import CryptoKit
import Foundation

/// Documents prepared for one commit, off the store's actor: their segment, and each body's text for snippets
/// (block-compressed, still plaintext in memory; sealed when committed).
public struct FullTextBatch: Sendable {
    let segment: FullTextSegment?
    let documents: [(id: FullTextDocumentID, fingerprint: String)]
    let bodyTexts: [Int: Data]
    public var isEmpty: Bool { documents.isEmpty }
}

/// The on-device full-text index of one account (docs/architecture/NATIVE_LIBRARY_SEARCH.md, "Full-text index").
///
/// Everything on disk is sealed with AES-GCM under the account's local-store key, with an account- and
/// file-bound associated data, in a directory with complete file protection that is excluded from backup:
/// `manifest.bin` (which documents are current, where), `seg-N.bin` (immutable segments) and `txt-ID.bin` (one
/// paper body's text for snippets). Nothing is written in plaintext. A changed `version` (format or tokenizer)
/// or an unreadable manifest empties the directory; the app then reindexes from the encrypted bundles.
public actor FullTextIndexStore {
    public static let format = 1
    /// Stored in the manifest; a different value means rebuild.
    public static var version: Int { format * 1_000 + FullTextTokenizer.version }
    /// At most this many segments; more are merged (smallest first).
    public static let maximumSegments = 8

    struct Manifest: Codable {
        var version: Int
        var account: UUID
        var nextSegment: UInt64 = 1
        var generation: UInt64 = 0
        var segments: [SegmentRecord] = []
        var docs: [DocRecord] = []
    }
    struct SegmentRecord: Codable, Equatable { let id: UInt64; let docs: Int; let bytes: Int }
    struct DocRecord: Codable {
        let id: FullTextDocumentID
        var segment: UInt64
        var index: Int
        let fingerprint: String
        /// The body text's file ID (body documents).
        let text: String?
        enum CodingKeys: String, CodingKey { case id = "i", segment = "s", index = "n", fingerprint = "f", text = "t" }
    }

    private let directory: URL
    private let accountID: UUID
    private let key: SymmetricKey
    private var manifest: Manifest
    private var loaded: [UInt64: FullTextSegment] = [:]
    private var current: FullTextSnapshot?
    private var closed = false
    private let textCache = FullTextTextCache()
    /// True when this open found no usable index (first run, version change or damage) and started empty.
    public private(set) var startedEmpty: Bool

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        guard localKey.count == 32 else { throw FullTextIndexError.invalidKey }
        self.directory = directory.standardizedFileURL
        self.accountID = accountID
        self.key = SymmetricKey(data: localKey)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        let manager = FileManager.default
        try manager.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: attributes)
        try? manager.setAttributes(attributes, ofItemAtPath: self.directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var secured = self.directory
        try? secured.setResourceValues(values)

        let manifestURL = self.directory.appendingPathComponent("manifest.bin")
        if let sealed = try? Data(contentsOf: manifestURL),
           let plain = try? Self.open(sealed, key: SymmetricKey(data: localKey), aad: Self.manifestAAD(accountID)),
           let decoded = try? JSONDecoder().decode(Manifest.self, from: plain),
           decoded.version == Self.version, decoded.account == accountID {
            manifest = decoded; startedEmpty = false
        } else {
            manifest = Manifest(version: Self.version, account: accountID); startedEmpty = true
        }
        // Files the manifest doesn't name: an interrupted commit, or everything after a version change.
        let referenced = Set(manifest.segments.map { "seg-\($0.id).bin" } + manifest.docs.compactMap { $0.text.map { "txt-\($0).bin" } })
        for url in (try? manager.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
        where (url.lastPathComponent.hasPrefix("seg-") || url.lastPathComponent.hasPrefix("txt-") || url.lastPathComponent.hasPrefix(".tmp-"))
            && !referenced.contains(url.lastPathComponent) {
            try? manager.removeItem(at: url)
        }
        if startedEmpty { try Self.write(manifest, to: self.directory, key: key, accountID: accountID) }
    }

    // MARK: Reading

    /// The fingerprint of every current document (an unchanged fingerprint needs no reindex).
    public func fingerprints() -> [FullTextDocumentID: String] {
        Dictionary(manifest.docs.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { _, last in last })
    }

    public var generation: UInt64 { manifest.generation }

    /// Bytes on disk (sealed segments and texts) and the documents they hold.
    public func footprint() -> (segmentBytes: Int, textBytes: Int, documents: Int) {
        let manager = FileManager.default
        func size(_ name: String) -> Int { ((try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.size] as? Int) ?? 0 }
        let segments = manifest.segments.reduce(0) { $0 + size("seg-\($1.id).bin") }
        let texts = manifest.docs.reduce(0) { $0 + ($1.text.map { size("txt-\($0).bin") } ?? 0) }
        return (segments, texts, manifest.docs.count)
    }

    /// The current index for queries, decrypting segments not yet in memory. A segment that can't be read empties
    /// the index (the app reindexes) rather than failing searches.
    public func snapshot() throws -> FullTextSnapshot {
        guard !closed else { throw FullTextIndexError.closed }
        if let current { return current }
        var segments: [FullTextSegment] = []
        for record in manifest.segments {
            if let segment = loaded[record.id] { segments.append(segment); continue }
            do {
                let segment = try loadSegment(record.id)
                loaded[record.id] = segment; segments.append(segment)
            } catch {
                try reset()
                return try snapshot()
            }
        }
        let snapshot = makeSnapshot(segments)
        current = snapshot
        return snapshot
    }

    /// Releases decrypted segments (memory pressure, or the library search going idle); the next query reloads.
    public func unload() { loaded = [:]; current = nil; textCache.removeAll() }

    // MARK: Writing

    /// Builds the segment and body texts for `documents`. Pure; runs on the caller's task, not the actor.
    public nonisolated static func prepare(_ documents: [FullTextDocument]) -> FullTextBatch {
        guard !documents.isEmpty else { return FullTextBatch(segment: nil, documents: [], bodyTexts: [:]) }
        let segment = FullTextSegment.build(documents)
        var texts: [Int: Data] = [:]
        for (index, document) in documents.enumerated() where document.id.part == .body {
            texts[index] = FullTextBodyText.encode(document.fields[.body] ?? "")
        }
        return FullTextBatch(segment: segment, documents: documents.map { ($0.id, $0.fingerprint) }, bodyTexts: texts)
    }

    /// Adds or replaces the batch's documents and removes `removing`, in one manifest write; then merges segments
    /// if there are too many or too much of one is out of date.
    public func commit(_ batch: FullTextBatch, removing: [FullTextDocumentID] = []) throws {
        guard !closed else { throw FullTextIndexError.closed }
        let replaced = Set(batch.documents.map(\.id)).union(removing)
        guard !batch.isEmpty || manifest.docs.contains(where: { replaced.contains($0.id) }) else { return }
        var next = manifest
        var obsoleteTexts: [String] = []
        next.docs.removeAll { record in
            guard replaced.contains(record.id) else { return false }
            if let text = record.text { obsoleteTexts.append(text) }
            return true
        }
        var written: [String] = []
        do {
            if let segment = batch.segment, !batch.isEmpty {
                let id = next.nextSegment
                next.nextSegment += 1
                let encoded = segment.encoded()
                try seal(encoded, aad: Self.segmentAAD(accountID, id), name: "seg-\(id).bin"); written.append("seg-\(id).bin")
                next.segments.append(SegmentRecord(id: id, docs: segment.docs.count, bytes: encoded.count))
                for (index, document) in batch.documents.enumerated() {
                    var textID: String?
                    if let text = batch.bodyTexts[index] {
                        let fileID = UUID().wire
                        try seal(text, aad: Self.textAAD(accountID, fileID), name: "txt-\(fileID).bin"); written.append("txt-\(fileID).bin")
                        textID = fileID
                    }
                    next.docs.append(DocRecord(id: document.id, segment: id, index: index, fingerprint: document.fingerprint, text: textID))
                }
                if current != nil || !loaded.isEmpty { loaded[id] = segment }
            }
            next.generation &+= 1
            try Self.write(next, to: directory, key: key, accountID: accountID)
        } catch {
            for name in written { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            throw error
        }
        manifest = next
        current = nil
        for text in obsoleteTexts { try? FileManager.default.removeItem(at: directory.appendingPathComponent("txt-\(text).bin")); textCache.remove(text) }
        try maintain()
    }

    /// Stops all further reads and writes (sign-out, account retirement). Waits for a commit in progress.
    public func close() { closed = true; loaded = [:]; current = nil; textCache.removeAll() }

    /// Empties the index (a damaged file, or a test); the app reindexes.
    public func reset() throws {
        guard !closed else { throw FullTextIndexError.closed }
        let manager = FileManager.default
        for url in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("seg-") || url.lastPathComponent.hasPrefix("txt-") {
            try? manager.removeItem(at: url)
        }
        manifest = Manifest(version: Self.version, account: accountID, generation: manifest.generation &+ 1)
        loaded = [:]; current = nil; textCache.removeAll(); startedEmpty = true
        try Self.write(manifest, to: directory, key: key, accountID: accountID)
    }

    // MARK: Merging

    /// Drops segments with no current document; merges the smallest when there are more than `maximumSegments`,
    /// and any segment more than half out of date.
    private func maintain() throws {
        var live: [UInt64: Int] = [:]
        for doc in manifest.docs { live[doc.segment, default: 0] += 1 }
        let empty = manifest.segments.filter { (live[$0.id] ?? 0) == 0 }
        if !empty.isEmpty {
            var next = manifest
            next.segments.removeAll { (live[$0.id] ?? 0) == 0 }
            next.generation &+= 1
            try Self.write(next, to: directory, key: key, accountID: accountID)
            manifest = next; current = nil
            for record in empty { loaded[record.id] = nil; try? FileManager.default.removeItem(at: directory.appendingPathComponent("seg-\(record.id).bin")) }
        }
        var chosen = Set<UInt64>()
        if manifest.segments.count > Self.maximumSegments {
            let smallest = manifest.segments.sorted { (live[$0.id] ?? 0, $0.id) < (live[$1.id] ?? 0, $1.id) }
            for record in smallest.prefix(manifest.segments.count - Self.maximumSegments / 2) { chosen.insert(record.id) }
        }
        for record in manifest.segments where record.docs >= 8 && (live[record.id] ?? 0) * 2 < record.docs { chosen.insert(record.id) }
        guard !chosen.isEmpty else { return }
        let records = manifest.segments.filter { chosen.contains($0.id) }
        let keepLoaded = current != nil || !loaded.isEmpty
        var segments: [FullTextSegment] = []
        for record in records { segments.append(try loaded[record.id] ?? loadSegment(record.id)) }
        var liveSlots = Set<String>()
        for doc in manifest.docs where chosen.contains(doc.segment) { liveSlots.insert("\(doc.segment)/\(doc.index)") }
        let (merged, mapping) = FullTextSegment.merge(segments) { s, d in liveSlots.contains("\(records[s].id)/\(d)") }
        var next = manifest
        let id = next.nextSegment
        next.nextSegment += 1
        let encoded = merged.encoded()
        try seal(encoded, aad: Self.segmentAAD(accountID, id), name: "seg-\(id).bin")
        let position = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.id, $0) })
        for index in next.docs.indices {
            guard let s = position[next.docs[index].segment], let newIndex = mapping[s][next.docs[index].index] else { continue }
            next.docs[index].segment = id; next.docs[index].index = newIndex
        }
        next.segments.removeAll { chosen.contains($0.id) }
        next.segments.append(SegmentRecord(id: id, docs: merged.docs.count, bytes: encoded.count))
        next.generation &+= 1
        do { try Self.write(next, to: directory, key: key, accountID: accountID) }
        catch { try? FileManager.default.removeItem(at: directory.appendingPathComponent("seg-\(id).bin")); throw error }
        manifest = next
        self.current = nil
        for record in records { loaded[record.id] = nil; try? FileManager.default.removeItem(at: directory.appendingPathComponent("seg-\(record.id).bin")) }
        if keepLoaded { loaded[id] = merged }
    }

    // MARK: Files

    private func makeSnapshot(_ segments: [FullTextSegment]) -> FullTextSnapshot {
        var current = Set<String>()
        var texts: [String: String] = [:]
        for doc in manifest.docs {
            current.insert("\(doc.segment)/\(doc.index)")
            if let text = doc.text { texts[doc.id.group] = text }
        }
        let ids = manifest.segments.map(\.id)
        let reader = FullTextTextReader(directory: directory, key: key, accountID: accountID, files: texts, cache: textCache)
        return FullTextSnapshot(segments: segments, current: { s, d in current.contains("\(ids[s])/\(d)") }, texts: reader,
                                generation: manifest.generation)
    }

    private func loadSegment(_ id: UInt64) throws -> FullTextSegment {
        let url = directory.appendingPathComponent("seg-\(id).bin")
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw FullTextIndexError.corrupt }
        let sealed = try Data(contentsOf: url, options: .mappedIfSafe)
        return try FullTextSegment.decode(try Self.open(sealed, key: key, aad: Self.segmentAAD(accountID, id)))
    }

    private func seal(_ plain: Data, aad: Data, name: String) throws {
        guard let sealed = try? AES.GCM.seal(plain, using: key, authenticating: aad).combined else { throw FullTextIndexError.storageUnavailable }
        try Self.writeAtomically(sealed, to: directory.appendingPathComponent(name))
    }

    static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad) }
        catch { throw FullTextIndexError.corrupt }
    }

    private static func write(_ manifest: Manifest, to directory: URL, key: SymmetricKey, accountID: UUID) throws {
        guard let plain = try? JSONEncoder().encode(manifest),
              let sealed = try? AES.GCM.seal(plain, using: key, authenticating: manifestAAD(accountID)).combined else {
            throw FullTextIndexError.storageUnavailable
        }
        try writeAtomically(sealed, to: directory.appendingPathComponent("manifest.bin"))
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        do { try data.write(to: url, options: options) } catch { throw FullTextIndexError.storageUnavailable }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let aadPrefix = "science-reader/search-index/"
    static func manifestAAD(_ account: UUID) -> Data { Data((aadPrefix + "manifest/v1/" + account.wire).utf8) }
    static func segmentAAD(_ account: UUID, _ id: UInt64) -> Data { Data((aadPrefix + "segment/v1/" + account.wire + "/" + String(id)).utf8) }
    static func textAAD(_ account: UUID, _ id: String) -> Data { Data((aadPrefix + "text/v1/" + account.wire + "/" + id).utf8) }
}

/// Reads one paper's sealed body text for a snippet. Recently read texts stay decoded in a small shared cache.
final class FullTextTextReader: @unchecked Sendable {
    private let directory: URL
    private let key: SymmetricKey
    private let accountID: UUID
    private let files: [String: String]
    private let cache: FullTextTextCache

    init(directory: URL, key: SymmetricKey, accountID: UUID, files: [String: String], cache: FullTextTextCache) {
        self.directory = directory; self.key = key; self.accountID = accountID; self.files = files; self.cache = cache
    }

    func body(group: String) -> FullTextBodyText? {
        guard let file = files[group] else { return nil }
        if let cached = cache.value(file) { return cached }
        guard let sealed = try? Data(contentsOf: directory.appendingPathComponent("txt-\(file).bin")),
              let plain = try? FullTextIndexStore.open(sealed, key: key, aad: FullTextIndexStore.textAAD(accountID, file)),
              let body = try? FullTextBodyText.decode(plain) else { return nil }
        cache.store(body, for: file)
        return body
    }
}

/// A few decoded body texts, most recent kept.
final class FullTextTextCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: FullTextBodyText] = [:]
    private var order: [String] = []
    private let limit = 64

    func value(_ key: String) -> FullTextBodyText? {
        lock.withLock {
            guard let value = values[key] else { return nil }
            order.removeAll { $0 == key }; order.append(key)
            return value
        }
    }
    func store(_ value: FullTextBodyText, for key: String) {
        lock.withLock {
            values[key] = value; order.removeAll { $0 == key }; order.append(key)
            while order.count > limit { values[order.removeFirst()] = nil }
        }
    }
    func remove(_ key: String) { lock.withLock { values[key] = nil; order.removeAll { $0 == key } } }
    func removeAll() { lock.withLock { values = [:]; order = [] } }
}

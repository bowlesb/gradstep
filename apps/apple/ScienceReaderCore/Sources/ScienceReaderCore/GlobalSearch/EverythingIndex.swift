import CryptoKit
import Foundation

/// The account's second encrypted index (docs/architecture/GLOBAL_SEARCH.md): chats and their messages, kept
/// explanations, snippets and collections, diagrams. The same engine and sealing as the Library's `search-index`
/// (`FullTextIndexStore`, AES-GCM under the account's local-store key, complete file protection, excluded from backup),
/// in its own folder and associated-data namespace, one metadata-part document per item (no per-item text file), each
/// item's kind, paper, container and date sealed in the manifest beside it. Recent searches are a sealed file in the
/// same folder.
public final class EverythingIndex: @unchecked Sendable {
    public static let namespace = "everything-index"

    public let directory: URL
    public let accountID: UUID
    private let store: FullTextIndexStore
    private let key: SymmetricKey
    private let lock = NSLock()
    private var cached: EverythingSnapshot?

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        self.directory = directory.standardizedFileURL
        self.accountID = accountID
        store = try FullTextIndexStore(directory: directory, accountID: accountID, localKey: localKey, namespace: Self.namespace)
        key = SymmetricKey(data: localKey)
    }

    /// True when this open found no usable index (first run, a new version, damage): the app builds it in the background.
    public var startedEmpty: Bool { get async { await store.startedEmpty } }

    /// Each indexed item's fingerprint, by group (`SearchItemInfo.group`).
    public func fingerprints() async -> [String: String] {
        var out: [String: String] = [:]
        for (id, fingerprint) in await store.fingerprints() { out[id.group] = fingerprint }
        return out
    }

    /// Adds or replaces `items` (each with its fingerprint) and removes `removing` (groups), in one commit. The segment is
    /// built on the caller's task, not the store's.
    public func commit(_ items: [(item: SearchItem, fingerprint: String)], removing: [String] = []) async throws {
        guard !items.isEmpty || !removing.isEmpty else { return }
        let batch = FullTextIndexStore.prepare(items.map { $0.item.document(fingerprint: $0.fingerprint) })
        try await store.commit(batch, removing: removing.map { FullTextDocumentID(group: $0, part: .metadata) })
    }

    /// The current index with each item's info, for queries; decrypts segments not yet in memory.
    public func snapshot() async throws -> EverythingSnapshot {
        let index = try await store.snapshot()
        if let cached = lock.withLock({ cached }), cached.index === index { return cached }
        let snapshot = EverythingSnapshot(index: index)
        lock.withLock { cached = snapshot }
        return snapshot
    }

    /// Memory warning or idle: decrypted segments are dropped; the next search reloads them.
    public func unload() async {
        lock.withLock { cached = nil }
        await store.unload()
    }

    /// Sign-out or account change: no further reads or writes.
    public func close() async {
        lock.withLock { cached = nil }
        await store.close()
    }

    /// Empties the index (a test, or a rebuild).
    public func reset() async throws {
        lock.withLock { cached = nil }
        try await store.reset()
    }

    public func footprint() async -> (bytes: Int, items: Int) {
        let footprint = await store.footprint()
        return (footprint.segmentBytes + footprint.textBytes, footprint.documents)
    }

    // MARK: Recent searches

    private var recentURL: URL { directory.appendingPathComponent("recent.bin") }
    private var recentAAD: Data { Data("science-reader/\(Self.namespace)/recent/v1/\(accountID.wire)".utf8) }
    /// Kept: this many (the screen shows five).
    public static let recentLimit = 10

    /// The searches kept on this device, newest first (sealed; never in UserDefaults).
    public func recentSearches() -> [String] {
        guard let sealed = try? Data(contentsOf: recentURL),
              let plain = try? FullTextIndexStore.open(sealed, key: key, aad: recentAAD),
              let list = try? JSONDecoder().decode([String].self, from: plain) else { return [] }
        return Array(list.prefix(Self.recentLimit))
    }

    /// Puts `query` first (an equal one, case and spacing aside, moves up), keeping `recentLimit`.
    @discardableResult
    public func remember(_ query: String) -> [String] {
        let text = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= 200 else { return recentSearches() }
        var list = recentSearches().filter { $0.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame }
        list.insert(text, at: 0)
        list = Array(list.prefix(Self.recentLimit))
        saveRecent(list)
        return list
    }

    public func clearRecentSearches() { try? FileManager.default.removeItem(at: recentURL) }

    private func saveRecent(_ list: [String]) {
        guard let plain = try? JSONEncoder().encode(list),
              let sealed = try? AES.GCM.seal(plain, using: key, authenticating: recentAAD).combined else { return }
        try? FullTextIndexStore.writeAtomically(sealed, to: recentURL)
    }
}

/// An immutable view of the everything index: the full-text snapshot and each current item's info.
public final class EverythingSnapshot: @unchecked Sendable {
    public let index: FullTextSnapshot
    public let items: [String: SearchItemInfo]
    /// Per index slot (`index.groups` order): the item's info, its conversation or collection (`collapseKey`) and its
    /// date in seconds, decoded once per snapshot so a search hashes no names.
    let slotInfos: [SearchItemInfo?]
    let slotKeys: [UUID?]
    let slotDates: [Double]

    init(index: FullTextSnapshot) {
        self.index = index
        var items: [String: SearchItemInfo] = [:]
        items.reserveCapacity(index.groups.count)
        var infos: [SearchItemInfo?] = [], keys: [UUID?] = [], dates: [Double] = []
        infos.reserveCapacity(index.groups.count); keys.reserveCapacity(index.groups.count); dates.reserveCapacity(index.groups.count)
        for group in index.groups {
            let info = SearchItemInfo(group: group, encoded: index.infos[group])
            if let info { items[group] = info }
            infos.append(info); keys.append(info?.collapseKey); dates.append(info?.date?.timeIntervalSince1970 ?? -.infinity)
        }
        self.items = items; slotInfos = infos; slotKeys = keys; slotDates = dates
    }

    public var generation: UInt64 { index.generation }
    public var count: Int { items.count }
}

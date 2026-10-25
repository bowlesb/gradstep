import CryptoKit
import Foundation

/// Snippets' search (docs/architecture/NOTES_AND_SNIPPETS.md "Search"; owner, TestFlight 91: "What in the snippets does
/// it actually search? Is it as good as it possibly can be?"). Everything runs on this device over decrypted records.
///
/// A query is split into words folded as the Library's full-text index folds them (case, diacritics and width: "Café"
/// finds "cafe", "CAFE" and "café"), never stemmed, and every word must begin a word of the same collection's name or of
/// one snippet (with its collection's name): "quick atten" finds the snippet about attention in Quick snippets.
///
/// A snippet's words are every text field its record carries (comment, quotation, the anchor's quotation, the paper's
/// title and authors, its arXiv ID, the section and the figure/table label) plus what the app knows about its pixels:
/// the reader blocks under a drawn region when that paper's reading is on this device (their text, the LaTeX of their
/// equations, figure and table captions and alt text) and the text Vision recognised in its image on this device.
public enum NoteSearch {
    /// A match: the collection, and the snippets that match on their own (opening the result goes to the first).
    public struct Match: Equatable, Sendable {
        public let noteID: UUID
        public let entryIDs: [UUID]
    }

    /// The query's words, folded and deduplicated, in order.
    public static func terms(_ query: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for token in FullTextTokenizer.tokens(query, stem: false) where !token.joined && seen.insert(token.term).inserted {
            out.append(token.term)
        }
        return out
    }

    /// The folded words of `texts`, sorted and unique (prefix lookups are a binary search).
    public static func words(_ texts: [String]) -> [String] {
        var all = Set<String>()
        for text in texts where !text.isEmpty {
            for token in FullTextTokenizer.tokens(text, stem: false) { all.insert(token.term) }
        }
        return all.sorted()
    }

    /// True when every term begins one of `words` (sorted, as `words(_:)` returns them).
    public static func matches(_ terms: [String], in words: [String]) -> Bool {
        terms.allSatisfy { hasPrefix($0, in: words) }
    }

    /// Every text field of the record itself.
    public static func recordText(_ record: NoteEntryRecord) -> [String] {
        var texts = [record.comment]
        if let quote = record.quote { texts.append(quote) }
        if let quote = record.anchor?.quote, quote != record.quote { texts.append(quote) }
        if let source = record.source {
            texts.append(source.title)
            texts.append(contentsOf: source.authors)
            if let id = source.sourceID, source.kind != .document { texts.append(id) }
            if let section = source.section { texts.append(section) }
            if let label = source.label { texts.append(label) }
        }
        return texts
    }

    /// What the reading shows under a snippet's blocks, when `index` is the reading the anchor names: each block's text
    /// (an equation block's is its LaTeX), its equations' LaTeX, and the captions and alt text of its figures and tables.
    public static func bundleText(_ anchor: NoteAnchor, in index: ReaderBundleIndex) -> [String] {
        let ids = Set(anchor.blockIDs)
        guard !ids.isEmpty else { return [] }
        var texts: [String] = index.blocks.filter { ids.contains($0.id) }.map(\.text)
        texts += index.equations.filter { ids.contains($0.blockID) }.map(\.latex)
        for figure in index.figures where ids.contains(figure.blockID) { texts += [figure.caption, figure.alt] }
        texts += (index.tables ?? []).filter { ids.contains($0.id) }.map(\.caption)
        return texts
    }

    /// The collections matching `query`, in `state`'s order. `extra` adds what the app knows beyond the record (the
    /// reading's text under a region, recognised text); `cache` keeps each snippet's folded words between keystrokes.
    public static func search(_ state: NotesState, query: String, extra: (NoteEntryRecord) -> [String] = { _ in [] },
                              cache: WordCache? = nil) -> [Match]? {
        let terms = terms(query)
        guard !terms.isEmpty else { return nil }
        var out: [Match] = []
        for note in state.notes {
            let title = words([note.title])
            let remaining = terms.filter { !hasPrefix($0, in: title) }
            var matched: [UUID] = [], any = remaining.isEmpty
            for entry in note.entries {
                let own = cache?.words(for: entry, extra: extra) ?? words(recordText(entry.record) + extra(entry.record))
                if matches(terms, in: own) { matched.append(entry.id); any = true }
                else if !any, matches(remaining, in: own) { any = true }
            }
            if any { out.append(Match(noteID: note.id, entryIDs: matched)) }
        }
        return out
    }

    /// Folded words per snippet, recomputed when its record or the extra text changes.
    public final class WordCache: @unchecked Sendable {
        private var stored: [UUID: (key: Int, words: [String])] = [:]
        private let lock = NSLock()
        public init() {}

        func words(for entry: NotesState.Entry, extra: (NoteEntryRecord) -> [String]) -> [String] {
            let texts = recordText(entry.record) + extra(entry.record)
            var hasher = Hasher()
            for text in texts { hasher.combine(text) }
            let key = hasher.finalize()
            lock.lock(); defer { lock.unlock() }
            if let hit = stored[entry.id], hit.key == key { return hit.words }
            let value = NoteSearch.words(texts)
            stored[entry.id] = (key, value)
            return value
        }

        public func removeAll() { lock.lock(); stored = [:]; lock.unlock() }
    }

    private static func hasPrefix(_ term: String, in words: [String]) -> Bool {
        var low = 0, high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid] < term { low = mid + 1 } else { high = mid }
        }
        return low < words.count && words[low].hasPrefix(term)
    }
}

/// Text Vision recognised in snippet images on this device, by the full image's blob ID: one file sealed with the
/// account's local key (AES-GCM, the account bound as associated data) in a folder with complete file protection and
/// excluded from backup, as kept explanations are. Never synced or sent; an empty string records "nothing found" so an
/// image is read once. Bounded: 4 KiB of text per image, 20,000 images.
public final class SnippetTextStore: @unchecked Sendable {
    public static let maximumTextBytes = 4_096
    public static let maximumImages = 20_000
    private static let aadPrefix = "science-reader/snippet-text/v1/"
    private let file: URL
    private let accountID: UUID
    private let key: SymmetricKey
    private let lock = NSLock()

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        let directory = directory.standardizedFileURL
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)
        file = directory.appendingPathComponent("recognised.sealed")
        self.accountID = accountID
        key = SymmetricKey(data: localKey)
    }

    /// Everything kept; empty when there is nothing, or the file doesn't open under this account's key.
    public func load() -> [UUID: String] {
        lock.lock(); defer { lock.unlock() }
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let sealed = try? Data(contentsOf: file), sealed.count <= 128 * 1_048_576,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key, authenticating: aad),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var out: [UUID: String] = [:]
        for (id, text) in stored { if let uuid = UUID(uuidString: id) { out[uuid] = text } }
        return out
    }

    /// Replaces what is kept (each text cut to its bound; past the image bound, an arbitrary remainder is dropped and
    /// read again later).
    public func save(_ texts: [UUID: String]) throws {
        lock.lock(); defer { lock.unlock() }
        var stored: [String: String] = [:]
        for (id, text) in texts.prefix(Self.maximumImages) { stored[id.uuidString.lowercased()] = Self.bounded(text) }
        let data = try JSONEncoder().encode(stored)
        guard let sealed = try AES.GCM.seal(data, using: key, authenticating: aad).combined else { throw ReaderError.invalidEvent }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try sealed.write(to: file, options: options)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
    }

    /// At most `maximumTextBytes` of UTF-8, cut between whole characters.
    public static func bounded(_ text: String) -> String { NoteSource.prefix(text, bytes: maximumTextBytes) }

    private var aad: Data { Data((Self.aadPrefix + accountID.wire).utf8) }
}

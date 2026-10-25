import Foundation

// Collapsed snippets (owner, 2026-10-22: "having the ability to collapse individual snippets would be helpful (so you can
// just see the date/times)"; docs/architecture/NOTES_AND_SNIPPETS.md "Collapsible snippet cards"). A collapsed entry is
// one line: its time, a short form of its paper's title and the first words of the reader's comment. Which entries are
// collapsed is remembered on this device only (never synced, never sent). The browser applies the same rules
// (apps/web/src/lib/note-collapse.ts) against the same cases (tests/fixtures/notes/collapsed-lines.json).

public enum NoteCollapsedLine {
    /// A paper title longer than this is shortened at a word; on a narrow screen (a phone, a compact window) the shorter
    /// limit leaves room for the comment's first words.
    public static let titleLimit = 32
    public static let compactTitleLimit = 20
    /// At most this many words of the comment (or quotation), and at most `wordsCharacterLimit` characters.
    public static let wordLimit = 8
    public static let wordsCharacterLimit = 60

    /// "3:04 PM · Direct Preference Optimization… · The early improvement is the interesting part." `time` is already
    /// formatted for the reader's locale; empty parts are left out.
    public static func line(time: String, record: NoteEntryRecord, titleLimit: Int = titleLimit) -> String {
        line(time: time, title: record.source?.title ?? "", comment: record.comment, quote: record.quote, label: record.source?.label, titleLimit: titleLimit)
    }

    public static func line(time: String, title: String, comment: String, quote: String?, label: String?, titleLimit: Int = titleLimit) -> String {
        [time, shortTitle(title, limit: titleLimit), firstWords(comment: comment, quote: quote, label: label)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Whitespace, newlines included, collapsed to single spaces.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The title, or its first words within `limit` characters with "…".
    public static func shortTitle(_ title: String, limit: Int = titleLimit) -> String {
        let text = collapse(title)
        guard text.count > limit else { return text }
        return cut(text, to: limit - 1, minimumWordCut: min(12, limit / 2)) + "…"
    }

    /// The first words of the comment; without one, of the quotation; without either, the item's label ("Figure 2").
    public static func firstWords(comment: String, quote: String?, label: String?) -> String {
        let source = [comment, quote ?? "", label ?? ""].map(collapse).first { !$0.isEmpty } ?? ""
        let words = source.split(separator: " ")
        var text = words.prefix(wordLimit).joined(separator: " ")
        var shortened = words.count > wordLimit
        if text.count > wordsCharacterLimit {
            text = cut(text, to: wordsCharacterLimit - 1, minimumWordCut: 20); shortened = true
        }
        return shortened ? trimEnd(text) + "…" : text
    }

    private static func trimEnd(_ text: String) -> String {
        var text = text
        while let last = text.last, last == " " || ":;,.-–—".contains(last) { text.removeLast() }
        return text
    }

    /// At most `limit` characters: whole words when the cut falls between words, else ending at the last space at or
    /// after `minimumWordCut`, else a hard cut; trailing punctuation before the "…" is dropped.
    private static func cut(_ text: String, to limit: Int, minimumWordCut: Int) -> String {
        var head = String(text.prefix(limit))
        let atBoundary = text.count > limit && text[text.index(text.startIndex, offsetBy: limit)] == " "
        if !atBoundary, let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= minimumWordCut {
            head = String(head[..<space])
        }
        return trimEnd(head)
    }
}

/// Which entries of each collection are collapsed on this device: one small list of entry IDs per collection in the
/// app's defaults. Nothing here is synced; deleting an entry elsewhere just leaves an ID that no longer matches.
public struct NoteCollapseMemory: @unchecked Sendable {
    public static let keyPrefix = "notes.collapsed."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func key(_ noteID: UUID) -> String { keyPrefix + noteID.uuidString.lowercased() }

    public func collapsed(in noteID: UUID) -> Set<UUID> {
        Set((defaults.stringArray(forKey: Self.key(noteID)) ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// Stores the set, keeping only IDs of entries the collection still has (when `existing` is given); an empty set
    /// removes the key.
    public func set(_ ids: Set<UUID>, in noteID: UUID, existing: Set<UUID>? = nil) {
        let kept = existing.map { ids.intersection($0) } ?? ids
        if kept.isEmpty { defaults.removeObject(forKey: Self.key(noteID)) }
        else { defaults.set(kept.map { $0.uuidString.lowercased() }.sorted(), forKey: Self.key(noteID)) }
    }
}

/// A collection's row in the Snippets list (owner, TestFlight 91: "You just need two lines there, the title and then the
/// number of snippets… I would honestly remove the date too"): its name, then how many snippets it holds. No date and
/// no papers; an empty collection says so once.
public enum NoteCollectionLine {
    public static func detail(entryCount: Int) -> String {
        switch entryCount {
        case 0: "No snippets yet"
        case 1: "1 snippet"
        default: "\(entryCount) snippets"
        }
    }
}

import Foundation

/// A paper's tags (docs/architecture/TAGS.md, migration 030). The server keeps three lists per
/// library item: the catalog's tags for the paper (`tags`), the reader's own (`user_tags`) and the
/// catalog tags the reader removed (`hidden_tags`). What the reader sees is the catalog's tags
/// minus the removed ones, then their own. Personal tags sync through the server like archive
/// state; they are not end-to-end encrypted.
public enum PaperTags {
    /// Server limits (migration 030's `valid_tag_list`): characters are Unicode scalars, as PostgreSQL counts them.
    public static let maximumCharacters = 40
    public static let maximumBytes = 120
    public static let maximumOwnTags = 12
    public static let maximumHiddenTags = 8

    /// Tag text as stored: whitespace collapsed to single spaces and trimmed, control characters
    /// removed; nil when empty or too long.
    public static func normalized(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(scalar)
        }
        let text = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !text.isEmpty, text.unicodeScalars.count <= maximumCharacters, text.utf8.count <= maximumBytes else { return nil }
        return text
    }

    /// Whether a list is valid as stored (normalized, distinct ignoring case, within `limit`).
    public static func isValid(_ list: [String], limit: Int) -> Bool {
        list.count <= limit && list.allSatisfy { normalized($0) == $0 } && Set(list.map { $0.lowercased() }).count == list.count
    }

    public static func contains(_ list: [String], _ tag: String) -> Bool {
        let key = tag.lowercased()
        return list.contains { $0.lowercased() == key }
    }

    /// The tags a reader sees: the catalog's (minus those the reader removed), then the reader's own.
    public static func effective(catalog: [String], own: [String], hidden: [String]) -> [String] {
        var result: [String] = []
        for tag in catalog where !contains(hidden, tag) && !contains(result, tag) { result.append(tag) }
        for tag in own where !contains(result, tag) { result.append(tag) }
        return result
    }

    /// The personal lists that make `desired` the effective tags over `catalog`: own tags are the
    /// desired ones the catalog lacks, hidden ones the catalog tags left out.
    public static func edit(catalog: [String], desired: [String]) -> (own: [String], hidden: [String]) {
        var chosen: [String] = []
        for tag in desired { if let text = normalized(tag), !contains(chosen, text) { chosen.append(text) } }
        let own = chosen.filter { !contains(catalog, $0) }
        var hidden: [String] = []
        for tag in catalog where !contains(chosen, tag) && !contains(hidden, tag) { hidden.append(tag) }
        return (own, hidden)
    }
}

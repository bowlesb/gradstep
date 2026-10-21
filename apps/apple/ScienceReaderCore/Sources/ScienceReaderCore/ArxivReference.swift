import Foundation

public enum ArxivReferenceError: Error, Equatable { case invalidReference }

/// A paper identity, never an address to fetch. Mirrors the acquisition adapter's
/// supported modern/historical IDs; pasted query strings and fragments are lost.
public struct ArxivReference: Equatable, Hashable, Sendable {
    public let sourceID: String
    public let revision: Int?
    public var identifier: String { sourceID + (revision.map { "v\($0)" } ?? "") }
    public var abstractURL: URL { URL(string: "https://arxiv.org/abs/\(identifier)")! }

    public init(_ input: String) throws {
        guard input.utf16.count <= 2_048 else { throw ArxivReferenceError.invalidReference }
        var value = input.trimmingCharacters(in: Self.trimCharacters)
        guard !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              !value.contains("\\") else { throw ArxivReferenceError.invalidReference }
        if Self.match(#"^https?://"#, value, insensitive: true) != nil {
            guard let parts = Self.match(#"^https?://[^/?#]+([^?#]*)"#, value, insensitive: true),
                  let path = parts[1], !path.isEmpty, !path.contains("%"),
                  Self.match(#"/(?:\.|\.\.)(?:/|$)"#, path) == nil,
                  let url = URLComponents(string: value),
                  let host = url.host?.lowercased(), ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(host),
                  url.user == nil, url.password == nil,
                  url.port == nil || url.port == (url.scheme?.lowercased() == "https" ? 443 : 80),
                  let route = Self.match(#"^/(abs|pdf)/(.+)$"#, path), let kind = route[1], let reference = route[2]
            else { throw ArxivReferenceError.invalidReference }
            value = reference
            if kind == "pdf", value.lowercased().hasSuffix(".pdf") { value.removeLast(4) }
        } else if let prefix = value.range(of: #"^arxiv:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            value.removeSubrange(prefix)
        }
        // ICU case folding accepts some non-ASCII lookalikes for [a-z].
        // arXiv identities use ASCII, independently of a pasted link's query.
        guard value.unicodeScalars.allSatisfy({ $0.isASCII }) else { throw ArxivReferenceError.invalidReference }
        var revision: Int?
        if let versioned = Self.match(#"^(.*)v([0-9]+)$"#, value, insensitive: true),
           let base = versioned[1], let version = versioned[2] {
            guard Self.match(#"^[1-9][0-9]{0,9}$"#, version) != nil,
                  let number = Int(version), number <= 2_147_483_647 else { throw ArxivReferenceError.invalidReference }
            value = base; revision = number
        }
        if let modern = Self.match(#"^([0-9]{2})([0-9]{2})\.([0-9]{4,5})$"#, value),
           let year = Int(modern[1]!), let month = Int(modern[2]!), let serial = modern[3] {
            guard (1...12).contains(month), year >= 7, year != 7 || month >= 4,
                  Int(serial)! > 0, serial.count == (year < 15 ? 4 : 5) else { throw ArxivReferenceError.invalidReference }
        } else {
            guard let historic = Self.match(#"^([a-z][a-z0-9-]*)(?:\.([a-z]{2}))?/([0-9]{2})([0-9]{2})([0-9]{3})$"#, value, insensitive: true),
                  let archive = historic[1]?.lowercased(), let yearText = historic[3], let monthText = historic[4],
                  let serial = historic[5], let year = Int(yearText), let month = Int(monthText),
                  (1...12).contains(month), Int(serial)! > 0,
                  !(year > 7 && year < 91), year != 91 || month >= 7, year != 7 || month <= 3,
                  historic[2] == nil || ["math", "cs", "nlin", "q-bio"].contains(archive)
            else { throw ArxivReferenceError.invalidReference }
            value = "\(archive)/\(yearText)\(monthText)\(serial)"
        }
        // The immutable catalog/import contract has this same source-ID cap.
        guard value.utf8.count <= 128 else { throw ArxivReferenceError.invalidReference }
        self.sourceID = value; self.revision = revision
    }

    /// The backend receives these canonical fields, never an arbitrary pasted URL.
    public init(sourceID: String, revision: Int?) throws {
        let normalized = try Self(sourceID + (revision.map { "v\($0)" } ?? ""))
        guard normalized.sourceID == sourceID, normalized.revision == revision else { throw ArxivReferenceError.invalidReference }
        self = normalized
    }

    private static func match(_ pattern: String, _ value: String, insensitive: Bool = false) -> [String?]? {
        // Compiled once: library rebuilds parse every paper's catalog key (NATIVE_REVIEW_20261021 C4).
        let expression = CompiledPatterns.shared.expression(pattern, options: insensitive ? [.caseInsensitive] : [])
        guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (0..<match.numberOfRanges).map { index in Range(match.range(at: index), in: value).map { String(value[$0]) } }
    }

    // ECMAScript trim's characters, matching the backend without silently
    // stripping C1 control characters such as U+0085 before validation.
    private static let trimCharacters = CharacterSet(charactersIn:
        "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
}

/// Fixed regular expressions, compiled once per pattern and options (a compiled `NSRegularExpression` is immutable and
/// safe to share between threads). Only literal patterns from this module go in, so the set stays small.
final class CompiledPatterns: @unchecked Sendable {
    static let shared = CompiledPatterns()
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]
    func expression(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        return lock.withLock {
            if let known = compiled[key] { return known }
            let expression = try! NSRegularExpression(pattern: pattern, options: options)
            compiled[key] = expression
            return expression
        }
    }
}

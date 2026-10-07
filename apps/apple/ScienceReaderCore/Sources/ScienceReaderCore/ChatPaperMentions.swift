import Foundation

/// A paper an answer names by arXiv ID or DOI. Found on the device from the
/// answer's own text; nothing is fetched and no model is asked.
public struct ChatPaperMention: Equatable, Hashable, Sendable, Identifiable {
    public enum Identity: Equatable, Hashable, Sendable {
        case arxiv(ArxivReference)
        /// As written in the answer (DOIs compare case-insensitively).
        case doi(String)
    }
    public let identity: Identity
    /// The title the answer gives it (a link's text or the item's bold title), if any.
    public let title: String?

    public init(identity: Identity, title: String?) { self.identity = identity; self.title = title }

    /// Stable across answers: `arxiv:<source ID>` or `doi:<lowercased DOI>`.
    public var id: String {
        switch identity {
        case .arxiv(let reference): "arxiv:\(reference.sourceID)"
        case .doi(let doi): "doi:\(doi.lowercased())"
        }
    }
    /// "arXiv 2305.18290" or "DOI 10.2307/2334029".
    public var label: String {
        switch identity {
        case .arxiv(let reference): "arXiv \(reference.identifier)"
        case .doi(let doi): "DOI \(doi)"
        }
    }
    /// The paper's page: arXiv's abstract page or the DOI resolver.
    public var url: URL {
        switch identity {
        case .arxiv(let reference): return reference.abstractURL
        case .doi(let doi):
            let path = doi.addingPercentEncoding(withAllowedCharacters: ChatPaperMentions.doiPathAllowed) ?? doi
            return URL(string: "https://doi.org/" + path) ?? URL(string: "https://doi.org/")!
        }
    }
}

public enum ChatPaperMentions {
    /// At most this many papers are listed under one answer.
    public static let maximum = 8

    static let doiPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#;")
        return allowed
    }()

    // Crossref's recommended DOI pattern (covers nearly all registered DOIs), ASCII only.
    private static let doiPattern = try! NSRegularExpression(pattern: #"\b10\.\d{4,9}/[-._;()/:A-Za-z0-9]+"#)
    private static let arxivLinkPattern = try! NSRegularExpression(
        pattern: #"arxiv\.org/(?:abs|pdf)/((?:[a-z][a-z-]*(?:\.[a-z]{2})?/\d{7})|(?:\d{4}\.\d{4,5}))(v\d+)?(?![\d])"#, options: [.caseInsensitive])
    private static let arxivNamePattern = try! NSRegularExpression(
        pattern: #"\barxiv(?::\s*|\s+)((?:[a-z][a-z-]*(?:\.[a-z]{2})?/\d{7})|(?:\d{4}\.\d{4,5}))(v\d+)?(?!\d)"#, options: [.caseInsensitive])
    private static let arxivDOIPattern = try! NSRegularExpression(pattern: #"^10\.48550/arxiv\.(.+)$"#, options: [.caseInsensitive])
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[([^\]\n]{1,300})\]\(([^)\s]{1,2000})\)"#)

    /// The papers an answer names, in order of first mention, deduplicated and
    /// capped at `maximum`. Papers that appear only in its trailing Sources list
    /// are left out: that list already shows them.
    public static func extract(from answer: String) -> [ChatPaperMention] {
        var text = ChatRichText.trailingSources(answer)?.body ?? answer
        if text.utf8.count > ChatRichText.maximumParsedBytes {
            text = String(decoding: text.utf8.prefix(ChatRichText.maximumParsedBytes), as: UTF8.self)
        }
        guard text.range(of: "arxiv", options: .caseInsensitive) != nil || text.contains("10.") else { return [] }
        let whole = NSRange(text.startIndex..., in: text)

        var found: [(location: Int, identity: ChatPaperMention.Identity, range: NSRange)] = []
        for pattern in [arxivLinkPattern, arxivNamePattern] {
            for match in pattern.matches(in: text, range: whole) {
                guard let id = Range(match.range(at: 1), in: text).map({ String(text[$0]) }) else { continue }
                let version = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
                guard let reference = try? ArxivReference(id + version) else { continue }
                found.append((match.range.location, .arxiv(reference), match.range))
            }
        }
        for match in doiPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let doi = trimmedDOI(String(text[range]))
            guard doi.count >= 8, doi.count <= 200 else { continue }
            let identity: ChatPaperMention.Identity
            let doiRange = NSRange(location: 0, length: (doi as NSString).length)
            if let arxiv = arxivDOIPattern.firstMatch(in: doi, range: doiRange),
               let id = Range(arxiv.range(at: 1), in: doi), let reference = try? ArxivReference(String(doi[id])) {
                identity = .arxiv(reference)
            } else {
                identity = .doi(doi)
            }
            found.append((match.range.location, identity, NSRange(location: match.range.location, length: (doi as NSString).length)))
        }
        found.sort { $0.location < $1.location }

        let links = linkPattern.matches(in: text, range: whole)
        let nsText = text as NSString
        // How many distinct papers each line names: a line's leading title belongs to its only paper.
        var papersPerLine: [Int: Set<String>] = [:]
        func lineRange(_ location: Int) -> NSRange { nsText.lineRange(for: NSRange(location: location, length: 0)) }
        for item in found { papersPerLine[lineRange(item.location).location, default: []].insert(key(item.identity)) }

        var order: [String] = [], mentions: [String: ChatPaperMention] = [:]
        for item in found {
            let id = key(item.identity)
            var title: String?
            if let link = links.first(where: { NSLocationInRange(item.location, $0.range(at: 2)) }) {
                title = cleanTitle(nsText.substring(with: link.range(at: 1)))
            }
            let line = lineRange(item.location)
            if title == nil, papersPerLine[line.location]?.count == 1 {
                title = leadingTitle(nsText.substring(with: line))
            }
            if let existing = mentions[id] {
                if existing.title == nil, let title { mentions[id] = ChatPaperMention(identity: existing.identity, title: title) }
                continue
            }
            guard order.count < maximum else { continue }
            order.append(id)
            mentions[id] = ChatPaperMention(identity: item.identity, title: title)
        }
        return order.compactMap { mentions[$0] }
    }

    private static func key(_ identity: ChatPaperMention.Identity) -> String {
        ChatPaperMention(identity: identity, title: nil).id
    }

    /// Drops punctuation that ends a sentence or closes a link around the DOI.
    static func trimmedDOI(_ value: String) -> String {
        var doi = value
        while let last = doi.last {
            if ".,;:".contains(last) { doi.removeLast(); continue }
            if last == ")", doi.filter({ $0 == "(" }).count < doi.filter({ $0 == ")" }).count { doi.removeLast(); continue }
            break
        }
        return doi
    }

    /// A list item's or line's leading title: `**Title**`, `*Title*`, `[Title](…)` or a quoted title.
    static func leadingTitle(_ line: String) -> String? {
        var rest = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        if let marker = rest.range(of: #"^(?:[-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) { rest = rest[marker.upperBound...] }
        let pairs: [(open: String, close: String)] = [("**", "**"), ("__", "__"), ("*", "*"), ("_", "_"), ("“", "”"), ("\"", "\""), ("[", "]")]
        for pair in pairs where rest.hasPrefix(pair.open) {
            let body = rest.dropFirst(pair.open.count)
            guard let close = body.range(of: pair.close) else { continue }
            return cleanTitle(String(body[..<close.lowerBound]))
        }
        return nil
    }

    /// Plain title text, or nil when it is not a usable title (an address, an ID, a label such as "Note:").
    static func cleanTitle(_ raw: String) -> String? {
        let stripped = raw.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—–-,;")))
        let lowered = stripped.lowercased()
        guard stripped.count >= 4, stripped.count <= 300, stripped.contains(" "), !stripped.hasSuffix(":"),
              !lowered.hasPrefix("http"), !lowered.contains("arxiv.org"), !lowered.hasPrefix("arxiv"), !lowered.hasPrefix("doi"),
              stripped.range(of: #"^\d{4}\.\d{4,5}"#, options: .regularExpression) == nil,
              stripped.range(of: #"^10\.\d{4,9}/"#, options: .regularExpression) == nil,
              stripped.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil else { return nil }
        return stripped
    }
}

import Foundation

/// The papers in an arXiv export API answer (Atom) for an `id_list` query: what this device read about related papers it
/// had no Feed result for. Identifier and version, title, authors, abstract, year and categories; entries that don't
/// carry an arXiv identifier and a title are skipped. No DTDs or external entities are read.
public enum ArxivAtomListing {
    public static let maximumBytes = 1_048_576

    public static func parse(_ data: Data) -> [DiscoveryResult] {
        guard data.count <= maximumBytes, let head = String(data: data.prefix(4096), encoding: .utf8), head.contains("<feed"),
              !head.localizedCaseInsensitiveContains("<!DOCTYPE") else { return [] }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.results
    }

    /// The `id_list` query URL for these identifiers (at most 20, no versions: the latest of each).
    public static func url(for sourceIDs: [String]) -> URL? {
        let ids = sourceIDs.prefix(20).map(InterestPool.key)
        guard !ids.isEmpty, ids.allSatisfy({ (try? ArxivReference($0)) != nil }) else { return nil }
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [URLQueryItem(name: "id_list", value: ids.joined(separator: ",")), URLQueryItem(name: "max_results", value: String(ids.count))]
        return components.url
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var results: [DiscoveryResult] = []
        private var inEntry = false, inAuthor = false
        private var text = ""
        private var id = "", title = "", summary = "", published = ""
        private var authors: [String] = [], categories: [String] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "entry": inEntry = true; id = ""; title = ""; summary = ""; published = ""; authors = []; categories = []
            case "author" where inEntry: inAuthor = true
            case "category", "arxiv:primary_category":
                if inEntry, let term = attributes["term"], term.range(of: #"^[a-z\-]{2,16}(\.[A-Za-z\-]{2,8})?$"#, options: .regularExpression) != nil,
                   !categories.contains(term), categories.count < 6 {
                    if name == "arxiv:primary_category" { categories.insert(term, at: 0) } else { categories.append(term) }
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inEntry { text += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard inEntry else { return }
            let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            switch name {
            case "id" where !inAuthor: id = value
            case "title": title = value
            case "summary": summary = value
            case "published": published = value
            case "name" where inAuthor: if !value.isEmpty, value.count <= 256, authors.count < 12 { authors.append(value) }
            case "author": inAuthor = false
            case "entry":
                inEntry = false
                if let match = id.range(of: #"arxiv\.org/abs/(.+)v(\d{1,4})$"#, options: .regularExpression) {
                    let tail = String(id[match]).replacingOccurrences(of: "arxiv.org/abs/", with: "")
                    if let v = tail.range(of: #"v\d{1,4}$"#, options: .regularExpression), let revision = Int(tail[v].dropFirst()) {
                        let sourceID = String(tail[..<v.lowerBound])
                        if (try? ArxivReference(sourceID)) != nil, (1 ... 2_000).contains(title.count) {
                            results.append(DiscoveryResult(sourceID: sourceID, revision: revision, title: title, authors: authors,
                                                           year: Int(published.prefix(4)), abstract: summary.isEmpty ? nil : String(summary.prefix(24_000)),
                                                           categories: categories))
                        }
                    }
                }
            default: break
            }
            text = ""
        }
    }
}

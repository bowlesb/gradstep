import Foundation

/// One arXiv search result from the `discover` function. Presentation only:
/// adding a result goes through the ordinary durable import command.
public struct DiscoveryResult: Decodable, Sendable, Equatable, Identifiable {
    public let sourceID: String
    public let revision: Int
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let abstract: String?
    public let abstractTruncated: Bool
    public let categories: [String]
    public var id: String { sourceID }

    private enum CodingKeys: String, CodingKey {
        case revision, title, authors, year, abstract, categories
        case sourceID = "source_id"
        case fullAbstract = "full_abstract", abstractTruncated = "abstract_truncated"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        revision = try c.decode(Int.self, forKey: .revision)
        title = try c.decode(String.self, forKey: .title)
        authors = try c.decode([String].self, forKey: .authors)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        let preview = try c.decodeIfPresent(String.self, forKey: .abstract)
        let full = try c.decodeIfPresent(String.self, forKey: .fullAbstract)
        abstract = full ?? preview
        abstractTruncated = try c.decodeIfPresent(Bool.self, forKey: .abstractTruncated) ?? (full == nil && (preview?.count ?? 0) >= 700)
        categories = try c.decode([String].self, forKey: .categories)
        guard (try? ArxivReference(sourceID)) != nil, (1...10_000).contains(revision), (1...2_000).contains(title.count),
              authors.count <= 12, authors.allSatisfy({ $0.count <= 256 }), categories.count <= 12,
              (preview?.count ?? 0) <= 2_000, (full?.count ?? 0) <= 24_000 else { throw ReaderError.corruptData }
    }
}

public struct DiscoveryResponse: Decodable, Sendable {
    public let results: [DiscoveryResult]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Skip individually invalid rows; a bad row never hides the others.
        var list = try c.nestedUnkeyedContainer(forKey: .results)
        var results: [DiscoveryResult] = []
        while !list.isAtEnd && results.count < 50 {
            if let value = try? list.decode(DiscoveryResult.self) { results.append(value) } else { _ = try? list.decode(Skip.self) }
        }
        self.results = results
    }
    private enum CodingKeys: String, CodingKey { case results }
    private struct Skip: Decodable {}
}

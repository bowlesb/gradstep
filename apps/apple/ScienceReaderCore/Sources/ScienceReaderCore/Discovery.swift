import Foundation

/// One arXiv search result from the `discover` function. Presentation only:
/// adding a result goes through the ordinary durable import command. Encodable for the Feed's page kept on the device
/// (FeedPages.swift), in the same wire form, so a kept row is read back through the same checks.
public struct DiscoveryResult: Codable, Sendable, Equatable, Identifiable {
    public let sourceID: String
    public let revision: Int
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let abstract: String?
    public let abstractTruncated: Bool
    public let categories: [String]
    /// Specific topics, most specific first (the server's keyword rules over title and abstract; docs/architecture/
    /// PERSONALIZED_FEED.md). Empty from an older server.
    public let topics: [String]
    /// Upvotes on Hugging Face Papers, recorded by the server's shared pool refresh; nil when unknown (not listed
    /// there, not yet seen, or an older server). Never estimated.
    public let upvotes: Int?
    /// Why For you suggests the paper ("In your tag: RLHF"); nil elsewhere.
    public let reason: FeedReason?
    public var id: String { sourceID }

    /// A paper this device read itself (arXiv's export API for related papers): no reason, no popularity.
    public init(sourceID: String, revision: Int, title: String, authors: [String], year: Int?, abstract: String?,
                categories: [String], topics: [String] = []) {
        self.sourceID = sourceID; self.revision = revision; self.title = title; self.authors = authors; self.year = year
        self.abstract = abstract; abstractTruncated = false; self.categories = categories; self.topics = topics
        upvotes = nil; reason = nil
    }

    private enum CodingKeys: String, CodingKey {
        case revision, title, authors, year, abstract, categories, topics, upvotes, reason
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
        // Presentation extras: a malformed value is dropped, never the paper.
        let topicList = (try? c.decodeIfPresent([String].self, forKey: .topics)) ?? nil
        topics = Array((topicList ?? []).filter { !$0.isEmpty && $0.count <= 40 }.prefix(8))
        let votes = (try? c.decodeIfPresent(Int.self, forKey: .upvotes)) ?? nil
        upvotes = votes.flatMap { (0...1_000_000).contains($0) ? $0 : nil }
        reason = (try? c.decodeIfPresent(FeedReason.self, forKey: .reason)) ?? nil
        guard (try? ArxivReference(sourceID)) != nil, (1...10_000).contains(revision), (1...2_000).contains(title.count),
              authors.count <= 12, authors.allSatisfy({ $0.count <= 256 }), categories.count <= 12,
              (preview?.count ?? 0) <= 2_000, (full?.count ?? 0) <= 24_000 else { throw ReaderError.corruptData }
    }

    /// The wire form, with the abstract as `full_abstract` and its truncation said explicitly, so decoding gives back
    /// the same value.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceID, forKey: .sourceID); try c.encode(revision, forKey: .revision)
        try c.encode(title, forKey: .title); try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(abstract, forKey: .fullAbstract); try c.encode(abstractTruncated, forKey: .abstractTruncated)
        try c.encode(categories, forKey: .categories); try c.encode(topics, forKey: .topics)
        try c.encodeIfPresent(upvotes, forKey: .upvotes); try c.encodeIfPresent(reason, forKey: .reason)
    }
}

/// Why For you suggests a paper. The server writes the sentence; `kind` lets the app choose a symbol.
public struct FeedReason: Codable, Sendable, Equatable {
    public let kind: String
    public let label: String
    public let text: String

    private enum CodingKeys: String, CodingKey { case kind, label, text }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        text = try c.decode(String.self, forKey: .text)
        guard kind.range(of: "^[a-z_]{1,24}$", options: .regularExpression) != nil, label.count <= 300,
              (1...200).contains(text.count) else { throw ReaderError.corruptData }
    }
}

/// One of the reader's topic chips (For you's `feed.topics`): a vocabulary topic, one of their own tags, or a
/// curated combination ("RL for reasoning"), with how many pool papers it has.
public struct FeedTopic: Decodable, Sendable, Hashable, Identifiable {
    public let name: String
    public let kind: String
    public let papers: Int?
    public var id: String { name }

    public init(name: String, kind: String = "topic", papers: Int? = nil) { self.name = name; self.kind = kind; self.papers = papers }

    private enum CodingKeys: String, CodingKey { case name, kind, papers }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "topic"
        papers = (try? c.decodeIfPresent(Int.self, forKey: .papers)) ?? nil
        guard (1...40).contains(name.count), name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
              kind.range(of: "^[a-z_]{1,24}$", options: .regularExpression) != nil else { throw ReaderError.corruptData }
    }
}

/// What a Feed response says about For you (`feed`): whether it is offered, and with For you itself, the
/// reader's topic chips; with a topic, which one.
public struct FeedInfo: Decodable, Sendable, Equatable {
    public let forYou: Bool
    public let coldStart: Bool
    public let topics: [FeedTopic]
    public let topic: FeedTopic?

    public init(forYou: Bool, coldStart: Bool = false, topics: [FeedTopic] = [], topic: FeedTopic? = nil) {
        self.forYou = forYou; self.coldStart = coldStart; self.topics = topics; self.topic = topic
    }

    private enum CodingKeys: String, CodingKey { case topics, topic, forYou = "for_you", coldStart = "cold_start" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forYou = (try? c.decodeIfPresent(Bool.self, forKey: .forYou)) ?? false
        coldStart = (try? c.decodeIfPresent(Bool.self, forKey: .coldStart)) ?? false
        var chips: [FeedTopic] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .topics) {
            while !list.isAtEnd && chips.count < 12 {
                if let chip = try? list.decode(FeedTopic.self) {
                    if !chips.contains(where: { $0.name.lowercased() == chip.name.lowercased() }) { chips.append(chip) }
                } else { _ = try? list.decode(Skip.self) }
            }
        }
        topics = chips
        topic = (try? c.decodeIfPresent(FeedTopic.self, forKey: .topic)) ?? nil
    }
    private struct Skip: Decodable {}
}

public struct DiscoveryResponse: Decodable, Sendable {
    public let results: [DiscoveryResult]
    /// Present on Feed responses from a server that offers For you to this reader.
    public let feed: FeedInfo?
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Skip individually invalid rows; a bad row never hides the others.
        var list = try c.nestedUnkeyedContainer(forKey: .results)
        var results: [DiscoveryResult] = []
        while !list.isAtEnd && results.count < 50 {
            if let value = try? list.decode(DiscoveryResult.self) { results.append(value) } else { _ = try? list.decode(Skip.self) }
        }
        self.results = results
        feed = (try? c.decodeIfPresent(FeedInfo.self, forKey: .feed)) ?? nil
    }
    private enum CodingKeys: String, CodingKey { case results, feed }
    private struct Skip: Decodable {}
}

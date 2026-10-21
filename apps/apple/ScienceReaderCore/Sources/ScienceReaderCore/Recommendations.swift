import Foundation

// AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md): the `functions/v1/recommend` request body, its streamed
// events and the client-side bounds that keep a request the server always accepts. Pure: no network, no UI.

/// One paper the server chose and tried to add, as the stream reports it.
public struct RecommendedPaper: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case added, present, failed }
    public let sourceID: String
    public let revision: Int?
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let reason: String
    public let status: Status
    public let importID: UUID?
    public var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", revision, title, authors, year, reason, status, importID = "import_id"
    }
    public init(sourceID: String, revision: Int?, title: String, authors: [String], year: Int?, reason: String, status: Status, importID: UUID?) {
        self.sourceID = sourceID; self.revision = revision; self.title = title; self.authors = authors; self.year = year
        self.reason = reason; self.status = status; self.importID = importID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        title = try c.decode(String.self, forKey: .title)
        authors = (try? c.decodeIfPresent([String].self, forKey: .authors)) ?? []
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
        status = try c.decode(Status.self, forKey: .status)
        importID = (try? c.decodeIfPresent(String.self, forKey: .importID)).flatMap { $0.flatMap(UUID.init(uuidString:)) }
    }
}

public struct RecommendDone: Equatable, Sendable {
    public let added: Int
    public let requested: Int
    public let credits: Int
    public let charged: Bool
    /// `none_related` (nothing close enough) or `not_added` (picks the library couldn't take), only when `added` is 0.
    public let reason: String?
    public init(added: Int, requested: Int, credits: Int, charged: Bool, reason: String?) {
        self.added = added; self.requested = requested; self.credits = credits; self.charged = charged; self.reason = reason
    }
}

public struct RecommendFailure: Equatable, Sendable, Error {
    public let code: String
    public let retryAfter: TimeInterval?
    public init(code: String, retryAfter: TimeInterval? = nil) { self.code = code; self.retryAfter = retryAfter }
}

public enum RecommendEvent: Equatable, Sendable {
    case searching
    case choosing(candidates: Int)
    case paper(ordinal: Int, RecommendedPaper)
    case done(RecommendDone)
    case failed(RecommendFailure)
}

public enum RecommendStreamError: Error, Equatable { case malformed, tooLarge }

/// Reads the function's `text/event-stream`: each `data:` line is one JSON event; comments (`: ping`) and other fields
/// are ignored, and so are event types this build doesn't know.
public struct RecommendSSEParser: Sendable {
    public static let maximumLineBytes = 64 * 1024
    private var line: [UInt8] = []
    public init() {}

    public mutating func consume<Bytes: Sequence>(_ bytes: Bytes) throws -> [RecommendEvent] where Bytes.Element == UInt8 {
        var events: [RecommendEvent] = []
        for byte in bytes {
            if byte == 0x0A || byte == 0x0D {
                if let event = try endLine() { events.append(event) }
                continue
            }
            guard line.count < Self.maximumLineBytes else { throw RecommendStreamError.tooLarge }
            line.append(byte)
        }
        return events
    }

    /// End of input: a final line without its newline still counts.
    public mutating func finish() throws -> [RecommendEvent] {
        let event = try endLine()
        return event.map { [$0] } ?? []
    }

    private mutating func endLine() throws -> RecommendEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        guard line.count > 5, line.starts(with: Array("data:".utf8)) else { return nil }
        var value = line.dropFirst(5)
        if value.first == 0x20 { value = value.dropFirst() }
        return try Self.decode(Data(value))
    }

    public static func decode(_ data: Data) throws -> RecommendEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { throw RecommendStreamError.malformed }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber).map(\.intValue) }
        switch type {
        case "status":
            switch object["phase"] as? String {
            case "searching": return .searching
            case "choosing": return .choosing(candidates: int("candidates") ?? 0)
            default: return nil
            }
        case "paper":
            guard let raw = object["paper"], JSONSerialization.isValidJSONObject(raw) else { throw RecommendStreamError.malformed }
            let paper = try JSONDecoder().decode(RecommendedPaper.self, from: JSONSerialization.data(withJSONObject: raw))
            return .paper(ordinal: int("ordinal") ?? 0, paper)
        case "done":
            return .done(RecommendDone(added: int("added") ?? 0, requested: int("requested") ?? 0, credits: int("credits") ?? 0,
                                       charged: object["charged"] as? Bool ?? false, reason: object["reason"] as? String))
        case "error":
            guard let code = object["code"] as? String, (1...64).contains(code.utf8.count) else { throw RecommendStreamError.malformed }
            return .failed(RecommendFailure(code: code, retryAfter: (object["retry_after"] as? NSNumber)?.doubleValue))
        default: return nil
        }
    }
}

/// The request body (`parseRecommendRequest` on the server is strict; these bounds match it).
public struct RecommendRequestBody: Encodable, Equatable, Sendable {
    public enum Scope: String, Encodable, Sendable { case paper, catalog }
    public struct Seed: Encodable, Equatable, Sendable {
        public let sourceID: String
        public let keywords: [String]
        enum CodingKeys: String, CodingKey { case sourceID = "source_id", keywords }
        public init(sourceID: String, keywords: [String]) { self.sourceID = sourceID; self.keywords = keywords }
    }
    public static let counts = [1, 3, 5]
    public static let maximumCatalogSeeds = 8

    public let operationID: UUID
    public let count: Int
    public let scope: Scope
    public let seeds: [Seed]
    enum CodingKeys: String, CodingKey { case operationID = "operation_id", count, scope, seeds }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID.uuidString.lowercased(), forKey: .operationID)
        try c.encode(count, forKey: .count); try c.encode(scope, forKey: .scope); try c.encode(seeds, forKey: .seeds)
    }

    /// Nil when the request couldn't be accepted (a count other than 1/3/5, no seed, or a paper without a server id).
    public static func make(operationID: UUID, count: Int, scope: Scope, seeds: [(sourceID: String, keywords: [String])]) -> Self? {
        guard counts.contains(count) else { return nil }
        var kept: [Seed] = []
        for seed in seeds where Recommendations.isEligibleSourceID(seed.sourceID) && !kept.contains(where: { $0.sourceID == seed.sourceID }) {
            kept.append(Seed(sourceID: seed.sourceID, keywords: Recommendations.keywords(seed.keywords, limit: scope == .paper ? 6 : 3)))
        }
        kept = Array(kept.prefix(scope == .paper ? 1 : maximumCatalogSeeds))
        guard !kept.isEmpty, scope == .catalog || kept.count == 1 else { return nil }
        return Self(operationID: operationID, count: count, scope: scope, seeds: kept)
    }
}

public enum Recommendations {
    /// Papers the server can seed from: arXiv identifiers and open-access web papers (never local PDFs or uploads).
    public static func isEligibleSourceID(_ value: String) -> Bool {
        value.range(of: #"^(\d{4}\.\d{4,5}|[a-z][a-z0-9.-]*/\d{7}|openalex:W\d{1,12})$"#, options: .regularExpression) != nil
    }

    /// The keywords the reader sees, kept only when the server's grammar accepts them: NFKC, one space between words,
    /// 2–60 characters of letters, digits, spaces and ' ’ . + & / ( ) -, starting with a letter or digit; distinct
    /// ignoring case; at most `limit`.
    public static func keywords(_ names: [String], limit: Int) -> [String] {
        let allowed = Set("'’.+&/()- ")
        var kept: [String] = []
        for name in names {
            let value = name.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard (2...60).contains(value.count), let first = value.first, first.isLetter || first.isNumber,
                  value.allSatisfy({ $0.isLetter || $0.isNumber || allowed.contains($0) }),
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  !kept.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
            kept.append(value)
            if kept.count == limit { break }
        }
        return kept
    }

    /// A catalog's seeds: its most recently added eligible papers, at most eight.
    public static func catalogSeeds<Item>(_ items: [Item], sourceID: (Item) -> String?, addedAt: (Item) -> Date?) -> [Item] {
        Array(items.filter { sourceID($0).map(isEligibleSourceID) == true }
            .sorted { (addedAt($0) ?? .distantPast) > (addedAt($1) ?? .distantPast) }
            .prefix(RecommendRequestBody.maximumCatalogSeeds))
    }

    /// What the reader is told for an error code (docs/architecture/AI_RECOMMENDATIONS.md "Streaming").
    public static func message(for code: String) -> String {
        switch code {
        case "daily_limit": "You’ve asked for recommendations 20 times today. Try again tomorrow."
        case "insufficient_credits": "You’re out of AI credits."
        case "platform_budget_exhausted": "AI features are paused for now. Nothing was charged."
        case "seed_unavailable": "This paper’s details aren’t ready yet. Try again in a minute."
        case "rate_limited": "Too many requests. Try again in a minute."
        case "unavailable": "Recommendations are switched off for now."
        case "connection": "The connection was lost. Papers already shown were added; check your library."
        default: "Recommendations aren’t available right now. Nothing was charged."
        }
    }
}

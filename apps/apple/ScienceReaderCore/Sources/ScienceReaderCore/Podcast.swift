import CryptoKit
import Foundation

// Paper podcasts, v1 client contract (docs/architecture/PAPER_PODCASTS.md, "V1 implementation contract").
// Every server value is bounded and checked here, before the app shows or stores it: an episode list, a
// transcript or a download grant that breaks the contract is refused as a whole rather than partly shown.

/// Shared catalog episode or the account's own private one.
public enum PodcastScope: String, Codable, Sendable { case shared, `private` }

public struct PodcastSource: Codable, Equatable, Sendable {
    public let arxivID: String?
    public let version: Int?
    public let url: URL?
    public let license: URL?
    public init(arxivID: String?, version: Int?, url: URL?, license: URL?) {
        self.arxivID = arxivID; self.version = version; self.url = url; self.license = license
    }
    private enum CodingKeys: String, CodingKey { case version, url, license; case arxivID = "arxiv_id" }
}

/// The verified audio member's identity, shown before the download starts (size) and checked after it.
public struct PodcastAudio: Codable, Equatable, Sendable {
    public let bytes: Int
    public let sha256: String
    public let mediaType: String
    public init(bytes: Int, sha256: String, mediaType: String) { self.bytes = bytes; self.sha256 = sha256; self.mediaType = mediaType }
    private enum CodingKeys: String, CodingKey { case bytes, sha256; case mediaType = "media_type" }
}

public struct PodcastChapter: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let startMS: Int
    public init(id: String, title: String, startMS: Int) { self.id = id; self.title = title; self.startMS = startMS }
    private enum CodingKeys: String, CodingKey { case id, title; case startMS = "start_ms" }
}

/// A verbatim quote from the pinned converted paper. The reader finds it in the paper by its text.
public struct PodcastEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let quote: String
    public let section: String?
    public init(id: String, quote: String, section: String?) { self.id = id; self.quote = quote; self.section = section }

    /// What to look for in the rendered paper. Quotes come from the converted text, which can carry Markdown heading
    /// and emphasis marks and run across a heading into the next block ("# Title ## Abstract We study …"); the page
    /// shows neither the marks nor one block. Search for the longest single-block piece, marks removed.
    public var searchText: String {
        let pieces = quote.components(separatedBy: "\n").flatMap {
            $0.replacingOccurrences(of: #"(^|\s)#{1,6}(?=\s)"#, with: "\u{1F}", options: .regularExpression).components(separatedBy: "\u{1F}")
        }
        let cleaned = pieces.map { piece in
            piece.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return cleaned.max { $0.count < $1.count } ?? quote
    }
}

/// The paper's own notation (displayed) beside how the hosts say it (heard).
public struct PodcastMath: Codable, Equatable, Sendable {
    public let latex: String
    public let spoken: String
    public init(latex: String, spoken: String) { self.latex = latex; self.spoken = spoken }
}

public enum PodcastSpeaker: String, Codable, Sendable { case explainer, skeptic }

public struct PodcastSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let speaker: PodcastSpeaker
    public let text: String
    public let startMS: Int
    public let endMS: Int
    public let chapter: String?
    /// `paper_result`, `author_interpretation`, `explainer_analogy` or `context`; unknown kinds are kept as text.
    public let claimType: String?
    public let evidence: [PodcastEvidence]
    public let math: [PodcastMath]
    public init(id: String, speaker: PodcastSpeaker, text: String, startMS: Int, endMS: Int, chapter: String?,
                claimType: String?, evidence: [PodcastEvidence], math: [PodcastMath] = []) {
        self.id = id; self.speaker = speaker; self.text = text; self.startMS = startMS; self.endMS = endMS
        self.chapter = chapter; self.claimType = claimType; self.evidence = evidence; self.math = math
    }
    private enum CodingKeys: String, CodingKey {
        case id, speaker, text, chapter, evidence, math
        case startMS = "start_ms", endMS = "end_ms", claimType = "claim_type"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); speaker = try c.decode(PodcastSpeaker.self, forKey: .speaker)
        text = try c.decode(String.self, forKey: .text)
        startMS = try c.decode(Int.self, forKey: .startMS); endMS = try c.decode(Int.self, forKey: .endMS)
        chapter = try c.decodeIfPresent(String.self, forKey: .chapter); claimType = try c.decodeIfPresent(String.self, forKey: .claimType)
        evidence = try c.decodeIfPresent([PodcastEvidence].self, forKey: .evidence) ?? []
        math = try c.decodeIfPresent([PodcastMath].self, forKey: .math) ?? []
    }
}

public struct PodcastTranscript: Codable, Equatable, Sendable {
    public struct Speakers: Codable, Equatable, Sendable {
        public let explainer: String
        public let skeptic: String
        public init(explainer: String, skeptic: String) { self.explainer = explainer; self.skeptic = skeptic }
    }
    public let speakers: Speakers
    /// Required AI/adaptation disclosure, shown with the transcript.
    public let disclosure: String
    /// "approximate": segment times are estimated from the audio, not word-aligned.
    public let timing: String
    public let segments: [PodcastSegment]
    public init(speakers: Speakers, disclosure: String, timing: String, segments: [PodcastSegment]) {
        self.speakers = speakers; self.disclosure = disclosure; self.timing = timing; self.segments = segments
    }

    public func name(of speaker: PodcastSpeaker) -> String { speaker == .explainer ? speakers.explainer : speakers.skeptic }

    /// The segment playing at `milliseconds` (the last one started), for highlighting and Now Playing.
    public func segment(at milliseconds: Int) -> PodcastSegment? { segments.last { $0.startMS <= milliseconds } ?? segments.first }
}

/// Server-side state of a release. Unknown values are kept, and treated as not playable.
public enum PodcastReleaseState: Equatable, Sendable, Codable {
    case ready, pendingReview, superseded, quarantined, withdrawn, unavailable, other(String)
    public init(raw: String) {
        switch raw {
        case "ready": self = .ready
        case "pending_review": self = .pendingReview
        case "superseded": self = .superseded
        case "quarantined": self = .quarantined
        case "withdrawn": self = .withdrawn
        case "unavailable": self = .unavailable
        default: self = .other(String(raw.prefix(64)))
        }
    }
    public var raw: String {
        switch self {
        case .ready: "ready"; case .pendingReview: "pending_review"; case .superseded: "superseded"
        case .quarantined: "quarantined"; case .withdrawn: "withdrawn"; case .unavailable: "unavailable"; case .other(let value): value
        }
    }
    /// Playback stops and a downloaded copy is removed (a correction or takedown the device has learned of).
    public var blocksPlayback: Bool { self == .quarantined || self == .withdrawn || self == .unavailable }
    public init(from decoder: any Decoder) throws { self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}

public struct PodcastEpisode: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let scope: PodcastScope
    /// Always present for shared episodes. A private episode's title isn't server-visible (private papers' titles live
    /// in the encrypted library), so the app supplies the library item's own title (`resolvingTitle`).
    public let title: String?
    public let year: Int?
    public let authors: [String]
    public let topic: String?
    public let durationMS: Int
    public let language: String
    public let aiAudio: Bool
    /// Labeled synthetic fixture audio (zero spend). Shown as such everywhere the episode appears.
    public let fixture: Bool
    public let documentID: UUID
    public let publishedAt: String?
    public let state: PodcastReleaseState
    public let source: PodcastSource?
    public let audio: PodcastAudio
    /// Present on the episode call, absent in the catalog.
    public let chapters: [PodcastChapter]?
    public let transcript: PodcastTranscript?
    /// The length it was made at (`podcast-10min-v1`, "10 min", 600). Absent from older servers.
    public let profile: String?
    public let label: String?
    public let targetSeconds: Int?

    public init(id: UUID, scope: PodcastScope, title: String?, year: Int?, authors: [String], topic: String?, durationMS: Int,
                language: String = "en", aiAudio: Bool = true, fixture: Bool, documentID: UUID, publishedAt: String?,
                state: PodcastReleaseState = .ready, source: PodcastSource?, audio: PodcastAudio,
                chapters: [PodcastChapter]? = nil, transcript: PodcastTranscript? = nil,
                profile: String? = nil, label: String? = nil, targetSeconds: Int? = nil) {
        self.id = id; self.scope = scope; self.title = title; self.year = year; self.authors = authors; self.topic = topic
        self.durationMS = durationMS; self.language = language; self.aiAudio = aiAudio; self.fixture = fixture
        self.documentID = documentID; self.publishedAt = publishedAt; self.state = state; self.source = source; self.audio = audio
        self.chapters = chapters; self.transcript = transcript
        self.profile = profile; self.label = label; self.targetSeconds = targetSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case scope, title, year, authors, topic, language, fixture, state, source, audio, chapters, transcript, profile, label
        case id = "release_id", durationMS = "duration_ms", aiAudio = "ai_audio", documentID = "document_id", publishedAt = "published_at"
        case targetSeconds = "target_seconds"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); scope = try c.decode(PodcastScope.self, forKey: .scope)
        title = try c.decodeIfPresent(String.self, forKey: .title); year = try c.decodeIfPresent(Int.self, forKey: .year)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        durationMS = try c.decode(Int.self, forKey: .durationMS)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        aiAudio = try c.decodeIfPresent(Bool.self, forKey: .aiAudio) ?? true
        fixture = try c.decodeIfPresent(Bool.self, forKey: .fixture) ?? false
        documentID = try c.decode(UUID.self, forKey: .documentID)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        state = try c.decodeIfPresent(PodcastReleaseState.self, forKey: .state) ?? .ready
        source = try c.decodeIfPresent(PodcastSource.self, forKey: .source)
        audio = try c.decode(PodcastAudio.self, forKey: .audio)
        chapters = try c.decodeIfPresent([PodcastChapter].self, forKey: .chapters)
        transcript = try c.decodeIfPresent(PodcastTranscript.self, forKey: .transcript)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        targetSeconds = try c.decodeIfPresent(Int.self, forKey: .targetSeconds)
        try validate()
    }

    /// Bounds from the profiles (the twenty-minute profile's 20 MiB audio cap; at most a 34-minute take) with room.
    public static let maximumAudioBytes = 20_971_520
    public static let maximumDurationMS = 3_600_000
    /// Media types a server release may have. WAV is accepted only for labeled fixtures (no encoder run).
    public static let mediaTypes: Set<String> = ["audio/mp4", "audio/aac", "audio/mpeg", "audio/x-m4a"]

    public func validate() throws {
        let fine = { (value: String, limit: Int) in !value.isEmpty && value.utf8.count <= limit }
        guard title.map({ fine($0, 1_000) }) ?? (scope == .private), authors.count <= 200, authors.allSatisfy({ fine($0, 300) }),
              topic.map({ fine($0, 120) }) ?? true, year.map({ (1000...3000).contains($0) }) ?? true,
              (1...Self.maximumDurationMS).contains(durationMS), fine(language, 16), aiAudio,
              (1...Self.maximumAudioBytes).contains(audio.bytes), PodcastHex.isSHA256(audio.sha256),
              Self.mediaTypes.contains(audio.mediaType) || (fixture && audio.mediaType == "audio/wav"),
              (publishedAt?.utf8.count ?? 0) <= 64,
              source.map({ ($0.arxivID?.utf8.count ?? 0) <= 64 && ($0.version.map { (1...10_000).contains($0) } ?? true)
                  && ($0.url.map { $0.scheme == "https" } ?? true) && ($0.license.map { $0.scheme == "https" } ?? true) }) ?? true,
              profile.map(PodcastLength.isProfile) ?? true, label.map({ fine($0, 40) }) ?? true,
              targetSeconds.map({ (30...3_600).contains($0) }) ?? true
        else { throw ReaderError.corruptData }
        if let chapters {
            guard chapters.count <= 100, Set(chapters.map(\.id)).count == chapters.count,
                  chapters.allSatisfy({ fine($0.id, 64) && fine($0.title, 300) && (0...durationMS).contains($0.startMS) }),
                  zip(chapters, chapters.dropFirst()).allSatisfy({ $0.startMS <= $1.startMS }) else { throw ReaderError.corruptData }
        }
        if let transcript {
            let segments = transcript.segments
            guard fine(transcript.speakers.explainer, 120), fine(transcript.speakers.skeptic, 120),
                  fine(transcript.disclosure, 2_000), fine(transcript.timing, 32),
                  (1...2_000).contains(segments.count), Set(segments.map(\.id)).count == segments.count,
                  segments.allSatisfy({ segment in
                      fine(segment.id, 64) && fine(segment.text, 8_000) && segment.startMS >= 0 && segment.startMS <= segment.endMS
                          && segment.endMS <= durationMS + 60_000 && (segment.chapter?.utf8.count ?? 0) <= 64
                          && (segment.claimType?.utf8.count ?? 0) <= 64 && segment.evidence.count <= 16 && segment.math.count <= 16
                          && segment.evidence.allSatisfy { fine($0.id, 64) && fine($0.quote, 2_000) && ($0.section?.utf8.count ?? 0) <= 120 }
                          && segment.math.allSatisfy { fine($0.latex, 2_000) && fine($0.spoken, 2_000) }
                  }),
                  zip(segments, segments.dropFirst()).allSatisfy({ $0.startMS <= $1.startMS }) else { throw ReaderError.corruptData }
        }
    }

    /// What lists and Now Playing show: the server's title, else the one the app resolved, else a neutral name.
    public var displayTitle: String { title ?? (scope == .private ? "Your private episode" : "Paper episode") }

    /// A private episode titled from the account's own library (its title isn't sent by the server). Shared titles stay.
    public func resolvingTitle(_ libraryTitle: String?) -> PodcastEpisode {
        guard title == nil, let libraryTitle, !libraryTitle.isEmpty else { return self }
        return PodcastEpisode(id: id, scope: scope, title: String(libraryTitle.prefix(1_000)), year: year, authors: authors, topic: topic,
                              durationMS: durationMS, language: language, aiAudio: aiAudio, fixture: fixture, documentID: documentID,
                              publishedAt: publishedAt, state: state, source: source, audio: audio, chapters: chapters, transcript: transcript,
                              profile: profile, label: label, targetSeconds: targetSeconds)
    }

    /// The catalog form (no chapters or transcript) of an episode, for lists and the downloads index.
    public var summary: PodcastEpisode {
        PodcastEpisode(id: id, scope: scope, title: title, year: year, authors: authors, topic: topic, durationMS: durationMS,
                       language: language, aiAudio: aiAudio, fixture: fixture, documentID: documentID, publishedAt: publishedAt,
                       state: state, source: source, audio: audio, profile: profile, label: label, targetSeconds: targetSeconds)
    }
}

/// A length offered for private generation (Short, 5, 10, 20 minutes), with its own credit maximum.
/// Who writes the script for a length (2026-10-14): the server lists each allowed writer with its own maximum, the
/// default first. `writer` is the id sent back with the quote request (`anthropic`, `deepseek`).
public struct PodcastWriter: Codable, Equatable, Sendable, Identifiable {
    public let writer: String
    public let label: String
    public let maxCredits: Int
    public let estimate: String?
    public let consentVersion: String?
    public var id: String { writer }
    public init(writer: String, label: String, maxCredits: Int, estimate: String? = nil, consentVersion: String? = nil) {
        self.writer = writer; self.label = label; self.maxCredits = maxCredits; self.estimate = estimate; self.consentVersion = consentVersion
    }
    private enum CodingKeys: String, CodingKey { case writer, label, estimate; case maxCredits = "max_credits", consentVersion = "consent_version" }
}

public struct PodcastLength: Codable, Equatable, Sendable, Identifiable {
    public let profile: String
    public let label: String
    public let targetSeconds: Int
    public let maxCredits: Int
    public let estimate: String?
    /// The writers offered for this length (servers from 2026-10-14; empty before), the default first.
    public var writers: [PodcastWriter]
    public var id: String { profile }
    public static let defaultProfile = "podcast-5min-v1"
    public init(profile: String, label: String, targetSeconds: Int, maxCredits: Int, estimate: String? = nil, writers: [PodcastWriter] = []) {
        self.profile = profile; self.label = label; self.targetSeconds = targetSeconds; self.maxCredits = maxCredits; self.estimate = estimate; self.writers = writers
    }
    /// The maximum for a writer, else the length's own (the default writer's).
    public func maxCredits(for writer: String?) -> Int { writers.first { $0.writer == writer }?.maxCredits ?? maxCredits }
    private enum CodingKeys: String, CodingKey { case profile, label, estimate, writers; case targetSeconds = "target_seconds", maxCredits = "max_credits" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(String.self, forKey: .profile); label = try c.decode(String.self, forKey: .label)
        targetSeconds = try c.decode(Int.self, forKey: .targetSeconds); maxCredits = try c.decode(Int.self, forKey: .maxCredits)
        estimate = try c.decodeIfPresent(String.self, forKey: .estimate)
        guard Self.isProfile(profile), !label.isEmpty, label.utf8.count <= 40, (30...3_600).contains(targetSeconds),
              (1...10_000).contains(maxCredits), (estimate?.utf8.count ?? 0) <= 300 else { throw ReaderError.corruptData }
        writers = (try? c.decodeIfPresent([PodcastWriter].self, forKey: .writers)) ?? []
    }
    static func isProfile(_ value: String) -> Bool { value.range(of: "^[a-z][a-z0-9-]{2,47}$", options: .regularExpression) != nil }
}

enum PodcastHex {
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct PodcastTransfer: Codable, Equatable, Sendable {
    public let remainingBytes: Int
    public let limitBytes: Int
    public init(remainingBytes: Int, limitBytes: Int) { self.remainingBytes = remainingBytes; self.limitBytes = limitBytes }
    private enum CodingKeys: String, CodingKey { case remainingBytes = "remaining_bytes", limitBytes = "limit_bytes" }
}

/// What the server offers now. Absent or false means unavailable: reading continues; there is no fallback.
public struct PodcastCapabilities: Codable, Equatable, Sendable {
    public let catalog: Bool
    public let generation: Bool
    public let delivery: Bool
    public let maxCredits: Int
    public let targetSeconds: Int
    public let transfer: PodcastTransfer?
    /// Lengths offered for private generation, shortest first (empty from older servers: five minutes only).
    public let lengths: [PodcastLength]
    public init(catalog: Bool, generation: Bool, delivery: Bool, maxCredits: Int = 150, targetSeconds: Int = 300, transfer: PodcastTransfer? = nil,
                lengths: [PodcastLength] = []) {
        self.catalog = catalog; self.generation = generation; self.delivery = delivery
        self.maxCredits = maxCredits; self.targetSeconds = targetSeconds; self.transfer = transfer; self.lengths = lengths
    }
    public static let unavailable = PodcastCapabilities(catalog: false, generation: false, delivery: false)
    private enum CodingKeys: String, CodingKey {
        case catalog, generation, delivery, transfer, lengths
        case maxCredits = "max_credits", targetSeconds = "target_seconds"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalog = try c.decodeIfPresent(Bool.self, forKey: .catalog) ?? false
        generation = try c.decodeIfPresent(Bool.self, forKey: .generation) ?? false
        delivery = try c.decodeIfPresent(Bool.self, forKey: .delivery) ?? false
        maxCredits = try c.decodeIfPresent(Int.self, forKey: .maxCredits) ?? 150
        targetSeconds = try c.decodeIfPresent(Int.self, forKey: .targetSeconds) ?? 300
        transfer = try c.decodeIfPresent(PodcastTransfer.self, forKey: .transfer)
        lengths = try c.decodeIfPresent([PodcastLength].self, forKey: .lengths) ?? []
        guard (1...10_000).contains(maxCredits), (30...3_600).contains(targetSeconds), lengths.count <= 8,
              Set(lengths.map(\.profile)).count == lengths.count,
              transfer.map({ $0.remainingBytes >= 0 && $0.limitBytes >= 0 }) ?? true else { throw ReaderError.corruptData }
    }
}

public struct PodcastCatalogPage: Codable, Equatable, Sendable {
    public let episodes: [PodcastEpisode]
    public let next: String?
    public let capabilities: PodcastCapabilities?
    public init(episodes: [PodcastEpisode], next: String?, capabilities: PodcastCapabilities?) {
        self.episodes = episodes; self.next = next; self.capabilities = capabilities
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try c.decode([PodcastEpisode].self, forKey: .episodes)
        next = try c.decodeIfPresent(String.self, forKey: .next)
        capabilities = try c.decodeIfPresent(PodcastCapabilities.self, forKey: .capabilities)
        guard episodes.count <= 50, Set(episodes.map(\.id)).count == episodes.count, (next?.utf8.count ?? 0) <= 512 else { throw ReaderError.corruptData }
    }
}

/// The explicit quote shown before any private generation; nothing is held until Start.
public struct PodcastQuote: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let expiresAt: String
    public let maxCredits: Int
    public let estimate: String
    public let providers: [String]
    public let consentVersion: String
    public let targetSeconds: Int
    /// The quoted length (absent from older servers: five minutes).
    public let profile: String?
    public let label: String?
    /// The writer the quote resolved to and its name (servers from 2026-10-14).
    public let writer: String?
    public let writerLabel: String?
    /// Every offered length with its own maximum, as listed beside the quote.
    public var options: [PodcastLength]
    public init(id: UUID, expiresAt: String, maxCredits: Int, estimate: String, providers: [String], consentVersion: String, targetSeconds: Int,
                profile: String? = nil, label: String? = nil, options: [PodcastLength] = [], writer: String? = nil, writerLabel: String? = nil) {
        self.id = id; self.expiresAt = expiresAt; self.maxCredits = maxCredits; self.estimate = estimate
        self.providers = providers; self.consentVersion = consentVersion; self.targetSeconds = targetSeconds
        self.profile = profile; self.label = label; self.options = options; self.writer = writer; self.writerLabel = writerLabel
    }
    private enum CodingKeys: String, CodingKey {
        case id, estimate, providers, profile, label, writer
        case expiresAt = "expires_at", maxCredits = "max_credits", consentVersion = "consent_version", targetSeconds = "target_seconds", writerLabel = "writer_label"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); expiresAt = try c.decode(String.self, forKey: .expiresAt)
        maxCredits = try c.decode(Int.self, forKey: .maxCredits); estimate = try c.decode(String.self, forKey: .estimate)
        providers = try c.decode([String].self, forKey: .providers); consentVersion = try c.decode(String.self, forKey: .consentVersion)
        targetSeconds = try c.decodeIfPresent(Int.self, forKey: .targetSeconds) ?? 300
        profile = try c.decodeIfPresent(String.self, forKey: .profile); label = try c.decodeIfPresent(String.self, forKey: .label)
        writer = try c.decodeIfPresent(String.self, forKey: .writer); writerLabel = try c.decodeIfPresent(String.self, forKey: .writerLabel)
        options = []
        guard profile.map(PodcastLength.isProfile) ?? true, (label?.utf8.count ?? 0) <= 40,
              (1...10_000).contains(maxCredits), !estimate.isEmpty, estimate.utf8.count <= 300, expiresAt.utf8.count <= 64,
              (1...8).contains(providers.count), providers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 120 }),
              consentVersion.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil,
              (30...3_600).contains(targetSeconds) else { throw ReaderError.corruptData }
    }
}

public enum PodcastQuoteOutcome: Equatable, Sendable {
    /// A new quote to show (and consent to) before Start.
    case quote(PodcastQuote)
    /// This exact episode is already ready for this account: play it, no new charge.
    case reuse(releaseID: UUID)
    /// An identical generation is already running for this account (another device): follow it.
    case join(requestID: UUID)
}

extension PodcastQuoteOutcome: Decodable {
    private enum CodingKeys: String, CodingKey { case quote, reuse, join, options }
    private struct Reuse: Decodable { let release_id: UUID }
    private struct Join: Decodable { let request_id: UUID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let present = [c.contains(.quote), c.contains(.reuse), c.contains(.join)].filter { $0 }.count
        guard present == 1 else { throw ReaderError.corruptData }
        if var quote = try c.decodeIfPresent(PodcastQuote.self, forKey: .quote) {
            quote.options = try c.decodeIfPresent([PodcastLength].self, forKey: .options) ?? []
            guard quote.options.count <= 8 else { throw ReaderError.corruptData }
            self = .quote(quote)
        }
        else if let reuse = try c.decodeIfPresent(Reuse.self, forKey: .reuse) { self = .reuse(releaseID: reuse.release_id) }
        else { self = .join(requestID: try c.decode(Join.self, forKey: .join).request_id) }
    }
}

public enum PodcastJobState: Equatable, Sendable, Codable {
    case queued, scripting, checking, synthesizing, verifying, publishing, ready
    case canceled, failed, capacityWait, unknownProvider, quarantined
    case other(String)

    public init(raw: String) {
        switch raw {
        case "queued": self = .queued; case "scripting": self = .scripting; case "checking": self = .checking
        case "synthesizing": self = .synthesizing; case "verifying": self = .verifying; case "publishing": self = .publishing
        case "ready": self = .ready; case "canceled": self = .canceled; case "failed": self = .failed
        case "capacity_wait": self = .capacityWait; case "unknown_provider": self = .unknownProvider; case "quarantined": self = .quarantined
        default: self = .other(String(raw.prefix(64)))
        }
    }
    public var raw: String {
        switch self {
        case .queued: "queued"; case .scripting: "scripting"; case .checking: "checking"; case .synthesizing: "synthesizing"
        case .verifying: "verifying"; case .publishing: "publishing"; case .ready: "ready"; case .canceled: "canceled"
        case .failed: "failed"; case .capacityWait: "capacity_wait"; case .unknownProvider: "unknown_provider"
        case .quarantined: "quarantined"; case .other(let value): value
        }
    }
    /// Still moving on the server: keep polling (an unknown state is polled too, never assumed finished).
    public var isActive: Bool {
        switch self {
        case .queued, .scripting, .checking, .synthesizing, .verifying, .publishing, .capacityWait, .other: true
        case .ready, .canceled, .failed, .unknownProvider, .quarantined: false
        }
    }
    /// Cancel is offered until the job reaches a terminal or held state.
    public var canCancel: Bool { isActive && self != .capacityWait }
    public init(from decoder: any Decoder) throws { self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}

/// A private generation as the server reports it. Charges are shown only when the server states them.
public struct PodcastJob: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let state: PodcastJobState
    public let stageEnteredAt: String?
    public let releaseID: UUID?
    public let heldCredits: Int
    public let chargedCredits: Int?
    public let releasedCredits: Int?
    public let failure: String?
    /// Cancel was asked for and the server is stopping further work (a provider call may still be finishing).
    public let cancelRequested: Bool
    /// The length being made (absent from older servers).
    public let profile: String?
    public init(requestID: UUID, state: PodcastJobState, stageEnteredAt: String?, releaseID: UUID?, heldCredits: Int,
                chargedCredits: Int?, releasedCredits: Int?, failure: String?, cancelRequested: Bool = false, profile: String? = nil) {
        self.requestID = requestID; self.state = state; self.stageEnteredAt = stageEnteredAt; self.releaseID = releaseID
        self.heldCredits = heldCredits; self.chargedCredits = chargedCredits; self.releasedCredits = releasedCredits; self.failure = failure
        self.cancelRequested = cancelRequested; self.profile = profile
    }
    private enum CodingKeys: String, CodingKey {
        case state, failure, profile
        case requestID = "request_id", stageEnteredAt = "stage_entered_at", releaseID = "release_id"
        case heldCredits = "held_credits", chargedCredits = "charged_credits", releasedCredits = "released_credits"
        case cancelRequested = "cancel_requested"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(UUID.self, forKey: .requestID); state = try c.decode(PodcastJobState.self, forKey: .state)
        stageEnteredAt = try c.decodeIfPresent(String.self, forKey: .stageEnteredAt)
        releaseID = try c.decodeIfPresent(UUID.self, forKey: .releaseID)
        heldCredits = try c.decodeIfPresent(Int.self, forKey: .heldCredits) ?? 0
        chargedCredits = try c.decodeIfPresent(Int.self, forKey: .chargedCredits)
        releasedCredits = try c.decodeIfPresent(Int.self, forKey: .releasedCredits)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        cancelRequested = try c.decodeIfPresent(Bool.self, forKey: .cancelRequested) ?? false
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        let credits = { (value: Int?) in value.map { (0...10_000).contains($0) } ?? true }
        guard (0...10_000).contains(heldCredits), credits(chargedCredits), credits(releasedCredits), profile.map(PodcastLength.isProfile) ?? true,
              (stageEnteredAt?.utf8.count ?? 0) <= 64,
              failure.map({ $0.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil }) ?? true,
              state != .ready || releaseID != nil else { throw ReaderError.corruptData }
    }
}

/// What start, status and cancel return: the job, or — when an identical episode became ready for this account
/// meanwhile (another device, an earlier request) — that release to play with no new charge.
public enum PodcastJobOutcome: Equatable, Sendable, Decodable {
    case job(PodcastJob)
    case reuse(releaseID: UUID)

    private enum CodingKeys: String, CodingKey { case job, reuse }
    private struct Reuse: Decodable { let release_id: UUID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let job = try c.decodeIfPresent(PodcastJob.self, forKey: .job), reuse = try c.decodeIfPresent(Reuse.self, forKey: .reuse)
        switch (job, reuse) {
        case (let job?, nil): self = .job(job)
        case (nil, let reuse?): self = .reuse(releaseID: reuse.release_id)
        default: throw ReaderError.corruptData
        }
    }
}

/// One member of a single-use download grant on the configured backend origin.
public struct PodcastMember: Codable, Equatable, Sendable {
    public let role: String
    public let url: URL
    public let bytes: Int
    public let sha256: String
    public let mediaType: String
    public init(role: String, url: URL, bytes: Int, sha256: String, mediaType: String) {
        self.role = role; self.url = url; self.bytes = bytes; self.sha256 = sha256; self.mediaType = mediaType
    }
    private enum CodingKeys: String, CodingKey { case role, url, bytes, sha256; case mediaType = "media_type" }
}

public struct PodcastGrant: Codable, Equatable, Sendable {
    public let expiresAt: String
    public let members: [PodcastMember]
    public init(expiresAt: String, members: [PodcastMember]) { self.expiresAt = expiresAt; self.members = members }
    private enum CodingKeys: String, CodingKey { case members; case expiresAt = "expires_at" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expiresAt = try c.decode(String.self, forKey: .expiresAt); members = try c.decode([PodcastMember].self, forKey: .members)
        guard expiresAt.utf8.count <= 64, (1...8).contains(members.count), Set(members.map(\.role)).count == members.count,
              members.allSatisfy({ (1...PodcastEpisode.maximumAudioBytes).contains($0.bytes) && PodcastHex.isSHA256($0.sha256)
                  && $0.role.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil && $0.mediaType.utf8.count <= 120 }),
              members.contains(where: { $0.role == "audio" }) else { throw ReaderError.corruptData }
    }
    public var audio: PodcastMember? { members.first { $0.role == "audio" } }
}

public struct PodcastReleaseStatus: Codable, Equatable, Sendable {
    public let state: PodcastReleaseState
    public let replacementID: UUID?
    public init(state: PodcastReleaseState, replacementID: UUID?) { self.state = state; self.replacementID = replacementID }
    private enum CodingKeys: String, CodingKey { case state; case replacementID = "replacement_id" }
}

/// `GET ?action=paper`: what Listen on one library paper can do now.
public struct PodcastPaperLookup: Codable, Equatable, Sendable {
    public let episode: PodcastEpisode?
    /// Every ready length of this paper (each length is its own episode), shortest first; empty from older servers.
    public let episodes: [PodcastEpisode]
    public let job: PodcastJob?
    public let capabilities: PodcastCapabilities?
    public init(episode: PodcastEpisode?, episodes: [PodcastEpisode] = [], job: PodcastJob?, capabilities: PodcastCapabilities?) {
        self.episode = episode; self.episodes = episodes; self.job = job; self.capabilities = capabilities
    }
    private enum CodingKeys: String, CodingKey { case episode, episodes, job, capabilities }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episode = try c.decodeIfPresent(PodcastEpisode.self, forKey: .episode)
        episodes = try c.decodeIfPresent([PodcastEpisode].self, forKey: .episodes) ?? []
        job = try c.decodeIfPresent(PodcastJob.self, forKey: .job)
        capabilities = try c.decodeIfPresent(PodcastCapabilities.self, forKey: .capabilities)
        guard episodes.count <= 8, Set(episodes.map(\.id)).count == episodes.count else { throw ReaderError.corruptData }
    }
}

public enum PodcastMemberTransport {
    /// Only the configured origin's single-use member endpoint receives the account's bearer token.
    public static func validated(_ url: URL, backendURL: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host == backendURL.host, parts.port == backendURL.port, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.path == "/functions/v1/podcast-member" else { throw ReaderError.corruptData }
        let query = parts.queryItems ?? []
        guard query.count == 2, Set(query.map(\.name)) == ["grant", "member"],
              let grant = query.first(where: { $0.name == "grant" })?.value, PodcastHex.isSHA256(grant),
              let member = query.first(where: { $0.name == "member" })?.value, UUID(uuidString: member) != nil else { throw ReaderError.corruptData }
    }
}

public enum PodcastAudioVerification {
    /// "Downloaded" requires every byte: exact length, then the SHA-256 the grant (and episode) named.
    public static func verify(_ data: Data, bytes: Int, sha256: String) throws {
        guard data.count == bytes, Data(SHA256.hash(data: data)).hex == sha256 else { throw ReaderError.corruptData }
    }

    /// The same check for a file already on disk (before playing a kept download).
    public static func verify(fileAt url: URL, bytes: Int, sha256: String) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == bytes else { throw ReaderError.corruptData }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256(), total = 0
        while let chunk = try handle.read(upToCount: 262_144), !chunk.isEmpty {
            total += chunk.count
            guard total <= bytes else { throw ReaderError.corruptData }
            hasher.update(data: chunk)
        }
        guard total == bytes, Data(hasher.finalize()).hex == sha256 else { throw ReaderError.corruptData }
    }
}

public enum PodcastDuration {
    /// "5 min", "1 hr 2 min", "45 sec": whole minutes for lists.
    public static func short(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }

    /// "2:05", "1:02:05": a player clock.
    public static func clock(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// VoiceOver: "2 minutes 5 seconds".
    public static func spoken(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full; formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
    }
}

/// The paper's own text on this device, for a private episode (migration 066): the numbered context the chat sends,
/// with the library's title and author names. Uploaded once per account and digest; the quote names it by digest.
public struct PodcastDeviceSource: Equatable, Sendable {
    public static let format = "paper-context-v2"
    public let context: LocalPaperChatContext
    public let title: String
    public let authors: [String]
    public init(context: LocalPaperChatContext, title: String, authors: [String]) {
        self.context = context; self.title = String(title.prefix(500)); self.authors = Array(authors.prefix(20).map { String($0.prefix(200)) })
    }
    /// What the quote names once the text is stored: identity and digest, never the text.
    public func descriptor(textSHA256: String) -> PodcastDeviceDescriptor {
        PodcastDeviceDescriptor(sourceID: context.sourceID, revision: context.revision, manifestSHA256: context.manifestSHA256,
                                textSHA256: textSHA256, title: title.isEmpty ? nil : title, authors: authors)
    }
}

/// The quote's `device_source`: the paper's identity and the stored text's digest.
public struct PodcastDeviceDescriptor: Equatable, Sendable {
    public let source = "arxiv"
    public let sourceID: String
    public let revision: Int
    public let manifestSHA256: String
    public let textSHA256: String
    public let title: String?
    public let authors: [String]
    public init(sourceID: String, revision: Int, manifestSHA256: String, textSHA256: String, title: String?, authors: [String]) {
        self.sourceID = sourceID; self.revision = revision; self.manifestSHA256 = manifestSHA256; self.textSHA256 = textSHA256
        self.title = title; self.authors = authors
    }
    /// The wire object (sorted keys when serialized).
    public var body: [String: Any] {
        var value: [String: Any] = ["source": source, "source_id": sourceID, "revision": revision, "manifest_sha256": manifestSHA256,
                                    "text_sha256": textSHA256, "authors": authors]
        if let title { value["title"] = title }
        return value
    }
}

#if DEBUG && FIXTURE_HOST
import CryptoKit
import Foundation
import ScienceReaderCore

/// Zero-spend podcast fixture for Simulator/Mac UI journeys (`--podcast-fixture`). Every episode is labeled
/// "Synthetic fixture" and `fixture: true`; its audio is tones generated on the device (one pitch per host, with the
/// transcript's timing), never a recording, a provider call or a network request. Compiled out of device and release
/// builds. Evidence quotes are verbatim sentences from the bundled offline sample paper, so the transcript's evidence
/// jump exercises the real passage finder.
actor PodcastFixtureTransport: PodcastTransport {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--podcast-fixture") }
    static let sampleDocument = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    static let sampleRelease = UUID(uuidString: "fa000000-0000-4000-8000-000000000001")!
    static let attentionRelease = UUID(uuidString: "fa000000-0000-4000-8000-000000000002")!
    static let fixtureAccount = UUID(uuidString: "fa000000-0000-4000-8000-0000000000ac")!

    enum GenerationMode { case succeeds, fails }
    private let generation: GenerationMode
    private let empty: Bool
    private var episodes: [UUID: (episode: PodcastEpisode, audio: Data)] = [:]
    private var jobs: [UUID: (itemID: UUID, steps: Int, releaseID: UUID?)] = [:]
    private var quotes: [UUID: UUID] = [:]

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        generation = arguments.contains("--podcast-fixture-generation=fail") ? .fails : .succeeds
        empty = arguments.contains("--podcast-fixture-empty")
        for spec in Self.catalogSpecs { let built = Self.build(spec); episodes[built.episode.id] = built }
    }

    private static let capabilities = PodcastCapabilities(catalog: true, generation: true, delivery: true, maxCredits: 150, targetSeconds: 300,
                                                          transfer: PodcastTransfer(remainingBytes: 104_857_600, limitBytes: 104_857_600))

    func catalog(after: String?, limit: Int) async throws -> PodcastCatalogPage {
        try await Task.sleep(for: .milliseconds(150))
        let order = Self.catalogSpecs.map(\.id)
        let shared = empty ? [] : order.compactMap { episodes[$0]?.episode }.filter { $0.scope == .shared }
        return PodcastCatalogPage(episodes: shared.map(\.summary), next: nil, capabilities: Self.capabilities)
    }

    func episode(_ releaseID: UUID) async throws -> PodcastEpisode {
        guard let entry = episodes[releaseID] else { throw BackendError.rejected("release_unavailable") }
        return entry.episode
    }

    func paper(itemID: UUID) async throws -> PodcastPaperLookup {
        // Fixture papers have no server item: the "item" is the document itself.
        let episode = empty ? nil : episodes.values.map(\.episode).first { $0.documentID == itemID }
        let job = jobs.first { $0.value.itemID == itemID && $0.value.releaseID == nil }.map { Self.job($0.key, steps: $0.value.steps, mode: generation) }
        return PodcastPaperLookup(episode: episode?.summary, job: job, capabilities: Self.capabilities)
    }

    func quote(itemID: UUID, requestID: UUID) async throws -> PodcastQuoteOutcome {
        if let existing = episodes.values.map(\.episode).first(where: { $0.documentID == itemID }) { return .reuse(releaseID: existing.id) }
        let id = UUID(); quotes[id] = itemID
        return .quote(PodcastQuote(id: id, expiresAt: "2026-10-08T12:15:00Z", maxCredits: 150,
                                   estimate: "Estimate — you're charged actual usage, maximum 150 credits",
                                   providers: ["Anthropic (script)", "Google Vertex AI (speech)"], consentVersion: "podcast-private-v1", targetSeconds: 300))
    }

    func start(quoteID: UUID, requestID: UUID, consentVersion: String) async throws -> PodcastJob {
        guard consentVersion == "podcast-private-v1" else { throw BackendError.rejected("consent_required") }
        guard let itemID = quotes.removeValue(forKey: quoteID) else { throw BackendError.rejected("quote_expired") }
        jobs[requestID] = (itemID, 0, nil)
        return Self.job(requestID, steps: 0, mode: generation)
    }

    func status(requestID: UUID) async throws -> PodcastJob {
        guard var job = jobs[requestID] else { throw BackendError.rejected("job_unavailable") }
        if job.steps < 7, job.releaseID == nil { job.steps += 1 }
        if job.steps >= 7, generation == .succeeds, job.releaseID == nil {
            let built = Self.build(Self.privateSpec(document: job.itemID))
            episodes[built.episode.id] = built; job.releaseID = built.episode.id
        }
        jobs[requestID] = job
        return Self.job(requestID, steps: job.steps, mode: generation, releaseID: job.releaseID)
    }

    func cancel(requestID: UUID) async throws -> PodcastJob {
        guard jobs[requestID] != nil else { throw BackendError.rejected("job_unavailable") }
        jobs[requestID]?.steps = -1
        return PodcastJob(requestID: requestID, state: .canceled, stageEnteredAt: nil, releaseID: nil, heldCredits: 150,
                          chargedCredits: 0, releasedCredits: 150, failure: nil)
    }

    func download(_ releaseID: UUID) async throws -> PodcastGrant {
        guard let entry = episodes[releaseID] else { throw BackendError.rejected("release_unavailable") }
        let url = URL(string: "https://fixture.invalid/functions/v1/podcast-member?grant=\(String(repeating: "f", count: 64))&member=\(releaseID.wire)")!
        return PodcastGrant(expiresAt: "2026-10-08T12:15:00Z", members: [PodcastMember(role: "audio", url: url, bytes: entry.audio.count,
                                                                                         sha256: entry.episode.audio.sha256, mediaType: "audio/wav")])
    }

    func states(_ releaseIDs: [UUID]) async throws -> [UUID: PodcastReleaseStatus] {
        Dictionary(uniqueKeysWithValues: releaseIDs.map { ($0, PodcastReleaseStatus(state: episodes[$0] == nil ? .unavailable : .ready, replacementID: nil)) })
    }

    func member(_ member: PodcastMember, progress: @escaping @Sendable (Int) -> Void) async throws -> Data {
        guard let id = URLComponents(url: member.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "member" })?.value
                .flatMap(UUID.init(uuidString:)), let entry = episodes[id] else { throw BackendError.rejected("podcast_grant_unavailable") }
        // A visible download: a few steps of progress, as a real transfer would show.
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(200)); progress(entry.audio.count * step / 4)
        }
        return entry.audio
    }

    // MARK: Fixture content

    private static func job(_ id: UUID, steps: Int, mode: GenerationMode, releaseID: UUID? = nil) -> PodcastJob {
        let states: [PodcastJobState] = [.queued, .scripting, .checking, .synthesizing, .verifying, .publishing, .publishing, .ready]
        if steps < 0 { return PodcastJob(requestID: id, state: .canceled, stageEnteredAt: nil, releaseID: nil, heldCredits: 150, chargedCredits: 0, releasedCredits: 150, failure: nil) }
        if steps >= 7 {
            return mode == .fails
                ? PodcastJob(requestID: id, state: .failed, stageEnteredAt: nil, releaseID: nil, heldCredits: 150, chargedCredits: 0, releasedCredits: 150, failure: "quality_rejected")
                : PodcastJob(requestID: id, state: .ready, stageEnteredAt: nil, releaseID: releaseID, heldCredits: 150, chargedCredits: 46, releasedCredits: 104, failure: nil)
        }
        return PodcastJob(requestID: id, state: states[steps], stageEnteredAt: "2026-10-08T12:00:00Z", releaseID: nil, heldCredits: 150,
                          chargedCredits: nil, releasedCredits: nil, failure: nil)
    }

    struct Line { let speaker: PodcastSpeaker; let text: String; let seconds: Double; var chapter: String? = nil; var evidence: [String] = []; var math: [PodcastMath] = [] }
    struct Spec { let id: UUID; let scope: PodcastScope; let document: UUID; let title: String?; let year: Int?; let topic: String?
        let authors: [String]; let source: PodcastSource?; let chapters: [(String, String)]; let lines: [Line] }

    static let catalogSpecs: [Spec] = [
        Spec(id: sampleRelease, scope: .shared, document: sampleDocument, title: "Synthetic fixture: Reading machine learning papers", year: 2026,
             topic: "Reading methods", authors: ["Gradstep offline sample"], source: nil,
             chapters: [("c1", "How to read a paper"), ("c2", "The attention equation"), ("c3", "Checking the evaluation")], lines: [
                Line(speaker: .explainer, text: "This is a labeled synthetic fixture: the tones stand in for two hosts. A first pass looks for the problem, the method and the evidence.",
                     seconds: 7, chapter: "c1", evidence: ["A useful first pass identifies the problem, the proposed method, and the evidence."]),
                Line(speaker: .skeptic, text: "And it keeps what the authors claim apart from what they actually measured?", seconds: 5, chapter: "c1",
                     evidence: ["Separate the authors’ claims from the measurements that support them."]),
                Line(speaker: .explainer, text: "Right. In the attention equation, the scores are divided by the square root of the key dimension.", seconds: 7, chapter: "c2",
                     evidence: ["The normalization in Equation (1) matters because the scale of raw compatibility scores changes with the key dimension."],
                     math: [PodcastMath(latex: "\\operatorname{softmax}\\!\\left(\\frac{QK^{\\mathsf T}}{\\sqrt{d_k}}\\right)V", spoken: "softmax of Q K transpose over the square root of d k, times V")]),
                Line(speaker: .skeptic, text: "The worked matrix isn't a result, though. The sample says so itself.", seconds: 5, chapter: "c2",
                     evidence: ["These numbers illustrate layout and row normalization; they are not measurements from a trained model."]),
                Line(speaker: .explainer, text: "For evaluation, compare the same split and protocol, and look at variation across runs.", seconds: 6, chapter: "c3",
                     evidence: ["Check variation across runs, not only the best run."]),
                Line(speaker: .skeptic, text: "And read an ablation as evidence about one component, not proof of everything.", seconds: 6, chapter: "c3",
                     evidence: ["Read an ablation as evidence about a component, not proof of every claim."]),
             ]),
        Spec(id: attentionRelease, scope: .shared, document: UUID(uuidString: "fa000000-0000-4000-8000-0000000000d2")!,
             title: "Synthetic fixture: Attention Is All You Need", year: 2017, topic: "Natural language processing",
             authors: ["Ashish Vaswani", "Noam Shazeer"],
             source: PodcastSource(arxivID: "1706.03762", version: 7, url: URL(string: "https://arxiv.org/abs/1706.03762v7"),
                                   license: URL(string: "https://arxiv.org/licenses/nonexclusive-distrib/1.0/")),
             chapters: [("c1", "The architecture")], lines: [
                Line(speaker: .explainer, text: "A labeled synthetic fixture about a paper that isn't in this library.", seconds: 6, chapter: "c1",
                     evidence: ["The Transformer, based solely on attention mechanisms"]),
                Line(speaker: .skeptic, text: "Its evidence links open the source, with an explicit Add.", seconds: 5, chapter: "c1"),
             ]),
    ]

    static func privateSpec(document: UUID) -> Spec {
        Spec(id: UUID(), scope: .private, document: document, title: nil, year: nil, topic: nil,
             authors: [], source: nil, chapters: [("c1", "Summary")], lines: [
                Line(speaker: .explainer, text: "A labeled synthetic private episode, made with zero spend.", seconds: 5, chapter: "c1"),
                Line(speaker: .skeptic, text: "Only this account can play it.", seconds: 4, chapter: "c1"),
             ])
    }

    static func build(_ spec: Spec) -> (episode: PodcastEpisode, audio: Data) {
        let gap = 0.35
        var segments: [PodcastSegment] = [], tones: [(PodcastSpeaker, Double, Double)] = [], time = 0.4
        for (index, line) in spec.lines.enumerated() {
            let start = time, end = time + line.seconds
            segments.append(PodcastSegment(id: "s\(index + 1)", speaker: line.speaker, text: line.text, startMS: Int(start * 1000), endMS: Int(end * 1000),
                                           chapter: line.chapter, claimType: line.evidence.isEmpty ? "context" : "paper_result",
                                           evidence: line.evidence.enumerated().map { PodcastEvidence(id: "e\(index + 1)-\($0.offset + 1)", quote: $0.element, section: nil) },
                                           math: line.math))
            tones.append((line.speaker, start, end)); time = end + gap
        }
        let audio = wav(tones: tones, duration: time + 0.4)
        let chapterStarts = spec.chapters.map { chapter in PodcastChapter(id: chapter.0, title: chapter.1,
            startMS: segments.first { $0.chapter == chapter.0 }?.startMS ?? 0) }
        let durationMS = Int((time + 0.4) * 1000)
        let episode = PodcastEpisode(id: spec.id, scope: spec.scope, title: spec.title, year: spec.year, authors: spec.authors, topic: spec.topic,
            durationMS: durationMS, fixture: true, documentID: spec.document, publishedAt: "2026-10-08T12:00:00Z", source: spec.source,
            audio: PodcastAudio(bytes: audio.count, sha256: Data(SHA256.hash(data: audio)).hex, mediaType: "audio/wav"),
            chapters: chapterStarts,
            transcript: PodcastTranscript(speakers: .init(explainer: "Host 1 — explainer", skeptic: "Host 2 — skeptical reader"),
                                          disclosure: "Synthetic fixture: tones, not a recording. Real episodes are AI-generated audio adapted from the paper.",
                                          timing: "approximate", segments: segments))
        return (episode, audio)
    }

    /// 16-bit mono PCM at 16 kHz: a soft tone per host (explainer lower, skeptic higher), pulsed like syllables.
    static func wav(tones: [(PodcastSpeaker, Double, Double)], duration: Double) -> Data {
        let rate = 16_000, count = Int(duration * Double(rate))
        var samples = [Int16](repeating: 0, count: count)
        for (speaker, start, end) in tones {
            let frequency = speaker == .explainer ? 196.0 : 294.0
            let first = Int(start * Double(rate)), last = min(count, Int(end * Double(rate)))
            guard first < last else { continue }
            for index in first..<last {
                let t = Double(index - first) / Double(rate), remaining = Double(last - index) / Double(rate)
                let edge = min(1, t / 0.03, remaining / 0.03)
                let syllable = 0.55 + 0.45 * sin(2 * .pi * 3.7 * t)
                let value = 0.18 * edge * syllable * sin(2 * .pi * frequency * t)
                samples[index] = Int16(max(-1, min(1, value)) * Double(Int16.max))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        // Apple platforms are little-endian, as WAV is.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
#endif

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
    /// `--podcast-fixture-credits=N`: the account's available credits, so the Listen sheet's balance line and the
    /// greyed-out lengths can be checked without a backend (absent: the balance is unknown, nothing is greyed out).
    static func fixtureCredits(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int64? {
        arguments.first { $0.hasPrefix("--podcast-fixture-credits=") }.flatMap { Int64($0.dropFirst("--podcast-fixture-credits=".count)) }
    }

    enum GenerationMode { case succeeds, fails, sourceTooLarge }
    private let generation: GenerationMode
    private let empty: Bool
    /// `--podcast-fixture-outcome-pending`: the previous private episode's provider outcome is unresolved (quote refused).
    private let outcomePending: Bool
    /// `--podcast-fixture-catalog-fault=always|after-first` (RESILIENCE.md fault fixtures): the catalog fails every
    /// time (as a server error), or after a first good page (as a busy server), to show the last-good list.
    private let catalogFault: String?
    /// `--podcast-fixture-steps=N`: checks of a request before it settles (7 by default), so a journey can leave while
    /// an episode is still being made and come back to it.
    private let readyAt: Int
    private var catalogCalls = 0
    private var episodes: [UUID: (episode: PodcastEpisode, audio: Data)] = [:]
    private var jobs: [UUID: (itemID: UUID, steps: Int, releaseID: UUID?, length: PodcastLength)] = [:]
    private var quotes: [UUID: (itemID: UUID, length: PodcastLength)] = [:]
    /// Requests in the order they were made, and private episodes newest first (Listen's own section, migration 076).
    private var requestOrder: [UUID] = []
    private var privateOrder: [UUID] = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        generation = arguments.contains("--podcast-fixture-generation=source-too-large") ? .sourceTooLarge
            : arguments.contains("--podcast-fixture-generation=fail") ? .fails : .succeeds
        empty = arguments.contains("--podcast-fixture-empty")
        outcomePending = arguments.contains("--podcast-fixture-outcome-pending")
        catalogFault = arguments.first { $0.hasPrefix("--podcast-fixture-catalog-fault=") }.map { String($0.dropFirst("--podcast-fixture-catalog-fault=".count)) }
        readyAt = arguments.first { $0.hasPrefix("--podcast-fixture-steps=") }.flatMap { Int($0.dropFirst("--podcast-fixture-steps=".count)) }.map { max(7, min($0, 200)) } ?? 7
        for spec in Self.catalogSpecs { let built = Self.build(spec); episodes[built.episode.id] = built }
    }

    /// The server's four lengths and their maximums (migration 052's serving-limit profiles, as staging serves them).
    // Version-3 maxima (migration 062: the script repair call), as staging quotes since 2026-10-14.
    static let lengths = [("podcast-short-v1", "Short", 150, 140), ("podcast-5min-v1", "5 min", 300, 150),
                          ("podcast-10min-v1", "10 min", 600, 300), ("podcast-20min-v1", "20 min", 1200, 520)]
        .map { PodcastLength(profile: $0.0, label: $0.1, targetSeconds: $0.2, maxCredits: $0.3,
                             estimate: "Estimate — you're charged actual usage, maximum \($0.3) credits",
                             writers: writers(profile: $0.0, deepseek: $0.3)) }
    private static let capabilities = PodcastCapabilities(catalog: true, generation: true, delivery: true, maxCredits: 150, targetSeconds: 300,
                                                          transfer: PodcastTransfer(remainingBytes: 104_857_600, limitBytes: 104_857_600),
                                                          lengths: lengths)
    private static func length(_ profile: String?) -> PodcastLength? { lengths.first { $0.profile == (profile ?? PodcastLength.defaultProfile) } }

    func catalog(after: String?, limit: Int) async throws -> PodcastCatalogPage {
        try await Task.sleep(for: .milliseconds(150))
        catalogCalls += 1
        if catalogFault == "always" { throw BackendError.rejected("request_failed") }
        if catalogFault == "after-first", catalogCalls > 1 { throw BackendError.throttled(retryAfter: 30) }
        let order = Self.catalogSpecs.map(\.id)
        let shared = empty ? [] : order.compactMap { episodes[$0]?.episode }.filter { $0.scope == .shared }
        // Work goes on while nobody watches: each check of the list moves the account's requests along too.
        for requestID in requestOrder { advance(requestID) }
        return PodcastCatalogPage(episodes: shared.map(\.summary), next: nil, capabilities: Self.capabilities, mine: after == nil ? mine() : nil)
    }

    /// The account's ready private episodes (newest first) and its requests being made, or that couldn't be made until it
    /// asks again for that paper; titles are left to the library, as the server leaves a private paper's title.
    private func mine() -> PodcastMine {
        var requests: [PodcastMine.Request] = []
        for (index, requestID) in requestOrder.enumerated().reversed() {
            guard let job = jobs[requestID], job.releaseID == nil, job.steps >= 0 else { continue }
            let later = requestOrder[(index + 1)...].contains { jobs[$0]?.itemID == job.itemID }
            let state = Self.job(requestID, steps: job.steps, mode: generation, length: job.length, readyAt: readyAt)
            if state.state.isActive {
                requests.append(PodcastMine.Request(requestID: requestID, status: "making", profile: job.length.profile, label: job.length.label,
                                                    targetSeconds: job.length.targetSeconds, documentID: job.itemID))
            } else if state.state == .failed, !later {
                requests.append(PodcastMine.Request(requestID: requestID, status: "failed", failure: state.failure, profile: job.length.profile,
                                                    label: job.length.label, targetSeconds: job.length.targetSeconds, documentID: job.itemID))
            }
        }
        let made = Dictionary(jobs.compactMap { entry in entry.value.releaseID.map { ($0, entry.key) } }, uniquingKeysWith: { first, _ in first })
        return PodcastMine(episodes: privateOrder.reversed().compactMap { episodes[$0]?.episode.summary }, requests: requests, madeBy: made)
    }

    /// One step of a request's work; the last makes its episode (or settles its failure).
    private func advance(_ requestID: UUID) {
        guard var job = jobs[requestID], job.steps >= 0 else { return }
        if job.steps < readyAt, job.releaseID == nil { job.steps += 1 }
        if job.steps >= readyAt, generation == .succeeds, job.releaseID == nil {
            let built = Self.build(Self.privateSpec(document: job.itemID, length: job.length))
            episodes[built.episode.id] = built; job.releaseID = built.episode.id; privateOrder.append(built.episode.id)
        }
        jobs[requestID] = job
    }

    func episode(_ releaseID: UUID) async throws -> PodcastEpisode {
        guard let entry = episodes[releaseID] else { throw BackendError.rejected("podcast_release_unavailable") }
        return entry.episode
    }

    func paper(itemID: UUID) async throws -> PodcastPaperLookup {
        // Fixture papers have no server item: the "item" is the document itself. Every ready length, shortest first.
        let ready = empty ? [] : episodes.values.map(\.episode).filter { $0.documentID == itemID }
            .sorted { ($0.targetSeconds ?? 300, $0.id.uuidString) < ($1.targetSeconds ?? 300, $1.id.uuidString) }
        let episode = ready.first { $0.scope == .private } ?? ready.first
        let job = jobs.first { $0.value.itemID == itemID && $0.value.releaseID == nil && $0.value.steps >= 0 }
            .map { Self.job($0.key, steps: $0.value.steps, mode: generation, length: $0.value.length, readyAt: readyAt) }
        return PodcastPaperLookup(episode: episode?.summary, episodes: ready.map(\.summary), job: job, capabilities: Self.capabilities)
    }

    /// The writers every fixture length offers (2026-10-14): DeepSeek first (the policy's default), Sonnet at its own maxima.
    static func writers(profile: String, deepseek: Int) -> [PodcastWriter] {
        let sonnet = ["podcast-short-v1": 180, "podcast-5min-v1": 200, "podcast-10min-v1": 360, "podcast-20min-v1": 610][profile] ?? deepseek
        return [PodcastWriter(writer: "deepseek", label: "DeepSeek V4 Pro", maxCredits: deepseek, consentVersion: "podcast-private-v2"),
                PodcastWriter(writer: "anthropic", label: "Claude Sonnet 5.5", maxCredits: sonnet, consentVersion: "podcast-private-v1")]
    }
    func uploadSource(_ source: PodcastDeviceSource) async throws -> String { String(repeating: "d", count: 64) }
    func quote(itemID: UUID, requestID: UUID, profile: String?, writer: String?, device: PodcastDeviceDescriptor?) async throws -> PodcastQuoteOutcome {
        if outcomePending { throw BackendError.rejected("podcast_outcome_pending") }
        guard let length = Self.length(profile) else { throw BackendError.rejected("podcast_profile_unavailable") }
        // Each length is its own episode: only the same length is reused.
        if let existing = episodes.values.map(\.episode).first(where: { $0.documentID == itemID && ($0.profile ?? PodcastLength.defaultProfile) == length.profile }) {
            return .reuse(releaseID: existing.id)
        }
        // The chosen writer (the default when none): its maximum, its provider label and its consent version, as the server quotes.
        guard let chosen = length.writers.first(where: { $0.writer == (writer ?? length.writers.first?.writer) }) else { throw BackendError.rejected("podcast_writer_unavailable") }
        let id = UUID(); quotes[id] = (itemID, length)
        return .quote(PodcastQuote(id: id, expiresAt: "2026-10-08T12:15:00Z", maxCredits: chosen.maxCredits,
                                   estimate: "Estimate — you're charged actual usage, maximum \(chosen.maxCredits) credits",
                                   providers: [chosen.writer == "deepseek" ? "DeepSeek (script)" : "Anthropic (script)", "Google Vertex AI (speech)"],
                                   consentVersion: chosen.consentVersion ?? "podcast-private-v1",
                                   targetSeconds: length.targetSeconds, profile: length.profile, label: length.label, options: Self.lengths,
                                   writer: chosen.writer, writerLabel: chosen.label))
    }

    func start(quoteID: UUID, requestID: UUID, consentVersion: String) async throws -> PodcastJobOutcome {
        guard ["podcast-private-v1", "podcast-private-v2"].contains(consentVersion) else { throw BackendError.rejected("consent_required") }
        guard let quote = quotes.removeValue(forKey: quoteID) else { throw BackendError.rejected("quote_expired") }
        jobs[requestID] = (quote.itemID, 0, nil, quote.length); requestOrder.append(requestID)
        return .job(Self.job(requestID, steps: 0, mode: generation, length: quote.length, readyAt: readyAt))
    }

    func status(requestID: UUID) async throws -> PodcastJobOutcome {
        guard jobs[requestID] != nil else { throw BackendError.rejected("podcast_request_unavailable") }
        advance(requestID)
        let job = jobs[requestID]!
        return .job(Self.job(requestID, steps: job.steps, mode: generation, releaseID: job.releaseID, length: job.length, readyAt: readyAt))
    }

    func cancel(requestID: UUID) async throws -> PodcastJobOutcome {
        guard let job = jobs[requestID] else { throw BackendError.rejected("podcast_request_unavailable") }
        jobs[requestID]?.steps = -1
        return .job(PodcastJob(requestID: requestID, state: .canceled, stageEnteredAt: nil, releaseID: nil, heldCredits: job.length.maxCredits,
                          chargedCredits: 0, releasedCredits: job.length.maxCredits, failure: nil, profile: job.length.profile))
    }

    func download(_ releaseID: UUID) async throws -> PodcastGrant {
        guard let entry = episodes[releaseID] else { throw BackendError.rejected("podcast_release_unavailable") }
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

    private static func job(_ id: UUID, steps: Int, mode: GenerationMode, releaseID: UUID? = nil, length: PodcastLength, readyAt: Int = 7) -> PodcastJob {
        let states: [PodcastJobState] = [.queued, .scripting, .checking, .synthesizing, .verifying, .publishing, .publishing, .ready]
        let held = length.maxCredits, profile = length.profile
        if steps < 0 { return PodcastJob(requestID: id, state: .canceled, stageEnteredAt: nil, releaseID: nil, heldCredits: held, chargedCredits: 0, releasedCredits: held, failure: nil, profile: profile) }
        if steps >= readyAt {
            // Five minutes charges 46 of 150 (the journeys' figure); other lengths about the same share of their maximum.
            let charged = length.profile == PodcastLength.defaultProfile ? 46 : held * 3 / 10
            switch mode {
            case .fails:
                return PodcastJob(requestID: id, state: .failed, stageEnteredAt: nil, releaseID: nil, heldCredits: held, chargedCredits: 0, releasedCredits: held, failure: "quality_rejected", profile: profile)
            case .sourceTooLarge:
                return PodcastJob(requestID: id, state: .failed, stageEnteredAt: nil, releaseID: nil, heldCredits: held, chargedCredits: 0, releasedCredits: held, failure: "source_too_large", profile: profile)
            case .succeeds:
                return PodcastJob(requestID: id, state: .ready, stageEnteredAt: nil, releaseID: releaseID, heldCredits: held, chargedCredits: charged, releasedCredits: held - charged, failure: nil, profile: profile)
            }
        }
        return PodcastJob(requestID: id, state: states[steps * 7 / readyAt], stageEnteredAt: "2026-10-08T12:00:00Z", releaseID: nil, heldCredits: held,
                          chargedCredits: nil, releasedCredits: nil, failure: nil, profile: profile)
    }

    struct Line { let speaker: PodcastSpeaker; let text: String; let seconds: Double; var chapter: String? = nil; var evidence: [String] = []; var math: [PodcastMath] = [] }
    struct Spec { let id: UUID; let scope: PodcastScope; let document: UUID; let title: String?; let year: Int?; let topic: String?
        let authors: [String]; let source: PodcastSource?; let chapters: [(String, String)]; let lines: [Line]
        var length: PodcastLength = PodcastFixtureTransport.length(nil)! }

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

    static func privateSpec(document: UUID, length: PodcastLength) -> Spec {
        Spec(id: UUID(), scope: .private, document: document, title: nil, year: nil, topic: nil,
             authors: [], source: nil, chapters: [("c1", "Summary")], lines: [
                Line(speaker: .explainer, text: "A labeled synthetic private episode, made with zero spend.", seconds: 5, chapter: "c1"),
                Line(speaker: .skeptic, text: "Only this account can play it.", seconds: 4, chapter: "c1"),
             ], length: length)
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
                                          timing: "approximate", segments: segments),
            profile: spec.length.profile, label: spec.length.label, targetSeconds: spec.length.targetSeconds)
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

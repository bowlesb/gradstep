import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// The v1 client contract (docs/architecture/PAPER_PODCASTS.md) and device-local listening history.
struct PodcastContractTests {
    static let release = "11111111-2222-4333-8444-555555555555"
    static let document = "aaaaaaaa-0000-0000-0000-000000000001"
    static let sha = String(repeating: "ab", count: 32)

    static func episodeJSON(extra: String = "", audio: String? = nil) -> String {
        """
        {"release_id":"\(release)","scope":"shared","title":"Attention as a reading exercise","year":2026,"authors":["A. Author","B. Author"],
         "topic":"Machine learning","duration_ms":301234,"language":"en","ai_audio":true,"fixture":false,"document_id":"\(document)",
         "published_at":"2026-10-08T12:00:00Z","state":"ready",
         "source":{"arxiv_id":"2410.03401","version":1,"url":"https://arxiv.org/abs/2410.03401v1","license":"https://creativecommons.org/licenses/by/4.0/"},
         "audio":\(audio ?? #"{"bytes":2400000,"sha256":"\#(sha)","media_type":"audio/mp4"}"#)\(extra)}
        """
    }

    static let transcriptJSON = """
    ,"chapters":[{"id":"c1","title":"The question","start_ms":0},{"id":"c2","title":"The evidence","start_ms":120000}],
    "transcript":{"speakers":{"explainer":"Host 1 — explainer","skeptic":"Host 2 — skeptical reader"},
     "disclosure":"AI-generated audio adapted from the paper.","timing":"approximate",
     "segments":[{"id":"s1","speaker":"explainer","text":"Start with the question.","start_ms":0,"end_ms":5000,"chapter":"c1",
       "claim_type":"context","evidence":[{"id":"e1","quote":"A useful first pass identifies the problem","section":"1"}],
       "math":[{"latex":"\\\\sqrt{d_k}","spoken":"the square root of d k"}]},
      {"id":"s2","speaker":"skeptic","text":"What supports it?","start_ms":5000,"end_ms":9000,"chapter":"c1","claim_type":"paper_result","evidence":[]}]}
    """

    @Test func decodesCatalogEpisodeAndFullEpisode() throws {
        let page = try JSONDecoder().decode(PodcastCatalogPage.self, from: Data("""
        {"episodes":[\(Self.episodeJSON())],"next":null,"capabilities":{"catalog":true,"generation":false,"delivery":true,"max_credits":150,
         "target_seconds":300,"transfer":{"remaining_bytes":104857600,"limit_bytes":104857600}}}
        """.utf8))
        #expect(page.episodes.count == 1)
        #expect(page.episodes[0].id == UUID(uuidString: Self.release))
        #expect(page.episodes[0].chapters == nil && page.episodes[0].transcript == nil)
        #expect(page.capabilities?.generation == false && page.capabilities?.transfer?.limitBytes == 104_857_600)

        let full = try JSONDecoder().decode(PodcastEpisode.self, from: Data(Self.episodeJSON(extra: Self.transcriptJSON).utf8))
        #expect(full.chapters?.map(\.id) == ["c1", "c2"])
        #expect(full.transcript?.segments.first?.evidence.first?.quote == "A useful first pass identifies the problem")
        #expect(full.transcript?.segments.first?.math.first?.latex == "\\sqrt{d_k}")
        #expect(full.transcript?.segment(at: 6_000)?.id == "s2")
        #expect(full.transcript?.name(of: .skeptic) == "Host 2 — skeptical reader")
        // The downloads index stores the full episode and reads it back through the same validation.
        let round = try JSONDecoder().decode(PodcastEpisode.self, from: JSONEncoder().encode(full))
        #expect(round == full)
        #expect(full.summary.transcript == nil)
    }

    @Test func refusesOutOfContractEpisodes() {
        let bad = [
            Self.episodeJSON(audio: #"{"bytes":0,"sha256":"\#(Self.sha)","media_type":"audio/mp4"}"#),
            Self.episodeJSON(audio: #"{"bytes":20000000,"sha256":"\#(Self.sha)","media_type":"audio/mp4"}"#),
            Self.episodeJSON(audio: #"{"bytes":100,"sha256":"ABCD","media_type":"audio/mp4"}"#),
            // WAV is only for labeled fixtures.
            Self.episodeJSON(audio: #"{"bytes":100,"sha256":"\#(Self.sha)","media_type":"audio/wav"}"#),
            Self.episodeJSON(audio: #"{"bytes":100,"sha256":"\#(Self.sha)","media_type":"text/html"}"#),
            Self.episodeJSON(extra: #","chapters":[{"id":"c1","title":"Late","start_ms":999999999}]"#),
        ]
        for json in bad { #expect(throws: (any Error).self) { try JSONDecoder().decode(PodcastEpisode.self, from: Data(json.utf8)) } }
        let fixture = Self.episodeJSON(audio: #"{"bytes":100,"sha256":"\#(Self.sha)","media_type":"audio/wav"}"#).replacingOccurrences(of: #""fixture":false"#, with: #""fixture":true"#)
        #expect((try? JSONDecoder().decode(PodcastEpisode.self, from: Data(fixture.utf8)))?.fixture == true)
    }

    @Test func privateEpisodesMayOmitServerInvisibleMetadata() throws {
        // A private paper's title (and year, authors, topic, source) isn't server-visible: the app titles it itself.
        let json = """
        {"release_id":"\(Self.release)","scope":"private","title":null,"year":null,"authors":null,"topic":null,"duration_ms":300000,
         "ai_audio":true,"fixture":false,"document_id":"\(Self.document)","state":"ready","source":null,
         "audio":{"bytes":2400000,"sha256":"\(Self.sha)","media_type":"audio/mp4"}}
        """
        let episode = try JSONDecoder().decode(PodcastEpisode.self, from: Data(json.utf8))
        #expect(episode.title == nil && episode.authors.isEmpty && episode.displayTitle == "Your private episode")
        let titled = episode.resolvingTitle("My uploaded draft")
        #expect(titled.displayTitle == "My uploaded draft" && titled.audio == episode.audio)
        // A shared episode always carries its title.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PodcastEpisode.self, from: Data(json.replacingOccurrences(of: #""scope":"private""#, with: #""scope":"shared""#).utf8))
        }
        // An explicit server title is never replaced by a library title.
        let shared = try JSONDecoder().decode(PodcastEpisode.self, from: Data(Self.episodeJSON().utf8))
        #expect(shared.resolvingTitle("Something else").title == "Attention as a reading exercise")
    }

    @Test func quoteOutcomesAreExclusive() throws {
        let quote = try JSONDecoder().decode(PodcastQuoteOutcome.self, from: Data("""
        {"quote":{"id":"\(Self.release)","expires_at":"2026-10-08T12:15:00Z","max_credits":150,
         "estimate":"Estimate — you're charged actual usage, maximum 150 credits","providers":["Anthropic (script)","Google Vertex AI (speech)"],
         "consent_version":"podcast-private-v1","target_seconds":300}}
        """.utf8))
        guard case .quote(let value) = quote else { Issue.record("expected a quote"); return }
        #expect(value.maxCredits == 150 && value.providers.count == 2 && value.consentVersion == "podcast-private-v1")
        #expect(try JSONDecoder().decode(PodcastQuoteOutcome.self, from: Data(#"{"reuse":{"release_id":"\#(Self.release)"}}"#.utf8))
                == .reuse(releaseID: UUID(uuidString: Self.release)!))
        #expect(try JSONDecoder().decode(PodcastQuoteOutcome.self, from: Data(#"{"join":{"request_id":"\#(Self.release)"}}"#.utf8))
                == .join(requestID: UUID(uuidString: Self.release)!))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PodcastQuoteOutcome.self, from: Data(#"{"reuse":{"release_id":"\#(Self.release)"},"join":{"request_id":"\#(Self.release)"}}"#.utf8))
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PodcastQuoteOutcome.self, from: Data("{}".utf8)) }
    }

    @Test func jobStatesNeverAssumeCompletion() throws {
        let running = try JSONDecoder().decode(PodcastJob.self, from: Data(#"{"request_id":"\#(Self.release)","state":"synthesizing","stage_entered_at":"2026-10-08T12:00:00Z","release_id":null,"held_credits":150,"charged_credits":null,"released_credits":null,"failure":null}"#.utf8))
        #expect(running.state == .synthesizing && running.state.isActive && running.state.canCancel && running.heldCredits == 150)
        let future = try JSONDecoder().decode(PodcastJob.self, from: Data(#"{"request_id":"\#(Self.release)","state":"reviewing_v2","held_credits":150}"#.utf8))
        #expect(future.state == .other("reviewing_v2") && future.state.isActive)
        let failed = try JSONDecoder().decode(PodcastJob.self, from: Data(#"{"request_id":"\#(Self.release)","state":"failed","held_credits":150,"charged_credits":0,"released_credits":150,"failure":"quality_rejected"}"#.utf8))
        #expect(!failed.state.isActive && failed.chargedCredits == 0 && failed.failure == "quality_rejected")
        // Ready without a release, or prose in `failure`, is out of contract.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PodcastJob.self, from: Data(#"{"request_id":"\#(Self.release)","state":"ready","held_credits":1}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PodcastJob.self, from: Data(#"{"request_id":"\#(Self.release)","state":"failed","held_credits":1,"failure":"Server said: no"}"#.utf8)) }
    }

    @Test func grantsAndMemberURLsStayOnTheBackendOrigin() throws {
        let backend = URL(string: "https://example.supabase.co")!
        let grant = String(repeating: "c", count: 64)
        let good = URL(string: "https://example.supabase.co/functions/v1/podcast-member?grant=\(grant)&member=\(Self.release)")!
        try PodcastMemberTransport.validated(good, backendURL: backend)
        for bad in ["https://evil.example/functions/v1/podcast-member?grant=\(grant)&member=\(Self.release)",
                    "http://example.supabase.co/functions/v1/podcast-member?grant=\(grant)&member=\(Self.release)",
                    "https://example.supabase.co/functions/v1/reader-member?grant=\(grant)&member=\(Self.release)",
                    "https://example.supabase.co/functions/v1/podcast-member?grant=\(grant)&member=\(Self.release)&extra=1",
                    "https://example.supabase.co/functions/v1/podcast-member?grant=XYZ&member=\(Self.release)"] {
            #expect(throws: (any Error).self) { try PodcastMemberTransport.validated(URL(string: bad)!, backendURL: backend) }
        }
        let decoded = try JSONDecoder().decode(PodcastGrant.self, from: Data("""
        {"expires_at":"2026-10-08T12:15:00Z","members":[{"role":"audio","url":"\(good.absoluteString)","bytes":2400000,"sha256":"\(Self.sha)","media_type":"audio/mp4"}]}
        """.utf8))
        #expect(decoded.audio?.bytes == 2_400_000)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PodcastGrant.self, from: Data(#"{"expires_at":"x","members":[{"role":"transcript","url":"\#(good.absoluteString)","bytes":1,"sha256":"\#(Self.sha)","media_type":"application/json"}]}"#.utf8))
        }
    }

    @Test func releaseStatesBlockPlaybackWhenWithdrawn() throws {
        let states = try JSONDecoder().decode([String: PodcastReleaseStatus].self, from: Data(#"{"a":{"state":"quarantined","replacement_id":null},"b":{"state":"superseded","replacement_id":"\#(Self.release)"},"c":{"state":"later_state"}}"#.utf8))
        #expect(states["a"]?.state.blocksPlayback == true)
        #expect(states["b"]?.state.blocksPlayback == false && states["b"]?.replacementID == UUID(uuidString: Self.release))
        #expect(states["c"]?.state == .other("later_state"))
    }

    @Test func audioVerificationNeedsEveryByte() throws {
        let data = Data((0..<4096).map { UInt8($0 % 251) })
        let digest = Data(SHA256.hash(data: data)).hex
        try PodcastAudioVerification.verify(data, bytes: data.count, sha256: digest)
        #expect(throws: (any Error).self) { try PodcastAudioVerification.verify(data.dropLast(), bytes: data.count, sha256: digest) }
        #expect(throws: (any Error).self) { try PodcastAudioVerification.verify(data, bytes: data.count, sha256: String(repeating: "0", count: 64)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        try PodcastAudioVerification.verify(fileAt: file, bytes: data.count, sha256: digest)
        var changed = data; changed[10] ^= 1; try changed.write(to: file)
        #expect(throws: (any Error).self) { try PodcastAudioVerification.verify(fileAt: file, bytes: data.count, sha256: digest) }
    }

    @Test func durationsReadNaturally() {
        #expect(PodcastDuration.short(milliseconds: 301_234) == "5 min")
        #expect(PodcastDuration.short(milliseconds: 45_000) == "45 sec")
        #expect(PodcastDuration.clock(milliseconds: 125_900) == "2:05")
        #expect(PodcastDuration.clock(milliseconds: 3_725_000) == "1:02:05")
    }
}

/// Responses captured from the real SQL + Edge handlers (tests/fixtures/podcast, committed by the backend work): the
/// native models decode every one, including a private episode with no server-visible title, unordered keys,
/// microsecond timestamps with numeric offsets, `cancel_requested` and `replacement_id`.
struct PodcastServerFixtureTests {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // ScienceReaderCore
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // repository root
        .appendingPathComponent("tests/fixtures/podcast", isDirectory: true)

    func load(_ name: String) throws -> Data { try Data(contentsOf: Self.folder.appendingPathComponent("\(name).json")) }

    @Test func catalogAndEpisode() throws {
        let page = try JSONDecoder().decode(PodcastCatalogPage.self, from: load("catalog"))
        #expect(page.episodes.count == 2 && page.next == nil)
        #expect(page.capabilities == PodcastCapabilities(catalog: true, generation: true, delivery: true, maxCredits: 150, targetSeconds: 300,
                                                         transfer: PodcastTransfer(remainingBytes: 104_857_600, limitBytes: 104_857_600)))
        #expect(page.episodes.map(\.fixture) == [false, true])
        // Microsecond timestamps with a numeric offset, as the server writes them (values change per capture).
        #expect(page.episodes[0].topic == "cs.LG" && page.episodes[0].publishedAt?.hasSuffix("+00:00") == true)
        struct Wrapped: Decodable { let episode: PodcastEpisode }
        let episode = try JSONDecoder().decode(Wrapped.self, from: load("episode")).episode
        #expect(episode.id == page.episodes[0].id && episode.audio == page.episodes[0].audio)
        #expect(episode.chapters?.map(\.id) == ["c1", "c2", "c3"])
        #expect(episode.transcript?.segments.count == 14 && episode.transcript?.timing == "approximate")
        #expect(episode.transcript?.segments.allSatisfy { $0.endMS <= episode.durationMS } == true)
        // The backend checker only accepts plain quotes from one paragraph (no headings or Markdown marks), so the
        // search text is the quote itself; the mark stripping below remains a defence for older or imported releases.
        let first = try #require(episode.transcript?.segments.first?.evidence.first)
        #expect(first.quote == "We study a synthetic routing method for journey tests only.")
        #expect(first.searchText == first.quote)
        #expect(PodcastEvidence(id: "e", quote: "## Method\nWe route tokens by a learned temperature.", section: nil).searchText
                == "We route tokens by a learned temperature.")
        #expect(PodcastEvidence(id: "e", quote: "Check variation across runs, not only the best run.", section: nil).searchText
                == "Check variation across runs, not only the best run.")
        #expect(PodcastEvidence(id: "e", quote: "The **ablation** removes the gate.", section: nil).searchText == "The ablation removes the gate.")
    }

    @Test func paperLookupsSharedAndPrivate() throws {
        let shared = try JSONDecoder().decode(PodcastPaperLookup.self, from: load("paper"))
        #expect(shared.job == nil && shared.episode?.scope == .shared && shared.episode?.title == "Journey fixture paper")
        let privateLookup = try JSONDecoder().decode(PodcastPaperLookup.self, from: load("paper_2"))
        let episode = try #require(privateLookup.episode)
        #expect(episode.scope == .private && episode.title == nil && episode.year == nil && episode.topic == nil && episode.authors.isEmpty)
        #expect(episode.source?.url == nil && episode.source?.arxivID == nil)
        #expect(episode.resolvingTitle("My own paper").displayTitle == "My own paper")
        #expect(privateLookup.capabilities?.generation == true)
    }

    @Test func quoteStartStatusDownloadStates() throws {
        guard case .quote(let quote) = try JSONDecoder().decode(PodcastQuoteOutcome.self, from: load("quote")) else {
            Issue.record("a quote"); return
        }
        #expect(quote.maxCredits == 150 && quote.consentVersion == "podcast-private-v1" && quote.expiresAt.hasSuffix("+00:00"))
        guard case .job(let started) = try JSONDecoder().decode(PodcastJobOutcome.self, from: load("start")) else { Issue.record("a job"); return }
        #expect(started.state == .queued && started.heldCredits == 150 && !started.cancelRequested && started.chargedCredits == nil)
        guard case .job(let ready) = try JSONDecoder().decode(PodcastJobOutcome.self, from: load("status")) else { Issue.record("a job"); return }
        #expect(ready.state == .ready && ready.releaseID != nil && ready.chargedCredits == 38 && ready.releasedCredits == 112 && ready.heldCredits == 0)
        #expect(ready.requestID == started.requestID)
        // start/status may answer with a ready release instead of a job.
        #expect(try JSONDecoder().decode(PodcastJobOutcome.self, from: Data(#"{"reuse":{"release_id":"\#(PodcastContractTests.release)"}}"#.utf8))
                == .reuse(releaseID: UUID(uuidString: PodcastContractTests.release)!))
        struct Grant: Decodable { let grant: PodcastGrant }
        let grant = try JSONDecoder().decode(Grant.self, from: load("download")).grant
        try PodcastMemberTransport.validated(try #require(grant.audio).url, backendURL: URL(string: "https://project.supabase.co")!)
        struct States: Decodable { let states: [String: PodcastReleaseStatus] }
        let states = try JSONDecoder().decode(States.self, from: load("states")).states
        #expect(states.count == 2 && states.values.contains { $0.state == .unavailable && $0.state.blocksPlayback })
    }
}

struct PodcastPlaybackLedgerTests {
    let release = UUID()
    let phone = UUID(), tablet = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func seekingBackwardsIsKept() {
        var session = PodcastPlaybackSession(releaseID: release, startedAt: t0, deviceID: phone)
        var ledger = PodcastPlaybackLedger()
        ledger.apply(session.record(positionMS: 120_000, durationMS: 300_000, completed: false, at: t0 + 120))
        // The listener goes back to an earlier chapter: a later update of the same session wins over a larger position.
        ledger.apply(session.record(positionMS: 30_000, durationMS: 300_000, completed: false, at: t0 + 125))
        #expect(ledger.resumePositionMS(for: release) == 30_000)
        // A stale, out-of-order delivery of the earlier update does not move it forward again.
        var replay = PodcastPlaybackSession(releaseID: release, id: session.id, startedAt: t0, deviceID: phone)
        let stale = replay.record(positionMS: 120_000, durationMS: 300_000, completed: false, at: t0 + 120)
        let staleApplied = ledger.apply(stale)
        #expect(!staleApplied)
        #expect(ledger.resumePositionMS(for: release) == 30_000)
    }

    @Test func laterSessionWinsAcrossOfflineDevices() {
        // Both devices listen offline; the tablet started later, so its position is the latest intent even though
        // the phone's session saved more updates and a larger position.
        var phoneSession = PodcastPlaybackSession(releaseID: release, startedAt: t0, deviceID: phone)
        var tabletSession = PodcastPlaybackSession(releaseID: release, startedAt: t0 + 60, deviceID: tablet)
        var phoneLedger = PodcastPlaybackLedger(), tabletLedger = PodcastPlaybackLedger()
        for second in stride(from: 10, through: 200, by: 10) {
            phoneLedger.apply(phoneSession.record(positionMS: second * 1000, durationMS: 300_000, completed: false, at: t0 + Double(second)))
        }
        tabletLedger.apply(tabletSession.record(positionMS: 45_000, durationMS: 300_000, completed: false, at: t0 + 70))
        let a = phoneLedger.merged(with: tabletLedger), b = tabletLedger.merged(with: phoneLedger)
        #expect(a == b)
        #expect(a.resumePositionMS(for: release) == 45_000)
        // Idempotent: merging the same copy again (a duplicate delivery) changes nothing.
        #expect(a.merged(with: tabletLedger) == a && a.merged(with: a) == a)
    }

    @Test func removalIsATombstone() {
        var session = PodcastPlaybackSession(releaseID: release, startedAt: t0, deviceID: phone)
        let played = session.record(positionMS: 90_000, durationMS: 300_000, completed: false, at: t0 + 90)
        var ledger = PodcastPlaybackLedger(records: [played])
        ledger.remove(release, deviceID: phone, at: t0 + 90)
        #expect(ledger.history.isEmpty && ledger.resumePositionMS(for: release) == nil)
        // The old record arriving again (another copy, a retry) does not bring the entry back.
        let replayed = ledger.apply(played)
        #expect(!replayed)
        #expect(ledger.history.isEmpty)
        // Listening again later starts a new session, which is newer than the removal.
        var again = PodcastPlaybackSession(releaseID: release, startedAt: t0 + 500, deviceID: phone)
        ledger.apply(again.record(positionMS: 12_000, durationMS: 300_000, completed: false, at: t0 + 512))
        #expect(ledger.resumePositionMS(for: release) == 12_000 && ledger.history.count == 1)
    }

    @Test func finishedOrBarelyStartedDoesNotResume() {
        var session = PodcastPlaybackSession(releaseID: release, startedAt: t0, deviceID: phone)
        var ledger = PodcastPlaybackLedger()
        ledger.apply(session.record(positionMS: 2_000, durationMS: 300_000, completed: false, at: t0 + 2))
        #expect(ledger.resumePositionMS(for: release) == nil)
        ledger.apply(session.record(positionMS: 295_000, durationMS: 300_000, completed: false, at: t0 + 295))
        #expect(ledger.resumePositionMS(for: release) == nil)
        ledger.apply(session.record(positionMS: 300_000, durationMS: 300_000, completed: true, at: t0 + 300))
        #expect(ledger.isCompleted(release) && ledger.resumePositionMS(for: release) == nil)
    }

    @Test func ledgerIsBoundedAndRoundTrips() throws {
        var ledger = PodcastPlaybackLedger()
        for n in 0..<(PodcastPlaybackLedger.maximumRecords + 20) {
            var session = PodcastPlaybackSession(releaseID: UUID(), startedAt: t0 + Double(n), deviceID: phone)
            ledger.apply(session.record(positionMS: 10_000, durationMS: 300_000, completed: false, at: t0 + Double(n)))
        }
        let bounded = ledger.bounded()
        #expect(bounded.records.count == PodcastPlaybackLedger.maximumRecords)
        #expect(bounded.history.first?.updatedAt == t0 + Double(PodcastPlaybackLedger.maximumRecords + 19))
        let data = try JSONEncoder.podcast.encode(bounded)
        #expect(try JSONDecoder.podcast.decode(PodcastPlaybackLedger.self, from: data) == bounded)
    }
}

struct PodcastLocalStoreTests {
    @Test func historyAndDownloadsAreSealedPerAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = Data(repeating: 7, count: 32)
        let store = try PodcastLocalStore(directory: directory, accountID: account, localKey: key)
        var session = PodcastPlaybackSession(releaseID: UUID(), startedAt: Date(timeIntervalSince1970: 1_800_000_000), deviceID: UUID())
        let ledger = PodcastPlaybackLedger(records: [session.record(positionMS: 61_000, durationMS: 300_000, completed: false, at: Date(timeIntervalSince1970: 1_800_000_061))])
        try await store.saveHistory(ledger)
        let loadedHistory = await store.loadHistory()
        #expect(loadedHistory == ledger)

        let episode = try JSONDecoder().decode(PodcastEpisode.self, from: Data(PodcastContractTests.episodeJSON(extra: PodcastContractTests.transcriptJSON).utf8))
        let record = PodcastDownloadRecord(episode: episode, fileName: PodcastDownloadRecord.fileName(for: episode.id, mediaType: "audio/mp4"),
                                           bytes: episode.audio.bytes, sha256: episode.audio.sha256, mediaType: "audio/mp4", kept: true,
                                           verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), lastUsedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.saveDownloads([record])
        let loadedDownloads = await store.loadDownloads()
        #expect(loadedDownloads == [record])
        // The file's bytes are sealed: no transcript text or release ID in the clear.
        let raw = try Data(contentsOf: directory.appendingPathComponent(PodcastLocalStore.downloadsFile))
        #expect(raw.range(of: Data("Start with the question".utf8)) == nil && raw.range(of: Data(episode.id.wire.utf8)) == nil)

        // Another account (or a different key) reads nothing rather than another account's history.
        let other = try PodcastLocalStore(directory: directory, accountID: UUID(), localKey: key)
        let otherHistory = await other.loadHistory(), otherDownloads = await other.loadDownloads()
        #expect(otherHistory.records.isEmpty && otherDownloads.isEmpty)
        let wrongKey = try PodcastLocalStore(directory: directory, accountID: account, localKey: Data(repeating: 8, count: 32))
        let wrongDownloads = await wrongKey.loadDownloads()
        #expect(wrongDownloads.isEmpty)

        // A record whose file name or digest was not derived from its episode is refused.
        var forged = record; forged = PodcastDownloadRecord(episode: episode, fileName: "../escape.m4a", bytes: forged.bytes, sha256: forged.sha256,
                                                            mediaType: forged.mediaType, kept: true, verifiedAt: forged.verifiedAt, lastUsedAt: forged.lastUsedAt)
        await #expect(throws: (any Error).self) { try await store.saveDownloads([forged]) }

        // A removed folder (sign-out retirement, account deletion) is never recreated by a late save.
        try FileManager.default.removeItem(at: directory)
        await #expect(throws: (any Error).self) { try await store.saveHistory(ledger) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

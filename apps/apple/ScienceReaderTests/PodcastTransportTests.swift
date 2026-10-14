import AVFoundation
import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Scripted `podcast` / `podcast-member` responses for one test host; records requests.
private final class PodcastHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var body = Data(); var contentType = "application/json" }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [String: Reply]] = [:]
    nonisolated(unsafe) private static var requests: [String: [(URLRequest, Data)]] = [:]

    static func install(_ host: String, _ routes: [String: Reply]) { lock.withLock { replies[host] = routes; requests[host] = [] } }
    static func remove(_ host: String) { lock.withLock { replies[host] = nil; requests[host] = nil } }
    static func recorded(_ host: String) -> [(URLRequest, Data)] { lock.withLock { requests[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        Self.lock.withLock { Self.requests[host, default: []].append((request, body)) }
        // Route by path plus the `action` query item (the member endpoint has none).
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        let key = url.path + (action.map { "?\($0)" } ?? "")
        guard let reply = Self.lock.withLock({ Self.replies[host]?[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.contentType, "Content-Length": String(reply.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StoredPodcastSession: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    init(_ value: Data) { self.value = value }
    func read(_ name: String) throws -> Data? { lock.withLock { value } }
    func write(_ data: Data, name: String) throws { lock.withLock { value = data } }
    func delete(_ name: String) throws { lock.withLock { value = nil } }
}

/// The app's half of the podcast contract (docs/architecture/PAPER_PODCASTS.md): requests carry the account's bearer
/// to the configured origin only, decoding is bounded and validated, and server failures become finite codes.
final class PodcastTransportTests: XCTestCase {
    private let account = UUID()
    private let release = UUID()
    private var host = ""
    private let sha = String(repeating: "ab", count: 32)

    override func setUp() { host = "podcast-\(UUID().wire).invalid" }
    override func tearDown() { PodcastHTTPProtocol.remove(host) }

    private func transport(_ routes: [String: PodcastHTTPProtocol.Reply]) throws -> BackendPodcastTransport {
        PodcastHTTPProtocol.install(host, routes)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [PodcastHTTPProtocol.self]
        let session = try ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: account, email: nil)))
        let client = try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture-anon", environment: host),
                                       network: URLSession(configuration: settings), credentials: StoredPodcastSession(session))
        return BackendPodcastTransport(client: client, accountID: account)
    }

    private func episodeJSON(release: UUID? = nil, transcript: Bool = false, bytes: Int = 4096, sha: String? = nil) -> String {
        let extra = transcript ? #","chapters":[{"id":"c1","title":"Start","start_ms":0}],"transcript":{"speakers":{"explainer":"Host 1","skeptic":"Host 2"},"disclosure":"AI-generated.","timing":"approximate","segments":[{"id":"s1","speaker":"explainer","text":"Hello.","start_ms":0,"end_ms":1000,"chapter":"c1","claim_type":"context","evidence":[]}]}"# : ""
        return #"{"release_id":"\#((release ?? self.release).wire)","scope":"shared","title":"An episode","year":2026,"authors":["A"],"topic":"Machine learning","duration_ms":300000,"ai_audio":true,"fixture":false,"document_id":"\#(UUID().wire)","state":"ready","audio":{"bytes":\#(bytes),"sha256":"\#(sha ?? self.sha)","media_type":"audio/mp4"}\#(extra)}"#
    }

    func testCatalogIsAnAuthorizedBoundedGet() async throws {
        let transport = try transport(["/functions/v1/podcast?catalog": .init(body: Data(#"{"episodes":[\#(episodeJSON())],"next":"c2","capabilities":{"catalog":true,"generation":false,"delivery":true}}"#.utf8))])
        let page = try await transport.catalog(after: "c1", limit: 500)
        XCTAssertEqual(page.episodes.map(\.id), [release])
        XCTAssertEqual(page.next, "c2")
        XCTAssertEqual(page.capabilities?.generation, false)
        let (request, body) = try XCTUnwrap(PodcastHTTPProtocol.recorded(host).first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual(request.url?.absoluteString, "https://\(host)/functions/v1/podcast?action=catalog&limit=50&after=c1", "Limit is clamped to 50")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "fixture-anon")
    }

    func testStartSendsTheQuoteRequestAndConsent() async throws {
        let quoteID = UUID(), requestID = UUID()
        let transport = try transport(["/functions/v1/podcast?start": .init(body: Data(#"{"job":{"request_id":"\#(requestID.wire)","state":"queued","held_credits":150}}"#.utf8))])
        guard case .job(let job) = try await transport.start(quoteID: quoteID, requestID: requestID, consentVersion: "podcast-private-v1") else {
            return XCTFail("A job")
        }
        XCTAssertEqual(job.state, .queued); XCTAssertEqual(job.heldCredits, 150)
        let (request, body) = try XCTUnwrap(PodcastHTTPProtocol.recorded(host).first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.query, "action=start")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(sent, ["quote_id": quoteID.wire, "request_id": requestID.wire, "consent_version": "podcast-private-v1"])
    }

    func testQuoteNamesTheChosenLengthAndReadsEveryOption() async throws {
        let itemID = UUID(), requestID = UUID()
        let options = #"[{"profile":"podcast-short-v1","label":"Short","target_seconds":150,"max_credits":110},{"profile":"podcast-10min-v1","label":"10 min","target_seconds":600,"max_credits":220}]"#
        let transport = try transport(["/functions/v1/podcast?quote": .init(body: Data(#"{"quote":{"id":"\#(release.wire)","expires_at":"2026-10-08T12:15:00Z","max_credits":220,"estimate":"Estimate — you're charged actual usage, maximum 220 credits","providers":["Anthropic (script)","Google Vertex AI (speech)"],"consent_version":"podcast-private-v1","target_seconds":600,"profile":"podcast-10min-v1","label":"10 min"},"options":\#(options)}"#.utf8))])
        guard case .quote(let quote) = try await transport.quote(itemID: itemID, requestID: requestID, profile: "podcast-10min-v1") else { return XCTFail("A quote") }
        XCTAssertEqual(quote.profile, "podcast-10min-v1"); XCTAssertEqual(quote.maxCredits, 220); XCTAssertEqual(quote.label, "10 min")
        XCTAssertEqual(quote.options.map(\.maxCredits), [110, 220])
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(PodcastHTTPProtocol.recorded(host).first).1) as? [String: String])
        XCTAssertEqual(sent, ["item_id": itemID.wire, "request_id": requestID.wire, "profile": "podcast-10min-v1"])
        // No length: the body carries none (the server's default, five minutes, for older behaviour).
        host = "podcast-\(UUID().wire).invalid"
        let plain = try self.transport(["/functions/v1/podcast?quote": .init(body: Data(#"{"reuse":{"release_id":"\#(release.wire)"}}"#.utf8))])
        let reused = try await plain.quote(itemID: itemID, requestID: requestID, profile: nil)
        XCTAssertEqual(reused, .reuse(releaseID: release))
        XCTAssertNil((try JSONSerialization.jsonObject(with: try XCTUnwrap(PodcastHTTPProtocol.recorded(host).first).1) as? [String: String])?["profile"])
    }

    func testFailuresBecomeFiniteCodesNeverServerProse() async throws {
        let cases: [(Int, String, String)] = [
            (402, #"{"code":"insufficient_credits"}"#, "insufficient_credits"),
            (409, #"{"code":"active_generation_limit"}"#, "active_generation_limit"),
            (409, #"{"code":"podcast_outcome_pending"}"#, "podcast_outcome_pending"),
            (503, #"{"code":"podcast_paused"}"#, "podcast_paused"),
            (500, #"{"code":"Something private happened: <paper title>"}"#, "request_failed"),
            (502, "<html>gateway</html>", "request_failed"),
        ]
        for (status, body, expected) in cases {
            host = "podcast-\(UUID().wire).invalid"
            let transport = try transport(["/functions/v1/podcast?quote": .init(status: status, body: Data(body.utf8))])
            do {
                _ = try await transport.quote(itemID: UUID(), requestID: UUID(), profile: nil)
                XCTFail("\(status) should fail")
            } catch BackendError.rejected(let code) {
                XCTAssertEqual(code, expected)
                XCTAssertFalse(BackendError.rejected(code).podcastMessage.contains("<"), "No server text reaches the reader")
            }
        }
        XCTAssertTrue(BackendError.rejected("insufficient_credits").podcastMessage.contains("this length’s maximum"))
        XCTAssertTrue(BackendError.rejected("podcast_profile_unavailable").podcastMessage.contains("Choose another length"))
    }

    func testEpisodeMustBeTheRequestedReleaseWithTranscript() async throws {
        let other = UUID()
        let transport = try transport(["/functions/v1/podcast?episode": .init(body: Data(#"{"episode":\#(episodeJSON(release: other, transcript: true))}"#.utf8))])
        do { _ = try await transport.episode(release); XCTFail("A different release is refused") }
        catch { XCTAssertEqual(error as? ReaderError, .corruptData) }
        host = "podcast-\(UUID().wire).invalid"
        let summaryOnly = try self.transport(["/functions/v1/podcast?episode": .init(body: Data(#"{"episode":\#(episodeJSON())}"#.utf8))])
        do { _ = try await summaryOnly.episode(release); XCTFail("The episode call must carry its transcript and chapters") }
        catch { XCTAssertEqual(error as? ReaderError, .corruptData) }
    }

    func testMemberDownloadIsSingleUseShapedAndBounded() async throws {
        let audio = Data((0..<4096).map { UInt8($0 % 241) })
        let grant = String(repeating: "c", count: 64), member = UUID()
        let path = "/functions/v1/podcast-member"
        let transport = try transport([path: .init(body: audio, contentType: "audio/mp4")])
        let good = PodcastMember(role: "audio", url: URL(string: "https://\(host)\(path)?grant=\(grant)&member=\(member.wire)")!,
                                 bytes: audio.count, sha256: sha, mediaType: "audio/mp4")
        let reported = LockedValue(0)
        let data = try await transport.member(good) { reported.set($0) }
        XCTAssertEqual(data, audio)
        XCTAssertEqual(reported.get(), audio.count)
        let (request, _) = try XCTUnwrap(PodcastHTTPProtocol.recorded(host).first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"), "Never a Range request")

        // Another origin, path or query shape never receives the bearer: refused before any request.
        let before = PodcastHTTPProtocol.recorded(host).count
        for url in ["https://evil.invalid\(path)?grant=\(grant)&member=\(member.wire)",
                    "https://\(host)/functions/v1/reader-member?grant=\(grant)&member=\(member.wire)",
                    "https://\(host)\(path)?grant=\(grant)&member=\(member.wire)&next=1"] {
            let bad = PodcastMember(role: "audio", url: URL(string: url)!, bytes: audio.count, sha256: sha, mediaType: "audio/mp4")
            do { _ = try await transport.member(bad) { _ in }; XCTFail(url) } catch { XCTAssertEqual(error as? ReaderError, .corruptData) }
        }
        XCTAssertEqual(PodcastHTTPProtocol.recorded(host).count, before)

        // More bytes than the grant names: the transfer is stopped, not accepted.
        let small = PodcastMember(role: "audio", url: good.url, bytes: 100, sha256: sha, mediaType: "audio/mp4")
        do { _ = try await transport.member(small) { _ in }; XCTFail("Oversized body") } catch {}
    }

    func testMemberFailuresKeepOnlyKnownCodes() async throws {
        let path = "/functions/v1/podcast-member"
        let transport = try transport([path: .init(status: 409, body: Data(#"{"code":"podcast_grant_consumed"}"#.utf8))])
        let member = PodcastMember(role: "audio", url: URL(string: "https://\(host)\(path)?grant=\(String(repeating: "d", count: 64))&member=\(UUID().wire)")!,
                                   bytes: 10, sha256: sha, mediaType: "audio/mp4")
        do { _ = try await transport.member(member) { _ in }; XCTFail("Consumed grant") }
        catch BackendError.rejected(let code) { XCTAssertEqual(code, "podcast_grant_consumed") }
    }
}

private final class LockedValue: @unchecked Sendable {
    private let lock = NSLock(); private var value: Int
    init(_ value: Int) { self.value = value }
    func set(_ next: Int) { lock.withLock { value = next } }
    func get() -> Int { lock.withLock { value } }
}

/// Presentation rules of the player and the Listen sheet (2026-10-14 UX fixes): the speed is a device preference,
/// lengths beyond the balance are greyed out and not quoted, the wait is stated per length, and an episode that
/// becomes ready after its sheet was closed is offered by name.
@MainActor
final class PodcastPresentationTests: XCTestCase {
    /// Owner report 2026-10-14 ("not able to create a podcast at all"): a paper read on this device has no server
    /// text to write an episode from, and the notice says so instead of claiming the paper is not in the library.
    func testAPaperWithoutAServerCopySaysWhyItCannotBecomeAnEpisode() throws {
        var member = Paper(id: UUID(), title: "Device paper", authors: "A", year: 2026, abstract: "", keywords: [], fileURL: nil, artifactID: nil)
        member.sourceMembership = try SourcePaperReference(membershipID: member.id, sourceID: "2601.01234", revision: 2)
        XCTAssertEqual(PodcastCenter.noEpisodeSource(for: member), "Episodes are made from a server copy of the paper. Papers read on this device don’t have one yet, so this paper can’t be made into an episode.")
        let legacy = Paper(id: UUID(), title: "Legacy", authors: "A", year: 2024, abstract: "", keywords: [], fileURL: nil, artifactID: UUID())
        XCTAssertEqual(PodcastCenter.noEpisodeSource(for: legacy), "Listening needs this paper in your synced library.")
    }

    private static let lengths = [("podcast-short-v1", "Short", 150, 140), ("podcast-5min-v1", "5 min", 300, 150),
                                  ("podcast-10min-v1", "10 min", 600, 300), ("podcast-20min-v1", "20 min", 1200, 530)]
        .map { PodcastLength(profile: $0.0, label: $0.1, targetSeconds: $0.2, maxCredits: $0.3) }
    private static let capabilities = PodcastCapabilities(catalog: true, generation: true, delivery: true, lengths: lengths)

    private func generation(selected: String? = nil, ready: [PodcastEpisode] = []) -> PodcastGeneration {
        PodcastGeneration(paperTitle: "A paper", itemID: UUID(), documentID: UUID(), phase: .offer, capabilities: Self.capabilities,
                          ready: ready, selected: selected)
    }

    func testPlaybackSpeedIsRememberedOnThisDevice() throws {
        let suite = "podcast-presentation-\(UUID().wire)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PodcastPlayer(defaults: defaults)
        XCTAssertEqual(first.rate, 1, "Nothing saved: 1×")
        first.rate = 1.5
        XCTAssertEqual(PodcastPlayer(defaults: defaults).rate, 1.5, "A new player (the next launch) starts at the chosen speed")
        XCTAssertEqual(PodcastPlayer.storedRate(in: defaults), 1.5)
        // Only speeds the player offers are restored; anything else means 1×.
        defaults.set(3.0, forKey: PodcastPlayer.rateKey)
        XCTAssertEqual(PodcastPlayer(defaults: defaults).rate, 1)
        XCTAssertNil(PodcastPlayer.storedRate(in: defaults))
        let reset = PodcastPlayer(defaults: defaults)
        reset.rate = 2
        reset.resetRatePreference()
        XCTAssertEqual(reset.rate, 1)
        XCTAssertNil(defaults.object(forKey: PodcastPlayer.rateKey), "The fixture reset forgets the choice")
    }

    func testLengthsBeyondTheBalanceAreGreyedOutAndNotQuoted() {
        let offer = generation()
        XCTAssertEqual(offer.selected, "podcast-5min-v1")
        let ten = Self.lengths[2], five = Self.lengths[1]
        XCTAssertFalse(offer.affordable(ten, credits: 200), "300 > 200: greyed out")
        XCTAssertTrue(offer.affordable(five, credits: 200))
        XCTAssertTrue(offer.affordable(five, credits: 150), "Exactly the maximum fits")
        XCTAssertTrue(offer.affordable(ten, credits: nil), "An unknown balance greys nothing out; the server decides")
        XCTAssertTrue(offer.shouldQuote(credits: 200), "The chosen five minutes is quoted at once")
        XCTAssertTrue(offer.shouldQuote(credits: nil))
        XCTAssertFalse(generation(selected: "podcast-10min-v1").shouldQuote(credits: 200), "A length beyond the balance waits for another choice")
        XCTAssertTrue(generation(selected: "podcast-10min-v1").shouldQuote(credits: 300))
    }

    func testExpectedWaitIsStatedPerLength() {
        XCTAssertEqual(PodcastGeneration.expectedWait(targetSeconds: 150), "Usually ready in a few minutes.")
        XCTAssertEqual(PodcastGeneration.expectedWait(targetSeconds: 300), "Usually ready in a few minutes.")
        XCTAssertEqual(PodcastGeneration.expectedWait(targetSeconds: 600), "This length can take 10 minutes or more.")
        XCTAssertEqual(PodcastGeneration.expectedWait(targetSeconds: 1200), "This length can take 10 minutes or more.")
        let running = generation()
        let tenMinuteJob = PodcastJob(requestID: UUID(), state: .scripting, stageEnteredAt: nil, releaseID: nil, heldCredits: 300,
                                      chargedCredits: nil, releasedCredits: nil, failure: nil, profile: "podcast-10min-v1")
        XCTAssertEqual(running.length(of: tenMinuteJob)?.targetSeconds, 600, "The job's own length, not the sheet's default")
        let unnamed = PodcastJob(requestID: UUID(), state: .scripting, stageEnteredAt: nil, releaseID: nil, heldCredits: 150,
                                 chargedCredits: nil, releasedCredits: nil, failure: nil, profile: nil)
        XCTAssertEqual(running.length(of: unnamed)?.targetSeconds, 300, "An older server names no length: the chosen one")
    }

    func testReadyNoticeNamesThePaperAndPollingSaysWhenItStops() {
        let notice = PodcastCenter.ReadyNotice(releaseID: UUID(), title: "LoRA: Low-Rank Adaptation of Large Language Models")
        XCTAssertEqual(notice.message, "Your episode of “LoRA: Low-Rank Adaptation of Large Language Models” is ready.")
        XCTAssertEqual(PodcastCenter.pollLimit, 1_800, "The polling bound from the design is unchanged")
        XCTAssertEqual(PodcastCenter.stillPreparingNotice, "Still preparing. Check back from Listen on this paper.")
    }
}

// The app compiles its fixtures with FIXTURE_HOST in Debug Simulator and Mac builds (project.yml); match that here.
#if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
/// The zero-spend fixture stays honest: valid audio of the stated length, contract-valid episodes, and evidence quotes
/// that really are in the bundled sample paper (so the evidence journey tests the real passage finder).
final class PodcastFixtureTests: XCTestCase {
    func testFixtureEpisodesAreValidLabeledAndPlayable() throws {
        for spec in PodcastFixtureTransport.catalogSpecs + PodcastFixtureTransport.lengths.map({ PodcastFixtureTransport.privateSpec(document: UUID(), length: $0) }) {
            let built = PodcastFixtureTransport.build(spec)
            XCTAssertTrue(built.episode.fixture)
            XCTAssertNoThrow(try built.episode.validate())
            let round = try JSONDecoder().decode(PodcastEpisode.self, from: JSONEncoder().encode(built.episode))
            XCTAssertEqual(round, built.episode)
            XCTAssertNoThrow(try PodcastAudioVerification.verify(built.audio, bytes: built.episode.audio.bytes, sha256: built.episode.audio.sha256))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().wire).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try built.audio.write(to: url)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            XCTAssertEqual(seconds, Double(built.episode.durationMS) / 1000, accuracy: 0.05)
            // The last passage ends inside the audio.
            XCTAssertLessThanOrEqual(built.episode.transcript?.segments.last?.endMS ?? 0, built.episode.durationMS)
        }
        // Deterministic bytes: the same spec gives the same digest (downloads verify against it).
        let spec = PodcastFixtureTransport.catalogSpecs[0]
        XCTAssertEqual(PodcastFixtureTransport.build(spec).episode.audio.sha256, PodcastFixtureTransport.build(spec).episode.audio.sha256)
    }

    func testSampleEvidenceQuotesAreVerbatimInTheBundledPaper() throws {
        // The offline sample the fixture library opens (ReaderBundleLoader.sample), read from the app's resources.
        let manifest = try ReaderBundleLoader.sample().manifestSHA256
        let url = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ReaderSamples/\(manifest)"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let sample = PodcastFixtureTransport.build(PodcastFixtureTransport.catalogSpecs[0]).episode
        XCTAssertEqual(sample.documentID, PodcastFixtureTransport.sampleDocument)
        let quotes = sample.transcript?.segments.flatMap(\.evidence).map(\.quote) ?? []
        XCTAssertEqual(quotes.count, 6)
        for quote in quotes { XCTAssertTrue(text.contains(quote), "Not in the sample: \(quote)") }
    }

    /// The fixture's maximums are the serving-limit (v2) profiles staging serves, and a ready length never needs credits.
    @MainActor func testFixtureLengthsAreTheServingLimitProfiles() {
        XCTAssertEqual(PodcastFixtureTransport.lengths.map(\.maxCredits), [140, 150, 300, 530])
        XCTAssertEqual(PodcastFixtureTransport.lengths.map(\.targetSeconds), [150, 300, 600, 1200])
        XCTAssertEqual(PodcastFixtureTransport.fixtureCredits(arguments: ["--podcast-fixture", "--podcast-fixture-credits=200"]), 200)
        XCTAssertNil(PodcastFixtureTransport.fixtureCredits(arguments: ["--podcast-fixture"]), "No argument: the balance is unknown")
        let document = UUID()
        let ready = PodcastFixtureTransport.build(PodcastFixtureTransport.privateSpec(document: document, length: PodcastFixtureTransport.lengths[3])).episode
        let generation = PodcastGeneration(paperTitle: "A paper", itemID: document, documentID: document, phase: .offer,
                                           capabilities: PodcastCapabilities(catalog: true, generation: true, delivery: true, lengths: PodcastFixtureTransport.lengths),
                                           ready: [ready], selected: "podcast-20min-v1")
        XCTAssertTrue(generation.affordable(PodcastFixtureTransport.lengths[3], credits: 0), "Ready: playing it costs nothing, so never greyed out")
        XCTAssertFalse(generation.shouldQuote(credits: 10_000), "Ready: played, not quoted")
    }
}
#endif

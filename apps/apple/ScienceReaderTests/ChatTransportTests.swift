import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Serves scripted chat responses for one test host and records requests.
private final class ChatHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var contentType = "text/event-stream; charset=utf-8"
        var chunks: [Data] = []
        var holdOpen = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [String: [(URLRequest, Data)]] = [:]
    nonisolated(unsafe) private static var stopped: [String: Int] = [:]

    static func install(_ host: String, _ reply: Reply) { lock.withLock { replies[host] = reply; requests[host] = []; stopped[host] = 0 } }
    static func remove(_ host: String) { lock.withLock { replies[host] = nil; requests[host] = nil; stopped[host] = nil } }
    static func recorded(_ host: String) -> [(URLRequest, Data)] { lock.withLock { requests[host] ?? [] } }
    static func stops(_ host: String) -> Int { lock.withLock { stopped[host] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let reply = Self.lock.withLock({ Self.replies[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
        }
        Self.lock.withLock { Self.requests[host, default: []].append((request, body)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !reply.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.lock.withLock { Self.stopped[host, default: 0] += 1 }
    }
}

private final class StoredSession: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    init(_ value: Data) { self.value = value }
    func read(_ name: String) throws -> Data? { lock.withLock { value } }
    func write(_ data: Data, name: String) throws { lock.withLock { value = data } }
    func delete(_ name: String) throws { lock.withLock { value = nil } }
}

final class ChatTransportTests: XCTestCase {
    private let account = UUID()
    private var host = ""

    override func setUp() { host = "chat-\(UUID().wire).invalid" }
    override func tearDown() { ChatHTTPProtocol.remove(host) }

    private func client(_ reply: ChatHTTPProtocol.Reply) throws -> BackendClient {
        ChatHTTPProtocol.install(host, reply)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ChatHTTPProtocol.self]
        let session = try ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: account, email: nil)))
        return try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture-anon", environment: host),
                                 network: URLSession(configuration: settings), credentials: StoredSession(session))
    }

    private func request() throws -> ChatGenerationRequest {
        try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(),
            transcript: [ChatTurnInput(role: .user, text: "Why \\(\\sqrt{d_k}\\)?")], selection: "a passage")
    }

    private func collect(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    func testStreamsEventsFromTheConfiguredHostWithAuthorization() async throws {
        let wire = Data(": open\n\nevent: delta\ndata: {\"text\":\"Hel\"}\n\nevent: delta\ndata: {\"text\":\"lo\"}\n\n: ping\n\nevent: done\ndata: {\"stop_reason\":\"end_turn\",\"credits\":2,\"usage\":{}}\n\n".utf8)
        let chunks = stride(from: 0, to: wire.count, by: 7).map { wire[$0..<min(wire.count, $0 + 7)] }
        let client = try client(.init(chunks: chunks.map { Data($0) }))
        let sent = try request()
        let events = try await collect(try await client.chatStream(sent, accountID: account))
        XCTAssertEqual(events, [.delta("Hel"), .delta("lo"), .done(stopReason: "end_turn", credits: 2)])
        let (urlRequest, body) = try XCTUnwrap(ChatHTTPProtocol.recorded(host).first)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://\(host)/functions/v1/chat")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "apikey"), "fixture-anon")
        XCTAssertEqual(body, try sent.encoded())
    }

    func testHTTPFailuresBecomeStableCodes() async throws {
        let cases: [(Int, Data, String)] = [
            (402, Data(#"{"code":"insufficient_credits"}"#.utf8), "insufficient_credits"),
            (503, Data("<html>gateway</html>".utf8), "service_unavailable"),
        ]
        for (status, data, code) in cases {
            host = "chat-\(UUID().wire).invalid"
            let client = try client(.init(status: status, contentType: "application/json", chunks: [data]))
            do {
                _ = try await client.chatStream(try request(), accountID: account)
                XCTFail("Expected \(code)")
            } catch ChatTransportError.rejected(let received) { XCTAssertEqual(received, code) }
            ChatHTTPProtocol.remove(host)
        }
    }

    func testRejectedChatSessionClearsAuthorityBeforeTheReaderCanTryAnotherCloudAction() async throws {
        for status in [401, 403] {
            host = "chat-\(UUID().wire).invalid"
            let client = try client(.init(status: status, contentType: "application/json",
                chunks: [Data(#"{"code":"authentication_required"}"#.utf8)]))
            do { _ = try await client.chatStream(try request(), accountID: account); XCTFail("Revoked session accepted") }
            catch AuthenticationError.sessionExpired { }
            let user = await client.currentUser(); XCTAssertNil(user)
            do { _ = try await client.chatStream(try request(), accountID: account); XCTFail("Revoked session retried") }
            catch BackendError.signInRequired { }
            XCTAssertEqual(ChatHTTPProtocol.recorded(host).count, 1)
            ChatHTTPProtocol.remove(host)
        }
    }

    func testRejectsNonStreamingSuccessAndOtherAccounts() async throws {
        let client = try client(.init(contentType: "application/json", chunks: [Data("{}".utf8)]))
        do { _ = try await client.chatStream(try request(), accountID: account); XCTFail("Expected malformed") }
        catch ChatStreamError.malformed {}
        do { _ = try await client.chatStream(try request(), accountID: UUID()); XCTFail("Expected sign-in required") }
        catch BackendError.signInRequired {}
        XCTAssertEqual(ChatHTTPProtocol.recorded(host).count, 1, "Another account's request is refused before the network")
    }

    func testMalformedEventsFailTheStream() async throws {
        let client = try client(.init(chunks: [Data("event: delta\ndata: {\"nope\":1}\n\n".utf8)]))
        do { _ = try await collect(try await client.chatStream(try request(), accountID: account)); XCTFail("Expected malformed") }
        catch ChatStreamError.malformed {}
    }

    func testCancellingTheConsumerCancelsTheRequest() async throws {
        let client = try client(.init(chunks: [Data("event: delta\ndata: {\"text\":\"first\"}\n\n".utf8)], holdOpen: true))
        // The consumer owns the only stream reference; leaving releases it.
        func first(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> ChatStreamEvent? {
            for try await event in stream { return event }
            return nil
        }
        let received = try await first(try await client.chatStream(try request(), accountID: account))
        XCTAssertEqual(received, .delta("first"))
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        while ChatHTTPProtocol.stops(host) == 0, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(ChatHTTPProtocol.stops(host), 0, "Leaving the stream cancels the HTTP request")
    }
}

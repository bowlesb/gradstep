import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Answers every request to its host with one scripted status, headers and body.
private final class StatusProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var headers: [String: String] = [:]; var body: Data = Data() }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    static func install(_ host: String, _ reply: Reply) { lock.withLock { replies[host] = reply } }
    static func remove(_ host: String) { lock.withLock { replies[host] = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host, let reply = Self.lock.withLock({ Self.replies[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StoredSession: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    init(_ value: Data) { self.value = value }
    func read(_ name: String) throws -> Data? { lock.withLock { value } }
    func write(_ data: Data, name: String) throws { lock.withLock { value = data } }
    func delete(_ name: String) throws { lock.withLock { value = nil } }
}

/// A transport whose answer never sends anything (a stalled connection).
private struct SilentTransport: ChatTransport {
    let events: [ChatStreamEvent]
    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { for event in events { continuation.yield(event) }; try? await Task.sleep(for: .seconds(3600)) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func creditBalance(accountID: UUID) async throws -> CreditBalance { CreditBalance(available: 0, reserved: 0) }
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable { throw ChatTransportError.rejected("unavailable") }
}

/// docs/architecture/RESILIENCE.md: a busy server's 429 carries its wait, transient and specific failures are told
/// apart, a first-device setup that can't reach the server isn't a key problem, and a silent answer ends.
final class ResilienceTests: XCTestCase {
    private let account = UUID()
    private var host = ""
    override func setUp() { host = "resilience-\(UUID().wire).invalid" }
    override func tearDown() { StatusProtocol.remove(host) }

    private func client(_ reply: StatusProtocol.Reply) throws -> BackendClient {
        StatusProtocol.install(host, reply)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StatusProtocol.self]
        let session = try ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: account, email: nil)))
        return try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture-anon", environment: host),
                                 network: URLSession(configuration: settings), credentials: StoredSession(session))
    }

    private func failure(_ reply: StatusProtocol.Reply) async throws -> BackendError {
        do { _ = try await client(reply).creditBalance(accountID: account); XCTFail("expected a failure"); throw CancellationError() }
        catch let error as BackendError { return error }
    }

    func testABusyServerSaysHowLongToWait() async throws {
        let header = try await failure(.init(status: 429, headers: ["Retry-After": "30"], body: Data(#"{"code":"too_busy"}"#.utf8)))
        XCTAssertEqual(header.retryAfter, 30)
        XCTAssertTrue(header.isTransient)
        XCTAssertTrue(header.errorDescription?.contains("30 seconds") == true, header.errorDescription ?? "")
        host = "resilience-\(UUID().wire).invalid"
        let body = try await failure(.init(status: 429, body: Data(#"{"retry_after":12}"#.utf8)))
        XCTAssertEqual(body.retryAfter, 12)
    }

    func testASpecificLimitKeepsItsOwnMessage() async throws {
        let limit = try await failure(.init(status: 429, body: Data(#"{"message":"request_rate_limit"}"#.utf8)))
        guard case .rejected("request_rate_limit") = limit else { return XCTFail("\(limit)") }
        XCTAssertFalse(limit.isTransient)
    }

    func testAnUnexplainedServerErrorIsWorthRetrying() async throws {
        let error = try await failure(.init(status: 503, body: Data("<html>gateway</html>".utf8)))
        guard case .rejected("request_failed") = error else { return XCTFail("\(error)") }
        XCTAssertTrue(error.isTransient)
        XCTAssertFalse(BackendError.rejected("insufficient_credits").isTransient)
    }

    @MainActor func testOnlyReachabilityFailuresAvoidTheRecoverySheet() {
        XCTAssertTrue(ReaderModel.isReachability(URLError(.notConnectedToInternet)))
        XCTAssertTrue(ReaderModel.isReachability(URLError(.timedOut)))
        XCTAssertTrue(ReaderModel.isReachability(BackendError.throttled(retryAfter: nil)))
        XCTAssertTrue(ReaderModel.isReachability(BackendError.rejected("request_failed")))
        XCTAssertFalse(ReaderModel.isReachability(URLError(.cancelled)))
        XCTAssertFalse(ReaderModel.isReachability(BackendError.rejected("key_authority_required")))
        XCTAssertFalse(ReaderModel.isReachability(ReaderError.missingKey))
    }

    func testASilentAnswerEndsAsInterrupted() async throws {
        let transport = IdleBoundedChatTransport(base: SilentTransport(events: [.delta("Partial")]), idle: .milliseconds(300))
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "Hello")], selection: nil)
        let started = ContinuousClock.now
        var received: [ChatStreamEvent] = []
        do {
            for try await event in try await transport.chatStream(request, accountID: account) { received.append(event) }
            XCTFail("a silent stream must not end quietly")
        } catch ChatTransportError.rejected(let code) {
            XCTAssertEqual(code, "transport")
        }
        XCTAssertEqual(received, [.delta("Partial")], "what arrived is kept")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the spinner has an end")
    }
}

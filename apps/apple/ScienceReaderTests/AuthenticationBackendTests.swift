import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

private final class AuthenticationTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: AuthenticationTestServer] = [:]
    static func install(_ host: String, server: AuthenticationTestServer) { lock.withLock { servers[host] = server } }
    static func remove(_ host: String) { _ = lock.withLock { servers.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let server = Self.lock.withLock({ Self.servers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        server.receive(self)
    }
    override func stopLoading() {
        if let host = request.url?.host { Self.lock.withLock { Self.servers[host] }?.stopped(self) }
    }
    func respond(_ reply: AuthenticationTestServer.Reply) {
        let response = HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"].merging(reply.headers) { _, value in value })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        if reply.finish { client?.urlProtocolDidFinishLoading(self) }
    }
    func fail(_ code: URLError.Code) { client?.urlProtocol(self, didFailWithError: URLError(code)) }
}

private final class AuthenticationTestServer: @unchecked Sendable {
    struct Reply: Sendable {
        let data: Data
        var status = 200
        var headers: [String: String] = [:]
        var finish = true
        var url: URL?
    }
    enum Step: Sendable { case reply(Reply), fail(URLError.Code), hold }
    struct Request: Sendable {
        let url: URL
        let body: Data
        let headers: [String: String]
        let timeout: TimeInterval
        var object: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var received: [Request] = []
    private var held: AuthenticationTestProtocol?
    private var sawStop = false
    let arrived = XCTestExpectation(description: "Owned auth request reached the fake transport")
    let cancelled = XCTestExpectation(description: "Owned auth transfer was cancelled")

    init(_ steps: [Step]) { self.steps = steps }
    func receive(_ request: AuthenticationTestProtocol) {
        let captured = Request(url: request.request.url!, body: Self.body(request.request),
            headers: request.request.allHTTPHeaderFields ?? [:], timeout: request.request.timeoutInterval)
        let step = lock.withLock { () -> Step in
            received.append(captured)
            let step = steps.isEmpty ? Step.reply(Reply(data: Data("{}".utf8), status: 503)) : steps.removeFirst()
            if case .hold = step { held = request; arrived.fulfill() }
            return step
        }
        switch step {
        case .reply(let reply): request.respond(reply)
        case .fail(let code): request.fail(code)
        case .hold: break
        }
    }
    func stopped(_ request: AuthenticationTestProtocol) {
        lock.withLock {
            if held === request, !sawStop { sawStop = true; cancelled.fulfill() }
        }
    }
    func release(_ reply: Reply) {
        let request = lock.withLock { () -> AuthenticationTestProtocol? in
            defer { held = nil }
            return held
        }
        request?.respond(reply)
    }
    func requests() -> [Request] { lock.withLock { received } }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class AuthenticationTestCredentials: AuthenticationCredentialStore, @unchecked Sendable {
    private enum Failure: Error { case injected }
    private let lock = NSLock()
    private var bytes: Data?
    private var failDelete = false
    private var failWriteAfterCommit = false
    private var writeCount = 0
    init(_ bytes: Data? = nil) { self.bytes = bytes }
    func read(_ name: String) throws -> Data? { lock.withLock { bytes } }
    func write(_ data: Data, name: String) throws {
        try lock.withLock {
            bytes = data; writeCount += 1
            if failWriteAfterCommit { throw Failure.injected }
        }
    }
    func delete(_ name: String) throws {
        try lock.withLock {
            if failDelete { throw Failure.injected }
            bytes = nil
        }
    }
    func failures(delete: Bool, writeAfterCommit: Bool = false) {
        lock.withLock { failDelete = delete; failWriteAfterCommit = writeAfterCommit }
    }
    func saved() -> Data? { lock.withLock { bytes } }
    func writes() -> Int { lock.withLock { writeCount } }
}

private struct AuthenticationFixture {
    let host = "authentication-\(UUID().uuidString.lowercased()).invalid"
    let server: AuthenticationTestServer
    let credentials: AuthenticationTestCredentials
    let client: BackendClient
    init(_ steps: [AuthenticationTestServer.Step], stored: Data? = nil,
         callback: URL? = AuthenticationConfiguration.callbackURL) throws {
        server = AuthenticationTestServer(steps); credentials = AuthenticationTestCredentials(stored)
        AuthenticationTestProtocol.install(host, server: server)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [AuthenticationTestProtocol.self]
        client = try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture-key",
            environment: host, authCallbackURL: callback), network: URLSession(configuration: settings), credentials: credentials)
    }
    func close() { AuthenticationTestProtocol.remove(host) }
    static func session(account: UUID = UUID(), email: String? = nil, expiresAt: Double = Date().timeIntervalSince1970 + 3_600,
                        accessToken: String = "fixture-access") throws -> Data {
        try ReaderCrypto.encode(AuthSession(access_token: accessToken, refresh_token: "fixture-refresh",
            expires_at: expiresAt, user: .init(id: account, email: email)))
    }
    static func ok(_ data: Data = Data("{}".utf8), status: Int = 200, headers: [String: String] = [:]) -> AuthenticationTestServer.Step {
        .reply(.init(data: data, status: status, headers: headers))
    }
}

@MainActor
final class AuthenticationBackendTests: XCTestCase {
    func testDeletedRemoteSessionRetiresCachedCredentialsInsteadOfRetryingForever() async throws {
        let account = UUID()
        let fixture = try AuthenticationFixture([.ok(Data(#"{"error_code":"refresh_token_not_found"}"#.utf8), status: 400)],
            stored: AuthenticationFixture.session(account: account, expiresAt: 0))
        defer { fixture.close() }
        do { let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse()); XCTFail("Deleted session accepted") }
        catch { }
        let user = await fixture.client.currentUser()
        XCTAssertNil(user, "A definitively rejected refresh must end cached sign-in")
        XCTAssertNil(fixture.credentials.saved(), "A restart must not restore the rejected session")
        do { let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse()); XCTFail("Deleted session retried") }
        catch { }
        XCTAssertEqual(fixture.server.requests().count, 1, "No cloud RPC or repeated refresh after definitive revocation")
    }

    func testRefreshTransientFailuresKeepOfflineIdentityAndCanRecover() async throws {
        let failures: [AuthenticationTestServer.Step] = [
            .fail(.timedOut), .ok(Data(#"{"error_code":"refresh_token_not_found"}"#.utf8), status: 503),
            .ok(Data(#"{"error_code":"refresh_token_not_found"}"#.utf8), status: 429),
            .ok(Data(#"{"error_code":"unexpected_failure"}"#.utf8), status: 400), .ok(Data("broken".utf8))
        ]
        for failure in failures {
            let account = UUID(), original = try AuthenticationFixture.session(account: account, expiresAt: 0)
            let fixture = try AuthenticationFixture([failure, .ok(AuthenticationFixture.session(account: account)), .ok()], stored: original)
            defer { fixture.close() }
            do { let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse()); XCTFail("Failure accepted") }
            catch { }
            let user = await fixture.client.currentUser()
            XCTAssertEqual(user?.id, account); XCTAssertEqual(fixture.credentials.saved(), original)
            let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse())
            XCTAssertEqual(fixture.server.requests().count, 3)
        }
    }

    func testClosedAccountWithUnexpiredTokenInvalidatesOnlyForExactAuthRejection() async throws {
        for (status, body, endsSession) in [
            (403, #"{"code":"28000","message":"authentication_required"}"#, true),
            (403, #"{"code":"account_unavailable"}"#, true),
            (403, #"{"code":"owner_mfa_required"}"#, false),
            (503, #"{"code":"28000","message":"authentication_required"}"#, false)
        ] {
            let account = UUID(), fixture = try AuthenticationFixture([.ok(Data(body.utf8), status: status)],
                stored: AuthenticationFixture.session(account: account))
            defer { fixture.close() }
            do { let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse()); XCTFail("Rejected request accepted") }
            catch { }
            let user = await fixture.client.currentUser()
            XCTAssertEqual(user == nil, endsSession); XCTAssertEqual(fixture.credentials.saved() == nil, endsSession)
        }
    }

    func testConcurrentRevokedRefreshNotifiesOnceAndCannotAffectANewLogin() async throws {
        let account = UUID(), nextAccount = UUID()
        let fixture = try AuthenticationFixture([.hold, .ok(AuthenticationFixture.session(account: nextAccount))],
            stored: AuthenticationFixture.session(account: account, expiresAt: 0))
        defer { fixture.close() }
        var events: [AuthenticationInvalidation] = []
        await fixture.client.observeSessionInvalidation { events.append($0) }
        let first = Task { let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse()) }
        await fulfillment(of: [fixture.server.arrived], timeout: 5)
        let second = Task { let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse()) }
        fixture.server.release(.init(data: Data(#"{"error_code":"refresh_token_not_found"}"#.utf8), status: 400))
        for task in [first, second] { do { try await task.value; XCTFail("Revoked refresh accepted") } catch { } }
        XCTAssertEqual(fixture.server.requests().count, 1); XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.accountID, account)
        let wasCurrent = await fixture.client.isCurrentInvalidation(event); XCTAssertTrue(wasCurrent)
        _ = try await fixture.client.signIn(email: "fixture", password: "fixture")
        let stillCurrent = await fixture.client.isCurrentInvalidation(event); XCTAssertFalse(stillCurrent)
        let user = await fixture.client.currentUser(); XCTAssertEqual(user?.id, nextAccount)
    }

    func testRevocationClearsMemoryEvenWhenCredentialCleanupFails() async throws {
        let fixture = try AuthenticationFixture([.ok(Data(#"{"error_code":"refresh_token_not_found"}"#.utf8), status: 400)],
            stored: AuthenticationFixture.session(expiresAt: 0))
        defer { fixture.close() }
        fixture.credentials.failures(delete: true)
        await error(.credentialStorage) { let _: EmptyResponse = try await fixture.client.rpc("v1_key_state", params: EmptyResponse()) }
        let user = await fixture.client.currentUser(); XCTAssertNil(user)
        await error(.credentialStorage) { _ = try await fixture.client.beginGoogleSignIn() }
        fixture.credentials.failures(delete: false)
        _ = try await fixture.client.beginGoogleSignIn()
        XCTAssertNil(fixture.credentials.saved())
    }

    func testReaderMemberPreservesBoundedQuotaErrorsEvenForATinyMember() async throws {
        let account = UUID(), token = String(repeating: "a", count: 64), memberID = UUID()
        let cases = [("reader_transfer_limit", 429), ("reader_upgrade_required", 426),
                     ("reader_grant_unavailable", 403), ("reader_grant_consumed", 409),
                     ("asset_inventory_incomplete", 503), ("reader_not_ready", 503), ("reader_integrity_failed", 503)]
        for (code, status) in cases {
            let fixture = try AuthenticationFixture([.ok(Data("{\"code\":\"\(code)\",\"message\":\"private-server-detail\"}".utf8), status: status)],
                                                    stored: AuthenticationFixture.session(account: account))
            defer { fixture.close() }
            let url = "https://\(fixture.host)/functions/v1/reader-member?grant=\(token)&member=\(memberID.wire)"
            let member = try JSONDecoder().decode(ReaderArtifactDescriptor.Member.self, from: JSONSerialization.data(withJSONObject:
                ["path": "a.txt", "bytes": 1, "sha256": String(repeating: "0", count: 64), "url": url]))
            do { _ = try await fixture.client.readerMember(member, accountID: account); XCTFail("Quota/availability response cannot be accepted") }
            catch BackendError.rejected(let result) { XCTAssertEqual(result, code) }
            catch { XCTFail("Lost delivery reason: \(type(of: error))") }
            let requests = fixture.server.requests()
            XCTAssertEqual(requests.count, 1, "A consumed grant is never retried automatically")
            XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer fixture-access")
            XCTAssertEqual(requests.first?.url.absoluteString, url)
        }
    }

    func testReaderMemberSuccessAndErrorBodiesHaveIndependentHardBounds() async throws {
        let account = UUID()
        for reply in [AuthenticationTestServer.Reply(data: Data([1, 2])),
                      .init(data: Data(repeating: 120, count: 4_097), status: 429),
                      .init(data: Data(), status: 503, headers: ["Content-Length": "4097"])] {
            let fixture = try AuthenticationFixture([.reply(reply)], stored: AuthenticationFixture.session(account: account))
            defer { fixture.close() }
            let member = try JSONDecoder().decode(ReaderArtifactDescriptor.Member.self, from: JSONSerialization.data(withJSONObject:
                ["path": "a.txt", "bytes": 1, "sha256": String(repeating: "0", count: 64),
                 "url": "https://\(fixture.host)/functions/v1/reader-member?grant=\(String(repeating: "a", count: 64))&member=\(UUID().wire)"]))
            do { _ = try await fixture.client.readerMember(member, accountID: account); XCTFail("Oversized response accepted") }
            catch LibraryProtocolError.payloadTooLarge { }
            catch { XCTFail("Wrong bound failure: \(type(of: error))") }
            XCTAssertEqual(fixture.server.requests().count, 1)
        }
    }

    func testEmailPreparationSendCorrectionAndAcceptanceUseOneCapturedAddress() async throws {
        let account = UUID()
        let fixture = try AuthenticationFixture([.ok(), .ok(Data(#"{"error_code":"otp_expired"}"#.utf8), status: 403),
            .ok(AuthenticationFixture.session(account: account))])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "  Researcher+paper@Example.invalid \n")
        XCTAssertEqual(request.email, "Researcher+paper@Example.invalid")
        XCTAssertTrue(fixture.server.requests().isEmpty, "Preparing must return identity before HTTP begins")
        let delivery = try await fixture.client.sendEmailCode(id: request.id)
        XCTAssertEqual(delivery, .sent)
        let beforeVerification = await fixture.client.currentUser()
        XCTAssertNil(beforeVerification); XCTAssertNil(fixture.credentials.saved())
        await error(.invalidCode) { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456") }
        let user = try await fixture.client.finishEmailSignIn(id: request.id, code: "654321")
        XCTAssertEqual(user.id, account); XCTAssertNil(user.email)
        let requests = fixture.server.requests()
        XCTAssertEqual(requests.map(\.url.path), ["/auth/v1/otp", "/auth/v1/verify", "/auth/v1/verify"])
        XCTAssertEqual(requests[0].object["create_user"] as? Bool, true)
        for value in requests { XCTAssertEqual(value.object["email"] as? String, request.email); XCTAssertEqual(value.timeout, 30) }
        XCTAssertEqual(requests[1].object["type"] as? String, "email")
        XCTAssertEqual(requests[2].object["token"] as? String, "654321")
        XCTAssertEqual(fixture.credentials.writes(), 1)
        await cancellation { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "654321") }
        XCTAssertEqual(fixture.server.requests().count, 3)
    }

    func testUnconfirmedSendAllowsCodeEntryWithoutRepeatingTheSend() async throws {
        let fixture = try AuthenticationFixture([.fail(.timedOut), .ok(AuthenticationFixture.session())])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        let delivery = try await fixture.client.sendEmailCode(id: request.id)
        XCTAssertEqual(delivery, .unconfirmed)
        await cancellation { _ = try await fixture.client.sendEmailCode(id: request.id) }
        _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456")
        XCTAssertEqual(fixture.server.requests().map(\.url.path), ["/auth/v1/otp", "/auth/v1/verify"])
    }

    func testMalformedTruncatedAndOversizedSendRepliesAllowOnlyExplicitVerification() async throws {
        let replies: [AuthenticationTestServer.Step] = [
            .ok(Data("not-json".utf8)),
            .ok(Data("{}".utf8), headers: ["Content-Length": "10"]),
            .ok(Data("{}".utf8), headers: ["Content-Length": "\(AuthenticationConfiguration.maximumResponseBytes + 1)"]),
            .ok(Data(repeating: 32, count: AuthenticationConfiguration.maximumResponseBytes + 1))
        ]
        for reply in replies {
            let fixture = try AuthenticationFixture([reply, .ok(AuthenticationFixture.session())])
            defer { fixture.close() }
            let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
            let delivery = try await fixture.client.sendEmailCode(id: request.id)
            XCTAssertEqual(delivery, .unconfirmed)
            let user = await fixture.client.currentUser()
            XCTAssertNil(user); XCTAssertNil(fixture.credentials.saved())
            await cancellation { _ = try await fixture.client.sendEmailCode(id: request.id) }
            _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456")
            XCTAssertEqual(fixture.server.requests().map(\.url.path), ["/auth/v1/otp", "/auth/v1/verify"])
            XCTAssertEqual(fixture.credentials.writes(), 1)
        }
    }

    func testServerFailureWithRateLimitBodyRemainsUnconfirmedAndExplicitlyRetryable() async throws {
        let misleading = AuthenticationFixture.ok(Data(#"{"error_code":"over_email_send_rate_limit"}"#.utf8),
            status: 503, headers: ["Retry-After": "60"])
        let fixture = try AuthenticationFixture([misleading, misleading, .ok(AuthenticationFixture.session())])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        let delivery = try await fixture.client.sendEmailCode(id: request.id)
        XCTAssertEqual(delivery, .unconfirmed, "HTTP 5xx does not establish whether a code was sent")
        await cancellation { _ = try await fixture.client.sendEmailCode(id: request.id) }
        await error(.connection) { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456") }
        XCTAssertEqual(fixture.server.requests().count, 2, "Neither ambiguous POST is automatically repeated")
        _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456")
        XCTAssertEqual(fixture.server.requests().map(\.url.path), ["/auth/v1/otp", "/auth/v1/verify", "/auth/v1/verify"])
    }

    func testVerificationFailuresPreserveOnlyTheOwnedChallengeForExplicitRetry() async throws {
        let fixture = try AuthenticationFixture([.ok(), .ok(Data(#"{"code":"over_request_rate_limit"}"#.utf8), status: 429, headers: ["Retry-After": "73"]),
            .ok(Data("not-json".utf8)), .fail(.networkConnectionLost), .ok(AuthenticationFixture.session())])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        _ = try await fixture.client.sendEmailCode(id: request.id)
        await error(.rateLimited(retryAfterSeconds: 73)) { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456") }
        XCTAssertEqual(fixture.server.requests().count, 2)
        await error(.invalidResponse) { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456") }
        XCTAssertEqual(fixture.server.requests().count, 3)
        await error(.connection) { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456") }
        XCTAssertEqual(fixture.server.requests().count, 4)
        _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456")
        XCTAssertEqual(fixture.server.requests().count, 5)
    }

    func testRateLimitedSendCanVerifyAnExistingCodeWithoutResending() async throws {
        let fixture = try AuthenticationFixture([
            .ok(Data(#"{"error_code":"over_email_send_rate_limit"}"#.utf8), status: 429, headers: ["Retry-After": "60"]),
            .ok(AuthenticationFixture.session())])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        await error(.rateLimited(retryAfterSeconds: 60)) { _ = try await fixture.client.sendEmailCode(id: request.id) }
        await cancellation { _ = try await fixture.client.sendEmailCode(id: request.id) }
        _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456")
        XCTAssertEqual(fixture.server.requests().map(\.url.path), ["/auth/v1/otp", "/auth/v1/verify"])
    }

    func testClosedSignupIsReportedAsNoAccountNotAsMissingConfiguration() async throws {
        let fixture = try AuthenticationFixture([
            .ok(Data(#"{"code":422,"error_code":"signup_disabled","msg":"Signups not allowed for this instance"}"#.utf8), status: 422),
            .ok(Data(#"{"code":400,"error_code":"otp_disabled"}"#.utf8), status: 400)])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "new.person@example.invalid")
        await error(.noAccount) { _ = try await fixture.client.sendEmailCode(id: request.id) }
        let disabled = try await fixture.client.prepareEmailSignIn(email: "new.person@example.invalid")
        await error(.configuration) { _ = try await fixture.client.sendEmailCode(id: disabled.id) }
    }

    func testAppleAdmissionHookRefusalHasAnActionableCategory() async throws {
        let fixture = try AuthenticationFixture([
            .ok(Data(#"{"code":403,"error_code":"hook_error","msg":"beta_invitation_required"}"#.utf8), status: 403)])
        defer { fixture.close() }
        let request = try await fixture.client.beginAppleSignIn()
        await error(.noAccount) { _ = try await fixture.client.finishAppleSignIn(id: request.id, identityToken: "fixture.identity.token") }
    }

    func testReplacementCancelsTheOldSendAndCannotVerifyOrCancelNewAuthority() async throws {
        let account = UUID(), fixture = try AuthenticationFixture([.hold, .ok(), .ok(AuthenticationFixture.session())])
        defer { fixture.close() }
        let old = try await fixture.client.prepareEmailSignIn(email: "old@example.invalid")
        let sending = Task { try await fixture.client.sendEmailCode(id: old.id) }
        await fulfillment(of: [fixture.server.arrived], timeout: 5)
        let current = try await fixture.client.prepareEmailSignIn(email: "current@example.invalid")
        await fulfillment(of: [fixture.server.cancelled], timeout: 5)
        fixture.server.release(.init(data: try AuthenticationFixture.session(account: account)))
        await cancellation { _ = try await sending.value }
        await cancellation { _ = try await fixture.client.finishEmailSignIn(id: old.id, code: "123456") }
        _ = try await fixture.client.sendEmailCode(id: current.id)
        let user = try await fixture.client.finishEmailSignIn(id: current.id, code: "123456")
        try await fixture.client.cancelSignIn(id: old.id)
        let retained = await fixture.client.currentUser()
        XCTAssertEqual(retained, user)
        XCTAssertEqual(fixture.server.requests().count, 3)
    }

    func testConcurrentEmailVerificationCannotExchangeTheSameCodeTwice() async throws {
        let fixture = try AuthenticationFixture([.ok(), .hold])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        _ = try await fixture.client.sendEmailCode(id: request.id)
        let first = Task { try await fixture.client.finishEmailSignIn(id: request.id, code: "123456") }
        await fulfillment(of: [fixture.server.arrived], timeout: 5)
        await cancellation { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "654321") }
        fixture.server.release(.init(data: try AuthenticationFixture.session()))
        _ = try await first.value
        XCTAssertEqual(fixture.server.requests().count, 2)
    }

    func testCanonicalCallbackMatchesTheRegisteredApplicationScheme() async throws {
        XCTAssertEqual(AuthenticationConfiguration.callback(in: .main), AuthenticationConfiguration.callbackURL)
        let fixture = try AuthenticationFixture([])
        defer { fixture.close() }
        let request = try await fixture.client.beginGoogleSignIn()
        XCTAssertEqual(request.callbackURL.absoluteString, "sciencereader://auth/callback")
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "redirect_to" })?.value, request.callbackURL.absoluteString)
        let wrong = try AuthenticationFixture([], callback: URL(string: "com.sciencereader.ios://auth-callback"))
        defer { wrong.close() }
        await error(.configuration) { _ = try await wrong.client.beginGoogleSignIn() }
        XCTAssertTrue(wrong.server.requests().isEmpty)
    }

    func testEmailCodeAndRequestBoundsFailBeforeNetworkDispatch() async throws {
        let fixture = try AuthenticationFixture([.ok()])
        defer { fixture.close() }
        for address in ["missing-at", "person@", "a\nb@example.invalid", String(repeating: "x", count: 321) + "@example.invalid"] {
            await error(.invalidEmail) { _ = try await fixture.client.prepareEmailSignIn(email: address) }
        }
        XCTAssertTrue(fixture.server.requests().isEmpty)
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        _ = try await fixture.client.sendEmailCode(id: request.id)
        for code in ["", "12345", "1234567", "１２３４５６", "12 456"] {
            await error(.invalidCode) { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: code) }
        }
        await error(.invalidResponse) {
            _ = try await fixture.client.signIn(email: "fixture", password: String(repeating: "x", count: 65_537))
        }
        XCTAssertEqual(fixture.server.requests().count, 1)
    }

    func testBoundedRepliesRejectOversizeTruncationRedirectAndWrongOrigin() async throws {
        let session = try AuthenticationFixture.session()
        let replies: [AuthenticationTestServer.Reply] = [
            .init(data: Data(), headers: ["Content-Length": "262145"]),
            .init(data: Data(repeating: 120, count: 262_145)),
            .init(data: session, headers: ["Content-Length": String(session.count + 1)]),
            .init(data: session, status: 302, headers: ["Location": "https://other.invalid/collect"]),
            .init(data: session, url: URL(string: "https://other.invalid/auth/v1/token")),
            .init(data: session, headers: ["Content-Encoding": "gzip"]),
            .init(data: session, status: 202)
        ]
        for reply in replies {
            let fixture = try AuthenticationFixture([.reply(reply)])
            defer { fixture.close() }
            await error(.invalidResponse) { _ = try await fixture.client.signIn(email: "fixture", password: "fixture") }
            let user = await fixture.client.currentUser()
            XCTAssertNil(user); XCTAssertNil(fixture.credentials.saved())
            XCTAssertEqual(fixture.server.requests().count, 1, "Auth does not dispatch a redirect or retry")
        }
    }

    func testSessionValidationAndRESTRelativeExpiryNeverPersistMalformedCredentials() async throws {
        let account = UUID()
        let base: [String: Any] = ["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3_600,
            "token_type": "bearer", "user": ["id": account.uuidString]]
        var malformed: [[String: Any]] = []
        let invalidFields: [(String, Any)] = [("access_token", ""), ("refresh_token", "bad\r\ntoken"),
            ("access_token", String(repeating: "x", count: 32_769)), ("expires_in", -1), ("token_type", "basic"),
            ("user", ["id": "not-a-uuid"])]
        for (key, value) in invalidFields {
            var row = base; row[key] = value; malformed.append(row)
        }
        for row in malformed {
            let fixture = try AuthenticationFixture([.ok(JSONSerialization.data(withJSONObject: row))])
            defer { fixture.close() }
            await error(.invalidResponse) { _ = try await fixture.client.signIn(email: "fixture", password: "fixture") }
            XCTAssertNil(fixture.credentials.saved())
        }
        let fixture = try AuthenticationFixture([.ok(JSONSerialization.data(withJSONObject: base))])
        defer { fixture.close() }
        let before = Date().timeIntervalSince1970
        let user = try await fixture.client.signIn(email: "fixture", password: "fixture")
        XCTAssertEqual(user.id, account); XCTAssertNil(user.email)
        let saved = try JSONDecoder().decode(AuthSession.self, from: XCTUnwrap(fixture.credentials.saved()))
        XCTAssertGreaterThanOrEqual(saved.expires_at, before + 3_600)
        XCTAssertLessThanOrEqual(saved.expires_at, Date().timeIntervalSince1970 + 3_600)
    }

    func testFailedCredentialDeletionInvalidatesMemoryAndAnOutstandingRefreshFirst() async throws {
        let account = UUID()
        let fixture = try AuthenticationFixture([.hold], stored: AuthenticationFixture.session(account: account, expiresAt: 0))
        defer { fixture.close() }
        let reading = Task { let _: EmptyResponse = try await fixture.client.rpc("v1_library", params: EmptyResponse()) }
        await fulfillment(of: [fixture.server.arrived], timeout: 5)
        fixture.credentials.failures(delete: true)
        await error(.credentialStorage) { try await fixture.client.signOut() }
        let user = await fixture.client.currentUser()
        XCTAssertNil(user, "Fallible deletion must not retain in-memory authority")
        XCTAssertNotNil(fixture.credentials.saved(), "Do not claim durable deletion when Keychain refused it")
        await fulfillment(of: [fixture.server.cancelled], timeout: 5)
        fixture.server.release(.init(data: try AuthenticationFixture.session(account: account)))
        await cancellation { _ = try await reading.value }
        await error(.credentialStorage) { _ = try await fixture.client.beginGoogleSignIn() }
        XCTAssertEqual(fixture.server.requests().count, 1)
        fixture.credentials.failures(delete: false)
        _ = try await fixture.client.beginGoogleSignIn()
        XCTAssertNil(fixture.credentials.saved())
    }

    func testLocalSignOutReturnsBeforeHeldLogoutAndNewProviderRetiresItsTransfer() async throws {
        let lateReplies: [AuthenticationTestServer.Reply] = [
            .init(data: Data(), status: 204),
            .init(data: Data(#"{"error_code":"unknown_retired_request"}"#.utf8), status: 503)
        ]
        for lateReply in lateReplies {
            let oldAccount = UUID(), newAccount = UUID()
            let fixture = try AuthenticationFixture([
                .hold, .ok(AuthenticationFixture.session(account: newAccount, accessToken: "new-session-access"))
            ], stored: AuthenticationFixture.session(account: oldAccount, accessToken: "retired-session-access"))
            defer { fixture.close() }
            let locallyRetired = expectation(description: "Sign-out completes while its remote response is held")
            let signingOut = Task {
                try await fixture.client.signOut()
                locallyRetired.fulfill()
            }
            await fulfillment(of: [locallyRetired, fixture.server.arrived], timeout: 5)
            let retired = await fixture.client.currentUser()
            XCTAssertNil(retired); XCTAssertNil(fixture.credentials.saved())
            let logout = try XCTUnwrap(fixture.server.requests().first)
            XCTAssertEqual(logout.url.path, "/auth/v1/logout")
            XCTAssertEqual(URLComponents(url: logout.url, resolvingAgainstBaseURL: false)?.queryItems,
                [URLQueryItem(name: "scope", value: "local")])
            XCTAssertEqual(logout.headers.first(where: { $0.key.lowercased() == "authorization" })?.value,
                "Bearer retired-session-access")

            let next = try await fixture.client.beginGoogleSignIn()
            await fulfillment(of: [fixture.server.cancelled], timeout: 5)
            var callback = try XCTUnwrap(URLComponents(url: next.callbackURL, resolvingAgainstBaseURL: false))
            callback.queryItems = [URLQueryItem(name: "code", value: "new-owned-code")]
            let accepted = try await fixture.client.finishGoogleSignIn(id: next.id, callbackURL: XCTUnwrap(callback.url))
            XCTAssertEqual(accepted.id, newAccount)
            // The cancelled URLProtocol can still deliver a late callback. It
            // must not become a logout or credential mutation for this session.
            fixture.server.release(lateReply)
            try await signingOut.value
            let retained = await fixture.client.currentUser()
            XCTAssertEqual(retained?.id, newAccount)
            let stored = try JSONDecoder().decode(AuthSession.self, from: XCTUnwrap(fixture.credentials.saved()))
            XCTAssertEqual(stored.user.id, newAccount)
            XCTAssertEqual(stored.access_token, "new-session-access")
            XCTAssertEqual(fixture.server.requests().map(\.url.path), ["/auth/v1/logout", "/auth/v1/token"])
            XCTAssertEqual(fixture.credentials.writes(), 1)
        }
    }

    func testFailedLocalRetirementDispatchesNoLogoutAndBlocksNewPreparationUntilCleanup() async throws {
        let fixture = try AuthenticationFixture([], stored: AuthenticationFixture.session())
        defer { fixture.close() }
        fixture.credentials.failures(delete: true)
        await error(.credentialStorage) { try await fixture.client.signOut() }
        let retired = await fixture.client.currentUser()
        XCTAssertNil(retired); XCTAssertNotNil(fixture.credentials.saved())
        await error(.credentialStorage) { _ = try await fixture.client.beginGoogleSignIn() }
        XCTAssertTrue(fixture.server.requests().isEmpty)
        fixture.credentials.failures(delete: false)
        _ = try await fixture.client.beginAppleSignIn()
        XCTAssertNil(fixture.credentials.saved())
        XCTAssertTrue(fixture.server.requests().isEmpty, "A discarded old token is not resurrected for logout")
    }

    func testPartialCredentialWriteCannotAcceptOrBypassRequiredCleanup() async throws {
        let fixture = try AuthenticationFixture([.ok(), .ok(AuthenticationFixture.session())])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        _ = try await fixture.client.sendEmailCode(id: request.id)
        fixture.credentials.failures(delete: true, writeAfterCommit: true)
        await error(.credentialStorage) { _ = try await fixture.client.finishEmailSignIn(id: request.id, code: "123456") }
        let user = await fixture.client.currentUser()
        XCTAssertNil(user); XCTAssertNotNil(fixture.credentials.saved())
        await error(.credentialStorage) { _ = try await fixture.client.prepareEmailSignIn(email: "other@example.invalid") }
        await error(.credentialStorage) { try await fixture.client.cancelSignIn(id: request.id) }
        XCTAssertEqual(fixture.server.requests().count, 2)
        fixture.credentials.failures(delete: false)
        let fresh = try await fixture.client.prepareEmailSignIn(email: "other@example.invalid")
        XCTAssertNotEqual(fresh.id, request.id); XCTAssertNil(fixture.credentials.saved())
    }

    func testUnknownProviderBodiesDoNotBecomeUIErrorsOrKnownCodes() async throws {
        let fixture = try AuthenticationFixture([.ok(Data(#"{"message":"otp_expired SECRET_CALLBACK_TOKEN","error_code":"unknown_SECRET"}"#.utf8), status: 400)])
        defer { fixture.close() }
        let request = try await fixture.client.prepareEmailSignIn(email: "person@example.invalid")
        await error(.rejected) { _ = try await fixture.client.sendEmailCode(id: request.id) }
        XCTAssertFalse(AuthenticationError.rejected.localizedDescription.contains("SECRET"))
        XCTAssertNil(fixture.credentials.saved())
    }

    private func error(_ expected: AuthenticationError, file: StaticString = #filePath, line: UInt = #line,
                       _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected a finite authentication failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? AuthenticationError, expected, file: file, line: line) }
    }
    private func cancellation(file: StaticString = #filePath, line: UInt = #line,
                              _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected stale/cancelled ownership", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, file: file, line: line) }
    }
}

private extension AuthenticationTestServer.Step {
    static func ok(_ data: Data = Data("{}".utf8), status: Int = 200, headers: [String: String] = [:]) -> Self {
        AuthenticationFixture.ok(data, status: status, headers: headers)
    }
}

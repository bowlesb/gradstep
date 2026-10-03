import CryptoKit
import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

private final class OAuthServer: @unchecked Sendable {
    private let lock = NSLock()
    let account = UUID()
    let arrived = XCTestExpectation(description: "OAuth exchange started")
    var holdExchange = false
    private var pending: StubProtocol?
    private var payloads: [[String: String]] = []

    func handle(_ request: StubProtocol) {
        lock.withLock {
            guard request.request.url?.path == "/auth/v1/token" else { request.respond(Data("{}".utf8), status: 404); return }
            payloads.append(Self.body(request.request))
            if holdExchange { pending = request; arrived.fulfill() }
            else { request.respond(session()) }
        }
    }
    private func session() -> Data {
        try! ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + 3600, user: .init(id: account, email: "fixture@example.invalid")))
    }
    func release() { lock.withLock { pending?.respond(session()); pending = nil; holdExchange = false } }
    func requests() -> [[String: String]] { lock.withLock { payloads } }
    private static func body(_ request: URLRequest) -> [String: String] {
        let data: Data
        if let bytes = request.httpBody { data = bytes }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096); var bytes = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        } else { data = Data() }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

@MainActor
final class OAuthSafetyTests: XCTestCase {
    private func fixture(_ server: OAuthServer) throws -> (BackendClient, String, String) {
        let environment = "oauth-safety-\(UUID().wire)", host = environment + ".invalid"
        StubProtocol.install(host: host) { server.handle($0) }
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [StubProtocol.self]
        let client = try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment),
                                       network: URLSession(configuration: network))
        return (client, environment, host)
    }
    private func clean(_ environment: String, _ host: String) {
        StubProtocol.remove(host: host); try? KeychainVault.delete(environment + ".auth-session")
    }
    private func callback(_ request: GoogleAuthorization) -> URL { URL(string: request.callbackURL.absoluteString + "?code=fixture-code")! }

    func testGoogleAndAppleExchangesBindPerAttemptSecrets() async throws {
        let server = OAuthServer(), (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let google = try await client.beginGoogleSignIn()
        let user = try await client.finishGoogleSignIn(id: google.id, callbackURL: callback(google))
        XCTAssertEqual(user.id, server.account)
        let payload = try XCTUnwrap(server.requests().first), verifier = try XCTUnwrap(payload["code_verifier"])
        XCTAssertEqual(payload["auth_code"], "fixture-code")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(URLComponents(url: google.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code_challenge" }?.value, challenge)
        XCTAssertNil(google.url.absoluteString.range(of: verifier))

        let apple = try await client.beginAppleSignIn()
        _ = try await client.finishAppleSignIn(id: apple.id, identityToken: "fixture-apple-token")
        let applePayload = try XCTUnwrap(server.requests().last), nonce = try XCTUnwrap(applePayload["nonce"])
        XCTAssertEqual(applePayload["provider"], "apple")
        XCTAssertEqual(applePayload["id_token"], "fixture-apple-token")
        XCTAssertEqual(Data(SHA256.hash(data: Data(nonce.utf8))).hex, apple.hashedNonce)
        XCTAssertFalse(try XCTUnwrap(KeychainVault.read(environment + ".auth-session")).contains(Data(nonce.utf8)))
    }

    func testCancelledAndOlderCallbacksCannotStartAnExchange() async throws {
        let server = OAuthServer(), (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let old = try await client.beginGoogleSignIn()
        try await client.cancelSignIn(id: old.id)
        let current = try await client.beginGoogleSignIn()
        do { _ = try await client.finishGoogleSignIn(id: old.id, callbackURL: callback(old)); XCTFail("Stale callback must fail") }
        catch is CancellationError { }
        _ = try await client.finishGoogleSignIn(id: current.id, callbackURL: callback(current))
        try await client.cancelSignIn(id: old.id)
        let user = await client.currentUser()
        XCTAssertEqual(user?.id, server.account); XCTAssertEqual(server.requests().count, 1)
        // Cancellation can still beat UI delivery after the HTTP exchange.
        try await client.cancelSignIn(id: current.id)
        let cancelled = await client.currentUser()
        XCTAssertNil(cancelled); XCTAssertNil(try KeychainVault.read(environment + ".auth-session"))
    }

    func testLateExchangeAfterSignOutCannotRestoreSession() async throws {
        let server = OAuthServer(); server.holdExchange = true
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let request = try await client.beginGoogleSignIn()
        let exchanging = Task { try await client.finishGoogleSignIn(id: request.id, callbackURL: callback(request)) }
        await fulfillment(of: [server.arrived], timeout: 5)
        try await client.signOut()
        server.release()
        do { _ = try await exchanging.value; XCTFail("Signed-out exchange must fail") }
        catch is CancellationError { }
        let user = await client.currentUser()
        XCTAssertNil(user); XCTAssertNil(try KeychainVault.read(environment + ".auth-session"))
    }

    func testOneAttemptCannotExchangeTwice() async throws {
        let server = OAuthServer(); server.holdExchange = true
        let (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let request = try await client.beginGoogleSignIn()
        let exchanging = Task { try await client.finishGoogleSignIn(id: request.id, callbackURL: callback(request)) }
        await fulfillment(of: [server.arrived], timeout: 5)
        do { _ = try await client.finishGoogleSignIn(id: request.id, callbackURL: callback(request)); XCTFail("Concurrent replay must fail") }
        catch is CancellationError { }
        server.release(); _ = try await exchanging.value
        do { _ = try await client.finishGoogleSignIn(id: request.id, callbackURL: callback(request)); XCTFail("Completed replay must fail") }
        catch is CancellationError { }
        XCTAssertEqual(server.requests().count, 1)
    }

    func testWrongDestinationAndProviderCannotExchangeCredentials() async throws {
        let server = OAuthServer(), (client, environment, host) = try fixture(server)
        defer { clean(environment, host) }
        let request = try await client.beginGoogleSignIn()
        do { _ = try await client.finishGoogleSignIn(id: request.id, callbackURL: URL(string: "other.app://auth-callback?code=fixture")!); XCTFail("Wrong callback must fail") }
        catch OAuthFlowError.invalidCallback { }
        do { _ = try await client.finishAppleSignIn(id: request.id, identityToken: "fixture"); XCTFail("Wrong provider must fail") }
        catch is CancellationError { }
        XCTAssertTrue(server.requests().isEmpty)
    }
}

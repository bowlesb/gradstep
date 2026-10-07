#if DEBUG && FIXTURE_HOST && !OFFLINE_RESOURCE_MEASUREMENTS
import Foundation
import ScienceReaderCore
import UIKit

/// Local workflow evidence only. No provider UI, DNS request, hosted account,
/// fresh-key bootstrap, or private-history write is part of this fixture.
enum AuthenticationWorkflowFixture {
    static let environment = "authentication-workflow-v1"
    static let host = "authentication-workflow.invalid"
    static let accountID = UUID(uuidString: "faaaaaaa-0000-0000-0000-000000000001")!
    static let acceptedCode = "654321"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--authentication-fixture") &&
            !ProcessInfo.processInfo.arguments.contains("--offline-resource-fixture")
    }

    enum Failure: Error { case disabled, invalidArguments, invalidRequest }

    static func makeBackend() throws -> (configuration: BackendConfiguration, client: BackendClient) {
        guard isEnabled else { throw Failure.disabled }
        let arguments = ProcessInfo.processInfo.arguments
        for pair in [["--authentication-apple-cancel", "--authentication-apple-fail"],
                     ["--authentication-google-cancel", "--authentication-google-fail"],
                     ["--authentication-send-unconfirmed", "--authentication-send-throttled"]] {
            guard pair.filter({ arguments.contains($0) }).count <= 1 else { throw Failure.invalidArguments }
        }
        if arguments.contains("--reset-authentication-fixture") {
            // These exact synthetic names never overlap a configured account.
            // Keep unrelated account keys, encrypted stores and outboxes intact.
            for name in [environment + ".auth-session",
                         environment + "." + accountID.wire + ".device-keys",
                         environment + "." + accountID.wire + ".device-keys.pending-enrollment"] {
                try KeychainVault.delete(name)
            }
        }
        AuthenticationWorkflowProtocol.reset()
        let settings = URLSessionConfiguration.ephemeral
        // This private protocol admits every URLSession request so unexpected
        // destinations fail here, rather than falling through to the network.
        settings.protocolClasses = [AuthenticationWorkflowProtocol.self]
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.httpShouldSetCookies = false; settings.waitsForConnectivity = false
        let configuration = BackendConfiguration(url: URL(string: "https://" + host)!,
            anonKey: "authentication-fixture-anon", environment: environment)
        let client = try BackendClient(configuration: configuration, network: URLSession(configuration: settings))
        return (configuration, client)
    }

    @MainActor
    static func presenter(anchor: UIWindow) -> any AuthenticationPresenting {
        // Deliberately does not construct an Apple/Google system presenter.
        AuthenticationWorkflowPresenter(enabled: isEnabled)
    }
}

private final class AuthenticationWorkflowProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestsRemaining = 64
    nonisolated(unsafe) private static var sentAddresses: Set<String> = []

    static func reset() {
        lock.withLock { requestsRemaining = 64; sentAddresses = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard AuthenticationWorkflowFixture.isEnabled,
                  let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "https", components.host == AuthenticationWorkflowFixture.host,
                  components.user == nil, components.password == nil, components.port == nil,
                  components.fragment == nil, request.httpMethod == "POST",
                  Self.lock.withLock({
                      guard Self.requestsRemaining > 0 else { return false }
                      Self.requestsRemaining -= 1; return true
                  }) else { throw AuthenticationWorkflowFixture.Failure.invalidRequest }
            let data = try Self.body(request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AuthenticationWorkflowFixture.Failure.invalidRequest
            }
            if url.path == "/auth/v1/logout" {
                guard components.query == "scope=local" else { throw AuthenticationWorkflowFixture.Failure.invalidRequest }
            } else if url.path != "/auth/v1/token", components.query != nil {
                throw AuthenticationWorkflowFixture.Failure.invalidRequest
            }
            switch url.path {
            case "/auth/v1/otp":
                let address = try Self.address(object)
                guard object["create_user"] as? Bool == true else { throw AuthenticationWorkflowFixture.Failure.invalidRequest }
                _ = Self.lock.withLock { Self.sentAddresses.insert(address) }
                if ProcessInfo.processInfo.arguments.contains("--authentication-send-unconfirmed") {
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                } else if ProcessInfo.processInfo.arguments.contains("--authentication-send-throttled") {
                    try respond(["error_code": "over_email_send_rate_limit"], status: 429, headers: ["Retry-After": "60"])
                } else { try respond([:]) }

            case "/auth/v1/verify":
                let address = try Self.address(object)
                guard object["type"] as? String == "email",
                      Self.lock.withLock({ Self.sentAddresses.contains(address) }) else {
                    throw AuthenticationWorkflowFixture.Failure.invalidRequest
                }
                if object["token"] as? String == AuthenticationWorkflowFixture.acceptedCode { try respondSession() }
                else { try respond(["error_code": "otp_expired"], status: 403) }

            case "/auth/v1/token":
                let query = components.queryItems ?? []
                guard query.count == 1, query[0].name == "grant_type" else { throw AuthenticationWorkflowFixture.Failure.invalidRequest }
                switch query[0].value {
                case "pkce":
                    guard object["auth_code"] as? String == "authentication-fixture-code",
                          let verifier = object["code_verifier"] as? String, (43...128).contains(verifier.utf8.count) else {
                        throw AuthenticationWorkflowFixture.Failure.invalidRequest
                    }
                case "id_token":
                    guard object["provider"] as? String == "apple",
                          object["id_token"] as? String == "authentication-fixture-token",
                          let nonce = object["nonce"] as? String, !nonce.isEmpty else {
                        throw AuthenticationWorkflowFixture.Failure.invalidRequest
                    }
                case "refresh_token":
                    guard object["refresh_token"] as? String == "authentication-fixture-refresh" else {
                        throw AuthenticationWorkflowFixture.Failure.invalidRequest
                    }
                default: throw AuthenticationWorkflowFixture.Failure.invalidRequest
                }
                try respondSession()

            case "/auth/v1/logout":
                try requireSession(); try respond([:])

            case "/rest/v1/rpc/v1_key_state":
                try requireSession()
                guard let device = object["p_device_id"] as? String, UUID(uuidString: device) != nil else {
                    throw AuthenticationWorkflowFixture.Failure.invalidRequest
                }
                // A known existing keyring without this device's envelope.
                // The finite placeholder is never accepted for recovery; there
                // is intentionally no enrollment/bootstrap route in this fixture.
                try respond(["epoch": 1, "recovery_package": "\\x00", "device_envelope": NSNull()])

            case "/rest/v1/rpc/v4_library_page":
                try requireSession()
                try respond(["format": 2, "account_id": AuthenticationWorkflowFixture.accountID.wire,
                    "baseline_cursor": 0, "retained_after": 0, "entries": [], "next_cursor": NSNull(), "has_more": false])

            case "/rest/v1/rpc/v4_library_changes":
                try requireSession()
                try respond(["format": 2, "account_id": AuthenticationWorkflowFixture.accountID.wire,
                    "through": 0, "retained_after": 0, "changes": [], "next_cursor": 0, "has_more": false])

            case "/rest/v1/rpc/v2_reports":
                try requireSession(); try respond([])

            default: throw AuthenticationWorkflowFixture.Failure.invalidRequest
            }
        } catch {
            // Never emit a captured URL, body, token or arbitrary error text.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() { }

    private static func address(_ object: [String: Any]) throws -> String {
        guard let address = object["email"] as? String, address.utf8.count <= 320,
              address.hasSuffix("@example.invalid"), !address.contains(where: { $0.isWhitespace }) else {
            throw AuthenticationWorkflowFixture.Failure.invalidRequest
        }
        return address
    }

    private static func body(_ request: URLRequest) throws -> Data {
        let limit = AuthenticationConfiguration.maximumRequestBytes
        if let data = request.httpBody {
            guard data.count <= limit else { throw AuthenticationWorkflowFixture.Failure.invalidRequest }
            return data
        }
        guard let stream = request.httpBodyStream else { throw AuthenticationWorkflowFixture.Failure.invalidRequest }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, data.count <= limit - count else { throw AuthenticationWorkflowFixture.Failure.invalidRequest }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func requireSession() throws {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer authentication-fixture-access" else {
            throw AuthenticationWorkflowFixture.Failure.invalidRequest
        }
    }

    private func respondSession() throws {
        try respond(["access_token": "authentication-fixture-access", "refresh_token": "authentication-fixture-refresh",
            "expires_at": Date().timeIntervalSince1970 + 3_600,
            "user": ["id": AuthenticationWorkflowFixture.accountID.wire, "email": NSNull()]])
    }

    private func respond(_ object: Any, status: Int = 200, headers: [String: String] = [:]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 4_096, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)].merging(headers) { _, value in value }) else {
            throw AuthenticationWorkflowFixture.Failure.invalidRequest
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private final class AuthenticationWorkflowPresenter: AuthenticationPresenting {
    private let enabled: Bool
    private var cancelled = false
    init(enabled: Bool) { self.enabled = enabled }

    func google(_ authorization: GoogleAuthorization) async throws -> URL {
        guard authorization.url.host == AuthenticationWorkflowFixture.host,
              authorization.callbackURL == AuthenticationConfiguration.callbackURL else {
            throw AuthenticationPresentationError.unavailable
        }
        try await outcome(for: "google")
        var callback = URLComponents(url: authorization.callbackURL, resolvingAgainstBaseURL: false)!
        callback.queryItems = [URLQueryItem(name: "code", value: "authentication-fixture-code")]
        return callback.url!
    }

    func apple(_ authorization: AppleAuthorization) async throws -> String {
        guard authorization.hashedNonce.utf8.count == 64 else { throw AuthenticationPresentationError.unavailable }
        try await outcome(for: "apple")
        return "authentication-fixture-token"
    }

    func cancel() { cancelled = true }

    private func outcome(for provider: String) async throws {
        try Task.checkCancellation()
        guard enabled, !cancelled else { throw AuthenticationPresentationError.cancelled }
        await Task.yield()
        try Task.checkCancellation()
        guard !cancelled else { throw AuthenticationPresentationError.cancelled }
        if ProcessInfo.processInfo.arguments.contains("--authentication-\(provider)-cancel") {
            throw AuthenticationPresentationError.cancelled
        }
        if ProcessInfo.processInfo.arguments.contains("--authentication-\(provider)-fail") {
            throw AuthenticationPresentationError.unavailable
        }
    }
}
#endif

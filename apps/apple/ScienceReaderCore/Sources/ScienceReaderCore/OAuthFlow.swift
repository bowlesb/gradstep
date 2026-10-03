import CryptoKit
import Foundation

public enum OAuthFlowError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidCallback, providerDenied
}

/// Per-attempt PKCE material, deliberately not Codable or persisted. The owner
/// must consume the attempt once and reject callbacks from older auth sessions.
public struct OAuthPKCEAttempt: Sendable {
    public let id: UUID
    public let callbackURL: URL
    public let verifier: String

    public init(callbackURL: URL) throws {
        try self.init(callbackURL: callbackURL, verifier: ReaderCrypto.randomKey().base64URL)
    }

    init(callbackURL: URL, verifier: String) throws {
        guard let target = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let scheme = target.scheme, scheme != "http", !scheme.isEmpty,
              target.host?.isEmpty == false, target.user == nil, target.password == nil,
              target.port == nil, target.query == nil, target.fragment == nil,
              (43...128).contains(verifier.utf8.count),
              verifier.utf8.allSatisfy({ Self.unreserved.contains($0) }) else { throw OAuthFlowError.invalidConfiguration }
        self.id = UUID(); self.callbackURL = callbackURL; self.verifier = verifier
    }

    public func authorizationURL(supabaseURL: URL) throws -> URL {
        guard var source = URLComponents(url: supabaseURL, resolvingAgainstBaseURL: false),
              source.scheme == "https", source.host?.isEmpty == false,
              source.user == nil, source.password == nil, source.port == nil,
              source.path.isEmpty || source.path == "/", source.query == nil, source.fragment == nil else {
            throw OAuthFlowError.invalidConfiguration
        }
        source.path = "/auth/v1/authorize"
        source.queryItems = [
            .init(name: "provider", value: "google"),
            .init(name: "redirect_to", value: callbackURL.absoluteString),
            .init(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            .init(name: "code_challenge_method", value: "s256")
        ]
        guard let result = source.url else { throw OAuthFlowError.invalidConfiguration }
        return result
    }

    public func authorizationCode(from url: URL) throws -> String {
        guard url.absoluteString.utf8.count <= 8_192,
              let expected = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let received = URLComponents(url: url, resolvingAgainstBaseURL: false),
              received.scheme?.lowercased() == expected.scheme?.lowercased(),
              received.host?.lowercased() == expected.host?.lowercased(),
              received.percentEncodedPath == expected.percentEncodedPath,
              received.user == nil, received.password == nil, received.port == nil,
              received.fragment == nil else { throw OAuthFlowError.invalidCallback }
        let items = received.queryItems ?? []
        if items.contains(where: { ["error", "error_code", "error_description"].contains($0.name) }) {
            throw OAuthFlowError.providerDenied
        }
        // Token-fragment/implicit callbacks must not accidentally become an
        // alternate session-establishment path as this client evolves.
        guard !items.contains(where: { ["access_token", "refresh_token", "id_token"].contains($0.name) }) else {
            throw OAuthFlowError.invalidCallback
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, (1...2_048).contains(code.utf8.count),
              code.utf8.allSatisfy({ Self.unreserved.contains($0) }) else { throw OAuthFlowError.invalidCallback }
        return code
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
}

public struct AppleSignInNonce: Sendable {
    public let raw: String
    public let hashed: String
    public init() {
        raw = ReaderCrypto.randomKey().base64URL
        hashed = Data(SHA256.hash(data: Data(raw.utf8))).hex
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

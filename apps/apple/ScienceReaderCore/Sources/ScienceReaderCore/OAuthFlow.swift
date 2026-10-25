import CryptoKit
import Foundation

public enum OAuthFlowError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidCallback, providerDenied, invitationRequired
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
              received.user == nil, received.password == nil, received.port == nil else { throw OAuthFlowError.invalidCallback }
        // Auth can return provider errors in a fragment even for a PKCE attempt. Only an error is
        // accepted there: implicit tokens, mixed query/fragment credentials and codes remain invalid.
        // A fragment naming no OAuth parameter is the browser's, not Auth's. WebKit keeps the fragment of an earlier page
        // in a redirect chain on a redirect whose Location has none (Supabase's 302 never has one), so the provider's own
        // pages can leave `#` or `#…` on the return. It is ignored: the code still needs this attempt's verifier
        // (TestFlight 92: Supabase issued the code, and the app refused the return with "Couldn't verify").
        let items: [URLQueryItem]
        if let fragment = received.percentEncodedFragment, Self.fragmentSpeaksForAuth(fragment) {
            guard received.query == nil, let parts = URLComponents(string: "?" + fragment),
                  parts.fragment == nil, let values = parts.queryItems, !values.isEmpty,
                  values.allSatisfy({ ["error", "error_code", "error_description"].contains($0.name) }) else {
                throw OAuthFlowError.invalidCallback
            }
            items = values
        } else { items = received.queryItems ?? [] }
        if items.contains(where: { ["error", "error_code", "error_description"].contains($0.name) }) {
            guard !items.contains(where: { ["code", "access_token", "refresh_token", "id_token"].contains($0.name) }),
                  Set(items.map(\.name)).count == items.count else { throw OAuthFlowError.invalidCallback }
            if items.contains(where: { $0.name == "error_code" && $0.value == "signup_disabled" }) ||
                items.contains(where: { $0.name == "error_description" && $0.value == "beta_invitation_required" }) {
                throw OAuthFlowError.invitationRequired
            }
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

    /// A description of a sign-in return for diagnostics, safe to keep and send: whether it reached this attempt's
    /// address, which OAuth parameter names arrived in its query and fragment, the code's shape, a short snake_case
    /// `error`/`error_code`, and its length. Never a code, token, description or any other value.
    public func describeCallback(_ url: URL) -> String {
        let length = url.absoluteString.utf8.count
        guard let received = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { return "unreadable length=\(length)" }
        var differs: [String] = []
        if received.scheme?.lowercased() != expected.scheme?.lowercased() { differs.append("scheme") }
        if received.host?.lowercased() != expected.host?.lowercased() { differs.append("host") }
        if received.percentEncodedPath != expected.percentEncodedPath { differs.append("path") }
        if received.user != nil || received.password != nil || received.port != nil { differs.append("authority") }
        let query = Self.parameters(received.percentEncodedQuery), fragment = Self.parameters(received.percentEncodedFragment)
        var parts = ["destination=" + (differs.isEmpty ? "ok" : differs.joined(separator: "+")),
                     "query=" + Self.names(received.percentEncodedQuery, query),
                     "fragment=" + Self.names(received.percentEncodedFragment, fragment)]
        let all = (query ?? []) + (fragment ?? [])
        if let code = all.first(where: { $0.name == "code" })?.value {
            let uuid = UUID(uuidString: code) != nil && code.utf8.count == 36
            parts.append("code=" + (uuid ? "uuid" : "\(code.utf8.count)ch") +
                         (code.utf8.allSatisfy { Self.unreserved.contains($0) } ? "" : ",unsafe"))
        }
        for name in ["error", "error_code"] {
            if let value = all.first(where: { $0.name == name })?.value, (1...48).contains(value.utf8.count),
               value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) { parts.append("\(name)=\(value)") }
        }
        parts.append("length=\(length)")
        return parts.joined(separator: " ")
    }

    /// Whether a callback fragment is Auth's: it names an OAuth parameter (any case, percent-decoded) or cannot be read.
    static func fragmentSpeaksForAuth(_ fragment: String) -> Bool {
        guard !fragment.isEmpty else { return false }
        guard let items = parameters(fragment) else { return true }
        return items.contains { authParameters.contains($0.name.lowercased()) }
    }

    private static func parameters(_ encoded: String?) -> [URLQueryItem]? {
        guard let encoded, !encoded.isEmpty, let parts = URLComponents(string: "?" + encoded), parts.fragment == nil else { return nil }
        return parts.queryItems ?? []
    }

    private static func names(_ encoded: String?, _ items: [URLQueryItem]?) -> String {
        guard let encoded else { return "none" }
        if encoded.isEmpty { return "empty" }
        guard let items else { return "unreadable" }
        let known = items.map { $0.name.lowercased() }.filter { authParameters.contains($0) || $0 == "state" }
        let other = items.count - known.count
        return (known + (other > 0 ? ["other:\(other)"] : [])).joined(separator: ",")
    }

    /// Names Auth uses in a return: a code, provider errors, or implicit-flow credentials.
    private static let authParameters: Set<String> = ["code", "error", "error_code", "error_description", "access_token",
        "refresh_token", "id_token", "provider_token", "provider_refresh_token", "token_type", "expires_in", "expires_at"]
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

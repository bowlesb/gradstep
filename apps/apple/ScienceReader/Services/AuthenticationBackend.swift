import Foundation

/// The presentation owner never stores credentials or accepts callback tokens
/// itself. Preparation is separate from HTTP so Close can retire its exact ID.
protocol AuthenticationBackend: Sendable {
    func currentUser() async -> AuthSession.User?
    func beginGoogleSignIn() async throws -> GoogleAuthorization
    func finishGoogleSignIn(id: UUID, callbackURL: URL) async throws -> AuthSession.User
    func beginAppleSignIn() async throws -> AppleAuthorization
    func finishAppleSignIn(id: UUID, identityToken: String) async throws -> AuthSession.User
    func prepareEmailSignIn(email: String) async throws -> EmailAuthorization
    func sendEmailCode(id: UUID) async throws -> EmailCodeDelivery
    func finishEmailSignIn(id: UUID, code: String) async throws -> AuthSession.User
    func cancelSignIn(id: UUID) async throws
    func signOut() async throws
}

struct EmailAuthorization: Equatable, Sendable {
    let id: UUID
    let email: String
}

enum EmailCodeDelivery: Equatable, Sendable {
    case sent
    /// The one request may have delivered a code. Entering it remains possible;
    /// this result never authorizes an automatic second send.
    case unconfirmed
}

enum AuthenticationError: Error, Equatable, Sendable, LocalizedError {
    /// noAccount: sign-up is closed (invitation-only beta) and no account uses this identity.
    case configuration, noAccount, invalidEmail, invalidCode
    case rateLimited(retryAfterSeconds: Int?)
    case connection, invalidResponse, credentialStorage, rejected

    var errorDescription: String? {
        switch self {
        case .configuration: "Sign-in is not configured for this build."
        case .noAccount: "No account uses this email yet."
        case .invalidEmail: "Enter a valid email address."
        case .invalidCode: "That code wasn’t accepted. Check it or request a new code."
        case .rateLimited: "Too many attempts. Wait before trying again."
        case .connection: "The connection was interrupted. Please try again."
        case .invalidResponse: "Sign-in returned an invalid response. Please try again."
        case .credentialStorage: "Sign-in details couldn’t be updated securely. Please try again."
        case .rejected: "Sign-in couldn’t be completed. Please try again."
        }
    }
}

enum AuthenticationConfiguration {
    static let callbackURL = URL(string: "sciencereader://auth/callback")!
    static let maximumResponseBytes = 256 * 1_024
    static let maximumRequestBytes = 64 * 1_024
    static let maximumTokenBytes = 32 * 1_024

    /// No fallback to a different callback spelling or an unregistered scheme.
    /// Probe targets have no callback registration and cannot start Google.
    static func callback(in bundle: Bundle) -> URL? {
        guard let source = bundle.object(forInfoDictionaryKey: "ScienceReaderAuthCallbackURL") as? String,
              source == callbackURL.absoluteString,
              let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(callbackURL.scheme!) == true }) else { return nil }
        return callbackURL
    }
}

/// Synchronous and narrowly injected: failures cannot yield between generation
/// invalidation and Keychain cleanup. Account encryption keys are out of scope.
protocol AuthenticationCredentialStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, name: String) throws
    func delete(_ name: String) throws
}

struct KeychainAuthenticationCredentialStore: AuthenticationCredentialStore {
    func read(_ name: String) throws -> Data? { try KeychainVault.read(name) }
    func write(_ data: Data, name: String) throws { try KeychainVault.write(data, name: name) }
    func delete(_ name: String) throws { try KeychainVault.delete(name) }
}

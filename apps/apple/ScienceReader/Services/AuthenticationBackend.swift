import Foundation
import os
import ScienceReaderCore

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
    case connection, invalidResponse, credentialStorage, rejected, sessionExpired

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
        case .sessionExpired: "Your session has ended. Sign in again to use your account."
        }
    }
}

/// A definitive rejection of one cached session, never an offline/network failure.
struct AuthenticationInvalidation: Equatable, Sendable {
    let id: UUID
    let accountID: UUID
    let credentialStorageFailed: Bool
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

/// Why sign-in failed on this device, so the next failure can be diagnosed from a report or a screenshot (TestFlight 92: a
/// refused Google return left no trace on the device or the server). Each entry is the method, the stage, a short reason
/// and, for a refused Google return, its shape (`OAuthPKCEAttempt.describeCallback`: parameter names, never a value).
/// Nothing here identifies the person or carries a credential. Kept in this device's defaults, not an account's store
/// (the person is signed out): at most eight entries, each for 14 days. Also written to the unified log.
final class SignInDiagnostics: @unchecked Sendable {
    struct Failure: Codable, Equatable, Sendable {
        let at: Date
        let build: String
        let method: String
        let stage: String
        let reason: String
        let detail: String?

        /// Short enough to read off a screenshot under the error.
        var reference: String { "\(method)-\(stage)-\(reason)" }
        var supportLine: String {
            "\(at.ISO8601Format()) build \(build): \(reference)" + (detail.map { " (\($0))" } ?? "")
        }
    }

    static let shared = SignInDiagnostics(defaults: .standard)
    private static let key = "signIn.failures.v1", limit = 8, lifetime: TimeInterval = 14 * 86_400
    private let defaults: UserDefaults
    private let build: String
    private let lock = NSLock()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScienceReader", category: "sign-in")

    init(defaults: UserDefaults, build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") {
        self.defaults = defaults; self.build = build
    }

    private var returnRoute: (route: String, at: Date)?

    /// How the Google return reached the app ("session": the authentication session answered; "app-url": the system
    /// opened the app with it). A refused return recorded within a minute names it.
    func noteReturnRoute(_ route: String, at: Date = Date()) {
        lock.withLock { returnRoute = (Self.token(route), at) }
    }

    func record(method: String, stage: String, reason: String, detail: String? = nil, at: Date = Date()) {
        let route = lock.withLock { returnRoute.flatMap { at.timeIntervalSince($0.at) < 60 ? $0.route : nil } }
        let described = stage == "callback" && detail?.contains("route=") != true
            ? [detail, route.map { "route=\($0)" }].compactMap { $0 }.joined(separator: " ") : detail
        let failure = Failure(at: at, build: String(build.prefix(16)), method: Self.token(method), stage: Self.token(stage),
                              reason: Self.token(reason), detail: described.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) })
        lock.withLock {
            let kept = Self.decode(defaults.data(forKey: Self.key)).filter { at.timeIntervalSince($0.at) < Self.lifetime }
            if let data = try? JSONEncoder().encode(Array((kept + [failure]).suffix(Self.limit))) { defaults.set(data, forKey: Self.key) }
        }
        log.error("sign-in failed: \(failure.supportLine, privacy: .public)")
        SessionTimeline.shared.record("sign_in_failure", ["reference": failure.reference, "detail": failure.detail ?? ""])
    }

    /// Newest last; entries older than 14 days are gone.
    func recent(now: Date = Date()) -> [Failure] {
        lock.withLock { Self.decode(defaults.data(forKey: Self.key)) }.filter { now.timeIntervalSince($0.at) < Self.lifetime }
    }

    /// The latest failure, if it happened in the last two minutes and is the kind asked for: the reference shown under
    /// a sign-in error.
    func latest(now: Date = Date(), where matches: (Failure) -> Bool = { _ in true }) -> Failure? {
        recent(now: now).last.flatMap { now.timeIntervalSince($0.at) < 120 && matches($0) ? $0 : nil }
    }

    /// What an in-app report shares, shown in the composer first.
    func supportSummary(now: Date = Date()) -> String? {
        let failures = recent(now: now)
        return failures.isEmpty ? nil : "Sign-in problems on this device\n" + failures.map(\.supportLine).joined(separator: "\n")
    }

    /// A failure's fixed category: never its description, which could carry server text.
    static func reason(_ error: any Error) -> String {
        switch error {
        case let error as OAuthFlowError:
            switch error {
            case .invalidCallback: "refused"
            case .invalidConfiguration: "configuration"
            case .providerDenied: "denied"
            case .invitationRequired: "not-invited"
            }
        case let error as AuthenticationError:
            switch error {
            case .configuration: "configuration"
            case .noAccount: "no-account"
            case .invalidEmail: "invalid-email"
            case .invalidCode: "invalid-code"
            case .rateLimited: "rate-limited"
            case .connection: "connection"
            case .invalidResponse: "invalid-response"
            case .credentialStorage: "credential-storage"
            case .rejected: "rejected"
            case .sessionExpired: "session-expired"
            }
        case is CancellationError: "cancelled"
        default: "other"
        }
    }

    private static func decode(_ data: Data?) -> [Failure] {
        data.flatMap { try? JSONDecoder().decode([Failure].self, from: $0) } ?? []
    }

    /// Our own fixed words only: lowercase letters, digits and dashes.
    private static func token(_ value: String) -> String {
        let kept = String(value.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) && $0.isASCII ||
            CharacterSet.decimalDigits.contains($0) && $0.isASCII || $0 == "-" }.prefix(40))
        return kept.isEmpty ? "unknown" : kept
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

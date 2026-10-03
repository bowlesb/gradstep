import Foundation
import ScienceReaderCore

struct BackendConfiguration: Sendable {
    let url: URL
    let anonKey: String
    let environment: String

    static func bundled() -> BackendConfiguration? {
        guard let source = Bundle.main.object(forInfoDictionaryKey: "ScienceReaderSupabaseURL") as? String,
              let url = URL(string: source), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "ScienceReaderSupabaseAnonKey") as? String, !key.isEmpty else { return nil }
        return BackendConfiguration(url: url, anonKey: key, environment: Bundle.main.object(forInfoDictionaryKey: "ScienceReaderEnvironment") as? String ?? "staging")
    }
}

struct AuthSession: Codable, Sendable {
    struct User: Codable, Sendable { let id: UUID; let email: String? }
    let access_token: String
    let refresh_token: String
    let expires_at: TimeInterval
    let user: User
}

enum BackendError: LocalizedError {
    case unavailable, signInRequired, emailConfirmation, rejected(String), transport
    var errorDescription: String? {
        switch self {
        case .unavailable: "The backend is not configured for this build."
        case .signInRequired: "Sign in to sync your library."
        case .emailConfirmation: "Check your email to confirm your account, then sign in."
        case .rejected(let code): switch code {
            case "insufficient_credits": "Your available credits do not cover this request."
            case "platform_budget_exhausted": "Cloud processing is temporarily paused. Downloaded papers remain available."
            case "key_authority_required", "stale_key_epoch": "This device needs updated encryption keys from an approved device or recovery code."
            case "invalid_credentials": "The email or password was not accepted."
            case "email_not_confirmed": "Confirm your email before signing in."
            case "sync_account_storage_limit": "Your cloud history storage is full. New changes remain on this device."
            case "sync_environment_storage_limit": "Cloud history uploads are paused because storage is full. New changes remain on this device."
            case "sync_account_transfer_limit": "Your cloud history download allowance has been reached for this month. Your saved work remains on this device."
            case "sync_environment_transfer_limit": "Cloud history downloads are temporarily paused. Your saved work remains on this device."
            case "sync_page_too_large": "Update the app to sync this history. Your saved work remains on this device."
            case "request_rate_limit": "Cloud requests are temporarily limited. Your saved work remains on this device."
            case "owner_mfa_required", "operator_required": "This action needs an authorized administrator with two-factor authentication."
            default: "The server could not complete this request. Please try again."
        }
        case .transport: "The connection was interrupted. Your saved work is still on this device."
        }
    }
}

actor BackendClient {
    private let config: BackendConfiguration
    private var session: AuthSession?
    private var refreshTask: (generation: UInt64, task: Task<AuthSession, Error>)?
    private var authGeneration: UInt64 = 0
    private let network: URLSession

    init(configuration: BackendConfiguration, network: URLSession? = nil) throws {
        self.config = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 60
        settings.waitsForConnectivity = false
        self.network = network ?? URLSession(configuration: settings)
        if let bytes = try KeychainVault.read("\(configuration.environment).auth-session") {
            session = try JSONDecoder().decode(AuthSession.self, from: bytes)
        }
    }

    func currentUser() -> AuthSession.User? { session?.user }

    func signIn(email: String, password: String) async throws -> AuthSession.User {
        try beginAuthenticationChange()
        let generation = authGeneration
        let data = try await raw(path: "auth/v1/token?grant_type=password", body: ReaderCrypto.encode(["email": email, "password": password]), token: nil)
        guard generation == authGeneration else { throw CancellationError() }
        let next = try JSONDecoder().decode(AuthSession.self, from: data)
        try save(next)
        return next.user
    }

    func signUp(email: String, password: String) async throws {
        try beginAuthenticationChange()
        let generation = authGeneration
        let data = try await raw(path: "auth/v1/signup", body: ReaderCrypto.encode(["email": email, "password": password]), token: nil)
        guard generation == authGeneration else { throw CancellationError() }
        if let next = try? JSONDecoder().decode(AuthSession.self, from: data) { try save(next) }
        else { throw BackendError.emailConfirmation }
    }

    func signOut() async throws {
        let previous = session
        try beginAuthenticationChange()
        // Local sign-out is complete even offline. A stale refresh cannot save
        // the old session back into Keychain after this generation changes.
        if let previous { _ = try? await raw(path: "auth/v1/logout?scope=local", body: Data("{}".utf8), token: previous.access_token) }
    }

    func rpc<P: Encodable & Sendable, R: Decodable & Sendable>(_ function: String, params: P, accountID: UUID? = nil, as type: R.Type = R.self) async throws -> R {
        let data = try await authorized(path: "rest/v1/rpc/\(function)", body: ReaderCrypto.encode(params), accountID: accountID)
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// SQL `returns void` has an empty HTTP 204 response. Keep it distinct from
    /// typed RPCs: an empty key-state response must never mean "no keyring".
    func rpcVoid<P: Encodable & Sendable>(_ function: String, params: P, accountID: UUID) async throws {
        let data = try await authorized(path: "rest/v1/rpc/\(function)", body: ReaderCrypto.encode(params), accountID: accountID)
        if !data.isEmpty {
            let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            guard value is NSNull else { throw ReaderError.corruptData }
        }
    }

    func edge<P: Encodable & Sendable, R: Decodable & Sendable>(_ function: String, body: P, accountID: UUID? = nil, as type: R.Type = R.self) async throws -> R {
        let data = try await authorized(path: "functions/v1/\(function)", body: ReaderCrypto.encode(body), accountID: accountID)
        return try JSONDecoder().decode(R.self, from: data)
    }

    func uploadReportImage(_ bytes: Data, mediaType: String, accountID: UUID, reportID: UUID, attachmentID: UUID) async throws {
        guard bytes.count <= 5 * 1024 * 1024, ["image/png", "image/jpeg"].contains(mediaType) else { throw ReaderError.invalidEvent }
        let result = try await authorized(path: "functions/v1/support-assets?report_id=\(reportID.wire)&attachment_id=\(attachmentID.wire)", body: bytes,
                                          mediaType: mediaType, accountID: accountID)
        struct Receipt: Decodable { let id: UUID }
        guard try JSONDecoder().decode(Receipt.self, from: result).id == attachmentID else { throw ReaderError.corruptData }
    }

    func reportImage(_ id: UUID, accountID: UUID) async throws -> Data {
        let data = try await authorized(path: "functions/v1/support-assets?attachment_id=\(id.wire)", body: nil, method: "GET", accountID: accountID)
        guard data.count <= 5 * 1024 * 1024 else { throw ReaderError.corruptData }
        return data
    }

    private func beginAuthenticationChange() throws {
        try KeychainVault.delete("\(config.environment).auth-session")
        authGeneration &+= 1
        refreshTask?.task.cancel(); refreshTask = nil; session = nil
    }

    private func authorized(path: String, body: Data?, method: String = "POST", mediaType: String = "application/json", accountID: UUID?) async throws -> Data {
        let generation = authGeneration
        guard let expected = session?.user.id, accountID == nil || expected == accountID else { throw BackendError.signInRequired }
        let token = try await accessToken()
        guard generation == authGeneration, session?.user.id == expected else { throw CancellationError() }
        let data = try await raw(path: path, body: body, token: token, method: method, mediaType: mediaType)
        guard generation == authGeneration, session?.user.id == expected else { throw CancellationError() }
        return data
    }

    private func accessToken() async throws -> String {
        guard let current = session else { throw BackendError.signInRequired }
        if current.expires_at > Date().timeIntervalSince1970 + 60 { return current.access_token }
        let generation = authGeneration
        let task: Task<AuthSession, Error>
        if let existing = refreshTask, existing.generation == generation { task = existing.task }
        else {
            task = Task { () throws -> AuthSession in
                let bytes = try await self.raw(path: "auth/v1/token?grant_type=refresh_token", body: ReaderCrypto.encode(["refresh_token": current.refresh_token]), token: nil)
                return try JSONDecoder().decode(AuthSession.self, from: bytes)
            }
            refreshTask = (generation, task)
        }
        defer { if refreshTask?.generation == generation { refreshTask = nil } }
        let next = try await task.value
        guard generation == authGeneration, session?.user.id == current.user.id, next.user.id == current.user.id else { throw CancellationError() }
        try save(next)
        return next.access_token
    }

    private func save(_ next: AuthSession) throws {
        try KeychainVault.write(ReaderCrypto.encode(next), name: "\(config.environment).auth-session")
        session = next
    }

    private func raw(path: String, body: Data?, token: String?, method: String = "POST", mediaType: String = "application/json") async throws -> Data {
        guard let url = URL(string: "/" + path, relativeTo: config.url)?.absoluteURL, url.host == config.url.host else { throw BackendError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackendError.transport }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let code: String?; let message: String?; let error_code: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let known = Set(["insufficient_credits","platform_budget_exhausted","key_authority_required","stale_key_epoch","owner_mfa_required","operator_required","invalid_credentials","email_not_confirmed", "attachment_count_limit", "attachment_storage_limit", "request_rate_limit", "attachment_expired", "sync_account_storage_limit", "sync_environment_storage_limit", "sync_account_transfer_limit", "sync_environment_transfer_limit", "sync_page_too_large"])
            let code = [failure?.message, failure?.error_code, failure?.code].compactMap { $0 }.first { known.contains($0) } ?? "request_failed"
            throw BackendError.rejected(code)
        }
        return data
    }
}

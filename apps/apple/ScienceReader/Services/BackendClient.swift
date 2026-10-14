import Foundation
import ScienceReaderCore

struct BackendConfiguration: Sendable {
    let url: URL
    let anonKey: String
    let environment: String
    let authCallbackURL: URL?

    init(url: URL, anonKey: String, environment: String,
         authCallbackURL: URL? = AuthenticationConfiguration.callbackURL) {
        self.url = url; self.anonKey = anonKey; self.environment = environment
        self.authCallbackURL = authCallbackURL
    }

    static func bundled() -> BackendConfiguration? {
        guard let source = Bundle.main.object(forInfoDictionaryKey: "ScienceReaderSupabaseURL") as? String,
              let url = URL(string: source), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "ScienceReaderSupabaseAnonKey") as? String, !key.isEmpty else { return nil }
        return BackendConfiguration(url: url, anonKey: key,
            environment: Bundle.main.object(forInfoDictionaryKey: "ScienceReaderEnvironment") as? String ?? "staging",
            authCallbackURL: AuthenticationConfiguration.callback(in: .main))
    }
}

struct AuthSession: Codable, Sendable {
    struct User: Codable, Equatable, Sendable {
        let id: UUID
        let email: String?
        /// How the account signs in ("apple", "google", "email"), from Auth's `app_metadata.providers` when it was
        /// sent; shown on the Account page only. Malformed or missing metadata is ignored, never a sign-in failure.
        let providers: [String]

        init(id: UUID, email: String?, providers: [String] = []) { self.id = id; self.email = email; self.providers = providers }

        private enum CodingKeys: String, CodingKey { case id, email, app_metadata }
        private enum MetadataKeys: String, CodingKey { case provider, providers }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            let metadata = try? container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .app_metadata)
            let listed = (try? metadata?.decodeIfPresent([String].self, forKey: .providers)) ?? nil
            let single = (try? metadata?.decodeIfPresent(String.self, forKey: .provider)) ?? nil
            providers = Self.bounded(listed ?? single.map { [$0] } ?? [])
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(email, forKey: .email)
            if !providers.isEmpty {
                var metadata = container.nestedContainer(keyedBy: MetadataKeys.self, forKey: .app_metadata)
                try metadata.encode(providers, forKey: .providers)
            }
        }

        /// Short lowercase provider names only, at most eight.
        private static func bounded(_ names: [String]) -> [String] {
            Array(names.filter { (1...32).contains($0.utf8.count) && $0.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") } }.prefix(8))
        }
    }
    let access_token: String
    let refresh_token: String
    let expires_at: TimeInterval
    let user: User
}

/// The outcome of a direct "Add to library" on a reference (functions/v1/add-reference).
struct AddReferenceResult: Decodable, Sendable, Equatable {
    struct Paper: Decodable, Sendable, Equatable { let title: String; let year: Int?; let source_id: String; let kind: String?; let host: String?; let link: String? }
    let status: String
    let route: String?
    let paper: Paper?
}

struct GoogleAuthorization: Sendable { let id: UUID; let url: URL; let callbackURL: URL }
struct AppleAuthorization: Sendable { let id: UUID; let hashedNonce: String }

enum BackendError: LocalizedError {
    case unavailable, signInRequired, emailConfirmation, rejected(String), transport
    /// Finite public delivery codes only. Server-provided prose never reaches the reader UI.
    static let readerDeliveryCodes: Set<String> = ["reader_transfer_limit", "reader_upgrade_required",
        "reader_grant_unavailable", "reader_grant_consumed", "asset_inventory_incomplete",
        "reader_unavailable", "reader_not_ready", "reader_integrity_failed"]
    var readerDeliveryMessage: String? {
        guard case .rejected(let code) = self, Self.readerDeliveryCodes.contains(code) else { return nil }
        return errorDescription
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: "The backend is not configured for this build."
        case .signInRequired: "Sign in to sync your library."
        case .emailConfirmation: "Check your email to confirm your account, then sign in."
        case .rejected(let code): switch code {
            case "insufficient_credits": "Your available credits do not cover this request."
            case "account_busy": "An answer or paper conversion is still in progress. Try again shortly; if this keeps happening, send a report."
            case "confirmation_required": "Type DELETE to confirm."
            case "purchases_unavailable": "Purchases aren’t available right now. Try again later."
            case "platform_budget_exhausted": "Cloud processing is temporarily paused. Downloaded papers remain available."
            case "reader_transfer_limit": "Paper downloads are temporarily limited. Downloaded papers remain available."
            case "reader_upgrade_required": "Update Gradstep to download this paper. Downloaded papers remain available."
            case "reader_grant_unavailable", "reader_grant_consumed": "The download needs to restart. Open the paper again."
            case "asset_inventory_incomplete", "reader_unavailable", "reader_not_ready": "This paper is temporarily unavailable. Downloaded papers remain available."
            case "reader_integrity_failed": "This paper couldn’t be verified. Try downloading it again."
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

actor BackendClient: LibraryTransport, LibraryCommandTransport, AuthenticationBackend {
    private let config: BackendConfiguration
    private var session: AuthSession?
    private var refreshTask: (generation: UInt64, task: Task<AuthSession, Error>)?
    private var authGeneration: UInt64 = 0
    private let network: URLSession
    /// Library read version: 5 (full entries with uploads), or 3 on a server that doesn't have v5 yet.
    private let authNetwork: URLSession
    private let credentials: any AuthenticationCredentialStore
    private var credentialCleanupAttempt: UUID?
    private var signInRequest: (id: UUID, task: Task<Data, Error>)?
    private var logoutTask: (id: UUID, task: Task<Void, Never>)?
    private enum EmailPhase { case prepared, sending, ready, verifying, failed }
    private enum SignInPhase {
        case google(OAuthPKCEAttempt), apple(AppleSignInNonce)
        case email(address: String, phase: EmailPhase)
        case exchanging, completed
    }
    private struct SignInAttempt {
        let id: UUID
        let generation: UInt64
        var phase: SignInPhase
    }
    private var signInAttempt: SignInAttempt?

    init(configuration: BackendConfiguration, network: URLSession? = nil,
         credentials: any AuthenticationCredentialStore = KeychainAuthenticationCredentialStore()) throws {
        self.config = configuration
        self.credentials = credentials
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 60
        settings.waitsForConnectivity = false
        self.network = network ?? URLSession(configuration: settings)
        // Preserve injected URLProtocol fixtures while fixing auth-only limits;
        // support/library payload policy remains independent.
        let authSettings = network?.configuration ?? URLSessionConfiguration.ephemeral
        authSettings.timeoutIntervalForRequest = 30
        authSettings.timeoutIntervalForResource = 60
        authSettings.waitsForConnectivity = false
        authSettings.urlCache = nil; authSettings.httpCookieStorage = nil
        authSettings.urlCredentialStorage = nil; authSettings.httpShouldSetCookies = false
        authSettings.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.authNetwork = URLSession(configuration: authSettings)
        let stored: Data?
        do { stored = try credentials.read("\(configuration.environment).auth-session") }
        catch { throw AuthenticationError.credentialStorage }
        if let stored {
            session = try Self.decodeSession(stored)
        }
    }

    func currentUser() -> AuthSession.User? { session?.user }

    deinit { authNetwork.invalidateAndCancel() }

    func beginGoogleSignIn() throws -> GoogleAuthorization {
        try Task.checkCancellation()
        try requireAuthenticationConfiguration()
        guard config.authCallbackURL == AuthenticationConfiguration.callbackURL else { throw AuthenticationError.configuration }
        try beginAuthenticationChange()
        let attempt = try OAuthPKCEAttempt(callbackURL: AuthenticationConfiguration.callbackURL)
        let url = try attempt.authorizationURL(supabaseURL: config.url)
        signInAttempt = SignInAttempt(id: attempt.id, generation: authGeneration, phase: .google(attempt))
        return GoogleAuthorization(id: attempt.id, url: url, callbackURL: attempt.callbackURL)
    }

    func finishGoogleSignIn(id: UUID, callbackURL: URL) async throws -> AuthSession.User {
        guard let attempt = signInAttempt, attempt.id == id, attempt.generation == authGeneration,
              case .google(let pkce) = attempt.phase else { throw CancellationError() }
        let code = try pkce.authorizationCode(from: callbackURL)
        return try await exchangeSignIn(attempt, route: .token(.pkce), body: ReaderCrypto.encode([
            "auth_code": code, "code_verifier": pkce.verifier
        ]))
    }

    func beginAppleSignIn() throws -> AppleAuthorization {
        try Task.checkCancellation()
        try requireAuthenticationConfiguration()
        try beginAuthenticationChange()
        let nonce = AppleSignInNonce(), id = UUID()
        signInAttempt = SignInAttempt(id: id, generation: authGeneration, phase: .apple(nonce))
        return AppleAuthorization(id: id, hashedNonce: nonce.hashed)
    }

    func finishAppleSignIn(id: UUID, identityToken: String) async throws -> AuthSession.User {
        guard let attempt = signInAttempt, attempt.id == id, attempt.generation == authGeneration,
              case .apple(let nonce) = attempt.phase else { throw CancellationError() }
        guard Self.validToken(identityToken) else { throw OAuthFlowError.invalidCallback }
        return try await exchangeSignIn(attempt, route: .token(.idToken), body: ReaderCrypto.encode([
            "provider": "apple", "id_token": identityToken, "nonce": nonce.raw
        ]))
    }

    func prepareEmailSignIn(email: String) throws -> EmailAuthorization {
        try Task.checkCancellation()
        try requireAuthenticationConfiguration()
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validEmail(address) else { throw AuthenticationError.invalidEmail }
        try beginAuthenticationChange()
        let id = UUID()
        signInAttempt = SignInAttempt(id: id, generation: authGeneration, phase: .email(address: address, phase: .prepared))
        return EmailAuthorization(id: id, email: address)
    }

    func sendEmailCode(id: UUID) async throws -> EmailCodeDelivery {
        guard let attempt = signInAttempt, owns(attempt), attempt.id == id,
              case .email(let address, .prepared) = attempt.phase else { throw CancellationError() }
        struct Body: Encodable { let email: String; let create_user = true }
        let body = try ReaderCrypto.encode(Body(email: address))
        signInAttempt?.phase = .email(address: address, phase: .sending)
        let delivery: EmailCodeDelivery
        do {
            let data = try await performSignInRequest(.emailSend, body: body, generation: attempt.generation)
            guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else { throw AuthenticationError.invalidResponse }
            delivery = .sent
        } catch {
            guard owns(attempt) else { throw CancellationError() }
            if let failure = error as? AuthenticationError,
               failure == .connection || failure == .invalidResponse {
                // A malformed or incomplete reply cannot establish whether
                // the code was delivered. Keep manual verification available,
                // without accepting a session or repeating this send.
                delivery = .unconfirmed
            }
            else {
                // A throttled resend may leave an earlier delivered code valid.
                // Keep verification available, but never repeat this send ID.
                if case AuthenticationError.rateLimited = error {
                    signInAttempt?.phase = .email(address: address, phase: .ready)
                } else { signInAttempt?.phase = .email(address: address, phase: .failed) }
                throw error
            }
        }
        guard owns(attempt) else { throw CancellationError() }
        signInAttempt?.phase = .email(address: address, phase: .ready)
        return delivery
    }

    func finishEmailSignIn(id: UUID, code: String) async throws -> AuthSession.User {
        guard let attempt = signInAttempt, owns(attempt), attempt.id == id,
              case .email(let address, .ready) = attempt.phase else { throw CancellationError() }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw AuthenticationError.invalidCode }
        signInAttempt?.phase = .email(address: address, phase: .verifying)
        let next: AuthSession
        do {
            let data = try await performSignInRequest(.emailVerify,
                body: ReaderCrypto.encode(["email": address, "token": code, "type": "email"]), generation: attempt.generation)
            guard owns(attempt) else { throw CancellationError() }
            next = try Self.decodeSession(data)
        } catch {
            guard owns(attempt) else { throw CancellationError() }
            // An explicit correction/retry is allowed. No HTTP error repeats a
            // token exchange automatically, and concurrent verification fails.
            signInAttempt?.phase = .email(address: address, phase: .ready)
            throw error
        }
        try save(next)
        signInAttempt?.phase = .completed
        return next.user
    }

    func cancelSignIn(id: UUID) throws {
        // Also covers cancellation while an exchange is in flight, or between
        // session persistence and UI delivery. A newer attempt has another ID.
        guard signInAttempt?.id == id || credentialCleanupAttempt == id else { return }
        try beginAuthenticationChange()
    }

    private func exchangeSignIn(_ attempt: SignInAttempt, route: AuthRoute, body: Data) async throws -> AuthSession.User {
        try Task.checkCancellation()
        signInAttempt?.phase = .exchanging
        let next: AuthSession
        do {
            let data = try await performSignInRequest(route, body: body, generation: attempt.generation)
            try Task.checkCancellation()
            guard owns(attempt) else { throw CancellationError() }
            next = try Self.decodeSession(data)
        } catch {
            guard owns(attempt) else { throw CancellationError() }
            signInAttempt = nil
            throw error
        }
        try save(next)
        // Retain identity/generation until UI acceptance; discard secrets.
        signInAttempt?.phase = .completed
        return next.user
    }

    func signIn(email: String, password: String) async throws -> AuthSession.User {
        try Task.checkCancellation()
        guard email.utf8.count <= 320, password.utf8.count <= AuthenticationConfiguration.maximumTokenBytes else { throw AuthenticationError.invalidResponse }
        try requireAuthenticationConfiguration()
        try beginAuthenticationChange()
        let generation = authGeneration
        let data = try await performSignInRequest(.token(.password), body: ReaderCrypto.encode(["email": email, "password": password]), generation: generation)
        guard generation == authGeneration else { throw CancellationError() }
        let next = try Self.decodeSession(data)
        try save(next)
        return next.user
    }

    func signUp(email: String, password: String) async throws {
        try Task.checkCancellation()
        guard email.utf8.count <= 320, password.utf8.count <= AuthenticationConfiguration.maximumTokenBytes else { throw AuthenticationError.invalidResponse }
        try requireAuthenticationConfiguration()
        try beginAuthenticationChange()
        let generation = authGeneration
        let data = try await performSignInRequest(.signUp, body: ReaderCrypto.encode(["email": email, "password": password]), generation: generation)
        guard generation == authGeneration else { throw CancellationError() }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["access_token"] == nil,
           object["id"] as? String != nil { throw BackendError.emailConfirmation }
        try save(Self.decodeSession(data))
    }

    func signOut() async throws {
        try retireAuthentication()
    }

    /// Completes local retirement without holding the next sign-in behind a
    /// remote request. The captured old token can only revoke its own session;
    /// a new preparation cancels that best-effort request independently.
    func retireAuthentication() throws {
        let previousAccessToken = session?.access_token
        try beginAuthenticationChange()
        guard let previousAccessToken else { return }
        let id = UUID()
        let task = Task {
            _ = try? await self.authRaw(.logout, body: Data("{}".utf8), token: previousAccessToken)
            // Late success/error cannot clear a newer logout's owner, change
            // authentication generation, or publish any credentials.
            if self.logoutTask?.id == id { self.logoutTask = nil }
        }
        logoutTask = (id, task)
    }

    func rpc<P: Encodable & Sendable, R: Decodable & Sendable>(_ function: String, params: P, accountID: UUID? = nil, as type: R.Type = R.self) async throws -> R {
        let data = try await authorized(path: "rest/v1/rpc/\(function)", body: ReaderCrypto.encode(params), accountID: accountID)
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// Library pages use their bounded wire decoder and keep the reconciler's
    /// original account/session/request ticket through the transport boundary.
    /// The immutable ticket chooses the full-read family. A failed v5 request is
    /// never replayed as a legacy request, nor as a compact-format request.
    func libraryPage(_ request: LibraryPageRequest) async throws -> LibraryPageDelivery {
        let function: String, body: Data
        switch request.query {
        case .baseline(let cursor):
            struct Parameters: Encodable { let p_cursor: LibraryBaselineCursor?; let p_limit: Int }
            function = "v\(request.readContext.endpointVersion)_library_page"
            body = try ReaderCrypto.encode(Parameters(p_cursor: cursor, p_limit: request.limit))
        case .changes(let after, let through):
            struct Parameters: Encodable { let p_after: Int64; let p_through: Int64?; let p_limit: Int; let p_dataset_epoch: String? }
            function = "v\(request.readContext.endpointVersion)_library_changes"
            body = try ReaderCrypto.encode(Parameters(p_after: after, p_through: through, p_limit: request.limit,
                p_dataset_epoch: request.readContext.datasetEpoch?.uuidString.lowercased()))
        }
        let data = try await authorized(path: "rest/v1/rpc/\(function)", body: body, accountID: request.accountID,
                                        maximumResponseBytes: LibraryWire.maximumPageBytes, libraryErrors: true)
        let page: LibraryPageDelivery.Page
        switch request.query {
        case .baseline: page = .baseline(try LibraryWire.decodeBaseline(data))
        case .changes: page = .changes(try LibraryWire.decodeChanges(data))
        }
        return LibraryPageDelivery(request: request, page: page)
    }

    func readerCapabilities(accountID: UUID) async throws -> ReaderCapabilities? {
        do {
            let data = try await authorized(path: "rest/v1/rpc/v1_reader_capabilities", body: Data("{}".utf8),
                accountID: accountID, maximumResponseBytes: 16_384)
            return try ReaderCapabilities.decode(data, accountID: accountID)
        } catch is ReaderCapabilityMissing { return nil }
    }

    func libraryCommand(_ attempt: LibraryCommandAttempt) async throws -> LibraryCommandDelivery {
        // The attempt's read context chooses the family. v2 commands have no dataset
        // precondition and are sent only for legacy (full-v3) observations. v5 commands
        // (migration 042) carry the observed upload dataset epoch, which the server checks
        // in the mutation's own transaction, closing restore-between-read-and-POST.
        let deployment = try LibraryCommandScope(accountID: attempt.scope.accountID, deploymentID: config.url.absoluteString)
        guard attempt.scope == deployment else { throw LibraryCommandError.invalidScope }
        let request = attempt.request
        let commands = ["begin_import", "set_library_item", "cancel_import", "retry_import", "set_item_archived", "set_item_tags"]
        let family = attempt.readContext.datasetEpoch == nil ? "v2_" : "v5_"
        guard commands.map({ family + $0 }).contains(request.endpoint),
              !request.body.isEmpty, request.body.count <= 2_048 else { throw LibraryCommandError.invalidMutation }
        // The frozen body must name exactly the attempt's dataset (or none for v2).
        let epoch = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["p_dataset_epoch"] as? String
        guard epoch == attempt.readContext.datasetEpoch?.wire else { throw LibraryCommandError.contextMismatch }
        let data = try await authorized(path: "rest/v1/rpc/\(request.endpoint)", body: request.body,
                                        accountID: attempt.scope.accountID, maximumResponseBytes: LibraryWire.maximumPageBytes,
                                        libraryCommandErrors: true)
        return LibraryCommandDelivery(attempt: attempt, response: try LibraryWire.decodeCommand(data))
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

    static let maximumChatStreamBytes = 2 * 1024 * 1024

    /// Streams one metered answer from `functions/v1/chat` on the configured
    /// project host only, with the same account/auth-generation checks as other
    /// authorized calls. Cancelling the consumer cancels the HTTP request; the
    /// server then aborts the provider and settles actual usage.
    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let generation = authGeneration
        guard let expected = session?.user.id, expected == accountID else { throw BackendError.signInRequired }
        let body = try request.encoded()
        // A paid answer can stream for minutes and the server acts as the user
        // afterwards (Ingest), so start it with a token that outlives it.
        let token = try await accessToken(validFor: 300)
        guard generation == authGeneration, session?.user.id == expected else { throw CancellationError() }
        guard let url = URL(string: "/functions/v1/chat", relativeTo: config.url)?.absoluteURL,
              url.scheme == "https", url.host == config.url.host else { throw BackendError.unavailable }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"; urlRequest.httpBody = body
        // Idle limit between bytes; the function sends a keep-alive every 15 s.
        urlRequest.timeoutInterval = 90
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await network.bytes(for: urlRequest, delegate: LibraryRedirectPolicy())
        let task = bytes.task
        guard generation == authGeneration, session?.user.id == expected else { task.cancel(); throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { task.cancel(); throw BackendError.transport }
        guard (200..<300).contains(http.statusCode) else {
            defer { task.cancel() }
            if http.statusCode == 401 { throw ChatTransportError.rejected("authentication_required") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 4_096 else { break }
                data.append(byte)
            }
            struct Failure: Decodable { let code: String }
            let code = (try? JSONDecoder().decode(Failure.self, from: data))?.code
            throw ChatTransportError.rejected(code.flatMap { $0.utf8.count <= 64 ? $0 : nil } ?? "service_unavailable")
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            task.cancel(); throw ChatStreamError.malformed
        }
        return AsyncThrowingStream { continuation in
            let reader = Task {
                var parser = ChatSSEParser(), chunk: [UInt8] = [], total = 0
                chunk.reserveCapacity(1_024)
                do {
                    for try await byte in bytes {
                        total += 1
                        guard total <= Self.maximumChatStreamBytes else { throw ChatStreamError.tooLarge }
                        chunk.append(byte)
                        // Deliver each complete line promptly; bound buffering otherwise.
                        if byte == 0x0A || chunk.count >= 1_024 {
                            for event in try parser.consume(chunk) { continuation.yield(event) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    for event in try parser.consume(chunk) { continuation.yield(event) }
                    parser.finish()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                task.cancel()
            }
            continuation.onTermination = { _ in reader.cancel(); task.cancel() }
        }
    }

    /// The chat function's published profile table (models, effort, length and credit estimates; `GET functions/v1/chat`).
    /// A server without profiles answers 405, which callers treat as "no choices offered".
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable {
        let data = try await authorized(path: "functions/v1/chat", body: nil, method: "GET", accountID: accountID, maximumResponseBytes: 65_536)
        guard let table = ChatProfileTable.decode(data) else { throw ReaderError.corruptData }
        return table
    }

    func creditBalance(accountID: UUID) async throws -> CreditBalance {
        struct NoParameters: Encodable, Sendable {}
        return try await rpc("v1_credit_balance", params: NoParameters(), accountID: accountID, as: CreditBalance.self)
    }

    func uploadReportImage(_ bytes: Data, mediaType: String, accountID: UUID, reportID: UUID, attachmentID: UUID) async throws {
        guard bytes.count <= 5 * 1024 * 1024, ["image/png", "image/jpeg"].contains(mediaType) else { throw ReaderError.invalidEvent }
        let result = try await authorized(path: "functions/v1/support-assets?report_id=\(reportID.wire)&attachment_id=\(attachmentID.wire)", body: bytes,
                                          mediaType: mediaType, accountID: accountID)
        struct Receipt: Decodable { let id: UUID }
        guard try JSONDecoder().decode(Receipt.self, from: result).id == attachmentID else { throw ReaderError.corruptData }
    }

    /// arXiv search for the Library's "arXiv" segment.
    func discover(query: String, accountID: UUID) async throws -> [DiscoveryResult] {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=?#")
        guard let encoded = String(query.prefix(300)).addingPercentEncoding(withAllowedCharacters: allowed) else { throw BackendError.unavailable }
        let data = try await authorized(path: "functions/v1/discover?q=\(encoded)&abstract=full", body: nil, method: "GET",
                                        accountID: accountID, maximumResponseBytes: 4_194_304)
        return try JSONDecoder().decode(DiscoveryResponse.self, from: data).results
    }

    /// "Add to library" on a bibliography entry: the server identifies the paper (arXiv id, DOI,
    /// citation match; no model, no credits) and queues it as this account's own import.
    func addReference(_ text: String, accountID: UUID) async throws -> AddReferenceResult {
        struct Body: Encodable { let operation_id: String; let reference: String; let capabilities: [String] }
        let body = try JSONEncoder().encode(Body(operation_id: UUID().wire, reference: String(text.prefix(2_000)), capabilities: ["web_import"]))
        let data = try await authorized(path: "functions/v1/add-reference", body: body, accountID: accountID, maximumResponseBytes: 65_536)
        return try JSONDecoder().decode(AddReferenceResult.self, from: data)
    }

    /// Add by any identifier or link (a DOI, a landing page or PDF link, a reference): the server
    /// identifies the paper and queues it as this account's own import, or says what this device can
    /// do next (upload the PDF, download it here). No credits.
    func addPaper(_ query: String, accountID: UUID) async throws -> AddPaperResult {
        struct Body: Encodable { let operation_id: String; let query: String; let capabilities: [String] }
        let body = try JSONEncoder().encode(Body(operation_id: UUID().wire, query: String(query.prefix(2_000)), capabilities: ["web_import", "pdf_upload"]))
        let data = try await authorized(path: "functions/v1/add-paper", body: body, accountID: accountID, maximumResponseBytes: 65_536)
        return try JSONDecoder().decode(AddPaperResult.self, from: data)
    }

    // MARK: Device PDFs. There is no upload transport: the server refuses PDF ingress (HTTP 410;
    // docs/architecture/HTML_FIRST_READER.md). Only the device-local import links remain.

    /// Stores the private display descriptor required for a paper created from a device PDF. The
    /// descriptor is sealed locally; the server receives only the envelope and never the title in
    /// the upload admission request. A unique upload source starts at revision zero, and replaying
    /// the same request is safe if the network drops after the server commits it.
    func putLibraryDescriptor(sourceID: String, displayName: String, filename: String?, accountID: UUID,
                              deviceID: UUID, keys: KeyBundle) async throws {
        let descriptorID = UUID(), mutationID = UUID()
        let payload = try LibraryDescriptorPayload(displayName: displayName, filename: filename)
        let envelope = try LibraryDescriptorCrypto.seal(payload, accountID: accountID, sourceID: sourceID,
            descriptorID: descriptorID, revision: 1, mutationID: mutationID, deviceID: deviceID, keys: keys)
        struct Parameters: Encodable, Sendable {
            let p_source_id: String; let p_expected_revision: Int; let p_caller_device_id: String
            let p_management_token: String; let p_envelope: LibraryDescriptorEnvelope
        }
        struct DescriptorResult: Decodable, Sendable { let status: String }
        struct Response: Decodable, Sendable { let format: Int; let account_id: UUID; let result: DescriptorResult }
        let response: Response = try await rpc("v1_put_library_descriptor", params: Parameters(
            p_source_id: sourceID, p_expected_revision: 0, p_caller_device_id: deviceID.wire,
            p_management_token: "\\x" + keys.managementToken.hex, p_envelope: envelope), accountID: accountID)
        guard response.format == 1, response.account_id == accountID,
              response.result.status == "applied" || response.result.status == "revision_conflict" else {
            throw ReaderError.corruptData
        }
    }

    /// Where this device can try to fetch a failed web import's PDF.
    func importPDFSources(_ importID: UUID, accountID: UUID) async throws -> PDFImportSources {
        struct Parameters: Encodable, Sendable { let p_import_id: UUID }
        return try await rpc("v1_import_pdf_sources", params: Parameters(p_import_id: importID), accountID: accountID)
    }

    /// The Feed: For you, one of the reader's topics, or the newest arXiv submissions in one category. `feed` in the
    /// response says whether For you is offered (docs/architecture/PERSONALIZED_FEED.md).
    func feed(_ selection: FeedSelection, accountID: UUID) async throws -> DiscoveryResponse {
        let query: String
        switch selection {
        case .forYou:
            query = "feed=for_you"
        case .topic(let name):
            var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=?#")
            guard (1...40).contains(name.count), let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { throw BackendError.unavailable }
            query = "feed=topic&topic=\(encoded)"
        case .category(let category):
            guard category.range(of: "^[a-z]{2,8}(-[a-z]{2,6})?(\\.[A-Z]{2})?$", options: .regularExpression) != nil else { throw BackendError.unavailable }
            query = "category=\(category)"
        }
        let data = try await authorized(path: "functions/v1/discover?\(query)&abstract=full", body: nil, method: "GET",
                                        accountID: accountID, maximumResponseBytes: 4_194_304)
        return try JSONDecoder().decode(DiscoveryResponse.self, from: data)
    }

    /// Deletes the signed-in account on the server (personal content, private
    /// files and the login; billing records stay de-identified).
    func deleteAccount(accountID: UUID) async throws {
        _ = try await authorized(path: "functions/v1/account-delete", body: Data(#"{"confirm":"delete my account"}"#.utf8),
                                 method: "POST", accountID: accountID, maximumResponseBytes: 4_096)
    }

    /// Reports verified App Store transactions; one result per transaction, in order.
    func syncStoreTransactions(_ signed: [String], accountID: UUID) async throws -> [StoreSyncResult] {
        struct Body: Encodable { let transactions: [String] }
        struct Response: Decodable { let results: [StoreSyncResult] }
        guard !signed.isEmpty, signed.count <= StoreSync.batchSize else { throw BackendError.unavailable }
        let data = try await authorized(path: "functions/v1/store-sync", body: try JSONEncoder().encode(Body(transactions: signed)),
                                        method: "POST", accountID: accountID, maximumResponseBytes: 65_536)
        return try JSONDecoder().decode(Response.self, from: data).results
    }

    /// The account's current plan from verified renewals (nil plan: none).
    func storeSummary(accountID: UUID) async throws -> StoreSummary {
        struct NoParameters: Encodable, Sendable {}
        return try await rpc("v1_store_summary", params: NoParameters(), accountID: accountID, as: StoreSummary.self)
    }

    /// Authorizes an offline reader download for one library item.
    func readerArtifact(itemID: UUID, accountID: UUID) async throws -> ReaderArtifactDescriptor {
        let data = try await authorized(path: "functions/v1/reader-artifact?item_id=\(itemID.wire)&transport=bounded-v1", body: nil, method: "GET",
                                        accountID: accountID, maximumResponseBytes: 1_048_576)
        return try JSONDecoder().decode(ReaderArtifactDescriptor.self, from: data)
    }

    /// Fetches one bundle member on the configured project host. Bounded
    /// delivery authenticates the captured account; legacy URLs carry no bearer.
    func readerMember(_ member: ReaderArtifactDescriptor.Member, accountID: UUID) async throws -> Data {
        let transport = try ReaderMemberTransport.validated(member.url, backendURL: config.url)
        if transport == .bounded {
            guard let query = URLComponents(url: member.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { throw BackendError.unavailable }
            let data = try await authorized(path: "functions/v1/reader-member?\(query)", body: nil, method: "GET", accountID: accountID,
                                            maximumResponseBytes: member.bytes)
            guard data.count == member.bytes else { throw BackendError.transport }
            return data
        }
        var request = URLRequest(url: member.url)
        request.httpMethod = "GET"
        let started = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await boundedResponse(for: request, maximumBytes: member.bytes)
        SessionTimeline.shared.record("request", ["method": "GET", "path": "storage/reader-member", "status": String((response as? HTTPURLResponse)?.statusCode ?? 0),
            "bytes": String(data.count), "ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == member.bytes else { throw BackendError.transport }
        return data
    }

    // MARK: Paper podcasts (functions/v1/podcast and podcast-member; docs/architecture/PAPER_PODCASTS.md)

    /// One `podcast` Edge call: GET without a body, POST with a JSON body. Decoding and bounds are in ScienceReaderCore.
    func podcastCall(_ query: String, body: Data?, accountID: UUID, maximumResponseBytes: Int) async throws -> Data {
        try await authorized(path: "functions/v1/podcast?\(query)", body: body, method: body == nil ? "GET" : "POST",
                             accountID: accountID, maximumResponseBytes: maximumResponseBytes)
    }

    /// One single-use member: the bearer goes only to this origin's member endpoint; no Range, no retry here (a failed
    /// transfer has consumed its grant and needs a new one). `progress` reports bytes received, in steps.
    func podcastMember(_ member: PodcastMember, accountID: UUID, progress: @escaping @Sendable (Int) -> Void) async throws -> Data {
        try PodcastMemberTransport.validated(member.url, backendURL: config.url)
        let generation = authGeneration
        guard session?.user.id == accountID else { throw BackendError.signInRequired }
        let token = try await accessToken()
        guard generation == authGeneration, session?.user.id == accountID else { throw CancellationError() }
        var request = URLRequest(url: member.url)
        request.httpMethod = "GET"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let started = ProcessInfo.processInfo.systemUptime
        let (bytes, response) = try await network.bytes(for: request, delegate: LibraryRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw BackendError.transport }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { guard body.count < 4_096 else { break }; body.append(byte) }
            struct Failure: Decodable { let code: String? }
            let code = (try? JSONDecoder().decode(Failure.self, from: body))?.code
            throw BackendError.rejected(code.flatMap { BackendError.podcastCodes.contains($0) ? $0 : nil } ?? "request_failed")
        }
        guard http.expectedContentLength <= Int64(member.bytes) else { throw LibraryProtocolError.payloadTooLarge }
        return try await withTaskCancellationHandler {
            var data = Data(); data.reserveCapacity(member.bytes)
            for try await byte in bytes {
                guard data.count < member.bytes else { throw LibraryProtocolError.payloadTooLarge }
                data.append(byte)
                if data.count % 65_536 == 0 { progress(data.count) }
            }
            try Task.checkCancellation()
            progress(data.count)
            SessionTimeline.shared.record("request", ["method": "GET", "path": "functions/v1/podcast-member", "status": "200",
                "bytes": String(data.count), "ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
            guard generation == authGeneration, session?.user.id == accountID else { throw CancellationError() }
            return data
        } onCancel: { bytes.task.cancel() }
    }

    func reportImage(_ id: UUID, accountID: UUID) async throws -> Data {
        let data = try await authorized(path: "functions/v1/support-assets?attachment_id=\(id.wire)", body: nil, method: "GET", accountID: accountID)
        guard data.count <= 5 * 1024 * 1024 else { throw ReaderError.corruptData }
        return data
    }

    private func beginAuthenticationChange() throws {
        let attemptID = invalidateAuthenticationMemory()
        do {
            try credentials.delete("\(config.environment).auth-session")
            credentialCleanupAttempt = nil
        } catch {
            credentialCleanupAttempt = attemptID
            throw AuthenticationError.credentialStorage
        }
    }

    /// Always retire network/in-memory authority before fallible local I/O.
    /// A subsequent preparation retries cleanup before allocating new secrets.
    private func invalidateAuthenticationMemory() -> UUID? {
        let attemptID = signInAttempt?.id ?? credentialCleanupAttempt
        authGeneration &+= 1
        refreshTask?.task.cancel(); refreshTask = nil
        signInRequest?.task.cancel(); signInRequest = nil
        logoutTask?.task.cancel(); logoutTask = nil
        session = nil; signInAttempt = nil
        return attemptID
    }

    private func owns(_ attempt: SignInAttempt) -> Bool {
        attempt.generation == authGeneration && signInAttempt?.id == attempt.id
    }

    private func performSignInRequest(_ route: AuthRoute, body: Data, generation: UInt64) async throws -> Data {
        try Task.checkCancellation()
        guard generation == authGeneration else { throw CancellationError() }
        let id = UUID(), task = Task { try await self.authRaw(route, body: body) }
        signInRequest = (id, task)
        defer { if signInRequest?.id == id { signInRequest = nil } }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == authGeneration else { throw CancellationError() }
            return result
        } catch {
            guard generation == authGeneration else { throw CancellationError() }
            throw error
        }
    }

    private func authorized(path: String, body: Data?, method: String = "POST", mediaType: String = "application/json", accountID: UUID?,
                            maximumResponseBytes: Int? = nil, libraryErrors: Bool = false,
                            libraryCommandErrors: Bool = false) async throws -> Data {
        let generation = authGeneration
        guard let expected = session?.user.id, accountID == nil || expected == accountID else { throw BackendError.signInRequired }
        let token = try await accessToken()
        guard generation == authGeneration, session?.user.id == expected else { throw CancellationError() }
        do {
            let data = try await raw(path: path, body: body, token: token, method: method, mediaType: mediaType,
                                     maximumResponseBytes: maximumResponseBytes, libraryErrors: libraryErrors,
                                     libraryCommandErrors: libraryCommandErrors)
            guard generation == authGeneration, session?.user.id == expected else { throw CancellationError() }
            return data
        } catch {
            // A late error belongs to the same authentication generation as a
            // late success; it must not reset or alter the next account session.
            guard generation == authGeneration, session?.user.id == expected else { throw CancellationError() }
            throw error
        }
    }

    private func accessToken(validFor seconds: TimeInterval = 60) async throws -> String {
        guard let current = session else { throw BackendError.signInRequired }
        if current.expires_at > Date().timeIntervalSince1970 + seconds { return current.access_token }
        let generation = authGeneration
        let task: Task<AuthSession, Error>
        if let existing = refreshTask, existing.generation == generation { task = existing.task }
        else {
            task = Task { () throws -> AuthSession in
                let bytes = try await self.authRaw(.token(.refreshToken), body: ReaderCrypto.encode(["refresh_token": current.refresh_token]))
                return try Self.decodeSession(bytes)
            }
            refreshTask = (generation, task)
        }
        defer { if refreshTask?.generation == generation { refreshTask = nil } }
        let next: AuthSession
        do { next = try await task.value }
        catch {
            guard generation == authGeneration, session?.user.id == current.user.id else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard generation == authGeneration, session?.user.id == current.user.id, next.user.id == current.user.id else { throw CancellationError() }
        try save(next)
        return next.access_token
    }

    private func save(_ next: AuthSession) throws {
        do { try credentials.write(ReaderCrypto.encode(next), name: "\(config.environment).auth-session") }
        catch {
            // A storage implementation can fail after writing. Refuse local
            // success, invalidate memory, and attempt to remove that ambiguity.
            let attemptID = invalidateAuthenticationMemory()
            do {
                try credentials.delete("\(config.environment).auth-session")
                credentialCleanupAttempt = nil
            } catch { credentialCleanupAttempt = attemptID }
            throw AuthenticationError.credentialStorage
        }
        session = next
    }

    private enum AuthGrant: String { case pkce, idToken = "id_token", password, refreshToken = "refresh_token" }
    private enum AuthRoute {
        case token(AuthGrant), emailSend, emailVerify, signUp, logout
        var path: String {
            switch self {
            case .token(let grant): "auth/v1/token?grant_type=\(grant.rawValue)"
            case .emailSend: "auth/v1/otp"
            case .emailVerify: "auth/v1/verify"
            case .signUp: "auth/v1/signup"
            case .logout: "auth/v1/logout?scope=local"
            }
        }
        func accepts(_ status: Int) -> Bool {
            if case .logout = self { return status == 200 || status == 204 }
            return status == 200
        }
    }

    private func requireAuthenticationConfiguration() throws {
        guard let url = URLComponents(url: config.url, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              !config.anonKey.isEmpty, config.anonKey.utf8.count <= 16_384,
              config.anonKey.utf8.allSatisfy({ (33...126).contains($0) }),
              config.environment != "offline-resource" else { throw AuthenticationError.configuration }
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= AuthenticationConfiguration.maximumTokenBytes &&
            value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func validEmail(_ address: String) -> Bool {
        guard (1...320).contains(address.utf8.count) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } &&
            !address.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    private static func decodeSession(_ data: Data) throws -> AuthSession {
        guard data.count <= AuthenticationConfiguration.maximumResponseBytes else { throw AuthenticationError.invalidResponse }
        struct Wire: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_at: TimeInterval?
            let expires_in: TimeInterval?
            let token_type: String?
            let user: AuthSession.User
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              validToken(wire.access_token), validToken(wire.refresh_token),
              wire.token_type == nil || wire.token_type?.lowercased() == "bearer",
              wire.user.email.map({ $0.utf8.count <= 320 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true
        else { throw AuthenticationError.invalidResponse }
        let expiry: TimeInterval
        if let absolute = wire.expires_at { expiry = absolute }
        else if let interval = wire.expires_in, interval.isFinite, interval > 0, interval <= 31_536_000 {
            // GoTrue REST may send expires_in without the SDK-derived expires_at.
            expiry = Date().timeIntervalSince1970 + interval
        } else { throw AuthenticationError.invalidResponse }
        // Expired cached sessions (including epoch zero) may still refresh.
        guard expiry.isFinite, expiry >= 0, expiry <= 253_402_300_799 else { throw AuthenticationError.invalidResponse }
        return AuthSession(access_token: wire.access_token, refresh_token: wire.refresh_token,
                           expires_at: expiry, user: wire.user)
    }

    /// Auth has a separate bounded session so resource deadlines also apply to
    /// injected transports. No redirect, response body or retry policy can
    /// widen the fixed route; errors contain only finite local categories.
    private func authRaw(_ route: AuthRoute, body: Data, token: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        try requireAuthenticationConfiguration()
        guard body.count <= AuthenticationConfiguration.maximumRequestBytes,
              let url = URL(string: "/" + route.path, relativeTo: config.url)?.absoluteURL else { throw AuthenticationError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (bytes, rawResponse) = try await authNetwork.bytes(for: request, delegate: LibraryRedirectPolicy())
            defer { bytes.task.cancel() }
            guard let response = rawResponse as? HTTPURLResponse, response.url == url,
                  response.expectedContentLength <= Int64(AuthenticationConfiguration.maximumResponseBytes),
                  response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true
            else { throw AuthenticationError.invalidResponse }
            let declared: Int?
            if let text = response.value(forHTTPHeaderField: "Content-Length") {
                guard !text.isEmpty, text.utf8.count <= 10, text.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(text), count <= AuthenticationConfiguration.maximumResponseBytes else { throw AuthenticationError.invalidResponse }
                declared = count
            } else { declared = nil }
            let data = try await withTaskCancellationHandler {
                var data = Data()
                data.reserveCapacity(min(declared ?? 4_096, AuthenticationConfiguration.maximumResponseBytes))
                for try await byte in bytes {
                    guard data.count < AuthenticationConfiguration.maximumResponseBytes else { throw AuthenticationError.invalidResponse }
                    data.append(byte)
                }
                try Task.checkCancellation()
                guard declared == nil || declared == data.count else { throw AuthenticationError.invalidResponse }
                return data
            } onCancel: { bytes.task.cancel() }
            try Task.checkCancellation()
            guard route.accepts(response.statusCode) else {
                if (200..<400).contains(response.statusCode) { throw AuthenticationError.invalidResponse }
                throw Self.authFailure(route: route, response: response, data: data)
            }
            return data
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? AuthenticationError { throw error }
            throw AuthenticationError.connection
        }
    }

    private static func authFailure(route: AuthRoute, response: HTTPURLResponse, data: Data) -> AuthenticationError {
        struct Failure: Decodable {
            let code: String?
            let errorCode: String?
            enum CodingKeys: String, CodingKey { case code; case errorCode = "error_code" }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                code = try? c.decode(String.self, forKey: .code)
                errorCode = try? c.decode(String.self, forKey: .errorCode)
            }
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        let codes = [failure?.code, failure?.errorCode].compactMap { $0 }
        // A gateway/server failure cannot become definitive business evidence
        // merely because its body happens to contain a familiar code.
        if (500...599).contains(response.statusCode) { return .connection }
        if response.statusCode == 429 || codes.contains(where: { ["over_email_send_rate_limit", "over_request_rate_limit", "over_send_rate_limit"].contains($0) }) {
            let value = response.value(forHTTPHeaderField: "Retry-After")
            let retry = value.flatMap { text -> Int? in
                guard !text.isEmpty, text.utf8.count <= 5, text.utf8.allSatisfy({ (48...57).contains($0) }),
                      let seconds = Int(text), (0...86_400).contains(seconds) else { return nil }
                return seconds
            }
            return .rateLimited(retryAfterSeconds: retry)
        }
        if codes.contains("signup_disabled") { return .noAccount }
        if codes.contains(where: { ["provider_disabled", "email_provider_disabled", "otp_disabled"].contains($0) }) { return .configuration }
        if codes.contains("email_address_invalid") { return .invalidEmail }
        if case .emailVerify = route, codes.contains(where: { ["otp_expired", "invalid_credentials"].contains($0) }) { return .invalidCode }
        return .rejected
    }

    private func raw(path: String, body: Data?, token: String?, method: String = "POST", mediaType: String = "application/json",
                     maximumResponseBytes: Int? = nil, libraryErrors: Bool = false,
                     libraryCommandErrors: Bool = false) async throws -> Data {
        guard let url = URL(string: "/" + path, relativeTo: config.url)?.absoluteURL, url.host == config.url.host else { throw BackendError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        let started = ProcessInfo.processInfo.systemUptime
        do {
            if let maximumResponseBytes {
                // A one-byte member may have a larger finite JSON quota error. Keep the
                // success ceiling exact, with a separate small error-only ceiling.
                let errorBytes = path.hasPrefix("functions/v1/reader-member?") ? 4_096 : nil
                (data, response) = try await boundedResponse(for: request, maximumBytes: maximumResponseBytes, maximumErrorBytes: errorBytes)
            } else {
                (data, response) = try await network.data(for: request)
            }
        } catch {
            SessionTimeline.shared.record("request", ["method": method, "path": SessionTimeline.describe(path: path), "status": "failed",
                                                      "ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
            throw error
        }
        SessionTimeline.shared.record("request", ["method": method, "path": SessionTimeline.describe(path: path),
            "status": String((response as? HTTPURLResponse)?.statusCode ?? 0), "bytes": String(data.count),
            "ms": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))])
        guard let response = response as? HTTPURLResponse else { throw BackendError.transport }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let code: String?; let message: String?; let error_code: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if libraryErrors, response.statusCode == 400, failure?.code == "P0001", failure?.message == "library_resync_required" {
                throw LibraryTransportError.resyncRequired
            }
            // Only exact discovery absence permits the service to consider legacy
            // mode. Missing dependencies/pages and schema-cache errors do not.
            if path == "rest/v1/rpc/v1_reader_capabilities", response.statusCode == 404,
               failure?.code == "PGRST202",
               failure?.message == "Could not find the function public.v1_reader_capabilities without parameters in the schema cache" {
                throw ReaderCapabilityMissing()
            }
            if libraryCommandErrors {
                if response.statusCode == 401 { throw BackendError.signInRequired }
                // library_resync_required: a v5 command observed in a replaced dataset (042).
                let commandCodes: Set<String> = ["operation_id_conflict", "request_rate_limit", "library_resync_required",
                    "library_account_import_limit", "library_environment_import_limit", "library_active_import_limit",
                    "library_account_item_limit", "library_environment_item_limit",
                    "library_account_receipt_limit", "library_environment_receipt_limit",
                    "import_not_retryable", "invalid_library_cursor", "document_not_verified"]
                if response.statusCode == 400, failure?.code == "P0001", let message = failure?.message,
                   commandCodes.contains(message) { throw BackendError.rejected(message) }
                // Unknown bodies, wrong HTTP/SQL codes and embedded lookalike
                // strings never become an immutable-operation conflict.
                throw BackendError.rejected("request_failed")
            }
            let known = Set(["upload_too_large", "upload_quota", "upload_limit", "upload_storage_full", "upload_expired", "upload_id_conflict",
                             "upload_target_unavailable", "upload_incomplete", "upload_unavailable", "upload_revision_conflict", "upload_not_receiving",
                             "upload_not_frozen", "upload_mismatch", "upload_attempt_limit", "upload_receipt_capacity", "upload_target_busy",
                             "upload_write_proof_required", "upload_disabled", "upload_storage_capacity", "paper_storage_capacity", "asset_inventory_reconciling",
                             "library_descriptor_required", "invalid_upload", "rate_limited",
                             "library_active_import_limit", "import_not_retryable", "import_unavailable",
                             "insufficient_credits","platform_budget_exhausted","key_authority_required","stale_key_epoch","owner_mfa_required","operator_required","invalid_credentials","email_not_confirmed", "attachment_count_limit", "attachment_storage_limit", "request_rate_limit", "attachment_expired", "sync_account_storage_limit", "sync_environment_storage_limit", "sync_account_transfer_limit", "sync_environment_transfer_limit", "sync_page_too_large", "account_busy", "confirmation_required", "purchases_unavailable", "feed_unavailable", "invalid_feed_topic"]).union(BackendError.readerDeliveryCodes)
                .union(BackendError.podcastCodes)
            let code = [failure?.message, failure?.error_code, failure?.code].compactMap { $0 }.first { known.contains($0) } ?? "request_failed"
            throw BackendError.rejected(code)
        }
        return data
    }

    private func boundedResponse(for request: URLRequest, maximumBytes: Int, maximumErrorBytes: Int? = nil) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await network.bytes(for: request, delegate: LibraryRedirectPolicy())
        // Always cancel on early exit, including a false Content-Length,
        // decoder-independent overflow, cancellation, or a truncated stream.
        defer { bytes.task.cancel() }
        let allowedBytes = if let maximumErrorBytes, let response = response as? HTTPURLResponse,
                              !(200..<300).contains(response.statusCode) { maximumErrorBytes } else { maximumBytes }
        guard response.expectedContentLength <= Int64(allowedBytes) else { throw LibraryProtocolError.payloadTooLarge }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(min(allowedBytes, 65_536))
            for try await byte in bytes {
                guard data.count < allowedBytes else { throw LibraryProtocolError.payloadTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } onCancel: { bytes.task.cancel() }
    }
}

/// Library and auth requests stay on their configured origin. Never follow a
/// redirect before parsing an error or forward credentials to its target.
private struct ReaderCapabilityMissing: Error {}

/// Bytes sent of a PDF upload, as a fraction.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
    // The signed upload URL is final: a redirect is never followed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class LibraryRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

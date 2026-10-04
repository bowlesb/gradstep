import Foundation
import Observation
import ScienceReaderCore

/// Presenters own platform UI only. Credentials and provider secrets belong to
/// the backend, and this coordinator owns whether a returned result is current.
@MainActor
protocol AuthenticationPresenting: AnyObject {
    func google(_ authorization: GoogleAuthorization) async throws -> URL
    func apple(_ authorization: AppleAuthorization) async throws -> String
    func cancel()
}

enum AuthenticationPresentationError: Error, Equatable { case cancelled, unavailable, invalidCredential }

@MainActor @Observable
final class AuthenticationCoordinator {
    enum Method: Equatable { case apple, google, email }
    enum Issue: Equatable {
        case configuration, presentation, invalidEmail, invalidCode, rateLimited
        case connection, invalidResponse, credentialStorage, rejected

        var message: String {
            switch self {
            case .configuration: "Sign-in isn’t available in this build."
            case .presentation: "Couldn’t open sign-in. Please try again."
            case .invalidEmail: "Enter a valid email address."
            case .invalidCode: "That code wasn’t accepted. Check it or request a new one."
            case .rateLimited: "Too many attempts. Please wait before trying again."
            case .connection: "Couldn’t finish sign-in. Check your connection and try again."
            case .invalidResponse: "Couldn’t verify the sign-in response. Please try again."
            case .credentialStorage: "Couldn’t update sign-in on this device. Please try again."
            case .rejected: "Sign-in wasn’t completed. Try again or choose another method."
            }
        }
    }

    struct Presentation: Equatable, Identifiable {
        let id: UUID
        let readerSessionID: UUID
    }
    struct EmailChallenge: Equatable {
        let attemptID: UUID
        let email: String
        let delivery: EmailCodeDelivery
        let resendAfter: TimeInterval
        var issue: Issue?
        var verifyAfter: TimeInterval = 0
    }
    enum Phase: Equatable {
        case closed
        case choices(Issue?)
        case emailEntry(email: String, issue: Issue?)
        case preparing(Method)
        case external(Method)
        case sendingCode(email: String)
        case codeEntry(EmailChallenge)
        case exchanging(Method)
        case cancelling
        case accepted(accountID: UUID)
    }
    struct Acceptance {
        let presentationID: UUID
        let readerSessionID: UUID
        let attemptID: UUID
        let backendAttemptID: UUID
        let user: AuthSession.User
    }

    private struct Attempt {
        let id: UUID
        let presentation: Presentation
        let method: Method
        let email: String?
        let presenter: (any AuthenticationPresenting)?
        var backendID: UUID?
    }
    private enum Intent {
        case choices, email(String)
        case start(Method, email: String?, presenter: (any AuthenticationPresenting)?)
    }

    private(set) var presentation: Presentation?
    private(set) var phase: Phase = .closed
    @ObservationIgnored private let backend: any AuthenticationBackend
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let accept: @MainActor (Acceptance) -> Bool
    @ObservationIgnored private let predecessor: Task<Void, Never>?
    @ObservationIgnored private var attempt: Attempt?
    @ObservationIgnored private var pending: (presentation: Presentation, intent: Intent)?
    @ObservationIgnored private var retiredBackendID: UUID?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var actionID: UUID?
    @ObservationIgnored private var cleanupIssue: Issue?

    init(backend: any AuthenticationBackend,
         predecessor: Task<Void, Never>? = nil,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         accept: @escaping @MainActor (Acceptance) -> Bool) {
        self.backend = backend; self.predecessor = predecessor; self.now = now; self.accept = accept
    }

    @discardableResult
    func open(readerSessionID: UUID) -> Presentation {
        if let presentation { return presentation }
        let next = Presentation(id: UUID(), readerSessionID: readerSessionID)
        presentation = next; phase = .choices(cleanupIssue)
        return next
    }

    func startApple(presenter: any AuthenticationPresenting) {
        request(.start(.apple, email: nil, presenter: presenter))
    }
    func startGoogle(presenter: any AuthenticationPresenting) {
        request(.start(.google, email: nil, presenter: presenter))
    }
    func showEmail() { request(.email("")) }
    func showChoices() { request(.choices) }
    func useAnotherEmail() {
        guard case .codeEntry(let challenge) = phase else { return }
        request(.email(challenge.email))
    }
    func sendCode(email: String) {
        guard case .emailEntry = phase else { return }
        request(.start(.email, email: email, presenter: nil))
    }
    func resendCode() {
        guard case .codeEntry(let challenge) = phase, now() >= challenge.resendAfter else { return }
        request(.start(.email, email: challenge.email, presenter: nil))
    }
    func resendSecondsRemaining(at instant: TimeInterval? = nil) -> Int {
        guard case .codeEntry(let challenge) = phase else { return 0 }
        return max(0, Int(ceil(challenge.resendAfter - (instant ?? now()))))
    }
    func verifySecondsRemaining(at instant: TimeInterval? = nil) -> Int {
        guard case .codeEntry(let challenge) = phase else { return 0 }
        return max(0, Int(ceil(challenge.verifyAfter - (instant ?? now()))))
    }

    func verifyCode(_ code: String) {
        guard case .codeEntry(let challenge) = phase, let current = attempt,
              current.id == challenge.attemptID, let backendID = current.backendID,
              owns(current), actionTask == nil, now() >= challenge.verifyAfter else { return }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            var failed = challenge; failed.issue = .invalidCode; phase = .codeEntry(failed)
            return
        }
        phase = .exchanging(.email)
        runAction(current) { [backend] in
            try await backend.finishEmailSignIn(id: backendID, code: code)
        } failure: { [weak self] error in
            guard let self, self.owns(current) else { return }
            if (error as? AuthenticationError) == .credentialStorage || error is CancellationError {
                // Credential persistence failure and backend invalidation end
                // this challenge. Do not offer Continue against a dead ID.
                self.retireCurrent()
                self.phase = .emailEntry(email: challenge.email,
                    issue: error is CancellationError ? .rejected : .credentialStorage)
                self.driveLifecycle()
                return
            }
            var failed = challenge
            failed.issue = Self.issue(error)
            if case AuthenticationError.rateLimited(let delay) = error {
                failed = EmailChallenge(attemptID: challenge.attemptID, email: challenge.email,
                    delivery: challenge.delivery,
                    resendAfter: max(challenge.resendAfter, self.now() + Double(delay ?? 60)),
                    issue: .rateLimited, verifyAfter: self.now() + Double(delay ?? 60))
            }
            self.phase = .codeEntry(failed)
        }
    }

    /// The view supplies the ID it actually presented. An old onDismiss cannot
    /// cancel a newer sheet, and an accepted sheet cannot erase its session.
    func close(presentationID: UUID) {
        guard presentation?.id == presentationID else { return }
        if case .accepted = phase { return }
        invalidate()
    }

    func didDismiss(presentationID: UUID) {
        guard presentation?.id == presentationID else { return }
        if case .accepted = phase {
            attempt = nil; pending = nil; presentation = nil; phase = .closed
        } else { invalidate() }
    }

    /// Account Sign out may retire even an accepted attempt. It is distinct
    /// from successful presentation dismissal, which must retain credentials.
    func invalidate() {
        retireCurrent()
        pending = nil; presentation = nil; phase = .closed
        driveLifecycle()
    }

    /// A replacement presentation can use a new coordinator, but must still
    /// join this owner's short preparation/cleanup lane before its first begin.
    func waitForRetirement() async {
        while let task = lifecycleTask { await task.value }
    }

    private func request(_ intent: Intent) {
        guard let presentation else { return }
        if case .accepted = phase { return }
        retireCurrent()
        pending = (presentation, intent)
        if case .start(let method, _, _) = intent { phase = .preparing(method) }
        else { phase = .cancelling }
        driveLifecycle()
    }

    private func retireCurrent() {
        // Fence local delivery before cancellation can call a delegate back.
        let old = attempt; attempt = nil
        actionID = nil
        let oldAction = actionTask; actionTask = nil
        oldAction?.cancel(); old?.presenter?.cancel()
        if let backendID = old?.backendID {
            // Only the lifecycle lane can allocate a backend owner. It cannot
            // allocate another one until this retirement has completed.
            precondition(retiredBackendID == nil || retiredBackendID == backendID)
            retiredBackendID = backendID
        }
    }

    private func driveLifecycle() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await self.drainLifecycle()
        }
    }

    /// One short begin/cancel lane, with at most one latest replacement intent.
    /// Browser presentation and network exchanges never occupy this lane.
    private func drainLifecycle() async {
        defer { lifecycleTask = nil }
        // Account sign-out has a separate owner. Its local credential
        // retirement must finish before any newer begin may mutate authority.
        await predecessor?.value
        while true {
            if let retiring = retiredBackendID {
                do {
                    try await backend.cancelSignIn(id: retiring)
                    if retiredBackendID == retiring { retiredBackendID = nil }
                    cleanupIssue = nil
                } catch {
                    // The backend invalidates memory before cleanup can fail.
                    // The next explicit begin must retry that durable cleanup.
                    retiredBackendID = nil; cleanupIssue = .credentialStorage
                    pending = nil
                    if presentation != nil { phase = .choices(.credentialStorage) }
                    return
                }
            }
            guard let next = pending else { return }
            pending = nil
            guard presentation == next.presentation else { continue }
            switch next.intent {
            case .choices: phase = .choices(cleanupIssue)
            case .email(let email): phase = .emailEntry(email: email, issue: cleanupIssue)
            case .start(let method, let email, let presenter):
                let current = Attempt(id: UUID(), presentation: next.presentation,
                                      method: method, email: email, presenter: presenter)
                attempt = current; phase = .preparing(method)
                do {
                    switch method {
                    case .apple:
                        let authorization = try await backend.beginAppleSignIn()
                        guard retain(authorization.id, for: current) else { continue }
                        startApple(authorization, current: current)
                    case .google:
                        let authorization = try await backend.beginGoogleSignIn()
                        guard retain(authorization.id, for: current) else { continue }
                        startGoogle(authorization, current: current)
                    case .email:
                        let authorization = try await backend.prepareEmailSignIn(email: email ?? "")
                        guard retain(authorization.id, for: current) else { continue }
                        startEmail(authorization, current: current)
                    }
                    cleanupIssue = nil
                } catch {
                    guard owns(current) else { continue }
                    attempt = nil
                    let issue = Self.issue(error)
                    if issue == .credentialStorage { cleanupIssue = issue }
                    phase = method == .email ? .emailEntry(email: email ?? "", issue: issue) : .choices(issue)
                }
            }
        }
    }

    private func retain(_ backendID: UUID, for current: Attempt) -> Bool {
        guard owns(current) else {
            // A delayed begin still created backend state. Retire it before
            // preparing the replacement, even if its original task was closed.
            precondition(retiredBackendID == nil)
            retiredBackendID = backendID
            return false
        }
        attempt?.backendID = backendID
        return true
    }

    private func startApple(_ authorization: AppleAuthorization, current: Attempt) {
        guard let presenter = current.presenter else { request(.choices); return }
        phase = .external(.apple)
        runAction(current) { [weak self, backend] in
            let token = try await presenter.apple(authorization)
            guard let self, self.owns(current), self.phase == .external(.apple) else { throw CancellationError() }
            self.phase = .exchanging(.apple)
            return try await backend.finishAppleSignIn(id: authorization.id, identityToken: token)
        }
    }
    private func startGoogle(_ authorization: GoogleAuthorization, current: Attempt) {
        guard let presenter = current.presenter else { request(.choices); return }
        phase = .external(.google)
        runAction(current) { [weak self, backend] in
            let callback = try await presenter.google(authorization)
            guard let self, self.owns(current), self.phase == .external(.google) else { throw CancellationError() }
            self.phase = .exchanging(.google)
            return try await backend.finishGoogleSignIn(id: authorization.id, callbackURL: callback)
        }
    }
    private func startEmail(_ authorization: EmailAuthorization, current: Attempt) {
        phase = .sendingCode(email: authorization.email)
        let started = now(), token = UUID()
        actionID = token
        actionTask = Task { [weak self, backend] in
            do {
                let delivery = try await backend.sendEmailCode(id: authorization.id)
                guard let self, self.owns(current), self.actionID == token else { return }
                self.phase = .codeEntry(EmailChallenge(attemptID: current.id, email: authorization.email,
                    delivery: delivery, resendAfter: started + 60, issue: nil))
            } catch {
                guard let self, self.owns(current), self.actionID == token else { return }
                if case AuthenticationError.rateLimited(let delay) = error {
                    // A code may already exist. Keep entry available, but do
                    // not claim that this request delivered one.
                    self.phase = .codeEntry(EmailChallenge(attemptID: current.id, email: authorization.email,
                        delivery: .unconfirmed, resendAfter: self.now() + Double(delay ?? 60), issue: .rateLimited))
                } else {
                    self.retireCurrent()
                    self.phase = .emailEntry(email: authorization.email, issue: Self.issue(error))
                    self.driveLifecycle()
                }
            }
            guard let self, self.actionID == token else { return }
            self.actionID = nil; self.actionTask = nil
        }
    }

    private func runAction(_ current: Attempt,
                           operation: @escaping @MainActor () async throws -> AuthSession.User,
                           failure: (@MainActor (any Error) -> Void)? = nil) {
        let token = UUID(); actionID = token
        actionTask = Task { [weak self] in
            do {
                let user = try await operation()
                guard let self, self.owns(current), self.actionID == token,
                      self.phase == .exchanging(current.method),
                      let backendID = self.attempt?.backendID else { return }
                // Validation, acceptance and the model handoff share one
                // MainActor turn: there is no dismissal/cancellation gap.
                self.phase = .accepted(accountID: user.id)
                let accepted = self.accept(Acceptance(presentationID: current.presentation.id,
                    readerSessionID: current.presentation.readerSessionID, attemptID: current.id,
                    backendAttemptID: backendID, user: user))
                if !accepted { self.invalidate() }
            } catch {
                guard let self, self.owns(current), self.actionID == token else { return }
                if let failure { failure(error) }
                else {
                    self.retireCurrent()
                    let cancelled = error is CancellationError ||
                        (error as? AuthenticationPresentationError) == .cancelled
                    self.phase = .choices(cancelled ? nil : Self.issue(error))
                    self.driveLifecycle()
                }
            }
            guard let self, self.actionID == token else { return }
            self.actionID = nil; self.actionTask = nil
        }
    }

    private func owns(_ current: Attempt) -> Bool {
        presentation == current.presentation && attempt?.id == current.id
    }

    private static func issue(_ error: any Error) -> Issue {
        if let error = error as? AuthenticationError {
            return switch error {
            case .configuration: .configuration
            case .invalidEmail: .invalidEmail
            case .invalidCode: .invalidCode
            case .rateLimited: .rateLimited
            case .connection: .connection
            case .invalidResponse: .invalidResponse
            case .credentialStorage: .credentialStorage
            case .rejected: .rejected
            }
        }
        if error is OAuthFlowError { return .invalidResponse }
        if let error = error as? AuthenticationPresentationError {
            return error == .invalidCredential ? .invalidResponse : .presentation
        }
        return .connection
    }
}

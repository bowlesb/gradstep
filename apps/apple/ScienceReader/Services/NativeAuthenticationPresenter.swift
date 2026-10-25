import AuthenticationServices
import Foundation
import UIKit

/// Owns only the system presentation. The coordinator and backend decide whether
/// a returned credential still belongs to an accepted authentication attempt.
@MainActor
final class NativeAuthenticationPresenter: NSObject, AuthenticationPresenting {
    private struct GooglePresentation {
        let id: UUID
        let session: ASWebAuthenticationSession
        let continuation: CheckedContinuation<URL, any Error>
    }

    private struct ApplePresentation {
        let id: UUID
        let controller: ASAuthorizationController
        let continuation: CheckedContinuation<String, any Error>
    }

    private enum Presentation {
        case google(GooglePresentation)
        case apple(ApplePresentation)

        var id: UUID {
            switch self {
            case .google(let current): current.id
            case .apple(let current): current.id
            }
        }
    }

    // Retain the actual window supplied by the account sheet. Never choose an
    // unrelated scene's key window or manufacture an unattached fallback window.
    private let anchor: UIWindow
    private var presentation: Presentation?
    /// The one presenter whose Google page is open, for a return that reaches the app's URL handler instead of the
    /// session (see `handleOpenedURL`). Weak: the coordinator's attempt owns the presenter.
    private static weak var googleOwner: NativeAuthenticationPresenter?

    init(anchor: UIWindow) {
        self.anchor = anchor
        super.init()
    }

    func google(_ authorization: GoogleAuthorization) async throws -> URL {
        let id = UUID()
        let callbackURL = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard presentation == nil, canPresent,
                  authorization.url.absoluteString.utf8.count <= 8_192,
                  let source = URLComponents(url: authorization.url, resolvingAgainstBaseURL: false),
                  source.scheme == "https", source.host?.isEmpty == false,
                  source.user == nil, source.password == nil, source.port == nil, source.fragment == nil,
                  authorization.callbackURL.absoluteString.utf8.count <= 8_192,
                  let callback = URLComponents(url: authorization.callbackURL, resolvingAgainstBaseURL: false),
                  let scheme = callback.scheme, !scheme.isEmpty, scheme != "http", scheme != "https",
                  callback.host?.isEmpty == false, callback.user == nil, callback.password == nil,
                  callback.port == nil, callback.query == nil, callback.fragment == nil else {
                throw AuthenticationPresentationError.unavailable
            }
            return try await withCheckedThrowingContinuation { continuation in
                let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
                    // Reduce provider errors before crossing to MainActor. No
                    // raw error, description or callback URL enters diagnostics.
                    let result: Result<URL, AuthenticationPresentationError>
                    // Diagnostics keep only a fixed reason (the session error's number, never its text).
                    let reason: String
                    if let error {
                        let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        result = .failure(cancelled ? .cancelled : .unavailable)
                        reason = cancelled ? "closed" : "session-error-\((error as NSError).code)"
                    } else if let callbackURL, callbackURL.absoluteString.utf8.count <= 8_192 {
                        // The backend's existing PKCE validator checks the full
                        // URI, code and forbidden token fragments before exchange.
                        result = .success(callbackURL)
                        reason = "session"
                    } else {
                        result = .failure(.invalidCredential)
                        reason = callbackURL == nil ? "no-return" : "return-too-long"
                    }
                    Task { @MainActor [weak self] in
                        self?.finishGoogle(id: id, result: result, reason: reason)
                    }
                }
                let session: ASWebAuthenticationSession
                if #available(iOS 17.4, *) {
                    session = ASWebAuthenticationSession(url: authorization.url,
                        callback: .customScheme(scheme), completionHandler: completion)
                } else {
                    session = ASWebAuthenticationSession(url: authorization.url,
                        callbackURLScheme: scheme, completionHandler: completion)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                presentation = .google(GooglePresentation(id: id, session: session, continuation: continuation))
                Self.googleOwner = self
                if !session.start() {
                    finishGoogle(id: id, result: .failure(.unavailable), reason: "start-failed")
                }
            }
        } onCancel: { [weak self] in
            // A delayed cancellation handler belongs only to this operation,
            // even if a caller has already started another presentation.
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
        try Task.checkCancellation()
        return callbackURL
    }

    func apple(_ authorization: AppleAuthorization) async throws -> String {
        let id = UUID()
        let identityToken = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard presentation == nil, canPresent,
                  authorization.hashedNonce.utf8.count == 64,
                  authorization.hashedNonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AuthenticationPresentationError.unavailable
            }
            return try await withCheckedThrowingContinuation { continuation in
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.email]
                request.nonce = authorization.hashedNonce
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                presentation = .apple(ApplePresentation(id: id, controller: controller, continuation: continuation))
                controller.performRequests()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
        try Task.checkCancellation()
        return identityToken
    }

    func cancel() {
        guard let current = presentation else { return }
        cancel(id: current.id)
    }

    private var canPresent: Bool {
        !anchor.isHidden && anchor.alpha > 0 &&
            anchor.windowScene?.activationState == .foregroundActive
    }

    private func cancel(id: UUID) {
        guard let current = presentation, current.id == id else { return }
        // Fence first: platform cancel may deliver a delegate callback before
        // returning. This continuation is owned locally and completes once.
        presentation = nil
        switch current {
        case .google(let current):
            if Self.googleOwner === self { Self.googleOwner = nil }
            current.session.cancel()
            current.continuation.resume(throwing: AuthenticationPresentationError.cancelled)
        case .apple(let current):
            current.controller.delegate = nil
            current.controller.presentationContextProvider = nil
            current.controller.cancel()
            current.continuation.resume(throwing: AuthenticationPresentationError.cancelled)
        }
    }

    /// Whether `url` is the app's sign-in return (`sciencereader://auth/callback`), whatever its query.
    static func isAuthenticationCallback(_ url: URL) -> Bool {
        guard let received = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: AuthenticationConfiguration.callbackURL, resolvingAgainstBaseURL: false)
        else { return false }
        return received.scheme?.lowercased() == expected.scheme?.lowercased()
            && received.host?.lowercased() == expected.host?.lowercased()
            && received.percentEncodedPath == expected.percentEncodedPath
    }

    /// The app's URL handler offers every opened URL here first. The Google return is registered as the app's own
    /// scheme, so the system can hand it to the app rather than to the open authentication session; the session then
    /// never answers and the sheet went back to its choices with no word (owner report, iPad build 86: Supabase
    /// issued the code, no exchange followed). Deliver it to the one open Google presentation, exactly as if the
    /// session had answered: the coordinator still checks the attempt owns it, and the backend validates the whole URI
    /// and needs this attempt's PKCE verifier, so nothing outside the attempt can sign in. A sign-in return with no
    /// open Google page is dropped. Returns whether the URL was a sign-in return (consumed either way).
    @discardableResult
    static func handleOpenedURL(_ url: URL) -> Bool {
        guard isAuthenticationCallback(url) else { return false }
        guard url.absoluteString.utf8.count <= 8_192, let owner = googleOwner,
              case .google(let current) = owner.presentation else {
            // The page had already closed, or the return is oversized: the person was told it didn't finish.
            SignInDiagnostics.shared.record(method: "google", stage: "callback", reason: "no-open-page",
                                            detail: "route=app-url length=\(url.absoluteString.utf8.count)")
            return true
        }
        owner.finishGoogle(id: current.id, result: .success(url), reason: "app-url")
        // Fenced above: the session's own cancellation callback finds no presentation and is ignored.
        current.session.cancel()
        return true
    }

    /// `reason`: how the return arrived ("session", "app-url"), or why there was none. Recorded only for the page still
    /// open here, so the session's answer to our own `cancel()` (after an app-URL return, or Close) adds nothing.
    private func finishGoogle(id: UUID, result: Result<URL, AuthenticationPresentationError>, reason: String) {
        guard case .google(let current) = presentation, current.id == id else { return }
        if case .success = result { SignInDiagnostics.shared.noteReturnRoute(reason) }
        else { SignInDiagnostics.shared.record(method: "google", stage: "presentation", reason: reason) }
        presentation = nil
        if Self.googleOwner === self { Self.googleOwner = nil }
        switch result {
        case .success(let callback): current.continuation.resume(returning: callback)
        case .failure(let error): current.continuation.resume(throwing: error)
        }
    }

    private func finishApple(controller: ASAuthorizationController, result: Result<String, AuthenticationPresentationError>) {
        guard case .apple(let current) = presentation, current.controller === controller else { return }
        presentation = nil
        controller.delegate = nil
        controller.presentationContextProvider = nil
        switch result {
        case .success(let token): current.continuation.resume(returning: token)
        case .failure(let error): current.continuation.resume(throwing: error)
        }
    }
}

extension NativeAuthenticationPresenter: ASWebAuthenticationPresentationContextProviding,
    ASAuthorizationControllerPresentationContextProviding, ASAuthorizationControllerDelegate {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard case .apple(let current) = presentation, current.controller === controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let bytes = credential.identityToken,
              (1...AuthenticationConfiguration.maximumTokenBytes).contains(bytes.count),
              bytes.allSatisfy({ (33...126).contains($0) }),
              let token = String(data: bytes, encoding: .utf8) else {
            finishApple(controller: controller, result: .failure(.invalidCredential))
            return
        }
        // An absent optional email/full name does not invalidate an identity token.
        finishApple(controller: controller, result: .success(token))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        let category: AuthenticationPresentationError = cancelled ? .cancelled : .unavailable
        finishApple(controller: controller, result: .failure(category))
    }
}

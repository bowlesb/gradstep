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
                    if let error {
                        let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        result = .failure(cancelled ? .cancelled : .unavailable)
                    } else if let callbackURL, callbackURL.absoluteString.utf8.count <= 8_192 {
                        // The backend's existing PKCE validator checks the full
                        // URI, code and forbidden token fragments before exchange.
                        result = .success(callbackURL)
                    } else {
                        result = .failure(.invalidCredential)
                    }
                    Task { @MainActor [weak self] in
                        self?.finishGoogle(id: id, result: result)
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
                if !session.start() {
                    finishGoogle(id: id, result: .failure(.unavailable))
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
            current.session.cancel()
            current.continuation.resume(throwing: AuthenticationPresentationError.cancelled)
        case .apple(let current):
            current.controller.delegate = nil
            current.controller.presentationContextProvider = nil
            current.controller.cancel()
            current.continuation.resume(throwing: AuthenticationPresentationError.cancelled)
        }
    }

    private func finishGoogle(id: UUID, result: Result<URL, AuthenticationPresentationError>) {
        guard case .google(let current) = presentation, current.id == id else { return }
        presentation = nil
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

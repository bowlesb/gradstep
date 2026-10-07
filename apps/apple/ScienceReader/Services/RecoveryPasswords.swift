import AuthenticationServices
import Security
import UIKit

/// Keeps the recovery code in the person's own Passwords (iCloud Keychain) under gradstep.ai,
/// through the `webcredentials:gradstep.ai` association. Both directions are system UI the
/// person approves; the app never reads Passwords without their choice and never sends the code
/// anywhere. Saving is optional: the code still works if it's written down instead.
@MainActor
enum RecoveryPasswords {
    static let domain = "gradstep.ai"
    static let title = "Gradstep recovery code"

    enum Failure: Error { case unavailable, cancelled }

    /// The account name shown in Passwords. Sign in with Apple may not share an email.
    static func account(email: String?) -> String {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Gradstep account" : trimmed
    }

    static func save(code: String, account: String, anchor: UIWindow) async throws {
        if #available(iOS 26.2, *) {
            do {
                try await ASCredentialDataManager().save(password: ASPasswordCredential(user: account, password: code),
                                                         for: ASAutoFillURLScope(host: domain), title: title, anchor: anchor)
            } catch let error as ASAuthorizationError where error.code == .canceled {
                throw Failure.cancelled
            } catch {
                throw Failure.unavailable
            }
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                SecAddSharedWebCredential(domain as CFString, account as CFString, code as CFString) { error in
                    if let error {
                        let code = CFErrorGetCode(error)
                        continuation.resume(throwing: code == Int(errSecUserCanceled) ? Failure.cancelled : Failure.unavailable)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Asks the system to offer the passwords saved for gradstep.ai; returns the one chosen.
    static func request(anchor: UIWindow) async throws -> String {
        let request = PasswordRequest(anchor: anchor)
        return try await request.run()
    }
}

@MainActor
private final class PasswordRequest: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: UIWindow
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<String, any Error>?

    init(anchor: UIWindow) { self.anchor = anchor }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [ASAuthorizationPasswordProvider().createRequest()])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller // Retained until the system answers.
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<String, RecoveryPasswords.Failure>) {
        controller?.delegate = nil; controller?.presentationContextProvider = nil; controller = nil
        continuation?.resume(with: result.mapError { $0 as any Error }); continuation = nil
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let password = (authorization.credential as? ASPasswordCredential)?.password
        MainActor.assumeIsolated { finish(password.map { .success($0) } ?? .failure(.unavailable)) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        MainActor.assumeIsolated { finish(.failure(cancelled ? .cancelled : .unavailable)) }
    }
}

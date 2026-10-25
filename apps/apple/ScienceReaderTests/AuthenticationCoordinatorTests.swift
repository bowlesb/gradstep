import Foundation
import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// Held operations intentionally ignore task cancellation so that these tests
/// exercise ownership at delivery, not only a cooperative fake transport.
@MainActor
private final class AuthenticationOwnerBackend: AuthenticationBackend {
    enum Kind: Equatable { case apple, google, email }
    var begins: [(Kind, UUID)] = []
    var cancellations: [UUID] = []
    var sends: [UUID] = []
    var verifications: [(UUID, String)] = []
    var current: UUID?
    var user: AuthSession.User?
    var holdNextBegin = false
    var holdExchanges = false
    var holdSends = false
    var failNextCancellation = false
    var nextVerificationError: AuthenticationError?
    var delivery: EmailCodeDelivery = .sent
    private var beginGate: CheckedContinuation<Void, Never>?
    private var exchanges: [UUID: CheckedContinuation<AuthSession.User, Error>] = [:]
    private var sendGates: [UUID: CheckedContinuation<EmailCodeDelivery, Error>] = [:]

    func currentUser() async -> AuthSession.User? { user }
    private func begin(_ kind: Kind) async -> UUID {
        let id = UUID(); begins.append((kind, id)); current = id; user = nil
        if holdNextBegin {
            holdNextBegin = false
            await withCheckedContinuation { beginGate = $0 }
        }
        return id
    }
    func beginGoogleSignIn() async throws -> GoogleAuthorization {
        let id = await begin(.google)
        return GoogleAuthorization(id: id, url: URL(string: "https://fixture.invalid/authorize")!,
            callbackURL: URL(string: "sciencereader://auth/callback")!)
    }
    func beginAppleSignIn() async throws -> AppleAuthorization {
        AppleAuthorization(id: await begin(.apple), hashedNonce: "fixture")
    }
    func prepareEmailSignIn(email: String) async throws -> EmailAuthorization {
        EmailAuthorization(id: await begin(.email), email: email.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func sendEmailCode(id: UUID) async throws -> EmailCodeDelivery {
        sends.append(id)
        if holdSends { return try await withCheckedThrowingContinuation { sendGates[id] = $0 } }
        return delivery
    }
    private func finish(_ id: UUID) async throws -> AuthSession.User {
        if holdExchanges {
            return try await withCheckedThrowingContinuation { exchanges[id] = $0 }
        }
        let result = AuthSession.User(id: UUID(), email: nil); user = result
        return result
    }
    func finishGoogleSignIn(id: UUID, callbackURL: URL) async throws -> AuthSession.User { try await finish(id) }
    func finishAppleSignIn(id: UUID, identityToken: String) async throws -> AuthSession.User { try await finish(id) }
    func finishEmailSignIn(id: UUID, code: String) async throws -> AuthSession.User {
        verifications.append((id, code))
        if let error = nextVerificationError { nextVerificationError = nil; throw error }
        return try await finish(id)
    }
    func cancelSignIn(id: UUID) async throws {
        cancellations.append(id)
        if current == id { current = nil; user = nil }
        if failNextCancellation { failNextCancellation = false; throw AuthenticationError.credentialStorage }
    }
    func signOut() async throws { current = nil; user = nil }
    func releaseBegin() { let gate = beginGate; beginGate = nil; gate?.resume() }
    func hasExchange(_ id: UUID) -> Bool { exchanges[id] != nil }
    func releaseExchange(_ id: UUID, result: Result<AuthSession.User, Error>) {
        exchanges.removeValue(forKey: id)?.resume(with: result)
    }
    func releaseSend(_ id: UUID, result: Result<EmailCodeDelivery, Error>) {
        sendGates.removeValue(forKey: id)?.resume(with: result)
    }
    func drain() {
        releaseBegin()
        let held = exchanges; exchanges = [:]
        for continuation in held.values { continuation.resume(throwing: CancellationError()) }
        let sending = sendGates; sendGates = [:]
        for continuation in sending.values { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class AuthenticationOwnerPresenter: AuthenticationPresenting {
    var starts = 0
    var cancellations = 0
    var error: AuthenticationPresentationError?
    func google(_ authorization: GoogleAuthorization) async throws -> URL {
        starts += 1
        if let error { throw error }
        return URL(string: authorization.callbackURL.absoluteString + "?code=fixture")!
    }
    func apple(_ authorization: AppleAuthorization) async throws -> String {
        starts += 1
        if let error { throw error }
        return "fixture-token"
    }
    func cancel() { cancellations += 1 }
}

/// A provider page that stays open until cancelled, as a real one does while the person is on it.
@MainActor
private final class HeldGooglePresenter: AuthenticationPresenting {
    var starts = 0
    var cancellations = 0
    private var pending: CheckedContinuation<Void, Error>?
    private func hold() async throws {
        starts += 1
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func google(_ authorization: GoogleAuthorization) async throws -> URL {
        try await hold(); return authorization.callbackURL
    }
    func apple(_ authorization: AppleAuthorization) async throws -> String {
        try await hold(); return "fixture-token"
    }
    func cancel() {
        cancellations += 1
        let waiting = pending; pending = nil
        waiting?.resume(throwing: AuthenticationPresentationError.cancelled)
    }
}

@MainActor
private final class AuthenticationOwnerFixture {
    let backend = AuthenticationOwnerBackend()
    var accepted: [AuthenticationCoordinator.Acceptance] = []
    var accepts = true
    var time: TimeInterval = 100
    lazy var coordinator = AuthenticationCoordinator(backend: backend, now: { [weak self] in self?.time ?? 0 }) { [weak self] acceptance in
        guard let self else { return false }
        self.accepted.append(acceptance)
        return self.accepts
    }
    func close() { coordinator.invalidate(); backend.drain() }
}

@MainActor
final class AuthenticationCoordinatorTests: XCTestCase {
    func testProviderRefusalReturnsToVisibleChoicesWithAnIssueAndCanRetry() async throws {
        for method in [AuthenticationCoordinator.Method.google, .apple] {
            let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
            fixture.backend.holdExchanges = true
            fixture.coordinator.open(readerSessionID: UUID())
            if method == .google { fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter()) }
            else { fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter()) }
            await eventually("provider exchange started") { fixture.backend.begins.last.map { fixture.backend.hasExchange($0.1) } ?? false }
            let id = try XCTUnwrap(fixture.backend.begins.last?.1)
            let refusal: any Error = method == .google ? OAuthFlowError.invitationRequired : AuthenticationError.noAccount
            fixture.backend.releaseExchange(id, result: .failure(refusal))
            await eventually("invitation refusal is visible") { fixture.coordinator.phase == .choices(.noAccount) }
            XCTAssertTrue(fixture.accepted.isEmpty)
            fixture.backend.holdExchanges = false
            if method == .google { fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter()) }
            else { fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter()) }
            await eventually("fresh attempt accepted after admission") { fixture.accepted.count == 1 }
        }
    }

    private func eventually(_ description: String,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), description, file: file, line: line)
    }

    func testAcceptedNoEmailAccountSurvivesClosingAndDismissingItsSheet() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        let owner = fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter())
        await eventually("Google accepted") { fixture.accepted.count == 1 }
        let accepted = try XCTUnwrap(fixture.accepted.first)
        XCTAssertNil(accepted.user.email)
        XCTAssertEqual(accepted.presentationID, owner.id)
        XCTAssertEqual(accepted.readerSessionID, owner.readerSessionID)
        fixture.coordinator.close(presentationID: owner.id)
        fixture.coordinator.didDismiss(presentationID: owner.id)
        XCTAssertEqual(fixture.coordinator.phase, .closed)
        XCTAssertTrue(fixture.backend.cancellations.isEmpty)
        XCTAssertEqual(fixture.backend.user?.id, accepted.user.id)
    }

    func testCloseDuringBeginRetiresReturnedBackendBeforeLatestReplacementStarts() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.backend.holdNextBegin = true
        let first = fixture.coordinator.open(readerSessionID: UUID())
        let oldPresenter = AuthenticationOwnerPresenter()
        fixture.coordinator.startGoogle(presenter: oldPresenter)
        await eventually("first begin entered") { fixture.backend.begins.count == 1 }
        let oldID = fixture.backend.begins[0].1
        fixture.coordinator.close(presentationID: first.id)
        let second = fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter())
        fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter())
        XCTAssertEqual(fixture.backend.begins.count, 1)
        fixture.backend.releaseBegin()
        await eventually("only latest replacement accepted") { fixture.accepted.count == 1 }
        XCTAssertEqual(fixture.backend.begins.map(\.0), [.google, .apple])
        XCTAssertEqual(fixture.backend.cancellations, [oldID])
        XCTAssertEqual(oldPresenter.starts, 0)
        XCTAssertEqual(fixture.accepted.first?.presentationID, second.id)
    }

    func testSwitchMethodDoesNotWaitForUncooperativeOldExchangeOrAcceptItsSuccess() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.backend.holdExchanges = true
        fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter())
        await eventually("old exchange held") {
            fixture.backend.begins.first.map { fixture.backend.hasExchange($0.1) } ?? false
        }
        let old = fixture.backend.begins[0].1
        fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter())
        await eventually("new exchange entered before old completion") {
            fixture.backend.begins.count == 2 && fixture.backend.hasExchange(fixture.backend.begins[1].1)
        }
        let current = fixture.backend.begins[1].1
        fixture.backend.releaseExchange(old, result: .success(.init(id: UUID(), email: "old@example.invalid")))
        fixture.backend.releaseExchange(current, result: .success(.init(id: UUID(), email: nil)))
        await eventually("only current accepted") { fixture.accepted.count == 1 }
        XCTAssertEqual(fixture.accepted.first?.backendAttemptID, current)
        XCTAssertEqual(fixture.backend.cancellations, [old])
    }

    func testCloseBeforeLateExchangeDeliveryRejectsSuccess() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.backend.holdExchanges = true
        let owner = fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter())
        await eventually("exchange held") {
            fixture.backend.begins.first.map { fixture.backend.hasExchange($0.1) } ?? false
        }
        let id = fixture.backend.begins[0].1
        fixture.coordinator.close(presentationID: owner.id)
        fixture.backend.releaseExchange(id, result: .success(.init(id: UUID(), email: nil)))
        await eventually("retired closed exchange") { fixture.backend.cancellations == [id] }
        XCTAssertEqual(fixture.coordinator.phase, .closed)
        XCTAssertTrue(fixture.accepted.isEmpty)
    }

    func testNewCoordinatorJoinsThePreviousPresentationPreparationBeforeBeginning() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.backend.holdNextBegin = true
        let previous = fixture.coordinator
        let first = previous.open(readerSessionID: UUID())
        previous.startGoogle(presenter: AuthenticationOwnerPresenter())
        await eventually("old coordinator entered begin") { fixture.backend.begins.count == 1 }
        let oldID = fixture.backend.begins[0].1
        previous.close(presentationID: first.id)
        previous.didDismiss(presentationID: first.id)
        let retirement = Task { await previous.waitForRetirement() }
        let replacement = AuthenticationCoordinator(backend: fixture.backend, predecessor: retirement) {
            fixture.accepted.append($0); return true
        }
        defer { replacement.invalidate() }
        let second = replacement.open(readerSessionID: UUID())
        replacement.startApple(presenter: AuthenticationOwnerPresenter())
        XCTAssertEqual(fixture.backend.begins.count, 1)
        fixture.backend.releaseBegin()
        await eventually("replacement accepted after retirement") { fixture.accepted.count == 1 }
        XCTAssertEqual(fixture.backend.begins.map(\.0), [.google, .apple])
        XCTAssertEqual(fixture.backend.cancellations, [oldID])
        XCTAssertEqual(fixture.accepted.first?.presentationID, second.id)
    }

    func testOldDismissalCannotCancelANewerPresentation() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        let first = fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.close(presentationID: first.id)
        let next = fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.showEmail()
        await eventually("new email entry") { fixture.coordinator.phase == .emailEntry(email: "", issue: nil) }
        fixture.coordinator.didDismiss(presentationID: first.id)
        XCTAssertEqual(fixture.coordinator.presentation, next)
        XCTAssertEqual(fixture.coordinator.phase, .emailEntry(email: "", issue: nil))
    }

    func testFailedPresentationFinishesAndOnlyAppleCancellationIsQuiet() async throws {
        for method in [AuthenticationCoordinator.Method.google, .apple] {
            for error in [AuthenticationPresentationError.unavailable, .cancelled, .invalidCredential] {
                let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
                fixture.coordinator.open(readerSessionID: UUID())
                let presenter = AuthenticationOwnerPresenter(); presenter.error = error
                if method == .google { fixture.coordinator.startGoogle(presenter: presenter) }
                else { fixture.coordinator.startApple(presenter: presenter) }
                await eventually("failed presenter retired") { fixture.backend.cancellations.count == 1 }
                // Apple's own Cancel is the person's choice. A Google page that closes without an answer may follow a
                // finished Google sign-in (iPad build 86), so it is never silent.
                let issue: AuthenticationCoordinator.Issue? = error == .cancelled ? (method == .google ? .googleUnfinished : nil) :
                    (error == .invalidCredential ? (method == .google ? .googleUnverified : .invalidResponse) : .presentation)
                XCTAssertEqual(fixture.coordinator.phase, .choices(issue), "\(method) \(error)")
                XCTAssertEqual(presenter.cancellations, 1)
                XCTAssertTrue(fixture.accepted.isEmpty)
            }
        }
    }

    /// TestFlight 92: a refused Google return said only "Couldn't verify the sign-in response. Please try again." It now
    /// names Google and the other ways in; an exchange the server answered badly keeps the general message.
    func testARefusedGoogleReturnSaysWhatToTry() async throws {
        let cases: [(AuthenticationCoordinator.Method, any Error, AuthenticationCoordinator.Issue)] = [
            (.google, OAuthFlowError.invalidCallback, .googleUnverified),
            (.google, AuthenticationError.invalidResponse, .invalidResponse),
            (.google, OAuthFlowError.invitationRequired, .noAccount),
            (.google, OAuthFlowError.providerDenied, .rejected),
            (.apple, OAuthFlowError.invalidCallback, .invalidResponse),
        ]
        for (method, error, expected) in cases {
            let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
            fixture.backend.holdExchanges = true
            fixture.coordinator.open(readerSessionID: UUID())
            if method == .google { fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter()) }
            else { fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter()) }
            await eventually("exchange started") { fixture.backend.begins.last.map { fixture.backend.hasExchange($0.1) } ?? false }
            fixture.backend.releaseExchange(try XCTUnwrap(fixture.backend.begins.last?.1), result: .failure(error))
            await eventually("\(method) \(error) is said") { fixture.coordinator.phase == .choices(expected) }
            XCTAssertTrue(fixture.accepted.isEmpty)
        }
        XCTAssertTrue(AuthenticationCoordinator.Issue.googleUnverified.message.contains("Try Google again, or continue with Apple or email"))
        XCTAssertTrue(AuthenticationCoordinator.Issue.invalidResponse.message.contains("still signed out"))
    }

    /// Owner report, iPad build 86: Google finished, Supabase issued a code, no exchange followed and the sheet showed
    /// its choices with no word. A cancellation the sheet didn't ask for now reads as an unfinished sign-in.
    func testCancellationUnderAnOwnedExchangeIsVisible() async throws {
        for method in [AuthenticationCoordinator.Method.google, .apple] {
            let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
            fixture.backend.holdExchanges = true
            fixture.coordinator.open(readerSessionID: UUID())
            if method == .google { fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter()) }
            else { fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter()) }
            await eventually("exchange started") { fixture.backend.begins.last.map { fixture.backend.hasExchange($0.1) } ?? false }
            let id = try XCTUnwrap(fixture.backend.begins.last?.1)
            fixture.backend.releaseExchange(id, result: .failure(CancellationError()))
            await eventually("unfinished sign-in is said") { fixture.coordinator.phase == .choices(.rejected) }
            XCTAssertTrue(fixture.accepted.isEmpty)
        }
    }

    func testLeavingAnUnansweredGooglePageSaysItDidNotFinish() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.coordinator.open(readerSessionID: UUID())
        let presenter = HeldGooglePresenter()
        fixture.coordinator.startGoogle(presenter: presenter)
        await eventually("Google page open") { fixture.coordinator.phase == .external(.google) && presenter.starts == 1 }
        fixture.coordinator.showChoices()
        await eventually("choices say Google didn't finish") { fixture.coordinator.phase == .choices(.googleUnfinished) }
        XCTAssertEqual(presenter.cancellations, 1)
        XCTAssertTrue(fixture.accepted.isEmpty)
        // Leaving before the page opened stays quiet.
        fixture.coordinator.startApple(presenter: HeldGooglePresenter())
        await eventually("Apple sheet open") { fixture.coordinator.phase == .external(.apple) }
        fixture.coordinator.showChoices()
        await eventually("quiet choices") { fixture.coordinator.phase == .choices(nil) }
    }

    func testOnlyTheSignInReturnIsTakenFromTheAppsURLHandler() {
        XCTAssertTrue(NativeAuthenticationPresenter.isAuthenticationCallback(URL(string: "sciencereader://auth/callback?code=abc")!))
        XCTAssertTrue(NativeAuthenticationPresenter.isAuthenticationCallback(URL(string: "SCIENCEREADER://AUTH/callback#error=access_denied")!))
        XCTAssertFalse(NativeAuthenticationPresenter.isAuthenticationCallback(URL(string: "sciencereader://paper/arxiv/2401.00001")!))
        XCTAssertFalse(NativeAuthenticationPresenter.isAuthenticationCallback(URL(string: "https://gradstep.ai/auth/callback?code=abc")!))
        XCTAssertFalse(NativeAuthenticationPresenter.isAuthenticationCallback(URL(string: "sciencereader://auth/callback/extra")!))
        // With no Google page open the return is consumed, never treated as a paper link, and nothing else happens.
        XCTAssertTrue(NativeAuthenticationPresenter.handleOpenedURL(URL(string: "sciencereader://auth/callback?code=abc")!))
        XCTAssertFalse(NativeAuthenticationPresenter.handleOpenedURL(URL(string: "sciencereader://paper/arxiv/2401.00001")!))
    }

    func testRejectedModelHandoffRetiresPersistedButUnacceptedSession() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.accepts = false
        fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter())
        await eventually("rejected handoff retired") { fixture.backend.cancellations.count == 1 }
        XCTAssertEqual(fixture.accepted.count, 1)
        XCTAssertEqual(fixture.coordinator.phase, .closed)
        XCTAssertNil(fixture.backend.user)
    }

    func testEmailUncertainDeliveryCorrectionAndExplicitResendRespectCapturedChallenge() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.backend.delivery = .unconfirmed
        fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.showEmail()
        await eventually("email entry ready") { fixture.coordinator.phase == .emailEntry(email: "", issue: nil) }
        fixture.coordinator.sendCode(email: "  Researcher@example.invalid \n")
        await eventually("uncertain delivery permits code entry") {
            if case .codeEntry = fixture.coordinator.phase { return true }; return false
        }
        guard case .codeEntry(let challenge) = fixture.coordinator.phase else { return XCTFail("Missing code entry") }
        XCTAssertEqual(challenge.email, "Researcher@example.invalid")
        XCTAssertEqual(challenge.delivery, .unconfirmed)
        XCTAssertEqual(fixture.coordinator.resendSecondsRemaining(), 60)
        fixture.coordinator.resendCode()
        XCTAssertEqual(fixture.backend.sends.count, 1)
        fixture.backend.nextVerificationError = .invalidCode
        fixture.coordinator.verifyCode("123456")
        await eventually("rejected code returns to its challenge") {
            if case .codeEntry(let value) = fixture.coordinator.phase { return value.issue == .invalidCode }; return false
        }
        XCTAssertEqual(fixture.backend.verifications.count, 1)
        XCTAssertEqual(fixture.backend.sends.count, 1)
        fixture.time += 60
        fixture.coordinator.resendCode()
        await eventually("explicit resend creates a new challenge") { fixture.backend.sends.count == 2 }
        await eventually("resend completed") {
            if case .codeEntry = fixture.coordinator.phase { return true }; return false
        }
        XCTAssertNotEqual(fixture.backend.sends[0], fixture.backend.sends[1])
        XCTAssertEqual(fixture.backend.cancellations, [fixture.backend.sends[0]])
        fixture.coordinator.verifyCode("654321")
        await eventually("corrected code accepted") { fixture.accepted.count == 1 }
        XCTAssertEqual(fixture.backend.verifications.last?.0, fixture.backend.sends[1])
    }

    func testChangingEmailRejectsTheOldSendAndNeverAutomaticallySendsAgain() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.backend.holdSends = true
        fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.showEmail()
        await eventually("email entry") { fixture.coordinator.phase == .emailEntry(email: "", issue: nil) }
        fixture.coordinator.sendCode(email: "old@example.invalid")
        await eventually("old send held") { fixture.backend.sends.count == 1 }
        let oldID = fixture.backend.sends[0]
        fixture.coordinator.showEmail()
        await eventually("new email entry") { fixture.coordinator.phase == .emailEntry(email: "", issue: nil) }
        fixture.backend.releaseSend(oldID, result: .success(.sent))
        fixture.coordinator.sendCode(email: "new@example.invalid")
        await eventually("new send held") { fixture.backend.sends.count == 2 }
        fixture.backend.releaseSend(fixture.backend.sends[1], result: .success(.unconfirmed))
        await eventually("new address owns code entry") {
            if case .codeEntry(let challenge) = fixture.coordinator.phase { return challenge.email == "new@example.invalid" }
            return false
        }
        XCTAssertEqual(fixture.backend.sends.count, 2)
        XCTAssertEqual(fixture.backend.cancellations, [oldID])
    }

    func testEmailRejectsNonASCIICodesAndRateLimitExtendsResendWithoutSending() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.showEmail()
        await eventually("email entry") { fixture.coordinator.phase == .emailEntry(email: "", issue: nil) }
        fixture.coordinator.sendCode(email: "fixture@example.invalid")
        await eventually("code entry") { if case .codeEntry = fixture.coordinator.phase { return true }; return false }
        fixture.coordinator.verifyCode("１２３４５６")
        XCTAssertTrue(fixture.backend.verifications.isEmpty)
        fixture.backend.nextVerificationError = .rateLimited(retryAfterSeconds: 120)
        fixture.coordinator.verifyCode("123456")
        await eventually("rate limit shown") {
            if case .codeEntry(let challenge) = fixture.coordinator.phase { return challenge.issue == .rateLimited }; return false
        }
        XCTAssertEqual(fixture.coordinator.resendSecondsRemaining(), 120)
        XCTAssertEqual(fixture.coordinator.verifySecondsRemaining(), 120)
        fixture.coordinator.verifyCode("654321")
        XCTAssertEqual(fixture.backend.verifications.count, 1)
        fixture.time += 60; fixture.coordinator.resendCode()
        XCTAssertEqual(fixture.backend.sends.count, 1)
        XCTAssertTrue(fixture.accepted.isEmpty)
        fixture.time += 60
        fixture.coordinator.verifyCode("654321")
        await eventually("explicit verification after cooldown") { fixture.accepted.count == 1 }
        XCTAssertEqual(fixture.backend.verifications.count, 2)
    }

    func testCredentialCleanupFailureStopsQueuedReplacementAndAllowsExplicitRetry() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.backend.holdExchanges = true
        fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.startGoogle(presenter: AuthenticationOwnerPresenter())
        await eventually("old exchange") {
            fixture.backend.begins.first.map { fixture.backend.hasExchange($0.1) } ?? false
        }
        fixture.backend.failNextCancellation = true
        fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter())
        await eventually("cleanup failure visible") { fixture.coordinator.phase == .choices(.credentialStorage) }
        XCTAssertEqual(fixture.backend.begins.count, 1)
        fixture.coordinator.startApple(presenter: AuthenticationOwnerPresenter())
        await eventually("explicit retry starts") { fixture.backend.begins.count == 2 }
        XCTAssertTrue(fixture.accepted.isEmpty)
    }

    func testEmailCredentialWriteFailureRequiresANewChallenge() async throws {
        let fixture = AuthenticationOwnerFixture(); defer { fixture.close() }
        fixture.coordinator.open(readerSessionID: UUID())
        fixture.coordinator.showEmail()
        await eventually("email entry") { fixture.coordinator.phase == .emailEntry(email: "", issue: nil) }
        fixture.coordinator.sendCode(email: "fixture@example.invalid")
        await eventually("code entry") { if case .codeEntry = fixture.coordinator.phase { return true }; return false }
        fixture.backend.nextVerificationError = .credentialStorage
        fixture.coordinator.verifyCode("123456")
        await eventually("failed challenge retired") { fixture.backend.cancellations.count == 1 }
        XCTAssertEqual(fixture.coordinator.phase, .emailEntry(email: "fixture@example.invalid", issue: .credentialStorage))
        fixture.coordinator.verifyCode("654321")
        XCTAssertEqual(fixture.backend.verifications.count, 1)
        fixture.coordinator.sendCode(email: "fixture@example.invalid")
        await eventually("new challenge sent") { fixture.backend.sends.count == 2 }
        XCTAssertNotEqual(fixture.backend.sends[0], fixture.backend.sends[1])
    }
}

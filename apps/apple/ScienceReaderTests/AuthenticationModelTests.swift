import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

private final class AuthenticationModelServer: @unchecked Sendable {
    let account = UUID()
    let keysArrived = XCTestExpectation(description: "key preparation reached server")
    private let lock = NSLock()
    private var heldKeys: StubProtocol?
    private var holdKeys = false
    private var failKeys = false
    private var freshAccount = false
    private var requests: [String] = []

    func configure(holdKeys: Bool = false, failKeys: Bool = false, freshAccount: Bool = false) {
        lock.withLock { self.holdKeys = holdKeys; self.failKeys = failKeys; self.freshAccount = freshAccount }
    }
    func handle(_ request: StubProtocol) {
        lock.withLock {
            let path = request.request.url!.path
            requests.append(path)
            switch path {
            case "/auth/v1/token", "/auth/v1/verify":
                request.respond(try! ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
                    expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: account, email: nil))))
            case "/auth/v1/otp", "/auth/v1/logout": request.respond(Data("{}".utf8))
            case "/rest/v1/rpc/v1_key_state":
                if holdKeys { heldKeys = request; keysArrived.fulfill() }
                else { respondKeys(request) }
            case "/rest/v1/rpc/v4_library_page":
                request.respond(Data("""
                    {"format":2,"account_id":"\(account.wire)","baseline_cursor":0,"retained_after":0,"entries":[],"next_cursor":null,"has_more":false}
                    """.utf8))
            case "/rest/v1/rpc/v4_library_changes":
                request.respond(Data("""
                    {"format":2,"account_id":"\(account.wire)","through":0,"retained_after":0,"changes":[],"next_cursor":0,"has_more":false}
                    """.utf8))
            default: request.respond(Data("[]".utf8))
            }
        }
    }
    private func respondKeys(_ request: StubProtocol) {
        if failKeys { request.respond(Data("{}".utf8), status: 503) }
        else if freshAccount { request.respond(Data("null".utf8)) }
        else { request.respond(Data(#"{"epoch":1,"recovery_package":"\\x00","device_envelope":null}"#.utf8)) }
    }
    func releaseKeys() {
        lock.withLock {
            if let heldKeys { respondKeys(heldKeys) }
            heldKeys = nil; holdKeys = false
        }
    }
    func count(_ path: String) -> Int { lock.withLock { requests.filter { $0 == path }.count } }
}

@MainActor
private final class AuthenticationModelPresenter: AuthenticationPresenting {
    func google(_ authorization: GoogleAuthorization) async throws -> URL {
        URL(string: authorization.callbackURL.absoluteString + "?code=fixture")!
    }
    func apple(_ authorization: AppleAuthorization) async throws -> String { "fixture-token" }
    func cancel() { }
}

@MainActor
private final class AuthenticationModelFixture {
    let server: AuthenticationModelServer
    let client: BackendClient
    let model: ReaderModel
    let environment: String
    let host: String
    let directory: URL
    var deviceKeyName: String { "\(environment).\(server.account.wire).device-keys" }

    init(server: AuthenticationModelServer = .init()) throws {
        self.server = server
        environment = "authentication-model-\(UUID().wire)"
        host = environment + ".invalid"
        directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent(environment)
        StubProtocol.install(host: host) { server.handle($0) }
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [StubProtocol.self]
        let configuration = BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment)
        client = try BackendClient(configuration: configuration, network: URLSession(configuration: settings))
        model = ReaderModel(configuration: configuration, client: client)
    }
    func close() async {
        await model.signOut()
        model.authenticationSheetDismissed()
        server.releaseKeys()
        await model.waitForLocalRetirement()
        StubProtocol.remove(host: host)
        for name in [environment + ".auth-session", deviceKeyName,
                     "\(environment).\(server.account.wire).support-outbox-key"] { try? KeychainVault.delete(name) }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class AuthenticationModelTests: XCTestCase {
    private func fixture(server: AuthenticationModelServer = .init()) throws -> AuthenticationModelFixture {
        let fixture = try AuthenticationModelFixture(server: server)
        addTeardownBlock { await fixture.close() }
        return fixture
    }
    private func eventually(_ description: String,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(4)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), description, file: file, line: line)
    }

    func testOpeningAndCancellingSignInPreservesGuestNavigationWithoutATypedDraft() throws {
        let model = ReaderModel(configuration: nil)
        model.openSample()
        let paper = try XCTUnwrap(model.selectedPaper?.id)
        let tab = model.tab, mode = model.wideMode
        model.openSignIn()
        model.closeSignIn(presentationID: try XCTUnwrap(model.signInPresentationID))
        model.authenticationSheetDismissed()
        XCTAssertEqual(model.selectedPaper?.id, paper)
        XCTAssertEqual(model.tab, tab)
        XCTAssertEqual(model.wideMode, mode)

        let fresh = ReaderModel(configuration: nil)
        fresh.tab = .settings
        fresh.openSignIn()
        fresh.closeSignIn(presentationID: try XCTUnwrap(fresh.signInPresentationID))
        fresh.authenticationSheetDismissed()
        XCTAssertEqual(fresh.tab, .settings)
        XCTAssertNil(fresh.selectedPaper)
    }

    func testAcceptedUUIDWithoutEmailDefersRecoveryUntilDismissAndKeepsGuestQuestion() async throws {
        let fixture = try fixture(), model = fixture.model
        model.openSample()
        model.selectionAction(.define, quote: "attention")
        let sample = model.selectedPaper?.id, draft = model.chatInput
        let id = try XCTUnwrap(model.signInPresentationID)
        let owner = try XCTUnwrap(model.authentication)
        owner.startApple(presenter: AuthenticationModelPresenter())
        await eventually("accepted account reaches recovery") { model.isSignedIn && model.needsRecovery && !model.isBusy }
        XCTAssertNil(model.email)
        XCTAssertFalse(model.librarySignInRequired)
        XCTAssertFalse(model.showSignIn)
        XCTAssertFalse(model.showRecovery, "Recovery cannot compete with the still-dismissing sign-in sheet")
        XCTAssertEqual(model.signInPresentationID, id)
        XCTAssertEqual(model.selectedPaper?.id, sample)
        XCTAssertEqual(model.chatInput, draft)
        XCTAssertEqual(model.tab, .chat)
        model.closeSignIn(presentationID: id)
        model.authenticationSheetDismissed()
        XCTAssertTrue(model.showRecovery)
        XCTAssertNil(model.signInPresentationID)
        let user = await fixture.client.currentUser()
        XCTAssertEqual(user?.id, fixture.server.account, "Accepted dismissal must not cancel the persisted session")
    }

    func testCloseRetainsGuestDraftAndBlocksNewPresentationUntilActualDismissal() async throws {
        let fixture = try fixture(), model = fixture.model
        model.chatInput = "A question to keep"
        model.openSignIn()
        let first = try XCTUnwrap(model.signInPresentationID)
        model.authentication?.showEmail()
        model.closeSignIn(presentationID: first)
        model.openSignIn()
        XCTAssertEqual(model.signInPresentationID, first)
        XCTAssertFalse(model.showSignIn)
        model.authenticationSheetDismissed()
        model.openSignIn()
        let second = try XCTUnwrap(model.signInPresentationID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.chatInput, "A question to keep")
        model.closeSignIn(presentationID: first)
        XCTAssertTrue(model.showSignIn)
        XCTAssertEqual(model.signInPresentationID, second)
    }

    func testRecoverySignOutRetainsAccountKeysAndCannotReopenFromLatePreparation() async throws {
        let server = AuthenticationModelServer(); server.configure(holdKeys: true)
        let fixture = try fixture(server: server), model = fixture.model
        model.openSignIn()
        let owner = try XCTUnwrap(model.authentication)
        owner.startGoogle(presenter: AuthenticationModelPresenter())
        await fulfillment(of: [server.keysArrived], timeout: 5)
        XCTAssertTrue(model.isSignedIn)
        let keyBytes = try XCTUnwrap(KeychainVault.read(fixture.deviceKeyName))
        let acceptedScope = model.readerSessionID
        await model.signOut()
        server.releaseKeys()
        model.authenticationSheetDismissed()
        await model.waitForLocalRetirement()
        XCTAssertNotEqual(model.readerSessionID, acceptedScope)
        XCTAssertFalse(model.isSignedIn)
        XCTAssertFalse(model.showRecovery)
        XCTAssertNil(model.accountPreparationIssue)
        XCTAssertEqual(try KeychainVault.read(fixture.deviceKeyName), keyBytes)
        XCTAssertNil(try KeychainVault.read(fixture.environment + ".auth-session"))
    }

    func testAccountPreparationFailureOffersRetryWithoutBootstrappingFreshKeys() async throws {
        let server = AuthenticationModelServer(); server.configure(failKeys: true)
        let fixture = try fixture(server: server), model = fixture.model
        model.openSignIn()
        try XCTUnwrap(model.authentication).startApple(presenter: AuthenticationModelPresenter())
        await eventually("preparation failure shown") { model.accountPreparationIssue != nil && !model.isBusy }
        XCTAssertTrue(model.isSignedIn)
        XCTAssertFalse(model.showRecovery)
        let keyBytes = try XCTUnwrap(KeychainVault.read(fixture.deviceKeyName))
        model.authenticationSheetDismissed()
        XCTAssertTrue(model.showRecovery)
        server.configure()
        await model.retryAccountPreparation()
        XCTAssertNil(model.accountPreparationIssue)
        XCTAssertTrue(model.needsRecovery)
        XCTAssertEqual(try KeychainVault.read(fixture.deviceKeyName), keyBytes)
        XCTAssertEqual(server.count("/rest/v1/rpc/v1_bootstrap_keys"), 0)
        XCTAssertEqual(server.count("/rest/v1/rpc/v1_key_state"), 2)
    }

    func testNewAccountRecoveryCodeSurvivesSignOutAndSameAccountReturn() async throws {
        let server = AuthenticationModelServer(); server.configure(freshAccount: true)
        let fixture = try fixture(server: server), model = fixture.model
        model.openSignIn()
        try XCTUnwrap(model.authentication).startApple(presenter: AuthenticationModelPresenter())
        await eventually("new recovery code prepared") { model.recoveryCode != nil && !model.isBusy }
        let code = try XCTUnwrap(model.recoveryCode)
        let saved = try XCTUnwrap(KeychainVault.read(fixture.deviceKeyName))
        model.authenticationSheetDismissed()
        await model.signOut()
        model.openSignIn()
        try XCTUnwrap(model.authentication).startGoogle(presenter: AuthenticationModelPresenter())
        await eventually("returning account reconciles the same code") { model.recoveryCode != nil && !model.isBusy }
        XCTAssertEqual(model.recoveryCode, code)
        XCTAssertEqual(try KeychainVault.read(fixture.deviceKeyName), saved)
        XCTAssertEqual(server.count("/rest/v1/rpc/v1_bootstrap_keys"), 0)
    }
}

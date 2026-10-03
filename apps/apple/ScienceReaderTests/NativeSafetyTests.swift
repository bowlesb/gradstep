import CryptoKit
import Foundation
import ImageIO
import ScienceReaderCore
import UIKit
import XCTest
@testable import ScienceReader

final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (StubProtocol) -> Void
    private static let mutex = NSLock()
    nonisolated(unsafe) private static var routes: [String: Handler] = [:]
    static func install(host: String, handler: @escaping Handler) { mutex.withLock { routes[host] = handler } }
    static func remove(host: String) { _ = mutex.withLock { routes.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let route = Self.mutex.withLock({ Self.routes[host] }) else { return }
        route(self)
    }
    override func stopLoading() { }
    func respond(_ data: Data, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class Scenario: @unchecked Sendable {
    private let lock = NSLock()
    var firstID = UUID()
    var secondID = UUID()
    private var loginCount = 0
    private var refreshCount = 0
    private var pending: StubProtocol?
    private var newDevice: UUID?
    private var envelope: String?
    private var enrollmentIDs: [UUID] = []
    private var failApprovalRead = true
    var holdRefresh = false
    var holdRead = false
    var recoveryPackage: String?
    var recoveryEpoch = 1
    let arrived: XCTestExpectation
    init(arrived: XCTestExpectation) { self.arrived = arrived }

    func handle(_ request: StubProtocol) {
        // URLProtocol delivers requests off the main actor. Serialize the test
        // server state; perform only deterministic fixture work under this lock.
        lock.withLock {
            let url = request.request.url!
            if url.path == "/auth/v1/token" {
                if url.query?.contains("refresh_token") == true {
                    refreshCount += 1; pending = request; arrived.fulfill()
                    if !holdRefresh { request.respond(session(id: firstID)); pending = nil }
                } else {
                    loginCount += 1
                    request.respond(session(id: loginCount == 1 ? firstID : secondID, expired: holdRefresh && loginCount == 1))
                }
            } else if url.path == "/auth/v1/logout" { request.respond(Data("{}".utf8)) }
            else if url.path.hasSuffix("v1_library") {
                if holdRead { pending = request; arrived.fulfill() }
                else { request.respond(Data("{}".utf8)) }
            } else if url.path.hasSuffix("v1_key_state") {
                guard let recoveryPackage else { request.respond(Data("null".utf8)); return }
                if envelope != nil && failApprovalRead {
                    failApprovalRead = false; request.respond(Data("{}".utf8), status: 503); return
                }
                let payload = body(request.request)
                let requested = (payload["p_device_id"] as? String)?.lowercased()
                let value: [String: Any] = ["epoch": recoveryEpoch, "recovery_package": recoveryPackage, "device_envelope": requested == newDevice?.wire ? (envelope as Any? ?? NSNull()) : NSNull()]
                request.respond(try! JSONSerialization.data(withJSONObject: value))
            } else if url.path.hasSuffix("v1_request_enrollment") {
                let payload = body(request.request)
                newDevice = UUID(uuidString: payload["p_device_id"] as! String)
                let id = UUID(uuidString: payload["p_request_id"] as! String)!
                enrollmentIDs.append(id)
                request.respond(try! JSONEncoder().encode(id))
            } else if url.path.hasSuffix("v1_enrollment_requests") {
                request.respond(try! JSONEncoder().encode(enrollmentIDs.map { ["id": $0.wire] }))
            } else if url.path.hasSuffix("v1_devices") {
                request.respond(Data("[]".utf8))
            } else if url.path.hasSuffix("v1_acknowledge_cursor") || url.path.hasSuffix("v1_set_report_status") {
                request.respond(Data(), status: 204)
            } else if url.path.hasSuffix("v1_approve_enrollment") {
                envelope = body(request.request)["p_envelope"] as? String
                // Simulate a server commit whose success response is lost.
                request.respond(Data("{}".utf8), status: 503)
            } else { request.respond(Data("{}".utf8), status: 404) }
        }
    }
    private func body(_ request: URLRequest) -> [String: Any] {
        let data: Data
        if let bytes = request.httpBody { data = bytes }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096); var bytes = Data()
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            data = bytes
        } else { data = Data() }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func session(id: UUID, expired: Bool = false) -> Data {
        try! ReaderCrypto.encode(AuthSession(access_token: "fixture-access-\(id.wire)", refresh_token: "fixture-refresh-\(id.wire)",
            expires_at: expired ? 0 : Date().timeIntervalSince1970 + 3600, user: .init(id: id, email: "fixture@example.invalid")))
    }
    func finishRefresh() { lock.withLock { pending?.respond(session(id: firstID)); pending = nil } }
    func finishRead(_ data: Data = Data("{}".utf8)) { lock.withLock { pending?.respond(data); pending = nil } }
    func refreshes() -> Int { lock.withLock { refreshCount } }
}

@MainActor
final class NativeSafetyTests: XCTestCase {
    func testEncryptedSQLiteHistoryWorksInTheAppSandbox() async throws {
        try await verifyLocalStore(checkProtection: false)
    }

    func testPhysicalDeviceProtectionForDatabaseAndJournal() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator returns no file protection class. Run this check on a passcode-protected physical device.")
        #else
        try await verifyLocalStore(checkProtection: true)
        #endif
    }

    private func verifyLocalStore(checkProtection: Bool) async throws {
        let account = UUID(), device = UUID(), bundle = KeyBundle.generate(accountID: account)
        let vault = "test-local-store-\(account.wire)"
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(vault, isDirectory: true)
        defer { try? KeychainVault.delete(vault); try? FileManager.default.removeItem(at: directory) }
        try KeychainVault.write(ReaderCrypto.randomKey(), name: vault)
        let key = try XCTUnwrap(KeychainVault.read(vault)), path = directory.appendingPathComponent("state.sqlite")
        let store = try EncryptedStore(url: path, accountID: account, localKey: key, keys: bundle)
        let pending = try await store.append(PrivateEvent(kind: .note, text: "PRIVATE-IOS-LOCAL-STORE-CHECK"), deviceID: device)
        let reopened = try EncryptedStore(url: path, accountID: account, localKey: key, keys: bundle)
        let recovered = await reopened.pending(); XCTAssertEqual(recovered, [pending])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(Set(files.map(\.lastPathComponent)).isSuperset(of: ["state.sqlite", "state.sqlite-wal", "state.sqlite-shm"]))
        for file in files {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data("PRIVATE-IOS-LOCAL-STORE-CHECK".utf8)))
            if checkProtection {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? (attributes[.protectionKey] as? String)
                if file.lastPathComponent == "state.sqlite-shm" {
                    // SQLite's mapped coordination index contains no database
                    // content. Apple gives it a mapping-safe protection class;
                    // forcing Complete can cause SIGBUS when the phone locks.
                    // https://www.sqlite.org/walformat.html
                    // https://bugs.webkit.org/show_bug.cgi?id=197390
                    XCTAssertTrue([FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
                                   FileProtectionType.completeUnlessOpen.rawValue].contains(protection ?? ""),
                                  "Mapping-safe protection for the SQLite coordination index")
                } else {
                    XCTAssertEqual(protection, FileProtectionType.complete.rawValue, "Protection class for \(file.lastPathComponent)")
                }
            }
        }
        XCTAssertTrue(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    func testPaperAndGeneralChatsKeepTheirOwnDraftAndConversation() {
        let model = ReaderModel(configuration: nil)
        model.openSample(); let paper = model.selectedPaper!
        let paperChat = UUID(), generalChat = UUID()
        model.activeConversation = paperChat; model.chatInput = "Paper draft"
        model.generalChat = true; model.activeConversation = generalChat; model.chatInput = "General draft"
        model.select(paper)
        XCTAssertEqual(model.activeConversation, paperChat); XCTAssertEqual(model.chatInput, "Paper draft")
        model.generalChat = true
        XCTAssertEqual(model.activeConversation, generalChat); XCTAssertEqual(model.chatInput, "General draft")
        model.newChat(general: false)
        XCTAssertNil(model.activeConversation); XCTAssertEqual(model.chatInput, "")
        model.generalChat = true
        XCTAssertEqual(model.activeConversation, generalChat); XCTAssertEqual(model.chatInput, "General draft")
    }

    func testOpeningHistoryRestoresItsPaperContext() throws {
        let model = ReaderModel(configuration: nil)
        model.openSample(); let paper = model.selectedPaper!, conversation = UUID()
        try model.privateState.apply(AppliedEvent(id: UUID(), deviceID: UUID(), payload: PrivateEvent(kind: .conversation, entityID: conversation, documentID: paper.id, text: "A paper question")))
        model.generalChat = true
        model.openConversation(conversation)
        XCTAssertEqual(model.activeConversation, conversation); XCTAssertFalse(model.generalChat)
        XCTAssertEqual(model.chatPaperID, paper.id); XCTAssertEqual(model.selectedPaper?.id, paper.id)
    }

    private func client(_ scenario: Scenario) throws -> (BackendClient, String, String) {
        let environment = "unit-\(UUID().wire)"; let host = environment + ".invalid"
        StubProtocol.install(host: host) { scenario.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let network = URLSession(configuration: configuration)
        let client = try BackendClient(configuration: BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment), network: network)
        return (client, environment, host)
    }

    func testVoidAcknowledgmentsAndMissingTypedResponsesAreDistinct() async throws {
        let scenario = Scenario(arrived: XCTestExpectation(description: "unused"))
        let (client, environment, host) = try client(scenario)
        defer { StubProtocol.remove(host: host); try? KeychainVault.delete(environment + ".auth-session") }
        _ = try await client.signIn(email: "fixture", password: "fixture")
        try await client.rpcVoid("v1_acknowledge_cursor", params: EmptyResponse(), accountID: scenario.firstID)
        try await client.rpcVoid("v1_set_report_status", params: EmptyResponse(), accountID: scenario.firstID)
        do {
            let _: DeviceKeys.KeyState? = try await client.rpc("v1_acknowledge_cursor", params: EmptyResponse(), accountID: scenario.firstID)
            XCTFail("An empty typed response cannot silently decode as a missing keyring")
        } catch is DecodingError { }
        let absent: DeviceKeys.KeyState? = try await client.rpc("v1_key_state", params: EmptyResponse(), accountID: scenario.firstID)
        XCTAssertNil(absent)
        do {
            try await client.rpcVoid("v1_library", params: EmptyResponse(), accountID: scenario.firstID)
            XCTFail("A structured response is not a void acknowledgment")
        } catch ReaderError.corruptData { }
    }

    func testLateRefreshCannotRestoreSignedOutSession() async throws {
        let arrived = expectation(description: "refresh waiting"); let scenario = Scenario(arrived: arrived); scenario.holdRefresh = true
        let (client, environment, host) = try client(scenario)
        defer { StubProtocol.remove(host: host); try? KeychainVault.delete(environment + ".auth-session") }
        _ = try await client.signIn(email: "fixture", password: "fixture")
        let request = Task { let _: EmptyResponse = try await client.rpc("v1_library", params: EmptyResponse(), accountID: scenario.firstID) }
        await fulfillment(of: [arrived], timeout: 5)
        try await client.signOut(); scenario.finishRefresh()
        if case .success = await request.result { XCTFail("An old request must not succeed after sign-out") }
        let user = await client.currentUser(); XCTAssertNil(user)
        XCTAssertNil(try KeychainVault.read(environment + ".auth-session"))
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        let arrived = expectation(description: "one refresh"); let scenario = Scenario(arrived: arrived); scenario.holdRefresh = true
        let (client, environment, host) = try client(scenario)
        defer { StubProtocol.remove(host: host); try? KeychainVault.delete(environment + ".auth-session") }
        _ = try await client.signIn(email: "fixture", password: "fixture")
        let first = Task { let _: EmptyResponse = try await client.rpc("v1_library", params: EmptyResponse(), accountID: scenario.firstID) }
        let second = Task { let _: EmptyResponse = try await client.rpc("v1_library", params: EmptyResponse(), accountID: scenario.firstID) }
        await fulfillment(of: [arrived], timeout: 5); scenario.finishRefresh()
        try await first.value; try await second.value
        XCTAssertEqual(scenario.refreshes(), 1)
    }

    func testAccountChangeRejectsOldReadAndOldOutboxActor() async throws {
        let arrived = expectation(description: "read waiting"); let scenario = Scenario(arrived: arrived); scenario.holdRead = true
        let (client, environment, host) = try client(scenario)
        defer { StubProtocol.remove(host: host); try? KeychainVault.delete(environment + ".auth-session") }
        _ = try await client.signIn(email: "first", password: "fixture")
        let request = Task { let _: EmptyResponse = try await client.rpc("v1_library", params: EmptyResponse(), accountID: scenario.firstID) }
        await fulfillment(of: [arrived], timeout: 5)
        _ = try await client.signIn(email: "second", password: "fixture"); scenario.finishRead()
        if case .success = await request.result { XCTFail("The previous account's response must be discarded") }
        do { let _: EmptyResponse = try await client.rpc("v1_library", params: EmptyResponse(), accountID: scenario.firstID); XCTFail("Old outbox actor must be rejected before sending") }
        catch BackendError.signInRequired { }
        let user = await client.currentUser(); XCTAssertEqual(user?.id, scenario.secondID)
    }

    func testModelDiscardsLateLibraryAndRecoveryUIAfterSignOut() async throws {
        let arrived = expectation(description: "model library waiting"), scenario = Scenario(arrived: arrived)
        scenario.holdRead = true
        let (client, environment, host) = try client(scenario)
        let configuration = BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment)
        let vault = "\(environment).\(scenario.firstID.wire)"
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(environment)
        defer {
            StubProtocol.remove(host: host)
            for key in [environment + ".auth-session", vault + ".device-keys", vault + ".support-outbox-key"] { try? KeychainVault.delete(key) }
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try await client.signIn(email: "fixture", password: "fixture")
        let model = ReaderModel(configuration: configuration, client: client)
        let starting = Task { await model.start() }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertTrue(model.showRecovery)
        model.chatInput = "The previous account's draft"
        await model.signOut()
        scenario.finishRead(Data("[{\"document_id\":\"aaaaaaaa-0000-4000-8000-000000000001\",\"title\":\"Old account library entry\"}]".utf8))
        await starting.value
        XCTAssertNil(model.email); XCTAssertNil(model.recoveryCode); XCTAssertFalse(model.showRecovery)
        XCTAssertTrue(model.papers.isEmpty); XCTAssertTrue(model.privateState.events.isEmpty); XCTAssertEqual(model.chatInput, "")
        XCTAssertNil(model.error)
    }

    func testRecoveryResumesCommittedEnrollmentAndPreservesLocalStoreKey() async throws {
        let scenario = Scenario(arrived: XCTestExpectation(description: "unused"))
        let account = scenario.firstID, bundle = KeyBundle.generate(accountID: scenario.firstID), code = ReaderCrypto.recoveryCode()
        scenario.recoveryPackage = DeviceKeys.hex(try ReaderCrypto.wrapRecovery(bundle, code: code))
        let (client, environment, host) = try client(scenario)
        let vault = "\(environment).\(account.wire).device-keys"
        defer { StubProtocol.remove(host: host); try? KeychainVault.delete(environment + ".auth-session"); try? KeychainVault.delete(vault); try? KeychainVault.delete(vault + ".pending-enrollment") }
        _ = try await client.signIn(email: "fixture", password: "fixture")
        let original = LocalDevice.create(accountID: account)
        try KeychainVault.write(ReaderCrypto.encode(original), name: vault)
        let manager = try DeviceKeys(backend: client, accountID: account, environment: environment)
        do { _ = try await manager.recover(code: code); XCTFail("The simulated response must fail") } catch { }
        XCTAssertNotNil(try KeychainVault.read(vault + ".pending-enrollment"))
        let restarted = try DeviceKeys(backend: client, accountID: account, environment: environment)
        guard case .ready(let enrolled) = try await restarted.prepare() else { return XCTFail("Committed enrollment must resume") }
        XCTAssertEqual(enrolled.localStoreKey, original.localStoreKey)
        XCTAssertNotEqual(enrolled.deviceID, original.deviceID)
        XCTAssertEqual(enrolled.bundle, bundle)
        XCTAssertNil(try KeychainVault.read(vault + ".pending-enrollment"))
    }

    func testRedactionAndCropAreFlattenedIntoUploadedPixels() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let original = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.red.setFill(); context.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
        }
        let result = try ScreenshotCapture.prepare(original, redactions: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)], crop: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let source = CGImageSourceCreateWithData(result.attachment.bytes as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(decoded.width, 80); XCTAssertEqual(decoded.height, 80)
        var pixels = [UInt8](repeating: 0, count: 80 * 80 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        XCTAssertEqual(Array(pixels[(40 * 80 + 40) * 4..<(40 * 80 + 40) * 4 + 4]), [0,0,0,255])
        XCTAssertEqual(Array(pixels[0..<4]), [255,255,255,255])
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary as String])
    }
}

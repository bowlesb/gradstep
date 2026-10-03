import Foundation
import ScienceReaderCore
import UIKit
import XCTest
@testable import ScienceReader

@MainActor
final class LiveSupportTests: XCTestCase {
    func testPrivateReportRoundTripAgainstStaging() async throws {
        let variables = ProcessInfo.processInfo.environment
        guard let email = variables["SCIENCE_READER_LIVE_EMAIL"], let password = variables["SCIENCE_READER_LIVE_PASSWORD"],
              let expected = variables["SCIENCE_READER_LIVE_ACCOUNT"], let accountID = UUID(uuidString: expected) else {
            throw XCTSkip("Run scripts/check-native-support.mjs for the disposable hosted fixture.")
        }
        guard let bundled = BackendConfiguration.bundled(), bundled.url.host == "coxhjvqpflgxkleydati.supabase.co" else { return XCTFail("Staging configuration is required") }
        let environment = "unit-live-\(UUID().wire)"
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        defer {
            try? KeychainVault.delete(environment + ".auth-session")
            try? KeychainVault.delete("\(environment).\(accountID.wire).support-outbox-key")
            try? FileManager.default.removeItem(at: root.appendingPathComponent(environment, isDirectory: true))
        }
        let backend = try BackendClient(configuration: BackendConfiguration(url: bundled.url, anonKey: bundled.anonKey, environment: environment))
        let user = try await backend.signIn(email: email, password: password)
        XCTAssertEqual(user.id, accountID)
        let service = try SupportService(accountID: accountID, environment: environment, backend: backend)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 10, y: 10, width: 80, height: 80))
        }
        let prepared = try ScreenshotCapture.prepare(image, redactions: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)])
        let id = UUID()
        let draft = SupportDraft(id: id, accountID: accountID, reportID: id, action: .report, text: "Synthetic native integration check; no user content.",
            title: "Native support fixture", appVersion: "test", build: "test", osVersion: "simulator", screen: "test", image: prepared.attachment)
        try await service.queue(draft); await service.refresh()
        XCTAssertTrue(service.waiting.isEmpty, "Report must leave the encrypted outbox after confirmed receipt")
        XCTAssertNil(service.error)
        XCTAssertTrue(service.reports.contains { $0.id == id })
        let first = try await service.thread(id)
        XCTAssertEqual(first.attachments.count, 1)
        let stored = try await service.image(prepared.attachment.id)
        XCTAssertEqual(stored, prepared.attachment.bytes)

        // Replay the exact operations after acknowledgment, as if the process
        // restarted between server commit and local removal of the outbox entry.
        try await service.queue(draft); await service.flush()
        let reply = SupportDraft(accountID: accountID, reportID: id, action: .reply, text: "Synthetic native reply")
        try await service.queue(reply); await service.flush()
        try await service.queue(reply); await service.flush()
        let final = try await service.thread(id)
        XCTAssertEqual(final.attachments.count, 1)
        XCTAssertEqual(final.messages.count, 1)
        XCTAssertTrue(service.waiting.isEmpty)
        service.cancel(); try await backend.signOut()
    }
}

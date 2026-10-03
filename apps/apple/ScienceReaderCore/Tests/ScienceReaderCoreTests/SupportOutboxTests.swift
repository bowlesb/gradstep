import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct SupportOutboxTests {
    @Test func offlineReportKeepsIdentityAndPrivateBytesAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), id = UUID(), key = ReaderCrypto.randomKey()
        let draft = SupportDraft(id: id, accountID: account, reportID: id, action: .report, text: "PRIVATE-REPORT-NOTE", title: "Equation issue",
                                 appVersion: "1", build: "2", osVersion: "test", screen: "paper", image: ReportImage(bytes: Data("PRIVATE-PIXELS".utf8), mediaType: "image/png"))
        let first = try SupportOutbox(directory: directory, accountID: account, key: key)
        try await first.enqueue(draft); try await first.enqueue(draft)
        let disk = try Data(contentsOf: directory.appendingPathComponent(id.wire + ".enc"))
        #expect(disk.range(of: Data("PRIVATE-REPORT-NOTE".utf8)) == nil)
        #expect(disk.range(of: Data("PRIVATE-PIXELS".utf8)) == nil)
        let restarted = try SupportOutbox(directory: directory, accountID: account, key: key)
        #expect(try await restarted.pending() == [draft])
        let wrongAccount = try SupportOutbox(directory: directory, accountID: UUID(), key: key)
        await #expect(throws: (any Error).self) { try await wrongAccount.pending() }
        try await restarted.acknowledge(draft)
        #expect(try await restarted.pending().isEmpty)
    }

    @Test func corruptedDraftIsPreservedAndNeverSentAsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = ReaderCrypto.randomKey()
        let draft = SupportDraft(accountID: account, reportID: UUID(), action: .reply, text: "Do not lose this")
        let box = try SupportOutbox(directory: directory, accountID: account, key: key)
        try await box.enqueue(draft)
        let url = directory.appendingPathComponent(draft.id.wire + ".enc")
        var bytes = try Data(contentsOf: url); bytes[bytes.count - 1] ^= 1; try bytes.write(to: url)
        await #expect(throws: (any Error).self) { try await box.pending() }
        #expect(try Data(contentsOf: url) == bytes)
    }
}

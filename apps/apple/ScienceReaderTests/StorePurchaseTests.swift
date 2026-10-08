import Foundation
import XCTest
@testable import ScienceReader

private final class RecordingStoreTransport: StoreSyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]] = []
    private let answer: @Sendable (String) -> StoreSyncResult
    private let failing: Bool
    init(failing: Bool = false, answer: @escaping @Sendable (String) -> StoreSyncResult) { self.failing = failing; self.answer = answer }
    var sent: [[String]] { lock.withLock { batches } }
    func syncStoreTransactions(_ signed: [String], accountID: UUID) async throws -> [StoreSyncResult] {
        lock.withLock { batches.append(signed) }
        if failing { throw BackendError.transport }
        return signed.map(answer)
    }
}

private final class FinishLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UInt64] = []
    var finished: [UInt64] { lock.withLock { ids } }
    func pending(_ id: UInt64) -> PendingStoreTransaction {
        PendingStoreTransaction(id: id, signed: "jws-\(id)", finish: { [self] in lock.withLock { ids.append(id) } })
    }
}

final class StorePurchaseTests: XCTestCase {
    private let account = UUID(uuidString: "18000000-0000-0000-0000-00000000000a")!

    func testOnlyFinalOutcomesFinishTheirTransactions() async throws {
        let outcomes = ["jws-1": "recorded", "jws-2": "already_recorded", "jws-3": "linked_to_another_account", "jws-4": "invalid",
                        "jws-5": "updated", "jws-6": "environment_unavailable", "jws-7": "account_closed"]
        let transport = RecordingStoreTransport { StoreSyncResult(outcome: outcomes[$0]!, credits: nil) }
        let log = FinishLog()
        let results = try await StoreSync.report((1...7).map(log.pending), accountID: account, transport: transport)
        XCTAssertEqual(results.map(\.outcome), (1...7).map { outcomes["jws-\($0)"]! })
        XCTAssertEqual(log.finished, [1, 2, 5], "Unconfirmed purchases stay unfinished so StoreKit offers them again")
    }

    func testNothingFinishesWhenTheServerIsUnreachable() async {
        let transport = RecordingStoreTransport(failing: true) { _ in StoreSyncResult(outcome: "recorded", credits: 800) }
        let log = FinishLog()
        do { _ = try await StoreSync.report([log.pending(1)], accountID: account, transport: transport); XCTFail("expected failure") }
        catch {}
        XCTAssertTrue(log.finished.isEmpty)
    }

    func testDuplicatesAreSentOnceAndLargeSetsAreBatched() async throws {
        let transport = RecordingStoreTransport { _ in StoreSyncResult(outcome: "recorded", credits: 0) }
        let log = FinishLog()
        let pending = (1...30).map(log.pending) + [log.pending(3), log.pending(4)]
        _ = try await StoreSync.report(pending, accountID: account, transport: transport)
        XCTAssertEqual(transport.sent.map(\.count), [25, 5])
        XCTAssertEqual(Set(transport.sent.flatMap { $0 }).count, 30)
        XCTAssertEqual(log.finished.count, 30)
    }

    func testAMismatchedAnswerFinishesNothing() async {
        final class ShortTransport: StoreSyncTransport, @unchecked Sendable {
            func syncStoreTransactions(_ signed: [String], accountID: UUID) async throws -> [StoreSyncResult] { [StoreSyncResult(outcome: "recorded", credits: 1)] }
        }
        let log = FinishLog()
        do { _ = try await StoreSync.report([log.pending(1), log.pending(2)], accountID: account, transport: ShortTransport()); XCTFail("expected failure") }
        catch {}
        XCTAssertTrue(log.finished.isEmpty)
    }

    func testPurchaseMessagesAndSummaryDecoding() throws {
        XCTAssertEqual(StoreSync.message(for: StoreSyncResult(outcome: "recorded", credits: 800)), "Added 800 credits.")
        XCTAssertEqual(StoreSync.message(for: StoreSyncResult(outcome: "already_recorded", credits: nil)), "Your purchase is active.")
        XCTAssertTrue(StoreSync.message(for: StoreSyncResult(outcome: "linked_to_another_account", credits: nil)).contains("another account"))
        XCTAssertTrue(StoreSync.message(for: nil).contains("try again automatically"))
        XCTAssertTrue(StoreSync.message(for: StoreSyncResult(outcome: "verification_unavailable", credits: nil)).contains("try again automatically"))
        for outcome in ["invalid", "environment_unavailable", "unsupported", "unknown_product", "unrecognized"] {
            let message = StoreSync.message(for: StoreSyncResult(outcome: outcome, credits: nil))
            XCTAssertFalse(message.contains("try again automatically"), "A refusal must not promise automatic recovery")
            XCTAssertFalse(message.contains("went through"))
            XCTAssertTrue(message.contains("report"))
        }
        XCTAssertTrue(StoreSync.message(for: StoreSyncResult(outcome: "invalid", credits: nil)).contains("Restore purchases"))
        let summary = try JSONDecoder().decode(StoreSummary.self, from: Data(#"{"plan":"pro","product_id":"com.sciencereader.ios.pro.monthly","expires_at":"2026-11-05T16:12:03.123456+00:00"}"#.utf8))
        XCTAssertEqual(summary.planName, "Pro")
        XCTAssertEqual(summary.expiresAt, ISO8601DateFormatter().date(from: "2026-11-05T16:12:03Z"))
        XCTAssertNil(try JSONDecoder().decode(StoreSummary.self, from: Data(#"{"plan":null}"#.utf8)).planName)
    }
}

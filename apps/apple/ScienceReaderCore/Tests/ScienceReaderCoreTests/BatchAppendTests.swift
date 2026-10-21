import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct BatchAppendTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        let account = UUID(), device = UUID(), localKey = ReaderCrypto.randomKey()
        let keys: KeyBundle
        let store: EncryptedStore
        var url: URL { directory.appendingPathComponent("state.sqlite") }

        init() throws {
            keys = KeyBundle.generate(accountID: account)
            store = try EncryptedStore(url: directory.appendingPathComponent("state.sqlite"), accountID: account, localKey: localKey, keys: keys)
        }

        func reopen(keys: KeyBundle? = nil) throws -> EncryptedStore {
            try EncryptedStore(url: url, accountID: account, localKey: localKey, keys: keys ?? self.keys)
        }
    }

    private func firstTurn() -> [(id: UUID, event: PrivateEvent)] {
        let conversation = UUID(), root = UUID()
        return [
            (root, PrivateEvent(kind: .conversation, entityID: conversation, text: "A saved question")),
            (UUID(), PrivateEvent(kind: .message, parents: [root], conversationID: conversation, text: "How does attention work?", role: .user, status: .complete))
        ]
    }

    @Test func firstTurnAndExactRetriesSurviveRestartAsOneConversation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let turn = firstTurn()
        let saved = try await fixture.store.appendBatch(turn, deviceID: fixture.device)
        #expect(saved.map(\.id) == turn.map(\.id))
        let reopened = try fixture.reopen()
        let state = await reopened.state()
        let branches = state.conversationBranches(turn[0].event.entityID)
        #expect(state.events.count == 2)
        #expect(branches.count == 1 && branches[0].complete)
        #expect(branches[0].messages.map(\.id) == [turn[1].id])
        #expect(await reopened.pending() == saved)
        try await reopened.acknowledge(saved[0])
        #expect(try await reopened.appendBatch(turn, deviceID: fixture.device) == saved)
        #expect(await reopened.pending() == [saved[1]])

        let child = (id: UUID(), event: PrivateEvent(kind: .message, parents: [saved[1].id], conversationID: turn[0].event.entityID,
                                                    text: "And multi-head attention?", role: .user, status: .complete))
        let extended = try await reopened.appendBatch([turn[1], child], deviceID: fixture.device)
        #expect(extended[0] == saved[1])
        let final = try fixture.reopen()
        #expect(await final.pending() == extended)
        #expect(await final.state().events.count == 3)
        #expect(await final.state().conversationBranches(turn[0].event.entityID).first?.messages.map(\.id) == [turn[1].id, child.id])
    }

    @Test func invalidSecondEventCannotLeaveAnOrphanConversation() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var turn = firstTurn()
        turn[1].event.role = nil
        await #expect(throws: ReaderError.invalidEvent) { try await fixture.store.appendBatch(turn, deviceID: fixture.device) }
        #expect(await fixture.store.state().events.isEmpty)
        #expect(await fixture.store.pending().isEmpty)
        let reopened = try fixture.reopen()
        #expect(await reopened.state().events.isEmpty)
        #expect(await reopened.pending().isEmpty)
    }

    @Test func failureDuringSecondInsertRollsBackBothRecordsAndOutbox() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let turn = firstTurn(), database = try SQLiteConnection(url: fixture.url)
        try database.execute("CREATE TRIGGER interrupt_turn BEFORE INSERT ON records WHEN NEW.ordinal=2 BEGIN SELECT RAISE(ABORT,'synthetic_turn_failure'); END;")
        await #expect(throws: (any Error).self) { try await fixture.store.appendBatch(turn, deviceID: fixture.device) }
        #expect(await fixture.store.state().events.isEmpty)
        #expect(await fixture.store.pending().isEmpty)
        let reopened = try fixture.reopen()
        #expect(await reopened.state().events.isEmpty)
        #expect(await reopened.pending().isEmpty)
        try database.execute("DROP TRIGGER interrupt_turn")
        let saved = try await reopened.appendBatch(turn, deviceID: fixture.device)
        let final = try fixture.reopen()
        #expect(await final.pending() == saved)
        #expect(await final.state().events.count == 2)
    }

    @Test func conflictingRetryAndStaleWriterCannotPublishPartialBatches() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let stale = fixture.store, current = try fixture.reopen(), turn = firstTurn()
        let saved = try await current.appendBatch(turn, deviceID: fixture.device)
        let newNote = (id: UUID(), event: PrivateEvent(kind: .note, text: "Must not leak from failed batch"))
        var changed = turn[1]; changed.event.text = "A different question under the same ID"
        await #expect(throws: ReaderError.eventConflict) {
            try await current.appendBatch([newNote, changed], deviceID: fixture.device)
        }
        #expect(await current.pending() == saved)
        #expect(await current.state().events.count == 2)
        await #expect(throws: ReaderError.storeChanged) { try await stale.appendBatch(firstTurn(), deviceID: fixture.device) }
        #expect(await stale.pending().isEmpty)
        #expect(await stale.state().events.isEmpty)
        let reopened = try fixture.reopen()
        #expect(await reopened.pending() == saved)
        #expect(await reopened.state().events.count == 2)
    }

    @Test func originalBatchIDsResolveToExactRebasedEnvelopes() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let turn = firstTurn()
        try await fixture.store.appendBatch(turn, deviceID: fixture.device)
        var keys = fixture.keys; try keys.rotate()
        try await fixture.store.updateKeys(keys)
        let currentDevice = UUID()
        let mapping = try await fixture.store.rebasePendingAfterCatchUp(deviceID: currentDevice, verifiedEpoch: keys.epoch, cursor: 0)
        let rebased = await fixture.store.pending()
        #expect(rebased.map(\.id) == turn.map { mapping[$0.id]! })
        let reopened = try fixture.reopen(keys: keys)
        #expect(try await reopened.appendBatch(turn, deviceID: fixture.device) == rebased)
        #expect(await reopened.pending() == rebased)
        #expect(await reopened.state().events.count == 2)
        await #expect(throws: ReaderError.invalidEvent) {
            try await reopened.appendBatch([turn[0], (rebased[0].id, turn[0].event)], deviceID: currentDevice)
        }
    }

    @Test func invalidBatchSizeDuplicateIDsAndForwardParentsAreRejected() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let turn = firstTurn()
        let oversized = (0..<201).map { _ in (id: UUID(), event: PrivateEvent(kind: .note, text: "Bounded input")) }
        for invalid in [[], [turn[0], turn[0]], [turn[1], turn[0]], oversized] {
            await #expect(throws: ReaderError.invalidEvent) { try await fixture.store.appendBatch(invalid, deviceID: fixture.device) }
        }
        #expect(await fixture.store.pending().isEmpty)
        let reopened = try fixture.reopen()
        #expect(await reopened.state().events.isEmpty)
    }

    @Test func countCapacityIsCheckedForTheWholeBatchAndDoesNotChargeRetries() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for count in [200, 200, 200, 200, 198] {
            let batch = (0..<count).map { _ in (id: UUID(), event: PrivateEvent(kind: .note, text: "Pending note")) }
            try await fixture.store.appendBatch(batch, deviceID: fixture.device)
        }
        let last = (0..<3).map { _ in (id: UUID(), event: PrivateEvent(kind: .note, text: "At the outbox boundary")) }
        await #expect(throws: ReaderError.localCapacityExceeded) { try await fixture.store.appendBatch(last, deviceID: fixture.device) }
        #expect(await fixture.store.pending().count == 998)
        #expect(await fixture.store.state().events.count == 998)
        let reopened = try fixture.reopen()
        #expect(await reopened.pending().count == 998)
        let accepted = Array(last.prefix(2))
        let saved = try await reopened.appendBatch(accepted, deviceID: fixture.device)
        #expect(await reopened.pending().count == 1_000)
        #expect(try await reopened.appendBatch(accepted, deviceID: fixture.device) == saved)
        #expect(await reopened.pending().count == 1_000)
    }

    @Test func byteCapacityRejectsAllNewEventsBeforePublishingAny() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let text = String(repeating: "x", count: 200_000)
        let oversized = (0..<84).map { _ in (id: UUID(), event: PrivateEvent(kind: .note, text: text)) }
        await #expect(throws: ReaderError.localCapacityExceeded) { try await fixture.store.appendBatch(oversized, deviceID: fixture.device) }
        #expect(await fixture.store.state().events.isEmpty)
        #expect(await fixture.store.pending().isEmpty)
        let reopened = try fixture.reopen()
        #expect(await reopened.state().events.isEmpty)
        #expect(await reopened.pending().isEmpty)
    }

    @Test func snapshotKeepsGenerationHistoryAndOutboxCoherentAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let initial = await fixture.store.snapshot()
        #expect(initial.generation == 0 && initial.pendingCount == 0 && initial.state.events.isEmpty)
        let turn = firstTurn()
        let saved = try await fixture.store.appendBatch(turn, deviceID: fixture.device)
        let appended = await fixture.store.snapshot()
        #expect(appended.generation == 1 && appended.pendingCount == 2 && appended.state.events.count == 2)
        #expect(appended.state.conversationBranches(turn[0].event.entityID).first?.messages.map(\.id) == [turn[1].id])

        try await fixture.store.acknowledge(saved[0])
        let acknowledged = await fixture.store.snapshot()
        #expect(acknowledged.generation == 2 && acknowledged.pendingCount == 1)
        #expect(acknowledged.state == appended.state)
        try await fixture.store.acknowledge(saved[0])
        #expect(try await fixture.store.appendBatch(turn, deviceID: fixture.device) == saved)
        #expect(await fixture.store.snapshot() == acknowledged)
        let reopened = try fixture.reopen()
        #expect(await reopened.snapshot() == LocalStoreSnapshot(state: acknowledged.state, generation: acknowledged.generation + 1,
            pendingCount: acknowledged.pendingCount, drafts: acknowledged.drafts, pendingEventIDs: acknowledged.pendingEventIDs, pendingNoteBlobs: acknowledged.pendingNoteBlobs, noteDestination: acknowledged.noteDestination))

        try await reopened.acknowledge(saved[1])
        let complete = await reopened.snapshot()
        #expect(complete.generation == 4 && complete.pendingCount == 0 && complete.state == appended.state)
        let remote = try ReaderCrypto.seal(PrivateEvent(kind: .note, text: "An incoming annotation"), id: UUID(), deviceID: UUID(), keys: fixture.keys)
        try await reopened.ingest([RemoteEvent(cursor: 1, envelope: remote, digest: remote.sha256)])
        let received = await reopened.snapshot()
        #expect(received.generation == 5 && received.pendingCount == 0 && received.state.events.count == 3)
        #expect(received.state.events[remote.id] != nil)
        let final = try fixture.reopen()
        #expect(await final.snapshot() == LocalStoreSnapshot(state: received.state, generation: received.generation + 1,
            pendingCount: received.pendingCount, drafts: received.drafts, pendingEventIDs: received.pendingEventIDs, pendingNoteBlobs: received.pendingNoteBlobs, noteDestination: received.noteDestination))
        // Earlier values remain stable even when later generations are
        // published first by independent asynchronous UI continuations.
        #expect(initial.state.events.isEmpty && initial.pendingCount == 0)
        #expect(appended.state.events.count == 2 && appended.pendingCount == 2)
    }

    @Test func rejectedAndRolledBackWritesNeverAdvanceThePublishedSnapshot() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let payload = PrivateEvent(kind: .note, text: "Previously durable annotation"), id = UUID()
        try await fixture.store.append(payload, deviceID: fixture.device, id: id)
        let before = await fixture.store.snapshot()
        var invalid = firstTurn(); invalid[1].event.role = nil
        await #expect(throws: ReaderError.invalidEvent) { try await fixture.store.appendBatch(invalid, deviceID: fixture.device) }
        #expect(await fixture.store.snapshot() == before)
        await #expect(throws: ReaderError.eventConflict) {
            try await fixture.store.append(PrivateEvent(kind: .note, text: "Conflicting annotation"), deviceID: fixture.device, id: id)
        }
        #expect(await fixture.store.snapshot() == before)

        let database = try SQLiteConnection(url: fixture.url)
        try database.execute("CREATE TRIGGER interrupt_snapshot BEFORE INSERT ON records WHEN NEW.ordinal=3 BEGIN SELECT RAISE(ABORT,'synthetic_snapshot_failure'); END;")
        await #expect(throws: (any Error).self) { try await fixture.store.appendBatch(firstTurn(), deviceID: fixture.device) }
        #expect(await fixture.store.snapshot() == before)
        let reopened = try fixture.reopen()
        #expect(await reopened.snapshot() == LocalStoreSnapshot(state: before.state, generation: before.generation + 1,
            pendingCount: before.pendingCount, drafts: before.drafts, pendingEventIDs: before.pendingEventIDs, pendingNoteBlobs: before.pendingNoteBlobs, noteDestination: before.noteDestination))
    }
}

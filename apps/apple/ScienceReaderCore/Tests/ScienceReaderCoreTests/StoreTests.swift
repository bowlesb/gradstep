import Foundation
import CSQLite
import Testing
@testable import ScienceReaderCore

@Suite struct StoreTests {
    @Test func failedPageCommitRollsBackRecordsCursorAndAcknowledgment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite")
        let account = UUID(), device = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        let local = try await store.append(PrivateEvent(kind: .note, text: "unsent edit"), deviceID: device)
        let second = try ReaderCrypto.seal(PrivateEvent(kind: .note, text: "second"), id: UUID(), deviceID: UUID(), keys: keys)
        let third = try ReaderCrypto.seal(PrivateEvent(kind: .note, text: "third"), id: UUID(), deviceID: UUID(), keys: keys)
        let page = [local, second, third].enumerated().map { RemoteEvent(cursor: Int64($0.offset+1), envelope: $0.element, digest: $0.element.sha256) }
        let database = try SQLiteConnection(url: path.resolvingSymlinksInPath())
        try database.execute("CREATE TRIGGER interrupt_page BEFORE INSERT ON records WHEN NEW.ordinal=3 BEGIN SELECT RAISE(ABORT,'synthetic_storage_failure'); END;")
        await #expect(throws: (any Error).self) { try await store.ingest(page) }
        #expect(await store.cursor() == 0)
        #expect(await store.pending() == [local])
        #expect(await store.state().events.count == 1)
        let reopened = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        #expect(await reopened.pending() == [local])
        #expect(await reopened.cursor() == 0)
        #expect(await reopened.state().events.count == 1)
        try database.execute("DROP TRIGGER interrupt_page")
        try await reopened.ingest(page)
        #expect(await reopened.cursor() == 3)
        #expect(await reopened.pending().isEmpty)
        let restored = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        #expect(await restored.state().events.count == 3)
        #expect(await restored.cursor() == 3)
    }

    @Test func staleWriterCannotOverwriteAnotherCommittedOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite"), account = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        let stale = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        let first = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        let payload = PrivateEvent(kind: .note, text: "durable first edit"), device = UUID(), id = UUID()
        let envelope = try await first.append(payload, deviceID: device, id: id)
        #expect(try await first.append(payload, deviceID: device, id: id) == envelope)
        await #expect(throws: ReaderError.storeChanged) { try await stale.append(PrivateEvent(kind: .note, text: "stale writer"), deviceID: UUID()) }
        let reopened = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        #expect(await reopened.pending() == [envelope])
        #expect(await reopened.state().events.count == 1)
        #expect(throws: (any Error).self) { try EncryptedStore(url: path, accountID: account, localKey: ReaderCrypto.randomKey(), keys: keys) }
        let another = UUID()
        #expect(throws: (any Error).self) { try EncryptedStore(url: path, accountID: another, localKey: key, keys: KeyBundle.generate(accountID: another)) }
    }

    @Test(arguments: ["deletion", "reordering", "substitution"])
    func recordSetCorruptionIsDetected(change: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite"), account = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        let first = try await store.append(PrivateEvent(kind: .note, text: "first"), deviceID: UUID())
        try await store.acknowledge(first)
        try await store.append(PrivateEvent(kind: .note, text: "second"), deviceID: UUID())
        let database = try SQLiteConnection(url: path.resolvingSymlinksInPath())
        switch change {
        case "deletion": try database.execute("DELETE FROM records WHERE ordinal=1")
        case "reordering": try database.execute("UPDATE records SET ordinal=3 WHERE ordinal=1")
        default: try database.execute("UPDATE records SET sealed=(SELECT sealed FROM records WHERE ordinal=2) WHERE ordinal=1")
        }
        #expect(throws: (any Error).self) { try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys) }
    }

    @Test func pendingWriteSurvivesRestartWithoutPlaintext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.enc")
        let account = UUID(), device = UUID(), localKey = ReaderCrypto.randomKey()
        let keys = KeyBundle.generate(accountID: account)
        let payload = PrivateEvent(kind: .note, text: "SECRET-UNSYNCED-ANNOTATION")
        let first = try EncryptedStore(url: path, accountID: account, localKey: localKey, keys: keys)
        let envelope = try await first.append(payload, deviceID: device)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let disk = try Data(contentsOf: file)
            #expect(disk.range(of: Data("SECRET-UNSYNCED-ANNOTATION".utf8)) == nil)
        }
        let restarted = try EncryptedStore(url: path, accountID: account, localKey: localKey, keys: keys)
        #expect(await restarted.pending() == [envelope])
        #expect(await restarted.state().revisions(for: payload.entityID).first?.payload == payload)
        try await restarted.acknowledge(envelope)
        #expect(await restarted.cursor() == 0)
        let afterAck = try EncryptedStore(url: path, accountID: account, localKey: localKey, keys: keys)
        #expect(await afterAck.pending().isEmpty)
        try await afterAck.ingest([RemoteEvent(cursor: 1, envelope: envelope, digest: envelope.sha256)])
        #expect(await afterAck.cursor() == 1)
        #expect(await afterAck.state().events.count == 1)
    }

    @Test func corruptPageCannotAdvanceCursorOrDiscardOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), device = UUID(), keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: directory.appendingPathComponent("state.enc"), accountID: account, localKey: ReaderCrypto.randomKey(), keys: keys)
        let local = try await store.append(PrivateEvent(kind: .note, text: "pending"), deviceID: device)
        let remote = try ReaderCrypto.seal(PrivateEvent(kind: .note, text: "remote"), id: UUID(), deviceID: UUID(), keys: keys)
        await #expect(throws: ReaderError.corruptData) {
            try await store.ingest([RemoteEvent(cursor: 1, envelope: local, digest: local.sha256), RemoteEvent(cursor: 2, envelope: remote, digest: Data())])
        }
        #expect(await store.cursor() == 0)
        #expect(await store.pending() == [local])
        #expect(await store.state().events.count == 1)
        await #expect(throws: ReaderError.cursorGap) {
            try await store.ingest([RemoteEvent(cursor: 2, envelope: remote, digest: remote.sha256)])
        }
        #expect(await store.cursor() == 0)
    }

    @Test func corruptedDiskNeverBecomesEmptyStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.enc")
        let account = UUID(), keys = KeyBundle.generate(accountID: account), localKey = ReaderCrypto.randomKey()
        let store = try EncryptedStore(url: path, accountID: account, localKey: localKey, keys: keys)
        try await store.append(PrivateEvent(kind: .note, text: "keep this"), deviceID: UUID())
        let database = try SQLiteConnection(url: path.resolvingSymlinksInPath())
        let damaged = Data(repeating: 0x17, count: 80)
        try database.update("UPDATE records SET sealed=? WHERE ordinal=1", values: [.blob(damaged)])
        #expect(throws: (any Error).self) { try EncryptedStore(url: path, accountID: account, localKey: localKey, keys: keys) }
        let preserved = try database.statement("SELECT sealed FROM records WHERE ordinal=1") { statement in
            _ = sqlite3_step(statement); return try SQLiteConnection.blob(statement, 0)
        }
        #expect(preserved == damaged)
    }

    @Test func concurrentNoteEditsAndDeletionConverge() throws {
        let note = UUID(), deviceA = UUID(), deviceB = UUID(), rootID = UUID()
        let root = AppliedEvent(id: rootID, deviceID: deviceA, payload: PrivateEvent(kind: .note, entityID: note, text: "original"))
        let left = AppliedEvent(id: UUID(), deviceID: deviceA, payload: PrivateEvent(kind: .note, entityID: note, parents: [rootID], text: "left edit"))
        let right = AppliedEvent(id: UUID(), deviceID: deviceB, payload: PrivateEvent(kind: .note, entityID: note, parents: [rootID], text: "right edit"))
        var a = PrivateState(), b = PrivateState()
        for event in [root, left, right] { try a.apply(event) }
        for event in [right, root, left] { try b.apply(event) }
        #expect(a == b)
        #expect(a.revisions(for: note).count == 2)
        let deleted = AppliedEvent(id: UUID(), deviceID: deviceB, payload: PrivateEvent(kind: .tombstone, entityID: note))
        try a.apply(deleted)
        let late = AppliedEvent(id: UUID(), deviceID: deviceA, payload: PrivateEvent(kind: .note, entityID: note, parents: [left.id], text: "late offline edit"))
        try a.apply(late)
        #expect(a.revisions(for: note).isEmpty)
        #expect(a.isDeleted(note))
    }
}

import CryptoKit
import CSQLite
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct RebaseTests {
    @Test func formatTwoHistoryUpgradesWithoutRewritingExistingRecords() async throws {
        // Captured by running EncryptedStore from 34100c5 in an isolated package,
        // using only public fixture keys. This is not today's writer relabeled.
        struct Fixture: Decodable {
            struct Record: Decodable { let ordinal: Int64; let id: String; let sealed: Data }
            let sourceCommit: String; let keys: KeyBundle; let localKey: Data; let metadata: Data; let records: [Record]
        }
        let fixtureURL = try #require(Bundle.module.url(forResource: "local-store-v2", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        #expect(fixture.sourceCommit.hasPrefix("34100c5"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("state.sqlite")
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let database = try SQLiteConnection(url: url)
        try database.execute("CREATE TABLE records(ordinal INTEGER PRIMARY KEY,id TEXT NOT NULL UNIQUE,sealed BLOB NOT NULL); CREATE TABLE metadata(id INTEGER PRIMARY KEY CHECK(id=1),sealed BLOB NOT NULL); PRAGMA application_id=1397903940; PRAGMA user_version=2;")
        for record in fixture.records {
            try database.update("INSERT INTO records VALUES(?,?,?)", values: [.integer(record.ordinal), .text(record.id), .blob(record.sealed)])
        }
        try database.update("INSERT INTO metadata VALUES(1,?)", values: [.blob(fixture.metadata)])
        let store = try EncryptedStore(url: url, accountID: fixture.keys.accountID, localKey: fixture.localKey, keys: fixture.keys)
        #expect(await store.cursor() == 1)
        #expect(await store.state().events.count == 2)
        let pending = try #require(await store.pending().first)
        #expect(try ReaderCrypto.open(pending, keys: fixture.keys).text == "Pending format-two edit")
        var keys = fixture.keys; try keys.rotate(); try await store.updateKeys(keys)
        let mapping = try await store.rebasePendingAfterCatchUp(deviceID: pending.deviceID, verifiedEpoch: keys.epoch, cursor: 1)
        #expect(mapping.count == 1 && mapping[pending.id] != nil)
        let reopened = try EncryptedStore(url: url, accountID: keys.accountID, localKey: fixture.localKey, keys: keys)
        #expect(await reopened.state() == store.state())
        #expect(await reopened.pending() == store.pending())
        for record in fixture.records {
            let preserved = try database.statement("SELECT sealed FROM records WHERE ordinal=?", values: [.integer(record.ordinal)]) { statement in
                #expect(sqlite3_step(statement) == SQLITE_ROW)
                return try SQLiteConnection.blob(statement, 0)
            }
            #expect(preserved == record.sealed)
        }
    }

    @Test func rotationPreservesPendingContentAndParentLinksAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite"), account = UUID(), device = UUID(), key = ReaderCrypto.randomKey()
        var keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys)
        let conversation = UUID()
        let root = try await store.append(PrivateEvent(kind: .conversation, entityID: conversation, text: "Offline conversation"), deviceID: device)
        let first = try await store.append(PrivateEvent(kind: .message, parents: [root.id], conversationID: conversation, text: "Unsent question", role: .user, status: .complete), deviceID: device)
        try keys.rotate(); try await store.updateKeys(keys)
        // A new-epoch child created while catch-up is running still depends on an
        // old-epoch parent and must be part of the same atomic replacement set.
        let child = try await store.append(PrivateEvent(kind: .message, parents: [first.id], conversationID: conversation, text: "Follow-up", role: .user, status: .complete), deviceID: device)
        let nextDevice = UUID()
        let mapping = try await store.rebasePendingAfterCatchUp(deviceID: nextDevice, verifiedEpoch: 2, cursor: 0)
        #expect(mapping.count == 3)
        let pending = await store.pending()
        #expect(pending.count == 3 && pending.allSatisfy { $0.epoch == 2 && $0.deviceID == nextDevice })
        #expect(Set(pending.map(\.id)).isDisjoint(with: [root.id, first.id, child.id]))
        let state = await store.state(), branches = state.conversationBranches(conversation)
        #expect(state.events.count == 3 && branches.count == 1 && branches[0].complete)
        #expect(branches[0].messages.map { $0.payload.text } == ["Unsent question", "Follow-up"])
        #expect(state.resolvedEventID(first.id) == mapping[first.id])
        let reopened = try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys)
        #expect(await reopened.pending() == pending)
        #expect(await reopened.state() == state)
        #expect(try await reopened.rebasePendingAfterCatchUp(deviceID: nextDevice, verifiedEpoch: 2, cursor: 0).isEmpty)
        // A second rotation is replayed from the journal, preserving the original
        // UI reference as an alias to the latest immutable cloud event.
        try keys.rotate(); try await reopened.updateKeys(keys)
        let secondMap = try await reopened.rebasePendingAfterCatchUp(deviceID: nextDevice, verifiedEpoch: 3, cursor: 0)
        let final = try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys)
        #expect(await final.state().resolvedEventID(first.id) == secondMap[mapping[first.id]!])
        #expect(await final.state().events.count == 3)
    }

    @Test func lostAcknowledgementIsPulledBeforeRebasingUncommittedChildren() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), device = UUID(), key = ReaderCrypto.randomKey(), conversation = UUID()
        var keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: directory.appendingPathComponent("state.sqlite"), accountID: account, localKey: key, keys: keys)
        let committed = try await store.append(PrivateEvent(kind: .message, conversationID: conversation, text: "Server received this", role: .user, status: .complete), deviceID: device)
        let pending = try await store.append(PrivateEvent(kind: .message, parents: [committed.id], conversationID: conversation, text: "Still offline", role: .user, status: .complete), deviceID: device)
        try keys.rotate(); try await store.updateKeys(keys)
        try await store.ingest([RemoteEvent(cursor: 1, envelope: committed, digest: committed.sha256)])
        let mapping = try await store.rebasePendingAfterCatchUp(deviceID: device, verifiedEpoch: 2, cursor: 1)
        #expect(Set(mapping.keys) == [pending.id])
        let uploaded = try #require(await store.pending().first)
        let payload = try ReaderCrypto.open(uploaded, keys: keys)
        #expect(payload.parents == [committed.id])
        try await store.ingest([RemoteEvent(cursor: 2, envelope: uploaded, digest: uploaded.sha256)])
        #expect(await store.pending().isEmpty)
        #expect(await store.state().events.count == 2)
        await #expect(throws: ReaderError.eventConflict) { try await store.ingest([RemoteEvent(cursor: 3, envelope: pending, digest: pending.sha256)]) }
        #expect(await store.cursor() == 2)
    }

    @Test func interruptedReplacementTransactionKeepsExactOriginalOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite"), account = UUID(), key = ReaderCrypto.randomKey(), device = UUID()
        var keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys)
        let original = try await store.append(PrivateEvent(kind: .note, text: "Preserve through a failed rebase"), deviceID: device)
        try keys.rotate(); try await store.updateKeys(keys)
        let database = try SQLiteConnection(url: url)
        // New envelope is row 2; row 3 is the marker. Fail between those writes.
        try database.execute("CREATE TRIGGER interrupt_rebase BEFORE INSERT ON records WHEN NEW.ordinal=3 BEGIN SELECT RAISE(ABORT,'synthetic_rebase_failure'); END;")
        await #expect(throws: (any Error).self) { try await store.rebasePendingAfterCatchUp(deviceID: device, verifiedEpoch: 2, cursor: 0) }
        let reopened = try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys)
        #expect(await reopened.pending() == [original])
        #expect(await reopened.state().events.count == 1)
        try database.execute("DROP TRIGGER interrupt_rebase")
        #expect(try await reopened.rebasePendingAfterCatchUp(deviceID: device, verifiedEpoch: 2, cursor: 0).count == 1)
    }
}

import CryptoKit
import CSQLite
import Foundation
import Testing
@testable import ScienceReaderCore

/// Notes local durability and blob transport: a save commits blobs, a new note and the entry together; the entry
/// uploads only after its blobs are `ready`; blobs retry with the same IDs and bytes; images are fetched on demand into
/// an encrypted cache.
@Suite struct NoteStoreTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        let account = UUID(), device = UUID(), key = ReaderCrypto.randomKey()
        let keys: KeyBundle
        var url: URL { directory.appendingPathComponent("state.sqlite") }
        init() { keys = KeyBundle.generate(accountID: account) }
        func open() throws -> EncryptedStore { try EncryptedStore(url: url, accountID: account, localKey: key, keys: keys) }
    }

    /// An in-memory note-assets service: idempotent PUT by (ID, digest), 409 on a different digest, scripted failures.
    actor FakeTransport: NoteAssetTransport {
        var stored: [UUID: Data] = [:]
        var puts: [UUID] = [], gets: [UUID] = []
        var failNextPuts: [NoteAssetError] = []
        var tamperDownloads = false
        func failPuts(_ errors: [NoteAssetError]) { failNextPuts = errors }
        func setTamper(_ value: Bool) { tamperDownloads = value }
        func put(blobID: UUID, blob: Data, sha256: String) async throws -> Int {
            puts.append(blobID)
            if !failNextPuts.isEmpty { throw failNextPuts.removeFirst() }
            guard Data(SHA256.hash(data: blob)).hex == sha256 else { throw NoteAssetError.invalidResponse }
            if let existing = stored[blobID] { guard existing == blob else { throw NoteAssetError.conflict } }
            stored[blobID] = blob
            return blob.count
        }
        func get(blobID: UUID) async throws -> Data {
            gets.append(blobID)
            guard var blob = stored[blobID] else { throw NoteAssetError.notFound }
            if tamperDownloads { blob[blob.count - 1] ^= 1 }
            return blob
        }
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 200)
    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 9, count: 100)

    /// A region capture into a new note: the note root, the entry and its two blobs.
    private func capture(_ f: Fixture, noteID: UUID = UUID(), newNote: Bool = true, counter: Int64 = 1,
                         comment: String = "") throws -> (events: [(id: UUID, event: PrivateEvent)], blobs: [NoteBlobWrite], entry: NoteEntryRecord) {
        let full = try NoteBlobCrypto.seal(Self.png, type: NoteMedia.png, width: 640, height: 300, accountID: f.account)
        let thumb = try NoteBlobCrypto.seal(Self.jpeg, type: NoteMedia.jpeg, width: 480, height: 225, accountID: f.account)
        let entry = NoteEntryRecord(noteID: noteID, kind: .region, counter: counter, capturedAt: 1_792_900_060_000, offsetMinutes: -420,
                                    comment: comment, source: NoteSource(kind: .arxiv, title: "Paper", sourceID: "2305.18290", revision: 3),
                                    media: NoteMediaSet(full: full.media, thumb: thumb.media))
        var events: [(id: UUID, event: PrivateEvent)] = []
        if newNote { events.append((UUID(), try NotesRecord.note(NoteRecord(noteID: noteID, title: "Quick notes", createdAt: 1)).event())) }
        events.append((UUID(), try NotesRecord.entry(entry).event()))
        return (events, [NoteBlobWrite(blobID: full.media.blobID, blob: full.blob), NoteBlobWrite(blobID: thumb.media.blobID, blob: thumb.blob)], entry)
    }

    @Test func aSaveCommitsBlobsNoteAndEntryTogetherAndTheEntryWaitsForItsBlobs() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open()
        let chat = try await store.append(PrivateEvent(kind: .conversation, text: "Unrelated chat"), deviceID: f.device)
        let saved = try capture(f)
        let envelopes = try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device, destination: saved.entry.noteID)
        let snapshot = await store.snapshot()
        #expect(NotesState(snapshot.state).notes.first?.entries.first?.record == saved.entry)
        #expect(snapshot.pendingCount == 3 && snapshot.pendingNoteBlobs == Set(saved.blobs.map(\.blobID)))
        #expect(snapshot.noteDestination == saved.entry.noteID)
        // The note root and the chat may upload now; the entry waits for its blobs.
        #expect(await store.pending().map(\.id) == [chat.id, envelopes[0].id])
        #expect(await store.heldNoteEvents() == [envelopes[1].id: saved.blobs.map(\.blobID)])
        #expect(try await store.pendingNoteUploads() == saved.blobs.map(\.blobID))
        #expect(try await store.noteBlob(saved.blobs[0].blobID) == saved.blobs[0].blob)

        // An exact retry (same IDs and bytes) changes nothing; other bytes for the same blob are refused.
        let generation = snapshot.generation
        #expect(try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device) == envelopes)
        #expect(await store.snapshot().generation == generation)
        await #expect(throws: ReaderError.eventConflict) {
            try await store.saveNoteEntry(saved.events, blobs: [NoteBlobWrite(blobID: saved.blobs[0].blobID, blob: saved.blobs[1].blob)], deviceID: f.device)
        }

        // Reopened (an app restart), everything is still there and still held.
        let reopened = try f.open()
        #expect(await reopened.snapshot().state == snapshot.state)
        #expect(await reopened.pending().map(\.id) == [chat.id, envelopes[0].id])
        #expect(try await reopened.pendingNoteUploads() == saved.blobs.map(\.blobID))

        // Once both blobs are ready, the entry is uploadable; the rows stay as this device's copy.
        try await reopened.markNoteBlobsReady([saved.blobs[0].blobID])
        #expect(await reopened.pending().map(\.id) == [chat.id, envelopes[0].id], "One blob is not enough")
        try await reopened.markNoteBlobsReady([saved.blobs[1].blobID])
        #expect(await reopened.pending().map(\.id) == [chat.id, envelopes[0].id, envelopes[1].id])
        #expect(await reopened.heldNoteEvents().isEmpty)
        #expect(try await reopened.pendingNoteUploads().isEmpty)
        #expect(try await reopened.noteBlob(saved.blobs[1].blobID) == saved.blobs[1].blob)
        #expect(try await f.open().pending().count == 3)
    }

    @Test func aFailedSaveLeavesNothingBehind() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open()
        let before = await store.snapshot()
        let saved = try capture(f)
        let database = try SQLiteConnection(url: f.url)
        try database.execute("CREATE TRIGGER refuse_entry BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic_disk_failure'); END;")
        await #expect(throws: (any Error).self) { try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device) }
        let count = try database.statement("SELECT count(*) FROM local_note_blobs") { statement in _ = sqlite3_step(statement); return sqlite3_column_int(statement, 0) }
        #expect(count == 0, "No blob row without its entry")
        #expect(await store.snapshot() == before)
        try database.execute("DROP TRIGGER refuse_entry")
        // The same save then succeeds with the same identities.
        let envelopes = try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        #expect(envelopes.map(\.id) == saved.events.map(\.id))
    }

    @Test func aCommentEditOfAHeldEntryWaitsWithItButOtherWorkDoesNot() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open()
        let saved = try capture(f)
        let envelopes = try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        var edited = saved.entry; edited.comment = "Edited while offline"
        let edit = try await store.append(try NotesRecord.entry(edited).event(parents: [envelopes[1].id]), deviceID: f.device)
        let text = NoteEntryRecord(noteID: saved.entry.noteID, kind: .text, counter: 2, capturedAt: 2, offsetMinutes: 0, comment: "Plain writing")
        let textEnvelope = try await store.saveNoteEntry([(UUID(), try NotesRecord.entry(text).event())], blobs: [], deviceID: f.device)
        #expect(await store.pending().map(\.id) == [envelopes[0].id, textEnvelope[0].id])
        try await store.markNoteBlobsReady(saved.blobs.map(\.blobID))
        #expect(await store.pending().map(\.id) == [envelopes[0].id, envelopes[1].id, edit.id, textEnvelope[0].id])
        #expect(NotesState(await store.state()).notes[0].entries.map(\.record.comment) == ["Edited while offline", "Plain writing"])
    }

    @Test func heldEntriesKeepWaitingUnderTheirNewIDsAfterAKeyRotation() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open()
        let saved = try capture(f)
        let envelopes = try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        var rotated = f.keys; try rotated.rotate()
        try await store.updateKeys(rotated)
        let mapping = try await store.rebasePendingAfterCatchUp(deviceID: f.device, verifiedEpoch: rotated.epoch, cursor: 0)
        let newEntryID = try #require(mapping[envelopes[1].id])
        #expect(await store.heldNoteEvents() == [newEntryID: saved.blobs.map(\.blobID)])
        #expect(await store.pending().map(\.id) == [mapping[envelopes[0].id]!])
        let reopened = try EncryptedStore(url: f.url, accountID: f.account, localKey: f.key, keys: rotated)
        #expect(await reopened.heldNoteEvents() == [newEntryID: saved.blobs.map(\.blobID)])
        // The media descriptor and its key are unchanged: no new upload is needed.
        #expect(NotesState(await reopened.state()).notes[0].entries[0].record.media == saved.entry.media)
    }

    @Test func uploadsMarkBlobsReadyRetryWithTheSameBytesAndReportFailures() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open(), transport = FakeTransport()
        let saved = try capture(f)
        let envelopes = try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        // Storage paused: the pass stops, nothing is marked, the entry stays held.
        await transport.failPuts([.quota])
        var report = try await NoteAssetSync.uploadPending(store: store, transport: transport)
        #expect(report.failures == [saved.blobs[0].blobID: .quota] && report.uploaded.isEmpty && report.remaining == 2)
        #expect(await store.pending().map(\.id) == [envelopes[0].id])
        // A timeout on the second: the first is ready; the retry sends the exact same bytes for the second.
        await transport.failPuts([])
        report = try await NoteAssetSync.uploadPending(store: store, transport: transport, limit: 1)
        #expect(report.uploaded == [saved.blobs[0].blobID] && report.remaining == 1)
        await transport.failPuts([.unavailable])
        report = try await NoteAssetSync.uploadPending(store: store, transport: transport)
        #expect(report.failures == [saved.blobs[1].blobID: .unavailable] && report.remaining == 1)
        report = try await NoteAssetSync.uploadPending(store: store, transport: transport)
        #expect(report.uploaded == [saved.blobs[1].blobID] && report.remaining == 0)
        #expect(await transport.stored[saved.blobs[1].blobID] == saved.blobs[1].blob)
        #expect(await transport.puts == [saved.blobs[0].blobID, saved.blobs[0].blobID, saved.blobs[1].blobID, saved.blobs[1].blobID])
        #expect(await store.pending().map(\.id) == envelopes.map(\.id))
        // A conflict (the ID exists with other bytes) is reported and leaves the entry held, without stopping others.
        let second = try capture(f, noteID: saved.entry.noteID, newNote: false, counter: 2)
        _ = try await store.saveNoteEntry(second.events, blobs: second.blobs, deviceID: f.device)
        await transport.failPuts([.conflict])
        report = try await NoteAssetSync.uploadPending(store: store, transport: transport)
        #expect(report.failures == [second.blobs[0].blobID: .conflict] && report.uploaded == [second.blobs[1].blobID])
        #expect(await store.heldNoteEvents().values.first == [second.blobs[0].blobID])
    }

    @Test func imagesComeFromThisDeviceOrADownloadVerifiedBeforeCaching() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let author = try f.open(), transport = FakeTransport()
        let saved = try capture(f)
        _ = try await author.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        let media = try #require(saved.entry.media)
        // The author's own capture shows without a network.
        #expect(try await NoteAssetSync.image(media.full, accountID: f.account, store: author, transport: nil) == Self.png)
        _ = try await NoteAssetSync.uploadPending(store: author, transport: transport)

        // A second approved device: same account keys, its own store.
        let other = Fixture.init()
        let second = try EncryptedStore(url: other.url, accountID: f.account, localKey: other.key, keys: f.keys)
        defer { try? FileManager.default.removeItem(at: other.directory) }
        await #expect(throws: NoteAssetError.unavailable) { try await NoteAssetSync.image(media.thumb!, accountID: f.account, store: second, transport: nil) }
        await transport.setTamper(true)
        await #expect(throws: NoteBlobCrypto.Failure.digest) {
            try await NoteAssetSync.image(media.thumb!, accountID: f.account, store: second, transport: transport)
        }
        #expect(try await second.noteBlob(media.thumb!.blobID) == nil, "A tampered download is never cached")
        await transport.setTamper(false)
        #expect(try await NoteAssetSync.image(media.thumb!, accountID: f.account, store: second, transport: transport) == Self.jpeg)
        #expect(try await NoteAssetSync.image(media.thumb!, accountID: f.account, store: second, transport: nil) == Self.jpeg, "Cached")
        #expect(await transport.gets.count == 2)
        // The wrong account cannot open it.
        await #expect(throws: NoteBlobCrypto.Failure.authentication) {
            try await NoteAssetSync.image(media.thumb!, accountID: UUID(), store: second, transport: transport)
        }
        // A cached copy is not an unsent upload: it never holds anything and never re-uploads.
        #expect(try await second.pendingNoteUploads().isEmpty)
    }

    @Test func formatSixStoresMigrateToFormatSevenWithNoNotesState() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open()
        let chat = try await store.append(PrivateEvent(kind: .conversation, text: "Before Notes"), deviceID: f.device)
        let before = await store.snapshot()
        let database = try SQLiteConnection(url: f.url)
        let aad = Data("science-reader/local-metadata/v2/\(f.account.wire)".utf8), key = SymmetricKey(data: f.key)
        let sealed = try database.statement("SELECT sealed FROM metadata WHERE id=1") { statement in
            _ = sqlite3_step(statement); return try SQLiteConnection.blob(statement, 0)
        }
        var metadata = try #require(JSONSerialization.jsonObject(with: AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                                                                                         authenticating: aad)) as? [String: Any])
        metadata["format"] = 6; metadata.removeValue(forKey: "noteUploads"); metadata.removeValue(forKey: "noteHolds")
        let legacy = try #require(AES.GCM.seal(JSONSerialization.data(withJSONObject: metadata), using: key, authenticating: aad).combined)
        try database.execute("BEGIN IMMEDIATE; DROP TABLE local_note_blobs; PRAGMA user_version=5")
        try database.update("UPDATE metadata SET sealed=? WHERE id=1", values: [.blob(legacy)])
        try database.execute("COMMIT")
        let migrated = try f.open()
        let snapshot = await migrated.snapshot()
        #expect(snapshot.state == before.state && snapshot.pendingNoteBlobs.isEmpty && snapshot.noteDestination == nil)
        #expect(await migrated.pending().map(\.id) == [chat.id])
        let version = try database.statement("PRAGMA user_version") { statement in _ = sqlite3_step(statement); return sqlite3_column_int(statement, 0) }
        #expect(version == 6)
        let saved = try capture(f)
        _ = try await migrated.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        #expect(try await f.open().pendingNoteUploads().count == 2)
    }

    @Test func aMissingUnsentBlobIsReportedNotIgnored() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open()
        let saved = try capture(f)
        _ = try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        let database = try SQLiteConnection(url: f.url)
        try database.update("DELETE FROM local_note_blobs WHERE id=?", values: [.text(saved.blobs[0].blobID.wire)])
        #expect(throws: ReaderError.corruptData) { try f.open() }
    }

    @Test func theCacheEvictsOldDownloadsButNeverUnsentCaptures() async throws {
        let f = Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try f.open()
        let saved = try capture(f)
        _ = try await store.saveNoteEntry(saved.events, blobs: saved.blobs, deviceID: f.device)
        let big = Data(repeating: 1, count: 2 * 1024 * 1024)
        var cached: [UUID] = []
        for _ in 0..<(EncryptedStore.maximumNoteCacheBytes / big.count + 2) {
            let id = UUID(); cached.append(id)
            try await store.cacheNoteBlob(id, blob: big)
        }
        #expect(try await store.noteBlob(cached[0]) == nil, "The oldest download went first")
        #expect(try await store.noteBlob(cached.last!) == big)
        #expect(try await store.noteBlob(saved.blobs[0].blobID) == saved.blobs[0].blob, "Unsent captures stay")
        #expect(try await store.pendingNoteUploads().count == 2)
    }
}

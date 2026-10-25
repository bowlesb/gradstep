import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// A device whose disk is full (docs/reviews/OFFLINE_AND_STORAGE_20261025.md): every write either completes or leaves
/// what was there before, the failure is told apart as "out of space" with how much to free, and once space is freed
/// the same store keeps working without a relaunch. Real ENOSPC on a 20 MB APFS disk image (`SmallDisk`); skipped where
/// `hdiutil` can't run.
@Suite(.serialized) struct StorageFullTests {
    @Test func outOfSpaceIsToldApartFromOtherWriteFailures() {
        #expect(StorageSpace.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        #expect(StorageSpace.isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(StorageSpace.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))))
        #expect(StorageSpace.isOutOfSpace(DatabaseFailure(code: 13)))
        #expect(StorageSpace.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: 4992)), "On-Demand Resources out of space")
        #expect(StorageSpace.isOutOfSpace(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile,
                                                   userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])), "a download that couldn't write its file")
        #expect(!StorageSpace.isOutOfSpace(DatabaseFailure(code: 5)), "busy is not full")
        #expect(!StorageSpace.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
        #expect(!StorageSpace.isOutOfSpace(URLError(.notConnectedToInternet)))
        #expect(!StorageSpace.isOutOfSpace(ReaderError.localCapacityExceeded), "the library's own limit has its own words")
        #expect(StorageSpace.message(for: URLError(.timedOut)) == nil)
        #expect(StorageSpace.message(needing: 1_234_567) == "This device is out of space. Free up 2 MB and try again.")
        #expect(StorageSpace.message(needing: 120_000) == "This device is out of space. Free up 1 MB and try again.")
        #expect(StorageSpace.message(for: POSIXError(.ENOSPC)) == "This device is out of space. Free up some space and try again.")
        #expect(StorageFullError(needed: 340_000_000).localizedDescription == "This device is out of space. Free up 340 MB and try again.")
    }

    @Test func ensureRefusesBeforeWritingWhenTheVolumeCantHoldIt() throws {
        guard let disk = SmallDisk() else { return }
        defer { disk.detach() }
        let target = disk.root.appendingPathComponent("not-yet/created/file")
        #expect(StorageSpace.available(at: target) != nil, "the nearest existing folder's volume")
        try StorageSpace.ensure(1_000_000, at: target, margin: 0)
        do { try StorageSpace.ensure(200_000_000, at: target, margin: 0); Issue.record("a 20 MB disk can't hold 200 MB") }
        catch let error as StorageFullError { #expect((error.needed ?? 0) > 170_000_000) }
    }

    /// Chats, notes, drafts and the sync outbox share one SQLite store: a commit on a full disk fails as out of space,
    /// nothing committed before is lost (also after reopening), and after space is freed the same open store saves again.
    @Test func theEncryptedStoreFailsCleanlyWhenFullAndRecoversWhenSpaceIsFreed() async throws {
        guard let disk = SmallDisk() else { return }
        defer { disk.detach() }
        let path = disk.root.appendingPathComponent("account/state.sqlite")
        let account = UUID(), device = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        let kept = try await store.append(PrivateEvent(kind: .note, text: "written before the disk filled"), deviceID: device)
        let filler = disk.fill(leaving: 16 * 1024)
        let text = String(repeating: "A question long enough to need new pages. ", count: 400)
        var failure: Error?
        for _ in 0..<200 {
            do { try await store.append(PrivateEvent(kind: .note, text: text), deviceID: device) } catch { failure = error; break }
        }
        let error = try #require(failure, "the disk filled")
        #expect(StorageSpace.isOutOfSpace(error), "\(error)")
        let saved = await store.state().events.count
        #expect(await store.state().events[kept.id] != nil)

        disk.release(filler)
        // The same store, without a relaunch: a failed commit rolled back and left it usable.
        try await store.append(PrivateEvent(kind: .note, text: "after space was freed"), deviceID: device)
        #expect(await store.state().events.count == saved + 1)
        let reopened = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        #expect(await reopened.state().events.count == saved + 1)
        #expect(await reopened.pending().contains(kept), "unsent work is still queued for sync")
    }

    /// Launch on a full disk: what is already saved opens and reads (the library, chats and notes keep working
    /// read-only), a save says the disk is full, and once space is freed the same store saves again. Before 2026-10-25
    /// this failed at open (SQLITE_IOERR_SHMOPEN, then SQLITE_FULL from the open's own bookkeeping write), which took
    /// the whole private library down. `earlierBuild`: the store was last closed by a build that let SQLite delete its
    /// -wal and -shm files; `leaving`: the bytes still free (none: not even an empty file can be made; a few blocks: an
    /// empty -wal fits, its 32 KB shared-memory index doesn't).
    @Test(arguments: [(false, 0), (true, 0), (true, 12_288)])
    func aStoreSavedEarlierOpensOnAFullDisk(earlierBuild: Bool, leaving: Int) async throws {
        guard let disk = SmallDisk() else { return }
        defer { disk.detach() }
        let path = disk.root.appendingPathComponent("account/state.sqlite")
        let account = UUID(), device = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        var saved: [EventEnvelope] = []
        do {
            let store = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
            for index in 0..<20 { saved.append(try await store.append(PrivateEvent(kind: .note, text: "note \(index)"), deviceID: device)) }
            _ = try await store.saveDraft(LocalDraft(id: UUID(), revision: 1, textRevision: UUID(), text: "", editedAt: Date(), branchRevision: UUID()))
        } // closed: SQLite checkpoints the journal into the database
        let folder = path.deletingLastPathComponent()
        let journal = ["state.sqlite-wal", "state.sqlite-shm"].map { folder.appendingPathComponent($0) }
        #expect(journal.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "this build keeps the journal files")
        if earlierBuild { for file in journal { try FileManager.default.removeItem(at: file) } }
        let filler = disk.fill(leaving: Int64(leaving))
        let reopened = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        #expect(await reopened.state().events.count == saved.count)
        #expect(Set(await reopened.pending().map(\.id)) == Set(saved.map(\.id)), "unsent work stays queued")
        do { try await reopened.append(PrivateEvent(kind: .note, text: "no room"), deviceID: device); Issue.record("the disk is full") }
        catch { #expect(StorageSpace.isOutOfSpace(error), "\(error)") }
        disk.release(filler)
        try await reopened.append(PrivateEvent(kind: .note, text: "after space was freed"), deviceID: device)
        #expect(await reopened.state().events.count == saved.count + 1)
    }

    /// A PDF saved on a full disk: "out of space" with how much to free (it was "couldn’t be saved securely"), the
    /// papers already saved still read, no half-written file is left, and the same store saves it once space is freed.
    @Test func aPDFSavedOnAFullDiskSaysHowMuchToFreeAndKeepsTheOthers() async throws {
        guard let disk = SmallDisk() else { return }
        defer { disk.detach() }
        let folder = disk.root.appendingPathComponent("papers")
        let account = UUID(), key = ReaderCrypto.randomKey()
        let store = try DevicePaperStore(directory: folder, accountID: account, localKey: key)
        let first = Data("%PDF-1.7\nalready here\n%%EOF\n".utf8)
        let kept = try await store.install(pdf: first, sourceID: "2401.00001", revision: 1)
        let filler = disk.fill(leaving: 256 * 1024)
        let large = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 3 * 1024 * 1024)
        do { try await store.install(pdf: large, sourceID: "2401.00002", revision: 1); Issue.record("the disk is full") }
        catch let error as StorageFullError {
            #expect((error.needed ?? 0) >= 2 * 1024 * 1024, "about the shortfall: \(String(describing: error.needed))")
            #expect(error.localizedDescription.hasPrefix("This device is out of space. Free up "))
        }
        #expect(try await store.read(kept.identity) == first)
        #expect(await store.records().count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") }, "\(names)")
        disk.release(filler)
        let saved = try await store.install(pdf: large, sourceID: "2401.00002", revision: 1)
        #expect(try await store.read(saved.identity) == large)
    }

    /// The on-device model installed on a full disk: out of space (not "didn't match"), nothing half-installed or left
    /// in staging, and the same install succeeds once space is freed.
    @Test func theModelInstalledOnAFullDiskLeavesNothingHalfDone() async throws {
        guard let disk = SmallDisk() else { return }
        defer { disk.detach() }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("model-source-\(UUID().wire)")
        defer { try? FileManager.default.removeItem(at: source) }
        let weights = Data(repeating: 7, count: 4 * 1024 * 1024)
        var files: [DevicePDFModelPack.File] = []
        for (path, data) in [("device-models.json", Data("{}".utf8)), ("DeviceLayout.mlmodelc/weights/weight.bin", weights)] {
            let url = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            files.append(.init(path: path, size: Int64(data.count), sha256: Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()))
        }
        let pack = DevicePDFModelPack(lock: ["layout": String(repeating: "a", count: 64)], files: files.sorted { $0.path < $1.path })
        let store = DevicePDFModelStore(root: disk.root.appendingPathComponent("models"), pack: pack)
        let filler = disk.fill(leaving: 1024 * 1024)
        do { try await store.install(from: source); Issue.record("the disk is full") }
        catch { #expect(StorageSpace.isOutOfSpace(error), "\(error)") }
        #expect(store.installed == nil)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: disk.root.appendingPathComponent("models").path)) ?? []
        #expect(!left.contains { $0.hasPrefix(".staging-") }, "\(left)")
        disk.release(filler)
        try await store.install(from: source)
        #expect(store.installed != nil)
    }

    /// A temporary file a crash left behind (up to 64 MB) is removed when the store next opens.
    @Test func aCrashedWritesTemporaryFileIsSweptAtOpen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("papers-\(UUID().wire)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = UUID(), key = ReaderCrypto.randomKey()
        _ = try DevicePaperStore(directory: folder, accountID: account, localKey: key)
        let readers = folder.appendingPathComponent("readers")
        _ = try DeviceReaderStore(directory: readers, accountID: account, localKey: key)
        let leftovers = [folder.appendingPathComponent(".paper-abc.bin.\(UUID().wire).tmp"), readers.appendingPathComponent(".reader-abc.bin.\(UUID().wire).tmp")]
        for file in leftovers { try Data(repeating: 1, count: 1024).write(to: file) }
        _ = try DevicePaperStore(directory: folder, accountID: account, localKey: key)
        _ = try DeviceReaderStore(directory: readers, accountID: account, localKey: key)
        #expect(leftovers.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    /// A draft checkpoint on a full disk fails as out of space; the last saved draft is what reopens.
    @Test func aDraftSavedOnAFullDiskKeepsTheLastSavedText() async throws {
        guard let disk = SmallDisk() else { return }
        defer { disk.detach() }
        let path = disk.root.appendingPathComponent("account/state.sqlite")
        let account = UUID(), key = ReaderCrypto.randomKey(), keys = KeyBundle.generate(accountID: account)
        let store = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        let id = UUID()
        var draft = LocalDraft(id: id, revision: 1, textRevision: UUID(), text: "The first sentence.", editedAt: Date(), branchRevision: UUID())
        draft = try await store.saveDraft(draft)
        let filler = disk.fill(leaving: 8 * 1024)
        var failure: Error?
        for revision in 2..<400 {
            var next = draft
            next.revision = Int64(revision); next.textRevision = UUID()
            next.text = String(repeating: "More words typed while the disk was full. ", count: 1_000 + revision)
            do { draft = try await store.saveDraft(next) } catch { failure = error; break }
        }
        let error = try #require(failure, "the disk filled")
        #expect(StorageSpace.isOutOfSpace(error), "\(error)")
        let lastSaved = draft
        disk.release(filler)
        let reopened = try EncryptedStore(url: path, accountID: account, localKey: key, keys: keys)
        #expect(await reopened.snapshot().drafts.first { $0.id == id }?.text == lastSaved.text)
    }
}

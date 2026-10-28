import Foundation
import Testing
@testable import ScienceReaderCore

/// The staff test catalog's queue (docs/architecture/TEST_CATALOGS.md): a folder's PDFs added once, read one at a time
/// in order, paused and resumed, resumed after a relaunch, and a failure never stopping the rest.
@Suite struct TestCatalogQueueTests {
    private let catalog = UUID(uuidString: "7e57ca7a-0000-4000-8000-000000000001")!
    private func sha(_ n: Int) -> String { String(repeating: String(n % 10), count: 64) }
    private func files(_ names: [String]) -> [(name: String, sha256: String)] {
        names.enumerated().map { (name: $0.element, sha256: sha($0.offset + 1)) }
    }

    @Test func onlyStaffSeeIt() {
        #expect(!TestCatalogQueue.isAvailable(operatorRoles: []))
        #expect(!TestCatalogQueue.isAvailable(operatorRoles: ["reader", "tester"]))
        #expect(TestCatalogQueue.isAvailable(operatorRoles: ["owner"]))
        #expect(TestCatalogQueue.isAvailable(operatorRoles: ["support"]))
    }

    @Test func addsEveryFileFirstThenReadsInNameOrder() {
        var queue = TestCatalogQueue(catalogID: catalog, catalogName: "Neuro")
        queue.merge(files: files(["b.pdf", "a10.pdf", "a2.pdf"])) { _ in .absent }
        #expect(queue.items.map(\.name) == ["a2.pdf", "a10.pdf", "b.pdf"])
        #expect(queue.line == "Adding 1 of 3 to the library")
        var order: [String] = []
        while let step = queue.next {
            switch step {
            case .add(let item): order.append("add \(item.name)"); queue.set(item.sha256, .toRead)
            case .read(let item): order.append("read \(item.name)"); queue.set(item.sha256, .reading)
                #expect(queue.next == nil, "one reading at a time")
                #expect(queue.line.hasPrefix("Reading \(queue.readCount + 1) of 3"))
                queue.set(item.sha256, .read)
            }
        }
        #expect(order == ["add a2.pdf", "add a10.pdf", "add b.pdf", "read a2.pdf", "read a10.pdf", "read b.pdf"])
        #expect(queue.isFinished)
        #expect(queue.line == "Done · 3 of 3 read")
    }

    @Test func importingTheSameFolderAgainChangesNothingAndSkipsWhatIsAlreadyThere() {
        var queue = TestCatalogQueue(catalogID: catalog, catalogName: "Neuro")
        // One file is in this catalog already (read), one in another catalog, one in the library here but unread.
        let placement: (String) -> TestCatalogQueue.Placement = { sha in
            switch sha {
            case self.sha(1): .inCatalog(read: true)
            case self.sha(2): .elsewhere
            case self.sha(3): .inCatalog(read: false)
            default: .absent
            }
        }
        queue.merge(files: files(["1.pdf", "2.pdf", "3.pdf", "4.pdf"]), placement: placement)
        #expect(queue.items.map(\.status) == [.read, .skipped("Already in your library in another catalog"), .toRead, .toImport])
        #expect(queue.total == 3, "a paper elsewhere is not part of the test")
        let once = queue
        queue.merge(files: files(["4.pdf", "3.pdf", "2.pdf", "1.pdf"]), placement: placement)
        #expect(queue == once, "idempotent")
        // Two copies of the same PDF are one paper.
        queue.merge(files: files(["1.pdf", "2.pdf", "3.pdf", "4.pdf"]) + [(name: "4 copy.pdf", sha256: sha(4))], placement: placement)
        #expect(queue == once)
        #expect(queue.next == .add(queue.items[3]))
    }

    @Test func aFailureNeverStopsTheRestAndImportingAgainRetriesIt() {
        var queue = TestCatalogQueue(catalogID: catalog, catalogName: "Neuro")
        queue.merge(files: files(["a.pdf", "b.pdf", "c.pdf"])) { _ in .absent }
        queue.set(sha(1), .failed("This PDF couldn’t be opened. It may be damaged."))
        #expect(queue.next == .add(queue.items[1]))
        queue.set(sha(2), .toRead); queue.set(sha(3), .toRead)
        #expect(queue.next == .read(queue.items[1]))
        queue.set(sha(2), .failed("The on-device model couldn’t finish this paper (layout)."))
        #expect(queue.next == .read(queue.items[2]), "the next paper is read after a failure")
        #expect(queue.line == "Reading 3 of 3 with the on-device model")
        queue.set(sha(3), .read)
        #expect(queue.isFinished)
        #expect(queue.failures.map(\.name) == ["a.pdf", "b.pdf"])
        #expect(queue.line == "Done · 1 of 3 read")
        // Importing the folder again looks at the failures afresh.
        queue.merge(files: files(["a.pdf", "b.pdf", "c.pdf"])) { sha in sha == self.sha(1) ? .absent : .inCatalog(read: sha == self.sha(3)) }
        #expect(queue.items.map(\.status) == [.toImport, .toRead, .read])
    }

    @Test func pauseAndResume() {
        var queue = TestCatalogQueue(catalogID: catalog, catalogName: "Neuro")
        queue.merge(files: files(["a.pdf", "b.pdf"])) { _ in .inCatalog(read: false) }
        queue.set(sha(1), .reading)
        queue.pause()
        #expect(queue.paused)
        #expect(queue.status(sha(1)) == .toRead, "the interrupted reading starts again on Resume")
        #expect(queue.next == nil)
        #expect(queue.line == "Paused · 0 of 2 read")
        queue.resume()
        #expect(queue.next == .read(queue.items[0]))
    }

    @Test func resumesAfterARelaunchFromItsSealedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("test-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = Data(repeating: 7, count: 32)
        let store = try TestCatalogQueueStore(directory: directory, accountID: account, localKey: key)
        #expect(store.load() == nil)
        var queue = TestCatalogQueue(catalogID: catalog, catalogName: "Neuro", folderBookmark: Data([1, 2, 3]))
        queue.merge(files: files(["a.pdf", "b.pdf", "c.pdf"])) { _ in .inCatalog(read: false) }
        queue.set(sha(1), .read); queue.set(sha(2), .reading)
        try store.save(queue)
        // The file is sealed: no name or hash in the clear.
        let raw = try Data(contentsOf: directory.appendingPathComponent("queue.sealed"))
        #expect(raw.range(of: Data("b.pdf".utf8)) == nil)
        // The app stopped mid-reading: the next launch reads that paper again, then the rest, in order.
        let reopened = try #require(try TestCatalogQueueStore(directory: directory, accountID: account, localKey: key).load())
        #expect(reopened.status(sha(2)) == .toRead)
        #expect(reopened.next == .read(reopened.items[1]))
        #expect(reopened.folderBookmark == Data([1, 2, 3]))
        // Another account's key opens nothing.
        #expect(try TestCatalogQueueStore(directory: directory, accountID: UUID(), localKey: key).load() == nil)
        try store.save(nil)
        #expect(store.load() == nil)
    }
}

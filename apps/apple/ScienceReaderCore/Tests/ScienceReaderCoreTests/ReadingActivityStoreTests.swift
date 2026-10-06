import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct ReadingActivityStoreTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func entry(_ id: UUID = UUID(), opened: Date? = Date(timeIntervalSinceReferenceDate: 800_000_000), progress: Double? = 0.6) -> ReadingActivityEntry {
        ReadingActivityEntry(documentID: id, openedAt: opened, progress: progress,
                             locationKey: "\(id.uuidString)/artifact/manifest",
                             location: .init(blockIndex: 12, blockFraction: 0.25, blockHeight: 140, scrollY: 2_400))
    }

    @Test func activityRoundTripsSealedAndBoundToTheAccount() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = ReaderCrypto.randomKey()
        let saved = [entry(), entry(opened: nil, progress: nil)]
        try await ReadingActivityStore(directory: directory, accountID: account, localKey: key).save(saved)

        let disk = try Data(contentsOf: directory.appendingPathComponent(ReadingActivityStore.fileName))
        #expect(disk.range(of: Data(saved[0].documentID.uuidString.utf8)) == nil, "No plaintext identifiers on disk")
        #expect(disk.range(of: Data("blockFraction".utf8)) == nil)

        let reopened = try ReadingActivityStore(directory: directory, accountID: account, localKey: key)
        #expect(await reopened.load() == saved)
        // Another account, or another local key, reads nothing rather than another account's data.
        #expect(try await ReadingActivityStore(directory: directory, accountID: UUID(), localKey: key).load().isEmpty)
        #expect(try await ReadingActivityStore(directory: directory, accountID: account, localKey: ReaderCrypto.randomKey()).load().isEmpty)
    }

    @Test func missingOrCorruptFileStartsEmptyAndIsReplacedOnSave() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = ReaderCrypto.randomKey()
        let store = try ReadingActivityStore(directory: directory, accountID: account, localKey: key)
        #expect(await store.load().isEmpty)
        try await store.save([entry()])
        let url = directory.appendingPathComponent(ReadingActivityStore.fileName)
        var bytes = try Data(contentsOf: url); bytes[bytes.count - 1] ^= 1; try bytes.write(to: url)
        #expect(await store.load().isEmpty)
        let replacement = [entry()]
        try await store.save(replacement)
        #expect(await store.load() == replacement)
    }

    @Test func invalidValuesAreRejectedAndTheListIsBounded() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReadingActivityStore(directory: directory, accountID: UUID(), localKey: ReaderCrypto.randomKey())
        await #expect(throws: (any Error).self) { try await store.save([entry(progress: 1.5)]) }
        await #expect(throws: (any Error).self) { try await store.save([entry(progress: .nan)]) }
        let duplicate = UUID()
        await #expect(throws: (any Error).self) { try await store.save([entry(duplicate), entry(duplicate)]) }
        var unpaired = entry(); unpaired.location = nil
        await #expect(throws: (any Error).self) { try await store.save([unpaired]) }

        let limit = ReadingActivityStore.maximumEntries
        let many = (0...limit).map { entry(opened: Date(timeIntervalSinceReferenceDate: Double($0))) }
        try await store.save(many)
        let kept = await store.load()
        #expect(kept.count == limit)
        #expect(!kept.contains { $0.documentID == many[0].documentID }, "The least recently opened entry is dropped")
        #expect(throws: (any Error).self) { try ReadingActivityStore(directory: directory, accountID: UUID(), localKey: Data(count: 16)) }
    }
}

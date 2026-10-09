import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct DevicePaperStoreTests {
    private func fixture() throws -> (directory: URL, account: UUID, key: Data, pdf: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("papers-\(UUID().wire)", isDirectory: true)
        let pdf = Data("%PDF-1.7\nfixture with an equation: x^2\n%%EOF\n".utf8)
        return (directory, UUID(), ReaderCrypto.randomKey(), pdf)
    }

    @Test func installsReadsAndReopensEncryptedRevision() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        let row = try await store.install(pdf: f.pdf, sourceID: "2401.12345", revision: 3)
        #expect(row.identity.sha256 == Data(SHA256.hash(data: f.pdf)))
        #expect(try await store.read(row.identity) == f.pdf)
        #expect(await store.records() == [row])
        let files = try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
        for file in files {
            #expect(try Data(contentsOf: file).range(of: f.pdf) == nil)
        }
        let reopened = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        #expect(try await reopened.read(row.identity) == f.pdf)
        #expect(await reopened.generation() == 1) // reopening does not create a new local generation
    }

    @Test func duplicateExactRevisionIsIdempotentAndSubstitutionIsRejected() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        let first = try await store.install(pdf: f.pdf, sourceID: "2401.12345", revision: 1)
        let second = try await store.install(pdf: f.pdf, sourceID: "2401.12345", revision: 1)
        #expect(first == second)
        await #expect(throws: LocalPaperStoreError.revisionConflict) {
            try await store.install(pdf: Data("%PDF-1.7\nsubstituted\n%%EOF".utf8), sourceID: "2401.12345", revision: 1)
        }
        #expect(await store.records().count == 1)
    }

    @Test func rejectsNonPDFOversizeAndWrongExpectedHash() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        await #expect(throws: LocalPaperStoreError.invalidPDF) {
            try await store.install(pdf: Data("not a pdf".utf8), sourceID: "2401.12345", revision: 1)
        }
        await #expect(throws: LocalPaperStoreError.revisionConflict) {
            try await store.install(pdf: f.pdf, sourceID: "2401.12345", revision: 1, expectedSHA256: Data(repeating: 1, count: 32))
        }
        let tooLarge = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: Int(DevicePaperStore.maximumPaperBytes) + 1)
        await #expect(throws: LocalPaperStoreError.tooLarge) {
            try await store.install(pdf: tooLarge, sourceID: "2401.12345", revision: 1)
        }
    }

    @Test func corruptionAndTamperingAreDetected() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        let row = try await store.install(pdf: f.pdf, sourceID: "2401.12345", revision: 1)
        let blob = try #require(try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("paper-") }))
        var bytes = try Data(contentsOf: blob); bytes[bytes.index(bytes.startIndex, offsetBy: 32)] ^= 0xff
        try bytes.write(to: blob)
        await #expect(throws: LocalPaperStoreError.corruptData) { try await store.read(row.identity) }
        // Startup validates the manifest and file shape without reading every
        // large blob; the authenticated digest is checked when it is opened.
        let reopened = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        await #expect(throws: LocalPaperStoreError.corruptData) { try await reopened.read(row.identity) }
    }

    @Test func removesRowsAndPrunesAuthenticatedOrphans() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let store = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        let row = try await store.install(pdf: f.pdf, sourceID: "2401.12345", revision: 1)
        let orphan = f.directory.appendingPathComponent("paper-00000000-0000-0000-0000-000000000001.bin")
        try Data([1, 2, 3]).write(to: orphan)
        try await store.remove(row.identity)
        #expect(await store.records().isEmpty)
        let reopened = try DevicePaperStore(directory: f.directory, accountID: f.account, localKey: f.key)
        #expect(await reopened.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }
}

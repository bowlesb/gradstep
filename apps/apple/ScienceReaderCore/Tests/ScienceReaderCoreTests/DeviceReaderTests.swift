import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct DeviceReaderTests {
    private func fixture(_ name: String = "package.json") throws -> VerifiedReaderBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/\(name)")))
    }
    @Test func extendedFiguresHaveIndependentNativeProvenanceAdmission() throws {
        let bundle = try fixture("figures-package.json")
        #expect(bundle.manifest.renderer.id == "gradstep-arxiv-html-mathml-v2")
        #expect(bundle.index.figures.count == 4)
        #expect(bundle.index.figures.last?.assetPaths.count == 2)
        #expect(bundle.index.blocks.last?.text.contains("Retained legend text") == true)
        #expect(try DeviceReaderPackage.decode(DeviceReaderPackage.encode(bundle)).manifestSHA256 == bundle.manifestSHA256)
    }
    @Test func sharedHTMLFixtureUsesExactRevisionAndManifestAnchors() throws {
        let bundle = try fixture()
        #expect(bundle.arxivSource == (try ArxivReaderSource(sourceID: "2601.01234", revision: 2)))
        #expect(bundle.index.equations.count == 2)
        #expect(try DeviceReaderPackage.decode(DeviceReaderPackage.encode(bundle)).manifestSHA256 == bundle.manifestSHA256)
        let ref = try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2)
        let context = try LocalPaperChatContext(reference: ref, bundle: bundle)
        let data = try JSONEncoder().encode(context)
        #expect(String(decoding: data, as: UTF8.self).contains("reader-local-context-v2"))
        // The numbered context is byte-identical to the browser's (shared golden fixture).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let golden = try String(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/local-context-v2.txt"), encoding: .utf8)
        #expect(context.text == golden)
        let figures = try fixture("figures-package.json")
        let figuresGolden = try String(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/figures-local-context-v2.txt"), encoding: .utf8)
        #expect(PaperChatContext.text(figures.index) == figuresGolden)
        #expect(PaperChatContext.citedBlock(bundle.index, marker: 1)?.kind == "heading")
        #expect(PaperChatContext.citedBlock(bundle.index, marker: 12) == nil)
        #expect(PaperChatContext.citedMarker("¶12") == 12); #expect(PaperChatContext.citedMarker("b-1") == nil); #expect(PaperChatContext.citedMarker("¶0") == nil)
        let wrong = try SourcePaperReference(membershipID: ref.membershipID, sourceID: ref.sourceID, revision: 1)
        #expect(throws: (any Error).self) { try LocalPaperChatContext(reference: wrong, bundle: bundle) }
    }
    @Test func sourceIdentityRequiresNewAuthenticatedEnvelopeWithoutFakeDocument() throws {
        let ref = try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2)
        let event = PrivateEvent(kind: .note, text: "A note", paperReference: ref)
        let json = try #require(JSONSerialization.jsonObject(with: ReaderCrypto.encode(event)) as? [String: Any])
        #expect(json["documentID"] == nil)
        #expect(event.documentID == ref.membershipID)
        let keys = KeyBundle.generate(accountID: UUID())
        let sealed = try ReaderCrypto.seal(event, id: UUID(), deviceID: UUID(), keys: keys)
        #expect(sealed.format == 2)
        #expect(try ReaderCrypto.open(sealed, keys: keys) == event)
        let downgraded = EventEnvelope(id: sealed.id, deviceID: sealed.deviceID, epoch: sealed.epoch, format: 1, ciphertext: sealed.ciphertext)
        #expect(throws: (any Error).self) { try ReaderCrypto.open(downgraded, keys: keys) }
    }
    @Test func encryptedDeviceBundleSurvivesReopenAndRejectsOtherAccount() async throws {
        let bundle = try fixture(), account = UUID(), key = ReaderCrypto.randomKey()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("html-reader-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DeviceReaderStore(directory: dir, accountID: account, localKey: key)
        let record = try await store.install(bundle: bundle)
        #expect(try await store.read(record.identity).manifestSHA256 == bundle.manifestSHA256)
        #expect(try await store.install(bundle: bundle) == record)
        let reopened = try DeviceReaderStore(directory: dir, accountID: account, localKey: key)
        #expect(try await reopened.read(record.identity).manifestSHA256 == bundle.manifestSHA256)
        #expect(throws: (any Error).self) { try DeviceReaderStore(directory: dir, accountID: UUID(), localKey: key) }
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: Data("Authored HTML fixture".utf8)) == nil)
        }
        try await reopened.remove(record.identity)
        #expect(await reopened.records().isEmpty)
    }
    @Test func localPDFMembershipStaysEncryptedAndHasNoServerDocument() throws {
        let membership = try LocalPDFMembership(title: "My private PDF", pageCount: 3, createdAt: 1234)
        let event = PrivateEvent(kind: .localPaper, text: try membership.text())
        let keys = KeyBundle.generate(accountID: UUID())
        let sealed = try ReaderCrypto.seal(event, id: UUID(), deviceID: UUID(), keys: keys)
        #expect(sealed.format == 2)
        #expect(try LocalPDFMembership.decode(ReaderCrypto.open(sealed, keys: keys)) == membership)
        #expect(sealed.ciphertext.range(of: Data(membership.title.utf8)) == nil)
        #expect(event.documentID == nil)
    }
}

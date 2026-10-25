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
    /// The on-device model's reading of an arXiv paper's PDF is that paper's text for its chat and explainers, as the
    /// HTML reading is: the same membership, the reading's own numbered index and manifest (TestFlight 90 follow-up).
    @Test func anOnDeviceModelReadingOfTheSameRevisionIsThePapersContext() throws {
        let html = try fixture()
        let reading = try Self.devicePDFBundle(index: html.index, paper: (sourceID: "2601.01234", revision: 2))
        #expect(reading.arxivSource == nil)
        #expect(reading.devicePDFArxivSource == (try ArxivReaderSource(sourceID: "2601.01234", revision: 2)))
        let ref = try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2)
        let context = try LocalPaperChatContext(reference: ref, bundle: reading)
        #expect(context.manifestSHA256 == reading.manifestSHA256)
        #expect(context.sourceSHA256 == reading.manifest.source.sha256)
        #expect(context.text == PaperChatContext.text(reading.index))
        #expect(context.sourceID == "2601.01234" && context.revision == 2)
        // Another paper, or a PDF the reader added (no arXiv paper): not this membership's text.
        let otherPaper = try Self.devicePDFBundle(index: html.index, paper: (sourceID: "2601.04321", revision: 2))
        #expect(throws: (any Error).self) { try LocalPaperChatContext(reference: ref, bundle: otherPaper) }
        let added = try Self.devicePDFBundle(index: html.index, paper: nil)
        #expect(added.devicePDFArxivSource == nil)
        #expect(throws: (any Error).self) { try LocalPaperChatContext(reference: ref, bundle: added) }
    }

    /// The device reads the paper's PDF it has, which may be another arXiv revision than the library's (a v1 kept while the
    /// library moved to v2): its explainers and chat still have the reading's text, and the request names the membership
    /// as it is, so the server authorizes it unchanged (TestFlight 91 known gap). An HTML reading stays exact.
    @Test func anOnDeviceModelReadingOfAnotherRevisionIsThePapersContext() throws {
        let html = try fixture()
        let reading = try Self.devicePDFBundle(index: html.index, paper: (sourceID: "2601.01234", revision: 1))
        let membership = try SourcePaperReference(membershipID: UUID(), sourceID: "2601.01234", revision: 2)
        let context = try LocalPaperChatContext(reference: membership, bundle: reading)
        #expect(context.source == "arxiv" && !context.isOwnPDF)
        #expect(context.sourceID == "2601.01234" && context.revision == 2 && context.membershipID == membership.membershipID.wire)
        #expect(context.text == PaperChatContext.text(reading.index) && context.manifestSHA256 == reading.manifestSHA256)
        let wire = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        #expect(Set(wire.keys) == ["format", "membership_id", "source", "source_id", "revision", "manifest_sha256", "source_sha256", "text"])
        #expect(wire["revision"] as? Int == 2)
        // The HTML reading of v2 is not v1's.
        let older = try SourcePaperReference(membershipID: membership.membershipID, sourceID: "2601.01234", revision: 1)
        #expect(throws: (any Error).self) { try LocalPaperChatContext(reference: older, bundle: html) }
    }

    /// A PDF the reader added, read by the on-device model: its explainers and chat send the reading's numbered text and
    /// nothing that names the paper (no id, title, or digest of the PDF or the reading); the server has no membership to
    /// authorize (TestFlight 91 known gap).
    @Test func anOnDeviceModelReadingOfTheReadersOwnPDFSendsOnlyItsText() throws {
        let html = try fixture()
        let paperID = UUID()
        let reading = try Self.devicePDFBundle(index: html.index, paper: (sourceID: LocalPDFMembership.sourceID(paperID), revision: 1))
        let context = try LocalPaperChatContext(ownPDF: paperID, bundle: reading)
        #expect(context.isOwnPDF && context.membershipID == paperID.wire)
        #expect(context.text == PaperChatContext.text(reading.index))
        let data = try JSONEncoder().encode(context)
        let wire = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(wire.keys) == ["format", "source", "text"])
        #expect(wire["format"] as? String == "reader-local-context-v2" && wire["source"] as? String == "local")
        let sent = String(decoding: data, as: UTF8.self)
        for secret in [paperID.wire, reading.manifestSHA256, reading.manifest.source.sha256] { #expect(!sent.contains(secret)) }
        // Another of the reader's PDFs, an arXiv paper's reading, or an HTML reading: not this paper's text.
        #expect(throws: (any Error).self) { try LocalPaperChatContext(ownPDF: UUID(), bundle: reading) }
        let arxiv = try Self.devicePDFBundle(index: html.index, paper: (sourceID: "2601.01234", revision: 2))
        #expect(throws: (any Error).self) { try LocalPaperChatContext(ownPDF: paperID, bundle: arxiv) }
        #expect(throws: (any Error).self) { try LocalPaperChatContext(ownPDF: paperID, bundle: html) }
        // The paper explainer's request carries it as the paper (mode `paper`, no document).
        let request = try ChatGenerationRequest.paperExplainer(operationID: UUID(), profile: .standard, localContext: context, visualAnswers: true)
        let body = try #require(try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(body["mode"] as? String == "paper" && body["document_id"] == nil)
        #expect((body["local_context"] as? [String: Any]).map { Set($0.keys) } == ["format", "source", "text"])
    }

    /// A minimal verified reading in the on-device model's format (`gradstep-device-pdf-mathml-v1`), with `index` as its
    /// index and the library paper named in its provenance.
    static func devicePDFBundle(index: ReaderBundleIndex, paper: (sourceID: String, revision: Int)?) throws -> VerifiedReaderBundle {
        let pdf = String(repeating: "b", count: 64), build = String(repeating: "a", count: 64)
        let html = Data("<!doctype html><html><body><p>reading</p></body></html>".utf8)
        // The index without its figure entries, whose images this minimal reading doesn't carry (the blocks stay).
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as? [String: Any])
        object["figures"] = []
        let indexData = try JSONSerialization.data(withJSONObject: object)
        let named = paper.map { ",\"paper\":{\"source_id\":\"\($0.sourceID)\",\"revision\":\($0.revision)}" } ?? ""
        let provenance = Data(("{\"format\":\"device-pdf-reader-provenance-v1\",\"source\":{\"kind\":\"device-pdf\",\"pdf_sha256\":\"\(pdf)\"\(named)},"
            + "\"adapter\":{\"id\":\"gradstep-device-pdf-mathml-v1\",\"build_sha256\":\"\(build)\"}}").utf8)
        let members: [(path: String, role: String, type: String, data: Data)] = [
            ("index.html", "html", "text/html", html), ("reader.json", "index", "application/json", indexData),
            ("provenance.json", "provenance", "application/json", provenance)]
        let rows = members.map { "{\"path\":\"\($0.path)\",\"role\":\"\($0.role)\",\"media_type\":\"\($0.type)\",\"bytes\":\($0.data.count),\"sha256\":\"\(VerifiedReaderBundle.digest($0.data))\"}" }
        let manifest = Data(("{\"format\":\"reader-bundle-v1\",\"renderer\":{\"id\":\"gradstep-device-pdf-mathml-v1\",\"build_sha256\":\"\(build)\"},"
            + "\"source\":{\"kind\":\"device-pdf\",\"sha256\":\"\(pdf)\",\"provenance_path\":\"provenance.json\"},"
            + "\"entrypoint\":\"index.html\",\"index_path\":\"reader.json\",\"members\":[\(rows.joined(separator: ","))]}").utf8)
        return try VerifiedReaderBundle.verify(manifest: manifest, expectedSHA256: VerifiedReaderBundle.digest(manifest),
                                               members: Dictionary(uniqueKeysWithValues: members.map { ($0.path, $0.data) }))
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
    /// Revision 16 lists captioned tables in the index (`tables`, optional): an earlier bundle reads without them; a
    /// list names table blocks once, each with a caption (validate.ts agrees).
    @Test func indexTablesAreOptionalAndNameTableBlocks() throws {
        let bundle = try fixture()
        #expect(bundle.index.tables == nil)
        let table = try #require(bundle.index.blocks.first { $0.kind == "table" })
        let paragraph = try #require(bundle.index.blocks.first { $0.kind == "paragraph" })
        func resigned(_ tables: [[String: String]]) throws -> VerifiedReaderBundle {
            var members = Dictionary(uniqueKeysWithValues: bundle.manifest.members.map { ($0.path, bundle.data(for: $0.path)!) })
            var index = try #require(JSONSerialization.jsonObject(with: members[bundle.manifest.indexPath]!) as? [String: Any])
            index["tables"] = tables
            members[bundle.manifest.indexPath] = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .withoutEscapingSlashes])
            var manifest = try #require(JSONSerialization.jsonObject(with: bundle.manifestData) as? [String: Any])
            manifest["members"] = (manifest["members"] as! [[String: Any]]).map { member in
                var member = member; let data = members[member["path"] as! String]!
                member["sha256"] = VerifiedReaderBundle.digest(data); member["bytes"] = data.count
                return member
            }
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
            return try VerifiedReaderBundle.verify(manifest: manifestData, expectedSHA256: VerifiedReaderBundle.digest(manifestData), members: members)
        }
        let listed = try resigned([["id": table.id, "caption": "Table 1: Values."]])
        #expect(listed.index.tables == [ReaderBundleIndex.Table(id: table.id, caption: "Table 1: Values.")])
        #expect(throws: ReaderBundleError.invalidIndex) { try resigned([["id": paragraph.id, "caption": "Table 9: Not a table."]]) }
        #expect(throws: ReaderBundleError.invalidIndex) { try resigned([["id": table.id, "caption": " "]]) }
        #expect(throws: ReaderBundleError.invalidIndex) { try resigned([["id": table.id, "caption": "A"], ["id": table.id, "caption": "B"]]) }
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

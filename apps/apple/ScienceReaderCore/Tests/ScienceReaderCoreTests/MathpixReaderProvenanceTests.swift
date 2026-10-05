import Foundation
import Testing
@testable import ScienceReaderCore

struct MathpixReaderProvenanceTests {
    private struct Fixture {
        // Synthetic byte-integrity fixture, not a provider capture or HTML render.
        static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAYAAAB3AH1ZAAAAIklEQVR42u3OIQEAAAACIP+f1hkWAp0k7ZeAgICAgIDAOTDcxPwukNxH3wAAAABJRU5ErkJggg==")!
        static let imageSHA = VerifiedReaderBundle.digest(png)
        static let imagePath = "assets/" + imageSHA + ".png"
        static let sourceSHA = VerifiedReaderBundle.digest(Data("\\title{Synthetic}\n\n\\(x^2\\)\n".utf8))
        static let build = String(repeating: "a", count: 64)
        var renderer = "timestep-mathpix-mathml-v1"
        var sourceKind = "mathpix-mmd"
        var mediaType = "image/png"
        var overrideProvenance: Data?
        var provenance: [String: Any] = [
            "format": "mathpix-reader-provenance-v2",
            "ocr": ["api": "v3/pdf", "profile": "science-reader-mmd-v1", "options_sha256": MathpixReaderProvenance.optionsSHA256],
            "provider_job_id": "synthetic-job_1",
            "document": ["sha256": String(repeating: "d", count: 64), "page_count": 1],
            "source": ["archive_path": "paper/main.mmd", "bytes": 23, "sha256": sourceSHA],
            "renderer": ["id": "timestep-mathpix-mathml-v1", "build_sha256": build],
            "image_inputs": [["archive_path": "paper/images/figure.png", "input_sha256": String(repeating: "c", count: 64),
                "published_path": imagePath, "published_sha256": imageSHA, "media_type": "image/png", "width": 32, "height": 16]]]
        var index: [String: Any] = ["format": "reader-index-v1", "title": "Synthetic Mathpix-shaped result",
            "headings": [], "blocks": [["id": "figure", "kind": "figure", "text": "Synthetic figure"]], "equations": [],
            "figures": [["id": "figure", "block_id": "figure", "asset_paths": [imagePath], "caption": "Synthetic figure", "alt": "A blue rectangle"]]]

        func encodedProvenance() throws -> Data {
            try JSONSerialization.data(withJSONObject: provenance, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
        }
        func package() throws -> (manifest: Data, members: [String: Data]) {
            let members = ["index.html": Data("<figure>Fixture</figure>".utf8),
                "reader.json": try JSONSerialization.data(withJSONObject: index, options: .sortedKeys),
                "provenance.json": try overrideProvenance ?? encodedProvenance(), Self.imagePath: Self.png]
            let roles = ["index.html": "html", "reader.json": "index", "provenance.json": "provenance", Self.imagePath: "image"]
            let types = ["html": "text/html", "index": "application/json", "provenance": "application/json", "image": mediaType]
            let entries = members.keys.sorted().map { path -> [String: Any] in
                let bytes = members[path]!, role = roles[path]!
                var entry: [String: Any] = ["path": path, "role": role, "media_type": types[role]!, "bytes": bytes.count,
                    "sha256": VerifiedReaderBundle.digest(bytes)]
                if role == "image" { entry["width"] = 32; entry["height"] = 16 }
                return entry
            }
            let manifest: [String: Any] = ["format": "reader-bundle-v1", "renderer": ["id": renderer, "build_sha256": Self.build],
                "source": ["kind": sourceKind, "sha256": Self.sourceSHA, "provenance_path": "provenance.json"],
                "entrypoint": "index.html", "index_path": "reader.json", "members": entries]
            return (try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys), members)
        }
        func verify() throws -> VerifiedReaderBundle {
            let value = try package()
            return try VerifiedReaderBundle.verify(manifest: value.manifest, expectedSHA256: VerifiedReaderBundle.digest(value.manifest), members: value.members)
        }
        mutating func change(_ key: String, _ name: String, _ value: Any) {
            var section = provenance[key] as! [String: Any]; section[name] = value; provenance[key] = section
        }
        mutating func changeImage(_ name: String, _ value: Any) {
            var rows = provenance["image_inputs"] as! [[String: Any]]; rows[0][name] = value; provenance["image_inputs"] = rows
        }
    }

    @Test func newProfileLoadsFromOwnedMemoryAndDirectory() throws {
        let fixture = Fixture(), value = try fixture.package(), memory = try fixture.verify()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try value.manifest.write(to: directory.appendingPathComponent("manifest.json"))
        for (path, bytes) in value.members {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let disk = try VerifiedReaderBundle.load(directory: directory, expectedSHA256: memory.manifestSHA256)
        #expect(disk.manifestData == memory.manifestData)
        #expect(disk.data(for: "provenance.json") == value.members["provenance.json"])
        #expect(disk.data(for: Fixture.imagePath) == Fixture.png)
    }

    @Test func onlyExactRendererSourcePairsAreCompatibleAndAuthoredProvenanceIsUnchanged() throws {
        for (renderer, kind) in [("timestep-mmd-v1", "mathpix-mmd"), ("timestep-mathpix-mathml-v1", "authored-mmd"),
                                 ("timestep-mathpix-mmd-v1", "mathpix-mmd"), ("new-renderer", "mathpix-mmd"),
                                 ("timestep-mathpix-mathml-v1", "new-source")] {
            var fixture = Fixture(); fixture.renderer = renderer; fixture.sourceKind = kind
            #expect(throws: ReaderBundleError.incompatibleFormat) { try fixture.verify() }
        }
        var authored = Fixture(); authored.renderer = "timestep-mmd-v1"; authored.sourceKind = "authored-mmd"
        authored.overrideProvenance = Data("{\"legacy_authored_shape\":true}".utf8)
        #expect(try authored.verify().data(for: "provenance.json") == authored.overrideProvenance)
    }

    @Test func rehashingCannotHideWrongSourceRendererOptionsOrOriginalBounds() throws {
        let changes: [(String, String, Any)] = [
            ("source", "sha256", String(repeating: "e", count: 64)), ("source", "bytes", 2_097_153),
            ("source", "bytes", 0), ("source", "bytes", true),
            ("document", "page_count", 0), ("document", "page_count", 251), ("document", "page_count", true),
            ("document", "page_count", 1.5), ("document", "sha256", String(repeating: "G", count: 64)),
            ("ocr", "api", "v3/text"), ("ocr", "profile", "future-profile"),
            ("ocr", "options_sha256", String(repeating: "a", count: 64)),
            ("renderer", "id", "timestep-mathpix-mmd-v1"), ("renderer", "build_sha256", String(repeating: "b", count: 64))]
        for (section, name, value) in changes {
            var fixture = Fixture(); fixture.change(section, name, value)
            #expect(throws: ReaderBundleError.invalidResource) { try fixture.verify() }
        }
        for job in ["", "job/../x", String(repeating: "j", count: 161), "job id"] {
            var fixture = Fixture(); fixture.provenance["provider_job_id"] = job
            #expect(throws: ReaderBundleError.invalidResource) { try fixture.verify() }
        }
    }

    @Test func provenanceObjectsAreClosedCanonicalAndBounded() throws {
        var extraRoot = Fixture(); extraRoot.provenance["raw_result_sha256"] = String(repeating: "c", count: 64)
        #expect(throws: ReaderBundleError.invalidResource) { try extraRoot.verify() }
        var oldFormat = Fixture(); oldFormat.provenance["format"] = "mathpix-reader-provenance-v1"
        #expect(throws: ReaderBundleError.invalidResource) { try oldFormat.verify() }
        for section in ["document", "ocr", "source", "renderer"] {
            var fixture = Fixture(); fixture.change(section, "unexpected", true)
            #expect(throws: ReaderBundleError.invalidResource) { try fixture.verify() }
        }
        var extraImage = Fixture(); extraImage.changeImage("unexpected", true)
        #expect(throws: ReaderBundleError.invalidResource) { try extraImage.verify() }
        let raw = try Fixture().encodedProvenance()
        let duplicate = Data(("{\"format\":\"mathpix-reader-provenance-v2\"," + String(decoding: raw.dropFirst(), as: UTF8.self)).utf8)
        for bytes in [raw.dropLast(), raw + Data([10]), duplicate] {
            var fixture = Fixture(); fixture.overrideProvenance = Data(bytes)
            #expect(throws: ReaderBundleError.invalidResource) { try fixture.verify() }
        }
        var oversized = Fixture(); oversized.overrideProvenance = Data(repeating: 32, count: 262_145)
        #expect(throws: ReaderBundleError.invalidManifest) { try oversized.verify() }
    }

    @Test func archivePathsAreCanonicalIdentitiesAndNeverURLs() throws {
        for path in ["../paper.mmd", "/paper.mmd", "paper//main.mmd", "paper/./main.mmd", "paper/%2e.mmd",
                     "paper\\main.mmd", "https://example.test/main.mmd", "paper/main.mmd?token=x", "paper/main.mmd#x",
                     "paper/CON.mmd", "a/b/c/d/e/f/g/h/i.mmd", "paper/main.MMD", "paper/main.mmd."] {
            var fixture = Fixture(); fixture.change("source", "archive_path", path)
            #expect(throws: ReaderBundleError.invalidResource) { try fixture.verify() }
        }
        var valid = Fixture(); valid.change("source", "archive_path", "_paper-v1/main.mmd")
        #expect(try valid.verify().manifest.source.kind == "mathpix-mmd")
    }

    @Test func imageInputsBindPublishedTypeHashAndDimensions() throws {
        let original = Fixture().provenance["image_inputs"] as! [[String: Any]]
        var alias = original[0]; alias["archive_path"] = "paper/images/second.png"
        var fixture = Fixture(); fixture.provenance["image_inputs"] = original + [alias]
        #expect(try fixture.verify().manifest.members.filter { $0.role == "image" }.count == 1)
        for rows in [[alias] + original, original + original, [], Array(repeating: original[0], count: 513)] {
            var broken = Fixture(); broken.provenance["image_inputs"] = rows
            #expect(throws: ReaderBundleError.invalidResource) { try broken.verify() }
        }
        let changes: [(String, Any)] = [("archive_path", "../outside.png"), ("archive_path", "paper/main.mmd"),
            ("input_sha256", "not-a-digest"), ("published_path", "figure.png"),
            ("published_path", "assets/" + Fixture.imageSHA + ".jpg"), ("published_sha256", String(repeating: "f", count: 64)),
            ("media_type", "image/jpeg"), ("media_type", "image/gif"), ("width", 31), ("height", 17), ("width", true)]
        for (name, value) in changes {
            var broken = Fixture(); broken.changeImage(name, value)
            #expect(throws: ReaderBundleError.invalidResource) { try broken.verify() }
        }
        var unreferenced = Fixture(); unreferenced.index["figures"] = [] as [Any]
        #expect(throws: ReaderBundleError.invalidResource) { try unreferenced.verify() }
        var missingDescription = Fixture()
        var figures = missingDescription.index["figures"] as! [[String: Any]]; figures[0]["alt"] = ""
        missingDescription.index["figures"] = figures
        #expect(throws: ReaderBundleError.invalidResource) { try missingDescription.verify() }
        // JPEG members are admitted only for this renderer, never the authored sample.
        var gif = Fixture(); gif.mediaType = "image/gif"
        #expect(throws: ReaderBundleError.invalidManifest) { try gif.verify() }
        var authoredJPEG = Fixture(); authoredJPEG.renderer = "timestep-mmd-v1"; authoredJPEG.sourceKind = "authored-mmd"
        authoredJPEG.mediaType = "image/jpeg"; authoredJPEG.overrideProvenance = Data("{}".utf8)
        #expect(throws: ReaderBundleError.invalidManifest) { try authoredJPEG.verify() }
    }

    /// The committed app fixture was produced by the Edge renderer from the
    /// real DPO Mathpix capture (arXiv 2305.18290, CC BY 4.0).
    @Test func realRendererOutputIsAdmittedWithItsLargerProfile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ScienceReader/Resources/ReaderSamples/" + Self.dpoManifestSHA256)
        let bundle = try VerifiedReaderBundle.load(directory: root.resolvingSymlinksInPath(), expectedSHA256: Self.dpoManifestSHA256)
        #expect(bundle.manifest.renderer.id == "timestep-mathpix-mathml-v1")
        #expect(bundle.index.equations.count == 270)
        #expect(bundle.index.equations.count > ReaderProfile.authored.equations / 2)
        #expect(bundle.index.figures.count == 4)
        #expect(bundle.manifest.members.filter { $0.role == "image" }.allSatisfy { $0.mediaType == "image/jpeg" })
        for member in bundle.manifest.members where member.role == "image" {
            try ReaderJPEGValidator.validate(try #require(bundle.data(for: member.path)), width: member.width!, height: member.height!)
        }
        let equation = try #require(bundle.index.equations.first { $0.display })
        let selection = ReaderSelection(manifestSHA256: bundle.manifestSHA256, parts: [.init(kind: "equation", blockID: equation.blockID, equationID: equation.id)])
        #expect(try selection.resolvedQuote(in: bundle).hasPrefix("\\[\\begin{equation*}"))
    }
    static let dpoManifestSHA256 = "a6ca6825b3c112f591b884ebd648b9d85785544050da3444f91ae9e7f2bed695"
}

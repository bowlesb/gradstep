import Foundation
import Testing
@testable import ScienceReaderCore

struct MathpixReaderProvenanceTests {
    private struct Fixture {
        // Synthetic byte-integrity fixture, not a provider capture or HTML render.
        static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAYAAAB3AH1ZAAAAIklEQVR42u3OIQEAAAACIP+f1hkWAp0k7ZeAgICAgIDAOTDcxPwukNxH3wAAAABJRU5ErkJggg==")!
        static let inputSHA = VerifiedReaderBundle.digest(png)
        static let imagePath = "assets/" + inputSHA + ".png"
        static let sourceSHA = VerifiedReaderBundle.digest(Data("# Synthetic\n\n$$x^2$$\n".utf8))
        var renderer = "timestep-mathpix-mmd-v1"
        var sourceKind = "mathpix-mmd"
        var overrideProvenance: Data?
        var provenance: [String: Any] = [
            "format": "mathpix-reader-provenance-v1", "raw_result_sha256": String(repeating: "c", count: 64),
            "document": ["sha256": String(repeating: "d", count: 64), "bytes": 1024, "page_count": 1],
            "ocr": ["api": "v3/pdf", "profile": "science-reader-mmd-v1", "options_sha256": MathpixReaderProvenance.optionsSHA256],
            "source": ["archive_path": "paper/main.mmd", "bytes": 23, "sha256": sourceSHA],
            "image_inputs": [["archive_path": "paper/images/figure.png", "input_sha256": inputSHA,
                "published_path": imagePath, "published_sha256": inputSHA, "width": 32, "height": 16]]]
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
            let types = ["html": "text/html", "index": "application/json", "provenance": "application/json", "image": "image/png"]
            let entries = members.keys.sorted().map { path -> [String: Any] in
                let bytes = members[path]!, role = roles[path]!
                var entry: [String: Any] = ["path": path, "role": role, "media_type": types[role]!, "bytes": bytes.count,
                    "sha256": VerifiedReaderBundle.digest(bytes)]
                if role == "image" { entry["width"] = 32; entry["height"] = 16 }
                return entry
            }
            let manifest: [String: Any] = ["format": "reader-bundle-v1", "renderer": ["id": renderer, "build_sha256": String(repeating: "a", count: 64)],
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
        for (renderer, kind) in [("timestep-mmd-v1", "mathpix-mmd"), ("timestep-mathpix-mmd-v1", "authored-mmd"),
                                 ("new-renderer", "mathpix-mmd"), ("timestep-mathpix-mmd-v1", "new-source")] {
            var fixture = Fixture(); fixture.renderer = renderer; fixture.sourceKind = kind
            #expect(throws: ReaderBundleError.incompatibleFormat) { try fixture.verify() }
        }
        var authored = Fixture(); authored.renderer = "timestep-mmd-v1"; authored.sourceKind = "authored-mmd"
        authored.overrideProvenance = Data("{\"legacy_authored_shape\":true}".utf8)
        #expect(try authored.verify().data(for: "provenance.json") == authored.overrideProvenance)
    }

    @Test func rehashingCannotHideWrongSourceOptionsOrOriginalBounds() throws {
        let changes: [(String, String, Any)] = [
            ("source", "sha256", String(repeating: "e", count: 64)), ("source", "bytes", 262_145),
            ("source", "bytes", 0), ("source", "bytes", true),
            ("document", "bytes", 7), ("document", "bytes", 33_554_433),
            ("document", "page_count", 0), ("document", "page_count", 251), ("document", "page_count", true),
            ("document", "page_count", 1.5), ("document", "sha256", String(repeating: "G", count: 64)),
            ("ocr", "api", "v3/text"), ("ocr", "profile", "future-profile"),
            ("ocr", "options_sha256", String(repeating: "a", count: 64))]
        for (section, name, value) in changes {
            var fixture = Fixture(); fixture.change(section, name, value)
            #expect(throws: ReaderBundleError.invalidResource) { try fixture.verify() }
        }
    }

    @Test func provenanceObjectsAreClosedCanonicalAndBounded() throws {
        var extraRoot = Fixture(); extraRoot.provenance["provider_job_id"] = "private-provider-detail"
        #expect(throws: ReaderBundleError.invalidResource) { try extraRoot.verify() }
        for section in ["document", "ocr", "source"] {
            var fixture = Fixture(); fixture.change(section, "unexpected", true)
            #expect(throws: ReaderBundleError.invalidResource) { try fixture.verify() }
        }
        var extraImage = Fixture(); extraImage.changeImage("unexpected", true)
        #expect(throws: ReaderBundleError.invalidResource) { try extraImage.verify() }
        let raw = try Fixture().encodedProvenance()
        let duplicate = Data(("{\"format\":\"mathpix-reader-provenance-v1\"," + String(decoding: raw.dropFirst(), as: UTF8.self)).utf8)
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

    @Test func imageAliasesPreserveCompleteSortedMappingAndManifestFacts() throws {
        let original = Fixture().provenance["image_inputs"] as! [[String: Any]]
        var alias = original[0]; alias["archive_path"] = "paper/images/second.png"
        var fixture = Fixture(); fixture.provenance["image_inputs"] = original + [alias]
        #expect(try fixture.verify().manifest.members.filter { $0.role == "image" }.count == 1)
        for rows in [[alias] + original, original + original, [], Array(repeating: original[0], count: 129)] {
            var broken = Fixture(); broken.provenance["image_inputs"] = rows
            #expect(throws: ReaderBundleError.invalidResource) { try broken.verify() }
        }
        let changes: [(String, Any)] = [("archive_path", "../outside.png"), ("archive_path", "paper/main.mmd"),
            ("input_sha256", String(repeating: "f", count: 64)),
            ("published_path", "figure.png"), ("published_sha256", String(repeating: "f", count: 64)),
            ("width", 31), ("height", 17), ("width", true)]
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
    }
}

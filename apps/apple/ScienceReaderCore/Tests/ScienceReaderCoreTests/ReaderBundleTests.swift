import Foundation
import Testing
@testable import ScienceReaderCore

struct ReaderBundleTests {
    private struct Fixture {
        var index: [String: Any] = ["format": "reader-index-v1", "title": "Authored sample",
            "headings": [["id": "b-heading", "level": 1, "title": "Sample"]],
            "blocks": [["id": "b-heading", "kind": "heading", "text": "Sample"],
                       ["id": "b-one", "kind": "paragraph", "text": "First"],
                       ["id": "b-two", "kind": "equation", "text": "Second"]],
            "equations": [["id": "e-one", "block_id": "b-one", "latex": "x^2", "display": false, "source_form": "body"],
                          ["id": "e-two", "block_id": "b-two", "latex": "x^2", "display": true, "source_form": "body"]],
            "figures": []]
        var files = ["index.html": Data("<h1>Sample</h1>".utf8), "reader.css": Data("body{color:black}".utf8),
                     "provenance.json": Data("{\"authored\":true}".utf8)]
        func package() throws -> (manifest: Data, files: [String: Data]) {
            var files = files
            files["reader.json"] = try JSONSerialization.data(withJSONObject: index, options: .sortedKeys)
            let roles = ["index.html": "html", "reader.css": "style", "provenance.json": "provenance", "reader.json": "index"]
            let mime = ["html": "text/html", "style": "text/css", "provenance": "application/json", "index": "application/json"]
            let members = files.keys.sorted().map { name -> [String: Any] in
                let data = files[name]!, role = roles[name] ?? "notice"
                return ["path": name, "role": role, "media_type": mime[role] ?? "text/plain", "bytes": data.count, "sha256": VerifiedReaderBundle.digest(data)]
            }
            let manifest: [String: Any] = ["format": "reader-bundle-v1", "renderer": ["id": "timestep-mmd-v1", "build_sha256": String(repeating: "a", count: 64)],
                "source": ["kind": "authored-mmd", "sha256": String(repeating: "b", count: 64), "provenance_path": "provenance.json"],
                "entrypoint": "index.html", "index_path": "reader.json", "members": members]
            return (try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys), files)
        }
        func verified() throws -> VerifiedReaderBundle {
            let value = try package()
            return try VerifiedReaderBundle.verify(manifest: value.manifest, expectedSHA256: VerifiedReaderBundle.digest(value.manifest), members: value.files)
        }
    }

    @Test func wholeBundleIntegrityPrecedesAnyReadableResource() throws {
        let original = try Fixture().package()
        let digest = VerifiedReaderBundle.digest(original.manifest)
        for missing in original.files.keys {
            var files = original.files; files.removeValue(forKey: missing)
            #expect(throws: ReaderBundleError.self) { try VerifiedReaderBundle.verify(manifest: original.manifest, expectedSHA256: digest, members: files) }
            files = original.files; files[missing] = Data("changed".utf8)
            #expect(throws: ReaderBundleError.self) { try VerifiedReaderBundle.verify(manifest: original.manifest, expectedSHA256: digest, members: files) }
        }
        #expect(throws: ReaderBundleError.integrityFailure) {
            try VerifiedReaderBundle.verify(manifest: original.manifest, expectedSHA256: String(repeating: "0", count: 64), members: original.files)
        }
    }

    @Test func unsafeAndCollidingPathsAreRefusedEvenWithValidNewManifestHash() throws {
        for name in ["../escape", "images/../escape", "/absolute", "images//a", "images/%2fescape", "images/a?x", "INDEX.html", "reader.css/child"] {
            var fixture = Fixture(); fixture.files[name] = Data([1])
            #expect(throws: ReaderBundleError.self) { try fixture.verified() }
        }
    }

    @Test func exactManifestFormattingSurvivesAnInMemoryReopen() throws {
        let fixture = try Fixture().package()
        let original = Data(" \n\t".utf8) + fixture.manifest + Data("\n ".utf8)
        let digest = VerifiedReaderBundle.digest(original)
        let bundle = try VerifiedReaderBundle.verify(manifest: original, expectedSHA256: digest, members: fixture.files)
        #expect(bundle.manifestData == original)
        #expect(try JSONEncoder().encode(bundle.manifest) != original)
        var members: [String: Data] = [:]
        for member in bundle.manifest.members { members[member.path] = try #require(bundle.data(for: member.path)) }
        let reopened = try VerifiedReaderBundle.verify(manifest: bundle.manifestData, expectedSHA256: digest, members: members)
        #expect(reopened.manifestData == original)
        #expect(reopened.data(for: "index.html") == fixture.files["index.html"])
    }

    @Test func resourceURLsAdmitOnlyExactMembersAndDocumentFragments() throws {
        let bundle = try Fixture().verified()
        let base = "reader-bundle://\(bundle.manifestSHA256)"
        #expect(bundle.resource(for: bundle.entryURL) != nil)
        #expect(bundle.permitsNavigation(to: URL(string: base + "/index.html#b-one")!))
        for url in [base + "/%69ndex.html", base + "/reader.css?x", base + "/reader.css#x", base + "/missing", base + "/../index.html", "file:///index.html", "https://example.com/index.html", base + ":12/index.html"] {
            #expect(bundle.resource(for: URL(string: url)!) == nil)
        }
        #expect(!bundle.permitsNavigation(to: URL(string: base + "/reader.css")!))
        #expect(!bundle.permitsNavigation(to: URL(string: base + "/index.html?query")!))
    }

    @Test func equationSourceIsResolvedByIdentityWithDistinctIdenticalEquations() throws {
        let bundle = try Fixture().verified()
        let selection = ReaderSelection(manifestSHA256: bundle.manifestSHA256, parts: [
            .init(kind: "text", blockID: "b-one", text: "Compare "),
            .init(kind: "equation", blockID: "b-one", equationID: "e-one"),
            .init(kind: "equation", blockID: "b-two", equationID: "e-two")])
        #expect(try selection.resolvedQuote(in: bundle) == "Compare \\(x^2\\)\n\\[x^2\\]")
        let wrongBlock = ReaderSelection(manifestSHA256: bundle.manifestSHA256, parts: [.init(kind: "equation", blockID: "b-two", equationID: "e-one")])
        #expect(throws: ReaderBundleError.invalidIndex) { try wrongBlock.resolvedQuote(in: bundle) }
        let injected = ReaderSelection(manifestSHA256: bundle.manifestSHA256, parts: [.init(kind: "equation", blockID: "b-one", text: "wrong equation", equationID: "e-one")])
        #expect(throws: ReaderBundleError.invalidIndex) { try injected.resolvedQuote(in: bundle) }
        let duplicate = ReaderSelection(manifestSHA256: bundle.manifestSHA256, parts: [.init(kind: "equation", blockID: "b-one", equationID: "e-one"), .init(kind: "equation", blockID: "b-one", equationID: "e-one")])
        #expect(throws: ReaderBundleError.invalidIndex) { try duplicate.resolvedQuote(in: bundle) }
    }

    @Test func selectionCannotCrossBundleIdentityOrTruncateOversizedMath() throws {
        let bundle = try Fixture().verified()
        let stale = ReaderSelection(manifestSHA256: String(repeating: "0", count: 64), parts: [.init(kind: "text", blockID: "b-one", text: "text")])
        #expect(throws: ReaderBundleError.invalidIndex) { try stale.resolvedQuote(in: bundle) }
        let oversized = ReaderSelection(manifestSHA256: bundle.manifestSHA256, parts: [
            .init(kind: "text", blockID: "b-one", text: String(repeating: "é", count: 9999)),
            .init(kind: "equation", blockID: "b-one", equationID: "e-one")])
        #expect(throws: ReaderBundleError.invalidIndex) { try oversized.resolvedQuote(in: bundle) }
    }

    @Test func completeMathEnvironmentsArePreservedWithoutNestedDelimiters() throws {
        var fixture = Fixture()
        let latex = #"\begin{align}a &= b \\ c &= d\label{eq:pair}\end{align}"#
        fixture.index["equations"] = [["id": "e-two", "block_id": "b-two", "latex": latex,
            "display": true, "source_form": "environment"]]
        let bundle = try fixture.verified()
        let selection = ReaderSelection(manifestSHA256: bundle.manifestSHA256,
            parts: [.init(kind: "equation", blockID: "b-two", equationID: "e-two")])
        #expect(try selection.resolvedQuote(in: bundle) == latex)
        for (form, display) in [("unknown", true), ("environment", false)] {
            fixture.index["equations"] = [["id": "e-two", "block_id": "b-two", "latex": latex,
                "display": display, "source_form": form]]
            #expect(throws: ReaderBundleError.invalidIndex) { try fixture.verified() }
        }
    }

    @Test func indexCannotAliasOrReferenceMissingElements() throws {
        var fixture = Fixture()
        fixture.index["equations"] = [["id": "e-one", "block_id": "missing", "latex": "x", "display": true, "source_form": "body"]]
        #expect(throws: ReaderBundleError.invalidIndex) { try fixture.verified() }
        fixture.index["equations"] = [["id": "b-one", "block_id": "b-one", "latex": "x", "display": true, "source_form": "body"]]
        #expect(throws: ReaderBundleError.invalidIndex) { try fixture.verified() }
        fixture = Fixture(); fixture.index["figures"] = [["id": "b-one", "block_id": "b-one", "asset_paths": ["missing.png"], "caption": "", "alt": ""]]
        #expect(throws: ReaderBundleError.invalidIndex) { try fixture.verified() }
    }

    @Test func diskLoadOwnsBytesAndRejectsSymlinkMembers() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try Fixture().package()
        try fixture.manifest.write(to: directory.appendingPathComponent("manifest.json"))
        for (name, bytes) in fixture.files { try bytes.write(to: directory.appendingPathComponent(name)) }
        let bundle = try VerifiedReaderBundle.load(directory: directory, expectedSHA256: VerifiedReaderBundle.digest(fixture.manifest))
        try Data("later edit".utf8).write(to: directory.appendingPathComponent("index.html"))
        #expect(bundle.data(for: "index.html") == fixture.files["index.html"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("index.html"))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("index.html").path, withDestinationPath: "reader.css")
        #expect(throws: ReaderBundleError.self) { try VerifiedReaderBundle.load(directory: directory, expectedSHA256: VerifiedReaderBundle.digest(fixture.manifest)) }
    }

    @Test func externalMutableBackingCannotChangeVerifiedResources() throws {
        let fixture = try Fixture().package()
        let original = fixture.files["index.html"]!
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: original.count, alignment: 1)
        defer { pointer.deallocate() }
        let manifestPointer = UnsafeMutableRawPointer.allocate(byteCount: fixture.manifest.count, alignment: 1)
        defer { manifestPointer.deallocate() }
        original.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        fixture.manifest.withUnsafeBytes { manifestPointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        var files = fixture.files
        files["index.html"] = Data(bytesNoCopy: pointer, count: original.count, deallocator: .none)
        let bundle = try VerifiedReaderBundle.verify(manifest: Data(bytesNoCopy: manifestPointer, count: fixture.manifest.count, deallocator: .none),
            expectedSHA256: VerifiedReaderBundle.digest(fixture.manifest), members: files)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: original.count)
        manifestPointer.initializeMemory(as: UInt8.self, repeating: 0, count: fixture.manifest.count)
        #expect(bundle.data(for: "index.html") == original)
        #expect(bundle.manifestData == fixture.manifest)
    }

    @Test func formatRoleAndResourceCeilingsArePartOfAdmission() throws {
        var fixture = Fixture(); fixture.files["empty-notice.txt"] = Data()
        let original = try fixture.package()
        #expect(try fixture.verified().data(for: "empty-notice.txt") == Data())
        let base = try JSONSerialization.jsonObject(with: original.manifest) as! [String: Any]
        for change in ["format", "renderer", "role", "size", "pixels"] {
            var manifest = base
            if change == "format" { manifest["format"] = "reader-bundle-v2" }
            if change == "renderer" { manifest["renderer"] = ["id": "unreviewed", "build_sha256": String(repeating: "a", count: 64)] }
            if ["role", "size", "pixels"].contains(change) {
                var members = manifest["members"] as! [[String: Any]]
                if change == "role" { members[0]["role"] = "script" }
                if change == "size" { members[0]["bytes"] = 16_777_217 }
                if change == "pixels" { members[0]["role"] = "image"; members[0]["media_type"] = "image/png"; members[0]["width"] = 8192; members[0]["height"] = 8192 }
                manifest["members"] = members
            }
            let data = try JSONSerialization.data(withJSONObject: manifest)
            #expect(throws: ReaderBundleError.self) { try VerifiedReaderBundle.verify(manifest: data, expectedSHA256: VerifiedReaderBundle.digest(data), members: original.files) }
        }
    }
}

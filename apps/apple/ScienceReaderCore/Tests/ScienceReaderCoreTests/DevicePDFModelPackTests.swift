import CryptoKit
import Foundation
import XCTest
@testable import ScienceReaderCore

/// The on-device PDF models as a download (docs/architecture/DEVICE_PDF_ROUTE.md "The models as a download"): the
/// description the app ships, the verified install, a model update, removal and where the route finds its models.
final class DevicePDFModelPackTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("model-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    /// A pack folder with the given files, and its description.
    private func makePack(_ name: String, _ contents: [String: String], lock: [String: String] = ["layout": String(repeating: "a", count: 64)]) throws -> (URL, DevicePDFModelPack) {
        let folder = temp.appendingPathComponent(name, isDirectory: true)
        var files: [DevicePDFModelPack.File] = []
        for (path, text) in contents {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            files.append(.init(path: path, size: Int64(text.utf8.count), sha256: Data(SHA256.hash(data: Data(text.utf8))).hex))
        }
        return (folder, DevicePDFModelPack(lock: lock, files: files))
    }

    private let models = ["device-models.json": "{}", "DeviceLayout.mlmodelc/model.mil": "layout", "DeviceLayout.mlmodelc/weights/weight.bin": "weights",
                          "tagger-vocab.json": "[]"]

    func testTheDescriptionRoundTripsAndItsVersionIsTheDigestOfItsFiles() throws {
        let (_, pack) = try makePack("pack", models)
        let url = temp.appendingPathComponent("device-models-pack.json")
        try JSONEncoder().encode(pack).write(to: url)
        let loaded = try DevicePDFModelPack.load(from: url)
        XCTAssertEqual(loaded, pack)
        XCTAssertEqual(loaded.bytes, Int64(models.values.map(\.utf8.count).reduce(0, +)))
        // The script's digest, written out: path, size and digest per line, in path order.
        let lines = pack.files.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        XCTAssertEqual(pack.version, Data(SHA256.hash(data: Data(lines.utf8))).hex)
        XCTAssertEqual(pack.files.map(\.path), pack.files.map(\.path).sorted())
    }

    func testADescriptionThatDisagreesWithItselfOrLeavesThePackIsRefused() throws {
        let (_, pack) = try makePack("pack", models)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pack)) as? [String: Any])
        func refused(_ change: (inout [String: Any]) -> Void) throws {
            var copy = object; change(&copy)
            let url = temp.appendingPathComponent("bad.json")
            try JSONSerialization.data(withJSONObject: copy).write(to: url)
            XCTAssertThrowsError(try DevicePDFModelPack.load(from: url))
        }
        try refused { $0["version"] = String(repeating: "0", count: 64) }
        try refused { $0["schema"] = "something-else" }
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        files[0]["path"] = "../escape"
        try refused { $0["files"] = files }
        files[0]["path"] = "/absolute"
        try refused { $0["files"] = files }
        object["files"] = [[String: Any]]()
        try refused { _ in }
    }

    func testInstallCopiesVerifiesAndMarksTheVersion() async throws {
        let (source, pack) = try makePack("odr", models)
        // An extra file in the source is not part of the pack and is not copied.
        try Data("stray".utf8).write(to: source.appendingPathComponent("extra.txt"))
        let store = DevicePDFModelStore(root: temp.appendingPathComponent("support"), pack: pack)
        XCTAssertNil(store.installed)
        XCTAssertNil(DevicePDFModelLocator.locate(environment: [:], store: store, bundled: nil))
        let fractions = Fractions()
        let installed = try await store.install(from: source, progress: { fractions.append($0) })
        XCTAssertEqual(store.installed, installed)
        XCTAssertEqual(installed.lastPathComponent, pack.version)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("DeviceLayout.mlmodelc/model.mil"), encoding: .utf8), "layout")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("extra.txt").path))
        XCTAssertEqual(store.installedBytes, pack.bytes + Int64(pack.version.utf8.count), "the files and the marker")
        XCTAssertEqual(fractions.values.last, 1)
        XCTAssertEqual(try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(DevicePDFModelLocator.locate(environment: [:], store: store, bundled: nil), .downloaded(installed))
        // No staging folder is left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [pack.version])
    }

    func testAFileThatDoesNotMatchIsRefusedAndNothingIsInstalled() async throws {
        let (source, pack) = try makePack("odr", models)
        try Data("tampered".utf8).write(to: source.appendingPathComponent("DeviceLayout.mlmodelc/model.mil"))
        let store = DevicePDFModelStore(root: temp.appendingPathComponent("support"), pack: pack)
        do { try await store.install(from: source); XCTFail("installed a tampered pack") } catch let error as DevicePDFModelPackError {
            XCTAssertEqual(error, .sizeMismatch("DeviceLayout.mlmodelc/model.mil"))
        }
        // Same size, different bytes.
        try Data("lay0ut".utf8).write(to: source.appendingPathComponent("DeviceLayout.mlmodelc/model.mil"))
        do { try await store.install(from: source); XCTFail("installed a tampered pack") } catch let error as DevicePDFModelPackError {
            XCTAssertEqual(error, .digestMismatch("DeviceLayout.mlmodelc/model.mil"))
        }
        try FileManager.default.removeItem(at: source.appendingPathComponent("tagger-vocab.json"))
        do { try await store.install(from: source); XCTFail("installed an incomplete pack") } catch let error as DevicePDFModelPackError {
            XCTAssertTrue([.missingFile("tagger-vocab.json"), .digestMismatch("DeviceLayout.mlmodelc/model.mil")].contains(error))
        }
        XCTAssertNil(store.installed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".staging") }, [])
    }

    func testAModelUpdateInstallsTheNewVersionAndRemovesTheOld() async throws {
        let root = temp.appendingPathComponent("support")
        let (oldSource, oldPack) = try makePack("old", models)
        let oldStore = DevicePDFModelStore(root: root, pack: oldPack)
        try await oldStore.install(from: oldSource)
        var changed = models; changed["DeviceLayout.mlmodelc/weights/weight.bin"] = "new weights"
        let (newSource, newPack) = try makePack("new", changed, lock: ["layout": String(repeating: "b", count: 64)])
        XCTAssertNotEqual(oldPack.version, newPack.version)
        // The app with the new lock: the old download is not this version's models.
        let newStore = DevicePDFModelStore(root: root, pack: newPack)
        XCTAssertNil(newStore.installed)
        XCTAssertEqual(newStore.otherVersions, [oldPack.version])
        XCTAssertNil(DevicePDFModelLocator.locate(environment: [:], store: newStore, bundled: nil))
        try await newStore.install(from: newSource)
        XCTAssertNotNil(newStore.installed)
        XCTAssertEqual(newStore.otherVersions, [])
        XCTAssertNil(oldStore.installed)
    }

    func testRemoveTakesEveryVersionAway() async throws {
        let (source, pack) = try makePack("odr", models)
        let store = DevicePDFModelStore(root: temp.appendingPathComponent("support"), pack: pack)
        try await store.install(from: source)
        try store.removeAll()
        XCTAssertNil(store.installed)
        XCTAssertEqual(store.installedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        try store.removeAll()  // nothing there: no error
    }

    func testPackagesInThePackAreCompiledOnTheDevice() async throws {
        var contents = models; contents["DeviceLayout.mlmodelc/model.mil"] = nil; contents["DeviceLayout.mlmodelc/weights/weight.bin"] = nil
        contents["DeviceLayout.mlpackage/Manifest.json"] = "{}"; contents["DeviceLayout.mlpackage/Data/weights.bin"] = "w"
        let (source, pack) = try makePack("packages", contents)
        let store = DevicePDFModelStore(root: temp.appendingPathComponent("support"), pack: pack)
        let compiledFrom = Fractions()
        let installed = try await store.install(from: source, compile: { url in
            // Stands in for Core ML's compiler: a folder elsewhere, as MLModel.compileModel returns.
            compiledFrom.append(Double(url.lastPathComponent == "DeviceLayout.mlpackage" ? 1 : 0))
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: out.appendingPathComponent("model.mil"))
            return out
        })
        XCTAssertEqual(compiledFrom.values, [1])
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("DeviceLayout.mlmodelc/model.mil"), encoding: .utf8), "compiled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("DeviceLayout.mlpackage").path))
    }

    func testTheLocatorPrefersTheOverrideThenTheDownloadThenTheApp() async throws {
        let (source, pack) = try makePack("odr", models)
        let store = DevicePDFModelStore(root: temp.appendingPathComponent("support"), pack: pack)
        let bundled = source  // a folder with device-models.json, as inside the Mac app
        XCTAssertEqual(DevicePDFModelLocator.locate(environment: [:], store: store, bundled: bundled), .bundled(bundled))
        XCTAssertEqual(DevicePDFModelLocator.locate(environment: [:], store: nil, bundled: nil), nil)
        let installed = try await store.install(from: source)
        XCTAssertEqual(DevicePDFModelLocator.locate(environment: [:], store: store, bundled: bundled), .downloaded(installed))
        let env = [DevicePDFModelLocator.environmentKey: source.path]
        XCTAssertEqual(DevicePDFModelLocator.locate(environment: env, store: store, bundled: nil), .override(source))
        // An override naming a folder without models is ignored.
        XCTAssertEqual(DevicePDFModelLocator.locate(environment: [DevicePDFModelLocator.environmentKey: temp.path], store: store, bundled: nil), .downloaded(installed))
        // A folder without device-models.json is not models.
        XCTAssertNil(DevicePDFModelLocator.locate(environment: [:], store: nil, bundled: temp))
    }

    func testStreamedDigestMatchesOneShot() throws {
        let url = temp.appendingPathComponent("big.bin")
        let data = Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        XCTAssertEqual(try DevicePDFModelStore.sha256(of: url), Data(SHA256.hash(data: data)).hex)
    }
}

/// Values reported from the installer's closures.
private final class Fractions: @unchecked Sendable {
    private let lock = NSLock(); private var stored: [Double] = []
    func append(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}

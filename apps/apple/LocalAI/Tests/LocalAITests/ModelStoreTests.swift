import CryptoKit
import Foundation
import Testing
@testable import LocalAI

@Suite struct ModelStoreTests {
    private func fixture() throws -> (LocalModelStore, LocalModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-ai-test-" + UUID().uuidString)
        let digest = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        let json = #"{"id":"fixture","name":"Fixture","repository":"unused/test","revision":"test-revision","vision":false,"files":[{"name":"model.safetensors","bytes":3,"sha256":"DIGEST"}]}"#
            .replacingOccurrences(of: "DIGEST", with: digest)
        let model = try JSONDecoder().decode(LocalModel.self, from: Data(json.utf8))
        return (LocalModelStore(root: root), model, root)
    }
    @Test func incompleteDownloadCannotBecomeInstalled() async throws {
        let (store, model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = store.directory(for: model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        #expect(await !store.isInstalled(model))
        await #expect(throws: LocalAIError.self) { try await store.verifiedDirectory(model) }
    }
    @Test func sameLengthCorruptionIsRejectedBeforeLoading() async throws {
        let (store, model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = store.directory(for: model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        try Data(model.revision.utf8).write(to: folder.appendingPathComponent("verified"))
        #expect(await store.isInstalled(model)) // metadata is not an integrity proof
        await #expect(throws: LocalAIError.self) { try await store.verifiedDirectory(model) }
    }
    @Test func verifiedLocalFilesNeedNoNetworkAndRemovalIsScoped() async throws {
        let (store, model, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = store.directory(for: model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        try Data(model.revision.utf8).write(to: folder.appendingPathComponent("verified"))
        let other = root.appendingPathComponent("another-model"); try Data("keep".utf8).write(to: other)
        #expect(try await store.verifiedDirectory(model) == folder)
        try await store.remove(model)
        #expect(await !store.isInstalled(model))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
    @Test func cataloguePinsEveryFileAndBothVisionProcessors() {
        #expect(LocalModel.all.count == 4)
        for model in LocalModel.all {
            #expect(model.revision.count == 40)
            #expect(model.files.contains { $0.name == "model.safetensors" })
            #expect(model.files.contains { $0.name == "tokenizer.json" })
            if model.vision { #expect(model.files.contains { $0.name == "processor_config.json" }) }
            #expect(model.files.allSatisfy { $0.bytes > 0 && $0.sha256.count == 64 && !$0.name.contains("/") })
        }
    }
    @Test func memoryAdmissionRequiresPhysicalCapacityHeadroomMetalBudgetAndNormalPressure() throws {
        let (_, model, _) = try fixture()
        let needed = model.requiredHeadroom(hasImage: true)
        #expect(model.admitsMemory(total: needed * 2, reclaimable: needed, metalLimit: needed, pressure: 1, hasImage: true))
        #expect(!model.admitsMemory(total: needed - 1, reclaimable: needed, metalLimit: needed, pressure: 1, hasImage: true))
        #expect(!model.admitsMemory(total: needed * 2, reclaimable: needed - 1, metalLimit: needed, pressure: 1, hasImage: true))
        #expect(!model.admitsMemory(total: needed * 2, reclaimable: needed, metalLimit: needed - 1, pressure: 1, hasImage: true))
        for pressure in [0, 2, 4] {
            #expect(!model.admitsMemory(total: needed * 2, reclaimable: needed, metalLimit: needed, pressure: pressure, hasImage: true))
        }
    }
}

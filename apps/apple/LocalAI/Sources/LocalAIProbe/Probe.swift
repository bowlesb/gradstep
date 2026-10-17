import Foundation
import LocalAI
import ScienceReaderCore

// Opt-in, local-only evidence. Never part of routine npm test. No provider credentials or paid calls.
@main struct Probe {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, let model = LocalModel.all.first(where: { $0.id == args[0] }) else {
            print("LocalAIProbe MODEL STORE download | MODEL STORE INPUT.json [IMAGE]"); return
        }
        let store = LocalModelStore(root: URL(fileURLWithPath: args[1], isDirectory: true))
        if args[2] == "download" {
            try await store.download(model) { _, _ in }
            print("Verified \(model.name), \(model.bytes) bytes"); return
        }
        struct Case: Decodable { let question: String; var selection: String?; var paper: String?; var focus: Int?; var action: String? }
        let fixture = try JSONDecoder().decode(Case.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let image = args.count > 3 ? try Data(contentsOf: URL(fileURLWithPath: args[3])) : nil
        let directory = try await store.verifiedDirectory(model)
        let result = try await LocalEngine().answer(model: model, directory: directory,
            input: .init(question: fixture.question, selection: fixture.selection, paper: fixture.paper, focus: fixture.focus,
                         action: fixture.action.flatMap(ChatAction.init(rawValue:))), image: image) { _ in }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}

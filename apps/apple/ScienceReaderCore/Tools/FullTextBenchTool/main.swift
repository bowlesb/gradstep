import Foundation
import ScienceReaderCore

// swift run -c release FullTextBenchTool <directory of .txt paper texts> [papers=2000]
// Builds an encrypted index of that many synthetic papers (the texts repeated, docs/architecture/NATIVE_LIBRARY_SEARCH.md
// "Measurements") in a temporary folder, then reports size, load time and query latency. Prints no paper text.
//
// swift run -c release FullTextBenchTool everything [owner|heavy|small ...]
// Global search's everything index (docs/architecture/GLOBAL_SEARCH.md "Measurements") on the synthetic owner and heavy
// corpora: build, size, cold open and load, each query alone and grouped with excerpts, typo correction, one-item commits.
let arguments = CommandLine.arguments.dropFirst()
guard let folder = arguments.first else {
    FileHandle.standardError.write(Data("usage: FullTextBenchTool <texts directory> [papers] | everything [owner|heavy|small]\n".utf8)); exit(2)
}
if folder == "everything" {
    let names = arguments.dropFirst().isEmpty ? ["owner", "heavy"] : Array(arguments.dropFirst())
    for name in names {
        let profile: EverythingBench.Profile = name == "heavy" ? .heavy : name == "small" ? .small : .owner
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everything-bench-\(UUID().uuidString)", isDirectory: true)
        print(try await EverythingBench.run(profile, directory: directory))
        print("")
    }
    exit(0)
}
let papers = arguments.dropFirst().first.flatMap(Int.init) ?? 2_000
let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "txt" }.sorted { $0.path < $1.path }
let texts = try urls.map { try String(contentsOf: $0, encoding: .utf8) }
guard !texts.isEmpty else { FileHandle.standardError.write(Data("no .txt files\n".utf8)); exit(2) }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fulltext-bench-\(UUID().uuidString)", isDirectory: true)
print("source texts: \(texts.count)")
let report = try await FullTextBench.run(texts: texts, papers: papers, directory: directory)
print(report)

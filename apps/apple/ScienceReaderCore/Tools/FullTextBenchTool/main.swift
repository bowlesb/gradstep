import Foundation
import ScienceReaderCore

// swift run -c release FullTextBenchTool <directory of .txt paper texts> [papers=2000]
// Builds an encrypted index of that many synthetic papers (the texts repeated, docs/architecture/NATIVE_LIBRARY_SEARCH.md
// "Measurements") in a temporary folder, then reports size, load time and query latency. Prints no paper text.
let arguments = CommandLine.arguments.dropFirst()
guard let folder = arguments.first else {
    FileHandle.standardError.write(Data("usage: FullTextBenchTool <texts directory> [papers]\n".utf8)); exit(2)
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

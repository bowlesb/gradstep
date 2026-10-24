import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Opt-in: the full-text index's size, load time and query latency in the Simulator (docs/architecture/
/// NATIVE_LIBRARY_SEARCH.md, "Measurements"). Set `TEST_RUNNER_FULLTEXT_BENCH_CORPUS` to a folder of plain-text paper
/// files (optionally `TEST_RUNNER_FULLTEXT_BENCH_PAPERS`, default 2000) and build with `SWIFT_OPTIMIZATION_LEVEL=-O`.
/// The report is attached and printed; it contains no paper text.
final class FullTextBenchTests: XCTestCase {
    func testFullTextIndexOnASyntheticLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["FULLTEXT_BENCH_CORPUS"] else {
            throw XCTSkip("Set TEST_RUNNER_FULLTEXT_BENCH_CORPUS to a folder of .txt paper texts")
        }
        let papers = environment["FULLTEXT_BENCH_PAPERS"].flatMap(Int.init) ?? 2_000
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }.sorted { $0.path < $1.path }
        let texts = try urls.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertFalse(texts.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fulltext-bench-\(UUID().uuidString)", isDirectory: true)
        var library: [String] = []
        let report = try await FullTextBench.run(texts: texts, papers: papers, directory: directory) { metadata, store in
            // The whole Library search as the app runs it: index, metadata substring fallback, ranking, snippets.
            let candidates = metadata.enumerated().map { offset, paper in
                LibrarySearchCandidate(id: "paper/\(paper.group)", title: paper.title, fields: [paper.title, paper.authors, paper.abstract, "", paper.tag],
                                       recentSequence: Int64(offset), position: offset, fullTextKey: paper.group)
            }
            for (round, text) in FullTextBench.defaultQueries.enumerated() {
                var times: [Double] = [], output = LibrarySearchOutput(rowIDs: [])
                for repetition in 0...10 {
                    let key = LibrarySearchKey(sessionID: UUID(), accountID: nil, sourceRevision: 1, query: text, sort: .recent)
                    let start = ContinuousClock.now
                    output = try await LibrarySearchEngine.run(LibrarySearchInput(ticket: .init(key: key), candidates: candidates, fullText: store))
                    let elapsed = start.duration(to: .now).components
                    let ms = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                    if round == 0 && repetition == 0 { library.append(String(format: "first search after launch (loads the index) %.1f ms", ms)) }
                    if repetition > 0 { times.append(ms) }
                }
                times.sort()
                library.append(String(format: "library %-28@ %5d rows %3d snippets  median %6.2f ms  max %6.2f ms",
                                      text as NSString, output.rowIDs.count, output.snippets.count, times[times.count / 2], times.last ?? 0))
            }
        }
        let text = report.description + "\n" + library.joined(separator: "\n")
        print("FULLTEXT BENCH\n\(text)")
        add(XCTAttachment(string: text))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

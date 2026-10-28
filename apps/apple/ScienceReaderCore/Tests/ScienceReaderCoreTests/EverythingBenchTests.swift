import Foundation
import Testing
@testable import ScienceReaderCore

/// Global search's speed target (docs/architecture/GLOBAL_SEARCH.md "Measurements"): grouped results with excerpts
/// within 100 ms of a keystroke at the heavy scale. Opt-in and slow; measure a release build:
///
///     EVERYTHING_BENCH=heavy swift test -c release -Xswiftc -enable-testing --filter EverythingBenchTests
///
/// (`owner`, `heavy` or both, comma-separated). The same report: `swift run -c release FullTextBenchTool everything`.
@Suite struct EverythingBenchTests {
    @Test func groupedResultsWithExcerptsComeWithinTheBudget() async throws {
        guard let names = ProcessInfo.processInfo.environment["EVERYTHING_BENCH"] else { return }
        for name in names.split(separator: ",") {
            let profile: EverythingBench.Profile = name == "heavy" ? .heavy : name == "small" ? .small : .owner
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("everything-bench-\(UUID().wire)", isDirectory: true)
            let report = try await EverythingBench.run(profile, directory: directory)
            print(report)
            #expect(report.worstFullP95MS < 100, "p95 \(report.worstFullP95MS) ms at \(profile.name)")
            #expect(report.loadMS < 250)
            // Every query found something (a typo through its correction).
            #expect(report.queries.allSatisfy { !$0.matches.isEmpty })
            #expect(report.queries.first { $0.query == "atention " }?.correction == "attention")
            // α, \alpha and alpha are one word.
            #expect(report.queries.first { $0.query == "α" }?.matches == report.queries.first { $0.query == "\\alpha" }?.matches)
        }
    }

    /// The generator is deterministic and shaped as the profile says (fast; runs in every `swift test`).
    @Test func theCorpusMatchesItsProfile() {
        let items = EverythingBench.corpus(.small)
        #expect(items.count == EverythingBench.Profile.small.items)
        #expect(EverythingBench.corpus(.small).map(\.body) == items.map(\.body))
        #expect(Set(items.map(\.kind)) == Set(SearchItemKind.allCases).subtracting([.figure, .paperExplainer]))
    }
}

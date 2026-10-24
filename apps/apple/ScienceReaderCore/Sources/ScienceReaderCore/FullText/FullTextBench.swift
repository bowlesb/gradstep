import Foundation

/// Measures the full-text index on a synthetic library made by repeating real paper text (the `FullTextBenchTool`
/// on a Mac, an opt-in test in the Simulator). Each synthetic paper rotates its source's paragraphs and adds a few
/// words of its own, so the dictionary grows with the library as a real one does. Prints nothing of the text.
public enum FullTextBench {
    public struct Report: Sendable, CustomStringConvertible {
        public var papers = 0
        public var sourceCharacters = 0
        public var buildSeconds = 0.0
        public var segmentBytes = 0, textBytes = 0
        public var openMilliseconds = 0.0, loadMilliseconds = 0.0
        public var queries: [(query: String, matches: Int, medianMS: Double, p95MS: Double)] = []
        public var snippetMedianMS = 0.0, snippetWarmMedianMS = 0.0
        public var bytesPerPaper: Double { Double(segmentBytes + textBytes) / Double(max(1, papers)) }
        public var description: String {
            var lines = [String(format: "papers %d (avg %.0f chars), build %.1f s (%.1f ms/paper)", papers,
                                Double(sourceCharacters) / Double(max(1, papers)), buildSeconds, buildSeconds * 1_000 / Double(max(1, papers))),
                         String(format: "on disk: segments %.1f MB, texts %.1f MB, %.1f KB/paper", Double(segmentBytes) / 1e6,
                                Double(textBytes) / 1e6, bytesPerPaper / 1e3),
                         String(format: "open %.1f ms, load (decrypt+decode all segments) %.1f ms", openMilliseconds, loadMilliseconds)]
            for query in queries {
                lines.append(String(format: "query %-28@ %5d matches  median %6.2f ms  p95 %6.2f ms", query.query as NSString, query.matches, query.medianMS, query.p95MS))
            }
            lines.append(String(format: "snippet (one paper) median %.3f ms with its text not yet read, %.3f ms cached", snippetMedianMS, snippetWarmMedianMS))
            return lines.joined(separator: "\n")
        }
    }

    public static let defaultQueries = ["attention ", "diffusion model ", "\"language models\"", "transfo", "gradient descent optimization ",
                                        "reward ", "in-context learning ", "zebra ", "state space model ", "kl"]

    /// Indexes `papers` synthetic papers from `texts` into a fresh encrypted index in `directory`, reopens it and
    /// times the queries (`repetitions` each, after one warm-up).
    /// One synthetic paper's metadata as the index holds it (the app's bench builds its Library rows from these).
    public struct Paper: Sendable {
        public let group: String, title: String, abstract: String, authors: String, tag: String
    }

    /// `inspect` runs on the reopened index before it is deleted (the app times its whole Library search there).
    public static func run(texts: [String], papers: Int, directory: URL, queries: [String] = defaultQueries,
                           repetitions: Int = 20, batch: Int = 32,
                           inspect: (([Paper], FullTextIndexStore) async throws -> Void)? = nil) async throws -> Report {
        precondition(!texts.isEmpty)
        try? FileManager.default.removeItem(at: directory)
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) }), account = UUID()
        var report = Report()
        report.papers = papers
        let paragraphs = texts.map { $0.components(separatedBy: "\n\n").filter { !$0.isEmpty } }
        var store = try FullTextIndexStore(directory: directory, accountID: account, localKey: key)
        let started = Date()
        var pending: [FullTextDocument] = []
        var metadata: [Paper] = []
        for index in 0..<papers {
            let source = paragraphs[index % paragraphs.count]
            let rotation = (index / paragraphs.count * 7) % max(1, source.count)
            var body = (source[rotation...] + source[..<rotation]).joined(separator: "\n\n")
            body += "\n\n" + (0..<150).map { "w\(index)q\($0 * 7919 % 1000)" }.joined(separator: " ")
            report.sourceCharacters += body.utf8.count
            let title = String(source.first?.prefix(120) ?? "Paper \(index)")
            let group = String(format: "paper-%05d", index)
            let paper = Paper(group: group, title: title, abstract: String(source.dropFirst().first?.prefix(1_500) ?? ""),
                              authors: "Author \(index % 300), Coauthor \(index % 41)", tag: "Topic \(index % 12)")
            metadata.append(paper)
            pending.append(FullTextDocument(id: .init(group: group, part: .metadata), fingerprint: "m\(index)",
                                            fields: [.title: title, .abstract: paper.abstract, .authors: paper.authors, .tags: paper.tag]))
            pending.append(FullTextDocument(id: .init(group: group, part: .body), fingerprint: "b\(index)", fields: [.body: body]))
            if pending.count >= batch * 2 || index == papers - 1 {
                let prepared = FullTextIndexStore.prepare(pending)
                try await store.commit(prepared)
                pending.removeAll(keepingCapacity: true)
            }
        }
        report.buildSeconds = Date().timeIntervalSince(started)
        (report.segmentBytes, report.textBytes, _) = await store.footprint()

        // A cold open, as at launch: the manifest only, then all segments on the first query.
        await store.close()
        let open = ContinuousClock.now
        store = try FullTextIndexStore(directory: directory, accountID: account, localKey: key)
        report.openMilliseconds = milliseconds(open.duration(to: .now))
        let load = ContinuousClock.now
        let snapshot = try await store.snapshot()
        report.loadMilliseconds = milliseconds(load.duration(to: .now))

        for text in queries {
            let query = FullTextQuery(text)
            let all: UInt64 = (1 << UInt64(query.clauses.count)) - 1
            var matches = 0, times: [Double] = []
            for repetition in 0...repetitions {
                let start = ContinuousClock.now
                let hits = snapshot.search(query)
                matches = hits.values.reduce(0) { $0 + ($1.clauses == all ? 1 : 0) }
                if repetition > 0 { times.append(milliseconds(start.duration(to: .now))) }
            }
            times.sort()
            report.queries.append((text, matches, times[times.count / 2], times[min(times.count - 1, times.count * 95 / 100)]))
        }
        // Snippets: one per paper for the first matches of a common query, each from a cold text cache entry.
        let hits = Array(snapshot.search(FullTextQuery("model ")).values.prefix(40))
        var snippetTimes: [Double] = []
        for hit in hits {
            let start = ContinuousClock.now
            _ = snapshot.snippet(for: hit)
            snippetTimes.append(milliseconds(start.duration(to: .now)))
        }
        snippetTimes.sort()
        report.snippetMedianMS = snippetTimes.isEmpty ? 0 : snippetTimes[snippetTimes.count / 2]
        // The same papers again (typing the next letter of a query): their texts are cached.
        var warmTimes: [Double] = []
        for hit in hits {
            let start = ContinuousClock.now
            _ = snapshot.snippet(for: hit)
            warmTimes.append(milliseconds(start.duration(to: .now)))
        }
        warmTimes.sort()
        report.snippetWarmMedianMS = warmTimes.isEmpty ? 0 : warmTimes[warmTimes.count / 2]
        if let inspect { await store.unload(); try await inspect(metadata, store) }
        await store.close()
        try? FileManager.default.removeItem(at: directory)
        return report
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

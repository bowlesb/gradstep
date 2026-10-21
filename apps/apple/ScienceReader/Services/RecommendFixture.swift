#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// UI fixture for AI recommendations (`--recommend-fixture`, with `--workflow-fixture --library-metadata-fixture`):
/// scripted function events with no account, network or provider. `--recommend-fixture-mode=none|daily_limit|
/// insufficient_credits|error` scripts the other outcomes. Added papers join the fixture library as imports, so
/// Remove and Undo run through the ordinary library paths. Compiled only into Simulator/Mac debug builds.
enum RecommendFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--recommend-fixture") }
    static var mode: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--recommend-fixture-mode=") }.map { String($0.dropFirst("--recommend-fixture-mode=".count)) } ?? "added"
    }
    static let service: ScriptedRecommendations? = isEnabled ? ScriptedRecommendations(mode: mode) : nil

    /// What the script "adds" (best first), with the reasons a model would give for “Attention Is All You Need”.
    static let papers: [RecommendedPaper] = [
        .init(sourceID: "2004.05150", revision: 2, title: "Longformer: The Long-Document Transformer", authors: ["Iz Beltagy", "Matthew E. Peters", "Arman Cohan"],
              year: 2020, reason: "Same attention, made sparse so it reaches long documents", status: .added,
              importID: UUID(uuidString: "fb000000-0000-4000-8000-000000000001")),
        .init(sourceID: "2001.04451", revision: 2, title: "Reformer: The Efficient Transformer", authors: ["Nikita Kitaev", "Łukasz Kaiser", "Anselm Levskaya"],
              year: 2020, reason: "Replaces its dot-product attention with hashing to save memory", status: .added,
              importID: UUID(uuidString: "fb000000-0000-4000-8000-000000000002")),
        .init(sourceID: "2006.04768", revision: 3, title: "Linformer: Self-Attention with Linear Complexity", authors: ["Sinong Wang", "Belinda Z. Li", "Madian Khabsa"],
              year: 2020, reason: "Approximates its attention matrix at linear cost", status: .added,
              importID: UUID(uuidString: "fb000000-0000-4000-8000-000000000003")),
        .init(sourceID: "2009.14794", revision: 4, title: "Rethinking Attention with Performers", authors: ["Krzysztof Choromanski", "Valerii Likhosherstov"],
              year: 2020, reason: "Kernel approximation of the same softmax attention", status: .added,
              importID: UUID(uuidString: "fb000000-0000-4000-8000-000000000004")),
        .init(sourceID: "2007.14062", revision: 2, title: "Big Bird: Transformers for Longer Sequences", authors: ["Manzil Zaheer", "Guru Guruganesh"],
              year: 2020, reason: "Sparse attention pattern with the same encoder design", status: .added,
              importID: UUID(uuidString: "fb000000-0000-4000-8000-000000000005")),
    ]

    /// Library fixture papers the menu can seed from (they have no arXiv ids otherwise).
    static let seedSources: [UUID: String] = [
        UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000001")!: "1706.03762",
        UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000002")!: "2305.18290",
        UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000003")!: "2106.09685",
    ]

    /// The import a server add creates, as the library would list it.
    static func importRecord(for paper: RecommendedPaper) -> LibraryImportRecord? {
        guard let id = paper.importID else { return nil }
        let value: [String: Any] = ["id": id.uuidString.lowercased(), "created_seq": 40, "state_seq": 40, "intent_revision": 1, "visible": true,
            "phase": "accepted", "progress": "finding", "source": "arxiv", "source_id": paper.sourceID, "source_revision": paper.revision ?? 1,
            "metadata_id": UUID().uuidString.lowercased(), "version_id": UUID().uuidString.lowercased(),
            "metadata": ["title": paper.title, "authors": paper.authors, "published_at": "\(paper.year ?? 2020)-01-01", "categories": ["cs.LG"]] as [String: Any],
            "metadata_recorded_at": "2026-10-21T09:00:00Z", "source_url": "https://arxiv.org/abs/\(paper.sourceID)", "retryable": false]
        return try? JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

/// Answers like functions/v1/recommend would: searching, choosing, papers ~0.8 s apart (slow enough for UI queries), done.
struct ScriptedRecommendations: RecommendationService {
    let mode: String
    func stream(_ body: RecommendRequestBody) async throws -> AsyncThrowingStream<RecommendEvent, Error> {
        let mode = self.mode, count = body.count
        return AsyncThrowingStream { continuation in
            let task = Task {
                func pause(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }
                do {
                    try await pause(250)
                    switch mode {
                    case "daily_limit", "insufficient_credits", "rate_limited", "seed_unavailable", "unavailable":
                        continuation.yield(.failed(RecommendFailure(code: mode))); continuation.finish(); return
                    default: break
                    }
                    continuation.yield(.searching); try await pause(1_800)
                    if mode == "error" { continuation.yield(.failed(RecommendFailure(code: "service_unavailable", retryAfter: 10))); continuation.finish(); return }
                    continuation.yield(.choosing(candidates: 34)); try await pause(1_500)
                    if mode == "none" {
                        continuation.yield(.done(RecommendDone(added: 0, requested: count, credits: 0, charged: false, reason: "none_related")))
                        continuation.finish(); return
                    }
                    let chosen = Array(RecommendFixture.papers.prefix(count))
                    for (index, paper) in chosen.enumerated() {
                        continuation.yield(.paper(ordinal: index + 1, paper)); try await pause(800)
                    }
                    continuation.yield(.done(RecommendDone(added: chosen.count, requested: count, credits: 1, charged: true, reason: nil)))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ReaderModel {
    /// `--recommend-fixture`: the library fixture's first papers get their arXiv ids, so Recommend is offered.
    func configureRecommendFixture() {
        papers = papers.map { paper in
            guard let source = RecommendFixture.seedSources[paper.id] else { return paper }
            var seeded = paper; seeded.sourceID = source; seeded.sourceRevision = 1
            return seeded
        }
    }
}
#endif

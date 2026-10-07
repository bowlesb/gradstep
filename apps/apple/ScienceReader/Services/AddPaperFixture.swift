#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// UI fixture for Add (`--add-paper-fixture`): scripted server outcomes, uploads and device downloads
/// with no account, network or provider. Compiled only into Simulator/Mac debug builds.
enum AddPaperFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--add-paper-fixture") }
    static let service: (any PaperAddingService)? = isEnabled ? ScriptedPaperAdding() : nil

    /// DOIs and links the script knows (UI tests type these).
    static let closedDOI = "10.1145/3292500.3330701"
    static let openDOI = "10.48550/arXiv.1706.03762"
    static let blockedLink = "https://openreview.net/pdf?id=HPuSIXJaa9"
    static let pdfLink = "https://files.example.org/workshop-draft.pdf"
}

/// Answers like functions/v1/add-paper would for the fixture's inputs.
final class ScriptedPaperAdding: PaperAddingService {
    func addPaper(_ query: String) async throws -> AddPaperResult {
        try await Task.sleep(for: .milliseconds(300))
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func paper(_ id: String, _ title: String, _ year: Int, kind: String, link: String?) -> AddReferenceResult.Paper {
            .init(title: title, year: year, source_id: id, kind: kind, host: nil, link: link)
        }
        switch text {
        case AddPaperFixture.closedDOI, "https://doi.org/\(AddPaperFixture.closedDOI)":
            return .init(status: "closed", route: "doi", paper: paper("openalex:W2963403868", "Optuna: A Next-generation Hyperparameter Optimization Framework", 2019,
                         kind: "web", link: "https://doi.org/\(AddPaperFixture.closedDOI)"), link: "https://doi.org/\(AddPaperFixture.closedDOI)", reason: nil, title: nil)
        case AddPaperFixture.openDOI:
            return .init(status: "added", route: "doi", paper: paper("1706.03762", "Attention Is All You Need", 2017, kind: "arxiv", link: nil), link: nil, reason: nil, title: nil)
        case AddPaperFixture.blockedLink:
            return .init(status: "blocked", route: "link", paper: nil, link: AddPaperFixture.blockedLink, reason: "source_blocked", title: nil)
        case AddPaperFixture.pdfLink:
            return .init(status: "link_only", route: "link", paper: nil, link: AddPaperFixture.pdfLink, reason: nil, title: "A Workshop Draft on Sparse Attention")
        default:
            return .init(status: "not_found", route: "none", paper: nil, link: nil, reason: nil, title: nil)
        }
    }
}
#endif

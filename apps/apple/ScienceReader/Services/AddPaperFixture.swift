#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore
import UIKit

/// UI fixture for Add (`--add-paper-fixture`): scripted server outcomes, uploads and device downloads
/// with no account, network or provider. Compiled only into Simulator/Mac debug builds.
enum AddPaperFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--add-paper-fixture") }
    static let service: ScriptedPaperAdding? = isEnabled ? ScriptedPaperAdding() : nil
    static let accountID = UUID(uuidString: "fa000000-0000-4000-8000-0000000000a1")!

    /// DOIs and links the script knows (UI tests type these).
    static let closedDOI = "10.1145/3292500.3330701"
    static let openDOI = "10.48550/arXiv.1706.03762"
    static let blockedLink = "https://openreview.net/pdf?id=HPuSIXJaa9"
    static let pdfLink = "https://files.example.org/workshop-draft.pdf"
    /// Failed web imports in the fixture library: blocked by the website, and not openly available.
    static let blockedImport = UUID(uuidString: "fa000000-0000-4000-8000-0000000000b1")!
    static let closedImport = UUID(uuidString: "fa000000-0000-4000-8000-0000000000b2")!

    /// A small real PDF (one page with a title line), written once per launch.
    static func samplePDF(named name: String = "fixture-paper.pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "Sparse Attention, Revisited: A Workshop Draft"]
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format).pdfData { context in
            context.beginPage()
            ("Sparse Attention, Revisited" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Answers like functions/v1/add-paper would for the fixture's inputs.
final class ScriptedPaperAdding: PaperAddingService, @unchecked Sendable {
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

    func importSources(_ importID: UUID) async throws -> PDFImportSources {
        try await Task.sleep(for: .milliseconds(150))
        return PDFImportSources(import_id: importID, source_id: "openalex:W3100000001", title: "Deep Learning Scaling is Predictable, Empirically",
                                links: ["https://fixture-publisher.example.org/blocked.pdf", "https://doi.org/10.5555/fixture.1"])
    }
}

/// Fetches the fixture's "website" without a network: the sample PDF, or (for the blocked link) a refusal.
struct FixturePDFFetcher: DevicePDFFetching {
    func fetch(_ links: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> DevicePDF {
        for step in 1...4 { try await Task.sleep(for: .milliseconds(400)); progress(Double(step) / 4) }
        if links.contains(where: { $0.absoluteString == AddPaperFixture.blockedLink }) { throw DeviceFetchError.blocked }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-device-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: try AddPaperFixture.samplePDF(), to: copy)
        return DevicePDF(file: copy, title: nil, link: links[0])
    }
}

extension ReaderModel {
    /// `--add-paper-fixture`: two failed web imports (a website that blocks servers, and a paper with no
    /// open copy) and an upload queue that sends to the script; a finished upload appears as an import.
    func configureAddPaperFixture() throws {
        func failed(_ id: UUID, sequence: Int, title: String, authors: [String], error: String) throws -> LibraryImportRecord {
            let value: [String: Any] = ["id": id.wire, "created_seq": sequence, "state_seq": sequence, "intent_revision": 1, "visible": true,
                "phase": "failed", "source": "web", "source_id": "openalex:W310000000\(sequence)", "source_revision": 1,
                "metadata_id": UUID().wire, "version_id": UUID().wire,
                "metadata": ["title": title, "authors": authors, "published_at": "2017-12-01", "categories": []] as [String: Any],
                "metadata_recorded_at": "2026-10-07T09:00:00Z", "source_url": "https://openalex.org/works/W310000000\(sequence)",
                "error_code": error, "retryable": true]
            return try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: value))
        }
        insertFixtureImport(try failed(AddPaperFixture.closedImport, sequence: 2, title: "Optuna: A Next-generation Hyperparameter Optimization Framework",
                                       authors: ["Takuya Akiba", "Shotaro Sano"], error: "not_open"))
        insertFixtureImport(try failed(AddPaperFixture.blockedImport, sequence: 1, title: "Deep Learning Scaling is Predictable, Empirically",
                                       authors: ["Joel Hestness", "Sharan Narang"], error: "source_blocked"))
        guard let service = AddPaperFixture.service else { return }
        uploads.fetcher = FixturePDFFetcher()
        uploads.activate(.init(service: service, accountID: AddPaperFixture.accountID, deploymentID: "add-paper-fixture",
            cursor: { 0 }, added: {},
            // PDFs stay on this device (2026-10-13): a chosen, shared or downloaded PDF is saved here, never sent.
            installLocal: { [weak self] _, checked, target in try self?.installFixtureLocalPDF(checked, target: target) }))
        // `--share-inbox-fixture`: what the Share extension would have saved — a PDF from Files and a link from Safari.
        if ProcessInfo.processInfo.arguments.contains("--share-inbox-fixture"), let inbox = Self.shareInbox {
            try? FileManager.default.removeItem(at: inbox.root)
            _ = try inbox.addPDF(from: try AddPaperFixture.samplePDF(), title: "shared-draft")
            _ = try inbox.addLink(URL(string: AddPaperFixture.blockedLink)!, title: nil)
        }
        importSharedItems()
    }
}
#endif

import Foundation
import ScienceReaderCore

/// The outcome of the Add sheet's "arXiv ID, DOI or link" (functions/v1/add-paper).
/// `link`: what this device can fetch when our servers can't (`blocked`, `link_only`, `closed`).
struct AddPaperResult: Decodable, Sendable, Equatable {
    let status: String
    let route: String?
    let paper: AddReferenceResult.Paper?
    let link: String?
    let reason: String?
    let title: String?
}

/// Where an uploaded PDF goes (docs/architecture/PDF_UPLOADS.md): a paper of its own, a failed
/// import it supplies (device fallback), or a known paper that isn't openly available.
enum PDFUploadTarget: Codable, Sendable, Equatable, Hashable {
    case newPaper
    case importID(UUID, revision: Int64)
    case source(String)

    /// A web paper (`openalex:W…`) an upload can attach to; other identities (a DOI OpenAlex
    /// doesn't know) upload as a paper of their own under the paper's title.
    static func forPaper(sourceID: String?) -> Self {
        guard let sourceID, LibrarySource.isWebSourceID(sourceID) else { return .newPaper }
        return .source(sourceID)
    }
}

/// What the reader can do next after an Add that didn't queue a paper.
enum AddNextStep: Equatable, Sendable, Hashable {
    /// Choose the PDF from Files (or drop it); it attaches to `target`.
    case uploadPDF(target: PDFUploadTarget, title: String?)
    /// Fetch the PDF over this device's own network, then upload it to `target`.
    case downloadOnDevice(link: URL, target: PDFUploadTarget, title: String?)

    var title: String {
        switch self {
        case .uploadPDF: "Upload the PDF…"
        case .downloadOnDevice: "Download on this device"
        }
    }
    var identifier: String {
        switch self {
        case .uploadPDF: "add.next.upload"
        case .downloadOnDevice: "add.next.device"
        }
    }
}

/// The Add sheet's message after a lookup, in the reader's words, with the next steps.
struct AddOutcome: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case added, present, closed, blocked, linkOnly, notFound, needsUpdate, unavailable, invalid }
    let kind: Kind
    let message: String
    var steps: [AddNextStep] = []

    /// The paper is queued (or already there): the sheet can close.
    var finished: Bool { kind == .added }

    static func from(_ result: AddPaperResult) -> AddOutcome {
        let named = result.paper.map { "“\($0.title)”" }
        let title = result.paper?.title ?? result.title
        let link = result.link.flatMap(Self.httpsURL)
        switch result.status {
        case "added":
            return .init(kind: .added, message: "Added \(named ?? "the paper"). It’s being prepared to read.")
        case "present":
            return .init(kind: .present, message: "\(named ?? "This paper") is already in your library.")
        case "closed":
            let target = PDFUploadTarget.forPaper(sourceID: result.paper?.source_id)
            var steps: [AddNextStep] = [.uploadPDF(target: target, title: title)]
            if let link { steps.append(.downloadOnDevice(link: link, target: target, title: title)) }
            return .init(kind: .closed, message: "\(named ?? "This paper") isn’t openly available. If you have the PDF, upload it and it will be converted for you alone.", steps: steps)
        case "blocked":
            let why: String
            switch result.reason {
            case "pdf_restricted": why = "This paper’s website needs a sign-in or subscription, so our servers can’t download it."
            case "source_unavailable": why = "The paper’s website isn’t responding to our servers."
            default: why = "The paper’s website blocked the download from our servers."
            }
            var steps: [AddNextStep] = []
            if let link { steps.append(.downloadOnDevice(link: link, target: .newPaper, title: title)) }
            steps.append(.uploadPDF(target: .newPaper, title: title))
            return .init(kind: .blocked, message: why + " Your device may still be able to download it.", steps: steps)
        case "link_only":
            var steps: [AddNextStep] = []
            if let link { steps.append(.downloadOnDevice(link: link, target: .newPaper, title: title)) }
            steps.append(.uploadPDF(target: .newPaper, title: title))
            let name = title.map { "“\($0)”" } ?? "This link"
            return .init(kind: .linkOnly, message: "\(name) isn’t a paper we could identify, but it leads to a PDF. Download it on this device to add it.", steps: steps)
        case "not_found":
            return .init(kind: .notFound, message: "Couldn’t find a paper for this. Check the ID or link, or upload the PDF.",
                         steps: [.uploadPDF(target: .newPaper, title: nil)])
        case "needs_update":
            return .init(kind: .needsUpdate, message: "\(named ?? "This paper") needs the latest version of Gradstep.")
        case "invalid":
            return .invalidInput
        default:
            return .init(kind: .unavailable, message: "Couldn’t add it right now. Check your connection and try again.")
        }
    }

    static let invalidInput = AddOutcome(kind: .invalid, message: "Enter an arXiv ID, a DOI, or a link to a paper or PDF.")
    static let unavailable = AddOutcome(kind: .unavailable, message: "Couldn’t add it right now. Check your connection and try again.")

    /// Only https links are offered for a device download (the fetcher checks them again).
    static func httpsURL(_ value: String) -> URL? {
        guard value.utf8.count <= 2_000, let components = URLComponents(string: value), components.scheme == "https",
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

/// What the reader typed in Add: an arXiv ID or link is added on this device (queued even offline,
/// as before); anything else is identified by the server.
enum AddInput: Equatable, Sendable {
    case arxiv(ArxivReference)
    case lookup(String)
    case empty

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { self = .empty }
        else if let reference = try? ArxivReference(text) { self = .arxiv(reference) }
        else { self = .lookup(String(text.prefix(2_000))) }
    }
}

/// The Add sheet's and uploads' network calls: the backend in the app, a script in UI fixtures.
protocol PaperAddingService: Sendable {
    func addPaper(_ query: String) async throws -> AddPaperResult
    func beginUpload(_ job: PDFUploadJob) async throws -> PDFUploadTicket
    func sendUpload(file: URL, path: String, token: String, progress: @escaping @Sendable (Double) -> Void) async throws
    func finalizeUpload(_ uploadID: UUID, observedCursor: Int64) async throws
    func importSources(_ importID: UUID) async throws -> PDFImportSources
}

/// The signed-in account's backend.
struct BackendPaperAdding: PaperAddingService {
    let backend: BackendClient
    let accountID: UUID
    func addPaper(_ query: String) async throws -> AddPaperResult { try await backend.addPaper(query, accountID: accountID) }
    func beginUpload(_ job: PDFUploadJob) async throws -> PDFUploadTicket { try await backend.beginPDFUpload(job, accountID: accountID) }
    func sendUpload(file: URL, path: String, token: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await backend.sendPDFUpload(file: file, path: path, token: token, accountID: accountID, progress: progress)
    }
    func finalizeUpload(_ uploadID: UUID, observedCursor: Int64) async throws {
        try await backend.finalizePDFUpload(uploadID, observedCursor: observedCursor, accountID: accountID)
    }
    func importSources(_ importID: UUID) async throws -> PDFImportSources { try await backend.importPDFSources(importID, accountID: accountID) }
}

extension LibraryImportRecord {
    /// A web paper or a reader's own upload can take a PDF from this device; arXiv papers always come from arXiv.
    var canTakeUpload: Bool { LibrarySource.isWebSourceID(sourceID) || LibrarySource.isUploadSourceID(sourceID) }
}

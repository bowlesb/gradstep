import CryptoKit
import Foundation
import PDFKit
import ScienceReaderCore

// Device-only PDF intake. Historical queue records are recognized and stopped;
// chosen, dropped, shared and downloaded files are checked and installed locally.
// No upload session, storage write or server conversion is requested.

/// Why a file cannot be opened on this device.
enum PDFFileProblem: Error, Equatable, Sendable {
    case notPDF, empty, tooLarge, tooManyPages, locked, unreadable

    var message: String {
        switch self {
        case .notPDF: "This file isn’t a PDF."
        case .empty: "This file is empty."
        case .tooLarge: "This PDF is larger than 64 MB, the device reader’s current limit."
        case .tooManyPages: "This PDF has more than 250 pages, the device reader’s current limit."
        case .locked: "This PDF is password-protected. Save a copy without the password, then add that."
        case .unreadable: "This PDF couldn’t be opened. It may be damaged."
        }
    }
}

/// A locally checked PDF: its exact size and SHA-256, its pages, and a title.
struct CheckedPDF: Equatable, Sendable {
    let sha256: String
    let byteCount: Int64
    let pages: Int
    let title: String
}

enum PDFFileCheck {
    static let maximumBytes: Int64 = 64 * 1024 * 1024
    static let maximumPages = 250
    static let maximumTitle = 500

    /// Device admission rules: `%PDF-` first, at most 64 MiB, 1–250 pages, readable.
    /// `preferred`: the paper's known title (it wins); `fallback`: a name to use when the PDF has no title of its own.
    static func check(_ url: URL, title preferred: String? = nil, fallback: String? = nil) throws -> CheckedPDF {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size == 0 { throw PDFFileProblem.empty }
        if size > maximumBytes { throw PDFFileProblem.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 5), head == Data("%PDF-".utf8) else { throw PDFFileProblem.notPDF }
        try handle.seek(toOffset: 0)
        var hasher = SHA256(); var read: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk); read += Int64(chunk.count)
        }
        guard read == size else { throw PDFFileProblem.unreadable }
        guard let document = PDFDocument(url: url) else { throw PDFFileProblem.unreadable }
        if document.isLocked { throw PDFFileProblem.locked }
        let pages = document.pageCount
        if pages < 1 { throw PDFFileProblem.unreadable }
        if pages > maximumPages { throw PDFFileProblem.tooManyPages }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return CheckedPDF(sha256: digest, byteCount: size, pages: pages,
                          title: cleanTitle(preferred) ?? documentTitle(document) ?? cleanTitle(fallback) ?? fileTitle(url))
    }

    /// The PDF's own title when it looks like one (not "Microsoft Word - draft.docx" or "untitled").
    static func documentTitle(_ document: PDFDocument) -> String? {
        guard let raw = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
              let title = cleanTitle(raw), title.count >= 6,
              title.range(of: #"^(microsoft (word|powerpoint)|untitled|document\d*$|.*\.(docx?|tex|pdf)$)"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return title
    }

    /// The file's name as a title: "sparse_attention-v2.pdf" → "sparse attention-v2".
    static func fileTitle(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        return cleanTitle(name) ?? "Uploaded PDF"
    }

    /// One line, no control characters, at most 500 characters (the server's rule).
    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let scalars = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let text = scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maximumTitle))
    }
}

/// One queued upload, saved beside its file until the server has it.
struct PDFUploadJob: Codable, Equatable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable { case waiting, uploading, finishing, failed }
    let id: UUID
    /// The server's upload (and operation) ID; replaced only when a session expired unfinished.
    var uploadID: UUID
    let accountID: UUID
    let createdAt: Date
    var title: String
    let sha256: String
    let byteCount: Int64
    let target: PDFUploadTarget
    var phase: Phase = .waiting
    /// A stop the reader must act on (`phase == .failed`), or why it is waiting.
    var issue: String?
    var issueCode: String?
    var attempts = 0
    var nextAttemptAt: Date?
    /// The library cursor sent with the first finalize; kept so a retried finalize is identical.
    var observedCursor: Int64?
}

/// One server-admitted chunk. `uncertain` counts attempts whose physical write may have happened but
/// whose acknowledgement was lost; those attempts remain liability until the server reconciles them.
struct PDFUploadPart: Decodable, Equatable, Sendable {
    let index: Int
    let bytes: Int
    let verified: Bool
    let attempts: Int
    let uncertain: Int
}

/// Ticket for sending the bytes. The optional `path`/`token` fields are retained only for the local
/// fixture and for decoding a pre-chunk deployment; staging and production use the chunk fields.
struct PDFUploadTicket: Decodable, Equatable, Sendable {
    let upload_id: UUID
    let state: String
    let revision: Int64?
    let generation: Int64?
    let byte_count: Int64?
    let chunk_bytes: Int?
    let part_count: Int?
    let parts: [PDFUploadPart]?
    let descriptor_required: Bool?
    let descriptor_ref: LibraryDescriptorReference?
    let path: String?
    let token: String?

    init(upload_id: UUID, state: String, path: String? = nil, token: String? = nil,
         revision: Int64? = nil, generation: Int64? = nil, byte_count: Int64? = nil,
         chunk_bytes: Int? = nil, part_count: Int? = nil, parts: [PDFUploadPart]? = nil,
         descriptor_required: Bool? = nil, descriptor_ref: LibraryDescriptorReference? = nil) {
        self.upload_id = upload_id; self.state = state; self.revision = revision; self.generation = generation
        self.byte_count = byte_count; self.chunk_bytes = chunk_bytes; self.part_count = part_count; self.parts = parts
        self.descriptor_required = descriptor_required; self.descriptor_ref = descriptor_ref
        self.path = path; self.token = token
    }

    var isChunked: Bool {
        generation != nil && revision != nil && chunk_bytes != nil && part_count != nil && parts != nil
    }
}

/// The begin request commits every part digest before the server admits any physical write. Hash one
/// bounded chunk at a time so a maximum-size PDF never becomes a second in-memory copy.
private func pdfUploadPartDigests(_ file: URL, byteCount: Int64) throws -> [String] {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var remaining = byteCount, result: [String] = []
    while remaining > 0 {
        let expected = Int(min(Int64(PDFUploadCenter.chunkBytes), remaining))
        guard let bytes = try handle.read(upToCount: expected), bytes.count == expected else { throw BackendError.transport }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        result.append(digest); remaining -= Int64(expected)
    }
    guard remaining == 0, result.count <= 16 else { throw BackendError.transport }
    return result
}

/// Links this device can try for a failed web import (`v1_import_pdf_sources`).
struct PDFImportSources: Decodable, Equatable, Sendable {
    let import_id: UUID
    let source_id: String
    let title: String?
    let links: [String]
}

/// The backend's answers an upload can act on.
enum PDFUploadFailure {
    /// The reader must change something; the job stops with this message.
    static func permanent(_ code: String) -> String? {
        switch code {
        case "upload_too_large": PDFFileProblem.tooLarge.message
        case "upload_quota": "Your private storage is full. Remove uploaded papers you no longer need, then try again."
        case "insufficient_credits": "Converting a PDF needs credits. Get credits, then try again."
        case "upload_target_unavailable", "import_not_retryable": "This paper no longer takes a PDF. Add the PDF on its own instead."
        case "key_authority_required": "Unlock this device's library before uploading a PDF."
        case "library_descriptor_required": "This upload needs the device's library keys. Unlock the library, then try again."
        case "invalid_upload": "This PDF couldn’t be sent."
        default: nil
        }
    }
    /// Waits worth naming (otherwise "Waiting for a connection").
    static func waiting(_ code: String) -> String {
        switch code {
        case "upload_limit", "library_active_import_limit": "Waiting for other papers to finish"
        case "upload_storage_full": "Uploads are paused for a while"
        case "rate_limited", "request_rate_limit": "Waiting a moment before trying again"
        default: "Waiting for a connection"
        }
    }
}

/// Files on disk, per deployment and account: `<root>/<deployment>/<account>/<job>/{job.json,paper.pdf}`.
struct PDFUploadStore: Sendable {
    let root: URL

    static func standard() throws -> PDFUploadStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return PDFUploadStore(root: support.appendingPathComponent("PDFUploads", isDirectory: true))
    }

    func directory(deployment: String, account: UUID) -> URL {
        let key = SHA256.hash(data: Data(deployment.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true).appendingPathComponent(account.uuidString.lowercased(), isDirectory: true)
    }
    func folder(_ job: UUID, deployment: String, account: UUID) -> URL {
        directory(deployment: deployment, account: account).appendingPathComponent(job.uuidString.lowercased(), isDirectory: true)
    }
    func file(_ job: UUID, deployment: String, account: UUID) -> URL {
        folder(job, deployment: deployment, account: account).appendingPathComponent("paper.pdf")
    }

    /// Copies the reader's file in (never moves or edits theirs) and saves the job beside it.
    func adopt(_ source: URL, job: PDFUploadJob, deployment: String) throws {
        let folder = folder(job.id, deployment: deployment, account: job.accountID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let target = folder.appendingPathComponent("paper.pdf")
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        try save(job, deployment: deployment)
    }

    func save(_ job: PDFUploadJob, deployment: String) throws {
        let data = try JSONEncoder().encode(job)
        try data.write(to: folder(job.id, deployment: deployment, account: job.accountID).appendingPathComponent("job.json"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(deployment: String, account: UUID) -> [PDFUploadJob] {
        let directory = directory(deployment: deployment, account: account)
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("job.json")),
                  let job = try? JSONDecoder().decode(PDFUploadJob.self, from: data), job.accountID == account,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("paper.pdf").path) else {
                // A half-written job (crash while copying) has nothing to resume.
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            return job
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func delete(_ job: UUID, deployment: String, account: UUID) {
        try? FileManager.default.removeItem(at: folder(job, deployment: deployment, account: account))
    }
}

/// The app's uploads: what the Library and Add sheet show, and the worker that sends them.
@MainActor @Observable
final class PDFUploadCenter {
    /// Must stay in lockstep with `PDF_CHUNK_BYTES` in `_shared/pdf-uploads.ts` and migration 039.
    nonisolated static let chunkBytes = 4_194_304

    struct Context {
        let service: any PaperAddingService
        let accountID: UUID
        let deploymentID: String
        /// The library's committed cursor (nil until the library has loaded).
        let cursor: @MainActor () -> Int64?
        /// A paper reached the library (refresh it).
        let added: @MainActor () -> Void
        /// Device-only sink. No upload transport is used by a production client.
        var installLocal: (@MainActor (URL, CheckedPDF, PDFUploadTarget) async throws -> Void)? = nil
    }

    /// Reader-visible state of each queued upload, oldest first.
    private var activationID = UUID()
    private(set) var jobs: [PDFUploadJob] = []
    /// Bytes sent of the job being uploaded (0…1).
    private(set) var progress: [UUID: Double] = [:]
    /// The latest finished upload, for a short confirmation.
    private(set) var notice: String?
    /// Asks the root view to present the document picker for this target.
    var pickRequest: PickRequest?
    /// A PDF that couldn't be queued (picked or dropped), for an alert.
    var problem: String?
    /// A link shared to Gradstep, for the Add sheet to look up when it opens.
    var sharedLink: String?
    /// Shared items being queued now (an inbox scan never queues one twice).
    @ObservationIgnored var sharedInFlight = Set<UUID>()
    /// Downloads on this device in progress or stopped (device fallback), before their upload is queued.
    private(set) var fetches: [DeviceFetch] = []
    /// This device's fetcher (a script in UI fixtures).
    @ObservationIgnored var fetcher: any DevicePDFFetching = DevicePDFFetcher()

    struct DeviceFetch: Identifiable, Equatable {
        let id: UUID
        let title: String
        var progress: Double?
        var issue: String?
        /// The page to open in Safari when the download didn't work here either.
        let page: URL?
        let target: PDFUploadTarget
    }

    struct PickRequest: Identifiable, Equatable {
        let id = UUID()
        let target: PDFUploadTarget
        let title: String?
    }

    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private let store: PDFUploadStore?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// Back-off between automatic attempts: 5 s, 30 s, 2 min, 10 min, then every 30 min.
    static let backoff: [TimeInterval] = [5, 30, 120, 600, 1_800]

    init(store: PDFUploadStore? = try? .standard(), now: @escaping () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store; self.now = now; self.sleep = sleep
    }

    var isActive: Bool { context != nil }
    var pending: [PDFUploadJob] { jobs.filter { $0.phase != .failed } }
    var failed: [PDFUploadJob] { jobs.filter { $0.phase == .failed } }

    /// Starts (or restarts) the queue for one signed-in account; its unsent uploads resume.
    func activate(_ context: Context) {
        if let current = self.context, current.accountID == context.accountID, current.deploymentID == context.deploymentID {
            self.context = context; resume(); return
        }
        deactivate()
        self.context = context
        jobs = store?.load(deployment: context.deploymentID, account: context.accountID) ?? []
        for index in jobs.indices where jobs[index].phase != .failed { jobs[index].phase = .waiting; jobs[index].nextAttemptAt = nil }
        resume()
    }

    /// Sign-out or account change: stop sending. The files stay for that account's next sign-in.
    func deactivate() {
        activationID = UUID()
        worker?.cancel(); worker = nil; wake?.cancel(); wake = nil
        context = nil; jobs = []; progress = [:]; notice = nil; pickRequest = nil; fetches = []; problem = nil; sharedLink = nil
    }

    /// Device fallback: fetches the PDF over this device's network (the server's checks), then queues its
    /// upload to `target`. Progress and a failure (with what to try next) show in the Library.
    func downloadOnDevice(links: [URL], title: String?, target: PDFUploadTarget) async {
        guard let account = context?.accountID, !links.isEmpty else { return }
        let activation = activationID
        let fetch = DeviceFetch(id: UUID(), title: title ?? links[0].host() ?? "the paper", progress: 0, issue: nil, page: links.last, target: target)
        fetches.append(fetch)
        do {
            let pdf = try await fetcher.fetch(links) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, let index = self.fetches.firstIndex(where: { $0.id == fetch.id }) else { return }
                    self.fetches[index].progress = fraction
                }
            }
            defer { try? FileManager.default.removeItem(at: pdf.file) }
            guard context?.accountID == account, activationID == activation else { return }
            try await add(file: pdf.file, title: title ?? pdf.title, target: target)
            fetches.removeAll { $0.id == fetch.id }
        } catch is CancellationError {
            fetches.removeAll { $0.id == fetch.id }
        } catch {
            guard context?.accountID == account, activationID == activation, let index = fetches.firstIndex(where: { $0.id == fetch.id }) else { return }
            fetches[index].progress = nil
            fetches[index].issue = (error as? DeviceFetchError)?.message ?? (error as? PDFFileProblem)?.message ?? DeviceFetchError.failed.message
        }
    }

    func dismissFetch(_ id: UUID) { fetches.removeAll { $0.id == id } }

    /// Checks and queues a PDF from Files, a drop, the share inbox or a device download.
    @discardableResult
    func add(file: URL, title: String? = nil, fallbackTitle: String? = nil, target: PDFUploadTarget) async throws -> PDFUploadJob {
        guard let context else { throw BackendError.signInRequired }
        let activation = activationID
        let checked = try await Task.detached(priority: .userInitiated) { try PDFFileCheck.check(file, title: title, fallback: fallbackTitle) }.value
        guard self.context?.accountID == context.accountID, activationID == activation else { throw CancellationError() }
        guard let install = context.installLocal else { throw BackendError.rejected("pdf_device_only") }
        try await install(file, checked, target)
        guard self.context?.accountID == context.accountID, activationID == activation else { throw CancellationError() }
        notice = "Saved “\(checked.title)” on this device."
        context.added()
        return PDFUploadJob(id: UUID(), uploadID: UUID(), accountID: context.accountID, createdAt: now(), title: checked.title,
                               sha256: checked.sha256, byteCount: checked.byteCount, target: target)

    }

    /// Try waiting uploads now (foreground, network back, the reader's Try again).
    func resume() {
        worker?.cancel(); worker = nil; wake?.cancel(); wake = nil
        for index in jobs.indices where jobs[index].phase != .failed {
            jobs[index].phase = .failed
            jobs[index].issue = "PDFs now stay on your device. Add this file again to save a local copy."
            jobs[index].issueCode = "pdf_device_only"
        }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].phase = .waiting; jobs[index].issue = nil; jobs[index].issueCode = nil; jobs[index].attempts = 0; jobs[index].nextAttemptAt = nil
        persist(jobs[index]); resume()
    }

    /// Removes a stopped (or unwanted) upload and its local copy. A finalized upload is already in the library.
    func remove(_ id: UUID) {
        guard let context, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs.remove(at: index)
        progress[id] = nil
        store?.delete(job.id, deployment: context.deploymentID, account: job.accountID)
    }

    func clearNotice() { notice = nil }

    private func persist(_ job: PDFUploadJob) {
        guard let context, let store else { return }
        try? store.save(job, deployment: context.deploymentID)
    }

    private func update(_ job: PDFUploadJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job; persist(job)
    }


}

private struct PDFUploadRestart: Error {}
private struct PDFUploadWaitForLibrary: Error {}

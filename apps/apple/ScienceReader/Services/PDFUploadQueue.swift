import CryptoKit
import Foundation
import PDFKit
import ScienceReaderCore

// PDF uploads (docs/architecture/PDF_UPLOADS.md): a durable, per-account queue on this device. A PDF the
// reader picks, drops, shares or downloads here is copied into the app's own storage first, checked the
// way the server will check it, then sent: begin (the server checks size, quota and credits, and signs
// an upload URL), the bytes straight to private Storage, finalize (the import appears in the library).
// Every step is retry-safe: the upload ID is the operation ID, a lost answer is replayed, an expired
// session starts again under a new ID, and unsent work resumes on the next launch or foreground.

/// Why a file can't be uploaded, in the reader's words. Checked on this device the way the server checks.
enum PDFFileProblem: Error, Equatable, Sendable {
    case notPDF, empty, tooLarge, tooManyPages, locked, unreadable

    var message: String {
        switch self {
        case .notPDF: "This file isn’t a PDF."
        case .empty: "This file is empty."
        case .tooLarge: "This PDF is larger than 64 MB, the most Gradstep can convert."
        case .tooManyPages: "This PDF has more than 250 pages, the most Gradstep can convert."
        case .locked: "This PDF is password-protected. Save a copy without the password, then add that."
        case .unreadable: "This PDF couldn’t be opened. It may be damaged."
        }
    }
}

/// A local PDF as the server will verify it: its exact size and SHA-256, its pages, and a title.
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

    /// The same rules the worker applies: `%PDF-` first, at most 64 MiB, 1–250 pages, readable.
    static func check(_ url: URL, title preferred: String? = nil) throws -> CheckedPDF {
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
                          title: cleanTitle(preferred) ?? documentTitle(document) ?? fileTitle(url))
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

/// Ticket for sending the bytes: the session's path and signed token (nil once the server has them).
struct PDFUploadTicket: Decodable, Equatable, Sendable {
    let upload_id: UUID
    let state: String
    let path: String
    let token: String?
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
    struct Context {
        let service: any PaperAddingService
        let accountID: UUID
        let deploymentID: String
        /// The library's committed cursor (nil until the library has loaded).
        let cursor: @MainActor () -> Int64?
        /// A paper reached the library (refresh it).
        let added: @MainActor () -> Void
    }

    /// Reader-visible state of each queued upload, oldest first.
    private(set) var jobs: [PDFUploadJob] = []
    /// Bytes sent of the job being uploaded (0…1).
    private(set) var progress: [UUID: Double] = [:]
    /// The latest finished upload, for a short confirmation.
    private(set) var notice: String?
    /// Asks the root view to present the document picker for this target.
    var pickRequest: PickRequest?
    /// A PDF that couldn't be queued (picked or dropped), for an alert.
    var problem: String?

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
        worker?.cancel(); worker = nil; wake?.cancel(); wake = nil
        context = nil; jobs = []; progress = [:]; notice = nil; pickRequest = nil
    }

    /// Checks and queues a PDF from Files, a drop, the share inbox or a device download.
    @discardableResult
    func add(file: URL, title: String? = nil, target: PDFUploadTarget) async throws -> PDFUploadJob {
        guard let context, let store else { throw BackendError.signInRequired }
        let checked = try await Task.detached(priority: .userInitiated) { try PDFFileCheck.check(file, title: title) }.value
        guard self.context?.accountID == context.accountID else { throw CancellationError() }
        let job = PDFUploadJob(id: UUID(), uploadID: UUID(), accountID: context.accountID, createdAt: now(), title: checked.title,
                               sha256: checked.sha256, byteCount: checked.byteCount, target: target)
        try await Task.detached(priority: .userInitiated) { try store.adopt(file, job: job, deployment: context.deploymentID) }.value
        guard self.context?.accountID == context.accountID else { store.delete(job.id, deployment: context.deploymentID, account: job.accountID); throw CancellationError() }
        jobs.append(job); notice = nil
        resume()
        return job
    }

    /// Try waiting uploads now (foreground, network back, the reader's Try again).
    func resume() {
        guard context != nil, worker == nil else { return }
        wake?.cancel(); wake = nil
        worker = Task { [weak self] in await self?.drain(); self?.worker = nil; self?.scheduleWake() }
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

    private func scheduleWake() {
        guard context != nil else { return }
        let due = jobs.filter { $0.phase == .waiting }.compactMap(\.nextAttemptAt).min()
        guard let due else { return }
        let delay = max(1, due.timeIntervalSince(now()))
        wake = Task { [weak self, sleep] in
            try? await sleep(.seconds(delay))
            guard !Task.isCancelled else { return }
            self?.wake = nil; self?.resume()
        }
    }

    /// Sends due uploads one at a time, oldest first.
    private func drain() async {
        while let context, !Task.isCancelled,
              let job = jobs.first(where: { $0.phase == .waiting && ($0.nextAttemptAt.map { $0 <= now() } ?? true) }) {
            await send(job, context: context)
        }
    }

    private func send(_ original: PDFUploadJob, context: Context) async {
        guard let store else { return }
        var job = original
        job.phase = .uploading; job.issue = nil; job.issueCode = nil; update(job)
        let file = store.file(job.id, deployment: context.deploymentID, account: job.accountID)
        do {
            let ticket = try await context.service.beginUpload(job)
            guard self.context?.accountID == context.accountID else { return }
            switch ticket.state {
            case "pending":
                guard let token = ticket.token else { throw BackendError.transport }
                progress[job.id] = 0
                let id = job.id
                try await context.service.sendUpload(file: file, path: ticket.path, token: token) { [weak self] fraction in
                    Task { @MainActor in self?.progress[id] = fraction }
                }
            case "finalized", "consumed":
                break // the server has it; finalize replays its answer
            default:
                // The session ended unfinished (expired): start again under a new upload ID.
                throw PDFUploadRestart()
            }
            guard self.context?.accountID == context.accountID else { return }
            job.phase = .finishing; update(job); progress[job.id] = nil
            guard let cursor = job.observedCursor ?? context.cursor() else { throw PDFUploadWaitForLibrary() }
            job.observedCursor = cursor; update(job)
            try await context.service.finalizeUpload(job.uploadID, observedCursor: cursor)
            guard self.context?.accountID == context.accountID else { return }
            jobs.removeAll { $0.id == job.id }
            store.delete(job.id, deployment: context.deploymentID, account: job.accountID)
            notice = "Added “\(job.title)”. It’s being prepared to read."
            context.added()
        } catch {
            guard self.context?.accountID == context.accountID, !(error is CancellationError) else { return }
            progress[job.id] = nil
            let code: String? = { if case BackendError.rejected(let code) = error { return code }; return nil }()
            if error is PDFUploadRestart || code == "upload_expired" || code == "upload_id_conflict" {
                job.uploadID = UUID(); job.observedCursor = nil; job.phase = .waiting; job.attempts = 0; job.nextAttemptAt = nil
            } else if let code, let message = PDFUploadFailure.permanent(code) {
                job.phase = .failed; job.issue = message; job.issueCode = code
            } else {
                job.attempts += 1
                job.phase = .waiting
                job.issue = error is PDFUploadWaitForLibrary ? "Waiting for your library" : PDFUploadFailure.waiting(code ?? "")
                job.nextAttemptAt = now().addingTimeInterval(Self.backoff[min(job.attempts - 1, Self.backoff.count - 1)])
            }
            update(job)
        }
    }
}

private struct PDFUploadRestart: Error {}
private struct PDFUploadWaitForLibrary: Error {}

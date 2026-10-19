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

/// A queued upload record written by a build before the device-only cutover. It is decoded so the
/// reader can save that file on this device or remove it; no build sends it.
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

/// Links this device can try for a failed web import (`v1_import_pdf_sources`).
struct PDFImportSources: Decodable, Equatable, Sendable {
    let import_id: UUID
    let source_id: String
    let title: String?
    let links: [String]
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
    typealias LocalInstaller = @MainActor (URL, CheckedPDF, PDFUploadTarget) async throws -> Void
    struct Context {
        let service: any PaperAddingService
        let accountID: UUID
        let deploymentID: String
        /// The library's committed cursor (nil until the library has loaded).
        let cursor: @MainActor () -> Int64?
        /// A paper reached the library (refresh it).
        let added: @MainActor () -> Void
        /// Device-only sink. No upload transport is used by a production client.
        var installLocal: LocalInstaller? = nil
        /// Captures the selected catalog before file checking or downloading suspends.
        var captureLocalInstall: (@MainActor () -> LocalInstaller)? = nil
    }

    /// Legacy queued uploads found on this device, oldest first (every one is stopped).
    private var activationID = UUID()
    private(set) var jobs: [PDFUploadJob] = []
    /// Retained for the banner API; no legacy job ever reports upload progress now.
    private(set) var progress: [UUID: Double] = [:]
    /// The latest file saved on this device, for a short confirmation.
    private(set) var notice: String?
    /// Asks the root view to present the document picker for this target.
    var pickRequest: PickRequest?
    /// A PDF that couldn't be queued (picked or dropped), for an alert.
    var problem: String?
    /// A link shared to Gradstep, for the Add sheet to look up when it opens.
    var sharedLink: String?
    /// Shared items being queued now (an inbox scan never queues one twice).
    @ObservationIgnored var sharedInFlight = Set<UUID>()
    /// Downloads on this device in progress or stopped (device fallback), before they are saved locally.
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
    @ObservationIgnored private let store: PDFUploadStore?
    @ObservationIgnored private let now: () -> Date

    init(store: PDFUploadStore? = try? .standard(), now: @escaping () -> Date = Date.init) {
        self.store = store; self.now = now
    }

    var isActive: Bool { context != nil }
    var pending: [PDFUploadJob] { jobs.filter { $0.phase != .failed } }
    var failed: [PDFUploadJob] { jobs.filter { $0.phase == .failed } }

    /// Starts (or restarts) the queue for one signed-in account; its legacy queued files are listed as stopped.
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

    /// Sign-out or account change. Legacy files stay for that account's next sign-in.
    func deactivate() {
        activationID = UUID()
        context = nil; jobs = []; progress = [:]; notice = nil; pickRequest = nil; fetches = []; problem = nil; sharedLink = nil
    }

    /// Device fallback: fetches the PDF over this device's network (the server's checks), then saves it on
    /// this device for `target`. Progress and a failure (with what to try next) show in the Library.
    func downloadOnDevice(links: [URL], title: String?, target: PDFUploadTarget) async {
        guard let account = context?.accountID, !links.isEmpty else { return }
        let activation = activationID
        let installer = context?.captureLocalInstall?() ?? context?.installLocal
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
            try await add(file: pdf.file, title: title ?? pdf.title, target: target, capturedInstaller: installer)
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

    /// Checks a PDF from Files, a drop, the share inbox or a device download and saves it on this device.
    @discardableResult
    func add(file: URL, title: String? = nil, fallbackTitle: String? = nil, target: PDFUploadTarget, capturedInstaller: LocalInstaller? = nil) async throws -> PDFUploadJob {
        guard let context else { throw BackendError.signInRequired }
        let activation = activationID
        let installer = capturedInstaller ?? context.captureLocalInstall?() ?? context.installLocal
        let checked = try await Task.detached(priority: .userInitiated) { try PDFFileCheck.check(file, title: title, fallback: fallbackTitle) }.value
        guard self.context?.accountID == context.accountID, activationID == activation else { throw CancellationError() }
        guard let install = installer else { throw BackendError.rejected("pdf_device_only") }
        try await install(file, checked, target)
        guard self.context?.accountID == context.accountID, activationID == activation else { throw CancellationError() }
        notice = "Saved “\(checked.title)” on this device."
        context.added()
        return PDFUploadJob(id: UUID(), uploadID: UUID(), accountID: context.accountID, createdAt: now(), title: checked.title,
                               sha256: checked.sha256, byteCount: checked.byteCount, target: target)

    }

    /// Legacy queued uploads are never sent; each is shown stopped with its device-only choice.
    func resume() {
        for index in jobs.indices where jobs[index].phase != .failed {
            jobs[index].phase = .failed
            jobs[index].issue = "PDFs now stay on your device. Add this file again to save a local copy."
            jobs[index].issueCode = "pdf_device_only"
        }
    }

    /// A file queued by a build before the device-only cutover is saved on this device instead of being sent;
    /// the stopped record is removed once the local copy exists.
    func retry(_ id: UUID) {
        guard let context, let store, let job = jobs.first(where: { $0.id == id }) else { return }
        let file = store.file(job.id, deployment: context.deploymentID, account: job.accountID)
        Task { [weak self] in
            do {
                _ = try await self?.add(file: file, title: job.title, target: job.target)
                self?.remove(id)
            } catch {
                guard let self, let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                self.jobs[index].issue = (error as? PDFFileProblem)?.message
                    ?? "This file couldn’t be saved on this device. Remove it and add the PDF again."
            }
        }
    }

    /// Removes a stopped legacy record and the file it queued.
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
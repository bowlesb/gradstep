import SwiftUI
import UniformTypeIdentifiers
import ScienceReaderCore

// PDF uploads in the Library (docs/architecture/PDF_UPLOADS.md): the picker a row asks for, the status of
// uploads still on their way, and dropping PDFs on iPad.

/// Queues a PDF the reader chose (Files or a drop): copies it into the app while access lasts.
@MainActor
enum PDFUploadIntake {
    static func add(_ url: URL, target: PDFUploadTarget, title: String?, model: ReaderModel) async -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await model.uploads.add(file: url, title: title, target: target); return nil }
        catch let problem as PDFFileProblem { return problem.message }
        catch is CancellationError { return nil }
        catch BackendError.signInRequired { return "Sign in to add papers to your library." }
        catch { return "Couldn’t add this PDF. Check there’s room on this device and try again." }
    }

    /// Files dropped on the Library or the Add sheet (iPad, Mac): each PDF is copied before the drop ends.
    static func loadDropped(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            let copy: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    guard let url else { continuation.resume(returning: nil); return }
                    // The provider's file is deleted when this handler returns.
                    let name = url.lastPathComponent.isEmpty ? "dropped.pdf" : url.lastPathComponent
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        .appendingPathComponent(name)
                    do {
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: target)
                        continuation.resume(returning: target)
                    } catch { continuation.resume(returning: nil) }
                }
            }
            if let copy { urls.append(copy) }
        }
        return urls
    }
}

/// The document picker a Library row asks for (Upload PDF on an import that needs one).
struct PDFUploadPresenter: ViewModifier {
    @Bindable var model: ReaderModel

    func body(content: Content) -> some View {
        let center = model.uploads
        content
            .fileImporter(isPresented: Binding(get: { center.pickRequest != nil && !Self.fixturePicks }, set: { if !$0 { center.pickRequest = nil } }),
                          allowedContentTypes: [.pdf]) { result in
                guard let request = center.pickRequest else { return }
                center.pickRequest = nil
                if case .success(let url) = result { take(url, request) }
            }
            .onChange(of: center.pickRequest) { _, request in
                // UI fixtures can't drive the system picker: they pick the sample PDF.
                guard Self.fixturePicks, let request else { return }
                center.pickRequest = nil
                #if DEBUG && FIXTURE_HOST
                if let url = try? AddPaperFixture.samplePDF() { take(url, request) }
                #endif
            }
            .alert("Couldn’t add the PDF", isPresented: Binding(get: { center.problem != nil }, set: { if !$0 { center.problem = nil } })) {
                Button("OK") { center.problem = nil }
            } message: { Text(center.problem ?? "") }
    }

    private func take(_ url: URL, _ request: PDFUploadCenter.PickRequest) {
        Task { if let message = await PDFUploadIntake.add(url, target: request.target, title: request.title, model: model) { model.uploads.problem = message } }
    }

    static var fixturePicks: Bool {
        #if DEBUG && FIXTURE_HOST
        return AddPaperFixture.isEnabled
        #else
        return false
        #endif
    }
}

/// Uploads on their way to the Library, above its rows: sending (with progress), waiting (and why), or
/// stopped (what to do). A finished upload says so briefly; its paper appears as an import.
struct PDFUploadBanners: View {
    @Bindable var model: ReaderModel
    var body: some View {
        let center = model.uploads
        VStack(spacing: 8) {
            ForEach(center.jobs) { job in
                if job.phase == .failed {
                    StatusBanner(tone: .problem, systemImage: "exclamationmark.triangle", message: "“\(job.title)”: \(job.issue ?? "Couldn’t upload this PDF.")",
                                 actionsBelow: true, messageID: "upload.issue") {
                        if job.issueCode == "insufficient_credits" { Button("Get credits") { model.showStore = true } }
                        Button("Try again") { center.retry(job.id) }.accessibilityIdentifier("upload.retry")
                        Button("Remove", role: .destructive) { center.remove(job.id) }.accessibilityIdentifier("upload.remove")
                    }
                } else {
                    StatusBanner(tone: .info, systemImage: "arrow.up.doc", message: status(job, progress: center.progress[job.id]), messageID: "upload.status") {
                        if job.phase == .uploading || job.phase == .finishing { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let notice = center.notice {
                StatusBanner(tone: .info, systemImage: "checkmark.circle", message: notice, messageID: "upload.notice") {
                    Button("OK") { center.clearNotice() }
                }
                .task(id: notice) { try? await Task.sleep(for: .seconds(6)); if center.notice == notice { center.clearNotice() } }
            }
        }
    }

    private func status(_ job: PDFUploadJob, progress: Double?) -> String {
        switch job.phase {
        case .uploading:
            if let progress, progress > 0 { return "Uploading “\(job.title)” · \(Int((progress * 100).rounded()))%" }
            return "Uploading “\(job.title)”"
        case .finishing: return "Adding “\(job.title)” to your library"
        case .waiting: return "“\(job.title)” · \(job.issue ?? "Waiting to upload")"
        case .failed: return job.issue ?? ""
        }
    }

    static func shows(_ model: ReaderModel) -> Bool { !model.uploads.jobs.isEmpty || model.uploads.notice != nil }
}

extension View {
    /// Accepts PDFs dropped from Files or another app (iPad, Mac): each becomes an upload of its own.
    func acceptsDroppedPDFs(model: ReaderModel, isTargeted: Binding<Bool>? = nil) -> some View {
        onDrop(of: [.pdf], isTargeted: isTargeted) { providers in
            guard model.uploads.isActive else { return false }
            Task { @MainActor in
                for url in await PDFUploadIntake.loadDropped(providers) {
                    if let message = await PDFUploadIntake.add(url, target: .newPaper, title: nil, model: model) { model.uploads.problem = message }
                }
            }
            return true
        }
    }
}

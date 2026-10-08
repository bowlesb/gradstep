import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share › Gradstep: saves a shared PDF or link to the app's inbox (no network, no account access here);
/// Gradstep adds it the next time it opens. docs/architecture/PDF_UPLOADS.md "Share extension".
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(state: state) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                     host.view.topAnchor.constraint(equalTo: view.topAnchor),
                                     host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
        Task { await save() }
    }

    private func save() async {
        guard let inbox = ShareInbox.shared() else { state.finish(.failed("Open Gradstep once, then share again.")); return }
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let title = items.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty }
        // A PDF first (a PDF viewer may also offer its URL); else a web link.
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) {
            do {
                let name = try await savePDF(provider, inbox: inbox)
                state.finish(.saved("“\(name)” will be added to your library when you open Gradstep."))
            } catch { state.finish(.failed((error as? ShareInboxError)?.message ?? "This PDF couldn’t be saved.")) }
            return
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            if url.isFileURL, url.pathExtension.lowercased() == "pdf" {
                do {
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    _ = try inbox.addPDF(from: url, title: url.deletingPathExtension().lastPathComponent)
                    state.finish(.saved("“\(url.deletingPathExtension().lastPathComponent)” will be added to your library when you open Gradstep."))
                } catch { state.finish(.failed((error as? ShareInboxError)?.message ?? "This PDF couldn’t be saved.")) }
                return
            }
            do {
                _ = try inbox.addLink(url, title: title)
                state.finish(.saved("Gradstep will look up this link when you open it."))
            } catch { state.finish(.failed((error as? ShareInboxError)?.message ?? "This link couldn’t be saved.")) }
            return
        }
        state.finish(.failed(ShareInboxError.unsupported.message))
    }

    /// The provider's file exists only while its handler runs: it is copied into the inbox there.
    private func savePDF(_ provider: NSItemProvider, inbox: ShareInbox) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                guard let url else { continuation.resume(throwing: error ?? ShareInboxError.unsupported); return }
                let name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                do { _ = try inbox.addPDF(from: url, title: name); continuation.resume(returning: name) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor @Observable
final class ShareState {
    enum Outcome: Equatable { case saving, saved(String), failed(String) }
    var outcome: Outcome = .saving
    func finish(_ outcome: Outcome) { self.outcome = outcome }
}

struct ShareView: View {
    let state: ShareState
    let done: () -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch state.outcome {
                case .saving:
                    ProgressView("Saving…")
                case .saved(let message):
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                    Text(message).multilineTextAlignment(.center)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange).accessibilityHidden(true)
                    Text(message).multilineTextAlignment(.center)
                }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Add to Gradstep").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done).disabled(state.outcome == .saving) } }
        }
    }
}

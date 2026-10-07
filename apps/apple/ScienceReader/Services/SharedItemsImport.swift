import Foundation
import ScienceReaderCore

/// Adds what was shared to Gradstep (Share › Gradstep) once someone is signed in: each PDF goes to the
/// upload queue (its banner shows in the Library); a link opens Add, which looks it up and offers the next
/// step. One link at a time; the rest wait for the next foreground. docs/architecture/PDF_UPLOADS.md
extension ReaderModel {
    /// The inbox this app reads (the app group's; a private folder in UI fixtures).
    static var shareInbox: ShareInbox? {
        #if DEBUG && FIXTURE_HOST
        if ProcessInfo.processInfo.arguments.contains("--share-inbox-fixture") {
            return ShareInbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("ShareInboxFixture", isDirectory: true))
        }
        #endif
        return ShareInbox.shared()
    }

    func importSharedItems() {
        guard uploads.isActive, let inbox = Self.shareInbox else { return }
        for item in inbox.pending() where !uploads.sharedInFlight.contains(item.id) {
            switch item.kind {
            case .pdf:
                uploads.sharedInFlight.insert(item.id)
                Task {
                    defer { uploads.sharedInFlight.remove(item.id) }
                    do {
                        try await uploads.add(file: inbox.pdf(item), fallbackTitle: item.title, target: .newPaper)
                        inbox.remove(item)
                    } catch let problem as PDFFileProblem {
                        uploads.problem = "“\(item.title ?? "The shared PDF")”: \(problem.message)"
                        inbox.remove(item)
                    } catch {
                        // Signed out or out of space: it stays for the next time.
                    }
                }
            case .link:
                guard !showImport, uploads.sharedLink == nil, let link = item.url else { continue }
                inbox.remove(item)
                uploads.sharedLink = link
                showImport = true
            }
        }
    }
}

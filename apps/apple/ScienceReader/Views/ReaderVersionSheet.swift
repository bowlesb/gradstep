import SwiftUI
import ScienceReaderCore

/// ⋯ › Reader version details (owner, build 62: "a message you can access… the version reader number for this paper, the
/// current version, and if it's more, the option to update it. We don't need to interrupt an otherwise working reader
/// experience"). Replaces the banner that said an older copy was showing.
struct ReaderVersionSheet: View {
    let model: ReaderModel
    let paper: Paper
    @SheetDismiss private var dismiss

    private var shown: Int? { paper.readerBundle.flatMap(ReaderVersions.revision(of:)) }
    private var current: Int? { ReaderVersions.current }
    private var outdated: Bool { guard let current else { return false }; return shown.map { $0 < current } ?? true }
    private var update: ReaderModel.ReaderUpdate? { model.readerUpdates[paper.id] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("This paper") { Text(shown.map { "Version \($0)" } ?? "An earlier version").accessibilityIdentifier("readerVersion.paper") }
                    if let current { LabeledContent("This app") { Text("Version \(current)").accessibilityIdentifier("readerVersion.app") } }
                } footer: {
                    Text("Each paper is prepared on this device from arXiv’s web version. Updating prepares it again with this app’s reader.")
                }
                if outdated {
                    Section("New since this paper’s version") {
                        ForEach(ReaderVersions.changes(since: shown).filter { current == nil || $0.revision <= current! }) { version in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Version \(version.revision)").font(.subheadline.weight(.semibold))
                                Text(version.note).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        if update?.running == true {
                            HStack(spacing: 10) { ProgressView(); Text("Updating…").foregroundStyle(.secondary) }
                                .accessibilityIdentifier("readerVersion.updating")
                        } else {
                            Button { model.updateReaderCopy() } label: { Label("Update this paper", systemImage: "arrow.triangle.2.circlepath") }
                                .accessibilityIdentifier("readerVersion.update")
                        }
                        if let failure = update?.failure {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure).font(.footnote)
                                if let code = update?.code { Text("Code: \(code)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                            .accessibilityIdentifier("readerVersion.failure")
                        }
                    } footer: { Text("The copy you’re reading stays until the update is ready.") }
                } else {
                    Section {
                        Label(update?.updated == true ? "Updated. This paper uses the latest reader." : "This paper uses the latest reader.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary).accessibilityIdentifier("readerVersion.latest")
                    }
                }
            }
            .navigationTitle("Reader version").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close").accessibilityIdentifier("readerVersion.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

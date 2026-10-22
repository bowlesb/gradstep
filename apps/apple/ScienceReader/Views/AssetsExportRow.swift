import ScienceReaderCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings › Your assets › Download your assets (owner, build 82: "Need a download assets button"): one action at the
/// bottom of the group. The zip is made on this device (AssetsExporter), then offered with the share sheet on iPhone and
/// iPad (Save to Files, AirDrop…) and a save panel on the Mac. Downloaded papers aren't in it; the ⓘ says so.
struct AssetsExportRow: View {
    @Bindable var model: ReaderModel
    @State private var exporter = AssetsExporter()
    @State private var presenting = false

    static let info = "A .zip of your chats, diagrams, snippets (with their images) and the explanations kept on this device, put together here. Downloaded papers aren’t included."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Button { exporter.start(model) } label: { Text(exporter.isPreparing ? "Preparing your assets…" : "Download your assets") }
                    .disabled(exporter.isPreparing)
                    .accessibilityIdentifier("settings.downloadAssets")
                    #if DEBUG && FIXTURE_HOST
                    .accessibilityValue(exporter.files.joined(separator: "\n"))
                    #endif
                InfoButton(text: Self.info, identifier: "settings.downloadAssets.info")
                Spacer(minLength: 0)
            }
            if case .preparing(let done, let total) = exporter.state {
                ProgressView(value: total > 0 ? Double(done) : nil, total: Double(max(total, 1))) {
                    if total > 0 { Text("\(done) of \(total) snippet images").font(.footnote).foregroundStyle(.secondary) }
                }
                .accessibilityIdentifier("settings.downloadAssets.progress")
            }
            if case .failed(let message) = exporter.state {
                Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("settings.downloadAssets.failure")
            } else if !exporter.isPreparing, !exporter.skipped.isEmpty {
                // What the last export left out, as its README lists it.
                Text(exporter.skipped.joined(separator: " ")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.downloadAssets.skipped")
            }
        }
        .onChange(of: exporter.state) { _, state in if case .ready = state { presenting = true } }
        .onChange(of: presenting) { _, now in if !now { exporter.finish() } }
        #if targetEnvironment(macCatalyst)
        .fileExporter(isPresented: $presenting, document: ZipFile(url: readyURL), contentType: .zip, defaultFilename: readyURL?.lastPathComponent) { _ in }
        #else
        .sheet(isPresented: $presenting) {
            if let url = readyURL { AssetsShareSheet(url: url).presentationDetents([.medium, .large]).ignoresSafeArea() }
        }
        #endif
    }

    private var readyURL: URL? { if case .ready(let url) = exporter.state { url } else { nil } }
}

/// The share sheet for the finished zip.
private struct AssetsShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "settings.downloadAssets.share"
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The finished zip as the Mac's save panel writes it.
private struct ZipFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let url: URL?
    init(url: URL?) { self.url = url }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try FileWrapper(url: url, options: .immediate)
    }
}

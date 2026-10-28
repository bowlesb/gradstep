import ScienceReaderCore
import SwiftUI
import UniformTypeIdentifiers

/// The on-device model at work on the open paper (docs/architecture/DEVICE_PDF_ROUTE.md): what it is reading,
/// how far it is, how long it has taken, and a way to stop. The page stays readable underneath.
struct DeviceModelProgressBar: View {
    let run: DeviceModelRun
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On-device model · experimental").font(.footnote.weight(.semibold))
                    TimelineView(.periodic(from: run.started, by: 1)) { context in
                        let elapsed = Int(context.date.timeIntervalSince(run.started))
                        Text("\(run.stageText) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    #if !targetEnvironment(macCatalyst)
                    // iOS pauses an app in the background and stops its GPU work: the reading needs the app open.
                    Text("Keep Gradstep open while it reads.").font(.caption).foregroundStyle(.secondary)
                    #endif
                }
                Spacer(minLength: 0)
                Button("Stop", role: .cancel, action: cancel).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityIdentifier("deviceModel.stop")
            }
            ProgressView(value: run.fraction).progressViewStyle(.linear)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceModel.progress")
    }
}

/// Above a reading the on-device model made: that it is one, what it did, and the ways out (report it, go back
/// to the HTML reading).
struct DeviceModelBanner: View {
    let summary: DeviceModelSummary?
    let report: () -> Void
    let showHTML: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "cpu").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Read by the on-device model · experimental").font(.footnote.weight(.semibold))
                Text(summary?.line ?? "Formulas it was unsure of are shown as images of the page.").font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Menu {
                Button(action: report) { Label("Report a problem with this reading", systemImage: "ladybug") }
                Button(action: showHTML) { Label("Show the HTML reading", systemImage: "doc.richtext") }
            } label: { Image(systemName: "ellipsis.circle").imageScale(.large) }
                .accessibilityLabel("On-device reading options").accessibilityIdentifier("deviceModel.options")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceModel.banner")
    }
}

/// Why the last model reading did not finish.
struct DeviceModelIssueBar: View {
    let issue: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(issue).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceModel.issue")
    }
}

/// The on-device model's download, offered where a reading's progress shows when the models are not on this device yet
/// (DEVICE_PDF_ROUTE.md "The models as a download"): its size, a Wi-Fi note on cellular, progress and Cancel. The reading
/// starts by itself once the models are in.
struct DeviceModelDownloadBar: View {
    let assets: DeviceModelAssets
    let download: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    switch assets.state {
                    case .downloading(let fraction):
                        Text("Downloading PDF reading model").font(.footnote.weight(.semibold))
                        Text("\(Int((fraction * 100).rounded(.down)))% of \(assets.approximateSize.replacingOccurrences(of: "about ", with: "")) · the reading starts when it’s done")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    case .failed(let message):
                        Text("PDF reading model").font(.footnote.weight(.semibold))
                        Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    default:
                        Button(action: download) {
                            Text("Download PDF reading model (\(assets.approximateSize))").font(.footnote.weight(.semibold))
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.borderless).accessibilityIdentifier("deviceModel.download")
                        Text("Reads PDFs on this device once it’s downloaded.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if assets.onExpensiveNetwork {
                        Text("You’re on cellular data; Wi-Fi is better for a download this size.").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if case .failed = assets.state {
                    Button("Try Again", action: download).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .accessibilityIdentifier("deviceModel.downloadAgain")
                }
                Button("Cancel", role: .cancel, action: cancel).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityIdentifier("deviceModel.downloadCancel")
            }
            if case .downloading(let fraction) = assets.state { ProgressView(value: fraction).progressViewStyle(.linear) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceModel.downloadBar")
    }
}

/// Settings › Experimental: the on-device PDF reader in one row (owner, TestFlight 91 session; DECISIONS "One row for the
/// on-device PDF reader"). The switch is on only when chosen and the models are on this device; turning it on without
/// them asks before the download (iPhone, iPad), the row then shows the download with Cancel and the switch comes on
/// when it finishes. On the Mac the models are inside the app: the switch alone.
struct DeviceModelReaderSettingsRow: View {
    @Bindable var model: ReaderModel
    static let info = "Reads a paper’s PDF on this device with Gradstep’s own models (takes longer, can be inaccurate)."

    var body: some View {
        let assets = model.deviceModelAssets
        Group {
            switch model.deviceModelReaderRow {
            case .toggle(let on, let note):
                Toggle(isOn: Binding(get: { on }, set: { model.setDeviceModelReader($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        if let note {
                            Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings.deviceModelNote")
                        }
                    }
                }
                .accessibilityIdentifier("settings.deviceModel")
            case .downloading(let fraction):
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        ProgressView(value: fraction).progressViewStyle(.linear)
                        Text("Downloading · \(Int((fraction * 100).rounded(.down)))% of \(assets.approximateSize.replacingOccurrences(of: "about ", with: ""))")
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            .accessibilityIdentifier("settings.deviceModelProgress")
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { model.setDeviceModelReader(false) }.buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.deviceModelCancel")
                }
                .accessibilityElement(children: .contain)
            }
        }
        .alert("Download the on-device PDF reader?", isPresented: $model.deviceModelDownloadQuestion) {
            Button("Download") { model.confirmDeviceModelDownload() }.accessibilityIdentifier("settings.deviceModelDownload")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(assets.approximateSize.prefix(1).uppercased() + assets.approximateSize.dropFirst() + "."
                 + (assets.onExpensiveNetwork ? " You’re on cellular data; Wi-Fi is better for a download this size." : ""))
        }
    }

    private var title: some View {
        LabelWithInfo(title: "On-device PDF reader", info: Self.info, identifier: "settings.deviceModel.info")
    }
}

/// Settings › Experimental, staff only (grey, like the Admin rows; docs/architecture/TEST_CATALOGS.md): import a folder of
/// PDFs as a catalog the on-device model reads one by one, with one progress line, Pause/Resume and what wasn't read.
struct TestCatalogSettingsRow: View {
    @Bindable var model: ReaderModel
    static let info = "Staff testing. Choose a folder of PDFs: each is added to your library on this device (never uploaded) in a catalog named after the folder, then read by the on-device model one at a time while Gradstep is open. Importing the same folder again skips PDFs already in your library and retries failures."

    var body: some View {
        Group {
            HStack(spacing: 2) {
                Button("Import a folder as a test catalog…") { model.beginTestCatalogImport() }
                    .disabled(!model.canManageCatalogs)
                    .accessibilityIdentifier("settings.testCatalog.import")
                InfoButton(text: Self.info, identifier: "settings.testCatalog.info")
            }
            .listRowBackground(Color.adminRow)
            if model.testCatalog == nil, let note = model.testCatalogWaiting {
                Text(note).font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.adminRow)
                    .accessibilityIdentifier("settings.testCatalog.progress")
            }
            if let queue = model.testCatalog {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(queue.catalogName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(model.testCatalogWaiting ?? queue.line).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            .accessibilityIdentifier("settings.testCatalog.progress")
                    }
                    Spacer(minLength: 0)
                    if !queue.isFinished {
                        Button(queue.paused ? "Resume" : "Pause") { queue.paused ? model.resumeTestCatalog() : model.pauseTestCatalog() }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                            .accessibilityIdentifier("settings.testCatalog.pause")
                    }
                }
                .listRowBackground(Color.adminRow)
                let notRead = queue.failures + queue.skipped
                if !notRead.isEmpty {
                    DisclosureGroup {
                        ForEach(notRead) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.footnote).lineLimit(2)
                                Text(Self.reason(item.status)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } label: {
                        Text("Not read · \(notRead.count)").font(.footnote)
                    }
                    .accessibilityIdentifier("settings.testCatalog.notRead")
                    .listRowBackground(Color.adminRow)
                }
            }
        }
        .fileImporter(isPresented: $model.testCatalogPicking, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { Task { await model.importTestCatalogFolder(folder) } }
        }
    }

    private static func reason(_ status: TestCatalogQueue.Status) -> String {
        switch status {
        case .failed(let reason), .skipped(let reason): reason
        default: ""
        }
    }
}

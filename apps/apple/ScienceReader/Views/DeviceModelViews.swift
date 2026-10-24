import ScienceReaderCore
import SwiftUI

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

/// Settings › Experimental: the on-device PDF model on this device, with the one action that applies (Download, Cancel
/// or Remove). Not shown on the Mac, whose models are inside the app.
struct DeviceModelSettingsRow: View {
    let assets: DeviceModelAssets
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On-device PDF model")
                Text(status).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("settings.deviceModelStatus")
            }
            Spacer(minLength: 0)
            switch assets.state {
            case .ready:
                Button("Remove", role: .destructive) { assets.remove() }.buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.deviceModelRemove")
            case .downloading:
                Button("Cancel") { assets.cancel() }.buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.deviceModelCancel")
            default:
                Button("Download") { Task { await assets.ensureDownloaded() } }.buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.deviceModelDownload")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.deviceModelFile")
    }
    private var status: String {
        switch assets.state {
        case .ready(let bytes, _): "Downloaded · \(DeviceModelAssets.sizeText(bytes))"
        case .downloading(let fraction): "Downloading · \(Int((fraction * 100).rounded(.down)))%"
        case .failed(let message): message
        case .notDownloaded, .unavailable: "Not downloaded · \(assets.approximateSize)" + (assets.onExpensiveNetwork ? " · Wi-Fi recommended" : "")
        }
    }
}

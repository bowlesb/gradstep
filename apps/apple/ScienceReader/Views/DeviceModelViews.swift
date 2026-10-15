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

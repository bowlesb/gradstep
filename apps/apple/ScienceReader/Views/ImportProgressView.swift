import SwiftUI

/// An import in progress, drawn from `ImportProgress` (docs/architecture/IMPORT_PROGRESS.md). While the server
/// gives a percent it redraws every second (the bar moves; the words change in rounded steps, without animation);
/// from older servers it shows a spinner and how long the step has run, once a minute, as before.
///
/// - `.row` (List rows, detailed rows): the step line ("Reading equations and figures (page 12 of 27)"), then a
///   slim bar with "62% · About 40 s left", and an info button when `explain` is set.
/// - `.compact` (a table column of about 100 pt): one word, with the percent when it fits ("Reading 62%"), the
///   bar, and the time on at most two lines ("40 s left").
///
/// The progress is one VoiceOver element ("Reading equations and figures, page 12 of 27, 62 percent, about 40
/// seconds left"); the info button is its own ("Why does this take a minute?").
struct ImportProgressView: View {
    enum Style { case row, compact }
    let progress: ImportProgress
    var style: Style = .row
    /// Shows "Why does this take a minute?" (`ImportProgressExplainer`); rows show an info button when set.
    var explain: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let counting = progress.detail != nil
        TimelineView(.periodic(from: counting ? progress.receivedAt : progress.stepSince ?? progress.receivedAt, by: counting ? 1 : 60)) { context in
            let shown = progress.presentation(at: context.date)
            switch style {
            case .row: row(shown)
            case .compact: compact(shown)
            }
        }
    }

    private func row(_ shown: ImportProgressPresentation) -> some View {
        Group {
            if let fraction = shown.fraction {
                VStack(alignment: .leading, spacing: 5) {
                    // VoiceOver: this line carries the whole sentence; the bar and status are its picture.
                    Text(shown.line).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(shown.accessibilityLabel)
                        .accessibilityIdentifier("importProgress")
                    // The bar and "62% · About 40 s left" on one line when it fits, else the status under the bar.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ImportProgressBar(fraction: fraction).frame(width: 96)
                            if let status = shown.status { Text(status).monospacedDigit().lineLimit(1).fixedSize().accessibilityHidden(true) }
                            if let explain { ImportProgressInfoButton(action: explain) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ImportProgressBar(fraction: fraction).frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 200)
                            HStack(spacing: 6) {
                                if let status = shown.status {
                                    Text(status).monospacedDigit().fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
                                }
                                if let explain { ImportProgressInfoButton(action: explain) }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            } else {
                // Older servers: the spinner and "Downloading the PDF · 2 min", as before.
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(shown.timeText.map { "\(shown.title) · \($0)" } ?? shown.step.label(short: false))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shown.accessibilityLabel)
                    .accessibilityIdentifier("importProgress")
                    if let explain { ImportProgressInfoButton(action: explain) }
                }
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    private func compact(_ shown: ImportProgressPresentation) -> some View {
        Group {
            if let fraction = shown.fraction {
                VStack(alignment: .leading, spacing: 3) {
                    ViewThatFits(in: .horizontal) {
                        Text(shown.percent.map { "\(shown.compactTitle) \($0)%" } ?? shown.compactTitle).monospacedDigit()
                        Text(shown.compactTitle)
                    }
                    .lineLimit(1)
                    ImportProgressBar(fraction: fraction)
                    if let time = shown.compactTimeText {
                        Text(time).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 6) {
                    ImportActivitySpinner()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shown.compactTitle).lineLimit(shown.compactTitleOverride == nil ? 1 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let time = shown.compactTimeText {
                            Text(time).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.accessibilityLabel)
        .accessibilityIdentifier("importProgress")
    }
}

/// Table imports use the regular spinner, centered beside the complete status/timing stack.
struct ImportActivitySpinner: View {
    var body: some View { ProgressView().controlSize(.regular).frame(width: 24, height: 24).accessibilityHidden(true) }
}

/// A slim bar for work under way. Neutral, because it reports rather than invites a tap (DESIGN: accent for
/// tappable things), and so it never reads as the accent bar that shows how far a paper has been read.
struct ImportProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.secondary)
                    .frame(width: max(fraction > 0 ? 4 : 0, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The small "i" beside an import's progress that opens `ImportProgressExplainer`.
struct ImportProgressInfoButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle").font(.footnote.weight(.medium))
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(.tint)
        // A larger target than the glyph without making the row taller.
        .padding(.vertical, -8)
        .accessibilityLabel("Why does this take a minute?")
        .accessibilityIdentifier("importProgress.help")
    }
}

/// "Why does this take a minute?": what happens between Add and reading, once, in the reader's words.
struct ImportProgressExplainer: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let symbol: String, title: String, text: String
        var id: String { title }
    }
    private let steps = [
        Step(symbol: "magnifyingglass", title: LibraryImportStep.finding.title,
             text: "Its title, authors and license."),
        Step(symbol: "arrow.down.circle", title: LibraryImportStep.downloading.title,
             text: "From arXiv, or an open-access copy from the publisher or a repository."),
        Step(symbol: "function", title: LibraryImportStep.converting.title,
             text: "Every page is read to pick out its text, equations and figures. This is the longest step, so long papers take longer."),
        Step(symbol: "doc.richtext", title: LibraryImportStep.building.title,
             text: "The text, equations and figures are laid out for your screen."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Gradstep makes a readable version of each paper you add: text that fits your screen, equations you can select and ask about, and figures you can open.")
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(steps) { step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: step.symbol).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.title).font(.headline)
                                    Text(step.text).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text("Most papers are ready in about a minute; long ones take a few. It carries on while you do other things, even if you leave the app.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Getting a paper ready").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("importProgress.explainer")
    }
}

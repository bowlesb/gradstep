import SwiftUI
import ScienceReaderCore

/// Listen on a paper without an episode: an explicit, bounded private generation (docs/DECISIONS.md, "Paper podcasts
/// v1", Decision 3). Nothing is held until the reader confirms the quote; status is the server's, polled; charges are
/// shown only as the server reports them.
struct PodcastGenerateSheet: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    private var center: PodcastCenter { model.podcasts }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let generation = center.generation {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(generation.paperTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let notice = center.notice { PodcastNoticeBanner(center: center, message: notice) }
                        content(generation)
                    }
                    .padding(DesignMetrics.margin)
                    .frame(maxWidth: DesignMetrics.column).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Listen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeTitle) { dismiss() }.accessibilityIdentifier("podcast.generate.close")
                }
            }
        }
        .presentationDetents([.large])
    }

    private var closeTitle: String {
        if case .running = center.generation?.phase { return "Close" }
        if case .quoted = center.generation?.phase { return "Not now" }
        return "Close"
    }

    @ViewBuilder private func content(_ generation: PodcastGeneration) -> some View {
        switch generation.phase {
        case .offer:
            Text("There’s no episode for this paper yet. You can create a private, five-minute episode: two AI hosts — an explainer and a skeptical reader — discuss the paper, with a transcript linked to its passages.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Only your account can play it. You’ll see the credit estimate before anything is held.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { center.requestQuote() } label: { ProminentLabel(title: "Get an estimate", fullWidth: true) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.quote")
        case .quoting, .starting:
            HStack(spacing: 10) { ProgressView(); Text(generation.phase == .quoting ? "Getting an estimate…" : "Starting…") }
                .accessibilityElement(children: .combine)
        case .quoted(let quote):
            quoteCard(quote)
        case .running(let job):
            progress(job)
        case .finished(let job):
            finished(job)
        case .failed(let message):
            StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: message, messageID: "podcast.generate.error") { EmptyView() }
            Button("Try again") { center.requestQuote() }.font(.body.weight(.semibold))
        }
    }

    private func quoteCard(_ quote: PodcastQuote) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(quote.estimate).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.estimate")
                Text("Starting holds up to \(quote.maxCredits) credits. You’re charged for the work actually done, and the rest is released. If the episode fails our checks, nothing is charged.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let balance = model.creditBalance {
                    Text("Available: \(balance.available) credits").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Label { Text("The paper’s converted text is sent to " + quote.providers.joined(separator: " and ") + ".") } icon: { PodcastConsentIcon(name: "server.rack") }
                Label { Text("The episode and its transcript are stored privately for your account, like your uploaded PDFs. They aren’t end-to-end encrypted.") } icon: { PodcastConsentIcon(name: "lock") }
                Label { Text("Your chats, notes and highlights are never used.") } icon: { PodcastConsentIcon(name: "bubble.left.and.bubble.right") }
                Label { Text("AI-generated · beta: check important claims against the paper.") } icon: { PodcastConsentIcon(name: "waveform") }
            }
            .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Button { center.startGeneration() } label: { ProminentLabel(title: "Create episode · up to \(quote.maxCredits) credits", fullWidth: true) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.start")
                .accessibilityHint("Holds up to \(quote.maxCredits) credits and starts making a private episode")
        }
    }

    private static let steps: [(PodcastJobState, String)] = [
        (.queued, "Waiting to start"), (.scripting, "Writing the script from the paper"), (.checking, "Checking it against the paper"),
        (.synthesizing, "Recording the two voices"), (.verifying, "Checking the audio"), (.publishing, "Finishing up"),
    ]

    private func progress(_ job: PodcastJob) -> some View {
        let index = Self.steps.firstIndex { $0.0 == job.state }
        return VStack(alignment: .leading, spacing: 12) {
            if job.state == .capacityWait {
                StatusBanner(tone: .info, systemImage: "hourglass", message: "Waiting for storage capacity. It continues automatically.")
            }
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { offset, step in
                HStack(spacing: 10) {
                    Group {
                        if let index, offset < index { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        else if offset == index { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }.frame(width: 22).accessibilityHidden(true)
                    Text(step.1).font(.body.weight(offset == index ? .semibold : .regular))
                        .foregroundStyle(index.map { offset <= $0 } ?? false ? Color.primary : Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(index.map { offset < $0 ? "done" : offset == $0 ? "in progress" : "not started" } ?? "")
            }
            Text("Holding up to \(job.heldCredits) credits. You can close this; it keeps going, and Listen on this paper shows its progress.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("podcast.generate.held")
            if job.state.canCancel {
                Button("Cancel episode", role: .destructive) { center.cancelGeneration() }.accessibilityIdentifier("podcast.generate.cancel")
                Text("Canceling stops further work; work already done is charged, within the maximum.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcast.generate.progress")
    }

    @ViewBuilder private func finished(_ job: PodcastJob) -> some View {
        switch job.state {
        case .ready:
            Label("Your episode is ready", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(.tint)
            charges(job)
            Button { center.playGenerated(job) } label: { ProminentLabel(title: "Play episode", fullWidth: true) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.play")
        case .canceled:
            Label("Canceled", systemImage: "xmark.circle").font(.title3.weight(.semibold))
            charges(job)
        case .unknownProvider:
            StatusBanner(tone: .problem, systemImage: "questionmark.circle",
                         message: "We couldn’t confirm the result with a provider. The hold stays until that’s resolved, and you won’t be charged more than the maximum. No automatic retry was made.")
            charges(job)
        case .quarantined:
            StatusBanner(tone: .problem, systemImage: "exclamationmark.shield", message: "This episode is held back for review and can’t be played.")
            charges(job)
        default:
            StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: Self.failure(job.failure), messageID: "podcast.generate.failed") { EmptyView() }
            charges(job)
            Text("Nothing is retried automatically. You can get a new estimate later.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func charges(_ job: PodcastJob) -> some View {
        if let charged = job.chargedCredits {
            Text(charged == 0 ? "No credits were charged." : "Charged \(charged) credits" + (job.releasedCredits.map { " · \($0) released" } ?? "") + ".")
                .font(.subheadline).accessibilityIdentifier("podcast.generate.charged")
        } else {
            Text("Holding up to \(job.heldCredits) credits until the final charge is recorded.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    static func failure(_ code: String?) -> String {
        switch code {
        case "quality_rejected": "The episode didn’t pass our checks against the paper, so it wasn’t published."
        case "source_too_large": "This paper is too long for a five-minute episode."
        case "provider_refused": "A provider declined to make this episode."
        case "worker_interrupted": "Making the episode was interrupted."
        default: "The episode couldn’t be made."
        }
    }
}

/// The consent list's icons share one width, so the lines' text starts in one column.
private struct PodcastConsentIcon: View {
    let name: String
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 26
    var body: some View { Image(systemName: name).foregroundStyle(.secondary).frame(width: width).accessibilityHidden(true) }
}

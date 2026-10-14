import SwiftUI
import ScienceReaderCore

/// Listen on a paper without an episode: an explicit, bounded private generation (docs/DECISIONS.md, "Paper podcasts
/// v1", Decision 3). Nothing is held until the reader confirms the quote; status is the server's, polled; charges are
/// shown only as the server reports them. The chosen length is quoted as soon as it is chosen (a quote holds nothing),
/// so confirming is one step; the balance is shown at the top and lengths beyond it are greyed out.
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
                        if let credits = center.availableCredits {
                            Text("Available: \(credits) credits").font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("podcast.generate.available")
                        }
                        if let notice = center.notice { PodcastNoticeBanner(center: center, message: notice) }
                        if let ready = center.readyNotice { PodcastReadyBanner(center: center, notice: ready) }
                        content(generation)
                    }
                    .padding(DesignMetrics.margin)
                    .frame(maxWidth: DesignMetrics.column).frame(maxWidth: .infinity)
                }
            }
            // The primary action stays in reach: pinned below the scrolling content, never below the fold.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let generation = center.generation { footer(generation) }
            }
            .navigationTitle("Listen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeTitle) { dismiss() }.accessibilityIdentifier("podcast.generate.close")
                }
            }
            // The balance shown is the account's latest; credits move when an episode settles.
            .task { await model.refreshCreditBalance() }
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
            Text(generation.ready.isEmpty
                 ? "There’s no episode for this paper yet. You can create a private episode: two AI hosts — an explainer and a skeptical reader — discuss the paper, with a transcript linked to its passages."
                 : "Each length is its own episode. Play one that’s ready, or create a private episode at another length: two AI hosts — an explainer and a skeptical reader — discuss the paper, with a transcript linked to its passages.")
                .fixedSize(horizontal: false, vertical: true)
            lengthPicker(generation, quote: nil)
            if let ready = generation.readyEpisode(generation.selected) {
                Text("Already made: \(PodcastDuration.spoken(milliseconds: ready.durationMS)). Playing it uses no credits.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let length = generation.selectedLength, !generation.affordable(length, credits: center.availableCredits) {
                Text("Your available credits don’t cover this length’s maximum. Choose a shorter length, or add credits first.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.unaffordable")
            } else {
                Text("Only your account can play it. You’ll see the credit estimate before anything is held.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .quoting:
            lengthPicker(generation, quote: nil)
            HStack(spacing: 10) { ProgressView(); Text("Getting an estimate…") }
                .accessibilityElement(children: .combine).accessibilityIdentifier("podcast.generate.quoting")
        case .starting:
            HStack(spacing: 10) { ProgressView(); Text("Starting…") }
                .accessibilityElement(children: .combine)
        case .quoted(let quote):
            lengthPicker(generation, quote: quote)
            quoteCard(quote)
        case .running(let job):
            progress(job, generation)
        case .finished(let job):
            finished(job)
        case .failed(let failure):
            if failure.isSourceTooLarge {
                sourceTooLarge()
            } else {
                // Another length may still fit (fewer credits, a smaller maximum): the picker stays.
                lengthPicker(generation, quote: nil)
                StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: failure.message, messageID: "podcast.generate.error") { EmptyView() }
                Button("Try again") { center.requestQuote() }
                    .font(.body.weight(.semibold)).accessibilityIdentifier("podcast.generate.retry")
            }
        }
    }

    /// The pinned primary action: Play for a ready length, Create for a quoted one; nothing otherwise.
    @ViewBuilder private func footer(_ generation: PodcastGeneration) -> some View {
        switch generation.phase {
        case .offer:
            if let ready = generation.readyEpisode(generation.selected) {
                footerBar {
                    Button { center.playSelectedReady() } label: {
                        ProminentLabel(title: "Play the \(generation.selectedLength?.label ?? "ready") episode", fullWidth: true)
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.playReady")
                    .accessibilityHint("Already made: \(PodcastDuration.spoken(milliseconds: ready.durationMS)). No credits are used.")
                }
            }
        case .quoted(let quote):
            footerBar {
                Button { center.startGeneration() } label: { ProminentLabel(title: "Create episode · up to \(quote.maxCredits) credits", fullWidth: true) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.start")
                    .accessibilityHint("Holds up to \(quote.maxCredits) credits and starts making a private episode")
            }
        default:
            EmptyView()
        }
    }

    private func footerBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Divider()
            content()
                .padding(.horizontal, DesignMetrics.margin).padding(.vertical, 12)
                .frame(maxWidth: DesignMetrics.column)
        }
        .frame(maxWidth: .infinity)
        .background(Color.chromeBackground)
    }

    /// Short · 5 min · 10 min · 20 min, each with its own maximum (from the quote once there is one), or marked ready.
    /// A length whose maximum exceeds the known balance is greyed out with the reason.
    private func lengthPicker(_ generation: PodcastGeneration, quote: PodcastQuote?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Length").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(generation.lengths) { length in
                let option = quote?.options.first { $0.profile == length.profile } ?? length
                let ready = generation.readyEpisode(length.profile)
                let chosen = generation.selected == length.profile
                let affordable = generation.affordable(option, credits: center.availableCredits)
                Button { center.selectLength(length.profile) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(chosen ? Color.accentColor : Color.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label).font(.body.weight(chosen ? .semibold : .regular)).foregroundStyle(.primary)
                            Text(ready.map { "Ready · \(PodcastDuration.short(milliseconds: $0.durationMS)) · no credits" }
                                 ?? "\(Self.about(seconds: option.targetSeconds)) · up to \(option.maxCredits) credits")
                                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !affordable {
                                Text("Not enough credits").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                    .opacity(affordable ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                .disabled(!affordable)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityHint(affordable ? "" : "Needs up to \(option.maxCredits) credits; \(center.availableCredits ?? 0) available")
                .accessibilityIdentifier("podcast.length.\(length.profile)")
                if length.id != generation.lengths.last?.id { Divider().padding(.leading, 34) }
            }
        }
    }

    /// "About 2½ minutes", "About 10 minutes".
    static func about(seconds: Int) -> String {
        let minutes = Double(seconds) / 60
        if minutes < 1 { return "Under a minute" }
        let whole = Int(minutes), half = minutes - Double(whole) >= 0.5
        return "About \(whole)\(half ? "½" : "") minute\(whole == 1 && !half ? "" : "s")"
    }

    private func quoteCard(_ quote: PodcastQuote) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(quote.label ?? "5 min") episode · \(Self.about(seconds: quote.targetSeconds).lowercased())")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("podcast.generate.quotedLength")
                Text(quote.estimate).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.estimate")
                Text("Starting holds up to \(quote.maxCredits) credits. You’re charged for the work actually done, and the rest is released. If the episode fails our checks, nothing is charged.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Text(PodcastGeneration.expectedWait(targetSeconds: quote.targetSeconds))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private static let steps: [(PodcastJobState, String)] = [
        (.queued, "Waiting to start"), (.scripting, "Writing the script from the paper"), (.checking, "Checking it against the paper"),
        (.synthesizing, "Recording the two voices"), (.verifying, "Checking the audio"), (.publishing, "Finishing up"),
    ]

    private func progress(_ job: PodcastJob, _ generation: PodcastGeneration) -> some View {
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
            if let length = generation.length(of: job) {
                Text(PodcastGeneration.expectedWait(targetSeconds: length.targetSeconds))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.wait")
            }
            Text("Holding up to \(job.heldCredits) credits. You can close this; it keeps going, and you’ll be offered Play in the app when it’s ready. Listen on this paper shows its progress.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("podcast.generate.held")
            if job.cancelRequested {
                Text("Canceling: no further work starts. Work already done is charged, within the maximum.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if job.state.canCancel {
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
            if job.failure == "source_too_large" {
                sourceTooLarge()
                charges(job)
            } else {
                StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: Self.failure(job.failure), messageID: "podcast.generate.failed") { EmptyView() }
                charges(job)
                Text("Nothing is retried automatically. You can get a new estimate later.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// A source-size refusal is a product boundary, not a transient failure. Give the reader a clear explanation and
    /// a route back to an already prepared episode instead of a retry loop that can never fit this source.
    @ViewBuilder private func sourceTooLarge() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This paper is too long for a full-paper episode at any available length", systemImage: "doc.text.magnifyingglass")
                .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                .accessibilityIdentifier("podcast.generate.sourceTooLarge")
            Text("Nothing was charged. Gradstep does not silently cut off a paper, so this request stopped before paid work could continue.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            Button {
                center.generation = nil
                center.listenSelected = true
                model.tab = .feed
                model.wideMode = .feed
                dismiss()
            } label: {
                Label("Browse shared episodes", systemImage: "headphones")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("podcast.generate.browseShared")
            Text("You can also close this sheet and keep reading the paper. Section-based episodes are not available yet.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        case "source_too_large": "This paper is too long for a full-paper episode."
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

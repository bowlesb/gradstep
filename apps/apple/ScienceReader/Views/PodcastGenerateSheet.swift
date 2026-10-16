import SwiftUI
import ScienceReaderCore

/// Listen on a paper without an episode (docs/DECISIONS.md, "Paper podcasts v1", Decision 3; simplified at the owner's
/// request, 2026-10-16: "our podcast UX feels too complex right now ... the important thing is you ask for, it doesnt
/// matter if you leave the page or app, its there for you"). Asking is one action, "Make an episode", with the length
/// and the writer chosen compactly (defaults preselected) and the price said once. After asking there is one calm state:
/// the episode is being made, the reader can leave, and it appears in Listen when it's ready. Nothing is held until
/// Make an episode; the chosen length is quoted as soon as it is chosen (a quote holds nothing).
struct PodcastGenerateSheet: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var center: PodcastCenter { model.podcasts }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let generation = center.generation {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(generation.paperTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if let notice = center.notice { PodcastNoticeBanner(center: center, message: notice) }
                        if let ready = center.readyNotice { PodcastReadyBanner(center: center, notice: ready) }
                        content(generation)
                    }
                    .padding(DesignMetrics.margin)
                    .frame(maxWidth: DesignMetrics.column).frame(maxWidth: .infinity)
                }
            }
            // The one action stays in reach: pinned below the scrolling content, never below the fold.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let generation = center.generation { footer(generation) }
            }
            .navigationTitle("Listen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("podcast.generate.close")
                }
            }
            // The balance is the account's latest; credits move when an episode settles.
            .task { await model.refreshCreditBalance() }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func content(_ generation: PodcastGeneration) -> some View {
        switch generation.phase {
        case .offer, .quoting:
            ask(generation, quote: nil)
        case .quoted(let quote):
            ask(generation, quote: quote)
        case .starting:
            making(generation, job: nil)
        case .running(let job):
            making(generation, job: job)
        case .finished(let job):
            finished(job, generation)
        case .failed(let failure):
            if failure.isSourceTooLarge {
                tooLong()
            } else {
                // Another length may still fit (fewer credits): the choice stays, with one plain sentence.
                ask(generation, quote: nil, problem: failure.message)
            }
        }
    }

    // MARK: Asking

    /// The lengths and writers, the price once, and what happens to the paper's text. One action below.
    private func ask(_ generation: PodcastGeneration, quote: PodcastQuote?, problem: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two AI hosts, an explainer and a skeptical reader, talk through the paper. The transcript links to its passages.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            lengthChooser(generation)
            writerChooser(generation)
            if let problem {
                Text(problem).font(.subheadline).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.error")
            } else {
                price(generation, quote: quote)
            }
            if generation.readyEpisode(generation.selected) == nil {
                Text("To make it, the paper’s text is sent to \(PodcastGeneration.plainProviders(quote?.providers ?? Self.providers(generation))) and deleted once the episode is made. The episode is private to your account (not end-to-end encrypted). AI-generated: check important claims against the paper.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.privacy")
            }
        }
    }

    /// The writers' providers before a quote names them (the quote's own list replaces this once it arrives).
    private static func providers(_ generation: PodcastGeneration) -> [String] {
        [generation.selectedWriter == "anthropic" ? "Anthropic" : generation.writers.isEmpty ? "Anthropic" : "DeepSeek", "Google"]
    }

    /// Short · 5 min · 10 min · 20 min as chips; the chosen one's time and maximum below. A length beyond the known
    /// balance is greyed out; a ready length says it plays free.
    private func lengthChooser(_ generation: PodcastGeneration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Length").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { lengthChips(generation) }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { lengthChips(generation) } }
            }
            if let length = generation.selectedLength {
                Text(Self.lengthLine(generation, length, credits: center.availableCredits))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.lengthLine")
            }
        }
    }

    @ViewBuilder private func lengthChips(_ generation: PodcastGeneration) -> some View {
        ForEach(generation.lengths) { length in
            let chosen = generation.selected == length.profile
            let affordable = generation.affordable(length, credits: center.availableCredits)
            ChipButton(title: length.label, selected: chosen) { center.selectLength(length.profile) }
                .disabled(!affordable)
                .opacity(affordable ? 1 : 0.45)
                .accessibilityLabel(Self.lengthLabel(generation, length, affordable: affordable))
                .accessibilityIdentifier("podcast.length.\(length.profile)")
        }
    }

    /// "10 min, about 10 minutes, up to 300 credits" (or "ready, no credits", or "not enough credits").
    static func lengthLabel(_ generation: PodcastGeneration, _ length: PodcastLength, affordable: Bool) -> String {
        if generation.readyEpisode(length.profile) != nil { return "\(length.label), ready, no credits" }
        let base = "\(length.label), \(about(seconds: length.targetSeconds).lowercased()), up to \(generation.maxCredits(length)) credits"
        return affordable ? base : base + ", not enough credits"
    }

    static func lengthLine(_ generation: PodcastGeneration, _ length: PodcastLength, credits: Int64?) -> String {
        if let ready = generation.readyEpisode(length.profile) {
            return "Already made: \(PodcastDuration.spoken(milliseconds: ready.durationMS)). Playing it uses no credits."
        }
        if !generation.affordable(length, credits: credits) {
            return "Needs up to \(generation.maxCredits(length)) credits; you have \(credits ?? 0). Choose a shorter length."
        }
        return about(seconds: length.targetSeconds)
    }

    /// Who writes the script (owner request 2026-10-14): the writers the server lists for the chosen length, the
    /// default first. Compact: one segmented control, shown only when there is a choice.
    @ViewBuilder private func writerChooser(_ generation: PodcastGeneration) -> some View {
        if generation.writers.count > 1, generation.readyEpisode(generation.selected) == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Written by").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                Picker("Written by", selection: Binding(get: { generation.selectedWriter ?? generation.writers[0].writer }, set: { center.selectWriter($0) })) {
                    ForEach(generation.writers) { writer in Text(writer.label).tag(writer.writer) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("podcast.writer")
            }
        }
    }

    /// The price, said once and plainly: the most it can cost, and that only what's used is charged.
    @ViewBuilder private func price(_ generation: PodcastGeneration, quote: PodcastQuote?) -> some View {
        if let length = generation.selectedLength, generation.readyEpisode(generation.selected) == nil,
           generation.affordable(length, credits: center.availableCredits) {
            let maximum = quote?.maxCredits ?? generation.maxCredits(length)
            Text("Up to \(maximum) credits. You’re charged only for what’s used, and nothing if it can’t be made.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("podcast.generate.price")
        }
    }

    /// "About 2½ minutes", "About 10 minutes".
    static func about(seconds: Int) -> String {
        let minutes = Double(seconds) / 60
        if minutes < 1 { return "Under a minute" }
        let whole = Int(minutes), half = minutes - Double(whole) >= 0.5
        return "About \(whole)\(half ? "½" : "") minute\(whole == 1 && !half ? "" : "s")"
    }

    // MARK: After asking

    /// One calm state instead of stages: it's being made, the reader can leave, and it will be in Listen.
    private func making(_ generation: PodcastGeneration, job: PodcastJob?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text("Making your episode").font(.title3.weight(.semibold))
            Text("You can leave this screen or the app. It’ll be in Listen when it’s ready.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("podcast.generate.leave")
            if let length = job.flatMap({ generation.length(of: $0) }) ?? generation.selectedLength {
                Text(PodcastGeneration.expectedWait(targetSeconds: length.targetSeconds))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("podcast.generate.wait")
            }
            if let job {
                if job.cancelRequested {
                    Text("Canceling.").font(.footnote).foregroundStyle(.secondary)
                } else if job.state.canCancel {
                    Button("Cancel this episode", role: .destructive) { center.cancelGeneration() }
                        .font(.subheadline).padding(.top, 6)
                        .accessibilityIdentifier("podcast.generate.cancel")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("podcast.generate.making")
    }

    @ViewBuilder private func finished(_ job: PodcastJob, _ generation: PodcastGeneration) -> some View {
        switch job.state {
        case .ready:
            Label("Your episode is ready", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(.tint)
            charges(job)
        case .canceled:
            Text("Canceled.").font(.title3.weight(.semibold))
            charges(job)
        case .unknownProvider:
            Text("We couldn’t finish this episode. You won’t be charged more than its maximum.")
                .font(.body).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("podcast.generate.failed")
        case .quarantined:
            Text("This episode is held back for review.").font(.body)
                .accessibilityIdentifier("podcast.generate.failed")
        default:
            if job.failure == "source_too_large" {
                tooLong()
            } else {
                Text("We couldn’t make this episode.").font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("podcast.generate.failed")
                charges(job)
            }
        }
    }

    /// A paper too long for any length is a boundary, not a failure to retry: said plainly, with somewhere to go.
    private func tooLong() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This paper is too long for an episode.")
                .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("podcast.generate.sourceTooLarge")
            Text("Nothing was charged.").font(.body)
            Button {
                center.generation = nil
                center.listenSelected = true
                model.tab = .feed
                model.wideMode = .feed
                dismiss()
            } label: {
                Label("Browse episodes", systemImage: "headphones").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("podcast.generate.browseShared")
        }
    }

    @ViewBuilder private func charges(_ job: PodcastJob) -> some View {
        if let charged = job.chargedCredits {
            Text(charged == 0 ? "Nothing was charged." : "Charged \(charged) credits.")
                .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("podcast.generate.charged")
        }
    }

    // MARK: The one action

    /// Make an episode (or Play a ready length) while asking; Done while it's being made; Play when it's ready;
    /// Try again when it couldn't be made.
    @ViewBuilder private func footer(_ generation: PodcastGeneration) -> some View {
        switch generation.phase {
        case .offer, .quoting, .quoted:
            if let ready = generation.readyEpisode(generation.selected) {
                footerBar {
                    Button { center.playSelectedReady() } label: { ProminentLabel(title: "Play the \(generation.selectedLength?.label ?? "ready") episode", fullWidth: true) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.playReady")
                        .accessibilityHint("Already made: \(PodcastDuration.spoken(milliseconds: ready.durationMS)). No credits are used.")
                }
            } else if let length = generation.selectedLength, generation.affordable(length, credits: center.availableCredits) {
                let quoted: Bool = { if case .quoted = generation.phase { return true }; return false }()
                footerBar {
                    Button { center.startGeneration() } label: {
                        HStack(spacing: 8) {
                            if !quoted { ProgressView().controlSize(.small).tint(colorScheme == .dark ? .black : .white) }
                            ProminentLabel(title: "Make an episode")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).disabled(!quoted)
                    .accessibilityIdentifier("podcast.generate.start")
                    .accessibilityHint(quoted ? "Makes a private episode. Up to \(generation.maxCredits(length)) credits." : "Checking the price")
                }
            }
        case .starting, .running:
            footerBar {
                Button { dismiss() } label: { ProminentLabel(title: "Done", fullWidth: true) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.done")
            }
        case .finished(let job):
            if job.state == .ready {
                footerBar {
                    Button { center.playGenerated(job) } label: { ProminentLabel(title: "Play episode", fullWidth: true) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.play")
                }
            } else if job.state == .failed, job.failure != "source_too_large" {
                retryBar()
            }
        case .failed(let failure):
            if !failure.isSourceTooLarge { retryBar() }
        }
    }

    private func retryBar() -> some View {
        footerBar {
            Button { center.askAgain() } label: { ProminentLabel(title: "Try again", fullWidth: true) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("podcast.generate.retry")
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
}

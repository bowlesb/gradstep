import SwiftUI
import ScienceReaderCore

// The player sheet and the compact player (docs/architecture/PAPER_PODCASTS.md): play/pause, ±15 s, speed, chapters,
// a transcript whose evidence opens the paper, and download. Dismissing the sheet keeps playing; Stop is explicit.

struct PodcastPlayerSheet: View {
    @Bindable var model: ReaderModel
    enum Pane: String, CaseIterable { case transcript = "Transcript", chapters = "Chapters", about = "About" }
    @State private var pane: Pane = .transcript
    @State private var scrubbing: Double?
    @State private var follow = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var center: PodcastCenter { model.podcasts }
    private var player: PodcastPlayer { model.podcasts.player }

    var body: some View {
        NavigationStack {
            if let episode = player.episode {
                // The transport controls and the pane picker stay put; only the chosen pane scrolls, so follow-along
                // (which keeps the passage being read centred) never scrolls the controls away.
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(episode)
                        if let notice = center.notice { PodcastNoticeBanner(center: center, message: notice) }
                        if let ready = center.readyNotice { PodcastReadyBanner(center: center, notice: ready) }
                        controls(episode)
                        if let notice = player.notice {
                            Text(notice).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("podcast.player.notice")
                        }
                        downloadRow(episode)
                        Picker("Show", selection: $pane) {
                            ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("podcast.player.pane")
                    }
                    .padding(.horizontal, DesignMetrics.margin).padding(.bottom, 10)
                    .frame(maxWidth: DesignMetrics.column).frame(maxWidth: .infinity)
                    .background(Color.chromeBackground)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("podcast.player.controls")
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            Group {
                                switch pane {
                                case .transcript: transcript(episode)
                                case .chapters: chapters(episode)
                                case .about: about(episode)
                                }
                            }
                            .padding(.horizontal, DesignMetrics.margin).padding(.top, 12).padding(.bottom, 24)
                            .frame(maxWidth: DesignMetrics.column).frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("podcast.player.content")
                        .onChange(of: currentSegmentID(episode)) { _, id in
                            guard follow, pane == .transcript, let id else { return }
                            if reduceMotion { proxy.scrollTo(id, anchor: .center) }
                            else { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) } }
                        }
                    }
                }
                .navigationTitle("Now playing").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityHint("Closes the player. Playback continues.")
                    }
                    ToolbarItem(placement: .topBarTrailing) { optionsMenu(episode) }
                }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "headphones")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .background { keyboardShortcuts }
        // Over the player: an evidence quote from a paper that isn't in the library.
        .sheet(item: Binding(get: { center.evidenceElsewhere }, set: { center.evidenceElsewhere = $0 })) { item in
            PodcastEvidenceElsewhereSheet(model: model, item: item).macSheetKeys()
        }
    }

    // MARK: Heading and controls

    private func heading(_ episode: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Part of the fixed header: bounded so a long title never crowds out the transcript.
            Text(episode.displayTitle).font(.title3.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("podcast.player.title")
            let line = ([episode.year.map(String.init)] + [authorsLine(episode)] + [episode.topicName]).compactMap { $0 }.filter { !$0.isEmpty }
            if !line.isEmpty { Text(line.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            PodcastBadges(episode: episode, kept: center.isKept(episode.id))
        }
        .padding(.top, 8)
    }

    private func authorsLine(_ episode: PodcastEpisode) -> String? {
        guard let first = episode.authors.first else { return nil }
        return episode.authors.count > 1 ? "\(first) et al." : first
    }

    private func controls(_ episode: PodcastEpisode) -> some View {
        let position = scrubbing.map { Int($0) } ?? player.currentMS
        return VStack(spacing: 10) {
            Slider(value: Binding(get: { Double(scrubbing.map { Int($0) } ?? player.currentMS) },
                                  set: { scrubbing = $0 }),
                   in: 0...Double(max(1, player.durationMS)), onEditingChanged: { editing in
                if !editing, let value = scrubbing { player.seek(toMS: Int(value)); scrubbing = nil }
            })
            .accessibilityLabel("Position")
            .accessibilityValue("\(PodcastDuration.spoken(milliseconds: position)) of \(PodcastDuration.spoken(milliseconds: player.durationMS))")
            .accessibilityIdentifier("podcast.player.position")
            HStack {
                Text(PodcastDuration.clock(milliseconds: position)).accessibilityIdentifier("podcast.player.elapsed")
                Spacer()
                Text("−" + PodcastDuration.clock(milliseconds: max(0, player.durationMS - position)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityHidden(true)
            HStack(spacing: 0) {
                speedMenu
                Spacer(minLength: 8)
                Button { player.skip(by: -PodcastPlayer.skipSeconds) } label: {
                    Image(systemName: "gobackward.15").font(.system(size: 26, weight: .medium)).frame(width: 56, height: 56)
                }.accessibilityLabel("Back 15 seconds").accessibilityIdentifier("podcast.player.back")
                Spacer(minLength: 8)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 68, height: 68)
                        .background(Color.accentColor, in: Circle())
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play").accessibilityIdentifier("podcast.player.toggle")
                Spacer(minLength: 8)
                Button { player.skip(by: PodcastPlayer.skipSeconds) } label: {
                    Image(systemName: "goforward.15").font(.system(size: 26, weight: .medium)).frame(width: 56, height: 56)
                }.accessibilityLabel("Forward 15 seconds").accessibilityIdentifier("podcast.player.forward")
                Spacer(minLength: 8)
                Color.clear.frame(width: 56, height: 1).accessibilityHidden(true)
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                ForEach(PodcastPlayer.rates, id: \.self) { Text(Self.rateLabel($0)).tag($0) }
            }
        } label: {
            Text(Self.rateLabel(player.rate)).font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 56, height: 44).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .accessibilityLabel("Speed").accessibilityValue(Self.rateLabel(player.rate)).accessibilityIdentifier("podcast.player.speed")
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%g×", rate)
    }

    @ViewBuilder private func downloadRow(_ episode: PodcastEpisode) -> some View {
        if let transfer = center.transfer, transfer.releaseID == episode.id, transfer.keep {
            HStack {
                ProgressView(value: transfer.fraction).accessibilityLabel("Downloading").accessibilityValue("\(Int(transfer.fraction * 100)) percent")
                Button("Cancel") { center.cancelTransfer() }.font(.subheadline.weight(.semibold))
            }
        } else if center.isKept(episode.id) {
            Label("Downloaded · plays offline", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("podcast.player.downloaded")
        } else {
            Button { center.download(episode) } label: {
                Label("Download for offline · \(ByteCountFormatter.string(fromByteCount: Int64(episode.audio.bytes), countStyle: .file))",
                      systemImage: "arrow.down.circle")
            }
            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("podcast.player.download")
        }
    }

    private func optionsMenu(_ episode: PodcastEpisode) -> some View {
        Menu {
            if center.isKept(episode.id) {
                MenuRow("Remove download", systemImage: "trash") { center.removeDownload(episode.id) }
            } else {
                MenuRow("Download", systemImage: "arrow.down.circle") { center.download(episode) }
            }
            if center.canChooseLength(for: episode) {
                // Each length is its own episode: play another that's ready, or make one (quoted first).
                MenuRow("Other lengths…", systemImage: "timer") { center.chooseLength(for: episode) }
                    .accessibilityIdentifier("podcast.player.lengths")
            }
            if model.papers.contains(where: { $0.id == episode.documentID }) {
                MenuRow("Open paper", systemImage: GradstepSymbol.paper) {
                    if let paper = model.papers.first(where: { $0.id == episode.documentID }) {
                        dismiss(); model.select(paper); model.tab = .paper
                        if model.wideMode != .browse { model.wideMode = .reader }
                    }
                }
            }
            MenuRow("Report a problem at \(PodcastDuration.clock(milliseconds: player.currentMS))", systemImage: "exclamationmark.bubble") {
                model.beginReport(afterMenu: true)
            }
            Section {
                Button(role: .destructive) { center.stop(); dismiss() } label: { Label("Stop playback", systemImage: "stop.fill") }
                    .accessibilityIdentifier("podcast.player.stop")
            }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("Player options").accessibilityIdentifier("podcast.player.options")
    }

    // MARK: Transcript, chapters, about

    private func currentSegmentID(_ episode: PodcastEpisode) -> String? { episode.transcript?.segment(at: player.currentMS)?.id }

    @ViewBuilder private func transcript(_ episode: PodcastEpisode) -> some View {
        if let transcript = episode.transcript {
            VStack(alignment: .leading, spacing: 4) {
                Text(transcript.disclosure).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if transcript.timing == "approximate" {
                    Text("Times are approximate.").font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Follow along", isOn: $follow).font(.subheadline).padding(.top, 4)
                    .accessibilityHint("Keeps the passage being read in view")
            }
            let current = currentSegmentID(episode)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(transcript.segments) { segment in
                    PodcastSegmentView(segment: segment, speaker: transcript.name(of: segment.speaker), current: segment.id == current,
                                       chapter: episode.chapters?.first { $0.id == segment.chapter && $0.startMS == segment.startMS },
                                       seek: { player.seek(toMS: segment.startMS); if !player.isPlaying { player.play() } },
                                       openEvidence: { center.openEvidence($0, in: episode) })
                        .id(segment.id)
                }
            }
        } else {
            Text("This episode’s transcript isn’t available offline.").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func chapters(_ episode: PodcastEpisode) -> some View {
        let current = player.chapterID
        VStack(spacing: 0) {
            ForEach(episode.chapters ?? []) { chapter in
                Button { player.seek(toMS: chapter.startMS); if !player.isPlaying { player.play() } } label: {
                    HStack(spacing: 12) {
                        Text(PodcastDuration.clock(milliseconds: chapter.startMS)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(minWidth: 48, alignment: .leading)
                        Text(chapter.title).font(.body.weight(chapter.id == current ? .semibold : .regular)).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if chapter.id == current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).accessibilityHidden(true) }
                    }
                    .padding(.vertical, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chapter.title), at \(PodcastDuration.spoken(milliseconds: chapter.startMS))")
                .accessibilityAddTraits(chapter.id == current ? .isSelected : [])
                .accessibilityIdentifier("podcast.chapter.\(chapter.id)")
                Divider()
            }
        }
    }

    @ViewBuilder private func about(_ episode: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(episode.fixture
                 ? "Synthetic fixture: these tones stand in for the hosts, so the app can be tested without generating audio. No AI request was made."
                 : "AI-generated audio adapted from the paper by two synthetic hosts: an explainer and a skeptical reader. It isn’t the authors’ work and doesn’t imply their participation.")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if episode.scope == .private {
                Text("Private · beta: only your account can play this episode. Check claims against the paper, and report anything wrong at the time you heard it.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let source = episode.source {
                if let url = source.url {
                    Link(destination: url) { Label("Source: \(source.arxivID.map { "arXiv:\($0)" + (source.version.map { "v\($0)" } ?? "") } ?? url.host() ?? "paper")", systemImage: "safari") }
                        .font(.subheadline)
                }
                if let license = source.license {
                    Link(destination: license) { Label("License", systemImage: "doc.text") }.font(.subheadline)
                }
            }
            if let authors = LibraryFormat.authorLine(episode.authors) {
                Text("Paper by " + authors)
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Your listening position stays on this device.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Space plays/pauses and the arrow keys skip 15 seconds with a hardware keyboard (iPad, Mac).
    private var keyboardShortcuts: some View {
        Group {
            Button("") { player.toggle() }.keyboardShortcut(.space, modifiers: [])
            Button("") { player.skip(by: -PodcastPlayer.skipSeconds) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { player.skip(by: PodcastPlayer.skipSeconds) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// One transcript passage: speaker, text (tap to play from here), the paper's notation and its evidence quotes.
struct PodcastSegmentView: View {
    let segment: PodcastSegment
    let speaker: String
    let current: Bool
    let chapter: PodcastChapter?
    let seek: () -> Void
    let openEvidence: (PodcastEvidence) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var mathSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chapter {
                Text(chapter.title).font(.headline).padding(.top, 8).accessibilityAddTraits(.isHeader)
            }
            Button(action: seek) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(speaker).font(.caption.weight(.semibold))
                            .foregroundStyle(segment.speaker == .explainer ? Color.accentColor : Color.orange)
                        Text(PodcastDuration.clock(milliseconds: segment.startMS)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(segment.text).font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(current ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(speaker): \(segment.text)")
            .accessibilityHint("Plays from \(PodcastDuration.spoken(milliseconds: segment.startMS))")
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier("podcast.segment.\(segment.id)")
            ForEach(Array(segment.math.enumerated()), id: \.offset) { _, math in mathView(math) }
            ForEach(segment.evidence) { evidence in
                Button { openEvidence(evidence) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.quote").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                        Text("“\(evidence.quote)”").font(.footnote).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.leading, 10)
                .accessibilityLabel("From the paper: \(evidence.quote)")
                .accessibilityHint("Opens the paper at this passage")
                .accessibilityIdentifier("podcast.evidence.\(evidence.id)")
            }
        }
    }

    /// The paper's own notation, typeset; VoiceOver reads how the hosts say it.
    @ViewBuilder private func mathView(_ math: PodcastMath) -> some View {
        Group {
            if let rendered = ChatMathCache.shared.render(math.latex, size: mathSize, display: true, dark: colorScheme == .dark) {
                ViewThatFits(in: .horizontal) {
                    Image(uiImage: rendered.image)
                    ScrollView(.horizontal, showsIndicators: true) { Image(uiImage: rendered.image) }
                }
            } else {
                Text(verbatim: math.latex).font(.system(.footnote, design: .monospaced))
            }
        }
        .padding(.leading, 10)
        .accessibilityElement().accessibilityLabel("Equation: \(math.spoken)")
    }
}

/// The compact player above the tab bar (and along the bottom of the wide layout): title, chapter, time left,
/// play/pause and Stop. The screens' own bottom controls sit above it (it takes part of the tab bar's reserve),
/// so it never covers the chat's message box or the reader's selection actions.
struct PodcastMiniPlayer: View {
    @Bindable var model: ReaderModel
    var wide = false
    static let height: CGFloat = 56
    private var player: PodcastPlayer { model.podcasts.player }

    var body: some View {
        if let episode = player.episode {
            HStack(spacing: 6) {
                Button { model.podcasts.showPlayer = true } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                            Circle().trim(from: 0, to: player.progress).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tint)
                        }
                        .frame(width: 32, height: 32).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(episode.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(subtitle(episode)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(episode.displayTitle), \(PodcastDuration.spoken(milliseconds: max(0, player.durationMS - player.currentMS))) left")
                .accessibilityHint("Opens the player")
                .accessibilityIdentifier("podcast.miniPlayer.open")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play").accessibilityIdentifier("podcast.miniPlayer.toggle")
                Button { model.podcasts.stop() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 40, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Stop playback").accessibilityIdentifier("podcast.miniPlayer.stop")
            }
            .padding(.leading, 10).padding(.trailing, 4)
            .frame(height: Self.height - 6)
            .frame(maxWidth: wide ? 640 : ChromeMetrics.tabBarMaxWidth)
            .chromeSurface(Capsule(), interactive: true)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("podcast.miniPlayer")
        }
    }

    private func subtitle(_ episode: PodcastEpisode) -> String {
        // Time left first: it's what the line is for, and it must survive truncation.
        let left = PodcastDuration.clock(milliseconds: max(0, player.durationMS - player.currentMS)) + " left"
        return ([left, player.chapter?.title, episode.fixture ? "Synthetic fixture" : "AI audio"].compactMap { $0 }).joined(separator: " · ")
    }
}

/// An evidence quote whose paper isn't in this library: show the quote, the source, and an explicit Add.
struct PodcastEvidenceElsewhereSheet: View {
    @Bindable var model: ReaderModel
    let item: PodcastEvidenceElsewhere
    @State private var adding = false
    @State private var outcome: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("This passage is from “\(item.episode.displayTitle)”, which isn’t in your library.").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("“\(item.quote)”").font(.body).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let url = item.episode.source?.url {
                    Link(destination: url) { Label("View source", systemImage: "safari") }.font(.body.weight(.semibold))
                        .accessibilityIdentifier("podcast.evidence.source")
                }
                if let arxiv = item.episode.source?.arxivID {
                    Button {
                        adding = true
                        Task {
                            do { try await model.importPaper(arxiv, stayInSearch: true); outcome = "Added to your library. It opens when it’s ready." }
                            catch { outcome = (error as? BackendError)?.errorDescription ?? "The paper couldn’t be added right now." }
                            adding = false
                        }
                    } label: { ProminentLabel(title: adding ? "Adding…" : "Add paper to library", fullWidth: true) }
                    .buttonStyle(.borderedProminent).disabled(adding || outcome != nil || !model.canBeginImport)
                    .accessibilityIdentifier("podcast.evidence.add")
                }
                if let outcome { Text(outcome).font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(DesignMetrics.margin)
            .navigationTitle("From the paper").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A podcast notice inside a podcast sheet, with its own dismiss.
struct PodcastNoticeBanner: View {
    let center: PodcastCenter
    let message: String
    var body: some View {
        StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: message, messageID: "podcast.notice") {
            Button { center.notice = nil } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                .accessibilityLabel("Dismiss").tint(.secondary)
        }
    }
}

/// An episode made while its sheet was closed is ready: Play it, inside a podcast sheet.
struct PodcastReadyBanner: View {
    let center: PodcastCenter
    let notice: PodcastCenter.ReadyNotice
    var body: some View {
        StatusBanner(tone: .info, systemImage: "checkmark.circle", message: notice.message, messageID: "podcast.ready") {
            Button("Play") { center.playReadyNotice() }.accessibilityIdentifier("podcast.ready.play")
            Button { center.readyNotice = nil } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                .accessibilityLabel("Dismiss").tint(.secondary)
        }
    }
}

/// The podcast sheets and notices, attached once at the root.
struct PodcastPresenter: ViewModifier {
    @Bindable var model: ReaderModel
    func body(content: Content) -> some View {
        @Bindable var center = model.podcasts
        content
            .sheet(isPresented: $center.showPlayer) { PodcastPlayerSheet(model: model).macSheetKeys() }
            .sheet(item: $center.generation) { _ in PodcastGenerateSheet(model: model).macSheetKeys() }
            // While the player or generation sheet is up, they show the notice themselves (a root alert can't present).
            .alert("Listen", isPresented: Binding(get: { center.notice != nil && !center.showPlayer && center.generation == nil },
                                                  set: { if !$0 { center.notice = nil } })) {
                Button("OK") { model.podcasts.notice = nil }
            } message: { Text(model.podcasts.notice ?? "") }
            // An episode that became ready after its sheet was closed: Play now, or later from Listen on the paper.
            .alert("Listen", isPresented: Binding(get: { center.readyNotice != nil && center.notice == nil && !center.showPlayer && center.generation == nil },
                                                  set: { if !$0 { center.readyNotice = nil } }),
                   presenting: center.readyNotice) { ready in
                Button("Play") { center.playReadyNotice(ready) }
                Button("Not now", role: .cancel) { center.readyNotice = nil }
            } message: { ready in Text(ready.message) }
    }
}

/// "Listen" in the Paper "…" menu and a Library row's actions.
struct PodcastListenMenuRow: View {
    @Bindable var model: ReaderModel
    let paper: Paper
    var body: some View {
        if model.podcasts.canListen(to: paper) {
            MenuRow("Listen", systemImage: "headphones") { model.podcasts.listen(to: paper) }
                .accessibilityIdentifier("paper.listen")
        }
    }
}

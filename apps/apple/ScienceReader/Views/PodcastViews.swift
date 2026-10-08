import SwiftUI
import ScienceReaderCore

// Paper podcasts in the Feed (docs/architecture/PAPER_PODCASTS.md, "Product boundary"): a Listen filter beside the
// Feed's topics shows ready shared episodes. The Feed's own arrangement is unchanged; Listen is one more chip, and
// choosing a topic chip returns to the topic's papers.

/// The Listen chip at the start of the Feed's topic row.
struct PodcastListenChip: View {
    @Bindable var model: ReaderModel
    var body: some View {
        if model.podcasts.listenAvailable {
            Button { model.podcasts.listenSelected = true } label: {
                ChipLabel(title: "Listen", selected: model.podcasts.listenSelected, systemImage: "headphones")
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.podcasts.listenSelected ? .isSelected : [])
            .accessibilityHint("Shows paper episodes to listen to")
            .accessibilityIdentifier("feed.listen")
        }
    }
}

/// The Feed while Listen is chosen: the same header (Listen, the topics, "…") over the episode list.
struct PodcastListenView: View {
    @Bindable var model: ReaderModel
    @State private var width: CGFloat = 0
    @Environment(\.tabBarReserve) private var tabBarReserve
    private var center: PodcastCenter { model.podcasts }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch center.catalogState {
                case .idle, .loading:
                    Spacer(); ProgressView("Finding episodes…").accessibilityIdentifier("podcast.loading"); Spacer()
                case .failed(let message):
                    ContentUnavailableView { Label("Episodes unavailable", systemImage: "headphones") }
                        description: { Text(message) }
                        actions: {
                            if model.librarySignInRequired && !model.podcasts.listenAvailable {
                                Button { model.openSignIn() } label: { ProminentLabel(title: "Sign in") }.buttonStyle(.borderedProminent)
                            } else { Button("Try again") { center.loadCatalog() } }
                        }
                case .loaded:
                    if center.catalog.isEmpty && center.keptDownloads.isEmpty {
                        ContentUnavailableView {
                            Label("No episodes yet", systemImage: "headphones")
                        } description: {
                            Text("Shared episodes appear here when they’re ready. A paper’s Listen action can also make a private episode for you.")
                        } actions: {
                            Button("Browse new papers") { center.listenSelected = false }.accessibilityIdentifier("podcast.browsePapers")
                        }
                    } else {
                        list
                    }
                }
            }
            .contentMargins(.bottom, 12, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .tabBarSpace()
            .toolbar(.hidden, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task { if center.catalogState == .idle || center.catalog.isEmpty { center.loadCatalog() } }
        }
    }

    private var list: some View {
        List {
            if let transfer = center.transfer { PodcastTransferBanner(center: center, transfer: transfer).listRowSeparator(.hidden) }
            if !center.keptDownloads.isEmpty {
                Section {
                    ForEach(center.keptDownloads, id: \.episode.id) { record in
                        PodcastEpisodeRow(model: model, episode: record.episode)
                    }
                } header: { Text("Downloaded").accessibilityAddTraits(.isHeader) }
            }
            Section {
                ForEach(center.catalog) { episode in
                    PodcastEpisodeRow(model: model, episode: episode)
                        .onAppear { if episode.id == center.catalog.last?.id { center.loadMoreCatalog() } }
                }
            } header: {
                if !center.keptDownloads.isEmpty && !center.catalog.isEmpty { Text("Shared episodes").accessibilityAddTraits(.isHeader) }
            } footer: {
                Text("Episodes are AI-generated audio adapted from each paper, with a transcript that links to the passages it relies on. Check important claims against the paper.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .refreshable { center.loadCatalog() }
        .readableScrollColumn(width: width)
        .accessibilityIdentifier("podcast.catalog")
    }

    private var header: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PodcastListenChip(model: model)
                    ForEach(model.feedCategories, id: \.self) { category in
                        ChipButton(title: ArxivTopics.name(for: category), selected: false) {
                            center.listenSelected = false
                            model.selectFeedCategory(category)
                        }.accessibilityIdentifier("feed.topic.\(category)")
                    }
                }
            }
            .mask(HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            })
            Menu {
                Section {
                    MenuRow("Refresh episodes", systemImage: "arrow.clockwise") { center.loadCatalog() }
                }
                Section { MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) } }
            } label: { HeaderButtonLabel(systemImage: "ellipsis") }
            .buttonStyle(.plain).accessibilityLabel("Listen options")
        }
        .readableColumn().padding(.top, 2).padding(.bottom, 8)
        .chromeBand(.top)
    }
}

/// An episode card: paper title, year, duration and topic, an AI-audio badge (and the fixture label), Play.
struct PodcastEpisodeRow: View {
    @Bindable var model: ReaderModel
    let episode: PodcastEpisode
    @ScaledMetric(relativeTo: .body) private var playSize: CGFloat = 40
    private var center: PodcastCenter { model.podcasts }
    private var playing: Bool { center.nowPlaying?.id == episode.id && center.player.isPlaying }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: playSize * 0.38, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: playSize, height: playSize)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.displayTitle).font(.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Text(metadata).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                PodcastBadges(episode: episode, kept: center.isKept(episode.id),
                              remainingMS: center.resumePosition(episode.id).map { episode.durationMS - $0 },
                              finished: center.isFinished(episode.id))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { center.play(episode) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(playing ? "Opens the player" : "Plays this episode")
        .accessibilityAction(named: center.isKept(episode.id) ? "Remove download" : "Download") { toggleDownload() }
        .accessibilityIdentifier("podcast.episode.\(episode.id.wire)")
        .contextMenu {
            Button { center.play(episode) } label: { Label("Play", systemImage: "play.fill") }
            Button { toggleDownload() } label: {
                Label(center.isKept(episode.id) ? "Remove download" : "Download", systemImage: center.isKept(episode.id) ? "trash" : "arrow.down.circle")
            }
            if center.resumePosition(episode.id) != nil || center.isFinished(episode.id) {
                Button { center.clearHistory(episode.id) } label: { Label("Clear progress", systemImage: "arrow.counterclockwise") }
            }
        }
    }

    private func toggleDownload() { center.isKept(episode.id) ? center.removeDownload(episode.id) : center.download(episode) }

    private var metadata: String {
        ([episode.year.map(String.init), PodcastDuration.short(milliseconds: episode.durationMS)].compactMap { $0 } + [episode.topic].compactMap { $0 })
            .joined(separator: " · ")
    }

    private var spokenLabel: String {
        var parts = [episode.displayTitle]
        if let year = episode.year { parts.append(String(year)) }
        parts.append(PodcastDuration.spoken(milliseconds: episode.durationMS))
        if let topic = episode.topic { parts.append(topic) }
        parts.append("AI audio")
        if episode.fixture { parts.append("synthetic fixture") }
        if episode.scope == .private { parts.append("private") }
        if center.isKept(episode.id) { parts.append("downloaded") }
        if playing { parts.append("playing") }
        return parts.joined(separator: ", ")
    }
}

/// The badges under an episode: AI audio always; the fixture label; private; downloaded; progress.
struct PodcastBadges: View {
    let episode: PodcastEpisode
    var kept = false
    var remainingMS: Int? = nil
    var finished = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badges }
            VStack(alignment: .leading, spacing: 4) { badges }
        }
        .accessibilityHidden(true)
    }
    @ViewBuilder private var badges: some View {
        PodcastBadge(title: "AI audio", systemImage: "waveform", tone: .accent)
        if episode.fixture { PodcastBadge(title: "Synthetic fixture", systemImage: "testtube.2", tone: .warning) }
        if episode.scope == .private { PodcastBadge(title: "Private · beta", systemImage: "lock.fill", tone: .neutral) }
        if kept { PodcastBadge(title: "Downloaded", systemImage: "arrow.down.circle.fill", tone: .neutral) }
        if finished { PodcastBadge(title: "Played", systemImage: "checkmark", tone: .neutral) }
        else if let remainingMS, remainingMS > 0 { PodcastBadge(title: "\(PodcastDuration.short(milliseconds: remainingMS)) left", systemImage: nil, tone: .neutral) }
    }
}

struct PodcastBadge: View {
    enum Tone { case accent, warning, neutral }
    let title: String
    let systemImage: String?
    let tone: Tone
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.weight(.semibold)) }
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
    }
    private var foreground: Color {
        switch tone { case .accent: .accentColor; case .warning: .orange; case .neutral: .secondary }
    }
    private var background: Color {
        switch tone {
        case .accent: Color.accentColor.opacity(0.12)
        case .warning: Color.orange.opacity(0.14)
        case .neutral: Color(uiColor: .tertiarySystemFill)
        }
    }
}

/// "Preparing audio…": a Play or Download fetching and verifying the whole file first, with Cancel.
struct PodcastTransferBanner: View {
    let center: PodcastCenter
    let transfer: PodcastCenter.Transfer
    var body: some View {
        StatusBanner(tone: .info, systemImage: "arrow.down.circle", message: transfer.keep
                     ? "Downloading “\(transfer.title)” · \(Int(transfer.fraction * 100))%"
                     : "Preparing audio · \(Int(transfer.fraction * 100))%",
                     messageID: "podcast.transfer") {
            Button("Cancel") { center.cancelTransfer() }.accessibilityIdentifier("podcast.transfer.cancel")
        }
        .accessibilityValue("\(Int(transfer.fraction * 100)) percent")
    }
}

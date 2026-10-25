import SwiftUI
import ScienceReaderCore

/// A Feed paper's details (owner, 2026-10-24: "if you click on the rest of the card, nothing happens. Instead I want the
/// screen to fill with a panel showing details of that paper that you can easily push down when done. Async, it could
/// start a search for related papers below"). Tall shows it as a large sheet swiped down when done (`FeedDetailSheet`);
/// Wide shows it in the Feed place's right slot (`FeedAbstractPane`). Its title, every author, when it appeared, its arXiv
/// number and popularity, its topics, why For you suggests it, Add (then Read) and View on arXiv, the whole abstract, and
/// related papers worked out on this device below (FeedRelated.swift). A related paper replaces the details, with Back.
struct FeedPaperDetails: View {
    @Bindable var model: ReaderModel
    let root: DiscoveryResult
    /// Above the title: the pane's room for the window's top row (the sheet has its own top row).
    var topInset: CGFloat = 0
    /// The sheet's top row: Back and ✕ there; nil in the pane (Back sits above the title).
    var close: (() -> Void)? = nil

    @State private var stack: [DiscoveryResult] = []
    @State private var related: [String: RelatedFeedOutcome] = [:]
    @State private var adding: Set<String> = []
    @State private var issue: String?
    @State private var allAuthors = false

    private var current: DiscoveryResult { stack.last ?? root }
    /// The paper Back returns to.
    private var backTitle: String? {
        if stack.count >= 2 { return stack[stack.count - 2].title }
        return stack.isEmpty ? nil : root.title
    }

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                SheetTopRow(back: stack.isEmpty ? nil : { back() }, close: close) {
                    // Where Back goes, so a pushed paper says it is one.
                    Text(backTitle ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            ScrollView {
                details(current)
                    .padding(.horizontal, close == nil ? 24 : DesignMetrics.margin + 4)
                    .padding(.top, topInset).padding(.bottom, 32)
                    .frame(maxWidth: DesignMetrics.column, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .id(current.sourceID)
        }
        .task(id: current.sourceID) {
            let paper = current
            guard related[paper.sourceID] == nil else { return }
            let outcome = await model.relatedPapers(for: paper)
            related[paper.sourceID] = outcome
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.detail")
    }

    private func back() {
        guard !stack.isEmpty else { return }
        stack.removeLast(); issue = nil; allAuthors = false
    }

    private func push(_ result: DiscoveryResult) {
        stack.append(result); issue = nil; allAuthors = false
    }

    @ViewBuilder private func details(_ result: DiscoveryResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if close == nil && !stack.isEmpty {
                // The pane: Back to the paper before, above the title.
                Button(action: back) {
                    Label("Back", systemImage: "chevron.backward").font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("feed.detail.back")
            }
            Text(result.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("feed.abstract.title")
            authors(result)
            // When it appeared, its arXiv number and popularity; then its topics and categories.
            Text(([FeedFormat.published(result), "arXiv \(result.sourceID)", FeedFormat.popularity(result)].compactMap { $0 })
                .joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityLabel(([FeedFormat.spokenPublished(result), "arXiv \(result.sourceID)",
                                      result.upvotes.map { _ in FeedFormat.spokenPopularity(result) }].compactMap { $0 }).joined(separator: ", "))
            if !topics(result).isEmpty { PaperTableChips(tags: topics(result)) }
            if let reason = result.reason {
                // The whole sentence ("Like “Muffin – A Shared Memory…”"), never shortened.
                Label { Text(reason.text).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: reason.kind == "trending" ? "arrow.up.right" : "sparkles").imageScale(.small)
                }
                .font(.footnote).foregroundStyle(Color.accentColor)
                .accessibilityLabel("Why: \(reason.text)")
                .accessibilityIdentifier("feed.detail.reason")
            }
            actions(result).padding(.top, 4)
            if let issue {
                StatusBanner(tone: .problem, systemImage: "exclamationmark.circle", message: issue)
            }
            Divider().padding(.vertical, 6)
            if let abstract = result.abstract {
                Text("Abstract").font(.headline).accessibilityAddTraits(.isHeader)
                Text(abstract).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("feed.abstract.text")
                if result.abstractTruncated, let url = URL(string: "https://arxiv.org/abs/\(result.sourceID)") {
                    Link("Read the full abstract on arXiv", destination: url).font(.footnote)
                }
            } else {
                Text("No abstract was published with this paper.").font(.subheadline).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 6)
            relatedSection(result)
        }
    }

    /// Every author: the first six, then "and N more", which shows the rest.
    @ViewBuilder private func authors(_ result: DiscoveryResult) -> some View {
        let names = result.authors
        let shown = 6
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text((allAuthors || names.count <= shown + 1 ? names : Array(names.prefix(shown))).joined(separator: ", "))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("feed.detail.authors")
                if names.count > shown + 1 && !allAuthors {
                    Button("and \(names.count - shown) more") { allAuthors = true }
                        .font(.subheadline).buttonStyle(.borderless)
                        .accessibilityLabel("Show \(names.count - shown) more authors")
                        .accessibilityIdentifier("feed.detail.moreAuthors")
                }
            }
        }
    }

    /// Its specific topics, then its arXiv categories' names not already among them.
    private func topics(_ result: DiscoveryResult) -> [String] {
        let topics = FeedFormat.topics(result, limit: 6)
        let categories = ArxivTopics.names(for: result.categories, limit: 3).filter { !topics.contains($0) }
        return topics + categories
    }

    /// The row's own actions (DiscoveryRow, FeedTable): Add to library, its progress while it is set up (a tap shows the
    /// Library), Read once it is here; View on arXiv.
    @ViewBuilder private func actions(_ result: DiscoveryResult) -> some View {
        let inLibrary = model.librarySourceIDs.contains(result.sourceID)
        let setup = model.discoverySetup(sourceID: result.sourceID)
        HStack(spacing: 12) {
            if adding.contains(result.id) || setup.busy {
                Button { model.showLibrary() } label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(setup.fraction.map { "\(ArxivHTMLReader.phase(for: $0)) \(Int(($0 * 100).rounded(.down)))%" } ?? "Adding…")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Shows the Library")
                .accessibilityIdentifier("feed.abstract.setup")
            } else if inLibrary {
                Button { read(result) } label: { Label("Read", systemImage: "book") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens the paper")
                    .accessibilityIdentifier("feed.abstract.read")
            } else {
                Button { add(result) } label: { Label("Add to library", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canBeginImport)
                    .accessibilityIdentifier("feed.abstract.add")
            }
            if let url = URL(string: "https://arxiv.org/abs/\(result.sourceID)") {
                Link(destination: url) { Label("View on arXiv", systemImage: "safari") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("feed.abstract.arxiv")
            }
        }
        .controlSize(.regular)
    }

    /// Read: the sheet goes and the paper opens (Wide: in this slot, still the Feed place).
    private func read(_ result: DiscoveryResult) {
        close?()
        model.openLibraryPaper(sourceID: result.sourceID)
    }

    private func add(_ result: DiscoveryResult) {
        adding.insert(result.id); issue = nil
        Task {
            do { try await model.addDiscovered(result) }
            catch ReaderModel.LibraryAddError.alreadyInLibrary { issue = "“\(result.title)” is already in your library." }
            catch { issue = "Couldn’t add “\(result.title)”. Try again." }
            adding.remove(result.id)
        }
    }

    // MARK: Related papers

    @ViewBuilder private func relatedSection(_ result: DiscoveryResult) -> some View {
        Text("Related papers").font(.headline).accessibilityAddTraits(.isHeader).accessibilityIdentifier("feed.related")
        if let outcome = related[result.sourceID] {
            if outcome.papers.isEmpty {
                Text("No related papers in this week’s feed").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("feed.related.none")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(outcome.papers) { paper in
                        relatedRow(paper)
                        if paper.id != outcome.papers.last?.id { Divider() }
                    }
                }
            }
        } else {
            // A quiet sign while this device works it out.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding related papers…").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("feed.related.loading")
        }
    }

    private func relatedRow(_ paper: RelatedFeedPaper) -> some View {
        let result = paper.result
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    // VoiceOver: the row's title opens it, as a tap anywhere on the row does.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows its details")
                    .accessibilityAction { push(result) }
                if let authors = LibraryFormat.shortAuthors(result.authors) {
                    Text(authors).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Label { Text(paper.reason.text).lineLimit(1) } icon: { Image(systemName: symbol(paper.reason)).imageScale(.small) }
                    .font(.footnote).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Why: \(paper.reason.text)")
            }
            Spacer(minLength: 4)
            DiscoveryAddControl(sourceID: result.sourceID, inLibrary: model.librarySourceIDs.contains(result.sourceID),
                                adding: adding.contains(result.id), enabled: model.canBeginImport,
                                setup: model.discoverySetup(sourceID: result.sourceID),
                                open: { read(result) }, showLibrary: { model.showLibrary() }) { add(result) }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { push(result) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.related.\(result.sourceID)")
    }

    private func symbol(_ reason: RelatedReason) -> String {
        switch reason {
        case .sameAuthor: "person.2"
        case .sharesTopic: "tag"
        case .close, .veryClose: "sparkles"
        }
    }
}

/// Tall: the details as a large sheet with a grabber, swiped down when done (VoiceOver: the escape gesture or ✕).
struct FeedDetailSheet: View {
    @Bindable var model: ReaderModel
    let root: DiscoveryResult
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        FeedPaperDetails(model: model, root: root, close: { dismiss() })
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .macSheetKeys()
    }
}

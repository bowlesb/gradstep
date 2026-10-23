import SwiftUI
import ScienceReaderCore

/// The Feed place's right slot in Wide (owner, 2026-10-23: "Feed also has a custom dual pane view: we present the abstract
/// to the right, and other details about the paper… when you inspect a given article, now the right space is used
/// specifically for the abstract and other details"). The article picked in the list: its title, authors, when it
/// appeared, its arXiv number, popularity and topics, why For you suggests it, and the whole abstract, with the row's own
/// actions — Add to library (then its progress, and Read once it is here) and View on arXiv. Picking a row never adds it;
/// only Add does. Read opens the paper in this slot, still the Feed place (WideSlots). With nothing picked, a quiet
/// placeholder. It has no row: the places menu floats over its top-right corner, above the details.
struct FeedAbstractPane: View {
    @Bindable var model: ReaderModel
    @State private var adding: Set<String> = []
    @State private var issue: String?

    var body: some View {
        Group {
            if let id = model.feedPickID, let result = model.feedResults.first(where: { $0.sourceID == id }) {
                details(result).id(result.sourceID)
            } else {
                ContentUnavailableView { Label("No article picked", image: GradstepSymbol.feed) }
                    description: { Text("Choose one in the list to see its abstract here.") }
                    .accessibilityIdentifier("feed.abstract.placeholder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(.container, edges: [.top, .bottom]))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.abstract")
    }

    private func details(_ result: DiscoveryResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(result.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("feed.abstract.title")
                if !result.authors.isEmpty {
                    Text(result.authors.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // When it appeared, its arXiv number and popularity; then its topics and categories.
                Text(([FeedFormat.published(result), "arXiv \(result.sourceID)", FeedFormat.popularity(result)].compactMap { $0 })
                    .joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityLabel(([FeedFormat.spokenPublished(result), "arXiv \(result.sourceID)",
                                          result.upvotes.map { _ in FeedFormat.spokenPopularity(result) }].compactMap { $0 }).joined(separator: ", "))
                if !topics(result).isEmpty { PaperTableChips(tags: topics(result)) }
                if let reason = result.reason { FeedReasonLine(reason: reason) }
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
            }
            .padding(.horizontal, 24)
            // Below the places menu's corner, as the paper's title sits below its floating controls.
            .padding(.top, WideMetrics.barHeight + 8).padding(.bottom, 32)
            .frame(maxWidth: DesignMetrics.column, alignment: .leading)
            .frame(maxWidth: .infinity)
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
                Button { model.openLibraryPaper(sourceID: result.sourceID) } label: { Label("Read", systemImage: "book") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens the paper here")
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

    private func add(_ result: DiscoveryResult) {
        adding.insert(result.id); issue = nil
        Task {
            do { try await model.addDiscovered(result) }
            catch ReaderModel.LibraryAddError.alreadyInLibrary { issue = "“\(result.title)” is already in your library." }
            catch { issue = "Couldn’t add “\(result.title)”. Try again." }
            adding.remove(result.id)
        }
    }
}

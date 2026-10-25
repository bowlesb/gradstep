import SwiftUI
import ScienceReaderCore

/// The Feed place's right slot in Wide (owner, 2026-10-23: "Feed also has a custom dual pane view: we present the abstract
/// to the right, and other details about the paper… when you inspect a given article, now the right space is used
/// specifically for the abstract and other details"). The article picked in the list shows the same details Tall shows in
/// its sheet (FeedPaperDetails, owner 2026-10-24): its title, authors, when it appeared, its arXiv number, popularity and
/// topics, why For you suggests it, Add (then Read) and View on arXiv, the whole abstract and related papers. Picking a
/// row never adds it; only Add does. Read opens the paper in this slot, still the Feed place (WideSlots). With nothing
/// picked, a quiet placeholder. It has no row: its details start level with the list's first row.
struct FeedAbstractPane: View {
    @Bindable var model: ReaderModel

    var body: some View {
        Group {
            if let id = model.feedPickID, let result = model.feedResults.first(where: { $0.sourceID == id }) {
                // A new pick starts afresh (its own related papers, no Back).
                FeedPaperDetails(model: model, root: result, topInset: WideMetrics.barHeight + 8).id(result.sourceID)
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
}

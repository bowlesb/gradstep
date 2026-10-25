import SwiftUI

// A stand-in for global search (docs/proposals/GLOBAL_SEARCH_AND_MORE.md B), built in parallel on its own branch. The
// navigation half (the bar's 🔍, Wide's 🔍, ⌘K, the Mac's toolbar field) needs only these two names; when the search
// branch merges, this file is deleted and its `GlobalSearchView(model:)` and `ReaderModel.openGlobalSearch(scopePaper:)`
// take over. Nothing here searches.

/// The Search place's content (every shape). The real view brings the keyboard up at once (JUDGMENT_LOG 16).
struct GlobalSearchView: View {
    @Bindable var model: ReaderModel
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Search", systemImage: "magnifyingglass")
            } description: {
                #if targetEnvironment(macCatalyst)
                // The Mac types in its toolbar's field (MacToolbarController); the results would show here.
                let query = MacCommandRequests.shared.globalSearchQuery
                Text(query.isEmpty ? "Search everything" : "“\(query)”")
                #else
                Text("Search everything")
                #endif
            }
            .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .tabBarSpace()
        }
        .accessibilityIdentifier("search.screen")
    }
}

extension ReaderModel {
    /// The Search place, scoped to a paper when one is given (B.5). Reading mode ends first (the paper alone has no places).
    func openGlobalSearch(scopePaper: Paper.ID? = nil) {
        exitReadingMode()
        tab = .search
    }
}

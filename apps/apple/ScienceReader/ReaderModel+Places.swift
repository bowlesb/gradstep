import Foundation
import ScienceReaderCore

// More and Search (owner, 2026-10-25; docs/proposals/GLOBAL_SEARCH_AND_MORE.md A; JUDGMENT_LOG 13–16): the compact bar is
// Library · Paper · Chat · More with 🔍 beside it. These only choose a place, as every existing route does: no route lands
// anywhere new, and the bar's selection is derived from `tab` (`ReaderTab.barSelection`).
extension ReaderModel {
    /// A row of the More list: Feed and Snippets become the place exactly as from the old bar (each keeps its state: the
    /// Feed's results and topic, the open collection), with More highlighted; Settings opens over the list as before and
    /// Done returns to it.
    func showMorePlace(_ place: ReaderTab) {
        switch place {
        case .settings: openSettings()
        case .feed, .notes: tab = place
        default: break
        }
    }

    /// The paper Search starts scoped to: the open paper when Paper is the place (B.5, "In this paper"), else none.
    var searchScopePaperID: UUID? {
        let reading = compactLayout ? tab == .paper : widePlace == .paper
        return reading ? selectedPaper?.id : nil
    }

    /// 🔍 (the bar's circle, Wide's beside the places button, ⌘K, the Mac's toolbar field and Edit › Search Everything):
    /// the Search place.
    func showSearchPlace() {
        openGlobalSearch(scopePaper: searchScopePaperID)
    }

    /// The window's bar changed (RootView): `nil` is Wide. The More list is a place only beside the compact bar; a window
    /// that grows to six places upright, or turns Wide (whose places menu has every place), leaves it for the Library,
    /// the app's first place. Feed and Snippets opened from More stay where they are (both bars and the menu have them).
    func tallBarChanged(to bar: TallBar?) {
        if tab == .more && bar != .compact { tab = .library }
    }
}

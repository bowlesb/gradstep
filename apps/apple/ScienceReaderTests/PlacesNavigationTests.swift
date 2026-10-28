import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// The bar with More and 🔍 (owner, 2026-10-25; docs/proposals/GLOBAL_SEARCH_AND_MORE.md A; JUDGMENT_LOG 13–16): which item
/// is highlighted is derived from the place; every existing route still lands on the place it did (A.5's call-site
/// table, one test per route group); each place keeps its state across bar switches.
@MainActor
final class PlacesNavigationTests: XCTestCase {
    private let compact = ReaderTab.bar(.compact)
    private let full = ReaderTab.bar(.full)

    func testTheBarsHoldTheirItems() {
        XCTAssertEqual(compact, [.library, .paper, .chat, .more], "Library · Paper · Chat · More, with 🔍 beside")
        XCTAssertEqual(full, [.feed, .library, .paper, .chat, .notes, .settings], "Every place on a full-width iPad upright")
        XCTAssertEqual(ReaderTab.morePlaces, [.feed, .notes, .settings], "More lists Feed, Snippets, Settings")
        XCTAssertEqual(ReaderTab.phoneTabs, [.feed, .library, .paper, .chat, .notes], "⌘1…⌘5 and the Mac keep their five")
        // Every place is reachable from either bar: its own item, or a row of More.
        for place in ReaderTab.phoneTabs + [.settings] {
            XCTAssertTrue(compact.contains(place) || ReaderTab.morePlaces.contains(place), "\(place) reachable on iPhone")
            XCTAssertTrue(full.contains(place), "\(place) in the full bar")
        }
    }

    /// Every place and every More-opened place, in both bars, with and without Settings over the screen.
    func testTheHighlightIsDerivedFromThePlace() {
        let expectedCompact: [ReaderTab: ReaderTab?] = [
            .library: .library, .paper: .paper, .chat: .chat,
            .feed: .more, .notes: .more, .more: .more, .settings: .more,
            .search: .search,
        ]
        let expectedFull: [ReaderTab: ReaderTab?] = [
            .feed: .feed, .library: .library, .paper: .paper, .chat: .chat, .notes: .notes, .settings: .settings,
            .search: .search, .more: nil,
        ]
        for tab in ReaderTab.allCases {
            XCTAssertEqual(ReaderTab.barSelection(tab: tab, settingsShown: false, bar: compact), expectedCompact[tab] ?? nil, "compact, \(tab)")
            XCTAssertEqual(ReaderTab.barSelection(tab: tab, settingsShown: false, bar: full), expectedFull[tab] ?? nil, "full, \(tab)")
            // Settings over any screen: More on iPhone (its third row), Settings in the full bar.
            XCTAssertEqual(ReaderTab.barSelection(tab: tab, settingsShown: true, bar: compact), .more, "compact, Settings over \(tab)")
            XCTAssertEqual(ReaderTab.barSelection(tab: tab, settingsShown: true, bar: full), .settings, "full, Settings over \(tab)")
        }
    }

    func testMoreRowsOpenTheirPlaceAndSettingsOverTheList() {
        let model = ReaderModel(configuration: nil)
        model.compactLayout = true
        model.tab = .more
        model.showMorePlace(.feed)
        XCTAssertEqual(model.tab, .feed)
        XCTAssertEqual(selection(model), .more, "Feed opened from More keeps More highlighted")
        model.tab = .more   // More again: its list
        model.showMorePlace(.notes)
        XCTAssertEqual(model.tab, .notes)
        XCTAssertEqual(selection(model), .more)
        model.tab = .more
        model.showMorePlace(.settings)
        XCTAssertTrue(model.settingsPresented, "Settings opens over the list")
        XCTAssertEqual(model.tab, .more, "The More list stays underneath")
        XCTAssertEqual(selection(model), .more)
        model.closeSettings()
        XCTAssertFalse(model.settingsPresented)
        XCTAssertEqual(model.tab, .more, "Done returns to the list")
    }

    /// More belongs to the compact bar: growing to six places upright, or turning Wide, leaves its list for the Library;
    /// a place opened from More stays.
    func testTheMoreListGivesWayWhereEveryPlaceShows() {
        let model = ReaderModel(configuration: nil)
        model.tab = .more
        model.tallBarChanged(to: .compact)
        XCTAssertEqual(model.tab, .more)
        model.tallBarChanged(to: .full)
        XCTAssertEqual(model.tab, .library)
        model.tab = .more
        model.tallBarChanged(to: nil)
        XCTAssertEqual(model.tab, .library, "Wide")
        model.tab = .feed
        model.tallBarChanged(to: .full)
        XCTAssertEqual(model.tab, .feed)
        model.tab = .search
        model.tallBarChanged(to: nil)
        XCTAssertEqual(model.tab, .search, "Search is a place in every shape")
    }

    #if targetEnvironment(simulator)
    // MARK: Routes (A.5): each lands where it did; only the highlight is new.

    func testPaperRoutesLandInPaper() async throws {
        let model = try await fixture()
        let paper = try XCTUnwrap(model.selectedPaper)
        model.tab = .library
        model.select(paper)
        XCTAssertEqual(model.tab, .paper, "select(paper)")
        XCTAssertEqual(selection(model), .paper)
        model.tab = .more
        model.openSample()
        XCTAssertEqual(model.tab, .paper, "openSample")
        model.tab = .notes
        model.showPaperPlace()
        XCTAssertEqual(model.tab, .paper, "showPaperPlace (passages, cited blocks, a snippet's source)")
        model.tab = .search
        model.openLibraryResult(paper)
        XCTAssertEqual(model.tab, .paper, "openLibraryResult")
        XCTAssertEqual(selection(model, .full), .paper)
    }

    func testChatRoutesLandInChat() async throws {
        let model = try await fixture()
        for (name, route) in [("askAboutSelectedPaper", { model.askAboutSelectedPaper() }),
                              ("returnToChat", { model.returnToChat() }),
                              ("continueInChat", { model.continueInChat() }),
                              ("discussReference", { model.discussReference("Vaswani et al. 2017") })] as [(String, () -> Void)] {
            model.tab = .more
            route()
            XCTAssertEqual(model.tab, .chat, name)
            XCTAssertEqual(selection(model), .chat, name)
        }
        if let conversation = model.activeConversation {
            model.tab = .feed
            model.openConversation(conversation)
            XCTAssertEqual(model.tab, .chat, "openConversation")
        }
    }

    func testLibraryRoutesLandInTheLibrary() async throws {
        let model = try await fixture()
        model.tab = .search
        model.showLibrary()
        XCTAssertEqual(model.tab, .library, "showLibrary")
        XCTAssertEqual(selection(model), .library)
        model.tab = .more
        model.showLibraryPapers(taggedWith: "preference learning")
        XCTAssertEqual(model.tab, .library, "showLibraryPapers(taggedWith:)")
        XCTAssertEqual(selection(model), .library)
    }

    func testSnippetAndFeedRoutesLandInTheirPlaceWithMoreHighlighted() async throws {
        let model = try await fixture()
        model.tab = .paper
        let collection = UUID()
        model.openNote(collection)
        XCTAssertEqual(model.tab, .notes, "openNote")
        XCTAssertEqual(model.notes.openNoteID, collection)
        XCTAssertEqual(selection(model), .more, "Snippets is under More on iPhone")
        XCTAssertEqual(selection(model, .full), .notes, "and its own item on a full-width iPad")
        // The Feed: Wide's Show feed beside the paper (the podcast's Browse episodes sets the same place).
        model.paperOrigin = .feed
        model.showListBesidePaper()
        XCTAssertEqual(model.tab, .feed, "showListBesidePaper from the Feed")
        XCTAssertEqual(selection(model), .more)
        XCTAssertEqual(selection(model, .full), .feed)
    }

    func testSettingsRoutesOpenOverTheScreen() async throws {
        let model = try await fixture()
        model.compactLayout = true
        model.tab = .paper
        model.openSettings()
        XCTAssertTrue(model.settingsPresented, "openSettings")
        XCTAssertEqual(model.tab, .paper, "The paper stays underneath")
        XCTAssertEqual(selection(model), .more, "More on iPhone")
        XCTAssertEqual(selection(model, .full), .settings, "Settings on a full-width iPad")
        model.closeSettings()
        XCTAssertEqual(selection(model), .paper)
    }

    func testSearchIsAPlaceScopedToTheOpenPaperFromPaper() async throws {
        let model = try await fixture()
        let paper = try XCTUnwrap(model.selectedPaper)
        model.compactLayout = true
        model.tab = .paper
        XCTAssertEqual(model.searchScopePaperID, paper.id, "🔍 from Paper scopes to it")
        model.showSearchPlace()
        XCTAssertEqual(model.tab, .search)
        XCTAssertEqual(selection(model), .search)
        XCTAssertEqual(selection(model, .full), .search)
        model.tab = .library
        XCTAssertNil(model.searchScopePaperID, "Elsewhere, no scope")
        // Wide: the paper beside its chat (Discuss) is the Paper place.
        model.compactLayout = false
        model.askAboutSelectedPaper()
        XCTAssertEqual(model.widePlace, .paper)
        XCTAssertEqual(model.searchScopePaperID, paper.id)
        model.compactLayout = true
    }

    // MARK: State per place

    /// Bar switches only change the place: the open paper and its reading position, the conversation, the Library's words,
    /// the open collection and the Feed's details all wait where they were.
    func testEachPlaceKeepsItsStateAcrossBarSwitches() async throws {
        let model = try await fixture()
        model.compactLayout = true
        let paper = try XCTUnwrap(model.selectedPaper)
        model.askAboutSelectedPaper()
        let conversation = model.activeConversation
        let location = PaperReadingLocation(blockIndex: 12, blockFraction: 0.4, blockHeight: 80, scrollY: 2400)
        model.paperLocations["fixture-key"] = location
        model.libraryQuery = "attention"
        let collection = UUID()
        model.openNote(collection)

        for tab in [ReaderTab.more, .library, .paper, .search, .chat, .more] { model.tab = tab }
        model.showMorePlace(.notes)
        XCTAssertEqual(model.notes.openNoteID, collection, "Snippets reopens on its collection from More")
        model.tab = .paper
        XCTAssertEqual(model.selectedPaper?.id, paper.id, "The open paper")
        XCTAssertEqual(model.paperLocations["fixture-key"], location, "Its reading position")
        model.tab = .chat
        XCTAssertEqual(model.activeConversation, conversation, "The conversation")
        XCTAssertFalse(model.generalChat, "Still the paper's chat")
        model.tab = .library
        XCTAssertEqual(model.libraryQuery, "attention", "The Library's words")
        model.libraryQuery = ""
    }

    private func fixture() async throws -> ReaderModel {
        let model = ReaderModel(configuration: nil)
        try await model.configureDurableDraftFixture(reset: true)
        XCTAssertNotNil(model.selectedPaper, "The fixture opens its sample paper")
        return model
    }
    #endif

    private func selection(_ model: ReaderModel, _ bar: TallBar = .compact) -> ReaderTab? {
        ReaderTab.barSelection(tab: model.tab, settingsShown: model.settingsPresented, bar: ReaderTab.bar(bar))
    }
}

import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// Global search in the app (docs/architecture/GLOBAL_SEARCH.md): the indexer follows writes, tombstones and unchanged
/// items; a search groups chats, Settings and the Feed, corrects a typo and falls back to some of the words; each result
/// opens where it lives; every Settings row it offers is a row in Settings.
@MainActor
final class GlobalSearchAppTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() { for folder in folders { try? FileManager.default.removeItem(at: folder) }; super.tearDown() }

    private func index() throws -> EverythingIndex {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("everything-app-\(UUID().wire)", isDirectory: true)
        folders.append(folder)
        return try EverythingIndex(directory: folder, accountID: UUID(), localKey: Data(repeating: 5, count: 32))
    }

    private struct Chat {
        var state = PrivateState()
        let device = UUID()
        mutating func add(_ payload: PrivateEvent, id: UUID = UUID()) throws -> UUID {
            try state.apply(AppliedEvent(id: id, deviceID: device, payload: payload)); return id
        }
    }

    /// Two chats (one deleted) and a diagram.
    private func chats() throws -> (Chat, conversation: UUID, question: UUID, answer: UUID, deleted: UUID) {
        var chat = Chat()
        let conversation = UUID(), deleted = UUID()
        let root = try chat.add(PrivateEvent(kind: .conversation, entityID: conversation, text: "Seabirds and their flight", createdAt: 1_790_000_000_000))
        let question = try chat.add(PrivateEvent(kind: .message, parents: [root], conversationID: conversation, text: "How does the albatross glide?",
                                                 role: .user, status: .complete, createdAt: 1_790_000_000_000))
        let answer = try chat.add(PrivateEvent(kind: .message, parents: [question], conversationID: conversation,
                                               text: "**Dynamic soaring**: the albatross gains energy from the wind gradient [¶4].",
                                               role: .assistant, status: .complete, createdAt: 1_790_000_001_000))
        let diagram = ChatDiagram(title: "Soaring cycle", source: "flowchart LR\n A[windward climb] --> B(leeward dive)", messageID: nil)!
        _ = try chat.add(PrivateEvent(kind: .diagram, conversationID: conversation, text: diagram.encodedText()))
        let otherRoot = try chat.add(PrivateEvent(kind: .conversation, entityID: deleted, text: "Penguins"))
        _ = try chat.add(PrivateEvent(kind: .message, parents: [otherRoot], conversationID: deleted, text: "albatross versus penguin", role: .user, status: .complete))
        _ = try chat.add(PrivateEvent(kind: .tombstone, entityID: deleted))
        return (chat, conversation, question, answer, deleted)
    }

    private func sources(_ state: PrivateState) -> EverythingIndexer.Sources {
        var sources = EverythingIndexer.Sources()
        sources.state = state; sources.summaries = state.conversationSummaries(); sources.notes = NotesState(state)
        return sources
    }

    private func reconcile(_ index: EverythingIndex, _ sources: EverythingIndexer.Sources) async -> Int {
        let commits = Counter()
        await EverythingIndexer.reconcile(index: index, sources: sources, changed: { commits.value += 1 }, progress: { _ in })
        return commits.value
    }

    func testTheIndexerFollowsWritesTombstonesAndSkipsWhatIsUnchanged() async throws {
        let made = try chats()
        var chat = made.0
        let (conversation, question, answer) = (made.conversation, made.question, made.answer)
        let index = try index()
        let first = await reconcile(index, sources(chat.state))
        XCTAssertEqual(first, 1)
        let groups = Set(await index.fingerprints().keys)
        XCTAssertTrue(groups.contains("message:\(question.wire)") && groups.contains("message:\(answer.wire)"))
        XCTAssertTrue(groups.contains("conversation:\(conversation.wire)"))
        XCTAssertEqual(groups.filter { $0.hasPrefix("diagram:") }.count, 1)
        XCTAssertEqual(groups.count, 4, "the deleted conversation and its message are not indexed")
        // Nothing changed: no commit.
        let unchanged = await reconcile(index, sources(chat.state))
        XCTAssertEqual(unchanged, 0)
        // A tombstone (here, or merged from another device) removes the message.
        _ = try chat.add(PrivateEvent(kind: .tombstone, entityID: chat.state.events[answer]!.payload.entityID))
        let removed = await reconcile(index, sources(chat.state))
        XCTAssertEqual(removed, 1)
        let remaining = await index.fingerprints()
        XCTAssertFalse(remaining.keys.contains("message:\(answer.wire)"))
    }

    func testASearchGroupsChatsSettingsAndTheFeedCorrectsTyposAndFallsBack() async throws {
        let (chat, conversation, question, _, _) = try chats()
        let index = try index()
        _ = await reconcile(index, sources(chat.state))
        func run(_ query: String, chip: GlobalSearchChip = .all) async -> GlobalSearchResults {
            var input = GlobalSearchInput(query: query, chip: chip, limit: 50)
            input.everything = index; input.sources = sources(chat.state)
            input.settings = GlobalSearchSettings.rows
            input.tags = [("Seabirds", 3)]
            return await GlobalSearchEngine.run(input)
        }
        // The reader's question ranks above the answer; the All view shows the chat once with "+1 more".
        let found = await run("albatross ")
        let chats = try XCTUnwrap(found.groups.first { $0.group == .chats })
        XCTAssertEqual(chats.rows.count, 1)
        XCTAssertEqual(chats.rows[0].target, .message(conversation: conversation, event: question))
        XCTAssertEqual(chats.rows[0].more, 1)
        XCTAssertEqual(chats.rows[0].title, "Seabirds and their flight")
        XCTAssertEqual(chats.total, 2)
        let excerpt = try XCTUnwrap(chats.rows[0].match?.excerpt)
        XCTAssertEqual(excerpt.highlights.map { String(decoding: Array(excerpt.text.utf16)[$0], as: UTF16.self) }, ["albatross"])
        // The Chats chip: both messages, uncollapsed.
        let chip = await run("albatross ", chip: .chats)
        XCTAssertEqual(chip.groups.first?.rows.count, 2)
        // Diagrams, tags and Settings (by title or another word for it, never the explanation).
        let leeward = await run("leeward"), seab = await run("seab"), dark = await run("dark mo"), underlined = await run("underlined")
        XCTAssertEqual(leeward.groups.map(\.group), [.diagrams])
        XCTAssertEqual(seab.groups.map(\.group), [.chats, .tags])
        XCTAssertEqual(dark.groups.first?.rows.first?.target, .setting("settings.theme"))
        XCTAssertTrue(underlined.groups.isEmpty)
        // A typo: the closest word that is indexed.
        let corrected = await run("albatros ")
        XCTAssertEqual(corrected.correction, "albatross")
        XCTAssertEqual(corrected.groups.first?.group, .chats)
        // Some words but not all: what has some of them.
        let partial = await run("albatross zebrafish ")
        XCTAssertTrue(partial.partial)
        XCTAssertEqual(partial.groups.first?.rows.first?.showsStrength, true)
    }

    func testEachResultOpensWhereItLives() throws {
        let (chat, conversation, _, answer, _) = try chats()
        let model = ReaderModel(configuration: nil)
        model.publish(LocalStoreSnapshot(state: chat.state, generation: 1, pendingCount: 0))
        model.openGlobalSearch()
        XCTAssertTrue(model.globalSearch.shown)
        model.openSearchResult(GlobalSearchRow(id: "c", group: .chats, symbol: "", title: "", target: .conversation(conversation)))
        XCTAssertEqual(model.tab, .chat); XCTAssertEqual(model.activeConversation, conversation)
        XCTAssertFalse(model.globalSearch.shown, "opening a result leaves search (iPhone)")
        model.tab = .library
        model.openSearchResult(GlobalSearchRow(id: "m", group: .chats, symbol: "", title: "", target: .message(conversation: conversation, event: answer)))
        XCTAssertEqual(model.tab, .chat); XCTAssertEqual(model.chatLanding?.eventID, answer)
        XCTAssertTrue(model.chatMessages.contains { $0.id == answer })
        let note = UUID()
        model.openSearchResult(GlobalSearchRow(id: "n", group: .snippets, symbol: "", title: "", target: .snippet(collection: note, entry: answer)))
        XCTAssertEqual(model.tab, .notes); XCTAssertEqual(model.notes.openNoteID, note); XCTAssertEqual(model.notes.focusEntryID, answer)
        model.openSearchResult(GlobalSearchRow(id: "s", group: .settings, symbol: "", title: "", target: .setting("settings.passageMarks")))
        XCTAssertTrue(model.settingsPresented || model.tab == .settings)
        XCTAssertEqual(model.settingsFocus?.row, "settings.passageMarks")
        model.openSearchResult(GlobalSearchRow(id: "t", group: .tags, symbol: "", title: "", target: .tag("Seabirds")))
        XCTAssertEqual(model.tab, .library)
        // Wide: a chat shows beside the results, which stay.
        model.openGlobalSearch()
        let row = GlobalSearchRow(id: "w", group: .chats, symbol: "", title: "", target: .conversation(conversation))
        model.openSearchResult(row, wide: true)
        XCTAssertTrue(model.globalSearch.shown); XCTAssertEqual(model.globalSearch.picked?.id, "w")
        // Sign-out's reset leaves nothing of the account on screen.
        model.globalSearch.query = "albatross"
        model.globalSearch.reset()
        XCTAssertEqual(model.globalSearch.query, ""); XCTAssertFalse(model.globalSearch.shown); XCTAssertNil(model.globalSearch.picked)
    }

    /// Every row global search offers is a row of Settings with that identifier as its scroll target.
    func testEverySettingsRowItOffersIsInSettings() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ScienceReader/Views")
        let source = try String(contentsOf: views.appendingPathComponent("RootView.swift"), encoding: .utf8)
        for row in GlobalSearchSettings.rows {
            if row.id.hasPrefix("settings.aiScenario.") {
                XCTAssertTrue(source.contains(#".settingsRow("settings.aiScenario.\(scenario.rawValue)""#))
                XCTAssertNotNil(AIUseCase(rawValue: String(row.id.dropFirst("settings.aiScenario.".count))), row.id)
            } else {
                XCTAssertTrue(source.contains(".settingsRow(\"\(row.id)\""), "\(row.id) is not a Settings row")
            }
        }
        XCTAssertEqual(Set(GlobalSearchSettings.rows.map(\.id)).count, GlobalSearchSettings.rows.count)
    }
}

@MainActor private final class Counter { var value = 0 }

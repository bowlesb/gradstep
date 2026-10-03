import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

@MainActor
final class WorkflowSafetyTests: XCTestCase {
    func testChangingArtifactClearsOldReaderActionsWithoutLosingItsLocation() throws {
        let model = ReaderModel(configuration: nil)
        model.openSample()
        let original = try XCTUnwrap(model.selectedPaper), originalScope = model.readerDocumentScope
        let key = "\(original.id.uuidString)/\(try XCTUnwrap(original.artifactID).uuidString)"
        model.headings = [PaperHeading(id: "original-section", title: "Original section")]
        model.paperJump = PaperJumpRequest(locationKey: key, headingID: "original-section")
        model.selectedQuote = "A passage from the original artifact"
        let position = PaperReadingLocation(blockIndex: 3, blockFraction: 0.4, blockHeight: 100, scrollY: 140)
        model.paperLocations[key] = position

        model.select(original)
        XCTAssertEqual(model.readerDocumentScope, originalScope)
        XCTAssertEqual(model.headings, [PaperHeading(id: "original-section", title: "Original section")])
        XCTAssertNotNil(model.paperJump)

        let replacement = Paper(id: original.id, title: original.title, authors: original.authors,
            year: original.year, abstract: original.abstract, keywords: original.keywords,
            fileURL: original.fileURL, artifactID: UUID())
        model.select(replacement)
        XCTAssertNotEqual(model.readerDocumentScope, originalScope, "Late callbacks belong to the old immutable artifact")
        XCTAssertTrue(model.headings.isEmpty)
        XCTAssertNil(model.paperJump)
        XCTAssertTrue(model.selectedQuote.isEmpty)
        XCTAssertEqual(model.paperLocations[key], position, "Returning to the original artifact retains its own position")
    }

    func testNewChatWithIdenticalDraftSurvivesPreviousSaveCompletion() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Explain attention", in: "general")
        let saving = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        XCTAssertNil(workspace.beginSubmission(in: "general"))
        workspace.select(nil, in: "general")
        workspace.setDraft("Explain attention", in: "general")
        let newComposer = workspace.composerID(in: "general")

        workspace.complete(saving)

        XCTAssertEqual(workspace.composerID(in: "general"), newComposer)
        XCTAssertNil(workspace.conversation(in: "general"))
        XCTAssertEqual(workspace.draft(in: "general"), "Explain attention")
        XCTAssertFalse(workspace.isSaving(in: "general"))
        XCTAssertFalse(workspace.hasSaved(in: "general"))
        workspace.select(saving.conversationID, in: "general")
        XCTAssertEqual(workspace.composerID(in: "general"), saving.composerID)
        XCTAssertEqual(workspace.draft(in: "general"), "")
        XCTAssertTrue(workspace.hasSaved(in: "general"))
    }

    func testHistorySelectionAndItsDraftSurviveAnotherSaveInTheSameContext() throws {
        var workspace = ChatWorkspace()
        let history = UUID(), context = "paper/fixture-a"
        workspace.select(history, in: context)
        workspace.setDraft("A follow-up for history", in: context)
        let historyComposer = workspace.composerID(in: context)
        workspace.select(nil, in: context)
        workspace.setDraft("A different new question", in: context)
        let saving = try XCTUnwrap(workspace.beginSubmission(in: context))
        workspace.select(history, in: context)

        workspace.complete(saving)

        XCTAssertEqual(workspace.composerID(in: context), historyComposer)
        XCTAssertEqual(workspace.conversation(in: context), history)
        XCTAssertEqual(workspace.draft(in: context), "A follow-up for history")
        XCTAssertFalse(workspace.isSaving(in: context))
    }

    func testOpeningTheCommittingConversationDoesNotOrphanItsNewDraft() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("First question", in: "general")
        let saving = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        // The durable conversation can appear through a concurrent sync before
        // the original save continuation updates this workspace.
        workspace.select(saving.conversationID, in: "general")
        workspace.setDraft("Follow-up typed from history", in: "general")
        workspace.complete(saving)
        XCTAssertEqual(workspace.draft(in: "general"), "Follow-up typed from history")

        workspace.select(UUID(), in: "general")
        workspace.select(saving.conversationID, in: "general")

        XCTAssertEqual(workspace.draft(in: "general"), "Follow-up typed from history")
        XCTAssertFalse(workspace.isSaving(in: "general"))
    }

    func testHistoryDraftsBelongToTheirConversation() {
        var workspace = ChatWorkspace()
        let first = UUID(), second = UUID()
        workspace.select(first, in: "general")
        workspace.setDraft("First conversation draft", in: "general")
        workspace.select(second, in: "general")
        XCTAssertEqual(workspace.draft(in: "general"), "")
        workspace.setDraft("Second conversation draft", in: "general")
        workspace.select(first, in: "general")
        XCTAssertEqual(workspace.draft(in: "general"), "First conversation draft")
        workspace.select(second, in: "general")
        XCTAssertEqual(workspace.draft(in: "general"), "Second conversation draft")
    }

    func testEditingBackToTheSameTextIsNotClearedByTheOlderSave() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Repeated question", in: "general")
        let saving = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        workspace.setDraft("A changed question", in: "general")
        workspace.setDraft("Repeated question", in: "general")
        workspace.complete(saving)

        XCTAssertEqual(workspace.draft(in: "general"), "Repeated question")
        XCTAssertEqual(workspace.conversation(in: "general"), saving.conversationID)
        XCTAssertFalse(workspace.isSaving(in: "general"))
        let next = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        XCTAssertEqual(next.conversationID, saving.conversationID)
        XCTAssertNil(next.rootID)
        XCTAssertNotEqual(next.id, saving.id)
    }

    func testFailedSavePreservesDraftAndLateCallbackCannotFinishItsRetry() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("  Preserve this question  ", in: "general")
        let failed = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        XCTAssertEqual(failed.text, "Preserve this question")
        workspace.fail(failed)
        XCTAssertEqual(workspace.draft(in: "general"), "  Preserve this question  ")
        XCTAssertFalse(workspace.isSaving(in: "general"))
        XCTAssertFalse(workspace.hasSaved(in: "general"))
        XCTAssertNil(workspace.conversation(in: "general"))
        let retry = try XCTUnwrap(workspace.beginSubmission(in: "general"))

        workspace.complete(failed)
        workspace.fail(failed)

        XCTAssertTrue(workspace.isSaving(in: "general"))
        XCTAssertEqual(workspace.draft(in: "general"), "  Preserve this question  ")
        workspace.complete(retry)
        XCTAssertFalse(workspace.isSaving(in: "general"))
        XCTAssertEqual(workspace.conversation(in: "general"), retry.conversationID)
        XCTAssertEqual(workspace.draft(in: "general"), "")
    }

    func testPaperAndGeneralComposersRemainIndependentDuringConcurrentSaves() throws {
        var workspace = ChatWorkspace()
        let contexts = ["paper/a", "general", "paper/b"]
        for context in contexts { workspace.setDraft("Question for \(context)", in: context) }
        let paperSave = try XCTUnwrap(workspace.beginSubmission(in: "paper/a"))
        XCTAssertFalse(workspace.isSaving(in: "general"))
        let generalSave = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        workspace.complete(paperSave)

        XCTAssertFalse(workspace.isSaving(in: "paper/a"))
        XCTAssertTrue(workspace.isSaving(in: "general"))
        XCTAssertEqual(workspace.draft(in: "general"), "Question for general")
        XCTAssertEqual(workspace.draft(in: "paper/b"), "Question for paper/b")
        workspace.fail(generalSave)
        XCTAssertEqual(workspace.draft(in: "general"), "Question for general")
        XCTAssertEqual(workspace.conversation(in: "paper/a"), paperSave.conversationID)
        XCTAssertNil(workspace.conversation(in: "paper/b"))
    }

    func testClearedWorkspaceIgnoresOldAccountCompletionAndFailure() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Previous account", in: "general")
        let previous = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        workspace = ChatWorkspace()
        workspace.setDraft("Current account", in: "general")
        let current = try XCTUnwrap(workspace.beginSubmission(in: "general"))

        workspace.complete(previous)
        workspace.fail(previous)

        XCTAssertEqual(workspace.composerID(in: "general"), current.composerID)
        XCTAssertEqual(workspace.conversation(in: "general"), current.conversationID)
        XCTAssertEqual(workspace.draft(in: "general"), "Current account")
        XCTAssertTrue(workspace.isSaving(in: "general"))
        workspace.complete(current)
        XCTAssertEqual(workspace.conversation(in: "general"), current.conversationID)
    }

    func testSearchTrimsWhitespaceAndMatchesWordsAcrossOptionalFields() {
        let model = ReaderModel(configuration: nil)
        let abstracts = model.showAbstracts, topics = model.showTopics
        defer { model.showAbstracts = abstracts; model.showTopics = topics }
        let attention = paper(title: "Efficient Attention", authors: "Ada Lovelace", abstract: "Training with less memory", keywords: ["optimization"])
        let sparse = paper(title: "Sparse Models")
        model.papers = [sparse, attention]
        model.libraryQuery = " \n ATTENTION\t lovelace  optimization "
        XCTAssertEqual(model.filteredPapers.map(\.id), [attention.id])
        model.showAbstracts = false; model.showTopics = false
        model.libraryQuery = "memory optimization"
        XCTAssertEqual(model.filteredPapers.map(\.id), [attention.id], "Hidden optional fields remain searchable")
        model.libraryQuery = "sparse"
        XCTAssertEqual(model.filteredPapers.map(\.id), [sparse.id])
        model.libraryQuery = " \n\t "
        XCTAssertEqual(model.filteredPapers.map(\.id), [sparse.id, attention.id])
        model.librarySort = "Title"
        XCTAssertEqual(model.filteredPapers.map(\.id), [attention.id, sparse.id])
        model.libraryQuery = "attention unknown"
        XCTAssertTrue(model.filteredPapers.isEmpty)
    }

    func testLibraryAndDiscoveryQueriesSurviveScopeSwitchesIndependently() {
        let model = ReaderModel(configuration: nil)
        model.searchQuery = "saved transformers"
        model.searchExternal = true
        XCTAssertEqual(model.searchQuery, "")
        model.searchQuery = "new diffusion papers"
        model.searchExternal = false
        XCTAssertEqual(model.searchQuery, "saved transformers")
        model.searchQuery = "saved attention"
        model.searchExternal = true
        XCTAssertEqual(model.searchQuery, "new diffusion papers")
        XCTAssertEqual(model.libraryQuery, "saved attention")
    }

    func testAskFromBrowseEntersReaderAndKeepsThePaperConversationDraft() {
        let model = ReaderModel(configuration: nil), selected = paper(title: "Selected paper")
        model.papers = [selected]; model.wideMode = .browse; model.select(selected)
        let conversation = UUID()
        model.activeConversation = conversation; model.chatInput = "Follow-up for this paper"
        XCTAssertEqual(model.wideMode, .browse)

        model.askAboutSelectedPaper()

        XCTAssertEqual(model.wideMode, .reader)
        XCTAssertEqual(model.tab, .chat)
        XCTAssertFalse(model.generalChat)
        XCTAssertEqual(model.chatPaper?.id, selected.id)
        XCTAssertEqual(model.activeConversation, conversation)
        XCTAssertEqual(model.chatInput, "Follow-up for this paper")
    }

    func testPaperlessNewChatAndSendDoNotDisplaceTheGeneralDraft() async {
        let model = ReaderModel(configuration: nil)
        model.chatInput = "A general question"
        let generalComposer = model.chatComposerID
        model.newChat(general: false)
        XCTAssertTrue(model.generalChat)
        XCTAssertEqual(model.chatComposerID, generalComposer)
        XCTAssertEqual(model.chatInput, "A general question")
        XCTAssertFalse(model.canUsePaperChat)
        model.generalChat = false
        model.chatInput = "No paper is selected"

        await model.sendMessage()

        XCTAssertFalse(model.showSignIn)
        XCTAssertFalse(model.isGenerating)
        XCTAssertTrue(model.privateState.events.isEmpty)
        model.generalChat = true
        XCTAssertEqual(model.chatInput, "A general question")
    }

    func testDeletedConversationCannotContinueOrRouteToAuthentication() async throws {
        let model = ReaderModel(configuration: nil)
        let conversation = UUID(), root = UUID(), message = UUID(), device = UUID()
        try model.privateState.apply(AppliedEvent(id: root, deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: conversation, text: "Old conversation")))
        try model.privateState.apply(AppliedEvent(id: message, deviceID: device, payload: PrivateEvent(kind: .message, parents: [root], conversationID: conversation,
                                                                                                  text: "An old question", role: .user, status: .complete)))
        model.openConversation(conversation); model.chatInput = "Do not append to a deleted chat"
        XCTAssertTrue(model.chatContextComplete)
        try model.privateState.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: conversation)))

        await model.sendMessage()

        XCTAssertTrue(model.chatWasDeleted)
        XCTAssertFalse(model.chatContextComplete)
        XCTAssertTrue(model.chatMessages.isEmpty)
        XCTAssertFalse(model.isGenerating)
        XCTAssertFalse(model.showSignIn)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.privateState.events.count, 3)
        XCTAssertEqual(model.chatInput, "Do not append to a deleted chat")
    }

    func testHistoryRestoresItsOwnPaperOrExplicitMissingPaperContext() throws {
        let model = ReaderModel(configuration: nil), first = paper(title: "First paper"), second = paper(title: "Second paper")
        model.papers = [first, second]; model.select(second)
        let conversation = UUID(), missingConversation = UUID(), missingPaper = UUID(), device = UUID()
        try model.privateState.apply(AppliedEvent(id: UUID(), deviceID: device,
                                                 payload: PrivateEvent(kind: .conversation, entityID: conversation, documentID: first.id, text: "First paper chat")))
        try model.privateState.apply(AppliedEvent(id: UUID(), deviceID: device,
                                                 payload: PrivateEvent(kind: .conversation, entityID: missingConversation, documentID: missingPaper, text: "Unavailable paper chat")))
        model.openConversation(conversation)
        XCTAssertEqual(model.chatPaper?.id, first.id)
        XCTAssertEqual(model.chatTitle, "First paper chat")
        model.chatInput = "A draft for the first paper"
        model.openConversation(missingConversation)
        XCTAssertFalse(model.generalChat)
        XCTAssertEqual(model.chatPaperID, missingPaper)
        XCTAssertNil(model.chatPaper)
        XCTAssertNil(model.selectedPaper)
        XCTAssertEqual(model.chatTitle, "Unavailable paper chat")
        model.openConversation(conversation)
        XCTAssertEqual(model.chatInput, "A draft for the first paper")
    }

    func testInitialAuthenticationFailureKeepsGuestSampleAndQuestion() async throws {
        let environment = "workflow-\(UUID().wire)", host = environment + ".invalid"
        StubProtocol.install(host: host) { request in request.respond(Data("{}".utf8), status: 401) }
        defer { StubProtocol.remove(host: host); try? KeychainVault.delete(environment + ".auth-session") }
        let networkConfiguration = URLSessionConfiguration.ephemeral
        networkConfiguration.protocolClasses = [StubProtocol.self]
        let configuration = BackendConfiguration(url: URL(string: "https://\(host)")!, anonKey: "fixture", environment: environment)
        let client = try BackendClient(configuration: configuration, network: URLSession(configuration: networkConfiguration))
        let model = ReaderModel(configuration: configuration, client: client)
        model.openSample()
        let sampleID = model.selectedPaper?.id
        model.selectionAction(.define, quote: "attention")
        let draft = model.chatInput

        await model.authenticate(email: "fixture@example.invalid", password: "fixture", create: false)

        XCTAssertNotNil(model.error)
        XCTAssertNil(model.email)
        XCTAssertEqual(model.selectedPaper?.id, sampleID)
        XCTAssertEqual(model.chatPaperID, sampleID)
        XCTAssertFalse(model.generalChat)
        XCTAssertEqual(model.chatInput, draft)
        XCTAssertEqual(model.tab, .chat)
    }

    func testLateSyncSnapshotCannotReplaceNewerSavedHistory() async throws {
        let account = UUID(), device = UUID(), key = ReaderCrypto.randomKey(), bundle = KeyBundle.generate(accountID: account)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-snapshot-\(UUID().wire)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try EncryptedStore(url: folder.appendingPathComponent("state.sqlite"), accountID: account, localKey: key, keys: bundle)
        _ = try await store.append(PrivateEvent(kind: .note, text: "Earlier state"), deviceID: device)
        let delayed = await store.snapshot()
        _ = try await store.append(PrivateEvent(kind: .note, text: "Newer saved state"), deviceID: device)
        let newest = await store.snapshot()
        let model = ReaderModel(configuration: nil)
        XCTAssertTrue(model.publish(newest))
        XCTAssertFalse(model.publish(delayed))
        XCTAssertEqual(model.privateState, newest.state)
        XCTAssertEqual(model.privateState.events.count, 2)
    }

    func testNewerSyncAttemptOwnsStatusEvenWithoutAStoreGenerationChange() throws {
        var ownership = ReaderWorkOwnership()
        let store = ownership.storeScope
        let failing = try XCTUnwrap(ownership.beginSync())
        let succeeding = try XCTUnwrap(ownership.beginSync())
        XCTAssertTrue(ownership.owns(store), "Either callback may still deliver a generation-checked snapshot")
        XCTAssertFalse(ownership.owns(failing), "The older failure must not replace status, alerts, or Recovery")
        XCTAssertTrue(ownership.owns(succeeding))
        XCTAssertEqual(failing.store, succeeding.store)
    }

    func testSameAccountActivationFencesOldDeviceCallbacksAndSyncAttempts() throws {
        var ownership = ReaderWorkOwnership()
        let oldStore = ownership.storeScope, accountSession = ownership.accountSessionID
        let oldAttempt = try XCTUnwrap(ownership.beginSync())
        let activation = ownership.beginActivation()
        XCTAssertEqual(ownership.accountSessionID, accountSession)
        XCTAssertFalse(ownership.owns(oldStore))
        XCTAssertFalse(ownership.owns(oldAttempt))
        XCTAssertNil(ownership.beginSync())
        ownership.finishActivation(oldStore)
        XCTAssertTrue(ownership.isActivating, "An old callback cannot release a newer activation's pause")
        ownership.finishActivation(activation)
        let current = try XCTUnwrap(ownership.beginSync())
        XCTAssertTrue(ownership.owns(current))
        XCTAssertFalse(ownership.owns(oldAttempt))
    }

    func testSignOutPreventsOldActivationFromUnpausingTheNextAccount() {
        var ownership = ReaderWorkOwnership()
        let previous = ownership.beginActivation(), previousAccount = ownership.accountSessionID
        ownership = ReaderWorkOwnership()
        let current = ownership.beginActivation()
        ownership.finishActivation(previous)
        XCTAssertNotEqual(ownership.accountSessionID, previousAccount)
        XCTAssertFalse(ownership.owns(previous))
        XCTAssertTrue(ownership.owns(current))
        XCTAssertTrue(ownership.isActivating)
        ownership.finishActivation(current)
        XCTAssertFalse(ownership.isActivating)
    }

    func testRemoteUserContinuationDoesNotRequestLocalScrolling() throws {
        let model = ReaderModel(configuration: nil)
        let conversation = UUID(), root = UUID(), first = UUID(), remote = UUID(), device = UUID()
        try model.privateState.apply(AppliedEvent(id: root, deviceID: device,
            payload: PrivateEvent(kind: .conversation, entityID: conversation, text: "Shared across devices")))
        try model.privateState.apply(AppliedEvent(id: first, deviceID: device,
            payload: PrivateEvent(kind: .message, parents: [root], conversationID: conversation,
                                  text: "An earlier answer", role: .assistant, status: .complete)))
        model.openConversation(conversation)
        XCTAssertNil(model.chatFollowRequest)

        try model.privateState.apply(AppliedEvent(id: remote, deviceID: UUID(),
            payload: PrivateEvent(kind: .message, parents: [first], conversationID: conversation,
                                  text: "A question from another device", role: .user, status: .complete)))
        XCTAssertEqual(model.activeBranchID, remote)
        XCTAssertNil(model.chatFollowRequest, "Incoming user content must preserve deliberate scrollback")

        model.activeBranchID = remote
        let choice = try XCTUnwrap(model.chatFollowRequest)
        XCTAssertEqual(choice.composerID, model.chatComposerID)
        model.activeBranchID = remote
        XCTAssertNotEqual(model.chatFollowRequest?.id, choice.id, "An explicit choice is its own scrolling intent")
        model.newChat(general: true)
        XCTAssertNotEqual(model.chatComposerID, choice.composerID, "The previous request cannot own a new composer")
    }

    func testExplicitBranchChoiceDuringSaveSurvivesItsLateCompletion() {
        var choices = ConversationBranchSelections()
        let conversation = UUID(), first = UUID(), second = UUID(), saved = UUID()
        choices.select(first, in: conversation)
        let saving = choices.capture(in: conversation)
        choices.select(second, in: conversation)
        XCTAssertFalse(choices.complete(saving, head: saved))
        XCTAssertEqual(choices.selected(in: conversation), second)
        choices.select(first, in: conversation)
        XCTAssertFalse(choices.complete(saving, head: saved), "Returning to the same branch is still a newer explicit choice")
        XCTAssertEqual(choices.selected(in: conversation), first)

        let nextSave = choices.capture(in: conversation)
        choices.select(UUID(), in: UUID())
        XCTAssertTrue(choices.complete(nextSave, head: saved), "A choice in another conversation does not block this save")
        XCTAssertEqual(choices.selected(in: conversation), saved)
    }

    func testReactivationWaitsForAcceptedWriteAndReusesTheOnlyStoreActor() async throws {
        let fixture = LocalPersistenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let persistence = ReaderLocalPersistence()
        let original = try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        let gate = WorkflowWriteGate()
        let write = Task {
            try await persistence.performWrite { store in
                await gate.hold()
                return [try await store.append(PrivateEvent(kind: .note, text: "Accepted before recovery"), deviceID: fixture.device)]
            }
        }
        await gate.waitUntilHeld()
        var rotated = fixture.keys; try rotated.rotate()
        let activationStarted = expectation(description: "Activation reached the pending writer")
        let activation = Task {
            activationStarted.fulfill()
            return try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: rotated)
        }
        await fulfillment(of: [activationStarted], timeout: 3)
        XCTAssertTrue(persistence.isActivating)
        do {
            _ = try await persistence.performWrite { _ in XCTFail("A new write cannot start during activation"); return [] }
            XCTFail("Expected a temporary write pause")
        } catch { XCTAssertEqual(error as? ReaderError, .storageUnavailable) }
        await gate.release()
        let saved = try await write.value
        let reactivated = try await activation.value
        XCTAssertTrue(reactivated === original)
        XCTAssertFalse(persistence.isActivating)
        XCTAssertEqual(saved.first?.epoch, fixture.keys.epoch, "The accepted write precedes the key update")
        let before = await reactivated.snapshot()
        XCTAssertEqual(before.generation, 1); XCTAssertEqual(before.pendingCount, 1)
        let newer = try await persistence.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Accepted after recovery"), deviceID: fixture.device)]
        }
        XCTAssertEqual(newer.first?.epoch, rotated.epoch)
        let after = await reactivated.snapshot()
        XCTAssertEqual(after.generation, 2); XCTAssertEqual(after.state.events.count, 2)
    }

    func testFailedActivationAfterDrainingWriteReleasesPauseAndKeepsDurableState() async throws {
        let fixture = LocalPersistenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        var currentKeys = fixture.keys; try currentKeys.rotate()
        let persistence = ReaderLocalPersistence()
        let original = try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: currentKeys)
        let gate = WorkflowWriteGate()
        let write = Task {
            try await persistence.performWrite { store in
                await gate.hold()
                return [try await store.append(PrivateEvent(kind: .note, text: "Preserve across failed activation"), deviceID: fixture.device)]
            }
        }
        await gate.waitUntilHeld()
        let activationStarted = expectation(description: "Failed activation waits for the existing write")
        let activation = Task {
            activationStarted.fulfill()
            return try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        }
        await fulfillment(of: [activationStarted], timeout: 3)
        XCTAssertTrue(persistence.isActivating)
        await gate.release()
        _ = try await write.value
        do { _ = try await activation.value; XCTFail("Older keys must not replace the active key bundle") }
        catch { XCTAssertEqual(error as? ReaderError, .invalidKey) }
        XCTAssertFalse(persistence.isActivating)
        XCTAssertTrue(persistence.store === original)
        _ = try await persistence.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Writer is usable after failure"), deviceID: fixture.device)]
        }
        let snapshot = await original.snapshot()
        XCTAssertEqual(snapshot.generation, 2); XCTAssertEqual(snapshot.state.events.count, 2)
    }

    func testCancelledActivationDoesNotCancelAnAcceptedWriteOrLeaveAPermanentPause() async throws {
        let fixture = LocalPersistenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let persistence = ReaderLocalPersistence()
        let original = try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        let gate = WorkflowWriteGate()
        let write = Task {
            try await persistence.performWrite { store in
                await gate.hold()
                return [try await store.append(PrivateEvent(kind: .note, text: "The user already sent this"), deviceID: fixture.device)]
            }
        }
        await gate.waitUntilHeld()
        let activationStarted = expectation(description: "Cancellable activation waits for the existing write")
        let activation = Task {
            activationStarted.fulfill()
            return try await persistence.activate(url: fixture.url, accountID: fixture.account, localKey: fixture.localKey, keys: fixture.keys)
        }
        await fulfillment(of: [activationStarted], timeout: 3)
        XCTAssertTrue(persistence.isActivating)
        activation.cancel()
        await gate.release()
        _ = try await write.value
        do { _ = try await activation.value; XCTFail("Expected activation cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(persistence.isActivating)
        XCTAssertTrue(persistence.store === original)
        _ = try await persistence.performWrite { store in
            [try await store.append(PrivateEvent(kind: .note, text: "Still writable after cancellation"), deviceID: fixture.device)]
        }
        let snapshot = await original.snapshot()
        XCTAssertEqual(snapshot.generation, 2); XCTAssertEqual(snapshot.pendingCount, 2)
    }

    private func paper(title: String, authors: String = "", abstract: String = "", keywords: [String] = []) -> Paper {
        Paper(id: UUID(), title: title, authors: authors, year: nil, abstract: abstract, keywords: keywords, fileURL: nil, artifactID: nil)
    }
}

private struct LocalPersistenceFixture: Sendable {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-lifecycle-\(UUID().wire)", isDirectory: true)
    let account = UUID(), device = UUID(), localKey = ReaderCrypto.randomKey()
    var url: URL { folder.appendingPathComponent("state.sqlite") }
    var keys: KeyBundle
    init() { keys = KeyBundle.generate(accountID: account) }
}

private actor WorkflowWriteGate {
    private var held = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        await withCheckedContinuation { continuation in
            waiter = continuation; held = true
            for arrival in arrivals { arrival.resume() }
            arrivals = []
        }
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { waiter?.resume(); waiter = nil }
}

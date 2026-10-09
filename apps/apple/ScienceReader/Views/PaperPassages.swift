import SwiftUI
import WebKit
import ScienceReaderCore

// Conversations linked to the passage they came from (docs/DECISIONS.md, "Passage-linked conversations"):
// a selection action saves a `TextAnchor` on its new conversation; the chat offers Go to passage; the paper
// underlines passages that have conversations, and a tap on one opens its chat. The bridge half is at the end of
// reader-bridge.js.

/// Where a selection action's question came from: the paper and the passage's anchor.
struct PassageOrigin: Equatable {
    let documentID: UUID
    let anchor: TextAnchor

    /// Nil for a paper without an immutable artifact (nothing to anchor to) or an empty quote.
    init?(scope: ReaderDocumentScope, selection: ReaderSelection, quote: String) {
        guard let artifactID = scope.artifactID,
              let anchor = TextAnchor.passage(artifactID: artifactID, selection: selection, quote: quote) else { return nil }
        documentID = scope.paperID; self.anchor = anchor
    }
}

/// A passage with a conversation, as the open paper underlines it.
struct PaperMark: Equatable {
    let conversationID: UUID
    let anchor: TextAnchor
    /// Made on the artifact being shown, so its block ID applies; otherwise only its text is searched for.
    let sameArtifact: Bool

    /// What the bridge needs (`__scienceReaderSetMarks`, `__scienceReaderGoToPassage`); no conversation text.
    var bridgeValue: [String: Any] {
        ["id": conversationID.wire, "quote": anchor.quote, "prefix": anchor.prefix, "suffix": anchor.suffix,
         "element": anchor.elementID ?? NSNull(), "same": sameArtifact]
    }
}

/// Go to passage, waiting for the reader like a contents jump.
struct PaperPassageRequest: Equatable, Identifiable {
    /// What asked for the passage: a chat's Go to passage, or a podcast transcript's evidence (PodcastCenter).
    enum Origin: Equatable { case chat, podcastEvidence }
    let id = UUID()
    let documentID: UUID
    let conversationID: UUID
    let anchor: TextAnchor
    var sameArtifact = false
    let requestedAt = Date()
    var origin = Origin.chat
}

/// The reader coordinator's passage bookkeeping (one load at a time).
struct PaperPassageState {
    var appliedMarks: [PaperMark]?
    var inFlight: UUID?
    var last: UUID?
    var generation = 0
    mutating func reset() { self = PaperPassageState(generation: generation + 1) }
}

extension PaperWebView.Coordinator {
    func applyPassageWork(in web: WKWebView) {
        applyMarks(in: web); applyPassage(in: web)
    }

    private func applyMarks(in web: WKWebView) {
        guard active, ready, parent.figureID == nil, parent.bundle != nil, passages.appliedMarks != parent.marks else { return }
        passages.appliedMarks = parent.marks
        web.callAsyncJavaScript("return window.__scienceReaderSetMarks(list);", arguments: ["list": parent.marks.map(\.bridgeValue)],
                                in: nil, in: .defaultClient, completionHandler: nil)
    }

    private func applyPassage(in web: WKWebView) {
        guard active, ready, parent.figureID == nil, parent.bundle != nil, passages.inFlight == nil,
              let request = parent.passage, request.id != passages.last else { return }
        passages.inFlight = request.id
        let generation = passages.generation
        let anchor = PaperMark(conversationID: request.conversationID, anchor: request.anchor, sameArtifact: request.sameArtifact)
        web.callAsyncJavaScript("return window.__scienceReaderGoToPassage(anchor);", arguments: ["anchor": anchor.bridgeValue],
                                in: nil, in: .defaultClient) { [weak self, weak web] result in
            guard let self, let web, self.active, self.passages.generation == generation else { return }
            self.passages.inFlight = nil; self.passages.last = request.id
            let found = (try? result.get() as? [String: Any])?["found"] as? Bool ?? false
            self.parent.onPassage(request.id, found)
            if let next = self.parent.passage?.id, next != request.id { self.applyPassage(in: web) }
        }
    }

    /// A tap on marked text: the conversations marked there (the bridge checks the point is on the mark's text).
    func receiveMarks(_ body: [String: Any]) {
        guard ready, parent.figureID == nil, let bundle = parent.bundle, body["manifest_sha256"] as? String == bundle.manifestSHA256,
              let values = body["ids"] as? [String], (1...20).contains(values.count) else { return }
        let known = Set(parent.marks.map(\.conversationID))
        let ids = values.compactMap(UUID.init(uuidString:)).filter(known.contains)
        guard ids.count == values.count, Set(ids).count == ids.count else { return }
        parent.onMarks(ids)
    }
}

extension ReaderModel {
    /// The passage a saved conversation was started from, when a selection action started it.
    func passageAnchor(of conversationID: UUID) -> TextAnchor? {
        conversationSummaries.first { $0.id == conversationID }?.anchor
    }

    /// Go to passage is offered for an anchored paper chat whose paper is in the library.
    func canGoToPassage(_ conversationID: UUID?) -> Bool {
        guard let conversationID, let summary = conversationSummaries.first(where: { $0.id == conversationID }),
              summary.anchor != nil, let documentID = summary.documentID else { return false }
        return papers.contains { $0.id == documentID }
    }

    /// Opens the paper (if it isn't open), keeps the conversation as the chat's, and scrolls to the passage with
    /// the citation Back to where reading left off. The reader says so when the passage can't be found.
    func goToPassage(_ conversationID: UUID) {
        guard let summary = conversationSummaries.first(where: { $0.id == conversationID }), let anchor = summary.anchor,
              let documentID = summary.documentID else { return }
        guard let paper = papers.first(where: { $0.id == documentID }) else {
            error = "The paper this chat came from isn’t in your library."; return
        }
        if selectedPaper?.id != paper.id || selectedPaper?.artifactID != paper.artifactID { select(paper) }
        if activeConversation != conversationID { openConversation(conversationID) }
        referenceNotice = nil
        passageRequest = PaperPassageRequest(documentID: documentID, conversationID: conversationID, anchor: anchor)
        tab = .paper
        if wideMode != .browse { wideMode = .reader }
    }

    /// The pending Go to passage for this paper (a request not applied within a minute is dropped, so opening the
    /// paper later doesn't jump unexpectedly).
    func passageJump(for paper: Paper) -> PaperPassageRequest? {
        guard var request = passageRequest, request.documentID == paper.id,
              Date().timeIntervalSince(request.requestedAt) < 60 else { return nil }
        request.sameArtifact = request.anchor.artifactID == paper.artifactID
        return request
    }

    func finishPassage(_ id: UUID, found: Bool) {
        guard let request = passageRequest, request.id == id else { return }
        passageRequest = nil
        if !found {
            referenceNotice = ReferenceNotice(kind: .closed, message: request.origin == .podcastEvidence
                                              ? "Couldn’t find this quote in the paper. The paper may have changed since the episode was made."
                                              : "Couldn’t find the passage this chat came from. The paper may have changed since.",
                                              reference: "")
        }
    }

    /// Passages with conversations on this paper, for the reader to underline (none when turned off in Settings).
    func paperMarks(for paper: Paper) -> [PaperMark] {
        guard showsPassageMarks else { return [] }
        return conversationSummaries.compactMap { summary in
            guard summary.documentID == paper.id, let anchor = summary.anchor else { return nil }
            return PaperMark(conversationID: summary.id, anchor: anchor, sameArtifact: anchor.artifactID == paper.artifactID)
        }
    }

    /// A tap on a mark: its conversation, or a choice when several are marked there.
    func openMarkedConversations(_ ids: [UUID]) {
        let known = ids.filter { id in conversationSummaries.contains { $0.id == id } }
        if known.count == 1 { openConversation(known[0]) } else if known.count > 1 { passageChoices = known }
    }

    /// The chooser's row for a conversation: its short title, with when it was last used if titles repeat.
    func passageChoiceTitle(_ id: UUID, among ids: [UUID]) -> String {
        func title(_ id: UUID) -> String {
            let display = conversationSummaries.first { $0.id == id }.map { ChatTitle.display($0) } ?? ""
            return display.isEmpty ? "Untitled conversation" : display
        }
        let own = title(id)
        guard ids.filter({ title($0) == own }).count > 1 else { return own }
        return own + " · " + ChatHistoryFormat.lastUsed(conversationSummaries.first { $0.id == id }?.lastUsedAt)
    }
}

extension ChatHistoryRow {
    /// All chats' muted second line for a chat from a passage, when the Paper column already names the paper:
    /// the passage in quotes, math as readable symbols, on one line.
    var passageLine: String? {
        guard let quote = summary.anchor?.quote else { return nil }
        let cut = quote.count > 240
        let line = ChatTitle.readable(String(quote.prefix(240)), truncated: cut)
        return line.isEmpty ? nil : "“" + line + "”"
    }
}

/// Several conversations on the tapped passage: choose one (Cancel keeps reading).
struct PassageChooser: ViewModifier {
    @Bindable var model: ReaderModel
    func body(content: Content) -> some View {
        content.confirmationDialog("Chats about this passage", isPresented: Binding(
            get: { model.passageChoices != nil }, set: { if !$0 { model.passageChoices = nil } }),
            titleVisibility: .visible, presenting: model.passageChoices) { ids in
            ForEach(ids, id: \.self) { id in
                Button(model.passageChoiceTitle(id, among: ids)) { model.passageChoices = nil; model.openConversation(id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// "Go to passage" for the visible conversation, in the chat's title menu and its "…" menu.
struct GoToPassageMenuRow: View {
    let model: ReaderModel
    var before: () -> Void = {}
    var body: some View {
        if let id = model.activeConversation, model.canGoToPassage(id) {
            MenuRow("Go to passage", systemImage: "text.quote") { before(); model.goToPassage(id) }
                .accessibilityIdentifier("chat.goToPassage")
        }
    }
}

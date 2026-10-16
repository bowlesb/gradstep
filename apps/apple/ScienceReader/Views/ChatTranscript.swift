import SwiftUI
import UIKit
import ScienceReaderCore

struct ChatTranscript: View {
    @Bindable var model: ReaderModel
    let fontSize: Double
    /// Floating chrome over the transcript (title bar and context switch above, message box and tab bar
    /// below): the conversation scrolls under it, and its ends can scroll clear of it.
    var insets = EdgeInsets()
    @State private var followsLatest = true
    @State private var hasNewMessages = false
    @State private var jump = TranscriptJump()
    @State private var paperActions = ChatPaperActions()
    /// The starters' draw: a new one for each new chat, kept while that empty chat is shown (chat redesign 2026-10-16).
    @State private var starterSeed = UInt32.random(in: .min ... .max)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scope = TranscriptScope(sessionID: model.readerSessionID, composerID: model.chatComposerID)
        let messages = model.chatTranscriptMessages
        ZStack(alignment: .bottomTrailing) {
            TranscriptTable(messages: messages, streamingID: model.chatStreamingMessageID, progress: model.chatStreamingProgress,
                fontSize: fontSize, diagrams: model.chatDiagrams, followUps: model.chatFollowUpQuestions,
                openDiagram: { model.openDiagram($0) }, papers: ChatPaperContext(model: model, actions: paperActions), jump: jump,
                localRequest: model.chatFollowRequest?.composerID == scope.composerID ? model.chatFollowRequest?.id : nil,
                insets: UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0),
                isCurrent: { model.readerSessionID == scope.sessionID && model.chatComposerID == scope.composerID },
                didFollow: { following in
                    guard model.readerSessionID == scope.sessionID, model.chatComposerID == scope.composerID else { return }
                    followsLatest = following
                    if following { hasNewMessages = false }
                })
                .id(scope)
            if messages.isEmpty {
                if showsStarters {
                    // Gemini's empty chat (owner, build 57): a soft glow rising behind the lower part, the starters
                    // just above the message box.
                    StarterGlow().allowsHitTesting(false).accessibilityHidden(true)
                    ChatStarterList(starters: starters) { model.useFollowUp($0) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, insets.bottom + 4)
                } else {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(16).padding(.top, insets.top)
                }
            }
            Button {
                jump = TranscriptJump(animated: !reduceMotion)
            } label: {
                Label(hasNewMessages ? "New messages" : "Latest", systemImage: "arrow.down")
                    .font(.caption.weight(.semibold)).padding(12)
            }
            .modifier(ReaderControlMaterial()).padding(12).padding(.bottom, insets.bottom).accessibilityIdentifier("chat.latest")
            .opacity(!followsLatest && !messages.isEmpty ? 1 : 0)
            .allowsHitTesting(!followsLatest && !messages.isEmpty)
            .accessibilityHidden(followsLatest || messages.isEmpty)
        }
        .onChange(of: scope) { _, _ in followsLatest = true; hasNewMessages = false; starterSeed = .random(in: .min ... .max) }
        .onChange(of: messages.last?.id) { _, _ in if !followsLatest { hasNewMessages = true } }
    }

    /// An empty chat that can be asked: starters instead of a notice.
    private var showsStarters: Bool {
        !model.chatWasDeleted && !model.chatHasRemovedMessages && (model.generalChat || model.canUsePaperChat) && model.chatStudyMap == nil
    }
    /// Three starters for this chat: about its paper (from the paper's reading index, when on this device), else general.
    private var starters: [ChatStarters.Starter] {
        let paper = model.generalChat ? nil : (model.chatPaper?.readerBundle.map { ChatStarters.paper($0.index) }
            ?? ChatStarters.Paper(figures: [], tables: [], equations: 0, headings: []))
        return ChatStarters.choose(paper, seed: starterSeed)
    }

    @ViewBuilder private var emptyState: some View {
        if model.chatWasDeleted {
            ContentUnavailableView("Conversation deleted", systemImage: "bubble.left", description: Text("Start a new chat to continue."))
        } else if model.chatHasRemovedMessages {
            ContentUnavailableView("Messages removed", systemImage: "bubble.left", description: Text("You can add a new message to this conversation."))
        } else if !model.generalChat && !model.canUsePaperChat {
            ContentUnavailableView("Choose a paper", image: GradstepSymbol.paper, description: Text("Open a paper from your library, or use General chat."))
        }
    }
}

/// Starter questions above the message box (Gemini's layout): a line icon and one line of text each, no heading. A tap
/// puts the question in the message box; nothing is sent until the reader sends it.
private struct ChatStarterList: View {
    let starters: [ChatStarters.Starter]
    let use: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(starters.enumerated()), id: \.element) { index, starter in
                Button { use(starter.text) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: Self.symbol(starter.icon)).font(.system(size: 19, weight: .regular))
                            .foregroundStyle(.secondary).frame(width: 28)
                        Text(starter.text).font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11).padding(.horizontal, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Puts this question in the message box")
                .accessibilityIdentifier("chat.starter.\(index)")
            }
        }
        .readableColumn()
        .accessibilityElement(children: .contain).accessibilityLabel("Suggested questions")
        .accessibilityIdentifier("chat.starters")
    }

    static func symbol(_ icon: String) -> String {
        switch icon {
        case "target": "scope"
        case "gear": "gearshape"
        case "figure": "photo"
        case "function": "function"
        case "table": "tablecells"
        case "chart": "chart.line.uptrend.xyaxis"
        case "question": "questionmark.bubble"
        case "book": "book"
        case "lightbulb": "lightbulb"
        case "compare": "arrow.left.arrow.right"
        case "map": "map"
        default: "sparkle"
        }
    }
}

/// The soft accent glow behind the lower part of an empty chat (Gemini's), stronger in the dark.
private struct StarterGlow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if !reduceTransparency {
            // An ellipse centred on the bottom edge, fading out about half way up.
            EllipticalGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.12), Color.accentColor.opacity(0)],
                               center: .bottom, startRadiusFraction: 0, endRadiusFraction: 0.62)
                .ignoresSafeArea()
        }
    }
}

private struct TranscriptScope: Hashable {
    let sessionID: UUID
    let composerID: UUID?
}

private struct TranscriptJump: Equatable {
    let id = UUID()
    var animated = false
}

private struct TranscriptMessage: View {
    let message: AppliedEvent
    let streaming: Bool
    /// The server's latest status for the streaming answer (searching, adding a paper).
    let progress: ChatProgress?
    let fontSize: Double
    let diagram: ChatDiagramLink?
    let openDiagram: (UUID) -> Void
    let papers: ChatPaperContext?
    /// Follow-up questions the newest answer suggests (only on that answer, never while streaming).
    var followUps: [String] = []
    @State private var showsFollowUps = false
    let first: Bool
    let last: Bool

    var body: some View {
        HStack(alignment: .top) {
            if message.payload.role == .user { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 8) {
                if streaming && (message.payload.text ?? "").isEmpty {
                    // Only before the first token; partial and final text then
                    // share identical layout, with no row added or removed.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: progress?.text ?? "Thinking…").font(.system(size: fontSize * 0.88)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: progress?.text ?? "Assistant is answering"))
                    .accessibilityIdentifier("chat.message.thinking")
                } else {
                    let sources = streaming ? nil : ChatRichText.trailingSources(message.payload.text ?? "")
                    if let inline = inlineParts {
                        // Each part's crop where the answer discusses it (owner, 2026-10-15: "the crops should be inline").
                        InlineFigurePartsAnswer(source: message.payload.text ?? "", stored: inline.stored, image: inline.image, fontSize: fontSize,
                                                identifier: "chat.message.text.\(message.id.wire)", onQuote: quoteHandler, onCite: citeHandler)
                    } else {
                        ChatMessageText(source: message.payload.text ?? "", fontSize: fontSize, streaming: streaming,
                                        speaker: message.payload.role == .user ? "You" : "Assistant", identifier: "chat.message.text.\(message.id.wire)",
                                        assistant: message.payload.role == .assistant, onQuote: quoteHandler, onCite: citeHandler)
                    }
                    if let sources { ChatSourcesView(sources: sources.sources, fontSize: fontSize) }
                    // What the server is doing between pieces of text; cleared when text resumes.
                    if streaming, let progress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(verbatim: progress.text).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: fontSize * 0.78)).foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: progress.text))
                        .accessibilityIdentifier("chat.message.progress")
                    }
                    // Papers the finished answer names (arXiv IDs, DOIs), found on the device.
                    if !streaming, message.payload.role == .assistant, message.payload.status == .complete, let papers {
                        let mentions = ChatPaperMentions.extract(from: message.payload.text ?? "")
                        if !mentions.isEmpty { ChatAnswerPapersView(mentions: mentions, fontSize: fontSize, context: papers) }
                    }
                }
                if message.payload.status == .interrupted {
                    let note = papers?.model.chatInterruptionNotes[message.id] ?? papers?.model.chatInterruptionNotes[message.payload.entityID]
                    Label(note ?? "Response interrupted", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore).accessibilityLabel(Text(note ?? "Response interrupted"))
                        .accessibilityIdentifier("chat.message.interrupted")
                }
                // Which model and settings answered (2026-10-08), quietly; nothing for answers saved without them.
                if !streaming, message.payload.role == .assistant,
                   let answeredBy = ChatProfileText.answeredBy(model: message.payload.model, profile: message.payload.profile) {
                    Text(verbatim: answeredBy).font(.system(size: fontSize * 0.72)).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel(Text(verbatim: "Answered with \(answeredBy)"))
                        .accessibilityIdentifier("chat.message.answeredBy.\(message.payload.entityID.wire)")
                }
                if let diagram, !streaming, diagram.isFigureParts, let inline = inlineParts {
                    // The crops are in the answer; under it, the whole figure with its parts outlined (a tap opens them all).
                    FigurePartsOverview(stored: inline.stored, image: inline.image, fontSize: fontSize) { openDiagram(diagram.id) }
                        .accessibilityIdentifier("chat.message.figureParts.\(message.payload.entityID.wire)")
                } else if let diagram, !streaming, diagram.isFigureParts, let model = papers?.model,
                   let stored = model.diagram(diagram.id).flatMap({ StoredFigureParts.decode($0.source) }) {
                    // An answer from before the inline crops (no markers): each crop with its number and label under it.
                    FigurePartsStrip(stored: stored, image: model.figureImage(manifest: stored.manifestSHA256, paths: stored.paths),
                                     fontSize: fontSize) { openDiagram(diagram.id) }
                        .accessibilityIdentifier("chat.message.figureParts.\(message.payload.entityID.wire)")
                } else if let diagram, !streaming, let model = papers?.model {
                    // The diagram itself in the answer (owner, build 46: "If you bothered to create a diagram please show it").
                    InlineDiagram(link: diagram, diagram: model.diagram(diagram.id), fontSize: fontSize) { openDiagram(diagram.id) }
                        .accessibilityIdentifier("chat.message.diagram.\(message.payload.entityID.wire)")
                } else if let diagram, !streaming {
                    Button { openDiagram(diagram.id) } label: {
                        Label(diagram.isFigureParts ? "View figure parts: \(diagram.title)" : diagram.isHTML ? "View visual: \(diagram.title)" : "View diagram: \(diagram.title)",
                              systemImage: diagram.isFigureParts ? "square.split.2x2" : diagram.isHTML ? "rectangle.and.text.magnifyingglass" : "square.stack.3d.up")
                            .font(.system(size: fontSize * 0.88)).lineLimit(2)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("chat.message.diagram.\(message.payload.entityID.wire)")
                }
                // Follow-up questions (2026-10-14), on request (owner, build 46: "they need to be upon request… take up too
                // much space"): one small control; open, each becomes the message; nothing is sent until the reader does.
                if !followUps.isEmpty, !streaming, message.payload.role == .assistant, let model = papers?.model {
                    VStack(alignment: .leading, spacing: 6) {
                        Button { withAnimation(.easeInOut(duration: 0.15)) { showsFollowUps.toggle() } } label: {
                            Label(showsFollowUps ? "Hide suggested questions" : "Suggested questions (\(followUps.count))",
                                  systemImage: showsFollowUps ? "chevron.up" : "text.bubble")
                                .font(.system(size: fontSize * 0.78)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("chat.followUps.toggle")
                        if showsFollowUps {
                            ForEach(followUps, id: \.self) { question in
                                Button { model.useFollowUp(question) } label: {
                                    Text(verbatim: question).font(.system(size: fontSize * 0.82)).multilineTextAlignment(.leading).lineLimit(3)
                                }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(.accentColor)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .contain).accessibilityLabel("Suggested questions")
                    .accessibilityIdentifier("chat.followUps")
                }
            }
            // Design audit F7: answers sit on the page (more room for equations); your messages keep a bubble.
            .padding(message.payload.role == .user ? 12 : 0)
            .frame(maxWidth: message.payload.role == .user ? nil : .infinity, alignment: .leading)
            .background(message.payload.role == .user ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
        }
        .padding(.horizontal, 16).padding(.top, first ? 16 : 0).padding(.bottom, last ? 24 : 20)
        .frame(maxWidth: 720).frame(maxWidth: .infinity)
        .accessibilityIdentifier("chat.message.\(message.id.wire)")
    }

    /// An answer with figure parts whose text marks where each part goes: the parts and the figure (nil on this device
    /// when the paper isn't here; the crops then show their numbers and labels only).
    private var inlineParts: (stored: StoredFigureParts, image: CGImage?)? {
        guard !streaming, message.payload.role == .assistant, let diagram, diagram.isFigureParts, let model = papers?.model,
              let stored = model.diagram(diagram.id).flatMap({ StoredFigureParts.decode($0.source) }),
              FigurePartMarkers.hasMarkers(message.payload.text ?? "") else { return nil }
        return (stored, model.figureImage(manifest: stored.manifestSHA256, paths: stored.paths))
    }

    /// Selected answer text and formulas: Quote in Chat, Explain, Define (not while streaming).
    private var quoteHandler: ChatQuoteHandler? {
        guard message.payload.role == .assistant, !streaming, let model = papers?.model else { return nil }
        return { action, quote in model.chatQuoteAction(action, quote: quote) }
    }
    /// An answer's `[¶N]` citations open that block of the paper (not while streaming); a question's marker too.
    private var citeHandler: ChatCiteHandler? {
        guard !(message.payload.role == .assistant && streaming), let model = papers?.model else { return nil }
        return { marker in model.goToCitedBlock(marker) }
    }
}

private struct TranscriptTable: UIViewRepresentable {
    let messages: [AppliedEvent]
    let streamingID: UUID?
    let progress: ChatProgress?
    let fontSize: Double
    let diagrams: [UUID: ChatDiagramLink]
    let followUps: [String]
    let openDiagram: (UUID) -> Void
    let papers: ChatPaperContext
    let jump: TranscriptJump
    let localRequest: UUID?
    /// The floating chrome's depth at each end; the table scrolls under it.
    let insets: UIEdgeInsets
    let isCurrent: () -> Bool
    let didFollow: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TranscriptTableView {
        let table = TranscriptTableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.keyboardDismissMode = .interactive
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 240
        table.sectionHeaderHeight = 0; table.sectionFooterHeight = 0
        table.sectionHeaderTopPadding = 0
        table.accessibilityIdentifier = "chat.transcript"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "message")
        context.coordinator.attach(table)
        return table
    }

    func updateUIView(_ table: TranscriptTableView, context: Context) {
        context.coordinator.receive(self, table: table)
    }

    static func dismantleUIView(_ table: TranscriptTableView, coordinator: Coordinator) {
        coordinator.retire(table)
    }

    @MainActor final class Coordinator: NSObject, UITableViewDelegate {
        private var source: UITableViewDiffableDataSource<Int, UUID>?
        private var owner: TranscriptTable?
        private var displayed: [AppliedEvent] = []
        private var displayedStreamingID: UUID?
        private var displayedProgress: ChatProgress?
        private var displayedFont = 0.0
        private var displayedDiagrams: [UUID: ChatDiagramLink] = [:]
        private var displayedFollowUps: [String] = []
        private var pending: TranscriptTable?
        private var generation = 0
        private var applying = false
        private var updating = false
        private var retired = false
        private var layoutDepth = 0
        private var restoring = false
        private var animating = false
        private var userScrolling = false
        private var settleAfterApply = false
        private var following = true
        private var publishedFollow: Bool?
        private var lastJump: UUID?
        private var lastLocalRequest: UUID?
        private var needsRestore = true
        private var animateRestore = false
        private var anchors: [RowAnchor] = []
        private var realizingAnchor: UUID?
        private var lastContentSize = CGSize.zero
        private var lastViewportSize = CGSize.zero

        private struct RowAnchor {
            let id: UUID
            let relativeY: CGFloat
        }

        func attach(_ table: TranscriptTableView) {
            table.delegate = self
            table.willResize = { [weak self, weak table] in
                guard let self, let table, !self.retired, self.owner?.isCurrent() == true else { return }
                if !self.following && !self.needsRestore && !self.userScrolling { self.anchors = self.readAnchors(table) }
                self.realizingAnchor = nil
                self.needsRestore = true
            }
            table.beforeLayout = { [weak self] in self?.layoutDepth += 1 }
            table.afterLayout = { [weak self, weak table] in
                guard let self, let table else { return }
                self.finishLayout(table)
                self.layoutDepth -= 1
            }
            source = UITableViewDiffableDataSource<Int, UUID>(tableView: table) { [weak self] table, indexPath, id in
                guard let self, !self.retired, self.owner?.isCurrent() == true,
                      let index = self.displayed.firstIndex(where: { $0.id == id }) else { return UITableViewCell() }
                let cell = table.dequeueReusableCell(withIdentifier: "message", for: indexPath)
                cell.selectionStyle = .none
                cell.backgroundConfiguration = .clear()
                cell.isAccessibilityElement = false
                cell.contentConfiguration = UIHostingConfiguration {
                    TranscriptMessage(message: self.displayed[index], streaming: id == self.displayedStreamingID,
                        progress: id == self.displayedStreamingID ? self.displayedProgress : nil, fontSize: self.displayedFont,
                        diagram: self.displayedDiagrams[self.displayed[index].payload.entityID], openDiagram: { [weak self] id in self?.owner?.openDiagram(id) },
                        papers: self.owner?.papers, followUps: index == self.displayed.count - 1 ? self.displayedFollowUps : [],
                        first: index == 0, last: index == self.displayed.count - 1)
                }.margins(.all, 0).minSize(width: 0, height: 0)
                return cell
            }
        }

        func receive(_ value: TranscriptTable, table: TranscriptTableView) {
            guard !retired, value.isCurrent() else { return }
            updating = true
            defer { updating = false; table.setNeedsLayout() }
            owner = value
            applyInsets(value.insets, to: table)
            if lastJump != value.jump.id || (value.localRequest != nil && lastLocalRequest != value.localRequest) {
                following = true; anchors = []; realizingAnchor = nil; needsRestore = true
                animateRestore = lastJump != nil && lastJump != value.jump.id && value.jump.animated
                lastJump = value.jump.id
            }
            lastLocalRequest = value.localRequest
            guard displayed != value.messages || displayedFont != value.fontSize || displayedStreamingID != value.streamingID
                    || displayedProgress != value.progress || displayedDiagrams != value.diagrams || displayedFollowUps != value.followUps || applying else { return }
            generation += 1
            pending = value
            applyPending(table)
        }

        /// Chrome that grows or shrinks (a banner, the keyboard hiding the tab bar) moves the readable area;
        /// the latest message stays in view when followed, otherwise the rows being read stay put.
        private func applyInsets(_ insets: UIEdgeInsets, to table: TranscriptTableView) {
            guard table.contentInset != insets else { return }
            if !following && !userScrolling && anchors.isEmpty { anchors = readAnchors(table) }
            table.contentInset = insets
            table.verticalScrollIndicatorInsets = insets
            realizingAnchor = nil
            needsRestore = true
        }

        private func applyPending(_ table: TranscriptTableView) {
            guard !applying, !retired, let update = pending, update.isCurrent(), let source else { return }
            pending = nil
            if !following && anchors.isEmpty && !userScrolling { anchors = readAnchors(table) }
            let old = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
            let oldFont = displayedFont, oldStreaming = displayedStreamingID, oldDiagrams = displayedDiagrams, oldProgress = displayedProgress
            let oldFollowUps = displayedFollowUps
            let oldFirst = displayed.first?.id
            let oldLast = displayed.last?.id
            displayed = update.messages; displayedFont = update.fontSize; displayedStreamingID = update.streamingID
            displayedProgress = update.progress
            displayedDiagrams = update.diagrams
            displayedFollowUps = update.followUps
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0]); snapshot.appendItems(displayed.map(\.id))
            let existing = Set(source.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(displayed.compactMap { item in
                guard existing.contains(item.id) else { return nil }
                let edgeChanged = (item.id == oldFirst) != (item.id == displayed.first?.id)
                    || (item.id == oldLast) != (item.id == displayed.last?.id)
                let streamingChanged = (item.id == oldStreaming) != (item.id == displayedStreamingID)
                    || (item.id == displayedStreamingID && oldProgress != displayedProgress)
                let diagramChanged = oldDiagrams[item.payload.entityID] != displayedDiagrams[item.payload.entityID]
                let followUpsChanged = (item.id == oldLast || item.id == displayed.last?.id) && oldFollowUps != displayedFollowUps
                return old[item.id] != item || oldFont != displayedFont || edgeChanged || streamingChanged || diagramChanged || followUpsChanged ? item.id : nil
            })
            applying = true
            let revision = generation
            source.apply(snapshot, animatingDifferences: false) { [weak self, weak table] in
                guard let self, let table, !self.retired, self.owner?.isCurrent() == true else { return }
                self.applying = false
                if self.pending != nil { self.applyPending(table); return }
                guard revision == self.generation else { return }
                if self.settleAfterApply { self.settleUserScroll(table); return }
                self.realizingAnchor = nil
                self.needsRestore = true
                table.setNeedsLayout()
            }
        }

        private func readAnchors(_ table: UITableView) -> [RowAnchor] {
            guard let source else { return [] }
            let top = table.contentOffset.y + table.adjustedContentInset.top
            return (table.indexPathsForVisibleRows ?? []).sorted().compactMap { path in
                guard let id = source.itemIdentifier(for: path) else { return nil }
                let frame = table.rectForRow(at: path)
                return frame.maxY > top ? RowAnchor(id: id, relativeY: frame.minY - top) : nil
            }
        }

        private func finishLayout(_ table: TranscriptTableView) {
            guard !retired, owner?.isCurrent() == true, !applying, !updating, !restoring,
                  table.bounds.height > 0, table.bounds.width > 0 else { return }
            let contentChanged = lastContentSize != table.contentSize
            let resized = lastViewportSize != table.bounds.size
            lastContentSize = table.contentSize
            lastViewportSize = table.bounds.size
            if !userScrolling && !table.isDragging && !table.isDecelerating && !animating && (needsRestore || contentChanged || resized) {
                restoring = true
                if following, !displayed.isEmpty {
                    let path = IndexPath(row: displayed.count - 1, section: 0)
                    if table.cellForRow(at: path) == nil { table.scrollToRow(at: path, at: .bottom, animated: false) }
                    let target = clampedY(table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom, table)
                    let shouldAnimate = animateRestore && abs(table.contentOffset.y - target) > pixel(table)
                    animating = shouldAnimate
                    if abs(table.contentOffset.y - target) > pixel(table) {
                        table.setContentOffset(CGPoint(x: 0, y: target), animated: shouldAnimate)
                    }
                } else if let anchor = anchors.first(where: { source?.indexPath(for: $0.id) != nil }), let path = source?.indexPath(for: anchor.id) {
                    // Realize one saved row, then restore from its measured layout.
                    // No recursive layout or eager measurement of the history.
                    if table.cellForRow(at: path) == nil && realizingAnchor != anchor.id {
                        realizingAnchor = anchor.id
                        table.scrollToRow(at: path, at: .top, animated: false)
                        needsRestore = true; restoring = false; table.setNeedsLayout()
                        return
                    }
                    if table.cellForRow(at: path) != nil {
                        let target = clampedY(table.rectForRow(at: path).minY - anchor.relativeY - table.adjustedContentInset.top, table)
                        if abs(table.contentOffset.y - target) > pixel(table) { table.setContentOffset(CGPoint(x: 0, y: target), animated: false) }
                    } else { anchors = [] }
                } else {
                    // If all previously visible rows were removed, retain UIKit's
                    // clamped position and capture the newly visible rows.
                    anchors = readAnchors(table)
                }
                needsRestore = false; animateRestore = false
                restoring = false
            }
            if publishedFollow != following {
                publishedFollow = following
                owner?.didFollow(following)
            }
        }

        private func clampedY(_ value: CGFloat, _ table: UITableView) -> CGFloat {
            let minimum = -table.adjustedContentInset.top
            return min(max(minimum, value), max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom))
        }

        private func pixel(_ table: UITableView) -> CGFloat { 1 / (table.window?.screen.scale ?? 2) }

        /// Whether the end of the conversation is on screen. Layout and chrome changes allow 80 pt of slack; the
        /// reader's own scroll allows none (`Self.gestureTolerance`): scrolling up even a little while an answer
        /// streams means staying there (owner report, build 35), and following resumes only at the end itself.
        private func isAtEnd(_ table: UITableView, tolerance: CGFloat = 80) -> Bool {
            guard !displayed.isEmpty else { return true }
            let last = IndexPath(row: displayed.count - 1, section: 0)
            guard table.cellForRow(at: last) != nil else { return false }
            return table.rectForRow(at: last).maxY <= table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom + tolerance
        }
        static let gestureTolerance: CGFloat = 2

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard !retired, owner?.isCurrent() == true else { return }
            userScrolling = true; following = false; anchors = []; realizingAnchor = nil; needsRestore = false; animating = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let table = scrollView as? TranscriptTableView, !retired, owner?.isCurrent() == true,
                  !applying, !updating, layoutDepth == 0, !restoring, !animating, (!needsRestore || userScrolling) else { return }
            following = isAtEnd(table, tolerance: userScrolling ? Self.gestureTolerance : 80)
            anchors = following ? [] : readAnchors(table)
            if publishedFollow != following { publishedFollow = following; owner?.didFollow(following) }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard !retired, owner?.isCurrent() == true else { return }
            animating = false; needsRestore = true; scrollView.setNeedsLayout()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate, let table = scrollView as? TranscriptTableView { settleUserScroll(table) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let table = scrollView as? TranscriptTableView { settleUserScroll(table) }
        }

        private func settleUserScroll(_ table: TranscriptTableView) {
            guard !retired, owner?.isCurrent() == true else { return }
            userScrolling = false
            if applying { settleAfterApply = true; return }
            settleAfterApply = false
            // The gesture's final position owns any resize that happened while
            // dragging. Never replay an anchor captured before that gesture.
            following = isAtEnd(table, tolerance: Self.gestureTolerance)
            anchors = following ? [] : readAnchors(table)
            realizingAnchor = nil; needsRestore = true
            table.setNeedsLayout()
        }

        func retire(_ table: TranscriptTableView) {
            retired = true; generation += 1
            pending = nil; owner = nil; displayed = []; anchors = []
            table.willResize = nil; table.beforeLayout = nil; table.afterLayout = nil
            for cell in table.visibleCells { cell.contentConfiguration = nil }
            table.delegate = nil; table.dataSource = nil; table.reloadData()
            source = nil
        }
    }
}

private final class TranscriptTableView: UITableView {
    var willResize: (() -> Void)?
    var beforeLayout: (() -> Void)?
    var afterLayout: (() -> Void)?

    override var bounds: CGRect {
        willSet { if bounds.size != newValue.size { willResize?() } }
    }

    override var frame: CGRect {
        willSet { if frame.size != newValue.size { willResize?() } }
    }

    override func layoutSubviews() {
        beforeLayout?()
        super.layoutSubviews()
        afterLayout?()
    }
}

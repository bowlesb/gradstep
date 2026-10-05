import SwiftUI
import UIKit
import ScienceReaderCore

struct ChatTranscript: View {
    @Bindable var model: ReaderModel
    let fontSize: Double
    @State private var followsLatest = true
    @State private var hasNewMessages = false
    @State private var jump = TranscriptJump()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let scope = TranscriptScope(sessionID: model.readerSessionID, composerID: model.chatComposerID)
        let messages = model.chatTranscriptMessages
        ZStack(alignment: .bottomTrailing) {
            TranscriptTable(messages: messages, streamingID: model.chatStreamingMessageID, fontSize: fontSize, diagrams: model.chatDiagrams,
                openDiagram: { model.openDiagram($0) }, jump: jump,
                localRequest: model.chatFollowRequest?.composerID == scope.composerID ? model.chatFollowRequest?.id : nil,
                isCurrent: { model.readerSessionID == scope.sessionID && model.chatComposerID == scope.composerID },
                didFollow: { following in
                    guard model.readerSessionID == scope.sessionID, model.chatComposerID == scope.composerID else { return }
                    followsLatest = following
                    if following { hasNewMessages = false }
                })
                .id(scope)
            if messages.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(16)
            }
            Button {
                jump = TranscriptJump(animated: !reduceMotion)
            } label: {
                Label(hasNewMessages ? "New messages" : "Latest", systemImage: "arrow.down")
                    .font(.caption.weight(.semibold)).padding(12)
            }
            .modifier(ReaderControlMaterial()).padding(12).accessibilityIdentifier("chat.latest")
            .opacity(!followsLatest && !messages.isEmpty ? 1 : 0)
            .allowsHitTesting(!followsLatest && !messages.isEmpty)
            .accessibilityHidden(followsLatest || messages.isEmpty)
        }
        .onChange(of: scope) { _, _ in followsLatest = true; hasNewMessages = false }
        .onChange(of: messages.last?.id) { _, _ in if !followsLatest { hasNewMessages = true } }
    }

    @ViewBuilder private var emptyState: some View {
        if model.chatWasDeleted {
            ContentUnavailableView("Conversation deleted", systemImage: "bubble.left", description: Text("Start a new chat to continue."))
        } else if model.chatHasRemovedMessages {
            ContentUnavailableView("Messages removed", systemImage: "bubble.left", description: Text("You can add a new message to this conversation."))
        } else if !model.generalChat && !model.canUsePaperChat {
            ContentUnavailableView("Choose a paper", systemImage: "doc.text", description: Text("Open a paper from your library, or use General chat."))
        } else {
            ContentUnavailableView(model.generalChat ? "Explore an idea" : "Ask about this paper", systemImage: "bubble.left.and.bubble.right", description: Text(model.generalChat ? "Ask a research question." : "Select a passage or ask a question."))
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
    let fontSize: Double
    let diagram: ChatDiagramLink?
    let openDiagram: (UUID) -> Void
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
                        Text("Thinking…").font(.system(size: fontSize * 0.88)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("Assistant is answering")
                    .accessibilityIdentifier("chat.message.thinking")
                } else {
                    ChatRichTextView(source: message.payload.text ?? "", fontSize: fontSize)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("chat.message.text.\(message.id.wire)")
                        .accessibilityLabel(Text("\(message.payload.role == .user ? "You" : "Assistant"): \(Text(Self.inlineSource(message.payload.text)))"))
                }
                if message.payload.status == .interrupted {
                    Label("Response interrupted", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let diagram, !streaming {
                    Button { openDiagram(diagram.id) } label: {
                        Label("View diagram: \(diagram.title)", systemImage: "square.stack.3d.up").font(.system(size: fontSize * 0.88)).lineLimit(2)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("chat.message.diagram.\(message.payload.entityID.wire)")
                }
            }
            .padding(12).background(message.payload.role == .user ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            if message.payload.role != .user { Spacer(minLength: 24) }
        }
        .padding(.horizontal, 16).padding(.top, first ? 16 : 0).padding(.bottom, last ? 24 : 20)
        .frame(maxWidth: 720).frame(maxWidth: .infinity)
        .accessibilityIdentifier("chat.message.\(message.id.wire)")
    }

    /// Inline Markdown, but backslashes stay literal: until rich rendering
    /// lands, LaTeX source such as `\(`, `\[`, `\{` and `\_` displays verbatim
    /// instead of losing its backslash to Markdown escaping.
    static func inlineSource(_ text: String?) -> LocalizedStringKey {
        LocalizedStringKey(ChatDisplayText.inlineMarkdownPreservingBackslashes(text ?? ""))
    }
}

private struct TranscriptTable: UIViewRepresentable {
    let messages: [AppliedEvent]
    let streamingID: UUID?
    let fontSize: Double
    let diagrams: [UUID: ChatDiagramLink]
    let openDiagram: (UUID) -> Void
    let jump: TranscriptJump
    let localRequest: UUID?
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
        private var displayedFont = 0.0
        private var displayedDiagrams: [UUID: ChatDiagramLink] = [:]
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
                    TranscriptMessage(message: self.displayed[index], streaming: id == self.displayedStreamingID, fontSize: self.displayedFont,
                        diagram: self.displayedDiagrams[self.displayed[index].payload.entityID], openDiagram: { [weak self] id in self?.owner?.openDiagram(id) },
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
            if lastJump != value.jump.id || (value.localRequest != nil && lastLocalRequest != value.localRequest) {
                following = true; anchors = []; realizingAnchor = nil; needsRestore = true
                animateRestore = lastJump != nil && lastJump != value.jump.id && value.jump.animated
                lastJump = value.jump.id
            }
            lastLocalRequest = value.localRequest
            guard displayed != value.messages || displayedFont != value.fontSize || displayedStreamingID != value.streamingID
                    || displayedDiagrams != value.diagrams || applying else { return }
            generation += 1
            pending = value
            applyPending(table)
        }

        private func applyPending(_ table: TranscriptTableView) {
            guard !applying, !retired, let update = pending, update.isCurrent(), let source else { return }
            pending = nil
            if !following && anchors.isEmpty && !userScrolling { anchors = readAnchors(table) }
            let old = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
            let oldFont = displayedFont, oldStreaming = displayedStreamingID, oldDiagrams = displayedDiagrams
            let oldFirst = displayed.first?.id
            let oldLast = displayed.last?.id
            displayed = update.messages; displayedFont = update.fontSize; displayedStreamingID = update.streamingID
            displayedDiagrams = update.diagrams
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0]); snapshot.appendItems(displayed.map(\.id))
            let existing = Set(source.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(displayed.compactMap { item in
                guard existing.contains(item.id) else { return nil }
                let edgeChanged = (item.id == oldFirst) != (item.id == displayed.first?.id)
                    || (item.id == oldLast) != (item.id == displayed.last?.id)
                let streamingChanged = (item.id == oldStreaming) != (item.id == displayedStreamingID)
                let diagramChanged = oldDiagrams[item.payload.entityID] != displayedDiagrams[item.payload.entityID]
                return old[item.id] != item || oldFont != displayedFont || edgeChanged || streamingChanged || diagramChanged ? item.id : nil
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

        private func isAtEnd(_ table: UITableView) -> Bool {
            guard !displayed.isEmpty else { return true }
            let last = IndexPath(row: displayed.count - 1, section: 0)
            guard table.cellForRow(at: last) != nil else { return false }
            return table.rectForRow(at: last).maxY <= table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom + 80
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard !retired, owner?.isCurrent() == true else { return }
            userScrolling = true; following = false; anchors = []; realizingAnchor = nil; needsRestore = false; animating = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let table = scrollView as? TranscriptTableView, !retired, owner?.isCurrent() == true,
                  !applying, !updating, layoutDepth == 0, !restoring, !animating, (!needsRestore || userScrolling) else { return }
            following = isAtEnd(table)
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
            following = isAtEnd(table)
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

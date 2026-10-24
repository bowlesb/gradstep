import SwiftUI

/// True for the paper inside the wide Reader (beside its chat column): its options offer Hide/Show chat.
private struct ReaderChatColumnKey: EnvironmentKey { static let defaultValue = false }

/// True for the chat in the wide Reader's column: its paper is visible beside it (whatever `tab` says), so the chat
/// offers no way back to it.
private struct ChatBesidePaperKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var readerChatColumn: Bool {
        get { self[ReaderChatColumnKey.self] }
        set { self[ReaderChatColumnKey.self] = newValue }
    }
    var chatBesidePaper: Bool {
        get { self[ChatBesidePaperKey.self] }
        set { self[ChatBesidePaperKey.self] = newValue }
    }
    /// The chat in Discuss's right slot (iPad Wide): its bar is All chats · title · ⋯ · ✕; ✕ returns to the paper.
    var discussChat: Bool {
        get { self[DiscussChatKey.self] }
        set { self[DiscussChatKey.self] = newValue }
    }
    /// The chat in the Chats view, beside All chats (iPad Wide's Chat place): no All chats button, the list is there.
    var chatsList: Bool {
        get { self[ChatsListKey.self] }
        set { self[ChatsListKey.self] = newValue }
    }
}

private struct DiscussChatKey: EnvironmentKey { static let defaultValue = false }
private struct ChatsListKey: EnvironmentKey { static let defaultValue = false }

/// The wide Reader (iPad, Mac): the paper beside its chat, matching the browser workspace and the legacy
/// large-screen behavior (docs/LEGACY_GAP_AUDIT.md #5). The chat column
/// can be hidden for full-width reading (Paper › "…" › Hide chat; the chat button in the paper's bar brings it back)
/// and widened or narrowed by dragging the divider (double-tap: the default width). Both are kept on this device.
/// A question asked from the paper shows the chat again.
struct ReaderSplit: View {
    @Bindable var model: ReaderModel
    let width: CGFloat
    /// While dragging: the chat width the divider is at (the panes change once, at the end of the drag, so the
    /// paper isn't reflowed on every frame).
    @State private var dragWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let minimumChat: CGFloat = 300
    /// The paper keeps at least this much.
    static let minimumPaper: CGFloat = 420
    /// The earlier fixed width, still the default.
    static func defaultChat(for width: CGFloat) -> CGFloat { min(400, max(320, width * 0.28)) }
    static func maximumChat(for width: CGFloat) -> CGFloat { max(minimumChat, min(width * 0.6, width - minimumPaper)) }
    static func clamped(_ value: CGFloat, for width: CGFloat) -> CGFloat {
        min(maximumChat(for: width), max(minimumChat, value))
    }

    private var chatWidth: CGFloat {
        Self.clamped(model.readerChatWidth.map { CGFloat($0) } ?? Self.defaultChat(for: width), for: width)
    }

    var body: some View {
        HStack(spacing: 0) {
            PaperView(model: model).frame(maxWidth: .infinity)
                .environment(\.readerChatColumn, true)
            if !model.readerChatHidden {
                divider
                ChatView(model: model).frame(width: chatWidth)
                    .environment(\.chatBesidePaper, true)
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Where the divider will land.
            if let dragWidth {
                Rectangle().fill(Color.accentColor).frame(width: 3)
                    .padding(.trailing, dragWidth - 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.readerChatHidden)
    }

    /// The hairline between the panes, with a wider area to drag and a grabber in the middle.
    private var divider: some View {
        Divider()
            .overlay {
                ZStack {
                    Color.clear.frame(width: 24).contentShape(Rectangle())
                    Capsule().fill(Color(uiColor: .tertiaryLabel)).frame(width: 5, height: 44)
                        .background(Capsule().fill(Color(uiColor: .systemBackground)).padding(-3))
                        .hoverEffect(.highlight)
                }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        dragWidth = Self.clamped(chatWidth - value.translation.width, for: width)
                    }
                    .onEnded { value in
                        model.readerChatWidth = Double(Self.clamped(chatWidth - value.translation.width, for: width))
                        dragWidth = nil
                    })
                .onTapGesture(count: 2) { model.readerChatWidth = nil }
                .accessibilityElement()
                .accessibilityLabel("Chat width")
                .accessibilityValue("\(Int(chatWidth.rounded())) points")
                .accessibilityHint("Swipe up or down to resize the chat")
                .accessibilityAdjustableAction { direction in
                    let step: CGFloat = direction == .increment ? 40 : -40
                    model.readerChatWidth = Double(Self.clamped(chatWidth + step, for: width))
                }
                .accessibilityAction(named: "Hide chat") { model.readerChatHidden = true }
                .accessibilityIdentifier("reader.chatDivider")
            }
            .zIndex(1)
    }
}

/// The list in the left slot beside the paper (ReaderModel.wideList): Contents (Navigate, ☰), or on the Mac the library
/// (Browse). The iPad's Library and Feed are places of their own with the paper on their right (WideSlots).
enum WideList: String { case none, papers, contents }

private struct SlotPaneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A page drawn in a Wide slot instead of a sheet (Contents): its top row is the slot's share of the one row.
    var slotPane: Bool {
        get { self[SlotPaneKey.self] }
        set { self[SlotPaneKey.self] = newValue }
    }
}

/// The iPad's Library, Feed and Paper places on one two-slot container (owner, 2026-10-23: "custom two panel behavior
/// for each of the 5 functionality areas"), so the paper keeps one identity, its load and its place, whichever of them
/// shows it:
/// - Library: the Library list | the open paper (a quiet placeholder with none). Still the Library place.
/// - Feed: the feed list | the picked article's abstract (FeedAbstractPane), or its paper once Read.
/// - Paper (promoted with the paper's list toggle, chosen from the places menu, or a helper opened): the paper alone, its
///   column centred; Contents | Paper (Navigate, ☰); Paper | Chat (Discuss). The paper's other helpers (AI Explainer,
///   the equation view, a figure page) open on its right from PaperView (explainerPresentation), on the same divider.
/// The list is on the left from the start, at the divider's place, whether or not something is picked.
struct WideSlots: View {
    @Bindable var model: ReaderModel
    let width: CGFloat
    /// Shared frames between the slots (the explainer handing its slot to the chat).
    @Namespace private var slots

    private enum Other { case library, feed, contents, chat, none }

    var body: some View {
        let other = self.other
        // The Feed's right slot shows the abstract (or a placeholder) until Read opens the paper there.
        let abstract = model.tab == .feed && !(model.feedReading && model.selectedPaper != nil)
        TwoSlotLayout(width: width, other: other == .chat ? .right : other == .none ? .none : .left,
                      arrangement: arrangement(other), collapse: collapse(other),
                      // A list covering the window gives what it picks its slot again: a paper, or the Feed's article.
                      selection: other == .feed ? model.feedPickID.map(AnyHashable.init)
                          : model.selectedPaper.map { AnyHashable($0.id) }) {
            ZStack {
                PaperView(model: model)
                    .accessibilityHidden(abstract).allowsHitTesting(!abstract)
                if abstract { FeedAbstractPane(model: model).transition(.opacity) }
            }
        } otherView: {
            view(other)
        }
        .environment(\.slotNamespace, slots)
    }

    private var other: Other {
        switch model.tab {
        case .library: return .library
        case .feed: return .feed
        default:
            if model.wideDiscuss { return .chat }
            return model.wideList == .contents ? .contents : .none
        }
    }

    private func arrangement(_ other: Other) -> SlotArrangement {
        switch other {
        case .library: .library
        case .feed: .feed
        case .contents: .contents
        case .chat, .none: .companion
        }
    }

    /// Dragging the divider past the other slot's minimum: a list collapses (the paper beside it becomes the Paper place;
    /// Contents closes), a chat closes.
    private func collapse(_ other: Other) -> (() -> Void)? {
        switch other {
        case .library: return model.selectedPaper == nil ? nil : { model.promotePaper() }
        case .feed: return model.feedReading && model.selectedPaper != nil ? { model.promotePaper() } : nil
        case .contents: return { model.wideList = .none }
        case .chat: return { model.tab = .paper }
        case .none: return nil
        }
    }

    private func view(_ other: Other) -> AnyView {
        switch other {
        case .library: return AnyView(LibraryView(model: model))
        case .feed: return AnyView(FeedView(model: model))
        case .contents: return AnyView(ContentsPane(model: model))
        case .chat:
            return AnyView(ChatView(model: model)
                .environment(\.chatBesidePaper, true)
                .environment(\.discussChat, true)
                // Arriving from an explainer: the explainer's frame becomes the chat's.
                .modifier(SharedSlotFrame(id: WideSlotTransition.explainerToChat, namespace: slots)))
        case .none: return AnyView(EmptyView())
        }
    }
}

/// Navigate's left slot: the paper's Contents, Figures, Tables and Equations as on iPhone; a row moves the paper beside it.
private struct ContentsPane: View {
    @Bindable var model: ReaderModel
    var body: some View {
        PaperContentsSheet(headings: model.headings, bundle: model.selectedPaper?.readerBundle, baseFontSize: model.paperFontSize,
                           report: { ReportPresenter.present(model, sheet: "Contents") },
                           onClose: { model.wideList = .none }) { target, id in
            if let key = model.readingLocationKey { model.paperJump = PaperJumpRequest(locationKey: key, headingID: id, target: target) }
        }
        .environment(\.slotPane, true)
        // Its figure pages keep Snippet, Chat and AI Explainer; what they choose applies to the paper beside.
        .environment(\.figureViewHost, model.selectedPaper.map { paper in
            FigureViewHost(model: model, paperID: paper.id,
                           finish: { outcome in model.pendingFigureOutcome = outcome; model.applyPendingFigureOutcome() },
                           close: {})
        })
    }
}

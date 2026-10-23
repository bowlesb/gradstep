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
                    // The places capsule is in the paper's share of the top row.
                    .environment(\.placesInBar, false)
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

/// What a slot of the Wide Paper screen holds (owner, 2026-10-22, "Two slots, a few views").
enum WidePane: Equatable { case papers, feed, contents, paper, explainer, chat }

/// The list in the left slot beside the paper (ReaderModel.wideList).
enum WideList: String { case none, papers, feed, contents }

private struct SlotPaneKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A page drawn in a Wide slot instead of a sheet (Contents): its top row is the slot's share of the one row.
    var slotPane: Bool {
        get { self[SlotPaneKey.self] }
        set { self[SlotPaneKey.self] = newValue }
    }
}

/// The iPad's Wide Paper screen: two slots at most, each in the iPhone's look, moved between by doing things rather than
/// choosing a layout. The paper keeps one identity in every view (its place and its load survive Read ↔ Discuss).
/// - Read: the paper alone, its reading column centred.
/// - Browse: Papers (the library or search results) | Paper. Navigate: Contents | Paper.
/// - Discuss: Paper (about 45%) | Chat. ✕ on the chat returns to Read (or the list it replaced).
/// - Explain: the paper's slot shows the explainer (PaperView › explainerPresentation); the left slot is unchanged.
struct WideSlots: View {
    @Bindable var model: ReaderModel
    let width: CGFloat

    var body: some View {
        let slots = model.wideSlots
        let side: TwoSlotLayout<PaperView, AnyView>.Side = slots.right == .chat ? .right : (slots.left == nil ? .none : .left)
        // Contents' row holds its four tabs and ✕: a little more room than a list.
        TwoSlotLayout(width: width, other: side, listWidth: slots.left == .contents ? { min(420, max(390, ($0 * 0.33).rounded())) } : nil) {
            PaperView(model: model)
        } otherView: {
            other(side == .right ? .chat : (slots.left ?? .paper))
        }
    }

    private func other(_ kind: WidePane) -> AnyView {
        switch kind {
        case .papers:
            return AnyView(LibraryView(model: model).environment(\.placesInBar, false).environment(\.librarySidebar, true))
        case .feed:
            return AnyView(FeedView(model: model).environment(\.placesInBar, false).environment(\.librarySidebar, true))
        case .contents: return AnyView(ContentsPane(model: model))
        case .chat:
            return AnyView(ChatView(model: model)
                .environment(\.chatBesidePaper, true)
                .environment(\.placesInBar, false)
                .environment(\.discussChat, true))
        case .paper, .explainer: return AnyView(EmptyView())
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
    }
}

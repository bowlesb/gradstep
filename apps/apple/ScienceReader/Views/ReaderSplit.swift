import SwiftUI

/// True for the paper inside the wide Reader (beside its chat column): its options offer Hide/Show chat.
private struct ReaderChatColumnKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var readerChatColumn: Bool {
        get { self[ReaderChatColumnKey.self] }
        set { self[ReaderChatColumnKey.self] = newValue }
    }
}

/// The wide Reader (iPad, Mac): the paper beside its chat, as before (docs/LEGACY_GAP_AUDIT.md #5). The chat column
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

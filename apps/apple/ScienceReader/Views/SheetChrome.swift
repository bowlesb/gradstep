import SwiftUI

// An information sheet's top row (owner, build 62; docs/DESIGN.md "Sheet top row" and "Explain actions"): the page's
// actions as words, no centred title and no Done. Build 78 (owner, 2026-10-21: "The report this screen isn't needed. The
// snippet icon is inconsistent. use txt at top Snippet, Chat, AI Explainer. X also not needed"): a figure, table or
// equation page's row is three glass capsules with words — Snippet, Chat, AI Explainer — and nothing else; the sheet
// closes by swiping it down (or VoiceOver's escape). The Mac, which has no swipe, keeps its X. It is the sheet's own
// navigation bar, so on iOS 26 its items are Liquid Glass, a pushed page keeps the system Back and its swipe, and earlier
// systems show plain bar buttons. The actions are peers, drawn alike (owner, build 76: "Confusing that only one is purple?").

/// One of a page's top-row actions.
struct ExplainAction {
    let identifier: String
    let hint: String
    let action: () -> Void
}

/// The round X that closes the sheet (iOS 26's close role; an xmark before it).
struct SheetCloseButton: View {
    let action: () -> Void
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
                .accessibilityIdentifier("sheet.close")
        } else {
            Button(action: action) { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                .accessibilityLabel("Close").accessibilityIdentifier("sheet.close")
        }
    }
}

extension View {
    /// The sheet's top row: **Snippet**, **Chat** and **AI Explainer** (each when offered) as words. `noun` names what is
    /// shown for VoiceOver ("Chat about Table"; build 76). `openChat`, on a pushed explainer, continues its conversation in
    /// Chat. `close` is how the sheet closes: VoiceOver's escape everywhere, and the X on the Mac only (build 78: no X on a
    /// touch screen, where the sheet swipes away); nil for a page whose sheet closes elsewhere.
    func sheetTopRow(snippet: ExplainAction? = nil, chat: ExplainAction? = nil, explainer: ExplainAction? = nil,
                     openChat: ExplainAction? = nil, noun: String = "Figure", close: (() -> Void)?) -> some View {
        modifier(SheetTopRowModifier(snippet: snippet, chat: chat, explainer: explainer, openChat: openChat, noun: noun, close: close))
    }
}

private struct SheetTopRowModifier: ViewModifier {
    let snippet: ExplainAction?
    let chat: ExplainAction?
    let explainer: ExplainAction?
    let openChat: ExplainAction?
    let noun: String
    let close: (() -> Void)?
    /// The X is the Mac's way to close a sheet, and Wide's in the paper's slot (ExplainPane); a touch-screen sheet swipes down.
    @Environment(\.coverPresentation) private var cover
    private var showsClose: Bool { close != nil && (Platform.isMac || cover) }

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { close?() }
            // In Wide's paper slot (ExplainPane) the page's own bar shows, as it does in a sheet.
            .navigationBarShownInCover(cover)
            .toolbar {
                // One item, not a group: iOS 26 moves bar buttons that don't fit into an overflow menu (both words
                // and the X went there in a half-height sheet); one view is laid out in the space it has.
                if snippet != nil || chat != nil || explainer != nil {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .principal) { actions.padding(.horizontal, showsClose ? 12 : 0) }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .principal) { actions.padding(.horizontal, showsClose ? 12 : 0) }
                    }
                }
                // Nothing on the right otherwise: no empty glass button there.
                if openChat != nil || showsClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            if let openChat {
                                Button(action: openChat.action) { Image(systemName: "bubble.left.and.text.bubble.right") }
                                    .accessibilityLabel("Open in Chat").accessibilityHint(openChat.hint).accessibilityIdentifier(openChat.identifier)
                            }
                            if showsClose, let close { SheetCloseButton(action: close) }
                        }
                    }
                }
            }
    }

    /// Words only (owner, build 78: "use txt"), the same size for all; a step smaller where the bar is narrow.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            row(font: .subheadline.weight(.semibold))
            row(font: .footnote.weight(.semibold))
        }
    }

    private func row(font: Font) -> some View {
        HStack(spacing: 8) {
            if let snippet {
                Button(action: snippet.action) { BarCapsule(title: "Snippet") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Snippet").accessibilityHint(snippet.hint).accessibilityIdentifier(snippet.identifier)
            }
            if let chat {
                Button(action: chat.action) { BarCapsule(title: "Chat") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chat about \(noun)").accessibilityHint(chat.hint).accessibilityIdentifier(chat.identifier)
            }
            if let explainer {
                Button(action: explainer.action) { BarCapsule(title: "AI Explainer") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("AI Explainer").accessibilityHint(explainer.hint).accessibilityIdentifier(explainer.identifier)
            }
        }
        .font(font)
        .fixedSize()
    }
}

/// A sheet's ⋯ (DESIGN.md "Screen options"): Report this screen, the last item as everywhere else (Catalogs).
struct SheetOptionsMenu: View {
    let report: () -> Void
    var body: some View {
        Menu {
            Section { MenuRow("Report this screen", systemImage: "ladybug", action: report) }
        } label: { Image(systemName: "ellipsis") }
            .accessibilityLabel("Options").accessibilityIdentifier("sheet.options")
    }
}

/// One action in the top row: a glass capsule (`ChromeSurface`) with accent words; all look the same.
private struct BarCapsule: View {
    let title: String

    var body: some View {
        Text(title).lineLimit(1)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .contentShape(Capsule())
            .foregroundStyle(Color.accentColor).modifier(ChromeSurface(shape: Capsule(), interactive: true))
    }
}

/// An explainer's heading: its figure or equation by name, a menu (⌄) of the paper's others to switch to (owner, build 62:
/// "a little thing you can expand to get to… all your equation listings").
struct ExplainerHeadingMenu<Item: Identifiable>: View {
    let title: String
    let items: [Item]
    let current: Item.ID
    let itemTitle: (Item) -> String
    let identifier: String
    let choose: (Item) -> Void

    var body: some View {
        if items.count < 2 {
            // Nothing to switch to: the name alone.
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier(identifier)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            ForEach(items) { item in
                Button { choose(item) } label: {
                    if item.id == current { Label(itemTitle(item), systemImage: "checkmark") } else { Text(itemTitle(item)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Image(systemName: "chevron.down").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Shows the paper’s others to switch to")
        .accessibilityIdentifier(identifier)
    }
}

// The Contents sheet's row (owner, build 62: "remove Done, use an X, use Liquid Glass tabs"): its tabs on the left, a
// round glass X on the right, a pushed page's round glass Back first; no centred title where the tabs already say where
// you are. It is drawn above the content rather than in a navigation bar.

struct SheetTopRow<Leading: View>: View {
    /// A pushed page's way back (nil on the sheet's first page).
    var back: (() -> Void)? = nil
    let close: () -> Void
    @ViewBuilder var leading: Leading
    /// In a Wide slot (Navigate's Contents) the row is the slot's share of the one top row: 52 pt, a hairline under it.
    @Environment(\.slotPane) private var slotPane

    var body: some View {
        if slotPane {
            row.padding(.horizontal, 12).frame(height: WideMetrics.barHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / UIScreen.main.scale) }
        } else {
            row.padding(.horizontal, DesignMetrics.margin).padding(.top, 14).padding(.bottom, 8)
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            if let back {
                Button(action: back) { HeaderButtonLabel(systemImage: "chevron.backward") }
                    .buttonStyle(.plain).accessibilityLabel("Back").accessibilityIdentifier("sheet.back")
            }
            leading.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) { HeaderButtonLabel(systemImage: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("sheet.close")
        }
    }
}

/// A pushed page's name in its top row, where nothing else says where you are (the tiles).
struct SheetRowTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
    }
}

/// Tabs in one glass capsule, as the reader's glass buttons (Chrome.swift): the chosen one on a quiet fill. Each tab is
/// a button named `<identifier>.<title, lowercased>`, selected when chosen.
struct GlassTabs<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    let identifier: String
    @Namespace private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let chosen = selection == option.value
                Button {
                    if reduceMotion { selection = option.value } else { withAnimation(.snappy(duration: 0.22)) { selection = option.value } }
                } label: {
                    // Each as wide as its name (equal widths squeezed "Equations" on a phone).
                    Text(option.title)
                        // One weight: a bolder chosen tab would widen and shift the others.
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: DesignMetrics.headerControl - 8)
                        .background {
                            if chosen { Capsule().fill(Color.primary.opacity(0.11)).matchedGeometryEffect(id: "chosen", in: space) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
                .accessibilityIdentifier("\(identifier).\(option.title.lowercased())")
            }
        }
        .padding(4)
        .frame(height: DesignMetrics.headerControl)
        .chromeSurface(Capsule(), interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

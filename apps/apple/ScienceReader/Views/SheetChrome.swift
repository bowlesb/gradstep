import SwiftUI

// An information sheet's top row (owner, build 62; docs/DESIGN.md "Sheet top row" and "Explain actions"): the page's
// actions on the left, a round X on the right, no centred title and no Done. It is the sheet's own navigation bar, so on
// iOS 26 its items are Liquid Glass (the prominent action tinted), a pushed page keeps the system Back and its swipe, and
// earlier systems show plain bar buttons.

/// One of a figure's or an equation's two explain actions.
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
    /// The sheet's top row: **Explain in Chat** and **AI Explainer** (each when offered) on the left, the X on the right
    /// (nil for a page whose sheet closes elsewhere). The bar shows no title.
    func sheetTopRow(chat: ExplainAction? = nil, explainer: ExplainAction? = nil, close: (() -> Void)?) -> some View {
        modifier(SheetTopRow(chat: chat, explainer: explainer, close: close))
    }
}

private struct SheetTopRow: ViewModifier {
    let chat: ExplainAction?
    let explainer: ExplainAction?
    let close: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // One item, not a group: iOS 26 moves bar buttons that don't fit into an overflow menu (both words
                // and the X went there in a half-height sheet); one view is laid out in the space it has.
                if chat != nil || explainer != nil {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .principal) { actions }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .principal) { actions }
                    }
                }
                if let close { ToolbarItem(placement: .topBarTrailing) { SheetCloseButton(action: close) } }
            }
    }

    /// Words always (owner: the two options by name), the same size for both: with the symbol where the bar has room,
    /// then without it, then a step smaller.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            row(symbol: true, font: .subheadline.weight(.semibold))
            row(symbol: false, font: .subheadline.weight(.semibold))
            row(symbol: false, font: .footnote.weight(.semibold))
        }
    }

    private func row(symbol: Bool, font: Font) -> some View {
        HStack(spacing: 8) {
            if let chat {
                Button(action: chat.action) {
                    BarCapsule(title: "Explain in Chat", symbol: symbol ? "bubble.left.and.text.bubble.right" : nil, prominent: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Explain in Chat").accessibilityHint(chat.hint).accessibilityIdentifier(chat.identifier)
            }
            if let explainer {
                Button(action: explainer.action) { BarCapsule(title: "AI Explainer", symbol: symbol ? "sparkles" : nil, prominent: true) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("AI Explainer").accessibilityHint(explainer.hint).accessibilityIdentifier(explainer.identifier)
            }
        }
        .font(font)
        .fixedSize()
    }
}

/// One action in the top row: a glass capsule (`ChromeSurface`), the main one tinted with the accent and white words.
private struct BarCapsule: View {
    let title: String
    let symbol: String?
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let label = HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(title).lineLimit(1)
        }
        .padding(.horizontal, 14).frame(minHeight: 36)
        .contentShape(Capsule())
        if prominent {
            label.foregroundStyle(.white).background(tinted)
        } else {
            label.foregroundStyle(Color.accentColor).modifier(ChromeSurface(shape: Capsule(), interactive: true))
        }
    }

    @ViewBuilder private var tinted: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            Capsule().fill(Color.clear).glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
        } else {
            Capsule().fill(Color.accentColor)
        }
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

import SwiftUI
import ScienceReaderCore

// One app, two shapes (owner, 2026-10-22; docs/DESIGN.md › Tall and Wide). The window's shape decides the layout, not
// the device:
// - Tall (iPhone, iPad upright, Split View halves, narrow windows) is the iPhone app exactly: the places capsule floats at
//   the bottom and one screen shows at a time.
// - Wide (iPad sideways; the Mac) puts the same places capsule in ONE top row, about 52 pt, shared by every pane on one
//   baseline with one hairline under it. Paper is the paper with its chat beside it; Chat is the general chat.
// Turning an iPad changes only where the capsule sits and whether the chat sits beside the paper.

enum WindowShape {
    /// The rule is `LayoutShape.of(size:)` (ScienceReaderCore), the window's size alone. The Mac's window stays Wide until
    /// its own step (its minimum width, 720, fits the panes it has today). Sizes are the whole window's, so a software
    /// keyboard (which shortens the safe area) never changes the shape.
    static func isWide(window size: CGSize) -> Bool {
        Platform.isMac || LayoutShape.of(size: size) == .wide
    }
}

enum WideMetrics {
    /// The Wide shape's one top row: 44 pt controls with 4 pt above and below.
    static let barHeight: CGFloat = 52
    /// The places capsule's height inside the row (its items are 36 pt inside 4 pt of glass).
    static let capsuleHeight: CGFloat = 44
}

private struct WideBarKey: EnvironmentKey { static let defaultValue = false }
private struct PlacesInBarKey: EnvironmentKey { static let defaultValue = false }
private struct LibrarySidebarKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The iPad's Wide shape: each pane draws its share of the one top row (`WideBar`) instead of a navigation bar or a
    /// header of its own. False on the Mac, whose window toolbar holds the places (MacSupport.swift).
    var wideBar: Bool {
        get { self[WideBarKey.self] }
        set { self[WideBarKey.self] = newValue }
    }
    /// This pane's share of the row holds the places capsule: the main pane (the paper beside its chat, Browse's paper).
    var placesInBar: Bool {
        get { self[PlacesInBarKey.self] }
        set { self[PlacesInBarKey.self] = newValue }
    }
    /// The Library as Browse's list beside the paper: its rows, never the full table (audit N8).
    var librarySidebar: Bool {
        get { self[LibrarySidebarKey.self] }
        set { self[LibrarySidebarKey.self] = newValue }
    }
}

/// The Wide two-slot container (owner, 2026-10-22; docs/DESIGN.md › Two slots). The left slot holds the "where to go"
/// list, the right slot the thing itself; Discuss (Paper | Chat) is the one exception, with the paper on the left. It owns
/// the slots' widths and the animated hand-offs between them; each pane draws its share of the one top row (`WideBar`,
/// all the same height, so the bars line up on one baseline with one continuous hairline). It knows nothing about
/// papers: the screens decide what goes in each slot.
///
/// The `main` view keeps one identity whichever side the other slot is on, so a paper keeps its load and its place
/// while it glides between Read (alone), Browse or Navigate (a list to its left) and Discuss (the chat to its right).
/// A screen that needs the whole width (the Library and Feed tables) is not in the container. In Tall the container
/// shows `main` alone: the iPhone's own navigation (tabs, pushes, Back) reaches the other slot's content.
struct TwoSlotLayout<Main: View, Other: View>: View {
    /// Where the other slot is: a list on the left, a companion on the right (Discuss), or none (the main view alone).
    enum Side: Hashable { case none, left, right }
    let width: CGFloat
    let other: Side
    /// Wide or Tall (LayoutShape); Tall shows `main` alone.
    var wide = true
    /// The main view's share of the width while the other slot is on its right (Discuss: the paper's 45%).
    var mainShareBesideRight: CGFloat = 0.45
    @ViewBuilder var main: Main
    @ViewBuilder var otherView: Other
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A list in the left slot: about 300–380 pt (at 900 pt a 300 pt list leaves the paper 600).
    static func listWidth(for width: CGFloat) -> CGFloat { min(380, max(300, (width * 0.28).rounded())) }

    var body: some View {
        let side = wide ? other : .none
        HStack(spacing: 0) {
            if side == .left {
                otherView.frame(width: Self.listWidth(for: width))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            main
                .frame(width: side == .right ? (width * mainShareBesideRight).rounded() : nil)
                .frame(maxWidth: side == .right ? nil : .infinity)
            if side == .right {
                Divider()
                otherView.frame(maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: side)
    }
}

/// A pane's share of the Wide shape's one top row. Its grammar is the iPhone's: at most one "where to go" button on the
/// left, the places capsule (or the chat's title) centred over the pane, then a create button where creating is the
/// screen's job and ⋯ last. The row shares the page's background and ends in a hairline; every pane's row has the same
/// height, so side-by-side panes line up on one baseline with one continuous hairline.
struct WideBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        WideBarLayout {
            HStack(spacing: 8) { leading }
            ZStack { center }
            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: WideMetrics.barHeight)
        .background { Color.chromeBackground.ignoresSafeArea(.container, edges: .top) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / UIScreen.main.scale).accessibilityHidden(true)
        }
        // The row keeps its size at large text sizes (as the iPhone's bars do); the content below grows.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
    }
}

extension WideBar where Leading == EmptyView {
    init(@ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, center: center, trailing: trailing)
    }
}

/// Three slots on one centre line: the middle one centred over the pane when it can be, the leading one taking (and
/// truncating to) what is left before it, the trailing one at its ideal size at the far edge.
struct WideBarLayout: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 600, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0], center = subviews[1], trailing = subviews[2]
        let width = bounds.width, height = bounds.height
        let trailingSize = trailing.sizeThatFits(ProposedViewSize(width: nil, height: height))
        let leadingIdeal = leading.sizeThatFits(ProposedViewSize(width: nil, height: height))
        // The leading slot's least useful width: its buttons, never less than the trailing ones (so the centre is centred).
        let leadingMinimum = min(leadingIdeal.width, leading.sizeThatFits(ProposedViewSize(width: 0, height: height)).width)
        let side = max(leadingMinimum, trailingSize.width)
        let centerRoom = max(0, width - 2 * side - 2 * spacing)
        let centerSize = center.sizeThatFits(ProposedViewSize(width: centerRoom > 0 ? centerRoom : width - trailingSize.width - spacing,
                                                              height: height))
        var centerX = bounds.minX + (width - centerSize.width) / 2
        // Off-centre only when it must be: clear of the trailing items, then of the leading items' minimum.
        centerX = min(centerX, bounds.maxX - trailingSize.width - (trailingSize.width > 0 ? spacing : 0) - centerSize.width)
        centerX = max(centerX, bounds.minX + leadingMinimum + (leadingMinimum > 0 ? spacing : 0))
        let midY = bounds.midY
        center.place(at: CGPoint(x: centerX, y: midY), anchor: .leading, proposal: ProposedViewSize(width: centerSize.width, height: height))
        trailing.place(at: CGPoint(x: bounds.maxX, y: midY), anchor: .trailing, proposal: ProposedViewSize(width: trailingSize.width, height: height))
        // The leading slot is offered all the room before the centre (a field fills it; buttons keep their size).
        let leadingEnd = centerSize.width > 0 ? centerX - spacing : bounds.maxX - trailingSize.width - (trailingSize.width > 0 ? spacing : 0)
        leading.place(at: CGPoint(x: bounds.minX, y: midY), anchor: .leading,
                      proposal: ProposedViewSize(width: max(0, leadingEnd - bounds.minX), height: height))
    }
}

/// The places capsule in the Wide row: Feed · Library · Paper · Chat · Snippets, then Search (owner, 2026-10-22: "Search is
/// the places capsule's last item"; it opens the library's list beside the paper, `ReaderModel.searchFromPlaces`). The
/// same glass, symbols and selection as the iPhone's bottom capsule, laid out in a row; symbols alone when the pane is
/// too narrow for the names. Each place keeps its `tab.*` identifier.
struct WidePlacesCapsule: View {
    @Bindable var model: ReaderModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            capsule(labels: true)
            capsule(labels: false)
        }
    }

    private func capsule(labels: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(ReaderTab.phoneTabs) { place in
                let selected = model.widePlace == place && model.tab != .settings
                let unavailable = place == .paper && model.selectedPaper == nil
                Button { model.showPlace(place) } label: { WidePlaceItem(place: place, selected: selected, label: labels) }
                    .buttonStyle(.plain)
                    .disabled(unavailable)
                    .opacity(unavailable ? 0.35 : 1)
                    .hoverEffect(.highlight)
                    .accessibilityLabel(place.rawValue)
                    .accessibilityIdentifier("tab.\(String(describing: place))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityShowsLargeContentViewer { Label(place.rawValue, image: place.icon) }
            }
            Button { model.searchFromPlaces() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.primary)
                    .frame(width: 40, height: WideMetrics.capsuleHeight - 8).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("tab.search")
        }
        .padding(4)
        .frame(height: WideMetrics.capsuleHeight)
        .fixedSize()
        .chromeSurface(Capsule(), interactive: true)
    }
}

/// One place in the Wide capsule: the iPhone tab's symbol and name side by side.
struct WidePlaceItem: View {
    let place: ReaderTab
    let selected: Bool
    var label = true
    var body: some View {
        HStack(spacing: 6) {
            Image(place.icon)
                .symbolRenderingMode(selected ? .palette : .monochrome)
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary), Color.gradstepAmber)
                .font(.system(size: 17, weight: .medium))
                .accessibilityHidden(true)
            if label {
                Text(place.rawValue).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
        }
        .padding(.horizontal, label ? 12 : 10)
        .frame(height: WideMetrics.capsuleHeight - 8)
        .background { if selected { Capsule().fill(Color.accentColor.opacity(0.14)) } }
        .contentShape(Capsule())
    }
}

/// A search field in a Wide row (the Library's, the Snippets', the library panel's): the iPhone header's glass capsule.
struct WideSearchField<Field: View>: View {
    @ViewBuilder var field: Field
    var body: some View {
        field
            .padding(.leading, 10).padding(.trailing, 6).frame(height: DesignMetrics.headerControl)
            .chromeSurface(Capsule())
    }
}

// MARK: - Explainers over the whole paper

private struct CoverPresentationKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A page shown in the paper's slot in Wide (ExplainPane): it has no swipe to close, so its top row shows the X.
    var coverPresentation: Bool {
        get { self[CoverPresentationKey.self] }
        set { self[CoverPresentationKey.self] = newValue }
    }
}

/// Explain (owner, 2026-10-22, "Two slots, a few views"): in Wide the figure page, the equation view and the AI
/// Explainers take the paper's slot, under its share of the top row, laid out as on the iPhone in a centred column. The
/// paper stays loaded beneath, so ✕ returns to it at the same place; the left slot is unchanged.
struct ExplainPane<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .environment(\.coverPresentation, true)
            .frame(maxWidth: DesignMetrics.column + 2 * DesignMetrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea(.container, edges: .bottom))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explain.pane")
            // The paper's share of the top row stays in view and usable above the explainer.
            .padding(.top, WideMetrics.barHeight)
    }
}

/// Wide: the explainer over the paper's slot (ExplainPane); its closing runs `onDismiss`, as a sheet's does.
private struct ExplainerOverlay<Page: View>: ViewModifier {
    let shown: Bool
    let onDismiss: (() -> Void)?
    @ViewBuilder let page: () -> Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if shown { ExplainPane { page() }.transition(.opacity.combined(with: .move(edge: .trailing))) }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: shown)
            .onChange(of: shown) { was, now in if was && !now { onDismiss?() } }
    }
}

extension View {
    /// A sheet in Tall, exactly as on iPhone; in Wide the paper's slot (ExplainPane).
    func explainerPresentation<Item: Identifiable, Page: View>(item: Binding<Item?>, wide: Bool, onDismiss: (() -> Void)? = nil,
                                                              @ViewBuilder content: @escaping (Item) -> Page) -> some View {
        self.sheet(item: wide ? .constant(nil) : item, onDismiss: onDismiss, content: content)
            .modifier(ExplainerOverlay(shown: wide && item.wrappedValue != nil, onDismiss: onDismiss) {
                if let value = item.wrappedValue { content(value) }
            })
    }

    func explainerPresentation<Page: View>(isPresented: Binding<Bool>, wide: Bool, onDismiss: (() -> Void)? = nil,
                                           @ViewBuilder content: @escaping () -> Page) -> some View {
        self.sheet(isPresented: wide ? .constant(false) : isPresented, onDismiss: onDismiss, content: content)
            .modifier(ExplainerOverlay(shown: wide && isPresented.wrappedValue, onDismiss: onDismiss, page: content))
    }

    /// Wide: the pane's share of the one top row replaces its navigation bar. Tall is left exactly as it was.
    @ViewBuilder func navigationBarHiddenInWide(_ wide: Bool) -> some View {
        if wide { toolbar(.hidden, for: .navigationBar) } else { self }
    }

    /// A page in Wide's paper slot (ExplainPane) keeps its own bar, as it has in a sheet.
    @ViewBuilder func navigationBarShownInCover(_ cover: Bool) -> some View {
        if cover { toolbar(.visible, for: .navigationBar) } else { self }
    }
}

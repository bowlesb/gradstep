import SwiftUI
import ScienceReaderCore

// One app, two shapes (owner, 2026-10-22; docs/DESIGN.md › Tall and Wide). The window's shape decides the layout, not
// the device:
// - Tall (iPhone, iPad upright, Split View halves, narrow windows) is the iPhone app exactly: the places capsule floats at
//   the bottom and one screen shows at a time.
// - Wide (iPad sideways; the Mac) gives each place its own two slots, the place's list on the left and what was picked
//   from it on the right (owner, 2026-10-23). The places are a menu in the window's top-left corner (`PlacesMenuButton`;
//   owner correction, 2026-10-23: "I meant the top left"), before the leftmost slot's controls; navigation never adds a
//   row of its own.
// Turning an iPad changes only where the places are and whether a second slot shows.

enum WindowShape {
    /// The rule is `LayoutShape.of(size:)` (ScienceReaderCore), the window's size alone. The Mac's window stays Wide until
    /// its own step (its minimum width, 720, fits the panes it has today). Sizes are the whole window's, so a software
    /// keyboard (which shortens the safe area) never changes the shape.
    static func isWide(window size: CGSize) -> Bool {
        Platform.isMac || LayoutShape.of(size: size) == .wide
    }
}

enum WideMetrics {
    /// A Wide row, where a slot has one: 44 pt controls with 4 pt above and below. Floating controls share its centre line.
    static let barHeight: CGFloat = 52
    /// The room the places button (the window's top-left corner, `PlacesMenuButton`) takes at the start of the leftmost
    /// slot's row or floating controls: its 44 pt circle and 8 pt after it.
    static let placesReserve: CGFloat = 52
}

private struct WideBarKey: EnvironmentKey { static let defaultValue = false }
private struct PlacesLeadingReserveKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct LibrarySidebarKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The iPad's Wide shape: each pane draws its own row (`WideBar`) or floats its controls instead of a navigation bar
    /// or a header of its own. False on the Mac, whose window toolbar holds the places (MacSupport.swift).
    var wideBar: Bool {
        get { self[WideBarKey.self] }
        set { self[WideBarKey.self] = newValue }
    }
    /// The room left free at the leading end of this slot's row (or its floating controls) for the places button, which
    /// sits in the window's top-left corner: `WideMetrics.placesReserve` in the leftmost slot (or a slot covering the
    /// window), 0 elsewhere (`TwoSlotLayout` hands it to whichever slot is on the left).
    var placesLeadingReserve: CGFloat {
        get { self[PlacesLeadingReserveKey.self] }
        set { self[PlacesLeadingReserveKey.self] = newValue }
    }
    /// The Mac's Library beside the paper: its rows, never the full table (audit N8).
    var librarySidebar: Bool {
        get { self[LibrarySidebarKey.self] }
        set { self[LibrarySidebarKey.self] = newValue }
    }
}

// MARK: - Two slots

/// Each place's own two-slot arrangement (owner, 2026-10-23: "custom two panel behavior for each of the 5 functionality
/// areas"). Its divider's position is kept per arrangement on this device as a fraction of the width, so turning the
/// iPad or resizing a window keeps the proportions.
enum SlotArrangement: String, CaseIterable {
    /// Library list | paper. Feed list | abstract or paper. All chats | conversation. Collections | collection.
    case library, feed, chats, snippets
    /// Contents | paper (Navigate, ☰).
    case contents
    /// Paper | its companion: AI Explainer, the equation view, a figure page or the chat (Discuss).
    case companion

    /// The left slot's share of the width to start with: half. One panel splitting into two breaks apart in the middle
    /// (owner, 2026-10-23); a dragged divider is kept, and VoiceOver's Reset returns it here.
    var defaultFraction: CGFloat { 0.5 }
    /// The narrowest each slot may be: a list 280 pt (Contents' four tabs and ✕ need 420), the paper 420 pt, a companion
    /// or a conversation 320 pt.
    var minimums: (left: CGFloat, right: CGFloat) {
        switch self {
        case .library, .feed: (280, 420)
        case .chats, .snippets: (280, 320)
        case .contents: (420, 420)
        case .companion: (420, 320)
        }
    }
    /// For VoiceOver: what the divider sizes.
    var title: String {
        switch self {
        case .library: "Library and paper"
        case .feed: "Feed and details"
        case .chats: "Chats and conversation"
        case .snippets: "Collections and collection"
        case .contents: "Contents and paper"
        case .companion: "Paper and companion"
        }
    }
    /// For the grabber of a slot covering the window: what comes back beside it.
    var coveredTitle: String {
        switch self {
        case .library, .contents, .companion: "the paper"
        case .feed: "the details"
        case .chats: "the conversation"
        case .snippets: "the collection"
        }
    }
}

/// Where each arrangement's divider is, kept on this device (UserDefaults `wide.divider.<arrangement>`).
@MainActor @Observable final class SlotFractions {
    static let shared = SlotFractions()
    private var values: [SlotArrangement: CGFloat] = [:]
    /// Arrangements whose list (or companion) covers the whole window after a double tap on the divider, as on iPhone
    /// (owner, 2026-10-23). For this run only: picking something from the list splits the slots again.
    private(set) var covering: Set<SlotArrangement> = []

    private init() {
        for arrangement in SlotArrangement.allCases {
            if let value = UserDefaults.standard.object(forKey: Self.key(arrangement)) as? Double { values[arrangement] = value }
        }
    }

    private static func key(_ arrangement: SlotArrangement) -> String { "wide.divider.\(arrangement.rawValue)" }

    func fraction(_ arrangement: SlotArrangement) -> CGFloat { values[arrangement] ?? arrangement.defaultFraction }

    /// A new position, or nil for the default (VoiceOver's Reset).
    func set(_ fraction: CGFloat?, for arrangement: SlotArrangement) {
        values[arrangement] = fraction
        if let fraction { UserDefaults.standard.set(Double(fraction), forKey: Self.key(arrangement)) }
        else { UserDefaults.standard.removeObject(forKey: Self.key(arrangement)) }
    }

    /// The double tap: the other slot covers the whole window, or (when it already does) the two slots return.
    func toggleCovering(_ arrangement: SlotArrangement) {
        if covering.contains(arrangement) { covering.remove(arrangement) } else { covering.insert(arrangement) }
    }

    /// Something was picked from a list: it shows beside the list again.
    func uncover(_ arrangement: SlotArrangement? = nil) {
        if let arrangement { covering.remove(arrangement) } else if !covering.isEmpty { covering = [] }
    }

    /// Tests and visual checks start from the defaults.
    func reset() { for arrangement in SlotArrangement.allCases { set(nil, for: arrangement) }; covering = [] }
}

/// The Wide two-slot container (owner, 2026-10-22; docs/DESIGN.md › Tall and Wide). Each place owns one arrangement
/// (owner, 2026-10-23): the left slot is the place itself (its list), the right slot what was picked from it; the paper's
/// helpers sit on its right (Paper | companion). It owns the slots' widths, the draggable divider between them and the
/// animated hand-offs; each pane draws its own row or floats its few controls. It knows nothing about papers: the
/// screens decide what goes in each slot.
///
/// The `main` view keeps one identity whichever side the other slot is on, so a paper keeps its load and its place
/// while it glides between the Library's right slot, the Paper place alone and Paper | companion. In Tall the container
/// shows `main` alone: the iPhone's own navigation (tabs, pushes, Back) reaches the other slot's content.
struct TwoSlotLayout<Main: View, Other: View>: View {
    /// Where the other slot is: a list on the left, a companion on the right, or none (the main view alone).
    enum Side: Hashable { case none, left, right }
    let width: CGFloat
    let other: Side
    /// Whose divider this is (its position is kept per arrangement).
    let arrangement: SlotArrangement
    /// Wide or Tall (LayoutShape); Tall shows `main` alone.
    var wide = true
    /// Dragging the divider past the other slot's minimum: the list collapses (the paper becomes the Paper place) or the
    /// companion closes. Nil: the divider stops at the minimum.
    var collapse: (() -> Void)? = nil
    /// What the list has picked (a paper, a conversation, a collection, a feed article): when it changes, a list covering
    /// the window gives the picked thing its slot again.
    var selection: AnyHashable? = nil
    @ViewBuilder var main: Main
    @ViewBuilder var otherView: Other
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The room the places button needs at the leading end of the leftmost slot's row (`placesLeadingReserve`).
    @Environment(\.placesLeadingReserve) private var placesReserve
    /// While dragging: the left slot's width under the finger (unclamped; the slots clamp it), and where it began.
    @State private var dragLeft: CGFloat?
    @State private var dragStart: CGFloat?

    /// How far past the other slot's minimum a drag must end to close it; short of that the divider stops at the minimum.
    static var collapseSlack: CGFloat { 40 }

    /// The left slot's width for an arrangement, a divider position and a window width.
    static func leftWidth(_ arrangement: SlotArrangement, fraction: CGFloat, width: CGFloat) -> CGFloat {
        clamped(arrangement, (fraction * width).rounded(), width: width)
    }

    /// A left width kept within both slots' minimums.
    static func clamped(_ arrangement: SlotArrangement, _ left: CGFloat, width: CGFloat) -> CGFloat {
        let minimums = arrangement.minimums
        return min(max(minimums.left, width - minimums.right), max(minimums.left, left))
    }

    private var storedLeft: CGFloat { Self.leftWidth(arrangement, fraction: SlotFractions.shared.fraction(arrangement), width: width) }

    var body: some View {
        let side = wide ? other : .none
        // A real drag (owner, 2026-10-23: "that doesn't feel like a real drag"): both slots follow the finger on every
        // frame, each stopping at its minimum; past the other slot's minimum (and `collapseSlack`) that slot dims, and
        // letting go closes it.
        let left = dragLeft.map { Self.clamped(arrangement, $0, width: width) } ?? storedLeft
        let closing = dragLeft.map { landing($0, side: side).closes } ?? false
        // Double tap on the divider: the list (or the companion) covers the whole window, as on iPhone (owner, 2026-10-23);
        // the main view stays loaded beneath it, at its place, and a grabber at the far edge brings the two slots back.
        let covering = side != .none && SlotFractions.shared.covering.contains(arrangement)
        // The places button is in the window's top-left corner (owner, 2026-10-23): the leftmost slot's row leaves room.
        let mainLeads = side != .left && !covering
        HStack(spacing: 0) {
            // The list's slot and the divider's hairline: both are drawn above, so the list can cover the window.
            if side == .left { Color.clear.frame(width: left + 1).accessibilityHidden(true) }
            main
                .frame(width: side == .right ? left : nil)
                .frame(maxWidth: side == .right ? nil : .infinity)
                .environment(\.placesLeadingReserve, mainLeads ? placesReserve : 0)
                // Covered: still loaded at its place, but neither seen, read by VoiceOver nor touched. (Its UIKit-hosted
                // parts, a NavigationStack's pages, don't take SwiftUI's hiding: the covering slot is modal as well.)
                .opacity(covering ? 0 : 1)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(covering)
                .allowsHitTesting(!covering)
                .accessibilitySortPriority(side == .left ? 0 : 2)
            // The divider's hairline and the companion's slot (flexible: a container measuring its own width, as the
            // explainer's does, must be free to grow with the window).
            if side == .right { Color.clear.frame(minWidth: 1, maxWidth: .infinity).accessibilityHidden(true) }
        }
        .overlay(alignment: side == .right ? .trailing : .leading) {
            if side != .none {
                otherView
                    .frame(width: covering ? width : (side == .left ? left : max(0, width - left - 1)))
                    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                    .opacity(closing ? 0.5 : 1)
                    .environment(\.placesLeadingReserve, mainLeads ? 0 : placesReserve)
                    .overlay(alignment: side == .left ? .trailing : .leading) { if covering { uncoverGrabber(side: side) } }
                    .accessibilityElement(children: .contain)
                    // Covering the window, it is all VoiceOver reads of the two slots (the places menu, outside them, stays).
                    .accessibilityAddTraits(covering ? .isModal : [])
                    // VoiceOver reads the slots left to right: the list, the divider, then what was picked.
                    .accessibilitySortPriority(side == .left ? 2 : 0)
                    .transition(.move(edge: side == .left ? .leading : .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .leading) {
            if side != .none && !covering {
                HStack(spacing: 0) { divider(left: left, side: side) }
                    .padding(.leading, left)
                    .accessibilitySortPriority(1)
            }
        }
        .accessibilityElement(children: .contain)
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: side)
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: covering)
        .onChange(of: selection) { SlotFractions.shared.uncover(arrangement) }
    }

    /// While a slot covers the window: a small glass handle at its far edge, its chevron pointing where the other slot
    /// comes back from; a tap or a drag inward brings the two slots back. Quiet (secondary, half the divider's grabber
    /// height again), but always there.
    private func uncoverGrabber(side: Side) -> some View {
        ZStack {
            Color.clear.frame(width: 32).contentShape(Rectangle())
            Image(systemName: side == .left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 20, height: 56)
                .chromeSurface(Capsule())
                .hoverEffect(.highlight)
        }
        .frame(height: 120)
        .padding(.horizontal, 2)
        .onTapGesture { SlotFractions.shared.uncover(arrangement) }
        .gesture(DragGesture(minimumDistance: 8).onEnded { value in
            if (side == .left && value.translation.width < -20) || (side == .right && value.translation.width > 20) {
                SlotFractions.shared.uncover(arrangement)
            }
        })
        .help("Show \(arrangement.coveredTitle) beside")
        .accessibilityElement()
        .accessibilityLabel("Show \(arrangement.coveredTitle) beside")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { SlotFractions.shared.uncover(arrangement) }
        .accessibilityIdentifier("slots.uncover")
    }

    /// A drag ending with the left slot `proposed` wide: where the divider goes, or that the other slot closes.
    private func landing(_ proposed: CGFloat, side: Side) -> (x: CGFloat, closes: Bool) {
        let minimums = arrangement.minimums
        if collapse != nil {
            if side == .left, proposed < minimums.left - Self.collapseSlack { return (0, true) }
            if side == .right, proposed > width - minimums.right + Self.collapseSlack { return (width, true) }
        }
        return (Self.clamped(arrangement, proposed, width: width), false)
    }

    /// The hairline between the slots, with a 24 pt area to drag and a grabber in the middle (as the Mac Reader's,
    /// ReaderSplit): drag to resize (the slots follow the finger), double-tap to let the list cover the window as on
    /// iPhone; VoiceOver adjusts it in steps of 5%, can reset it to the middle, and has the covering as an action.
    private func divider(left: CGFloat, side: Side) -> some View {
        let fractions = SlotFractions.shared
        let percent = Int((left / max(width, 1) * 100).rounded())
        return Divider()
            .overlay {
                ZStack {
                    Color.clear.frame(width: 24).contentShape(Rectangle())
                    Capsule().fill(Color(uiColor: .tertiaryLabel)).frame(width: 5, height: 44)
                        .background(Capsule().fill(Color(uiColor: .systemBackground)).padding(-3))
                        .hoverEffect(.highlight)
                }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        // Measured from where the drag began, not from the slots as they are now (they follow it).
                        let start = dragStart ?? left
                        if dragStart == nil { dragStart = left }
                        dragLeft = start + value.translation.width
                    }
                    .onEnded { value in
                        let end = landing((dragStart ?? left) + value.translation.width, side: side)
                        // One transaction: the kept fraction takes over from the live width, with no motion.
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            if !end.closes { fractions.set(end.x / max(width, 1), for: arrangement) }
                            dragLeft = nil; dragStart = nil
                        }
                        if end.closes { collapse?() }
                    })
                // As on iPhone: the list over the whole window (owner, 2026-10-23); the grabber at its edge brings it back.
                .onTapGesture(count: 2) { fractions.toggleCovering(arrangement) }
                .accessibilityElement()
                .accessibilityLabel("\(arrangement.title) divider")
                .accessibilityValue("\(percent) percent on the left")
                .accessibilityHint("Swipe up or down to move it")
                .accessibilityAdjustableAction { direction in
                    let step = width * (direction == .increment ? 0.05 : -0.05)
                    fractions.set(landing(left + step, side: side).x / max(width, 1), for: arrangement)
                }
                .accessibilityAction(named: "Reset") { fractions.set(nil, for: arrangement) }
                .accessibilityAction(named: side == .left ? "Cover the window with the list" : "Cover the window") {
                    fractions.toggleCovering(arrangement)
                }
                .accessibilityIdentifier("slots.divider")
            }
    }
}

/// A slot's row in the Wide shape, only where the slot has controls of its own (owner, 2026-10-23: navigation "never
/// costs vertical space"). Its grammar is the iPhone's: a field or at most one "where to go" button on the left, the
/// chat's title in the centre, then a create button where creating is the screen's job and ⋯ last. In the leftmost slot
/// it starts `placesLeadingReserve` in from the edge, after the places button in the window's top-left corner (owner,
/// 2026-10-23). The row shares the page's background and ends in a hairline; every row has the same height, so
/// side-by-side rows line up on one centre line.
struct WideBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing
    @Environment(\.placesLeadingReserve) private var placesReserve

    var body: some View {
        WideBarLayout {
            HStack(spacing: 8) { leading }
            ZStack { center }
            HStack(spacing: 8) { trailing }
        }
        .padding(.leading, 12 + placesReserve).padding(.trailing, 12)
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

extension WideBar where Center == EmptyView {
    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: leading, center: { EmptyView() }, trailing: trailing)
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

// MARK: - Places

/// The places menu (owner, 2026-10-23: "put them in a menu in the right hand side, which is conceptually similar to the
/// ... menu"; it replaced the places capsule in the Wide row). One 44 pt glass circle in the window's top-left corner
/// (owner correction, 2026-10-23: "I thought I asked for an icon in the top left… I meant the top left"), the same spot in
/// every view, a list covering the window included, showing the current place's own symbol in accent, so it also says where you are. Its
/// rows: Feed, Library, Paper, Chat, Snippets (the current one checked; Paper needs a paper), then Search. ⌘1…⌘5 choose
/// the places with a hardware keyboard. Each row keeps its `tab.*` identifier.
struct PlacesMenuButton: View {
    @Bindable var model: ReaderModel

    var body: some View {
        let current = model.widePlace
        Menu {
            Section {
                ForEach(ReaderTab.phoneTabs) { place in
                    Toggle(isOn: Binding(get: { model.widePlace == place }, set: { _ in model.showPlace(place) })) {
                        Label { Text(place.rawValue) } icon: { menuIcon(place.icon) }
                    }
                    .disabled(place == .paper && model.selectedPaper == nil)
                    .accessibilityIdentifier("tab.\(String(describing: place))")
                }
            }
            Section {
                // Search (owner, 2026-10-22: "search lives at the top of the left panel, like Mail"): the Library place
                // with its field focused.
                MenuRow("Search", systemImage: "magnifyingglass") { model.searchFromPlaces() }.accessibilityIdentifier("tab.search")
            }
        } label: {
            Image(current.icon)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.accentColor, Color.gradstepAmber)
                .font(.system(size: 19, weight: .medium))
                .frame(width: DesignMetrics.headerControl, height: DesignMetrics.headerControl).modifier(GlassCircle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Places, \(current.rawValue)")
        .accessibilityIdentifier("places.menu")
        .accessibilityShowsLargeContentViewer { Label(current.rawValue, image: current.icon) }
        .background { shortcuts }
    }

    /// ⌘1…⌘5: the places in the menu's order (the Mac's View menu binds the same keys there; this button is iPad only).
    private var shortcuts: some View {
        ForEach(Array(ReaderTab.phoneTabs.enumerated()), id: \.offset) { index, place in
            Button(place.rawValue) { model.showPlace(place) }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(place == .paper && model.selectedPaper == nil)
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A search field in a Wide row (the Library's, the Snippets'): the iPhone header's glass capsule.
struct WideSearchField<Field: View>: View {
    @ViewBuilder var field: Field
    var body: some View {
        field
            .padding(.leading, 10).padding(.trailing, 6).frame(height: DesignMetrics.headerControl)
            .chromeSurface(Capsule())
    }
}

// MARK: - Turning upright

/// Turning an iPad from Wide to Tall with a paper beside the Library, or an article picked in the Feed (owner, 2026-10-23:
/// "make sure that the paper we were just reading appears in the middle of the list, and it's initially highlighted";
/// "and then it dims, similar to the way the Figure outline dims in the AI Figure Explainer"): the Tall list centres that
/// row and tints it, and the tint fades away on its own (`RevealTint`). A row not in the list (filtered out, searched
/// past) gets nothing.
struct RowReveal: Equatable {
    let place: ReaderTab
    /// The list row's id: a Library entry's (`LibraryListEntry.id`), a Feed article's source ID.
    let rowID: String
    let token = UUID()

    /// Full strength for the turn's own animation (about half a second), then the figure outline's 0.4 s wait.
    static var delay: TimeInterval { 0.9 * slow }
    /// The figure outline's fade (`FigureFullscreenStage.fadeDuration`).
    static var duration: TimeInterval { FigureFullscreenStage.fadeDuration * slow }

    /// Fixture builds may slow it down to photograph and test it (`--row-reveal-slow=<factor>`).
    private static var slow: Double {
        #if DEBUG && FIXTURE_HOST
        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--row-reveal-slow=") })
            .flatMap({ Double($0.dropFirst("--row-reveal-slow=".count)) }) {
            return min(60, max(1, value))
        }
        #endif
        return 1
    }
}

/// A table's revealed row (PaperTable): which row, its reveal, and how to end it once the tint has gone.
struct TableReveal<ID: Hashable> {
    let row: ID
    let reveal: RowReveal
    let end: () -> Void
}

extension ReaderModel {
    /// The Tall list's revealed row for `place` (nil in Wide, where the open paper shows beside the list).
    func revealedRow(in place: ReaderTab, wide: Bool) -> TableReveal<String>? {
        guard !wide, let reveal = rowReveal, reveal.place == place else { return nil }
        return TableReveal(row: reveal.rowID, reveal: reveal) { [weak self] in
            if self?.rowReveal == reveal { self?.rowReveal = nil }
        }
    }
}

/// The revealed row's tint, the Feed's picked-row look (accent at 12%): full, then after `RowReveal.delay` it fades with
/// ease-in over `RowReveal.duration`, as the figure outline does (`FigureFullscreenStage`); with Reduce Motion it stays as
/// long, then goes at once. Then the reveal ends, and the row is no longer marked selected.
struct RevealTint: View {
    let reveal: RowReveal
    let end: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var strength = 1.0

    var body: some View {
        Color.accentColor.opacity(0.12 * strength)
            .task(id: reveal.token) {
                strength = 1
                try? await Task.sleep(for: .seconds(RowReveal.delay))
                if reduceMotion { try? await Task.sleep(for: .seconds(RowReveal.duration)); strength = 0 }
                else {
                    withAnimation(.easeIn(duration: RowReveal.duration)) { strength = 0 }
                    try? await Task.sleep(for: .seconds(RowReveal.duration))
                }
                if !Task.isCancelled { end() }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// The Tall list scrolls the revealed row to its middle as it appears, and again once the turn has settled.
    func revealScroll<ID: Hashable>(_ row: ID?, token: UUID?, proxy: ScrollViewProxy) -> some View {
        task(id: token) {
            guard let row else { return }
            proxy.scrollTo(row, anchor: .center)
            try? await Task.sleep(for: .seconds(0.45))
            proxy.scrollTo(row, anchor: .center)
        }
    }
}

// MARK: - Shared frames between slots

/// The hand-off between slots that keeps the content's identity on screen (owner, 2026-10-22: the explainer turns into the
/// chat "with a smooth transition with the same content").
enum WideSlotTransition {
    static let explainerToChat = "explainer-to-chat"
}

private struct SlotNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

extension EnvironmentValues {
    /// The Wide slots' shared namespace (WideSlots): views that hand a slot to each other match their frames in it.
    var slotNamespace: Namespace.ID? {
        get { self[SlotNamespaceKey.self] }
        set { self[SlotNamespaceKey.self] = newValue }
    }
}

/// One frame shared by the view leaving a slot and the one arriving (matchedGeometryEffect); nothing outside the slots.
struct SharedSlotFrame: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: id, in: namespace, properties: .frame, anchor: .topTrailing) }
        else { content }
    }
}

// MARK: - The paper's companions

private struct CoverPresentationKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A page shown in the paper's companion slot in Wide (ExplainPane): it has no swipe to close, so its top row shows
    /// the X.
    var coverPresentation: Bool {
        get { self[CoverPresentationKey.self] }
        set { self[CoverPresentationKey.self] = newValue }
    }
}

/// A companion (owner, 2026-10-23: "When Paper is a left primary item, the AI explainer and equation explainer can go on
/// the right"): in Wide the figure page, the equation view and the AI Explainers open in the slot on the paper's right,
/// laid out as on the iPhone, with ✕ and a draggable divider. The paper stays beside them at the same place.
struct ExplainPane<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.slotNamespace) private var slots
    var body: some View {
        content
            .environment(\.coverPresentation, true)
            .frame(maxWidth: DesignMetrics.column + 2 * DesignMetrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea(.container, edges: .bottom))
            // Continue in Chat: the explainer's slot becomes the chat's (WideSlots), one shared frame moving.
            .modifier(SharedSlotFrame(id: WideSlotTransition.explainerToChat, namespace: slots))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explain.pane")
    }
}

/// Wide: the explainer in the companion slot beside the paper (ExplainPane); closing it (✕, or dragging the divider past
/// its minimum) runs `onDismiss`, as a sheet's does. `opened` runs as it appears, so the paper becomes the Paper place.
private struct ExplainerCompanion<Page: View>: ViewModifier {
    let shown: Bool
    let close: () -> Void
    let onDismiss: (() -> Void)?
    let opened: (() -> Void)?
    @ViewBuilder let page: () -> Page
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        TwoSlotLayout(width: width, other: shown ? .right : .none, arrangement: .companion, collapse: close) {
            content
        } otherView: {
            ExplainPane { page() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: shown) { was, now in
            if was && !now { onDismiss?() }
            if now && !was { opened?() }
        }
    }
}

extension View {
    /// A sheet in Tall, exactly as on iPhone; in Wide the companion slot beside the paper (ExplainPane).
    func explainerPresentation<Item: Identifiable, Page: View>(item: Binding<Item?>, wide: Bool, opened: (() -> Void)? = nil,
                                                              onDismiss: (() -> Void)? = nil,
                                                              @ViewBuilder content: @escaping (Item) -> Page) -> some View {
        self.sheet(item: wide ? .constant(nil) : item, onDismiss: onDismiss, content: content)
            .modifier(ExplainerCompanion(shown: wide && item.wrappedValue != nil, close: { item.wrappedValue = nil },
                                         onDismiss: onDismiss, opened: opened) {
                if let value = item.wrappedValue { content(value) }
            })
    }

    func explainerPresentation<Page: View>(isPresented: Binding<Bool>, wide: Bool, opened: (() -> Void)? = nil,
                                           onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Page) -> some View {
        self.sheet(isPresented: wide ? .constant(false) : isPresented, onDismiss: onDismiss, content: content)
            .modifier(ExplainerCompanion(shown: wide && isPresented.wrappedValue, close: { isPresented.wrappedValue = false },
                                         onDismiss: onDismiss, opened: opened, page: content))
    }

    /// Wide: the pane's own row (or floating controls) replaces its navigation bar. Tall is left exactly as it was.
    @ViewBuilder func navigationBarHiddenInWide(_ wide: Bool) -> some View {
        if wide { toolbar(.hidden, for: .navigationBar) } else { self }
    }

    /// A page in Wide's companion slot (ExplainPane) keeps its own bar, as it has in a sheet.
    @ViewBuilder func navigationBarShownInCover(_ cover: Bool) -> some View {
        if cover { toolbar(.visible, for: .navigationBar) } else { self }
    }
}

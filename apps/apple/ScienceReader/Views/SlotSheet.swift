import SwiftUI
import ScienceReaderCore

// Prompts as on iPhone (owner, 2026-10-24: "In the ai explainer it again put the prompt in the middle of the screen over the
// two left and right underneath please fix that, make the UX same as iPhone find all instances where this guidance
// applies"; docs/DESIGN.md › Tall and Wide). On iPad nothing floats as a centred card over the two slots:
// - Wide, a prompt raised from something in a slot (an explainer, the chat, a list, Snippets) covers that slot only, rising
//   from its bottom edge with the iPhone sheet's look (`slotSheet`); the other slot stays visible and usable.
// - Tall, and a prompt that belongs to the whole app (Settings, sign-in, Get credits…), is the iPhone's sheet scaled up
//   (`phoneSheetSizing`): the window's width upright, a page's size sideways, never the small centred form sheet.

// MARK: - The window's shape for a sheet

enum PhoneSheet {
    /// The foreground window's size (a sheet's own size isn't its window's).
    @MainActor static var windowSize: CGSize? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return (scene?.keyWindow ?? scene?.windows.first)?.bounds.size
    }

    /// Tall (LayoutShape): the iPhone's sheet spans the window.
    @MainActor static var windowIsTall: Bool { windowSize.map { !WindowShape.isWide(window: $0) } ?? true }
}

/// Upright, more than any window (the sheet takes all the window gives it: the iPhone's card, its top edge under the status
/// bar); sideways, a page's size, as `.page`.
@available(iOS 18.0, *)
private struct PhoneSheetSizing: PresentationSizing {
    let tall: Bool
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        tall ? ProposedViewSize(width: 100_000, height: 100_000) : PagePresentationSizing.page.proposedSize(for: root, context: context)
    }
}

private struct PhoneSheetSizingModifier: ViewModifier {
    @State private var tall = true
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            content
                .presentationSizing(PhoneSheetSizing(tall: tall))
                // Turning the iPad resizes the sheet: its shape is read again then.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in tall = PhoneSheet.windowIsTall }
                .onAppear { tall = PhoneSheet.windowIsTall }
        } else {
            content
        }
        #endif
    }
}

extension View {
    /// A sheet's content: on iPad, the iPhone's sheet scaled up rather than the centred form sheet (upright the window's
    /// width, sideways a page). The iPhone (whose sheets already are), iPadOS 17 (no sizing API) and the Mac are unchanged.
    func phoneSheetSizing() -> some View { modifier(PhoneSheetSizingModifier()) }

    /// A sheet that belongs to the whole app (Settings, sign-in, Get credits, Add paper…): the system's sheet, sized as on
    /// iPhone (`phoneSheetSizing`).
    func appSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                               @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().phoneSheetSizing() }
    }

    func appSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                   @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).phoneSheetSizing() }
    }
}

// MARK: - A slot's own sheets

/// How tall a slot's sheet is, as the sheet's detents on iPhone: the slot's height (less the iPhone's gap above a large
/// sheet), half of it, or a fixed height.
enum SlotSheetDetent: Equatable {
    case large, medium, height(CGFloat)
    var presentation: PresentationDetent {
        switch self { case .large: .large; case .medium: .medium; case .height(let height): .height(height) }
    }
}

private struct SlotSheetDetentKey: PreferenceKey {
    static let defaultValue: SlotSheetDetent? = nil
    static func reduce(value: inout SlotSheetDetent?, nextValue: () -> SlotSheetDetent?) { value = value ?? nextValue() }
}

private struct SlotSheetDismissDisabledKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// The sheet's detent in either form: the system sheet's (`presentationDetents`) and a slot's sheet's.
    func sheetDetent(_ detent: SlotSheetDetent) -> some View {
        presentationDetents([detent.presentation]).slotSheetDetent(detent)
    }

    /// A slot's sheet's detent only, for content that sets the system sheet's own detents (with a selection).
    func slotSheetDetent(_ detent: SlotSheetDetent) -> some View { preference(key: SlotSheetDetentKey.self, value: detent) }

    /// `interactiveDismissDisabled` for either form: a slot's sheet then ignores the swipe, the dimmed slot's tap and
    /// VoiceOver's escape, as the system sheet does.
    func sheetDismissDisabled(_ disabled: Bool = true) -> some View {
        interactiveDismissDisabled(disabled).preference(key: SlotSheetDismissDisabledKey.self, value: disabled)
    }
}

/// The sheets shown over one slot, newest last (only the newest shows).
@MainActor @Observable final class SlotSheetCenter {
    struct Entry: Identifiable {
        let id: UUID
        var content: AnyView
        var close: @MainActor @Sendable () -> Void
        var interactiveDismissDisabled: Bool
    }
    private(set) var entries: [Entry] = []

    func present(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
    }
    func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }
}

private struct SlotSheetCenterKey: EnvironmentKey { static let defaultValue: SlotSheetCenter? = nil }
private struct SlotSheetCloseKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable () -> Void)? = nil }

extension EnvironmentValues {
    /// The slot a view is in, Wide on iPad with two slots showing (TwoSlotLayout): its sheets cover that slot. Nil
    /// elsewhere: sheets are the system's.
    var slotSheetCenter: SlotSheetCenter? {
        get { self[SlotSheetCenterKey.self] }
        set { self[SlotSheetCenterKey.self] = newValue }
    }
    /// Closes the slot's sheet a view is in (`SheetDismiss`); nil in a system sheet.
    var slotSheetClose: (@MainActor @Sendable () -> Void)? {
        get { self[SlotSheetCloseKey.self] }
        set { self[SlotSheetCloseKey.self] = newValue }
    }
}

/// `@Environment(\.dismiss)` for a sheet's content that may be a slot's sheet: closes whichever it is in.
@propertyWrapper struct SheetDismiss: DynamicProperty {
    @Environment(\.dismiss) private var system
    @Environment(\.slotSheetClose) private var slot
    var wrappedValue: SheetDismissAction { SheetDismissAction(slot: slot, system: system) }
}

struct SheetDismissAction {
    let slot: (@MainActor @Sendable () -> Void)?
    let system: DismissAction
    @MainActor func callAsFunction() { if let slot { slot() } else { system() } }
}

/// One slot of TwoSlotLayout: hosts the sheets raised from inside it while two slots show (`active`), on iPad. Inactive,
/// the enclosing slot's host (if any) stays in charge, and with none the sheets are the system's. The Mac keeps its sheets.
struct SlotSheetHost: ViewModifier {
    private let active: Bool
    @Environment(\.slotSheetCenter) private var enclosing
    @State private var center = SlotSheetCenter()

    init(active: Bool) { self.active = active && !Platform.isMac }

    func body(content: Content) -> some View {
        content
            .environment(\.slotSheetCenter, active ? center : enclosing)
            .overlay {
                ZStack {
                    if active, let entry = center.entries.last {
                        SlotSheetCard(entry: entry).id(entry.id).transition(.opacity)
                    }
                }
                .animation(.snappy(duration: 0.25), value: center.entries.last?.id)
            }
    }
}

/// The iPhone sheet's look within a slot: the slot dimmed (a tap closes), the sheet rising from the slot's bottom edge with
/// a grabber and rounded top corners, dragged down by its grabber to close; modal for VoiceOver, whose escape closes it.
private struct SlotSheetCard: View {
    let entry: SlotSheetCenter.Entry
    @State private var detent: SlotSheetDetent = .large
    /// The content asks not to be closed by a swipe or a tap (`sheetDismissDisabled`), as with unsaved text.
    @State private var contentHolds = false
    @State private var drag: CGFloat = 0
    /// Risen: false for the first frame, so the sheet rises from the slot's bottom edge as the slot dims.
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var holds: Bool { entry.interactiveDismissDisabled || contentHolds }

    var body: some View {
        GeometryReader { proxy in
            let room = proxy.size.height
            let height: CGFloat = switch detent {
            case .large: room - 10
            case .medium: room / 2
            case .height(let fixed): min(room - 10, fixed + proxy.safeAreaInsets.bottom + 14)
            }
            ZStack(alignment: .bottom) {
                Color.black.opacity(risen ? 0.18 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if !holds { entry.close() } }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    // The grabber's strip takes the drag (the content's own lists keep their scrolling).
                    Capsule().fill(Color(uiColor: .tertiaryLabel)).frame(width: 36, height: 5)
                        .padding(.top, 5).padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { value in if !holds { drag = value.translation.height } }
                            .onEnded { value in
                                let far = value.translation.height > 100 || value.predictedEndTranslation.height > 240
                                if far && !holds { entry.close() }
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { drag = 0 }
                            })
                        .accessibilityHidden(true)
                    entry.content
                        .environment(\.slotSheetClose, entry.close)
                        .onPreferenceChange(SlotSheetDetentKey.self) { value in detent = value ?? .large }
                        .onPreferenceChange(SlotSheetDismissDisabledKey.self) { value in contentHolds = value }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: max(120, height))
                // Its background runs under the home indicator, as the iPhone's sheet does.
                .background(UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                    .fill(Color(uiColor: .systemGroupedBackground))
                    .shadow(color: .black.opacity(0.14), radius: 18, y: -2)
                    .ignoresSafeArea(.container, edges: .bottom))
                .offset(y: risen ? max(0, drag) : room)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { if !holds { entry.close() } }
                .accessibilityIdentifier("slot.sheet")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear { withAnimation(reduceMotion ? nil : .snappy(duration: 0.32)) { risen = true } }
    }
}

/// `slotSheet`: the system's sheet (`phoneSheetSizing`) except in a Wide slot, where it covers that slot (SlotSheetHost).
private struct SlotSheetModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    /// What is shown (an item's ID): a change while shown shows the new one.
    let identity: AnyHashable?
    let interactiveDismissDisabled: Bool
    let onDismiss: (() -> Void)?
    @ViewBuilder let sheet: () -> Sheet
    @Environment(\.slotSheetCenter) private var center
    @State private var id = UUID()
    /// The slot showing it, when one is.
    @State private var shownIn: SlotSheetCenter?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: center == nil ? $isPresented : .constant(false), onDismiss: onDismiss) {
                sheet().interactiveDismissDisabled(interactiveDismissDisabled).phoneSheetSizing()
            }
            .onChange(of: isPresented, initial: true) { _, _ in sync() }
            .onChange(of: identity) { _, _ in if shownIn != nil { show() } }
            .onChange(of: center.map(ObjectIdentifier.init)) { _, _ in sync() }
            .onDisappear { shownIn?.remove(id); shownIn = nil }
    }

    private func sync() {
        // Turned to Tall (or the slots merged): the slot's sheet becomes the system's, which the binding presents.
        if let shownIn, shownIn !== center { shownIn.remove(id); self.shownIn = nil }
        guard center != nil else { return }
        if isPresented { show() }
        else if let shownIn { shownIn.remove(id); self.shownIn = nil; onDismiss?() }
    }

    private func show() {
        guard let center else { return }
        let binding = $isPresented
        center.present(.init(id: id, content: AnyView(sheet()), close: { binding.wrappedValue = false },
                             interactiveDismissDisabled: interactiveDismissDisabled))
        shownIn = center
    }
}

extension View {
    /// A sheet raised from inside a slot: in Wide on iPad it covers that slot only, as the iPhone's sheet covers its screen;
    /// elsewhere it is the system's sheet, the iPhone's look on iPad too (`phoneSheetSizing`). Its content closes itself
    /// with `@SheetDismiss` (not `@Environment(\.dismiss)`, which can't reach a slot's sheet).
    func slotSheet<Sheet: View>(isPresented: Binding<Bool>, interactiveDismissDisabled: Bool = false, onDismiss: (() -> Void)? = nil,
                                @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(SlotSheetModifier(isPresented: isPresented, identity: nil, interactiveDismissDisabled: interactiveDismissDisabled,
                                   onDismiss: onDismiss, sheet: content))
    }

    func slotSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, interactiveDismissDisabled: Bool = false,
                                                    onDismiss: (() -> Void)? = nil,
                                                    @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        modifier(SlotSheetModifier(isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
                                   identity: item.wrappedValue.map { AnyHashable($0.id) },
                                   interactiveDismissDisabled: interactiveDismissDisabled, onDismiss: onDismiss) {
            if let value = item.wrappedValue { content(value) }
        })
    }
}

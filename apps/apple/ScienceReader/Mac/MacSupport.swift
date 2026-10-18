import SwiftUI
import WebKit
import ScienceReaderCore

// The Mac app is this target built with Mac Catalyst and the Mac idiom ("Optimize for Mac"); see
// docs/architecture/MAC_APP.md. Shared views ask `Platform`; Mac-only behavior lives here and in
// MacCommands.swift, so the iOS app is unchanged.

enum Platform {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// iPad or Mac: the layouts that put panes side by side and center scrolling columns. The Mac
    /// uses the same wide workspace as the browser (Library/Feed, Reader and Chat panes), while
    /// reusing the iPad's SwiftUI surfaces and shared model for behavioral parity.
    @MainActor static var isLargeScreen: Bool {
        let idiom = UIDevice.current.userInterfaceIdiom
        return idiom == .pad || idiom == .mac
    }

    /// Visual checks (docs/VISUAL_CHECK.md): `--appearance=dark|light` pins the appearance for a capture where no
    /// Simulator setting can (the Mac). Nil otherwise: the system appearance.
    static var fixtureAppearance: ColorScheme? {
        #if DEBUG && FIXTURE_HOST
        switch ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--appearance=") })?.dropFirst("--appearance=".count) {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Visual checks on the Mac: `--window-size=WxH` opens the window at that size and never remembers it.
    static var fixtureWindowSize: CGSize? {
        #if DEBUG && FIXTURE_HOST
        guard let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--window-size=") })?.dropFirst("--window-size=".count) else { return nil }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 320, parts[1] >= 240, parts[0] <= 8192, parts[1] <= 8192 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
        #else
        return nil
        #endif
    }
}

extension ReaderModel {
    /// The wide layout's view switch (iPad header picker, Mac toolbar and View menu): the mode, the tab
    /// that goes with it, and which chat it shows. Leaves Settings when it is showing.
    func showWideMode(_ mode: WideMode) {
        wideMode = mode
        tab = mode == .feed ? .feed : (mode == .chat ? .chat : (mode == .reader ? .paper : .library))
        if mode == .chat { generalChat = true }
        if mode == .reader, chatPaperID != nil { generalChat = false }
    }
}

/// Requests from the menu bar to views that own the state (consumed once by the view).
@MainActor @Observable final class MacCommandRequests {
    static let shared = MacCommandRequests()
    /// Focus the Library's search field (⌘F), or its arXiv search (⌥⌘F).
    var librarySearch: UUID?
}

// MARK: - Rows and sheets

extension View {
    /// Mac: buttons without a style of their own look as they do on iPad (accent text or symbol), not like
    /// Mac push buttons. Explicit styles (bordered, prominent, plain) are unaffected.
    @ViewBuilder func macPlatformStyle() -> some View {
        #if targetEnvironment(macCatalyst)
        buttonStyle(.borderless)
        #else
        self
        #endif
    }

    /// Mac: a light highlight under the pointer on a list row. No effect on iPhone and iPad.
    func macRowHover() -> some View { modifier(MacRowHover()) }

    /// Mac: a text button at the leading end of a bar keeps its natural width (Mac Catalyst otherwise
    /// draws it in a 44 pt circle, truncating "Cancel" to "C…").
    @ViewBuilder func macBarButton() -> some View {
        #if targetEnvironment(macCatalyst)
        fixedSize()
        #else
        self
        #endif
    }

    /// Mac: a keyboard shortcut that only the Mac shows (menu-bar conventions such as ⌘Return to send).
    @ViewBuilder func macKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        #if targetEnvironment(macCatalyst)
        keyboardShortcut(key, modifiers: modifiers)
        #else
        self
        #endif
    }

    /// Mac: ⌘W (File › Close) closes this sheet, like Escape (which Mac Catalyst sheets already handle). Apply to the
    /// sheet's content (inside `.sheet { }`); pass `false` while the sheet must stay (work in progress, a choice the
    /// reader must make).
    func macSheetKeys(enabled: Bool = true) -> some View { modifier(MacSheetKeys(enabled: enabled)) }
}

private struct MacRowHover: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.onHover { hovered = $0 }
            .listRowBackground(hovered ? Color.primary.opacity(0.05) : nil)
        #else
        content
        #endif
    }
}

private struct MacSheetKeys: ViewModifier {
    let enabled: Bool
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        // File › Close finds this guard in the frontmost sheet (MacClose). A hidden ⌘W button here lost to the menu
        // bar's own Close, which closed the sheet with a tag still being typed (MAC_APP.md, 2026-10-16).
        content.background { MacSheetGuard(enabled: enabled, dismiss: dismiss) }
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// A sheet's answer to File › Close: whether it may close now, and how.
final class MacSheetGuardView: UIView {
    var enabled = true
    var dismiss: () -> Void = {}
}

private struct MacSheetGuard: UIViewRepresentable {
    let enabled: Bool
    let dismiss: DismissAction
    func makeUIView(context: Context) -> MacSheetGuardView {
        let view = MacSheetGuardView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: MacSheetGuardView, context: Context) {
        view.enabled = enabled
        view.dismiss = { dismiss() }
    }
}

/// File › Close (⌘W): the frontmost sheet first, then the window (MAC_APP.md). A sheet with a guard closes only when
/// the guard allows (`macSheetKeys(enabled:)`); one without a guard closes unless it asks not to be dismissed; an alert
/// waits for its choice. The window closes only when nothing is presented over it.
@MainActor enum MacClose {
    static func perform() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.keyWindow ?? scene.windows.first, let root = window.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        guard top !== root else {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
            return
        }
        if let sheetGuard = top.view.firstDescendant(of: MacSheetGuardView.self) {
            if sheetGuard.enabled { sheetGuard.dismiss() }
            return
        }
        if top is UIAlertController || top.isModalInPresentation { return }
        top.presentingViewController?.dismiss(animated: true)
    }
}

extension UIResponder {
    /// File › Close (MacAppDelegate): every responder answers it the same way, so it reaches MacClose from wherever focus is.
    @objc func gradstepClose(_ sender: Any?) { MacClose.perform() }
}

private extension UIView {
    func firstDescendant<View: UIView>(of type: View.Type) -> View? {
        for child in subviews {
            if let match = child as? View ?? child.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
#endif

// MARK: - Reader web view

/// The reader's web view. Selected text gets the system edit menu (the context menu on the Mac) with Copy first,
/// then the selection actions — Explain in Chat, Why it matters, Related papers, Add paper — then the system's
/// Look Up, Translate, Share… A tapped equation opens the same menu beside it: Copy LaTeX, Copy as text and the
/// actions (owner feedback, build 16 #4/#5, replacing the bar that sat under the paper), with AI Explainer (its own view)
/// right after Explain in Chat.
final class ReaderWebView: WKWebView, @MainActor UIEditMenuInteractionDelegate {
    /// The paper's own view (not a figure's): runs a selection action on what is selected when it is chosen.
    var menuAction: ((SelectionAction) -> Void)?
    /// Text is selected (the bridge's last report). The Mac's right-click menu offers the actions only then; iOS offers
    /// them whenever WebKit shows its edit menu, which can open before the debounced report arrives.
    var hasSelection = false
    /// The open paper's web view (not a figure's), for Edit › Find in Paper.
    @MainActor static weak var paper: ReaderWebView?
    /// Called with the bridge's equation ID when that equation's menu closes without an action (its outline goes too).
    var onEquationMenuDismissed: ((String) -> Void)?
    /// "AI Explainer" in a tapped equation's menu, right after Explain in Chat (owner, build 62; it was "Equation"): opens
    /// the equation view for that equation and asks for its explanation (docs/architecture/EQUATION_VIEW.md). Nil offers
    /// no such item.
    var onOpenEquation: ((String) -> Void)?
    private lazy var equationMenu = UIEditMenuInteraction(delegate: self)
    /// The equation whose menu is open: its quote, where it is, its ID in the page, and this presentation's token.
    private var equation: (quote: String, rect: CGRect, equationID: String, id: String)?
    /// All bibliography actions together (owner, 2026-10-18); iOS edit menus otherwise paginate them.
    private weak var referenceSheet: UIAlertController?
    #if targetEnvironment(macCatalyst)
    private var macMenuButton: ReaderMenuButton?
    private weak var macMenuSheet: UIAlertController?
    #endif

    /// Opens every action together: a native action sheet on touch devices, an anchored menu on Mac.
    func presentReferenceMenu(rect: CGRect, actions: [UIMenuElement]) {
        #if targetEnvironment(macCatalyst)
        presentMacMenu(UIMenu(children: actions), rect: rect)
        #else
        referenceSheet?.dismiss(animated: false)
        var responder: UIResponder? = self
        while responder != nil, !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for case let action as UIAction in actions {
            sheet.addAction(UIAlertAction(title: action.title, style: .default) { _ in UIControl().sendAction(action) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let visible = rect.intersection(bounds)
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = visible.isNull ? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1) : visible
        referenceSheet = sheet
        controller.present(sheet, animated: true)
        #endif
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // Find in the paper (⌘F, ⌘G, as in Safari) is enabled by PaperWebView for the paper's own view.
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var findRequested: (() -> Void)?
    var findStepped: ((Bool) -> Void)?
    func showFind() { findRequested?() }
    func findNext(backwards: Bool) { findStepped?(backwards) }

    /// Selected text: the actions right after the system's Copy.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let menuAction, hasSelection || !Platform.isMac else { return }
        let menu = UIMenu(title: "", identifier: Self.selectionMenuID, options: .displayInline,
                          children: Self.actions(SelectionAction.allCases, run: menuAction))
        guard builder.menu(for: Self.selectionMenuID) == nil else { return }
        if builder.menu(for: .standardEdit) != nil { builder.insertSibling(menu, afterMenu: .standardEdit) }
        else { builder.insertChild(menu, atStartOfMenu: .root) }
    }

    static let selectionMenuID = UIMenu.Identifier("gradstep.selection")

    static func actions(_ actions: [SelectionAction], run: @escaping (SelectionAction) -> Void) -> [UIMenuElement] {
        actions.map { action in
            UIAction(title: action.menuTitle, image: UIImage(systemName: action.symbol),
                     identifier: UIAction.Identifier("reader.selection." + action.rawValue.lowercased())) { _ in run(action) }
        }
    }

    // MARK: Equations

    /// A tapped equation (its LaTeX quote and where it is, in this view's coordinates): opens the edit menu beside it.
    func presentEquationMenu(quote: String, rect: CGRect, equationID: String) {
        guard menuAction != nil else { return }
        let id = UUID().uuidString
        equation = (quote, rect, equationID, id)
        #if targetEnvironment(macCatalyst)
        if let menu = equationActionsMenu() {
            presentMacMenu(menu, rect: rect) { [weak self] in
                guard let self, self.equation?.id == id else { return }
                self.equation = nil; self.onEquationMenuDismissed?(equationID)
            }
        }
        #else
        if !interactions.contains(where: { $0 === equationMenu }) { addInteraction(equationMenu) }
        let visible = rect.intersection(bounds)
        let point = visible.isNull ? CGPoint(x: bounds.midX, y: bounds.midY) : CGPoint(x: visible.midX, y: visible.minY)
        equationMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: id as NSString, sourcePoint: point))
        #endif
    }

    func dismissEquationMenu() {
        equation = nil
        #if targetEnvironment(macCatalyst)
        macMenuButton?.contextMenuInteraction?.dismissMenu()
        macMenuButton?.removeFromSuperview(); macMenuButton = nil
        macMenuSheet?.dismiss(animated: false); macMenuSheet = nil
        #else
        equationMenu.dismissMenu()
        #endif
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {

        guard let equation, configuration.identifier as? String == equation.id else { return nil }
        return equationActionsMenu()
    }

    private func equationActionsMenu() -> UIMenu? {
        guard let equation, let menuAction else { return nil }
        let copyText = UIAction(title: "Copy as Text", image: UIImage(systemName: "textformat"), identifier: UIAction.Identifier("reader.equation.copyText")) { _ in
            UIPasteboard.general.string = equation.quote
        }
        // The menu is closing because of the action: the equation stays selected until the action has read it.
        let run: (SelectionAction) -> Void = { [weak self] action in self?.equation = nil; menuAction(action) }
        var actions: [UIMenuElement] = [UIAction(title: "Chat about Equation", image: UIImage(systemName: "bubble.left.and.text.bubble.right"),
            identifier: UIAction.Identifier("reader.selection.define")) { _ in run(.define) }]
        actions += Self.actions([.similar], run: run)
        if let open = onOpenEquation {
            let view = UIAction(title: "AI Explainer", image: UIImage(systemName: "sparkles"), identifier: UIAction.Identifier("reader.equation.view")) { [weak self] _ in
                self?.equation = nil; open(equation.equationID)
            }
            actions.insert(view, at: min(1, actions.count))
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: actions),
                                 UIMenu(options: .displayInline, children: [copyText])])
    }

    #if targetEnvironment(macCatalyst)
    // UIEditMenuInteraction explicitly rejects programmatic presentation in the Mac idiom. A menu control's
    // public primary action presents the same UIMenu beside the clicked equation/reference on Catalyst.
    private func presentMacMenu(_ menu: UIMenu, rect: CGRect, dismissed: @escaping () -> Void = {}) {
        macMenuButton?.contextMenuInteraction?.dismissMenu()
        macMenuButton?.removeFromSuperview()
        macMenuSheet?.dismiss(animated: false); macMenuSheet = nil
        let visible = rect.intersection(bounds)
        let point = visible.isNull ? CGPoint(x: bounds.midX, y: bounds.midY) : CGPoint(x: visible.midX, y: visible.minY)
        // macOS 14.0–14.3 predates UIControl's programmatic primary action. Keep every action available in a
        // standard anchored action sheet there, without changing the app's deployment minimum.
        guard #available(macCatalyst 17.4, *) else {
            var responder: UIResponder? = self
            while responder != nil, !(responder is UIViewController) { responder = responder?.next }
            guard let controller = responder as? UIViewController else { dismissed(); return }
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            func append(_ elements: [UIMenuElement]) {
                for element in elements {
                    if let group = element as? UIMenu { append(group.children) }
                    else if let action = element as? UIAction {
                        sheet.addAction(UIAlertAction(title: action.title, style: .default) { _ in
                            UIControl().sendAction(action); dismissed()
                        })
                    }
                }
            }
            append(menu.children)
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in dismissed() })
            sheet.popoverPresentationController?.sourceView = self
            sheet.popoverPresentationController?.sourceRect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
            macMenuSheet = sheet; controller.present(sheet, animated: true)
            return
        }
        let button = ReaderMenuButton(frame: CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        button.menu = menu; button.showsMenuAsPrimaryAction = true; button.isAccessibilityElement = false
        button.ended = { [weak self, weak button] in
            guard let self, let button, self.macMenuButton === button else { return }
            self.macMenuButton = nil; button.removeFromSuperview(); dismissed()
        }
        addSubview(button); macMenuButton = button
        button.performPrimaryAction()
    }
    #endif

    /// An equation as Unicode text (as the chat's "Copy as text").
    static func plainText(_ quote: String) -> String {
        let math = ChatTitle.segments(quote).compactMap { segment -> String? in
            if case .math(let body, _, _) = segment { return body }
            return nil
        }
        return math.count == 1 ? ChatMathText.plain(math[0]) : ChatTitle.readable(quote, wholeWord: true)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let equation, configuration.identifier as? String == equation.id else { return .null }
        let visible = equation.rect.intersection(bounds)
        return visible.isNull ? .null : visible
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        // Only the menu still current: a tap on another equation replaces it with that one's.
        guard let equation, configuration.identifier as? String == equation.id else { return }
        animator.addCompletion { [weak self] in
            guard let self, self.equation?.id == equation.id else { return }
            self.equation = nil
            self.onEquationMenuDismissed?(equation.equationID)
        }
    }
}

#if targetEnvironment(macCatalyst)
private final class ReaderMenuButton: UIButton {
    var ended: (() -> Void)?
    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        if let animator { animator.addCompletion { [weak self] in self?.ended?() } }
        else { ended?() }
    }
}
#endif

// MARK: - Window

#if targetEnvironment(macCatalyst)
/// The Mac app's delegate: removes the document-based items Catalyst puts in the File menu (Duplicate,
/// Move, Rename, Export) and the text Find menu, which GradstepCommands replaces.
final class MacAppDelegate: UIResponder, UIApplicationDelegate {
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .document)
        // The system's Close (performClose:) closed a sheet with its work in progress (a tag being typed); this one asks
        // the sheet first (MacClose). Replaced in place: its menu anchors SwiftUI's File items, and a second ⌘W is dropped.
        builder.replaceChildren(ofMenu: .close) { children in
            children.map { child in
                guard (child as? UICommand)?.action == NSSelectorFromString("performClose:") else { return child }
                return UIKeyCommand(title: "Close", action: #selector(UIResponder.gradstepClose(_:)), input: "w", modifierFlags: .command)
            }
        }
        builder.remove(menu: .find)
        builder.remove(menu: .format)
    }
}

/// Configures the Mac window once it exists: size limits, a first-launch size, and a unified toolbar
/// holding the wide layout's view switch (Feed · Library · Reader · Browse · General Chat) and Settings,
/// which on iPad sit in the app's own header row.
struct MacWindowConfiguration: UIViewRepresentable {
    let model: ReaderModel
    let mode: WideMode
    let settingsShown: Bool
    /// Reading mode: the window's toolbar steps aside with the rest of the chrome (READING_MODE.md).
    var reading = false

    func makeCoordinator() -> MacToolbarController { MacToolbarController(model: model) }

    func makeUIView(context: Context) -> WindowHookView {
        let view = WindowHookView()
        let controller = context.coordinator
        view.onWindow = { window in controller.attach(to: window) }
        view.onResize = { size in controller.windowResized(to: size) }
        return view
    }

    func updateUIView(_ view: WindowHookView, context: Context) {
        context.coordinator.update(mode: mode, settingsShown: settingsShown)
        context.coordinator.showToolbar(!reading)
    }
}

final class WindowHookView: UIView {
    var onWindow: ((UIWindow) -> Void)?
    var onResize: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { onWindow?(window) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let size = window?.bounds.size, size != lastSize { lastSize = size; onResize?(size) }
    }
}

@MainActor final class MacToolbarController: NSObject, NSToolbarDelegate {
    /// Narrower than this, the panes (Reader: paper and chat; Browse: library and paper) don't fit. Half of a
    /// 13-inch screen (735 pt) still holds the window, so it tiles beside another app.
    static let minimumSize = CGSize(width: 720, height: 520)
    static let defaultSize = CGSize(width: 1280, height: 820)
    private static let modesID = NSToolbarItem.Identifier("gradstep.modes")
    private static let settingsID = NSToolbarItem.Identifier("gradstep.settings")
    private static let sizeKey = "mac.window.size"

    private let model: ReaderModel
    private weak var scene: UIWindowScene?
    /// Sizes are remembered only after the launch size is applied (the system's first size isn't the reader's).
    private var restoringSize = true
    private var modes: NSToolbarItemGroup?
    private var settings: NSToolbarItem?

    init(model: ReaderModel) { self.model = model }

    func attach(to window: UIWindow) {
        guard let scene = window.windowScene, scene !== self.scene else { return }
        self.scene = scene
        scene.title = "Gradstep"
        scene.sizeRestrictions?.minimumSize = Self.minimumSize
        if let titlebar = scene.titlebar {
            let toolbar = NSToolbar(identifier: "gradstep.window")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.centeredItemIdentifiers = [Self.modesID]
            titlebar.toolbar = toolbar
            titlebar.toolbarStyle = .unified
            // The view switch says where you are; the window's title would only repeat a pane's title.
            titlebar.titleVisibility = .hidden
            titlebar.separatorStyle = .automatic
        }
        // The window opens at the size it had when the app was last used (the system's first window is
        // small for three panes, and Mac Catalyst doesn't restore it), centered on the screen.
        let saved = UserDefaults.standard.string(forKey: Self.sizeKey).map(NSCoder.cgSize(for:)) ?? .zero
        let wanted = Platform.fixtureWindowSize ?? (saved.width >= Self.minimumSize.width && saved.height >= Self.minimumSize.height ? saved : Self.defaultSize)
        // After the window is on screen; an earlier request is ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak scene, weak window] in
            guard let self, let scene, let window else { return }
            defer { self.restoringSize = false }
            let screen = scene.screen.bounds
            let size = CGSize(width: min(wanted.width, screen.width - 40), height: min(wanted.height, screen.height - 60))
            guard abs(window.bounds.width - size.width) > 2 || abs(window.bounds.height - size.height) > 2 else { return }
            let frame = CGRect(x: (screen.width - size.width) / 2, y: max(30, (screen.height - size.height) / 2),
                               width: size.width, height: size.height)
            scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        }
        update(mode: model.wideMode, settingsShown: model.tab == .settings)
    }

    /// Reading mode hides the toolbar (the quiet bar over the paper has its controls); leaving it brings it back.
    func showToolbar(_ visible: Bool) {
        guard let toolbar = scene?.titlebar?.toolbar, toolbar.isVisible != visible else { return }
        toolbar.isVisible = visible
    }

    func windowResized(to size: CGSize) {
        guard !restoringSize, Platform.fixtureWindowSize == nil, size.width >= Self.minimumSize.width, size.height >= Self.minimumSize.height else { return }
        UserDefaults.standard.set(NSCoder.string(for: size), forKey: Self.sizeKey)
    }

    func update(mode: WideMode, settingsShown: Bool) {
        guard modes != nil else { return }
        // Settings is outside the five workspace panes. Catalyst keeps reporting the last selected
        // index for a native select-one group, so use select-any and clear every segment explicitly.
        if settingsShown {
            setModeSelection(nil)
        } else {
            setModeSelection(WideMode.allCases.firstIndex(of: mode) ?? 1)
        }
    }

    private func setModeSelection(_ index: Int?) {
        guard let modes else { return }
        for candidate in WideMode.allCases.indices {
            modes.setSelected(candidate == index, at: candidate)
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modesID, .flexibleSpace, Self.settingsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.modesID:
            let titles = WideMode.allCases.map(\.rawValue)
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: titles, selectionMode: .selectAny,
                                           labels: titles, target: self, action: #selector(modeChosen(_:)))
            group.controlRepresentation = .expanded
            group.label = "View"
            group.toolTip = "Choose a view (⌘1–⌘5)"
            modes = group
            setModeSelection(WideMode.allCases.firstIndex(of: model.wideMode) ?? 1)
            return group
        case Self.settingsID:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = UIImage(systemName: "gearshape")
            item.label = "Settings"
            item.toolTip = "Settings (⌘,)"
            item.isBordered = true
            item.target = self
            item.action = #selector(settingsChosen(_:))
            settings = item
            return item
        default: return nil
        }
    }

    @objc private func modeChosen(_ sender: NSToolbarItemGroup) {
        guard WideMode.allCases.indices.contains(sender.selectedIndex) else { return }
        let index = sender.selectedIndex
        setModeSelection(index)
        model.showWideMode(WideMode.allCases[index])
    }

    @objc private func settingsChosen(_ sender: NSToolbarItem) {
        if model.tab == .settings { model.showWideMode(model.wideMode) } else { model.tab = .settings }
    }
}
#endif

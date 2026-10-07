import SwiftUI
import WebKit

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

    /// iPad or Mac: the layouts that put panes side by side and center scrolling columns. The Mac is
    /// treated like a large iPad unless a Mac path is better.
    @MainActor static var isLargeScreen: Bool {
        let idiom = UIDevice.current.userInterfaceIdiom
        return idiom == .pad || idiom == .mac
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

    /// Mac: ⌘W closes this sheet, like Escape (which Mac Catalyst sheets already handle). Apply to the
    /// sheet's content (inside `.sheet { }`); pass `false` while the sheet must stay (work in progress).
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
        content.background {
            if enabled {
                // An invisible button owns the shortcut; the sheet's visible Cancel/Done stay as they are.
                Button("Close") { dismiss() }.keyboardShortcut("w")
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        #else
        content
        #endif
    }
}

// MARK: - Reader web view

/// The reader's web view. On the Mac, the context menu of selected text starts with the selection
/// actions (Explain, Why it matters, Related, Add paper), the same actions as the bar under the paper.
final class ReaderWebView: WKWebView {
    /// Set while text is selected in the paper; runs a selection action on it.
    var selectionAction: ((SelectionAction) -> Void)?
    /// The open paper's web view (not a figure's), for Edit › Find in Paper.
    @MainActor static weak var paper: ReaderWebView?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        #if targetEnvironment(macCatalyst)
        // Mac: find in the paper (⌘F, ⌘G), as in Safari.
        isFindInteractionEnabled = true
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the find bar over the paper.
    func showFind() {
        _ = becomeFirstResponder()
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func findNext(backwards: Bool) {
        guard let findInteraction else { return }
        if findInteraction.searchText?.isEmpty ?? true { showFind() }
        else if backwards { findInteraction.findPrevious() } else { findInteraction.findNext() }
    }

    #if targetEnvironment(macCatalyst)
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let selectionAction else { return }
        let actions = SelectionAction.allCases.map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.macSymbol)) { _ in selectionAction(action) }
        }
        let menu = UIMenu(title: "", identifier: UIMenu.Identifier("gradstep.selection"), options: .displayInline, children: actions)
        if builder.menu(for: .standardEdit) != nil { builder.insertSibling(menu, beforeMenu: .standardEdit) }
        else { builder.insertChild(menu, atStartOfMenu: .root) }
    }
    #endif
}

extension SelectionAction {
    var macSymbol: String {
        switch self { case .define: "text.magnifyingglass"; case .relevance: "lightbulb"; case .similar: "point.3.connected.trianglepath.dotted"; case .ingest: "plus.square.on.square" }
    }
}

// MARK: - Window

#if targetEnvironment(macCatalyst)
/// The Mac app's delegate: removes the document-based items Catalyst puts in the File menu (Duplicate,
/// Move, Rename, Export) and the text Find menu, which GradstepCommands replaces.
final class MacAppDelegate: UIResponder, UIApplicationDelegate {
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .document)
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
        let wanted = saved.width >= Self.minimumSize.width && saved.height >= Self.minimumSize.height ? saved : Self.defaultSize
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

    func windowResized(to size: CGSize) {
        guard !restoringSize, size.width >= Self.minimumSize.width, size.height >= Self.minimumSize.height else { return }
        UserDefaults.standard.set(NSCoder.string(for: size), forKey: Self.sizeKey)
    }

    func update(mode: WideMode, settingsShown: Bool) {
        if let index = WideMode.allCases.firstIndex(of: mode), modes?.selectedIndex != index { modes?.selectedIndex = index }
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
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: titles, selectionMode: .selectOne,
                                           labels: titles, target: self, action: #selector(modeChosen(_:)))
            group.controlRepresentation = .expanded
            group.label = "View"
            group.toolTip = "Choose a view (⌘1–⌘5)"
            group.selectedIndex = WideMode.allCases.firstIndex(of: model.wideMode) ?? 1
            modes = group
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
        model.showWideMode(WideMode.allCases[sender.selectedIndex])
    }

    @objc private func settingsChosen(_ sender: NSToolbarItem) {
        if model.tab == .settings { model.showWideMode(model.wideMode) } else { model.tab = .settings }
    }
}
#endif

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
    /// The place the Wide shape shows (docs/DESIGN.md › Tall and Wide). A paper's chat sits beside its paper, so the Chat
    /// tab with a paper's chat is the Paper place there; Chat is the general chat.
    var widePlace: ReaderTab { tab == .chat && !generalChat ? .paper : tab }

    /// The library's list beside the open paper, whose row is highlighted there: the iPad's Library place (Library |
    /// paper), the Mac's Browse (Library ⋯ › Show library beside paper).
    var browsing: Bool {
        guard !compactLayout else { return false }
        return Platform.isMac ? wideList == .papers && widePlace == .paper && !wideDiscuss : tab == .library
    }

    /// iPad Wide: the paper is in the Library's or the Feed's right slot, its list beside it (owner, 2026-10-23: "When you
    /// are in this mode, you are still technically in 'Library' view, just with a paper to the right").
    var paperBesideList: Bool {
        !compactLayout && !Platform.isMac && selectedPaper != nil && (tab == .library || (tab == .feed && feedReading))
    }

    /// Opening a paper: the Paper place. In iPad Wide's Discuss the paper is already beside the chat: a citation or a
    /// passage scrolls it in place and the chat stays (owner, 2026-10-22).
    func showPaperPlace() { if !discussShown { tab = .paper } }

    /// iPad Wide's Discuss is showing (the paper on the left, its chat on the right).
    var discussShown: Bool { !compactLayout && !Platform.isMac && wideDiscuss }

    /// The places menu's Search (owner, 2026-10-22: "search lives at the top of the left panel, like Mail"): the Library
    /// place with its field focused; results in its list, the one picked on the right.
    func searchFromPlaces() {
        if widePlace != .library { showPlace(.library) }
        MacCommandRequests.shared.librarySearch = UUID()
    }

    /// iPad Wide: "Paper can also be a left primary item" (owner, 2026-10-23). The paper's list toggle (Hide library, Hide
    /// feed) or dragging the divider past the list's minimum: the list slides away and the paper, the same view at the
    /// same place, becomes the Paper place. Its toggle (Show library, Show feed) returns it to where it came from.
    func promotePaper() {
        guard selectedPaper != nil else { return }
        if tab == .library || tab == .feed { paperOrigin = tab }
        tab = .paper
    }

    /// iPad Wide's Show library / Show feed: that list back on the left, the paper on its right, in the place it came from
    /// (the Library unless the paper was opened from the Feed). Contents or a companion beside the paper closes.
    func showListBesidePaper() {
        wideList = .none
        if paperOrigin == .feed { feedReading = true; tab = .feed } else { tab = .library }
    }

    /// iPad Wide: one of the paper's helpers (AI Explainer, the equation view, a figure page) opened in the companion slot
    /// on its right. The paper becomes the Paper place: a list beside it slides away, a chat gives the slot up (its draft
    /// stays) and Contents closes, so nothing adds a third column.
    func openCompanion() {
        guard !compactLayout, !Platform.isMac else { return }
        if tab == .library || tab == .feed { paperOrigin = tab; tab = .paper } else if wideDiscuss { tab = .paper }
        if wideList == .contents { wideList = .none }
    }

    /// Paper ⋯ › Show library beside paper (the Mac's View menu, and Library ⋯ there): the Mac's Papers list beside the
    /// paper (Browse); on iPad the list toggle's Show and Hide.
    func setLibraryBesidePaper(_ shown: Bool) {
        if !Platform.isMac {
            if shown { showListBesidePaper() } else { promotePaper() }
            return
        }
        wideList = shown ? .papers : .none
        if shown, widePlace != .paper || wideDiscuss { tab = .paper }
    }

    /// Wide ☰: Contents in the left slot beside the paper (Navigate), or closed. It takes the place of a chat or a list
    /// beside the paper (the paper becomes the Paper place).
    func toggleContentsPanel() {
        if wideDiscuss || paperBesideList {
            if paperBesideList { paperOrigin = tab }
            tab = .paper; wideList = .contents; return
        }
        wideList = wideList == .contents ? .none : .contents
    }

    /// A place chosen from the places menu (iPad Wide), the Mac toolbar or View menu. Tall is the tab as it is. Wide: Chat
    /// is the general chat (a paper's chat is the Paper place's right slot), and Paper is the paper as the left primary
    /// item, its chat ready to be its own. Each place keeps its selection (the Library's open paper, the Feed's picked
    /// article). Leaves Settings when it is showing.
    func showPlace(_ place: ReaderTab) {
        if !compactLayout {
            if place == .chat { generalChat = true }
            if place == .paper, chatPaperID != nil { generalChat = false }
        }
        tab = place
    }

    /// Discuss: the paper's chat is open (the paper on the left, the chat on the right).
    var wideDiscuss: Bool { tab == .chat && !generalChat }

    /// A figure page's choice made outside the paper's own sheets (Navigate's Contents in the left slot), as PaperView
    /// applies it when its sheet closes.
    func applyPendingFigureOutcome() {
        guard let outcome = takeFigureOutcome() else { return }
        switch outcome {
        case .figure(_, let id): if let key = readingLocationKey { paperJump = PaperJumpRequest(locationKey: key, headingID: id, target: .figure) }
        case .paragraph(let paperID, let marker): goToCitedBlock(marker, paperID: paperID)
        case .askInChat(let context, let part): askAboutFigure(context, part: part)
        case .signIn: openSignIn()
        case .continueChat: tab = .chat; readerChatHidden = false; requestComposerFocus()
        }
    }

    /// The open paper's reading key (PaperView's): a jump from the Contents in the left slot goes to this reader copy.
    var readingLocationKey: String? {
        guard let paper = selectedPaper else { return nil }
        return "\(paper.id.uuidString)/\(paper.artifactID?.uuidString ?? "unversioned")/\(paper.readerBundle?.manifestSHA256 ?? "unverified")"
    }

    /// The Mac's Settings in place of the window's panes (Done returns to where it was opened from).
    func showSettingsPlace() {
        if tab != .settings { placeBeforeSettings = widePlace }
        tab = .settings
    }
}

/// Requests from the menu bar to views that own the state (consumed once by the view).
@MainActor @Observable final class MacCommandRequests {
    static let shared = MacCommandRequests()
    /// Focus the Library's search field (⌘F), or its arXiv search (⌥⌘F).
    var librarySearch: UUID?
    /// Edit › Find in Paper: the open paper's view shows its find bar (with its own checks: a readable paper, the
    /// selection cleared).
    var findInPaper: UUID?
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
/// actions (owner feedback, build 16 #4/#5, replacing the bar that sat under the paper), with Focus (its own view; build 78)
/// right after Chat about Equation.
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
    /// "Focus" in a tapped equation's menu, right after Chat about Equation (owner, build 78: "Let's change AI explainer to
    /// Focus. Because in the first view you can see the equation up large which is helpful. In the next screen we should
    /// not necessarily assume they need an AI explainer"): opens the equation view for that equation, large, without
    /// asking for an explanation; its top row offers AI Explainer (docs/architecture/EQUATION_VIEW.md). Nil offers no such item.
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
        guard builder.system == .context else { return }
        if let menuAction, hasSelection || !Platform.isMac, builder.menu(for: Self.selectionMenuID) == nil {
            let menu = UIMenu(title: "", identifier: Self.selectionMenuID, options: .displayInline,
                              children: Self.actions(SelectionAction.allCases, run: menuAction))
            if builder.menu(for: .standardEdit) != nil { builder.insertSibling(menu, afterMenu: .standardEdit) }
            else { builder.insertChild(menu, atStartOfMenu: .root) }
        }
        // Notes (NOTES_AND_SNIPPETS.md): after the chat actions and separate from them (no AI, no credits). Add to note
        // keeps the selection as a quotation; Draw snippet is the contextual way into drawing a box (on the Mac, a
        // right-click anywhere on the page).
        var notes: [UIMenuElement] = []
        if let noteAction, hasSelection || !Platform.isMac {
            notes.append(UIAction(title: "Save snippet", image: UIImage(systemName: "note.text.badge.plus"),
                                  identifier: UIAction.Identifier("reader.selection.addToNote")) { _ in noteAction() })
        }
        if let drawSnippet {
            notes.append(UIAction(title: "Draw snippet", image: UIImage(systemName: "crop"),
                                  identifier: UIAction.Identifier("reader.drawSnippet")) { _ in drawSnippet() })
        }
        guard !notes.isEmpty, builder.menu(for: Self.notesMenuID) == nil else { return }
        let menu = UIMenu(title: "", identifier: Self.notesMenuID, options: .displayInline, children: notes)
        if builder.menu(for: Self.selectionMenuID) != nil { builder.insertSibling(menu, afterMenu: Self.selectionMenuID) }
        else if builder.menu(for: .standardEdit) != nil { builder.insertSibling(menu, afterMenu: .standardEdit) }
        else { builder.insertChild(menu, atEndOfMenu: .root) }
    }

    static let selectionMenuID = UIMenu.Identifier("gradstep.selection")
    static let notesMenuID = UIMenu.Identifier("gradstep.notes")
    /// Add to note on the selected text (the paper's own view).
    var noteAction: (() -> Void)?
    /// Draw snippet from the context menu (the paper's own view).
    var drawSnippet: (() -> Void)?
    /// Figure pages' views by figure ID, for a figure's Add to note (weak: a page that closes is gone).
    @MainActor static let figurePages = NSMapTable<NSString, ReaderWebView>.strongToWeakObjects()

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
            let view = UIAction(title: "Focus", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), identifier: UIAction.Identifier("reader.equation.view")) { [weak self] _ in
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

/// Configures the Mac window once it exists: size limits, a first-launch size, and a unified toolbar holding the five
/// places (Feed · Library · Paper · Chat · Snippets), which on iPad are the places capsule. Settings is the last row of
/// every ⋯ and ⌘, (docs/DESIGN.md › Tall and Wide).
struct MacWindowConfiguration: UIViewRepresentable {
    let model: ReaderModel
    let place: ReaderTab
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
        context.coordinator.update(place: place, settingsShown: settingsShown)
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
    private static let sizeKey = "mac.window.size"

    private let model: ReaderModel
    private weak var scene: UIWindowScene?
    /// Sizes are remembered only after the launch size is applied (the system's first size isn't the reader's).
    private var restoringSize = true
    private var modes: NSToolbarItemGroup?

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
        update(place: model.widePlace, settingsShown: model.tab == .settings)
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

    private static let places = ReaderTab.phoneTabs

    func update(place: ReaderTab, settingsShown: Bool) {
        guard modes != nil else { return }
        // Settings is outside the five workspace panes. Catalyst keeps reporting the last selected
        // index for a native select-one group, so use select-any and clear every segment explicitly.
        if settingsShown {
            setModeSelection(nil)
        } else {
            setModeSelection(Self.places.firstIndex(of: place) ?? 1)
        }
    }

    private func setModeSelection(_ index: Int?) {
        guard let modes else { return }
        for candidate in Self.places.indices {
            modes.setSelected(candidate == index, at: candidate)
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.modesID, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.modesID:
            let titles = Self.places.map(\.rawValue)
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: titles, selectionMode: .selectAny,
                                           labels: titles, target: self, action: #selector(modeChosen(_:)))
            group.controlRepresentation = .expanded
            group.label = "Places"
            group.toolTip = "Choose a place (⌘1–⌘5)"
            modes = group
            setModeSelection(Self.places.firstIndex(of: model.widePlace) ?? 1)
            return group
        default: return nil
        }
    }

    @objc private func modeChosen(_ sender: NSToolbarItemGroup) {
        guard Self.places.indices.contains(sender.selectedIndex) else { return }
        let index = sender.selectedIndex
        setModeSelection(index)
        model.showPlace(Self.places[index])
    }
}
#endif

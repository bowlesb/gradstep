import SwiftUI
import ScienceReaderCore

// Line width and reading mode (docs/architecture/READING_MODE.md). Owner, 2026-10-15: "when your reading space gets
// wider there should be new words on a line … there needs to be some option", and "a really good full screen reading
// mode for Mac app and web app that feels like a truly great experience". The measure is applied by the shared reader
// bridge (`__scienceReaderSetLineWidth`), never by the bundle's CSS; reading mode is the wide layout stepping aside.

/// The paper's text column: about 72 characters a line at every text size, about 100, or the window's width.
enum ReaderLineWidth: String, CaseIterable, Identifiable {
    case comfortable, wide, full
    var id: Self { self }
    var title: String { switch self { case .comfortable: "Comfortable"; case .wide: "Wide"; case .full: "Full width" } }
    /// The Mac menu's title case.
    var menuTitle: String { switch self { case .comfortable: "Comfortable"; case .wide: "Wide"; case .full: "Full Width" } }
    var detail: String {
        switch self {
        case .comfortable: "About 72 characters a line"
        case .wide: "About 100 characters a line"
        case .full: "Lines fill the window: wider means more words"
        }
    }
    var symbol: String {
        switch self { case .comfortable: "text.justify.leading"; case .wide: "text.justify"; case .full: "arrow.left.and.right.text.vertical" }
    }
}

/// What reading mode remembers between position reports (not observed: the bar shows only the section's title).
struct ReadingModeState {
    /// The block at the top of the paper being read, as the reader last reported it.
    var block: (paperID: UUID, index: Int)?
    /// The sections of the open paper's bundle, by its manifest.
    var sections: (manifest: String, list: [ReadingSections.Section])?
    /// The window was already full screen when reading mode began (leaving it then keeps the window full screen).
    var wasFullScreen = false
}

/// A paper's sections in reading order: its headings, each where it stands in the bundle's blocks (a heading's ID is
/// its block's ID).
enum ReadingSections {
    struct Section: Equatable { let id: String; let title: String; let block: Int }

    static func sections(headings: [(id: String, title: String)], blockIDs: [String]) -> [Section] {
        let position = Dictionary(blockIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return headings.compactMap { heading in position[heading.id].map { Section(id: heading.id, title: heading.title, block: $0) } }
            .sorted { $0.block < $1.block }
    }
    static func sections(in index: ReaderBundleIndex) -> [Section] {
        sections(headings: index.headings.map { ($0.id, $0.title) }, blockIDs: index.blocks.map(\.id))
    }
    /// The section a block belongs to: the last heading at or before it.
    static func current(_ sections: [Section], block: Int?) -> Section? {
        guard let block else { return nil }
        return sections.last { $0.block <= block }
    }
    /// The next (1) or previous (-1) section from the one being read; before the first heading, the first.
    static func step(_ sections: [Section], from block: Int?, by delta: Int) -> Section? {
        guard !sections.isEmpty else { return nil }
        guard let current = current(sections, block: block), let at = sections.firstIndex(of: current) else { return delta > 0 ? sections.first : nil }
        let target = at + delta
        return sections.indices.contains(target) ? sections[target] : nil
    }
}

extension ReaderModel {
    var canEnterReadingMode: Bool { selectedPaper?.readerBundle != nil }

    func enterReadingMode() {
        guard !readingMode, canEnterReadingMode else { return }
        readingChatShown = false
        if tab == .settings { tab = .paper }
        readingMode = true
        #if targetEnvironment(macCatalyst)
        readingState.wasFullScreen = MacFullScreen.isOn
        MacFullScreen.set(true)
        #endif
    }

    /// `leavingFullScreen`: false when the window has already left full screen by itself.
    func exitReadingMode(leavingFullScreen: Bool = true) {
        guard readingMode else { return }
        readingMode = false; readingChatShown = false
        #if targetEnvironment(macCatalyst)
        if leavingFullScreen && !readingState.wasFullScreen { MacFullScreen.set(false) }
        #endif
    }

    func toggleReadingMode() { if readingMode { exitReadingMode() } else { enterReadingMode() } }

    /// The place key the paper view saves under (PaperView.readingKey).
    func readingLocationKey(for paper: Paper) -> String {
        "\(paper.id.uuidString)/\(paper.artifactID?.uuidString ?? "unversioned")/\(paper.readerBundle?.manifestSHA256 ?? "unverified")"
    }

    private func readingSections(for paper: Paper) -> [ReadingSections.Section] {
        guard let bundle = paper.readerBundle else { return [] }
        if let cached = readingState.sections, cached.manifest == bundle.manifestSHA256 { return cached.list }
        let list = ReadingSections.sections(in: bundle.index)
        readingState.sections = (bundle.manifestSHA256, list)
        return list
    }

    /// Each position report from the open paper: the section being read, for the bar and for J / K.
    func noteReadingPosition(_ location: PaperReadingLocation, paperID: UUID) {
        guard let index = location.blockIndex, let paper = selectedPaper, paper.id == paperID else { return }
        readingState.block = (paperID, index)
        let title = ReadingSections.current(readingSections(for: paper), block: index)?.title
        if readingSectionTitle != title { readingSectionTitle = title }
    }

    /// J / K (and Paper › Next Section on the Mac): the next or previous section from the one being read.
    func stepSection(_ delta: Int) {
        guard let paper = selectedPaper, paper.readerBundle != nil else { return }
        let block = readingState.block?.paperID == paper.id ? readingState.block?.index : nil
        guard let target = ReadingSections.step(readingSections(for: paper), from: block, by: delta) else { return }
        paperJump = PaperJumpRequest(locationKey: readingLocationKey(for: paper), headingID: target.id)
    }
}

#if targetEnvironment(macCatalyst)
/// Window full screen from Mac Catalyst, which has no API of its own: AppKit's public `-[NSWindow toggleFullScreen:]`
/// (what View › Enter Full Screen sends), reached through the runtime.
@MainActor enum MacFullScreen {
    static let didExit = Notification.Name("NSWindowDidExitFullScreenNotification")
    private static var window: NSObject? {
        guard let application = NSClassFromString("NSApplication").map({ $0 as AnyObject }),
              let shared = application.value(forKey: "sharedApplication") as? NSObject else { return nil }
        return (shared.value(forKey: "keyWindow") as? NSObject) ?? (shared.value(forKey: "mainWindow") as? NSObject)
    }
    static var isOn: Bool {
        guard let mask = window?.value(forKey: "styleMask") as? UInt else { return false }
        return mask & (1 << 14) != 0 // NSWindowStyleMaskFullScreen
    }
    static func set(_ on: Bool) {
        guard let window, isOn != on else { return }
        window.perform(NSSelectorFromString("toggleFullScreen:"), with: nil)
    }
}
#endif

/// iPad and Mac: the paper in the wide layout, where line width and reading mode apply (a phone's column is the
/// same at every measure).
private struct WideReaderKey: EnvironmentKey { static let defaultValue = false }
/// The paper inside reading mode: its bar is the quiet one, its toolbar steps aside.
private struct ReadingModeActiveKey: EnvironmentKey { static let defaultValue = false }
/// The chat over the paper's trailing side in reading mode: the bar keeps clear of it.
private struct ReadingChatInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var wideReader: Bool { get { self[WideReaderKey.self] } set { self[WideReaderKey.self] = newValue } }
    var readingModeActive: Bool { get { self[ReadingModeActiveKey.self] } set { self[ReadingModeActiveKey.self] = newValue } }
    var readingChatInset: CGFloat { get { self[ReadingChatInsetKey.self] } set { self[ReadingChatInsetKey.self] = newValue } }
}

/// ⇧⌘R on an iPad's keyboard; the Mac's View menu has its own.
struct ReadingModeShortcut: ViewModifier {
    func body(content: Content) -> some View {
        if Platform.isMac { content } else { content.keyboardShortcut("r", modifiers: [.command, .shift]) }
    }
}

/// Line width: a menu of the three measures, beside A− / A+.
struct LineWidthMenu: View {
    @Binding var selection: ReaderLineWidth
    var identifier = "paper.lineWidth"
    var body: some View {
        Menu {
            Picker("Line width", selection: $selection) {
                ForEach(ReaderLineWidth.allCases) { width in
                    Label { Text(width.title); Text(width.detail) } icon: { Image(systemName: width.symbol) }.tag(width)
                }
            }
        } label: {
            Image(systemName: "arrow.left.and.right.text.vertical").font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 40).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .accessibilityLabel("Line width").accessibilityValue(selection.title)
        .accessibilityIdentifier(identifier)
        .help("Line width: \(selection.title)")
    }
}

/// Reading mode: the paper alone, full screen on the Mac, with the chat sliding over it when asked for (it never
/// reflows the paper, so the place stays). Esc closes the chat, then leaves.
struct ReadingModeView: View {
    @Bindable var model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let chatWidth = min(460, max(320, geometry.size.width * 0.36))
            ZStack(alignment: .trailing) {
                PaperView(model: model).environment(\.readingModeActive, true)
                    .environment(\.readingChatInset, model.readingChatShown ? chatWidth : 0)
                if model.readingChatShown {
                    ChatView(model: model)
                        .environment(\.chatBesidePaper, true)
                        .frame(width: chatWidth)
                        .background(Color(uiColor: .systemBackground))
                        .overlay(alignment: .leading) { Divider() }
                        .shadow(color: .black.opacity(0.16), radius: 24, x: -6)
                        .transition(.move(edge: .trailing))
                        .accessibilityIdentifier("reading.chat")
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.readingChatShown)
        .background {
            Button("Close") { if model.readingChatShown { model.readingChatShown = false } else { model.exitReadingMode() } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #if targetEnvironment(macCatalyst)
        // Leaving full screen the Mac's way (the green button, ⌃⌘F) leaves reading mode too.
        .onReceive(NotificationCenter.default.publisher(for: MacFullScreen.didExit)) { _ in
            if model.readingMode { model.exitReadingMode(leavingFullScreen: false) }
        }
        #endif
    }
}

/// Reading mode's bar over the top of the paper: shown on entering (so it can be found), when the pointer comes near
/// the top edge or a tap lands there, and while Back is offered or the chat is over the paper. Reading on (scrolling)
/// puts it away, as in Books; a tap's bar stays a while so its menus can be used, a pointer's while it is over it.
struct ReadingTopBar: View {
    @Bindable var model: ReaderModel
    let title: String
    /// Back (or Find) is offered: the bar stays.
    let forced: Bool
    let contents: () -> Void
    let figures: (() -> Void)?
    @State private var shown = true
    @State private var hovering = false
    @State private var hide: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.readingChatInset) private var chatInset

    /// Back offered, the chat over the paper (its toggle stays in reach), or VoiceOver: the bar stays.
    private var visible: Bool { shown || forced || voiceOver || model.readingChatShown }
    private var percent: Int? {
        model.selectedPaper.flatMap { model.readingActivity[$0.id]?.progress }.map { Int(($0 * 100).rounded(.down)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let percent {
                GeometryReader { proxy in
                    Rectangle().fill(Color.accentColor.opacity(0.65)).frame(width: proxy.size.width * CGFloat(percent) / 100)
                }.frame(height: 2).accessibilityHidden(true)
            }
            ZStack(alignment: .top) {
                // The edge that brings the bar back: a pointer near it, or a tap.
                Color.clear.frame(height: 28).contentShape(Rectangle())
                    .onContinuousHover { phase in if case .active = phase { reveal(hold: false) } else if !hovering { hideSoon() } }
                    .onTapGesture { reveal(hold: true, for: .seconds(10)) }
                    .accessibilityHidden(true)
                if visible { bar.transition(.opacity.combined(with: .move(edge: .top))) }
            }
        }
        .padding(.trailing, chatInset)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visible)
        .onAppear { reveal(hold: true) }
        // The chat going away leaves the bar a moment (its toggle was just used), not gone at once.
        .onChange(of: model.readingChatShown) { _, shown in if !shown { reveal(hold: true) } }
        // Reading on puts it away (not under a pointer, nor while Back or the chat keep it).
        .onChange(of: percent) { _, _ in if shown && !hovering { hideSoon(after: .milliseconds(400)) } }
        .onDisappear { hide?.cancel() }
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Button { model.exitReadingMode() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 40, height: 40) }
                .accessibilityLabel("Exit reading mode").accessibilityIdentifier("reading.exit").help("Exit reading mode (Esc)")
            Button(action: contents) { Image(GradstepSymbol.contents).frame(width: 40, height: 40) }
                .accessibilityLabel("Table of contents").accessibilityIdentifier("reading.contents")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let section = model.readingSectionTitle { Text(section).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("reading.section")
            Spacer(minLength: 8)
            if let percent {
                Text("\(percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityLabel("\(percent) percent read")
            }
            if let figures {
                Button(action: figures) { Image(systemName: "photo.on.rectangle").frame(width: 40, height: 40) }
                    .accessibilityLabel("Figures").accessibilityIdentifier("reading.figures")
            }
            Button { model.paperFontSize = max(14, model.paperFontSize - 1) } label: { Image(systemName: "textformat.size.smaller").frame(width: 36, height: 40) }
                .disabled(model.paperFontSize <= 14).accessibilityLabel("Smaller text")
            Button { model.paperFontSize = min(26, model.paperFontSize + 1) } label: { Image(systemName: "textformat.size.larger").frame(width: 36, height: 40) }
                .disabled(model.paperFontSize >= 26).accessibilityLabel("Larger text")
            LineWidthMenu(selection: $model.paperLineWidth, identifier: "reading.lineWidth")
            Button { model.readingChatShown.toggle() } label: { Image(GradstepSymbol.chat).frame(width: 40, height: 40) }
                .accessibilityLabel(model.readingChatShown ? "Hide chat" : "Ask in chat").accessibilityIdentifier("reading.chat.toggle")
                .help("Ask in chat (⌃⌘H)")
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .chromeSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 6)
        .frame(maxWidth: 980)
        .onHover { inside in hovering = inside; if inside { reveal(hold: false) } else { hideSoon() } }
        // Using the bar keeps it (a menu opened from it would close with it).
        .simultaneousGesture(TapGesture().onEnded { reveal(hold: true, for: .seconds(10)) })
        .accessibilityElement(children: .contain).accessibilityIdentifier("reading.bar")
    }

    private func reveal(hold: Bool, for delay: Duration = .milliseconds(2500)) {
        hide?.cancel(); shown = true
        if hold { hideSoon(after: delay) }
    }
    private func hideSoon(after delay: Duration = .milliseconds(1200)) {
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { shown = false }
        }
    }
}

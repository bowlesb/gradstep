import SwiftUI
import WebKit
import ScienceReaderCore

/// Reading state for one immutable document artifact. It contains no paper text. Kept per
/// account on this device (ReadingActivityStore), never sent to the server.
struct PaperReadingLocation: Equatable {
    let blockIndex: Int?
    let blockFraction: Double
    let blockHeight: Double
    let scrollY: Double
    /// 0…1 through the document at this position, when the reader reported it.
    var progress: Double? = nil

    fileprivate func adjusted(by delta: Double) -> Self {
        Self(blockIndex: blockIndex, blockFraction: blockFraction + delta / max(1, blockHeight),
             blockHeight: blockHeight, scrollY: max(0, scrollY + delta), progress: progress)
    }
}

struct PaperJumpRequest: Equatable, Identifiable {
    let id = UUID()
    let locationKey: String
    let headingID: String
}

struct PaperHeading: Equatable, Identifiable {
    let id: String
    let title: String
}

private struct PaperLoadIdentity: Hashable {
    let scope: ReaderDocumentScope
    let revision: UUID
}

/// A bibliography entry the reader tapped (reader-bridge.js): its text as shown, the best
/// link it names, and where it is on screen (to anchor the actions).
struct ReaderReference: Identifiable, Equatable {
    struct Link: Equatable {
        let url: URL
        let title: String
    }

    let id = UUID()
    let title: String
    let text: String
    let link: Link?
    let anchor: CGRect

    /// Accepts only a well-formed message for a block of this verified bundle.
    init?(message body: [String: Any], bundle: VerifiedReaderBundle, viewport: CGSize) {
        guard body["manifest_sha256"] as? String == bundle.manifestSHA256, let block = body["block_id"] as? String,
              bundle.index.blocks.contains(where: { $0.id == block }),
              let raw = body["text"] as? String, raw.utf8.count <= 16_000 else { return nil }
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if let number = body["number"] as? Int, (0...99_999).contains(number) { title = "Reference \(number)" }
        else if let label = body["label"] as? String, (1...24).contains(label.count) { title = "Reference \(label)" }
        else { title = "Reference" }
        self.text = text
        let hrefs = (body["links"] as? [String] ?? []).prefix(8)
        link = Self.link(in: text, hrefs: Array(hrefs))
        let rect = body["rect"] as? [String: Double] ?? [:]
        let values = ["x", "y", "width", "height"].map { rect[$0] ?? 0 }
        let bounds = CGRect(origin: .zero, size: viewport)
        anchor = values.allSatisfy(\.isFinite)
            ? CGRect(x: values[0], y: values[1], width: max(1, values[2]), height: max(1, values[3])).intersection(bounds) : .null
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The entry's best destination: its arXiv paper, then its DOI, then a web address.
    static func link(in text: String, hrefs: [String]) -> Link? {
        let lowered = text.lowercased()
        if lowered.contains("arxiv") || lowered.contains("corr") {
            for match in text.matches(of: #/(\d{2})(\d{2})\.(\d{4,5})(v\d{1,3})?(?!\d)/#) {
                let before = match.range.lowerBound == text.startIndex ? nil : text[text.index(before: match.range.lowerBound)]
                guard before.map({ !$0.isNumber && $0 != "." }) ?? true,
                      let year = Int(match.output.1), let month = Int(match.output.2), year >= 7, (1...12).contains(month) else { continue }
                let id = "\(match.output.1)\(match.output.2).\(match.output.3)\(match.output.4 ?? "")"
                if let url = URL(string: "https://arxiv.org/abs/" + id) { return Link(url: url, title: "Open on arXiv") }
            }
        }
        if let match = text.firstMatch(of: #/\b(10\.\d{4,9}/[^\s"<>]+)/#) {
            var doi = String(match.output.1)
            while let last = doi.last, ".,;:]".contains(last) || (last == ")" && doi.filter({ $0 == "(" }).count < doi.filter({ $0 == ")" }).count) {
                doi.removeLast()
            }
            if let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://doi.org/" + path) {
                return Link(url: url, title: "Open DOI")
            }
        }
        let candidates = hrefs + text.matches(of: #/https://[^\s<>"]+/#).map { String($0.output) }
        for candidate in candidates {
            var value = candidate
            while let last = value.last, ".,;:)]".contains(last) { value.removeLast() }
            guard let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false, url.user == nil else { continue }
            return Link(url: url, title: "Open link")
        }
        return nil
    }
}

struct PaperView: View {
    @Bindable var model: ReaderModel
    @State private var showContents = false
    @State private var selection: ReaderSelection?
    @State private var readerFailed = false
    @State private var reloadID = UUID()
    @State private var selectionClearID = UUID()
    @State private var figure: String?
    @State private var loadingPaper = true
    /// After following a citation: offer "Back" to the place left.
    @State private var citationBack = false
    @State private var citationReturnID: UUID?
    @State private var reference: ReaderReference?
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

    private var readingKey: String? {
        guard let paper = model.selectedPaper else { return nil }
        return "\(paper.id.uuidString)/\(paper.artifactID?.uuidString ?? "unversioned")/\(paper.readerBundle?.manifestSHA256 ?? "unverified")"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let paper = model.selectedPaper, let bundle = paper.readerBundle, let readingKey, let readerScope = model.readerDocumentScope {
                    // Floating chrome (2026-10-07): the tab bar and the reader's controls float on a band below the
                    // page, which fades its last lines. The page itself stops above them: reading positions,
                    // heading and citation jumps are measured in the page's own viewport, which must be what shows.
                    Group {
                        PaperWebView(url: bundle.entryURL, bundle: bundle, locationKey: readingKey,
                                     location: paper.artifactID == nil ? nil : model.paperLocations[readingKey],
                                     fontSize: model.paperFontSize * bodySize / 17, jump: model.paperJump,
                                     reduceMotion: reduceMotion, selectionClearID: selectionClearID, onLoading: {
                                         if model.readerDocumentScope == readerScope { loadingPaper = $0 }
                                     },
                                     onLocation: { key, location in
                                         // A sign-out clears the selection and the account's transient state.
                                         guard model.readerSessionID == readerScope.sessionID, model.selectedPaper != nil, paper.artifactID != nil else { return }
                                         model.recordReadingLocation(location, key: key, documentID: paper.id)
                                     }, onJumpApplied: { id in
                                         if model.paperJump?.id == id { model.paperJump = nil }
                                     },
                                     onSelection: {
                                         if model.readerDocumentScope == readerScope { selection = $0 }
                                     }, onHeadings: {
                                         if model.readerDocumentScope == readerScope { model.headings = $0 }
                                     }, onFigure: {
                                         if model.readerDocumentScope == readerScope {
                                             #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
                                             OfflineResourceProbe.shared.begin(.figure)
                                             #endif
                                             figure = $0
                                         }
                                     }, onFailure: {
                                         if model.readerDocumentScope == readerScope {
                                             readerFailed = true; selection = nil; model.headings = []; citationBack = false; reference = nil
                                         }
                                     }, onReady: {
                                         #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
                                         if model.readerDocumentScope == readerScope { OfflineResourceProbe.shared.finish(.readerReady) }
                                         #endif
                                     }, paperLine: paper.publicationLine, citationReturnID: citationReturnID, onCitation: { active in
                                         if model.readerDocumentScope == readerScope { citationBack = active }
                                     }, onReference: { value in
                                         if model.readerDocumentScope == readerScope { reference = value }
                                     }, selectionAction: selection == nil ? nil : { action in
                                         runSelectionAction(action, scope: readerScope)
                                     })
                            .id(PaperLoadIdentity(scope: readerScope, revision: reloadID))
                            .overlay(alignment: .topLeading) { referenceActions }
                    }
                    .overlay { if readerFailed {
                        ContentUnavailableView { Label("Couldn’t open this paper", systemImage: "doc.badge.ellipsis") }
                            description: { Text("The reading bundle couldn’t be loaded completely.") }
                            actions: { Button("Try again") { readerFailed = false; loadingPaper = true; reloadID = UUID() } }
                            .background(Color(uiColor: .systemBackground))
                    } }
                    .overlay { if loadingPaper { ProgressView("Opening paper…").allowsHitTesting(false) } }
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls(scope: readerScope) }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: citationBack)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection == nil)
                    .macPaperMenu(PaperMenuActions(
                        contents: { showContents = true },
                        back: citationBack && !readerFailed ? { citationBack = false; citationReturnID = UUID() } : nil,
                        selection: selection == nil ? nil : { runSelectionAction($0, scope: readerScope) }))
                } else if model.selectedPaper != nil {
                    if model.openingPaperID == model.selectedPaper?.id {
                        ProgressView("Opening paper…").accessibilityIdentifier("paper.openingLocalCopy")
                    } else if let issue = model.readerOpenIssue {
                        ContentUnavailableView { Label("Couldn’t open this paper", systemImage: "doc.badge.ellipsis") }
                            description: { Text(issue) }
                            actions: { Button("Try again") { model.retryOpeningSelectedPaper() } }
                    } else {
                        ContentUnavailableView("Paper download needed", systemImage: "arrow.down.document", description: Text("Download this paper’s complete reading bundle to open it offline."))
                    }
                } else {
                    ContentUnavailableView("Open a paper", image: GradstepSymbol.paper, description: Text("Choose a paper from your library to start reading."))
                }
            }
            .tabBarSpace(fade: false)
            .navigationTitle("Paper").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showContents = true } label: { Image(GradstepSymbol.contents) }.accessibilityLabel("Table of contents").disabled(model.selectedPaper == nil) }
                ToolbarItem(placement: .principal) { titleView }
                // Screen options (docs/DESIGN.md): "…" is the rightmost item; view choices first,
                // then this screen's actions, then "Report this screen".
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // One row: smaller A, larger A.
                        ControlGroup {
                            MenuRow("Smaller text", systemImage: "textformat.size.smaller") { model.paperFontSize = max(14, model.paperFontSize - 1) }
                                .disabled(model.paperFontSize <= 14)
                            MenuRow("Larger text", systemImage: "textformat.size.larger") { model.paperFontSize = min(26, model.paperFontSize + 1) }
                                .disabled(model.paperFontSize >= 26)
                        }
                        .controlGroupStyle(.compactMenu)
                        MenuRow("Ask about this paper", systemImage: GradstepSymbol.chat) { model.askAboutSelectedPaper() }
                        MenuRow("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Paper options")
                }
            }
            .sheet(isPresented: $showContents) {
                NavigationStack {
                    List(model.headings) { heading in
                        Button(heading.title) {
                            if let readingKey { model.paperJump = PaperJumpRequest(locationKey: readingKey, headingID: heading.id) }
                            showContents = false
                        }
                    }.navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showContents = false } } }
                }.presentationDetents([.medium, .large]).macSheetKeys()
            }
            .sheet(isPresented: Binding(get: { figure != nil }, set: { if !$0 { figure = nil } })) {
                NavigationStack {
                    Group {
                        if let figure, let bundle = model.selectedPaper?.readerBundle, let scope = model.readerDocumentScope {
                            FigureWebView(bundle: bundle, figureID: figure, baseFontSize: model.paperFontSize, onReady: {
                                #if (DEBUG || OFFLINE_RESOURCE_MEASUREMENTS) && FIXTURE_HOST
                                if model.readerDocumentScope == scope, self.figure == figure { OfflineResourceProbe.shared.finish(.figure) }
                                #endif
                            })
                        }
                        else { Color.clear }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { figure = nil } } }
                }.macSheetKeys()
            }
        }
        .onChange(of: model.readerDocumentScope) { _, _ in
            selection = nil; figure = nil; showContents = false; readerFailed = false
            citationBack = false; reference = nil; model.referenceNotice = nil
            loadingPaper = model.selectedPaper?.readerBundle != nil
        }
    }

    /// The reader's floating bottom controls (a reference's outcome, Back after a citation, the selection
    /// actions), over the paper's fade; with none showing, the fade alone (under the tab bar).
    private func bottomControls(scope: ReaderDocumentScope) -> some View {
        let notice = readerFailed ? nil : model.referenceNotice
        let back = citationBack && !readerFailed
        return VStack(spacing: 8) {
            if let notice { referenceBanner(notice) }
            if back { citationBackButton }
            if let selection { selectionControls(selection, scope: scope) }
        }
        .padding(.top, notice != nil || back || selection != nil ? 6 : 0)
        .padding(.bottom, notice != nil || back || selection != nil ? 8 : 0)
        .frame(maxWidth: .infinity)
        .chromeBand(.bottom)
    }

    // MARK: - Citations and references

    /// The outcome of "Add to library" on a reference. Success clears itself; a reference the
    /// server can't identify offers the chat, which searches more widely.
    private func referenceBanner(_ notice: ReaderModel.ReferenceNotice) -> some View {
        let problem = notice.kind == .notFound || notice.kind == .unavailable || notice.kind == .closed
        return StatusBanner(tone: problem ? .problem : .info,
                            systemImage: notice.kind == .working ? "arrow.down.circle" : problem ? "exclamationmark.circle" : "checkmark.circle",
                            message: notice.message, actionsBelow: notice.kind == .notFound, messageID: "reader.reference.notice") {
            if notice.kind == .notFound {
                Button("Ask in chat") { model.referenceNotice = nil; model.selectionAction(.ingest, quote: notice.reference) }
            } else if notice.kind == .unavailable {
                Button("Try again") { Task { await model.addReference(notice.reference) } }
            }
            if notice.kind != .working {
                Button { model.referenceNotice = nil } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                    .accessibilityLabel("Dismiss").tint(.secondary)
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .transition(.opacity)
        .task(id: notice.id) {
            guard notice.kind == .added || notice.kind == .present else { return }
            try? await Task.sleep(for: .seconds(6))
            if model.referenceNotice?.id == notice.id { model.referenceNotice = nil }
        }
    }

    /// Floats over the bottom of the paper after a citation jump; returns to the exact place.
    private var citationBackButton: some View {
        Button {
            citationBack = false; citationReturnID = UUID()
        } label: {
            Label("Back", systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .modifier(ReaderControlMaterial())
        .accessibilityIdentifier("reader.citation.back")
        .accessibilityHint("Returns to where you were reading")
        .transition(.opacity)
    }

    /// The actions for a tapped reference, anchored to the entry (a popover on iPad).
    private var referenceActions: some View {
        GeometryReader { proxy in
            let anchor = reference?.anchor ?? .null
            let rect = anchor.isNull || anchor.isEmpty ? CGRect(x: proxy.size.width / 2, y: proxy.size.height / 2, width: 1, height: 1) : anchor
            Color.clear
                .frame(width: rect.width, height: rect.height)
                .confirmationDialog(reference?.title ?? "Reference", isPresented: Binding(
                    get: { reference != nil }, set: { if !$0 { reference = nil } }), titleVisibility: .visible, presenting: reference) { value in
                    if let link = value.link {
                        Button(link.title) { openURL(link.url) }
                    }
                    Button("Add to library") { Task { await model.addReference(value.text) } }
                    Button("Copy") { UIPasteboard.general.string = value.text }
                    Button("Cancel", role: .cancel) {}
                } message: { value in
                    Text(value.text)
                }
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }

    /// The paper's title, with "Offline sample" as a small second line rather than a separate band.
    private var titleView: some View {
        VStack(spacing: 0) {
            Text(model.selectedPaper?.title ?? "Paper").font(.subheadline.weight(.semibold)).lineLimit(1)
            if model.selectedPaper?.isSample == true {
                Text("Offline sample").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        // Both lines stay inside the bar at large text sizes, as the system's own bar titles do.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func selectionControls(_ selection: ReaderSelection, scope: ReaderDocumentScope) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(SelectionAction.allCases, id: \.self) { selectionButton($0, selection: selection, scope: scope) }
                clearSelectionButton
            }
            HStack(spacing: 12) {
                Grid(horizontalSpacing: 20, verticalSpacing: 4) {
                    GridRow {
                        selectionButton(.define, selection: selection, scope: scope)
                        selectionButton(.relevance, selection: selection, scope: scope)
                    }
                    GridRow {
                        selectionButton(.similar, selection: selection, scope: scope)
                        selectionButton(.ingest, selection: selection, scope: scope)
                    }
                }
                clearSelectionButton
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack { selectionButton(.define, selection: selection, scope: scope, expanded: true); clearSelectionButton }
                ForEach([SelectionAction.relevance, .similar, .ingest], id: \.self) {
                    selectionButton($0, selection: selection, scope: scope, expanded: true)
                }
            }
        }
        // iPhone: a full-width bar, so every action is easy to reach. iPad: the bar fits its
        // content rather than stretching a band of glass around four words.
        .padding(.horizontal, 12).padding(.vertical, 4).frame(maxWidth: horizontalSizeClass == .regular ? nil : .infinity)
        .modifier(ReaderControlMaterial()).padding(.horizontal, 12).transition(.opacity)
    }

    /// The selection bar, the Mac's context menu and its Paper menu run the same action.
    private func runSelectionAction(_ action: SelectionAction, scope: ReaderDocumentScope) {
        guard let selection else { return }
        model.selectionAction(action, selection: selection, scope: scope)
        self.selection = nil; selectionClearID = UUID()
    }

    private func selectionButton(_ action: SelectionAction, selection: ReaderSelection, scope: ReaderDocumentScope, expanded: Bool = false) -> some View {
        Button {
            model.selectionAction(action, selection: selection, scope: scope)
            self.selection = nil; selectionClearID = UUID()
        } label: {
            Text(action.title).font(.subheadline.weight(.semibold)).fixedSize()
                .frame(minWidth: 44, maxWidth: expanded ? .infinity : nil, minHeight: 44, alignment: expanded ? .leading : .center)
                .contentShape(Rectangle())
        }.accessibilityIdentifier("reader.selection." + action.rawValue.lowercased())
    }

    private var clearSelectionButton: some View {
        Button { selection = nil; selectionClearID = UUID() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
            .accessibilityLabel("Clear selection").accessibilityIdentifier("reader.selection.clear")
    }
}

struct PaperWebView: UIViewRepresentable {
    let url: URL
    var bundle: VerifiedReaderBundle? = nil
    var figureID: String? = nil
    let locationKey: String
    let location: PaperReadingLocation?
    let fontSize: Double
    let jump: PaperJumpRequest?
    let reduceMotion: Bool
    var selectionClearID: UUID? = nil
    let onLoading: (Bool) -> Void
    let onLocation: (String, PaperReadingLocation) -> Void
    let onJumpApplied: (UUID) -> Void
    let onSelection: (ReaderSelection?) -> Void
    let onHeadings: ([PaperHeading]) -> Void
    let onFigure: (String) -> Void
    var onFailure: () -> Void = {}
    var onReady: () -> Void = {}
    /// One secondary line under the authors (year · venue · source); nil shows none.
    var paperLine: String? = nil
    /// A new value returns from a citation jump to the reading position.
    var citationReturnID: UUID? = nil
    /// True while the reader can go back from a citation jump.
    var onCitation: (Bool) -> Void = { _ in }
    var onReference: (ReaderReference) -> Void = { _ in }
    /// While text is selected: runs a selection action (the Mac's context menu for the selection).
    var selectionAction: ((SelectionAction) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    /// One ephemeral (never persisted) store for every reader page: a new store per
    /// page made WebKit start fresh support processes on each open.
    @MainActor static let dataStore = WKWebsiteDataStore.nonPersistent()
    static let bridgeScript = Bundle.main.url(forResource: "reader-bridge", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    @MainActor private static var warm: WKWebView?

    /// Starts WebKit's processes once, just after launch, so the first paper
    /// opened doesn't pay for them (~1–3 s measured on the first open).
    @MainActor static func prewarm() {
        guard warm == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        warm = web
    }

    func makeUIView(context: Context) -> WKWebView {
        SessionTimeline.shared.record("reader", ["phase": "create"])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let bundle { configuration.setURLSchemeHandler(ReaderBundleSchemeHandler(bundle: bundle), forURLScheme: "reader-bundle") }
        let script = Self.bridgeScript
        var info: [String: Any] = [:]
        if let bundle, let indexData = try? JSONEncoder().encode(bundle.index),
           let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any] {
            info = index; info["manifest_sha256"] = bundle.manifestSHA256
            if let figureID { info["figure_id"] = figureID }
        }
        let json = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
        // The line is placed before the first layout, so restoring a position never shifts.
        let line = figureID == nil ? paperLine.flatMap { try? JSONEncoder().encode($0) } : nil
        context.coordinator.appliedPaperLine = line == nil ? nil : paperLine
        let prelude = "window.__readerBundleConfig = " + (bundle == nil ? "null" : String(decoding: json, as: UTF8.self)) + ";\n"
            + "window.__readerPaperLine = " + (line.map { String(decoding: $0, as: UTF8.self) } ?? "null") + ";\n"
        configuration.userContentController.addUserScript(WKUserScript(source: prelude + script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "reader")
        let web = ReaderWebView(frame: .zero, configuration: configuration)
        if figureID == nil { ReaderWebView.paper = web }
        web.isOpaque = false; web.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        web.navigationDelegate = context.coordinator
        #if DEBUG
        web.isInspectable = true
        #endif
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        (web as? ReaderWebView)?.selectionAction = selectionAction
        if context.coordinator.loadedURL != url {
            context.coordinator.ready = false
            context.coordinator.loadedURL = url
            context.coordinator.invalidateLoad()
            SessionTimeline.shared.record("reader", ["phase": "request"])
            if bundle != nil { context.coordinator.navigation = web.load(URLRequest(url: url)) }
            else { context.coordinator.navigation = web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        }
        guard context.coordinator.ready else { return }
        context.coordinator.clearSelectionIfNeeded(in: web)
        context.coordinator.returnFromCitationIfNeeded(in: web)
        context.coordinator.applyPaperLine(in: web)
        // Math fit depends on the text size, so refit only when it changes
        // (compared here: WebKit rounds the size it stores).
        if context.coordinator.appliedFontSize != fontSize {
            context.coordinator.appliedFontSize = fontSize
            web.callAsyncJavaScript("document.documentElement.style.fontSize = size + 'px'; window.__scienceReaderFit?.();",
                                    arguments: ["size": fontSize], in: nil, in: .defaultClient, completionHandler: nil)
        }
        context.coordinator.applyJump(in: web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.saveFinalLocation(in: web)
        coordinator.active = false
        web.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
        web.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: PaperWebView
        var loadedURL: URL?
        var ready = false
        var active = true
        var navigation: WKNavigation?
        var appliedFontSize: Double?
        private var loadingID = UUID()
        private var inFlightJumpID: UUID?
        private var lastJumpID: UUID?
        private var latestLocation: PaperReadingLocation?
        private var sampledOffsetY = 0.0
        private var lastSelectionClearID: UUID?
        private var lastCitationReturnID: UUID?
        /// After a citation jump the saved place stays where reading left off.
        private var citationActive = false
        var appliedPaperLine: String?
        init(_ parent: PaperWebView) {
            self.parent = parent; lastSelectionClearID = parent.selectionClearID; lastCitationReturnID = parent.citationReturnID
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "selection":
                guard ready, let bundle = parent.bundle, let value = body["selection"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value),
                      data.count <= 100_000, let selection = try? JSONDecoder().decode(ReaderSelection.self, from: data),
                      let quote = try? selection.resolvedQuote(in: bundle), !quote.isEmpty else { parent.onSelection(nil); return }
                parent.onSelection(selection)
            case "headings":
                if let items = body["items"] as? [[String: String]], items.count <= 500 {
                    let headings = items.compactMap { item -> PaperHeading? in
                        guard let id = item["id"], !id.isEmpty, id.utf8.count <= 2_048,
                              let title = item["title"], !title.isEmpty, title.utf8.count <= 8_000 else { return nil }
                        return PaperHeading(id: id, title: title)
                    }
                    guard headings.count == items.count, Set(headings.map(\.id)).count == headings.count else { return }
                    parent.onHeadings(headings)
                }
            case "figure":
                if ready, let bundle = parent.bundle, body["manifest_sha256"] as? String == bundle.manifestSHA256,
                   let id = body["id"] as? String, bundle.index.figures.contains(where: { $0.id == id }) { parent.onFigure(id) }
            case "invalid": invalidateLoad(); navigation = nil; parent.onLoading(false); parent.onFailure()
            case "position": if ready, let web = message.webView { remember(body, in: web) }
            case "citation":
                guard ready, let state = body["state"] as? String, state == "jumped" || state == "ended" else { return }
                citationActive = state == "jumped"
                parent.onCitation(citationActive)
            case "reference":
                guard ready, let bundle = parent.bundle, let size = message.webView?.bounds.size,
                      let reference = ReaderReference(message: body, bundle: bundle, viewport: size) else { return }
                parent.onReference(reference)
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active, navigation === self.navigation else { return }
            let load = loadingID
            let location: Any
            if let saved = parent.location {
                location = ["block": saved.blockIndex ?? -1, "fraction": saved.blockFraction, "y": saved.scrollY] as [String: Any]
            } else { location = NSNull() }
            let arguments: [String: Any] = ["size": parent.fontSize, "location": location]
            webView.callAsyncJavaScript("""
                document.documentElement.style.fontSize = size + 'px';
                await window.__scienceReaderReady;
                await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
                window.__scienceReaderFit?.();
                if (location) window.__scienceReaderRestore(location);
                return window.__scienceReaderLocation();
                """, arguments: arguments, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                    guard let self, let webView, self.active, self.loadingID == load else { return }
                    guard case .success(let value) = result, let body = value as? [String: Any] else {
                        self.parent.onLoading(false); self.parent.onFailure(); return
                    }
                    self.ready = true
                    SessionTimeline.shared.record("reader", ["phase": "ready"])
                    self.appliedFontSize = arguments["size"] as? Double
                    self.remember(body, in: webView)
                    self.parent.onLoading(false)
                    self.parent.onReady()
                    self.applyJump(in: webView)
                }
        }

        func applyJump(in web: WKWebView) {
            guard active, ready, inFlightJumpID == nil, let request = parent.jump,
                  request.locationKey == parent.locationKey, request.id != lastJumpID else { return }
            inFlightJumpID = request.id
            let load = loadingID
            web.callAsyncJavaScript("""
                return window.__scienceReaderJumpToHeading(id,reduced);
                """, arguments: ["id": request.headingID, "reduced": parent.reduceMotion], in: nil, in: .defaultClient) { [weak self, weak web] result in
                    guard let self, let web, self.active, self.loadingID == load else { return }
                    self.inFlightJumpID = nil
                    if case .success(let value) = result, value as? Bool == true {
                        self.lastJumpID = request.id
                        self.parent.onJumpApplied(request.id)
                    }
                    if self.parent.jump?.id != request.id { self.applyJump(in: web) }
                }
        }

        func clearSelectionIfNeeded(in web: WKWebView) {
            guard let id = parent.selectionClearID, id != lastSelectionClearID else { return }
            lastSelectionClearID = id
            web.callAsyncJavaScript("window.__scienceReaderClearSelection();", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func returnFromCitationIfNeeded(in web: WKWebView) {
            guard let id = parent.citationReturnID, id != lastCitationReturnID else { return }
            lastCitationReturnID = id
            citationActive = false
            web.callAsyncJavaScript("return window.__scienceReaderCitationBack();", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }

        /// Library metadata can arrive or change while the paper is open.
        func applyPaperLine(in web: WKWebView) {
            guard parent.figureID == nil, appliedPaperLine != parent.paperLine else { return }
            appliedPaperLine = parent.paperLine
            web.callAsyncJavaScript("window.__scienceReaderSetPaperLine(line);", arguments: ["line": parent.paperLine ?? NSNull()],
                                    in: nil, in: .defaultClient, completionHandler: nil)
        }

        private func remember(_ body: [String: Any], in web: WKWebView) {
            guard let block = body["block"] as? Int, (-1...1_000_000).contains(block),
                  let fraction = body["fraction"] as? Double, fraction.isFinite, abs(fraction) < 1_000_000,
                  let height = body["height"] as? Double, height.isFinite, (1...1_000_000_000).contains(height),
                  let y = body["y"] as? Double, y.isFinite, (0...1_000_000_000).contains(y) else { return }
            let progress = (body["progress"] as? Double).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            let location = PaperReadingLocation(blockIndex: block < 0 ? nil : block, blockFraction: fraction, blockHeight: height, scrollY: y,
                                                progress: progress)
            latestLocation = location
            sampledOffsetY = web.scrollView.contentOffset.y
            parent.onLocation(parent.locationKey, location)
        }

        func saveFinalLocation(in web: WKWebView) {
            guard ready, let latestLocation else { return }
            // Include the final scroll movement even if the throttled DOM report is still queued
            // (but not a citation jump: the place to come back to is where reading left off).
            let delta = citationActive ? 0 : (web.scrollView.contentOffset.y - sampledOffsetY) / max(1, web.scrollView.zoomScale)
            parent.onLocation(parent.locationKey, latestLocation.adjusted(by: delta))
        }

        func invalidateLoad() {
            loadingID = UUID(); ready = false; inFlightJumpID = nil; latestLocation = nil; appliedFontSize = nil; citationActive = false
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard active, navigation === self.navigation else { return }
            SessionTimeline.shared.record("reader", ["phase": "loading"])
            parent.onLoading(true)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(navigation) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(navigation) }
        private func fail(_ navigation: WKNavigation?) {
            guard active, navigation === self.navigation else { return }
            invalidateLoad(); self.navigation = nil; parent.onLoading(false); parent.onFailure()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard active else { return }
            invalidateLoad(); navigation = nil
            parent.onLoading(false); parent.onFailure()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let destination = navigationAction.request.url else { return .cancel }
            if let bundle = parent.bundle {
                if bundle.permitsNavigation(to: destination), navigationAction.targetFrame?.isMainFrame == true { return .allow }
            } else if destination.isFileURL, let loadedURL,
                      destination.standardizedFileURL.path == loadedURL.standardizedFileURL.path { return .allow }
            if navigationAction.navigationType == .linkActivated, destination.scheme == "https" { await UIApplication.shared.open(destination) }
            return .cancel
        }
    }
}

struct FigureWebView: View {
    let bundle: VerifiedReaderBundle
    let figureID: String
    var baseFontSize: Double = 17
    var onReady: () -> Void = {}
    @State private var failed = false
    @State private var loading = true
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    var body: some View {
        PaperWebView(url: bundle.entryURL, bundle: bundle, figureID: figureID,
                     locationKey: bundle.manifestSHA256 + "/" + figureID, location: nil,
                     fontSize: baseFontSize * bodySize / 17, jump: nil, reduceMotion: true, onLoading: { loading = $0 },
                     onLocation: { _, _ in }, onJumpApplied: { _ in }, onSelection: { _ in },
                     onHeadings: { _ in }, onFigure: { _ in }, onFailure: { failed = true }, onReady: onReady)
            .overlay { if failed { ContentUnavailableView("Couldn’t open figure", systemImage: "photo").background(Color(uiColor: .systemBackground)) }
                else if loading { ProgressView("Opening figure…").allowsHitTesting(false) } }
    }
}

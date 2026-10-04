import SwiftUI
import WebKit
import ScienceReaderCore

/// Transient reading state for one immutable document artifact. It contains no paper text.
struct PaperReadingLocation: Equatable {
    let blockIndex: Int?
    let blockFraction: Double
    let blockHeight: Double
    let scrollY: Double

    fileprivate func adjusted(by delta: Double) -> Self {
        Self(blockIndex: blockIndex, blockFraction: blockFraction + delta / max(1, blockHeight),
             blockHeight: blockHeight, scrollY: max(0, scrollY + delta))
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

struct PaperView: View {
    @Bindable var model: ReaderModel
    @State private var showContents = false
    @State private var selection: ReaderSelection?
    @State private var readerFailed = false
    @State private var reloadID = UUID()
    @State private var selectionClearID = UUID()
    @State private var figure: String?
    @State private var loadingPaper = true
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var readingKey: String? {
        guard let paper = model.selectedPaper else { return nil }
        return "\(paper.id.uuidString)/\(paper.artifactID?.uuidString ?? "unversioned")/\(paper.readerBundle?.manifestSHA256 ?? "unverified")"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let paper = model.selectedPaper, let bundle = paper.readerBundle, let readingKey, let readerScope = model.readerDocumentScope {
                    VStack(spacing: 0) {
                        if paper.isSample {
                            Text("Offline sample").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 5).background(Color.secondary.opacity(0.05))
                        }
                        PaperWebView(url: bundle.entryURL, bundle: bundle, locationKey: readingKey,
                                     location: paper.artifactID == nil ? nil : model.paperLocations[readingKey],
                                     fontSize: model.paperFontSize * bodySize / 17, jump: model.paperJump,
                                     reduceMotion: reduceMotion, selectionClearID: selectionClearID, onLoading: {
                                         if model.readerDocumentScope == readerScope { loadingPaper = $0 }
                                     },
                                     onLocation: { key, location in
                                         // A sign-out clears the selection and the account's transient state.
                                         guard model.readerSessionID == readerScope.sessionID, model.selectedPaper != nil, paper.artifactID != nil else { return }
                                         model.paperLocations[key] = location
                                     }, onJumpApplied: { id in
                                         if model.paperJump?.id == id { model.paperJump = nil }
                                     },
                                     onSelection: {
                                         if model.readerDocumentScope == readerScope { selection = $0 }
                                     }, onHeadings: {
                                         if model.readerDocumentScope == readerScope { model.headings = $0 }
                                     }, onFigure: {
                                         if model.readerDocumentScope == readerScope { figure = $0 }
                                     }, onFailure: {
                                         if model.readerDocumentScope == readerScope { readerFailed = true; selection = nil; model.headings = [] }
                                     })
                            .id(PaperLoadIdentity(scope: readerScope, revision: reloadID))
                            .overlay { if readerFailed {
                                ContentUnavailableView { Label("Couldn’t open this paper", systemImage: "doc.badge.ellipsis") }
                                    description: { Text("The reading bundle couldn’t be loaded completely.") }
                                    actions: { Button("Try again") { readerFailed = false; loadingPaper = true; reloadID = UUID() } }
                                    .background(Color(uiColor: .systemBackground))
                            } }
                            .overlay { if loadingPaper { ProgressView("Opening paper…").allowsHitTesting(false) } }
                        if let selection {
                            selectionControls(selection, scope: readerScope)
                        }
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selection == nil)
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
                    ContentUnavailableView("Open a paper", systemImage: "doc.text", description: Text("Choose a paper from your library to start reading."))
                }
            }
            .navigationTitle("Paper").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Table of contents").disabled(model.selectedPaper == nil) }
                ToolbarItem(placement: .principal) { Text(model.selectedPaper?.title ?? "Paper").font(.subheadline.weight(.semibold)).lineLimit(1) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Smaller text", systemImage: "textformat.size.smaller") { model.paperFontSize = max(14, model.paperFontSize - 1) }
                        Button("Larger text", systemImage: "textformat.size.larger") { model.paperFontSize = min(26, model.paperFontSize + 1) }
                        Button("Ask about this paper", systemImage: "bubble.left") { model.askAboutSelectedPaper() }
                        Button("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Paper options")
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
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showContents = false } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: Binding(get: { figure != nil }, set: { if !$0 { figure = nil } })) {
                NavigationStack {
                    Group {
                        if let figure, let bundle = model.selectedPaper?.readerBundle { FigureWebView(bundle: bundle, figureID: figure, baseFontSize: model.paperFontSize) }
                        else { Color.clear }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { figure = nil } } }
                }
            }
        }
        .onChange(of: model.readerDocumentScope) { _, _ in
            selection = nil; figure = nil; showContents = false; readerFailed = false
            loadingPaper = model.selectedPaper?.readerBundle != nil
        }
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
        .padding(.horizontal, 12).padding(.vertical, 4).frame(maxWidth: .infinity)
        .modifier(ReaderControlMaterial()).padding(.horizontal, 12).padding(.bottom, 4).transition(.opacity)
    }

    private func selectionButton(_ action: SelectionAction, selection: ReaderSelection, scope: ReaderDocumentScope, expanded: Bool = false) -> some View {
        Button {
            model.selectionAction(action, selection: selection, scope: scope)
            self.selection = nil; selectionClearID = UUID()
        } label: {
            Text(action.rawValue).font(.subheadline.weight(.semibold)).fixedSize()
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let bundle { configuration.setURLSchemeHandler(ReaderBundleSchemeHandler(bundle: bundle), forURLScheme: "reader-bundle") }
        let script = Bundle.main.url(forResource: "reader-bridge", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var info: [String: Any] = [:]
        if let bundle, let indexData = try? JSONEncoder().encode(bundle.index),
           let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any] {
            info = index; info["manifest_sha256"] = bundle.manifestSHA256
            if let figureID { info["figure_id"] = figureID }
        }
        let json = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
        let prelude = "window.__readerBundleConfig = " + (bundle == nil ? "null" : String(decoding: json, as: UTF8.self)) + ";\n"
        configuration.userContentController.addUserScript(WKUserScript(source: prelude + script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "reader")
        let web = WKWebView(frame: .zero, configuration: configuration)
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
        if context.coordinator.loadedURL != url {
            context.coordinator.ready = false
            context.coordinator.loadedURL = url
            context.coordinator.invalidateLoad()
            if bundle != nil { context.coordinator.navigation = web.load(URLRequest(url: url)) }
            else { context.coordinator.navigation = web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        }
        guard context.coordinator.ready else { return }
        context.coordinator.clearSelectionIfNeeded(in: web)
        web.callAsyncJavaScript("document.documentElement.style.fontSize = size + 'px'", arguments: ["size": fontSize], in: nil, in: .defaultClient, completionHandler: nil)
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
        private var loadingID = UUID()
        private var inFlightJumpID: UUID?
        private var lastJumpID: UUID?
        private var latestLocation: PaperReadingLocation?
        private var sampledOffsetY = 0.0
        private var lastSelectionClearID: UUID?
        init(_ parent: PaperWebView) { self.parent = parent; lastSelectionClearID = parent.selectionClearID }

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
                if (location) window.__scienceReaderRestore(location);
                return window.__scienceReaderLocation();
                """, arguments: arguments, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                    guard let self, let webView, self.active, self.loadingID == load else { return }
                    guard case .success(let value) = result, let body = value as? [String: Any] else {
                        self.parent.onLoading(false); self.parent.onFailure(); return
                    }
                    self.ready = true
                    self.remember(body, in: webView)
                    self.parent.onLoading(false)
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

        private func remember(_ body: [String: Any], in web: WKWebView) {
            guard let block = body["block"] as? Int, (-1...1_000_000).contains(block),
                  let fraction = body["fraction"] as? Double, fraction.isFinite, abs(fraction) < 1_000_000,
                  let height = body["height"] as? Double, height.isFinite, (1...1_000_000_000).contains(height),
                  let y = body["y"] as? Double, y.isFinite, (0...1_000_000_000).contains(y) else { return }
            let location = PaperReadingLocation(blockIndex: block < 0 ? nil : block, blockFraction: fraction, blockHeight: height, scrollY: y)
            latestLocation = location
            sampledOffsetY = web.scrollView.contentOffset.y
            parent.onLocation(parent.locationKey, location)
        }

        func saveFinalLocation(in web: WKWebView) {
            guard ready, let latestLocation else { return }
            // Include the final scroll movement even if the throttled DOM report is still queued.
            let delta = (web.scrollView.contentOffset.y - sampledOffsetY) / max(1, web.scrollView.zoomScale)
            parent.onLocation(parent.locationKey, latestLocation.adjusted(by: delta))
        }

        func invalidateLoad() {
            loadingID = UUID(); ready = false; inFlightJumpID = nil; latestLocation = nil
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard active, navigation === self.navigation else { return }
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
    @State private var failed = false
    @State private var loading = true
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    var body: some View {
        PaperWebView(url: bundle.entryURL, bundle: bundle, figureID: figureID,
                     locationKey: bundle.manifestSHA256 + "/" + figureID, location: nil,
                     fontSize: baseFontSize * bodySize / 17, jump: nil, reduceMotion: true, onLoading: { loading = $0 },
                     onLocation: { _, _ in }, onJumpApplied: { _ in }, onSelection: { _ in },
                     onHeadings: { _ in }, onFigure: { _ in }, onFailure: { failed = true })
            .overlay { if failed { ContentUnavailableView("Couldn’t open figure", systemImage: "photo").background(Color(uiColor: .systemBackground)) }
                else if loading { ProgressView("Opening figure…").allowsHitTesting(false) } }
    }
}

import SwiftUI
import WebKit

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

struct PaperView: View {
    @Bindable var model: ReaderModel
    @State private var showContents = false
    @State private var selectedText = ""
    @State private var figure: String?
    @State private var loadingPaper = true
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var readingKey: String? {
        guard let paper = model.selectedPaper else { return nil }
        return "\(paper.id.uuidString)/\(paper.artifactID?.uuidString ?? "unversioned")"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let paper = model.selectedPaper, let file = paper.fileURL, let readingKey, let readerScope = model.readerDocumentScope {
                    VStack(spacing: 0) {
                        if paper.isSample {
                            Text("Offline sample").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 5).background(Color.secondary.opacity(0.05))
                        }
                        PaperWebView(url: file, locationKey: readingKey,
                                     location: paper.artifactID == nil ? nil : model.paperLocations[readingKey],
                                     fontSize: model.paperFontSize * bodySize / 17, jump: model.paperJump,
                                     reduceMotion: reduceMotion, onLoading: {
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
                                         if model.readerDocumentScope == readerScope { selectedText = $0 }
                                     }, onHeadings: {
                                         if model.readerDocumentScope == readerScope { model.headings = $0 }
                                     }, onFigure: {
                                         if model.readerDocumentScope == readerScope { figure = $0 }
                                     })
                            .id(readerScope)
                            .overlay { if loadingPaper { ProgressView("Opening paper…").allowsHitTesting(false) } }
                        if !selectedText.isEmpty {
                            HStack(spacing: 0) {
                                ForEach(SelectionAction.allCases, id: \.self) { action in
                                    Button(action.rawValue) { model.selectionAction(action, quote: selectedText); selectedText = "" }
                                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
                                }
                            }.padding(4).modifier(ReaderControlMaterial()).padding(.horizontal, 12).padding(.bottom, 4).transition(.opacity)
                        }
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedText.isEmpty)
                } else if model.selectedPaper != nil {
                    ContentUnavailableView("Paper download needed", systemImage: "arrow.down.document", description: Text("Download this paper’s complete reading bundle to open it offline."))
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
                    if let figure { FigureWebView(html: figure) }
                    else { Color.clear }
                }.overlay(alignment: .topTrailing) { Button("Done") { figure = nil }.padding().background(.regularMaterial, in: Capsule()).padding() }
            }
        }
        .onChange(of: model.readerDocumentScope) { _, _ in
            selectedText = ""; figure = nil; showContents = false
            loadingPaper = model.selectedPaper?.fileURL != nil
        }
    }
}

struct PaperWebView: UIViewRepresentable {
    let url: URL
    let locationKey: String
    let location: PaperReadingLocation?
    let fontSize: Double
    let jump: PaperJumpRequest?
    let reduceMotion: Bool
    let onLoading: (Bool) -> Void
    let onLocation: (String, PaperReadingLocation) -> Void
    let onJumpApplied: (UUID) -> Void
    let onSelection: (String) -> Void
    let onHeadings: ([PaperHeading]) -> Void
    let onFigure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let script = """
        (() => {
          const post = value => window.webkit.messageHandlers.reader.postMessage(value);
          // Renderer IDs are part of the immutable artifact: section/equation
          // references already point at them. Missing or ambiguous IDs get a
          // private Contents key; never rewrite an existing artifact anchor.
          const counts = new Map();
          document.querySelectorAll('[id]').forEach(element => counts.set(element.id,(counts.get(element.id)||0)+1));
          const used = new Set(counts.keys());
          const headings = [...document.querySelectorAll('h1,h2,h3')]
            .filter(element=>(element.textContent||'').trim()).slice(0,500);
          const headingTargets = new Map();
          const items = headings.map((element,index) => {
            const valid = element.id && element.id.length<=512 && !/[\\u0000-\\u0020\\u007f]/.test(element.id) && counts.get(element.id)===1;
            let key=element.id;
            if (!valid) {
              const stem='sr-heading-'+index;
              let id=stem, suffix=0;
              while (used.has(id)) id=stem+'-'+(++suffix);
              used.add(id); key=id;
            }
            headingTargets.set(key,element);
            return {id:key,title:(element.textContent||'').trim().slice(0,2000)};
          });
          window.__scienceReaderJumpToHeading = (key,reduced) => {
            const heading=headingTargets.get(key);
            if (!heading) return false;
            heading.scrollIntoView({behavior:reduced?'instant':'smooth',block:'start'});
            return true;
          };
          post({type:'headings',items});
          const blocks = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,figure,table,pre')];
          window.__scienceReaderLocation = () => {
            const index = blocks.findIndex(element => {
              const rect = element.getBoundingClientRect();
              return rect.height > 0 && rect.bottom > 0;
            });
            const rect = index >= 0 ? blocks[index].getBoundingClientRect() : null;
            return {block:index, fraction:rect ? -rect.top / Math.max(1,rect.height) : 0,
                    height:rect ? Math.max(1,rect.height) : 1, y:Math.max(0,window.scrollY)};
          };
          window.__scienceReaderRestore = location => {
            const block = blocks[location.block];
            const rect = block?.getBoundingClientRect();
            const y = rect ? window.scrollY + rect.top + location.fraction * Math.max(1,rect.height) : location.y;
            window.scrollTo({top:Math.max(0,y),behavior:'instant'});
          };
          let positionTimer;
          const postPosition = () => post({type:'position',...window.__scienceReaderLocation()});
          window.addEventListener('scroll',() => {
            if (positionTimer) return;
            positionTimer=setTimeout(()=> { positionTimer=null; postPosition(); },120);
          },{passive:true});
          window.addEventListener('scrollend',postPosition);
          let timer;
          document.addEventListener('selectionchange',() => {
            clearTimeout(timer);
            timer=setTimeout(()=>post({type:'selection',text:(window.getSelection()?.toString() || '').trim().slice(0,20000)}),180);
          });
          document.querySelectorAll('figure').forEach((element,index)=> {
            const open = () => {
              if (window.getSelection()?.toString()) return;
              const detail = element.cloneNode(true);
              ['role','tabindex','aria-label'].forEach(name=>detail.removeAttribute(name));
              post({type:'figure',html:detail.outerHTML});
            };
            element.setAttribute('role','button'); element.setAttribute('tabindex','0');
            element.setAttribute('aria-label','Open figure '+(index+1));
            element.addEventListener('click',open);
            element.addEventListener('keydown',event=> {
              if (event.key==='Enter' || event.key===' ') { event.preventDefault(); open(); }
            });
          });
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "reader")
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
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        guard context.coordinator.ready else { return }
        web.callAsyncJavaScript("document.documentElement.style.fontSize = size + 'px'", arguments: ["size": fontSize], in: nil, in: .page, completionHandler: nil)
        context.coordinator.applyJump(in: web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.saveFinalLocation(in: web)
        coordinator.active = false
        web.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        web.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: PaperWebView
        var loadedURL: URL?
        var ready = false
        var active = true
        private var loadingID = UUID()
        private var inFlightJumpID: UUID?
        private var lastJumpID: UUID?
        private var latestLocation: PaperReadingLocation?
        private var sampledOffsetY = 0.0
        init(_ parent: PaperWebView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "selection": if let text = body["text"] as? String, text.utf8.count <= 80_000 { parent.onSelection(text.count > 2 ? text : "") }
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
            case "figure": if let html = body["html"] as? String, html.utf8.count <= 1_000_000 { parent.onFigure(html) }
            case "position": if ready, let web = message.webView { remember(body, in: web) }
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let load = loadingID
            let location: Any
            if let saved = parent.location {
                location = ["block": saved.blockIndex ?? -1, "fraction": saved.blockFraction, "y": saved.scrollY] as [String: Any]
            } else { location = NSNull() }
            let arguments: [String: Any] = ["size": parent.fontSize, "location": location]
            webView.callAsyncJavaScript("""
                document.documentElement.style.fontSize = size + 'px';
                await document.fonts.ready;
                await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
                if (location) window.__scienceReaderRestore(location);
                return window.__scienceReaderLocation();
                """, arguments: arguments, in: nil, in: .page) { [weak self, weak webView] result in
                    guard let self, let webView, self.active, self.loadingID == load else { return }
                    self.ready = true
                    if case .success(let value) = result, let body = value as? [String: Any] { self.remember(body, in: webView) }
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
                """, arguments: ["id": request.headingID, "reduced": parent.reduceMotion], in: nil, in: .page) { [weak self, weak web] result in
                    guard let self, let web, self.active, self.loadingID == load else { return }
                    self.inFlightJumpID = nil
                    if case .success(let value) = result, value as? Bool == true {
                        self.lastJumpID = request.id
                        self.parent.onJumpApplied(request.id)
                    }
                    if self.parent.jump?.id != request.id { self.applyJump(in: web) }
                }
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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loadingID = UUID(); ready = false; inFlightJumpID = nil; latestLocation = nil
            parent.onLoading(true)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.onLoading(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.onLoading(false) }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let destination = navigationAction.request.url else { return .cancel }
            if destination.isFileURL, let loadedURL,
               destination.standardizedFileURL.path.hasPrefix(loadedURL.deletingLastPathComponent().standardizedFileURL.path + "/") { return .allow }
            if navigationAction.navigationType == .linkActivated, destination.scheme == "https" { await UIApplication.shared.open(destination) }
            return .cancel
        }
    }
}

struct FigureWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString("<html><head><meta name='viewport' content='width=device-width, initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src data: file:; style-src 'unsafe-inline'\"><style>:root{color-scheme:light dark}body{font-family:system-ui;padding:70px 16px}svg,img{max-width:100%;height:auto}figure{margin:0}figcaption{margin-top:24px;font-size:15px}</style></head><body>\(html)</body></html>", baseURL: nil)
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
}

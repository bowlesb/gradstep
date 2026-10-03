import SwiftUI
import WebKit

struct PaperView: View {
    @Bindable var model: ReaderModel
    @State private var showContents = false
    @State private var selectedText = ""
    @State private var figure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let paper = model.selectedPaper, let file = paper.fileURL {
                    VStack(spacing: 0) {
                        if paper.isSample {
                            Text("Offline reader sample").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 5).background(Color.secondary.opacity(0.05))
                        }
                        PaperWebView(url: file, fontSize: model.paperFontSize, jumpTo: model.jumpToHeading,
                                     onSelection: { selectedText = $0 }, onHeadings: { model.headings = $0 }, onFigure: { figure = $0 })
                        if !selectedText.isEmpty {
                            HStack(spacing: 0) {
                                ForEach(SelectionAction.allCases, id: \.self) { action in
                                    Button(action.rawValue) { model.selectionAction(action, quote: selectedText); selectedText = "" }
                                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
                                }
                            }.background(.bar).transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
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
                        Button("Ask about this paper", systemImage: "bubble.left") { model.generalChat = false; model.tab = .chat }
                        Button("Report this screen", systemImage: "ladybug") { model.beginReport(afterMenu: true) }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Paper options")
                }
            }
            .sheet(isPresented: $showContents) {
                NavigationStack {
                    List(Array(model.headings.enumerated()), id: \.offset) { index, title in
                        Button(title) { model.jumpToHeading = "sr-heading-\(index)"; showContents = false }
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
    }
}

struct PaperWebView: UIViewRepresentable {
    let url: URL
    let fontSize: Double
    let jumpTo: String?
    let onSelection: (String) -> Void
    let onHeadings: ([String]) -> Void
    let onFigure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let script = """
        (() => {
          const post = value => window.webkit.messageHandlers.reader.postMessage(value);
          const headings = [...document.querySelectorAll('h1,h2,h3')];
          headings.forEach((element,index) => element.id='sr-heading-'+index);
          post({type:'headings',items:headings.map(element=>element.textContent || '')});
          let timer;
          document.addEventListener('selectionchange',() => {
            clearTimeout(timer);
            timer=setTimeout(()=>post({type:'selection',text:(window.getSelection()?.toString() || '').trim().slice(0,20000)}),180);
          });
          document.querySelectorAll('figure').forEach(element=>element.addEventListener('click',()=> {
            if (!(window.getSelection()?.toString())) post({type:'figure',html:element.outerHTML});
          }));
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
            context.coordinator.loadedURL = url
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        web.callAsyncJavaScript("document.documentElement.style.fontSize = size + 'px'", arguments: ["size": fontSize], in: nil, in: .page, completionHandler: nil)
        if let jumpTo, context.coordinator.lastJump != jumpTo {
            context.coordinator.lastJump = jumpTo
            web.callAsyncJavaScript("document.getElementById(id)?.scrollIntoView({behavior:'smooth',block:'start'})", arguments: ["id": jumpTo], in: nil, in: .page, completionHandler: nil)
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { web.configuration.userContentController.removeScriptMessageHandler(forName: "reader"); web.stopLoading() }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: PaperWebView
        var loadedURL: URL?
        var lastJump: String?
        init(_ parent: PaperWebView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "selection": if let text = body["text"] as? String, text.utf8.count <= 80_000 { parent.onSelection(text.count > 2 ? text : "") }
            case "headings": if let items = body["items"] as? [String] { parent.onHeadings(Array(items.prefix(500))) }
            case "figure": if let html = body["html"] as? String, html.utf8.count <= 1_000_000 { parent.onFigure(html) }
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.callAsyncJavaScript("document.documentElement.style.fontSize = size + 'px'", arguments: ["size": parent.fontSize], in: nil, in: .page, completionHandler: nil)
        }

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

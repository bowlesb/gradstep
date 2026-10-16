import SwiftUI
import WebKit
import ScienceReaderCore

struct PresentedDiagram: Identifiable, Equatable { let id: UUID }

/// A saved diagram in a sheet (from an answer's "View diagram").
struct DiagramSheet: View {
    let diagram: ChatDiagram
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DiagramDetail(diagram: diagram)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Draws a diagram on device. Its Mermaid source came from a model answer, so
/// it is untrusted: the page allows no scripts, network or navigation, and
/// Mermaid (bundled) runs in strict mode from an app-owned script.
struct DiagramDetail: View {
    let diagram: ChatDiagram
    @Environment(\.colorScheme) private var colorScheme
    @State private var failed = false

    var body: some View {
        Group {
            if diagram.isFigureParts, let stored = StoredFigureParts.decode(diagram.source) {
                FigurePartsView(stored: stored)
            } else if diagram.isHTML {
                HTMLVisualWebView(html: diagram.source, dark: colorScheme == .dark).id(colorScheme)
                    .accessibilityIdentifier("visual.canvas")
            } else if failed {
                // Checked (and sent back once) before it was kept, so this is rare: say so plainly; the source is there
                // for the curious, collapsed.
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Couldn’t draw this diagram", systemImage: "exclamationmark.triangle").font(.headline)
                            .accessibilityIdentifier("diagram.failed")
                        Text("View the source below, or ask the chat to draw it again.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        DisclosureGroup("Source") {
                            Text(diagram.source).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }
                        .accessibilityIdentifier("diagram.source")
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                MermaidWebView(source: diagram.source, dark: colorScheme == .dark) { failed = true }
                    .id(colorScheme)
                    .accessibilityIdentifier("diagram.canvas")
            }
        }
        .navigationTitle(diagram.title).navigationBarTitleDisplayMode(.inline)
    }
}

/// A visual answer: the server-sanitized HTML fragment in a page of its own, with no scripts, no network and no
/// navigation (chat-visual.ts `visualDocument`; the same policy as the diagram page).
struct HTMLVisualWebView: UIViewRepresentable {
    let html: String
    let dark: Bool

    static func document(_ html: String, dark: Bool, fontSize: Double) -> String {
        let size = Int(min(26, max(12, fontSize)))
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=4">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>:root{color-scheme:\(dark ? "dark" : "light dark")}html,body{margin:0;padding:0}body{padding:16px;font:\(size)px/1.45 -apple-system,system-ui,sans-serif;background:Canvas;color:CanvasText;overflow-wrap:anywhere}table{border-collapse:collapse;max-width:100%}td,th{border:1px solid rgba(128,128,128,.45);padding:4px 8px;vertical-align:top}th{text-align:left}svg{max-width:100%;height:auto}pre,code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}pre{white-space:pre-wrap}h1,h2,h3{line-height:1.25}h1{font-size:1.35em}h2{font-size:1.2em}h3{font-size:1.05em}img,iframe,object,embed,video{display:none !important}</style>
        </head><body>\(html)</body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        view.loadHTMLString(Self.document(html, dark: dark, fontSize: UIFont.preferredFont(forTextStyle: .body).pointSize), baseURL: nil)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        // The page itself loads; nothing it links to does (a link in a visual stays a link in name only).
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}

struct MermaidWebView: UIViewRepresentable {
    let source: String
    let dark: Bool
    let onFailure: () -> Void

    static let library: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    static let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=6">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
        <style>:root{color-scheme:light dark}html,body{height:100%}body{margin:0;padding:16px;box-sizing:border-box;background:Canvas;font:-apple-system-body;display:flex}#diagram{margin:auto}#diagram svg{display:block;height:auto}</style>
        </head><body><div id="diagram"></div></body></html>
        """

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let input = (try? JSONSerialization.data(withJSONObject: ["source": source, "dark": dark])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        let render = """
            ;(async () => {
              const input = \(input), post = value => window.webkit.messageHandlers.diagram.postMessage(value);
              try {
                if (!input || typeof globalThis.mermaid?.render !== 'function') throw new Error('unavailable');
                // Directives in the (untrusted) source cannot override these keys.
                globalThis.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: input.dark ? 'dark' : 'default',
                  fontFamily: '-apple-system, system-ui, sans-serif',
                  secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering',
                    'dompurifyConfig', 'themeCSS', 'themeVariables', 'theme', 'fontFamily', 'htmlLabels'] });
                // A tall, narrow screen reads a left-to-right flowchart better top to bottom.
                let source = input.source;
                if (window.innerWidth < 600 && window.innerHeight > window.innerWidth) {
                  source = source.replace(/^(\\s*(?:flowchart|graph)\\s+)(?:LR|RL)\\b/, '$1TD');
                }
                const { svg } = await globalThis.mermaid.render('sr-diagram', source);
                document.getElementById('diagram').innerHTML = svg;
                // Fit the width, but never below 75% of natural size: labels stay readable and
                // only very large diagrams scroll (pinch-zoom still works). Smaller ones sit centred.
                const drawn = document.querySelector('#diagram svg'), box = drawn?.viewBox?.baseVal;
                if (drawn && box && box.width > 0) {
                  const scale = Math.max(Math.min(1, (window.innerWidth - 32) / box.width), 0.75);
                  drawn.removeAttribute('width'); drawn.style.maxWidth = 'none'; drawn.style.width = (box.width * scale) + 'px';
                }
                post({ ok: true });
              } catch (error) { post({ ok: false }); }
            })();
            """
        if let library = Self.library {
            configuration.userContentController.addUserScript(WKUserScript(source: library + "\n" + render,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "diagram")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = .systemBackground
        web.navigationDelegate = context.coordinator
        #if DEBUG
        web.isInspectable = true
        #endif
        if Self.library == nil { context.coordinator.fail() } else { web.loadHTMLString(Self.page, baseURL: nil) }
        context.coordinator.startTimeout()
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "diagram", contentWorld: .defaultClient)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let onFailure: () -> Void
        private var settled = false, loaded = false
        private var timeout: Task<Void, Never>?

        init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }

        func startTimeout() {
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.fail()
            }
        }
        func cancel() { settled = true; timeout?.cancel() }
        func fail() {
            guard !settled else { return }
            settled = true; timeout?.cancel()
            DispatchQueue.main.async { self.onFailure() }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !settled else { return }
            if (message.body as? [String: Any])?["ok"] as? Bool == true { settled = true; timeout?.cancel() } else { fail() }
        }

        // Only the initial document loads; diagram links never navigate.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !loaded, navigationAction.request.url?.absoluteString == "about:blank" else { return .cancel }
            loaded = true
            return .allow
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
    }
}

/// Checks Mermaid source with the bundled Mermaid's parser (nothing is drawn) before a diagram is kept (2026-10-07):
/// in an off-screen web view set up like the one that draws diagrams (no page scripts, network or navigation; strict).
@MainActor enum MermaidCheck {
    enum Result: Equatable, Sendable {
        case valid
        /// Mermaid's error message (bounded), for the one request that asks for a corrected diagram.
        case invalid(String)
        /// The check couldn't run (no bundled Mermaid, a timeout): the diagram is kept as it is.
        case unavailable
    }

    static func check(_ source: String, timeout: Duration = .seconds(10)) async -> Result {
        guard let library = MermaidWebView.library else { return .unavailable }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let input = (try? JSONSerialization.data(withJSONObject: ["source": source])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        let script = """
            ;(async () => {
              const input = \(input), post = value => window.webkit.messageHandlers.check.postMessage(value);
              try {
                if (!input || typeof globalThis.mermaid?.parse !== 'function') { post({ unavailable: true }); return; }
                globalThis.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict',
                  secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering',
                    'dompurifyConfig', 'themeCSS', 'themeVariables', 'theme', 'fontFamily', 'htmlLabels'] });
                await globalThis.mermaid.parse(input.source);
                post({ ok: true });
              } catch (error) { post({ ok: false, message: String(error?.message ?? error).slice(0, 600) }); }
            })();
            """
        configuration.userContentController.addUserScript(WKUserScript(source: library + "\n" + script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let checker = Checker()
        configuration.userContentController.add(checker, contentWorld: .defaultClient, name: "check")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), configuration: configuration)
        web.navigationDelegate = checker
        let result = await withCheckedContinuation { continuation in
            checker.continuation = continuation
            web.loadHTMLString(MermaidWebView.page, baseURL: nil)
            Task { [weak checker] in
                try? await Task.sleep(for: timeout)
                checker?.finish(.unavailable)
            }
        }
        configuration.userContentController.removeScriptMessageHandler(forName: "check", contentWorld: .defaultClient)
        web.navigationDelegate = nil
        return result
    }

    @MainActor private final class Checker: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var continuation: CheckedContinuation<Result, Never>?
        private var loaded = false

        func finish(_ result: Result) {
            continuation?.resume(returning: result); continuation = nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any]
            switch body?["ok"] as? Bool {
            case true?: finish(.valid)
            case false?: finish(.invalid(String((body?["message"] as? String ?? "").prefix(600))))
            case nil: finish(.unavailable)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !loaded, navigationAction.request.url?.absoluteString == "about:blank" else { return .cancel }
            loaded = true
            return .allow
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.unavailable) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.unavailable) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.unavailable) }
    }
}

/// A diagram drawn into an image for the chat transcript (owner, build 46: "If you bothered to create a diagram please
/// show it"): Mermaid renders offscreen with SVG labels (no foreign objects, so the canvas stays readable), the SVG is
/// drawn into a canvas at twice its size and comes back as PNG. Cached per diagram and appearance for the session.
@MainActor enum DiagramPreview {
    private static var cache: [String: UIImage] = [:]
    private static var failed: Set<String> = []

    static func cached(_ id: UUID, dark: Bool) -> UIImage? { cache["\(id)-\(dark)"] }
    static func didFail(_ id: UUID, dark: Bool) -> Bool { failed.contains("\(id)-\(dark)") }

    static func render(_ id: UUID, source: String, dark: Bool, timeout: Duration = .seconds(12)) async -> UIImage? {
        let key = "\(id)-\(dark)"
        if let image = cache[key] { return image }
        guard !failed.contains(key), let library = MermaidWebView.library else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let input = (try? JSONSerialization.data(withJSONObject: ["source": source, "dark": dark])).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        let script = """
            ;(async () => {
              const input = \(input), post = value => window.webkit.messageHandlers.preview.postMessage(value);
              try {
                if (!input || typeof globalThis.mermaid?.render !== 'function') { post({ ok: false }); return; }
                globalThis.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: input.dark ? 'dark' : 'default',
                  fontFamily: '-apple-system, system-ui, sans-serif', htmlLabels: false, flowchart: { htmlLabels: false },
                  secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering',
                    'dompurifyConfig', 'themeCSS', 'themeVariables', 'theme', 'fontFamily', 'htmlLabels'] });
                // Top to bottom reads best in a narrow chat column.
                const source = input.source.replace(/^(\\s*(?:flowchart|graph)\\s+)(?:LR|RL)\\b/, '$1TD');
                const { svg } = await globalThis.mermaid.render('sr-preview', source);
                const doc = new DOMParser().parseFromString(svg, 'image/svg+xml'), root = doc.documentElement;
                const box = (root.getAttribute('viewBox') || '').split(/[ ,]+/).map(Number);
                const width = Math.min(1200, Math.max(1, Math.ceil(box[2] || 600))), height = Math.max(1, Math.ceil((box[3] || 400) * width / (box[2] || width)));
                root.setAttribute('width', String(width)); root.setAttribute('height', String(height)); root.removeAttribute('style');
                const text = new XMLSerializer().serializeToString(root);
                const image = new Image();
                image.src = 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(text)));
                await image.decode();
                const canvas = document.createElement('canvas'), scale = 2;
                canvas.width = width * scale; canvas.height = height * scale;
                const context = canvas.getContext('2d');
                context.scale(scale, scale); context.drawImage(image, 0, 0, width, height);
                post({ ok: true, png: canvas.toDataURL('image/png') });
              } catch (error) { post({ ok: false }); }
            })();
            """
        configuration.userContentController.addUserScript(WKUserScript(source: library + "\n" + script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let receiver = Receiver()
        configuration.userContentController.add(receiver, contentWorld: .defaultClient, name: "preview")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        web.navigationDelegate = receiver
        let data = await withCheckedContinuation { continuation in
            receiver.continuation = continuation
            web.loadHTMLString(MermaidWebView.page, baseURL: nil)
            Task { [weak receiver] in
                try? await Task.sleep(for: timeout)
                receiver?.finish(nil)
            }
        }
        configuration.userContentController.removeScriptMessageHandler(forName: "preview", contentWorld: .defaultClient)
        web.navigationDelegate = nil
        guard let data, let image = UIImage(data: data, scale: 2) else { failed.insert(key); return nil }
        cache[key] = image
        return image
    }

    @MainActor private final class Receiver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var continuation: CheckedContinuation<Data?, Never>?
        private var loaded = false
        func finish(_ data: Data?) { continuation?.resume(returning: data); continuation = nil }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any]
            guard body?["ok"] as? Bool == true, let png = body?["png"] as? String, png.hasPrefix("data:image/png;base64,"),
                  png.count < 24_000_000 else { finish(nil); return }
            finish(Data(base64Encoded: String(png.dropFirst("data:image/png;base64,".count))))
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !loaded, navigationAction.request.url?.absoluteString == "about:blank" else { return .cancel }
            loaded = true
            return .allow
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }
    }
}

/// Under an answer: the diagram itself (a visual's page, or the Mermaid drawing as an image), a tap opens it full size.
struct InlineDiagram: View {
    let link: ChatDiagramLink
    let diagram: ChatDiagram?
    let fontSize: Double
    let open: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        let dark = colorScheme == .dark
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if link.isHTML, let diagram {
                        HTMLVisualWebView(html: diagram.source, dark: dark).allowsHitTesting(false).frame(height: 260)
                    } else if let image = image ?? DiagramPreview.cached(link.id, dark: dark) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                    } else if failed {
                        // As tall as the spinner it replaces, so the answer doesn't jump (and a tap on it still opens the
                        // diagram, where its source is): owner, builds 58–59, rows must not change height as they settle.
                        Label("Couldn’t draw it here", systemImage: "exclamationmark.triangle")
                            .font(.system(size: fontSize * 0.8)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                Label(link.isHTML ? "\(link.title) · Open" : "\(link.title) · Open full size", systemImage: link.isHTML ? "rectangle.and.text.magnifyingglass" : "square.stack.3d.up")
                    .font(.system(size: fontSize * 0.8)).foregroundStyle(Color.accentColor).lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(link.isHTML ? "Visual: \(link.title)" : "Diagram: \(link.title)")
        .accessibilityHint("Opens it full size")
        .task(id: "\(link.id)-\(dark)") {
            guard !link.isHTML, image == nil, let diagram, !diagram.isHTML, !diagram.isFigureParts else { return }
            image = await DiagramPreview.render(link.id, source: diagram.source, dark: dark)
            failed = image == nil
        }
    }
}

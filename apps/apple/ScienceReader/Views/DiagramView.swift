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
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
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
            if failed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("This diagram couldn’t be drawn.", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(diagram.source).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
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

private struct MermaidWebView: UIViewRepresentable {
    let source: String
    let dark: Bool
    let onFailure: () -> Void

    private static let library: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let page = """
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

import SwiftUI
import WebKit
import ScienceReaderCore

/// Contents › Equations › View as tiles (owner, build 62: "How possible is it to use a tile view similar to figures?"):
/// the paper's display equations typeset as in the paper, from the bundle's own page markup and stylesheet, in one web
/// page laid out as a grid (not a web view per tile). Each tile is named by its number; a tap opens the equation as its
/// row does. No page script runs; only this view's layout script, in its own world.
struct EquationTilesView: UIViewRepresentable {
    let bundle: VerifiedReaderBundle
    let equations: [PaperContentsSheet.Equation]
    let open: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = PaperWebView.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(ReaderBundleSchemeHandler(bundle: bundle), forURLScheme: "reader-bundle")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.layoutScript, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "tiles")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.navigationDelegate = context.coordinator
        web.loadHTMLString(Self.page(bundle: bundle, equations: equations), baseURL: URL(string: "reader-bundle://\(bundle.manifestSHA256)/"))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.open = open }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "tiles", contentWorld: .defaultClient)
        web.stopLoading()
    }

    /// The bundle's stylesheet, then the grid: tiles on a quiet fill, light and dark, each equation centred and scaled
    /// down (never up) to its tile; the printed number is the tile's label, so the equation's own tag is hidden.
    static func page(bundle: VerifiedReaderBundle, equations: [PaperContentsSheet.Equation]) -> String {
        let style = bundle.manifest.members.first { $0.role == "style" }?.path
        let link = style.map { "<link rel=\"stylesheet\" href=\"\($0)\">" } ?? ""
        let tiles = equations.map { equation in
            let label = escape(equation.label)
            let body = equation.markup ?? "<span class=\"tile-missing\">\(label)</span>"
            return "<div class=\"tile\" role=\"button\" tabindex=\"0\" aria-label=\"\(label)\" data-id=\"\(escape(equation.id))\">"
                + "<div class=\"tile-label\" aria-hidden=\"true\">\(label)</div><div class=\"tile-eq\" aria-hidden=\"true\"><div class=\"tile-inner\">\(body)</div></div></div>"
        }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\(link)
        <style>
        :root{color-scheme:light dark}
        :root,html,body{background:transparent!important}
        body{margin:0;padding:8px 16px 32px;max-width:none}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
        .tile{display:flex;flex-direction:column;gap:6px;min-height:104px;padding:10px 10px 12px;border-radius:14px;
          background:rgba(120,120,128,.12);cursor:pointer;-webkit-tap-highlight-color:transparent;overflow:hidden}
        .tile:active{background:rgba(120,120,128,.22)}
        .tile-label{font:600 13px -apple-system,system-ui,sans-serif;opacity:.7;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .tile-eq{flex:1;display:flex;align-items:center;justify-content:center;overflow:hidden;font-size:16px}
        .tile-inner{width:max-content;transform-origin:center center}
        .tile .reader-equation{margin:0;padding:0;background:transparent;max-width:none;overflow:visible}
        .tile .reader-display{display:inline-block}
        .tile .reader-tag{display:none}
        .tile math{font-size:1em}
        .tile img{max-width:none}
        </style></head><body><div class="grid">\(tiles)</div></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Fits each equation to its tile (scaled down only) and reports a tile's tap.
    static let layoutScript = """
    (() => {
      const fit = () => {
        for (const box of document.querySelectorAll('.tile-eq')) {
          const inner = box.firstElementChild; if (!inner) continue;
          inner.style.transform = 'none';
          // 8 pt of the tile on each side beyond its padding (owner, 2026-10-21: a margin around every equation shown).
          const scale = Math.min(1, (box.clientWidth - 16) / Math.max(1, inner.scrollWidth), 120 / Math.max(1, inner.scrollHeight));
          inner.style.transform = scale < 1 ? 'scale(' + scale + ')' : 'none';
        }
      };
      const open = tile => { const id = tile?.getAttribute('data-id'); if (id) window.webkit.messageHandlers.tiles.postMessage(id); };
      document.addEventListener('click', event => open(event.target.closest?.('.tile')));
      document.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') open(event.target.closest?.('.tile')); });
      window.addEventListener('resize', fit);
      window.addEventListener('load', fit);
      fit();
      document.fonts?.ready?.then(fit);
    })();
    """

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var open: (String) -> Void
        private var loaded = false
        init(open: @escaping (String) -> Void) { self.open = open }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the page itself; a link inside an equation goes nowhere.
            guard action.navigationType == .other, !loaded else { return .cancel }
            loaded = true
            return .allow
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let id = message.body as? String, (1...200).contains(id.utf8.count) else { return }
            open(id)
        }
    }
}

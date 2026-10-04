// A standalone macOS WebKit component check. No iOS target, signing, phone,
// customer source, persisted website data, or application transcript is used.
import AppKit
import CryptoKit
import Foundation
import WebKit

private struct ProofFailure: Error {}

@MainActor
private final class Harness: NSObject, WKNavigationDelegate, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
    let world = WKContentWorld.world(name: "typesetter-proof-" + UUID().uuidString)
    let invocation = UUID().uuidString
    let url = URL(string: "chat-proof://local/index.html")!
    var web: WKWebView!
    var loaded: CheckedContinuation<Void, Error>?
    var acceptedResult: [String: Any]?
    var documentLoads = 0
    var rejectedRequests = 0
    var rejectedNavigations = 0
    var bridgeCalls = 0
    var terminated = false

    init(bundle: String) {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(self, forURLScheme: "chat-proof")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: world, name: "proof")
        let diagnostics = """
        globalThis.__proofDiagnostics = {consoleCalls:0, errors:0, cspViolations:0};
        for (const key of ['log','warn','error','info','debug']) console[key] = () => __proofDiagnostics.consoleCalls++;
        addEventListener('error', () => __proofDiagnostics.errors++);
        addEventListener('unhandledrejection', () => __proofDiagnostics.errors++);
        addEventListener('securitypolicyviolation', () => __proofDiagnostics.cspViolations++);
        """
        configuration.userContentController.addUserScript(WKUserScript(source: diagnostics + "\n" + bundle,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 600), configuration: configuration)
        web.navigationDelegate = self
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            web.load(URLRequest(url: url))
        }
    }

    func run(_ fixture: [String: Any]) async throws -> [String: Any] {
        let start = ContinuousClock.now
        guard let observation = try await web.callAsyncJavaScript("""
            const result = globalThis.ChatTypesetterProof.run(input);
            const reply = await window.webkit.messageHandlers.proof.postMessage({invocation, result});
            const reused = globalThis.ChatTypesetterProof.run({source:'x'});
            return {replyAccepted:reply.accepted, reused:reused.code,
              resources:performance.getEntriesByType('resource').length,
              ...globalThis.__proofDiagnostics};
            """, arguments: ["input": fixture, "invocation": invocation], in: nil, contentWorld: world) as? [String: Any],
              var result = acceptedResult else { throw ProofFailure() }
        let pageIsolation = try await web.callAsyncJavaScript("""
            return typeof globalThis.ChatTypesetterProof === 'undefined'
              && !document.documentElement.hasAttribute('data-page-ran');
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        let elapsed = start.duration(to: .now)
        result["durationMs"] = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        let expectedStage = fixture["expectedStage"] as? String
        let goodLabel = fixture["labeled"] as? Bool != true || (result["textNodes"] as? Int ?? 0) > 0
        let pass = result["code"] as? String == fixture["expected"] as? String
            && (expectedStage == nil || result["stage"] as? String == expectedStage) && goodLabel
            && observation["replyAccepted"] as? Bool == true && observation["reused"] as? String == "realm_consumed"
            && observation["resources"] as? Int == 0 && observation["consoleCalls"] as? Int == 0
            && observation["errors"] as? Int == 0 && observation["cspViolations"] as? Int == 0
            && pageIsolation == true && documentLoads == 1 && bridgeCalls == 1
            && rejectedRequests == 0 && rejectedNavigations == 0 && !terminated
            && !web.configuration.websiteDataStore.isPersistent
            && !web.configuration.defaultWebpagePreferences.allowsContentJavaScript
        result["id"] = fixture["id"]; result["expected"] = fixture["expected"]
        result["observation"] = observation; result["pageIsolation"] = pageIsolation
        result["documentLoads"] = documentLoads; result["bridgeCalls"] = bridgeCalls
        result["rejectedRequests"] = rejectedRequests; result["rejectedNavigations"] = rejectedNavigations
        result["passed"] = pass
        return result
    }

    func close() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "proof", contentWorld: world)
        web.configuration.userContentController.removeAllUserScripts()
        web.navigationDelegate = nil
        web.stopLoading()
        web = nil
        // Called only after the awaited terminal result of our synchronous
        // fixture. This does NOT claim process termination or cancellation.
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        bridgeCalls += 1
        guard message.webView === web, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], body["invocation"] as? String == invocation,
              acceptedResult == nil, let result = body["result"] as? [String: Any],
              JSONSerialization.isValidJSONObject(result),
              let encoded = try? JSONSerialization.data(withJSONObject: result), encoded.count <= 2048 else {
            return (["accepted": false], nil)
        }
        acceptedResult = result
        return (["accepted": true], nil)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard urlSchemeTask.request.url == url, documentLoads == 0 else {
            rejectedRequests += 1
            urlSchemeTask.didFailWithError(ProofFailure()); return
        }
        documentLoads += 1
        // Inline script is deliberately permitted by CSP, then disabled by the
        // WK preference. Its marker must remain absent. All resources denied.
        let html = """
        <!doctype html><html><head><meta http-equiv="Content-Security-Policy"
        content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; font-src 'none'">
        <script>document.documentElement.setAttribute('data-page-ran','yes')</script>
        </head><body></body></html>
        """
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: html.utf8.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(Data(html.utf8)); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.request.url == url && navigationAction.targetFrame?.isMainFrame == true { return .allow }
        rejectedNavigations += 1; return .cancel
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(); loaded = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { terminated = true; fail() }
    private func fail() { loaded?.resume(throwing: ProofFailure()); loaded = nil }
}

@main
private struct Main {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        // A timeout aborts the experiment; it never opens a replacement slot.
        let watchdog = Task { @MainActor in
            try await Task.sleep(for: .seconds(55))
            print("{\"passed\":false,\"failure\":\"proof_timeout\"}"); exit(1)
        }
        do {
            guard CommandLine.arguments.count == 2 else { throw ProofFailure() }
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let data = try Data(contentsOf: directory.appendingPathComponent("typesetter.js"))
            let bundle = String(decoding: data, as: UTF8.self)
            let fixtureData = try Data(contentsOf: directory.appendingPathComponent("fixtures.json"))
            guard let fixtures = try JSONSerialization.jsonObject(with: fixtureData) as? [[String: Any]] else { throw ProofFailure() }
            var rows: [[String: Any]] = []
            for fixture in fixtures {
                let harness = Harness(bundle: bundle)
                try await harness.start()
                rows.append(try await harness.run(fixture))
                harness.close()
            }
            let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
            let report: [String: Any] = ["format": 1, "scope": "macOS WKContentWorld component; no iOS layout, sanitizer, tokenizer or hard resource bound",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "bundleSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "fixturesSHA256": SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined(),
                "rows": rows, "passed": passed]
            let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: directory.appendingPathComponent("webkit-results.json"))
            print("{\"cases\":\(rows.count),\"passed\":\(passed)}")
            watchdog.cancel(); exit(passed ? 0 : 1)
        } catch {
            // No potentially source-bearing WebKit exception reaches stdout.
            print("{\"passed\":false,\"failure\":\"proof_harness_failed\"}")
            watchdog.cancel(); exit(1)
        }
    }
}

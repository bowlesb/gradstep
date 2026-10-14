import Foundation
import ScienceReaderCore
import WebKit

enum ArxivHTMLError: Error, Sendable {
    case unavailable, retryLater, retrieval, invalid, tooLarge
    var message: String {
        switch self {
        case .unavailable: "HTML reader unavailable for this version. You can still open the source or its PDF on this device."
        case .retryLater: "arXiv is busy. Please try preparing this paper again later."
        case .retrieval: "Couldn’t retrieve this paper from arXiv. Check your connection and try again."
        case .invalid: "This version’s HTML couldn’t be prepared completely. You can still open its PDF on this device."
        case .tooLarge: "This paper exceeds the device reader’s current preparation limits. You can still open its PDF."
        }
    }
}

/// Serial, bounded acquisition on the reader's network. Nothing is fetched by
/// WebKit: it receives only byte strings after URL, type and size validation.
private actor ArxivHTMLAcquisition {
    static let shared = ArxivHTMLAcquisition()
    private var nextRequest = Date.distantPast

    func fetch(_ url: URL, source: ArxivReaderSource, maximum: Int) async throws -> Data {
        guard url == source.htmlURL || source.admitsAsset(url.absoluteString) else { throw ArxivHTMLError.invalid }
        // Reserve a slot before suspending, including concurrent paper opens.
        let now = Date(), scheduled = max(now, nextRequest)
        nextRequest = scheduled.addingTimeInterval(3)
        if scheduled > now { try await Task.sleep(for: .seconds(scheduled.timeIntervalSince(now))) }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: ArxivNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(url == source.htmlURL ? "text/html" : "image/png,image/jpeg,image/svg+xml", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw ArxivHTMLError.invalid }
        if [404, 410].contains(http.statusCode), url == source.htmlURL { throw ArxivHTMLError.unavailable }
        if http.statusCode == 429 || http.statusCode == 503 {
            // Do not retry early, even if another open arrives on this device.
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            nextRequest = max(nextRequest, Date().addingTimeInterval(min(max(delay, 3), 86_400)))
            throw ArxivHTMLError.retryLater
        }
        guard http.statusCode == 200 else { throw ArxivHTMLError.retrieval }
        let types = url == source.htmlURL ? ["text/html", "application/xhtml+xml"] : ["image/png", "image/jpeg", "image/svg+xml"]
        guard types.contains(http.mimeType?.lowercased() ?? "") else { throw ArxivHTMLError.invalid }
        guard http.expectedContentLength <= maximum else { throw ArxivHTMLError.tooLarge }
        var data = Data(); data.reserveCapacity(min(maximum, max(0, Int(http.expectedContentLength))))
        for try await byte in stream {
            guard data.count < maximum else { throw ArxivHTMLError.tooLarge }
            data.append(byte)
            if data.count % 65_536 == 0 { try Task.checkCancellation() }
        }
        guard !data.isEmpty else { throw ArxivHTMLError.invalid }
        return data
    }
}

private final class ArxivNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // An exact version is required; a redirect cannot silently choose one.
        completionHandler(nil)
    }
}

@MainActor
final class ArxivHTMLReader: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var completion: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var started = false
    private let acquire: @Sendable (URL, ArxivReaderSource, Int) async throws -> Data
    init(acquire: @escaping @Sendable (URL, ArxivReaderSource, Int) async throws -> Data = { url, source, maximum in
        try await ArxivHTMLAcquisition.shared.fetch(url, source: source, maximum: maximum)
    }) { self.acquire = acquire; super.init() }

    func prepare(_ source: ArxivReaderSource) async throws -> VerifiedReaderBundle {
        defer { close() }
        let html = try await acquire(source.htmlURL, source, 2_097_152)
        try await load()
        let arguments: [String: Any] = ["source": html.base64EncodedString(), "sourceID": source.sourceID, "revision": source.revision]
        let references = try await call("return JSON.stringify(GradstepArxivReader.assets(source, sourceID, revision));", arguments: arguments)
        guard let data = references.data(using: .utf8) else { throw ArxivHTMLError.invalid }
        let urls = try JSONDecoder().decode([String].self, from: data)
        guard urls.count <= 512, Set(urls).count == urls.count else { throw ArxivHTMLError.invalid }
        var inputs: [[String: String]] = [], total = html.count
        for reference in urls {
            try Task.checkCancellation()
            guard source.admitsAsset(reference), let url = URL(string: reference) else { throw ArxivHTMLError.invalid }
            let bytes = try await acquire(url, source, min(16_777_216, 33_554_432 - total))
            total += bytes.count
            guard total <= 33_554_432 else { throw ArxivHTMLError.tooLarge }
            inputs.append(["url": reference, "base64": bytes.base64EncodedString()])
        }
        var args = arguments; args["inputs"] = inputs
        let package = try await call("return JSON.stringify(await GradstepArxivReader.prepare(source, sourceID, revision, inputs));", arguments: args)
        try Task.checkCancellation()
        guard let bytes = package.data(using: .utf8) else { throw ArxivHTMLError.invalid }
        let bundle = try DeviceReaderPackage.decode(bytes)
        guard bundle.arxivSource == source else { throw ArxivHTMLError.invalid }
        return try await Task.detached(priority: .userInitiated) { try ReaderBundleLoader.admitImages(in: bundle) }.value
    }

    private func load() async throws {
        guard let path = Bundle.main.url(forResource: "arxiv-reader", withExtension: "js"),
              let script = try? String(contentsOf: path, encoding: .utf8) else { throw ArxivHTMLError.invalid }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self; web = view
        _ = try await operation {
            view.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'none'; connect-src 'none'\"></head><body></body></html>", baseURL: nil)
        }
    }
    private func call(_ body: String, arguments: [String: Any]) async throws -> String {
        guard let web else { throw ArxivHTMLError.invalid }
        return try await operation {
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient) { [weak self] result in
                switch result {
                case .success(let value):
                    if let text = value as? String { self?.finish(.success(text)) }
                    else { self?.finish(.failure(ArxivHTMLError.invalid)) }
                case .failure: self?.finish(.failure(ArxivHTMLError.invalid))
                }
            }
        }
    }
    private func operation(_ start: () -> Void) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(ArxivHTMLError.invalid))
                }
                start()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<String, Error>) {
        timeout?.cancel(); timeout = nil
        let continuation = completion; completion = nil; continuation?.resume(with: result)
    }
    private func close() { finish(.failure(CancellationError())); web?.stopLoading(); web?.navigationDelegate = nil; web = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success("ready")) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(ArxivHTMLError.invalid)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(ArxivHTMLError.invalid)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(ArxivHTMLError.invalid)) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !started, navigationAction.request.url?.absoluteString == "about:blank" else { return .cancel }
        started = true; return .allow
    }
}

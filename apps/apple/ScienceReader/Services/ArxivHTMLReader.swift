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

/// The compiler this app ships (scripts/build-arxiv-compiler.mjs writes `arxiv-reader-build.json` beside it): a stored
/// bundle whose manifest names another build was compiled by an older app and is prepared again when it is opened
/// (ReaderModel.openHTMLReader; owner, build 40: a paper first opened on build 39 still showed the old author block).
struct ArxivCompilerIdentity: Decodable, Sendable, Equatable {
    let rendererID: String
    let revision: Int
    let buildSHA256: String
    enum CodingKeys: String, CodingKey { case rendererID = "renderer_id", revision, buildSHA256 = "build_sha256" }

    static let shipped: ArxivCompilerIdentity? = {
        guard let url = Bundle.main.url(forResource: "arxiv-reader-build", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ArxivCompilerIdentity.self, from: data)
    }()
    /// Whether this app's compiler made the bundle (true when the identity file is missing: never re-prepare blindly).
    static func isCurrent(_ bundle: VerifiedReaderBundle) -> Bool {
        guard let shipped else { return true }
        return bundle.manifest.renderer.id == shipped.rendererID && bundle.manifest.renderer.buildSHA256 == shipped.buildSHA256
    }
}

/// Acquisition pacing. A paper's HTML document request is spaced like a new page visit; that page's own
/// declared assets then load together, bounded, the way a browser loads the images of one page. A
/// Retry-After from arXiv pauses every request from this device.
enum ArxivAcquisitionPolicy {
    static let documentSpacing: TimeInterval = 3
    static let assetConcurrency = 4
    /// A longer pause is reported as "busy" immediately instead of holding the reader open.
    static let busyLimit: TimeInterval = 60
    /// 8 MiB (was 2 MiB; owner, build 40: Apertus 1.5's 2.6 MB HTML was refused as over the limit).
    static let sourceBytes = 8_388_608
    static let assetBytes = 16_777_216
    static let totalBytes = 41_943_040
    static let assets = 512
}

/// Bounded acquisition on the reader's network. Nothing is fetched by WebKit:
/// it receives only byte strings after URL, type and size validation.
private actor ArxivHTMLAcquisition {
    static let shared = ArxivHTMLAcquisition()
    private var nextDocumentRequest = Date.distantPast
    private var busyUntil = Date.distantPast
    #if DEBUG
    /// Tests: URL protocols that answer arxiv.org in-process (no pacing, nothing leaves the process).
    private var fixtureProtocols: [AnyClass]? { ArxivHTMLReader.fixtureProtocolClasses }
    #else
    private var fixtureProtocols: [AnyClass]? { nil }
    #endif

    func fetch(_ url: URL, source: ArxivReaderSource, maximum: Int) async throws -> Data {
        let document = url == source.htmlURL
        guard document || source.admitsAsset(url.absoluteString) else { throw ArxivHTMLError.invalid }
        // Reserve a slot before suspending, including concurrent paper opens.
        let now = Date()
        if busyUntil.timeIntervalSince(now) > ArxivAcquisitionPolicy.busyLimit { throw ArxivHTMLError.retryLater }
        var scheduled = max(now, busyUntil)
        if document {
            scheduled = max(scheduled, nextDocumentRequest)
            nextDocumentRequest = scheduled.addingTimeInterval(ArxivAcquisitionPolicy.documentSpacing)
        }
        if scheduled > now, fixtureProtocols == nil { try await Task.sleep(for: .seconds(scheduled.timeIntervalSince(now))) }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        if let fixtureProtocols { config.protocolClasses = fixtureProtocols }
        let session = URLSession(configuration: config, delegate: ArxivNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(document ? "text/html" : "image/png,image/jpeg,image/svg+xml", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw ArxivHTMLError.invalid }
        if [404, 410].contains(http.statusCode), document { throw ArxivHTMLError.unavailable }
        if http.statusCode == 429 || http.statusCode == 503 {
            // Do not retry early, even if another open arrives on this device.
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            busyUntil = max(busyUntil, Date().addingTimeInterval(min(max(delay, 3), 86_400)))
            nextDocumentRequest = max(nextDocumentRequest, busyUntil)
            throw ArxivHTMLError.retryLater
        }
        guard http.statusCode == 200 else { throw ArxivHTMLError.retrieval }
        let types = document ? ["text/html", "application/xhtml+xml"] : ["image/png", "image/jpeg", "image/svg+xml"]
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
    #if DEBUG
    /// Tests only: protocols for the acquisition session, so a fixture answers arxiv.org without the network or pacing.
    nonisolated(unsafe) static var fixtureProtocolClasses: [AnyClass]?
    #endif
    private var web: WKWebView?
    private var completion: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var started = false
    private let acquire: @Sendable (URL, ArxivReaderSource, Int) async throws -> Data
    init(acquire: @escaping @Sendable (URL, ArxivReaderSource, Int) async throws -> Data = { url, source, maximum in
        try await ArxivHTMLAcquisition.shared.fetch(url, source: source, maximum: maximum)
    }) { self.acquire = acquire; super.init() }

    /// `authors`: the library's author names for this paper; the compiler shows them when the HTML's own names are
    /// graphics or missing (a team logo). Every device of one library passes the same names, so the bundle is the same.
    func prepare(_ source: ArxivReaderSource, authors: [String] = []) async throws -> VerifiedReaderBundle {
        defer { close() }
        let html = try await acquire(source.htmlURL, source, ArxivAcquisitionPolicy.sourceBytes)
        try await load()
        let arguments: [String: Any] = ["source": html.base64EncodedString(), "sourceID": source.sourceID, "revision": source.revision]
        let references = try await call("return JSON.stringify(GradstepArxivReader.assets(source, sourceID, revision));", arguments: arguments)
        guard let data = references.data(using: .utf8) else { throw ArxivHTMLError.invalid }
        let urls = try JSONDecoder().decode([String].self, from: data)
        guard urls.count <= ArxivAcquisitionPolicy.assets, Set(urls).count == urls.count else { throw ArxivHTMLError.invalid }
        let inputs = try await fetchAssets(urls, source: source, used: html.count)
        var args = arguments; args["inputs"] = inputs
        args["options"] = ["authors": Array(authors.map { String($0.prefix(256)) }.prefix(64))]
        let package = try await call("return JSON.stringify(await GradstepArxivReader.prepare(source, sourceID, revision, inputs, options));", arguments: args)
        try Task.checkCancellation()
        guard let bytes = package.data(using: .utf8) else { throw ArxivHTMLError.invalid }
        let bundle = try DeviceReaderPackage.decode(bytes)
        guard bundle.arxivSource == source else { throw ArxivHTMLError.invalid }
        return try await Task.detached(priority: .userInitiated) { try ReaderBundleLoader.admitImages(in: bundle) }.value
    }

    /// The declared assets of one paper, in declaration order, at most `assetConcurrency` in flight and within the
    /// total byte budget. One failure cancels the others.
    private func fetchAssets(_ urls: [String], source: ArxivReaderSource, used: Int) async throws -> [[String: String]] {
        let assets = try urls.map { reference -> URL in
            guard source.admitsAsset(reference), let url = URL(string: reference) else { throw ArxivHTMLError.invalid }
            return url
        }
        var inputs = [[String: String]?](repeating: nil, count: assets.count)
        var total = used
        let acquire = self.acquire
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func start() {
                guard next < assets.count else { return }
                let index = next, bound = min(ArxivAcquisitionPolicy.assetBytes, ArxivAcquisitionPolicy.totalBytes - total)
                next += 1
                group.addTask { (index, try await acquire(assets[index], source, bound)) }
            }
            for _ in 0..<ArxivAcquisitionPolicy.assetConcurrency { start() }
            while let (index, data) = try await group.next() {
                try Task.checkCancellation()
                total += data.count
                guard total <= ArxivAcquisitionPolicy.totalBytes else { throw ArxivHTMLError.tooLarge }
                inputs[index] = ["url": urls[index], "base64": data.base64EncodedString()]
                start()
            }
        }
        return try inputs.map { input in
            guard let input else { throw ArxivHTMLError.invalid }
            return input
        }
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

import Foundation
import os
import ScienceReaderCore
import WebKit

enum ArxivHTMLError: Error, Sendable {
    case unavailable, retryLater, retrieval, invalid, tooLarge
    /// arXiv refused this device (403): no arXiv request from it for a day (`ArxivDeviceRefusal`).
    case refused
    /// The device compiler refused the paper with one of its finite reason codes (never source text).
    case compiler(String)
    /// One image arXiv didn't serve (not found, not an image, too large on its own): its figure says so and the paper
    /// opens (`fetchAssets`). Never shown on its own.
    case assetMissing
    var message: String {
        switch self {
        case .unavailable: "arXiv couldn’t make a web version of this paper, which the reader needs. Its PDF downloads from arXiv to this device."
        case .retryLater: "arXiv is busy. Please try preparing this paper again later."
        case .refused: "arXiv refused requests from this device, so Gradstep won’t ask arXiv from it again for a day. Papers already on this device still open."
        case .retrieval: "Couldn’t retrieve this paper from arXiv. Check your connection and try again."
        case .invalid, .assetMissing: "This version’s HTML couldn’t be prepared completely. You can still open its PDF on this device."
        case .tooLarge: "This paper exceeds the device reader’s current preparation limits. You can still open its PDF."
        case .compiler(let code): ArxivCompilerFailure.message(for: code)
        }
    }
}

/// What a paper the HTML reader couldn't show offers instead (build 57: 2610.20399 has no arXiv HTML, and the screen said
/// "you can still open its PDF" with only Try again under it). The PDF is fetched by this device, as any arXiv request is.
enum ReaderOpenFallback: Equatable, Sendable {
    case none
    /// The reader couldn't prepare this version: its PDF, beside Try again.
    case pdf
    /// arXiv has no HTML for this version (404): only its PDF; trying again can't help.
    case pdfOnly

    init(_ error: Error) {
        switch error as? ArxivHTMLError {
        case .unavailable: self = .pdfOnly
        // arXiv busy, refused or unreachable: its PDF would fail the same way.
        case .retryLater, .refused, .retrieval: self = .none
        default: self = .pdf
        }
    }
}

/// The compiler's reason codes by category: the same table as the browser's compiler frame
/// (`apps/web/src/reader/arxiv-compiler-host.js`; `tests/backend/reader-failure-categories.test.ts` keeps the two
/// equal and every converter code listed). A refusal used to collapse to one message with nothing logged (audit,
/// 2026-10-15; owner screenshot of 2610.15371: no way to tell what had refused).
enum ArxivCompilerFailure {
    static let categories: [(name: String, codes: [String])] = [
        ("source-incomplete", ["arxiv_conversion_error"]),
        ("source-unavailable", ["arxiv_article", "arxiv_identity"]),
        ("limit", ["source_limit", "bundle_limit", "manifest_limit", "html_limit", "block_limit", "heading_limit", "image_limit", "image_total_limit", "image_dimensions", "image_dimensions_exceeded", "svg_dimensions", "base64_limit"]),
        ("math", ["arxiv_math_attribute", "arxiv_math_element", "arxiv_math_style", "arxiv_math_semantics", "arxiv_math_source", "arxiv_math_mismatch", "arxiv_math_empty", "arxiv_math_coverage", "arxiv_math_duplicate", "arxiv_equation"]),
        ("figure", ["arxiv_asset_url", "arxiv_asset_type", "arxiv_inline_svg", "arxiv_asset", "arxiv_asset_set", "arxiv_asset_missing", "arxiv_asset_coverage", "image_decode", "image_timeout", "svg_attribute", "svg_doctype", "svg_element", "svg_fragment", "svg_id", "svg_invalid", "svg_resource", "svg_style", "invalid_image"]),
        ("reference", ["arxiv_duplicate_id", "arxiv_unresolved_fragment", "arxiv_fragment"]),
        ("formatting", ["arxiv_nested_content", "arxiv_list", "arxiv_table_span", "arxiv_caption", "arxiv_figure", "arxiv_node", "arxiv_title", "arxiv_block_text", "arxiv_alt"]),
    ]
    static func category(for code: String) -> String { categories.first { $0.codes.contains(code) }?.name ?? "unknown" }
    /// The reader's words for the category, the same as the browser's.
    static func message(for code: String) -> String {
        let text: String = switch category(for: code) {
        case "source-incomplete": "arXiv’s HTML for this version contains a conversion error."
        case "source-unavailable": "arXiv did not return readable HTML for this version."
        case "limit": "This paper exceeds the device reader’s preparation limits."
        case "math": "The HTML reader couldn’t preserve an equation in this paper."
        case "figure": "A figure in this paper couldn’t be prepared on this device."
        case "reference": "The HTML reader couldn’t resolve this paper’s internal references."
        case "formatting": "The HTML reader doesn’t yet support part of this paper’s formatting."
        default: "This version’s HTML couldn’t be prepared completely."
        }
        return text + " You can still open its PDF on this device."
    }
    /// The reason code in a WebKit JavaScript exception, when the compiler threw one (its error's message is the
    /// code, so the message ends with it); a browser error of its own ("undefined is not an object") is none.
    static func code(in error: Error) -> String? {
        guard let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String,
              let range = message.range(of: "[a-z][a-z0-9]*_[a-z0-9_]+$", options: .regularExpression) else { return nil }
        return String(message[range])
    }
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScienceReader", category: "arxiv-reader")
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
/// Retry-After from arXiv pauses every request from this device; a refusal (403) stops them for a day, shared with the
/// export API fetcher (`ArxivDeviceRefusal`; owner, 2026-10-15).
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
    /// Every arXiv request from this app names it, with no user identifier (owner, 2026-10-15; ARXIV_DEVICE_ONLY.md §5.9).
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        #if targetEnvironment(macCatalyst)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return "Gradstep/\(version) (\(platform); +https://gradstep.ai; mailto:hello@gradstep.ai)"
    }
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
    private var refusal: ArxivDeviceRefusal { ArxivDeviceRefusal(suite: ArxivHTMLReader.refusalSuite) }
    #else
    private var fixtureProtocols: [AnyClass]? { nil }
    private var refusal: ArxivDeviceRefusal { ArxivDeviceRefusal() }
    #endif

    func fetch(_ url: URL, source: ArxivReaderSource, maximum: Int) async throws -> Data {
        let document = url == source.htmlURL
        guard document || source.admitsAsset(url.absoluteString) else { throw ArxivHTMLError.invalid }
        // Reserve a slot before suspending, including concurrent paper opens.
        let now = Date()
        if refusal.until(now: now) != nil { throw ArxivHTMLError.refused }
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
        request.setValue(ArxivAcquisitionPolicy.userAgent, forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw ArxivHTMLError.invalid }
        if [404, 410].contains(http.statusCode), document { throw ArxivHTMLError.unavailable }
        if http.statusCode == 403 { refusal.record(now: Date()); throw ArxivHTMLError.refused }
        if http.statusCode == 429 || http.statusCode == 503 {
            // Do not retry early, even if another open arrives on this device.
            let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            busyUntil = max(busyUntil, Date().addingTimeInterval(min(max(delay, 3), 86_400)))
            nextDocumentRequest = max(nextDocumentRequest, busyUntil)
            throw ArxivHTMLError.retryLater
        }
        // One image arXiv doesn't serve (not found, a redirect, not an image, too large on its own, empty) is that
        // figure's loss, not the paper's; a server error, arXiv being busy or refusing, and the paper's remaining byte
        // budget still stop the preparation (2026-10-16, "degrade, don't refuse").
        let missing = { (error: ArxivHTMLError) in document ? error : ArxivHTMLError.assetMissing }
        guard http.statusCode == 200 else { throw http.statusCode < 500 ? missing(.retrieval) : ArxivHTMLError.retrieval }
        let types = document ? ["text/html", "application/xhtml+xml"] : ["image/png", "image/jpeg", "image/svg+xml"]
        guard types.contains(http.mimeType?.lowercased() ?? "") else { throw missing(.invalid) }
        let tooLarge = maximum >= ArxivAcquisitionPolicy.assetBytes ? missing(.tooLarge) : ArxivHTMLError.tooLarge
        guard http.expectedContentLength <= maximum else { throw tooLarge }
        var data = Data(); data.reserveCapacity(min(maximum, max(0, Int(http.expectedContentLength))))
        for try await byte in stream {
            guard data.count < maximum else { throw tooLarge }
            data.append(byte)
            if data.count % 65_536 == 0 { try Task.checkCancellation() }
        }
        guard !data.isEmpty else { throw missing(.invalid) }
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
    /// Tests only: where the device's arXiv refusal is kept, instead of the app's own defaults.
    nonisolated(unsafe) static var refusalSuite: String?
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
    /// Preparation as the reader sees it: one fraction, "Downloading…" through the HTML and its assets (0–0.8), then
    /// "Preparing…" through the compile and the image admission (0.8–1).
    static func phase(for fraction: Double) -> String { fraction < 0.8 ? "Downloading…" : "Preparing…" }

    /// `onSource`: the page's bytes once downloaded, for the metadata this device reads from them
    /// (SourceMetadataReporter; nil unless the server asks for it).
    func prepare(_ source: ArxivReaderSource, authors: [String] = [], title: String? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in },
                 onSource: (@Sendable (Data) -> Void)? = nil) async throws -> VerifiedReaderBundle {
        defer { close() }
        progress(0.02)
        let html = try await acquire(source.htmlURL, source, ArxivAcquisitionPolicy.sourceBytes)
        onSource?(html)
        progress(0.12)
        try await load()
        // The catalog record goes with both calls: a paper whose HTML has no `h1` or no author block is headed from it.
        var options: [String: Any] = ["authors": Array(authors.map { String($0.prefix(256)) }.prefix(64))]
        if let title, !title.isEmpty { options["title"] = String(title.prefix(2000)) }
        let arguments: [String: Any] = ["source": html.base64EncodedString(), "sourceID": source.sourceID, "revision": source.revision, "options": options]
        let references = try await call("return JSON.stringify(GradstepArxivReader.assets(source, sourceID, revision, options));", arguments: arguments)
        guard let data = references.data(using: .utf8) else { throw ArxivHTMLError.invalid }
        let urls = try JSONDecoder().decode([String].self, from: data)
        guard urls.count <= ArxivAcquisitionPolicy.assets, Set(urls).count == urls.count else { throw ArxivHTMLError.invalid }
        let inputs = try await fetchAssets(urls, source: source, used: html.count) { done, count in progress(0.12 + 0.68 * (count == 0 ? 1 : Double(done) / Double(count))) }
        progress(0.82)
        var args = arguments; args["inputs"] = inputs
        let package = try await call("return JSON.stringify(await GradstepArxivReader.prepare(source, sourceID, revision, inputs, options));", arguments: args)
        try Task.checkCancellation()
        guard let bytes = package.data(using: .utf8) else { throw ArxivHTMLError.invalid }
        let bundle = try DeviceReaderPackage.decode(bytes)
        guard bundle.arxivSource == source else { throw ArxivHTMLError.invalid }
        progress(0.94)
        let admitted = try await Task.detached(priority: .userInitiated) { try ReaderBundleLoader.admitImages(in: bundle) }.value
        progress(1)
        return admitted
    }

    /// The declared assets of one paper, in declaration order, at most `assetConcurrency` in flight and within the
    /// total byte budget. An image arXiv didn't serve goes as `missing` (its figure says so); any other failure cancels
    /// the others.
    private func fetchAssets(_ urls: [String], source: ArxivReaderSource, used: Int, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> [[String: Any]] {
        let assets = try urls.map { reference -> URL in
            guard source.admitsAsset(reference), let url = URL(string: reference) else { throw ArxivHTMLError.invalid }
            return url
        }
        var inputs = [[String: Any]?](repeating: nil, count: assets.count)
        var total = used
        let acquire = self.acquire
        try await withThrowingTaskGroup(of: (Int, Data?).self) { group in
            var next = 0
            func start() {
                guard next < assets.count else { return }
                let index = next, bound = min(ArxivAcquisitionPolicy.assetBytes, ArxivAcquisitionPolicy.totalBytes - total)
                next += 1
                group.addTask {
                    do { return (index, try await acquire(assets[index], source, bound)) }
                    catch ArxivHTMLError.assetMissing { return (index, nil) }
                }
            }
            for _ in 0..<ArxivAcquisitionPolicy.assetConcurrency { start() }
            var done = 0
            while let (index, data) = try await group.next() {
                try Task.checkCancellation()
                done += 1; progress(done, assets.count)
                if let data {
                    total += data.count
                    guard total <= ArxivAcquisitionPolicy.totalBytes else { throw ArxivHTMLError.tooLarge }
                    inputs[index] = ["url": urls[index], "base64": data.base64EncodedString()]
                } else {
                    inputs[index] = ["url": urls[index], "missing": true]
                }
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
                case .failure(let error):
                    // The code, never the exception text (it may carry source text or browser details).
                    if let code = ArxivCompilerFailure.code(in: error) {
                        ArxivCompilerFailure.log.error("device compiler refused the paper: \(code, privacy: .public) (\(ArxivCompilerFailure.category(for: code), privacy: .public))")
                        self?.finish(.failure(ArxivHTMLError.compiler(code)))
                    } else {
                        ArxivCompilerFailure.log.error("device compiler call failed without a reason code")
                        self?.finish(.failure(ArxivHTMLError.invalid))
                    }
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

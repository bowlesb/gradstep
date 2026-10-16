import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// "Download on this device" (docs/architecture/PDF_UPLOADS.md): the server's link and address rules, and
/// the fetch itself against a scripted network.
final class DevicePDFFetcherTests: XCTestCase {
    func testLinksAndAddressesFollowTheServerRules() {
        XCTAssertEqual(DeviceLinkPolicy.publicHTTPS(URL(string: "http://repo.example.org/a.pdf#x")!)?.absoluteString, "https://repo.example.org/a.pdf",
                       "http is upgraded, the fragment dropped")
        for refused in ["https://10.0.0.1/a.pdf", "https://[::1]/a.pdf", "https://localhost/a.pdf", "https://printer.local/a.pdf",
                        "https://repo.example.org:8443/a.pdf", "https://user:pass@repo.example.org/a.pdf", "ftp://repo.example.org/a.pdf", "https://intranet/a.pdf"] {
            XCTAssertNil(DeviceLinkPolicy.publicHTTPS(URL(string: refused)!), refused)
        }
        for address in ["10.1.2.3", "127.0.0.1", "192.168.1.203", "169.254.1.1", "100.64.0.1", "172.16.0.1", "0.0.0.0", "224.0.0.1",
                        "::1", "::", "fe80::1", "fc00::1", "2001:db8::1", "2002::1", "::ffff:10.0.0.1", "not an address"] {
            XCTAssertFalse(DeviceLinkPolicy.isPublicAddress(address), address)
        }
        for address in ["93.184.216.34", "8.8.8.8", "2606:4700::1111", "::ffff:93.184.216.34"] {
            XCTAssertTrue(DeviceLinkPolicy.isPublicAddress(address), address)
        }
    }

    func testLandingPagesDeclareTheirPDF() {
        let base = URL(string: "https://proceedings.example.org/v202/paper.html")!
        XCTAssertEqual(LandingPage.pdfLink(#"<meta name="citation_pdf_url" content="/v202/paper.pdf">"#, base: base)?.absoluteString,
                       "https://proceedings.example.org/v202/paper.pdf")
        XCTAssertEqual(LandingPage.pdfLink(#"<meta content='http://cdn.example.org/p.pdf?download=1&amp;v=2' name=CITATION_PDF_URL>"#, base: base)?.absoluteString,
                       "https://cdn.example.org/p.pdf?download=1&v=2")
        XCTAssertEqual(LandingPage.pdfLink(#"<link rel="alternate" type="application/pdf" href="alt.pdf">"#, base: base)?.absoluteString,
                       "https://proceedings.example.org/v202/alt.pdf")
        XCTAssertEqual(LandingPage.pdfLink(#"<iframe src="https://viewer.example.org/stamp.pdf"></iframe>"#, base: base)?.absoluteString,
                       "https://viewer.example.org/stamp.pdf")
        XCTAssertNil(LandingPage.pdfLink(#"<meta name="citation_pdf_url" content="https://192.168.1.1/p.pdf">"#, base: base))
        XCTAssertEqual(LandingPage.title(#"<meta name="citation_title" content="A Watermark for Large Language Models">"#), "A Watermark for Large Language Models")
        XCTAssertEqual(LandingPage.refusal("<title>Just a moment...</title><div class=\"cf-turnstile\"></div>", url: base, status: 403), .blocked)
        XCTAssertEqual(LandingPage.refusal("<form><input type=\"password\"></form>", url: base, status: 200), .restricted)
        XCTAssertEqual(LandingPage.refusal("<p>A blog post</p>", url: base, status: 200), .notPDF)
    }

    // MARK: Fetching against a scripted network

    private func fetcher(_ routes: [String: ScriptedResponse], resolve: @escaping @Sendable (String) -> [String] = { _ in ["93.184.216.34"] }) -> DevicePDFFetcher {
        ScriptedProtocol.routes = routes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        return DevicePDFFetcher(resolve: { resolve($0) }, configuration: configuration)
    }
    private let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x20, count: 200_000)

    /// "Open PDF" on a paper without arXiv HTML (build 57): arXiv hears from the app by name, and not at all for a day
    /// after it refused this device, as with the reader's own requests.
    func testAnArxivPDFNamesTheAppAndRespectsARefusal() async throws {
        let suite = "arxiv.pdf.test.\(UUID().uuidString)"
        ArxivHTMLReader.refusalSuite = suite
        defer { ArxivHTMLReader.refusalSuite = nil; UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        ScriptedProtocol.userAgents = []
        let link = URL(string: "https://arxiv.org/pdf/2610.20399v1")!
        let fetched = try await fetcher([link.absoluteString: .init(body: pdf)]).fetch([link]) { _ in }
        try? FileManager.default.removeItem(at: fetched.file)
        XCTAssertTrue(ScriptedProtocol.userAgents.first?.hasPrefix("Gradstep/") == true, "\(ScriptedProtocol.userAgents)")
        ArxivDeviceRefusal(suite: suite).record(now: Date())
        do { _ = try await fetcher([link.absoluteString: .init(body: pdf)]).fetch([link]) { _ in }; XCTFail("refused") }
        catch { XCTAssertEqual(error as? DeviceFetchError, .blocked) }
        XCTAssertEqual(ScriptedProtocol.userAgents.count, 1, "nothing asked of arXiv after its refusal")
    }

    func testAPDFAPageThatDeclaresOneAndTheNextLinkAfterARefusal() async throws {
        let direct = try await fetcher(["https://repo.example.org/a.pdf": .init(body: pdf)]).fetch([URL(string: "https://repo.example.org/a.pdf")!]) { _ in }
        XCTAssertEqual(try Data(contentsOf: direct.file), pdf)
        let page = #"<html><head><meta name="citation_title" content="Sparse Attention"><meta name="citation_pdf_url" content="/files/p.pdf"></head></html>"#
        let landing = try await fetcher([
            "https://publisher.example.com/article/1": .init(status: 302, headers: ["Location": "/article/1/full"]),
            "https://publisher.example.com/article/1/full": .init(body: Data(page.utf8), headers: ["Content-Type": "text/html"]),
            "https://publisher.example.com/files/p.pdf": .init(body: pdf),
        ]).fetch([URL(string: "https://publisher.example.com/article/1")!]) { _ in }
        XCTAssertEqual(landing.title, "Sparse Attention")
        XCTAssertEqual(landing.link.absoluteString, "https://publisher.example.com/files/p.pdf")
        let fallback = try await fetcher([
            "https://blocked.example.org/a.pdf": .init(status: 403, body: Data("<title>Just a moment...</title>".utf8), headers: ["cf-mitigated": "challenge"]),
            "https://mirror.example.net/a.pdf": .init(body: pdf),
        ]).fetch([URL(string: "https://blocked.example.org/a.pdf")!, URL(string: "https://mirror.example.net/a.pdf")!]) { _ in }
        XCTAssertEqual(fallback.link.host(), "mirror.example.net")
    }

    func testRefusalsUnsafeHopsAndSizeAreReported() async throws {
        func outcome(_ routes: [String: ScriptedResponse], _ link: String, resolve: @escaping @Sendable (String) -> [String] = { _ in ["93.184.216.34"] }) async -> DeviceFetchError? {
            do { _ = try await fetcher(routes, resolve: resolve).fetch([URL(string: link)!]) { _ in }; return nil }
            catch { return error as? DeviceFetchError }
        }
        let challenge = await outcome(["https://dl.example.org/doi/1": .init(status: 403, body: Data(#"<div class="cf-turnstile"></div>"#.utf8))], "https://dl.example.org/doi/1")
        XCTAssertEqual(challenge, .blocked)
        let signIn = await outcome(["https://journal.example.org/pdf/1": .init(status: 302, headers: ["Location": "https://idp.example.org/login"]),
                                    "https://idp.example.org/login": .init(body: Data(#"<form><input type="password"></form>"#.utf8))], "https://journal.example.org/pdf/1")
        XCTAssertEqual(signIn, .restricted)
        let internalHop = await outcome(["https://repo.example.org/a": .init(status: 302, headers: ["Location": "https://files.example.org/a.pdf"])],
                                        "https://repo.example.org/a", resolve: { $0 == "files.example.org" ? ["10.0.0.7"] : ["93.184.216.34"] })
        XCTAssertEqual(internalHop, .unsafe, "a redirect to a private address is refused before any request")
        let ipLiteral = await outcome([:], "https://192.168.1.203/paper.pdf")
        XCTAssertEqual(ipLiteral, .unsafe)
        let noPDF = await outcome(["https://blog.example.org/p": .init(body: Data("<p>hello</p>".utf8))], "https://blog.example.org/p")
        XCTAssertEqual(noPDF, .notPDF)
        let huge = await outcome(["https://repo.example.org/big.pdf": .init(body: pdf, headers: ["Content-Length": "70000000"])], "https://repo.example.org/big.pdf")
        XCTAssertEqual(huge, .tooLarge)
        let busy = await outcome(["https://repo.example.org/a.pdf": .init(status: 503)], "https://repo.example.org/a.pdf")
        XCTAssertEqual(busy, .unreachable)
    }

    @MainActor
    func testFailedImportsOfferTheRightNextStep() throws {
        func record(source: String, sourceID: String, url: String?, error: String) throws -> LibraryImportRecord {
            var value: [String: Any] = ["id": UUID().uuidString.lowercased(), "created_seq": 1, "state_seq": 1, "intent_revision": 1, "visible": true,
                "phase": "failed", "source": source, "source_id": sourceID, "error_code": error, "retryable": true]
            value["source_url"] = url ?? NSNull()
            return try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let web = { (error: String) in try record(source: "web", sourceID: "openalex:W1", url: "https://openalex.org/works/W1", error: error) }
        XCTAssertEqual(LibraryImportAction.available(for: try web("source_blocked"), retrying: false), .downloadOnDevice)
        XCTAssertEqual(LibraryImportAction.available(for: try web("pdf_restricted"), retrying: false), .downloadOnDevice)
        XCTAssertEqual(LibraryImportAction.available(for: try web("not_open"), retrying: false), .uploadPDF)
        XCTAssertEqual(LibraryImportAction.available(for: try web("download_failed"), retrying: false), .retry)
        XCTAssertTrue(try web("download_failed").canDownloadOnDevice, "still offered in the row's menu")
        let upload = try record(source: "upload", sourceID: "upload:31000000-0000-4000-8000-0000000000a1", url: nil, error: "upload_failed")
        XCTAssertEqual(LibraryImportAction.available(for: upload, retrying: false), .uploadPDF)
        XCTAssertFalse(upload.canDownloadOnDevice)
        // Its PDF saved on this device (PDFs stay on the device, so the import stays failed): open it, don't fetch it again.
        XCTAssertEqual(LibraryImportAction.available(for: try web("source_blocked"), retrying: false, localPaperAvailable: true), .openLocalPDF)
        XCTAssertEqual(LibraryImportAction.available(for: upload, retrying: false, localPaperAvailable: true), .openLocalPDF)
        let arxiv = try record(source: "arxiv", sourceID: "2305.18290", url: "https://arxiv.org/abs/2305.18290", error: "source_blocked")
        XCTAssertEqual(LibraryImportAction.available(for: arxiv, retrying: false), .retry, "arXiv papers always come from arXiv")
        XCTAssertEqual(LibraryImportAction.available(for: arxiv, retrying: false, localPaperAvailable: true), .retry, "… a local copy changes nothing there")
        XCTAssertFalse(arxiv.canTakeUpload)

        var sourceOnly: [String: Any] = ["id": UUID().wire, "created_seq": 2, "state_seq": 2, "intent_revision": 1,
            "visible": true, "phase": "source_only", "source": "arxiv", "source_id": "2401.12345",
            "source_url": "https://arxiv.org/abs/2401.12345v2", "source_revision": 2, "metadata_id": UUID().wire,
            "version_id": UUID().wire, "metadata_recorded_at": "2026-10-09T06:00:00Z",
            "metadata": ["title": "Source-only paper", "authors": ["A B"], "categories": ["cs.LG"]],
            "error_code": "license_unverified", "retryable": false]
        let local = try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: sourceOnly))
        XCTAssertEqual(LibraryImportAction.available(for: local, retrying: false), .downloadOnDevice)
        XCTAssertTrue(local.canDownloadOnDevice)
        XCTAssertEqual(LibraryImportAction.available(for: local, retrying: false, localPaperAvailable: true), .openLocalPDF)
    }
}

struct ScriptedResponse: Sendable {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
}

final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: ScriptedResponse] = [:]
    nonisolated(unsafe) static var userAgents: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.userAgents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "")
        guard let url = request.url, let route = Self.routes[url.absoluteString],
              let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !route.body.isEmpty { client?.urlProtocol(self, didLoad: route.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

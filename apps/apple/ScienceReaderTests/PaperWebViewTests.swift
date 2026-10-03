import SwiftUI
import WebKit
import XCTest
@testable import ScienceReader

@MainActor
final class PaperWebViewTests: XCTestCase {
    func testContentsPreserveArtifactAnchorsAndUseThemForNavigation() async throws {
        let document = """
        <h1 id="paper-introduction">Introduction</h1>
        <div id="sr-heading-1"></div>
        <h2>  A heading without an ID  </h2>
        <h2 id="duplicate">Ambiguous heading</h2><p id="duplicate">Duplicate source ID</p>
        <a id="intro-link" href="#paper-introduction">Back to introduction</a>
        <div style="height:1500px"></div>
        <h2 id="equation-section">Equations</h2>
        <p>Equation references and section links retain their original destination.</p>
        <div style="height:1000px"></div>
        """
        let harness = try Harness(document: document,
                                  jump: PaperJumpRequest(locationKey: "fixture-artifact", headingID: "equation-section"))
        defer { harness.close() }
        await fulfillment(of: [harness.loaded, harness.jumped], timeout: 15)
        let web = try XCTUnwrap(harness.web)
        XCTAssertEqual(harness.headings.map(\.title), ["Introduction", "A heading without an ID", "Ambiguous heading", "Equations"])
        XCTAssertEqual(harness.headings.first?.id, "paper-introduction")
        XCTAssertEqual(harness.headings.last?.id, "equation-section")
        XCTAssertEqual(Set(harness.headings.map(\.id)).count, harness.headings.count)
        XCTAssertNotEqual(harness.headings[1].id, "sr-heading-1", "Fallback must not steal a different element's ID")
        XCTAssertNotEqual(harness.headings[2].id, "duplicate", "Ambiguous source IDs must not point Contents at another element")
        let identities = try await web.evaluateJavaScript("""
            document.querySelector('h2[id="duplicate"]').id==='duplicate'
            && document.getElementById('duplicate').tagName==='H2'
            && document.querySelectorAll('h2')[0].id===''
            """) as? Bool
        XCTAssertEqual(identities, true, "Private Contents keys do not mutate absent or duplicate source IDs")
        let position = try await web.evaluateJavaScript("document.getElementById('equation-section').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(position), 0, accuracy: 2, "Contents jumps to the retained renderer ID")
        let link = try await web.evaluateJavaScript("""
            document.getElementById('intro-link').getAttribute('href') === '#paper-introduction'
            && document.getElementById('paper-introduction').tagName === 'H1'
            """) as? Bool
        XCTAssertEqual(link, true, "The artifact's internal link still resolves to its original heading")
        _ = try await web.callAsyncJavaScript("""
            document.getElementById('intro-link').click();
            await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
            """, arguments: [:], in: nil, contentWorld: .page)
        let returned = try await web.evaluateJavaScript("document.getElementById('paper-introduction').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(returned), 0, accuracy: 2, "An in-paper fragment link remains navigable after the contents jump")
        let duplicateJump = try await web.callAsyncJavaScript(
            "return window.__scienceReaderJumpToHeading(key,true);",
            arguments: ["key": harness.headings[2].id], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(duplicateJump, true)
        let duplicatePosition = try await web.evaluateJavaScript("document.querySelector('h2[id=\"duplicate\"]').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(duplicatePosition), 0, accuracy: 2)
    }

    func testContentsBridgeBoundsHeadingsAndIgnoresEmptyTitles() async throws {
        let many = (0..<520).map { "<h2 id='section-\($0)'>Section \($0)</h2>" }.joined()
        let document = "<h1> \n </h1><h1 id='oversized-\(String(repeating: "a", count: 520))'>\(String(repeating: "x", count: 3000))</h1>" + many
        let harness = try Harness(document: document)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        XCTAssertEqual(harness.headings.count, 500)
        XCTAssertEqual(harness.headings.first?.title.count, 2_000)
        XCTAssertLessThan(try XCTUnwrap(harness.headings.first?.id.count), 512)
        XCTAssertFalse(harness.headings.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertEqual(harness.headings.last?.id, "section-498")
        let original = try await XCTUnwrap(harness.web).evaluateJavaScript("document.querySelectorAll('h1')[1].id.length") as? Int
        XCTAssertEqual(original, 530, "An oversized existing source anchor remains intact")
    }

    @MainActor
    private final class Harness {
        let loaded = XCTestExpectation(description: "Offline reader loaded")
        let jumped = XCTestExpectation(description: "Contents jump applied")
        var headings: [PaperHeading] = []
        private var didLoad = false
        private var didJump = false
        private let directory: URL
        private let window: UIWindow
        private let previousKeyWindow: UIWindow?
        private var controller: UIHostingController<PaperWebView>?

        init(document: String, jump: PaperJumpRequest? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("paper.html")
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <style>body{margin:0;font-family:system-ui}h1,h2{margin:0;padding:16px 0}</style>
            </head><body>\(document)</body></html>
            """
            try Data(html.utf8).write(to: file)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKeyWindow = scene.keyWindow
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            let view = PaperWebView(url: file, locationKey: "fixture-artifact", location: nil, fontSize: 17,
                                    jump: jump, reduceMotion: true, onLoading: { [weak self] loading in
                guard let self, !loading, !didLoad else { return }
                didLoad = true; loaded.fulfill()
            }, onLocation: { _, _ in }, onJumpApplied: { [weak self] _ in
                guard let self, !didJump else { return }
                didJump = true; jumped.fulfill()
            }, onSelection: { _ in }, onHeadings: { [weak self] in self?.headings = $0 }, onFigure: { _ in })
            let host = UIHostingController(rootView: view)
            controller = host
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        }

        var web: WKWebView? {
            func find(_ view: UIView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                return view.subviews.lazy.compactMap(find).first
            }
            return controller.flatMap { find($0.view) }
        }

        func close() {
            web?.stopLoading()
            window.isHidden = true
            window.rootViewController = nil
            controller = nil
            previousKeyWindow?.makeKey()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

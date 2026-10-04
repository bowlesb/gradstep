import SwiftUI
import WebKit
import XCTest
import ScienceReaderCore
@testable import ScienceReader

@MainActor
final class PaperWebViewTests: XCTestCase {
    func testGeneratedBundleLoadsAndEquationSelectionResolvesItsExactSource() async throws {
        let bundle = try ReaderBundleLoader.sample()
        let harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        XCTAssertFalse(harness.failed)
        let web = try XCTUnwrap(harness.web)
        let equation = try XCTUnwrap(bundle.index.equations.first)
        _ = try await web.callAsyncJavaScript("""
            const node=document.getElementById(id),range=document.createRange();
            range.selectNode(node);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
            """, arguments: ["id": equation.id], in: nil, contentWorld: .page)
        await fulfillment(of: [harness.selected], timeout: 5)
        let selection = try XCTUnwrap(harness.selection)
        XCTAssertEqual(selection.parts.filter { $0.kind == "equation" }.map(\.equationID), [equation.id])
        let quote = try selection.resolvedQuote(in: bundle)
        XCTAssertTrue(quote.contains(equation.latex))
        XCTAssertEqual(harness.headings.map(\.id), bundle.index.headings.map(\.id))
        let loaded = try await web.evaluateJavaScript("[...document.images].every(image=>image.complete&&image.naturalWidth>0)") as? Bool
        XCTAssertEqual(loaded, true)
        let scriptIsIsolated = try await web.evaluateJavaScript("typeof window.__scienceReaderJumpToHeading==='undefined'") as? Bool
        XCTAssertEqual(scriptIsIsolated, true, "Page content cannot replace the app-owned bridge")
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func testFigureOpensFromTheSameVerifiedSnapshotWithLocalImages() async throws {
        let bundle = try ReaderBundleLoader.sample()
        let figure = try XCTUnwrap(bundle.index.figures.first)
        let paper = try Harness(bundle: bundle)
        defer { paper.close() }
        await fulfillment(of: [paper.loaded], timeout: 15)
        XCTAssertFalse(paper.failed)
        _ = try await XCTUnwrap(paper.web).callAsyncJavaScript("document.getElementById(id).click();", arguments: ["id": figure.id], in: nil, contentWorld: .page)
        await fulfillment(of: [paper.openedFigure], timeout: 5)
        XCTAssertEqual(paper.figureID, figure.id)
        let detail = try Harness(bundle: bundle, figureID: figure.id)
        defer { detail.close() }
        await fulfillment(of: [detail.loaded], timeout: 15)
        XCTAssertFalse(detail.failed)
        let state = try await XCTUnwrap(detail.web).evaluateJavaScript("document.querySelectorAll('figure').length===1 && document.images.length>0 && [...document.images].every(image=>image.complete&&image.naturalWidth>0)") as? Bool
        XCTAssertEqual(state, true)
        XCTAssertEqual(detail.web?.url, bundle.entryURL)
    }

    func testSelectedTableRetainsCellAndRowSeparators() async throws {
        let bundle = try ReaderBundleLoader.sample()
        let harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        XCTAssertFalse(harness.failed)
        let web = try XCTUnwrap(harness.web)
        let expected = try await web.callAsyncJavaScript("""
            const table=document.querySelector('table'), range=document.createRange();
            range.selectNode(table); const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
            return [...table.querySelector('tr').children].slice(0,2).map(node=>node.textContent.trim()).join('\\t');
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        await fulfillment(of: [harness.selected], timeout: 5)
        let quote = try XCTUnwrap(harness.selection).resolvedQuote(in: bundle)
        XCTAssertTrue(quote.contains(try XCTUnwrap(expected)), "Selected table: \(quote.debugDescription)")
        XCTAssertTrue(quote.contains("\n"))
    }

    func testEquationTapOffersExactSourceAndCanBeCleared() async throws {
        let bundle = try ReaderBundleLoader.sample(), harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        let equation = try XCTUnwrap(bundle.index.equations.first(where: \.display))
        let web = try XCTUnwrap(harness.web)
        _ = try await web.callAsyncJavaScript("document.getElementById(id).click();", arguments: ["id": equation.id], in: nil, contentWorld: .page)
        await fulfillment(of: [harness.selected], timeout: 5)
        XCTAssertEqual(harness.selection?.parts, [.init(kind: "equation", blockID: equation.blockID, equationID: equation.id)])
        XCTAssertTrue(try XCTUnwrap(harness.selection).resolvedQuote(in: bundle).contains(equation.latex))
        let cleared = try await web.callAsyncJavaScript("window.__scienceReaderClearSelection(); return document.querySelectorAll('.reader-selected-equation').length===0;",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(cleared, true)
    }

    func testPointerPanDoesNotActivateEquationActions() async throws {
        let bundle = try ReaderBundleLoader.sample(), harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        harness.selected.isInverted = true
        let equation = try XCTUnwrap(bundle.index.equations.first(where: \.display))
        _ = try await XCTUnwrap(harness.web).callAsyncJavaScript("""
            const equation=document.getElementById(id);
            equation.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,pointerId:1,clientX:100,clientY:100}));
            equation.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,pointerId:1,clientX:150,clientY:100}));
            equation.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,pointerId:1,clientX:150,clientY:100}));
            equation.click();
            """, arguments: ["id": equation.id], in: nil, contentWorld: .page)
        await fulfillment(of: [harness.selected], timeout: 0.5)
        XCTAssertNil(harness.selection)
    }

    func testInvalidDOMAndUnlistedImagesFailThenFreshVerifiedBundleLoads() async throws {
        let bundle = try ReaderBundleLoader.sample()
        let html = String(decoding: try XCTUnwrap(bundle.data(for: bundle.manifest.entrypoint)), as: UTF8.self)
        let image = try XCTUnwrap(bundle.index.figures.first?.assetPaths.first)
        for broken in [html.replacingOccurrences(of: "data-reader-equation=", with: "data-invalid-equation="),
                       html.replacingOccurrences(of: image, with: "assets/missing.png")] {
            XCTAssertNotEqual(html, broken)
            let invalid = try replacingHTML(in: bundle, with: broken)
            let harness = try Harness(bundle: invalid)
            await fulfillment(of: [harness.loaded], timeout: 15)
            XCTAssertTrue(harness.failed, "Integrity alone does not establish a usable document")
            harness.close()
        }
        let reopened = try Harness(bundle: bundle)
        defer { reopened.close() }
        await fulfillment(of: [reopened.loaded], timeout: 15)
        XCTAssertFalse(reopened.failed)
        XCTAssertFalse(reopened.headings.isEmpty)
    }

    private func replacingHTML(in bundle: VerifiedReaderBundle, with html: String) throws -> VerifiedReaderBundle {
        var files = Dictionary(uniqueKeysWithValues: bundle.manifest.members.map { ($0.path, bundle.data(for: $0.path)!) })
        let bytes = Data(html.utf8); files[bundle.manifest.entrypoint] = bytes
        var manifest = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle.manifest)) as! [String: Any]
        var members = manifest["members"] as! [[String: Any]]
        let entry = try XCTUnwrap(members.firstIndex { $0["path"] as? String == bundle.manifest.entrypoint })
        members[entry]["bytes"] = bytes.count; members[entry]["sha256"] = VerifiedReaderBundle.digest(bytes)
        manifest["members"] = members
        let data = try JSONSerialization.data(withJSONObject: manifest)
        return try VerifiedReaderBundle.verify(manifest: data, expectedSHA256: VerifiedReaderBundle.digest(data), members: files)
    }

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
            arguments: ["key": harness.headings[2].id], in: nil, contentWorld: .defaultClient) as? Bool
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
        let selected = XCTestExpectation(description: "Verified selection received")
        let openedFigure = XCTestExpectation(description: "Figure ID received")
        var selection: ReaderSelection?
        var figureID: String?
        var failed = false
        var headings: [PaperHeading] = []
        private var didLoad = false
        private var didJump = false
        private let directory: URL
        private let window: UIWindow
        private let previousKeyWindow: UIWindow?
        private var controller: UIHostingController<PaperWebView>?

        init(document: String = "", bundle: VerifiedReaderBundle? = nil, figureID: String? = nil, jump: PaperJumpRequest? = nil) throws {
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
            let view = PaperWebView(url: bundle?.entryURL ?? file, bundle: bundle, figureID: figureID, locationKey: "fixture-artifact", location: nil, fontSize: 17,
                                    jump: jump, reduceMotion: true, onLoading: { [weak self] loading in
                guard let self, !loading, !didLoad else { return }
                didLoad = true; loaded.fulfill()
            }, onLocation: { _, _ in }, onJumpApplied: { [weak self] _ in
                guard let self, !didJump else { return }
                didJump = true; jumped.fulfill()
            }, onSelection: { [weak self] selection in
                guard let self, let selection, self.selection == nil else { return }
                self.selection = selection; selected.fulfill()
            }, onHeadings: { [weak self] in self?.headings = $0 }, onFigure: { [weak self] id in
                guard let self, self.figureID == nil else { return }
                self.figureID = id; openedFigure.fulfill()
            }, onFailure: { [weak self] in self?.failed = true })
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

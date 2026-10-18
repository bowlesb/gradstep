import XCTest
import SwiftUI
import WebKit
import ScienceReaderCore
@testable import ScienceReader

/// Contents › Equations rows (owner, build 62: "remove the equation text… Equation 1, Equation 2").
final class ContentsEquationLabelTests: XCTestCase {
    func testAnEquationIsNamedByItsNumberElseItsSection() {
        XCTAssertEqual(PaperContentsSheet.label(number: "(4)", section: "3 Method"), "Equation (4)")
        XCTAssertEqual(PaperContentsSheet.label(number: nil, section: "3.2 Method"), "Equation · 3.2 Method")
        XCTAssertEqual(PaperContentsSheet.label(number: nil, section: nil), "Equation")
    }

    func testABlocksSectionIsTheLastHeadingBeforeIt() throws {
        let json = """
        {"format":"reader-index-v1","title":"T","headings":[{"id":"h1","level":2,"title":"1 Intro"},{"id":"h2","level":2,"title":"2 Method"}],
         "blocks":[{"id":"p0","kind":"paragraph","text":"a"},{"id":"h1","kind":"heading","text":"1 Intro"},{"id":"e1","kind":"equation","text":"x"},
                   {"id":"h2","kind":"heading","text":"2 Method"},{"id":"e2","kind":"equation","text":"y"}],
         "equations":[],"figures":[]}
        """
        let index = try JSONDecoder().decode(ReaderBundleIndex.self, from: Data(json.utf8))
        let sections = PaperContentsSheet.sections(of: index)
        XCTAssertNil(sections["p0"], "before any heading")
        XCTAssertEqual(sections["e1"], "1 Intro")
        XCTAssertEqual(sections["e2"], "2 Method")
    }
}

@MainActor
final class EquationDisplayTransitionTests: XCTestCase {
    @Observable final class Source { var markup = "<span>first equation x = 1</span>" }
    struct Display: View {
        let source: Source
        let bundle: VerifiedReaderBundle
        @State private var height: CGFloat = 100
        var body: some View {
            EquationWebView(bundle: bundle, markup: source.markup, fontSize: 17, scale: 1.6, height: $height)
                .frame(height: height)
        }
    }
    func testSwitchingEquationsReplacesPixelsInTheExistingWebView() async throws {
        let source = Source(), bundle = try ReaderBundleLoader.sample()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Display(source: source, bundle: bundle))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func web(in view: UIView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { web(in: $0) }.first }
        var shown: WKWebView?
        for _ in 0..<100 {
            shown = window.rootViewController.flatMap { web(in: $0.view) }
            if let shown, (try? await shown.evaluateJavaScript("document.getElementById('eq')?.textContent")) as? String == "first equation x = 1" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let display = try XCTUnwrap(shown)
        let initial = try await display.evaluateJavaScript("document.getElementById('eq').textContent") as? String
        XCTAssertEqual(initial, "first equation x = 1")
        source.markup = "<span>fourth equation y = 4</span>"
        var final = ""
        for _ in 0..<100 {
            final = (try? await display.evaluateJavaScript("document.getElementById('eq')?.textContent")) as? String ?? ""
            if final == "fourth equation y = 4" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(final, "fourth equation y = 4", "Changing the heading must replace the formula, not only resize the old pixels")
        XCTAssertTrue(display === window.rootViewController.flatMap { web(in: $0.view) }, "Exercise SwiftUI's reused web view")
    }
}

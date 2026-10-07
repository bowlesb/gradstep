import SwiftUI
import WebKit
import XCTest
import ScienceReaderCore
@testable import ScienceReader

/// Passage-linked conversations in the reader bridge (reader-bridge.js, end; Views/PaperPassages.swift): the
/// selection's context, Go to passage and its text-search fallback, and marks that leave the page alone.
@MainActor
final class PaperPassageTests: XCTestCase {
    private let artifact = OfflineReaderFixture.artifact
    private let introduction = "b-e8b10bc14510-6", highLevel = "b-e8b10bc14510-8"
    private let passage = "bias our model toward the (potentially rare) high-quality coding ability"

    // MARK: Anchors and Go to passage

    func testSelectionContextFindsThePassageAgainWithBack() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let harness = try PassageHarness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        let web = try XCTUnwrap(harness.web)
        let selected = try await script(web, Self.selectText, ["id": introduction, "text": passage]) as? Bool
        XCTAssertEqual(selected, true)
        let received = try await eventually { harness.selection?.parts.isEmpty == false }
        XCTAssertTrue(received)
        let selection = try XCTUnwrap(harness.selection)
        let quote = try selection.resolvedQuote(in: bundle)
        XCTAssertEqual(quote, passage)
        let anchor = try XCTUnwrap(TextAnchor.passage(artifactID: artifact, selection: selection, quote: quote))
        XCTAssertEqual(anchor.elementID, introduction)
        XCTAssertEqual(anchor.prefix, "enerating code, we would like to", "\(anchor.prefix)")
        XCTAssertEqual(anchor.suffix, "present in its training data. Si", "\(anchor.suffix)")

        _ = try await script(web, "window.__scienceReaderClearSelection(); window.scrollTo({top: 0, behavior: 'instant'});")
        let result = try await go(web, anchor, same: true)
        XCTAssertEqual(result["found"] as? Bool, true); XCTAssertEqual(result["method"] as? String, "exact")
        let landed = try await eventually { try await self.highlighted(web) == self.passage }
        XCTAssertTrue(landed, "The passage is tinted once the page settles")
        let visible = try await script(web, """
            const rect = [...CSS.highlights.get('sr-passage')][0].getBoundingClientRect();
            return rect.top >= 0 && rect.bottom <= window.innerHeight;
            """) as? Bool
        XCTAssertEqual(visible, true)
        XCTAssertEqual(harness.citationStates, [true], "Back is offered, as after a citation")
        _ = try await script(web, "return window.__scienceReaderCitationBack();")
        let returned = try await eventually { (try await self.script(web, "return window.scrollY;") as? Double ?? -1) < 1 }
        XCTAssertTrue(returned, "Back returns to where reading left off")
        let cleared = try await eventually(timeout: 4) { try await self.highlighted(web) == nil }
        XCTAssertTrue(cleared, "The tint fades")
    }

    func testAnotherConversionFallsBackThroughTheTextSearchCascade() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let harness = try PassageHarness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        let web = try XCTUnwrap(harness.web)
        let other = UUID()
        func anchor(_ quote: String, _ prefix: String = "", _ suffix: String = "") -> TextAnchor {
            TextAnchor(artifactID: other, quote: quote, prefix: prefix, suffix: suffix, elementID: "b-from-another-conversion")
        }
        // Whitespace differs (another conversion wrapped the line).
        var result = try await go(web, anchor("bias our model\n toward   the (potentially rare)"), same: false)
        XCTAssertEqual(result["method"] as? String, "whitespace")
        // The passage's ending was reworded: its opening still finds it.
        let opening = "At a high level, existing methods instill the desired behaviors into a language model using curated sets of human"
        result = try await go(web, anchor(opening + " judgements, which a later conversion spelled differently."), same: false)
        XCTAssertEqual(result["method"] as? String, "opening")
        var text = try await eventuallyHighlighted(web)
        XCTAssertTrue(text?.hasPrefix("At a high level, existing methods") == true, text ?? "nil")
        // The quote itself no longer appears: the text around it does.
        result = try await go(web, anchor("wanted conduct", "existing methods instill the", "into a language model using"), same: false)
        XCTAssertEqual(result["method"] as? String, "context")
        text = try await eventuallyHighlighted(web)
        XCTAssertEqual(text, "desired behaviors")
        let jumps = harness.citationStates.count
        // Nothing matches: say so; the page doesn't move and Back isn't offered again.
        result = try await go(web, anchor("No passage in this paper reads like this sentence.", "zzzzzzzzzzzz", "yyyyyyyyyyyy"), same: false)
        XCTAssertEqual(result["found"] as? Bool, false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.citationStates.count, jumps)
        XCTAssertEqual(harness.citationStates.last, true)
    }

    func testAShortQuoteLandsInItsOwnBlockByElementOrContext() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let harness = try PassageHarness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        let web = try XCTUnwrap(harness.web)
        let blockOfPassage = """
            const range = [...CSS.highlights.get('sr-passage')][0];
            const block = range.startContainer.parentElement.closest('[data-reader-block]');
            const before = document.createRange(); before.setStart(block, 0); before.setEnd(range.startContainer, range.startOffset);
            return [block.id, before.toString().slice(-25)];
            """
        // "the" occurs hundreds of times; on its own artifact the block ID picks the paragraph.
        _ = try await go(web, TextAnchor(artifactID: artifact, quote: "the", elementID: highLevel), same: true)
        _ = try await eventuallyHighlighted(web)
        var place = try await script(web, blockOfPassage) as? [String]
        XCTAssertEqual(place?.first, highLevel)
        // On another conversion the text around it does.
        _ = try await go(web, TextAnchor(artifactID: UUID(), quote: "the", prefix: "existing methods instill", suffix: "desired behaviors into",
                                         elementID: introduction), same: false)
        _ = try await eventuallyHighlighted(web)
        place = try await script(web, blockOfPassage) as? [String]
        XCTAssertEqual(place?.first, highLevel)
        XCTAssertEqual(place?.last, "existing methods instill ")
    }

    func testFormulaPassageIsAnchoredFoundAndMarked() async throws {
        let bundle = try ReaderBundleLoader.sample()
        let harness = try PassageHarness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        let web = try XCTUnwrap(harness.web)
        let equation = try XCTUnwrap(bundle.index.equations.first(where: \.display))
        _ = try await web.callAsyncJavaScript("document.getElementById(id).click();", arguments: ["id": equation.id], in: nil, contentWorld: .page)
        let received = try await eventually { harness.selection?.parts.first?.kind == "equation" }
        XCTAssertTrue(received)
        let selection = try XCTUnwrap(harness.selection)
        let anchor = try XCTUnwrap(TextAnchor.passage(artifactID: artifact, selection: selection, quote: try selection.resolvedQuote(in: bundle)))
        XCTAssertTrue(anchor.quote.contains(equation.latex))
        XCTAssertTrue(anchor.prefix.hasSuffix("fits into the model."), anchor.prefix)
        XCTAssertTrue(anchor.suffix.contains("The normalization in"), anchor.suffix)
        _ = try await script(web, "window.__scienceReaderClearSelection();")
        let result = try await go(web, anchor, same: true)
        XCTAssertEqual(result["found"] as? Bool, true); XCTAssertEqual(result["method"] as? String, "exact")
        let marked = try await script(web, """
            const count = window.__scienceReaderSetMarks(list);
            return [count, document.getElementById(id).classList.contains('sr-chat-mark-display')];
            """, ["list": [PaperMark(conversationID: UUID(), anchor: anchor, sameArtifact: true).bridgeValue], "id": equation.id]) as? [Any]
        XCTAssertEqual(marked?.first as? Int, 1)
        XCTAssertEqual(marked?.last as? Bool, true, "Drawn math gets its own mark")
    }

    func testNativeGoToPassageWaitsForTheReaderAndReportsAMissingPassage() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let found = PaperPassageRequest(documentID: UUID(), conversationID: UUID(),
                                        anchor: TextAnchor(artifactID: artifact, quote: passage, elementID: introduction), sameArtifact: true)
        let harness = try PassageHarness(bundle: bundle, passage: found)
        await fulfillment(of: [harness.loaded], timeout: 20)
        let applied = try await eventually { harness.passages.count == 1 }
        XCTAssertTrue(applied)
        XCTAssertEqual(harness.passages.first?.0, found.id); XCTAssertEqual(harness.passages.first?.1, true)
        XCTAssertEqual(harness.citationStates, [true])
        harness.close()

        let missing = PaperPassageRequest(documentID: UUID(), conversationID: UUID(),
                                          anchor: TextAnchor(artifactID: UUID(), quote: "Not in this paper at all, anywhere."))
        let second = try PassageHarness(bundle: bundle, passage: missing)
        defer { second.close() }
        await fulfillment(of: [second.loaded], timeout: 20)
        let reported = try await eventually { second.passages.count == 1 }
        XCTAssertTrue(reported)
        XCTAssertEqual(second.passages.first?.1, false)
        XCTAssertEqual(second.citationStates, [], "No Back without a jump")
    }

    // MARK: Marks

    func testMarksLeaveTextLayoutSelectionCitationsAndPositionAlone() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let harness = try PassageHarness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        let web = try XCTUnwrap(harness.web)
        let marks = [
            PaperMark(conversationID: UUID(), anchor: TextAnchor(artifactID: artifact, quote: passage, elementID: introduction), sameArtifact: true),
            PaperMark(conversationID: UUID(), anchor: TextAnchor(artifactID: artifact, quote: "capabilities [11, 7, 42, 8]. However", elementID: introduction), sameArtifact: true),
            PaperMark(conversationID: UUID(), anchor: TextAnchor(artifactID: UUID(), quote: "not in this paper at all"), sameArtifact: false),
        ]
        _ = try await script(web, "document.getElementById(id).scrollIntoView({block: 'center', behavior: 'instant'});", ["id": introduction])
        let page = """
            const rect = document.getElementById(id).getBoundingClientRect();
            return JSON.stringify({elements: document.body.getElementsByTagName('*').length, height: document.documentElement.scrollHeight,
              top: rect.top, bottom: rect.bottom, text: document.body.innerText.length, location: window.__scienceReaderLocation()});
            """
        let before = try await script(web, page, ["id": introduction]) as? String
        let count = try await script(web, "return window.__scienceReaderSetMarks(list);", ["list": marks.map(\.bridgeValue)]) as? Int
        XCTAssertEqual(count, 2, "The anchor from elsewhere isn't marked")
        let ranges = try await script(web, "return [...CSS.highlights.get('sr-chat-mark')].map(range => range.toString());") as? [String]
        XCTAssertEqual(ranges, [passage, "capabilities [11, 7, 42, 8]. However"])
        let after = try await script(web, page, ["id": introduction]) as? String
        XCTAssertEqual(before, after, "Marks add no element and move nothing; the reading position is unchanged")

        // Selecting inside a mark still yields the paper's exact text.
        _ = try await script(web, Self.selectText, ["id": introduction, "text": "potentially rare"])
        let selected = try await eventually { (try? harness.selection.map { try $0.resolvedQuote(in: bundle) }) == "potentially rare" }
        XCTAssertTrue(selected)
        _ = try await script(web, "window.__scienceReaderClearSelection();")
        // A citation inside a mark still goes to its reference, and opens no chat.
        _ = try await web.callAsyncJavaScript("document.querySelector('#\(introduction) .sr-cite').click();", arguments: [:], in: nil, contentWorld: .page)
        let jumped = try await eventually { harness.citationStates == [true] }
        XCTAssertTrue(jumped)
        XCTAssertEqual(harness.marked, [])
    }

    func testTappingAMarkReportsItsConversationsAndOtherTapsDoNot() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let first = UUID(), second = UUID(), third = UUID()
        let marks = [
            PaperMark(conversationID: first, anchor: TextAnchor(artifactID: artifact, quote: passage, elementID: introduction), sameArtifact: true),
            PaperMark(conversationID: second, anchor: TextAnchor(artifactID: artifact, quote: "(potentially rare) high-quality", elementID: introduction), sameArtifact: true),
            PaperMark(conversationID: third, anchor: TextAnchor(artifactID: artifact, quote: "curated sets of human preferences", elementID: highLevel), sameArtifact: true),
        ]
        let harness = try PassageHarness(bundle: bundle, marks: marks)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        let web = try XCTUnwrap(harness.web)
        let applied = try await eventually { try await self.script(web, "return CSS.highlights.get('sr-chat-mark')?.size ?? 0;") as? Int == 3 }
        XCTAssertTrue(applied, "The native side hands the marks over once the reader is ready")
        func tap(_ text: String, in block: String) async throws {
            _ = try await web.callAsyncJavaScript("""
                const element = document.getElementById(block);
                const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
                let node; while ((node = walker.nextNode()) && !node.textContent.includes(text)) {}
                const range = document.createRange(), at = node.textContent.indexOf(text);
                range.setStart(node, at); range.setEnd(node, at + text.length);
                node.parentElement.scrollIntoView({block: 'center', behavior: 'instant'});
                const rect = range.getClientRects()[0], x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
                document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('click', {bubbles: true, clientX: x, clientY: y}));
                """, arguments: ["block": block, "text": text], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await tap("high-quality", in: introduction)
        XCTAssertEqual(harness.marked, [[first, second]], "Both conversations on that passage, for the chooser")
        try await tap("coding ability", in: introduction)
        XCTAssertEqual(harness.marked.last, [first])
        try await tap("sets of human", in: highLevel)
        XCTAssertEqual(harness.marked.last, [third])
        let reports = harness.marked.count
        try await tap("existing methods", in: highLevel)
        XCTAssertEqual(harness.marked.count, reports, "Unmarked text opens nothing")
        _ = try await script(web, Self.selectText, ["id": introduction, "text": "high-quality"])
        try await tap("high-quality", in: introduction)
        XCTAssertEqual(harness.marked.count, reports, "While text is selected a tap doesn't open a chat")
    }

    // MARK: Helpers

    private static let selectText = """
        const walker = document.createTreeWalker(document.getElementById(id), NodeFilter.SHOW_TEXT);
        let node; while ((node = walker.nextNode())) {
          const at = node.textContent.indexOf(text);
          if (at < 0) continue;
          const range = document.createRange(); range.setStart(node, at); range.setEnd(node, at + text.length);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
          return true;
        }
        return false;
        """

    private func script(_ web: WKWebView, _ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await web.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    private func go(_ web: WKWebView, _ anchor: TextAnchor, same: Bool) async throws -> [String: Any] {
        _ = try await script(web, "CSS.highlights.delete('sr-passage');")
        let value = PaperMark(conversationID: UUID(), anchor: anchor, sameArtifact: same).bridgeValue
        return try await script(web, "return window.__scienceReaderGoToPassage(anchor);", ["anchor": value]) as? [String: Any] ?? [:]
    }

    private func highlighted(_ web: WKWebView) async throws -> String? {
        try await script(web, "const value = CSS.highlights.get('sr-passage'); return value ? [...value][0].toString() : null;") as? String
    }

    private func eventuallyHighlighted(_ web: WKWebView) async throws -> String? {
        _ = try await eventually { try await self.highlighted(web) != nil }
        return try await highlighted(web)
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }
}

/// A paper reader in its own window with the passage hooks connected.
@MainActor
private final class PassageHarness {
    let loaded = XCTestExpectation(description: "Reader loaded")
    var selection: ReaderSelection?
    var marked: [[UUID]] = []
    var passages: [(UUID, Bool)] = []
    var citationStates: [Bool] = []
    private var didLoad = false
    private let window: UIWindow
    private let previousKeyWindow: UIWindow?
    private var controller: UIHostingController<PaperWebView>?

    init(bundle: VerifiedReaderBundle, marks: [PaperMark] = [], passage: PaperPassageRequest? = nil) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.keyWindow
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let view = PaperWebView(url: bundle.entryURL, bundle: bundle, locationKey: "passage-fixture", location: nil, fontSize: 17,
                                jump: nil, reduceMotion: true, onLoading: { [weak self] loading in
            guard let self, !loading, !didLoad else { return }
            didLoad = true; loaded.fulfill()
        }, onLocation: { _, _ in }, onJumpApplied: { _ in }, onSelection: { [weak self] in
            if let selection = $0, !selection.parts.isEmpty { self?.selection = selection }
        }, onHeadings: { _ in }, onFigure: { _ in }, onCitation: { [weak self] in self?.citationStates.append($0) },
           marks: marks, onMarks: { [weak self] in self?.marked.append($0) },
           passage: passage, onPassage: { [weak self] in self?.passages.append(($0, $1)) })
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
    }
}

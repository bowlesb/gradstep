import CryptoKit
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

    // MARK: - Citations, references and the publication line

    private func script(_ web: WKWebView, _ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await web.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    func testCitationsLinkToTheBibliographyWithoutChangingTheText() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let line = "2023 · NeurIPS · arXiv 2305.18290v3"
        let harness = try Harness(bundle: bundle, paperLine: line)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        XCTAssertFalse(harness.failed)
        let web = try XCTUnwrap(harness.web)
        let html = String(decoding: try XCTUnwrap(bundle.data(for: bundle.manifest.entrypoint)), as: UTF8.self)
        let stateValue = try await script(web, """
            const original = new DOMParser().parseFromString(html, 'text/html');
            const changed = [...document.querySelectorAll('[data-reader-block]')]
              .filter(element => original.getElementById(element.id)?.textContent !== element.textContent).map(element => element.id);
            const cites = [...document.querySelectorAll('.sr-cite')], line = document.querySelector('.sr-paper-line');
            return {changed, cites: cites.length,
              misplaced: cites.filter(cite => !cite.closest('[data-reader-block]') || cite.closest('[data-sr-reference],math,a,pre')).length,
              first: cites[0].textContent, firstTarget: cites[0].getAttribute('data-sr-cite'),
              range: cites.slice(0, 4).map(cite => cite.textContent).join('|'),
              reference: document.querySelector('[data-sr-reference="ref-5"]').textContent.trim().slice(0, 30),
              entries: document.querySelectorAll('[data-sr-reference]').length,
              line: line.textContent, afterAuthors: line.previousElementSibling.classList.contains('reader-authors'),
              next: line.nextElementSibling.textContent.trim(), inBlock: !!line.closest('[data-reader-block]'),
              userSelect: getComputedStyle(line).webkitUserSelect || getComputedStyle(line).userSelect};
            """, ["html": html]) as? [String: Any]
        let state = try XCTUnwrap(stateValue)
        XCTAssertEqual(state["changed"] as? [String], [], "Only inline wrappers are added: every block keeps its exact text")
        XCTAssertGreaterThanOrEqual(state["cites"] as? Int ?? 0, 85, "DPO's numbered citations link")
        XCTAssertEqual(state["misplaced"] as? Int, 0, "No links inside the bibliography, math, links or code")
        XCTAssertEqual(state["first"] as? String, "[11")
        XCTAssertEqual(state["firstTarget"] as? String, "ref-11")
        XCTAssertEqual(state["range"] as? String, "[11|7|42|8]", "Each number in [11, 7, 42, 8] is its own link")
        XCTAssertEqual(state["reference"] as? String, "[5] R. A. Bradley and M. E. Te")
        XCTAssertEqual(state["entries"] as? Int, 51)
        XCTAssertEqual(state["line"] as? String, line)
        XCTAssertEqual(state["afterAuthors"] as? Bool, true)
        XCTAssertEqual(state["next"] as? String, "Abstract")
        XCTAssertEqual(state["inBlock"] as? Bool, false)
        XCTAssertEqual(state["userSelect"] as? String, "none")
        XCTAssertEqual(harness.headings.map(\.id), bundle.index.headings.map(\.id), "Contents are unchanged")

        // A selection across the publication line resolves without it.
        _ = try await script(web, """
            const authors = document.querySelector('.reader-authors'), abstract = document.querySelector('.reader-abstract');
            const range = document.createRange(); range.setStart(authors, 0); range.setEnd(abstract.firstChild, 40);
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            """)
        await fulfillment(of: [harness.selected], timeout: 5)
        let quote = try XCTUnwrap(harness.selection).resolvedQuote(in: bundle)
        XCTAssertTrue(quote.hasPrefix("Rafael Rafailov"), quote)
        XCTAssertTrue(quote.contains("While large-scale unsupervised"), quote)
        XCTAssertFalse(quote.contains("NeurIPS"), "The publication line is not part of the paper's text")
    }

    func testSelectedPassageWithCitationsKeepsItsExactText() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        let block = try XCTUnwrap(bundle.index.blocks.first { $0.text.hasPrefix("Large unsupervised language models") })
        _ = try await script(try XCTUnwrap(harness.web), """
            const range = document.createRange(); range.selectNodeContents(document.getElementById(id));
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            """, ["id": block.id])
        await fulfillment(of: [harness.selected], timeout: 5)
        let quote = try XCTUnwrap(harness.selection).resolvedQuote(in: bundle)
        XCTAssertEqual(quote, block.text, "Selecting linked citations yields the bundle's own text")
        XCTAssertTrue(quote.contains("capabilities [11, 7, 42, 8]. However"))
    }

    func testCitationJumpsToItsReferenceAndBackReturnsToTheExactPlace() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        let web = try XCTUnwrap(harness.web)
        let originValue = try await script(web, """
            const cite = document.querySelector('.sr-cite[data-sr-cite="ref-28"]');
            window.scrollTo({top: window.scrollY + cite.getBoundingClientRect().top - 180, behavior: 'instant'});
            await new Promise(resolve => setTimeout(resolve, 400));
            return window.scrollY;
            """) as? Double
        let origin = try XCTUnwrap(originValue)
        XCTAssertGreaterThan(origin, 100)
        let reported = harness.locations.count
        let entryVisible = """
            const rect = document.querySelector('[data-sr-reference="ref-28"]').getBoundingClientRect();
            return rect.top >= 0 && rect.bottom <= window.innerHeight;
            """
        _ = try await web.callAsyncJavaScript("document.querySelector('.sr-cite[data-sr-cite=\"ref-28\"]').click();",
                                              arguments: [:], in: nil, contentWorld: .page)
        let landed = try await eventually { try await self.script(web, entryVisible) as? Bool == true }
        XCTAssertTrue(landed, "The reference is on screen")
        XCTAssertEqual(harness.citationStates, [true], "Back is offered")
        let highlighted = try await eventually { try await self.script(web, "return document.querySelectorAll('.sr-flash').length === 1;") as? Bool == true }
        XCTAssertTrue(highlighted, "The reference is briefly highlighted")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(harness.locations.dropFirst(reported).allSatisfy { abs($0.scrollY - origin) < 2 },
                      "While Back is offered the saved place stays where reading left off")

        let wentBack = try await script(web, "return window.__scienceReaderCitationBack();") as? Bool
        XCTAssertEqual(wentBack, true)
        let returned = try await eventually { abs((try await self.script(web, "return window.scrollY;") as? Double ?? -1) - origin) < 1 }
        XCTAssertTrue(returned, "Back returns to the exact reading position")
        XCTAssertEqual(harness.citationStates, [true, false])

        // Scrolling a screen away from the reference ends the offer.
        _ = try await web.callAsyncJavaScript("document.querySelector('.sr-cite[data-sr-cite=\"ref-28\"]').click();",
                                              arguments: [:], in: nil, contentWorld: .page)
        let landedAgain = try await eventually { try await self.script(web, entryVisible) as? Bool == true }
        XCTAssertTrue(landedAgain)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await script(web, "window.scrollBy({top: -2 * window.innerHeight, behavior: 'instant'});")
        let ended = try await eventually { harness.citationStates == [true, false, true, false] }
        XCTAssertTrue(ended, "\(harness.citationStates)")
        let backAgain = try await script(web, "return window.__scienceReaderCitationBack();") as? Bool
        XCTAssertEqual(backAgain, false, "Nothing to go back to once the offer ended")
    }

    func testReferenceTapOffersItsTextAndBestLink() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .mathpix)
        let harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 20)
        _ = try await XCTUnwrap(harness.web).callAsyncJavaScript("document.querySelector('[data-sr-reference=\"ref-5\"]').click();",
                                                                 arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [harness.referenced], timeout: 5)
        let reference = try XCTUnwrap(harness.reference)
        XCTAssertEqual(reference.title, "Reference 5")
        XCTAssertTrue(reference.text.hasPrefix("R. A. Bradley and M. E. Terry. Rank analysis"), reference.text)
        XCTAssertEqual(reference.link?.url.absoluteString, "https://doi.org/10.2307/2334029")
        XCTAssertEqual(reference.link?.title, "Open DOI")
        XCTAssertNil(harness.selection, "A reference tap is not a selection")
    }

    func testAuthorYearCitationsLinkOnlyOnAnUnambiguousMatch() async throws {
        let paragraph = "Transformers (Vaswani et al., 2017; Kingma &amp; Ba, 2015), as Vaswani et al. (2017) showed, "
            + "the interval [0, 1], RNNs (Graves, 2013), speech (Graves et al., 2013) and attention (Luong et al., 2015)."
        let document = """
        <h1 data-reader-block="b-1">A paper</h1>
        <p data-reader-block="b-2" id="b-2">\(paragraph)</p>
        <h2 data-reader-block="b-3">References</h2>
        <p data-reader-block="b-4" id="b-4">Ashish Vaswani, Noam Shazeer, and Niki Parmar. Attention is all you need. In NeurIPS, 2017.
        Diederik P. Kingma and Jimmy Ba. Adam: A method for stochastic optimization. In ICLR, 2015.
        Alex Graves. Generating sequences with recurrent neural networks. arXiv:1308.0850, 2013.
        Alex Graves, Abdel-rahman Mohamed, and Geoffrey Hinton. Speech recognition with deep recurrent networks. In ICASSP, 2013.
        Minh-Thang Luong, Quoc V. Le, Ilya Sutskever, Oriol Vinyals, and Lukasz Kaiser. Multi-task sequence to sequence learning. arXiv, 2015.
        Minh-Thang Luong, Hieu Pham, and Christopher D. Manning. Effective approaches to attention-based neural machine translation. In EMNLP, 2015.</p>
        """
        let harness = try Harness(document: document)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        let web = try XCTUnwrap(harness.web)
        let links = try await script(web, """
            return [...document.querySelectorAll('.sr-cite')].map(cite => cite.textContent + '>' + cite.getAttribute('data-sr-cite'));
            """) as? [String]
        XCTAssertEqual(links, ["Vaswani et al., 2017>ref-1", "Kingma & Ba, 2015>ref-2", "Vaswani et al. (2017)>ref-1",
                               "Graves, 2013>ref-3", "Graves et al., 2013>ref-4"],
                       "One cited name is the one-author entry and \"et al.\" the three-author one; two three-author "
                       + "Luong 2015 entries leave (Luong et al., 2015) unlinked; [0, 1] has no numbered bibliography")
        let text = try await script(web, "return document.getElementById('b-2').textContent;") as? String
        XCTAssertEqual(text, paragraph.replacingOccurrences(of: "&amp;", with: "&"))
        _ = try await web.callAsyncJavaScript("document.querySelector('.sr-cite[data-sr-cite=\"ref-2\"]').click();",
                                              arguments: [:], in: nil, contentWorld: .page)
        let jumped = try await eventually { harness.citationStates == [true] }
        XCTAssertTrue(jumped)
    }

    /// Owner feedback (2026-10-07): "Stadter et al, 2021" should link like a number does.
    func testAuthorYearFormsLinkEachNameAndYear() async throws {
        let forms = "Stiff solvers (Stadter et al, 2021) fail, as Stadter et al. (2021) showed. Embeddings "
            + "(van der Maaten &amp; Hinton, 2008), as van der Maaten and Hinton (2008) did, and (de Freitas et al., 2019). "
            + "NER (Tjong Kim Sang and De Meulder, 2003). ELMo (Peters et al., 2017, 2018a). HCI (Wu et al., 2022a,b). "
            + "BIG-bench (BIG-bench collaboration, 2021). SSMs (Kalman, 1960; Gu, Goel, and Ré 2022; Gu, Johnson, Goel, et al. 2021)."
        let split = "Split by markup (Vaswani <em>et al.</em>, 2017) and by a line (Vaswani et al.,<br>2017)."
        let document = """
        <h1 data-reader-block="b-1">A paper</h1>
        <p data-reader-block="b-2" id="b-2">\(forms)</p>
        <p data-reader-block="b-3" id="b-3">\(split)</p>
        <figure data-reader-block="b-4" id="b-4"><figcaption>Figure 1: The filter (Kalman, 1960).</figcaption></figure>
        <h2 data-reader-block="b-5">References</h2>
        <p data-reader-block="b-6" id="b-6">Albert Gu, Karan Goel, and Christopher Ré. 2022. Efficiently modeling long sequences with structured state spaces. In ICLR.
        Albert Gu, Isys Johnson, Karan Goel, Khaled Saab, Tri Dao, Atri Rudra, and Christopher Ré. 2021. Combining recurrent, convolutional, and continuous-time models. In NeurIPS.
        Rudolph Emil Kalman. 1960. A new approach to linear filtering and prediction problems.
        Matthew Peters, Waleed Ammar, Chandra Bhagavatula, and Russell Power. 2017. Semi-supervised sequence tagging. In ACL.
        Matthew Peters, Mark Neumann, Mohit Iyyer, Matt Gardner, and Luke Zettlemoyer. 2018a. Deep contextualized word representations. In NAACL.
        Matthew Peters, Mark Neumann, Luke Zettlemoyer, and Wen-tau Yih. 2018b. Dissecting contextual word embeddings. In EMNLP.
        P.Städter, Y. Schälte, L. Schmiester, J. Hasenauer, and P. L. Stapor. Benchmarking of numerical integration methods for ODE models. Scientific Reports, 2021.
        Erik F. Tjong Kim Sang and Fien De Meulder. 2003. Introduction to the CoNLL-2003 shared task. In CoNLL.
        de Freitas, N., Smith, A., and Jones, B. (2019). A title for particles. Journal.
        van der Maaten, L. and Hinton, G. (2008). Visualizing data using t-SNE. JMLR.
        Ashish Vaswani, Noam Shazeer, and Niki Parmar. 2017. Attention is all you need. In NeurIPS.
        Tongshuang Wu, Ellen Jiang, Aaron Donsbach, and Carrie J. Cai. 2022a. PromptChainer. In CHI.
        Tongshuang Wu, Michael Terry, and Carrie Jun Cai. 2022b. AI chains. In CHI.
        BIG-bench collaboration. 2021. Beyond the imitation game. arXiv.</p>
        """
        let harness = try Harness(document: document)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        let web = try XCTUnwrap(harness.web)
        let stateValue = try await script(web, """
            const links = id => [...document.getElementById(id).querySelectorAll('.sr-cite')]
              .map(cite => cite.textContent + '>' + cite.getAttribute('data-sr-cite'));
            const cite = document.querySelector('#b-2 .sr-cite'), style = getComputedStyle(cite);
            const probe = document.createElement('span');
            probe.style.color = 'var(--sr-link)'; document.body.append(probe);
            const linkColor = getComputedStyle(probe).color; probe.remove();
            return {forms: links('b-2'), split: links('b-3'), caption: links('b-4'),
              focus: [...document.querySelectorAll('#b-3 .sr-cite')].map(span => span.tabIndex),
              labels: [...document.querySelectorAll('#b-2 .sr-cite[aria-label]')].map(span => span.getAttribute('aria-label')),
              text: ['b-2', 'b-3', 'b-4'].map(id => document.getElementById(id).textContent),
              linkColor: style.color === linkColor, underline: style.textDecorationLine || style.webkitTextDecorationLine};
            """) as? [String: Any]
        let state = try XCTUnwrap(stateValue)
        XCTAssertEqual(state["forms"] as? [String], [
            "Stadter et al, 2021>ref-7", "Stadter et al. (2021)>ref-7",
            "van der Maaten & Hinton, 2008>ref-10", "van der Maaten and Hinton (2008)>ref-10", "de Freitas et al., 2019>ref-9",
            "Tjong Kim Sang and De Meulder, 2003>ref-8", "Peters et al., 2017>ref-4", "2018a>ref-5", "Wu et al., 2022a>ref-12", "b>ref-13",
            "BIG-bench collaboration, 2021>ref-14", "Kalman, 1960>ref-3", "Gu, Goel, and Ré 2022>ref-1", "Gu, Johnson, Goel, et al. 2021>ref-2",
        ], "Diacritics fold, particles and multi-word surnames match, each name–year pair links on its own")
        XCTAssertEqual(state["labels"] as? [String], ["Peters et al., 2018a", "Wu et al., 2022b"], "A lone year or letter is named in full")
        XCTAssertEqual(state["split"] as? [String], ["Vaswani >ref-11", "et al.>ref-11", ", 2017>ref-11", "Vaswani et al.,>ref-11", "2017>ref-11"],
                       "A citation split by markup or a line break links in pieces")
        XCTAssertEqual(state["focus"] as? [Int], [0, -1, -1, 0, -1], "Each split citation is one focus stop")
        XCTAssertEqual(state["caption"] as? [String], ["Kalman, 1960>ref-3"], "Figure captions link too")
        XCTAssertEqual(state["text"] as? [String], [forms.replacingOccurrences(of: "&amp;", with: "&"),
                                                    split.replacingOccurrences(of: "<em>", with: "").replacingOccurrences(of: "</em>", with: "")
                                                        .replacingOccurrences(of: "<br>", with: ""),
                                                    "Figure 1: The filter (Kalman, 1960)."], "Only inline wrappers are added")
        XCTAssertEqual(state["underline"] as? String, "underline", "Touch devices underline citations subtly")
        XCTAssertEqual(state["linkColor"] as? Bool, true, "Author–year links use the numbered links' color")

        _ = try await web.callAsyncJavaScript("document.querySelector('.sr-cite[data-sr-cite=\"ref-13\"]').click();",
                                              arguments: [:], in: nil, contentWorld: .page)
        let jumped = try await eventually { harness.citationStates == [true] }
        XCTAssertTrue(jumped, "Tapping \"b\" in (Wu et al., 2022a,b) jumps to Wu 2022b and offers Back")
        let wentBack = try await script(web, "return window.__scienceReaderCitationBack();") as? Bool
        XCTAssertEqual(wentBack, true)
    }

    /// Evidence screenshots, not part of the regular suite: a real author–year bundle's links and a jump,
    /// light and dark. Runs with TEST_RUNNER_SCIENCE_READER_CITATION_BUNDLE=<bundle directory> (and optionally
    /// TEST_RUNNER_SCIENCE_READER_CITATION_TEXT=<text of the citation to follow>).
    func testAuthorYearCitationScreenshots() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCIENCE_READER_CITATION_BUNDLE"], !path.isEmpty else {
            throw XCTSkip("Set SCIENCE_READER_CITATION_BUNDLE to an author–year reader bundle directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        let bundle = try ReaderBundleLoader.load(directory: directory, expectedSHA256: digest)
        let needle = environment["SCIENCE_READER_CITATION_TEXT"] ?? "et al"
        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = style == .dark ? "dark" : "light"
            let harness = try Harness(bundle: bundle, style: style)
            await fulfillment(of: [harness.loaded], timeout: 20)
            let web = try XCTUnwrap(harness.web)
            let found = try await script(web, """
                const cite = [...document.querySelectorAll('.sr-cite')].find(cite => cite.textContent.includes(needle));
                if (!cite) return false;
                window.scrollTo({top: window.scrollY + cite.getBoundingClientRect().top - window.innerHeight / 3, behavior: 'instant'});
                await new Promise(resolve => setTimeout(resolve, 600));
                return true;
                """, ["needle": needle]) as? Bool
            XCTAssertEqual(found, true, "A citation containing \(needle)")
            add(try await harness.screenshot("Author–year links (\(name))"))
            _ = try await web.callAsyncJavaScript("[...document.querySelectorAll('.sr-cite')].find(cite => cite.textContent.includes(needle)).click();",
                                                  arguments: ["needle": needle], in: nil, contentWorld: .page)
            let jumped = try await eventually { harness.citationStates == [true] }
            XCTAssertTrue(jumped)
            // The highlight is drawn over the entry once the scroll settles; it must be on screen.
            let target = """
                const flash = document.querySelector('.sr-flash');
                if (!flash) return false;
                const rect = flash.getBoundingClientRect();
                return rect.bottom > 0 && rect.top < window.innerHeight;
                """
            let landed = try await eventually { try await self.script(web, target) as? Bool == true }
            XCTAssertTrue(landed, "The cited entry is on screen and highlighted")
            add(try await harness.screenshot("After following it (\(name))"))
            harness.close()
        }
    }

    func testReferenceLinksPreferArXivThenDOIThenTheWeb() {
        func link(_ text: String, _ hrefs: [String] = []) -> String? { ReaderReference.link(in: text, hrefs: hrefs)?.url.absoluteString }
        XCTAssertEqual(link("H. Bong and A. Rinaldo. ICML, 2022. arXiv:2110.11487."), "https://arxiv.org/abs/2110.11487")
        XCTAssertEqual(link("D. Bahdanau et al. Neural machine translation. CoRR, abs/1409.0473, 2014."), "https://arxiv.org/abs/1409.0473")
        XCTAssertEqual(link("A. Vaswani et al. arXiv preprint arXiv:1706.03762v5, 2017. doi: 10.5555/3295222"), "https://arxiv.org/abs/1706.03762v5")
        XCTAssertEqual(ReaderReference.link(in: "arXiv:2110.11487", hrefs: [])?.title, "Open on arXiv")
        XCTAssertEqual(link("R. A. Bradley. Biometrika, 39(3/4):324-345, 1952. doi: https://doi.org/10.2307/2334029.",
                            ["https://doi.org/10.2307/2334029"]), "https://doi.org/10.2307/2334029")
        XCTAssertEqual(link("Y. Yue. J. Comput. Syst. Sci., 1997. doi: 10.1016/S0022-0000(05)80001-8."),
                       "https://doi.org/10.1016/S0022-0000(05)80001-8")
        XCTAssertEqual(ReaderReference.link(in: "doi: 10.1007/BF00992696", hrefs: [])?.title, "Open DOI")
        XCTAssertEqual(link("T. Brown et al. NeurIPS 2020. URL https://proceedings.neurips.cc/paper_",
                            ["https://proceedings.neurips.cc/paper/2020/file/1457c0d6-Paper.pdf"]),
                       "https://proceedings.neurips.cc/paper/2020/file/1457c0d6-Paper.pdf")
        XCTAssertEqual(link("B. Wang. GPT-J. https://github.com/kingoflolz/mesh-transformer-jax, May 2021."),
                       "https://github.com/kingoflolz/mesh-transformer-jax")
        XCTAssertEqual(ReaderReference.link(in: "https://example.org/a", hrefs: [])?.title, "Open link")
        XCTAssertNil(link("R. J. Williams. Simple statistical gradient-following algorithms. Mach. Learn., 8(3-4):229-256, 1992."))
        XCTAssertNil(link("Proceedings 2017.12345, 2017."), "A number that looks like an arXiv ID needs an arXiv mention")
        XCTAssertNil(link("See http://example.org/plain"), "Only https addresses open")
    }

    func testPublicationLineShowsOnlyKnownParts() {
        var paper = Paper(id: UUID(), title: "Attention Is All You Need", authors: "", year: 2017, abstract: "", keywords: [],
                          fileURL: nil, artifactID: nil, sourceID: "1706.03762", sourceRevision: 7)
        paper.venue = " NeurIPS "
        XCTAssertEqual(paper.publicationLine, "2017 · NeurIPS · arXiv 1706.03762v7")
        paper.venue = nil; paper.sourceRevision = nil
        XCTAssertEqual(paper.publicationLine, "2017 · arXiv 1706.03762")
        var web = Paper(id: UUID(), title: "Web", authors: "", year: 2015, abstract: "", keywords: [], fileURL: nil, artifactID: nil,
                        sourceID: "openalex:W2100837269", sourceRevision: 1)
        web.venue = "Nature"
        XCTAssertEqual(web.publicationLine, "2015 · Nature · Open access")
        let unknown = Paper(id: UUID(), title: "Note", authors: "", year: nil, abstract: "", keywords: [], fileURL: nil, artifactID: nil)
        XCTAssertNil(unknown.publicationLine)
        let sample = Paper(id: UUID(), title: "Sample", authors: "", year: 2026, abstract: "", keywords: [], fileURL: nil, artifactID: nil, isSample: true)
        XCTAssertNil(sample.publicationLine, "The bundled sample prints its own year")
    }

    @MainActor
    private final class Harness {
        let loaded = XCTestExpectation(description: "Offline reader loaded")
        let jumped = XCTestExpectation(description: "Contents jump applied")
        let selected = XCTestExpectation(description: "Verified selection received")
        let openedFigure = XCTestExpectation(description: "Figure ID received")
        let referenced = XCTestExpectation(description: "Reference actions requested")
        var selection: ReaderSelection?
        var figureID: String?
        var reference: ReaderReference?
        var citationStates: [Bool] = []
        var locations: [PaperReadingLocation] = []
        var failed = false
        var headings: [PaperHeading] = []
        private var didLoad = false
        private var didJump = false
        private let directory: URL
        private let window: UIWindow
        private let previousKeyWindow: UIWindow?
        private var controller: UIHostingController<PaperWebView>?

        init(document: String = "", bundle: VerifiedReaderBundle? = nil, figureID: String? = nil, jump: PaperJumpRequest? = nil,
             paperLine: String? = nil, style: UIUserInterfaceStyle = .unspecified) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("paper.html")
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <style>body{margin:0;font-family:system-ui}h1,h2{margin:0;padding:16px 0}</style>
            </head><body>\(document)</body></html>
            """
            try Data(html.utf8).write(to: file)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKeyWindow = scene.keyWindow
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = style
            let view = PaperWebView(url: bundle?.entryURL ?? file, bundle: bundle, figureID: figureID, locationKey: "fixture-artifact", location: nil, fontSize: 17,
                                    jump: jump, reduceMotion: true, onLoading: { [weak self] loading in
                guard let self, !loading, !didLoad else { return }
                didLoad = true; loaded.fulfill()
            }, onLocation: { [weak self] _, location in self?.locations.append(location) }, onJumpApplied: { [weak self] _ in
                guard let self, !didJump else { return }
                didJump = true; jumped.fulfill()
            }, onSelection: { [weak self] selection in
                guard let self, let selection, self.selection == nil else { return }
                self.selection = selection; selected.fulfill()
            }, onHeadings: { [weak self] in self?.headings = $0 }, onFigure: { [weak self] id in
                guard let self, self.figureID == nil else { return }
                self.figureID = id; openedFigure.fulfill()
            }, onFailure: { [weak self] in self?.failed = true }, paperLine: paperLine, onCitation: { [weak self] in
                self?.citationStates.append($0)
            }, onReference: { [weak self] reference in
                guard let self, self.reference == nil else { return }
                self.reference = reference; referenced.fulfill()
            })
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

        /// The page as shown, kept with the test results.
        func screenshot(_ name: String) async throws -> XCTAttachment {
            let image = try await XCTUnwrap(web).takeSnapshot(configuration: nil)
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways
            return attachment
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

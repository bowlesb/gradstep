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
              touchOnly: matchMedia('(hover:none)').matches,
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
        let touchOnly = try XCTUnwrap(state["touchOnly"] as? Bool)
        XCTAssertEqual(state["underline"] as? String, touchOnly ? "underline" : "none",
                       "Citations gain a subtle underline when hover is unavailable, including touch devices")
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

    /// Owner feedback (build 14): "[Gelfond and Lifschitz 1991]" and "[Lobo et al. 1992; Eiter et al. 1997b]" did not link.
    /// ACM style brackets the citation and prints no comma before the year; small capitals may come out of OCR in capitals.
    func testBracketedAuthorYearCitationsWithoutACommaLink() async throws {
        let paragraph = "Answer sets [Gelfond and Lifschitz 1991] are expressive [Lobo et al. 1992; Eiter et al. 1997b; Gelfond and Lifschitz 1991]. "
            + "Stable models [Przymusinski 1991a; 1991b], constraints [Buccafurri, Leone, and Rullo 2000], datalog [Eiter, Gottlob, and Mannila 1997b]. "
            + "As Gelfond and Lifschitz [1991] showed; [Cadoli et al. 1997] fits two entries. "
            + "Small capitals [GELFOND AND LIFSCHITZ 1988; EITER ET AL. 1997a] and [Eiter And Leone 1998]."
        let document = """
        <h1 data-reader-block="b-1">The DLV System</h1>
        <p data-reader-block="b-2" id="b-2">\(paragraph)</p>
        <h2 data-reader-block="b-3">REFERENCES</h2>
        <p data-reader-block="b-4" id="b-4">Buccafurri, F., Leone, N., and Rullo, P. 2000. Enhancing disjunctive datalog by constraints. IEEE TKDE 12, 5, 845-860.
        Cadoli, M., Eiter, T., and Gottlob, G. 1997. Default logic as a query language. IEEE TKDE 9, 3, 448-463.
        Cadoli, M., Giovanardi, A., and Schaerf, M. 1997. Experimental analysis of the computational cost of evaluating QBF.
        Eiter, T., Gottlob, G., and Leone, N. 1997a. Abduction from logic programs: Semantics and complexity.
        Eiter, T., Gottlob, G., and Mannila, H. 1997b. Disjunctive datalog. ACM TODS 22, 3, 364-418.
        Eiter, T., And Leone, N. 1998. A paper whose "and" is in small capitals.
        Gelfond, M. and Lifschitz, V. 1988. The stable model semantics for logic programming.
        Gelfond, M. and Lifschitz, V. 1991. Classical negation in logic programs and disjunctive databases.
        Lobo, J., Minker, J., and Rajasekar, A. 1992. Foundations of Disjunctive Logic Programming. The MIT Press.
        Przymusinski, T. C. 1991a. Stable semantics for disjunctive programs. New Generation Computing 9, 401-424.
        Przymusinski, T. C. 1991b. Semantics of normal and disjunctive logic programs.</p>
        """
        let harness = try Harness(document: document)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        let web = try XCTUnwrap(harness.web)
        let stateValue = try await script(web, """
            return {links: [...document.querySelectorAll('#b-2 .sr-cite')].map(cite => cite.textContent + '>' + cite.getAttribute('data-sr-cite')),
              text: document.getElementById('b-2').textContent};
            """) as? [String: Any]
        let state = try XCTUnwrap(stateValue)
        XCTAssertEqual(state["links"] as? [String], [
            "Gelfond and Lifschitz 1991>ref-8", "Lobo et al. 1992>ref-9", "Eiter et al. 1997b>ref-5", "Gelfond and Lifschitz 1991>ref-8",
            "Przymusinski 1991a>ref-10", "1991b>ref-11", "Buccafurri, Leone, and Rullo 2000>ref-1", "Eiter, Gottlob, and Mannila 1997b>ref-5",
            "Gelfond and Lifschitz [1991]>ref-8", "GELFOND AND LIFSCHITZ 1988>ref-7", "EITER ET AL. 1997a>ref-4", "Eiter And Leone 1998>ref-6",
        ], "Each bracketed name–year pair links; [Cadoli et al. 1997] fits two three-author entries and stays plain")
        XCTAssertEqual(state["text"] as? String, paragraph)
        _ = try await web.callAsyncJavaScript("document.querySelector('#b-2 .sr-cite').click();", arguments: [:], in: nil, contentWorld: .page)
        let jumped = try await eventually { harness.citationStates == [true] }
        XCTAssertTrue(jumped, "Tapping [Gelfond and Lifschitz 1991] jumps to the entry and offers Back")
    }

    // MARK: - The paper's own table of contents

    /// Owner feedback (build 14): the paper's own contents rendered as one run-on paragraph
    /// ("Contents 1 Introduction ..... 1 2 Core Language ..... 3 2.1 Syntax ..... 3 …").
    func testPaperContentsBecomeAListThatJumpsToItsSections() async throws {
        let contents = "Contents\n1 Introduction ..... 1\n2 Core Language ..... 3\n2.1 Syntax ..... 3\n2.1.1 Terms ..... 4\n"
            + "2.2 Problems in NP and <span class=\"reader-equation reader-inline\" data-reader-equation=\"e-1\" id=\"e-1\" data-latex=\"\\Delta _ { 2 }\">Δ2</span> ..... 5\n"
            + "3 Knowledge Representation ..... 7\nA Appendix: Encodings ..... 55"
        // Each of these must stay exactly as it is.
        let untouched = [
            "b-3": "We waited ..... 3 hours. Then the second run ..... 5 ended and the third ..... 9 did too, quickly.",
            "b-4": "Results\n1 apple 2\n2 pears 3\n3 plums 4\n4 figs 5",
            "b-8": "Contents 1 apple 2 banana 3 cherry 4 kiwi",
            "b-9": "Contents 1 Introduction 1 3 Background 3 2 Setup 4 5 Results 7",
            "b-17": "Steps ..... 1\nmore prose that is not an entry at all\nand ..... 2",
        ]
        let document = """
        <h1 data-reader-block="b-1" id="b-1">A paper</h1>
        <p data-reader-block="b-2" id="b-2">\(contents)</p>
        <p data-reader-block="b-3" id="b-3">\(untouched["b-3"]!)</p>
        <p data-reader-block="b-4" id="b-4">\(untouched["b-4"]!)</p>
        <h2 data-reader-block="b-5" id="b-5">Table of Contents</h2>
        <p data-reader-block="b-6" id="b-6">1 Introduction 1\n2 Background 3\n2.1 Setup 4\n3 Results 7\nReferences 9</p>
        <p data-reader-block="b-7" id="b-7">Contents 1 Introduction 1 2 Background 3 2.1 Setup 4 3 Results 7</p>
        <p data-reader-block="b-8" id="b-8">\(untouched["b-8"]!)</p>
        <p data-reader-block="b-9" id="b-9">\(untouched["b-9"]!)</p>
        <p data-reader-block="b-16" id="b-16">List of Figures\n1 Overview of the system ..... 2\n2 Syntax ..... 5\n3 Ablations ..... 8</p>
        <p data-reader-block="b-17" id="b-17">\(untouched["b-17"]!)</p>
        <div style="height:900px"></div>
        <h2 data-reader-block="b-10" id="b-10">1. INTRODUCTION</h2><p data-reader-block="b-11" id="b-11">Body.</p>
        <div style="height:900px"></div>
        <h2 data-reader-block="b-12" id="b-12">2 Core Language</h2>
        <h3 data-reader-block="b-13" id="b-13">2.1 Syntax</h3>
        <p data-reader-block="b-14" id="b-14">Terms come first.\n2.1.1 Terms. A term is a constant or a variable.</p>
        <div style="height:900px"></div>
        <h2 data-reader-block="b-15" id="b-15">A. APPENDIX: ENCODINGS</h2>
        <h2 data-reader-block="b-18" id="b-18">References</h2>
        <div style="height:1200px"></div>
        """
        let harness = try Harness(document: document)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        let web = try XCTUnwrap(harness.web)
        let stateValue = try await script(web, """
            const original = new DOMParser().parseFromString('<body>' + html + '</body>', 'text/html');
            const changed = [...document.querySelectorAll('[data-reader-block]')]
              .filter(element => original.getElementById(element.id)?.textContent !== element.textContent).map(element => element.id);
            const rows = id => [...document.querySelectorAll(`#${id} > .sr-toc-entry`)];
            const describe = row => [row.querySelector('.sr-toc-label').textContent.replace(/\\s+/g, ' ').trim(),
              row.querySelector('.sr-toc-page').textContent, row.getAttribute('data-sr-depth')].join('|');
            const linked = id => rows(id).filter(row => row.classList.contains('sr-toc-link'))
              .map(row => row.querySelector('.sr-toc-label').textContent.replace(/\\s+/g, ' ').trim());
            const probe = document.createElement('span'); document.body.append(probe);
            probe.style.color = 'var(--sr-muted)'; const muted = getComputedStyle(probe).color;
            probe.style.color = 'var(--sr-link)'; const link = getComputedStyle(probe).color; probe.remove();
            const [top, sub] = [rows('b-2')[0], rows('b-2')[2]], page = top.querySelector('.sr-toc-page');
            return {changed, lists: [...document.querySelectorAll('.sr-toc')].map(element => element.id),
              b2: rows('b-2').map(describe), b6: rows('b-6').map(describe), b7: rows('b-7').map(describe), b16: rows('b-16').map(describe),
              linked2: linked('b-2'), linked6: linked('b-6'), linked16: linked('b-16'),
              caption: document.querySelector('#b-2 > .sr-toc-caption')?.textContent,
              equation: document.getElementById('e-1').closest('[data-reader-block]').id,
              label: rows('b-2')[2].getAttribute('aria-label'), role: rows('b-2')[2].getAttribute('role'),
              unlinkedRole: rows('b-2')[5].getAttribute('role'), focus: rows('b-2')[2].tabIndex,
              display: getComputedStyle(top).display, align: getComputedStyle(page).textAlign, pageMuted: getComputedStyle(page).color === muted,
              leader: getComputedStyle(top.querySelector('.sr-toc-leader')).fontSize,
              hidden: top.querySelector('.sr-toc-leader').getAttribute('aria-hidden'),
              indent: parseFloat(getComputedStyle(sub).paddingLeft) - parseFloat(getComputedStyle(top).paddingLeft),
              linkColor: getComputedStyle(top.querySelector('.sr-toc-label')).color === link,
              plainColor: getComputedStyle(rows('b-2')[5].querySelector('.sr-toc-label')).color !== link,
              oneLine: rows('b-2').every((row, i, all) => !i || row.getBoundingClientRect().top >= all[i - 1].getBoundingClientRect().bottom - 1),
              pagesRight: rows('b-2').every(row => Math.abs(row.querySelector('.sr-toc-page').getBoundingClientRect().right - row.getBoundingClientRect().right) < 1)};
            """, ["html": document]) as? [String: Any]
        let state = try XCTUnwrap(stateValue)
        XCTAssertEqual(state["changed"] as? [String], [], "Only wrappers are added: every block keeps its exact text")
        XCTAssertEqual(state["lists"] as? [String], ["b-2", "b-6", "b-7", "b-16"],
                       "Leader entries, plain lines after a Contents heading and a run-together Contents become lists; prose, a "
                       + "numbered list without a caption, out-of-order numbers and mixed prose do not")
        XCTAssertEqual(state["b2"] as? [String], ["1 Introduction|1|0", "2 Core Language|3|0", "2.1 Syntax|3|1", "2.1.1 Terms|4|2",
                                                  "2.2 Problems in NP and Δ2|5|1", "3 Knowledge Representation|7|0", "A Appendix: Encodings|55|0"])
        XCTAssertEqual(state["b6"] as? [String], ["1 Introduction|1|0", "2 Background|3|0", "2.1 Setup|4|1", "3 Results|7|0", "References|9|0"])
        XCTAssertEqual(state["b7"] as? [String], ["1 Introduction|1|0", "2 Background|3|0", "2.1 Setup|4|1", "3 Results|7|0"])
        XCTAssertEqual(state["b16"] as? [String], ["1 Overview of the system|2|0", "2 Syntax|5|0", "3 Ablations|8|0"])
        XCTAssertEqual(state["linked2"] as? [String], ["1 Introduction", "2 Core Language", "2.1 Syntax", "2.1.1 Terms", "A Appendix: Encodings"],
                       "Headings match by number and title (\"1. INTRODUCTION\"), a run-in head by its line; no heading, no link")
        XCTAssertEqual(state["linked6"] as? [String], ["1 Introduction", "References"])
        XCTAssertEqual(state["linked16"] as? [String], [], "A list of figures never links to a heading")
        XCTAssertEqual(state["caption"] as? String, "Contents")
        XCTAssertEqual(state["equation"] as? String, "b-2", "An equation in a title stays in its block")
        XCTAssertEqual(state["label"] as? String, "2.1 Syntax, page 3")
        XCTAssertEqual(state["role"] as? String, "link")
        XCTAssertNil(state["unlinkedRole"] as? String)
        XCTAssertEqual(state["focus"] as? Int, 0)
        XCTAssertEqual(state["display"] as? String, "flex")
        XCTAssertEqual(state["align"] as? String, "right")
        XCTAssertEqual(state["pageMuted"] as? Bool, true)
        XCTAssertEqual(state["leader"] as? String, "0px", "The dots become a faint dotted rule")
        XCTAssertEqual(state["hidden"] as? String, "true")
        XCTAssertGreaterThan(state["indent"] as? Double ?? 0, 10, "2.1 is indented under 2")
        XCTAssertEqual(state["linkColor"] as? Bool, true)
        XCTAssertEqual(state["plainColor"] as? Bool, true)
        XCTAssertEqual(state["oneLine"] as? Bool, true, "One entry per line")
        XCTAssertEqual(state["pagesRight"] as? Bool, true, "Page numbers are right-aligned")

        // A tap on "2.1 Syntax" goes to its heading and offers Back to the contents.
        let originValue = try await script(web, "return window.scrollY;") as? Double
        let origin = try XCTUnwrap(originValue)
        _ = try await web.callAsyncJavaScript("document.querySelectorAll('#b-2 > .sr-toc-entry')[2].click();", arguments: [:], in: nil, contentWorld: .page)
        let atHeading = try await eventually { abs((try await self.script(web, "return document.getElementById('b-13').getBoundingClientRect().top;") as? Double ?? -99)) < 2 }
        XCTAssertTrue(atHeading, "The heading is at the top, as a Contents jump puts it")
        XCTAssertEqual(harness.citationStates, [true], "Back is offered")
        let wentBack = try await script(web, "return window.__scienceReaderCitationBack();") as? Bool
        XCTAssertEqual(wentBack, true)
        let returned = try await eventually { abs((try await self.script(web, "return window.scrollY;") as? Double ?? -1) - origin) < 1 }
        XCTAssertTrue(returned, "Back returns to the contents")
        XCTAssertEqual(harness.citationStates, [true, false])

        // A run-in head ("2.1.1 Terms. A term is…") is reached by keyboard too.
        _ = try await web.callAsyncJavaScript("""
            const row = document.querySelectorAll('#b-2 > .sr-toc-entry')[3]; row.focus();
            row.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
            """, arguments: [:], in: nil, contentWorld: .page)
        let atRunIn = try await eventually {
            let top = try await self.script(web, """
                const block = document.getElementById('b-14'), text = block.firstChild, at = text.data.indexOf('2.1.1');
                const range = document.createRange(); range.setStart(text, at); range.setEnd(text, at + 5);
                return range.getBoundingClientRect().top;
                """) as? Double ?? -99
            return abs(top - 22) < 2
        }
        XCTAssertTrue(atRunIn, "The run-in head's line is at the top")
        XCTAssertEqual(harness.citationStates, [true, false, true])
    }

    /// A selection across a formatted contents block still quotes the bundle's own text, dots and all,
    /// and the app's Contents list is unchanged.
    func testPaperContentsInABundleKeepSelectionsAndContents() async throws {
        let sample = try ReaderBundleLoader.sample()
        let html = String(decoding: try XCTUnwrap(sample.data(for: sample.manifest.entrypoint)), as: UTF8.self)
        let paragraph = "A useful first pass identifies the problem, the proposed method, and the evidence. Separate the authors’ claims "
            + "from the measurements that support them. Mark passages that depend on assumptions you want to revisit."
        let contents = "Contents\n1 Start with the question ..... 1\n2 Read the equations in context ..... 2\n3 Check the evaluation ..... 4\n"
            + "4 Follow the references ..... 5\nReferences ..... 6"
        XCTAssertTrue(html.contains(paragraph))
        let bundle = try replacingHTML(in: sample, with: html.replacingOccurrences(of: paragraph, with: contents))
        let harness = try Harness(bundle: bundle)
        defer { harness.close() }
        await fulfillment(of: [harness.loaded], timeout: 15)
        XCTAssertFalse(harness.failed)
        let web = try XCTUnwrap(harness.web)
        let linked = try await script(web, """
            return [...document.querySelectorAll('#b-51ef8c310855-5 > .sr-toc-link')].map(row => row.getAttribute('aria-label'));
            """) as? [String]
        XCTAssertEqual(linked, ["1 Start with the question, page 1", "2 Read the equations in context, page 2", "3 Check the evaluation, page 4",
                                "4 Follow the references, page 5", "References, page 6"])
        XCTAssertEqual(harness.headings.map(\.id), bundle.index.headings.map(\.id), "The app's Contents list is unchanged")
        _ = try await script(web, """
            const range = document.createRange(); range.selectNodeContents(document.getElementById('b-51ef8c310855-5'));
            const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            """)
        await fulfillment(of: [harness.selected], timeout: 5)
        let quote = try XCTUnwrap(harness.selection).resolvedQuote(in: bundle)
        XCTAssertEqual(quote, contents, "The quote is the block's own text, leaders included")
        XCTAssertEqual(Set(try XCTUnwrap(harness.selection).parts.map(\.blockID)), ["b-51ef8c310855-5"])
    }

    /// Evidence screenshots, not part of the regular suite: a real paper's contents list (light and dark), after following
    /// one entry, and a bracketed author–year citation. Runs with TEST_RUNNER_SCIENCE_READER_CONTENTS_BUNDLE=<bundle directory>
    /// (and optionally TEST_RUNNER_SCIENCE_READER_CITATION_TEXT=<text of a citation to show>, TEST_RUNNER_SCIENCE_READER_SHOTS=<directory>).
    func testPaperContentsScreenshots() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCIENCE_READER_CONTENTS_BUNDLE"], !path.isEmpty else {
            throw XCTSkip("Set SCIENCE_READER_CONTENTS_BUNDLE to a reader bundle directory whose paper prints its own contents")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let digest = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        let bundle = try ReaderBundleLoader.load(directory: directory, expectedSHA256: digest)
        let needle = environment["SCIENCE_READER_CITATION_TEXT"] ?? "Gelfond and Lifschitz 1991"
        let output = environment["SCIENCE_READER_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        func keep(_ harness: Harness, _ name: String) async throws {
            let attachment = try await harness.screenshot(name)
            add(attachment)
            if let output, let image = try await harness.web?.takeSnapshot(configuration: nil), let png = image.pngData() {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-") + ".png"))
            }
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = style == .dark ? "dark" : "light"
            let harness = try Harness(bundle: bundle, style: style)
            await fulfillment(of: [harness.loaded], timeout: 20)
            let web = try XCTUnwrap(harness.web)
            let found = try await script(web, """
                const list = document.querySelector('.sr-toc');
                if (!list) return false;
                window.scrollTo({top: window.scrollY + list.getBoundingClientRect().top - 60, behavior: 'instant'});
                await new Promise(resolve => setTimeout(resolve, 500));
                return true;
                """) as? Bool
            XCTAssertEqual(found, true, "The paper's contents are shown as a list")
            try await keep(harness, "contents \(name)")
            _ = try await web.callAsyncJavaScript("[...document.querySelectorAll('.sr-toc-link')][4].click();", arguments: [:], in: nil, contentWorld: .page)
            let jumped = try await eventually { harness.citationStates == [true] }
            XCTAssertTrue(jumped)
            try await Task.sleep(for: .milliseconds(900))
            try await keep(harness, "contents followed \(name)")
            _ = try await script(web, "return window.__scienceReaderCitationBack();")
            let cited = try await script(web, """
                const cite = [...document.querySelectorAll('.sr-cite')].find(cite => cite.textContent.includes(needle));
                if (!cite) return false;
                window.scrollTo({top: window.scrollY + cite.getBoundingClientRect().top - window.innerHeight / 3, behavior: 'instant'});
                await new Promise(resolve => setTimeout(resolve, 600));
                return true;
                """, ["needle": needle]) as? Bool
            XCTAssertEqual(cited, true, "A bracketed citation containing \(needle) links")
            try await keep(harness, "bracketed citation \(name)")
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

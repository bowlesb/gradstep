import CoreGraphics
import XCTest
@testable import ScienceReaderCore

/// Show in PDF (FIGURE_VIEW.md "Show in PDF"): the block rows read from provenance, the passage found again on the PDF's
/// text layer (folding, a word broken at a line's end, a ligature, a repeated phrase told apart by the block's page, the
/// fallbacks), a part of a page drawn, and the pop-up's opening zoom.
final class ShowInPDFTests: XCTestCase {
    // MARK: Glyphs

    /// One line of glyphs from `x`, 5 points a letter, a space leaving a gap and no glyph (as many PDFs draw text).
    private func line(_ text: String, x: Double = 72, top: Double, size: Double = 10) -> [DevicePDFGlyph] {
        var out: [DevicePDFGlyph] = [], at = x
        for character in text {
            if character == " " { at += 2.5; continue }
            out.append(DevicePDFGlyph(text: String(character), x0: at, top: top, x1: at + 5, bottom: top + size, size: size, font: "Times-Roman", upright: true))
            at += 5
        }
        return out
    }

    private func region(_ page: Int, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> DevicePDFTextRegion {
        DevicePDFTextRegion(page: page, x0: x0, y0: y0, x1: x1, y1: y1)!
    }

    // MARK: Folding

    func testFoldingIgnoresSpacingCaseAccentsPunctuationAndCompatibilityForms() {
        let folded = { (s: String) in String(String.UnicodeScalarView(PDFPassageLocator.fold(s).compactMap(Unicode.Scalar.init))) }
        XCTAssertEqual(folded("The  re-\nsults, Fig. 3!"), "theresultsfig3")
        XCTAssertEqual(folded("ﬁne ﬂow ﬀ"), "fineflowff", "ligatures are their letters")
        XCTAssertEqual(folded("Café naïve Ångström"), "cafenaiveangstrom")
        XCTAssertEqual(folded("𝑥 + 𝐲 = Ｚ"), "xyz", "mathematical and wide letters are plain letters")
        XCTAssertEqual(folded("α-β Σ"), "αβσ", "Greek is kept, lower case")
        XCTAssertEqual(folded(" \n\t—–·"), "")
    }

    // MARK: Locating

    func testAWordBrokenAtALineEndIsFoundOnBothLines() throws {
        let glyphs = line("Our experiments show that the re-", top: 100) + line("sults hold across every setting.", top: 112)
        let found = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: "the results hold"), pageCount: 1) { _ in glyphs })
        XCTAssertEqual(found.match, .words)
        XCTAssertEqual(found.page, 0)
        XCTAssertEqual(found.lines.count, 2, "the two lines the words are on")
        XCTAssertEqual(found.lines[0].minY, 99, accuracy: 0.01); XCTAssertEqual(found.lines[1].minY, 111, accuracy: 0.01)
        // The first line's highlight starts at "the" (22 letters and 4 spaces in), not at the line's start.
        XCTAssertEqual(found.lines[0].minX, 191.0, accuracy: 0.01)
        // The second ends after "hold".
        XCTAssertLessThan(found.lines[1].maxX, 72 + 5 * 15)
    }

    func testALigatureGlyphMatchesItsLetters() throws {
        var glyphs = line("We ", top: 100)
        // "ﬁnd" drawn with one ligature glyph for "fi".
        glyphs.append(DevicePDFGlyph(text: "ﬁ", x0: 90, top: 100, x1: 98, bottom: 110, size: 10, font: "Times-Roman", upright: true))
        glyphs += line("nd the optimum.", x: 98, top: 100)
        let found = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: "We find the optimum"), pageCount: 1) { _ in glyphs })
        XCTAssertEqual(found.match, .words)
        XCTAssertEqual(found.lines.count, 1)
        XCTAssertEqual(found.lines[0].minX, 71, accuracy: 0.01)
        // And the other way round: the reading has the ligature, the PDF the letters.
        let plain = line("We find the optimum.", top: 100)
        XCTAssertEqual(PDFPassageLocator.locate(PDFPassageQuery(text: "We ﬁnd the"), pageCount: 1) { _ in plain }?.match, .words)
    }

    func testARepeatedPhraseIsFoundOnTheBlocksPage() throws {
        let phrase = "the policy is optimal under the reward model"
        let pages = [line("Theorem 1 states " + phrase + ".", top: 200), line("As shown, " + phrase + " again.", top: 400)]
        var asked: [Int] = []
        func locate(_ query: PDFPassageQuery) -> PDFPassageLocation? {
            PDFPassageLocator.locate(query, pageCount: 2) { asked.append($0); return pages[$0] }
        }
        // The block's place says page 2: its occurrence there, and only that page is read.
        let second = try XCTUnwrap(locate(PDFPassageQuery(text: phrase, regions: [region(1, 60, 390, 560, 420)])))
        XCTAssertEqual(second.page, 1); XCTAssertEqual(second.match, .words); XCTAssertEqual(asked, [1])
        XCTAssertEqual(second.bounds.midY, 405, accuracy: 1)
        // Page 1's place: page 1's.
        XCTAssertEqual(locate(PDFPassageQuery(text: phrase, regions: [region(0, 60, 190, 560, 220)]))?.page, 0)
        // No place recorded (an older reading): every page is read; the text around the selection tells them apart, then
        // the page the block's position suggests.
        asked = []
        XCTAssertEqual(locate(PDFPassageQuery(text: phrase, before: "As shown,", after: "again"))?.page, 1)
        XCTAssertEqual(asked, [0, 1])
        XCTAssertEqual(locate(PDFPassageQuery(text: phrase, before: "Theorem 1 states"))?.page, 0)
        XCTAssertEqual(locate(PDFPassageQuery(text: phrase, expectedPage: 1.2))?.page, 1)
        XCTAssertEqual(locate(PDFPassageQuery(text: phrase, expectedPage: 0))?.page, 0)
    }

    func testTwoOccurrencesOnOnePageAreToldApartByTheBlocksBox() throws {
        let phrase = "gradient of the loss"
        let glyphs = line("We take the " + phrase + " first.", top: 100) + line("Then the " + phrase + " again.", top: 300)
        let lower = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: phrase, regions: [region(0, 60, 290, 500, 320)]), pageCount: 1) { _ in glyphs })
        XCTAssertEqual(lower.bounds.midY, 305, accuracy: 1)
        let upper = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: phrase, regions: [region(0, 60, 90, 500, 120)]), pageCount: 1) { _ in glyphs })
        XCTAssertEqual(upper.bounds.midY, 105, accuracy: 1)
    }

    func testAPassageTheReadingChangedIsFoundApproximately() throws {
        // The PDF has a formula the reading shows as LaTeX, and the model misread one letter ("rnodel").
        let glyphs = line("We fit the reward model r(x, y) to the preference data and then", top: 100)
            + line("optimise the policy against the learned reward model directly.", top: 112)
        let reading = "We fit the reward rnodel \\(r_\\phi(x,y)\\) to the preference data and then optimise the policy"
        let found = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: reading, regions: [region(0, 60, 90, 500, 130)]), pageCount: 1) { _ in glyphs })
        XCTAssertEqual(found.match, .approximate)
        XCTAssertEqual(found.lines.count, 2)
        XCTAssertEqual(found.lines[0].minX, 71, accuracy: 0.01, "from the passage's first word")
    }

    func testWithoutTheWordsTheBlocksRecordedPlaceIsShown() throws {
        // A scanned page: no text layer. The block's boxes on its first page.
        let regions = [region(2, 72, 500, 300, 700), region(2, 310, 80, 540, 200), region(3, 72, 80, 300, 120)]
        let scanned = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: "Some words", regions: regions), pageCount: 4) { _ in [] })
        XCTAssertEqual(scanned.match, .region)
        XCTAssertEqual(scanned.page, 2)
        XCTAssertEqual(scanned.lines, [regions[0].rect, regions[1].rect])
        // Words the PDF doesn't have: the same.
        let other = line("Entirely different text on this page.", top: 100)
        XCTAssertEqual(PDFPassageLocator.locate(PDFPassageQuery(text: "Some words", regions: regions), pageCount: 4) { _ in other }?.match, .region)
        // An equation (no text, its recorded box).
        let equation = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: "", regions: [region(0, 200, 300, 400, 330)]), pageCount: 1) { _ in other })
        XCTAssertEqual(equation.match, .region); XCTAssertEqual(equation.bounds, CGRect(x: 200, y: 300, width: 200, height: 30))
        // No record and no words: nothing to show. A record on a page the PDF doesn't have is no record.
        XCTAssertNil(PDFPassageLocator.locate(PDFPassageQuery(text: "Some words"), pageCount: 4) { _ in other })
        XCTAssertNil(PDFPassageLocator.locate(PDFPassageQuery(text: "Some words", regions: [region(9, 0, 0, 10, 10)]), pageCount: 4) { _ in [] })
    }

    func testTheRealTextLayerOfAHandWrittenPDF() throws {
        // Two pages of Helvetica, the same sentence on both, the second's broken over two lines with a hyphen.
        func content(_ lines: [(Double, String)]) -> String {
            lines.map { "BT /F1 10 Tf 72 \($0.0) Td (\($0.1)) Tj ET" }.joined(separator: "\n")
        }
        let first = content([(700, "Introduction. We study preference learning."), (686, "Direct optimisation is simple.")])
        let second = content([(500, "Results. We study prefer-"), (486, "ence learning in practice.")])
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        func object(_ body: String) { offsets.append(pdf.utf8.count); pdf += "\(offsets.count) 0 obj\n\(body)\nendobj\n" }
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> >>")
        object("<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>")
        object("<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>")
        object("<< /Length \(first.utf8.count) >>\nstream\n\(first)\nendstream")
        object("<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream")
        object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        pdf += "trailer << /Root 1 0 R /Size \(offsets.count + 1) >>\n%%EOF\n"
        let document = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: Data(pdf.utf8) as CFData))))
        let glyphs = (1...2).map { DevicePDFTextLayer.glyphs(page: document.page(at: $0)!) }
        XCTAssertFalse(glyphs[1].isEmpty, "the text layer reads the page")
        // The reading's block on page 2 (its region from the converter): the broken word, both lines.
        let found = try XCTUnwrap(PDFPassageLocator.locate(PDFPassageQuery(text: "We study preference learning", regions: [region(1, 60, 280, 400, 320)]),
                                                           pageCount: 2) { glyphs[$0] })
        XCTAssertEqual(found.page, 1); XCTAssertEqual(found.match, .words); XCTAssertEqual(found.lines.count, 2)
        // Points from the top: the first line's baseline is 292 below the top, its glyphs above it.
        XCTAssertEqual(found.lines[0].maxY, 792 - 500 + 3, accuracy: 3)
        // Without a record, the first page's sentence (the same words, unbroken).
        XCTAssertEqual(PDFPassageLocator.locate(PDFPassageQuery(text: "We study preference learning"), pageCount: 2) { glyphs[$0] }?.page, 0)
    }

    // MARK: Provenance

    func testBlockAndEquationRowsAreReadFromProvenance() throws {
        let manifest = try JSONDecoder().decode(ReaderBundleManifest.self, from: Data("""
        {"format":"reader-bundle-v1","renderer":{"id":"gradstep-device-pdf-mathml-v1","build_sha256":"\(String(repeating: "a", count: 64))"},
         "source":{"kind":"device-pdf","sha256":"\(String(repeating: "b", count: 64))","provenance_path":"provenance.json"},
         "entrypoint":"index.html","index_path":"reader.json","members":[]}
        """.utf8))
        func provenance(_ extra: String) -> Data {
            Data("""
            {"format":"device-pdf-reader-provenance-v1","source":{"kind":"device-pdf","pdf_sha256":"\(String(repeating: "b", count: 64))"},
             "adapter":{"id":"gradstep-device-pdf-mathml-v1","build_sha256":"\(String(repeating: "a", count: 64))"}\(extra)}
            """.utf8)
        }
        let source = try DevicePDFReaderProvenance.validate(provenance("""
        ,"blocks":[["b-1-2",0,72,100.5,540,180],["b-1-3",0,72,600,300,740],["b-1-3",1,310,72,540,120],
                   ["b-1-4",1.5,72,72,90,90],["b-1-5",1,90,72,72,90],["b-1-6",1,72,72,90],[8,1,72,72,90,90]],
         "equations":[["e-1-1",0.98,1,2,200,300,400,330,-1],["e-1-2",0.5,0,2,200,300],["e-1-3",0.9,1,"2",200,300,400,330,-1]]
        """), manifest: manifest)
        XCTAssertEqual(Set(source.blocks.keys), ["b-1-2", "b-1-3"], "a fractional page, an empty box, a short row and a numeric id are left out")
        XCTAssertEqual(source.blocks["b-1-3"]?.map(\.page), [0, 1], "a paragraph across two pages, in reading order")
        XCTAssertEqual(source.blocks["b-1-2"]?.first?.rect, CGRect(x: 72, y: 100.5, width: 468, height: 79.5))
        XCTAssertEqual(Set(source.equations.keys), ["e-1-1"])
        XCTAssertEqual(source.equations["e-1-1"]?.page, 2)
        XCTAssertEqual(source.equations["e-1-1"]?.rect, CGRect(x: 200, y: 300, width: 200, height: 30))
        // A reading made before port revision 11: no block rows, still valid.
        let older = try DevicePDFReaderProvenance.validate(provenance(""), manifest: manifest)
        XCTAssertEqual(older.blocks, [:]); XCTAssertEqual(older.equations, [:])
    }

    // MARK: Drawing and zoom

    func testAPartOfThePageIsDrawnWhereTheWholePageHasIt() throws {
        // A black square at 100…120 × 100…120 from the bottom left of a 200 × 300 page: 180…200 from the top.
        let content = "0 0 0 rg 100 100 20 20 re f"
        let pdf = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n"
            + "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Contents 4 0 R >> endobj\n"
            + "4 0 obj << /Length \(content.utf8.count) >> stream\n\(content)\nendstream endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"
        let page = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: Data(pdf.utf8) as CFData)))?.page(at: 1))
        XCTAssertEqual(DevicePDFRaster.shownSize(page), CGSize(width: 200, height: 300))
        // The region 90…130 across, 170…210 down, at 2 px a point: 80 × 80 px with the square at 20…60 both ways.
        let image = try XCTUnwrap(DevicePDFRaster.render(page, pixelsPerPoint: 2, region: CGRect(x: 90, y: 170, width: 40, height: 40)))
        XCTAssertEqual([image.width, image.height], [80, 80])
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func dark(_ x: Int, _ y: Int) -> Bool { pixels[(y * w + x) * 4] < 64 }  // rows top to bottom
        XCTAssertTrue(dark(25, 25) && dark(55, 55) && dark(25, 55) && dark(55, 25), "the square")
        XCTAssertFalse(dark(15, 15) || dark(65, 65) || dark(15, 65) || dark(65, 15), "white around it")
        // A region off the page draws nothing.
        XCTAssertNil(DevicePDFRaster.render(page, pixelsPerPoint: 2, region: CGRect(x: 300, y: 0, width: 10, height: 10)))
    }

    func testThePopUpOpensFramedOnThePassage() {
        let page = CGSize(width: 612, height: 792), view = CGSize(width: 390, height: 700)
        let whole = 390.0 / 612
        // A paragraph 468 points wide: fitted with its margin across, more than the whole page's zoom.
        let paragraph = CGRect(x: 72, y: 300, width: 468, height: 60)
        let opened = PDFPassageZoom.opening(focus: paragraph, page: page, view: view, maximumZoom: 6)
        XCTAssertEqual(opened.zoom, 390 / (468 + 2 * 24), accuracy: 1e-9)
        XCTAssertGreaterThan(opened.zoom, whole)
        XCTAssertEqual(opened.centre, CGPoint(x: 306, y: 330))
        // One word: widened to 45 % of the page, never past the maximum.
        let word = CGRect(x: 300, y: 300, width: 20, height: 10)
        XCTAssertEqual(PDFPassageZoom.opening(focus: word, page: page, view: view, maximumZoom: 6).zoom, 390 / (612 * 0.45), accuracy: 1e-9)
        XCTAssertEqual(PDFPassageZoom.opening(focus: word, page: page, view: view, maximumZoom: 1).zoom, 1)
        // Nothing to frame: the whole page.
        XCTAssertEqual(PDFPassageZoom.opening(focus: .null, page: page, view: view, maximumZoom: 6).zoom, whole, accuracy: 1e-9)
        // The offset centres the passage across; down, the page (598 points tall at this zoom) is shorter than the view,
        // so it is centred.
        let z = opened.zoom
        let offset = PDFPassageZoom.offset(centre: opened.centre, zoom: z, page: page, view: view)
        XCTAssertEqual(offset.x, 306 * z - 195, accuracy: 1e-6); XCTAssertEqual(offset.y, 396 * z - 350, accuracy: 1e-6)
        // Closer in, it stays on the page at its corner.
        XCTAssertEqual(PDFPassageZoom.offset(centre: .zero, zoom: 3, page: page, view: view), .zero)
        let far = PDFPassageZoom.offset(centre: CGPoint(x: 612, y: 792), zoom: 3, page: page, view: view)
        XCTAssertEqual(far.x, 612 * 3 - 390, accuracy: 1e-6); XCTAssertEqual(far.y, 792 * 3 - 700, accuracy: 1e-6)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import ScienceReaderCore

/// The device route's text layer against its reference, pdfplumber 0.11.8 over pdfminer.six with gradstep's
/// `pdftext.read_pages` baseline correction. `Fixtures/device-pdf-text-layer.pdf` is hand-written (scratchpad
/// `textlayer/make_fixture.py`): a non-embedded Type 1 font with Differences (`uni`, ligature names), core-14
/// Helvetica, a ToUnicode CMap (bfchar with UTF-16 pairs, bfrange incremental and array forms), a Type 0 Identity-H
/// font with W widths, a Type 3 font with its own FontMatrix, an embedded Type 1 program whose cleartext carries the
/// encoding, a font whose metrics put glyphs below the baseline, TJ kerning, Tz, Tc, Tw, Ts, TL, T*, ' and ",
/// a rotated CTM, a text matrix with scale, form XObjects (nested, one inheriting its parent's resources) and an
/// undefined font. The expected glyphs are the reference's output for that file, to the last bit.
struct DevicePDFTextLayerTests {
    typealias Row = (String, Double, Double, Double, Double, Double, String, Bool)
    static let expected: [Row] = [
        ("α", 72.0, 63.0, 78.0, 75.0, 12.0, "ABCDEF+TestSerif", true),
        ("β", 78.0, 63.0, 85.2, 75.0, 12.0, "ABCDEF+TestSerif", true),
        ("fi", 85.2, 63.0, 93.60000000000001, 75.0, 12.0, "ABCDEF+TestSerif", true),
        ("α", 72.0, 83.0, 78.0, 95.0, 12.0, "ABCDEF+TestSerif", true),
        ("β", 81.0, 83.0, 88.2, 95.0, 12.0, "ABCDEF+TestSerif", true),
        ("fi", 86.76, 83.0, 95.16000000000001, 95.0, 12.0, "ABCDEF+TestSerif", true),
        ("H", 72.0, 104.07000000000005, 77.776, 114.07000000000005, 10.0, "Helvetica", true),
        ("i", 78.976, 104.07000000000005, 80.752, 114.07000000000005, 10.0, "Helvetica", true),
        (" ", 81.952, 104.07000000000005, 84.176, 114.07000000000005, 10.0, "Helvetica", true),
        ("t", 85.376, 104.07000000000005, 87.60000000000001, 114.07000000000005, 10.0, "Helvetica", true),
        ("h", 88.8, 104.07000000000005, 93.24799999999999, 114.07000000000005, 10.0, "Helvetica", true),
        ("e", 94.44800000000001, 104.07000000000005, 98.89600000000002, 114.07000000000005, 10.0, "Helvetica", true),
        ("r", 100.096, 104.07000000000005, 102.76, 114.07000000000005, 10.0, "Helvetica", true),
        ("e", 103.96000000000001, 104.07000000000005, 108.40800000000002, 114.07000000000005, 10.0, "Helvetica", true),
        (" ", 108.408, 104.5, 111.188, 114.5, 10.0, "Helvetica", true),
        ("u", 111.188, 104.5, 116.748, 114.5, 10.0, "Helvetica", true),
        ("p", 116.748, 104.5, 122.308, 114.5, 10.0, "Helvetica", true),
        ("a", 72.0, 124.07000000000005, 77.56, 134.07000000000005, 10.0, "Helvetica", true),
        (" ", 77.56, 124.07000000000005, 80.34, 134.07000000000005, 10.0, "Helvetica", true),
        ("b", 84.34, 124.07000000000005, 89.9, 134.07000000000005, 10.0, "Helvetica", true),
        (" ", 89.9, 124.07000000000005, 92.68, 134.07000000000005, 10.0, "Helvetica", true),
        ("c", 96.68, 124.07000000000005, 101.68, 134.07000000000005, 10.0, "Helvetica", true),
        ("n", 72.0, 138.07000000000005, 77.56, 148.07000000000005, 10.0, "Helvetica", true),
        ("e", 77.56, 138.07000000000005, 83.12, 148.07000000000005, 10.0, "Helvetica", true),
        ("x", 83.12, 138.07000000000005, 88.12, 148.07000000000005, 10.0, "Helvetica", true),
        ("t", 88.12, 138.07000000000005, 90.9, 148.07000000000005, 10.0, "Helvetica", true),
        ("l", 72.0, 152.07000000000005, 74.22, 162.07000000000005, 10.0, "Helvetica", true),
        ("i", 74.22, 152.07000000000005, 76.44, 162.07000000000005, 10.0, "Helvetica", true),
        ("n", 76.44, 152.07000000000005, 82.0, 162.07000000000005, 10.0, "Helvetica", true),
        ("e", 82.0, 152.07000000000005, 87.56, 162.07000000000005, 10.0, "Helvetica", true),
        ("q", 87.56, 152.07000000000005, 93.12, 162.07000000000005, 10.0, "Helvetica", true),
        ("u", 94.12, 152.07000000000005, 99.68, 162.07000000000005, 10.0, "Helvetica", true),
        ("o", 100.68, 152.07000000000005, 106.24000000000001, 162.07000000000005, 10.0, "Helvetica", true),
        ("t", 107.24000000000001, 152.07000000000005, 110.02000000000001, 162.07000000000005, 10.0, "Helvetica", true),
        ("e", 111.02000000000001, 152.07000000000005, 116.58000000000001, 162.07000000000005, 10.0, "Helvetica", true),
        ("d", 117.58000000000001, 152.07000000000005, 123.14000000000001, 162.07000000000005, 10.0, "Helvetica", true),
        ("α", 72.0, 163.20000000000005, 76.4, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        ("fi", 77.4, 163.20000000000005, 81.855, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        ("𝒜", 82.855, 163.20000000000005, 87.36500000000001, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        ("x", 88.36500000000001, 163.20000000000005, 94.525, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        ("y", 95.525, 163.20000000000005, 101.74000000000001, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        ("z", 102.74000000000001, 163.20000000000005, 109.01, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        ("A", 110.01, 163.20000000000005, 116.33500000000001, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        ("B", 117.33500000000001, 163.20000000000005, 123.715, 174.20000000000005, 11.0, "XYZABC+TestMath", true),
        (" ", 72.0, 184.98000000000002, 74.25, 193.98000000000002, 9.0, "QRSTUV+TestCID", true),
        ("A", 75.25, 184.98000000000002, 81.748, 193.98000000000002, 9.0, "QRSTUV+TestCID", true),
        ("a", 82.748, 184.98000000000002, 87.248, 193.98000000000002, 9.0, "QRSTUV+TestCID", true),
        ("b", 88.24799999999999, 184.98000000000002, 92.74799999999999, 193.98000000000002, 9.0, "QRSTUV+TestCID", true),
        ("c", 93.74799999999999, 184.98000000000002, 98.24799999999999, 193.98000000000002, 9.0, "QRSTUV+TestCID", true),
        ("(cid:153)", 99.24799999999999, 184.98000000000002, 108.24799999999999, 193.98000000000002, 9.0, "QRSTUV+TestCID", true),
        ("a", 72.0, 206.0, 88.0, 226.0, 20.0, "unknown", true),
        ("b", 89.0, 206.0, 101.0, 226.0, 20.0, "unknown", true),
        ("Γ", 72.0, 234.5, 78.1, 244.5, 10.0, "GHIJKL+TestEmbedded", true),
        ("∂", 79.1, 234.5, 85.3, 244.5, 10.0, "GHIJKL+TestEmbedded", true),
        ("𝐀", 86.3, 234.5, 92.6, 244.5, 10.0, "GHIJKL+TestEmbedded", true),
        ("(cid:68)", 93.6, 234.5, 100.0, 244.5, 10.0, "GHIJKL+TestEmbedded", true),
        ("(cid:69)", 101.0, 234.5, 107.5, 244.5, 10.0, "GHIJKL+TestEmbedded", true),
        ("O", 72.0, 254.5, 79.0, 264.5, 10.0, "MNOPQR+OffBase", true),
        ("f", 80.0, 254.5, 87.0, 264.5, 10.0, "MNOPQR+OffBase", true),
        ("f", 88.0, 254.5, 95.0, 264.5, 10.0, "MNOPQR+OffBase", true),
        ("R", 293.656, 486.224, 301.656, 492.0, 5.7760000000000105, "Helvetica", false),
        ("o", 293.656, 480.776, 301.656, 485.224, 4.447999999999979, "Helvetica", false),
        ("t", 293.656, 477.552, 301.656, 479.776, 2.2239999999999895, "Helvetica", false),
        ("a", 293.656, 472.10400000000004, 301.656, 476.552, 4.447999999999979, "Helvetica", false),
        ("t", 293.656, 468.88, 301.656, 471.104, 2.2239999999999895, "Helvetica", false),
        ("e", 293.656, 463.432, 301.656, 467.88, 4.447999999999979, "Helvetica", false),
        ("d", 293.656, 457.98400000000004, 301.656, 462.432, 4.447999999999979, "Helvetica", false),
        ("I", 132.0, 324.07, 134.78, 334.07, 10.0, "Helvetica", true),
        ("n", 134.78, 324.07, 140.34, 334.07, 10.0, "Helvetica", true),
        (" ", 140.34, 324.07, 143.12, 334.07, 10.0, "Helvetica", true),
        ("f", 143.12, 324.07, 145.9, 334.07, 10.0, "Helvetica", true),
        ("o", 145.9, 324.07, 151.46, 334.07, 10.0, "Helvetica", true),
        ("r", 151.46, 324.07, 154.79000000000002, 334.07, 10.0, "Helvetica", true),
        ("m", 154.79, 324.07, 163.12, 334.07, 10.0, "Helvetica", true),
        ("n", 96.0, 583.4315, 98.502, 587.9315, 4.5, "Helvetica", true),
        ("e", 98.502, 583.4315, 101.00399999999999, 587.9315, 4.5, "Helvetica", true),
        ("s", 101.004, 583.4315, 103.254, 587.9315, 4.5, "Helvetica", true),
        ("t", 103.254, 583.4315, 104.50500000000001, 587.9315, 4.5, "Helvetica", true),
        ("e", 104.505, 583.4315, 107.00699999999999, 587.9315, 4.5, "Helvetica", true),
        ("d", 107.007, 583.4315, 109.509, 587.9315, 4.5, "Helvetica", true),
        ("S", 72.0, 376.14, 85.34, 396.14, 20.0, "Helvetica", true),
        ("c", 87.34, 376.14, 97.34, 396.14, 20.0, "Helvetica", true),
        ("a", 99.34, 376.14, 110.46000000000001, 396.14, 20.0, "Helvetica", true),
        ("l", 112.46000000000001, 376.14, 116.9, 396.14, 20.0, "Helvetica", true),
        ("e", 118.9, 376.14, 130.02, 396.14, 20.0, "Helvetica", true),
        ("d", 132.01999999999998, 376.14, 143.14, 396.14, 20.0, "Helvetica", true),
        ("m", 72.0, 402.0, 72.0, 412.0, 10.0, "unknown", true),
        ("i", 73.0, 402.0, 73.0, 412.0, 10.0, "unknown", true),
        ("s", 74.0, 402.0, 74.0, 412.0, 10.0, "unknown", true),
        ("s", 75.0, 402.0, 75.0, 412.0, 10.0, "unknown", true),
        ("i", 76.0, 402.0, 76.0, 412.0, 10.0, "unknown", true),
        ("n", 77.0, 402.0, 77.0, 412.0, 10.0, "unknown", true),
        ("g", 78.0, 402.0, 78.0, 412.0, 10.0, "unknown", true),
        (" ", 79.0, 402.0, 79.0, 412.0, 10.0, "unknown", true),
        ("f", 82.0, 402.0, 82.0, 412.0, 10.0, "unknown", true),
        ("o", 83.0, 402.0, 83.0, 412.0, 10.0, "unknown", true),
        ("n", 84.0, 402.0, 84.0, 412.0, 10.0, "unknown", true),
        ("t", 85.0, 402.0, 85.0, 412.0, 10.0, "unknown", true)
    ]

    private func page() throws -> CGPDFPage {
        let url = try #require(Bundle.module.url(forResource: "device-pdf-text-layer", withExtension: "pdf"))
        let doc = try #require(CGPDFDocument(url as CFURL))
        return try #require(doc.page(at: 1))
    }

    @Test func glyphsMatchTheReferenceTextLayer() throws {
        let glyphs = DevicePDFTextLayer.glyphs(page: try page())
        #expect(glyphs.count == Self.expected.count)
        for (glyph, row) in zip(glyphs, Self.expected) {
            #expect(glyph.text == row.0)
            #expect(abs(glyph.x0 - row.1) < 1e-9 && abs(glyph.top - row.2) < 1e-9 && abs(glyph.x1 - row.3) < 1e-9 && abs(glyph.bottom - row.4) < 1e-9,
                    "\(row.0): \(glyph) vs \(row)")
            #expect(abs(glyph.size - row.5) < 1e-9)
            #expect(glyph.font == row.6)
            #expect(glyph.upright == row.7)
        }
    }

    @Test func pageSizeUsesTheDisplayedBox() throws {
        #expect(DevicePDFTextLayer.pageSize(page: try page()) == CGSize(width: 612, height: 792))
    }

    @Test func shiftedAndCroppedPagesKeepGlyphsOnTheRenderedInk() throws {
        for rotate in [0, 90, 180, 270] {
            // Inherited, nonzero MediaBox; a smaller CropBox; one visible letter and text outside the crop.
            let stream = "BT /F1 20 Tf 1 0 0 1 90 170 Tm (H) Tj 1 0 0 1 42 55 Tm (OFF) Tj ET"
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [40 50 260 280] >>",
                "<< /Type /Page /Parent 2 0 R /CropBox [60 80 200 240] /Rotate \(rotate) /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
            ]
            var pdf = "%PDF-1.4\n", offsets = [0]
            for (index, object) in objects.enumerated() {
                offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
            }
            let xref = pdf.utf8.count
            pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
            for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
            pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            let provider = try #require(CGDataProvider(data: Data(pdf.utf8) as CFData))
            let document = try #require(CGPDFDocument(provider)), page = try #require(document.page(at: 1))
            let size = DevicePDFTextLayer.pageSize(page: page)
            let quarter = rotate == 90 || rotate == 270
            #expect(size == CGSize(width: quarter ? 160 : 140, height: quarter ? 140 : 160))
            let glyphs = DevicePDFTextLayer.glyphs(page: page)
            #expect(glyphs.map(\.text) == ["H"])
            let glyph = try #require(glyphs.first)
            let image = try #require(DevicePDFRaster.render(page, dpi: 144))
            let rgb = DevicePDFRaster.rgb(image)
            var ink = 0, outside = 0
            for y in 0..<rgb.height {
                for x in 0..<rgb.width {
                    let offset = (y * rgb.width + x) * 3
                    if rgb.pixels[offset] < 100 && rgb.pixels[offset + 1] < 100 && rgb.pixels[offset + 2] < 100 {
                        ink += 1
                        let px = Double(x) / 2, py = Double(y) / 2
                        if px < glyph.x0 - 1 || px > glyph.x1 + 1 || py < glyph.top - 1 || py > glyph.bottom + 1 { outside += 1 }
                    }
                }
            }
            #expect(ink > 20)
            #expect(outside == 0, "rotation \(rotate): \(outside) ink pixels outside \(glyph)")
        }
    }

    @Test func fontCasesReadTheirText() throws {
        let text = DevicePDFTextLayer.glyphs(page: try page()).map(\.text)
        #expect(text.contains("fi"))          // Differences: /f_i
        #expect(text.contains("\u{1D49C}"))   // ToUnicode surrogate pair
        #expect(text.contains("(cid:153)"))   // Identity-H code without a mapping
        #expect(text.contains("\u{0393}"))    // embedded Type 1 cleartext: dup 65 /Gamma put
        #expect(text.contains("(cid:68)"))    // ... and a name the glyph list lacks
        let rotated = DevicePDFTextLayer.glyphs(page: try page()).filter { !$0.upright }
        #expect(rotated.map(\.text).joined() == "Rotated")
    }

    @Test func offBaselineMetricsAreReplacedByTheBaselineBox() throws {
        // OffBase's descriptor puts every glyph 0.5 to 1.5 em below its baseline (y = 530): the box is rebuilt from it.
        let off = DevicePDFTextLayer.glyphs(page: try page()).filter { $0.font == "MNOPQR+OffBase" }
        #expect(off.count == 3)
        for g in off {
            #expect(abs(g.top - (792 - (530 + 0.75 * g.size))) < 1e-9)
            #expect(abs(g.bottom - (792 - (530 - 0.25 * g.size))) < 1e-9)
        }
    }

    @Test func toUnicodeCMapForms() {
        let cmap = Array("""
        2 beginbfchar <41> <03B1> <42> <00660069> endbfchar
        2 beginbfrange <61> <63> <0078> <64> <65> [<0041> <0042>] endbfrange
        1 beginbfchar <20> <00A0> endbfchar
        """.utf8)
        let map = DevicePDFCMap.toUnicode(cmap)
        #expect(map[0x41] == "α" && map[0x42] == "fi" && map[0x61] == "x" && map[0x63] == "z" && map[0x64] == "A" && map[0x65] == "B")
        #expect(map[0x20] == "\u{00A0}")
    }

    @Test func glyphNamesFollowPdfminer() {
        #expect(DevicePDFFontEncoding.name2unicode("alpha") == "α")
        #expect(DevicePDFFontEncoding.name2unicode("uni03B103B2") == "αβ")
        #expect(DevicePDFFontEncoding.name2unicode("u1D400") == "\u{1D400}")
        #expect(DevicePDFFontEncoding.name2unicode("f_i") == "fi")
        #expect(DevicePDFFontEncoding.name2unicode("a.sc") == "a")
        #expect(DevicePDFFontEncoding.name2unicode(".notdef") == nil)
        #expect(DevicePDFFontEncoding.name2unicode("uniD800") == nil)
        #expect(DevicePDFFontEncoding.name2unicode("notaglyph") == nil)
    }
}

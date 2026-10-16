import XCTest
@testable import ScienceReaderCore

/// A formula crop cleaned before it is shown (owner, build 62: "an outline clean step where excess pixels around the
/// edge are cleaned and then with margin"; DevicePDFRaster.cleanFormula). Crops are 216 dpi, so a 10 pt line is
/// 30 px to the em; the margin here is 8 px.
final class DevicePDFFormulaCleanTests: XCTestCase {
    private let em = 30.0, margin = 8

    /// White, with black rectangles (end exclusive) and, around each `halo` rectangle, a one-pixel grey edge as
    /// antialiasing leaves.
    private func canvas(_ width: Int, _ height: Int, _ ink: [[Int]], halo: [[Int]] = []) -> DevicePDFRaster.RGB {
        var pixels = [UInt8](repeating: 255, count: width * height * 3)
        func paint(_ r: [Int], _ value: UInt8) {
            for y in max(0, r[1])..<min(height, r[3]) { for x in max(0, r[0])..<min(width, r[2]) {
                let i = (y * width + x) * 3; pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value } }
        }
        for r in halo { paint([r[0] - 1, r[1] - 1, r[2] + 1, r[3] + 1], 220) }
        for r in ink + halo { paint(r, 0) }
        return .init(width: width, height: height, pixels: pixels)
    }

    /// Dark pixels of the cleaned image, in the crop's coordinates.
    private func dark(_ cleaned: DevicePDFRaster.CleanedCrop, below threshold: UInt8 = 250) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for y in 0..<cleaned.image.height { for x in 0..<cleaned.image.width where cleaned.image.pixels[(y * cleaned.image.width + x) * 3] < threshold {
            out.append((x + cleaned.rect[0], y + cleaned.rect[1])) } }
        return out
    }

    private func assertShape(_ cleaned: DevicePDFRaster.CleanedCrop, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(cleaned.image.width, cleaned.rect[2] - cleaned.rect[0], file: file, line: line)
        XCTAssertEqual(cleaned.image.height, cleaned.rect[3] - cleaned.rect[1], file: file, line: line)
        XCTAssertEqual(cleaned.image.pixels.count, cleaned.image.width * cleaned.image.height * 3, file: file, line: line)
    }

    func testTheTailsOfTheLinesAboveAndBelowGoAndTheInkKeepsAMargin() {
        // A display formula's box padded by 2 pt: descender tails of the line above cut by the top edge, ascender stubs
        // of the line below cut by the bottom edge, each with its antialiased rim.
        let crop = canvas(300, 120, [[40, 40, 260, 80]],
                          halo: [[20, 0, 30, 5], [100, 0, 110, 6], [200, 0, 204, 4], [50, 114, 60, 120], [150, 112, 156, 120]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        assertShape(cleaned)
        // The formula with a one-pixel rim for its own antialiasing, then the margin on every side.
        XCTAssertEqual(cleaned.rect, [39 - margin, 39 - margin, 261 + margin, 81 + margin])
        XCTAssertTrue(dark(cleaned).allSatisfy { (40..<260).contains($0.0) && (40..<80).contains($0.1) }, "nothing of the other lines is left, not even their grey rims")
        XCTAssertEqual(dark(cleaned, below: 1).count, 220 * 40, "the formula's ink is all there")
    }

    func testATallOperatorAndItsLimitsStay() {
        // An integral from near the top to near the bottom with limits above and below it, and one tail at the top edge.
        let crop = canvas(240, 120, [[20, 8, 26, 112], [16, 4, 30, 7], [16, 113, 30, 116], [40, 40, 200, 80], [200, 0, 210, 2]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        assertShape(cleaned)
        XCTAssertEqual(cleaned.rect, [15 - margin, 3 - margin, 201 + margin, 117 + margin], "integral, limits and body kept; the tail dropped")
        XCTAssertFalse(dark(cleaned).contains { $0.0 >= 200 && $0.1 < 3 }, "the tail at the top edge is gone")
    }

    func testAFractionKeepsNumeratorBarAndDenominator() {
        let crop = canvas(240, 110, [[100, 20, 140, 45], [90, 55, 150, 57], [100, 65, 140, 90], [60, 0, 70, 5], [120, 105, 126, 110]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        assertShape(cleaned)
        XCTAssertEqual(cleaned.rect, [89 - margin, 19 - margin, 151 + margin, 91 + margin])
        XCTAssertEqual(dark(cleaned, below: 1).count, 40 * 25 + 60 * 2 + 40 * 25, "numerator, the thin bar and denominator, whole")
    }

    func testAFormulaWithNothingToTrimOnlyGetsItsMargin() {
        let crop = canvas(100, 80, [[30, 30, 70, 50]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        assertShape(cleaned)
        XCTAssertEqual(cleaned.rect, [29 - margin, 29 - margin, 71 + margin, 51 + margin])
        let left = dark(cleaned).map(\.0).min()! - cleaned.rect[0], right = cleaned.rect[2] - 1 - dark(cleaned).map(\.0).max()!
        let top = dark(cleaned).map(\.1).min()! - cleaned.rect[1], bottom = cleaned.rect[3] - 1 - dark(cleaned).map(\.1).max()!
        XCTAssertEqual(Set([left, right, top, bottom]), [margin + 1], "the same white on every side")
        XCTAssertEqual(DevicePDFRaster.cleanFormula(crop, em: em, margin: margin).image.pixels, cleaned.image.pixels, "deterministic")
    }

    func testAFormulaTheBoxCutIntoIsNeverCutFurther() {
        // Ink at the top edge as tall as a line's letters is the formula itself, clipped by its box: kept.
        let tall = DevicePDFRaster.cleanFormula(canvas(240, 80, [[40, 0, 60, 20], [70, 25, 200, 60]]), em: em, margin: margin)
        XCTAssertEqual(tall.rect[1], -margin, "the clipped piece stays")
        // A wide flat piece at the edge holding much of the ink (a cut numerator): taking it would cut the formula.
        let wide = DevicePDFRaster.cleanFormula(canvas(240, 80, [[40, 0, 200, 12], [60, 30, 180, 50]]), em: em, margin: margin)
        XCTAssertEqual(wide.rect[1], -margin, "nothing is dropped when a quarter of the ink would go")
    }

    func testSpecksAmongTheDroppedTailsGoAndTheFormulasOwnDotsStay() {
        // Ascender stubs of the next line at the bottom edge, with an i's dot among them; the formula's own dot (ẋ) above.
        let crop = canvas(300, 110, [[40, 20, 260, 60], [50, 100, 56, 110], [150, 102, 156, 110], [120, 101, 123, 104], [100, 14, 103, 17]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        assertShape(cleaned)
        XCTAssertEqual(cleaned.rect, [39 - margin, 13 - margin, 261 + margin, 61 + margin], "the dot above stays; the stubs and the i's dot go")
    }

    func testAGlyphCutByTheSideOfTheBoxGoesButTheFormulasFirstSymbolStays() {
        // A sliver of the neighbouring word at the left edge, then a narrow first symbol close to the formula.
        let crop = canvas(300, 80, [[0, 30, 5, 45], [34, 30, 37, 50], [40, 25, 260, 55]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        XCTAssertEqual(cleaned.rect, [33 - margin, 24 - margin, 261 + margin, 56 + margin])
    }
}

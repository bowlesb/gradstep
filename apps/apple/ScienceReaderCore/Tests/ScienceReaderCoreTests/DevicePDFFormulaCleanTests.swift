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

    /// Compare ink in original crop coordinates, so a smaller image or moved margin cannot hide lost symbols.
    private func positions(_ rectangles: [[Int]], width: Int) -> Set<Int> {
        Set(rectangles.flatMap { r in (r[1]..<r[3]).flatMap { y in (r[0]..<r[2]).map { x in y * width + x } } })
    }

    private func blackPositions(_ cleaned: DevicePDFRaster.CleanedCrop, width: Int) -> Set<Int> {
        Set(dark(cleaned, below: 1).map { $0.1 * width + $0.0 })
    }

    func testNativeContentRemovesInteriorPunctuationAndNeighborFragments() {
        // Neither foreign piece reaches the crop edge. The old pixel-only core inference keeps both.
        let own = [[20, 20, 100, 40]], foreign = [[110, 24, 114, 29], [35, 4, 43, 10]]
        let crop = canvas(120, 60, own, halo: foreign)
        let legacy = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        XCTAssertTrue(blackPositions(legacy, width: 120).isSuperset(of: positions(foreign, width: 120)))
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [19, 19, 101, 41])
        assertShape(cleaned)
        XCTAssertEqual(blackPositions(cleaned, width: 120), positions(own, width: 120))
        XCTAssertTrue(dark(cleaned).allSatisfy { (20..<100).contains($0.0) && (20..<40).contains($0.1) }, "foreign antialiasing is removed too")
    }

    func testNativeContentCanRemoveMoreForeignInkThanTheSmallStatisticContains() {
        let own = [[50, 25, 60, 35]], foreign = [[10, 0, 110, 8]]
        let crop = canvas(120, 60, own + foreign)
        let legacy = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        XCTAssertEqual(blackPositions(legacy, width: 120).count, 900, "legacy quarter-ink safeguard keeps the neighboring line")
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [49, 24, 61, 36])
        XCTAssertEqual(blackPositions(cleaned, width: 120), positions(own, width: 120), "ownership preserves the entire statistic while removing 800 foreign pixels")
    }

    func testNativeContentProtectsDisconnectedDotsPrimesScriptsFractionAndIntegralLimits() {
        let own = [[70, 35, 150, 60], [40, 20, 60, 27], [35, 31, 65, 33], [40, 38, 60, 45],
                   [15, 10, 20, 90], [10, 5, 25, 8], [10, 92, 25, 95],
                   [90, 28, 92, 30], [110, 21, 112, 26], [130, 18, 140, 24]]
        let crop = canvas(220, 110, own + [[180, 30, 190, 40]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [9, 4, 151, 96])
        assertShape(cleaned)
        XCTAssertEqual(blackPositions(cleaned, width: 220), positions(own, width: 220), "small detached mathematical marks are protected, not treated as specks")
    }

    func testProtectedComponentsStayWholeAcrossContentBoundsAndCropEdges() {
        // A connected radical/bar extends above and left of the hint; a first glyph is clipped by the crop's edge.
        let own = [[5, 15, 52, 18], [48, 15, 52, 40], [0, 25, 6, 45], [40, 35, 100, 50]]
        let crop = canvas(130, 70, own + [[110, 25, 116, 40]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [3, 20, 101, 51])
        XCTAssertEqual(blackPositions(cleaned, width: 130), positions(own, width: 130), "a component is never clipped to the content rectangle")
        XCTAssertEqual(cleaned.rect[0], -margin, "ink already at the crop edge is retained")
    }

    func testContentUsesPixelToleranceAndKeepsProtectedAntialiasing() {
        let own = [[30, 20, 60, 40]], rim = [[30, 20, 60, 40]]
        let crop = canvas(100, 70, [], halo: rim + [[75, 20, 80, 40]])
        // A subpixel bound just beyond the main ink still intersects the one-pixel protected tolerance.
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [60.5, 19, 70, 41])
        XCTAssertEqual(blackPositions(cleaned, width: 100), positions(own, width: 100))
        XCTAssertEqual(dark(cleaned).count, 32 * 22, "all protected one-pixel grey edges remain")
    }

    func testShortEdgeDescendersOverlappingLooseFontBoundsGoButOwnScriptsStay() {
        // The neighboring line's g reaches inside a loose ascent box, but most of its clipped tail is outside.
        // A detached superscript and prime wholly inside the band must remain, even though both are small.
        let own = [[20, 17, 90, 38], [93, 8, 99, 13], [102, 7, 104, 11]]
        let crop = canvas(120, 50, own, halo: [[30, 0, 36, 12], [45, 44, 50, 50]])
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [0, 6.6, 120, 44])
        XCTAssertEqual(blackPositions(cleaned, width: 120), positions(own, width: 120))
    }

    func testNativeBandRetainsTallClippedOperatorsAndAnEdgeScriptWithItsMidpointInside() {
        let own = [[10, 0, 15, 24], [20, 0, 25, 12], [40, 20, 90, 40]]
        let crop = canvas(120, 50, own)
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [0, 5, 120, 41])
        XCTAssertEqual(blackPositions(cleaned, width: 120), positions(own, width: 120))
    }

    func testMalformedOrOutOfCropContentKeepsTheExactLegacyResult() {
        let crop = canvas(120, 60, [[20, 20, 100, 40], [50, 0, 55, 5]])
        let legacy = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        let invalid: [[Double]] = [[], [1, 2, 3], [1, 2, 3, 4, 5], [.nan, 10, 100, 50],
                                   [10, 10, .infinity, 50], [-1, 10, 100, 50], [10, -1, 100, 50],
                                   [10, 10, 121, 50], [10, 10, 100, 61], [30, 10, 20, 50],
                                   [10, 40, 100, 20], [10, 10, 10, 40], [10, 10, 100, 10]]
        for content in invalid {
            let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: content)
            XCTAssertEqual(cleaned.rect, legacy.rect, "invalid content: \(content)")
            XCTAssertEqual(cleaned.image.pixels, legacy.image.pixels, "invalid content: \(content)")
        }
    }

    func testContentWithoutAnyProtectedInkAbstainsToLegacyCleaning() {
        let crop = canvas(120, 60, [[20, 20, 100, 40], [50, 0, 55, 5]])
        let legacy = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin)
        let cleaned = DevicePDFRaster.cleanFormula(crop, em: em, margin: margin, content: [105, 45, 115, 55])
        XCTAssertEqual(cleaned.rect, legacy.rect)
        XCTAssertEqual(cleaned.image.pixels, legacy.image.pixels, "a misplaced hint cannot erase every component")
    }
}

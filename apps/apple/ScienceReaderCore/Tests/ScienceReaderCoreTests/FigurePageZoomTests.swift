import CoreGraphics
import XCTest
@testable import ScienceReaderCore

/// Zoom out of a figure onto its PDF page (FIGURE_VIEW.md "Zoom out onto the page"): the converter's figure regions read
/// from provenance, the page placed under the figure's own pixels, and the viewer's zoom arithmetic.
final class FigurePageZoomTests: XCTestCase {
    private let manifest = try! JSONDecoder().decode(ReaderBundleManifest.self, from: Data("""
    {"format":"reader-bundle-v1","renderer":{"id":"gradstep-device-pdf-mathml-v1","build_sha256":"\(String(repeating: "a", count: 64))"},
     "source":{"kind":"device-pdf","sha256":"\(String(repeating: "b", count: 64))","provenance_path":"provenance.json"},
     "entrypoint":"index.html","index_path":"reader.json","members":[]}
    """.utf8))

    private func provenance(figures: String?) -> Data {
        Data("""
        {"format":"device-pdf-reader-provenance-v1","source":{"kind":"device-pdf","pdf_sha256":"\(String(repeating: "b", count: 64))"},
         "adapter":{"id":"gradstep-device-pdf-mathml-v1","build_sha256":"\(String(repeating: "a", count: 64))"}\(figures.map { ",\"figures\":\($0)" } ?? "")}
        """.utf8)
    }

    func testFigureRegionsAreReadFromProvenanceAndBadRowsAreLeftOut() throws {
        let source = try DevicePDFReaderProvenance.validate(provenance(figures: """
        [["b-1-10",0,314.88,300,545.28,410.4,612,792],
         ["b-1-11",1.5,10,10,20,20,612,792],
         ["b-1-12",2,10,10,9,20,612,792],
         ["b-1-13",2,10,10,700,20,612,792],
         ["b-1-14",3,10,10,20,20],
         [7,3,10,10,20,20,612,792],
         ["b-1-15",3,72,72,144,108,792,612]]
        """), manifest: manifest)
        XCTAssertEqual(Set(source.figures.keys), ["b-1-10", "b-1-15"], "a fractional page, an empty crop, a crop off the page, a short row and a numeric id are left out")
        let first = try XCTUnwrap(source.figures["b-1-10"])
        XCTAssertEqual(first.page, 0)
        XCTAssertEqual(first.crop.minX, 314.88, accuracy: 1e-9); XCTAssertEqual(first.crop.minY, 300, accuracy: 1e-9)
        XCTAssertEqual(first.crop.width, 230.4, accuracy: 1e-9); XCTAssertEqual(first.crop.height, 110.4, accuracy: 1e-9)
        XCTAssertEqual(first.pageSize, CGSize(width: 612, height: 792))
        XCTAssertEqual(source.figures["b-1-15"]?.pageSize, CGSize(width: 792, height: 612), "a turned page as shown")
        // Readings before port revision 10 have no regions: the reading is still valid, it offers no zoom-out.
        XCTAssertEqual(try DevicePDFReaderProvenance.validate(provenance(figures: nil), manifest: manifest).figures, [:])
        XCTAssertEqual(try DevicePDFReaderProvenance.validate(provenance(figures: "{}"), manifest: manifest).figures, [:])
    }

    func testThePageLiesUnderTheFigureInItsOwnPixels() throws {
        // The converter's crop at 150 dpi: 230.4 × 110.4 pt is 480 × 230 px.
        let region = try XCTUnwrap(DevicePDFFigureRegion(page: 0, x0: 314.88, y0: 300, x1: 545.28, y1: 410.4, pageWidth: 612, pageHeight: 792))
        let layout = try XCTUnwrap(FigurePageLayout(region: region, imageWidth: 480, imageHeight: 230))
        XCTAssertEqual(layout.scaleX, 150.0 / 72, accuracy: 1e-9); XCTAssertEqual(layout.scaleY, 150.0 / 72, accuracy: 1e-9)
        XCTAssertEqual(layout.page.minX, -656, accuracy: 1e-6); XCTAssertEqual(layout.page.minY, -625, accuracy: 1e-6)
        XCTAssertEqual(layout.page.width, 1275, accuracy: 1e-6); XCTAssertEqual(layout.page.height, 1650, accuracy: 1e-6)
        // The crop, mapped from page points, is exactly the image.
        let crop = layout.figurePixels(region.crop)
        XCTAssertEqual(crop.minX, 0, accuracy: 1e-6); XCTAssertEqual(crop.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(crop.width, 480, accuracy: 1e-6); XCTAssertEqual(crop.height, 230, accuracy: 1e-6)
        // The canvas: the page (the figure's 12 px margin lies within it); the image's corner where the crop is.
        let canvas = layout.canvas(pad: CGSize(width: 12, height: 12))
        XCTAssertEqual(canvas.size.width, 1275, accuracy: 1e-6); XCTAssertEqual(canvas.size.height, 1650, accuracy: 1e-6)
        XCTAssertEqual(canvas.imageOrigin.x, 656, accuracy: 1e-6); XCTAssertEqual(canvas.imageOrigin.y, 625, accuracy: 1e-6)
        // A figure scaled down for the image budget (dpi 150 × 0.5) maps the same crop at half the density.
        let scaled = try XCTUnwrap(FigurePageLayout(region: region, imageWidth: 240, imageHeight: 115))
        XCTAssertEqual(scaled.page.width, 637.5, accuracy: 1e-6)
        // An image that is not this crop (another aspect) has no page.
        XCTAssertNil(FigurePageLayout(region: region, imageWidth: 480, imageHeight: 480))
    }

    func testTheFiguresMarginReachingPastThePageWidensTheCanvas() throws {
        // A figure flush with the page's top-left corner: its white margin reaches 12 px past the page.
        let region = try XCTUnwrap(DevicePDFFigureRegion(page: 0, x0: 0, y0: 0, x1: 72, y1: 72, pageWidth: 144, pageHeight: 288))
        let layout = try XCTUnwrap(FigurePageLayout(region: region, imageWidth: 150, imageHeight: 150))
        let canvas = layout.canvas(pad: CGSize(width: 12, height: 12))
        XCTAssertEqual(canvas.imageOrigin, CGPoint(x: 12, y: 12))
        XCTAssertEqual(canvas.size.width, 312, accuracy: 1e-6); XCTAssertEqual(canvas.size.height, 612, accuracy: 1e-6)
    }

    func testZoomArithmetic() {
        let view = CGSize(width: 400, height: 800)
        // The crop (480 × 230 at the canvas's 656, 625) fits by its width; the page (1275 × 1650) by its width too.
        let crop = CGRect(x: 656, y: 625, width: 480, height: 230), page = CGRect(x: 0, y: 0, width: 1275, height: 1650)
        XCTAssertEqual(FigureZoomMath.fitZoom(crop, in: view), 400.0 / 480, accuracy: 1e-9)
        XCTAssertEqual(FigureZoomMath.fitZoom(page, in: view), 400.0 / 1275, accuracy: 1e-9)
        // Framing the crop: grown about its centre to the view's shape.
        let framed = FigureZoomMath.fitted(crop, to: view)
        XCTAssertEqual(framed.midX, crop.midX, accuracy: 1e-9); XCTAssertEqual(framed.midY, crop.midY, accuracy: 1e-9)
        XCTAssertEqual(framed.width, 480, accuracy: 1e-9); XCTAssertEqual(framed.height, 960, accuracy: 1e-9)
        // At the crop's fit, held to the crop: centred down (it is shorter than the view), its own width across.
        let z = 400.0 / 480
        let held = FigureZoomMath.clampedOffset(CGPoint(x: 0, y: 0), zoom: z, view: view, bounds: crop)
        XCTAssertEqual(held.x, 656 * z, accuracy: 1e-6)
        XCTAssertEqual(held.y, (crop.midY - 480) * z, accuracy: 1e-6, "the crop centred, the view reaching past it")
        // Held to the page instead, the same zoom pans over the page and stops at its edges.
        let free = FigureZoomMath.clampedOffset(CGPoint(x: -500, y: 5000), zoom: z, view: view, bounds: page)
        XCTAssertEqual(free.x, 0, accuracy: 1e-6); XCTAssertEqual(free.y, (1650 - 960) * z, accuracy: 1e-6)
        // The whole page fitted: centred down, flush across.
        let pageZoom = FigureZoomMath.fitZoom(page, in: view)
        let whole = FigureZoomMath.clampedOffset(.zero, zoom: pageZoom, view: view, bounds: page)
        XCTAssertEqual(whole.x, 0, accuracy: 1e-6); XCTAssertEqual(whole.y, (825 - 800 / pageZoom / 2) * pageZoom, accuracy: 1e-6)
    }

    func testThePageIsDrawnSharpEnoughAndNoLarger() {
        let page = CGSize(width: 612, height: 792)
        // A phone (390 × 844 pt at 3×): the page fits at 0.637 pt per pt; twice the screen's pixels is 3.82 px per point.
        XCTAssertEqual(FigurePageLayout.renderDensity(pageSize: page, viewSize: CGSize(width: 390, height: 844), screenScale: 3, figureDensity: 150.0 / 72),
                       390.0 / 612 * 3 * 2, accuracy: 1e-9)
        // Never below the figure's own density, never past 4096 px along the page's longer side.
        XCTAssertEqual(FigurePageLayout.renderDensity(pageSize: page, viewSize: CGSize(width: 100, height: 100), screenScale: 1, figureDensity: 150.0 / 72),
                       150.0 / 72, accuracy: 1e-9)
        XCTAssertEqual(FigurePageLayout.renderDensity(pageSize: page, viewSize: CGSize(width: 2000, height: 2000), screenScale: 2, figureDensity: 2),
                       4096.0 / 792, accuracy: 1e-9)
    }
}

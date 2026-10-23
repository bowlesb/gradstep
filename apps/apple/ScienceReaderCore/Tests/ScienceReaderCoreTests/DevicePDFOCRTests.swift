import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import ScienceReaderCore

/// A page whose text layer is missing or unreadable is read by on-device text recognition (DevicePDFOCR).
final class DevicePDFOCRTests: XCTestCase {
    private func glyph(_ text: String, _ x: Double) -> DevicePDFGlyph {
        DevicePDFGlyph(text: text, x0: x, top: 100, x1: x + 5, bottom: 110, size: 10, font: "ABCDEF+CMR10", upright: true)
    }

    func testUnreadableLayersAreScansAndUnmappedCodes() {
        let prose = (0..<200).map { glyph(String("abcdefghij".randomElement()!), Double($0) * 5) }
        XCTAssertFalse(DevicePDFOCR.unreadable(prose))
        XCTAssertTrue(DevicePDFOCR.unreadable([]), "a scan has no text layer")
        XCTAssertTrue(DevicePDFOCR.unreadable(Array(prose.prefix(3))), "a scan's layer is empty or nearly")
        XCTAssertFalse(DevicePDFOCR.unreadable(Array(prose.prefix(10))), "a page with a few words (a figure's page) keeps its layer")
        let codes = (0..<200).map { glyph($0 % 2 == 0 ? "(cid:\($0 % 40))" : "e", Double($0) * 5) }
        XCTAssertTrue(DevicePDFOCR.unreadable(codes), "half the characters are codes without a Unicode mapping")
        let math = prose + (0..<20).map { glyph("(cid:\($0))", Double($0) * 5) }
        XCTAssertFalse(DevicePDFOCR.unreadable(math), "a few unmapped math symbols leave the page readable")
    }

    func testRecognisedWordsBecomeGlyphsInPoints() throws {
        // A 612 x 792 pt page at 150 dpi with one line of text 1 inch from the top-left corner.
        let scale = 150.0 / 72.0, width = Int(612 * scale), height = Int(792 * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Times-Roman" as CFString, 24 * scale, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Routing tokens to experts", attributes: [.init(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 72 * scale, y: Double(height) - 96 * scale)
        CTLineDraw(line, context)
        let image = try XCTUnwrap(context.makeImage())
        let glyphs = DevicePDFOCR.glyphs(image: image, size: CGSize(width: 612, height: 792))
        let text = glyphs.map(\.text).joined()
        XCTAssertTrue(text.contains("Routing") && text.contains("experts"), text)
        XCTAssertTrue(glyphs.allSatisfy { $0.font == DevicePDFOCR.font && $0.x0 >= 60 && $0.x1 < 400 && $0.top > 60 && $0.bottom < 110 }, "\(glyphs.first.map { "\($0)" } ?? "")")
        let words = DevicePDFOCR.glyphs(layer: [], image: image, size: CGSize(width: 612, height: 792))
        XCTAssertEqual(words.map(\.text).joined(), text, "an empty layer is replaced by what recognition reads")
    }
}

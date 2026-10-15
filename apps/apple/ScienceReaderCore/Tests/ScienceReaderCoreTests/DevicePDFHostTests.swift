import CoreML
import Foundation
import ImageIO
import XCTest
@testable import ScienceReaderCore

/// The device route's host pieces that need no model files (docs/architecture/DEVICE_PDF_ROUTE.md). The models
/// themselves are checked against the exports' samples by the Mac harness (layout 91/91, tagger 60/60,
/// recogniser 20/20 on 2026-10-15).
@available(macOS 15.0, iOS 18.0, *)
final class DevicePDFHostTests: XCTestCase {
    func testPaddedRowsAreReadThroughTheirStrides() throws {
        // Core ML hands the layout's [30704, 11] scores back with strides [32, 1].
        var storage = [Float](repeating: -1, count: 3 * 4)
        for r in 0..<3 { for c in 0..<3 { storage[r * 4 + c] = Float(r * 10 + c) } }
        let array = try storage.withUnsafeMutableBytes { raw in
            try MLMultiArray(dataPointer: raw.baseAddress!, shape: [3, 3], dataType: .float32, strides: [4, 1])
        }
        XCTAssertEqual(DevicePDFModels.floats(array), [0, 1, 2, 10, 11, 12, 20, 21, 22])
    }

    func testLayoutDecodingKeepsPerClassNMSAndScoreOrder() {
        // Two overlapping paragraphs (IoU 0.81 > 0.6: one survives), a heading over the same box (another class:
        // kept), a paragraph under its threshold (dropped).
        let boxes: [Float] = [0, 0, 100, 10, /**/ 0, 0, 100, 9, /**/ 0, 0, 100, 10, /**/ 0, 50, 100, 60]
        let classes = ["heading", "paragraph"]
        let scores: [Float] = [0.1, 0.9, /**/ 0.1, 0.8, /**/ 0.7, 0.1, /**/ 0.1, 0.5]
        let found = DevicePDFModels.decode(boxes: boxes, scores: scores, points: 4, classes: classes,
                                           thresholds: ["heading": 0.6, "paragraph": 0.6], iou: 0.6, maximum: 300, k: 2)
        XCTAssertEqual(found.map(\.cls), ["paragraph", "heading"])
        XCTAssertEqual(found.map(\.score), [0.9, 0.7])
        XCTAssertEqual(found[0].box, [0, 0, 100, 10])
    }

    func testTokenizerDecodesByteLevelTokensAndCleansSpaces() {
        // "Ġ" is the byte-level space; specials are skipped; " ," loses its space as transformers' clean-up does.
        let tokens = [0: "<s>", 2: "</s>", 5: "\\frac", 6: "{a}", 7: "Ġ,", 8: "Ġb", 9: "一"]
        let tokenizer = DevicePDFTokenizer(tokens: tokens, special: [0, 2])
        XCTAssertEqual(tokenizer.decode([5, 6, 7, 8, 9, 2]), "\\frac{a}, b一")
    }

    func testRecogniserResizeFollowsTorchvision() {
        // Shorter side to 447 unless the longer side would pass 448: then the longer is 448.
        XCTAssertEqual(DevicePDFRaster.resizedSize(width: 300, height: 40, size: 447, maximum: 448).0, 448)
        XCTAssertEqual(DevicePDFRaster.resizedSize(width: 300, height: 40, size: 447, maximum: 448).1, 59)
        XCTAssertTrue(DevicePDFRaster.resizedSize(width: 400, height: 400, size: 447, maximum: 448) == (447, 447))
    }

    func testTrimBorderFindsTheInkAndPixelsArePadded() {
        var pixels = [UInt8](repeating: 255, count: 20 * 10 * 3)
        for y in 3..<6 { for x in 4..<9 { let i = (y * 20 + x) * 3; pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0 } }
        let trimmed = DevicePDFRaster.trimBorder(.init(width: 20, height: 10, pixels: pixels))
        XCTAssertEqual(trimmed.width, 5); XCTAssertEqual(trimmed.height, 3)
        let input = DevicePDFRaster.recogniserPixels(.init(width: 20, height: 10, pixels: pixels), size: 448, mean: 0.9545467, std: 0.15394445)
        XCTAssertEqual(input.count, 448 * 448)
        XCTAssertEqual(input[447 * 448 + 447], 0, "padding is the normalised mean")
    }

    func testPNGIsTheMinimalProfile() throws {
        let image = DevicePDFRaster.RGB(width: 3, height: 2, pixels: [255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 128, 128, 128, 255, 255, 255])
        let png = DevicePDFRaster.png(image)
        let bytes = [UInt8](png)
        XCTAssertEqual(Array(bytes[12..<16]), Array("IHDR".utf8))
        XCTAssertEqual(bytes[24], 8); XCTAssertEqual(bytes[25], 2)
        // Chunk types in order: IHDR, IDAT, IEND, nothing else.
        var offset = 8, types: [String] = []
        while offset < bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            types.append(String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)); offset += 12 + length
        }
        XCTAssertEqual(types, ["IHDR", "IDAT", "IEND"])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 3); XCTAssertEqual(decoded.height, 2)
    }

    func testProvenanceNamesThePDFAndThePaper() throws {
        let manifest = try JSONDecoder().decode(ReaderBundleManifest.self, from: Data("""
        {"format":"reader-bundle-v1","renderer":{"id":"gradstep-device-pdf-mathml-v1","build_sha256":"\(String(repeating: "a", count: 64))"},
         "source":{"kind":"device-pdf","sha256":"\(String(repeating: "b", count: 64))","provenance_path":"provenance.json"},
         "entrypoint":"index.html","index_path":"reader.json","members":[]}
        """.utf8))
        let good = Data("""
        {"format":"device-pdf-reader-provenance-v1","source":{"kind":"device-pdf","pdf_sha256":"\(String(repeating: "b", count: 64))",
         "paper":{"source_id":"2305.18290","revision":3}},"adapter":{"id":"gradstep-device-pdf-mathml-v1","build_sha256":"\(String(repeating: "a", count: 64))"}}
        """.utf8)
        let source = try DevicePDFReaderProvenance.validate(good, manifest: manifest)
        XCTAssertEqual(source.paper, try DevicePDFPaper(sourceID: "2305.18290", revision: 3))
        XCTAssertNoThrow(try DevicePDFPaper(sourceID: "local:" + UUID().uuidString.lowercased(), revision: 1))
        XCTAssertThrowsError(try DevicePDFPaper(sourceID: "local:not-a-uuid", revision: 1))
        let otherPDF = Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "\"pdf_sha256\":\"bbbb", with: "\"pdf_sha256\":\"cbbb").utf8)
        XCTAssertThrowsError(try DevicePDFReaderProvenance.validate(otherPDF, manifest: manifest))
    }
}

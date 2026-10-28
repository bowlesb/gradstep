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
    func testIndependentTaggerRecoveryRunsOnlyAfterTwoInvalidBuffers() throws {
        for sequence in [[[-2.0, 0, 3]], [[0, 0, 0], [-2, 0, 3]], [[0, 0, 0], [0, 0, 0]]] {
            var calls = 0, recoveries = 0
            let result = try DevicePDFModels.readTaggerOutput(count: 3, recovery: {
                recoveries += 1; return [-2, 0, 3]
            }) {
                let row = sequence[min(calls, sequence.count - 1)].map(Float.init); calls += 1; return row
            }
            XCTAssertEqual(result, [-2, 0, 3])
            XCTAssertEqual(calls, sequence.count)
            XCTAssertEqual(recoveries, sequence.last == [0, 0, 0] ? 1 : 0)
        }
    }

    func testInvalidReferenceOrThrownPredictionStillFailsWithinTheBound() {
        var calls = 0, recoveries = 0
        XCTAssertThrowsError(try DevicePDFModels.readTaggerOutput(count: 3, recovery: {
            recoveries += 1; return [0, 0, 0]
        }) { calls += 1; return [0, 0, 0] })
        XCTAssertEqual(calls, 2); XCTAssertEqual(recoveries, 1)
        calls = 0; recoveries = 0
        XCTAssertThrowsError(try DevicePDFModels.readTaggerOutput(count: 3, recovery: {
            recoveries += 1; return [-2, 0, 3]
        }) { calls += 1; throw DevicePDFModelError.unusable("prediction") })
        XCTAssertEqual(calls, 1); XCTAssertEqual(recoveries, 0, "recovery does not hide arbitrary model exceptions")
    }

    func testPartiallyEmptyTaggerOutputRetriesAndFailsExplicitly() throws {
        let valid = (0..<67).map { Float($0) * 0.01 - 10 }
        let partial = Array(valid.prefix(32)) + [Float](repeating: 0, count: 35)
        var calls = 0
        let recovered = try DevicePDFModels.readTaggerOutput(count: valid.count) {
            calls += 1; return calls == 1 ? partial : valid
        }
        XCTAssertEqual(recovered, valid); XCTAssertEqual(calls, 2)
        XCTAssertThrowsError(try DevicePDFModels.readTaggerOutput(count: partial.count) { partial })
        let separated: [Float] = [0, -1, 0, -2, 0, -3, 0, -4, 0, -5, 0, -6, 0, -7, 0]
        XCTAssertEqual(try DevicePDFModels.readTaggerOutput(count: separated.count) { separated }, separated)
    }

    func testInvalidTaggerBuffersRetryOnceWithoutSilentlyRemovingMath() throws {
        for invalid: [Float] in [[0, 0, 0], [-2, .nan, 3], [-2, .infinity, 3], [-2, 3]] {
            var calls = 0
            let recovered = try DevicePDFModels.readTaggerOutput(count: 3) { calls += 1; return calls == 1 ? invalid : [-2, 0, 3] }
            XCTAssertEqual(recovered, [-2, 0, 3]); XCTAssertEqual(calls, 2)
            calls = 0
            XCTAssertThrowsError(try DevicePDFModels.readTaggerOutput(count: 3) { calls += 1; return invalid })
            XCTAssertEqual(calls, 2, "persistent bad output fails after a bounded retry")
        }
        var calls = 0
        _ = try DevicePDFModels.readTaggerOutput(count: 3) { calls += 1; return [-2, 0, 3] }
        XCTAssertEqual(calls, 1, "valid outputs have no extra model call")
    }

    /// TestFlight 93's pack (no reference) keeps 93's tolerance after the same bounded retry (JUDGMENT_LOG 56).
    func testPackWithoutReferenceReadsAPersistentlyInvalidLineAsProseAfterTheRetry() throws {
        for invalid: [Float] in [[0, 0, 0], [-2, .nan, 3], [-2, 3]] {
            var calls = 0
            let recovered = try DevicePDFModels.readLegacyTaggerOutput(count: 3) { calls += 1; return calls == 1 ? invalid : [-2, 0, 3] }
            XCTAssertEqual(recovered.values, [-2, 0, 3]); XCTAssertFalse(recovered.unread); XCTAssertEqual(calls, 2)
            calls = 0
            let unread = try DevicePDFModels.readLegacyTaggerOutput(count: 3) { calls += 1; return invalid }
            XCTAssertTrue(unread.unread); XCTAssertEqual(calls, 2, "the same bounded retry first")
            XCTAssertEqual(unread.values.count, 3)
            XCTAssertTrue(unread.values.allSatisfy { $0.isFinite && 1 / (1 + exp(-Double($0))) < 0.01 }, "prose under any threshold")
        }
        var calls = 0
        let healthy = try DevicePDFModels.readLegacyTaggerOutput(count: 3) { calls += 1; return [-2, 0, 3] }
        XCTAssertEqual(healthy.values, [-2, 0, 3]); XCTAssertFalse(healthy.unread); XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try DevicePDFModels.readLegacyTaggerOutput(count: 3) { throw DevicePDFModelError.unusable("prediction") },
                             "a thrown model error is not hidden")
    }

    func testTaggerVocabularyMatchesTheLoadedModelShape() throws {
        XCTAssertEqual(try DevicePDFModels.validateTaggerShape(modelWidth: 10, context: 0, maximum: 400), 10)
        XCTAssertEqual(try DevicePDFModels.validateTaggerShape(modelWidth: 12, context: 24, maximum: 400), 12)
        for (width, context, maximum) in [(10, 24, 400), (12, 0, 400), (14, 24, 400), (12, -1, 400), (12, 200, 400), (12, 24, 401), (10, 0, 1)] {
            XCTAssertThrowsError(try DevicePDFModels.validateTaggerShape(modelWidth: width, context: context, maximum: maximum))
        }
        XCTAssertThrowsError(try DevicePDFModels.validateTaggerShape(modelWidth: nil, context: 0, maximum: 400))
        XCTAssertThrowsError(try DevicePDFModels.validateTaggerShape(modelWidth: 10, context: 0, maximum: nil))
    }

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

    /// A page with `/Rotate 90` is drawn turned, as displayed: its size swaps and a mark in the bottom-left of the
    /// unrotated page lands where the turn puts it; an unrotated page draws as before.
    func testRenderTurnsARotatedPageAsItIsDisplayed() throws {
        func document(rotate: Int) throws -> CGPDFPage {
            let content = "0 0 0 rg 0 0 20 20 re f"
            let pdf = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n"
                + "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Rotate \(rotate) /Contents 4 0 R >> endobj\n"
                + "4 0 obj << /Length \(content.utf8.count) >> stream\n\(content)\nendstream endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pdf.utf8) as CFData))
            return try XCTUnwrap(CGPDFDocument(provider)?.page(at: 1))
        }
        func darkCorner(_ image: CGImage) throws -> String {
            let w = image.width, h = image.height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Bitmap rows run top to bottom in memory.
            func dark(_ x: Int, _ y: Int) -> Bool { pixels[(y * w + x) * 4] < 64 }
            let corners = ["top-left": dark(5, 5), "top-right": dark(w - 6, 5), "bottom-left": dark(5, h - 6), "bottom-right": dark(w - 6, h - 6)]
            return corners.filter(\.value).map(\.key).sorted().joined(separator: ",")
        }
        let plain = try XCTUnwrap(DevicePDFRaster.render(try document(rotate: 0), dpi: 72))
        XCTAssertEqual([plain.width, plain.height], [200, 100])
        XCTAssertEqual(try darkCorner(plain), "bottom-left")
        let turned = try XCTUnwrap(DevicePDFRaster.render(try document(rotate: 90), dpi: 72))
        XCTAssertEqual([turned.width, turned.height], [100, 200], "a quarter turn swaps the page's size")
        XCTAssertEqual(try darkCorner(turned), "top-left", "/Rotate 90 turns the page clockwise: its bottom-left comes to the top-left")
    }

    func testConverterRulesAreNamesOrNumericOptions() {
        let rules = DevicePDFRoute.converterRules(["tidy", "displayGate=0.9", "bad name", "x=y", "captionMath", "=1"])
        XCTAssertEqual(rules.map(\.0), ["captionMath", "displayGate", "tidy"])
        XCTAssertEqual(rules.first { $0.0 == "displayGate" }?.1 as? Double, 0.9)
        XCTAssertEqual(rules.first { $0.0 == "tidy" }?.1 as? Bool, true)
    }
}

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import ScienceReaderCore

/// The completeness step (FigureCropCompletion.swift) against the shared golden fixtures exported from
/// scripts/subfigure-detector/app_crops.py (tests/fixtures/figure-crops/cases.json); the browser's figure-crops.test.ts
/// reads the same file.
@Suite struct FigureCropCompletionTests {
    struct Fixtures: Decodable {
        struct Expect: Decodable {
            let components: Int; let inkPixels: Int; let componentDigest: String; let tiled: Bool; let crops: [[Double]?]
            let inkCoverage: Double; let padding: Int
        }
        struct Case: Decodable { let name: String; let image: String; let width: Int; let height: Int; let boxes: [[Double]]; let expect: Expect }
        let tolerancePixels: Double
        let cases: [Case]
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures/figure-crops")
    static let fixtures = try! JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: directory.appendingPathComponent("cases.json")))

    static func image(_ name: String) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The PNG's decoded bytes as they are (no drawing, no colour conversion).
    static func ink(_ name: String) throws -> FigureInk {
        let image = try image(name)
        let data = try #require(image.dataProvider?.data) as Data
        #expect(image.bitsPerComponent == 8)
        return try #require(data.withUnsafeBytes { FigureInk(pixels: $0, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow, bytesPerPixel: image.bitsPerPixel / 8) })
    }

    @Test(arguments: fixtures.cases.map(\.name)) func matchesThePythonReference(_ name: String) throws {
        let c = try #require(Self.fixtures.cases.first { $0.name == name })
        let ink = try Self.ink(c.image)
        #expect(ink.width == c.width && ink.height == c.height)
        #expect(ink.inkPixels == c.expect.inkPixels)
        #expect(ink.components.count == c.expect.components)
        let text = ink.components.map { "\(Int($0.box.x0)),\(Int($0.box.y0)),\(Int($0.box.x1)),\(Int($0.box.y1)),\($0.pixels)" }.joined(separator: ";")
        #expect(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() == c.expect.componentDigest)
        let result = FigureCropCompletion.complete(ink, fractions: c.boxes.map { CropRect($0[0], $0[1], $0[2], $0[3]) })
        #expect(result.tiled == c.expect.tiled)
        #expect(result.crops.count == c.expect.crops.count)
        for (crop, want) in zip(result.crops, c.expect.crops) {
            if let want {
                let got = try #require(crop)
                for (a, b) in zip([got.x0, got.y0, got.x1, got.y1], want) { #expect(abs(a - b) <= Self.fixtures.tolerancePixels, "\(name): \(got) vs \(want)") }
            } else { #expect(crop == nil, "\(name): expected the whole figure") }
        }
        #expect(abs((result.coverage ?? -1) - c.expect.inkCoverage) < 1e-5)
        #expect(FigureCropCompletion.padding(width: c.width, height: c.height) == c.expect.padding)
    }

    @Test func theAppDecodeMatchesTheRawPixels() throws {
        let raw = try Self.ink("letters-shared-legend.png"), drawn = try #require(FigureInk(image: try Self.image("letters-shared-legend.png")))
        #expect(drawn.inkPixels == raw.inkPixels && drawn.components == raw.components)
    }

    @Test func aCardPresentsItsCropOnBackgroundPadding() throws {
        let shown = PresentedCrop(ink: 1000, 400, crop: CropRect(100, 40, 500, 360))
        #expect(shown.region == CropRect(0.1, 0.1, 0.5, 0.9) && !shown.whole)
        #expect(shown.padX == 8.0 / 1000 && shown.padY == 8.0 / 400)
        #expect(PresentedCrop(ink: 1000, 400, crop: nil).whole)
        #expect(FigureCropCompletion.padding(width: 2000, height: 1200) == 24)
        // Cut from an image twice the size: the region rounds outward, the padding scales and is white.
        let image = try Self.image("dpo-figure-2.png")
        let padded = try #require(PresentedCrop(ink: image.width, image.height, crop: CropRect(8, 8, 672, 492)).image(from: image))
        let p = FigureCropCompletion.padding(width: image.width, height: image.height)
        #expect(padded.width == 664 + 2 * p && padded.height == 484 + 2 * p)
        let cornerImage = try #require(padded.cropping(to: CGRect(x: 0, y: 0, width: p, height: p)))
        let corner = try #require(FigureInk(image: cornerImage))
        #expect(corner.inkPixels == 0, "the padding is background")
        #expect(FigureWalkthrough.Box(x: 0.25, y: 0.5, w: 0.5, h: 0.25).fractions == CropRect(0.25, 0.5, 0.75, 0.75))
    }
}

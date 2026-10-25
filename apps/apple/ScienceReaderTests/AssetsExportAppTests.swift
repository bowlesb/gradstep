import CoreGraphics
import Foundation
import ImageIO
import Testing
import ScienceReaderCore
@testable import ScienceReader

/// Download your assets (owner, TestFlight 92: "Does this mean we don't sync picture content on our servers?"): a figure
/// breakdown's parts are cut on the device from its own copy of the paper, as the chat shows them, and go into the zip;
/// without the figure's image there is nothing to cut.
struct AssetsExportAppTests {
    private static func size(_ png: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    @Test func eachPartIsCutFromThePapersFigure() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .authored)
        let figure = try #require(bundle.index.figures.first)
        let path = try #require(figure.assetPaths.first)
        let parts = [ChatFigureParts.Part(label: "Left half", box: [0, 0, 0.5, 1], note: "The question."),
                     ChatFigureParts.Part(label: "Right half", box: [0.5, 0, 1, 1], note: "The answer.")]
        let stored = StoredFigureParts(manifestSHA256: bundle.manifestSHA256, blockID: figure.blockID, assetPath: path, paragraph: 4,
                                       title: "Figure 1", parts: parts)
        let pictures = await AssetsExporter.figurePartPictures(stored, bundle: bundle)
        #expect(pictures.count == 2)
        for picture in pictures {
            let png = try #require(picture)
            #expect(png.prefix(4) == Data([0x89, 0x50, 0x4e, 0x47]), "PNG")
            let (width, height) = try #require(Self.size(png))
            #expect(width > 8 && height > 8)
        }
        // The input the zip is built from names each part's picture, keyed by the breakdown and the part's number.
        let input = AssetsExport.Input(exportedAt: 1_792_929_600_000, breakdowns: [AssetsExport.Breakdown(id: "b", title: "Figure 1",
            parts: parts.map { AssetsExport.BreakdownPart(label: $0.label, note: $0.note, image: "image/png") })])
        let images = Dictionary(uniqueKeysWithValues: pictures.enumerated().compactMap { index, data in data.map { ("b/\(index + 1)", $0) } })
        let result = AssetsExport.build(input, images: images)
        #expect(result.files.map(\.path).contains("Gradstep export 2026-10-25/breakdowns/images/b-1.png"))
        #expect(result.files.map(\.path).contains("Gradstep export 2026-10-25/breakdowns/images/b-2.png"))
    }

    @Test func nothingIsCutWithoutTheFiguresImage() async throws {
        let bundle = try OfflineReaderFixture.reader(variant: .authored)
        let stored = StoredFigureParts(manifestSHA256: bundle.manifestSHA256, blockID: "missing", assetPath: "assets/not-in-the-bundle.png", paragraph: 1,
                                       title: "Gone", parts: [ChatFigureParts.Part(label: "A", box: [0, 0, 0.5, 0.5], note: "n")])
        #expect(await AssetsExporter.figurePartPictures(stored, bundle: bundle) == [nil])
    }
}

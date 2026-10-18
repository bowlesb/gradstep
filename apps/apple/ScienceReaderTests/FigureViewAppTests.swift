import CoreGraphics
import Foundation
import ScienceReaderCore
import Testing
@testable import ScienceReader

/// The figure view on the device (docs/architecture/FIGURE_VIEW.md): the image a walkthrough sends is the one chat
/// sends for the same figure, and a table the page draws is drawn here as an image the model can read.
@MainActor @Suite struct FigureViewAppTests {
    private func bundle() throws -> VerifiedReaderBundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try DeviceReaderPackage.decode(Data(contentsOf: root.appendingPathComponent("tests/fixtures/reader-arxiv/package.json")))
    }

    @Test func aFiguresImageIsTheOneChatSends() throws {
        let bundle = try bundle()
        let figure = try #require(bundle.index.figures.first)
        let own = try #require(ChatFigureFinder.image(for: figure, bundle: bundle))
        let chat = try #require(ChatFigureFinder.images(question: "What does Figure 1 show?", selection: nil, bundle: bundle).first)
        #expect(own == chat)
        #expect(own.id == "F1" && own.paragraph == 6)
    }

    /// Owner, build 62: AI Explainer asks for the walkthrough; a figure switched to from the explainer's heading shows what
    /// is kept and waits for AI Explainer (nothing is asked unasked).
    @Test func aFigureSwitchedToWaitsForAIExplainer() async throws {
        let bundle = try bundle()
        let figure = try #require(bundle.index.figures.first)
        let model = ReaderModel(configuration: nil)
        let context = FigureViewContext(paperID: UUID(), bundle: bundle, figureID: figure.id, label: "Figure 1", caption: figure.caption,
                                        paragraph: 6, assetPaths: figure.assetPaths, localContext: nil)
        let switched = FigureExplainSession(context: context, model: model)
        await switched.start(requesting: false)
        #expect(switched.walkthrough.state == .idle, "nothing asked")
        let asked = FigureExplainSession(context: context, model: model)
        await asked.start()
        #expect(asked.walkthrough.state != .idle, "AI Explainer asks (here: sign in first, no account)")
    }

    @Test func aTableIsDrawnAsTheModelReadsIt() async throws {
        let bundle = try bundle()
        let data = try #require(bundle.data(for: bundle.manifest.entrypoint))
        let page = try #require(String(data: data, encoding: .utf8))
        let markup = try #require(EquationMarkup.block(in: page, blockID: "b-6b536bf95fcc-7"))
        let image = try #require(await TableDrawing.image(bundle: bundle, markup: markup))
        #expect(image.width >= 40 && image.height >= 20, "\(image.width)×\(image.height)")
        // Ink on white: the table's text and rules were drawn.
        let width = 64, height = 64
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        let dark = (0..<(width * height)).filter { Int(pixels[$0 * 4]) + Int(pixels[$0 * 4 + 1]) + Int(pixels[$0 * 4 + 2]) < 450 }.count
        #expect(dark > 8, "the table is drawn, not blank (\(dark) dark pixels)")
        let prepared = try #require(ChatFigureFinder.prepare(image))
        #expect(prepared.width <= ChatFigureFinder.maximumSide && prepared.height <= ChatFigureFinder.maximumSide)
    }

    @Test func reopeningAnExplainedFigureUsesTheSavedAnswerWithoutRequestingAI() async throws {
        let bundle = try bundle(), figure = try #require(bundle.index.figures.first)
        let model = ReaderModel(configuration: nil)
        let context = FigureViewContext(paperID: UUID(), bundle: bundle, figureID: figure.id, label: "Figure 1", caption: figure.caption,
            paragraph: 6, assetPaths: figure.assetPaths, localContext: nil)
        #expect(!FigureExplainSession.hasSavedAnswer(context: context, model: model))
        model.keepFigureAnswer(FigureAnswer(text: "The saved explanation", model: "gemini-flash"), for:
            FigureResultKey(manifestSHA256: bundle.manifestSHA256, figureID: figure.id, action: .figure, profile: model.equationProfile))
        #expect(FigureExplainSession.hasSavedAnswer(context: context, model: model))
        let reopened = FigureExplainSession(context: context, model: model)
        await reopened.start(requesting: false)
        #expect(reopened.walkthrough.state == .done)
        #expect(reopened.walkthrough.text == "The saved explanation")
        #expect(!reopened.asksConsent)
    }
}

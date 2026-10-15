import CoreGraphics
import SwiftUI
import Foundation
import Testing
import ScienceReaderCore
@testable import ScienceReader

/// Visual answers (docs/proposals/CHAT_TOOLS.md): an HTML fragment the server sanitized, kept like a diagram
/// (format html-v1) and shown in a frame with no scripts; the request names the reader's setting.
struct ChatVisualTests {
    @Test func aVisualIsADiagramOfTheHTMLFormat() {
        let visual = ChatDiagram(title: " Loop ", source: "<ol><li>a</li></ol>", messageID: nil, format: ChatDiagram.htmlFormat)
        #expect(visual?.isHTML == true && visual?.title == "Loop")
        #expect(ChatDiagram(title: "x", source: "<p>y</p>", messageID: nil, format: "svg-v9") == nil, "unknown formats are refused")
        #expect(ChatDiagram(title: "x", source: String(repeating: "y", count: 24_001), messageID: nil, format: ChatDiagram.htmlFormat) == nil)
        #expect(ChatDiagram(title: "x", source: String(repeating: "y", count: 16_001), messageID: nil) == nil, "Mermaid keeps its own bound")
        let encoded = visual!.encodedText()
        #expect(encoded.contains("\"format\":\"html-v1\""))
        #expect(ChatDiagram.decode(encoded)?.isHTML == true)
        #expect(ChatDiagram.decode("{\"format\":\"mermaid-v1\",\"source\":\"graph TD; a-->b\",\"title\":\"T\"}")?.isHTML == false)
    }

    @Test func theRequestNamesTheSetting() throws {
        let turns = [ChatTurnInput(role: .user, text: "How does the loop flow?")]
        let on = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: turns, selection: nil)
        let off = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: turns, selection: nil, visualAnswers: false)
        let onBody = String(decoding: try on.encoded(), as: UTF8.self), offBody = String(decoding: try off.encoded(), as: UTF8.self)
        #expect(onBody.contains("\"capabilities\":[\"visual_answers\"]"))
        #expect(offBody.contains("\"capabilities\":[]"), "an empty list tells the server the reader turned visuals off")
        #expect(ChatGenerationRequest.capabilities(action: .ingest, visualAnswers: true) == ["web_import", "visual_answers"])
    }

    @Test func theVisualPageHasNoScriptsAndNoNetwork() {
        let page = HTMLVisualWebView.document("<p>hi</p>", dark: true, fontSize: 17)
        #expect(page.contains("default-src 'none'; style-src 'unsafe-inline'"))
        #expect(!page.contains("<script") && page.contains("<body><p>hi</p></body>"))
        #expect(page.contains("color-scheme:dark"))
    }
}

/// Figures in chat (consent v3): the figure a question names is found by its caption, prepared within the provider's
/// resolution, sent with the question, and the answer's parts are kept as `figure-parts-v1` and cropped on the device.
struct ChatFigureTests {
    /// A real paper's bundle as the device compiles it (`node scripts/reader-device-compile.mjs --ids=<id> --out=<dir>`),
    /// when this Mac has one: TEST_RUNNER_FIGURE_BUNDLE=<dir>/<id>.
    @Test func aRealPapersNamedFigureIsFoundAndPrepared() throws {
        guard let path = ProcessInfo.processInfo.environment["FIGURE_BUNDLE"],
              let sha = try? String(contentsOfFile: path + "/manifest.sha256", encoding: .utf8) else { return }
        let bundle = try ReaderBundleLoader.load(directory: URL(fileURLWithPath: path), expectedSHA256: sha.trimmingCharacters(in: .whitespacesAndNewlines))
        for question in ["What does Figure 4 show? Walk me through each part.", "Explain figure 2 in parts", "fig. 3 please", "Figure 1 please"] {
            let images = ChatFigureFinder.images(question: question, selection: nil, bundle: bundle)
            print("figure finder: \(question) -> \(images.map { "\($0.id) ¶\($0.paragraph) \($0.width)x\($0.height) \($0.data.count) chars \($0.caption.prefix(30))" })")
            #expect(images.count == 1, "\(question)")
        }
    }

    @Test func mentionsAreFoundInOrder() {
        let found = ChatFigureFinder.mentions(in: "Compare Fig. 3 with Figure 2 and Table 1; and figure 3 again")
        #expect(found.map { "\($0.kind) \($0.number)" } == ["figure 3", "figure 2", "table 1"])
    }

    @Test func theNamedFigureIsSentPreparedAndTheRequestNamesConsentV3() throws {
        let bundle = try OfflineReaderFixture.reader(variant: .authored)
        let images = ChatFigureFinder.images(question: "What does Figure 1 show?", selection: nil, bundle: bundle)
        let figure = try #require(bundle.index.figures.first)
        #expect(figure.caption.hasPrefix("Figure 1"))
        do {
            let image = try #require(images.first)
            #expect(image.id == "F1" && image.mediaType == "image/jpeg" && image.blockID == figure.blockID && image.assetPath == figure.assetPaths.first)
            #expect(image.width <= 1_568 && image.height <= 1_568 && Double(image.width * image.height) <= 1_150_000 * 1.01)
            #expect(Data(base64Encoded: image.data)?.prefix(2) == Data([0xff, 0xd8]), "JPEG")
            let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(), transcript: [ChatTurnInput(role: .user, text: "What does Figure 1 show?")],
                                                         selection: nil, figures: images)
            let body = String(decoding: try request.encoded(), as: UTF8.self)
            #expect(body.contains("\"consent_version\":\"cloud-ai-v3\"") && body.contains("\"figures\":[{") && body.contains("\"id\":\"F1\""))
        }
        #expect(ChatFigureFinder.images(question: "What does Figure 9 show?", selection: nil, bundle: bundle).isEmpty, "no such figure")
        let general = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: [ChatTurnInput(role: .user, text: "q")], selection: nil, figures: images)
        #expect(general.figures.isEmpty, "never in a general chat")
    }

    @Test func partsAreKeptAndCroppedByTheirBoxes() throws {
        let parts = ChatFigureParts(figure: "F1", paragraph: 4, title: "Pipeline", parts: [.init(label: "Left", box: [0, 0, 0.5, 1], note: "The encoder.")])
        #expect(parts.isValid)
        #expect(!ChatFigureParts(figure: "F1", paragraph: 4, title: "x", parts: [.init(label: "a", box: [0.5, 0.5, 0.51, 1], note: "n")]).isValid, "too thin")
        let stored = StoredFigureParts(manifestSHA256: String(repeating: "a", count: 64), blockID: "b-1", assetPath: "assets/x.png", paragraph: 4,
                                       title: "Pipeline", parts: parts.parts)
        let diagram = try #require(ChatDiagram(title: "Pipeline", source: stored.encodedText(), messageID: nil, format: ChatDiagram.figurePartsFormat))
        #expect(diagram.isFigureParts && ChatDiagram.decode(diagram.encodedText())?.isFigureParts == true)
        #expect(ChatDiagram(title: "x", source: "{}", messageID: nil, format: ChatDiagram.figurePartsFormat) == nil, "only well-formed parts")
        let context = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let crop = try #require(FigurePartsView.crop(image, [0, 0, 0.5, 1]))
        #expect(crop.width == 100 && crop.height == 100)
    }

    @Test func theStreamCarriesParts() throws {
        var parser = ChatSSEParser()
        let events = try parser.consume(Data("event: figure_parts\ndata: {\"figure\":\"F1\",\"paragraph\":4,\"title\":\"P\",\"parts\":[{\"label\":\"a\",\"box\":[0,0,0.5,1],\"note\":\"n\"}]}\n\nevent: figure_parts\ndata: {\"figure\":\"F1\"}\n\n".utf8))
        #expect(events.count == 1)
        if case .figureParts(let parts) = events.first { #expect(parts.parts.first?.label == "a") } else { Issue.record("no parts") }
    }
}

/// A look at figure parts as the reader sees them: DPO's Figure 1 with the parts a live answer gave (2026-10-15),
/// rendered to an image for review (skipped where the DPO capture is not on this machine).
@MainActor
struct FigurePartsRenderingTests {
    @Test func dpoFigureOneRenders() throws {
        let path = "/Users/benbowlwes/science-reader/.artifacts/bundles/ecbc0a04588f/assets/825ee442fd526b3a11f86b5847f507f51e3d9921717bc809c01c532d8a125051.jpg"
        guard let data = FileManager.default.contents(atPath: path), let image = ChatFigureFinder.image(data) else { return }
        let parts: [ChatFigureParts.Part] = [
            .init(label: "RLHF: preference data", box: [0.00, 0.15, 0.27, 0.80], note: "A prompt with a preferred and a dispreferred answer."),
            .init(label: "RLHF: reward model", box: [0.25, 0.20, 0.47, 0.75], note: "Fit to the preferences by maximum likelihood."),
            .init(label: "RLHF: RL loop", box: [0.40, 0.20, 0.72, 0.95], note: "The policy samples; the reward model scores; repeat."),
            .init(label: "DPO: preference data", box: [0.62, 0.15, 0.80, 0.80], note: "The same pairs."),
            .init(label: "DPO: final LM", box: [0.76, 0.15, 1.00, 0.80], note: "Trained directly, no reward model or RL."),
        ]
        let stored = StoredFigureParts(manifestSHA256: String(repeating: "0", count: 64), blockID: "b", assetPath: "x", paragraph: 7, title: "RLHF vs. DPO", parts: parts)
        // The image renderer draws no scroll views: their contents are rendered directly.
        let view = VStack(alignment: .leading, spacing: 16) {
            FigurePartsThumbnails(stored: stored, image: image, fontSize: 17).fixedSize()
            FigurePartsContent(stored: stored, image: image)
        }.padding(16).frame(width: 760, alignment: .leading).clipped().background(Color.white)
        let renderer = ImageRenderer(content: view); renderer.scale = 2; renderer.proposedSize = ProposedViewSize(width: 760, height: nil)
        let png = try #require(renderer.uiImage?.pngData())
        #expect(png.count > 10_000)
        try? png.write(to: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-benbowlwes-science-reader/5a96b04d-7ac1-43e8-a0d4-69cc27e75f80/scratchpad/figure-parts-render.png"))
    }
}

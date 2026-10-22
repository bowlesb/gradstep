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

    /// C9: the figure view's single, off-main decode shows the composed figure and sends exactly the image chat sends.
    @Test func theOnceDecodedFigureSendsWhatChatSends() async throws {
        let bundle = try bundle()
        for figure in bundle.index.figures {
            let prepared = await Task.detached { ChatFigureFinder.prepared(figure, bundle: bundle) }.value
            #expect(prepared.sent == ChatFigureFinder.image(for: figure, bundle: bundle))
            let paths = Array(figure.assetPaths.prefix(ChatFigureFinder.maximumPanels))
            let panels = paths.compactMap { bundle.data(for: $0).flatMap(ChatFigureFinder.image) }
            let shown = panels.count == paths.count ? ChatFigureFinder.composite(panels) : nil
            #expect(prepared.image?.width == shown?.width && prepared.image?.height == shown?.height)
        }
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
        #expect(reopened.progress == nil, "a kept answer has no progress bar")
    }

    #if DEBUG && (targetEnvironment(simulator) || targetEnvironment(macCatalyst))
    /// The journeys' fixture streams the walkthrough as the server of 2026-10-22 does (progress with characters and the
    /// announced count, the summary, each part in order, then the final `figure`), so the app's progress and progressive
    /// walkthrough are what a reader sees from the live server.
    @Test func theFixtureStreamsTheWalkthroughAsTheServerDoes() async throws {
        let walkthrough = ChatFixtureTransport.figureWalkthrough
        let events = AsyncThrowingStream<ChatStreamEvent, Error> { continuation in
            Task {
                try await ChatFixtureTransport.streamWalkthrough(walkthrough, continuation)
                continuation.yield(.figure(walkthrough)); continuation.finish()
            }
        }
        var tracker = FigureProgress.Tracker(expected: nil)
        tracker.opened()
        var labels = [tracker.state().label], values: [Double] = [], soFar: [Int] = [], characters: [Int] = []
        for try await event in events {
            if case .figureProgress(let step) = event, let count = step.characters { characters.append(count) }
            if tracker.apply(event), let shown = tracker.walkthroughSoFar { soFar.append(shown.sections.count) }
            let state = tracker.state()
            if labels.last != state.label { labels.append(state.label) }
            if let value = state.value { values.append(value) }
        }
        #expect(labels == ["Reading the figure…", "Writing the summary…", "Writing part 1 of 3…", "Writing part 2 of 3…", "Writing part 3 of 3…", "Writing part 4…"])
        #expect(soFar == [0, 1, 2, 3], "the summary, then each part once, in order")
        #expect(characters == characters.sorted() && characters.count == 8, "characters grow")
        #expect(values == values.sorted() && !values.isEmpty && values.allSatisfy { $0 < 1 }, "the bar only moves forward")
        #expect(tracker.final == walkthrough && tracker.walkthroughSoFar == walkthrough)
    }
    #endif
}

/// The figures activity's default (owner, 2026-10-22: "Let's try Gemini instead of Sonnet for Figures then"; Sonnet earlier
/// that day): the server's `default_figures`, else Gemini Flash when offered, never the general chat default; a saved
/// figures choice is kept, except the short-lived Sonnet default, forgotten once.
@MainActor @Suite(.serialized) struct FiguresDefaultTests {
    private let sonnet = ChatProfileChoice(model: .sonnet, effort: .low, length: .standard)
    private let deepseek = ChatProfileChoice(model: .deepseek, effort: .low, length: .standard)
    private let gemini = ChatProfileChoice(model: .gemini, effort: .medium, length: .standard)
    private func table(_ offered: [ChatProfileChoice], default choice: ChatProfileChoice, figures: ChatProfileChoice? = nil) -> ChatProfileTable {
        ChatProfileTable(version: ChatProfileTable.supportedVersion, defaultChoice: choice,
                         estimates: Dictionary(uniqueKeysWithValues: offered.map { ($0, .init(low: 1, high: 2, max: 3)) }), figuresDefault: figures)
    }
    private func scratch() -> UserDefaults {
        let name = "figures-default-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func theFiguresDefaultIsGeminiNotTheChatDefault() {
        // The server's default_figures when offered.
        #expect(ReaderModel.figuresDefault(table: table([sonnet, gemini, deepseek], default: sonnet, figures: gemini), chatDefault: deepseek) == gemini)
        // A table without default_figures: Gemini when offered, not the general default (DeepSeek here).
        #expect(ReaderModel.figuresDefault(table: table([sonnet, gemini, deepseek], default: deepseek), chatDefault: deepseek) == gemini)
        // Before the table loads: Gemini; a table without Gemini: the chat default.
        #expect(ReaderModel.figuresDefault(table: nil, chatDefault: deepseek) == gemini)
        #expect(ReaderModel.figuresDefault(table: table([deepseek, sonnet], default: sonnet), chatDefault: deepseek) == deepseek)
    }

    @Test func aNewReaderGetsTheFiguresDefaultAndOtherActivitiesAreUnchanged() {
        let defaults = UserDefaults.standard, keys = [ReaderModel.scenarioProfilesKey, "chat.defaultProfile"]
        let prior = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) } }
        defaults.removeObject(forKey: ReaderModel.scenarioProfilesKey)
        let model = ReaderModel(configuration: nil)
        model.chatDefaultProfile = deepseek
        #expect(model.profileDefault(for: .figures) == gemini, "the general default (DeepSeek) is no longer inherited")
        #expect(model.profileDefault(for: .paper) == deepseek && model.profileDefault(for: .equations) == deepseek, "other activities unchanged")
        model.setProfileDefault(deepseek, for: .figures)
        #expect(model.profileDefault(for: .figures) == deepseek, "an explicit figures choice is kept")
        model.resetAIDefault(for: .figures)
        #expect(model.profileDefault(for: .figures) == gemini, "reset: the figures default")
    }

    @Test func theShortLivedSonnetDefaultIsForgottenOnceAndOtherChoicesKept() {
        let defaults = scratch()
        defaults.set(["figures": "sonnet-low-standard", "paper": "sonnet-low-standard"], forKey: ReaderModel.scenarioProfilesKey)
        let migrated = ReaderModel.storedScenarioProfiles(defaults)
        #expect(migrated["figures"] == nil && migrated["paper"] == "sonnet-low-standard", "only figures, only that value")
        #expect(defaults.dictionary(forKey: ReaderModel.scenarioProfilesKey) as? [String: String] == ["paper": "sonnet-low-standard"])
        // Once: a later explicit Sonnet choice for figures sticks.
        defaults.set(["figures": "sonnet-low-standard"], forKey: ReaderModel.scenarioProfilesKey)
        #expect(ReaderModel.storedScenarioProfiles(defaults)["figures"] == "sonnet-low-standard")
        // A saved DeepSeek or Gemini choice is never touched.
        for kept in [deepseek.id, gemini.id] {
            let other = scratch()
            other.set(["figures": kept], forKey: ReaderModel.scenarioProfilesKey)
            #expect(ReaderModel.storedScenarioProfiles(other)["figures"] == kept)
            #expect(other.bool(forKey: ReaderModel.figuresDefaultMigrationKey))
        }
    }
}

import CoreGraphics
import Foundation
import ScienceReaderCore
import UIKit
import WebKit

// The figure view (owner, build 59; docs/architecture/FIGURE_VIEW.md): a walkthrough of one figure on request, part by
// part, a part's crop where the walkthrough points at a small detail, and any part again more simply. Both requests are
// chat actions on the chat's own profile, capabilities and paper, so they read the chat's cached paper.

/// One figure (or table) of a paper on this device, resolved for its view.
struct FigureViewContext {
    let paperID: UUID
    let bundle: VerifiedReaderBundle
    /// The figure's id in the bundle (its block), or a table's block.
    let figureID: String
    /// "Figure 3", "Table 2"; "Figure" or "Table" when the caption names no number.
    let label: String
    /// The whole caption, equations as `\( … \)`.
    let caption: String
    /// The figure's `[¶N]` block.
    let paragraph: Int?
    /// The figure's images; empty for a table the page draws (its image is drawn on this device).
    let assetPaths: [String]
    /// The paper numbered on this device; nil when it isn't an arXiv paper here (no walkthrough then).
    let localContext: LocalPaperChatContext?
    var isDrawnTable: Bool { assetPaths.isEmpty }
}

/// What a figure page or its walkthrough asks for as it closes, applied once the sheet has gone.
enum FigureViewOutcome {
    /// A `[¶N]` the walkthrough cites, or the paragraph a part cites (with Back).
    case paragraph(paperID: UUID, marker: Int)
    /// The figure itself in the paper (with Back).
    case figure(paperID: UUID, figureID: String)
    /// A new chat about the paper with the figure (or one part's text) as the passage; nothing is sent.
    case askInChat(FigureViewContext, part: FigureWalkthrough.Section?)
    /// Signed out: sign in, from the app (a sheet over this one can't).
    case signIn
    case continueChat
}

/// The walkthrough and its parts explained more simply, each kept on the device.
@MainActor @Observable final class FigureExplainSession {
    enum State: Equatable {
        case idle, loading, done
        case failed(String, retryable: Bool)
        /// The chat's cloud consent isn't given yet on this device.
        case needsConsent
        case needsSignIn
        /// The paper isn't an arXiv paper on this device, or its figure couldn't be prepared: no walkthrough.
        case unavailable
    }
    struct Part: Equatable {
        var state: State = .idle
        var walkthrough: FigureWalkthrough?
        /// The words, when no walkthrough came (or a part again, more simply).
        var text = ""
        /// Ended early or with nothing to show, and the reader paid nothing (CHAT.md "When an answer stops early").
        var notCharged = false
        var answeredModel: String?
    }

    private(set) var walkthrough = Part()
    /// The walkthrough's progress bar while it is asked for and written (FigureProgress; FIGURE_VIEW.md "Progress"): a
    /// stage label always, a value while the number of parts is known. Nil when nothing is being asked.
    private(set) var progress: FigureProgress.State?
    /// How many of a streamed walkthrough's parts show: a part shows once its card has been framed (off the main actor, a
    /// moment), so no card shows and then changes size. Every part shows once the walkthrough is no longer loading.
    private(set) var shownSections = 0
    @ObservationIgnored private var tracker = FigureProgress.Tracker(expected: nil)
    /// Whether the walkthrough held now is the final one (`figure`), not the parts streamed so far: the framing's count
    /// check needs the final number of parts. `framedFinal`: what the last framing used.
    @ObservationIgnored private var walkthroughFinal = true
    @ObservationIgnored private var framedFinal = true
    /// A part explained more simply, by the part's index in the walkthrough.
    private(set) var simpler: [Int: Part] = [:]
    /// The figure as the request sends it (its panels composed, or the table drawn here), which crops are cut from.
    private(set) var image: CGImage?
    /// Each card's framing (FIGURE_VIEW.md "Parts as viewports"): completed on the image the request carried, then framed
    /// by confidence as a viewport into `image` (tight, loose and outlined, or the whole figure outlined); the caption's
    /// panel letters cap the parts. By section index; empty until worked out (off the main actor), so no card shows and
    /// then changes size.
    private(set) var framed: [Int: FramedPart] = [:]
    /// The card's key in the local framing record (FigureFramingRecorder); nil when the paper isn't an arXiv paper here.
    func recordKey(_ surface: FigureFramingRecord.Surface, _ index: Int) -> String? {
        context.localContext == nil ? nil : "\(context.bundle.manifestSHA256)|\(context.figureID)|\(surface.rawValue)|\(index)"
    }
    /// The share of the figure's ink the walkthrough's crops show (nil without crops, or until worked out).
    private(set) var inkCoverage: Double?
    /// The figure's own sub-figures in the image the request carries (FIGURE_VIEW.md "Structure first"): described to the
    /// model after the caption, and the walkthrough's parts that show one are framed as it, exactly.
    private(set) var structure: FigureStructure?
    @ObservationIgnored private var ink: FigureInk?
    @ObservationIgnored private var inkReady = false
    @ObservationIgnored private var cropGeneration = 0
    let context: FigureViewContext
    let localModelID: String?
    @ObservationIgnored private weak var model: ReaderModel?
    @ObservationIgnored private var sent: ChatFigureImage?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var awaitingConsent: (() -> Void)?
    var asksConsent: Bool { awaitingConsent != nil }

    init(context: FigureViewContext, model: ReaderModel) {
        self.context = context; self.model = model; self.localModelID = model.localAIModelID
    }

    static func hasSavedAnswer(context: FigureViewContext, model: ReaderModel) -> Bool {
        model.figureAnswer(FigureResultKey(manifestSHA256: context.bundle.manifestSHA256, figureID: context.figureID,
            action: .figure, profile: model.equationProfile, localModel: model.localAI.identity(model.localAIModelID))) != nil
    }

    /// Shows what this device kept; asks for the walkthrough when nothing is kept and `requesting` (AI Explainer was chosen
    /// to get here; a figure switched to from the explainer's heading waits for AI Explainer).
    func start(requesting: Bool = true) async {
        guard let model else { return }
        let profile = model.equationProfile
        if let kept = model.figureAnswer(key(.figure, part: nil, profile: profile)) {
            walkthrough = Part(state: .done, walkthrough: kept.walkthrough, text: kept.text, answeredModel: kept.model)
            for (index, section) in (kept.walkthrough?.sections ?? []).enumerated() {
                if let more = model.figureAnswer(key(.figureSimpler, part: section.text, profile: profile)) { simpler[index] = Part(state: .done, text: more.text) }
            }
        }
        await prepareImage()
        await prepareInk()
        if requesting, walkthrough.state == .idle { explain() }
    }

    func explain() { if walkthrough.state != .loading, walkthrough.state != .done { run(.figure, part: nil) } }
    func retry() { run(.figure, part: nil) }
    /// "Explain more simply" (owner: "ask to back up a bit"): that part again, inline under it.
    func simplify(_ index: Int) {
        guard let section = walkthrough.walkthrough?.sections[safe: index], simpler[index]?.state != .loading, simpler[index]?.state != .done else { return }
        run(.figureSimpler, part: (index, section))
    }
    func retrySimpler(_ index: Int) {
        guard let section = walkthrough.walkthrough?.sections[safe: index] else { return }
        run(.figureSimpler, part: (index, section))
    }

    func acceptConsent() {
        guard let model, let resume = awaitingConsent else { return }
        awaitingConsent = nil
        guard model.acceptCloudConsent() else {
            walkthrough = Part(state: .failed("Your choice couldn’t be saved. Try again.", retryable: true)); return
        }
        resume()
    }

    func declineConsent() {
        guard awaitingConsent != nil else { return }
        awaitingConsent = nil
        if walkthrough.state == .needsConsent { walkthrough = Part(state: .failed("Explanations use the chat’s AI. Try again to choose.", retryable: true)) }
        for (index, part) in simpler where part.state == .needsConsent { simpler[index] = nil }
    }

    func stop() { for task in tasks.values { task.cancel() }; tasks = [:] }

    /// The figure's own image, composed as chat composes it, or a table drawn by the page's own stylesheet.
    private func prepareImage() async {
        guard image == nil else { return }
        let bundle = context.bundle
        if context.isDrawnTable {
            guard let html = bundle.data(for: bundle.manifest.entrypoint).flatMap({ String(data: $0, encoding: .utf8) }),
                  let markup = EquationMarkup.block(in: html, blockID: context.figureID),
                  let drawn = await TableDrawing.image(bundle: bundle, markup: markup),
                  let prepared = ChatFigureFinder.prepare(drawn), let paragraph = context.paragraph else { return }
            image = drawn
            sent = ChatFigureImage(id: "F1", paragraph: paragraph, caption: context.caption, mediaType: "image/jpeg", data: prepared.data.base64EncodedString(),
                                   width: prepared.width, height: prepared.height, blockID: context.figureID, assetPath: "")
        } else {
            guard let figure = bundle.index.figures.first(where: { $0.id == context.figureID }) else { return }
            // Up to four full-size panels and a composite of up to 40 MP: decoded once, off the main actor.
            let prepared = await Task.detached(priority: .userInitiated) { ChatFigureFinder.prepared(figure, bundle: bundle) }.value
            image = prepared.image; sent = prepared.sent; structure = prepared.structure
        }
    }

    /// The ink of the image the request carries, decoded once off the main actor (FigureCropCompletion).
    private func prepareInk() async {
        guard !inkReady else { return }
        if let encoded = sent.flatMap({ Data(base64Encoded: $0.data) }) {
            ink = await Task.detached(priority: .userInitiated) { PresentedCrop.ink(of: encoded) }.value
        }
        inkReady = true
        refreshCrops()
    }

    /// Frames the walkthrough's cards together, off the main actor.
    private func refreshCrops() {
        let sections = walkthrough.walkthrough?.sections ?? []
        let countCheck = walkthroughFinal
        framedFinal = countCheck
        guard inkReady, let image else { shownSections = sections.count; return }
        // Structure first: a section that shows one of the figure's own sub-figures (by letter, a box on its band, or in
        // order) is that sub-figure, exactly; the others as the AI boxed them. When the parts number neither the caption's
        // panels nor the sub-figures, the AI's own show the whole figure (FigureFraming).
        let structure = self.structure
        let matched = FigureStructure.match(sections.map { FigureStructure.Section(label: $0.label, title: $0.title, kind: $0.cardKind.rawValue, box: $0.box?.fractions) }, structure)
        let boxed = sections.indices.filter { sections[$0].cardKind == .panel && (sections[$0].box != nil || matched[$0] != nil) }
        let exact = boxed.map { i in matched[i].flatMap { structure?.parts[$0].rect } }
        let boxes = boxed.enumerated().map { k, i in exact[k] ?? sections[i].box!.fractions }, labels = boxed.map { sections[$0].label.isEmpty ? sections[$0].title : sections[$0].label }
        let structureParts = structure?.parts.count ?? 0
        let ink = self.ink, caption = context.caption, width = image.width, height = image.height
        let fallback = ink == nil ? walkthrough.walkthrough?.cropCoverage(width: image.width, height: image.height) : nil
        cropGeneration += 1
        let generation = cropGeneration
        Task { [weak self] in
            struct Made: Sendable { let framed: [Int: FramedPart]; let coverage: Double? }
            let made = await Task.detached(priority: .userInitiated) { () -> Made in
                let all = FigureFraming.frame(ink, width: width, height: height, boxes: boxes, caption: caption, labels: labels, exact: exact,
                                              structureParts: structureParts, countCheck: countCheck)
                var framed: [Int: FramedPart] = [:]
                for (k, index) in boxed.enumerated() where k < all.parts.count { framed[index] = all.parts[k] }
                return Made(framed: framed, coverage: all.coverage)
            }.value
            guard let self, generation == cropGeneration else { return }
            // Unchanged framings are left alone (no card is redrawn needlessly as later parts arrive).
            if framed != made.framed { framed = made.framed }
            inkCoverage = made.coverage ?? fallback
            shownSections = sections.count
            record(boxed: boxed, sections: sections, boxes: boxes)
        }
    }

    /// The local framing record (FigureFramingRecorder): arXiv figures only, geometry only, in memory, never sent.
    private func record(boxed: [Int], sections: [FigureWalkthrough.Section], boxes: [CropRect]) {
        guard let local = context.localContext else { return }
        let figure = ArxivFigure(sourceID: local.sourceID, revision: local.revision, figure: context.label)
        for (k, index) in boxed.enumerated() {
            guard let part = framed[index], let key = recordKey(.walkthrough, index) else { continue }
            FigureFramingRecorder.shared.shown(key, FigureFramingRecord(figure: figure, surface: .walkthrough, part: k, parts: boxed.count, level: part.level,
                                                                        box: sections[index].box?.fractions ?? boxes[k], region: part.region, frame: part.frame))
        }
    }

    private func run(_ action: ChatAction, part: (index: Int, section: FigureWalkthrough.Section)?) {
        guard let model else { return }
        func set(_ value: Part) { store(value, index: part?.index) }
        guard model.isSignedIn else { set(Part(state: .needsSignIn)); return }
        guard localModelID != nil || context.localContext != nil else { set(Part(state: .unavailable)); return }
        guard localModelID != nil || model.hasCloudConsent else {
            awaitingConsent = { [weak self] in self?.run(action, part: part) }
            set(Part(state: .needsConsent)); return
        }
        guard localModelID != nil || model.chatProfileTable != nil else { set(Part(state: .failed("Cloud models haven’t loaded. Choose model to retry.", retryable: false))); return }
        guard let image = sent else { set(Part(state: .unavailable)); return }
        let profile = model.equationProfile
        let request: ChatGenerationRequest
        do {
            let label = part.map { "\(context.label) \($0.section.name)" } ?? context.label
            // The walkthrough's selection: the caption, then the figure's own sub-figures when it has several.
            let quote = part?.section.text ?? FigureStructure.quote(caption: context.caption, structure)
            if localModelID != nil {
                guard quote.unicodeScalars.count <= ChatGenerationRequest.maximumSelectionScalars else { throw LocalAIContext.Failure.mandatoryInputTooLarge }
                request = try ChatGenerationRequest.make(operationID: UUID(), documentID: context.paperID,
                    transcript: [.init(role: .user, text: label)], selection: quote, action: action, profile: profile, figures: [image])
                    .forLocalInference(paperText: PaperChatContext.text(context.bundle.index), focus: context.paragraph)
            } else if let local = context.localContext {
                request = try .figure(action, operationID: UUID(), label: label, quote: quote, profile: profile,
                                      localContext: local, visualAnswers: model.visualAnswers, image: image)
            } else { set(Part(state: .unavailable)); return }
        } catch {
            let message = localModelID != nil ? ChatFailureText.message(for: "local_context_large") : "This figure couldn’t be sent."
            set(Part(state: .failed(message, retryable: false))); return
        }
        if part == nil { beginProgress() }
        set(Part(state: .loading))
        let id = part.map { "simpler.\($0.index)" } ?? "figure"
        tasks[id]?.cancel()
        let answerKey = key(action, part: part?.section.text, profile: profile)
        tasks[id] = Task { [weak self] in await self?.stream(request, action: action, part: part?.index, key: answerKey) }
    }

    /// The walkthrough, or one part's simpler words.
    private func store(_ value: Part, index: Int?) {
        guard let index else {
            // The final walkthrough is framed again with the count check even when its parts are the ones streamed.
            let changed = walkthrough.walkthrough != value.walkthrough || framedFinal != walkthroughFinal
            walkthrough = value
            if changed { refreshCrops() }
            return
        }
        simpler[index] = value
    }

    private func stream(_ request: ChatGenerationRequest, action: ChatAction, part index: Int?, key: FigureResultKey) async {
        func set(_ value: Part) { store(value, index: index) }
        var part = Part(state: .loading), model: String?, credits: Int?, stopReason = ""
        // The streamed walkthrough (servers from 2026-10-22): the summary and the parts so far, shown as they arrive; the
        // final `figure` replaces them and is what is kept. Older servers send only the final `figure`.
        let walking = index == nil && action == .figure
        let scope = self.model?.readerSessionID
        do {
            guard let events = try await self.model?.equationStream(request, localModelID: localModelID) else { set(Part(state: .needsSignIn)); endProgress(); return }
            if walking { tracker.opened(); showProgress() }
            for try await event in events {
                guard !Task.isCancelled else { return }
                if walking {
                    let grew = tracker.apply(event)
                    if case .figure = event { walkthroughFinal = true }
                    showProgress()
                    if grew { part.walkthrough = tracker.walkthroughSoFar; set(part) }
                }
                switch event {
                case .delta(let piece):
                    part.text += piece
                    // A part more simply streams as it is written; the walkthrough's words (no usable walkthrough) come whole.
                    if localModelID != nil || (index != nil && action == .figureSimpler) { set(part) }
                case .figure(let walkthrough): part.walkthrough = walkthrough
                case .done(let reason, let paid, let answered, _): credits = paid; stopReason = reason; part.state = .done; model = answered; part.answeredModel = answered
                case .failure(let code, let paid): credits = paid; part.state = Self.failure(code)
                default: break
                }
                if part.state != .loading { break }
            }
        } catch ChatTransportError.rejected(let code) { part.state = Self.failure(code) }
        catch { guard !Task.isCancelled else { return }; part.state = Self.failure("transport") }
        guard !Task.isCancelled, self.model?.readerSessionID == scope else { return }
        if part.state == .loading { part.state = Self.failure("transport") }
        // Free AI that couldn't pay says why (migration 0150): the balance is read again once.
        if part.state == .failed(Self.noCredits, retryable: true), let reader = self.model {
            await reader.refreshCreditBalance()
            guard !Task.isCancelled, reader.readerSessionID == scope else { return }
            part.state = .failed(reader.creditsMessage(Self.noCredits, premium: ReaderModel.isPremium(key.profile.model)), retryable: true)
        }
        if walking {
            // Only the final walkthrough is kept or shown at the end: parts streamed without it are dropped (a failure shows
            // today's failure, not a partial walkthrough).
            part.walkthrough = tracker.final
            walkthroughFinal = true
        }
        if part.state == .done, part.walkthrough == nil, part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            part.state = .failed(index == nil ? "Couldn’t explain this figure. Try again." : "Couldn’t explain this part. Try again.", retryable: true)
        }
        // The server says what an early or empty ending cost: nothing (it never charges for work it couldn't show). A
        // walkthrough cut off at its length keeps the parts it showed, uncharged.
        part.notCharged = credits == 0 && (part.state != .done || (walking && part.walkthrough != nil && !Self.completeEndings.contains(stopReason)))
        if walking { endProgress() }
        set(part)
        guard part.state == .done, let reader = self.model else { return }
        reader.keepFigureAnswer(FigureAnswer(walkthrough: part.walkthrough, text: part.text, model: model), for: key)
        if localModelID == nil { Task { await reader.refreshCreditBalance() } }
    }

    /// Endings that wrote the whole walkthrough (anything else that cost nothing was cut off: "limit").
    private static let completeEndings: Set<String> = ["end_turn", "stop_sequence", "tool_use", "stop"]

    /// A new walkthrough request: preparing, expecting the figure's own sub-figures, else its caption's lettered panels.
    private func beginProgress() {
        walkthroughFinal = false; shownSections = 0
        tracker = FigureProgress.Tracker(expected: FigureProgress.expectedParts(subfigures: structure?.parts.count,
                                                                                captionLetters: FigureFraming.captionLetters(context.caption).count))
        showProgress()
    }

    /// Shows where the request is; unchanged steps leave the bar alone.
    private func showProgress() {
        let state = tracker.state()
        if progress != state { progress = state }
    }

    private func endProgress() { progress = nil }

    private static let noCredits = "Not enough credits for this. Your balance is in Settings."
    private static func failure(_ code: String) -> State {
        switch code {
        case "insufficient_credits": .failed(noCredits, retryable: true)
        default: .failed(ChatFailureText.message(for: code), retryable: ChatFailureText.isRetryable(code))
        }
    }

    private func key(_ action: ChatAction, part: String?, profile: ChatProfileChoice) -> FigureResultKey {
        FigureResultKey(manifestSHA256: context.bundle.manifestSHA256, figureID: context.figureID, action: action, part: part,
                        profile: profile, localModel: model?.localAI.identity(localModelID))
    }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A table as the paper's page draws it, as an image the model can read: the table's own markup with the bundle's
/// stylesheet, light, at its natural width, printed to PDF by WebKit (no window needed) and drawn on white.
@MainActor final class TableDrawing: NSObject, WKNavigationDelegate {
    static let maximumWidth = 1_500.0
    private var loaded: CheckedContinuation<Bool, Never>?

    static func image(bundle: VerifiedReaderBundle, markup: String) async -> CGImage? {
        await TableDrawing().draw(bundle: bundle, markup: markup)
    }

    static func page(bundle: VerifiedReaderBundle, markup: String) -> String {
        let style = bundle.manifest.members.first { $0.role == "style" }?.path
        let link = style.map { "<link rel=\"stylesheet\" href=\"\($0)\">" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light">\(link)
        <style>
        :root{color-scheme:light}html,body{background:#fff!important;color:#111!important;margin:0;padding:0}
        #t{display:inline-block;width:max-content;max-width:\(Int(maximumWidth))px;padding:14px;background:#fff}
        #t .reader-table{overflow:visible!important;max-width:none!important;margin:0}
        </style></head><body><div id="t">\(markup)</div></body></html>
        """
    }

    private func draw(bundle: VerifiedReaderBundle, markup: String) async -> CGImage? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = PaperWebView.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(ReaderBundleSchemeHandler(bundle: bundle), forURLScheme: "reader-bundle")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.maximumWidth + 40, height: 800), configuration: configuration)
        web.overrideUserInterfaceStyle = .light
        web.navigationDelegate = self
        defer { web.navigationDelegate = nil; web.stopLoading() }
        let finished = await withCheckedContinuation { continuation in
            loaded = continuation
            web.loadHTMLString(Self.page(bundle: bundle, markup: markup), baseURL: URL(string: "reader-bundle://\(bundle.manifestSHA256)/"))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finish(false)
            }
        }
        guard finished,
              let measured = try? await web.callAsyncJavaScript(
                  "const r = document.getElementById('t').getBoundingClientRect(); return [Math.ceil(r.width), Math.ceil(r.height)];",
                  arguments: [:], in: nil, contentWorld: .defaultClient) as? [Double],
              measured.count == 2, measured[0] >= 8, measured[1] >= 8 else { return nil }
        let size = CGSize(width: min(measured[0], Self.maximumWidth + 40), height: min(measured[1], 6_000))
        web.frame = CGRect(origin: .zero, size: CGSize(width: max(web.frame.width, size.width), height: size.height))
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = CGRect(origin: .zero, size: size)
        guard let pdf = try? await web.pdf(configuration: pdfConfiguration) else { return nil }
        return Self.render(pdf, size: size)
    }

    /// The first PDF page on white at twice its size, within 3,000 px on a side.
    static func render(_ pdf: Data, size: CGSize) -> CGImage? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width >= 8, box.height >= 8 else { return nil }
        let scale = min(2, 3_000 / max(box.width, box.height))
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.navigationType == .other ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(false) }
    private func finish(_ value: Bool) { loaded?.resume(returning: value); loaded = nil }
}

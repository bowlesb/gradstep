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
        /// One part extracted: its region (cropped here) and the closer reading; nil when the words came without a box.
        var detail: FigureDetail?
        /// The words, when no walkthrough came (or a part again, more simply).
        var text = ""
        /// Ended early or with nothing to show, and the reader paid nothing (CHAT.md "When an answer stops early").
        var notCharged = false
    }

    private(set) var walkthrough = Part()
    /// A part explained more simply, by the part's index in the walkthrough.
    private(set) var simpler: [Int: Part] = [:]
    /// A part extracted with more context (owner, TestFlight 62: "Extract the subfigure and more context"), by its index.
    private(set) var details: [Int: Part] = [:]
    /// The figure as the request sends it (its panels composed, or the table drawn here), which crops are cut from.
    private(set) var image: CGImage?
    let context: FigureViewContext
    @ObservationIgnored private weak var model: ReaderModel?
    @ObservationIgnored private var sent: ChatFigureImage?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var awaitingConsent: (() -> Void)?
    var asksConsent: Bool { awaitingConsent != nil }

    init(context: FigureViewContext, model: ReaderModel) { self.context = context; self.model = model }

    /// Shows what this device kept; asks for the walkthrough when nothing is kept (Explain was chosen to get here).
    func start() async {
        guard let model else { return }
        let profile = model.equationProfile
        if let kept = model.figureAnswer(key(.figure, part: nil, profile: profile)) {
            walkthrough = Part(state: .done, walkthrough: kept.walkthrough, text: kept.text)
            for (index, section) in (kept.walkthrough?.sections ?? []).enumerated() {
                if let more = model.figureAnswer(key(.figureSimpler, part: section.text, profile: profile)) { simpler[index] = Part(state: .done, text: more.text) }
                if let closer = model.figureAnswer(key(.figureDetail, part: section.text, profile: profile)) {
                    details[index] = Part(state: .done, detail: closer.detail, text: closer.text)
                }
            }
        }
        await prepareImage()
        if walkthrough.state == .idle { explain() }
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
    /// "Extract the subfigure and more context": that part's region, cropped, read again with more of the paper, inline
    /// under it.
    func extract(_ index: Int) {
        guard let section = walkthrough.walkthrough?.sections[safe: index], details[index]?.state != .loading, details[index]?.state != .done else { return }
        run(.figureDetail, part: (index, section))
    }
    func retryDetail(_ index: Int) {
        guard let section = walkthrough.walkthrough?.sections[safe: index] else { return }
        run(.figureDetail, part: (index, section))
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
        for (index, part) in details where part.state == .needsConsent { details[index] = nil }
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
            let paths = Array(figure.assetPaths.prefix(ChatFigureFinder.maximumPanels))
            let images = paths.compactMap { bundle.data(for: $0).flatMap(ChatFigureFinder.image) }
            image = images.count == paths.count ? ChatFigureFinder.composite(images) : nil
            sent = ChatFigureFinder.image(for: figure, bundle: bundle)
        }
    }

    private func run(_ action: ChatAction, part: (index: Int, section: FigureWalkthrough.Section)?) {
        guard let model else { return }
        func set(_ value: Part) { store(value, action: action, index: part?.index) }
        guard model.isSignedIn else { set(Part(state: .needsSignIn)); return }
        guard let local = context.localContext else { set(Part(state: .unavailable)); return }
        guard model.hasCloudConsent else {
            awaitingConsent = { [weak self] in self?.run(action, part: part) }
            set(Part(state: .needsConsent)); return
        }
        guard let image = sent else { set(Part(state: .unavailable)); return }
        let profile = model.equationProfile
        let request: ChatGenerationRequest
        do {
            let label = part.map { "\(context.label) \($0.section.name)" } ?? context.label
            // A part extracted is named by its label and title with its text, so the model knows which region to crop.
            let quote = part.map { action == .figureDetail
                ? ([$0.section.label, $0.section.title].filter { !$0.isEmpty }.joined(separator: " ") + "\n" + $0.section.text) : $0.section.text } ?? context.caption
            request = try .figure(action, operationID: UUID(), label: label, quote: quote, profile: profile,
                                  localContext: local, visualAnswers: model.visualAnswers, image: image)
        } catch { set(Part(state: .failed("This figure couldn’t be sent.", retryable: false))); return }
        set(Part(state: .loading))
        let id = part.map { "\(action == .figureDetail ? "detail" : "simpler").\($0.index)" } ?? "figure"
        tasks[id]?.cancel()
        let answerKey = key(action, part: part?.section.text, profile: profile)
        tasks[id] = Task { [weak self] in await self?.stream(request, action: action, part: part?.index, key: answerKey) }
    }

    /// The walkthrough, or one part's simpler words or extract.
    private func store(_ value: Part, action: ChatAction, index: Int?) {
        guard let index else { walkthrough = value; return }
        if action == .figureDetail { details[index] = value } else { simpler[index] = value }
    }

    private func stream(_ request: ChatGenerationRequest, action: ChatAction, part index: Int?, key: FigureResultKey) async {
        func set(_ value: Part) { store(value, action: action, index: index) }
        var part = Part(state: .loading), model: String?, credits: Int?
        do {
            guard let events = try await self.model?.equationStream(request) else { set(Part(state: .needsSignIn)); return }
            for try await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .delta(let piece):
                    part.text += piece
                    // A part more simply streams as it is written; the walkthrough's words (no usable walkthrough) and an
                    // extract's (no usable box) come whole.
                    if index != nil, action == .figureSimpler { set(part) }
                case .figure(let walkthrough): part.walkthrough = walkthrough
                case .figureDetail(let detail): part.detail = detail
                case .done(_, let paid, let answered, _): credits = paid; part.state = .done; model = answered
                case .failure(let code, let paid): credits = paid; part.state = Self.failure(code)
                default: break
                }
                if part.state != .loading { break }
            }
        } catch ChatTransportError.rejected(let code) { part.state = Self.failure(code) }
        catch { guard !Task.isCancelled else { return }; part.state = Self.failure("transport") }
        guard !Task.isCancelled else { return }
        if part.state == .loading { part.state = Self.failure("transport") }
        if part.state == .done, part.walkthrough == nil, part.detail == nil, part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            part.state = .failed(index == nil ? "Couldn’t explain this figure. Try again." : "Couldn’t explain this part. Try again.", retryable: true)
        }
        // The server says what an early or empty ending cost: nothing (it never charges for work it couldn't show).
        part.notCharged = credits == 0 && part.state != .done
        set(part)
        guard part.state == .done, let reader = self.model else { return }
        reader.keepFigureAnswer(FigureAnswer(walkthrough: part.walkthrough, detail: part.detail, text: part.text, model: model), for: key)
        Task { await reader.refreshCreditBalance() }
    }

    private static func failure(_ code: String) -> State {
        switch code {
        case "insufficient_credits": .failed("Not enough credits for this. Your balance is in Settings.", retryable: true)
        default: .failed(ChatFailureText.message(for: code), retryable: ChatFailureText.isRetryable(code))
        }
    }

    private func key(_ action: ChatAction, part: String?, profile: ChatProfileChoice) -> FigureResultKey {
        FigureResultKey(manifestSHA256: context.bundle.manifestSHA256, figureID: context.figureID, action: action, part: part, profile: profile)
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

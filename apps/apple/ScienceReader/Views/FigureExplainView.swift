import ScienceReaderCore
import SwiftUI
import UIKit

// The figure view's screens (owner, build 59; docs/architecture/FIGURE_VIEW.md): a figure page offers Explain and Ask in
// chat side by side; Explain opens the walkthrough in the equation view's look: the figure, what it shows, then each
// part with its crop where the walkthrough points at a small detail. A part's menu explains it more simply, shows it in
// the paper, or asks about it in chat.

/// Who a figure page belongs to: the open paper's model, and how the sheet it is in closes with what was chosen
/// (applied once the sheet has gone, as the equation view's outcomes are).
struct FigureViewHost {
    let model: ReaderModel
    let paperID: UUID
    let finish: @MainActor (FigureViewOutcome) -> Void
    /// Closes the sheet with nothing chosen (an explainer's X).
    let close: @MainActor () -> Void
}

private struct FigureViewHostKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: FigureViewHost? = nil }
/// A half-height sheet's way to take the full height (Contents, a figure reference): the walkthrough reads best there.
private struct ExpandSheetKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    var figureViewHost: FigureViewHost? {
        get { self[FigureViewHostKey.self] }
        set { self[FigureViewHostKey.self] = newValue }
    }
    var expandSheet: (@MainActor () -> Void)? {
        get { self[ExpandSheetKey.self] }
        set { self[ExpandSheetKey.self] = newValue }
    }
}

extension View {
    /// A figure page's top row (DESIGN.md "Sheet top row"): Explain in Chat and AI Explainer on the left, the X on the
    /// right, and the walkthrough AI Explainer opens (in the page's own navigation stack, so Back returns to the figure).
    /// Without a host (a figure outside the open paper) only the X.
    func figurePageActions(figureID: String, close: @escaping () -> Void) -> some View {
        modifier(FigurePageActions(figureID: figureID, close: close))
    }
}

private struct FigurePageActions: ViewModifier {
    let figureID: String
    let close: () -> Void
    @Environment(\.figureViewHost) private var host
    @Environment(\.expandSheet) private var expandSheet
    @State private var context: FigureViewContext?
    @State private var explaining = false
    @State private var explainOnOpen = true
    @State private var choosingAI = false

    func body(content: Content) -> some View {
        content
            .sheetTopRow(
                chat: host.flatMap { host in context.map { context in
                    ExplainAction(identifier: "figureView.askInChat", hint: "Ask about this figure here; nothing is sent") {
                        explainOnOpen = false; expandSheet?(); explaining = true
                    }
                } },
                // An arXiv paper on this device only: the walkthrough reads the paper numbered here.
                explainer: host != nil && context != nil
                    ? ExplainAction(identifier: "figureView.explain", hint: "Open the saved explanation, or choose a model for a new one.") {
                        if let host, let context, FigureExplainSession.hasSavedAnswer(context: context, model: host.model) {
                            explainOnOpen = false; expandSheet?(); explaining = true
                        } else { choosingAI = true }
                    }
                    : nil,
                noun: context?.label.hasPrefix("Table") == true ? "Table" : "Figure",
                close: close)
            .navigationDestination(isPresented: $explaining) {
                if let host, let context { FigureExplainView(model: host.model, context: context, requesting: explainOnOpen, finish: host.finish, close: host.close) }
            }
            .sheet(isPresented: $choosingAI) {
                if let host {
                    AIChoiceView(model: host.model, scenario: .figures, needsVision: true) { _ in
                        explainOnOpen = true; expandSheet?(); explaining = true
                    }
                }
            }
            .task(id: figureID) {
                explaining = false
                context = host.flatMap { $0.model.figureContext(paperID: $0.paperID, figureID: figureID) }
            }
    }
}

/// The walkthrough of one figure: the figure, what it shows, then part by part. Requested on opening when nothing is
/// kept on this device (AI Explainer was chosen to get here); kept answers show at once. Its heading switches to another
/// figure of the paper, which shows its kept walkthrough or offers AI Explainer (nothing is asked unasked).
struct FigureExplainView: View {
    let model: ReaderModel
    let finish: @MainActor (FigureViewOutcome) -> Void
    let close: @MainActor () -> Void
    @State private var context: FigureViewContext
    @State private var session: FigureExplainSession?
    /// The figure AI Explainer was chosen for is asked for at once; one switched to from the heading is not.
    @State private var requestsOnOpen = true
    @State private var choosingAI = false
    @State private var chatToken: UUID?
    @State private var chatFocus = 0
    @State private var expandedImage: FigureImagePresentation?
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0

    init(model: ReaderModel, context: FigureViewContext, requesting: Bool = true, finish: @escaping @MainActor (FigureViewOutcome) -> Void,
         close: @escaping @MainActor () -> Void) {
        self.model = model; self.finish = finish; self.close = close
        _context = State(initialValue: context)
        _requestsOnOpen = State(initialValue: requesting)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let session { content(session) } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .sheetTopRow(
            explainer: session.map { $0.walkthrough.state == .idle } == true
                ? ExplainAction(identifier: "figureView.walkthrough.explain", hint: "Choose a model to explain this figure.") { choosingAI = true }
                : nil,
            openChat: ExplainAction(identifier: "figureView.openInChat", hint: "Continue this conversation in Chat.") {
                guard let chatToken else { return }
                model.promoteContextualChat(chatToken, explanation: figureExplanation, image: session?.image); finish(.continueChat)
            }, close: close)
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: context.figureID) {
            session?.stop()
            chatToken = model.beginContextualChat(paperID: context.paperID, manifest: context.bundle.manifestSHA256,
                element: context.figureID, label: context.label, quote: context.caption)
            let opened = FigureExplainSession(context: context, model: model)
            session = opened
            let requesting = requestsOnOpen
            requestsOnOpen = false
            await opened.start(requesting: requesting)
        }
        .onDisappear { if expandedImage == nil { session?.stop(); if let chatToken { model.endContextualChat(chatToken) } } }
        .modifier(FigureImageCover(image: $expandedImage))
        .sheet(isPresented: $choosingAI) {
            AIChoiceView(model: model, chat: true, needsVision: true) { id in
                model.localAIModelID = id; session?.stop()
                let opened = FigureExplainSession(context: context, model: model); session = opened
                Task { await opened.start() }
            }
        }
        .sheet(isPresented: Binding(get: { session?.asksConsent ?? false }, set: { if !$0, session?.asksConsent == true { session?.declineConsent() } })) {
            CloudConsentContent(accept: { session?.acceptConsent() }, decline: { session?.declineConsent() })
                .presentationDetents([.large])
                .macSheetKeys()
        }
    }

    private var composer: some View {
        ContextualChatComposer(model: model, token: chatToken, label: context.label, needsVision: true,
            explanation: figureExplanation, busy: session?.walkthrough.state == .loading, focusRequest: chatFocus,
            modelChanged: {
                session?.stop()
                let next = FigureExplainSession(context: context, model: model); session = next
                Task { await next.start(requesting: false) }
            })
    }

    private var figureExplanation: String {
        guard let session else { return "" }
        guard let walkthrough = session.walkthrough.walkthrough else { return session.walkthrough.text }
        return ([walkthrough.summary] + walkthrough.sections.map { "\($0.name): \($0.text)" }).joined(separator: "\n")
    }

    private func cloudLabel(_ session: FigureExplainSession) -> String {
        if let served = session.walkthrough.answeredModel { return "\(ChatProfileText.modelName(served))" }
        if session.walkthrough.state == .done { return "Saved explanation" }
        return "\(model.chatProfileTable?.label(model.equationProfile.model) ?? model.equationProfile.model.label)"
    }

    private func content(_ session: FigureExplainSession) -> some View {
        ContextualConversationScroll(model: model, token: chatToken) {
            VStack(alignment: .leading, spacing: 18) {
                heading
                figureCard(session)
                Text(session.localModelID.map { "\(model.localAI.name($0)) (local)" } ?? cloudLabel(session))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("figureView.aiSource")
                walkthrough(session)
                ContextualChatThread(model: model, token: chatToken, onCite: cite)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("figureView.walkthrough")
    }

    private func expandable(_ image: CGImage, label: String, identifier: String) -> some View {
        ZStack(alignment: .topTrailing) {
            ZoomableFigureImage(image: image).accessibilityLabel(label).accessibilityIdentifier(identifier)
                Button { expandedImage = FigureImagePresentation(image: image, whole: session?.image, label: label) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").padding(12).background(.regularMaterial, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("View \(label) fullscreen").accessibilityIdentifier("figureView.fullscreen")
                    .padding(4)
        }
    }

    // MARK: The figure

    /// "Figure 3 ⌄": the paper's other figures (or tables, from a table) to switch to.
    private var heading: some View {
        let index = context.bundle.index
        let isTable = context.label.hasPrefix("Table") || context.isDrawnTable
        let entries = isTable ? GalleryFigure.tables(in: index) : GalleryFigure.all(in: index).filter { !($0.number?.hasPrefix("Table") ?? false) }
        return ExplainerHeadingMenu(title: context.label, items: entries, current: context.figureID,
                                    itemTitle: { entry in [entry.number ?? (isTable ? "Table" : "Figure"), String(entry.caption.prefix(60))]
                                        .filter { !$0.isEmpty }.joined(separator: " — ") },
                                    identifier: "figureView.heading") { entry in
            guard entry.id != context.figureID, let other = model.figureContext(paperID: context.paperID, figureID: entry.id) else { return }
            context = other
        }
    }

    private func figureCard(_ session: FigureExplainSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Whole figure").font(.subheadline.weight(.semibold))
            if let image = session.image {
                // Figures are drawn on white in the paper; keep that in dark mode too.
                expandable(image, label: context.label, identifier: "figureView.figure").id(context.figureID).aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                    // Even a tiny bitmap needs enough room for a two-finger gesture.
                    .frame(maxWidth: max(160, CGFloat(image.width) * 2), maxHeight: min(300, max(160, CGFloat(image.height) * 2)))
                    .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity)
            }
            ChatMessageText(source: context.caption, fontSize: bodySize * 0.82, streaming: false, speaker: "Caption", identifier: "figureView.caption")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    // MARK: The walkthrough

    @ViewBuilder private func walkthrough(_ session: FigureExplainSession) -> some View {
        let part = session.walkthrough
        VStack(alignment: .leading, spacing: 16) {
            if let walkthrough = part.walkthrough {
                if !walkthrough.summary.isEmpty {
                    ChatMessageText(source: walkthrough.summary, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                    identifier: "figureView.summary", assistant: true, onCite: cite)
                }
                if let image = session.image, let coverage = walkthrough.cropCoverage(width: image.width, height: image.height), coverage < 1 {
                    Text("The detail cards do not cover the entire image. The whole figure above keeps every panel, axis and legend available.")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("figureView.coverageFallback")
                }
                ForEach(Array(walkthrough.sections.enumerated()), id: \.offset) { index, section in
                    sectionCard(section, index: index, session: session)
                }
            } else if !part.text.isEmpty, part.state == .done || session.localModelID != nil {
                // No usable walkthrough: the model's words are the description.
                ChatMessageText(source: part.text, fontSize: bodySize, streaming: part.state == .loading, speaker: "Assistant", identifier: "figureView.description",
                                assistant: true, onCite: cite)
            }
            status(part, working: context.isDrawnTable || context.label.hasPrefix("Table") ? "Looking at the table…" : "Looking at the figure…", retry: { session.retry() })
        }
    }

    private func sectionCard(_ section: FigureWalkthrough.Section, index: Int, session: FigureExplainSession) -> some View {
        let number = index + 1, simpler = session.simpler[index], detail = session.details[index]
        return VStack(alignment: .leading, spacing: 10) {
            // A tap on the part's heading opens its menu (owner: "tap on different parts of the response and ask to back
            // up a bit, or link back into the paper"); a long press or right-click anywhere on the part does too.
            Menu { menuItems(section, index: index, session: session) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([section.typeLabel, section.label].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Text(section.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "ellipsis.circle").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([section.label, section.title].filter { !$0.isEmpty }.joined(separator: ": "))
            .accessibilityHint("Options for this part")
            .accessibilityIdentifier("figureView.section.\(number).menu")
            if section.cardKind == .panel, let box = section.box, let image = session.image, let crop = Self.crop(image, box) {
                expandable(crop, label: "Detail of \(context.label): \(section.name)", identifier: "figureView.section.\(number).crop").aspectRatio(CGFloat(crop.width) / CGFloat(crop.height), contentMode: .fit)
                    .frame(maxWidth: max(160, CGFloat(crop.width) * 2), maxHeight: min(260, max(160, CGFloat(crop.height) * 2)))
                    .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.25)))
                    .frame(maxWidth: .infinity)
            }
            if section.cardKind == .relatedWork {
                Text("As described in this paper").font(.caption).foregroundStyle(.secondary)
            }
            ChatMessageText(source: section.text, fontSize: bodySize, streaming: false, speaker: "Assistant",
                            identifier: "figureView.section.\(number).text", assistant: true, onCite: cite)
            if let simpler {
                VStack(alignment: .leading, spacing: 8) {
                    Label("More simply", systemImage: "arrow.uturn.backward").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if !simpler.text.isEmpty {
                        ChatMessageText(source: simpler.text, fontSize: bodySize, streaming: simpler.state == .loading, speaker: "Assistant",
                                        identifier: "figureView.section.\(number).simpler", assistant: true,
                                        onCite: simpler.state == .loading ? nil : cite)
                    }
                    status(simpler, working: "Explaining it more simply…", retry: { session.retrySimpler(index) })
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 3) }
            }
            if let detail { detailBlock(detail, number: number, index: index, session: session) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .contextMenu { menuItems(section, index: index, session: session) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("figureView.section.\(number)")
    }

    /// One part extracted (owner, TestFlight 62: "opens up a loader below, gets the info, and puts it below"): the region
    /// cropped from the image that was sent, then the closer reading; the words alone when no region could be given.
    @ViewBuilder private func detailBlock(_ detail: FigureExplainSession.Part, number: Int, index: Int, session: FigureExplainSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Up close", systemImage: "viewfinder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let box = detail.detail?.box, let image = session.image, let crop = Self.crop(image, box) {
                expandable(crop, label: "This part of \(context.label), up close", identifier: "figureView.section.\(number).detailCrop").aspectRatio(CGFloat(crop.width) / CGFloat(crop.height), contentMode: .fit)
                    .frame(maxWidth: max(160, CGFloat(crop.width) * 2), maxHeight: min(320, max(160, CGFloat(crop.height) * 2)))
                    .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.25)))
                    .frame(maxWidth: .infinity)
            }
            let words = detail.detail?.text ?? detail.text
            if detail.state == .done, !words.isEmpty {
                ChatMessageText(source: words, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                identifier: "figureView.section.\(number).detail", assistant: true, onCite: cite)
                if detail.detail == nil {
                    Text("Couldn’t crop this part; here is the closer reading.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("figureView.section.\(number).detailNoCrop")
                }
            }
            status(detail, working: "Extracting this part…", retry: { session.retryDetail(index) })
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 3) }
    }

    @ViewBuilder private func menuItems(_ section: FigureWalkthrough.Section, index: Int, session: FigureExplainSession) -> some View {
        let state = session.simpler[index]?.state, extracted = session.details[index]?.state
        Button { session.simplify(index) } label: { Label("Explain more simply", systemImage: "arrow.uturn.backward") }
            .disabled(state == .loading || state == .done)
            .accessibilityIdentifier("figureView.simpler")
        if section.cardKind == .panel {
            Button { session.extract(index) } label: { Label("Extract the subfigure and more context", systemImage: "viewfinder") }
                .disabled(extracted == .loading || extracted == .done)
                .accessibilityIdentifier("figureView.extract")
        }
        Button {
            rememberReturn()
            finish(section.paragraphs.first.map { .paragraph(paperID: context.paperID, marker: $0) } ?? .figure(paperID: context.paperID, figureID: context.figureID))
        } label: { Label("Show in the paper", systemImage: "doc.text.magnifyingglass") }
            .accessibilityIdentifier("figureView.showInPaper")
        Button { model.chatInput = "About \(section.name): "; chatFocus += 1 } label: { Label("Ask about this part", systemImage: "bubble.left.and.text.bubble.right") }
            .accessibilityIdentifier("figureView.askAbout")
    }

    @ViewBuilder private func status(_ part: FigureExplainSession.Part, working: String, retry: @escaping () -> Void) -> some View {
        switch part.state {
        case .loading where part.text.isEmpty:
            HStack(spacing: 10) { ProgressView(); Text(working).foregroundStyle(.secondary) }
                .accessibilityElement(children: .combine).accessibilityIdentifier("figureView.loading")
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                Text(part.notCharged ? message + " Not charged." : message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("figureView.failure")
                if retryable { Button("Try again", action: retry).accessibilityIdentifier("figureView.retry") }
                Button("Change AI") { choosingAI = true }.accessibilityIdentifier("figureView.changeAI")
            }
        case .needsSignIn:
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to have figures explained.").foregroundStyle(.secondary)
                Button("Sign in") { finish(.signIn) }
            }
        case .needsConsent:
            Button("Continue…", action: retry)
        case .unavailable:
            Text("Explanations need this paper on this device as an arXiv paper.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    private func rememberReturn() {
        model.rememberExplainer(paperID: context.paperID, manifest: context.bundle.manifestSHA256,
            item: context.figureID, label: context.label, equation: false)
    }

    private var cite: ChatCiteHandler {
        let paperID = context.paperID
        return { marker in rememberReturn(); finish(.paragraph(paperID: paperID, marker: marker)) }
    }

    /// A part of the figure, by its box in fractions of the image the request carried (the same proportions here).
    static func crop(_ image: CGImage, _ box: FigureWalkthrough.Box) -> CGImage? {
        guard let rect = box.displayBox.pixels(width: image.width, height: image.height) else { return nil }
        return image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }
}

/// Every figure crop is directly pinchable; at 1× its scroll view has no pan extent, so the enclosing page scrolls.
struct ZoomableFigureImage: UIViewRepresentable {
    let image: CGImage
    func makeUIView(context: Context) -> FigureZoomScroll { FigureZoomScroll(image: image) }
    func updateUIView(_ view: FigureZoomScroll, context: Context) { view.setImage(image) }
}

final class FigureZoomScroll: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var pixels: CGImage
    private var laidOut = CGSize.zero
    init(image: CGImage) {
        pixels = image
        super.init(frame: .zero)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 8
        bounces = false; bouncesZoom = false; contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        backgroundColor = .white; picture.image = UIImage(cgImage: image); addSubview(picture)
        isAccessibilityElement = true; accessibilityTraits = [.image, .adjustable]
        accessibilityHint = "Pinch to zoom, drag to pan; double tap to reset."
        accessibilityValue = "100%"
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom)); doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setImage(_ image: CGImage) {
        guard pixels !== image else { return }
        let changedSize = pixels.width != image.width || pixels.height != image.height
        pixels = image; picture.image = UIImage(cgImage: image)
        if changedSize { laidOut = .zero; setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOut, bounds.width > 0, bounds.height > 0 else { return }
        laidOut = bounds.size; setZoomScale(1, animated: false)
        let fit = min(bounds.width / CGFloat(pixels.width), bounds.height / CGFloat(pixels.height))
        picture.frame = CGRect(x: 0, y: 0, width: CGFloat(pixels.width) * fit, height: CGFloat(pixels.height) * fit)
        contentSize = picture.frame.size; centerImage()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage(); accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
    }
    private func centerImage() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }
    @objc private func toggleZoom() { setZoomScale(zoomScale > 1 ? 1 : 2, animated: true) }
    override func accessibilityIncrement() { setZoomScale(min(maximumZoomScale, zoomScale + 0.5), animated: false) }
    override func accessibilityDecrement() { setZoomScale(max(1, zoomScale - 0.5), animated: false) }
}

struct FigureImagePresentation: Identifiable {
    let id = UUID()
    let image: CGImage
    let whole: CGImage?
    let label: String
}

private struct FigureViewerWindowSizeKey: EnvironmentKey { static let defaultValue = CGSize.zero }
extension EnvironmentValues {
    var figureViewerWindowSize: CGSize {
        get { self[FigureViewerWindowSizeKey.self] }
        set { self[FigureViewerWindowSizeKey.self] = newValue }
    }
}

private struct FigureImageCover: ViewModifier {
    @Binding var image: FigureImagePresentation?
    @Environment(\.figureViewerWindowSize) private var windowSize
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.sheet(item: $image) { value in
            // The presenting sheet has its own smaller geometry. Carry the owning window's size from RootView.
            if #available(iOS 18.0, *), windowSize.width > 0, windowSize.height > 0 {
                FullscreenFigureImage(image: value) { image = nil }
                    .frame(width: windowSize.width, height: windowSize.height)
                    .presentationSizing(.fitted)
            } else {
                FullscreenFigureImage(image: value) { image = nil }
            }
        }
        #else
        content.fullScreenCover(item: $image) { value in
            FullscreenFigureImage(image: value) { image = nil }
        }
        #endif
    }
}

struct FullscreenFigureImage: View {
    let image: FigureImagePresentation
    let close: () -> Void
    @State private var whole = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(image.label).font(.headline)
                Spacer()
                if let original = image.whole, original !== image.image {
                    Button(whole ? "Show detail" : "Whole figure") { whole.toggle() }
                }
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close fullscreen image").accessibilityIdentifier("figureView.fullscreen.close")
                    .macKeyboardShortcut(.escape, modifiers: [])
            }.padding(.horizontal, 16)
            ZoomableFigureImage(image: whole ? image.whole ?? image.image : image.image)
                .id(whole).accessibilityIdentifier("figureView.fullscreen.image")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Pinch to zoom · Drag to pan · Double tap to reset").font(.footnote).foregroundStyle(.secondary).padding(12)
        }.background(Color(uiColor: .systemBackground)).macSheetKeys()
    }
}

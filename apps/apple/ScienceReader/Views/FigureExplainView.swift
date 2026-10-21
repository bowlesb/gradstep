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
    /// A figure page's top row (DESIGN.md "Sheet top row"): Snippet, Chat and AI Explainer as words (owner, build 78), and
    /// the walkthrough AI Explainer opens (in the page's own navigation stack, so Back returns to the figure). The sheet
    /// swipes away (the Mac keeps an X). Without a host (a figure outside the open paper) no actions.
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

    /// Drawing a snippet over this figure page (Add to note: the whole item first, then adjust).
    private var capturing: Bool { host?.model.notes.capturing == .figure }
    private var paper: Paper? { host.flatMap { host in host.model.papers.first { $0.id == host.paperID } ?? host.model.selectedPaper } }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let host, capturing, let paper {
                    SnippetCaptureOverlay(model: host.model, origin: .figure, capture: { rect, size in
                        try await SnippetCapturer.webRegion(rect, overlaySize: size, web: ReaderWebView.figurePages.object(forKey: figureID as NSString),
                                                            paper: paper, origin: .figure)
                    }, wholeTitle: "Whole page")
                }
            }
            .overlay(alignment: .bottom) {
                if let host, !capturing { NoteSavedBanner(model: host.model, origin: .figure, leave: host.close).padding(.bottom, 12) }
            }
            .sheetTopRow(
                // Add to note: the whole figure or table chosen to start (build 78: "Snippet", in words, first).
                snippet: capturing ? nil : host.map { host in
                    ExplainAction(identifier: "figureView.addToNote", hint: "Saves this figure, or a part of it, as a snippet") { addToNote(host) }
                },
                chat: capturing ? nil : host.flatMap { host in context.map { context in
                    ExplainAction(identifier: "figureView.askInChat", hint: "Ask about this figure here; nothing is sent") {
                        explainOnOpen = false; expandSheet?(); explaining = true
                    }
                } },
                // An arXiv paper on this device only: the walkthrough reads the paper numbered here.
                explainer: host != nil && context != nil && !capturing
                    ? ExplainAction(identifier: "figureView.explain", hint: "Open the saved explanation, or choose a model for a new one.") {
                        if let host, let context, FigureExplainSession.hasSavedAnswer(context: context, model: host.model) {
                            explainOnOpen = false; expandSheet?(); explaining = true
                        } else { choosingAI = true }
                    }
                    : nil,
                noun: context?.label.hasPrefix("Table") == true ? "Table" : "Figure",
                close: capturing ? nil : close)
            .toolbar {
                if let host, capturing { SnippetCaptureToolbar(model: host.model) }
            }
            .modifier(OptionalComposerHost(model: host?.model, origin: .figure))
            .onDisappear { if capturing { host?.model.notes.capturing = nil } }
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

    /// Add to note: the whole figure or table is chosen to start; the corners adjust it, Use snippet keeps it.
    private func addToNote(_ host: FigureViewHost) {
        guard host.model.notesAvailability == .ready else {
            host.model.error = host.model.isSignedIn ? "Unlock Notes on this device to save snippets." : "Sign in to save snippets to your encrypted notes."
            return
        }
        Task { @MainActor in
            host.model.notes.captureInitialRect = await SnippetCapturer.figureBounds(in: ReaderWebView.figurePages.object(forKey: figureID as NSString))
            host.model.notes.notice = nil
            host.model.notes.capturing = .figure
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
            // Reappearing after the fullscreen figure (iPhone/iPad cover) keeps this figure's session and whatever is
            // arriving; only another figure starts a new one.
            if let session, session.context.figureID == context.figureID,
               session.context.bundle.manifestSHA256 == context.bundle.manifestSHA256 { return }
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
        // The fullscreen control sits under the crop, never over it (2026-10-21: the round button hid each crop's title).
        VStack(alignment: .trailing, spacing: 4) {
            ZoomableFigureImage(image: image).aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
            Button { expandedImage = FigureImagePresentation(image: image, label: label) } label: {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right").font(.footnote.weight(.medium))
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.borderless).accessibilityLabel("View \(label) fullscreen").accessibilityIdentifier("figureView.fullscreen")
        }
    }

    /// A part's card: a viewport into the whole figure framed by confidence (FIGURE_VIEW.md "Parts as viewports"), its
    /// aspect the frame's; a tap or Full screen expands it to the whole figure with the part outlined.
    private func partCard(_ part: FramedPart, image: CGImage, label: String, identifier: String, maxHeight: CGFloat, recordKey: String?) -> some View {
        let W = Double(image.width), H = Double(image.height)
        let frameWidth = (part.frame.x1 - part.frame.x0) * W, frameHeight = (part.frame.y1 - part.frame.y0) * H
        let expand = { expandedImage = FigureImagePresentation(image: image, part: part, label: label, recordKey: recordKey) }
        return VStack(alignment: .trailing, spacing: 4) {
            FigureViewport(image: image, part: part, recordKey: recordKey, snippetKey: identifier, onTap: expand)
                .id(identifier + "\(part.frame)")
                .aspectRatio(frameWidth / frameHeight, contentMode: .fit)
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
            Button(action: expand) {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right").font(.footnote.weight(.medium))
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.borderless).accessibilityLabel("View \(label) fullscreen").accessibilityIdentifier("figureView.fullscreen")
        }
        .frame(maxWidth: max(160, frameWidth * 2), maxHeight: min(maxHeight, max(160, frameHeight * 2)))
        .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.25)))
        .frame(maxWidth: .infinity)
    }

    /// Save snippet from a part: what its card shows (the view as the reader left it), into the snippet composer.
    private func saveSnippet(_ section: FigureWalkthrough.Section, number: Int, session: FigureExplainSession) {
        guard model.notesAvailability == .ready else {
            model.error = model.isSignedIn ? "Unlock Notes on this device to save snippets." : "Sign in to save snippets to your encrypted notes."
            return
        }
        guard let paper = model.papers.first(where: { $0.id == context.paperID }) ?? model.selectedPaper, let whole = session.image else { return }
        let index = number - 1
        let shown = FigureViewportScroll.shown.object(forKey: "figureView.section.\(number).crop" as NSString)
        let line = max(2, Double(max(whole.width, whole.height)) / 280)
        guard let image = shown?.visibleImage() ?? session.framed[index]?.renderFrame(whole, outline: FigurePartCrop.outline, lineWidth: line) else { return }
        let block = context.bundle.index.figures.first { $0.id == context.figureID }?.blockID ?? context.figureID
        let anchor = NoteAnchor(manifestSHA256: context.bundle.manifestSHA256, rendererRevision: ReaderVersions.revision(of: context.bundle) ?? 0,
                                blockIDs: NoteAnchor.isBlockID(block) ? [block] : [], rects: [], viewport: nil, quote: nil)
        let snippet = CapturedSnippet(kind: .region, image: image, quote: nil, source: SnippetCapturer.source(for: paper, label: "\(context.label) · \(section.name)"),
                                      anchor: anchor, capturedAt: Date(), origin: .figure, paperID: paper.id)
        model.notes.notice = nil
        model.notes.composer = NoteComposerRequest(snippet: snippet)
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
                expandable(image, label: context.label, identifier: "figureView.figure").id(context.figureID)
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
                if let coverage = session.inkCoverage, coverage < 1 {
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
        let number = index + 1, simpler = session.simpler[index]
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
            if section.cardKind == .panel, section.box != nil, let part = session.framed[index], let image = session.image {
                partCard(part, image: image, label: part.level == .low ? "\(context.label), whole, for \(section.name)" : "Detail of \(context.label): \(section.name)",
                         identifier: "figureView.section.\(number).crop", maxHeight: 260, recordKey: session.recordKey(.walkthrough, index))
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
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .contextMenu { menuItems(section, index: index, session: session) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("figureView.section.\(number)")
    }

    /// A part's menu (owner, 2026-10-21: "consistently create one good product experience in the AI result"): Explain
    /// more simply is the one AI follow-up (words under the part, nothing else); to look closer, the card zooms and
    /// expands to the whole figure. "Extract the subfigure and more context" was removed.
    @ViewBuilder private func menuItems(_ section: FigureWalkthrough.Section, index: Int, session: FigureExplainSession) -> some View {
        let state = session.simpler[index]?.state
        Button { session.simplify(index) } label: { Label("Explain more simply", systemImage: "arrow.uturn.backward") }
            .disabled(state == .loading || state == .done)
            .accessibilityIdentifier("figureView.simpler")
        if session.framed[index] != nil {
            Button { saveSnippet(section, number: index + 1, session: session) } label: { Label("Save snippet", systemImage: "note.text.badge.plus") }
                .accessibilityIdentifier("figureView.saveSnippet")
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

}

/// Every figure crop is directly pinchable; at 1× its scroll view has no pan extent, so the enclosing page scrolls.
struct ZoomableFigureImage: UIViewRepresentable {
    let image: CGImage
    /// Background kept around the image at 1× (fullscreen: owner, 2026-10-21, "some margin around them").
    var inset: CGFloat = 0
    func makeUIView(context: Context) -> FigureZoomScroll { FigureZoomScroll(image: image, inset: inset) }
    func updateUIView(_ view: FigureZoomScroll, context: Context) { view.setImage(image) }
}

final class FigureZoomScroll: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var pixels: CGImage
    private var laidOut = CGSize.zero
    private let inset: CGFloat
    init(image: CGImage, inset: CGFloat = 0) {
        pixels = image; self.inset = inset
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
        let fit = min(max(1, bounds.width - 2 * inset) / CGFloat(pixels.width), max(1, bounds.height - 2 * inset) / CGFloat(pixels.height))
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

/// A part card as a viewport into the whole figure (owner, 2026-10-21: "present it as a crop of the whole thing, that they
/// can expand, rather than an actual crop"; FIGURE_VIEW.md "Parts as viewports"). The whole figure, on its white margin,
/// is zoomed and placed so the part's frame (FigureFraming) fills the card: a tight frame looks as a crop did, a loose one
/// shows some of the figure around the part (softly veiled, the part outlined), a low one the whole figure with the part
/// outlined. Pinching moves the view over the whole figure (out to all of it, in to 8×); once pinched, it pans; a double
/// tap returns to the frame; a tap expands to the whole figure. At the frame the card doesn't pan, so the page scrolls.
struct FigureViewport: UIViewRepresentable {
    let image: CGImage
    let part: FramedPart
    /// Fullscreen: the view starts on the part's frame and widens to the whole figure (`showPart` frames the part again).
    var fullscreen = false
    var showPart = false
    /// The card's framing record (FigureFramingRecorder), and its key for Save snippet.
    var recordKey: String?
    var snippetKey: String?
    var onTap: (() -> Void)?
    func makeUIView(context: Context) -> FigureViewportScroll {
        FigureViewportScroll(image: image, part: part, fullscreen: fullscreen, recordKey: recordKey, snippetKey: snippetKey, onTap: onTap)
    }
    func updateUIView(_ view: FigureViewportScroll, context: Context) {
        view.onTap = onTap
        if fullscreen { view.show(part: showPart) }
    }
}

final class FigureViewportScroll: UIScrollView, UIScrollViewDelegate {
    /// The cards on screen by their snippet key (Save snippet draws what one shows).
    static let shown = NSMapTable<NSString, FigureViewportScroll>.strongToWeakObjects()
    private let canvas = UIView(), picture = UIImageView(), veil = CAShapeLayer(), outline = CAShapeLayer()
    private let pixels: CGImage, part: FramedPart, fullscreen: Bool, recordKey: String?
    var onTap: (() -> Void)?
    private var laidOut = CGSize.zero, restZoom: CGFloat = 1, interacted = false, wantsPart = false, widened = false
    private let pad: CGSize
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    init(image: CGImage, part: FramedPart, fullscreen: Bool, recordKey: String?, snippetKey: String?, onTap: (() -> Void)?) {
        pixels = image; self.part = part; self.fullscreen = fullscreen; self.recordKey = recordKey; self.onTap = onTap
        pad = CGSize(width: part.padX * Double(image.width), height: part.padY * Double(image.height))
        super.init(frame: .zero)
        delegate = self; bounces = false; bouncesZoom = false; contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false; backgroundColor = .white
        canvas.backgroundColor = .white
        canvas.frame = CGRect(x: 0, y: 0, width: CGFloat(image.width) + 2 * pad.width, height: CGFloat(image.height) + 2 * pad.height)
        picture.image = UIImage(cgImage: image)
        picture.frame = CGRect(x: pad.width, y: pad.height, width: CGFloat(image.width), height: CGFloat(image.height))
        canvas.addSubview(picture)
        veil.fillRule = .evenOdd; veil.fillColor = UIColor.white.cgColor
        outline.fillColor = nil; outline.strokeColor = FigurePartCrop.outline
        canvas.layer.addSublayer(veil); canvas.layer.addSublayer(outline)
        let region = regionRect
        veil.path = { let p = UIBezierPath(rect: canvas.bounds.insetBy(dx: -4000, dy: -4000)); p.append(UIBezierPath(rect: region)); return p.cgPath }()
        addSubview(canvas)
        panGestureRecognizer.isEnabled = fullscreen
        isAccessibilityElement = true; accessibilityTraits = [.image, .adjustable]
        accessibilityHint = fullscreen ? "Pinch to zoom, drag to pan." : "Shows the whole figure with this part outlined. Pinch to zoom; double tap to return."
        accessibilityValue = "100%"
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:))); doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        if !fullscreen {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped)); tap.require(toFail: doubleTap)
            addGestureRecognizer(tap)
        }
        if let snippetKey { Self.shown.setObject(self, forKey: snippetKey as NSString) }
        applyLook()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The part's region and the rest frame, in canvas points (1 point = 1 pixel of the figure at zoom 1).
    private var regionRect: CGRect { rect(part.region) }
    private func rect(_ r: CropRect) -> CGRect {
        let W = Double(pixels.width), H = Double(pixels.height)
        return CGRect(x: r.x0 * W + pad.width, y: r.y0 * H + pad.height, width: (r.x1 - r.x0) * W, height: (r.y1 - r.y0) * H)
    }
    /// The frame grown to the view's shape about its centre (fullscreen's box is the whole figure's shape).
    private func fitted(_ r: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return r }
        let aspect = bounds.width / bounds.height, w = r.width / r.height > aspect ? r.width : r.height * aspect
        return CGRect(x: r.midX - w / 2, y: r.midY - w / aspect / 2, width: w, height: w / aspect)
    }
    private var restRect: CGRect { fitted(rect(part.frame)) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOut, bounds.width > 0, bounds.height > 0 else { return }
        laidOut = bounds.size
        let rest = restRect, whole = canvas.frame.size == .zero ? CGSize(width: 1, height: 1) : CGSize(width: canvas.bounds.width, height: canvas.bounds.height)
        restZoom = bounds.width / rest.width
        let fit = min(bounds.width / whole.width, bounds.height / whole.height)
        minimumZoomScale = min(fit, restZoom); maximumZoomScale = restZoom * 8
        if fullscreen && widened && !wantsPart { showWhole(animated: false) } else if !interacted || fullscreen { goTo(rest, animated: false) }
        if fullscreen && !widened {
            widened = true
            // Opens on the part's frame, then widens to the whole figure (at once with Reduce Motion).
            if reduceMotion { showWhole(animated: false) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in if self?.wantsPart == false { self?.showWhole(animated: true) } } }
        }
    }

    private func goTo(_ r: CGRect, animated: Bool) {
        let zoom = min(maximumZoomScale, max(minimumZoomScale, bounds.width / r.width))
        let apply = { [self] in
            setZoomScale(zoom, animated: false)
            centre()
            setContentOffset(CGPoint(x: r.minX * zoom - contentInset.left, y: r.minY * zoom - contentInset.top), animated: false)
            clampOffset()
        }
        if animated { UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseInOut], animations: apply) } else { apply() }
        updateValue()
    }
    private func showWhole(animated: Bool) { goTo(fitted(canvas.bounds), animated: animated) }
    /// Fullscreen's Show part / Whole figure.
    func show(part showing: Bool) {
        guard showing != wantsPart else { return }
        wantsPart = showing
        guard laidOut != .zero else { return }
        if showing { goTo(restRect, animated: !reduceMotion) } else { showWhole(animated: !reduceMotion) }
        if !showing, let recordKey { FigureFramingRecorder.shared.changed(recordKey, expanded: true) }
    }

    private func clampOffset() {
        let maxX = max(-contentInset.left, contentSize.width - bounds.width), maxY = max(-contentInset.top, contentSize.height - bounds.height)
        contentOffset = CGPoint(x: min(maxX, max(-contentInset.left, contentOffset.x)), y: min(maxY, max(-contentInset.top, contentOffset.y)))
    }
    private func centre() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { reveal() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre(); applyLook(); updateValue() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { record(zoomed: true) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { record(panned: true) } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { record(panned: true) }

    private func reveal() {
        guard !interacted else { return }
        interacted = true; panGestureRecognizer.isEnabled = true; applyLook()
    }
    private func applyLook() {
        let look = part.look(revealed: interacted || fullscreen)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        veil.fillColor = UIColor.white.withAlphaComponent(look.veil).cgColor; veil.isHidden = look.veil <= 0
        outline.isHidden = !look.outlined
        let line = 2 / max(zoomScale, 0.01)
        outline.lineWidth = line; outline.path = UIBezierPath(rect: regionRect.insetBy(dx: -line, dy: -line)).cgPath
        CATransaction.commit()
    }
    private func updateValue() { accessibilityValue = "\(Int((zoomScale / max(restZoom, 0.0001) * 100).rounded()))%" }

    /// What the view shows, in pixels of the figure (it may reach into the white margin).
    private var visible: CropRect {
        let z = max(zoomScale, 0.0001), x = (contentOffset.x) / z - pad.width, y = (contentOffset.y) / z - pad.height
        return CropRect(Double(x), Double(y), Double(x + bounds.width / z), Double(y + bounds.height / z))
    }
    private func record(zoomed: Bool = false, panned: Bool = false) {
        guard let recordKey else { return }
        let v = visible, W = Double(pixels.width), H = Double(pixels.height)
        FigureFramingRecorder.shared.changed(recordKey, view: CropRect(v.x0 / W, v.y0 / H, v.x1 / W, v.y1 / H), zoomed: zoomed, panned: panned)
    }

    /// What the card shows (Save snippet): the figure at its own resolution or the card's on-screen pixels, whichever is
    /// larger, with the veil and outline as shown.
    func visibleImage() -> CGImage? {
        let v = visible, screen = window?.screen.scale ?? 2, z = max(zoomScale, 0.0001)
        let scale = max(1, Double(bounds.width * screen) / max(1, v.x1 - v.x0))
        return part.render(pixels, view: v, scale: scale, revealed: interacted || fullscreen, outline: FigurePartCrop.outline, lineWidth: 2 * scale / Double(z))
    }

    @objc private func tapped() { onTap?(); if let recordKey { FigureFramingRecorder.shared.changed(recordKey, expanded: true) } }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if interacted && !fullscreen {
            interacted = false; panGestureRecognizer.isEnabled = false
            goTo(restRect, animated: !reduceMotion); applyLook(); record()
        } else {
            reveal()
            let at = gesture.location(in: canvas), size = CGSize(width: bounds.width / (zoomScale * 2), height: bounds.height / (zoomScale * 2))
            zoom(to: CGRect(x: at.x - size.width / 2, y: at.y - size.height / 2, width: size.width, height: size.height), animated: !reduceMotion)
        }
    }
    override func accessibilityActivate() -> Bool { guard let onTap else { return false }; onTap(); return true }
    override func accessibilityIncrement() { reveal(); setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: false); record(zoomed: true) }
    override func accessibilityDecrement() { reveal(); setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: false); record(zoomed: true) }
}

struct FigureImagePresentation: Identifiable {
    let id = UUID()
    /// The whole figure.
    let image: CGImage
    /// A part card's framing: fullscreen opens on it and widens to the whole figure, the part outlined.
    var part: FramedPart?
    let label: String
    var recordKey: String?
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
    /// A part's fullscreen opens on its frame and widens to the whole figure; Show part frames it again.
    @State private var showPart = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(image.label).font(.headline)
                Spacer()
                if image.part != nil {
                    Button(showPart ? "Whole figure" : "Show part") { showPart.toggle() }
                }
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close fullscreen image").accessibilityIdentifier("figureView.fullscreen.close")
                    .keyboardShortcut(.escape, modifiers: [])
            }.padding(.horizontal, 16)
            Group {
                if let part = image.part {
                    // The whole figure's shape, inside 16 pt of the screen's edges, the part outlined.
                    FigureViewport(image: image.image, part: part, fullscreen: true, showPart: showPart, recordKey: image.recordKey)
                        .aspectRatio((Double(image.image.width) * (1 + 2 * part.padX)) / (Double(image.image.height) * (1 + 2 * part.padY)), contentMode: .fit)
                        .padding(16)
                        .accessibilityLabel(image.label)
                } else {
                    ZoomableFigureImage(image: image.image, inset: 16)
                }
            }
            .accessibilityIdentifier("figureView.fullscreen.image")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Pinch to zoom · Drag to pan · Double tap to reset").font(.footnote).foregroundStyle(.secondary).padding(12)
        }.background(Color(uiColor: .systemBackground)).macSheetKeys()
    }
}

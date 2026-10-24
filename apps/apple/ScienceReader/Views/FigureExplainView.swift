import ScienceReaderCore
import SwiftUI
import UIKit
import WebKit

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
/// A figure page's way to open the figure's PDF page full screen (a pinch outwards on it; FIGURE_VIEW.md "Zoom out onto
/// the page"); nil unless the figure has one on this device.
private struct FigurePageZoomOutKey: EnvironmentKey { nonisolated(unsafe) static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    var figurePageZoomOut: (@MainActor () -> Void)? {
        get { self[FigurePageZoomOutKey.self] }
        set { self[FigurePageZoomOutKey.self] = newValue }
    }
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
    /// The figure full screen on its PDF page (a pinch outwards on a figure the on-device model cut from a PDF here).
    @State private var expandedImage: FigureImagePresentation?

    /// Drawing a snippet over this figure page (Add to note: the whole item first, then adjust).
    private var capturing: Bool { host?.model.notes.capturing == .figure }
    private var paper: Paper? { host.flatMap { host in host.model.papers.first { $0.id == host.paperID } ?? host.model.selectedPaper } }

    func body(content: Content) -> some View {
        content
            .modifier(FigurePageZoomOutHost(zoomOut: zoomOut, image: $expandedImage))
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
            .slotSheet(isPresented: $choosingAI) {
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

    /// Opens the figure's PDF page full screen; nil without one (or while drawing a snippet).
    private var zoomOut: (@MainActor () -> Void)? {
        guard context?.pdfPage != nil, !capturing else { return nil }
        return { showPage() }
    }

    /// The figure full screen, zooming out onto its PDF page at once (the figure's own image is decoded off the main actor).
    private func showPage() {
        guard expandedImage == nil, let context, let page = context.pdfPage,
              let figure = context.bundle.index.figures.first(where: { $0.id == context.figureID }) else { return }
        let bundle = context.bundle
        Task { @MainActor in
            let prepared = await Task.detached(priority: .userInitiated) { ChatFigureFinder.prepared(figure, bundle: bundle) }.value
            guard let image = prepared.image, let page = FigureImagePresentation.page(page, for: image) else { return }
            presentFigureImage { expandedImage = FigureImagePresentation(image: image, part: nil, label: context.label, page: page, startOnPage: true) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .slotSheet(isPresented: $choosingAI) {
            AIChoiceView(model: model, chat: true, needsVision: true) { id in
                model.localAIModelID = id; session?.stop()
                let opened = FigureExplainSession(context: context, model: model); session = opened
                Task { await opened.start() }
            }
        }
        .slotSheet(isPresented: Binding(get: { session?.asksConsent ?? false }, set: { if !$0, session?.asksConsent == true { session?.declineConsent() } })) {
            CloudConsentContent(accept: { session?.acceptConsent() }, decline: { session?.declineConsent() })
                .sheetDetent(.large)
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

    /// Opens the full-screen figure from a card (FIGURE_VIEW.md "Full screen on touch"): at once, from the card's own place
    /// (`at`, window coordinates), recording how (the local framing record).
    /// `toPage`: a pinch outwards on the card opens onto the figure's PDF page, when it has one (FIGURE_VIEW.md "Zoom out
    /// onto the page").
    private func open(_ image: CGImage, part: FramedPart?, label: String, identifier: String, recordKey: String?,
                      _ gesture: FigureFramingRecord.OpenGesture, at rect: CGRect?, toPage: Bool = false) {
        if let recordKey { FigureFramingRecorder.shared.changed(recordKey, opened: gesture) }
        let card = FigureViewportScroll.shown.object(forKey: identifier as NSString)
        let source = rect ?? card.flatMap { $0.window == nil ? nil : $0.convert($0.bounds, to: nil) }
        let page = FigureImagePresentation.page(context.pdfPage, for: image)
        presentFigureImage { expandedImage = FigureImagePresentation(image: image, part: part, label: label, recordKey: recordKey, source: source, sourceKey: identifier,
                                                                    page: page, startOnPage: toPage && page != nil) }
    }

    /// A card that opens full screen when touched (the whole figure, or a part framed by confidence: FIGURE_VIEW.md "Parts as
    /// viewports"), its aspect the frame's, with a Full screen button under it, never over it (2026-10-21: the round button
    /// hid each crop's title).
    private func partCard(_ part: FramedPart?, image: CGImage, label: String, identifier: String, maxHeight: CGFloat, recordKey: String?) -> some View {
        let W = Double(image.width), H = Double(image.height), shown = part ?? .whole(width: image.width, height: image.height)
        let frameWidth = (shown.frame.x1 - shown.frame.x0) * W, frameHeight = (shown.frame.y1 - shown.frame.y0) * H
        let expand = { (gesture: FigureFramingRecord.OpenGesture, rect: CGRect?, toPage: Bool) in
            open(image, part: part, label: label, identifier: identifier, recordKey: recordKey, gesture, at: rect, toPage: toPage)
        }
        return VStack(alignment: .trailing, spacing: 4) {
            FigureViewport(image: image, part: shown, recordKey: recordKey, snippetKey: identifier, onOpen: { gesture, rect, out in expand(gesture, rect, out) })
                .id(identifier + "\(shown.frame)")
                .aspectRatio(frameWidth / frameHeight, contentMode: .fit)
                .accessibilityLabel(label).accessibilityIdentifier(identifier)
            Button { expand(.button, nil, false) } label: {
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
                // Figures are drawn on white in the paper; keep that in dark mode too. Touched, it opens full screen.
                partCard(nil, image: image, label: context.label, identifier: "figureView.figure", maxHeight: 300, recordKey: nil).id(context.figureID)
            }
            ChatMessageText(source: context.caption, fontSize: bodySize * 0.82, streaming: false, speaker: "Caption", identifier: "figureView.caption")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    // MARK: The walkthrough

    /// The walkthrough as it arrives (FIGURE_VIEW.md "Progress"): at once a progress bar with its stage and placeholders
    /// where the summary and a part will be; then the summary, then each part appended in order with the bar below the last
    /// one (where the next appears), so nothing above it moves; the bar fades when the walkthrough is done (at once with
    /// Reduce Motion). The coverage note and "Not charged." come once it is done, after the parts.
    @ViewBuilder private func walkthrough(_ session: FigureExplainSession) -> some View {
        let part = session.walkthrough, loading = part.state == .loading
        VStack(alignment: .leading, spacing: 16) {
            if let walkthrough = part.walkthrough {
                if !walkthrough.summary.isEmpty {
                    ChatMessageText(source: walkthrough.summary, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                    identifier: "figureView.summary", assistant: true, onCite: cite)
                }
                ForEach(Array(walkthrough.sections.prefix(loading ? session.shownSections : walkthrough.sections.count).enumerated()), id: \.offset) { index, section in
                    sectionCard(section, index: index, session: session, ready: !loading)
                }
                if !loading, let coverage = session.inkCoverage, coverage < 1 {
                    Text("The detail cards do not cover the entire image. The whole figure above keeps every panel, axis and legend available.")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("figureView.coverageFallback")
                }
                if part.state == .done, part.notCharged {
                    Text("This walkthrough stopped before the end. Not charged.")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("figureView.notCharged")
                }
            } else if !part.text.isEmpty, part.state == .done || session.localModelID != nil {
                // No usable walkthrough: the model's words are the description.
                ChatMessageText(source: part.text, fontSize: bodySize, streaming: part.state == .loading, speaker: "Assistant", identifier: "figureView.description",
                                assistant: true, onCite: cite)
            }
            if loading, let progress = session.progress {
                FigureProgressBar(state: progress).transition(.opacity)
                FigureWalkthroughSkeleton(summary: (part.walkthrough?.summary ?? "").isEmpty && part.text.isEmpty).transition(.opacity)
            }
            status(part, working: context.isDrawnTable || context.label.hasPrefix("Table") ? "Looking at the table…" : "Looking at the figure…",
                   showsLoading: session.progress == nil, retry: { session.retry() })
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: session.progress == nil)
        .onChange(of: session.progress?.label) { _, label in
            // VoiceOver hears each new stage ("Writing part 2 of 3…"), not every step of the bar.
            if let label, UIAccessibility.isVoiceOverRunning { AccessibilityNotification.Announcement(label).post() }
        }
    }

    private func sectionCard(_ section: FigureWalkthrough.Section, index: Int, session: FigureExplainSession, ready: Bool) -> some View {
        let number = index + 1, simpler = session.simpler[index]
        return VStack(alignment: .leading, spacing: 10) {
            // A tap on the part's heading opens its menu (owner: "tap on different parts of the response and ask to back
            // up a bit, or link back into the paper"); a long press or right-click anywhere on the part does too. While the
            // walkthrough is still being written its parts' menus wait (their actions need the final walkthrough).
            // The heading looks the same either way (only the ⋯ waits, faint), so nothing changes but the ⋯ when it is done.
            let heading = HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.headingLabel)
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Text(section.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "ellipsis.circle").foregroundStyle(ready ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            if ready {
                Menu { menuItems(section, index: index, session: session) } label: { heading }
                    .buttonStyle(.plain)
                    .accessibilityLabel([section.label, section.title].filter { !$0.isEmpty }.joined(separator: ": "))
                    .accessibilityHint("Options for this part")
                    .accessibilityIdentifier("figureView.section.\(number).menu")
            } else {
                heading
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel([section.label, section.title].filter { !$0.isEmpty }.joined(separator: ": "))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("figureView.section.\(number).menu")
            }
            if section.cardKind == .panel, let part = session.framed[index], let image = session.image {
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
        .contextMenu { if ready { menuItems(section, index: index, session: session) } }
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

    @ViewBuilder private func status(_ part: FigureExplainSession.Part, working: String, showsLoading: Bool = true, retry: @escaping () -> Void) -> some View {
        switch part.state {
        case .loading where part.text.isEmpty && showsLoading:
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

/// The walkthrough's progress bar (FigureProgress): the stage in words over a bar, filled while the number of parts is
/// known, else moving. One accessibility element: the stage is its label, the share its value (none while indeterminate).
struct FigureProgressBar: View {
    let state: FigureProgress.State
    var identifier = "figureView.progress"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.label).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let value = state.value {
                ProgressView(value: value)
            } else {
                FigureIndeterminateBar(moving: !reduceMotion)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .accessibilityValue(state.value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier(identifier)
    }
}

/// An indeterminate bar the same height and tint as `ProgressView(value:)`'s: a short segment that sweeps across the
/// track, or (Reduce Motion) a still, partly filled track.
private struct FigureIndeterminateBar: View {
    let moving: Bool
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, segment = max(40, width * 0.28)
            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .systemFill))
                if moving {
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(Color.accentColor).frame(width: segment).offset(x: -segment + (width + segment) * phase)
                    }
                } else {
                    Capsule().fill(Color.accentColor.opacity(0.45)).frame(width: segment)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

/// Where the walkthrough will appear while it is asked for: summary lines (until the summary arrives) and the next part's
/// card. Still under Reduce Motion, else a slow pulse. Hidden from VoiceOver (the progress bar says where it is); the
/// journeys find it in fixture builds.
private struct FigureWalkthroughSkeleton: View {
    let summary: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if summary {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach([1.0, 0.94, 0.62], id: \.self) { share in line.frame(maxWidth: .infinity, alignment: .leading).scaleEffect(x: share, y: 1, anchor: .leading) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(width: 90, height: 11)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(width: 180, height: 15)
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(height: 120)
                line; line.scaleEffect(x: 0.8, y: 1, anchor: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .opacity(dim ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
        }
        .onChange(of: reduceMotion) { _, still in if still { dim = false } }
        .modifier(SkeletonAccessibility(identifier: "figureView.skeleton"))
    }

    private var line: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(height: 12)
    }
}

struct SkeletonAccessibility: ViewModifier {
    let identifier: String
    func body(content: Content) -> some View {
        #if DEBUG && FIXTURE_HOST
        content.accessibilityElement(children: .ignore).accessibilityIdentifier(identifier)
        #else
        content.accessibilityHidden(true)
        #endif
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
/// is placed so the part's frame (FigureFraming) fills the card: a tight frame looks as a crop did, a loose one shows some
/// of the figure around the part (softly veiled, the part outlined), a low one the whole figure with the part outlined.
///
/// Full screen on touch (owner, 2026-10-22: "whenever you try to interact with it, it becomes a full screen thing … with
/// not really any in-between"; FIGURE_VIEW.md "Full screen on touch"): the card itself never zooms or pans (the page
/// scrolls over it). A tap, a double tap, a pinch, a sideways drag, VoiceOver's activate or the Full screen button opens
/// the full-screen viewer at once, from the card's own place and framing (`FigureFullscreenStage`).
struct FigureViewport: UIViewRepresentable {
    let image: CGImage
    let part: FramedPart
    /// The card's framing record (FigureFramingRecorder), and its key for Save snippet and for closing back onto it.
    var recordKey: String?
    var snippetKey: String?
    /// How the reader opened it, and where the card is (window coordinates).
    var onOpen: ((FigureFramingRecord.OpenGesture, CGRect, Bool) -> Void)?
    func makeUIView(context: Context) -> FigureViewportScroll {
        FigureViewportScroll(image: image, part: part, fullscreen: false, outlines: true, recordKey: recordKey, snippetKey: snippetKey, onOpen: onOpen)
    }
    func updateUIView(_ view: FigureViewportScroll, context: Context) { view.onOpen = onOpen }
}

/// A figure page whose figure has its PDF page on this device: a pinch outwards on it (`FigurePagePinch`) or VoiceOver's
/// "Show the whole page" opens the figure full screen on its page.
private struct FigurePageZoomOutHost: ViewModifier {
    let zoomOut: (@MainActor () -> Void)?
    @Binding var image: FigureImagePresentation?
    func body(content: Content) -> some View {
        content
            // In the actions, not around the content: the figure page's web view is never made again.
            .accessibilityActions { if let zoomOut { Button("Show the whole page") { zoomOut() } } }
            .environment(\.figurePageZoomOut, zoomOut)
            .modifier(FigureImageCover(image: $image))
    }
}

/// A figure page's pinch outwards (FIGURE_VIEW.md "Zoom out onto the page"): alongside the web view's own zoom, once a
/// gesture, when the page is not zoomed in, it calls `action` (set only for a figure with its PDF page on this device).
@MainActor final class FigurePagePinch: NSObject, UIGestureRecognizerDelegate {
    var action: (@MainActor () -> Void)?
    private weak var web: WKWebView?
    private var fired = false
    func attach(to web: WKWebView) {
        self.web = web
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))); pinch.delegate = self
        web.addGestureRecognizer(pinch)
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: fired = false
        case .changed:
            guard !fired, let action, gesture.scale < 0.85, let scroll = web?.scrollView, scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return }
            fired = true; action()
        default: break
        }
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Decides for one view's own gesture recognizers (UIView's `gestureRecognizerShouldBegin` is the view's, so these live
/// apart): whether one may begin, and whether it may run alongside the page's scrolling.
final class FigureGestureFilter: NSObject, UIGestureRecognizerDelegate {
    var shouldBegin: (UIGestureRecognizer) -> Bool = { _ in true }
    var simultaneous = false
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool { shouldBegin(gesture) }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { simultaneous }
}

final class FigureViewportScroll: UIScrollView, UIScrollViewDelegate {
    /// The cards on screen by their snippet key (Save snippet draws what one shows; full screen closes back onto it).
    static let shown = NSMapTable<NSString, FigureViewportScroll>.strongToWeakObjects()
    private let canvas = UIView(), picture = UIImageView()
    /// The veil and outline, each in its own layer so full screen can fade them (`lookLayer`).
    private let lookLayer = CALayer(), veil = CAShapeLayer(), outline = CAShapeLayer()
    let pixels: CGImage, part: FramedPart
    private let fullscreen: Bool, outlines: Bool, recordKey: String?
    /// How the card was opened, where it is, and whether the pinch was outwards (to the page, when there is one).
    var onOpen: ((FigureFramingRecord.OpenGesture, CGRect, Bool) -> Void)?
    /// Full screen: the zoom state changed (true at the whole figure), for the Whole figure / Show part control.
    var onWhole: ((Bool) -> Void)?
    /// Full screen: the PDF page shown around the figure, or not (the top row's page control).
    var onPage: ((Bool) -> Void)?
    private var laidOut = CGSize.zero
    private(set) var restZoom: CGFloat = 1
    private let pad: CGSize
    private let filter = FigureGestureFilter()

    // The page under the figure (FIGURE_VIEW.md "Zoom out onto the page"; full screen, a figure the on-device route cut
    // from a PDF on this device). The canvas then holds the page, the image placed exactly on its crop; until the reader
    // zooms out past the whole figure everything looks and pans as without it (the figure on its white margin, `backing`).
    private let page: FigurePDFPage?, layout: FigurePageLayout?
    private let pageView = UIImageView(), backing = UIView(), cropOutline = CAShapeLayer()
    /// Where the image's top-left corner sits in the canvas (its white margin's width without a page).
    private let imageOrigin: CGPoint
    private var pageRequested = false
    private(set) var pageShown = false
    var hasPage: Bool { layout != nil }

    init(image: CGImage, part: FramedPart, fullscreen: Bool, outlines: Bool, recordKey: String?, snippetKey: String?, page: FigurePDFPage? = nil,
         onOpen: ((FigureFramingRecord.OpenGesture, CGRect, Bool) -> Void)?) {
        pixels = image; self.part = part; self.fullscreen = fullscreen; self.outlines = outlines; self.recordKey = recordKey; self.onOpen = onOpen
        pad = CGSize(width: part.padX * Double(image.width), height: part.padY * Double(image.height))
        let layout = fullscreen ? page.flatMap { FigurePageLayout(region: $0.region, imageWidth: image.width, imageHeight: image.height) } : nil
        self.layout = layout; self.page = layout == nil ? nil : page
        let placed = layout?.canvas(pad: pad)
        imageOrigin = placed?.imageOrigin ?? CGPoint(x: pad.width, y: pad.height)
        super.init(frame: .zero)
        delegate = self; bounces = false; bouncesZoom = false; contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false; backgroundColor = .white
        canvas.backgroundColor = .white
        canvas.frame = CGRect(origin: .zero, size: placed?.size ?? CGSize(width: CGFloat(image.width) + 2 * pad.width, height: CGFloat(image.height) + 2 * pad.height))
        picture.image = UIImage(cgImage: image)
        picture.frame = CGRect(x: imageOrigin.x, y: imageOrigin.y, width: CGFloat(image.width), height: CGFloat(image.height))
        if let layout {
            // The page (white until drawn) and the figure's own margin, the page hidden until the reader zooms out.
            canvas.backgroundColor = .clear
            pageView.backgroundColor = .white; pageView.alpha = 0; pageView.contentMode = .scaleToFill
            pageView.frame = layout.page.offsetBy(dx: imageOrigin.x, dy: imageOrigin.y)
            backing.backgroundColor = .white; backing.frame = figureBox
            canvas.addSubview(pageView); canvas.addSubview(backing)
        }
        canvas.addSubview(picture)
        for view in [self, canvas, picture, pageView, backing] { view.isMultipleTouchEnabled = true }
        veil.fillRule = .evenOdd; veil.fillColor = UIColor.white.cgColor
        outline.fillColor = nil; outline.strokeColor = FigurePartCrop.outline
        lookLayer.frame = canvas.bounds
        lookLayer.addSublayer(veil); lookLayer.addSublayer(outline); canvas.layer.addSublayer(lookLayer)
        // On the page, the crop stays faintly outlined in the parts' outline colour.
        cropOutline.fillColor = nil; cropOutline.strokeColor = FigurePartCrop.outline.copy(alpha: 0.55); cropOutline.isHidden = true
        canvas.layer.addSublayer(cropOutline)
        let region = regionRect, box = figureBox
        veil.path = { let p = UIBezierPath(rect: box); p.append(UIBezierPath(rect: region)); return p.cgPath }()
        addSubview(canvas)
        isAccessibilityElement = true
        if fullscreen {
            accessibilityTraits = [.image, .adjustable]
            accessibilityHint = layout == nil ? "Pinch to zoom, drag to pan, double tap for the whole figure or the part."
                : "Pinch to zoom, drag to pan; zoom out past the figure for its page in the PDF. Double tap for the whole figure or the part."
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:))); doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            updateActions()
        } else {
            // The card: nothing zooms or pans here; any of these opens full screen at once.
            accessibilityTraits = [.image, .button]
            accessibilityHint = "Opens the whole figure full screen."
            isScrollEnabled = false; pinchGestureRecognizer?.isEnabled = false
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped)); addGestureRecognizer(tap)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))); pinch.delegate = filter; addGestureRecognizer(pinch)
            let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))); drag.delegate = filter; drag.maximumNumberOfTouches = 1
            addGestureRecognizer(drag)
            // A sideways drag opens; an up-or-down one is the page's scroll (which runs alongside until then).
            filter.simultaneous = true
            filter.shouldBegin = { [weak self] gesture in
                guard let self, let pan = gesture as? UIPanGestureRecognizer else { return true }
                let v = pan.velocity(in: self)
                return abs(v.x) > abs(v.y) * 1.2
            }
        }
        if let snippetKey { Self.shown.setObject(self, forKey: snippetKey as NSString) }
        applyLook()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The part's region and a frame, in canvas points (1 point = 1 pixel of the figure at zoom 1).
    var regionRect: CGRect { rect(part.region) }
    var frameRect: CGRect { rect(part.frame) }
    private func rect(_ r: CropRect) -> CGRect {
        let W = Double(pixels.width), H = Double(pixels.height)
        return CGRect(x: r.x0 * W + imageOrigin.x, y: r.y0 * H + imageOrigin.y, width: (r.x1 - r.x0) * W, height: (r.y1 - r.y0) * H)
    }
    /// The figure on its white margin, in canvas points (the whole canvas without a page).
    private var figureBox: CGRect {
        CGRect(x: imageOrigin.x - pad.width, y: imageOrigin.y - pad.height, width: CGFloat(pixels.width) + 2 * pad.width, height: CGFloat(pixels.height) + 2 * pad.height)
    }
    /// The frame grown to the view's shape about its centre.
    private func fitted(_ r: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return r }
        return FigureZoomMath.fitted(r, to: bounds.size)
    }
    private var restRect: CGRect { fitted(frameRect) }
    /// The zoom at which the whole figure fits (full screen's smallest without a page).
    var wholeZoom: CGFloat { FigureZoomMath.fitZoom(figureBox, in: bounds.size) }
    /// The zoom at which the whole page fits (full screen's smallest with one).
    private var pageZoom: CGFloat { FigureZoomMath.fitZoom(canvas.bounds, in: bounds.size) }
    var showsWhole: Bool { zoomScale <= wholeZoom * 1.01 }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOut, bounds.width > 0, bounds.height > 0 else { return }
        laidOut = bounds.size
        restZoom = bounds.width / restRect.width
        if fullscreen {
            // Zoom limits sized to the whole figure: out to all of it (to its whole page, with one), in to 8× that (at
            // least 3× the part's own frame).
            minimumZoomScale = min(wholeZoom, restZoom, hasPage ? pageZoom : .greatestFiniteMagnitude); maximumZoomScale = max(wholeZoom * 8, restZoom * 3)
            // With a page, the view is held to the figure (or the page) by `hold`, so it may reach past the canvas's edges.
            if hasPage { contentInset = UIEdgeInsets(top: bounds.height, left: bounds.width, bottom: bounds.height, right: bounds.width) }
        } else {
            minimumZoomScale = restZoom; maximumZoomScale = restZoom
        }
        if pageShown { showPage(animated: false) } else { goTo(restRect, animated: false) }
    }

    /// Shows `r` (canvas points), fitted to the view; inside an animation block it animates with it.
    func goTo(_ r: CGRect, animated: Bool, duration: TimeInterval = 0.4) {
        let zoom = min(maximumZoomScale, max(minimumZoomScale, bounds.width / r.width))
        let apply = { [self] in
            setZoomScale(zoom, animated: false)
            if hasPage {
                contentOffset = FigureZoomMath.clampedOffset(CGPoint(x: r.minX * zoom, y: r.minY * zoom), zoom: zoom, view: bounds.size, bounds: holdBounds)
            } else {
                centre()
                setContentOffset(CGPoint(x: r.minX * zoom - contentInset.left, y: r.minY * zoom - contentInset.top), animated: false)
                clampOffset()
            }
        }
        if animated { UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: apply) } else { apply() }
        applyLook(); updateValue(); onWhole?(showsWhole)
    }
    func showPart(animated: Bool) { leavePage(animated: animated); goTo(restRect, animated: animated) }
    func showWhole(animated: Bool) { leavePage(animated: animated); goTo(fitted(figureBox), animated: animated) }
    /// The whole page around the figure, fitted (the top row's page control, VoiceOver's "Show the whole page").
    func showPage(animated: Bool) {
        guard hasPage else { return }
        enterPage(animated: animated)
        goTo(fitted(canvas.bounds), animated: animated)
    }
    /// Where the part's frame is now, in `view`'s coordinates (the card's matched geometry).
    func frameOnScreen(in view: UIView) -> CGRect { canvas.convert(frameRect, to: view) }

    private func clampOffset() {
        let maxX = max(-contentInset.left, contentSize.width - bounds.width), maxY = max(-contentInset.top, contentSize.height - bounds.height)
        contentOffset = CGPoint(x: min(maxX, max(-contentInset.left, contentOffset.x)), y: min(maxY, max(-contentInset.top, contentOffset.y)))
    }
    private func centre() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }
    /// With a page: what the view is held to, the figure on its margin (as without a page) until the page shows, then
    /// the whole canvas.
    private var holdBounds: CGRect { pageShown ? canvas.bounds : figureBox }
    private func hold() {
        guard hasPage, bounds.width > 0 else { return }
        let held = FigureZoomMath.clampedOffset(contentOffset, zoom: zoomScale, view: bounds.size, bounds: holdBounds)
        if abs(held.x - contentOffset.x) > 0.01 || abs(held.y - contentOffset.y) > 0.01 { contentOffset = held }
    }
    /// At the top edge (a swipe down there closes full screen rather than panning).
    var atTop: Bool {
        guard hasPage else { return contentOffset.y <= -contentInset.top + 1 }
        return contentOffset.y <= FigureZoomMath.clampedOffset(CGPoint(x: contentOffset.x, y: -1e9), zoom: zoomScale, view: bounds.size, bounds: holdBounds).y + 1
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if hasPage {
            // Past the whole figure the page shows around it, and stays until the reader goes back to the figure.
            if !pageShown, zoomScale < min(wholeZoom, restZoom) * 0.995 { enterPage(animated: true) }
            hold()
        } else { centre() }
        applyLook(); updateValue(); onWhole?(showsWhole)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { hold() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { record(zoomed: true) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { record(panned: true) } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { record(panned: true) }

    /// The page fades in around the figure (drawn now, the first time), the crop outlined on it.
    private func enterPage(animated: Bool) {
        guard hasPage, !pageShown else { return }
        pageShown = true
        requestPage()
        let show = { [self] in pageView.alpha = 1; backing.alpha = 0 }
        if animated, !UIAccessibility.isReduceMotionEnabled { UIView.animate(withDuration: 0.25, animations: show) } else { show() }
        applyLook(); updateValue(); updateActions(); onPage?(true)
    }
    /// Back to the figure: the page fades and the view is held to the figure again.
    private func leavePage(animated: Bool) {
        guard pageShown else { return }
        pageShown = false
        let hide = { [self] in pageView.alpha = 0; backing.alpha = 1 }
        if animated, !UIAccessibility.isReduceMotionEnabled { UIView.animate(withDuration: 0.3, animations: hide) } else { hide() }
        applyLook(); updateValue(); updateActions(); onPage?(false)
    }
    /// The page drawn once, at the screen's resolution for the whole page fitted (twice that, for zooming in), off the main
    /// actor; it goes with this view when full screen closes.
    private func requestPage() {
        guard let page, let layout, !pageRequested else { return }
        pageRequested = true
        let density = FigurePageLayout.renderDensity(pageSize: layout.region.pageSize, viewSize: bounds.size,
                                                     screenScale: window?.screen.scale ?? traitCollection.displayScale, figureDensity: layout.scaleX)
        Task { @MainActor [weak self] in
            guard let image = await page.render(density: density), let self else { return }
            self.pageView.image = UIImage(cgImage: image)
            self.updateValue()
        }
    }

    /// The veil and outline: the card's look at rest; full screen's revealed look (soft veil, the part outlined), which
    /// `fadeLook` fades away. The whole figure as a part has neither. On the page, the crop's own faint outline.
    private func applyLook() {
        let look = part.look(revealed: fullscreen)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        veil.fillColor = UIColor.white.withAlphaComponent(look.veil).cgColor; veil.isHidden = look.veil <= 0 || !outlines
        outline.isHidden = !look.outlined || !outlines
        let line = 2 / max(zoomScale, 0.01)
        outline.lineWidth = line; outline.path = UIBezierPath(rect: regionRect.insetBy(dx: -line, dy: -line)).cgPath
        cropOutline.isHidden = !pageShown
        if pageShown {
            let thin = 1.5 / max(zoomScale, 0.01)
            cropOutline.lineWidth = thin; cropOutline.path = UIBezierPath(rect: picture.frame.insetBy(dx: -thin / 2, dy: -thin / 2)).cgPath
        }
        CATransaction.commit()
    }
    /// Full screen: the outline (and veil) seen, then gone over `duration` (or, with Reduce Motion, after it at once).
    func fadeLook(after delay: TimeInterval, duration: TimeInterval, reduceMotion: Bool) {
        lookLayer.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true); lookLayer.opacity = 1; CATransaction.commit()
        lookShown = true; updateValue()
        if reduceMotion {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { [weak self] in
                CATransaction.begin(); CATransaction.setDisableActions(true); self?.lookLayer.opacity = 0; CATransaction.commit()
                self?.lookShown = false; self?.updateValue()
            }
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.beginTime = lookLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
        fade.duration = duration; fade.fillMode = .backwards; fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        lookLayer.opacity = 0
        lookLayer.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { [weak self] in self?.lookShown = false; self?.updateValue() }
    }
    private var lookShown = false
    private func updateValue() {
        let percent = "\(Int((zoomScale / max(restZoom, 0.0001) * 100).rounded()))%"
        #if DEBUG && FIXTURE_HOST
        // The journeys read where the view is and whether the outline still shows (and, with a page, whether it is drawn).
        let place = pageShown ? "page \(pageView.image == nil ? "drawing" : "drawn"), crop outlined" : showsWhole ? "whole" : "part"
        accessibilityValue = fullscreen ? "\(percent), \(place), outline \(lookShown ? "shown" : "hidden")" : percent
        #else
        accessibilityValue = pageShown ? "\(percent), the page around the figure" : percent
        #endif
    }
    /// VoiceOver: to the whole page and back to the figure (with a page).
    private func updateActions() {
        guard hasPage else { accessibilityCustomActions = nil; return }
        accessibilityCustomActions = [pageShown
            ? UIAccessibilityCustomAction(name: "Back to the figure") { [weak self] _ in self?.showPart(animated: false); self?.record(zoomed: true); return true }
            : UIAccessibilityCustomAction(name: "Show the whole page") { [weak self] _ in self?.showPage(animated: false); self?.record(zoomed: true); return true }]
    }

    /// What the view shows, in pixels of the figure (it may reach into the white margin).
    var visible: CropRect {
        let z = max(zoomScale, 0.0001), x = (contentOffset.x) / z - imageOrigin.x, y = (contentOffset.y) / z - imageOrigin.y
        return CropRect(Double(x), Double(y), Double(x + bounds.width / z), Double(y + bounds.height / z))
    }
    func record(zoomed: Bool = false, panned: Bool = false) {
        guard let recordKey, fullscreen else { return }
        let v = visible, W = Double(pixels.width), H = Double(pixels.height)
        FigureFramingRecorder.shared.changed(recordKey, view: CropRect(v.x0 / W, v.y0 / H, v.x1 / W, v.y1 / H), zoomed: zoomed, panned: panned)
    }

    /// What the card shows (Save snippet): the figure at its own resolution or the card's on-screen pixels, whichever is
    /// larger, with the veil and outline as shown.
    func visibleImage() -> CGImage? {
        let v = visible, screen = window?.screen.scale ?? 2, z = max(zoomScale, 0.0001)
        let scale = max(1, Double(bounds.width * screen) / max(1, v.x1 - v.x0))
        return part.render(pixels, view: v, scale: scale, revealed: fullscreen, outline: FigurePartCrop.outline, lineWidth: 2 * scale / Double(z))
    }

    // The card's ways in: each opens full screen at once (a pinch outwards, onto the page when the figure has one).
    private func open(_ gesture: FigureFramingRecord.OpenGesture, out: Bool = false) { onOpen?(gesture, convert(bounds, to: nil), out) }
    @objc private func tapped() { open(.tap) }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        // It opens as soon as the fingers have moved enough to tell a pinch outwards (onto the page) from one inwards.
        guard gesture.state == .began || gesture.state == .changed, abs(gesture.scale - 1) > 0.03 || gesture.state == .changed && abs(gesture.velocity) > 0.5 else { return }
        open(.pinch, out: abs(gesture.scale - 1) > 0.03 ? gesture.scale < 1 : gesture.velocity < 0); gesture.state = .cancelled
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) { if gesture.state == .began { open(.drag); gesture.state = .cancelled } }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        // Full screen: the whole figure ↔ the part; from the page, back to the part.
        let reduce = UIAccessibility.isReduceMotionEnabled
        if showsWhole || pageShown { showPart(animated: !reduce); if outlines { fadeLook(after: 0.4, duration: 1, reduceMotion: reduce) } } else { showWhole(animated: !reduce) }
        record(zoomed: true)
    }
    override func accessibilityActivate() -> Bool {
        guard !fullscreen, onOpen != nil else { return false }
        open(.accessibility); return true
    }
    override func accessibilityIncrement() {
        guard fullscreen else { return }
        setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: false); record(zoomed: true)
    }
    override func accessibilityDecrement() {
        guard fullscreen else { return }
        setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: false); record(zoomed: true)
    }
}

/// The full-screen viewer's stage (UIKit, so the open and close are one exact, interruptible motion): a backdrop and the
/// figure's view. Opening, the view starts exactly where the card was, showing exactly what the card showed (its frame
/// mapped onto the card, clipped to it), and in one motion becomes the full screen framed on the part; then the part's
/// outline fades over about a second while the whole figure is the reader's to pan and zoom. Closing (X, Escape, a swipe
/// down at the top) runs the same motion back onto the card. Reduce Motion: a cross-fade each way, the outline shown for a
/// second and then hidden.
final class FigureFullscreenStage: UIView {
    let scroll: FigureViewportScroll
    private let backdrop = UIView(), clip = UIView()
    /// Where the card was (window coordinates) and how to find it again when closing; nil: no card to open from (the Mac).
    private let source: CGRect?, sourceKey: String?
    private let outlines: Bool
    private var opened = false, closing = false
    private let filter = FigureGestureFilter()
    var onChrome: ((Bool) -> Void)?
    var onClosed: (() -> Void)?
    var onWhole: ((Bool) -> Void)? { didSet { scroll.onWhole = onWhole } }
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    /// Fixture builds may slow the motion down to photograph it mid-way (`--figure-fullscreen-slow=<factor>`).
    private static var slow: Double {
        #if DEBUG && FIXTURE_HOST
        if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--figure-fullscreen-slow=") }).flatMap({ Double($0.dropFirst("--figure-fullscreen-slow=".count)) }) {
            return min(40, max(1, value))
        }
        #endif
        return 1
    }
    static let openDuration = 0.35, fadeDuration = 1.0

    var onPage: ((Bool) -> Void)? { didSet { scroll.onPage = onPage } }
    /// Opened by a pinch outwards: once open, the view zooms out onto the figure's page.
    private let startOnPage: Bool

    init(image: CGImage, part: FramedPart, outlines: Bool, label: String, recordKey: String?, source: CGRect?, sourceKey: String?,
         page: FigurePDFPage? = nil, startOnPage: Bool = false) {
        scroll = FigureViewportScroll(image: image, part: part, fullscreen: true, outlines: outlines, recordKey: recordKey, snippetKey: nil, page: page, onOpen: nil)
        self.source = source; self.sourceKey = sourceKey; self.outlines = outlines; self.startOnPage = startOnPage && scroll.hasPage
        super.init(frame: .zero)
        backgroundColor = .clear
        // Both fingers of a pinch reach the figure (a plain view takes only the first touch).
        isMultipleTouchEnabled = true
        backdrop.backgroundColor = .systemBackground; backdrop.alpha = 0
        addSubview(backdrop); addSubview(scroll)
        scroll.backgroundColor = .clear
        scroll.accessibilityLabel = label
        scroll.accessibilityIdentifier = "figureView.fullscreen.image"
        clip.backgroundColor = .black
        let dismiss = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:))); dismiss.delegate = filter; dismiss.maximumNumberOfTouches = 1
        // A swipe down at the top of the figure closes (iPhone/iPad; the Mac has the X and Escape).
        filter.shouldBegin = { [weak self] gesture in
            guard let self, let pan = gesture as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: self)
            return !closing && pan.numberOfTouches == 1 && v.y > abs(v.x) * 1.2 && scroll.atTop
        }
        addGestureRecognizer(dismiss)
        scroll.panGestureRecognizer.require(toFail: dismiss)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        guard !closing, scroll.transform == .identity || !opened else { return }
        if scroll.frame != bounds { scroll.frame = bounds; scroll.layoutIfNeeded() }
        guard !opened, bounds.width > 0, bounds.height > 0, window != nil else { return }
        opened = true
        open()
    }

    private var sourceCard: FigureViewportScroll? {
        sourceKey.flatMap { FigureViewportScroll.shown.object(forKey: $0 as NSString) }
    }
    private func finish() {
        sourceCard?.alpha = 1
        onClosed?()
    }
    deinit { MainActor.assumeIsolated { sourceCard?.alpha = 1 } }

    /// The card's rectangle now, in this view's coordinates (nil when it is gone or off screen).
    private func cardRect() -> CGRect? {
        if let key = sourceKey, let card = FigureViewportScroll.shown.object(forKey: key as NSString), let w = card.window, w === window {
            let r = card.convert(card.bounds, to: self)
            return r.intersects(bounds) ? r : nil
        }
        return source.map { convert($0, from: nil) }
    }
    /// The part's frame as the view now shows it, in this view's coordinates without the view's own transform.
    private func frameInStage() -> CGRect {
        let f = scroll.frameOnScreen(in: scroll), b = scroll.bounds
        return f.offsetBy(dx: scroll.center.x - b.width / 2 - b.minX, dy: scroll.center.y - b.height / 2 - b.minY)
    }
    /// The transform that puts the part's frame (as the view now shows it) onto `target`, about the view's centre.
    private func transform(onto target: CGRect) -> CGAffineTransform {
        let f = frameInStage(), s = target.width / max(1, f.width)
        let c = scroll.center
        let tx = target.midX - c.x - s * (f.midX - c.x), ty = target.midY - c.y - s * (f.midY - c.y)
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: s, y: s)
    }

    private func open() {
        let slow = Self.slow
        guard !reduceMotion, let card = cardRect() else {
            // No card to come from (or Reduce Motion): a cross-fade.
            scroll.alpha = 0
            UIView.animate(withDuration: 0.18 * slow, delay: 0, options: [.curveEaseOut]) { [self] in backdrop.alpha = 1; scroll.alpha = 1 }
                completion: { [weak self] _ in self?.settled() }
            onChrome?(true)
            return
        }
        // Start: the frame exactly on the card, clipped to it (the card's own rounded corners). The card itself is hidden
        // while the viewer is up (the viewer is it, moved), and shown again once the viewer has closed back onto it.
        sourceCard?.alpha = 0
        let f = scroll.frameOnScreen(in: scroll)
        clip.frame = f; clip.layer.cornerRadius = 8 / max(0.01, card.width / max(1, f.width))
        scroll.mask = clip
        scroll.transform = transform(onto: card)
        UIView.animate(withDuration: Self.openDuration * slow, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [.allowUserInteraction]) { [self] in
            scroll.transform = .identity
            clip.frame = scroll.bounds; clip.layer.cornerRadius = 0
            backdrop.alpha = 1
        } completion: { [weak self] _ in
            self?.scroll.mask = nil
            self?.settled()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * slow) { [weak self] in self?.onChrome?(true) }
    }

    /// Open: the outline fades (or, with Reduce Motion, shows for a second, then goes); opened by a pinch outwards, the view
    /// then zooms out onto the page.
    private func settled() {
        if startOnPage { scroll.showPage(animated: !reduceMotion); scroll.record(zoomed: true) }
        guard outlines else { return }
        scroll.fadeLook(after: 0.1 * Self.slow, duration: Self.fadeDuration * Self.slow, reduceMotion: reduceMotion)
    }

    /// The page around the figure, or back to the figure (the top row's page control).
    func togglePage() {
        if scroll.pageShown {
            scroll.showPart(animated: !reduceMotion)
            if outlines { scroll.fadeLook(after: 0.4, duration: Self.fadeDuration, reduceMotion: reduceMotion) }
        } else { scroll.showPage(animated: !reduceMotion) }
        scroll.record(zoomed: true)
    }

    /// Whole figure ↔ the part (the top row's control).
    func toggle() {
        if scroll.showsWhole {
            scroll.showPart(animated: !reduceMotion)
            if outlines { scroll.fadeLook(after: 0.4, duration: Self.fadeDuration, reduceMotion: reduceMotion) }
        } else { scroll.showWhole(animated: !reduceMotion) }
        scroll.record(zoomed: true)
    }

    /// Back onto the card (or a fade without one), then `onClosed`.
    func close() {
        guard !closing else { return }
        closing = true
        scroll.record()
        onChrome?(false)
        let slow = Self.slow
        guard !reduceMotion, let card = cardRect() else {
            UIView.animate(withDuration: 0.18 * slow, delay: 0, options: [.curveEaseIn]) { [self] in backdrop.alpha = 0; scroll.alpha = 0 }
                completion: { [weak self] _ in self?.finish() }
            return
        }
        // The view returns to the card's framing as it shrinks onto the card.
        let dragged = scroll.transform
        scroll.transform = .identity
        clip.frame = scroll.bounds; clip.layer.cornerRadius = 0; scroll.mask = clip
        scroll.transform = dragged
        UIView.animate(withDuration: Self.openDuration * slow, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: []) { [self] in
            scroll.showPart(animated: false)
            let f = scroll.frameOnScreen(in: scroll)
            scroll.transform = transform(onto: card)
            clip.frame = f; clip.layer.cornerRadius = 8 / max(0.01, card.width / max(1, f.width))
            backdrop.alpha = 0
        } completion: { [weak self] _ in self?.finish() }
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        let dy = max(0, pan.translation(in: self).y), share = min(1, dy / max(1, bounds.height))
        switch pan.state {
        case .changed:
            scroll.transform = CGAffineTransform(translationX: 0, y: dy).scaledBy(x: 1 - 0.25 * share, y: 1 - 0.25 * share)
            backdrop.alpha = 1 - min(1, share * 1.6)
            onChrome?(dy < 24)
        case .ended, .cancelled:
            if pan.state == .ended, dy > 110 || pan.velocity(in: self).y > 900 { close() }
            else {
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) { [self] in
                    scroll.transform = .identity; backdrop.alpha = 1
                }
                onChrome?(true)
            }
        default: break
        }
    }

    override func accessibilityPerformEscape() -> Bool { close(); return true }
}

struct FigureImagePresentation: Identifiable {
    let id = UUID()
    /// The whole figure.
    let image: CGImage
    /// A part card's framing: full screen opens on it, the part outlined; nil for the whole figure.
    var part: FramedPart?
    let label: String
    var recordKey: String?
    /// Where the card was (window coordinates), and its key to find it again when closing.
    var source: CGRect?
    var sourceKey: String?
    /// The figure's PDF page on this device (an on-device reading), and whether to open onto it.
    var page: FigurePDFPage?
    var startOnPage = false

    /// `page` when this image is the crop it records (a figure of one image as the route cut it); else nil.
    static func page(_ page: FigurePDFPage?, for image: CGImage) -> FigurePDFPage? {
        page.flatMap { FigurePageLayout(region: $0.region, imageWidth: image.width, imageHeight: image.height) == nil ? nil : $0 }
    }
}

private struct FigureViewerWindowSizeKey: EnvironmentKey { static let defaultValue = CGSize.zero }
extension EnvironmentValues {
    var figureViewerWindowSize: CGSize {
        get { self[FigureViewerWindowSizeKey.self] }
        set { self[FigureViewerWindowSizeKey.self] = newValue }
    }
}

/// Presents or dismisses the full-screen figure without the system's slide: the stage itself moves from and back to the
/// card (FigureFullscreenStage).
@MainActor func presentFigureImage(_ change: () -> Void) { var t = Transaction(); t.disablesAnimations = true; withTransaction(t, change) }

private struct FigureImageCover: ViewModifier {
    @Binding var image: FigureImagePresentation?
    @Environment(\.figureViewerWindowSize) private var windowSize
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.sheet(item: $image) { value in
            // The presenting sheet has its own smaller geometry. Carry the owning window's size from RootView. The Mac has
            // no card to open from in another window's coordinates: the viewer fades in, framed on the part.
            if #available(iOS 18.0, *), windowSize.width > 0, windowSize.height > 0 {
                FullscreenFigureImage(image: value, matched: false) { image = nil }
                    .frame(width: windowSize.width, height: windowSize.height)
                    .presentationSizing(.fitted)
            } else {
                FullscreenFigureImage(image: value, matched: false) { image = nil }
            }
        }
        #else
        content.fullScreenCover(item: $image) { value in
            FullscreenFigureImage(image: value, matched: true) { presentFigureImage { image = nil } }
                .presentationBackground(.clear)
        }
        #endif
    }
}

/// The full-screen figure: the stage, and over it a slim top row (the figure's name, Whole figure / Show part, and X).
struct FullscreenFigureImage: View {
    let image: FigureImagePresentation
    /// Whether the stage moves from and back to the card (iPhone/iPad); the Mac's sheet fades.
    var matched = true
    let close: () -> Void
    @State private var stage: FigureFullscreenStage?
    @State private var chrome = false
    @State private var whole = false
    @State private var onPage = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FigureStageView(image: image, matched: matched, stage: $stage, chrome: $chrome, whole: $whole, onPage: $onPage, closed: close)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    Text(image.label).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if image.part != nil {
                        Button(whole ? "Show part" : "Whole figure") { stage?.toggle() }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 36)
                            .background(Capsule().fill(.regularMaterial))
                            .accessibilityIdentifier("figureView.fullscreen.toggle")
                    }
                    if image.page != nil {
                        // The PDF page around the figure (a figure the on-device model cut from a PDF on this device), as
                        // small as the X: zooming out past the figure does the same.
                        Button { stage?.togglePage() } label: {
                            Image(systemName: onPage ? "crop" : "doc.viewfinder").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                                .background(Circle().fill(.regularMaterial))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(onPage ? "Back to the figure" : "Show the whole page").accessibilityIdentifier("figureView.fullscreen.page")
                    }
                    Button { stage?.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                            .background(Circle().fill(.regularMaterial))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close fullscreen image").accessibilityIdentifier("figureView.fullscreen.close")
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16).padding(.top, 4)
                .opacity(chrome ? 1 : 0)
                .allowsHitTesting(chrome)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome)
            }
            .macSheetKeys()
    }
}

private struct FigureStageView: UIViewRepresentable {
    let image: FigureImagePresentation
    let matched: Bool
    @Binding var stage: FigureFullscreenStage?
    @Binding var chrome: Bool
    @Binding var whole: Bool
    @Binding var onPage: Bool
    let closed: () -> Void
    func makeUIView(context: Context) -> FigureFullscreenStage {
        let part = image.part ?? .whole(width: image.image.width, height: image.image.height)
        let view = FigureFullscreenStage(image: image.image, part: part, outlines: image.part != nil, label: image.label, recordKey: image.recordKey,
                                         source: matched ? image.source : nil, sourceKey: matched ? image.sourceKey : nil,
                                         page: image.page, startOnPage: image.startOnPage)
        view.onChrome = { shown in Task { @MainActor in chrome = shown } }
        view.onWhole = { at in Task { @MainActor in if whole != at { whole = at } } }
        view.onPage = { shown in Task { @MainActor in if onPage != shown { onPage = shown } } }
        view.onClosed = closed
        Task { @MainActor in stage = view }
        return view
    }
    func updateUIView(_ view: FigureFullscreenStage, context: Context) {}
}

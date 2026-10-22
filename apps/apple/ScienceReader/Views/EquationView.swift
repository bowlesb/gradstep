import ScienceReaderCore
import SwiftUI
import WebKit

// The equation view (owner, 2026-10-15; docs/architecture/EQUATION_VIEW.md): a tapped equation large, at the size the
// reader picks and optionally scrolled sideways; what it says and each symbol described, from the paper where the paper
// describes it (a link to that paragraph) and from general usage where it does not; optional background; Ask in chat.
// The two requests are chat actions on the chat's own profile and paper, so they share the chat's cached paper.

/// "AI Explainer" chosen on a tapped equation of this paper (owner, build 62), or the view opened on an equation.
struct EquationViewRequest: Identifiable, Equatable {
    let id = UUID()
    let paperID: UUID
    let equationID: String
    /// Asks for the explanation at once (AI Explainer was the reader's request); otherwise only on the view's button.
    var explains = false
    var chats = false
}

/// One equation resolved from the paper's verified bundle (`ReaderModel.equationContext(for:)`).
struct EquationViewContext {
    let paperID: UUID
    let bundle: VerifiedReaderBundle
    let equationID: String
    let blockID: String
    /// The equation's own element in the bundle's page; nil shows its LaTeX instead.
    let markup: String?
    let number: String?
    /// "Equation (4)", or "Equation".
    let label: String
    let latex: String
    /// The equation's `[¶N]` block.
    let paragraph: Int?
    /// The paper numbered on this device; nil when it isn't a source paper here (no descriptions then).
    let localContext: LocalPaperChatContext?
}

/// What the view asks for as it closes, applied once it has gone.
enum EquationViewOutcome {
    case paragraph(paperID: UUID, marker: Int)
    case askInChat(EquationViewContext)
    case continueChat
}

/// The view's two requests: the symbols (on opening) and the background (on its button), each kept on the device.
@MainActor @Observable final class EquationSession {
    enum State: Equatable {
        case idle, loading, done
        case failed(String, retryable: Bool)
        /// The chat's cloud consent isn't given yet on this device.
        case needsConsent
        case needsSignIn
        /// The paper isn't a source paper on this device: the equation shows, its symbols can't be described.
        case unavailable
    }
    struct Part: Equatable {
        var state: State = .idle
        var text = ""
        var symbols: EquationSymbols?
        var credits: Int?
        var answeredModel: String?
    }

    private(set) var symbols = Part()
    private(set) var background = Part()
    let context: EquationViewContext
    let localModelID: String?
    @ObservationIgnored private weak var model: ReaderModel?
    @ObservationIgnored private var tasks: [ChatAction: Task<Void, Never>] = [:]
    @ObservationIgnored private var awaitingConsent: ChatAction?
    var asksConsent: Bool { awaitingConsent != nil && (symbols.state == .needsConsent || background.state == .needsConsent) }

    init(context: EquationViewContext, model: ReaderModel) {
        self.context = context; self.model = model; self.localModelID = model.localAIModelID
    }

    /// Shows what this device kept. Nothing is asked of the AI until the reader asks for it (owner, build 59: "The AI
    /// explanation should only come if you ask for it").
    func start() {
        guard let model else { return }
        for action in [ChatAction.equation, .equationBackground] {
            if let kept = model.equationAnswer(key(action, profile: model.equationProfile)) {
                set(action, Part(state: .done, text: kept.text, symbols: kept.symbols, credits: kept.credits, answeredModel: kept.model))
            }
        }
    }

    /// Explain: the summary and each symbol (the AI, on request).
    func explain() { if symbols.state != .loading, symbols.state != .done { run(.equation) } }

    func showBackground() { if background.state != .loading, background.state != .done { run(.equationBackground) } }
    func retry(_ action: ChatAction) { run(action) }

    func acceptConsent() {
        guard let model, let action = awaitingConsent else { return }
        awaitingConsent = nil
        guard model.acceptCloudConsent() else { set(action, Part(state: .failed("Your choice couldn’t be saved. Try again.", retryable: true))); return }
        run(action)
        // The other request was waiting for the same consent.
        let other: ChatAction = action == .equation ? .equationBackground : .equation
        if part(other).state == .needsConsent { set(other, Part()); if other == .equation { run(.equation) } }
    }

    func declineConsent() {
        guard let action = awaitingConsent else { return }
        awaitingConsent = nil
        set(action, Part(state: .failed("Cloud explanations need your consent. Try again to choose.", retryable: true)))
    }

    func stop() { for task in tasks.values { task.cancel() }; tasks = [:] }

    private func run(_ action: ChatAction) {
        guard let model else { return }
        guard model.isSignedIn else { set(action, Part(state: .needsSignIn)); return }
        guard localModelID != nil || context.localContext != nil else { set(action, Part(state: .unavailable)); return }
        guard localModelID != nil || model.hasCloudConsent else { awaitingConsent = action; set(action, Part(state: .needsConsent)); return }
        guard localModelID != nil || model.chatProfileTable != nil else { set(action, Part(state: .failed("Cloud models haven’t loaded. Choose model to retry.", retryable: false))); return }
        let profile = model.equationProfile
        let request: ChatGenerationRequest
        do {
            if localModelID != nil {
                guard context.latex.unicodeScalars.count <= ChatGenerationRequest.maximumSelectionScalars else { throw LocalAIContext.Failure.mandatoryInputTooLarge }
                request = try ChatGenerationRequest.make(operationID: UUID(), documentID: context.paperID,
                    transcript: [.init(role: .user, text: context.label)], selection: context.latex, action: action, profile: profile)
                    .forLocalInference(paperText: PaperChatContext.text(context.bundle.index), focus: context.paragraph)
            } else if let local = context.localContext {
                request = try .equation(action, operationID: UUID(), label: context.label, latex: context.latex, profile: profile,
                                        localContext: local, visualAnswers: model.visualAnswers)
            } else { set(action, Part(state: .unavailable)); return }
        } catch {
            let message = localModelID != nil ? ChatFailureText.message(for: "local_context_large") : "This equation couldn’t be sent."
            set(action, Part(state: .failed(message, retryable: false))); return
        }
        set(action, Part(state: .loading))
        tasks[action]?.cancel()
        let answerKey = key(action, profile: profile)
        tasks[action] = Task { [weak self] in await self?.stream(action, request: request, key: answerKey) }
    }

    private func stream(_ action: ChatAction, request: ChatGenerationRequest, key: EquationResultKey) async {
        var part = Part(state: .loading), model: String?
        let scope = self.model?.readerSessionID
        do {
            guard let events = try await self.model?.equationStream(request, localModelID: localModelID) else { set(action, Part(state: .needsSignIn)); return }
            for try await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .delta(let piece):
                    part.text += piece
                    // Background streams as it is written; the symbols' words (no usable symbols) come whole.
                    if action == .equationBackground || localModelID != nil { set(action, part) }
                case .equation(let described): part.symbols = described
                case .done(_, let credits, let answered, _): part.credits = credits; part.state = .done; model = answered; part.answeredModel = answered
                case .failure(let code, let credits): part.credits = credits; part.state = Self.failure(code)
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
        if part.state == .done, part.symbols == nil, part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            part.state = .failed(action == .equation ? "Couldn’t describe this equation. Try again." : "Couldn’t write the background. Try again.", retryable: true)
        }
        set(action, part)
        guard part.state == .done, let reader = self.model else { return }
        reader.keepEquationAnswer(EquationAnswer(symbols: part.symbols, text: part.text, credits: part.credits, model: model), for: key)
        if localModelID == nil { Task { await reader.refreshCreditBalance() } }
    }

    private static let noCredits = "Not enough credits for this. Your balance is in Settings."
    private static func failure(_ code: String) -> State {
        switch code {
        case "insufficient_credits": .failed(noCredits, retryable: true)
        default: .failed(ChatFailureText.message(for: code), retryable: ChatFailureText.isRetryable(code))
        }
    }

    private func key(_ action: ChatAction, profile: ChatProfileChoice) -> EquationResultKey {
        EquationResultKey(manifestSHA256: context.bundle.manifestSHA256, equationID: context.equationID, action: action,
                          profile: profile, localModel: model?.localAI.identity(localModelID))
    }
    private func part(_ action: ChatAction) -> Part { action == .equation ? symbols : background }
    private func set(_ action: ChatAction, _ part: Part) { if action == .equation { symbols = part } else { background = part } }
}

struct EquationView: View {
    @Bindable var model: ReaderModel
    let request: EquationViewRequest
    let finish: (EquationViewOutcome?) -> Void
    @State private var session: EquationSession?
    @State private var missing = false
    @State private var choosingAI = false
    @State private var chatToken: UUID?
    @State private var chatFocus = 0
    /// The equation shown: the request's, or another chosen from the heading (owner, build 62: "a little thing you can
    /// expand to get to… all your equation listings"); one switched to waits for AI Explainer.
    @State private var equationID: String?
    @State private var equations: [PaperContentsSheet.Equation] = []
    /// The equation's size against the reader's text: 100–400 %, 160 % to start (remembered on this device).
    @AppStorage("equation.scale") private var scale = 1.6
    @State private var displayHeight: CGFloat = 96
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0

    private static let scales: ClosedRange<Double> = 1.0...4.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let session { content(session) }
                    else if missing { ContentUnavailableView("Couldn’t open this equation", systemImage: "function") }
                    else { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let session { composer(session) }
            }
            // The top row (DESIGN.md "Sheet top row"; owner, build 78): Snippet, Chat and AI Explainer (until it is
            // asked) in words; the sheet swipes away (the Mac keeps an X).
            .sheetTopRow(
                snippet: session.map { session in
                    ExplainAction(identifier: "equation.addToNote", hint: "Saves this equation as a snippet") { addToNote(session.context) }
                },
                chat: session.map { _ in
                    ExplainAction(identifier: "equation.chat", hint: "Ask about this equation below; nothing is sent") { chatFocus += 1 }
                },
                explainer: session.flatMap { session in
                    session.symbols.state == .idle
                        ? ExplainAction(identifier: "equation.explain", hint: "Choose a model to describe this equation.") { choosingAI = true }
                        : nil
                },
                openChat: ExplainAction(identifier: "equation.openInChat", hint: "Continue this conversation in Chat.") {
                    guard let chatToken, let session else { return }
                    model.promoteContextualChat(chatToken, explanation: equationExplanation(session)); finish(.continueChat)
                }, noun: "Equation", close: { finish(nil) })
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .bottom) { NoteSavedBanner(model: model, origin: .equation) { finish(nil) }.padding(.bottom, 80) }
            .noteComposerHost(model, origin: .equation)
        }
        .frame(minWidth: Platform.isMac ? 560 : nil, minHeight: Platform.isMac ? 640 : nil)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .task(id: equationID ?? request.equationID) {
            let shown = equationID ?? request.equationID
            session?.stop()
            guard let context = model.equationContext(for: EquationViewRequest(paperID: request.paperID, equationID: shown)) else { missing = true; return }
            missing = false
            chatToken = model.beginContextualChat(paperID: context.paperID, manifest: context.bundle.manifestSHA256,
                element: context.blockID, label: context.label, quote: context.latex)
            if request.chats { chatFocus += 1 }
            let opened = EquationSession(context: context, model: model)
            session = opened
            opened.start()
            // AI Explainer from the equation's menu asks at once; an equation switched to from the heading waits.
            if request.explains, equationID == nil, opened.symbols.state == .idle { choosingAI = true }
            if equations.isEmpty { equations = await PaperContentsSheet.equations(in: context.bundle) }
        }
        .onDisappear { session?.stop(); if let chatToken { model.endContextualChat(chatToken) } }
        .sheet(isPresented: $choosingAI) {
            AIChoiceView(model: model, chat: true, needsVision: false) { id in
                model.localAIModelID = id
                guard let context = session?.context else { return }
                session?.stop()
                let opened = EquationSession(context: context, model: model)
                session = opened; opened.start(); opened.explain()
            }
        }
        .sheet(isPresented: Binding(get: { session?.asksConsent ?? false }, set: { if !$0, session?.asksConsent == true { session?.declineConsent() } })) {
            CloudConsentContent(accept: { session?.acceptConsent() }, decline: { session?.declineConsent() })
                .presentationDetents([.large])
                .macSheetKeys()
        }
    }

    private func rememberReturn() {
        guard let context = session?.context else { return }
        model.rememberExplainer(paperID: context.paperID, manifest: context.bundle.manifestSHA256,
            item: context.equationID, label: context.label, equation: true)
    }

    private func composer(_ session: EquationSession) -> some View {
        ContextualChatComposer(model: model, token: chatToken, label: session.context.label, needsVision: false,
            explanation: equationExplanation(session), busy: session.symbols.state == .loading || session.background.state == .loading,
            focusRequest: chatFocus, modelChanged: {
                session.stop()
                let next = EquationSession(context: session.context, model: model); self.session = next; next.start()
            })
    }

    private func content(_ session: EquationSession) -> some View {
        ContextualConversationScroll(model: model, token: chatToken) {
            VStack(alignment: .leading, spacing: 22) {
                // "Equation (4) ⌄": the paper's other equations to switch to.
                ExplainerHeadingMenu(title: session.context.label, items: equations, current: session.context.equationID,
                                     itemTitle: { $0.label },  // "Equation (4)", or "Equation · 3.2 Method" when unnumbered
                                     identifier: "equation.heading") { other in
                    if other.id != session.context.equationID { equationID = other.id }
                }
                VStack(alignment: .leading, spacing: 8) {
                    display(session.context)
                    Text(session.localModelID.map { "\(model.localAI.name($0)) (local)" } ?? cloudLabel(session))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("equation.aiSource")
                }
                symbols(session)
                if session.symbols.state == .done { backgroundSection(session) }
                ContextualChatThread(model: model, token: chatToken, onCite: cite(session))
                    .id("contextChat.thread")
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("equation.view")
    }

    private func cloudLabel(_ session: EquationSession) -> String {
        if let served = session.symbols.answeredModel { return "\(ChatProfileText.modelName(served))" }
        if session.symbols.state == .done { return "Saved explanation" } // A legacy saved answer may not name its model.
        return "\(model.chatProfileTable?.label(model.equationProfile.model) ?? model.equationProfile.model.label)"
    }

    private func equationExplanation(_ session: EquationSession) -> String {
        let symbols = session.symbols.symbols
        return [symbols?.summary ?? session.symbols.text,
                symbols?.symbols.map { "\($0.symbol): \($0.meaning)" }.joined(separator: "\n") ?? "",
                session.background.text].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: The equation

    private func display(_ context: EquationViewContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let markup = context.markup {
                    EquationWebView(bundle: context.bundle, markup: markup, fontSize: model.paperFontSize * bodySize / 17,
                                    scale: scale, height: $displayHeight)
                        // The scheme handler is bound to one immutable bundle; equation changes reload below.
                        .id(context.bundle.manifestSHA256)
                        .frame(height: displayHeight)
                } else {
                    ScrollView(.horizontal) {
                        Text(context.latex).font(.system(size: bodySize * scale * 0.8, design: .monospaced)).textSelection(.enabled).padding(.vertical, 8)
                    }
                    .accessibilityIdentifier("equation.display")
                }
            }
            .frame(maxWidth: .infinity)
            // A border with room inside it (owner, 2026-10-21: "Some border basically, when we present them in the
            // equation view"): the equation never meets the edge of its surface, however wide it is fitted.
            .padding(.horizontal, 8)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    sizeButton("minus", label: "Smaller", id: "equation.smaller", enabled: scale > Self.scales.lowerBound + 0.01) {
                        scale = max(Self.scales.lowerBound, ((scale - 0.2) * 10).rounded() / 10)
                    }
                    sizeButton("plus", label: "Larger", id: "equation.larger", enabled: scale < Self.scales.upperBound - 0.01) {
                        scale = min(Self.scales.upperBound, ((scale + 0.2) * 10).rounded() / 10)
                    }
                    Text("\(Int((scale * 100).rounded())) %").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 52).accessibilityIdentifier("equation.sizeValue")
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Equation size")
                Spacer(minLength: 0)
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    /// The rendered equation (WKWebView's snapshot of its own view, on this card's background) as a region snippet.
    private func addToNote(_ context: EquationViewContext) {
        guard model.notesAvailability == .ready else {
            model.error = model.isSignedIn ? "Unlock Notes on this device to save snippets." : "Sign in to save snippets to your encrypted notes."
            return
        }
        guard let web = EquationWebView.shown, web.window != nil,
              let paper = model.papers.first(where: { $0.id == context.paperID }) ?? model.selectedPaper else { return }
        Task { @MainActor in
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            guard let image = try? await web.takeSnapshot(configuration: configuration),
                  let opaque = SnippetCapturer.opaque(image, background: .secondarySystemGroupedBackground, traits: web.traitCollection) else { return }
            let anchor = NoteAnchor(manifestSHA256: context.bundle.manifestSHA256, rendererRevision: ReaderVersions.revision(of: context.bundle) ?? 0,
                                    blockIDs: NoteAnchor.isBlockID(context.blockID) ? [context.blockID] : [], rects: [], viewport: nil, quote: nil)
            let snippet = CapturedSnippet(kind: .region, image: opaque, quote: nil, source: SnippetCapturer.source(for: paper, label: context.label),
                                          anchor: anchor, capturedAt: Date(), origin: .equation, paperID: paper.id)
            model.notes.notice = nil
            model.notes.composer = NoteComposerRequest(snippet: snippet)
        }
    }

    private func sizeButton(_ symbol: String, label: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 40).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(enabled ? Color.accentColor : Color.secondary)
            .disabled(!enabled).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    // MARK: Symbols

    @ViewBuilder private func symbols(_ session: EquationSession) -> some View {
        let part = session.symbols
        VStack(alignment: .leading, spacing: 14) {
            if let described = part.symbols {
                if !described.summary.isEmpty {
                    Text(described.summary).font(.body).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("equation.summary")
                }
                if !described.symbols.isEmpty {
                    Text("Symbols").font(.headline).accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(described.symbols.enumerated()), id: \.offset) { index, symbol in
                            if index > 0 { Divider() }
                            symbolRow(symbol, index: index + 1, paperID: session.context.paperID)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                }
            } else if !part.text.isEmpty, part.state == .done || session.localModelID != nil {
                // No usable symbols: the model's words are the description.
                ChatMessageText(source: part.text, fontSize: bodySize, streaming: part.state == .loading, speaker: "Assistant", identifier: "equation.description",
                                assistant: true, onCite: cite(session))
            }
            status(part, session: session, action: .equation, working: "Describing the symbols…")
        }
    }

    private func symbolRow(_ symbol: EquationSymbols.Symbol, index: Int, paperID: UUID) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(symbol.latex.map(ChatMathText.plain).flatMap { $0.isEmpty ? nil : $0 } ?? symbol.symbol)
                .font(.system(size: bodySize * 1.15, design: .serif)).italic()
                .frame(minWidth: 52, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(symbol.meaning).fixedSize(horizontal: false, vertical: true)
                if let paragraph = symbol.paragraph, symbol.source == .paper {
                    Button("From the paper ¶\(paragraph)") { rememberReturn(); finish(.paragraph(paperID: paperID, marker: paragraph)) }
                        .font(.footnote).buttonStyle(.borderless)
                        .accessibilityLabel("From the paper, paragraph \(paragraph)")
                        .accessibilityHint("Shows that paragraph, with Back to return")
                        .accessibilityIdentifier("equation.symbolSource.\(index)")
                } else {
                    Text("General meaning").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel("General meaning: the paper doesn’t define it")
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(symbol.symbol): \(symbol.meaning)")
        .accessibilityIdentifier("equation.symbol.\(index)")
    }

    // MARK: Background

    @ViewBuilder private func backgroundSection(_ session: EquationSession) -> some View {
        let part = session.background
        VStack(alignment: .leading, spacing: 12) {
            if part.state == .idle {
                Button { session.showBackground() } label: {
                    Label("More background", systemImage: "text.book.closed").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Explains what the equation is for and the ideas behind it. Uses credits.")
                .accessibilityIdentifier("equation.background")
            } else {
                Text("Background").font(.headline).accessibilityAddTraits(.isHeader)
                if !part.text.isEmpty {
                    ChatMessageText(source: part.text, fontSize: bodySize, streaming: part.state == .loading, speaker: "Assistant",
                                    identifier: "equation.backgroundText", assistant: true, onCite: part.state == .loading ? nil : cite(session))
                }
                status(part, session: session, action: .equationBackground, working: "Writing the background…")
            }
        }
    }

    // MARK: Shared

    @ViewBuilder private func status(_ part: EquationSession.Part, session: EquationSession, action: ChatAction, working: String) -> some View {
        switch part.state {
        case .loading where part.text.isEmpty:
            HStack(spacing: 10) { ProgressView(); Text(working).foregroundStyle(.secondary) }
                .accessibilityElement(children: .combine).accessibilityIdentifier("equation.loading")
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if retryable { Button("Try again") { session.retry(action) }.accessibilityIdentifier("equation.retry") }
                Button("Change AI") { choosingAI = true }.accessibilityIdentifier("equation.changeAI")
            }
        case .needsSignIn:
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to have the symbols described.").foregroundStyle(.secondary)
                Button("Sign in") { finish(nil); model.openSignIn() }
            }
        case .needsConsent:
            Button("Continue…") { session.retry(action) }
        case .unavailable where action == .equation:
            Text("Descriptions need this paper on this device as an arXiv paper. The equation above is the paper’s own.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    private func cite(_ session: EquationSession) -> ChatCiteHandler {
        let paperID = session.context.paperID
        return { marker in rememberReturn(); finish(.paragraph(paperID: paperID, marker: marker)) }
    }
}

/// The equation alone, from the bundle's own page and stylesheet: MathML, or the formula image a device-PDF bundle holds.
/// Its size follows the reader's text size times the chosen scale; off "Scroll sideways" a wider equation is scaled to
/// fit, on it keeps its size and scrolls. No page script runs; only this view's layout script, in its own world.
struct EquationWebView: UIViewRepresentable {
    /// The equation on screen, for Add to note (weak: a closed page is gone).
    @MainActor static weak var shown: WKWebView?
    let bundle: VerifiedReaderBundle
    let markup: String
    let fontSize: Double
    let scale: Double
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = PaperWebView.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(ReaderBundleSchemeHandler(bundle: bundle), forURLScheme: "reader-bundle")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.layoutScript, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "equation")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.alwaysBounceVertical = false; web.scrollView.bounces = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        web.accessibilityIdentifier = "equation.display"
        Self.shown = web
        context.coordinator.loadSource(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadSource(web)
        context.coordinator.layout(web)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "equation", contentWorld: .defaultClient)
        web.stopLoading()
    }

    /// The bundle's stylesheet, then this view's: transparent page, the equation inline and centred when it fits.
    static func page(bundle: VerifiedReaderBundle, markup: String) -> String {
        let style = bundle.manifest.members.first { $0.role == "style" }?.path
        let link = style.map { "<link rel=\"stylesheet\" href=\"\($0)\">" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\(link)
        <style>
        :root,html,body{background:transparent!important}
        body{margin:0;padding:14px 8px;text-align:center}
        #eq{display:inline-block;width:max-content;text-align:left;vertical-align:top}
        #eq .reader-equation{margin:0;padding:0;background:transparent;max-width:none;overflow:visible}
        #eq .reader-display{display:inline-block}
        #eq .reader-tagged{display:inline-flex;align-items:center;gap:1.2em}
        #eq .reader-tag{white-space:nowrap;opacity:.75}
        #eq math{font-size:1em}
        </style></head><body><div id="eq">\(markup)</div></body></html>
        """
    }

    static let layoutScript = """
    (() => {
      let last = null;
      const apply = () => {
        if (!last) return null;
        const eq = document.getElementById('eq'); if (!eq) return null;
        document.documentElement.style.fontSize = last.size + 'px';
        eq.style.zoom = '1';
        const available = Math.max(1, document.documentElement.clientWidth - 16);
        const natural = eq.scrollWidth;
        // Fit once at the reader's base size, then apply the requested zoom. A wide formula must
        // grow when + is tapped; fitting its already-enlarged width would cancel every zoom step.
        const fit = Math.min(1, available / Math.max(1, natural)) * last.scale;
        eq.style.zoom = String(fit);
        const height = Math.ceil(eq.getBoundingClientRect().height + 28);
        return { height, fit, natural, available };
      };
      window.__equationLayout = (size, scale) => { last = { size, scale }; return apply(); };
      window.addEventListener('resize', () => { const result = apply(); if (result) window.webkit.messageHandlers.equation.postMessage(result); });
    })();
    """

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: EquationWebView
        private var loaded = false
        private var applied: (size: Double, scale: Double)?
        private var source: String?
        private var navigation: WKNavigation?
        init(_ parent: EquationWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the page itself; a link inside an equation goes nowhere.
            action.navigationType == .other && !loaded ? .allow : .cancel
        }

        func loadSource(_ web: WKWebView) {
            guard source != parent.markup else { return }
            source = parent.markup; loaded = false; applied = nil
            web.stopLoading(); web.scrollView.setContentOffset(.zero, animated: false)
            navigation = web.loadHTMLString(EquationWebView.page(bundle: parent.bundle, markup: parent.markup),
                baseURL: URL(string: "reader-bundle://\(parent.bundle.manifestSHA256)/"))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            loaded = true; applied = nil
            layout(webView)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let height = body["height"] as? Double else { return }
            report(height, in: message.webView)
        }

        func layout(_ web: WKWebView) {
            let size = parent.fontSize, scale = parent.scale
            web.scrollView.isScrollEnabled = true
            guard loaded, applied?.size != size || applied?.scale != scale else { return }
            applied = (size, scale)
            web.callAsyncJavaScript("return window.__equationLayout(size, scale);", arguments: ["size": size, "scale": scale],
                                    in: nil, in: .defaultClient) { [weak self, weak web] result in
                guard let self, case .success(let value) = result, let body = value as? [String: Any], let height = body["height"] as? Double else { return }
                self.report(height, in: web)
                if scale <= 1 { web?.scrollView.setContentOffset(.zero, animated: false) }
            }
        }

        private func report(_ height: Double, in web: WKWebView?) {
            guard height.isFinite, height > 0 else { return }
            let value = CGFloat(min(max(height, 48), 2_400))
            if abs(parent.height - value) > 1 { parent.height = value }
        }
    }
}

/// Inline use of the real chat event store: no second transcript format or unencrypted conversation cache.
struct ContextualConversationScroll<Content: View>: View {
    let model: ReaderModel
    let token: UUID?
    @ViewBuilder var content: Content
    @State private var followsAnswer = true
    private let bottom = "contextChat.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                    Color.clear.frame(height: 1).id(bottom).accessibilityHidden(true)
                }
                // Native attributed text can finish its layout after the final stream event.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                    if followsAnswer, (token == nil ? model.promotedChatContext != nil : model.ownsContextualChat(token)), !model.chatIsEmpty {
                        proxy.scrollTo(bottom, anchor: .bottom)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
                if followsAnswer, (token == nil ? model.promotedChatContext != nil : model.ownsContextualChat(token)), !model.chatIsEmpty {
                    proxy.scrollTo(bottom, anchor: .bottom)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture().onChanged { _ in followsAnswer = false })
            .onChange(of: model.chatTranscriptMessages.last?.id) { _, _ in
                guard (token == nil ? model.promotedChatContext != nil : model.ownsContextualChat(token)) else { return }
                followsAnswer = true
                withAnimation { proxy.scrollTo(bottom, anchor: .bottom) }
            }
            .onChange(of: model.chatTranscriptMessages.last?.payload.text) { _, _ in
                if followsAnswer, (token == nil ? model.promotedChatContext != nil : model.ownsContextualChat(token)) { proxy.scrollTo(bottom, anchor: .bottom) }
            }
            .onAppear {
                if (token == nil ? model.promotedChatContext != nil : model.ownsContextualChat(token)), !model.chatIsEmpty { proxy.scrollTo(bottom, anchor: .bottom) }
            }
        }
    }
}

struct ContextualChatThread: View {
    let model: ReaderModel
    let token: UUID?
    let onCite: ChatCiteHandler
    @ScaledMetric(relativeTo: .body) private var size = 17.0
    @State private var paperActions = ChatPaperActions()
    var body: some View {
        if (token == nil ? model.promotedChatContext != nil : model.ownsContextualChat(token)) {
            let messages = model.chatTranscriptMessages, streamingID = model.chatStreamingMessageID
            let followUps = model.chatFollowUpQuestions, last = messages.last?.id
            if !messages.isEmpty { Divider().padding(.vertical, 8) }
            // Chat's own message row (NATIVE_REVIEW_20261021 B2): sources, papers named, follow-ups, interruption notes,
            // figure-part crops, quote actions and diagrams (by the answer's entity) as in the Chat tab.
            ForEach(messages, id: \.id) { message in
                TranscriptMessage(message: message, streaming: message.id == streamingID,
                                  progress: message.id == streamingID ? model.chatStreamingProgress : nil, fontSize: size,
                                  diagram: model.chatDiagrams[message.payload.entityID], openDiagram: { model.openDiagram($0) },
                                  papers: ChatPaperContext(model: model, actions: paperActions),
                                  followUps: message.id == last ? followUps : [], first: false, last: false,
                                  textIdentifier: "contextChat.message.\(message.id.wire)", cite: onCite, horizontalInset: 0)
            }
        }
    }
}

struct ContextualChatComposer: View {
    @Bindable var model: ReaderModel
    let token: UUID?
    let label: String
    let needsVision: Bool
    let explanation: String
    var busy = false
    var focusRequest = 0
    var modelChanged: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue = model.chatAnswerIssue, model.ownsContextualChat(token) {
                Text(issue.message(free: model.creditBalance?.free)).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("contextChat.error")
                if issue.retryable { Button(issue.actionTitle) { model.retryAnswer() }.accessibilityIdentifier("contextChat.retry") }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Ask about \(label)", text: Binding(get: { model.ownsContextualChat(token) ? model.chatInput : "" },
                    set: { if model.ownsContextualChat(token) { model.chatInput = $0 } }), axis: .vertical)
                    .focused($focused).lineLimit(1...5).padding(.horizontal, 14).padding(.top, 12)
                    .accessibilityIdentifier("contextChat.composer")
                HStack(spacing: 12) {
                    Button { choosing = true } label: {
                        HStack(spacing: 4) { Text(model.currentAIName); Image(systemName: "chevron.down").font(.caption2) }
                            .font(.caption).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("contextChat.model")
                    Spacer(minLength: 4)
                    ChatDictationButton(model: model)
                    if model.isAnswering {
                        Button { model.stopAnswer() } label: { ComposerActionLabel(systemImage: "stop.fill", enabled: !model.isStoppingAnswer) }
                            .disabled(model.isStoppingAnswer).accessibilityLabel("Stop answer").accessibilityIdentifier("contextChat.stop")
                    } else {
                        Button { send() } label: { ComposerActionLabel(systemImage: "arrow.up", enabled: canSend) }
                            .disabled(!canSend).accessibilityLabel("Send").accessibilityIdentifier("contextChat.send")
                            // As in Chat: ⌘Return sends (Mac and an iPad keyboard); Return starts a new line.
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }.padding(.leading, 14).padding(.trailing, 3).padding(.bottom, 3)
            }
            .chromeSurface(RoundedRectangle(cornerRadius: 22), outlined: true)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        .background(.regularMaterial)
        .onChange(of: focusRequest) { _, _ in focused = true }
        .sheet(isPresented: $choosing) {
            AIChoiceView(model: model, chat: true, needsVision: needsVision) { id in
                model.localAIModelID = id; modelChanged()
            }
        }
        .sheet(item: Binding(get: { model.ownsContextualChat(token) ? model.chatConsentPrompt : nil }, set: { next in
            if model.ownsContextualChat(token), next == nil, let prompt = model.chatConsentPrompt { model.declineChatConsent(prompt) }
        })) { prompt in ChatConsentView(model: model, prompt: prompt).interactiveDismissDisabled().macSheetKeys(enabled: false) }
    }
    private func send() {
        guard let token else { return }
        // Mac (⌘Return), as Chat's composer: the field ends editing first so it can't write the sent text back, then
        // takes the focus again for the next question.
        guard Platform.isMac, focused else { Task { await model.sendContextualMessage(token, explanation: explanation) }; return }
        focused = false
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            await model.sendContextualMessage(token, explanation: explanation)
            focused = true
        }
    }
    private var canSend: Bool {
        model.ownsContextualChat(token) && !busy && !model.isGenerating && !model.isDiscardingDraft && model.chatContextComplete
            && !model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

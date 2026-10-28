import ScienceReaderCore
import SwiftUI

// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"): from Paper › … › AI
// Explainer, in the figure explainer's look: its cards (PaperExplainerCards: "In short", Key concepts — the background it
// assumes and its own ideas, each one line with the paragraphs that rely on it — and a diagram of how they fit together),
// then a conversation about it with the figure explainer's Open in Chat symbol, which carries the cards.
//
// TestFlight 93 (owner, 2026-10-25; JUDGMENT_LOG 27): "The space at the top isn't that well used … an option for users to
// request more elaboration on each concept, and then another screen in front. Then when we swipe away we get the entire
// overview behind". The header moved into the sheet's bar (PaperExplainerHeader), and each Key concept has "Go deeper ›":
// its card (PaperConceptView) opens in front as a sheet (a slot's sheet in Wide on iPad), and swiping it down shows the
// overview as it was, at the same place.

/// The explainer's compact header: in the sheet's own bar beside the chat symbol, two short lines — a small "AI Explainer ·
/// <model>" label over the paper's title — so the overview starts right under the bar instead of under a 28-point title, the
/// title and the model on three lines and an empty band above them. The figure and equation explainers keep their own
/// headings (a ⌄ menu of the paper's other figures or equations: ExplainerHeadingMenu), which this one doesn't share.
/// The bar holds one view (the header, the chat symbol and, on the Mac or in Wide's slot, the X), as the sheet top row's
/// words are one view (SheetChrome.swift): iOS 26 moves bar items that don't fit into an overflow menu, which took the chat
/// symbol when the header was its own leading item.
enum PaperExplainerHeader {
    /// The label (with the model) and the paper's title.
    static let lines = 2
    static let titleLineLimit = 1
    /// The header is in the bar, not the page.
    static let inBar = true
    /// The overview's space above its first card (16 under the old heading, whose own three lines came first).
    static let contentTopPadding: CGFloat = 8
    /// Larger text keeps the bar's two lines inside the bar (the whole title is the header's VoiceOver label).
    static let largestType = DynamicTypeSize.xxLarge
    static func label(model: String) -> String { "AI Explainer · \(model)" }
    /// The bar's own margins, both sides together: its one view spans the rest.
    static let barMargins: CGFloat = 40
}

struct PaperExplainView: View {
    let model: ReaderModel
    let context: PaperExplainerContext
    let requesting: Bool
    /// A concept whose kept card opens in front once the explainer shows (Back from one of its ¶ links; Your AI usage's
    /// Open concept). Only a kept one: nothing is asked unasked.
    var openConcept: String? = nil
    /// What it closes with (a cited paragraph, Open in Chat, sign in), applied once the sheet has gone.
    let finish: @MainActor (FigureViewOutcome) -> Void
    let close: @MainActor () -> Void
    @State private var session: PaperExplainerSession?
    @State private var chatToken: UUID?
    @State private var choosingAI = false
    /// The concept card in front (Go deeper).
    @State private var deeper: PaperConceptSession?
    /// The concept last asked about (Ask about this): its words go with the question, before the overview's.
    @State private var asked: PaperConceptSession?
    @State private var chatFocus = 0
    /// The page's width: the bar row's.
    @State private var width: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.coverPresentation) private var cover

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let session { content(session) } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ContextualChatComposer(model: model, token: chatToken, label: "this explanation", needsVision: false,
                                   explanation: explanationText, busy: session?.state == .loading, focusRequest: chatFocus)
        }
        // The sheet's own bar (inline; shown in Wide's slot), its row drawn here as one view: the header, the chat symbol
        // and the X where the sheet shows one (the Mac, Wide's slot). VoiceOver's escape closes it, as everywhere.
        .sheetTopRow(noun: "Paper", close: nil)
        .accessibilityAction(.escape) { close() }
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .principal) { topRow }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { topRow }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: context.bundle.manifestSHA256) {
            guard session == nil else { return }
            chatToken = model.beginContextualChat(paperID: context.paperID, manifest: context.bundle.manifestSHA256,
                element: "paper-explainer", label: "AI Explainer", quote: context.title)
            let opened = PaperExplainerSession(context: context, model: model)
            session = opened
            opened.start(requesting: requesting)
            // Back from a concept's ¶ link, or Your AI usage: its kept card in front again (after the sheet has settled).
            if let id = openConcept, opened.state == .done, opened.concepts[id] != nil, let entry = opened.entry(id) {
                try? await Task.sleep(for: .milliseconds(450))
                if deeper == nil { deeper = opened.concept(entry.item, kind: entry.kind) }
                return
            }
            // Nothing kept and nothing asked yet (opened from Your assets after the answer was removed): choose a model.
            // (After the sheet has settled: a sheet asked for while this one is still presenting can be dropped.)
            if !requesting, opened.state == .idle {
                try? await Task.sleep(for: .milliseconds(450))
                if opened.state == .idle { choosingAI = true }
            }
        }
        .onDisappear { session?.stop(); if let chatToken { model.endContextualChat(chatToken) } }
        .slotSheet(isPresented: $choosingAI) {
            AIChoiceView(model: model, chat: true, needsVision: false) { _ in session?.explain() }
        }
        .slotSheet(isPresented: Binding(get: { session?.asksConsent ?? false }, set: { if !$0, session?.asksConsent == true { session?.declineConsent() } })) {
            CloudConsentContent(accept: { session?.acceptConsent() }, decline: { session?.declineConsent() })
                .sheetDetent(.large).macSheetKeys()
        }
        // Go deeper: the concept's card in front; swiping it down shows the overview as it was (this view stays, scrolled
        // where it was). A card closed while it is written goes on being written (the explainer's session holds it).
        .slotSheet(item: $deeper) { concept in
            PaperConceptView(model: model, session: concept, currentAI: currentAI, onCite: citeConcept(concept.item.id),
                             ask: { ask(concept) }, signIn: { finish(.signIn) })
                .macSheetKeys()
        }
    }

    /// The question's context: the concept last asked about, then the overview.
    private var explanationText: String {
        let overview = session?.explainer?.text ?? session?.text ?? ""
        guard let asked, asked.state == .done else { return overview }
        let words = asked.concept?.text ?? asked.text
        return words.isEmpty ? overview : "Go deeper: \(asked.item.name)\n\n\(words)" + (overview.isEmpty ? "" : "\n\n\(overview)")
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            header
            Button {
                guard let chatToken else { return }
                model.promoteContextualChat(chatToken, explanation: explanationText, paperExplainer: session?.state == .done ? session?.explainer : nil)
                finish(.continueChat)
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.body.weight(.medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44).contentShape(Circle())
                    .modifier(ChromeSurface(shape: Circle(), interactive: true))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open in Chat").accessibilityHint("Continue this conversation in Chat.")
            .accessibilityIdentifier("paperExplainer.openInChat")
            if Platform.isMac || cover { SheetCloseButton(action: close) }
        }
        // The bar sizes its one view to the view's own width: the page's, less the bar's margins.
        .frame(width: width > 0 ? max(200, width - PaperExplainerHeader.barMargins) : nil)
    }

    /// Two short lines in the bar: "AI Explainer · <model>" and the paper's title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(PaperExplainerHeader.label(model: session.map(sourceLabel) ?? currentAI))
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("paperExplainer.aiSource")
            Text(context.title).font(.footnote.weight(.semibold)).lineLimit(PaperExplainerHeader.titleLineLimit)
                .accessibilityIdentifier("paperExplainer.paperTitle")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...PaperExplainerHeader.largestType)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("paperExplainer.header")
    }

    private func content(_ session: PaperExplainerSession) -> some View {
        ContextualConversationScroll(model: model, token: chatToken) {
            VStack(alignment: .leading, spacing: 18) {
                explainer(session)
                ContextualChatThread(model: model, token: chatToken, onCite: cite)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, PaperExplainerHeader.contentTopPadding).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("paperExplainer.page")
    }

    private var currentAI: String { model.chatProfileTable?.label(model.equationProfile.model) ?? model.equationProfile.model.label }

    private func sourceLabel(_ session: PaperExplainerSession) -> String {
        if let served = session.answeredModel { return ChatProfileText.modelName(served) }
        if session.state == .done { return "Saved explanation" }
        return currentAI
    }

    /// As it arrives (the figure explainer's rules): the bar and a skeleton at once; then the summary, each entry appended
    /// in order with the bar below the last (nothing above it moves); the diagram once the explainer is whole; the bar fades.
    @ViewBuilder private func explainer(_ session: PaperExplainerSession) -> some View {
        let loading = session.state == .loading
        VStack(alignment: .leading, spacing: 18) {
            if let explainer = session.explainer {
                PaperExplainerCards(explainer: explainer, loading: loading, bodySize: bodySize,
                                    deeper: session.state == .done ? { item, kind in deeper = session.concept(item, kind: kind) } : nil,
                                    deepened: session.deepened, onCite: cite)
                if session.state == .done, session.notCharged {
                    Text("This explanation stopped before the end. Not charged.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("paperExplainer.notCharged")
                }
            } else if session.state == .done, !session.text.isEmpty {
                // No usable explainer: the model's words are the description.
                ChatMessageText(source: session.text, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                identifier: "paperExplainer.description", assistant: true, onCite: cite)
            }
            if loading, let progress = session.progress {
                PaperProgressBar(state: progress).transition(.opacity)
                if session.explainer == nil { PaperExplainerSkeleton().transition(.opacity) }
            }
            status(session)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: session.progress == nil)
        .onChange(of: session.progress?.label) { _, label in
            // VoiceOver hears each new stage, not every step of the bar.
            if let label, UIAccessibility.isVoiceOverRunning { AccessibilityNotification.Announcement(label).post() }
        }
    }

    @ViewBuilder private func status(_ session: PaperExplainerSession) -> some View {
        switch session.state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("The background this paper assumes, its key ideas and how they fit together.").foregroundStyle(.secondary)
                Button("Explain this paper") { choosingAI = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("paperExplainer.start")
            }
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                Text(session.notCharged ? message + " Not charged." : message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paperExplainer.failure")
                if retryable { Button("Try again") { session.explain() }.accessibilityIdentifier("paperExplainer.retry") }
                Button("Change AI") { choosingAI = true }.accessibilityIdentifier("paperExplainer.changeAI")
            }
        case .needsSignIn:
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to have papers explained.").foregroundStyle(.secondary)
                Button("Sign in") { finish(.signIn) }
            }
        case .needsConsent: Button("Continue…") { session.explain() }
        case .unavailable:
            Text("The explainer needs this paper on this device as an arXiv paper.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    private var cite: ChatCiteHandler {
        let context = context, model = model
        return { marker in
            model.rememberExplainer(paperID: context.paperID, manifest: context.bundle.manifestSHA256, item: "paper", label: "AI Explainer",
                                    equation: false, action: ChatAction.paperExplainer.rawValue)
            finish(.paragraph(paperID: context.paperID, marker: marker))
        }
    }

    /// A ¶ in a concept's card: the paper there, as from the overview; Back returns to the explainer with the card in front.
    /// (The explainer closes with the card on it: one dismissal.)
    private func citeConcept(_ id: String) -> ChatCiteHandler {
        let context = context, model = model
        return { marker in
            model.rememberExplainer(paperID: context.paperID, manifest: context.bundle.manifestSHA256, item: id, label: "AI Explainer",
                                    equation: false, action: ChatAction.paperConcept.rawValue)
            finish(.paragraph(paperID: context.paperID, marker: marker))
        }
    }

    /// Ask about this: the card goes, the explainer's question box starts "About “<concept>”: " (as a figure part's Ask
    /// about this part) and its words go with the question; the keyboard comes up once the card has gone.
    private func ask(_ concept: PaperConceptSession) {
        asked = concept
        deeper = nil
        if model.ownsContextualChat(chatToken) { model.chatInput = "About “\(concept.item.name)”: " }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            chatFocus += 1
        }
    }
}

/// A Key concept, deeper (JUDGMENT_LOG 27): in front of the overview, the concept in this paper's context — what it is, why
/// the paper needs it, an intuition or small example, how the paper uses it — and where it appears, each place a ¶ link as
/// in the overview; then Ask about this. It streams in section by section with the explainer's bar; a kept one shows at once.
/// Swiped down (or closed on the Mac), the overview behind is as it was.
struct PaperConceptView: View {
    let model: ReaderModel
    let session: PaperConceptSession
    /// The AI it is asked of (the explainer's), named until the model that wrote it is known.
    let currentAI: String
    let onCite: ChatCiteHandler
    let ask: () -> Void
    let signIn: () -> Void
    @SheetDismiss private var dismiss
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sections
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("paperConcept.page")
        .task { session.start() }
        .slotSheet(isPresented: Binding(get: { session.asksConsent }, set: { if !$0, session.asksConsent { session.declineConsent() } })) {
            CloudConsentContent(accept: { session.acceptConsent() }, decline: { session.declineConsent() })
                .sheetDetent(.large).macSheetKeys()
        }
    }

    /// The model that wrote it (the fallback's name when it answered), else the AI it is asked of.
    private var source: String {
        if let served = session.answeredModel { return ChatProfileText.modelName(served) }
        return session.state == .done ? "Saved explanation" : currentAI
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(PaperExplainerCards.color(session.kind)).frame(width: 7, height: 7)
                    Text(session.kind == .background ? "Background" : "This paper").font(.caption).foregroundStyle(.secondary)
                    Text("· \(source)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("paperConcept.aiSource")
                }
                .accessibilityElement(children: .combine)
                Text(session.item.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("paperConcept.name")
                if !session.item.line.isEmpty {
                    Text(session.item.line).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            // The Mac has no swipe: its X (a touch screen swipes the card down).
            if Platform.isMac { SheetCloseButton { dismiss() } }
        }
    }

    @ViewBuilder private var sections: some View {
        let loading = session.state == .loading, done = session.state == .done
        VStack(alignment: .leading, spacing: 16) {
            if let concept = session.concept {
                ForEach(Array(concept.sections.enumerated()), id: \.offset) { index, section in
                    sectionCard(section, number: index + 1, ready: done)
                }
            } else if done, !session.text.isEmpty {
                // No usable sections: the model's words are the explanation.
                ChatMessageText(source: session.text, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                identifier: "paperConcept.description", assistant: true, onCite: onCite)
            }
            if loading, let progress = session.progress {
                PaperProgressBar(state: progress, identifier: "paperConcept.progress").transition(.opacity)
                if session.concept == nil { PaperExplainerSkeleton(identifier: "paperConcept.skeleton").transition(.opacity) }
            }
            status
            if done {
                if session.notCharged {
                    Text("This explanation stopped before the end. Not charged.").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("paperConcept.notCharged")
                }
                Button(action: ask) { Label("Ask about this", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(.bordered).accessibilityHint("Asks in the explainer’s chat, about this concept.")
                    .accessibilityIdentifier("paperConcept.ask")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: session.progress == nil)
        .onChange(of: session.progress?.label) { _, label in
            if let label, UIAccessibility.isVoiceOverRunning { AccessibilityNotification.Announcement(label).post() }
        }
    }

    /// One section on the explainer's raised card: its words with working ¶ links, or (where it appears) each place as the
    /// overview's ¶ link with what happens there. The links wait for the whole concept (as the figure walkthrough's).
    private func sectionCard(_ section: PaperConcept.Section, number: Int, ready: Bool) -> some View {
        PaperExplainerCard(title: section.title) {
            if !section.text.isEmpty {
                ChatMessageText(source: section.text, fontSize: bodySize, streaming: false, speaker: "Assistant",
                                identifier: "paperConcept.section.\(number).text", assistant: true, onCite: ready ? onCite : nil)
            }
            ForEach(section.places, id: \.paragraph) { place in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button("¶\(place.paragraph)") { onCite(place.paragraph) }
                        .font(.footnote.weight(.semibold)).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(Platform.isMac ? .small : .mini)
                        .disabled(!ready)
                        .accessibilityLabel("Go to paragraph \(place.paragraph)").accessibilityIdentifier("paperConcept.place.\(place.paragraph)")
                    if !place.note.isEmpty {
                        Text(place.note).font(.system(size: bodySize * 0.92)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paperConcept.section.\(number)")
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .failed(let message, let retryable):
            VStack(alignment: .leading, spacing: 8) {
                Text(session.notCharged ? message + " Not charged." : message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paperConcept.failure")
                if retryable { Button("Try again") { session.retry() }.accessibilityIdentifier("paperConcept.retry") }
            }
        case .needsSignIn:
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to have papers explained.").foregroundStyle(.secondary)
                Button("Sign in", action: signIn)
            }
        case .needsConsent: Button("Continue…") { session.retry() }
        case .unavailable:
            Text("Going deeper needs this paper on this device as an arXiv paper.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }
}

/// The explainer's progress bar: the stage in words over a bar, filled while the announced count holds, else moving.
/// One accessibility element: the stage is its label, the share its value (none while indeterminate).
private struct PaperProgressBar: View {
    let state: PaperExplainerProgress.State
    var identifier = "paperExplainer.progress"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.label).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let value = state.value {
                ProgressView(value: value)
            } else {
                GeometryReader { proxy in
                    let width = proxy.size.width, segment = max(40, width * 0.28)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .systemFill))
                        if reduceMotion {
                            Capsule().fill(Color.accentColor.opacity(0.45)).frame(width: segment)
                        } else {
                            TimelineView(.animation) { timeline in
                                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                                Capsule().fill(Color.accentColor).frame(width: segment).offset(x: -segment + (width + segment) * phase)
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 4)
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

/// Where the explainer will appear while it is asked for: summary lines and a list's rows. Still under Reduce Motion,
/// else a slow pulse; hidden from VoiceOver (the bar says where it is).
private struct PaperExplainerSkeleton: View {
    var identifier = "paperExplainer.skeleton"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([1.0, 0.94, 0.62], id: \.self) { share in line(height: 12).scaleEffect(x: share, y: 1, anchor: .leading) }
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(width: 110, height: 15)
                ForEach(0..<3, id: \.self) { _ in
                    line(height: 13).frame(width: 160)
                    line(height: 11)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .opacity(dim ? 0.55 : 1)
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } } }
        .accessibilityHidden(true)
        .accessibilityIdentifier(identifier)
    }

    private func line(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

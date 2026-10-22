import ScienceReaderCore
import SwiftUI

// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"): from Paper › … › AI
// Explainer, in the figure explainer's look: the paper, then its cards (PaperExplainerCards: "In short", Key concepts —
// the background it assumes and its own ideas, each one line with the paragraphs that rely on it — and a diagram of how they
// fit together), then a conversation about it with the figure explainer's Open in Chat symbol, which carries the cards.

struct PaperExplainView: View {
    let model: ReaderModel
    let context: PaperExplainerContext
    let requesting: Bool
    /// What it closes with (a cited paragraph, Open in Chat, sign in), applied once the sheet has gone.
    let finish: @MainActor (FigureViewOutcome) -> Void
    let close: @MainActor () -> Void
    @State private var session: PaperExplainerSession?
    @State private var chatToken: UUID?
    @State private var choosingAI = false
    @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let session { content(session) } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ContextualChatComposer(model: model, token: chatToken, label: "this explanation", needsVision: false,
                                   explanation: explanationText, busy: session?.state == .loading)
        }
        .sheetTopRow(
            explainer: session?.state == .idle
                ? ExplainAction(identifier: "paperExplainer.explain", hint: "Choose a model to explain this paper.") { choosingAI = true }
                : nil,
            openChat: ExplainAction(identifier: "paperExplainer.openInChat", hint: "Continue this conversation in Chat.") {
                guard let chatToken else { return }
                model.promoteContextualChat(chatToken, explanation: explanationText, paperExplainer: session?.state == .done ? session?.explainer : nil)
                finish(.continueChat)
            }, noun: "Paper", close: close)
        .background(Color(uiColor: .systemGroupedBackground))
        .task(id: context.bundle.manifestSHA256) {
            guard session == nil else { return }
            chatToken = model.beginContextualChat(paperID: context.paperID, manifest: context.bundle.manifestSHA256,
                element: "paper-explainer", label: "AI Explainer", quote: context.title)
            let opened = PaperExplainerSession(context: context, model: model)
            session = opened
            opened.start(requesting: requesting)
            // Nothing kept and nothing asked yet (opened from Your assets after the answer was removed): choose a model.
            // (After the sheet has settled: a sheet asked for while this one is still presenting can be dropped.)
            if !requesting, opened.state == .idle {
                try? await Task.sleep(for: .milliseconds(450))
                if opened.state == .idle { choosingAI = true }
            }
        }
        .onDisappear { session?.stop(); if let chatToken { model.endContextualChat(chatToken) } }
        .sheet(isPresented: $choosingAI) {
            AIChoiceView(model: model, chat: true, needsVision: false) { _ in session?.explain() }
        }
        .sheet(isPresented: Binding(get: { session?.asksConsent ?? false }, set: { if !$0, session?.asksConsent == true { session?.declineConsent() } })) {
            CloudConsentContent(accept: { session?.acceptConsent() }, decline: { session?.declineConsent() })
                .presentationDetents([.large]).macSheetKeys()
        }
    }

    private var explanationText: String { session?.explainer?.text ?? session?.text ?? "" }

    private func content(_ session: PaperExplainerSession) -> some View {
        ContextualConversationScroll(model: model, token: chatToken) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Explainer").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text(context.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        .accessibilityIdentifier("paperExplainer.paperTitle")
                    Text(sourceLabel(session)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("paperExplainer.aiSource")
                }
                explainer(session)
                ContextualChatThread(model: model, token: chatToken, onCite: cite)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("paperExplainer.page")
    }

    private func sourceLabel(_ session: PaperExplainerSession) -> String {
        if let served = session.answeredModel { return ChatProfileText.modelName(served) }
        if session.state == .done { return "Saved explanation" }
        return model.chatProfileTable?.label(model.equationProfile.model) ?? model.equationProfile.model.label
    }

    /// As it arrives (the figure explainer's rules): the bar and a skeleton at once; then the summary, each entry appended
    /// in order with the bar below the last (nothing above it moves); the diagram once the explainer is whole; the bar fades.
    @ViewBuilder private func explainer(_ session: PaperExplainerSession) -> some View {
        let loading = session.state == .loading
        VStack(alignment: .leading, spacing: 18) {
            if let explainer = session.explainer {
                PaperExplainerCards(explainer: explainer, loading: loading, bodySize: bodySize, onCite: cite)
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
}

/// The explainer's progress bar: the stage in words over a bar, filled while the announced count holds, else moving.
/// One accessibility element: the stage is its label, the share its value (none while indeterminate).
private struct PaperProgressBar: View {
    let state: PaperExplainerProgress.State
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
        .accessibilityIdentifier("paperExplainer.progress")
    }
}

/// Where the explainer will appear while it is asked for: summary lines and a list's rows. Still under Reduce Motion,
/// else a slow pulse; hidden from VoiceOver (the bar says where it is).
private struct PaperExplainerSkeleton: View {
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
        .accessibilityIdentifier("paperExplainer.skeleton")
    }

    private func line(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)).frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

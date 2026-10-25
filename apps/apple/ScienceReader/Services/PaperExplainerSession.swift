import Foundation
import ScienceReaderCore

// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"): on request from Paper › …,
// the background the paper assumes, its key ideas and a diagram of how they fit together. The request is the paper chat's
// own (its profile, capabilities and cached paper) with the action `paper_explainer`; the explainer streams in entry by
// entry with the figure explainer's progress rules, and is kept on the device per paper revision and model.

/// One paper of this device, resolved for its explainer.
struct PaperExplainerContext {
    let paperID: UUID
    let title: String
    let bundle: VerifiedReaderBundle
    /// The paper numbered on this device; nil when it isn't an arXiv paper here (no explainer then).
    let localContext: LocalPaperChatContext?
}

@MainActor @Observable final class PaperExplainerSession {
    enum State: Equatable {
        case idle, loading, done
        case failed(String, retryable: Bool)
        case needsConsent, needsSignIn, unavailable
    }
    private(set) var state: State = .idle
    /// The explainer so far (streamed), then the final one.
    private(set) var explainer: PaperExplainer?
    /// The model's words when no usable explainer came.
    private(set) var text = ""
    /// Ended early or with nothing to show, and the reader paid nothing.
    private(set) var notCharged = false
    private(set) var answeredModel: String?
    /// The progress bar while it is asked for and written; nil otherwise.
    private(set) var progress: PaperExplainerProgress.State?
    @ObservationIgnored private var tracker = PaperExplainerProgress.Tracker()
    @ObservationIgnored private weak var model: ReaderModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var awaitingConsent: (() -> Void)?
    var asksConsent: Bool { awaitingConsent != nil }
    let context: PaperExplainerContext

    init(context: PaperExplainerContext, model: ReaderModel) { self.context = context; self.model = model }

    private var key: PaperExplainerKey? {
        model.map { PaperExplainerKey(manifestSHA256: context.bundle.manifestSHA256, profile: $0.equationProfile) }
    }

    /// Shows what this device kept; asks when nothing is kept and `requesting`.
    func start(requesting: Bool) {
        if let key, let kept = model?.paperExplainerAnswer(key) {
            explainer = kept.explainer; text = kept.text; answeredModel = kept.model; state = .done
            return
        }
        if requesting { explain() }
    }

    func explain() { if state != .loading { run() } }
    func stop() { task?.cancel(); task = nil }

    func acceptConsent() {
        guard let model, let resume = awaitingConsent else { return }
        awaitingConsent = nil
        guard model.acceptCloudConsent() else { state = .failed("Your choice couldn’t be saved. Try again.", retryable: true); return }
        resume()
    }
    func declineConsent() {
        guard awaitingConsent != nil else { return }
        awaitingConsent = nil
        if state == .needsConsent { state = .failed("The explainer uses the chat’s AI. Try again to choose.", retryable: true) }
    }

    private func run() {
        guard let model else { return }
        guard model.isSignedIn else { state = .needsSignIn; return }
        guard let local = context.localContext else { state = .unavailable; return }
        guard model.hasCloudConsent else {
            awaitingConsent = { [weak self] in self?.run() }
            state = .needsConsent; return
        }
        guard model.chatProfileTable != nil else { state = .failed("Cloud models haven’t loaded. Try again in a moment.", retryable: true); return }
        let profile = model.equationProfile
        guard let request = try? ChatGenerationRequest.paperExplainer(operationID: UUID(), profile: profile, localContext: local, visualAnswers: model.visualAnswers)
            .linked(item: "paper") else {
            state = .failed("This paper couldn’t be sent.", retryable: false); return
        }
        explainer = nil; text = ""; notCharged = false; answeredModel = nil
        tracker = PaperExplainerProgress.Tracker(); showProgress()
        state = .loading
        task?.cancel()
        let key = PaperExplainerKey(manifestSHA256: context.bundle.manifestSHA256, profile: profile)
        task = Task { [weak self] in await self?.stream(request, key: key) }
    }

    private func stream(_ request: ChatGenerationRequest, key: PaperExplainerKey) async {
        var credits: Int?, stopReason = "", ending: State = .loading, words = ""
        let scope = model?.readerSessionID
        do {
            guard let events = try await model?.equationStream(request) else { state = .needsSignIn; progress = nil; return }
            tracker.opened(); showProgress()
            for try await event in events {
                guard !Task.isCancelled else { return }
                if tracker.apply(event) { explainer = tracker.explainerSoFar }
                showProgress()
                switch event {
                case .delta(let piece): words += piece
                case .done(let reason, let paid, let answered, _): credits = paid; stopReason = reason; answeredModel = answered; ending = .done
                case .failure(let code, let paid): credits = paid; ending = Self.failure(code)
                default: break
                }
                if ending != .loading { break }
            }
        } catch ChatTransportError.rejected(let code) { ending = Self.failure(code) }
        catch { guard !Task.isCancelled else { return }; ending = Self.failure("transport") }
        guard !Task.isCancelled, model?.readerSessionID == scope else { return }
        if ending == .loading { ending = Self.failure("transport") }
        // Free AI that couldn't pay says why (migration 0150): the balance is read again once.
        if ending == Self.failure("insufficient_credits"), let reader = model {
            await reader.refreshCreditBalance()
            guard !Task.isCancelled, reader.readerSessionID == scope else { return }
            ending = .failed(reader.creditsMessage(Self.noCredits, premium: ReaderModel.isPremium(key.profile.model)), retryable: true)
        }
        // Only the final explainer is kept; a failure drops what streamed (the failure shows with Try again).
        explainer = ending == .done ? (tracker.final ?? tracker.explainerSoFar) : nil
        text = words
        if ending == .done, explainer == nil, words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ending = .failed("Couldn’t explain this paper. Try again.", retryable: true)
        }
        notCharged = credits == 0 && (ending != .done || !["end_turn", "stop_sequence", "tool_use", "stop"].contains(stopReason))
        progress = nil
        state = ending
        guard ending == .done, let model else { return }
        model.keepPaperExplainerAnswer(PaperExplainerAnswer(explainer: explainer, text: text, model: answeredModel), for: key)
        Task { await model.refreshCreditBalance() }
    }

    private func showProgress() {
        let next = tracker.state()
        if progress != next { progress = next }
    }

    private static let noCredits = "Not enough credits for this. Your balance is in Settings."
    private static func failure(_ code: String) -> State {
        switch code {
        case "insufficient_credits": .failed(noCredits, retryable: true)
        default: .failed(ChatFailureText.message(for: code), retryable: ChatFailureText.isRetryable(code))
        }
    }
}

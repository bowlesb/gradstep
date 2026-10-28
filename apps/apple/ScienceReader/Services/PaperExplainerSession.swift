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
    /// The concepts deepened from this explainer and kept with it ("Go deeper", 2026-10-25), by entry id.
    private(set) var concepts: [String: PaperConceptAnswer] = [:]
    /// The entries already deepened: the overview's quiet mark.
    var deepened: Set<String> { Set(concepts.keys) }
    /// The key the shown explainer is kept under (its concepts are kept with it, whatever AI is chosen later).
    @ObservationIgnored private(set) var keptKey: PaperExplainerKey?
    @ObservationIgnored private var conceptSessions: [String: PaperConceptSession] = [:]
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
            concepts = kept.concepts ?? [:]; keptKey = key
            return
        }
        if requesting { explain() }
    }

    func explain() { if state != .loading { run() } }
    func stop() {
        task?.cancel(); task = nil
        for session in conceptSessions.values { session.stop() }
    }

    /// One entry's deeper card: what was kept for it, or (asked for with `start`) a request at the explainer's AI and price.
    /// The same session while the explainer is open, so a card closed while it is written keeps being written and shows
    /// when opened again.
    func concept(_ item: PaperExplainer.Item, kind: PaperExplainer.Kind) -> PaperConceptSession {
        if let open = conceptSessions[item.id], open.item == item { return open }
        let opened = PaperConceptSession(item: item, kind: kind, kept: concepts[item.id], owner: self)
        conceptSessions[item.id] = opened
        return opened
    }
    /// The entry and its kind, by id (a card asked for by Your AI usage or a return from the paper).
    func entry(_ id: String) -> (item: PaperExplainer.Item, kind: PaperExplainer.Kind)? {
        if let item = explainer?.background.first(where: { $0.id == id }) { return (item, .background) }
        if let item = explainer?.ideas.first(where: { $0.id == id }) { return (item, .idea) }
        return nil
    }

    /// A concept's card finished: kept with this explainer (the file that holds it) so reopening it is free.
    fileprivate func keep(_ answer: PaperConceptAnswer, for id: String) {
        concepts[id] = answer
        guard let model, let explainer, state == .done else { return }
        let key = keptKey ?? PaperExplainerKey(manifestSHA256: context.bundle.manifestSHA256, profile: model.equationProfile)
        concepts = model.keepPaperConcept(answer, id: id, explainer: explainer, key: key)
    }
    fileprivate var reader: ReaderModel? { model }

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
        // A new explainer has new entries: the concepts deepened from the old one stay with it (in its file).
        for session in conceptSessions.values { session.stop() }
        conceptSessions = [:]; concepts = [:]; keptKey = nil
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
        keptKey = key
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

/// "Go deeper" on one Key concept (2026-10-25; JUDGMENT_LOG 27, CHAT.md "Go deeper on a key concept"): its card, in front of
/// the explainer. One request at the explainer's own AI, price and rules (the reader's consent, the hold, the fallback and
/// its deadline: the server's), streamed section by section with the explainers' progress rules; kept with the explainer
/// once done, so the card opens again without asking (`fromKept`).
@MainActor @Observable final class PaperConceptSession: Identifiable {
    typealias State = PaperExplainerSession.State
    nonisolated var id: String { item.id }
    let item: PaperExplainer.Item
    let kind: PaperExplainer.Kind
    private(set) var state: State = .idle
    /// The concept so far (streamed), then the final one.
    private(set) var concept: PaperConcept?
    /// The model's words when no usable concept came.
    private(set) var text = ""
    private(set) var answeredModel: String?
    /// Ended early or with nothing to show, and the reader paid nothing.
    private(set) var notCharged = false
    /// Shown from what this device kept: no request was made.
    private(set) var fromKept = false
    private(set) var progress: FigureProgress.State?
    @ObservationIgnored private var tracker = PaperConceptTracker()
    @ObservationIgnored private weak var owner: PaperExplainerSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var awaitingConsent: (() -> Void)?
    var asksConsent: Bool { awaitingConsent != nil }

    init(item: PaperExplainer.Item, kind: PaperExplainer.Kind, kept: PaperConceptAnswer?, owner: PaperExplainerSession) {
        self.item = item; self.kind = kind; self.owner = owner
        if let kept { concept = kept.concept; text = kept.text; answeredModel = kept.model; state = .done; fromKept = true }
    }

    /// The card opened: what was kept shows as it is; otherwise it is asked for (once; a failure waits for Try again).
    func start() { if state == .idle { run() } }
    func retry() { if state != .loading, state != .done { run() } }
    func stop() { task?.cancel(); task = nil; if state == .loading { state = .idle; progress = nil } }

    func acceptConsent() {
        guard let model = owner?.reader, let resume = awaitingConsent else { return }
        awaitingConsent = nil
        guard model.acceptCloudConsent() else { state = .failed("Your choice couldn’t be saved. Try again.", retryable: true); return }
        resume()
    }
    func declineConsent() {
        guard awaitingConsent != nil else { return }
        awaitingConsent = nil
        if state == .needsConsent { state = .failed("Going deeper uses the chat’s AI. Try again to choose.", retryable: true) }
    }

    private func run() {
        guard let owner, let model = owner.reader else { return }
        guard model.isSignedIn else { state = .needsSignIn; return }
        guard let local = owner.context.localContext else { state = .unavailable; return }
        guard model.hasCloudConsent else {
            awaitingConsent = { [weak self] in self?.run() }
            state = .needsConsent; return
        }
        guard model.chatProfileTable != nil else { state = .failed("Cloud models haven’t loaded. Try again in a moment.", retryable: true); return }
        guard let request = try? ChatGenerationRequest.paperConcept(operationID: UUID(), item: item, kind: kind, profile: model.equationProfile,
                                                                    localContext: local, visualAnswers: model.visualAnswers).linked(item: item.id) else {
            state = .failed("This concept couldn’t be sent.", retryable: false); return
        }
        concept = nil; text = ""; notCharged = false; answeredModel = nil; fromKept = false
        tracker = PaperConceptTracker(); showProgress()
        state = .loading
        task?.cancel()
        task = Task { [weak self] in await self?.stream(request) }
    }

    private func stream(_ request: ChatGenerationRequest) async {
        var credits: Int?, stopReason = "", ending: State = .loading, words = ""
        let model = owner?.reader, scope = model?.readerSessionID
        do {
            guard let events = try await model?.equationStream(request) else { state = .needsSignIn; progress = nil; return }
            tracker.opened(); showProgress()
            for try await event in events {
                guard !Task.isCancelled else { return }
                if tracker.apply(event) { concept = tracker.conceptSoFar }
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
        if ending == Self.failure("insufficient_credits"), let model {
            await model.refreshCreditBalance()
            guard !Task.isCancelled, model.readerSessionID == scope else { return }
            ending = .failed(model.creditsMessage(Self.noCredits, premium: ReaderModel.isPremium(request.profile.model)), retryable: true)
        }
        // Only the final concept is kept; a failure drops what streamed (the failure shows with Try again).
        concept = ending == .done ? tracker.conceptSoFar : nil
        text = words
        if ending == .done, concept == nil, words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ending = .failed("Couldn’t go deeper on this concept. Try again.", retryable: true)
        }
        notCharged = credits == 0 && (ending != .done || !["end_turn", "stop_sequence", "tool_use", "stop"].contains(stopReason))
        progress = nil
        state = ending
        guard ending == .done else { return }
        owner?.keep(PaperConceptAnswer(concept: concept, text: text, model: answeredModel), for: item.id)
        if let model { Task { await model.refreshCreditBalance() } }
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

import Foundation
import ScienceReaderCore

// Your AI usage (owner, 2026-10-22; docs/architecture/OPERATIONS_AND_BILLING.md "Your AI usage"): the account's own
// metered requests from `v1_ai_usage` (migration 0144), and what this device remembers about where each answer came from
// so a row can say Paper chat / General chat / Explain in Chat and name the paper from the library here.

/// Reads the signed-in account's usage pages. The live backend, the fixture host and the idle wrapper answer it.
protocol AIUsageSource: Sendable {
    func aiUsage(days: Int, activity: AIUsageActivity?, before: AIUsageCursor?, accountID: UUID) async throws -> AIUsagePage
}

/// `aiUsage` is in BackendClient.swift, beside the balance (it uses the client's private authorized request).
extension BackendClient: AIUsageSource {}

extension IdleBoundedChatTransport: AIUsageSource {
    func aiUsage(days: Int, activity: AIUsageActivity?, before: AIUsageCursor?, accountID: UUID) async throws -> AIUsagePage {
        guard let source = base as? any AIUsageSource else { throw ChatTransportError.rejected("unavailable") }
        return try await source.aiUsage(days: days, activity: activity, before: before, accountID: accountID)
    }
}

/// The cloud chat transport, remembering on this device which conversation kind and paper each operation was for, just
/// before it is sent (titles are never stored or sent: the usage screen looks them up in the library).
struct UsageRecordingChatTransport: ChatTransport, AIUsageSource {
    let base: any ChatTransport
    let environment: String

    func chatStream(_ request: ChatGenerationRequest, accountID: UUID) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        if !request.isLocalInference {
            AIUsageProvenanceStore(environment: environment, accountID: accountID).remember(request.operationID, AIUsageProvenance(request))
        }
        return try await base.chatStream(request, accountID: accountID)
    }
    func creditBalance(accountID: UUID) async throws -> CreditBalance { try await base.creditBalance(accountID: accountID) }
    func chatProfiles(accountID: UUID) async throws -> ChatProfileTable { try await base.chatProfiles(accountID: accountID) }
    func recordStop(operationID: UUID, accountID: UUID) async throws { try await base.recordStop(operationID: operationID, accountID: accountID) }
    func aiUsage(days: Int, activity: AIUsageActivity?, before: AIUsageCursor?, accountID: UUID) async throws -> AIUsagePage {
        guard let source = base as? any AIUsageSource else { throw ChatTransportError.rejected("unavailable") }
        return try await source.aiUsage(days: days, activity: activity, before: before, accountID: accountID)
    }
}

extension ReaderModel {
    /// The usage reader for the signed-in account, when the server can be asked.
    var aiUsageSource: (any AIUsageSource)? { chatTransport as? any AIUsageSource }

    /// What this device remembers for the signed-in account (nothing while signed out).
    func aiUsageProvenance() -> [UUID: AIUsageProvenance] {
        guard let accountID else { return [:] }
        return AIUsageProvenanceStore(environment: usageEnvironment, accountID: accountID).all()
    }

    /// The paper's title in this device's library, or nil (an operation from another device, or a paper since removed).
    func aiUsagePaperTitle(_ provenance: AIUsageProvenance?) -> String? {
        guard let provenance else { return nil }
        if let paper = aiUsagePaper(membership: provenance.membershipID, document: provenance.documentID) { return paper.title }
        if let membership = provenance.membershipID.flatMap(UUID.init(uuidString:)),
           let item = completeLibrary?.imports.first(where: { $0.id == membership && $0.visible }) { return item.metadata?.title ?? "Untitled paper" }
        return nil
    }

    /// The library paper a request named: its membership (an arXiv paper, a PDF the reader added by its id here, or a legacy
    /// arXiv item, whose chats and explainers name the library item: `legacyChatContext`, `paperLocalContext`), or its
    /// server document.
    func aiUsagePaper(membership: String?, document: UUID?) -> Paper? {
        if let membership = membership.flatMap(UUID.init(uuidString:)) {
            if let paper = papers.first(where: { $0.sourceMembership?.membershipID == membership }) { return paper }
            // A PDF the reader added: its id on this device (LocalPaperChatContext(ownPDF:); never sent).
            if let paper = papers.first(where: { $0.isLocalPDF && $0.id == membership }) { return paper }
            if let item = completeLibrary?.items.first(where: { $0.id == membership && $0.visible }),
               let paper = papers.first(where: { $0.id == item.documentID }) { return paper }
        }
        if let document, let paper = papers.first(where: { $0.id == document }) { return paper }
        return nil
    }

    // MARK: Each row's way back (owner, TestFlight 92: "a link here to the original resource in context")

    /// What the rows are looked up in, read once per page: this device's records, its history (synced, so a request from
    /// another device finds its chat too), its conversations and the explanations kept here.
    func aiUsageLookup() async -> AIUsageLookup {
        let state = privateState
        let history = await Task.detached(priority: .userInitiated) { state.usageHistory() }.value
        let conversations = Dictionary(state.conversationSummaries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        await refreshKeptExplanations()
        return AIUsageLookup(provenance: aiUsageProvenance(), history: history, conversations: conversations,
                             kept: keptFigureExplanations + keptEquationExplanations + keptPaperExplanations)
    }

    /// A row's activity name, the paper (or, for a general chat, the chat's title) under it, and where it leads: the
    /// conversation, the paper at the figure or equation with its explanation, the paper's AI Explainer, the papers a
    /// recommendation added, or the paper. No link when what it was for no longer exists here.
    func aiUsageRow(_ op: AIUsageOperation, lookup: AIUsageLookup) -> AIUsageRowContext {
        let p = lookup.provenance[op.id]
        var label = AIUsageFormat.activityLabel(op.activity, provenance: p)
        var paper = p.flatMap { aiUsagePaper(membership: $0.membershipID, document: $0.documentID) }
        var subtitle = aiUsagePaperTitle(p)
        var link: AIUsageLink?
        if op.activity == .recommendations {
            if let run = recommendationRun(for: op, provenance: p) {
                link = AIUsageLink(title: "Show papers", target: .recommendation)
                if subtitle == nil, case .catalog(let name) = run.subject { subtitle = "For " + name }
            }
        } else if let id = AIUsageFormat.conversation(for: op, provenance: p, history: lookup.history), let chat = lookup.conversations[id] {
            link = AIUsageLink(title: "Open chat", target: .conversation(id))
            if paper == nil, let document = chat.documentID { paper = aiUsagePaper(membership: document.wire, document: document) }
            subtitle = subtitle ?? paper?.title ?? chat.title
        } else if let p, let item = p.itemID, let action = p.action, let found = paper, !found.isSample {
            link = AIUsageLink(title: Self.explanationLinkTitle(action), target: .explanation(ExplanationSubject(paperID: found.id,
                paperTitle: found.title, manifestSHA256: found.readerBundle?.manifestSHA256 ?? "", itemID: item, label: "", action: action,
                savedAt: op.createdAt)))
        } else if let kept = AIUsageFormat.explanation(for: op, provenance: p, kept: lookup.kept),
                  let found = papers.first(where: { $0.id == kept.paperID && !$0.isSample }) {
            link = AIUsageLink(title: Self.explanationLinkTitle(kept.action), target: .explanation(kept))
            if kept.action == ChatAction.paperExplainer.rawValue { label = "AI Explainer" }
            subtitle = subtitle ?? found.title
        } else if let found = paper, !found.isSample, !AIUsageFormat.conversationActivities.contains(op.activity) {
            // An explainer recorded before its item was: its paper. A chat that is gone has no link (not its paper).
            link = AIUsageLink(title: "Open paper", target: .paper(found.id))
        }
        return AIUsageRowContext(label: label, subtitle: subtitle, link: link)
    }

    private static func explanationLinkTitle(_ action: String) -> String {
        if action == ChatAction.paperExplainer.rawValue { return "Open AI Explainer" }
        // Go deeper on a concept: the explainer with that concept's kept card in front.
        if action == ChatAction.paperConcept.rawValue { return "Open concept" }
        return action.hasPrefix("equation") ? "Open equation" : "Open figure"
    }

    /// Opens what a row was for: Settings (or the credits store) gives way to the chat or the paper; a recommendation's
    /// papers open over the screen, as when it ran.
    func openAIUsageTarget(_ target: AIUsageTarget, operation: AIUsageOperation) {
        if case .recommendation = target {
            guard let run = recommendationRun(for: operation, provenance: aiUsageProvenance()[operation.id]) else { return }
            let present = { [weak self] in guard let self else { return }; self.recommendation = run; self.showRecommendations = true }
            // The store's sheet and the recommendations' share a host: the store closes first.
            if showStore { showStore = false; Task { @MainActor in try? await Task.sleep(for: .milliseconds(450)); present() } } else { present() }
            return
        }
        showStore = false
        if settingsPresented { settingsPresented = false }
        switch target {
        case .conversation(let id): openConversation(id)
        case .explanation(let subject): if !openExplanation(subject) { error = "This paper isn’t in your library on this device." }
        case .paper(let id): if let paper = papers.first(where: { $0.id == id }) { select(paper) }
        case .recommendation: break
        }
        if tab == .settings { closeSettings() }
    }

    /// The papers a recommendation added, as its sheet shows them: the request still in view, or one rebuilt from what this
    /// device recorded (the papers still in the library; their reasons aren't kept). Nil when none of them is here.
    func recommendationRun(for op: AIUsageOperation, provenance: AIUsageProvenance?) -> RecommendationRun? {
        if let run = recommendation, run.body.operationID == op.id { return run }
        guard let provenance, provenance.kind == .recommendation else { return nil }
        let rows: [RecommendationRun.Row] = (provenance.added ?? []).compactMap { membership in
            guard let paper = aiUsagePaper(membership: membership, document: nil), let sourceID = paper.sourceID else { return nil }
            let recommended = RecommendedPaper(sourceID: sourceID, revision: paper.sourceRevision, title: paper.title, authors: paper.authorNames,
                                               year: paper.year, reason: "", status: .added, importID: UUID(uuidString: membership))
            return RecommendationRun.Row(paper: recommended, state: .added)
        }
        guard let first = rows.first else { return nil }
        let seed = aiUsagePaper(membership: provenance.membershipID, document: nil)
        let catalog = provenance.catalogID.flatMap { libraryCatalogs.catalog($0) }
        let subject: RecommendationRun.Subject = seed.map { .paper(title: $0.title) } ?? .catalog(name: catalog?.name ?? currentCatalog.name)
        let count = RecommendRequestBody.counts.first { $0 >= rows.count } ?? 5
        guard let body = RecommendRequestBody.make(operationID: op.id, count: count, scope: seed == nil ? .catalog : .paper,
                                                   seeds: [(sourceID: seed?.sourceID ?? first.paper.sourceID, keywords: [])]) else { return nil }
        let run = RecommendationRun(subject: subject, count: count, catalogID: provenance.catalogID ?? currentCatalog.id,
                                    catalogName: catalog?.name ?? currentCatalog.name, namesCatalog: libraryCatalogs.catalogs.count > 1, body: body)
        run.rows = rows
        let credits = Int(op.credits ?? 0)
        run.phase = .finished(RecommendDone(added: rows.count, requested: count, credits: credits, charged: credits > 0, reason: nil))
        return run
    }

    /// A recommendation remembers, on this device, the paper or catalog it was for and each library entry it added (ids
    /// only), so Your AI usage can show those papers again.
    func rememberRecommendation(_ run: RecommendationRun) {
        guard let accountID else { return }
        AIUsageProvenanceStore(environment: usageEnvironment, accountID: accountID).remember(run.body.operationID, AIUsageProvenance(
            kind: .recommendation, membershipID: run.seedMembership, catalogID: run.catalogID,
            added: run.rows.filter { $0.state == .added || $0.state == .removeFailed }.compactMap { $0.paper.importID?.wire }))
    }
}

/// What the usage rows are looked up in (`ReaderModel.aiUsageLookup`).
struct AIUsageLookup {
    var provenance: [UUID: AIUsageProvenance] = [:]
    var history: [AIUsageHistoryMessage] = []
    var conversations: [UUID: ConversationSummary] = [:]
    var kept: [ExplanationSubject] = []
}

/// A row's words and its way back.
struct AIUsageRowContext: Equatable {
    let label: String
    let subtitle: String?
    let link: AIUsageLink?
}

struct AIUsageLink: Equatable {
    let title: String
    let target: AIUsageTarget
}

enum AIUsageTarget: Equatable {
    case conversation(UUID)
    case explanation(ExplanationSubject)
    case paper(UUID)
    case recommendation
}

import Foundation
import ScienceReaderCore

/// The Library's order: a field and a direction. Each field has a natural direction (newest,
/// most read, A→Z first); table headers may reverse it. Rows without a value for the field
/// (never opened, no year) stay last in either direction.
struct LibrarySearchSort: Hashable, Sendable {
    enum Field: String, CaseIterable, Hashable, Sendable {
        case recent, title, authors, year, opened, progress, chats, tags, pages, source
        var label: String {
            switch self {
            case .recent: "Recent"; case .title: "Title"; case .authors: "Authors"; case .year: "Year"
            case .opened: "Opened"; case .progress: "Progress"; case .chats: "Chats"
            case .tags: "Tags"; case .pages: "Pages"; case .source: "Source"
            }
        }
        /// Orders that only the table's columns offer (the List's Sort menu keeps its original choices).
        var isTableOnly: Bool { self == .authors || self == .tags || self == .pages || self == .source }
        var defaultAscending: Bool { self == .title || self == .authors || self == .tags || self == .source }
        /// Orders by this device's reading activity or private chats rather than library metadata.
        var usesActivity: Bool { self == .opened || self == .progress || self == .chats }
    }
    var field: Field
    var ascending: Bool

    init(field: Field, ascending: Bool? = nil) {
        self.field = field
        self.ascending = ascending ?? field.defaultAscending
    }
    static let recent = Self(field: .recent)
    static let title = Self(field: .title)
}

/// Optional sort values beside the title/recency every candidate has. Activity values are a
/// snapshot taken when the candidates were prepared.
struct LibrarySortKeys: Equatable, Sendable {
    var authors: String? = nil
    var year: Int? = nil
    var opened: Date? = nil
    var progress: Double? = nil
    var chats = 0
    /// The first tag shown (`LibraryTags`).
    var tag: String? = nil
    var pages: Int? = nil
    /// The Source column's label (arXiv identifier or host).
    var source: String? = nil
}

/// The caller advances sourceRevision for searchable metadata changes, including
/// cached/guest presentation changes. Command-only changes have their own revision.
struct LibrarySearchKey: Equatable, Sendable {
    let sessionID: UUID
    let accountID: UUID?
    let sourceRevision: UInt64
    let query: String
    let sort: LibrarySearchSort
    let commandRevision: Int64
    /// Advances when the full-text index changes (a paper's text indexed or removed).
    let fullTextRevision: UInt64

    init(sessionID: UUID, accountID: UUID?, sourceRevision: UInt64, query: String,
         sort: LibrarySearchSort, commandRevision: Int64 = -1, fullTextRevision: UInt64 = 0) {
        self.sessionID = sessionID
        self.accountID = accountID
        self.sourceRevision = sourceRevision
        self.query = query
        self.sort = sort
        self.commandRevision = commandRevision
        self.fullTextRevision = fullTextRevision
    }
}

/// Metadata only: no model row, reader bytes, selection or account capabilities.
/// Strings/arrays retain their existing copy-on-write storage across requests.
struct LibrarySearchCandidate: Equatable, Sendable {
    let id: String
    let title: String
    let fields: [String]
    let recentSequence: Int64
    let position: Int
    var keys = LibrarySortKeys()
    /// The paper's documents in the full-text index (its ID); nil for imports and queued commands.
    var fullTextKey: String? = nil
    /// What each of `fields` is, for a result's match line ("100% · title"); a field without one counts as tags.
    var fieldKinds: [SearchMatchField] = []
    /// 0: matches the filters. 1: a tag filter's possible related paper (Filter + related), shown only when
    /// `LibraryRelatedRequest` admits it, and after every group-0 row whatever the order.
    var group = 0

    func kind(of field: Int) -> SearchMatchField { field < fieldKinds.count ? fieldKinds[field] : field == 0 ? .title : .tags }
    /// The first field of this kind (the abstract, the authors), for a result's excerpt.
    func text(of kind: SearchMatchField) -> String? { fieldKinds.firstIndex(of: kind).flatMap { fields.indices.contains($0) ? fields[$0] : nil } }
}

struct LibrarySearchTicket: Equatable, Sendable {
    let key: LibrarySearchKey
    let id: UUID

    init(key: LibrarySearchKey) {
        self.key = key
        id = UUID()
    }
}

struct LibrarySearchInput: Sendable {
    let ticket: LibrarySearchTicket
    let candidates: [LibrarySearchCandidate]
    /// This account's encrypted full-text index (docs/architecture/NATIVE_LIBRARY_SEARCH.md); nil searches metadata only.
    var fullText: FullTextIndexStore? = nil
    /// Filter + related: which group-1 candidates join the tagged papers (TagRelated), worked out here, off the main actor.
    var related: LibraryRelatedRequest? = nil
}

/// A tag filter with its related papers (owner, TestFlight 92; docs/architecture/INTEREST_INDEX.md "Related papers for a
/// tag"): the tag, the current catalog's papers carrying it, and the candidates (the group-1 rows), with their public
/// fingerprints where the device has them and the pool's term statistics. Nothing here leaves the device.
struct LibraryRelatedRequest: Sendable, Equatable {
    let tag: String
    let tagged: [TagRelated.Paper]
    let candidates: [TagRelated.Paper]
    /// The term statistics' digest (equality), and the statistics.
    let termsDigest: String?
    let terms: InterestTerms?

    static func == (a: Self, b: Self) -> Bool {
        a.tag == b.tag && a.termsDigest == b.termsDigest && a.tagged == b.tagged && a.candidates == b.candidates
    }

    func select() -> [String: TagRelated.Reason] {
        TagRelated.select(tag: tag, tagged: tagged, candidates: candidates, terms: terms)
    }
}

/// Matching rows in order, and a body snippet for the first rows whose match was in the paper's text.
struct LibrarySearchOutput: Sendable {
    var rowIDs: [String]
    var snippets: [String: FullTextSnippet] = [:]
    /// With a query: each row's match (strength, title highlights, and for the first rows one excerpt).
    var matches: [String: SearchResultMatch] = [:]
    /// Filter + related: why each related row is listed.
    var related: [String: TagRelated.Reason] = [:]
}

struct LibrarySearchResult: Sendable {
    let ticket: LibrarySearchTicket
    let rowIDs: [String]
    let snippets: [String: FullTextSnippet]
    var matches: [String: SearchResultMatch] = [:]
    var related: [String: TagRelated.Reason] = [:]
    /// Time inside the worker, separate from caller snapshot/publication work
    /// and submit-to-result latency. An injected async worker may also suspend.
    let workerElapsedMilliseconds: Double
}

enum LibrarySearchEvent: Sendable {
    case completed(LibrarySearchResult)
    case failed(LibrarySearchTicket)
}

enum LibrarySearchEngine {
    /// Rows (in display order) that get a body snippet; later rows show none.
    static let snippetLimit = 100
    /// A clause that only a metadata substring matched (part of a word, punctuation) adds this to the score.
    static let substringScore = 1.0
    /// The newest paper's score is multiplied by 1 + this, the oldest's by 1.
    static let recencyBoost = 0.1

    /// Metadata only (no full-text index): the existing localized substring rules.
    static func search(_ input: LibrarySearchInput) throws -> [String] {
        try match(input, query: FullTextQuery(input.ticket.key.query), hits: [:], snapshot: nil, related: input.related?.select()).rowIDs
    }

    /// The Library search: every clause (word or quoted phrase) must match, either in the full-text index (words,
    /// phrases, the last word as a prefix, in title, authors, tags, abstract, notes or the paper's text) or as a
    /// localized substring of the row's metadata fields as before, so results are never fewer than metadata alone.
    static func run(_ input: LibrarySearchInput) async throws -> LibrarySearchOutput {
        try Task.checkCancellation()
        let query = FullTextQuery(input.ticket.key.query)
        var hits: [String: FullTextHit] = [:]
        var snapshot: FullTextSnapshot?
        if let store = input.fullText, !query.isEmpty, input.candidates.contains(where: { $0.fullTextKey != nil }) {
            snapshot = try? await store.snapshot()
            try Task.checkCancellation()
            hits = snapshot?.search(query, isCancelled: { Task.isCancelled }) ?? [:]
        }
        try Task.checkCancellation()
        return try match(input, query: query, hits: hits, snapshot: snapshot, related: input.related?.select())
    }

    /// Whitespace-separated words outside quotes and quoted phrases are ANDed; each may match any of the caller's
    /// original fields (localized substring) or the paper's full-text hit. With a query and the default Recent
    /// order, rows are ranked by relevance (BM25 with field weights, a small recency boost); every other order sorts
    /// as before.
    /// `related`: the group-1 candidates that join (Filter + related); the others are left out.
    static func match(_ input: LibrarySearchInput, query: FullTextQuery, hits: [String: FullTextHit],
                      snapshot: FullTextSnapshot?, related: [String: TagRelated.Reason]? = nil) throws -> LibrarySearchOutput {
        try Task.checkCancellation()
        let clauses = query.clauses
        var matches: [Int] = []
        var scores: [Double] = []
        /// Per matching row, each clause's strongest field.
        var clauseFields: [[SearchMatchField?]] = []
        matches.reserveCapacity(input.candidates.count)
        for (index, candidate) in input.candidates.enumerated() {
            try Task.checkCancellation()
            if candidate.group == 1, related?[candidate.id] == nil { continue }
            let hit = candidate.fullTextKey.flatMap { hits[$0] }
            var includesEveryClause = true
            var score = hit?.score ?? 0
            var found = [SearchMatchField?](repeating: nil, count: clauses.count)
            for (clauseIndex, clause) in clauses.enumerated() {
                try Task.checkCancellation()
                if let hit, hit.clauses & (1 << UInt64(clauseIndex)) != 0 { found[clauseIndex] = hit.strongestField(clause: clauseIndex); continue }
                // The strongest metadata field containing it (the first one found unless a stronger one follows).
                var strongest: SearchMatchField?
                for (offset, field) in candidate.fields.enumerated() {
                    try Task.checkCancellation()
                    let kind = candidate.kind(of: offset)
                    if let strongest, strongest <= kind { continue }
                    if field.localizedStandardContains(clause.text) { strongest = kind }
                }
                guard let strongest else {
                    includesEveryClause = false
                    break
                }
                found[clauseIndex] = strongest
                score += substringScore
            }
            if includesEveryClause { matches.append(index); scores.append(score); clauseFields.append(found) }
        }
        try Task.checkCancellation()
        let sort = input.ticket.key.sort
        if !clauses.isEmpty && sort.field == .recent && !sort.ascending {
            // Relevance, then recent order. Recency: the creation sequence's place between the oldest and newest.
            let sequences = input.candidates.lazy.map(\.recentSequence).filter { $0 != Int64.max }
            let oldest = sequences.min() ?? 0, newest = sequences.max() ?? 0
            var ranked: [Double] = []
            ranked.reserveCapacity(matches.count)
            for (offset, index) in matches.enumerated() {
                let sequence = input.candidates[index].recentSequence
                let recency = sequence == Int64.max || newest == oldest ? 1 : Double(sequence - oldest) / Double(newest - oldest)
                ranked.append(scores[offset] * (1 + recencyBoost * recency))
            }
            var order = Array(matches.indices)
            try order.sort { left, right in
                try Task.checkCancellation()
                let groups = (input.candidates[matches[left]].group, input.candidates[matches[right]].group)
                if groups.0 != groups.1 { return groups.0 < groups.1 }
                if ranked[left] != ranked[right] { return ranked[left] > ranked[right] }
                return ordered(input.candidates[matches[left]], before: input.candidates[matches[right]], by: sort)
            }
            matches = order.map { matches[$0] }; clauseFields = order.map { clauseFields[$0] }
        } else {
            // Sort just the matching indexes once. Neither the search nor the sort
            // builds a second joined/lowercased representation of large metadata.
            var order = Array(matches.indices)
            try order.sort { left, right in
                try Task.checkCancellation()
                return ordered(input.candidates[matches[left]], before: input.candidates[matches[right]], by: sort)
            }
            matches = order.map { matches[$0] }; clauseFields = order.map { clauseFields[$0] }
        }
        try Task.checkCancellation()
        var rowIDs: [String] = []
        rowIDs.reserveCapacity(matches.count)
        var snippetRows: [(row: String, hit: FullTextHit)] = []
        let all: UInt64 = clauses.count >= 64 ? .max : (1 << UInt64(clauses.count)) - 1
        for index in matches {
            try Task.checkCancellation()
            let candidate = input.candidates[index]
            rowIDs.append(candidate.id)
            if snapshot != nil, snippetRows.count < snippetLimit, let hit = candidate.fullTextKey.flatMap({ hits[$0] }),
               hit.bodyClauses != 0, hit.clauses & all != 0 {
                snippetRows.append((candidate.id, hit))
            }
        }
        var snippets: [String: FullTextSnippet] = [:]
        if let snapshot, !snippetRows.isEmpty {
            // Each snippet reads one sealed text (a fraction of a millisecond); in parallel.
            let results = SnippetResults(count: snippetRows.count)
            DispatchQueue.concurrentPerform(iterations: snippetRows.count) { offset in
                guard !Task.isCancelled else { return }
                results.set(offset, snapshot.snippet(for: snippetRows[offset].hit))
            }
            try Task.checkCancellation()
            for (offset, row) in snippetRows.enumerated() { if let snippet = results.value(offset) { snippets[row.row] = snippet } }
        }
        var displayed: [String: SearchResultMatch] = [:]
        if !clauses.isEmpty {
            displayed.reserveCapacity(matches.count)
            for (offset, index) in matches.enumerated() {
                try Task.checkCancellation()
                let candidate = input.candidates[index], match = SearchMatch(clauseFields: clauseFields[offset])
                displayed[candidate.id] = offset < snippetLimit
                    ? resultMatch(match, query: query, candidate: candidate, body: snippets[candidate.id])
                    : SearchResultMatch(match: match)
            }
        }
        return LibrarySearchOutput(rowIDs: rowIDs, snippets: snippets, matches: displayed, related: related ?? [:])
    }

    /// A row's match as shown: the title's matched words, and one excerpt of where else it matched: the paper's text
    /// (the snippet), its abstract or its authors, whichever shows the most words the title doesn't (then in that order
    /// of strength: abstract, authors, text). Nothing more when the title shows every word.
    static func resultMatch(_ match: SearchMatch, query: FullTextQuery, candidate: LibrarySearchCandidate, body: FullTextSnippet?) -> SearchResultMatch {
        let title = SearchHighlighter.occurrences(query, in: candidate.title)
        var result = SearchResultMatch(match: match, titleHighlights: SearchHighlighter.highlights(query, in: candidate.title))
        let inTitle = Set(title.map(\.clause))
        guard inTitle.count < match.total else { return result }
        var best: (shown: Int, field: SearchMatchField, excerpt: FullTextSnippet)?
        func consider(_ field: SearchMatchField, _ excerpt: FullTextSnippet?) {
            guard let excerpt else { return }
            let shown = SearchHighlighter.clauses(query, in: excerpt.text).subtracting(inTitle).count
            if shown > 0, shown > best?.shown ?? 0 || (shown == best?.shown && field < best!.field) { best = (shown, field, excerpt) }
        }
        for field in [SearchMatchField.abstract, .authors] where match.clauseFields.contains(field) {
            if let text = candidate.text(of: field), !text.isEmpty { consider(field, SearchHighlighter.excerpt(query, in: text)) }
        }
        consider(.fullText, body)
        if let best { result.excerpt = best.excerpt; result.excerptField = best.field }
        return result
    }

    /// The one Library ordering, shared by the search worker and the table's header comparator.
    /// Title ties fall back to stable row IDs; every other tie keeps recent order (creation
    /// sequence, then source position).
    static func ordered(_ left: LibrarySearchCandidate, before right: LibrarySearchCandidate, by sort: LibrarySearchSort) -> Bool {
        // Filter + related: the tagged papers first, then the related ones, each in the chosen order.
        if left.group != right.group { return left.group < right.group }
        let recent = left.recentSequence == right.recentSequence
            ? left.position < right.position : left.recentSequence > right.recentSequence
        let increasing: ComparisonResult = sort.ascending ? .orderedAscending : .orderedDescending
        /// nil: equal, so recent order decides. Missing values sort last in both directions.
        func compare<Value: Comparable>(_ l: Value?, _ r: Value?) -> Bool? {
            switch (l, r) {
            case let (l?, r?): l == r ? nil : (sort.ascending ? l < r : l > r)
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): nil
            }
        }
        /// Text in reading order ("2001.08361" before "2106.09685"); missing values last.
        func compareText(_ l: String?, _ r: String?) -> Bool {
            switch (l, r) {
            case let (l?, r?):
                let order = l.localizedStandardCompare(r)
                return order == .orderedSame ? recent : order == increasing
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return recent
            }
        }
        switch sort.field {
        case .recent:
            if sort.ascending, left.recentSequence != right.recentSequence { return left.recentSequence < right.recentSequence }
            return recent
        case .title:
            let order = left.title.localizedCompare(right.title)
            return order == .orderedSame ? left.id < right.id : order == increasing
        case .authors:
            switch (left.keys.authors, right.keys.authors) {
            case let (l?, r?):
                let order = l.localizedCompare(r)
                return order == .orderedSame ? recent : order == increasing
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return recent
            }
        case .year: return compare(left.keys.year, right.keys.year) ?? recent
        case .opened: return compare(left.keys.opened, right.keys.opened) ?? recent
        case .progress: return compare(left.keys.progress, right.keys.progress) ?? recent
        case .chats: return compare(left.keys.chats, right.keys.chats) ?? recent
        case .tags: return compareText(left.keys.tag, right.keys.tag)
        case .pages: return compare(left.keys.pages, right.keys.pages) ?? recent
        case .source: return compareText(left.keys.source, right.keys.source)
        }
    }
}

/// Owns one computation and one replaceable pending input. Cancellation fences
/// publication immediately, but replacement work waits for the old worker to
/// actually return, even if an injected worker ignores cancellation.
/// Snippets written by concurrent workers, each to its own slot.
private final class SnippetResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FullTextSnippet?]
    init(count: Int) { values = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: FullTextSnippet?) { lock.withLock { values[index] = value } }
    func value(_ index: Int) -> FullTextSnippet? { lock.withLock { values[index] } }
}

@MainActor
final class LibrarySearchCoordinator {
    /// A metadata-only worker returning row IDs (tests inject these).
    typealias Worker = @Sendable (LibrarySearchInput) async throws -> [String]
    typealias OutputWorker = @Sendable (LibrarySearchInput) async throws -> LibrarySearchOutput
    typealias Publish = @MainActor (LibrarySearchEvent) -> Void

    private struct Running: Sendable {
        let ticket: LibrarySearchTicket
        let task: Task<LibrarySearchResult, Error>
    }

    private let worker: OutputWorker
    private let publish: Publish
    private var current: LibrarySearchTicket?
    private var pending: LibrarySearchInput?
    private var running: Running?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(worker: @escaping Worker, publish: @escaping Publish) {
        self.worker = { LibrarySearchOutput(rowIDs: try await worker($0)) }
        self.publish = publish
    }

    /// The Library's own search: metadata and, when given, the full-text index.
    init(publish: @escaping Publish) {
        self.worker = { try await LibrarySearchEngine.run($0) }
        self.publish = publish
    }

    deinit { running?.task.cancel() }

    @discardableResult
    func submit(key: LibrarySearchKey, candidates: [LibrarySearchCandidate], fullText: FullTextIndexStore? = nil,
                related: LibraryRelatedRequest? = nil) -> LibrarySearchTicket {
        let ticket = LibrarySearchTicket(key: key)
        current = ticket
        pending = LibrarySearchInput(ticket: ticket, candidates: candidates, fullText: fullText, related: related)
        running?.task.cancel()
        startPendingIfIdle()
        return ticket
    }

    /// Also used at account/session retirement. Keep tracking canceled work so
    /// a later activation cannot run a second computation concurrently with it.
    func invalidate() {
        current = nil
        pending = nil
        running?.task.cancel()
        resumeIdleWaitersIfIdle()
    }

    /// Joins accepted work and any replacement submitted before the next idle
    /// boundary. This does not manufacture completion for a canceled worker.
    func waitForIdle() async {
        guard running != nil || pending != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func startPendingIfIdle() {
        guard running == nil, let input = pending else { return }
        pending = nil
        let worker = worker
        let task = Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            let output = try await worker(input)
            let elapsed = started.duration(to: .now).components
            return LibrarySearchResult(ticket: input.ticket, rowIDs: output.rowIDs, snippets: output.snippets, matches: output.matches,
                related: output.related, workerElapsedMilliseconds: Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
        }
        running = Running(ticket: input.ticket, task: task)
        Task { @MainActor [weak self] in
            let result = await task.result
            self?.finished(input.ticket, result: result)
        }
    }

    private func finished(_ ticket: LibrarySearchTicket, result: Result<LibrarySearchResult, Error>) {
        guard running?.ticket == ticket else { return }
        running = nil
        if current == ticket {
            switch result {
            case .success(let value): publish(.completed(value))
            case .failure: publish(.failed(ticket))
            }
        }
        // Publication may synchronously submit or invalidate. Both helpers
        // recheck current state rather than starting a second worker on return.
        startPendingIfIdle()
        resumeIdleWaitersIfIdle()
    }

    private func resumeIdleWaitersIfIdle() {
        guard running == nil, pending == nil else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

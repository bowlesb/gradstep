import Foundation

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

    init(sessionID: UUID, accountID: UUID?, sourceRevision: UInt64, query: String,
         sort: LibrarySearchSort, commandRevision: Int64 = -1) {
        self.sessionID = sessionID
        self.accountID = accountID
        self.sourceRevision = sourceRevision
        self.query = query
        self.sort = sort
        self.commandRevision = commandRevision
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
}

struct LibrarySearchResult: Sendable {
    let ticket: LibrarySearchTicket
    let rowIDs: [String]
    /// Time inside the worker, separate from caller snapshot/publication work
    /// and submit-to-result latency. An injected async worker may also suspend.
    let workerElapsedMilliseconds: Double
}

enum LibrarySearchEvent: Sendable {
    case completed(LibrarySearchResult)
    case failed(LibrarySearchTicket)
}

enum LibrarySearchEngine {
    /// Preserve the existing localized substring rules: whitespace-separated
    /// terms are ANDed; each term may match any of the caller's original fields.
    static func search(_ input: LibrarySearchInput) throws -> [String] {
        try Task.checkCancellation()
        let terms = input.ticket.key.query.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [Int] = []
        matches.reserveCapacity(input.candidates.count)
        for (index, candidate) in input.candidates.enumerated() {
            try Task.checkCancellation()
            var includesEveryTerm = true
            for term in terms {
                try Task.checkCancellation()
                var includesTerm = false
                for field in candidate.fields {
                    try Task.checkCancellation()
                    if field.localizedStandardContains(term) {
                        includesTerm = true
                        break
                    }
                }
                if !includesTerm {
                    includesEveryTerm = false
                    break
                }
            }
            if includesEveryTerm { matches.append(index) }
        }
        try Task.checkCancellation()
        // Sort just the matching indexes once. Neither the search nor the sort
        // builds a second joined/lowercased representation of large metadata.
        let sort = input.ticket.key.sort
        try matches.sort { leftIndex, rightIndex in
            try Task.checkCancellation()
            return ordered(input.candidates[leftIndex], before: input.candidates[rightIndex], by: sort)
        }
        try Task.checkCancellation()
        var rowIDs: [String] = []
        rowIDs.reserveCapacity(matches.count)
        for index in matches {
            try Task.checkCancellation()
            rowIDs.append(input.candidates[index].id)
        }
        return rowIDs
    }

    /// The one Library ordering, shared by the search worker and the table's header comparator.
    /// Title ties fall back to stable row IDs; every other tie keeps recent order (creation
    /// sequence, then source position).
    static func ordered(_ left: LibrarySearchCandidate, before right: LibrarySearchCandidate, by sort: LibrarySearchSort) -> Bool {
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
@MainActor
final class LibrarySearchCoordinator {
    typealias Worker = @Sendable (LibrarySearchInput) async throws -> [String]
    typealias Publish = @MainActor (LibrarySearchEvent) -> Void

    private struct Running: Sendable {
        let ticket: LibrarySearchTicket
        let task: Task<LibrarySearchResult, Error>
    }

    private let worker: Worker
    private let publish: Publish
    private var current: LibrarySearchTicket?
    private var pending: LibrarySearchInput?
    private var running: Running?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(worker: @escaping Worker = { try LibrarySearchEngine.search($0) },
         publish: @escaping Publish) {
        self.worker = worker
        self.publish = publish
    }

    deinit { running?.task.cancel() }

    @discardableResult
    func submit(key: LibrarySearchKey, candidates: [LibrarySearchCandidate]) -> LibrarySearchTicket {
        let ticket = LibrarySearchTicket(key: key)
        current = ticket
        pending = LibrarySearchInput(ticket: ticket, candidates: candidates)
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
            let rowIDs = try await worker(input)
            let elapsed = started.duration(to: .now).components
            return LibrarySearchResult(ticket: input.ticket, rowIDs: rowIDs,
                workerElapsedMilliseconds: Double(elapsed.seconds) * 1_000
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

import Foundation
import ScienceReaderCore
import UIKit

/// Keeps the account's sealed everything index (docs/architecture/GLOBAL_SEARCH.md) in step with what global search
/// finds besides papers: conversations and their messages, diagrams, kept equation, figure and paper explanations,
/// snippet collections and snippets (with the reading's text under a drawn region and Vision's recognised text). Runs
/// off the main actor at utility priority after a change, coalesced: two seconds after the last change, at once after
/// 64 changes, and when the app goes to the background. Each item has a fingerprint, so an unchanged one is never
/// rebuilt: messages are immutable events (their ID and status), explanations a file and its date, the rest their words.
@MainActor
final class EverythingIndexer {
    /// What one pass reads, captured on the main actor: values (copy-on-write), never the model.
    struct Sources: Sendable {
        var state = PrivateState()
        var summaries: [ConversationSummary] = []
        var notes = NotesState()
        /// Library papers' titles, for a chat's paper.
        var paperTitles: [UUID: String] = [:]
        /// The library paper each snippet came from (by entry), for "In this paper".
        var notePapers: [UUID: UUID] = [:]
        /// Readings on this device by manifest, for the text under a drawn region.
        var readings: [String: ReaderBundleIndex] = [:]
        /// Text recognised in region images, by the full image's blob ID.
        var recognised: [UUID: String] = [:]
        var equations: EquationResultStore?
        var figures: EquationResultStore?
        var explainers: EquationResultStore?
    }

    private(set) var index: EverythingIndex?
    private var running: Task<Void, Never>?
    private var again = false
    private var scheduled: Task<Void, Never>?
    private var changes = 0
    /// Reads the sources at the start of each pass.
    var sources: (() -> Sources)?
    /// After each commit: the index changed (a showing search runs again).
    var changed: (() -> Void)?
    /// A long pass's progress (0…1), nil when done: the search screen's one quiet "Indexing" line.
    var progress: ((Double?) -> Void)?
    private var memoryObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    /// Coalescing (the proposal's measurement: one commit costs 22–81 ms, as it reseals the manifest).
    nonisolated static let quiet: Duration = .seconds(2)
    nonisolated static let changesBeforeCommit = 64
    /// Items per commit while building.
    nonisolated static let chunk = 512
    /// A pass with more items than this to index shows its progress.
    nonisolated static let progressFrom = 200

    init() {
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let index = self?.index else { return }
                Task { await index.unload() }
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func attach(_ index: EverythingIndex?) {
        guard index !== self.index else { return }
        detach()
        self.index = index
        if index != nil { schedule(after: .milliseconds(1_500)) }
    }

    /// Sign-out or account change: stop now. The index itself is closed with the account's other local writers.
    func detach() {
        scheduled?.cancel(); scheduled = nil
        running?.cancel(); running = nil
        again = false; changes = 0; index = nil
        progress?(nil)
    }

    /// Something searchable changed (a write, a sync merge, a tombstone, a kept explanation, recognised text).
    func noteChange() {
        guard index != nil else { return }
        changes += 1
        schedule(after: changes >= Self.changesBeforeCommit ? .zero : Self.quiet)
    }

    /// Index now (the app is going to the background, or a test).
    func flush() { if index != nil { schedule(after: .zero) } }

    private func schedule(after delay: Duration) {
        guard index != nil else { return }
        if running != nil { again = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func start() {
        guard let index, running == nil, let sources = sources?() else { return }
        again = false; changes = 0
        let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.changed?() }
        let progress: @MainActor @Sendable (Double?) -> Void = { [weak self] value in self?.progress?(value) }
        running = Task.detached(priority: .utility) { [weak self] in
            await Self.reconcile(index: index, sources: sources, changed: changed, progress: progress)
            await self?.finished()
        }
    }

    private func finished() {
        running = nil
        if again { again = false; schedule(after: .milliseconds(200)) }
    }

    /// Waits for the pass in progress (tests).
    func waitForIdle() async {
        while let running { await running.value }
    }

    // MARK: A pass

    /// One item to index: its group, its fingerprint, and how to build it (only when its fingerprint changed).
    struct Stub {
        let group: String
        let fingerprint: String
        let build: () -> SearchItem?
    }

    /// Every item the sources hold, as stubs (cheap: nothing is cleaned or decrypted here).
    nonisolated static func stubs(_ sources: Sources) -> [Stub] {
        var out: [Stub] = []
        let state = sources.state
        var deleted = Set<UUID>()
        for event in state.events.values where event.payload.kind == .tombstone { deleted.insert(event.payload.entityID) }
        // Conversations (All chats' summaries exclude deleted ones), and each one's paper.
        var conversationPapers: [UUID: UUID] = [:]
        for summary in sources.summaries {
            if let paper = summary.documentID { conversationPapers[summary.id] = paper }
            let item = SearchItem.conversation(id: summary.id, title: summary.title, paperID: summary.documentID,
                                               paperTitle: summary.documentID.flatMap { sources.paperTitles[$0] },
                                               passage: summary.anchor?.quote, date: summary.lastUsedAt ?? summary.startedAt)
            out.append(Stub(group: item.group, fingerprint: item.contentFingerprint) { item })
        }
        let live = Set(sources.summaries.map(\.id))
        var diagrams: [UUID: [AppliedEvent]] = [:]
        for event in state.events.values {
            let payload = event.payload
            switch payload.kind {
            case .message:
                guard let conversation = payload.conversationID, live.contains(conversation), !deleted.contains(payload.entityID),
                      let text = payload.text, !text.isEmpty else { continue }
                let paper = conversationPapers[conversation]
                let fingerprint = SearchItem.fingerprint("e", event.id.wire, payload.status?.rawValue ?? "-", paper?.wire ?? "-")
                out.append(Stub(group: "\(SearchItemKind.message.rawValue):\(event.id.wire)", fingerprint: fingerprint) {
                    .message(eventID: event.id, conversationID: conversation, paperID: paper, text: text,
                             byReader: payload.role == .user, date: payload.createdDate)
                })
            case .diagram:
                guard !deleted.contains(payload.entityID), payload.conversationID.map({ live.contains($0) }) ?? true else { continue }
                diagrams[payload.entityID, default: []].append(event)
            default: continue
            }
        }
        // A diagram's current revision (as `PrivateState.revisions` chooses it).
        for (id, revisions) in diagrams {
            let superseded = Set(revisions.flatMap(\.payload.parents))
            guard let event = revisions.filter({ !superseded.contains($0.id) }).min(by: { $0.id.wire < $1.id.wire }),
                  let diagram = ChatDiagram.decode(event.payload.text) else { continue }
            let conversation = event.payload.conversationID
            let paper = conversation.flatMap { conversationPapers[$0] }
            let fingerprint = SearchItem.fingerprint("d", event.id.wire, paper?.wire ?? "-")
            out.append(Stub(group: "\(SearchItemKind.diagram.rawValue):\(id.wire)", fingerprint: fingerprint) {
                .diagram(id: id, diagram: diagram, conversationID: conversation, paperID: paper, date: event.payload.createdDate)
            })
        }
        // Collections and snippets: their words are small; built here and compared by content.
        for note in sources.notes.notes {
            let collection = SearchItem.collection(id: note.id, name: note.title, date: Date(timeIntervalSince1970: Double(note.lastEdited) / 1_000))
            out.append(Stub(group: collection.group, fingerprint: collection.contentFingerprint) { collection })
            for entry in note.entries {
                let record = entry.record
                var extra: [String] = []
                if let anchor = record.anchor, let manifest = anchor.manifestSHA256, let reading = sources.readings[manifest] {
                    extra = NoteSearch.bundleText(anchor, in: reading)
                }
                let recognised = record.media.flatMap { sources.recognised[$0.full.blobID] }
                let item = SearchItem.snippet(record, collection: note.title, paperID: sources.notePapers[record.entryID], extra: extra,
                                              recognised: recognised, date: Date(timeIntervalSince1970: Double(entry.lastEdited) / 1_000))
                out.append(Stub(group: item.group, fingerprint: item.contentFingerprint) { item })
            }
        }
        // Kept explanations: a file and its date (decrypted only when new or rewritten).
        for (kind, store) in [(SearchItemKind.equation, sources.equations), (.figure, sources.figures), (.paperExplainer, sources.explainers)] {
            guard let store else { continue }
            for stamp in store.fileStamps() {
                let id = String(stamp.fileName.dropLast(".sealed".count))
                let fingerprint = SearchItem.fingerprint("f", stamp.fileName, String(stamp.modified.timeIntervalSince1970))
                out.append(Stub(group: "\(kind.rawValue):\(id)", fingerprint: fingerprint) {
                    explanation(kind, id: id, store: store)
                })
            }
        }
        return out
    }

    /// A kept explanation's item, read from its sealed file.
    nonisolated static func explanation(_ kind: SearchItemKind, id: String, store: EquationResultStore) -> SearchItem? {
        let fileName = id + ".sealed"
        switch kind {
        case .equation: return store.read(fileName: fileName, as: EquationAnswer.self).flatMap { SearchItem.equation(fileName: id, answer: $0) }
        case .figure: return store.read(fileName: fileName, as: FigureAnswer.self).flatMap { SearchItem.figure(fileName: id, answer: $0) }
        case .paperExplainer: return store.read(fileName: fileName, as: PaperExplainerAnswer.self).flatMap { SearchItem.paperExplainer(fileName: id, answer: $0) }
        default: return nil
        }
    }

    /// One pass: removals and every changed item, a chunk per commit (a search sees progress), then done.
    nonisolated static func reconcile(index: EverythingIndex, sources: Sources, changed: @escaping @MainActor @Sendable () -> Void,
                                      progress: @escaping @MainActor @Sendable (Double?) -> Void) async {
        let current = await index.fingerprints()
        let stubs = stubs(sources)
        let wanted = Set(stubs.map(\.group))
        var removing = current.keys.filter { !wanted.contains($0) }
        let pending = stubs.filter { current[$0.group] != $0.fingerprint }
        guard !pending.isEmpty || !removing.isEmpty else { return }
        let shows = pending.count > progressFrom
        if shows { await progress(0) }
        defer { if shows { Task { @MainActor in progress(nil) } } }
        var done = 0, batch: [(item: SearchItem, fingerprint: String)] = []
        func commit() async -> Bool {
            guard !Task.isCancelled else { return false }
            do { try await index.commit(batch, removing: removing) } catch { return false }
            batch = []; removing = []
            await changed()
            if shows { await progress(Double(done) / Double(pending.count)) }
            return true
        }
        for stub in pending {
            if Task.isCancelled { return }
            done += 1
            // An item whose source can't be read any more (an explanation removed meanwhile) is dropped.
            guard let item = stub.build() else { removing.append(stub.group); continue }
            batch.append((item, stub.fingerprint))
            if batch.count >= chunk { guard await commit() else { return } }
        }
        if !batch.isEmpty || !removing.isEmpty { _ = await commit() }
    }
}

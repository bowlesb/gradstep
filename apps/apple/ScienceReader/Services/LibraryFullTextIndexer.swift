import Foundation
import ScienceReaderCore
import UIKit

/// Keeps the account's encrypted full-text index (docs/architecture/NATIVE_LIBRARY_SEARCH.md, "Full-text index") in
/// step with the library: each paper's metadata (title, authors, tags, abstract, its notes and snippets) and the
/// text of each reading saved on this device. Work runs off the main actor at low priority, one paper body at a time;
/// an unchanged fingerprint is never reindexed, so after the first run a launch only compares fingerprints.
@MainActor
final class LibraryFullTextIndexer {
    /// One paper's metadata fields as the library shows them (documents and fingerprints are made off the main actor).
    struct PaperFields: Sendable {
        let group: String
        let title: String
        let authors: String
        let tags: [String]
        let abstract: String
        let notes: String
    }
    /// What one pass indexes, captured on the main actor.
    struct Inputs: Sendable {
        var papers: [PaperFields] = []
        /// Saved readings (both device stores), and the library paper each belongs to ("sourceID/revision" → group;
        /// "sourceID" alone when the library has no revision for it).
        var stores: [DeviceReaderStore] = []
        var groupsBySource: [String: String] = [:]
        /// Papers opened from a reading not kept in a device store (samples, older server readings): group → reading.
        var opened: [String: (fingerprint: String, index: ReaderBundleIndex)] = [:]
    }

    private(set) var store: FullTextIndexStore?
    private var running: Task<Void, Never>?
    private var again = false
    private var scheduled: Task<Void, Never>?
    private var opened: [String: (fingerprint: String, index: ReaderBundleIndex)] = [:]
    /// Reads the library at the start of each pass.
    var inputs: (() -> Inputs)?
    /// After each commit: the index changed (the model reruns a current search).
    var changed: (() -> Void)?
    private var memoryObserver: NSObjectProtocol?

    init() {
        // Decrypted segments are the index's memory (about 30 KB a paper); the next search reloads them.
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let store = self?.store else { return }
                Task { await store.unload() }
            }
        }
    }

    func attach(_ store: FullTextIndexStore?) {
        guard store !== self.store else { return }
        detach()
        self.store = store
        if store != nil { schedule(after: .milliseconds(800)) }
    }

    /// Sign-out or account change: stop now. The store itself is closed with the account's other local writers.
    func detach() {
        scheduled?.cancel(); scheduled = nil
        running?.cancel(); running = nil
        again = false; opened = [:]; store = nil
    }

    /// A paper opened from a reading that isn't saved in a device store: index its text once.
    func indexOpened(group: String, fingerprint: String, index: ReaderBundleIndex) {
        guard store != nil else { return }
        guard opened[group]?.fingerprint != fingerprint else { return }
        opened[group] = (fingerprint, index)
        schedule()
    }

    /// The library, its readings or its notes changed: reconcile soon (coalesced).
    func schedule(after delay: Duration = .milliseconds(400)) {
        guard store != nil else { return }
        if running != nil { again = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// Removes these papers' body text now (their downloaded copies are being deleted).
    func forgetBodies(_ groups: Set<String>) {
        guard let store, !groups.isEmpty else { return }
        for group in groups { opened[group] = nil }
        let removing = groups.map { FullTextDocumentID(group: $0, part: .body) }
        let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.changed?() }
        Task.detached(priority: .utility) {
            try? await store.commit(FullTextIndexStore.prepare([]), removing: removing)
            await changed()
        }
    }

    private func start() {
        guard let store, running == nil, var inputs = inputs?() else { return }
        inputs.opened = opened
        opened = [:]
        again = false
        let changed: @MainActor @Sendable () -> Void = { [weak self] in self?.changed?() }
        running = Task.detached(priority: .utility) { [weak self] in
            await Self.reconcile(store: store, inputs: inputs, changed: changed)
            await self?.finished()
        }
    }

    private func finished() {
        running = nil
        if again { again = false; schedule(after: .milliseconds(200)) }
    }

    /// One pass: metadata changes and removals in one commit, then each saved reading not yet indexed, in batches.
    nonisolated static func reconcile(store: FullTextIndexStore, inputs: Inputs, changed: @escaping @MainActor () -> Void) async {
        let current = await store.fingerprints()
        var wanted = Set<FullTextDocumentID>()
        var metadata: [FullTextDocument] = []
        for paper in inputs.papers {
            let document = FullTextLibrary.metadata(group: paper.group, title: paper.title, authors: paper.authors, tags: paper.tags,
                                                    abstract: paper.abstract, notes: paper.notes)
            wanted.insert(document.id)
            if current[document.id] != document.fingerprint { metadata.append(document) }
        }
        let groups = Set(inputs.papers.map(\.group))
        // Saved readings by paper; the first store (arXiv HTML copies) wins over the on-device model's readings.
        var bodies: [String: (store: DeviceReaderStore, record: LocalReaderRecord, fingerprint: String)] = [:]
        for readers in inputs.stores {
            for record in await readers.records() {
                guard let group = inputs.groupsBySource["\(record.identity.sourceID)/\(record.identity.revision)"] ?? inputs.groupsBySource[record.identity.sourceID],
                      groups.contains(group), bodies[group] == nil else { continue }
                bodies[group] = (readers, record, "s:" + record.identity.sha256.map { String(format: "%02x", $0) }.joined())
            }
        }
        for group in bodies.keys { wanted.insert(FullTextDocumentID(group: group, part: .body)) }
        for (id, fingerprint) in current where id.part == .body && fingerprint.hasPrefix("b:") && groups.contains(id.group) && bodies[id.group] == nil {
            wanted.insert(id)
        }
        var opened: [FullTextDocument] = []
        for (group, value) in inputs.opened where groups.contains(group) && bodies[group] == nil && current[.init(group: group, part: .body)] != value.fingerprint {
            opened.append(FullTextLibrary.body(group: group, fingerprint: value.fingerprint, text: FullTextLibrary.bodyText(value.index)))
            wanted.insert(.init(group: group, part: .body))
        }
        let removing = current.keys.filter { !wanted.contains($0) }
        if !metadata.isEmpty || !removing.isEmpty || !opened.isEmpty {
            guard !Task.isCancelled else { return }
            do { try await store.commit(FullTextIndexStore.prepare(metadata + opened), removing: removing) } catch { return }
            await changed()
        }
        // Bodies: decrypt each saved reading once, a few per commit so a search sees progress.
        var batch: [FullTextDocument] = []
        var batchCharacters = 0
        for (group, body) in bodies.sorted(by: { $0.key < $1.key }) where current[.init(group: group, part: .body)] != body.fingerprint {
            guard !Task.isCancelled else { return }
            guard let bundle = try? await body.store.read(body.record.identity) else { continue }
            let text = FullTextLibrary.bodyText(bundle.index)
            batch.append(FullTextLibrary.body(group: group, fingerprint: body.fingerprint, text: text))
            batchCharacters += text.utf8.count
            if batch.count >= 16 || batchCharacters >= 4_000_000 {
                guard !Task.isCancelled else { return }
                do { try await store.commit(FullTextIndexStore.prepare(batch)) } catch { return }
                batch = []; batchCharacters = 0
                await changed()
            }
        }
        if !batch.isEmpty, !Task.isCancelled {
            do { try await store.commit(FullTextIndexStore.prepare(batch)) } catch { return }
            await changed()
        }
    }
}

import Foundation
import ImageIO
import ScienceReaderCore
import UniformTypeIdentifiers

/// Settings › Your assets › Download your assets (owner, build 82: "Need a download assets button"): this device's own
/// content (chats, diagrams, figure breakdowns with their parts cut from the paper here, snippets with their images, the
/// explanations kept here) as one .zip made on the device
/// (AssetsExport.swift; the browser's lib/assets-export.ts makes the same). Nothing is sent: only a snippet image not yet
/// on this device is downloaded, encrypted, as Snippets downloads it. The zip waits in this app's temporary folder (complete
/// file protection) until it has been shared or saved, then is removed.
@MainActor @Observable final class AssetsExporter {
    enum State: Equatable {
        case idle
        /// Snippet images read so far, of the total (0 of 0 while the rest is gathered).
        case preparing(done: Int, total: Int)
        case ready(URL)
        case failed(String)
    }
    private(set) var state: State = .idle
    /// What was left out of the last export, in the README's words.
    private(set) var skipped: [String] = []
    /// The last export's files (paths inside the zip), for the fixture journeys.
    private(set) var files: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    var isPreparing: Bool { if case .preparing = state { true } else { false } }

    func start(_ model: ReaderModel) {
        guard !isPreparing else { return }
        finish()
        state = .preparing(done: 0, total: 0)
        task = Task { [weak self] in
            do {
                let (input, images) = try await Self.gather(model) { done, total in self?.state = .preparing(done: done, total: total) }
                let (url, result) = try await Task.detached(priority: .userInitiated) { try Self.write(input, images: images) }.value
                guard !Task.isCancelled, let self else { try? FileManager.default.removeItem(at: url); return }
                self.skipped = result.skipped; self.files = result.files.map(\.path)
                self.state = .ready(url)
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed("Your assets couldn’t be put together. Try again.")
            }
        }
    }

    /// The share sheet or save panel closed: the zip is removed from this device's temporary folder.
    func finish() {
        task?.cancel(); task = nil
        if case .ready(let url) = state { try? FileManager.default.removeItem(at: url) }
        state = .idle
    }

    // MARK: Gathering (on the main actor: the account's state), then building off it

    private static func gather(_ model: ReaderModel, progress: @escaping @MainActor (Int, Int) -> Void) async throws -> (AssetsExport.Input, [String: Data]) {
        let state = model.privateState
        let titles = Dictionary(model.papers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var skipped: [String] = []

        // Chats: the version whose last message is newest (a chat continued on two devices has two).
        let summaries = state.conversationSummaries()
        var exported: [AssetsExport.Chat] = [], unreadable = 0
        for summary in summaries {
            let branches = state.conversationBranches(summary.id)
            guard let branch = branches.max(by: { latest($0, state) < latest($1, state) }) else { if summary.messageCount > 0 { unreadable += 1 }; continue }
            let messages = branch.messages.compactMap { event -> AssetsExport.Message? in
                guard let role = event.payload.role, let text = event.payload.text else { return nil }
                return AssetsExport.Message(role: role == .user ? .user : .assistant, text: text, at: event.payload.createdAt, model: event.payload.model,
                                            interrupted: event.payload.status == .interrupted ? true : nil)
            }
            exported.append(AssetsExport.Chat(id: summary.id.wire, title: summary.title, paper: summary.documentID.flatMap { titles[$0] },
                                           startedAt: summary.startedAt.map(PrivateEvent.timestamp), passage: summary.anchor?.quote,
                                           versions: branches.count > 1 ? branches.count : nil, messages: messages))
        }
        if unreadable > 0 { skipped.append("\(unreadable) \(unreadable == 1 ? "chat" : "chats") couldn’t be read on this device yet.") }
        let chatTitles = Dictionary(summaries.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        let all = state.diagrams()
        let diagrams = all.filter { !$0.diagram.isFigureParts }.map { id, diagram -> AssetsExport.Diagram in
            let event = state.revisions(for: id).first
            return AssetsExport.Diagram(id: id.wire, title: diagram.title, format: diagram.format, source: diagram.source,
                                        at: event?.payload.createdAt, chat: event?.payload.conversationID.flatMap { chatTitles[$0] })
        }

        // Figure breakdowns (owner, TestFlight 92): their parts and notes sync with the chat, encrypted; their pictures are
        // never stored, so each is cut here from this device's copy of the paper, as the chat shows it. One whose paper isn't
        // downloaded here is left out (the ⓘ says so). Papers are read one at a time.
        let chats = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var breakdowns: [AssetsExport.Breakdown] = [], pictures: [String: Data] = [:], uncut = 0
        var byManifest: [String: [(id: UUID, stored: StoredFigureParts, event: AppliedEvent?)]] = [:]
        for (id, diagram) in all where diagram.isFigureParts {
            guard let stored = StoredFigureParts.decode(diagram.source) else { uncut += 1; continue }
            byManifest[stored.manifestSHA256, default: []].append((id, stored, state.revisions(for: id).first))
        }
        for manifest in byManifest.keys.sorted() {
            try Task.checkCancellation()
            let group = byManifest[manifest] ?? []
            let chat = group.lazy.compactMap { $0.event?.payload.conversationID.flatMap { chats[$0] } }.first
            let paper = chat?.documentID.flatMap { model.aiUsagePaper(membership: $0.wire, document: $0) }
            guard let bundle = await model.storedReaderBundle(manifest: manifest, paper: paper) else { uncut += group.count; continue }
            for (id, stored, event) in group {
                let cut = await figurePartPictures(stored, bundle: bundle)
                for (index, data) in cut.enumerated() { if let data { pictures["\(id.wire)/\(index + 1)"] = data } }
                let conversation = event?.payload.conversationID.flatMap { chats[$0] }
                breakdowns.append(AssetsExport.Breakdown(id: id.wire, title: stored.title, at: event?.payload.createdAt, chat: conversation?.title,
                    paper: conversation?.documentID.flatMap { titles[$0] ?? model.aiUsagePaper(membership: $0.wire, document: $0)?.title },
                    parts: stored.parts.enumerated().map { index, part in
                        AssetsExport.BreakdownPart(label: part.label, note: part.note, image: cut.indices.contains(index) && cut[index] != nil ? "image/png" : nil)
                    }))
            }
        }
        if uncut > 0 {
            skipped.append("\(uncut) figure \(uncut == 1 ? "breakdown isn’t" : "breakdowns aren’t") included: \(uncut == 1 ? "its paper isn’t" : "their papers aren’t") downloaded on this device.")
        }

        // Snippets, every collection (not only those a search shows), with their images decrypted here.
        let notes = NotesState(state).notes
        var collections: [AssetsExport.Collection] = [], wanted: [(String, NoteMedia)] = []
        for note in notes {
            let snippets = note.entries.map { entry -> AssetsExport.Snippet in
                let r = entry.record
                if let full = r.media?.full { wanted.append((r.entryID.wire, full)) }
                return AssetsExport.Snippet(id: r.entryID.wire, kind: AssetsExport.Snippet.Kind(rawValue: r.kind.rawValue) ?? .text, at: r.capturedAt,
                    comment: r.comment, quote: r.quote,
                    source: r.source.map { AssetsExport.SnippetSource(title: $0.title, section: $0.section, label: $0.label, url: $0.url, page: $0.page) },
                    image: r.media?.full.type)
            }
            collections.append(AssetsExport.Collection(id: note.id.wire, title: note.title, snippets: snippets))
        }
        var images = pictures
        progress(0, wanted.count)
        for (index, (id, media)) in wanted.enumerated() {
            try Task.checkCancellation()
            if let data = try? await model.noteImageData(media) { images[id] = data }
            progress(index + 1, wanted.count)
        }

        // Explanations kept on this device (sealed answers; opened off the main actor).
        let stores = (model.equationResultStore(), model.figureResultStore(), model.paperExplainerResultStore())
        let (explanations, unnamed) = await Task.detached(priority: .userInitiated) { explanationsKept(stores.0, stores.1, stores.2) }.value
        if unnamed > 0 { skipped.append("\(unnamed) older \(unnamed == 1 ? "explanation doesn’t" : "explanations don’t") say which paper \(unnamed == 1 ? "it belongs" : "they belong") to and \(unnamed == 1 ? "isn’t" : "aren’t") included.") }

        let input = AssetsExport.Input(exportedAt: PrivateEvent.timestamp(Date()), chats: exported, diagrams: diagrams, collections: collections,
                                       explanations: explanations, breakdowns: breakdowns.isEmpty ? nil : breakdowns, skipped: skipped)
        return (input, images)
    }

    /// Each part of a breakdown as the chat shows it (`ReaderModel.figurePartCrops`: completed on the figure as the question
    /// carried it and framed by confidence), as PNG; nil where the figure or a part couldn't be cut. Off the main actor.
    nonisolated static func figurePartPictures(_ stored: StoredFigureParts, bundle: VerifiedReaderBundle) async -> [Data?] {
        await Task.detached(priority: .userInitiated) { () -> [Data?] in
            let none = [Data?](repeating: nil, count: stored.parts.count)
            let panels = stored.paths.compactMap { bundle.data(for: $0).flatMap(ChatFigureFinder.image) }
            guard panels.count == stored.paths.count, let composed = ChatFigureFinder.composite(panels) else { return none }
            let asset = stored.paths.count == 1 ? bundle.data(for: stored.paths[0]) : nil
            let found = bundle.index.figures.first { $0.blockID == stored.blockID || $0.id == stored.blockID }
            let structure = found.flatMap { f in Array(f.assetPaths.prefix(ChatFigureFinder.maximumPanels)) == stored.paths ? ChatFigureFinder.structure(of: f, bundle: bundle) : nil }
            let crops = FigurePartCrop.all(stored, image: composed, asset: asset, caption: found?.caption ?? "", structure: structure)
            return stored.parts.indices.map { index in crops.indices.contains(index) ? crops[index].flatMap { png($0.image) } : nil }
        }.value
    }

    nonisolated private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func latest(_ branch: ConversationBranch, _ state: PrivateState) -> Int64 {
        branch.messages.last.flatMap { $0.payload.createdAt ?? state.arrivalIndex($0.id).map(Int64.init) } ?? -1
    }

    /// Each explained equation, figure, part or paper once (the newest answer, whatever model), as Your assets lists them.
    nonisolated private static func explanationsKept(_ equations: EquationResultStore?, _ figures: EquationResultStore?,
                                                     _ papers: EquationResultStore?) -> ([AssetsExport.Explanation], Int) {
        var seen = Set<String>(), out: [AssetsExport.Explanation] = [], unnamed = 0
        func once(_ subject: ExplanationSubject?, part: String = "") -> ExplanationSubject? {
            guard let subject else { unnamed += 1; return nil }
            return seen.insert("\(subject.paperID.wire)|\(subject.itemID)|\(subject.action)|\(part)").inserted ? subject : nil
        }
        let at = { (subject: ExplanationSubject) in PrivateEvent.timestamp(subject.savedAt) }
        for answer in equations?.all(as: EquationAnswer.self) ?? [] {
            guard let s = once(answer.subject) else { continue }
            out.append(AssetsExport.Explanation(kind: .equation, action: s.action, paper: s.paperTitle, label: s.label, at: at(s), model: answer.model,
                summary: answer.symbols?.summary,
                symbols: answer.symbols?.symbols.map { AssetsExport.Symbol(symbol: $0.symbol, latex: $0.latex, meaning: $0.meaning, source: $0.source.rawValue, paragraph: $0.paragraph) },
                text: answer.text))
        }
        for answer in figures?.all(as: FigureAnswer.self) ?? [] {
            if let action = answer.subject?.action, !FigureAnswer.isShownFigureAction(action) { continue }
            // A part explained more simply is its own answer: its words tell parts apart.
            guard let s = once(answer.subject, part: answer.subject?.action == ChatAction.figureSimpler.rawValue ? answer.text : "") else { continue }
            out.append(AssetsExport.Explanation(kind: .figure, action: s.action, paper: s.paperTitle, label: s.label, at: at(s), model: answer.model,
                summary: answer.walkthrough?.summary,
                sections: answer.walkthrough?.sections.map { AssetsExport.Section(name: $0.name, title: $0.title, text: $0.text, paragraphs: $0.paragraphs) },
                text: answer.text))
        }
        for answer in papers?.all(as: PaperExplainerAnswer.self) ?? [] {
            guard let s = once(answer.subject) else { continue }
            let e = answer.explainer
            let names = Dictionary(((e?.background ?? []) + (e?.ideas ?? [])).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let items = { (list: [PaperExplainer.Item]) in list.map { AssetsExport.Item(name: $0.name, line: $0.line, paragraphs: $0.paragraphs) } }
            out.append(AssetsExport.Explanation(kind: .paper, action: s.action, paper: s.paperTitle, label: s.label, at: at(s), model: answer.model,
                summary: e?.summary, background: e.map { items($0.background) }, ideas: e.map { items($0.ideas) },
                links: e?.links.map { AssetsExport.Link(from: names[$0.from] ?? $0.from, to: names[$0.to] ?? $0.to, label: $0.label) },
                text: answer.text))
        }
        return (out, unnamed)
    }

    /// The zip in this app's temporary folder (earlier exports removed first), with complete file protection as the
    /// account's own stores; and what it holds.
    nonisolated private static func write(_ input: AssetsExport.Input, images: [String: Data]) throws -> (URL, AssetsExport.Result) {
        let result = AssetsExport.build(input, images: images)
        let data = try AssetsExport.zip(result.files, at: input.exportedAt)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("assets-export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(result.fileName)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try data.write(to: url, options: options)
        return (url, result)
    }
}

extension ReaderModel {
    /// A paper revision's reading as this device holds it, by its bundle's manifest: the copy open now, else a saved copy of
    /// that paper in this device's reader stores (its arXiv reading or the on-device model's), read and checked here.
    /// Nothing is fetched: a paper that isn't downloaded has none.
    func storedReaderBundle(manifest: String, paper: Paper?) async -> VerifiedReaderBundle? {
        let open = (papers.map(\.readerBundle) + [selectedPaper?.readerBundle]).compactMap { $0 }
        if let bundle = open.first(where: { $0.manifestSHA256 == manifest }) { return bundle }
        guard let paper else { return nil }
        let sources = Set([paper.sourceID, paper.isLocalPDF ? LocalPDFMembership.sourceID(paper.id) : nil].compactMap { $0 })
        for store in [localPersistence.localReaderStore, localPersistence.modelReaderStore].compactMap({ $0 }) {
            for record in await store.records() where sources.contains(record.identity.sourceID) {
                guard let stored = try? await store.read(record.identity), stored.manifestSHA256 == manifest else { continue }
                return try? await Task.detached(priority: .userInitiated) { try ReaderBundleLoader.admitImages(in: stored) }.value
            }
        }
        return nil
    }
}

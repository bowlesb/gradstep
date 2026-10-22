import Foundation
import ScienceReaderCore

/// Settings › Your assets › Download your assets (owner, build 82: "Need a download assets button"): this device's own
/// content (chats, diagrams, snippets with their images, the explanations kept here) as one .zip made on the device
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
        var chats: [AssetsExport.Chat] = [], unreadable = 0
        for summary in summaries {
            let branches = state.conversationBranches(summary.id)
            guard let branch = branches.max(by: { latest($0, state) < latest($1, state) }) else { if summary.messageCount > 0 { unreadable += 1 }; continue }
            let messages = branch.messages.compactMap { event -> AssetsExport.Message? in
                guard let role = event.payload.role, let text = event.payload.text else { return nil }
                return AssetsExport.Message(role: role == .user ? .user : .assistant, text: text, at: event.payload.createdAt, model: event.payload.model,
                                            interrupted: event.payload.status == .interrupted ? true : nil)
            }
            chats.append(AssetsExport.Chat(id: summary.id.wire, title: summary.title, paper: summary.documentID.flatMap { titles[$0] },
                                           startedAt: summary.startedAt.map(PrivateEvent.timestamp), passage: summary.anchor?.quote,
                                           versions: branches.count > 1 ? branches.count : nil, messages: messages))
        }
        if unreadable > 0 { skipped.append("\(unreadable) \(unreadable == 1 ? "chat" : "chats") couldn’t be read on this device yet.") }
        let chatTitles = Dictionary(summaries.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        let diagrams = state.diagrams().map { id, diagram -> AssetsExport.Diagram in
            let event = state.revisions(for: id).first
            return AssetsExport.Diagram(id: id.wire, title: diagram.title, format: diagram.format, source: diagram.source,
                                        at: event?.payload.createdAt, chat: event?.payload.conversationID.flatMap { chatTitles[$0] })
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
        var images: [String: Data] = [:]
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

        let input = AssetsExport.Input(exportedAt: PrivateEvent.timestamp(Date()), chats: chats, diagrams: diagrams, collections: collections,
                                       explanations: explanations, skipped: skipped)
        return (input, images)
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

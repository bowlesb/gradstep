#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// Synthetic UI journeys only. Compiled out of physical-device and release builds;
/// the launch branch returns before constructing any network or account services.
extension ReaderModel {
    func configureWorkflowFixture() throws {
        openSample()
        guard let sample = selectedPaper else { return }
        papers.append(Paper(id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!,
            title: "Sparse metadata: an unpublished research note", authors: "", year: nil, abstract: "", keywords: [], fileURL: nil, artifactID: nil))
        let conversation = UUID(uuidString: "cccccccc-0000-0000-0000-000000000001")!
        let root = UUID(), device = UUID()
        try privateState.apply(AppliedEvent(id: root, deviceID: device, payload: PrivateEvent(kind: .conversation, entityID: conversation, documentID: sample.id, text: "Understanding attention")))
        var parent = root
        let turns: [(PrivateEvent.Role, String)] = [
            (.user, "How does self-attention scale with sequence length?"),
            (.assistant, "Self-attention compares each query with every key. Doubling the sequence length creates roughly four times as many pairwise scores.\n\nThe attention score matrix therefore takes quadratic memory in the sequence length. The cost of projecting tokens into queries, keys, and values also depends on the model width.\n\nFor a fair comparison, separate training from decoding, and measure latency and peak memory on the same hardware."),
            (.user, "What should I measure in a small experiment?"),
            (.assistant, "Use several sequence lengths and keep the batch size fixed. Record wall-clock time, peak memory, and the number of tokens processed.\n\nWarm up the model before measuring. GPU work is asynchronous, so synchronize around the timed region. Report the median and variation over repeated runs.\n\nFinally, check that the output remains numerically consistent. A faster implementation is useful only if it preserves the behavior your experiment requires."),
            (.user, "How would this affect reading a long paper?"),
            (.assistant, "A long document may need bounded context retrieval. Keep source passages and citations attached to each answer so that claims can be checked against the paper.\n\nThis is a synthetic conversation for layout testing; no AI request was made.")
        ]
        for (role, text) in turns {
            let id = UUID()
            try privateState.apply(AppliedEvent(id: id, deviceID: device, payload: PrivateEvent(kind: .message, parents: [parent], conversationID: conversation, documentID: sample.id, text: text, role: role, status: .complete)))
            parent = id
        }
        activeConversation = conversation
        if ProcessInfo.processInfo.arguments.contains("--branch-fixture") {
            try configureBranchWorkflowFixture(documentID: sample.id)
        }
        if ProcessInfo.processInfo.arguments.contains("--library-metadata-fixture") {
            try configureLibraryMetadataFixture(sample: sample)
        }
        if ProcessInfo.processInfo.arguments.contains("--feed-fixture") { installFeedFixture() }
        tab = .library; wideMode = .library
    }

    /// Varied library metadata for the table / detailed-row layouts: author counts, years,
    /// topics, added dates, this device's opened/progress values, chats, imports and states.
    /// Dates are relative to launch so labels read Today, Yesterday, a weekday, a date.
    private func configureLibraryMetadataFixture(sample: Paper) throws {
        let now = Date(), day: TimeInterval = 86_400
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "eeeeeeee-0000-0000-0000-%012ld", n))! }
        struct Row { let n: Int; let title: String; let authors: [String]; let year: Int?; let topics: [String]
            let addedDaysAgo: Double; let sequence: Int64; let pages: Int?; let opened: Double?; let progress: Double?
            let chats: Int; let offline: PaperOfflineStatus; var converted = true; var abstract = "" }
        let rows = [
            Row(n: 1, title: "Attention Is All You Need", authors: ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar", "Jakob Uszkoreit",
                "Llion Jones", "Aidan N. Gomez", "Łukasz Kaiser", "Illia Polosukhin"], year: 2017, topics: ["cs.CL", "cs.LG"],
                addedDaysAgo: 0, sequence: 9, pages: 15, opened: 0.1, progress: 0.6, chats: 2, offline: .available,
                abstract: "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks. We propose a new simple network architecture, the Transformer, based solely on attention mechanisms."),
            Row(n: 2, title: "Direct Preference Optimization: Your Language Model is Secretly a Reward Model",
                authors: ["Rafael Rafailov", "Archit Sharma", "Eric Mitchell", "Stefano Ermon", "Christopher D. Manning", "Chelsea Finn"],
                year: 2023, topics: ["cs.LG", "cs.AI", "cs.CL"], addedDaysAgo: 1, sequence: 8, pages: 27, opened: 3, progress: 0.25,
                chats: 1, offline: .available,
                abstract: "We introduce a new parameterization of the reward model in RLHF that enables extraction of the corresponding optimal policy in closed form."),
            Row(n: 3, title: "LoRA: Low-Rank Adaptation of Large Language Models", authors: ["Edward J. Hu", "Yelong Shen", "Phillip Wallis",
                "Zeyuan Allen-Zhu", "Yuanzhi Li", "Shean Wang", "Lu Wang", "Weizhu Chen"], year: 2021, topics: ["cs.CL", "cs.AI", "cs.LG"],
                addedDaysAgo: 4, sequence: 7, pages: 26, opened: nil, progress: nil, chats: 0, offline: .none,
                abstract: "We propose Low-Rank Adaptation, which freezes the pretrained model weights and injects trainable rank decomposition matrices into each layer."),
            Row(n: 5, title: "Deep Residual Learning for Image Recognition", authors: ["Kaiming He", "Xiangyu Zhang", "Shaoqing Ren", "Jian Sun"],
                year: 2015, topics: ["cs.CV"], addedDaysAgo: 12, sequence: 5, pages: 12, opened: 9, progress: 1, chats: 3, offline: .available,
                abstract: "We present a residual learning framework to ease the training of networks that are substantially deeper than those used previously."),
            Row(n: 6, title: "Adam: A Method for Stochastic Optimization", authors: ["Diederik P. Kingma", "Jimmy Ba"], year: 2014,
                topics: ["cs.LG"], addedDaysAgo: 30, sequence: 4, pages: 15, opened: 20, progress: 0.08, chats: 0, offline: .available,
                abstract: "We introduce Adam, an algorithm for first-order gradient-based optimization of stochastic objective functions."),
            Row(n: 7, title: "A Method for Unconstrained Convex Minimization Problem with the Rate of Convergence O(1/k²)",
                authors: ["Yurii Nesterov"], year: 1983, topics: ["math.OC"], addedDaysAgo: 400, sequence: 2, pages: 5, opened: nil,
                progress: nil, chats: 0, offline: .available),
        ]
        var papers: [Paper] = [], sequences: [UUID: Int64] = [:], offline: [UUID: PaperOfflineStatus] = [:]
        var activity: [UUID: PaperActivity] = [sample.id: PaperActivity(openedAt: now, progress: 0.35)]
        let device = UUID()
        for row in rows {
            let documentID = id(row.n)
            var paper = Paper(id: documentID, title: row.title, authors: row.authors.joined(separator: ", "), year: row.year,
                              abstract: row.abstract, keywords: row.topics, fileURL: nil, artifactID: id(100 + row.n))
            paper.authorNames = row.authors; paper.addedAt = now - row.addedDaysAgo * day; paper.pageCount = row.pages
            paper.canReadStructured = row.converted
            papers.append(paper); sequences[documentID] = row.sequence; offline[documentID] = row.offline
            if row.opened != nil || row.progress != nil {
                activity[documentID] = PaperActivity(openedAt: row.opened.map { now - $0 * day }, progress: row.progress)
            }
            for chat in 0..<row.chats {
                try privateState.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .conversation,
                    entityID: id(1_000 + row.n * 10 + chat), documentID: documentID, text: "About \(row.title.prefix(24))")))
            }
        }
        // The workflow's sparse note: no authors, year or topics, and no converted reader.
        var sparse = Paper(id: UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000001")!,
            title: "Sparse metadata: an unpublished research note", authors: "", year: nil, abstract: "", keywords: [], fileURL: nil, artifactID: nil)
        sparse.addedAt = now - 6 * day; sparse.canReadStructured = false
        papers.insert(sparse, at: 3); sequences[sparse.id] = 6
        func importRecord(_ n: Int, sequence: Int, phase: String, progress: String?, error: String?, title: String,
                          authors: [String], published: String, categories: [String], source: String,
                          detail: [String: Any]? = nil) throws -> LibraryImportRecord {
            var value: [String: Any] = ["id": id(n).wire, "created_seq": sequence, "state_seq": sequence, "intent_revision": 1,
                "visible": true, "phase": phase, "source": "arxiv", "source_id": source, "source_revision": 1,
                "metadata_id": id(n + 50).wire, "version_id": id(n + 60).wire,
                "metadata": ["title": title, "authors": authors, "published_at": published, "categories": categories] as [String: Any],
                "metadata_recorded_at": "2026-10-01T09:00:00Z", "source_url": "https://arxiv.org/abs/\(source)v1",
                "retryable": phase == "failed"]
            if let progress { value["progress"] = progress }
            if let error { value["error_code"] = error }
            if let detail { value["progress_detail"] = detail }
            return try JSONDecoder().decode(LibraryImportRecord.self, from: JSONSerialization.data(withJSONObject: value))
        }
        // `--import-progress-fixture` (import progress, 2026-10-07): imports at every step with the server's percent and
        // time left (migration 029): just added, downloading a large PDF, reading page 12 of 27, nearly ready, one
        // backing off after an error, and one from an older server (no detail: spinner and step time, as before).
        if ProcessInfo.processInfo.arguments.contains("--import-progress-fixture") {
            let progressImports = [
                try importRecord(30, sequence: 16, phase: "accepted", progress: "finding", error: nil,
                    title: "Mamba: Linear-Time Sequence Modeling with Selective State Spaces", authors: ["Albert Gu", "Tri Dao"],
                    published: "2023-12-01", categories: ["cs.LG", "cs.AI"], source: "2312.00752",
                    detail: ["step": "finding", "percent": 2, "eta_seconds": 47]),
                try importRecord(31, sequence: 15, phase: "acquiring", progress: "downloading", error: nil,
                    title: "High-Resolution Image Synthesis with Latent Diffusion Models", authors: ["Robin Rombach", "Andreas Blattmann",
                    "Dominik Lorenz", "Patrick Esser", "Björn Ommer"], published: "2021-12-20", categories: ["cs.CV"], source: "2112.10752",
                    detail: ["step": "downloading", "percent": 14, "eta_seconds": 52, "pages": 45, "bytes": 40_817_183]),
                try importRecord(20, sequence: 14, phase: "acquiring", progress: "converting", error: nil,
                    title: "Scaling Laws for Neural Language Models", authors: ["Jared Kaplan", "Sam McCandlish", "Tom Henighan",
                    "Tom B. Brown", "Benjamin Chess", "Rewon Child", "Scott Gray", "Alec Radford", "Jeffrey Wu", "Dario Amodei"],
                    published: "2020-01-23", categories: ["cs.LG", "stat.ML"], source: "2001.08361",
                    detail: ["step": "reading_equations", "percent": 62, "eta_seconds": 40, "pages": 27, "pages_done": 12]),
                try importRecord(32, sequence: 13, phase: "acquiring", progress: "rendering", error: nil,
                    title: "Proximal Policy Optimization Algorithms", authors: ["John Schulman", "Filip Wolski", "Prafulla Dhariwal",
                    "Alec Radford", "Oleg Klimov"], published: "2017-07-20", categories: ["cs.LG"], source: "1707.06347",
                    detail: ["step": "preparing", "percent": 91, "eta_seconds": 6, "pages": 12]),
                try importRecord(33, sequence: 12, phase: "acquiring", progress: "converting", error: nil,
                    title: "Denoising Diffusion Probabilistic Models", authors: ["Jonathan Ho", "Ajay Jain", "Pieter Abbeel"],
                    published: "2020-06-19", categories: ["cs.LG", "stat.ML"], source: "2006.11239",
                    detail: ["step": "reading_equations", "percent": 41, "delayed": true, "pages": 25, "pages_done": 9]),
                try importRecord(34, sequence: 11, phase: "acquiring", progress: "downloading", error: nil,
                    title: "Language Models are Few-Shot Learners", authors: ["Tom B. Brown", "Benjamin Mann", "Nick Ryder"],
                    published: "2020-05-28", categories: ["cs.CL"], source: "2005.14165"),
                try importRecord(35, sequence: 10, phase: "failed", progress: nil, error: "download_retrying",
                    title: "Adam: A Method for Stochastic Optimization", authors: ["Diederik P. Kingma", "Jimmy Ba"],
                    published: "2014-12-22", categories: ["cs.LG"], source: "1412.6980"),
                try importRecord(21, sequence: 3, phase: "failed", progress: nil, error: "insufficient_credits",
                    title: "Constitutional AI: Harmlessness from AI Feedback", authors: ["Yuntao Bai", "Saurav Kadavath", "Sandipan Kundu"],
                    published: "2022-12-15", categories: ["cs.CL", "cs.AI"], source: "2212.08073"),
            ]
            installLibraryMetadataFixture(papers: papers, imports: progressImports, sequences: sequences, activity: activity, offline: offline,
                importStepStarts: [id(34): now - 70], importDetailsReceived: Dictionary(uniqueKeysWithValues: progressImports.map { ($0.id, now) }))
            return
        }
        // `--slow-import-fixture`: the converting import has been in its step for minutes (taking longer than usual),
        // another has been downloading for a minute, and a third failed to download (retryable).
        let slow = ProcessInfo.processInfo.arguments.contains("--slow-import-fixture")
        var imports = [
            try importRecord(20, sequence: slow ? 13 : 10, phase: "acquiring", progress: "converting", error: nil,
                title: "Scaling Laws for Neural Language Models", authors: ["Jared Kaplan", "Sam McCandlish", "Tom Henighan",
                "Tom B. Brown", "Benjamin Chess", "Rewon Child", "Scott Gray", "Alec Radford", "Jeffrey Wu", "Dario Amodei"],
                published: "2020-01-23", categories: ["cs.LG", "stat.ML"], source: "2001.08361"),
            try importRecord(21, sequence: 3, phase: "failed", progress: nil, error: "insufficient_credits",
                title: "Constitutional AI: Harmlessness from AI Feedback", authors: ["Yuntao Bai", "Saurav Kadavath", "Sandipan Kundu"],
                published: "2022-12-15", categories: ["cs.CL", "cs.AI"], source: "2212.08073"),
        ]
        if slow {
            imports.append(try importRecord(22, sequence: 12, phase: "acquiring", progress: "downloading", error: nil,
                title: "Denoising Diffusion Probabilistic Models", authors: ["Jonathan Ho", "Ajay Jain", "Pieter Abbeel"],
                published: "2020-06-19", categories: ["cs.LG", "stat.ML"], source: "2006.11239"))
            imports.append(try importRecord(23, sequence: 11, phase: "failed", progress: nil, error: "download_failed",
                title: "Language Models are Few-Shot Learners", authors: ["Tom B. Brown", "Benjamin Mann", "Nick Ryder"],
                published: "2020-05-28", categories: ["cs.CL"], source: "2005.14165"))
        }
        installLibraryMetadataFixture(papers: papers, imports: imports, sequences: sequences, activity: activity, offline: offline,
            importStepStarts: slow ? [id(20): now - 4.5 * 60, id(22): now - 75] : [:])
    }

    private func configureBranchWorkflowFixture(documentID: UUID) throws {
        let conversation = UUID(uuidString: "dddddddd-0000-0000-0000-000000000001")!
        let device = UUID(uuidString: "dddddddd-0000-0000-0000-000000000002")!
        let root = UUID(uuidString: "dddddddd-0000-0000-0000-000000000003")!
        let question = UUID(uuidString: "dddddddd-0000-0000-0000-000000000600")!
        let observed = UUID(uuidString: "dddddddd-0000-0000-0000-000000000900")!
        let sibling = UUID(uuidString: "dddddddd-0000-0000-0000-000000000100")!
        try privateState.apply(AppliedEvent(id: root, deviceID: device, payload: PrivateEvent(kind: .conversation,
            entityID: conversation, documentID: documentID, text: "A retained paper discussion")))
        try privateState.apply(AppliedEvent(id: question, deviceID: device, payload: PrivateEvent(kind: .message,
            entityID: question, parents: [root], conversationID: conversation, documentID: documentID,
            text: "Keep this earlier question visible.", role: .user, status: .complete)))
        try privateState.apply(AppliedEvent(id: observed, deviceID: device, payload: PrivateEvent(kind: .message,
            entityID: observed, parents: [question], conversationID: conversation, documentID: documentID,
            text: "This observed reply was removed.", role: .assistant, status: .complete)))
        // Observe the first answer before a sibling arrives. Removing that answer
        // must retain its earlier context without silently selecting the sibling.
        openConversation(conversation)
        chatInput = "Draft for the retained paper discussion"
        try privateState.apply(AppliedEvent(id: sibling, deviceID: device, payload: PrivateEvent(kind: .message,
            entityID: sibling, parents: [question], conversationID: conversation, documentID: documentID,
            text: "A sibling reply requires an explicit choice.", role: .assistant, status: .complete)))
        try privateState.apply(AppliedEvent(id: UUID(uuidString: "dddddddd-0000-0000-0000-000000000901")!,
            deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: observed)))
        newChat(general: true)
        chatInput = "A separate general draft"
    }
}
#endif

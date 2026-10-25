import Foundation
import ScienceReaderCore

// The Library's topics (interest index step 3): when to recompute, what goes in, what is written back (encrypted), and
// the reader's actions on a topic. The computation itself is ScienceReaderCore/Interest (InterestLibraryModel) behind
// LibraryInterest's engine. Step 4 (For you in topic sections) reads `interest.topics` and the engine's model; nothing
// here needs to change for it.

extension ReaderModel {
    /// Recompute soon (library, registry or reading changed); coalesces bursts.
    func scheduleInterestUpdate(after delay: Duration = .milliseconds(400)) {
        interest.updateTask?.cancel()
        interest.updateTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.runInterestUpdate()
        }
    }

    /// The reader's key for a paper: its public identifier, or nil for an uploaded or device PDF (no public fingerprint).
    static func interestKey(_ paper: Paper) -> String? {
        guard !paper.isSample, !paper.isLocalPDF, let source = paper.sourceID, !source.isEmpty,
              !LibrarySource.isUploadSourceID(source), !source.hasPrefix("local:") else { return nil }
        return InterestPool.key(source)
    }

    func interestInputs() -> InterestInputs {
        var snippets: [UUID: Int] = [:]
        for note in notes.state.notes {
            for entry in note.entries {
                guard let source = entry.record.source, let paper = notePaper(for: source) else { continue }
                snippets[paper.id, default: 0] += 1
            }
        }
        var levels: [String: Int] = [:]
        var inputs: [InterestLibraryPaper] = []
        for paper in papers where !paper.isSample {
            let key = Self.interestKey(paper)
            let level = InterestWeights.readingLevel(progress: readingActivity[paper.id]?.progress)
            if let key, level > 0 { levels[key] = max(levels[key] ?? 0, level) }
            inputs.append(InterestLibraryPaper(id: paper.id, key: key, title: paper.title, abstract: paper.abstract,
                weight: .init(addedAt: paper.addedAt, archived: isArchived(paper), hasOwnTags: !paper.ownTags.isEmpty, readingLevel: level,
                              snippets: snippets[paper.id] ?? 0, chats: paperChatCounts[paper.id] ?? 0)))
        }
        var complete = completeLibrary != nil
        #if DEBUG && FIXTURE_HOST
        if Self.interestFixtureDirectory != nil { complete = true }
        #endif
        return InterestInputs(papers: inputs, readingLevels: levels, registry: interestRegistry, complete: complete, now: Date())
    }

    #if DEBUG && FIXTURE_HOST
    static var interestFixtureDirectory: URL? {
        ProcessInfo.processInfo.environment["INTEREST_FIXTURE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #endif

    /// The registry's writer: this device, or a fixed fixture device.
    private var interestDevice: UUID? {
        #if DEBUG && FIXTURE_HOST
        if Self.interestFixtureDirectory != nil, device == nil { return UUID(uuidString: "f1f1f1f1-0000-4000-8000-000000000001") }
        #endif
        return device?.deviceID
    }

    func runInterestUpdate() async {
        var inputs = interestInputs()
        let keys = Set(inputs.papers.compactMap(\.key))
        var ready = false
        #if DEBUG && FIXTURE_HOST
        if let directory = Self.interestFixtureDirectory { ready = await interest.prepareFixture(directory: directory) }
        #endif
        if !ready {
            guard let backend, let accountID, !keys.isEmpty else { return }
            let client = feedRelated.indexClient(backend: backend, accountID: accountID)
            ready = await interest.prepare(client: client, backend: backend, accountID: accountID, keys: keys)
        }
        guard ready, let engine = interest.engine, !Task.isCancelled else { return }
        interestFingerprintsChanged()
        inputs = interestInputs()
        let topics = await engine.update(inputs)
        guard !Task.isCancelled else { return }
        interest.publish(topics)
        if let filter = libraryTopicFilter {
            // The filtered topic changed papers (or left): follow it, or show everything again.
            if let slice = topics.slice(filter.id) {
                let next = LibraryTopicFilter(id: slice.id, label: slice.label, papers: Set(slice.papers))
                if next != filter { libraryTopicFilter = next }
            } else { libraryTopicFilter = nil }
        }
        await writeInterestRegisters(topics, inputs: inputs)
        refreshInterestKeywords(inputs.papers)
    }

    /// Shown topics (hysteresis) and this device's reading levels, as encrypted registry records. Shown flags are written
    /// only from a fully loaded library with every fingerprint present (a sign-in's empty first state must not switch
    /// topics off), at most once a minute; reading levels at most every six hours.
    private func writeInterestRegisters(_ topics: InterestLibraryTopics, inputs: InterestInputs) async {
        guard let device = interestDevice else { return }
        let registry = inputs.registry
        var shown: [InterestRegistryRecord.Shown] = []
        if inputs.complete, topics.pending == 0, topics.indexed > 0,
           interest.lastShownWrite.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            shown = registry.shownChanges(selected: topics.shownIDs, map: nil)
        }
        let readingKey = "interest.readingWrite.\(accountID?.wire ?? "fixture")"
        var reading: [InterestRegistryRecord.Reading] = []
        let lastReading = UserDefaults.standard.object(forKey: readingKey) as? Date
        if lastReading.map({ Date().timeIntervalSince($0) > 6 * 3_600 }) ?? true {
            reading = registry.readingChanges(local: inputs.readingLevels, device: device)
        }
        guard !shown.isEmpty || !reading.isEmpty else { return }
        do {
            try await persistInterestRecords(try InterestRegistry.records(device: device, shown: shown, reading: reading))
            if !shown.isEmpty { interest.lastShownWrite = Date() }
            if !reading.isEmpty { UserDefaults.standard.set(Date(), forKey: readingKey) }
        } catch {
            SessionTimeline.shared.record("interest", ["phase": "register-write-failed"])
        }
    }

    /// Keywords for every library paper from the term layer, with the paper's full text from the encrypted full-text
    /// index when it has one, at utility priority; only papers whose text changed are recomputed.
    private func refreshInterestKeywords(_ papers: [InterestLibraryPaper]) {
        guard let engine = interest.engine else { return }
        interest.keywordTask?.cancel()
        let index = fullTextIndexer.store
        interest.keywordTask = Task { [weak self] in
            let snapshot = try? await index?.snapshot()
            let fingerprints = await index?.fingerprints() ?? [:]
            var signatures: [UUID: String] = [:]
            for paper in papers { signatures[paper.id] = fingerprints[FullTextDocumentID(group: paper.id.wire, part: .body)] ?? "" }
            let keywords = await Task.detached(priority: .utility) {
                await engine.keywords(for: papers, bodySignature: signatures) { id in snapshot?.bodyText(group: id.wire) }
            }.value
            guard !Task.isCancelled, let self else { return }
            if InterestKeywordStore.shared.replace(keywords.filter { !$0.value.isEmpty }) { self.interestKeywordsChanged() }
        }
    }

    // MARK: The reader's actions

    /// A slice or legend row: show only that topic's papers; the same again shows everything.
    func toggleTopicFilter(_ slice: InterestTopicSlice) {
        if libraryTopicFilter?.id == slice.id { libraryTopicFilter = nil; return }
        libraryTagFilter = nil
        libraryTopicFilter = LibraryTopicFilter(id: slice.id, label: slice.label, papers: Set(slice.papers))
    }

    private func writeTopic(_ id: Int, change: (inout (name: String?, hidden: Bool, colour: Int?)) -> Void) async {
        guard let device = interestDevice else { show(LibraryCatalogError.unavailable); return }
        let current = interestRegistry.topic(id, map: nil)
        var state = (name: current?.name, hidden: current?.hidden ?? false, colour: current?.colour)
        change(&state)
        do {
            let record = try InterestRegistryRecord(device: device, topics: [.init(id: id, epoch: interestRegistry.nextEpoch, name: state.name,
                                                                                    hidden: state.hidden, colour: state.colour)])
            try await persistInterestRecords([record])
        } catch {
            show(error)
        }
    }

    /// The reader's name for a topic; empty restores the computed label.
    func renameTopic(_ id: Int, to raw: String) async {
        let name = InterestRegistryRecord.normalizedName(raw)
        await writeTopic(id) { $0.name = name }
    }

    func setTopicHidden(_ id: Int, _ hidden: Bool) async {
        if hidden, libraryTopicFilter?.id == id { libraryTopicFilter = nil }
        await writeTopic(id) { $0.hidden = hidden }
    }

    /// A palette slot, or nil for colour by size.
    func setTopicColour(_ id: Int, _ slot: Int?) async {
        await writeTopic(id) { $0.colour = slot }
    }

    #if DEBUG && FIXTURE_HOST
    /// UI fixtures (`INTEREST_FIXTURE_DIR`): the public fixture library (38 Feed-pool papers) as Library papers, with the
    /// fixture's reading, tags and chats, so the chart has real topics without an account.
    func configureInterestFixture() throws {
        guard let directory = Self.interestFixtureDirectory else { return }
        let data = try Data(contentsOf: directory.appendingPathComponent("interest-library-v1.json"))
        let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let now = Date(), day: TimeInterval = 86_400
        var papers: [Paper] = [], activity: [UUID: PaperActivity] = [:], sequences: [UUID: Int64] = [:]
        let device = UUID()
        for (i, p) in (fixture["papers"] as? [[String: Any]] ?? []).enumerated() {
            let id = UUID(uuidString: String(format: "ffffffff-0000-0000-0000-%012d", i))!
            var paper = Paper(id: id, title: p["title"] as? String ?? "", authors: "", year: 2026, abstract: p["abstract"] as? String ?? "",
                              keywords: [], fileURL: nil, artifactID: nil)
            paper.sourceID = p["key"] as? String; paper.sourceRevision = 1
            paper.addedAt = now - Double(p["days_ago"] as? Int ?? 0) * day
            paper.archived = p["archived"] as? Bool ?? false
            if p["own_tags"] as? Bool == true { paper.ownTags = ["Reading group"]; paper.tags = ["Reading group"] }
            papers.append(paper); sequences[id] = Int64(1_000 - i)
            let reading = p["reading"] as? Int ?? 0
            if reading > 0 { activity[id] = PaperActivity(openedAt: now - day, progress: [0, 0.2, 0.4, 0.7, 1][reading]) }
            for chat in 0 ..< (p["chats"] as? Int ?? 0) {
                try privateState.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .conversation,
                    entityID: UUID(uuidString: String(format: "ffffffff-0000-0000-%04d-%012d", chat, i))!, documentID: id, text: "Chat \(chat)")))
            }
        }
        installLibraryMetadataFixture(papers: papers, imports: [], sequences: sequences, activity: activity, offline: [:])
    }
    #endif
}

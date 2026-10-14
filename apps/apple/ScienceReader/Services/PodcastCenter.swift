import Foundation
import Observation
import ScienceReaderCore
import UIKit

/// The signed-in, activated account's podcast service and local folder.
struct PodcastAccount {
    let id: UUID
    let transport: any PodcastTransport
    /// The account's local folder (Application Support/<environment>/<account>/): erased with the account.
    let folder: URL
    let localKey: Data
    let deviceID: UUID
}

/// A private-generation sheet: a length, its quote, explicit consent, then the server job's progress and charges.
struct PodcastGeneration: Identifiable, Equatable {
    enum Failure: Equatable {
        case sourceTooLarge
        case message(String)

        var message: String {
            switch self {
            case .sourceTooLarge:
                return "This paper is longer than a full-paper episode can handle."
            case .message(let value):
                return value
            }
        }

        var isSourceTooLarge: Bool {
            if case .sourceTooLarge = self { return true }
            return false
        }

        static func from(_ error: Error) -> Self {
            if let backend = error as? BackendError,
               case .rejected(let code) = backend,
               code == "source_too_large" {
                return .sourceTooLarge
            }
            return .message(error.podcastMessage)
        }
    }

    enum Phase: Equatable {
        case offer, quoting, quoted(PodcastQuote), starting, running(PodcastJob), finished(PodcastJob), failed(Failure)
    }
    let id = UUID()
    let paperTitle: String
    let itemID: UUID
    let documentID: UUID
    var phase: Phase
    /// Lengths offered (shortest first); five minutes alone when the server lists none.
    var lengths: [PodcastLength]
    /// This paper's ready episodes, one per length. Each length is its own episode: a ready one plays, at no charge.
    var ready: [PodcastEpisode] = []
    /// The chosen length's profile.
    var selected: String
    /// Idempotency keys: one quote request per length and one start request per quote, so a retried quote or start is
    /// the same request, never a second quote or charge.
    var quoteRequestIDs: [String: UUID] = [:]
    var startRequestIDs: [UUID: UUID] = [:]

    init(paperTitle: String, itemID: UUID, documentID: UUID, phase: Phase, capabilities: PodcastCapabilities?,
         ready: [PodcastEpisode] = [], selected: String? = nil) {
        self.paperTitle = paperTitle; self.itemID = itemID; self.documentID = documentID; self.phase = phase
        let offered = capabilities?.lengths ?? []
        let lengths = offered.isEmpty ? [PodcastLength(profile: PodcastLength.defaultProfile, label: "5 min", targetSeconds: capabilities?.targetSeconds ?? 300,
                                                       maxCredits: capabilities?.maxCredits ?? 150)] : offered
        let playable = ready.filter { !$0.state.blocksPlayback }
        // The job's own length; else five minutes unless it is already ready (then the next longer length still to make).
        let fresh = lengths.filter { length in !playable.contains { ($0.profile ?? PodcastLength.defaultProfile) == length.profile } }
        let chosen = selected.flatMap { wanted in lengths.first { $0.profile == wanted }?.profile }
            ?? (fresh.contains { $0.profile == PodcastLength.defaultProfile } ? PodcastLength.defaultProfile : nil)
            ?? (fresh.first { $0.targetSeconds > 300 } ?? fresh.first)?.profile
            ?? lengths.first { $0.profile == PodcastLength.defaultProfile }?.profile ?? lengths[0].profile
        self.lengths = lengths; self.ready = playable; self.selected = chosen
    }

    var selectedLength: PodcastLength? { lengths.first { $0.profile == selected } }
    func readyEpisode(_ profile: String) -> PodcastEpisode? { ready.first { ($0.profile ?? PodcastLength.defaultProfile) == profile } }

    /// A length can be started when its maximum fits the available credits (a ready length never needs any; an
    /// unknown balance greys nothing out: the server still decides, and says so).
    func affordable(_ length: PodcastLength, credits: Int64?) -> Bool {
        guard readyEpisode(length.profile) == nil, let credits else { return true }
        return Int64(length.maxCredits) <= credits
    }

    /// Whether the chosen length is quoted at once (nothing is held by a quote): not ready and not known to be
    /// beyond the balance.
    func shouldQuote(credits: Int64?) -> Bool {
        guard let length = selectedLength else { return false }
        return readyEpisode(selected) == nil && affordable(length, credits: credits)
    }

    /// The job's length when the server names it, else the chosen one.
    func length(of job: PodcastJob) -> PodcastLength? { lengths.first { $0.profile == job.profile } ?? selectedLength }

    /// What to expect while an episode is made (docs/architecture/PAPER_PODCASTS.md, "Staged generation"): Short
    /// and five minutes run as one request; ten and twenty minutes run in stages, and a twenty-minute draft alone can
    /// take about ten minutes.
    static func expectedWait(targetSeconds: Int) -> String {
        targetSeconds > 300 ? "This length can take 10 minutes or more." : "Usually ready in a few minutes."
    }
}

/// An evidence quote whose paper isn't in this library: offer the source and an explicit Add.
struct PodcastEvidenceElsewhere: Identifiable, Equatable {
    let id = UUID()
    let quote: String
    let episode: PodcastEpisode
}

/// Paper podcasts on this device (docs/architecture/PAPER_PODCASTS.md): the Listen catalog, playback, verified
/// downloads, device-local listening history and explicitly quoted private generation. Owned by `ReaderModel`; an
/// account change stops playback and forgets everything shown for the previous account.
@MainActor @Observable
final class PodcastCenter {
    enum CatalogState: Equatable { case idle, loading, loaded, failed(String) }
    /// A Play or Download that is fetching and verifying the audio first.
    struct Transfer: Equatable {
        let releaseID: UUID
        let title: String
        var received: Int
        let total: Int
        let keep: Bool
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    /// The Feed's Listen filter (a chip beside the topics).
    var listenSelected = false
    private(set) var capabilities: PodcastCapabilities?
    private(set) var catalog: [PodcastEpisode] = []
    private(set) var catalogState: CatalogState = .idle
    private(set) var catalogNext: String?
    let player = PodcastPlayer()
    var showPlayer = false
    private(set) var transfer: Transfer?
    private(set) var downloads: [UUID: PodcastDownloadRecord] = [:]
    private(set) var history = PodcastPlaybackLedger()
    var generation: PodcastGeneration?
    var evidenceElsewhere: PodcastEvidenceElsewhere?
    /// A one-line problem or outcome, shown as an alert.
    var notice: String?
    /// A private episode that became ready after its sheet was closed: offered with Play (an alert at the root, a
    /// banner inside an open podcast sheet). In-app only; local notifications are an owner decision.
    struct ReadyNotice: Identifiable, Equatable {
        let id = UUID()
        let releaseID: UUID
        let title: String
        var message: String { "Your episode of “\(title)” is ready." }
    }
    var readyNotice: ReadyNotice?
    /// Status polling stops after this long; the job itself continues on the server.
    static let pollLimit: TimeInterval = 1_800
    static let stillPreparingNotice = "Still preparing. Check back from Listen on this paper."
    /// Releases the server has corrected (superseded) since they were downloaded: their replacement.
    private(set) var corrections: [UUID: UUID] = [:]

    @ObservationIgnored weak var host: ReaderModel?
    @ObservationIgnored private var account: PodcastAccount?
    @ObservationIgnored private var store: PodcastLocalStore?
    @ObservationIgnored private var session: PodcastPlaybackSession?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var historySave: Task<Void, Never>?
    @ObservationIgnored private var generationCounter = 0
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    #if DEBUG && FIXTURE_HOST
    @ObservationIgnored private var fixtureTransport: PodcastFixtureTransport?
    #endif

    init() {
        player.onSave = { [weak self] episode, position, duration, completed, reason in
            self?.record(episode: episode, positionMS: position, durationMS: duration, completed: completed, reason: reason)
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.saveNow(); self?.flushHistory() }
        }
        #if DEBUG && FIXTURE_HOST
        // Quick visual checks (`simctl launch … --podcast-fixture --podcast-listen`): open on the Listen filter.
        if PodcastFixtureTransport.isEnabled, ProcessInfo.processInfo.arguments.contains("--podcast-listen") { listenSelected = true }
        // A reset fixture starts at 1×: the saved speed is a device preference the journeys must not inherit.
        if PodcastFixtureTransport.isEnabled, ProcessInfo.processInfo.arguments.contains("--reset-podcast-fixture") { player.resetRatePreference() }
        // Autoplay needs the catalog, whichever tab the check opens on.
        if PodcastFixtureTransport.isEnabled, ProcessInfo.processInfo.arguments.contains("--podcast-autoplay") {
            Task { [weak self] in self?.loadCatalog() }
        }
        #endif
    }

    #if DEBUG && FIXTURE_HOST
    /// `--podcast-autoplay` (visual checks): play the sample fixture episode once the Listen list has loaded.
    func fixtureAutoplay() {
        guard PodcastFixtureTransport.isEnabled, ProcessInfo.processInfo.arguments.contains("--podcast-autoplay"),
              nowPlaying == nil, let episode = catalog.first(where: { $0.id == PodcastFixtureTransport.sampleRelease }) else { return }
        play(episode, at: 9_000)
        // `--podcast-autoplay-mini`: then close the sheet, to see the mini-player (iPad visual checks).
        if ProcessInfo.processInfo.arguments.contains("--podcast-autoplay-mini") {
            Task { try? await Task.sleep(for: .seconds(2)); showPlayer = false }
        }
    }
    #endif

    /// The Listen chip is offered when listening could work for this account (or the fixture).
    var listenAvailable: Bool {
        #if DEBUG && FIXTURE_HOST
        if PodcastFixtureTransport.isEnabled { return true }
        #endif
        // Absent capabilities mean unavailable: a server without podcasts keeps the Feed exactly as it was.
        return host?.podcastAccount != nil && capabilities?.catalog == true
    }

    /// Learns this account's capabilities once (from the catalog call) so the Listen chip can appear.
    func prepareListen() {
        guard capabilities == nil, catalogState == .idle, host?.podcastAccount != nil || fixtureEnabled else { return }
        loadCatalog()
    }

    private var fixtureEnabled: Bool {
        #if DEBUG && FIXTURE_HOST
        return PodcastFixtureTransport.isEnabled
        #else
        return false
        #endif
    }

    var nowPlaying: PodcastEpisode? { player.episode }

    /// The account's available credits as last loaded (nil until known), for the Listen sheet's balance line and
    /// for greying out lengths whose maximum exceeds it. Only the server's hold decides; this is a courtesy.
    var availableCredits: Int64? {
        #if DEBUG && FIXTURE_HOST
        if PodcastFixtureTransport.isEnabled { return PodcastFixtureTransport.fixtureCredits() }
        #endif
        return host?.creditBalance?.available
    }

    /// Listen is offered for a synced library paper (the offline sample only has a fixture episode).
    /// Why Listen cannot start for a paper the server has no podcast source for (owner report 2026-10-14: "not able to
    /// create a podcast at all"). Episodes are written from the server's converted text; a paper read on this device
    /// through the HTML reader has none, which is not the same as being outside the synced library.
    static func noEpisodeSource(for paper: Paper) -> String {
        if paper.sourceMembership != nil {
            return "Episodes are made from a server copy of the paper. Papers read on this device don’t have one yet, so this paper can’t be made into an episode."
        }
        return "Listening needs this paper in your synced library."
    }
    func canListen(to paper: Paper) -> Bool {
        #if DEBUG && FIXTURE_HOST
        if PodcastFixtureTransport.isEnabled { return true }
        #endif
        // Unknown capabilities still offer Listen (the paper call reports them); known-off hides it.
        return !paper.isSample && host?.podcastAccount != nil && (capabilities.map { $0.delivery || $0.generation } ?? true)
    }
    func isKept(_ releaseID: UUID) -> Bool { downloads[releaseID]?.kept == true }
    var keptDownloads: [PodcastDownloadRecord] { downloads.values.filter(\.kept).sorted { $0.lastUsedAt > $1.lastUsedAt } }

    // MARK: Account

    /// Sign-out, account switch or deletion: stop playback and drop the previous account's state and handles.
    func accountChanged() {
        guard account != nil else { return }
        player.stop(); flushHistory()
        account = nil; store = nil; session = nil
        transferTask?.cancel(); transferTask = nil; transfer = nil
        pollTask?.cancel(); pollTask = nil; catalogTask?.cancel(); catalogTask = nil
        catalog = []; catalogState = .idle; catalogNext = nil; capabilities = nil
        downloads = [:]; history = PodcastPlaybackLedger(); generation = nil; evidenceElsewhere = nil; notice = nil; corrections = [:]
        readyNotice = nil; showPlayer = false; listenSelected = false
    }

    /// The current account's context, loading its sealed history and downloads list the first time.
    private func currentAccount() async -> PodcastAccount? {
        let resolved: PodcastAccount?
        #if DEBUG && FIXTURE_HOST
        if PodcastFixtureTransport.isEnabled { resolved = fixtureAccount() } else { resolved = host?.podcastAccount }
        #else
        resolved = host?.podcastAccount
        #endif
        guard let resolved else { if account != nil { accountChanged() }; return nil }
        if let account, account.id == resolved.id { return account }
        if account != nil { accountChanged() }
        account = resolved
        let directory = resolved.folder.appendingPathComponent("podcasts", isDirectory: true)
        // Never recreate an erased account folder: only the podcasts folder inside an existing one.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        guard let opened = try? PodcastLocalStore(directory: directory, accountID: resolved.id, localKey: resolved.localKey) else { return resolved }
        store = opened
        let ledger = await opened.loadHistory(), records = await opened.loadDownloads()
        guard self.account?.id == resolved.id else { return nil }
        history = ledger
        // Only records whose file is still present stay "downloaded".
        downloads = Dictionary(uniqueKeysWithValues: records.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
            .map { ($0.episode.id, $0) })
        return resolved
    }

    private var audioDirectory: URL? { account?.folder.appendingPathComponent("podcasts", isDirectory: true) }

    #if DEBUG && FIXTURE_HOST
    private func fixtureAccount() -> PodcastAccount? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = base.appendingPathComponent("podcast-fixture/\(PodcastFixtureTransport.fixtureAccount.wire)", isDirectory: true)
        if account == nil, ProcessInfo.processInfo.arguments.contains("--reset-podcast-fixture") { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transport = fixtureTransport ?? PodcastFixtureTransport(); fixtureTransport = transport
        return PodcastAccount(id: PodcastFixtureTransport.fixtureAccount, transport: transport, folder: folder,
                              localKey: Data(repeating: 0x5a, count: 32), deviceID: UUID(uuidString: "fa000000-0000-4000-8000-0000000000de")!)
    }
    #endif

    // MARK: Catalog

    func loadCatalog() {
        catalogTask?.cancel()
        catalogState = catalog.isEmpty ? .loading : catalogState
        catalogTask = Task {
            guard let account = await currentAccount() else {
                catalogState = .failed("Sign in to listen to paper episodes."); return
            }
            do {
                let page = try await account.transport.catalog(after: nil, limit: 50)
                guard self.account?.id == account.id, !Task.isCancelled else { return }
                capabilities = page.capabilities ?? capabilities
                catalog = page.episodes.map { resolve($0) }; catalogNext = page.next; catalogState = .loaded
                #if DEBUG && FIXTURE_HOST
                fixtureAutoplay()
                #endif
                await refreshDownloadedStates()
            } catch {
                guard self.account?.id == account.id, !Task.isCancelled else { return }
                catalogState = .failed(error.podcastMessage)
            }
        }
    }

    func loadMoreCatalog() {
        guard let next = catalogNext, catalogState == .loaded, let account else { return }
        catalogNext = nil
        Task {
            do {
                let page = try await account.transport.catalog(after: next, limit: 50)
                guard self.account?.id == account.id else { return }
                let known = Set(catalog.map(\.id))
                catalog += page.episodes.filter { !known.contains($0.id) }.map { resolve($0) }; catalogNext = page.next
            } catch { catalogNext = next }
        }
    }

    /// Before relying on downloaded copies (and on reconnect): learn about takedowns and corrections. Offline devices
    /// can't learn of one until then, and exported copies can't be erased remotely.
    func refreshDownloadedStates() async {
        guard let account, !downloads.isEmpty else { return }
        guard let states = try? await account.transport.states(Array(downloads.keys)), self.account?.id == account.id else { return }
        for (releaseID, status) in states {
            if status.state.blocksPlayback {
                let title = downloads[releaseID]?.episode.displayTitle
                if nowPlaying?.id == releaseID { player.stop() }
                removeFile(releaseID)
                notice = "“\(title ?? "An episode")” is no longer available and was removed from this device."
            } else if status.state == .superseded, let replacement = status.replacementID {
                corrections[releaseID] = replacement
            }
        }
        persistDownloads()
    }

    // MARK: Playing

    /// Plays `episode`: from a verified local copy, or after fetching and verifying the whole file first (no Range,
    /// no streaming). Tapping Play never adds a paper or buys anything.
    func play(_ episode: PodcastEpisode, at startMS: Int? = nil) {
        if readyNotice?.releaseID == episode.id { readyNotice = nil }
        if nowPlaying?.id == episode.id {
            if let startMS { player.seek(toMS: startMS) }
            if !player.isPlaying { player.play() }
            showPlayer = true; return
        }
        transferTask?.cancel()
        transferTask = Task {
            guard let account = await currentAccount() else { notice = "Sign in to listen to paper episodes."; return }
            do {
                let full = try await fullEpisode(episode, account: account)
                let url = try await localFile(for: full, keep: false, account: account)
                guard self.account?.id == account.id, !Task.isCancelled else { return }
                beginSession(full)
                player.load(full, fileURL: url, startMS: startMS ?? history.resumePositionMS(for: full.id) ?? 0, autoplay: true)
                showPlayer = true
            } catch is CancellationError {
            } catch {
                guard self.account?.id == account.id else { return }
                notice = error.podcastMessage
            }
            if self.transfer?.releaseID == episode.id, !(self.transfer?.keep ?? false) { self.transfer = nil }
        }
    }

    /// Stops a Play/Download that is still fetching (slow networks): the grant is spent, a later try gets a new one.
    func cancelTransfer() { transferTask?.cancel(); transferTask = nil; transfer = nil }

    /// Keeps the episode for offline listening (reusing a copy already played: no second transfer).
    func download(_ episode: PodcastEpisode) {
        if let record = downloads[episode.id] {
            downloads[episode.id]?.kept = true; downloads[episode.id]?.lastUsedAt = Date()
            if record.episode.transcript == nil { Task { await self.refreshEpisode(episode.id) } }
            persistDownloads(); return
        }
        transferTask?.cancel()
        transferTask = Task {
            guard let account = await currentAccount() else { notice = "Sign in to download episodes."; return }
            do {
                let full = try await fullEpisode(episode, account: account)
                _ = try await localFile(for: full, keep: true, account: account)
            } catch is CancellationError {
            } catch {
                guard self.account?.id == account.id else { return }
                notice = error.podcastMessage
            }
            if self.transfer?.releaseID == episode.id { self.transfer = nil }
        }
    }

    /// Removes this device's copy only; shared catalog content and other devices are unaffected.
    func removeDownload(_ releaseID: UUID) {
        if nowPlaying?.id == releaseID {
            // Still playing from it: keep the file as an ordinary (evictable) copy instead of pulling it away.
            downloads[releaseID]?.kept = false
        } else { removeFile(releaseID) }
        persistDownloads()
    }

    func stop() { player.stop(); showPlayer = false; session = nil; flushHistory() }

    private func fullEpisode(_ episode: PodcastEpisode, account: PodcastAccount) async throws -> PodcastEpisode {
        let episode = resolve(episode)
        if episode.transcript != nil, episode.chapters != nil { return episode }
        if let stored = downloads[episode.id]?.episode, stored.transcript != nil { return stored }
        let full = try await account.transport.episode(episode.id)
        guard full.audio == episode.audio, full.documentID == episode.documentID else { throw ReaderError.corruptData }
        return full.resolvingTitle(episode.title)
    }

    /// A private episode's title comes from this account's library (the server doesn't have it); `fallback` is the
    /// title already known for it (the paper a generation was started from).
    func resolve(_ episode: PodcastEpisode, fallback: String? = nil) -> PodcastEpisode {
        guard episode.title == nil else { return episode }
        return episode.resolvingTitle(host?.papers.first { $0.id == episode.documentID }?.title ?? fallback)
    }

    private func refreshEpisode(_ releaseID: UUID) async {
        guard let account, let fetched = try? await account.transport.episode(releaseID), var record = downloads[releaseID],
              fetched.audio == record.episode.audio else { return }
        let full = fetched.resolvingTitle(record.episode.title)
        record = PodcastDownloadRecord(episode: full, fileName: record.fileName, bytes: record.bytes, sha256: record.sha256,
                                       mediaType: record.mediaType, kept: record.kept, verifiedAt: record.verifiedAt, lastUsedAt: record.lastUsedAt)
        downloads[releaseID] = record; persistDownloads()
    }

    /// A verified local file for `episode`: re-checked if already here, otherwise one single-use grant, every byte
    /// received, length and SHA-256 checked, then written with file protection and recorded.
    private func localFile(for episode: PodcastEpisode, keep: Bool, account: PodcastAccount) async throws -> URL {
        guard let directory = audioDirectory else { throw ReaderError.storageUnavailable }
        if let record = downloads[episode.id] {
            let url = directory.appendingPathComponent(record.fileName)
            let size = record.bytes, digest = record.sha256
            let intact = await Task.detached { (try? PodcastAudioVerification.verify(fileAt: url, bytes: size, sha256: digest)) != nil }.value
            if intact {
                downloads[episode.id]?.lastUsedAt = Date(); if keep { downloads[episode.id]?.kept = true }
                persistDownloads(); return url
            }
            removeFile(episode.id)
        }
        transfer = Transfer(releaseID: episode.id, title: episode.displayTitle, received: 0, total: episode.audio.bytes, keep: keep)
        let grant = try await account.transport.download(episode.id)
        guard let member = grant.audio, member.bytes == episode.audio.bytes, member.sha256 == episode.audio.sha256,
              member.mediaType == episode.audio.mediaType else { throw ReaderError.corruptData }
        let releaseID = episode.id
        let data = try await account.transport.member(member) { [weak self] received in
            Task { @MainActor in if self?.transfer?.releaseID == releaseID { self?.transfer?.received = received } }
        }
        try Task.checkCancellation()
        try PodcastAudioVerification.verify(data, bytes: member.bytes, sha256: member.sha256)
        guard self.account?.id == account.id else { throw CancellationError() }
        let name = PodcastDownloadRecord.fileName(for: episode.id, mediaType: member.mediaType)
        let url = directory.appendingPathComponent(name)
        // Readable while the device is locked after first unlock, so background playback continues; excluded from backup.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var file = url; try? file.setResourceValues(values)
        let now = Date()
        downloads[episode.id] = PodcastDownloadRecord(episode: episode, fileName: name, bytes: member.bytes, sha256: member.sha256,
                                                      mediaType: member.mediaType, kept: keep, verifiedAt: now, lastUsedAt: now)
        evictTransientCopies()
        persistDownloads()
        transfer = nil
        return url
    }

    /// Copies Play needed but the reader didn't keep: at most three, least recently used first, never the one playing.
    private func evictTransientCopies() {
        let transient = downloads.values.filter { !$0.kept && $0.episode.id != nowPlaying?.id }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        for record in transient.dropFirst(3) { removeFile(record.episode.id) }
    }

    private func removeFile(_ releaseID: UUID) {
        guard let record = downloads.removeValue(forKey: releaseID), let directory = audioDirectory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
    }

    private func persistDownloads() {
        guard let store else { return }
        let records = Array(downloads.values.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(PodcastLocalStore.maximumDownloads))
        Task { try? await store.saveDownloads(records) }
    }

    // MARK: History (device-local)

    private func beginSession(_ episode: PodcastEpisode) {
        session = PodcastPlaybackSession(releaseID: episode.id, startedAt: Date(), deviceID: account?.deviceID ?? UUID())
    }

    private func record(episode: PodcastEpisode, positionMS: Int, durationMS: Int, completed: Bool, reason: PodcastPlayer.SaveReason) {
        guard var current = session, current.releaseID == episode.id else { return }
        let record = current.record(positionMS: positionMS, durationMS: durationMS, completed: completed, at: Date())
        session = current
        history.apply(record)
        // Pauses, chapters, seeks and the end are saved now; the 15-second tick is saved too (bounded, not every second).
        flushHistory()
        if reason == .finished { downloads[episode.id]?.lastUsedAt = Date() }
    }

    private func flushHistory() {
        guard let store else { return }
        let ledger = history
        historySave?.cancel()
        historySave = Task { try? await store.saveHistory(ledger) }
    }

    func clearHistory(_ releaseID: UUID) {
        history.remove(releaseID, deviceID: account?.deviceID ?? UUID(), at: Date()); flushHistory()
    }

    func resumePosition(_ releaseID: UUID) -> Int? { history.resumePositionMS(for: releaseID) }
    func isFinished(_ releaseID: UUID) -> Bool { history.isCompleted(releaseID) }

    // MARK: Listen on a paper, and private generation

    /// Listen (Paper "…" menu, a Library row): play the paper's shared or own private episode, follow a generation
    /// already running, or offer an explicitly quoted private generation.
    func listen(to paper: Paper) { open(paper, choosingLength: false) }

    /// "Other lengths…" from the player: the paper's ready lengths to play, or another length to make.
    func chooseLength(for episode: PodcastEpisode) {
        guard let paper = host?.papers.first(where: { $0.id == episode.documentID }) else { return }
        showPlayer = false
        Task {
            // After the player sheet has gone: one sheet presents at a time.
            try? await Task.sleep(for: .milliseconds(600))
            open(paper, choosingLength: true)
        }
    }

    /// Other lengths can be made for a library paper when private generation is offered.
    func canChooseLength(for episode: PodcastEpisode) -> Bool {
        guard host?.papers.contains(where: { $0.id == episode.documentID }) == true else { return false }
        #if DEBUG && FIXTURE_HOST
        if PodcastFixtureTransport.isEnabled { return true }
        #endif
        return capabilities?.generation == true
    }

    private func open(_ paper: Paper, choosingLength: Bool) {
        Task {
            guard let account = await currentAccount() else { notice = "Sign in to listen to paper episodes."; return }
            let itemID: UUID
            #if DEBUG && FIXTURE_HOST
            if PodcastFixtureTransport.isEnabled { itemID = paper.id } else {
                guard let found = host?.podcastItemID(for: paper) else { notice = Self.noEpisodeSource(for: paper); return }
                itemID = found
            }
            #else
            guard let found = host?.podcastItemID(for: paper) else { notice = Self.noEpisodeSource(for: paper); return }
            itemID = found
            #endif
            do {
                let lookup = try await account.transport.paper(itemID: itemID)
                guard self.account?.id == account.id else { return }
                if let capabilities = lookup.capabilities { self.capabilities = capabilities }
                let ready = lookup.episodes.map { resolve($0, fallback: paper.title) }
                if !choosingLength, let episode = lookup.episode, !episode.state.blocksPlayback {
                    play(resolve(episode, fallback: paper.title))
                } else if let job = lookup.job, job.state.isActive {
                    generation = PodcastGeneration(paperTitle: paper.title, itemID: itemID, documentID: paper.id, phase: .running(job),
                                                   capabilities: lookup.capabilities ?? capabilities, ready: ready, selected: job.profile)
                    poll(job.requestID)
                } else if lookup.capabilities?.generation == true {
                    generation = PodcastGeneration(paperTitle: paper.title, itemID: itemID, documentID: paper.id, phase: .offer,
                                                   capabilities: lookup.capabilities, ready: ready)
                    // One confirm step: the chosen length's estimate is fetched at once (a quote holds nothing).
                    quoteIfWanted()
                } else if choosingLength, let episode = lookup.episode, !episode.state.blocksPlayback {
                    notice = "Other lengths can’t be made right now. This episode keeps playing."
                } else {
                    notice = "There’s no episode for this paper yet, and creating one isn’t available right now. Reading is unaffected."
                }
            } catch {
                guard self.account?.id == account.id else { return }
                notice = error.podcastMessage
            }
        }
    }

    /// Step 1: an explicit quote for the chosen length. Nothing is held yet.
    func requestQuote() {
        guard var current = generation, let account else { return }
        let profile = current.selected
        let requestID = current.quoteRequestIDs[profile] ?? UUID()
        current.quoteRequestIDs[profile] = requestID
        current.phase = .quoting
        generation = current
        Task {
            do {
                let outcome = try await account.transport.quote(itemID: current.itemID, requestID: requestID, profile: profile)
                guard generation?.id == current.id, generation?.selected == profile else { return }
                switch outcome {
                case .quote(let quote): generation?.phase = .quoted(quote)
                case .reuse(let releaseID): try await playReady(releaseID, title: current.paperTitle, account: account)
                case .join(let requestID): try await follow(account.transport.status(requestID: requestID), current, account: account)
                }
            } catch {
                guard generation?.id == current.id, generation?.selected == profile else { return }
                // Quotes hold nothing: a retry may use a new request (an expired quote can't be revived).
                generation?.quoteRequestIDs[profile] = nil
                generation?.phase = .failed(.from(error))
            }
        }
    }

    /// Choosing a length: it is quoted at once (a quote holds nothing; an estimate still in flight for the previous
    /// choice is ignored when it lands); a length that is ready plays instead of being made again; one known to be
    /// beyond the balance waits, greyed out, for a different choice.
    func selectLength(_ profile: String) {
        guard var current = generation, current.selected != profile, current.lengths.contains(where: { $0.profile == profile }) else { return }
        switch current.phase {
        case .offer, .quoting, .quoted, .failed: break
        case .finished(let job) where job.state == .failed: break
        default: return
        }
        current.selected = profile
        current.phase = .offer
        generation = current
        quoteIfWanted()
    }

    /// The offer's chosen length, quoted unless it is ready or known not to fit the balance.
    private func quoteIfWanted() {
        guard let current = generation, current.phase == .offer, current.shouldQuote(credits: availableCredits) else { return }
        requestQuote()
    }

    /// The chosen length is already ready for this paper: play it (no new charge).
    func playSelectedReady() {
        guard let current = generation, let episode = current.readyEpisode(current.selected) else { return }
        generation = nil
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            play(episode)
        }
    }

    /// Step 2: the reader confirmed the quote and providers. One funding operation holds at most the quoted maximum.
    func startGeneration() {
        guard var current = generation, case .quoted(let quote) = current.phase, let account else { return }
        let requestID = current.startRequestIDs[quote.id] ?? UUID()
        current.startRequestIDs[quote.id] = requestID
        current.phase = .starting
        generation = current
        Task {
            do {
                let outcome = try await account.transport.start(quoteID: quote.id, requestID: requestID, consentVersion: quote.consentVersion)
                try await follow(outcome, current, account: account)
            } catch {
                guard generation?.id == current.id else { return }
                generation?.phase = .failed(.from(error))
            }
        }
    }

    func cancelGeneration() {
        guard let current = generation, case .running(let job) = current.phase, job.state.canCancel, let account else { return }
        Task {
            do {
                try await follow(account.transport.cancel(requestID: job.requestID), current, account: account)
            } catch {
                guard generation?.id == current.id else { return }
                notice = error.podcastMessage
            }
        }
    }

    /// Durable server status, polled on a bounded schedule (2 s, then 5 s, then 15 s); never inferred from time.
    /// The sheet may be closed meanwhile (`generation` nil, or another paper's): the outcome is then told as a notice,
    /// with Play when the episode is ready; reaching the polling limit says so instead of going quiet.
    private func poll(_ requestID: UUID) {
        pollTask?.cancel()
        generationCounter += 1
        let counter = generationCounter
        let followed = generation
        pollTask = Task {
            let started = Date()
            while !Task.isCancelled, let account, generationCounter == counter {
                let elapsed = Date().timeIntervalSince(started)
                #if DEBUG && FIXTURE_HOST
                let interval: Double = PodcastFixtureTransport.isEnabled ? 0.6 : elapsed < 30 ? 2 : elapsed < 180 ? 5 : 15
                #else
                let interval: Double = elapsed < 30 ? 2 : elapsed < 180 ? 5 : 15
                #endif
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, generationCounter == counter else { return }
                if elapsed >= Self.pollLimit { notice = Self.stillPreparingNotice; return }
                guard let outcome = try? await account.transport.status(requestID: requestID), self.account?.id == account.id else { continue }
                let sheetOpen = generation?.id == followed?.id
                guard case .job(let job) = outcome else {
                    // Ready already (another request for the same episode): play it, no new charge.
                    if case .reuse(let releaseID) = outcome, let current = followed {
                        if sheetOpen { try? await playReady(releaseID, title: current.paperTitle, account: account) }
                        else { readyNotice = ReadyNotice(releaseID: releaseID, title: current.paperTitle) }
                    }
                    return
                }
                if sheetOpen, generation?.phase != .offer { generation?.phase = job.state.isActive ? .running(job) : .finished(job) }
                if job.state.isActive { continue }
                // Settled: the balance moved (charged or released), and a closed sheet is told the outcome.
                Task { await host?.refreshCreditBalance() }
                if !sheetOpen, let current = followed { settledWhileClosed(job, of: current) }
                return
            }
        }
    }

    /// The outcome of a job whose sheet was closed: Play when ready, otherwise a plain line (Listen has the details).
    private func settledWhileClosed(_ job: PodcastJob, of current: PodcastGeneration) {
        let charge = job.chargedCredits.map { $0 == 0 ? "No credits were charged." : "Charged \($0) credits." } ?? ""
        let outcome: String
        switch job.state {
        case .ready:
            guard let releaseID = job.releaseID else { outcome = "Your episode of “\(current.paperTitle)” is ready."; break }
            readyNotice = ReadyNotice(releaseID: releaseID, title: current.paperTitle); return
        case .canceled: outcome = "The episode of “\(current.paperTitle)” was canceled."
        default: outcome = "The episode of “\(current.paperTitle)” couldn’t be made."
        }
        notice = [outcome, charge, "Listen on this paper has the details."].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Play from the ready notice (no new charge). The alert passes the notice it showed; a banner uses the current one.
    func playReadyNotice(_ shown: ReadyNotice? = nil) {
        guard let ready = shown ?? readyNotice, let account else { return }
        readyNotice = nil
        // From a banner inside another paper's Listen sheet: that sheet goes first (one sheet presents at a time).
        let closingSheet = generation != nil
        generation = nil
        Task {
            do {
                let episode = try await account.transport.episode(ready.releaseID)
                if closingSheet { try? await Task.sleep(for: .milliseconds(600)) }
                guard self.account?.id == account.id else { return }
                play(resolve(episode, fallback: ready.title))
            } catch { notice = error.podcastMessage }
        }
    }

    /// A job to show (and poll while active), or a release that is already ready for this account.
    private func follow(_ outcome: PodcastJobOutcome, _ current: PodcastGeneration, account: PodcastAccount) async throws {
        guard generation?.id == current.id else { return }
        switch outcome {
        case .job(let job):
            generation?.phase = job.state.isActive ? .running(job) : .finished(job)
            if job.state.isActive { poll(job.requestID) }
        case .reuse(let releaseID):
            try await playReady(releaseID, title: current.paperTitle, account: account)
        }
    }

    /// Closes the generation sheet and plays a ready release (no new charge).
    private func playReady(_ releaseID: UUID, title: String, account: PodcastAccount) async throws {
        let episode = try await account.transport.episode(releaseID)
        generation = nil
        // After the sheet has gone: one sheet presents at a time.
        try? await Task.sleep(for: .milliseconds(600))
        play(resolve(episode, fallback: title))
    }

    func playGenerated(_ job: PodcastJob) {
        guard let releaseID = job.releaseID, let account, let title = generation?.paperTitle else { return }
        generation = nil
        Task {
            do {
                let episode = try await account.transport.episode(releaseID)
                // After the generation sheet has gone: one sheet presents at a time.
                try? await Task.sleep(for: .milliseconds(600))
                play(resolve(episode, fallback: title))
            } catch { notice = error.podcastMessage }
        }
    }

    // MARK: Transcript evidence

    /// Opens the pinned paper at the quote (the passage finder used by Go to passage), or offers the source.
    func openEvidence(_ evidence: PodcastEvidence, in episode: PodcastEpisode) {
        guard let host else { return }
        guard let paper = host.papers.first(where: { $0.id == episode.documentID }) else {
            evidenceElsewhere = PodcastEvidenceElsewhere(quote: evidence.quote, episode: episode); return
        }
        showPlayer = false
        host.showEvidence(evidence.searchText, in: paper)
    }
}

extension ReaderModel {
    /// A transcript's evidence: open its paper (keeping the chat as it is) and center the quote, as Go to passage does,
    /// with the citation Back to where reading left off. Found by its text, so a newer conversion of the paper works too.
    func showEvidence(_ quote: String, in paper: Paper) {
        if selectedPaper?.id != paper.id || selectedPaper?.artifactID != paper.artifactID { select(paper) }
        referenceNotice = nil
        passageRequest = PaperPassageRequest(documentID: paper.id, conversationID: UUID(),
                                             anchor: TextAnchor(artifactID: paper.artifactID ?? UUID(), quote: quote), origin: .podcastEvidence)
        tab = .paper
        if wideMode != .browse { wideMode = .reader }
    }
}

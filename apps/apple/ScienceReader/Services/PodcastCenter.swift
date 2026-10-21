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
    /// The chosen writer (`anthropic`, `deepseek`; 2026-10-14), nil when the server lists none: the policy's default.
    var selectedWriter: String?
    /// Settings › AI defaults › Podcasts (2026-10-21): preselected whenever the chosen length offers it.
    var preferredWriter: String?
    /// Idempotency keys: one quote request per length and one start request per quote, so a retried quote or start is
    /// the same request, never a second quote or charge.
    var quoteRequestIDs: [String: UUID] = [:]
    var startRequestIDs: [UUID: UUID] = [:]
    /// The paper's own text on this device when the server has no converted text for it (migration 066), and the
    /// digest the server gave it once stored (the quote names the text by digest).
    var deviceSource: PodcastDeviceSource?
    var deviceTextSHA256: String?

    init(paperTitle: String, itemID: UUID, documentID: UUID, phase: Phase, capabilities: PodcastCapabilities?,
         ready: [PodcastEpisode] = [], selected: String? = nil, preferredWriter: String? = nil) {
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
        self.preferredWriter = preferredWriter
        self.selectedWriter = lengths.first { $0.profile == chosen }?.writer(preferring: preferredWriter)
    }

    /// A different length: the chosen writer stays when that length offers it, else the default writer from Settings,
    /// else the server's default.
    mutating func choose(length profile: String) {
        selected = profile
        guard let length = selectedLength else { return }
        selectedWriter = length.writers.contains { $0.writer == selectedWriter } ? selectedWriter : length.writer(preferring: preferredWriter)
    }

    /// After a request finishes the server deletes the text it was made from (migration 076): a new request sends it
    /// again under new request ids.
    mutating func forgetFinishedRequest() { deviceTextSHA256 = nil; quoteRequestIDs = [:]; startRequestIDs = [:] }

    var selectedLength: PodcastLength? { lengths.first { $0.profile == selected } }
    /// The writers the chosen length offers (empty on servers without the choice), the default first.
    var writers: [PodcastWriter] { selectedLength?.writers ?? [] }
    /// The maximum shown for a length: the chosen writer's when the server lists writers.
    func maxCredits(_ length: PodcastLength) -> Int { length.maxCredits(for: selectedWriter) }
    func readyEpisode(_ profile: String) -> PodcastEpisode? { ready.first { ($0.profile ?? PodcastLength.defaultProfile) == profile } }

    /// A length can be started when its maximum fits the available credits (a ready length never needs any; an
    /// unknown balance greys nothing out: the server still decides, and says so).
    func affordable(_ length: PodcastLength, credits: Int64?) -> Bool {
        guard readyEpisode(length.profile) == nil, let credits else { return true }
        return Int64(maxCredits(length)) <= credits
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

    /// The providers a quote names, as plain names ("DeepSeek and Google"): what the paper's text is sent to.
    static func plainProviders(_ labels: [String]) -> String {
        let names = labels.map { label -> String in
            let name = label.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            return name.hasPrefix("Google") ? "Google" : name
        }
        guard let last = names.last else { return "our providers" }
        return names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + last : last
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
    /// When the shown list was loaded, and a note when a later check failed: the list stays, said as of then
    /// (docs/architecture/RESILIENCE.md fix 10).
    private(set) var catalogLoadedAt: Date?
    private(set) var catalogStaleNote: String?
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
    /// An episode asked for earlier is ready, or couldn't be made, while the app is open (owner, 2026-10-16: "it doesnt
    /// matter if you leave the page or app, its there for you"): a small notice above the tab bar with Play or Try
    /// again, never a modal (a banner inside an open podcast sheet). In-app only; local notifications are an owner decision.
    struct ReadyNotice: Identifiable, Equatable {
        enum Kind: Equatable { case ready(UUID), failed(paperID: UUID?, profile: String?) }
        let id = UUID()
        let kind: Kind
        let title: String
        init(releaseID: UUID, title: String) { kind = .ready(releaseID); self.title = title }
        init(failedFor paperID: UUID?, profile: String?, title: String) { kind = .failed(paperID: paperID, profile: profile); self.title = title }
        var releaseID: UUID? { if case .ready(let id) = kind { return id }; return nil }
        var headline: String { releaseID == nil ? "Couldn’t make your episode" : "Your episode is ready" }
        var message: String {
            switch kind {
            case .ready: "Your episode of “\(title)” is ready."
            case .failed: "Your episode of “\(title)” couldn’t be made."
            }
        }
    }
    var readyNotice: ReadyNotice?
    /// Listen's own section (migration 076): the account's ready private episodes, newest first, and the episodes it
    /// asked for that are being made or couldn't be made.
    private(set) var myEpisodes: [PodcastEpisode] = []
    private(set) var myRequests: [PodcastMine.Request] = []
    /// Status polling stops after this long; the job itself continues on the server, and Listen keeps checking.
    static let pollLimit: TimeInterval = 1_800
    /// Listen checks for episodes being made after these waits (then every minute), for at most `mineLimit`.
    static let mineDelays: [TimeInterval] = [15, 30, 60]
    static let mineLimit: TimeInterval = 2_700
    /// Releases the server has corrected (superseded) since they were downloaded: their replacement.
    private(set) var corrections: [UUID: UUID] = [:]

    @ObservationIgnored weak var host: ReaderModel?
    @ObservationIgnored private var account: PodcastAccount?
    @ObservationIgnored private var store: PodcastLocalStore?
    @ObservationIgnored private var session: PodcastPlaybackSession?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var mineTask: Task<Void, Never>?
    @ObservationIgnored private var mineFetch: Task<Void, Never>?
    /// Requests whose outcome was already announced, so the status poll and Listen's check never announce one twice.
    @ObservationIgnored private var announced: Set<UUID> = []
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
        if PodcastFixtureTransport.isEnabled, ProcessInfo.processInfo.arguments.contains("--reset-podcast-fixture") { player.resetRatePreference(); defaultWriter = nil }
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

    /// Settings › AI defaults by activity › Podcasts (owner, 2026-10-21: "Podcasts is missing from defaults in model
    /// settings"): the writer each new episode request starts with, on this device. nil follows the server's default.
    /// Sent as the quote's `writer` only when the chosen length offers it (`PodcastLength.writer(preferring:)`).
    var defaultWriter: String? = UserDefaults.standard.string(forKey: PodcastCenter.defaultWriterKey) {
        didSet { UserDefaults.standard.set(defaultWriter, forKey: Self.defaultWriterKey) }
    }
    static let defaultWriterKey = "ai.podcastWriter"
    /// The writers Settings may offer: every writer the server lists for any length, the default first.
    var offeredWriters: [PodcastWriter] { capabilities?.offeredWriters ?? [] }
    /// The writer new requests start with, as Settings shows it: the saved default while the server offers it, else
    /// the server's default.
    var effectiveDefaultWriter: PodcastWriter? {
        offeredWriters.first { $0.writer == defaultWriter } ?? offeredWriters.first
    }
    /// Settings › Podcasts is shown while this account could make episodes: before the server has said (the row then
    /// loads what it offers) or when it offers generation.
    var writerSettingAvailable: Bool {
        guard host?.podcastAccount != nil || fixtureEnabled else { return false }
        return capabilities?.generation ?? true
    }

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
    /// Owner (build 35): the earlier wording ("a server copy of the paper") read as if PDFs were kept on the server
    /// (they are not; the server keeps only the text it converted for older papers) and was off-putting.
    /// The paper's own text for a private episode: a paper read on this device (a membership with its verified bundle),
    /// or an arXiv library item from before the HTML-first reader, named by its item id with the text this device
    /// prepared from its exact revision (migration 081; the server no longer keeps its text, as legacy chat).
    static func deviceSource(for paper: Paper, itemID: UUID? = nil) -> PodcastDeviceSource? {
        let reference: SourcePaperReference
        if let membership = paper.sourceMembership { reference = membership }
        else if let itemID, let source = paper.legacyArxivSource, paper.readerBundle?.manifest.source.kind == "arxiv-html",
                let legacy = try? SourcePaperReference(membershipID: itemID, sourceID: source.sourceID, revision: source.revision) { reference = legacy }
        else { return nil }
        guard let bundle = paper.readerBundle, let context = try? LocalPaperChatContext(reference: reference, bundle: bundle) else { return nil }
        return PodcastDeviceSource(context: context, title: paper.title, authors: paper.authorNames)
    }
    static func noEpisodeSource(for paper: Paper) -> String {
        if paper.sourceMembership != nil || paper.legacyArxivSource != nil {
            // The episode is made from the paper's text on this device (migrations 066, 081); it has to be opened here first.
            return "Open this paper first so its text is ready on this device, then try Listen again."
        }
        if paper.isLocalPDF || paper.fileURL != nil {
            return "Episodes are made from a paper’s structured text. This PDF has no structured text on this device yet."
        }
        return "Episodes can’t be made for this paper yet: it isn’t in your synced library. Add it to your library, then try again."
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
        mineTask?.cancel(); mineTask = nil; mineFetch?.cancel(); mineFetch = nil; myEpisodes = []; myRequests = []; announced = []
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
                catalogLoadedAt = Date(); catalogStaleNote = nil
                if let mine = page.mine { applyMine(mine) }
                #if DEBUG && FIXTURE_HOST
                fixtureAutoplay()
                #endif
                await refreshDownloadedStates()
            } catch {
                guard self.account?.id == account.id, !Task.isCancelled else { return }
                if !catalog.isEmpty, catalogState == .loaded, let loaded = catalogLoadedAt {
                    catalogStaleNote = "Couldn’t check for new episodes. These are the episodes from \(LastGood.phrase(loaded))."
                    return
                }
                catalogState = .failed(error.podcastMessage)
            }
        }
    }

    /// Listen's own section again (on returning to Listen or to the app, and while episodes are being made): the
    /// first page's `mine` only, leaving the shared list as it is.
    func refreshMine() {
        guard catalogState == .loaded else { if catalogState != .loading { loadCatalog() }; return }
        mineFetch?.cancel()
        mineFetch = Task {
            guard let account = await currentAccount(),
                  let page = try? await account.transport.catalog(after: nil, limit: 50),
                  self.account?.id == account.id, !Task.isCancelled else { return }
            capabilities = page.capabilities ?? capabilities
            if let mine = page.mine { applyMine(mine) }
        }
    }

    /// The app came back to the foreground: anything being made may be ready now.
    func sceneBecameActive() {
        guard account != nil, catalogState == .loaded || !myRequests.isEmpty else { return }
        refreshMine()
    }

    /// Whether a private episode is new to this device (never played here).
    func isNew(_ episode: PodcastEpisode) -> Bool {
        episode.scope == .private && resumePosition(episode.id) == nil && !isFinished(episode.id) && nowPlaying?.id != episode.id
    }

    /// The paper a request or episode was made from, when it's in this library.
    func paper(for documentID: UUID?) -> Paper? { documentID.flatMap { id in host?.papers.first { $0.id == id } } }

    /// A request's title: the server's (device papers), else the library's, else a neutral name.
    func title(of request: PodcastMine.Request) -> String {
        request.title ?? paper(for: request.documentID)?.title ?? "Your episode"
    }

    private func applyMine(_ mine: PodcastMine) {
        let previous = myRequests
        let wasMaking = Set(previous.filter { !$0.failed }.map(\.id))
        myEpisodes = mine.episodes.map { episode in
            let asked = mine.madeBy[episode.id].flatMap { id in previous.first { $0.id == id } }
            return resolve(episode, fallback: asked?.title)
        }
        myRequests = mine.requests
        // A request that was being made and isn't any more: its episode is ready, or it couldn't be made.
        for requestID in wasMaking where !announced.contains(requestID) && !mine.requests.contains(where: { $0.id == requestID && !$0.failed }) {
            if let failed = mine.requests.first(where: { $0.id == requestID && $0.failed }) {
                announced.insert(requestID)
                readyNotice = ReadyNotice(failedFor: failed.documentID, profile: failed.profile, title: title(of: failed))
            } else if let release = mine.madeBy.first(where: { $0.value == requestID })?.key, let episode = myEpisodes.first(where: { $0.id == release }) {
                announced.insert(requestID)
                if nowPlaying?.id != release {
                    let asked = previous.first { $0.id == requestID }
                    readyNotice = ReadyNotice(releaseID: release, title: episode.title ?? asked.map { title(of: $0) } ?? episode.displayTitle)
                }
            }
        }
        watchMine()
    }

    /// While something is being made: check again after 15 s, 30 s, then every minute (only in the foreground), for at
    /// most 45 minutes; returning to Listen or to the app checks at once.
    private func watchMine() {
        guard myRequests.contains(where: { !$0.failed }) else { mineTask?.cancel(); mineTask = nil; return }
        guard mineTask == nil else { return }
        mineTask = Task { [weak self] in
            let started = Date()
            var step = 0
            while !Task.isCancelled, Date().timeIntervalSince(started) < Self.mineLimit {
                var delay = Self.mineDelays[min(step, Self.mineDelays.count - 1)]
                #if DEBUG && FIXTURE_HOST
                if PodcastFixtureTransport.isEnabled { delay = 1 }
                #endif
                step += 1
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                if self.host?.sceneActive == false && !self.fixtureEnabled { continue }
                self.refreshMine()
            }
            // Out of time (not replaced): returning to Listen or to the app starts watching again.
            if !Task.isCancelled { self?.mineTask = nil }
        }
    }

    /// Try again from Listen or its notice: the paper's Listen sheet, at the same length.
    func tryAgain(paperID: UUID?, profile: String?) {
        readyNotice = nil
        guard let paper = paper(for: paperID) else {
            notice = "Open the paper on this device, then choose Listen to try again."; return
        }
        open(paper, choosingLength: false, preferring: profile)
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

    private func open(_ paper: Paper, choosingLength: Bool, preferring profile: String? = nil) {
        Task {
            guard let account = await currentAccount() else { notice = "Sign in to listen to paper episodes."; return }
            let itemID: UUID
            // A paper read on this device: its membership id names it, and its own text makes the episode (066).
            var deviceSource: PodcastDeviceSource?
            #if DEBUG && FIXTURE_HOST
            if PodcastFixtureTransport.isEnabled { itemID = paper.id } else if let found = host?.podcastItemID(for: paper) {
                itemID = found; deviceSource = Self.deviceSource(for: paper, itemID: found)
            } else {
                guard let source = Self.deviceSource(for: paper) else { notice = Self.noEpisodeSource(for: paper); return }
                itemID = UUID(uuidString: source.context.membershipID) ?? paper.id; deviceSource = source
            }
            #else
            // A synced item: an arXiv one from before the HTML-first reader also needs this device's text to make an
            // episode (its existing episodes play without it).
            if let found = host?.podcastItemID(for: paper) { itemID = found; deviceSource = Self.deviceSource(for: paper, itemID: found) } else {
                guard let source = Self.deviceSource(for: paper) else { notice = Self.noEpisodeSource(for: paper); return }
                itemID = UUID(uuidString: source.context.membershipID) ?? paper.id; deviceSource = source
            }
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
                                                   capabilities: lookup.capabilities ?? capabilities, ready: ready, selected: job.profile,
                                                   preferredWriter: defaultWriter)
                    generation?.deviceSource = deviceSource
                    poll(job.requestID)
                } else if lookup.capabilities?.generation == true {
                    generation = PodcastGeneration(paperTitle: paper.title, itemID: itemID, documentID: paper.id, phase: .offer,
                                                   capabilities: lookup.capabilities, ready: ready, selected: profile,
                                                   preferredWriter: defaultWriter)
                    generation?.deviceSource = deviceSource
                    // One confirm step: the chosen length's estimate is fetched at once (a quote holds nothing).
                    quoteIfWanted()
                } else if choosingLength, let episode = lookup.episode, !episode.state.blocksPlayback {
                    notice = "Other lengths can’t be made right now. This episode keeps playing."
                } else {
                    notice = "Episodes can’t be made right now. Reading is unaffected."
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
        let profile = current.selected, writer = current.selectedWriter
        // One request id per length and writer: a changed writer is a new quote, a retry is the same one.
        let key = writer.map { "\(profile)|\($0)" } ?? profile
        let requestID = current.quoteRequestIDs[key] ?? UUID()
        current.quoteRequestIDs[key] = requestID
        current.phase = .quoting
        generation = current
        Task {
            do {
                // The paper's text is sent once per request and named by its digest in every quote; the server deletes
                // it once the episode is made (migration 076), so text it no longer has is sent again, once.
                let send: @MainActor (PodcastDeviceSource) async throws -> String = { source in
                    let digest = try await account.transport.uploadSource(source)
                    if self.generation?.id == current.id { self.generation?.deviceTextSHA256 = digest }
                    return digest
                }
                var device: PodcastDeviceDescriptor?
                var cached = false
                if let source = current.deviceSource {
                    let digest: String
                    if let known = current.deviceTextSHA256 { digest = known; cached = true } else { digest = try await send(source) }
                    guard generation?.id == current.id else { return }
                    device = source.descriptor(textSHA256: digest)
                }
                let outcome: PodcastQuoteOutcome
                do {
                    outcome = try await account.transport.quote(itemID: current.itemID, requestID: requestID, profile: profile, writer: writer, device: device)
                } catch BackendError.rejected("source_unavailable") where cached && current.deviceSource != nil {
                    device = current.deviceSource!.descriptor(textSHA256: try await send(current.deviceSource!))
                    outcome = try await account.transport.quote(itemID: current.itemID, requestID: requestID, profile: profile, writer: writer, device: device)
                }
                guard generation?.id == current.id, generation?.selected == profile, generation?.selectedWriter == writer else { return }
                switch outcome {
                case .quote(let quote): generation?.phase = .quoted(quote)
                case .reuse(let releaseID): try await playReady(releaseID, title: current.paperTitle, account: account)
                case .join(let requestID): try await follow(account.transport.status(requestID: requestID), current, account: account)
                }
            } catch {
                guard generation?.id == current.id, generation?.selected == profile else { return }
                // Quotes hold nothing: a retry may use a new request (an expired quote can't be revived).
                generation?.quoteRequestIDs[key] = nil
                generation?.phase = .failed(.from(error))
            }
        }
    }

    /// Choosing a length: it is quoted at once (a quote holds nothing; an estimate still in flight for the previous
    /// choice is ignored when it lands); a length that is ready plays instead of being made again; one known to be
    /// beyond the balance waits, greyed out, for a different choice.
    /// The reader chose a writer: the maxima follow it and the length is quoted again.
    func selectWriter(_ writer: String) {
        guard var current = generation, current.selectedWriter != writer, current.writers.contains(where: { $0.writer == writer }) else { return }
        current.selectedWriter = writer
        if case .quoted = current.phase { current.phase = .offer }
        generation = current
        quoteIfWanted()
    }
    func selectLength(_ profile: String) {
        guard var current = generation, current.selected != profile, current.lengths.contains(where: { $0.profile == profile }) else { return }
        switch current.phase {
        case .offer, .quoting, .quoted, .failed: break
        case .finished(let job) where job.state == .failed: current.forgetFinishedRequest()
        default: return
        }
        current.choose(length: profile)
        current.phase = .offer
        generation = current
        quoteIfWanted()
    }

    /// Try again in the sheet: the same length and writer, asked afresh. A finished request's text was deleted with it
    /// (migration 076), so the paper's text is sent again with the new quote.
    func askAgain() {
        guard var current = generation else { return }
        if case .finished = current.phase { current.forgetFinishedRequest() }
        current.quoteRequestIDs = [:]
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
                // Listen shows it being made, wherever the reader goes next.
                refreshMine()
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
                // Past the bound the poll stops quietly: Listen keeps checking and shows the episode when it's ready.
                if elapsed >= Self.pollLimit { refreshMine(); return }
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
                if !sheetOpen, let current = followed { settledWhileClosed(job, of: current) } else { announced.insert(job.requestID) }
                refreshMine()
                return
            }
        }
    }

    /// The outcome of a job whose sheet was closed: a small notice with Play when ready, or Try again when it couldn't
    /// be made (Listen shows it too). A cancel the reader asked for needs no notice.
    private func settledWhileClosed(_ job: PodcastJob, of current: PodcastGeneration) {
        guard !announced.contains(job.requestID) else { return }
        announced.insert(job.requestID)
        switch job.state {
        case .ready:
            guard let releaseID = job.releaseID else { return }
            readyNotice = ReadyNotice(releaseID: releaseID, title: current.paperTitle)
        case .canceled: return
        default:
            readyNotice = ReadyNotice(failedFor: current.documentID, profile: job.profile ?? current.selected, title: current.paperTitle)
        }
    }

    /// Play from the ready notice (no new charge). The alert passes the notice it showed; a banner uses the current one.
    func playReadyNotice(_ shown: ReadyNotice? = nil) {
        guard let ready = shown ?? readyNotice, let account else { return }
        readyNotice = nil
        guard let releaseID = ready.releaseID else {
            if case .failed(let paperID, let profile) = ready.kind { tryAgain(paperID: paperID, profile: profile) }
            return
        }
        // From a banner inside another paper's Listen sheet: that sheet goes first (one sheet presents at a time).
        let closingSheet = generation != nil
        generation = nil
        Task {
            do {
                let episode = try await account.transport.episode(releaseID)
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

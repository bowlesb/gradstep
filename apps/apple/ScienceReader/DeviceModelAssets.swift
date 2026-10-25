import Foundation
import Network
import Observation
import ScienceReaderCore
import UIKit

/// The on-device PDF models as a separate download (docs/architecture/DEVICE_PDF_ROUTE.md "The models as a download").
///
/// iPhone and iPad: the app carries only the pack's description (`device-models-pack.json`); the pack itself is an
/// On-Demand Resources tag hosted by the App Store with the build. Downloading asks the system for the tag, checks every
/// file against the description while copying it to Application Support (excluded from backup), then lets the system
/// purge its own copy. The Mac app (On-Demand Resources do not exist there) carries the models inside the app.
@MainActor @Observable
final class DeviceModelAssets {
    enum State: Equatable {
        /// This build has neither models nor a pack to download.
        case unavailable
        case notDownloaded
        /// 0…1: the download is the first 90 %, checking and copying the rest.
        case downloading(Double)
        case ready(bytes: Int64, bundled: Bool)
        case failed(String)
    }

    static let shared = DeviceModelAssets()

    private(set) var state: State = .unavailable
    /// Cellular or Low Data Mode: the download offer says Wi-Fi is better for its size.
    private(set) var onExpensiveNetwork = false
    let pack: DevicePDFModelPack? = DeviceModelAssets.packDescription

    /// The reader once chose to download the models: a model update downloads again by itself on Wi-Fi.
    private(set) var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "deviceModels.wanted") }
        set { UserDefaults.standard.set(newValue, forKey: "deviceModels.wanted") }
    }
    @ObservationIgnored private var request: NSBundleResourceRequest?
    /// Each download run's number: a cancelled run's late answers change nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var olderVersionRemoved = false
    @ObservationIgnored private var checkedForUpdate = false
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var download: Task<Bool, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        #if DEBUG && FIXTURE_HOST
        if let fixture = Self.downloadFixture {
            // A fixture run starts from the default: nothing chosen, nothing downloaded before.
            UserDefaults.standard.removeObject(forKey: "reader.deviceModel")
            UserDefaults.standard.removeObject(forKey: "deviceModels.wanted")
            fixtureInstalled = fixture == .ready
            refresh()
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained, online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(expensive: expensive, online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "device-models.network"))
        refresh()
    }

    // MARK: Where the models are (any thread)

    /// The pack this build expects, from the description inside the app; nil when the build was made without models.
    nonisolated static let packDescription: DevicePDFModelPack? = {
        guard let url = Bundle.main.url(forResource: "device-models-pack", withExtension: "json") else { return nil }
        return try? DevicePDFModelPack.load(from: url)
    }()

    nonisolated static var store: DevicePDFModelStore? {
        guard let pack = packDescription, let root = try? DevicePDFModelStore.defaultRoot() else { return nil }
        return DevicePDFModelStore(root: root, pack: pack)
    }

    /// The models inside the app itself (the Mac app; a build with On-Demand Resources turned off). An On-Demand
    /// Resources copy lives outside the app's folder and is never taken for this.
    nonisolated static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(packDescription?.folder ?? "DeviceModels", isDirectory: true)
    }

    /// Where the route loads its models from now, or nil when they must be downloaded first.
    nonisolated static func locate() -> DevicePDFModelLocator.Location? {
        DevicePDFModelLocator.locate(store: store, bundled: bundledDirectory)
    }

    // MARK: State

    func refresh() {
        guard download == nil else { return }
        #if DEBUG && FIXTURE_HOST
        if Self.downloadFixture != nil { state = fixtureInstalled ? .ready(bytes: Self.fixtureBytes, bundled: false) : .notDownloaded; return }
        #endif
        if let location = Self.locate() {
            switch location {
            case .bundled(let url): state = .ready(bytes: DevicePDFModelStore.bytes(in: url), bundled: true)
            case .override(let url): state = .ready(bytes: DevicePDFModelStore.bytes(in: url), bundled: true)
            case .downloaded: state = .ready(bytes: Self.store?.installedBytes ?? 0, bundled: false)
            }
            Self.store?.removeOtherVersions()
            return
        }
        guard pack != nil else { state = .unavailable; return }
        #if targetEnvironment(macCatalyst)
        state = .unavailable
        #else
        // A model update: the old version is not this build's models, so it goes now; the new one comes on Wi-Fi.
        if !(Self.store?.otherVersions.isEmpty ?? true) { olderVersionRemoved = true }
        Self.store?.removeOtherVersions()
        state = .notDownloaded
        #endif
    }

    /// The first network answer decides whether a model update downloads by itself: on Wi-Fi, for a reader who had
    /// downloaded the models before.
    private func networkChanged(expensive: Bool, online: Bool) {
        onExpensiveNetwork = expensive
        guard online, !checkedForUpdate else { return }
        checkedForUpdate = true
        if state == .notDownloaded, wanted || olderVersionRemoved, !expensive { _ = start(urgent: false) }
    }

    /// The state as Settings' one row reads it (`DeviceModelReaderSetting`).
    var files: DeviceModelFiles {
        switch state {
        case .unavailable: .unavailable
        case .notDownloaded: .missing
        case .downloading(let fraction): .downloading(fraction)
        case .ready(_, let bundled): .ready(bundled: bundled)
        case .failed(let message): .failed(message)
        }
    }

    /// The on-device PDF reader's choice at launch: what was stored, else on only where the models were downloaded here.
    static func initialReaderPreference() -> Bool {
        let assets = shared
        return DeviceModelReaderSetting.initialPreference(stored: UserDefaults.standard.object(forKey: "reader.deviceModel") as? Bool,
                                                          files: assets.files, downloadedBefore: assets.wanted)
    }

    /// The models are a download on this device (not the Mac app's own copy, not a test folder).
    var downloadable: Bool {
        guard pack != nil || Self.downloadFixture != nil else { return false }
        if case .ready(_, let bundled) = state { return !bundled }
        return state != .unavailable
    }

    /// "about 365 MB": the pack’s size to the nearest 5 MB.
    var approximateSize: String {
        let megabytes = Double(pack?.bytes ?? (Self.downloadFixture != nil ? Self.fixtureBytes : 0)) / 1_000_000
        return "about \(Int((megabytes / 5).rounded()) * 5) MB"
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // MARK: Download

    /// Downloads, checks and installs the pack; true when the models are ready. A second call joins the first.
    @discardableResult
    func ensureDownloaded() async -> Bool {
        if case .ready = state { return true }
        return await start(urgent: true).value
    }

    private func start(urgent: Bool) -> Task<Bool, Never> {
        if let download {
            if urgent { request?.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent }
            return download
        }
        #if DEBUG && FIXTURE_HOST
        if let fixture = Self.downloadFixture { return startFixture(fixture) }
        #endif
        #if targetEnvironment(macCatalyst)
        // On-Demand Resources do not exist on the Mac: its models are inside the app or not at all.
        return Task { false }
        #else
        guard let pack, let store = Self.store else { return Task { false } }
        wanted = true
        state = .downloading(0)
        generation += 1
        let run = generation
        let request = NSBundleResourceRequest(tags: [pack.tag])
        request.loadingPriority = urgent ? NSBundleResourceRequestLoadingPriorityUrgent : 0.5
        self.request = request
        progressObservation = request.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.progressed(run, 0.9 * fraction) }
        }
        let task = Task { [weak self] () -> Bool in
            let failure: String? = await withCheckedContinuation { continuation in
                request.beginAccessingResources { error in
                    continuation.resume(returning: error.map { ($0 as NSError).code == NSUserCancelledError ? "" : Self.message(for: $0) })
                }
            }
            guard let self, self.generation == run, self.request != nil else { request.endAccessingResources(); return false }
            // A run cancelled while it installs must not end a newer run's request.
            defer { if self.generation == run { self.finish() } else { request.endAccessingResources() } }
            if let failure {
                self.state = failure.isEmpty ? .notDownloaded : .failed(failure)
                return false
            }
            guard let source = request.bundle.url(forResource: pack.folder, withExtension: nil) else {
                self.state = .failed("The download didn’t contain the model. Try again.")
                return false
            }
            // Copying and checking 365 MB takes seconds: finished in the background if the app is sent there.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Install the PDF reading model")
            defer { UIApplication.shared.endBackgroundTask(background) }
            let installed: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try await store.install(from: source, progress: { fraction in
                        Task { @MainActor [weak self] in self?.progressed(run, 0.9 + 0.1 * fraction) }
                    })
                    return nil
                } catch { return Self.message(for: error) }
            }.value
            guard self.generation == run else { return false }
            if let installed { self.state = .failed(installed); return false }
            self.state = .ready(bytes: store.installedBytes, bundled: false)
            return true
        }
        download = task
        return task
        #endif
    }

    private func progressed(_ run: Int, _ fraction: Double) {
        guard generation == run, case .downloading(let shown) = state, fraction > shown else { return }
        state = .downloading(min(1, fraction))
    }

    /// Ends the system's hold on its own copy (ours is in Application Support) and lets it go first when space is short.
    private func finish() {
        request?.endAccessingResources()
        if let tag = pack?.tag { Bundle.main.setPreservationPriority(0, forTags: [tag]) }
        progressObservation = nil
        self.request = nil
        download = nil
    }

    func cancel() {
        #if DEBUG && FIXTURE_HOST
        if Self.downloadFixture != nil {
            guard download != nil else { return }
            generation += 1; download = nil; state = .notDownloaded; return
        }
        #endif
        guard let request else { return }
        request.progress.cancel()
        // The system may finish the transfer anyway; this run no longer installs it.
        generation += 1
        finish()
        state = .notDownloaded
    }

    /// Settings › On-device PDF model › Remove.
    func remove() {
        cancel()
        wanted = false
        #if DEBUG && FIXTURE_HOST
        fixtureInstalled = false
        #endif
        try? Self.store?.removeAll()
        state = pack == nil ? .unavailable : .notDownloaded
        refresh()
    }

    #if DEBUG && FIXTURE_HOST
    // MARK: UI-test fixture

    /// `--device-model-download-fixture[=ready|fail|slow]` (UI tests and visual checks): a pack of about 365 MB that
    /// "downloads" in about two seconds (`slow`: twenty; `fail`: stops at 40 % with the connection message) without On-Demand
    /// Resources or files; `ready` starts downloaded. Settings only: the route still finds no models.
    enum DownloadFixture: String { case missing, ready, fail, slow }
    nonisolated static let downloadFixture: DownloadFixture? = {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--device-model-download-fixture") }) else { return nil }
        return argument.split(separator: "=").dropFirst().first.flatMap { DownloadFixture(rawValue: String($0)) } ?? .missing
    }()
    nonisolated static let fixtureBytes: Int64 = 365_200_000
    @ObservationIgnored private var fixtureInstalled = false

    private func startFixture(_ fixture: DownloadFixture) -> Task<Bool, Never> {
        wanted = true
        state = .downloading(0)
        generation += 1
        let run = generation, steps = 20, pause: Duration = fixture == .slow ? .seconds(1) : .milliseconds(100)
        let task = Task { [weak self] () -> Bool in
            for step in 1...steps {
                try? await Task.sleep(for: pause)
                guard let self, self.generation == run else { return false }
                if fixture == .fail, step == steps * 2 / 5 {
                    self.download = nil
                    self.state = .failed("The download stopped. Check the connection and try again.")
                    return false
                }
                self.progressed(run, Double(step) / Double(steps))
            }
            guard let self, self.generation == run else { return false }
            self.download = nil
            self.fixtureInstalled = true
            self.state = .ready(bytes: Self.fixtureBytes, bundled: false)
            return true
        }
        download = task
        return task
    }
    #else
    nonisolated static var downloadFixture: Never? { nil }
    nonisolated static let fixtureBytes: Int64 = 0
    #endif

    nonisolated static func message(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSBundleOnDemandResourceOutOfSpaceError || ns.code == NSFileWriteOutOfSpaceError {
            return "Not enough free space on this device for the model."
        }
        if let pack = error as? DevicePDFModelPackError {
            switch pack {
            case .compileFailed: return "The model couldn’t be prepared on this device."
            default: return "The downloaded model didn’t match this version of Gradstep. Try again."
            }
        }
        if ns.domain == NSURLErrorDomain { return "The download stopped. Check the connection and try again." }
        return "The model couldn’t be downloaded. Try again."
    }
}

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
    private var wanted: Bool {
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

    /// The models are a download on this device (not the Mac app's own copy, not a test folder).
    var downloadable: Bool {
        guard pack != nil else { return false }
        if case .ready(_, let bundled) = state { return !bundled }
        return state != .unavailable
    }

    /// "about 365 MB": the pack’s size to the nearest 5 MB.
    var approximateSize: String {
        let megabytes = Double(pack?.bytes ?? 0) / 1_000_000
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
        try? Self.store?.removeAll()
        state = pack == nil ? .unavailable : .notDownloaded
        refresh()
    }

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

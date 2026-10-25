import Foundation
import Network
import Observation
import ScienceReaderCore

/// Whether this device has a network path, and a nudge when it comes back (docs/reviews/OFFLINE_AND_STORAGE_20261025.md):
/// queued work (sync, library changes, the first-device setup) resumes at once instead of after its back-off, which can
/// reach five minutes. Nothing here blocks a request: a request made while "offline" still runs and fails or succeeds
/// on its own (the path monitor can lag a real change).
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOffline = false
    @ObservationIgnored private var reconnected: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        #if DEBUG && FIXTURE_HOST
        _ = NetworkFaultFixture.started // the window counts from launch (ReaderModel makes this at launch)
        if let window = NetworkFaultFixture.offlineWindow {
            isOffline = true
            if window.isFinite {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, window - NetworkFaultFixture.elapsed)))
                    self?.changed(online: true)
                }
            }
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.changed(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "connectivity"))
    }

    /// Calls `handler` each time the device goes from offline to online. Keep the token to stop.
    @discardableResult
    func onReconnect(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID(); reconnected[token] = handler; return token
    }
    func cancel(_ token: UUID?) { if let token { reconnected[token] = nil } }

    private func changed(online: Bool) {
        let wasOffline = isOffline
        isOffline = !online
        guard wasOffline, online else { return }
        for handler in reconnected.values { handler() }
    }
}

/// One short line for a failed connection or a full disk, saying what happened; nil for any other error (callers keep
/// their own wording). `service`: who couldn't be reached ("Gradstep", "arXiv").
enum ConnectionText {
    static let offline = "You’re offline. What’s on this device still works."
    /// Sync's line while offline (it resumes by itself when the connection returns).
    static let offlineSync = "Offline · Saved on this device"
    static let networkSignIn = "This Wi‑Fi needs you to sign in. Open Safari to sign in, then try again."

    static func message(for error: Error, reaching service: String = "Gradstep") -> String? {
        if let space = StorageSpace.message(for: error) { return space }
        guard let code = urlCode(error) else { return nil }
        switch code {
        case .cancelled: return nil
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive: return offline
        case .timedOut: return "\(service) took too long to answer. Try again."
        case .networkConnectionLost: return "The connection was lost. Try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            // A captive Wi‑Fi answering in place of the real server fails here.
            return "Couldn’t make a secure connection to \(service). If this Wi‑Fi asks you to sign in, open Safari to do so, then try again."
        default: return "Couldn’t reach \(service). Check your connection and try again."
        }
    }

    /// The device has no network path (as opposed to a server that didn't answer).
    static func isOffline(_ error: Error) -> Bool {
        guard let code = urlCode(error) else { return false }
        return [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive].contains(code)
    }

    /// Any failure to connect or to finish talking to a server (not a refusal, not a full disk).
    static func isConnection(_ error: Error) -> Bool {
        guard let code = urlCode(error) else { return false }
        return code != .cancelled
    }

    private static func urlCode(_ error: Error) -> URLError.Code? {
        if let url = error as? URLError { return url.code }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain ? URLError.Code(rawValue: ns.code) : nil
    }
}

#if DEBUG && FIXTURE_HOST
/// `--network-offline[=<seconds>]` (UI journeys only): the device is offline from launch (for that many seconds, then
/// back online). Every request the app makes fails as offline meanwhile, through `BackendFaultProtocol` (backend, arXiv,
/// PDF downloads) and the chat fixture; `Connectivity` reports it. The Simulator shares the Mac's network, which stays on.
enum NetworkFaultFixture {
    static let started = Date()
    static let offlineWindow: TimeInterval? = {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--network-offline") }) else { return nil }
        let value = argument.split(separator: "=").dropFirst().first.flatMap { TimeInterval(String($0)) }
        return value ?? .infinity
    }()
    static var elapsed: TimeInterval { Date().timeIntervalSince(started) }
    /// Offline now (within the window).
    static var isOffline: Bool { offlineWindow.map { elapsed < $0 } ?? false }
}
#endif

#if DEBUG && FIXTURE_HOST
/// `--storage-full-fixture[=<seconds>]` (UI journeys only): once a fixture account's store is open (`arm`), every write to
/// the encrypted store and the local paper and reader stores fails as a full disk would (`StorageFullError`, 120 MB to
/// free), for that long, then succeeds again, as when the reader frees some space. Nothing is written meanwhile.
enum StorageFullFixture {
    static let window: TimeInterval? = {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--storage-full-fixture") }) else { return nil }
        return argument.split(separator: "=").dropFirst().first.flatMap { TimeInterval(String($0)) } ?? .infinity
    }()
    nonisolated(unsafe) private static var armedAt: Date?
    static let error = StorageFullError(needed: 120_000_000)
    static func arm() { if window != nil, armedAt == nil { armedAt = Date() } }
    static var isFull: Bool {
        guard let window, let armedAt else { return false }
        return Date().timeIntervalSince(armedAt) < window
    }
}
#endif

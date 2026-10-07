#if INTERNAL
import Foundation
import Observation
import ReplayKit
import UIKit

/// Records a test session for review (docs/SESSION_REVIEW.md): the app's screen
/// (ReplayKit, app content only; the microphone when "Include my voice" is on)
/// plus `SessionTimeline`. Internal and Debug builds only. Nothing is uploaded:
/// the finished session is one zip the owner AirDrops to the Mac.
@MainActor @Observable
final class SessionCapture {
    static let shared = SessionCapture()

    enum State: Equatable { case idle, starting, recording, finishing }
    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    private(set) var sessions: [URL] = []
    var share: SharedSession?
    var issue: String?
    private(set) var showSyncBand = false
    var includeVoice = UserDefaults.standard.object(forKey: "session.includeVoice") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeVoice, forKey: "session.includeVoice") }
    }

    struct SharedSession: Identifiable { let url: URL; var id: URL { url } }

    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var videoRecording = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let hangs = HangWatch()

    static var root: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TestSessions", isDirectory: true)
    }

    private init() { refreshSessions() }

    func start() async {
        guard state == .idle else { return }
        state = .starting; issue = nil
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = formatter.string(from: Date())
        let directory = Self.root.appendingPathComponent(id, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { issue = "Couldn’t create the session folder."; state = .idle; return }
        self.directory = directory

        let recorder = RPScreenRecorder.shared()
        videoRecording = false
        if recorder.isAvailable {
            recorder.isMicrophoneEnabled = includeVoice
            do { try await recorder.startRecording(); videoRecording = true }
            catch { issue = "Screen recording wasn’t started (\((error as NSError).localizedDescription)). Only the event log is recorded." }
        } else { issue = "Screen recording isn’t available here. Only the event log is recorded." }

        let bounds = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds }.first ?? .zero
        do {
            try SessionTimeline.shared.begin(at: directory.appendingPathComponent("timeline.jsonl"), metadata: [
                "video": videoRecording ? "1" : "0", "voice": videoRecording && includeVoice ? "1" : "0",
                "window_width": String(Int(bounds.width)), "window_height": String(Int(bounds.height)),
            ])
        } catch {
            issue = "Couldn’t start the event log."
            if videoRecording { recorder.stopRecording { _, _ in } }
            state = .idle; return
        }
        startedAt = Date()
        startObserving()
        // ReplayKit captures only once its permission prompt has gone: wait until the app is active again.
        for _ in 0..<50 where UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(400))
        // Sync marker: a magenta band the review tool finds in the video.
        showSyncBand = true; SessionTimeline.shared.record("sync_band", ["on": "1"])
        try? await Task.sleep(for: .milliseconds(700))
        showSyncBand = false; SessionTimeline.shared.record("sync_band", ["on": "0"])
        state = .recording
    }

    func mark() { SessionTimeline.shared.record("mark") }

    func stop() async {
        guard state == .recording, let directory else { return }
        state = .finishing
        SessionTimeline.shared.end()
        stopObserving()
        if videoRecording {
            do { try await RPScreenRecorder.shared().stopRecording(withOutput: directory.appendingPathComponent("screen.mp4")) }
            catch { issue = "The screen recording couldn’t be saved; the event log is kept." }
        }
        let info = Bundle.main.infoDictionary
        var system = utsname(); uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let meta: [String: Any] = [
            "format": "science-reader-session-1", "app": "Gradstep",
            "version": info?["CFBundleShortVersionString"] as? String ?? "", "build": info?["CFBundleVersion"] as? String ?? "",
            "device": model, "system": UIDevice.current.systemVersion, "idiom": UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            "screen_scale": screen?.scale ?? 0, "started_at": ISO8601DateFormatter().string(from: startedAt ?? Date()),
            "video": videoRecording && FileManager.default.fileExists(atPath: directory.appendingPathComponent("screen.mp4").path),
            "voice": videoRecording && includeVoice,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("meta.json"))
        }
        let zip = Self.package(directory)
        if zip != nil { try? FileManager.default.removeItem(at: directory) }
        self.directory = nil; startedAt = nil
        pruneSessions(keeping: 5); refreshSessions()
        if let zip { share = SharedSession(url: zip) } else if issue == nil { issue = "The session couldn’t be packaged." }
        state = .idle
    }

    func delete(_ url: URL) { try? FileManager.default.removeItem(at: url); refreshSessions() }

    /// One zip per session (system zip of the folder), named for the Mac's review script.
    private static func package(_ directory: URL) -> URL? {
        let destination = root.appendingPathComponent("gradstep-session-\(directory.lastPathComponent).zip")
        var result: URL?, failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &failure) { zipped in
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: zipped, to: destination)) != nil { result = destination }
        }
        return result
    }

    private func refreshSessions() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        sessions = files.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneSessions(keeping count: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for old in files.filter({ $0.pathExtension == "zip" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(count) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private func startObserving() {
        let center = NotificationCenter.default, timeline = SessionTimeline.shared
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                timeline.record("keyboard", ["shown": "1", "height": String(Int(frame.height))])
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
                timeline.record("keyboard", ["shown": "0"])
            },
            center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let bounds = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds }.first ?? .zero
                    timeline.record("orientation", ["width": String(Int(bounds.width)), "height": String(Int(bounds.height))])
                }
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                timeline.record("memory_warning")
            },
        ]
        hangs.start()
    }

    private func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        hangs.stop()
    }
}

/// Main-thread stalls longer than 400 ms, recorded when they end (`ms` is the
/// stall's length, so it began `ms` before the event's time).
final class HangWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "session.hang-watch")
    private var timer: DispatchSourceTimer?
    private var pending = false
    private var sentAt: TimeInterval = 0

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(100))
            source.setEventHandler { [self] in
                guard !pending else { return }
                pending = true; sentAt = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { [self] in
                    let answered = ProcessInfo.processInfo.systemUptime
                    queue.async { [self] in
                        let stall = answered - sentAt
                        if stall > 0.4 { SessionTimeline.shared.record("hang", ["ms": String(Int(stall * 1000))]) }
                        pending = false
                    }
                }
            }
            timer = source; source.resume()
        }
    }

    func stop() { queue.async { [self] in timer?.cancel(); timer = nil; pending = false } }
}
#endif

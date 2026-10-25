#if INTERNAL
import Foundation
import Observation
import ReplayKit
import UIKit

/// What the recorder needs of ReplayKit (a stand-in in unit tests: ReplayKit does not record in the Simulator).
@MainActor
protocol SessionScreenRecording: AnyObject {
    var isAvailable: Bool { get }
    var isMicrophoneEnabled: Bool { get set }
    func startRecording() async throws
    func stopRecording(withOutput url: URL) async throws
}

/// ReplayKit's in-app recording.
@MainActor
final class ReplayKitRecording: SessionScreenRecording {
    private var recorder: RPScreenRecorder { RPScreenRecorder.shared() }
    var isAvailable: Bool { recorder.isAvailable }
    var isMicrophoneEnabled: Bool {
        get { recorder.isMicrophoneEnabled }
        set { recorder.isMicrophoneEnabled = newValue }
    }
    /// Through the completion handler, so the call waits for ReplayKit's answer (a bare `startRecording()` can resolve to
    /// the handler form with no handler, which returns at once).
    func startRecording() async throws {
        let recorder = recorder
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startRecording { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func stopRecording(withOutput url: URL) async throws { try await recorder.stopRecording(withOutput: url) }
}

/// Records a test session for review (docs/SESSION_REVIEW.md): the app's screen
/// (ReplayKit, app content only; the microphone when "Include my voice" is on)
/// plus `SessionTimeline`. Internal and Debug builds only. Nothing is uploaded:
/// the finished session is one zip the owner AirDrops to the Mac.
///
/// ReplayKit's picture stops once the app has been in the background while its sound goes on (owner session
/// 20261024-164759: the picture ended at 0:16, the sound ran 11 minutes). So when the app comes back the recorder ends
/// that file (everything up to the background is in it) and starts the next one, `screen-2.mp4`, …, with the sync band
/// again and a `video_gap` event; the review tool reads every part.
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
    /// The screen video stopped and could not restart: the strip says so; the event log goes on.
    private(set) var videoStopped = false
    var includeVoice = UserDefaults.standard.object(forKey: "session.includeVoice") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeVoice, forKey: "session.includeVoice") }
    }

    struct SharedSession: Identifiable { let url: URL; var id: URL { url } }

    @ObservationIgnored private(set) var directory: URL?
    @ObservationIgnored private var videoRecording = false
    /// The video part being recorded (1: screen.mp4).
    @ObservationIgnored private var videoPart = 1
    /// When the app went to the background with the video running (timeline seconds).
    @ObservationIgnored private var backgroundedAt: TimeInterval?
    /// Ending one video part and starting the next; Stop waits for it.
    @ObservationIgnored private(set) var videoRestart: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let hangs = HangWatch()
    @ObservationIgnored private let recorder: SessionScreenRecording
    @ObservationIgnored private let root: URL

    static var root: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TestSessions", isDirectory: true)
    }

    /// The file of a video part: screen.mp4, then screen-2.mp4, …
    static func videoFile(_ part: Int) -> String { part == 1 ? "screen.mp4" : "screen-\(part).mp4" }

    init(recorder: SessionScreenRecording = ReplayKitRecording(), root: URL = SessionCapture.root) {
        self.recorder = recorder; self.root = root
        refreshSessions()
    }

    func start() async {
        guard state == .idle else { return }
        state = .starting; issue = nil; videoStopped = false; videoPart = 1; backgroundedAt = nil
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = formatter.string(from: Date())
        let directory = root.appendingPathComponent(id, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { issue = "Couldn’t create the session folder."; state = .idle; return }
        self.directory = directory

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
            if videoRecording { try? await recorder.stopRecording(withOutput: directory.appendingPathComponent(Self.videoFile(1))) }
            state = .idle; return
        }
        startedAt = Date()
        startObserving()
        await showSyncMarker(part: 1)
        state = .recording
        // Sent to the background while starting: the first part's picture may already have stopped.
        if backgroundedAt != nil, UIApplication.shared.applicationState == .active { appBecameActive() }
    }

    /// Sync marker: a magenta band the review tool finds in the video. ReplayKit captures only once its permission prompt
    /// has gone, so it waits until the app is active again.
    private func showSyncMarker(part: Int) async {
        for _ in 0..<50 where UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(400))
        let segment: [String: String] = part == 1 ? [:] : ["segment": String(part)]
        showSyncBand = true; SessionTimeline.shared.record("sync_band", segment.merging(["on": "1"]) { $1 })
        try? await Task.sleep(for: .milliseconds(700))
        showSyncBand = false; SessionTimeline.shared.record("sync_band", segment.merging(["on": "0"]) { $1 })
    }

    func mark() { SessionTimeline.shared.record("mark") }

    // MARK: Background and back

    /// The app went to the background: ReplayKit's picture stops here.
    func appEnteredBackground() {
        guard state == .starting || state == .recording, videoRecording, backgroundedAt == nil else { return }
        backgroundedAt = SessionTimeline.shared.now
    }

    /// The app is active again: after a background, the video part ends and the next one starts. Becoming active without
    /// having been in the background (Control Center, an alert, ReplayKit's own prompt) changes nothing.
    func appBecameActive() {
        guard let from = backgroundedAt, videoRestart == nil, state == .recording, videoRecording else { return }
        backgroundedAt = nil
        videoRestart = Task { [weak self] in
            await self?.restartVideo(from: from)
            self?.videoRestart = nil
        }
    }

    private func restartVideo(from: TimeInterval) async {
        guard let directory else { return }
        let timeline = SessionTimeline.shared, ending = videoPart, next = ending + 1, file = Self.videoFile(next)
        timeline.record("video_segment", ["phase": "end", "segment": String(ending)])
        do { try await recorder.stopRecording(withOutput: directory.appendingPathComponent(Self.videoFile(ending))) }
        catch { timeline.record("video_segment", ["phase": "save_failed", "segment": String(ending), "error": String((error as NSError).code)]) }
        recorder.isMicrophoneEnabled = includeVoice
        do {
            try await recorder.startRecording()
            videoPart = next
            let to = timeline.now ?? from
            timeline.record("video_segment", ["phase": "start", "segment": String(next), "file": file])
            timeline.record("video_gap", ["from": Self.seconds(from), "to": Self.seconds(to), "resumed": "1", "segment": String(next), "file": file])
            await showSyncMarker(part: next)
        } catch {
            videoRecording = false; videoStopped = true
            timeline.record("video_gap", ["from": Self.seconds(from), "to": Self.seconds(timeline.now ?? from), "resumed": "0",
                                          "error": String((error as NSError).code)])
            issue = "The screen video stopped when Gradstep went to the background and couldn’t restart; the event log goes on."
        }
    }

    private static func seconds(_ t: TimeInterval) -> String { String(format: "%.3f", t) }

    // MARK: Stop

    func stop() async {
        guard state == .recording, let directory else { return }
        state = .finishing
        await videoRestart?.value
        SessionTimeline.shared.end()
        stopObserving()
        if videoRecording {
            do { try await recorder.stopRecording(withOutput: directory.appendingPathComponent(Self.videoFile(videoPart))) }
            catch { issue = "The screen recording couldn’t be saved; the event log is kept." }
        }
        let videoFiles = (1...videoPart).map(Self.videoFile).filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        let info = Bundle.main.infoDictionary
        var system = utsname(); uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let meta: [String: Any] = [
            "format": "science-reader-session-1", "app": "Gradstep",
            "version": info?["CFBundleShortVersionString"] as? String ?? "", "build": info?["CFBundleVersion"] as? String ?? "",
            "device": model, "system": UIDevice.current.systemVersion, "idiom": Platform.isMac ? "mac" : UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
            "screen_scale": screen?.scale ?? 0, "started_at": ISO8601DateFormatter().string(from: startedAt ?? Date()),
            "video": !videoFiles.isEmpty, "video_files": videoFiles,
            "voice": !videoFiles.isEmpty && includeVoice,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("meta.json"))
        }
        let zip = package(directory)
        if zip != nil { try? FileManager.default.removeItem(at: directory) }
        self.directory = nil; startedAt = nil; backgroundedAt = nil
        pruneSessions(keeping: 5); refreshSessions()
        if let zip { share = SharedSession(url: zip) } else if issue == nil { issue = "The session couldn’t be packaged." }
        state = .idle
    }

    func delete(_ url: URL) { try? FileManager.default.removeItem(at: url); refreshSessions() }

    /// One zip per session (system zip of the folder), named for the Mac's review script.
    private func package(_ directory: URL) -> URL? {
        let destination = root.appendingPathComponent("gradstep-session-\(directory.lastPathComponent).zip")
        var result: URL?, failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &failure) { zipped in
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: zipped, to: destination)) != nil { result = destination }
        }
        return result
    }

    private func refreshSessions() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        sessions = files.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneSessions(keeping count: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
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
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appEnteredBackground() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
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

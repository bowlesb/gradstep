import Foundation

/// The event log of a test session (docs/SESSION_REVIEW.md), written beside the
/// screen recording so a reviewer can find problems without narration: screen
/// and state changes, touches, errors shown, requests, hangs, keyboard,
/// orientation. Events carry seconds since the session started (monotonic
/// clock) and never paper or chat text. Recording is off unless a session is
/// running; `record` is then a cheap no-op. Lines are appended to disk as they
/// happen so a crash keeps everything before it.
final class SessionTimeline: @unchecked Sendable {
    static let shared = SessionTimeline()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var started: TimeInterval = 0
    private var written = 0
    private static let maximumBytes = 8 * 1024 * 1024

    var isRecording: Bool { lock.withLock { handle != nil } }

    /// Seconds since the session started, or nil when not recording.
    var now: TimeInterval? { lock.withLock { handle == nil ? nil : ProcessInfo.processInfo.systemUptime - started } }

    func begin(at url: URL, metadata: [String: String]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        lock.withLock { handle = file; started = ProcessInfo.processInfo.systemUptime; written = 0 }
        record("start", metadata)
    }

    func end() {
        record("stop", [:])
        lock.withLock { try? handle?.close(); handle = nil }
    }

    func record(_ kind: String, _ fields: [String: String] = [:]) {
        lock.withLock {
            guard let handle, written < Self.maximumBytes else { return }
            var event: [String: String] = fields
            event["kind"] = kind
            event["t"] = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            guard var line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
            line.append(0x0A)
            try? handle.write(contentsOf: line)
            written += line.count
        }
    }

    /// A request's path without its query (queries can carry search text).
    static func describe(path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1).first ?? "")
    }
}

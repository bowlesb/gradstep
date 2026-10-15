import Foundation

/// How one device paces its requests to arXiv's legacy API (docs/architecture/ARXIV_DEVICE_ONLY.md §5.9): the terms ask
/// for no more than one request every three seconds, one connection at a time, and arXiv's robots page treats rapid
/// retries as an attack. Request starts are at least 3 s apart; 429/503 wait Retry-After (at least a minute, doubling,
/// at most a day); a 403 stops every request from this device for 24 hours. A wait longer than a minute is refused
/// rather than held, so the reader is told instead of left waiting. Persisted, so a relaunch keeps the back-off.
public struct ArxivRequestPacer: Codable, Equatable, Sendable {
    public static let spacing: TimeInterval = 3
    public static let refusalPause: TimeInterval = 86_400
    public static let longestWait: TimeInterval = 60

    public private(set) var nextStart: Date
    public private(set) var busyUntil: Date?
    public private(set) var refusedUntil: Date?
    public private(set) var failures: Int

    public init() { nextStart = .distantPast; busyUntil = nil; refusedUntil = nil; failures = 0 }

    /// When the next request may start (and reserves it), or nil when this device must not ask arXiv now.
    public mutating func reserve(now: Date) -> Date? {
        if let refusedUntil, refusedUntil > now { return nil }
        var start = max(now, nextStart)
        if let busyUntil, busyUntil > start { start = busyUntil }
        guard start.timeIntervalSince(now) <= Self.longestWait else { return nil }
        nextStart = start.addingTimeInterval(Self.spacing)
        return start
    }

    /// What arXiv answered (`retryAfter` in seconds when it said).
    public mutating func record(status: Int, retryAfter: TimeInterval?, now: Date) {
        switch status {
        case 403:
            refusedUntil = now.addingTimeInterval(Self.refusalPause)
        case 429, 503:
            failures += 1
            let backoff = min(Self.refusalPause, 60 * pow(2, Double(failures - 1)))
            let delay = min(Self.refusalPause, max(60, retryAfter ?? backoff))
            busyUntil = now.addingTimeInterval(delay)
            nextStart = max(nextStart, busyUntil!)
        case 200..<300:
            failures = 0
        default:
            break
        }
    }

    /// True while a 403 keeps this device from asking.
    public func isRefused(now: Date) -> Bool { refusedUntil.map { $0 > now } ?? false }
}

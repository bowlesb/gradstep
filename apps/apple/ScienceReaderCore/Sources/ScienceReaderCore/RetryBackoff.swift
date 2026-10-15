import Foundation

/// Last-good data shown after a failed refresh says when it is from (docs/architecture/RESILIENCE.md fix 10).
public enum LastGood {
    /// "a minute ago", "12 minutes ago", "14:05" (today), "Oct 14" (earlier).
    public static func phrase(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "a minute ago" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) minutes ago" }
        let format = DateFormatter(); format.locale = locale; format.calendar = calendar
        format.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "jmm" : "MMMd")
        return format.string(from: date)
    }
}

/// Retry timing for every client loop (docs/architecture/RESILIENCE.md): a failing call backs off exponentially with
/// jitter, honours the server's wait, and a healthy poll keeps its cadence with a little jitter, so devices that lost
/// the server together don't come back together.
public enum RetryBackoff {
    /// The wait after `failures` consecutive failures (1 = the first): between half and all of
    /// `min(cap, base × 2^(failures−1))`, never shorter than `retryAfter`.
    public static func delay(failures: Int, base: TimeInterval, cap: TimeInterval, retryAfter: TimeInterval? = nil,
                             random: () -> Double = { Double.random(in: 0...1) }) -> TimeInterval {
        let exponent = Double(min(max(failures, 1) - 1, 16))
        let ceiling = min(cap, base * pow(2, exponent))
        let jittered = ceiling * (0.5 + 0.5 * min(max(random(), 0), 1))
        return max(jittered, min(retryAfter ?? 0, cap * 4))
    }

    /// A healthy cadence spread by ±`spread` (20 % by default).
    public static func jittered(_ seconds: TimeInterval, spread: Double = 0.2, random: () -> Double = { Double.random(in: 0...1) }) -> TimeInterval {
        seconds * (1 - spread + 2 * spread * min(max(random(), 0), 1))
    }

    /// Seconds from a `Retry-After` header (delta-seconds or an HTTP date) or a JSON body's `retry_after`; nil when absent
    /// or nonsensical. Bounded to an hour.
    public static func retryAfter(header: String?, body: Double? = nil, now: Date = Date()) -> TimeInterval? {
        if let body, body.isFinite, body >= 0 { return min(body, 3600) }
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return min(seconds, 3600) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        guard let date = format.date(from: header) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), 3600)
    }
}

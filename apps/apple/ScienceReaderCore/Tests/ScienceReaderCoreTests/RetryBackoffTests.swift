import Foundation
import Testing
@testable import ScienceReaderCore

struct RetryBackoffTests {
    @Test func backsOffExponentiallyWithinHalfToFullOfTheCeiling() {
        #expect(RetryBackoff.delay(failures: 1, base: 2, cap: 300, random: { 0 }) == 1)
        #expect(RetryBackoff.delay(failures: 1, base: 2, cap: 300, random: { 1 }) == 2)
        #expect(RetryBackoff.delay(failures: 4, base: 2, cap: 300, random: { 1 }) == 16)
        #expect(RetryBackoff.delay(failures: 30, base: 2, cap: 300, random: { 1 }) == 300, "capped")
        #expect(RetryBackoff.delay(failures: 30, base: 2, cap: 300, random: { 0 }) == 150, "never all devices at the same instant")
    }

    @Test func honoursTheServersWait() {
        #expect(RetryBackoff.delay(failures: 1, base: 2, cap: 300, retryAfter: 45, random: { 0 }) == 45)
        #expect(RetryBackoff.delay(failures: 1, base: 2, cap: 10, retryAfter: 9_999, random: { 0 }) == 40, "a silly wait is bounded")
    }

    @Test func jitterSpreadsAHealthyCadence() {
        #expect(abs(RetryBackoff.jittered(60, random: { 0 }) - 48) < 1e-9)
        #expect(abs(RetryBackoff.jittered(60, random: { 1 }) - 72) < 1e-9)
    }

    @Test func lastGoodSaysWhenItIsFrom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LastGood.phrase(now.addingTimeInterval(-30), now: now) == "a minute ago")
        #expect(LastGood.phrase(now.addingTimeInterval(-12 * 60), now: now) == "12 minutes ago")
        let earlier = LastGood.phrase(now.addingTimeInterval(-3 * 86_400), now: now, locale: Locale(identifier: "en_US"))
        #expect(earlier.contains("Jan"), "an older copy names its day: \(earlier)")
    }

    @Test func readsRetryAfterAsSecondsADateOrABody() {
        #expect(RetryBackoff.retryAfter(header: "30") == 30)
        #expect(RetryBackoff.retryAfter(header: nil, body: 12) == 12)
        let date = "Thu, 15 Jan 2027 08:00:00 GMT"
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let base = format.date(from: date)!.addingTimeInterval(-20)
        #expect(RetryBackoff.retryAfter(header: date, now: base) == 20)
        #expect(RetryBackoff.retryAfter(header: "soon") == nil)
        #expect(RetryBackoff.retryAfter(header: "99999") == 3600)
    }
}

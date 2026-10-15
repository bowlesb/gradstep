import Foundation
import Testing
@testable import ScienceReaderCore

/// One device's pacing of arXiv's legacy API (docs/architecture/ARXIV_DEVICE_ONLY.md §5.9).
struct ArxivRequestPacerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requestStartsAreThreeSecondsApart() {
        var pacer = ArxivRequestPacer()
        #expect(pacer.reserve(now: t0) == t0)
        #expect(pacer.reserve(now: t0) == t0.addingTimeInterval(3))
        #expect(pacer.reserve(now: t0.addingTimeInterval(1)) == t0.addingTimeInterval(6))
        // Long after, the next one starts at once.
        #expect(pacer.reserve(now: t0.addingTimeInterval(100)) == t0.addingTimeInterval(100))
    }

    @Test func aRefusalStopsEveryRequestForADay() {
        var pacer = ArxivRequestPacer()
        _ = pacer.reserve(now: t0)
        pacer.record(status: 403, retryAfter: nil, now: t0)
        #expect(pacer.isRefused(now: t0.addingTimeInterval(3600)))
        #expect(pacer.reserve(now: t0.addingTimeInterval(86_399)) == nil)
        #expect(pacer.reserve(now: t0.addingTimeInterval(86_401)) == t0.addingTimeInterval(86_401))
    }

    @Test func busyAnswersWaitAsAskedAtLeastAMinuteAndDouble() {
        var pacer = ArxivRequestPacer()
        _ = pacer.reserve(now: t0)
        pacer.record(status: 429, retryAfter: 30, now: t0)
        #expect(pacer.busyUntil == t0.addingTimeInterval(60), "never sooner than a minute")
        // Within the longest wait the request is scheduled after the pause; a longer wait is refused, not held.
        #expect(pacer.reserve(now: t0.addingTimeInterval(10)) == t0.addingTimeInterval(60))
        pacer.record(status: 503, retryAfter: nil, now: t0.addingTimeInterval(60))
        #expect(pacer.busyUntil == t0.addingTimeInterval(180), "doubling without Retry-After")
        #expect(pacer.reserve(now: t0.addingTimeInterval(61)) == nil)
        pacer.record(status: 429, retryAfter: 1e9, now: t0)
        #expect(pacer.busyUntil == t0.addingTimeInterval(86_400), "at most a day")
        pacer.record(status: 200, retryAfter: nil, now: t0)
        #expect(pacer.failures == 0)
    }

    @Test func itSurvivesARelaunch() throws {
        var pacer = ArxivRequestPacer()
        _ = pacer.reserve(now: t0)
        pacer.record(status: 403, retryAfter: nil, now: t0)
        let restored = try JSONDecoder().decode(ArxivRequestPacer.self, from: JSONEncoder().encode(pacer))
        #expect(restored == pacer)
        #expect(restored.isRefused(now: t0.addingTimeInterval(1)))
    }

    @Test func theCapabilityIsReadWhenPresentAndOffOtherwise() throws {
        let account = UUID()
        func capabilities(_ extra: String) throws -> ReaderCapabilities {
            let json = """
            {"format":1,"account_id":"\(account.uuidString.lowercased())","library":{"endpoint_family":"full-v5","wire_format":2,"source_level":4,
             "dataset_epoch":"\(UUID().uuidString.lowercased())"},"descriptors":{"format":1,"maximum_batch":24},
             "uploads":{"protocol":"upload-chunks-v1","enabled":false,"chunk_bytes":4194304,"maximum_bytes":67108864,"maximum_parts":16,"part_attempts":2}\(extra)}
            """
            return try ReaderCapabilities.decode(Data(json.utf8), accountID: account)
        }
        #expect(try !capabilities("").submitsSourceMetadata, "an older server says nothing: off")
        #expect(try !capabilities(#","source_metadata":{"enabled":false,"format":"arxiv-source-metadata-v1"}"#).submitsSourceMetadata)
        #expect(try capabilities(#","source_metadata":{"enabled":true,"format":"arxiv-source-metadata-v1"}"#).submitsSourceMetadata)
        #expect(try !capabilities(#","source_metadata":{"enabled":true,"format":"arxiv-source-metadata-v2"}"#).submitsSourceMetadata, "an unknown format: off")
    }
}

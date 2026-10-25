import Foundation
import Testing
@testable import ScienceReaderCore

/// The Feed's last page per view, kept on the device across launches (owner, 2026-10-25): sealed per account, bounded,
/// expired after 14 days unopened, and erased on sign-out.
@Suite struct FeedPageStoreTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func result(_ id: String, title: String = "Verifier-Guided GRPO Scales Mathematical Reasoning", abstract: String? = nil,
                        reason: Bool = true) throws -> DiscoveryResult {
        var row: [String: Any] = ["source_id": id, "revision": 2, "title": title, "authors": ["Sara Okafor", "Peter Lindqvist"],
                                  "year": 2026, "categories": ["cs.LG"], "topics": ["Policy optimization"], "upvotes": 87]
        let text = abstract ?? "Process verifiers shape group-relative policy optimization rewards."
        row[text.count > 2_000 ? "full_abstract" : "abstract"] = text
        if reason { row["reason"] = ["kind": "added", "label": "DeepSeekMath", "text": "Because you added “DeepSeekMath”"] }
        return try JSONDecoder().decode(DiscoveryResult.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private func page(_ view: String, _ ids: [String], opened: Date? = nil, fetched: Date? = nil) throws -> FeedKeptPage {
        FeedKeptPage(view: view, fetchedAt: fetched ?? now.addingTimeInterval(-7_200), openedAt: opened ?? now, results: try ids.map { try result($0) })
    }

    @Test func aResultRoundTripsThroughItsWireForm() throws {
        let long = String(repeating: "A long abstract that the server sent whole. ", count: 60)
        for original in [try result("2610.07767"), try result("2610.07768", abstract: long), try result("2610.07769", reason: false)] {
            let decoded = try JSONDecoder().decode(DiscoveryResult.self, from: ReaderCrypto.encode(original))
            #expect(decoded == original)
        }
    }

    @Test func pagesRoundTripSealedAndBoundToTheAccount() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = ReaderCrypto.randomKey()
        let saved = ["for_you": try page("for_you", ["2610.07767", "2610.05030"]),
                     "topic:Tokenization": try page("topic:Tokenization", ["2610.03543"], opened: now.addingTimeInterval(-60))]
        try await FeedPageStore(directory: directory, accountID: account, localKey: key).save(saved, now: now)

        let disk = try Data(contentsOf: directory.appendingPathComponent(FeedPageStore.fileName))
        #expect(disk.range(of: Data("Verifier-Guided".utf8)) == nil, "No plaintext titles on disk")
        #expect(disk.range(of: Data("2610.07767".utf8)) == nil)
        #expect(disk.range(of: Data("Tokenization".utf8)) == nil, "nor the reader's topics")

        #expect(try await FeedPageStore(directory: directory, accountID: account, localKey: key).load(now: now) == saved)
        // Another account, or another local key, reads nothing rather than another account's Feed.
        #expect(try await FeedPageStore(directory: directory, accountID: UUID(), localKey: key).load(now: now).isEmpty)
        #expect(try await FeedPageStore(directory: directory, accountID: account, localKey: ReaderCrypto.randomKey()).load(now: now).isEmpty)
        #expect(throws: (any Error).self) { try FeedPageStore(directory: directory, accountID: account, localKey: Data(count: 16)) }
    }

    @Test func eachViewKeepsOnlyItsLastPageAndTheWholeIsBounded() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedPageStore(directory: directory, accountID: UUID(), localKey: ReaderCrypto.randomKey())
        // The newest page of a view replaces the one before (one entry per view).
        try await store.save(["for_you": try page("for_you", ["2610.07767"])], now: now)
        try await store.save(["for_you": try page("for_you", ["2610.05030"])], now: now)
        #expect(await store.load(now: now)["for_you"]?.results.map(\.sourceID) == ["2610.05030"])

        // At most 16 views: the least recently opened go first.
        var many: [String: FeedKeptPage] = [:]
        for index in 0..<(FeedPageStore.maximumViews + 4) {
            let view = "category:cs.\(index)"
            many[view] = try page(view, ["2610.0\(1000 + index)"], opened: now.addingTimeInterval(-Double(index) * 60))
        }
        let kept = try await store.save(many, now: now)
        #expect(kept.count == FeedPageStore.maximumViews)
        #expect(kept["category:cs.0"] != nil && kept["category:cs.\(FeedPageStore.maximumViews)"] == nil)
        #expect(await store.load(now: now).count == FeedPageStore.maximumViews)

        // At most 50 papers a view; and a view whose page doesn't fit in 4 MB is dropped whole, the most recent kept.
        let fifty = try (0..<60).map { try result(String(format: "2610.%05d", $0 + 10_000)) }
        let wide = FeedKeptPage(view: "for_you", fetchedAt: now, openedAt: now, results: Array(fifty.prefix(50)))
        #expect(try FeedPageStore.bounded([wide], now: now).first?.results.count == 50)
        await #expect(throws: (any Error).self) {
            try await store.save(["for_you": FeedKeptPage(view: "for_you", fetchedAt: now, openedAt: now, results: fifty)], now: now)
        }
        let huge = String(repeating: "x", count: 23_000)
        let heavy = try (0..<50).map { try result(String(format: "2610.%05d", $0 + 10_000), abstract: huge) }
        var pages: [String: FeedKeptPage] = [:]
        for index in 0..<6 {
            pages["topic:T\(index)"] = FeedKeptPage(view: "topic:T\(index)", fetchedAt: now, openedAt: now.addingTimeInterval(-Double(index)), results: heavy)
        }
        let fitted = try await store.save(pages, now: now)
        #expect(!fitted.isEmpty && fitted.count < 6, "about 1.2 MB a view: three fit")
        #expect(fitted["topic:T0"] != nil, "the most recently opened view is kept")
        let bytes = try Data(contentsOf: directory.appendingPathComponent(FeedPageStore.fileName)).count
        #expect(bytes <= FeedPageStore.maximumBytes + 64)
    }

    @Test func aViewNotOpenedForFourteenDaysIsDropped() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedPageStore(directory: directory, accountID: UUID(), localKey: ReaderCrypto.randomKey())
        let day: TimeInterval = 86_400
        try await store.save(["for_you": try page("for_you", ["2610.07767"], opened: now.addingTimeInterval(-13 * day), fetched: now.addingTimeInterval(-20 * day)),
                              "category:cs.LG": try page("category:cs.LG", ["2610.05030"], opened: now.addingTimeInterval(-15 * day))], now: now)
        let kept = await store.load(now: now)
        #expect(Set(kept.keys) == ["for_you"], "opened 13 days ago stays however old its papers; 15 days unopened goes")
        #expect(await store.load(now: now.addingTimeInterval(2 * day)).isEmpty, "and For you goes too once 14 days pass unopened")
        // Nothing left to keep removes the file.
        try await store.save([:], now: now)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(FeedPageStore.fileName).path))
    }

    @Test func signOutErasesThePagesAndACorruptFileStartsEmpty() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID(), key = ReaderCrypto.randomKey()
        let store = try FeedPageStore(directory: directory, accountID: account, localKey: key)
        try await store.save(["for_you": try page("for_you", ["2610.07767"])], now: now)
        let url = directory.appendingPathComponent(FeedPageStore.fileName)
        var bytes = try Data(contentsOf: url); bytes[bytes.count - 1] ^= 1; try bytes.write(to: url)
        #expect(await store.load(now: now).isEmpty, "a damaged file is forgotten, not an error")
        try await store.save(["for_you": try page("for_you", ["2610.05030"])], now: now)
        #expect(await store.load(now: now)["for_you"]?.results.first?.sourceID == "2610.05030", "and replaced by the next save")
        await store.erase()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await FeedPageStore(directory: directory, accountID: account, localKey: key).load(now: now).isEmpty)
        // A page whose key isn't its view, or an empty page, is never written.
        await #expect(throws: (any Error).self) { try await store.save(["for_you": try page("topic:x", ["2610.05030"])], now: now) }
        await #expect(throws: (any Error).self) { try await store.save(["for_you": try page("for_you", [])], now: now) }
    }

    @Test func theOfflineLineSaysHowLongAgo() {
        #expect(LastGood.ago(now.addingTimeInterval(-30), now: now) == "a minute ago")
        #expect(LastGood.ago(now.addingTimeInterval(-12 * 60), now: now) == "12 minutes ago")
        #expect(LastGood.ago(now.addingTimeInterval(-59.6 * 60), now: now) == "an hour ago")
        #expect(LastGood.ago(now.addingTimeInterval(-2 * 3_600), now: now) == "2 hours ago")
        #expect(LastGood.ago(now.addingTimeInterval(-23.6 * 3_600), now: now) == "a day ago")
        #expect(LastGood.ago(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days ago")
        #expect(LastGood.ago(now.addingTimeInterval(60), now: now) == "a minute ago", "a clock that moved back")
    }
}

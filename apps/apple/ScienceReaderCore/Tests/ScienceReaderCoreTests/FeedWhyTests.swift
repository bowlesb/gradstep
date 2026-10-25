import Foundation
import XCTest
@testable import ScienceReaderCore

/// The Feed by why each paper is suggested (owner, 2026-10-24: "Let's try having a column in Table for the reason and
/// having grouped lists in list view"): the Why column's labels, the order by why (the List's and the Why sort's) and the
/// ⓘ texts. The List's group headings went after TestFlight 92 (JUDGMENT_LOG 30).
final class FeedWhyTests: XCTestCase {
    private func results(_ reasons: [(String, String, String)?]) throws -> [DiscoveryResult] {
        let rows = reasons.enumerated().map { index, reason -> [String: Any] in
            var row: [String: Any] = ["source_id": String(format: "2610.%05d", index + 1), "revision": 1, "title": "Paper \(index + 1)",
                                      "authors": ["Mei Lin"], "categories": ["cs.LG"]]
            if let reason { row["reason"] = ["kind": reason.0, "label": reason.1, "text": reason.2] }
            return row
        }
        let body = try JSONSerialization.data(withJSONObject: ["results": rows])
        return try JSONDecoder().decode(DiscoveryResponse.self, from: body).results
    }

    private func reason(_ kind: String, _ label: String, _ text: String) throws -> FeedReason {
        try XCTUnwrap(results([(kind, label, text)]).first?.reason)
    }

    private let muffin = "Muffin – A Shared Memory Architecture for Long-Horizon Agents"

    func testWhyColumnLabels() throws {
        XCTAssertEqual(try reason("tag", "RLHF", "In your tag: RLHF").shortLabel, "Your tag: RLHF")
        XCTAssertEqual(try reason("added", muffin, "Because you added “Muffin…”").shortLabel, "Like: Muffin – A Shared Memory…")
        XCTAssertEqual(try reason("more_like", "Mamba", "More like “Mamba”").shortLabel, "Like: Mamba")
        XCTAssertEqual(try reason("author", "Tri Dao", "By Tri Dao, an author in your library").shortLabel, "Author: Tri Dao")
        // Owner, TestFlight 91: "Popular ▲ 232" and "Category: cs.LG" made no sense; they say what they mean.
        XCTAssertEqual(try reason("trending", "48", "Popular on Hugging Face Papers").shortLabel, "Popular: 48 upvotes")
        XCTAssertEqual(try reason("trending", "1", "Popular on Hugging Face Papers").shortLabel, "Popular: 1 upvote")
        XCTAssertEqual(try reason("trending", "many", "Popular on Hugging Face Papers").shortLabel, "Popular")
        XCTAssertEqual(try reason("popular", "3", "Added by several readers this week").shortLabel, "Readers are adding")
        XCTAssertEqual(try reason("category", "cs.CL", "New in Natural language processing").shortLabel, "New in Natural language processing")
        XCTAssertEqual(try reason("category", "cs.LG", "New in Machine learning").shortLabel, "New in Machine learning")
        XCTAssertEqual(try reason("explore", "cs.RO", "Something different: Robotics").shortLabel, "Explore")
        XCTAssertEqual(try reason("future_kind", "x", "A reason from a later server").shortLabel, "A reason from a later server",
                       "an unknown kind shows the server's sentence")
        XCTAssertEqual(try reason("added", "Mamba", "x").group, .like)
        XCTAssertEqual(try reason("trending", "1", "x").group, .popular)
        XCTAssertEqual(try reason("future_kind", "x", "y").group, .other)
    }

    /// The Why column never shows a raw arXiv code (owner, TestFlight 91: "What does that even mean category CSLG?"): the
    /// server's name, else the app's own name for the code, else the code.
    func testCategoryReasonsUseTheReadersName() throws {
        XCTAssertEqual(try reason("category", "stat.ML", "A later wording").shortLabel, "New in Machine learning",
                       "a sentence without the prefix: the app's name for the code")
        XCTAssertEqual(try reason("category", "cs.AI", "New in ").shortLabel, "New in Artificial intelligence")
        XCTAssertEqual(try reason("category", "q-bio.XX", "A later wording").shortLabel, "New in q-bio.XX", "an unknown code stays")
        XCTAssertEqual(try reason("category", "", "A later wording").shortLabel, "New in a field you read")
        XCTAssertFalse(try reason("category", "cs.LG", "New in Machine learning").shortLabel.contains("cs."))
    }

    /// The ⓘ beside the Why column's header: what each label means, popularity's ▲ included.
    func testTheInfoExplainsEveryReasonAndTheUpvotes() {
        let info = FeedWhy.info
        for words in ["Your tag", "Like", "Author", "Popular", "Hugging Face Papers", "▲", "Readers are adding",
                      "New in", "Explore"] {
            XCTAssertTrue(info.contains(words), "the ⓘ explains \(words): \(info)")
        }
        XCTAssertFalse(info.contains("cs."), "no arXiv codes")
    }

    /// Feed ⋯ › About For you: how each of the server's why sentences starts, and what it means, in the List's order.
    func testAboutForYouExplainsEveryWhyLineInTheListsOrder() {
        let about = FeedWhy.aboutForYou
        let starts = ["In your tag", "Like “…”", "Because you added", "More like", "By …", "Popular on Hugging Face Papers", "▲",
                      "Added by several readers", "New in", "Something different"]
        for words in starts { XCTAssertTrue(about.contains(words), "About For you explains \(words): \(about)") }
        let order = ["In your tag", "Like “…”", "By …", "Popular on", "New in", "Something different"]
            .map { about.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted(), "in the List's order")
        XCTAssertFalse(about.contains("cs."), "no arXiv codes")
        XCTAssertFalse(about.contains("Like papers you added"), "not the heading the owner found redundant")
    }

    func testShortTitlesCutAtAWord() {
        XCTAssertEqual(FeedWhy.shortTitle("Mamba", limit: 28), "Mamba")
        XCTAssertEqual(FeedWhy.shortTitle("  Direct   Preference\nOptimization ", limit: 60), "Direct Preference Optimization")
        XCTAssertEqual(FeedWhy.shortTitle(muffin, limit: 28), "Muffin – A Shared Memory…")
        XCTAssertLessThanOrEqual(FeedWhy.shortTitle(String(repeating: "x", count: 80), limit: 28).count, 28)
    }

    /// The List, and sorting by Why, group rows (tags, like papers, authors, popular, category, explore; no reason
    /// last), keeping the server's order within each group; reversed, the groups reverse and no reason stays last.
    func testWhyOrderGroupsAndKeepsTheServersOrder() throws {
        let rows = try results([
            ("explore", "cs.RO", "Something different: Robotics"),   // 1
            ("author", "Tri Dao", "By Tri Dao, an author in your library"), // 2
            ("tag", "RLHF", "In your tag: RLHF"),                     // 3
            nil,                                                      // 4
            ("added", muffin, "Because you added “Muffin…”"),          // 5
            ("tag", "SSMs", "In your tag: SSMs"),                     // 6
            ("trending", "48", "Popular on Hugging Face Papers"),     // 7
            ("tag", "rlhf", "In your tag: rlhf"),                     // 8
            ("category", "cs.CL", "New in Natural language processing"), // 9
            ("more_like", "Mamba", "More like “Mamba”"),               // 10
            ("popular", "3", "Added by several readers this week"),   // 11
        ])
        let ids = { (list: [DiscoveryResult]) in list.map { Int($0.sourceID.suffix(5))! } }
        XCTAssertEqual(ids(FeedWhy.ordered(rows)), [3, 8, 6, 5, 10, 2, 7, 11, 9, 1, 4])
        XCTAssertEqual(ids(FeedWhy.ordered(rows, ascending: false)), [1, 9, 7, 11, 2, 5, 10, 6, 3, 8, 4])
    }
}

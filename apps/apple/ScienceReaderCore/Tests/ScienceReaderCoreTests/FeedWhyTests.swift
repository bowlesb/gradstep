import Foundation
import XCTest
@testable import ScienceReaderCore

/// The Feed grouped by why each paper is suggested (owner, 2026-10-24: "Let's try having a column in Table for the reason
/// and having grouped lists in list view"): the Why column's labels and order, the List's sections, their merge rule
/// and the rows' trimmed why lines.
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

    /// The ⓘ beside the Why column's header and on the List's headers: what each reason means, popularity's ▲ included.
    func testTheInfoExplainsEveryReasonAndTheUpvotes() {
        let info = FeedWhy.info
        for words in ["Your tag", "Like", "Author", "Popular", "Hugging Face Papers", "▲", "Readers are adding",
                      "New in", "Explore"] {
            XCTAssertTrue(info.contains(words), "the ⓘ explains \(words): \(info)")
        }
        XCTAssertFalse(info.contains("cs."), "no arXiv codes")
        for group in FeedWhyGroup.allCases {
            XCTAssertFalse(group.explanation.isEmpty, "\(group) explains itself")
        }
        XCTAssertTrue(FeedWhyGroup.popular.explanation.contains("Hugging Face Papers"))
        XCTAssertTrue(FeedWhyGroup.category.explanation.contains("arXiv"))
    }

    func testShortTitlesCutAtAWord() {
        XCTAssertEqual(FeedWhy.shortTitle("Mamba", limit: 28), "Mamba")
        XCTAssertEqual(FeedWhy.shortTitle("  Direct   Preference\nOptimization ", limit: 60), "Direct Preference Optimization")
        XCTAssertEqual(FeedWhy.shortTitle(muffin, limit: 28), "Muffin – A Shared Memory…")
        XCTAssertLessThanOrEqual(FeedWhy.shortTitle(String(repeating: "x", count: 80), limit: 28).count, 28)
    }

    /// Sorting by Why groups rows (tags, like papers, authors, popular, category, explore; no reason last) and keeps the
    /// server's order within each group; reversed, the groups reverse and no reason stays last.
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

    func testSectionsFollowTheGroupsOrderAndTheServersOrderWithin() throws {
        let rows = try results([
            ("author", "Tri Dao", "By Tri Dao, an author in your library"), // 1
            ("tag", "RLHF", "In your tag: RLHF"),                         // 2
            ("added", muffin, "Because you added “Muffin…”"),              // 3
            ("tag", "RLHF", "In your tag: RLHF"),                         // 4
            ("explore", "cs.RO", "Something different: Robotics"),        // 5
            ("trending", "48", "Popular on Hugging Face Papers"),         // 6
            ("tag", "SSMs", "In your tag: SSMs"),                         // 7
            ("popular", "3", "Added by several readers this week"),       // 8
            ("category", "cs.CL", "New in Natural language processing"),  // 9
            ("tag", "SSMs", "In your tag: SSMs"),                         // 10
            ("more_like", "Mamba", "More like “Mamba”"),                   // 11
        ])
        let sections = try XCTUnwrap(FeedWhy.sections(rows))
        XCTAssertEqual(sections.map(\.title), ["RLHF", "SSMs", "Like papers you added", "From authors you read", "Popular this week",
                                               "By category", "Something different"])
        XCTAssertEqual(sections.map { $0.results.map { Int($0.sourceID.suffix(5))! } }, [[2, 4], [7, 10], [3, 11], [1], [6, 8], [9], [5]])
        XCTAssertEqual(sections.reduce(0) { $0 + $1.results.count }, rows.count, "every paper once")
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
    }

    /// Two or more tags with one paper each share one "Your tags" section after the tags with several; one keeps its name.
    func testOnePaperTagsMerge() throws {
        let rows = try results([
            ("tag", "Tokenization", "In your tag: Tokenization"), // 1
            ("tag", "RLHF", "In your tag: RLHF"),                 // 2
            ("tag", "SSMs", "In your tag: SSMs"),                 // 3
            ("tag", "RLHF", "In your tag: RLHF"),                 // 4
            ("author", "Tri Dao", "By Tri Dao"),                  // 5
        ])
        let sections = try XCTUnwrap(FeedWhy.sections(rows))
        XCTAssertEqual(sections.map(\.title), ["RLHF", "Your tags", "From authors you read"])
        XCTAssertEqual(sections[1].results.map(\.sourceID), ["2610.00001", "2610.00003"])
        XCTAssertNil(sections[1].tag)
        let one = try XCTUnwrap(FeedWhy.sections(results([("tag", "RLHF", "In your tag: RLHF"), ("author", "Tri Dao", "By Tri Dao")])))
        XCTAssertEqual(one.map(\.title), ["RLHF", "From authors you read"], "a single one-paper tag keeps its name")
    }

    /// One kind of reason (a category chip's papers, or none at all): no headers.
    func testOneReasonShowsNoHeaders() throws {
        XCTAssertNil(FeedWhy.sections(try results([nil, nil, nil])))
        XCTAssertNil(FeedWhy.sections(try results([("category", "cs.CL", "New in NLP"), ("category", "cs.LG", "New in Machine learning")])))
        XCTAssertNil(FeedWhy.sections(try results([("trending", "48", "x"), ("popular", "3", "y")])), "popular and trending are one section")
        XCTAssertNil(FeedWhy.sections(try results([("tag", "RLHF", "In your tag: RLHF"), ("tag", "rlhf", "In your tag: rlhf")])))
        XCTAssertNil(FeedWhy.sections([]))
        XCTAssertNil(FeedWhy.sections(try results([("tag", "RLHF", "x"), ("tag", "SSMs", "y")])), "two one-paper tags are one section")
        XCTAssertNotNil(FeedWhy.sections(try results([("tag", "RLHF", "x"), ("tag", "SSMs", "y"), ("tag", "RLHF", "x")])))
    }

    /// A row's why line drops what its header says and keeps the specific anchor.
    func testRowLinesDropWhatTheHeaderSays() throws {
        let rows = try results([
            ("tag", "RLHF", "In your tag: RLHF"), ("tag", "RLHF", "In your tag: RLHF"),
            ("tag", "SSMs", "In your tag: SSMs"), ("tag", "Tokenization", "In your tag: Tokenization"),
            ("added", muffin, "Because you added “Muffin…”"), ("more_like", "Mamba", "More like “Mamba”"),
            ("author", "Tri Dao", "By Tri Dao, an author in your library"),
            ("trending", "48", "Popular on Hugging Face Papers"), ("popular", "3", "Added by several readers this week"),
            ("category", "cs.CL", "New in Natural language processing"), ("explore", "cs.RO", "Something different: Robotics"),
        ])
        let sections = try XCTUnwrap(FeedWhy.sections(rows))
        func line(_ index: Int) -> String? {
            let result = rows[index]
            let section = sections.first { $0.results.contains(result) }!
            return FeedWhy.line(result.reason!, in: section)
        }
        XCTAssertNil(line(0), "under “RLHF”, not “In your tag: RLHF” again")
        XCTAssertEqual(line(2), "SSMs", "under “Your tags”, which tag")
        XCTAssertEqual(line(4), "Like “Muffin – A Shared Memory Architecture for Long-Horizon…”")
        XCTAssertEqual(line(5), "More like “Mamba”")
        XCTAssertEqual(line(6), "By Tri Dao")
        XCTAssertEqual(line(7), "On Hugging Face Papers")
        XCTAssertEqual(line(8), "Added by several readers")
        XCTAssertEqual(line(9), "Natural language processing")
        XCTAssertEqual(line(10), "Robotics")
    }
}

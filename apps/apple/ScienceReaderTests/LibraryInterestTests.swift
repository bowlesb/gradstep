import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// The Library's topics in the app (interest index step 3): which papers have a public key, the keywords the term layer
/// adds to a paper's shown keywords, and the topic filter.
@MainActor
final class LibraryInterestTests: XCTestCase {
    private func paper(_ source: String?, title: String = "KV cache compression for long-context decoding", local: Bool = false) -> Paper {
        var paper = Paper(id: UUID(), title: title, authors: "", year: 2026, abstract: "", keywords: [], fileURL: nil, artifactID: nil)
        paper.sourceID = source; paper.isLocalPDF = local
        return paper
    }

    func testOnlyPublicPapersHaveAnInterestKey() {
        XCTAssertEqual(ReaderModel.interestKey(paper("2610.08811")), "2610.08811")
        XCTAssertEqual(ReaderModel.interestKey(paper("openalex:W1234567890")), "openalex:W1234567890")
        XCTAssertNil(ReaderModel.interestKey(paper("upload:" + UUID().uuidString.lowercased())), "Uploads have no public fingerprint")
        XCTAssertNil(ReaderModel.interestKey(paper("local:" + UUID().uuidString.lowercased(), local: true)), "Device PDFs neither")
        XCTAssertNil(ReaderModel.interestKey(paper(nil)))
    }

    func testTermLayerKeywordsComeFirstThenTheVocabulary() {
        let p = paper("2610.08811", title: "Sparse attention and mixture of experts")
        let before = LibraryTags.tags(for: p)
        defer { _ = InterestKeywordStore.shared.replace([:]) }
        XCTAssertTrue(InterestKeywordStore.shared.replace([p.id: ["KV cache compression", "Decoding throughput", "Sparse attention"]]))
        let after = LibraryTags.tags(for: p)
        XCTAssertEqual(Array(after.prefix(3)), ["KV cache compression", "Decoding throughput", "Sparse attention"])
        XCTAssertEqual(Set(after.map { $0.lowercased() }).count, after.count, "No duplicates")
        XCTAssertLessThanOrEqual(after.count, 6)
        XCTAssertTrue(after.dropFirst(3).allSatisfy { before.contains($0) }, "Then the vocabulary's names")
        // The reader's own tags win.
        var own = p; own.tagsCustomized = true; own.tags = ["Reading group"]
        XCTAssertEqual(LibraryTags.tags(for: own), ["Reading group"])
    }

    func testTopicFilterTogglesAndClearsWithOtherFilters() {
        let model = ReaderModel(configuration: nil)
        let slice = InterestTopicSlice(id: 205, label: "KV Cache Compression", computedLabel: "KV Cache Compression", renamed: false,
                                       papers: [UUID()], share: 0.2, colour: 0, hidden: false, terms: ["kv cache compression"])
        model.toggleTopicFilter(slice)
        XCTAssertEqual(model.libraryTopicFilter?.id, 205)
        XCTAssertTrue(model.libraryFiltered)
        model.toggleTopicFilter(slice)
        XCTAssertNil(model.libraryTopicFilter, "The same topic again shows everything")
        model.toggleTopicFilter(slice)
        model.showLibraryPapers(taggedWith: "RLHF")
        XCTAssertNil(model.libraryTopicFilter, "A tag filter replaces it")
        model.toggleTopicFilter(slice)
        XCTAssertNil(model.libraryTagFilter, "and the other way round")
        model.searchPapers("sparse attention")
        XCTAssertNil(model.libraryTopicFilter, "A search starts from the whole library")
    }
}

import Foundation
import ScienceReaderCore

/// The order of the Library's arXiv search results (owner feedback, build 16 #2: "recent articles should be shown
/// first"). The server ranks by relevance (with citations); Newest re-sorts that list on the device by when each paper
/// was first submitted, read from its arXiv identifier (`2310.12036` = October 2023, number 12036), so papers from
/// the same month keep arXiv's own order. Ties keep the server's relevance order.
enum DiscoveryOrder: String, CaseIterable, Identifiable, Sendable {
    case newest, relevance
    var id: Self { self }
    var title: String { self == .newest ? "Newest" : "Relevance" }

    func ordered(_ results: [DiscoveryResult]) -> [DiscoveryResult] {
        guard self == .newest else { return results }
        return results.enumerated()
            .sorted { lhs, rhs in
                let left = Self.submissionKey(lhs.element), right = Self.submissionKey(rhs.element)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Larger is newer: year, month and the identifier's sequence number; the year alone for an identifier that
    /// can't be read; 0 when neither is known (those go last).
    static func submissionKey(_ result: DiscoveryResult) -> Int64 {
        if let key = submissionKey(sourceID: result.sourceID) { return key }
        return result.year.map { Int64($0) * 100 * 1_000_000 } ?? 0
    }

    /// `YYMM.NNNNN` (2007 on) or `archive/YYMMNNN` (before 2007).
    static func submissionKey(sourceID: String) -> Int64? {
        let modern = sourceID.split(separator: ".", omittingEmptySubsequences: false)
        if modern.count == 2, modern[0].count == 4, let prefix = Int(modern[0]), let number = Int(modern[1]) {
            let year = 2000 + prefix / 100, month = prefix % 100
            guard (1...12).contains(month) else { return nil }
            return Int64(year * 100 + month) * 1_000_000 + Int64(number)
        }
        if let slash = sourceID.lastIndex(of: "/") {
            let digits = sourceID[sourceID.index(after: slash)...]
            guard digits.count == 7, let value = Int(digits) else { return nil }
            let twoDigitYear = value / 100_000, month = value / 1_000 % 100, number = value % 1_000
            guard (1...12).contains(month) else { return nil }
            let year = twoDigitYear >= 91 ? 1900 + twoDigitYear : 2000 + twoDigitYear
            return Int64(year * 100 + month) * 1_000_000 + Int64(number)
        }
        return nil
    }
}

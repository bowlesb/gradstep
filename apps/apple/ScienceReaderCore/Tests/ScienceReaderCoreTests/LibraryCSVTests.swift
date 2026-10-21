import Foundation
import Testing
@testable import ScienceReaderCore

/// Build 75 (ACLs): a catalog saved as CSV. The browser checks the same shared file.
@Suite struct LibraryCSVTests {
    private struct Fixture: Decodable {
        struct Row: Decodable {
            let title: String; let authors: [String]; let year: Int?; let arxivID: String?; let doi: String?
            let link: String?; let tags: [String]; let added: String?
        }
        let columns: [String]
        let rows: [Row]
        let csv: String
    }

    private func fixture() throws -> Fixture {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("tests/fixtures/library-csv/catalog.json")))
    }

    @Test func matchesTheSharedFixtureByteForByte() throws {
        let shared = try fixture()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let rows = shared.rows.map { row in
            LibraryCSV.Row(title: row.title, authors: row.authors, year: row.year, arxivID: row.arxivID, doi: row.doi, link: row.link,
                           tags: row.tags, added: row.added.flatMap { iso.date(from: $0) ?? plain.date(from: $0) })
        }
        #expect(LibraryCSV.columns == shared.columns)
        #expect(LibraryCSV.document(rows) == shared.csv)
        #expect(LibraryCSV.data(rows) == Data(shared.csv.utf8))
    }

    @Test func fileNamesAreSafe() {
        #expect(LibraryCSV.fileName("Reading list") == "Reading list.csv")
        #expect(LibraryCSV.fileName("a/b:c\n") == "a b c.csv")
        #expect(LibraryCSV.fileName(" .. ") == "Catalog.csv")
        #expect(LibraryCSV.fileName(String(repeating: "x", count: 200)).count == 84)
    }
}

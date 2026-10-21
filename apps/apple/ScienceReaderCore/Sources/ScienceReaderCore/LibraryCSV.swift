import Foundation

/// A catalog as a spreadsheet (owner, build 75: "an option to save the entire catalog as csv"). Built on the device
/// from what the Library already shows; nothing is sent anywhere until the reader shares or saves the file. The
/// browser's `lib/library-csv.ts` writes the same bytes; both are checked against `tests/fixtures/library-csv/catalog.json`.
public enum LibraryCSV {
    public struct Row: Equatable, Sendable {
        public var title: String
        public var authors: [String]
        public var year: Int?
        /// The arXiv identifier with its version ("2305.18290v3"), when the paper is an arXiv paper.
        public var arxivID: String?
        public var doi: String?
        public var link: String?
        public var tags: [String]
        public var added: Date?
        public init(title: String, authors: [String], year: Int?, arxivID: String?, doi: String?, link: String?, tags: [String], added: Date?) {
            self.title = title; self.authors = authors; self.year = year; self.arxivID = arxivID; self.doi = doi
            self.link = link; self.tags = tags; self.added = added
        }
    }

    public static let columns = ["Title", "Authors", "Year", "arXiv ID", "DOI", "Link", "Tags", "Added"]

    /// UTF-8 with a byte-order mark (so spreadsheets read accents and other scripts), CRLF line ends, RFC 4180 quoting.
    public static func document(_ rows: [Row]) -> String {
        var lines = [columns.map(cell).joined(separator: ",")]
        for row in rows {
            lines.append([row.title, row.authors.joined(separator: "; "), row.year.map(String.init) ?? "", row.arxivID ?? "",
                          row.doi ?? "", row.link ?? "", row.tags.joined(separator: "; "), row.added.map(day) ?? ""]
                .map(cell).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.map { $0 + "\r\n" }.joined()
    }

    public static func data(_ rows: [Row]) -> Data { Data(document(rows).utf8) }

    /// A file name from the catalog's name: no path separators or control characters, at most 80 characters.
    public static func fileName(_ catalog: String) -> String {
        let cleaned = catalog.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:*?\"<>|".unicodeScalars.contains(scalar) ? " " : String(scalar)
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(80))
        return (name.isEmpty ? "Catalog" : name) + ".csv"
    }

    /// A spreadsheet runs a cell that starts with = + - @ (or a tab or return) as a formula: an apostrophe keeps it text.
    static func cell(_ value: String) -> String {
        var text = value
        if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { text = "'" + text }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The day the paper was added, in UTC (the same day on every device).
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

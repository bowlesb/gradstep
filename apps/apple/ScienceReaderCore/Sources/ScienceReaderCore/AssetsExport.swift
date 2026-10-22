import Foundation
import zlib

/// Download your assets (owner, build 82: "Need a download assets button"): the reader's own content as one .zip, put
/// together on this device from what it holds or can decrypt; nothing is sent anywhere. Downloaded papers are left out
/// (they are the publishers' content). The browser's lib/assets-export.ts builds the same files and the same zip byte for
/// byte from the same input (tests/fixtures/assets-export/assets-export-v1.json), so every rule here is repeatable: dates
/// in UTC, names cleaned by an explicit character list, files ordered by their UTF-8 bytes, stored (uncompressed) entries.
public enum AssetsExport {
    public struct Message: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable { case user, assistant }
        public var role: Role
        public var text: String
        public var at: Int64?
        public var model: String?
        public var interrupted: Bool?
        public init(role: Role, text: String, at: Int64? = nil, model: String? = nil, interrupted: Bool? = nil) {
            self.role = role; self.text = text; self.at = at; self.model = model; self.interrupted = interrupted
        }
    }
    public struct Chat: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var paper: String?
        public var startedAt: Int64?
        public var passage: String?
        public var versions: Int?
        public var messages: [Message]
        public init(id: String, title: String, paper: String? = nil, startedAt: Int64? = nil, passage: String? = nil, versions: Int? = nil, messages: [Message]) {
            self.id = id; self.title = title; self.paper = paper; self.startedAt = startedAt; self.passage = passage; self.versions = versions; self.messages = messages
        }
    }
    public struct Diagram: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var format: String
        public var source: String
        public var at: Int64?
        public var chat: String?
        public init(id: String, title: String, format: String, source: String, at: Int64? = nil, chat: String? = nil) {
            self.id = id; self.title = title; self.format = format; self.source = source; self.at = at; self.chat = chat
        }
    }
    public struct SnippetSource: Codable, Equatable, Sendable {
        public var title: String
        public var section: String?
        public var label: String?
        public var url: String?
        public var page: Int?
        public init(title: String, section: String? = nil, label: String? = nil, url: String? = nil, page: Int? = nil) {
            self.title = title; self.section = section; self.label = label; self.url = url; self.page = page
        }
    }
    public struct Snippet: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case region, quote, text }
        public var id: String
        public var kind: Kind
        public var at: Int64
        public var comment: String
        public var quote: String?
        public var source: SnippetSource?
        /// The snippet has an image of this type (`image/png`, `image/jpeg`); its bytes are passed separately.
        public var image: String?
        public init(id: String, kind: Kind, at: Int64, comment: String, quote: String? = nil, source: SnippetSource? = nil, image: String? = nil) {
            self.id = id; self.kind = kind; self.at = at; self.comment = comment; self.quote = quote; self.source = source; self.image = image
        }
    }
    public struct Collection: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var snippets: [Snippet]
        public init(id: String, title: String, snippets: [Snippet]) { self.id = id; self.title = title; self.snippets = snippets }
    }
    public struct Item: Codable, Equatable, Sendable {
        public var name: String
        public var line: String
        public var paragraphs: [Int]
        public init(name: String, line: String, paragraphs: [Int]) { self.name = name; self.line = line; self.paragraphs = paragraphs }
    }
    public struct Symbol: Codable, Equatable, Sendable {
        public var symbol: String
        public var latex: String?
        public var meaning: String
        public var source: String
        public var paragraph: Int?
        public init(symbol: String, latex: String? = nil, meaning: String, source: String, paragraph: Int? = nil) {
            self.symbol = symbol; self.latex = latex; self.meaning = meaning; self.source = source; self.paragraph = paragraph
        }
    }
    public struct Section: Codable, Equatable, Sendable {
        public var name: String
        public var title: String
        public var text: String
        public var paragraphs: [Int]
        public init(name: String, title: String, text: String, paragraphs: [Int]) { self.name = name; self.title = title; self.text = text; self.paragraphs = paragraphs }
    }
    public struct Link: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var label: String
        public init(from: String, to: String, label: String) { self.from = from; self.to = to; self.label = label }
    }
    public struct Explanation: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case equation, figure, paper }
        public var kind: Kind
        public var action: String
        public var paper: String
        public var label: String
        public var at: Int64
        public var model: String?
        public var summary: String?
        public var symbols: [Symbol]?
        public var sections: [Section]?
        public var background: [Item]?
        public var ideas: [Item]?
        public var links: [Link]?
        public var text: String
        public init(kind: Kind, action: String, paper: String, label: String, at: Int64, model: String? = nil, summary: String? = nil, symbols: [Symbol]? = nil,
                    sections: [Section]? = nil, background: [Item]? = nil, ideas: [Item]? = nil, links: [Link]? = nil, text: String) {
            self.kind = kind; self.action = action; self.paper = paper; self.label = label; self.at = at; self.model = model; self.summary = summary
            self.symbols = symbols; self.sections = sections; self.background = background; self.ideas = ideas; self.links = links; self.text = text
        }
    }
    public struct Input: Codable, Equatable, Sendable {
        public var exportedAt: Int64
        public var chats: [Chat]
        public var diagrams: [Diagram]
        public var collections: [Collection]
        public var explanations: [Explanation]
        /// What the device couldn't read, in the device's own words (each a sentence).
        public var skipped: [String]
        public init(exportedAt: Int64, chats: [Chat] = [], diagrams: [Diagram] = [], collections: [Collection] = [], explanations: [Explanation] = [], skipped: [String] = []) {
            self.exportedAt = exportedAt; self.chats = chats; self.diagrams = diagrams; self.collections = collections; self.explanations = explanations; self.skipped = skipped
        }
    }
    public struct File: Equatable, Sendable {
        public let path: String
        public let data: Data
    }
    public struct Result: Equatable, Sendable {
        public let root: String
        public let fileName: String
        public let files: [File]
        public let skipped: [String]
    }

    // MARK: Names and text

    private static let pathCharacters: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    private static let spaces: Set<UInt32> = [0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
                                              0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000]

    /// One line: control and format characters (and, for a file name, path characters) become spaces; runs of spaces
    /// become one; trimmed. Counted in Unicode scalars.
    static func line(_ text: String, path: Bool = false) -> String {
        var out = String.UnicodeScalarView(), space = false
        for c in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let category = c.properties.generalCategory
            if spaces.contains(c.value) || category == .control || category == .format || (path && pathCharacters.contains(c)) {
                space = !out.isEmpty; continue
            }
            if space { out.append(" "); space = false }
            out.append(c)
        }
        return String(out)
    }
    private static func clip(_ text: String, _ limit: Int) -> String {
        let all = Array(text.unicodeScalars)
        guard all.count > limit else { return text }
        var head = String(String.UnicodeScalarView(all.prefix(limit - 1)))
        while head.unicodeScalars.last == " " { head.unicodeScalars.removeLast() }
        return head + "…"
    }
    private static func dropping(_ text: String, leading: Bool, _ set: Set<Unicode.Scalar>) -> String {
        var scalars = Array(text.unicodeScalars)
        if leading { while let first = scalars.first, set.contains(first) { scalars.removeFirst() } }
        else { while let last = scalars.last, set.contains(last) { scalars.removeLast() } }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A file name from a title: one line, no path characters, no leading dots, at most `limit` scalars.
    public static func fileName(_ title: String, limit: Int = 60, fallback: String = "Untitled") -> String {
        var name = dropping(line(title, path: true), leading: true, [".", " "])
        let all = Array(name.unicodeScalars)
        if all.count > limit { name = String(String.UnicodeScalarView(all.prefix(limit))) }
        name = dropping(name, leading: false, [".", " "])
        return name.isEmpty ? fallback : name
    }

    private static func components(_ ms: Int64) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let seconds = (Double(ms) / 1000).rounded(.down)
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
    }
    private static func pad(_ n: Int, _ width: Int = 2) -> String { String(repeating: "0", count: max(0, width - String(n).count)) + String(n) }
    /// `2026-10-22` (UTC).
    public static func day(_ ms: Int64) -> String {
        let c = components(ms)
        return "\(pad(c.year ?? 1970, 4))-\(pad(c.month ?? 1))-\(pad(c.day ?? 1))"
    }
    /// `2026-10-22 14:03 UTC`.
    public static func stamp(_ ms: Int64) -> String {
        let c = components(ms)
        return "\(day(ms)) \(pad(c.hour ?? 0)):\(pad(c.minute ?? 0)) UTC"
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func quoteBlock(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            .map { trim($0).isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func link(_ title: String, _ path: String) -> String {
        "- [\(line(title).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))](<\(path)>)"
    }
    private static func paragraphs(_ list: [Int]) -> String { list.isEmpty ? "" : " (\(list.map { "¶\($0)" }.joined(separator: ", ")))" }
    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
    private static func nonEmpty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
    /// UTF-8 byte order (the browser's `byBytes`).
    static func precedes(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }

    // MARK: The files

    private static func chatMarkdown(_ c: Chat) -> String {
        let facts = [
            nonEmpty(c.paper).map { "- Paper: \(line($0))" },
            c.startedAt.map { "- Started: \(stamp($0))" },
            nonEmpty(c.passage).map { "- Passage: “\(clip(line($0), 300))”" },
            (c.versions ?? 0) > 1 ? "- This chat has \(c.versions!) versions; this is the most recent." : nil,
        ].compactMap { $0 }
        let turns = c.messages.map { m -> String in
            let who = [m.role == .user ? "**You**" : "**AI**", m.role == .assistant ? nonEmpty(m.model).map { line($0) } ?? "" : "", m.at.map(stamp) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            return "\(who)\(m.interrupted == true ? " (stopped early)" : "")\n\n\(trim(m.text))"
        }
        let title = line(c.title)
        return ([title.isEmpty ? "Untitled chat" : title].map { "# \($0)" } + [facts.joined(separator: "\n"), "---"] + turns)
            .filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private static let kindLabel: [Snippet.Kind: String] = [.region: "Region", .quote: "Quote", .text: "Note"]
    private static func snippetMarkdown(_ c: Collection, images: [String: String]) -> String {
        let entries = c.snippets.map { s -> String in
            var parts = ["## \(stamp(s.at)) · \(kindLabel[s.kind]!)"]
            if let quote = s.quote, !trim(quote).isEmpty { parts.append(quoteBlock(trim(quote))) }
            if let image = images[s.id] { parts.append("![Snippet](<images/\(image)>)") }
            else if s.image != nil { parts.append("_The image wasn’t available on this device._") }
            if !trim(s.comment).isEmpty { parts.append(trim(s.comment)) }
            if let src = s.source {
                let fields = [line(src.title), nonEmpty(src.section).map { line($0) } ?? "", nonEmpty(src.label).map { line($0) } ?? "",
                              src.page.flatMap { $0 == 0 ? nil : "page \($0)" } ?? "", src.url ?? ""]
                parts.append("Source: \(fields.filter { !$0.isEmpty }.joined(separator: " — "))")
            }
            return parts.joined(separator: "\n\n")
        }
        let title = line(c.title)
        return (["# \(title.isEmpty ? "Untitled collection" : title)"] + entries).joined(separator: "\n\n") + "\n"
    }

    private static let suffix: [String: String] = ["equation_background": " (background)", "figure_simpler": " (more simply)"]
    private static func explanationMarkdown(_ e: Explanation) -> String {
        let paper = line(e.paper), label = line(e.label)
        let facts = ["- Paper: \(paper.isEmpty ? "Unknown paper" : paper)", "- Saved: \(stamp(e.at))", nonEmpty(e.model).map { "- Model: \(line($0))" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        var out = ["# \(label.isEmpty ? "Explanation" : label)\(suffix[e.action] ?? "")", facts]
        if e.kind == .paper {
            if let summary = nonEmpty(e.summary) { out += ["## In short", trim(summary)] }
            let items = { (list: [Item]) in
                list.map { "- **\(line($0.name))**\($0.line.isEmpty ? "" : ": \(line($0.line))")\(paragraphs($0.paragraphs))" }.joined(separator: "\n")
            }
            if let background = e.background, !background.isEmpty { out += ["## Background", items(background)] }
            if let ideas = e.ideas, !ideas.isEmpty { out += ["## Key ideas", items(ideas)] }
            if let links = e.links, !links.isEmpty {
                out += ["## How it fits together", links.map { "- \(line($0.from)) → \(line($0.to))\($0.label.isEmpty ? "" : ": \(line($0.label))")" }.joined(separator: "\n")]
            }
        } else {
            if let summary = nonEmpty(e.summary) { out.append(trim(summary)) }
            if let symbols = e.symbols, !symbols.isEmpty {
                out += ["## Symbols", symbols.map { s -> String in
                    let latex = nonEmpty(s.latex).map { " `\(line($0).replacingOccurrences(of: "`", with: "'"))`" } ?? ""
                    let note = s.paragraph.flatMap { $0 == 0 ? nil : " (¶\($0))" } ?? (s.source == "general" ? " (general knowledge)" : "")
                    return "- **\(line(s.symbol))**\(latex): \(line(s.meaning))\(note)"
                }.joined(separator: "\n")]
            }
            for s in e.sections ?? [] {
                let heading = !s.title.isEmpty && s.title != s.name ? "\(line(s.name)): \(line(s.title))" : line(s.name.isEmpty ? s.title : s.name)
                out += ["## \(heading)", trim(s.text) + paragraphs(s.paragraphs)]
            }
        }
        if !trim(e.text).isEmpty { out.append(trim(e.text)) }
        return out.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private static func diagramFile(_ d: Diagram) -> (ext: String, text: String) {
        if d.format == ChatDiagram.htmlFormat {
            return ("html", "<!doctype html>\n<html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
                + "<title>\(escapeHTML(line(d.title)))</title></head>\n<body>\n\(trim(d.source))\n</body></html>\n")
        }
        let header = ["%% \(line(d.title))", nonEmpty(d.chat).map { "%% From the chat “\(line($0))”" } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        return ("mmd", "\(header)\n\(trim(d.source))\n")
    }

    /// Every file of the export, under one folder named for the day, with README.md first. `images`: snippet images by
    /// snippet id (decrypted on this device).
    public static func build(_ input: Input, images: [String: Data]) -> Result {
        let root = "Gradstep export \(day(input.exportedAt))"
        var used = Set<String>(), files: [File] = [], skipped: [String] = []
        var listed: [String: [String]] = [:]
        func claim(_ folder: String, _ name: String, _ ext: String) -> String {
            var path = "\(folder)/\(name).\(ext)", n = 2
            while used.contains(path.lowercased()) { path = "\(folder)/\(name) \(n).\(ext)"; n += 1 }
            used.insert(path.lowercased())
            return path
        }
        func add(_ path: String, _ text: String) { files.append(File(path: path, data: Data(text.utf8))) }
        func ordered(_ a: Int64?, _ aID: String, _ b: Int64?, _ bID: String) -> Bool {
            let x = a ?? -1, y = b ?? -1
            return x != y ? x < y : precedes(aID, bID)
        }

        let chats = input.chats.filter { !$0.messages.isEmpty }.sorted { ordered($0.startedAt, $0.id, $1.startedAt, $1.id) }
        for c in chats {
            let name = fileName(c.title, limit: 60, fallback: "Untitled chat")
            let path = claim("chats", c.startedAt.map { "\(day($0)) \(name)" } ?? name, "md")
            add(path, chatMarkdown(c)); listed["chats", default: []].append(link(c.title.isEmpty ? "Untitled chat" : c.title, path))
        }

        var breakdowns = 0
        for d in input.diagrams.sorted(by: { ordered($0.at, $0.id, $1.at, $1.id) }) {
            guard d.format == ChatDiagram.currentFormat || d.format == ChatDiagram.htmlFormat else { breakdowns += 1; continue }
            let file = diagramFile(d), name = fileName(d.title, limit: 60, fallback: "Diagram")
            let path = claim("diagrams", d.at.map { "\(day($0)) \(name)" } ?? name, file.ext)
            add(path, file.text); listed["diagrams", default: []].append(link(d.title.isEmpty ? "Diagram" : d.title, path))
        }
        if breakdowns > 0 {
            skipped.append("\(plural(breakdowns, "figure breakdown", "figure breakdowns")) from chats \(breakdowns == 1 ? "isn’t" : "aren’t") included: \(breakdowns == 1 ? "it is" : "they are") cut from the paper itself.")
        }

        var snippetCount = 0
        let collections = input.collections.sorted { a, b in
            let x = line(a.title), y = line(b.title)
            return x != y ? precedes(x, y) : precedes(a.id, b.id)
        }
        for c in collections {
            let snippets = c.snippets.sorted { ordered($0.at, $0.id, $1.at, $1.id) }
            var names: [String: String] = [:], missing = 0
            for s in snippets {
                guard let type = s.image else { continue }
                guard let bytes = images[s.id] else { missing += 1; continue }
                let imagePath = claim("snippets/images", s.id, type == "image/png" ? "png" : "jpg")
                files.append(File(path: imagePath, data: bytes)); names[s.id] = String(imagePath.dropFirst("snippets/images/".count))
            }
            let path = claim("snippets", fileName(c.title, limit: 60, fallback: "Untitled collection"), "md")
            var sorted = c; sorted.snippets = snippets
            add(path, snippetMarkdown(sorted, images: names)); listed["snippets", default: []].append(link(c.title.isEmpty ? "Untitled collection" : c.title, path))
            snippetCount += snippets.count
            let title = line(c.title).isEmpty ? "Untitled collection" : line(c.title)
            if missing == 1 { skipped.append("An image in “\(title)” wasn’t available on this device.") }
            else if missing > 1 { skipped.append("\(missing) images in “\(title)” weren’t available on this device.") }
        }

        let rank: [Explanation.Kind: Int] = [.equation: 0, .figure: 1, .paper: 2]
        let explanations = input.explanations.sorted { a, b in
            if a.kind != b.kind { return rank[a.kind]! < rank[b.kind]! }
            if line(a.paper) != line(b.paper) { return precedes(line(a.paper), line(b.paper)) }
            if line(a.label) != line(b.label) { return precedes(line(a.label), line(b.label)) }
            if a.action != b.action { return precedes(a.action, b.action) }
            return a.at < b.at
        }
        let folders: [Explanation.Kind: String] = [.equation: "explanations/equations", .figure: "explanations/figures", .paper: "explanations/papers"]
        for e in explanations {
            let paper = fileName(e.paper, limit: 50, fallback: "Unknown paper"), extra = suffix[e.action] ?? ""
            let name = e.kind == .paper ? paper : "\(paper) – \(fileName(e.label + extra, limit: 40, fallback: "Explanation"))"
            let path = claim(folders[e.kind]!, name, "md")
            add(path, explanationMarkdown(e))
            let paperTitle = line(e.paper).isEmpty ? "Unknown paper" : line(e.paper)
            listed[e.kind.rawValue, default: []].append(link(e.kind == .paper ? paperTitle : "\(paperTitle) – \(line(e.label))\(extra)", path))
        }
        skipped += input.skipped.map { line($0) }.filter { !$0.isEmpty }

        let count = { (kind: Explanation.Kind) in input.explanations.filter { $0.kind == kind }.count }
        let sections: [(String, String)] = [("Chats", "chats"), ("Diagrams", "diagrams"), ("Snippets", "snippets"), ("Equation explanations", "equation"),
                                            ("Figure explanations", "figure"), ("Paper explanations", "paper")]
        let readme = ([
            "# Gradstep export",
            "Exported \(stamp(input.exportedAt)). Everything here was put together on this device from your own content.",
            ["- Chats: \(chats.count)", "- Diagrams: \(listed["diagrams"]?.count ?? 0)",
             "- Snippets: \(snippetCount) in \(plural(collections.count, "collection", "collections"))",
             "- Equation explanations: \(count(.equation))", "- Figure explanations: \(count(.figure))", "- Paper explanations: \(count(.paper))"].joined(separator: "\n"),
            "Downloaded papers aren’t included: get them again from each paper’s source. Explanations are kept on each device, so these are the ones kept on this one.",
            skipped.isEmpty ? "" : "## Left out\n\n" + skipped.map { "- \($0)" }.joined(separator: "\n"),
        ] + sections.compactMap { title, key in listed[key].flatMap { $0.isEmpty ? nil : "## \(title)\n\n" + $0.joined(separator: "\n") } })
            .filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"

        let sortedFiles = files.sorted { precedes($0.path, $1.path) }
        return Result(root: root, fileName: "\(root).zip",
                      files: [File(path: "\(root)/README.md", data: Data(readme.utf8))] + sortedFiles.map { File(path: "\(root)/\($0.path)", data: $0.data) },
                      skipped: skipped)
    }

    // MARK: The zip (stored entries, UTF-8 names, one fixed time)

    public enum ZipError: Error, Equatable { case tooLarge }

    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(zlib.crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }

    /// A zip of the files in the order given: stored (no compression), names flagged UTF-8, every entry dated `at` (UTC,
    /// to two seconds). Throws past the plain zip format's limits (4 GB, 65,535 entries).
    public static func zip(_ files: [File], at: Int64) throws -> Data {
        let c = components(at)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let date = UInt16(((max(1980, c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        let total = files.reduce(22) { $0 + 76 + 2 * $1.path.utf8.count + $1.data.count }
        guard files.count <= 0xffff, total <= 0xffff_ffff else { throw ZipError.tooLarge }
        var out = Data(capacity: total)
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        var central: [(name: Data, crc: UInt32, size: UInt32, offset: UInt32)] = []
        for file in files {
            let name = Data(file.path.utf8), crc = crc32(file.data), size = UInt32(file.data.count), offset = UInt32(out.count)
            u32(0x04034b50); u16(10); u16(0x0800); u16(0); u16(time); u16(date); u32(crc); u32(size); u32(size); u16(UInt16(name.count)); u16(0)
            out.append(name); out.append(file.data)
            central.append((name, crc, size, offset))
        }
        let start = UInt32(out.count)
        for entry in central {
            u32(0x02014b50); u16(20); u16(10); u16(0x0800); u16(0); u16(time); u16(date); u32(entry.crc); u32(entry.size); u32(entry.size)
            u16(UInt16(entry.name.count)); u16(0); u16(0); u16(0); u16(0); u32(0); u32(entry.offset); out.append(entry.name)
        }
        let size = UInt32(out.count) - start
        u32(0x06054b50); u16(0); u16(0); u16(UInt16(central.count)); u16(UInt16(central.count)); u32(size); u32(start); u16(0)
        return out
    }
}

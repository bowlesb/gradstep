import Foundation

/// Presentation-only structure of a chat message: Markdown-like blocks with
/// inline and display math. Parsing never alters the stored source text; any
/// construct that is not closed (for example while streaming) stays literal.
public enum ChatInline: Equatable, Sendable {
    /// Inline Markdown source (bold, italic, code, links) without math.
    case text(String)
    /// LaTeX body of `\( … \)` or `$ … $`.
    case math(String)
}

public enum ChatBlock: Equatable, Sendable {
    case paragraph([ChatInline])
    case heading(level: Int, [ChatInline])
    /// `marker` is "•" or an ordinal such as "2."; `depth` counts indentation levels.
    case listItem(marker: String, depth: Int, [ChatInline])
    /// LaTeX body of `\[ … \]` or `$$ … $$`.
    case displayMath(String)
    /// Fenced code, or table rows that are not (yet) a complete table: shown
    /// monospaced and unwrapped.
    case preformatted(String)
    /// A complete GFM table: header, alignment row and body rows.
    case table(ChatTable)
    /// The web sources list the server appends to an answer that searched.
    case sources([ChatSource])
}

public struct ChatSource: Equatable, Sendable {
    public let title: String?
    public let url: URL
}

/// A GFM table from an answer. Cells keep their inline Markdown and math; a
/// pipe inside inline code or math, or escaped as `\|`, belongs to its cell.
public struct ChatTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }
    public struct Cell: Equatable, Sendable {
        /// The cell's Markdown, with `\|` resolved to `|` outside math.
        public let source: String
        public let parts: [ChatInline]
        public init(_ source: String) { self.source = source; parts = ChatRichText.inline(source) }
    }
    /// Larger tables stay pipe text (they are rarely readable as a grid on a phone).
    public static let maximumColumns = 12
    public static let maximumRows = 120

    public let header: [Cell]
    public let alignments: [Alignment]
    /// Body rows, each padded with empty cells or cut to the header's width (as GFM does).
    public let rows: [[Cell]]

    /// `rows`: the trimmed source lines, header first, then the alignment row.
    /// Nil unless the header and alignment row agree on the number of columns.
    public init?(rows lines: [String]) {
        guard lines.count >= 2, lines.count - 2 <= Self.maximumRows else { return nil }
        let header = Self.cells(lines[0]), separator = Self.cells(lines[1])
        guard !header.isEmpty, header.count <= Self.maximumColumns, header.count == separator.count else { return nil }
        var alignments: [Alignment] = []
        for marker in separator {
            guard let alignment = Self.alignment(marker) else { return nil }
            alignments.append(alignment)
        }
        self.header = header.map(Cell.init)
        self.alignments = alignments
        rows = lines.dropFirst(2).map { line in
            let cells = Self.cells(line)
            return (0..<header.count).map { Cell($0 < cells.count ? cells[$0] : "") }
        }
    }

    private static func alignment(_ marker: String) -> Alignment? {
        guard marker.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
        switch (marker.hasPrefix(":"), marker.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    /// Splits one row on unescaped pipes outside inline code and math, dropping
    /// the outer pipes. Cells are trimmed; `\|` becomes `|` except inside math.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = [], current = ""
        var index = line.startIndex, endedWithPipe = false
        while index < line.endIndex {
            let character = line[index], next = line.index(after: index)
            endedWithPipe = false
            if character == "\\", next < line.endIndex {
                if line[next] == "|" { current.append("|"); index = line.index(after: next); continue }
                if line[next] == "(", let close = line.range(of: "\\)", range: line.index(after: next)..<line.endIndex) {
                    current += line[index..<close.upperBound]; index = close.upperBound; continue
                }
                // Any other escape (such as `\$`) is copied as is and never opens anything.
                current += line[index...next]; index = line.index(after: next); continue
            }
            if character == "`" {
                let run = line[index...].prefix(while: { $0 == "`" })
                let afterRun = run.endIndex
                if let close = Self.closingRun(of: run.count, in: line, from: afterRun) {
                    current += line[index..<close].replacingOccurrences(of: "\\|", with: "|")
                    index = close
                } else {
                    current += run; index = afterRun
                }
                continue
            }
            if character == "$", let math = ChatRichText.dollarMath(line, at: index) {
                current += line[index..<math.end]; index = math.end; continue
            }
            if character == "|" { cells.append(current); current = ""; endedWithPipe = true; index = next; continue }
            current.append(character); index = next
        }
        if !endedWithPipe { cells.append(current) }
        if line.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The end of a code span: just past a backtick run of exactly `count`.
    private static func closingRun(of count: Int, in line: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < line.endIndex {
            guard line[index] == "`" else { index = line.index(after: index); continue }
            let run = line[index...].prefix(while: { $0 == "`" })
            if run.count == count { return run.endIndex }
            index = run.endIndex
        }
        return nil
    }

    // MARK: Spoken form (VoiceOver)

    /// A cell as plain words: emphasis and code marks removed, math as its LaTeX.
    public static func spokenText(_ cell: Cell) -> String {
        let text = cell.parts.map { part -> String in
            switch part {
            case .math(let latex): return latex
            case .text(let value):
                let prepared = ChatDisplayText.inlineMarkdownPreservingBackslashes(ChatRichText.inertLinks(value))
                guard let attributed = try? AttributedString(markdown: prepared, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                else { return value }
                return String(attributed.characters)
            }
        }.joined()
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "Columns: Method, Win rate".
    public var spokenHeader: String {
        "Columns: " + header.map { Self.spokenText($0).isEmpty ? "blank" : Self.spokenText($0) }.joined(separator: ", ")
    }

    /// "Row 2: Method, DPO; Win rate, 64%". Empty cells are skipped.
    public func spokenRow(_ index: Int) -> String {
        let values = zip(header, rows[index]).compactMap { column, cell -> String? in
            let value = Self.spokenText(cell), name = Self.spokenText(column)
            guard !value.isEmpty else { return nil }
            return name.isEmpty ? value : "\(name), \(value)"
        }
        return "Row \(index + 1): " + (values.isEmpty ? "blank" : values.joined(separator: "; "))
    }
}

public enum ChatRichText {
    /// Upper bound on parsed input; longer messages keep their tail as plain text.
    public static let maximumParsedBytes = 200_000

    /// `streaming`: the text may still grow, so table rows at its very end stay
    /// pipe text until a following line (or the finished answer) completes them.
    public static func parse(_ source: String, streaming: Bool = false) -> [ChatBlock] {
        var text = source
        var overflow: String?
        if text.utf8.count > maximumParsedBytes {
            let cut = text.utf8.index(text.utf8.startIndex, offsetBy: maximumParsedBytes)
            let boundary = String.Index(cut, within: text) ?? text.index(text.startIndex, offsetBy: min(text.count, maximumParsedBytes / 4))
            overflow = String(text[boundary...]); text = String(text[..<boundary])
        }
        var blocks: [ChatBlock] = []
        let trailing = trailingSources(text)
        if let trailing { text = trailing.body }
        let segments = displaySegments(text)
        // Only the very end of a still-growing answer can hold an unfinished table.
        let growing = streaming && overflow == nil && trailing == nil
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .math(let body): blocks.append(.displayMath(body))
            case .text(let chunk): blocks.append(contentsOf: lineBlocks(chunk, growing: growing && index == segments.count - 1))
            }
        }
        if let overflow { blocks.append(.paragraph([.text(overflow)])) }
        if let trailing { blocks.append(.sources(trailing.sources)) }
        return blocks
    }

    /// Blocks as reading text for VoiceOver, close to their source: inline
    /// Markdown kept (the caller renders it), math as its delimited LaTeX, a
    /// table as its spoken rows. Sources are read from their own list.
    public static func spokenText(_ blocks: [ChatBlock]) -> String {
        func line(_ parts: [ChatInline]) -> String {
            parts.map { part in
                switch part {
                case .text(let value): value
                case .math(let latex): "\\(\(latex)\\)"
                }
            }.joined()
        }
        return blocks.compactMap { block -> String? in
            switch block {
            case .paragraph(let parts), .heading(_, let parts): line(parts)
            case .listItem(let marker, _, let parts): "\(marker) \(line(parts))"
            case .displayMath(let latex): "\\[\(latex)\\]"
            case .preformatted(let text): text
            case .table(let table): ([table.spokenHeader] + table.rows.indices.map(table.spokenRow)).joined(separator: "\n")
            case .sources: nil
            }
        }.joined(separator: "\n\n")
    }

    // MARK: Sources

    /// A final "Sources:" section whose every line is `N. [title — ]https://…`
    /// (the server's format); anything else stays ordinary text.
    public static func trailingSources(_ text: String) -> (body: String, sources: [ChatSource])? {
        guard let marker = text.range(of: "\n\nSources:\n", options: .backwards) ?? (text.hasPrefix("Sources:\n") ? text.range(of: "Sources:\n") : nil)
        else { return nil }
        let lines = text[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Patterns compiled once (every render of every answer asked; NATIVE_REVIEW_20261021 C12).
        guard (1...8).contains(lines.count) else { return nil }
        let pattern = CompiledPatterns.shared.expression(#"^\d{1,2}\. (?:(.{1,300}) — )?(https://[^\s]{1,500})$"#)
        var sources: [ChatSource] = []
        for line in lines {
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let urlRange = Range(match.range(at: 2), in: line), let url = URL(string: String(line[urlRange])),
                  url.scheme == "https", url.host?.isEmpty == false else { return nil }
            let title = Range(match.range(at: 1), in: line).map { String(line[$0]) }
            sources.append(ChatSource(title: title, url: url))
        }
        return (String(text[..<marker.lowerBound]), sources)
    }

    // MARK: Display math (outside fenced code)

    private enum Segment { case text(String), math(String) }

    private static func displaySegments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var buffer = ""
        var index = text.startIndex
        var inFence = false
        var lineStart = true
        func flush() { if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" } }
        while index < text.endIndex {
            if lineStart && text[index...].hasPrefix("```") {
                inFence.toggle()
            }
            if !inFence {
                for (open, close) in [("\\[", "\\]"), ("$$", "$$")] where text[index...].hasPrefix(open) {
                    let bodyStart = text.index(index, offsetBy: open.count)
                    if let end = text.range(of: close, range: bodyStart..<text.endIndex) {
                        let body = text[bodyStart..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !body.isEmpty, !body.contains("\n\n") {
                            flush(); result.append(.math(body))
                            index = end.upperBound; lineStart = false
                            continue
                        }
                    }
                }
            }
            if index >= text.endIndex { break }
            let character = text[index]
            buffer.append(character)
            lineStart = character == "\n"
            index = text.index(after: index)
        }
        flush()
        return result
    }

    // MARK: Line blocks

    private static func lineBlocks(_ chunk: String, growing: Bool) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var paragraph: [String] = []
        var table: [String] = []
        var fence: [String]?
        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(inline(joined))) }
            paragraph = []
        }
        /// Rows become a table only once complete and well formed; otherwise they stay pipe text.
        func flushTable(complete: Bool) {
            guard !table.isEmpty else { return }
            if complete, let parsed = ChatTable(rows: table) { blocks.append(.table(parsed)) }
            else { blocks.append(.preformatted(table.joined(separator: "\n"))) }
            table = []
        }
        let lines = chunk.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // While the answer grows, its last line is unfinished: it may still become a row.
            let unfinished = growing && index == lines.count - 1
            if var open = fence {
                if trimmed.hasPrefix("```") { blocks.append(.preformatted(open.joined(separator: "\n"))); fence = nil }
                else { open.append(line); fence = open }
                continue
            }
            if trimmed.hasPrefix("```") { flushParagraph(); flushTable(complete: true); fence = []; continue }
            if trimmed.hasPrefix("|") && (trimmed.count > 1 || unfinished) { flushParagraph(); table.append(trimmed); continue }
            if unfinished && trimmed.isEmpty && !table.isEmpty { continue }
            flushTable(complete: true)
            if trimmed.isEmpty { flushParagraph(); continue }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, inline(heading.text)))
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                blocks.append(.listItem(marker: item.marker, depth: item.depth, inline(item.text)))
                continue
            }
            paragraph.append(line)
        }
        if let open = fence { paragraph.append(contentsOf: ["```"] + open) }
        flushTable(complete: !growing); flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (marker: String, depth: Int, text: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        let depth = min(indent / 2, 4)
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return ("•", depth, String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if (1...3).contains(digits.count), rest.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits).", depth, String(rest.dropFirst(digits.count + 2)))
        }
        return nil
    }

    // MARK: Links

    /// Model output is untrusted (paper text can carry prompt injection), so
    /// links are shown, not followed: `[text](url)` → `text (url)` and
    /// `<https://…>` → `https://…`. The URL stays visible and copyable.
    public static func inertLinks(_ text: String) -> String {
        guard text.contains("](") || text.contains("<http") else { return text }
        var result = text
        let markdown = CompiledPatterns.shared.expression(#"\[([^\]\n]{0,500})\]\(([^)\s]{1,2000})\)"#)
        result = markdown.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 ($2)")
        let angle = CompiledPatterns.shared.expression(#"<(https?://[^>\s]{1,2000})>"#)
        result = angle.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        return result
    }

    // MARK: Answer label

    /// An answer's leading "Answer:" label (`**Answer:**`, `Answer:`, `## Answer:`), which says nothing
    /// (owner feedback 2026-10-07). Display only; the stored text keeps it.
    public static func withoutAnswerLabel(_ text: String) -> String {
        guard let label = text.range(of: #"^\s*(?:#{1,6}\s+)?(?:\*\*|__|\*|_)?\s*answer\s*(?:\*\*|__|\*|_)?\s*:\s*(?:\*\*|__|\*|_)?[ \t]*\n*"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return text }
        return String(text[label.upperBound...])
    }

    // MARK: Styled runs

    /// Inline parts as runs to draw: Markdown (bold, italic, code) parsed once across the
    /// whole line, so emphasis around inline math (`**$n = 0$:**`) applies instead of
    /// showing its asterisks. Text runs carry Foundation's inline presentation intents.
    public enum StyledRun: Equatable, Sendable {
        case text(AttributedString)
        case math(String, InlinePresentationIntent)
    }

    public static func styledRuns(_ parts: [ChatInline]) -> [StyledRun] {
        // Each formula becomes one private-use placeholder while the Markdown is parsed.
        let base: UInt32 = 0xF0000
        var combined = "", formulas: [String] = []
        for part in parts {
            switch part {
            case .text(let value): combined += String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value < base }))
            case .math(let latex):
                guard let placeholder = Unicode.Scalar(base + UInt32(formulas.count)) else { return fallbackRuns(parts) }
                combined.unicodeScalars.append(placeholder); formulas.append(latex)
            }
        }
        guard let parsed = try? AttributedString(markdown: ChatDisplayText.inlineMarkdownPreservingBackslashes(inertLinks(combined)),
                                                 options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return fallbackRuns(parts) }
        var runs: [StyledRun] = []
        for run in parsed.runs {
            let slice = parsed[run.range]
            let intent = run.inlinePresentationIntent ?? []
            var pending = ""
            func flush() {
                guard !pending.isEmpty else { return }
                var text = AttributedString(pending); text.mergeAttributes(run.attributes)
                text.link = nil // links stay inert: shown, never followed
                runs.append(.text(text)); pending = ""
            }
            for scalar in String(slice.characters).unicodeScalars {
                if scalar.value >= base, Int(scalar.value - base) < formulas.count {
                    flush(); runs.append(.math(formulas[Int(scalar.value - base)], intent))
                } else {
                    pending.unicodeScalars.append(scalar)
                }
            }
            flush()
        }
        return runs
    }

    private static func fallbackRuns(_ parts: [ChatInline]) -> [StyledRun] {
        parts.map { part in
            switch part {
            case .text(let value): .text(AttributedString(value))
            case .math(let latex): .math(latex, [])
            }
        }
    }

    // MARK: Inline math

    /// Splits `\( … \)` and conservative `$ … $` (no space just inside the
    /// dollars, not followed by a digit, not escaped). Code spans stay text.
    public static func inline(_ text: String) -> [ChatInline] {
        var result: [ChatInline] = []
        var buffer = ""
        var index = text.startIndex
        var inCode = false
        func flush() { if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" } }
        while index < text.endIndex {
            let character = text[index]
            if character == "`" { inCode.toggle() }
            if !inCode {
                if text[index...].hasPrefix("\\("),
                   let end = text.range(of: "\\)", range: text.index(index, offsetBy: 2)..<text.endIndex) {
                    let body = text[text.index(index, offsetBy: 2)..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty { flush(); result.append(.math(body)); index = end.upperBound; continue }
                }
                if character == "$", !(index > text.startIndex && text[text.index(before: index)] == "\\"),
                   let math = dollarMath(text, at: index) {
                    flush(); result.append(.math(math.body)); index = math.end; continue
                }
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flush()
        return result
    }

    static func dollarMath(_ text: String, at index: String.Index) -> (body: String, end: String.Index)? {
        let start = text.index(after: index)
        guard start < text.endIndex, text[start] != "$", !text[start].isWhitespace else { return nil }
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "\n" { return nil }
            if character == "$", text[text.index(before: cursor)] != "\\" {
                let previous = text[text.index(before: cursor)]
                let after = text.index(after: cursor)
                if previous.isWhitespace { return nil }
                if after < text.endIndex, text[after].isNumber { return nil }
                let body = String(text[start..<cursor])
                return body.isEmpty ? nil : (body, after)
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}

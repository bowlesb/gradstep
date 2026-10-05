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
    /// Fenced code or a Markdown table, shown monospaced and unwrapped.
    case preformatted(String)
    /// The web sources list the server appends to an answer that searched.
    case sources([ChatSource])
}

public struct ChatSource: Equatable, Sendable {
    public let title: String?
    public let url: URL
}

public enum ChatRichText {
    /// Upper bound on parsed input; longer messages keep their tail as plain text.
    public static let maximumParsedBytes = 200_000

    public static func parse(_ source: String) -> [ChatBlock] {
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
        for segment in displaySegments(text) {
            switch segment {
            case .math(let body): blocks.append(.displayMath(body))
            case .text(let chunk): blocks.append(contentsOf: lineBlocks(chunk))
            }
        }
        if let overflow { blocks.append(.paragraph([.text(overflow)])) }
        if let trailing { blocks.append(.sources(trailing.sources)) }
        return blocks
    }

    // MARK: Sources

    /// A final "Sources:" section whose every line is `N. [title — ]https://…`
    /// (the server's format); anything else stays ordinary text.
    public static func trailingSources(_ text: String) -> (body: String, sources: [ChatSource])? {
        guard let marker = text.range(of: "\n\nSources:\n", options: .backwards) ?? (text.hasPrefix("Sources:\n") ? text.range(of: "Sources:\n") : nil)
        else { return nil }
        let lines = text[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard (1...8).contains(lines.count),
              let pattern = try? NSRegularExpression(pattern: #"^\d{1,2}\. (?:(.{1,300}) — )?(https://[^\s]{1,500})$"#) else { return nil }
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

    private static func lineBlocks(_ chunk: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        var paragraph: [String] = []
        var table: [String] = []
        var fence: [String]?
        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(inline(joined))) }
            paragraph = []
        }
        func flushTable() { if !table.isEmpty { blocks.append(.preformatted(table.joined(separator: "\n"))); table = [] } }
        for rawLine in chunk.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = fence {
                if trimmed.hasPrefix("```") { blocks.append(.preformatted(open.joined(separator: "\n"))); fence = nil }
                else { open.append(line); fence = open }
                continue
            }
            if trimmed.hasPrefix("```") { flushParagraph(); flushTable(); fence = []; continue }
            if trimmed.hasPrefix("|") && trimmed.count > 1 { flushParagraph(); table.append(trimmed); continue }
            flushTable()
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
        flushTable(); flushParagraph()
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
        if let markdown = try? NSRegularExpression(pattern: #"\[([^\]\n]{0,500})\]\(([^)\s]{1,2000})\)"#) {
            result = markdown.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1 ($2)")
        }
        if let angle = try? NSRegularExpression(pattern: #"<(https?://[^>\s]{1,2000})>"#) {
            result = angle.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        }
        return result
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

    private static func dollarMath(_ text: String, at index: String.Index) -> (body: String, end: String.Index)? {
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

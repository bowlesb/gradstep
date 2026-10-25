import Foundation

/// Readable text of what global search indexes (docs/architecture/GLOBAL_SEARCH.md "What is indexed"): the words a
/// reader sees, so a result's excerpt shows text, not Markdown or LaTeX, and its matched words line up with the index.
public enum SearchText {
    /// A chat message (question or answer): Markdown markers, figure-part markers, `[¶N]` citations and the sources list
    /// left out; links as their text and address; inline and display math as readable math (`SearchText.math`); tables'
    /// cells and code kept. Blocks on their own lines.
    public static func chat(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var source = text.utf8.contains(0x5B) && text.contains("[[") && FigurePartMarkers.hasMarkers(text) ? FigurePartMarkers.stripped(text) : text
        // Plain prose (most questions) needs nothing more. Byte scans: Character-wise ones cost more than the rest.
        if !source.utf8.contains(where: { special[Int($0)] }) { return String(trimmed(source[...])) }
        if source.contains("Sources:\n"), let trailing = ChatRichText.trailingSources(source) { source = trailing.body }
        // Display math first (it may span lines), then line by line; a lighter pass than the transcript's parser
        // (ChatRichText.parse), which costs about 0.4 ms an answer: indexing reads every message.
        if source.utf8.contains(0x24) { source = replacingMath(source, open: "$$", close: "$$") }
        if source.utf8.contains(0x5C) { source = replacingMath(source, open: "\\[", close: "\\]") }
        var lines: [String] = []
        var fenced = false
        for raw in source.utf8.split(separator: 0x0A) {
            var line = trimmed(Substring(raw))
            guard let first = line.utf8.first else { continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced { lines.append(String(line)); continue }
            if first == 0x7C /* | */ {
                // A table: its alignment row goes, cells are separated by a dot.
                if line.utf8.allSatisfy({ $0 == 0x7C || $0 == 0x2D || $0 == 0x3A || $0 == 0x20 }) { continue }
                line = Substring(line.split(separator: "|").map { trimmed($0) }.filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if first == 0x23 || first == 0x3E || first == 0x2D || first == 0x2A || first == 0x2B || (first >= 0x30 && first <= 0x39) || first == 0xE2 {
                line = Substring(withoutBlockMarker(String(line)))
            }
            let text = line.utf8.contains(where: { special[Int($0)] }) ? inline(String(line)) : String(line)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.joined(separator: "\n")
    }

    /// Bytes that may need more than copying: Markdown, math, links, citations, line breaks.
    private static let special: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in "*_`#|$\\[]<>~\n".utf8 { table[Int(byte)] = true }
        return table
    }()

    /// Spaces and tabs off both ends.
    static func trimmed(_ text: Substring) -> Substring {
        let utf8 = text.utf8
        guard let start = utf8.firstIndex(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0A }) else { return "" }
        let end = utf8.lastIndex(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D && $0 != 0x0A })!
        return text[start...end]
    }

    /// A heading's `#`s, a quotation's `>`, a list item's marker.
    static func withoutBlockMarker(_ line: String) -> String {
        guard let first = line.first else { return line }
        var rest = Substring(line)
        if first == "#" { rest = rest.drop { $0 == "#" } }
        else if first == ">" { rest = rest.drop { $0 == ">" || $0 == " " } }
        else if (first == "-" || first == "*" || first == "+" || first == "•"), rest.dropFirst().first == " " { rest = rest.dropFirst(2) }
        else if first.isNumber, let dot = rest.prefix(4).firstIndex(where: { $0 == "." || $0 == ")" }),
                rest[rest.startIndex..<dot].allSatisfy(\.isNumber), rest[rest.index(after: dot)...].first == " " {
            rest = rest[rest.index(after: dot)...]
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// One line's inline Markdown: math as readable math, links as their text and address, emphasis and code marks
    /// dropped, `[¶N]` citations removed.
    static func inline(_ line: String) -> String {
        var text = line
        if text.contains("\\(") { text = replacingMath(text, open: "\\(", close: "\\)") }
        if text.contains("$") { text = replacingDollarMath(text) }
        if text.contains("](") || text.contains("<http") { text = ChatRichText.inertLinks(text) }
        if text.contains("*") || text.contains("_") || text.contains("`") || text.contains("~~") {
            for marker in ["**", "__", "`", "~~"] where text.contains(marker) { text = text.replacingOccurrences(of: marker, with: "") }
            if text.contains("*") { text = withoutSingleAsterisks(text) }
        }
        return withoutCitations(text).trimmingCharacters(in: .whitespaces)
    }

    /// `open`…`close` spans replaced by their readable math.
    static func replacingMath(_ text: String, open: String, close: String) -> String {
        guard text.contains(open) else { return text }
        var out = "", rest = text[...]
        while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: close) {
            out += rest[..<start.lowerBound]
            out += " " + math(String(rest[start.upperBound..<end.lowerBound])) + " "
            rest = rest[end.upperBound...]
        }
        return out + rest
    }

    /// `$…$` inline math (not prices: the opening `$` is followed, and the closing one preceded, by a non-space).
    static func replacingDollarMath(_ text: String) -> String {
        var out = "", rest = text[...]
        while let start = rest.firstIndex(of: "$") {
            let after = rest.index(after: start)
            guard after < rest.endIndex, !rest[after].isWhitespace, let end = rest[after...].firstIndex(of: "$"),
                  end > after, !rest[rest.index(before: end)].isWhitespace,
                  !(rest[rest.index(after: end)...].first?.isNumber ?? false) else {
                out += rest[...start]; rest = rest[after...]; continue
            }
            out += rest[..<start]
            out += math(String(rest[after..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Single-asterisk emphasis removed; a multiplication sign between spaces stays.
    static func withoutSingleAsterisks(_ text: String) -> String {
        var out = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == "*" {
                let before = index > 0 ? characters[index - 1] : " ", after = index + 1 < characters.count ? characters[index + 1] : " "
                if !(before.isWhitespace && after.isWhitespace) { continue }
            }
            out.append(character)
        }
        return out
    }

    /// `[¶12]`, `[¶3, ¶4]`, `[¶5–7]` removed: a paragraph number is never a match.
    public static func withoutCitations(_ text: String) -> String {
        guard text.contains("[¶") else { return text }
        var out = "", rest = text[...]
        while let open = rest.range(of: "[¶") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "]"),
                  rest[open.upperBound..<close].allSatisfy({ $0.isNumber || " ,–-¶".contains($0) }) else {
                out += rest[open.lowerBound..<open.upperBound]; rest = rest[open.upperBound...]; continue
            }
            if out.last == " ", rest[rest.index(after: close)...].first.map({ $0 == " " || ".,;:".contains($0) }) ?? true { out.removeLast() }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // MARK: Math

    private static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
    private static let symbols: [String: String] = [
        "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂", "nabla": "∇", "infty": "∞", "sqrt": "√", "cdot": "·",
        "times": "×", "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "sim": "∼",
        "propto": "∝", "in": "∈", "to": "→", "rightarrow": "→", "leftarrow": "←", "mid": "|", "ldots": "…", "cdots": "⋯",
        "odot": "⊙", "otimes": "⊗", "oplus": "⊕", "top": "⊤", "intercal": "⊤", "ell": "ℓ", "pm": "±", "langle": "⟨", "rangle": "⟩",
    ]

    /// LaTeX as one line of readable text: Greek letters and common symbols as characters (`\alpha` → α, `\sum` → ∑),
    /// a transpose as ⊤ (`QK^\top` → QK⊤, so "top" is never a word), layout commands dropped with their arguments kept
    /// (`\mathrm{softmax}` → softmax, `\frac{a}{b}` → a b), other commands as their names (`\log` → log), braces gone.
    public static func math(_ latex: String) -> String {
        guard latex.contains("\\") || latex.contains("{") else { return latex }
        var out = ""
        out.reserveCapacity(latex.utf8.count)
        let scalars = Array(latex.unicodeScalars)
        var index = 0
        func isLetter(_ s: Unicode.Scalar) -> Bool { (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122) }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                var end = index + 1
                while end < scalars.count && isLetter(scalars[end]) { end += 1 }
                if end == index + 1 {
                    // `\,` `\;` `\!` `\ ` `\{` `\}` `\\`: spacing, a literal brace, a line break.
                    if end < scalars.count, "{}".unicodeScalars.contains(scalars[end]) { out.unicodeScalars.append(scalars[end]) } else { out += " " }
                    index = min(scalars.count, end + 1); continue
                }
                let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                if let letter = greek[name] { out += letter }
                else if let symbol = symbols[name] { out += symbol }
                else if FullTextTokenizer.layoutCommands.contains(name) { out += " " }
                else { out += (out.last.map { $0.isLetter || $0.isNumber } ?? false ? " " : "") + name }
                index = end; continue
            }
            if scalar == "}" { if index + 1 < scalars.count, scalars[index + 1] == "{" { out += " " }; index += 1; continue }
            if scalar == "{" || scalar == "~" { if scalar == "~" { out += " " }; index += 1; continue }
            out.unicodeScalars.append(scalar)
            index += 1
        }
        // `^{⊤}` and `^⊤` read as a transpose mark.
        return out.replacingOccurrences(of: "^⊤", with: "⊤").split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    // MARK: Diagrams

    /// A diagram's words: a Mermaid diagram's node and edge labels and messages (its syntax and node names left out), a
    /// visual answer's text, a figure breakdown's parts and notes.
    public static func diagram(_ diagram: ChatDiagram) -> String {
        if diagram.isHTML { return html(diagram.source) }
        if diagram.isFigureParts, let parts = StoredFigureParts.decode(diagram.source) {
            return ([parts.title] + parts.parts.flatMap { [$0.label, $0.note] }).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return mermaid(diagram.source)
    }

    /// Mermaid labels: text in brackets, parentheses, braces, quotes and `|edge|` labels, and a sequence diagram's
    /// messages and notes (after `:`).
    public static func mermaid(_ source: String) -> String {
        var labels: [String] = []
        for line in source.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%%") else { continue }
            var found = false
            var stack: [(close: Character, start: String.Index)] = []
            var index = trimmed.startIndex
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if let top = stack.last, character == top.close {
                    stack.removeLast()
                    if stack.isEmpty {
                        let label = trimmed[trimmed.index(after: top.start)..<index].trimmingCharacters(in: CharacterSet(charactersIn: " \"'()[]{}/\\>"))
                        if !label.isEmpty { labels.append(label); found = true }
                    }
                } else if stack.isEmpty || stack.last?.close != "\"" {
                    switch character {
                    case "[": stack.append(("]", index))
                    case "(": stack.append((")", index))
                    case "{": stack.append(("}", index))
                    case "\"": stack.append(("\"", index))
                    case "|" where stack.isEmpty: stack.append(("|", index))
                    default: break
                    }
                }
                index = trimmed.index(after: index)
            }
            if !found, let colon = trimmed.firstIndex(of: ":") {
                let message = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !message.isEmpty { labels.append(message) }
            }
        }
        return labels.map(html).joined(separator: "\n")
    }

    /// Markup as text: tags dropped (a `<br>` as a space), entities read, white space collapsed.
    public static func html(_ markup: String) -> String {
        guard markup.contains("<") || markup.contains("&") else { return markup }
        var text = markup.replacingOccurrences(of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return FigureCaptionText.entities(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

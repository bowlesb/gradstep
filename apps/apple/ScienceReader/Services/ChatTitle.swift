import Foundation
import ScienceReaderCore

// Short conversation titles (owner feedback, build 14 #7). A conversation's saved title is its first question (at most
// 100 characters), so a conversation started from a reader selection action was titled by the action's prompt:
// "Explain in plain terms, including any symbols: \[\begin{equation*}…". At display time only (nothing saved or sent
// changes), a known prompt becomes its action's short label, followed by the selected passage with its LaTeX turned
// into readable symbols: "Explain · Attention(Q, K, V)=softmax(…".

extension SelectionAction {
    /// The question a selection action asks; the selected passage follows it. It is saved as the conversation's first
    /// question (and so its title), which `ChatTitle` recognizes.
    var promptPrefix: String {
        switch self {
        case .define: "Explain in plain terms, including any symbols: "
        case .relevance: "Why does this matter to the paper's method and results? "
        case .similar: "Find related papers, earlier and recent, with links: "
        case .ingest: "Find and add the paper referenced in this passage: "
        }
    }

    func prompt(_ quote: String) -> String { promptPrefix + quote }
}

enum ChatTitle {
    /// Characters of the first question kept as a conversation's title (`ReaderModel`); a title this long was cut.
    static let savedLimit = 100

    /// Selection-action prompts and their short labels: the current wordings, then earlier ones still in history.
    static let prompts: [(prefix: String, label: String)] = SelectionAction.allCases.map { ($0.promptPrefix, $0.title) } + [
        ("Explain this in plain terms, in the context of this paper (for notation or an equation, say what each symbol means): ", "Explain"),
        ("Define this in the context of the paper: ", "Define"),
        ("What role does this passage play in the paper's argument? Connect it to the method and the results: ", "Why it matters"),
        ("Explain why this passage matters to the paper: ", "Why it matters"),
        ("Find papers related to this passage — earlier work it builds on and recent follow-ups — with links: ", "Related"),
        ("Find related research and explain the connections: ", "Related"),
    ]

    /// The title to show for a saved conversation title: "Explain · ‹passage›" for a selection action, otherwise the
    /// question itself; math in either as readable symbols, on one line, "…" where the saved title was cut.
    static func display(_ saved: String) -> String {
        // Exactly the saved length: the question was (almost certainly) longer. A cut at a space ended a whole word.
        let truncated = saved.count == savedLimit, wholeWord = saved.last?.isWhitespace == true
        let text = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, label) in prompts {
            if text.hasPrefix(prefix) {
                let rest = String(text.dropFirst(prefix.count))
                var quote = readable(rest, truncated: truncated, wholeWord: wholeWord)
                if quote.isEmpty {
                    // One formula longer than the saved title (or with no complete part): show what was saved of it
                    // rather than the bare action.
                    let partial = collapse(segments(rest).map { segment -> String in
                        switch segment {
                        case .text(let value): return value
                        case .math(let body, _, _): return formula(body, cut: false)
                        }
                    }.joined(separator: " "))
                    if !partial.isEmpty { quote = truncated && !partial.hasSuffix("…") ? partial + "…" : partial }
                }
                return quote.isEmpty ? label : "\(label) · \(quote)"
            }
            // No passage, or an earlier, longer prompt cut off before its passage.
            if text == prefix.trimmingCharacters(in: .whitespaces) || (truncated && !text.isEmpty && prefix.hasPrefix(text)) { return label }
        }
        return readable(text, truncated: truncated, wholeWord: wholeWord)
    }

    /// Text with LaTeX (`\(…\)`, `\[…\]`, `$…$`, `$$…$$`, environments) as readable symbols, on one line. A formula left
    /// open by truncation is shown up to its last complete part; truncated prose up to its last whole word.
    static func readable(_ text: String, truncated: Bool = false, wholeWord: Bool = false) -> String {
        guard text.contains("\\") || text.contains("$") else {
            return finish(collapse(text), truncated: truncated, endsInPartialWord: !wholeWord)
        }
        var output = "", endsInProse = true
        for segment in segments(text) {
            switch segment {
            case .text(let value): output += value; endsInProse = true
            case .math(let body, let display, let closed):
                let formula = formula(body, cut: !closed)
                output += display ? " \(formula) " : formula; endsInProse = false
            }
        }
        return finish(collapse(output), truncated: truncated, endsInPartialWord: endsInProse && !wholeWord)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "…" where the saved title was cut, after the last whole word when it ends in prose.
    private static func finish(_ text: String, truncated: Bool, endsInPartialWord: Bool) -> String {
        guard truncated, !text.isEmpty, !text.hasSuffix("…") else { return text }
        var result = Substring(text)
        if endsInPartialWord, let space = result.lastIndex(of: " "), result.distance(from: space, to: result.endIndex) <= 24 {
            result = result[..<space]
        }
        while let last = result.last, ",;:".contains(last) || last.isWhitespace { result = result.dropLast() }
        return result + "…"
    }

    // MARK: Math segments

    enum Segment: Equatable { case text(String), math(String, display: Bool, closed: Bool) }

    /// Splits text into prose and formulas. `\[`, `\(`, `$$` and `\begin{…}` left open (a title cut short) run to the
    /// end; a single `$` is math only when closed, as in Pandoc (so "$5 and $10" stays prose).
    static func segments(_ text: String) -> [Segment] {
        let c = Array(text)
        var result: [Segment] = [], prose = "", i = 0
        func starts(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            return index + t.count <= c.count && Array(c[index..<index + t.count]) == t
        }
        func find(_ token: String, from index: Int) -> Int? {
            var j = index
            while j < c.count { if starts(token, at: j) { return j }; j += 1 }
            return nil
        }
        func emit(_ segment: Segment) {
            if !prose.isEmpty { result.append(.text(prose)); prose = "" }
            result.append(segment)
        }
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "[" || c[i + 1] == "(" {
                let closer = c[i + 1] == "[" ? "\\]" : "\\)", display = c[i + 1] == "["
                if let end = find(closer, from: i + 2) {
                    emit(.math(String(c[(i + 2)..<end]), display: display, closed: true)); i = end + 2
                } else { emit(.math(String(c[(i + 2)...]), display: display, closed: false)); i = c.count }
            } else if starts("\\begin{", at: i) {
                let nameStart = i + 7
                if let nameEnd = find("}", from: nameStart), let end = find("\\end{" + String(c[nameStart..<nameEnd]) + "}", from: nameEnd) {
                    let after = end + 6 + (nameEnd - nameStart)
                    emit(.math(String(c[i..<after]), display: true, closed: true)); i = after
                } else { emit(.math(String(c[i...]), display: true, closed: false)); i = c.count }
            } else if starts("$$", at: i) {
                if let end = find("$$", from: i + 2) {
                    emit(.math(String(c[(i + 2)..<end]), display: true, closed: true)); i = end + 2
                } else { emit(.math(String(c[(i + 2)...]), display: true, closed: false)); i = c.count }
            } else if c[i] == "$", i + 1 < c.count, !c[i + 1].isWhitespace,
                      let end = (i + 1 ..< c.count).first(where: { j in
                          c[j] == "$" && !c[j - 1].isWhitespace && c[j - 1] != "\\" && (j + 1 == c.count || !c[j + 1].isNumber)
                      }) {
                emit(.math(String(c[(i + 1)..<end]), display: false, closed: true)); i = end + 1
            } else if c[i] == "\\", i + 1 < c.count, "$%&_#{}".contains(c[i + 1]) {
                prose.append(c[i + 1]); i += 2   // an escaped character in prose
            } else { prose.append(c[i]); i += 1 }
        }
        if !prose.isEmpty { result.append(.text(prose)) }
        return result
    }

    // MARK: Formulas

    /// One formula as a line of text: structure first (environments, fractions, roots, accents, sub- and superscripts,
    /// innermost groups first), then the All chats preview's symbols (`ChatPreview.readableMath`).
    static func formula(_ latex: String, cut: Bool = false) -> String {
        var s = cut ? completePart(latex) : latex
        // Layout-only commands and environments.
        s = s.replacing(/\\(?:begin|end)\s*\{[^{}]*\}/, with: " ")
        s = s.replacing(/\\(?:label|tag)\*?\s*\{[^{}]*\}/, with: "")
        s = s.replacing(/\\(?:nonumber|notag|displaystyle|textstyle|scriptstyle|scriptscriptstyle|limits|nolimits|[bB]ig{1,2}[lrm]?)(?![A-Za-z])/, with: "")
        s = s.replacing(/\\(?:quad|qquad)(?![A-Za-z])/, with: " ")
        s = s.replacing(/\\\\|&/, with: " ")
        // Mathpix spaces every token ("\frac { 1 } { \sqrt { d _ { k } } }"); join groups to their commands (a space
        // after a closing brace stays: "} / (").
        s = s.replacing(/\s+([{}^_])/) { String($0.output.1) }
        s = s.replacing(/([{^_])\s+/) { String($0.output.1) }
        // Unbraced scripts (`d_k`) before braced ones, whose longer results (`_simple`) are final.
        s = s.replacing(/([_^])([A-Za-z0-9])/) { script(String($0.output.2), sub: $0.output.1 == "_") }
        for _ in 0..<8 {
            let before = s
            s = s.replacing(/\\(?:mathrm|mathbf|mathit|mathsf|mathtt|mathcal|mathbb|mathfrak|text|textrm|textbf|textit|operatorname\*?|bm|boldsymbol|mathop)\{([^{}]*)\}/) {
                String($0.output.1)
            }
            s = s.replacing(/\\(hat|widehat|tilde|widetilde|bar|overline|vec|dot|ddot)\{([^{}]*)\}/) { match in
                accented(String(match.output.2), String(match.output.1))
            }
            s = s.replacing(/\\sqrt\{([^{}]*)\}/) { "√" + grouped(String($0.output.1)) }
            s = s.replacing(/\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}/) { grouped(String($0.output.1)) + "/" + grouped(String($0.output.2)) }
            s = s.replacing(/([_^])\{([^{}]*)\}/) { script(String($0.output.2), sub: $0.output.1 == "_") }
            if s == before { break }
        }
        s = ChatPreview.readableMath(s)
        s = collapse(s)
        s = s.replacing(/([(\[])\s+/) { String($0.output.1) }
        s = s.replacing(/\s+([)\],;.])/) { String($0.output.1) }
        return s
    }

    /// The part of a formula cut off by truncation that is complete: a trailing half-typed command dropped, and an
    /// unclosed group cut back to the command (and its earlier arguments) that opened it.
    static func completePart(_ latex: String) -> String {
        var c = Array(latex.replacing(/\\[A-Za-z]*$/, with: ""))
        var open: [Int] = []
        for (i, ch) in c.enumerated() where i == 0 || c[i - 1] != "\\" {
            if ch == "{" { open.append(i) } else if ch == "}" { _ = open.popLast() }
        }
        guard var cut = open.first else { return String(c) }
        while cut > 0 {
            var p = cut - 1
            while p > 0, c[p] == " " { p -= 1 }
            if c[p] == "}" {   // an earlier argument of the same command
                var depth = 0, q = p
                while q >= 0 { if c[q] == "}" { depth += 1 } else if c[q] == "{" { depth -= 1; if depth == 0 { break } }; q -= 1 }
                guard q >= 0 else { break }
                cut = q
            } else if c[p].isLetter {
                var q = p
                while q > 0, c[q - 1].isLetter { q -= 1 }
                if q > 0, c[q - 1] == "\\" { cut = q - 1 }
                break
            } else if c[p] == "_" || c[p] == "^" { cut = p; break }
            else { break }
        }
        c.removeSubrange(cut...)
        return String(c)
    }

    /// One token as is, several in parentheses: `√d`, `√(a + b)`, `(Q K)/√d`.
    private static func grouped(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        let simple = !value.contains(where: { " +-−=<>,/".contains($0) })
        return simple ? value : "(\(value))"
    }

    /// A combining accent on one letter (x̂, ṽ); the bare letters otherwise.
    private static func accented(_ base: String, _ accent: String) -> String {
        let marks: [String: String] = ["hat": "\u{302}", "widehat": "\u{302}", "tilde": "\u{303}", "widetilde": "\u{303}",
                                       "bar": "\u{304}", "overline": "\u{304}", "vec": "\u{20D7}", "dot": "\u{307}", "ddot": "\u{308}"]
        let value = base.trimmingCharacters(in: .whitespaces)
        guard value.count == 1, value.first?.isLetter == true, let mark = marks[accent] else { return value }
        return value + mark
    }

    /// Numeric sub- and superscripts and the transpose as Unicode (x₀, x², x⁻¹, Kᵀ); letters as the previews write them
    /// (d_k, as `ChatPreview` does), longer ones as `_simple` or `_(i=1)`.
    private static func script(_ content: String, sub: Bool) -> String {
        let value = content.trimmingCharacters(in: .whitespaces)
        let table = sub ? subscripts : superscripts
        if !value.isEmpty, value.count <= 2 || value.allSatisfy(\.isNumber) {
            let mapped = value.compactMap { table[$0] }
            if mapped.count == value.count { return String(mapped) }
        }
        return (sub ? "_" : "^") + grouped(value)
    }

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋",
    ]
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻",
        "T": "ᵀ", "*": "*",
    ]
}

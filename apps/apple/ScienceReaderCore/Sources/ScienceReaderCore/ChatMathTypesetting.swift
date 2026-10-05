import Foundation

/// Rewrites LaTeX that SwiftMath (the native chat typesetter) cannot parse
/// into equivalent or near-equivalent forms it can, so one unsupported
/// command does not turn a whole formula back into source text. Presentation
/// only: stored message text is never changed, and anything still unsupported
/// falls back to the visible source as before.
public enum ChatMathTypesetting {
    /// Commands replaced by a fixed string (Unicode symbols render natively).
    private static let symbols: [String: String] = [
        "dfrac": "\\frac", "tfrac": "\\frac", "boldsymbol": "\\bm", "lVert": "\\Vert", "rVert": "\\Vert",
        "lvert": "|", "rvert": "|", "middle": "", "implies": "\\Longrightarrow", "impliedby": "\\Longleftarrow",
        "triangleq": "≜", "coloneqq": "≔", "eqqcolon": "≕", "lesssim": "≲", "gtrsim": "≳", "lessapprox": "⪅",
        "gtrapprox": "⪆", "iint": "∬", "iiint": "∭", "intercal": "⊺", "nmid": "∤", "leqslant": "\\leq",
        "geqslant": "\\geq", "varnothing": "\\emptyset", "dots": "\\ldots", "dotsc": "\\ldots", "dotsb": "\\cdots",
        "dotsm": "\\cdots", "bmod": "\\;\\mathrm{mod}\\;", "nonumber": "", "notag": "", "limits": "", "nolimits": "",
    ]
    /// Delimiter sizing commands; the delimiter itself is kept.
    private static let sizing: Set<String> = [
        "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl", "bigr", "Bigr", "biggr", "Biggr", "bigm", "Bigm", "biggm", "Biggm",
    ]
    /// One-argument commands: (prefix, suffix) around the rewritten argument,
    /// or nil to drop the argument.
    private static let unary: [String: (String, String)?] = [
        "operatorname": ("\\mathrm{", "}"), "mathop": ("{", "}"), "mathbin": ("{", "}"), "mathrel": ("{", "}"),
        "boxed": ("{", "}"), "cancel": ("{", "}"), "emph": ("\\textit{", "}"), "mathds": ("\\mathbb{", "}"),
        "mathscr": ("\\mathcal{", "}"), "underbrace": ("\\underline{", "}"), "overbrace": ("\\overline{", "}"),
        "xrightarrow": ("\\rightarrow^{", "}"), "xleftarrow": ("\\leftarrow^{", "}"), "tag": ("\\qquad (", ")"),
        "pmod": ("\\;(\\mathrm{mod}\\;", ")"), "hspace": nil, "label": nil, "phantom": nil, "vphantom": nil, "hphantom": nil,
    ]
    /// Two-argument stacking commands: \underset{a}{b} → {b}_{a}.
    private static let stacked: [String: String] = ["underset": "_", "overset": "^", "stackrel": "^"]
    private static let alignLike: Set<String> = ["align", "align*", "aligned", "flalign", "flalign*", "alignat", "alignat*", "eqnarray", "eqnarray*"]
    private static let gatherLike: Set<String> = ["gather", "gather*", "gathered", "multline", "multline*", "array"]
    private static let dropped: Set<String> = ["equation", "equation*", "displaymath"]

    public static func prepare(_ latex: String) -> String {
        rewriteEnvironments(rewrite(latex))
    }

    // MARK: Commands

    private static func rewrite(_ source: String) -> String {
        let chars = Array(source)
        var out = "", i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else { out.append(c); i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
            guard j > i + 1 else { out.append(c); out.append(chars[i + 1]); i += 2; continue } // \{, \\, \, …
            let name = String(chars[(i + 1)..<j])
            if name == "not", let next = nextToken(chars, from: j) {
                if next.text == "=" { out += "\\neq"; i = next.end; continue }
                if next.text == "\\in" { out += "\\notin"; i = next.end; continue }
            }
            if sizing.contains(name) { i = j; continue }
            if let replacement = symbols[name] {
                out += replacement
                i = j
                continue
            }
            var k = j
            if k < chars.count, chars[k] == "*" { k += 1 } // \operatorname*
            if let rule = unary[name], let argument = nextToken(chars, from: k) {
                if let (prefix, suffix) = rule { out += prefix + rewrite(argument.body) + suffix }
                i = argument.end
                continue
            }
            if let script = stacked[name], let first = nextToken(chars, from: k), let second = nextToken(chars, from: first.end) {
                out += "{" + rewrite(second.body) + "}" + script + "{" + rewrite(first.body) + "}"
                i = second.end
                continue
            }
            out += "\\" + name
            i = j
        }
        return out
    }

    /// The next argument: a balanced `{…}` group (body without braces), a
    /// control sequence, or one character. Nil at the end or on imbalance.
    private static func nextToken(_ chars: [Character], from start: Int) -> (text: String, body: String, end: Int)? {
        var i = start
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return nil }
        if chars[i] == "{" {
            var depth = 0, j = i
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j < chars.count else { return nil }
            let body = String(chars[(i + 1)..<j])
            return ("{" + body + "}", body, j + 1)
        }
        if chars[i] == "\\" {
            var j = i + 1
            while j < chars.count, chars[j].isASCII, chars[j].isLetter { j += 1 }
            if j == i + 1, j < chars.count { j += 1 }
            let text = String(chars[i..<j])
            return (text, text, j)
        }
        return (String(chars[i]), String(chars[i]), i + 1)
    }

    // MARK: Environments

    private static let environment = try? NSRegularExpression(
        pattern: #"\\begin\{([a-zA-Z]+\*?)\}(\{[^{}]*\})?(.*?)\\end\{\1\}"#, options: [.dotMatchesLineSeparators])

    /// One left-to-right pass; bodies are rewritten recursively (bounded).
    private static func rewriteEnvironments(_ source: String, depth: Int = 0) -> String {
        guard depth < 4, source.contains("\\begin{"), let environment else { return source }
        var result = "", cursor = source.startIndex
        for match in environment.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let whole = Range(match.range, in: source), let nameRange = Range(match.range(at: 1), in: source),
                  let bodyRange = Range(match.range(at: 3), in: source) else { continue }
            result += source[cursor..<whole.lowerBound]
            let name = String(source[nameRange]), body = rewriteEnvironments(String(source[bodyRange]), depth: depth + 1)
            let argument = Range(match.range(at: 2), in: source).map { String(source[$0]) } ?? ""
            if dropped.contains(name) { result += body }
            else if alignLike.contains(name) { result += "\\begin{aligned}" + alignedRows(body) + "\\end{aligned}" }
            else if gatherLike.contains(name) {
                let rows = body.components(separatedBy: "\\\\").map { "\\displaystyle " + $0 }
                result += "\\begin{matrix}" + rows.joined(separator: "\\\\") + "\\end{matrix}"
            }
            else { result += "\\begin{\(name)}" + argument + body + "\\end{\(name)}" }
            cursor = whole.upperBound
        }
        return result + source[cursor...]
    }

    /// SwiftMath's `aligned` needs exactly two columns per row: a row without
    /// `&` gets one at its end, and extra column pairs become spacing.
    private static func alignedRows(_ body: String) -> String {
        body.components(separatedBy: "\\\\").map { row in
            var parts = splitColumns(row)
            if parts.count == 1 { parts.append("") }
            if parts.count > 2 { parts = [parts[0], parts[1...].joined(separator: "\\quad ")] }
            return parts.joined(separator: "&")
        }.joined(separator: "\\\\")
    }

    private static func splitColumns(_ row: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0, escaped = false
        for c in row {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { current.append(c); escaped = true; continue }
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1 }
            if c == "&", depth == 0 { parts.append(current); current = ""; continue }
            current.append(c)
        }
        parts.append(current)
        return parts
    }
}

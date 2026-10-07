import Foundation

/// A formula as readable plain text ("Copy as text"): Greek letters and common
/// symbols as Unicode, simple sub/superscripts as Unicode scripts (else `_x`, `^(…)`),
/// `\frac{a}{b}` as `a/b`, `\sqrt{x}` as `√x`, style commands dropped. An
/// approximation for pasting into prose; Copy LaTeX keeps the exact source.
public enum ChatMathText {
    public static func plain(_ latex: String) -> String {
        var parser = Parser(Array(latex.unicodeScalars).map(Character.init))
        let text = parser.sequence(until: nil)
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "sim": "∼", "simeq": "≃", "equiv": "≡", "propto": "∝", "infty": "∞", "partial": "∂", "nabla": "∇",
        "sum": "∑", "prod": "∏", "int": "∫", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪", "cap": "∩",
        "forall": "∀", "exists": "∃", "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "mapsto": "↦", "top": "ᵀ", "intercal": "ᵀ", "ell": "ℓ", "ldots": "…", "cdots": "⋯", "dots": "…",
        "langle": "⟨", "rangle": "⟩", "lVert": "‖", "rVert": "‖", "Vert": "‖", "|": "‖", "mid": "|", "circ": "∘", "odot": "⊙",
        "otimes": "⊗", "oplus": "⊕", "star": "⋆", "ast": "∗", "prime": "′", "lesssim": "≲", "gtrsim": "≳", "ll": "≪", "gg": "≫",
        "log": "log", "exp": "exp", "ln": "ln", "max": "max", "min": "min", "arg": "arg", "sin": "sin", "cos": "cos", "tanh": "tanh",
        "lim": "lim", "sup": "sup", "inf": "inf", "det": "det", "Pr": "Pr", "E": "E",
        ",": " ", ";": " ", ":": " ", "!": "", " ": " ", "quad": " ", "qquad": " ", "{": "{", "}": "}", "%": "%", "_": "_", "&": "&", "#": "#", "$": "$",
    ]
    /// Commands whose argument is shown as is (fonts, text, operator names).
    static let styles: Set<String> = ["mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak", "boldsymbol", "bm",
                                      "text", "textrm", "textbf", "textit", "operatorname", "mbox", "hat", "bar", "tilde", "vec", "overline", "widehat", "widetilde"]
    /// Commands that only size or space and are dropped.
    static let dropped: Set<String> = ["left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "displaystyle", "textstyle",
                                       "limits", "nolimits"]
    static let superscripts: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "T": "ᵀ", "t": "ᵗ", "k": "ᵏ", "*": "*", "′": "′", "ᵀ": "ᵀ"]
    static let subscripts: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"]

    private struct Parser {
        let chars: [Character]
        var index = 0
        var depth = 0
        init(_ chars: [Character]) { self.chars = chars }

        mutating func sequence(until close: Character?) -> String {
            var out = ""
            depth += 1; defer { depth -= 1 }
            guard depth < 40 else { index = chars.count; return out }
            while index < chars.count {
                let c = chars[index]
                if let close, c == close { index += 1; return out }
                switch c {
                case "{": index += 1; out += sequence(until: "}")
                case "\\": out += command()
                case "^": index += 1; out += script(superscripts, marker: "^")
                case "_": index += 1; out += script(subscripts, marker: "_")
                case "~": index += 1; out += " "
                case "&": index += 1; out += " "
                default: index += 1; out.append(c)
                }
            }
            return out
        }

        /// One argument: a braced group, a command or a single character.
        mutating func argument() -> String {
            while index < chars.count, chars[index] == " " { index += 1 }
            guard index < chars.count else { return "" }
            switch chars[index] {
            case "{": index += 1; return sequence(until: "}")
            case "\\": return command()
            default: let c = chars[index]; index += 1; return String(c)
            }
        }

        mutating func script(_ table: [Character: Character], marker: Character) -> String {
            let body = argument()
            if !body.isEmpty, body.allSatisfy({ table[$0] != nil }) { return String(body.map { table[$0]! }) }
            return body.count == 1 ? "\(marker)\(body)" : "\(marker)(\(body))"
        }

        mutating func command() -> String {
            index += 1 // backslash
            guard index < chars.count else { return "" }
            var name = ""
            if chars[index].isLetter {
                while index < chars.count, chars[index].isLetter { name.append(chars[index]); index += 1 }
            } else {
                name = String(chars[index]); index += 1
            }
            if name == "frac" || name == "dfrac" || name == "tfrac" {
                let top = argument(), bottom = argument()
                return "\(group(top))/\(group(bottom))"
            }
            if name == "sqrt" { return "√" + group(argument()) }
            if name == "\\" { return "; " }
            if ChatMathText.styles.contains(name) { return argument() }
            if ChatMathText.dropped.contains(name) {
                // \left( keeps its delimiter.
                if index < chars.count, ["left", "right", "bigl", "bigr", "Bigl", "Bigr", "big", "Big"].contains(name) {
                    if chars[index] == "." { index += 1; return "" }
                    if chars[index] == "\\" { return command() }
                    let c = chars[index]; index += 1; return String(c)
                }
                return ""
            }
            if name == "begin" || name == "end" { _ = argument(); return " " }
            return ChatMathText.symbols[name] ?? name
        }

        /// Parenthesizes anything longer than one symbol in a fraction or root.
        func group(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.count <= 1 || trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) ? trimmed : "(\(trimmed))"
        }
    }
}

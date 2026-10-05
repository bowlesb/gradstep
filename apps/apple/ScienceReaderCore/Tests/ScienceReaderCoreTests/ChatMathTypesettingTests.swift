import Testing
@testable import ScienceReaderCore

struct ChatMathTypesettingTests {
    private func prepared(_ latex: String) -> String { ChatMathTypesetting.prepare(latex) }

    @Test func supportedLatexIsUnchanged() {
        for latex in ["\\frac{a}{b}", "\\mathbb{E}_{x \\sim D}[\\log \\sigma(x)]", "\\begin{aligned} a &= b \\\\ &= c \\end{aligned}",
                      "\\left\\{ x \\right\\}", "\\begin{cases} 1 & x > 0 \\\\ 0 & \\text{otherwise} \\end{cases}", "a \\, b \\; c \\\\ d"] {
            #expect(prepared(latex) == latex)
        }
    }

    @Test func commandsBecomeSupportedEquivalents() {
        #expect(prepared("\\operatorname{softmax}(x)") == "\\mathrm{softmax}(x)")
        #expect(prepared("\\operatorname*{arg\\,max}_x f") == "\\mathrm{arg\\,max}_x f")
        #expect(prepared("\\boldsymbol{A}\\boldsymbol\\theta") == "\\bm{A}\\bm\\theta")
        #expect(prepared("\\dfrac{1}{2}\\tfrac12") == "\\frac{1}{2}\\frac12")
        #expect(prepared("\\bigl( x \\Bigr) \\lVert y \\rVert") == "( x ) \\Vert y \\Vert")
        #expect(prepared("\\underset{\\theta}{\\max} f") == "{\\max}_{\\theta} f")
        #expect(prepared("\\stackrel{\\Delta}{=}") == "{=}^{\\Delta}")
        // Symbols the app registers with the typesetter stay commands (raw Unicode would be dropped).
        #expect(prepared("g \\triangleq h, a \\lesssim b, x \\implies y") == "g \\triangleq h, a \\lesssim b, x \\Longrightarrow y")
        #expect(ChatMathTypesetting.customSymbols.allSatisfy { $0.character.unicodeScalars.count == 1 })
        #expect(prepared("i \\bmod W, a \\pmod{n}") == "i \\;\\mathrm{mod}\\; W, a \\;(\\mathrm{mod}\\;n)")
        #expect(prepared("\\underbrace{a+b}_{n} \\xrightarrow{f} c \\tag{3}\\label{eq:x}") == "\\underline{a+b}_{n} \\rightarrow^{f} c \\qquad (3)")
        #expect(prepared("a \\xrightarrow[n \\to \\infty]{d} b") == "a \\rightarrow^{d}_{n \\to \\infty} b")
        #expect(prepared("a \\not= b, c \\not\\in D, \\max\\limits_x") == "a \\neq b, c \\notin D, \\max_x")
        // Arguments are rewritten too.
        #expect(prepared("\\boxed{\\operatorname{Tr}(A)}") == "{\\mathrm{Tr}(A)}")
    }

    @Test func environmentsMatchWhatTheTypesetterAccepts() {
        #expect(prepared("\\begin{equation*} x = 1 \\end{equation*}") == " x = 1 ")
        #expect(prepared("\\begin{align*} a &= b \\\\ c \\end{align*}") == "\\begin{aligned} a &= b \\\\ c &\\end{aligned}")
        #expect(prepared("\\begin{align} a &= b & c &= d \\end{align}") == "\\begin{aligned} a &= b \\quad  c \\quad = d \\end{aligned}")
        #expect(prepared("\\begin{gather*} a \\\\ b \\end{gather*}") == "\\begin{matrix}\\displaystyle  a \\\\\\displaystyle  b \\end{matrix}")
        #expect(prepared("\\begin{array}{cl} a & b \\end{array}") == "\\begin{matrix}\\displaystyle  a & b \\end{matrix}")
        // Rows and columns split only outside nested environments; native aligned rows are kept.
        let nested = "\\begin{aligned} x &= \\begin{bmatrix}1\\\\2\\end{bmatrix} \\\\ y &= 3\\end{aligned}"
        #expect(prepared(nested) == nested)
        #expect(prepared("\\begin{align*} f &= \\begin{cases} 1 & a \\\\ 0 & b \\end{cases} \\end{align*}")
                == "\\begin{aligned} f &= \\begin{cases} 1 & a \\\\ 0 & b \\end{cases} \\end{aligned}")
        // A leading group is content except for environments that take an argument.
        #expect(prepared("\\begin{equation}{a+b}^2=c\\end{equation}") == "{a+b}^2=c")
        #expect(prepared("\\begin{eqnarray} a &=& b \\end{eqnarray}") == "\\begin{eqnarray} a &=& b \\end{eqnarray}")
        // Nested environments are rewritten inside kept ones.
        #expect(prepared("\\begin{cases} \\begin{gather*} a \\end{gather*} \\end{cases}")
                == "\\begin{cases} \\begin{matrix}\\displaystyle  a \\end{matrix} \\end{cases}")
    }

    @Test func malformedInputIsLeftForTheVisibleFallback() {
        for latex in ["\\operatorname{x", "\\underset{a}", "\\begin{align*} a &= b", "\\", "\\frac{"] {
            _ = prepared(latex) // must not crash or loop
        }
        #expect(prepared("\\operatorname{x") == "\\operatorname{x")
    }
}

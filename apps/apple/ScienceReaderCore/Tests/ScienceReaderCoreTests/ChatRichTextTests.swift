import Foundation
import Testing
@testable import ScienceReaderCore

struct ChatRichTextTests {
    @Test func paragraphsInlineAndDisplayMath() {
        let blocks = ChatRichText.parse("DPO minimizes \\(\\mathcal{L}_{\\mathrm{DPO}}\\) in Eq. (7):\n\n\\[\\mathcal{L} = -\\log \\sigma(x)\\]\n\nDone.")
        #expect(blocks == [
            .paragraph([.text("DPO minimizes "), .math("\\mathcal{L}_{\\mathrm{DPO}}"), .text(" in Eq. (7):")]),
            .displayMath("\\mathcal{L} = -\\log \\sigma(x)"),
            .paragraph([.text("Done.")]),
        ])
    }

    @Test func displayMathInsideAParagraphSplitsIt() {
        let blocks = ChatRichText.parse("The update is \\[h = W_0 x + BAx\\] where B starts at zero.")
        #expect(blocks == [.paragraph([.text("The update is")]), .displayMath("h = W_0 x + BAx"), .paragraph([.text("where B starts at zero.")])])
    }

    @Test func headingsListsTablesAndCode() {
        let source = "## Where it is\n- applied to \\(W_q\\)\n  - nested\n2. second\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```python\nx = $1\n```"
        #expect(ChatRichText.parse(source) == [
            .heading(level: 2, [.text("Where it is")]),
            .listItem(marker: "•", depth: 0, [.text("applied to "), .math("W_q")]),
            .listItem(marker: "•", depth: 1, [.text("nested")]),
            .listItem(marker: "2.", depth: 0, [.text("second")]),
            .table(ChatTable(rows: ["| a | b |", "|---|---|", "| 1 | 2 |"])!),
            .preformatted("x = $1"),
        ])
    }

    // MARK: Tables

    private func table(_ source: String, streaming: Bool = false) -> ChatTable? {
        for block in ChatRichText.parse(source, streaming: streaming) { if case .table(let table) = block { return table } }
        return nil
    }
    private func texts(_ cells: [ChatTable.Cell]) -> [String] { cells.map(\.source) }

    @Test func tableHeaderAlignmentAndInlineCells() throws {
        let source = "Compared:\n\n| Method | Loss | Win rate |\n|:---|:---:|---:|\n| **DPO** | \\(-\\log\\sigma(\\beta\\Delta)\\) | 64% |\n| `IPO` | squared | 63% |\n\nDone."
        let blocks = ChatRichText.parse(source)
        #expect(blocks.count == 3)
        #expect(blocks.first == .paragraph([.text("Compared:")]))
        #expect(blocks.last == .paragraph([.text("Done.")]))
        let parsed = try #require(table(source))
        #expect(texts(parsed.header) == ["Method", "Loss", "Win rate"])
        #expect(parsed.alignments == [.leading, .center, .trailing])
        #expect(parsed.rows.count == 2)
        #expect(parsed.rows[0][0].parts == [.text("**DPO**")])
        #expect(parsed.rows[0][1].parts == [.math("-\\log\\sigma(\\beta\\Delta)")])
        #expect(parsed.rows[1][0].parts == [.text("`IPO`")])
        #expect(parsed.spokenHeader == "Columns: Method, Loss, Win rate")
        #expect(parsed.spokenRow(0) == "Row 1: Method, DPO; Loss, -\\log\\sigma(\\beta\\Delta); Win rate, 64%")
        #expect(parsed.spokenRow(1) == "Row 2: Method, IPO; Loss, squared; Win rate, 63%")
    }

    @Test func raggedRowsArePaddedOrCut() throws {
        let parsed = try #require(table("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 | 5 |\n|  | x |"))
        #expect(parsed.rows.map(texts) == [["1", "", ""], ["1", "2", "3"], ["", "x", ""]])
        #expect(parsed.spokenRow(0) == "Row 1: a, 1", "Empty cells are not read")
        #expect(parsed.spokenRow(2) == "Row 3: b, x")
        // Rows without their closing pipe still split.
        #expect(try #require(table("| a | b\n| - | -\n| 1 | 2")).rows.map(texts) == [["1", "2"]])
    }

    @Test func escapedPipesAndPipesInsideCodeOrMathStayInTheirCell() throws {
        let parsed = try #require(table(#"""
        | Expression | Meaning |
        |---|---|
        | `a | b` | code, \| escaped |
        | \(\|w\|_2\) | norm |
        | $|x|$ and `` c`|`d `` | abs |
        | \$5 | $10 |
        """#))
        #expect(parsed.rows.map(texts) == [
            ["`a | b`", "code, | escaped"],
            [#"\(\|w\|_2\)"#, "norm"],
            ["$|x|$ and `` c`|`d ``", "abs"],
            [#"\$5"#, "$10"],
        ])
        #expect(parsed.rows[1][0].parts == [.math(#"\|w\|_2"#)], "LaTeX keeps its escaped bars inside math")
        #expect(parsed.rows[2][0].parts.first == .math("|x|"))
    }

    @Test func malformedTablesStayPipeText() {
        // No alignment row, mismatched column counts, or an invalid marker: not a table.
        for source in ["| a | b |\n| 1 | 2 |", "| a | b |\n|---|\n| 1 | 2 |", "| a | b |\n|---|-x-|\n| 1 | 2 |"] {
            #expect(ChatRichText.parse(source) == [.preformatted(source)])
        }
        let wide = "|" + (1...13).map { " c\($0) |" }.joined() + "\n|" + String(repeating: "---|", count: 13)
        #expect(ChatRichText.parse(wide) == [.preformatted(wide)], "More than 12 columns stay pipe text")
    }

    @Test func aStreamingTableStaysPipeTextUntilItIsComplete() {
        let rows = "| a | b |\n|---|---|\n| 1 | 2 |"
        let start = "Results:\n\n"
        // Still growing: the rows (and an unfinished next line) stay monospaced text.
        for partial in [start + "| a |", start + "| a | b |\n|--", start + rows, start + rows + "\n", start + rows + "\n|", start + rows + "\n| 3"] {
            let blocks = ChatRichText.parse(partial, streaming: true)
            #expect(blocks.count == 2)
            guard case .preformatted = blocks.last else { Issue.record("\(partial) rendered \(blocks)"); continue }
        }
        // A following line completes it, even while streaming.
        #expect(table(start + rows + "\n\nNext", streaming: true) != nil)
        #expect(table(start + rows + "\nN", streaming: true) != nil)
        // At the very end of the finished answer it is complete too.
        #expect(table(start + rows) != nil)
        #expect(table(start + rows + "\n") != nil)
        // A table before display math or sources is complete while streaming.
        #expect(table(rows + "\n\\[x\\]", streaming: true) != nil)
        #expect(table(rows + "\n\nSources:\n1. https://example.org/a", streaming: true) != nil)
    }

    @Test func spokenTextReadsTablesAsRows() {
        let spoken = ChatRichText.spokenText(ChatRichText.parse("Intro \\(x\\)\n\n| a | b |\n|---|---|\n| 1 | 2 |"))
        #expect(spoken == "Intro \\(x\\)\n\nColumns: a, b\nRow 1: a, 1; b, 2")
    }

    // MARK: Owner feedback 2026-10-07

    @Test func emphasisAroundInlineMathApplies() throws {
        // `**$n = 0$:**` used to show its asterisks: emphasis is parsed across the formula.
        let runs = ChatRichText.styledRuns(ChatRichText.inline("**$n = 0$:** the base case, *with \\(x\\) here*, `code`"))
        guard case .math(let latex, let intent) = runs.first else { Issue.record("\(runs)"); return }
        #expect(latex == "n = 0")
        #expect(intent.contains(.stronglyEmphasized))
        let texts = runs.compactMap { run -> (String, InlinePresentationIntent)? in
            if case .text(let text) = run { return (String(text.characters), text.inlinePresentationIntent ?? []) }
            return nil
        }
        #expect(texts.map(\.0).joined() == ": the base case, with  here, code", "No Markdown markers remain")
        #expect(texts.first.map { $0.1.contains(.stronglyEmphasized) } == true)
        #expect(texts.first(where: { $0.0.hasPrefix("with") }).map { $0.1.contains(.emphasized) } == true)
        #expect(texts.last.map { $0.1.contains(.code) } == true)
        #expect(runs.filter { if case .math = $0 { true } else { false } }.count == 2)
        // Plain text with LaTeX backslashes and inert links is unchanged in meaning.
        let plain = ChatRichText.styledRuns([.text("see [the paper](https://example.org) and \\{x\\}")])
        let joined = plain.map { run -> String in if case .text(let text) = run { String(text.characters) } else { "" } }.joined()
        #expect(joined == "see the paper (https://example.org) and \\{x\\}")
        #expect(plain.allSatisfy { if case .text(let text) = $0 { text.runs.allSatisfy { $0.link == nil } } else { false } }, "Links stay inert")
    }

    @Test func aLeadingAnswerLabelIsNotShown() {
        for text in ["**Answer:** DPO is simpler.", "Answer: DPO is simpler.", "**Answer**: DPO is simpler.", "## Answer:\nDPO is simpler.",
                     "  __answer:__\n\nDPO is simpler."] {
            #expect(ChatRichText.withoutAnswerLabel(text) == "DPO is simpler.", "\(text)")
        }
        for text in ["The answer: DPO.", "Answering this: DPO.", "**Answers differ:** yes"] {
            #expect(ChatRichText.withoutAnswerLabel(text) == text)
        }
    }

    @Test func formulasCopyAsReadableText() {
        #expect(ChatMathText.plain(#"\mathrm{softmax}\left(\frac{QK^\top}{\sqrt{d_k}}\right)V"#) == "softmax(QKᵀ/(√dₖ))V")
        #expect(ChatMathText.plain(#"\alpha_t \leq \beta^{2}"#) == "αₜ ≤ β²")
        #expect(ChatMathText.plain(#"-\log \sigma(\beta \Delta_\theta)"#) == "-log σ(β Δ_θ)")
        #expect(ChatMathText.plain(#"\|w\|_2"#) == "‖w‖₂")
        #expect(ChatMathText.plain(#"\sum_{i=1}^{n} x_i"#) == "∑ᵢ₌₁ⁿ xᵢ")
        #expect(ChatMathText.plain(String(repeating: "{", count: 500)).isEmpty, "Deep nesting is bounded")
    }

    @Test func dollarsAreConservative() {
        #expect(ChatRichText.inline("costs $5 and $10 today") == [.text("costs $5 and $10 today")])
        #expect(ChatRichText.inline("with $x^2$ here") == [.text("with "), .math("x^2"), .text(" here")])
        #expect(ChatRichText.inline("escaped \\$x$ stays") == [.text("escaped \\$x$ stays")])
        #expect(ChatRichText.inline("`code \\(x\\)` text") == [.text("`code \\(x\\)` text")])
    }

    @Test func unclosedMathStaysLiteralWhileStreaming() {
        #expect(ChatRichText.parse("Partial \\(\\frac{a}{") == [.paragraph([.text("Partial \\(\\frac{a}{")])])
        #expect(ChatRichText.parse("Start \\[x =") == [.paragraph([.text("Start \\[x =")])])
        #expect(ChatRichText.parse("```\nopen fence") == [.paragraph([.text("```\nopen fence")])])
    }

    @Test func displayDollarMath() {
        #expect(ChatRichText.parse("$$E = mc^2$$") == [.displayMath("E = mc^2")])
    }

    @Test func trailingSourcesBecomeASourcesBlock() throws {
        let text = "IPO generalizes DPO.\n\nSources:\n1. A General Theoretical Paradigm — https://arxiv.org/abs/2310.12036\n2. https://example.org/blog"
        let blocks = ChatRichText.parse(text)
        #expect(blocks.first == .paragraph([.text("IPO generalizes DPO.")]))
        guard case .sources(let sources) = blocks.last else { Issue.record("no sources block"); return }
        #expect(sources == [ChatSource(title: "A General Theoretical Paradigm", url: URL(string: "https://arxiv.org/abs/2310.12036")!),
                            ChatSource(title: nil, url: URL(string: "https://example.org/blog")!)])
        // Anything not in the exact format stays text: http, prose lines, too many entries.
        for invalid in ["x\n\nSources:\n1. http://example.org", "x\n\nSources:\nSee the paper.",
                        "x\n\nSources:\n" + (1...9).map { "\($0). https://e.org/\($0)" }.joined(separator: "\n")] {
            #expect(ChatRichText.trailingSources(invalid) == nil)
        }
    }

    @Test func linksAreShownNotFollowed() {
        #expect(ChatRichText.inertLinks("see [the derivation](https://evil.example/?q=secret) now") == "see the derivation (https://evil.example/?q=secret) now")
        #expect(ChatRichText.inertLinks("<https://arxiv.org/abs/2305.18290>") == "https://arxiv.org/abs/2305.18290")
        #expect(ChatRichText.inertLinks("no links \\(x\\)") == "no links \\(x\\)")
    }
}

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
            .preformatted("| a | b |\n|---|---|\n| 1 | 2 |"),
            .preformatted("x = $1"),
        ])
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

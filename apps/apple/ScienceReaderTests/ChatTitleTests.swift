import Foundation
import ScienceReaderCore
import XCTest
@testable import ScienceReader

/// Short conversation titles (owner feedback, build 14 #7): a selection action's prompt becomes its label and the
/// selected passage, LaTeX reads as symbols, and everything else is the question as asked. Titles are saved as the
/// first 100 characters of the first question, so most cases go through `saved(_:)`.
final class ChatTitleTests: XCTestCase {
    /// What a conversation keeps as its title (`ReaderModel`: the trimmed question's first 100 characters).
    private func saved(_ question: String) -> String { String(question.prefix(ChatTitle.savedLimit)) }

    func testEveryCurrentSelectionPromptBecomesItsLabelAndPassage() {
        for action in SelectionAction.allCases {
            XCTAssertEqual(ChatTitle.display(saved(action.prompt("scaled dot-product attention"))), "\(action.title) · scaled dot-product attention")
        }
        XCTAssertEqual(SelectionAction.define.prompt("x"), "Explain in plain terms, including any symbols: x", "The prompt the server receives is unchanged")
        XCTAssertEqual(ChatTitle.display("Explain in plain terms, including any symbols:"), "Explain", "No passage")
    }

    func testOwnersHistoryFromBuild14() {
        // The display equation as the reader resolves it, cut at 100 characters inside the formula.
        let equation = "\\[\\begin{equation*}\n\\operatorname{Attention}(Q, K, V)=\\operatorname{softmax}\\left(\\frac{Q K^{T}}{\\sqrt{d_{k}}}\\right) V\n\\end{equation*}\\]"
        XCTAssertEqual(ChatTitle.display(saved("Explain in plain terms, including any symbols: " + equation)), "Explain · Attention(Q, K, V)…")
        XCTAssertEqual(ChatTitle.display(SelectionAction.define.prompt(equation)), "Explain · Attention(Q, K, V)=softmax((Q Kᵀ)/√d_k) V",
                       "Uncut (longer than a saved title)")
        // Earlier wordings, still in history; Mathpix's spaced LaTeX.
        XCTAssertEqual(ChatTitle.display(saved("Define this in the context of the paper: \\(\\frac { 1 } { \\sqrt { d _ { k } } }\\)")), "Define · 1/√d_k")
        XCTAssertEqual(ChatTitle.display(saved("Find related research and explain the connections: \\[\\begin{equation*}\n\\mathcal{L}_{\\mathrm{DPO}}(\\pi_{\\theta}; \\pi_{\\mathrm{ref}}) = -\\mathbb{E}_{(x, y_w, y_l) \\sim \\mathcal{D}}")),
                       "Related · L_DPO(…", "Cut inside `\\pi`: the half command is dropped")
        XCTAssertEqual(ChatTitle.display(saved("Find and add the paper referenced in this passage: [3] T. D. Lee and G. C. Wick. Physical Review D, 2(6):1033, 1970.")),
                       "Add paper · [3] T. D. Lee and G. C. Wick. Physical Review D…", "Cut at a space: the last word is whole")
        XCTAssertEqual(ChatTitle.display(saved("Find and add the paper referenced in this passage: Gerald E Farin. Curves and surfaces for CAGD: a practical guide. Morgan Kaufmann, 2002.")),
                       "Add paper · Gerald E Farin. Curves and surfaces for CAGD: a…", "Cut inside “practical”")
    }

    func testEarlierPromptWordings() {
        let adam = "Define this in the context of the paper: \\(\\hat { m } _ { t } / ( \\sqrt { \\hat { v } _ { t } } + \\epsilon )\\)"
        XCTAssertEqual(ChatTitle.display(adam), "Define · m̂_t / (√v̂_t + ε)")
        XCTAssertEqual(ChatTitle.display(saved(adam)), "Define · m̂_t / (√v̂_t +…", "Cut inside `\\epsilon`")
        XCTAssertEqual(ChatTitle.display(saved("Explain why this passage matters to the paper: the reward is implicit")), "Why it matters · the reward is implicit")
        XCTAssertEqual(ChatTitle.display(saved("Why does this matter to the paper's method and results? We find it beneficial to sample quality to train on the simplified objective \\(L_{\\text{simple}}\\)")),
                       "Why it matters · We find it beneficial to sample quality to…")
        XCTAssertEqual(ChatTitle.display(saved("Find papers related to this passage — earlier work it builds on and recent follow-ups — with links: LoRA")),
                       "Related", "The prompt fills the saved title; the passage was cut off")
        XCTAssertEqual(ChatTitle.display(saved("Explain this in plain terms, in the context of this paper (for notation or an equation, say what each symbol means): $x$")),
                       "Explain", "An earlier prompt longer than the saved title")
    }

    /// The passage's paragraph marker travels with the question (owner, build 42), never into its title.
    func testTheParagraphMarkerStaysOutOfTheTitle() {
        XCTAssertEqual(ChatTitle.display("Explain in plain terms, including any symbols: parameters φ are optimized alongside [¶24]"),
                       "Explain · parameters φ are optimized alongside")
        XCTAssertEqual(ChatTitle.display("Why does this matter to the paper's method and results? the critic [¶3]"), "Why it matters · the critic")
        XCTAssertEqual(ChatTitle.display("What is [¶24] about?"), "What is [¶24] about?", "A marker inside a question is its text")
    }

    func testOtherQuestionsStayAsAsked() {
        XCTAssertEqual(ChatTitle.display("Why scale the dot products by the square root of d_k?"), "Why scale the dot products by the square root of d_k?")
        XCTAssertEqual(ChatTitle.display("Why scale by $\\sqrt{d_k}$?"), "Why scale by √d_k?")
        XCTAssertEqual(ChatTitle.display("It costs $5 and $10 a month"), "It costs $5 and $10 a month", "Dollar amounts are not math")
        XCTAssertEqual(ChatTitle.display("Can you explain in plain terms, including any symbols: x"), "Can you explain in plain terms, including any symbols: x")
        XCTAssertEqual(ChatTitle.display("  Two\nlines  "), "Two lines")
        XCTAssertEqual(ChatTitle.display(""), "")
    }

    func testFormulasReadAsSymbols() {
        XCTAssertEqual(ChatTitle.formula("z = \\mu + \\sigma \\odot \\epsilon"), "z = μ + σ ⊙ ε")
        XCTAssertEqual(ChatTitle.formula("\\sum_{i=1}^{n} x_i^2 + W^{-1}"), "∑_(i=1)^n x_i² + W⁻¹")
        XCTAssertEqual(ChatTitle.formula("\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}"), "a = b c = d")
        XCTAssertEqual(ChatTitle.formula("\\tilde{x} \\in \\mathbb{R}^{d}"), "x̃ ∈ R^d")
        XCTAssertEqual(ChatTitle.formula("\\mathcal{L}_{\\mathrm{DPO}}(\\pi_{\\theta}; \\pi_{\\mathrm{ref}}) = -\\mathbb{E}_{(x, y_w, y_l) \\sim \\mathcal{D}}"),
                       "L_DPO(π_θ; π_ref) = -E_((x, y_w, y_l) ∼ D)")
        // Cut off mid-formula: the last complete part.
        XCTAssertEqual(ChatTitle.formula("\\operatorname{softmax}\\left(\\frac{Q K^{T}}{\\sqrt{d_", cut: true), "softmax(")
        XCTAssertEqual(ChatTitle.formula("\\alpha + \\operatorna", cut: true), "α +")
    }

    func testAllChatsUsesAndSearchesTheShortTitle() {
        let summary = ConversationSummary(id: UUID(), title: saved("Why does this matter to the paper's method and results? Equation 3"),
                                          documentID: nil, messageCount: 2, startedAt: nil, lastUsedAt: nil, lastArrival: 0,
                                          latestAnswer: nil, questions: "Why does this matter to the paper's method and results? Equation 3")
        let row = ChatHistoryRow(summary: summary, paperTitle: nil)
        XCTAssertEqual(row.title, "Why it matters · Equation 3")
        XCTAssertEqual(ChatHistoryQuery.rows([summary], paperTitles: [:], filter: .all, search: "matters", sort: .default).count, 1,
                       "The label shown can be searched for")
        XCTAssertEqual(ChatHistoryRow(summary: ConversationSummary(id: UUID(), title: " ", documentID: nil, messageCount: 0, startedAt: nil,
                                                                    lastUsedAt: nil, lastArrival: 0, latestAnswer: nil, questions: ""),
                                      paperTitle: nil).title, "Untitled conversation")
    }

    /// Explain on one equation (owner request 2026-10-07): the legacy app's equation prompt, shortened, with the
    /// formula first so the title still reads "Explain · ‹formula›".
    func testExplainingOneEquationUsesTheEquationPrompt() {
        let equation = "\\[\\mathcal{L}_{\\text{simple}} = \\mathbb{E}_{t, x_0, \\epsilon}\\left[\\|\\epsilon - \\epsilon_\\theta(x_t, t)\\|^2\\right]\\]"
        XCTAssertEqual(SelectionAction.define.prompt(equation),
                       "Explain this equation: \\[\\mathcal{L}_{\\text{simple}} = \\mathbb{E}_{t, x_0, \\epsilon}\\left[\\|\\epsilon - \\epsilon_\\theta(x_t, t)\\|^2\\right]\\]"
                       + "\n\nBriefly cover the background needed to read it, its overall message, what each symbol means, and how its notation compares with common ML conventions.")
        let long = ChatTitle.display(saved(SelectionAction.define.prompt(equation)))
        XCTAssertTrue(long.hasPrefix("Explain · L_simple = E_(t, x₀, ε)") && long.hasSuffix("…"), "Cut inside the formula: \(long)")
        // Saved cut inside the instructions: the formula is whole, so no "…".
        let forward = "\\[x_t = \\sqrt{\\bar{\\alpha}_t}\\, x_0 + \\sqrt{1 - \\bar{\\alpha}_t}\\, \\epsilon\\]"
        XCTAssertTrue(SelectionAction.define.prompt(forward).count > ChatTitle.savedLimit)
        let title = ChatTitle.display(saved(SelectionAction.define.prompt(forward)))
        XCTAssertTrue(title.hasPrefix("Explain · x_t = √"), title)
        XCTAssertFalse(title.contains("Briefly") || title.contains("\\") || title.hasSuffix("…"), title)
        XCTAssertEqual(ChatTitle.display(SelectionAction.define.prompt("\\(z = \\mu + \\sigma \\odot \\epsilon\\)")), "Explain · z = μ + σ ⊙ ε",
                       "Uncut: the instructions are left out")
        XCTAssertEqual(ChatTitle.display(saved(SelectionAction.define.prompt("\\(a = b\\)") + "\n")), "Explain · a = b")
        // Cut inside a long formula: its start, as before.
        let attention = "\\[\\begin{equation*}\n\\operatorname{Attention}(Q, K, V)=\\operatorname{softmax}\\left(\\frac{Q K^{T}}{\\sqrt{d_{k}}}\\right) V\n\\end{equation*}\\]"
        let cut = ChatTitle.display(saved(SelectionAction.define.prompt(attention)))
        XCTAssertEqual(cut, "Explain · Attention(Q, K, V)=softmax…", "More of the formula fits than with the plain prompt")
    }

    func testOnlyASingleEquationGetsTheEquationPrompt() {
        for equation in ["\\[x_t = \\sqrt{\\alpha_t} x_0\\]", "$$p(x) \\propto e^{-E(x)}$$", "\\(a \\leq b\\),", "\\(\\theta^* = \\arg\\min L\\).",
                         "\\begin{equation}\ny = W x + b\n\\end{equation}", "\\[\\nabla f\\]"] {
            XCTAssertTrue(SelectionAction.isSingleEquation(equation), equation)
            XCTAssertTrue(SelectionAction.define.prompt(equation).hasPrefix("Explain this equation: "), equation)
        }
        for other in ["scaled dot-product attention", "\\(\\beta\\)", "\\(\\hat{m}_t / \\sqrt{\\hat{v}_t}\\)", "where \\(a = b\\)",
                      "\\(a = b\\) and \\(c = d\\)", "\\[\\]", "\\[x = ", "\\(\\neg p\\)", ""] {
            XCTAssertFalse(SelectionAction.isSingleEquation(other), other)
        }
        XCTAssertEqual(SelectionAction.define.prompt("\\(\\beta\\)"), "Explain in plain terms, including any symbols: \\(\\beta\\)",
                       "A lone symbol keeps the plain prompt")
        XCTAssertEqual(SelectionAction.relevance.prompt("\\[a = b\\]"), "Why does this matter to the paper's method and results? \\[a = b\\]",
                       "Only Explain has an equation prompt")
    }

    /// A saved title cut inside one long display formula still names the formula (the journey fixtures' shape).
    func testATitleCutInsideOneLongFormulaShowsItsStart() {
        let prompt = "Explain in plain terms, including any symbols: \\begin{equation}\n\\operatorname{Attention}(Q, K, V)=\\operatorname{softmax}\\left(\\frac{Q K^{T}}{\\sqrt{d_{k}}}\\right) V\n\\end{equation}"
        let saved = String(prompt.prefix(100))
        let title = ChatTitle.display(saved)
        XCTAssertTrue(title.hasPrefix("Explain · "), title)
        XCTAssertTrue(title.hasSuffix("…"), title)
        XCTAssertFalse(title.contains("\\"), title)
    }

    /// The reader's equation selection wraps the environment in display delimiters; cut inside it, the title still
    /// shows the formula's start.
    func testATitleCutInsideAWrappedEquationShowsItsStart() {
        let prompt = "Explain in plain terms, including any symbols: \\[\\begin{equation}\n\\mathrm{Attention}(Q, K, V)=\\mathrm{softmax}\\left(\\frac{Q K^{\\top}}{\\sqrt{d_k}}\\right) V \\label{eq:attention}\n\\end{equation}\\]"
        let title = ChatTitle.display(String(prompt.prefix(100)))
        XCTAssertTrue(title.hasPrefix("Explain · ") && title.count > 12, title)
        XCTAssertFalse(title.contains("\\"), title)
    }

    /// Topic titles (2026-10-08): a generated or renamed title is shown as saved, never parsed as a prompt; a
    /// conversation without one keeps its derived title. All chats searches both the title and the questions.
    func testTopicTitlesAreShownAsSavedEverywhere() {
        XCTAssertEqual(ChatTitle.display("Explain in plain terms, including any symbols: x", source: "generated"),
                       "Explain in plain terms, including any symbols: x", "A topic title is never shortened as a prompt")
        XCTAssertEqual(ChatTitle.display("Explain in plain terms, including any symbols: x", source: nil), "Explain · x")
        XCTAssertEqual(ChatTitle.display(" Scaling in\ndot-product attention ", source: "renamed"), "Scaling in dot-product attention")
        let titled = ConversationSummary(id: UUID(), title: "Explainer for a persona paper", documentID: UUID(), messageCount: 2,
            startedAt: nil, lastUsedAt: nil, lastArrival: 1, latestAnswer: "A", questions: "What is a persona vector?",
            titleSource: PrivateEvent.generatedTitle)
        let row = ChatHistoryRow(summary: titled, paperTitle: "Persona Vectors")
        XCTAssertEqual(row.title, "Explainer for a persona paper")
        XCTAssertTrue(ChatHistoryQuery.matches(row, "explainer"))
        XCTAssertTrue(ChatHistoryQuery.matches(row, "vector?"), "The questions stay searchable")
        XCTAssertEqual(ChatTitle.display(titled), "Explainer for a persona paper")
    }
}

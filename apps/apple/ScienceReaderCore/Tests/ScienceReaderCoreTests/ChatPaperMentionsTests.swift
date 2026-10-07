import Foundation
import Testing
@testable import ScienceReaderCore

struct ChatPaperMentionsTests {
    private func ids(_ text: String) -> [String] { ChatPaperMentions.extract(from: text).map(\.id) }

    @Test func relatedAnswerListsArxivAndDOIPapersWithTitles() throws {
        let answer = """
        Related work:

        1. **Direct Preference Optimization: Your Language Model is Secretly a Reward Model** — Rafailov et al., 2023. arXiv:2305.18290
        2. [A General Theoretical Paradigm to Understand Learning from Human Preferences](https://arxiv.org/abs/2310.12036v2) — Azar et al.
        3. **Rank Analysis of Incomplete Block Designs** — Bradley and Terry, 1952. https://doi.org/10.2307/2334029.
        4. KTO (https://arxiv.org/pdf/2402.01306.pdf) and ORPO (arXiv 2403.07691) compare against it.

        Sources:
        1. Attention Is All You Need — https://arxiv.org/abs/1706.03762
        """
        let mentions = ChatPaperMentions.extract(from: answer)
        #expect(mentions.map(\.id) == ["arxiv:2305.18290", "arxiv:2310.12036", "doi:10.2307/2334029", "arxiv:2402.01306", "arxiv:2403.07691"],
                "In order, without the paper only Sources names")
        #expect(mentions[0].title == "Direct Preference Optimization: Your Language Model is Secretly a Reward Model")
        #expect(mentions[1].title == "A General Theoretical Paradigm to Understand Learning from Human Preferences")
        #expect(mentions[1].label == "arXiv 2310.12036v2")
        #expect(mentions[2].title == "Rank Analysis of Incomplete Block Designs")
        #expect(mentions[2].label == "DOI 10.2307/2334029", "The sentence's full stop is not part of the DOI")
        #expect(mentions[2].url.absoluteString == "https://doi.org/10.2307/2334029")
        #expect(mentions[3].title == nil && mentions[4].title == nil, "A line naming two papers gives neither its leading words")
        #expect(mentions[0].url.absoluteString == "https://arxiv.org/abs/2305.18290")
    }

    @Test func duplicatesAndArxivDOIsCollapseAndTheListIsCapped() {
        let text = "See arXiv:2305.18290, [DPO](https://arxiv.org/abs/2305.18290v3) and doi:10.48550/arXiv.2305.18290 again."
        let mentions = ChatPaperMentions.extract(from: text)
        #expect(mentions.map(\.id) == ["arxiv:2305.18290"])
        #expect(mentions.first?.title == nil, "A one-word link label is not taken as a title")
        // DOIs compare case-insensitively.
        #expect(ids("10.1000/ABC and 10.1000/abc") == ["doi:10.1000/abc"])
        let many = (1...12).map { "arXiv:2401.\(String(format: "%05d", $0))" }.joined(separator: "\n")
        #expect(ids(many).count == ChatPaperMentions.maximum)
    }

    @Test func onlyRecognizedIdentifiersCount() {
        // Bare numbers, impossible arXiv dates, prices and version strings are not papers.
        #expect(ids("Accuracy rose from 2305.18290 to 2310.12036 points; costs $10.50; version 10.2.1/3.") == [])
        #expect(ids("arXiv:2313.00001 and arXiv:1706.3762") == [], "Month 13 and a short serial are invalid")
        #expect(ids("arXiv:hep-th/9901001v2") == ["arxiv:hep-th/9901001"])
        #expect(ids("arXiv preprint arXiv:1706.03762.") == ["arxiv:1706.03762"])
        // A DOI inside a Markdown link keeps its closing parenthesis out; DOIs with parentheses keep theirs.
        #expect(ids("[the paper](https://doi.org/10.1016/S0140-6736(20)30183-5)") == ["doi:10.1016/s0140-6736(20)30183-5"])
        #expect(ids("(see 10.1145/3292500.3330701)") == ["doi:10.1145/3292500.3330701"])
        #expect(ids("No identifiers here.") == [])
    }

    @Test func titlesComeFromLinksOrTheItemsLeadingTitle() {
        #expect(ChatPaperMentions.leadingTitle("- **Scaling Laws for Neural Language Models** (Kaplan, 2020)") == "Scaling Laws for Neural Language Models")
        #expect(ChatPaperMentions.leadingTitle("3) “Deep Residual Learning for Image Recognition”, He et al.") == "Deep Residual Learning for Image Recognition")
        #expect(ChatPaperMentions.leadingTitle("**Note:** this is related") == nil)
        #expect(ChatPaperMentions.leadingTitle("Plain text arXiv:2305.18290") == nil)
        #expect(ChatPaperMentions.cleanTitle("https://arxiv.org/abs/2305.18290") == nil)
        #expect(ChatPaperMentions.cleanTitle("arXiv:2305.18290") == nil)
    }
}

import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct PaperDiscoveryTests {
    @Test func publicLinksRoundTripWithoutPrivateIdentifiers() throws {
        for id in ["2305.18290v3", "hep-th/9711200v1"] {
            let link = try #require(PublicPaperLink(arxiv: id))
            #expect(PublicPaperLink(url: link.url) == link)
            #expect(link.sourceURL.host == "arxiv.org")
        }
        let doi = try #require(PublicPaperLink(doi: "10.1234/example/part"))
        #expect(PublicPaperLink(url: doi.url) == doi)
        for raw in ["https://evil.test/p/arxiv/2305.18290", "https://app.gradstep.ai@evil.test/p/arxiv/2305.18290",
                    "https://app.gradstep.ai/p/arxiv/2305.18290?token=x", "http://app.gradstep.ai/p/arxiv/2305.18290",
                    "https://app.gradstep.ai/p/arxiv/../../account", "https://app.gradstep.ai/p/doi/no"] {
            #expect(PublicPaperLink(url: URL(string: raw)!) == nil)
        }
    }
    @Test func keywordsDistinguishMethodsAndNeverAddGenericCategories() {
        let tags = PaperKeywords.derive(title: "LoRA: Parameter-Efficient Fine-Tuning", abstract: "We study low rank adaptation and quantization.")
        #expect(tags.contains("LoRA")); #expect(tags.contains("Parameter-efficient fine-tuning")); #expect(tags.contains("Quantization"))
        #expect(!PaperKeywords.allowed("Artificial intelligence")); #expect(!PaperKeywords.allowed("Machine learning"))
        #expect(PaperKeywords.derive(title: "A study", abstract: "Machine learning and artificial intelligence").isEmpty)
    }
    /// C2: the word-index matching keeps the phrase semantics of the original substring search: whole words only,
    /// hyphens as spaces, a plural term matching its singular, and a repeat (the memo) the same answer.
    @Test func keywordPhrasesMatchWholeWordsHyphensAndSingulars() {
        #expect(PaperKeywords.derive(title: "A study", abstract: "We train graph-neural networks on molecules.").contains("Graph neural networks"))
        #expect(PaperKeywords.derive(title: "A study", abstract: "A graph neural network for molecules.").contains("Graph neural networks"))
        #expect(!PaperKeywords.derive(title: "A study", abstract: "Subgraph neural networking is not the same words.").contains("Graph neural networks"))
        #expect(!PaperKeywords.derive(title: "A study", abstract: "Neural networks on a graph.").contains("Graph neural networks"))
        let title = "Mixture of experts beat diffusion models", abstract = "We compare state space models."
        let first = PaperKeywords.derive(title: title, abstract: abstract)
        #expect(first.prefix(2).sorted() == ["Diffusion models", "Mixture of experts"], "Title matches rank above abstract matches")
        #expect(first.contains("State space models"))
        #expect(PaperKeywords.derive(title: title, abstract: abstract) == first)
        #expect(PaperKeywords.derive(title: title, abstract: abstract, text: "world models appear in the body").contains("World models"))
    }
    /// Build 75: LLM, Large language models, Reasoning and Evaluation tagged most of the owner's library.
    @Test func genericKeywordsNeverDescribeAPaper() {
        let tags = PaperKeywords.derive(title: "Interactive Learning for LLM Reasoning with TreeCut",
            abstract: "Large language models show strong reasoning. We evaluate mathematical reasoning and tool use on a benchmark.")
        #expect(!tags.contains("LLM")); #expect(!tags.contains("Reasoning")); #expect(!tags.contains("Large language models"))
        #expect(!tags.contains("Evaluation"))
        #expect(tags.contains("TreeCut")); #expect(tags.contains("Mathematical reasoning")); #expect(tags.contains("Tool use"))
        for name in ["LLMs", " large language models ", "Transformers", "Benchmark"] { #expect(!PaperKeywords.distinctive(name)) }
        #expect(PaperKeywords.allowed("LLM"), "a tag the reader types stays theirs")
    }
    @Test func textIndexIsBoundedAndIndependentPapersCanBeForgotten() {
        var index = DevicePaperTextIndex(); let a = UUID(), b = UUID()
        index.insert(.init(digest: "a", text: "A distinctive superconductor appendix result"), for: a)
        index.insert(.init(digest: "b", text: "Another paper about robotics"), for: b)
        #expect(index.entries[a]?.terms.contains("superconductor") == true)
        index.remove(a); #expect(index.entries[a] == nil); #expect(index.entries[b] != nil)
        index.retain([]); #expect(index.entries.isEmpty)
        for n in 0..<205 { index.insert(.init(digest: "\(n)", text: "sample"), for: UUID()) }
        #expect(index.entries.count == 200)
        #expect(DevicePaperTextIndex.Entry(digest: "x", text: (0..<20_000).map { "term\($0)" }.joined(separator: " ")).terms.count == 10_000)
    }
}

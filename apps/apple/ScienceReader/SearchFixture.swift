#if DEBUG && FIXTURE_HOST
import Foundation
import ScienceReaderCore

/// `--search-fixture` (with `--draft-fixture`): a kept equation explanation of the offline sample's first equation, written
/// through the real sealed store, for global search's journeys (docs/architecture/GLOBAL_SEARCH.md). Its words are made
/// up for the fixture ("Zanzibar" is in no other fixture). Compiled out of device and release builds.
extension ReaderModel {
    static var searchFixtureEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--search-fixture") }

    func installSearchFixture() {
        guard let bundle = try? ReaderBundleLoader.sample(), let equation = bundle.index.equations.first,
              let sample = papers.first(where: { $0.isSample }) ?? selectedPaper else { return }
        let subject = ExplanationSubject(paperID: sample.id, paperTitle: sample.title, manifestSHA256: bundle.manifestSHA256,
                                         itemID: equation.id, label: "Equation (1)", action: ChatAction.equation.rawValue, savedAt: Date())
        let symbols = EquationSymbols(summary: "The Zanzibar normaliser turns the scaled scores into attention weights.", symbols: [
            .init(symbol: "Q", latex: "Q", meaning: "the queries, one row per token", source: .general),
            .init(symbol: "√dₖ", latex: #"\sqrt{d_k}"#, meaning: "the Zanzibar scale that keeps the softmax from saturating", source: .general),
        ])
        let key = EquationResultKey(manifestSHA256: bundle.manifestSHA256, equationID: equation.id, action: .equation, profile: equationProfile)
        keepEquationAnswer(EquationAnswer(symbols: symbols, text: "", model: "fixture", subject: subject), for: key)
    }
}
#endif

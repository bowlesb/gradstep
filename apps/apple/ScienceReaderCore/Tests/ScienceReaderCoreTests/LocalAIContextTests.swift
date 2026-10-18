import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct LocalAIContextTests {
    private func count(_ system: String, _ user: String) -> Int { system.utf8.count + user.utf8.count }

    @Test func retrievesNearTheFigureWithoutRenumberingOrSendingTheWholePaper() throws {
        let paper = (1...100).map { "[¶\($0)] " + String(repeating: "Ordinary unrelated paragraph. ", count: 8) }.joined(separator: "\n\n")
        let prompt = try LocalAIContext.build(.init(question: "Explain the axis", paper: paper, focus: 75), budget: 2_500, count: count)
        #expect(prompt.paragraphs.contains(75))
        #expect(prompt.omittedParagraphs > 90)
        #expect(prompt.user.contains("[¶75]"))
        #expect(count(prompt.system, prompt.user) <= 2_500)
    }
    @Test func retainsExactLatexAndRejectsOversizedMandatoryInput() throws {
        let latex = #"\bar B=(\Delta A)^{-1}(\exp(\Delta A)-I)\Delta B"#
        let prompt = try LocalAIContext.build(.init(question: "Explain", selection: latex), budget: 2_000, count: count)
        #expect(prompt.user.contains(latex))
        #expect(throws: LocalAIContext.Failure.self) {
            try LocalAIContext.build(.init(question: "Explain", selection: String(repeating: latex, count: 100)), budget: 2_000, count: count)
        }
    }
    @Test func lexicalRetrievalFindsEvidenceLateInThePaperAndHistoryIsBounded() throws {
        let paper = "[¶1] Unrelated introduction.\n\n[¶92] Discretization uses zero-order hold and a matrix exponential."
        let history = (0...20).map { ChatTurnInput(role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "Old context ", count: 50)) }
        let result = try LocalAIContext.build(.init(question: "How does zero-order discretization work?", paper: paper, history: history), budget: 2_000, count: count)
        #expect(result.paragraphs.contains(92)); #expect(result.omittedTurns >= 17)
    }
    @Test func localToolsNeverSilentlyFallBackToCloud() {
        for action in [ChatAction.related, .ingest, .diagramFix, .study] {
            #expect(throws: LocalAIContext.Failure.self) {
                try LocalAIContext.build(.init(question: "Perform the requested action", action: action), count: count)
            }
        }
    }
    @Test func mathematicalEvidenceTravelsWithItsRetrievedExplanation() throws {
        let paper = "[¶1] A general introduction.\n\n[¶2] \\[ L=-\\log\\sigma(z) \\]\n\n[¶3] The preference objective gradient weights incorrectly ordered completions.\n\n"
            + (4...30).map { "[¶\($0)] Preference objective gradient discussion without the actual expression. " + String(repeating: "Commentary. ", count: 20) }.joined(separator: "\n\n")
        let result = try LocalAIContext.build(.init(question: "Derive the preference objective gradient", paper: paper), budget: 1_700, count: count)
        #expect(result.paragraphs.contains(2))
        #expect(result.user.contains(#"L=-\log\sigma(z)"#))
    }
    @Test func nativeContextCannotBeEncodedAsACloudRequest() throws {
        let request = try ChatGenerationRequest.make(operationID: UUID(), documentID: UUID(),
            transcript: [.init(role: .user, text: "Explain")], selection: nil)
            .forLocalInference(paperText: "Device-only PDF text", focus: 2)
        #expect(throws: ChatRequestError.self) { try request.encoded() }
        let general = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil,
            transcript: [.init(role: .user, text: "Private general question")], selection: nil)
            .forLocalInference(paperText: nil)
        #expect(throws: ChatRequestError.self) { try general.encoded() }
    }
    @Test func equationNamedInQuestionWinsOverRepeatedGradientCommentary() throws {
        let paper = "[¶32] The policy objective becomes:\n\n[¶33] \\[ L=-\\log\\sigma(z) \\tag{7} \\]\n\n[¶34] This fits an implicit reward.\n\n"
            + (35...80).map { "[¶\($0)] DPO loss gradient sigma weight Section 4 derivation. " + String(repeating: "Other discussion. ", count: 12) }.joined(separator: "\n\n")
        let result = try LocalAIContext.build(.init(question: "Derive the DPO loss gradient from Eq. 7", paper: paper), budget: 2_000, count: count)
        #expect(result.paragraphs.contains(33)); #expect(result.paragraphs.contains(32))
    }
    @Test func rejectedAppendixBlocksDoNotRetokenizeTheWholePrompt() throws {
        let paper = (1...400).map { "[¶\($0)] " + String(repeating: "Long appendix text ", count: 100) }.joined(separator: "\n\n")
        var fullPromptCounts = 0, totalCounts = 0
        let result = try LocalAIContext.build(.init(question: "Explain", paper: paper), budget: 2_500) { system, user in
            totalCounts += 1
            if !system.isEmpty { fullPromptCounts += 1 }
            return count(system, user)
        }
        #expect(fullPromptCounts <= 4)
        #expect(totalCounts <= 52)
        #expect(count(result.system, result.user) <= 2_500)
    }
    @Test func localAndCloudExplanationsHaveDifferentCacheIdentities() {
        let cloud = EquationResultKey(manifestSHA256: "abc", equationID: "eq1", action: .equation, profile: .standard)
        let local = EquationResultKey(manifestSHA256: "abc", equationID: "eq1", action: .equation, profile: .standard, localModel: "local/qwen/revision")
        #expect(cloud.fileName != local.fileName)
        let another = EquationResultKey(manifestSHA256: "abc", equationID: "eq1", action: .equation, profile: .standard, localModel: "local/qwen/updated")
        #expect(local.fileName != another.fileName)
    }
}

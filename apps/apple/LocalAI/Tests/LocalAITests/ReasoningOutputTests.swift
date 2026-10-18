import Testing
@testable import LocalAI

@Suite struct ReasoningOutputTests {
    @Test func primedReasoningIsPrivateAcrossEveryBoundary() {
        let text = "Private reasoning αβ.</think>\nThe answer is 42."
        for boundary in text.indices {
            var output = ReasoningOutput(thinking: true)
            let visible = output.append(String(text[..<boundary])) + output.append(String(text[boundary...])) + output.finish()
            #expect(visible == "\nThe answer is 42.")
        }
    }
    @Test func aTruncatedReasoningSpanNeverBecomesAnAnswer() {
        var output = ReasoningOutput(thinking: true)
        #expect(output.append("Only private reasoning </thi") + output.finish() == "")
    }
    @Test func ordinaryTextAndLaterThinkingSpansAreHandledSeparately() {
        var output = ReasoningOutput(thinking: false)
        let text = "Start <think>private</think>finish."
        var visible = ""
        for c in text { visible += output.append(String(c)) }
        visible += output.finish()
        #expect(visible == "Start finish.")
    }
}

import Foundation
import Testing
import ScienceReaderCore
@testable import ScienceReader

/// Visual answers (docs/proposals/CHAT_TOOLS.md): an HTML fragment the server sanitized, kept like a diagram
/// (format html-v1) and shown in a frame with no scripts; the request names the reader's setting.
struct ChatVisualTests {
    @Test func aVisualIsADiagramOfTheHTMLFormat() {
        let visual = ChatDiagram(title: " Loop ", source: "<ol><li>a</li></ol>", messageID: nil, format: ChatDiagram.htmlFormat)
        #expect(visual?.isHTML == true && visual?.title == "Loop")
        #expect(ChatDiagram(title: "x", source: "<p>y</p>", messageID: nil, format: "svg-v9") == nil, "unknown formats are refused")
        #expect(ChatDiagram(title: "x", source: String(repeating: "y", count: 24_001), messageID: nil, format: ChatDiagram.htmlFormat) == nil)
        #expect(ChatDiagram(title: "x", source: String(repeating: "y", count: 16_001), messageID: nil) == nil, "Mermaid keeps its own bound")
        let encoded = visual!.encodedText()
        #expect(encoded.contains("\"format\":\"html-v1\""))
        #expect(ChatDiagram.decode(encoded)?.isHTML == true)
        #expect(ChatDiagram.decode("{\"format\":\"mermaid-v1\",\"source\":\"graph TD; a-->b\",\"title\":\"T\"}")?.isHTML == false)
    }

    @Test func theRequestNamesTheSetting() throws {
        let turns = [ChatTurnInput(role: .user, text: "How does the loop flow?")]
        let on = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: turns, selection: nil)
        let off = try ChatGenerationRequest.make(operationID: UUID(), documentID: nil, transcript: turns, selection: nil, visualAnswers: false)
        let onBody = String(decoding: try on.encoded(), as: UTF8.self), offBody = String(decoding: try off.encoded(), as: UTF8.self)
        #expect(onBody.contains("\"capabilities\":[\"visual_answers\"]"))
        #expect(offBody.contains("\"capabilities\":[]"), "an empty list tells the server the reader turned visuals off")
        #expect(ChatGenerationRequest.capabilities(action: .ingest, visualAnswers: true) == ["web_import", "visual_answers"])
    }

    @Test func theVisualPageHasNoScriptsAndNoNetwork() {
        let page = HTMLVisualWebView.document("<p>hi</p>", dark: true, fontSize: 17)
        #expect(page.contains("default-src 'none'; style-src 'unsafe-inline'"))
        #expect(!page.contains("<script") && page.contains("<body><p>hi</p></body>"))
        #expect(page.contains("color-scheme:dark"))
    }
}

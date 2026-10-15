import Foundation
import Testing
import WebKit
@testable import ScienceReader

/// The device compiler's reason code travels with the failure, categorized like the browser frame, and the message
/// says which part of the paper refused (owner screenshot 2026-10-15, 2610.15371: "couldn't be prepared completely"
/// with no way to tell why).
struct ArxivCompilerFailureTests {
    @Test func categoriesMatchTheBrowserFrame() {
        #expect(ArxivCompilerFailure.category(for: "arxiv_title") == "formatting")
        #expect(ArxivCompilerFailure.category(for: "arxiv_math_coverage") == "math")
        #expect(ArxivCompilerFailure.category(for: "source_limit") == "limit")
        #expect(ArxivCompilerFailure.category(for: "arxiv_article") == "source-unavailable")
        #expect(ArxivCompilerFailure.category(for: "index_identity") == "unknown", "a validator code is an internal inconsistency")
        let codes = ArxivCompilerFailure.categories.flatMap(\.codes)
        #expect(Set(codes).count == codes.count, "each code in one category")
    }

    @Test func messagesNameTheCategoryAndTheWayOut() {
        #expect(ArxivHTMLError.compiler("arxiv_math_coverage").message == "The HTML reader couldn’t preserve an equation in this paper. You can still open its PDF on this device.")
        #expect(ArxivHTMLError.compiler("arxiv_title").message.hasPrefix("The HTML reader doesn’t yet support part of this paper’s formatting."))
        #expect(ArxivHTMLError.compiler("index_identity").message == "This version’s HTML couldn’t be prepared completely. You can still open its PDF on this device.")
    }

    @Test func theCodeIsReadFromTheJavaScriptException() {
        func error(_ message: String) -> Error {
            NSError(domain: WKError.errorDomain, code: WKError.javaScriptExceptionOccurred.rawValue, userInfo: ["WKJavaScriptExceptionMessage": message])
        }
        #expect(ArxivCompilerFailure.code(in: error("arxiv_title")) == "arxiv_title")
        #expect(ArxivCompilerFailure.code(in: error("ReaderRenderError: arxiv_math_coverage")) == "arxiv_math_coverage")
        #expect(ArxivCompilerFailure.code(in: error("TypeError: undefined is not an object")) == nil, "a browser error of its own is no code")
        #expect(ArxivCompilerFailure.code(in: error("Error: Unexpected token '<' in source_text")) == "source_text", "the trailing token only; never the whole text")
        #expect(ArxivCompilerFailure.code(in: NSError(domain: "x", code: 1)) == nil)
    }
}

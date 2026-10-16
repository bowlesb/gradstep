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

    /// Build 57 (2610.20399, no arXiv HTML): the screen said "you can still open its PDF" with only Try again under it.
    @Test func aPaperTheReaderCantShowOffersItsPDF() {
        #expect(ReaderOpenFallback(ArxivHTMLError.unavailable) == .pdfOnly, "no HTML at all: the PDF, not Try again")
        #expect(ReaderOpenFallback(ArxivHTMLError.compiler("arxiv_math_coverage")) == .pdf)
        #expect(ReaderOpenFallback(ArxivHTMLError.invalid) == .pdf)
        #expect(ReaderOpenFallback(ArxivHTMLError.tooLarge) == .pdf)
        #expect(ReaderOpenFallback(NSError(domain: "x", code: 1)) == .pdf, "any other preparation failure")
        for network in [ArxivHTMLError.retryLater, .refused, .retrieval] {
            #expect(ReaderOpenFallback(network) == .none, "arXiv busy, refused or unreachable: its PDF would fail the same way")
        }
        #expect(ArxivHTMLError.unavailable.message.contains("web version"))
    }

    /// Build 62: two papers failed on the phone behind one sentence. The device's own stops keep that sentence and carry a
    /// code (Reader version details, the failure screen's ⓘ, the session log); each offers the PDF.
    @Test func theDevicesOwnStopsSayTheSameAndCarryACode() {
        for code in ["web_process_ended", "timeout", "load_failed", "result_invalid", "package_invalid", "source_mismatch", "compiler_threw"] {
            let error = ArxivHTMLError.stopped(code)
            #expect(error.code == code)
            #expect(error.message == ArxivHTMLError.invalid.message)
            #expect(ReaderOpenFallback(error) == .pdf)
        }
        #expect(ArxivHTMLError.compiler("arxiv_math_coverage").code == "arxiv_math_coverage")
        #expect(ArxivHTMLError.unavailable.code == "no_html")
    }

    /// Reader version details (build 62): this app's version is named, and a stored paper's from the shipped list.
    @Test func readerVersionsNameThisAppsAndEarlierCopies() throws {
        let current = try #require(ReaderVersions.current)
        #expect(ReaderVersions.all.first?.revision == current, "the list leads with this app's version")
        #expect(ReaderVersions.all.map(\.revision) == ReaderVersions.all.map(\.revision).sorted(by: >))
        #expect(ReaderVersions.all.allSatisfy { !$0.note.isEmpty && $0.buildSHA256.count == 64 })
        #expect(ReaderVersions.changes(since: current).isEmpty)
        #expect(ReaderVersions.changes(since: current - 1).map(\.revision) == [current])
        #expect(ReaderVersions.changes(since: nil).count == ReaderVersions.all.count)
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

/// One device compile at a time (build 62: several preparations at once on a phone).
@Suite struct ArxivCompileGateTests {
    @Test func secondCompileWaitsForTheFirstAndACancelledWaiterLeaves() async throws {
        let gate = ArxivCompileGate()
        try await gate.enter()
        let order = OrderLog()
        let second = Task { try await gate.enter(); await order.add("second"); await gate.leave() }
        let cancelled = Task { try await gate.enter(); await order.add("cancelled"); await gate.leave() }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(100))
        await order.add("first done")
        await gate.leave()
        try await second.value
        _ = await cancelled.result
        #expect(await order.items == ["first done", "second"])
    }
}

private actor OrderLog {
    var items: [String] = []
    func add(_ item: String) { items.append(item) }
}

import Foundation
import XCTest
import ScienceReaderCore
import WebKit
@testable import ScienceReader

@MainActor
final class UnsentDraftTests: XCTestCase {
    func testContextualChatsPreserveDraftsAndFenceOldViews() async throws {
        let model = ReaderModel(configuration: nil); model.openSample()
        let paper = try XCTUnwrap(model.selectedPaper), manifest = String(repeating: "a", count: 64)
        model.chatInput = "Keep my ordinary paper draft"; let previous = model.chatComposerID
        let first = model.beginContextualChat(paperID: paper.id, manifest: manifest, element: "eq1", label: "Equation (1)", quote: "x^2")
        XCTAssertTrue(model.ownsContextualChat(first)); XCTAssertNotEqual(model.chatComposerID, previous)
        XCTAssertEqual(model.chatInput, ""); model.chatInput = "Why squared?"
        let second = model.beginContextualChat(paperID: paper.id, manifest: manifest, element: "F1", label: "Figure 1", quote: "A figure")
        XCTAssertFalse(model.ownsContextualChat(first)); XCTAssertTrue(model.ownsContextualChat(second)); XCTAssertEqual(model.chatInput, "")
        model.endContextualChat(first); XCTAssertTrue(model.ownsContextualChat(second), "late view disappearance cannot close its replacement")
        model.endContextualChat(second); XCTAssertEqual(model.chatComposerID, previous); XCTAssertEqual(model.chatInput, "Keep my ordinary paper draft")
        let reopened = model.beginContextualChat(paperID: paper.id, manifest: manifest, element: "eq1", label: "Equation (1)", quote: "x^2")
        XCTAssertEqual(model.chatInput, "Why squared?")
        model.endContextualChat(reopened); XCTAssertFalse(model.ownsContextualChat(reopened))
        XCTAssertFalse(model.hasContextualChat)
    }

    func testReportedMathActuallyRendersInLightAndDark() throws {
        for (i, latex) in [#"x \longmapsto \begin{cases} x + cy & \text{if } b = 0, \\ x + cz & \text{if } b = 1, \end{cases}"#,
                            #"\ket{0}^{\otimes n}"#].enumerated() {
            for dark in [false, true] {
                let rendered = try XCTUnwrap(ChatMathCache.shared.render(latex, size: 22, display: true, dark: dark), latex)
                XCTAssertGreaterThan(rendered.image.size.width, 15); XCTAssertGreaterThan(rendered.image.size.height, 15)
                let attachment = XCTAttachment(image: rendered.image); attachment.name = "Reported math \(i) \(dark ? "dark" : "light")"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testEquationEnlargementReallyOverflowsWithoutAToggle() async throws {
        let config = WKWebViewConfiguration(), web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        web.loadHTMLString("<html><head><meta name='viewport' content='width=device-width'></head><body style='margin:0'><div id='eq' style='display:inline-block'><span style='display:inline-block;width:1600px;height:40px'>Wide equation</span></div></body></html>", baseURL: nil)
        for _ in 0..<100 { if !web.isLoading { break }; try await Task.sleep(for: .milliseconds(30)) }
        _ = try await web.evaluateJavaScript(EquationWebView.layoutScript)
        _ = try await web.evaluateJavaScript("window.__equationLayout(17,1)")
        let fit = try await web.evaluateJavaScript("document.documentElement.scrollWidth") as! Double
        _ = try await web.evaluateJavaScript("window.__equationLayout(17,2)")
        let enlarged = try await web.evaluateJavaScript("document.documentElement.scrollWidth") as! Double
        XCTAssertLessThanOrEqual(fit, 322); XCTAssertGreaterThan(enlarged, 500)
    }

    func testFailedFirstSaveAndNewerDraftBothRemainReachable() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Original question", in: "general")
        let failed = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        workspace.select(nil, in: "general")
        workspace.setDraft("Newer question", in: "general")
        let newer = try XCTUnwrap(workspace.composerID(in: "general"))
        workspace.fail(failed)

        XCTAssertEqual(Set(workspace.unsentDrafts.map(\.id)), [failed.composerID, newer])
        XCTAssertTrue(try XCTUnwrap(workspace.unsentDrafts.first { $0.id == failed.composerID }).failed)
        XCTAssertEqual(workspace.composerID(in: "general"), newer)
        XCTAssertEqual(workspace.selectDraft(failed.composerID), "general")
        XCTAssertEqual(workspace.draft(in: "general"), "Original question")
        XCTAssertEqual(workspace.selectDraft(newer), "general")
        XCTAssertEqual(workspace.draft(in: "general"), "Newer question")

        _ = workspace.selectDraft(failed.composerID)
        let retry = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        _ = workspace.selectDraft(newer)
        workspace.complete(retry)
        XCTAssertEqual(workspace.composerID(in: "general"), newer)
        XCTAssertEqual(workspace.unsentDrafts.map(\.id), [newer])
        workspace.select(retry.conversationID, in: "general")
        XCTAssertEqual(workspace.draft(in: "general"), "")
    }

    func testPendingAndSavedConversationsAreNotDuplicatedAsUnsentChats() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft(" \n ", in: "general")
        XCTAssertTrue(workspace.unsentDrafts.isEmpty)
        workspace.setDraft("A question", in: "general")
        let saving = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        XCTAssertTrue(workspace.unsentDrafts.isEmpty)
        workspace.discardDraft(saving.composerID)
        XCTAssertTrue(workspace.isSaving(in: "general"))
        workspace.complete(saving)
        workspace.setDraft("Follow-up retained by history", in: "general")
        XCTAssertTrue(workspace.unsentDrafts.isEmpty)
        workspace.select(nil, in: "general")
        workspace.select(saving.conversationID, in: "general")
        XCTAssertEqual(workspace.draft(in: "general"), "Follow-up retained by history")
    }

    func testDiscardedFailedDraftCannotReturnThroughLateCompletion() throws {
        var workspace = ChatWorkspace()
        workspace.setDraft("Discard this failed save", in: "general")
        let failed = try XCTUnwrap(workspace.beginSubmission(in: "general"))
        workspace.fail(failed)
        workspace.discardDraft(failed.composerID)
        workspace.complete(failed)
        workspace.fail(failed)
        XCTAssertTrue(workspace.unsentDrafts.isEmpty)
        XCTAssertNil(workspace.composerID(in: "general"))
        XCTAssertNil(workspace.selectDraft(failed.composerID))
    }

    func testReopeningDraftRestoresItsPaperOrGeneralContext() throws {
        let model = ReaderModel(configuration: nil)
        model.openSample()
        let paper = try XCTUnwrap(model.selectedPaper)
        model.chatInput = "Question for this paper"
        let paperDraft = try XCTUnwrap(model.chatComposerID)
        model.newChat(general: true)
        model.chatInput = "A general research question"
        let generalDraft = try XCTUnwrap(model.chatComposerID)

        let previousHidden = model.readerChatHidden
        defer { model.readerChatHidden = previousHidden }
        model.readerChatHidden = true
        model.openUnsentDraft(paperDraft)
        XCTAssertFalse(model.readerChatHidden, "Opening a paper draft reveals its composer in the wide Reader")
        XCTAssertFalse(model.generalChat)
        XCTAssertEqual(model.chatPaperID, paper.id)
        XCTAssertEqual(model.chatInput, "Question for this paper")
        XCTAssertEqual(model.tab, .chat)
        model.openUnsentDraft(generalDraft)
        XCTAssertTrue(model.generalChat)
        XCTAssertEqual(model.chatInput, "A general research question")
        model.papers = []
        model.openUnsentDraft(paperDraft)
        XCTAssertFalse(model.generalChat)
        XCTAssertEqual(model.chatPaperID, paper.id)
        XCTAssertNil(model.selectedPaper)
        XCTAssertEqual(model.chatInput, "Question for this paper")
        model.discardUnsentDraft(paperDraft)
        XCTAssertEqual(model.unsentDrafts.map(\.id), [generalDraft])
    }

    func testNewPaperChatRevealsTheHiddenColumnAndKeepsItsPreviousDraft() throws {
        let model = ReaderModel(configuration: nil)
        let previousHidden = model.readerChatHidden
        defer { model.readerChatHidden = previousHidden }
        model.openSample()
        model.chatInput = "A question to finish later"
        let previousDraft = try XCTUnwrap(model.chatComposerID)
        model.readerChatHidden = true

        model.newChat(general: false)

        XCTAssertFalse(model.readerChatHidden)
        XCTAssertNotEqual(model.chatComposerID, previousDraft)
        XCTAssertEqual(model.chatInput, "")
        model.openUnsentDraft(previousDraft)
        XCTAssertEqual(model.chatInput, "A question to finish later")
    }
}

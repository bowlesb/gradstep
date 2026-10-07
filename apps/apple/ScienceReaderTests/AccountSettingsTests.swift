import Foundation
import XCTest
@testable import ScienceReader

/// The Account row and page (owner feedback, build 14 #8): sync in plain words, how the account is named and signed
/// into, and reading the sign-in methods from the session Auth returns.
final class AccountSettingsTests: XCTestCase {
    func testSyncInPlainWords() {
        let synced = SyncSummary.from(status: "Synced", issue: nil, pending: 0)
        XCTAssertEqual(synced.tone, .synced)
        XCTAssertEqual(synced.title, "Your chats and notes are synced")
        XCTAssertEqual(synced.detail, "They’re encrypted with keys held on your devices.")
        XCTAssertEqual(synced.short, "Synced")
        XCTAssertEqual(SyncSummary.from(status: "Saved on this device", issue: nil, pending: 0).tone, .synced, "A local save already sent")

        let waiting = SyncSummary.from(status: "Saved on this device", issue: nil, pending: 3)
        XCTAssertEqual(waiting.title, "Waiting to sync 3 changes")
        XCTAssertEqual(waiting.short, "3 changes waiting to sync")
        XCTAssertEqual(SyncSummary.from(status: "1 changes waiting to sync", issue: nil, pending: 1).title, "Waiting to sync 1 change")

        XCTAssertEqual(SyncSummary.from(status: "Syncing…", issue: nil, pending: 2).detail, "Sending 2 changes.")
        XCTAssertEqual(SyncSummary.from(status: "On this device", issue: nil, pending: 0).title, "Not synced yet",
                       "Before the first sync finishes nothing is claimed as synced")

        let offline = SyncSummary.from(status: "Saved on this device · Sync paused", issue: "The Internet connection appears to be offline.", pending: 4)
        XCTAssertEqual(offline.tone, .paused)
        XCTAssertEqual(offline.title, "Sync is paused")
        XCTAssertEqual(offline.detail, "The Internet connection appears to be offline.", "The reason, as the sync reported it")
        XCTAssertEqual(offline.short, "Sync paused")
        XCTAssertEqual(SyncSummary.from(status: "Saved on this device · Sync paused", issue: nil, pending: 0).detail,
                       "Your changes are saved on this device and sync when it can reach Gradstep.")
    }

    func testAccountNameAndMethods() {
        XCTAssertEqual(AccountFormat.name(email: "reader@example.com", providers: ["apple"]), "reader@example.com")
        XCTAssertEqual(AccountFormat.name(email: nil, providers: []), "Signed in with Apple", "Only Apple withholds the email")
        XCTAssertEqual(AccountFormat.name(email: "", providers: ["google"]), "Signed in with Google")
        XCTAssertEqual(AccountFormat.methods(["apple", "google"]), "Apple and Google")
        XCTAssertEqual(AccountFormat.methods(["email", "email", "phone"]), "Email code", "Repeats and unknown methods left out")
        XCTAssertNil(AccountFormat.methods([]))
    }

    func testSessionUserReadsSignInMethodsTolerantly() throws {
        let id = UUID()
        func user(_ json: String) throws -> AuthSession.User { try JSONDecoder().decode(AuthSession.User.self, from: Data(json.utf8)) }
        XCTAssertEqual(try user(#"{"id":"\#(id)","email":"a@b.c","app_metadata":{"provider":"apple","providers":["apple","google"]}}"#).providers, ["apple", "google"])
        XCTAssertEqual(try user(#"{"id":"\#(id)","email":"a@b.c","app_metadata":{"provider":"email"}}"#).providers, ["email"])
        XCTAssertEqual(try user(#"{"id":"\#(id)","email":null}"#).providers, [], "Older cached sessions have no metadata")
        XCTAssertEqual(try user(#"{"id":"\#(id)","app_metadata":{"providers":"apple"}}"#).providers, [], "Malformed metadata is ignored")
        XCTAssertEqual(try user(#"{"id":"\#(id)","app_metadata":"x"}"#).providers, [])
        XCTAssertEqual(try user(#"{"id":"\#(id)","app_metadata":{"providers":["Apple <script>","google"]}}"#).providers, ["google"])
        XCTAssertThrowsError(try user(#"{"email":"a@b.c"}"#), "The account ID is still required")

        // Cached with the session and read back.
        let original = AuthSession.User(id: id, email: "a@b.c", providers: ["google"])
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.User.self, from: JSONEncoder().encode(original)), original)
        let bare = AuthSession.User(id: id, email: nil)
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.User.self, from: JSONEncoder().encode(bare)), bare)
    }
}

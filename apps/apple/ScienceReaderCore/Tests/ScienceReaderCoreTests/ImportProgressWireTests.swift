import Foundation
import Testing
@testable import ScienceReaderCore

/// `progress_detail` on import entries (migration 029): decoded leniently, compared like every other field at
/// equal state_seq, and kept through the offline cache's encoding.
@Suite struct ImportProgressWireTests {
    private let account = UUID(uuidString: "a0000000-0000-0000-0000-000000000030")!

    private func importJSON(state: Int64 = 1, detail: Any? = nil) -> [String: Any] {
        var row: [String: Any] = ["kind": "import", "id": "00000000-0000-0000-0000-000000000301", "created_seq": 1, "state_seq": state,
            "intent_revision": 1, "visible": true, "phase": "acquiring", "source": "arxiv", "source_id": "2305.18290",
            "requested_revision": NSNull(), "source_revision": NSNull(), "metadata_id": NSNull(), "version_id": NSNull(),
            "metadata": NSNull(), "metadata_recorded_at": NSNull(), "source_url": "https://arxiv.org/abs/2305.18290",
            "document_id": NSNull(), "library_item_id": NSNull(), "error_code": NSNull(), "retryable": false, "progress": "converting"]
        if let detail { row["progress_detail"] = detail }
        return row
    }

    private func decode(_ row: [String: Any]) throws -> LibraryImportRecord {
        let data = try JSONSerialization.data(withJSONObject: row)
        guard case .import(let value) = try JSONDecoder().decode(LibraryEntry.self, from: data) else { throw LibraryProtocolError.invalidEntry }
        return value
    }

    private func page(_ rows: [[String: Any]], high: Int64) throws -> LibraryBaselinePage {
        let cursor: [String: Any] = ["format": 2, "account_id": account.wire, "through": high, "created_seq": 1,
                                     "id": rows.last!["id"]!, "kind": "import"]
        return try LibraryWire.decodeBaseline(JSONSerialization.data(withJSONObject: [
            "format": 2, "account_id": account.wire, "baseline_cursor": high, "retained_after": 0,
            "entries": rows, "next_cursor": cursor, "has_more": false] as [String: Any]))
    }

    @Test func decodesTheServerShape() throws {
        let value = try decode(importJSON(detail: ["step": "reading_equations", "percent": 62, "eta_seconds": 40,
                                                   "pages": 27, "pages_done": 17]))
        #expect(value.progressDetail == LibraryImportProgressDetail(step: .readingEquations, percent: 62, etaSeconds: 40,
                                                                    pages: 27, pagesDone: 17))
        let delayed = try decode(importJSON(detail: ["step": "downloading", "percent": 9, "delayed": true, "bytes": 3_355_443]))
        #expect(delayed.progressDetail?.delayed == true && delayed.progressDetail?.etaSeconds == nil
                && delayed.progressDetail?.bytes == 3_355_443)
        // Older servers: no key, no detail.
        #expect(try decode(importJSON()).progressDetail == nil)
        #expect(try decode(importJSON(detail: NSNull())).progressDetail == nil)
    }

    @Test func malformedOrNewerDetailsNeverRejectTheEntry() throws {
        let odd = try decode(importJSON(detail: ["step": "polishing", "percent": 140, "eta_seconds": -5, "pages": 0,
                                                 "pages_done": 9, "bytes": "big", "delayed": "yes", "future": [1, 2]]))
        #expect(odd.progressDetail == LibraryImportProgressDetail(step: .other("polishing"), percent: 0, pagesDone: 9))
        let tooFar = try decode(importJSON(detail: ["step": "reading_equations", "percent": 50, "pages": 10, "pages_done": 11]))
        #expect(tooFar.progressDetail?.pagesDone == nil, "more pages done than pages: dropped")
        #expect(try decode(importJSON(detail: "62%")).progressDetail == LibraryImportProgressDetail(step: .other(""), percent: 0))
        #expect(try decode(importJSON(detail: [1, 2, 3])).progressDetail?.step == .other(""))
        #expect(try decode(importJSON(detail: ["step": String(repeating: "x", count: 65)])).progressDetail?.step == .other(""))
    }

    @Test func automaticRetryTimeIsOptionalBoundedAndSurvivesEncoding() throws {
        var row = importJSON()
        row["phase"] = "failed"; row["error_code"] = "metadata_unavailable"; row["retryable"] = true
        #expect(try decode(row).autoRetryAt == nil)
        for invalid: Any in [NSNull(), "tomorrow", String(repeating: "x", count: 65), 123, ["at": "2026-10-08T01:00:00Z"]] {
            row["auto_retry_at"] = invalid
            #expect(try decode(row).autoRetryAt == nil)
        }
        row["auto_retry_at"] = "2026-10-08T01:00:00Z"
        let value = try decode(row)
        #expect(value.autoRetryAt != nil)
        #expect(try JSONDecoder().decode(LibraryImportRecord.self, from: JSONEncoder().encode(value)) == value)
        #expect(try OfflineCacheCodec.decode(LibraryImportRecord.self, from: OfflineCacheCodec.encode(value)) == value)
    }

    @Test func survivesTheCacheEncodingExactly() throws {
        for detail in [["step": "reading_equations", "percent": 62, "eta_seconds": 40, "pages": 27, "pages_done": 17] as [String: Any],
                       ["step": "waiting", "percent": 30, "delayed": true], ["step": "finding", "percent": 0, "eta_seconds": 47]] {
            let entry = try JSONDecoder().decode(LibraryEntry.self, from: JSONSerialization.data(withJSONObject: importJSON(detail: detail)))
            let again = try JSONDecoder().decode(LibraryEntry.self, from: JSONEncoder().encode(entry))
            #expect(again == entry)
        }
    }

    private func changes(_ batches: [(Int64, [[String: Any]])], through: Int64) throws -> LibraryChangesPage {
        try LibraryWire.decodeChanges(JSONSerialization.data(withJSONObject: [
            "format": 2, "account_id": account.wire, "through": through, "retained_after": 0,
            "changes": batches.map { ["seq": $0.0, "entries": $0.1] as [String: Any] },
            "next_cursor": through, "has_more": false] as [String: Any]))
    }

    @Test func aDifferentDetailNeedsANewStateSequence() throws {
        let downloading: [String: Any] = ["step": "downloading", "percent": 10, "eta_seconds": 42]
        var library = LibraryReconciler(accountID: account)
        let first = try library.nextRequest()
        try library.accept(page([importJSON(state: 3, detail: downloading)], high: 3), for: first)
        let catchUp = try library.nextRequest()
        try library.accept(changes([], through: 3), for: catchUp)
        let id = LibraryEntryID(kind: .import, entityID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!)

        // The same detail at the same state_seq is the same entry.
        var request = try library.nextRequest()
        #expect(try library.accept(changes([(4, [importJSON(state: 3, detail: downloading)])], through: 4), for: request).identicalEntries == 1)
        // Another detail at the same state_seq breaks the server's promise.
        request = try library.nextRequest()
        let before = library
        #expect(throws: LibraryProtocolError.conflictingRevision(id, 3)) {
            try library.accept(changes([(5, [importJSON(state: 3, detail: ["step": "downloading", "percent": 11, "eta_seconds": 40])])], through: 5), for: request)
        }
        // A new state_seq replaces it.
        library = before
        request = try library.nextRequest()
        try library.accept(changes([(5, [importJSON(state: 5, detail: ["step": "reading_equations", "percent": 28, "pages": 27, "eta_seconds": 40])])],
                                   through: 5), for: request)
        guard case .import(let now) = library.entries[id] else { Issue.record("Expected the import"); return }
        #expect(now.progressDetail?.step == .readingEquations && now.progressDetail?.pages == 27)
    }
}

import Foundation
import Testing
@testable import ScienceReaderCore

/// Swift ⇄ browser Notes records (tests/fixtures/notes/cross-client-v1.json). `swiftWritten` holds what this codec writes
/// for edge cases (non-ASCII and emoji titles, escapes, tiny and fractional numbers, optional keys, a local PDF); the
/// browser codec (apps/web/src/lib/notes.ts) decoded and re-encoded each to the same bytes when the file was made.
/// `browserWritten` holds what the browser codec writes for its own edge cases (null anchor identity included); Swift must
/// read, validate and re-encode each byte for byte. Regenerate with NOTES_INTEROP_WRITE=<path> and the browser script
/// recorded in IMPLEMENTATION_STATUS.md.
@Suite struct NotesInteropTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let path = root.appendingPathComponent("tests/fixtures/notes/cross-client-v1.json")

    static func swiftRecords() throws -> [NotesRecord] {
        let note = UUID(uuidString: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!
        let key = Data((0..<32).map { UInt8($0 * 7 % 251) })
        let full = NoteMedia(blobID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, key: key,
                             sha256: String(repeating: "ab", count: 32), bytes: 123_456, type: NoteMedia.png, width: 1_170, height: 603)
        let thumb = NoteMedia(blobID: UUID(uuidString: "66666666-7777-4888-9999-aaaaaaaaaaaa")!, key: Data(key.reversed()),
                              sha256: String(repeating: "cd", count: 32), bytes: 9_876, type: NoteMedia.jpeg, width: 480, height: 247)
        let emoji = String(repeating: "🧠", count: 79) + "é"
        return [
            .note(NoteRecord(noteID: note, title: emoji, createdAt: 1_792_900_000_123)),
            .note(NoteRecord(noteID: UUID(uuidString: "b1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!, title: "Préférence · “learning” / \\ DPO", createdAt: 0)),
            .entry(NoteEntryRecord(entryID: UUID(uuidString: "c1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!, noteID: note, kind: .region, counter: 2_147_483_647,
                capturedAt: 1_792_900_060_000, offsetMinutes: 840,
                comment: "Line one\nTab\there \"quoted\" \\ back </script> \u{1} ✓ 🧠",
                source: NoteSource(kind: .arxiv, title: "Direct Preference Optimization", authors: ["Rafael Rafailov", "Ζήτα Ωμέγα"],
                                   sourceID: "2305.18290", revision: 3, url: "https://arxiv.org/abs/2305.18290v3", section: "4 Direct Preference Optimization",
                                   label: "Figure 2", membershipID: UUID(uuidString: "d1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!),
                anchor: NoteAnchor(manifestSHA256: String(repeating: "0f", count: 32), rendererRevision: 16,
                                   blockIDs: ["b-de424d551000-37", "b_2", "S1.F2"].filter(NoteAnchor.isBlockID),
                                   rects: [[0.0001, 0.00001, 0.75, 0.1234], [0, 0.5, 1, 0.0000001]], viewport: [390.5, 844, 3], quote: nil),
                quote: nil, media: NoteMediaSet(full: full, thumb: thumb))),
            .entry(NoteEntryRecord(entryID: UUID(uuidString: "e1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!, noteID: note, kind: .quote, counter: 3,
                capturedAt: 1_792_900_120_000, offsetMinutes: -720, comment: "",
                source: NoteSource(kind: .document, title: "Reading machine learning papers", sourceID: "aaaaaaaa-0000-0000-0000-000000000001"),
                anchor: NoteAnchor(manifestSHA256: String(repeating: "1e", count: 32), rendererRevision: 0, blockIDs: [], rects: [],
                                   viewport: nil, quote: "∑ᵢ xᵢ — “quoted”"),
                quote: "∑ᵢ xᵢ — “quoted”")),
            .entry(NoteEntryRecord(entryID: UUID(uuidString: "f1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!, noteID: note, kind: .region, counter: 4,
                capturedAt: 1_792_900_180_000, offsetMinutes: 0, comment: "Page crop",
                source: NoteSource(kind: .localPDF, title: "A local PDF", authors: [], sourceID: "2401.00001", revision: 1,
                                   url: "https://arxiv.org/abs/2401.00001v1", pdfSHA256: String(repeating: "9a", count: 32), page: 12),
                media: NoteMediaSet(full: full))),
            .entry(NoteEntryRecord(entryID: UUID(uuidString: "a2b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!, noteID: note, kind: .text, counter: 5,
                capturedAt: 1_792_900_240_000, offsetMinutes: 330, comment: "Compare with IPO next.")),
        ]
    }

    @Test func swiftWrittenRecordsKeepTheirPinnedBytes() throws {
        let records = try Self.swiftRecords()
        for record in records { try record.validate() }
        let encoded = records.map { String(decoding: $0.encoded(), as: UTF8.self) }
        if let output = ProcessInfo.processInfo.environment["NOTES_INTEROP_WRITE"] {
            try JSONSerialization.data(withJSONObject: ["swiftWritten": encoded], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
            return
        }
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.path)) as? [String: Any])
        #expect(fixture["swiftWritten"] as? [String] == encoded, "Swift writes the bytes the browser verified")
        // And they read back as the same records.
        for (record, text) in zip(records, encoded) { #expect(try NotesRecord.decode(json: Data(text.utf8)) == record) }
    }

    @Test func browserWrittenRecordsReadValidateAndReencodeByteForByte() throws {
        guard ProcessInfo.processInfo.environment["NOTES_INTEROP_WRITE"] == nil else { return }
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.path)) as? [String: Any])
        let written = try #require(fixture["browserWritten"] as? [String])
        #expect(written.count >= 6)
        for text in written {
            let event = PrivateEvent(kind: .note, entityID: UUID(), text: text)
            guard case .record(let record) = NotesRecord.decode(PrivateEvent(kind: .note, entityID: try Self.entity(text), text: text)) else {
                Issue.record("Swift refused a browser record: \(NotesRecord.decode(event)) \(text.prefix(120))"); continue
            }
            #expect(String(decoding: record.encoded(), as: UTF8.self) == text, "Re-encodes byte for byte: \(text.prefix(120))")
        }
    }

    private static func entity(_ text: String) throws -> UUID {
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try #require(UUID(uuidString: (object["entryID"] ?? object["noteID"]) as? String ?? ""))
    }
}

import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// Notes v1 against the shared fixture (tests/fixtures/notes/notes-v1.json): the records Swift, the browser and the
/// server must agree on byte for byte, the invalid and future records, and the exact blob encryption vector.
@Suite struct NotesTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let fixtureData = try! Data(contentsOf: root.appendingPathComponent("tests/fixtures/notes/notes-v1.json"))
    private static var fixture: [String: Any] { try! JSONSerialization.jsonObject(with: fixtureData) as! [String: Any] }
    private static var records: [String: Any] { fixture["records"] as! [String: Any] }
    private let device = UUID()

    /// The fixture without insignificant whitespace: exactly what JSON.stringify writes for the same objects.
    private static let minified: String = {
        var out = "", inString = false, escaped = false
        for character in String(decoding: fixtureData, as: UTF8.self) {
            if inString {
                out.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" { inString = true; out.append(character) }
            else if !character.isWhitespace { out.append(character) }
        }
        return out
    }()

    private static func recordData(_ name: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: records[name]!)
    }
    private static func record(_ name: String) throws -> NotesRecord { try NotesRecord.decode(json: recordData(name)) }

    private func applied(_ record: NotesRecord, id: UUID = UUID(), parents: [UUID] = [], createdAt: Int64? = nil) throws -> AppliedEvent {
        AppliedEvent(id: id, deviceID: device, payload: try record.event(parents: parents, createdAt: createdAt))
    }
    private func state(_ events: [AppliedEvent]) throws -> PrivateState {
        var value = PrivateState(); for event in events { try value.apply(event) }; return value
    }

    // MARK: Fixture records

    @Test(arguments: ["note", "entry", "quoteEntry", "textEntry", "noteRenamed", "entryCommentEdited"])
    func fixtureRecordsDecodeValidateAndEncodeByteForByte(_ name: String) throws {
        let record = try Self.record(name)
        try record.validate()
        let encoded = String(decoding: record.encoded(), as: UTF8.self)
        #expect(Self.minified.contains("\"\(name)\":" + encoded + ","), "\(name) re-encodes to the fixture's exact bytes")
        // Through an event and back: the same record and the same bytes.
        let event = try record.event()
        #expect(event.kind == .note && event.entityID == record.entityID && event.parents.isEmpty)
        #expect(event.text == encoded)
        #expect(NotesRecord.decode(event) == .record(record))
    }

    @Test func fixtureRecordFieldsMatchTheContract() throws {
        guard case .entry(let entry) = try Self.record("entry") else { Issue.record("not an entry"); return }
        #expect(entry.kind == .region && entry.counter == 1 && entry.offsetMinutes == -420)
        #expect(entry.source?.kind == .arxiv && entry.source?.revision == 3 && entry.source?.label == "Equation (7)")
        #expect(entry.anchor?.rects == [[0.08, 0.41, 0.84, 0.12]] && entry.anchor?.viewport == [390, 844, 3])
        #expect(entry.media?.full.key == Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        #expect(entry.media?.thumb == nil)
        guard case .entry(let quote) = try Self.record("quoteEntry"), case .entry(let text) = try Self.record("textEntry") else { return }
        #expect(quote.kind == .quote && quote.quote?.hasPrefix("Large unsupervised") == true && quote.source?.section == nil)
        #expect(text.kind == .text && text.source == nil && text.anchor == nil && text.media == nil)
    }

    @Test func invalidRecordsFailWithTheirStatedReasons() throws {
        let invalid = Self.records["invalid"] as! [[String: Any]]
        let reasons = Self.records["invalidReasons"] as! [String]
        #expect(invalid.count == reasons.count)
        for (object, reason) in zip(invalid, reasons) {
            let data = try JSONSerialization.data(withJSONObject: object)
            let event = PrivateEvent(kind: .note, entityID: UUID(uuidString: (object["entryID"] ?? object["noteID"]) as! String)!,
                                     text: String(decoding: data, as: UTF8.self))
            #expect(NotesRecord.decode(event) == .malformed(reason: reason), "\(reason)")
            // Writers refuse the same record.
            if let record = try? NotesRecord.decode(json: data) { #expect(throws: NotesValidationError(reason)) { try record.event() } }
        }
    }

    @Test func futureRecordsAreKeptCountedAndNeverShownAsKnownNotes() throws {
        let future = (Self.records["future"] as! [[String: Any]])[0]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: future), as: UTF8.self)
        let entryID = UUID(uuidString: future["entryID"] as! String)!
        let event = PrivateEvent(kind: .note, entityID: entryID, text: text)
        #expect(NotesRecord.decode(event) == .future(format: "gradstep-notes-v2", noteID: UUID(uuidString: future["noteID"] as! String)))
        let note = try applied(Self.record("note"))
        let projection = NotesState(try state([note, AppliedEvent(id: UUID(), deviceID: device, payload: event)]))
        #expect(projection.futureRecordCount == 1 && projection.malformedCount == 0)
        #expect(projection.notes.count == 1 && projection.notes[0].entries.isEmpty && projection.notes[0].futureEntryCount == 1)
        // A future note record: listed for "Update Gradstep", not as a note.
        let futureNoteID = UUID()
        let futureNote = AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .note, entityID: futureNoteID,
            text: "{\"format\":\"gradstep-notes-v9\",\"record\":\"note\",\"noteID\":\"\(futureNoteID.wire)\"}"))
        let withNote = NotesState(try state([futureNote]))
        #expect(withNote.notes.isEmpty && withNote.futureNoteIDs == [futureNoteID])
    }

    // MARK: Blob cryptography

    @Test func encryptionVectorMatchesByteForByte() throws {
        let blob = Self.fixture["blob"] as! [String: String]
        let account = UUID(uuidString: blob["accountID"]!)!, blobID = UUID(uuidString: blob["blobID"]!)!
        #expect(NoteBlobCrypto.aad(accountID: account, blobID: blobID) == Data(blob["aad"]!.utf8))
        let sealed = try NoteBlobCrypto.seal(Data(hex: blob["plaintextHex"]!)!, type: NoteMedia.png, width: 1, height: 1, accountID: account,
                                             blobID: blobID, key: Data(hex: blob["keyHex"]!)!, nonce: Data(hex: blob["nonceHex"]!)!)
        #expect(sealed.blob.hex == blob["blobHex"])
        #expect(sealed.media.sha256 == blob["blobSHA256"])
        guard case .entry(let entry) = try Self.record("entry"), let media = entry.media?.full else { Issue.record("no media"); return }
        #expect(sealed.media == media, "The fixture entry's descriptor is this blob's")
        #expect(try NoteBlobCrypto.open(sealed.blob, media: media, accountID: account) == Data(hex: blob["plaintextHex"]!))
    }

    @Test func openingChecksDigestTagAccountAndMagicBytes() throws {
        let account = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let sealed = try NoteBlobCrypto.seal(png, type: NoteMedia.png, width: 4, height: 3, accountID: account)
        #expect(try NoteBlobCrypto.open(sealed.blob, media: sealed.media, accountID: account) == png)
        var flipped = sealed.blob; flipped[flipped.count - 1] ^= 1
        #expect(throws: NoteBlobCrypto.Failure.digest) { try NoteBlobCrypto.open(flipped, media: sealed.media, accountID: account) }
        let retagged = NoteMedia(blobID: sealed.media.blobID, key: sealed.media.key, sha256: Data(SHA256.hash(data: flipped)).hex,
                                 bytes: flipped.count, type: NoteMedia.png, width: 4, height: 3)
        #expect(throws: NoteBlobCrypto.Failure.authentication) { try NoteBlobCrypto.open(flipped, media: retagged, accountID: account) }
        #expect(throws: NoteBlobCrypto.Failure.authentication) { try NoteBlobCrypto.open(sealed.blob, media: sealed.media, accountID: UUID()) }
        let jpegClaim = NoteMedia(blobID: sealed.media.blobID, key: sealed.media.key, sha256: sealed.media.sha256, bytes: sealed.media.bytes,
                                  type: NoteMedia.jpeg, width: 4, height: 3)
        #expect(throws: NoteBlobCrypto.Failure.mediaType) { try NoteBlobCrypto.open(sealed.blob, media: jpegClaim, accountID: account) }
        #expect(throws: NoteBlobCrypto.Failure.size) { try NoteBlobCrypto.open(sealed.blob.dropLast(), media: sealed.media, accountID: account) }
        #expect(throws: NoteBlobCrypto.Failure.dimensions) { try NoteBlobCrypto.checkDimensions(width: 4, height: 4, media: sealed.media) }
        try NoteBlobCrypto.checkDimensions(width: 4, height: 3, media: sealed.media)
        // Fresh key and nonce per blob.
        let again = try NoteBlobCrypto.seal(png, type: NoteMedia.png, width: 4, height: 3, accountID: account, blobID: sealed.media.blobID)
        #expect(again.blob != sealed.blob && again.media.key != sealed.media.key)
    }

    // MARK: Reducer

    private func entry(_ note: UUID, counter: Int64, id: UUID = UUID(), comment: String = "", kind: NoteEntryRecord.Kind = .text,
                       captured: Int64 = 1_792_900_000_000) -> NoteEntryRecord {
        NoteEntryRecord(entryID: id, noteID: note, kind: kind, counter: counter, capturedAt: captured, offsetMinutes: 0, comment: comment,
                        quote: kind == .quote ? "A quotation" : nil)
    }

    @Test func entriesOrderByCounterThenIDWhateverTheArrivalOrder() throws {
        let noteID = UUID()
        let note = try applied(.note(NoteRecord(noteID: noteID, title: "Project", createdAt: 1)))
        let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, high = UUID(uuidString: "ffffffff-0000-4000-8000-000000000001")!
        let a = try applied(.entry(entry(noteID, counter: 2, id: high, comment: "second (tie, larger ID)")))
        let b = try applied(.entry(entry(noteID, counter: 2, id: low, comment: "second (tie, smaller ID)")))
        let c = try applied(.entry(entry(noteID, counter: 1, comment: "first")))
        let d = try applied(.entry(entry(noteID, counter: 7, kind: .quote)))
        for order in [[note, a, b, c, d], [d, c, b, a, note], [b, note, d, a, c]] {
            let projection = NotesState(try state(order))
            #expect(projection.notes.count == 1)
            #expect(projection.notes[0].entries.map(\.record.comment) == ["first", "second (tie, smaller ID)", "second (tie, larger ID)", ""])
            #expect(projection.nextCounter(for: noteID) == 8 && projection.notes[0].nextCounter == 8)
        }
        #expect(NotesState().nextCounter(for: noteID) == 1)
    }

    @Test func renamesAndCommentEditsAreCausalRevisionsAndConflictsKeepBothVersions() throws {
        let note = try Self.record("note"), renamed = try Self.record("noteRenamed")
        let created = try Self.record("entry"), edited = try Self.record("entryCommentEdited")
        let noteEvent = try applied(note), entryEvent = try applied(created)
        let rename = try applied(renamed, parents: [noteEvent.id])
        let edit = try applied(edited, parents: [entryEvent.id])
        var projection = NotesState(try state([edit, rename, entryEvent, noteEvent]))
        #expect(projection.notes[0].title == "Preference learning (DPO, IPO)" && !projection.notes[0].hasConflict)
        #expect(projection.notes[0].entries[0].record.comment == "Edited: the margin is scaled by beta.")
        #expect(!projection.notes[0].entries[0].hasConflict && projection.notes[0].entries[0].headIDs == [edit.id])

        // A concurrent comment on another device: both survive; the greatest event ID is shown first.
        guard case .entry(var other) = created else { return }
        other.comment = "Concurrent edit"
        let concurrent = try applied(.entry(other), id: UUID(uuidString: "ffffffff-ffff-4fff-bfff-ffffffffffff")!, parents: [entryEvent.id])
        var journal = try state([noteEvent, entryEvent, edit, rename, concurrent])
        projection = NotesState(journal)
        let conflicted = projection.notes[0].entries[0]
        #expect(conflicted.hasConflict && conflicted.heads.count == 2)
        #expect(conflicted.record.comment == "Concurrent edit", "The deterministic winner is the greatest event ID")
        // Choosing a version names every head; the conflict ends.
        guard case .entry(var chosen) = edited else { return }
        chosen.comment = "Edited: the margin is scaled by beta."
        let resolution = try applied(.entry(chosen), parents: conflicted.headIDs)
        try journal.apply(resolution)
        projection = NotesState(journal)
        #expect(!projection.notes[0].entries[0].hasConflict && projection.notes[0].entries[0].record.comment == chosen.comment)
    }

    @Test func revisionsCannotRewriteImmutableFields() throws {
        let noteID = UUID()
        let original = entry(noteID, counter: 1, comment: "original")
        let note = try applied(.note(NoteRecord(noteID: noteID, title: "N", createdAt: 1))), first = try applied(.entry(original))
        let moved = NoteEntryRecord(entryID: original.entryID, noteID: UUID(), kind: .text, counter: 1, capturedAt: original.capturedAt,
                                    offsetMinutes: 0, comment: "moved to another note")
        let reordered = NoteEntryRecord(entryID: original.entryID, noteID: noteID, kind: .text, counter: 9, capturedAt: original.capturedAt,
                                        offsetMinutes: 0, comment: "reordered")
        let renamedDate = NoteRecord(noteID: noteID, title: "Other", createdAt: 99)
        let projection = NotesState(try state([note, first, try applied(.entry(moved), parents: [first.id]),
                                                try applied(.entry(reordered), parents: [first.id]),
                                                try applied(.note(renamedDate), parents: [note.id])]))
        #expect(projection.malformedCount == 3)
        #expect(projection.notes[0].title == "N" && projection.notes[0].entries.map(\.record.comment) == ["original"])
    }

    @Test func tombstonesHideNotesAndEntriesPermanentlyAndCountersStillAdvance() throws {
        let noteID = UUID()
        let note = try applied(.note(NoteRecord(noteID: noteID, title: "N", createdAt: 1)))
        let kept = try applied(.entry(entry(noteID, counter: 1, comment: "kept")))
        let removed = try applied(.entry(entry(noteID, counter: 5, comment: "removed")))
        guard case .entry(let removedRecord) = NotesRecord.decode(removed.payload).record else { return }
        let removal = AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: removedRecord.entryID))
        var journal = try state([note, kept, removed, removal])
        var projection = NotesState(journal)
        #expect(projection.notes[0].entries.map(\.record.comment) == ["kept"])
        #expect(projection.nextCounter(for: noteID) == 6, "A removed entry's counter is never reused")
        // A stale revision of the removed entry cannot resurrect it.
        var stale = removedRecord; stale.comment = "stale edit"
        try journal.apply(applied(.entry(stale), parents: [removed.id]))
        #expect(NotesState(journal).notes[0].entries.count == 1)
        // Deleting the note hides it and its entries.
        try journal.apply(AppliedEvent(id: UUID(), deviceID: device, payload: PrivateEvent(kind: .tombstone, entityID: noteID)))
        projection = NotesState(journal)
        #expect(projection.notes.isEmpty && projection.isDeleted(noteID) && projection.incompleteEntryCount == 0)
    }

    @Test func anEntryWithoutItsNoteIsIncompleteNotReassigned() throws {
        let noteID = UUID(), other = UUID()
        let otherNote = try applied(.note(NoteRecord(noteID: other, title: "Quick notes", createdAt: 1)))
        let orphan = try applied(.entry(entry(noteID, counter: 1)))
        var journal = try state([otherNote, orphan])
        var projection = NotesState(journal)
        #expect(projection.incompleteEntryCount == 1 && projection.notes.map(\.title) == ["Quick notes"] && projection.notes[0].entries.isEmpty)
        try journal.apply(applied(.note(NoteRecord(noteID: noteID, title: "Arrived", createdAt: 2))))
        projection = NotesState(journal)
        #expect(projection.incompleteEntryCount == 0 && projection.note(noteID)?.entries.count == 1)
    }

    @Test func malformedEventsAreCountedAndOtherNoteEventsIgnored() throws {
        let noteID = UUID()
        let note = try applied(.note(NoteRecord(noteID: noteID, title: "N", createdAt: 1)))
        // The record's ID must be the event's entity.
        var mismatched = note.payload; mismatched = PrivateEvent(kind: .note, entityID: UUID(), text: mismatched.text)
        let garbage = PrivateEvent(kind: .note, entityID: UUID(), text: "{\"format\":\"gradstep-notes-v1\",\"record\":\"note\"}")
        let catalog = try LibraryCatalogBatch(operations: [.init(.create, catalogID: UUID(), name: "Robotics")]).event(in: PrivateState())
        let legacy = PrivateEvent(kind: .note, entityID: UUID(), text: "A plain note from an early build")
        let projection = NotesState(try state([note] + [mismatched, garbage, catalog, legacy].map {
            AppliedEvent(id: UUID(), deviceID: device, payload: $0)
        }))
        #expect(projection.notes.count == 1 && projection.malformedCount == 2 && projection.futureRecordCount == 0)
        #expect(NotesRecord.decode(catalog) == .other && NotesRecord.decode(legacy) == .other)
    }

    @Test func libraryCatalogReducerIgnoresNotesRecords() throws {
        let other = UUID()
        let catalog = try LibraryCatalogBatch(operations: [.init(.create, catalogID: other, name: "Robotics"), .init(.makeDefault, catalogID: other)])
            .event(in: PrivateState())
        let base = [AppliedEvent(id: UUID(), deviceID: device, payload: catalog)]
        let notes = try ["note", "entry", "quoteEntry", "textEntry"].map { try applied(Self.record($0)) }
        let withNotes = try state(base + notes), without = try state(base)
        #expect(LibraryCatalogState(withNotes) == LibraryCatalogState(without))
        #expect(LibraryCatalogState(withNotes).catalogs.map(\.name).sorted() == ["Default", "Robotics"])
        #expect(NotesState(withNotes).notes.first?.entries.count == 3 && NotesState(without).notes.isEmpty)
    }

    @Test func notesEventsSealAsFormatOneForOlderClients() throws {
        // Older clients decode any `note` event and only look for catalog records: Notes records travel as ordinary
        // format-1 envelopes, which every released client opens, keeps and ignores.
        let keys = KeyBundle.generate(accountID: UUID())
        for name in ["note", "entry", "quoteEntry", "textEntry"] {
            let event = try Self.record(name).event()
            let envelope = try ReaderCrypto.seal(event, id: UUID(), deviceID: device, keys: keys)
            #expect(envelope.format == 1)
            #expect(try ReaderCrypto.open(envelope, keys: keys) == event)
        }
    }

    @Test func canonicalNumbersMatchJavaScript() {
        #expect(NotesJSON.number(0.08) == "0.08" && NotesJSON.number(390) == "390" && NotesJSON.number(0.5) == "0.5")
        #expect(NotesJSON.number(0.00001) == "0.00001" && NotesJSON.number(1e-7) == "1e-7" && NotesJSON.number(-0.000002) == "-0.000002")
        #expect(NotesJSON.number(0.1 + 0.2) == "0.30000000000000004" && NotesJSON.number(0) == "0")
        #expect(NoteAnchor.rect(CGRect(x: 31.2, y: 346.04, width: 327.6, height: 101.28), in: CGSize(width: 390, height: 844))
                == [0.08, 0.41, 0.84, 0.12])
        // Escaping as JSON.stringify: control characters, quotes and backslashes; "/" and non-ASCII as is.
        let text = NotesJSON.string("a\"b\\c/d\u{1}é\n").data
        #expect(String(decoding: text, as: UTF8.self) == "\"a\\\"b\\\\c/d\\u0001é\\n\"")
    }
}

extension NotesRecord.Decoded {
    var record: NotesRecord? { if case .record(let value) = self { value } else { nil } }
}

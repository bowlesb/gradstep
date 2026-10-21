import CryptoKit
import Foundation

// Notes and snippets (docs/architecture/NOTES_AND_SNIPPETS.md, "Implementation contract"): named notes holding an
// ordered stream of captured regions, quotations and the reader's own writing. Each record is a `PrivateEvent` of kind
// `note` whose `text` is one JSON object with `format == "gradstep-notes-v1"`. Every other `note` event (Library
// catalogs, anything older) is ignored here, and the catalog reducer ignores these records.
//
// Canonical encoding: compact JSON with the contract's keys in the contract's order — what `JSON.stringify` writes
// for an object built in that order. Nullable keys are written as `null`; optional keys (`membershipID`, `pdfSHA256`,
// `page`, `thumb`) are left out when absent. tests/fixtures/notes/notes-v1.json pins the bytes for Swift, the browser
// and the server.

public enum NotesFormat {
    public static let v1 = "gradstep-notes-v1"
    /// A later version of this namespace: kept, counted and shown as "Update Gradstep to see this note".
    static let namespace = "gradstep-notes-"
    /// Encoded record bound (contract: 48 KiB).
    public static let maximumRecordBytes = 48 * 1024
    public static let maximumTitleScalars = 80
    public static let maximumCommentBytes = 16 * 1024
    public static let maximumQuoteBytes = 20 * 1024
    public static let maximumBlockIDs = 64
    public static let maximumRects = 64
    /// The largest integer every client represents exactly (JavaScript's safe integer).
    public static let maximumInteger: Int64 = 9_007_199_254_740_991
    /// Stored blob limits (nonce ‖ ciphertext ‖ tag): full image 2 MiB of image bytes, thumbnail 64 KiB.
    public static let maximumFullImageBytes = 2 * 1024 * 1024
    public static let maximumThumbnailBytes = 64 * 1024
    public static let blobOverhead = 28
    public static let maximumImageEdge = 4_096
    public static let maximumImagePixels = 6_000_000
    public static let maximumThumbnailEdge = 480
}

public struct NotesValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

// MARK: - Records

public struct NoteRecord: Equatable, Sendable {
    public let noteID: UUID
    public var title: String
    public let createdAt: Int64

    public init(noteID: UUID = UUID(), title: String, createdAt: Int64) {
        self.noteID = noteID; self.title = title; self.createdAt = createdAt
    }

    /// A title as the reader typed it, trimmed; nil when it is empty, too long or has control characters.
    public static func normalizedTitle(_ input: String) -> String? {
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= NotesFormat.maximumTitleScalars,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return title
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NotesValidationError("empty title") }
        guard title.unicodeScalars.count <= NotesFormat.maximumTitleScalars else { throw NotesValidationError("title over 80 Unicode scalars") }
        guard NoteRecord.normalizedTitle(title) == title else { throw NotesValidationError("title not trimmed") }
        try NotesJSON.validateTimestamp(createdAt, "createdAt")
    }

    var json: NotesJSON {
        .object([("format", .string(NotesFormat.v1)), ("record", .string("note")), ("noteID", .string(noteID.wire)),
                 ("title", .string(title)), ("createdAt", .int(createdAt))])
    }
}

public struct NoteSource: Equatable, Sendable {
    public enum Kind: String, Sendable { case arxiv, localPDF = "local_pdf", document }
    public let kind: Kind
    public let title: String
    public let authors: [String]
    public let sourceID: String?
    public let revision: Int?
    public let url: String?
    public let section: String?
    public let label: String?
    public let membershipID: UUID?
    public let pdfSHA256: String?
    /// One-based page of a local PDF.
    public let page: Int?

    public init(kind: Kind, title: String, authors: [String] = [], sourceID: String? = nil, revision: Int? = nil, url: String? = nil,
                section: String? = nil, label: String? = nil, membershipID: UUID? = nil, pdfSHA256: String? = nil, page: Int? = nil) {
        self.kind = kind; self.title = title; self.authors = authors; self.sourceID = sourceID; self.revision = revision
        self.url = url; self.section = section; self.label = label; self.membershipID = membershipID
        self.pdfSHA256 = pdfSHA256; self.page = page
    }

    func validate() throws {
        guard title.utf8.count <= 2_048, authors.count <= 64, authors.allSatisfy({ $0.utf8.count <= 512 }),
              (sourceID?.utf8.count ?? 0) <= 256, (url?.utf8.count ?? 0) <= 2_048,
              (section?.utf8.count ?? 0) <= 1_024, (label?.utf8.count ?? 0) <= 256 else { throw NotesValidationError("source over its bounds") }
        if let revision { guard (0...100_000).contains(revision) else { throw NotesValidationError("invalid source revision") } }
        if let page { guard (1...100_000).contains(page) else { throw NotesValidationError("invalid source page") } }
        if let pdfSHA256 { guard NotesJSON.isSHA256(pdfSHA256) else { throw NotesValidationError("invalid pdfSHA256") } }
        if let url { guard let parsed = URL(string: url), parsed.scheme == "https" else { throw NotesValidationError("invalid source url") } }
    }

    var json: NotesJSON {
        var fields: [(String, NotesJSON)] = [("kind", .string(kind.rawValue)), ("title", .string(title)),
            ("authors", .array(authors.map(NotesJSON.string))), ("sourceID", .optionalString(sourceID)),
            ("revision", revision.map { .int(Int64($0)) } ?? .null), ("url", .optionalString(url)),
            ("section", .optionalString(section)), ("label", .optionalString(label))]
        if let membershipID { fields.append(("membershipID", .string(membershipID.wire))) }
        if let pdfSHA256 { fields.append(("pdfSHA256", .string(pdfSHA256))) }
        if let page { fields.append(("page", .int(Int64(page)))) }
        return .object(fields)
    }
}

public struct NoteAnchor: Equatable, Sendable {
    public let manifestSHA256: String
    public let rendererRevision: Int
    public let blockIDs: [String]
    /// Viewport-relative rectangles, each [x, y, w, h] in 0…1.
    public let rects: [[Double]]
    /// [width, height, scale] of the viewport the rectangles are relative to.
    public let viewport: [Double]?
    public let quote: String?

    public init(manifestSHA256: String, rendererRevision: Int, blockIDs: [String], rects: [[Double]], viewport: [Double]?, quote: String?) {
        self.manifestSHA256 = manifestSHA256; self.rendererRevision = rendererRevision; self.blockIDs = blockIDs
        self.rects = rects; self.viewport = viewport; self.quote = quote
    }

    /// A normalized rectangle rounded so that every client writes the same digits (1/10,000 of the viewport).
    public static func rect(_ value: CGRect, in viewport: CGSize) -> [Double] {
        guard viewport.width > 0, viewport.height > 0 else { return [0, 0, 0, 0] }
        func unit(_ x: Double) -> Double { (min(1, max(0, x)) * 10_000).rounded() / 10_000 }
        let x = unit(value.minX / viewport.width), y = unit(value.minY / viewport.height)
        return [x, y, min(unit(value.width / viewport.width), 1 - x), min(unit(value.height / viewport.height), 1 - y)]
    }

    func validate() throws {
        guard NotesJSON.isSHA256(manifestSHA256) else { throw NotesValidationError("invalid manifestSHA256") }
        guard (0...1_000_000).contains(rendererRevision) else { throw NotesValidationError("invalid rendererRevision") }
        guard blockIDs.count <= NotesFormat.maximumBlockIDs, blockIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }) else {
            throw NotesValidationError("too many source blocks")
        }
        guard rects.count <= NotesFormat.maximumRects, rects.allSatisfy({ rect in
            rect.count == 4 && rect.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && rect[0] + rect[2] <= 1.001 && rect[1] + rect[3] <= 1.001
        }) else { throw NotesValidationError("invalid anchor rects") }
        if let viewport {
            guard viewport.count == 3, viewport.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100_000 }) else { throw NotesValidationError("invalid viewport") }
        }
        guard (quote?.utf8.count ?? 0) <= NotesFormat.maximumQuoteBytes else { throw NotesValidationError("anchor quote over 20 KiB") }
    }

    var json: NotesJSON {
        .object([("manifestSHA256", .string(manifestSHA256)), ("rendererRevision", .int(Int64(rendererRevision))),
                 ("blockIDs", .array(blockIDs.map(NotesJSON.string))),
                 ("rects", .array(rects.map { .array($0.map(NotesJSON.double)) })),
                 ("viewport", viewport.map { .array($0.map(NotesJSON.double)) } ?? .null),
                 ("quote", .optionalString(quote))])
    }
}

public struct NoteMedia: Equatable, Sendable {
    public static let png = "image/png", jpeg = "image/jpeg"
    public let blobID: UUID
    /// The blob's own 256-bit AES-GCM key. It exists only inside this encrypted record.
    public let key: Data
    /// Lowercase hex SHA-256 of the stored blob (nonce ‖ ciphertext ‖ tag).
    public let sha256: String
    /// Stored blob length.
    public let bytes: Int
    public let type: String
    public let width: Int
    public let height: Int

    public init(blobID: UUID, key: Data, sha256: String, bytes: Int, type: String, width: Int, height: Int) {
        self.blobID = blobID; self.key = key; self.sha256 = sha256; self.bytes = bytes; self.type = type
        self.width = width; self.height = height
    }

    func validate(thumbnail: Bool) throws {
        guard key.count == 32 else { throw NotesValidationError("media key is not 32 bytes") }
        guard NotesJSON.isSHA256(sha256) else { throw NotesValidationError("invalid media sha256") }
        guard [Self.png, Self.jpeg].contains(type) else { throw NotesValidationError("unsupported media type") }
        let limit = (thumbnail ? NotesFormat.maximumThumbnailBytes : NotesFormat.maximumFullImageBytes) + NotesFormat.blobOverhead
        guard bytes > NotesFormat.blobOverhead, bytes <= limit else { throw NotesValidationError("media over its size limit") }
        let edge = thumbnail ? NotesFormat.maximumThumbnailEdge : NotesFormat.maximumImageEdge
        guard width > 0, height > 0, width <= edge, height <= edge, width * height <= NotesFormat.maximumImagePixels else {
            throw NotesValidationError("media dimensions over their limit")
        }
    }

    var json: NotesJSON {
        .object([("blobID", .string(blobID.wire)), ("key", .string(key.base64EncodedString())), ("sha256", .string(sha256)),
                 ("bytes", .int(Int64(bytes))), ("type", .string(type)), ("width", .int(Int64(width))), ("height", .int(Int64(height)))])
    }
}

public struct NoteMediaSet: Equatable, Sendable {
    public let full: NoteMedia
    public let thumb: NoteMedia?
    public init(full: NoteMedia, thumb: NoteMedia? = nil) { self.full = full; self.thumb = thumb }
    public var all: [NoteMedia] { [full] + (thumb.map { [$0] } ?? []) }

    var json: NotesJSON {
        var fields: [(String, NotesJSON)] = [("full", full.json)]
        if let thumb { fields.append(("thumb", thumb.json)) }
        return .object(fields)
    }
}

public struct NoteEntryRecord: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case region, quote, text }
    public let entryID: UUID
    public let noteID: UUID
    public let kind: Kind
    public let counter: Int64
    public let capturedAt: Int64
    public let offsetMinutes: Int
    public var comment: String
    public let source: NoteSource?
    public let anchor: NoteAnchor?
    public let quote: String?
    public let media: NoteMediaSet?

    public init(entryID: UUID = UUID(), noteID: UUID, kind: Kind, counter: Int64, capturedAt: Int64, offsetMinutes: Int,
                comment: String, source: NoteSource? = nil, anchor: NoteAnchor? = nil, quote: String? = nil, media: NoteMediaSet? = nil) {
        self.entryID = entryID; self.noteID = noteID; self.kind = kind; self.counter = counter; self.capturedAt = capturedAt
        self.offsetMinutes = offsetMinutes; self.comment = comment; self.source = source; self.anchor = anchor
        self.quote = quote; self.media = media
    }

    public func validate() throws {
        guard counter >= 1 else { throw NotesValidationError("counter must be >= 1") }
        guard counter <= NotesFormat.maximumInteger else { throw NotesValidationError("counter over the safe integer range") }
        try NotesJSON.validateTimestamp(capturedAt, "capturedAt")
        // The browser's bound (±1,440): every real offset is within ±14 hours; neither client rejects the other's.
        guard (-1_440...1_440).contains(offsetMinutes) else { throw NotesValidationError("invalid offsetMinutes") }
        guard comment.utf8.count <= NotesFormat.maximumCommentBytes else { throw NotesValidationError("comment over 16 KiB") }
        guard (quote?.utf8.count ?? 0) <= NotesFormat.maximumQuoteBytes else { throw NotesValidationError("quote over 20 KiB") }
        try source?.validate()
        try anchor?.validate()
        try media?.full.validate(thumbnail: false)
        try media?.thumb?.validate(thumbnail: true)
        if let media, let thumb = media.thumb, thumb.blobID == media.full.blobID { throw NotesValidationError("thumbnail reuses the full blob") }
        switch kind {
        case .region: guard media != nil else { throw NotesValidationError("region without media") }
        case .quote: guard let quote, !quote.isEmpty, media == nil else { throw NotesValidationError("quote entry without a quote") }
        case .text: guard media == nil, quote == nil else { throw NotesValidationError("text entry with captured content") }
        }
    }

    /// Everything but `comment`: what a revision must repeat exactly.
    func sameIdentity(as other: NoteEntryRecord) -> Bool {
        var copy = other; copy.comment = comment
        return copy == self
    }

    var json: NotesJSON {
        .object([("format", .string(NotesFormat.v1)), ("record", .string("entry")), ("entryID", .string(entryID.wire)),
                 ("noteID", .string(noteID.wire)), ("kind", .string(kind.rawValue)), ("counter", .int(counter)),
                 ("capturedAt", .int(capturedAt)), ("offsetMinutes", .int(Int64(offsetMinutes))), ("comment", .string(comment)),
                 ("source", source?.json ?? .null), ("anchor", anchor?.json ?? .null), ("quote", .optionalString(quote)),
                 ("media", media?.json ?? .null)])
    }
}

/// One decoded `note` event, as far as Notes is concerned.
public enum NotesRecord: Equatable, Sendable {
    case note(NoteRecord)
    case entry(NoteEntryRecord)

    public var entityID: UUID {
        switch self { case .note(let note): note.noteID; case .entry(let entry): entry.entryID }
    }

    public func validate() throws {
        switch self { case .note(let note): try note.validate(); case .entry(let entry): try entry.validate() }
    }

    /// The canonical bytes (see the top of this file).
    public func encoded() -> Data {
        switch self { case .note(let note): note.json.data; case .entry(let entry): entry.json.data }
    }

    /// A validated record as a private event. Creation has no parents; a revision names every current head of its entity.
    public func event(parents: [UUID] = [], createdAt: Int64? = nil) throws -> PrivateEvent {
        try validate()
        let data = encoded()
        guard data.count <= NotesFormat.maximumRecordBytes else { throw NotesValidationError("record over 48 KiB") }
        guard parents.count <= 100 else { throw NotesValidationError("too many parents") }
        return PrivateEvent(kind: .note, entityID: entityID, parents: parents, text: String(decoding: data, as: UTF8.self), createdAt: createdAt)
    }

    public enum Decoded: Equatable, Sendable {
        /// Library catalogs and every other technical note: not ours.
        case other
        case record(NotesRecord)
        /// A later Notes version: kept intact and counted, never edited.
        case future(format: String, noteID: UUID?)
        /// A known record that fails validation: skipped with a visible count.
        case malformed(reason: String)
    }

    public static func decode(_ event: PrivateEvent) -> Decoded {
        guard event.kind == .note, let text = event.text else { return .other }
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = object["format"] as? String else { return .other }
        if format != NotesFormat.v1 {
            guard format.hasPrefix(NotesFormat.namespace) else { return .other }
            return .future(format: format, noteID: (object["noteID"] as? String).flatMap(UUID.init(uuidString:)))
        }
        guard data.count <= NotesFormat.maximumRecordBytes else { return .malformed(reason: "record over 48 KiB") }
        let record: NotesRecord
        do { record = try decode(object) } catch let error as NotesValidationError { return .malformed(reason: error.reason) }
        catch { return .malformed(reason: "unreadable record") }
        do { try record.validate() } catch let error as NotesValidationError { return .malformed(reason: error.reason) }
        catch { return .malformed(reason: "unreadable record") }
        guard event.entityID == record.entityID, event.documentID == nil, event.conversationID == nil, event.anchor == nil else {
            return .malformed(reason: "event does not match its record")
        }
        return .record(record)
    }

    /// Decodes one record object (a fixture or an event's text) without validating its bounds.
    public static func decode(json data: Data) throws -> NotesRecord {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotesValidationError("not an object") }
        return try decode(object)
    }

    static func decode(_ object: [String: Any]) throws -> NotesRecord {
        let read = NotesJSON.Reader(object)
        guard try read.string("format") == NotesFormat.v1 else { throw NotesValidationError("unknown format") }
        switch try read.string("record") {
        case "note":
            return .note(NoteRecord(noteID: try read.uuid("noteID"), title: try read.string("title"), createdAt: try read.int("createdAt")))
        case "entry":
            guard let kind = NoteEntryRecord.Kind(rawValue: try read.string("kind")) else { throw NotesValidationError("unknown entry kind") }
            return .entry(NoteEntryRecord(entryID: try read.uuid("entryID"), noteID: try read.uuid("noteID"), kind: kind,
                counter: try read.int("counter"), capturedAt: try read.int("capturedAt"), offsetMinutes: Int(try read.int("offsetMinutes")),
                comment: try read.string("comment"), source: try read.object("source").map(Self.source),
                anchor: try read.object("anchor").map(Self.anchor), quote: try read.optionalString("quote"),
                media: try read.object("media").map(Self.mediaSet)))
        default: throw NotesValidationError("unknown record")
        }
    }

    private static func source(_ read: NotesJSON.Reader) throws -> NoteSource {
        guard let kind = NoteSource.Kind(rawValue: try read.string("kind")) else { throw NotesValidationError("unknown source kind") }
        return NoteSource(kind: kind, title: try read.string("title"), authors: try read.strings("authors"),
                          sourceID: try read.optionalString("sourceID"), revision: try read.optionalInt("revision").map(Int.init),
                          url: try read.optionalString("url"), section: try read.optionalString("section"), label: try read.optionalString("label"),
                          membershipID: try read.optionalString("membershipID").map { value in
                              guard let id = UUID(uuidString: value) else { throw NotesValidationError("invalid membershipID") }
                              return id
                          },
                          pdfSHA256: try read.optionalString("pdfSHA256"), page: try read.optionalInt("page").map(Int.init))
    }

    private static func anchor(_ read: NotesJSON.Reader) throws -> NoteAnchor {
        NoteAnchor(manifestSHA256: try read.string("manifestSHA256"), rendererRevision: Int(try read.int("rendererRevision")),
                   blockIDs: try read.strings("blockIDs"), rects: try read.numberArrays("rects"),
                   viewport: try read.optionalNumbers("viewport"), quote: try read.optionalString("quote"))
    }

    private static func mediaSet(_ read: NotesJSON.Reader) throws -> NoteMediaSet {
        guard let full = try read.object("full") else { throw NotesValidationError("media without full image") }
        return NoteMediaSet(full: try media(full), thumb: try read.object("thumb").map(media))
    }

    private static func media(_ read: NotesJSON.Reader) throws -> NoteMedia {
        guard let key = Data(base64Encoded: try read.string("key")) else { throw NotesValidationError("invalid media key") }
        return NoteMedia(blobID: try read.uuid("blobID"), key: key, sha256: try read.string("sha256"), bytes: Int(try read.int("bytes")),
                         type: try read.string("type"), width: Int(try read.int("width")), height: Int(try read.int("height")))
    }
}

// MARK: - Reducer

/// The reader's notes, projected from the private state. Arrival order never decides anything: revisions are causal,
/// concurrent heads stay visible as versions, entries are ordered by (counter, entryID), and tombstones are permanent.
public struct NotesState: Equatable, Sendable {
    public struct Version<Record: Equatable & Sendable>: Equatable, Sendable {
        public let eventID: UUID
        public let record: Record
        /// The author's clock when the revision was written (display only).
        public let editedAt: Int64?
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public var id: UUID { record.entryID }
        /// The deterministic winner among the current heads (greatest event ID).
        public let record: NoteEntryRecord
        /// Every current head; more than one is a conflict ("2 versions").
        public let heads: [Version<NoteEntryRecord>]
        public let createdEventID: UUID?
        public var hasConflict: Bool { heads.count > 1 }
        public var headIDs: [UUID] { heads.map(\.eventID) }
        public let lastEdited: Int64
    }

    public struct Note: Identifiable, Equatable, Sendable {
        public var id: UUID { record.noteID }
        public let record: NoteRecord
        public let heads: [Version<NoteRecord>]
        public var title: String { record.title }
        public var hasConflict: Bool { heads.count > 1 }
        public var headIDs: [UUID] { heads.map(\.eventID) }
        public let entries: [Entry]
        /// Entries written by a later version of Gradstep.
        public let futureEntryCount: Int
        public let lastEdited: Int64
        /// The next entry's counter: one greater than every counter known in this note, removed entries included.
        public let nextCounter: Int64
    }

    /// Known notes, most recently active first (presentation only; identity breaks ties).
    public let notes: [Note]
    /// Note IDs that only a later version can show ("Update Gradstep to see this note").
    public let futureNoteIDs: [UUID]
    /// Known records that failed validation (skipped, never silently).
    public let malformedCount: Int
    /// Records of a later Notes version (kept and left intact).
    public let futureRecordCount: Int
    /// Entries whose note has not arrived yet: an incomplete state, never reassigned to another note.
    public let incompleteEntryCount: Int
    private let counters: [UUID: Int64]
    private let deleted: Set<UUID>

    public init(_ state: PrivateState = PrivateState()) {
        var deleted = Set<UUID>()
        var noteEvents: [UUID: [(AppliedEvent, NoteRecord)]] = [:], entryEvents: [UUID: [(AppliedEvent, NoteEntryRecord)]] = [:]
        var malformed = 0, future = 0, futureNotes = Set<UUID>(), futureEntries: [UUID: Int] = [:]
        for event in state.events.values {
            if event.payload.kind == .tombstone { deleted.insert(event.payload.entityID); continue }
            switch NotesRecord.decode(event.payload) {
            case .other: continue
            case .malformed: malformed += 1
            case .future(_, let noteID):
                future += 1
                if let noteID {
                    if noteID == event.payload.entityID { futureNotes.insert(noteID) } else { futureEntries[noteID, default: 0] += 1 }
                }
            case .record(.note(let note)): noteEvents[note.noteID, default: []].append((event, note))
            case .record(.entry(let entry)): entryEvents[entry.entryID, default: []].append((event, entry))
            }
        }

        var counters: [UUID: Int64] = [:]
        var entriesByNote: [UUID: [Entry]] = [:], incomplete = 0
        for (entryID, revisions) in entryEvents {
            let resolved = Self.resolve(revisions, same: { $0.sameIdentity(as: $1) })
            malformed += resolved.rejected
            guard let winner = resolved.heads.last else { continue }
            let noteID = winner.record.noteID
            counters[noteID] = max(counters[noteID] ?? 0, winner.record.counter)
            guard !deleted.contains(entryID), !deleted.contains(noteID) else { continue }
            guard noteEvents[noteID] != nil else { incomplete += 1; continue }
            let edited = resolved.all.map { $0.editedAt ?? $0.record.capturedAt }.max() ?? winner.record.capturedAt
            entriesByNote[noteID, default: []].append(Entry(record: winner.record, heads: resolved.heads, createdEventID: resolved.root,
                                                            lastEdited: edited))
        }

        var notes: [Note] = []
        for (noteID, revisions) in noteEvents where !deleted.contains(noteID) {
            let resolved = Self.resolve(revisions, same: { $0.noteID == $1.noteID && $0.createdAt == $1.createdAt })
            malformed += resolved.rejected
            guard let winner = resolved.heads.last else { continue }
            let entries = (entriesByNote[noteID] ?? []).sorted {
                $0.record.counter != $1.record.counter ? $0.record.counter < $1.record.counter : $0.id.wire < $1.id.wire
            }
            let edited = (resolved.all.map { $0.editedAt ?? $0.record.createdAt } + entries.map(\.lastEdited)).max() ?? winner.record.createdAt
            notes.append(Note(record: winner.record, heads: resolved.heads, entries: entries, futureEntryCount: futureEntries[noteID] ?? 0,
                              lastEdited: edited, nextCounter: (counters[noteID] ?? 0) + 1))
        }
        self.notes = notes.sorted { $0.lastEdited != $1.lastEdited ? $0.lastEdited > $1.lastEdited : $0.id.wire < $1.id.wire }
        self.futureNoteIDs = futureNotes.subtracting(deleted).subtracting(noteEvents.keys).sorted { $0.wire < $1.wire }
        self.malformedCount = malformed
        self.futureRecordCount = future
        self.incompleteEntryCount = incomplete
        self.counters = counters
        self.deleted = deleted
    }

    public func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }
    public func isDeleted(_ id: UUID) -> Bool { deleted.contains(id) }

    /// The counter a new entry in `noteID` takes (1 for a new note).
    public func nextCounter(for noteID: UUID) -> Int64 { (counters[noteID] ?? 0) + 1 }

    public func entry(_ id: UUID) -> (note: Note, entry: Entry)? {
        for note in notes { if let entry = note.entries.first(where: { $0.id == id }) { return (note, entry) } }
        return nil
    }

    private struct Resolved<Record: Equatable & Sendable> {
        let heads: [Version<Record>]
        let all: [Version<Record>]
        let root: UUID?
        let rejected: Int
    }

    /// Heads among an entity's revisions. Revisions whose immutable fields differ from the creation record (or, before it
    /// arrives, the lowest event ID) are rejected and counted. Heads are sorted so the winner (greatest ID) is last.
    private static func resolve<Record>(_ revisions: [(AppliedEvent, Record)], same: (Record, Record) -> Bool) -> Resolved<Record> {
        let sorted = revisions.sorted { $0.0.id.wire < $1.0.id.wire }
        guard let reference = sorted.first(where: { $0.0.payload.parents.isEmpty }) ?? sorted.first else {
            return Resolved(heads: [], all: [], root: nil, rejected: 0)
        }
        let accepted = sorted.filter { $0.0.id == reference.0.id || (same($0.1, reference.1) && !($0.0.payload.parents.isEmpty && $0.0.id != reference.0.id)) }
        let superseded = Set(accepted.flatMap { $0.0.payload.parents })
        let versions = accepted.map { Version(eventID: $0.0.id, record: $0.1, editedAt: $0.0.payload.createdAt) }
        let heads = versions.filter { !superseded.contains($0.eventID) }
        return Resolved(heads: heads, all: versions, root: reference.0.payload.parents.isEmpty ? reference.0.id : nil,
                        rejected: sorted.count - accepted.count)
    }
}

// MARK: - Blob cryptography

/// AES-256-GCM for snippet images. A fresh 32-byte key and 12-byte nonce per blob; stored blob = nonce ‖ ciphertext ‖ tag;
/// AAD = "science-reader/snippet-blob/v1\n{account}\n{blob}\n" with lowercase canonical UUIDs.
public enum NoteBlobCrypto {
    public enum Failure: Error, Equatable, Sendable { case digest, authentication, mediaType, dimensions, size }

    public static func aad(accountID: UUID, blobID: UUID) -> Data {
        Data("science-reader/snippet-blob/v1\n\(accountID.wire)\n\(blobID.wire)\n".utf8)
    }

    /// Seals `plaintext` (the encoded image) into a stored blob and its descriptor. `nonce` only for fixtures.
    public static func seal(_ plaintext: Data, type: String, width: Int, height: Int, accountID: UUID, blobID: UUID = UUID(),
                            key: Data = ReaderCrypto.randomKey(), nonce: Data? = nil) throws -> (blob: Data, media: NoteMedia) {
        guard key.count == 32 else { throw ReaderError.invalidKey }
        let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: gcmNonce,
                                      authenticating: aad(accountID: accountID, blobID: blobID))
        guard let blob = sealed.combined else { throw ReaderError.corruptData }
        let media = NoteMedia(blobID: blobID, key: key, sha256: Data(SHA256.hash(data: blob)).hex, bytes: blob.count,
                              type: type, width: width, height: height)
        return (blob, media)
    }

    /// Checks the stored blob's digest and length, then the tag, then the media type's magic bytes. Callers decode the
    /// image and compare its dimensions with the record (`checkDimensions`) before showing it.
    public static func open(_ blob: Data, media: NoteMedia, accountID: UUID) throws -> Data {
        guard blob.count == media.bytes, blob.count > NotesFormat.blobOverhead else { throw Failure.size }
        guard Data(SHA256.hash(data: blob)).hex == media.sha256 else { throw Failure.digest }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: SymmetricKey(data: media.key),
                                         authenticating: aad(accountID: accountID, blobID: media.blobID))
        } catch { throw Failure.authentication }
        guard hasMagic(plaintext, type: media.type) else { throw Failure.mediaType }
        return plaintext
    }

    public static func hasMagic(_ data: Data, type: String) -> Bool {
        switch type {
        case NoteMedia.png: data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case NoteMedia.jpeg: data.starts(with: [0xFF, 0xD8, 0xFF])
        default: false
        }
    }

    /// Decoded image dimensions must equal the record's.
    public static func checkDimensions(width: Int, height: Int, media: NoteMedia) throws {
        guard width == media.width, height == media.height else { throw Failure.dimensions }
    }
}

// MARK: - Canonical JSON

enum NotesJSON: Equatable {
    case string(String), int(Int64), double(Double), null
    indirect case array([NotesJSON])
    indirect case object([(String, NotesJSON)])

    static func optionalString(_ value: String?) -> NotesJSON { value.map(NotesJSON.string) ?? .null }

    static func == (lhs: NotesJSON, rhs: NotesJSON) -> Bool { lhs.data == rhs.data }

    var data: Data { var out = ""; write(&out); return Data(out.utf8) }

    private func write(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case .int(let value): out += String(value)
        case .double(let value): out += Self.number(value)
        case .string(let value): Self.quote(value, into: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() { if index > 0 { out += "," }; value.write(&out) }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, field) in fields.enumerated() {
                if index > 0 { out += "," }
                Self.quote(field.0, into: &out); out += ":"; field.1.write(&out)
            }
            out += "}"
        }
    }

    /// JSON.stringify's string escaping: quote, backslash and control characters (short forms where JSON has them,
    /// otherwise lowercase \u00xx); everything else, including "/" and non-ASCII, as is.
    private static func quote(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }

    /// JavaScript's Number formatting for finite values: integers without a fraction, the shortest round-trip digits
    /// otherwise, decimal notation from 1e-6 up to 1e21.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        let text = value.description
        guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else { return text }
        let mantissa = String(text[..<e]), exponent = Int(text[text.index(after: e)...]) ?? 0
        let negative = mantissa.hasPrefix("-")
        let digits = mantissa.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        if exponent < 0 && exponent >= -6 {
            return (negative ? "-" : "") + "0." + String(repeating: "0", count: -exponent - 1) + digits
        }
        if exponent >= 21 || exponent < -6 {
            let body = mantissa.hasSuffix(".0") ? String(mantissa.dropLast(2)) : mantissa
            return body + "e" + (exponent > 0 ? "+" : "-") + String(abs(exponent))
        }
        return text
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validateTimestamp(_ value: Int64, _ name: String) throws {
        guard value >= 0, value < 253_402_300_800_000 else { throw NotesValidationError("invalid \(name)") }
    }

    /// Strict typed reads from JSONSerialization output. Numbers must be integral where integers are expected.
    struct Reader {
        let object: [String: Any]
        init(_ object: [String: Any]) { self.object = object }

        private func present(_ key: String) -> Any? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            return value
        }
        func string(_ key: String) throws -> String {
            guard let value = present(key) as? String else { throw NotesValidationError("missing \(key)") }
            return value
        }
        func optionalString(_ key: String) throws -> String? {
            guard let value = present(key) else { return nil }
            guard let string = value as? String else { throw NotesValidationError("invalid \(key)") }
            return string
        }
        func uuid(_ key: String) throws -> UUID {
            guard let id = UUID(uuidString: try string(key)) else { throw NotesValidationError("invalid \(key)") }
            return id
        }
        private static func integer(_ value: Any, _ key: String) throws -> Int64 {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw NotesValidationError("invalid \(key)") }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), abs(double) <= Double(NotesFormat.maximumInteger) else {
                throw NotesValidationError("invalid \(key)")
            }
            return Int64(double)
        }
        private static func double(_ value: Any, _ key: String) throws -> Double {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw NotesValidationError("invalid \(key)")
            }
            return number.doubleValue
        }
        func int(_ key: String) throws -> Int64 {
            guard let value = present(key) else { throw NotesValidationError("missing \(key)") }
            return try Self.integer(value, key)
        }
        func optionalInt(_ key: String) throws -> Int64? {
            guard let value = present(key) else { return nil }
            return try Self.integer(value, key)
        }
        func strings(_ key: String) throws -> [String] {
            guard let values = present(key) as? [Any] else { throw NotesValidationError("missing \(key)") }
            return try values.map { value in
                guard let string = value as? String else { throw NotesValidationError("invalid \(key)") }
                return string
            }
        }
        func optionalNumbers(_ key: String) throws -> [Double]? {
            guard let value = present(key) else { return nil }
            guard let values = value as? [Any] else { throw NotesValidationError("invalid \(key)") }
            return try values.map { try Self.double($0, key) }
        }
        func numberArrays(_ key: String) throws -> [[Double]] {
            guard let values = present(key) as? [Any] else { throw NotesValidationError("missing \(key)") }
            return try values.map { value in
                guard let numbers = value as? [Any] else { throw NotesValidationError("invalid \(key)") }
                return try numbers.map { try Self.double($0, key) }
            }
        }
        func object(_ key: String) throws -> Reader? {
            guard let value = present(key) else { return nil }
            guard let object = value as? [String: Any] else { throw NotesValidationError("invalid \(key)") }
            return Reader(object)
        }
    }
}

import Foundation
import ScienceReaderCore
import UIKit

// Notes and snippets: the account's writes (docs/architecture/NOTES_AND_SNIPPETS.md "Implementation contract").
// Every write is one local transaction in the account's encrypted store, acknowledged only once it is durable; sync
// follows on its own. Records are `gradstep-notes-v1` note events; deletion is the existing permanent tombstone.

extension ReaderModel {
    enum NotesAvailability: Equatable {
        /// Not signed in: notes need the account's encrypted store.
        case signedOut
        /// Signed in, but this device's keys aren't approved yet (Unlock notes: the device approval/recovery flow).
        case locked
        case ready
    }

    var notesAvailability: NotesAvailability {
        guard isSignedIn else { return .signedOut }
        guard store != nil, device != nil, !needsRecovery else { return .locked }
        return .ready
    }

    enum NotesWriteError: LocalizedError {
        case unavailable, emptyTitle, emptyText, noteMissing, entryMissing
        var errorDescription: String? {
            switch self {
            case .unavailable: "Couldn’t save on this device. Your notes need this account’s private library to be open."
            case .emptyTitle: "Give the note a name, up to 80 characters."
            case .emptyText: "Write something before saving."
            case .noteMissing: "This note is no longer available. It may have been deleted on another device."
            case .entryMissing: "This entry is no longer available. It may have been deleted on another device."
            }
        }
    }

    /// The local commit: blobs, events, holds and destination together, then a fresh snapshot and a sync.
    private func commitNotes(_ events: [(id: UUID, event: PrivateEvent)], blobs: [NoteBlobWrite] = [], destination: UUID? = nil) async throws {
        guard let store, let device, accountID == device.accountID, !workOwnership.isActivating else { throw NotesWriteError.unavailable }
        let scope = sessionID, storeScope = workOwnership.storeScope, persistence = localPersistence, deviceID = device.deviceID
        _ = try await persistence.acceptWrite { local in
            try await local.saveNoteEntry(events, blobs: blobs, deviceID: deviceID, destination: destination)
        }.value
        let snapshot = await store.snapshot()
        guard sessionID == scope else { throw CancellationError() }
        if workOwnership.owns(storeScope) { publish(snapshot) }
        Task { [weak self] in if let self, self.sessionID == scope { await self.synchronize() } }
    }

    private var notesNow: (timestamp: Int64, offset: Int) {
        (PrivateEvent.timestamp(Date()), TimeZone.current.secondsFromGMT() / 60)
    }

    private func normalizedNoteTitle(_ raw: String) throws -> String {
        guard let title = NoteRecord.normalizedTitle(raw) else { throw NotesWriteError.emptyTitle }
        return title
    }

    @discardableResult
    func createNote(_ title: String) async throws -> UUID {
        let record = NoteRecord(title: try normalizedNoteTitle(title), createdAt: notesNow.timestamp)
        try await commitNotes([(UUID(), try NotesRecord.note(record).event(createdAt: record.createdAt))])
        return record.noteID
    }

    func renameNote(_ id: UUID, to title: String) async throws {
        guard let note = notes.state.note(id) else { throw NotesWriteError.noteMissing }
        var record = note.record
        record.title = try normalizedNoteTitle(title)
        // A rename names every current head of the note, which also resolves "2 versions".
        try await commitNotes([(UUID(), try NotesRecord.note(record).event(parents: note.headIDs, createdAt: notesNow.timestamp))])
    }

    func deleteNote(_ id: UUID) async throws {
        guard notes.state.note(id) != nil else { throw NotesWriteError.noteMissing }
        try await commitNotes([(UUID(), PrivateEvent(kind: .tombstone, entityID: id, createdAt: notesNow.timestamp))])
        if notes.openNoteID == id { notes.openNoteID = nil }
        if notes.notice?.noteID == id { notes.notice = nil }
    }

    /// The reader's own writing as an entry (no source is invented).
    @discardableResult
    func addText(_ text: String, to noteID: UUID) async throws -> UUID {
        guard text.contains(where: { !$0.isWhitespace }) else { throw NotesWriteError.emptyText }
        guard notes.state.note(noteID) != nil else { throw NotesWriteError.noteMissing }
        let now = notesNow
        let entry = NoteEntryRecord(noteID: noteID, kind: .text, counter: notes.state.nextCounter(for: noteID), capturedAt: now.timestamp,
                                    offsetMinutes: now.offset, comment: text)
        try await commitNotes([(UUID(), try NotesRecord.entry(entry).event(createdAt: now.timestamp))], destination: noteID)
        return entry.entryID
    }

    /// A new revision of an entry's comment; its parents are every current head (an explicit choice between versions).
    func editComment(_ entryID: UUID, comment: String) async throws {
        guard let found = notes.state.entry(entryID) else { throw NotesWriteError.entryMissing }
        var record = found.entry.record
        record.comment = comment
        if found.entry.record.kind == .text, !comment.contains(where: { !$0.isWhitespace }) { throw NotesWriteError.emptyText }
        try await commitNotes([(UUID(), try NotesRecord.entry(record).event(parents: found.entry.headIDs, createdAt: notesNow.timestamp))])
    }

    /// Keeps one of an entry's concurrent versions: a revision of it whose parents are every head.
    func keepVersion(_ entryID: UUID, version: NoteEntryRecord) async throws {
        guard let found = notes.state.entry(entryID) else { throw NotesWriteError.entryMissing }
        try await commitNotes([(UUID(), try NotesRecord.entry(version).event(parents: found.entry.headIDs, createdAt: notesNow.timestamp))])
    }

    func deleteEntry(_ entryID: UUID) async throws {
        guard notes.state.entry(entryID) != nil else { throw NotesWriteError.entryMissing }
        try await commitNotes([(UUID(), PrivateEvent(kind: .tombstone, entityID: entryID, createdAt: notesNow.timestamp))])
    }

    /// Seals a capture's images under fresh keys once; every retry of this Save reuses them (same IDs, same bytes).
    func prepareSnippet(_ snippet: CapturedSnippet) async throws -> PreparedSnippet {
        guard let accountID else { throw NotesWriteError.unavailable }
        guard let image = snippet.image else { return PreparedSnippet(entryID: UUID(), newNoteID: UUID(), blobs: [], media: nil) }
        return try await Task.detached(priority: .userInitiated) {
            let full = try SnippetImageEncoder.full(image), thumb = try SnippetImageEncoder.thumbnail(image)
            let sealedFull = try NoteBlobCrypto.seal(full.data, type: full.type, width: full.width, height: full.height, accountID: accountID)
            let sealedThumb = try NoteBlobCrypto.seal(thumb.data, type: thumb.type, width: thumb.width, height: thumb.height, accountID: accountID)
            return PreparedSnippet(entryID: UUID(), newNoteID: UUID(),
                                   blobs: [NoteBlobWrite(blobID: sealedFull.media.blobID, blob: sealedFull.blob),
                                           NoteBlobWrite(blobID: sealedThumb.media.blobID, blob: sealedThumb.blob)],
                                   media: NoteMediaSet(full: sealedFull.media, thumb: sealedThumb.media))
        }.value
    }

    /// Saves a capture to an existing note or a new one, with the reader's optional comment. The new note and its first
    /// entry commit together; nothing is created when this throws. Returns the note and entry IDs.
    @discardableResult
    func saveSnippet(_ snippet: CapturedSnippet, prepared: PreparedSnippet, to destination: NoteDestinationChoice,
                     newTitle: String, comment: String) async throws -> (noteID: UUID, entryID: UUID) {
        // A repeated Save of a capture that is already committed is the same operation: one entry, never two. (The
        // store's commit is atomic, so a failed attempt left nothing behind and the next one writes it in full.)
        if let existing = notes.state.entry(prepared.entryID) { return (existing.note.id, prepared.entryID) }
        let now = notesNow
        var events: [(id: UUID, event: PrivateEvent)] = []
        let noteID: UUID
        switch destination {
        case .existing(let id):
            guard notes.state.note(id) != nil else { throw NotesWriteError.noteMissing }
            noteID = id
        case .new:
            let record = NoteRecord(noteID: prepared.newNoteID, title: try normalizedNoteTitle(newTitle), createdAt: now.timestamp)
            events.append((Self.eventID(prepared.newNoteID, salt: 1), try NotesRecord.note(record).event(createdAt: now.timestamp)))
            noteID = record.noteID
        }
        let counter = notes.state.note(noteID)?.nextCounter ?? 1
        let entry = NoteEntryRecord(entryID: prepared.entryID, noteID: noteID, kind: snippet.kind, counter: counter,
                                    capturedAt: PrivateEvent.timestamp(snippet.capturedAt), offsetMinutes: now.offset, comment: comment,
                                    source: snippet.source, anchor: snippet.anchor, quote: snippet.kind == .quote ? snippet.quote : nil,
                                    media: prepared.media)
        events.append((Self.eventID(prepared.entryID, salt: 2), try NotesRecord.entry(entry).event(createdAt: now.timestamp)))
        try await commitNotes(events, blobs: prepared.blobs, destination: noteID)
        return (noteID, entry.entryID)
    }

    /// A stable event ID for an operation's records, so a retried Save after an uncertain failure is an exact retry.
    private static func eventID(_ entity: UUID, salt: UInt8) -> UUID {
        var bytes = entity.uuid
        bytes.0 ^= salt; bytes.6 = (bytes.6 & 0x0F) | 0x40; bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }

    /// The decrypted, verified image for a descriptor: memory, this device's encrypted copy, then a download.
    func noteImage(_ media: NoteMedia) async throws -> UIImage {
        if let cached = notes.cachedImage(media) { return cached }
        let data = try await noteImageData(media)
        let image = try await Task.detached(priority: .userInitiated) { try SnippetImageEncoder.decode(data, media: media) }.value
        notes.cache(image, for: media)
        return image
    }

    /// The image's verified bytes (PNG or JPEG as captured): this device's encrypted copy, else a download.
    func noteImageData(_ media: NoteMedia) async throws -> Data {
        guard let store, let accountID else { throw NotesWriteError.unavailable }
        let transport: (any NoteAssetTransport)? = notesTransportOverride ?? backend.map { BackendNoteAssets(backend: $0, accountID: accountID) }
        return try await NoteAssetSync.image(media, accountID: accountID, store: store, transport: transport)
    }

    /// Notes › an entry's Open in paper: the paper when it is in the library, at the captured passage where it can be found.
    func openNoteSource(_ entry: NoteEntryRecord) -> Bool {
        guard let source = entry.source, let paper = notePaper(for: source) else { return false }
        if selectedPaper?.id != paper.id || selectedPaper?.artifactID != paper.artifactID { select(paper) }
        referenceNotice = nil
        // The captured passage, as Go to passage finds a chat's: its quote, else its first block on the same reader copy.
        // A different copy never inherits the old pixel rectangle; when the place can't be found the reader says so.
        if let anchor = entry.anchor, let manifest = anchor.manifestSHA256, let block = anchor.blockIDs.first {
            var request = PaperPassageRequest(documentID: paper.id, conversationID: UUID(),
                                              anchor: TextAnchor(manifestSHA256: manifest, quote: anchor.quote ?? entry.quote ?? "",
                                                                 elementID: block))
            request.origin = .note
            passageRequest = request
        }
        showPaperPlace()
        return true
    }

    /// Settings from a top-right menu: over the current screen on a phone; the wide layouts' own Settings otherwise.
    func openSettings(afterMenu: Bool = false) {
        let present = { [weak self] in
            guard let self else { return }
            // iPad in either shape: a sheet over the screen, as on iPhone. The Mac: Settings takes the window's panes.
            if self.compactLayout || !Platform.isMac { self.settingsPresented = true } else { self.showSettingsPlace() }
        }
        if afterMenu { Task { try? await Task.sleep(for: .milliseconds(250)); present() } } else { present() }
    }

    func closeSettings() {
        if settingsPresented { settingsPresented = false }
        if tab == .settings { tab = placeBeforeSettings }
    }

    /// A note entry's ⋯ › Chat: a region's full image first (decrypted on this device), then its chat; without the image
    /// (not downloaded, or a check failed) the chat still starts from its source.
    func chatAboutNoteEntryLoadingImage(_ entry: NotesState.Entry) {
        guard entry.record.kind == .region, let media = entry.record.media?.full else {
            chatAboutNoteEntry(entry, image: nil); return
        }
        Task { [weak self] in
            let image = try? await self?.noteImage(media)
            self?.chatAboutNoteEntry(entry, image: image?.cgImage)
        }
    }

    /// Notes › Open note after a save, or a note chosen from the list.
    func openNote(_ id: UUID, entry: UUID? = nil) {
        notes.notice = nil
        notes.openNoteID = id; notes.focusEntryID = entry
        tab = .notes
    }
}

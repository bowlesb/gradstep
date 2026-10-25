import Foundation
import ImageIO
import Observation
import ScienceReaderCore
import UIKit
import UniformTypeIdentifiers
import Vision

// Notes and snippets (docs/architecture/NOTES_AND_SNIPPETS.md): the account's notes as the reader sees them, their sync
// states, and the capture/composer/confirmation state shared by Paper, figure pages, the local PDF reader and Notes.
// Writes go through ReaderModel+Notes.swift (the account's encrypted store and its sync).

/// What a capture produced, before it is saved: the crop or the quotation and where it came from. Its identities (entry,
/// blobs, a new note) are allocated once, on the first Save, so repeated taps and retries are one operation.
struct CapturedSnippet: Identifiable {
    enum Origin: Equatable { case paper, figure, equation, pdf }
    let id = UUID()
    let kind: NoteEntryRecord.Kind
    let image: CGImage?
    let quote: String?
    let source: NoteSource?
    let anchor: NoteAnchor?
    let capturedAt: Date
    let origin: Origin
    /// The paper this came from (Open in paper, Adjust crop).
    let paperID: UUID?
}

/// The composer for one capture or one piece of writing (Notes › Add text).
struct NoteComposerRequest: Identifiable {
    let id = UUID()
    var snippet: CapturedSnippet?
    /// Add text into this note (nil for a capture, which chooses its destination).
    var textNoteID: UUID?
}

/// "Saved to <note> · Open note", over the screen the capture came from.
struct NoteSavedNotice: Identifiable, Equatable {
    let id = UUID()
    let noteID: UUID
    let entryID: UUID
    let title: String
    let waiting: Bool
    let origin: CapturedSnippet.Origin
}

/// Where a capture is saved.
enum NoteDestinationChoice: Hashable {
    case existing(UUID)
    case new
}

/// A capture's stable identities and sealed images, made on its first Save and reused by every retry.
struct PreparedSnippet {
    let entryID: UUID
    let newNoteID: UUID
    let blobs: [NoteBlobWrite]
    let media: NoteMediaSet?
}

/// The sync state of one entry, in words (never color alone).
enum NoteEntrySync: Equatable {
    case synced
    /// Saved on this device; its event hasn't reached the server.
    case waiting
    /// Its image is still uploading (the entry follows it).
    case uploadingImage
    /// The image couldn't upload; the entry and its image stay on this device.
    case failed(NoteAssetError)

    var label: String? {
        switch self {
        case .synced: nil
        case .waiting: "Saved on this device · Waiting to sync"
        case .uploadingImage: "Saved on this device · Image waiting to upload"
        case .failed(.quota): "Saved on this device · Storage for snippet images is full; sync is paused"
        case .failed(.signInRequired): "Saved on this device · Sign in again to sync"
        case .failed(.conflict), .failed(.tooLarge), .failed(.invalidResponse):
            "Saved on this device · This image couldn’t upload. Send a report so it can be fixed."
        case .failed: "Saved on this device · Upload will retry"
        }
    }
}

@MainActor @Observable final class NotesCenter {
    private(set) var state = NotesState()
    /// Advances whenever `state` changes (the full-text index reindexes a paper's notes then).
    @ObservationIgnored private(set) var stateRevision = 0
    private(set) var pendingEvents: Set<UUID> = []
    private(set) var pendingBlobs: Set<UUID> = []
    /// The note this device last saved to.
    private(set) var destination: UUID?
    private(set) var uploadFailures: [UUID: NoteAssetError] = [:]
    /// The note open in Notes (its stream), and the entry Open note jumps to.
    var openNoteID: UUID?
    var focusEntryID: UUID?
    var search = ""
    /// A region capture over a paper, figure or PDF: which host draws it.
    var capturing: CapturedSnippet.Origin?
    /// A figure page's whole item, preselected when its capture starts ("whole item, then optional adjust").
    var captureInitialRect: CGRect?
    var composer: NoteComposerRequest?
    var notice: NoteSavedNotice?
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()
    /// Collapsed entries per collection (owner, 2026-10-22), remembered on this device only (`NoteCollapseMemory`). The
    /// dictionary holds the collections changed or read this session; the defaults are the record across launches.
    private var collapsedEntries: [UUID: Set<UUID>] = [:]
    @ObservationIgnored var collapseMemory = NoteCollapseMemory()
    /// The open collection's name is edited in place (owner, TestFlight 91): its ⋯ › Rename collection asks the title.
    var renameRequest: UUID?
    /// Text Vision recognised in region images on this device, by the full image's blob ID ("" when there was none);
    /// sealed on disk (`SnippetTextStore`), read for search only.
    private(set) var recognised: [UUID: String] = [:]
    @ObservationIgnored var recognisedLoaded = false
    @ObservationIgnored var textStore: SnippetTextStore?
    @ObservationIgnored var recognising: Task<Void, Never>?
    @ObservationIgnored var recogniseAgain = false
    /// Full images that weren't on this device when their words were looked for (read when one is downloaded).
    @ObservationIgnored var recogniseMissing: Set<UUID> = []
    /// The reading a manifest names, when it is on this device (set by ReaderModel): search reads the blocks under a region.
    @ObservationIgnored var readingIndex: (String) -> ReaderBundleIndex? = { _ in nil }
    @ObservationIgnored private let searchWords = NoteSearch.WordCache()

    func update(_ privateState: PrivateState) {
        let next = NotesState(privateState)
        guard next != state else { return }
        state = next
        stateRevision &+= 1
        if let openNoteID, state.note(openNoteID) == nil, state.isDeleted(openNoteID) { self.openNoteID = nil }
    }

    func update(snapshot: LocalStoreSnapshot) {
        if pendingEvents != snapshot.pendingEventIDs { pendingEvents = snapshot.pendingEventIDs }
        if pendingBlobs != snapshot.pendingNoteBlobs { pendingBlobs = snapshot.pendingNoteBlobs }
        if destination != snapshot.noteDestination { destination = snapshot.noteDestination }
        let resolved = uploadFailures.filter { pendingBlobs.contains($0.key) }
        if resolved.count != uploadFailures.count { uploadFailures = resolved }
    }

    func record(_ report: NoteUploadReport) {
        var failures = uploadFailures
        for id in report.uploaded { failures.removeValue(forKey: id) }
        failures.merge(report.failures) { $1 }
        if failures != uploadFailures { uploadFailures = failures }
    }

    func reset() {
        state = NotesState(); pendingEvents = []; pendingBlobs = []; destination = nil; uploadFailures = [:]
        stateRevision &+= 1
        openNoteID = nil; focusEntryID = nil; search = ""; capturing = nil; captureInitialRect = nil; composer = nil; notice = nil
        collapsedEntries = [:]; renameRequest = nil
        recognised = [:]; recognisedLoaded = false; textStore = nil; searchWords.removeAll()
        recognising?.cancel(); recognising = nil; recogniseAgain = false; recogniseMissing = []
        images.removeAllObjects()
    }

    // MARK: Collapsed entries (this device only)

    func collapsed(in noteID: UUID) -> Set<UUID> { collapsedEntries[noteID] ?? collapseMemory.collapsed(in: noteID) }

    func isCollapsed(_ entryID: UUID, in noteID: UUID) -> Bool { collapsed(in: noteID).contains(entryID) }

    func setCollapsed(_ collapsed: Bool, entry entryID: UUID, in noteID: UUID) {
        var ids = self.collapsed(in: noteID)
        if collapsed { ids.insert(entryID) } else { ids.remove(entryID) }
        store(ids, in: noteID)
    }

    /// Collapse all / Expand all from the collection's ⋯.
    func setAllCollapsed(_ collapsed: Bool, in noteID: UUID) {
        store(collapsed ? Set(state.note(noteID)?.entries.map(\.id) ?? []) : [], in: noteID)
    }

    private func store(_ ids: Set<UUID>, in noteID: UUID) {
        let existing = state.note(noteID).map { Set($0.entries.map(\.id)) }
        let kept = existing.map { ids.intersection($0) } ?? ids
        collapsedEntries[noteID] = kept
        collapseMemory.set(kept, in: noteID, existing: existing)
    }

    // MARK: Presentation

    /// Collections matching the search (NoteSearch: every text field of a snippet, the reading under a drawn region when
    /// it is on this device, text recognised in its image), most recent first.
    var shownNotes: [NotesState.Note] {
        guard let matches = searchMatches else { return state.notes }
        let ids = Set(matches.map(\.noteID))
        return state.notes.filter { ids.contains($0.id) }
    }

    /// The search's matches, or nil when nothing is searched.
    var searchMatches: [NoteSearch.Match]? {
        NoteSearch.search(state, query: search, extra: { [self] in searchText($0) }, cache: searchWords)
    }

    /// What search knows about a snippet beyond its record: the reading's blocks under a drawn region (their text, the
    /// LaTeX of their equations, figure and table captions) and the text recognised in its image.
    func searchText(_ record: NoteEntryRecord) -> [String] {
        var texts: [String] = []
        if let anchor = record.anchor, let manifest = anchor.manifestSHA256, let index = readingIndex(manifest) {
            texts += NoteSearch.bundleText(anchor, in: index)
        }
        if let id = record.media?.full.blobID, let text = recognised[id], !text.isEmpty { texts.append(text) }
        return texts
    }

    func setRecognised(_ texts: [UUID: String]) {
        if texts != recognised { recognised = texts }
    }

    func sync(of entry: NotesState.Entry) -> NoteEntrySync {
        let blobs = entry.record.media?.all.map(\.blobID) ?? []
        if let failure = blobs.compactMap({ uploadFailures[$0] }).first { return .failed(failure) }
        if blobs.contains(where: { pendingBlobs.contains($0) }) { return .uploadingImage }
        if entry.headIDs.contains(where: { pendingEvents.contains($0) }) { return .waiting }
        return .synced
    }

    func isWaiting(_ note: NotesState.Note) -> Bool {
        note.headIDs.contains { pendingEvents.contains($0) } || note.entries.contains { sync(of: $0) != .synced }
    }

    var pendingCount: Int { state.notes.reduce(0) { $0 + ($1.headIDs.contains { pendingEvents.contains($0) } ? 1 : 0)
        + $1.entries.filter { sync(of: $0) != .synced }.count } }

    func cachedImage(_ media: NoteMedia) -> UIImage? { images.object(forKey: media.blobID.wire as NSString) }
    func cache(_ image: UIImage, for media: NoteMedia) { images.setObject(image, forKey: media.blobID.wire as NSString) }
}

// MARK: - Recognised text

/// Reads the words in a snippet's image with Vision, on this device, once per image (Snippets' search). Lines in reading
/// order, joined by newlines; at most `SnippetTextStore.maximumTextBytes`.
enum SnippetTextRecognizer {
    static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return SnippetTextStore.bounded(lines.joined(separator: "\n"))
    }
}

// MARK: - Images

/// Encodes a capture for its encrypted blobs (contract: full image PNG — JPEG only when PNG cannot fit — longest edge
/// ≤4,096 px, ≤6 MP, ≤2 MiB; thumbnail JPEG, longest edge 480 px, ≤64 KiB). ImageIO writes no metadata here.
enum SnippetImageEncoder {
    struct Encoded {
        let data: Data
        let type: String
        let width: Int
        let height: Int
    }

    enum Failure: LocalizedError {
        case tooLarge, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "This snippet is too detailed to save as one image. Draw a smaller box, or save it as two snippets."
            case .unreadable: "This snippet couldn’t be prepared. Try drawing it again."
            }
        }
    }

    static func full(_ image: CGImage) throws -> Encoded {
        var current = try bounded(image, edge: NotesFormat.maximumImageEdge, pixels: NotesFormat.maximumImagePixels)
        // PNG keeps text and math exact; a photographic crop that can't fit as PNG is saved as a high-quality JPEG; only
        // then is the image made smaller, and the composer shows the actual result.
        for _ in 0..<4 {
            if let png = encode(current, type: .png, quality: nil), png.count <= NotesFormat.maximumFullImageBytes {
                return Encoded(data: png, type: NoteMedia.png, width: current.width, height: current.height)
            }
            for quality in [0.92, 0.85] {
                if let jpeg = encode(current, type: .jpeg, quality: quality), jpeg.count <= NotesFormat.maximumFullImageBytes {
                    return Encoded(data: jpeg, type: NoteMedia.jpeg, width: current.width, height: current.height)
                }
            }
            current = try scaled(current, by: 0.75)
        }
        throw Failure.tooLarge
    }

    static func thumbnail(_ image: CGImage) throws -> Encoded {
        var current = try bounded(image, edge: NotesFormat.maximumThumbnailEdge, pixels: NotesFormat.maximumImagePixels)
        for _ in 0..<4 {
            for quality in [0.8, 0.65, 0.5, 0.35] {
                if let jpeg = encode(current, type: .jpeg, quality: quality), jpeg.count <= NotesFormat.maximumThumbnailBytes {
                    return Encoded(data: jpeg, type: NoteMedia.jpeg, width: current.width, height: current.height)
                }
            }
            current = try scaled(current, by: 0.75)
        }
        throw Failure.tooLarge
    }

    /// Decodes an image and checks it against its descriptor (contract: dimensions match the record) before display.
    static func decode(_ data: Data, media: NoteMedia) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw NoteBlobCrypto.Failure.mediaType }
        try NoteBlobCrypto.checkDimensions(width: width, height: height, media: media)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw NoteBlobCrypto.Failure.mediaType }
        return UIImage(cgImage: image)
    }

    private static func bounded(_ image: CGImage, edge: Int, pixels: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        var factor = min(1, Double(edge) / Double(longest))
        let area = Double(image.width * image.height) * factor * factor
        if area > Double(pixels) { factor *= (Double(pixels) / area).squareRoot() * 0.999 }
        return factor < 1 ? try scaled(image, by: factor) : image
    }

    private static func scaled(_ image: CGImage, by factor: Double) throws -> CGImage {
        let width = max(1, Int((Double(image.width) * factor).rounded(.down))), height = max(1, Int((Double(image.height) * factor).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.unreadable }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw Failure.unreadable }
        return result
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        // JPEG has no alpha: flatten onto white, as the page was.
        let source = type == .jpeg ? (flattened(image) ?? image) : image
        CGImageDestinationAddImage(destination, source, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

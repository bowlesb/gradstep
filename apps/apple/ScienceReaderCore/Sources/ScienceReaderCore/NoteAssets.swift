import CryptoKit
import Foundation

// Snippet image transport (docs/architecture/NOTES_AND_SNIPPETS.md "Blob API"): one edge function, `note-assets`, is the
// only writer. `PUT {SUPABASE_URL}/functions/v1/note-assets/{blobID}` with the stored blob and `x-content-sha256` is
// idempotent (same ID and digest = success); `GET` returns the stored blob. The transport is a protocol so the app's
// network client, a UI-test fixture and unit-test fakes are interchangeable.

public enum NoteAssetError: Error, Equatable, Sendable {
    /// 409: the blob ID already exists with another digest. This capture can never upload under its ID.
    case conflict
    /// 413: over 2 MiB + 28 bytes.
    case tooLarge
    /// 429 `{code:"quota"}` on upload: storage is paused for this account or environment.
    case quota
    /// 429 on download: this month's download allowance is used.
    case downloadLimit
    /// 404 on download.
    case notFound
    /// 401/403: sign in again (or this device is no longer approved).
    case signInRequired
    /// A network or server failure; retrying the same request is safe.
    case unavailable
    /// A response that doesn't match the request (wrong byte count, malformed body).
    case invalidResponse

    /// Whether the next blob would fail the same way (stop the pass rather than hammer the service).
    var stopsPass: Bool { [.quota, .signInRequired, .unavailable].contains(self) }
}

public protocol NoteAssetTransport: Sendable {
    /// Uploads a stored blob; returns the byte count the server recorded as `ready`.
    func put(blobID: UUID, blob: Data, sha256: String) async throws -> Int
    /// Downloads a stored blob.
    func get(blobID: UUID) async throws -> Data
}

public struct NoteUploadReport: Equatable, Sendable {
    public var uploaded: [UUID] = []
    public var failures: [UUID: NoteAssetError] = [:]
    public var remaining = 0
    public init() {}
}

public enum NoteAssetSync {
    /// Uploads this device's unsent snippet blobs, oldest first, marking each `ready` in the store so the entry that names
    /// it may follow. Retries reuse the exact ID and bytes. A per-blob failure is reported, never thrown: unrelated chats
    /// and notes keep syncing; the entry stays held with its image on this device.
    public static func uploadPending(store: EncryptedStore, transport: any NoteAssetTransport, limit: Int = 64) async throws -> NoteUploadReport {
        var report = NoteUploadReport()
        let pending = try await store.pendingNoteUploads()
        for id in pending.prefix(limit) {
            try Task.checkCancellation()
            guard let blob = try await store.noteBlob(id) else { continue }
            do {
                let bytes = try await transport.put(blobID: id, blob: blob, sha256: Data(SHA256.hash(data: blob)).hex)
                guard bytes == blob.count else { throw NoteAssetError.invalidResponse }
                try Task.checkCancellation()
                try await store.markNoteBlobsReady([id])
                report.uploaded.append(id)
            } catch let error as NoteAssetError {
                report.failures[id] = error
                if error.stopsPass { break }
            } catch is URLError {
                report.failures[id] = .unavailable
                break
            }
        }
        report.remaining = try await store.pendingNoteUploads().count
        return report
    }

    /// The decrypted image for a descriptor: this device's copy (an unsent capture or cached download) or a download,
    /// verified (digest, tag, media type) before it is cached. Callers check decoded dimensions before display.
    public static func image(_ media: NoteMedia, accountID: UUID, store: EncryptedStore,
                             transport: (any NoteAssetTransport)?) async throws -> Data {
        if let local = try await store.noteBlob(media.blobID) {
            return try NoteBlobCrypto.open(local, media: media, accountID: accountID)
        }
        guard let transport else { throw NoteAssetError.unavailable }
        let blob = try await transport.get(blobID: media.blobID)
        let plaintext = try NoteBlobCrypto.open(blob, media: media, accountID: accountID)
        // A cache write failure doesn't hide an image that downloaded and verified.
        try? await store.cacheNoteBlob(media.blobID, blob: blob)
        return plaintext
    }
}

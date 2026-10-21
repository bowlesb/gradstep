import CryptoKit
import Foundation
import ScienceReaderCore
import UIKit
import XCTest
@testable import ScienceReader

/// Opt-in, staging only: the app's own note-assets transport, store and sync against the deployed function, with a
/// disposable @example.invalid account whose session a harness writes to `TEST_RUNNER_NOTES_LIVE_CONFIG` (a JSON file:
/// url, anonKey, environment, accountID, accessToken, refreshToken, expiresAt). The harness creates and deletes the
/// account; this test never sees a service key. Without the variable it is skipped. No paid calls.
final class NotesLiveAssetsTests: XCTestCase {
    private struct Config: Decodable {
        let url: URL; let anonKey: String; let environment: String
        let accountID: UUID; let accessToken: String; let refreshToken: String; let expiresAt: Double
    }

    private final class Session: AuthenticationCredentialStore, @unchecked Sendable {
        private let lock = NSLock(); private var value: Data?
        init(_ value: Data) { self.value = value }
        func read(_ name: String) throws -> Data? { lock.withLock { value } }
        func write(_ data: Data, name: String) throws { lock.withLock { value = data } }
        func delete(_ name: String) throws { lock.withLock { value = nil } }
    }

    func testNativeCapturesUploadReleaseTheirEntryAndDecryptOnASecondDevice() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTES_LIVE_CONFIG"] else { throw XCTSkip("Set TEST_RUNNER_NOTES_LIVE_CONFIG") }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(config.url.host?.hasPrefix("coxhjvqpflgxkleydati") == true, "Staging only")
        let session = try ReaderCrypto.encode(AuthSession(access_token: config.accessToken, refresh_token: config.refreshToken,
            expires_at: config.expiresAt, user: .init(id: config.accountID, email: nil)))
        let client = try BackendClient(configuration: .init(url: config.url, anonKey: config.anonKey, environment: config.environment),
                                       credentials: Session(session))
        let transport = BackendNoteAssets(backend: client, accountID: config.accountID)

        // Device A: a real capture (PNG and JPEG thumbnail), saved with a new note, its entry held for its blobs.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().wire)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = KeyBundle.generate(accountID: config.accountID)
        let storeA = try EncryptedStore(url: directory.appendingPathComponent("a.sqlite"), accountID: config.accountID,
                                        localKey: ReaderCrypto.randomKey(), keys: keys)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let page = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 360), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 360))
            ("Live staging check: an encrypted snippet" as NSString).draw(at: CGPoint(x: 20, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 40)])
        }.cgImage!
        let full = try SnippetImageEncoder.full(page), thumb = try SnippetImageEncoder.thumbnail(page)
        let sealedFull = try NoteBlobCrypto.seal(full.data, type: full.type, width: full.width, height: full.height, accountID: config.accountID)
        let sealedThumb = try NoteBlobCrypto.seal(thumb.data, type: thumb.type, width: thumb.width, height: thumb.height, accountID: config.accountID)
        let note = NoteRecord(title: "Live check", createdAt: PrivateEvent.timestamp(Date()))
        let entry = NoteEntryRecord(noteID: note.noteID, kind: .region, counter: 1, capturedAt: PrivateEvent.timestamp(Date()), offsetMinutes: 0,
                                    comment: "", media: NoteMediaSet(full: sealedFull.media, thumb: sealedThumb.media))
        let device = UUID()
        let envelopes = try await storeA.saveNoteEntry([(UUID(), try NotesRecord.note(note).event()), (UUID(), try NotesRecord.entry(entry).event())],
            blobs: [NoteBlobWrite(blobID: sealedFull.media.blobID, blob: sealedFull.blob), NoteBlobWrite(blobID: sealedThumb.media.blobID, blob: sealedThumb.blob)],
            deviceID: device)
        let held = await storeA.pending().map(\.id)
        XCTAssertEqual(held, [envelopes[0].id], "The entry waits for its images")

        // Upload through the app's transport; a repeat is the same ready object.
        let report = try await NoteAssetSync.uploadPending(store: storeA, transport: transport)
        XCTAssertEqual(Set(report.uploaded), [sealedFull.media.blobID, sealedThumb.media.blobID], "\(report.failures)")
        XCTAssertEqual(report.remaining, 0)
        let released = await storeA.pending().map(\.id)
        XCTAssertEqual(released, envelopes.map(\.id), "Both images are ready; the entry may upload")
        let repeated = try await transport.put(blobID: sealedFull.media.blobID, blob: sealedFull.blob, sha256: sealedFull.media.sha256)
        XCTAssertEqual(repeated, sealedFull.blob.count)

        // Device B (same account keys, its own store): thumbnail then full image, verified, decrypted and cached.
        let storeB = try EncryptedStore(url: directory.appendingPathComponent("b.sqlite"), accountID: config.accountID,
                                        localKey: ReaderCrypto.randomKey(), keys: keys)
        let thumbBytes = try await NoteAssetSync.image(sealedThumb.media, accountID: config.accountID, store: storeB, transport: transport)
        XCTAssertNoThrow(try SnippetImageEncoder.decode(thumbBytes, media: sealedThumb.media))
        let fullBytes = try await NoteAssetSync.image(sealedFull.media, accountID: config.accountID, store: storeB, transport: transport)
        XCTAssertEqual(fullBytes, full.data)
        let cached = try await storeB.noteBlob(sealedFull.media.blobID)
        XCTAssertEqual(cached, sealedFull.blob, "Cached encrypted on device B")

        // Refusals the client relies on.
        let other = try NoteBlobCrypto.seal(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9]), type: NoteMedia.png, width: 1, height: 1,
                                            accountID: config.accountID, blobID: sealedFull.media.blobID)
        do { _ = try await transport.put(blobID: sealedFull.media.blobID, blob: other.blob, sha256: other.media.sha256); XCTFail("conflict") }
        catch let error as NoteAssetError { XCTAssertEqual(error, .conflict) }
        do { _ = try await transport.get(blobID: UUID()); XCTFail("not found") }
        catch let error as NoteAssetError { XCTAssertEqual(error, .notFound) }
        let summary: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "uploaded": report.uploaded.count,
                                      "fullBytes": sealedFull.blob.count, "thumbBytes": sealedThumb.blob.count, "fullType": full.type,
                                      "secondDeviceDecrypted": true, "conflict": "409", "missing": "404"]
        print("NOTES_LIVE_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
    }
}

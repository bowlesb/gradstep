import CryptoKit
import Foundation
import PDFKit
import ScienceReaderCore
import UIKit
import XCTest
@testable import ScienceReader

/// Scripted note-assets responses for one test host (the deployed function's statuses and bodies).
private final class NoteAssetsProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var body = Data(); var headers: [String: String] = [:] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
    static func install(_ host: String, _ list: [Reply]) { lock.withLock { replies[host] = list; requests[host] = [] } }
    static func remove(_ host: String) { lock.withLock { replies[host] = nil; requests[host] = nil } }
    static func recorded(_ host: String) -> [URLRequest] { lock.withLock { requests[host] ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply: Reply? = Self.lock.withLock {
            Self.requests[host, default: []].append(request)
            guard var list = Self.replies[host], !list.isEmpty else { return nil }
            let next = list.removeFirst(); Self.replies[host] = list; return next
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers.merging(["Content-Length": String(reply.body.count)]) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StoredNotesSession: AuthenticationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    init(_ value: Data) { self.value = value }
    func read(_ name: String) throws -> Data? { lock.withLock { value } }
    func write(_ data: Data, name: String) throws { lock.withLock { value = data } }
    func delete(_ name: String) throws { lock.withLock { value = nil } }
}

/// The app's half of Notes: the deployed note-assets responses, image encoding bounds, the PDF region renderer and
/// the model's writes through the encrypted fixture store.
@MainActor
final class NotesAppTests: XCTestCase {
    private let account = UUID()
    private var host = ""

    override func setUp() { host = "notes-\(UUID().wire).invalid" }
    override func tearDown() { NoteAssetsProtocol.remove(host) }

    private func transport(_ replies: [NoteAssetsProtocol.Reply]) throws -> BackendNoteAssets {
        NoteAssetsProtocol.install(host, replies)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [NoteAssetsProtocol.self]
        let session = try ReaderCrypto.encode(AuthSession(access_token: "fixture-access", refresh_token: "fixture-refresh",
            expires_at: Date().timeIntervalSince1970 + 3_600, user: .init(id: account, email: nil)))
        let client = try BackendClient(configuration: .init(url: URL(string: "https://\(host)")!, anonKey: "fixture-anon", environment: host),
                                       network: URLSession(configuration: settings), credentials: StoredNotesSession(session))
        return BackendNoteAssets(backend: client, accountID: account)
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: Transport

    func testUploadsAndDownloadsFollowTheDeployedFunction() async throws {
        let blob = Data(repeating: 7, count: 64), blobID = UUID(), digest = Data(SHA256.hash(data: blob)).hex
        let notes = try transport([
            .init(status: 200, body: json(#"{"state":"ready","bytes":64}"#)),
            .init(status: 200, body: blob, headers: ["X-Content-SHA256": digest]),
        ])
        let bytes = try await notes.put(blobID: blobID, blob: blob, sha256: digest)
        XCTAssertEqual(bytes, 64)
        let downloaded = try await notes.get(blobID: blobID)
        XCTAssertEqual(downloaded, blob)
        let requests = NoteAssetsProtocol.recorded(host)
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "GET"])
        XCTAssertEqual(requests[0].url?.path, "/functions/v1/note-assets/\(blobID.wire)")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-content-sha256"), digest)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertNil(requests[1].httpBody)
    }

    func testRefusalsBecomeTheirOwnErrors() async throws {
        let cases: [(NoteAssetsProtocol.Reply, String, NoteAssetError)] = [
            (.init(status: 409, body: json(#"{"code":"conflict"}"#)), "PUT", .conflict),
            (.init(status: 413, body: json(#"{"code":"too_large"}"#)), "PUT", .tooLarge),
            (.init(status: 400, body: json(#"{"code":"digest_mismatch"}"#)), "PUT", .invalidResponse),
            (.init(status: 429, body: json(#"{"code":"quota"}"#)), "PUT", .quota),
            (.init(status: 429, body: json(#"{"code":"rate_limited","retry_after":60}"#)), "PUT", .unavailable),
            (.init(status: 503, body: json(#"{"code":"not_ready"}"#)), "PUT", .unavailable),
            (.init(status: 401, body: json(#"{"code":"authentication_required"}"#)), "PUT", .signInRequired),
            (.init(status: 404, body: json(#"{"code":"not_found"}"#)), "GET", .notFound),
            (.init(status: 429, body: json(#"{"code":"quota","retry_after":864000}"#)), "GET", .downloadLimit),
            (.init(status: 503, body: json(#"{"code":"integrity_failed"}"#)), "GET", .unavailable),
            // A body that doesn't match the server's own digest is not shown or cached.
            (.init(status: 200, body: Data([1, 2, 3]), headers: ["X-Content-SHA256": String(repeating: "0", count: 64)]), "GET", .unavailable),
        ]
        for (reply, method, expected) in cases {
            let notes = try transport([reply])
            do {
                if method == "PUT" { _ = try await notes.put(blobID: UUID(), blob: Data(repeating: 1, count: 40), sha256: String(repeating: "a", count: 64)) }
                else { _ = try await notes.get(blobID: UUID()) }
                XCTFail("\(reply.status) should fail")
            } catch let error as NoteAssetError {
                XCTAssertEqual(error, expected, "\(method) \(reply.status) \(String(decoding: reply.body, as: UTF8.self))")
            }
            NoteAssetsProtocol.remove(host)
        }
    }

    // MARK: Images

    private func pageImage(width: Int, height: Int, photographic: Bool = false) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if photographic {
                // Per-pixel colour noise does not compress as PNG: the encoder must fall back to JPEG (or a smaller
                // size), never fail silently.
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                var generator = SystemRandomNumberGenerator()
                for index in stride(from: 0, to: bytes.count, by: 8) {
                    let value = generator.next()
                    withUnsafeBytes(of: value) { raw in for offset in 0..<8 where index + offset < bytes.count { bytes[index + offset] = raw[offset] } }
                }
                for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
                let provider = CGDataProvider(data: Data(bytes) as CFData)!
                let noise = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                context.cgContext.draw(noise, in: CGRect(x: 0, y: 0, width: width, height: height))
            } else {
                let text = "Direct Preference Optimization: the loss is a logistic regression on the implicit reward margin." as NSString
                for row in 0..<(height / 40) {
                    text.draw(at: CGPoint(x: 12, y: row * 40 + 8), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
                }
            }
        }.cgImage!
    }

    func testTextCropsStayPNGAndThumbnailsAreBoundedJPEG() throws {
        let image = pageImage(width: 1170, height: 600)
        let full = try SnippetImageEncoder.full(image), thumb = try SnippetImageEncoder.thumbnail(image)
        XCTAssertEqual(full.type, NoteMedia.png)
        XCTAssertEqual([full.width, full.height], [1170, 600], "A text crop keeps every pixel")
        XCTAssertLessThanOrEqual(full.data.count, NotesFormat.maximumFullImageBytes)
        XCTAssertEqual(thumb.type, NoteMedia.jpeg)
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), NotesFormat.maximumThumbnailEdge)
        XCTAssertLessThanOrEqual(thumb.data.count, NotesFormat.maximumThumbnailBytes)
        // The encoded bytes carry no metadata beyond the image itself.
        let source = CGImageSourceCreateWithData(full.data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // ImageIO may record the pixel dimensions; nothing else (no camera, place, time or software).
        let exif = Set((properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]).keys.map { $0 as String })
        XCTAssertTrue(exif.isSubset(of: ["PixelXDimension", "PixelYDimension", "ColorSpace"]), "\(exif)")
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary]); XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        // Decoding checks the dimensions against the record.
        let media = NoteMedia(blobID: UUID(), key: Data(count: 32), sha256: String(repeating: "0", count: 64), bytes: 100,
                              type: full.type, width: full.width, height: full.height)
        XCTAssertNoThrow(try SnippetImageEncoder.decode(full.data, media: media))
        let wrong = NoteMedia(blobID: UUID(), key: Data(count: 32), sha256: String(repeating: "0", count: 64), bytes: 100,
                              type: full.type, width: full.width, height: full.height + 1)
        XCTAssertThrowsError(try SnippetImageEncoder.decode(full.data, media: wrong))
    }

    func testLargeAndPhotographicCropsFitTheContractLimits() throws {
        let large = try SnippetImageEncoder.full(pageImage(width: 5_000, height: 1_600))
        XCTAssertLessThanOrEqual(max(large.width, large.height), NotesFormat.maximumImageEdge)
        XCTAssertLessThanOrEqual(large.width * large.height, NotesFormat.maximumImagePixels)
        let noisy = try SnippetImageEncoder.full(pageImage(width: 1_800, height: 1_800, photographic: true))
        XCTAssertLessThanOrEqual(noisy.data.count, NotesFormat.maximumFullImageBytes)
        XCTAssertEqual(noisy.type, NoteMedia.jpeg, "A photographic crop that can't fit as PNG is a JPEG")
    }

    // MARK: PDF regions

    /// A 200 × 200 pt page, red in its top-left quarter as shown, white elsewhere.
    private func pdfPage(rotation: Int = 0) throws -> PDFPage {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
            context.beginPage()
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        page.rotation = rotation
        return page
    }

    private func color(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
    }

    func testPDFRegionsRenderExactlyTheChosenPartOfThePage() throws {
        // Shown at 2 pt per PDF unit, 10 pt from the view's left and 20 pt from its top.
        let page = try pdfPage(), shown = CGRect(x: 10, y: 20, width: 400, height: 400)
        let red = try XCTUnwrap(PDFRegionRenderer.render(page: page, pageRect: shown, crop: CGRect(x: 30, y: 40, width: 120, height: 100), scale: 2))
        XCTAssertEqual([red.width, red.height], [240, 200])
        let inside = color(red, x: 120, y: 100)
        XCTAssertTrue(inside.r > 200 && inside.g < 60 && inside.b < 60, "The top-left quarter is red: \(inside)")
        let white = try XCTUnwrap(PDFRegionRenderer.render(page: page, pageRect: shown, crop: CGRect(x: 250, y: 260, width: 100, height: 100), scale: 2))
        let outside = color(white, x: 100, y: 100)
        XCTAssertTrue(outside.r > 230 && outside.g > 230 && outside.b > 230, "The bottom-right quarter is white: \(outside)")
        // A page shown rotated 90°: the red quarter is now at the top right of what the reader sees.
        let turned = try pdfPage(rotation: 90)
        let topRight = try XCTUnwrap(PDFRegionRenderer.render(page: turned, pageRect: shown, crop: CGRect(x: 260, y: 30, width: 100, height: 100), scale: 2))
        let rotated = color(topRight, x: 100, y: 100)
        XCTAssertTrue(rotated.r > 200 && rotated.g < 60, "Rotation follows what is shown: \(rotated)")
    }

    // MARK: Model

    #if targetEnvironment(simulator)
    func testNotesWritesCommitLocallyAndProjectBack() async throws {
        let model = ReaderModel(configuration: nil)
        try await model.configureDurableDraftFixture(reset: true)
        XCTAssertEqual(model.notesAvailability, .ready)
        let noteID = try await model.createNote("  Preference learning  ")
        XCTAssertEqual(model.notes.state.note(noteID)?.title, "Preference learning", "Titles are trimmed")
        do { _ = try await model.createNote("   "); XCTFail("An empty title is refused") } catch {}

        // A region capture into the existing note, with its encrypted images.
        let paper = try XCTUnwrap(model.selectedPaper)
        let snippet = CapturedSnippet(kind: .region, image: pageImage(width: 600, height: 300), quote: nil,
                                      source: SnippetCapturer.source(for: paper, label: "Figure 1"), anchor: nil,
                                      capturedAt: Date(), origin: .paper, paperID: paper.id)
        let prepared = try await model.prepareSnippet(snippet)
        let saved = try await model.saveSnippet(snippet, prepared: prepared, to: .existing(noteID), newTitle: "", comment: "Worth comparing")
        // Saving again with the same prepared identities is an exact retry: still one entry.
        _ = try await model.saveSnippet(snippet, prepared: prepared, to: .existing(noteID), newTitle: "", comment: "Worth comparing")
        var note = try XCTUnwrap(model.notes.state.note(noteID))
        XCTAssertEqual(note.entries.map(\.id), [saved.entryID])
        XCTAssertEqual(note.entries[0].record.source?.label, "Figure 1")
        XCTAssertEqual(model.notes.destination, noteID, "The last destination is remembered")
        XCTAssertEqual(model.notes.sync(of: note.entries[0]), .uploadingImage, "The image is waiting for the server")
        let full = try XCTUnwrap(note.entries[0].record.media?.full)
        let image = try await model.noteImage(full)
        XCTAssertEqual(Int(image.size.width * image.scale), 600)

        // Text, a comment edit and a second version chosen explicitly.
        let textID = try await model.addText("Compare with IPO next.", to: noteID)
        try await model.editComment(saved.entryID, comment: "Edited")
        note = try XCTUnwrap(model.notes.state.note(noteID))
        XCTAssertEqual(note.entries.map(\.record.comment), ["Edited", "Compare with IPO next."])
        XCTAssertEqual(note.entries.map(\.record.counter), [1, 2])
        try await model.renameNote(noteID, to: "DPO and IPO")
        XCTAssertEqual(model.notes.state.note(noteID)?.title, "DPO and IPO")

        // A new note and its first entry commit together.
        let quote = CapturedSnippet(kind: .quote, image: nil, quote: "A useful first pass", source: SnippetCapturer.source(for: paper),
                                    anchor: nil, capturedAt: Date(), origin: .paper, paperID: paper.id)
        let quoted = try await model.saveSnippet(quote, prepared: try await model.prepareSnippet(quote), to: .new, newTitle: "Quick notes", comment: "")
        XCTAssertEqual(model.notes.state.note(quoted.noteID)?.entries.first?.record.quote, "A useful first pass")
        XCTAssertEqual(model.notes.shownNotes.first?.id, quoted.noteID, "Most recent first")
        model.notes.search = "ipo"
        XCTAssertEqual(model.notes.shownNotes.map(\.id), [noteID], "Search covers titles and writing")
        model.notes.search = ""

        // Deletion: an entry, then the note (tombstones).
        try await model.deleteEntry(textID)
        XCTAssertEqual(model.notes.state.note(noteID)?.entries.count, 1)
        try await model.deleteNote(noteID)
        XCTAssertNil(model.notes.state.note(noteID))
        XCTAssertTrue(model.notes.state.isDeleted(noteID))

        // Everything is in the encrypted store: a fresh model on the same fixture sees the same notes.
        await model.flushDrafts()
        let reopened = ReaderModel(configuration: nil)
        try await reopened.configureDurableDraftFixture(reset: false)
        XCTAssertEqual(reopened.notes.state.notes.map(\.id), [quoted.noteID])
        XCTAssertEqual(reopened.notes.destination, quoted.noteID)
    }

    func testSettingsOpensOverTheScreenOnPhonesAndAsTheWideDestinationElsewhere() async throws {
        let model = ReaderModel(configuration: nil)
        model.tab = .paper; model.compactLayout = true
        model.openSettings()
        XCTAssertTrue(model.settingsPresented)
        XCTAssertEqual(model.tab, .paper, "The screen underneath stays")
        model.closeSettings()
        XCTAssertFalse(model.settingsPresented); XCTAssertEqual(model.tab, .paper)
        // Going somewhere from Settings leaves it.
        model.openSettings(); model.tab = .library
        XCTAssertFalse(model.settingsPresented)
        // Wide: Settings is a sheet on iPad, as in Tall; the Mac's Settings takes the panes and Done returns to the place.
        model.compactLayout = false
        model.showPlace(.notes)
        XCTAssertEqual(model.tab, .notes)
        model.openSettings()
        if Platform.isMac { XCTAssertEqual(model.tab, .settings) } else { XCTAssertTrue(model.settingsPresented); XCTAssertEqual(model.tab, .notes) }
        model.closeSettings()
        XCTAssertEqual(model.tab, .notes); XCTAssertFalse(model.settingsPresented)
    }
    #endif
}

import Foundation
import ScienceReaderCore
import UIKit
import XCTest
import zlib
@testable import ScienceReader

@MainActor
final class ReaderBundleLoaderTests: XCTestCase {
    func testRasterIsDecodedBeforeTheBundleBecomesReadable() throws {
        let bytes = fixturePNG
        let (directory, digest) = try writeBundle(image: bytes)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ReaderBundleLoader.load(directory: directory, expectedSHA256: digest)
        XCTAssertEqual(bundle.data(for: "figure.png"), bytes)
    }

    func testCorrectHashesCannotAdmitFalseDimensionsOrImageType() throws {
        let image = fixtureImage()
        for (bytes, width) in [(fixturePNG, 1),
                               (try XCTUnwrap(image.jpegData(compressionQuality: 0.9)), 32)] {
            let (directory, digest) = try writeBundle(image: bytes, width: width)
            defer { try? FileManager.default.removeItem(at: directory) }
            // Both are valid byte-integrity packages; native image admission
            // must independently verify actual type and bounded dimensions.
            XCTAssertNoThrow(try VerifiedReaderBundle.load(directory: directory, expectedSHA256: digest))
            XCTAssertThrowsError(try ReaderBundleLoader.load(directory: directory, expectedSHA256: digest)) {
                XCTAssertEqual($0 as? ReaderBundleError, .invalidResource)
            }
        }
    }

    func testIncompleteRasterCannotBePublishedWithARecomputedHash() throws {
        let png = fixturePNG
        let imageData = try XCTUnwrap(png.range(of: Data("IDAT".utf8)))
        let truncated = Data(png.prefix(imageData.lowerBound + 4))
        let (directory, digest) = try writeBundle(image: truncated)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrow(try VerifiedReaderBundle.load(directory: directory, expectedSHA256: digest))
        XCTAssertThrowsError(try ReaderBundleLoader.load(directory: directory, expectedSHA256: digest)) {
            XCTAssertEqual($0 as? ReaderBundleError, .invalidResource)
        }
    }

    func testValidPNGContainerCannotHideAnIncompleteOrTrailingDeflateStream() throws {
        let compressed = fixturePNG.subdata(in: 41..<(fixturePNG.count - 16))
        for stream in [Data(compressed.dropLast()), compressed + Data([0])] {
            let broken = fixturePNG.prefix(33) + chunk("IDAT", stream) + fixturePNG.suffix(12)
            let (directory, digest) = try writeBundle(image: broken)
            defer { try? FileManager.default.removeItem(at: directory) }
            XCTAssertNoThrow(try VerifiedReaderBundle.load(directory: directory, expectedSHA256: digest))
            XCTAssertThrowsError(try ReaderBundleLoader.load(directory: directory, expectedSHA256: digest)) {
                XCTAssertEqual($0 as? ReaderBundleError, .invalidResource)
            }
        }
    }

    func testPNGRefusesBadCRCUnexpectedChunksAndIncorrectScanlineExtent() throws {
        var badCRC = fixturePNG; badCRC[29] ^= 1
        let ancillary = fixturePNG.prefix(33) + chunk("tEXt", Data("not in this profile".utf8)) + fixturePNG.dropFirst(33)
        for bytes in [badCRC, ancillary, fixturePNG + Data([0])] {
            XCTAssertThrowsError(try ReaderPNGValidator.validate(bytes, width: 32, height: 16))
        }
        for height in [15, 17] {
            var header = fixturePNG.subdata(in: 16..<29); header[7] = UInt8(height)
            let broken = fixturePNG.prefix(8) + chunk("IHDR", header) + fixturePNG.dropFirst(33)
            XCTAssertThrowsError(try ReaderPNGValidator.validate(broken, width: 32, height: height))
        }
    }

    // Authored 32×16 RGBA blue raster emitted by the pinned renderer's encodePNG.
    // UIImage.pngData adds metadata outside this intentionally narrow profile.
    private var fixturePNG: Data { Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAYAAAB3AH1ZAAAAIklEQVR42u3OIQEAAAACIP+f1hkWAp0k7ZeAgICAgIDAOTDcxPwukNxH3wAAAABJRU5ErkJggg==")! }

    private func chunk(_ type: String, _ bytes: Data) -> Data {
        let body = Data(type.utf8) + bytes
        var size = UInt32(bytes.count).bigEndian
        var checksum = body.withUnsafeBytes { UInt32(crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count))).bigEndian }
        return withUnsafeBytes(of: &size) { Data($0) } + body + withUnsafeBytes(of: &checksum) { Data($0) }
    }

    private func fixtureImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 16), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }
    }

    private func writeBundle(image: Data, width: Int = 32) throws -> (URL, String) {
        let index: [String: Any] = ["format": "reader-index-v1", "title": "Image admission fixture",
            "headings": [], "blocks": [["id": "figure", "kind": "figure", "text": "Image"]], "equations": [],
            "figures": [["id": "figure", "block_id": "figure", "asset_paths": ["figure.png"], "caption": "Image", "alt": "Image"]]]
        let files = ["index.html": Data("<figure id='figure'><img src='figure.png'></figure>".utf8),
            "reader.json": try JSONSerialization.data(withJSONObject: index),
            "provenance.json": Data("{\"authored\":true}".utf8), "figure.png": image]
        let roles = ["index.html": "html", "reader.json": "index", "provenance.json": "provenance", "figure.png": "image"]
        let types = ["html": "text/html", "index": "application/json", "provenance": "application/json", "image": "image/png"]
        let members = files.keys.sorted().map { path -> [String: Any] in
            let bytes = files[path]!, role = roles[path]!
            var member: [String: Any] = ["path": path, "role": role, "media_type": types[role]!, "bytes": bytes.count,
                "sha256": VerifiedReaderBundle.digest(bytes)]
            if role == "image" { member["width"] = width; member["height"] = 16 }
            return member
        }
        let manifest: [String: Any] = ["format": "reader-bundle-v1", "renderer": ["id": "timestep-mmd-v1", "build_sha256": String(repeating: "a", count: 64)],
            "source": ["kind": "authored-mmd", "sha256": String(repeating: "b", count: 64), "provenance_path": "provenance.json"],
            "entrypoint": "index.html", "index_path": "reader.json", "members": members]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        for (path, bytes) in files { try bytes.write(to: directory.appendingPathComponent(path)) }
        return (directory, VerifiedReaderBundle.digest(data))
    }
}

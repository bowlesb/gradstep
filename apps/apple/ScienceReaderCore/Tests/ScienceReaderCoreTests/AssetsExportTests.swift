import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// Download your assets (AssetsExport.swift) against the fixture the browser's lib/assets-export.ts writes and is checked
/// against (tests/fixtures/assets-export/assets-export-v1.json): the same files and the same zip, byte for byte.
@Suite struct AssetsExportTests {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var fixtureData: Data { try! Data(contentsOf: root.appendingPathComponent("tests/fixtures/assets-export/assets-export-v1.json")) }
    static var fixture: [String: Any] { try! JSONSerialization.jsonObject(with: fixtureData) as! [String: Any] }
    static func input() throws -> AssetsExport.Input {
        struct Wrapper: Decodable { let input: AssetsExport.Input }
        return try JSONDecoder().decode(Wrapper.self, from: fixtureData).input
    }
    static func images() throws -> [String: Data] {
        let raw = try #require(fixture["images"] as? [String: String])
        return raw.mapValues { hex in Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }) }
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isText(_ path: String) -> Bool { ["md", "mmd", "html"].contains((path as NSString).pathExtension) }

    @Test func theFilesAndZipAreTheBrowsers() throws {
        let input = try Self.input()
        let result = AssetsExport.build(input, images: try Self.images())
        let archive = try AssetsExport.zip(result.files, at: input.exportedAt)
        let expected = try #require(Self.fixture["expected"] as? [String: Any])
        #expect(result.fileName == expected["fileName"] as? String)
        #expect(result.skipped == expected["skipped"] as? [String])
        let files = try #require(expected["files"] as? [[String: String]])
        #expect(result.files.map(\.path) == files.map { $0["path"]! })
        for (file, want) in zip(result.files, files) {
            if Self.isText(file.path) { #expect(String(decoding: file.data, as: UTF8.self) == want["text"], "\(file.path)") }
            else { #expect(Self.sha256(file.data) == want["sha256"], "\(file.path)") }
        }
        #expect(archive.count == expected["zipBytes"] as? Int)
        #expect(Self.sha256(archive) == expected["zipSHA256"] as? String)
    }

    @Test func namesAreCleanedAsTheBrowserCleansThem() {
        #expect(AssetsExport.fileName("  .hidden: résumé\tnotes ") == "hidden résumé notes")
        #expect(AssetsExport.fileName("a/b\\c*?\"<>|d") == "a b c d")
        #expect(AssetsExport.fileName("...") == "Untitled")
        #expect(AssetsExport.fileName(String(repeating: "x", count: 70) + " tail", limit: 60) == String(repeating: "x", count: 60))
        #expect(AssetsExport.fileName("e\u{301}", limit: 10) == "é")
        #expect(AssetsExport.day(0) == "1970-01-01")
        #expect(AssetsExport.stamp(1_792_677_600_000) == "2026-10-22 14:00 UTC")
    }

    @Test func nothingKeptStillExplainsItself() throws {
        let result = AssetsExport.build(AssetsExport.Input(exportedAt: 1_792_677_600_000), images: [:])
        #expect(result.files.map(\.path) == ["Gradstep export 2026-10-22/README.md"])
        #expect(String(decoding: result.files[0].data, as: UTF8.self).contains("Downloaded papers aren’t included"))
        #expect(try AssetsExport.zip(result.files, at: 0).count == 22 + 76 + 2 * result.files[0].path.utf8.count + result.files[0].data.count)
    }
}

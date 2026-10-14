import CoreFoundation
import Foundation

/// Exact official HTML source identity; never a PDF document or provider job.
public struct ArxivReaderSource: Codable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let revision: Int
    public init(sourceID: String, revision: Int) throws {
        guard sourceID.range(of: #"^(?:\d{4}\.\d{4,5}|[a-z][a-z.-]+(?:\.[A-Z]{2})?/\d{7})$"#, options: .regularExpression) != nil,
              (1...2_147_483_647).contains(revision) else { throw ReaderBundleError.invalidResource }
        self.sourceID = sourceID; self.revision = revision
    }
    public var htmlURL: URL { URL(string: "https://arxiv.org/html/\(sourceID)v\(revision)")! }
    public func admitsAsset(_ value: String) -> Bool {
        guard value.utf8.count <= 2048, let url = URL(string: value), url.absoluteString == value,
              url.scheme == "https", url.host == "arxiv.org", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.hasPrefix(htmlURL.path + "/"),
              !value.contains("%"),
              !value.contains("/../"), !value.contains("/./"), !value.contains("\\"),
              ["png", "jpg", "jpeg", "svg"].contains(url.pathExtension.lowercased()) else { return false }
        return true
    }
}

enum ArxivReaderProvenance {
    static func validate(_ data: Data, manifest: ReaderBundleManifest, index: ReaderBundleIndex) throws -> ArxivReaderSource {
        guard (1...262_144).contains(data.count) else { throw ReaderBundleError.invalidResource }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw ReaderBundleError.invalidResource }
        let extended = manifest.renderer.id == "gradstep-arxiv-html-mathml-v2"
        var rootKeys: Set<String> = ["format", "source", "renderer", "image_inputs"]
        if extended { rootKeys.insert("inline_image_inputs") }
        let root = try object(value, keys: rootKeys)
        let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
        guard canonical == data, root["format"] as? String == (extended ? "arxiv-html-reader-provenance-v2" : "arxiv-html-reader-provenance-v1") else { throw ReaderBundleError.invalidResource }
        let source = try object(root["source"], keys: ["arxiv_id", "revision", "url", "bytes", "sha256"])
        guard let id = source["arxiv_id"] as? String else { throw ReaderBundleError.invalidResource }
        let identity = try ArxivReaderSource(sourceID: id, revision: integer(source["revision"], in: 1...2_147_483_647))
        guard source["url"] as? String == identity.htmlURL.absoluteString,
              source["sha256"] as? String == manifest.source.sha256 else { throw ReaderBundleError.invalidResource }
        _ = try integer(source["bytes"], in: 1...2_097_152)
        let renderer = try object(root["renderer"], keys: ["id", "build_sha256"])
        guard renderer["id"] as? String == manifest.renderer.id,
              renderer["build_sha256"] as? String == manifest.renderer.buildSHA256 else { throw ReaderBundleError.invalidResource }
        guard let rows = root["image_inputs"] as? [Any], rows.count <= 512 else { throw ReaderBundleError.invalidResource }
        let images = Dictionary(uniqueKeysWithValues: manifest.members.filter { $0.role == "image" }.map { ($0.path, $0) })
        var groups = [("source_url", rows)]
        if extended {
            guard let inline = root["inline_image_inputs"] as? [Any], inline.count + rows.count <= 512 else { throw ReaderBundleError.invalidResource }
            groups.append(("source_id", inline))
        }
        var published = Set<String>()
        for (key, inputs) in groups {
          var previous: String?
          for value in inputs {
            let row = try object(value, keys: [key, "input_sha256", "published_path", "published_sha256", "media_type", "width", "height"])
            guard let url = row[key] as? String,
                  key == "source_url" ? identity.admitsAsset(url) :
                    (url.range(of: #"^[A-Za-z_][A-Za-z0-9_.:-]{0,199}$"#, options: .regularExpression) != nil && row["media_type"] as? String == "image/png"),
                  previous.map({ $0 < url }) ?? true,
                  isDigest(row["input_sha256"]), let sha = row["published_sha256"] as? String, isDigest(sha),
                  let media = row["media_type"] as? String, let ext = ["image/png": "png", "image/jpeg": "jpg"][media],
                  let path = row["published_path"] as? String, path == "assets/" + sha + "." + ext,
                  let image = images[path], image.sha256 == sha, image.mediaType == media else { throw ReaderBundleError.invalidResource }
            guard try integer(row["width"], in: 1...8192) == image.width,
                  try integer(row["height"], in: 1...8192) == image.height else { throw ReaderBundleError.invalidResource }
            previous = url; published.insert(path)
          }
        }
        guard published == Set(images.keys), published == Set(index.figures.flatMap(\.assetPaths)),
              index.figures.allSatisfy({ !$0.alt.isEmpty }) else { throw ReaderBundleError.invalidResource }
        return identity
    }
    private static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let result = value as? [String: Any], Set(result.keys) == keys else { throw ReaderBundleError.invalidResource }
        return result
    }

    private static func integer(_ value: Any?, in range: ClosedRange<Int>) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ReaderBundleError.invalidResource
        }
        let scalar = number.doubleValue
        guard scalar.isFinite, scalar.rounded(.towardZero) == scalar,
              scalar >= Double(range.lowerBound), scalar <= Double(range.upperBound) else { throw ReaderBundleError.invalidResource }
        return Int(scalar)
    }

    private static func isDigest(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func alphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

}

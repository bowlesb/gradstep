import CoreFoundation
import Foundation

/// The closed `mathpix-reader-provenance-v2` record of a
/// `timestep-mathpix-mathml-v1` bundle, authenticated by the reader manifest.
/// It binds the OCR profile, provider job, original document, archive source,
/// renderer build and every published figure input. It does not establish
/// provider origin or account access: the publisher still supplies the
/// independently trusted manifest digest and keeps raw outputs server-side.
enum MathpixReaderProvenance {
    static let format = "mathpix-reader-provenance-v2"
    static let optionsSHA256 = "1e817fa114840383c016f89f51a562ca8c90afb07d0cae3673036e8ce1b931b3"

    static func validate(_ data: Data, manifest: ReaderBundleManifest, index: ReaderBundleIndex) throws {
        guard (1...262_144).contains(data.count) else { throw ReaderBundleError.invalidResource }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw ReaderBundleError.invalidResource }
        let root = try object(value, keys: ["format", "ocr", "provider_job_id", "document", "source", "renderer", "image_inputs"])
        // Every admitted scalar string below is ASCII. The same sorted-key JSON
        // plus LF encoding rejects duplicate keys and alternate JSON spellings.
        let canonical: Data
        do { canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10]) }
        catch { throw ReaderBundleError.invalidResource }
        guard canonical == data, root["format"] as? String == format,
              let job = root["provider_job_id"] as? String, (1...160).contains(job.utf8.count),
              job.utf8.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 95 }) else { throw ReaderBundleError.invalidResource }

        let ocr = try object(root["ocr"], keys: ["api", "profile", "options_sha256"])
        // The options hash varies with the funded page cap; the server binds it
        // to the OCR run, and the whole bundle to the trusted manifest digest.
        guard ocr["api"] as? String == "v3/pdf", ocr["profile"] as? String == "science-reader-mmd-v1",
              isDigest(ocr["options_sha256"]) else { throw ReaderBundleError.invalidResource }
        let document = try object(root["document"], keys: ["sha256", "page_count"])
        guard isDigest(document["sha256"]) else { throw ReaderBundleError.invalidResource }
        _ = try integer(document["page_count"], in: 1...250)
        let source = try object(root["source"], keys: ["archive_path", "bytes", "sha256"])
        guard let sourcePath = source["archive_path"] as? String, archivePath(sourcePath), sourcePath.hasSuffix(".mmd"),
              source["sha256"] as? String == manifest.source.sha256 else { throw ReaderBundleError.invalidResource }
        _ = try integer(source["bytes"], in: 1...2_097_152)
        let renderer = try object(root["renderer"], keys: ["id", "build_sha256"])
        guard renderer["id"] as? String == manifest.renderer.id,
              renderer["build_sha256"] as? String == manifest.renderer.buildSHA256 else { throw ReaderBundleError.invalidResource }

        guard let rows = root["image_inputs"] as? [Any], rows.count <= 512 else { throw ReaderBundleError.invalidResource }
        let images = Dictionary(uniqueKeysWithValues: manifest.members.filter { $0.role == "image" }.map { ($0.path, $0) })
        var previousPath: String?, published = Set<String>()
        for value in rows {
            let row = try object(value, keys: ["archive_path", "input_sha256", "published_path", "published_sha256", "media_type", "width", "height"])
            guard let path = row["archive_path"] as? String, archivePath(path), path != sourcePath,
                  previousPath.map({ $0 < path }) ?? true, isDigest(row["input_sha256"]),
                  let publishedSHA = row["published_sha256"] as? String, isDigest(publishedSHA),
                  let mediaType = row["media_type"] as? String, let suffix = ["image/jpeg": "jpg", "image/png": "png"][mediaType],
                  let publishedPath = row["published_path"] as? String, publishedPath == "assets/" + publishedSHA + "." + suffix,
                  let image = images[publishedPath], image.mediaType == mediaType, image.sha256 == publishedSHA else {
                throw ReaderBundleError.invalidResource
            }
            let width = try integer(row["width"], in: 1...8192), height = try integer(row["height"], in: 1...8192)
            guard width == image.width, height == image.height else { throw ReaderBundleError.invalidResource }
            // Several archive inputs may share one canonical published member;
            // each alias must match that member's hash, type and dimensions.
            previousPath = path
            published.insert(publishedPath)
        }
        let referenced = Set(index.figures.flatMap(\.assetPaths))
        guard published == Set(images.keys), referenced == published,
              index.figures.allSatisfy({ !$0.alt.isEmpty }) else { throw ReaderBundleError.invalidResource }
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

    /// Same canonical file-path subset used by reader-zip-v1. These are archive
    /// identities only; native code never opens these paths or fetches resources.
    private static func archivePath(_ path: String) -> Bool {
        guard (1...240).contains(path.utf8.count) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...8).contains(parts.count) else { return false }
        let reserved: Set<String> = ["con", "prn", "aux", "nul"]
        return parts.allSatisfy { part in
            guard let first = part.utf8.first, alphanumeric(first) || first == 45 || first == 95,
                  part.last != ".", part.utf8.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 95 || $0 == 46 }) else { return false }
            let name = String(part.split(separator: ".")[0]).lowercased()
            if reserved.contains(name) { return false }
            if name.count == 4, (name.hasPrefix("com") || name.hasPrefix("lpt")),
               let last = name.utf8.last, (49...57).contains(last) { return false }
            return true
        }
    }
}

import CoreML
import CryptoKit
import Foundation

/// The on-device PDF models as a separate download (docs/architecture/DEVICE_PDF_ROUTE.md "The models as a download").
///
/// `scripts/device-models.mjs` builds the pack (`apps/apple/DeviceModels`: the compiled models, their contracts and
/// vocabularies, checked against `apps/apple/device-models.lock.json`) and writes this description of it,
/// `device-models-pack.json`, which ships inside the app. The pack itself travels separately (an On-Demand Resources
/// tag on iPhone and iPad; inside the app on the Mac), so the app trusts only what this description names: every file's
/// size and SHA-256, and a version that is the digest of that list.
public struct DevicePDFModelPack: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
        public init(path: String, size: Int64, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
    }
    public static let schemaID = "gradstep-device-models-pack-v1"
    public let schema: String
    /// The digest of the file list (`version(of:)`): a new model, vocabulary or compiler output is a new version.
    public let version: String
    /// The On-Demand Resources tag the pack is published under, and the folder it unpacks as.
    public let tag: String
    public let folder: String
    /// The locked package digests the pack was built from, by role (`device-models.lock.json`), for reports.
    public let lock: [String: String]
    public let files: [File]

    public init(tag: String = "device-pdf-models", folder: String = "DeviceModels", lock: [String: String], files: [File]) {
        schema = Self.schemaID; self.tag = tag; self.folder = folder; self.lock = lock
        self.files = files.sorted { $0.path < $1.path }; version = Self.version(of: self.files)
    }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// `sha256("<path>\t<size>\t<sha256>\n" …)` over the files in path order; the script computes the same.
    public static func version(of files: [File]) -> String {
        let lines = files.sorted { $0.path < $1.path }.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        return Data(SHA256.hash(data: Data(lines.utf8))).hex
    }

    /// Reads and checks a description: its schema, a version that matches its files, relative paths that stay inside
    /// the pack, lowercase hex digests.
    public static func load(from url: URL) throws -> DevicePDFModelPack {
        let pack = try JSONDecoder().decode(DevicePDFModelPack.self, from: Data(contentsOf: url))
        try pack.validate()
        return pack
    }

    public func validate() throws {
        guard schema == Self.schemaID, !files.isEmpty, !tag.isEmpty, Self.isSafe(folder), !folder.contains("/") else { throw DevicePDFModelPackError.invalidDescription }
        for file in files {
            guard Self.isSafe(file.path), file.size >= 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw DevicePDFModelPackError.invalidDescription }
        }
        guard Set(files.map(\.path)).count == files.count, version == Self.version(of: files) else { throw DevicePDFModelPackError.invalidDescription }
    }

    static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public enum DevicePDFModelPackError: Error, Equatable, Sendable {
    case invalidDescription
    case missingFile(String)
    case sizeMismatch(String)
    case digestMismatch(String)
    case compileFailed(String)
}

/// The downloaded models on this device: `<root>/<version>/` (Application Support, excluded from backup), one version
/// at a time. A version is installed only after every file of the pack was copied and its size and SHA-256 matched;
/// a `.verified` marker naming the version is written last, so a copy cut short is never used.
public struct DevicePDFModelStore: Sendable {
    public let root: URL
    public let pack: DevicePDFModelPack
    static let marker = ".verified"

    public init(root: URL, pack: DevicePDFModelPack) { self.root = root; self.pack = pack }

    /// `Application Support/DevicePDFModels` for this app.
    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DevicePDFModels", isDirectory: true)
    }

    public var directory: URL { root.appendingPathComponent(pack.version, isDirectory: true) }

    /// The installed models of this build's version, or nil.
    public var installed: URL? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(Self.marker), encoding: .utf8),
              text == pack.version else { return nil }
        return directory
    }

    /// Other versions on the device (a model update leaves the old one until the new one is in).
    public var otherVersions: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != pack.version && !$0.hasPrefix(".") }
    }

    /// Bytes on disk of the installed version (0 when there is none).
    public var installedBytes: Int64 {
        guard let directory = installed else { return 0 }
        return Self.bytes(in: directory)
    }

    /// Copies the pack from `source` (its folder: the On-Demand Resources copy, a local build), checks every file against
    /// the description, compiles any `.mlpackage` it carries into the `.mlmodelc` of the same name, and makes it the
    /// installed version; older versions are removed. Only the files the description names are copied.
    @discardableResult
    public func install(from source: URL, compile: @Sendable (URL) async throws -> URL = { try await MLModel.compileModel(at: $0) },
                        progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var rootURL = root; try? rootURL.setResourceValues(values)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let total = max(1, pack.bytes)
        var done: Int64 = 0
        for file in pack.files {
            let from = source.appendingPathComponent(file.path), to = staging.appendingPathComponent(file.path)
            guard fm.fileExists(atPath: from.path) else { throw DevicePDFModelPackError.missingFile(file.path) }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
            // The copy is what will be used, so the copy is what is checked.
            let size = (try fm.attributesOfItem(atPath: to.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == file.size else { throw DevicePDFModelPackError.sizeMismatch(file.path) }
            guard try Self.sha256(of: to) == file.sha256 else { throw DevicePDFModelPackError.digestMismatch(file.path) }
            done += file.size
            progress(Double(done) / Double(total))
        }
        // A pack may carry models uncompiled (`X.mlpackage`): compiled here, on this device, to `X.mlmodelc`.
        let packages = Set(pack.files.compactMap { file -> String? in
            guard let range = file.path.range(of: ".mlpackage/") else { return nil }
            return String(file.path[..<range.upperBound].dropLast())
        })
        for package in packages.sorted() {
            let compiled: URL
            do { compiled = try await compile(staging.appendingPathComponent(package)) } catch { throw DevicePDFModelPackError.compileFailed(package) }
            let target = staging.appendingPathComponent(String(package.dropLast(".mlpackage".count)) + ".mlmodelc")
            try? fm.removeItem(at: target)
            try fm.moveItem(at: compiled, to: target)
            try fm.removeItem(at: staging.appendingPathComponent(package))
        }
        try Data(pack.version.utf8).write(to: staging.appendingPathComponent(Self.marker), options: .atomic)
        try? fm.removeItem(at: directory)
        try fm.moveItem(at: staging, to: directory)
        var installed = directory; try? installed.setResourceValues(values)
        removeOtherVersions()
        return directory
    }

    /// Removes every version but this build's.
    public func removeOtherVersions() {
        for version in otherVersions { try? FileManager.default.removeItem(at: root.appendingPathComponent(version)) }
    }

    /// Removes every downloaded version (Settings › On-device PDF model › Remove).
    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.removeItem(at: root)
    }

    /// The file's SHA-256, read in 1 MB pieces (the recogniser is hundreds of MB).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize()).hex
    }

    public static func bytes(in directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}

/// Where the models are for this run, in order: a folder named by `GRADSTEP_DEVICE_MODELS` (tests and tools on a Mac),
/// the verified download of this build's version, the models inside the app (the Mac app, a local build that carries
/// them). Nil: the models must be downloaded first.
public enum DevicePDFModelLocator {
    public static let environmentKey = "GRADSTEP_DEVICE_MODELS"

    public enum Location: Equatable, Sendable {
        case override(URL), downloaded(URL), bundled(URL)
        public var directory: URL { switch self { case .override(let url), .downloaded(let url), .bundled(let url): url } }
    }

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment, store: DevicePDFModelStore?,
                              bundled: URL?) -> Location? {
        if let path = environment[environmentKey], !path.isEmpty, hasConfiguration(URL(fileURLWithPath: path)) {
            return .override(URL(fileURLWithPath: path))
        }
        if let installed = store?.installed, hasConfiguration(installed) { return .downloaded(installed) }
        if let bundled, hasConfiguration(bundled) { return .bundled(bundled) }
        return nil
    }

    static func hasConfiguration(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("device-models.json").path)
    }
}

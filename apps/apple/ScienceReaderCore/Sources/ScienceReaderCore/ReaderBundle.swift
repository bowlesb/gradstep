import CryptoKit
import Darwin
import Foundation

public enum ReaderBundleError: Error, Equatable, Sendable {
    case invalidManifest, incompatibleFormat, invalidIndex, invalidResource, integrityFailure
}

/// Content metadata is independent of account membership. The expected manifest
/// digest must come from a trusted artifact descriptor (or the compiled sample).
public struct ReaderBundleManifest: Codable, Sendable {
    public struct Renderer: Codable, Sendable {
        public let id: String
        public let buildSHA256: String
        enum CodingKeys: String, CodingKey { case id; case buildSHA256 = "build_sha256" }
    }
    public struct Source: Codable, Sendable {
        public let kind: String
        public let sha256: String
        public let provenancePath: String
        enum CodingKeys: String, CodingKey { case kind, sha256; case provenancePath = "provenance_path" }
    }
    public struct Member: Codable, Sendable {
        public let path: String
        public let role: String
        public let mediaType: String
        public let bytes: Int
        public let sha256: String
        public let width: Int?
        public let height: Int?
        enum CodingKeys: String, CodingKey { case path, role, bytes, sha256, width, height; case mediaType = "media_type" }
    }
    public let format: String
    public let renderer: Renderer
    public let source: Source
    public let entrypoint: String
    public let indexPath: String
    public let members: [Member]
    enum CodingKeys: String, CodingKey { case format, renderer, source, entrypoint, members; case indexPath = "index_path" }
}

public struct ReaderBundleIndex: Codable, Sendable {
    public struct Heading: Codable, Sendable {
        public let id: String
        public let level: Int
        public let title: String
    }
    public struct Block: Codable, Sendable {
        public let id: String
        public let kind: String
        public let text: String
    }
    public struct Equation: Codable, Sendable {
        public let id: String
        public let blockID: String
        public let latex: String
        public let display: Bool
        public let sourceForm: String
        enum CodingKeys: String, CodingKey { case id, latex, display; case blockID = "block_id"; case sourceForm = "source_form" }
    }
    public struct Figure: Codable, Sendable {
        public let id: String
        public let blockID: String
        public let assetPaths: [String]
        public let caption: String
        public let alt: String
        enum CodingKeys: String, CodingKey { case id, caption, alt; case blockID = "block_id"; case assetPaths = "asset_paths" }
    }
    public let format: String
    public let title: String
    public let headings: [Heading]
    public let blocks: [Block]
    public let equations: [Equation]
    public let figures: [Figure]
}

/// Exact renderer/source pairs admitted by this client, each with its own
/// bounds. The authored sample keeps its original limits; the Mathpix MathML
/// renderer is sized for real papers and may publish JPEG figure crops.
struct ReaderProfile: Sendable {
    let rendererID: String
    let sourceKind: String
    let imageTypes: Set<String>
    let equations: Int, figures: Int, blocks: Int, headings: Int
    let indexBytes: Int, totalPixels: Int

    static let authored = ReaderProfile(rendererID: "timestep-mmd-v1", sourceKind: "authored-mmd", imageTypes: ["image/png"],
        equations: 512, figures: 128, blocks: 5000, headings: 500, indexBytes: 2_097_152, totalPixels: 16_000_000)
    static let mathpixMathML = ReaderProfile(rendererID: "timestep-mathpix-mathml-v1", sourceKind: "mathpix-mmd",
        imageTypes: ["image/png", "image/jpeg"], equations: 4000, figures: 256, blocks: 20_000, headings: 1000,
        indexBytes: 4_194_304, totalPixels: 64_000_000)

    static let arxivHTML = ReaderProfile(rendererID: "gradstep-arxiv-html-mathml-v1", sourceKind: "arxiv-html",
        imageTypes: ["image/png", "image/jpeg"], equations: 4000, figures: 256, blocks: 20_000, headings: 1000,
        indexBytes: 4_194_304, totalPixels: 64_000_000)
    static let arxivHTML2 = ReaderProfile(rendererID: "gradstep-arxiv-html-mathml-v2", sourceKind: "arxiv-html",
        imageTypes: ["image/png", "image/jpeg"], equations: 4000, figures: 256, blocks: 20_000, headings: 1000,
        indexBytes: 4_194_304, totalPixels: 64_000_000)

    static func matching(_ manifest: ReaderBundleManifest) -> ReaderProfile? {
        [authored, mathpixMathML, arxivHTML, arxivHTML2].first { $0.rendererID == manifest.renderer.id && $0.sourceKind == manifest.source.kind }
    }
}

/// An owned, verified snapshot. WebKit never reopens unchecked on-disk assets.
public struct VerifiedReaderBundle: Sendable {
    public let manifestSHA256: String
    /// Exact authenticated bytes, retained for encrypted installation/reopening.
    /// Re-encoding `manifest` is not guaranteed to preserve its trusted digest.
    public let manifestData: Data
    public let manifest: ReaderBundleManifest
    public let index: ReaderBundleIndex
    private let contents: [String: Data]

    public var arxivSource: ArxivReaderSource? {
        guard manifest.source.kind == "arxiv-html", let data = contents[manifest.source.provenancePath] else { return nil }
        return try? ArxivReaderProvenance.validate(data, manifest: manifest, index: index)
    }
    public var entryURL: URL { resourceURL(path: manifest.entrypoint) }
    private func resourceURL(path: String) -> URL {
        // All caller-visible member paths have already passed the ASCII policy.
        URL(string: "reader-bundle://\(manifestSHA256)/\(path)")!
    }
    public func data(for path: String) -> Data? { contents[path] }
    public func resource(for url: URL) -> (data: Data, mediaType: String)? {
        guard url.scheme == "reader-bundle", url.host == manifestSHA256,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let member = manifest.members.first(where: { resourceURL(path: $0.path).absoluteString == url.absoluteString }),
              let data = contents[member.path] else { return nil }
        return (data, member.mediaType)
    }
    public func permitsNavigation(to url: URL) -> Bool {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        parts.fragment = nil
        return parts.url?.absoluteString == entryURL.absoluteString
    }

    public static func verify(manifest input: Data, expectedSHA256: String, members: [String: Data]) throws -> Self {
        guard input.count <= 262_144, isDigest(expectedSHA256) else { throw ReaderBundleError.integrityFailure }
        let data = owned(input)
        guard digest(data) == expectedSHA256 else {
            throw ReaderBundleError.integrityFailure
        }
        let manifest: ReaderBundleManifest
        do { manifest = try JSONDecoder().decode(ReaderBundleManifest.self, from: data) }
        catch { throw ReaderBundleError.invalidManifest }
        let profile = try validate(manifest)
        guard Set(members.keys) == Set(manifest.members.map(\.path)) else { throw ReaderBundleError.invalidResource }
        var frozen: [String: Data] = [:]
        for member in manifest.members {
            guard let bytes = members[member.path], bytes.count == member.bytes,
                  bytes.count <= 16_777_216 else { throw ReaderBundleError.integrityFailure }
            let copy = owned(bytes)
            guard digest(copy) == member.sha256 else { throw ReaderBundleError.integrityFailure }
            frozen[member.path] = copy
        }
        guard let indexData = frozen[manifest.indexPath], indexData.count <= profile.indexBytes else {
            throw ReaderBundleError.invalidIndex
        }
        let index: ReaderBundleIndex
        do { index = try JSONDecoder().decode(ReaderBundleIndex.self, from: indexData) }
        catch { throw ReaderBundleError.invalidIndex }
        try validate(index, manifest: manifest, profile: profile)
        if manifest.source.kind == "mathpix-mmd" {
            guard let provenance = frozen[manifest.source.provenancePath] else { throw ReaderBundleError.invalidResource }
            try MathpixReaderProvenance.validate(provenance, manifest: manifest, index: index)
        }
        if manifest.source.kind == "arxiv-html" {
            guard let provenance = frozen[manifest.source.provenancePath] else { throw ReaderBundleError.invalidResource }
            _ = try ArxivReaderProvenance.validate(provenance, manifest: manifest, index: index)
        }
        return Self(manifestSHA256: expectedSHA256, manifestData: data, manifest: manifest, index: index, contents: frozen)
    }

    public static func load(directory: URL, expectedSHA256: String) throws -> Self {
        guard directory.isFileURL else { throw ReaderBundleError.invalidResource }
        let root = directory.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else { throw ReaderBundleError.invalidResource }
        let data = try read(root.appendingPathComponent("manifest.json"), maximum: 262_144)
        guard isDigest(expectedSHA256), digest(data) == expectedSHA256 else { throw ReaderBundleError.integrityFailure }
        let manifest: ReaderBundleManifest
        do { manifest = try JSONDecoder().decode(ReaderBundleManifest.self, from: data) }
        catch { throw ReaderBundleError.invalidManifest }
        _ = try validate(manifest)
        var members: [String: Data] = [:]
        for member in manifest.members {
            let url = root.appendingPathComponent(member.path)
            guard url.resolvingSymlinksInPath().path == url.path,
                  url.path.hasPrefix(root.path + "/") else { throw ReaderBundleError.invalidResource }
            members[member.path] = try read(url, maximum: member.bytes)
        }
        return try verify(manifest: data, expectedSHA256: expectedSHA256, members: members)
    }

    private static func read(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ReaderBundleError.invalidResource }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw ReaderBundleError.invalidResource }
        var bytes = Data()
        while let chunk = try file.read(upToCount: min(65_536, maximum + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= maximum else { throw ReaderBundleError.invalidResource }
        }
        return bytes
    }

    @discardableResult
    private static func validate(_ manifest: ReaderBundleManifest) throws -> ReaderProfile {
        guard manifest.format == "reader-bundle-v1", let profile = ReaderProfile.matching(manifest) else {
            throw ReaderBundleError.incompatibleFormat
        }
        guard isDigest(manifest.renderer.buildSHA256), isDigest(manifest.source.sha256),
              (1...512).contains(manifest.members.count) else { throw ReaderBundleError.invalidManifest }
        let mime: [String: Set<String>] = ["html": ["text/html"], "index": ["application/json"],
            "style": ["text/css"], "image": profile.imageTypes,
            "provenance": ["application/json"], "notice": ["text/plain"]]
        var paths = Set<String>(), total = 0, pixels = 0
        for member in manifest.members {
            guard validPath(member.path), member.path.lowercased() != "manifest.json",
                  paths.insert(member.path.lowercased()).inserted,
                  mime[member.role]?.contains(member.mediaType) == true,
                  (0...16_777_216).contains(member.bytes), isDigest(member.sha256) else {
                throw ReaderBundleError.invalidManifest
            }
            total += member.bytes
            if member.role == "html", member.bytes > 8_388_608 { throw ReaderBundleError.invalidManifest }
            if ["mathpix-mmd", "arxiv-html"].contains(manifest.source.kind), member.role == "provenance",
               !(1...262_144).contains(member.bytes) { throw ReaderBundleError.invalidManifest }
            if member.role == "image" {
                guard let width = member.width, let height = member.height,
                      (1...8192).contains(width), (1...8192).contains(height),
                      width * height <= 16_000_000 else { throw ReaderBundleError.invalidManifest }
                pixels += width * height
            } else if member.width != nil || member.height != nil { throw ReaderBundleError.invalidManifest }
        }
        guard total <= 33_554_432, pixels <= profile.totalPixels,
              manifest.members.filter({ $0.role == "html" }).count == 1,
              manifest.members.filter({ $0.role == "index" }).count == 1,
              manifest.members.filter({ $0.role == "provenance" }).count == 1,
              manifest.members.contains(where: { $0.path == manifest.entrypoint && $0.role == "html" }),
              manifest.members.contains(where: { $0.path == manifest.indexPath && $0.role == "index" }),
              manifest.members.contains(where: { $0.path == manifest.source.provenancePath && $0.role == "provenance" }) else {
            throw ReaderBundleError.invalidManifest
        }
        // Reject file/directory conflicts even when neither path contains '..'.
        for member in manifest.members {
            let components = member.path.lowercased().split(separator: "/")
            for count in 1..<components.count where paths.contains(components.prefix(count).joined(separator: "/")) {
                throw ReaderBundleError.invalidManifest
            }
        }
        return profile
    }

    private static func validate(_ index: ReaderBundleIndex, manifest: ReaderBundleManifest, profile: ReaderProfile) throws {
        guard index.format == "reader-index-v1", bounded(index.title, maximum: 2000), !index.title.isEmpty,
              index.headings.count <= profile.headings, (1...profile.blocks).contains(index.blocks.count),
              index.equations.count <= profile.equations, index.figures.count <= profile.figures else { throw ReaderBundleError.invalidIndex }
        let kinds: Set<String> = ["heading", "paragraph", "equation", "figure", "table", "list", "code"]
        var blocks: [String: ReaderBundleIndex.Block] = [:]
        for block in index.blocks {
            guard validID(block.id), blocks[block.id] == nil, kinds.contains(block.kind),
                  bounded(block.text) else { throw ReaderBundleError.invalidIndex }
            blocks[block.id] = block
        }
        var headings = Set<String>(), equations = Set<String>(), figures = Set<String>()
        for heading in index.headings {
            guard headings.insert(heading.id).inserted, blocks[heading.id]?.kind == "heading",
                  (1...6).contains(heading.level), bounded(heading.title, maximum: 2000), !heading.title.isEmpty else {
                throw ReaderBundleError.invalidIndex
            }
        }
        for equation in index.equations {
            guard validID(equation.id), equations.insert(equation.id).inserted,
                  blocks[equation.id] == nil, blocks[equation.blockID] != nil,
                  !equation.latex.isEmpty, bounded(equation.latex),
                  equation.sourceForm == "body" || (equation.sourceForm == "environment" && equation.display) else { throw ReaderBundleError.invalidIndex }
        }
        let images = Set(manifest.members.filter { $0.role == "image" }.map(\.path))
        for figure in index.figures {
            guard figure.id == figure.blockID, figures.insert(figure.id).inserted,
                  blocks[figure.blockID]?.kind == "figure", bounded(figure.caption), bounded(figure.alt),
                  (1...16).contains(figure.assetPaths.count), Set(figure.assetPaths).count == figure.assetPaths.count,
                  Set(figure.assetPaths).isSubset(of: images) else { throw ReaderBundleError.invalidIndex }
        }
    }

    public static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }
    private static func owned(_ data: Data) -> Data { data.isEmpty ? Data() : data.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) } }
    private static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func bounded(_ value: String, maximum: Int = 20_000) -> Bool { value.utf8.count <= maximum && !value.contains("\0") }
    private static func validID(_ value: String) -> Bool {
        (1...200).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func validPath(_ value: String) -> Bool {
        guard (1...240).contains(value.utf8.count) else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.utf8.first, (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
            return part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
        }
    }
}

/// Only IDs cross from the document for math. Equation source is resolved from
/// the verified sidecar; it is never accepted from a JavaScript message.
public struct ReaderSelection: Codable, Equatable, Sendable {
    public struct Part: Codable, Equatable, Sendable {
        public let kind: String
        public let blockID: String
        public let text: String?
        public let equationID: String?
        public init(kind: String, blockID: String, text: String? = nil, equationID: String? = nil) {
            self.kind = kind; self.blockID = blockID; self.text = text; self.equationID = equationID
        }
        enum CodingKeys: String, CodingKey { case kind, text; case blockID = "block_id"; case equationID = "equation_id" }
    }
    /// The paper's text just before and after the selection as the reader bridge reads it. Only used to find the
    /// passage again (`TextAnchor`); never part of the question, and bounded when the anchor is made.
    public struct Context: Codable, Equatable, Sendable {
        public let prefix: String
        public let suffix: String
        public init(prefix: String, suffix: String) { self.prefix = prefix; self.suffix = suffix }
    }
    public let manifestSHA256: String
    public let parts: [Part]
    public let context: Context?
    public init(manifestSHA256: String, parts: [Part], context: Context? = nil) {
        self.manifestSHA256 = manifestSHA256; self.parts = parts; self.context = context
    }
    enum CodingKeys: String, CodingKey { case parts, context; case manifestSHA256 = "manifest_sha256" }

    public func resolvedQuote(in bundle: VerifiedReaderBundle) throws -> String {
        guard manifestSHA256 == bundle.manifestSHA256, (1...512).contains(parts.count) else { throw ReaderBundleError.invalidIndex }
        let blocks = Set(bundle.index.blocks.map(\.id))
        let equations = Dictionary(uniqueKeysWithValues: bundle.index.equations.map { ($0.id, $0) })
        var seenEquations = Set<String>(), output = ""
        for part in parts {
            guard blocks.contains(part.blockID) else { throw ReaderBundleError.invalidIndex }
            switch part.kind {
            case "text":
                guard part.equationID == nil, let text = part.text, text.utf8.count <= 20_000, !text.contains("\0") else { throw ReaderBundleError.invalidIndex }
                output += text
            case "equation":
                guard part.text == nil, let id = part.equationID, seenEquations.insert(id).inserted,
                      let equation = equations[id], equation.blockID == part.blockID else { throw ReaderBundleError.invalidIndex }
                if equation.sourceForm == "environment" { output += "\n" + equation.latex + "\n" }
                else { output += equation.display ? "\n\\[\(equation.latex)\\]\n" : "\\(\(equation.latex)\\)" }
            default: throw ReaderBundleError.invalidIndex
            }
            guard output.utf8.count <= 20_000 else { throw ReaderBundleError.invalidIndex }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

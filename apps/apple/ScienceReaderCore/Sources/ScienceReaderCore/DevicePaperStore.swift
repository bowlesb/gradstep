import CryptoKit
import Darwin
import Foundation

/// The identity of one exact source revision held on this device.  The hash is
/// part of the identity so a later revision, or a different PDF served for the
/// same revision, cannot silently replace the copy a reader was using.
public struct LocalPaperIdentity: Codable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let revision: Int
    public let sha256: Data

    public init(sourceID: String, revision: Int, sha256: Data) throws {
        guard Self.validSourceID(sourceID), (1...Int(Int32.max)).contains(revision), sha256.count == 32 else {
            throw LocalPaperStoreError.invalidIdentity
        }
        self.sourceID = sourceID
        self.revision = revision
        self.sha256 = sha256
    }

    private static func validSourceID(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7e && scalar != "\\"
            }
    }
}

public struct LocalPaperRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let identity: LocalPaperIdentity
    public let byteCount: Int64
    public let createdAt: Date
    /// Hash of the encrypted file. It detects disk damage before decryption;
    /// `identity.sha256` remains the hash of the original PDF bytes.
    public let sealedSHA256: Data

    public init(id: UUID, identity: LocalPaperIdentity, byteCount: Int64, createdAt: Date, sealedSHA256: Data) throws {
        guard byteCount > 0, byteCount <= DevicePaperStore.maximumPaperBytes,
              sealedSHA256.count == 32, id != UUID.zero else { throw LocalPaperStoreError.invalidRecord }
        self.id = id
        self.identity = identity
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.sealedSHA256 = sealedSHA256
    }
}

public enum LocalPaperStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidRecord
    case invalidPDF
    case tooLarge
    case revisionConflict
    case missing
    case corruptData
    case wrongAccount
    case storageUnavailable
    case capacityExceeded
}

private struct LocalPaperManifest: Codable, Equatable {
    let format: Int
    let accountID: UUID
    var generation: Int64
    var rows: [UUID: LocalPaperRecord]

    init(accountID: UUID) {
        self.format = 1
        self.accountID = accountID
        self.generation = 0
        self.rows = [:]
    }
}

/// A bounded, file-backed encrypted store for PDFs that the server is not
/// licensed to retain. Metadata and each blob are authenticated separately so
/// a crash cannot expose a plaintext PDF or turn a substituted file into a
/// valid paper. This store is deliberately independent of the cloud library
/// journal: a source-only paper has no server document or artifact ID.
public actor DevicePaperStore {
    public static let maximumPaperBytes: Int64 = 64 * 1024 * 1024
    public static let maximumPapers = 128
    public static let maximumTotalBytes: Int64 = 2 * 1024 * 1024 * 1024

    private static let manifestName = "manifest.bin"
    private static let blobPrefix = "paper-"
    private static let blobSuffix = ".bin"
    private static let maximumManifestBytes = 512 * 1024
    private static let indexAADPrefix = "science-reader/device-papers/index/v1/"
    private static let blobAADPrefix = "science-reader/device-papers/blob/v1/"

    private let directory: URL
    private let manifestURL: URL
    private let accountID: UUID
    private let key: SymmetricKey
    private var manifest: LocalPaperManifest

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        self.directory = directory.standardizedFileURL
        self.manifestURL = directory.standardizedFileURL.appendingPathComponent(Self.manifestName)
        self.accountID = accountID
        self.key = SymmetricKey(data: localKey)

        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        let manager = FileManager.default
        try manager.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: attributes)
        try manager.setAttributes(attributes, ofItemAtPath: self.directory.path)
        var protection = URLResourceValues()
        protection.isExcludedFromBackup = true
        var securedDirectory = self.directory
        try? securedDirectory.setResourceValues(protection)

        if manager.fileExists(atPath: manifestURL.path) {
            guard try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw LocalPaperStoreError.corruptData
            }
            let sealed = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            self.manifest = try Self.openManifest(sealed, accountID: accountID, key: key)
        } else {
            self.manifest = LocalPaperManifest(accountID: accountID)
            try Self.writeManifest(self.manifest, to: manifestURL, accountID: accountID, key: key)
        }
        try Self.validateManifest(self.manifest, directory: self.directory, accountID: accountID)
        try Self.removeOrphans(in: self.directory, referenced: Set(self.manifest.rows.values.map(Self.fileName)))
    }

    public func records() -> [LocalPaperRecord] {
        manifest.rows.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id.wire < $1.id.wire : $0.createdAt > $1.createdAt
        }
    }

    public func record(sourceID: String, revision: Int) -> LocalPaperRecord? {
        manifest.rows.values.first { $0.identity.sourceID == sourceID && $0.identity.revision == revision }
    }

    public func contains(_ identity: LocalPaperIdentity) -> Bool {
        manifest.rows.values.contains { $0.identity == identity }
    }

    /// Encrypt and atomically install a PDF from a temporary file. The input
    /// is deleted by the caller; this method never retains a plaintext path.
    @discardableResult
    public func install(pdfAt sourceURL: URL, sourceID: String, revision: Int,
                        expectedSHA256: Data? = nil, createdAt: Date = Date()) throws -> LocalPaperRecord {
        guard try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LocalPaperStoreError.invalidPDF
        }
        guard let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumPaperBytes else { throw LocalPaperStoreError.tooLarge }
        let bytes: Data
        do { bytes = try Data(contentsOf: sourceURL, options: .mappedIfSafe) }
        catch { throw LocalPaperStoreError.storageUnavailable }
        return try install(pdf: bytes, sourceID: sourceID, revision: revision,
                           expectedSHA256: expectedSHA256, createdAt: createdAt)
    }

    /// Testable byte-oriented entry point; production callers should prefer
    /// `install(pdfAt:)` so the temporary source can be removed immediately.
    @discardableResult
    public func install(pdf: Data, sourceID: String, revision: Int,
                        expectedSHA256: Data? = nil, createdAt: Date = Date()) throws -> LocalPaperRecord {
        guard pdf.count >= 5, pdf.prefix(5) == Data("%PDF-".utf8) else { throw LocalPaperStoreError.invalidPDF }
        guard Int64(pdf.count) <= Self.maximumPaperBytes else { throw LocalPaperStoreError.tooLarge }
        let digest = Data(SHA256.hash(data: pdf))
        if let expectedSHA256, expectedSHA256 != digest { throw LocalPaperStoreError.revisionConflict }
        let identity = try LocalPaperIdentity(sourceID: sourceID, revision: revision, sha256: digest)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw LocalPaperStoreError.invalidRecord }

        if let existing = manifest.rows.values.first(where: { $0.identity.sourceID == sourceID && $0.identity.revision == revision }) {
            guard existing.identity == identity else { throw LocalPaperStoreError.revisionConflict }
            return existing
        }
        guard manifest.rows.count < Self.maximumPapers,
              manifest.rows.values.reduce(Int64(0), { $0 + $1.byteCount }) <= Self.maximumTotalBytes - Int64(pdf.count) else {
            throw LocalPaperStoreError.capacityExceeded
        }

        let id = UUID()
        let sealed: Data
        do {
            let aad = Self.blobAAD(accountID: accountID, recordID: id, identity: identity)
            guard let combined = try AES.GCM.seal(pdf, using: key, authenticating: aad).combined else {
                throw LocalPaperStoreError.storageUnavailable
            }
            sealed = combined
        } catch let error as LocalPaperStoreError { throw error }
        catch { throw LocalPaperStoreError.storageUnavailable }

        let destination = directory.appendingPathComponent(Self.fileName(id))
        try Self.writeAtomically(sealed, to: destination)
        var next = manifest
        next.generation = manifest.generation == Int64.max ? Int64.max : manifest.generation + 1
        let row = try LocalPaperRecord(id: id, identity: identity, byteCount: Int64(pdf.count), createdAt: createdAt,
                                       sealedSHA256: Data(SHA256.hash(data: sealed)))
        next.rows[id] = row
        do {
            try Self.writeManifest(next, to: manifestURL, accountID: accountID, key: key)
            manifest = next
            return row
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public func read(_ identity: LocalPaperIdentity) throws -> Data {
        guard let row = manifest.rows.values.first(where: { $0.identity == identity }) else { throw LocalPaperStoreError.missing }
        let url = directory.appendingPathComponent(Self.fileName(row.id))
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == Int64(row.byteCount) + 28 else { throw LocalPaperStoreError.corruptData }
        let sealed: Data
        do { sealed = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw LocalPaperStoreError.missing }
        guard Data(SHA256.hash(data: sealed)) == row.sealedSHA256 else { throw LocalPaperStoreError.corruptData }
        do {
            let aad = Self.blobAAD(accountID: accountID, recordID: row.id, identity: identity)
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
            guard data.count == row.byteCount, data.prefix(5) == Data("%PDF-".utf8),
                  Data(SHA256.hash(data: data)) == identity.sha256 else { throw LocalPaperStoreError.corruptData }
            return data
        } catch let error as LocalPaperStoreError { throw error }
        catch { throw LocalPaperStoreError.corruptData }
    }

    public func remove(_ identity: LocalPaperIdentity) throws {
        guard let row = manifest.rows.values.first(where: { $0.identity == identity }) else { throw LocalPaperStoreError.missing }
        var next = manifest
        next.generation = manifest.generation == Int64.max ? Int64.max : manifest.generation + 1
        next.rows.removeValue(forKey: row.id)
        // Commit the encrypted index first. If the process dies here, the
        // still-present blob is an authenticated orphan and is pruned on the
        // next open. The inverse order could leave an index pointing nowhere.
        try Self.writeManifest(next, to: manifestURL, accountID: accountID, key: key)
        manifest = next
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(row.id)))
    }

    public func removeAll() throws {
        let rows = manifest.rows
        var next = manifest
        next.generation = manifest.generation == Int64.max ? Int64.max : manifest.generation + 1
        next.rows = [:]
        try Self.writeManifest(next, to: manifestURL, accountID: accountID, key: key)
        manifest = next
        for row in rows.values { try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(row.id))) }
    }

    public func generation() -> Int64 { manifest.generation }

    private static func indexAAD(accountID: UUID) -> Data { Data((indexAADPrefix + accountID.wire).utf8) }

    private static func blobAAD(accountID: UUID, recordID: UUID, identity: LocalPaperIdentity) -> Data {
        Data((blobAADPrefix + accountID.wire + "/" + recordID.wire + "/" + identity.sourceID + "/" + String(identity.revision) + "/" + identity.sha256.hex).utf8)
    }

    private static func fileName(_ row: LocalPaperRecord) -> String { fileName(row.id) }
    private static func fileName(_ id: UUID) -> String { blobPrefix + id.wire + blobSuffix }

    private static func openManifest(_ sealed: Data, accountID: UUID, key: SymmetricKey) throws -> LocalPaperManifest {
        guard sealed.count >= 28, sealed.count <= maximumManifestBytes else { throw LocalPaperStoreError.corruptData }
        do {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: indexAAD(accountID: accountID))
            let manifest = try JSONDecoder().decode(LocalPaperManifest.self, from: bytes)
            try validateManifest(manifest, directory: nil, accountID: accountID)
            return manifest
        } catch let error as LocalPaperStoreError { throw error }
        catch { throw LocalPaperStoreError.corruptData }
    }

    private static func validateManifest(_ value: LocalPaperManifest, directory: URL?, accountID: UUID) throws {
        guard value.format == 1, value.accountID == accountID, value.generation >= 0,
              value.rows.count <= maximumPapers,
              value.rows.values.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= maximumPaperBytes && $0.sealedSHA256.count == 32 }),
              value.rows.values.reduce(Int64(0), { $0 + $1.byteCount }) <= maximumTotalBytes,
              Set(value.rows.values.map { "\($0.identity.sourceID)\u{1f}\($0.identity.revision)" }).count == value.rows.count else {
            throw LocalPaperStoreError.corruptData
        }
        if let directory {
            let manager = FileManager.default
            for row in value.rows.values {
                let url = directory.appendingPathComponent(fileName(row.id))
                guard manager.fileExists(atPath: url.path),
                      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      Int64(size) == row.byteCount + 28 else { throw LocalPaperStoreError.corruptData }
            }
        }
    }

    private static func writeManifest(_ value: LocalPaperManifest, to url: URL, accountID: UUID, key: SymmetricKey) throws {
        try validateManifest(value, directory: nil, accountID: accountID)
        let plain: Data
        do { plain = try ReaderCrypto.encode(value) } catch { throw LocalPaperStoreError.storageUnavailable }
        guard plain.count <= maximumManifestBytes - 28 else { throw LocalPaperStoreError.capacityExceeded }
        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(plain, using: key, authenticating: indexAAD(accountID: accountID)).combined else {
                throw LocalPaperStoreError.storageUnavailable
            }
            sealed = combined
        } catch let error as LocalPaperStoreError { throw error }
        catch { throw LocalPaperStoreError.storageUnavailable }
        try writeAtomically(sealed, to: url)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().wire).tmp")
        do {
            guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LocalPaperStoreError.storageUnavailable
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as LocalPaperStoreError {
            try? manager.removeItem(at: temporary)
            throw error
        } catch {
            try? manager.removeItem(at: temporary)
            // A full disk says so, with about how much to free (docs/reviews/OFFLINE_AND_STORAGE_20261025.md).
            if StorageSpace.isOutOfSpace(error) { throw StorageSpace.fullError(writing: Int64(data.count), at: url) }
            throw LocalPaperStoreError.storageUnavailable
        }
    }

    private static func removeOrphans(in directory: URL, referenced: Set<String>) throws {
        let manager = FileManager.default
        // A write interrupted by a crash leaves its hidden temporary file (up to the 64 MB limit); none is in use while
        // the store is being opened.
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        for url in files where url.lastPathComponent.hasPrefix(blobPrefix) && url.pathExtension == String(blobSuffix.dropFirst())
            && !referenced.contains(url.lastPathComponent) {
            try? manager.removeItem(at: url)
        }
    }
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

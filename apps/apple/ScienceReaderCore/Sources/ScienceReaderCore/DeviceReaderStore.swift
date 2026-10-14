import CryptoKit
import Darwin
import Foundation

/// The identity of one exact source revision held on this device.  The hash is
/// part of the identity so a later revision, or a different bundle prepared for the
/// same revision, cannot silently replace the copy a reader was using.
public struct LocalReaderIdentity: Codable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let revision: Int
    public let sha256: Data

    public init(sourceID: String, revision: Int, sha256: Data) throws {
        guard Self.validSourceID(sourceID), (1...Int(Int32.max)).contains(revision), sha256.count == 32 else {
            throw LocalReaderStoreError.invalidIdentity
        }
        self.sourceID = sourceID
        self.revision = revision
        self.sha256 = sha256
    }

    private static func validSourceID(_ value: String) -> Bool {
        (try? ArxivReaderSource(sourceID: value, revision: 1)) != nil
    }
}

public struct LocalReaderRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let identity: LocalReaderIdentity
    public let byteCount: Int64
    public let createdAt: Date
    /// Hash of the encrypted file. It detects disk damage before decryption;
    /// `identity.sha256` remains the hash of the encrypted bundle’s decoded transport bytes.
    public let sealedSHA256: Data

    public init(id: UUID, identity: LocalReaderIdentity, byteCount: Int64, createdAt: Date, sealedSHA256: Data) throws {
        guard byteCount > 0, byteCount <= DeviceReaderStore.maximumReaderBytes,
              sealedSHA256.count == 32, id != UUID.zero else { throw LocalReaderStoreError.invalidRecord }
        self.id = id
        self.identity = identity
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.sealedSHA256 = sealedSHA256
    }
}

public enum LocalReaderStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidRecord
    case invalidBundle
    case tooLarge
    case revisionConflict
    case missing
    case corruptData
    case wrongAccount
    case storageUnavailable
    case capacityExceeded
}

private struct LocalReaderManifest: Codable, Equatable {
    let format: Int
    let accountID: UUID
    var generation: Int64
    var rows: [UUID: LocalReaderRecord]

    init(accountID: UUID) {
        self.format = 1
        self.accountID = accountID
        self.generation = 0
        self.rows = [:]
    }
}

/// Account-isolated encrypted HTML bundles, independent of server artifacts.
/// AAD domains, directory and manifest are separate from the PDF store. Atomic
/// publication retains the preceding verified copy after interrupted writes.
public actor DeviceReaderStore {
    public static let maximumReaderBytes: Int64 = 64 * 1024 * 1024
    public static let maximumReaders = 128
    public static let maximumTotalBytes: Int64 = 2 * 1024 * 1024 * 1024

    private static let manifestName = "manifest.bin"
    private static let blobPrefix = "reader-"
    private static let blobSuffix = ".bin"
    private static let maximumManifestBytes = 512 * 1024
    private static let indexAADPrefix = "science-reader/device-readers/index/v1/"
    private static let blobAADPrefix = "science-reader/device-readers/blob/v1/"

    private let directory: URL
    private let manifestURL: URL
    private let accountID: UUID
    private let key: SymmetricKey
    private var manifest: LocalReaderManifest

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
                throw LocalReaderStoreError.corruptData
            }
            let sealed = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            self.manifest = try Self.openManifest(sealed, accountID: accountID, key: key)
        } else {
            self.manifest = LocalReaderManifest(accountID: accountID)
            try Self.writeManifest(self.manifest, to: manifestURL, accountID: accountID, key: key)
        }
        try Self.validateManifest(self.manifest, directory: self.directory, accountID: accountID)
        try Self.removeOrphans(in: self.directory, referenced: Set(self.manifest.rows.values.map(Self.fileName)))
    }

    public func records() -> [LocalReaderRecord] {
        manifest.rows.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id.wire < $1.id.wire : $0.createdAt > $1.createdAt
        }
    }

    public func record(sourceID: String, revision: Int) -> LocalReaderRecord? {
        manifest.rows.values.first { $0.identity.sourceID == sourceID && $0.identity.revision == revision }
    }

    public func contains(_ identity: LocalReaderIdentity) -> Bool {
        manifest.rows.values.contains { $0.identity == identity }
    }

    /// The caller must independently validate the HTML/index and decoded images
    /// before installation; this layer rechecks the manifest, source and hashes.
    @discardableResult
    public func install(bundle: VerifiedReaderBundle, createdAt: Date = Date()) throws -> LocalReaderRecord {
        guard let source = bundle.arxivSource else { throw LocalReaderStoreError.invalidBundle }
        let sourceID = source.sourceID, revision = source.revision
        let payload = try DeviceReaderPackage.encode(bundle)
        guard Int64(payload.count) <= Self.maximumReaderBytes else { throw LocalReaderStoreError.tooLarge }
        let digest = Data(SHA256.hash(data: payload))
        let identity = try LocalReaderIdentity(sourceID: sourceID, revision: revision, sha256: digest)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw LocalReaderStoreError.invalidRecord }

        if let existing = manifest.rows.values.first(where: { $0.identity.sourceID == sourceID && $0.identity.revision == revision }) {
            guard existing.identity == identity else { throw LocalReaderStoreError.revisionConflict }
            return existing
        }
        guard manifest.rows.count < Self.maximumReaders,
              manifest.rows.values.reduce(Int64(0), { $0 + $1.byteCount }) <= Self.maximumTotalBytes - Int64(payload.count) else {
            throw LocalReaderStoreError.capacityExceeded
        }

        let id = UUID()
        let sealed: Data
        do {
            let aad = Self.blobAAD(accountID: accountID, recordID: id, identity: identity)
            guard let combined = try AES.GCM.seal(payload, using: key, authenticating: aad).combined else {
                throw LocalReaderStoreError.storageUnavailable
            }
            sealed = combined
        } catch let error as LocalReaderStoreError { throw error }
        catch { throw LocalReaderStoreError.storageUnavailable }

        let destination = directory.appendingPathComponent(Self.fileName(id))
        try Self.writeAtomically(sealed, to: destination)
        var next = manifest
        next.generation = manifest.generation == Int64.max ? Int64.max : manifest.generation + 1
        let row = try LocalReaderRecord(id: id, identity: identity, byteCount: Int64(payload.count), createdAt: createdAt,
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

    public func read(_ identity: LocalReaderIdentity) throws -> VerifiedReaderBundle {
        guard let row = manifest.rows.values.first(where: { $0.identity == identity }) else { throw LocalReaderStoreError.missing }
        let url = directory.appendingPathComponent(Self.fileName(row.id))
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == Int64(row.byteCount) + 28 else { throw LocalReaderStoreError.corruptData }
        let sealed: Data
        do { sealed = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw LocalReaderStoreError.missing }
        guard Data(SHA256.hash(data: sealed)) == row.sealedSHA256 else { throw LocalReaderStoreError.corruptData }
        do {
            let aad = Self.blobAAD(accountID: accountID, recordID: row.id, identity: identity)
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
            guard data.count == row.byteCount,
                  Data(SHA256.hash(data: data)) == identity.sha256 else { throw LocalReaderStoreError.corruptData }
            let bundle = try DeviceReaderPackage.decode(data)
            guard let source = bundle.arxivSource, source.sourceID == identity.sourceID, source.revision == identity.revision else {
                throw LocalReaderStoreError.corruptData
            }
            return bundle
        } catch let error as LocalReaderStoreError { throw error }
        catch { throw LocalReaderStoreError.corruptData }
    }

    public func remove(_ identity: LocalReaderIdentity) throws {
        guard let row = manifest.rows.values.first(where: { $0.identity == identity }) else { throw LocalReaderStoreError.missing }
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

    private static func blobAAD(accountID: UUID, recordID: UUID, identity: LocalReaderIdentity) -> Data {
        Data((blobAADPrefix + accountID.wire + "/" + recordID.wire + "/" + identity.sourceID + "/" + String(identity.revision) + "/" + identity.sha256.hex).utf8)
    }

    private static func fileName(_ row: LocalReaderRecord) -> String { fileName(row.id) }
    private static func fileName(_ id: UUID) -> String { blobPrefix + id.wire + blobSuffix }

    private static func openManifest(_ sealed: Data, accountID: UUID, key: SymmetricKey) throws -> LocalReaderManifest {
        guard sealed.count >= 28, sealed.count <= maximumManifestBytes else { throw LocalReaderStoreError.corruptData }
        do {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: indexAAD(accountID: accountID))
            let manifest = try JSONDecoder().decode(LocalReaderManifest.self, from: bytes)
            try validateManifest(manifest, directory: nil, accountID: accountID)
            return manifest
        } catch let error as LocalReaderStoreError { throw error }
        catch { throw LocalReaderStoreError.corruptData }
    }

    private static func validateManifest(_ value: LocalReaderManifest, directory: URL?, accountID: UUID) throws {
        guard value.format == 1, value.accountID == accountID, value.generation >= 0,
              value.rows.count <= maximumReaders,
              value.rows.values.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= maximumReaderBytes && $0.sealedSHA256.count == 32 }),
              value.rows.values.reduce(Int64(0), { $0 + $1.byteCount }) <= maximumTotalBytes,
              Set(value.rows.values.map { "\($0.identity.sourceID)\u{1f}\($0.identity.revision)" }).count == value.rows.count else {
            throw LocalReaderStoreError.corruptData
        }
        if let directory {
            let manager = FileManager.default
            for row in value.rows.values {
                let url = directory.appendingPathComponent(fileName(row.id))
                guard manager.fileExists(atPath: url.path),
                      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      Int64(size) == row.byteCount + 28 else { throw LocalReaderStoreError.corruptData }
            }
        }
    }

    private static func writeManifest(_ value: LocalReaderManifest, to url: URL, accountID: UUID, key: SymmetricKey) throws {
        try validateManifest(value, directory: nil, accountID: accountID)
        let plain: Data
        do { plain = try ReaderCrypto.encode(value) } catch { throw LocalReaderStoreError.storageUnavailable }
        guard plain.count <= maximumManifestBytes - 28 else { throw LocalReaderStoreError.capacityExceeded }
        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(plain, using: key, authenticating: indexAAD(accountID: accountID)).combined else {
                throw LocalReaderStoreError.storageUnavailable
            }
            sealed = combined
        } catch let error as LocalReaderStoreError { throw error }
        catch { throw LocalReaderStoreError.storageUnavailable }
        try writeAtomically(sealed, to: url)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().wire).tmp")
        do {
            guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LocalReaderStoreError.storageUnavailable
            }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as LocalReaderStoreError {
            try? manager.removeItem(at: temporary)
            throw error
        } catch {
            try? manager.removeItem(at: temporary)
            throw LocalReaderStoreError.storageUnavailable
        }
    }

    private static func removeOrphans(in directory: URL, referenced: Set<String>) throws {
        let manager = FileManager.default
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

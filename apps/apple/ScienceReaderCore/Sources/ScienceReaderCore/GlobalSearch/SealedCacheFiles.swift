import CryptoKit
import Foundation

/// A folder of small cache files sealed with the account's local-store key (AES-GCM; the associated data binds each file
/// to the account, the cache and its name), with complete file protection and excluded from backup. ML paper search
/// keeps a query's results here for a day (docs/architecture/GLOBAL_SEARCH.md "ML paper search cache"); before
/// 2026-10-25 they were plaintext JSON.
public struct SealedCacheFiles: Sendable {
    public let directory: URL
    private let accountID: UUID
    private let key: SymmetricKey
    private let namespace: String
    /// A file over this size is never read.
    public static let maximumBytes = 4_194_304

    public init(directory: URL, accountID: UUID, localKey: Data, namespace: String) throws {
        guard localKey.count == 32 else { throw ReaderError.invalidKey }
        self.directory = directory.standardizedFileURL; self.accountID = accountID; key = SymmetricKey(data: localKey); self.namespace = namespace
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: attributes)
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: self.directory.path)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = self.directory
        try? excluded.setResourceValues(values)
    }

    private func aad(_ name: String) -> Data { Data("science-reader/\(namespace)/v1/\(accountID.wire)/\(name)".utf8) }

    private func url(_ name: String) -> URL? {
        guard !name.isEmpty, name.count <= 128, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return directory.appendingPathComponent(name + ".sealed")
    }

    /// The file's contents, or nil when it is missing, unreadable, too large or sealed for another account or name.
    public func read(_ name: String) -> Data? {
        guard let url = url(name), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let sealed = try? Data(contentsOf: url), sealed.count <= Self.maximumBytes,
              let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: aad(name))
    }

    public func write(_ data: Data, as name: String) throws {
        guard let url = url(name), data.count <= Self.maximumBytes,
              let sealed = try AES.GCM.seal(data, using: key, authenticating: aad(name)).combined else { throw ReaderError.invalidEvent }
        #if os(iOS)
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try sealed.write(to: url, options: [.atomic])
        #endif
    }

    /// Removes every file (sign-out).
    public func removeAll() { try? FileManager.default.removeItem(at: directory) }
}

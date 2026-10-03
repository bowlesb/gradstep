import CryptoKit
import Foundation

public struct ReportImage: Codable, Equatable, Sendable {
    public let id: UUID
    public let bytes: Data
    public let mediaType: String
    public init(id: UUID = UUID(), bytes: Data, mediaType: String) { self.id = id; self.bytes = bytes; self.mediaType = mediaType }
}

public struct SupportDraft: Codable, Equatable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable { case report, reply, status }
    public let id: UUID
    public let accountID: UUID
    public let reportID: UUID
    public let action: Action
    public let createdAt: Date
    public let text: String
    public let title: String?
    public let appVersion: String?
    public let build: String?
    public let osVersion: String?
    public let screen: String?
    public let image: ReportImage?

    public init(id: UUID = UUID(), accountID: UUID, reportID: UUID, action: Action, text: String, title: String? = nil,
                appVersion: String? = nil, build: String? = nil, osVersion: String? = nil, screen: String? = nil, image: ReportImage? = nil) {
        self.id = id; self.accountID = accountID; self.reportID = reportID; self.action = action; self.createdAt = Date()
        self.text = text; self.title = title; self.appVersion = appVersion; self.build = build; self.osVersion = osVersion; self.screen = screen; self.image = image
    }
    public func validate(accountID: UUID) throws {
        guard self.accountID == accountID else { throw ReaderError.wrongAccount }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 10000 else { throw ReaderError.invalidEvent }
        switch action {
        case .report:
            guard id == reportID, let title, !title.isEmpty, title.unicodeScalars.count <= 160,
                  let appVersion, !appVersion.isEmpty, appVersion.count <= 40, let build, !build.isEmpty, build.count <= 40,
                  let osVersion, osVersion.count <= 100, let screen, screen.count <= 100 else { throw ReaderError.invalidEvent }
        case .reply: guard image == nil else { throw ReaderError.invalidEvent }
        case .status: guard ["open", "verified"].contains(text), image == nil else { throw ReaderError.invalidEvent }
        }
        if let image { guard ["image/png", "image/jpeg"].contains(image.mediaType), !image.bytes.isEmpty, image.bytes.count <= 5 * 1024 * 1024 else { throw ReaderError.invalidEvent } }
    }
}

/// Bounded, independent encrypted records. Changing one queued report never
/// rewrites another report's screenshot. The operation identity binds the AAD.
public actor SupportOutbox {
    private let directory: URL
    private let accountID: UUID
    private let key: SymmetricKey

    public init(directory: URL, accountID: UUID, key: Data) throws {
        guard key.count == 32 else { throw ReaderError.invalidKey }
        self.directory = directory; self.accountID = accountID; self.key = SymmetricKey(data: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        var url = directory; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try url.setResourceValues(flags)
    }

    public func pending() throws -> [SupportDraft] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "enc" }.map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw ReaderError.corruptData }
                return try read(id)
            }.sorted { $0.createdAt == $1.createdAt ? $0.id.wire < $1.id.wire : $0.createdAt < $1.createdAt }
    }

    public func enqueue(_ draft: SupportDraft) throws {
        try draft.validate(accountID: accountID)
        let url = path(draft.id)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(draft.id) == draft else { throw ReaderError.eventConflict }
            return
        }
        guard try pending().count < 20 else { throw ReaderError.pendingChanges }
        guard let bytes = try AES.GCM.seal(ReaderCrypto.encode(draft), using: key, authenticating: aad(draft.id)).combined else { throw ReaderError.corruptData }
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }

    public func acknowledge(_ draft: SupportDraft) throws {
        guard try read(draft.id) == draft else { throw ReaderError.eventConflict }
        try FileManager.default.removeItem(at: path(draft.id))
    }
    private func path(_ id: UUID) -> URL { directory.appendingPathComponent(id.wire + ".enc") }
    private func aad(_ id: UUID) -> Data { Data("science-reader/support-outbox/v1/\(accountID.wire)/\(id.wire)".utf8) }
    private func read(_ id: UUID) throws -> SupportDraft {
        let bytes = try Data(contentsOf: path(id))
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad(id))
        let draft = try JSONDecoder().decode(SupportDraft.self, from: plain)
        guard draft.id == id else { throw ReaderError.corruptData }
        try draft.validate(accountID: accountID)
        return draft
    }
}

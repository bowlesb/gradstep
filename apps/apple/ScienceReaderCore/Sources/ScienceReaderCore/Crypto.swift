import CryptoKit
import Foundation

public enum ReaderError: Error, Equatable, Sendable, CaseIterable {
    case invalidKey, invalidRecoveryCode, wrongAccount, unsupportedFormat, corruptData
    case eventConflict, cursorGap, staleEpoch, missingKey, invalidEvent, pendingChanges
    case storageUnavailable, storeChanged, localCapacityExceeded
}

/// Sync-status copy. Each case says what stopped and that this device's copy still works; nothing quotes server
/// text or event content. A sign-in does not reopen history from zero, so no case promises that.
extension ReaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Update Gradstep to keep syncing this history. Everything on this device stays available."
        case .invalidEvent, .corruptData:
            "Sync stopped at an entry this device can’t read. Everything on this device stays available; send a report so it can be fixed."
        case .eventConflict:
            "Sync stopped at an entry that doesn’t match this device’s copy. Everything on this device stays available; send a report so it can be fixed."
        case .cursorGap:
            "Sync stopped at a gap in your cloud history. Everything on this device stays available; send a report so it can be fixed."
        case .missingKey, .staleEpoch: "This device needs updated encryption keys from an approved device or recovery code."
        case .invalidKey: "This device’s encryption keys aren’t valid. Restore them with a recovery code or an approved device."
        case .invalidRecoveryCode: "That recovery code wasn’t accepted. Check it and try again."
        case .wrongAccount: "These keys belong to a different account. Sign out and sign in again."
        case .pendingChanges: "Changes on this device haven’t synced yet. Try again once sync finishes."
        case .storageUnavailable: "This device’s private library isn’t open. Reopen the app and try again."
        case .storeChanged: "This device’s private library was replaced. Reopen the app and try again."
        case .localCapacityExceeded: "This device’s private library is full. Remove downloaded papers or chats to make room."
        }
    }
}

public struct KeyBundle: Codable, Equatable, Sendable {
    public let accountID: UUID
    public var epoch: Int
    public var contentKeys: [String: Data]
    public var managementToken: Data

    public static func generate(accountID: UUID) -> KeyBundle {
        KeyBundle(accountID: accountID, epoch: 1, contentKeys: ["1": ReaderCrypto.randomKey()], managementToken: ReaderCrypto.randomKey())
    }

    public func validate(accountID: UUID) throws {
        guard self.accountID == accountID else { throw ReaderError.wrongAccount }
        guard epoch > 0, epoch <= Int(Int32.max), contentKeys[String(epoch)] != nil,
              managementToken.count == 32, !contentKeys.isEmpty,
              contentKeys.allSatisfy({ key, data in
                  guard let number = Int(key) else { return false }
                  return number > 0 && number <= epoch && String(number) == key && data.count == 32
              }) else { throw ReaderError.invalidKey }
    }

    public func key(for epoch: Int) throws -> SymmetricKey {
        try validate(accountID: accountID)
        guard let bytes = contentKeys[String(epoch)] else { throw ReaderError.missingKey }
        return SymmetricKey(data: bytes)
    }

    public mutating func rotate() throws {
        guard epoch < Int(Int32.max) else { throw ReaderError.invalidKey }
        epoch += 1
        contentKeys[String(epoch)] = ReaderCrypto.randomKey()
        managementToken = ReaderCrypto.randomKey()
    }
}

public struct EventEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let epoch: Int
    public let format: Int
    public let ciphertext: Data

    public var sha256: Data { Data(SHA256.hash(data: ciphertext)) }

    public init(id: UUID, deviceID: UUID, epoch: Int, format: Int = 1, ciphertext: Data) {
        self.id = id; self.deviceID = deviceID; self.epoch = epoch
        self.format = format; self.ciphertext = ciphertext
    }
}

public enum ReaderCrypto {
    public static func randomKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func eventAAD(accountID: UUID, id: UUID, deviceID: UUID, epoch: Int, format: Int) -> Data {
        Data("science-reader/event/v1\n\(accountID.wire)\n\(id.wire)\n\(deviceID.wire)\n\(epoch)\n\(format)\n".utf8)
    }

    public static func seal(_ event: PrivateEvent, id: UUID, deviceID: UUID, keys: KeyBundle) throws -> EventEnvelope {
        try event.validate()
        let format = event.kind == .localPaper || event.paperReference != nil || event.anchor?.manifestSHA256 != nil ? 2 : 1
        let aad = eventAAD(accountID: keys.accountID, id: id, deviceID: deviceID, epoch: keys.epoch, format: format)
        let sealed = try AES.GCM.seal(encode(event), using: keys.key(for: keys.epoch), authenticating: aad)
        guard let bytes = sealed.combined, bytes.count <= 262_144 else { throw ReaderError.invalidEvent }
        return EventEnvelope(id: id, deviceID: deviceID, epoch: keys.epoch, format: format, ciphertext: bytes)
    }

    public static func open(_ envelope: EventEnvelope, keys: KeyBundle) throws -> PrivateEvent {
        guard [1, 2].contains(envelope.format) else { throw ReaderError.unsupportedFormat }
        guard envelope.ciphertext.count >= 28, envelope.ciphertext.count <= 262_144 else { throw ReaderError.corruptData }
        let aad = eventAAD(accountID: keys.accountID, id: envelope.id, deviceID: envelope.deviceID, epoch: envelope.epoch, format: envelope.format)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: keys.key(for: envelope.epoch), authenticating: aad)
        let event = try JSONDecoder().decode(PrivateEvent.self, from: bytes)
        try event.validate()
        if envelope.format == 1, event.kind == .localPaper || event.paperReference != nil || event.anchor?.manifestSHA256 != nil { throw ReaderError.unsupportedFormat }
        return event
    }

    public static func recoveryCode() -> String {
        let hex = randomKey().hex
        return stride(from: 0, to: hex.count, by: 8).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 8)])
        }.joined(separator: "-")
    }

    private static func recoveryKey(code: String, accountID: UUID) throws -> SymmetricKey {
        let compact = code.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        guard let bytes = Data(hex: compact), bytes.count == 32 else { throw ReaderError.invalidRecoveryCode }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Data(accountID.wire.utf8),
                                     info: Data("science-reader/recovery/v1".utf8), outputByteCount: 32)
    }

    public static func wrapRecovery(_ keys: KeyBundle, code: String) throws -> Data {
        try keys.validate(accountID: keys.accountID)
        let aad = Data("science-reader/recovery/v1/\(keys.accountID.wire)".utf8)
        guard let data = try AES.GCM.seal(encode(keys), using: recoveryKey(code: code, accountID: keys.accountID), authenticating: aad).combined else {
            throw ReaderError.corruptData
        }
        return data
    }

    public static func recover(_ wrapped: Data, code: String, accountID: UUID) throws -> KeyBundle {
        let aad = Data("science-reader/recovery/v1/\(accountID.wire)".utf8)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: recoveryKey(code: code, accountID: accountID), authenticating: aad)
        let bundle = try JSONDecoder().decode(KeyBundle.self, from: bytes)
        try bundle.validate(accountID: accountID)
        return bundle
    }

    public static func enrollmentFingerprint(accountID: UUID, deviceID: UUID, publicKey: Data, challenge: Data) throws -> String {
        guard publicKey.count == 32, challenge.count == 32 else { throw ReaderError.invalidKey }
        return Data(SHA256.hash(data: Data("science-reader/enrollment/v1/\(accountID.wire)/\(deviceID.wire)/".utf8) + publicKey + challenge)).hex
    }

    private static func deviceContext(accountID: UUID, deviceID: UUID, epoch: Int, challenge: Data) throws -> Data {
        guard challenge.count == 32, epoch > 0 else { throw ReaderError.invalidKey }
        return Data("science-reader/device-envelope/v1/\(accountID.wire)/\(deviceID.wire)/\(epoch)/".utf8) + challenge
    }

    public static func wrapForDevice(_ keys: KeyBundle, deviceID: UUID, recipientPublicKey: Data, challenge: Data) throws -> Data {
        try keys.validate(accountID: keys.accountID)
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let context = try deviceContext(accountID: keys.accountID, deviceID: deviceID, epoch: keys.epoch, challenge: challenge)
        let publicBytes = ephemeral.publicKey.rawRepresentation
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: publicBytes + recipientPublicKey, outputByteCount: 32)
        guard let wrapped = try AES.GCM.seal(encode(keys), using: key, authenticating: context + publicBytes + recipientPublicKey).combined else {
            throw ReaderError.corruptData
        }
        return publicBytes + wrapped
    }

    public static func unwrapForDevice(_ wrapped: Data, accountID: UUID, deviceID: UUID, epoch: Int,
                                      privateKey: Curve25519.KeyAgreement.PrivateKey, challenge: Data) throws -> KeyBundle {
        guard wrapped.count >= 60, wrapped.count <= 65536 else { throw ReaderError.corruptData }
        let publicBytes = Data(wrapped.prefix(32))
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicBytes)
        let context = try deviceContext(accountID: accountID, deviceID: deviceID, epoch: epoch, challenge: challenge)
        let recipient = privateKey.publicKey.rawRepresentation
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: context, sharedInfo: publicBytes + recipient, outputByteCount: 32)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped.dropFirst(32)), using: key, authenticating: context + publicBytes + recipient)
        let bundle = try JSONDecoder().decode(KeyBundle.self, from: bytes)
        try bundle.validate(accountID: accountID)
        guard bundle.epoch == epoch else { throw ReaderError.staleEpoch }
        return bundle
    }
}

extension UUID { public var wire: String { uuidString.lowercased() } }
extension Data {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            guard let value = UInt8(hex[cursor..<next], radix: 16) else { return nil }
            bytes.append(value); cursor = next
        }
        self.init(bytes)
    }
}

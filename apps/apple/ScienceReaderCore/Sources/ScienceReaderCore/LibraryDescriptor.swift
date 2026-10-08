import CryptoKit
import Foundation

/// Mutable private-display state, separate from immutable catalog metadata.
public struct LibraryDescriptorReference: Codable, Equatable, Hashable, Sendable {
    public let descriptorID: UUID
    public let revision: Int
    public let epoch: Int
    public let sha256: String
    private enum CodingKeys: String, CodingKey { case descriptorID = "descriptor_id", revision, epoch, sha256 }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .descriptorID)
        guard let descriptorID = UUID(uuidString: id), descriptorID.wire == id else { throw ReaderError.corruptData }
        self.descriptorID = descriptorID
        revision = try values.decode(Int.self, forKey: .revision)
        epoch = try values.decode(Int.self, forKey: .epoch)
        sha256 = try values.decode(String.self, forKey: .sha256)
        guard (1...Int(Int32.max)).contains(revision), (1...Int(Int32.max)).contains(epoch), sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ReaderError.corruptData }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(descriptorID.wire, forKey: .descriptorID)
        try values.encode(revision, forKey: .revision); try values.encode(epoch, forKey: .epoch)
        try values.encode(sha256, forKey: .sha256)
    }
}

/// Private display text for a library source. It is neither public catalog metadata nor a filesystem path.
public struct LibraryDescriptorPayload: Codable, Equatable, Sendable {
    public let displayName: String
    public let filename: String?

    public init(displayName: String, filename: String? = nil) throws {
        let name = try Self.normalizeName(displayName)
        guard Self.validText(name, scalars: 500, bytes: 2_000),
              filename.map({ Self.validText($0, scalars: 255, bytes: 1_024)
                  && $0.unicodeScalars.contains(where: { !Self.isWhitespace($0.value) }) }) ?? true
        else { throw ReaderError.invalidEvent }
        self.displayName = name
        self.filename = filename
        guard canonicalData.count <= 4_096 else { throw ReaderError.invalidEvent }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Swift String equality folds canonically equivalent spellings; this wire deliberately preserves them.
        guard lhs.displayName.utf8.elementsEqual(rhs.displayName.utf8) else { return false }
        switch (lhs.filename, rhs.filename) {
        case (nil, nil): return true
        case (let left?, let right?): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case displayName = "display_name", filename }

    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: DescriptorField.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw ReaderError.corruptData
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let name = try values.decode(String.self, forKey: .displayName)
        // An absent filename and an explicit null are different on this wire.
        let filename = try values.contains(.filename) ? values.decode(String.self, forKey: .filename) : nil
        try self.init(displayName: name, filename: filename)
        guard displayName.utf8.elementsEqual(name.utf8) else { throw ReaderError.corruptData }
    }

    /// Canonical format 1 JSON: fixed key order, literal Unicode, quotes/backslashes escaped, no whitespace.
    /// Constructing these bytes explicitly avoids serializer differences for non-ASCII and slash escaping.
    var canonicalData: Data {
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let optional = filename.map { ",\"filename\":" + quoted($0) } ?? ""
        return Data(("{\"display_name\":" + quoted(displayName) + optional + "}").utf8)
    }

    private static func normalizeName(_ value: String) throws -> String {
        var result = String.UnicodeScalarView()
        var space = false, count = 0
        for scalar in value.unicodeScalars {
            if isWhitespace(scalar.value) { space = !result.isEmpty }
            else {
                count += space ? 2 : 1
                guard count <= 500 else { throw ReaderError.invalidEvent }
                if space { result.append(" ") }
                result.append(scalar)
                space = false
            }
        }
        return String(result)
    }

    private static func validText(_ value: String, scalars: Int, bytes: Int) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= scalars && value.utf8.count <= bytes
            && value.unicodeScalars.allSatisfy { $0.value > 0x1f && !(0x7f...0x9f).contains($0.value) }
    }

    /// Frozen table, independent of locale or the system's Unicode version.
    private static func isWhitespace(_ scalar: UInt32) -> Bool {
        (0x09...0x0d).contains(scalar) || scalar == 0x20 || scalar == 0x85 || scalar == 0xa0
            || scalar == 0x1680 || (0x2000...0x200a).contains(scalar) || (0x2028...0x2029).contains(scalar)
            || scalar == 0x202f || scalar == 0x205f || scalar == 0x3000
    }
}

/// An immutable mutation envelope. Persist these exact bytes before sending, then reuse it for a retry.
/// Descriptor errors must be isolated from library synchronization; retain opaque references/ciphertext on failure.
public struct LibraryDescriptorEnvelope: Codable, Equatable, Sendable {
    public let descriptorID: UUID
    public let revision: Int
    public let mutationID: UUID
    public let deviceID: UUID
    public let epoch: Int
    public let format: Int
    public let ciphertext: Data
    public let sha256: Data

    public init(descriptorID: UUID, revision: Int, mutationID: UUID, deviceID: UUID, epoch: Int, format: Int = 1,
                ciphertext: Data, sha256: Data) throws {
        guard format == 1 else { throw ReaderError.unsupportedFormat }
        guard (1...Int(Int32.max)).contains(revision), (1...Int(Int32.max)).contains(epoch),
              (28...4_124).contains(ciphertext.count), sha256.count == 32,
              Data(SHA256.hash(data: ciphertext)) == sha256 else { throw ReaderError.corruptData }
        self.descriptorID = descriptorID; self.revision = revision; self.mutationID = mutationID
        self.deviceID = deviceID; self.epoch = epoch; self.format = format
        self.ciphertext = ciphertext; self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case descriptorID = "descriptor_id", revision, mutationID = "mutation_id", deviceID = "device_id"
        case epoch, format, ciphertext, sha256
    }

    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: DescriptorField.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw ReaderError.corruptData
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func id(_ key: CodingKeys) throws -> UUID {
            let text = try values.decode(String.self, forKey: key)
            guard let id = UUID(uuidString: text), id.wire == text else { throw ReaderError.corruptData }
            return id
        }
        let encoded = try values.decode(String.self, forKey: .ciphertext)
        let digest = try values.decode(String.self, forKey: .sha256)
        guard encoded.utf8.count <= 5_500, let bytes = Data(base64Encoded: encoded),
              bytes.base64EncodedString() == encoded, digest.utf8.count == 64,
              digest.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }),
              let sha256 = Data(hex: digest) else { throw ReaderError.corruptData }
        try self.init(descriptorID: id(.descriptorID), revision: values.decode(Int.self, forKey: .revision),
                      mutationID: id(.mutationID), deviceID: id(.deviceID), epoch: values.decode(Int.self, forKey: .epoch),
                      format: values.decode(Int.self, forKey: .format), ciphertext: bytes, sha256: sha256)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(descriptorID.wire, forKey: .descriptorID)
        try values.encode(revision, forKey: .revision)
        try values.encode(mutationID.wire, forKey: .mutationID)
        try values.encode(deviceID.wire, forKey: .deviceID)
        try values.encode(epoch, forKey: .epoch)
        try values.encode(format, forKey: .format)
        try values.encode(ciphertext.base64EncodedString(), forKey: .ciphertext)
        try values.encode(sha256.hex, forKey: .sha256)
    }
}

public enum LibraryDescriptorCrypto {
    public static func seal(_ payload: LibraryDescriptorPayload, accountID: UUID, sourceID: String, descriptorID: UUID,
                            revision: Int, mutationID: UUID, deviceID: UUID, keys: KeyBundle) throws -> LibraryDescriptorEnvelope {
        try seal(payload, accountID: accountID, sourceID: sourceID, descriptorID: descriptorID, revision: revision,
                 mutationID: mutationID, deviceID: deviceID, keys: keys, nonce: AES.GCM.Nonce())
    }

    // Internal only: fixed nonces are for the independent cross-client test vector, never a production caller.
    static func seal(_ payload: LibraryDescriptorPayload, accountID: UUID, sourceID: String, descriptorID: UUID,
                     revision: Int, mutationID: UUID, deviceID: UUID, keys: KeyBundle,
                     nonce: AES.GCM.Nonce) throws -> LibraryDescriptorEnvelope {
        try keys.validate(accountID: accountID)
        let aad = try aad(accountID: accountID, sourceID: sourceID, descriptorID: descriptorID, revision: revision,
                          mutationID: mutationID, deviceID: deviceID, epoch: keys.epoch)
        let sealed = try AES.GCM.seal(payload.canonicalData, using: key(keys, epoch: keys.epoch), nonce: nonce, authenticating: aad)
        guard let bytes = sealed.combined else { throw ReaderError.corruptData }
        return try LibraryDescriptorEnvelope(descriptorID: descriptorID, revision: revision, mutationID: mutationID,
            deviceID: deviceID, epoch: keys.epoch, ciphertext: bytes, sha256: Data(SHA256.hash(data: bytes)))
    }

    public static func open(_ envelope: LibraryDescriptorEnvelope, accountID: UUID, sourceID: String,
                            keys: KeyBundle) throws -> LibraryDescriptorPayload {
        try keys.validate(accountID: accountID)
        let aad = try aad(accountID: accountID, sourceID: sourceID, descriptorID: envelope.descriptorID,
                          revision: envelope.revision, mutationID: envelope.mutationID, deviceID: envelope.deviceID, epoch: envelope.epoch)
        let key = try key(keys, epoch: envelope.epoch)
        do {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key, authenticating: aad)
            guard bytes.count <= 4_096, String(data: bytes, encoding: .utf8) != nil else { throw ReaderError.corruptData }
            let payload = try JSONDecoder().decode(LibraryDescriptorPayload.self, from: bytes)
            guard payload.canonicalData == bytes else { throw ReaderError.corruptData }
            return payload
        } catch { throw ReaderError.corruptData }
    }

    static func key(_ keys: KeyBundle, epoch: Int) throws -> SymmetricKey {
        try HKDF<SHA256>.deriveKey(inputKeyMaterial: keys.key(for: epoch), salt: Data(keys.accountID.wire.utf8),
                                 info: Data("science-reader/library-descriptor/key/v1".utf8), outputByteCount: 32)
    }

    static func aad(accountID: UUID, sourceID: String, descriptorID: UUID, revision: Int, mutationID: UUID,
                    deviceID: UUID, epoch: Int) throws -> Data {
        guard (1...128).contains(sourceID.utf8.count), sourceID.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              (1...Int(Int32.max)).contains(revision), (1...Int(Int32.max)).contains(epoch) else { throw ReaderError.invalidEvent }
        return Data(("science-reader/library-descriptor/v1\n\(accountID.wire)\n\(sourceID)\n\(descriptorID.wire)\n"
            + "\(revision)\n\(mutationID.wire)\n\(deviceID.wire)\n\(epoch)\n1\n").utf8)
    }
}

private struct DescriptorField: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

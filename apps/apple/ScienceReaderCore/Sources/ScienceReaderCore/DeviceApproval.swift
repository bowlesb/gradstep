import CryptoKit
import Foundation

// QR device approval (docs/architecture/PRIVACY_AND_SYNC.md#approving-a-new-device-qr): a new device shows a payload
// that commits to its exact enrollment fingerprint; an approved device scans it, refuses any server request whose
// key material doesn't hash to that fingerprint, and wraps the key bundle for that recipient with the existing device
// envelope (ENCRYPTED_WIRE_FORMAT.md). The web port is apps/web/src/lib/approval.ts; both are checked against
// Tests/ScienceReaderCoreTests/Fixtures/device-approval-v1.json.

/// What kind of device is asking, as the new device declares it in its QR payload (display only).
public enum DeviceKind: String, Sendable, CaseIterable {
    case browser = "w", mac = "m", iPhone = "p", iPad = "t"

    public var name: String {
        switch self {
        case .browser: "Web browser"
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        }
    }
}

public enum DeviceApprovalError: Error, Equatable, Sendable {
    /// Not a Gradstep approval code, or a version this build doesn't know.
    case unrecognized
    /// The code was made for another account.
    case differentAccount
    /// The server lists no unexpired, unapproved request with this identity (expired, already used, or never sent).
    case expiredOrUsed
    /// The server's request doesn't hash to the scanned fingerprint. Never approve: this is a substituted key.
    case keyMismatch
}

/// The QR text: `GSDA1.<request id>.<account tag>.<fingerprint>.<kind>`, binary fields as unpadded base64url
/// (16, 16 and 32 bytes). 97 ASCII characters.
public struct DeviceApprovalPayload: Equatable, Sendable {
    public static let version = "GSDA1"
    public let requestID: UUID
    public let accountTag: Data
    public let fingerprint: Data
    public let kind: DeviceKind

    public init(requestID: UUID, accountTag: Data, fingerprint: Data, kind: DeviceKind) throws {
        guard accountTag.count == 16, fingerprint.count == 32 else { throw DeviceApprovalError.unrecognized }
        self.requestID = requestID; self.accountTag = accountTag; self.fingerprint = fingerprint; self.kind = kind
    }

    public init(requestID: UUID, accountID: UUID, deviceID: UUID, publicKey: Data, challenge: Data, kind: DeviceKind) throws {
        try self.init(requestID: requestID, accountTag: DeviceApproval.accountTag(accountID),
                      fingerprint: DeviceApproval.fingerprint(accountID: accountID, deviceID: deviceID, publicKey: publicKey, challenge: challenge),
                      kind: kind)
    }

    /// Strict: exactly five fields, canonical base64url of the exact lengths, a known kind.
    public init(scanned text: String) throws {
        guard text.utf8.count <= 128 else { throw DeviceApprovalError.unrecognized }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == Self.version,
              let id = Base64URL.decode(parts[1], count: 16), let tag = Base64URL.decode(parts[2], count: 16),
              let fingerprint = Base64URL.decode(parts[3], count: 32), let kind = DeviceKind(rawValue: parts[4]) else {
            throw DeviceApprovalError.unrecognized
        }
        let uuid = id.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        try self.init(requestID: uuid, accountTag: tag, fingerprint: fingerprint, kind: kind)
    }

    public var encoded: String {
        let id = withUnsafeBytes(of: requestID.uuid) { Data($0) }
        return [Self.version, Base64URL.encode(id), Base64URL.encode(accountTag), Base64URL.encode(fingerprint), kind.rawValue]
            .joined(separator: ".")
    }

    public var comparisonCode: String { DeviceApproval.comparisonCode(fingerprint: fingerprint) }
}

/// One row of `v1_enrollment_requests()` (the server returns only unexpired, unapproved rows).
public struct EnrollmentRequestRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let deviceID: UUID
    public let publicKey: Data
    public let challenge: Data

    public init(id: UUID, deviceID: UUID, publicKey: Data, challenge: Data) {
        self.id = id; self.deviceID = deviceID; self.publicKey = publicKey; self.challenge = challenge
    }

    public func fingerprint(accountID: UUID) throws -> Data {
        try DeviceApproval.fingerprint(accountID: accountID, deviceID: deviceID, publicKey: publicKey, challenge: challenge)
    }

    /// The six digits the new device shows for this exact recipient.
    public func comparisonCode(accountID: UUID) throws -> String {
        DeviceApproval.comparisonCode(fingerprint: try fingerprint(accountID: accountID))
    }
}

public enum DeviceApproval {
    /// 16 bytes identifying the account without putting its ID on screen.
    public static func accountTag(_ accountID: UUID) -> Data {
        Data(SHA256.hash(data: Data("science-reader/device-approval/v1/account/\(accountID.wire)".utf8)).prefix(16))
    }

    /// The enrollment comparison fingerprint (ENCRYPTED_WIRE_FORMAT.md): account, recipient device, public key and
    /// challenge — everything the device envelope binds.
    public static func fingerprint(accountID: UUID, deviceID: UUID, publicKey: Data, challenge: Data) throws -> Data {
        guard publicKey.count == 32, challenge.count == 32 else { throw ReaderError.invalidKey }
        return Data(SHA256.hash(data: Data("science-reader/enrollment/v1/\(accountID.wire)/\(deviceID.wire)/".utf8) + publicKey + challenge))
    }

    /// Six decimal digits from a domain-separated hash of the fingerprint. A short check for people, not a key:
    /// the QR carries the full fingerprint.
    public static func comparisonCode(fingerprint: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("science-reader/device-approval/v1/code/".utf8) + fingerprint))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(value)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// "123 456", for reading aloud and comparing.
    public static func display(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    /// Picks the server request the scanned payload names and proves it is the scanned recipient. A renewed request
    /// (new ID, same recipient) still matches by fingerprint. Any request with the scanned ID but other key material is
    /// refused outright.
    public static func match(_ payload: DeviceApprovalPayload, accountID: UUID,
                             requests: [EnrollmentRequestRecord]) throws -> EnrollmentRequestRecord {
        guard payload.accountTag == accountTag(accountID) else { throw DeviceApprovalError.differentAccount }
        if let named = requests.first(where: { $0.id == payload.requestID }) {
            guard (try? named.fingerprint(accountID: accountID)) == payload.fingerprint else { throw DeviceApprovalError.keyMismatch }
            return named
        }
        if let renewed = requests.first(where: { (try? $0.fingerprint(accountID: accountID)) == payload.fingerprint }) { return renewed }
        throw DeviceApprovalError.expiredOrUsed
    }

    /// The approval envelope: the existing device envelope for exactly this request's recipient.
    public static func envelope(for request: EnrollmentRequestRecord, keys: KeyBundle) throws -> Data {
        try ReaderCrypto.wrapForDevice(keys, deviceID: request.deviceID, recipientPublicKey: request.publicKey, challenge: request.challenge)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Canonical, unpadded, exact length only (re-encoding must reproduce the text).
    static func decode(_ text: String, count: Int) -> Data? {
        guard text.count == (count * 4 + 2) / 3,
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), data.count == count, encode(data) == text else { return nil }
        return data
    }
}

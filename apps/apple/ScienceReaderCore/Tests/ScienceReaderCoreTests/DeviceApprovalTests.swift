import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

/// QR device approval: payload encoding, the comparison code, and what the approving device refuses.
/// The fixture is computed independently in Node (scripts/check-wire.mjs) and also checked by the web tests.
@Suite struct DeviceApprovalTests {
    struct Fixture: Decodable {
        let accountID: UUID, deviceID: UUID, requestID: UUID
        let publicKey: Data, challenge: Data
        let kind: String, accountTag: String, fingerprint: String, code: String, payload: String
        let codeVectors: [String: String]
    }
    let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "device-approval-v1", withExtension: "json")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()
    var request: EnrollmentRequestRecord {
        EnrollmentRequestRecord(id: fixture.requestID, deviceID: fixture.deviceID, publicKey: fixture.publicKey, challenge: fixture.challenge)
    }

    @Test func encodesTheFixturePayloadAndCodeExactly() throws {
        let payload = try DeviceApprovalPayload(requestID: fixture.requestID, accountID: fixture.accountID, deviceID: fixture.deviceID,
                                                publicKey: fixture.publicKey, challenge: fixture.challenge, kind: .browser)
        #expect(payload.encoded == fixture.payload)
        #expect(payload.encoded.count == 97)
        #expect(payload.fingerprint.hex == fixture.fingerprint)
        #expect(Base64URL.encode(payload.accountTag) == fixture.accountTag)
        #expect(payload.comparisonCode == fixture.code)
        #expect(try request.comparisonCode(accountID: fixture.accountID) == fixture.code)
        // The existing documented enrollment fingerprint is the same bytes.
        #expect(try ReaderCrypto.enrollmentFingerprint(accountID: fixture.accountID, deviceID: fixture.deviceID,
                                                       publicKey: fixture.publicKey, challenge: fixture.challenge) == fixture.fingerprint)
        for (hex, code) in fixture.codeVectors { #expect(DeviceApproval.comparisonCode(fingerprint: Data(hex: hex)!) == code) }
        #expect(DeviceApproval.display("016434") == "016 434")
        #expect(try DeviceApprovalPayload(scanned: fixture.payload) == payload)
    }

    @Test func parsingIsStrict() throws {
        let good = fixture.payload
        var parts = good.split(separator: ".").map(String.init)
        let rejected = [
            "", "https://app.gradstep.ai", good + ".", good + "\n", " " + good, good.replacingOccurrences(of: "GSDA1", with: "GSDA2"),
            good.replacingOccurrences(of: ".w", with: ".x"),
            { var p = parts; p[3] = String(p[3].dropLast()); return p.joined(separator: ".") }(),     // short fingerprint
            { var p = parts; p[1] += "A"; return p.joined(separator: ".") }(),                         // long request ID
            { var p = parts; p[3] = p[3].replacingOccurrences(of: "_", with: "/"); return p.joined(separator: ".") }(), // standard base64
            { var p = parts; p[1] = String(p[1].dropLast()) + "B"; return p.joined(separator: ".") }(), // non-canonical last char
            String(repeating: "A", count: 4096),
        ]
        for text in rejected { #expect(throws: DeviceApprovalError.unrecognized) { try DeviceApprovalPayload(scanned: text) } }
        parts[4] = "t"
        #expect(try DeviceApprovalPayload(scanned: parts.joined(separator: ".")).kind == .iPad)
    }

    @Test func matchesTheScannedRecipientAndRefusesSubstitutes() throws {
        let payload = try DeviceApprovalPayload(scanned: fixture.payload)
        let other = EnrollmentRequestRecord(id: UUID(), deviceID: UUID(), publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                            challenge: ReaderCrypto.randomKey())
        #expect(try DeviceApproval.match(payload, accountID: fixture.accountID, requests: [other, request]) == request)

        // The server names the scanned request but carries another key, challenge or device: refuse.
        let swappedKey = EnrollmentRequestRecord(id: request.id, deviceID: request.deviceID, publicKey: other.publicKey, challenge: request.challenge)
        let swappedChallenge = EnrollmentRequestRecord(id: request.id, deviceID: request.deviceID, publicKey: request.publicKey, challenge: other.challenge)
        let swappedDevice = EnrollmentRequestRecord(id: request.id, deviceID: other.deviceID, publicKey: request.publicKey, challenge: request.challenge)
        for swapped in [swappedKey, swappedChallenge, swappedDevice] {
            #expect(throws: DeviceApprovalError.keyMismatch) {
                try DeviceApproval.match(payload, accountID: fixture.accountID, requests: [swapped, request])
            }
        }
        // A different account's code is named as such, before any request is considered.
        #expect(throws: DeviceApprovalError.differentAccount) { try DeviceApproval.match(payload, accountID: UUID(), requests: [request]) }
        // Expired or approved requests are absent from the server's list (it is authoritative; no local clock).
        #expect(throws: DeviceApprovalError.expiredOrUsed) { try DeviceApproval.match(payload, accountID: fixture.accountID, requests: [other]) }
        #expect(throws: DeviceApprovalError.expiredOrUsed) { try DeviceApproval.match(payload, accountID: fixture.accountID, requests: []) }
        // A renewal keeps the recipient under a new request ID; it still matches by fingerprint.
        let renewed = EnrollmentRequestRecord(id: UUID(), deviceID: request.deviceID, publicKey: request.publicKey, challenge: request.challenge)
        #expect(try DeviceApproval.match(payload, accountID: fixture.accountID, requests: [other, renewed]) == renewed)
    }

    @Test func approvalEnvelopeOpensOnlyForTheScannedRecipient() throws {
        let account = UUID(), device = UUID(), recipient = Curve25519.KeyAgreement.PrivateKey(), challenge = ReaderCrypto.randomKey()
        let request = EnrollmentRequestRecord(id: UUID(), deviceID: device, publicKey: recipient.publicKey.rawRepresentation, challenge: challenge)
        let payload = try DeviceApprovalPayload(requestID: request.id, accountID: account, deviceID: device,
                                                publicKey: request.publicKey, challenge: challenge, kind: .mac)
        let keys = KeyBundle.generate(accountID: account)
        let matched = try DeviceApproval.match(try DeviceApprovalPayload(scanned: payload.encoded), accountID: account, requests: [request])
        let envelope = try DeviceApproval.envelope(for: matched, keys: keys)
        #expect(try ReaderCrypto.unwrapForDevice(envelope, accountID: account, deviceID: device, epoch: 1, privateKey: recipient, challenge: challenge) == keys)
        #expect(throws: (any Error).self) {
            try ReaderCrypto.unwrapForDevice(envelope, accountID: account, deviceID: device, epoch: 1, privateKey: .init(), challenge: challenge)
        }
    }
}

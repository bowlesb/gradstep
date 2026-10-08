import CryptoKit
import Foundation
import ScienceReaderCore

struct Fixture: Decodable {
    let keys: KeyBundle
    let payload: PrivateEvent
    let eventID: UUID
    let deviceID: UUID
    let challenge: Data
    let privateKey: Data
    let recoveryCode: String
    let eventCiphertext: Data
    let recoveryPackage: Data
    let deviceEnvelope: Data
    /// Optional QR approval check: a recipient (e.g. a WebCrypto key) as its QR payload and server request name it.
    let approval: Approval?
}
struct Approval: Decodable {
    let payload: String
    let requestID: UUID
    let deviceID: UUID
    let publicKey: Data
    let challenge: Data
}
struct ApprovalOutput: Encodable {
    let code: String
    let envelope: Data
    let refusedSubstitute: Bool
}
struct Output: Encodable {
    let eventCiphertext: Data
    let recoveryPackage: Data
    let deviceEnvelope: Data
    let fingerprint: String
    let approval: ApprovalOutput?
}
let data = FileHandle.standardInput.readDataToEndOfFile()
guard data.count < 65_536 else { throw ReaderError.invalidEvent }
let input = try JSONDecoder().decode(Fixture.self, from: data)
// This executable accepts only the public test account; it is not a user-key tool.
guard input.keys.accountID.wire == "11111111-2222-4333-8444-555555555555" else { throw ReaderError.wrongAccount }
let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: input.privateKey)
let event = EventEnvelope(id: input.eventID, deviceID: input.deviceID, epoch: input.keys.epoch, ciphertext: input.eventCiphertext)
guard try ReaderCrypto.open(event, keys: input.keys) == input.payload,
      try ReaderCrypto.recover(input.recoveryPackage, code: input.recoveryCode, accountID: input.keys.accountID) == input.keys,
      try ReaderCrypto.unwrapForDevice(input.deviceEnvelope, accountID: input.keys.accountID, deviceID: input.deviceID,
          epoch: input.keys.epoch, privateKey: recipient, challenge: input.challenge) == input.keys else { throw ReaderError.corruptData }
// Approve exactly as the app does: parse the scanned text, match it against the server's request, wrap for it.
let approval = try input.approval.map { approval -> ApprovalOutput in
    let payload = try DeviceApprovalPayload(scanned: approval.payload)
    let request = EnrollmentRequestRecord(id: approval.requestID, deviceID: approval.deviceID, publicKey: approval.publicKey, challenge: approval.challenge)
    let matched = try DeviceApproval.match(payload, accountID: input.keys.accountID, requests: [request])
    // The same request carrying another key must be refused.
    let substitute = EnrollmentRequestRecord(id: approval.requestID, deviceID: approval.deviceID,
        publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, challenge: approval.challenge)
    let refused = (try? DeviceApproval.match(payload, accountID: input.keys.accountID, requests: [substitute])) == nil
    return ApprovalOutput(code: try matched.comparisonCode(accountID: input.keys.accountID),
                          envelope: try DeviceApproval.envelope(for: matched, keys: input.keys), refusedSubstitute: refused)
}
let output = Output(eventCiphertext: try ReaderCrypto.seal(input.payload, id: input.eventID, deviceID: input.deviceID, keys: input.keys).ciphertext,
    recoveryPackage: try ReaderCrypto.wrapRecovery(input.keys, code: input.recoveryCode),
    deviceEnvelope: try ReaderCrypto.wrapForDevice(input.keys, deviceID: input.deviceID, recipientPublicKey: recipient.publicKey.rawRepresentation, challenge: input.challenge),
    fingerprint: try ReaderCrypto.enrollmentFingerprint(accountID: input.keys.accountID, deviceID: input.deviceID, publicKey: recipient.publicKey.rawRepresentation, challenge: input.challenge),
    approval: approval)
FileHandle.standardOutput.write(try ReaderCrypto.encode(output))

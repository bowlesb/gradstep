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
}
struct Output: Encodable {
    let eventCiphertext: Data
    let recoveryPackage: Data
    let deviceEnvelope: Data
    let fingerprint: String
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
let output = Output(eventCiphertext: try ReaderCrypto.seal(input.payload, id: input.eventID, deviceID: input.deviceID, keys: input.keys).ciphertext,
    recoveryPackage: try ReaderCrypto.wrapRecovery(input.keys, code: input.recoveryCode),
    deviceEnvelope: try ReaderCrypto.wrapForDevice(input.keys, deviceID: input.deviceID, recipientPublicKey: recipient.publicKey.rawRepresentation, challenge: input.challenge),
    fingerprint: try ReaderCrypto.enrollmentFingerprint(accountID: input.keys.accountID, deviceID: input.deviceID, publicKey: recipient.publicKey.rawRepresentation, challenge: input.challenge))
FileHandle.standardOutput.write(try ReaderCrypto.encode(output))

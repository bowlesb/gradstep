import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct WireTests {
    private struct Fixture: Decodable {
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

    @Test func nodeGeneratedFullEnvelopesAreReadableInSwift() throws {
        let url = try #require(Bundle.module.url(forResource: "envelopes-v1", withExtension: "json"))
        let input = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let envelope = EventEnvelope(id: input.eventID, deviceID: input.deviceID, epoch: 1, ciphertext: input.eventCiphertext)
        #expect(try ReaderCrypto.open(envelope, keys: input.keys) == input.payload)
        #expect(try ReaderCrypto.recover(input.recoveryPackage, code: input.recoveryCode, accountID: input.keys.accountID) == input.keys)
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: input.privateKey)
        #expect(try ReaderCrypto.unwrapForDevice(input.deviceEnvelope, accountID: input.keys.accountID, deviceID: input.deviceID,
            epoch: 1, privateKey: recipient, challenge: input.challenge) == input.keys)
        var challenge = input.challenge; challenge[0] ^= 1
        #expect(throws: (any Error).self) { try ReaderCrypto.unwrapForDevice(input.deviceEnvelope, accountID: input.keys.accountID,
            deviceID: input.deviceID, epoch: 1, privateKey: recipient, challenge: challenge) }
    }
}

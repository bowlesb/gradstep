import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct CryptoTests {
    let account = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let device = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func encryptionAuthenticatesIdentityAndDetectsTampering() throws {
        let keys = KeyBundle.generate(accountID: account)
        let payload = PrivateEvent(kind: .note, text: "A private passage about attention.")
        let encrypted = try ReaderCrypto.seal(payload, id: UUID(), deviceID: device, keys: keys)
        #expect(try ReaderCrypto.open(encrypted, keys: keys) == payload)
        let second = try ReaderCrypto.seal(payload, id: encrypted.id, deviceID: device, keys: keys)
        #expect(second.ciphertext != encrypted.ciphertext)
        #expect(throws: (any Error).self) {
            try ReaderCrypto.open(EventEnvelope(id: UUID(), deviceID: device, epoch: 1, ciphertext: encrypted.ciphertext), keys: keys)
        }
        #expect(throws: (any Error).self) {
            try ReaderCrypto.open(EventEnvelope(id: encrypted.id, deviceID: UUID(), epoch: 1, ciphertext: encrypted.ciphertext), keys: keys)
        }
        var corrupt = encrypted.ciphertext; corrupt[corrupt.count-1] ^= 1
        #expect(throws: (any Error).self) {
            try ReaderCrypto.open(EventEnvelope(id: encrypted.id, deviceID: device, epoch: 1, ciphertext: corrupt), keys: keys)
        }
        #expect(throws: ReaderError.unsupportedFormat) {
            try ReaderCrypto.open(EventEnvelope(id: encrypted.id, deviceID: device, epoch: 1, format: 2, ciphertext: encrypted.ciphertext), keys: keys)
        }
    }

    @Test func recoveryRequiresCodeAndCorrectAccount() throws {
        let keys = KeyBundle.generate(accountID: account)
        let code = ReaderCrypto.recoveryCode()
        let wrapped = try ReaderCrypto.wrapRecovery(keys, code: code)
        #expect(try ReaderCrypto.recover(wrapped, code: code.uppercased(), accountID: account) == keys)
        #expect(throws: (any Error).self) { try ReaderCrypto.recover(wrapped, code: ReaderCrypto.recoveryCode(), accountID: account) }
        #expect(throws: (any Error).self) { try ReaderCrypto.recover(wrapped, code: code, accountID: UUID()) }
        #expect(throws: ReaderError.invalidRecoveryCode) { try ReaderCrypto.recover(wrapped, code: "a password", accountID: account) }
    }

    @Test func enrollmentBindsRecipientChallengeAndEpoch() throws {
        let keys = KeyBundle.generate(accountID: account)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let challenge = ReaderCrypto.randomKey()
        let wrapped = try ReaderCrypto.wrapForDevice(keys, deviceID: device, recipientPublicKey: privateKey.publicKey.rawRepresentation, challenge: challenge)
        #expect(try ReaderCrypto.unwrapForDevice(wrapped, accountID: account, deviceID: device, epoch: 1, privateKey: privateKey, challenge: challenge) == keys)
        #expect(throws: (any Error).self) {
            try ReaderCrypto.unwrapForDevice(wrapped, accountID: account, deviceID: device, epoch: 1, privateKey: .init(), challenge: challenge)
        }
        #expect(throws: (any Error).self) {
            try ReaderCrypto.unwrapForDevice(wrapped, accountID: account, deviceID: device, epoch: 1, privateKey: privateKey, challenge: ReaderCrypto.randomKey())
        }
        #expect(throws: (any Error).self) {
            try ReaderCrypto.unwrapForDevice(wrapped, accountID: account, deviceID: device, epoch: 2, privateKey: privateKey, challenge: challenge)
        }
    }

    @Test func rotationRetainsHistoryAndReplacesWriteAuthority() throws {
        var keys = KeyBundle.generate(accountID: account)
        let prior = keys
        let payload = PrivateEvent(kind: .note, text: "Old encrypted history")
        let event = try ReaderCrypto.seal(payload, id: UUID(), deviceID: device, keys: keys)
        try keys.rotate()
        #expect(keys.epoch == 2)
        #expect(keys.managementToken != prior.managementToken)
        #expect(try ReaderCrypto.open(event, keys: keys) == payload)
        let future = try ReaderCrypto.seal(payload, id: UUID(), deviceID: device, keys: keys)
        #expect(throws: ReaderError.missingKey) { try ReaderCrypto.open(future, keys: prior) }
    }

    @Test func nodeAESGCMKnownAnswer() throws {
        // Independently generated with Node 24 createCipheriv('aes-256-gcm').
        // Empty AAD for this primitive vector. Identity AAD is tested above.
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
        let sealed = try AES.GCM.seal(Data(repeating: 0, count: 16), using: key, nonce: nonce)
        #expect(sealed.ciphertext.hex == "cea7403d4d606b6e074ec5d3baf39d18")
        #expect(sealed.tag.hex == "d0d1c8a799996bf0265b98b5d48ab919")
    }
}

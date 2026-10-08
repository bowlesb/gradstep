import CryptoKit
import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct LibraryDescriptorTests {
    private struct Vector: Decodable {
        let content_key_hex: String
        let derived_key_hex: String
        let nonce_hex: String
        let account_id: UUID
        let source_id: String
        let plaintext: LibraryDescriptorPayload
        let plaintext_utf8: String
        let aad_utf8: String
        let envelope: LibraryDescriptorEnvelope
        let additional_vectors: [Additional]
        struct Additional: Decodable {
            let plaintext: LibraryDescriptorPayload
            let plaintext_utf8: String
            let nonce_hex: String
            let ciphertext: String
            let sha256: String
        }
        var keys: KeyBundle {
            KeyBundle(accountID: account_id, epoch: envelope.epoch,
                      contentKeys: [String(envelope.epoch): Data(hex: content_key_hex)!], managementToken: Data(repeating: 4, count: 32))
        }
    }

    private func vector() throws -> Vector {
        // One frozen shared file, also consumed by Node/WebCrypto. Never copy or regenerate it in a client test.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: root.appendingPathComponent("tests/fixtures/library-descriptor/v1.json")))
    }

    private func seal(_ payload: LibraryDescriptorPayload, vector: Vector, nonce: String? = nil,
                      keys: KeyBundle? = nil) throws -> LibraryDescriptorEnvelope {
        let e = vector.envelope
        if let nonce {
            return try LibraryDescriptorCrypto.seal(payload, accountID: vector.account_id, sourceID: vector.source_id,
                descriptorID: e.descriptorID, revision: e.revision, mutationID: e.mutationID, deviceID: e.deviceID,
                keys: keys ?? vector.keys, nonce: AES.GCM.Nonce(data: Data(hex: nonce)!))
        }
        return try LibraryDescriptorCrypto.seal(payload, accountID: vector.account_id, sourceID: vector.source_id,
            descriptorID: e.descriptorID, revision: e.revision, mutationID: e.mutationID, deviceID: e.deviceID, keys: keys ?? vector.keys)
    }

    private func open(_ envelope: LibraryDescriptorEnvelope, vector: Vector, keys: KeyBundle? = nil) throws -> LibraryDescriptorPayload {
        try LibraryDescriptorCrypto.open(envelope, accountID: vector.account_id, sourceID: vector.source_id, keys: keys ?? vector.keys)
    }

    private func aad(_ v: Vector) throws -> Data {
        let e = v.envelope
        return try LibraryDescriptorCrypto.aad(accountID: v.account_id, sourceID: v.source_id, descriptorID: e.descriptorID,
            revision: e.revision, mutationID: e.mutationID, deviceID: e.deviceID, epoch: e.epoch)
    }

    private func envelope(bytes: Data, like e: LibraryDescriptorEnvelope, descriptorID: UUID? = nil,
                          revision: Int? = nil, mutationID: UUID? = nil, deviceID: UUID? = nil, epoch: Int? = nil) throws -> LibraryDescriptorEnvelope {
        try LibraryDescriptorEnvelope(descriptorID: descriptorID ?? e.descriptorID, revision: revision ?? e.revision,
            mutationID: mutationID ?? e.mutationID, deviceID: deviceID ?? e.deviceID, epoch: epoch ?? e.epoch,
            ciphertext: bytes, sha256: Data(SHA256.hash(data: bytes)))
    }

    @Test func frozenNodeVectorsReproduceExactlyAndDecrypt() throws {
        let v = try vector()
        #expect(try LibraryDescriptorCrypto.key(v.keys, epoch: v.envelope.epoch).withUnsafeBytes { Data($0).hex } == v.derived_key_hex)
        #expect(try aad(v) == Data(v.aad_utf8.utf8))
        #expect(v.plaintext.canonicalData == Data(v.plaintext_utf8.utf8))
        #expect(try seal(v.plaintext, vector: v, nonce: v.nonce_hex) == v.envelope)
        #expect(try open(v.envelope, vector: v) == v.plaintext)
        for other in v.additional_vectors {
            #expect(other.plaintext.canonicalData == Data(other.plaintext_utf8.utf8))
            let sealed = try seal(other.plaintext, vector: v, nonce: other.nonce_hex)
            #expect(sealed.ciphertext.base64EncodedString() == other.ciphertext)
            #expect(sealed.sha256.hex == other.sha256)
            #expect(try open(sealed, vector: v) == other.plaintext)
        }
    }

    @Test func everyIdentityFieldAndCiphertextSectionAreAuthenticated() throws {
        let v = try vector(), e = v.envelope
        var keys = v.keys
        keys.epoch += 1
        keys.contentKeys[String(keys.epoch)] = keys.contentKeys[String(e.epoch)]
        let changed = [try envelope(bytes: e.ciphertext, like: e, descriptorID: UUID()),
                       try envelope(bytes: e.ciphertext, like: e, revision: e.revision + 1),
                       try envelope(bytes: e.ciphertext, like: e, mutationID: UUID()),
                       try envelope(bytes: e.ciphertext, like: e, deviceID: UUID()),
                       try envelope(bytes: e.ciphertext, like: e, epoch: e.epoch + 1)]
        for edited in changed { #expect(throws: ReaderError.corruptData) { try open(edited, vector: v, keys: keys) } }
        #expect(throws: ReaderError.corruptData) {
            try LibraryDescriptorCrypto.open(e, accountID: v.account_id, sourceID: "upload:66666666-6666-4666-8666-666666666666", keys: v.keys)
        }
        #expect(throws: ReaderError.wrongAccount) { try LibraryDescriptorCrypto.open(e, accountID: UUID(), sourceID: v.source_id, keys: v.keys) }
        let otherKeys = KeyBundle(accountID: UUID(), epoch: e.epoch, contentKeys: v.keys.contentKeys, managementToken: v.keys.managementToken)
        #expect(throws: ReaderError.corruptData) {
            try LibraryDescriptorCrypto.open(e, accountID: otherKeys.accountID, sourceID: v.source_id, keys: otherKeys)
        }
        for index in [0, 12, e.ciphertext.count - 1] {
            var bytes = e.ciphertext; bytes[index] ^= 1
            // Recompute the unkeyed digest: this assertion must exercise GCM, not just the transport checksum.
            #expect(throws: ReaderError.corruptData) { try open(envelope(bytes: bytes, like: e), vector: v) }
        }
    }

    @Test func strictWireEnvelopeRejectsAliasesAndOutOfBoundsFields() throws {
        let v = try vector()
        let encoded = try ReaderCrypto.encode(v.envelope)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(try JSONDecoder().decode(LibraryDescriptorEnvelope.self, from: encoded) == v.envelope)
        let changes: [(String, Any)] = [
            ("descriptor_id", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), ("revision", 0), ("revision", 2_147_483_648),
            ("epoch", 0), ("epoch", 1.5), ("format", 2), ("format", true), ("extra", "not allowed"),
            ("ciphertext", v.envelope.ciphertext.base64EncodedString().replacingOccurrences(of: "=", with: "")),
            ("ciphertext", "\n" + v.envelope.ciphertext.base64EncodedString()),
            ("sha256", v.envelope.sha256.hex.uppercased()), ("sha256", String(repeating: "0", count: 64)),
        ]
        for (key, value) in changes {
            var candidate = object; candidate[key] = value
            #expect(throws: (any Error).self) { try JSONDecoder().decode(LibraryDescriptorEnvelope.self, from: JSONSerialization.data(withJSONObject: candidate)) }
        }
        for key in object.keys {
            var candidate = object; candidate.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(LibraryDescriptorEnvelope.self, from: JSONSerialization.data(withJSONObject: candidate)) }
        }
        // Nonzero unused Base64 bits decode to the same bytes, but are not canonical.
        var alias = v.envelope.ciphertext.base64EncodedString(); alias.removeLast(3); alias += "h=="
        var candidate = object; candidate["ciphertext"] = alias
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LibraryDescriptorEnvelope.self, from: JSONSerialization.data(withJSONObject: candidate)) }
        for count in [27, 4_125] {
            #expect(throws: ReaderError.corruptData) { try envelope(bytes: Data(repeating: 0, count: count), like: v.envelope) }
        }
    }

    @Test func normalizationIsScalarBasedAndPreservesExactFilenameAndCombiningSpelling() throws {
        let spaces: [UInt32] = Array(0x09...0x0d) + [0x20, 0x85, 0xa0, 0x1680] + Array(0x2000...0x200a) + [0x2028, 0x2029, 0x202f, 0x205f, 0x3000]
        for scalar in spaces {
            let gap = String(Unicode.Scalar(scalar)!)
            #expect(try LibraryDescriptorPayload(displayName: gap + "A" + gap + gap + "B" + gap).displayName == "A B")
        }
        #expect(try LibraryDescriptorPayload(displayName: "\t  attention\u{a0}\u{2009}\nheads\u{3000} ").displayName == "attention heads")
        let combining = try LibraryDescriptorPayload(displayName: "Cafe\u{301}", filename: "  draft 🧠.pdf ")
        #expect(try combining != LibraryDescriptorPayload(displayName: "Café", filename: "  draft 🧠.pdf "))
        #expect(combining.filename == "  draft 🧠.pdf ")
        #expect(try LibraryDescriptorPayload(displayName: String(repeating: "🧠", count: 500)).displayName.unicodeScalars.count == 500)
        #expect(throws: ReaderError.invalidEvent) { try LibraryDescriptorPayload(displayName: String(repeating: "🧠", count: 501)) }
        #expect(throws: ReaderError.invalidEvent) { try LibraryDescriptorPayload(displayName: String(repeating: "e\u{301}", count: 251)) }
        #expect(throws: ReaderError.invalidEvent) { try LibraryDescriptorPayload(displayName: " \n\t") }
        #expect(throws: ReaderError.invalidEvent) { try LibraryDescriptorPayload(displayName: "title\u{7f}") }
        #expect(throws: ReaderError.invalidEvent) { try LibraryDescriptorPayload(displayName: "title\u{0}") }
        for filename in ["", " \u{3000}", "a\nb", "a\u{85}b", String(repeating: "🧠", count: 256)] {
            #expect(throws: ReaderError.invalidEvent) { try LibraryDescriptorPayload(displayName: "title", filename: filename) }
        }
    }

    @Test func authenticatedButNoncanonicalOrInvalidPayloadIsStillRejected() throws {
        let v = try vector()
        let invalid = [
            #"{"display_name":"A","filename":null}"#, #"{"display_name":"A","extra":1}"#,
            #"{ "display_name":"A"}"#, #"{"display_name":"A","display_name":"B"}"#,
            #"{"display_name":"\u0041"}"#, #"{"filename":"a.pdf","display_name":"A"}"#,
            #"{"display_name":" A "}"#, #"{"display_name":"A\tB"}"#,
            #"{"display_name":"\ud800"}"#, #"{"display_name":"\udfff"}"#,
            #"{"display_name":"\ud800x"}"#, #"{"display_name":"A","filename":"a\n.pdf"}"#,
            #"{"display_name":"\ud83e\udde0"}"#,
        ].map { Data($0.utf8) } + [Data([0xc0, 0xaf]), Data(repeating: 0x20, count: 4_097),
                                  Data([0xef, 0xbb, 0xbf]) + v.plaintext.canonicalData]
        for bytes in invalid {
            let sealed = try AES.GCM.seal(bytes, using: LibraryDescriptorCrypto.key(v.keys, epoch: v.envelope.epoch), authenticating: aad(v))
            let combined = try #require(sealed.combined)
            #expect(throws: ReaderError.corruptData) { try open(envelope(bytes: combined, like: v.envelope), vector: v) }
        }
        // Optional filename omitted, literal slash, and non-ASCII line separator in filename all round-trip.
        for payload in [try LibraryDescriptorPayload(displayName: "A/B"),
                        try LibraryDescriptorPayload(displayName: "A", filename: "a\u{2028}b.pdf")] {
            #expect(try open(seal(payload, vector: v), vector: v) == payload)
        }
    }

    @Test func rotationKeepsHistoricalReadsAndSealsWithFreshNonceAndCurrentEpoch() throws {
        let v = try vector()
        var keys = v.keys
        try keys.rotate()
        #expect(try open(v.envelope, vector: v, keys: keys) == v.plaintext)
        let first = try seal(v.plaintext, vector: v, keys: keys)
        let second = try seal(v.plaintext, vector: v, keys: keys)
        #expect(first.epoch == keys.epoch)
        #expect(first.ciphertext != second.ciphertext)
        #expect(try open(first, vector: v, keys: keys) == v.plaintext)
        #expect(throws: ReaderError.missingKey) { try open(first, vector: v) }
        keys.contentKeys.removeValue(forKey: String(v.envelope.epoch))
        #expect(throws: ReaderError.missingKey) { try open(v.envelope, vector: v, keys: keys) }
    }

    @Test func sourceContextRejectsWhitespaceNonASCIIAndInjection() throws {
        let v = try vector(), e = v.envelope
        for source in ["", "a b", "a\nb", "a\rb", "a\u{7f}b", "é", String(repeating: "x", count: 129)] {
            #expect(throws: ReaderError.invalidEvent) {
                try LibraryDescriptorCrypto.open(e, accountID: v.account_id, sourceID: source, keys: v.keys)
            }
        }
    }
}

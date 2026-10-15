import Foundation

/// Local transport only. Its self-reported digest is checked for integrity;
/// acquisition on this device supplies trust, never an unauthenticated upload.
public enum DeviceReaderPackage {
    private struct Payload: Codable {
        struct Member: Codable { let path: String; let base64: String }
        let manifest: String
        let manifestSHA256: String
        let members: [Member]
    }
    public static func decode(_ data: Data) throws -> VerifiedReaderBundle {
        guard data.count <= 48 * 1024 * 1024 else { throw ReaderBundleError.invalidResource }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.manifest.utf8.count <= 349_528, payload.members.count <= 512,
              let manifest = Data(base64Encoded: payload.manifest) else { throw ReaderBundleError.invalidResource }
        var members: [String: Data] = [:], total = 0
        for member in payload.members {
            guard member.base64.utf8.count <= 22_369_624, members[member.path] == nil,
                  let bytes = Data(base64Encoded: member.base64) else { throw ReaderBundleError.invalidResource }
            total += bytes.count
            guard total <= 33_554_432 else { throw ReaderBundleError.invalidResource }
            members[member.path] = bytes
        }
        let bundle = try VerifiedReaderBundle.verify(manifest: manifest, expectedSHA256: payload.manifestSHA256, members: members)
        guard bundle.arxivSource != nil || bundle.devicePDFSource?.paper != nil else { throw ReaderBundleError.incompatibleFormat }
        return bundle
    }
    public static func encode(_ bundle: VerifiedReaderBundle) throws -> Data {
        guard bundle.arxivSource != nil || bundle.devicePDFSource?.paper != nil else { throw ReaderBundleError.incompatibleFormat }
        let payload = Payload(manifest: bundle.manifestData.base64EncodedString(), manifestSHA256: bundle.manifestSHA256,
            members: try bundle.manifest.members.map { member in
                guard let data = bundle.data(for: member.path) else { throw ReaderBundleError.invalidResource }
                return Payload.Member(path: member.path, base64: data.base64EncodedString())
            })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

import Foundation

/// The full native wire is format 2 for both families. Compact format 4/5 is a
/// different protocol and is never a substitute for one of these contexts.
/// Deployment/account binding belongs to the enclosing store/request scope.
public enum LibraryReadContext: Codable, Equatable, Sendable {
    case legacyFull3
    case uploadFull5(datasetEpoch: UUID)

    public var endpointVersion: Int { if case .uploadFull5 = self { 5 } else { 3 } }
    public var datasetEpoch: UUID? { if case .uploadFull5(let epoch) = self { epoch } else { nil } }
    public var permitsUploads: Bool { datasetEpoch != nil }

    private enum CodingKeys: String, CodingKey { case family, epoch }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .family) {
        case "full-v3":
            guard !values.contains(.epoch) else { throw LibraryProtocolError.invalidCursor }
            self = .legacyFull3
        case "full-v5": self = .uploadFull5(datasetEpoch: try values.decode(UUID.self, forKey: .epoch))
        default: throw LibraryProtocolError.unsupportedFormat
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(permitsUploads ? "full-v5" : "full-v3", forKey: .family)
        if let epoch = datasetEpoch { try values.encode(epoch.wire, forKey: .epoch) }
    }
}

/// Advisory, account-bound protocol discovery. `uploads.enabled` never grants
/// a send, allocation or provider call; the server admits each action again.
public struct ReaderCapabilities: Decodable, Equatable, Sendable {
    public struct Library: Decodable, Equatable, Sendable {
        public let endpointFamily: String
        public let wireFormat: Int
        public let sourceLevel: Int
        public let datasetEpoch: UUID
        private enum CodingKeys: String, CodingKey {
            case endpointFamily = "endpoint_family", wireFormat = "wire_format"
            case sourceLevel = "source_level", datasetEpoch = "dataset_epoch"
        }
    }
    public struct Descriptors: Decodable, Equatable, Sendable {
        public let format: Int
        public let maximumBatch: Int
        private enum CodingKeys: String, CodingKey { case format, maximumBatch = "maximum_batch" }
    }
    public struct Uploads: Decodable, Equatable, Sendable {
        public let `protocol`: String
        public let enabled: Bool
        public let chunkBytes: Int
        public let maximumBytes: Int
        public let maximumParts: Int
        public let partAttempts: Int
        private enum CodingKeys: String, CodingKey {
            case `protocol`, enabled, chunkBytes = "chunk_bytes", maximumBytes = "maximum_bytes"
            case maximumParts = "maximum_parts", partAttempts = "part_attempts"
        }
    }
    public let format: Int
    public let accountID: UUID
    public let library: Library
    public let descriptors: Descriptors
    public let uploads: Uploads
    public var readContext: LibraryReadContext { .uploadFull5(datasetEpoch: library.datasetEpoch) }
    private enum CodingKeys: String, CodingKey { case format, accountID = "account_id", library, descriptors, uploads }

    public static func decode(_ data: Data, accountID: UUID) throws -> Self {
        guard data.count <= 16_384 else { throw LibraryProtocolError.payloadTooLarge }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.accountID == accountID else { throw LibraryProtocolError.accountMismatch }
        guard result.format == 1, result.library.endpointFamily == "full-v5", result.library.wireFormat == 2,
              result.library.sourceLevel == 4, result.descriptors.format == 1, result.descriptors.maximumBatch == 24,
              result.uploads.protocol == "upload-chunks-v1", result.uploads.chunkBytes == 4_194_304,
              result.uploads.maximumBytes == 67_108_864, result.uploads.maximumParts == 16,
              (1...8).contains(result.uploads.partAttempts) else { throw LibraryProtocolError.unsupportedFormat }
        return result
    }
}

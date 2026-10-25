import Foundation
import zlib

// The interest index's public artifacts (docs/architecture/INTEREST_INDEX.md §3–4; the server's codec is
// supabase/functions/_shared/interest/codec.ts). Every artifact is one gzip stream holding
//   "GSI1" · u32 LE header length · UTF-8 JSON header · binary body
// The header names the kind (`map`, `terms` or `shard`) and its format version (1). Bodies:
//   shard  per paper: u8 id length · id (ASCII) · u16 LE announcement day (days since 1970-01-01) · q8 fingerprint
//   map    q8 centroids, one per header node, in header order
//   terms  per phrase, sorted bytewise: u8 shared-prefix length · suffix (UTF-8) · 0x00 · varint df · i8 conceptness×1000
// q8 = f32 LE scale (max |x| / 127) · 384 × i8 round(x / scale).

public enum InterestArtifactError: Error, Equatable {
    case gzip, magic, header, format, truncated, dimension
}

/// One decoded artifact: its JSON header and its binary body.
public struct InterestArtifact: Sendable {
    public enum Kind: String, Sendable, Decodable { case map, terms, shard }
    public let kind: Kind
    /// The whole header as JSON (step 3 reads the map's nodes and the terms' tokenizer spec from it).
    public let header: [String: InterestJSON]
    public let body: Data

    /// Most an artifact may inflate to (the server caps one artifact at 16 MiB compressed; a window's shard is ≈ 4 MB raw).
    public static let maximumInflatedBytes = 96 * 1_048_576
    static let magic: [UInt8] = [0x47, 0x53, 0x49, 0x31] // "GSI1"

    public init(gzipped: Data) throws {
        let raw = try Self.gunzip(gzipped)
        guard raw.count >= 8, Array(raw.prefix(4)) == Self.magic else { throw InterestArtifactError.magic }
        let length = Int(raw.loadLE(UInt32.self, at: 4))
        guard length <= raw.count - 8 else { throw InterestArtifactError.truncated }
        let headerData = raw.subdata(in: 8 ..< 8 + length)
        guard let header = try? JSONDecoder().decode([String: InterestJSON].self, from: headerData),
              case .string(let kindName)? = header["kind"], let kind = Kind(rawValue: kindName) else { throw InterestArtifactError.header }
        guard case .number(let format)? = header["format"], format == 1 else { throw InterestArtifactError.format }
        self.kind = kind; self.header = header
        body = raw.subdata(in: 8 + length ..< raw.count)
    }

    /// A gzip stream's contents (zlib checks the stream's CRC-32 and length).
    static func gunzip(_ data: Data, limit: Int = maximumInflatedBytes) throws -> Data {
        guard data.count >= 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { throw InterestArtifactError.gzip }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw InterestArtifactError.gzip }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunk = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunk)
        var status: Int32 = Z_OK
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                    stream.next_out = out.baseAddress; stream.avail_out = uInt(chunk)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw InterestArtifactError.gzip }
                output.append(buffer, count: chunk - Int(stream.avail_out))
                if output.count > limit { throw InterestArtifactError.gzip }
            } while status != Z_STREAM_END && (stream.avail_in > 0 || stream.avail_out == 0)
        }
        guard status == Z_STREAM_END else { throw InterestArtifactError.truncated }
        return output
    }
}

/// The header's JSON values, kept as they are.
public enum InterestJSON: Decodable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([InterestJSON]), object([String: InterestJSON])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([InterestJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: InterestJSON].self)) }
    }
}

/// q8 fingerprints: an f32 LE scale, then 384 signed bytes.
public enum InterestQ8 {
    public static let dimension = 384
    public static let bytes = 4 + dimension

    /// Decodes one q8 vector at `offset` into `out` (dimension floats), L2-normalised when `normalize`.
    public static func decode(_ data: Data, at offset: Int, into out: UnsafeMutablePointer<Float>, normalize: Bool = true) {
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            let scale = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(as: UInt32.self)))
            let values = base.advanced(by: 4).assumingMemoryBound(to: Int8.self)
            var norm: Float = 0
            for i in 0 ..< dimension {
                let v = Float(values[i]) * scale
                out[i] = v; norm += v * v
            }
            if normalize, norm > 0 {
                let inverse = 1 / norm.squareRoot()
                for i in 0 ..< dimension { out[i] *= inverse }
            }
        }
    }

    /// One q8 vector as floats.
    public static func decode(_ data: Data, at offset: Int = 0, normalize: Bool = true) -> [Float] {
        var out = [Float](repeating: 0, count: dimension)
        out.withUnsafeMutableBufferPointer { decode(data, at: offset, into: $0.baseAddress!, normalize: normalize) }
        return out
    }
}

/// A shard's papers in order: arXiv identifier, announcement day and the q8 fingerprint's offset in the body.
public struct InterestShard: Sendable {
    public struct Paper: Sendable, Equatable {
        public let sourceID: String
        /// Days since 1970-01-01 (UTC).
        public let announcedDay: Int
        /// Where its q8 fingerprint starts in `body`.
        public let offset: Int
    }
    public let papers: [Paper]
    public let body: Data

    public init(_ artifact: InterestArtifact) throws {
        guard artifact.kind == .shard else { throw InterestArtifactError.header }
        let body = artifact.body
        var papers: [Paper] = []
        var at = 0
        while at < body.count {
            let length = Int(body[body.startIndex + at]); at += 1
            guard length > 0, at + length + 2 + InterestQ8.bytes <= body.count else { throw InterestArtifactError.truncated }
            let idBytes = body.subdata(in: body.startIndex + at ..< body.startIndex + at + length)
            guard idBytes.allSatisfy({ (0x21 ... 0x7e).contains($0) }), let id = String(data: idBytes, encoding: .ascii) else { throw InterestArtifactError.header }
            at += length
            let day = Int(body.loadLE(UInt16.self, at: at)); at += 2
            papers.append(Paper(sourceID: id, announcedDay: day, offset: at))
            at += InterestQ8.bytes
        }
        if case .number(let count)? = artifact.header["papers"], Int(count) != papers.count { throw InterestArtifactError.truncated }
        self.papers = papers; self.body = body
    }
}

extension Data {
    func loadLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.baseAddress!.advanced(by: offset).loadUnaligned(as: T.self)) }
    }
}

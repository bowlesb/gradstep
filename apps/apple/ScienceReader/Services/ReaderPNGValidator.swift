import Foundation
import ScienceReaderCore
import zlib

/// The renderer's restricted PNG profile, checked before ImageIO allocates a
/// raster. ImageIO can otherwise recover incomplete files and report success.
enum ReaderPNGValidator {
    static func validate(_ data: Data, width: Int, height: Int) throws {
        let bytes = [UInt8](data)
        guard bytes.count <= 16_777_216, bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_000_000 else {
            throw ReaderBundleError.invalidResource
        }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        var offset = 8, chunks = 0, channels = 0, ended = false, compressed = Data()
        while offset < bytes.count {
            chunks += 1
            guard chunks <= 512, offset + 12 <= bytes.count else { throw ReaderBundleError.invalidResource }
            let length = Int(uint32(offset))
            guard length <= 16_777_216, length <= bytes.count - offset - 12 else { throw ReaderBundleError.invalidResource }
            let body = offset + 8, end = body + length
            let actualCRC = bytes.withUnsafeBytes { raw in
                crc32(0, raw.baseAddress!.advanced(by: offset + 4).assumingMemoryBound(to: Bytef.self), uInt(length + 4))
            }
            guard UInt32(actualCRC) == uint32(end) else { throw ReaderBundleError.invalidResource }
            let type = Array(bytes[(offset + 4)..<body])
            if chunks == 1 {
                guard type == Array("IHDR".utf8), length == 13,
                      Int(uint32(body)) == width, Int(uint32(body + 4)) == height,
                      bytes[body + 8] == 8, [2, 6].contains(bytes[body + 9]),
                      bytes[body + 10] == 0, bytes[body + 11] == 0, bytes[body + 12] == 0 else {
                    throw ReaderBundleError.invalidResource
                }
                channels = bytes[body + 9] == 2 ? 3 : 4
            } else if type == Array("IDAT".utf8) {
                compressed.append(contentsOf: bytes[body..<end])
            } else if type == Array("IEND".utf8) {
                guard length == 0, !compressed.isEmpty, end + 4 == bytes.count else { throw ReaderBundleError.invalidResource }
                ended = true; break
            } else { throw ReaderBundleError.invalidResource }
            offset = end + 4
        }
        guard ended, channels > 0 else { throw ReaderBundleError.invalidResource }
        try validateScanlines(compressed, rowBytes: width * channels + 1, height: height)
    }

    private static func validateScanlines(_ compressed: Data, rowBytes: Int, height: Int) throws {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ReaderBundleError.invalidResource
        }
        defer { inflateEnd(&stream) }
        let expected = rowBytes * height
        var buffer = [UInt8](repeating: 0, count: 65_536), total = 0
        try compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)
            while true {
                let before = stream.avail_in
                let result = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard count <= expected - total else { throw ReaderBundleError.invalidResource }
                var filter = (rowBytes - total % rowBytes) % rowBytes
                while filter < count {
                    guard buffer[filter] <= 4 else { throw ReaderBundleError.invalidResource }
                    filter += rowBytes
                }
                total += count
                if result == Z_STREAM_END {
                    guard stream.avail_in == 0, total == expected else { throw ReaderBundleError.invalidResource }
                    return
                }
                guard result == Z_OK, count > 0 || stream.avail_in < before else { throw ReaderBundleError.invalidResource }
            }
        }
    }
}

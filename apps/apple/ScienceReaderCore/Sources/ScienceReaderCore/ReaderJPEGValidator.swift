import Foundation

/// Structural JPEG profile for reader figures, checked before ImageIO decodes
/// a raster (ImageIO can recover truncated files and still report success).
/// One baseline/extended/progressive Huffman frame of 8-bit samples with 1 or
/// 3 components, complete entropy-coded scans, and EOI as the final bytes.
/// Application/comment segments are tolerated here; the renderer already
/// publishes metadata-free canonical files.
public enum ReaderJPEGValidator {
    public static func validate(_ data: Data, width: Int, height: Int) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes.count <= 16_777_216, bytes[0] == 0xff, bytes[1] == 0xd8,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_000_000 else {
            throw ReaderBundleError.invalidResource
        }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        var at = 2, segments = 0, scans = 0, frame: [UInt8]? = nil
        while true {
            segments += 1
            guard segments <= 4096, at + 2 <= bytes.count, bytes[at] == 0xff else { throw ReaderBundleError.invalidResource }
            var marker = bytes[at + 1]
            while marker == 0xff {
                at += 1
                guard at + 1 < bytes.count else { throw ReaderBundleError.invalidResource }
                marker = bytes[at + 1]
            }
            if marker == 0xd9 {
                guard at + 2 == bytes.count, frame != nil, scans > 0 else { throw ReaderBundleError.invalidResource }
                return
            }
            guard marker != 0x00, marker != 0x01, marker != 0xd8, !(0xd0...0xd7).contains(marker),
                  at + 4 <= bytes.count else { throw ReaderBundleError.invalidResource }
            let length = u16(at + 2), end = at + 2 + length
            guard length >= 2, end <= bytes.count else { throw ReaderBundleError.invalidResource }
            switch marker {
            case 0xc0, 0xc1, 0xc2:
                let count = length >= 8 ? Int(bytes[at + 9]) : 0
                guard frame == nil, length >= 8, bytes[at + 4] == 8, u16(at + 5) == height, u16(at + 7) == width,
                      count == 1 || count == 3, length == 8 + 3 * count else { throw ReaderBundleError.invalidResource }
                var ids: [UInt8] = []
                for n in 0..<count {
                    let id = bytes[at + 10 + 3 * n], sampling = bytes[at + 11 + 3 * n], table = bytes[at + 12 + 3 * n]
                    guard !ids.contains(id), (1...4).contains(sampling >> 4), (1...4).contains(sampling & 15), table <= 3 else {
                        throw ReaderBundleError.invalidResource
                    }
                    ids.append(id)
                }
                frame = ids
                at = end
            case 0xda:
                guard let components = frame, length >= 8 else { throw ReaderBundleError.invalidResource }
                let count = Int(bytes[at + 4])
                guard (1...components.count).contains(count), length == 6 + 2 * count,
                      (0..<count).allSatisfy({ components.contains(bytes[at + 5 + 2 * $0]) }) else { throw ReaderBundleError.invalidResource }
                // Entropy-coded data ends at the first marker that is neither
                // a stuffed 0xFF00 nor a restart marker.
                var cursor = end
                while true {
                    guard cursor + 1 < bytes.count else { throw ReaderBundleError.invalidResource }
                    if bytes[cursor] == 0xff {
                        let next = bytes[cursor + 1]
                        if next == 0x00 || (0xd0...0xd7).contains(next) { cursor += 2; continue }
                        if next == 0xff { cursor += 1; continue }
                        break
                    }
                    cursor += 1
                }
                guard cursor > end else { throw ReaderBundleError.invalidResource }
                scans += 1
                at = cursor
            case 0xc4, 0xdb, 0xdd, 0xe0...0xef, 0xfe:
                at = end
            default:
                // Lossless, hierarchical and arithmetic-coded frames, DNL, DAC
                // and reserved markers are outside this profile.
                throw ReaderBundleError.invalidResource
            }
        }
    }
}

import Foundation

/// TexTeller's tokenizer for decoding only (RobertaTokenizer, byte-level BPE): ids to tokens, the special tokens
/// skipped, the byte-level alphabet mapped back to bytes (a token with a character outside it, an added CJK token,
/// keeps its own UTF-8), then `clean_up_tokenization_spaces` (the tokenizer's config sets it) and a strip, as
/// `Recogniser._batch` decodes.
public struct DevicePDFTokenizer: Sendable {
    let tokens: [Int: String]
    let special: Set<Int>
    static let byteDecoder: [Character: UInt8] = {
        var bs = Array(UInt8(ascii: "!")...UInt8(ascii: "~")) + Array(UInt8(0xA1)...UInt8(0xAC)) + Array(UInt8(0xAE)...UInt8(0xFF))
        var cs = bs.map { UInt32($0) }
        var n: UInt32 = 0
        for b in 0...255 where !bs.contains(UInt8(b)) { bs.append(UInt8(b)); cs.append(256 + n); n += 1 }
        var out: [Character: UInt8] = [:]
        for (b, c) in zip(bs, cs) { out[Character(Unicode.Scalar(c)!)] = b }
        return out
    }()

    public init(vocabulary: URL, added: URL) throws {
        guard let data = try? Data(contentsOf: vocabulary), let vocab = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw DevicePDFModelError.missing(vocabulary.lastPathComponent)
        }
        var tokens: [Int: String] = [:]
        for (token, id) in vocab { tokens[id] = token }
        if let data = try? Data(contentsOf: added), let extra = try JSONSerialization.jsonObject(with: data) as? [String: Int] {
            for (token, id) in extra { tokens[id] = token }
        }
        self.init(tokens: tokens, special: Set(["<s>", "<pad>", "</s>", "<unk>", "<mask>"].compactMap { vocab[$0] }))
    }

    init(tokens: [Int: String], special: Set<Int>) { self.tokens = tokens; self.special = special }

    public func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids where !special.contains(id) {
            guard let token = tokens[id] else { continue }
            var mapped: [UInt8] = []
            var ok = true
            for ch in token { if let b = Self.byteDecoder[ch] { mapped.append(b) } else { ok = false; break } }
            bytes += ok ? mapped : Array(token.utf8)
        }
        var text = String(decoding: bytes, as: UTF8.self)
        for (from, to) in [(" .", "."), (" ?", "?"), (" !", "!"), (" ,", ","), (" ' ", "'"), (" n't", "n't"), (" 'm", "'m"), (" 's", "'s"), (" 've", "'ve"), (" 're", "'re")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

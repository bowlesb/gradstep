import Accelerate
import CryptoKit
import Foundation

/// Independent float32 evaluation of the repo's two-layer bidirectional PyTorch Tagger. This is a recovery
/// implementation, not another trained model. Weights are immutable; every prediction owns its recurrent state.
public final class DevicePDFReferenceTagger: Sendable {
    public let featureCount: Int
    public let vocabularySHA256: String
    public let checkpointSHA256: String
    public let binarySHA256: String
    private let hidden: Int
    private let tensors: [String: [Float]]

    private struct Tensor: Decodable {
        let shape: [Int]
        let offset: Int
        let count: Int
    }
    private struct Manifest: Decodable {
        let format: String
        let nFeatures: Int
        let hidden: Int
        let maxLength: Int
        let checkpointSHA256: String
        let vocabularySHA256: String
        let binarySHA256: String
        let byteOrder: String
        let scalarType: String
        let offsetUnit: String
        let tensors: [String: Tensor]
        enum CodingKeys: String, CodingKey {
            case format, hidden, tensors
            case nFeatures = "n_features", maxLength = "max_len", checkpointSHA256 = "checkpoint_sha256"
            case vocabularySHA256 = "vocabulary_sha256", binarySHA256 = "binary_sha256"
            case byteOrder = "byte_order", scalarType = "scalar_type", offsetUnit = "offset_unit"
        }
    }

    /// Both paths are chosen by the verified pack, never by a path inside the manifest. Validate the complete tensor
    /// layout and byte count before reading/allocating weights, then verify the digest and every scalar's finiteness.
    public init(manifest: URL, weights: URL) throws {
        func fail(_ part: String) -> DevicePDFModelError { .unusable("reference tagger " + part) }
        func byteCount(_ url: URL, maximum: Int) throws -> Int {
            guard url.isFileURL,
                  let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                  bytes.int64Value > 0, bytes.int64Value <= Int64(maximum) else { throw fail("file size") }
            return bytes.intValue
        }
        _ = try byteCount(manifest, maximum: 64 * 1024)
        let decoded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        func digestValid(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard decoded.format == "device-pdf-tagger-reference-v1", [10, 12].contains(decoded.nFeatures),
              (1...256).contains(decoded.hidden), decoded.maxLength == 400,
              decoded.byteOrder == "little", decoded.scalarType == "float32", decoded.offsetUnit == "float32_elements",
              digestValid(decoded.checkpointSHA256), digestValid(decoded.vocabularySHA256), digestValid(decoded.binarySHA256) else { throw fail("manifest") }
        let h = decoded.hidden, features = decoded.nFeatures
        var shapes: [String: [Int]] = ["font.weight": [256, 24], "cls.weight": [10, 8], "ch.weight": [512, 16],
                                      "inp.weight": [h, features + 48], "inp.bias": [h], "out.weight": [1, h * 2], "out.bias": [1]]
        for layer in 0..<2 {
            for suffix in ["", "_reverse"] {
                shapes["gru.weight_ih_l\(layer)\(suffix)"] = [3 * h, layer == 0 ? h : 2 * h]
                shapes["gru.weight_hh_l\(layer)\(suffix)"] = [3 * h, h]
                shapes["gru.bias_ih_l\(layer)\(suffix)"] = [3 * h]
                shapes["gru.bias_hh_l\(layer)\(suffix)"] = [3 * h]
            }
        }
        guard Set(decoded.tensors.keys) == Set(shapes.keys) else { throw fail("tensor names") }
        var count = 0
        for name in shapes.keys.sorted() {
            let expected = shapes[name]!, tensor = decoded.tensors[name]!, size = expected.reduce(1, *)
            // Canonical contiguous layout also rules out overlaps, omitted bytes and unchecked padding.
            guard tensor.shape == expected, tensor.count == size, tensor.offset == count else { throw fail("tensor layout") }
            count += size
        }
        guard try byteCount(weights, maximum: 16 * 1024 * 1024) == count * 4 else { throw fail("weight size") }
        let data = try Data(contentsOf: weights, options: .mappedIfSafe)
        guard data.count == count * 4,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == decoded.binarySHA256 else { throw fail("weight digest") }
        let finite = data.withUnsafeBytes { bytes in
            (0..<count).allSatisfy { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))).isFinite }
        }
        guard finite else { throw fail("nonfinite weight") }
        var loaded: [String: [Float]] = [:]
        data.withUnsafeBytes { bytes in
            for (name, tensor) in decoded.tensors {
                loaded[name] = (tensor.offset..<(tensor.offset + tensor.count)).map {
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
                }
            }
        }
        featureCount = features; hidden = h; tensors = loaded
        vocabularySHA256 = decoded.vocabularySHA256; checkpointSHA256 = decoded.checkpointSHA256
        binarySHA256 = decoded.binarySHA256
    }

    /// Exact length, no padded suffix: the backward GRU must start at the last actual glyph.
    public func tag(x: [Float], font: [Int32], cls: [Int32], char: [Int32]) throws -> [Float] {
        let length = font.count, h = hidden, width = featureCount + 48
        guard (2...400).contains(length), x.count == length * featureCount, cls.count == length, char.count == length,
              x.allSatisfy(\.isFinite), font.allSatisfy({ (0..<256).contains($0) }),
              cls.allSatisfy({ (0..<10).contains($0) }), char.allSatisfy({ (0..<512).contains($0) }) else {
            throw DevicePDFModelError.unusable("reference tagger input")
        }
        let fonts = tensors["font.weight"]!, classes = tensors["cls.weight"]!, chars = tensors["ch.weight"]!
        var joined = [Float](repeating: 0, count: length * width)
        for row in 0..<length {
            let base = row * width
            for i in 0..<featureCount { joined[base + i] = x[row * featureCount + i] }
            for i in 0..<24 { joined[base + featureCount + i] = fonts[Int(font[row]) * 24 + i] }
            for i in 0..<8 { joined[base + featureCount + 24 + i] = classes[Int(cls[row]) * 8 + i] }
            for i in 0..<16 { joined[base + featureCount + 32 + i] = chars[Int(char[row]) * 16 + i] }
        }
        var sequence = Self.linear(joined, rows: length, columns: width, weights: tensors["inp.weight"]!, outputs: h)
        let bias = tensors["inp.bias"]!
        for i in sequence.indices { sequence[i] = max(0, sequence[i] + bias[i % h]) }
        for layer in 0..<2 {
            let inputWidth = layer == 0 ? h : 2 * h
            var output = [Float](repeating: 0, count: length * 2 * h)
            for direction in 0..<2 {
                let suffix = direction == 0 ? "" : "_reverse"
                let inputWeight = tensors["gru.weight_ih_l\(layer)\(suffix)"]!
                let hiddenWeight = tensors["gru.weight_hh_l\(layer)\(suffix)"]!
                let inputBias = tensors["gru.bias_ih_l\(layer)\(suffix)"]!
                let hiddenBias = tensors["gru.bias_hh_l\(layer)\(suffix)"]!
                let gates = Self.linear(sequence, rows: length, columns: inputWidth, weights: inputWeight, outputs: 3 * h)
                var state = [Float](repeating: 0, count: h), recurrent = [Float](repeating: 0, count: 3 * h)
                for step in 0..<length {
                    let row = direction == 0 ? step : length - 1 - step
                    hiddenWeight.withUnsafeBufferPointer { weights in
                        state.withUnsafeBufferPointer { previous in
                            recurrent.withUnsafeMutableBufferPointer { values in
                                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(3 * h), Int32(h), 1,
                                            weights.baseAddress!, Int32(h), previous.baseAddress!, 1, 0, values.baseAddress!, 1)
                            }
                        }
                    }
                    for i in 0..<h {
                        let base = row * 3 * h
                        let reset = 1 / (1 + expf(-(gates[base + i] + inputBias[i] + recurrent[i] + hiddenBias[i])))
                        let update = 1 / (1 + expf(-(gates[base + h + i] + inputBias[h + i] + recurrent[h + i] + hiddenBias[h + i])))
                        // PyTorch gate order r,z,n, with reset applied after the recurrent candidate projection.
                        let candidate = tanhf(gates[base + 2 * h + i] + inputBias[2 * h + i] + reset * (recurrent[2 * h + i] + hiddenBias[2 * h + i]))
                        state[i] = (1 - update) * candidate + update * state[i]
                        output[row * 2 * h + direction * h + i] = state[i]
                    }
                }
            }
            sequence = output
        }
        var logits = Self.linear(sequence, rows: length, columns: 2 * h, weights: tensors["out.weight"]!, outputs: 1)
        let outputBias = tensors["out.bias"]![0]
        for i in logits.indices { logits[i] += outputBias }
        guard logits.allSatisfy(\.isFinite) else { throw DevicePDFModelError.unusable("reference tagger output") }
        return logits
    }

    /// PyTorch Linear uses input × weightᵀ. The immutable weight matrices are row-major [outputs, inputs].
    private static func linear(_ input: [Float], rows: Int, columns: Int, weights: [Float], outputs: Int) -> [Float] {
        var result = [Float](repeating: 0, count: rows * outputs)
        input.withUnsafeBufferPointer { x in
            weights.withUnsafeBufferPointer { w in
                result.withUnsafeMutableBufferPointer { y in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(outputs), Int32(columns),
                                1, x.baseAddress!, Int32(columns), w.baseAddress!, Int32(columns), 0, y.baseAddress!, Int32(outputs))
                }
            }
        }
        return result
    }
}

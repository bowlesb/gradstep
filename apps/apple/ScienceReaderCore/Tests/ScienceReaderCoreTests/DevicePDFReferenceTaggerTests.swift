import CryptoKit
import Foundation
import XCTest
@testable import ScienceReaderCore

final class DevicePDFReferenceTaggerTests: XCTestCase {
    private struct Gold: Decodable { let fixtures: [Sample] }
    private struct Sample: Decodable, Sendable {
        let id: String
        let x: [Float]
        let font: [Int32], cls: [Int32], char: [Int32]
        let logits: [Float]
    }
    private func resource(_ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "device-pdf-tagger-reference-fixture", withExtension: ext))
    }
    private func samples() throws -> [Sample] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "device-pdf-tagger-reference-gold", withExtension: "json"))
        return try JSONDecoder().decode(Gold.self, from: Data(contentsOf: url)).fixtures
    }
    private func model() throws -> DevicePDFReferenceTagger {
        try DevicePDFReferenceTagger(manifest: resource("json"), weights: resource("bin"))
    }

    func testBothLayersAndDirectionsMatchIndependentPyTorchAtExactLengths() throws {
        // Nonzero, distinct weights in every r/z/n gate and both input/recurrent biases make gate order,
        // reset placement, backward alignment, concatenation and accidental padding affect these answers.
        let model = try model(), gold = try samples()
        XCTAssertEqual(gold.map { $0.font.count }, [2, 3])
        XCTAssertEqual(model.featureCount, 12)
        XCTAssertEqual(model.vocabularySHA256, "02887629cd17b6d51699310b0d201a9f7a301731a1314858b85e75aed3a79e77")
        for sample in gold + gold.reversed() {
            let actual = try model.tag(x: sample.x, font: sample.font, cls: sample.cls, char: sample.char)
            XCTAssertEqual(actual.count, sample.logits.count)
            for (value, expected) in zip(actual, sample.logits) { XCTAssertEqual(value, expected, accuracy: 0.000001, sample.id) }
        }
    }

    func testInMemoryCarrierBytesUseIdenticalValidationAndPredictionsWithoutAPlaintextFile() throws {
        let manifest = try Data(contentsOf: resource("json")), weights = try Data(contentsOf: resource("bin"))
        let memory = try DevicePDFReferenceTagger(manifest: manifest, weights: weights)
        let disk = try model()
        XCTAssertEqual(memory.binarySHA256, disk.binarySHA256)
        XCTAssertEqual(memory.checkpointSHA256, disk.checkpointSHA256)
        for sample in try samples() {
            XCTAssertEqual(try memory.tag(x: sample.x, font: sample.font, cls: sample.cls, char: sample.char),
                           try disk.tag(x: sample.x, font: sample.font, cls: sample.cls, char: sample.char))
        }
        var corrupt = weights; corrupt[0] ^= 1
        XCTAssertThrowsError(try DevicePDFReferenceTagger(manifest: manifest, weights: corrupt))
        XCTAssertThrowsError(try DevicePDFReferenceTagger(manifest: manifest, weights: Data(weights.dropLast())))
        XCTAssertThrowsError(try DevicePDFReferenceTagger(manifest: Data(repeating: 32, count: 65_537), weights: weights))
    }

    func testConcurrentPredictionsHaveIndependentRecurrentState() throws {
        let model = try model(), gold = try samples()
        final class Errors: @unchecked Sendable {
            let lock = NSLock()
            var failures = 0
            func fail() { lock.lock(); failures += 1; lock.unlock() }
        }
        let errors = Errors()
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            let sample = gold[i % gold.count]
            guard let values = try? model.tag(x: sample.x, font: sample.font, cls: sample.cls, char: sample.char),
                  values.count == sample.logits.count,
                  zip(values, sample.logits).allSatisfy({ abs($0.0 - $0.1) < 0.000001 }) else { errors.fail(); return }
        }
        XCTAssertEqual(errors.failures, 0)
    }

    private func changed(_ edit: (inout [String: Any], inout Data) -> Void) throws -> DevicePDFReferenceTagger {
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource("json"))) as? [String: Any])
        var data = try Data(contentsOf: resource("bin"))
        edit(&manifest, &data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = directory.appendingPathComponent("reference.json"), binary = directory.appendingPathComponent("reference.bin")
        try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: json)
        try data.write(to: binary)
        return try DevicePDFReferenceTagger(manifest: json, weights: binary)
    }

    func testManifestDimensionsFormatsAndTensorRangesAreValidatedBeforeLoading() throws {
        for (key, value): (String, Any) in [("format", "unknown"), ("n_features", 11), ("hidden", 0),
                                          ("hidden", 257), ("hidden", Int.max), ("max_len", 401),
                                          ("byte_order", "big"), ("scalar_type", "float16"), ("offset_unit", "bytes"),
                                          ("vocabulary_sha256", String(repeating: "z", count: 64))] {
            XCTAssertThrowsError(try changed { manifest, _ in manifest[key] = value }, key)
        }
        for property in ["offset", "count", "shape"] {
            XCTAssertThrowsError(try changed { manifest, _ in
                var tensors = manifest["tensors"] as! [String: [String: Any]]
                if property == "shape" { tensors["out.weight"]![property] = [1, 99] }
                else { tensors["out.weight"]![property] = -1 }
                manifest["tensors"] = tensors
            }, property)
        }
        XCTAssertThrowsError(try changed { manifest, _ in
            var tensors = manifest["tensors"] as! [String: Any]
            tensors.removeValue(forKey: "out.bias"); manifest["tensors"] = tensors
        })
        XCTAssertThrowsError(try changed { manifest, _ in
            var tensors = manifest["tensors"] as! [String: Any]
            tensors["unexpected"] = ["shape": [1], "offset": 0, "count": 1]; manifest["tensors"] = tensors
        })
    }

    func testCorruptTruncatedAndNonfiniteWeightsFailClosed() throws {
        XCTAssertThrowsError(try changed { _, data in data[0] ^= 1 })
        XCTAssertThrowsError(try changed { _, data in data.removeLast() })
        XCTAssertThrowsError(try changed { manifest, data in
            data.replaceSubrange(0..<4, with: [0, 0, 192, 127]) // quiet float32 NaN, with an otherwise valid digest
            manifest["binary_sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        })
        // Manifest path-like metadata is not used to select a file: only the explicitly supplied binary is read.
        XCTAssertNoThrow(try changed { manifest, _ in manifest["binary_file"] = "../../does-not-exist.bin" })
    }

    func testInputLengthsFeaturesAndEmbeddingIndicesFailBeforePrediction() throws {
        let model = try model(), sample = try XCTUnwrap(samples().first)
        for length in [0, 1, 401] {
            XCTAssertThrowsError(try model.tag(x: [Float](repeating: 0, count: length * 12),
                                             font: [Int32](repeating: 0, count: length), cls: [Int32](repeating: 0, count: length),
                                             char: [Int32](repeating: 0, count: length)))
        }
        XCTAssertThrowsError(try model.tag(x: Array(sample.x.dropLast()), font: sample.font, cls: sample.cls, char: sample.char))
        for invalid: Float in [.nan, .infinity, -.infinity] {
            var x = sample.x; x[0] = invalid
            XCTAssertThrowsError(try model.tag(x: x, font: sample.font, cls: sample.cls, char: sample.char))
        }
        for invalid: Int32 in [-1, 256] {
            var font = sample.font; font[0] = invalid
            XCTAssertThrowsError(try model.tag(x: sample.x, font: font, cls: sample.cls, char: sample.char))
        }
        var classes = sample.cls; classes[0] = 10
        XCTAssertThrowsError(try model.tag(x: sample.x, font: sample.font, cls: classes, char: sample.char))
        var chars = sample.char; chars[0] = 512
        XCTAssertThrowsError(try model.tag(x: sample.x, font: sample.font, cls: sample.cls, char: chars))
    }
}

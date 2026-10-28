import CryptoKit
import Foundation
import XCTest
@testable import ScienceReaderCore

/// Explicit local corpus gate, excluded from routine focused native tests. No model files ship in the test bundle.
@available(macOS 15.0, iOS 18.0, *)
final class DevicePDFReferenceRecoveryCorpusTests: XCTestCase {
    func testPersistentInvalidBuffersRecoverThroughTheActualPolicyAndFrozenWeights() throws {
        guard let path = ProcessInfo.processInfo.environment["DEVICE_PDF_RECOVERY_CORPUS"] else {
            throw XCTSkip("opt-in local native reference corpus")
        }
        struct Paths: Decodable { let inputs: String, gold: String, manifest: String, weights: String, report: String }
        struct Input: Decodable { let x: [Float], font: [Int32], cls: [Int32], char: [Int32] }
        struct Gold: Decodable { let inputs_sha256: String, checkpoint_sha256: String, logits: [[Float]] }
        func data(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
        let paths = try JSONDecoder().decode(Paths.self, from: data(path))
        try JSONSerialization.data(withJSONObject: ["passed": false]).write(to: URL(fileURLWithPath: paths.report), options: .atomic)
        let bytes = try data(paths.inputs), inputs = try JSONDecoder().decode([Input].self, from: bytes)
        let goldBytes = try data(paths.gold), gold = try JSONDecoder().decode(Gold.self, from: goldBytes)
        let inputsSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let model = try DevicePDFReferenceTagger(manifest: URL(fileURLWithPath: paths.manifest), weights: URL(fileURLWithPath: paths.weights))
        let identityVerified = inputsSHA256 == gold.inputs_sha256 && inputs.count == 2029 &&
            inputs.count == gold.logits.count && model.featureCount == 12 && model.checkpointSHA256 == gold.checkpoint_sha256
        guard identityVerified else { return XCTFail("corpus/model identity mismatch; report remains failed") }
        let shapesVerified = zip(inputs, gold.logits).allSatisfy {
            $0.0.font.count == $0.1.count && $0.1.allSatisfy(\.isFinite)
        }
        guard shapesVerified else { return XCTFail("invalid gold shape or nonfinite gold logits; report remains failed") }
        var calls = 0, recoveries = 0, ownDisagreements = 0, allDisagreements = 0, glyphs = 0, maxError: Float = 0
        let threshold = logf(0.65 / 0.35)
        for (i, input) in inputs.enumerated() {
            let result = try DevicePDFModels.readTaggerOutput(count: input.font.count, recovery: {
                recoveries += 1
                return try model.tag(x: input.x, font: input.font, cls: input.cls, char: input.char)
            }) { calls += 1; return [Float](repeating: 0, count: input.font.count) }
            guard result.count == gold.logits[i].count else { return XCTFail("wrong recovered output length; report remains failed") }
            for j in result.indices {
                glyphs += 1; maxError = max(maxError, abs(result[j] - gold.logits[i][j]))
                if (result[j] > threshold) != (gold.logits[i][j] > threshold) {
                    allDisagreements += 1
                    if input.x[j * model.featureCount + 10] == 0 && input.x[j * model.featureCount + 11] == 0 { ownDisagreements += 1 }
                }
            }
        }
        XCTAssertEqual(calls, inputs.count * 2); XCTAssertEqual(recoveries, inputs.count)
        XCTAssertEqual(ownDisagreements, 0, "recovery must preserve the trained model's own-glyph decisions")
        let report: [String: Any] = ["inputs": inputs.count, "inputs_sha256": inputsSHA256,
            "gold_sha256": SHA256.hash(data: goldBytes).map { String(format: "%02x", $0) }.joined(),
            "checkpoint_sha256": model.checkpointSHA256, "binary_sha256": model.binarySHA256,
            "vocabulary_sha256": model.vocabularySHA256, "identity_verified": identityVerified, "gold_shapes_verified": shapesVerified,
            "injected_invalid_coreml_calls": calls,
            "reference_recoveries": recoveries, "glyphs": glyphs, "own_disagreements": ownDisagreements,
            "all_disagreements": allDisagreements, "max_absolute_logit_error": maxError,
            "passed": identityVerified && shapesVerified && calls == inputs.count * 2 && recoveries == inputs.count && ownDisagreements == 0,
            "scope": "fault injection through production recovery policy and real frozen weights; not a measured whole-import failure rate"]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: paths.report), options: .atomic)
    }
}

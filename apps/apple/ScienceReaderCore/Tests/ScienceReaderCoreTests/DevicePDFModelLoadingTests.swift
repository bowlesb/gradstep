import CoreML
import Foundation
import XCTest
@testable import ScienceReaderCore

@available(macOS 15.0, iOS 18.0, *)
final class DevicePDFModelLoadingTests: XCTestCase {
    func testOnlyKnownCoreMLServiceErrorsBecomeBoundedRetryableFailures() {
        let cases: [(Int, DevicePDFModelAccessFailure)] = [(8, .keyUnavailable), (9, .decryptionFailed), (10, .serviceUnavailable)]
        for (code, expected) in cases {
            let error = NSError(domain: MLModelErrorDomain, code: code,
                                userInfo: [NSLocalizedDescriptionKey: "https://private-key-server.invalid/path?secret=private"])
            XCTAssertEqual(DevicePDFModels.accessFailure(error), expected)
            XCTAssertEqual(DevicePDFModels.accessFailure(NSError(domain: "wrapper", code: 1,
                                                                 userInfo: [NSUnderlyingErrorKey: error])), expected)
            XCTAssertEqual(DevicePDFModels.accessFailure(DevicePDFModelError.access(expected)), expected)
            XCTAssertFalse(expected.message.contains("private"))
            XCTAssertTrue(expected.message.lowercased().contains("try again"))
            XCTAssertTrue(expected.message.contains("internet for first use"))
            XCTAssertTrue(expected.message.contains("still on this device"))
            XCTAssertLessThan(expected.message.count, 200)
        }
        XCTAssertNil(DevicePDFModels.accessFailure(NSError(domain: "unrelated", code: 8)))
        XCTAssertNil(DevicePDFModels.accessFailure(NSError(domain: MLModelErrorDomain, code: 3)))
    }

    func testOrdinaryRecognizerErrorsRetainCPUAndImageFallbacks() async throws {
        var calls: [MLComputeUnits] = []
        let (model, issue) = try await DevicePDFModels.recogniserWithFallback(units: .cpuAndGPU) { units in
            calls.append(units)
            if units != .cpuOnly { throw DevicePDFModelError.unusable("unsupported") }
            return 7
        }
        XCTAssertEqual(calls, [.cpuAndGPU, .cpuOnly]); XCTAssertEqual(model, 7); XCTAssertNil(issue)
        calls = []
        let (absent, finalIssue): (Int?, String?) = try await DevicePDFModels.recogniserWithFallback(units: .cpuAndGPU) { units in
            calls.append(units); throw DevicePDFModelError.unusable("unsupported")
        }
        XCTAssertEqual(calls, [.cpuAndGPU, .cpuOnly]); XCTAssertNil(absent); XCTAssertEqual(finalIssue, "recogniser unsupported")
        calls = []
        let _: (Int?, String?) = try await DevicePDFModels.recogniserWithFallback(units: .cpuOnly) { units in
            calls.append(units); throw DevicePDFModelError.unusable("unsupported")
        }
        XCTAssertEqual(calls, [.cpuOnly])
    }

    func testKeyFailureNeverDowngradesToMissingRecognizerOrRetriesOnOtherUnits() async {
        for failOnCPU in [false, true] {
            var calls: [MLComputeUnits] = []
            do {
                let _: (Int?, String?) = try await DevicePDFModels.recogniserWithFallback(units: .cpuAndGPU) { units in
                    calls.append(units)
                    if failOnCPU && units != .cpuOnly { throw DevicePDFModelError.unusable("unsupported") }
                    throw NSError(domain: MLModelErrorDomain, code: 8)
                }
                XCTFail("A locked selected model cannot silently disappear")
            } catch {
                XCTAssertEqual(error as? DevicePDFModelError, .access(.keyUnavailable))
                XCTAssertEqual(calls, failOnCPU ? [.cpuAndGPU, .cpuOnly] : [.cpuAndGPU])
            }
        }
    }

    func testCancelledModelLoadDoesNotRetry() async {
        var calls = 0
        do {
            let _: (Int?, String?) = try await DevicePDFModels.recogniserWithFallback(units: .cpuAndGPU) { _ in
                calls += 1; throw CancellationError()
            }
            XCTFail("Cancelled loading must propagate")
        } catch { XCTAssertTrue(error is CancellationError); XCTAssertEqual(calls, 1) }

        for cancelBefore in [false, true] {
            for operationThrows in [false, true] {
                let task = Task {
                    if cancelBefore { withUnsafeCurrentTask { $0?.cancel() } }
                    var calls = 0
                    do {
                        let _: (Int?, String?) = try await DevicePDFModels.recogniserWithFallback(units: .cpuAndGPU) { _ in
                            calls += 1
                            await Task.yield()
                            withUnsafeCurrentTask { $0?.cancel() }
                            if operationThrows { throw NSError(domain: MLModelErrorDomain, code: 8) }
                            return 7
                        }
                        return false
                    } catch { return error is CancellationError && calls == (cancelBefore ? 0 : 1) }
                }
                let stopped = await task.value
                XCTAssertTrue(stopped, "Cancelled loading must neither accept a late model nor start CPU fallback")
            }
        }
    }

    func testProtectedPacksRequireRecognizerEvenWhenCallerDoesNotRequestStrictness() async {
        for (mode, required, shouldFail): (String?, Bool, Bool) in [(nil, false, false), ("development-plaintext", false, false),
                                                                  ("encrypted", false, true), (nil, true, true)] {
            var calls = 0
            do {
                let (model, issue): (Int?, String?) = try await DevicePDFModels.recogniserWithFallback(
                    units: .cpuAndGPU, required: required, protectionMode: mode) { _ in
                        calls += 1; throw DevicePDFModelError.unusable("unsupported")
                    }
                XCTAssertFalse(shouldFail); XCTAssertNil(model); XCTAssertEqual(issue, "recogniser unsupported")
            } catch {
                XCTAssertTrue(shouldFail)
                XCTAssertEqual(error as? DevicePDFModelError, .unusable("recogniser unavailable"))
            }
            XCTAssertEqual(calls, 2)
        }
    }

    func testCarrierPredictionCancellationBeforeDuringAndAfterAwaitIsPreserved() async {
        do {
            _ = try await DevicePDFModels.referenceCarrierOutput { throw CancellationError() }
            XCTFail("A cancelled carrier prediction must not become an unusable model")
        } catch { XCTAssertTrue(error is CancellationError) }

        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var called = false
            do {
                _ = try await DevicePDFModels.referenceCarrierOutput { called = true; return nil }
                return false
            } catch { return error is CancellationError && !called }
        }
        let stoppedBefore = await before.value
        XCTAssertTrue(stoppedBefore)

        for predictionThrows in [false, true] {
            let during = Task {
                do {
                    _ = try await DevicePDFModels.referenceCarrierOutput {
                        await Task.yield()
                        withUnsafeCurrentTask { $0?.cancel() }
                        if predictionThrows { throw NSError(domain: MLModelErrorDomain, code: 11) }
                        return MLFeatureValue(int64: 7)
                    }
                    return false
                } catch { return error is CancellationError }
            }
            let stoppedDuring = await during.value
            XCTAssertTrue(stoppedDuring, "Late success and framework cancellation must both preserve the stop")
        }
    }

    func testCarrierPredictionKeepsHealthyOutputAndBoundedNonCancellationFailures() async throws {
        let expected = MLFeatureValue(int64: 7)
        let actual = try await DevicePDFModels.referenceCarrierOutput { expected }
        XCTAssertTrue(actual === expected)
        for (error, expected): (Error, DevicePDFModelError) in [
            (NSError(domain: MLModelErrorDomain, code: 8), .access(.keyUnavailable)),
            (NSError(domain: "foreign", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://private.invalid/key"]),
             .unusable("tagger reference carrier"))
        ] {
            do {
                _ = try await DevicePDFModels.referenceCarrierOutput { throw error }
                XCTFail("Carrier failure must propagate")
            } catch { XCTAssertEqual(error as? DevicePDFModelError, expected) }
        }
    }

    func testCarrierWeightsAreExactLittleEndianFloat32InMemory() throws {
        let array = try MLMultiArray(shape: [299_249], dataType: .float32)
        array.withUnsafeMutableBytes { bytes, _ in bytes.initializeMemory(as: UInt8.self, repeating: 0) }
        array[0] = 1; array[1] = -2.5
        let data = try DevicePDFModels.referenceWeightData(array)
        XCTAssertEqual(data.count, 1_196_996)
        XCTAssertEqual(Array(data.prefix(8)), [0, 0, 128, 63, 0, 0, 32, 192])
        XCTAssertTrue(data.dropFirst(8).allSatisfy { $0 == 0 })
    }

    func testCarrierShapeTypeAndNonfiniteValuesFailBeforeReferenceInitialization() throws {
        XCTAssertThrowsError(try DevicePDFModels.referenceWeightData(nil))
        for array in [try MLMultiArray(shape: [299_249], dataType: .double),
                      try MLMultiArray(shape: [1, 299_249], dataType: .float32),
                      try MLMultiArray(shape: [299_248], dataType: .float32)] {
            XCTAssertThrowsError(try DevicePDFModels.referenceWeightData(array))
        }
        let array = try MLMultiArray(shape: [299_249], dataType: .float32)
        array.withUnsafeMutableBytes { bytes, _ in bytes.initializeMemory(as: UInt8.self, repeating: 0) }
        for invalid: Float in [.nan, .infinity, -.infinity] {
            array[299_248] = NSNumber(value: invalid)
            XCTAssertThrowsError(try DevicePDFModels.referenceWeightData(array))
        }
    }

    func testReferenceConfigurationSupportsCarrierWithoutPlaintextWeights() throws {
        let data = Data(#"{"manifest":"reference.json","manifest_sha256":"m","coreml_sha256":"c","weights_model":{"id":"carrier","file":"DeviceTaggerReference.mlmodelc","weights_sha256":"w"}}"#.utf8)
        let reference = try JSONDecoder().decode(DevicePDFModelConfiguration.Tagger.Reference.self, from: data)
        XCTAssertNil(reference.weights)
        XCTAssertEqual(reference.weightsModel?.file, "DeviceTaggerReference.mlmodelc")
    }

    func testEncryptedIntelPreflightDoesNotBlockPlaintextDevelopmentOrAppleSilicon() {
        XCTAssertThrowsError(try DevicePDFModels.validateProtection(mode: "encrypted", intelMac: true)) { error in
            XCTAssertEqual(error as? DevicePDFModelError, .unusable("encrypted PDF models require a Mac with Apple silicon"))
        }
        XCTAssertNoThrow(try DevicePDFModels.validateProtection(mode: nil, intelMac: true))
        XCTAssertNoThrow(try DevicePDFModels.validateProtection(mode: "development-plaintext", intelMac: true))
        XCTAssertNoThrow(try DevicePDFModels.validateProtection(mode: "encrypted", intelMac: false))
    }
}

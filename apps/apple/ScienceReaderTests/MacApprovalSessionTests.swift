#if targetEnvironment(macCatalyst)
import CryptoKit
import ScienceReaderCore
import Vision
import XCTest
@testable import ScienceReader

@MainActor
final class MacApprovalSessionTests: XCTestCase {
    private func payload() throws -> DeviceApprovalPayload {
        try DeviceApprovalPayload(requestID: UUID(), accountID: UUID(), deviceID: UUID(),
                                  publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                  challenge: ReaderCrypto.randomKey(), kind: .mac)
    }

    func testQRCodeRoundTripsTheFullMacPayload() throws {
        let payload = try payload()
        let image = try XCTUnwrap(MacApprovalQRCode.image(payload)?.cgImage)
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let decoded = try XCTUnwrap(request.results?.first?.payloadStringValue)
        XCTAssertEqual(decoded, payload.encoded)
        XCTAssertEqual(try DeviceApprovalPayload(scanned: decoded).kind, .mac)
    }

    func testPollingBacksOffRefreshesServerRequestAndStopsAtItsBound() async throws {
        let payload = try payload()
        var time: TimeInterval = 0
        var sleeps: [TimeInterval] = [], refreshTimes: [TimeInterval] = []
        let session = MacApprovalSession(duration: 125, now: { time }, sleep: { duration in
            sleeps.append(duration); time += duration
        })
        await session.run { refresh in
            if refresh { refreshTimes.append(time) }
            return payload
        }
        XCTAssertEqual(Array(sleeps.prefix(4)), [2, 3, 4.5, 6.75])
        XCTAssertTrue(sleeps.allSatisfy { $0 > 0 && $0 <= 10 })
        XCTAssertEqual(time, 125)
        XCTAssertEqual(refreshTimes.count, 2)
        XCTAssertGreaterThanOrEqual(refreshTimes[1] - refreshTimes[0], 60)
        guard case .paused = session.phase else { return XCTFail("A stopped poll must not keep offering a waiting QR") }
        XCTAssertFalse(session.running)
    }

    func testLateResultCannotOverwriteANewerApprovalSession() async throws {
        let payload = try payload()
        let session = MacApprovalSession()
        let arrived = expectation(description: "old request suspended")
        var pending: CheckedContinuation<DeviceApprovalPayload?, Never>?
        let old = Task {
            await session.run { _ in
                await withCheckedContinuation { continuation in pending = continuation; arrived.fulfill() }
            }
        }
        await fulfillment(of: [arrived], timeout: 2)
        session.stop()
        await session.run { _ in nil }
        pending?.resume(returning: payload)
        await old.value
        XCTAssertEqual(session.phase, .approved)
        XCTAssertFalse(session.running)
    }

    func testCancellationDoesNotPublishAWaitingRecipient() async throws {
        let payload = try payload()
        let session = MacApprovalSession()
        let arrived = expectation(description: "request suspended")
        var pending: CheckedContinuation<DeviceApprovalPayload?, Never>?
        let task = Task {
            await session.run { _ in
                await withCheckedContinuation { continuation in pending = continuation; arrived.fulfill() }
            }
        }
        await fulfillment(of: [arrived], timeout: 2)
        task.cancel()
        pending?.resume(returning: payload)
        await task.value
        XCTAssertEqual(session.phase, .preparing)
        XCTAssertFalse(session.running)
    }

    func testFailureUsesActionableCopyWithoutExposingTheError() async {
        let session = MacApprovalSession()
        await session.run { _ in throw NSError(domain: "private-response-body", code: 400) }
        guard case .paused(let message) = session.phase else { return XCTFail("A failed poll needs a retry action") }
        XCTAssertTrue(message.contains("connection"))
        XCTAssertFalse(message.contains("private-response-body"))
    }
}
#endif

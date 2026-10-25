#if DEBUG // SessionCapture is in Internal and Debug builds; this target has no INTERNAL flag
import XCTest
@testable import ScienceReader

/// The test-session recorder after the background (docs/SESSION_REVIEW.md; owner session 20261024-164759 on TestFlight 91:
/// the picture stopped at 0:16 when the app went to the background at 0:17, the sound ran on for 11 minutes). ReplayKit
/// does not run in the Simulator, so a stand-in recorder records what the session asks of it.
@MainActor
final class SessionVideoSegmentTests: XCTestCase {
    private final class FakeRecorder: SessionScreenRecording {
        var isAvailable = true
        var isMicrophoneEnabled = false
        var starts = 0
        var stops: [String] = []
        /// Start calls (1-based) that fail.
        var failingStarts: Set<Int> = []
        func startRecording() async throws {
            starts += 1
            if failingStarts.contains(starts) { throw NSError(domain: "RPRecordingErrorDomain", code: -5803) }
        }
        func stopRecording(withOutput url: URL) async throws {
            stops.append(url.lastPathComponent)
            try Data("video".utf8).write(to: url)
        }
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func events(_ capture: SessionCapture) throws -> [[String: String]] {
        let url = try XCTUnwrap(capture.directory).appendingPathComponent("timeline.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
    }

    func testReturningFromTheBackgroundStartsANewVideoAndLogsTheGap() async throws {
        let recorder = FakeRecorder()
        let capture = SessionCapture(recorder: recorder, root: root)
        await capture.start()
        XCTAssertEqual(capture.state, .recording)
        XCTAssertEqual(recorder.starts, 1)

        capture.appEnteredBackground()
        capture.appBecameActive()
        await capture.videoRestart?.value
        XCTAssertEqual(recorder.stops, ["screen.mp4"], "The first part is saved with everything before the background")
        XCTAssertEqual(recorder.starts, 2, "…and a new recording starts")
        XCTAssertFalse(capture.videoStopped)

        let logged = try events(capture)
        let gap = try XCTUnwrap(logged.first { $0["kind"] == "video_gap" })
        XCTAssertEqual(gap["resumed"], "1"); XCTAssertEqual(gap["segment"], "2"); XCTAssertEqual(gap["file"], "screen-2.mp4")
        XCTAssertLessThanOrEqual(try XCTUnwrap(Double(gap["from"] ?? "")), try XCTUnwrap(Double(gap["to"] ?? "")))
        XCTAssertTrue(logged.contains { $0["kind"] == "video_segment" && $0["phase"] == "end" && $0["segment"] == "1" })
        XCTAssertTrue(logged.contains { $0["kind"] == "video_segment" && $0["phase"] == "start" && $0["segment"] == "2" })
        XCTAssertTrue(logged.contains { $0["kind"] == "sync_band" && $0["on"] == "1" && $0["segment"] == "2" },
                      "The new part shows the sync band so the review lines it up")

        // A second trip to the background makes a third part; Stop saves the part being recorded.
        capture.appEnteredBackground(); capture.appBecameActive()
        await capture.videoRestart?.value
        await capture.stop()
        XCTAssertEqual(recorder.stops, ["screen.mp4", "screen-2.mp4", "screen-3.mp4"])
        XCTAssertNotNil(capture.share, "The session is packaged")
    }

    func testBecomingActiveWithoutLeavingTheAppKeepsTheVideo() async throws {
        let recorder = FakeRecorder()
        let capture = SessionCapture(recorder: recorder, root: root)
        await capture.start()
        // Control Center, a notification, the permission alert: inactive and back, never in the background.
        capture.appBecameActive()
        XCTAssertNil(capture.videoRestart)
        await capture.stop()
        XCTAssertEqual(recorder.stops, ["screen.mp4"]); XCTAssertEqual(recorder.starts, 1)
    }

    func testAVideoThatCannotRestartIsShownAsStopped() async throws {
        let recorder = FakeRecorder()
        recorder.failingStarts = [2]
        let capture = SessionCapture(recorder: recorder, root: root)
        await capture.start()
        capture.appEnteredBackground(); capture.appBecameActive()
        await capture.videoRestart?.value
        XCTAssertTrue(capture.videoStopped, "The strip shows the video stopped")
        XCTAssertNotNil(capture.issue)
        let gap = try XCTUnwrap(try events(capture).first { $0["kind"] == "video_gap" })
        XCTAssertEqual(gap["resumed"], "0")
        // Later returns don't try again with no recording running; Stop keeps the first part and the log.
        capture.appEnteredBackground(); capture.appBecameActive()
        XCTAssertNil(capture.videoRestart)
        await capture.stop()
        XCTAssertEqual(recorder.stops, ["screen.mp4"])
        XCTAssertNotNil(capture.share)
    }
}
#endif

import XCTest
import UIKit

/// Opt-in only, paired with the dedicated optimized resource-probe app target.
/// The runner never constructs the 4,000 rows, image or padded bundle. Raw app
/// phase readings are small JSON attachments; XCTest retains its application-
/// targeted CPU/memory metrics in xcresult. WebContent memory remains unknown.
@MainActor
final class OfflineResourcePerformanceTests: XCTestCase {
    private let paperID = "paper.cccccccc-4000-4000-8000-0000000036b0" // document(role: 1, row: 4,000)
    private let noMatchQuery = "zzresourceunmatched"
    private let expectedPayload = 33_554_432

    private enum Phase: Int { case restore = 1, publication, open, readerReady, search, figure }
    private struct Event: Decodable {
        let phase: Int
        let startMS: Double
        let elapsedMS: Double
        let count: Int?
        let startAppFootprintBytes: UInt64?
        let endAppFootprintBytes: UInt64?
        let appLifetimePeakBytes: UInt64?
    }
    private struct SettledFootprint: Decodable {
        let requestedOffsetMS: Int
        let elapsedMS: Double
        let appFootprintBytes: UInt64?
        let appLifetimePeakBytes: UInt64?
    }
    private struct Probe: Decodable {
        let format: Int
        let pid: Int32
        let mode: Int
        let rows: Int
        let installations: Int
        let ciphertextBytes: Int
        let expectedMemberBytes: Int
        let openedMemberBytes: Int?
        let debugAssertions: Bool
        let seeded: Bool
        let failure: Int
        let events: [Event]
        let searchSourceElapsedMS: Double?
        let searchWorkerElapsedMS: Double?
        let searchPublicationElapsedMS: Double?
        let restoreProjectionElapsedMS: Double?
        let settledStartMS: Double?
        let settledSamples: [SettledFootprint]?
        let webContentPeakBytes: UInt64?
        let appIntervalPeakBytes: UInt64?
        func event(_ phase: Phase) -> Event? { events.first { $0.phase == phase.rawValue } }
    }

    override func setUp() async throws {
        try await super.setUp()
        #if !targetEnvironment(simulator)
        throw XCTSkip("Resource fixtures are Simulator-only; this harness never operates a physical device.")
        #endif
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCIENCE_READER_RESOURCE_TESTS"] == "1",
                          "Opt-in resource measurements require the optimized Simulator resource-probe target.")
        continueAfterFailure = false
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
    }

    override func tearDown() async throws {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["SCIENCE_READER_RESOURCE_TESTS"] == "1" {
            await MainActor.run { XCUIApplication().terminate() }
        }
        #endif
        try await super.tearDown()
    }

    /// Empty persistent account control on the same app, runtime and simulator.
    /// This is reported alongside the maximum case, never blindly subtracted
    /// from a peak collected at a different instant or in another process.
    func testEmptyEncryptedLibraryRestorationBaseline() throws {
        let app = XCUIApplication()
        configure(app, mode: "empty")
        app.launch()
        _ = try require(app, phase: .restore, rows: 0)
        app.terminate()
        var invocation = 0
        measure(metrics: launchMetrics(app), options: options()) {
            configure(app, mode: "empty")
            startMeasuring()
            app.launch()
            let result = wait(app) { $0.event(.restore) != nil || $0.failure != 0 }
            stopMeasuring()
            attach(app, caseID: "empty-restore", invocation: invocation)
            assertRestored(result, rows: 0)
            app.terminate(); invocation += 1
        }
    }

    /// Measures normal decrypt/restore/model publication through first visible
    /// row. The full-library no-match search then runs through the real field;
    /// its request latency, worker time and main-actor publication are separate
    /// measurements. Worker latency is not a main-thread stall.
    func testMaximumLibraryRestorationAndNoMatchSearch() throws {
        let app = XCUIApplication()
        try seed(app)
        var invocation = 0
        measure(metrics: launchMetrics(app), options: options()) {
            configure(app, mode: "restore")
            startMeasuring()
            app.launch()
            let result = wait(app) { $0.event(.restore) != nil || $0.failure != 0 }
            let firstRow = app.buttons[paperID].waitForExistence(timeout: 20)
            stopMeasuring()
            attach(app, caseID: "maximum-restore", invocation: invocation)
            assertRestored(result, rows: 4_000)
            XCTAssertTrue(firstRow, "Restore must publish the normal Library row, without a fixture fallback.")
            XCTAssertEqual(result?.event(.publication)?.count, 4_000, "Record final MainActor application of the complete projection.")
            XCTAssertGreaterThan(result?.restoreProjectionElapsedMS ?? -1, 0,
                                 "Cache authentication/validation and author joining remain inside full restore.")

            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap(); search.typeText(noMatchQuery)
            let searched = wait(app) { $0.event(.search) != nil || $0.failure != 0 }
            XCTAssertTrue(app.staticTexts["No matching papers"].waitForExistence(timeout: 20))
            XCTAssertEqual(searched?.failure, 0)
            XCTAssertEqual(searched?.event(.search)?.count, 0, "Compute the real no-match result across all 4,000 rows.")
            XCTAssertEqual(searched?.rows, 4_000, "Searching cannot replace the complete cached presentation.")
            XCTAssertNotNil(searched?.searchSourceElapsedMS)
            XCTAssertGreaterThan(searched?.searchWorkerElapsedMS ?? 0, 0)
            XCTAssertNotNil(searched?.searchPublicationElapsedMS)
            attach(app, caseID: "maximum-no-match-search", invocation: invocation)
            app.terminate(); invocation += 1
        }
    }

    /// The measured launch includes the deliberate passive sampling window.
    /// Restore latency remains the original app phase, and these snapshots
    /// are neither interval peaks nor proof of stable retained memory.
    func testEmptyLibraryPostRestoreFootprintSamples() throws {
        let app = XCUIApplication()
        configure(app, mode: "empty")
        app.launch()
        _ = try require(app, phase: .restore, rows: 0)
        app.terminate()
        measureSettledFootprints(app, mode: "empty", rows: 0)
    }

    func testMaximumLibraryPostRestoreFootprintSamples() throws {
        let app = XCUIApplication()
        try seed(app)
        measureSettledFootprints(app, mode: "restore", rows: 4_000)
    }

    /// Restore outside the measured interval, then use the same row tap,
    /// synchronous input ownership, native verifier and WebKit readiness as
    /// ordinary reading. The 16M-pixel figure sheet is opened after measuring.
    func testMaximumInstalledBundleOpeningAndFigure() throws {
        let app = XCUIApplication()
        try seed(app)
        var invocation = 0
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options()) {
            configure(app, mode: "restore")
            app.launch()
            let restored = wait(app) { $0.event(.restore) != nil || $0.failure != 0 }
            assertRestored(restored, rows: 4_000)
            let row = app.buttons[paperID]
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            startMeasuring()
            row.tap()
            let opened = wait(app, timeout: 45) { $0.event(.readerReady) != nil || $0.failure != 0 }
            let web = app.webViews.firstMatch
            let rendered = web.staticTexts["Read the verified resource fixture"].waitForExistence(timeout: 10)
            stopMeasuring()
            attach(app, caseID: "maximum-open", invocation: invocation)
            XCTAssertEqual(opened?.failure, 0)
            XCTAssertEqual(opened?.openedMemberBytes, expectedPayload)
            XCTAssertEqual(opened?.event(.open)?.count, expectedPayload)
            XCTAssertNotNil(opened?.event(.readerReady))
            XCTAssertTrue(rendered, "The real verified renderer must finish; a generic empty WebView is insufficient.")
            XCTAssertFalse(app.staticTexts["Read this paper as its PDF"].exists)

            // Use the verified index and ordinary Contents sheet after the
            // opening interval; no programmatic DOM jump substitutes for it.
            app.buttons["Table of contents"].tap()
            let lastSection = app.buttons["Return to the reading context"]
            XCTAssertTrue(lastSection.waitForExistence(timeout: 5)); lastSection.tap()
            let lastHeading = web.staticTexts["Return to the reading context"]
            let arrived = NSPredicate { _, _ in
                lastHeading.exists && lastHeading.isHittable && lastHeading.frame.minY >= web.frame.minY - 2
                    && lastHeading.frame.maxY <= web.frame.maxY + 2
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: arrived, object: nil)], timeout: 5), .completed)
            app.buttons["Table of contents"].tap()
            let firstSection = app.buttons["Read the verified resource fixture"]
            XCTAssertTrue(firstSection.waitForExistence(timeout: 5)); firstSection.tap()
            let firstHeading = web.staticTexts["Read the verified resource fixture"]
            let returned = NSPredicate { _, _ in firstHeading.exists && firstHeading.isHittable }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5), .completed)

            let figure = web.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open figure: Resource figure with sixteen million pixels.")).firstMatch
            for _ in 0..<6 {
                if figure.exists, figure.isHittable { break }
                let below = !figure.exists || figure.frame.midY > web.frame.midY
                let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.7 : 0.4))
                let to = web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.4 : 0.7))
                from.press(forDuration: 0.05, thenDragTo: to)
            }
            XCTAssertTrue(figure.exists); XCTAssertTrue(figure.isHittable)
            figure.tap()
            // The figure sheet's X (DESIGN.md "Sheet top row").
            let done = app.buttons["sheet.close"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["Couldn’t open figure"].exists)
            let detail = app.webViews.element(boundBy: app.webViews.count - 1)
            let image = detail.images.firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 10))
            XCTAssertGreaterThan(image.frame.width, 40); XCTAssertGreaterThan(image.frame.height, 40)
            let notLoading = NSPredicate { _, _ in
                !app.staticTexts["Opening figure…"].exists && !app.progressIndicators["Opening figure…"].exists
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: notLoading, object: nil)], timeout: 10), .completed)
            XCTAssertFalse(app.staticTexts["Couldn’t open figure"].exists)
            if invocation == 1 {
                let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                capture.name = "16M-pixel encrypted fixture figure"; capture.lifetime = .keepAlways; add(capture)
            }
            done.tap()
            XCTAssertTrue(web.waitForExistence(timeout: 5))
            // A modal may hide RootView's probe from accessibility. Collect
            // the recorded figure event after dismissing the real sheet.
            let figureResult = wait(app, timeout: 10) { $0.event(.figure) != nil || $0.failure != 0 }
            XCTAssertEqual(figureResult?.failure, 0); XCTAssertNotNil(figureResult?.event(.figure))
            attach(app, caseID: "maximum-figure", invocation: invocation)
            app.terminate(); invocation += 1
        }
    }

    private func seed(_ app: XCUIApplication) throws {
        configure(app, mode: "seed")
        app.launch()
        // This generous setup limit is not a release-readiness latency budget.
        // It includes synthesizing/validating 2,048,000 author strings and
        // committing 128 MiB of metadata, outside every measured interval.
        let result = wait(app, timeout: 300) { $0.seeded || $0.failure != 0 }
        attach(app, caseID: "unmeasured-seed", invocation: 0)
        let probe = try XCTUnwrap(result)
        XCTAssertEqual(probe.failure, 0); XCTAssertTrue(probe.seeded)
        XCTAssertEqual(probe.rows, 4_000); XCTAssertEqual(probe.installations, 1)
        XCTAssertEqual(probe.expectedMemberBytes, expectedPayload)
        app.terminate()
    }

    private func configure(_ app: XCUIApplication, mode: String, settled: Bool = false) {
        app.launchArguments = ["--offline-resource-fixture", "--offline-resource-mode", mode]
        if settled { app.launchArguments.append("--offline-resource-settled") }
        // Root's isolated target owns its bundle identifier/configuration.
        // XCUIApplication() deliberately follows that target binding.
    }

    private func options() -> XCTMeasureOptions {
        let value = XCTMeasureOptions()
        value.iterationCount = 5
        value.invocationOptions = [.manuallyStart, .manuallyStop]
        return value
    }

    private func launchMetrics(_ app: XCUIApplication) -> [any XCTMetric] {
        [XCTClockMetric(), XCTApplicationLaunchMetric(waitUntilResponsive: true),
         XCTMemoryMetric(application: app), XCTCPUMetric(application: app)]
    }

    private func measureSettledFootprints(_ app: XCUIApplication, mode: String, rows: Int) {
        var invocation = 0
        measure(metrics: launchMetrics(app), options: options()) {
            configure(app, mode: mode, settled: true)
            startMeasuring()
            app.launch()
            // No selection, query, or other interaction is issued before all
            // four readings; only the small numeric status is observed.
            let result = wait(app) { $0.settledSamples?.count == 4 || $0.failure != 0 }
            stopMeasuring()
            attach(app, caseID: rows == 0 ? "empty-post-restore-samples" : "maximum-post-restore-samples",
                   invocation: invocation, settled: true)
            assertSettled(result, rows: rows)
            if rows > 0 {
                XCTAssertTrue(app.buttons[paperID].waitForExistence(timeout: 5),
                              "The complete library must remain normally visible after sampling.")
            }
            app.terminate(); invocation += 1
        }
    }

    private func raw(_ app: XCUIApplication) -> Data? {
        let status = app.staticTexts["offline.resource.status"]
        guard status.exists, let text = status.value as? String, let data = text.data(using: .utf8), data.count <= 16_384 else { return nil }
        return data
    }

    private func wait(_ app: XCUIApplication, timeout: TimeInterval = 45, until predicate: @escaping (Probe) -> Bool) -> Probe? {
        var latest: Probe?
        let ready = NSPredicate { _, _ in
            guard let data = self.raw(app), let probe = try? JSONDecoder().decode(Probe.self, from: data),
                  probe.format == 4, probe.events.count <= 6, (probe.settledSamples?.count ?? 0) <= 4 else { return false }
            latest = probe
            return predicate(probe)
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: timeout)
        XCTAssertEqual(result, .completed, "A missing phase is a failed run, not zero latency or empty data.")
        return latest
    }

    private func require(_ app: XCUIApplication, phase: Phase, rows: Int) throws -> Probe {
        let value = try XCTUnwrap(wait(app) { $0.event(phase) != nil || $0.failure != 0 })
        assertRestored(value, rows: rows)
        return value
    }

    private func assertRestored(_ value: Probe?, rows: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value?.failure, 0, file: file, line: line)
        XCTAssertEqual(value?.debugAssertions, false, "Use the optimized measurement target; Debug timings are not comparable.", file: file, line: line)
        XCTAssertEqual(value?.rows, rows, file: file, line: line)
        XCTAssertEqual(value?.installations, rows == 0 ? 0 : 1, file: file, line: line)
        XCTAssertEqual(value?.expectedMemberBytes, rows == 0 ? 0 : expectedPayload, file: file, line: line)
        XCTAssertEqual(value?.event(.restore)?.count, rows, file: file, line: line)
        if let projection = value?.restoreProjectionElapsedMS, let restore = value?.event(.restore) {
            XCTAssertTrue(projection.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(projection, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(projection, restore.elapsedMS,
                "The projection subphase must remain inside the unchanged full restore interval.", file: file, line: line)
        } else { XCTFail("Missing format-4 projection interval.", file: file, line: line) }
        XCTAssertNil(value?.openedMemberBytes, "Restoration must not hydrate the installed bundle.", file: file, line: line)
        XCTAssertNil(value?.webContentPeakBytes, "App-only metrics do not measure WebContent.", file: file, line: line)
        if rows > 0 { XCTAssertGreaterThan(value?.ciphertextBytes ?? 0, expectedPayload, file: file, line: line) }
    }

    private func assertSettled(_ value: Probe?, rows: Int, file: StaticString = #filePath, line: UInt = #line) {
        assertRestored(value, rows: rows, file: file, line: line)
        guard let value, let start = value.settledStartMS, let samples = value.settledSamples,
              let restore = value.event(.restore) else {
            XCTFail("Missing post-restore sample evidence.", file: file, line: line); return
        }
        XCTAssertTrue(start.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(start + 0.000_001, restore.startMS + restore.elapsedMS,
                                   "Sampling begins after the separate restoration phase.", file: file, line: line)
        XCTAssertEqual(samples.map(\.requestedOffsetMS), [0, 250, 500, 1_000], file: file, line: line)
        var previousElapsed = -1.0
        for sample in samples {
            XCTAssertTrue(sample.elapsedMS.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(sample.elapsedMS, Double(sample.requestedOffsetMS), file: file, line: line)
            XCTAssertGreaterThan(sample.elapsedMS, previousElapsed, file: file, line: line)
            XCTAssertNotNil(sample.appFootprintBytes, "An unavailable metric is not a zero-footprint success.", file: file, line: line)
            XCTAssertGreaterThan(sample.appFootprintBytes ?? 0, 0, file: file, line: line)
            previousElapsed = sample.elapsedMS
        }
        XCTAssertNil(value.event(.open), file: file, line: line)
        XCTAssertNil(value.event(.readerReady), file: file, line: line)
        XCTAssertNil(value.event(.search), "This journey does not issue a no-match query.", file: file, line: line)
        XCTAssertNil(value.event(.figure), file: file, line: line)
        XCTAssertNil(value.appIntervalPeakBytes, "XCTest retains the actual interval peak separately.", file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, caseID: String, invocation: Int, settled: Bool = false) {
        guard let data = raw(app), let probe = try? JSONSerialization.jsonObject(with: data) else {
            XCTFail("Missing raw resource measurements for \(caseID)"); return
        }
        var value: [String: Any] = ["format": 1, "case": caseID, "invocation": invocation,
            "xctest_discards_first_interval": true, "app_probe": probe,
            "xctest_interval_cpu_and_memory": "See the unmodified application-targeted xcresult measurements.",
            "webcontent_peak_bytes": NSNull(), "physical_device_acceptance": false,
            "provisional_review_budgets_ms": ["restore": 5_000, "open_plus_webkit": 3_000,
                "publication": 100, "search_source_main_actor": 100, "search_publication_main_actor": 100],
            "budgets_are_acceptance_claims": false,
            "runtime": ProcessInfo.processInfo.operatingSystemVersionString]
        if settled {
            value["measurement_window"] = "Launch through four passive post-restore samples; includes the requested 1000 ms sampling window."
            value["restore_latency"] = "The unchanged restore app phase; not the launch-through-samples clock."
            value["samples_are_peaks_or_stability_proof"] = false
            value["offline_restore_only"] = true
            value["live_cache_save_exercised"] = false
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), encoded.count <= 32_768 else {
            XCTFail("Invalid resource measurement attachment"); return
        }
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "offline-resource-\(caseID)-\(invocation).json"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

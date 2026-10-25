import XCTest
@testable import ScienceReaderCore

/// Settings › Experimental › On-device PDF reader as one row (owner, TestFlight 91 session, 2026-10-24): off by default,
/// never shown on while the model is not on this device, turning it on asks before a download, the row shows the
/// download's progress and the toggle comes on when it finishes; a failure or Cancel leaves it off.
final class DeviceModelReaderSettingTests: XCTestCase {
    typealias Setting = DeviceModelReaderSetting

    // MARK: The starting preference

    func testOffByDefaultWhereTheModelWasNeverDownloaded() {
        XCTAssertFalse(Setting.initialPreference(stored: nil, files: .missing, downloadedBefore: false),
                       "The owner's case: the old default was on with nothing downloaded")
        XCTAssertFalse(Setting.initialPreference(stored: nil, files: .unavailable, downloadedBefore: false))
    }

    func testExistingInstallsWithTheModelStayOn() {
        XCTAssertTrue(Setting.initialPreference(stored: true, files: .ready(bundled: false), downloadedBefore: true))
        // The old default (never stored) with the model downloaded: the download was offered only with the reader on.
        XCTAssertTrue(Setting.initialPreference(stored: nil, files: .ready(bundled: false), downloadedBefore: true))
        // A model update removed the old version and the new one is on its way: still the reader's choice.
        XCTAssertTrue(Setting.initialPreference(stored: nil, files: .missing, downloadedBefore: true))
        XCTAssertTrue(Setting.initialPreference(stored: true, files: .missing, downloadedBefore: true))
    }

    func testAnExplicitChoiceIsKept() {
        XCTAssertFalse(Setting.initialPreference(stored: false, files: .ready(bundled: false), downloadedBefore: true))
        XCTAssertTrue(Setting.initialPreference(stored: true, files: .ready(bundled: true), downloadedBefore: false), "The Mac, turned on")
        XCTAssertTrue(Setting.initialPreference(stored: true, files: .missing, downloadedBefore: false),
                      "On without the model: Settings shows it off, a paper still offers the download")
    }

    func testTheMacIsOffUntilTurnedOn() {
        XCTAssertFalse(Setting.initialPreference(stored: nil, files: .ready(bundled: true), downloadedBefore: false))
    }

    // MARK: What the row shows

    func testTheRowIsNeverOnWithoutTheModel() {
        for files: DeviceModelFiles in [.missing, .unavailable, .failed("The download stopped.")] {
            guard case .toggle(let on, _) = Setting.row(preference: true, files: files) else { return XCTFail("\(files)") }
            XCTAssertFalse(on, "\(files)")
        }
        XCTAssertEqual(Setting.row(preference: true, files: .ready(bundled: false)), .toggle(on: true, note: nil))
        XCTAssertEqual(Setting.row(preference: false, files: .ready(bundled: false)), .toggle(on: false, note: nil))
        XCTAssertEqual(Setting.row(preference: true, files: .ready(bundled: true)), .toggle(on: true, note: nil))
    }

    func testTheRowShowsProgressWhileDownloadingAndTheFailureAfter() {
        XCTAssertEqual(Setting.row(preference: true, files: .downloading(0.37)), .downloading(0.37))
        XCTAssertEqual(Setting.row(preference: false, files: .failed("Not enough free space on this device for the model.")),
                       .toggle(on: false, note: "Not enough free space on this device for the model."))
    }

    // MARK: Moving the toggle

    func testTurningOnWithoutTheModelAsksFirstAndChangesNothing() {
        XCTAssertEqual(Setting.toggled(to: true, files: .missing).command, .askToDownload)
        XCTAssertNil(Setting.toggled(to: true, files: .missing).preference, "Off until Download is chosen")
        XCTAssertEqual(Setting.toggled(to: true, files: .failed("x")).command, .askToDownload, "A failed download can be tried again")
    }

    func testTurningOnWithTheModelIsImmediate() {
        let mac = Setting.toggled(to: true, files: .ready(bundled: true))
        XCTAssertEqual(mac.preference, true); XCTAssertEqual(mac.command, DeviceModelReaderCommand.none, "The Mac: toggle only")
        let downloaded = Setting.toggled(to: true, files: .ready(bundled: false))
        XCTAssertEqual(downloaded.preference, true); XCTAssertEqual(downloaded.command, DeviceModelReaderCommand.none)
    }

    func testTurningOffCancelsADownloadOrRemovesTheDownloadedModel() {
        let downloading = Setting.toggled(to: false, files: .downloading(0.5))
        XCTAssertEqual(downloading.preference, false); XCTAssertEqual(downloading.command, .cancelDownload)
        let downloaded = Setting.toggled(to: false, files: .ready(bundled: false))
        XCTAssertEqual(downloaded.preference, false); XCTAssertEqual(downloaded.command, .removeDownloadedModels)
        let mac = Setting.toggled(to: false, files: .ready(bundled: true))
        XCTAssertEqual(mac.preference, false); XCTAssertEqual(mac.command, DeviceModelReaderCommand.none, "The Mac's own copy stays")
    }

    func testADownloadThatEndsWithoutTheModelLeavesItOff() {
        XCTAssertTrue(Setting.preferenceAfterDownload(files: .ready(bundled: false)))
        XCTAssertFalse(Setting.preferenceAfterDownload(files: .failed("The download stopped. Check the connection and try again.")))
        XCTAssertFalse(Setting.preferenceAfterDownload(files: .missing), "Cancelled")
    }

    /// The whole journey through the pure rules: off → ask → Download → progress → on → off.
    func testAJourney() {
        var preference = Setting.initialPreference(stored: nil, files: .missing, downloadedBefore: false)
        var files = DeviceModelFiles.missing
        XCTAssertEqual(Setting.row(preference: preference, files: files), .toggle(on: false, note: nil))
        XCTAssertEqual(Setting.toggled(to: true, files: files).command, .askToDownload)
        // Download chosen: the reader wants it; the system downloads.
        preference = true; files = .downloading(0.1)
        XCTAssertEqual(Setting.row(preference: preference, files: files), .downloading(0.1))
        files = .ready(bundled: false); preference = Setting.preferenceAfterDownload(files: files)
        XCTAssertEqual(Setting.row(preference: preference, files: files), .toggle(on: true, note: nil))
        let off = Setting.toggled(to: false, files: files)
        XCTAssertEqual(off.command, .removeDownloadedModels)
        preference = off.preference ?? preference; files = .missing
        XCTAssertEqual(Setting.row(preference: preference, files: files), .toggle(on: false, note: nil))
    }
}

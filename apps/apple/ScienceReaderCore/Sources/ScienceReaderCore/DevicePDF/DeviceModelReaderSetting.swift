import Foundation

/// Where the on-device PDF models are, as Settings sees them (the app's `DeviceModelAssets` reports it).
public enum DeviceModelFiles: Equatable, Sendable {
    /// This build has neither models nor a pack to download.
    case unavailable
    /// A separate download (iPhone, iPad) not on this device.
    case missing
    /// 0…1.
    case downloading(Double)
    /// Downloaded here, or `bundled` inside the app (the Mac).
    case ready(bundled: Bool)
    /// The last download failed, in the reader's words.
    case failed(String)
}

/// What Settings › Experimental shows for the on-device PDF reader: one row.
public enum DeviceModelReaderRow: Equatable, Sendable {
    /// The switch, with the last download's failure under the title.
    case toggle(on: Bool, note: String?)
    /// The download's progress in place of the switch, with Cancel.
    case downloading(Double)
}

/// What moving the switch asks of the app.
public enum DeviceModelReaderCommand: Equatable, Sendable {
    case none
    /// "Download the on-device PDF reader?" with its size, Download and Cancel.
    case askToDownload
    case cancelDownload
    /// Turned off: the downloaded models go (they were the reason it was on). The Mac's copy inside the app stays.
    case removeDownloadedModels
}

/// The on-device PDF reader's one Settings row (owner, TestFlight 91 session, 2026-10-24: *"I would just have it be off
/// by default, and then if you turn it on… a pop-up saying download the PDF reader… then it starts downloading. I don't
/// think you need to use 2 rows"*; docs/DECISIONS.md "One row for the on-device PDF reader"). The stored preference is
/// the reader's choice; the row is on only when that choice is on and the models are on this device, so it is never
/// "on but not downloaded".
public enum DeviceModelReaderSetting {
    /// The preference at launch. Nothing stored (the earlier default was on): on only where the models were downloaded
    /// here, since the download was offered only with the reader on. An explicit choice is kept.
    public static func initialPreference(stored: Bool?, files: DeviceModelFiles, downloadedBefore: Bool) -> Bool {
        if let stored { return stored }
        if case .ready(bundled: false) = files { return true }
        return downloadedBefore
    }

    public static func row(preference: Bool, files: DeviceModelFiles) -> DeviceModelReaderRow {
        switch files {
        case .downloading(let fraction): .downloading(fraction)
        case .ready: .toggle(on: preference, note: nil)
        case .failed(let message): .toggle(on: false, note: message)
        case .missing, .unavailable: .toggle(on: false, note: nil)
        }
    }

    /// The reader moved the switch: the new preference (nil: unchanged) and what the app does.
    public static func toggled(to on: Bool, files: DeviceModelFiles) -> (preference: Bool?, command: DeviceModelReaderCommand) {
        if on {
            switch files {
            case .ready, .downloading: return (true, .none)
            case .missing, .failed: return (nil, .askToDownload)
            case .unavailable: return (nil, .none)
            }
        }
        switch files {
        case .downloading: return (false, .cancelDownload)
        case .ready(bundled: false): return (false, .removeDownloadedModels)
        default: return (false, .none)
        }
    }

    /// After a download chosen in Settings: on only if the models arrived (a failure or Cancel leaves it off).
    public static func preferenceAfterDownload(files: DeviceModelFiles) -> Bool {
        if case .ready = files { return true }
        return false
    }
}

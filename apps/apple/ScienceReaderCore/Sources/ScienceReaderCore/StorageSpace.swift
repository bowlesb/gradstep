import CSQLite
import Darwin
import Foundation

/// The device's disk being full, told apart from every other storage failure (docs/reviews/OFFLINE_AND_STORAGE_20261025.md).
/// A full disk is the reader's to fix (free some space) and says how much is needed; any other write failure keeps
/// its own wording. Nothing here deletes anything: what is already on the device stays readable.
public enum StorageSpace {
    /// Room kept free beyond what a write needs, so the write doesn't leave the device with nothing (and SQLite's
    /// journal, the system and other apps keep working): 50 MB.
    public static let margin: Int64 = 50 * 1024 * 1024

    /// Whether this error is the disk (or the account's quota) being full: a Foundation file write, a POSIX write,
    /// SQLite, a URLSession download that couldn't write its file, or an On-Demand Resources download.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        if error is StorageFullError { return true }
        if let failure = error as? DatabaseFailure { return failure.code & 0xff == SQLITE_FULL }
        if let posix = error as? POSIXError { return posix.code == .ENOSPC || posix.code == .EDQUOT }
        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain:
            // 640 NSFileWriteOutOfSpaceError; 4992 NSBundleOnDemandResourceOutOfSpaceError.
            if ns.code == NSFileWriteOutOfSpaceError || ns.code == 4992 { return true }
        case NSPOSIXErrorDomain:
            if ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT) { return true }
        default: break
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, (underlying as NSError) !== ns { return isOutOfSpace(underlying) }
        return false
    }

    /// Bytes free for important work on the volume holding `url` (or its nearest existing parent); nil when unknown.
    public static func available(at url: URL) -> Int64? {
        var probe = url
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: probe.path) { break }
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // The important-usage figure counts purgeable space the system would free for us; the Mac's plain volumes and
        // some disk images report it as zero, so the plain figure is the fallback.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Refuses a write of about `bytes` before it starts when the volume can't hold it with `margin` to spare. Unknown
    /// free space never refuses (the write itself still fails cleanly when the disk fills).
    public static func ensure(_ bytes: Int64, at url: URL, margin: Int64 = StorageSpace.margin) throws {
        guard let free = available(at: url) else { return }
        let needed = max(0, bytes) + margin
        if free < needed { throw StorageFullError(needed: needed - free) }
    }

    /// The error for a write of `bytes` to `url` that failed because the disk is full: how much more it needs, from the
    /// space free now (at least the write itself when that can't be read).
    public static func fullError(writing bytes: Int64, at url: URL) -> StorageFullError {
        let free = available(at: url) ?? 0
        return StorageFullError(needed: max(bytes - free, 0) + min(bytes, margin) / 4 + 1)
    }

    /// "12 MB"
    public static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file) }

    /// One line, with how much to free when known.
    public static func message(needing bytes: Int64? = nil) -> String {
        guard let bytes, bytes > 0 else { return "This device is out of space. Free up some space and try again." }
        return "This device is out of space. Free up \(size(roundedUp(bytes))) and try again."
    }

    /// The message for a failed write: the full-disk line when it is one, else nil (the caller keeps its own wording).
    public static func message(for error: Error) -> String? {
        guard isOutOfSpace(error) else { return nil }
        return message(needing: (error as? StorageFullError)?.needed)
    }

    /// To a figure worth reading: 1.2 MB → 2 MB, 340 MB → 340 MB.
    static func roundedUp(_ bytes: Int64) -> Int64 {
        let mb: Int64 = 1_000_000
        return bytes < mb ? mb : ((bytes + mb - 1) / mb) * mb
    }
}

/// A write refused (or failed) because the disk is full; `needed` is how many more bytes would let it through.
public struct StorageFullError: Error, Equatable, Sendable, LocalizedError {
    public let needed: Int64?
    public init(needed: Int64? = nil) { self.needed = needed }
    public var errorDescription: String? { StorageSpace.message(needing: needed) }
}

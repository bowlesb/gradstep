import Foundation

/// A real, small APFS volume for out-of-space tests (docs/reviews/OFFLINE_AND_STORAGE_20261025.md): `hdiutil` makes a
/// disk image in the temporary folder, attaches it at a private mount point (never shown in the Finder), and detaches
/// and deletes it afterwards. Writes into `root` really fail with ENOSPC / SQLITE_FULL once it fills. Unavailable (nil)
/// where `hdiutil` can't run, so a test skips instead of failing.
final class SmallDisk {
    let root: URL
    private let image: URL
    private let folder: URL

    init?(megabytes: Int = 20) {
        #if os(macOS)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gs-small-disk-" + UUID().uuidString.prefix(8))
        let image = folder.appendingPathComponent("disk.dmg"), mount = folder.appendingPathComponent("volume")
        do { try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true) } catch { return nil }
        guard Self.run(["create", "-size", "\(megabytes)m", "-fs", "APFS", "-volname", "GSFull", "-type", "UDIF", "-layout", "NONE", image.path]),
              Self.run(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path]) else {
            try? FileManager.default.removeItem(at: folder); return nil
        }
        self.folder = folder; self.image = image; self.root = mount
        #else
        return nil
        #endif
    }

    deinit { detach() }

    func detach() {
        #if os(macOS)
        guard FileManager.default.fileExists(atPath: image.path) else { return }
        if !Self.run(["detach", root.path]) { _ = Self.run(["detach", "-force", root.path]) }
        try? FileManager.default.removeItem(at: folder)
        #endif
    }

    /// Fills the volume with a filler file until fewer than `leaving` bytes are free (APFS keeps a little back).
    @discardableResult
    func fill(leaving: Int64 = 0, name: String = "filler") -> URL {
        let filler = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: filler) else { return filler }
        defer { try? handle.close() }
        let chunk = Data(repeating: 0x5a, count: 256 * 1024), small = Data(repeating: 0x5a, count: 4096)
        while (freeBytes ?? 0) > leaving + Int64(chunk.count) { if (try? handle.write(contentsOf: chunk)) == nil { break } }
        while (freeBytes ?? 0) > leaving + Int64(small.count) { if (try? handle.write(contentsOf: small)) == nil { break } }
        try? handle.synchronize()
        return filler
    }

    /// Frees what `fill` took.
    func release(_ filler: URL) { try? FileManager.default.removeItem(at: filler); sync() }

    var freeBytes: Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    #if os(macOS)
    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    #endif
}

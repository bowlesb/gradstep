import Foundation

/// A staff test catalog made from a folder of PDFs (docs/architecture/TEST_CATALOGS.md): every PDF in the folder is added
/// to the library on this device, filed in a catalog named after the folder, then read by the on-device model one at a
/// time. This is the queue's state: what each file is waiting for, in order, and whether it is paused. It survives a
/// relaunch (sealed on this device; never synced) so the readings resume where they stopped.
public struct TestCatalogQueue: Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        /// Chosen from the folder; not yet added to the library.
        case toImport
        /// In the library (in this catalog); not yet read by the model.
        case toRead
        /// Being read now. A relaunch puts it back to `toRead`.
        case reading
        /// Read: the model's reading is kept on this device.
        case read
        /// Left alone, with the reason (already in the library elsewhere, a duplicate in the folder, removed).
        case skipped(String)
        /// Could not be added or read, with the reason; the rest carry on. Importing the folder again retries it.
        case failed(String)

        var isOpen: Bool { self == .toImport || self == .toRead || self == .reading }
    }

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: String { sha256 }
        /// The file's name in the folder.
        public let name: String
        /// Lowercase hex SHA-256 of the file's bytes: how a file already in the library is recognised.
        public let sha256: String
        public var status: Status
        public init(name: String, sha256: String, status: Status) { self.name = name; self.sha256 = sha256; self.status = status }
    }

    /// Where a file from the folder already is.
    public enum Placement: Equatable, Sendable {
        /// Not in the library.
        case absent
        /// In the library and in this catalog; `read` when the model's reading of it is kept.
        case inCatalog(read: Bool)
        /// In the library in another catalog: never moved or read, so the test leaves the reader's own papers alone.
        case elsewhere
    }

    public enum Step: Equatable, Sendable {
        case add(Item)
        case read(Item)
    }

    public static let currentFormat = 1
    public var format = Self.currentFormat
    /// The catalog the files are filed in (named after the folder).
    public let catalogID: UUID
    public var catalogName: String
    /// The folder, so files not yet added can still be read after a relaunch (a security-scoped bookmark).
    public var folderBookmark: Data?
    public private(set) var items: [Item]
    public private(set) var paused: Bool

    public init(catalogID: UUID, catalogName: String, folderBookmark: Data? = nil, items: [Item] = [], paused: Bool = false) {
        self.catalogID = catalogID; self.catalogName = catalogName; self.folderBookmark = folderBookmark
        self.items = items; self.paused = paused
    }

    /// Only staff (operator roles: the owner, support) see the action and its progress.
    public static func isAvailable(operatorRoles: [String]) -> Bool {
        operatorRoles.contains { ["owner", "support"].contains($0) }
    }

    /// Adds a folder's PDFs (any order; listed by name). Idempotent: a file already queued keeps its place, and its status
    /// is brought up to date from where it is now (importing the folder again is how to retry a failure). A file already in
    /// the library is matched by its content, never added twice: in this catalog it is only read (if it isn't yet);
    /// elsewhere it is skipped. Two files with the same bytes are one paper (the first by name).
    public mutating func merge(files: [(name: String, sha256: String)], placement: (String) -> Placement) {
        let sorted = files.map { (name: $0.name, sha256: $0.sha256.lowercased()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var seen = Set<String>()
        for file in sorted where seen.insert(file.sha256).inserted {
            let fresh: Status = switch placement(file.sha256) {
            case .absent: .toImport
            case .inCatalog(let read): read ? .read : .toRead
            case .elsewhere: .skipped("Already in your library in another catalog")
            }
            if let index = items.firstIndex(where: { $0.sha256 == file.sha256 }) {
                // The file being read now carries on; any other takes where it is now.
                if items[index].status != .reading { items[index].status = fresh }
            } else {
                items.append(Item(name: file.name, sha256: file.sha256, status: fresh))
            }
        }
    }

    /// What to do next: every file is added first (while the folder is at hand), then each is read in order. Nil when
    /// paused, when something is being read, or when nothing is left.
    public var next: Step? {
        guard !paused, !items.contains(where: { $0.status == .reading }) else { return nil }
        if let item = items.first(where: { $0.status == .toImport }) { return .add(item) }
        if let item = items.first(where: { $0.status == .toRead }) { return .read(item) }
        return nil
    }

    public mutating func set(_ sha256: String, _ status: Status) {
        guard let index = items.firstIndex(where: { $0.sha256 == sha256 }) else { return }
        items[index].status = status
    }

    public func status(_ sha256: String) -> Status? { items.first { $0.sha256 == sha256 }?.status }

    /// Pause stops after (or interrupts) the current reading; that file is read again on Resume.
    public mutating func pause() {
        paused = true
        for index in items.indices where items[index].status == .reading { items[index].status = .toRead }
    }
    public mutating func resume() { paused = false }

    /// After a relaunch (or a sign-out mid-reading): the reading that was under way starts again.
    public mutating func relaunched() {
        for index in items.indices where items[index].status == .reading { items[index].status = .toRead }
    }

    /// The files this test covers (not those skipped).
    public var total: Int { items.filter { if case .skipped = $0.status { return false }; return true }.count }
    public var readCount: Int { items.filter { $0.status == .read }.count }
    public var failures: [Item] { items.filter { if case .failed = $0.status { return true }; return false } }
    public var skipped: [Item] { items.filter { if case .skipped = $0.status { return true }; return false } }
    /// Settled: every file read, failed or skipped.
    public var isFinished: Bool { !items.contains { $0.status.isOpen } }
    var settledCount: Int { readCount + failures.count }

    /// The one progress line ("Reading 7 of 36 with the on-device model").
    public var line: String {
        let total = total
        if total == 0 { return skipped.isEmpty ? "No PDFs in this folder" : "Nothing new to read in this folder" }
        if isFinished { return "Done · \(readCount) of \(total) read" }
        let position = min(total, settledCount + 1)
        if paused { return "Paused · \(readCount) of \(total) read" }
        if let adding = items.firstIndex(where: { $0.status == .toImport }) {
            let added = items[..<adding].filter { if case .skipped = $0.status { return false }; return true }.count
            return "Adding \(min(total, added + 1)) of \(total) to the library"
        }
        return "Reading \(position) of \(total) with the on-device model"
    }
}

/// The queue on this device: one small file sealed with the account's local-store key in the account's folder (removed
/// with it), never synced or uploaded.
public struct TestCatalogQueueStore: Sendable {
    public static let name = "queue"
    private let files: SealedCacheFiles

    public init(directory: URL, accountID: UUID, localKey: Data) throws {
        files = try SealedCacheFiles(directory: directory, accountID: accountID, localKey: localKey, namespace: "test-catalogs")
    }

    /// The saved queue as it should resume: a reading under way when the app stopped starts again.
    public func load() -> TestCatalogQueue? {
        guard let data = files.read(Self.name), var queue = try? JSONDecoder().decode(TestCatalogQueue.self, from: data),
              queue.format == TestCatalogQueue.currentFormat else { return nil }
        queue.relaunched()
        return queue
    }

    public func save(_ queue: TestCatalogQueue?) throws {
        guard let queue else { try? FileManager.default.removeItem(at: files.directory.appendingPathComponent(Self.name + ".sealed")); return }
        try files.write(try JSONEncoder().encode(queue), as: Self.name)
    }
}

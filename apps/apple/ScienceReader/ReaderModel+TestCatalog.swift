import CryptoKit
import Foundation
import ScienceReaderCore
#if DEBUG && FIXTURE_HOST
import UIKit
#endif

/// Settings › Experimental › "Import a folder as a test catalog" (staff only; docs/architecture/TEST_CATALOGS.md, owner
/// 2026-10-28: "a catalog … with maybe 30-40 random neuroscience pdf papers preloaded into the library with the on device
/// model"). Every PDF in a chosen folder is added through the ordinary local-PDF path (checked, kept encrypted on this
/// device, never uploaded), filed in a catalog named after the folder, then read by the on-device model one at a time
/// while the app is open. The queue (TestCatalogQueue) is sealed on this device and resumes after a relaunch. Other
/// catalogs and papers are never moved, re-added or read.
extension ReaderModel {
    /// Staff only (operator roles), in builds that carry the on-device model.
    var showsTestCatalogTools: Bool { TestCatalogQueue.isAvailable(operatorRoles: operatorRoles) && DeviceModelEngine.available }

    /// The model is on (chosen) and on this device.
    private var testCatalogModelReady: Bool { deviceModelAvailable && deviceModelReady }

    /// The row's button: the model first (the usual "Download the on-device PDF reader?" when it isn't here; tap again once
    /// it is), then the folder picker.
    func beginTestCatalogImport() {
        guard showsTestCatalogTools, canManageCatalogs else { return }
        if !testCatalogModelReady {
            setDeviceModelReader(true)
            guard testCatalogModelReady else { return }
        }
        #if DEBUG && FIXTURE_HOST
        if let folder = TestCatalogFixture.folder() { Task { await importTestCatalogFolder(folder, securityScoped: false) }; return }
        #endif
        testCatalogPicking = true
    }

    /// The chosen folder: its PDFs are listed and fingerprinted, the catalog is found (this queue's, else one with the
    /// folder's name) or created, and the queue takes every file not yet in the library (re-importing skips those that
    /// are, by content).
    func importTestCatalogFolder(_ folder: URL, securityScoped: Bool = true) async {
        guard showsTestCatalogTools, canManageCatalogs else { return }
        let scope = sessionID
        testCatalogWaiting = nil
        // A folder inside the app's own files needs no grant (the call then says no); any other picked folder does.
        let scoped = securityScoped && folder.startAccessingSecurityScopedResource()
        // Files are added from this folder during this session; a bookmark finds it again after a relaunch.
        releaseTestCatalogFolder()
        testCatalogFolder = folder; testCatalogFolderScoped = scoped
        let bookmark = Self.testCatalogBookmark(folder)
        let name = LibraryCatalogBatch.normalizedName(folder.lastPathComponent) ?? "Test PDFs"
        let files = await Task.detached(priority: .userInitiated) { Self.testCatalogFiles(in: folder) }.value
        guard sessionID == scope else { return }
        guard !files.isEmpty else {
            testCatalogWaiting = securityScoped && !scoped ? "Gradstep couldn’t open that folder." : "No PDFs in that folder."
            return
        }
        let catalogID: UUID
        if let queue = testCatalog, queue.catalogName.caseInsensitiveCompare(name) == .orderedSame, libraryCatalogs.catalog(queue.catalogID) != nil {
            catalogID = queue.catalogID
        } else if let existing = libraryCatalogs.catalogs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            catalogID = existing.id
        } else {
            do { catalogID = try await createCatalog(name) }
            catch { if sessionID == scope { testCatalogWaiting = "Couldn’t create the catalog “\(name)”." }; return }
        }
        guard sessionID == scope else { return }
        let kept = await testCatalogReadings()
        guard sessionID == scope else { return }
        if testCatalog?.catalogID != catalogID {
            // One test catalog at a time: a new folder takes the queue over (the earlier catalog and its papers stay).
            stopTestCatalogWorker()
            testCatalog = TestCatalogQueue(catalogID: catalogID, catalogName: name)
        }
        guard var queue = testCatalog else { return }
        queue.catalogName = name
        queue.folderBookmark = bookmark ?? queue.folderBookmark
        queue.merge(files: files) { self.testCatalogPlacement($0, catalogID: catalogID, kept: kept) }
        queue.resume()
        testCatalog = queue
        localPersistence.saveTestCatalog(queue)
        if libraryCatalogs.catalog(catalogID) != nil { selectCatalog(catalogID) }
        runTestCatalog()
    }

    func pauseTestCatalog() {
        guard var queue = testCatalog else { return }
        queue.pause()
        testCatalog = queue
        localPersistence.saveTestCatalog(queue)
        stopTestCatalogWorker()
        testCatalogWaiting = nil
    }

    func resumeTestCatalog() {
        guard var queue = testCatalog else { return }
        if !testCatalogModelReady { setDeviceModelReader(true) }
        queue.resume()
        testCatalog = queue
        localPersistence.saveTestCatalog(queue)
        testCatalogWaiting = nil
        runTestCatalog()
    }

    /// After activation: the saved queue comes back, and carries on (staff only) unless it was paused or is done.
    func restoreTestCatalog() {
        guard testCatalog == nil, let store = localPersistence.testCatalogStore, let queue = store.load() else { return }
        // Its catalog was deleted since: the test is over (the next folder imported replaces the saved queue).
        guard libraryCatalogs.catalog(queue.catalogID) != nil else { return }
        testCatalog = queue
        guard !queue.isFinished, !queue.paused else { return }
        let scope = sessionID
        Task { [weak self] in
            guard let self else { return }
            await self.refreshOperatorRoles()
            guard self.sessionID == scope, self.showsTestCatalogTools else { return }
            self.runTestCatalog()
        }
    }

    /// The model finished downloading: a queue that waited for it carries on.
    func testCatalogModelArrived() {
        guard testCatalogWaiting != nil, testCatalogModelReady, testCatalog?.paused == false else { return }
        testCatalogWaiting = nil
        runTestCatalog()
    }

    /// Sign-out: the worker stops; the queue stays saved for this account's next session.
    func stopTestCatalog() {
        stopTestCatalogWorker()
        releaseTestCatalogFolder()
        testCatalog = nil; testCatalogWaiting = nil; testCatalogPicking = false
    }

    // MARK: The worker

    func runTestCatalog() {
        guard testCatalogWorker == nil, let queue = testCatalog, queue.next != nil else { return }
        let worker = UUID(), scope = sessionID
        testCatalogWorker = worker
        testCatalogTask = Task { [weak self] in
            await self?.workTestCatalog(worker: worker, scope: scope)
            guard let self, self.testCatalogWorker == worker else { return }
            self.testCatalogWorker = nil; self.testCatalogTask = nil
            if self.testCatalog?.items.contains(where: { $0.status == .toImport }) != true { self.releaseTestCatalogFolder() }
        }
    }

    private func stopTestCatalogWorker() {
        testCatalogWorker = nil
        testCatalogTask?.cancel(); testCatalogTask = nil
        // Only the reading the queue started stops; a reading the reader started stays.
        if let run = testCatalogRunID, deviceModelRun?.id == run { cancelDeviceModelReading() }
        testCatalogRunID = nil
    }

    private func current(_ worker: UUID, _ scope: UUID) -> Bool { testCatalogWorker == worker && sessionID == scope && !Task.isCancelled }

    private func workTestCatalog(worker: UUID, scope: UUID) async {
        while current(worker, scope), let queue = testCatalog, let step = queue.next {
            switch step {
            case .add(let item):
                await addTestCatalogFile(item, catalogID: queue.catalogID, worker: worker, scope: scope)
            case .read(let item):
                guard testCatalogModelReady else { testCatalogWaiting = "Waiting for the on-device model (turn it on above)"; return }
                // A reading the reader started themselves finishes first.
                while deviceModelRun != nil {
                    try? await Task.sleep(for: .seconds(1))
                    guard current(worker, scope) else { return }
                }
                await readTestCatalogFile(item, catalogID: queue.catalogID, worker: worker, scope: scope)
            }
        }
    }

    private func setTestCatalog(_ sha256: String, _ status: TestCatalogQueue.Status, worker: UUID, scope: UUID) {
        guard testCatalogWorker == worker, sessionID == scope, var queue = testCatalog else { return }
        queue.set(sha256, status)
        testCatalog = queue
        localPersistence.saveTestCatalog(queue)
    }

    /// One file: checked and kept on this device as a paper of the library, filed in the test catalog.
    private func addTestCatalogFile(_ item: TestCatalogQueue.Item, catalogID: UUID, worker: UUID, scope: UUID) async {
        let kept = await testCatalogReadings()
        guard current(worker, scope) else { return }
        // Added meanwhile (or before a relaunch cut this short): never twice.
        switch testCatalogPlacement(item.sha256, catalogID: catalogID, kept: kept) {
        case .absent: break
        case .inCatalog(let read): setTestCatalog(item.sha256, read ? .read : .toRead, worker: worker, scope: scope); return
        case .elsewhere: setTestCatalog(item.sha256, .skipped("Already in your library in another catalog"), worker: worker, scope: scope); return
        }
        guard let folder = testCatalogFolderURL() else {
            setTestCatalog(item.sha256, .failed("The folder isn’t available any more. Import it again to add this file."), worker: worker, scope: scope)
            return
        }
        let file = folder.appendingPathComponent(item.name)
        // A file named like a title ("Author 2007 - Short title.pdf") names the paper; otherwise the PDF's own title does.
        let stem = (item.name as NSString).deletingPathExtension
        let named = stem.split(separator: " ").count >= 3 ? stem : nil
        do {
            let checked = try await Task.detached(priority: .userInitiated) { try PDFFileCheck.check(file, title: named, fallback: stem) }.value
            guard current(worker, scope) else { return }
            guard checked.sha256 == item.sha256 else {
                setTestCatalog(item.sha256, .failed("This file changed after the folder was chosen. Import the folder again."), worker: worker, scope: scope)
                return
            }
            if let paper = testCatalogPaperWithoutPDF(title: checked.title, pages: checked.pages, catalogID: catalogID), let sourceID = paper.sourceID {
                // Added from this folder on another device (the catalog syncs, the PDF never does): this device keeps the
                // same paper's PDF instead of adding it twice.
                let write = try localPersistence.acceptLocalPaperWrite {
                    try await $0.install(pdfAt: file, sourceID: sourceID, revision: 1, expectedSHA256: Data(hex: checked.sha256))
                }
                _ = try await write.value
                await refreshLocalPaperRecords()
            } else {
                try await installLocalPDF(file, checked: checked, target: .newPaper, catalogID: catalogID)
            }
            setTestCatalog(item.sha256, .toRead, worker: worker, scope: scope)
        } catch is CancellationError {
        } catch {
            let reason = (error as? PDFFileProblem)?.message ?? StorageSpace.message(for: error)
                ?? ((error as? LocalPaperStoreError) == .capacityExceeded ? "This device’s space for added PDFs is full." : nil)
                ?? "This PDF couldn’t be added on this device."
            setTestCatalog(item.sha256, .failed(reason), worker: worker, scope: scope)
        }
    }

    /// One reading by the on-device model, kept on this device (it opens at once from the paper's "Read with the on-device
    /// model"). A failure is recorded with its reason and the queue moves on.
    private func readTestCatalogFile(_ item: TestCatalogQueue.Item, catalogID: UUID, worker: UUID, scope: UUID) async {
        guard let record = localPaperRecords.first(where: { $0.identity.sha256.hex == item.sha256 }),
              let paper = testCatalogPaper(record) else {
            setTestCatalog(item.sha256, .skipped("No longer in your library"), worker: worker, scope: scope)
            return
        }
        guard libraryCatalogs.catalogID(for: catalogKey(paper)) == catalogID else {
            setTestCatalog(item.sha256, .skipped("Moved to another catalog"), worker: worker, scope: scope)
            return
        }
        guard #available(iOS 18.0, *), let pdfStore = localPersistence.localPaperStore,
              let source = try? DevicePDFPaper(sourceID: record.identity.sourceID, revision: record.identity.revision) else {
            setTestCatalog(item.sha256, .failed("The on-device model can’t read PDFs on this device."), worker: worker, scope: scope)
            return
        }
        if await testCatalogHasReading(source) { setTestCatalog(item.sha256, .read, worker: worker, scope: scope); return }
        guard current(worker, scope) else { return }
        setTestCatalog(item.sha256, .reading, worker: worker, scope: scope)
        let identity = record.identity
        let outcome: DeviceModelOutcome = await withCheckedContinuation { continuation in
            testCatalogRunID = startDeviceModelRun(paper, source: source, again: false, load: { try await pdfStore.read(identity) }) { outcome in
                continuation.resume(returning: outcome)
            }
        }
        // Paused (or signed out) meanwhile: Pause already put this file back to be read again.
        guard testCatalogWorker == worker, sessionID == scope else { return }
        testCatalogRunID = nil
        switch outcome {
        case .read:
            let kept = await testCatalogHasReading(source)
            setTestCatalog(item.sha256, kept ? .read : .failed("Read, but the reading couldn’t be kept on this device."), worker: worker, scope: scope)
        case .failed(let reason):
            setTestCatalog(item.sha256, .failed(reason), worker: worker, scope: scope)
        case .cancelled:
            // Stop on the paper's own bar ends this paper only; the queue carries on.
            setTestCatalog(item.sha256, .failed("Stopped before it finished."), worker: worker, scope: scope)
        }
    }

    // MARK: Where a file already is

    /// The library paper a PDF on this device belongs to (an added PDF, or an arXiv paper's downloaded PDF).
    private func testCatalogPaper(_ record: LocalPaperRecord) -> Paper? {
        papers.first { !$0.isSample && $0.isLocalPDF && $0.sourceID == record.identity.sourceID }
            ?? papers.first { !$0.isSample && !$0.isLocalPDF && localPDFRecord(for: $0)?.identity == record.identity }
    }

    /// The queue read this paper (its reading is kept on this device), so it opens even while another paper is read.
    func testCatalogHasKeptReading(_ paper: Paper) -> Bool {
        guard let queue = testCatalog, !paper.isSample, let record = localPDFRecord(for: paper) else { return false }
        return queue.status(record.identity.sha256.hex) == .read
    }

    /// A PDF paper of this catalog whose PDF isn't on this device (it was added on another device), by the title and page
    /// count an import of the same file gives it.
    private func testCatalogPaperWithoutPDF(title: String, pages: Int, catalogID: UUID) -> Paper? {
        papers.first { paper in
            paper.isLocalPDF && !paper.isSample && paper.title == title && paper.pageCount == pages
                && libraryCatalogs.catalogID(for: catalogKey(paper)) == catalogID && localPDFRecord(for: paper) == nil
        }
    }

    func testCatalogPlacement(_ sha256: String, catalogID: UUID, kept: Set<String>) -> TestCatalogQueue.Placement {
        for record in localPaperRecords where record.identity.sha256.hex == sha256 {
            guard let paper = testCatalogPaper(record) else { continue }
            guard libraryCatalogs.catalogID(for: catalogKey(paper)) == catalogID else { return .elsewhere }
            return .inCatalog(read: kept.contains(Self.readingKey(record.identity.sourceID, record.identity.revision)))
        }
        return .absent
    }

    private static func readingKey(_ sourceID: String, _ revision: Int) -> String { "\(sourceID)#\(revision)" }

    /// The sources the on-device model's readings kept on this device are of.
    private func testCatalogReadings() async -> Set<String> {
        #if DEBUG && FIXTURE_HOST
        if DeviceModelFixture.fakesReading { return Set(fakeModelReadings.map { Self.readingKey($0, 1) }) }
        #endif
        let records = await localPersistence.modelReaderStore?.records() ?? []
        return Set(records.map { Self.readingKey($0.identity.sourceID, $0.identity.revision) })
    }

    private func testCatalogHasReading(_ source: DevicePDFPaper) async -> Bool {
        await testCatalogReadings().contains(Self.readingKey(source.sourceID, source.revision))
    }

    // MARK: The folder

    /// The folder chosen this session, else the one its bookmark finds after a relaunch.
    private func testCatalogFolderURL() -> URL? {
        if let testCatalogFolder { return testCatalogFolder }
        guard let bookmark = testCatalog?.folderBookmark else { return nil }
        var stale = false
        #if targetEnvironment(macCatalyst)
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        guard let folder = (try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)) else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        testCatalogFolder = folder; testCatalogFolderScoped = scoped
        return folder
    }

    /// A bookmark to the chosen folder (security-scoped, read-only, on the Mac; iOS's document-picker bookmarks carry their
    /// scope). Nil when the system won't make one: files not yet added then ask for the folder again after a relaunch.
    private static func testCatalogBookmark(_ folder: URL) -> Data? {
        #if targetEnvironment(macCatalyst)
        if let scoped = try? folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        #endif
        return try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func releaseTestCatalogFolder() {
        if testCatalogFolderScoped { testCatalogFolder?.stopAccessingSecurityScopedResource() }
        testCatalogFolder = nil; testCatalogFolderScoped = false
    }

    /// The folder's PDFs (not its subfolders or hidden files) with each file's SHA-256, read in chunks.
    nonisolated static func testCatalogFiles(in folder: URL) -> [(name: String, sha256: String)] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { url in
            guard url.pathExtension.lowercased() == "pdf", (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return (name: url.lastPathComponent, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}

#if DEBUG && FIXTURE_HOST
/// `--test-catalog-fixture` (UI journeys): the button imports a generated folder instead of opening the picker: three
/// small papers drawn on the device and one damaged file, so the catalog, the queue and a listed failure can be driven
/// without Files.
enum TestCatalogFixture {
    static let folderName = "Neuroscience test PDFs"
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--test-catalog-fixture") }

    /// Made once per launch: importing it again within a launch finds the same bytes.
    @MainActor private static var made: URL?

    @MainActor static func folder() -> URL? {
        guard isEnabled else { return nil }
        if let made { return made }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("test-catalog-fixture", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        made = folder
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let papers = [("Hartley 2014 - Place cells and grid cells in a navigating rat", "Place cells and grid cells"),
                      ("Okafor 2019 - Dopamine prediction errors in the striatum", "Dopamine prediction errors"),
                      ("Lindqvist 2022 - Working memory capacity in prefrontal circuits", "Working memory capacity")]
        for (name, title) in papers {
            try? pdf(title: title).write(to: folder.appendingPathComponent(name + ".pdf"))
        }
        try? Data("%PDF-1.4\nnot really a PDF\n".utf8).write(to: folder.appendingPathComponent("Broken 2001 - A damaged file.pdf"))
        return folder
    }

    private static func pdf(title: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            let body = UIFont(name: "Times New Roman", size: 10) ?? .systemFont(ofSize: 10)
            let paragraph = "Neurons in this circuit change their firing with experience; we record them across sessions and model the "
                + "population with a simple rate equation. "
            for page in 0..<2 {
                context.beginPage()
                if page == 0 {
                    (title as NSString).draw(in: CGRect(x: 90, y: 72, width: 432, height: 30),
                                             withAttributes: [.font: UIFont(name: "Times New Roman Bold", size: 17) ?? .boldSystemFont(ofSize: 17)])
                }
                (String(repeating: paragraph, count: 12) as NSString).draw(in: CGRect(x: 72, y: 130, width: 468, height: 560), withAttributes: [.font: body])
            }
        }
    }
}
#endif

import CoreML
import Foundation
import UIKit
import ScienceReaderCore

/// A reading by the on-device model in progress (docs/architecture/DEVICE_PDF_ROUTE.md): the layout of every page
/// first, then the pages in order, each with its formulas.
struct DeviceModelRun: Equatable {
    /// This run, apart from a later one of the same paper: a cancelled run's late cleanup must not end the next.
    let id = UUID()
    let paperID: UUID
    let started: Date
    var pages = 0, layoutPages = 0, pagesRead = 0
    /// Formulas read so far of those found so far: the recogniser reads them in the background while the pages are
    /// read (docs/reviews/DEVICE_PDF_ROUTE_20261021.md), so the total grows until the last page is read.
    var formulasDone = 0, formulasTotal = 0
    /// The paper is on screen already, every formula as its image, while the formulas are read.
    var previewShown = false
    /// 0…1: the layout pass is the first 15 %, reading the pages the next 25 %, the formulas the rest.
    var fraction: Double {
        guard pages > 0 else { return 0 }
        if layoutPages < pages { return 0.15 * Double(layoutPages) / Double(pages) }
        let read = min(1, Double(pagesRead) / Double(pages))
        let formulas = formulasTotal > 0 ? Double(formulasDone) / Double(formulasTotal) * (read < 1 ? read : 1) : (read < 1 ? 0 : 1)
        return min(1, 0.15 + 0.25 * read + 0.6 * formulas)
    }
    var stageText: String {
        if pages == 0 { return "Loading the models…" }
        if layoutPages < pages { return "Finding the layout · page \(layoutPages) of \(pages)" }
        if pagesRead < pages { return "Reading page \(min(pages, pagesRead + 1)) of \(pages)" }
        if formulasTotal > 0, formulasDone < formulasTotal {
            return previewShown ? "Typesetting formulas · \(formulasDone) of \(formulasTotal)" : "Formulas \(formulasDone) of \(formulasTotal)"
        }
        return "Finishing"
    }
}

/// What one model reading did, for its banner and a report (counts and times only, never the paper's text).
struct DeviceModelSummary: Equatable, Sendable {
    let pages: Int
    let seconds: Double
    let equations: Int
    let rendered: Int
    let figures: Int
    let warnings: [String]
    let models: String
    let hostSeconds: [String: Double]
    /// The formula model could not load on this device (every formula is then an image of the page).
    var recogniserUnavailable = false

    var line: String {
        let time = seconds >= 90 ? "\(Int(seconds / 60)) min \(Int(seconds) % 60) s" : "\(Int(seconds.rounded())) s"
        let formulas: String
        if equations == 0 { formulas = "no formulas found" }
        else if recogniserUnavailable { formulas = "formulas shown as images (the formula model can’t run on this device)" }
        else { formulas = "\(rendered) of \(equations) formulas typeset, the rest shown as images" }
        return "\(pages) \(pages == 1 ? "page" : "pages") in \(time) · \(formulas)"
    }
    var diagnostics: String {
        var lines = ["On-device model reading (experimental): \(line); \(figures) figures.", "Models: \(models)."]
        if !hostSeconds.isEmpty { lines.append("Seconds: " + hostSeconds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ".") }
        if recogniserUnavailable { lines.append("The formula model did not load on this device.") }
        if !warnings.isEmpty { lines.append("Warnings: " + warnings.prefix(8).joined(separator: "; ") + ".") }
        return lines.joined(separator: "\n")
    }
}

/// Loads the models and the converter once per reading and runs the route off the main thread.
enum DeviceModelEngine {
    /// The models for this run: the verified download (iPhone, iPad), the app's own copy (Mac), or a folder named by
    /// `GRADSTEP_DEVICE_MODELS` (tests on this Mac); nil until the models are downloaded (DeviceModelAssets).
    static var modelsDirectory: URL? { DeviceModelAssets.locate()?.directory }
    static var compilerURL: URL? { Bundle.main.url(forResource: "device-pdf-reader", withExtension: "js") }
    /// The converter rules beyond the port kit, each turned on after it was measured against the arXiv HTML of real
    /// papers (docs/reviews/DEVICE_PDF_ROUTE_20261021.md; DevicePDFRoute.Options.rules).
    /// On (2026-10-21): simple inline formulas from the text layer (`transcribe`) and math the tagger missed found by its
    /// fonts (`fontMath`); LaTeXML-style rows tidied for Temml (`tidy`); the title page by the library's metadata
    /// (`frontMatter`); no heading twice (`headingDupes`); reference entries split (`splitReferences`); a line's run read
    /// by one region (`lineOwners`). Off, because they measured worse: `extendSpans`.
    /// On (2026-10-23, also measured on publishers' PDFs: docs/reviews/DEVICE_PDF_ROUTE_20261023.md): captions keep their
    /// math (`captionMath`); a display's number left out of its crop and shown as its tag (`equationNumbers`); overlapping
    /// display boxes read as one (`mergeDisplays`); a bibliography without a heading (`bibliography`); the venue's
    /// first-page notice dropped (`venueNotice`); a display's full stop kept (`displayPunctuation`); unknown fonts read as
    /// the ones they stand for (`fontAliases`); justified lines' narrow word gaps (`wordGaps`); TeX's text accents
    /// (`accents`); lines that do not merge through a script's box (`lineBands`). The display gate stays at 0.95.
    /// On (2026-10-24, docs/reviews/DEVICE_PDF_WEAKNESSES_20261024.md): a formula under the gate is typeset when its
    /// letters, digits, accents and operators are the page's own glyphs (`verifyGlyphs`, confidence 0.5 and up); a formula
    /// whose glyphs repeat an earlier one's takes its reading (`reuseRecognitions`, speed); ligatures as letters
    /// (`ligatures`); a compound's hyphen at a line's end kept when the paper prints the pair hyphenated (`compounds`); a
    /// glyph returning to the left below its line's own text starts a new line (`lineReturns`). Off: `displayLines` (a
    /// numbered display the layout read as a paragraph's line becomes a display; +0.01 displays found on all three corpora,
    /// but their typeset precision 0.004–0.006 lower).
    /// On (2026-10-24, docs/reviews/DEVICE_PDF_TABLES_20261024.md): table columns from the body's grid, so a spanning
    /// header no longer merges the columns under it (`tableColumns`); a wrapped table cell read line by line
    /// (`cellLines`); a table caption printed under its table follows it (`tableCaptionBelow`). Off: `narrowCellGaps`
    /// (cells apart at 0.45 glyph heights: wins on 5,285 labelled tables and the arXiv test corpus, ties dev, loses
    /// 0.003 cell F1 on venue PDFs).
    static let rules: Set<String> = ["transcribe", "fontMath", "tidy", "frontMatter", "headingDupes", "splitReferences", "lineOwners",
                                     "captionMath", "equationNumbers", "mergeDisplays", "bibliography", "venueNotice", "displayPunctuation",
                                     "fontAliases", "wordGaps", "accents", "lineBands", "verifyGlyphs", "reuseRecognitions", "ligatures",
                                     "compounds", "lineReturns", "tableColumns", "cellLines", "tableCaptionBelow"]
    /// The converter is in this build, the models are here or can be downloaded, and the system can run the stateful
    /// recogniser.
    static var available: Bool {
        guard #available(iOS 18.0, *) else { return false }
        guard compilerURL != nil else { return false }
        #if DEBUG && FIXTURE_HOST
        if DeviceModelAssets.downloadFixture != nil { return true }
        #endif
        if modelsDirectory != nil { return true }
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return DeviceModelAssets.packDescription != nil
        #endif
    }

    @available(iOS 18.0, *)
    /// `preview`: the reading before its formulas are read (each one its page image), verified like the final one; it
    /// arrives once, from a background thread, while the recogniser finishes.
    static func read(pdf: Data, name: String, title: String, authors: [String] = [], source: DevicePDFPaper,
                     progress: @escaping @Sendable (DevicePDFRoute.Stage) -> Void,
                     preview: @escaping @Sendable (VerifiedReaderBundle) -> Void = { _ in }) async throws -> (VerifiedReaderBundle, DeviceModelSummary) {
        guard let directory = modelsDirectory, let compilerURL else { throw DevicePDFModelError.missing("DeviceModels") }
        let start = Date()
        let task = Task.detached(priority: .userInitiated) { () async throws -> (VerifiedReaderBundle, DeviceModelSummary) in
            let models = try await DevicePDFModels.load(directory: directory)
            let route = DevicePDFRoute(models: models, compilerSource: try String(contentsOf: compilerURL, encoding: .utf8))
            var options = DevicePDFRoute.Options(title: title, sourceID: source.sourceID, revision: source.revision)
            options.authors = authors; options.rules = rules
            // Each recogniser batch in flight holds its own state (about 0.4 GB for a batch of 8): two only where memory is ample.
            options.recogniserConcurrency = ProcessInfo.processInfo.physicalMemory >= 7_500_000_000 ? 2 : 1
            options.onPreview = { output in
                guard let verified = try? VerifiedReaderBundle.verify(manifest: output.manifest, expectedSHA256: output.manifestSHA256, members: output.members),
                      let bundle = try? ReaderBundleLoader.admitImages(in: verified) else { return }
                preview(bundle)
            }
            let output = try route.convert(pdf: pdf, name: name, options: options, progress: progress, cancelled: { Task.isCancelled })
            let verified = try VerifiedReaderBundle.verify(manifest: output.manifest, expectedSHA256: output.manifestSHA256, members: output.members)
            let bundle = try ReaderBundleLoader.admitImages(in: verified)
            return (bundle, summary(output.summary, bundle: bundle, seconds: Date().timeIntervalSince(start), models: models))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    @available(iOS 18.0, *)
    static func summary(_ data: Data, bundle: VerifiedReaderBundle, seconds: Double, models: DevicePDFModels) -> DeviceModelSummary {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let int = { (key: String) -> Int? in (object[key] as? NSNumber)?.intValue }
        let host = (object["host_seconds"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let models = models.provenance.map { "\($0["role"] ?? "") \($0["id"] ?? "")" }.joined(separator: ", ")
        return DeviceModelSummary(pages: int("pages") ?? 0, seconds: seconds, equations: int("equations") ?? bundle.index.equations.count,
                                  rendered: int("rendered") ?? 0, figures: int("figures") ?? bundle.index.figures.count,
                                  warnings: object["warnings"] as? [String] ?? [], models: models, hostSeconds: host,
                                  recogniserUnavailable: object["recogniser_unavailable"] != nil)
    }
}

#if DEBUG && FIXTURE_HOST
/// Simulator journeys only (`--device-model-fixture`): a two-page paper drawn on the device stands in for the sample
/// paper's PDF, so the menu, progress, banner and the way back can be driven without an account's PDF store.
enum DeviceModelFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--device-model-fixture") }
    /// `--device-model-fake-reading`: a stand-in for the models (no Core ML on this Mac): each reading's bar moves through
    /// two pages and it finishes without a kept reading (TEST_CATALOGS.md journeys).
    static var fakesReading: Bool { ProcessInfo.processInfo.arguments.contains("--device-model-fake-reading") }
    /// `--device-model-fake-step-ms=<n>`: the pause between its steps (default 400 ms).
    static var fakeStepMilliseconds: Int {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--device-model-fake-step-ms=") }
            .flatMap { Int($0.dropFirst("--device-model-fake-step-ms=".count)) } ?? 400
    }
    static func pdf() -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            let body = UIFont(name: "Times New Roman", size: 10) ?? .systemFont(ofSize: 10)
            func draw(_ text: String, _ font: UIFont, _ rect: CGRect) { (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: UIColor.black]) }
            let bold = { (size: CGFloat) in UIFont(name: "Times New Roman Bold", size: size) ?? .boldSystemFont(ofSize: size) }
            let paragraph = "We study a simple objective and show that its gradient is well defined for every input. The method is easy to "
                + "implement and matches strong baselines on three benchmarks while using a fraction of their compute. "
            for n in 0..<2 {
                context.beginPage()
                var y: CGFloat = 72
                if n == 0 {
                    draw("A Synthetic Paper About Simple Objectives", bold(17), CGRect(x: 90, y: y, width: 432, height: 30)); y += 44
                    draw("Ada Example and Grace Sample", body, CGRect(x: 220, y: y, width: 300, height: 14)); y += 34
                    draw("Abstract", bold(11), CGRect(x: 286, y: y, width: 100, height: 16)); y += 20
                    draw(String(repeating: paragraph, count: 2), body, CGRect(x: 110, y: y, width: 392, height: 80)); y += 96
                }
                draw("\(n + 1)  \(n == 0 ? "Introduction" : "Method")", bold(12), CGRect(x: 72, y: y, width: 300, height: 18)); y += 26
                for _ in 0..<4 { draw(String(repeating: paragraph, count: 3), body, CGRect(x: 72, y: y, width: 468, height: 90)); y += 100 }
            }
        }
    }
}
#endif

extension ReaderModel {
    /// The PDF of this paper on this device, if any: an arXiv paper's by its revision (else any revision kept), a
    /// PDF the reader added by its local id.
    func localPDFRecord(for paper: Paper) -> LocalPaperRecord? {
        if paper.isLocalPDF, let id = paper.sourceID { return localPaperRecords.first { $0.identity.sourceID == id } }
        guard let source = paper.arxivReaderSource ?? paper.sourceID.flatMap({ id in paper.sourceRevision.flatMap { try? ArxivReaderSource(sourceID: id, revision: $0) } }) else { return nil }
        return localPaperRecords.first { $0.identity.sourceID == source.sourceID && $0.identity.revision == source.revision }
            ?? localPaperRecords.first { $0.identity.sourceID == source.sourceID }
    }
    /// The PDF page an on-device reading cut this figure from, when that PDF is on this device (FIGURE_VIEW.md "Zoom out
    /// onto the page"): the reading's own record of the crop, and the PDF found by its digest. Nil for any other reading,
    /// for one made before the crops were recorded (port revision 10), and when the PDF has been removed.
    func figurePDFPage(bundle: VerifiedReaderBundle, figureID: String) -> FigurePDFPage? {
        guard let region = bundle.devicePDFSource?.figures[figureID], let load = devicePDF(bundle: bundle) else { return nil }
        return FigurePDFPage(region: region, load: load)
    }
    /// How to read the PDF an on-device reading was made from, when it is on this device (found by its digest); nil for any
    /// other reading and when the PDF has been removed. Read only when asked (a zoom-out, Show in PDF), never sent anywhere.
    func devicePDF(bundle: VerifiedReaderBundle) -> (@Sendable () async throws -> Data)? {
        guard bundle.manifest.source.kind == "device-pdf", let source = bundle.devicePDFSource else { return nil }
        #if DEBUG && FIXTURE_HOST
        // `--figure-fixture-pdf=<path>`: the PDF a fixture reading was made from, read from this Mac.
        if let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--figure-fixture-pdf=") })?.dropFirst("--figure-fixture-pdf=".count) {
            let url = URL(fileURLWithPath: String(path))
            return { try Data(contentsOf: url) }
        }
        #endif
        guard let record = localPaperRecords.first(where: { $0.identity.sha256.hex == source.pdfSHA256 }),
              let store = localPersistence.localPaperStore else { return nil }
        let identity = record.identity
        return { try await store.read(identity) }
    }
    /// Show in PDF applies: the open reading is an on-device one whose PDF is still on this device.
    func canShowInPDF(_ bundle: VerifiedReaderBundle?) -> Bool { bundle.map { devicePDF(bundle: $0) != nil } ?? false }

    /// Show in PDF for a selection (FIGURE_VIEW.md "Show in PDF"): its text and the text around it, and where the reading
    /// says its blocks (and any equation in it) came from.
    func showInPDFRequest(bundle: VerifiedReaderBundle, selection: ReaderSelection) -> ShowInPDFRequest? {
        guard let source = bundle.devicePDFSource, let load = devicePDF(bundle: bundle), selection.manifestSHA256 == bundle.manifestSHA256 else { return nil }
        var blockIDs: [String] = []
        for part in selection.parts where !blockIDs.contains(part.blockID) { blockIDs.append(part.blockID) }
        // An equation part stands between words as a gap the approximate match allows for.
        let text = selection.parts.map { $0.kind == "text" ? ($0.text ?? "") : " " }.joined()
        let equationIDs = selection.parts.compactMap(\.equationID)
        let regions = blockIDs.flatMap { source.blocks[$0] ?? [] } + equationIDs.compactMap { source.equations[$0] }
        let isEquation = selection.parts.allSatisfy { $0.kind == "equation" }
        return ShowInPDFRequest(query: PDFPassageQuery(text: isEquation ? "" : text, before: selection.context?.prefix ?? "",
                                                       after: selection.context?.suffix ?? "", regions: regions),
                                blockFraction: blockIDs.first.flatMap { Self.blockFraction($0, in: bundle) },
                                subject: isEquation ? .equation : .text, load: load)
    }

    /// Show in PDF for a tapped equation: its own recorded box (its block's when it has none).
    func showEquationInPDFRequest(bundle: VerifiedReaderBundle, equationID: String) -> ShowInPDFRequest? {
        guard let source = bundle.devicePDFSource, let load = devicePDF(bundle: bundle) else { return nil }
        let blockID = bundle.index.equations.first { $0.id == equationID }?.blockID
        let regions = source.equations[equationID].map { [$0] } ?? blockID.flatMap { source.blocks[$0] } ?? []
        return ShowInPDFRequest(query: PDFPassageQuery(text: "", regions: regions), blockFraction: blockID.flatMap { Self.blockFraction($0, in: bundle) },
                                subject: .equation, load: load)
    }

    /// How far through the reading a block is (0…1): where to look first in a PDF whose reading recorded no places.
    private static func blockFraction(_ id: String, in bundle: VerifiedReaderBundle) -> Double? {
        guard let index = bundle.index.blocks.firstIndex(where: { $0.id == id }), bundle.index.blocks.count > 1 else { return nil }
        return Double(index) / Double(bundle.index.blocks.count - 1)
    }
    var deviceModelAvailable: Bool { deviceModelReader && DeviceModelEngine.available }

    // MARK: Settings › Experimental › On-device PDF reader (one row; DeviceModelReaderSetting)

    /// What the row shows now.
    var deviceModelReaderRow: DeviceModelReaderRow {
        DeviceModelReaderSetting.row(preference: deviceModelReader, files: deviceModelAssets.files)
    }

    /// The row's switch: on asks before a download when the models are not here; off cancels a download or removes the
    /// downloaded models (a model reading in progress stops first).
    func setDeviceModelReader(_ on: Bool) {
        let (preference, command) = DeviceModelReaderSetting.toggled(to: on, files: deviceModelAssets.files)
        if let preference { deviceModelReader = preference }
        switch command {
        case .none: break
        case .askToDownload: deviceModelDownloadQuestion = true
        case .cancelDownload:
            dismissDeviceModelDownload()
        case .removeDownloadedModels:
            if deviceModelRun != nil { cancelDeviceModelReading() }
            deviceModelDownloadPaperID = nil
            deviceModelAssets.remove()
        }
    }

    /// "Download the on-device PDF reader?" › Download: the models download (the row shows their progress) and the switch
    /// comes on when they are installed; a failure or Cancel leaves it off.
    func confirmDeviceModelDownload() {
        deviceModelDownloadQuestion = false
        deviceModelReader = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.deviceModelAssets.ensureDownloaded()
            self.deviceModelReader = DeviceModelReaderSetting.preferenceAfterDownload(files: self.deviceModelAssets.files)
            self.testCatalogModelArrived()
        }
    }
    /// Whether "Read with the on-device model" applies to this paper now.
    func canReadWithDeviceModel(_ paper: Paper) -> Bool {
        guard deviceModelAvailable else { return false }
        // While the test catalog's queue reads another paper, a reading it kept still opens (TEST_CATALOGS.md).
        if deviceModelRun != nil { return testCatalogHasKeptReading(paper) }
        #if DEBUG && FIXTURE_HOST
        if DeviceModelFixture.isEnabled, paper.isSample { return true }
        #endif
        return !paper.isSample && localPDFRecord(for: paper) != nil
    }
    /// Whether the paper's PDF is here for the model (the options menu offers it).
    func hasDeviceModelPDF(_ paper: Paper) -> Bool {
        #if DEBUG && FIXTURE_HOST
        if DeviceModelFixture.isEnabled, paper.isSample { return true }
        #endif
        return !paper.isSample && localPDFRecord(for: paper) != nil
    }
    func isModelReading(_ paper: Paper?) -> Bool { paper?.readerBundle?.manifest.source.kind == "device-pdf" }
    var shownDeviceModelSummary: DeviceModelSummary? {
        guard let bundle = selectedPaper?.readerBundle, bundle.manifest.source.kind == "device-pdf" else { return nil }
        return deviceModelSummaries[bundle.manifestSHA256]
    }
    /// For a report: what the model reading on screen did (counts, times, models); nil for any other reading.
    var deviceModelDiagnostics: String? {
        guard let bundle = selectedPaper?.readerBundle, bundle.manifest.source.kind == "device-pdf" else { return nil }
        return deviceModelSummaries[bundle.manifestSHA256]?.diagnostics
            ?? "On-device model reading (experimental) \(bundle.manifestSHA256.prefix(12)): \(bundle.index.blocks.count) blocks, \(bundle.index.equations.count) formulas, \(bundle.index.figures.count) figures."
    }

    /// Reads the paper's PDF on this device with the experimental models and shows the result in the reader; a
    /// reading kept from before opens at once unless `again`.
    func readWithDeviceModel(_ paper: Paper, again: Bool = false) {
        guard #available(iOS 18.0, *), canReadWithDeviceModel(paper) else { return }
        let load: () async throws -> Data
        let source: DevicePDFPaper
        #if DEBUG && FIXTURE_HOST
        if DeviceModelFixture.isEnabled, paper.isSample, let fixture = try? DevicePDFPaper(sourceID: "2305.18290", revision: 3) {
            source = fixture; load = { DeviceModelFixture.pdf() }
        } else {
            guard let record = localPDFRecord(for: paper), let pdfStore = localPersistence.localPaperStore,
                  let paperSource = try? DevicePDFPaper(sourceID: record.identity.sourceID, revision: record.identity.revision) else { return }
            source = paperSource; load = { try await pdfStore.read(record.identity) }
        }
        #else
        guard let record = localPDFRecord(for: paper), let pdfStore = localPersistence.localPaperStore,
              let paperSource = try? DevicePDFPaper(sourceID: record.identity.sourceID, revision: record.identity.revision) else { return }
        source = paperSource; load = { try await pdfStore.read(record.identity) }
        #endif
        let scope = sessionID
        deviceModelIssue = nil
        if paper.isLocalPDF, selectedPaper?.id != paper.id {
            // From a PDF the reader added (its own PDF view): the reading happens, and opens, in the reader.
            localPaperPresentation = nil
            selectedPaper = paper; chatPaperID = paper.id; showPaperPlace()
            generalChat = false
        }
        if deviceModelRun != nil {
            // The test catalog's queue is reading another paper: the reading it kept of this one opens without the models.
            guard !again, let modelStore = localPersistence.modelReaderStore else { return }
            Task { [weak self] in
                guard let kept = await modelStore.record(sourceID: source.sourceID, revision: source.revision),
                      let bundle = try? await modelStore.read(kept.identity), let self, self.sessionID == scope else { return }
                self.showModelReading(bundle, for: paper)
            }
            return
        }
        // The models are a separate download (DEVICE_PDF_ROUTE.md "The models as a download"): offered in the bar where
        // the reading's progress shows; the reading starts once they are in.
        if !deviceModelReady {
            deviceModelDownloadPaperID = paper.id
            deviceModelDownloadAgain = again
            return
        }
        deviceModelDownloadPaperID = nil
        startDeviceModelRun(paper, source: source, again: again, load: load) { [weak self] outcome in
            guard let self, self.sessionID == scope, case .failed(let message) = outcome else { return }
            self.deviceModelIssue = message
        }
    }

    /// The models are on this device (or, in UI fixtures, the stand-in model reads instead).
    var deviceModelReady: Bool {
        #if DEBUG && FIXTURE_HOST
        if DeviceModelFixture.fakesReading { return true }
        #endif
        return DeviceModelEngine.modelsDirectory != nil
    }

    /// How a model reading ended: read (and shown when its paper is open), stopped, or why it failed in the reader's words.
    enum DeviceModelOutcome: Equatable { case read, cancelled, failed(String) }

    /// One model reading as `deviceModelRun` (its progress shows on the paper when that paper is open, and Stop ends it):
    /// a kept reading opens at once unless `again`; otherwise the PDF is read, kept on this device and shown when its paper
    /// is open. `finished` hears how it ended. The paper's own "Read with the on-device model" and the test catalog's queue
    /// (ReaderModel+TestCatalog.swift) both start readings here, one at a time.
    @available(iOS 18.0, *)
    @discardableResult
    func startDeviceModelRun(_ paper: Paper, source: DevicePDFPaper, again: Bool, load: @escaping () async throws -> Data,
                             finished: @escaping @MainActor (DeviceModelOutcome) -> Void) -> UUID {
        let scope = sessionID, modelStore = localPersistence.modelReaderStore
        let started = DeviceModelRun(paperID: paper.id, started: Date()), runID = started.id
        deviceModelRun = started
        // A cancelled reading still unwinding finishes first, so two model loads never overlap in memory.
        let unwinding = deviceModelUnwinding
        // The screen stays on while the model reads: auto-lock would pause the app and stop its GPU work.
        // On the Mac, idle sleep would pause it the same way.
        #if !targetEnvironment(macCatalyst)
        UIApplication.shared.isIdleTimerDisabled = true
        #else
        let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Reading a paper with the on-device model")
        #endif
        deviceModelTask = Task { [weak self] in
            guard let self else { return }
            defer {
                #if targetEnvironment(macCatalyst)
                ProcessInfo.processInfo.endActivity(awake)
                #endif
                // Only this run's own cleanup: a cancelled run unwinding late must not end a newer one.
                if self.deviceModelRun?.id == runID { self.deviceModelRun = nil; self.deviceModelTask = nil }
                #if !targetEnvironment(macCatalyst)
                // A newer run keeps the screen awake.
                if self.deviceModelRun == nil { UIApplication.shared.isIdleTimerDisabled = false }
                #endif
            }
            await unwinding?.value
            do {
                try Task.checkCancellation()
                if !again, let modelStore, let kept = await modelStore.record(sourceID: source.sourceID, revision: source.revision) {
                    let bundle = try await modelStore.read(kept.identity)
                    guard self.sessionID == scope else { finished(.cancelled); return }
                    self.showModelReading(bundle, for: paper)
                    finished(.read)
                    return
                }
                #if DEBUG && FIXTURE_HOST
                if DeviceModelFixture.fakesReading {
                    try await self.fakeDeviceModelReading(source: source, runID: runID)
                    finished(.read)
                    return
                }
                #endif
                let pdf = try await load()
                let (bundle, summary) = try await DeviceModelEngine.read(pdf: pdf, name: "\(source.sourceID)v\(source.revision).pdf", title: paper.title, authors: paper.authorNames, source: source) { stage in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == scope, var run = self.deviceModelRun, run.id == runID else { return }
                        switch stage {
                        case .layout(let page, let of): run.layoutPages = page; run.pages = of
                        case .reading(let done, let of): run.pagesRead = done; run.pages = of; run.layoutPages = of
                        case .formulas(let done, let of): run.formulasDone = done; run.formulasTotal = of
                        }
                        self.deviceModelRun = run
                    }
                } preview: { preview in
                    // The paper while its formulas are read: shown, not kept (the finished reading replaces it).
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionID == scope, var run = self.deviceModelRun, run.id == runID else { return }
                        self.showModelReading(preview, for: paper)
                        run.previewShown = true; self.deviceModelRun = run
                    }
                }
                try Task.checkCancellation()
                guard self.sessionID == scope else { finished(.cancelled); return }
                self.deviceModelSummaries[bundle.manifestSHA256] = summary
                if let modelStore {
                    if let old = await modelStore.record(sourceID: source.sourceID, revision: source.revision) { try? await modelStore.remove(old.identity) }
                    _ = try? await modelStore.install(bundle: bundle)
                }
                self.showModelReading(bundle, for: paper)
                finished(.read)
            } catch is CancellationError {
                finished(.cancelled)
            } catch {
                if case .cancelled? = error as? DevicePDFRoute.Failure { finished(.cancelled); return }
                guard self.sessionID == scope else { finished(.cancelled); return }
                finished(.failed(Self.deviceModelMessage(error)))
            }
        }
        return runID
    }

    #if DEBUG && FIXTURE_HOST
    /// `--device-model-fake-reading` (UI journeys on a Mac that must not run the real models): the run's bar walks through
    /// two pages in about a second and the source counts as read this session; nothing is kept.
    private func fakeDeviceModelReading(source: DevicePDFPaper, runID: UUID) async throws {
        let steps: [(Int, Int)] = [(1, 0), (2, 0), (2, 1), (2, 2)]
        for (layout, read) in steps {
            try await Task.sleep(for: .milliseconds(DeviceModelFixture.fakeStepMilliseconds))
            guard var run = deviceModelRun, run.id == runID else { throw CancellationError() }
            run.pages = 2; run.layoutPages = layout; run.pagesRead = read
            deviceModelRun = run
        }
        fakeModelReadings.insert(source.sourceID)
    }
    #endif

    /// The download bar's Download: the models, then the reading it was offered for (when that paper is still open).
    func downloadDeviceModelThenRead() {
        guard let paperID = deviceModelDownloadPaperID else { return }
        let again = deviceModelDownloadAgain, scope = sessionID
        Task { [weak self] in
            guard let self else { return }
            let ready = await self.deviceModelAssets.ensureDownloaded()
            guard ready, self.sessionID == scope, self.deviceModelDownloadPaperID == paperID,
                  let paper = self.selectedPaper, paper.id == paperID else { return }
            self.deviceModelDownloadPaperID = nil
            self.readWithDeviceModel(paper, again: again)
        }
    }

    /// The download bar's Cancel: stops a download in progress and closes the offer.
    func dismissDeviceModelDownload() {
        if case .downloading = deviceModelAssets.state { deviceModelAssets.cancel() }
        deviceModelDownloadPaperID = nil
    }

    /// The added PDF a local PDF view shows, when the model can read it.
    func modelReadablePaper(for presentation: LocalPaperPresentation) -> Paper? {
        guard let record = localPaperRecords.first(where: { $0.id == presentation.id }),
              let paper = papers.first(where: { $0.isLocalPDF && $0.sourceID == record.identity.sourceID }),
              canReadWithDeviceModel(paper) else { return nil }
        return paper
    }

    func cancelDeviceModelReading() {
        deviceModelTask?.cancel(); deviceModelUnwinding = deviceModelTask; deviceModelTask = nil; deviceModelRun = nil
        #if !targetEnvironment(macCatalyst)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func showModelReading(_ bundle: VerifiedReaderBundle, for paper: Paper) {
        guard let current = selectedPaper, current.id == paper.id else { return }
        if let html = current.readerBundle, html.manifest.source.kind != "device-pdf" { deviceModelHTMLBundles[paper.id] = html }
        let shown = current.displaying(bundle)
        // From the preview to the finished reading of the same PDF: the same blocks, so the reading place carries over.
        if let previous = current.readerBundle, previous.manifest.source.kind == "device-pdf", previous.manifest.source.sha256 == bundle.manifest.source.sha256,
           let oldKey = readingKey(for: current), let place = paperLocations[oldKey], let newKey = readingKey(for: shown) { paperLocations[newKey] = place }
        papers = papers.map { $0.id == paper.id ? shown : $0 }
        selectedPaper = shown
    }

    /// Back to the HTML reading the model reading replaced (or the usual opening when there was none).
    func showHTMLReading() {
        guard let paper = selectedPaper else { return }
        let html = deviceModelHTMLBundles.removeValue(forKey: paper.id)
        let shown = paper.displaying(html)
        papers = papers.map { $0.id == paper.id ? shown : $0 }
        selectedPaper = shown
        if html == nil { retryOpeningSelectedPaper() }
    }

    static func deviceModelMessage(_ error: Error) -> String {
        if #available(iOS 18.0, *), let failure = error as? DevicePDFRoute.Failure {
            switch failure {
            case .unreadablePDF: return "The on-device model couldn’t read this PDF."
            case .encrypted: return "This PDF is password-protected."
            case .converter(let code, _): return "The on-device model couldn’t finish this paper (\(code))."
            case .cancelled: return "Stopped."
            }
        }
        if let model = error as? DevicePDFModelError {
            switch model {
            case .missing: return "The PDF reading model isn’t on this device yet."
            case .unusable(let what): return "A model couldn’t run on this device (\(what.prefix(80)))."
            case .access(let reason): return reason.message
            }
        }
        if error is ReaderBundleError { return "The on-device model’s reading didn’t pass the reader’s checks." }
        return "The on-device model couldn’t read this paper."
    }
}

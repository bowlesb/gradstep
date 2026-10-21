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
    static var modelsDirectory: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("DeviceModels", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("device-models.json").path) else { return nil }
        return url
    }
    static var compilerURL: URL? { Bundle.main.url(forResource: "device-pdf-reader", withExtension: "js") }
    /// The models and the converter are in this build and the system can run the stateful recogniser.
    static var available: Bool {
        guard #available(iOS 18.0, *) else { return false }
        return modelsDirectory != nil && compilerURL != nil
    }

    @available(iOS 18.0, *)
    /// `preview`: the reading before its formulas are read (each one its page image), verified like the final one; it
    /// arrives once, from a background thread, while the recogniser finishes.
    static func read(pdf: Data, name: String, title: String, source: DevicePDFPaper,
                     progress: @escaping @Sendable (DevicePDFRoute.Stage) -> Void,
                     preview: @escaping @Sendable (VerifiedReaderBundle) -> Void = { _ in }) async throws -> (VerifiedReaderBundle, DeviceModelSummary) {
        guard let directory = modelsDirectory, let compilerURL else { throw DevicePDFModelError.missing("DeviceModels") }
        let start = Date()
        let task = Task.detached(priority: .userInitiated) { () throws -> (VerifiedReaderBundle, DeviceModelSummary) in
            let models = try DevicePDFModels(directory: directory)
            let route = DevicePDFRoute(models: models, compilerSource: try String(contentsOf: compilerURL, encoding: .utf8))
            var options = DevicePDFRoute.Options(title: title, sourceID: source.sourceID, revision: source.revision)
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
    var deviceModelAvailable: Bool { deviceModelReader && DeviceModelEngine.available }
    /// Whether "Read with the on-device model" applies to this paper now.
    func canReadWithDeviceModel(_ paper: Paper) -> Bool {
        guard deviceModelAvailable, deviceModelRun == nil else { return false }
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
        let scope = sessionID, modelStore = localPersistence.modelReaderStore
        deviceModelIssue = nil
        if paper.isLocalPDF, selectedPaper?.id != paper.id {
            // From a PDF the reader added (its own PDF view): the reading happens, and opens, in the reader.
            localPaperPresentation = nil
            selectedPaper = paper; chatPaperID = paper.id; tab = .paper
            // The wide layout (iPad, Mac) shows the reader too, as opening any paper does (`select`).
            if wideMode != .browse { wideMode = .reader }
            generalChat = false
        }
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
                    guard self.sessionID == scope else { return }
                    self.showModelReading(bundle, for: paper)
                    return
                }
                let pdf = try await load()
                let (bundle, summary) = try await DeviceModelEngine.read(pdf: pdf, name: "\(source.sourceID)v\(source.revision).pdf", title: paper.title, source: source) { stage in
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
                guard self.sessionID == scope else { return }
                self.deviceModelSummaries[bundle.manifestSHA256] = summary
                if let modelStore {
                    if let old = await modelStore.record(sourceID: source.sourceID, revision: source.revision) { try? await modelStore.remove(old.identity) }
                    _ = try? await modelStore.install(bundle: bundle)
                }
                self.showModelReading(bundle, for: paper)
            } catch is CancellationError {
            } catch {
                if case .cancelled? = error as? DevicePDFRoute.Failure { return }
                guard self.sessionID == scope else { return }
                self.deviceModelIssue = Self.deviceModelMessage(error)
            }
        }
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
            switch model { case .missing: return "The on-device models aren’t in this build."; case .unusable(let what): return "A model couldn’t run on this device (\(what.prefix(80)))." }
        }
        if error is ReaderBundleError { return "The on-device model’s reading didn’t pass the reader’s checks." }
        return "The on-device model couldn’t read this paper."
    }
}

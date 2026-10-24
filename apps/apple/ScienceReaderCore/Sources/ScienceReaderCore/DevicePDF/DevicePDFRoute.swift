import CoreGraphics
import CryptoKit
import Foundation
import JavaScriptCore

/// One PDF to one reader bundle on the device (docs/architecture/DEVICE_PDF_ROUTE.md): the converter
/// (`device-pdf-reader.js`, the rules) runs in JavaScriptCore and calls back into this host for pages, glyphs,
/// layout detections, tagger logits, recognitions and image crops. Synchronous; run it off the main thread.
///
/// Since 2026-10-21 (docs/reviews/DEVICE_PDF_ROUTE_20261021.md) the host overlaps the stages: the pages' layout and
/// text are read ahead on other threads, the tagger's lines run on several threads, and the recogniser reads formulas
/// in the background in batches (port revision 5's `submit`/`collect`) while the converter reads on; a reading with
/// every formula as its image can be handed over before the formulas are read (`onPreview`).
@available(iOS 18.0, macOS 15.0, *)
public final class DevicePDFRoute {
    public struct Options: Sendable {
        public var title: String?
        public var sourceID: String?
        public var revision: Int?
        public var trace: Bool
        /// Evaluation: the host's answers written down (`Output.record`) for the Node replay of the converter.
        public var record = false
        /// Converter rules beyond the port kit, by their input names (device-pdf/types.ts): `transcribe` (simple inline
        /// formulas from the text layer), `frontMatter` (the title page's title and author lines found by the library's
        /// metadata), `tidy` (confident recognitions Temml refuses, tidied), …; `name=number` sets a numeric option
        /// (`displayGate=0.9`). The converter ignores names it does not know.
        public var rules: Set<String> = []
        /// The library's authors (the `frontMatter` rule finds the author lines by them).
        public var authors: [String] = []
        public var maxPages: Int
        /// Recogniser calls in flight at once: crops (one-crop export) or batches (a batched export). Same results.
        public var recogniserConcurrency = 2
        /// The recogniser runs in the background while the converter reads on (port revision 5); off: page by page.
        public var background = true
        /// Pages whose layout and text are read ahead at once (0: on demand, as the converter asks).
        public var prefetchPages = 2
        /// A page whose text layer is missing or unreadable is read by on-device text recognition instead (DevicePDFOCR).
        public var ocrFallback = true
        /// Threads the inline tagger's lines are spread over. 1: concurrent predictions of the flexible-shape tagger gave
        /// different logits under load even on separate instances (2026-10-21), so the default keeps one.
        public var taggerThreads = 1
        /// A complete reading before the formulas are read (each shown as its image), handed over while the recogniser
        /// finishes (background mode only).
        public var onPreview: (@Sendable (Output) -> Void)?
        /// Evaluation only: each page's layout detections and canvas scale as the converter receives them.
        public var observeDetections: (@Sendable (Int, [DevicePDFModels.Detection], Double) -> Void)?
        public init(title: String? = nil, sourceID: String? = nil, revision: Int? = nil, trace: Bool = false, maxPages: Int = 0,
                    observeDetections: (@Sendable (Int, [DevicePDFModels.Detection], Double) -> Void)? = nil) {
            self.title = title; self.sourceID = sourceID; self.revision = revision; self.trace = trace; self.maxPages = maxPages
            self.observeDetections = observeDetections
        }
    }
    /// The converter reads every page's layout and text first, then reads the pages in order; formulas are read as
    /// their pages are (`formulas` counts all the formulas submitted so far in background mode, the page's otherwise).
    public enum Stage: Sendable, Equatable { case layout(page: Int, of: Int), reading(pagesDone: Int, of: Int), formulas(done: Int, of: Int) }
    public struct Output: Sendable {
        public let manifest: Data
        public let manifestSHA256: String
        public let members: [String: Data]
        /// The converter's summary (JSON) with the host's timings merged in.
        public let summary: Data
        /// The Python route's `index.json` shape, for `bundle_conformance.py` (only with `Options.trace`).
        public let trace: Data?
        /// With `Options.record`: the host's answers (device-pdf/record.ts), JSON.
        public var record: Data? = nil
    }
    public enum Failure: Error, Sendable, Equatable {
        case unreadablePDF
        case encrypted
        case converter(code: String, message: String)
        case cancelled
    }

    let models: DevicePDFModels
    let compiler: String

    public init(models: DevicePDFModels, compilerSource: String) {
        self.models = models; self.compiler = compilerSource
    }

    public func convert(pdf data: Data, name: String, options: Options = Options(),
                        progress: @escaping (Stage) -> Void = { _ in }, cancelled: @escaping () -> Bool = { false }) throws -> Output {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { throw Failure.unreadablePDF }
        if document.isEncrypted, !document.isUnlocked { throw Failure.encrypted }
        let pageCount = options.maxPages > 0 ? min(document.numberOfPages, options.maxPages) : document.numberOfPages
        guard pageCount > 0 else { throw Failure.unreadablePDF }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let timings = DevicePDFTimings()
        func timed<T>(_ key: String, page: Int? = nil, _ body: () throws -> T) rethrows -> T { try timings.timed(key, page: page, body) }
        // The page the converter is reading (after every page's layout): its tagger lines and its own JavaScript time are
        // that page's (the per-page timings; `pageClock` is when the page began).
        var readingPage = 0, pageClock = DispatchTime.now().uptimeNanoseconds
        // Page images at 150 dpi stay for the recogniser crops of the page being read; other resolutions are kept
        // for the last page asked only.
        var pages150: [Int: DevicePDFRaster.RGB] = [:]
        var other: (page: Int, dpi: Double, image: DevicePDFRaster.RGB)?
        func page150(_ index: Int) -> DevicePDFRaster.RGB? {
            if let image = pages150[index] { return image }
            guard let page = document.page(at: index + 1), let image = timed("render", page: index, { DevicePDFRaster.render(page, dpi: 150) }) else { return nil }
            let rgb = DevicePDFRaster.rgb(image)
            if pages150.count >= 2, let oldest = pages150.keys.min() { pages150[oldest] = nil }
            pages150[index] = rgb
            return rgb
        }
        // An encrypted document is read by this thread only (the read-ahead opens its own copies of an unlocked PDF).
        let prefetch = options.prefetchPages > 0 && !document.isEncrypted
            ? DevicePDFPagePrefetch(data: data, count: pageCount, workers: options.prefetchPages, models: models, timings: timings, ocr: options.ocrFallback) : nil
        let recogniser = options.background && models.recogniserIssue == nil
            ? DevicePDFBackgroundRecogniser(models: models, workers: options.recogniserConcurrency, timings: timings) { done, total in progress(.formulas(done: done, of: total)) }
            : nil
        defer { prefetch?.stop(); recogniser?.stop() }

        let context = JSContext()!
        var failure: Failure?
        context.exceptionHandler = { _, exception in
            let code = exception?.objectForKeyedSubscript("code")?.toString() ?? "exception"
            failure = failure ?? .converter(code: code == "undefined" ? "exception" : code, message: exception?.toString() ?? "")
        }
        context.evaluateScript(compiler)
        if let failure { throw failure }
        guard let api = context.objectForKeyedSubscript("GradstepDevicePDF"), !api.isUndefined else {
            throw Failure.converter(code: "compiler_missing", message: "GradstepDevicePDF is not defined")
        }
        let host = JSValue(newObjectIn: context)!
        var formulasDone = 0
        func pageObject(width: Double, height: Double, imageWidth: Int, imageHeight: Int, scale: Double, glyphs: [DevicePDFGlyph],
                        detections: [DevicePDFModels.Detection]) -> [String: Any] {
            [
                "width": width, "height": height, "image_width": imageWidth, "image_height": imageHeight, "scale": scale,
                "glyphs": [
                    "text": glyphs.map(\.text), "x0": glyphs.map(\.x0), "top": glyphs.map(\.top), "x1": glyphs.map(\.x1),
                    "bottom": glyphs.map(\.bottom), "size": glyphs.map(\.size), "font": glyphs.map(\.font), "upright": glyphs.map(\.upright),
                ],
                "detections": detections.map { ["cls": $0.cls, "score": $0.score, "box": $0.box] },
            ]
        }
        let pageBlock: @convention(block) (Int) -> Any = { index in
            guard index >= 0, index < pageCount else { return NSNull() }
            if let prefetch {
                guard let read = prefetch.page(index) else { return NSNull() }
                if let problem = read.failure { context.exception = JSValue(newErrorFromMessage: problem, in: context); return NSNull() }
                options.observeDetections?(index, read.detections, read.scale)
                return pageObject(width: read.width, height: read.height, imageWidth: read.imageWidth, imageHeight: read.imageHeight, scale: read.scale,
                                  glyphs: read.glyphs, detections: read.detections)
            }
            guard let page = document.page(at: index + 1) else { return NSNull() }
            guard let rgb = page150(index), let image = DevicePDFRaster.cgImage(rgb) else { return NSNull() }
            let detected: (detections: [DevicePDFModels.Detection], scale: Double)
            do { detected = try timed("layout", page: index) { try self.models.detect(page: image) } }
            catch { context.exception = JSValue(newErrorFromMessage: "layout: \(error)", in: context); return NSNull() }
            options.observeDetections?(index, detected.detections, detected.scale)
            var glyphs = timed("text", page: index) { DevicePDFTextLayer.glyphs(page: page) }
            let size = DevicePDFTextLayer.pageSize(page: page)
            if options.ocrFallback, DevicePDFOCR.unreadable(glyphs) { glyphs = timed("ocr", page: index) { DevicePDFOCR.glyphs(layer: glyphs, image: image, size: size) } }
            return pageObject(width: size.width, height: size.height, imageWidth: rgb.width, imageHeight: rgb.height, scale: detected.scale,
                              glyphs: glyphs, detections: detected.detections)
        }
        let tagBlock: @convention(block) (JSValue) -> Any = { lines in
            // The lines' features first (JavaScript values belong to this thread), then the model over several threads.
            let count = Int(lines.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            var inputs: [(x: [Float], font: [Int32], cls: [Int32], char: [Int32])?] = []
            for i in 0..<count {
                guard let line = lines.objectAtIndexedSubscript(i) else { inputs.append(nil); continue }
                func numbers(_ key: String) -> [Double] { (line.objectForKeyedSubscript(key)?.toArray() as? [NSNumber])?.map(\.doubleValue) ?? [] }
                inputs.append((numbers("x").map(Float.init), numbers("font").map { Int32($0) }, numbers("cls").map { Int32($0) }, numbers("char").map { Int32($0) }))
            }
            var out = [[Double]?](repeating: nil, count: count)
            // One tagger instance per thread (DevicePDFModels.taggers): never more threads than instances.
            let models = self.models, threads = max(1, min(options.taggerThreads, count, DevicePDFModels.taggerInstances))
            let start = DispatchTime.now().uptimeNanoseconds
            // The page's lines while no recogniser call runs (DevicePDFModels.exclusive).
            models.exclusive.lock(); defer { models.exclusive.unlock() }
            out.withUnsafeMutableBufferPointer { results in
                let results = results
                DispatchQueue.concurrentPerform(iterations: threads) { worker in
                    for i in stride(from: worker, to: count, by: threads) {
                        guard let input = inputs[i] else { results[i] = []; continue }
                        results[i] = (try? models.tag(x: input.x, font: input.font, cls: input.cls, char: input.char, slot: worker))?.map(Double.init)
                        if ProcessInfo.processInfo.environment["DEVICE_PDF_TAG_CHECK"] != nil {
                            let again = (try? models.tag(x: input.x, font: input.font, cls: input.cls, char: input.char, slot: worker))?.map(Double.init)
                            if again != results[i] { FileHandle.standardError.write(Data("TAG MISMATCH line \(i) of \(count), \(input.font.count) glyphs\n".utf8)) }
                        }
                    }
                }
            }
            timings.add("tag", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, page: readingPage)
            if out.contains(where: { $0 == nil }) { context.exception = JSValue(newErrorFromMessage: "tagger: a line could not be read", in: context); return NSNull() }
            return out.map { $0 ?? [] }
        }
        /// A crop request's piece of its page image with the recogniser's 8 px margin (nil when it cannot be cut).
        func cut(_ crop: JSValue?) -> (DevicePDFRaster.RGB?, Bool) {
            let display = crop?.objectForKeyedSubscript("display")?.toBool() ?? false
            guard let crop, let page = crop.objectForKeyedSubscript("page")?.toNumber()?.intValue, page >= 0, page < pageCount,
                  let rect = (crop.objectForKeyedSubscript("rect")?.toArray() as? [NSNumber])?.map(\.intValue), rect.count == 4,
                  let image = page150(page) else { return (nil, display) }
            return (DevicePDFRaster.crop(image, rect, margin: 8), display)
        }
        let recogniseBlock: @convention(block) (JSValue) -> Any = { crops in
            let count = Int(crops.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            // Without a recogniser every formula stays unread: the converter shows each as its image.
            if self.models.recogniserIssue != nil { return [Any](repeating: NSNull(), count: count) }
            let pieces = (0..<count).map { cut(crops.objectAtIndexedSubscript($0)).0 }
            let start = DispatchTime.now().uptimeNanoseconds
            // One page's crops, `recogniserConcurrency` calls in flight, in batches of the export's size.
            let b = max(1, self.models.recogniserBatch)
            let groups = stride(from: 0, to: count, by: b).map { Array($0..<min(count, $0 + b)) }
            final class Results: @unchecked Sendable {
                let lock = NSLock(); var rows: [Any]; var done = 0
                let report: (Stage) -> Void
                init(_ n: Int, report: @escaping (Stage) -> Void) { rows = [Any](repeating: NSNull(), count: n); self.report = report }
            }
            let results = Results(count, report: progress), models = self.models, c = models.configuration.recogniser
            let workers = max(1, min(options.recogniserConcurrency, groups.count))
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                for g in stride(from: worker, to: groups.count, by: workers) {
                    let present = groups[g].filter { pieces[$0] != nil }
                    let inputs = present.map { DevicePDFRaster.recogniserPixels(pieces[$0]!, size: c.imageSize, mean: c.mean, std: c.std) }
                    let read = present.isEmpty ? [] : ((try? models.recognise(batch: inputs)) ?? [])
                    results.lock.lock()
                    for (i, r) in zip(present, read) { results.rows[i] = ["latex": r.latex, "probs": r.probabilities] as [String: Any] }
                    results.done += groups[g].count; results.report(.formulas(done: results.done, of: count))
                    results.lock.unlock()
                }
            }
            timings.add("equations", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, page: readingPage)
            formulasDone += results.rows.filter { !($0 is NSNull) }.count
            return results.rows
        }
        let submitBlock: @convention(block) (JSValue) -> Int = { crops in
            let count = Int(crops.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            // The converter's cost hint (the formula's glyph count), when it gives one: batches of like reading lengths.
            let costs = (0..<count).map { i -> Int? in
                guard let value = crops.objectAtIndexedSubscript(i)?.objectForKeyedSubscript("cost"), value.isNumber else { return nil }
                let n = value.toDouble(); return n.isFinite && n >= 0 ? Int(min(n, 100_000)) : nil
            }
            return recogniser?.submit((0..<count).map { cut(crops.objectAtIndexedSubscript($0)) }, page: readingPage, costs: costs) ?? -1
        }
        let collectBlock: @convention(block) (Int) -> Any = { ticket in
            let rows = recogniser?.collect(ticket) ?? []
            formulasDone += rows.filter { !($0 is NSNull) }.count
            return rows
        }
        let imageBlock: @convention(block) (JSValue) -> Any = { request in
            // Any resolution: figures past the image budget are asked for at 150 × f dpi.
            guard let page = request.objectForKeyedSubscript("page")?.toNumber()?.intValue, let dpi = request.objectForKeyedSubscript("dpi")?.toNumber()?.doubleValue,
                  dpi.isFinite, dpi > 0, dpi <= 600,
                  let rect = (request.objectForKeyedSubscript("rect")?.toArray() as? [NSNumber])?.map(\.intValue), rect.count == 4,
                  rect[2] > rect[0], rect[3] > rect[1] else { return NSNull() }
            let source: DevicePDFRaster.RGB?
            if dpi == 150 { source = page150(page) }
            else if let other, other.page == page, other.dpi == dpi { source = other.image }
            else if let pdfPage = document.page(at: page + 1), let image = timed("render", page: page, { DevicePDFRaster.render(pdfPage, dpi: dpi) }) {
                let rgb = DevicePDFRaster.rgb(image); other = (page, dpi, rgb); source = rgb
            } else { source = nil }
            guard let source else { return NSNull() }
            // A formula's crop is cleaned when the converter asks (`clean: { em, margin }` in pixels at this resolution):
            // the cut tails of the lines above and below go, the ink is trimmed and given a margin, and the image's
            // place on the page comes back with it so the converter sizes and aligns it (DevicePDFRaster.cleanFormula).
            let clean = request.objectForKeyedSubscript("clean")
            if let clean, clean.isObject, let em = clean.objectForKeyedSubscript("em")?.toNumber()?.doubleValue, em.isFinite, em > 0, em <= 1000,
               let margin = clean.objectForKeyedSubscript("margin")?.toNumber()?.intValue, (0...200).contains(margin) {
                let (png, placed) = timed("images", page: page) { () -> (Data, [Int]) in
                    let cleaned = DevicePDFRaster.cleanFormula(DevicePDFRaster.crop(source, rect), em: em, margin: margin)
                    return (DevicePDFRaster.png(cleaned.image), [rect[0] + cleaned.rect[0], rect[1] + cleaned.rect[1], rect[0] + cleaned.rect[2], rect[1] + cleaned.rect[3]])
                }
                return ["png": png.base64EncodedString(), "width": placed[2] - placed[0], "height": placed[3] - placed[1], "rect": placed] as [String: Any]
            }
            let png = timed("images", page: page) { DevicePDFRaster.png(DevicePDFRaster.crop(source, rect)) }
            return ["png": png.base64EncodedString(), "width": rect[2] - rect[0], "height": rect[3] - rect[1]] as [String: Any]
        }
        let previewBlock: @convention(block) (JSValue) -> Void = { value in
            guard let onPreview = options.onPreview, let output = try? Self.output(value, trace: nil) else { return }
            onPreview(output)
        }
        let progressBlock: @convention(block) (String, Int, Int) -> Void = { stage, done, total in
            let now = DispatchTime.now().uptimeNanoseconds
            if stage == "layout" {
                // Waiting for the read-ahead or reading the page on demand: before the reading starts, not a page's own.
                if done == total { pageClock = now }
                progress(.layout(page: done, of: total))
            } else if stage == "pages" {
                // The page's wall time on the converter's thread (its rules, its tagger calls and image crops included).
                timings.addToPage("read", Double(now - pageClock) / 1e9, page: done - 1)
                // Work submitted after the last page (none is a page's own) counts in the totals only.
                pageClock = now; readingPage = done < total ? done : -1
                progress(.reading(pagesDone: done, of: total))
            }
        }
        let cancelledBlock: @convention(block) () -> Bool = {
            if cancelled() { recogniser?.stop(); prefetch?.stop(); return true }
            return false
        }
        host.setObject(pageBlock, forKeyedSubscript: "page" as NSString)
        host.setObject(tagBlock, forKeyedSubscript: "tag" as NSString)
        host.setObject(recogniseBlock, forKeyedSubscript: "recognise" as NSString)
        if recogniser != nil {
            host.setObject(submitBlock, forKeyedSubscript: "submit" as NSString)
            host.setObject(collectBlock, forKeyedSubscript: "collect" as NSString)
            if options.onPreview != nil { host.setObject(previewBlock, forKeyedSubscript: "preview" as NSString) }
        }
        host.setObject(imageBlock, forKeyedSubscript: "image" as NSString)
        host.setObject(progressBlock, forKeyedSubscript: "progress" as NSString)
        host.setObject(cancelledBlock, forKeyedSubscript: "cancelled" as NSString)

        var input: [String: Any] = [
            "pdf": ["sha256": digest, "bytes": data.count, "name": name], "pages": pageCount,
            "models": models.provenance, "tagger": models.taggerVocabulary, "trace": options.trace, "record": options.record,
        ]
        for (name, value) in Self.converterRules(options.rules) { input[name] = value }
        if !options.authors.isEmpty { input["authors"] = Array(options.authors.prefix(200)) }
        if let title = options.title { input["title"] = title }
        if let sourceID = options.sourceID, let revision = options.revision { input["paper"] = ["source_id": sourceID, "revision": revision] }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = api.invokeMethod("convert", withArguments: [input, host])
        let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        if cancelled() { throw Failure.cancelled }
        if let failure { throw failure }
        guard let result, result.isObject else { throw Failure.converter(code: "result_shape", message: "the converter returned no bundle") }
        var trace: Data?
        if options.trace, let value = result.objectForKeyedSubscript("trace") {
            if value.isString, let text = value.toString() { trace = Data(text.utf8) }
            else if value.isObject, let object = value.toDictionary() { trace = try? JSONSerialization.data(withJSONObject: object, options: []) }
        }
        let bundle = try Self.output(result, trace: trace)
        var summary = (result.objectForKeyedSubscript("summary")?.toDictionary() as? [String: Any]) ?? [:]
        // Busy seconds per stage (they overlap when pages are read ahead and the recogniser runs in the background) and
        // the wall time.
        var seconds = timings.snapshot
        seconds["total"] = total
        // After the last page: waiting for the recogniser, then the formulas, figures and the bundle written.
        seconds["finish"] = Double(DispatchTime.now().uptimeNanoseconds - pageClock) / 1e9
        summary["host_seconds"] = seconds.mapValues { ($0 * 100).rounded() / 100 }
        // Busy seconds per page and stage (evaluation): render, text, layout, ocr (read ahead), tag, equations (the page's
        // share of its recogniser batches), images, and `read`, the page's wall time on the converter's thread.
        summary["host_pages"] = timings.pages.map { $0.mapValues { ($0 * 1000).rounded() / 1000 } }
        summary["pipeline"] = ["background": recogniser != nil, "prefetch_pages": prefetch == nil ? 0 : options.prefetchPages,
                               "recogniser_batch": models.recogniserBatch, "recogniser_in_flight": options.recogniserConcurrency,
                               "tagger_threads": options.taggerThreads] as [String: Any]
        summary["model_load_seconds"] = models.loadSeconds.mapValues { ($0 * 100).rounded() / 100 }
        summary["formulas_recognised"] = formulasDone
        if let issue = models.recogniserIssue { summary["recogniser_unavailable"] = String(issue.prefix(300)) }
        let summaryData = (try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        var output = Output(manifest: bundle.manifest, manifestSHA256: bundle.manifestSHA256, members: bundle.members, summary: summaryData, trace: trace)
        if options.record, let value = result.objectForKeyedSubscript("record"), value.isString, let text = value.toString() { output.record = Data(text.utf8) }
        return output
    }

    /// A converter result (`{manifest, manifest_sha256, members, summary}`, base64) as bytes.
    static func output(_ value: JSValue, trace: Data?) throws -> Output {
        guard value.isObject, let manifest64 = value.objectForKeyedSubscript("manifest")?.toString(),
              let manifest = Data(base64Encoded: manifest64), let sha = value.objectForKeyedSubscript("manifest_sha256")?.toString(),
              let members64 = value.objectForKeyedSubscript("members")?.toDictionary() as? [String: String] else {
            throw Failure.converter(code: "result_shape", message: "the converter returned no bundle")
        }
        var members: [String: Data] = [:]
        for (path, value) in members64 {
            guard let bytes = Data(base64Encoded: value) else { throw Failure.converter(code: "result_shape", message: path) }
            members[path] = bytes
        }
        let summary = (value.objectForKeyedSubscript("summary")?.toDictionary()).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
        return Output(manifest: manifest, manifestSHA256: sha, members: members, summary: summary, trace: trace)
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension DevicePDFRoute {
    /// The converter's input options for `Options.rules`: a bare name is `true`, `name=number` a number; anything else is
    /// dropped (names are ASCII letters; the converter ignores those it does not know).
    public static func converterRules(_ rules: Set<String>) -> [(String, Any)] {
        rules.sorted().compactMap { rule -> (String, Any)? in
            let parts = rule.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty, name.count <= 40, name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
            if parts.count == 1 { return (name, true) }
            guard let number = Double(parts[1]), number.isFinite else { return nil }
            return (name, number)
        }
    }
}

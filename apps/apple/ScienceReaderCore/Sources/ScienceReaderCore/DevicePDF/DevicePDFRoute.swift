import CoreGraphics
import CryptoKit
import Foundation
import JavaScriptCore

/// One PDF to one reader bundle on the device (docs/architecture/DEVICE_PDF_ROUTE.md): the converter
/// (`device-pdf-reader.js`, the rules) runs in JavaScriptCore and calls back into this host for pages, glyphs,
/// layout detections, tagger logits, recognitions and image crops. Synchronous; run it off the main thread.
@available(iOS 18.0, macOS 15.0, *)
public final class DevicePDFRoute {
    public struct Options: Sendable {
        public var title: String?
        public var sourceID: String?
        public var revision: Int?
        public var trace: Bool
        public var maxPages: Int
        /// Crops recognised at once (2 by default; 1 is the reference's one-at-a-time order, same results).
        public var recogniserConcurrency = 2
        /// Evaluation only: each page's layout detections and canvas scale as the converter receives them.
        public var observeDetections: (@Sendable (Int, [DevicePDFModels.Detection], Double) -> Void)?
        public init(title: String? = nil, sourceID: String? = nil, revision: Int? = nil, trace: Bool = false, maxPages: Int = 0,
                    observeDetections: (@Sendable (Int, [DevicePDFModels.Detection], Double) -> Void)? = nil) {
            self.title = title; self.sourceID = sourceID; self.revision = revision; self.trace = trace; self.maxPages = maxPages
            self.observeDetections = observeDetections
        }
    }
    /// The converter reads every page's layout and text first, then reads the pages in order, recognising each
    /// page's formulas as it goes.
    public enum Stage: Sendable, Equatable { case layout(page: Int, of: Int), reading(pagesDone: Int, of: Int), formulas(done: Int, of: Int) }
    public struct Output: Sendable {
        public let manifest: Data
        public let manifestSHA256: String
        public let members: [String: Data]
        /// The converter's summary (JSON) with the host's timings merged in.
        public let summary: Data
        /// The Python route's `index.json` shape, for `bundle_conformance.py` (only with `Options.trace`).
        public let trace: Data?
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

        var timings: [String: Double] = ["render": 0, "layout": 0, "text": 0, "tag": 0, "equations": 0, "images": 0]
        func timed<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
            let start = DispatchTime.now().uptimeNanoseconds
            defer { timings[key, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 }
            return try body()
        }
        // Page images at 150 dpi stay for the recogniser crops of the page being read; other resolutions are kept
        // for the last page asked only.
        var pages150: [Int: DevicePDFRaster.RGB] = [:]
        var other: (page: Int, dpi: Double, image: DevicePDFRaster.RGB)?
        func page150(_ index: Int) -> DevicePDFRaster.RGB? {
            if let image = pages150[index] { return image }
            guard let page = document.page(at: index + 1), let image = timed("render", { DevicePDFRaster.render(page, dpi: 150) }) else { return nil }
            let rgb = DevicePDFRaster.rgb(image)
            if pages150.count >= 2, let oldest = pages150.keys.min() { pages150[oldest] = nil }
            pages150[index] = rgb
            return rgb
        }

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
        let pageBlock: @convention(block) (Int) -> Any = { index in
            guard index >= 0, index < pageCount, let page = document.page(at: index + 1) else { return NSNull() }
            guard let rgb = page150(index), let image = DevicePDFRaster.cgImage(rgb) else { return NSNull() }
            let detected: (detections: [DevicePDFModels.Detection], scale: Double)
            do { detected = try timed("layout") { try self.models.detect(page: image) } }
            catch { context.exception = JSValue(newErrorFromMessage: "layout: \(error)", in: context); return NSNull() }
            options.observeDetections?(index, detected.detections, detected.scale)
            let glyphs = timed("text") { DevicePDFTextLayer.glyphs(page: page) }
            let size = DevicePDFTextLayer.pageSize(page: page)
            return [
                "width": size.width, "height": size.height, "image_width": rgb.width, "image_height": rgb.height, "scale": detected.scale,
                "glyphs": [
                    "text": glyphs.map(\.text), "x0": glyphs.map(\.x0), "top": glyphs.map(\.top), "x1": glyphs.map(\.x1),
                    "bottom": glyphs.map(\.bottom), "size": glyphs.map(\.size), "font": glyphs.map(\.font), "upright": glyphs.map(\.upright),
                ],
                "detections": detected.detections.map { ["cls": $0.cls, "score": $0.score, "box": $0.box] },
            ] as [String: Any]
        }
        let tagBlock: @convention(block) (JSValue) -> Any = { lines in
            var out: [[Double]] = []
            let count = Int(lines.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            for i in 0..<count {
                guard let line = lines.objectAtIndexedSubscript(i) else { out.append([]); continue }
                func numbers(_ key: String) -> [Double] { (line.objectForKeyedSubscript(key)?.toArray() as? [NSNumber])?.map(\.doubleValue) ?? [] }
                let x = numbers("x").map(Float.init), font = numbers("font").map { Int32($0) }, cls = numbers("cls").map { Int32($0) }, char = numbers("char").map { Int32($0) }
                do { out.append(try timed("tag") { try self.models.tag(x: x, font: font, cls: cls, char: char) }.map(Double.init)) }
                catch { context.exception = JSValue(newErrorFromMessage: "tagger: \(error)", in: context); return NSNull() }
            }
            return out
        }
        let recogniseBlock: @convention(block) (JSValue) -> Any = { crops in
            let count = Int(crops.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            // Without a recogniser every formula stays unread: the converter shows each as its image.
            if self.models.recogniserIssue != nil { return [Any](repeating: NSNull(), count: count) }
            // The crops first (the page images are this thread's), then the recognitions `recogniserConcurrency` at a
            // time: a decoder step is mostly fixed overhead, so two crops in flight nearly halve the wall time.
            var images: [CGImage?] = []
            for i in 0..<count {
                guard let crop = crops.objectAtIndexedSubscript(i), let page = crop.objectForKeyedSubscript("page")?.toNumber()?.intValue,
                      let rect = (crop.objectForKeyedSubscript("rect")?.toArray() as? [NSNumber])?.map(\.intValue), rect.count == 4,
                      let image = page150(page) else { images.append(nil); continue }
                images.append(DevicePDFRaster.cgImage(DevicePDFRaster.crop(image, rect, margin: 8)))
            }
            // The progress callback is the caller's (not Sendable): workers call it one at a time, under the lock, so
            // the counts arrive in order and the caller never sees two calls at once.
            final class Results: @unchecked Sendable {
                let lock = NSLock(); var rows: [Any]; var done = 0
                let report: (Stage) -> Void
                init(_ n: Int, report: @escaping (Stage) -> Void) { rows = [Any](repeating: NSNull(), count: n); self.report = report }
            }
            let results = Results(count, report: progress), models = self.models, crops = images
            let start = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.concurrentPerform(iterations: max(1, min(options.recogniserConcurrency, count))) { worker in
                var i = worker
                while i < count {
                    if let cg = crops[i], let r = try? models.recognise(crop: cg) {
                        results.lock.lock(); results.rows[i] = ["latex": r.latex, "probs": r.probabilities] as [String: Any]; results.lock.unlock()
                    }
                    results.lock.lock(); results.done += 1; results.report(.formulas(done: results.done, of: count)); results.lock.unlock()
                    i += max(1, min(options.recogniserConcurrency, count))
                }
            }
            timings["equations", default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            formulasDone += results.rows.filter { !($0 is NSNull) }.count
            return results.rows
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
            else if let pdfPage = document.page(at: page + 1), let image = timed("render", { DevicePDFRaster.render(pdfPage, dpi: dpi) }) {
                let rgb = DevicePDFRaster.rgb(image); other = (page, dpi, rgb); source = rgb
            } else { source = nil }
            guard let source else { return NSNull() }
            // A formula's crop is cleaned when the converter asks (`clean: { em, margin }` in pixels at this resolution):
            // the cut tails of the lines above and below go, the ink is trimmed and given a margin, and the image's
            // place on the page comes back with it so the converter sizes and aligns it (DevicePDFRaster.cleanFormula).
            let clean = request.objectForKeyedSubscript("clean")
            if let clean, clean.isObject, let em = clean.objectForKeyedSubscript("em")?.toNumber()?.doubleValue, em.isFinite, em > 0, em <= 1000,
               let margin = clean.objectForKeyedSubscript("margin")?.toNumber()?.intValue, (0...200).contains(margin) {
                let (png, placed) = timed("images") { () -> (Data, [Int]) in
                    let cleaned = DevicePDFRaster.cleanFormula(DevicePDFRaster.crop(source, rect), em: em, margin: margin)
                    return (DevicePDFRaster.png(cleaned.image), [rect[0] + cleaned.rect[0], rect[1] + cleaned.rect[1], rect[0] + cleaned.rect[2], rect[1] + cleaned.rect[3]])
                }
                return ["png": png.base64EncodedString(), "width": placed[2] - placed[0], "height": placed[3] - placed[1], "rect": placed] as [String: Any]
            }
            let png = timed("images") { DevicePDFRaster.png(DevicePDFRaster.crop(source, rect)) }
            return ["png": png.base64EncodedString(), "width": rect[2] - rect[0], "height": rect[3] - rect[1]] as [String: Any]
        }
        let progressBlock: @convention(block) (String, Int, Int) -> Void = { stage, done, total in
            if stage == "layout" { progress(.layout(page: done, of: total)) }
            else if stage == "pages" { progress(.reading(pagesDone: done, of: total)) }
        }
        let cancelledBlock: @convention(block) () -> Bool = { cancelled() }
        host.setObject(pageBlock, forKeyedSubscript: "page" as NSString)
        host.setObject(tagBlock, forKeyedSubscript: "tag" as NSString)
        host.setObject(recogniseBlock, forKeyedSubscript: "recognise" as NSString)
        host.setObject(imageBlock, forKeyedSubscript: "image" as NSString)
        host.setObject(progressBlock, forKeyedSubscript: "progress" as NSString)
        host.setObject(cancelledBlock, forKeyedSubscript: "cancelled" as NSString)

        var input: [String: Any] = [
            "pdf": ["sha256": digest, "bytes": data.count, "name": name], "pages": pageCount,
            "models": models.provenance, "tagger": models.taggerVocabulary, "trace": options.trace,
        ]
        if let title = options.title { input["title"] = title }
        if let sourceID = options.sourceID, let revision = options.revision { input["paper"] = ["source_id": sourceID, "revision": revision] }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = api.invokeMethod("convert", withArguments: [input, host])
        let total = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        if cancelled() { throw Failure.cancelled }
        if let failure { throw failure }
        guard let result, result.isObject, let manifest64 = result.objectForKeyedSubscript("manifest")?.toString(),
              let manifest = Data(base64Encoded: manifest64), let sha = result.objectForKeyedSubscript("manifest_sha256")?.toString(),
              let members64 = result.objectForKeyedSubscript("members")?.toDictionary() as? [String: String] else {
            throw Failure.converter(code: "result_shape", message: "the converter returned no bundle")
        }
        var members: [String: Data] = [:]
        for (path, value) in members64 {
            guard let bytes = Data(base64Encoded: value) else { throw Failure.converter(code: "result_shape", message: path) }
            members[path] = bytes
        }
        var summary = (result.objectForKeyedSubscript("summary")?.toDictionary() as? [String: Any]) ?? [:]
        timings["converter"] = max(0, total - timings.values.reduce(0, +))
        timings["total"] = total
        summary["host_seconds"] = timings.mapValues { ($0 * 100).rounded() / 100 }
        summary["model_load_seconds"] = models.loadSeconds.mapValues { ($0 * 100).rounded() / 100 }
        summary["formulas_recognised"] = formulasDone
        if let issue = models.recogniserIssue { summary["recogniser_unavailable"] = String(issue.prefix(300)) }
        let summaryData = (try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        var trace: Data?
        if options.trace, let value = result.objectForKeyedSubscript("trace") {
            if value.isString, let text = value.toString() { trace = Data(text.utf8) }
            else if value.isObject, let object = value.toDictionary() { trace = try? JSONSerialization.data(withJSONObject: object, options: []) }
        }
        return Output(manifest: manifest, manifestSHA256: sha, members: members, summary: summaryData, trace: trace)
    }
}

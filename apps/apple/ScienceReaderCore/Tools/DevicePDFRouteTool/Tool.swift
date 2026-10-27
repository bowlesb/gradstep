import Foundation
import ScienceReaderCore
import CoreML
import ImageIO
import JavaScriptCore

/// Page crops for the weakness report: `[{pdf, page (0-based), rect: [x0, y0, x1, y1] (points, top-left origin), dpi, out,
/// boxes?: [[x0, y0, x1, y1, "#rrggbb"]] (points)}]`. Pages are rendered by `DevicePDFRaster.render` (font smoothing off,
/// as the route reads them); each box is outlined on the crop; PNGs are written to `out`.
func renderCrops(jobs url: URL) throws {
    let jobs = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
    var documents: [String: CGPDFDocument] = [:]
    var cache: (key: String, image: CGImage)?
    var written = 0
    for job in jobs {
        guard let path = job["pdf"] as? String, let index = (job["page"] as? NSNumber)?.intValue, let out = job["out"] as? String,
              let rect = (job["rect"] as? [NSNumber])?.map(\.doubleValue), rect.count == 4 else { continue }
        let dpi = (job["dpi"] as? NSNumber)?.doubleValue ?? 110
        if documents[path] == nil, let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL), let document = CGPDFDocument(provider) {
            documents[path] = document
        }
        guard let document = documents[path], let page = document.page(at: index + 1) else { continue }
        let key = "\(path)#\(index)@\(dpi)"
        let image: CGImage
        if let cache, cache.key == key { image = cache.image } else {
            guard let rendered = DevicePDFRaster.render(page, dpi: dpi) else { continue }
            image = rendered; cache = (key, rendered)
        }
        let k = dpi / 72
        let x0 = max(0, Int((rect[0] * k).rounded(.down))), y0 = max(0, Int((rect[1] * k).rounded(.down)))
        let x1 = min(image.width, Int((rect[2] * k).rounded(.up))), y1 = min(image.height, Int((rect[3] * k).rounded(.up)))
        guard x1 > x0, y1 > y0, let piece = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)),
              let ctx = CGContext(data: nil, width: x1 - x0, height: y1 - y0, bitsPerComponent: 8, bytesPerRow: (x1 - x0) * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
        let h = Double(y1 - y0)
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: x1 - x0, height: y1 - y0))
        for box in (job["boxes"] as? [[Any]]) ?? [] {
            let b = box.prefix(4).compactMap { ($0 as? NSNumber)?.doubleValue }
            guard b.count == 4, box.count >= 5, let hex = box[4] as? String, hex.count == 7, let rgb = Int(hex.dropFirst(), radix: 16) else { continue }
            let bx0 = b[0] * k - Double(x0), bx1 = b[2] * k - Double(x0), by0 = b[1] * k - Double(y0), by1 = b[3] * k - Double(y0)
            ctx.setStrokeColor(CGColor(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 0.9))
            ctx.setLineWidth(2)
            // Core Graphics' origin is the bottom left.
            ctx.stroke(CGRect(x: bx0, y: h - by1, width: bx1 - bx0, height: by1 - by0))
        }
        guard let drawn = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(destination, drawn, nil)
        if CGImageDestinationFinalize(destination) { written += 1 }
    }
    print("rendered \(written) of \(jobs.count) crops")
}

// The device route on this Mac, for evaluation (docs/architecture/DEVICE_PDF_ROUTE.md):
//   swift run -c release DevicePDFRouteTool <paper.pdf> <out-dir> --models <dir> --compiler <device-pdf-reader.js>
//       [--trace] [--title "…"] [--max-pages N] [--layout ne|gpu|cpu|all] [--recogniser gpu|cpu|all] [--tagger cpu|ne]
// Writes the bundle's members and manifest.json; with --trace also index.json (the Python route's shape, for the
// desktop's bundle_conformance.py) and conversion.json (summary and timings).
@main
struct Tool {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let value = args[i + 1]; args.removeSubrange(i...(i + 1)); return value
        }
        func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
        // Same source pixels through legacy and content-aware image cleaning; no model inference or PDF writes.
        if let jobs = option("--clean-formula-crops") {
            try cleanFormulaCrops(jobs: URL(fileURLWithPath: jobs)); return
        }
        // --replay-converter <record.json> --compiler <js>: the converter alone in JavaScriptCore on a run's recorded host
        // answers (no models), timed: with JSC_useJIT=false in the environment this is the phone's case (no JIT for an
        // app's JSContext).
        if let recordPath = option("--replay-converter"), let compiler = option("--compiler") {
            try replayConverter(record: URL(fileURLWithPath: recordPath), compiler: URL(fileURLWithPath: compiler), repeats: Int(option("--repeat") ?? "1") ?? 1)
            return
        }
        // --render-crops <jobs.json>: page crops for the weakness report (scripts/device-route-weaknesses.mjs), rendered as
        // the route renders pages (Core Graphics, font smoothing off), with outlined boxes drawn on top.
        if let jobsPath = option("--render-crops") {
            try renderCrops(jobs: URL(fileURLWithPath: jobsPath))
            return
        }
        // Offline corpus research: preserve the exact device glyphs and layout without running formula recognition.
        // A job is {pdf, page (zero-based), out}; originals are opened read-only and each result is written atomically.
        if let jobsPath = option("--audit-pages"), let modelsPath = option("--models") {
            guard #available(macOS 15.0, *) else { exit(2) }
            struct AuditJob: Decodable { let pdf: String; let page: Int; let out: String }
            let jobs = try JSONDecoder().decode([AuditJob].self, from: Data(contentsOf: URL(fileURLWithPath: jobsPath)))
            let loaded = try DevicePDFModels(directory: URL(fileURLWithPath: modelsPath))
            for (index, job) in jobs.enumerated() {
                if FileManager.default.fileExists(atPath: job.out) { continue }
                guard job.page >= 0, let document = CGPDFDocument(URL(fileURLWithPath: job.pdf) as CFURL),
                      let page = document.page(at: job.page + 1), let image = DevicePDFRaster.render(page, dpi: 150) else {
                    throw DevicePDFModelError.unusable("audit page \(job.page)")
                }
                let size = DevicePDFTextLayer.pageSize(page: page)
                let layer = DevicePDFTextLayer.glyphs(page: page)
                let needsOCR = DevicePDFOCR.unreadable(layer)
                let glyphs = needsOCR ? DevicePDFOCR.glyphs(layer: layer, image: image, size: size) : layer
                let detected = try loaded.detect(page: image)
                let output: [String: Any] = [
                    "pdf": job.pdf, "page": job.page, "ocr": needsOCR, "models": loaded.provenance,
                    "width": size.width, "height": size.height, "image_width": image.width, "image_height": image.height,
                    "scale": detected.scale,
                    "glyphs": ["text": glyphs.map(\.text), "x0": glyphs.map(\.x0), "top": glyphs.map(\.top),
                               "x1": glyphs.map(\.x1), "bottom": glyphs.map(\.bottom), "size": glyphs.map(\.size),
                               "font": glyphs.map(\.font), "upright": glyphs.map(\.upright)],
                    "detections": detected.detections.map { ["cls": $0.cls, "score": $0.score, "box": $0.box] }
                ]
                try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: job.out), options: .atomic)
                print("audited \(index + 1)/\(jobs.count)")
            }
            return
        }
        // Actual Core ML outputs for offline parity checks and filling newly requested tagger windows in a replay.
        // Inputs are the converter's unrounded TagLine values; no PDF is acquired or processed by a server.
        if let inputsPath = option("--tag-inputs"), let modelsPath = option("--models"), let outPath = option("--out") {
            guard #available(macOS 15.0, *) else { exit(2) }
            struct TagInput: Decodable { let x: [Float]; let font: [Int32]; let cls: [Int32]; let char: [Int32] }
            let inputs = try JSONDecoder().decode([TagInput].self, from: Data(contentsOf: URL(fileURLWithPath: inputsPath)))
            let loaded = try DevicePDFModels(directory: URL(fileURLWithPath: modelsPath), taggerUnits: .cpuOnly)
            let outputs = try inputs.map { try loaded.tag(x: $0.x, font: $0.font, cls: $0.cls, char: $0.char) }
            let result: [String: Any] = ["logits": outputs, "features": loaded.taggerFeatures, "models": loaded.provenance]
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: outPath), options: .atomic)
            print("tagged \(inputs.count) exact-length inputs with \(loaded.taggerFeatures) features")
            return
        }
        // Fill only recogniser requests absent from a recorded conversion, using the same local raster and model.
        // JSONL output preserves completed batches if a long corpus run is interrupted.
        if let jobsPath = option("--recognise-crops"), let modelsPath = option("--models"), let outPath = option("--out") {
            guard #available(macOS 15.0, *) else { exit(2) }
            struct CropJob: Decodable { let id: String; let pdf: String; let page: Int; let rect: [Int] }
            let jobs = try JSONDecoder().decode([CropJob].self, from: Data(contentsOf: URL(fileURLWithPath: jobsPath)))
            let loaded = try DevicePDFModels(directory: URL(fileURLWithPath: modelsPath))
            if let issue = loaded.recogniserIssue { throw DevicePDFModelError.unusable(issue) }
            let c = loaded.configuration.recogniser
            let outputURL = URL(fileURLWithPath: outPath)
            guard !FileManager.default.fileExists(atPath: outPath) else { throw DevicePDFModelError.unusable("crop output already exists") }
            FileManager.default.createFile(atPath: outPath, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            func write(_ value: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
                try output.write(contentsOf: data)
            }
            try write(["models": loaded.provenance])
            var documentPath = "", document: CGPDFDocument?, cachedKey = "", cachedPage: DevicePDFRaster.RGB?
            for start in stride(from: 0, to: jobs.count, by: loaded.recogniserBatch) {
                let group = Array(jobs[start..<min(jobs.count, start + loaded.recogniserBatch)])
                let pixels = try group.map { job -> [Float] in
                    if documentPath != job.pdf {
                        documentPath = job.pdf
                        document = CGPDFDocument(URL(fileURLWithPath: job.pdf) as CFURL)
                    }
                    let key = "\(job.pdf)#\(job.page)"
                    if cachedKey != key {
                        guard let page = document?.page(at: job.page + 1), let rendered = DevicePDFRaster.render(page, dpi: 150) else {
                            throw DevicePDFModelError.unusable("crop page \(job.id)")
                        }
                        cachedPage = DevicePDFRaster.rgb(rendered); cachedKey = key
                    }
                    guard let image = cachedPage, job.rect.count == 4 else { throw DevicePDFModelError.unusable("crop rectangle") }
                    return DevicePDFRaster.recogniserPixels(DevicePDFRaster.crop(image, job.rect, margin: 8), size: c.imageSize, mean: c.mean, std: c.std)
                }
                let recognised = try loaded.recognise(batch: pixels)
                guard recognised.count == group.count else { throw DevicePDFModelError.unusable("crop answer count") }
                for (job, answer) in zip(group, recognised) { try write(["id": job.id, "latex": answer.latex, "probs": answer.probabilities]) }
                if start % 64 == 0 { print("recognised \(min(jobs.count, start + group.count))/\(jobs.count)") }
            }
            return
        }
        // --dump-glyphs <page> <pdf>: that page's glyphs as the host reads them (text layer, or text recognition when the
        // layer is unreadable), one per line: text, x0, top, x1, bottom, size, font.
        if let pageText = option("--dump-glyphs"), let pdfPath = args.first, let index = Int(pageText) {
            guard let provider = CGDataProvider(url: URL(fileURLWithPath: pdfPath) as CFURL), let document = CGPDFDocument(provider),
                  let page = document.page(at: index + 1), let image = DevicePDFRaster.render(page, dpi: 150) else { exit(2) }
            let size = DevicePDFTextLayer.pageSize(page: page)
            for g in DevicePDFOCR.glyphs(layer: DevicePDFTextLayer.glyphs(page: page), image: image, size: size) {
                print([g.text, String(format: "%.1f", g.x0), String(format: "%.1f", g.top), String(format: "%.1f", g.x1), String(format: "%.1f", g.bottom),
                       String(format: "%.1f", g.size), g.font].joined(separator: "\t"))
            }
            return
        }
        // --check-determinism: the tagger and the layout on fixed inputs, alone and while the recogniser runs on another
        // thread; prints how many outputs differ from the first.
        if flag("--check-determinism"), let models = option("--models") {
            guard #available(macOS 15.0, *) else { exit(2) }
            let loaded = try DevicePDFModels(directory: URL(fileURLWithPath: models), taggerUnits: option("--tagger").flatMap(MLUnits.init(rawValue:))?.compute ?? .cpuOnly)
            // Lines of 6 to 60 glyphs, in turn (the tagger's inputs have flexible length).
            typealias Line = (x: [Float], font: [Int32], cls: [Int32], char: [Int32])
            var lines: [Line] = []
            for t in stride(from: 6, through: 160, by: 3) {
                let x: [Float] = (0..<(t * loaded.taggerFeatures)).map { i -> Float in Float(sin(Double(i + t) * 0.37)) }
                let font: [Int32] = (0..<t).map { i -> Int32 in Int32(i % 7) }
                let cls: [Int32] = (0..<t).map { i -> Int32 in Int32(i % 9) }
                let char: [Int32] = (0..<t).map { i -> Int32 in Int32((i * 13) % 200) }
                lines.append((x, font, cls, char))
            }
            let reference = try lines.map { try loaded.tag(x: $0.x, font: $0.font, cls: $0.cls, char: $0.char) }
            func differs(_ rounds: Int) -> (Int, Float) {
                var n = 0; var worst: Float = 0
                for _ in 0..<rounds { for (i, l) in lines.enumerated() {
                    let out = (try? loaded.tag(x: l.0, font: l.1, cls: l.2, char: l.3)) ?? []
                    if out != reference[i] { n += 1; worst = max(worst, zip(out, reference[i]).map { abs($0 - $1) }.max() ?? .infinity) }
                } }
                return (n, worst)
            }
            print("tagger alone: \(differs(4)) differ of \(4 * lines.count)")
            final class Flag: @unchecked Sendable { var stop = false }
            let flag = Flag()
            for _ in 0..<2 { Thread { while !flag.stop { _ = try? loaded.recognise(batch: [[Float](repeating: 0, count: 448 * 448)]) } }.start() }
            print("tagger while two recognisers run: \(differs(4)) differ of \(4 * lines.count)")
            flag.stop = true
            return
        }
        // --bench-steps: the recogniser's encoder pass and decoder step times for its batch size (blank input, 48 steps).
        if flag("--bench-steps"), let models = option("--models") {
            guard #available(macOS 15.0, *) else { exit(2) }
            let units = option("--recogniser").flatMap(MLUnits.init(rawValue:)) ?? .gpu
            let loaded = try DevicePDFModels(directory: URL(fileURLWithPath: models), recogniserUnits: units.compute)
            for (name, ms) in try loaded.stepTimes(steps: Int(option("--steps") ?? "48") ?? 48) { print("\(name)\t\(String(format: "%.2f", ms)) ms") }
            return
        }
        // --bench-recogniser <samples dir>: the recogniser alone on an export's sample crops (export.json, samples/*.npy).
        if let samples = option("--bench-recogniser"), let models = option("--models") {
            guard #available(macOS 15.0, *) else { exit(2) }
            let units = option("--recogniser").flatMap(MLUnits.init(rawValue:)) ?? .gpu
            try benchRecogniser(models: URL(fileURLWithPath: models), samples: URL(fileURLWithPath: samples), units: units.compute,
                                repeats: Int(option("--repeat") ?? "4") ?? 4, inFlight: Int(option("--in-flight") ?? "1") ?? 1)
            return
        }
        guard let models = option("--models"), let compiler = option("--compiler") else {
            FileHandle.standardError.write(Data("usage: DevicePDFRouteTool <pdf> <out> --models <dir> --compiler <js> [--trace]\n".utf8)); exit(2)
        }
        let detectionsPath = option("--detections"), concurrency = Int(option("--concurrency") ?? "2") ?? 2
        // --serial: the port kit's order (layout on demand, one tagger thread, formulas page by page), for comparisons.
        let serial = flag("--serial"), prefetch = Int(option("--prefetch") ?? "2") ?? 2, taggerThreads = Int(option("--tagger-threads") ?? "1") ?? 1
        let previewPath = option("--preview"), record = flag("--record")
        // --rules transcribe,frontMatter,tidy: converter rules beyond the port kit (DevicePDFRoute.Options.rules).
        let rules = Set((option("--rules") ?? "").split(separator: ",").map { String($0) })
        let authors = option("--authors")?.split(separator: ";").map { String($0) } ?? []
        let title = option("--title"), maxPages = Int(option("--max-pages") ?? "0") ?? 0, trace = flag("--trace"), noOCR = flag("--no-ocr")
        func units(_ name: String?, _ fallback: MLUnits) -> MLUnits { name.flatMap(MLUnits.init(rawValue:)) ?? fallback }
        let layoutUnits = units(option("--layout"), .ne), recogniserUnits = units(option("--recogniser"), .gpu), taggerUnits = units(option("--tagger"), .cpu)
        guard args.count == 2 else { FileHandle.standardError.write(Data("need <pdf> <out>\n".utf8)); exit(2) }
        let pdf = URL(fileURLWithPath: args[0]), out = URL(fileURLWithPath: args[1])
        guard #available(macOS 15.0, *) else { FileHandle.standardError.write(Data("needs macOS 15\n".utf8)); exit(2) }
        let loaded = try DevicePDFModels(directory: URL(fileURLWithPath: models), layoutUnits: layoutUnits.compute,
                                         taggerUnits: taggerUnits.compute, recogniserUnits: recogniserUnits.compute)
        let route = DevicePDFRoute(models: loaded, compilerSource: try String(contentsOfFile: compiler, encoding: .utf8))
        let data = try Data(contentsOf: pdf)
        var lastFormulaReport = 0
        // --detections <file.jsonl>: each page's decoded layout detections (evaluation).
        final class Lines: @unchecked Sendable { var text = "" }
        let lines = Lines()
        var observe: (@Sendable (Int, [DevicePDFModels.Detection], Double) -> Void)? = nil
        if detectionsPath != nil {
            observe = { page, found, scale in
                var rows: [[String: Any]] = []
                for d in found { rows.append(["cls": d.cls, "score": d.score, "box": d.box]) }
                let object: [String: Any] = ["page": page, "scale": scale, "detections": rows]
                if let data = try? JSONSerialization.data(withJSONObject: object) { lines.text += String(decoding: data, as: UTF8.self) + "\n" }
            }
        }
        let output = try route.convert(pdf: data, name: pdf.lastPathComponent, options: { var o = DevicePDFRoute.Options(title: title, trace: trace, maxPages: maxPages, observeDetections: observe); o.recogniserConcurrency = concurrency; o.record = record; o.rules = rules; o.authors = authors; o.ocrFallback = !noOCR
            if serial { o.background = false; o.prefetchPages = 0; o.taggerThreads = 1 } else { o.prefetchPages = prefetch; o.taggerThreads = taggerThreads }
            // --preview <file>: when the first reading (formulas as images) arrives, its seconds since the start.
            if let previewPath {
                let started = Date()
                o.onPreview = { output in
                    let line = "{\"seconds\": \(Date().timeIntervalSince(started)), \"manifest_sha256\": \"\(output.manifestSHA256)\"}"
                    try? line.write(toFile: previewPath, atomically: true, encoding: .utf8)
                }
            }
            return o }(), progress: { stage in
            switch stage {
            case .layout(let page, let of): if page == of || page % 10 == 0 { FileHandle.standardError.write(Data("layout \(page)/\(of)\n".utf8)) }
            case .reading(let done, let of): FileHandle.standardError.write(Data("read \(done)/\(of)\n".utf8)); lastFormulaReport = 0
            case .formulas(let done, let of):
                if done - lastFormulaReport >= 50 { lastFormulaReport = done; FileHandle.standardError.write(Data("  formulas \(done)/\(of)\n".utf8)) }
            }
        })
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try output.manifest.write(to: out.appendingPathComponent("manifest.json"))
        for (path, bytes) in output.members {
            let url = out.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        try output.summary.write(to: out.appendingPathComponent("conversion.json"))
        if let detectionsPath { try lines.text.write(toFile: detectionsPath, atomically: true, encoding: .utf8) }
        if let trace = output.trace { try trace.write(to: out.appendingPathComponent("index.json")) }
        // --record: the host's answers for the Node replay (scripts/device-route-replay.mjs); kept beside the bundle.
        if let recorded = output.record { try recorded.write(to: out.appendingPathComponent("record.json")) }
        // The app's own verification of the bundle, as the reader would admit it.
        do {
            _ = try VerifiedReaderBundle.verify(manifest: output.manifest, expectedSHA256: output.manifestSHA256, members: output.members)
            print("verified \(output.manifestSHA256)")
        } catch { print("NOT VERIFIED: \(error)") }
        print(String(decoding: output.summary, as: UTF8.self))
    }
}

private func cleanFormulaCrops(jobs url: URL) throws {
    struct Job: Decodable { let id: String; let pdf: String; let page: Int; let rect: [Int]; let em: Double; let margin: Int; let content: [Double]?; let out: String }
    let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: url))
    var documents: [String: CGPDFDocument] = [:]
    var cached: (pdf: String, page: Int, image: DevicePDFRaster.RGB)?
    for job in jobs {
        guard job.rect.count == 4, job.rect[2] > job.rect[0], job.rect[3] > job.rect[1] else { throw DevicePDFModelError.unusable("crop audit rectangle") }
        guard job.content == nil || job.content!.count == 4 else { throw DevicePDFModelError.unusable("crop audit content rectangle") }
        if documents[job.pdf] == nil { documents[job.pdf] = CGPDFDocument(URL(fileURLWithPath: job.pdf) as CFURL) }
        guard let page = documents[job.pdf]?.page(at: job.page + 1) else { throw DevicePDFModelError.unusable("crop audit page") }
        let source: DevicePDFRaster.RGB
        if let cached, cached.pdf == job.pdf, cached.page == job.page { source = cached.image }
        else {
            guard let image = DevicePDFRaster.render(page, dpi: 216) else { throw DevicePDFModelError.unusable("crop audit render") }
            source = DevicePDFRaster.rgb(image); cached = (job.pdf, job.page, source)
        }
        let raw = DevicePDFRaster.crop(source, job.rect)
        let content = job.content.map { [$0[0] - Double(job.rect[0]), $0[1] - Double(job.rect[1]), $0[2] - Double(job.rect[0]), $0[3] - Double(job.rect[1])] }
        let before = DevicePDFRaster.cleanFormula(raw, em: job.em, margin: job.margin)
        let after = DevicePDFRaster.cleanFormula(raw, em: job.em, margin: job.margin, content: content)
        let out = URL(fileURLWithPath: job.out, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, image) in [("raw", raw), ("before", before.image), ("after", after.image)] {
            try DevicePDFRaster.png(image).write(to: out.appendingPathComponent(name + ".png"), options: .atomic)
        }
        let meta: [String: Any] = ["id": job.id, "rect": job.rect, "before": before.rect, "after": after.rect]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: out.appendingPathComponent("geometry.json"), options: .atomic)
    }
    print("cleaned \(jobs.count) crops from the same CoreGraphics pixels")
}

enum MLUnits: String {
    case ne, gpu, cpu, all
    var compute: MLComputeUnits {
        switch self { case .ne: return .cpuAndNeuralEngine; case .gpu: return .cpuAndGPU; case .cpu: return .cpuOnly; case .all: return .all }
    }
}

/// The recogniser on an export's sample crops: one crop at a time, then in the export's batches (`--in-flight` batches at
/// once), each sample `repeats` times so batches fill; reports milliseconds per crop and agreement with the export's ids.
@available(macOS 15.0, *)
func benchRecogniser(models: URL, samples: URL, units: MLComputeUnits, repeats: Int, inFlight: Int) throws {
    let loaded = try DevicePDFModels(directory: models, recogniserUnits: units)
    if let issue = loaded.recogniserIssue { print("recogniser not loaded: \(issue)"); exit(1) }
    let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: samples.appendingPathComponent("export.json"))) as! [String: Any]
    let rows = ((meta["equivalence"] as! [String: Any])["samples"] as! [[String: Any]])
    func npy(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: samples.appendingPathComponent("samples").appendingPathComponent(name))
        let headerLength = Int(data[8]) | Int(data[9]) << 8
        let body = data.subdata(in: (10 + headerLength)..<data.count)
        return body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    let inputs = try rows.map { try npy($0["file"] as! String) }
    let expected = rows.map { ($0["ids"] as! [Int]).dropFirst().map { $0 } }
    let placement = rows.map { $0["placement"] as! String }
    let b = loaded.recogniserBatch
    print("batch \(b); load \(loaded.loadSeconds)")
    _ = try loaded.recognise(batch: [inputs[0]])  // warm-up
    // One crop at a time (a batched export pads the rest of its rows).
    var agree = 0, perPlacement: [String: [Double]] = [:]
    for (i, input) in inputs.enumerated() {
        let t = DispatchTime.now().uptimeNanoseconds
        let r = try loaded.recognise(batch: [input])[0]
        perPlacement[placement[i], default: []].append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        if r.tokens == expected[i] { agree += 1 }
    }
    for (k, v) in perPlacement.sorted(by: { $0.key < $1.key }) { print("single \(k): mean \(String(format: "%.0f", v.reduce(0, +) / Double(v.count))) ms per crop (\(v.count))") }
    print("single agreement \(agree)/\(inputs.count)")
    // Batched: every sample `repeats` times, sorted by length (as the route sorts crops by width), `inFlight` batches at once.
    var work: [Int] = []
    for _ in 0..<repeats { work += Array(inputs.indices) }
    work.sort { expected[$0].count < expected[$1].count }
    let groups = stride(from: 0, to: work.count, by: b).map { Array(work[$0..<min(work.count, $0 + b)]) }
    final class Box: @unchecked Sendable { var agree = 0; let lock = NSLock() }
    let box = Box()
    let t = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.concurrentPerform(iterations: max(1, inFlight)) { worker in
        var g = worker
        while g < groups.count {
            if let out = try? loaded.recognise(batch: groups[g].map { inputs[$0] }) {
                let ok = zip(groups[g], out).filter { expected[$0.0] == $0.1.tokens }.count
                box.lock.lock(); box.agree += ok; box.lock.unlock()
            }
            g += max(1, inFlight)
        }
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
    print("batched: \(work.count) crops in \(groups.count) batches, \(String(format: "%.0f", ms)) ms, \(String(format: "%.1f", ms / Double(work.count))) ms per crop; agreement \(box.agree)/\(work.count)")
}

/// The converter on recorded host answers (`--record`), in JavaScriptCore, timed; blank images of the asked sizes.
func replayConverter(record url: URL, compiler: URL, repeats: Int) throws {
    let record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let pages = record["pages"] as! [Any]
    var tags: [String: Any] = [:], recognitions: [String: Any] = [:]
    for pair in record["tags"] as! [[Any]] { tags[pair[0] as! String] = pair[1] }
    for pair in record["recognitions"] as! [[Any]] { recognitions[pair[0] as! String] = pair[1] }
    var input = record["input"] as! [String: Any]
    input["trace"] = false; input["record"] = false
    let source = try String(contentsOf: compiler, encoding: .utf8)
    for round in 0..<max(1, repeats) {
        let context = JSContext()!
        context.exceptionHandler = { _, e in FileHandle.standardError.write(Data("JS: \(e?.toString() ?? "")\n".utf8)) }
        context.evaluateScript(source)
        let api = context.objectForKeyedSubscript("GradstepDevicePDF")!
        let host = JSValue(newObjectIn: context)!
        final class Count { var misses = 0 }
        let count = Count()
        let page: @convention(block) (Int) -> Any = { i in pages[i] }
        let tag: @convention(block) (JSValue) -> Any = { lines in
            let n = Int(lines.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            var out: [Any] = []
            for i in 0..<n {
                let l = lines.objectAtIndexedSubscript(i)!
                let chars = ((l.objectForKeyedSubscript("char")?.toArray() as? [NSNumber]) ?? []).map { String($0.intValue) }
                let fonts = ((l.objectForKeyedSubscript("font")?.toArray() as? [NSNumber]) ?? []).map { String($0.intValue) }
                let x = ((l.objectForKeyedSubscript("x")?.toArray() as? [NSNumber]) ?? []).map { String(format: "%.3f", $0.doubleValue) }
                let key = chars.joined(separator: ",") + "|" + fonts.joined(separator: ",") + "|" + x.joined(separator: ",")
                if let hit = tags[key] { out.append(hit) } else { count.misses += 1; out.append(fonts.map { _ in -10.0 }) }
            }
            return out
        }
        let recognise: @convention(block) (JSValue) -> Any = { crops in
            let n = Int(crops.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            var out: [Any] = []
            for i in 0..<n {
                let c = crops.objectAtIndexedSubscript(i)!
                let rect = ((c.objectForKeyedSubscript("rect")?.toArray() as? [NSNumber]) ?? []).map { String($0.intValue) }.joined(separator: ",")
                out.append(recognitions["\(c.objectForKeyedSubscript("page")!.toInt32()):\(rect)"] ?? NSNull())
            }
            return out
        }
        let image: @convention(block) (JSValue) -> Any = { r in
            let rect = ((r.objectForKeyedSubscript("rect")?.toArray() as? [NSNumber]) ?? []).map(\.intValue)
            guard rect.count == 4 else { return NSNull() }
            let w = max(1, rect[2] - rect[0]), h = max(1, rect[3] - rect[1])
            let png = DevicePDFRaster.png(DevicePDFRaster.RGB(width: w, height: h, pixels: [UInt8](repeating: 230, count: w * h * 3)))
            var out: [String: Any] = ["png": png.base64EncodedString(), "width": w, "height": h]
            if let clean = r.objectForKeyedSubscript("clean"), clean.isObject { out["rect"] = rect }
            return out
        }
        host.setObject(page, forKeyedSubscript: "page" as NSString)
        host.setObject(tag, forKeyedSubscript: "tag" as NSString)
        host.setObject(recognise, forKeyedSubscript: "recognise" as NSString)
        host.setObject(image, forKeyedSubscript: "image" as NSString)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = api.invokeMethod("convert", withArguments: [input, host])
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let sha = result?.objectForKeyedSubscript("manifest_sha256")?.toString() ?? "none"
        print("round \(round): \(String(format: "%.2f", seconds)) s for \(pages.count) pages (\(String(format: "%.3f", seconds / Double(pages.count))) s/page), tag misses \(count.misses), manifest \(sha.prefix(12)), JIT \(ProcessInfo.processInfo.environment["JSC_useJIT"] ?? "default")")
    }
}

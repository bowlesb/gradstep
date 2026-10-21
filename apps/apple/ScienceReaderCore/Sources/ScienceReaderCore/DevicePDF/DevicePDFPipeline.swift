import CoreGraphics
import Foundation

/// Stage timings that several threads add to (the busy seconds of each stage; stages overlap, so they can sum to more
/// than the wall time).
final class DevicePDFTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: [String: Double] = ["render": 0, "layout": 0, "text": 0, "tag": 0, "equations": 0, "images": 0]
    func add(_ key: String, _ value: Double) { lock.lock(); seconds[key, default: 0] += value; lock.unlock() }
    func timed<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { add(key, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9) }
        return try body()
    }
    var snapshot: [String: Double] { lock.lock(); defer { lock.unlock() }; return seconds }
}

/// Each page's layout and text read ahead of the converter (docs/reviews/DEVICE_PDF_ROUTE_20261021.md): `workers` pages
/// at once, in order, each worker with its own document (Core Graphics' PDF objects are not shared across threads). The
/// converter's `host.page(i)` waits for page i. The page image is not kept: the reading renders it again for its crops.
@available(iOS 18.0, macOS 15.0, *)
final class DevicePDFPagePrefetch: @unchecked Sendable {
    struct Page { let width: Double, height: Double; let imageWidth: Int, imageHeight: Int; let scale: Double
        let glyphs: [DevicePDFGlyph]; let detections: [DevicePDFModels.Detection]; let failure: String? }
    private let condition = NSCondition()
    private var pages: [Int: Page] = [:]
    private var next = 0, stopped = false
    private let count: Int

    init(data: Data, count: Int, workers: Int, models: DevicePDFModels, timings: DevicePDFTimings) {
        self.count = count
        for _ in 0..<max(1, workers) {
            let thread = Thread { [self] in
                guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return }
                while let index = claim() {
                    let page = Self.read(document: document, index: index, models: models, timings: timings)
                    condition.lock(); pages[index] = page; condition.broadcast(); condition.unlock()
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
    private func claim() -> Int? {
        condition.lock(); defer { condition.unlock() }
        guard !stopped, next < count else { return nil }
        next += 1; return next - 1
    }
    static func read(document: CGPDFDocument, index: Int, models: DevicePDFModels, timings: DevicePDFTimings) -> Page {
        guard let pdfPage = document.page(at: index + 1), let image = timings.timed("render", { DevicePDFRaster.render(pdfPage, dpi: 150) }) else {
            return Page(width: 0, height: 0, imageWidth: 0, imageHeight: 0, scale: 0, glyphs: [], detections: [], failure: "page \(index + 1)")
        }
        let size = DevicePDFTextLayer.pageSize(page: pdfPage)
        let glyphs = timings.timed("text") { DevicePDFTextLayer.glyphs(page: pdfPage) }
        do {
            // The canvas from the same pixels the on-demand path draws (the page's RGB copy): drawn from the rendered
            // image directly, a few detections near a threshold came out differently.
            guard let pixels = DevicePDFRaster.cgImage(DevicePDFRaster.rgb(image)) else { throw DevicePDFModelError.unusable("page image") }
            let detected = try timings.timed("layout") { try models.detect(page: pixels) }
            return Page(width: size.width, height: size.height, imageWidth: image.width, imageHeight: image.height, scale: detected.scale,
                        glyphs: glyphs, detections: detected.detections, failure: nil)
        } catch {
            return Page(width: size.width, height: size.height, imageWidth: image.width, imageHeight: image.height, scale: 1, glyphs: glyphs,
                        detections: [], failure: "layout: \(error)")
        }
    }
    /// Page `index`, waiting for it; nil after `stop`.
    func page(_ index: Int) -> Page? {
        condition.lock(); defer { condition.unlock() }
        while pages[index] == nil && !stopped { condition.wait() }
        return pages.removeValue(forKey: index)
    }
    func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
}

/// The recogniser in the background (port revision 5): the converter submits each page's crops and reads on; worker
/// threads run the recogniser on batches of the export's size, crops of one placement together and the narrowest first
/// (a batch decodes until its longest crop ends, so like lengths waste fewer steps); `collect` waits for a submission.
@available(iOS 18.0, macOS 15.0, *)
final class DevicePDFBackgroundRecogniser: @unchecked Sendable {
    struct Item { let ticket: Int; let row: Int; let crop: DevicePDFRaster.RGB?; let display: Bool }
    private let condition = NSCondition()
    private var inline: [Item] = [], display: [Item] = []
    private var results: [Int: [Any]] = [:], remaining: [Int: Int] = [:]
    private var tickets = 0, closed = false, stopped = false, running = 0
    private(set) var done = 0, total = 0
    private let models: DevicePDFModels
    private let batch: Int
    private let progress: (Int, Int) -> Void

    init(models: DevicePDFModels, workers: Int, timings: DevicePDFTimings, progress: @escaping (Int, Int) -> Void) {
        self.models = models; self.batch = max(1, models.recogniserBatch); self.progress = progress
        for _ in 0..<max(1, workers) {
            let thread = Thread { [self] in
                while let items = take() {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let rows = run(items)
                    timings.add("equations", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                    condition.lock()
                    for (item, row) in zip(items, rows) { results[item.ticket]?[item.row] = row; remaining[item.ticket, default: 1] -= 1 }
                    done += items.count; running -= 1
                    progress(done, total)
                    condition.broadcast(); condition.unlock()
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// The crops of one page (already cut on this thread, which owns the page images); returns the submission's ticket.
    func submit(_ crops: [(DevicePDFRaster.RGB?, Bool)]) -> Int {
        condition.lock(); defer { condition.unlock() }
        let ticket = tickets; tickets += 1
        results[ticket] = [Any](repeating: NSNull(), count: crops.count); remaining[ticket] = crops.count; total += crops.count
        for (row, (crop, isDisplay)) in crops.enumerated() {
            let item = Item(ticket: ticket, row: row, crop: crop, display: isDisplay)
            if isDisplay { display.append(item) } else { inline.append(item) }
        }
        condition.broadcast()
        return ticket
    }
    /// A submission's results (`{latex, probs}` or NSNull per crop), waiting for them. The first collect closes the
    /// queue: the converter submits nothing after it starts collecting.
    func collect(_ ticket: Int) -> [Any] {
        condition.lock(); defer { condition.unlock() }
        closed = true; condition.broadcast()
        while (remaining[ticket] ?? 0) > 0 && !stopped { condition.wait() }
        return results.removeValue(forKey: ticket) ?? []
    }
    func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }

    /// The next batch: a full batch of one placement, narrowest first; once the queue is closed, whatever is left; and
    /// when the recogniser would otherwise sit idle for a moment, a part batch (it costs about what a full one does).
    private func take() -> [Item]? {
        condition.lock(); defer { condition.unlock() }
        var idle = false
        while true {
            if stopped { return nil }
            let pick: Bool? = display.count >= batch || (closed && !display.isEmpty) ? true
                : inline.count >= batch || (closed && !inline.isEmpty) ? false
                : (idle && running == 0 && !(display.isEmpty && inline.isEmpty)) ? display.count >= inline.count : nil
            if let isDisplay = pick {
                var pool = isDisplay ? display : inline
                pool.sort { ($0.crop?.width ?? 0) < ($1.crop?.width ?? 0) }
                let items = Array(pool.prefix(batch))
                pool.removeFirst(items.count)
                if isDisplay { display = pool } else { inline = pool }
                running += 1
                return items
            }
            if closed && inline.isEmpty && display.isEmpty { return nil }
            idle = !condition.wait(until: Date().addingTimeInterval(0.2))
        }
    }

    private func run(_ items: [Item]) -> [Any] {
        let c = models.configuration.recogniser
        var inputs = [[Float]?](repeating: nil, count: items.count)
        inputs.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: items.count) { i in
                if let crop = items[i].crop { out[i] = DevicePDFRaster.recogniserPixels(crop, size: c.imageSize, mean: c.mean, std: c.std) }
            }
        }
        let present = inputs.indices.filter { inputs[$0] != nil }
        var rows = [Any](repeating: NSNull(), count: items.count)
        guard !present.isEmpty, let recognised = try? models.recognise(batch: present.map { inputs[$0]! }) else { return rows }
        for (i, r) in zip(present, recognised) { rows[i] = ["latex": r.latex, "probs": r.probabilities] as [String: Any] }
        return rows
    }
}

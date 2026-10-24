import SwiftUI
import ScienceReaderCore

// Show in PDF (owner, 2026-10-24: "it would be neat to somehow have a feature where, wherever you select, it can guess where
// in the pdf that is and show it to you with a pop up that you can zoom around in"; docs/architecture/FIGURE_VIEW.md "Show in
// PDF"). For an on-device reading whose PDF is on this device: the selected passage (or a tapped equation) found on the PDF
// (PDFPassageLocator) and shown on its page, framed and highlighted, to pinch out to the whole page and step through the
// pages. The PDF is read on this device only when asked, drawn as far as it shows, and let go when the pop-up closes.

/// What Show in PDF looks for, and the PDF on this device.
struct ShowInPDFRequest: Identifiable {
    enum Subject { case text, equation }
    let id = UUID()
    let query: PDFPassageQuery
    /// How far through the reading the passage's block is (0…1), for a reading without recorded places.
    let blockFraction: Double?
    let subject: Subject
    let load: @Sendable () async throws -> Data
}

/// The PDF, read once for the pop-up: pages, their text layers (as searched) and their drawing, one at a time.
actor ShowInPDFDocument {
    private let document: CGPDFDocument
    let pageCount: Int
    private var glyphs: [Int: [DevicePDFGlyph]] = [:]

    init?(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0,
              !document.isEncrypted || document.isUnlocked else { return nil }
        self.document = document; pageCount = document.numberOfPages
    }

    /// Each page's size as shown (the glyphs' and the drawing's points), from 0.
    func sizes() -> [CGSize] { (0..<pageCount).map { document.page(at: $0 + 1).map(DevicePDFRaster.shownSize) ?? CGSize(width: 612, height: 792) } }

    func locate(_ query: PDFPassageQuery, blockFraction: Double?) -> PDFPassageLocation? {
        var query = query
        if let blockFraction { query.expectedPage = blockFraction * Double(max(0, pageCount - 1)) }
        return PDFPassageLocator.locate(query, pageCount: pageCount) { page in
            if let known = glyphs[page] { return known }
            let read = document.page(at: page + 1).map { DevicePDFTextLayer.glyphs(page: $0) } ?? []
            glyphs[page] = read
            return read
        }
    }

    /// `region` of a page (points) at `density` pixels per point.
    func render(page: Int, density: Double, region: CGRect) -> ShowInPDFImage {
        guard !Task.isCancelled, let pdfPage = document.page(at: page + 1) else { return ShowInPDFImage(image: nil) }
        return ShowInPDFImage(image: DevicePDFRaster.render(pdfPage, pixelsPerPoint: density, region: region))
    }
}

struct ShowInPDFImage: @unchecked Sendable { let image: CGImage? }

extension View {
    /// Show in PDF's pop-up: full screen on iPhone and upright iPad (as the AI explainer covers the page); sideways on iPad,
    /// over the slot the reader is in (`slotSheet`), never across both; a sheet on the Mac, as the figure viewer is there.
    func showInPDFPresentation(_ request: Binding<ShowInPDFRequest?>, wide: Bool) -> some View {
        modifier(ShowInPDFPresentation(request: request, wide: wide))
    }
}

private struct ShowInPDFPresentation: ViewModifier {
    @Binding var request: ShowInPDFRequest?
    let wide: Bool
    @Environment(\.figureViewerWindowSize) private var windowSize

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.sheet(item: $request) { value in
            ShowInPDFView(request: value) { request = nil }
                .frame(minWidth: 640, idealWidth: max(640, windowSize.width * 0.6), minHeight: 640, idealHeight: max(640, windowSize.height * 0.85))
                .macSheetKeys()
        }
        #else
        content
            .fullScreenCover(item: wide ? .constant(nil) : $request) { value in ShowInPDFView(request: value) { request = nil } }
            .slotSheet(item: wide ? $request : .constant(nil)) { value in ShowInPDFView(request: value, inSlot: true) { request = nil } }
        #endif
    }
}

/// The pop-up: the page with the passage, a slim top row (where it is, the page's neighbours, X).
struct ShowInPDFView: View {
    let request: ShowInPDFRequest
    var inSlot = false
    let close: () -> Void

    private enum Phase {
        case finding
        case unreadable
        /// Nothing to show for the passage: said plainly, with the PDF still there to browse.
        case missing(ShowInPDFDocument, [CGSize])
        case shown(ShowInPDFDocument, [CGSize], PDFPassageLocation?)
    }
    @State private var phase: Phase = .finding
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground).ignoresSafeArea()
            switch phase {
            case .finding:
                ProgressView("Finding it in the PDF…").accessibilityIdentifier("showInPDF.finding")
            case .unreadable:
                ContentUnavailableView("Couldn’t open the PDF", systemImage: "doc.questionmark",
                                       description: Text("The PDF this reading was made from couldn’t be read on this device."))
                    .accessibilityIdentifier("showInPDF.unreadable")
            case .missing(let document, let sizes):
                ContentUnavailableView {
                    Label("Not found in the PDF", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(request.subject == .equation ? "This reading has no record of where this equation is in the PDF."
                         : "These words aren’t in the PDF’s text, and this reading has no record of where they came from.")
                } actions: {
                    Button("Browse the PDF") { page = 0; phase = .shown(document, sizes, nil) }.accessibilityIdentifier("showInPDF.browse")
                }
                .accessibilityIdentifier("showInPDF.missing")
            case .shown(let document, let sizes, let location):
                PDFPageZoomView(document: document, page: page, pageSize: sizes[min(page, sizes.count - 1)],
                                location: location?.page == page ? location : nil,
                                blocks: request.query.regions.filter { $0.page == page }.map(\.rect))
                    .ignoresSafeArea(edges: inSlot ? [] : .all)
                    .id(page)
            }
        }
        .overlay(alignment: .top) { topRow }
        .task {
            guard case .finding = phase else { return }
            guard let data = try? await request.load(), let document = ShowInPDFDocument(data: data) else { phase = .unreadable; return }
            let sizes = await document.sizes()
            let location = await document.locate(request.query, blockFraction: request.blockFraction)
            if let location { page = location.page; phase = .shown(document, sizes, location) }
            else { phase = .missing(document, sizes) }
        }
        .macSheetKeys()
    }

    private var pages: Int {
        switch phase { case .shown(_, let sizes, _), .missing(_, let sizes): sizes.count; default: 0 }
    }
    private var location: PDFPassageLocation? { if case .shown(_, _, let location) = phase { location } else { nil } }

    /// Where it is (the page; how sure), the previous and next pages, X.
    private var topRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pages > 0 && isShown ? "Page \(page + 1) of \(pages)" : "Show in PDF").font(.headline).lineLimit(1)
                    .accessibilityIdentifier("showInPDF.title")
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).accessibilityIdentifier("showInPDF.note") }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            Spacer(minLength: 8)
            if isShown && pages > 1 {
                roundButton("chevron.left", label: "Previous page", identifier: "showInPDF.previous") { go(-1) }
                    .disabled(page == 0).keyboardShortcut(.leftArrow, modifiers: [])
                roundButton("chevron.right", label: "Next page", identifier: "showInPDF.next") { go(1) }
                    .disabled(page >= pages - 1).keyboardShortcut(.rightArrow, modifiers: [])
            }
            roundButton("xmark", label: "Close", identifier: "showInPDF.close") { close() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private var isShown: Bool { if case .shown = phase { true } else { false } }

    /// What the highlight is, when it isn't the exact words (and only on the passage's page).
    private var note: String? {
        guard let location, location.page == page else { return nil }
        switch location.match {
        case .words: return nil
        case .approximate: return "Closest match: the reading differs from the PDF here."
        case .region: return request.subject == .equation ? "Where the model read this equation." : "Where the model read this passage; the exact words weren’t found."
        }
    }

    private func go(_ step: Int) {
        let next = min(max(0, page + step), max(0, pages - 1))
        guard next != page else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { page = next }
    }

    private func roundButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                .background(Circle().fill(.regularMaterial))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

// MARK: - The page

private struct PDFPageZoomView: UIViewRepresentable {
    let document: ShowInPDFDocument
    let page: Int
    let pageSize: CGSize
    let location: PDFPassageLocation?
    let blocks: [CGRect]
    func makeUIView(context: Context) -> PDFPageScroll {
        PDFPageScroll(document: document, page: page, pageSize: pageSize, location: location, blocks: blocks)
    }
    func updateUIView(_ view: PDFPageScroll, context: Context) {}
}

/// One page in a zooming scroll view, measured in page points (zoom = view points per page point): the whole page drawn
/// once at about twice the screen's pixels for the fitted page (FigurePageLayout.renderDensity), and, zoomed past that, the
/// visible part drawn again sharp when the view comes to rest; the passage's lines filled, its extent outlined.
final class PDFPageScroll: UIScrollView, UIScrollViewDelegate {
    private let document: ShowInPDFDocument
    private let pageIndex: Int
    private let pageSize: CGSize
    private let location: PDFPassageLocation?
    /// The passage's block's recorded boxes on this page: a part of a line opens with its column across.
    private let blocks: [CGRect]
    private let canvas = UIView()
    private let base = UIImageView()
    private let detail = UIImageView()
    private let marks = CAShapeLayer()
    private let outline = CAShapeLayer()
    private var laidOut = CGSize.zero
    private var baseDensity = 0.0
    private var baseTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = 0
    private var drawn = false

    init(document: ShowInPDFDocument, page: Int, pageSize: CGSize, location: PDFPassageLocation?, blocks: [CGRect]) {
        self.document = document; pageIndex = page; self.pageSize = pageSize; self.location = location; self.blocks = blocks
        super.init(frame: .zero)
        delegate = self
        bouncesZoom = true; contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        canvas.frame = CGRect(origin: .zero, size: pageSize)
        canvas.backgroundColor = .white
        canvas.layer.shadowColor = UIColor.black.cgColor; canvas.layer.shadowOpacity = 0.12; canvas.layer.shadowRadius = 6; canvas.layer.shadowOffset = .zero
        base.frame = canvas.bounds; base.contentMode = .scaleToFill
        detail.isHidden = true; detail.contentMode = .scaleToFill
        canvas.addSubview(base); canvas.addSubview(detail)
        if let location {
            let fill = UIBezierPath()
            for rect in location.lines { fill.append(UIBezierPath(rect: rect)) }
            marks.path = location.match == .region ? nil : fill.cgPath
            marks.fillColor = UIColor.systemYellow.withAlphaComponent(0.32).cgColor
            let box = location.match == .region ? fill : UIBezierPath(roundedRect: location.bounds.insetBy(dx: -2, dy: -1.5), cornerRadius: 2)
            outline.path = box.cgPath
            outline.fillColor = UIColor.clear.cgColor
            outline.strokeColor = UIColor.tintColor.resolvedColor(with: traitCollection).cgColor
            if location.match != .words { outline.lineDashPattern = [6, 4] }
            canvas.layer.addSublayer(marks); canvas.layer.addSublayer(outline)
        }
        addSubview(canvas)
        contentSize = pageSize
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:))); doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        isAccessibilityElement = true; accessibilityTraits = [.image, .adjustable]
        accessibilityIdentifier = "showInPDF.page"
        accessibilityLabel = "Page \(page + 1) of the PDF" + (location == nil ? "" : location!.match == .words ? ", the passage highlighted" : ", its place outlined")
        accessibilityHint = "Pinch to zoom, drag to move; double tap for the whole page."
        updateAccessibilityValue()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { baseTask?.cancel(); detailTask?.cancel() }

    private var fitZoom: CGFloat { FigureZoomMath.fitZoom(CGRect(origin: .zero, size: pageSize), in: bounds.size) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != laidOut else { return }
        let first = laidOut == .zero
        laidOut = bounds.size
        minimumZoomScale = fitZoom
        // Close enough to read a subscript: twelve times the whole page, at least 8 view points per page point.
        maximumZoomScale = max(fitZoom * 12, 8)
        if first { frameOpening() } else { setZoomScale(max(minimumZoomScale, min(zoomScale, maximumZoomScale)), animated: false); centreContent() }
        drawBase()
    }

    /// The passage framed (the whole page without one).
    private func frameOpening(animated: Bool = false) {
        let opening = PDFPassageZoom.opening(focus: location?.bounds ?? .null, page: pageSize, view: bounds.size, maximumZoom: fitZoom * 6,
                                             blocks: blocks)
        setZoomScale(opening.zoom, animated: false)
        centreContent()
        setContentOffset(PDFPassageZoom.offset(centre: opening.centre, zoom: opening.zoom, page: pageSize, view: bounds.size), animated: animated)
        outline.lineWidth = 2 / zoomScale
        settle()
    }

    private func centreContent() {
        let size = CGSize(width: pageSize.width * zoomScale, height: pageSize.height * zoomScale)
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - size.height) / 2), left: max(0, (bounds.width - size.width) / 2),
                                    bottom: max(0, (bounds.height - size.height) / 2), right: max(0, (bounds.width - size.width) / 2))
    }

    /// The whole page, once, sharp for the fitted page and a little closer.
    private func drawBase() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let density = FigurePageLayout.renderDensity(pageSize: pageSize, viewSize: bounds.size, screenScale: max(1, scale), figureDensity: 1)
        guard abs(density - baseDensity) > 0.01 else { return }
        baseDensity = density
        baseTask?.cancel()
        let document = document, page = pageIndex, region = CGRect(origin: .zero, size: pageSize)
        baseTask = Task { [weak self] in
            let drawn = await document.render(page: page, density: density, region: region)
            guard let self, !Task.isCancelled, let image = drawn.image else { return }
            self.base.image = UIImage(cgImage: image)
            self.drawn = true; self.updateAccessibilityValue()
            self.settle()
        }
    }

    /// At rest past the base's sharpness: the visible part drawn again at the screen's pixels.
    private func settle() {
        detailTask?.cancel(); detailGeneration += 1
        let scale = Double(window?.screen.scale ?? traitCollection.displayScale)
        let density = Double(zoomScale) * max(1, scale)
        guard baseDensity > 0, density > baseDensity * 1.15 else { detail.isHidden = true; detail.image = nil; return }
        let visible = convert(bounds, to: canvas).intersection(canvas.bounds)
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return }
        // A margin of a quarter view each way, so a small pan stays sharp; no more than about 16 million pixels.
        let region = visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 4).intersection(canvas.bounds)
        let capped = min(density, sqrt(16_000_000 / Double(region.width * region.height)))
        let generation = detailGeneration, document = document, page = pageIndex
        detailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let drawn = await document.render(page: page, density: capped, region: region)
            guard let self, !Task.isCancelled, generation == self.detailGeneration, let image = drawn.image else { return }
            self.detail.image = UIImage(cgImage: image)
            self.detail.frame = region
            self.detail.isHidden = false
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centreContent()
        outline.lineWidth = 2 / max(0.01, zoomScale)
        updateAccessibilityValue()
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    /// Double tap: the whole page, and back to the passage (or in, where tapped, without one).
    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 { setZoomScale(minimumZoomScale, animated: true); return }
        if location != nil { frameOpening(animated: true); return }
        let point = tap.location(in: canvas), z = min(maximumZoomScale, minimumZoomScale * 3)
        zoom(to: CGRect(x: point.x - bounds.width / z / 2, y: point.y - bounds.height / z / 2, width: bounds.width / z, height: bounds.height / z), animated: true)
    }

    private func updateAccessibilityValue() {
        let percent = Int((zoomScale / max(0.0001, fitZoom) * 100).rounded())
        let whole = zoomScale <= minimumZoomScale * 1.01
        accessibilityValue = "\(whole ? "whole page" : "\(percent)%")\(drawn ? ", drawn" : "")"
    }
    override func accessibilityIncrement() { setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: false); settle() }
    override func accessibilityDecrement() { setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: false); settle() }
}

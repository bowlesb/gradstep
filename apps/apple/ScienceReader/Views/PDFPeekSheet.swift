import SwiftUI
import PDFKit
import ScienceReaderCore

struct PDFPeekPresentation: Identifiable {
    let id = UUID()
    let paper: Paper
    let scope: ReaderDocumentScope
    let snapshot: PDFReadingSnapshot?
}

/// Like the figure explainer, the PDF owns its opening motion instead of a system sheet slide.
@MainActor func presentPDFPeek(_ change: () -> Void) {
    var transaction = Transaction(); transaction.disablesAnimations = true
    withTransaction(transaction, change)
}

extension View {
    func pdfPeekPresentation(model: ReaderModel) -> some View { modifier(PDFPeekCover(model: model)) }
}

private struct PDFPeekCover: ViewModifier {
    @Bindable var model: ReaderModel
    @Environment(\.figureViewerWindowSize) private var windowSize
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.sheet(item: $model.pdfPeek) { presentation in
            if #available(iOS 18.0, *), windowSize.width > 0, windowSize.height > 0 {
                viewer(presentation).frame(width: windowSize.width, height: windowSize.height).presentationSizing(.fitted)
            } else { viewer(presentation) }
        }
        #else
        content.fullScreenCover(item: $model.pdfPeek) { presentation in
            viewer(presentation).presentationBackground(.clear)
        }
        #endif
    }
    private func viewer(_ presentation: PDFPeekPresentation) -> some View {
        PDFPeekSheet(model: model, presentation: presentation, worker: model.pdfPeekWorker) {
            presentPDFPeek { model.pdfPeek = nil }
        }.id(presentation.id)
    }
}

/// Full-screen PDF; dismissal never asks WebKit to restore, scroll or clear a selection.
struct PDFPeekSheet: View {
    let model: ReaderModel
    let presentation: PDFPeekPresentation
    let worker: PDFPositionWorker
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var download = false
    @State private var retry = 0
    @State private var missing = false
    @State private var loading = true
    @State private var data: Data?
    @State private var match: PDFPositionMatch?
    @State private var page = 0
    @State private var pageCount = 0
    @State private var message = "Finding this passage on your device…"

    private var status: String {
        guard match?.status == "matched", page > 0 else { return message }
        let estimate = page == (match?.ranges.first?.page ?? -1) + 1
            ? " · \(presentation.snapshot?.nearby == true ? "Nearby text" : "Estimated position")" : ""
        return "Page \(page) of \(pageCount)\(estimate)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PDF").font(.headline)
                    if data != nil {
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .accessibilityIdentifier("pdfPeek.status")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36).background(Circle().fill(.regularMaterial))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close PDF and return to reader")
                .accessibilityIdentifier("pdfPeek.close").keyboardShortcut(.escape, modifiers: [])
            }
            // Keep the document and X available even in landscape at the largest accessibility sizes.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .padding(.horizontal, 16).padding(.vertical, 4)
            .contentShape(Rectangle())
            // Only the top row dismisses: dragging the PDF itself always browses the document.
            .simultaneousGesture(DragGesture().onEnded { value in
                if value.translation.height > 60 && value.translation.height > abs(value.translation.width) * 1.2 { close() }
            })
            if let data {
                PDFPeekView(data: data, match: match, reduceMotion: reduceMotion, onOutline: { visible in
                    if !visible { match = nil; message = "Position unavailable · Browse PDF" }
                }, onPage: { number, count in page = number; pageCount = count })
                    .accessibilityIdentifier("pdfPeek.document").ignoresSafeArea(.container, edges: .bottom)
            } else if loading {
                ProgressView(download ? "Downloading PDF to this device…" : "Opening PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(missing ? "PDF download needed" : "PDF preview unavailable", systemImage: "doc")
                } description: { Text(message) } actions: {
                    if missing {
                        Button("Download PDF to this device") { download = true; retry += 1 }
                            .accessibilityIdentifier("pdfPeek.download")
                    } else if presentation.snapshot != nil {
                        Button("Try again") { retry += 1 }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
        .accessibilityAction(.escape, close)
        .overlay {
            if scenePhase != .active && !Platform.isMac {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: retry) { await load() }
        .macSheetKeys()
    }

    @MainActor private func load() async {
        loading = true; missing = false
        guard let snapshot = presentation.snapshot else {
            message = "This reading position could not be captured. Close the preview and try again."; loading = false; return
        }
        var original: Data?
        do {
            let (bytes, identity) = try await model.pdfForPeek(paper: presentation.paper, scope: presentation.scope, download: download)
            original = bytes
            try Task.checkCancellation()
            guard model.isCurrentPDFPeek(paper: presentation.paper, scope: presentation.scope) else { return }
            let result = try await worker.match(data: bytes, identity: identity, text: snapshot.text)
            try Task.checkCancellation()
            guard model.isCurrentPDFPeek(paper: presentation.paper, scope: presentation.scope) else { return }
            // Publish together so a different page does not flash up while matching.
            match = result; data = bytes
            if result.status == "matched", let page = result.ranges.first?.page {
                message = "Estimated position · Page \(page + 1)"
            } else {
                message = result.reason == "no-text"
                    ? "No searchable text · Browse PDF"
                    : "Position not found · Browse PDF"
            }
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, model.isCurrentPDFPeek(paper: presentation.paper, scope: presentation.scope) else { return }
            if case PDFPeekError.missing = error {
                missing = true; message = "Download this paper’s exact version directly from arXiv. It stays on this device."
            } else if case PDFPeekError.unreadable = error {
                data = nil; message = "This PDF is damaged or password-protected and could not be opened."
            } else if let original {
                data = original; message = "Position unavailable · Browse PDF"
            } else if case PDFPeekError.unavailable = error {
                message = "An exact arXiv version and local paper storage are needed for this preview."
            } else if case PDFPeekError.wrongRevision = error {
                message = "arXiv did not return the requested version. The PDF was not saved."
            } else {
                message = "The PDF could not be opened. Check your connection if it needs downloading, then try again."
            }
        }
        loading = false
    }
}

struct PDFPeekView: UIViewRepresentable {
    let data: Data
    let match: PDFPositionMatch?
    var reduceMotion = false
    var onOutline: (Bool) -> Void = { _ in }
    var onPage: (Int, Int) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PDFPeekNativeView {
        let view = PDFPeekNativeView()
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFPeekNativeView, context: Context) {
        view.reduceMotion = reduceMotion
        view.onPage = { number, count in DispatchQueue.main.async { onPage(number, count) } }
        if let match, match.status == "matched", !view.appliedMatch {
            view.apply(match)
            let valid = view.targetPage != nil
            DispatchQueue.main.async { onOutline(valid) }
        }
    }
    static func dismantleUIView(_ view: PDFPeekNativeView, coordinator: ()) { view.stopOpening() }
}

/// PDFKit retains its normal scrolling, selection and pinch zoom. A screen-space outline is drawn only during
/// the opening motion, following PDFKit's own crop/rotation conversion on every frame. No PDF annotation is made.
final class PDFPeekNativeView: PDFView {
    private(set) var appliedMatch = false
    private(set) var targetPage: PDFPage?
    private(set) var targetBounds = CGRect.zero
    private(set) var outlineVisible = false
    private(set) var openingScale: CGFloat = 1
    var reduceMotion = UIAccessibility.isReduceMotionEnabled
    var onPage: (Int, Int) -> Void = { _, _ in }
    private var landing = false
    private let outline = CAShapeLayer()
    var outlineOpacity: Float { outline.opacity }
    var outlineFrame: CGRect { outline.path?.boundingBoxOfPath ?? .zero }
    private var tick: CADisplayLink?
    private var began = 0.0
    private var targetScale: CGFloat = 1
    private var cameraFinished = false
    static let zoomDuration = 0.35
    static let fadeDuration = 1.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoScales = true; displayMode = .singlePageContinuous; displayDirection = .vertical
        backgroundColor = .systemBackground
        outline.fillColor = nil; outline.strokeColor = FigurePartCrop.outline; outline.lineWidth = 2
        outline.opacity = 0; layer.addSublayer(outline)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ match: PDFPositionMatch) {
        guard !appliedMatch, match.status == "matched", let document else { return }
        appliedMatch = true
        for range in match.ranges.prefix(3) {
            guard range.page >= 0, range.page < document.pageCount, let page = document.page(at: range.page),
                  range.location >= 0, range.length > 0,
                  range.location <= page.numberOfCharacters, range.length <= page.numberOfCharacters - range.location,
                  let selection = page.selection(for: NSRange(location: range.location, length: range.length)) else { continue }
            let box = selection.bounds(for: page).intersection(page.bounds(for: displayBox))
            guard !box.isNull, !box.isEmpty, [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { continue }
            targetPage = page; targetBounds = box.insetBy(dx: -6, dy: -6).intersection(page.bounds(for: displayBox))
            landing = true; setNeedsLayout(); break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard landing, bounds.width > 0, bounds.height > 0, let page = targetPage else { return }
        landing = false
        // Land on the page first: PDFKit's go(to: selection) may leave it at the bottom below the previous page.
        go(to: page)
        let crop = page.bounds(for: displayBox)
        let pageSize = convert(crop, from: page).size, focusSize = convert(targetBounds, from: page).size
        let scale = max(scaleFactor, 0.001)
        openingScale = scale * min((bounds.width - 24) / max(pageSize.width, 1), (bounds.height - 24) / max(pageSize.height, 1))
        targetScale = min(openingScale * 3, scale * min((bounds.width - 40) / max(focusSize.width, 1),
                                                                      (bounds.height - 64) / max(focusSize.height, 1)))
        targetScale = max(openingScale, min(maxScaleFactor, targetScale))
        minScaleFactor = min(minScaleFactor, openingScale)
        began = CACurrentMediaTime(); cameraFinished = false; outlineVisible = true
        let proxy = PDFPeekFrameTick(); proxy.view = self
        tick = CADisplayLink(target: proxy, selector: #selector(PDFPeekFrameTick.step))
        tick?.add(to: .main, forMode: .common)
        animateOpening(at: began)
        pageChanged()
    }

    fileprivate func animateOpening(at now: TimeInterval) {
        guard let page = targetPage else { stopOpening(); return }
        let elapsed = max(0, now - began)
        if !cameraFinished {
            let progress = reduceMotion ? 1 : min(1, elapsed / Self.zoomDuration)
            let eased = 1 - pow(1 - progress, 3)
            scaleFactor = openingScale + (targetScale - openingScale) * eased
            // Centre the approximate area with enough page context, using PDFKit for rotated/cropped pages.
            let crop = page.bounds(for: displayBox), visible = convert(bounds, to: page)
            let width = min(crop.width, visible.width), height = min(crop.height, visible.height)
            let focus = progress < 1 ? CGRect(x: crop.midX + (targetBounds.midX - crop.midX) * eased,
                                              y: crop.midY + (targetBounds.midY - crop.midY) * eased, width: 0, height: 0) : targetBounds
            let frame = CGRect(x: max(crop.minX, min(crop.maxX - width, focus.midX - width / 2)),
                               y: max(crop.minY, min(crop.maxY - height, focus.midY - height / 2)), width: width, height: height)
            go(to: frame, on: page)
            cameraFinished = progress >= 1
        }
        let faded = min(1, elapsed / Self.fadeDuration)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // PDFKit may insert its rendering subviews after our initialization; keep the transient stroke above them.
        layer.addSublayer(outline)
        outline.path = UIBezierPath(roundedRect: convert(targetBounds, from: page), cornerRadius: 5).cgPath
        outline.opacity = reduceMotion ? (faded < 1 ? 1 : 0) : Float(1 - faded * faded)
        CATransaction.commit()
        if faded >= 1 { outlineVisible = false; tick?.invalidate(); tick = nil }
        updateValue()
    }

    func stopOpening() {
        tick?.invalidate(); tick = nil; outline.removeAllAnimations(); outline.opacity = 0; outlineVisible = false
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stopOpening() } }
    @objc private func pageChanged() {
        guard let document, let page = currentPage else { return }
        onPage(document.index(for: page) + 1, document.pageCount); updateValue()
    }
    private func updateValue() {
        guard let document, let page = currentPage else { return }
        let position = "Page \(document.index(for: page) + 1) of \(document.pageCount)"
        #if DEBUG && FIXTURE_HOST
        accessibilityValue = "\(position), zoom \(Int((scaleFactor / max(openingScale, 0.001) * 100).rounded()))%, outline \(outlineVisible ? "shown" : "hidden")"
        #else
        accessibilityValue = position
        #endif
    }
}

private final class PDFPeekFrameTick: NSObject {
    weak var view: PDFPeekNativeView?
    @objc func step(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.animateOpening(at: link.timestamp)
    }
}

/// One tap with two direct touches, distinct from the reader's existing one-finger double tap for Contents.
/// A moving pinch or two-finger drag fails UITapGestureRecognizer and stays with WebKit.
@MainActor final class PDFPeekTwoFingerTap: NSObject {
    private(set) var recognizer: UITapGestureRecognizer!
    var action: ((CGPoint) -> Void)? { didSet { recognizer?.isEnabled = action != nil } }
    func attach(to view: UIView) {
        guard recognizer == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.numberOfTouchesRequired = 2; tap.numberOfTapsRequired = 1
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = true; tap.isEnabled = action != nil
        view.addGestureRecognizer(tap); recognizer = tap
    }
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let view = tap.view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let point = tap.location(in: view)
        // WKWebView's viewport and UIKit points have the same proportions, including reader text-size changes.
        action?(CGPoint(x: max(0, min(1, point.x / view.bounds.width)), y: max(0, min(1, point.y / view.bounds.height))))
    }
}

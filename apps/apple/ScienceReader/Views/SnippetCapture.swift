import CryptoKit
import PDFKit
import ScienceReaderCore
import SwiftUI
import WebKit

// Drawing a snippet (docs/architecture/NOTES_AND_SNIPPETS.md "Capture, step by step"): Paper ⋯ › Draw snippet (or a
// figure/table page's Add to note, or the local PDF reader's) fixes the page, a drag draws a box in either direction,
// four corners (44 pt targets) and the inside adjust it, and Use snippet opens the composer. The overlay takes every
// touch while it is up, so the page can't scroll, select or open Contents underneath; nothing in the reader's own
// gesture handling is replaced. Cancel (Escape) restores reading. Use snippet sits alone in the bottom-right corner (owner,
// TestFlight 91); the whole page and each edge are VoiceOver actions, and ⌘A takes the whole page.

/// The host's top bar while drawing: Cancel and what to do (the page's own controls step aside; nothing moves).
struct SnippetCaptureToolbar: ToolbarContent {
    let model: ReaderModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { model.notes.capturing = nil }
                .keyboardShortcut(.cancelAction).macBarButton()
                .accessibilityIdentifier("capture.cancel")
        }
        ToolbarItem(placement: .principal) {
            Text("Draw snippet").font(.subheadline.weight(.semibold)).lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct SnippetCaptureOverlay: View {
    @Bindable var model: ReaderModel
    let origin: CapturedSnippet.Origin
    /// Turns the box (in this overlay's coordinates) into a snippet: the page's pixels and where they came from.
    let capture: @MainActor (CGRect, CGSize) async throws -> CapturedSnippet
    /// The whole visible page, or a figure page's whole item.
    var wholeTitle = "Whole page"

    private enum Drag: Equatable {
        case new(CGPoint)
        case move(CGRect)
        case corner(Corner, CGRect)
    }
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    @State private var rect: CGRect?
    @State private var drag: Drag?
    @State private var size: CGSize = .zero
    @State private var working = false
    @State private var issue: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let minimum: CGFloat = 24
    private static let handleReach: CGFloat = 22

    private var usable: Bool { (rect.map { $0.width >= Self.minimum && $0.height >= Self.minimum } ?? false) && !working }

    var body: some View {
        GeometryReader { proxy in
            // Owner, TestFlight 91: "you just need the button, Use snippet… put it in the bottom right… you don't need the
            // enclosure. None of this other stuff": the box with its corners, and one button in the corner. Cancel is the
            // bar's; the whole page and each edge stay as VoiceOver actions and keyboard shortcuts.
            ZStack(alignment: .bottomTrailing) {
                surface(in: proxy.size)
                controls(in: proxy.size)
                    .padding(.trailing, 16).padding(.bottom, 16).padding(.leading, 16)
            }
            .onAppear {
                size = proxy.size
                if let initial = model.notes.captureInitialRect {
                    rect = initial.intersection(CGRect(origin: .zero, size: proxy.size)); model.notes.captureInitialRect = nil
                }
            }
            .onChange(of: proxy.size) { _, new in
                // A rotation, a font change or a new layout invalidates the geometry: ask for a new box, never recrop.
                if new != size, rect != nil { rect = nil; issue = "The page changed size. Draw the box again." }
                size = new
            }
        }
    }

    // MARK: Drawing surface

    private func drawing(in size: CGSize) -> some View {
        let bounds = CGRect(origin: .zero, size: size)
        return ZStack(alignment: .topLeading) {
            // Dim outside the box (lightly before one is drawn, so the page stays readable).
            Path { path in
                path.addRect(bounds)
                if let rect { path.addRect(rect) }
            }
            .fill(Color.black.opacity(rect == nil ? 0.10 : 0.34), style: FillStyle(eoFill: true))
            if let rect {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    .accessibilityHidden(true)
                ForEach(Corner.allCases, id: \.self) { corner in
                    let point = Self.point(corner, of: rect)
                    RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: .systemBackground))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(point)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in changed(value, bounds: bounds) }
            .onEnded { _ in drag = nil })
        .accessibilityElement()
        .accessibilityLabel("Snippet area")
        .accessibilityIdentifier("capture.overlay")
        .accessibilityValue(rect.map { "\(Int($0.width)) by \(Int($0.height)) points" } ?? "No box drawn")
        .accessibilityHint("Drag to draw a box. Actions choose the whole page or move each edge.")
    }

    /// Drawing is never the only way to choose a region: the whole page, then each edge in steps (VoiceOver actions).
    private func surface(in size: CGSize) -> some View {
        drawing(in: size)
        .accessibilityAction(named: wholeTitle) { selectWhole(in: size) }
        .accessibilityAction(named: "Move top edge up") { nudge(.top, by: -1, in: size) }
        .accessibilityAction(named: "Move top edge down") { nudge(.top, by: 1, in: size) }
        .accessibilityAction(named: "Move bottom edge up") { nudge(.bottom, by: -1, in: size) }
        .accessibilityAction(named: "Move bottom edge down") { nudge(.bottom, by: 1, in: size) }
        .accessibilityAction(named: "Move left edge left") { nudge(.left, by: -1, in: size) }
        .accessibilityAction(named: "Move left edge right") { nudge(.left, by: 1, in: size) }
        .accessibilityAction(named: "Move right edge left") { nudge(.right, by: -1, in: size) }
        .accessibilityAction(named: "Move right edge right") { nudge(.right, by: 1, in: size) }
    }

    private enum Edge { case top, bottom, left, right }

    private func selectWhole(in size: CGSize) {
        rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4); issue = nil
    }

    /// One step of an edge (a twentieth of the page, at least 16 pt), keeping the box at least its minimum size.
    private func nudge(_ edge: Edge, by direction: CGFloat, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var box = rect ?? CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.15, dy: size.height * 0.3)
        let stepX = max(16, size.width / 20) * direction, stepY = max(16, size.height / 20) * direction
        var minX = box.minX, minY = box.minY, maxX = box.maxX, maxY = box.maxY
        switch edge {
        case .top: minY = min(max(0, minY + stepY), maxY - Self.minimum)
        case .bottom: maxY = max(min(size.height, maxY + stepY), minY + Self.minimum)
        case .left: minX = min(max(0, minX + stepX), maxX - Self.minimum)
        case .right: maxX = max(min(size.width, maxX + stepX), minX + Self.minimum)
        }
        box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rect = box; issue = nil
    }

    private func changed(_ value: DragGesture.Value, bounds: CGRect) {
        issue = nil
        if drag == nil {
            let start = value.startLocation
            if let rect, let corner = nearestCorner(to: start, of: rect) { drag = .corner(corner, rect) }
            else if let rect, rect.contains(start) { drag = .move(rect) }
            else { drag = .new(start) }
        }
        let location = CGPoint(x: min(max(value.location.x, 0), bounds.width), y: min(max(value.location.y, 0), bounds.height))
        switch drag {
        case .new(let start):
            rect = CGRect(x: min(start.x, location.x), y: min(start.y, location.y), width: abs(location.x - start.x), height: abs(location.y - start.y))
        case .move(let original):
            let dx = value.translation.width, dy = value.translation.height
            rect = CGRect(x: min(max(0, original.minX + dx), bounds.width - original.width),
                          y: min(max(0, original.minY + dy), bounds.height - original.height), width: original.width, height: original.height)
        case .corner(let corner, let original):
            var minX = original.minX, minY = original.minY, maxX = original.maxX, maxY = original.maxY
            switch corner {
            case .topLeft: minX = min(location.x, maxX - Self.minimum); minY = min(location.y, maxY - Self.minimum)
            case .topRight: maxX = max(location.x, minX + Self.minimum); minY = min(location.y, maxY - Self.minimum)
            case .bottomLeft: minX = min(location.x, maxX - Self.minimum); maxY = max(location.y, minY + Self.minimum)
            case .bottomRight: maxX = max(location.x, minX + Self.minimum); maxY = max(location.y, minY + Self.minimum)
            }
            rect = CGRect(x: max(0, minX), y: max(0, minY), width: min(bounds.width, maxX) - max(0, minX), height: min(bounds.height, maxY) - max(0, minY))
        case nil: break
        }
    }

    /// The corner within reach (44 pt targets); the nearest wins when a small box puts several in reach.
    private func nearestCorner(to point: CGPoint, of rect: CGRect) -> Corner? {
        Corner.allCases.map { ($0, hypot(Self.point($0, of: rect).x - point.x, Self.point($0, of: rect).y - point.y)) }
            .filter { $0.1 <= Self.handleReach }.min { $0.1 < $1.1 }?.0
    }

    private static func point(_ corner: Corner, of rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    // MARK: Controls

    /// Use snippet in the bottom-right corner, alone (owner, TestFlight 91). A problem (the page changed size, a capture
    /// failed) shows beside it until the box is drawn again. ⌘A takes the whole page.
    private func controls(in size: CGSize) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 0)
            if let issue {
                Text(issue).font(.footnote).foregroundStyle(.primary).multilineTextAlignment(.trailing)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .chromeSurface(Capsule())
                    .accessibilityIdentifier("capture.status")
            }
            Button { use() } label: {
                HStack(spacing: 6) {
                    if working { ProgressView().controlSize(.small).tint(.white) }
                    Text("Use snippet").font(.body.weight(.semibold))
                }
                .padding(.horizontal, 18).frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .disabled(!usable)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(rect == nil ? "Draw a box around what you want to keep first." : "")
            .accessibilityIdentifier("capture.use")
        }
        .background {
            Button(wholeTitle) { selectWhole(in: size) }.keyboardShortcut("a")
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
        }
    }

    private func use() {
        guard let rect, usable else { return }
        working = true; issue = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let snippet = try await capture(rect, size)
                model.notes.composer = NoteComposerRequest(snippet: snippet)
            } catch {
                issue = (error as? LocalizedError)?.errorDescription ?? "This region couldn’t be captured. Try drawing it again."
            }
        }
    }
}

// MARK: - Capture adapters

enum SnippetCaptureError: LocalizedError {
    case pageChanged, unavailable, outsidePage
    var errorDescription: String? {
        switch self {
        case .pageChanged: "The page changed while drawing. Draw the box again."
        case .unavailable: "This page can’t be captured right now. Wait for it to finish loading, then try again."
        case .outsidePage: "Draw the box over the page."
        }
    }
}

@MainActor enum SnippetCapturer {
    /// Reads, from the page's own DOM (no message to or from the page), the reader blocks the box touches, the section it
    /// is in and the figure or table it shows. Every value is checked against the verified bundle before it is kept.
    private static let regionScript = """
        const r = {left: x, top: y, right: x + w, bottom: y + h};
        const hit = e => { const b = e.getBoundingClientRect(); return b.width > 0 && b.height > 0 && b.right > r.left && b.left < r.right && b.bottom > r.top && b.top < r.bottom; };
        const blocks = [...document.querySelectorAll('[data-reader-block]')].filter(hit).slice(0, 64).map(e => e.id);
        let section = null;
        for (const h of document.querySelectorAll('h2,h3,h4,h5,h6')) {
          if (h.closest('[data-sr-chrome]')) continue;
          if (h.getBoundingClientRect().top <= r.top + 8) section = h.textContent.replace(/\\s+/g, ' ').trim(); else break;
        }
        let label = null;
        const figure = [...document.querySelectorAll('figure[data-reader-figure]')].find(hit);
        const caption = figure ? (figure.querySelector('figcaption')?.textContent || '') : '';
        const match = caption.replace(/\\s+/g, ' ').trim().match(/^(Figure|Fig\\.|Table|Algorithm)\\s*[A-Za-z0-9.]{1,10}/);
        if (match) label = match[0].replace(/^Fig\\./, 'Figure').replace(/[.:]+$/, '');
        return {blocks, section: section ? section.slice(0, 300) : null, label};
        """

    /// The figure element's box in a figure page, for "whole item, then optional adjust".
    private static let figureScript = """
        const figure = document.querySelector('figure[data-reader-figure]') || document.querySelector('table') || document.body;
        const b = figure.getBoundingClientRect();
        return {x: b.left, y: b.top, w: b.width, h: b.height};
        """

    static func source(for paper: Paper, label: String? = nil, section: String? = nil) -> NoteSource {
        let title = NoteSource.prefix(paper.title, bytes: NoteSource.maximumTitleBytes)
        let authors = Array(paper.authorNames.prefix(64)).map { NoteSource.prefix($0, bytes: 512) }
        let section = section.map { NoteSource.prefix($0, bytes: NoteSource.maximumSectionBytes) }
        if let arxiv = paper.arxivReaderSource {
            return NoteSource(kind: .arxiv, title: title, authors: authors, sourceID: arxiv.sourceID, revision: arxiv.revision,
                              url: "https://arxiv.org/abs/\(arxiv.sourceID)v\(arxiv.revision)", section: section, label: label,
                              membershipID: paper.sourceMembership?.membershipID)
        }
        return NoteSource(kind: .document, title: title, authors: authors, sourceID: paper.id.wire, revision: paper.sourceRevision.flatMap { $0 >= 1 ? $0 : nil },
                          url: nil, section: section, label: label, membershipID: paper.sourceMembership?.membershipID)
    }

    /// A region of the paper's (or a figure page's) web view: WKWebView's own snapshot of exactly that rectangle in the
    /// view's coordinates, at the screen's pixel density, with the overlay not part of it.
    static func webRegion(_ rect: CGRect, overlaySize: CGSize, web: WKWebView?, paper: Paper, origin: CapturedSnippet.Origin) async throws -> CapturedSnippet {
        guard let web, let bundle = paper.readerBundle, web.window != nil else { throw SnippetCaptureError.unavailable }
        guard abs(web.bounds.width - overlaySize.width) < 1, abs(web.bounds.height - overlaySize.height) < 1 else { throw SnippetCaptureError.pageChanged }
        let crop = rect.intersection(web.bounds)
        guard !crop.isNull, crop.width >= 8, crop.height >= 8 else { throw SnippetCaptureError.outsidePage }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = crop
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = NSNumber(value: Double(crop.width))
        let image = try await web.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage else { throw SnippetCaptureError.unavailable }
        // CSS pixels are points at the reader's zoom of 1; a pinch-zoomed page scales them.
        let zoom = max(0.1, web.scrollView.zoomScale)
        let found = try? await web.callAsyncJavaScript(regionScript, arguments: ["x": crop.minX / zoom, "y": crop.minY / zoom,
                                                                                 "w": crop.width / zoom, "h": crop.height / zoom],
                                                       in: nil, contentWorld: .defaultClient) as? [String: Any]
        let known = Set(bundle.index.blocks.map(\.id))
        let blocks = ((found?["blocks"] as? [String]) ?? []).filter { known.contains($0) && NoteAnchor.isBlockID($0) }.prefix(NotesFormat.maximumBlockIDs)
        // The section heading above the box (h2 and below: h1 is the paper's own title, already the source title).
        let section = (found?["section"] as? String).map { String($0.prefix(300)) }.flatMap { $0.isEmpty || $0 == paper.title ? nil : $0 }
        let label = (found?["label"] as? String).flatMap { $0.wholeMatch(of: /(?:Figure|Table|Algorithm) ?[A-Za-z0-9.]{1,10}/) != nil ? $0 : nil }
        let scale = web.window?.screen.scale ?? web.traitCollection.displayScale
        let anchor = NoteAnchor(manifestSHA256: bundle.manifestSHA256, rendererRevision: ReaderVersions.revision(of: bundle) ?? 0,
                                blockIDs: Array(blocks), rects: [NoteAnchor.rect(crop, in: web.bounds.size)],
                                viewport: [Double(web.bounds.width), Double(web.bounds.height), Double(scale)], quote: nil)
        return CapturedSnippet(kind: .region, image: cgImage, quote: nil, source: source(for: paper, label: label, section: section),
                               anchor: anchor, capturedAt: Date(), origin: origin, paperID: paper.id)
    }

    /// A snapshot of a transparent view on the background it was seen on (the snippet keeps its look in either theme).
    static func opaque(_ image: UIImage, background: UIColor, traits: UITraitCollection) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale; format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            background.resolvedColor(with: traits).setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }.cgImage
    }

    /// The figure's own box in a figure page's web view, to preselect the whole item.
    static func figureBounds(in web: WKWebView?) async -> CGRect? {
        guard let web, let value = try? await web.callAsyncJavaScript(figureScript, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Double],
              let x = value["x"], let y = value["y"], let w = value["w"], let h = value["h"], [x, y, w, h].allSatisfy(\.isFinite) else { return nil }
        let zoom = max(0.1, web.scrollView.zoomScale)
        let rect = CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom).insetBy(dx: -6, dy: -6).intersection(web.bounds)
        return rect.isNull || rect.width < 24 || rect.height < 24 ? nil : rect
    }

    /// A selection in the paper as a quotation (Add to note in the selection menu): its text as the bundle resolves it,
    /// the blocks it spans, no pixels and no invented page.
    static func quote(_ selection: ReaderSelection, quote: String, paper: Paper) -> CapturedSnippet? {
        guard let bundle = paper.readerBundle, selection.manifestSHA256 == bundle.manifestSHA256 else { return nil }
        let text = String(quote.utf8.prefix(NotesFormat.maximumQuoteBytes)) ?? String(quote.prefix(5_000))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var seen = Set<String>(), blocks: [String] = []
        for part in selection.parts where NoteAnchor.isBlockID(part.blockID) && seen.insert(part.blockID).inserted
            && blocks.count < NotesFormat.maximumBlockIDs { blocks.append(part.blockID) }
        let anchor = NoteAnchor(manifestSHA256: bundle.manifestSHA256, rendererRevision: ReaderVersions.revision(of: bundle) ?? 0,
                                blockIDs: blocks, rects: [], viewport: nil, quote: text)
        return CapturedSnippet(kind: .quote, image: nil, quote: text, source: source(for: paper), anchor: anchor, capturedAt: Date(),
                               origin: .paper, paperID: paper.id)
    }

    /// A region of a local PDF: PDFKit draws exactly that part of the page (never the screen), at the screen's density.
    static func pdfRegion(_ rect: CGRect, overlaySize: CGSize, view: PDFView?, presentation: LocalPaperPresentation) throws -> CapturedSnippet {
        guard let view, view.document != nil else { throw SnippetCaptureError.unavailable }
        guard abs(view.bounds.width - overlaySize.width) < 1, abs(view.bounds.height - overlaySize.height) < 1 else { throw SnippetCaptureError.pageChanged }
        guard let page = view.page(for: CGPoint(x: rect.midX, y: rect.midY), nearest: true) else { throw SnippetCaptureError.outsidePage }
        let pageRect = view.convert(page.bounds(for: .cropBox), from: page)
        let crop = rect.intersection(pageRect)
        guard !crop.isNull, crop.width >= 8, crop.height >= 8 else { throw SnippetCaptureError.outsidePage }
        let scale = view.window?.screen.scale ?? view.traitCollection.displayScale
        guard let image = PDFRegionRenderer.render(page: page, pageRect: pageRect, crop: crop, scale: max(2, scale)) else { throw SnippetCaptureError.unavailable }
        let index = view.document.map { $0.index(for: page) } ?? 0
        let digest = Data(SHA256Digest.hash(presentation.data)).hex
        let source = NoteSource(kind: .localPDF, title: NoteSource.prefix(presentation.title, bytes: NoteSource.maximumTitleBytes),
                                authors: Array(presentation.authors.prefix(64)).map { NoteSource.prefix($0, bytes: 512) },
                                sourceID: presentation.sourceID, revision: presentation.revision,
                                url: presentation.sourceID.flatMap { id in presentation.revision.map { "https://arxiv.org/abs/\(id)v\($0)" } },
                                section: nil, label: nil, pdfSHA256: digest, page: index + 1)
        return CapturedSnippet(kind: .region, image: image, quote: nil, source: source, anchor: nil, capturedAt: Date(), origin: .pdf,
                               paperID: nil)
    }
}

enum SHA256Digest {
    static func hash(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }
}

/// Renders part of a PDF page. `pageRect` is where the page is shown (rotation applied, y down) and `crop` is the part
/// wanted, both in the same view coordinates; the result has `scale` pixels per point.
enum PDFRegionRenderer {
    static func render(page: PDFPage, pageRect: CGRect, crop: CGRect, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let shownWidth = rotated ? box.height : box.width
        guard shownWidth > 0, pageRect.width > 0 else { return nil }
        let pointsPerUnit = pageRect.width / shownWidth
        // Bounded like the stored image (longest edge 4,096 px) before encoding.
        let pixelScale = min(scale, CGFloat(NotesFormat.maximumImageEdge) / max(crop.width, crop.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = pixelScale; format.opaque = true
        let image = UIGraphicsImageRenderer(size: crop.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: crop.size))
            let cg = context.cgContext
            cg.translateBy(x: pageRect.minX - crop.minX, y: pageRect.minY - crop.minY)
            // PDF space is y up: flip within the shown page, then draw the page box (PDFKit applies its rotation).
            cg.translateBy(x: 0, y: pageRect.height)
            cg.scaleBy(x: pointsPerUnit, y: -pointsPerUnit)
            page.draw(with: .cropBox, to: cg)
        }
        return image.cgImage
    }
}

// MARK: - Saved confirmation

/// "Saved to <note> · Open note" over the screen a capture came from; it goes after a few seconds.
struct NoteSavedBanner: View {
    @Bindable var model: ReaderModel
    let origin: CapturedSnippet.Origin
    /// Closes the sheet the capture came from before Notes opens (a figure page, the PDF reader).
    var leave: () -> Void = {}

    var body: some View {
        if let notice = model.notes.notice, notice.origin == origin {
            StatusBanner(tone: .info, systemImage: "checkmark.circle",
                         message: "Saved to \(notice.title)" + (notice.waiting ? " · Waiting to sync" : ""),
                         messageID: "notes.saved") {
                Button("Open") { leave(); model.openNote(notice.noteID, entry: notice.entryID) }
                    .accessibilityIdentifier("notes.saved.open")
                Button { model.notes.notice = nil } label: { Image(systemName: "xmark").font(.footnote.weight(.semibold)) }
                    .accessibilityLabel("Dismiss").tint(.secondary)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .transition(.opacity)
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(8))
                if model.notes.notice?.id == notice.id { model.notes.notice = nil }
            }
        }
    }
}

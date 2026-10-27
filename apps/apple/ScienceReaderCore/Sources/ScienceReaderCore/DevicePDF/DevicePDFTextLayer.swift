import CoreGraphics
import Foundation

/// One character of a page's text layer, as the device route's reference reads it (`gradstep.data.pdftext.read_pages`:
/// pdfplumber's characters with the baseline correction for fonts whose metrics put the glyph below its baseline).
/// Points, origin at the top left of the displayed CropBox, including page rotation (rather than pdfplumber's
/// absolute MediaBox offsets); `size` is the glyph box's height (its width for vertical writing).
public struct DevicePDFGlyph: Sendable, Equatable {
    public let text: String
    public let x0: Double
    public let top: Double
    public let x1: Double
    public let bottom: Double
    public let size: Double
    /// The font descriptor's FontName, subset prefix included (`ABCDEF+CMMI10`); "unknown" without a descriptor.
    public let font: String
    public let upright: Bool

    public init(text: String, x0: Double, top: Double, x1: Double, bottom: Double, size: Double, font: String, upright: Bool) {
        self.text = text; self.x0 = x0; self.top = top; self.x1 = x1; self.bottom = bottom; self.size = size; self.font = font; self.upright = upright
    }
}

/// The PDF's own text layer, read with CGPDFScanner the way pdfminer.six (under pdfplumber) reads it, so the device
/// route sees the glyphs its Python reference was built on (docs/architecture/DEVICE_PDF_ROUTE.md). PDFKit cannot be
/// used: it reports substituted fonts, ink boxes and synthetic spaces.
///
/// Known differences from pdfminer: predefined CJK CMaps (pdfminer ships them as data files) decode nothing; malformed
/// content that makes pdfminer raise is read as far as Core Graphics' scanner goes.
public enum DevicePDFTextLayer {
    /// Glyphs in content-stream order (form XObjects in place).
    public static func glyphs(page: CGPDFPage) -> [DevicePDFGlyph] {
        let geometry = PageGeometry(page)
        let run = TextLayerRun(geometry: geometry)
        let resources = inherited(page.dictionary, "Resources").flatMap { value -> CGPDFDictionaryRef? in
            if case .dict(let d) = value { return d }
            return nil
        }
        let cs = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(cs) }
        Interpreter(run: run, resources: resources, ctm: geometry.ctm, depth: 0).scan(cs)
        return run.glyphs
    }

    /// The displayed crop box, rotated like DevicePDFRaster, in the same coordinates as layout and formula crops.
    public static func pageSize(page: CGPDFPage) -> CGSize {
        let g = PageGeometry(page)
        return CGSize(width: g.width, height: g.height)
    }

    fileprivate static func inherited(_ dict: CGPDFDictionaryRef?, _ key: String) -> DevicePDFObject.Value? {
        var node = dict
        var hops = 0
        while let d = node, hops < 64 {
            if let v = DevicePDFObject.get(d, key) { return v }
            node = DevicePDFObject.dict(d, "Parent")
            hops += 1
        }
        return nil
    }
}

// MARK: - Geometry

struct DevicePDFMatrix: Equatable {
    var a, b, c, d, e, f: Double
    static let identity = DevicePDFMatrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    /// pdfminer `mult_matrix(m1, m0)`: m1 applied first, then m0.
    static func mult(_ m1: DevicePDFMatrix, _ m0: DevicePDFMatrix) -> DevicePDFMatrix {
        DevicePDFMatrix(a: m0.a * m1.a + m0.c * m1.b, b: m0.b * m1.a + m0.d * m1.b,
                        c: m0.a * m1.c + m0.c * m1.d, d: m0.b * m1.c + m0.d * m1.d,
                        e: m0.a * m1.e + m0.c * m1.f + m0.e, f: m0.b * m1.e + m0.d * m1.f + m0.f)
    }
    /// pdfminer `translate_matrix`.
    func translated(_ x: Double, _ y: Double) -> DevicePDFMatrix {
        DevicePDFMatrix(a: a, b: b, c: c, d: d, e: x * a + y * c + e, f: x * b + y * d + f)
    }
    func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + c * y + e, b * x + d * y + f) }
}

private struct PageGeometry {
    let ctm: DevicePDFMatrix
    let width: Double
    let height: Double

    init(_ page: CGPDFPage) {
        let dict = page.dictionary
        let crop = page.getBoxRect(.cropBox).standardized
        let box = [crop.minX, crop.minY, crop.maxX, crop.maxY]
        var rotate = 0
        switch DevicePDFTextLayer.inherited(dict, "Rotate") {
        case .int(let r)?: rotate = r
        case .real(let r)?: rotate = Int(r)
        default: break
        }
        rotate = ((rotate % 360) + 360) % 360
        // Normalize the displayed crop box exactly once. Returning pdfplumber's absolute MediaBox
        // offsets here shifts glyphs away from the raster on publisher PDFs with a nonzero origin.
        let (x0, y0, x1, y1) = (box[0], box[1], box[2], box[3])
        switch rotate {
        case 90: ctm = DevicePDFMatrix(a: 0, b: -1, c: 1, d: 0, e: -y0, f: x1)
        case 180: ctm = DevicePDFMatrix(a: -1, b: 0, c: 0, d: -1, e: x1, f: y1)
        case 270: ctm = DevicePDFMatrix(a: 0, b: 1, c: -1, d: 0, e: y1, f: -x0)
        default: ctm = DevicePDFMatrix(a: 1, b: 0, c: 0, d: 1, e: -x0, f: -y0)
        }
        let quarter = rotate == 90 || rotate == 270
        width = quarter ? y1 - y0 : x1 - x0
        height = quarter ? x1 - x0 : y1 - y0
    }
}

// MARK: - Interpretation

private final class TextLayerRun {
    let geometry: PageGeometry
    var glyphs: [DevicePDFGlyph] = []
    /// pdfminer keeps one device CTM, set by `cm`, `Q` and the start of every (form) content stream; a form leaves
    /// its last CTM behind for the stream that invoked it until that stream's next `cm` or `Q`. Kept for fidelity.
    var deviceCTM = DevicePDFMatrix.identity
    var fonts: [Int: DevicePDFFont] = [:]
    lazy var defaultFont = DevicePDFFont.make(nil)
    let table: CGPDFOperatorTableRef

    init(geometry: PageGeometry) {
        self.geometry = geometry
        glyphs.reserveCapacity(4096)
        table = CGPDFOperatorTableCreate()!
        Interpreter.register(table)
    }
    deinit { CGPDFOperatorTableRelease(table) }

    func font(_ spec: CGPDFDictionaryRef) -> DevicePDFFont {
        let key = unsafeBitCast(spec, to: Int.self) // the dictionary's identity within this document
        if let f = fonts[key] { return f }
        let f = DevicePDFFont.make(spec)
        fonts[key] = f
        return f
    }
}

private struct TextState {
    var font: DevicePDFFont? = nil
    var fontsize: Double = 0
    var charspace: Double = 0
    var wordspace: Double = 0
    var scaling: Double = 100
    var leading: Double = 0
    var render: Int = 0
    var rise: Double = 0
    var matrix = DevicePDFMatrix.identity
    var linematrix: (Double, Double) = (0, 0)
}

private enum TextPiece { case number(Double), bytes([UInt8]) }

/// One content stream's interpreter (pdfminer creates a fresh one, with a fresh text state, for every form XObject).
private final class Interpreter {
    unowned let run: TextLayerRun
    let resources: CGPDFDictionaryRef?
    var ctm: DevicePDFMatrix
    var state = TextState()
    var stack: [(DevicePDFMatrix, TextState)] = []
    let depth: Int

    init(run: TextLayerRun, resources: CGPDFDictionaryRef?, ctm: DevicePDFMatrix, depth: Int) {
        self.run = run
        self.resources = resources
        self.ctm = ctm
        self.depth = depth
        run.deviceCTM = ctm
    }

    private var contentStream: CGPDFContentStreamRef? = nil

    func scan(_ cs: CGPDFContentStreamRef) {
        contentStream = cs
        let scanner = CGPDFScannerCreate(cs, run.table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        _ = CGPDFScannerScan(scanner)
    }

    fileprivate static func me(_ info: UnsafeMutableRawPointer?) -> Interpreter { Unmanaged<Interpreter>.fromOpaque(info!).takeUnretainedValue() }

    // MARK: operands

    private static func pop(_ s: CGPDFScannerRef) -> DevicePDFObject.Value? {
        var o: CGPDFObjectRef? = nil
        guard CGPDFScannerPopObject(s, &o), let o else { return nil }
        return DevicePDFObject.value(o)
    }
    /// pdfminer pops exactly `n` operands and skips the operator when there are fewer. Returned in stream order.
    fileprivate static func pop(_ s: CGPDFScannerRef, _ n: Int) -> [DevicePDFObject.Value]? {
        var out: [DevicePDFObject.Value] = []
        for _ in 0..<n { guard let v = pop(s) else { return nil }; out.append(v) }
        return out.reversed()
    }

    static func register(_ t: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(t, "q") { _, info in let i = Interpreter.me(info); i.stack.append((i.ctm, i.state)) }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in
            let i = Interpreter.me(info)
            if let (m, s) = i.stack.popLast() { i.ctm = m; i.state = s; i.run.deviceCTM = m }
        }
        CGPDFOperatorTableSetCallback(t, "cm") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 6) else { return }
            let n = v.compactMap(\.number)
            guard n.count == 6 else { return }
            i.ctm = DevicePDFMatrix.mult(DevicePDFMatrix(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5]), i.ctm)
            i.run.deviceCTM = i.ctm
        }
        CGPDFOperatorTableSetCallback(t, "BT") { _, info in let i = Interpreter.me(info); i.state.matrix = .identity; i.state.linematrix = (0, 0) }
        CGPDFOperatorTableSetCallback(t, "Tc") { s, info in if let v = Interpreter.pop(s, 1)?[0].number { Interpreter.me(info).state.charspace = v } }
        CGPDFOperatorTableSetCallback(t, "Tw") { s, info in if let v = Interpreter.pop(s, 1)?[0].number { Interpreter.me(info).state.wordspace = v } }
        CGPDFOperatorTableSetCallback(t, "Tz") { s, info in if let v = Interpreter.pop(s, 1)?[0].number { Interpreter.me(info).state.scaling = v } }
        CGPDFOperatorTableSetCallback(t, "TL") { s, info in if let v = Interpreter.pop(s, 1)?[0].number { Interpreter.me(info).state.leading = -v } }
        CGPDFOperatorTableSetCallback(t, "Ts") { s, info in if let v = Interpreter.pop(s, 1)?[0].number { Interpreter.me(info).state.rise = v } }
        CGPDFOperatorTableSetCallback(t, "Tr") { s, info in if let v = Interpreter.pop(s, 1)?[0].number { Interpreter.me(info).state.render = Int(v) } }
        CGPDFOperatorTableSetCallback(t, "Tf") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 2) else { return }
            i.state.font = i.font(named: v[0])
            if let size = v[1].number { i.state.fontsize = size }
        }
        CGPDFOperatorTableSetCallback(t, "Td") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 2) else { return }
            if let tx = v[0].number, let ty = v[1].number { i.moveText(tx, ty) }
            i.state.linematrix = (0, 0)
        }
        CGPDFOperatorTableSetCallback(t, "TD") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 2) else { return }
            if let tx = v[0].number, let ty = v[1].number { i.moveText(tx, ty) }
            if let ty = v[1].number { i.state.leading = ty }
            i.state.linematrix = (0, 0)
        }
        CGPDFOperatorTableSetCallback(t, "Tm") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 6) else { return }
            let n = v.compactMap(\.number)
            guard n.count == 6 else { return }
            i.state.matrix = DevicePDFMatrix(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5])
            i.state.linematrix = (0, 0)
        }
        CGPDFOperatorTableSetCallback(t, "T*") { _, info in Interpreter.me(info).nextLine() }
        CGPDFOperatorTableSetCallback(t, "TJ") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 1) else { return }
            guard case .array(let a) = v[0] else { i.show([Interpreter.piece(v[0])].compactMap { $0 }); return }
            i.show(DevicePDFObject.items(a).compactMap(Interpreter.piece))
        }
        CGPDFOperatorTableSetCallback(t, "Tj") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 1) else { return }
            i.show([Interpreter.piece(v[0])].compactMap { $0 })
        }
        CGPDFOperatorTableSetCallback(t, "'") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 1) else { return }
            i.nextLine()
            i.show([Interpreter.piece(v[0])].compactMap { $0 })
        }
        CGPDFOperatorTableSetCallback(t, "\"") { s, info in
            // pdfminer's `"` sets Tw and Tc and shows the string without moving to the next line. Kept for fidelity.
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 3) else { return }
            if let aw = v[0].number { i.state.wordspace = aw }
            if let ac = v[1].number { i.state.charspace = ac }
            i.show([Interpreter.piece(v[2])].compactMap { $0 })
        }
        CGPDFOperatorTableSetCallback(t, "Do") { s, info in
            let i = Interpreter.me(info)
            guard let v = Interpreter.pop(s, 1), case .name(let name) = v[0] else { return }
            i.invoke(name)
        }
    }

    fileprivate static func piece(_ v: DevicePDFObject.Value) -> TextPiece? {
        switch v {
        case .int(let n): return .number(Double(n))
        case .real(let r): return .number(r)
        case .string(let b): return .bytes(b)
        default: return nil
        }
    }

    private func moveText(_ tx: Double, _ ty: Double) {
        let m = state.matrix
        state.matrix = DevicePDFMatrix(a: m.a, b: m.b, c: m.c, d: m.d, e: tx * m.a + ty * m.c + m.e, f: tx * m.b + ty * m.d + m.f)
    }
    private func nextLine() {
        let m = state.matrix
        state.matrix = DevicePDFMatrix(a: m.a, b: m.b, c: m.c, d: m.d, e: state.leading * m.c + m.e, f: state.leading * m.d + m.f)
        state.linematrix = (0, 0)
    }

    private func font(named value: DevicePDFObject.Value) -> DevicePDFFont {
        if case .name(let name) = value, let fonts = DevicePDFObject.dict(resources, "Font"), let spec = DevicePDFObject.dict(fonts, name) {
            return run.font(spec)
        }
        return run.defaultFont // pdfminer: an undefined font id is `get_font(None, {})`
    }

    private func invoke(_ name: String) {
        guard depth < 32, let parent = contentStream, let xobjects = DevicePDFObject.dict(resources, "XObject"), let stream = DevicePDFObject.stream(xobjects, name),
              let dict = CGPDFStreamGetDictionary(stream), DevicePDFObject.name(dict, "Subtype") == "Form", DevicePDFObject.has(dict, "BBox") else { return }
        var matrix = DevicePDFMatrix.identity
        if let m = DevicePDFObject.array(dict, "Matrix").map(DevicePDFObject.items)?.compactMap(\.number), m.count == 6 {
            matrix = DevicePDFMatrix(a: m[0], b: m[1], c: m[2], d: m[3], e: m[4], f: m[5])
        }
        var formResources = resources
        if let own = DevicePDFObject.dict(dict, "Resources"), CGPDFDictionaryGetCount(own) > 0 { formResources = own }
        let cs = CGPDFContentStreamCreateWithStream(stream, formResources ?? dict, parent)
        defer { CGPDFContentStreamRelease(cs) }
        Interpreter(run: run, resources: formResources, ctm: DevicePDFMatrix.mult(matrix, ctm), depth: depth + 1).scan(cs)
    }

    // MARK: pdfminer PDFTextDevice.render_string and PDFLayoutAnalyzer.render_char / LTChar

    private func show(_ seq: [TextPiece]) {
        guard let font = state.font else { return }
        let matrix = DevicePDFMatrix.mult(state.matrix, run.deviceCTM)
        let fontsize = state.fontsize
        let scaling = state.scaling * 0.01
        let charspace = state.charspace * scaling
        var wordspace = state.wordspace * scaling
        let rise = state.rise
        if font.multibyte { wordspace = 0 }
        let dxscale = 0.001 * fontsize * scaling
        var (x, y) = state.linematrix
        var needcharspace = false
        let vertical = font.vertical
        for piece in seq {
            switch piece {
            case .number(let n):
                if vertical { y -= n * dxscale } else { x -= n * dxscale }
                needcharspace = true
            case .bytes(let bytes):
                for cid in font.decode(bytes) {
                    if needcharspace { if vertical { y += charspace } else { x += charspace } }
                    let adv = char(matrix.translated(x, y), font, fontsize, scaling, rise, cid)
                    if vertical { y += adv } else { x += adv }
                    if cid == 32, wordspace != 0 { if vertical { y += wordspace } else { x += wordspace } }
                    needcharspace = true
                }
            }
        }
        state.linematrix = (x, y)
    }

    private func char(_ m: DevicePDFMatrix, _ font: DevicePDFFont, _ fontsize: Double, _ scaling: Double, _ rise: Double, _ cid: Int) -> Double {
        let text = font.text(cid) ?? "(cid:\(cid))"
        let adv = font.charWidth(cid) * fontsize * scaling
        let bbox: (Double, Double, Double, Double)
        if font.vertical {
            let (dvx, dvy) = font.charDisp(cid)
            let vx = dvx.map { $0 * fontsize * 0.001 } ?? fontsize * 0.5
            let vy = (1000 - dvy) * fontsize * 0.001
            bbox = (-vx, vy + rise + adv, -vx + fontsize, vy + rise)
        } else {
            let descent = font.descentInTextSpace * fontsize
            bbox = (0, descent + rise, adv, descent + rise + fontsize)
        }
        let upright = m.a * m.d * scaling > 0 && m.b * m.c <= 0
        // pdfminer `apply_matrix_rect`: the four corners' extent.
        let p1 = m.apply(bbox.0, bbox.1), p2 = m.apply(bbox.2, bbox.1), p3 = m.apply(bbox.2, bbox.3), p4 = m.apply(bbox.0, bbox.3)
        let x0 = min(p1.0, p2.0, p3.0, p4.0), x1 = max(p1.0, p2.0, p3.0, p4.0)
        let y0 = min(p1.1, p2.1, p3.1, p4.1), y1 = max(p1.1, p2.1, p3.1, p4.1)
        let size = font.vertical ? x1 - x0 : y1 - y0
        // Top-left coordinates of the displayed crop; the raster uses the same crop and rotation.
        let g = run.geometry
        var top = g.height - y1
        var bottom = g.height - y0
        // gradstep `pdftext._off_baseline`: metrics that put the glyph box away from its baseline (STIX Two Math in
        // Word-made PDFs) are replaced by a box from the baseline.
        if m.b == 0, m.c == 0, m.d > 0 {
            let baseline = m.f
            if !(y0 - 0.05 * size <= baseline && baseline <= y1) {
                top = g.height - (baseline + 0.75 * size)
                bottom = g.height - (baseline - 0.25 * size)
            }
        }
        // Content streams can contain text outside CropBox; it is not visible in the PDF image.
        guard x1 >= 0, x0 <= g.width, bottom >= 0, top <= g.height else { return adv }
        run.glyphs.append(DevicePDFGlyph(text: text, x0: x0, top: top, x1: x1, bottom: bottom, size: size,
                                         font: font.fontname, upright: upright))
        return adv
    }
}

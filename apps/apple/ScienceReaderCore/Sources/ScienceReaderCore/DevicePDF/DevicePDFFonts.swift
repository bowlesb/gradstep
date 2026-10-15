import CoreGraphics
import Foundation

// Fonts as pdfminer.six models them (`pdffont.py`, `encodingdb.py`; MIT License, Copyright (c) 2004-2016 Yusuke
// Shinyama): code decoding, the code -> text mapping, advance widths and the descent that fixes each glyph's box.
// Every rule follows pdfminer, including where it departs from the PDF specification, because the device route's
// reference text layer is pdfplumber over pdfminer (docs/architecture/DEVICE_PDF_ROUTE.md).

// MARK: - Reading CGPDF objects

enum DevicePDFObject {
    enum Value {
        case int(Int)
        case real(Double)
        case name(String)
        case string([UInt8])
        case array(CGPDFArrayRef)
        case dict(CGPDFDictionaryRef)
        case stream(CGPDFStreamRef)
        case other

        var number: Double? {
            switch self { case .int(let i): return Double(i); case .real(let r): return r; default: return nil }
        }
    }

    static func value(_ object: CGPDFObjectRef) -> Value {
        switch CGPDFObjectGetType(object) {
        case .integer:
            var v: CGPDFInteger = 0
            return CGPDFObjectGetValue(object, .integer, &v) ? .int(Int(v)) : .other
        case .real:
            var v: CGPDFReal = 0
            return CGPDFObjectGetValue(object, .real, &v) ? .real(Double(v)) : .other
        case .name:
            var p: UnsafePointer<CChar>? = nil
            return CGPDFObjectGetValue(object, .name, &p) && p != nil ? .name(String(cString: p!)) : .other
        case .string:
            var s: CGPDFStringRef? = nil
            return CGPDFObjectGetValue(object, .string, &s) && s != nil ? .string(bytes(s!)) : .other
        case .array:
            var a: CGPDFArrayRef? = nil
            return CGPDFObjectGetValue(object, .array, &a) && a != nil ? .array(a!) : .other
        case .dictionary:
            var d: CGPDFDictionaryRef? = nil
            return CGPDFObjectGetValue(object, .dictionary, &d) && d != nil ? .dict(d!) : .other
        case .stream:
            var s: CGPDFStreamRef? = nil
            return CGPDFObjectGetValue(object, .stream, &s) && s != nil ? .stream(s!) : .other
        default:
            return .other
        }
    }

    static func get(_ d: CGPDFDictionaryRef?, _ key: String) -> Value? {
        guard let d else { return nil }
        var o: CGPDFObjectRef? = nil
        guard CGPDFDictionaryGetObject(d, key, &o), let o else { return nil }
        return value(o)
    }
    static func has(_ d: CGPDFDictionaryRef?, _ key: String) -> Bool {
        guard let d else { return false }
        var o: CGPDFObjectRef? = nil
        return CGPDFDictionaryGetObject(d, key, &o) && o != nil
    }
    static func name(_ d: CGPDFDictionaryRef?, _ key: String) -> String? {
        if case .name(let n)? = get(d, key) { return n }
        return nil
    }
    static func number(_ d: CGPDFDictionaryRef?, _ key: String) -> Double? { get(d, key)?.number }
    static func int(_ d: CGPDFDictionaryRef?, _ key: String) -> Int? {
        switch get(d, key) { case .int(let i)?: return i; case .real(let r)?: return Int(r); default: return nil }
    }
    static func dict(_ d: CGPDFDictionaryRef?, _ key: String) -> CGPDFDictionaryRef? {
        switch get(d, key) {
        case .dict(let x)?: return x
        case .stream(let s)?: return CGPDFStreamGetDictionary(s)
        default: return nil
        }
    }
    static func array(_ d: CGPDFDictionaryRef?, _ key: String) -> CGPDFArrayRef? {
        if case .array(let a)? = get(d, key) { return a }
        return nil
    }
    static func stream(_ d: CGPDFDictionaryRef?, _ key: String) -> CGPDFStreamRef? {
        if case .stream(let s)? = get(d, key) { return s }
        return nil
    }
    static func items(_ a: CGPDFArrayRef) -> [Value] {
        (0..<CGPDFArrayGetCount(a)).map { k in
            var o: CGPDFObjectRef? = nil
            return CGPDFArrayGetObject(a, k, &o) && o != nil ? value(o!) : .other
        }
    }
    static func bytes(_ s: CGPDFStringRef) -> [UInt8] {
        guard let p = CGPDFStringGetBytePtr(s) else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s)))
    }
    static func data(_ s: CGPDFStreamRef) -> [UInt8]? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(s, &format), format == .raw else { return nil }
        return [UInt8](data as Data)
    }
    /// pdfminer's `safe_rect_list`: four numbers or nothing.
    static func rect(_ a: CGPDFArrayRef?) -> [Double]? {
        guard let a else { return nil }
        let v = items(a).prefix(4).compactMap(\.number)
        return v.count == 4 ? Array(v) : nil
    }
}

// MARK: - Glyph names and encodings

enum DevicePDFFontEncoding {
    static let glyphs: [String: String] = {
        var out: [String: String] = [:]
        out.reserveCapacity(4400)
        for line in DevicePDFFontsData.glyphList.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            var text = String.UnicodeScalarView()
            for hex in parts[1].split(separator: ".") { if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { text.append(s) } }
            out[String(parts[0])] = String(text)
        }
        return out
    }()

    private static func isHexPrefix(_ s: Substring) -> Bool { s.first.map { $0.isHexDigit } ?? false }

    /// pdfminer `encodingdb.name2unicode`, nil where it raises (KeyError or ValueError).
    static func name2unicode(_ full: String) -> String? {
        let name = full.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let components = name.split(separator: "_", omittingEmptySubsequences: false)
        if components.count > 1 {
            var out = ""
            for c in components { guard let t = name2unicode(String(c)) else { return nil }; out += t }
            return out
        }
        if let g = glyphs[name] { return g }
        if name.hasPrefix("uni") {
            // `name.strip("uni")` strips the characters u, n and i from both ends.
            let core = name.trimmingCharacters(in: CharacterSet(charactersIn: "uni"))
            guard isHexPrefix(Substring(core)), core.count % 4 == 0 else { return nil }
            var out = String.UnicodeScalarView()
            var start = core.startIndex
            while start < core.endIndex {
                let end = core.index(start, offsetBy: 4)
                guard let v = UInt32(core[start..<end], radix: 16), !(0xD800...0xDFFF).contains(v), let s = Unicode.Scalar(v) else { return nil }
                out.append(s)
                start = end
            }
            return String(out)
        }
        if name.hasPrefix("u") {
            let core = name.trimmingCharacters(in: CharacterSet(charactersIn: "u"))
            guard isHexPrefix(Substring(core)), (4...6).contains(core.count),
                  let v = UInt32(core, radix: 16), !(0xD800...0xDFFF).contains(v), let s = Unicode.Scalar(v) else { return nil }
            return String(Character(s))
        }
        return nil
    }

    /// StandardEncoding, MacRomanEncoding, WinAnsiEncoding, PDFDocEncoding: code -> text.
    static let latin: [String: [Int: String]] = {
        var std: [Int: String] = [:], mac: [Int: String] = [:], win: [Int: String] = [:], pdf: [Int: String] = [:]
        for line in DevicePDFFontsData.latinEncodings.split(separator: "\n") {
            let p = line.split(separator: " ").map(String.init)
            guard p.count == 5, let text = name2unicode(p[0]) else { continue }
            if let c = Int(p[1]) { std[c] = text }
            if let c = Int(p[2]) { mac[c] = text }
            if let c = Int(p[3]) { win[c] = text }
            if let c = Int(p[4]) { pdf[c] = text }
        }
        return ["StandardEncoding": std, "MacRomanEncoding": mac, "WinAnsiEncoding": win, "PDFDocEncoding": pdf]
    }()

    /// pdfminer `EncodingDB.get_encoding`.
    static func encoding(_ name: String, differences: [DevicePDFObject.Value]? = nil) -> [Int: String] {
        var map = latin[name] ?? latin["StandardEncoding"]!
        guard let differences, !differences.isEmpty else { return map }
        var code = 0
        for x in differences {
            switch x {
            case .int(let i): code = i
            case .name(let n):
                if let t = name2unicode(n) { map[code] = t }
                code += 1
            default: break
            }
        }
        return map
    }
}

// MARK: - Core 14 metrics

struct DevicePDFCoreMetrics: Sendable {
    let fontName: String
    let flags: Int
    let bbox: [Double]
    let ascent: Double?
    let descent: Double?
    let missingWidth: Double?
    let widths: [String: Double]

    static let all: [String: DevicePDFCoreMetrics] = {
        var out: [String: DevicePDFCoreMetrics] = [:]
        let lines = DevicePDFFontsData.coreMetrics.split(separator: "\n").map(String.init)
        var k = 0
        while k + 1 < lines.count {
            let head = lines[k].split(separator: "\t").map(String.init)
            var widths: [String: Double] = [:]
            for pair in lines[k + 1].split(separator: " ") {
                let kv = pair.split(separator: ":")
                if kv.count == 2, let v = UInt32(kv[0], radix: 16), let s = Unicode.Scalar(v), let w = Double(kv[1]) { widths[String(Character(s))] = w }
            }
            if head.count == 7 {
                let num: (String) -> Double? = { $0 == "-" ? nil : Double($0) }
                out[head[0]] = DevicePDFCoreMetrics(fontName: head[1], flags: Int(head[2]) ?? 0,
                    bbox: head[3].split(separator: ",").compactMap { Double($0) }, ascent: num(head[4]), descent: num(head[5]),
                    missingWidth: num(head[6]), widths: widths)
            }
            k += 2
        }
        for (alias, base) in DevicePDFFontsData.coreAliases { out[alias] = out[base] }
        return out
    }()
}

// MARK: - Fonts

/// One font as pdfminer's `PDFFont` subclasses model it.
final class DevicePDFFont {
    enum CodeMap { case singleByte, identity2, identity1, empty }

    private(set) var fontname = "unknown"
    private var descent: Double = 0
    private var hscale = 0.001, vscale = 0.001
    private var widths: [Int: Double] = [:]
    private var textWidths: [String: Double] = [:]
    private var defaultWidth: Double = 0
    private var cid2unicode: [Int: String] = [:]
    private var unicodeMap: [Int: String]? = nil
    private var identityUnicode = false
    private(set) var multibyte = false
    private(set) var vertical = false
    private var codes: CodeMap = .singleByte
    private var disps: [Int: (Double?, Double)] = [:]
    private var defaultDisp: (Double?, Double) = (nil, 0)

    var descentInTextSpace: Double { descent * vscale }

    /// pdfminer `PDFResourceManager.get_font`.
    static func make(_ spec: CGPDFDictionaryRef?) -> DevicePDFFont {
        let font = DevicePDFFont()
        let subtype = DevicePDFObject.name(spec, "Subtype") ?? "Type1"
        switch subtype {
        case "Type3": font.loadType3(spec)
        case "CIDFontType0", "CIDFontType2": font.loadCID(spec, encoding: nil, toUnicode: nil)
        case "Type0":
            var descendant: CGPDFDictionaryRef? = nil
            if let fonts = DevicePDFObject.array(spec, "DescendantFonts"), case .dict(let d)? = DevicePDFObject.items(fonts).first { descendant = d }
            font.loadCID(descendant, encoding: DevicePDFObject.get(spec, "Encoding"), toUnicode: DevicePDFObject.get(spec, "ToUnicode"))
        default: font.loadType1(spec) // Type1, MMType1, TrueType, and pdfminer's fallback for anything else
        }
        return font
    }

    // PDFFont.__init__
    private func loadDescriptor(_ descriptor: CGPDFDictionaryRef?, defaultWidth: Double? = nil) {
        switch DevicePDFObject.get(descriptor, "FontName") {
        case .name(let n)?: fontname = n
        case .string(let b)?: fontname = String(decoding: b, as: UTF8.self) // pdfplumber decodes a byte-string name
        default: fontname = "unknown"
        }
        descent = DevicePDFObject.number(descriptor, "Descent") ?? 0
        self.defaultWidth = defaultWidth ?? DevicePDFObject.number(descriptor, "MissingWidth") ?? 0
        if descent > 0 { descent = -descent }
    }

    // PDFSimpleFont.__init__ (encoding and ToUnicode)
    private func loadSimpleEncoding(_ spec: CGPDFDictionaryRef?) {
        switch DevicePDFObject.get(spec, "Encoding") {
        case nil: cid2unicode = DevicePDFFontEncoding.encoding("StandardEncoding")
        case .dict(let d)?:
            let base = DevicePDFObject.name(d, "BaseEncoding") ?? "StandardEncoding"
            let diff = DevicePDFObject.array(d, "Differences").map(DevicePDFObject.items)
            cid2unicode = DevicePDFFontEncoding.encoding(base, differences: diff)
        case .name(let n)?: cid2unicode = DevicePDFFontEncoding.encoding(n)
        default: cid2unicode = DevicePDFFontEncoding.encoding("")
        }
        if let s = DevicePDFObject.stream(spec, "ToUnicode") {
            unicodeMap = DevicePDFObject.data(s).map(DevicePDFCMap.toUnicode) ?? [:]
        } else if DevicePDFObject.has(spec, "ToUnicode") {
            unicodeMap = [:] // pdfminer reads a non-stream as an empty stream
        }
    }

    private func simpleWidths(_ spec: CGPDFDictionaryRef?) {
        let first = DevicePDFObject.int(spec, "FirstChar") ?? 0
        if let list = DevicePDFObject.array(spec, "Widths") {
            for (k, v) in DevicePDFObject.items(list).enumerated() { if let w = v.number { widths[first + k] = w } }
        } else {
            for k in 0..<256 { widths[first + k] = 0 }
        }
    }

    // PDFType1Font / PDFTrueTypeFont
    private func loadType1(_ spec: CGPDFDictionaryRef?) {
        let basefont = DevicePDFObject.name(spec, "BaseFont") ?? "unknown"
        var descriptor: CGPDFDictionaryRef? = nil
        if let core = DevicePDFCoreMetrics.all[basefont] {
            textWidths = core.widths
            loadSimpleEncoding(spec)
            fontname = core.fontName
            descent = core.descent ?? 0
            defaultWidth = core.missingWidth ?? 0
            if descent > 0 { descent = -descent }
        } else {
            descriptor = DevicePDFObject.dict(spec, "FontDescriptor")
            simpleWidths(spec)
            loadSimpleEncoding(spec)
            loadDescriptor(descriptor)
        }
        if !DevicePDFObject.has(spec, "Encoding"), let file = DevicePDFObject.stream(descriptor, "FontFile") {
            let length1 = DevicePDFObject.int(CGPDFStreamGetDictionary(file), "Length1") ?? 0
            if let data = DevicePDFObject.data(file) {
                cid2unicode = DevicePDFCMap.type1Encoding(Array(data.prefix(max(0, length1))))
            }
        }
    }

    // PDFType3Font
    private func loadType3(_ spec: CGPDFDictionaryRef?) {
        simpleWidths(spec)
        let descriptor = DevicePDFObject.dict(spec, "FontDescriptor")
        loadSimpleEncoding(spec)
        loadDescriptor(descriptor)
        let bbox = DevicePDFObject.rect(descriptor != nil ? DevicePDFObject.array(descriptor, "FontBBox") : DevicePDFObject.array(spec, "FontBBox")) ?? [0, 0, 0, 0]
        descent = bbox[1] // not forced negative: set after PDFFont.__init__
        if let m = DevicePDFObject.array(spec, "FontMatrix").map(DevicePDFObject.items).map({ $0.compactMap(\.number) }), m.count >= 4 {
            hscale = m[0] + m[2]
            vscale = m[1] + m[3]
        }
    }

    // PDFCIDFont
    private func loadCID(_ spec: CGPDFDictionaryRef?, encoding: DevicePDFObject.Value?, toUnicode: DevicePDFObject.Value?) {
        multibyte = true
        let info = DevicePDFObject.dict(spec, "CIDSystemInfo")
        func text(_ key: String) -> String {
            if case .string(let b)? = DevicePDFObject.get(info, key) { return String(b.map { Character(Unicode.Scalar($0)) }) }
            return "unknown"
        }
        let ordering = text("Ordering").trimmingCharacters(in: .whitespacesAndNewlines)
        let cidcoding = "\(text("Registry").trimmingCharacters(in: .whitespacesAndNewlines))-\(ordering)"
        let encodingValue = encoding ?? DevicePDFObject.get(spec, "Encoding")
        var cmapName = "unknown"
        var encodingName = "unknown"
        if case .name(let n)? = encodingValue { encodingName = n }
        switch encodingValue {
        case .name(let n)?: cmapName = n
        case .stream(let s)?: cmapName = DevicePDFObject.name(CGPDFStreamGetDictionary(s), "CMapName") ?? "unknown"
        case .dict(let d)?: cmapName = DevicePDFObject.name(d, "CMapName") ?? "unknown"
        default: break
        }
        if cmapName == "DLIdent-H" { cmapName = "Identity-H" }
        if cmapName == "DLIdent-V" { cmapName = "Identity-V" }
        switch cmapName {
        case "Identity-H": codes = .identity2
        case "Identity-V": codes = .identity2; vertical = true
        case "OneByteIdentityH": codes = .identity1
        case "OneByteIdentityV": codes = .identity1; vertical = true
        default: codes = .empty // predefined CJK CMaps are not shipped (pdfminer reads them from its own data files)
        }
        let descriptor = DevicePDFObject.dict(spec, "FontDescriptor")
        let toUnicodeValue = toUnicode ?? DevicePDFObject.get(spec, "ToUnicode")
        switch toUnicodeValue {
        case .stream(let s)?: unicodeMap = DevicePDFObject.data(s).map(DevicePDFCMap.toUnicode) ?? [:]
        case .name(let n)?:
            if ordering.contains("Identity") || n.contains("Identity") || encodingName.contains("Identity") { identityUnicode = true }
        case nil:
            if cidcoding == "Adobe-Identity" || cidcoding == "Adobe-UCS", let file = DevicePDFObject.stream(descriptor, "FontFile2"),
               let data = DevicePDFObject.data(file) {
                unicodeMap = DevicePDFTrueTypeCMap.unicodeMap(data)
            }
        default: break
        }
        if vertical {
            let w2 = DevicePDFObject.array(spec, "W2").map(DevicePDFObject.items) ?? []
            var r: [DevicePDFObject.Value] = []
            for v in w2 {
                if case .array(let a) = v {
                    if let first = r.last?.number {
                        let xs = DevicePDFObject.items(a).compactMap(\.number)
                        var k = 0
                        while k + 3 <= xs.count { let cid = Int(first) + k / 3; widths[cid] = xs[k]; disps[cid] = (xs[k + 1], xs[k + 2]); k += 3 }
                        r = []
                    }
                } else if v.number != nil {
                    r.append(v)
                    if r.count == 5, let c1 = r[0].number, let c2 = r[1].number, let w = r[2].number, let vx = r[3].number, let vy = r[4].number {
                        if Int(c2) >= Int(c1) { for cid in Int(c1)...Int(c2) { widths[cid] = w; disps[cid] = (vx, vy) } }
                        r = []
                    }
                }
            }
            let dw2 = DevicePDFObject.array(spec, "DW2").map(DevicePDFObject.items)?.compactMap(\.number) ?? [880, -1000]
            defaultDisp = (nil, dw2.first ?? 880)
            loadDescriptor(descriptor, defaultWidth: dw2.count > 1 ? dw2[1] : -1000)
        } else {
            for (cid, w) in Self.cidWidths(DevicePDFObject.array(spec, "W").map(DevicePDFObject.items) ?? []) { widths[cid] = w }
            loadDescriptor(descriptor, defaultWidth: DevicePDFObject.number(spec, "DW") ?? 1000)
        }
    }

    /// pdfminer `get_widths`.
    static func cidWidths(_ seq: [DevicePDFObject.Value]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        var r: [DevicePDFObject.Value] = []
        for v in seq {
            switch v {
            case .array(let a):
                if let last = r.last {
                    if case .int(let c1) = last {
                        for (k, w) in DevicePDFObject.items(a).enumerated() { if let w = w.number { out[c1 + k] = w } }
                    }
                    r = []
                }
            case .int, .real:
                r.append(v)
                if r.count == 3 {
                    if case .int(let c1) = r[0], case .int(let c2) = r[1], let w = r[2].number, c2 >= c1, c2 - c1 < 1 << 20 {
                        for cid in c1...c2 { out[cid] = w }
                    }
                    r = []
                }
            default: break
            }
        }
        return out
    }

    func decode(_ bytes: [UInt8]) -> [Int] {
        switch codes {
        case .singleByte, .identity1: return bytes.map(Int.init)
        case .identity2:
            var out: [Int] = []
            out.reserveCapacity(bytes.count / 2)
            var k = 0
            while k + 1 < bytes.count { out.append(Int(bytes[k]) << 8 | Int(bytes[k + 1])); k += 2 }
            return out
        case .empty: return []
        }
    }

    func text(_ cid: Int) -> String? {
        if multibyte {
            if identityUnicode {
                guard let s = Unicode.Scalar(UInt32(truncatingIfNeeded: cid)) else { return "\u{FFFD}" }
                return String(Character(s))
            }
            return unicodeMap?[cid]
        }
        if let t = unicodeMap?[cid] { return t }
        return cid2unicode[cid]
    }

    func charWidth(_ cid: Int) -> Double {
        if let w = widths[cid] { return w * hscale }
        if !textWidths.isEmpty, let t = text(cid), let w = textWidths[t] { return w * hscale }
        return defaultWidth * hscale
    }

    /// Vertical fonts: (vx, vy) with vx nil when unspecified.
    func charDisp(_ cid: Int) -> (Double?, Double) { disps[cid] ?? defaultDisp }
}

/// pdfminer `TrueTypeFont.create_unicode_map`: the font program's own cmap, glyph -> text, for a CID font without a
/// ToUnicode map. Unicode subtables of formats 0, 2 and 4, read the way pdfminer reads them (its format 4 idRangeOffset
/// is taken from the start of the array, not the segment's own entry; kept for fidelity).
enum DevicePDFTrueTypeCMap {
    static func unicodeMap(_ data: [UInt8]) -> [Int: String]? {
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= data.count ? Int(data[o]) << 8 | Int(data[o + 1]) : nil }
        func s16(_ o: Int) -> Int? { u16(o).map { $0 >= 0x8000 ? $0 - 0x10000 : $0 } }
        func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= data.count ? Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3]) : nil }
        guard let ntables = u16(4) else { return nil }
        var cmapOffset: Int? = nil
        for t in 0..<ntables {
            let rec = 12 + 16 * t
            guard rec + 16 <= data.count else { break }
            if data[rec] == 0x63, data[rec + 1] == 0x6D, data[rec + 2] == 0x61, data[rec + 3] == 0x70 { cmapOffset = u32(rec + 8) }
        }
        guard let base = cmapOffset, let nsubtables = u16(base + 2) else { return nil }
        var char2gid: [Int: Int] = [:], order: [Int] = []
        func set(_ c: Int, _ g: Int) { if char2gid.updateValue(g, forKey: c) == nil { order.append(c) } }
        for k in 0..<nsubtables {
            let rec = base + 4 + 8 * k
            guard let platform = u16(rec), let encoding = u16(rec + 2), let offset = u32(rec + 4) else { break }
            guard platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10)) else { continue }
            let st = base + offset
            guard let format = u16(st) else { continue }
            switch format {
            case 0:
                for c in 0..<256 { guard st + 6 + c < data.count else { break }; set(c, Int(data[st + 6 + c])) }
            case 2:
                var keys: [Int] = []
                for i in 0..<256 { guard let v = u16(st + 6 + 2 * i) else { break }; keys.append(v) }
                guard keys.count == 256 else { continue }
                var firstbytes = [Int](repeating: 0, count: 8192)
                for (i, key) in keys.enumerated() { firstbytes[key / 8] = i }
                let nhdrs = (keys.max() ?? 0) / 8 + 1
                var headers: [(Int, Int, Int, Int, Int)] = []
                for i in 0..<nhdrs {
                    let h = st + 6 + 512 + 8 * i
                    guard let firstcode = u16(h), let entcount = u16(h + 2), let delta = s16(h + 4), let off = u16(h + 6) else { break }
                    headers.append((i, firstcode, entcount, delta, h + 6 + off))
                }
                for (i, firstcode, entcount, delta, pos) in headers where entcount > 0 {
                    let first = firstcode + (firstbytes[i] << 8)
                    for c in 0..<entcount {
                        guard var gid = u16(pos + 2 * c) else { break }
                        if gid != 0 { gid += delta }
                        set(first + c, gid)
                    }
                }
            case 4:
                guard let segcount2 = u16(st + 6) else { continue }
                let segcount = segcount2 / 2
                let ends = st + 14, starts = ends + 2 * segcount + 2, deltas = starts + 2 * segcount, offsets = deltas + 2 * segcount
                for i in 0..<segcount {
                    guard let ec = u16(ends + 2 * i), let sc = u16(starts + 2 * i), let idd = s16(deltas + 2 * i),
                          let idr = u16(offsets + 2 * i) else { break }
                    guard ec >= sc else { continue }
                    if idr != 0 {
                        for c in sc...ec { guard let b = u16(offsets + idr + 2 * (c - sc)) else { break }; set(c, (b + idd) & 0xFFFF) }
                    } else {
                        for c in sc...ec { set(c, (c + idd) & 0xFFFF) }
                    }
                }
            default: continue // pdfminer asserts here and the font fails; nothing is read from it
            }
        }
        guard !order.isEmpty else { return nil }
        var out: [Int: String] = [:]
        for c in order {
            let gid = char2gid[c]!
            guard let s = Unicode.Scalar(UInt32(truncatingIfNeeded: c)) else { continue }
            let text = String(Character(s))
            if text == "\u{00A0}", out[gid] == " " { continue }
            out[gid] = text
        }
        return out
    }
}

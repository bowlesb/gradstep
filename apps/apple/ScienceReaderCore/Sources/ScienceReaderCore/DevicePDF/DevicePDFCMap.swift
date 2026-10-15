import Foundation

// The PostScript reading the text layer needs: ToUnicode CMaps and the cleartext encoding of an embedded Type 1
// font. A faithful port of pdfminer.six's `psparser.PSBaseParser`/`PSStackParser`, `cmapdb.CMapParser` and
// `pdffont.Type1FontHeaderParser` (MIT License, Copyright (c) 2004-2016 Yusuke Shinyama), quirks included, because the
// device route's reference text layer is pdfplumber over pdfminer (docs/architecture/DEVICE_PDF_ROUTE.md).

/// One PostScript value as pdfminer's stack parser yields it.
indirect enum DevicePDFPSValue {
    case int(Int)
    case real(Double)
    case bool(Bool)
    case string([UInt8])
    case literal(String)
    case keyword(String)
    case array([DevicePDFPSValue])
    case dict([String: DevicePDFPSValue])

    var bytes: [UInt8]? { if case .string(let b) = self { return b }; return nil }
    var int: Int? { if case .int(let i) = self { return i }; return nil }
}

/// pdfminer's PSBaseParser tokenizer over a byte buffer.
struct DevicePDFPSLexer {
    enum Token {
        case value(DevicePDFPSValue)   // number, bool, string, literal
        case keyword(String)           // including "[", "]", "{", "}", "<<", ">>"
    }
    private let s: [UInt8]
    private var i = 0
    init(_ bytes: [UInt8]) { s = bytes }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x0B }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
    private static func isAlpha(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    /// `[#/%\[\]()<>{}\s]`
    private static func endsName(_ c: UInt8) -> Bool {
        isSpace(c) || c == 0x23 || c == 0x2F || c == 0x25 || c == 0x5B || c == 0x5D || c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x7B || c == 0x7D
    }
    private static func hexValue(_ c: UInt8) -> UInt8 {
        if c <= 0x39 { return c - 0x30 }
        if c <= 0x46 { return c - 0x41 + 10 }
        return c - 0x61 + 10
    }

    mutating func next() -> Token? {
        while i < s.count {
            let c = s[i]
            if Self.isSpace(c) { i += 1; continue }
            if c == 0x25 { // % comment to end of line
                while i < s.count, s[i] != 0x0A, s[i] != 0x0D { i += 1 }
                continue
            }
            if c == 0x2F { i += 1; return .value(.literal(literal())) }
            if c == 0x2D || c == 0x2B || Self.isDigit(c) {
                if let n = number() { return .value(n) }
                continue
            }
            if c == 0x2E {
                if let n = float(start: i, prefix: []) { return .value(n) }
                continue
            }
            if Self.isAlpha(c) {
                let start = i
                i += 1
                while i < s.count, !Self.endsName(s[i]) { i += 1 }
                let word = String(decoding: s[start..<i], as: UTF8.self)
                if word == "true" { return .value(.bool(true)) }
                if word == "false" { return .value(.bool(false)) }
                return .keyword(word)
            }
            if c == 0x28 { i += 1; return .value(.string(string())) }
            if c == 0x3C {
                i += 1
                if i < s.count, s[i] == 0x3C { i += 1; return .keyword("<<") }
                return .value(.string(hexString()))
            }
            if c == 0x3E {
                i += 1
                if i < s.count, s[i] == 0x3E { i += 1; return .keyword(">>") }
                continue
            }
            if c == 0x00 { i += 1; continue }
            i += 1
            return .keyword(String(decoding: [c], as: UTF8.self))
        }
        return nil
    }

    private mutating func literal() -> String {
        var token: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if c == 0x23 { // #xx
                i += 1
                var hex: [UInt8] = []
                while i < s.count, hex.count < 2, Self.isHex(s[i]) { hex.append(s[i]); i += 1 }
                if !hex.isEmpty { token.append(hex.reduce(0) { $0 &* 16 &+ Self.hexValue($1) }) }
                continue
            }
            if Self.endsName(c) { break }
            token.append(c); i += 1
        }
        return String(bytes: token, encoding: .utf8) ?? String(decoding: token, as: UTF8.self)
    }

    private mutating func number() -> DevicePDFPSValue? {
        let start = i
        i += 1
        while i < s.count, Self.isDigit(s[i]) { i += 1 }
        if i < s.count, s[i] == 0x2E { return float(start: start, prefix: []) }
        let text = String(decoding: s[start..<i], as: UTF8.self)
        if let v = Int(text) { return .int(v) }
        return nil
    }

    /// From `start`: the digits so far, the '.', then digits (pdfminer's `_parse_float`).
    private mutating func float(start: Int, prefix: [UInt8]) -> DevicePDFPSValue? {
        // `i` is at the '.' (or within digits before it).
        while i < s.count, s[i] != 0x2E { i += 1 }
        i += 1
        while i < s.count, Self.isDigit(s[i]) { i += 1 }
        let text = String(decoding: s[start..<i], as: UTF8.self)
        if let v = Double(text) { return .real(v) }
        // Python's float() also takes "5." and ".5"; Double() takes both, and "-." / "." fail in both.
        return nil
    }

    private mutating func string() -> [UInt8] {
        var token: [UInt8] = []
        var paren = 1
        while i < s.count {
            let c = s[i]
            if c == 0x5C { // backslash
                i += 1
                guard i < s.count else { break }
                let e = s[i]
                if e >= 0x30 && e <= 0x37 {
                    var oct = 0, n = 0
                    while i < s.count, n < 3, s[i] >= 0x30, s[i] <= 0x37 { oct = oct * 8 + Int(s[i] - 0x30); i += 1; n += 1 }
                    token.append(UInt8(truncatingIfNeeded: oct))
                    continue
                }
                switch e {
                case 0x62: token.append(8)
                case 0x74: token.append(9)
                case 0x6E: token.append(10)
                case 0x66: token.append(12)
                case 0x72: token.append(13)
                case 0x28, 0x29, 0x5C: token.append(e)
                case 0x0D: if i + 1 < s.count, s[i + 1] == 0x0A { i += 1 }
                default: break // pdfminer drops an unknown escape and the backslash
                }
                i += 1
                continue
            }
            if c == 0x28 { paren += 1; token.append(c); i += 1; continue }
            if c == 0x29 {
                paren -= 1
                i += 1
                if paren > 0 { token.append(c); continue }
                return token
            }
            token.append(c); i += 1
        }
        return token
    }

    private mutating func hexString() -> [UInt8] {
        var digits: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if Self.isSpace(c) { i += 1; continue }
            if !Self.isHex(c) { break }
            digits.append(c); i += 1
        }
        var out: [UInt8] = []
        var k = 0
        while k < digits.count {
            if k + 1 < digits.count { out.append(Self.hexValue(digits[k]) << 4 | Self.hexValue(digits[k + 1])); k += 2 }
            else { out.append(Self.hexValue(digits[k])); k += 1 } // a lone digit is its own value (pdfminer's HEX_PAIR ".")
        }
        return out
    }
}

/// pdfminer's PSStackParser: arrays, dicts and procs built on a context stack; keywords handed to `keyword`.
struct DevicePDFPSStackParser {
    private var lexer: DevicePDFPSLexer
    private var context: [(type: Character, stack: [DevicePDFPSValue])] = []
    var stack: [DevicePDFPSValue] = []
    private var type: Character? = nil

    init(_ bytes: [UInt8]) { lexer = DevicePDFPSLexer(bytes) }

    mutating func popAll() -> [DevicePDFPSValue] { defer { stack = [] }; return stack }
    mutating func pop(_ n: Int) -> [DevicePDFPSValue] {
        let k = min(n, stack.count)
        let out = Array(stack.suffix(k))
        stack.removeLast(k)
        return out
    }

    /// Runs to the end of the input, calling `keyword` for each keyword that is not structure.
    mutating func run(_ keyword: (inout DevicePDFPSStackParser, String) -> Void) {
        while let token = lexer.next() {
            switch token {
            case .value(let v): stack.append(v)
            case .keyword("["): begin("a")
            case .keyword("]"): if let items = end("a") { stack.append(.array(items)) }
            case .keyword("<<"): begin("d")
            case .keyword(">>"):
                if let items = end("d") {
                    // An odd count is a syntax error in pdfminer: nothing is pushed.
                    if items.count % 2 == 0 {
                        var d: [String: DevicePDFPSValue] = [:]
                        var k = 0
                        while k < items.count {
                            if case .literal(let name) = items[k] { d[name] = items[k + 1] }
                            k += 2
                        }
                        stack.append(.dict(d))
                    }
                }
            case .keyword("{"): begin("p")
            case .keyword("}"): if let items = end("p") { stack.append(.array(items)) }
            case .keyword(let word): keyword(&self, word)
            }
        }
    }

    private mutating func begin(_ t: Character) {
        context.append((type ?? " ", stack))
        type = t
        stack = []
    }
    private mutating func end(_ t: Character) -> [DevicePDFPSValue]? {
        guard type == t, let outer = context.popLast() else { return nil } // a mismatch is ignored (pdfminer non-strict)
        let items = stack
        stack = outer.stack
        type = outer.type == " " ? nil : outer.type
        return items
    }
}

enum DevicePDFCMap {
    /// pdfminer `utils.nunpack`: big-endian unsigned.
    static func nunpack(_ b: [UInt8]) -> Int {
        var v = 0
        for x in b { v = (v &<< 8) | Int(x) }
        return v
    }

    /// Python's `bytes.decode("UTF-16BE", "ignore")`.
    static func utf16BE(_ b: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        var k = 0
        while k + 1 < b.count {
            let u = UInt32(b[k]) << 8 | UInt32(b[k + 1])
            k += 2
            if u >= 0xD800 && u <= 0xDBFF {
                if k + 1 < b.count {
                    let lo = UInt32(b[k]) << 8 | UInt32(b[k + 1])
                    if lo >= 0xDC00 && lo <= 0xDFFF {
                        k += 2
                        if let scalar = Unicode.Scalar(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)) { scalars.append(scalar) }
                    }
                    // an unpaired high surrogate is dropped; the next unit is read on its own
                }
                continue
            }
            if u >= 0xDC00 && u <= 0xDFFF { continue }
            if let scalar = Unicode.Scalar(u) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// A ToUnicode CMap as pdfminer's `FileUnicodeMap` filled by `CMapParser`: cid -> text.
    static func toUnicode(_ data: [UInt8]) -> [Int: String] {
        var map: [Int: String] = [:]
        func add(_ cid: Int, _ code: DevicePDFPSValue) {
            let text: String
            switch code {
            case .literal(let name):
                guard let t = DevicePDFFontEncoding.name2unicode(name) else { return }
                text = t
            case .string(let b): text = utf16BE(b)
            case .int(let i):
                guard let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: i)) else { return }
                text = String(Character(scalar))
            default: return
            }
            if text == "\u{00A0}", map[cid] == " " { return }
            map[cid] = text
        }
        var inCMap = true
        var parser = DevicePDFPSStackParser(data)
        parser.run { p, word in
            switch word {
            case "begincmap": inCMap = true; _ = p.popAll(); return
            case "endcmap": inCMap = false; return
            default: break
            }
            guard inCMap else { return }
            switch word {
            case "def": _ = p.pop(2)
            case "usecmap": _ = p.pop(1)
            case "begincodespacerange", "endcodespacerange", "begincidrange", "begincidchar", "beginbfrange", "beginbfchar",
                 "beginnotdefrange", "endnotdefrange":
                _ = p.popAll()
            case "endcidrange":
                let objs = p.popAll()
                var k = 0
                while k + 3 <= objs.count {
                    defer { k += 3 }
                    guard let sb = objs[k].bytes, let eb = objs[k + 1].bytes, let cid = objs[k + 2].int, sb.count == eb.count else { continue }
                    let sp = Array(sb.dropLast(4)), ep = Array(eb.dropLast(4))
                    guard sp == ep else { continue }
                    let sv = Array(sb.suffix(4)), ev = Array(eb.suffix(4))
                    let start = nunpack(sv), end = nunpack(ev), vlen = sv.count
                    guard end >= start, end - start < 65_536 else { continue }
                    for n in 0...(end - start) {
                        add(cid + n, .string(sp + packed(start + n, vlen)))
                    }
                }
            case "endcidchar":
                let objs = p.popAll()
                var k = 0
                while k + 2 <= objs.count {
                    // pdfminer reads the pair as (cid, code) and requires an int then bytes; the CMap syntax is
                    // <code> cid, so this adds nothing for well-formed input (kept for fidelity).
                    if let cid = objs[k].int, case .string = objs[k + 1] { add(cid, objs[k + 1]) }
                    k += 2
                }
            case "endbfrange":
                let objs = p.popAll()
                var k = 0
                while k + 3 <= objs.count {
                    defer { k += 3 }
                    guard let sb = objs[k].bytes, let eb = objs[k + 1].bytes, sb.count == eb.count else { continue }
                    let start = nunpack(sb), end = nunpack(eb)
                    if case .array(let codes) = objs[k + 2] {
                        var cid = start
                        for code in codes where cid <= end { add(cid, code); cid += 1 }
                    } else if let code = objs[k + 2].bytes {
                        guard end >= start, end - start < 65_536 else { continue }
                        let v = Array(code.suffix(4)), prefix = Array(code.dropLast(4))
                        let base = nunpack(v)
                        for n in 0...(end - start) { add(start + n, .string(prefix + packed(base + n, v.count))) }
                    }
                }
            case "endbfchar":
                let objs = p.popAll()
                var k = 0
                while k + 2 <= objs.count {
                    if let cid = objs[k].bytes, let code = objs[k + 1].bytes { add(nunpack(cid), .string(code)) }
                    k += 2
                }
            default:
                p.stack.append(.keyword(word))
            }
        }
        return map
    }

    /// `struct.pack(">L", v)[-n:]`
    private static func packed(_ v: Int, _ n: Int) -> [UInt8] {
        let x = UInt32(truncatingIfNeeded: v)
        let all: [UInt8] = [UInt8(x >> 24), UInt8(x >> 16 & 0xFF), UInt8(x >> 8 & 0xFF), UInt8(x & 0xFF)]
        return Array(all.suffix(n))
    }

    /// The cleartext part of an embedded Type 1 program: `dup <code> /<name> put` entries as code -> text
    /// (pdfminer's `Type1FontHeaderParser.get_encoding`, unknown names left out).
    static func type1Encoding(_ cleartext: [UInt8]) -> [Int: String] {
        var map: [Int: String] = [:]
        var parser = DevicePDFPSStackParser(cleartext)
        parser.run { p, word in
            // Only `put` acts (other keywords are not pushed: Type1FontHeaderParser overrides do_keyword).
            guard word == "put" else { return }
            let pair = p.pop(2)
            guard pair.count == 2, let code = pair[0].int, case .literal(let name) = pair[1] else { return }
            if let text = DevicePDFFontEncoding.name2unicode(name) { map[code] = text }
        }
        return map
    }
}

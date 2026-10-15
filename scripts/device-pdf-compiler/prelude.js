// A bare JavaScriptCore JSContext has no TextEncoder/TextDecoder; the converter's shared helpers create them when
// their module loads. UTF-8 only, `fatal` honoured, the BOM kept (as `ignoreBOM: true`).
(function () {
  if (typeof globalThis.TextEncoder === 'undefined') {
    globalThis.TextEncoder = class TextEncoder {
      get encoding() { return 'utf-8'; }
      encode(input = '') {
        const s = String(input), out = [];
        for (let i = 0; i < s.length; i++) {
          let c = s.charCodeAt(i);
          if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
            const d = s.charCodeAt(i + 1);
            if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; } else c = 0xfffd;
          } else if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
          if (c < 0x80) out.push(c);
          else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
          else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
          else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
        return new Uint8Array(out);
      }
    };
  }
  if (typeof globalThis.TextDecoder === 'undefined') {
    globalThis.TextDecoder = class TextDecoder {
      constructor(label = 'utf-8', options = {}) {
        if (!/^utf-?8$/i.test(String(label))) throw new RangeError('encoding');
        this.fatal = !!options.fatal;
      }
      get encoding() { return 'utf-8'; }
      decode(input) {
        const b = input instanceof Uint8Array ? input : new Uint8Array(input ? (input.buffer ?? input) : []);
        const parts = []; let chunk = [];
        const bad = () => { if (this.fatal) throw new TypeError('invalid utf-8'); chunk.push(0xfffd); };
        for (let i = 0; i < b.length;) {
          const x = b[i];
          let n = 0, c = 0, min = 0;
          if (x < 0x80) { chunk.push(x); i++; }
          else {
            if (x >= 0xc2 && x <= 0xdf) { n = 1; c = x & 31; min = 0x80; }
            else if (x >= 0xe0 && x <= 0xef) { n = 2; c = x & 15; min = 0x800; }
            else if (x >= 0xf0 && x <= 0xf4) { n = 3; c = x & 7; min = 0x10000; }
            else { bad(); i++; continue; }
            if (i + n >= b.length) { bad(); i = b.length; continue; } // a sequence cut short at the end
            let ok = true;
            for (let k = 1; k <= n; k++) { const y = b[i + k]; if ((y & 0xc0) !== 0x80) { ok = false; break; } c = (c << 6) | (y & 63); }
            if (!ok || c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) { bad(); i++; continue; }
            i += n + 1;
            if (c >= 0x10000) { c -= 0x10000; chunk.push(0xd800 + (c >> 10), 0xdc00 + (c & 1023)); } else chunk.push(c);
          }
          if (chunk.length >= 8192) { parts.push(String.fromCharCode.apply(null, chunk)); chunk = []; }
        }
        parts.push(String.fromCharCode.apply(null, chunk));
        return parts.join('');
      }
    };
  }
})();

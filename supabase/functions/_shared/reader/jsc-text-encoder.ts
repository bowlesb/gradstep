// JavaScriptCore without a web view (the native metadata extractor's JSContext) has no TextEncoder, and the shared
// reader code creates one when it loads. UTF-8 encoding is all it needs; browsers and Deno keep their own.
// Imported first by source-metadata-entry.ts so it runs before the modules that use it.
const g = globalThis as { TextEncoder?: unknown };
if (typeof g.TextEncoder === 'undefined') {
  g.TextEncoder = class {
    readonly encoding = 'utf-8';
    encode(text = ''): Uint8Array {
      const out: number[] = [];
      for (const ch of String(text)) {
        const c = ch.codePointAt(0)!;
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
        else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
      return Uint8Array.from(out);
    }
  };
}
export {};

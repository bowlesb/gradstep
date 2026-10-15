// A synthetic paper for the device PDF converter's tests: glyphs laid out like a LaTeX article, layout detections
// where a detector would put them, and deterministic stand-ins for the three models (the same rules the Python
// reference ran with when `synthetic-reference.json` was recorded: scripts in the fixture's README).
import { zlibSync } from 'fflate';
import type { DevicePDFHost, DevicePDFInput, PageInput, TagLine, TaggerVocabulary } from '../../../supabase/functions/_shared/reader/device-pdf/types.ts';
import { encodeBase64 } from '../../../supabase/functions/_shared/reader/device-pdf/base64.ts';

export const W = 612, H = 792;
export const IMAGE_W = Math.round(W * 150 / 72), IMAGE_H = Math.round(H * 150 / 72);
export const SCALE_CANVAS = Math.min(1024 / IMAGE_W, 1440 / IMAGE_H);
export interface G { text: string; x0: number; top: number; x1: number; bottom: number; size: number; font: string; upright: boolean }

/** One line of glyphs: 0.5 em per character; a `$…$` run is set in CMMI10, `^…^` in CMSY10. */
export function line(text: string, x: number, y: number, size = 10, font = 'ABCDEF+CMR10'): G[] {
  const out: G[] = []; let cx = x, mode = '';
  for (const ch of text) {
    if (ch === '$' || ch === '^') { mode = mode === ch ? '' : ch; continue; }
    const w = size * 0.5;
    if (ch === ' ') { cx += w; continue; }
    out.push({ text: ch, x0: cx, top: y, x1: cx + w, bottom: y + size, size, upright: true,
      font: mode === '$' ? 'XYZABC+CMMI10' : mode === '^' ? 'QRSTUV+CMSY10' : font });
    cx += w;
  }
  return out;
}
export function lines(texts: string[], x: number, y: number, size = 10, font?: string, leading = 12): G[] {
  return texts.flatMap((t, i) => line(t, x, y + i * leading, size, font));
}
export const extent = (gl: G[], pad = 1): number[] => [Math.min(...gl.map(g => g.x0)) - pad, Math.min(...gl.map(g => g.top)) - pad, Math.max(...gl.map(g => g.x1)) + pad, Math.max(...gl.map(g => g.bottom)) + pad];
/** A detection: a box in points to canvas pixels (0.1 px, as the reference rounds). */
export const det = (cls: string, box: number[], score = 0.9) => ({ cls, score, box: box.map(v => Math.round(v * 150 / 72 * SCALE_CANVAS * 10) / 10) });

export function page(glyphs: G[], detections: PageInput['detections']): PageInput {
  return { width: W, height: H, image_width: IMAGE_W, image_height: IMAGE_H, scale: SCALE_CANVAS,
    glyphs: { text: glyphs.map(g => g.text), x0: glyphs.map(g => g.x0), top: glyphs.map(g => g.top), x1: glyphs.map(g => g.x1),
      bottom: glyphs.map(g => g.bottom), size: glyphs.map(g => g.size), font: glyphs.map(g => g.font), upright: glyphs.map(g => g.upright) },
    detections };
}

export const TAGGER: TaggerVocabulary = { font_vocab: { CMR: 2, CMMI: 7, CMSY: 8 }, font_prior: { CMR: 0.01, CMMI: 0.9, CMSY: 0.8 },
  char_vocab: { '120': 5 }, threshold: 0.7, max_len: 400, unknown_index: 0, default_prior: 0.04 };
const MATH = /CMMI|CMSY|CMEX|MSAM|MSBM|Math|rsfs|eufm|wasy|stmry|Symbol/i;
export const mathIDs = (vocab: TaggerVocabulary) => new Set(Object.entries(vocab.font_vocab).filter(([f]) => MATH.test(f)).map(([, i]) => i));
/** The recogniser stand-in: a crop is read by its size (both sides of the differential use this rule). */
export function recogniseRule(w: number, h: number): { latex: string; probs: number[] } {
  const k = (w * 7 + h * 13) % 11;
  return { latex: k === 0 ? '\\foo{x}' : `x_{${k}}`, probs: [0.70 + ((w * 31 + h * 17) % 30) / 100, 0.99, 0.93 + (k % 5) / 100].map(v => Number(v.toFixed(5))) };
}

export function png(width: number, height: number, seed = 0): string {
  const crc = (bytes: Uint8Array) => { let c = 0xffffffff; for (const b of bytes) { c ^= b; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0); } return (c ^ 0xffffffff) >>> 0; };
  const chunk = (name: string, body: Uint8Array) => {
    const out = new Uint8Array(body.length + 12), view = new DataView(out.buffer);
    view.setUint32(0, body.length); out.set([...name].map(c => c.charCodeAt(0)), 4); out.set(body, 8);
    view.setUint32(8 + body.length, crc(out.subarray(4, 8 + body.length))); return out;
  };
  const header = new Uint8Array(13), hv = new DataView(header.buffer); hv.setUint32(0, width); hv.setUint32(4, height); header[8] = 8; header[9] = 2;
  const rows = new Uint8Array((width * 3 + 1) * height).fill(255); for (let y = 0; y < height; y++) rows[y * (width * 3 + 1)] = 0;
  rows[1] = seed & 255; rows[2] = (seed >> 8) & 255; // distinct bytes per crop, so content addressing keeps them apart
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', zlibSync(rows)), chunk('IEND', new Uint8Array())];
  const all = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { all.set(p, at); at += p.length; }
  return encodeBase64(all);
}

export interface HostLog { tagCalls: number; taggedLines: number; recogniseCalls: number; images: { page: number; dpi: number; rect: number[] }[]; crops: { page: number; rect: number[] }[] }
export function host(pages: PageInput[], options: { vocab?: TaggerVocabulary; imageLimit?: number; failImages?: boolean; failRecognition?: boolean } = {}): DevicePDFHost & { log: HostLog } {
  const log: HostLog = { tagCalls: 0, taggedLines: 0, recogniseCalls: 0, images: [], crops: [] };
  const math = mathIDs(options.vocab ?? TAGGER);
  let distinct = 0;
  return {
    log,
    page: i => pages[i],
    tag: (ls: TagLine[]) => { log.tagCalls++; log.taggedLines += ls.length; return ls.map(l => l.font.map(f => math.has(f) ? 5 : -5)); },
    recognise: crops => {
      log.recogniseCalls++;
      if (options.failRecognition) throw new Error('model unavailable');
      return crops.map(c => { log.crops.push(c); return recogniseRule(c.rect[2] - c.rect[0], c.rect[3] - c.rect[1]); });
    },
    image: r => {
      log.images.push(r);
      if (options.failImages) throw new Error('no');
      const w = Math.max(1, Math.min(options.imageLimit ?? 48, r.rect[2] - r.rect[0])), h = Math.max(1, Math.min(options.imageLimit ?? 48, r.rect[3] - r.rect[1]));
      return { png: png(w, h, distinct++), width: w, height: h };
    },
  };
}

/** The stand-in PDF's identity: the bytes `%PDF-synthetic\n` the reference hashed when the fixture was recorded. */
export const PDF = { sha256: '819ece86bd7fa3b347ce703ffa0e46db34a28142381ce3b63befe5e7992f51b1', bytes: 15, name: 'synthetic.pdf' };
export function input(pages: number, extra: Partial<DevicePDFInput> = {}): DevicePDFInput {
  return { pdf: PDF, pages, models: [{ role: 'layout', id: 'layout-fcos-v5', sha256: 'b'.repeat(64) }], tagger: TAGGER, ...extra };
}

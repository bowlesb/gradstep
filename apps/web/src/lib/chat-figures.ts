// Figures in chat (docs/architecture/CHAT.md "Figures in chat"), the browser's port of ChatFigureFinder and
// ScienceReaderCore/ChatFigures.swift: a question that names a figure or table carries that figure's image from the
// open paper (consent cloud-ai-v3 names figures), and the answer may break it into parts the reader sees cropped.
// The stored form (`figure-parts-v1`) is the same JSON the apps keep, so either surface shows the other's answers.
import type { VerifiedBundle } from './bundle';

export const MAX_FIGURES = 2, MAX_SIDE = 1568, MAX_PIXELS = 1_150_000;

export interface ChatFigureImage {
  id: string; paragraph: number; caption: string; mediaType: 'image/jpeg' | 'image/png'; data: string; width: number; height: number;
  /** Kept on this device only: where the image is, so the answer's parts can be cropped from it later; a figure of
   * several panels has them all, sent as one image stacked (`composeFigure`). */
  blockID: string; assetPath: string; assetPaths: string[];
}
export interface FigurePart { label: string; box: [number, number, number, number]; note: string }
export interface FigureParts { figure: string; paragraph: number; title: string; parts: FigurePart[] }
export interface StoredFigureParts { manifestSHA256: string; blockID: string; assetPath: string; paragraph: number; title: string; parts: FigurePart[]; assetPaths?: string[] }
/** The images a stored figure's boxes refer to, in order. */
export const storedPaths = (s: StoredFigureParts): string[] => s.assetPaths && s.assetPaths.length > 1 ? s.assetPaths : [s.assetPath];

/** "figure 2", "table 1" named in the text, in order of first mention. */
export function figureMentions(text: string): { kind: 'figure' | 'table'; number: number }[] {
  const found: { kind: 'figure' | 'table'; number: number }[] = [];
  for (const m of text.matchAll(/\b(fig(?:ure)?s?\.?|tables?)\s*(\d{1,3})\b/gi)) {
    const kind = m[1].toLowerCase().startsWith('tab') ? 'table' : 'figure', number = Number(m[2]);
    if (!found.some(f => f.kind === kind && f.number === number)) found.push({ kind, number });
  }
  return found;
}

/** "Figure 4" or "Table 2" from a caption that starts with its number; null otherwise. */
export function figureLabel(caption: string): string | null {
  const m = /^\s*(figure|fig\.?|table)\s*(\d{1,3})\b/i.exec(caption);
  return m ? `${m[1].toLowerCase().startsWith('tab') ? 'Table' : 'Figure'} ${Number(m[2])}` : null;
}

/** The figure whose caption names it ("Figure 2:", "Fig. 2.", "Table 1:"). */
export function figureFor(mention: { kind: string; number: number }, index: VerifiedBundle['index']) {
  return index.figures.find(f => {
    const m = /^\s*(figure|fig\.?|table)\s*(\d{1,3})\b/i.exec(f.caption);
    return !!m && (m[1].toLowerCase().startsWith('tab') ? 'table' : 'figure') === mention.kind && Number(m[2]) === mention.number;
  });
}

const partValid = (p: unknown): p is FigurePart => {
  if (!p || typeof p !== 'object') return false;
  const v = p as Record<string, unknown>, box = v.box;
  return Array.isArray(box) && box.length === 4 && box.every(n => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1)
    && (box[2] as number) - (box[0] as number) >= 0.03 && (box[3] as number) - (box[1] as number) >= 0.03
    && typeof v.label === 'string' && v.label.length > 0 && [...v.label].length <= 60 && typeof v.note === 'string' && v.note.length > 0 && [...v.note].length <= 800;
};

/** The `figure_parts` event, or null when it is not usable (informational: never fatal). */
export function parseFigureParts(value: unknown): FigureParts | null {
  if (!value || typeof value !== 'object') return null;
  const v = value as Record<string, unknown>;
  if (typeof v.figure !== 'string' || !Number.isSafeInteger(v.paragraph) || typeof v.title !== 'string' || !v.title || [...v.title].length > 120
    || !Array.isArray(v.parts) || v.parts.length < 1 || v.parts.length > 8 || !v.parts.every(partValid)) return null;
  return { figure: v.figure, paragraph: v.paragraph as number, title: v.title,
    parts: (v.parts as FigurePart[]).map(p => ({ label: p.label, box: [p.box[0], p.box[1], p.box[2], p.box[3]], note: p.note })) };
}

/** As the apps encode it (sorted keys), so a diagram made here opens on iOS and the Mac. */
export function storedFigurePartsText(s: StoredFigureParts): string {
  return JSON.stringify({ assetPath: s.assetPath, ...(s.assetPaths && s.assetPaths.length > 1 ? { assetPaths: s.assetPaths } : {}), blockID: s.blockID,
    manifestSHA256: s.manifestSHA256, paragraph: s.paragraph, parts: s.parts.map(p => ({ box: p.box, label: p.label, note: p.note })), title: s.title });
}
export function decodeStoredFigureParts(text: string): StoredFigureParts | null {
  if (new TextEncoder().encode(text).length > 16_000) return null;
  try {
    const v = JSON.parse(text) as Record<string, unknown>;
    if (typeof v.manifestSHA256 !== 'string' || typeof v.blockID !== 'string' || typeof v.assetPath !== 'string' || !Number.isSafeInteger(v.paragraph)
      || typeof v.title !== 'string' || !Array.isArray(v.parts) || v.parts.length < 1 || v.parts.length > 8 || !v.parts.every(partValid)) return null;
    const paths = Array.isArray(v.assetPaths) && v.assetPaths.length > 1 && v.assetPaths.length <= 4 && v.assetPaths.every(p => typeof p === 'string') ? v.assetPaths as string[] : undefined;
    return { manifestSHA256: v.manifestSHA256, blockID: v.blockID, assetPath: v.assetPath, paragraph: v.paragraph as number, title: v.title,
      parts: v.parts as FigurePart[], ...(paths ? { assetPaths: paths } : {}) };
  } catch { return null; }
}

const base64 = (bytes: Uint8Array) => { let s = ''; for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192)); return btoa(s); };

export const MAX_PANELS = 4;
/** A figure's panels as one image, as the apps compose it (ChatFigureFinder.composite): each scaled to the widest
 * panel's width, top to bottom, 2 % of the width of white between them; the parts' boxes are fractions of it. */
export async function composeFigure(images: { bytes: Uint8Array; mediaType: string }[]): Promise<ImageBitmap | OffscreenCanvas | null> {
  try {
    const panels = await Promise.all(images.slice(0, MAX_PANELS).map(i => createImageBitmap(new Blob([i.bytes as BlobPart], { type: i.mediaType }))));
    if (panels.length === 1) return panels[0];
    const width = Math.max(...panels.map(p => p.width)), gap = Math.max(1, Math.round(width * 0.02));
    const heights = panels.map(p => Math.round(p.height * width / p.width)), height = heights.reduce((a, b) => a + b, 0) + gap * (panels.length - 1);
    if (!panels.length || width * height > 40_000_000) return null;
    const canvas = new OffscreenCanvas(width, height), ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, width, height);
    let top = 0;
    panels.forEach((p, i) => { ctx.drawImage(p, 0, top, width, heights[i]); top += heights[i] + gap; p.close(); });
    return canvas;
  } catch { return null; }
}

/** A figure as the model reads it best: scaled to the provider's resolution, JPEG on white (no transparency). */
export async function prepareFigure(bytes: Uint8Array, mediaType: string): Promise<{ data: string; width: number; height: number } | null> {
  try { return await prepareSource(await createImageBitmap(new Blob([bytes as BlobPart], { type: mediaType }))); } catch { return null; }
}
/** An image already shown on this page (a note snippet's decrypted crop), prepared as a figure is. */
export async function prepareImageURL(url: string): Promise<{ data: string; width: number; height: number } | null> {
  try { const img = new Image(); img.src = url; await img.decode(); return await prepareSource(await createImageBitmap(img)); } catch { return null; }
}
async function prepareSource(bitmap: ImageBitmap | OffscreenCanvas): Promise<{ data: string; width: number; height: number } | null> {
  try {
    const long = Math.max(bitmap.width, bitmap.height), short = Math.min(bitmap.width, bitmap.height);
    const limit = Math.min(MAX_SIDE, Math.sqrt(MAX_PIXELS * long / short), long), scale = limit / long;
    const w = Math.max(1, Math.round(bitmap.width * scale)), h = Math.max(1, Math.round(bitmap.height * scale));
    if (w < 8 || h < 8 || w > 1600 || h > 1600) return null;
    const canvas = new OffscreenCanvas(w, h), ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, w, h); ctx.drawImage(bitmap, 0, 0, w, h); if ('close' in bitmap) bitmap.close();
    const out = new Uint8Array(await (await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.85 })).arrayBuffer());
    return out.length <= 1_150_000 ? { data: base64(out), width: w, height: h } : null;
  } catch { return null; }
}

const mediaTypeOf = (bundle: VerifiedBundle, path: string) => bundle.manifest.members.find(m => m.path === path)?.media_type ?? 'image/png';

/** The images to send with a question, from the open paper's bundle (at most two figures). */
export async function chatFigureImages(question: string, selection: string | null, bundle: VerifiedBundle): Promise<ChatFigureImage[]> {
  const figures: VerifiedBundle['index']['figures'] = [];
  for (const mention of figureMentions([selection, question].filter(Boolean).join('\n'))) {
    const figure = figureFor(mention, bundle.index);
    if (!figure || figures.some(f => f.id === figure.id)) continue;
    figures.push(figure);
    if (figures.length === MAX_FIGURES) break;
  }
  const out: ChatFigureImage[] = [];
  for (const figure of figures) {
    const image = await figureImage(bundle, figure, `F${out.length + 1}`);
    if (image) out.push(image);
  }
  return out;
}

/** One figure of the open paper as a question carries it: a figure of several panels goes as one image, its panels
 * stacked (2610.19525's Figure 1, (a) and (b)); null when its image can't be prepared here. */
export async function figureImage(bundle: VerifiedBundle, figure: VerifiedBundle['index']['figures'][number], id = 'F1'): Promise<ChatFigureImage | null> {
  const paths = figure.asset_paths.slice(0, MAX_PANELS), path = paths[0];
  const panels = paths.map(p => ({ bytes: bundle.contents.get(p), mediaType: mediaTypeOf(bundle, p) }));
  const paragraph = bundle.index.blocks.findIndex(b => b.id === figure.block_id) + 1;
  if (!path || panels.some(p => !p.bytes) || paragraph < 1) return null;
  const source = panels.length > 1 ? await composeFigure(panels as { bytes: Uint8Array; mediaType: string }[]) : null;
  const prepared = panels.length > 1 ? (source ? await prepareSource(source) : null) : await prepareFigure(panels[0].bytes!, panels[0].mediaType);
  if (!prepared) return null;
  return { id, paragraph, caption: [...figure.caption].slice(0, 1200).join(''), mediaType: 'image/jpeg', ...prepared,
    blockID: figure.block_id, assetPath: path, assetPaths: paths };
}

// ---------- Where an answer's parts go (owner, 2026-10-15: "the crops should be inline") ----------
// `[[part N]]` lines mark where part N's crop sits in the answer, as FigurePartMarkers does in the apps. A marker is
// never shown as text: without its part the line is simply left out.
const MARKER = /^[ \t]*\[\[\s*part\s*(\d{1,2})\s*\]\][ \t]*/i;
export type PartSegment = { kind: 'text'; text: string } | { kind: 'part'; number: number };

export const hasPartMarkers = (text: string): boolean => text.split('\n').some(line => MARKER.test(line));

/** The answer in order: the text between markers and the parts they name (1…`parts`). */
export function partSegments(text: string, parts: number): PartSegment[] {
  const out: PartSegment[] = []; let buffer: string[] = [];
  const flush = () => { const joined = buffer.join('\n').trim(); if (joined) out.push({ kind: 'text', text: joined }); buffer = []; };
  for (const line of text.split('\n')) {
    const m = MARKER.exec(line);
    if (!m) { buffer.push(line); continue; }
    flush();
    const n = Number(m[1]);
    if (n >= 1 && n <= parts) out.push({ kind: 'part', number: n });
    const rest = line.slice(m[0].length);
    if (rest.trim()) buffer.push(rest);
  }
  flush();
  return out;
}

/** The text without its marker lines (and, while an answer streams, without a marker still arriving at its end). */
export function stripPartMarkers(text: string, streaming = false): string {
  const lines = text.split('\n').flatMap(line => { const m = MARKER.exec(line); if (!m) return [line]; const rest = line.slice(m[0].length); return rest.trim() ? [rest] : []; });
  if (streaming && lines.length && lines[lines.length - 1].trim().startsWith('[[') && !lines[lines.length - 1].includes(']]')) lines.pop();
  return lines.join('\n').replace(/\n{3,}/g, '\n\n');
}

// Builds the sandboxed reader document from a verified bundle
// (docs/architecture/BROWSER_READER.md#reader-frame).
import frame from 'virtual:reader-frame';
import { toBase64 } from '../lib/bytes';
import { MAXIMUM_READER_HEADINGS, type VerifiedBundle } from '../lib/bundle';
import { isUUID } from '../lib/bytes';
import type { Selection, SelectionPart } from '../lib/passage';

export const FRAME_SCRIPT_HASH = frame.hash;

const REMOVE = 'script,base,meta[http-equiv],iframe,frame,frameset,object,embed,applet,form,link,noscript,template,portal';

export interface FrameOptions { parentOrigin: string; paperLine?: string | null; paperTags?: string[] | { names: string[]; source: string } | null; paperAuthors?: string[]; figureID?: string; fontSize?: number; theme?: 'light' | 'dark' | null;
  /** The text column's measure (READING_MODE.md): comfortable, wide or full. */ lineWidth?: LineWidth }
import type { LineWidth } from './line-width';
export { LINE_WIDTHS, type LineWidth } from './line-width';

/** No bundle scripts, frames, forms or handlers, no script or data URLs; verified images inlined as data URIs. Shared
 * with the equation view's frame (equation-frame.ts). */
export function scrub(root: Document | Element, bundle: VerifiedBundle) {
  root.querySelectorAll(REMOVE).forEach(element => element.remove());
  for (const element of [...(root instanceof Element ? [root] : []), ...root.querySelectorAll('*')]) {
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase(), value = attribute.value.trim().toLowerCase();
      if (name.startsWith('on') || name === 'srcset' || name === 'formaction' || name === 'ping'
        || (['href', 'src', 'xlink:href', 'action', 'background', 'poster'].includes(name) && /^(javascript|vbscript|data):/.test(value.replace(/[\s\u0000-\u001f]/g, '')))) {
        element.removeAttribute(attribute.name);
      }
    }
  }
  const images = new Map(bundle.manifest.members.filter(m => m.role === 'image').map(m => [m.path, m]));
  for (const img of root.querySelectorAll('img')) {
    const member = images.get(img.getAttribute('src') ?? '');
    if (member) img.setAttribute('src', `data:${member.media_type};base64,${toBase64(bundle.contents.get(member.path)!)}`);
    else img.removeAttribute('src');
  }
}
/** The bundle's stylesheets in its own link order, then any remaining style members. */
export function bundleStyles(bundle: VerifiedBundle, hrefs: (string | null)[] = []): string[] {
  const styles = bundle.manifest.members.filter(m => m.role === 'style');
  const ordered = [...hrefs.map(href => styles.find(s => s.path === href)).filter(Boolean), ...styles.filter(s => !hrefs.includes(s.path))];
  return [...new Set(ordered)].map(member => new TextDecoder().decode(bundle.contents.get(member!.path)!));
}

/** The last framed bundle's document around its config block: parsing the paper, encoding every image and adding the
 * styles, CSP and frame script happen once per bundle; each figure or table view of the same paper (and every ←/→ step)
 * only adds its own config (C4). One paper at a time, so at most one extra copy is held. */
let template: { bundle: VerifiedBundle; before: string; after: string } | null = null;
function documentTemplate(bundle: VerifiedBundle): { before: string; after: string } {
  if (template?.bundle === bundle) return template;
  const html = new TextDecoder().decode(bundle.contents.get(bundle.manifest.entrypoint)!);
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const stylesheetHrefs = [...doc.querySelectorAll('link[rel~="stylesheet"]')].map(l => l.getAttribute('href'));
  scrub(doc, bundle);
  const head = doc.head;
  const csp = doc.createElement('meta');
  csp.setAttribute('http-equiv', 'Content-Security-Policy');
  csp.setAttribute('content', `default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src '${frame.hash}'; base-uri 'none'; form-action 'none'; connect-src 'none'; frame-src 'none'; font-src 'none'`);
  head.prepend(csp);
  for (const text of bundleStyles(bundle, stylesheetHrefs)) {
    const style = doc.createElement('style');
    style.textContent = text;
    head.append(style);
  }
  const configBlock = doc.createElement('script');
  configBlock.setAttribute('type', 'application/json');
  configBlock.setAttribute('data-gradstep-config', '');
  // A script's text is serialized as is, so the config can take this marker's place exactly.
  const marker = `gradstep-frame-config-${crypto.randomUUID()}`;
  configBlock.textContent = marker;
  const script = doc.createElement('script');
  script.textContent = frame.script;
  doc.body.append(configBlock, script);
  const parts = ('<!doctype html>\n' + doc.documentElement.outerHTML).split(marker);
  if (parts.length !== 2) throw new Error('frame_template');
  template = { bundle, before: parts[0], after: parts[1] };
  return template;
}

/** The bundle's HTML with app-owned presentation: no bundle scripts, inlined styles, verified images as data URIs. */
export function frameDocument(bundle: VerifiedBundle, options: FrameOptions): string {
  const { before, after } = documentTemplate(bundle);
  const config = {
    parent_origin: options.parentOrigin, paper_line: options.paperLine ?? null, paper_tags: options.paperTags ?? null, paper_authors: options.paperAuthors ?? [], font_size: options.fontSize ?? null, theme: options.theme ?? null, line_width: options.lineWidth ?? null,
    bundle: { ...bundle.index, manifest_sha256: bundle.manifestSHA256, ...(options.figureID ? { figure_id: options.figureID } : {}) },
  };
  // `<` escaped so no text in the index can end the data block.
  return before + JSON.stringify(config).replace(/</g, '\\u003c') + after;
}

/** Messages from the frame, validated with the native coordinator's bounds. */
export type FrameMessage =
  | { type: 'headings'; items: { id: string; title: string; depth?: number }[] }
  | { type: 'position'; block: number; fraction: number; height: number; y: number; progress: number }
  /** After a jump: `back` is whether Back is offered (not after a chat jump that began at the top), `from` the
   * section left ("3 Method"), empty when the bridge doesn't know it (PaperView's citation Back). */
  | { type: 'citation'; state: 'jumped' | 'ended'; back: boolean; from: string }
  | { type: 'selection'; empty: boolean; selection: Selection | null }
  | { type: 'marks'; ids: string[] } | { type: 'passage'; found: boolean }
  | { type: 'reference'; reference: ReaderReference } | { type: 'figureref'; reference: ReaderFigureReference }
  | { type: 'author'; name: string } | { type: 'figure'; id: string } | { type: 'tags' } | { type: 'contentsGesture' } | { type: 'invalid' }
  | { type: 'find'; count: number; index: number; matches: { index: number; text: string }[] }
  | { type: 'key'; key: FrameKey }
  /** A link out of the paper the reader clicked (frame-shim.js): opened in a new tab, never in the frame. */
  | { type: 'link'; url: string }
  /** Notes: a region or element made into a PNG inside the frame (frame-shim.js). `box` is in the frame's CSS px. */
  | { type: 'capture'; nonce: string; ok: true; png: ArrayBuffer; width: number; height: number; blocks: string[]; box: [number, number, number, number]; viewport: [number, number, number] }
  | { type: 'capture'; nonce: string; ok: false; reason: string }
  | { type: 'captureProbe'; nonce: string; ok: boolean };

/** App shortcuts typed while the paper frame has focus (forwarded by the frame shim). */
export type FrameKey = 'find' | 'search' | 'escape' | 'left' | 'right' | 'help' | 'reading' | 'next' | 'previous';
const FRAME_KEYS: readonly FrameKey[] = ['find', 'search', 'escape', 'left', 'right', 'help', 'reading', 'next', 'previous'];

export function readFrameMessage(value: unknown, bundle?: VerifiedBundle): FrameMessage | null {
  const v = value as Record<string, unknown>;
  if (!v || typeof v !== 'object' || typeof v.type !== 'string') return null;
  const finite = (x: unknown) => typeof x === 'number' && Number.isFinite(x);
  switch (v.type) {
    case 'author': return typeof v.name === 'string' && v.name.length > 1 && v.name.length <= 256 ? { type: 'author', name: v.name } : null;
    case 'headings':
      if (!Array.isArray(v.items) || v.items.length > MAXIMUM_READER_HEADINGS) return null;
      return { type: 'headings', items: (v.items as { id?: unknown; title?: unknown; depth?: unknown }[]).filter(i => typeof i?.id === 'string' && i.id && i.id.length <= 2048
        && typeof i.title === 'string' && i.title && i.title.length <= 8000).map(i => ({ id: i.id as string, title: i.title as string,
        depth: Number.isInteger(i.depth) && (i.depth as number) >= 0 && (i.depth as number) <= 3 ? i.depth as number : undefined })) };
    case 'position':
      return [v.block, v.fraction, v.height, v.y, v.progress].every(finite) && Number.isInteger(v.block)
        ? { type: 'position', block: v.block as number, fraction: v.fraction as number, height: v.height as number, y: v.y as number, progress: Math.min(1, Math.max(0, v.progress as number)) } : null;
    case 'citation': {
      if (v.state !== 'jumped' && v.state !== 'ended') return null;
      // An older bridge names neither: Back is offered, with no section.
      const from = typeof v.from === 'string' ? [...v.from.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim()].slice(0, 60).join('') : '';
      return { type: 'citation', state: v.state, back: v.state === 'jumped' && v.back !== false, from };
    }
    case 'selection': {
      const raw = v.selection as { manifest_sha256?: unknown; parts?: unknown; context?: unknown } | undefined;
      const parts = raw?.parts;
      if (!Array.isArray(parts) || parts.length === 0) return { type: 'selection', empty: true, selection: null };
      return { type: 'selection', empty: false, selection: readSelection(raw!) };
    }
    case 'marks': return Array.isArray(v.ids) && v.ids.length >= 1 && v.ids.length <= 50 && v.ids.every(isUUID)
      ? { type: 'marks', ids: [...new Set((v.ids as string[]).map(id => id.toLowerCase()))] } : null;
    case 'passage': return typeof v.found === 'boolean' ? { type: 'passage', found: v.found } : null;
    case 'reference': {
      const reference = bundle && readReference(v, bundle);
      return reference ? { type: 'reference', reference } : null;
    }
    case 'figureref': {
      const reference = bundle && readFigureReference(v, bundle);
      return reference ? { type: 'figureref', reference } : null;
    }
    case 'figure': return typeof v.id === 'string' && /^[0-9A-Za-z_-]{1,200}$/.test(v.id) ? { type: 'figure', id: v.id } : null;
    case 'tags': return { type: 'tags' };
    case 'contentsGesture': return bundle && v.manifest_sha256 === bundle.manifestSHA256 ? { type: 'contentsGesture' } : null;
    case 'invalid': return { type: 'invalid' };
    case 'find': {
      const count = v.count, index = v.index;
      return Number.isInteger(count) && Number.isInteger(index) && (count as number) >= 0 && (count as number) <= 1000 && (index as number) >= -1 && (index as number) < Math.max(1, count as number)
        ? { type: 'find', count: count as number, index: count === 0 ? -1 : index as number, matches: Array.isArray(v.matches) ? v.matches.slice(0,1000).flatMap((m: unknown) => {
          if (!m || typeof m !== 'object') return []; const row = m as Record<string,unknown>;
          return Number.isInteger(row.index) && Number(row.index)>=0 && Number(row.index)<Number(count) && typeof row.text==='string' && row.text.length<=205 ? [{index:Number(row.index),text:row.text}] : [];
        }) : [] } : null;
    }
    case 'key': return FRAME_KEYS.includes(v.key as FrameKey) ? { type: 'key', key: v.key as FrameKey } : null;
    case 'link': { const url = typeof v.url === 'string' ? outboundLink(v.url) : null; return url ? { type: 'link', url } : null; }
    case 'captureProbe': return typeof v.nonce === 'string' && isUUID(v.nonce) && typeof v.ok === 'boolean' ? { type: 'captureProbe', nonce: v.nonce.toLowerCase(), ok: v.ok } : null;
    case 'capture': {
      if (typeof v.nonce !== 'string' || !isUUID(v.nonce)) return null;
      const nonce = v.nonce.toLowerCase();
      if (v.ok !== true) return { type: 'capture', nonce, ok: false, reason: typeof v.reason === 'string' && /^[a-z_]{1,24}$/.test(v.reason) ? v.reason : 'failed' };
      const int = (x: unknown, hi: number) => Number.isInteger(x) && (x as number) >= 1 && (x as number) <= hi;
      const box = v.box, viewport = v.viewport;
      // Bounded before anything decodes it: a PNG of at most 4,096 px a side and 6 MP (frame-shim.js), a few known blocks.
      if (!(v.png instanceof ArrayBuffer) || v.png.byteLength < 8 || v.png.byteLength > 48 * 1024 * 1024 || !int(v.width, 4096) || !int(v.height, 4096)
        || (v.width as number) * (v.height as number) > 6_000_000 || !Array.isArray(v.blocks) || v.blocks.length > 64 || !v.blocks.every(b => typeof b === 'string' && ID.test(b))
        || !Array.isArray(box) || box.length !== 4 || !box.every(finite) || !Array.isArray(viewport) || viewport.length !== 3 || !viewport.every(n => finite(n) && (n as number) > 0 && (n as number) < 100_000)
        || (bundle && v.manifest_sha256 !== bundle.manifestSHA256)) return { type: 'capture', nonce, ok: false, reason: 'invalid' };
      return { type: 'capture', nonce, ok: true, png: v.png, width: v.width as number, height: v.height as number, blocks: v.blocks as string[],
        box: box as [number, number, number, number], viewport: viewport as [number, number, number] };
    }
  }
  return null;
}

/** A paper's own link out (the apps open only https in Safari): http becomes https, no credentials, bounded. */
export function outboundLink(raw: string): string | null {
  if (raw.length > 4096 || /[\u0000-\u0020\u007f]/.test(raw)) return null;
  try {
    const url = new URL(raw);
    if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || !url.hostname) return null;
    url.protocol = 'https:';
    return url.href;
  } catch { return null; }
}

const ID = /^[0-9A-Za-z_-]{1,200}$/;
const textBytes = (s: string) => new TextEncoder().encode(s).length;
/** A selection with the native bounds; anything out of bounds is no selection (the actions don't show). */
function readSelection(raw: { manifest_sha256?: unknown; parts?: unknown; context?: unknown }): Selection | null {
  const parts = raw.parts as Record<string, unknown>[];
  if (typeof raw.manifest_sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(raw.manifest_sha256) || parts.length > 512) return null;
  const out: SelectionPart[] = [];
  for (const p of parts) {
    if (!p || typeof p.block_id !== 'string' || !ID.test(p.block_id)) return null;
    if (p.kind === 'text' && typeof p.text === 'string' && textBytes(p.text) <= 20_000 && p.equation_id === undefined) out.push({ kind: 'text', blockID: p.block_id, text: p.text });
    else if (p.kind === 'equation' && typeof p.equation_id === 'string' && ID.test(p.equation_id) && p.text === undefined) out.push({ kind: 'equation', blockID: p.block_id, equationID: p.equation_id });
    else return null;
  }
  const c = raw.context as { prefix?: unknown; suffix?: unknown } | null | undefined;
  const context = c && typeof c.prefix === 'string' && typeof c.suffix === 'string' && textBytes(c.prefix) <= 4000 && textBytes(c.suffix) <= 4000 ? { prefix: c.prefix, suffix: c.suffix } : null;
  return { manifest: raw.manifest_sha256, parts: out, context };
}


export interface ReaderReference {
  blockID: string; text: string; link: { url: string; title: string } | null;
  rect: { x: number; y: number; width: number; height: number } | null;
}
export interface ReaderFigureReference { id: string; label: string; goTitle: string }

/** Native ReaderReference's destination order: arXiv, DOI, then a safe HTTPS link. */
export function referenceLink(text: string, hrefs: readonly string[]): ReaderReference['link'] {
  if (/arxiv|corr/i.test(text)) {
    for (const match of text.matchAll(/(?<![\d.])(\d{2})(\d{2})\.(\d{4,5})(v\d{1,3})?(?!\d)/g)) {
      if (Number(match[1]) >= 7 && Number(match[2]) >= 1 && Number(match[2]) <= 12) return { url: `https://arxiv.org/abs/${match[0]}`, title: 'Open on arXiv' };
    }
  }
  const doi = text.match(/\b10\.\d{4,9}\/[^\s"<>]+/);
  if (doi) {
    let value = doi[0];
    while (/[.,;:\]]$/.test(value) || (value.endsWith(')') && (value.match(/\(/g)?.length ?? 0) < (value.match(/\)/g)?.length ?? 0))) value = value.slice(0, -1);
    return { url: `https://doi.org/${value.split('/').map(encodeURIComponent).join('/')}`, title: 'Open DOI' };
  }
  for (const raw of [...hrefs.slice(0, 8), ...text.matchAll(/https:\/\/[^\s<>"]+/g)].map(v => typeof v === 'string' ? v : v[0])) {
    if (raw.length > 4096) continue;
    try {
      const url = new URL(raw.replace(/[.,;:)\]]+$/, ''));
      if (url.protocol === 'https:' && url.hostname && !url.username && !url.password) return { url: url.href, title: 'Open link' };
    } catch { /* not a destination */ }
  }
  return null;
}

function readReference(v: Record<string, unknown>, bundle: VerifiedBundle): ReaderReference | null {
  if (v.manifest_sha256 !== bundle.manifestSHA256 || typeof v.block_id !== 'string' || !bundle.index.blocks.some(b => b.id === v.block_id)
    || typeof v.text !== 'string' || textBytes(v.text) > 16_000) return null;
  const text = v.text.replace(/\s+/g, ' ').trim();
  if (!text) return null;
  const r = v.rect as Record<string, unknown> | null;
  const rect = r && ['x', 'y', 'width', 'height'].every(k => typeof r[k] === 'number' && Number.isFinite(r[k]))
    ? { x: r.x as number, y: r.y as number, width: Math.max(1, r.width as number), height: Math.max(1, r.height as number) } : null;
  const hrefs = Array.isArray(v.links) ? v.links.slice(0, 8).filter((x): x is string => typeof x === 'string') : [];
  return { blockID: v.block_id, text, rect, link: referenceLink(text, hrefs) };
}
function readFigureReference(v: Record<string, unknown>, bundle: VerifiedBundle): ReaderFigureReference | null {
  if (v.manifest_sha256 !== bundle.manifestSHA256 || typeof v.id !== 'string' || typeof v.label !== 'string'
    || !/^(?:Figure|Table|Algorithm) [A-Z0-9][A-Za-z0-9.]{0,9}$/.test(v.label)
    || !(bundle.index.figures.some(f => f.id === v.id) || bundle.index.blocks.some(b => b.id === v.id && ['table', 'code'].includes(b.kind)))) return null;
  return { id: v.id, label: v.label, goTitle: v.label.startsWith('Table') ? 'Go to table' : v.label.startsWith('Algorithm') ? 'Go to algorithm' : 'Go to figure' };
}

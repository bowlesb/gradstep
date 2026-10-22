// Download your assets (owner, build 82: "Need a download assets button"): the reader's own content as one .zip, put
// together on this device from what it holds or can decrypt; nothing is sent anywhere. Downloaded papers are left out
// (they are the publishers' content). Swift's AssetsExport.swift builds the same files and the same zip byte for byte
// from the same input (tests/fixtures/assets-export.json), so every rule here is written to be repeatable: dates in UTC,
// names cleaned by an explicit character list, files ordered by their UTF-8 bytes, stored (uncompressed) zip entries.
import { utf8, type Bytes } from './bytes';

export const EXPORT_FORMAT = 'gradstep-export-v1';

export interface ExportMessage { role: 'user' | 'assistant'; text: string; at?: number; model?: string; interrupted?: boolean }
export interface ExportChat { id: string; title: string; paper?: string; startedAt?: number; passage?: string; versions?: number; messages: ExportMessage[] }
export interface ExportDiagram { id: string; title: string; format: string; source: string; at?: number; chat?: string }
export interface ExportSnippetSource { title: string; section?: string; label?: string; url?: string; page?: number }
export interface ExportSnippet {
  id: string; kind: 'region' | 'quote' | 'text'; at: number; comment: string; quote?: string; source?: ExportSnippetSource;
  /** The snippet has an image of this type; its bytes are passed separately (missing bytes: left out and said so). */
  image?: 'image/png' | 'image/jpeg';
}
export interface ExportCollection { id: string; title: string; snippets: ExportSnippet[] }
export interface ExportItem { name: string; line: string; paragraphs: number[] }
export interface ExportExplanation {
  kind: 'equation' | 'figure' | 'paper'; action: string; paper: string; label: string; at: number; model?: string;
  summary?: string;
  symbols?: { symbol: string; latex?: string; meaning: string; source: string; paragraph?: number }[];
  sections?: { name: string; title: string; text: string; paragraphs: number[] }[];
  background?: ExportItem[]; ideas?: ExportItem[]; links?: { from: string; to: string; label: string }[];
  text: string;
}
export interface ExportInput {
  exportedAt: number; chats: ExportChat[]; diagrams: ExportDiagram[]; collections: ExportCollection[]; explanations: ExportExplanation[];
  /** What the device couldn't read, in the device's own words (each a sentence). */
  skipped: string[];
}
export interface ExportFile { path: string; data: Bytes }
export interface ExportResult { root: string; files: ExportFile[]; skipped: string[]; fileName: string }

// ---------- Names and text ----------

const PATH_CHARACTERS = new Set(['/', '\\', ':', '*', '?', '"', '<', '>', '|']);
const SPACES = new Set([0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
  0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000]);
const isControl = (c: string) => /^[\p{Cc}\p{Cf}]$/u.test(c);

/** One line: control and format characters (and, for a file name, path characters) become spaces; runs of spaces become
 * one; trimmed. Counted in Unicode scalars, as Swift's `unicodeScalars`. */
function line(text: string, path = false): string {
  let out = '', space = false;
  for (const c of text.normalize('NFC')) {
    const blank = SPACES.has(c.codePointAt(0)!) || isControl(c) || (path && PATH_CHARACTERS.has(c));
    if (blank) { space = out.length > 0; continue; }
    if (space) { out += ' '; space = false; }
    out += c;
  }
  return out;
}
const scalars = (text: string) => [...text];
function clip(text: string, limit: number): string {
  const all = scalars(text);
  return all.length <= limit ? text : all.slice(0, limit - 1).join('').trimEnd() + '…';
}

/** A file name from a title: one line, no path characters, no leading dots, at most `limit` scalars. */
export function fileName(title: string, limit = 60, fallback = 'Untitled'): string {
  let name = line(title, true).replace(/^[. ]+/, '');
  const all = scalars(name);
  if (all.length > limit) name = all.slice(0, limit).join('');
  name = name.replace(/[ .]+$/, '');
  return name || fallback;
}

const pad = (n: number, width = 2) => String(n).padStart(width, '0');
/** `2026-10-22` (UTC). */
export function day(ms: number): string { const d = new Date(ms); return `${pad(d.getUTCFullYear(), 4)}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`; }
/** `2026-10-22 14:03 UTC`. */
export function stamp(ms: number): string { const d = new Date(ms); return `${day(ms)} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} UTC`; }

const quoteBlock = (text: string) => text.replace(/\r\n?/g, '\n').split('\n').map(l => (l.trim() ? `> ${l}` : '>')).join('\n');
const escapeHTML = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const link = (title: string, path: string) => `- [${line(title).replace(/[[\]]/g, '')}](<${path}>)`;
const paragraphs = (list: readonly number[]) => list.length ? ` (${list.map(n => `¶${n}`).join(', ')})` : '';
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
const byBytes = (a: string, b: string) => {
  const x = utf8(a), y = utf8(b);
  for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i]! - y[i]!;
  return x.length - y.length;
};

// ---------- The files ----------

function chatMarkdown(c: ExportChat): string {
  const facts = [
    c.paper ? `- Paper: ${line(c.paper)}` : '',
    c.startedAt !== undefined ? `- Started: ${stamp(c.startedAt)}` : '',
    c.passage ? `- Passage: “${clip(line(c.passage), 300)}”` : '',
    c.versions && c.versions > 1 ? `- This chat has ${c.versions} versions; this is the most recent.` : '',
  ].filter(Boolean);
  const turns = c.messages.map(m => {
    const who = [m.role === 'user' ? '**You**' : '**AI**', m.role === 'assistant' && m.model ? line(m.model) : '', m.at !== undefined ? stamp(m.at) : '']
      .filter(Boolean).join(' · ');
    return `${who}${m.interrupted ? ' (stopped early)' : ''}\n\n${m.text.trim()}`;
  });
  return [`# ${line(c.title) || 'Untitled chat'}`, facts.join('\n'), '---', ...turns].filter(Boolean).join('\n\n') + '\n';
}

const KIND_LABEL: Record<ExportSnippet['kind'], string> = { region: 'Region', quote: 'Quote', text: 'Note' };
function snippetMarkdown(c: ExportCollection, images: ReadonlyMap<string, string>): string {
  const entries = c.snippets.map(s => {
    const parts = [`## ${stamp(s.at)} · ${KIND_LABEL[s.kind]}`];
    if (s.quote?.trim()) parts.push(quoteBlock(s.quote.trim()));
    const image = images.get(s.id);
    if (image) parts.push(`![Snippet](<images/${image}>)`);
    else if (s.image) parts.push('_The image wasn’t available on this device._');
    if (s.comment.trim()) parts.push(s.comment.trim());
    if (s.source) {
      const src = s.source;
      parts.push(`Source: ${[line(src.title), src.section ? line(src.section) : '', src.label ? line(src.label) : '', src.page ? `page ${src.page}` : '', src.url ?? '']
        .filter(Boolean).join(' — ')}`);
    }
    return parts.join('\n\n');
  });
  return [`# ${line(c.title) || 'Untitled collection'}`, ...entries].join('\n\n') + '\n';
}

const SUFFIX: Record<string, string> = { equation_background: ' (background)', figure_simpler: ' (more simply)' };
function explanationMarkdown(e: ExportExplanation): string {
  const facts = [`- Paper: ${line(e.paper) || 'Unknown paper'}`, `- Saved: ${stamp(e.at)}`, e.model ? `- Model: ${line(e.model)}` : ''].filter(Boolean).join('\n');
  const out = [`# ${line(e.label) || 'Explanation'}${SUFFIX[e.action] ?? ''}`, facts];
  if (e.kind === 'paper') {
    if (e.summary) out.push('## In short', e.summary.trim());
    const items = (list: ExportItem[]) => list.map(i => `- **${line(i.name)}**${i.line ? `: ${line(i.line)}` : ''}${paragraphs(i.paragraphs)}`).join('\n');
    if (e.background?.length) out.push('## Background', items(e.background));
    if (e.ideas?.length) out.push('## Key ideas', items(e.ideas));
    if (e.links?.length) out.push('## How it fits together', e.links.map(l => `- ${line(l.from)} → ${line(l.to)}${l.label ? `: ${line(l.label)}` : ''}`).join('\n'));
  } else {
    if (e.summary) out.push(e.summary.trim());
    if (e.symbols?.length) out.push('## Symbols', e.symbols.map(s => `- **${line(s.symbol)}**${s.latex ? ` \`${line(s.latex).replace(/`/g, "'")}\`` : ''}: ${line(s.meaning)}`
      + (s.paragraph ? ` (¶${s.paragraph})` : s.source === 'general' ? ' (general knowledge)' : '')).join('\n'));
    for (const s of e.sections ?? []) {
      const heading = s.title && s.title !== s.name ? `${line(s.name)}: ${line(s.title)}` : line(s.name || s.title);
      out.push(`## ${heading}`, s.text.trim() + paragraphs(s.paragraphs));
    }
  }
  if (e.text.trim()) out.push(e.text.trim());
  return out.filter(Boolean).join('\n\n') + '\n';
}

function diagramFile(d: ExportDiagram): { ext: string; text: string } {
  if (d.format === 'html-v1') {
    return { ext: 'html', text: `<!doctype html>\n<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">`
      + `<title>${escapeHTML(line(d.title))}</title></head>\n<body>\n${d.source.trim()}\n</body></html>\n` };
  }
  const header = [`%% ${line(d.title)}`, d.chat ? `%% From the chat “${line(d.chat)}”` : ''].filter(Boolean).join('\n');
  return { ext: 'mmd', text: `${header}\n${d.source.trim()}\n` };
}

/** Every file of the export, under one folder named for the day, with README.md first. `images`: snippet images by
 * snippet id (decrypted on this device). */
export function buildExport(input: ExportInput, images: ReadonlyMap<string, Uint8Array>): ExportResult {
  const root = `Gradstep export ${day(input.exportedAt)}`;
  const used = new Set<string>(), files: ExportFile[] = [];
  const claim = (folder: string, name: string, ext: string) => {
    let path = `${folder}/${name}.${ext}`;
    for (let n = 2; used.has(path.toLowerCase()); n++) path = `${folder}/${name} ${n}.${ext}`;
    used.add(path.toLowerCase());
    return path;
  };
  const add = (path: string, data: Uint8Array | string) => files.push({ path, data: (typeof data === 'string' ? utf8(data) : data) as Bytes });
  const listed: Record<string, string[]> = { chats: [], diagrams: [], snippets: [], equation: [], figure: [], paper: [] };
  const skipped: string[] = [];
  const order = <T extends { id?: string }>(at: (t: T) => number | undefined) => (a: T, b: T) =>
    ((at(a) ?? -1) - (at(b) ?? -1)) || byBytes(a.id ?? '', b.id ?? '');

  const chats = [...input.chats].filter(c => c.messages.length).sort(order(c => c.startedAt));
  for (const c of chats) {
    const name = fileName(c.title, 60, 'Untitled chat');
    const path = claim('chats', c.startedAt !== undefined ? `${day(c.startedAt)} ${name}` : name, 'md');
    add(path, chatMarkdown(c)); listed.chats.push(link(c.title || 'Untitled chat', path));
  }

  let breakdowns = 0;
  for (const d of [...input.diagrams].sort(order(d => d.at))) {
    if (d.format !== 'mermaid-v1' && d.format !== 'html-v1') { breakdowns++; continue; }
    const file = diagramFile(d), name = fileName(d.title, 60, 'Diagram');
    const path = claim('diagrams', d.at !== undefined ? `${day(d.at)} ${name}` : name, file.ext);
    add(path, file.text); listed.diagrams.push(link(d.title || 'Diagram', path));
  }
  if (breakdowns) skipped.push(`${plural(breakdowns, 'figure breakdown', 'figure breakdowns')} from chats ${breakdowns === 1 ? 'isn’t' : 'aren’t'} included: ${breakdowns === 1 ? 'it is' : 'they are'} cut from the paper itself.`);

  let snippetCount = 0;
  const collections = [...input.collections].sort((a, b) => byBytes(line(a.title), line(b.title)) || byBytes(a.id, b.id));
  for (const c of collections) {
    const snippets = [...c.snippets].sort(order(s => s.at));
    const names = new Map<string, string>();
    let missing = 0;
    for (const s of snippets) {
      if (!s.image) continue;
      const bytes = images.get(s.id);
      if (!bytes) { missing++; continue; }
      const imagePath = claim('snippets/images', s.id, s.image === 'image/png' ? 'png' : 'jpg');
      add(imagePath, bytes); names.set(s.id, imagePath.slice('snippets/images/'.length));
    }
    const path = claim('snippets', fileName(c.title, 60, 'Untitled collection'), 'md');
    add(path, snippetMarkdown({ ...c, snippets }, names)); listed.snippets.push(link(c.title || 'Untitled collection', path));
    snippetCount += snippets.length;
    const title = line(c.title) || 'Untitled collection';
    if (missing) skipped.push(missing === 1 ? `An image in “${title}” wasn’t available on this device.` : `${missing} images in “${title}” weren’t available on this device.`);
  }

  const kinds = { equation: 0, figure: 1, paper: 2 } as const;
  const explanations = [...input.explanations].sort((a, b) => (kinds[a.kind] - kinds[b.kind]) || byBytes(line(a.paper), line(b.paper))
    || byBytes(line(a.label), line(b.label)) || byBytes(a.action, b.action) || a.at - b.at);
  const folders = { equation: 'explanations/equations', figure: 'explanations/figures', paper: 'explanations/papers' } as const;
  for (const e of explanations) {
    const paper = fileName(e.paper, 50, 'Unknown paper');
    const name = e.kind === 'paper' ? paper : `${paper} – ${fileName(e.label + (SUFFIX[e.action] ?? ''), 40, 'Explanation')}`;
    const path = claim(folders[e.kind], name, 'md');
    add(path, explanationMarkdown(e));
    listed[e.kind].push(link(e.kind === 'paper' ? line(e.paper) || 'Unknown paper' : `${line(e.paper) || 'Unknown paper'} – ${line(e.label)}${SUFFIX[e.action] ?? ''}`, path));
  }
  skipped.push(...input.skipped.map(s => line(s)).filter(Boolean));

  const count = (kind: ExportExplanation['kind']) => input.explanations.filter(e => e.kind === kind).length;
  const readme = [
    '# Gradstep export',
    `Exported ${stamp(input.exportedAt)}. Everything here was put together on this device from your own content.`,
    [`- Chats: ${chats.length}`, `- Diagrams: ${listed.diagrams.length}`,
      `- Snippets: ${snippetCount} in ${plural(collections.length, 'collection', 'collections')}`,
      `- Equation explanations: ${count('equation')}`, `- Figure explanations: ${count('figure')}`, `- Paper explanations: ${count('paper')}`].join('\n'),
    'Downloaded papers aren’t included: get them again from each paper’s source. Explanations are kept on each device, so these are the ones kept on this one.',
    skipped.length ? `## Left out\n\n${skipped.map(s => `- ${s}`).join('\n')}` : '',
    ...([['Chats', listed.chats], ['Diagrams', listed.diagrams], ['Snippets', listed.snippets], ['Equation explanations', listed.equation],
      ['Figure explanations', listed.figure], ['Paper explanations', listed.paper]] as const)
      .filter(([, l]) => l.length).map(([title, l]) => `## ${title}\n\n${l.join('\n')}`),
  ].filter(Boolean).join('\n\n') + '\n';

  const ordered = files.sort((a, b) => byBytes(a.path, b.path));
  return {
    root, fileName: `${root}.zip`, skipped,
    files: [{ path: `${root}/README.md`, data: utf8(readme) }, ...ordered.map(f => ({ path: `${root}/${f.path}`, data: f.data }))],
  };
}

// ---------- The zip (stored entries, UTF-8 names, one fixed time) ----------

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; table[n] = c >>> 0; }
  return table;
})();
export function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]!) & 255]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** A zip of the files in the order given: stored (no compression), names flagged UTF-8, every entry dated `at` (UTC, to
 * two seconds). Throws past the plain zip format's limits (4 GB, 65,535 entries). */
export function zip(files: readonly ExportFile[], at: number): Bytes {
  const d = new Date(at);
  const time = (d.getUTCHours() << 11) | (d.getUTCMinutes() << 5) | Math.floor(d.getUTCSeconds() / 2);
  const date = ((Math.max(1980, d.getUTCFullYear()) - 1980) << 9) | ((d.getUTCMonth() + 1) << 5) | d.getUTCDate();
  const total = files.reduce((n, f) => n + 76 + 2 * utf8(f.path).length + f.data.length, 22);
  if (files.length > 0xffff || total > 0xffffffff) throw new Error('export_too_large');
  const out = new Uint8Array(total), view = new DataView(out.buffer);
  let pos = 0;
  const u16 = (v: number) => { view.setUint16(pos, v, true); pos += 2; };
  const u32 = (v: number) => { view.setUint32(pos, v >>> 0, true); pos += 4; };
  const put = (b: Uint8Array) => { out.set(b, pos); pos += b.length; };
  const central: { name: Uint8Array; crc: number; size: number; offset: number }[] = [];
  for (const f of files) {
    const name = utf8(f.path), crc = crc32(f.data), offset = pos;
    u32(0x04034b50); u16(10); u16(0x0800); u16(0); u16(time); u16(date); u32(crc); u32(f.data.length); u32(f.data.length); u16(name.length); u16(0);
    put(name); put(f.data);
    central.push({ name, crc, size: f.data.length, offset });
  }
  const start = pos;
  for (const c of central) {
    u32(0x02014b50); u16(20); u16(10); u16(0x0800); u16(0); u16(time); u16(date); u32(c.crc); u32(c.size); u32(c.size);
    u16(c.name.length); u16(0); u16(0); u16(0); u16(0); u32(0); u32(c.offset); put(c.name);
  }
  const size = pos - start;
  u32(0x06054b50); u16(0); u16(0); u16(central.length); u16(central.length); u32(size); u32(start); u16(0);
  return out as Bytes;
}

// The reading pass (device_pdf.Converter.convert and _float), ported rule for rule. It produces the logical
// blocks in the reference's order, the reference's own index (`trace`, for bundle_conformance.py) and the
// formulas with their crops; `emit.ts` turns the logical blocks into this reader's vocabulary.
import { check, fail, sha256Hex, utf8 } from '../util.ts';
import { assign, byX, canonicalText, centreIn, clipBytes, growLines, joinLines, lineText, linesOf, median, orphanRegions,
  pyRound, recogniserRect, union, visible } from './geometry.ts';
import { confidence, renderMath } from './math.ts';
import { furniture, isFrontMatter, isFurniture, marginGlyphLines, structure } from './structure.ts';
import { cellSpanOk, tableCells, type Cell } from './tables.ts';
import { spansOf, tagInput } from './tagger.ts';
import { BLOCK_TEXT_CHUNK, CROP_MARGIN, DEVICE_PDF_CONVERTER_VERSION, DEVICE_PDF_RENDERER_ID, DPI, GATE, GATE_DISPLAY, LAYOUT_CLASSES,
  PLACEHOLDER, TABLE_PLACED, TAGGED, type Box, type DevicePDFHost, type DevicePDFInput, type Formula, type Glyph, type PageInput, type Region } from './types.ts';

/** A piece of text with formula markers (`__EQ_<id>__`) where the reference's HTML had them. */
export type Marked = string;
export const marker = (id: string) => `__EQ_${id}__`;
export const MARKER = /__EQ_(e-[0-9a-f]+-\d+)__/g;

export type FigureImage = { request: { page: number; rect: [number, number, number, number] } };
export type LogicalBlock =
  | { kind: 'heading'; level: number; marked: Marked; text: string }
  | { kind: 'paragraph'; marked: Marked; text: string; role: '' | 'authors' | 'footnote' | 'abstract' }
  | { kind: 'equation'; formula: string }
  | { kind: 'code'; lines: Marked[]; text: string }
  | { kind: 'references'; refs: string[] }
  | { kind: 'figure'; table: boolean; page: number; rect: [number, number, number, number]; caption: string }
  | { kind: 'cells'; caption: string; rows: { marked: Marked; span: number }[][]; text: string };

export interface TraceIndex {
  format: string; title: string;
  headings: { id: string; level: number; title: string }[];
  blocks: { id: string; kind: string; text: string }[];
  equations: Record<string, unknown>[];
  figures: { id: string; block_id: string; asset_paths: string[]; caption: string; alt: string }[];
}
export interface Reading {
  prefix: string; title: string; blocks: LogicalBlock[]; formulas: Map<string, Formula>; committed: string[];
  trace: TraceIndex; traceFigureBlocks: Map<LogicalBlock, string>;
  pages: { width: number; height: number; imageWidth: number; imageHeight: number }[];
  warnings: string[]; unowned: number; recognitionFailures: number;
}

interface Page { width: number; height: number; imageWidth: number; imageHeight: number; scale: number; glyphs: Glyph[]; detections: PageInput['detections'] }

function readPage(raw: PageInput): Page {
  check(raw && typeof raw === 'object', 'device_pdf_page');
  const g = raw.glyphs, n = g?.text?.length ?? -1;
  check(n >= 0 && n <= 200_000 && ['x0', 'top', 'x1', 'bottom', 'size', 'font', 'upright'].every(k => (g as Record<string, unknown[]>)[k]?.length === n), 'device_pdf_page');
  const finite = (v: unknown) => typeof v === 'number' && Number.isFinite(v);
  check([raw.width, raw.height, raw.image_width, raw.image_height, raw.scale].every(finite) && raw.width > 0 && raw.height > 0 && raw.scale > 0, 'device_pdf_page');
  const glyphs: Glyph[] = [];
  for (let i = 0; i < n; i++) {
    const glyph = { text: String(g.text[i] ?? ''), x0: +g.x0[i], top: +g.top[i], x1: +g.x1[i], bottom: +g.bottom[i], size: +g.size[i], font: String(g.font[i] ?? ''), upright: !!g.upright[i] };
    if (![glyph.x0, glyph.top, glyph.x1, glyph.bottom, glyph.size].every(Number.isFinite)) continue;
    glyphs.push(glyph);
  }
  const detections = (Array.isArray(raw.detections) ? raw.detections : []).filter(d => d && LAYOUT_CLASSES.includes(d.cls) && Array.isArray(d.box) && d.box.length === 4 && d.box.every(Number.isFinite) && Number.isFinite(d.score));
  return { width: raw.width, height: raw.height, imageWidth: Math.trunc(raw.image_width), imageHeight: Math.trunc(raw.image_height), scale: raw.scale, glyphs, detections };
}

export function read(input: DevicePDFInput, host: DevicePDFHost): Reading {
  const prefix = sha256Hex(utf8(`${input.pdf.sha256}:${DEVICE_PDF_RENDERER_ID}:${DEVICE_PDF_CONVERTER_VERSION}`)).slice(0, 12);
  const nPages = input.pages;
  check(Number.isSafeInteger(nPages) && nPages >= 1 && nPages <= 2000, 'device_pdf_pages');
  const cancelled = () => { if (host.cancelled?.()) fail('cancelled'); };
  // The text layer and the layout of every page first: running heads are known only from the whole document.
  const pages: Page[] = [];
  for (let p = 0; p < nPages; p++) { cancelled(); pages.push(readPage(host.page(p))); host.progress?.('layout', p + 1, nPages); }
  const known = furniture(pages.map(page => ({ glyphs: page.glyphs, height: page.height })));
  const s = DPI / 72;
  const blocks: LogicalBlock[] = [];
  const formulas = new Map<string, Formula>();
  const committed: string[] = [];
  const pendingRecognition: Formula[] = [];
  const warnings: string[] = [];
  const trace: TraceIndex = { format: 'reader-index-v1', title: '', headings: [], blocks: [], equations: [], figures: [] };
  const traceFigureBlocks = new Map<LogicalBlock, string>();
  let nEq = 0;
  const equationID = () => `e-${prefix}-${++nEq}`;
  const addTrace = (kind: string, text: string, level?: number): string => {
    const id = `b-${prefix}-${trace.blocks.length + 1}`;
    trace.blocks.push({ id, kind, text: clipBytes(text, 20_000) });
    if (kind === 'heading') {
      const lv = Math.min(6, Math.max(1, level || 2));
      trace.headings.push({ id, level: lv, title: [...text].slice(0, 2000).join('') || 'Untitled' });
    }
    return id;
  };
  const commit = (f: Formula, blockID: string, sourceForm: 'body' | 'environment') => {
    committed.push(f.id); pendingRecognition.push(f);
    trace.equations.push({ id: f.id, block_id: blockID, latex: '', display: f.display, source_form: sourceForm });
  };
  let title = '', inReferences = false, refs: string[] = [];
  let para: { marked: Marked; text: string; formulas: Formula[]; role: '' | 'abstract' }[] = [];
  let nGlyphs = 0, nUnowned = 0, recognitionFailures = 0;

  const flushPara = () => {
    if (!para.length) return;
    const marked = joinLines(para.map(x => x.marked)), text = joinLines(para.map(x => x.text));
    const block: LogicalBlock = { kind: 'paragraph', marked, text, role: para[0].role };
    blocks.push(block);
    const bid = addTrace('paragraph', text);
    for (const x of para) for (const f of x.formulas) commit(f, bid, 'body');
    para = [];
  };
  const continues = (text: string, cls: string, prevCls: string): boolean => {
    if (!para.length || cls !== 'paragraph' || prevCls !== 'paragraph') return false;
    const last = para[para.length - 1].text.trimEnd();
    return !!last && !'.!?:;”’)]'.includes([...last].pop()!) && /^[a-zα-ω(￼]/.test(text);
  };
  const flushRefs = () => {
    const chunks: string[][] = [[]];
    for (const r of refs) {
      const current = chunks[chunks.length - 1];
      if (current.length && current.reduce((n, x) => n + utf8(x).length + 1, 0) + utf8(r).length > BLOCK_TEXT_CHUNK) chunks.push([]);
      chunks[chunks.length - 1].push(r);
    }
    for (const chunk of chunks) {
      if (!chunk.length) continue;
      blocks.push({ kind: 'references', refs: chunk });
      addTrace('list', canonicalText(chunk.join(' ')));
    }
    refs = [];
  };
  const makeFormula = (gl: Glyph[], page: number, display: boolean, fontSize: number, box?: Box): Formula => {
    const bx = box ?? union(gl);
    const shown = gl.filter(visible);
    return { id: equationID(), display, page, box: bx, fontSize: fontSize > 0 ? fontSize : 10,
      baseline: display ? undefined : Math.max(...shown.map(g => g.bottom)) - bx[1],
      glyphText: byX(gl).map(g => g.text).join(''), latex: '', confidence: 0, recognised: false, rendered: false };
  };

  const recognisePending = () => {
    const readable: { f: Formula; rect: [number, number, number, number] }[] = [];
    for (const f of pendingRecognition) {
      formulas.set(f.id, f);
      const page = pages[f.page];
      const rect = recogniserRect(f.box, s, page.imageWidth, page.imageHeight);
      // Crops under 4 px either side (before the 8 px margin) are not read.
      if (rect[2] - rect[0] + 2 * CROP_MARGIN < 4 + 2 * CROP_MARGIN || rect[3] - rect[1] + 2 * CROP_MARGIN < 4 + 2 * CROP_MARGIN) continue;
      readable.push({ f, rect });
    }
    pendingRecognition.length = 0;
    if (!readable.length) return;
    let results: ({ latex: string; probs: number[] } | null)[] = [];
    try { results = host.recognise(readable.map(r => ({ page: r.f.page, rect: r.rect }))); }
    catch { warnings.push('equations: Error'); recognitionFailures += readable.length; return; }
    readable.forEach(({ f }, i) => {
      const r = results?.[i];
      if (!r || typeof r.latex !== 'string' || !Array.isArray(r.probs)) { recognitionFailures += 1; return; }
      // The reference keeps each token probability to five decimals before the gate reads it (texteller._batch).
      f.latex = r.latex; f.probs = r.probs.filter(Number.isFinite).map(v => Number(v.toFixed(5))); f.recognised = true;
      f.confidence = confidence(f.probs, f.display);
    });
  };

  for (let p = 0; p < nPages; p++) {
    cancelled();
    const page = pages[p];
    const heads = new Set(marginGlyphLines(page.glyphs, page.height).filter(([text]) => known.has(text)).flatMap(([, ln]) => ln));
    let glyphs = page.glyphs.filter(g => visible(g) && !heads.has(g));
    let regions: Region[] = page.detections.map(d => ({ cls: d.cls, score: d.score, box: d.box.map(v => v / page.scale), pt: d.box.map(v => v / page.scale / s) as Box }));
    const dropped = new Set(regions.filter(r => isFurniture(r, glyphs, page.height, known) || (p === 0 && isFrontMatter(r, glyphs))));
    regions = regions.filter(r => !dropped.has(r));
    const gone = new Set(glyphs.filter(g => [...dropped].some(r => centreIn(g, r.pt))));
    glyphs = glyphs.filter(g => !gone.has(g));
    regions = [...regions, ...orphanRegions(glyphs, growLines(glyphs, assign(glyphs, regions)), s)];
    const ordered = structure(regions, page.imageWidth, p === 0);
    const readers = [...ordered.filter(r => r.cls !== 'authors'), ...ordered.filter(r => r.cls === 'authors').flatMap(r => r.parts ?? []),
      ...ordered.flatMap(r => r.captions ?? [])];
    let owner = growLines(glyphs, assign(glyphs, readers));
    for (const r of ordered) if (r.cls === 'authors') { const parts = new Set(r.parts); owner = owner.map(o => o && parts.has(o) ? r : o); }
    nGlyphs += glyphs.length; nUnowned += owner.filter(o => o === null).length;
    const owned = (r: Region) => glyphs.filter((_, i) => owner[i] === r);

    // Every line the tagger will read on this page, in one call: region lines and table cell lines.
    const lineCache = new Map<Region, Glyph[][]>();
    const linesFor = (r: Region) => { if (!lineCache.has(r)) lineCache.set(r, linesOf(owned(r))); return lineCache.get(r)!; };
    const cellCache = new Map<Region, Cell[][] | null>();
    const cellsFor = (r: Region) => {
      if (!cellCache.has(r)) { const body = owned(r).filter(visible); cellCache.set(r, body.length ? tableCells(body) : null); }
      return cellCache.get(r)!;
    };
    const candidates: Glyph[][] = [];
    for (const r of ordered) {
      if (TAGGED.has(r.cls)) candidates.push(...linesFor(r).filter(l => l.length >= 2));
      if (r.cls === 'table') {
        const body = owned(r).filter(visible), cells = cellsFor(r);
        if (cells && cells.reduce((n, row) => n + row.reduce((m, [gl]) => m + gl.length, 0), 0) >= TABLE_PLACED * body.length) {
          for (const row of cells) for (const [gl] of row) if (gl.length >= 2) candidates.push(byXCached(gl));
        }
      }
    }
    const spanCache = new Map<Glyph[], [number, number][]>();
    const unique = [...new Set(candidates)];
    if (unique.length) {
      const logits = host.tag(unique.map(l => tagInput(l, input.tagger)));
      check(Array.isArray(logits) && logits.length === unique.length, 'device_pdf_tagger');
      unique.forEach((l, i) => spanCache.set(l, spansOf((logits[i] ?? []).map(Number), input.tagger.threshold)));
    }
    const spansFor = (line: Glyph[]) => line.length < 2 ? [] : spanCache.get(line) ?? [];

    let prevCls = '';
    const notes: { marked: Marked; text: string; formulas: Formula[] }[] = [];
    if (p === 0 && !title) {
      const first = ordered.find(r => r.cls === 'title');
      if (first) { const tl = owned(first); title = tl.length ? joinLines(linesOf(tl).map(ln => lineText(ln, [])[0])) : ''; }
    }
    let lastText = '';
    for (const r of ordered) {
      let cls = r.cls;
      if (cls === 'figure' || cls === 'table') { float(r, p); continue; }
      if (cls === 'display') {
        flushPara(); prevCls = cls;
        const body = owned(r);
        const f = makeFormula(body, p, true, body.length ? median(body.map(g => g.size)) : 10, body.length ? union(body) : r.pt);
        blocks.push({ kind: 'equation', formula: f.id });
        commit(f, addTrace('equation', PLACEHOLDER), 'environment');
        continue;
      }
      const inside = owned(r);
      if (!inside.length) continue;
      const texts: string[] = [], parts: Marked[] = [], tagFormulas: Formula[] = [];
      for (const line of linesFor(r)) {
        let spans = TAGGED.has(cls) && !inReferences ? spansFor(line) : [];
        if (cls === 'authors') spans = [];
        const [text, fl] = lineText(line, spans);
        texts.push(text);
        let marked = text;
        const size = median(line.map(g => g.size));
        for (const gl of fl) {
          const f = makeFormula(gl, p, false, size);
          tagFormulas.push(f);
          marked = marked.replace(PLACEHOLDER, marker(f.id));
        }
        parts.push(marked);
      }
      const text = joinLines(texts);
      if (!text || (cls !== 'title' && cls !== 'heading' && (text.match(/[\p{L}\p{N}]/gu) ?? []).length < 2 && !text.includes(PLACEHOLDER))) continue;
      const inner = cls !== 'listing' ? joinLines(parts) : parts.join('\n');
      if (continues(text, cls, prevCls)) { para.push({ marked: inner, text, formulas: tagFormulas, role: '' }); continue; }
      flushPara();
      if (title && cls !== 'title' && canonicalText(text) === canonicalText(title)) continue;
      if (canonicalText(text) === lastText) continue;
      lastText = canonicalText(text);
      if (cls === 'paragraph' && canonicalText(text).toLowerCase() === 'abstract') cls = 'heading';
      if (cls === 'title') {
        if (trace.headings.length && trace.headings[0].level === 1) continue;
        blocks.push({ kind: 'heading', level: 1, marked: inner, text }); addTrace('heading', text, 1);
      } else if (cls === 'heading') {
        if (inReferences && refs.length) flushRefs();
        inReferences = /^\s*(\d+\.?\s*)?(references|bibliography|literature cited|works cited)\b/i.test(text);
        const level = /^\d+(\.\d+)*\.?\s/.test(text) ? 2 + Math.min(2, (text.trim().split(' ')[0].match(/\./g) ?? []).length) : 2;
        blocks.push({ kind: 'heading', level, marked: inner, text }); addTrace('heading', text, level);
      } else if (cls === 'listing') {
        blocks.push({ kind: 'code', lines: inner.split('\n'), text });
        const bid = addTrace('code', text);
        for (const f of tagFormulas) commit(f, bid, 'body');
      } else if (inReferences && (cls === 'paragraph' || cls === 'bibitem')) {
        refs.push(text);
      } else if (cls === 'footnote') {
        notes.push({ marked: inner, text, formulas: tagFormulas });
        continue; // a footnote at the column's foot does not close the paragraph above it
      } else if (cls === 'authors') {
        blocks.push({ kind: 'paragraph', marked: inner, text, role: 'authors' }); addTrace('paragraph', text);
      } else {
        if (cls === 'abstract' && !(trace.headings.length && trace.headings[trace.headings.length - 1].title === 'Abstract')) {
          blocks.push({ kind: 'heading', level: 2, marked: 'Abstract', text: 'Abstract' }); addTrace('heading', 'Abstract', 2);
        }
        para.push({ marked: inner, text, formulas: tagFormulas, role: cls === 'abstract' ? 'abstract' : '' });
        if (cls !== 'paragraph') flushPara();
      }
      prevCls = cls;
    }
    for (const note of notes) {
      blocks.push({ kind: 'paragraph', marked: note.marked, text: note.text, role: 'footnote' });
      const bid = addTrace('paragraph', note.text);
      for (const f of note.formulas) commit(f, bid, 'body');
    }
    recognisePending();
    host.progress?.('pages', p + 1, nPages);

    function float(r: Region, pageIndex: number) {
      const box = r.box;
      const rect: [number, number, number, number] = [Math.trunc(box[0]), Math.trunc(box[1]), Math.trunc(box[2] + 0.999), Math.trunc(box[3] + 0.999)];
      if (rect[2] - rect[0] < 8 || rect[3] - rect[1] < 8) return;
      const caps = (r.captions ?? []).map(c => joinLines(linesOf(owned(c)).map(ln => lineText(ln, [])[0])));
      const capText = caps.filter(Boolean).join(' ');
      const kind = r.cls === 'figure' ? 'figure' : 'table';
      if (kind === 'table') {
        const body = owned(r).filter(visible);
        const cells = cellsFor(r);
        if (cells && cells.reduce((n, row) => n + row.reduce((m, [gl]) => m + gl.length, 0), 0) >= TABLE_PLACED * body.length) {
          const rows: { marked: Marked; span: number }[][] = [], texts: string[] = [], cellFormulas: Formula[] = [];
          for (const row of cells) {
            const tds: { marked: Marked; span: number }[] = [];
            for (const [gl, span] of row) {
              if (!gl.length) { tds.push({ marked: '', span: 1 }); continue; }
              const line = byXCached(gl);
              const [text, fl] = lineText(line, spansFor(line).filter(sp => cellSpanOk(line.slice(sp[0], sp[1]))));
              texts.push(text);
              let marked = text;
              const size = median(line.map(g => g.size));
              for (const fgl of fl) { const f = makeFormula(fgl, pageIndex, false, size); cellFormulas.push(f); marked = marked.replace(PLACEHOLDER, marker(f.id)); }
              tds.push({ marked, span });
            }
            rows.push(tds);
          }
          const text = canonicalText([...(capText ? [capText] : []), ...texts].join(' '));
          blocks.push({ kind: 'cells', caption: capText, rows, text });
          const bid = addTrace('table', text);
          for (const f of cellFormulas) commit(f, bid, 'body');
          return;
        }
      }
      const block: LogicalBlock = { kind: 'figure', table: kind === 'table', page: pageIndex, rect, caption: capText };
      blocks.push(block);
      const bid = addTrace(kind, capText);
      traceFigureBlocks.set(block, bid);
      if (kind === 'figure') trace.figures.push({ id: bid, block_id: bid, asset_paths: [], caption: clipBytes(capText, 20_000),
        alt: clipBytes(capText ? capText.split('. ')[0] : 'Figure', 2000) });
    }
  }
  flushPara();
  if (refs.length) flushRefs();
  recognisePending();

  trace.title = title || input.pdf.name.replace(/\.[^.]*$/, '');
  return { prefix, title, blocks, formulas, committed, trace, traceFigureBlocks, warnings, recognitionFailures,
    unowned: pyRound(nUnowned / Math.max(1, nGlyphs), 4),
    pages: pages.map(pg => ({ width: pg.width, height: pg.height, imageWidth: pg.imageWidth, imageHeight: pg.imageHeight })) };
}

// One sorted copy per cell glyph list, so the tagger's results are found again by identity.
const sortedCells = new WeakMap<Glyph[], Glyph[]>();
function byXCached(gl: Glyph[]): Glyph[] {
  let sorted = sortedCells.get(gl);
  if (!sorted) { sorted = byX(gl); sortedCells.set(gl, sorted); }
  return sorted;
}

/** The gate: Temml MathML for each recognised formula whose confidence passes. */
export function gate(reading: Reading): void {
  for (const id of reading.committed) {
    const f = reading.formulas.get(id)!;
    if (f.latex && f.confidence >= (f.display ? GATE_DISPLAY : GATE)) {
      const math = renderMath(f.latex, f.display);
      if (math) { f.rendered = true; f.mathml = math; }
    }
  }
}

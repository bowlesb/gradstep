// The reading pass (device_pdf.Converter.convert and _float), ported rule for rule. It produces the logical
// blocks in the reference's order, the reference's own index (`trace`, for bundle_conformance.py) and the
// formulas with their crops; `emit.ts` turns the logical blocks into this reader's vocabulary.
import { check, fail, sha256Hex, utf8 } from '../util.ts';
import { argsort, assign, byX, canonicalText, centreIn, clipBytes, growLines, joinLines, lineText, linesOf, median, orphanRegions,
  pyRound, recogniserRect, typicalGap, union, useWordGaps, visible } from './geometry.ts';
import { confidence, renderMath, tidyLatex } from './math.ts';
import { furniture, isFrontMatter, isFurniture, marginGlyphLines, structure, venueNotice } from './structure.ts';
import { cellSpanOk, tableCells, type Cell } from './tables.ts';
import { aliasFont, aliasText, spansOf, tagInput } from './tagger.ts';
import { mathRuns, transcribe } from './transcribe.ts';
import { BLOCK_TEXT_CHUNK, CROP_MARGIN, LINE_GAP, DEVICE_PDF_CONVERTER_VERSION, DEVICE_PDF_RENDERER_ID, DPI, GATE, GATE_DISPLAY, LAYOUT_CLASSES,
  PLACEHOLDER, TABLE_PLACED, TAGGED, type Box, type DevicePDFHost, type DevicePDFInput, type Formula, type Glyph, type PageInput, type Region,
  type TaggerVocabulary } from './types.ts';

/** The font of glyphs the host recognised from the page image (DevicePDFOCR.swift). */
export const OCR_FONT = 'GradstepOCR';

/** A piece of text with formula markers (`__EQ_<id>__`) where the reference's HTML had them. */
export type Marked = string;
export const marker = (id: string) => `__EQ_${id}__`;
export const MARKER = /__EQ_(e-[0-9a-f]+-\d+)__/g;

export type FigureImage = { request: { page: number; rect: [number, number, number, number] } };
export type LogicalBlock =
  | { kind: 'heading'; level: number; marked: Marked; text: string; trace?: string }
  | { kind: 'paragraph'; marked: Marked; text: string; role: '' | 'authors' | 'footnote' | 'abstract' }
  | { kind: 'equation'; formula: string }
  | { kind: 'code'; lines: Marked[]; text: string }
  | { kind: 'references'; refs: string[] }
  | { kind: 'figure'; table: boolean; page: number; rect: [number, number, number, number]; caption: string; captionMarked?: Marked }
  | { kind: 'cells'; caption: string; captionMarked?: Marked; rows: { marked: Marked; span: number }[][]; text: string };

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
  /** Recognitions submitted to the host's background recogniser and not yet collected (`settle`). */
  submissions: { ticket: number; formulas: Formula[] }[];
  /** The recogniser's LaTeX tidied when Temml refuses it as read (math.tidyLatex). */
  tidy: boolean;
  /** The display gate's threshold (input.displayGate, else GATE_DISPLAY). */
  displayGate: number;
}

interface Page { width: number; height: number; imageWidth: number; imageHeight: number; scale: number; glyphs: Glyph[]; detections: PageInput['detections'] }

function readPage(raw: PageInput, aliases?: TaggerVocabulary): Page {
  check(raw && typeof raw === 'object', 'device_pdf_page');
  const g = raw.glyphs, n = g?.text?.length ?? -1;
  check(n >= 0 && n <= 200_000 && ['x0', 'top', 'x1', 'bottom', 'size', 'font', 'upright'].every(k => (g as Record<string, unknown[]>)[k]?.length === n), 'device_pdf_page');
  const finite = (v: unknown) => typeof v === 'number' && Number.isFinite(v);
  check([raw.width, raw.height, raw.image_width, raw.image_height, raw.scale].every(finite) && raw.width > 0 && raw.height > 0 && raw.scale > 0, 'device_pdf_page');
  const glyphs: Glyph[] = [];
  for (let i = 0; i < n; i++) {
    const font = String(g.font[i] ?? '');
    const text = String(g.text[i] ?? '');
    const glyph = { text: aliases ? aliasText(text, font) : text, x0: +g.x0[i], top: +g.top[i], x1: +g.x1[i], bottom: +g.bottom[i], size: +g.size[i], font: aliases ? aliasFont(font, aliases) : font, upright: !!g.upright[i] };
    if (![glyph.x0, glyph.top, glyph.x1, glyph.bottom, glyph.size].every(Number.isFinite)) continue;
    glyphs.push(glyph);
  }
  const detections = (Array.isArray(raw.detections) ? raw.detections : []).filter(d => d && LAYOUT_CLASSES.includes(d.cls) && Array.isArray(d.box) && d.box.length === 4 && d.box.every(Number.isFinite) && Number.isFinite(d.score));
  return { width: raw.width, height: raw.height, imageWidth: Math.trunc(raw.image_width), imageHeight: Math.trunc(raw.image_height), scale: raw.scale, glyphs, detections };
}

export function read(input: DevicePDFInput, host: DevicePDFHost): Reading {
  const prefix = sha256Hex(utf8(`${input.pdf.sha256}:${DEVICE_PDF_RENDERER_ID}:${DEVICE_PDF_CONVERTER_VERSION}`)).slice(0, 12);
  useWordGaps(null);
  const nPages = input.pages;
  check(Number.isSafeInteger(nPages) && nPages >= 1 && nPages <= 2000, 'device_pdf_pages');
  const cancelled = () => { if (host.cancelled?.()) fail('cancelled'); };
  // The text layer and the layout of every page first: running heads are known only from the whole document.
  const pages: Page[] = [];
  for (let p = 0; p < nPages; p++) { cancelled(); pages.push(readPage(host.page(p), input.fontAliases ? input.tagger : undefined)); host.progress?.('layout', p + 1, nPages); }
  if (input.wordGaps) useWordGaps(typicalGap(pages));
  const known = furniture(pages.map(page => ({ glyphs: page.glyphs, height: page.height })));
  // Pages the host read by text recognition (its text layer missing or unreadable; DevicePDFOCR.swift).
  const recognisedPages = pages.filter(page => page.glyphs.length && page.glyphs.every(g => g.font === OCR_FONT)).length;
  const s = DPI / 72;
  const blocks: LogicalBlock[] = [];
  const formulas = new Map<string, Formula>();
  const committed: string[] = [];
  const pendingRecognition: Formula[] = [];
  const warnings: string[] = [];
  if (recognisedPages) warnings.push(`text recognised from the page image: ${recognisedPages} of ${nPages} pages`);
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
    committed.push(f.id);
    if (f.transcribed) formulas.set(f.id, f); else pendingRecognition.push(f);
    trace.equations.push({ id: f.id, block_id: blockID, latex: '', display: f.display, source_form: sourceForm });
  };
  let title = '', inReferences = false, refs: string[] = [];
  /** References read without a heading (bibliography): they end at the first region that is not an entry. */
  let headless = false;
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
    const f: Formula = { id: equationID(), display, page, box: bx, fontSize: fontSize > 0 ? fontSize : 10,
      baseline: display ? undefined : Math.max(...shown.map(g => g.bottom)) - bx[1],
      glyphText: byX(gl).map(g => g.text).join(''), latex: '', confidence: 0, recognised: false, rendered: false };
    // A simple inline formula is written from the text layer and never reaches the recogniser (transcribe.ts).
    const tex = !display && input.transcribe ? transcribe(gl, fontSize) : null;
    if (tex) Object.assign(f, { latex: tex, probs: [], recognised: true, confidence: 1, transcribed: true });
    return f;
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
    const requests = readable.map(r => ({ page: r.f.page, rect: r.rect, display: r.f.display }));
    // A host with a background recogniser reads this page's formulas while the converter reads on (port revision 5).
    if (host.submit && host.collect) {
      let ticket: number;
      try { ticket = host.submit(requests); } catch { warnings.push('equations: Error'); recognitionFailures += readable.length; return; }
      submissions.push({ ticket, formulas: readable.map(r => r.f) });
      return;
    }
    let results: ({ latex: string; probs: number[] } | null)[] = [];
    try { results = host.recognise(requests.map(({ page, rect }) => ({ page, rect }))); }
    catch { warnings.push('equations: Error'); recognitionFailures += readable.length; return; }
    recognitionFailures += assignRecognitions(readable.map(r => r.f), results);
  };
  const submissions: Reading['submissions'] = [];

  for (let p = 0; p < nPages; p++) {
    cancelled();
    const page = pages[p];
    const heads = new Set(marginGlyphLines(page.glyphs, page.height).filter(([text]) => known.has(text)).flatMap(([, ln]) => ln));
    // The venue's notice on the first page (proceedings line, copyright, open-access watermark) is not the paper's text.
    if (input.venueNotice && p === 0) for (const g of venueNotice(page.glyphs, page.height)) heads.add(g);
    let glyphs = page.glyphs.filter(g => visible(g) && !heads.has(g));
    let regions: Region[] = page.detections.map(d => ({ cls: d.cls, score: d.score, box: d.box.map(v => v / page.scale), pt: d.box.map(v => v / page.scale / s) as Box }));
    const dropped = new Set(regions.filter(r => isFurniture(r, glyphs, page.height, known) || (p === 0 && isFrontMatter(r, glyphs))));
    regions = regions.filter(r => !dropped.has(r));
    if (input.bibliography) regions = mergeOverlapping(regions, 'bibitem');
    // A display boxed twice (the group and a row of it) would be read in pieces: one formula, as it was set.
    if (input.mergeDisplays) regions = mergeOverlapping(regions, 'display');
    const gone = new Set(glyphs.filter(g => [...dropped].some(r => centreIn(g, r.pt))));
    glyphs = glyphs.filter(g => !gone.has(g));
    regions = [...regions, ...orphanRegions(glyphs, growLines(glyphs, assign(glyphs, regions)), s)];
    if (p === 0 && input.frontMatter) frontMatterRoles(regions, glyphs, input);
    const ordered = structure(regions, page.imageWidth, p === 0);
    const readers = [...ordered.filter(r => r.cls !== 'authors'), ...ordered.filter(r => r.cls === 'authors').flatMap(r => r.parts ?? []),
      ...ordered.flatMap(r => r.captions ?? [])];
    let owner = growLines(glyphs, assign(glyphs, readers));
    if (input.lineOwners) owner = lineOwners(glyphs, owner);
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
      if (input.captionMath) for (const c of r.captions ?? []) candidates.push(...linesFor(c).filter(l => l.length >= 2));
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
      // A bibliography without a heading ends where its entries do: at a display, or a paragraph that opens without a label.
      if (headless && inReferences && (cls === 'display' || cls === 'listing' || cls === 'abstract' ||
        (cls === 'paragraph' && !REFERENCE_LABEL.test(lineText(linesFor(r)[0] ?? [], [])[0])))) {
        if (refs.length) flushRefs();
        inReferences = false; headless = false;
      }
      if (cls === 'display') {
        flushPara(); prevCls = cls;
        const body = owned(r);
        // The equation number is not part of the formula the recogniser learnt to read (equationNumbers).
        const numbered = input.equationNumbers ? equationNumber(body, r.pt[2]) : null;
        const formulaBody = numbered?.body ?? body;
        // On a page read by text recognition (DevicePDFOCR) the glyphs' boxes are a word's, spread: the layout's box is the formula's.
        const recognised = body.length > 0 && body.every(g => g.font === OCR_FONT);
        const numberLeft = numbered ? Math.min(...body.filter(g => !numbered.body.includes(g)).map(g => g.x0)) : Infinity;
        const regionBox: Box = [r.pt[0], r.pt[1], Math.max(r.pt[0] + 1, Math.min(r.pt[2], numberLeft - 1)), r.pt[3]];
        const f = makeFormula(formulaBody, p, true, body.length ? median(body.map(g => g.size)) : 10, formulaBody.length && !recognised ? union(formulaBody) : regionBox);
        if (numbered) { f.tag = numbered.tag; f.imageBox = recognised ? r.pt : union(body); }
        // The full stop or comma after a display often falls just outside its box, unowned; the formula keeps it.
        if (input.displayPunctuation) f.trailing = trailingPunctuation(formulaBody, glyphs.filter((_, i) => owner[i] === null));
        blocks.push({ kind: 'equation', formula: f.id });
        commit(f, addTrace('equation', PLACEHOLDER), 'environment');
        continue;
      }
      const inside = owned(r);
      if (!inside.length) continue;
      // A bibliography without a heading (REVTeX): the layout's reference entries, two or more opening with a label.
      if (input.bibliography && !inReferences && cls === 'bibitem' && linesFor(r).filter(l => REFERENCE_LABEL.test(lineText(l, [])[0])).length >= 2) {
        flushPara(); inReferences = true; headless = true;
      }
      const texts: string[] = [], parts: Marked[] = [], tagFormulas: Formula[] = [];
      for (const line of linesFor(r)) {
        let spans = TAGGED.has(cls) && !inReferences ? spansFor(line) : [];
        if (input.extendSpans && spans.length) spans = extendSpans(line, spans);
        // Math the tagger missed, found by its fonts and written from the text layer (transcribe.mathRuns).
        if (input.fontMath && spans.length < 64 && TAGGED.has(cls) && !inReferences && cls !== 'authors') {
          spans = [...spans, ...fontSpans(line, spans)].sort((a, b) => a[0] - b[0]);
        }
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
      // The library's title read as a heading when the layout found no title: the reader's h1 is that title already.
      if (input.headingDupes && !title && cls === 'heading' && input.title && letters(text) === letters(input.title)) continue;
      if (canonicalText(text) === lastText) continue;
      lastText = canonicalText(text);
      if (cls === 'paragraph' && canonicalText(text).toLowerCase() === 'abstract') cls = 'heading';
      if (cls === 'title') {
        if (trace.headings.length && trace.headings[0].level === 1) continue;
        blocks.push({ kind: 'heading', level: 1, marked: inner, text }); addTrace('heading', text, 1);
      } else if (cls === 'heading') {
        if (inReferences && refs.length) flushRefs();
        inReferences = /^\s*(\d+\.?\s*)?(references|bibliography|literature cited|works cited)\b/i.test(text); headless = false;
        const level = /^\d+(\.\d+)*\.?\s/.test(text) ? 2 + Math.min(2, (text.trim().split(' ')[0].match(/\./g) ?? []).length) : 2;
        blocks.push({ kind: 'heading', level, marked: inner, text, trace: addTrace('heading', text, level) });
      } else if (cls === 'listing') {
        blocks.push({ kind: 'code', lines: inner.split('\n'), text });
        const bid = addTrace('code', text);
        for (const f of tagFormulas) commit(f, bid, 'body');
      } else if (inReferences && (cls === 'paragraph' || cls === 'bibitem')) {
        // One region often holds several entries (the layout boxes a column of them): each entry starts at a line that
        // opens with a label ("[12]", "12.") or sits out to the left of the line before (hanging indent).
        if (input.splitReferences) {
          const entries = referenceEntries(linesFor(r), texts);
          // An entry broken by a column or page (a bibliography without a heading): a region that opens without a
          // label, after labelled entries, continues the last one.
          if (headless && entries.length && refs.length && !REFERENCE_LABEL.test(entries[0]) && REFERENCE_LABEL.test(refs[refs.length - 1])) {
            refs[refs.length - 1] = joinLines([refs[refs.length - 1], entries.shift()!]);
          }
          refs.push(...entries);
        } else refs.push(text);
      } else if (cls === 'footnote') {
        notes.push({ marked: inner, text, formulas: tagFormulas });
        continue; // a footnote at the column's foot does not close the paragraph above it
      } else if (cls === 'authors') {
        blocks.push({ kind: 'paragraph', marked: inner, text, role: 'authors' }); addTrace('paragraph', text);
      } else {
        const abstractHeading = (t: string) => input.headingDupes ? letters(t) === 'abstract' : t === 'Abstract';
        if (cls === 'abstract' && !(trace.headings.length && abstractHeading(trace.headings[trace.headings.length - 1].title))) {
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
      // Captions keep their math (captionMath): the tagger's spans and font-found math, as in a paragraph's lines.
      const capFormulas: Formula[] = [];
      const captionMarked = input.captionMath ? (r.captions ?? []).map(c => joinLines(linesFor(c).map(line => {
        let spans = spansFor(line);
        if (input.fontMath && spans.length < 64) spans = [...spans, ...fontSpans(line, spans)].sort((a, b) => a[0] - b[0]);
        const [text, fl] = lineText(line, spans);
        let marked = text;
        const size = median(line.map(g => g.size));
        for (const gl of fl) { const f = makeFormula(gl, pageIndex, false, size); capFormulas.push(f); marked = marked.replace(PLACEHOLDER, marker(f.id)); }
        return marked;
      }))).filter(Boolean).join(' ') : undefined;
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
              const tagged = spansFor(line).filter(sp => cellSpanOk(line.slice(sp[0], sp[1])));
              // Math the tagger missed in a cell, found by its fonts and written from the text layer (transcribe.ts).
              const found = input.fontMath ? mathRuns(line, tagged) : [];
              const [text, fl] = lineText(line, [...tagged, ...found].sort((a, b) => a[0] - b[0]));
              texts.push(text);
              let marked = text;
              const size = median(line.map(g => g.size));
              for (const fgl of fl) { const f = makeFormula(fgl, pageIndex, false, size); cellFormulas.push(f); marked = marked.replace(PLACEHOLDER, marker(f.id)); }
              tds.push({ marked, span });
            }
            rows.push(tds);
          }
          const text = canonicalText([...(capText ? [capText] : []), ...texts].join(' '));
          blocks.push({ kind: 'cells', caption: capText, ...(captionMarked !== undefined ? { captionMarked } : {}), rows, text });
          const bid = addTrace('table', text);
          for (const f of [...capFormulas, ...cellFormulas]) commit(f, bid, 'body');
          return;
        }
      }
      const block: LogicalBlock = { kind: 'figure', table: kind === 'table', page: pageIndex, rect, caption: capText, ...(captionMarked !== undefined ? { captionMarked } : {}) };
      blocks.push(block);
      const bid = addTrace(kind, capText);
      for (const f of capFormulas) commit(f, bid, 'body');
      traceFigureBlocks.set(block, bid);
      if (kind === 'figure') trace.figures.push({ id: bid, block_id: bid, asset_paths: [], caption: clipBytes(capText, 20_000),
        alt: clipBytes(capText ? capText.split('. ')[0] : 'Figure', 2000) });
    }
  }
  flushPara();
  if (refs.length) flushRefs();
  if (input.headingDupes) contentsAsText(blocks, trace);
  recognisePending();

  trace.title = title || input.pdf.name.replace(/\.[^.]*$/, '');
  return { prefix, title, blocks, formulas, committed, trace, traceFigureBlocks, warnings, recognitionFailures, submissions, tidy: !!input.tidy,
    displayGate: typeof input.displayGate === 'number' && input.displayGate >= 0.5 && input.displayGate <= 1 ? input.displayGate : GATE_DISPLAY,
    unowned: pyRound(nUnowned / Math.max(1, nGlyphs), 4),
    pages: pages.map(pg => ({ width: pg.width, height: pg.height, imageWidth: pg.imageWidth, imageHeight: pg.imageHeight })) };
}

/** The punctuation mark that ends a display just outside its box, or '': among `free` glyphs, a run to the right of
 * the formula (each within 0.8 em of the one before; a closing delimiter the box cut off may come first) whose last
 * glyph is a full stop, comma or semicolon in the lower part of the formula (its last row, or beside limits below it). */
export function trailingPunctuation(body: readonly Glyph[], free: readonly Glyph[]): string {
  const shown = body.filter(visible);
  if (!shown.length) return '';
  const em = median(shown.map(g => g.size)) || 10, top = Math.min(...shown.map(g => g.top)), bottom = Math.max(...shown.map(g => g.bottom));
  let right = Math.max(...shown.map(g => g.x1));
  const beside = byX(free.filter(g => visible(g) && g.x0 >= right - 0.1 * em && g.x0 - right <= 3 * em && (g.top + g.bottom) / 2 >= top && (g.top + g.bottom) / 2 <= bottom + 0.3 * em));
  for (const g of beside) {
    if (g.x0 - right > 0.8 * em) break;
    if (/^[.,;]$/.test(g.text)) return (g.top + g.bottom) / 2 >= top + 0.4 * (bottom - top) ? g.text : '';
    right = Math.max(right, g.x1);
  }
  return '';
}

const NUMBER_TAG = /^\((?:[A-Z]{1,2}\.?)?\d{1,3}(?:\.\d{1,3})?[a-z]?\)$/;
/** A display's equation numbers: on each of its lines, a run of glyphs reading "(12)", "(3.4)", "(A.1)" or "(81a)" set
 * apart to the right of the formula (1.5 em or more, or half an em when it ends within 1.5 em of the display box's right
 * edge `right`, where a tight two-column layout sets it), or alone on a line of its own right of everything else (a
 * number centred between rows). Returns the glyphs without the numbers and the numbers as one tag; null when none. */
export function equationNumber(body: readonly Glyph[], right = Infinity): { body: Glyph[]; tag: string } | null {
  const shown = body.filter(visible);
  if (shown.length < 4) return null;
  const em = median(shown.map(g => g.size)) || 10;
  const drop = new Set<Glyph>(), tags: { top: number; text: string }[] = [];
  for (const line of linesOf(shown)) {
    const order = byX(line);
    let k = order.length - 1;
    while (k > 0 && order[k].x0 - order[k - 1].x1 < 0.5 * em) k--;
    const run = order.slice(k), text = run.map(g => g.text).join('').replace(/\s+/g, '');
    if (!NUMBER_TAG.test(text)) continue;
    const rest = shown.filter(g => !run.includes(g) && !drop.has(g));
    if (rest.length < 3) continue;
    const gap = k > 0 ? run[0].x0 - order[k - 1].x1 : run[0].x0 - Math.max(...rest.map(g => g.x1));
    const flush = right - Math.max(...run.map(g => g.x1)) <= 1.5 * em;
    const apart = gap >= 1.5 * em || (flush && gap >= 0.5 * em);
    if (!apart) continue;
    for (const g of run) drop.add(g);
    tags.push({ top: Math.min(...run.map(g => g.top)), text });
  }
  if (!tags.length) return null;
  return { body: body.filter(g => !drop.has(g)), tag: tags.sort((a, b) => a.top - b.top).map(t => t.text).join(' ') };
}

// One sorted copy per cell glyph list, so the tagger's results are found again by identity.
const sortedCells = new WeakMap<Glyph[], Glyph[]>();
function byXCached(gl: Glyph[]): Glyph[] {
  let sorted = sortedCells.get(gl);
  if (!sorted) { sorted = byX(gl); sortedCells.set(gl, sorted); }
  return sorted;
}

/** `mathRuns` on a line in stream order (spans index it as given): a run found in x order counts when its glyphs are one
 * stretch of the stream too and it overlaps none of `taken`. */
export function fontSpans(line: readonly Glyph[], taken: readonly [number, number][]): [number, number][] {
  const order = argsort(line, g => g.x0);
  const at = new Map(order.map((i, k) => [i, k]));
  const busy: [number, number][] = [];
  for (const [s, e] of taken) for (let i = s; i < e; i++) { const k = at.get(i); if (k !== undefined) busy.push([k, k + 1]); }
  const out: [number, number][] = [];
  for (const [s, e] of mathRuns(order.map(i => line[i]), busy)) {
    const idx = order.slice(s, e), lo = Math.min(...idx), hi = Math.max(...idx);
    if (hi - lo + 1 === idx.length && !taken.some(([a, b]) => a <= hi && lo < b)) out.push([lo, hi + 1]);
  }
  return out;
}

/** A references region's lines (glyphs, and their text) as its entries: a line starts an entry when it opens with a
 * label ("[12]", "12.", "(12)") or begins more than half an em left of the line before (the hanging indent most styles
 * use); otherwise it continues the entry, a word broken at the line's end joined. */
const REFERENCE_LABEL = /^\s*(\[\s*[\w+.\-]{1,12}\s*\]|\(\d{1,4}\)|\d{1,4}\.)\s/;
/** Regions of one class that overlap within a column, as one region (their union): the layout often boxes a column of
 * reference entries as overlapping regions, and glyphs shared between them would be read in two pieces out of order.
 * Regions overlap when they share more than half of the narrower one's width and any height. */
export function mergeOverlapping(regions: readonly Region[], cls: string): Region[] {
  const same = regions.filter(r => r.cls === cls).map(r => ({ ...r, box: [...r.box], pt: [...r.pt] as Box }));
  const overlap = (a: Region, b: Region) => Math.min(a.box[2], b.box[2]) - Math.max(a.box[0], b.box[0]) > 0.5 * Math.min(a.box[2] - a.box[0], b.box[2] - b.box[0])
    && Math.min(a.box[3], b.box[3]) - Math.max(a.box[1], b.box[1]) > 0;
  for (let merged = true; merged;) {
    merged = false;
    for (let i = 0; i < same.length && !merged; i++) for (let j = i + 1; j < same.length && !merged; j++) {
      if (!overlap(same[i], same[j])) continue;
      const a = same[i], b = same[j];
      a.box = [Math.min(a.box[0], b.box[0]), Math.min(a.box[1], b.box[1]), Math.max(a.box[2], b.box[2]), Math.max(a.box[3], b.box[3])];
      a.pt = [Math.min(a.pt[0], b.pt[0]), Math.min(a.pt[1], b.pt[1]), Math.max(a.pt[2], b.pt[2]), Math.max(a.pt[3], b.pt[3])];
      a.score = Math.max(a.score, b.score);
      same.splice(j, 1); merged = true;
    }
  }
  return [...regions.filter(r => r.cls !== cls), ...same];
}

export function referenceEntries(lines: readonly Glyph[][], texts: readonly string[]): string[] {
  const label = REFERENCE_LABEL;
  const lefts = lines.map(l => Math.min(...l.filter(visible).map(g => g.x0)));
  const sizes = lines.map(l => median(l.map(g => g.size)) || 10);
  const labelled = texts.filter(t => label.test(t)).length >= 2;
  const entries: string[][] = [];
  texts.forEach((t, i) => {
    if (!t) return;
    const starts = !entries.length || (labelled ? label.test(t) : lefts[i] < lefts[i - 1] - 0.5 * sizes[i]);
    if (starts) entries.push([t]); else entries[entries.length - 1].push(t);
  });
  return entries.map(e => joinLines(e)).filter(Boolean);
}

/** A printed table of contents: three or more headings in a row, each of which comes again as a later heading, are the
 * contents list, not sections; they become paragraphs (the reader's Contents is built from the sections themselves).
 * In place, the reference's index kept in step. */
export function contentsAsText(blocks: LogicalBlock[], trace: TraceIndex): void {
  const key = (b: LogicalBlock) => b.kind === 'heading' ? letters(b.text).replace(/\d+$/, '') : '';
  const later = new Map<string, number>(); // heading text -> last index
  blocks.forEach((b, i) => { if (b.kind === 'heading' && b.level > 1) later.set(key(b), i); });
  let run: number[] = [];
  const settle = () => {
    if (run.length >= 3) for (const i of run) {
      const b = blocks[i] as Extract<LogicalBlock, { kind: 'heading' }>;
      blocks[i] = { kind: 'paragraph', marked: b.marked, text: b.text, role: '' };
      const row = trace.blocks.find(t => t.id === b.trace);
      if (row) row.kind = 'paragraph';
      trace.headings = trace.headings.filter(h => h.id !== b.trace);
    }
    run = [];
  };
  blocks.forEach((b, i) => {
    if (b.kind === 'heading' && b.level > 1 && b.trace && (later.get(key(b)) ?? i) > i) run.push(i);
    else settle();
  });
  settle();
}

/** One run of a text line (glyphs at word spacing or closer) belongs to one region: the region holding most of it. A
 * heading whose box is narrower than its text otherwise loses its first or last letters to the paragraph box beside it
 * ("ic droplet size" for "Electrostatic droplet size"). Column gutters (over one glyph height) end a run. */
export function lineOwners(glyphs: readonly Glyph[], owner: readonly (Region | null)[]): (Region | null)[] {
  const index = new Map<Glyph, number>(glyphs.map((g, i) => [g, i]));
  const out = [...owner];
  for (const line of linesOf(glyphs)) {
    const order = byX(line);
    let run: Glyph[] = [];
    const settle = () => {
      if (run.length < 2) return;
      const votes = new Map<Region, number>();
      for (const g of run) { const o = out[index.get(g)!]; if (o) votes.set(o, (votes.get(o) ?? 0) + 1); }
      if (votes.size < 2) return;
      const [winner, n] = [...votes].sort((a, b) => b[1] - a[1])[0];
      // Only a clear majority, and never for floats or displays (their glyphs are read by other rules).
      if (n * 2 <= run.length || ['figure', 'table', 'display'].includes(winner.cls)) return;
      if ([...votes.keys()].some(r => ['figure', 'table', 'display'].includes(r.cls))) return;
      for (const g of run) out[index.get(g)!] = winner;
    };
    for (const g of order) {
      const prev = run[run.length - 1];
      if (prev && g.x0 - prev.x1 > LINE_GAP * Math.max(1.0, g.bottom - g.top)) { settle(); run = []; }
      run.push(g);
    }
    settle();
  }
  return out;
}

const OPERATOR_NAMES = new Set(['sin', 'cos', 'tan', 'sec', 'csc', 'cot', 'sinh', 'cosh', 'tanh', 'log', 'ln', 'exp', 'max', 'min', 'sup', 'inf',
  'lim', 'det', 'dim', 'arg', 'Pr', 'tr', 'diag', 'softmax', 'argmax', 'argmin']);
/** A tagged formula's glyph run grown over what the tagger cut off at its edges (spans in stream order, as `lineText`
 * takes them): touching digits and operators in the roman font ("63.6" of "63.6±3.9") and an operator name set against it
 * ("cos" of "cos θ"). The tagger's commonest error is a formula cut short (the desktop's boundary analysis); a grown span
 * is kept only when its glyphs are one stretch of the stream and it meets no other span. */
export function extendSpans(line: readonly Glyph[], spans: readonly [number, number][]): [number, number][] {
  if (!spans.length) return [...spans];
  const order = argsort(line, g => g.x0), at = new Map(order.map((i, k) => [i, k]));
  const owner = new Map<number, number>(); // x position -> span number
  spans.forEach(([s, e], n) => { for (let i = s; i < e; i++) { const k = at.get(i); if (k !== undefined) owner.set(k, n); } });
  const roman = (g: Glyph) => /^(CMR|LMRoman\d*-Regular|NimbusRomNo9L-Regu|TeXGyreTermes-Regular|NewTXRoman|ntxr|txr|Times-Roman)/i.test(g.font.replace(/^[A-Z]{6}\+/, ''));
  // Glyphs of one formula: touching, or across the medium and thick spaces TeX sets around operators and relations.
  const operator = (g: Glyph) => /^[=+\-−×±<>≤≥≈∼·∈]$/.test(g.text);
  const touching = (a: Glyph, b: Glyph) => b.x0 - a.x1 < (operator(a) || operator(b) ? 0.32 : 0.12) * Math.max(a.size, b.size, 1);
  const neutral = (g: Glyph) => roman(g) && /^[0-9.=+\-−()[\]/×±·]$/.test(g.text);
  const current: [number, number][] = spans.map(([s, e]) => [s, e]);
  const grown = current.map(([s, e], n): [number, number] => {
    const xs = [];
    for (let i = s; i < e; i++) { const k = at.get(i); if (k !== undefined) xs.push(k); }
    let lo = Math.min(...xs), hi = Math.max(...xs);
    const free = (k: number) => k >= 0 && k < order.length && owner.get(k) === undefined && visible(line[order[k]]);
    // Left: digits and operators, then an operator name.
    while (free(lo - 1) && neutral(line[order[lo - 1]]) && touching(line[order[lo - 1]], line[order[lo]])) lo--;
    // TeX sets a thin space (1/6 em) between an operator name and its argument; the name's own letters touch.
    let k = lo - 1, name = '';
    while (free(k) && roman(line[order[k]]) && /^\p{L}$/u.test(line[order[k]].text)
      && (k === lo - 1 ? line[order[lo]].x0 - line[order[k]].x1 < 0.3 * Math.max(line[order[k]].size, 1) : touching(line[order[k]], line[order[k + 1]]))) { name = line[order[k]].text + name; k--; }
    if (name && OPERATOR_NAMES.has(name) && !(free(k) && /^\p{L}$/u.test(line[order[k]].text))) lo = k + 1;
    // Right: digits and operators (not a closing comma or full stop).
    while (free(hi + 1) && neutral(line[order[hi + 1]]) && touching(line[order[hi]], line[order[hi + 1]])) hi++;
    while (hi > Math.max(...xs) && /^[.]$/.test(line[order[hi]].text)) hi--;
    const idx = order.slice(lo, hi + 1), a = Math.min(...idx), b = Math.max(...idx);
    if (b - a + 1 !== idx.length || current.some(([x, y], m) => m !== n && x <= b && a < y)) return [s, e];
    // The grown span owns its glyphs from now on: a later span does not grow into them.
    for (let p = lo; p <= hi; p++) owner.set(p, n);
    current[n] = [a, b + 1];
    return [a, b + 1];
  });
  // Spans that now meet ("x =" and "y" of "x = y") are one formula when their glyphs touch across the meeting point.
  const sorted = [...grown].sort((p, q) => p[0] - q[0]), merged: [number, number][] = [];
  for (const sp of sorted) {
    const last = merged[merged.length - 1];
    if (last && last[1] === sp[0] && touching(line[last[1] - 1], line[sp[0]]) && line[sp[0]].x0 >= line[last[1] - 1].x0) last[1] = sp[1];
    else merged.push([sp[0], sp[1]]);
  }
  return merged;
}

const letters = (text: string) => text.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
/** The first page's title and author lines when the layout called them headings (REVTeX and other title pages): a
 * heading that is the library's title becomes the title (when the layout found none), and a heading above the abstract
 * and the first paragraph that names one of the library's authors joins the author block (structure.ts gathers the
 * paragraphs between the title and the first heading). In place. */
export function frontMatterRoles(regions: Region[], glyphs: readonly Glyph[], input: Pick<DevicePDFInput, 'title' | 'authors'>): void {
  const text = (r: Region) => joinLines(linesOf(glyphs.filter(g => centreIn(g, r.pt))).map(ln => lineText(ln, [])[0]));
  const title = input.title ? letters(input.title) : '';
  if (title && !regions.some(r => r.cls === 'title')) {
    const match = regions.filter(r => r.cls === 'heading').sort((a, b) => a.box[1] - b.box[1]).find(r => letters(text(r)) === title);
    if (match) match.cls = 'title';
  }
  const families = (input.authors ?? []).map(a => letters(a.trim().split(/\s+/).pop() ?? '')).filter(f => f.length >= 3);
  const top = regions.find(r => r.cls === 'title');
  if (!families.length || !top) return;
  const body = regions.filter(r => r.cls === 'abstract' || r.cls === 'paragraph').map(r => r.box[1]);
  const limit = body.length ? Math.min(...body) : Infinity;
  for (const r of regions) {
    if (r.cls !== 'heading' || r.box[1] < top.box[3] - 2 || r.box[1] > limit) continue;
    const t = text(r);
    if (/^\s*(\d+(\.\d+)*|[IVX]+\.?)\s|^\s*[A-Z]\.\s+(?![A-Z]\.)/.test(t)) continue; // a numbered section is a section (not an initial)
    const words = letters(t);
    if (families.some(f => words.includes(f))) r.cls = 'paragraph';
  }
}

/** Each formula's recognition (LaTeX and token probabilities) and its confidence; returns how many had none. */
function assignRecognitions(fs: Formula[], results: ({ latex: string; probs: number[] } | null)[] | null | undefined): number {
  let failures = 0;
  fs.forEach((f, i) => {
    const r = results?.[i];
    if (!r || typeof r.latex !== 'string' || !Array.isArray(r.probs)) { failures += 1; return; }
    // The reference keeps each token probability to five decimals before the gate reads it (texteller._batch).
    f.latex = r.latex; f.probs = r.probs.filter(Number.isFinite).map(v => Number(v.toFixed(5))); f.recognised = true;
    f.confidence = confidence(f.probs, f.display);
  });
  return failures;
}

/** The background recogniser's results, waited for (port revision 5); nothing to do for a host that recognises inline. */
export function settle(reading: Reading, host: DevicePDFHost): void {
  for (const { ticket, formulas } of reading.submissions.splice(0)) {
    let results: ({ latex: string; probs: number[] } | null)[] | null = null;
    try { results = host.collect!(ticket); } catch { reading.warnings.push('equations: Error'); reading.recognitionFailures += formulas.length; continue; }
    reading.recognitionFailures += assignRecognitions(formulas, results);
  }
}

/** The gate: Temml MathML for each recognised formula whose confidence passes. */
export function gate(reading: Reading): void {
  for (const id of reading.committed) {
    const f = reading.formulas.get(id)!;
    // A display's punctuation the recogniser could not see (displayPunctuation): after the formula, as LaTeXML sets it.
    if (f.trailing && f.latex && !f.transcribed && !/[.,;]\s*(\\end\{[a-z*]+\}\s*)?$/.test(f.latex)) f.latex = `${f.latex}${f.trailing}`;
    if (f.latex && f.confidence >= (f.display ? reading.displayGate : GATE)) {
      let math = renderMath(f.latex, f.display);
      // Port revision 5: the recogniser's LaTeXML-style rows and package commands, tidied when Temml refuses them as read.
      if (!math && reading.tidy) {
        const tidied = tidyLatex(f.latex);
        if (tidied !== f.latex && (math = renderMath(tidied, f.display))) f.latex = tidied;
      }
      if (math) { f.rendered = true; f.mathml = math; }
    }
  }
}

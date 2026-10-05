import MarkdownIt from 'markdown-it';
import mathpixPlugins from 'mathpix-markdown-it/lib/markdown/mathpix-markdown-plugins.js';
import { classes, el, elements, isMathToken, mathAttributeIsSafe, MATH_ELEMENTS, normalizeSpace, outText, parseHTML, render, textContent } from './html.ts';
import type { DomNode, OutNode } from './html.ts';
import { applyMathVariant } from './mathvariant.ts';
import { INDEX_FORMAT, LIMITS, MATH_OPTIONS } from './profile.ts';
import { boundedText, byteLength, check, CONTROL, excerpt, fail, ReaderRenderError } from './util.ts';

export interface ReaderIndex {
  format: string;
  title: string;
  headings: { id: string; level: number; title: string }[];
  blocks: { id: string; kind: string; text: string }[];
  equations: { id: string; block_id: string; latex: string; display: boolean; source_form: 'body' | 'environment' }[];
  figures: { id: string; block_id: string; asset_paths: string[]; caption: string; alt: string }[];
}
export interface ResolvedImage { path: string; width: number; height: number }
export interface RenderStats { equations: number; mathFallbacks: number; figures: number; blocks: number; links: number }
export interface RenderedDocument { bodyHTML: string; index: ReaderIndex; stats: RenderStats }
interface MathToken { type: string; latex: string; mathml: string; error: boolean; label: string }
type Child = OutNode | string;

const MATH_TYPES = ['inline_math', 'display_math', 'equation_math', 'equation_math_not_number'];
// Raw MathML/AsciiMath/chemistry input has no LaTeX source or needs SVG; it is
// shown as escaped source text instead of being interpreted.
const VERBATIM_TYPES = ['inline_mathML', 'display_mathML', 'ascii_math', 'smiles', 'smiles_inline'];
// MathJax keeps TeX definitions in module-level maps that outlive a document,
// and an Edge isolate serves many documents. Definitions are refused so no
// document can change how a later document's math is interpreted.
export const MACRO_DEFINITION = /\\(?:(?:re)?newcommand|providecommand|(?:re)?newenvironment|DeclareMathOperator|DeclarePairedDelimiter|Newextarrow|definecolor|newif|futurelet|global|[gex]?def|let)(?![A-Za-z])/;

// Removed with their content: active content, hidden provider sidecars and
// anything that would need SVG, another document or a network resource.
const DROP = new Set(['script', 'style', 'svg', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'textarea', 'select',
  'option', 'link', 'meta', 'base', 'template', 'noscript', 'audio', 'video', 'source', 'track', 'canvas', 'frame', 'frameset',
  'applet', 'title', 'head', 'xmp', 'plaintext', 'noembed', 'math', 'mathml', 'latex', 'asciimath', 'mathmlword', 'tsv',
  'csv', 'table-markdown', 'smiles', 'mjx-container', 'picture', 'map', 'area', 'dialog', 'portal']);
const FLOW = new Set(['div', 'p', 'section', 'article', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'table',
  'pre', 'figure', 'hr', 'img', 'center', 'details', 'summary', 'dl', 'dt', 'dd', 'header', 'footer', 'nav', 'aside',
  'main', 'figcaption', 'li', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th', 'caption']);
const INLINE_SAME = new Set(['em', 'i', 'strong', 'b', 'u', 's', 'sub', 'sup', 'code']);

function isHidden(node: DomNode): boolean {
  const names = classes(node);
  return names.includes('hidden') || names.includes('footnote-backref');
}
const skipped = (node: DomNode): boolean => node.type !== 'tag' || DROP.has(node.name) || isHidden(node);
const hasFlow = (node: DomNode): boolean => (node.children ?? []).some(child =>
  !skipped(child) && (FLOW.has(child.name) || hasFlow(child)));
const isBlank = (node: DomNode): boolean => node.type === 'text' ? !node.data.trim() : skipped(node);
const CONTROLS = new RegExp(CONTROL.source, 'g');
const cleanText = (text: string): string => text.toWellFormed().replace(CONTROLS, '').replace(/[\u2028\u2029]/g, ' ');
const normalized = normalizeSpace;
const hasContent = (children: Child[]): boolean => children.some(child => typeof child !== 'string' || child.trim());

export function safeHTTPS(value: string): string | null {
  if (value.length > 2048 || CONTROL.test(value) || /\s/.test(value)) return null;
  let url: URL;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.port) return null;
  return url.href.length <= 2048 ? url.href : null;
}

// Converts MathJax's MathML into the admitted vocabulary. Unknown MathML is
// not guessed at: the equation falls back to its visible LaTeX source.
class UnsupportedMath extends Error {}
function convertMath(mathml: string, display: boolean): { math: OutNode; tag: string | null } {
  const root = parseHTML(mathml, true);
  const top = (root.children ?? []).filter(node => !(node.type === 'text' && !node.data.trim()));
  if (top.length !== 1 || top[0].type !== 'tag' || top[0].name !== 'math') throw new UnsupportedMath();
  // WebKit has no mlabeledtr layout. A single equation number is placed
  // beside the math in HTML; multi-row numbers become a trailing cell.
  const outside = display && elements(root, node => node.name === 'mlabeledtr').length === 1;
  let tag: string | null = null;
  const convert = (node: DomNode, inToken: boolean): Child | null => {
    if (node.type === 'text') {
      if (inToken) return cleanText(node.data);
      if (!node.data.trim()) return null;
      throw new UnsupportedMath();
    }
    if (node.type !== 'tag') return null;
    const name = node.name;
    if (name === 'annotation' || name === 'annotation-xml' || name === 'mglyph') return null;
    if (name === 'merror') throw new UnsupportedMath();
    if (name === 'semantics' || name === 'maction') {
      const first = (node.children ?? []).find(child => child.type === 'tag');
      return first ? convert(first, false) : null;
    }
    const children = (list: DomNode[], token: boolean) =>
      list.map(child => convert(child, token)).filter((child): child is Child => child !== null && child !== '');
    if (name === 'mlabeledtr') {
      const cells = (node.children ?? []).filter(child => child.type === 'tag');
      if (!cells.length || cells.some(cell => cell.name !== 'mtd')) throw new UnsupportedMath();
      const label = normalized(textContent(cells[0]));
      if (!label || byteLength(label) > 64 || CONTROL.test(label)) throw new UnsupportedMath();
      const row = el('mtr', {}, children(cells.slice(1), false));
      if (outside) tag = label;
      else row.children.push(el('mtd', {}, [el('mspace', { width: '1em' }), el('mtext', {}, [label])]));
      return row;
    }
    if (!MATH_ELEMENTS.has(name)) throw new UnsupportedMath();
    const attribs: Record<string, string> = {};
    for (const [key, value] of Object.entries(node.attribs ?? {})) if (mathAttributeIsSafe(name, key, value)) attribs[key] = value;
    if (name === 'math') { if (display) attribs.display = 'block'; else delete attribs.display; }
    const converted = children(node.children ?? [], isMathToken(name));
    const variant = attribs.mathvariant;
    if ((name === 'mi' || name === 'mn') && variant && variant !== 'normal' && converted.every(child => typeof child === 'string')) {
      const mapped = applyMathVariant(converted.join(''), variant);
      if (mapped !== null) { delete attribs.mathvariant; return el(name, attribs, [mapped]); }
    }
    return el(name, attribs, converted);
  };
  const math = convert(top[0], false);
  if (!math || typeof math === 'string') throw new UnsupportedMath();
  return { math, tag };
}

function renderMathpixHTML(source: string): { html: string; side: MathToken[] } {
  // One synchronous section: Mathpix and MathJax keep per-document counters
  // in module state, which the plugin resets at the start of every parse.
  const md = new MarkdownIt({ html: false, linkify: false, typographer: false, breaks: false, maxNesting: 40 });
  md.use(mathpixPlugins.mathpixMarkdownPlugin, {
    outMath: { ...MATH_OPTIONS }, accessibility: null, copyToClipboard: false, enableFileLinks: false,
    centerImages: false, centerTables: false, parserErrors: 'show', mathDelimiterMode: 'strict',
    codeHighlight: { code: false, auto: false }, showPageBreaks: false, renderElement: {},
  });
  const side: MathToken[] = [];
  type Token = { type: string; content: string; mathData?: { mathml?: string; error?: unknown }; idLabels?: unknown };
  for (const type of MATH_TYPES) {
    md.renderer.rules[type] = (tokens: Token[], index: number) => {
      const token = tokens[index];
      side.push({ type: token.type, latex: String(token.content ?? ''), mathml: String(token.mathData?.mathml ?? ''),
        error: Boolean(token.mathData?.error), label: typeof token.idLabels === 'string' ? token.idLabels : '' });
      return `<span data-sr-math="${side.length - 1}"></span>`;
    };
  }
  for (const type of VERBATIM_TYPES) {
    md.renderer.rules[type] = (tokens: Token[], index: number) =>
      `<code>${String(tokens[index].content ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</code>`;
  }
  // The provider's parser logs TeX errors with document text. Rendering is
  // synchronous, so diagnostics are muted for exactly this section and never
  // reach hosted function logs.
  const methods = ['log', 'info', 'warn', 'error', 'debug'] as const;
  const saved = methods.map(name => console[name]);
  for (const name of methods) console[name] = () => {};
  try {
    const env = {};
    return { html: md.renderer.render(md.parse(source, env), md.options, env), side };
  } catch (error) {
    if (error instanceof ReaderRenderError) throw error;
    return fail('markdown_render_failed');
  } finally {
    methods.forEach((name, n) => { console[name] = saved[n]; });
  }
}

interface Context { blockID: string; inAnchor: boolean; lifted: DomNode[]; separator: ' ' | 'br' }

export function renderMathpixDocument(source: string, sourceDigest: string, resolveImage: (src: string) => ResolvedImage,
  titleFallback?: string): RenderedDocument {
  check(typeof source === 'string' && source.length > 0 && !source.includes('\u0000') && byteLength(source) <= LIMITS.sourceBytes, 'source_limit');
  check(/^[a-f0-9]{12}$/.test(sourceDigest), 'source_digest');
  check(!MACRO_DEFINITION.test(source), 'unsupported_macro_definition');
  const { html, side } = renderMathpixHTML(source);
  check(side.length <= LIMITS.equations, 'equation_limit');
  const dom = parseHTML(html);

  const blocks: { id: string; kind: string; node: OutNode }[] = [];
  const equations: ReaderIndex['equations'] = [];
  const figures: ReaderIndex['figures'] = [];
  const aliases = new Map<string, string>();
  const fragmentAnchors: { node: OutNode; target: string }[] = [];
  const usedMath = new Set<number>();
  const top: OutNode[] = [];
  const stats = { equations: 0, mathFallbacks: 0, figures: 0, blocks: 0, links: 0 };
  let titleID: string | null = null, lastHeading = '';

  const nextBlockID = () => { check(blocks.length < LIMITS.blocks, 'block_limit'); return `b-${sourceDigest}-${blocks.length + 1}`; };
  const contextFor = (blockID: string, separator: ' ' | 'br' = ' '): Context => ({ blockID, inAnchor: false, lifted: [], separator });
  function addBlock(kind: string, node: OutNode): OutNode {
    const id = node.attribs.id;
    check(id === `b-${sourceDigest}-${blocks.length + 1}` && node.attribs['data-reader-block'] === id, 'block_identity');
    node.attribs['data-reader-kind'] = kind;
    blocks.push({ id, kind, node });
    return node;
  }
  const alias = (old: string | undefined, id: string) => { if (old && old.length <= 512 && !aliases.has(old)) aliases.set(old, id); };

  function equation(index: number, context: Context): OutNode | null {
    check(Number.isSafeInteger(index) && index < side.length && !usedMath.has(index), 'math_placeholder');
    usedMath.add(index);
    const token = side[index];
    if (!token.latex.trim()) return null;
    check(equations.length < LIMITS.equations, 'equation_limit');
    const latex = boundedText(token.latex, LIMITS.textBytes, 'equation_source');
    const display = token.type !== 'inline_math';
    const id = `e-${sourceDigest}-${equations.length + 1}`;
    equations.push({ id, block_id: context.blockID, latex, display,
      source_form: token.type === 'equation_math' || token.type === 'equation_math_not_number' ? 'environment' : 'body' });
    alias(token.label, id);
    const names = ['reader-equation', display ? 'reader-display' : 'reader-inline'];
    let children: Child[];
    try {
      if (token.error || !token.mathml) throw new UnsupportedMath();
      const converted = convertMath(token.mathml, display);
      children = [converted.math];
      if (converted.tag) { names.push('reader-tagged'); children.push(el('span', { class: 'reader-tag' }, [converted.tag])); }
    } catch (error) {
      if (!(error instanceof UnsupportedMath)) throw error;
      stats.mathFallbacks++;
      names.push('reader-math-fallback');
      children = [display ? latex : `\\(${latex}\\)`];
    }
    return el('span', { id, class: names.join(' '), 'data-reader-equation': id, 'data-latex': latex }, children);
  }

  function anchor(node: DomNode, context: Context): Child[] {
    const href = node.attribs?.href ?? '';
    const children = inline(node.children ?? [], { ...context, inAnchor: true });
    if (context.inAnchor || !hasContent(children)) return children;
    if (href.startsWith('#') && href.length > 1) {
      const out = el('a', {}, children);
      fragmentAnchors.push({ node: out, target: href.slice(1) });
      return [out];
    }
    const url = safeHTTPS(href);
    if (!url) return children; // non-HTTPS, relative and script URLs keep only their text
    stats.links++;
    return [el('a', { href: url, rel: 'noopener noreferrer' }, children)];
  }

  // Phrasing conversion. Flow content inside phrasing contexts is flattened;
  // images are lifted out and become figures after the current block.
  function inline(nodes: DomNode[], context: Context): Child[] {
    const out: Child[] = [];
    for (const node of nodes) {
      if (node.type === 'text') { const text = cleanText(node.data); if (text) out.push(text); continue; }
      if (skipped(node)) continue;
      const name = node.name;
      if (node.attribs?.id) alias(node.attribs.id, context.blockID);
      if (name === 'span' && 'data-sr-math' in node.attribs) {
        const value = node.attribs['data-sr-math'];
        check(/^\d{1,6}$/.test(value) && (node.children ?? []).length === 0, 'math_placeholder');
        const math = equation(Number(value), context);
        if (math) out.push(math);
      } else if (name === 'img') context.lifted.push(node);
      else if (name === 'a') out.push(...anchor(node, context));
      else if (name === 'br') out.push(el('br'));
      else if (INLINE_SAME.has(name) || name === 'del' || name === 'strike') {
        const children = inline(node.children ?? [], context);
        if (children.length) out.push(el(INLINE_SAME.has(name) ? name : 's', {}, children));
      } else if (FLOW.has(name)) {
        const children = inline(node.children ?? [], context);
        if (!hasContent(children)) continue;
        if (hasContent(out)) out.push(context.separator === 'br' ? el('br') : ' ');
        out.push(...children);
      } else out.push(...inline(node.children ?? [], context)); // other wrappers are unwrapped
    }
    return out;
  }

  function liftFigures(lifted: DomNode[]): void { for (const image of lifted) emitFloat(image); }

  function emitParagraph(nodes: DomNode[], className?: string, lines = false): void {
    const id = nextBlockID(), context = contextFor(id);
    let children: Child[] = [];
    if (lines) {
      // Author blocks: each provider line (span) becomes one visual line.
      for (const node of nodes) {
        for (const line of node.type === 'tag' && node.name === 'p' ? node.children ?? [] : [node]) {
          const converted = inline([line], context);
          if (!hasContent(converted)) continue;
          if (children.length) children.push(el('br'));
          children.push(...converted);
        }
      }
    } else children = inline(nodes, context);
    if (hasContent(children)) {
      const significant = children.filter(child => typeof child !== 'string' || child.trim());
      const only = significant.length === 1 && typeof significant[0] !== 'string' ? significant[0] : null;
      const kind = only?.attribs['data-reader-equation'] && only.attribs.class.includes('reader-display') ? 'equation' : 'paragraph';
      top.push(addBlock(kind, el('p', { id, 'data-reader-block': id, ...(className ? { class: className } : {}) }, children)));
    }
    liftFigures(context.lifted);
  }

  function emitHeading(node: DomNode, level: number, title: boolean): void {
    const id = nextBlockID(), context = contextFor(id, 'br');
    const children = inline([node], context);
    if (hasContent(children)) {
      alias(node.attribs?.id, id);
      top.push(addBlock('heading', el(`h${level}`, { id, 'data-reader-block': id }, children)));
      if (title) titleID = id;
      lastHeading = normalized(textContent(node));
    }
    liftFigures(context.lifted);
  }

  // Provider floats: images become one figure block (≤16 images, one
  // caption); tables become table blocks; anything else is ordinary flow.
  function emitFloat(container: DomNode): void {
    const images = container.name === 'img' ? [container] : elements(container, node => node.name === 'img' && !skippedAncestor(node, container));
    const tables = elements(container, node => node.name === 'table' && !ancestorNamed(node.parent, 'table', container) && !skippedAncestor(node, container));
    const captions = elements(container, node => (node.name === 'figcaption' || classes(node).some(name => name.startsWith('caption'))) &&
      !captionAncestor(node, container) && !skippedAncestor(node, container));
    if (images.length) {
      check(figures.length < LIMITS.figures, 'figure_limit');
      check(images.length <= LIMITS.imagesPerFigure, 'figure_images');
      const id = nextBlockID(), context = contextFor(id, 'br');
      let caption = inline(captions, context);
      if (!hasContent(caption)) {
        const title = images.map(image => image.attribs.title ?? '').find(text => text.trim());
        caption = title ? [cleanText(title)] : [];
      }
      const captionText = normalized(outText(el('span', {}, caption)));
      const provided = normalized(cleanText(images.map(image => image.attribs.alt ?? '').find(text => text.trim()) ?? ''));
      const alt = excerpt(provided || firstSentence(captionText) || `Figure ${figures.length + 1}`, 300);
      const paths: string[] = [];
      const children: Child[] = images.map(image => {
        const resolved = resolveImage(image.attribs.src ?? '');
        if (!paths.includes(resolved.path)) paths.push(resolved.path);
        return el('img', { src: resolved.path, alt, width: String(resolved.width), height: String(resolved.height) });
      });
      if (hasContent(caption)) children.push(el('figcaption', {}, caption));
      if (container.attribs?.id) alias(container.attribs.id, id);
      top.push(addBlock('figure', el('figure', { id, 'data-reader-block': id, 'data-reader-figure': id }, children)));
      figures.push({ id, block_id: id, asset_paths: paths, caption: excerpt(captionText, LIMITS.textBytes), alt });
      // Any image nested in these tables already belongs to this figure.
      for (const table of tables) emitTable(table, [], container, false);
      return;
    }
    if (tables.length) {
      tables.forEach((table, n) => emitTable(table, n === tables.length - 1 ? captions : [], container));
      return;
    }
    emitFlow(container.children ?? []);
  }

  function tableRows(table: DomNode, context: Context): OutNode[] {
    const rows: OutNode[] = [];
    const visit = (node: DomNode) => {
      for (const child of node.children ?? []) {
        if (skipped(child)) continue;
        if (child.name === 'tr') {
          const cells = (child.children ?? []).filter(cell => !skipped(cell) && (cell.name === 'td' || cell.name === 'th')).map(cell => {
            const attribs: Record<string, string> = {};
            for (const key of ['colspan', 'rowspan']) {
              const value = cell.attribs?.[key];
              if (value && /^[1-9][0-9]{0,2}$/.test(value) && value !== '1') attribs[key] = value;
            }
            return el(cell.name, attribs, inline(cell.children ?? [], { ...context, separator: 'br' }));
          });
          rows.push(el('tr', {}, cells));
        } else if (child.name === 'thead' || child.name === 'tbody' || child.name === 'tfoot') visit(child);
      }
    };
    visit(table);
    return rows;
  }

  function emitTable(table: DomNode, captions: DomNode[], container: DomNode | null, lift = true): void {
    const id = nextBlockID(), context = contextFor(id, 'br');
    const rows = tableRows(table, context);
    const caption = inline(captions, context);
    const children: Child[] = [el('table', {}, [el('tbody', {}, rows)])];
    if (hasContent(caption)) {
      const node = el('p', { class: 'reader-caption' }, caption);
      if (container && precedes(captions[0], table, container)) children.unshift(node); else children.push(node);
    }
    alias(table.attribs?.id, id);
    top.push(addBlock('table', el('div', { id, class: 'reader-table', 'data-reader-block': id }, children)));
    if (lift) liftFigures(context.lifted);
  }

  // Top-level list items are reading blocks; nested lists, paragraphs, code
  // and tables stay inside their item without becoming separate blocks.
  function list(node: DomNode, className?: string): void {
    const lifted: DomNode[] = [];
    const wrapper = convertList(node, null, lifted);
    if (className) wrapper.attribs.class = className;
    if (wrapper.children.length) top.push(wrapper);
    liftFigures(lifted);
  }
  function convertList(node: DomNode, parent: Context | null, lifted: DomNode[]): OutNode {
    const ordered = node.name === 'ol';
    const attribs: Record<string, string> = {};
    if (ordered && /^-?[0-9]{1,6}$/.test(node.attribs?.start ?? '') && node.attribs.start !== '1') attribs.start = node.attribs.start;
    const wrapper = el(ordered ? 'ol' : 'ul', attribs, []);
    for (const item of node.children ?? []) {
      if (skipped(item) || item.name !== 'li') continue;
      const id = parent ? '' : nextBlockID();
      const context = parent ?? { ...contextFor(id, 'br'), lifted };
      const children: Child[] = [];
      let custom = item.attribs?.['data-custom-marker'] === 'true';
      const parts: DomNode[] = [];
      for (const child of item.children ?? []) {
        if (child.type === 'tag' && classes(child).includes('li_level')) {
          custom = true;
          const marker = normalized(cleanText(textContent(child)));
          if (marker) children.push(el('span', { class: 'reader-marker' }, [marker]));
        } else parts.push(child);
      }
      children.push(...itemContent(parts, context, lifted));
      const li = el('li', parent ? {} : { id, 'data-reader-block': id }, children);
      if (custom) li.attribs.class = 'reader-custom-marker';
      if (parent) wrapper.children.push(li);
      else { alias(item.attribs?.id, id); wrapper.children.push(addBlock('list', li)); }
    }
    return wrapper;
  }
  function itemContent(nodes: DomNode[], context: Context, lifted: DomNode[]): Child[] {
    const out: Child[] = [];
    let run: DomNode[] = [];
    const flush = () => {
      const converted = inline(run, context);
      run = [];
      if (hasContent(converted)) out.push(...(out.length ? [el('p', {}, converted)] : converted));
    };
    for (const node of nodes) {
      if (skipped(node) || node.name === 'img' || !(FLOW.has(node.name) || hasFlow(node))) { run.push(node); continue; }
      flush();
      if (node.name === 'ul' || node.name === 'ol') out.push(convertList(node, context, lifted));
      else if (node.name === 'pre') out.push(el('pre', {}, [el('code', {}, [cleanText(textContent(node))])]));
      else if (node.name === 'table') out.push(el('table', {}, [el('tbody', {}, tableRows(node, context))]));
      else if (hasFlow(node)) out.push(...itemContent(node.children ?? [], context, lifted));
      else { run.push(node); flush(); }
    }
    flush();
    return out;
  }

  function emitCode(node: DomNode): void {
    const text = cleanText(textContent(node));
    if (!text.trim()) return;
    const id = nextBlockID();
    top.push(addBlock('code', el('pre', { id, 'data-reader-block': id }, [el('code', {}, [text])])));
  }

  function emitFootnotes(section: DomNode): void {
    for (const node of elements(section, n => (n.name === 'ol' || n.name === 'ul') && !ancestorNamed(n.parent, 'li', section))) {
      const lifted: DomNode[] = [];
      const wrapper = convertList(node, null, lifted);
      wrapper.attribs.class = 'reader-footnotes';
      if (wrapper.children.length) top.push(el('hr'), wrapper);
      liftFigures(lifted);
    }
  }

  // Segment provider flow into reading blocks. Every top-level output node is
  // a block, a list whose items are blocks, or a rule, so prose never sits
  // outside a block and blocks never nest.
  function emitFlow(nodes: DomNode[], className?: string): void {
    let run: DomNode[] = [];
    const flush = () => { if (run.some(node => !isBlank(node))) emitParagraph(run, className); run = []; };
    for (const node of nodes) {
      if (node.type === 'text') { run.push(node); continue; }
      if (skipped(node)) continue;
      const name = node.name, names = classes(node);
      if (!FLOW.has(name) && !hasFlow(node)) { run.push(node); continue; }
      flush();
      if (/^h[1-6]$/.test(name)) {
        let level = Number(name.slice(1));
        const title = titleID === null && (names.includes('main-title') || node.attribs.type === 'title' || level === 1);
        if (title) level = 1; else if (level === 1 || names.includes('abstract_head')) level = 2;
        emitHeading(node, level, title);
      } else if (names.includes('author')) emitParagraph(node.children ?? [], 'reader-authors', true);
      else if (names.includes('abstract')) emitFlow(node.children ?? [], 'reader-abstract');
      else if (name === 'figure' || name === 'img' || names.includes('table') || names.includes('figure')) emitFloat(node);
      else if (name === 'table') emitTable(node, [], null);
      else if (name === 'ul' || name === 'ol') list(node, /^(?:[0-9.]+\s*)?(?:references|bibliography)$/i.test(lastHeading) ? 'reader-references' : undefined);
      else if (name === 'pre') emitCode(node);
      else if (name === 'section' && names.includes('footnotes')) emitFootnotes(node);
      else if (name === 'hr') { if (!names.includes('footnotes-sep')) top.push(el('hr')); }
      else if (hasFlow(node)) emitFlow(node.children ?? [], className);
      else emitParagraph([node], className);
    }
    flush();
  }
  emitFlow(dom.children ?? []);

  // The provider's \title is the document title; otherwise an explicitly
  // supplied fallback (for example catalog metadata) becomes a leading H1.
  if (titleID === null) {
    const fallback = normalized(cleanText(titleFallback ?? ''));
    check(fallback.length > 0, 'document_title');
    const id = `b-${sourceDigest}-0`;
    const node = el('h1', { id, 'data-reader-block': id, 'data-reader-kind': 'heading' }, [fallback]);
    blocks.unshift({ id, kind: 'heading', node });
    top.unshift(node);
    titleID = id;
  }

  // Fragment links resolve to generated IDs or become plain text.
  const generated = new Set([...blocks.map(block => block.id), ...equations.map(item => item.id)]);
  const unresolved = new Set<OutNode>();
  for (const { node, target } of fragmentAnchors) {
    let decoded = target;
    try { decoded = decodeURIComponent(target); } catch { /* keep the raw form */ }
    const id = aliases.get(target) ?? aliases.get(decoded);
    if (id && generated.has(id)) node.attribs.href = `#${id}`; else unresolved.add(node);
  }
  const unwrap = (node: Child): Child[] => {
    if (typeof node === 'string') return [node];
    node.children = node.children.flatMap(unwrap);
    return unresolved.has(node) ? node.children : [node];
  };
  const body = top.flatMap(unwrap);
  // Index equations in document order. Registration follows the provider's
  // token order, which can differ from the rendered order (e.g. a table
  // caption rendered before the cells it was parsed after).
  const order = new Map<string, number>();
  const collect = (node: Child) => {
    if (typeof node === 'string') return;
    const id = node.attribs['data-reader-equation'];
    if (id && !order.has(id)) order.set(id, order.size);
    node.children.forEach(collect);
  };
  body.forEach(collect);
  equations.sort((a, b) => (order.get(a.id) ?? Number.MAX_SAFE_INTEGER) - (order.get(b.id) ?? Number.MAX_SAFE_INTEGER));

  const titleBlock = blocks.find(block => block.id === titleID)!;
  const title = excerpt(normalized(outText(titleBlock.node)), LIMITS.headingBytes);
  check(title.length > 0, 'document_title');
  const headings = blocks.filter(block => block.kind === 'heading' && block.id !== titleID)
    .map(block => ({ id: block.id, level: Number(block.node.name.slice(1)), title: excerpt(normalized(outText(block.node)), LIMITS.headingBytes) }))
    .filter(heading => heading.title.length > 0);
  check(headings.length <= LIMITS.headings, 'heading_limit');
  const index: ReaderIndex = {
    format: INDEX_FORMAT, title, headings,
    blocks: blocks.map(block => ({ id: block.id, kind: block.kind, text: excerpt(normalized(outText(block.node)), LIMITS.textBytes) })),
    equations, figures,
  };
  Object.assign(stats, { equations: equations.length, figures: figures.length, blocks: blocks.length });
  return { bodyHTML: body.map(node => render(node)).join('\n'), index, stats };
}

function firstSentence(text: string): string {
  const match = /^(.{40,240}?[.!?])(?:\s|$)/.exec(text);
  return (match ? match[1] : text.slice(0, 240)).trim();
}
function ancestorNamed(node: DomNode | null, name: string, stop: DomNode): boolean {
  for (let current = node; current && current !== stop; current = current.parent) if (current.name === name) return true;
  return false;
}
function skippedAncestor(node: DomNode, stop: DomNode): boolean {
  for (let current = node.parent; current && current !== stop; current = current.parent) if (skipped(current)) return true;
  return false;
}
function captionAncestor(node: DomNode, stop: DomNode): boolean {
  for (let current = node.parent; current && current !== stop; current = current.parent) {
    if (current.name === 'figcaption' || classes(current).some(name => name.startsWith('caption'))) return true;
  }
  return false;
}
function precedes(a: DomNode, b: DomNode, root: DomNode): boolean {
  let seen: 'a' | 'b' | null = null;
  walkUntil(root, node => { if (node === a) seen = 'a'; else if (node === b) seen = 'b'; return seen !== null; });
  return seen === 'a';
}
function walkUntil(node: DomNode, visit: (node: DomNode) => boolean): boolean {
  if (visit(node)) return true;
  for (const child of node.children ?? []) if (walkUntil(child, visit)) return true;
  return false;
}

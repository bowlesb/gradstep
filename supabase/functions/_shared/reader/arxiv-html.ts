// Official arXiv HTML -> the existing inert reader vocabulary. No network, OCR,
// source scripts/styles, or PDF handling. Acquisition supplies every image.
import { classes, el, elements, HTML_SUFFIX, htmlPrefix, isMathToken, MATH_ELEMENTS, mathAttributeIsSafe,
  normalizeSpace, outText, parseHTML, render, serialize, textContent, walk, type DomNode, type OutNode } from './html.ts';
import { INDEX_FORMAT, LIMITS } from './profile.ts';
import { boundedText, check, excerpt, sha256Hex, utf8 } from './util.ts';
import type { ReaderIndex } from './render.ts';

export const ARXIV_RENDERER_ID = 'gradstep-arxiv-html-mathml-v2';
export const ARXIV_SOURCE_KIND = 'arxiv-html';
export const ARXIV_PROVENANCE_FORMAT = 'arxiv-html-reader-provenance-v2';
export const ARXIV_RENDERER_REVISION = 2;
export const ARXIV_ID = /^(?:\d{4}\.\d{4,5}|[a-z][a-z.-]+(?:\.[A-Z]{2})?\/\d{7})$/;
export type HTMLImage = { path: string; width: number; height: number };
type Child = OutNode | string;
const has = (n: DomNode, cls: string) => classes(n).includes(cls);
const children = (n: DomNode) => n.children ?? [];
const active = new Set(['script', 'style', 'link', 'meta', 'form', 'input', 'button', 'textarea', 'iframe', 'embed', 'audio', 'video']);

export function arxivHTMLURL(sourceID: string, revision: number): string {
  check(ARXIV_ID.test(sourceID) && Number.isSafeInteger(revision) && revision >= 1 && revision <= 2147483647, 'arxiv_identity');
  return `https://arxiv.org/html/${sourceID}v${revision}`;
}

export function arxivAssetURL(reference: string, sourceURL: string): string {
  let url: URL;
  try { url = new URL(reference, sourceURL); } catch { throw new Error('arxiv_asset_url'); }
  const source = new URL(sourceURL);
  const root = source.pathname + '/';
  check(url.origin === 'https://arxiv.org' && source.origin === url.origin && !url.username && !url.password &&
    !url.port && !url.search && !url.hash && url.pathname.startsWith(root) && !/%/.test(url.pathname) &&
    /\.(?:png|jpe?g|svg)$/i.test(url.pathname) && url.href.length <= 2048, 'arxiv_asset_url');
  return url.href;
}

/** LaTeXML marks what it could not convert (an undefined macro such as `\\pdfauthor`) with `ltx_ERROR`; these are
 * dropped and counted, and the paper still reads (2026-10-14: a paper with 288 such preamble macros was refused
 * outright). Beyond this many the conversion is not trusted at all. */
export const CONVERSION_ERROR_LIMIT = 1000;
function article(source: string): { root: DomNode; dropped: number } {
  check(utf8(source).length <= LIMITS.sourceBytes && source.length > 0, 'source_limit');
  const root = parseHTML(source);
  const papers = elements(root, n => n.name === 'article' && has(n, 'ltx_document'));
  check(papers.length === 1, 'arxiv_article');
  const ids = new Set<string>(), errors: DomNode[] = [];
  walk(papers[0], n => {
    if (n.attribs?.id) { check(!ids.has(n.attribs.id), 'arxiv_duplicate_id'); ids.add(n.attribs.id); }
    if (has(n, 'ltx_ERROR') || has(n, 'ltx_error')) errors.push(n);
  });
  check(errors.length <= CONVERSION_ERROR_LIMIT, 'arxiv_conversion_error');
  for (const n of errors) { const parent = n.parent; if (parent?.children) parent.children = parent.children.filter(c => c !== n); }
  return { root: papers[0], dropped: errors.length };
}

/** Only the paper's content assets, never logos, styles or PDF object fallbacks. */
export function arxivHTMLAssets(source: string, sourceURL: string): string[] {
  // Exactly the images the compiled reader references (a dry compile with placeholder admissions), so acquisition,
  // asset coverage and provenance agree; a graphic the reader leaves out is never fetched. Structural refusals surface
  // here, before any image is downloaded.
  const placeholder = { path: `assets/${'0'.repeat(64)}.png`, width: 1, height: 1 };
  const assets = convertArxivHTML(source, sourceURL, () => placeholder).imageURLs.filter(url => !url.startsWith('#'));
  check(assets.length <= LIMITS.archiveImages, 'image_limit');
  return assets;
}

/** Inline vectors are source bytes, never remote asset URLs. The canonical
 * serialization is hashed in provenance before the device SVG admission. */
export function arxivInlineImages(source: string, sourceURL: string): Map<string, string> {
  // Exactly the pictures the compiled reader references (a dry compile), as for raster assets.
  const placeholder = { path: `assets/${'0'.repeat(64)}.png`, width: 1, height: 1 };
  const wanted = new Set(convertArxivHTML(source, sourceURL, () => placeholder).imageURLs.filter(url => url.startsWith('#')).map(url => url.slice(1)));
  const result = new Map<string, string>();
  for (const n of elements(article(source).root, n => n.name === 'svg')) {
    const id = n.attribs.id;
    if (typeof id !== 'string' || !wanted.has(id)) continue;
    check(/^[A-Za-z_][A-Za-z0-9_.:-]{0,199}$/.test(id) && !nearest(n, 'svg') && !nearest(n, 'math'), 'arxiv_inline_svg');
    check(!n.attribs.xmlns || n.attribs.xmlns === 'http://www.w3.org/2000/svg', 'arxiv_inline_svg');
    const xml = serialize(svgTextLabels({ ...n, attribs: { ...n.attribs, xmlns: 'http://www.w3.org/2000/svg' } }));
    result.set('#' + id, xml);
  }
  check(result.size === wanted.size, 'arxiv_inline_svg');
  check(result.size <= LIMITS.archiveImages, 'image_limit');
  return result;
}

/** LaTeXML draws TikZ node labels as `foreignObject` HTML, which the device SVG admission refuses. Each label becomes
 * SVG text centred in the label's box (its flip undone), so the diagram keeps its words; placement is best effort. */
function svgTextLabels(n: DomNode): DomNode {
  if (n.type !== 'tag') return n;
  if (n.name === 'foreignObject') {
    const width = Number(n.attribs.width) || 0, height = Number(n.attribs.height) || 0;
    const size = /font-size:\s*([\d.]+)(pt|px)/.exec(n.attribs.style ?? '');
    const fontSize = size ? (size[2] === 'pt' ? Number(size[1]) * 4 / 3 : Number(size[1])) : 13;
    const label: DomNode = { type: 'text', data: normalizeSpace(textContent(n)), name: '', attribs: {}, children: [], parent: null };
    const text: DomNode = { type: 'tag', name: 'text', attribs: { x: String(width / 2), y: String(height / 2), 'text-anchor': 'middle',
      'dominant-baseline': 'central', 'font-size': String(Math.round(fontSize * 100) / 100), transform: `matrix(1 0 0 -1 0 ${height})` },
      children: [label], parent: null, data: '' };
    return { type: 'tag', name: 'g', attribs: n.attribs.transform ? { transform: n.attribs.transform } : {}, children: [text], parent: null, data: '' };
  }
  return { ...n, children: (n.children ?? []).map(svgTextLabels) };
}

export function convertArxivHTML(source: string, sourceURL: string, resolveImage: (url: string) => HTMLImage): {
  index: ReaderIndex; html: string; imageURLs: string[];
} {
  const { root, dropped } = article(source);
  check(/^https:\/\/arxiv\.org\/html\/.+v[1-9][0-9]*$/.test(sourceURL), 'arxiv_identity');
  const digest = sha256Hex(utf8(`${ARXIV_RENDERER_REVISION}\n${source}`)).slice(0, 12);
  const blocks: { id: string; kind: string; node: OutNode }[] = [], top: OutNode[] = [];
  let omittedGraphics = 0;
  /** Math carried by a picture (drawn inside it or left out with it) rather than rendered as an equation. */
  const skippedMath = new Set<DomNode>();
  /** A paragraph whose only content is one graphic (LaTeXML's unwrapped \\includegraphics): a figure, not text. */
  const loneImage = (n: DomNode): boolean => {
    let images = 0, other = false;
    const visit = (c: DomNode) => {
      if (c.type === 'text') { if (c.data.trim()) other = true; return; }
      if (c.type !== 'tag') return;
      if (['img', 'object', 'svg'].includes(c.name)) { images += 1; return; }
      if (!['span', 'a', 'div', 'p'].includes(c.name)) { other = true; return; }
      children(c).forEach(visit);
    };
    children(n).forEach(visit);
    return images === 1 && !other;
  };
  const equations: ReaderIndex['equations'] = [], figures: ReaderIndex['figures'] = [];
  const usedMath = new Set<DomNode>();
  const aliases = new Map<string, string>(), links: { node: OutNode; target: string }[] = [];
  const imageURLs = new Set<string>();
  const figureImages = new Map<string, OutNode[]>();
  const bind = (n: DomNode, id: string) => { if (n.attribs?.id) aliases.set(n.attribs.id, id); };
  const nextID = () => { check(blocks.length < LIMITS.blocks, 'block_limit'); return `b-${digest}-${blocks.length + 1}`; };
  function block(n: DomNode, name: string, kind: string, make: (id: string) => Child[], attrs: Record<string, string> = {}): OutNode {
    const id = nextID();
    const out = el(name, { ...attrs, id, 'data-reader-block': id, 'data-reader-kind': kind });
    blocks.push({ id, kind, node: out }); bind(n, id);
    out.children = make(id);
    return out;
  }
  function mathNode(n: DomNode): Child[] {
    if (n.type === 'text') return n.data.trim() || isMathToken(n.parent?.name ?? '') ? [n.data] : [];
    if (n.name === 'annotation' || n.name === 'annotation-xml') return [];
    if (n.name === 'a' || n.name === 'span') return children(n).flatMap(mathNode);
    if (n.name === 'semantics') {
      const presentation = children(n).filter(c => c.type === 'tag' && !['annotation', 'annotation-xml'].includes(c.name));
      check(presentation.length === 1, 'arxiv_math_semantics');
      return mathNode(presentation[0]);
    }
    check(MATH_ELEMENTS.has(n.name) && n.name !== 'math', 'arxiv_math_element');
    const attrs: Record<string, string> = {};
    for (const [key, value] of Object.entries(n.attribs ?? {})) {
      if (['class', 'id', 'intent', 'alttext', 'xref', 'xmlns'].includes(key)) continue;
      if (key === 'style') {
        // LaTeXML mirrors a few presentation attributes as CSS. Never retain
        // source CSS; translate only this finite scalar vocabulary.
        for (const declaration of value.split(';').map(v => v.trim()).filter(Boolean)) {
          const match = /^(width|height|depth|font-size|--ltx-fg-color|--ltx-bg-color):\s*([A-Za-z0-9 .%#+-]+)$/.exec(declaration);
          check(match, 'arxiv_math_style');
          const attr = match[1] === 'font-size' ? 'mathsize' : match[1] === '--ltx-fg-color' ? 'mathcolor'
            : match[1] === '--ltx-bg-color' ? 'mathbackground' : match[1];
          check(mathAttributeIsSafe(n.name, attr, match[2]), 'arxiv_math_style'); attrs[attr] = match[2];
        }
        continue;
      }
      check(mathAttributeIsSafe(n.name, key, value), 'arxiv_math_attribute'); attrs[key] = value;
    }
    return [el(n.name, attrs, children(n).flatMap(mathNode))];
  }
  function equation(n: DomNode, owner: string, forceDisplay = false): OutNode {
    check(!usedMath.has(n), 'arxiv_math_duplicate'); usedMath.add(n);
    const annotations = elements(n, c => c.name === 'annotation' && c.attribs.encoding === 'application/x-tex');
    const latex = boundedText(n.attribs.alttext ?? (annotations.length === 1 ? textContent(annotations[0]) : ''), LIMITS.textBytes, 'arxiv_math_source');
    check(latex.trim().length > 0 && equations.length < LIMITS.equations, 'arxiv_math_source');
    if (annotations.length) check(annotations.length === 1 && normalizeSpace(textContent(annotations[0])) === normalizeSpace(latex), 'arxiv_math_mismatch');
    const display = forceDisplay || n.attribs.display === 'block';
    const id = `e-${digest}-${equations.length + 1}`; bind(n, id);
    const form = /^\s*\\begin\{(?:equation\*?|align\*?|gather\*?|multline\*?)\}/.test(latex) ? 'environment' : 'body';
    check(form !== 'environment' || display, 'arxiv_math_source');
    equations.push({ id, block_id: owner, latex, display, source_form: form });
    const math = el('math', display ? { display: 'block' } : {}, children(n).flatMap(mathNode));
    check(math.children.length > 0, 'arxiv_math_empty');
    return el('span', { id, 'data-reader-equation': id, 'data-latex': latex,
      class: `reader-equation ${display ? 'reader-display' : 'reader-inline'}` }, [math]);
  }
  function inline(n: DomNode, owner: string, inAnchor = false, forceDisplay = false): Child[] {
    if (n.type === 'text') return [n.data];
    if (n.type === 'comment') return [];
    check(n.type === 'tag' || active.has(n.name), 'arxiv_node');
    if (active.has(n.name)) return [];
    bind(n, owner);
    if (n.name === 'math') return [equation(n, owner, forceDisplay)];
    if (['svg', 'img', 'object'].includes(n.name) && figureImages.has(owner)) return [figureImage(n, owner, true)];
    // A graphic inside running text outside a figure (an affiliation logo, an inline TikZ mark): the reader has no
    // inline-image vocabulary there, so it is left out and counted in the closing note rather than refusing the paper.
    if (['svg', 'img', 'object'].includes(n.name)) {
      omittedGraphics += 1; for (const m of elements(n, c => c.name === 'math')) skippedMath.add(m); return [];
    }
    check(!['table', 'figure'].includes(n.name), 'arxiv_nested_content');
    const content = () => children(n).flatMap(c => inline(c, owner, inAnchor || n.name === 'a', forceDisplay));
    if (n.name === 'br') return [el('br')];
    if (n.name === 'a') {
      if (inAnchor) return content();
      const href = n.attribs.href ?? '';
      let target: URL | null = null;
      try { target = new URL(href, sourceURL); } catch { /* preserve inert text */ }
      const node = el('a', {}, content());
      if (target && target.origin === new URL(sourceURL).origin && target.pathname === new URL(sourceURL).pathname && target.hash) {
        let fragment: string; try { fragment = decodeURIComponent(target.hash.slice(1)); } catch { throw new Error('arxiv_fragment'); }
        links.push({ node, target: fragment }); return [node];
      }
      if (target && ['https:', 'http:'].includes(target.protocol) && !target.username && !target.password && !target.port) {
        target.protocol = 'https:'; node.attribs = { href: target.href, rel: 'noopener noreferrer' }; return [node];
      }
      return node.children;
    }
    const name = ['em', 'i', 'strong', 'b', 'u', 's', 'sub', 'sup', 'code'].includes(n.name) ? n.name
      : has(n, 'ltx_font_bold') ? 'strong' : has(n, 'ltx_font_italic') ? 'em' : null;
    const result = content();
    // Inline wrappers have no arbitrary attributes; the reader owns its CSS.
    return name ? [el(name, {}, result)] : ['p', 'div', 'li', 'tr'].includes(n.name) ? [...result, el('br')] : result;
  }
  function table(n: DomNode, owner: string): OutNode {
    bind(n, owner);
    const rows = elements(n, c => c.name === 'tr' && nearest(c, 'table') === n);
    return el('table', {}, [el('tbody', {}, rows.map(row => {
      bind(row, owner);
      return el('tr', {}, children(row).filter(c => ['td', 'th'].includes(c.name)).map(cell => {
        bind(cell, owner);
        const attrs: Record<string, string> = {};
        for (const key of ['rowspan', 'colspan']) if (cell.attribs[key]) {
          check(/^[1-9][0-9]{0,2}$/.test(cell.attribs[key]), 'arxiv_table_span'); attrs[key] = cell.attribs[key];
        }
        return el(cell.name, attrs, children(cell).flatMap(c => cellContents(c, owner)));
      }));
    }))]);
  }
  function cellContents(n: DomNode, owner: string): Child[] {
    if (n.type === 'text' || n.type === 'comment') return inline(n, owner);
    // HTML tables nested inside a cell express a panel's row layout. Flatten
    // only that layout to line/column separators; retain every cell and math.
    if (n.name === 'table' || elements(n, c => c !== n && c.name === 'table').length) {
      bind(n, owner);
      return children(n).flatMap(c => cellContents(c, owner));
    }
    if (['tbody', 'thead', 'tfoot', 'tr', 'td', 'th'].includes(n.name)) {
      bind(n, owner);
      return [...children(n).flatMap(c => cellContents(c, owner)), ...(n.name === 'tr' ? [el('br')] : [' '])];
    }
    return inline(n, owner);
  }
  function tableContents(n: DomNode, owner: string): Child[] {
    if (n.type === 'text') return [n.data];
    if (n.type === 'comment' || active.has(n.name)) return [];
    bind(n, owner);
    if (n.name === 'table') return [table(n, owner)];
    if (n.name === 'math') return [equation(n, owner)];
    if (n.name === 'figcaption') return [el('p', { class: 'reader-caption' }, children(n).flatMap(c => inline(c, owner)))];
    if (['ul', 'ol', 'li', 'p', 'pre'].includes(n.name)) return [el(n.name, {}, children(n).flatMap(c => tableContents(c, owner)))];
    if (['div', 'figure', 'section'].includes(n.name) ||
      elements(n, child => child !== n && child.name === 'table').length) return children(n).flatMap(c => tableContents(c, owner));
    return inline(n, owner);
  }
  function figureImage(n: DomNode, owner: string, inlineImage = false): OutNode {
    bind(n, owner);
    // Math drawn inside an inline SVG picture (a TikZ node's foreignObject) travels with the picture, not as an equation.
    if (n.name === 'svg') for (const m of elements(n, c => c.name === 'math')) skippedMath.add(m);
    check(n.name !== 'object' || n.attribs.type === 'image/svg+xml', 'arxiv_asset_type');
    const url = n.name === 'svg' ? '#' + n.attribs.id : arxivAssetURL(n.attribs[n.name === 'img' ? 'src' : 'data'] ?? '', sourceURL);
    imageURLs.add(url);
    const asset = resolveImage(url);
    check(/^assets\/[a-f0-9]{64}\.(png|jpg)$/.test(asset.path) && Number.isSafeInteger(asset.width) && Number.isSafeInteger(asset.height)
      && asset.width > 0 && asset.height > 0 && asset.width <= LIMITS.imageDimension && asset.height <= LIMITS.imageDimension, 'arxiv_asset');
    const output = el('img', {src:asset.path,alt:'Figure',width:String(asset.width),height:String(asset.height),
      ...(inlineImage ? {class:'reader-inline-image'} : {})});
    figureImages.get(owner)!.push(output); return output;
  }
  function imageFigure(n: DomNode): OutNode {
    const images = elements(n, c => ['img','object','svg'].includes(c.name));
    check(images.length >= 1 && images.length <= LIMITS.imagesPerFigure && figures.length < LIMITS.figures, 'arxiv_figure');
    const captions = elements(n, c => c.name === 'figcaption');
    check(captions.length <= 1, 'arxiv_caption');
    return block(n, 'figure', 'figure', id => {
      const imageNodes: OutNode[] = []; figureImages.set(id, imageNodes);
      let caption: OutNode | null = null;
      // Preserve legend text and inline symbols instead of collecting images
      // and accidentally discarding the other children of a figure.
      const parts: Child[] = [];
      const visit = (child: DomNode) => {
        if (child.type === 'comment' || active.has(child.name)) return;
        bind(child, id);
        if (child.name === 'figcaption') {
          caption = el('figcaption', {}, children(child).flatMap(c => inline(c, id))); parts.push(caption);
        } else if (child.name === 'img' || child.name === 'object') parts.push(figureImage(child,id));
        else if (child.name === 'p') parts.push(el('p', {}, children(child).flatMap(c => inline(c,id))));
        else if (['div','span'].includes(child.name)) children(child).forEach(visit);
        else parts.push(...inline(child,id));
      };
      if (['img','object'].includes(n.name)) parts.push(figureImage(n,id));
      else children(n).forEach(visit);
      const output: Child[] = []; let run: Child[] = [];
      const flush = () => {
        if (run.some(c => typeof c !== 'string' || c.trim())) output.push(el('p', {}, run));
        run = [];
      };
      for (const part of parts) {
        if (typeof part !== 'string' && (['p','figcaption'].includes(part.name) || (part.name === 'img' && !part.attribs.class))) {
          flush(); output.push(part);
        } else run.push(part);
      }
      flush();
      const captionText = caption ? excerpt(normalizeSpace(outText(caption)), LIMITS.textBytes) : '';
      const alt = boundedText(captionText || images.map(i => i.attribs.alt ?? '').filter(Boolean).join(' ') || 'Figure', LIMITS.textBytes, 'arxiv_alt');
      for (const image of imageNodes) image.attribs.alt = alt;
      const paths = imageNodes.map(image => image.attribs.src);
      figures.push({ id, block_id: id, asset_paths: [...new Set(paths)], caption: captionText, alt });
      return output;
    }, {});
  }
  function flow(n: DomNode): OutNode[] {
    if (n.type === 'comment' || active.has(n.name) || (n.type === 'text' && !n.data.trim())) return [];
    if (n.type === 'text') return [block(n, 'p', 'paragraph', () => [n.data])];
    check(n.type === 'tag', 'arxiv_node');
    const before = blocks.length;
    let output: OutNode[];
    if (/^h[1-6]$/.test(n.name)) output = [block(n, n.name, 'heading', id => children(n).flatMap(c => inline(c, id)))];
    else if (n.name === 'figure') {
      const tables = elements(n, c => c.name === 'table');
      const images = elements(n, c => ['img','object','svg'].includes(c.name));
      const captions = children(n).filter(c => c.name === 'figcaption');
      if (captions.length > 1 && !tables.length && !elements(n, c => c !== n && c.name === 'figure').length) {
        // LaTeXML can put several complete numbered figures in one container.
        // Keep each image group with its following caption, in source order.
        output = []; let panel: DomNode[] = [];
        for (const child of children(n)) {
          panel.push(child);
          if (child.name === 'figcaption') {
            output.push(imageFigure({ ...n, attribs: {}, children: panel })); panel = [];
          }
        }
        output.push(...panel.flatMap(flow));
      } else if (elements(n, c => c !== n && c.name === 'figure').length || (tables.length && images.length)) {
        // Compound figures keep their panel order and captions as separate,
        // non-nested reader blocks. A reference to the group opens its first panel.
        output = children(n).flatMap(flow);
      } else if (tables.length || images.length === 0) {
        output = [block(n, 'div', 'table', id => children(n).flatMap(c => tableContents(c, id)), { class: 'reader-table' })];
      } else output = [imageFigure(n)];
    } else if (has(n, 'ltx_equation') || has(n, 'ltx_equationgroup')) {
      const maths = elements(n, c => c.name === 'math');
      check(maths.length > 0, 'arxiv_equation');
      output = [block(n, 'p', 'equation', id => {
        const parts: Child[] = [];
        for (const math of maths) parts.push(equation(math, id, true));
        const tags = elements(n, c => has(c, 'ltx_tag_equation') || has(c, 'ltx_tag_equationgroup'));
        if (tags.length) {
          const last = parts[parts.length - 1] as OutNode;
          last.attribs.class += ' reader-tagged';
          last.children.push(el('span', { class: 'reader-tag' }, [tags.map(textContent).join(' ')]));
        }
        walk(n, child => { if (child.name !== 'math' && child.attribs?.id && !aliases.has(child.attribs.id)) bind(child, id); });
        return parts;
      })];
    } else if (n.name === 'table') output = [block(n, 'div', 'table', id => [table(n, id)], { class: 'reader-table' })];
    else if (n.name === 'pre') output = [block(n, 'pre', 'code', () => [el('code', {}, [textContent(n)])])];
    else if (n.name === 'ul' || n.name === 'ol') {
      const list = el(n.name, has(n, 'ltx_biblist') ? { class: 'reader-references' } : {}, []);
      for (const item of children(n)) {
        if (item.type === 'text' && !item.data.trim() || item.type === 'comment') continue;
        check(item.name === 'li', 'arxiv_list');
        // An item holding a table (KAN's enumerated comparisons) keeps it as a table inside the item.
        const tabular = elements(item, c => c !== item && c.name === 'table').length > 0;
        list.children.push(block(item, 'li', 'list', id => children(item).flatMap(c => tabular ? tableContents(c, id) : inline(c, id))));
      }
      output = [list];
    } else if (n.name !== 'figcaption' && n.name !== 'math' && !has(n, 'ltx_authors') && loneImage(n)) {
      // A TikZ picture that is really a framed text box (LaTeXML: `svg.ltx_picture` whose foreignObjects hold the
      // text): its words read as paragraphs and the frame is left out and counted. Any other lone graphic is a figure.
      const picture = elements(n, c => c.name === 'svg')[0];
      const labels = picture ? elements(picture, c => c.name === 'foreignObject').filter(fo => normalizeSpace(textContent(fo)).length > 0) : [];
      if (picture && labels.length) {
        omittedGraphics += 1;
        output = labels.map(fo => block(fo, 'p', 'paragraph', id => children(fo).flatMap(c => inline(c, id))));
        if (picture.attribs?.id && output.length) bind(picture, output[0].attribs.id);
      } else output = [imageFigure(n)];
    }
    // A table or figure wrapped in inline-blocks (LaTeXML's resizebox, `span.ltx_transformed_inner`): its container
    // is flow, not a paragraph, so the table reads as a table block.
    else if (n.name !== 'figcaption' && !has(n, 'ltx_authors') && elements(n, c => c !== n && ['table', 'figure'].includes(c.name)).length) output = children(n).flatMap(flow);
    else if (n.name === 'p' || n.name === 'figcaption' || has(n, 'ltx_authors') || n.name === 'math') {
      output = [block(n, 'p', n.name === 'math' ? 'equation' : 'paragraph', id => n.name === 'math' ? [equation(n, id)]
        : children(n).flatMap(c => inline(c, id)), has(n, 'ltx_authors') ? { class: 'reader-authors' }
          : n.name === 'figcaption' ? { class: 'reader-caption' } : {})];
    } else if (n.name === 'hr') output = [el('hr')];
    else if (['article', 'section', 'div', 'header', 'footer', 'aside'].includes(n.name)) output = children(n).flatMap(flow);
    else if (n.name === 'img' || n.name === 'object') output = [imageFigure(n)];
    else output = [block(n, 'p', 'paragraph', id => inline(n, id))];
    if (blocks.length > before && n.attribs?.id && !aliases.has(n.attribs.id)) bind(n, blocks[before].id);
    return output;
  }
  top.push(...flow(root));
  if (dropped > 0 || omittedGraphics > 0) {
    // Said in the paper itself, as its last paragraph, so a reader knows what the HTML omitted.
    const parts = [dropped > 0 ? `${dropped} unsupported ${dropped === 1 ? 'command' : 'commands'}` : '',
      omittedGraphics > 0 ? `${omittedGraphics} inline ${omittedGraphics === 1 ? 'graphic' : 'graphics'}` : ''].filter(Boolean);
    const id = nextID();
    const note = el('p', { id, 'data-reader-block': id, 'data-reader-kind': 'paragraph' },
      [`Note: arXiv’s HTML conversion of this version left out ${parts.join(' and ')}. The PDF is complete.`]);
    blocks.push({ id, kind: 'paragraph', node: note }); top.push(note);
  }
  check(new Set([...usedMath, ...skippedMath]).size === elements(root, n => n.name === 'math').length, 'arxiv_math_coverage');
  for (const entry of blocks) if (entry.kind === 'figure') entry.node.attribs['data-reader-figure'] = entry.id;
  for (const link of links) {
    const id = aliases.get(link.target); check(id, 'arxiv_unresolved_fragment'); link.node.attribs.href = `#${id}`;
  }
  const titles = blocks.filter(b => b.node.name === 'h1');
  check(titles.length === 1, 'arxiv_title');
  const title = boundedText(normalizeSpace(outText(titles[0].node)), LIMITS.headingBytes, 'arxiv_title');
  check(title.length > 0, 'arxiv_title');
  const headings = blocks.filter(b => b.kind === 'heading' && b !== titles[0]).map(b => ({ id: b.id,
    level: Number(b.node.name.slice(1)), title: boundedText(normalizeSpace(outText(b.node)), LIMITS.headingBytes, 'heading_limit') }));
  check(headings.length <= LIMITS.headings, 'heading_limit');
  const index: ReaderIndex = { format: INDEX_FORMAT, title, headings, equations, figures,
    blocks: blocks.map(b => ({ id: b.id, kind: b.kind, text: boundedText(normalizeSpace(outText(b.node)), LIMITS.textBytes, 'arxiv_block_text') })) };
  const html = htmlPrefix(title) + top.map(render).join('') + HTML_SUFFIX;
  check(utf8(html).length <= LIMITS.htmlBytes && imageURLs.size <= LIMITS.archiveImages, 'html_limit');
  return { index, html, imageURLs: [...imageURLs].sort() };
}
function nearest(node: DomNode, name: string): DomNode | null {
  for (let p = node.parent; p; p = p.parent) if (p.name === name) return p;
  return null;
}

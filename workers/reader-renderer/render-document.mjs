import { createRequire } from 'node:module';
import { profile, requireThat, boundedText, sha256, escapeAttr, escapeText, pathIsSafe } from './common.mjs';
import { parseHTML, elements, namespaceIDs, serialize, sanitizeAndValidate, walk } from './dom.mjs';
import { resolveArchiveImagePath, validateImageMapping } from './image-paths.mjs';

const require = createRequire(import.meta.url);
const MarkdownIt = require('markdown-it');
const { mathpixMarkdownPlugin } = require('mathpix-markdown-it/lib/markdown/mathpix-markdown-plugins.js');
const { resetMmdGlobalState } = require('mathpix-markdown-it/lib/markdown/common/reset-mmd-state.js');
const mathTypes = new Set(['inline_math', 'display_math', 'equation_math', 'equation_math_not_number']);
const forbiddenTypes = new Set(['inline_mathML', 'display_mathML', 'ascii_math', 'smiles', 'chemistry', 'html_block', 'html_inline', 'usepackage_geometry']);
let consumed = false;

function textOf(node, equationMap) {
  if (node.type === 'text') return node.data;
  const equation = equationMap.get(node.attribs?.['data-reader-equation']);
  if (equation) return equation.latex;
  if (node.name === 'img') return node.attribs.alt;
  if (node.name === 'br') return ' ';
  return (node.children ?? []).map(child => textOf(child, equationMap)).join(['tr', 'td', 'th', 'li', 'table', 'thead', 'tbody', 'ul', 'ol', 'figure'].includes(node.name) ? ' ' : '');
}
export function renderIsolatedDocument(source, images, imageMapping = null) {
  requireThat(!consumed, 'renderer_process_reused'); consumed = true;
  requireThat(typeof source === 'string' && source.length > 0 && Buffer.byteLength(source) <= profile.max_source_bytes && !source.includes('\u0000'), 'source_limit');
  const digest = sha256(Buffer.from(source)).slice(0, 12);
  const archiveImages = imageMapping ? validateImageMapping(imageMapping, images) : null;
  const imagePaths = new Set();
  resetMmdGlobalState();
  const md = new MarkdownIt({ html: false, linkify: false, typographer: false, breaks: false, maxNesting: 32 });
  md.use(mathpixMarkdownPlugin, { outMath: { ...profile.math_options }, accessibility: null, copyToClipboard: false, enableFileLinks: false, centerImages: false, centerTables: false, renderElement: {}, parserErrors: 'show', mathDelimiterMode: 'strict', codeHighlight: { code: false, auto: false } });
  const env = {}; const tokens = md.parse(source, env);
  const blocks = [], equations = [], figures = [], aliases = new Map();
  function bindAlias(alias, id) { requireThat(!aliases.has(alias) || aliases.get(alias) === id, 'ambiguous_source_label'); aliases.set(alias, id); }
  function newBlock(token, kind) {
    requireThat(blocks.length < profile.max_blocks, 'block_limit');
    const block = { id: `b-${digest}-${blocks.length + 1}`, kind, token };
    blocks.push(block); token.readerBlock = block; return block;
  }
  function visit(list, current = null) {
    const localStack = [];
    for (let index = 0; index < list.length; index++) {
      const token = list[index]; requireThat(!forbiddenTypes.has(token.type), 'unsupported_source_construct');
      if (token.nesting === 1) {
        let block = current;
        if (!current) {
          const kind = token.type === 'heading_open' ? 'heading' : token.type === 'paragraph_open' ? 'paragraph' : token.type === 'table_open' ? 'table' : ['bullet_list_open', 'ordered_list_open', 'mmd_footnote_block_open'].includes(token.type) ? 'list' : null;
          if (kind) {
            const next = list[index + 1]; const children = next?.type === 'inline' ? (next.children ?? []).filter(t => t.type !== 'softbreak' && !(t.type === 'text' && !t.content.trim())) : [];
            const actualKind = kind === 'paragraph' && children.length === 1 && children[0].type === 'image' ? 'figure' : kind === 'paragraph' && children.length === 1 && mathTypes.has(children[0].type) && children[0].type !== 'inline_math' ? 'equation' : kind;
            block = newBlock(token, actualKind);
            if (kind === 'heading' && token.attrGet('id')) bindAlias(token.attrGet('id'), block.id);
            token.attrSet('id', block.id); token.attrSet('data-reader-block', block.id); token.attrSet('data-reader-kind', actualKind);
            if (actualKind === 'figure') { token.tag = 'figure'; token.attrSet('data-reader-figure', block.id); }
            else if (token.type === 'paragraph_open') token.tag = 'p';
          }
        }
        localStack.push({ previous: current, block, open: token }); current = block;
      } else if (token.nesting === -1) {
        const parent = localStack.pop(); requireThat(parent, 'token_nesting');
        if (parent.open.readerBlock?.kind === 'figure') { token.tag = 'figure'; token.readerFigureClose = parent.open.readerBlock; }
        else if (parent.open.type === 'paragraph_open' && parent.open.readerBlock) token.tag = 'p';
        current = parent.previous;
      } else if (['fence', 'code_block'].includes(token.type) && !current) newBlock(token, 'code');
      if (mathTypes.has(token.type)) {
        requireThat(current && equations.length < profile.max_equations && !token.mathData?.error && typeof token.mathData?.mathml === 'string' && typeof token.mathEquation === 'string', 'math_error');
        requireThat(Number.isFinite(token.mathData.widthEx) && token.mathData.widthEx > 0 && token.mathData.widthEx <= profile.max_equation_width_ex && Number.isFinite(token.mathData.heightEx) && token.mathData.heightEx > 0 && token.mathData.heightEx <= profile.max_equation_height_ex, 'equation_dimensions');
        const equation = { id: `e-${digest}-${equations.length + 1}`, block_id: current.id, latex: boundedText(token.content, 'equation_source'), display: token.type !== 'inline_math', source_form: ['equation_math', 'equation_math_not_number'].includes(token.type) ? 'environment' : 'body' };
        equations.push(equation); token.readerEquation = equation;
        if (token.idLabels) bindAlias(token.idLabels, equation.id);
      }
      if (token.type === 'image') {
        requireThat(current?.kind === 'figure' && figures.length < profile.max_figures, 'figure_context');
        let path = token.attrGet('src');
        if (archiveImages) {
          const sourcePath = resolveArchiveImagePath(path, imageMapping.source_path);
          path = archiveImages.get(sourcePath); requireThat(path !== undefined, 'asset_reference');
          imagePaths.add(sourcePath); requireThat(imagePaths.size <= profile.max_figures, 'asset_limit');
          // Only this parsed image token changes. The original source and math
          // tokens retain their exact bytes and same-node source association.
          token.attrSet('src', path);
        }
        requireThat(pathIsSafe(path) && images.has(path), 'asset_reference');
        const alt = boundedText(token.content).trim(); requireThat(alt.length > 0, 'figure_alt');
        const figure = { id: current.id, block_id: current.id, asset_paths: [path], caption: boundedText(token.attrGet('title') ?? alt), alt };
        figures.push(figure); current.figure = figure;
      }
      if (token.children) visit(token.children, current);
    }
    requireThat(localStack.length === 0, 'token_nesting');
  }
  visit(tokens);
  md.renderer.rules.mmd_footnote_block_open = (list, index) => { const block = list[index].readerBlock; requireThat(block, 'footnote_context'); return `<div id="${block.id}" data-reader-block="${block.id}" data-reader-kind="list" class="reader-footnotes"><hr>`; };
  md.renderer.rules.mmd_footnote_block_close = () => '</div>';
  for (const type of mathTypes) md.renderer.rules[type] = (list, index) => {
    const token = list[index], equation = token.readerEquation; requireThat(equation, 'equation_context');
    const mathml = parseHTML(token.mathData.mathml); requireThat(elements(mathml, n => n.name === 'math').length === 1, 'equation_mathml');
    // MathJax's HTML extension keeps source-controlled attributes in semantic
    // MathML, including macro-expanded \style/\class/\cssId/\href. Reject them
    // here before accepting the corresponding SVG; raw-HTML-off is insufficient.
    for (const node of elements(mathml, () => true)) {
      for (const key of Object.keys(node.attribs)) {
        requireThat(!['style', 'class', 'href', 'role', 'hidden'].includes(key) && !key.startsWith('aria-'), 'author_math_attributes');
        if (key === 'id') requireThat(node.name === 'mtd' && node.attribs.id.startsWith('mjx-eqn:'), 'author_math_attributes');
      }
    }
    const generated = parseHTML(token.mathEquation);
    requireThat(elements(generated, n => n.name === 'merror' || n.attribs['data-mml-node'] === 'merror' || 'data-mjx-error' in n.attribs).length === 0, 'math_error');
    const svg = elements(generated, n => n.name === 'svg' && !hasSVGParent(n)); requireThat(svg.length === 1, 'equation_svg');
    namespaceIDs(svg[0], `${equation.id}-svg`, aliases); svg[0].attribs['aria-hidden'] = 'true'; svg[0].attribs.focusable = 'false';
    namespaceIDs(mathml, `${equation.id}-mml`, aliases);
    const mathmlID = `${equation.id}-assistive`;
    return `<span id="${equation.id}" data-reader-equation="${equation.id}" class="reader-equation ${equation.display ? 'reader-display' : 'reader-inline'}" role="math" aria-labelledby="${mathmlID}"><span class="reader-math-visual" aria-hidden="true">${serialize(svg[0])}</span><span id="${mathmlID}" class="reader-assistive-math">${serialize(mathml)}</span><span class="reader-latex" hidden="hidden" aria-hidden="true">${escapeText(equation.latex)}</span></span>`;
  };
  md.renderer.rules.image = (list, index) => {
    const token = list[index], path = token.attrGet('src'), image = images.get(path);
    requireThat(image, 'asset_reference');
    return `<img src="${escapeAttr(path)}" alt="${escapeAttr(token.content)}" width="${image.width}" height="${image.height}">`;
  };
  const closeParagraph = md.renderer.rules.paragraph_close;
  md.renderer.rules.paragraph_close = (list, index, options, env, renderer) => {
    const figure = list[index].readerFigureClose?.figure;
    return (figure ? `<figcaption>${escapeText(figure.caption)}</figcaption>` : '') + (closeParagraph ? closeParagraph(list, index, options, env, renderer) : renderer.renderToken(list, index, options));
  };
  for (const type of ['fence', 'code_block']) {
    const render = md.renderer.rules[type];
    md.renderer.rules[type] = (list, index, ...args) => { const block = list[index].readerBlock; const html = render(list, index, ...args); return block ? `<div id="${block.id}" data-reader-block="${block.id}" data-reader-kind="code">${html}</div>` : html; };
  }
  const rendered = parseHTML(md.renderer.render(tokens, md.options, env));
  // Only references generated outside the owned equation nodes need source-label
  // translation. Every equation already owns a private SVG/MathML ID namespace.
  const ownedIDs = new Set([...blocks.map(b => b.id), ...equations.map(e => e.id)]), seenIDs = new Set(); let referenceOrdinal = 0;
  for (const node of elements(rendered, n => 'id' in n.attribs)) {
    const old = node.attribs.id; requireThat(!seenIDs.has(old), 'duplicate_generated_id'); seenIDs.add(old);
    if (!ownedIDs.has(old) && !equations.some(e => old.startsWith(`${e.id}-`))) { const id = `r-${digest}-${++referenceOrdinal}`; bindAlias(old, id); node.attribs.id = id; }
  }
  const normalizedIDs = new Set(elements(rendered, n => 'id' in n.attribs).map(n => n.attribs.id));
  walk(rendered, node => {
    for (const attr of ['href', 'xlink:href']) {
      const value = node.attribs?.[attr]; if (value === undefined) continue;
      requireThat(value.startsWith('#'), 'external_reference'); const target = value.slice(1);
      const translated = normalizedIDs.has(target) ? target : aliases.get(target); requireThat(translated, 'unresolved_fragment'); node.attribs[attr] = `#${translated}`;
    }
    // Mathpix's reference anchors emit inert bookkeeping not used by this bundle.
    if (node.name === 'a') { delete node.attribs.target; delete node.attribs.rel; delete node.attribs['data-parentheses']; delete node.attribs['data-type']; delete node.attribs.value; }
  });
  const safe = sanitizeAndValidate(serialize(rendered), new Set(images.keys()));
  const equationMap = new Map(equations.map(e => [e.id, e]));
  const blockNodes = elements(safe, n => 'data-reader-block' in n.attribs);
  const equationNodes = elements(safe, n => 'data-reader-equation' in n.attribs);
  const figureNodes = elements(safe, n => 'data-reader-figure' in n.attribs);
  requireThat(blockNodes.length === blocks.length && equationNodes.length === equations.length && figureNodes.length === figures.length, 'sidecar_missing_node');
  const blockIDs = new Set(blocks.map(b => b.id));
  for (const node of equationNodes) {
    const equation = equationMap.get(node.attribs['data-reader-equation']); requireThat(equation && node.attribs.id === equation.id, 'equation_identity');
    let parent = node.parent; while (parent && !parent.attribs?.['data-reader-block']) parent = parent.parent;
    requireThat(parent?.attribs['data-reader-block'] === equation.block_id, 'equation_parent');
    requireThat(elements(node, n => n.name === 'svg' && !hasSVGParent(n)).length === 1 && elements(node, n => n.name === 'math').length === 1 && elements(node, n => n.attribs.class === 'reader-latex').length === 1, 'equation_representation');
  }
  for (const figure of figures) {
    const node = figureNodes.find(n => n.attribs.id === figure.id); requireThat(node && node.attribs['data-reader-block'] === figure.block_id, 'figure_identity');
    requireThat(JSON.stringify(elements(node, n => n.name === 'img').map(n => n.attribs.src)) === JSON.stringify(figure.asset_paths), 'figure_assets');
  }
  const headings = blockNodes.filter(n => /^h[1-6]$/.test(n.name)).map(n => ({ id: n.attribs.id, level: Number(n.name.slice(1)), title: boundedText(textOf(n, equationMap).replace(/\s+/g, ' ').trim()) }));
  requireThat(headings.length <= profile.max_headings && headings.filter(h => h.level === 1).length === 1 && headings.every(h => h.title.length > 0 && Buffer.byteLength(h.title) <= profile.max_heading_bytes), 'document_title');
  const title = headings.find(h => h.level === 1).title; requireThat(title.length > 0, 'document_title');
  const index = { format: profile.index_format, title, headings: headings.filter(h => h.level !== 1), blocks: blockNodes.map(n => ({ id: n.attribs.id, kind: n.attribs['data-reader-kind'], text: boundedText(textOf(n, equationMap).replace(/\s+/g, ' ').trim()) })), equations, figures };
  requireThat(index.blocks.every(b => blockIDs.has(b.id)), 'sidecar_identity');
  return { html: serialize(safe), index, ...(imageMapping ? { image_paths: [...imagePaths].sort() } : {}) };
}
function hasSVGParent(node) { for (let p = node.parent; p; p = p.parent) if (p.name === 'svg') return true; return false; }

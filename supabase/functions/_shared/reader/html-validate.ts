// Independent inert-DOM/index admission, shared by the server test harness and
// the on-device compiler. No network, image decoder or provider dependency.
import { CLASSES, domText, elements, HTML_ATTRIBUTES, HTML_SUFFIX, htmlPrefix, isMathToken, MATH_ELEMENTS, mathAttributeIsSafe, normalizeSpace, parseHTML, PHRASING, serialize, type DomNode } from './html.ts';
import { LIMITS } from './profile.ts';
import { check, CONTROL, decodeUTF8, excerpt, idIsSafe } from './util.ts';
import type { ReaderIndex } from './render.ts';

// --- HTML ------------------------------------------------------------------

function attr(node: DomNode, name: string): string | undefined { return node.attribs?.[name]; }
const indexText = (node: DomNode, maximum: number) => excerpt(normalizeSpace(domText(node)), maximum);
const blank = (node: DomNode) => node.type === 'text' && !node.data.trim();

/** The on-device PDF converter's additions (docs/architecture/DEVICE_PDF_ROUTE.md), admitted only for its bundles:
 * an unsure formula shown as its crop (`reader-math-image`, a style limited to em sizes) and footnote paragraphs. */
const DEVICE_PDF_CLASSES = new Set(['reader-math-image', 'reader-footnote']);
const MATH_IMAGE_STYLE = { inline: /^height:\d{1,3}(\.\d{1,3})?em;vertical-align:-?\d{1,3}(\.\d{1,3})?em$/, display: /^width:\d{1,3}(\.\d{1,3})?em$/ };

export function validateHTML(bytes: Uint8Array, index: ReaderIndex, images: Map<string, { width: number; height: number }>, extendedFigures = false, devicePDF = false): void {
  check(bytes.length <= LIMITS.htmlBytes, 'html_limit');
  const html = decodeUTF8(bytes, 'html_encoding');
  const prefix = htmlPrefix(index.title), suffix = HTML_SUFFIX;
  check(html.startsWith(prefix) && html.endsWith(suffix) && html.length >= prefix.length + suffix.length, 'html_structure');
  const body = html.slice(prefix.length, html.length - suffix.length);
  const root = parseHTML(body);
  // The generator's serialization is a parse fixed point; anything an HTML5
  // tree builder could restructure is refused by the content rules below.
  check(serialize(root) === body, 'html_canonical');

  const ids = new Set<string>(), fragments: string[] = [];
  const blocks: DomNode[] = [], equations: DomNode[] = [], figures: DomNode[] = [];
  const blockOf = (node: DomNode): DomNode | null => {
    for (let current: DomNode | null = node; current; current = current.parent) if (current.attribs?.['data-reader-block']) return current;
    return null;
  };
  const visit = (node: DomNode, inMath: boolean, inAnchor: boolean, phrasingOnly: boolean): void => {
    if (node.type === 'text') {
      check(!CONTROL.test(node.data), 'html_text');
      if (node.data.trim()) {
        check(blockOf(node) !== null, 'text_outside_block');
        if (inMath) check(node.parent && isMathToken(node.parent.name), 'math_text');
        else check(!['ul', 'ol', 'table', 'tbody', 'tr', 'figure'].includes(node.parent?.name ?? ''), 'html_text');
      }
      return;
    }
    check(node.type === 'tag', 'html_node_type');
    const name = node.name;
    if (inMath) {
      check(MATH_ELEMENTS.has(name) && name !== 'math', 'math_element');
      for (const [key, value] of Object.entries(node.attribs)) check(mathAttributeIsSafe(name, key, value), 'math_attribute');
      for (const child of node.children) visit(child, true, inAnchor, true);
      return;
    }
    check(name === 'math' || name in HTML_ATTRIBUTES, 'html_tag');
    const inlineImage = extendedFigures && name === 'img' && attr(node,'class') === 'reader-inline-image';
    const mathImage = devicePDF && name === 'img' && node.parent?.name === 'span' && attr(node.parent, 'data-reader-equation') !== undefined &&
      (attr(node.parent, 'class') ?? '').split(' ').includes('reader-math-image');
    if (phrasingOnly) check(PHRASING.has(name) || inlineImage || mathImage, 'html_content_model');
    if (name === 'math') {
      check(node.parent?.name === 'span' && attr(node.parent, 'data-reader-equation') !== undefined, 'math_context');
      for (const [key, value] of Object.entries(node.attribs)) check(mathAttributeIsSafe('math', key, value), 'math_attribute');
      for (const child of node.children) visit(child, true, inAnchor, true);
      return;
    }
    const allowed = HTML_ATTRIBUTES[name];
    for (const [key, value] of Object.entries(node.attribs)) {
      check((allowed.includes(key) || (inlineImage && key === 'class') || (mathImage && key === 'style')) && !CONTROL.test(value) && value.length <= LIMITS.textBytes * 2, `html_attribute:${name}`);
      if (key === 'id') { check(idIsSafe(value) && !ids.has(value), 'dom_id'); ids.add(value); }
      if (key === 'class') check(inlineImage || value.split(' ').every(item => CLASSES.has(item) || (devicePDF && DEVICE_PDF_CLASSES.has(item))), 'html_class');
    }
    if (attr(node, 'data-reader-block') !== undefined) {
      check(attr(node, 'id') === attr(node, 'data-reader-block') && blockOf(node.parent!) === null, 'block_nesting');
      blocks.push(node);
    }
    if (attr(node, 'data-reader-equation') !== undefined) equations.push(node);
    if (attr(node, 'data-reader-figure') !== undefined) figures.push(node);
    let childPhrasing = phrasingOnly || ['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'figcaption', 'th', 'td', 'code', ...PHRASING].includes(name);
    switch (name) {
      case 'a': {
        check(!inAnchor, 'nested_anchor');
        const href = attr(node, 'href') ?? '';
        if (href.startsWith('#')) { check(attr(node, 'rel') === undefined, 'link_reference'); fragments.push(href.slice(1)); }
        else {
          let url: URL | null = null;
          try { url = new URL(href); } catch { /* refused below */ }
          check(url && url.protocol === 'https:' && url.href === href && !url.username && !url.password && !url.port &&
            attr(node, 'rel') === 'noopener noreferrer', 'link_reference');
        }
        for (const child of node.children) visit(child, false, true, true);
        return;
      }
      case 'img': {
        if (mathImage) {
          const image = images.get(attr(node, 'src') ?? '');
          const display = (attr(node.parent!, 'class') ?? '').split(' ')[1] === 'reader-display';
          check(image && attr(node, 'width') === String(image.width) && attr(node, 'height') === String(image.height) &&
            (attr(node, 'alt') ?? '').trim().length > 0 && MATH_IMAGE_STYLE[display ? 'display' : 'inline'].test(attr(node, 'style') ?? ''), 'image_reference');
          return;
        }
        const image = images.get(attr(node, 'src') ?? '');
        check((inlineImage ? blockOf(node)?.name === 'figure' && node.parent?.name !== 'figure' : node.parent?.name === 'figure') && image && attr(node, 'width') === String(image.width) &&
          attr(node, 'height') === String(image.height) && (attr(node, 'alt') ?? '').trim().length > 0, 'image_reference');
        return;
      }
      case 'figure': {
        const children = node.children.filter(child => !blank(child));
        const last = children[children.length - 1];
        const imgs = extendedFigures ? elements(node, child => child.name === 'img') : children.filter(child => child.name === 'img');
        check(imgs.length >= 1 && (extendedFigures
          ? children.every(child => ['img','p','figcaption'].includes(child.name)) && children.filter(child => child.name === 'figcaption').length <= 1
          : children.every((child, n) => child.name === 'img' || (child.name === 'figcaption' && n === children.length - 1)) &&
            (last.name === 'img' || last.name === 'figcaption')), 'figure_structure');
        break;
      }
      case 'div': check(attr(node, 'class') === 'reader-table', 'html_structure'); break;
      case 'table': check(node.children.filter(child => !blank(child)).every(child => child.name === 'tbody'), 'table_structure'); break;
      case 'tbody': check(node.parent?.name === 'table' && node.children.filter(child => !blank(child)).every(child => child.name === 'tr'), 'table_structure'); break;
      case 'tr': check(node.parent?.name === 'tbody' && node.children.filter(child => !blank(child)).every(child => child.name === 'td' || child.name === 'th'), 'table_structure'); break;
      case 'th': case 'td': {
        check(node.parent?.name === 'tr', 'table_structure');
        for (const key of ['colspan', 'rowspan']) { const value = attr(node, key); check(value === undefined || /^[1-9][0-9]{0,2}$/.test(value), 'table_structure'); }
        break;
      }
      case 'ul': case 'ol': {
        check(node.children.filter(child => !blank(child)).every(child => child.name === 'li'), 'list_structure');
        const start = attr(node, 'start');
        check(start === undefined || (name === 'ol' && /^-?[0-9]{1,6}$/.test(start)), 'list_structure');
        break;
      }
      case 'li': check(node.parent?.name === 'ul' || node.parent?.name === 'ol', 'list_structure'); childPhrasing = false; break;
      case 'pre': check(node.children.length === 1 && node.children[0].name === 'code', 'code_structure'); break;
      case 'code': check(node.children.every(child => child.type === 'text') || node.parent?.name !== 'pre', 'code_structure'); break;
      case 'figcaption': check(node.parent?.name === 'figure', 'figure_structure'); break;
      case 'span': {
        if (attr(node, 'data-reader-equation') !== undefined) {
          const names = (attr(node, 'class') ?? '').split(' ');
          const children = node.children.filter(child => !blank(child));
          const math = children.filter(child => child.name === 'math');
          check(names[0] === 'reader-equation' && (names[1] === 'reader-inline' || names[1] === 'reader-display') && attr(node, 'data-latex') !== undefined, 'equation_representation');
          const tagged = names.includes('reader-tagged'), fallback = names.includes('reader-math-fallback');
          const picture = devicePDF && names.includes('reader-math-image');
          check(names.length === 2 + Number(tagged) + Number(fallback) + Number(picture) && !(tagged && fallback) && !(picture && (tagged || fallback)), 'equation_representation');
          if (picture) check(children.length === 1 && children[0].type === 'tag' && children[0].name === 'img', 'equation_representation');
          else if (fallback) check(children.length === 1 && children[0].type === 'text', 'equation_representation');
          else {
            check(math.length === 1 && children[0] === math[0] && children.length === (tagged ? 2 : 1), 'equation_representation');
            check((attr(math[0], 'display') === 'block') === (names[1] === 'reader-display'), 'equation_representation');
            if (tagged) check(children[1].name === 'span' && attr(children[1], 'class') === 'reader-tag' && names[1] === 'reader-display', 'equation_representation');
          }
        } else if (attr(node, 'class') === 'reader-tag') {
          check(node.parent && attr(node.parent, 'data-reader-equation') !== undefined && node.children.every(child => child.type === 'text'), 'equation_representation');
        } else check((attr(node, 'class') === 'reader-marker' && node.parent?.name === 'li')
          || (['reader-affiliations', 'reader-notes'].includes(attr(node, 'class') ?? '') && node.parent?.name === 'p' && attr(node.parent, 'class') === 'reader-authors'), 'html_structure');
        break;
      }
      case 'p': {
        const names = attr(node, 'class');
        check(names === undefined || ['reader-authors', 'reader-abstract', 'reader-caption'].includes(names) || (devicePDF && names === 'reader-footnote'), 'html_class');
        break;
      }
    }
    for (const child of node.children) visit(child, false, inAnchor, childPhrasing);
  };
  for (const child of root.children) {
    if (blank(child)) continue;
    const name = child.name;
    check(child.type === 'tag' && (attr(child, 'data-reader-block') !== undefined || name === 'hr' ||
      ((name === 'ul' || name === 'ol') && child.children.filter(item => !blank(item)).every(item => attr(item, 'data-reader-block') !== undefined))), 'top_level');
    visit(child, false, false, false);
  }
  for (const id of fragments) check(ids.has(id), 'unresolved_fragment');

  // DOM and sidecar describe the same blocks, equations and figures, in order.
  check(blocks.length === index.blocks.length && equations.length === index.equations.length && figures.length === index.figures.length, 'index_identity');
  const blockByID = new Map<string, DomNode>();
  blocks.forEach((node, n) => {
    const row = index.blocks[n];
    check(attr(node, 'id') === row.id && attr(node, 'data-reader-kind') === row.kind && row.text === indexText(node, LIMITS.textBytes), 'index_identity');
    const expected: Record<string, string[]> = { heading: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'], paragraph: ['p'], equation: ['p'],
      figure: ['figure'], table: ['div'], list: ['li'], code: ['pre'] };
    check(expected[row.kind].includes(node.name) && (row.kind === 'figure') === (attr(node, 'data-reader-figure') !== undefined), 'index_identity');
    blockByID.set(row.id, node);
  });
  // Exactly one H1 carries the document title; every other heading is navigable.
  const headingBlocks = blocks.filter(node => attr(node, 'data-reader-kind') === 'heading');
  const titles = headingBlocks.filter(node => node.name === 'h1');
  check(titles.length === 1 && indexText(titles[0], LIMITS.headingBytes) === index.title, 'index_title');
  const navigable = headingBlocks.filter(node => node !== titles[0] && indexText(node, LIMITS.headingBytes).length > 0);
  check(navigable.length === index.headings.length && navigable.every((node, n) => attr(node, 'id') === index.headings[n].id &&
    node.name === `h${index.headings[n].level}` && indexText(node, LIMITS.headingBytes) === index.headings[n].title), 'index_heading');
  equations.forEach((node, n) => {
    const row = index.equations[n];
    check(attr(node, 'id') === row.id && attr(node, 'data-reader-equation') === row.id && attr(node, 'data-latex') === row.latex &&
      blockOf(node) === blockByID.get(row.block_id) && (attr(node, 'class') ?? '').split(' ')[1] === (row.display ? 'reader-display' : 'reader-inline'), 'equation_identity');
    if ((attr(node, 'class') ?? '').includes('reader-math-fallback')) {
      check(node.children[0].data === (row.display ? row.latex : `\\(${row.latex}\\)`), 'equation_representation');
    }
  });
  figures.forEach((node, n) => {
    const row = index.figures[n];
    const imgs = extendedFigures ? elements(node, child => child.name === 'img') : node.children.filter(child => child.name === 'img');
    const caption = node.children.find(child => child.name === 'figcaption');
    check(attr(node, 'id') === row.id && attr(node, 'data-reader-figure') === row.id &&
      JSON.stringify([...new Set(imgs.map(img => attr(img, 'src')))]) === JSON.stringify(row.asset_paths) &&
      imgs.every(img => attr(img, 'alt') === row.alt) &&
      row.caption === (caption ? indexText(caption, LIMITS.textBytes) : ''), 'figure_identity');
  });
}


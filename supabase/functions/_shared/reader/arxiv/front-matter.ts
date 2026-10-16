// Front matter (arXiv converter component): the title, the authors and the abstract head the paper whatever template
// set them. A catalog title or author line when the HTML has none; a custom title page read into the header; front
// matter before anything LaTeXML placed above the title; a paragraph that only repeats the title left out.
import { elements, normalizeSpace, outText, textContent, type DomNode, type OutNode } from '../html.ts';
import { block, fold, isMarker, remove, reorder, children, type ArxivContext, type Child } from './context.ts';
import { EMAIL, MARKS, parseRun, plain, renderAuthors, unwrap } from './authors.ts';

/** A title page LaTeXML could not convert (a custom report template whose macros it does not know, 2610.18356): the
 * abstract, the affiliations and the contribution notes it carried are kept for the header; the rest (a logo path,
 * running titles, PDF metadata) is left out with the macros. Read before the document title only. */
export function templatePreamble(cx: ArxivContext, n: DomNode): void {
  const segments: { macro: string; nodes: DomNode[] }[] = [{ macro: '', nodes: [] }];
  const visit = (c: DomNode) => {
    if (isMarker(c)) { segments.push({ macro: c.attribs['data-reader-macro'], nodes: [] }); return; }
    if (c.type === 'tag' && ['p', 'div', 'section', 'span'].includes(c.name) && (c.name !== 'span' || elements(c, x => x !== c && isMarker(x)).length)) { children(c).forEach(visit); return; }
    segments[segments.length - 1].nodes.push(c);
  };
  children(n).forEach(visit);
  const text = (nodes: DomNode[]) => normalizeSpace(nodes.map(textContent).join(''));
  for (const segment of segments) {
    const words = text(segment.nodes);
    if (!words) continue;
    if (/abstract/i.test(segment.macro) && !cx.pendingAbstract) { cx.pendingAbstract = { owner: n, nodes: segment.nodes }; continue; }
    for (const m of segment.nodes.flatMap(x => elements(x, y => y.name === 'math'))) cx.skippedMath.add(m);
    if (/contribution|thanks|footnote|note/i.test(segment.macro)) {
      const note = /^\[?\s*([^\]\s]{1,3})\s*\]\s*(.+)$/u.exec(words);
      cx.templateNotes.push(note ? { mark: note[1], text: note[2] } : { mark: '', text: words });
      continue;
    }
    // Affiliation lines a template wrote as "1]Wuhan University".
    for (const line of nodesLines(segment.nodes)) {
      const affiliation = /^\s*(\d{1,2}|[a-z])\s*\]\s*(.+?)\s*$/u.exec(line);
      if (affiliation) cx.templateAffiliations.push({ mark: affiliation[1], text: normalizeSpace(affiliation[2]) });
    }
  }
}
const nodesLines = (nodes: DomNode[]): string[] => nodes.map(textContent).join('').split('\n');

/** No `h1` (a template that set the title as a bold paragraph, 2610.19861): the catalog's title heads the paper. */
export function catalogTitle(cx: ArxivContext): void {
  if (!elements(cx.root, n => n.name === 'h1').length && cx.metadataTitle) {
    const heading = block(cx, cx.root, 'h1', 'heading', () => [cx.metadataTitle]); cx.synthetic.add(heading); cx.top.push(heading); cx.titleSeen = true;
  }
}

/** Front matter first: a figure or a venue line LaTeXML placed before the title (DDPM's samples, SGAnalog's "AI for Chip
 * Design") follows the title, the authors and the abstract instead (sweep, 2026-10-15). */
export function frontMatterFirst(cx: ArxivContext): void {
  const top = cx.top;
  const h1At = top.findIndex(node => node.name === 'h1');
  if (h1At > 0) {
    const front = (node: OutNode) => node.name === 'h1' || (node.name === 'p' && node.attribs.class === 'reader-authors')
      || (/^h[2-6]$/.test(node.name) && fold(outText(node)) === 'abstract');
    let end = h1At; while (end < top.length && front(top[end])) end += 1;
    // The abstract's paragraph(s), when a heading named it.
    if (end > h1At + 1 && /^h[2-6]$/.test(top[end - 1].name)) while (end < top.length && top[end].name === 'p' && top[end].attribs.class !== 'reader-authors') end += 1;
    const before = top.splice(0, h1At); top.splice(end - h1At, 0, ...before); reorder(cx);
  }
}

// No author block in the HTML (a template that set the names in a tabular, 2610.19861): the library's names head
// the paper after its title, and a paragraph that merely lists them again is left out.
export function catalogHeader(cx: ArxivContext): void {
  if (!cx.metadataAuthors.length) return;
  // An author block that names none of the paper's authors (a template's placeholder: 2610.20588's "Lorem Dolor"; a
  // submission's "Anonymous Authors") gives way to the library's names. Accents are compared without their marks, so
  // "Köprü" in the HTML still matches "Kopru" in the catalog and keeps the HTML's own spelling.
  const existing = cx.blocks.find(b => b.node.attribs.class === 'reader-authors');
  if (existing) {
    // Marks and footnote numbers run into the names in the HTML ("Rafailov2,†"): only the letters are compared.
    const bare = (t: string) => fold(t.normalize('NFKD').replace(/\p{M}/gu, '').replace(/\p{N}+/gu, ' '));
    const shown = ` ${bare(outText(existing.node))} `;
    const families = cx.metadataAuthors.map(name => bare(name).split(' ').filter(Boolean).pop() ?? '').filter(f => f.length > 1);
    if (families.length && !families.some(f => shown.includes(` ${f} `))) existing.node.children = [cx.metadataAuthors.join(', ')];
    return;
  }
  const names = cx.metadataAuthors.join(', ');
  const authors = block(cx, cx.root, 'p', 'paragraph', () => [names], { class: 'reader-authors' }); cx.synthetic.add(authors);
  const titleAt = cx.top.findIndex(node => node.name === 'h1');
  cx.top.splice(titleAt + 1, 0, authors); reorder(cx);
  const listed = fold(cx.metadataAuthors.join(' '));
  for (const entry of cx.blocks.filter(b => b.kind === 'paragraph' && b.node !== authors && fold(outText(b.node)) === listed)) remove(cx, entry);
  // A custom title page (2610.14075: names with marks in a tabular, affiliation lines, a date line, "Corresponding
  // authors:" with e-mail) reads into the header: its names with their marks when they are the catalog's, its
  // affiliations, notes and project page under them; the date, e-mail lines and a logo go. A subtitle stays. The
  // scan runs to the first section, past the abstract (1707.03017 sets its authors in a table after the abstract),
  // and reads tables cell by cell (build 46: LensErase's logo stopped it; FiLM's table stayed a table).
  const catalog = new Set(cx.metadataAuthors.map(fold));
  const parsedNames: Child[][] = [], affiliations: Child[][] = [], addresses: Child[][] = [], notes: { mark: string; body: Child[] }[] = [];
  // A mark set as a formula reads as its LaTeX (`\ast`, 2610.20538's "Equal contribution"): the symbol it draws, and
  // the separators left where e-mail addresses were go.
  const marked = (text: string) => text.replace(EMAIL, '').replace(/\\(?:ast|star|textasteriskcentered)(?![A-Za-z])/g, '∗')
    .replace(/\\ddagger(?![A-Za-z])/g, '‡').replace(/\\dagger(?![A-Za-z])/g, '†').replace(/\\S(?![A-Za-z])/g, '§')
    .replace(/\\P(?![A-Za-z])/g, '¶').replace(/^[\s,;:]+/, '').replace(/[\s,;:]+([∗*†‡§¶‖])/g, ' $1');
  const splitNotes = (text: string): { mark: string; body: Child[] }[] => {
    const found = [...marked(text).matchAll(/([∗*†‡§¶‖])\s*([^∗*†‡§¶‖]+)/g)]
      .map(m => ({ mark: m[1], body: [m[2].replace(/\s+([.,;:])/g, '$1').replace(/[\s,;:]+$/, '').trim()] as Child[] })).filter(n => (n.body[0] as string).length > 0);
    return found.length ? found : [{ mark: '', body: [marked(text).replace(/[\s,;:]+$/, '').trim()] }];
  };
  const isEmailOnly = (text: string) => text.length > 0 && !text.replace(EMAIL, '').replace(/[\s,;{}()]/g, '').length;
  // One unit (a paragraph, or a table cell): true when it belongs to the header and was taken.
  const take = (raw: Child[], text: string): boolean => {
    const unit = unwrap(raw), run = parseRun(unit);
    const matched = run.names.filter(name => catalog.has(fold(plain(name).replace(MARKS, '')))).length;
    if (!text) return true;
    if (isEmailOnly(text)) return true;
    if (/\bdate:/i.test(text) || (/\b(19|20)\d{2}\b/.test(text) && text.length <= 60 && !/[.!?]$/.test(text) && !matched)) return true;
    if (/corresponding author|equal contribution|contributed equally|project lead/i.test(text) && text.length <= 300) { notes.push(...splitNotes(text)); return true; }
    if (/^(project page|project website|website|homepage|code|github)\s*:/i.test(text) && unit.some(part => typeof part !== 'string' && part.name === 'a')) { addresses.push(unit); return true; }
    if (run.names.length >= 1 && matched * 2 >= run.names.length && matched >= 1) { parsedNames.push(...run.names); affiliations.push(...run.affiliations); return true; }
    if (!run.names.length && run.affiliations.length) { affiliations.push(...run.affiliations); return true; }
    return false;
  };
  let kept = 0, inAbstract = false;
  for (const node of cx.top.slice(cx.top.indexOf(authors) + 1, cx.top.indexOf(authors) + 24)) {
    const entry = cx.blocks.find(b => b.node === node); if (!entry) break;
    const text = normalizeSpace(outText(node));
    if (/^h[2-6]$/.test(node.name)) { if (fold(text) === 'abstract') { inAbstract = true; continue; } break; }
    if (node.name === 'figure') {
      // A logo (no caption) on the title page goes; a captioned figure (a teaser) stays and the scan goes on.
      if (!node.children.some(c => typeof c !== 'string' && c.name === 'figcaption') && !inAbstract) { remove(cx, entry); cx.omittedGraphics += 1; }
      continue;
    }
    if (node.name === 'div' && node.attribs.class === 'reader-table') {
      const cells: Child[][] = [];
      const collect = (n: Child) => { if (typeof n === 'string') return; if (n.name === 'td' || n.name === 'th') { cells.push(n.children); return; } n.children.forEach(collect); };
      collect(node);
      const named = cells.filter(cell => parseRun(unwrap(cell)).names.some(name => catalog.has(fold(plain(name).replace(MARKS, ''))))).length;
      if (named >= 1 && cells.every(cell => take(cell, normalizeSpace(plain(cell))))) { remove(cx, entry); continue; }
      if (++kept >= 3) break; else continue;
    }
    if (node.name !== 'p' || node.attribs.class) { if (inAbstract) continue; break; }
    if (inAbstract && text.length > 300) continue;
    if (take(node.children, text)) { remove(cx, entry); continue; }
    if (++kept >= 3) break;
  }
  if (parsedNames.length || affiliations.length || notes.length || addresses.length) {
    authors.children = renderAuthors(parsedNames.length ? parsedNames : [[names]], affiliations, addresses, notes);
  }
}

/** A paragraph that merely repeats the catalog title heading the paper is left out. */
export function dropRepeatedTitle(cx: ArxivContext): void {
  if (cx.metadataTitle && cx.blocks[0]?.node.name === 'h1' && cx.blocks[0].node.children[0] === cx.metadataTitle) {
    const repeat = cx.blocks.find((b, i) => i > 0 && b.kind === 'paragraph' && fold(outText(b.node)) === fold(cx.metadataTitle));
    if (repeat) remove(cx, repeat);
  }
}

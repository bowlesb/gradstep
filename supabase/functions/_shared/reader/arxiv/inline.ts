// Running text (arXiv converter component): what a paragraph, caption, list item or cell holds.
import { el, elements, normalizeSpace, textContent, type DomNode } from '../html.ts';
import { check } from '../util.ts';
import { active, bind, children, has, type ArxivContext, type Child } from './context.ts';
import { equation, mathAsText } from './math.ts';
import { figureImage } from './figures.ts';

// A size or style command LaTeXML left in running text ("\\scriptsize①" in 2610.14075's Figure 1 caption, build 42:
// "I see \\scriptsize") is no word of the paper.
export const LEAKED_MACRO = /\\(?:scriptsize|footnotesize|small|tiny|large|Large|LARGE|huge|Huge|normalsize|bfseries|itshape|rmfamily|sffamily|ttfamily|bf|it|rm|sf|tt|em|centering|raggedright|raggedleft|noindent|boldmath|unboldmath|relax)(?![A-Za-z])\s?/g;
/** Running text in the reader's phrasing vocabulary: emphasis, links (in-page ones resolved at the end), notes,
 * equations, and graphics only inside a figure. In a heading (`asText`), a formula Unicode spells exactly is text
 * (math.ts `mathAsText`), so the heading's index text, its title in Contents and the page's, has no LaTeX in it. */
export function inline(cx: ArxivContext, n: DomNode, owner: string, inAnchor = false, forceDisplay = false, asText = false): Child[] {
  if (n.type === 'text') return [n.data.replace(LEAKED_MACRO, '')];
  // A citation LaTeXML could not resolve prints as a bold "?" (2610.18683: "(?)", "(??)"): left out and counted;
  // the parentheses around it go too (`tidyPunctuation`).
  if (n.type === 'tag' && has(n, 'ltx_font_bold') && /^\?+$/.test(normalizeSpace(textContent(n)))) { cx.unresolvedCitations += 1; bind(cx, n, owner); return []; }
  if (n.type === 'comment') return [];
  check(n.type === 'tag' || active.has(n.name), 'arxiv_node');
  if (active.has(n.name)) return [];
  bind(cx, n, owner);
  if (n.name === 'math') {
    const text = asText && !cx.usedMath.has(n) ? mathAsText(n) : null;
    if (text) { cx.usedMath.add(n); return text; }
    return [equation(cx, n, owner, forceDisplay)];
  }
  if (['svg', 'img', 'object'].includes(n.name) && cx.figureImages.has(owner)) return [figureImage(cx, n, owner, true)];
  // A graphic inside running text outside a figure (an affiliation logo, an inline TikZ mark): the reader has no
  // inline-image vocabulary there, so it is left out and counted in the closing note rather than refusing the paper.
  if (['svg', 'img', 'object'].includes(n.name)) {
    cx.omittedGraphics += 1; for (const m of elements(n, c => c.name === 'math')) cx.skippedMath.add(m); return [];
  }
  check(!['table', 'figure'].includes(n.name), 'arxiv_nested_content');
  // A footnote in running text (LaTeXML: the mark, then the content repeating the mark and a "footnotetext:" label,
  // 2610.19864): the mark once, then its words.
  if (has(n, 'ltx_note')) {
    const mark = elements(n, x => x !== n && has(x, 'ltx_note_mark'))[0];
    const content = elements(n, x => x !== n && has(x, 'ltx_note_content'))[0];
    for (const x of elements(n, x => x !== n && (has(x, 'ltx_note_mark') || has(x, 'ltx_note_type'))))
      for (const m of elements(x, y => y.name === 'math')) cx.skippedMath.add(m);
    const body = (content ? children(content) : children(n).filter(x => !has(x, 'ltx_note_mark')))
      .filter(x => !(x.type === 'tag' && (has(x, 'ltx_note_mark') || has(x, 'ltx_note_type')))).flatMap(x => inline(cx, x, owner, inAnchor, forceDisplay, asText));
    const markText = mark ? normalizeSpace(textContent(mark)) : '';
    return markText ? [el('sup', {}, [markText]), ' ', ...body] : body;
  }
  const content = () => children(n).flatMap(c => inline(cx, c, owner, inAnchor || n.name === 'a', forceDisplay, asText));
  if (n.name === 'br') return [el('br')];
  if (n.name === 'a') {
    if (inAnchor) return content();
    const href = n.attribs.href ?? '';
    let target: URL | null = null;
    try { target = new URL(href, cx.sourceURL); } catch { /* preserve inert text */ }
    const node = el('a', {}, content());
    if (target && target.origin === new URL(cx.sourceURL).origin && target.pathname === new URL(cx.sourceURL).pathname && target.hash) {
      let fragment: string; try { fragment = decodeURIComponent(target.hash.slice(1)); } catch { throw new Error('arxiv_fragment'); }
      cx.links.push({ node, target: fragment }); return [node];
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

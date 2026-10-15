// Math (arXiv converter component): formulas as sanitized MathML with their LaTeX in the index, and the coverage rule
// that every `math` element of the paper is either rendered or deliberately left out with what carried it.
import { el, elements, isMathToken, MATH_ELEMENTS, mathAttributeIsSafe, normalizeSpace, textContent, type DomNode, type OutNode } from '../html.ts';
import { LIMITS } from '../profile.ts';
import { boundedText, check } from '../util.ts';
import { bind, children, type ArxivContext, type Child } from './context.ts';

/** LaTeXML's presentation MathML in the reader's vocabulary: annotations and links dropped, attributes allow-listed. */
export function mathNode(n: DomNode): Child[] {
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
      // source CSS; translate only this finite scalar vocabulary. Anything
      // else is left out, never refused: one `vertical-align:-2.1pt` on one
      // formula refused all of 2606.05868 (owner, 2026-10-15: "Couldn't open
      // this paper"). The formula keeps its content; only that styling goes.
      for (const declaration of value.split(';').map(v => v.trim()).filter(Boolean)) {
        const match = /^(width|height|depth|font-size|--ltx-fg-color|--ltx-bg-color):\s*([A-Za-z0-9 .%#+-]+)$/.exec(declaration);
        if (!match) continue;
        // The reader owns its colours: a source colour or background (a boxed ± in 2610.18683's tables, a teal
        // dagger) is left out, as the HTML's own colours are.
        if (match[1] === '--ltx-fg-color' || match[1] === '--ltx-bg-color') continue;
        const attr = match[1] === 'font-size' ? 'mathsize' : match[1];
        if (mathAttributeIsSafe(n.name, attr, match[2])) attrs[attr] = match[2];
      }
      continue;
    }
    if (key === 'mathcolor' || key === 'mathbackground') continue;
    // An attribute outside the allow-list (or with an unsafe value) is left out, as unknown styling is.
    if (mathAttributeIsSafe(n.name, key, value)) attrs[key] = value;
  }
  return [el(n.name, attrs, children(n).flatMap(mathNode))];
}
/** One formula: its LaTeX source in the index, its MathML in an equation span (forced display in an equation block). */
export function equation(cx: ArxivContext, n: DomNode, owner: string, forceDisplay = false): OutNode {
  check(!cx.usedMath.has(n), 'arxiv_math_duplicate'); cx.usedMath.add(n);
  const annotations = elements(n, c => c.name === 'annotation' && c.attribs.encoding === 'application/x-tex');
  const latex = boundedText(n.attribs.alttext ?? (annotations.length === 1 ? textContent(annotations[0]) : ''), LIMITS.textBytes, 'arxiv_math_source');
  check(latex.trim().length > 0 && cx.equations.length < LIMITS.equations, 'arxiv_math_source');
  if (annotations.length) check(annotations.length === 1 && normalizeSpace(textContent(annotations[0])) === normalizeSpace(latex), 'arxiv_math_mismatch');
  const display = forceDisplay || n.attribs.display === 'block';
  const id = `e-${cx.digest}-${cx.equations.length + 1}`; bind(cx, n, id);
  const form = /^\s*\\begin\{(?:equation\*?|align\*?|gather\*?|multline\*?)\}/.test(latex) ? 'environment' : 'body';
  check(form !== 'environment' || display, 'arxiv_math_source');
  cx.equations.push({ id, block_id: owner, latex, display, source_form: form });
  const math = el('math', display ? { display: 'block' } : {}, children(n).flatMap(mathNode));
  check(math.children.length > 0, 'arxiv_math_empty');
  return el('span', { id, 'data-reader-equation': id, 'data-latex': latex,
    class: `reader-equation ${display ? 'reader-display' : 'reader-inline'}` }, [math]);
}

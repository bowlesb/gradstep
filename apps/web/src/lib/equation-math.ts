// A symbol in the equation view, typeset (EQUATION_VIEW.md): its LaTeX when the model gave it, else its plain text read
// as math ("L_DPO(π_θ; π_ref)" → L_{DPO}(π_{θ}; π_{ref})), as MathML by the bundled Temml and the answers' sanitizer.
// Loaded with the view only (it brings the typesetter).
import { renderMath, sanitize } from './markdown';
import type { EquationSymbol } from './equation';

/** Plain text with `_`/`^` runs braced so Temml groups them: "π_ref" → "π_{ref}"; braced groups are left as they are. */
export const texFromText = (text: string) => text.replace(/([_^])([^\s{}()[\],;|_^]+)/g, '$1{$2}');

/** MathML for the symbol, or null to show its text: a rendering Temml flags as an error is not shown. */
export function symbolMath(symbol: EquationSymbol): string | null {
  const tries = [symbol.latex, /[_^]/.test(symbol.symbol) ? texFromText(symbol.symbol) : null];
  for (const tex of tries) {
    if (!tex) continue;
    const html = renderMath(tex, false);
    if (/<merror|math-source|temml-error/.test(html)) continue;
    return typeof DOMParser === 'function' ? sanitize(html) : html;
  }
  return null;
}

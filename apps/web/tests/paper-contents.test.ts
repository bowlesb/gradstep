// Contents › Figures, Tables and Equations (owner, build 59), as the app's PaperContentsSheet: the rows' numbers,
// captions and equations read as text.
import { describe, expect, it } from 'vitest';
import { contentsEquations, contentsFigures, figureLabel, mathText } from '../src/lib/paper-contents';

describe('figure and table rows', () => {
  it('splits the number from the caption, as GalleryFigure.label', () => {
    expect(figureLabel('Figure 4: Best of N sampling.')).toEqual({ number: 'Figure 4', caption: 'Best of N sampling.' });
    expect(figureLabel('Fig. 2. Left: the reward.')).toEqual({ number: 'Figure 2', caption: 'Left: the reward.' });
    expect(figureLabel('FIGURE A.1 | Appendix plot')).toEqual({ number: 'Figure A.1', caption: 'Appendix plot' });
    expect(figureLabel('Table 3: Win rates \\% over SFT')).toEqual({ number: 'Table 3', caption: 'Win rates % over SFT' });
    expect(figureLabel('An unnumbered  sketch , drawn')).toEqual({ number: null, caption: 'An unnumbered sketch, drawn' });
  });
  it('lists figures and tables apart, in order, from the caption or else the alt text', () => {
    const rows = contentsFigures({ figures: [
      { id: 'f1', block_id: 'f1', asset_paths: [], caption: 'Figure 1: Subplots of AI learning over time.', alt: 'x' },
      { id: 't1', block_id: 't1', asset_paths: [], caption: 'Table 1: Results.', alt: 'x' },
      { id: 'f2', block_id: 'f2', asset_paths: [], caption: '', alt: 'Figure 2: From the alt text' },
      { id: 'a1', block_id: 'a1', asset_paths: [], caption: 'Algorithm 1 DPO', alt: 'x' },
    ] });
    expect(rows.filter(r => !r.table).map(r => [r.number, r.caption])).toEqual([['Figure 1', 'Subplots of AI learning over time.'], ['Figure 2', 'From the alt text'], [null, 'Algorithm 1 DPO']]);
    expect(rows.filter(r => r.table).map(r => r.id)).toEqual(['t1']);
  });
});

describe('equation rows', () => {
  const equation = (id: string, latex: string, display = true) => ({ id, block_id: 'b', latex, display, source_form: 'latex' });
  it('numbers each display equation as printed, else by its \\tag, else just "Equation"; inline math is left out', () => {
    const rows = contentsEquations({ equations: [
      equation('e1', '\\mathcal{L}_{\\text{DPO}}(\\pi_\\theta) = -\\log \\sigma(\\beta x) \\label{eq:dpo}'),
      equation('e2', 'x^2 + y^2 = 1 \\tag{A.3}'),
      equation('e3', 'a = b \\nonumber'),
      equation('i1', 'x', false),
    ] }, id => (id === 'e1' ? '(7)' : null));
    expect(rows).toEqual([
      { id: 'e1', label: 'Equation (7)', text: 'L_(DPO)(π_θ) = -log σ(β x)' },
      { id: 'e2', label: 'Equation (A.3)', text: 'x² + y² = 1' },
      { id: 'e3', label: 'Equation', text: 'a = b' },
    ]);
  });
  it('keeps a row to 160 characters', () => {
    const [row] = contentsEquations({ equations: [equation('e', 'a+'.repeat(200))] }, () => null);
    expect([...row.text]).toHaveLength(160);
  });
});

describe('LaTeX read as text (ChatMathText.plain)', () => {
  it('reads fractions, roots, scripts, Greek letters, styles and delimiters', () => {
    expect(mathText('\\frac{a}{b+c}')).toBe('a/(b+c)');
    expect(mathText('\\sqrt{x^2}')).toBe('√x²'); expect(mathText('\\sqrt{a+b}')).toBe('√(a+b)');
    expect(mathText('x_{ij}^{T}')).toBe('xᵢⱼᵀ');
    expect(mathText('\\left( \\mathbf{W} \\right)')).toBe('( W )');
    expect(mathText('\\left. y \\right|')).toBe('y |');
    expect(mathText('\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}')).toBe('a = b ; c = d');
    expect(mathText('\\sum_{i=1}^{n} w_i')).toBe('∑ᵢ₌₁ⁿ wᵢ');
    expect(mathText('\\unknown{x}')).toBe('unknownx');
  });
  it('is bounded on deep nesting', () => {
    expect(() => mathText('{'.repeat(10_000) + 'x' + '}'.repeat(10_000))).not.toThrow();
  });
});

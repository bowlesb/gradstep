// Accents drawn over their letter in every engine the reader runs in (owner, TestFlight 92: "Is this equation displayed
// correctly?", 2610.27450v1 equation (3), where the bar of \bar{p}^U_M stood off to the left of the p).
//
// WebKit (iPhone, iPad, Mac and Safari) sets an accent's glyph by the glyph's own height above its baseline. The spacing
// accents LaTeX's commands write (˙ ¨ ˚, and ¯ ^ ~ when they are not stretched) carry their ink a whole x-height up, so
// the mark floats above the letter; stretched (LaTeXML's ¯ ^ ~), WebKit draws STIX Two Math's smallest wide form, wider
// than a wide letter (A, W, μ): a bar reaching out to the letter's left, a hat or tilde across its top, and its
// subscript pushed away (Â  t). The marks used instead over a letter sit low in their own glyphs, so WebKit sets them
// just over it, and Chromium and Firefox, which place an accent by its ink, draw them over it as before: a bar (¯ ‾ ˉ)
// is an en dash, a hat the caret ‸, a tilde ~ not stretched (which WebKit sets low), a dot the dot operator, two dots
// two of them, a ring the ring operator. Over a group (\overline{x+y}, \widehat{xy}) the stretched mark spans it and
// stays. Acute, grave, breve and check have no low-set twin and stay as written. WebKit also spaces an accent that is
// an operator (→, and the twins) as one, which widens the letter and pushes its scripts away, so a mark has no space.
import type { OutNode } from './html.ts';

const MACRON = new Set(['¯', '‾', 'ˉ', '\u0304', '\u0305']);
const HAT = new Set(['^', 'ˆ', '\u0302']), TILDE = new Set(['~', '˜', '\u0303']);
const SWAP: Record<string, string> = { '˙': '⋅', '\u0307': '⋅', '¨': '⋅⋅', '\u0308': '⋅⋅', '˚': '∘', '\u030a': '∘' };
/** The marks a LaTeX accent command writes. */
const MARKS = new Set([...MACRON, ...HAT, ...TILDE, ...Object.keys(SWAP), 'ˇ', '´', '`', '˘', '→', '←', '\u20d7']);
const TOKENS = new Set(['mi', 'mn', 'mo', 'mtext']);

/** An `mover` accent in the form the reader draws (changed in place). LaTeXML marks its accents `accent="true"`; Temml
 * (`temml`) leaves the attribute out and marks the accent's `mo` not stretchy, and such an `mover` becomes an accent. */
export function readerAccent(node: OutNode, temml = false): OutNode {
  if (node.name !== 'mover' || node.children.length !== 2 || node.children.some(c => typeof c === 'string')) return node;
  const [base, mark] = node.children as OutNode[];
  if (mark.name !== 'mo' || mark.children.some(c => typeof c !== 'string')) return node;
  const text = (mark.children as string[]).join('').trim();
  if (!MARKS.has(text)) return node;
  if (temml) {
    if (node.attribs.accent !== undefined || mark.attribs.stretchy !== 'false') return node;
    node.attribs.accent = 'true';
  }
  if (node.attribs.accent !== 'true') return node;
  const letter = TOKENS.has(base.name) || (base.name === 'mrow' && base.children.length === 1
    && typeof base.children[0] !== 'string' && TOKENS.has(base.children[0].name));
  const swap = (glyph: string) => { mark.children = [glyph]; mark.attribs.stretchy = 'false'; };
  const stretched = mark.attribs.stretchy === 'true';
  if (MACRON.has(text)) { if (!stretched || letter) swap('–'); }
  else if (SWAP[text]) swap(SWAP[text]);
  else if (HAT.has(text) || TILDE.has(text)) {
    if (letter && !stretched) swap(HAT.has(text) ? '‸' : '~');
    // Temml's \hat{xy}: stretched over the group, as LaTeXML's.
    else if (mark.attribs.stretchy === 'false') delete mark.attribs.stretchy;
  }
  mark.attribs.lspace = '0em'; mark.attribs.rspace = '0em';
  return node;
}

/** Every accent of a formula in the reader's form (`readerAccent`), innermost first. */
export function readerAccents(node: OutNode, temml = false): OutNode {
  for (const child of node.children) if (typeof child !== 'string') readerAccents(child, temml);
  return readerAccent(node, temml);
}

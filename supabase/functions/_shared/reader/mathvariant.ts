// MathML Core renders mathvariant only as "normal"; styled letters must be
// the Unicode Mathematical Alphanumeric Symbols. This maps MathJax's
// mathvariant tokens so bold, script, fraktur and double-struck letters look
// right in WebKit and Chromium alike. Returns null when a letter has no
// mapping, in which case the caller keeps the attribute.
const LATIN: Record<string, number> = {
  bold: 0x1d400, italic: 0x1d434, 'bold-italic': 0x1d468, script: 0x1d49c, 'bold-script': 0x1d4d0,
  fraktur: 0x1d504, 'double-struck': 0x1d538, 'bold-fraktur': 0x1d56c, 'sans-serif': 0x1d5a0,
  'bold-sans-serif': 0x1d5d4, 'sans-serif-italic': 0x1d608, 'sans-serif-bold-italic': 0x1d63c, monospace: 0x1d670,
};
const DIGITS: Record<string, number> = {
  bold: 0x1d7ce, 'double-struck': 0x1d7d8, 'sans-serif': 0x1d7e2, 'bold-sans-serif': 0x1d7ec, monospace: 0x1d7f6,
};
const GREEK: Record<string, number> = {
  bold: 0x1d6a8, italic: 0x1d6e2, 'bold-italic': 0x1d71c, 'bold-sans-serif': 0x1d756, 'sans-serif-bold-italic': 0x1d790,
};
// Letters that predate the block live in Letterlike Symbols.
const HOLES: Record<string, Record<string, number>> = {
  italic: { h: 0x210e },
  script: { B: 0x212c, E: 0x2130, F: 0x2131, H: 0x210b, I: 0x2110, L: 0x2112, M: 0x2133, R: 0x211b, e: 0x212f, g: 0x210a, o: 0x2134 },
  fraktur: { C: 0x212d, H: 0x210c, I: 0x2111, R: 0x211c, Z: 0x2128 },
  'double-struck': { C: 0x2102, H: 0x210d, N: 0x2115, P: 0x2119, Q: 0x211a, R: 0x211d, Z: 0x2124 },
};
// Greek order in the block: Α–Ρ, ϴ, Σ–Ω, ∇, α–ω, ∂, ϵ, ϑ, ϰ, ϕ, ϱ, ϖ.
function greekIndex(code: number): number {
  if (code >= 0x391 && code <= 0x3a1) return code - 0x391;
  if (code === 0x3f4) return 17;
  if (code >= 0x3a3 && code <= 0x3a9) return code - 0x3a3 + 18;
  if (code === 0x2207) return 25;
  if (code >= 0x3b1 && code <= 0x3c9) return code - 0x3b1 + 26;
  const extra = [0x2202, 0x3f5, 0x3d1, 0x3f0, 0x3d5, 0x3f1, 0x3d6].indexOf(code);
  return extra < 0 ? -1 : 51 + extra;
}

export function applyMathVariant(text: string, variant: string): string | null {
  let out = '';
  for (const char of text) {
    const code = char.codePointAt(0)!;
    const hole = HOLES[variant]?.[char];
    if (hole !== undefined) { out += String.fromCodePoint(hole); continue; }
    if (/[A-Za-z]/.test(char)) {
      if (LATIN[variant] === undefined) return null;
      out += String.fromCodePoint(LATIN[variant] + (code <= 0x5a ? code - 0x41 : code - 0x61 + 26));
    } else if (/[0-9]/.test(char)) {
      if (DIGITS[variant] === undefined) { if (variant.includes('italic') || variant === 'script' || variant.includes('fraktur')) { out += char; continue; } return null; }
      out += String.fromCodePoint(DIGITS[variant] + code - 0x30);
    } else if (greekIndex(code) >= 0) {
      if (GREEK[variant] === undefined) return null;
      out += String.fromCodePoint(GREEK[variant] + greekIndex(code));
    } else out += char;
  }
  return out;
}

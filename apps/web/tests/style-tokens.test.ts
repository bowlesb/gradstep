// The design tokens hold (src/tokens.css; docs/DESIGN.md "Tokens"): outside tokens.css, font sizes, radii, layers and
// motion are written with the token names, never as raw numbers. The allow-list below is the remainder not yet
// migrated (content-relative sizes, long-running loops, the explicitly timed figure outline). It only shrinks: a count
// above its entry fails (a new raw value), and a count below it fails too (lower the entry to lock in the gain).
import { readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

const SRC = join(__dirname, '../src');
const PROPERTIES = ['font-size', 'font', 'border-radius', 'border-top-left-radius', 'border-top-right-radius', 'border-bottom-left-radius',
  'border-bottom-right-radius', 'z-index', 'transition', 'transition-duration', 'animation', 'animation-duration'] as const;

/** Raw literals still allowed, per file and property. Lower these as values move onto tokens; never raise them. */
const ALLOWED: Record<string, Partial<Record<(typeof PROPERTIES)[number], number>>> = {
  'style.css': {
    // Answer text sized relative to the reader's chosen chat text: headings, code, math, citations, part captions.
    'font-size': 5,
    // The spinner's turn and the indeterminate bar's slide are loops, not interface motion.
    animation: 2,
    // Under Reduce Motion the spinner keeps turning, slowly (it is the only sign of progress).
    'animation-duration': 1,
    // FIGURE_VIEW.md: the part outline shows for a second, then fades (and without the fade under Reduce Motion).
    transition: 2,
  },
  'ui/Podcast.css': { animation: 1 },
};

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(path);
    return entry.name.endsWith('.css') && entry.name !== 'tokens.css' ? [path] : [];
  });
}

/** A value is raw when, with var(…) references removed, a number with a unit (or a bare z-index number) is left. Inside
 * z-index, `calc(var(--z-…) - 1)` is a token with an offset, not a new layer. */
function raw(property: string, value: string): boolean {
  const v = value.replace(/!important/, '').trim();
  if (property === 'z-index') return !/^(auto|0|var\(--z-[\w-]+\)|calc\(var\(--z-[\w-]+\) [+-] \d\))$/.test(v);
  const stripped = v.replace(/var\(--[\w-]+(,[^)]*)?\)/g, '');
  if (property.endsWith('radius')) return /\d*\.?\d+(px|rem|em|%)/.test(stripped);
  if (property === 'font-size' || property === 'font') return /\d*\.?\d+(px|rem|em|pt)/.test(stripped);
  return /(^|[\s,(])\d*\.?\d+m?s\b/.test(stripped); // transition, animation: a duration
}

export function rawDeclarations(css: string): { property: string; value: string }[] {
  const found: { property: string; value: string }[] = [];
  const body = css.replace(/\/\*[\s\S]*?\*\//g, '');
  for (const block of body.matchAll(/\{([^{}]*)\}/g)) {
    for (const declaration of block[1].split(';')) {
      const match = /^\s*([\w-]+)\s*:\s*([\s\S]+?)\s*$/.exec(declaration);
      if (!match) continue;
      const property = match[1].toLowerCase();
      if ((PROPERTIES as readonly string[]).includes(property) && raw(property, match[2])) found.push({ property, value: match[2] });
    }
  }
  return found;
}

describe('design tokens', () => {
  it('recognises raw values and token values', () => {
    expect(rawDeclarations('.a { font-size: 13px; border-radius: var(--r-md); z-index: 40; transition: color .12s; }').map(d => d.property))
      .toEqual(['font-size', 'z-index', 'transition']);
    expect(rawDeclarations('.a { font: var(--fs-body)/var(--lh-body) var(--font-ui); z-index: calc(var(--z-topbar) - 1); transition: color var(--dur-1) var(--ease-out); border-radius: 0 var(--r-sm); }'))
      .toEqual([]);
  });

  it('no stylesheet adds a raw font size, radius, layer or duration outside tokens.css', () => {
    const problems: string[] = [];
    for (const file of cssFiles(SRC)) {
      const name = relative(SRC, file);
      const counts = new Map<string, { property: string; value: string }[]>();
      for (const d of rawDeclarations(readFileSync(file, 'utf8'))) counts.set(d.property, [...(counts.get(d.property) ?? []), d]);
      for (const property of PROPERTIES) {
        const found = counts.get(property) ?? [], allowed = ALLOWED[name]?.[property] ?? 0;
        if (found.length > allowed) problems.push(`${name}: ${found.length - allowed} new raw ${property} (${found.map(d => d.value).join(' | ')}); use the tokens in src/tokens.css`);
        if (found.length < allowed) problems.push(`${name}: ${property} is down to ${found.length}; lower its allow-list entry from ${allowed}`);
      }
    }
    expect(problems).toEqual([]);
  });
});

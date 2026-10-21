// Structure first (figure-structure.ts; FIGURE_VIEW.md "Structure first") against the shared fixture
// tests/fixtures/figure-crops/structure.json, which ScienceReaderCore's FigureStructureTests read too: the same sub-figures,
// bands, note, quote and section matches from the same markup. UPDATE_STRUCTURE_FIXTURE=1 rewrites the expectations from
// this implementation (review the diff: it is the behaviour).
import { readFileSync, writeFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Rect } from '../src/lib/figure-crops';
import type { VerifiedBundle } from '../src/lib/bundle';
import { STRUCTURE, bundleFigureStructure, figureMarkup, figureStructure, matchSections, stackLayout, structureFits, structureNote, structureQuote, subcaption, type FigureStructure, type MatchSection } from '../src/lib/figure-structure';

const file = new URL('../../../tests/fixtures/figure-crops/structure.json', import.meta.url);
type Size = { width: number; height: number } | null;
const fixture = JSON.parse(readFileSync(file, 'utf8')) as {
  parameters: Record<string, number>;
  cases: { name: string; markup: string; assetPaths: string[]; sizes: Size[]; caption: string; expect?: { structure: FigureStructure | null; note: string | null; quote: string } }[];
  matches: { name: string; structure: string; sections: MatchSection[]; expect?: (number | null)[] }[];
  subcaptions: { text: string; expect?: { letter: string; words: string } | null }[];
  stackLayouts: { sizes: { width: number; height: number }[]; expect?: ReturnType<typeof stackLayout> }[];
};
const structureOf = (c: (typeof fixture.cases)[number]) => figureStructure(c.markup, c.assetPaths, c.sizes, c.caption);
const sectionsOf = (m: (typeof fixture.matches)[number]) => m.sections.map(s => ({ ...s, kind: s.kind ?? undefined, box: s.box as Rect | null }));

describe('figure structure (shared fixtures)', () => {
  it('uses the parameters the fixture states', () => {
    expect({ ...STRUCTURE }).toEqual(fixture.parameters);
  });
  for (const c of fixture.cases) {
    it(c.name, () => {
      const s = structureOf(c);
      expect(s).toEqual(c.expect!.structure);
      expect(s ? structureNote(s) : null).toBe(c.expect!.note);
      expect(structureQuote(c.caption, s)).toBe(c.expect!.quote);
    });
  }
  for (const m of fixture.matches) {
    it(`matches sections: ${m.name}`, () => {
      const s = structureOf(fixture.cases.find(c => c.name === m.structure)!);
      expect(matchSections(sectionsOf(m), s)).toEqual(m.expect);
    });
  }
  it('reads sub-captions and lays out the composite as composeFigure draws it', () => {
    for (const x of fixture.subcaptions) expect(subcaption(x.text)).toEqual(x.expect);
    for (const x of fixture.stackLayouts) expect(stackLayout(x.sizes)).toEqual(x.expect);
  });

  it('finds a figure block in the page and keeps a structure only for the image it describes', () => {
    const page = '<p>x</p><figure data-reader-block="b-2" data-reader-figure="b-2" id="b-2"><img src="a"></figure><figure data-reader-figure="b-3" id="b-3"><img src="b"><p>(a) y</p></figure>';
    expect(figureMarkup(page, 'b-3')).toBe('<figure data-reader-figure="b-3" id="b-3"><img src="b"><p>(a) y</p></figure>');
    expect(figureMarkup(page, 'b-4')).toBeNull();
    expect(figureMarkup(page, 'b"x')).toBeNull();
    const s = structureOf(fixture.cases[0])!;
    // The request's image is the composite scaled (within 1,568 px): the same aspect.
    expect(structureFits(s, { width: 1568 * s.width / s.height, height: 1568 })).toBe(true);
    expect(structureFits(s, { width: s.width, height: s.height * 0.8 })).toBe(false);
    expect(structureFits(null, { width: 1, height: 1 })).toBe(false);
  });

  it('leaves the note out when caption and note would pass the selection limit', () => {
    const s = structureOf(fixture.cases[0])!, long = 'x'.repeat(STRUCTURE.quoteScalars - 50);
    expect(structureQuote(long, s)).toBe(long);
    expect(structureQuote('Figure 3: short.', s).startsWith('Figure 3: short.\n\nThe image stacks this figure\'s 3 sub-figures')).toBe(true);
  });
});

// Opt-in, a real paper as the device compiles it (`node scripts/reader-device-compile.mjs --ids=2610.22353v1
// --out=<dir>`): FIGURE_STRUCTURE_BUNDLE=<dir>/2610.22353v1 prints every multi-image figure's structure and checks
// Figure 3's three sub-captioned images.
const real = process.env.FIGURE_STRUCTURE_BUNDLE;
if (real) describe('figure structure of a real compiled paper', () => {
  it('reads every multi-image figure of the bundle', () => {
    const dir = new URL(`file://${real}/`), read = (path: string) => readFileSync(new URL(path, dir));
    const manifest = JSON.parse(read('manifest.json').toString()), index = JSON.parse(read('reader.json').toString());
    const bundle = { manifest, index, contents: new Map([[manifest.entrypoint, new Uint8Array(read(manifest.entrypoint))]]) } as unknown as VerifiedBundle;
    for (const figure of index.figures.filter((f: { asset_paths: string[] }) => f.asset_paths.length > 1)) {
      const s = bundleFigureStructure(bundle, figure);
      console.log(`${figure.caption.slice(0, 40)} — ${figure.asset_paths.length} images:`, s ? `${s.parts.length} parts ${s.width}×${s.height}\n${structureNote(s)}` : 'no structure');
    }
    const three = index.figures.find((f: { caption: string }) => f.caption.startsWith('Figure 3:'));
    const s = bundleFigureStructure(bundle, three)!;
    expect(s.parts.map(p => `${p.label} ${p.caption}`)).toEqual(['(a) Routing criticality', '(b) Expert variance', '(c) Router variance']);
  });
});

if (process.env.UPDATE_STRUCTURE_FIXTURE) {
  it('rewrites the expectations', () => {
    const out = JSON.parse(readFileSync(file, 'utf8'));
    out.parameters = { ...STRUCTURE };
    for (const c of out.cases) { const s = structureOf(c); c.expect = { structure: s, note: s ? structureNote(s) : null, quote: structureQuote(c.caption, s) }; }
    for (const m of out.matches) m.expect = matchSections(sectionsOf(m), structureOf(out.cases.find((c: { name: string }) => c.name === m.structure)));
    for (const x of out.subcaptions) x.expect = subcaption(x.text);
    for (const x of out.stackLayouts) x.expect = stackLayout(x.sizes);
    writeFileSync(file, JSON.stringify(out, null, 1) + '\n');
  });
}

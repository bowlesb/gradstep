import test from 'node:test';
import assert from 'node:assert/strict';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import type { ImageRequest, RecogniseRequest } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';
import { det, extent, host, input, line, page, type G } from './device-pdf/synthetic.ts';

function convert(options: { display?: boolean; ocr?: boolean; rotated?: boolean; script?: G; glyphs?: G[]; accents?: boolean } = {}) {
  const glyphs = options.glyphs ?? line(options.display ? '$x+1$' : 'Before $x+1$ after.', 54.25, 100.5);
  const own = options.display ? glyphs : glyphs.slice(6, 9);
  if (options.ocr) for (const g of own) g.font = 'GradstepOCR';
  if (options.rotated) for (const g of own) g.upright = false;
  if (options.script) glyphs.splice(9, 0, options.script);
  const pages = [page(glyphs, [det(options.display ? 'display' : 'paragraph', extent(glyphs, 3))])];
  const h = host(pages);
  // Keep the selected span fixed even when the synthetic model misses the neighboring script or sees OCR fonts.
  h.tag = rows => rows.map(row => row.font.map((_, i) => !options.display && i >= 6 && i < 9 ? 5 : -5));
  const recognitions: RecogniseRequest[][] = [];
  h.recognise = crops => { recognitions.push(structuredClone(crops)); return crops.map(() => ({ latex: '999137', probs: [0.1] })); };
  const requests: ImageRequest[] = [];
  const image = h.image;
  h.image = r => { requests.push(structuredClone(r)); return image(r); };
  const bundle = composeDevicePDFReader(input(1, { title: 'Crop ownership', trace: true, accents: options.accents }), h);
  const formulas = requests.filter(r => r.clean);
  assert.equal(formulas.length, 1, 'fixture has exactly one rejected formula image');
  const provenance = JSON.parse(new TextDecoder().decode(bundle.members.get('provenance.json')!));
  return { request: formulas[0], own, provenance, recognitions, bundle };
}

test('upright native inline content uses absolute 216 dpi glyph height and full padded width', () => {
  const { request, own, provenance } = convert();
  const bounds = [Math.min(...own.map(g => g.x0)), Math.min(...own.map(g => g.top)), Math.max(...own.map(g => g.x1)), Math.max(...own.map(g => g.bottom))];
  assert.equal(request.dpi, 216);
  assert.deepEqual(request.clean?.content, [Math.max(0, bounds[0] - 2) * 3, bounds[1] * 3, (bounds[2] + 2) * 3, bounds[3] * 3],
    'fractional absolute page pixels preserve the whole horizontal strip and native glyph height');
  assert.deepEqual(request.rect, [Math.trunc((bounds[0] - 2) * 3), Math.trunc((bounds[1] - 2) * 3), Math.trunc((bounds[2] + 2) * 3 + 0.999), Math.trunc((bounds[3] + 2) * 3 + 0.999)]);
  assert.deepEqual(provenance.equations[0].slice(4, 8), bounds.map(v => Number(v.toFixed(1))), 'PDF source location remains the formula glyph box');
});

for (const options of [{ display: true }, { ocr: true }, { rotated: true }]) {
  test(`${Object.keys(options)[0]} formulas retain legacy cleaning without a content hint`, () => {
    const { request } = convert(options);
    assert.ok(request.clean);
    assert.equal(request.clean.content, undefined);
  });
}

test('an untagged detached same-line script inside the padded crop is included in protection', () => {
  const base = convert();
  const right = Math.max(...base.own.map(g => g.x1));
  const script: G = { text: '2', x0: right + 0.25, x1: right + 1.5, top: 99.5, bottom: 103.5, size: 5, font: 'ABCDEF+CMR10', upright: true };
  const result = convert({ script });
  assert.deepEqual(result.request.rect, base.request.rect, 'no recognition/source crop expansion');
  assert.deepEqual(result.provenance.equations, base.provenance.equations, 'the model decision and original PDF place are unchanged');
  assert.deepEqual(result.request.clean?.content, [base.request.clean!.content![0], script.top * 3, base.request.clean!.content![2], 110.5 * 3]);
});

test('a same-line glyph crossing the horizontal crop boundary retains a full-width protection band', () => {
  const base = convert();
  const right = Math.max(...base.own.map(g => g.x1));
  const script: G = { text: ',', x0: right + 0.25, x1: right + 4, top: 106, bottom: 110.5, size: 6, font: 'ABCDEF+CMR10', upright: true };
  const result = convert({ script });
  assert.deepEqual(result.request.rect, base.request.rect);
  assert.deepEqual(result.provenance.equations, base.provenance.equations);
  assert.deepEqual(result.request.clean?.content, base.request.clean?.content,
    'partial same-line punctuation remains protected even though its glyph continues past the crop');
});

test('a neighboring glyph crossing the vertical crop boundary makes content-guided cleaning abstain', () => {
  const base = convert();
  const right = Math.max(...base.own.map(g => g.x1));
  const script: G = { text: '2', x0: right + 0.25, x1: right + 4, top: 97.5, bottom: 103.5, size: 6, font: 'ABCDEF+CMR10', upright: true };
  const result = convert({ script });
  assert.deepEqual(result.request.rect, base.request.rect);
  assert.deepEqual(result.provenance.equations, base.provenance.equations);
  assert.equal(result.request.clean?.content, undefined, 'a vertically clipped neighboring script must not be erased using an incomplete ownership hint');
});

function assertSameReading(a: ReturnType<typeof convert>, b: ReturnType<typeof convert>) {
  const { content: _a, ...cleanA } = a.request.clean!;
  const { content: _b, ...cleanB } = b.request.clean!;
  assert.deepEqual({ ...a.request, clean: cleanA }, { ...b.request, clean: cleanB }, 'only cleaning eligibility may change');
  assert.deepEqual(a.recognitions, b.recognitions, 'recognition input is unchanged');
  assert.deepEqual(a.provenance, b.provenance, 'source locations and equation decisions are unchanged');
  assert.deepEqual(a.bundle.trace, b.bundle.trace, 'composed text and model results are unchanged');
  for (const name of ['reader.json', 'index.html']) assert.deepEqual(a.bundle.members.get(name), b.bundle.members.get(name), `${name} is unchanged with fake pixels`);
}

test('a composed macron keeps legacy cleaning when the emptied accent extends above its base glyph', () => {
  const glyphs = line('Before $x+1$ after.', 54.25, 100.5);
  glyphs[6].font = 'ABCDEF+CMR10';
  const precomposed = structuredClone(glyphs);
  precomposed[6].text = 'x\u0304';
  glyphs.splice(6, 0, { ...glyphs[6], text: '¯', top: 98.6, bottom: 108.6 });
  const result = convert({ glyphs, accents: true }), control = convert({ glyphs: precomposed, accents: true });
  assert.ok(control.request.clean?.content, 'already composed text without a separate accent does not disable cleaning');
  assert.equal(result.request.clean?.content, undefined, 'the emptied macron must not be erased by the shorter base-glyph band');
  assertSameReading(result, control);
});

test('an emptied accent from another line entering the rounded crop also disables the hint', () => {
  const glyphs = line('Before $x+1$ after.', 54.25, 100.5);
  const base: G = { ...glyphs[6], text: 'x', font: 'ABCDEF+CMR10', top: 120.5, bottom: 130.5 };
  const precomposed = [...structuredClone(glyphs), { ...base, text: 'x\u0304' }];
  // The 216 dpi crop starts at floor((100.5 - 2) * 3) / 3 = 98⅓ pt. The accent reaches only that rounding fringe.
  glyphs.push({ ...base, text: '¯', top: 98.1, bottom: 98.45 }, base);
  const result = convert({ glyphs, accents: true }), control = convert({ glyphs: precomposed, accents: true });
  assert.ok(control.request.clean?.content, 'the other line alone does not disable this formula crop');
  assert.equal(result.request.clean?.content, undefined, 'emptied accents are checked even when their base is outside the line and crop');
  assertSameReading(result, control);
});

test('a composed accent elsewhere on the page does not disable an unaffected formula hint', () => {
  const glyphs = line('Before $x+1$ after.', 54.25, 100.5);
  const precomposed = structuredClone(glyphs);
  precomposed[0].text = 'B\u0304';
  glyphs.splice(0, 0, { ...glyphs[0], text: '¯', top: 98.6, bottom: 108.6 });
  const result = convert({ glyphs, accents: true }), control = convert({ glyphs: precomposed, accents: true });
  assert.ok(result.request.clean?.content, 'only compositions touching this crop require abstention');
  assert.deepEqual(result.request.clean.content, control.request.clean?.content);
  assertSameReading(result, control);
});

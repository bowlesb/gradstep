import test from 'node:test';
import assert from 'node:assert/strict';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { UNTRANSCRIBED_LATEX, UNTRANSCRIBED_TEXT } from '../../supabase/functions/_shared/reader/device-pdf/emit.ts';
import { elements, parseHTML } from '../../supabase/functions/_shared/reader/html.ts';
import { validateHTML } from '../../supabase/functions/_shared/reader/html-validate.ts';
import { det, extent, host, input, line, page } from './device-pdf/synthetic.ts';

function convert(display: boolean, latex: string | null, confidence: number, failImages = false, verifyGlyphs = false) {
  const prose = line(display ? 'The equation follows.' : 'The value $x+1$ is measured.', 54, 100);
  const math = display ? line('$x+1$', 150, 140) : [];
  const pages = [page([...prose, ...math], [det('paragraph', extent(prose)), ...(display ? [det('display', extent(math, 3))] : [])])];
  const h = host(pages, { failImages });
  h.recognise = crops => crops.map(() => latex === null ? null : { latex, probs: [confidence] });
  const bundle = composeDevicePDFReader(input(1, { title: 'Transcription boundary', verifyGlyphs, trace: true }), h);
  const member = (name: string) => new TextDecoder().decode(bundle.members.get(name)!);
  return { bundle, html: member('index.html'), index: JSON.parse(member('reader.json')), provenance: JSON.parse(member('provenance.json')) };
}

for (const display of [false, true]) {
  test(`${display ? 'display' : 'inline'} rejected guesses are absent from delivered text, alt and equation metadata`, () => {
    for (const failImages of [false, true]) {
      const r = convert(display, '999137+888241', 0.1, failImages);
      assert.equal(r.index.equations.length, 1);
      assert.equal(r.index.equations[0].latex, UNTRANSCRIBED_LATEX);
      for (const content of [r.html, JSON.stringify(r.index)]) assert.doesNotMatch(content, /999137|888241/);
      assert.ok(r.index.blocks.some((b: { text: string }) => b.text.includes('transcription unavailable')));
      if (!failImages) assert.ok(r.html.includes(`alt="${UNTRANSCRIBED_TEXT}"`));
      else {
        const fallbacks = elements(parseHTML(r.html), n => n.attribs?.class?.includes('reader-math-fallback'));
        assert.equal(fallbacks.length, 1);
        assert.equal(fallbacks[0].children.map(n => n.data ?? '').join(''), UNTRANSCRIBED_TEXT,
          'the unavailable-crop label is readable text, without LaTeX commands or delimiters');
      }
      assert.equal(r.provenance.equations[0][2], 0);
      assert.ok(r.provenance.equations[0].slice(3, 8).every(Number.isFinite));
      assert.equal(r.bundle.trace!.equations[0].latex, '999137+888241', 'raw answer is retained only in diagnostic trace');
    }
  });
}

test('plain unavailable-crop labels are limited to the device-PDF sentinel; legacy bundles still validate', () => {
  for (const display of [false, true]) {
    const r = convert(display, null, 0, true);
    const validate = (html: string, devicePDF = true, index = r.index) =>
      validateHTML(new TextEncoder().encode(html), index, new Map(), true, devicePDF);
    validate(r.html);
    const legacy = display ? UNTRANSCRIBED_LATEX : `\\(${UNTRANSCRIBED_LATEX}\\)`;
    validate(r.html.replace(`>${UNTRANSCRIBED_TEXT}</span>`, `>${legacy}</span>`));
    assert.throws(() => validate(r.html, false), /equation_representation/,
      'other reader profiles keep their existing fallback contract');
    assert.throws(() => validate(r.html.replace(`>${UNTRANSCRIBED_TEXT}</span>`, '>a plausible guess</span>')),
      /equation_representation/);
    const wrongIndex = structuredClone(r.index);
    wrongIndex.equations[0].latex = 'x+1';
    for (const block of wrongIndex.blocks) block.text = block.text.replaceAll(UNTRANSCRIBED_LATEX, 'x+1');
    assert.throws(() => validate(r.html.replace(`data-latex="${UNTRANSCRIBED_LATEX}"`, 'data-latex="x+1"'), true, wrongIndex),
      /equation_representation/, 'the plain label cannot disguise a different equation source');
  }
});

test('confidence rejection, invalid LaTeX and missing recognitions all use the same safe boundary', () => {
  for (const [latex, confidence] of [['999137', 0.1], ['\\invalidcommand{999137}', 0.99], [null, 0]] as const) {
    const r = convert(true, latex, confidence);
    assert.equal(r.index.equations[0].latex, UNTRANSCRIBED_LATEX);
    assert.doesNotMatch(r.html, /999137|invalidcommand/);
  }
});

test('confidence-accepted and glyph-supported formulas retain searchable LaTeX and MathML', () => {
  for (const [confidence, verifyGlyphs] of [[0.99, false], [0.6, true]] as const) {
    const r = convert(true, 'x+1', confidence, false, verifyGlyphs);
    assert.equal(r.index.equations[0].latex, 'x+1');
    assert.equal(r.provenance.equations[0][2], 1);
    assert.match(r.html, /<math display="block">/);
    assert.doesNotMatch(r.html, /transcription unavailable/);
  }
});

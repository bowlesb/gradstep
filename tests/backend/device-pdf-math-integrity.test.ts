import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import { glyphsAgree, renderMath } from '../../supabase/functions/_shared/reader/device-pdf/math.ts';
import { det, extent, host, input, line, page } from './device-pdf/synthetic.ts';

const agrees = (page: string[], latex: string) => {
  const math = renderMath(latex, true);
  assert.ok(math, `Valid fixture LaTeX: ${latex}`);
  return glyphsAgree(page, math);
};

test('recorded model readings that dropped the integral on pages 18 and 23 are no longer promoted', () => {
  const cases = JSON.parse(readFileSync(new URL('./device-pdf/math-integrity-real.json', import.meta.url), 'utf8'));
  assert.equal(cases.length, 2);
  for (const fixture of cases) {
    assert.equal(agrees(fixture.glyphs, fixture.latex), false, `${fixture.paper} page ${fixture.page}`);
  }
});

test('uncertain equations cannot lose, invent or change named mathematical operators', () => {
  const cases = [
    ['∫f(x)dx', '\\int f(x)dx', 'f(x)dx'],
    ['∑xi', '\\sum x_i', '\\prod x_i'],
    ['x∈A', 'x\\in A', 'xA'],
    ['x≠y', 'x\\ne y', 'x=y'],
    ['x±y', 'x\\pm y', 'x\\mp y'],
    ['x⊗y', 'x\\otimes y', 'xy'],
    ['∂ft', '\\partial f t', '\\frac{\\partial f}{\\partial t}'],
    ['√xy', '\\sqrt{xy}', 'xy'],
    ['xy', 'xy', '\\sqrt{xy}'],
    ['√x√y', '\\sqrt{x}\\sqrt{y}', '\\sqrt{xy}'],
  ];
  for (const [source, correct, wrong] of cases) {
    assert.equal(agrees([...source], correct), true, correct);
    assert.equal(agrees([...source], wrong), false, `${source} must not verify ${wrong}`);
  }
});

test('every unnamed font glyph needs a corresponding mathematical symbol or balanced delimiter', () => {
  for (const unknown of ['(cid:90)', '(cid:82)', '\uE000', '\uFFFD', '\uFFFC']) {
    assert.equal(agrees([unknown, ...'f(x)dx'], 'f(x)dx'), false, unknown);
    assert.equal(agrees([unknown, ...'f(x)dx'], '\\int f(x)dx'), !['\uFFFD', '\uFFFC'].includes(unknown), unknown);
  }
  assert.equal(agrees(['𝑥', '∈', 'ℝ'], 'x\\in\\mathbb{R}'), true);
  assert.equal(agrees(['d', 'i', 'ﬀ', 'x'], '\\mathrm{diff}x'), true, 'named ligatures');
  assert.equal(agrees(['di', 'ﬀ', 'x'], '\\mathrm{diff}x'), false, 'this guard does not broaden the original character evidence');
  assert.equal(agrees(['(cid:18)', 'x', '+', 'y', '(cid:19)'], '(x+y)'), true, 'every unnamed glyph has a balanced delimiter slot');
  assert.equal(agrees(['(cid:18)', 'x', '+', 'y'], '(x+y)'), false, 'one unknown cannot account for two delimiters');
  assert.equal(agrees(['(cid:18)', 'x', '+', 'y', '(cid:90)'], 'x+y'), false, 'two omitted operators cannot be discarded');
  assert.equal(agrees(['(cid:18)', 'x', '+', 'y', '(cid:19)', '(cid:90)'], '(x+y)'), false, 'a delimiter pair cannot hide an integral');
  assert.equal(agrees(['(cid:18)', 'x', '+', 'y', '(cid:19)', '(cid:90)'], '\\int(x+y)'), true, 'all three unnamed glyphs accounted for');
  assert.equal(agrees(['(cid:90)', 'x', '+', 'y'], 'ax+y'), false, 'an unknown cannot explain an extra letter');
  assert.equal(agrees(['(cid:90)', 'x', '+', 'y'], '\\int xy'), false, 'an unknown cannot excuse a missing named operator');
});

test('equivalent PDF and MathML symbol encodings keep correct equations typeset', () => {
  for (const [source, latex] of [
    ['x·y', 'x\\cdot y'], ['x∙y', 'x\\cdot y'], ['x···y', 'x\\cdots y'],
    ['A\\B', 'A\\setminus B'], ['f◦g', 'f\\circ g'], ['x≠y', 'x\\ne y'],
    ['∫∫fxy', '\\iint fxy'], ['3√x', '\\sqrt[3]{x}'],
  ]) assert.equal(agrees([...source], latex), true, `${source}: ${latex}`);
});

test('the reader bundle keeps the original PDF crop and source region when uncertain math fails verification', () => {
  const before = line('The original equation follows.', 54, 100);
  const equation = line('$∫f(x)dx$', 180, 140);
  const pages = [page([...before, ...equation], [det('paragraph', extent(before)), det('display', extent(equation, 3))])];
  const convert = (latex: string) => {
    const h = host(pages);
    h.recognise = crops => crops.map(() => ({ latex, probs: [0.6, 0.7, 0.99] }));
    const bundle = composeDevicePDFReader(input(1, { title: 'Integral fixture', verifyGlyphs: true, trace: true }), h);
    return { bundle, html: new TextDecoder().decode(bundle.members.get('index.html')!), log: h.log };
  };
  const correct = convert('\\int f(x)dx'), missing = convert('f(x)dx');
  assert.match(correct.html, /<math display="block">/);
  assert.doesNotMatch(correct.html, /reader-math-image/);
  assert.match(missing.html, /reader-display reader-math-image/);
  assert.doesNotMatch(missing.html, /<math display="block">/);
  assert.equal(missing.log.images.length, 1);
  const crop = missing.log.images[0];
  assert.equal(crop.page, 0);
  assert.equal(crop.dpi, 216);
  assert.ok(crop.rect[0] / 3 < equation[0].x0 && crop.rect[2] / 3 > equation.at(-1)!.x1);
  const src = /<img[^>]*src="([^"]+)"/.exec(missing.html)![1];
  assert.ok(missing.bundle.members.has(src), 'the fallback image is in the verified bundle');
  assert.equal(missing.bundle.trace!.equations[0].id, correct.bundle.trace!.equations[0].id);
  const provenance = (bundle: typeof missing.bundle) => JSON.parse(new TextDecoder().decode(bundle.members.get('provenance.json')!));
  const original = provenance(correct.bundle).equations[0], fallback = provenance(missing.bundle).equations[0];
  assert.equal(original[2], 1);
  assert.equal(fallback[2], 0);
  assert.deepEqual(fallback.slice(3), original.slice(3), 'the page and PDF bounds survive the fallback');
});

test('an unnamed integral inside an inline equation uses the PDF crop in the reading', () => {
  const glyphs = line('Consider $∫f(x)dx$ in this argument.', 54, 100);
  glyphs.find(g => g.text === '∫')!.text = '(cid:90)';
  const h = host([page(glyphs, [det('paragraph', extent(glyphs))])]);
  h.recognise = crops => crops.map(() => ({ latex: 'f(x)dx', probs: [0.7, 0.99] }));
  const bundle = composeDevicePDFReader(input(1, { title: 'Inline integral', verifyGlyphs: true }), h);
  const html = new TextDecoder().decode(bundle.members.get('index.html')!);
  assert.match(html, /reader-inline reader-math-image/);
  assert.match(html, /Consider /);
  assert.match(html, /in this argument/);
  assert.equal(h.log.images.length, 1);
});

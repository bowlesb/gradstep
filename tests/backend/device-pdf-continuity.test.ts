import { test } from 'node:test';
import assert from 'node:assert/strict';
import { composeDevicePDFReader } from '../../supabase/functions/_shared/reader/device-pdf/bundle.ts';
import type { PageInput } from '../../supabase/functions/_shared/reader/device-pdf/types.ts';
import { det, extent, host, input, line, page } from './device-pdf/synthetic.ts';

const paragraph = (text: string, y: number, size = 10) => {
  const gl = line(text, 72, y, size);
  return page(gl, [det('paragraph', extent(gl))]);
};
function convert(pages: PageInput[]) {
  const h = host(pages), bundle = composeDevicePDFReader(input(pages.length, { title: 'Continuity', transcribe: true }), h);
  const json = (name: string) => JSON.parse(new TextDecoder().decode(bundle.members.get(name)!));
  const reader = json('reader.json'), provenance = json('provenance.json');
  return { reader, provenance, paragraphs: reader.blocks.filter((b: { kind: string }) => b.kind === 'paragraph'), h };
}

test('a sentence continued after a page break has one paragraph and both PDF places', () => {
  const { paragraphs, provenance } = convert([paragraph('The cells grow in a medium containing', 700), paragraph('alginate and other nutrients.', 80)]);
  assert.deepEqual(paragraphs.map((p: { text: string }) => p.text), ['The cells grow in a medium containing alginate and other nutrients.']);
  assert.deepEqual(provenance.blocks.filter((b: unknown[]) => b[0] === paragraphs[0].id).map((b: unknown[]) => b[1]), [0, 1]);
});

test('a hyphenated word and a parenthesized term continue across pages', () => {
  for (const [left, right, expected] of [
    ['The differentiation assay measures differenti-', 'ation in the sample.', 'The differentiation assay measures differentiation in the sample.'],
    ['We introduced the transgene (abc-1)', 'into the mutant cells.', 'We introduced the transgene (abc-1) into the mutant cells.'],
    ['The assay uses the “closed”', 'labeling setup for cells.', 'The assay uses the “closed” labeling setup for cells.'],
  ]) {
    const { paragraphs } = convert([paragraph(left, 700), paragraph(right, 80)]);
    assert.deepEqual(paragraphs.map((p: { text: string }) => p.text), [expected]);
  }
});

test('a completed sentence, including quoted punctuation, stays separate', () => {
  for (const left of ['The experiment ended.', 'The experiment ended.)', 'They called it “complete.”', 'The following conditions:']) {
    const { paragraphs } = convert([paragraph(left, 700), paragraph('another paragraph begins here.', 80)]);
    assert.equal(paragraphs.length, 2, left);
  }
});

test('page counters and small footer text do not join the next body paragraph', () => {
  for (const [text, size] of [['9 of 22', 10], ['9 / 22', 10], ['Page 1 of 13', 10], ['An Author', 10], ['12', 10], ['(3.14)', 10], ['Publisher footer without punctuation', 8]] as const) {
    const { paragraphs } = convert([paragraph(text, 700, size), paragraph('continuing the body of the article.', 80, 10)]);
    assert.equal(paragraphs.length, 2, text);
  }
});

test('a broken word without independent support stays split instead of inventing a word', () => {
  const { paragraphs } = convert([paragraph('The experiment is requir-', 700), paragraph('aging in the specimen.', 80)]);
  assert.equal(paragraphs.length, 2);
  assert.ok(!paragraphs.some((p: { text: string }) => p.text.includes('requiraging')));
});

test('a supported compound retains its hyphen, and abstains when compound handling is disabled', () => {
  const pages = [paragraph('The cell-level assay measures cell-', 700), paragraph('level effects in the sample.', 80)];
  for (const compounds of [true, false]) {
    const bundle = composeDevicePDFReader(input(2, { title: 'Continuity', compounds }), host(pages));
    const ps = JSON.parse(new TextDecoder().decode(bundle.members.get('reader.json')!)).blocks.filter((b: { kind: string }) => b.kind === 'paragraph');
    assert.equal(ps.length, compounds ? 1 : 2);
    if (compounds) assert.equal(ps[0].text, 'The cell-level assay measures cell-level effects in the sample.');
  }
});

test('boundary-line typography guards mixed regions at either side of a page break', () => {
  const body = line('The experiment continues with', 72, 680), doi = line('https://example.test/figure', 72, 700, 8);
  const mixedEnd = page([...body, ...doi], [det('paragraph', extent([...body, ...doi]))]);
  assert.equal(convert([mixedEnd, paragraph('the remainder of the experiment.', 80)]).paragraphs.length, 2);
  const small = line('https://example.test/figure', 72, 80, 8), next = line('the remainder of the experiment.', 72, 100);
  const mixedStart = page([...small, ...next], [det('paragraph', extent([...small, ...next]))]);
  assert.equal(convert([paragraph('The experiment continues with', 700), mixedStart]).paragraphs.length, 2);
});

test('a blank or figure-only intervening page does not join distant paragraphs', () => {
  for (const middle of [page([], []), page([], [det('figure', [72, 80, 500, 650])])]) {
    assert.equal(convert([paragraph('The experiment continues with', 700), middle, paragraph('another passage here.', 80)]).paragraphs.length, 2);
  }
});

test('a heading or display between the fragments closes the paragraph', () => {
  for (const cls of ['heading', 'display']) {
    const between = line(cls === 'heading' ? 'Results' : '$x$', 72, 80), body = line('another paragraph begins here.', 72, 120);
    const next = page([...between, ...body], [det(cls, extent(between)), det('paragraph', extent(body))]);
    assert.equal(convert([paragraph('The experiment continues with', 700), next]).paragraphs.length, 2);
  }
});

test('a figure above the continuation keeps its own region while the sentence joins below it', () => {
  const body = line('alginate and other nutrients.', 72, 550), cap = line('Figure 1. The experiment.', 72, 490, 8);
  const second = page([...body, ...cap], [det('figure', [72, 80, 500, 470]), det('caption', extent(cap)), det('paragraph', extent(body))]);
  const { paragraphs, reader, provenance } = convert([paragraph('The cells grow in a medium containing', 700), second]);
  assert.equal(paragraphs.length, 1);
  assert.equal(reader.figures.length, 1);
  assert.deepEqual(provenance.blocks.filter((b: unknown[]) => b[0] === paragraphs[0].id).map((b: unknown[]) => b[1]), [0, 1]);
  assert.ok(provenance.blocks.some((b: unknown[]) => b[0] === reader.figures[0].block_id && b[1] === 1));
});

test('duplicate layout boxes after a page join cannot repeat words or inline equations', () => {
  for (const end of ['.', '']) {
    const gl = line(`the value of $x$ in the sample${end}`, 72, 80), box = det('paragraph', extent(gl));
    const { paragraphs, reader, provenance } = convert([paragraph('The experiment determines', 700), page(gl, [box, { ...box }])]);
    assert.equal(paragraphs.length, 1);
    assert.equal((paragraphs[0].text.match(/the value/g) ?? []).length, 1);
    assert.equal(reader.equations.length, 1);
    assert.equal(reader.equations[0].block_id, paragraphs[0].id);
    assert.equal(provenance.blocks.filter((b: unknown[]) => b[0] === paragraphs[0].id).length, 2);
  }
});

test('ordinary same-page paragraph separation keeps its existing punctuation rule', () => {
  const a = line('We introduced the transgene (abc-1)', 72, 100), b = line('into the mutant cells.', 72, 200);
  assert.equal(convert([page([...a, ...b], [det('paragraph', extent(a)), det('paragraph', extent(b))])]).paragraphs.length, 2);
});

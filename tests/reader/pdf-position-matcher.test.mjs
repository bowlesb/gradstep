import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source = readFileSync(new URL('../../apps/apple/ScienceReader/Resources/pdf-position-matcher.js', import.meta.url), 'utf8');
export const matcher = new Function(source + '; return PDFPositionMatcher;')();
const passage = 'The efficient transformer learns robust representations using sparse attention across multiple independent training examples.';

test('finds prose and returns original UTF-16 offsets through ligatures, accents and line-end hyphenation', () => {
  const text = '😀 preface\nThe efﬁcient trans-\nformer learns robust representations using sparse attention across multiple independent training examples.';
  const result = matcher.create(['unrelated introduction', text]).match(passage);
  assert.equal(result.status, 'matched'); assert.equal(result.ranges[0].page, 1);
  const r = result.ranges[0]; assert.equal(text.slice(r.location, r.location+r.length), text.slice(11,-1));
});
test('repeated passages abstain, even if document progress could suggest a page', () => {
  assert.equal(matcher.create([passage, 'elsewhere', passage]).match(passage).reason, 'ambiguous');
});
test('nearby distinguishing text resolves duplicate boilerplate', () => {
  const suffix = ' A spectral penalty improves calibration for unseen robot trajectories.';
  const result = matcher.create([passage, passage+suffix]).match(passage+suffix);
  assert.equal(result.status, 'matched'); assert.equal(result.ranges[0].page, 1);
});
test('changed whitespace and missing words retain localization', () => {
  const result = matcher.create([passage]).match(passage.replace('robust ', '').replaceAll(' ', '\n'));
  assert.equal(result.status, 'matched');
});
test('short, formula-only, absent, empty and repetitive queries cannot fabricate highlights', () => {
  const index = matcher.create([passage]);
  for (const query of ['', 'Introduction', 'x = y + z', 'the the the the the the', 'The maritime vessel crossed Atlantic waters before docking in northern coastal harbors.']) assert.equal(index.match(query).status, 'unmatched');
  assert.equal(matcher.create(['']).match(passage).reason, 'no-text');
});
test('matches passages crossing PDF page boundaries with separate valid ranges', () => {
  const pages = [passage.slice(0,74), passage.slice(74)];
  const result = matcher.create(pages).match(passage);
  assert.equal(result.status, 'matched'); assert.equal(result.ranges.length, 2);
  for (const r of result.ranges) assert.ok(r.location >= 0 && r.length > 0 && r.location+r.length <= pages[r.page].length);
});
test('resource bounds refuse instead of silently indexing only part of a PDF', () => {
  assert.throws(() => matcher.create(Array(513).fill('')));
  assert.throws(() => matcher.create(['x'.repeat(200001)]));
  assert.throws(() => matcher.create([null]));
  assert.equal(matcher.create([passage]).match('x'.repeat(2401)).reason, 'query-limit');
});
test('a nearer weak passage cannot outrank an exact distant match', () => {
  const index = matcher.create(['transformer sparse efficient training independent robust unrelated content', passage]);
  assert.equal(index.match(passage).ranges[0].page, 1);
  assert.deepEqual(index.match(passage), index.match(passage));
});

test('a paragraph continuation after an interrupting figure cannot replace its requested opening', () => {
  const opening = 'Distinctive maritime observations describe coastal migration patterns across northern archipelagos during seasonal temperature variations.';
  const continuation = ' In this detailed analysis we present robust measurements of the resulting phenomena and compare multiple alternative assumptions using carefully controlled independent experimental observations.';
  const pages = [opening + ' Footnote ' + 'interrupting illustration labels and credits '.repeat(40) + continuation];
  const result = matcher.create(pages).match(opening + continuation);
  if (result.status === 'matched') assert.ok(result.ranges[0].location < opening.length);
});

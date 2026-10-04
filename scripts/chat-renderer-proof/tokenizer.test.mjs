import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tokenize, copyMessage, copyEquation } from './tokenizer.mjs';
import { sourceFixtures } from './source-fixtures.mjs';

for (const fixture of sourceFixtures) test(fixture.id, () => {
  const result = tokenize(fixture.source);
  // Failure diagnostics contain only the fixture ID and finite status values.
  assert.equal(result.code, fixture.expected);
  if (result.code !== 'ok') { assert.deepEqual(Object.keys(result), ['code']); return; }
  assert.equal(copyMessage(result) === fixture.source, true);
  assert.equal(result.equations.length, fixture.equations.length);
  assert.equal(new Set(result.equations.map(item => item.id)).size, result.equations.length);
  result.equations.forEach((equation, i) => {
    assert.equal(equation.latex === fixture.equations[i], true, 'Exact authored LaTeX');
    assert.equal(copyEquation(result, equation.id) === fixture.equations[i], true, 'Source-based equation copy');
    assert.equal(fixture.source.slice(equation.body.start, equation.body.end) === equation.latex, true);
    if (fixture.starts) assert.equal(equation.raw.start, fixture.starts[i]);
    if (i) assert.ok(equation.raw.start >= result.equations[i - 1].raw.end);
  });
  let previousEnd = 0;
  for (const block of result.blocks) {
    assert.ok(block.raw.start >= previousEnd && block.raw.end <= fixture.source.length);
    previousEnd = block.raw.end;
    if (block.kind === 'paragraph') {
      assert.equal(block.parts.map(part => fixture.source.slice(part.raw.start, part.raw.end)).join('')
        === fixture.source.slice(block.content.start, block.content.end), true, 'Lossless inline partition');
    }
  }
});

test('original paragraph offsets do not use repeated text search', () => {
  const source = '  $x$\n\n  $x$\n';
  const result = tokenize(source);
  assert.equal(result.code, 'ok');
  assert.deepEqual(result.equations.map(item => item.raw), [{ start: 2, end: 5 }, { start: 9, end: 12 }]);
});

test('raw code spans preserve whitespace even when markdown display normalizes it', () => {
  const source = 'a `` one\n$x$ `` b';
  const result = tokenize(source);
  assert.equal(result.code, 'ok');
  const part = result.blocks[0].parts.find(part => part.kind === 'code');
  assert.equal(source.slice(part.raw.start, part.raw.end) === '`` one\n$x$ ``', true);
  assert.equal(source.slice(part.body.start, part.body.end) === ' one\n$x$ ', true);
});

test('mixed repeated equations, whitespace and non-BMP prefixes retain exact spans', () => {
  for (const prefix of ['', ' ', '🧠 ', 'e\u0301 ', '\tcode\n\n']) {
    const source = prefix + 'a $x$ b $x$\n';
    const result = tokenize(source);
    assert.equal(result.code, 'ok');
    assert.deepEqual(result.equations.map(item => item.raw.start), [prefix.length + 2, prefix.length + 8]);
  }
});

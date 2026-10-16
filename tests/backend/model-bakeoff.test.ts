import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { SpendLedger, rateCeiling, requestCeiling, validateGrades, validateQuestions } from '../../scripts/model-bakeoff-support.mjs';

test('bake-off concurrent admissions count outstanding calls and preserve them after restart', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bakeoff-budget-'));
  try {
    const path = join(dir, 'ledger.json'), ledger = new SpendLedger(path, 1);
    const first = ledger.reserve(0.6, { model: 'one' });
    ledger.identify(first, 'gen-fixture');
    assert.throws(() => ledger.reserve(0.6, { model: 'two' }), /Budget admission refused/);
    ledger.settle(first, undefined);
    const resumed = new SpendLedger(path, 1);
    assert.equal(resumed.rows[0].generation, 'gen-fixture');
    assert.throws(() => resumed.identify(first, 'different-generation'), /identity changed/);
    assert.equal(resumed.outstanding, 0.6);
    assert.throws(() => resumed.reserve(0.5, {}), /Budget admission refused/);
    resumed.settle(first, 0.1);
    assert.equal(resumed.actual, 0.1);
    assert.equal(resumed.outstanding, 0);
    resumed.reserve(0.9, {});
    assert.equal(resumed.exposure, 1);
  } finally { rmSync(dir, { recursive: true }); }
});

test('bake-off missing usage is never free, and an overrun stops new admissions', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bakeoff-budget-'));
  try {
    const ledger = new SpendLedger(join(dir, 'ledger.json'), 2);
    const id = ledger.reserve(0.5, {});
    for (const cost of [null, NaN, -1, '0.1']) ledger.settle(id, cost);
    assert.equal(ledger.exposure, 0.5);
    ledger.settle(id, 0.7);
    assert.throws(() => ledger.reserve(0.1, {}), /overrun/);
    assert.throws(() => new SpendLedger(join(dir, 'ledger.json'), NaN), /cap/);
    assert.throws(() => new SpendLedger(join(dir, 'ledger.json'), 19), /cap/);
  } finally { rmSync(dir, { recursive: true }); }
});

test('bake-off holds cover the expensive length tier, hourly cache creation and output', () => {
  const rates = rateCeiling([{ pricing: { prompt: '0.0000001', completion: '0.0000005', input_cache_write_1h: '0.0000002',
    overrides: [{ min_prompt_tokens: 100000, prompt: '0.0000005', completion: '0.0000025', input_cache_write_1h: '0.000001' }] } }]);
  assert.equal(rates.input, 0.000001);
  assert.equal(rates.output, 0.0000025);
  assert.ok(requestCeiling([{ role: 'user', content: 'x'.repeat(200000) }], [], 10000, rates) > 0.225);
  assert.throws(() => rateCeiling([]), /endpoint/);
  assert.throws(() => rateCeiling([{ pricing: { prompt: 'bad', completion: '0.1' } }]), /price/);
});

test('bake-off rejects missing, duplicate, out-of-range and malformed grades', () => {
  const grade = { label: 'A', key_points_hit: [0], errors: [], correctness: 8, completeness: 8, faithfulness: 8, citations: 8, clarity: 8, overall: 8, comment: 'Supported' };
  assert.equal(validateGrades([grade], ['A'], 1), true);
  assert.equal(validateGrades([grade], ['A', 'B'], 1), false);
  assert.equal(validateGrades([grade, grade], ['A', 'B'], 1), false);
  assert.equal(validateGrades([{ ...grade, overall: 11 }], ['A'], 1), false);
  assert.equal(validateGrades([{ ...grade, key_points_hit: [1] }], ['A'], 1), false);
});

test('bake-off refuses placeholder references and source paragraphs outside the bundle', () => {
  const paper = () => ({ index: { blocks: [{}, {}], figures: [{}] } });
  const q = { id: 'test-q', paper: 'test', question: 'Why?', type: 'explain', reference: 'A verified reference answer long enough to contain substantive claims.', key_points: [{ point: 'Evidence', paragraphs: [2] }], errors_to_penalize: [], figure: 1 };
  assert.equal(validateQuestions([q], paper).length, 1);
  assert.throws(() => validateQuestions([{ ...q, reference: 'x' }], paper), /Incomplete/);
  assert.throws(() => validateQuestions([{ ...q, figure: 2 }], paper), /figure/);
  assert.throws(() => validateQuestions([{ ...q, key_points: [{ point: 'Evidence', paragraphs: [3] }] }], paper), /paragraph/);
  assert.throws(() => validateQuestions([q, q], paper), /duplicate/);
});

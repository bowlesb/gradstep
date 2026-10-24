// The gte-small tokenizer matches Hugging Face `tokenizers` exactly, with padding off (docs/architecture/INTEREST_INDEX.md
// §1). Fixture: tests/fixtures/interest/tokenizer-parity.json (thenlper/gte-small@17e1f347 via Python tokenizers, padding
// off, truncation 512): 70 pool abstracts, one over 512 tokens, and ten hostile strings.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { CLS_ID, MAX_TOKENS, PAD_ID, SEP_ID, WordPiece } from '../../supabase/functions/_shared/interest/wordpiece.ts';

const vocabText = readFileSync(new URL('../../services/pipeline-worker/model/vocab.txt', import.meta.url), 'utf8');
const fixture = JSON.parse(readFileSync(new URL('../fixtures/interest/tokenizer-parity.json', import.meta.url), 'utf8')) as
  { cases: { text: string; ids: number[] }[] };
const wordpiece = new WordPiece(vocabText);

test('the vocabulary is gte-small@17e1f347 vocab.txt', () => {
  assert.equal(createHash('sha256').update(vocabText).digest('hex'), '07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3');
  assert.equal(wordpiece.size, 30522);
});

test('token ids equal Hugging Face tokenizers for every fixture text', () => {
  assert.ok(fixture.cases.length >= 80);
  for (const { text, ids } of fixture.cases) assert.deepEqual(wordpiece.encode(text), ids, text.slice(0, 60));
});

test('padding is pinned off: one id per real token, never [PAD], [CLS] … [SEP]', () => {
  for (const { text } of fixture.cases) {
    const ids = wordpiece.encode(text);
    assert.equal(ids[0], CLS_ID);
    assert.equal(ids.at(-1), SEP_ID);
    assert.ok(!ids.includes(PAD_ID), 'no pad token');
    assert.ok(ids.length <= MAX_TOKENS);
  }
  // A short text stays short: the shipped tokenizer.json would have padded it to 128.
  assert.deepEqual(wordpiece.encode('kv cache'), [CLS_ID, 24888, 17053, SEP_ID]);
  assert.deepEqual(wordpiece.encode(''), [CLS_ID, SEP_ID]);
});

test('truncation keeps 512 tokens including [CLS] and [SEP]', () => {
  const long = fixture.cases.find(c => c.ids.length === MAX_TOKENS);
  assert.ok(long, 'the fixture has a truncated text');
  assert.equal(wordpiece.encode(long.text).length, MAX_TOKENS);
});

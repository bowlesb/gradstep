// Interest index term layer and artifact codecs (docs/architecture/INTEREST_INDEX.md §3–4). The n-gram counts must equal
// scikit-learn's CountVectorizer exactly (tests/fixtures/interest/ngrams.json, generated with terms.py's settings and
// min_df 2 / max_df 0.5 on 40 pool papers); the codecs must round-trip.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { countVocabulary, documentText, ngrams, tokens } from '../../supabase/functions/_shared/interest/ngrams.ts';
import {
  DIM, Q8_BYTES, dequantize, fromHalfvecSend, mapBody, normalize, pack, quantize, readMapCentroids, readShard, readTerms,
  shardBody, termsBody, unpack,
} from '../../supabase/functions/_shared/interest/codec.ts';
import { STOP_WORDS } from '../../supabase/functions/_shared/interest/stopwords.ts';
import { conceptness, finishPaperTerms, nodeTerms, paperCandidates } from '../../supabase/functions/_shared/interest/terms.ts';

const fixture = JSON.parse(readFileSync(new URL('../fixtures/interest/ngrams.json', import.meta.url), 'utf8')) as {
  docs: { title: string; abstract: string }[]; vocabulary: Record<string, number>; doc0_counts: Record<string, number> };

test('stop words are scikit-learn English plus the domain list (410)', () => {
  const stop = JSON.parse(readFileSync(new URL('../fixtures/interest/stopwords.json', import.meta.url), 'utf8'));
  assert.deepEqual([...STOP_WORDS], [...new Set([...stop.sklearn_english, ...stop.domain])].sort());
  assert.equal(STOP_WORDS.length, 410);
});

test('tokens follow Python word boundaries and drop stop words before n-grams', () => {
  // "naïve": no boundary before "ï" in Python, so nothing; "3d" starts with a digit; "models" is a domain stop word.
  assert.deepEqual(tokens('The KV-cache of naïve GPT-4o models, 3D x'), ['kv-cache', 'gpt-4o']);
  assert.deepEqual(tokens('naïve café résumé'), []);
  assert.deepEqual(ngrams(['a', 'b', 'c']), ['a', 'b', 'c', 'a b', 'b c', 'a b c']);
  // "learning of representations" -> the stop word goes first, so the bigram spans it.
  assert.ok(ngrams(tokens('sparse learning of representations')).includes('learning representations'));
});

test('vocabulary and document frequencies equal scikit-learn CountVectorizer', () => {
  const vocab = countVocabulary(fixture.docs.map(d => documentText(d.title, d.abstract)), 2, 0.5);
  const got = Object.fromEntries(vocab.terms.map((t, i) => [t, vocab.df[i]]));
  assert.deepEqual(got, fixture.vocabulary);
  const doc0 = vocab.docTerms[0];
  assert.deepEqual(Object.fromEntries(Array.from(doc0.ids, (t, i) => [vocab.terms[t], doc0.counts[i]])), fixture.doc0_counts);
});

const unit = (seed: number) => {
  const v = new Float32Array(DIM);
  for (let i = 0; i < DIM; i++) v[i] = Math.sin(seed * 97 + i * 13.37);
  return normalize(v);
};

test('q8 keeps cosine above 0.9998 and halfvec_send decodes', () => {
  const v = unit(1);
  const q = quantize(v);
  assert.equal(q.length, Q8_BYTES);
  const back = normalize(dequantize(q));
  let c = 0;
  for (let i = 0; i < DIM; i++) c += v[i] * back[i];
  assert.ok(c > 0.9998, String(c));
  const send = new Uint8Array(4 + 2 * DIM);
  const view = new DataView(send.buffer);
  view.setInt16(0, DIM, false);
  view.setUint16(4, 0x3c00, false);   // 1.0
  view.setUint16(6, 0xc000, false);   // -2.0
  view.setUint16(8, 0x3555, false);   // ~0.33325
  const h = fromHalfvecSend(send);
  assert.equal(h[0], 1); assert.equal(h[1], -2); assert.ok(Math.abs(h[2] - 0.33325) < 1e-4);
});

test('shard, terms and map artifacts round-trip through gzip', async () => {
  const papers = [{ sourceID: '2610.00001', announcedOn: '2026-10-23', q8: quantize(unit(2)) },
    { sourceID: 'cs/0211004', announcedOn: '2026-10-08', q8: quantize(unit(3)) }];
  const shard = await pack({ kind: 'shard', format: 1, papers: 2 }, shardBody(papers));
  const s = await unpack(shard);
  assert.equal(s.header.kind, 'shard');
  assert.deepEqual(readShard(s.body), papers);

  const stats = [{ term: 'kv cache', df: 31, conceptness: 0.037 }, { term: 'kv', df: 200, conceptness: -0.004 },
    { term: 'speculative decoding', df: 12, conceptness: 0.058 }, { term: 'é', df: 3, conceptness: 0.5 }];
  const t = await unpack(await pack({ kind: 'terms', format: 1 }, termsBody(stats)));
  assert.deepEqual(readTerms(t.body), [
    { term: 'kv', df: 200, conceptness: -0.004 }, { term: 'kv cache', df: 31, conceptness: 0.037 },
    { term: 'speculative decoding', df: 12, conceptness: 0.058 }, { term: 'é', df: 3, conceptness: 0.127 }]);

  const cents = [unit(4), unit(5)];
  const m = await unpack(await pack({ kind: 'map', format: 1, nodes: [] }, mapBody(cents)));
  const back = readMapCentroids(m.body, 2);
  assert.ok(back[1].reduce((s, x, i) => s + x * cents[1][i], 0) > 0.9998);
  await assert.rejects(unpack(await pack({ kind: 'map', format: 2 as 1 }, new Uint8Array())), /interest_artifact_format/);
});

test('terms: conceptness, per-paper TF-IDF terms and c-TF-IDF node terms behave as terms.py', () => {
  const texts = fixture.docs.map(d => documentText(d.title, d.abstract));
  const vocab = countVocabulary(texts, 2, 0.5);
  const n = texts.length;
  const E = new Float32Array(n * DIM);
  for (let d = 0; d < n; d++) E.set(unit(10 + (d % 4)), d * DIM);   // four "topics"
  const termVec = (t: number) => unit(10 + (t % 4));
  const conc = conceptness(vocab, E, termVec);
  assert.equal(conc.length, vocab.terms.length);
  assert.ok(conc.every(x => Number.isFinite(x)));
  const lookup = (term: string) => { const t = vocab.terms.indexOf(term); return t < 0 ? undefined : { df: vocab.df[t], conceptness: conc[t] }; };
  const vec = (term: string) => { const t = vocab.terms.indexOf(term); return t < 0 ? undefined : termVec(t); };
  const candidates = paperCandidates(fixture.docs[0].title, fixture.docs[0].abstract, lookup, n);
  assert.ok(candidates.length > 0 && candidates.length <= 40);
  for (let i = 1; i < candidates.length; i++) assert.ok(candidates[i - 1][1] >= candidates[i][1], 'TF-IDF order');
  const picked = finishPaperTerms(candidates, E.subarray(0, DIM), vec, lookup, 5, -1);
  assert.ok(picked.length > 0 && picked.length <= 5);
  assert.deepEqual(finishPaperTerms(candidates, E.subarray(0, DIM), vec, lookup, 5, 2), [], 'the concept filter drops everything at 2');
  for (const a of picked) for (const b of picked) if (a !== b) assert.ok(!a.includes(b), `${a} / ${b} not substrings`);
  const terms = nodeTerms(vocab, [[0, 1, 2, 3, 4], [5, 6, 7, 8, 9]], 6);
  assert.equal(terms.length, 2);
  assert.ok(terms[0].length > 0 && terms[0].length <= 6);
});

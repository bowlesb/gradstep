// Slow and opt-in (docs/TESTING.md): the worker's gte-small embedder reproduces the step-1 reference vectors
// (sentence-transformers fp32, tests/fixtures/interest/reference-vectors.json) with cos >= 0.9999, and padding inside a
// batch never changes a fingerprint. Needs `npm ci` in services/pipeline-worker and the fp32 ONNX model:
//   INTEREST_MODEL_PATH=/path/to/model.onnx node --test tests/interest/embed-parity.test.ts
// (Xenova/gte-small@5927d17 onnx/model.onnx; the embedder refuses any other file by its SHA-256.)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { createEmbedder } from '../../services/pipeline-worker/interest-embed.ts';
import { interestText } from '../../supabase/functions/_shared/interest/job.ts';

const modelPath = process.env.INTEREST_MODEL_PATH;
// As in the image: ONNX Runtime's telemetry stays off (the embedder refuses to load the runtime otherwise).
process.env.ORT_DISABLE_TELEMETRY = '1';
const fixture = JSON.parse(readFileSync(new URL('../fixtures/interest/reference-vectors.json', import.meta.url), 'utf8')) as
  { papers: { title: string; abstract: string; f32: string }[] };
const cos = (a: Float32Array, b: Float32Array) => a.reduce((s, x, i) => s + x * b[i], 0);

test('fp32 ONNX fingerprints equal the step-1 vectors; batching and padding change nothing', { skip: !modelPath && 'INTEREST_MODEL_PATH not set' }, async () => {
  const embed = await createEmbedder({ modelPath: pathToFileURL(modelPath!) });
  const texts = fixture.papers.map(p => interestText(p.title, p.abstract));
  const batched = await embed([...texts, 'kv cache', 'speculative decoding']);
  for (const [i, p] of fixture.papers.entries()) {
    const ref = new Float32Array(Uint8Array.from(Buffer.from(p.f32, 'base64')).buffer);
    assert.ok(cos(batched[i], ref) >= 0.9999, `paper ${i}: cos ${cos(batched[i], ref)}`);
  }
  // A phrase alone and inside a batch with long abstracts (padded to their length) gets the same vector.
  const [alone] = await embed(['kv cache']);
  assert.ok(cos(alone, batched[texts.length]) > 0.99999, 'padding never enters the mean');
  await assert.rejects(createEmbedder({ modelPath: new URL('../fixtures/interest/stopwords.json', import.meta.url) }), /interest_model_mismatch/);
});

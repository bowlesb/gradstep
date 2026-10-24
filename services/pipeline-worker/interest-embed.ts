// gte-small on CPU for the interest index (docs/architecture/INTEREST_INDEX.md §1): the fp32 ONNX export
// (Xenova/gte-small@5927d17, the same weights as thenlper/gte-small@17e1f347), baked into the image by the Dockerfile
// and checked against its SHA-256 before use; the dependency-free WordPiece tokenizer with padding off; mean pooling
// over the attention mask; L2 normalisation. One thread: Cloud Run gives the instance one vCPU.
import { createHash } from 'node:crypto';
import { createReadStream, readFileSync } from 'node:fs';
import { WordPiece } from '../../supabase/functions/_shared/interest/wordpiece.ts';
import { DIM } from '../../supabase/functions/_shared/interest/codec.ts';

export const MODEL_SHA256 = '398a29991324e0b383afa13375d681ced3079c83e097fb1ebd9290d7498523b3';
export const MODEL_PATH = new URL('./model/gte-small.onnx', import.meta.url);
export const VOCAB_PATH = new URL('./model/vocab.txt', import.meta.url);
/** Batches are length-sorted; a batch holds at most this many tokens (padding included). */
const BATCH_TOKENS = 8192;
const BATCH_TEXTS = 64;

async function fileSha256(path: URL): Promise<string> {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk as Buffer);
  return hash.digest('hex');
}

export type Embedder = (texts: string[]) => Promise<Float32Array[]>;

export async function createEmbedder(options: { modelPath?: URL; vocabPath?: URL; threads?: number } = {}): Promise<Embedder> {
  const modelPath = options.modelPath ?? MODEL_PATH;
  if (await fileSha256(modelPath) !== MODEL_SHA256) throw new Error('interest_model_mismatch');
  const ort = await import('onnxruntime-node');
  const session = await ort.InferenceSession.create(modelPath.pathname, {
    intraOpNumThreads: options.threads ?? 1, interOpNumThreads: 1, graphOptimizationLevel: 'all', executionProviders: ['cpu'] });
  const wordpiece = new WordPiece(readFileSync(options.vocabPath ?? VOCAB_PATH, 'utf8'));
  const output = session.outputNames.includes('last_hidden_state') ? 'last_hidden_state' : session.outputNames[0];
  const typeIDs = session.inputNames.includes('token_type_ids');

  return async texts => {
    const encoded = texts.map(t => wordpiece.encode(t));
    const order = encoded.map((_, i) => i).sort((a, b) => encoded[a].length - encoded[b].length);
    const out = new Array<Float32Array>(texts.length);
    for (let start = 0; start < order.length;) {
      let end = start + 1;
      while (end < order.length && end - start < BATCH_TEXTS && (end - start + 1) * encoded[order[end]].length <= BATCH_TOKENS) end++;
      const batch = order.slice(start, end), length = encoded[batch.at(-1)!].length, b = batch.length;
      const ids = new BigInt64Array(b * length), mask = new BigInt64Array(b * length);
      batch.forEach((index, row) => encoded[index].forEach((id, col) => { ids[row * length + col] = BigInt(id); mask[row * length + col] = 1n; }));
      const feeds: Record<string, InstanceType<typeof ort.Tensor>> = {
        input_ids: new ort.Tensor('int64', ids, [b, length]), attention_mask: new ort.Tensor('int64', mask, [b, length]) };
      if (typeIDs) feeds.token_type_ids = new ort.Tensor('int64', new BigInt64Array(b * length), [b, length]);
      const result = await session.run(feeds);
      const hidden = result[output].data as Float32Array;
      batch.forEach((index, row) => {
        // Mean over the real tokens only: padded positions in a batch never enter the fingerprint.
        const v = new Float32Array(DIM), n = encoded[index].length;
        for (let t = 0; t < n; t++) { const o = (row * length + t) * DIM; for (let i = 0; i < DIM; i++) v[i] += hidden[o + i]; }
        let norm = 0;
        for (let i = 0; i < DIM; i++) { v[i] /= n; norm += v[i] * v[i]; }
        norm = Math.sqrt(norm) || 1;
        for (let i = 0; i < DIM; i++) v[i] /= norm;
        out[index] = v;
      });
      start = end;
    }
    return out;
  };
}

// Gradstep interest index worker entry (docs/architecture/INTEREST_INDEX.md). The HTTP parent (server.ts, POST /interest)
// runs this in a worker thread with the pipeline's hard deadline and awaits it before replying: no detached work under
// request-based billing. One bounded run: sync, embed, publish a shard, and build the map when due.
import { installEgressGuard } from '../../supabase/functions/_shared/egress.ts';
import { parentPort, workerData } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
import { pipelineService, rpcAdapter } from '../../supabase/functions/_shared/pipeline-runtime.ts';
import { MODEL_VERSION, runInterest } from '../../supabase/functions/_shared/interest/job.ts';
import { createEmbedder, type Embedder } from './interest-embed.ts';
// No request from this thread may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
// The job itself makes no request other than to the database: the model is baked into the image.
installEgressGuard('pipeline-worker/interest');

/** Leaves time to release the claim before the parent's 840 s hard limit. */
export const INTEREST_BUDGET_MS = 780_000;
const log = (event: string, fields: Record<string, unknown> = {}) => console.log(JSON.stringify({ event, ...fields }));

export async function runInterestOnce(now: () => number = Date.now): Promise<{ processed: number; ms: number }> {
  const started = now();
  let embedder: Embedder | null = null;
  const result = await runInterest({
    rpc: rpcAdapter(pipelineService()),
    // The model loads only when there is something to embed.
    embed: async texts => (embedder ??= await createEmbedder())(texts),
    modelVersion: MODEL_VERSION, now, uuid: () => randomUUID(), log,
  }, started + INTEREST_BUDGET_MS);
  log('interest_run', { ms: now() - started, ...result.counts });
  return { processed: result.processed, ms: now() - started };
}

// Only the HTTP parent's explicitly created worker runs this entry point.
if (parentPort && workerData?.pipelineRun === 1 && workerData.entryPoint === import.meta.url) {
  try { parentPort.postMessage({ ok: true, result: await runInterestOnce() }); }
  catch (error) {
    const code = error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected';
    parentPort.postMessage({ ok: false, code });
  }
}

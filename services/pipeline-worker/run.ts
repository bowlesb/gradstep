// Gradstep paper pipeline worker for Google Cloud Run (docs/architecture/PIPELINE_RELIABILITY.md).
// Runs the same pipeline code as the Edge `paper-worker` under Node 24, with the memory
// and time large papers need. pg_cron and the import trigger call it through pg_net with
// the pipeline secret (never a customer token). Each call works through due papers, one
// at a time, until none is due or the run budget is spent, and answers when it is done.
import { parentPort, workerData } from 'node:worker_threads';
import { resolve4, resolve6 } from 'node:dns/promises';
import { randomUUID } from 'node:crypto';
import { MathpixClient } from '../../supabase/functions/_shared/mathpix.ts';
import { runPipeline, type PipelineDeps } from '../../supabase/functions/_shared/pipeline.ts';
import { pipelineService, rpcAdapter, runtimeEnv, storageAdapter, uploadStorageAdapter } from '../../supabase/functions/_shared/pipeline-runtime.ts';
import { renderReader } from '../../supabase/functions/_shared/reader-adapter.ts';
import { sweepPdfUploads } from '../../supabase/functions/_shared/pdf-uploads.ts';
import { sweepAccountDeletions } from '../../supabase/functions/_shared/account-deletion.ts';
import { classifyPaper, createTagClient, tagCatalog, type TaggingDeps } from '../../supabase/functions/_shared/tags.ts';

/** Stop claiming new papers after this soft budget; the parent enforces a hard whole-run deadline. */
export const RUN_BUDGET_MS = 480_000;
/** Each paper's own deadline (the pipeline stops starting stages 30 s before it). */
export const PAPER_DEADLINE_MS = 360_000;
/** Topic tagging after each paper and at the end of a run (docs/architecture/TAGS.md). */
export const TAG_DEADLINE_MS = 90_000;

const log = (event: string, fields: Record<string, unknown> = {}) => console.log(JSON.stringify({ event, ...fields }));

/** A web PDF host's addresses (every one must be public; checked per redirect hop by the pipeline). */
async function resolveHost(host: string): Promise<string[]> {
  const answers = await Promise.allSettled([resolve4(host), resolve6(host)]);
  const addresses = answers.flatMap(answer => answer.status === 'fulfilled' ? answer.value : []);
  if (!addresses.length) throw new Error('dns_unresolved');
  return addresses;
}

function deps(): PipelineDeps {
  const service = pipelineService();
  const appID = runtimeEnv('MATHPIX_APP_ID'), appKey = runtimeEnv('MATHPIX_APP_KEY');
  if (!appID || !appKey) throw new Error('provider_credentials_unavailable');
  return {
    rpc: rpcAdapter(service), storage: storageAdapter(service), uploads: uploadStorageAdapter(service), fetch,
    mathpix: new MathpixClient({ appID, appKey }), render: renderReader,
    sleep: ms => new Promise(resolve => setTimeout(resolve, ms)), now: () => Date.now(), uuid: () => randomUUID(),
    log: (event, fields = {}) => log(event, fields),
    resolveHost,
    // No self-kick: this run keeps claiming due papers itself.
  };
}

/** Claude Haiku chooses catalog tags when the Anthropic key is configured; otherwise only the arXiv-category fallback runs. */
function taggingDeps(): TaggingDeps {
  const key = runtimeEnv('ANTHROPIC_API_KEY');
  const client = key ? createTagClient(key) : null;
  return {
    rpc: rpcAdapter(pipelineService()), classify: client ? input => classifyPaper(client, input) : null,
    uuid: () => randomUUID(), now: () => Date.now(), log: (event, fields = {}) => log(event, fields),
  };
}

export interface RunResult { processed: number; ms: number }
/** Works through due papers until none is due or the budget is spent. Tags papers whose metadata
 * has arrived after each one (a paper's tags are ready while it converts), and once more at the end. */
export async function runOnce(make: () => PipelineDeps = deps, now: () => number = Date.now,
  tagging: (() => TaggingDeps) | null = taggingDeps, sweepUploads = true): Promise<RunResult> {
  const started = now();
  let processed = 0;
  // Finish any account deletion left incomplete (cheap when none is).
  await sweepAccountDeletions(pipelineService(), fields => log('account_deletion', fields)).catch(() => {});
  if (sweepUploads) {
    try {
      const service = pipelineService();
      await sweepPdfUploads(rpcAdapter(service), paths => uploadStorageAdapter(service).remove(paths), fields => log('pdf_uploads', fields));
    } catch { log('pdf_uploads', { event: 'pdf_upload_sweep_failed' }); }
  }
  const pipeline = make();
  let tagger: TaggingDeps | null = null;
  const tag = async (maxPapers: number) => {
    if (!tagging) return;
    try {
      tagger ??= tagging();
      const result = await tagCatalog(tagger, { deadline: now() + TAG_DEADLINE_MS, maxPapers });
      if (result.model || result.fallback || result.failed || result.projected) log('tags_run', { ...result });
    } catch (error) { log('tags_failed', { code: error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected' }); }
  };
  while (now() - started < RUN_BUDGET_MS) {
    const result = await runPipeline(pipeline, now() + PAPER_DEADLINE_MS);
    if (!result.processed) break;
    processed += result.processed;
    await tag(3);
  }
  await tag(30);
  return { processed, ms: now() - started };
}

// Only the HTTP parent's explicitly created worker runs this entry point. Importing
// runOnce in a test does not create work, read credentials or call a provider.
if (parentPort && workerData?.pipelineRun === 1 && workerData.entryPoint === import.meta.url) {
  try { parentPort.postMessage({ ok: true, result: await runOnce() }); }
  catch (error) {
    const code = error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected';
    parentPort.postMessage({ ok: false, code });
  }
}

// Gradstep paper pipeline worker for Google Cloud Run (docs/architecture/PIPELINE_RELIABILITY.md).
// Runs the same pipeline code as the Edge `paper-worker` under Node 24, with the memory
// and time large papers need. pg_cron and the import trigger call it through pg_net with
// the pipeline secret (never a customer token). Each call works through due papers, one
// at a time, until none is due or the run budget is spent, and answers when it is done.
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { resolve4, resolve6 } from 'node:dns/promises';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { MathpixClient } from '../../supabase/functions/_shared/mathpix.ts';
import { runPipeline, type PipelineDeps } from '../../supabase/functions/_shared/pipeline.ts';
import { pipelineService, rpcAdapter, runtimeEnv, storageAdapter, uploadStorageAdapter } from '../../supabase/functions/_shared/pipeline-runtime.ts';
import { renderReader } from '../../supabase/functions/_shared/reader-adapter.ts';
import { sweepAccountDeletions } from '../../supabase/functions/_shared/account-deletion.ts';
import { sweepPdfUploads } from '../../supabase/functions/_shared/pdf-uploads.ts';
import { classifyPaper, createTagClient, tagCatalog, type TaggingDeps } from '../../supabase/functions/_shared/tags.ts';

/** No new paper is claimed after this; Cloud Run's request timeout (900 s) leaves room to finish one. */
export const RUN_BUDGET_MS = 480_000;
/** Each paper's own deadline (the pipeline stops starting stages 30 s before it). */
export const PAPER_DEADLINE_MS = 360_000;
/** Topic tagging after each paper and at the end of a run (docs/architecture/TAGS.md). */
export const TAG_DEADLINE_MS = 90_000;

const log = (event: string, fields: Record<string, unknown> = {}) => console.log(JSON.stringify({ event, ...fields }));

export function sameSecret(given: string, expected: string): boolean {
  const a = Buffer.from(given), b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

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
  // Delete readers' uploads that were used, abandoned or never finished (migration 033).
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

let running: Promise<RunResult> | null = null;

export async function handle(request: IncomingMessage, response: ServerResponse, secret = runtimeEnv('PIPELINE_SECRET')): Promise<void> {
  const send = (status: number, body: unknown) => {
    response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
    response.end(JSON.stringify(body));
  };
  request.resume();
  if (request.method === 'GET' && request.url === '/health') return send(200, { ok: true });
  if (request.method !== 'POST') return send(405, { code: 'method_unavailable' });
  const given = request.headers['x-pipeline-secret'];
  if (!secret || secret.length < 32 || typeof given !== 'string' || !sameSecret(given, secret)) return send(401, { code: 'unauthorized' });
  // One run per instance (Cloud Run concurrency is 1; this also covers local use).
  if (running) return send(202, { accepted: true, busy: true });
  running = runOnce();
  try {
    const result = await running;
    log('run_finished', { processed: result.processed, ms: result.ms });
    send(200, { accepted: true, processed: result.processed });
  } catch (error) {
    const code = error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected';
    log('run_failed', { code });
    send(500, { code: 'run_failed' });
  } finally { running = null; }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 8080);
  createServer((request, response) => { void handle(request, response); }).listen(port, () => log('listening', { port }));
}

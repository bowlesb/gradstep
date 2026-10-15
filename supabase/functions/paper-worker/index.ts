// Advances queued papers. Invoked by pg_cron (every minute) and by the import
// trigger via pg_net; authenticated with a dedicated shared secret, never a
// customer token. Returns immediately and works in the background.
import { installEgressGuard } from '../_shared/egress.ts';
import { runMetadataPipeline, type MetadataDeps } from '../_shared/metadata-pipeline.ts';
import { pipelineService, rpcAdapter } from '../_shared/pipeline-runtime.ts';
import { sweepAccountDeletions } from '../_shared/account-deletion.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); EGRESS_ARXIV sets report or block.
installEgressGuard('paper-worker');

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0; for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function deps(): MetadataDeps {
  return { rpc: rpcAdapter(pipelineService()), fetch,
    sleep: ms => new Promise(resolve => setTimeout(resolve, ms)), now: () => Date.now(), uuid: () => crypto.randomUUID(),
    log: (event, fields = {}) => console.log(JSON.stringify({ event, ...fields })) };
}

Deno.serve(async request => {
  const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  const secret = Deno.env.get('PIPELINE_SECRET');
  if (request.method !== 'POST') return Response.json({ code: 'method_unavailable' }, { status: 405, headers });
  if (!secret || secret.length < 32 || !sameSecret(request.headers.get('x-pipeline-secret') ?? '', secret)) {
    return Response.json({ code: 'unauthorized' }, { status: 401, headers });
  }
  void request.body?.cancel().catch(() => {});
  const started = Date.now();
  const work = (async () => {
    try {
      // Finish any account deletion left incomplete (cheap when none is).
      await sweepAccountDeletions(pipelineService(), fields => console.log(JSON.stringify(fields))).catch(() => {});
      const result = await runMetadataPipeline(deps(), started + 300_000);
      console.log(JSON.stringify({ event: 'run_finished', processed: result.processed, ms: Date.now() - started }));
    } catch (error) {
      console.log(JSON.stringify({ event: 'run_failed', code: error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected' }));
    }
  })();
  if (typeof EdgeRuntime !== 'undefined') { EdgeRuntime.waitUntil(work); return Response.json({ accepted: true }, { status: 202, headers }); }
  await work;
  return Response.json({ accepted: true }, { headers });
});

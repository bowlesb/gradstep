// Advances queued papers. Invoked by pg_cron (every minute) and by the import
// trigger via pg_net; authenticated with a dedicated shared secret, never a
// customer token. Returns immediately and works in the background.
import { MathpixClient } from '../_shared/mathpix.ts';
import { runPipeline, type PipelineDeps } from '../_shared/pipeline.ts';
import { pipelineService, rpcAdapter, storageAdapter } from '../_shared/pipeline-runtime.ts';
import { renderReader } from '../_shared/reader-adapter.ts';
import { sweepAccountDeletions } from '../_shared/account-deletion.ts';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0; for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function deps(): PipelineDeps {
  const service = pipelineService();
  const appID = Deno.env.get('MATHPIX_APP_ID'), appKey = Deno.env.get('MATHPIX_APP_KEY');
  if (!appID || !appKey) throw new Error('provider_credentials_unavailable');
  return {
    rpc: rpcAdapter(service), storage: storageAdapter(service), fetch,
    mathpix: new MathpixClient({ appID, appKey }), render: renderReader,
    sleep: ms => new Promise(resolve => setTimeout(resolve, ms)), now: () => Date.now(), uuid: () => crypto.randomUUID(),
    log: (event, fields = {}) => console.log(JSON.stringify({ event, ...fields })),
    kick: async () => {
      const url = Deno.env.get('SUPABASE_URL'), secret = Deno.env.get('PIPELINE_SECRET');
      if (!url || !secret) return;
      const response = await fetch(`${url}/functions/v1/paper-worker`, { method: 'POST', body: '{"reason":"continue"}',
        headers: { 'content-type': 'application/json', 'x-pipeline-secret': secret }, signal: AbortSignal.timeout(10_000) });
      void response.body?.cancel().catch(() => {});
    },
  };
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
      const result = await runPipeline(deps(), started + 300_000);
      console.log(JSON.stringify({ event: 'run_finished', processed: result.processed, ms: Date.now() - started }));
    } catch (error) {
      console.log(JSON.stringify({ event: 'run_failed', code: error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected' }));
    }
  })();
  if (typeof EdgeRuntime !== 'undefined') { EdgeRuntime.waitUntil(work); return Response.json({ accepted: true }, { status: 202, headers }); }
  await work;
  return Response.json({ accepted: true }, { headers });
});

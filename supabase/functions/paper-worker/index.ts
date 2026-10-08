// Advances queued papers. Invoked by pg_cron (every minute) and by the import
// trigger via pg_net; authenticated with a dedicated shared secret, never a
// customer token. Returns immediately and works in the background.
import { MathpixClient } from '../_shared/mathpix.ts';
import { runPipeline, type PipelineDeps } from '../_shared/pipeline.ts';
import { pipelineService, rpcAdapter, storageAdapter, uploadStorageAdapter } from '../_shared/pipeline-runtime.ts';
import { renderReader } from '../_shared/reader-adapter.ts';
import { sweepAccountDeletions } from '../_shared/account-deletion.ts';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0; for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

/** A web PDF host's addresses: the runtime resolver, else DNS over HTTPS. Throws
 * (the download is refused) when neither answers; the cause is logged. */
async function resolveHost(host: string): Promise<string[]> {
  const resolveDns = (Deno as { resolveDns?: typeof Deno.resolveDns }).resolveDns;
  let runtime = 'unavailable';
  if (typeof resolveDns === 'function') {
    const answers = await Promise.allSettled([(async () => resolveDns(host, 'A'))(), (async () => resolveDns(host, 'AAAA'))()]);
    const addresses = answers.flatMap(answer => answer.status === 'fulfilled' ? answer.value : []);
    if (addresses.length) return addresses;
    const reason = (answers.find(answer => answer.status === 'rejected') as PromiseRejectedResult | undefined)?.reason;
    runtime = reason instanceof Error ? reason.name : 'empty';
    // The name does not exist: no need to ask again.
    if (runtime === 'NotFound') { console.log(JSON.stringify({ event: 'dns_unresolved', resolver: 'runtime', error: runtime })); throw new Error('dns_unresolved'); }
  }
  const addresses: string[] = [];
  for (const type of ['A', 'AAAA']) {
    try {
      const response = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=${type}`,
        { headers: { accept: 'application/dns-json' }, redirect: 'error', signal: AbortSignal.timeout(5_000) });
      const body = await response.json() as { Answer?: { type?: number; data?: unknown }[] };
      for (const answer of body.Answer ?? []) if ((answer.type === 1 || answer.type === 28) && typeof answer.data === 'string') addresses.push(answer.data);
    } catch { /* tried below */ }
  }
  console.log(JSON.stringify({ event: 'dns_fallback', runtime, answered: addresses.length > 0 }));
  if (!addresses.length) throw new Error('dns_unresolved');
  return addresses;
}

function deps(): PipelineDeps {
  const service = pipelineService();
  const appID = Deno.env.get('MATHPIX_APP_ID'), appKey = Deno.env.get('MATHPIX_APP_KEY');
  if (!appID || !appKey) throw new Error('provider_credentials_unavailable');
  return {
    rpc: rpcAdapter(service), storage: storageAdapter(service), uploads: uploadStorageAdapter(service), fetch,
    mathpix: new MathpixClient({ appID, appKey }), render: renderReader,
    sleep: ms => new Promise(resolve => setTimeout(resolve, ms)), now: () => Date.now(), uuid: () => crypto.randomUUID(),
    log: (event, fields = {}) => console.log(JSON.stringify({ event, ...fields })),
    // Web PDF hosts: every address must be public (checked per redirect hop).
    resolveHost,
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

// Refreshes the Feed's shared pool (docs/architecture/PERSONALIZED_FEED.md). Woken by pg_cron
// (app_private.feed_refresh_kick, migration 044) only when refreshing is on and the source is due;
// authenticated by the dedicated FEED_REFRESH_SECRET header, never a user token. Claims the source,
// answers 202, and finishes the fetch in the background under the claim's lease.
import { rpc, serviceClient } from '../_shared/backend.ts';
import { runRefresh, sameSecret, type PoolItem, type RefreshClaim, type RefreshStatus } from '../_shared/feed-pool.ts';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

Deno.serve(async request => {
  const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  if (request.method !== 'POST') return Response.json({ code: 'method_unavailable' }, { status: 405, headers });
  const secret = Deno.env.get('FEED_REFRESH_SECRET');
  if (!secret || secret.length < 32 || !sameSecret(request.headers.get('x-feed-secret') ?? '', secret)) {
    return Response.json({ code: 'authentication_required' }, { status: 401, headers });
  }
  void request.body?.cancel().catch(() => {});
  try {
    const service = serviceClient();
    const claim = await rpc<RefreshClaim | null>(service, 'worker_feed_refresh_claim');
    if (!claim) return Response.json({ claimed: false }, { headers });
    const started = Date.now();
    const work = runRefresh({
      slot: () => rpc(service, 'worker_pipeline_arxiv_slot', { p_slots: 1, p_max_wait_ms: 20_000 }),
      fetch,
      upsert: (claimID: string, items: PoolItem[], topicsVersion: string) =>
        rpc(service, 'worker_feed_upsert', { p_claim_id: claimID, p_items: items, p_topics_version: topicsVersion }),
      finish: (claimID: string, status: RefreshStatus, etag: string | null, lastModified: string | null, items: number | null) =>
        rpc(service, 'worker_feed_refresh_finish', { p_claim_id: claimID, p_status: status, p_etag: etag, p_last_modified: lastModified, p_items: items }),
      sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
      today: () => new Date().toISOString().slice(0, 10),
      log: fields => console.log(JSON.stringify({ function: 'feed-refresh', ...fields })),
    }, claim).then(outcome => console.log(JSON.stringify({ function: 'feed-refresh', event: 'refreshed', status: outcome.status,
      items: outcome.items, inserted: outcome.inserted, updated: outcome.updated, pool: outcome.pool ?? null, code: outcome.code ?? null,
      ms: Date.now() - started })));
    if (typeof EdgeRuntime !== 'undefined') { EdgeRuntime.waitUntil(work); return Response.json({ claimed: true }, { status: 202, headers }); }
    await work;
    return Response.json({ claimed: true }, { headers });
  } catch {
    return Response.json({ code: 'service_unavailable' }, { status: 503, headers });
  }
});

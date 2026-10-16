// Refreshes the Feed's shared pool (docs/architecture/PERSONALIZED_FEED.md). Woken by pg_cron
// (app_private.feed_refresh_kick, migration 043) only when refreshing is on and the source is due;
// the claim names the source (migration 074): DataCite's arXiv records (feed-datacite.ts). Our
// servers never contact arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md): a claim for any other
// source (arXiv's RSS, retired by migration 076) is recorded as failed, never fetched. Authenticated by the dedicated FEED_REFRESH_SECRET header, never a user token. Claims the source,
// answers 202, and finishes the fetch in the background under the claim's lease. The same run reads
// Hugging Face Papers upvotes for the pool (feed-signals.ts, migration 046) before releasing the claim.
import { installEgressGuard } from '../_shared/egress.ts';
import { installProviderHealth } from '../_shared/provider-health.ts';
import { rpc, serviceClient } from '../_shared/backend.ts';
import { dataCitePoolSource } from '../_shared/feed-datacite.ts';
import { runRefresh, sameSecret, type PoolItem, type PoolSource, type RefreshClaim, type RefreshStatus } from '../_shared/feed-pool.ts';
import { runSignals, type SignalDayStatus, type SignalPlan, type Upvote } from '../_shared/feed-signals.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('feed-refresh');
// Provider calls are counted per hour and fail fast while a provider's breaker is open (docs/architecture/RESILIENCE.md).
installProviderHealth('feed-refresh', serviceClient);

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

/** Any source but DataCite fails closed: nothing is requested. */
const retired: PoolSource = async () => ({ status: 'failed', code: 'arxiv_egress_disabled' });

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
    const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
    const work = runRefresh({
      fetch,
      upsert: (claimID: string, items: PoolItem[], topicsVersion: string) =>
        rpc(service, 'worker_feed_upsert', { p_claim_id: claimID, p_items: items, p_topics_version: topicsVersion }),
      finish: (claimID: string, status: RefreshStatus, etag: string | null, lastModified: string | null, items: number | null) =>
        rpc(service, 'worker_feed_refresh_finish', { p_claim_id: claimID, p_status: status, p_etag: etag, p_last_modified: lastModified, p_items: items }),
      sleep,
      today: () => new Date().toISOString().slice(0, 10),
      log: fields => console.log(JSON.stringify({ function: 'feed-refresh', ...fields })),
      signals: (claimID: string) => runSignals({
        plan: (id: string) => rpc<SignalPlan>(service, 'worker_feed_signal_plan', { p_claim_id: id }),
        record: (id: string, day: string, status: SignalDayStatus, items: Upvote[]) =>
          rpc<{ matched: number }>(service, 'worker_feed_signals_record', { p_claim_id: id, p_day: day, p_status: status, p_items: items }),
        fetch,
        sleep,
      }, claimID),
    }, claim, claim.kind === 'datacite' ? dataCitePoolSource() : retired).then(outcome => console.log(JSON.stringify({ function: 'feed-refresh', event: 'refreshed', source: claim.kind ?? 'unknown', status: outcome.status,
      items: outcome.items, inserted: outcome.inserted, updated: outcome.updated, pool: outcome.pool ?? null, code: outcome.code ?? null,
      ms: Date.now() - started })));
    if (typeof EdgeRuntime !== 'undefined') { EdgeRuntime.waitUntil(work); return Response.json({ claimed: true }, { status: 202, headers }); }
    await work;
    return Response.json({ claimed: true }, { headers });
  } catch {
    return Response.json({ code: 'service_unavailable' }, { status: 503, headers });
  }
});

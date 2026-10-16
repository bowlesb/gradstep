// The Feed's shared pool (docs/architecture/PERSONALIZED_FEED.md): the pool's source (DataCite's arXiv records,
// feed-datacite.ts; our servers never contact arXiv, docs/architecture/ARXIV_DEVICE_ONLY.md) brings strict items, which
// are tagged with the keyword topic rules and written through fenced service RPCs (migration 043). Pure helpers (Deno +
// Node); the `feed-refresh` function supplies the transport and database.
import { FEED_TOPICS_VERSION, feedTopics } from './feed-topics.ts';
import type { SignalOutcome } from './feed-signals.ts';

export interface PoolItem {
  source_id: string; revision: number; title: string; authors: string[]; abstract: string | null;
  categories: string[]; topics: string[]; announced_on: string; announce_type: 'new' | 'cross';
}

/** What `worker_feed_refresh_claim` returns; `kind` is the source (migration 074; DataCite only since 077). */
export interface RefreshClaim {
  claim_id: string; source: string; kind?: 'arxiv_rss' | 'datacite'; categories: string[]; etag: string | null; last_modified: string | null; max_items: number;
}

export type RefreshStatus = 'updated' | 'not_modified' | 'failed' | 'busy';
export interface RefreshOutcome { status: RefreshStatus; items: number; inserted: number; updated: number; code?: string; pool?: number }

// An arXiv category: an archive (`cs`, `q-bio`, `astro-ph`) and an optional subject class (`.LG`, `.NC`, or
// physics' lower-case `.comp-ph`). `q-bio`/`q-fin` start with one letter (egress.no-arxiv, 2026-10-16: q-bio.NC was 400).
export const POOL_CATEGORY = /^(q-[a-z]{3,4}|[a-z]{2,8}(-[a-z]{2,6})?)(\.([A-Z]{2}|[a-z]{2,8}(-[a-z]{2,4})?))?$/;
export const POOL_BATCH = 400;

/** Authors as the pool keeps them: at most 12, the last author kept for long lists (first 11 + last). */
export function poolAuthors(names: readonly string[]): string[] {
  const clean = names.map(name => name.replace(/\s+/g, ' ').trim()).filter(name => name.length >= 1 && name.length <= 256);
  return clean.length > 12 ? [...clean.slice(0, 11), clean[clean.length - 1]] : clean;
}

/** Adds the keyword topic tags (feed-topics.ts) to each item. */
export function withTopics(items: readonly PoolItem[]): PoolItem[] {
  return items.map(item => ({ ...item, topics: feedTopics(item.title, item.abstract, item.categories) }));
}

/** Reads at most `maximum` bytes of a response body, or throws. */
export async function readBounded(response: Response, maximum: number): Promise<Uint8Array> {
  const declared = response.headers.get('content-length');
  if (declared && Number(declared) > maximum) { void response.body?.cancel().catch(() => {}); throw new Error('feed_too_large'); }
  if (!response.body) return new Uint8Array();
  const reader = response.body.getReader();
  const parts: Uint8Array[] = []; let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximum) { void reader.cancel().catch(() => {}); throw new Error('feed_too_large'); }
    parts.push(value);
  }
  const joined = new Uint8Array(length); let offset = 0;
  for (const part of parts) { joined.set(part, offset); offset += part.byteLength; }
  return joined;
}

/** Constant-time comparison of the cron's secret header. */
export function sameSecret(given: string, expected: string): boolean {
  const x = new TextEncoder().encode(given), y = new TextEncoder().encode(expected);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

export interface RefreshDeps {
  fetch: typeof fetch;
  upsert(claimID: string, items: PoolItem[], topicsVersion: string): Promise<{ inserted: number; updated: number }>;
  finish(claimID: string, status: RefreshStatus, etag: string | null, lastModified: string | null, items: number | null): Promise<{ pruned: number; pool: number }>;
  sleep(ms: number): Promise<void>;
  today(): string;
  log?(fields: Record<string, unknown>): void;
  /** Popularity (feed-signals.ts, migration 046), run under the same claim before it is released. */
  signals?(claimID: string): Promise<SignalOutcome>;
}

/** What a source brings back for one refresh: new items, "nothing new", "busy", or a failure with its code. */
export interface PoolFetch {
  status: 'updated' | 'not_modified' | 'busy' | 'failed'; items?: PoolItem[]; skipped?: number;
  etag?: string | null; lastModified?: string | null; code?: string;
}
/** Where the pool's items come from: DataCite (feed-datacite.ts, migrations 074 and 077). */
export type PoolSource = (deps: RefreshDeps, claim: RefreshClaim) => Promise<PoolFetch>;

/** One refresh under a claim: the source's items, tagged, upserted in batches, then the popularity pass (if any),
 * then the outcome recorded. Never throws: any failure is recorded as `failed` (the claim's lease covers a crash). */
export async function runRefresh(deps: RefreshDeps, claim: RefreshClaim, source: PoolSource): Promise<RefreshOutcome> {
  const finish = async (outcome: RefreshOutcome, etag: string | null = null, lastModified: string | null = null): Promise<RefreshOutcome> => {
    if (deps.signals && outcome.code !== 'invalid_categories') {
      // Independent of the source's answer (a 304, a busy slot or a failure still refreshes upvotes).
      try {
        const signals = await deps.signals(claim.claim_id);
        deps.log?.({ event: 'popularity', status: signals.status, days: signals.days, requests: signals.requests,
          matched: signals.matched, code: signals.code ?? null });
      } catch { deps.log?.({ event: 'popularity', status: 'failed', code: 'unexpected' }); }
    }
    try {
      const recorded = await deps.finish(claim.claim_id, outcome.status, etag, lastModified, outcome.status === 'updated' ? outcome.items : null);
      return { ...outcome, pool: recorded.pool };
    } catch {
      return { ...outcome, code: outcome.code ?? 'finish_failed' };
    }
  };
  try {
    const fetched = await source(deps, claim);
    if (fetched.status !== 'updated') return finish({ status: fetched.status, items: 0, inserted: 0, updated: 0, ...(fetched.code ? { code: fetched.code } : {}) });
    const items = withTopics(fetched.items ?? []);
    let inserted = 0, updated = 0;
    for (let start = 0; start < items.length; start += POOL_BATCH) {
      const written = await deps.upsert(claim.claim_id, items.slice(start, start + POOL_BATCH), FEED_TOPICS_VERSION);
      inserted += written.inserted; updated += written.updated;
    }
    deps.log?.({ event: 'pool_parsed', items: items.length, skipped: fetched.skipped ?? 0, source: claim.kind ?? 'unknown' });
    return finish({ status: 'updated', items: items.length, inserted, updated }, fetched.etag ?? null, fetched.lastModified ?? null);
  } catch (error) {
    const code = error instanceof Error && /^[a-z0-9_]{1,40}$/.test(error.message) ? error.message : 'unexpected';
    return finish({ status: 'failed', items: 0, inserted: 0, updated: 0, code });
  }
}

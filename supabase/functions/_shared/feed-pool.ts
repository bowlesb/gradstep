// The Feed's shared pool (docs/architecture/PERSONALIZED_FEED.md): one conditional request to
// arXiv's combined RSS for the pool's categories, parsed into strict items, tagged with the keyword
// topic rules, and written through fenced service RPCs (migration 043). Pure helpers (Deno + Node);
// the `feed-refresh` function supplies the transport and database.
import { arxivReference } from './arxiv.ts';
import { xmlText } from './discover.ts';
import { FEED_TOPICS_VERSION, feedTopics } from './feed-topics.ts';
import type { SignalOutcome } from './feed-signals.ts';

export interface PoolItem {
  source_id: string; revision: number; title: string; authors: string[]; abstract: string | null;
  categories: string[]; topics: string[]; announced_on: string; announce_type: 'new' | 'cross';
}

/** What `worker_feed_refresh_claim` returns. */
export interface RefreshClaim {
  claim_id: string; source: string; categories: string[]; etag: string | null; last_modified: string | null; max_items: number;
}

export type RefreshStatus = 'updated' | 'not_modified' | 'failed' | 'busy';
export interface RefreshOutcome { status: RefreshStatus; items: number; inserted: number; updated: number; code?: string; pool?: number }

const CATEGORY = /^[a-z]{2,8}(-[a-z]{2,6})?(\.[A-Z]{2})?$/;
export const POOL_MAX_BYTES = 16 * 1024 * 1024;
export const POOL_BATCH = 400;
const USER_AGENT = 'Gradstep/0.1 (research paper reader; +https://gradstep.ai; mailto:hello@gradstep.ai)';

/** One combined listing for all the pool's categories (arXiv joins categories with "+"). */
export function poolFeedURL(categories: readonly string[]): string {
  if (!categories.length || categories.length > 16 || categories.some(c => !CATEGORY.test(c))) throw new Error('invalid_categories');
  return `https://rss.arxiv.org/rss/${categories.join('+')}`;
}

const MONTHS: Record<string, string> = { Jan: '01', Feb: '02', Mar: '03', Apr: '04', May: '05', Jun: '06', Jul: '07', Aug: '08', Sep: '09', Oct: '10', Nov: '11', Dec: '12' };

/** The announcement day as arXiv dates it ("Thu, 08 Oct 2026 00:00:00 -0400" → 2026-10-08). */
export function announcementDay(pubDate: string | null): string | null {
  const match = pubDate ? /(\d{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4})/.exec(pubDate) : null;
  if (!match) return null;
  const day = `${match[3]}-${MONTHS[match[2]]}-${match[1].padStart(2, '0')}`;
  return Number.isNaN(Date.parse(`${day}T00:00:00Z`)) ? null : day;
}

function dayOffset(day: string, today: string): number {
  return Math.round((Date.parse(`${day}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86_400_000);
}

/** Authors as the pool keeps them: at most 12, the last author kept for long lists (first 11 + last). */
export function poolAuthors(names: readonly string[]): string[] {
  const clean = names.map(name => name.replace(/\s+/g, ' ').trim()).filter(name => name.length >= 1 && name.length <= 256);
  return clean.length > 12 ? [...clean.slice(0, 11), clean[clean.length - 1]] : clean;
}

/** Parses arXiv's RSS into pool items: only `new` and `cross` announcements (replacements are old
 * papers), every field bounded and validated as migration 043 requires; anything else is skipped.
 * Bounded text extraction (no DTD, no entity expansion). Topics are added by `withTopics`. */
export function parsePoolRSS(bytes: Uint8Array, options: { limit: number; today: string }): { items: PoolItem[]; skipped: number } {
  if (bytes.length > POOL_MAX_BYTES) throw new Error('feed_too_large');
  const text = new TextDecoder().decode(bytes);
  if (!/^\s*(<\?xml[^>]*>\s*)?<rss[\s>]/.test(text) || /<!DOCTYPE/i.test(text)) throw new Error('invalid_feed');
  const items = new Map<string, PoolItem>();
  let skipped = 0;
  const itemPattern = /<item>([\s\S]*?)<\/item>/g;
  let match: RegExpExecArray | null;
  while ((match = itemPattern.exec(text))) {
    const item = match[1];
    const field = (name: string) => { const m = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(item); return m ? xmlText(m[1]) : null; };
    try {
      const description = field('description') ?? '';
      const header = /^arXiv:(\S+?)v(\d+) Announce Type: (\S+)/.exec(description);
      if (!header) { skipped++; continue; }
      const type = header[3];
      if (type !== 'new' && type !== 'cross') continue;          // replacements are not new papers
      const ref = arxivReference(header[1]);
      const revision = Number(header[2]);
      const title = (field('title') ?? '').trim();
      const categories = [...new Set([...item.matchAll(/<category>([^<]{1,64})<\/category>/g)].map(c => xmlText(c[1]))
        .filter(c => /^[A-Za-z][A-Za-z0-9.-]{0,63}$/.test(c)))].slice(0, 12);
      const day = announcementDay(field('pubDate')) ?? options.today;
      const offset = dayOffset(day, options.today);
      if (!title || title.length > 2000 || !categories.length || !Number.isInteger(revision) || revision < 1 || revision > 10_000
        || offset < -60 || offset > 2) { skipped++; continue; }
      const abstract = description.replace(/^arXiv:\S+ Announce Type: \S+\s*Abstract:\s*/, '').trim().slice(0, 2000) || null;
      const authors = poolAuthors((field('dc:creator') ?? '').split(/,\s*|\s+and\s+/));
      const known = items.get(ref.sourceID);
      if (known) {
        // A paper listed twice: keep its categories together and prefer "new".
        known.categories = [...new Set([...known.categories, ...categories])].slice(0, 12);
        if (type === 'new') known.announce_type = 'new';
        continue;
      }
      if (items.size >= options.limit) { skipped++; continue; }
      items.set(ref.sourceID, { source_id: ref.sourceID, revision, title, authors, abstract, categories, topics: [], announced_on: day, announce_type: type });
    } catch { skipped++; }
  }
  return { items: [...items.values()], skipped };
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
  /** The shared arXiv pacing slot (`worker_pipeline_arxiv_slot`). */
  slot(): Promise<{ reserved: boolean; wait_ms: number }>;
  fetch: typeof fetch;
  upsert(claimID: string, items: PoolItem[], topicsVersion: string): Promise<{ inserted: number; updated: number }>;
  finish(claimID: string, status: RefreshStatus, etag: string | null, lastModified: string | null, items: number | null): Promise<{ pruned: number; pool: number }>;
  sleep(ms: number): Promise<void>;
  today(): string;
  log?(fields: Record<string, unknown>): void;
  /** Popularity (feed-signals.ts, migration 046), run under the same claim before it is released. */
  signals?(claimID: string): Promise<SignalOutcome>;
}

/** One refresh under a claim: pacing slot, conditional GET, parse, tag, upsert in batches, then the
 * popularity pass (if any), then record the outcome. Never throws: any failure is recorded as `failed`
 * (the claim's lease covers a crash). */
export async function runRefresh(deps: RefreshDeps, claim: RefreshClaim): Promise<RefreshOutcome> {
  const finish = async (outcome: RefreshOutcome, etag: string | null = null, lastModified: string | null = null): Promise<RefreshOutcome> => {
    if (deps.signals && outcome.code !== 'invalid_categories') {
      // Independent of arXiv's answer (a 304, a busy slot or a failure still refreshes upvotes).
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
  let url: string;
  try { url = poolFeedURL(claim.categories); } catch { return finish({ status: 'failed', items: 0, inserted: 0, updated: 0, code: 'invalid_categories' }); }
  try {
    const slot = await deps.slot();
    if (!slot.reserved) return finish({ status: 'busy', items: 0, inserted: 0, updated: 0 });
    if (slot.wait_ms > 0) await deps.sleep(slot.wait_ms);
    const headers: Record<string, string> = { accept: 'application/rss+xml', 'user-agent': USER_AGENT };
    if (claim.etag) headers['if-none-match'] = claim.etag;
    if (claim.last_modified) headers['if-modified-since'] = claim.last_modified;
    const response = await deps.fetch(url, { redirect: 'error', signal: AbortSignal.timeout(30_000), headers });
    if (response.status === 304) { void response.body?.cancel().catch(() => {}); return finish({ status: 'not_modified', items: 0, inserted: 0, updated: 0 }); }
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      return finish({ status: 'failed', items: 0, inserted: 0, updated: 0, code: `arxiv_${response.status}` });
    }
    const bytes = await readBounded(response, POOL_MAX_BYTES);
    const parsed = parsePoolRSS(bytes, { limit: claim.max_items, today: deps.today() });
    const items = withTopics(parsed.items);
    let inserted = 0, updated = 0;
    for (let start = 0; start < items.length; start += POOL_BATCH) {
      const written = await deps.upsert(claim.claim_id, items.slice(start, start + POOL_BATCH), FEED_TOPICS_VERSION);
      inserted += written.inserted; updated += written.updated;
    }
    deps.log?.({ event: 'pool_parsed', items: items.length, skipped: parsed.skipped });
    const etag = response.headers.get('etag'), lastModified = response.headers.get('last-modified');
    return finish({ status: 'updated', items: items.length, inserted, updated },
      etag && etag.length <= 256 ? etag : null, lastModified && lastModified.length <= 64 ? lastModified : null);
  } catch (error) {
    const code = error instanceof Error && /^[a-z0-9_]{1,40}$/.test(error.message) ? error.message : 'unexpected';
    return finish({ status: 'failed', items: 0, inserted: 0, updated: 0, code });
  }
}

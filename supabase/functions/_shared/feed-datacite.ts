// The Feed from DataCite (owner decision 2026-10-16; docs/architecture/ARXIV_DEVICE_ONLY.md §5.5): arXiv's records of
// the pool's categories as DataCite holds them, read once for everyone by feed-refresh, never from arXiv. DataCite is
// not an arXiv host, its records are CC0 and arXiv support named it as a metadata source. New papers appear when arXiv
// registers their DOIs at announcement (about three hours after arXiv's own listing). Pure helpers (Deno + Node).
import { DATACITE_API, dataciteGet, parseDataCiteRecord } from './datacite.ts';
import { POOL_CATEGORY, poolAuthors, type PoolFetch, type PoolItem, type PoolSource, type RefreshClaim, type RefreshDeps } from './feed-pool.ts';

/** Records per page: with abstracts, well under DataCite's bounded 1 MiB response. */
export const DATACITE_POOL_PAGE = 100;
/** At most this many pages a refresh (4,000 records), one at a time, a second apart. */
export const DATACITE_POOL_MAX_PAGES = 40;
/** The widest window a refresh reads: announcements of the last three days, so missed refreshes lose nothing. */
export const DATACITE_POOL_WINDOW_DAYS = 3;
/** A successful refresh marks as read the records created up to this long before it ran (DataCite registers an
 * announcement's DOIs over a few minutes and indexes them shortly after), so the next refresh rereads only that. */
export const DATACITE_POOL_LAG_HOURS = 3;
const FIELDS = 'doi,titles,creators,descriptions,subjects,version,dates,created,publicationYear,citationCount';
const DAY = /^\d{4}-\d{2}-\d{2}$/;
/** DataCite's search has no conditional GET; the instant read up to plays If-Modified-Since, kept in the source row's
 * `last_modified` (64 characters at most, migration 043; a category change clears it). */
const WATERMARK = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const validCategories = (categories: readonly string[]) =>
  categories.length >= 1 && categories.length <= 16 && categories.every(c => POOL_CATEGORY.test(c));
const dayBefore = (today: string, days: number) => new Date(Date.parse(`${today}T00:00:00Z`) - days * 86_400_000).toISOString().slice(0, 10);
const seconds = (ms: number) => `${new Date(ms).toISOString().slice(0, 19)}Z`;

/** arXiv's records in `categories` created since `since` (a day, or an instant to the second), newest first, page `page`. */
export function dataCitePoolURL(categories: readonly string[], since: string, page: number, size = DATACITE_POOL_PAGE): string {
  const from = DAY.test(since) ? `${since}T00:00:00Z` : /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(since) ? since : null;
  if (!validCategories(categories) || !from || Number.isNaN(Date.parse(from)) || !Number.isSafeInteger(page) || page < 1 || page > 100
    || !Number.isSafeInteger(size) || size < 1 || size > 200) throw new Error('invalid_categories');
  const query = `(${categories.map(c => `subjects.subject:"${c}"`).join(' OR ')}) AND created:[${from} TO *]`;
  const params = new URLSearchParams({ query, 'provider-id': 'arxiv', sort: '-created', 'page[size]': String(size), 'page[number]': String(page),
    'disable-facets': 'true', 'fields[dois]': FIELDS });
  return `${DATACITE_API}/dois?${params}`;
}

/** One category's newest records of the last week (a Feed chip outside the pool: discover's fallback). */
export const dataCiteCategoryURL = (category: string, today: string, size = 25): string =>
  dataCitePoolURL([category], dayBefore(today, 7), 1, size);

/** A page of DataCite's answer as pool items, bounded and validated as migration 043 requires: the paper's arXiv
 * categories (at most 12), "new" when its primary category is in the pool and "cross" otherwise, the day DataCite
 * created its DOI as the announcement day. Records that are not arXiv papers, or outside the window, are skipped. */
export function parseDataCitePool(json: unknown, options: { categories: readonly string[]; today: string; limit: number }):
  { items: PoolItem[]; skipped: number; more: boolean } {
  const body = json as { data?: unknown; links?: { next?: unknown } } | null;
  const data = Array.isArray(body?.data) ? body.data : [];
  const pool = new Set(options.categories), items: PoolItem[] = [];
  let skipped = 0;
  for (const resource of data) {
    const created = (resource as { attributes?: { created?: unknown } })?.attributes?.created;
    const at = typeof created === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(created) ? Date.parse(created) : NaN;
    if (items.length >= options.limit) { skipped++; continue; }
    const record = parseDataCiteRecord(resource);
    if (!record || !Number.isFinite(at)) { skipped++; continue; }
    const day = new Date(at).toISOString().slice(0, 10);
    const offset = Math.round((Date.parse(`${day}T00:00:00Z`) - Date.parse(`${options.today}T00:00:00Z`)) / 86_400_000);
    const categories = record.categories.filter(c => POOL_CATEGORY.test(c)).slice(0, 12);
    if (!categories.some(c => pool.has(c)) || record.title.length > 2000 || record.version < 1 || record.version > 10_000
      || offset < -60 || offset > 2) { skipped++; continue; }
    items.push({ source_id: record.sourceID, revision: record.version, title: record.title, authors: poolAuthors(record.authors),
      abstract: record.abstract ? record.abstract.slice(0, 2000) : null, categories, topics: [], announced_on: day,
      announce_type: pool.has(categories[0]) ? 'new' : 'cross' });
  }
  return { items, skipped, more: typeof body?.links?.next === 'string' && data.length > 0 };
}

/** Where a refresh starts reading: the last refresh's mark, never before the window. */
export function dataCitePoolSince(today: string, watermark: string | null): string {
  const floor = Date.parse(`${dayBefore(today, DATACITE_POOL_WINDOW_DAYS)}T00:00:00Z`);
  const mark = watermark && WATERMARK.test(watermark) ? Date.parse(watermark) : NaN;
  return seconds(Number.isFinite(mark) && mark > floor ? Math.min(mark, Date.parse(`${today}T00:00:00Z`) + 86_400_000) : floor);
}

/** The pool from DataCite: the records created since the last refresh's mark (at most the window), page by page a
 * second apart, every paper once, at most `max_items`. Nothing there is "not modified" and keeps the mark; otherwise
 * the mark moves to `DATACITE_POOL_LAG_HOURS` before this refresh. Writes are idempotent. */
export function dataCitePoolSource(options: { get?: (url: string, deps: RefreshDeps) => Promise<unknown>; now?: () => number } = {}): PoolSource {
  const get = options.get ?? ((url: string, deps: RefreshDeps) =>
    dataciteGet(url, { fetch: deps.fetch, sleep: deps.sleep, signal: AbortSignal.timeout(30_000) }));
  return async (deps: RefreshDeps, claim: RefreshClaim): Promise<PoolFetch> => {
    if (!validCategories(claim.categories)) return { status: 'failed', code: 'invalid_categories' };
    const started = (options.now ?? Date.now)();
    const today = deps.today(), since = dataCitePoolSince(today, claim.last_modified);
    const seen = new Map<string, PoolItem>();
    let skipped = 0;
    for (let page = 1; page <= DATACITE_POOL_MAX_PAGES && seen.size < claim.max_items; page++) {
      if (page > 1) await deps.sleep(1000);
      const parsed = parseDataCitePool(await get(dataCitePoolURL(claim.categories, since, page), deps),
        { categories: claim.categories, today, limit: claim.max_items - seen.size });
      skipped += parsed.skipped;
      for (const item of parsed.items) if (!seen.has(item.source_id)) seen.set(item.source_id, item);
      if (!parsed.more) break;
    }
    if (!seen.size) return { status: 'not_modified', skipped };
    const mark = Math.max(Date.parse(since), started - DATACITE_POOL_LAG_HOURS * 3_600_000);
    return { status: 'updated', items: [...seen.values()], skipped, etag: null, lastModified: seconds(mark) };
  };
}

// Search from this browser (docs/architecture/ARXIV_DEVICE_ONLY.md §5.6; owner, 2026-10-15). While the server's
// `device_search` capability is on, the person's search goes from this browser to DataCite (CORS; identified by
// `mailto`, since a browser cannot set a User-Agent), never through our server, and is ordered by the shared,
// explainable rules in paper-search.ts. One search's requests at a time; each query's results are kept in this tab
// for 24 hours; nothing is stored. The page has no paper-search box yet (a proposal for the owner, §5.6): this is the
// engine it would use. The search code and the DataCite client load only on the first search.
import { BackendError, rpc } from './backend';
import { decodeFeed, type DiscoveryResult } from './feed';

export const DEVICE_SEARCH_FORMAT = 'device-search-v1';
export const SEARCH_CACHE_MS = 86_400_000;
const CAPABILITY_TTL_MS = 10 * 60 * 1000;
const CACHE_ENTRIES = 50;

export interface BrowserSearchDeps {
  capabilities(account: string): Promise<{ device_search?: { enabled?: unknown; format?: unknown } } | null>;
  /** Tests: DataCite answered in-process. */
  fetch?: (input: string, init?: RequestInit) => Promise<Response>;
  now?: () => number;
}

const live: BrowserSearchDeps = { capabilities: account => rpc('v1_reader_capabilities', {}, { account, maximum: 16_384 }) };
const normalized = (query: string) => query.normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim();

export function browserSearch(account: string, deps: BrowserSearchDeps = live) {
  const now = deps.now ?? (() => Date.now());
  let capability: { on: boolean; at: number } | null = null;
  const cache = new Map<string, { at: number; results: DiscoveryResult[] }>();
  let queue: Promise<unknown> = Promise.resolve();

  async function enabled(): Promise<boolean> {
    if (capability && now() - capability.at < CAPABILITY_TTL_MS) return capability.on;
    let on = false;
    try { const caps = await deps.capabilities(account); on = caps?.device_search?.enabled === true && caps.device_search.format === DEVICE_SEARCH_FORMAT; }
    catch { on = false; }
    capability = { on, at: now() };
    return on;
  }

  async function run(query: string, signal?: AbortSignal): Promise<DiscoveryResult[]> {
    const { runSearch, SearchNotFound } = await import('../../../../supabase/functions/_shared/paper-search.ts');
    const { dataciteGet, DataCiteError } = await import('../../../../supabase/functions/_shared/datacite.ts');
    const results = await runSearch('datacite', query, async request => {
      try { return JSON.stringify(await dataciteGet(request.url, { browser: true, fetch: deps.fetch, signal, attempts: 2 })); }
      catch (error) { if (error instanceof DataCiteError && error.code === 'datacite_not_found') throw new SearchNotFound(); throw error; }
    });
    // The same decoder as every other paper list from the server.
    return decodeFeed({ results }).results;
  }

  return {
    enabled,
    /** The person's search; refused while the capability is off (the caller keeps today's behaviour). */
    async search(query: string, signal?: AbortSignal): Promise<DiscoveryResult[]> {
      const key = normalized(query);
      if (!key) return [];
      if (!await enabled()) throw new BackendError('device_search_disabled');
      const hit = cache.get(key);
      if (hit && now() - hit.at < SEARCH_CACHE_MS) return hit.results;
      const turn = queue.then(() => run(key, signal));
      queue = turn.catch(() => undefined);
      let results: DiscoveryResult[];
      try { results = await turn; } catch (error) { if (signal?.aborted) throw error; throw new BackendError('search_unavailable'); }
      cache.delete(key); cache.set(key, { at: now(), results });
      while (cache.size > CACHE_ENTRIES) cache.delete(cache.keys().next().value!);
      return results;
    },
  };
}

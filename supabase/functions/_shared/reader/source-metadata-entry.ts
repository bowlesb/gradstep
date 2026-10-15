// The native app's metadata extractor and device search (arxiv-source-metadata.js, built by
// scripts/build-arxiv-compiler.mjs): a separate bundle from the reader compiler, so reading a paper's metadata or
// searching never changes how a paper is prepared (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3, §5.6). Host:
// `GradstepSourceMetadata.extract(html, sourceID, revision)` and `.fromAtom(xml, sourceID, revision)` return the record
// as JSON, or "null"; `.searchRequests(query)`, `.searchCount(xml)` and `.searchResults(query, responses)` run a
// search whose requests the app makes itself (paced, identified, one at a time).
import './jsc-text-encoder.ts';
import { extractSourceMetadata, sourceMetadataFromAtom } from './arxiv/source-metadata.ts';
import { arxivSearchRequests, BROAD_BELOW, parseArxivAtom, planSearch, rankSearch, type SearchResult, type SearchRole } from '../paper-search.ts';

export function extract(html: string, sourceID: string, revision: number): string {
  if (typeof html !== 'string' || typeof sourceID !== 'string' || !Number.isSafeInteger(revision)) return 'null';
  try {
    const result = extractSourceMetadata(html, sourceID, revision);
    return JSON.stringify(result ? result.metadata : null);
  } catch {
    return 'null';
  }
}

/** The export API's Atom answer for one exact version (the native fallback for a paper without HTML). */
export function fromAtom(xml: string, sourceID: string, revision: number): string {
  if (typeof xml !== 'string' || typeof sourceID !== 'string' || !Number.isSafeInteger(revision)) return 'null';
  try {
    const result = sourceMetadataFromAtom(xml, sourceID, revision);
    return JSON.stringify(result ? result.metadata : null);
  } catch {
    return 'null';
  }
}

/** The export API requests for a search, as JSON `{requests: [{role, url}], broad: {role, url} | null, broad_below}`, or
 * "null" for an empty query. The app makes `requests` in order, and `broad` only when the relevance answer has fewer
 * than `broad_below` entries (`searchCount`). */
export function searchRequests(query: string): string {
  try {
    const plan = planSearch(query);
    if (!plan) return 'null';
    const { requests, broad } = arxivSearchRequests(plan);
    return JSON.stringify({ requests, broad, broad_below: BROAD_BELOW });
  } catch {
    return 'null';
  }
}

/** How many papers an Atom answer lists (-1 when it isn't one). */
export function searchCount(xml: string): number {
  try { return parseArxivAtom(xml).length; } catch { return -1; }
}

/** The ordered results (the discover contract) from the answers the app received, `{role: atom}` as JSON. */
export function searchResults(query: string, responses: string): string {
  try {
    const plan = planSearch(query);
    const answers = JSON.parse(responses) as Record<string, unknown>;
    if (!plan || !answers || typeof answers !== 'object') return '[]';
    const lists: Partial<Record<SearchRole, SearchResult[]>> = {};
    for (const role of ['id', 'relevance', 'phrase', 'broad'] as const) {
      const xml = answers[role];
      if (typeof xml !== 'string') continue;
      try { lists[role] = parseArxivAtom(xml); } catch { lists[role] = []; }
    }
    return JSON.stringify(rankSearch(plan, lists));
  } catch {
    return '[]';
  }
}

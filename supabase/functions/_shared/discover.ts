// arXiv discovery for the Library "arXiv" search. Pure helpers (Deno + Node).
import { arxivReference } from './arxiv.ts';
import { children, one, plain, sourceXML } from './source-xml.ts';

const ATOM = 'http://www.w3.org/2005/Atom';

export interface DiscoveryResult {
  source_id: string; revision: number; title: string; authors: string[]; year: number | null;
  abstract: string | null; categories: string[];
}

/** Builds a bounded arXiv API query: an ID/URL looks up that paper; free text
 * matches all words. Returns null for an empty or unusable query. */
export function arxivSearchURL(query: string, limit = 15): string | null {
  const text = query.normalize('NFKC').trim().slice(0, 300);
  if (!text) return null;
  const url = new URL('https://export.arxiv.org/api/query');
  try {
    const ref = arxivReference(text);
    url.search = new URLSearchParams({ id_list: `${ref.sourceID}${ref.revision ? `v${ref.revision}` : ''}`, max_results: '1' }).toString();
    return url.href;
  } catch { /* free text */ }
  const words = text.toLowerCase().replace(/[^\p{L}\p{N}\s.-]/gu, ' ').split(/\s+/).filter(w => w.length > 1 || /\d/.test(w)).slice(0, 12);
  if (!words.length) return null;
  url.search = new URLSearchParams({ search_query: words.map(w => `all:${w}`).join(' AND '), max_results: String(Math.min(Math.max(limit, 1), 25)),
    sortBy: 'relevance', sortOrder: 'descending' }).toString();
  return url.href;
}

/** Parses an arXiv Atom feed into compact results; malformed entries are skipped. */
export function parseArxivSearch(bytes: Uint8Array): DiscoveryResult[] {
  const root = sourceXML(bytes);
  if (root.uri !== ATOM || root.local !== 'feed') throw new Error('invalid_feed');
  const results: DiscoveryResult[] = [];
  for (const entry of children(root, ATOM, 'entry').slice(0, 25)) {
    try {
      const ref = arxivReference(plain(one(entry, ATOM, 'id'), 256)!);
      if (ref.revision === null) continue;
      const title = plain(one(entry, ATOM, 'title'), 2000)!.replace(/\s+/g, ' ').trim();
      const authors = children(entry, ATOM, 'author').slice(0, 9).map(a => plain(one(a, ATOM, 'name'), 256)!);
      const published = plain(one(entry, ATOM, 'published', false), 64, false);
      const abstract = plain(one(entry, ATOM, 'summary', false), 24_000, false)?.replace(/\s+/g, ' ').trim() ?? null;
      const categories = [...new Set(children(entry, ATOM, 'category').map(c => c.attributes['{}term']).filter((t): t is string => !!t && /^[A-Za-z][A-Za-z0-9.-]{0,63}$/.test(t)))].slice(0, 6);
      results.push({ source_id: ref.sourceID, revision: ref.revision, title, authors,
        year: published && /^\d{4}/.test(published) ? Number(published.slice(0, 4)) : null,
        abstract: abstract ? abstract.slice(0, 700) : null, categories });
    } catch { /* skip malformed entry */ }
  }
  return results;
}

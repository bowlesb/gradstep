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

/** Free-text queries of two or more words also run an oldest-first title
 * phrase search: arXiv's relevance ranking buries the original paper under
 * later derivatives (e.g. "direct preference optimization"). */
export function arxivSearchURLs(query: string): string[] {
  const primary = arxivSearchURL(query);
  if (!primary || new URL(primary).searchParams.has('id_list')) return primary ? [primary] : [];
  const phrase = query.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 120);
  if (phrase.split(' ').length < 2) return [primary];
  const url = new URL('https://export.arxiv.org/api/query');
  url.search = new URLSearchParams({ search_query: `ti:"${phrase}"`, max_results: '3', sortBy: 'submittedDate', sortOrder: 'ascending' }).toString();
  return [url.href, primary];
}

/** Newest announcements in one arXiv category (Feed): arXiv's daily RSS,
 * which is fast, unlike a date-sorted API query over a large category. */
export function arxivRecentURL(category: string): string | null {
  if (!/^[a-z]{2,8}(-[a-z]{2,6})?(\.[A-Z]{2})?$/.test(category)) return null;
  return `https://rss.arxiv.org/rss/${category}`;
}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
function xmlText(value: string): string {
  return value.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').replace(/<[^>]*>/g, '')
    .replace(/&(#x[0-9a-fA-F]{1,6}|#\d{1,7}|amp|lt|gt|quot|apos);/g, (_, e: string) => e[0] === '#'
      ? String.fromCodePoint(parseInt(e[1] === 'x' ? e.slice(2) : e.slice(1), e[1] === 'x' ? 16 : 10)) : ENTITIES[e])
    .replace(/\s+/g, ' ').trim();
}

/** Parses the first new announcements of an arXiv RSS feed. Bounded text
 * extraction (no entity expansion, no DTD); malformed items are skipped. */
export function parseArxivRSS(bytes: Uint8Array, limit = 25): DiscoveryResult[] {
  const text = new TextDecoder().decode(bytes.subarray(0, 4 * 1024 * 1024));
  if (!/^\s*(<\?xml[^>]*>\s*)?<rss[\s>]/.test(text) || /<!DOCTYPE/i.test(text)) throw new Error('invalid_feed');
  const results: DiscoveryResult[] = [];
  const itemPattern = /<item>([\s\S]*?)<\/item>/g;
  let match: RegExpExecArray | null;
  while ((match = itemPattern.exec(text)) && results.length < limit) {
    const item = match[1];
    const field = (name: string) => { const m = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(item); return m ? xmlText(m[1]) : null; };
    const description = field('description') ?? '';
    const header = /^arXiv:(\S+?)v(\d+) Announce Type: (\S+)/.exec(description);
    if (!header || !['new', 'cross'].includes(header[3])) continue;
    try {
      const ref = arxivReference(header[1]);
      const title = field('title');
      if (!title) continue;
      const year = /^\d{4}\./.test(ref.sourceID) ? 2000 + Number(ref.sourceID.slice(0, 2)) : null;
      const authors = (field('dc:creator') ?? '').split(/,\s*|\s+and\s+/).map(a => a.trim()).filter(a => a && a.length <= 256).slice(0, 9);
      const categories = [...item.matchAll(/<category>([^<]{1,64})<\/category>/g)].map(c => xmlText(c[1])).filter(c => /^[A-Za-z][A-Za-z0-9.-]{0,63}$/.test(c)).slice(0, 6);
      const abstract = description.replace(/^arXiv:\S+ Announce Type: \S+\s*Abstract:\s*/, '').slice(0, 700) || null;
      results.push({ source_id: ref.sourceID, revision: Number(header[2]), title: title.slice(0, 2000), authors, year, abstract, categories });
    } catch { /* skip malformed */ }
  }
  return results;
}

/** Earliest title matches first, then relevance results, without duplicates. */
export function mergeDiscovery(lists: DiscoveryResult[][]): DiscoveryResult[] {
  const seen = new Set<string>(); const merged: DiscoveryResult[] = [];
  for (const list of lists) for (const result of list) {
    if (!seen.has(result.source_id)) { seen.add(result.source_id); merged.push(result); }
  }
  return merged.slice(0, 25);
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

/** Title lookup for Ingest: an id lookup when the model supplied one, then
 * oldest-first title phrase and all-title-words queries. */
export function arxivTitleURLs(title: string, arxivID: string | null): string[] {
  const urls: string[] = [];
  if (arxivID) { try { const ref = arxivReference(arxivID); urls.push(`https://export.arxiv.org/api/query?${new URLSearchParams({ id_list: ref.sourceID, max_results: '1' })}`); } catch { /* ignored */ } }
  const words = titleWords(title).slice(0, 14);
  if (words.length < 2) return urls;
  const phrase = new URLSearchParams({ search_query: `ti:"${words.join(' ')}"`, max_results: '5', sortBy: 'submittedDate', sortOrder: 'ascending' });
  const all = new URLSearchParams({ search_query: words.filter(w => w.length > 2).slice(0, 10).map(w => `ti:${w}`).join(' AND '), max_results: '10', sortBy: 'relevance', sortOrder: 'descending' });
  urls.push(`https://export.arxiv.org/api/query?${phrase}`, `https://export.arxiv.org/api/query?${all}`);
  return urls;
}

function titleWords(title: string): string[] {
  return title.normalize('NFKC').toLowerCase().replace(/\$[^$]*\$/g, ' ').replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter(Boolean);
}

/** Token F1 between two titles (case, punctuation and math-insensitive). */
export function titleSimilarity(a: string, b: string): number {
  const x = titleWords(a), y = titleWords(b);
  if (!x.length || !y.length) return 0;
  const counts = new Map<string, number>();
  for (const w of x) counts.set(w, (counts.get(w) ?? 0) + 1);
  let common = 0;
  for (const w of y) { const n = counts.get(w) ?? 0; if (n > 0) { common++; counts.set(w, n - 1); } }
  return common === 0 ? 0 : 2 * common / (x.length + y.length);
}

export interface TitleQuery { title: string; year: number | null; firstAuthor: string | null; arxivID: string | null }
const NEGATIONS = new Set(['not', 'no', 'without', 'non', 'beyond']);
function surname(name: string): string {
  const family = name.includes(',') ? name.split(',')[0] : name.trim().split(/\s+/).at(-1) ?? '';
  return family.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^\p{L}]/gu, '');
}

/** The candidate a citation refers to, only if it clearly matches: a wrong
 * paper costs the reader a conversion, so near-misses are rejected. Requires
 * a near-identical title (or an exact main title before a subtitle), a
 * plausible year, the cited first author among the first authors, and no
 * negation difference ("… are not …"). Without an author, the title must be
 * exact; titles under four words also need the author and year. */
export function matchPaper<T extends { source_id: string; title: string; year: number | null; authors: readonly string[] }>(query: TitleQuery, candidates: readonly T[]): T | null {
  const wantedWords = titleWords(query.title);
  const author = query.firstAuthor ? surname(query.firstAuthor) : '';
  let best: { item: T; score: number } | null = null;
  for (const item of candidates) {
    let score = titleSimilarity(query.title, item.title);
    const main = item.title.split(':')[0];
    if (main !== item.title && titleWords(main).length >= 3 && titleSimilarity(query.title, main) === 1) score = Math.max(score, 0.95);
    const words = titleWords(item.title), wanted = new Set(wantedWords), found = new Set(words);
    if ([...NEGATIONS].some(word => wanted.has(word) !== found.has(word))) continue;
    const yearKnown = query.year !== null && item.year !== null;
    if (yearKnown && (item.year! < query.year! - 3 || item.year! > query.year! + 1)) continue;
    const authorMatch = author.length > 1 && item.authors.slice(0, 3).some(name => surname(name) === author);
    if (author && item.authors.length && !authorMatch) continue;
    if (!author && score < 1) continue;
    if (wantedWords.length < 4 && !(authorMatch && yearKnown) && item.source_id !== query.arxivID) continue;
    if (query.arxivID && item.source_id === query.arxivID) score += 0.05;
    if (!best || score > best.score) best = { item, score };
  }
  return best && best.score >= 0.9 ? best.item : null;
}

/** Runs arXiv API queries through the shared pacing (`slot` reserves request
 * slots and returns the wait). Used by the discover function and Ingest. */
export async function searchArxiv(urls: readonly string[], fetcher: typeof fetch,
  slot: (slots: number) => Promise<{ reserved: boolean; wait_ms: number; spacing_ms?: number }>, signal?: AbortSignal): Promise<DiscoveryResult[]> {
  if (!urls.length) return [];
  const pause = (ms: number) => new Promise<void>((resolve, reject) => {
    if (signal?.aborted) { reject(new Error('aborted')); return; }
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => { clearTimeout(timer); reject(new Error('aborted')); }, { once: true });
  });
  const reserved = await slot(urls.length);
  if (!reserved.reserved) throw new Error('search_busy');
  if (reserved.wait_ms > 0) await pause(reserved.wait_ms);
  const lists: DiscoveryResult[][] = [];
  for (const [index, url] of urls.entries()) {
    if (index > 0) await pause(reserved.spacing_ms ?? 3000);
    const timeout = AbortSignal.timeout(20_000);
    const response = await fetcher(url, { redirect: 'error', signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      headers: { accept: 'application/atom+xml', 'user-agent': 'ScienceReader/0.1 (research paper reader)' } });
    if (!response.ok || !response.body) { void response.body?.cancel().catch(() => {}); throw new Error('search_unavailable'); }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > 6 * 1024 * 1024) throw new Error('search_unavailable');
    lists.push(parseArxivSearch(bytes));
  }
  return mergeDiscovery(lists);
}

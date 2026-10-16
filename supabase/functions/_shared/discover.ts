// Finding papers on our servers without contacting arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md, rollout steps 5–7):
// the shared result row, OpenAlex candidates for a cited title (Ingest, Add), strict citation matching, and DataCite
// lookups by arXiv DOI or title. Paper search itself is paper-search.ts. Pure helpers (Deno + Node) apart from
// `lookupDataCite`.
import { arxivReference } from './arxiv.ts';
import { DATACITE_API, DataCiteError, dataciteBatchURL, dataciteGet, dataciteRecordURL, DATACITE_MAX_BATCH } from './datacite.ts';
import { formEncode, parseDataCiteSearch } from './paper-search.ts';
import { openPDFLocations } from './web-source.ts';

export interface DiscoveryResult {
  source_id: string; revision: number; title: string; authors: string[]; year: number | null;
  abstract: string | null; categories: string[];
  /** Opt-in presentation fields; the legacy preview stays <=700 characters. */
  full_abstract?: string | null; abstract_truncated?: boolean;
}

/** Keep older clients' bounded previews compatible; newer clients explicitly request full abstracts. */
function utf16Prefix(text: string, maximum: number): string {
  const value = text.toWellFormed();
  const last = value.charCodeAt(maximum - 1), next = value.charCodeAt(maximum);
  const end = last >= 0xd800 && last <= 0xdbff && next >= 0xdc00 && next <= 0xdfff ? maximum - 1 : maximum;
  return value.slice(0, end);
}

export function discoveryAbstract(text: string | null, full = false, sourceTruncated = false): Pick<DiscoveryResult, 'abstract' | 'full_abstract' | 'abstract_truncated'> {
  const value = text?.trim() || null;
  const preview = value ? utf16Prefix(value, 700) : null;
  if (!full) return { abstract: preview };
  return { abstract: preview, full_abstract: value ? utf16Prefix(value, 24_000) : null,
    abstract_truncated: sourceTruncated || (value?.length ?? 0) > 24_000 };
}

/** The arXiv copy an OpenAlex work lists (identity only: the link is parsed, never requested). */
function arxivLocationOf(work: { locations?: unknown }): { sourceID: string; version: number | null } | null {
  for (const location of Array.isArray(work.locations) ? work.locations.slice(0, 20) : []) {
    for (const key of ['landing_page_url', 'pdf_url']) {
      const value = (location as Record<string, unknown>)?.[key];
      const match = typeof value === 'string' ? /arxiv\.org\/(?:abs|pdf)\/([^?#\s]+?)(?:v(\d{1,3}))?(?:\.pdf)?$/i.exec(value) : null; // egress-ok: parse
      if (match) { try { return { sourceID: arxivReference(match[1]).sourceID, version: match[2] ? Number(match[2]) : null }; } catch { /* not an arXiv ID */ } }
    }
  }
  return null;
}

/** A paper as OpenAlex knows it, for Ingest: its arXiv copy if any, otherwise
 * its first open PDF location (see openPDFLocations) and DOI. `source_id` is the key matching uses. */
export interface OpenAlexCandidate {
  source_id: string; title: string; year: number | null; authors: string[];
  arxivID: string | null; openalexID: string; doi: string | null; pdfURL: string | null; landingURL: string | null; license: string | null;
}

/** OpenAlex works matching a cited title (any source), within a year of the cited year. */
export function openAlexFindURL(query: TitleQuery): string | null {
  const text = query.title.normalize('NFKC').replace(/[^\p{L}\p{N}\s.+#-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
  if (text.length < 3) return null;
  const url = new URL('https://api.openalex.org/works');
  const filters = query.year ? [`publication_year:${query.year - 1}-${query.year + 1}`] : [];
  url.search = new URLSearchParams({ search: text, 'per-page': '10',
    select: 'id,doi,title,publication_year,authorships,locations,best_oa_location', ...(filters.length ? { filter: filters.join(',') } : {}) }).toString();
  return url.href;
}

const safeURL = (value: unknown): string | null => {
  if (typeof value !== 'string' || value.length > 2000) return null;
  try { const url = new URL(value); return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null; } catch { return null; }
};

export function openAlexCandidates(json: unknown): OpenAlexCandidate[] {
  const results = (json as { results?: unknown })?.results;
  if (!Array.isArray(results)) throw new Error('invalid_openalex');
  const candidates: OpenAlexCandidate[] = [];
  for (const work of results.slice(0, 25)) {
    const w = work as { id?: unknown; doi?: unknown; title?: unknown; publication_year?: unknown; authorships?: unknown; best_oa_location?: unknown; locations?: unknown };
    if (typeof w.id !== 'string' || !/^https:\/\/openalex\.org\/W\d{1,15}$/.test(w.id) || typeof w.title !== 'string' || !w.title.trim()) continue;
    const arxiv = arxivLocationOf(w);
    const best = (w.best_oa_location ?? null) as { pdf_url?: unknown; landing_page_url?: unknown; license?: unknown } | null;
    const doi = typeof w.doi === 'string' ? /^https:\/\/doi\.org\/(10\.\d{4,9}\/\S{1,200})$/i.exec(w.doi)?.[1] ?? null : null;
    const authors = (Array.isArray(w.authorships) ? w.authorships.slice(0, 9) : [])
      .map(a => (a as { author?: { display_name?: unknown } })?.author?.display_name).filter((n): n is string => typeof n === 'string');
    const openalexID = w.id.slice('https://openalex.org/'.length);
    candidates.push({ source_id: arxiv?.sourceID ?? openalexID, title: w.title.replace(/\s+/g, ' ').trim().slice(0, 400),
      year: typeof w.publication_year === 'number' ? w.publication_year : null, authors, arxivID: arxiv?.sourceID ?? null, openalexID,
      doi, pdfURL: openPDFLocations(w)[0] ?? null, landingURL: safeURL(best?.landing_page_url) ?? (doi ? `https://doi.org/${doi}` : null),
      license: typeof best?.license === 'string' ? best.license.slice(0, 40) : null });
  }
  return candidates;
}

export function titleWords(title: string): string[] {
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

// --- DataCite lookups for a cited paper (Ingest, Add by text or DOI, a reference's Add to library). DataCite holds the
// metadata arXiv registers for every paper (CC0), by DOI (10.48550/arXiv.<id>) and by title; arXiv's API is never asked.
const LOOKUP_FIELDS = 'doi,titles,creators,descriptions,subjects,version,dates,publicationYear';
const lookupURL = (query: string, size: number, sort: string) => `${DATACITE_API}/dois?${formEncode({ query, 'provider-id': 'arxiv', sort,
  'page[size]': String(size), 'disable-facets': 'true', 'fields[dois]': LOOKUP_FIELDS })}`;

/** A cited title as DataCite queries, in order: the earliest papers titled with its words as a phrase (arXiv numbers
 * papers in order, so DOI order is submission order: the original before its derivatives), then papers whose titles
 * have every word, most relevant first. Words are letters and digits only, so no query syntax reaches DataCite. */
export function dataciteTitleURLs(title: string): string[] {
  const words = titleWords(title).filter(w => /^[\p{L}\p{N}]+$/u.test(w)).slice(0, 14);
  if (words.length < 2) return [];
  const urls = [lookupURL(`titles.title:"${words.join(' ')}"`, 5, 'name')];
  const all = words.filter(w => w.length > 2).slice(0, 10);
  if (all.length >= 2) urls.push(lookupURL(`titles.title:(${all.join(' AND ')})`, 10, 'relevance'));
  return urls;
}

/** The DataCite request for arXiv identifiers: one record by its DOI, or up to 25 in one request. Invalid IDs are dropped. */
export function dataciteIDURL(sourceIDs: readonly string[]): string | null {
  const ids = [...new Set(sourceIDs)].filter(id => { try { dataciteRecordURL(id); return true; } catch { return false; } }).slice(0, DATACITE_MAX_BATCH);
  return !ids.length ? null : ids.length === 1 ? dataciteRecordURL(ids[0]) : dataciteBatchURL(ids);
}

/** Runs DataCite lookups in order (a DOI DataCite doesn't have is no result, not a failure), each within 10 s, without
 * retrying a busy answer (these are interactive); results in order without duplicates. Throws when one fails. */
export async function lookupDataCite(urls: readonly string[], fetcher: typeof fetch, signal?: AbortSignal): Promise<DiscoveryResult[]> {
  const seen = new Set<string>(), results: DiscoveryResult[] = [];
  for (const url of urls) {
    let body: unknown;
    const within = signal ? AbortSignal.any([signal, AbortSignal.timeout(10_000)]) : AbortSignal.timeout(10_000);
    try { body = await dataciteGet(url, { fetch: fetcher, signal: within, attempts: 1 }); }
    catch (error) { if (error instanceof DataCiteError && error.code === 'datacite_not_found') continue; throw error; }
    for (const { citations: _, topics: __, ...result } of parseDataCiteSearch(body)) {
      if (!seen.has(result.source_id)) { seen.add(result.source_id); results.push(result); }
    }
  }
  return results;
}

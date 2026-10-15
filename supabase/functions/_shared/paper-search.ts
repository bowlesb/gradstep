// Paper search without OpenAlex (owner decision, 2026-10-15; docs/architecture/ARXIV_DEVICE_ONLY.md §5.6). One module for
// every place that searches: native devices ask arXiv's API (the app builds the requests and reads the Atom answers
// with this code in JavaScriptCore), the browser and the server's path for older builds ask DataCite. All of them order
// the results with the same rules, each one explainable to a reader:
//   1. the index's own relevance order (arXiv's or DataCite's word matching);
//   2. more of the query's words in the title, and the query as a phrase in the title;
//   3. machine-learning categories first, outside computing and statistics last (as the server search did);
//   4. the paper whose title or main title is exactly the query;
//   5. the earliest paper titled with the query's phrase: ×2 when its main title is the phrase (DPO), ×1.5 when the
//      phrase has three or more words and the paper is in a machine-learning category (RAG, chain of thought, NeRF):
//      usually the paper that named the idea, which word matching buries under its many derivatives.
// No citation counts: neither index has them for arXiv papers. Pure and synchronous apart from `runSearch`.
import { elements, parseHTML, type DomNode } from './reader/html.ts';
import { parseDataCiteRecord, DATACITE_API } from './datacite.ts';
import { isArxivSourceID } from './source-metadata.ts';
import { displayTopics, feedTopics } from './feed-topics.ts';

export const DEVICE_SEARCH_FORMAT = 'device-search-v1';
/** A strict search with fewer results than this also runs its broad one (any word on arXiv; near spellings on DataCite). */
export const BROAD_BELOW = 5;
/** Candidates asked of the index for reordering, and results shown. */
export const SEARCH_CANDIDATES = 50;
export const SEARCH_RESULTS = 25;

/** The response contract of today's search (discover?q=; native DiscoveryResult, browser decodeFeed). */
export interface SearchResult {
  source_id: string; revision: number; title: string; authors: string[]; year: number | null;
  abstract: string | null; full_abstract: string | null; abstract_truncated: boolean; categories: string[]; topics: string[];
}

export type SearchPlan =
  | { kind: 'id'; sourceID: string; revision: number | null }
  | { kind: 'text'; text: string; words: string[]; phrase: string | null };
export type SearchRole = 'id' | 'relevance' | 'phrase' | 'broad';
export interface SearchRequest { role: SearchRole; url: string }
export interface SearchRequests { requests: SearchRequest[]; broad: SearchRequest | null }
export type SearchEngine = 'arxiv' | 'datacite';
/** `get` throws this when the index says the paper isn't there (DataCite's 404 for an ID): no results, not a failure. */
export class SearchNotFound extends Error { constructor() { super('search_not_found'); } }

const STOP = new Set(['a', 'an', 'the', 'of', 'for', 'in', 'on', 'to', 'and', 'or', 'with', 'via', 'by', 'from', 'is', 'are', 'at', 'as', 'how', 'what', 'we', 'do', 'does']);
const normalized = (value: string) => value.normalize('NFKC').toLowerCase().replace(/\$[^$]*\$/g, ' ').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
/** Light stemming so "models" meets "model" and "learning" stays "learning". */
const stem = (word: string) => word.length > 3 && word.endsWith('s') && !word.endsWith('ss') ? word.slice(0, -1) : word;
const words = (value: string) => normalized(value).split(' ').filter(Boolean).map(stem);

/** An arXiv identifier or arXiv link in the query, else its words (at most 12) and, for 2–8 words, its phrase. */
export function planSearch(raw: string): SearchPlan | null {
  const text = typeof raw === 'string' ? raw.normalize('NFKC').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 300) : '';
  if (!text) return null;
  const id = /^(?:arxiv:\s*|(?:https?:\/\/)?(?:www\.|export\.)?arxiv\.org\/(?:abs|pdf)\/)?([a-z-]+(?:\.[a-z]{2})?\/\d{7}|\d{4}\.\d{4,5})(?:v(\d{1,4}))?(?:\.pdf)?\/?$/i.exec(text);
  if (id) {
    const sourceID = id[1].replace(/^([a-z-]+)\.([a-z]{2})\//i, (_, a: string, b: string) => `${a.toLowerCase()}.${b.toUpperCase()}/`).replace(/^([a-z-]+)\//i, (m: string) => m.toLowerCase());
    if (isArxivSourceID(sourceID)) return { kind: 'id', sourceID, revision: id[2] ? Number(id[2]) : null };
  }
  // Index query syntax never reaches an index: only letters, digits and hyphens inside words.
  const terms = text.toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, ' ').split(/\s+/).map(w => w.replace(/^-+|-+$/g, ''))
    .filter(w => w.length > 1 || /\d/.test(w)).slice(0, 12);
  if (!terms.length) return null;
  const phrase = terms.length >= 2 && terms.length <= 8 ? terms.join(' ') : null;
  // Matching every word: common words add nothing but can stop a match, so they go when others remain.
  const content = terms.filter(w => !STOP.has(w));
  return { kind: 'text', text, words: content.length ? content : terms, phrase };
}

// --- arXiv's API, from a device (native only: it sends no CORS headers). One request at a time, 3 s apart, by the app.
const ARXIV_API = 'https://export.arxiv.org/api/query'; // egress-ok: device
/** `application/x-www-form-urlencoded`, byte for byte as URLSearchParams writes it: JavaScriptCore has no URL APIs. */
export const formEncode = (params: Record<string, string>) => Object.entries(params).map(([key, value]) => [key, value]
  .map(part => encodeURIComponent(part).replace(/[!'()~]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`).replace(/%20/g, '+')).join('=')).join('&');
const arxivURL = (params: Record<string, string>) => `${ARXIV_API}?${formEncode(params)}`;

/** The device's requests: relevance (all words), then the oldest titles with the phrase; the broad one (any word)
 * only when the strict one finds fewer than `BROAD_BELOW`. */
export function arxivSearchRequests(plan: SearchPlan): SearchRequests {
  if (plan.kind === 'id') {
    return { requests: [{ role: 'id', url: arxivURL({ id_list: `${plan.sourceID}${plan.revision ? `v${plan.revision}` : ''}`, max_results: '1' }) }], broad: null };
  }
  const field = (w: string) => `all:${w.includes('-') ? `"${w}"` : w}`;
  const requests: SearchRequest[] = [{ role: 'relevance', url: arxivURL({ search_query: plan.words.map(field).join(' AND '),
    max_results: String(SEARCH_CANDIDATES), sortBy: 'relevance', sortOrder: 'descending' }) }];
  if (plan.phrase) requests.push({ role: 'phrase', url: arxivURL({ search_query: `ti:"${plan.phrase}"`, max_results: '3', sortBy: 'submittedDate', sortOrder: 'ascending' }) });
  const broad = plan.words.length > 1 ? { role: 'broad' as const, url: arxivURL({ search_query: plan.words.map(field).join(' OR '),
    max_results: String(SEARCH_CANDIDATES), sortBy: 'relevance', sortOrder: 'descending' }) } : null;
  return { requests, broad };
}

const textOf = (node: DomNode | undefined): string => {
  if (!node) return '';
  if (node.type === 'text') return node.data ?? '';
  return (node.children ?? []).map(textOf).join('');
};
const squash = (value: string) => value.replace(/\s+/g, ' ').trim();
const CATEGORY = /^[a-z-]{2,16}(\.[A-Za-z-]{2,16})?$/;

function abstractFields(text: string | null): Pick<SearchResult, 'abstract' | 'full_abstract' | 'abstract_truncated'> {
  // A lone surrogate becomes U+FFFD (String.prototype.toWellFormed, which the browser build's library predates).
  const value = text ? squash(text).replace(/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g, '\ufffd') : '';
  if (!value) return { abstract: null, full_abstract: null, abstract_truncated: false };
  const cut = (max: number) => { const end = value.length > max && /[\ud800-\udbff]/.test(value[max - 1]) ? max - 1 : max; return value.slice(0, end); };
  return { abstract: cut(700), full_abstract: cut(24_000), abstract_truncated: value.length > 24_000 };
}
const withTopics = (r: Omit<SearchResult, 'topics'>): SearchResult => ({ ...r, topics: displayTopics(feedTopics(r.title, r.full_abstract ?? r.abstract, r.categories)) });

/** arXiv's Atom answer as results (at most `SEARCH_CANDIDATES`); malformed entries are skipped, an error feed is empty. */
export function parseArxivAtom(xml: string): SearchResult[] {
  if (typeof xml !== 'string' || !/<feed[\s>]/.test(xml.slice(0, 4096)) || /<!DOCTYPE/i.test(xml)) throw new Error('invalid_feed');
  const root = parseHTML(xml, true);
  const results: SearchResult[] = [];
  for (const entry of elements(root, n => n.name === 'entry').slice(0, SEARCH_CANDIDATES)) {
    const child = (name: string) => (entry.children ?? []).filter(n => n.type === 'tag' && n.name === name);
    const id = /arxiv\.org\/abs\/(.+?)v(\d{1,4})$/.exec(squash(textOf(child('id')[0])));
    const title = squash(textOf(child('title')[0])).slice(0, 2000);
    if (!id || !isArxivSourceID(id[1]) || !title) continue;
    const authors = child('author').map(a => squash(textOf((a.children ?? []).find(n => n.type === 'tag' && n.name === 'name')))).filter(a => a && a.length <= 256).slice(0, 9);
    const primary = elements(entry, n => n.name === 'arxiv:primary_category')[0]?.attribs?.term;
    const categories = [...new Set([primary, ...child('category').map(c => c.attribs?.term)].filter((c): c is string => typeof c === 'string' && CATEGORY.test(c)))].slice(0, 6);
    const published = /^(\d{4})-/.exec(squash(textOf(child('published')[0])))?.[1];
    results.push(withTopics({ source_id: id[1], revision: Number(id[2]), title, authors, year: published ? Number(published) : null,
      ...abstractFields(textOf(child('summary')[0]) || null), categories }));
  }
  return results;
}

// --- DataCite, from the browser (CORS) or the server for older builds. Its query is AND by default; `~1` admits one edit.
const dataciteSearchURL = (query: string, size: number, sort: string) => `${DATACITE_API}/dois?${formEncode({ query, 'provider-id': 'arxiv',
  sort, 'page[size]': String(size), 'disable-facets': 'true', 'fields[dois]': 'doi,titles,creators,descriptions,subjects,version,dates,publicationYear' })}`;

/** The browser's requests: relevance (all words), then the earliest titles with the phrase (DOI order is arXiv's
 * numbering, which is chronological); near spellings only when the strict search finds fewer than `BROAD_BELOW`. */
export function dataciteSearchRequests(plan: SearchPlan): SearchRequests {
  if (plan.kind === 'id') return { requests: [{ role: 'id', url: `${DATACITE_API}/dois/10.48550/arXiv.${plan.sourceID}` }], broad: null };
  // The words are letters, digits and inner hyphens (planSearch); a hyphen is query syntax there, so it is escaped.
  const term = (w: string) => w.replace(/-/g, '\\-');
  const strict = plan.words.map(term).join(' ');
  const requests: SearchRequest[] = [{ role: 'relevance', url: dataciteSearchURL(strict, SEARCH_CANDIDATES, 'relevance') }];
  if (plan.phrase) requests.push({ role: 'phrase', url: dataciteSearchURL(`titles.title:"${plan.phrase}"`, 3, 'name') });
  const fuzzy = plan.words.map(w => w.length >= 3 && /^[\p{L}]+$/u.test(w) ? `${w}~1` : term(w)).join(' ');
  return { requests, broad: fuzzy !== strict ? { role: 'broad', url: dataciteSearchURL(fuzzy, SEARCH_CANDIDATES, 'relevance') } : null };
}

/** DataCite's answer (a list, or one DOI) as results; records that are not arXiv papers are skipped. */
export function parseDataCiteSearch(json: unknown): SearchResult[] {
  const data = (json as { data?: unknown })?.data;
  const items = Array.isArray(data) ? data.slice(0, SEARCH_CANDIDATES) : data ? [data] : [];
  return items.flatMap(item => {
    const record = parseDataCiteRecord(item);
    if (!record) return [];
    const first = record.submitted[1] ?? Object.values(record.submitted).sort()[0];
    const year = first ? Number(first.slice(0, 4)) : Number((item as { attributes?: { publicationYear?: unknown } }).attributes?.publicationYear) || null;
    return [withTopics({ source_id: record.sourceID, revision: record.version, title: record.title.slice(0, 2000), authors: record.authors.slice(0, 9),
      year, ...abstractFields(record.abstract), categories: record.categories.slice(0, 6) })];
  });
}

export const searchRequests = (engine: SearchEngine, plan: SearchPlan) => engine === 'arxiv' ? arxivSearchRequests(plan) : dataciteSearchRequests(plan);
export function parseSearchResponse(engine: SearchEngine, body: string): SearchResult[] {
  if (engine === 'arxiv') return parseArxivAtom(body);
  let json: unknown;
  try { json = JSON.parse(body); } catch { throw new Error('invalid_feed'); }
  return parseDataCiteSearch(json);
}

// --- Ordering (the rules at the top). Every factor is a plain multiplier, listed in `explainResult`.
const ML = new Set(['cs.LG', 'cs.CL', 'cs.CV', 'cs.AI', 'cs.NE', 'cs.IR', 'cs.RO', 'cs.MA', 'cs.SD', 'stat.ML', 'eess.IV', 'eess.AS', 'math.OC']);
export interface SearchFactors { relevance: number; title: number; field: number; exact: number; original: number }

export function rankSearch(plan: SearchPlan, lists: Partial<Record<SearchRole, SearchResult[]>>, limit = SEARCH_RESULTS): SearchResult[] {
  return explainSearch(plan, lists, limit).map(r => r.result);
}

export function explainSearch(plan: SearchPlan, lists: Partial<Record<SearchRole, SearchResult[]>>, limit = SEARCH_RESULTS):
  { result: SearchResult; score: number; factors: SearchFactors }[] {
  if (plan.kind === 'id') return (lists.id ?? []).filter(r => r.source_id === plan.sourceID).slice(0, 1)
    .map(result => ({ result, score: 1, factors: { relevance: 1, title: 1, field: 1, exact: 1, original: 1 } }));
  const wanted = words(plan.text), content = [...new Set(wanted.filter(w => !STOP.has(w)))];
  const phrase = plan.phrase ? words(plan.phrase).join(' ') : null;
  const query = wanted.join(' ');
  const candidates = new Map<string, { result: SearchResult; rank: number }>();
  const strict = lists.relevance ?? [], broad = lists.broad ?? [];
  strict.forEach((result, rank) => { if (!candidates.has(result.source_id)) candidates.set(result.source_id, { result, rank }); });
  broad.forEach((result, rank) => { if (!candidates.has(result.source_id)) candidates.set(result.source_id, { result, rank: strict.length + rank }); });
  // The earliest paper titled with the phrase (rule 5) leads, even when the relevance list buried it; the other phrase
  // answers join at the back.
  const mainTitle = (title: string) => words(title.split(/:\s|\s[-–—]\s/)[0]).join(' ');
  const titled = (r: SearchResult) => phrase !== null && ` ${words(r.title).join(' ')} `.includes(` ${phrase} `);
  const earliest = (lists.phrase ?? []).find(titled) ?? null;
  const originalFactor = !earliest || !phrase ? 1 : mainTitle(earliest.title) === phrase ? 2
    : phrase.split(' ').length >= 3 && earliest.categories.some(c => ML.has(c)) ? 1.5 : 1;
  for (const result of lists.phrase ?? []) {
    const lead = originalFactor > 1 && result === earliest;
    const known = candidates.get(result.source_id);
    if (lead) candidates.set(result.source_id, { result: known?.result ?? result, rank: 0 });
    else if (!known) candidates.set(result.source_id, { result, rank: Math.max(SEARCH_CANDIDATES, strict.length + broad.length) });
  }
  const scored = [...candidates.values()].map(({ result, rank }) => {
    const title = words(result.title), titleSet = new Set(title), joined = ` ${title.join(' ')} `;
    const coverage = content.length ? content.filter(w => titleSet.has(w)).length / content.length : 0;
    const factors: SearchFactors = {
      relevance: 1 / (1 + rank / 10),
      title: 1 + 0.5 * coverage + (phrase && joined.includes(` ${phrase} `) ? 0.5 : 0),
      field: result.categories.some(c => ML.has(c)) ? 1.15 : result.categories.some(c => /^(cs|stat)\./.test(c)) || !result.categories.length ? 1 : 0.7,
      exact: query && (title.join(' ') === query || mainTitle(result.title) === query) ? 3 : 1,
      original: earliest && earliest.source_id === result.source_id ? originalFactor : 1,
    };
    return { result, score: factors.relevance * factors.title * factors.field * factors.exact * factors.original, factors };
  });
  return scored.sort((a, b) => b.score - a.score || (a.result.source_id < b.result.source_id ? -1 : 1)).slice(0, limit);
}

/** One search, start to finish, through `get` (which owns pacing, caching and identification). The broad request runs
 * only when the strict one found fewer than `BROAD_BELOW` papers; a failed phrase or broad request leaves the others. */
export async function runSearch(engine: SearchEngine, query: string, get: (request: SearchRequest) => Promise<string>,
  limit = SEARCH_RESULTS): Promise<SearchResult[]> {
  const plan = planSearch(query);
  if (!plan) return [];
  const { requests, broad } = searchRequests(engine, plan);
  const lists: Partial<Record<SearchRole, SearchResult[]>> = {};
  for (const request of requests) {
    try { lists[request.role] = parseSearchResponse(engine, await get(request)); }
    catch (error) {
      if (error instanceof SearchNotFound) lists[request.role] = [];
      else if (request.role === 'relevance' || request.role === 'id') throw error;
    }
  }
  if (broad && (lists.relevance?.length ?? 0) < BROAD_BELOW) {
    try { lists.broad = parseSearchResponse(engine, await get(broad)); } catch { /* the strict results stand */ }
  }
  return rankSearch(plan, lists, limit);
}

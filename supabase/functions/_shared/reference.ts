// "Add to library" on a bibliography entry, without a model: read the entry's arXiv id or
// DOI, else match it with Crossref's citation matcher, then find an arXiv or open-access copy
// with the shared finder. A found paper is accepted only if its title appears in the entry.
import type { FindResult, FoundPaper } from './chat.ts';
import { openAlexCandidates, searchArxiv, titleWords, type DiscoveryResult } from './discover.ts';
import { publicHTTPS } from './web-source.ts';

export const MAX_REFERENCE_CHARS = 2_000;
const MAILTO = 'hello@gradstep.ai';

/** arXiv ids written in the entry (new style, with or without a version). */
export function arxivIDs(text: string): string[] {
  const ids = [...text.matchAll(/(?<![\d.])(\d{4}\.\d{4,5})(?:v\d+)?(?![\d])/g)].map(m => m[1]);
  return [...new Set(ids)].slice(0, 3);
}

/** DOIs written in the entry, trailing punctuation removed. */
export function dois(text: string): string[] {
  const found = [...text.matchAll(/\b10\.\d{4,9}\/[^\s"<>]+/gi)].map(m => m[0].replace(/[.,;:)\]]+$/, ''));
  return [...new Set(found.map(d => d.toLowerCase()))].slice(0, 2);
}

/** True when nearly every significant word of `title` appears in the entry (in any order). */
export function titleInReference(title: string, reference: string): boolean {
  const wanted = titleWords(title);
  if (wanted.length < 2) return false;
  const present = new Set(titleWords(reference));
  const hits = wanted.filter(word => present.has(word)).length;
  return hits / wanted.length >= 0.85;
}

/** The entry without numbering and links, for a citation search. */
export function citationText(reference: string): string {
  return reference.normalize('NFKC').replace(/https?:\/\/\S+/g, ' ').replace(/^\s*\[?\d{1,4}[\].)]?\s*/, '')
    .replace(/\s+/g, ' ').trim().slice(0, 600);
}

const VENUE = /^(?:in\b|proc(?:eedings)?\b|arxiv\b|journal\b|advances in\b|conference\b|international\b|ieee\b|acm\b|springer\b|vol(?:ume)?\b|pp?\.|pages\b|technical report\b|preprint\b|morgan kaufmann\b|mit press\b|cambridge\b|oxford\b|openreview\b)/i;
/** Looks like an author list: initials, "and", "et al.", or a short run of capitalised names. */
function authorLike(segment: string): boolean {
  // APA style: "He, K., Zhang, X., & Sun, J. (2016)".
  if (/,.*\(\d{4}[a-z]?\)$/.test(segment) || /&/.test(segment) && /,/.test(segment)) return true;
  if (/\bet al\b/i.test(segment) || /(?:^|\s)\p{Lu}\.\s?(?:\p{Lu}\.\s?)?\p{Lu}\p{Ll}/u.test(segment)) return true;
  const words = segment.split(/\s+/);
  if (/(?:,|\band\b)/.test(segment) && words.every(w => /^(?:and|\p{Lu}[\p{L}'-]*,?|\p{Lu}\.,?)$/u.test(w))) return true;
  return words.length <= 4 && words.every(w => /^\p{Lu}[\p{L}'-]*\.?,?$/u.test(w)) && !/:/.test(segment);
}

/** Likely titles in a bibliography entry, most likely first: a quoted title, else the first
 * sentence-like segment after the authors that isn't a venue, year or page range. */
export function candidateTitles(reference: string): string[] {
  const text = citationText(reference);
  const titles: string[] = [];
  for (const m of text.matchAll(/[“"]([^”"]{8,300})[”"]/g)) titles.push(m[1].replace(/[,.\s]+$/, ''));
  const segments = text.split(/\.\s+(?=[A-Z0-9“"])/).map(t => t.replace(/^[,;\s]+|[,;.\s]+$/g, '')).filter(Boolean);
  for (const [index, segment] of segments.entries()) {
    const words = segment.split(/\s+/);
    if (words.length < 2 || words.length > 40) continue;
    if (index === 0 && authorLike(segment)) continue;
    if (VENUE.test(segment) || /^\(?\d{4}\)?$/.test(segment) || /^\d/.test(segment)) continue;
    // Volume/page lines ("JMLR, 15(1):1929–1958, 2014") and a segment that already holds a quoted title.
    if (/\d+\s*\(\d+\)|\d+\s*[–-]\s*\d+/.test(segment) || /[“"]/.test(segment)) continue;
    // A short venue-and-year line ("JMLR 2023", "NeurIPS, 2017").
    if (words.length <= 4 && /\b(?:19|20)\d{2}\b/.test(segment)) continue;
    if (authorLike(segment) && !/:/.test(segment)) continue;
    titles.push(segment);
  }
  return [...new Set(titles.map(t => t.replace(/\s+/g, ' ').trim()))].filter(t => t.length >= 8).slice(0, 3);
}

/** The latest plausible year written in the entry. */
export function referenceYear(reference: string): number | null {
  const years = [...reference.matchAll(/\b(19[5-9]\d|20\d{2})\b/g)].map(m => Number(m[1]));
  return years.length ? years[years.length - 1] : null;
}

export function crossrefURL(reference: string): string {
  const url = new URL('https://api.crossref.org/works');
  url.search = new URLSearchParams({ 'query.bibliographic': citationText(reference), rows: '3',
    select: 'DOI,title,author,issued,score', mailto: MAILTO }).toString();
  return url.href;
}

export interface CrossrefCandidate { doi: string; title: string; year: number | null; firstAuthor: string | null; score: number }
export function crossrefCandidates(json: unknown): CrossrefCandidate[] {
  const items = (json as { message?: { items?: unknown } })?.message?.items;
  if (!Array.isArray(items)) return [];
  const out: CrossrefCandidate[] = [];
  for (const raw of items.slice(0, 5)) {
    const item = raw as { DOI?: unknown; title?: unknown; author?: unknown; issued?: { 'date-parts'?: unknown }; score?: unknown };
    const title = Array.isArray(item.title) && typeof item.title[0] === 'string' ? item.title[0].replace(/\s+/g, ' ').trim() : '';
    if (typeof item.DOI !== 'string' || !title) continue;
    const parts = item.issued?.['date-parts'];
    const year = Array.isArray(parts) && Array.isArray(parts[0]) && Number.isInteger(parts[0][0]) ? parts[0][0] as number : null;
    const first = Array.isArray(item.author) ? item.author[0] as { family?: unknown; given?: unknown } | undefined : undefined;
    const firstAuthor = first && typeof first.family === 'string' ? `${typeof first.given === 'string' ? `${first.given} ` : ''}${first.family}` : null;
    out.push({ doi: item.DOI.toLowerCase(), title, year, firstAuthor, score: typeof item.score === 'number' ? item.score : 0 });
  }
  return out;
}

export type ReferenceRoute = 'arxiv_id' | 'doi' | 'title' | 'crossref' | 'openalex' | 'none';
export interface ReferenceDeps {
  fetch: typeof fetch;
  /** Reserves paced arXiv API slots (shared with the pipeline). */
  slot: (slots: number) => Promise<{ reserved: boolean; wait_ms: number; spacing_ms?: number }>;
  findPaper: (wanted: { title: string; year: number | null; firstAuthor: string | null; arxivID: string | null }, signal: AbortSignal, options: { web: boolean }) => Promise<FindResult>;
}

const UA = { accept: 'application/json', 'user-agent': `Gradstep/0.1 (research paper reader; mailto:${MAILTO})` };
async function getJSON(fetcher: typeof fetch, url: string, signal: AbortSignal): Promise<unknown | null> {
  try {
    const response = await fetcher(url, { headers: UA, redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(8_000)]) });
    if (!response.ok) { void response.body?.cancel().catch(() => {}); return null; }
    return await response.json();
  } catch { return null; }
}

/** OpenAlex's record for a DOI: an arXiv copy, an open-access PDF, or a closed paper. */
async function byDOI(deps: ReferenceDeps, doi: string, reference: string, web: boolean, signal: AbortSignal): Promise<FindResult | null> {
  const select = 'id,doi,title,publication_year,authorships,locations,best_oa_location';
  const work = await getJSON(deps.fetch, `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=${select}`, signal);
  if (!work) return null;
  const [candidate] = openAlexCandidates({ results: [work] });
  if (!candidate || !titleInReference(candidate.title, reference)) return null;
  if (candidate.arxivID) return { status: 'found', paper: { source_id: candidate.arxivID, title: candidate.title, year: candidate.year, kind: 'arxiv' } };
  const open = candidate.pdfURL ? publicHTTPS(candidate.pdfURL.replace(/^http:\/\//i, 'https://')) : null;
  const paper: FoundPaper = { source_id: `openalex:${candidate.openalexID}`, title: candidate.title, year: candidate.year, kind: 'web',
    host: open?.hostname ?? null, link: candidate.landingURL };
  if (open && !/(^|\.)arxiv\.org$/.test(open.hostname)) return { status: web ? 'found' : 'needs_update', paper };
  return { status: 'closed', paper };
}

/**
 * Identifies the paper a bibliography entry cites and where an open copy is. Never throws;
 * `unavailable` when no source could be consulted.
 */
export async function resolveReference(deps: ReferenceDeps, reference: string, web: boolean, signal: AbortSignal)
  : Promise<{ result: FindResult; route: ReferenceRoute }> {
  let consulted = false;
  // 1. An arXiv id in the entry: one direct lookup, accepted if the title matches the entry.
  const ids = arxivIDs(reference);
  if (ids.length) {
    const url = `https://export.arxiv.org/api/query?${new URLSearchParams({ id_list: ids.join(','), max_results: String(ids.length) })}`;
    try {
      const found: DiscoveryResult[] = await searchArxiv([url], deps.fetch, deps.slot, signal);
      consulted = true;
      const match = found.find(paper => titleInReference(paper.title, reference)) ?? (found.length === 1 && citationText(reference).length < 40 ? found[0] : undefined);
      if (match) return { route: 'arxiv_id', result: { status: 'found', paper: { source_id: match.source_id, title: match.title, year: match.year, kind: 'arxiv' } } };
    } catch { /* fall through */ }
  }
  // 2. A DOI in the entry.
  let closed: FindResult | null = null;
  for (const doi of dois(reference)) {
    const found = await byDOI(deps, doi, reference, web, signal);
    if (found) { consulted = true; if (found.status !== 'closed') return { route: 'doi', result: found }; closed ??= found; }
  }
  // 3. The entry's own title (quoted, or between the authors and the venue) through the shared strict
  //    search: OpenAlex (arXiv copies, open-access PDFs) and arXiv. Fast, and what a reader would do.
  for (const title of candidateTitles(reference).slice(0, 2)) {
    if (signal.aborted) break;
    const viaTitle = await deps.findPaper({ title, year: referenceYear(reference), firstAuthor: null, arxivID: null }, signal, { web })
      .catch((): FindResult => ({ status: 'unavailable' }));
    if (viaTitle.status !== 'unavailable') consulted = true;
    if (viaTitle.status === 'found' || viaTitle.status === 'needs_update') return { route: 'title', result: viaTitle };
    if (viaTitle.status === 'closed') closed ??= viaTitle;
  }
  // 4. Crossref's citation matcher, accepted only if the matched title appears in the entry; then its DOI,
  //    then the shared title search (arXiv preprints of journal papers often have no DOI link).
  const crossref = await getJSON(deps.fetch, crossrefURL(reference), signal);
  if (crossref) consulted = true;
  const match = crossrefCandidates(crossref).find(candidate => titleInReference(candidate.title, reference));
  if (match) {
    const viaDOI = await byDOI(deps, match.doi, reference, web, signal);
    if (viaDOI && viaDOI.status !== 'closed') return { route: 'crossref', result: viaDOI };
    const viaTitle = await deps.findPaper({ title: match.title, year: match.year, firstAuthor: match.firstAuthor, arxivID: null }, signal, { web })
      .catch((): FindResult => ({ status: 'unavailable' }));
    if (viaTitle.status === 'found' || viaTitle.status === 'needs_update') return { route: 'crossref', result: viaTitle };
    return { route: 'crossref', result: viaDOI ?? (viaTitle.status === 'closed' ? viaTitle : closed ?? { status: 'closed', paper: { source_id: `doi:${match.doi}`, title: match.title, year: match.year, link: `https://doi.org/${match.doi}` } }) };
  }
  if (closed) return { route: 'doi', result: closed };
  // 5. No citation match (many ML papers exist only on arXiv or at venues Crossref doesn't index):
  //    OpenAlex's search on the entry, accepting a work whose title appears in it.
  const search = new URL('https://api.openalex.org/works');
  search.search = new URLSearchParams({ search: citationText(reference).slice(0, 300), 'per-page': '10',
    select: 'id,doi,title,publication_year,authorships,locations,best_oa_location', mailto: MAILTO }).toString();
  const listed = await getJSON(deps.fetch, search.href, signal);
  if (listed) {
    consulted = true;
    let candidates: ReturnType<typeof openAlexCandidates> = [];
    try { candidates = openAlexCandidates(listed).filter(c => titleInReference(c.title, reference)); } catch { candidates = []; }
    const best = candidates.find(c => c.arxivID) ?? candidates.find(c => c.pdfURL) ?? candidates[0];
    if (best) {
      const viaTitle = await deps.findPaper({ title: best.title, year: best.year, firstAuthor: null, arxivID: best.arxivID ?? null }, signal, { web })
        .catch((): FindResult => ({ status: 'unavailable' }));
      if (viaTitle.status !== 'not_found' && viaTitle.status !== 'unavailable') return { route: 'openalex', result: viaTitle };
    }
  }
  return { route: 'none', result: { status: consulted && !signal.aborted ? 'not_found' : 'unavailable' } };
}

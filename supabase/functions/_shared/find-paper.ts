// Finding a cited paper and adding it to a reader's library: shared by Ingest in chat
// (the model names the paper) and the direct "Add to library" on a reference (no model).
// Strict matches only: an arXiv id the citation names (its DataCite record), then, only while the owner's
// `openalex_enabled` switch is on, OpenAlex (arXiv copies, open-access PDFs), then DataCite's title search and a
// scholarly web search in parallel (capped at 15 s). Our servers never contact arXiv
// (docs/architecture/ARXIV_DEVICE_ONLY.md). OpenAlex is off by owner decision (migration 075, §6.0.4): an absent,
// unreadable or failed policy keeps it off.
import type { SupabaseClient } from '@supabase/supabase-js';
import type { FindResult, FoundPaper, PaperRequest } from './chat.ts';
import { arxivReference } from './arxiv.ts';
import { dataciteIDURL, dataciteTitleURLs, lookupDataCite, matchPaper, type DiscoveryResult, openAlexCandidates, openAlexFindURL } from './discover.ts';
import { publicHTTPS } from './web-source.ts';
import { readJSONCapped } from './bounded-json.ts';
/** An OpenAlex search answer (10 works, selected fields) is tens of kilobytes; refuse anything far larger (review A24). */
const OPENALEX_MAX_BYTES = 2 * 1024 * 1024;
import type { SearchInput, SearchOutcome } from './tavily.ts';

export interface FinderOptions {
  /** `pipeline_policy.openalex_enabled` (`worker_search_policy().openalex`, migration 072; switched off by 075). Read
   * lazily, at most once, and only when a title lookup runs. Anything but an explicit `true` keeps OpenAlex off. */
  openAlex?: boolean | (() => Promise<boolean>);
  /** The caller's request identity (add-paper/add-reference `operation_id`, the chat operation for Ingest): an import's
   * operation UUID is derived from it and the paper, so a retried request replays instead of queuing twice (review A5). */
  requestID?: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** The import's operation UUID for `v2_add_paper_once`: a domain-separated SHA-256 of the request, the kind and the
 * source, shaped as a UUID (version 4 bits, as provider attempt ids are). No request identity: a random one. */
export async function serverAddOperationID(requestID: string | undefined, paper: Pick<FoundPaper, 'source_id' | 'kind'>): Promise<string> {
  if (!requestID || !UUID.test(requestID)) return crypto.randomUUID();
  const bytes = new TextEncoder().encode(JSON.stringify(['gradstep/server-add/v1', requestID.toLowerCase(), paper.kind === 'web' ? 'web' : 'arxiv', paper.source_id]));
  const hex = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

/** Whether a policy reading allows OpenAlex: only an explicit `true` does (fail closed). */
export function openAlexAllowed(policy: unknown): boolean {
  return !!policy && typeof policy === 'object' && !Array.isArray(policy) && (policy as { openalex?: unknown }).openalex === true;
}

/** Paid search is injected already admitted; a raw provider key is never accepted. */
export function paperFinder(user: SupabaseClient,
  search?: (input: SearchInput, signal: AbortSignal) => Promise<SearchOutcome>, fetcher: typeof fetch = fetch, options: FinderOptions = {}) {
  let allowed: Promise<boolean> | null = null;
  const openAlexOn = () => allowed ??= (async () => {
    try { return typeof options.openAlex === 'function' ? await options.openAlex() === true : options.openAlex === true; }
    catch { return false; }
  })();
  async function findPaper(wanted: PaperRequest, signal: AbortSignal, { web, tavily = false }: { web: boolean; tavily?: boolean }): Promise<FindResult> {
    // Stopping at the first clear match. A failed query does not hide the others; all failing is "unavailable".
    const seen: DiscoveryResult[] = [];
    let answered = false, closed: FindResult | null = null;
    // OpenAlex first (only with the switch on), in parallel: it answers in about a second and knows a paper's other
    // versions (an arXiv copy under a conference title; open-access PDFs elsewhere), under the same strict match.
    // DataCite's title search is the fallback, and the only title search with the switch off.
    const openAlex = (async (): Promise<FindResult | null> => {
      const find = openAlexFindURL(wanted);
      if (!find || !await openAlexOn()) return null;
      try {
        const response = await fetcher(find, { redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
          headers: { accept: 'application/json', 'user-agent': 'Gradstep/0.1 (research paper reader; +https://gradstep.ai; mailto:hello@gradstep.ai)' } });
        if (!response.ok) { void response.body?.cancel().catch(() => {}); return null; }
        answered = true;
        // A paper's preprint and journal versions are often separate works: prefer one
        // with an arXiv copy, then one with an open-access PDF.
        const candidates = openAlexCandidates(await readJSONCapped(response, OPENALEX_MAX_BYTES));
        const openPDF = (url: string | null) => {
          const open = url ? publicHTTPS(url.replace(/^http:\/\//i, 'https://')) : null;
          return open && !/(^|\.)arxiv\.org$/.test(open.hostname) ? open : null;
        };
        const match = matchPaper(wanted, candidates.filter(c => c.arxivID)) ?? matchPaper(wanted, candidates.filter(c => openPDF(c.pdfURL)))
          ?? matchPaper(wanted, candidates);
        if (match?.arxivID) return { status: 'found', paper: { source_id: match.arxivID, title: match.title, year: match.year, kind: 'arxiv' } };
        if (!match) return null;
        const open = openPDF(match.pdfURL);
        const paper = { source_id: `openalex:${match.openalexID}`, title: match.title, year: match.year, kind: 'web' as const,
          host: open?.hostname ?? null, link: match.landingURL };
        if (open) return { status: web ? 'found' : 'needs_update', paper };
        closed = { status: 'closed', paper };
        return null;
      } catch { return null; }
    })();
    const lookup = async (url: string | null, within: AbortSignal): Promise<FindResult | null> => {
      if (!url || within.aborted) return null;
      try { seen.push(...await lookupDataCite([url], fetcher, within)); answered = true; } catch { return null; }
      const match = matchPaper(wanted, seen);
      return match ? { status: 'found', paper: { source_id: match.source_id, title: match.title, year: match.year } } : null;
    };
    // An arXiv id in the citation is checked directly (its DataCite record, one request).
    const cited = (() => { try { return wanted.arxivID ? arxivReference(wanted.arxivID).sourceID : null; } catch { return null; } })();
    if (cited) {
      const byID = await lookup(dataciteIDURL([cited]), signal);
      if (byID) return byID;
    }
    const viaOpenAlex = await openAlex;
    if (viaOpenAlex) return viaOpenAlex;
    // Fallbacks, in parallel and capped at 15 s so "not found" is said promptly: DataCite's title
    // search, and a scholarly web search (Tavily) for an arXiv copy under another title (named by
    // DataCite). Both accept only the same strict match.
    const fallback = AbortSignal.any([signal, AbortSignal.timeout(15_000)]);
    const byTitle = (async (): Promise<FindResult | null> => {
      for (const url of dataciteTitleURLs(wanted.title)) { const found = await lookup(url, fallback); if (found) return found; if (fallback.aborted) break; }
      return null;
    })();
    const byWeb = (async (): Promise<FindResult | null> => {
      if (!tavily || !search) return null;
      const query = `${wanted.title}${wanted.firstAuthor ? ` ${wanted.firstAuthor}` : ''} arXiv`;
      const searched = await search({ query, academic: true }, fallback).catch(() => null);
      const ids = searched?.status === 'ok'
        ? [...new Set(searched.results.flatMap(r => /arxiv\.org\/(?:abs|pdf)\/(\d{4}\.\d{4,5})/.exec(r.url)?.[1] ?? []))].slice(0, 5) : [];
      if (!ids.length) return null;
      const url = dataciteIDURL(ids);
      if (!url) return null;
      try {
        const match = matchPaper(wanted, await lookupDataCite([url], fetcher, fallback));
        return match ? { status: 'found', paper: { source_id: match.source_id, title: match.title, year: match.year, kind: 'arxiv' } } : null;
      } catch { return null; }
    })();
    const hit = await new Promise<FindResult | null>(resolve => {
      let pending = 2;
      for (const attempt of [byTitle, byWeb]) attempt.then(found => { if (found) resolve(found); else if (--pending === 0) resolve(null); }, () => { if (--pending === 0) resolve(null); });
    });
    if (hit) return hit;
    if (closed) return closed;
    return { status: answered && !signal.aborted ? 'not_found' : 'unavailable' };
  }

  async function importPaper(paper: FoundPaper, signal: AbortSignal): Promise<'added' | 'present' | 'failed'> {
    // The caller's own library command, as the reader (their token). The database decides under the library locks
    // whether the reader already has the paper (an active or source-only import, or a visible item), so a finished
    // paper or a retried request never queues a second import (migration 120, review A5).
    if (signal.aborted) return 'failed';
    const { data, error } = await user.rpc('v2_add_paper_once', { p_operation_id: await serverAddOperationID(options.requestID, paper),
      p_source_id: paper.source_id, p_web: paper.kind === 'web' }).abortSignal(signal);
    const status = error ? null : (data as { result?: { status?: unknown } } | null)?.result?.status;
    return status === 'applied' ? 'added' : status === 'present' ? 'present' : 'failed';
  }
  return { findPaper, importPaper };
}

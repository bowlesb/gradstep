// Finding a cited paper and adding it to a reader's library: shared by Ingest in chat
// (the model names the paper) and the direct "Add to library" on a reference (no model).
// Strict matches only: arXiv first by id, then OpenAlex (arXiv copies, open-access PDFs),
// then arXiv's title search and a scholarly web search in parallel (capped at 15 s).
import type { SupabaseClient } from '@supabase/supabase-js';
import type { FindResult, FoundPaper, PaperRequest } from './chat.ts';
import { arxivTitleURLs, matchPaper, searchArxiv, type DiscoveryResult, openAlexCandidates, openAlexFindURL } from './discover.ts';
import { publicHTTPS } from './web-source.ts';
import { tavilySearch } from './tavily.ts';

export function paperFinder(service: SupabaseClient, user: SupabaseClient, tavilyKey: string | undefined) {
  async function findPaper(wanted: PaperRequest, signal: AbortSignal, { web }: { web: boolean }): Promise<FindResult> {
    // One paced request at a time, stopping at the first clear match. A
    // failed query does not hide the others; all failing is "unavailable".
    const slot = async (slots: number) => {
      const { data, error } = await service.rpc('worker_pipeline_arxiv_slot', { p_slots: slots, p_max_wait_ms: 10_000 });
      if (error) throw new Error('search_busy');
      return data;
    };
    const seen: DiscoveryResult[] = [];
    let answered = false, closed: FindResult | null = null;
    // OpenAlex first, in parallel: it answers in about a second and knows a paper's other
    // versions (an arXiv copy under a conference title; open-access PDFs elsewhere), under
    // the same strict match. arXiv's own paced title search is the slower fallback.
    const openAlex = (async (): Promise<FindResult | null> => {
      const find = openAlexFindURL(wanted);
      if (!find) return null;
      try {
        const response = await fetch(find, { redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
          headers: { accept: 'application/json', 'user-agent': 'Gradstep/0.1 (research paper reader)' } });
        if (!response.ok) { void response.body?.cancel().catch(() => {}); return null; }
        answered = true;
        // A paper's preprint and journal versions are often separate works: prefer one
        // with an arXiv copy, then one with an open-access PDF.
        const candidates = openAlexCandidates(await response.json());
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
    const urls = arxivTitleURLs(wanted.title, wanted.arxivID);
    const arxiv = async (url: string, within: AbortSignal): Promise<FindResult | null> => {
      if (within.aborted) return null;
      try { seen.push(...await searchArxiv([url], fetch, slot, within)); answered = true; } catch { return null; }
      const match = matchPaper(wanted, seen);
      return match ? { status: 'found', paper: { source_id: match.source_id, title: match.title, year: match.year } } : null;
    };
    // An arXiv id in the citation is checked directly (one paced request).
    if (urls.length && new URL(urls[0]).searchParams.has('id_list')) {
      const byID = await arxiv(urls.shift()!, signal);
      if (byID) return byID;
    }
    const viaOpenAlex = await openAlex;
    if (viaOpenAlex) return viaOpenAlex;
    // Fallbacks, in parallel and capped at 15 s so "not found" is said promptly: arXiv's own
    // (paced, slow) title search, and a scholarly web search (Tavily) for an arXiv copy under
    // another title. Both accept only the same strict match.
    const fallback = AbortSignal.any([signal, AbortSignal.timeout(15_000)]);
    const byTitle = (async (): Promise<FindResult | null> => {
      for (const url of urls) { const found = await arxiv(url, fallback); if (found) return found; if (fallback.aborted) break; }
      return null;
    })();
    const byWeb = (async (): Promise<FindResult | null> => {
      if (!tavilyKey) return null;
      const query = `${wanted.title}${wanted.firstAuthor ? ` ${wanted.firstAuthor}` : ''} arXiv`;
      const searched = await tavilySearch(fetch, tavilyKey, { query, academic: true }, fallback).catch(() => null);
      const ids = searched?.status === 'ok'
        ? [...new Set(searched.results.flatMap(r => /arxiv\.org\/(?:abs|pdf)\/(\d{4}\.\d{4,5})/.exec(r.url)?.[1] ?? []))].slice(0, 5) : [];
      if (!ids.length) return null;
      const url = `https://export.arxiv.org/api/query?${new URLSearchParams({ id_list: ids.join(','), max_results: String(ids.length) })}`;
      try {
        const match = matchPaper(wanted, await searchArxiv([url], fetch, slot, fallback));
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
    // The caller's own library command, exactly like the app's Add. Skip
    // papers already present or still importing (bounded look-up).
    const sourceID = paper.source_id;
    let cursor: unknown = null, head: unknown = null;
    for (let page = 0; page < 3; page++) {
      const { data, error } = await user.rpc('v3_library_page', { p_cursor: cursor, p_limit: 100 }).abortSignal(signal);
      if (error || typeof data?.baseline_cursor !== 'number') return 'failed';
      head ??= data.baseline_cursor;
      const entries: { kind?: string; source_id?: string; visible?: boolean; phase?: string }[] = Array.isArray(data.entries) ? data.entries : [];
      if (entries.some(e => e.source_id === sourceID && e.visible && (e.kind === 'item' || ['accepted', 'resolving', 'acquiring'].includes(e.phase ?? '')))) return 'present';
      if (!data.has_more || !data.next_cursor) break;
      cursor = data.next_cursor;
    }
    if (signal.aborted) return 'failed';
    const { data, error } = await user.rpc(paper.kind === 'web' ? 'v2_begin_web_import' : 'v2_begin_import',
      { p_operation_id: crypto.randomUUID(), p_source_id: sourceID, p_observed_cursor: head }).abortSignal(signal);
    return !error && data?.result?.status === 'applied' ? 'added' : 'failed';
  }
  return { findPaper, importPaper };
}

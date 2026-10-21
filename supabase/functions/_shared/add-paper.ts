// The Add sheet's "any identifier or link" (functions/v1/add-paper): identify what the reader typed
// (identify.ts; a reference goes through add-reference's resolution), then queue an arXiv or
// open-access paper as the reader's own import, exactly like the app's Add (no credits here;
// conversion is metered by the pipeline). Anything our servers can't fetch comes back with the
// next step the app offers: upload the PDF (`closed`), or download it on the reader's device
// (`blocked`, `link_only`).
import type { FindResult, FoundPaper } from './chat.ts';
import { parseAddInput, resolveDOI, resolveLink, type AddResolution, type AddRoute, type IdentifyDeps } from './identify.ts';
import { resolveReference } from './reference.ts';

export type AddStatus = 'added' | 'present' | 'closed' | 'blocked' | 'link_only' | 'not_found' | 'needs_update' | 'unavailable' | 'invalid' | 'failed';
export interface AddPaperResponse {
  status: AddStatus;
  route: AddRoute;
  paper: { title: string; year: number | null; source_id: string; kind: 'arxiv' | 'web'; host: string | null; link: string | null } | null;
  /** `blocked` / `link_only` / `closed`: what the reader's device can fetch (a PDF or the page declaring one). */
  link: string | null;
  /** `blocked`: why our servers couldn't use the link (`source_blocked`, `pdf_restricted`, `source_unavailable`). */
  reason: string | null;
  /** `link_only`: the page's title, for an upload of an unidentified PDF. */
  title: string | null;
}

export interface AddPaperDeps extends IdentifyDeps {
  importPaper(paper: FoundPaper, signal: AbortSignal): Promise<'added' | 'present' | 'failed'>;
}

const httpsLink = (value: string | null | undefined) => value && /^https:\/\/[!-~]{1,2000}$/.test(value) ? value : null;

function present(paper: FoundPaper | null) {
  return paper ? { title: paper.title, year: paper.year, source_id: paper.source_id, kind: paper.kind ?? 'arxiv', host: paper.host ?? null,
    link: httpsLink(paper.link) } : null;
}

/** Never throws for a source's behaviour: `unavailable` when nothing could be consulted in time. */
export async function addPaper(deps: AddPaperDeps, raw: string, web: boolean, signal: AbortSignal): Promise<AddPaperResponse> {
  const input = parseAddInput(raw);
  const base = { link: null, reason: null, title: null };
  if (!input) return { status: 'invalid', route: 'none', paper: null, ...base };
  let resolved: { result: AddResolution; route: AddRoute };
  try {
    switch (input.kind) {
      case 'arxiv':
        resolved = { route: 'arxiv_id', result: { status: 'found', paper: { source_id: input.sourceID, title: `arXiv ${input.sourceID}`, year: null, kind: 'arxiv' } } };
        break;
      case 'doi': resolved = { route: 'doi', result: await resolveDOI(deps, input.doi, web, signal) }; break;
      case 'url': resolved = await resolveLink(deps, input.url, web, signal); break;
      case 'text': {
        const reference = await resolveReference({ fetch: deps.fetch, findPaper: deps.findPaper, openAlex: deps.openAlex }, input.text, web, signal);
        resolved = { route: reference.route === 'none' ? 'none' : 'reference', result: reference.result };
        break;
      }
    }
  } catch { resolved = { route: 'none', result: { status: 'unavailable' } }; }
  if (signal.aborted && resolved.result.status !== 'blocked' && resolved.result.status !== 'link_only') {
    return { status: 'unavailable', route: resolved.route, paper: null, ...base };
  }
  const result = resolved.result;
  switch (result.status) {
    case 'found': {
      const status = await deps.importPaper(result.paper, signal).catch(() => 'failed' as const);
      return { status, route: resolved.route, paper: present(result.paper), ...base };
    }
    case 'closed': return { status: 'closed', route: resolved.route, paper: present(result.paper), ...base, link: httpsLink(result.paper.link) };
    case 'needs_update': return { status: 'needs_update', route: resolved.route, paper: present(result.paper), ...base };
    case 'blocked': return { status: 'blocked', route: resolved.route, paper: null, link: httpsLink(result.link), reason: result.reason, title: result.title };
    case 'link_only': return { status: 'link_only', route: resolved.route, paper: null, link: httpsLink(result.link), reason: null, title: result.title };
    default: return { status: (result as FindResult).status === 'not_found' ? 'not_found' : 'unavailable', route: resolved.route, paper: null, ...base };
  }
}

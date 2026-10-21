// Add a paper by any identifier or link (owner, 2026-10-07: "adding a pdf needs to be absolutely
// bullet proof"). The Add sheet sends what the reader typed or pasted: an arXiv ID or link, a DOI,
// any web link (a landing page or a PDF), or a reference. This module says which paper it names and
// where an open copy is, without a model: arXiv by ID, a DOI through Crossref (OpenAlex first only while the owner's
// `openalex_enabled` switch is on; off since migration 075), a link through the DOI or arXiv ID in it, known proceedings hosts, and
// the page's own citation tags. Every fetch of a reader-supplied link uses the web import's checks
// (https on a public name, every redirect hop re-resolved, private addresses refused, bounded).
// When the paper can't be fetched by our servers the result says what the reader's own device
// can try (`blocked`, `link_only`, `closed` with a link). Deno and Node compatible.
import type { FindResult, FoundPaper, PaperRequest } from './chat.ts';
import { arxivReference } from './arxiv.ts';
import { isArxivHost } from './egress.ts';
import { openAlexCandidates, type OpenAlexCandidate } from './discover.ts';
import { checkHost, declaredURL, landingPagePDF, publicHTTPS, refusal, WEB_USER_AGENT, type ResolveHost } from './web-source.ts';
import { readJSONCapped } from './bounded-json.ts';

const MAILTO = 'hello@gradstep.ai';
/** What a reader may type: bounded like a reference. */
export const MAX_INPUT_CHARS = 2_000;

export type AddInput =
  | { kind: 'arxiv'; sourceID: string; revision: number | null }
  | { kind: 'doi'; doi: string }
  | { kind: 'url'; url: URL }
  | { kind: 'text'; text: string };

const DOI = /^10\.\d{4,9}\/[^\s"<>]+$/i;
const trimDOI = (value: string) => value.replace(/[.,;:)\]}>"']+$/, '').toLowerCase();

/** A DOI written as `10.…`, `doi:10.…` or a doi.org link (percent-encoded or not). */
export function doiOf(text: string): string | null {
  let value = text.trim().replace(/^doi:\s*/i, '');
  const link = /^https?:\/\/(?:dx\.)?doi\.org\/(.+)$/i.exec(value);
  if (link) { try { value = decodeURIComponent(link[1]); } catch { return null; } }
  value = trimDOI(value);
  return DOI.test(value) && value.length <= 256 ? value : null;
}

/** What the reader typed: an arXiv ID or link, a DOI, a web link, or other text (a reference). */
export function parseAddInput(raw: string): AddInput | null {
  const text = raw.normalize('NFKC').replace(/\s+/g, ' ').trim();
  if (!text || [...text].length > MAX_INPUT_CHARS || /\p{Cc}/u.test(text)) return null;
  try { const ref = arxivReference(text); return { kind: 'arxiv', sourceID: ref.sourceID, revision: ref.revision }; } catch { /* not arXiv */ }
  const doi = doiOf(text);
  // arXiv's own DOI (DataCite registers 10.48550/arXiv.<id> for every paper) names the paper outright.
  const arxivDOI = doi ? /^10\.48550\/arxiv\.(.+)$/.exec(doi)?.[1] : undefined;
  if (arxivDOI) { try { const ref = arxivReference(arxivDOI); return { kind: 'arxiv', sourceID: ref.sourceID, revision: ref.revision }; } catch { /* not an arXiv identifier */ } }
  if (doi) return { kind: 'doi', doi };
  if (/^(https?:\/\/|www\.)\S+$/i.test(text)) {
    // A link is fetched over https only; http is upgraded (never fetched in the clear).
    const url = publicHTTPS(text.replace(/^http:\/\//i, 'https://').replace(/^www\./i, 'https://www.'), 2000);
    return url ? { kind: 'url', url } : null;
  }
  // Another scheme (ftp:, file:, javascript:) is never fetched or searched for.
  if (/^[a-z][a-z0-9+.-]{1,20}:\/\//i.test(text)) return null;
  return text.length >= 8 ? { kind: 'text', text } : null;
}

/** A DOI in a link's path (publisher and repository URLs commonly carry it). */
export function doiInURL(url: URL): string | null {
  if (/(^|\.)doi\.org$/.test(url.hostname)) return doiOf(url.href);
  let path: string;
  try { path = decodeURIComponent(url.pathname); } catch { return null; }
  // /doi/10.…, /doi/abs/10.…, /doi/full/10.…, /doi/pdf/10.…, /article/10.…, /chapter/10.…
  const match = /\/(?:doi(?:\/(?:abs|full|pdf|epdf|book|reader))?|article|chapter|content)\/(10\.\d{4,9}\/[^?#\s]+)/i.exec(path);
  if (match) {
    const doi = trimDOI(match[1].replace(/\.pdf$/i, '').replace(/\/(?:pdf|full|abstract|fulltext\.html)$/i, ''));
    return DOI.test(doi) ? doi : null;
  }
  // nature.com/articles/<suffix> → 10.1038/<suffix>
  const nature = /^\/articles\/([a-z]{1,8}\d[\w.-]{2,60})$/i.exec(url.pathname);
  if (/(^|\.)nature\.com$/.test(url.hostname) && nature) return `10.1038/${nature[1].replace(/\.pdf$/i, '').toLowerCase()}`;
  return null;
}

/** An arXiv link anywhere in a URL (an arXiv page, or a redirect to one): its abstract, PDF or HTML page. */
export function arxivInURL(url: URL): { sourceID: string; revision: number | null } | null {
  if (!isArxivHost(url.hostname)) return null;
  // The HTML page (`/html/<id>v<n>/`) names the same paper as its abstract page.
  const html = /^\/html\/([^/?#]+?)\/?$/.exec(url.pathname);
  const href = html ? `https://arxiv.org/abs/${html[1]}` : url.href.replace(/^http:/, 'https:'); // egress-ok: parse
  try { return arxivReference(href); } catch { return null; }
}

/** The landing page of a proceedings PDF, whose citation tags name the paper. */
export function landingForPDF(url: URL): URL | null {
  const host = url.hostname, path = url.pathname;
  const build = (value: string) => publicHTTPS(value);
  let m: RegExpExecArray | null;
  if (/(^|\.)(neurips|nips)\.cc$/.test(host) && (m = /^(.*\/paper(?:_files\/paper)?\/\d{4})\/file\/([0-9a-f]{16,64})-(?:Paper|Supplemental)(-Conference|-Datasets_and_Benchmarks(?:_Track)?)?\.pdf$/i.exec(path))) {
    return build(`https://${host}${m[1]}/hash/${m[2]}-Abstract${m[3] ?? ''}.html`);
  }
  if (host === 'proceedings.mlr.press' && (m = /^\/(v\d{1,4})\/([\w-]{1,120})(?:\/\2)?\.pdf$/.exec(path))) return build(`https://${host}/${m[1]}/${m[2]}.html`);
  if (host === 'aclanthology.org' && (m = /^\/([\w.-]{3,80})\.pdf$/.exec(path))) return build(`https://${host}/${m[1]}/`);
  if (host === 'openaccess.thecvf.com' && (m = /^\/(content.*)\/papers\/([\w.-]{1,200})_paper\.pdf$/.exec(path))) return build(`https://${host}/${m[1]}/html/${m[2]}_paper.html`);
  if (/(^|\.)jmlr\.org$/.test(host) && (m = /^\/papers\/volume(\d{1,3})\/([\w.-]{1,80})\/\2\.pdf$/.exec(path))) return build(`https://${host}/papers/v${m[1]}/${m[2]}.html`);
  if (host === 'openreview.net' && path === '/pdf' && url.searchParams.get('id')) {
    return build(`https://openreview.net/forum?id=${encodeURIComponent(url.searchParams.get('id')!)}`);
  }
  if (host === 'ojs.aaai.org' && (m = /^(\/index\.php\/\w+\/article)\/download\/(\d+)(?:\/\d+)?$/.exec(path))) return build(`https://${host}${m[1]}/view/${m[2]}`);
  return null;
}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '–', mdash: '—', rsquo: '’', lsquo: '‘', rdquo: '”', ldquo: '“' };
/** Page text: entities decoded, control characters and runs of space folded. */
export function pageText(value: string, maximum = 400): string | null {
  const text = value.replace(/&(#x[0-9a-f]{1,6}|#\d{1,7}|[a-z]{2,8});/gi, (whole, name: string) => {
    if (name[0] === '#') {
      const code = name[1] === 'x' || name[1] === 'X' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return Number.isFinite(code) && code > 31 && code < 0x110000 ? String.fromCodePoint(code) : ' ';
    }
    return ENTITIES[name.toLowerCase()] ?? whole;
  }).replace(/<[^>]*>/g, ' ').replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim();
  return text ? [...text].slice(0, maximum).join('').trim() : null;
}

export interface PageFacts { doi: string | null; title: string | null; arxiv: { sourceID: string; revision: number | null } | null; pdfURL: URL | null }

/** What a landing page says about its paper: Highwire/Dublin Core/PRISM tags (`citation_doi`,
 * `citation_title`, `citation_arxiv_id`, `citation_pdf_url`, `dc.identifier`, `prism.doi`), else
 * its Open Graph or `<title>`. */
export function pageFacts(html: string, base: URL): PageFacts {
  const tags = html.match(/<meta\b[^>]*>/gi) ?? [];
  const attribute = (tag: string, name: string) => {
    const match = new RegExp(`[\\s"'/]${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=<>\`]+))`, 'i').exec(tag);
    return match?.slice(1).find(v => v !== undefined) ?? null;
  };
  const named = new Map<string, string>();
  for (const tag of tags) {
    const name = (attribute(tag, 'name') ?? attribute(tag, 'property') ?? '').toLowerCase();
    const content = attribute(tag, 'content');
    if (name && content && !named.has(name)) named.set(name, content);
  }
  let doi: string | null = null;
  for (const key of ['citation_doi', 'prism.doi', 'bepress_citation_doi', 'dc.identifier', 'dc.identifier.doi']) {
    const value = named.get(key);
    if (value && (doi = doiOf(pageText(value, 300) ?? ''))) break;
  }
  let arxiv: PageFacts['arxiv'] = null;
  const arxivID = named.get('citation_arxiv_id');
  if (arxivID) { try { arxiv = arxivReference(arxivID.trim()); } catch { arxiv = null; } }
  const rawTitle = named.get('citation_title') ?? named.get('dc.title') ?? named.get('og:title')
    ?? /<title[^>]*>([\s\S]{1,600}?)<\/title>/i.exec(html)?.[1] ?? null;
  const title = rawTitle ? pageText(rawTitle) : null;
  return { doi, title: title && title.length >= 4 ? title : null, arxiv, pdfURL: landingPagePDF(html, base) };
}

export type Probe =
  | { kind: 'pdf'; url: URL }
  | { kind: 'page'; url: URL; html: string }
  | { kind: 'arxiv'; sourceID: string; revision: number | null }
  | { kind: 'refused'; url: URL; code: 'pdf_restricted' | 'source_blocked' | 'not_pdf' | 'download_failed' | 'source_unavailable' };

const PAGE_BYTES = 1_500_000;

/** Fetches a reader-supplied link far enough to know what it is: a PDF (only its first bytes are
 * read), a web page (bounded), a redirect to arXiv, or a refusal and why. Every hop is checked
 * like a web import download. Never throws for the site's behaviour; throws on `signal`. */
export async function probeLink(fetcher: typeof fetch, start: URL, resolve: ResolveHost | undefined, signal: AbortSignal): Promise<Probe> {
  let current: URL | null = publicHTTPS(start, 2000);
  for (let hop = 0; hop < 7; hop++) {
    if (!current) return { kind: 'refused', url: start, code: 'download_failed' };
    const arxiv = arxivInURL(current);
    if (arxiv) return { kind: 'arxiv', ...arxiv };
    // Our servers never contact arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md): an arXiv page naming no paper, or a
    // redirect to one, is not followed.
    if (isArxivHost(current.hostname)) return { kind: 'refused', url: current, code: 'download_failed' };
    try { await checkHost(current, resolve); }
    catch { return { kind: 'refused', url: current, code: 'download_failed' }; }
    let response: Response;
    try {
      response = await fetcher(current.href, { redirect: 'manual', headers: { accept: 'text/html, application/pdf;q=0.9, */*;q=0.5', 'user-agent': WEB_USER_AGENT },
        signal: AbortSignal.any([signal, AbortSignal.timeout(12_000)]) });
    } catch (error) {
      if (signal.aborted) throw error;
      return { kind: 'refused', url: current, code: 'source_unavailable' };
    }
    const drop = () => void response.body?.cancel().catch(() => {});
    // DNS rebinding (review A24): fetch resolves the name again, and the runtime offers no way to pin the address it
    // connects to. Resolve once more now that the answer has arrived; unless every address is still public, the hop is
    // refused before its body, headers or redirect are used. This narrows the window (a name that turned private after
    // our first check) but cannot prove where fetch connected (docs/architecture/PDF_UPLOADS.md §1, residual risk).
    try { await checkHost(current, resolve); }
    catch { drop(); return { kind: 'refused', url: current, code: 'download_failed' }; }
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); drop();
      current = location ? declaredURL(location, current, false, 4096) : null; continue;
    }
    if (response.status === 429 || response.status >= 500) { drop(); return { kind: 'refused', url: current, code: 'source_unavailable' }; }
    if (response.headers.get('cf-mitigated') === 'challenge' || response.headers.has('x-amzn-waf-action')) { drop(); return { kind: 'refused', url: current, code: 'source_blocked' }; }
    if (response.status === 404 || response.status === 410) { drop(); return { kind: 'refused', url: current, code: 'download_failed' }; }
    const body = response.body ? await readHead(response.body, response.status >= 400 ? 256 * 1024 : PAGE_BYTES).catch(() => null) : null;
    if (response.status >= 400) return { kind: 'refused', url: current, code: refusal(body?.kind === 'page' ? body.html : '', current, response.status) };
    if (response.status !== 200 || !body) return { kind: 'refused', url: current, code: 'download_failed' };
    if (body.kind === 'pdf') return { kind: 'pdf', url: current };
    if (body.kind === 'other') return { kind: 'refused', url: current, code: 'not_pdf' };
    // A bot check served with 200 (Cloudflare, Turnstile) says so in the page.
    const why = refusal(body.html, current, 200);
    if (why === 'source_blocked' || why === 'pdf_restricted') {
      // A refusal page can still be a real landing page that mentions a sign-in; trust it when it names its paper.
      const facts = pageFacts(body.html, current);
      if (!facts.doi && !facts.arxiv && !facts.pdfURL) return { kind: 'refused', url: current, code: why };
    }
    return { kind: 'page', url: current, html: body.html };
  }
  return { kind: 'refused', url: start, code: 'download_failed' };
}

/** The first bytes of a body: a PDF is recognised and the rest never read; a page is read up to `pageBytes`. */
async function readHead(body: ReadableStream<Uint8Array>, pageBytes: number): Promise<{ kind: 'pdf' } | { kind: 'page'; html: string } | { kind: 'other' }> {
  const reader = body.getReader(); const parts: Uint8Array[] = []; let size = 0;
  const text = (limit: number) => {
    const bytes = new Uint8Array(Math.min(size, limit)); let offset = 0;
    for (const part of parts) { if (offset >= bytes.length) break; const take = part.subarray(0, bytes.length - offset); bytes.set(take, offset); offset += take.length; }
    return new TextDecoder().decode(bytes);
  };
  try {
    while (size < pageBytes) {
      const { done, value } = await reader.read();
      if (done) break;
      parts.push(value); size += value.byteLength;
      const head = text(512);
      if (head.startsWith('%PDF-')) return { kind: 'pdf' };
      const rest = head.replace(/^﻿/, '').trimStart();
      if (rest && !rest.startsWith('<') && (rest.length >= 5 || size >= 512)) return { kind: 'other' };
    }
  } finally { void reader.cancel().catch(() => {}); }
  const head = text(512).replace(/^﻿/, '').trimStart();
  if (head.startsWith('%PDF-')) return { kind: 'pdf' };
  return head.startsWith('<') ? { kind: 'page', html: text(pageBytes) } : { kind: 'other' };
}

export type AddRoute = 'arxiv_id' | 'doi' | 'link' | 'page' | 'title' | 'reference' | 'none';
/** The outcome before any import: the paper found (arXiv or an open copy), a closed paper, or for a
 * link our servers can't use, what the reader's device can fetch (`link`) and why. */
export type AddResolution =
  | FindResult
  | { status: 'blocked'; reason: 'source_blocked' | 'pdf_restricted' | 'source_unavailable'; link: string; title: string | null }
  | { status: 'link_only'; link: string; title: string | null };

export interface IdentifyDeps {
  fetch: typeof fetch;
  resolveHost?: ResolveHost;
  findPaper: (wanted: PaperRequest, signal: AbortSignal, options: { web: boolean }) => Promise<FindResult>;
  /** `pipeline_policy.openalex_enabled` (migration 072; off since 075). Only an explicit `true` asks OpenAlex; absent or
   * unreadable is off, and a DOI is named by Crossref alone (fail closed, review A15). */
  openAlex?: boolean;
}

const JSON_HEADERS = { accept: 'application/json', 'user-agent': `Gradstep/0.1 (research paper reader; mailto:${MAILTO})` };
async function getJSON(fetcher: typeof fetch, url: string, signal: AbortSignal): Promise<{ ok: true; json: unknown } | { ok: false; missing: boolean }> {
  try {
    const response = await fetcher(url, { headers: JSON_HEADERS, redirect: 'follow', signal: AbortSignal.any([signal, AbortSignal.timeout(8_000)]) });
    if (!response.ok) { void response.body?.cancel().catch(() => {}); return { ok: false, missing: response.status === 404 }; }
    // A full Crossref work (its reference list included) can reach a few hundred kilobytes; 4 MiB bounds it (review A24).
    return { ok: true, json: await readJSONCapped(response, 4 * 1024 * 1024) };
  } catch { return { ok: false, missing: false }; }
}

const openPDF = (url: string | null) => {
  const open = url ? publicHTTPS(url.replace(/^http:\/\//i, 'https://')) : null;
  return open && !/(^|\.)arxiv\.org$/.test(open.hostname) ? open : null;
};

/** OpenAlex's candidate as a result: its arXiv copy, an open copy, or closed (with its landing page). */
function fromCandidate(candidate: OpenAlexCandidate, web: boolean): FindResult {
  if (candidate.arxivID) return { status: 'found', paper: { source_id: candidate.arxivID, title: candidate.title, year: candidate.year, kind: 'arxiv' } };
  const open = openPDF(candidate.pdfURL);
  const paper: FoundPaper = { source_id: `openalex:${candidate.openalexID}`, title: candidate.title, year: candidate.year, kind: 'web',
    host: open?.hostname ?? null, link: candidate.landingURL ?? (candidate.doi ? `https://doi.org/${candidate.doi}` : null) };
  return open ? { status: web ? 'found' : 'needs_update', paper } : { status: 'closed', paper };
}

/** A DOI: with OpenAlex on (`deps.openAlex === true`), OpenAlex's work (arXiv copy, open copy or closed); otherwise, and
 * for a DOI OpenAlex doesn't know, Crossref names it and the finder searches by title (preprints often have no DOI
 * link); else closed under its DOI. */
export async function resolveDOI(deps: IdentifyDeps, doi: string, web: boolean, signal: AbortSignal): Promise<FindResult> {
  const select = 'id,doi,title,publication_year,authorships,locations,best_oa_location';
  const work: Awaited<ReturnType<typeof getJSON>> = deps.openAlex !== true ? { ok: false, missing: true }
    : await getJSON(deps.fetch, `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=${select}&mailto=${MAILTO}`, signal);
  if (work.ok) {
    let candidate: OpenAlexCandidate | undefined;
    try { [candidate] = openAlexCandidates({ results: [work.json] }); } catch { candidate = undefined; }
    if (candidate) {
      const result = fromCandidate(candidate, web);
      if (result.status !== 'closed') return result;
      // A journal version without an open copy often has an arXiv preprint under the same title.
      const preprint = await deps.findPaper({ title: candidate.title, year: candidate.year, firstAuthor: candidate.authors[0] ?? null, arxivID: null }, signal, { web })
        .catch((): FindResult => ({ status: 'unavailable' }));
      return preprint.status === 'found' && preprint.paper.kind !== 'web' ? preprint : result;
    }
  }
  const crossref = await getJSON(deps.fetch, `https://api.crossref.org/works/${encodeURIComponent(doi)}?mailto=${MAILTO}`, signal);
  if (!crossref.ok) return (work.ok || work.missing) && crossref.missing ? { status: 'not_found' } : { status: 'unavailable' };
  const message = (crossref.json as { message?: { title?: unknown; subtitle?: unknown; issued?: { 'date-parts'?: unknown }; author?: unknown } })?.message;
  // Crossref keeps a subtitle apart ("Optuna" + "A Next-generation …"); the preprint is titled with both.
  const subtitle = Array.isArray(message?.subtitle) && typeof message.subtitle[0] === 'string' ? message.subtitle[0].trim() : '';
  const title = Array.isArray(message?.title) && typeof message.title[0] === 'string' ? pageText(subtitle ? `${message.title[0]}: ${subtitle}` : message.title[0]) : null;
  if (!title) return { status: 'not_found' };
  const parts = message?.issued?.['date-parts'];
  const year = Array.isArray(parts) && Array.isArray(parts[0]) && Number.isInteger(parts[0][0]) ? parts[0][0] as number : null;
  const first = Array.isArray(message?.author) ? message.author[0] as { family?: unknown } | undefined : undefined;
  const found = await deps.findPaper({ title, year, firstAuthor: typeof first?.family === 'string' ? first.family : null, arxivID: null }, signal, { web })
    .catch((): FindResult => ({ status: 'unavailable' }));
  if (found.status === 'found' || found.status === 'needs_update' || found.status === 'closed') return found;
  return { status: 'closed', paper: { source_id: `doi:${doi}`, title, year, link: `https://doi.org/${doi}` } };
}

/**
 * A web link: the arXiv ID or DOI in it, else the landing page's citation tags (for a proceedings
 * PDF, its known landing page), else the paper the page is titled after. A link that can't be
 * identified but leads to a PDF is `link_only` (the reader's device can fetch it); a site that
 * refuses our servers is `blocked`.
 */
export async function resolveLink(deps: IdentifyDeps, url: URL, web: boolean, signal: AbortSignal): Promise<{ result: AddResolution; route: AddRoute }> {
  const arxiv = arxivInURL(url);
  if (arxiv) return { route: 'arxiv_id', result: { status: 'found', paper: { source_id: arxiv.sourceID, title: `arXiv ${arxiv.sourceID}`, year: null, kind: 'arxiv' } } };
  const named = doiInURL(url);
  let viaDOI: FindResult | null = null;
  if (named) {
    viaDOI = await resolveDOI(deps, named, web, signal);
    if (viaDOI.status === 'found' || viaDOI.status === 'needs_update') return { route: 'doi', result: viaDOI };
  }
  const landing = landingForPDF(url);
  const probe = await probeLink(deps.fetch, landing ?? url, deps.resolveHost, signal);
  if (probe.kind === 'arxiv') return { route: 'link', result: { status: 'found', paper: { source_id: probe.sourceID, title: `arXiv ${probe.sourceID}`, year: null, kind: 'arxiv' } } };
  if (probe.kind === 'refused') {
    if (viaDOI && viaDOI.status === 'closed') return { route: 'doi', result: viaDOI };
    if (probe.code === 'download_failed' || probe.code === 'not_pdf') {
      // A known landing page that isn't there anymore: the PDF link itself may still work.
      return landing ? { route: 'link', result: { status: 'link_only', link: url.href, title: null } } : { route: 'none', result: { status: 'not_found' } };
    }
    return { route: 'link', result: { status: 'blocked', reason: probe.code, link: url.href, title: null } };
  }
  if (probe.kind === 'pdf') {
    if (viaDOI && viaDOI.status === 'closed') return { route: 'doi', result: viaDOI };
    return { route: 'link', result: { status: 'link_only', link: probe.url.href, title: null } };
  }
  const facts = pageFacts(probe.html, probe.url);
  if (facts.arxiv) return { route: 'page', result: { status: 'found', paper: { source_id: facts.arxiv.sourceID, title: facts.title ?? `arXiv ${facts.arxiv.sourceID}`, year: null, kind: 'arxiv' } } };
  const doi = facts.doi && facts.doi !== named ? facts.doi : null;
  if (doi) {
    const found = await resolveDOI(deps, doi, web, signal);
    if (found.status === 'found' || found.status === 'needs_update') return { route: 'page', result: found };
    viaDOI ??= found;
  }
  if (facts.title && !viaDOI) {
    const found = await deps.findPaper({ title: facts.title, year: null, firstAuthor: null, arxivID: null }, signal, { web })
      .catch((): FindResult => ({ status: 'unavailable' }));
    if (found.status === 'found' || found.status === 'needs_update') return { route: 'title', result: found };
    if (found.status === 'closed') viaDOI = found;
  }
  // Not identified as an open paper: the PDF the page declares (or the PDF that was pasted) is still
  // there for the reader's device; a closed paper keeps its identity so an upload attaches to it.
  const pdf = facts.pdfURL ?? (landing ? url : null);
  if (viaDOI && viaDOI.status === 'closed') {
    const paper = { ...viaDOI.paper, link: pdf?.href ?? viaDOI.paper.link ?? probe.url.href };
    return { route: 'page', result: { status: 'closed', paper } };
  }
  if (pdf) return { route: 'page', result: { status: 'link_only', link: pdf.href, title: facts.title } };
  return { route: 'none', result: { status: 'not_found' } };
}

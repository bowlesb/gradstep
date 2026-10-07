// Web imports (migration 019): a paper with no arXiv copy, read from the
// open-access PDF OpenAlex reports for it. OpenAlex is the only source of a web
// paper's metadata and PDF locations; those locations are third-party data, so
// every hop of every download is checked here. Deno and Node compatible.

export const WEB_USER_AGENT = 'ScienceReader/0.1 (research paper reader; mailto:support@sciencereader.invalid)';
const MiB = 1024 * 1024;

/** `permanent`: retrying the same request cannot help (the import fails; a user retry may). */
export class WebSourceError extends Error {
  readonly code: 'metadata_unavailable' | 'download_failed' | 'too_large' | 'rate_limited';
  readonly permanent: boolean;
  constructor(code: WebSourceError['code'], permanent: boolean) { super(code); this.code = code; this.permanent = permanent; }
}

/** Host names resolved before each request (Deno.resolveDns in the worker). */
export type ResolveHost = (host: string) => Promise<string[]>;

const ARXIV_HOSTS = /(^|\.)arxiv\.org$/;
/** Venues that serve their papers' PDFs freely. OpenAlex often labels these locations
 * closed (JMLR, older NeurIPS/PMLR volumes have no DOI for Unpaywall to check). */
const OPEN_VENUES = /(^|\.)(jmlr\.org|jmlr\.csail\.mit\.edu|mlr\.press|nips\.cc|neurips\.cc|icml\.cc|iclr\.cc|thecvf\.com|ecva\.net|bmva\.org|aclanthology\.org|aclweb\.org|openreview\.net|aaai\.org|ijcai\.org|jair\.org|isca-archive\.org|isca-speech\.org|roboticsproceedings\.org)$/;
const LOCAL_NAMES = /(^|\.)(localhost|local|localdomain|internal|intranet|lan|home|corp|arpa|invalid|test|example)$/;

/** https on the default port, a public DNS name (never an IP literal or a local
 * name), no credentials, printable ASCII. Mirrors app_private.web_url_ok. */
export function publicHTTPS(value: string | URL): URL | null {
  let url: URL;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || url.username || url.password || url.port !== '' || url.hash) return null;
  const host = url.hostname.toLowerCase();
  // A letter-only top-level label excludes IPv4 literals (in any notation, once
  // parsed) and IPv6 literals; single-label names are excluded too.
  if (!/^[a-z0-9-]{1,63}(\.[a-z0-9-]{1,63})*\.[a-z]{2,63}$/.test(host) || LOCAL_NAMES.test(host)) return null;
  if (url.href.length > 1000 || !/^[!-~]+$/.test(url.href)) return null;
  return url;
}

function ipv4Public(address: string): boolean {
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some(p => !Number.isInteger(p) || p < 0 || p > 255)) return false;
  const [a, b, c] = parts;
  return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 192 && b === 0 && (c === 0 || c === 2))
    || (a === 192 && b === 88 && c === 99) || (a === 198 && (b === 18 || b === 19)) || (a === 198 && b === 51 && c === 100)
    || (a === 203 && b === 0 && c === 113));
}

/** False for loopback, private, link-local, shared, documentation, multicast and reserved ranges. */
export function isPublicAddress(address: string): boolean {
  const value = address.trim().toLowerCase();
  if (/^\d+\.\d+\.\d+\.\d+$/.test(value)) return ipv4Public(value);
  if (!value.includes(':')) return false;
  const mapped = /^(?:0{0,4}:){0,5}(?:0{0,4}:)?ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(value) ?? /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(value);
  if (mapped) return ipv4Public(mapped[1]);
  if (value === '::' || value === '::1') return false;
  const first = parseInt(value.split(':')[0] || '0', 16);
  if (Number.isNaN(first)) return false;
  // Global unicast only (2000::/3), minus Teredo (2001::/32), documentation (2001:db8::/32) and 6to4 (2002::/16).
  if (first < 0x2000 || first > 0x3fff) return false;
  return !/^2001:0{0,4}:/.test(value) && !/^2001:0?db8:/.test(value) && !/^2002:/.test(value);
}

async function checkHost(url: URL, resolve: ResolveHost | undefined): Promise<void> {
  if (!resolve) return;
  let addresses: string[];
  try { addresses = await resolve(url.hostname); } catch { throw new WebSourceError('download_failed', true); }
  if (!addresses.length || addresses.some(address => !isPublicAddress(address))) throw new WebSourceError('download_failed', true);
}

async function readCapped(body: ReadableStream<Uint8Array>, maximum: number, isPDF: boolean): Promise<Uint8Array> {
  const reader = body.getReader(); const parts: Uint8Array[] = []; let size = 0; let checked = !isPDF;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximum) throw new WebSourceError('too_large', true);
      parts.push(value);
      if (!checked && size >= 5) {
        const head = new Uint8Array(5); let at = 0;
        for (const part of parts) { const take = part.subarray(0, 5 - at); head.set(take, at); at += take.length; if (at === 5) break; }
        // A landing page or bot challenge in place of the PDF: stop reading it.
        if (new TextDecoder().decode(head) !== '%PDF-') throw new WebSourceError('download_failed', true);
        checked = true;
      }
    }
  } catch (error) { void reader.cancel().catch(() => {}); throw error; }
  if (!checked) throw new WebSourceError('download_failed', true);
  const bytes = new Uint8Array(size); let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
  return bytes;
}

/** Landing pages read for their PDF link are capped (Zenodo's record page is ~200 KB). */
const LANDING_PAGE_BYTES = 1_500_000;

/** The PDF a repository landing page declares: `citation_pdf_url` (Highwire tags, used by
 * Zenodo, OpenReview, PMLR, institutional repositories), else a PDF alternate link. */
export function landingPagePDF(html: string, base: URL): URL | null {
  const decode = (value: string) => value.replace(/&amp;/g, '&').replace(/&#x2F;|&#47;/gi, '/').trim();
  const tags = html.match(/<(?:meta|link)\b[^>]*>/gi) ?? [];
  const attribute = (tag: string, name: string) => new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, 'i').exec(tag)?.slice(1).find(v => v !== undefined) ?? null;
  const candidates: string[] = [];
  for (const tag of tags) {
    if (/^<meta/i.test(tag) && attribute(tag, 'name')?.toLowerCase() === 'citation_pdf_url') candidates.unshift(attribute(tag, 'content') ?? '');
    else if (/^<link/i.test(tag) && /\balternate\b/i.test(attribute(tag, 'rel') ?? '') && /application\/pdf/i.test(attribute(tag, 'type') ?? '')) candidates.push(attribute(tag, 'href') ?? '');
  }
  for (const value of candidates) {
    if (!value) continue;
    try { const next = publicHTTPS(new URL(decode(value), base)); if (next) return next; } catch { /* next candidate */ }
  }
  return null;
}

async function readText(body: ReadableStream<Uint8Array>, maximum: number): Promise<string> {
  const reader = body.getReader(); const parts: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximum) throw new WebSourceError('download_failed', true);
      parts.push(value);
    }
  } catch (error) { void reader.cancel().catch(() => {}); throw error; }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
  return new TextDecoder().decode(bytes);
}

/** One download, every redirect hop re-checked (URL and resolved addresses).
 * `budget` bounds the whole download (all hops and the body). A repository landing
 * page in place of the PDF is followed once to the PDF it declares. */
export async function fetchWebPDF(fetcher: typeof fetch, start: string, maximum: number, resolve?: ResolveHost,
  budget: AbortSignal = AbortSignal.timeout(120_000)): Promise<Uint8Array> {
  let current = publicHTTPS(start), followedPage = false;
  for (let hop = 0; hop < 7; hop++) {
    // arXiv copies go through the arXiv path (and its pacing), never a web redirect.
    if (!current || ARXIV_HOSTS.test(current.hostname)) throw new WebSourceError('download_failed', true);
    if (budget.aborted) throw new WebSourceError('download_failed', false);
    await checkHost(current, resolve);
    let response: Response;
    try {
      response = await fetcher(current.href, { redirect: 'manual', headers: { accept: 'application/pdf, text/html;q=0.8, */*;q=0.5', 'user-agent': WEB_USER_AGENT },
        signal: AbortSignal.any([budget, AbortSignal.timeout(60_000)]) });
    } catch { throw new WebSourceError('download_failed', false); }
    const drop = () => void response.body?.cancel().catch(() => {});
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); drop();
      let next: URL | null = null;
      try { next = location ? publicHTTPS(new URL(location, current)) : null; } catch { next = null; }
      current = next; continue;
    }
    if (response.status === 429 || response.status >= 500) { drop(); throw new WebSourceError('rate_limited', false); }
    if (response.status !== 200 || !response.body) { drop(); throw new WebSourceError('download_failed', true); }
    if (/^\s*text\/html/i.test(response.headers.get('content-type') ?? '')) {
      if (followedPage) { drop(); throw new WebSourceError('download_failed', true); }
      let html: string;
      try { html = await readText(response.body, LANDING_PAGE_BYTES); }
      catch (error) { throw error instanceof WebSourceError ? error : new WebSourceError('download_failed', false); }
      const next = landingPagePDF(html, current);
      if (!next) throw new WebSourceError('download_failed', true);
      followedPage = true; current = next; continue;
    }
    const declared = response.headers.get('content-length');
    if (declared && Number(declared) > maximum) { drop(); throw new WebSourceError('too_large', true); }
    // A reset or timeout mid-body is transient: the next location (or a later attempt) may work.
    try { return await readCapped(response.body, maximum, true); }
    catch (error) { throw error instanceof WebSourceError ? error : new WebSourceError('download_failed', false); }
  }
  throw new WebSourceError('download_failed', true);
}

/** Tries each location in order within one overall budget. Fails permanently only
 * if every location did; running out of budget is transient. */
export async function fetchFirstWebPDF(fetcher: typeof fetch, urls: readonly string[], maximum: number, resolve?: ResolveHost,
  budget: AbortSignal = AbortSignal.timeout(120_000)): Promise<{ bytes: Uint8Array; url: string }> {
  let transient: WebSourceError | null = null, tooLarge = false;
  for (const url of urls.slice(0, 3)) {
    if (budget.aborted) { transient ??= new WebSourceError('download_failed', false); break; }
    try { return { bytes: await fetchWebPDF(fetcher, url, maximum, resolve, budget), url }; }
    catch (error) {
      if (!(error instanceof WebSourceError)) throw error;
      if (!error.permanent) transient ??= error;
      if (error.code === 'too_large') tooLarge = true;
    }
  }
  if (transient) throw transient;
  throw new WebSourceError(tooLarge ? 'too_large' : 'download_failed', true);
}

/** The OpenAlex work behind a web source ID (`openalex:W…`). */
export function openAlexWorkURL(sourceID: string): string {
  const work = /^openalex:(W[1-9]\d{0,14})$/.exec(sourceID)?.[1];
  if (!work) throw new WebSourceError('metadata_unavailable', true);
  const url = new URL(`https://api.openalex.org/works/${work}`);
  url.search = new URLSearchParams({ select: 'id,doi,title,display_name,publication_date,authorships,abstract_inverted_index,primary_location,best_oa_location,locations' }).toString();
  return url.href;
}

/** Bounded JSON from api.openalex.org only (merged works redirect within it). */
export async function fetchOpenAlexWork(fetcher: typeof fetch, url: string): Promise<unknown> {
  let current = new URL(url);
  for (let hop = 0; hop < 3; hop++) {
    if (current.protocol !== 'https:' || current.hostname !== 'api.openalex.org' || current.port !== '') throw new WebSourceError('metadata_unavailable', true);
    let response: Response;
    try {
      response = await fetcher(current.href, { redirect: 'manual', headers: { accept: 'application/json', 'user-agent': WEB_USER_AGENT },
        signal: AbortSignal.timeout(20_000) });
    } catch { throw new WebSourceError('metadata_unavailable', false); }
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); void response.body?.cancel().catch(() => {});
      if (!location) throw new WebSourceError('metadata_unavailable', true);
      current = new URL(location, current); continue;
    }
    if (response.status === 404) { void response.body?.cancel().catch(() => {}); throw new WebSourceError('metadata_unavailable', true); }
    if (response.status !== 200 || !response.body) { void response.body?.cancel().catch(() => {}); throw new WebSourceError('metadata_unavailable', false); }
    const bytes = await readCapped(response.body, 2 * MiB, false).catch(() => { throw new WebSourceError('metadata_unavailable', false); });
    try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new WebSourceError('metadata_unavailable', false); }
  }
  throw new WebSourceError('metadata_unavailable', true);
}

/** A work's PDF locations worth trying, best first (at most three): OpenAlex's best
 * open-access location, PDFs on open venues, then other open-access copies. Never
 * arXiv-hosted (arXiv copies use the arXiv path); http links are tried over https.
 * A closed location that slips through fails safely (login pages are refused). */
export function openPDFLocations(work: unknown): string[] {
  if (!work || typeof work !== 'object') return [];
  type Location = { pdf_url?: unknown; landing_page_url?: unknown; is_oa?: unknown } | null;
  const w = work as { best_oa_location?: unknown; locations?: unknown };
  const best = (w.best_oa_location && typeof w.best_oa_location === 'object' ? w.best_oa_location : null) as Location;
  const all = (Array.isArray(w.locations) ? w.locations.slice(0, 50) : []) as Location[];
  // Some locations (e.g. JMLR) give the PDF itself as the landing page and no pdf_url.
  const url = (location: Location) => {
    const raw = typeof location?.pdf_url === 'string' ? location.pdf_url
      : typeof location?.landing_page_url === 'string' && /^[^?#]+\.pdf(?:[?#]|$)/i.test(location.landing_page_url) ? location.landing_page_url : null;
    return raw ? publicHTTPS(raw.replace(/^http:\/\//i, 'https://')) : null;
  };
  const ordered = [url(best), ...all.map(url).filter(u => u && OPEN_VENUES.test(u.hostname)), ...all.filter(l => l?.is_oa === true).map(url)];
  const result: string[] = [];
  for (const candidate of ordered) {
    if (candidate && !ARXIV_HOSTS.test(candidate.hostname) && !result.includes(candidate.href)) result.push(candidate.href);
    if (result.length === 3) break;
  }
  return result;
}

export interface WebWork {
  metadata: { title: string; authors: string[]; abstract: string | null; published_at: string | null; updated_at: null; categories: string[]; venue: string | null };
  doi: string | null;
  /** Open-access PDF locations, best first, never on arXiv (arXiv copies use the arXiv path). */
  pdfURLs: string[];
  landingURL: string | null;
}

/** Third-party text: control characters (the reader's attribution refuses them) become spaces. */
const clean = (value: unknown, maximum: number): string | null => {
  if (typeof value !== 'string') return null;
  const text = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, maximum).trim();
  return text || null;
};

function validDate(value: unknown): string | null {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value ? value : null;
}

function abstractText(index: unknown): string | null {
  if (!index || typeof index !== 'object' || Array.isArray(index)) return null;
  const words: string[] = [];
  for (const [word, positions] of Object.entries(index as Record<string, unknown>).slice(0, 20_000)) {
    if (Array.isArray(positions)) for (const at of positions.slice(0, 1000)) if (typeof at === 'number' && Number.isInteger(at) && at >= 0 && at < 20_000) words[at] = word;
  }
  return clean(words.filter(Boolean).join(' '), 24_000);
}

/** OpenAlex's work record as catalog metadata and PDF locations; null if unusable. */
export function openAlexWork(json: unknown): WebWork | null {
  if (!json || typeof json !== 'object' || Array.isArray(json)) return null;
  const w = json as Record<string, unknown>;
  if (typeof w.id !== 'string' || !/^https:\/\/openalex\.org\/W\d{1,15}$/.test(w.id)) return null;
  const title = clean(w.title, 2000) ?? clean(w.display_name, 2000);
  if (!title) return null;
  const authors = (Array.isArray(w.authorships) ? w.authorships.slice(0, 512) : [])
    .map(a => clean((a as { author?: { display_name?: unknown } })?.author?.display_name, 256)).filter((n): n is string => !!n);
  const venue = clean((w.primary_location as { source?: { display_name?: unknown } } | null)?.source?.display_name, 1024);
  const doi = typeof w.doi === 'string' ? /^https:\/\/doi\.org\/(10\.\d{4,9}\/[!-~]{1,200})$/i.exec(w.doi)?.[1] ?? null : null;
  const best = (w.best_oa_location && typeof w.best_oa_location === 'object' ? w.best_oa_location : null) as { landing_page_url?: unknown } | null;
  const pdfURLs = openPDFLocations(w);
  const landing = typeof best?.landing_page_url === 'string' ? publicHTTPS(best.landing_page_url.replace(/^http:\/\//i, 'https://')) : null;
  const landingURL = landing && landing.href.length <= 512 ? landing.href : doi ? `https://doi.org/${doi}` : null;
  return { metadata: { title, authors, abstract: abstractText(w.abstract_inverted_index), published_at: validDate(w.publication_date), updated_at: null,
    categories: [], venue }, doi, pdfURLs, landingURL };
}

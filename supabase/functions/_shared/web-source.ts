// Web imports (migration 019): a paper with no arXiv copy, read from the
// open-access PDF OpenAlex reports for it. OpenAlex is the only source of a web
// paper's metadata and PDF locations; those locations are third-party data, so
// every hop of every download is checked here. Deno and Node compatible.

export const WEB_USER_AGENT = 'ScienceReader/0.1 (research paper reader; mailto:support@sciencereader.invalid)';
const MiB = 1024 * 1024;

/** `permanent`: retrying the same request now cannot help (the next location is tried; the
 * import fails, and migration 027 decides from the code whether it is retried automatically).
 * Download codes, as readers see them:
 * - `pdf_restricted`: the location needs a sign-in or subscription (401/402, a login page, a paywall);
 * - `source_blocked`: the website refused an automated download (a bot check, 403);
 * - `not_pdf`: the location is a web page that declares no PDF, or a file that is not a PDF;
 * - `too_large`: over the size limit;
 * - `download_failed`: anything else (gone, refused redirect, unresolvable or private host, TLS);
 * - `rate_limited` (429/5xx) and transient `download_failed` (resets, timeouts) are retried soon. */
export class WebSourceError extends Error {
  readonly code: 'metadata_unavailable' | 'download_failed' | 'too_large' | 'rate_limited' | 'pdf_restricted' | 'source_blocked' | 'not_pdf';
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
 * name), no credentials, printable ASCII. Mirrors app_private.web_url_ok (stored
 * locations: 1000 characters); a redirect hop, never stored, may be longer (sign-in
 * round trips carry tokens). */
export function publicHTTPS(value: string | URL, maxLength = 1000): URL | null {
  let url: URL;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || url.username || url.password || url.port !== '' || url.hash) return null;
  const host = url.hostname.toLowerCase();
  // A letter-only top-level label excludes IPv4 literals (in any notation, once
  // parsed) and IPv6 literals; single-label names are excluded too.
  if (!/^[a-z0-9-]{1,63}(\.[a-z0-9-]{1,63})*\.[a-z]{2,63}$/.test(host) || LOCAL_NAMES.test(host)) return null;
  if (url.href.length > maxLength || !/^[!-~]+$/.test(url.href)) return null;
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

/** A bounded body (OpenAlex JSON). */
async function readCapped(body: ReadableStream<Uint8Array>, maximum: number): Promise<Uint8Array> {
  const reader = body.getReader(); const parts: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximum) throw new WebSourceError('too_large', true);
      parts.push(value);
    }
  } catch (error) { void reader.cancel().catch(() => {}); throw error; }
  return joined(parts, size);
}

/** Landing pages read for their PDF link are cut here (the link is declared in the head;
 * Zenodo's record page is ~200 KB, ScienceDirect's ~830 KB). Refusal pages are read less. */
const LANDING_PAGE_BYTES = 1_500_000;
const REFUSAL_PAGE_BYTES = 256 * 1024;

const LOCAL_HOST = /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])$/i;

/** A link a server or page declares, as a URL we may fetch: resolved against `base`, http
 * upgraded to https (never fetched in the clear), fragment dropped. `rebaseLocal`: a page
 * that names its own host as localhost (a common DSpace 7 misconfiguration) means itself. */
function declaredURL(value: string, base: URL, rebaseLocal = false, maxLength = 1000): URL | null {
  let url: URL;
  try {
    url = new URL(value.trim(), base);
    if (url.protocol === 'http:') url = new URL(`https:${url.href.slice('http:'.length)}`);
    if (rebaseLocal && LOCAL_HOST.test(url.hostname)) url = new URL(url.pathname + url.search, base);
  } catch { return null; }
  url.hash = '';
  return publicHTTPS(url, maxLength);
}

/** PubMed Central serves its PDFs to browsers only (a proof-of-work page); NLM publishes the
 * same open-access articles as open data on S3 (PMC Article Datasets), where a PMC article
 * page or PDF link is fetched instead (first version; a missing one fails like any location). */
const PMC_PAGE = /^(?:(?:www\.)?ncbi\.nlm\.nih\.gov\/pmc\/articles|pmc\.ncbi\.nlm\.nih\.gov\/articles|(?:www\.)?europepmc\.org\/(?:articles|article\/PMC))\/(?:PMC)?(\d{1,9})(?:\/|$)/i;
export function openDataPDF(url: URL): URL | null {
  const id = PMC_PAGE.exec(url.hostname + url.pathname)?.[1];
  return id ? new URL(`https://pmc-oa-opendata.s3.amazonaws.com/PMC${Number(id)}.1/PMC${Number(id)}.1.pdf`) : null;
}

const decodeEntities = (value: string) => value.replace(/&amp;/gi, '&').replace(/&#x2F;|&#47;/gi, '/').replace(/&#x3A;|&#58;/gi, ':').trim();

/** The PDF a repository landing page declares, best first: `citation_pdf_url` (Highwire tags:
 * Zenodo, OpenReview, PMLR, JMLR, ACL Anthology, CVF, EPrints, DSpace, OJS) or bepress's, a PDF
 * alternate link, a PDF in an iframe/embed (IEEE's stamp page), then a prompt meta refresh. */
export function landingPagePDF(html: string, base: URL): URL | null {
  const tags = html.match(/<(?:meta|link|iframe|embed)\b[^>]*>/gi) ?? [];
  // Quoted or unquoted values (ACL Anthology writes name=citation_pdf_url).
  const attribute = (tag: string, name: string) => {
    const match = new RegExp(`[\\s"'/]${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=<>\`]+))`, 'i').exec(tag);
    const value = match?.slice(1).find(v => v !== undefined);
    return value === undefined ? null : decodeEntities(match?.[3] !== undefined ? value.replace(/\/$/, '') : value);
  };
  const ranked: [number, string][] = [];
  for (const tag of tags) {
    const kind = /^<(\w+)/.exec(tag)![1].toLowerCase();
    if (kind === 'meta') {
      const name = (attribute(tag, 'name') ?? attribute(tag, 'property') ?? '').toLowerCase();
      if (name === 'citation_pdf_url' || name === 'bepress_citation_pdf_url') ranked.push([0, attribute(tag, 'content') ?? '']);
      else if (attribute(tag, 'http-equiv')?.toLowerCase() === 'refresh') {
        const refresh = /^\s*(\d{1,3})\s*[;,]\s*url\s*=\s*['"]?([^'"]+)/i.exec(attribute(tag, 'content') ?? '');
        if (refresh && Number(refresh[1]) <= 10) ranked.push([3, refresh[2]]);
      }
    } else if (kind === 'link') {
      if (/\balternate\b/i.test(attribute(tag, 'rel') ?? '') && /application\/pdf/i.test(attribute(tag, 'type') ?? '')) ranked.push([1, attribute(tag, 'href') ?? '']);
    } else {
      const src = attribute(tag, 'src') ?? '';
      if (/application\/pdf/i.test(attribute(tag, 'type') ?? '') || /\.pdf(?:[?#]|$)/i.test(src)) ranked.push([2, src]);
    }
  }
  for (const [, value] of ranked.sort((a, b) => a[0] - b[0])) {
    const next = value ? declaredURL(value, base, true) : null;
    if (next) return next;
  }
  return null;
}

// Markers seen on real refusals (survey 2026-10-07): Cloudflare/Turnstile, AWS WAF and
// CloudFront, Akamai, Imperva/Incapsula, Radware (perfdrive), PMC's proof-of-work page.
const BOT_TITLE = /just a moment|attention required|verifying (you are human|your browser)|verify you are (a )?human|human verification|are you a (robot|human)|security check|checking (your )?browser|access denied|request (could not be satisfied|rejected|blocked)|bot (check|protection|detection|verification)|captcha|preparing to download|unusual traffic|forbidden|too many requests/i;
const BOT_PAGE = /cf-turnstile|challenge-platform|cf-chl-|_incapsula_resource|perfdrive|captcha-delivery|px-captcha|cloudpmc-viewer-pow|awswaf|hcaptcha|g-recaptcha|datadome/i;
const LOGIN_PATH = /(^|\/)(login|log-in|logon|signin|sign-in|sso|shibboleth|wayf|idp|authorize|oauth2?)(\/|\.|$)/i;
const LOGIN_HOST = /^(idp|login|sso|auth|signin|shibboleth|wayf)\./i;
const PAYWALL = /\b(purchase|buy|rent) (this |the )?(article|chapter|paper|pdf|issue)\b|\bsubscribe (now|to (read|access|view|continue))\b|\b(institutional|subscriber) (log ?in|access|sign ?in)\b|\b(log|sign) ?in (to|through|via|with) (your )?(institution|institutional|access|read|download|view|continue)\b|\baccess (through|via) your institution\b|\b(you|your institution) (do|does) not have (a )?(subscription|access)\b|\bpay[- ]per[- ]view\b/i;

/** Why a location served a page (or a refusal) instead of the PDF: a sign-in or paywall
 * (`pdf_restricted`), a bot check or a refusal (`source_blocked`), or a page that declares
 * no PDF (`not_pdf`). A login link alone is not a paywall (open repositories have one). */
export function refusal(html: string, url: URL, status: number): 'pdf_restricted' | 'source_blocked' | 'not_pdf' | 'download_failed' {
  const title = /<title[^>]*>([\s\S]{0,300}?)<\/title>/i.exec(html)?.[1] ?? '';
  if (status === 401 || status === 402 || /<input\b[^>]*\btype\s*=\s*["']?password\b/i.test(html) || LOGIN_PATH.test(url.pathname) || LOGIN_HOST.test(url.hostname)) return 'pdf_restricted';
  if (BOT_TITLE.test(title) || BOT_PAGE.test(html)) return 'source_blocked';
  const visible = html.replace(/<(script|style)\b[\s\S]*?<\/\1\s*>/gi, ' ').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
  if (PAYWALL.test(visible)) return 'pdf_restricted';
  if (status >= 400) return [403, 405, 451].includes(status) ? 'source_blocked' : 'download_failed';
  return 'not_pdf';
}

function joined(parts: Uint8Array[], size: number): Uint8Array {
  const bytes = new Uint8Array(size); let offset = 0;
  for (const part of parts) {
    if (offset >= size) break;
    const take = part.subarray(0, size - offset); bytes.set(take, offset); offset += take.byteLength;
  }
  return bytes;
}

/** What a body is, from its first bytes (never its declared type: servers send PDFs as
 * text/html or octet-stream, and pages as application/pdf). Null until it can tell. */
function sniff(head: Uint8Array, final: boolean): 'pdf' | 'page' | 'other' | null {
  const text = new TextDecoder().decode(head);
  if (text.startsWith('%PDF-')) return 'pdf';
  const rest = text.replace(/^﻿/, '').trimStart();
  if (rest.startsWith('<')) return 'page';
  return rest.length >= 5 || final || head.byteLength >= 512 ? 'other' : null;
}

type Download = { kind: 'pdf'; bytes: Uint8Array } | { kind: 'page'; html: string } | { kind: 'other' };
/** Reads a download: a PDF whole (refused past `maximum`), a web page up to `pageBytes` (for
 * its PDF link or its refusal), anything else not at all. */
async function readDownload(body: ReadableStream<Uint8Array>, maximum: number, pageBytes = LANDING_PAGE_BYTES): Promise<Download> {
  const reader = body.getReader(); const parts: Uint8Array[] = []; let size = 0; let kind: 'pdf' | 'page' | 'other' | null = null;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      parts.push(value); size += value.byteLength;
      kind ??= sniff(joined(parts, Math.min(size, 512)), false);
      if (kind === 'other') break;
      if (kind === 'pdf' && size > maximum) throw new WebSourceError('too_large', true);
      if (kind === 'page' && size >= pageBytes) break;
    }
  } catch (error) { void reader.cancel().catch(() => {}); throw error; }
  if (kind !== 'pdf') void reader.cancel().catch(() => {});
  kind ??= size ? sniff(joined(parts, Math.min(size, 512)), true) : 'other';
  if (kind === 'pdf') return { kind, bytes: joined(parts, size) };
  if (kind === 'page') return { kind, html: new TextDecoder().decode(joined(parts, Math.min(size, pageBytes))) };
  return { kind: 'other' };
}

/** A certificate the runtime cannot verify (expired, self-signed, an incomplete chain):
 * retrying the same host soon will not help. */
const tlsFailure = (error: unknown) => {
  const cause = (error as { cause?: { code?: unknown; message?: unknown } } | null)?.cause;
  return /CERT|SSL|TLS|UNABLE_TO_VERIFY|SELF_SIGNED|certificate/i.test(`${cause?.code ?? ''} ${cause?.message ?? ''}`);
};

/** One download, every redirect hop re-checked (URL and resolved addresses).
 * `budget` bounds the whole download (all hops and the body). A web page in place of the
 * PDF is followed once to the PDF it declares; otherwise it is classified (see `refusal`). */
export async function fetchWebPDF(fetcher: typeof fetch, start: string, maximum: number, resolve?: ResolveHost,
  budget: AbortSignal = AbortSignal.timeout(120_000)): Promise<Uint8Array> {
  const first = publicHTTPS(start);
  let current = first && (openDataPDF(first) ?? first), followedPage = false;
  for (let hop = 0; hop < 7; hop++) {
    // arXiv copies go through the arXiv path (and its pacing), never a web redirect.
    if (!current || ARXIV_HOSTS.test(current.hostname)) throw new WebSourceError('download_failed', true);
    if (budget.aborted) throw new WebSourceError('download_failed', false);
    await checkHost(current, resolve);
    let response: Response;
    try {
      response = await fetcher(current.href, { redirect: 'manual', headers: { accept: 'application/pdf, text/html;q=0.8, */*;q=0.5', 'user-agent': WEB_USER_AGENT },
        signal: AbortSignal.any([budget, AbortSignal.timeout(60_000)]) });
    } catch (error) { throw new WebSourceError('download_failed', tlsFailure(error)); }
    const drop = () => void response.body?.cancel().catch(() => {});
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); drop();
      current = location ? declaredURL(location, current, false, 4096) : null; continue;
    }
    if (response.status === 429 || response.status >= 500) { drop(); throw new WebSourceError('rate_limited', false); }
    // Bot checks announced in headers (Cloudflare, AWS WAF, which also answers 202).
    if (response.headers.get('cf-mitigated') === 'challenge' || response.headers.has('x-amzn-waf-action')) { drop(); throw new WebSourceError('source_blocked', true); }
    if (response.status === 404 || response.status === 410) { drop(); throw new WebSourceError('download_failed', true); }
    if (response.status >= 400) {
      // A refusal: its page tells a sign-in or paywall from a bot check.
      let html = '';
      if (response.body) {
        const page = await readDownload(response.body, maximum, REFUSAL_PAGE_BYTES).catch(() => null);
        if (page?.kind === 'page') html = page.html;
      }
      throw new WebSourceError(refusal(html, current, response.status), true);
    }
    if (response.status !== 200 || !response.body) { drop(); throw new WebSourceError('download_failed', true); }
    const declared = response.headers.get('content-length');
    if (declared && Number(declared) > maximum) { drop(); throw new WebSourceError('too_large', true); }
    let body: Download;
    // A reset or timeout mid-body is transient: the next location (or a later attempt) may work.
    try { body = await readDownload(response.body, maximum); }
    catch (error) { throw error instanceof WebSourceError ? error : new WebSourceError('download_failed', false); }
    if (body.kind === 'pdf') return body.bytes;
    if (body.kind === 'other') throw new WebSourceError('not_pdf', true);
    const next = followedPage ? null : landingPagePDF(body.html, current);
    if (!next) throw new WebSourceError(refusal(body.html, current, 200), true);
    followedPage = true; current = openDataPDF(next) ?? next;
  }
  throw new WebSourceError('download_failed', true);
}

/** When every location failed for good, the reason readers see: the most telling one. */
const PERMANENT_RANK: Record<string, number> = { too_large: 5, pdf_restricted: 4, source_blocked: 3, not_pdf: 2, download_failed: 1 };

/** Tries each location in order within one overall budget. Fails permanently only
 * if every location did; running out of budget is transient. */
export async function fetchFirstWebPDF(fetcher: typeof fetch, urls: readonly string[], maximum: number, resolve?: ResolveHost,
  budget: AbortSignal = AbortSignal.timeout(120_000)): Promise<{ bytes: Uint8Array; url: string }> {
  let transient: WebSourceError | null = null, permanent: WebSourceError['code'] = 'download_failed';
  for (const url of urls.slice(0, 3)) {
    if (budget.aborted) { transient ??= new WebSourceError('download_failed', false); break; }
    try { return { bytes: await fetchWebPDF(fetcher, url, maximum, resolve, budget), url }; }
    catch (error) {
      if (!(error instanceof WebSourceError)) throw error;
      if (!error.permanent) transient ??= error;
      else if ((PERMANENT_RANK[error.code] ?? 0) > (PERMANENT_RANK[permanent] ?? 0)) permanent = error.code;
    }
  }
  if (transient) throw transient;
  throw new WebSourceError(permanent, true);
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
    const bytes = await readCapped(response.body, 2 * MiB).catch(() => { throw new WebSourceError('metadata_unavailable', false); });
    try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new WebSourceError('metadata_unavailable', false); }
  }
  throw new WebSourceError('metadata_unavailable', true);
}

type OpenAlexLocation = { pdf_url?: unknown; landing_page_url?: unknown; is_oa?: unknown; source?: unknown } | null;
const httpsURL = (raw: unknown) => typeof raw === 'string' ? publicHTTPS(raw.replace(/^http:\/\//i, 'https://')) : null;
const locationsOf = (work: unknown) => {
  const all = (work as { locations?: unknown } | null)?.locations;
  return (Array.isArray(all) ? all.slice(0, 50) : []) as OpenAlexLocation[];
};

/** Every explicit PDF location of a work, best first: OpenAlex's best open-access location,
 * PDFs on open venues, then other open-access copies; never arXiv-hosted, http tried over https. */
function explicitPDFs(work: unknown): URL[] {
  if (!work || typeof work !== 'object') return [];
  const w = work as { best_oa_location?: unknown };
  const best = (w.best_oa_location && typeof w.best_oa_location === 'object' ? w.best_oa_location : null) as OpenAlexLocation;
  const all = locationsOf(work);
  // Some locations (e.g. JMLR) give the PDF itself as the landing page and no pdf_url.
  const url = (location: OpenAlexLocation) => httpsURL(typeof location?.pdf_url === 'string' ? location.pdf_url
    : typeof location?.landing_page_url === 'string' && /^[^?#]+\.pdf(?:[?#]|$)/i.test(location.landing_page_url) ? location.landing_page_url : null);
  const ordered = [url(best), ...all.map(url).filter(u => u && OPEN_VENUES.test(u.hostname)), ...all.filter(l => l?.is_oa === true).map(url)];
  const result: URL[] = [];
  for (const candidate of ordered) {
    if (candidate && !ARXIV_HOSTS.test(candidate.hostname) && !result.some(r => r.href === candidate.href)) result.push(candidate);
  }
  return result;
}

/** A work's PDF locations worth trying, best first (at most three): OpenAlex's best
 * open-access location, PDFs on open venues, then other open-access copies. Never
 * arXiv-hosted (arXiv copies use the arXiv path); http links are tried over https.
 * A closed location that slips through fails safely (login pages are refused).
 * Ingest decides from this whether a paper has an open copy. */
export function openPDFLocations(work: unknown): string[] {
  return explicitPDFs(work).slice(0, 3).map(u => u.href);
}

/** Hosts that answered every non-browser request with a bot check when surveyed (2026-10-07:
 * Cloudflare, CloudFront/AWS WAF, Radware). Their copies are tried after every other copy, not
 * dropped (a check can be lifted). Ordering only: correctness never depends on this list. */
const CHALLENGED_HOSTS = /(^|\.)(dl\.acm\.org|academic\.oup\.com|journals\.iucr\.org|thelancet\.com|cell\.com|sciencedirect\.com|science\.org|sciencemag\.org|pnas\.org|onlinelibrary\.wiley\.com|tandfonline\.com|journals\.sagepub\.com|pubs\.acs\.org|iopscience\.iop\.org|peerj\.com|papers\.ssrn\.com|escholarship\.org|openreview\.net)$/;

/** Where the pipeline downloads a web paper from (at most three, the stored limit): explicit
 * PDFs on hosts that serve them, then PubMed Central copies through NLM's open data, then open
 * repository records (their landing page declares the PDF, e.g. a Zenodo DOI or a DSpace
 * handle), then explicit PDFs on hosts that challenge automated downloads. Covers whatever
 * Ingest counts as open (`openPDFLocations`), never arXiv-hosted. */
export function downloadLocations(work: unknown): string[] {
  if (!work || typeof work !== 'object') return [];
  const explicit = explicitPDFs(work);
  const open = locationsOf(work).filter(l => l?.is_oa === true);
  const pmc = [...explicit, ...open.flatMap(l => [httpsURL(l?.pdf_url), httpsURL(l?.landing_page_url)])].map(u => u && openDataPDF(u));
  const repositories = open.filter(l => l?.pdf_url == null && (l?.source as { type?: unknown } | null)?.type === 'repository')
    .map(l => httpsURL(l?.landing_page_url)).filter(u => u && !openDataPDF(u));
  const ordered = [...explicit.filter(u => !CHALLENGED_HOSTS.test(u.hostname) && !openDataPDF(u)), ...pmc, ...repositories,
    ...explicit.filter(u => CHALLENGED_HOSTS.test(u.hostname))];
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
  /** Where to download it from, best first (`downloadLocations`), never on arXiv (arXiv copies use the arXiv path). */
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
  const pdfURLs = downloadLocations(w);
  const landing = typeof best?.landing_page_url === 'string' ? publicHTTPS(best.landing_page_url.replace(/^http:\/\//i, 'https://')) : null;
  const landingURL = landing && landing.href.length <= 512 ? landing.href : doi ? `https://doi.org/${doi}` : null;
  return { metadata: { title, authors, abstract: abstractText(w.abstract_inverted_index), published_at: validDate(w.publication_date), updated_at: null,
    categories: [], venue }, doi, pdfURLs, landingURL };
}

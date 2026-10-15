// DataCite for arXiv's DOIs (10.48550/arXiv.<id>): the metadata arXiv deposits, read from DataCite rather than from
// arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md §5.10). arXiv support named it as a metadata source; it is not an
// arXiv host, its records are CC0, and it sends CORS headers, so the browser can use the same client and parser.
// Bounded responses, one request at a time per caller, polite backoff on 429/503, and an identifying User-Agent where
// the platform lets us set one (DataCite gives identified clients a higher limit).
import { ARXIV_CATEGORIES, isArxivSourceID, licenseFromRights, SOURCE_METADATA_FORMAT, validateSourceMetadata, type SourceMetadata } from './source-metadata.ts';

export const DATACITE_API = 'https://api.datacite.org';
export const DATACITE_USER_AGENT = 'Gradstep/0.1 (research paper reader; +https://gradstep.ai; mailto:hello@gradstep.ai)';
export const DATACITE_MAX_BYTES = 1_048_576;
export const DATACITE_MAX_BATCH = 25;

export class DataCiteError extends Error {
  readonly code: 'datacite_not_found' | 'datacite_unavailable' | 'datacite_invalid' | 'datacite_too_large';
  constructor(code: DataCiteError['code']) { super(code); this.code = code; }
}

/** One arXiv paper's record as DataCite describes its latest version. */
export interface DataCiteRecord {
  sourceID: string;
  /** The latest version DataCite knows (licence and title describe that version). */
  version: number;
  title: string;
  authors: string[];
  abstract: string | null;
  categories: string[];
  licenseURI: string | null;
  /** Submission date of each version it lists (YYYY-MM-DD). */
  submitted: Record<number, string>;
}

export const dataciteDOI = (sourceID: string): string => {
  if (!isArxivSourceID(sourceID)) throw new DataCiteError('datacite_invalid');
  return `10.48550/arXiv.${sourceID}`;
};
export const dataciteRecordURL = (sourceID: string): string => `${DATACITE_API}/dois/${dataciteDOI(sourceID)}`;
export const dataciteBatchURL = (sourceIDs: readonly string[]): string => {
  if (!sourceIDs.length || sourceIDs.length > DATACITE_MAX_BATCH) throw new DataCiteError('datacite_invalid');
  return `${DATACITE_API}/dois?${new URLSearchParams({ ids: sourceIDs.map(dataciteDOI).join(','), 'page[size]': String(sourceIDs.length) })}`;
};

const CATEGORY_SET = new Set(ARXIV_CATEGORIES);
const clean = (value: unknown, max: number): string | null => {
  if (typeof value !== 'string') return null;
  const out = value.normalize('NFC').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  return out && [...out].length <= max ? out : null;
};

/** A DataCite DOI resource (`data` of /dois/<doi>, or one item of /dois?ids=…) as a record, or null when it is not an
 * arXiv paper we can read. Names are "Given Family" (DataCite stores "Family, Given"). */
export function parseDataCiteRecord(resource: unknown): DataCiteRecord | null {
  if (!resource || typeof resource !== 'object') return null;
  const attributes = (resource as { attributes?: unknown }).attributes as Record<string, unknown> | undefined;
  if (!attributes || typeof attributes !== 'object') return null;
  const doi = typeof attributes.doi === 'string' ? attributes.doi : null;
  const match = doi ? /^10\.48550\/arxiv\.(.+)$/i.exec(doi) : null;
  if (!match) return null;
  // DataCite lower-cases the DOI; the identifier's own case returns from the archive part ("hep-th/9711200",
  // "math.AG/0101001" — the subject class is upper case), and modern IDs are digits.
  const raw = match[1];
  const sourceID = /^[a-z-]+\.[a-z]{2}\//.test(raw) ? raw.replace(/^([a-z-]+\.)([a-z]{2})\//, (_, a: string, b: string) => `${a}${b.toUpperCase()}/`) : raw;
  if (!isArxivSourceID(sourceID)) return null;
  const version = typeof attributes.version === 'string' && /^[1-9][0-9]{0,3}$/.test(attributes.version) ? Number(attributes.version) : null;
  const titles = Array.isArray(attributes.titles) ? attributes.titles : [];
  const title = clean((titles.find(t => t && typeof t === 'object' && !(t as { titleType?: unknown }).titleType) as { title?: unknown } | undefined)?.title, 2000);
  if (!version || !title) return null;
  const authors = (Array.isArray(attributes.creators) ? attributes.creators : []).slice(0, 512).flatMap(c => {
    if (!c || typeof c !== 'object') return [];
    const creator = c as { name?: unknown; givenName?: unknown; familyName?: unknown };
    const given = clean(creator.givenName, 200), family = clean(creator.familyName, 200);
    const name = given && family ? `${given} ${family}` : clean(creator.name, 256)?.replace(/^([^,]+),\s*(.+)$/, '$2 $1');
    const out = name ? clean(name, 256) : null;
    return out ? [out] : [];
  });
  if (!authors.length) return null;
  const description = (Array.isArray(attributes.descriptions) ? attributes.descriptions : [])
    .find(d => d && typeof d === 'object' && (d as { descriptionType?: unknown }).descriptionType === 'Abstract') as { description?: unknown } | undefined;
  const abstractText = typeof description?.description === 'string' ? description.description.normalize('NFC').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').trim() : '';
  const abstract = abstractText && [...abstractText].length <= 24_000 ? abstractText : null;
  // "Machine Learning (cs.LG)" → cs.LG; arXiv's own scheme only, primary first as DataCite lists it.
  const categories = [...new Set((Array.isArray(attributes.subjects) ? attributes.subjects : []).flatMap(s => {
    if (!s || typeof s !== 'object' || (s as { subjectScheme?: unknown }).subjectScheme !== 'arXiv') return [];
    const code = /\(([^()]+)\)\s*$/.exec(String((s as { subject?: unknown }).subject ?? ''))?.[1];
    return code && CATEGORY_SET.has(code) ? [code] : [];
  }))].slice(0, 64);
  const rights = Array.isArray(attributes.rightsList) ? attributes.rightsList : [];
  const licenseURI = rights.map(r => licenseFromRights(r as Record<string, unknown>)).find(Boolean) ?? null;
  const submitted: Record<number, string> = {};
  for (const d of Array.isArray(attributes.dates) ? attributes.dates : []) {
    if (!d || typeof d !== 'object') continue;
    const { date, dateType, dateInformation } = d as { date?: unknown; dateType?: unknown; dateInformation?: unknown };
    const v = typeof dateInformation === 'string' ? /^v([1-9][0-9]{0,3})$/.exec(dateInformation)?.[1] : undefined;
    if (dateType === 'Submitted' && v && typeof date === 'string' && /^[0-9]{4}-[0-9]{2}-[0-9]{2}/.test(date)) submitted[Number(v)] = date.slice(0, 10);
  }
  return { sourceID, version, title, authors, abstract, categories, licenseURI, submitted };
}

/** The device contract for a record, pinned to `revision` (≤ the latest DataCite knows). The licence is the latest
 * version's, so it is kept only for that version: an older version's licence is unknown here (null). */
export function dataciteSourceMetadata(record: DataCiteRecord, revision: number, observedAt = new Date()): SourceMetadata {
  if (!Number.isSafeInteger(revision) || revision < 1 || revision > record.version) throw new DataCiteError('datacite_invalid');
  return validateSourceMetadata({ format: SOURCE_METADATA_FORMAT, source_id: record.sourceID, revision, origin: 'datacite', title: record.title,
    authors: record.authors, abstract: record.abstract, categories: record.categories,
    license_uri: revision === record.version ? record.licenseURI : null, version_date: record.submitted[revision] ?? null,
    html_available: false, observed_at: observedAt.toISOString() }, {}, observedAt).metadata;
}

/** The fields a server-side verification compares (§5.4 step 5), and their digest's preimage. */
export const dataciteEvidence = (record: DataCiteRecord) => ({ origin: 'datacite', doi: dataciteDOI(record.sourceID).toLowerCase(),
  title: record.title, first_author: record.authors[0], version: record.version, license_uri: record.licenseURI });

type Fetch = (input: string, init?: RequestInit) => Promise<Response>;
export interface DataCiteOptions {
  fetch?: Fetch; signal?: AbortSignal; sleep?: (ms: number) => Promise<void>;
  /** Browsers cannot set User-Agent (a forbidden header); they identify with `mailto` and their Origin instead. */
  browser?: boolean; attempts?: number;
}

async function boundedJSON(response: Response): Promise<unknown> {
  const declared = Number(response.headers.get('content-length') ?? 0);
  if (declared > DATACITE_MAX_BYTES) throw new DataCiteError('datacite_too_large');
  const reader = response.body?.getReader();
  if (!reader) throw new DataCiteError('datacite_invalid');
  const chunks: Uint8Array[] = []; let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > DATACITE_MAX_BYTES) { try { await reader.cancel(); } catch { /* closing */ } throw new DataCiteError('datacite_too_large'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total); let at = 0;
  for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.length; }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { throw new DataCiteError('datacite_invalid'); }
}

/** GET with 429/503 backoff (Retry-After honoured, at least 1 s, at most 60 s, `attempts` tries). */
export async function dataciteGet(url: string, options: DataCiteOptions = {}): Promise<unknown> {
  const fetcher = options.fetch ?? ((input: string, init?: RequestInit) => fetch(input, init));
  const sleep = options.sleep ?? ((ms: number) => new Promise(resolve => setTimeout(resolve, ms)));
  const target = new URL(url);
  if (target.origin !== DATACITE_API) throw new DataCiteError('datacite_invalid');
  if (options.browser) target.searchParams.set('mailto', 'hello@gradstep.ai');
  const headers: Record<string, string> = { accept: 'application/vnd.api+json' };
  if (!options.browser) headers['user-agent'] = DATACITE_USER_AGENT;
  const attempts = Math.min(Math.max(options.attempts ?? 3, 1), 5);
  for (let attempt = 1; ; attempt++) {
    let response: Response;
    try { response = await fetcher(target.href, { headers, redirect: 'error', signal: options.signal, ...(options.browser ? { credentials: 'omit', referrerPolicy: 'no-referrer' } : {}) }); }
    catch (error) { if (options.signal?.aborted) throw error; if (attempt >= attempts) throw new DataCiteError('datacite_unavailable'); await sleep(1000 * 2 ** attempt); continue; }
    if (response.status === 404) { try { await response.body?.cancel(); } catch { /* none */ } throw new DataCiteError('datacite_not_found'); }
    if (response.status === 429 || response.status === 503) {
      try { await response.body?.cancel(); } catch { /* none */ }
      if (attempt >= attempts) throw new DataCiteError('datacite_unavailable');
      const retryAfter = Number(response.headers.get('retry-after'));
      await sleep(Math.min(60_000, Math.max(1000, Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 1000 * 2 ** attempt)));
      continue;
    }
    if (!response.ok) { try { await response.body?.cancel(); } catch { /* none */ } throw new DataCiteError('datacite_unavailable'); }
    return boundedJSON(response);
  }
}

/** One paper's record. */
export async function fetchDataCiteRecord(sourceID: string, options: DataCiteOptions = {}): Promise<DataCiteRecord> {
  const body = await dataciteGet(dataciteRecordURL(sourceID), options) as { data?: unknown };
  const record = parseDataCiteRecord(body?.data);
  if (!record || record.sourceID.toLowerCase() !== sourceID.toLowerCase()) throw new DataCiteError('datacite_invalid');
  return record;
}

/** Up to 25 papers in one request; papers DataCite doesn't have are simply absent from the map. */
export async function fetchDataCiteRecords(sourceIDs: readonly string[], options: DataCiteOptions = {}): Promise<Map<string, DataCiteRecord>> {
  const body = await dataciteGet(dataciteBatchURL(sourceIDs), options) as { data?: unknown };
  const out = new Map<string, DataCiteRecord>();
  for (const item of Array.isArray(body?.data) ? body.data : []) {
    const record = parseDataCiteRecord(item);
    if (record && sourceIDs.includes(record.sourceID)) out.set(record.sourceID, record);
  }
  return out;
}

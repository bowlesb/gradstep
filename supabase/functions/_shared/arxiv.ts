import { children, one, plain, sourceXML, SourceError, type XMLNode } from './source-xml.ts';
import { sha256 } from './http.ts';

const ATOM = 'http://www.w3.org/2005/Atom';
const ARXIV_ATOM = 'http://arxiv.org/schemas/atom';
const OAI = 'http://www.openarchives.org/OAI/2.0/';
const RAW = 'http://arxiv.org/OAI/arXivRaw/';
const allowedInputHosts = new Set(['arxiv.org', 'www.arxiv.org', 'export.arxiv.org']);

export interface ArxivReference { sourceID: string; revision: number | null }
export interface ArxivMetadata {
  title: string;
  authors: string[];
  abstract: string | null;
  // Full UTC instants are retained for version/license correlation. Convert to
  // the date-only catalog DTO only at the database persistence boundary.
  published_at: string | null;
  updated_at: string | null;
  categories: string[];
  venue: string | null;
}
export interface ArxivRecord {
  sourceID: string;
  revision: number;
  metadata: ArxivMetadata;
}
export interface ArxivCatalogMetadata extends Omit<ArxivMetadata, 'published_at' | 'updated_at'> {
  /** Calendar dates (YYYY-MM-DD), as required by the catalog RPC. */
  published_at: string | null;
  updated_at: string | null;
}

function revisionNumber(value: string): number {
  if (!/^[1-9][0-9]{0,9}$/.test(value) || Number(value) > 2_147_483_647) throw new SourceError('invalid_arxiv_id');
  return Number(value);
}

// Input URLs are parsed only for identity; they are never fetched. Always derive
// outbound URLs below. URL credentials, nonstandard ports, arbitrary hosts/paths
// and encoded path syntax are refused, including before URL normalization.
export function arxivReference(input: string): ArxivReference {
  if (typeof input !== 'string' || input.length > 2048) throw new SourceError('invalid_arxiv_id');
  let value = input.trim();
  if (/\p{Cc}/u.test(value) || value.includes('\\')) throw new SourceError('invalid_arxiv_id');
  if (/^https?:\/\//i.test(value)) {
    const rawPath = /^https?:\/\/[^/?#]+([^?#]*)/i.exec(value)?.[1];
    if (!rawPath || /%/.test(rawPath) || /\/(?:\.|\.\.)(?:\/|$)/.test(rawPath)) throw new SourceError('invalid_arxiv_id');
    let url: URL;
    try { url = new URL(value); } catch { throw new SourceError('invalid_arxiv_id'); }
    if (!allowedInputHosts.has(url.hostname) || url.username || url.password || url.port || /%/.test(url.pathname)) throw new SourceError('invalid_arxiv_id');
    const path = /^\/(abs|pdf)\/(.+)$/.exec(url.pathname);
    if (!path) throw new SourceError('invalid_arxiv_id');
    value = path[2];
    if (path[1] === 'pdf') value = value.replace(/\.pdf$/i, '');
  } else value = value.replace(/^arxiv:\s*/i, '');
  let revision: number | null = null;
  const versioned = /^(.*)v([0-9]+)$/i.exec(value);
  if (versioned) { value = versioned[1]; revision = revisionNumber(versioned[2]); }
  const modern = /^([0-9]{2})([0-9]{2})\.([0-9]{4,5})$/.exec(value);
  if (modern) {
    const year = Number(modern[1]), month = Number(modern[2]), serial = modern[3];
    if (month < 1 || month > 12 || year < 7 || (year === 7 && month < 4) || !Number(serial) || serial.length !== (year < 15 ? 4 : 5)) throw new SourceError('invalid_arxiv_id');
  } else {
    const historic = /^([a-z][a-z0-9-]*)(?:\.([a-z]{2}))?\/([0-9]{2})([0-9]{2})([0-9]{3})$/i.exec(value);
    if (!historic) throw new SourceError('invalid_arxiv_id');
    const archive = historic[1].toLowerCase(), year = Number(historic[3]), month = Number(historic[4]);
    if (month < 1 || month > 12 || !Number(historic[5]) ||
        (year > 7 && year < 91) || (year === 91 && month < 7) || (year === 7 && month > 3) ||
        (historic[2] && !['math', 'cs', 'nlin', 'q-bio'].includes(archive))) throw new SourceError('invalid_arxiv_id');
    // Optional historical classification is not part of the external identity.
    value = `${archive}/${historic[3]}${historic[4]}${historic[5]}`;
  }
  return { sourceID: value, revision };
}

function validated(reference: ArxivReference): ArxivReference {
  const result = arxivReference(`${reference.sourceID}${reference.revision === null ? '' : `v${reference.revision}`}`);
  if (result.sourceID !== reference.sourceID || result.revision !== reference.revision) throw new SourceError('invalid_arxiv_id');
  return result;
}

export function arxivURLs(reference: ArxivReference): { abstract: string; atom: string; raw: string; pdf: string | null } {
  const ref = validated(reference);
  const id = `${ref.sourceID}${ref.revision === null ? '' : `v${ref.revision}`}`;
  const atom = new URL('https://export.arxiv.org/api/query');
  atom.search = new URLSearchParams({ id_list: id, max_results: '1' }).toString();
  const raw = new URL('https://oaipmh.arxiv.org/oai');
  raw.search = new URLSearchParams({ verb: 'GetRecord', identifier: `oai:arXiv.org:${ref.sourceID}`, metadataPrefix: 'arXivRaw' }).toString();
  return { abstract: `https://arxiv.org/abs/${id}`, atom: atom.href, raw: raw.href,
    pdf: ref.revision === null ? null : `https://arxiv.org/pdf/${id}` };
}

function dateValue(node: XMLNode | undefined): string | null {
  const value = plain(node, 64, false);
  if (value === null) return null;
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) throw new SourceError('invalid_source_metadata');
  const timestamp = Date.parse(value);
  // Check the source calendar day independently of its timezone; Date.parse
  // alone normalizes invalid dates such as February 30.
  if (!Number.isFinite(timestamp) || new Date(`${value.slice(0, 10)}T00:00:00Z`).toISOString().slice(0, 10) !== value.slice(0, 10)) throw new SourceError('invalid_source_metadata');
  return new Date(timestamp).toISOString();
}

export function arxivAtomRecord(bytes: Uint8Array, expected: ArxivReference): ArxivRecord {
  validated(expected);
  const root = sourceXML(bytes);
  if (root.uri !== ATOM || root.local !== 'feed') throw new SourceError('invalid_source_metadata');
  const entries = children(root, ATOM, 'entry');
  if (!entries.length) throw new SourceError('source_not_found');
  if (entries.length !== 1) throw new SourceError('source_identity_mismatch');
  const entry = entries[0];
  let ref: ArxivReference;
  try { ref = arxivReference(plain(one(entry, ATOM, 'id'), 256)!); }
  catch { throw new SourceError('invalid_source_metadata'); }
  if (ref.sourceID !== expected.sourceID || ref.revision === null || (expected.revision !== null && ref.revision !== expected.revision)) throw new SourceError('source_identity_mismatch');
  const authors = children(entry, ATOM, 'author').map(author => plain(one(author, ATOM, 'name'), 256)!);
  const categoryNodes = children(entry, ATOM, 'category');
  if (authors.length > 512 || categoryNodes.length > 64) throw new SourceError('metadata_size_limit');
  const categories = [...new Set(categoryNodes.map(category => {
    const term = category.attributes['{}term'];
    if (!term || !/^[A-Za-z][A-Za-z0-9.-]{0,63}$/.test(term)) throw new SourceError('invalid_source_metadata');
    return term;
  }))];
  const metadata: ArxivMetadata = {
    title: plain(one(entry, ATOM, 'title'), 2000)!, authors,
    abstract: plain(one(entry, ATOM, 'summary', false), 24_000, false),
    published_at: dateValue(one(entry, ATOM, 'published', false)),
    updated_at: dateValue(one(entry, ATOM, 'updated', false)),
    categories, venue: plain(one(entry, ARXIV_ATOM, 'journal_ref', false), 1024, false),
  };
  // Leave room for PostgreSQL's JSONB spacing in the 32 KiB catalog bound.
  if (new TextEncoder().encode(JSON.stringify(metadata)).length > 30_000) throw new SourceError('metadata_size_limit');
  return { sourceID: ref.sourceID, revision: ref.revision, metadata };
}

/** Arguments for migration010's metadata RPC; preserves the evidence record. */
export function arxivCatalogArguments(record: ArxivRecord): {
  p_source_id: string; p_revision: number; p_metadata: ArxivCatalogMetadata;
} {
  const ref = validated(record);
  if (ref.revision === null) throw new SourceError('invalid_source_metadata');
  const calendarDate = (value: string | null) => {
    if (value === null) return null;
    if (!Number.isFinite(Date.parse(value)) || new Date(value).toISOString() !== value) throw new SourceError('invalid_source_metadata');
    return value.slice(0, 10);
  };
  return { p_source_id: ref.sourceID, p_revision: ref.revision, p_metadata: {
    title: record.metadata.title, authors: [...record.metadata.authors], categories: [...record.metadata.categories],
    abstract: record.metadata.abstract, venue: record.metadata.venue,
    published_at: calendarDate(record.metadata.published_at), updated_at: calendarDate(record.metadata.updated_at),
  } };
}

export type ArxivReuse =
  | { eligible: false; reason: 'revision_unverified' | 'license_unverified' | 'license_not_supported' }
  | { eligible: true; licenseURI: string; policyVersion: 'arxiv-reuse-v1'; evidence: {
    source_id: string; source_revision: number; source_url: string; license_uri: string;
    evidence_url: string; evidence_format: 'arXivRaw'; evidence_sha256: string; observed_at: string; latest_version_at: string;
  } };

function rawVersionDate(node: XMLNode | undefined): string | null {
  const value = plain(node, 64, false);
  if (!value) return null;
  const match = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), ([0-9]{1,2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) ([0-9]{4}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) GMT$/.exec(value);
  if (!match) return null;
  const time = Date.parse(value);
  const canonical = `${match[1]}, ${match[2].padStart(2, '0')} ${match[3]} ${match[4]} ${match[5]} GMT`;
  if (!Number.isFinite(time) || new Date(time).toUTCString() !== canonical) return null;
  return new Date(time).toISOString();
}

function supportedLicense(value: string): string | null {
  // Only normalize the HTTP/HTTPS spelling of these exact public licenses.
  // Do not follow redirects or accept lookalikes, query strings, or other terms.
  if (/^https?:\/\/creativecommons\.org\/licenses\/by\/4\.0\/$/.test(value)) return 'https://creativecommons.org/licenses/by/4.0/';
  if (/^https?:\/\/creativecommons\.org\/publicdomain\/zero\/1\.0\/$/.test(value)) return 'https://creativecommons.org/publicdomain/zero/1.0/';
  return null;
}

// This consumes a response obtained from the derived OAI URL by a trusted,
// rate-limited worker. It is never an endpoint accepting client license claims.
// A hash is evidence provenance, not a signature from arXiv or byte verification.
export async function arxivReuseEvidence(bytes: Uint8Array, pinned: ArxivRecord, observedAt: string): Promise<ArxivReuse> {
  const ref = validated(pinned);
  if (ref.revision === null || !Number.isFinite(Date.parse(observedAt)) || new Date(observedAt).toISOString() !== observedAt) throw new SourceError('invalid_source_metadata');
  const root = sourceXML(bytes);
  if (root.uri !== OAI || root.local !== 'OAI-PMH') throw new SourceError('invalid_source_metadata');
  if (children(root, OAI, 'error').length) throw new SourceError('source_unavailable');
  const get = one(root, OAI, 'GetRecord')!, record = one(get, OAI, 'record')!, header = one(record, OAI, 'header')!;
  if (header.attributes['{}status'] === 'deleted') throw new SourceError('source_not_found');
  const identity = plain(one(header, OAI, 'identifier'), 256);
  if (identity !== `oai:arXiv.org:${ref.sourceID}`) throw new SourceError('source_identity_mismatch');
  const raw = one(one(record, OAI, 'metadata')!, RAW, 'arXivRaw')!;
  const rawRef = arxivReference(plain(one(raw, RAW, 'id'), 128)!);
  if (rawRef.sourceID !== ref.sourceID || rawRef.revision !== null) throw new SourceError('source_identity_mismatch');
  const versions = children(raw, RAW, 'version').map(version => {
    const value = version.attributes['{}version'];
    if (!value?.startsWith('v')) throw new SourceError('invalid_source_metadata');
    let revision: number;
    try { revision = revisionNumber(value.slice(1)); } catch { throw new SourceError('invalid_source_metadata'); }
    return { revision, submittedAt: rawVersionDate(one(version, RAW, 'date', false)) };
  });
  if (!versions.length || versions.length > 4096 || new Set(versions.map(v => v.revision)).size !== versions.length) throw new SourceError('invalid_source_metadata');
  // OAI describes the latest version. Its history does not prove the license
  // of an older revision; never reuse the latest license for an older PDF.
  const latest = versions.reduce((a, b) => a.revision > b.revision ? a : b);
  if (latest.revision !== ref.revision || versions.some(version => version.submittedAt === null) ||
      !latest.submittedAt || latest.submittedAt !== pinned.metadata.updated_at) return { eligible: false, reason: 'revision_unverified' };
  const license = plain(one(raw, RAW, 'license', false), 512, false);
  if (!license) return { eligible: false, reason: 'license_unverified' };
  const licenseURI = supportedLicense(license);
  if (!licenseURI) return { eligible: false, reason: 'license_not_supported' };
  const urls = arxivURLs(ref);
  return { eligible: true, licenseURI, policyVersion: 'arxiv-reuse-v1', evidence: {
    source_id: ref.sourceID, source_revision: ref.revision, source_url: urls.abstract,
    license_uri: licenseURI, evidence_url: urls.raw, evidence_format: 'arXivRaw',
    evidence_sha256: await sha256(bytes), observed_at: observedAt, latest_version_at: latest.submittedAt,
  } };
}

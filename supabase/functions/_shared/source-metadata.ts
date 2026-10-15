// Device-supplied paper metadata (docs/architecture/ARXIV_DEVICE_ONLY.md §5.3, §5.4): what a reader's device read
// about an arXiv paper (from the arXiv HTML it already downloaded, the export API on native, or DataCite in the
// browser) and sends to our server, which never contacts arXiv itself. One contract for both clients and the server:
// the device extractor builds it, `validateSourceMetadata` checks it here, and the database function
// `app_private.valid_source_metadata` (migration 071) checks it again at the boundary. The two tables below are
// seeded into the database by that migration; tests/backend/source-metadata.test.ts keeps them identical.

export const SOURCE_METADATA_FORMAT = 'arxiv-source-metadata-v1';
export const SOURCE_METADATA_ORIGINS = ['arxiv_html', 'arxiv_api', 'datacite'] as const;
export type SourceMetadataOrigin = typeof SOURCE_METADATA_ORIGINS[number];
export const SOURCE_METADATA_MAX_BYTES = 30_000;

export interface SourceMetadata {
  format: typeof SOURCE_METADATA_FORMAT;
  source_id: string;
  revision: number;
  origin: SourceMetadataOrigin;
  title: string;
  authors: string[];
  abstract: string | null;
  /** Primary first. The HTML gives the primary only; the API and DataCite give all. */
  categories: string[];
  license_uri: string | null;
  /** The exact version's date (YYYY-MM-DD) when known. */
  version_date: string | null;
  html_available: boolean;
  observed_at: string;
}

export class SourceMetadataError extends Error {
  readonly code = 'invalid_source_metadata';
  readonly field: string;
  constructor(field: string) { super(`invalid_source_metadata:${field}`); this.field = field; }
}

/** arXiv's licences as its pages and records name them. CC licences use the https spelling our catalog already uses
 * (`catalog_asset_approvals`, arxiv.ts); arXiv's own licences keep their identifiers. Unknown text is null, never a guess. */
export const ARXIV_LICENSES: readonly { uri: string; labels: readonly string[]; spdx?: string }[] = Object.freeze([
  { uri: 'https://creativecommons.org/licenses/by/4.0/', labels: ['CC BY 4.0'], spdx: 'cc-by-4.0' },
  { uri: 'https://creativecommons.org/licenses/by-sa/4.0/', labels: ['CC BY-SA 4.0'], spdx: 'cc-by-sa-4.0' },
  { uri: 'https://creativecommons.org/licenses/by-nc-sa/4.0/', labels: ['CC BY-NC-SA 4.0'], spdx: 'cc-by-nc-sa-4.0' },
  { uri: 'https://creativecommons.org/licenses/by-nc-nd/4.0/', labels: ['CC BY-NC-ND 4.0'], spdx: 'cc-by-nc-nd-4.0' },
  { uri: 'https://creativecommons.org/publicdomain/zero/1.0/', labels: ['CC Zero', 'CC0 1.0', 'CC0'], spdx: 'cc0-1.0' },
  { uri: 'http://arxiv.org/licenses/nonexclusive-distrib/1.0/', labels: ['arXiv.org perpetual non-exclusive license', 'arXiv.org perpetual, non-exclusive license'] }, // egress-ok: namespace
  // Historical licences (older submissions).
  { uri: 'https://creativecommons.org/licenses/by/3.0/', labels: ['CC BY 3.0'], spdx: 'cc-by-3.0' },
  { uri: 'https://creativecommons.org/licenses/by-nc-sa/3.0/', labels: ['CC BY-NC-SA 3.0'], spdx: 'cc-by-nc-sa-3.0' },
  { uri: 'https://creativecommons.org/licenses/publicdomain/', labels: ['Public Domain'] },
  { uri: 'http://arxiv.org/licenses/assumed-1991-2003/', labels: ['Assumed arXiv.org perpetual non-exclusive license'] }, // egress-ok: namespace
]);

/** arXiv's category codes (the current taxonomy plus the archives and legacy subject classes older papers carry). */
export const ARXIV_CATEGORIES: readonly string[] = Object.freeze([
  ...['AI', 'AR', 'CC', 'CE', 'CG', 'CL', 'CR', 'CV', 'CY', 'DB', 'DC', 'DL', 'DM', 'DS', 'ET', 'FL', 'GL', 'GR', 'GT', 'HC', 'IR', 'IT',
    'LG', 'LO', 'MA', 'MM', 'MS', 'NA', 'NE', 'NI', 'OH', 'OS', 'PF', 'PL', 'RO', 'SC', 'SD', 'SE', 'SI', 'SY'].map(c => `cs.${c}`),
  ...['EM', 'GN', 'TH'].map(c => `econ.${c}`),
  ...['AS', 'IV', 'SP', 'SY'].map(c => `eess.${c}`),
  ...['AC', 'AG', 'AP', 'AT', 'CA', 'CO', 'CT', 'CV', 'DG', 'DS', 'FA', 'GM', 'GN', 'GR', 'GT', 'HO', 'IT', 'KT', 'LO', 'MG', 'MP', 'NA', 'NT',
    'OA', 'OC', 'PR', 'QA', 'RA', 'RT', 'SG', 'SP', 'ST'].map(c => `math.${c}`),
  'astro-ph', ...['CO', 'EP', 'GA', 'HE', 'IM', 'SR'].map(c => `astro-ph.${c}`),
  'cond-mat', ...['dis-nn', 'mes-hall', 'mtrl-sci', 'other', 'quant-gas', 'soft', 'stat-mech', 'str-el', 'supr-con'].map(c => `cond-mat.${c}`),
  'gr-qc', 'hep-ex', 'hep-lat', 'hep-ph', 'hep-th', 'math-ph', 'nucl-ex', 'nucl-th', 'quant-ph',
  'nlin', ...['AO', 'CD', 'CG', 'PS', 'SI'].map(c => `nlin.${c}`),
  'physics', ...['acc-ph', 'ao-ph', 'app-ph', 'atm-clus', 'atom-ph', 'bio-ph', 'chem-ph', 'class-ph', 'comp-ph', 'data-an', 'ed-ph', 'flu-dyn',
    'gen-ph', 'geo-ph', 'hist-ph', 'ins-det', 'med-ph', 'optics', 'plasm-ph', 'pop-ph', 'soc-ph', 'space-ph'].map(c => `physics.${c}`),
  'q-bio', ...['BM', 'CB', 'GN', 'MN', 'NC', 'OT', 'PE', 'QM', 'SC', 'TO'].map(c => `q-bio.${c}`),
  ...['CP', 'EC', 'GN', 'MF', 'PM', 'PR', 'RM', 'ST', 'TR'].map(c => `q-fin.${c}`),
  ...['AP', 'CO', 'ME', 'ML', 'OT', 'TH'].map(c => `stat.${c}`),
  // Legacy subject classes (papers before the current archives).
  'acc-phys', 'adap-org', 'alg-geom', 'ao-sci', 'atom-ph', 'bayes-an', 'chao-dyn', 'chem-ph', 'cmp-lg', 'comp-gas', 'dg-ga', 'funct-an',
  'mtrl-th', 'patt-sol', 'plasm-ph', 'q-alg', 'solv-int', 'supr-con',
]);
const CATEGORY_SET = new Set(ARXIV_CATEGORIES);
export const isArxivCategory = (code: string): boolean => CATEGORY_SET.has(code);

/** The licence named by a page's "License: …" text, or null. */
export function licenseFromLabel(text: string | null | undefined): string | null {
  if (typeof text !== 'string') return null;
  const label = text.normalize('NFC').replace(/\s+/g, ' ').trim().replace(/^License:\s*/i, '');
  return ARXIV_LICENSES.find(l => l.labels.some(known => known.toLowerCase() === label.toLowerCase()))?.uri ?? null;
}
/** The licence of a DataCite rights entry (SPDX identifier, or arXiv's own URI), or null. */
export function licenseFromRights(rights: { rightsUri?: unknown; rightsIdentifier?: unknown } | null | undefined): string | null {
  if (!rights || typeof rights !== 'object') return null;
  const spdx = typeof rights.rightsIdentifier === 'string' ? rights.rightsIdentifier.toLowerCase() : null;
  if (spdx) { const hit = ARXIV_LICENSES.find(l => l.spdx === spdx); if (hit) return hit.uri; }
  if (typeof rights.rightsUri !== 'string') return null;
  const uri = rights.rightsUri.replace(/^https?:\/\//, '').replace(/legalcode$/, '').replace(/\/?$/, '/');
  return ARXIV_LICENSES.find(l => l.uri.replace(/^https?:\/\//, '') === uri)?.uri ?? null;
}

const MODERN_ID = /^([0-9]{2})([0-9]{2})\.[0-9]{4,5}$/;
const OLD_ID = /^[a-z-]+(\.[A-Z]{2})?\/[0-9]{7}$/;
export const isArxivSourceID = (id: unknown): id is string => typeof id === 'string' && id.length <= 64 && (MODERN_ID.test(id) || OLD_ID.test(id));

const CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/;
/** NFC, no controls or bidirectional overrides, whitespace collapsed (line breaks kept in abstracts). */
function text(value: unknown, field: string, max: number, multiline = false): string {
  if (typeof value !== 'string') throw new SourceMetadataError(field);
  let out = value.normalize('NFC');
  if (CONTROL.test(out.replace(/[\n\t]/g, ' '))) throw new SourceMetadataError(field);
  out = multiline ? out.replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim() : out.replace(/\s+/g, ' ').trim();
  if (!out || [...out].length > max) throw new SourceMetadataError(field);
  return out;
}
const DATE = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/;
function calendarDate(value: string): Date | null {
  const m = DATE.exec(value); if (!m) return null;
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return d.getUTCFullYear() === Number(m[1]) && d.getUTCMonth() === Number(m[2]) - 1 && d.getUTCDate() === Number(m[3]) ? d : null;
}

/** Checked and normalized, or SourceMetadataError naming the first bad field. `now` is injectable for tests. Returns
 * the record and its soft flags (kept for review, never a refusal): a v1 date whose month differs from the ID's. */
export function validateSourceMetadata(input: unknown, expected: { sourceID?: string; revision?: number } = {}, now = new Date()):
  { metadata: SourceMetadata; flags: string[] } {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new SourceMetadataError('object');
  const o = input as Record<string, unknown>;
  const keys = ['format', 'source_id', 'revision', 'origin', 'title', 'authors', 'abstract', 'categories', 'license_uri', 'version_date', 'html_available', 'observed_at'];
  for (const key of Object.keys(o)) if (!keys.includes(key)) throw new SourceMetadataError(key);
  if (o.format !== SOURCE_METADATA_FORMAT) throw new SourceMetadataError('format');
  if (!isArxivSourceID(o.source_id) || (expected.sourceID !== undefined && o.source_id !== expected.sourceID)) throw new SourceMetadataError('source_id');
  if (!Number.isSafeInteger(o.revision) || (o.revision as number) < 1 || (o.revision as number) > 9999
    || (expected.revision !== undefined && o.revision !== expected.revision)) throw new SourceMetadataError('revision');
  if (!SOURCE_METADATA_ORIGINS.includes(o.origin as SourceMetadataOrigin)) throw new SourceMetadataError('origin');
  const title = text(o.title, 'title', 2000);
  if (!Array.isArray(o.authors) || o.authors.length < 1 || o.authors.length > 512) throw new SourceMetadataError('authors');
  const authors = o.authors.map(a => text(a, 'authors', 256));
  const abstract = o.abstract === null ? null : text(o.abstract, 'abstract', 24_000, true);
  if (!Array.isArray(o.categories) || o.categories.length > 64) throw new SourceMetadataError('categories');
  const categories = o.categories.map(c => { if (typeof c !== 'string' || !isArxivCategory(c)) throw new SourceMetadataError('categories'); return c; });
  if (new Set(categories).size !== categories.length) throw new SourceMetadataError('categories');
  if (o.license_uri !== null && !ARXIV_LICENSES.some(l => l.uri === o.license_uri)) throw new SourceMetadataError('license_uri');
  let versionDate: Date | null = null;
  if (o.version_date !== null) {
    versionDate = typeof o.version_date === 'string' ? calendarDate(o.version_date) : null;
    if (!versionDate || versionDate.getTime() > now.getTime() + 86_400_000 || versionDate.getTime() < Date.UTC(1991, 7, 1)) throw new SourceMetadataError('version_date');
  }
  if (typeof o.html_available !== 'boolean') throw new SourceMetadataError('html_available');
  if (typeof o.observed_at !== 'string' || !/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$/.test(o.observed_at)) throw new SourceMetadataError('observed_at');
  const observed = Date.parse(o.observed_at);
  if (!Number.isFinite(observed) || observed > now.getTime() + 300_000) throw new SourceMetadataError('observed_at');
  const flags: string[] = [];
  const modern = MODERN_ID.exec(o.source_id as string);
  if (modern && versionDate) {
    const idMonth = Date.UTC(2000 + Number(modern[1]), Number(modern[2]) - 1, 1);
    // A version cannot predate its identifier's month; the first version's month should equal it (flag only).
    if (versionDate.getTime() < idMonth) throw new SourceMetadataError('version_date');
    if (o.revision === 1 && (versionDate.getUTCFullYear() !== 2000 + Number(modern[1]) || versionDate.getUTCMonth() !== Number(modern[2]) - 1)) flags.push('v1_month_differs');
  }
  const metadata: SourceMetadata = { format: SOURCE_METADATA_FORMAT, source_id: o.source_id as string, revision: o.revision as number,
    origin: o.origin as SourceMetadataOrigin, title, authors, abstract, categories, license_uri: o.license_uri as string | null,
    version_date: o.version_date as string | null, html_available: o.html_available, observed_at: new Date(observed).toISOString() };
  if (new TextEncoder().encode(JSON.stringify(metadata)).length > SOURCE_METADATA_MAX_BYTES) throw new SourceMetadataError('size');
  return { metadata, flags };
}

/** Title comparison for verification: case, accents' composition, punctuation and spacing don't count. */
export const comparableTitle = (title: string): string =>
  title.normalize('NFKC').toLowerCase().replace(/\$[^$]*\$/g, ' ').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
/** An author's family name for verification ("Rafailov, Rafael" and "Rafael Rafailov" both give "rafailov"). */
export const familyName = (author: string): string => {
  const name = author.normalize('NFKC').trim();
  const family = name.includes(',') ? name.split(',')[0] : name.split(/\s+/).at(-1) ?? '';
  return family.toLowerCase().replace(/[^\p{L}\p{N}-]+/gu, '');
};

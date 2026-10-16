// Server metadata only. No PDF acquisition, Storage reads/writes, rendering,
// Mathpix client or provider credentials are available in this dependency graph.
// Our servers never contact arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md, rollout step 5): an arXiv paper's catalog
// record comes from DataCite, where arXiv registers each paper's DOI (10.48550/arXiv.<id>) and its metadata.
import { arxivAbstractURL } from './arxiv.ts';
import { dataciteEvidence, dataciteRecordURL, DataCiteError, fetchDataCiteRecord, type DataCiteRecord } from './datacite.ts';
import { sha256 } from './http.ts';
import { fetchOpenAlexWork, openAlexWork, openAlexWorkURL, WebSourceError } from './web-source.ts';
import type { PipelineRPC } from './pipeline-runtime.ts';

/** The claimed paper as `worker_pipeline_claim` returns it. Only metadata-stage fields are read; retained
 * historical columns (originals, OCR attempts, artifacts) are deliberately not modelled here. */
export interface PaperEntry {
  id: string; source_id: string; requested_revision: number; stage: string; generation: number; claim_id: string; failures: number;
  /** False when the claim is only for synchronizing memberships, not a due metadata fetch. */
  due?: boolean;
  source_kind?: 'arxiv' | 'web' | 'upload';
}
export interface MetadataDeps {
  rpc: PipelineRPC;
  fetch: typeof fetch;
  sleep(ms: number): Promise<void>;
  now(): number;
  uuid(): string;
  log(event: string, fields?: Record<string, string | number | boolean | null>): void;
  /** Starts a fresh worker invocation (each gets its own CPU allowance). */
  kick?(): Promise<void>;
}
type Claim = { p_paper_id: string; p_claim_id: string; p_generation: number };
type StepResult = { entry: PaperEntry };
class PermanentFailure extends Error {
  readonly code: string; readonly resume: string | null;
  constructor(code: string, resume: string | null = null) { super(code); this.code = code; this.resume = resume; }
}
export class SourceBusy extends Error {
  readonly host: string;
  readonly retryAfterSeconds: number | null;
  constructor(host: string, retryAfterSeconds: number | null) { super('rate_limited'); this.host = host; this.retryAfterSeconds = retryAfterSeconds; }
}
/** DataCite has no record of this version yet: arXiv registers a new paper's DOI about three hours after it is announced,
 * and a new version's metadata likewise. The paper waits (its import shows its placeholder) and is asked again. */
export class NotYetListed extends Error { constructor() { super('metadata_pending'); } }
export function retryAfterSeconds(value: string | null, now: number): number | null {
  if (!value) return null;
  const seconds = /^\s*\d{1,6}\s*$/.test(value) ? Number(value) : Math.ceil((Date.parse(value) - now) / 1000);
  return Number.isFinite(seconds) && seconds >= 0 ? Math.min(seconds, 3600) : null;
}
/** Attempts before a paper DataCite doesn't list fails as `metadata_unavailable` (about 9 hours: 10, 20, … 60 minutes
 * apart); any other failure fails after 10. A failed import can be retried, and a device's record nudges it (077). */
export const PENDING_ATTEMPTS = 12;
export const pendingDelaySeconds = (failures: number) => Math.min(3600, 600 * Math.max(1, failures));

/** The licences shared reuse accepts (as `catalog_asset_approvals` and podcast rights do): CC BY 4.0 and CC0. */
const REUSABLE = new Set(['https://creativecommons.org/licenses/by/4.0/', 'https://creativecommons.org/publicdomain/zero/1.0/']);
const MAX_METADATA_BYTES = 30_000;
const calendarDay = (value: string | undefined): string | null =>
  value && /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value) && !Number.isNaN(Date.parse(`${value}T00:00:00Z`))
    && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value ? value : null;

export interface CatalogFromDataCite {
  revision: number;
  /** `worker_record_arxiv_metadata`'s shape (migration 010): dates are calendar days. */
  metadata: { title: string; authors: string[]; abstract: string | null; published_at: string | null; updated_at: string | null; categories: string[]; venue: null };
  /** What migration 077's `worker_pipeline_datacite_metadata` checks and keeps as the record's provenance. */
  evidence: { origin: 'datacite'; doi: string; source_id: string; source_revision: number; source_url: string; version: number;
    title: string; first_author: string; license_uri: string | null; evidence_url: string; evidence_format: 'datacite'; evidence_sha256: string; observed_at: string };
  /** Shared reuse: the exact version DataCite describes (its latest) under CC BY 4.0 or CC0 (the database decides again). */
  eligible: boolean;
}

/** The catalog record for one version from DataCite's record, or null when DataCite doesn't know that version yet.
 * Title, authors, abstract and categories are the latest version's (DataCite describes the latest); the dates are the
 * first version's and this version's submission days; the licence is known only for the latest version. */
export async function dataciteCatalog(record: DataCiteRecord, requested: number | null, observedAt: string): Promise<CatalogFromDataCite | null> {
  const revision = requested ?? record.version;
  if (!Number.isSafeInteger(revision) || revision < 1 || revision > record.version) return null;
  const metadata: CatalogFromDataCite['metadata'] = { title: record.title, authors: record.authors.slice(0, 512), abstract: record.abstract,
    published_at: calendarDay(record.submitted[1]), updated_at: calendarDay(record.submitted[revision]), categories: record.categories.slice(0, 64), venue: null };
  // The catalog's size bound: a very long abstract goes first, then the end of a very long author list (the first stay).
  const size = () => new TextEncoder().encode(JSON.stringify(metadata)).length;
  if (size() > MAX_METADATA_BYTES) metadata.abstract = null;
  while (size() > MAX_METADATA_BYTES && metadata.authors.length > 1) metadata.authors = metadata.authors.slice(0, Math.floor(metadata.authors.length * 0.8));
  const compared = dataciteEvidence(record);
  const exact = revision === record.version;
  const licenseURI = exact ? record.licenseURI : null;
  return { revision, metadata, eligible: exact && licenseURI !== null && REUSABLE.has(licenseURI), evidence: {
    origin: 'datacite', doi: compared.doi, source_id: record.sourceID, source_revision: revision,
    source_url: arxivAbstractURL({ sourceID: record.sourceID, revision }), version: record.version, title: compared.title,
    first_author: compared.first_author, license_uri: licenseURI, evidence_url: dataciteRecordURL(record.sourceID), evidence_format: 'datacite',
    evidence_sha256: await sha256(new TextEncoder().encode(JSON.stringify(compared))), observed_at: observedAt } };
}

const isWeb = (e: PaperEntry) => e.source_kind === 'web' || e.source_id.startsWith('openalex:');


/** Web source failures become pipeline failures; `resume` is where a user retry restarts. */
function webFailure(error: unknown, resume: string): never {
  if (error instanceof WebSourceError) throw error.permanent ? new PermanentFailure(error.code, resume) : new Error(error.code);
  throw error;
}

async function stageWebMetadata(deps: MetadataDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
  let work;
  try { work = openAlexWork(await fetchOpenAlexWork(deps.fetch, openAlexWorkURL(e.source_id))); }
  catch (error) { webFailure(error, 'metadata'); }
  if (!work) throw new PermanentFailure('metadata_unavailable', 'metadata');
  // No open-access copy: the metadata is still recorded, so readers see the paper and can supply its PDF
  // (its private papers fail at download as `not_open`; migration 039).
  const entry = await deps.rpc<PaperEntry>('worker_pipeline_web_metadata', { ...claim, p_metadata: work.metadata, p_doi: work.doi,
    p_pdf_urls: work.pdfURLs, p_landing_url: work.landingURL });
  deps.log('metadata', { paper: e.id, web: true, locations: work.pdfURLs.length });
  return { entry };
}

async function stageMetadata(deps: MetadataDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
  if (isWeb(e)) return stageWebMetadata(deps, e, claim);
  // One request to DataCite (a second after a 429 or 503, honouring Retry-After): never arXiv.
  let record: DataCiteRecord;
  try { record = await fetchDataCiteRecord(e.source_id, { fetch: deps.fetch, sleep: deps.sleep, attempts: 2 }); }
  catch (error) {
    if (error instanceof DataCiteError && error.code === 'datacite_not_found') throw new NotYetListed();
    // A record DataCite can't describe usefully (no version, title or author) names no paper we can show.
    if (error instanceof DataCiteError && (error.code === 'datacite_invalid' || error.code === 'datacite_too_large')) throw new PermanentFailure('metadata_unavailable');
    throw new SourceBusy('api.datacite.org', null);
  }
  const catalog = await dataciteCatalog(record, e.requested_revision > 0 ? e.requested_revision : null, new Date(deps.now()).toISOString());
  if (!catalog) throw new NotYetListed();
  const entry = await deps.rpc<PaperEntry>('worker_pipeline_datacite_metadata', { ...claim, p_revision: catalog.revision,
    p_metadata: catalog.metadata, p_evidence: catalog.evidence });
  deps.log('metadata', { paper: e.id, record: 'datacite', eligible: catalog.eligible, latest: catalog.revision === record.version });
  return { entry };
}


export async function runMetadataPipeline(deps: MetadataDeps, deadline: number): Promise<{ processed: number }> {
  const policy = await deps.rpc<{ enabled: boolean }>('worker_pipeline_policy', {});
  await deps.rpc('worker_expire_stale_chat_operations', {}).catch(() => deps.log('chat_sweep_failed'));
  if (!policy.enabled || deps.now() >= deadline - 30_000) return { processed: 0 };
  const paper = await deps.rpc<PaperEntry | null>('worker_pipeline_claim', { p_claim_id: deps.uuid() });
  if (!paper) return { processed: 0 };
  const claim = { p_paper_id: paper.id, p_claim_id: paper.claim_id, p_generation: paper.generation };
  try {
    if (paper.stage === 'metadata' && paper.due !== false) await stageMetadata(deps, paper, claim);
    // Existing metadata can be attached to a new source membership without
    // resuming its historical paid stage or changing an unresolved liability.
    await deps.rpc('worker_pipeline_sync_imports', claim);
    await deps.rpc('worker_pipeline_release', claim);
  } catch (error) {
    const code = error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'metadata_unavailable';
    // Which endpoint refused and how (a status or a network failure name): operators see why a source is unavailable.
    const cause = error instanceof Error && error.cause && typeof error.cause === 'object' ? error.cause as Record<string, unknown> : null;
    deps.log('metadata_error', { paper: paper.id, code, ...(cause ? { endpoint: cause.endpoint, status: cause.status ?? null, reason: cause.reason ?? null } : {}) });
    if (paper.stage === 'metadata') {
      const failures = paper.failures + 1;
      const pending = error instanceof NotYetListed;
      const fail = error instanceof PermanentFailure || failures >= (pending ? PENDING_ATTEMPTS : 10);
      const seconds = pending ? pendingDelaySeconds(failures) : error instanceof SourceBusy ? error.retryAfterSeconds ?? 60 : Math.min(600, 15 * 2 ** Math.min(failures, 6));
      await deps.rpc('worker_pipeline_defer', { ...claim, p_seconds: fail ? 0 : Math.min(seconds, 3600),
        p_error_code: fail ? 'metadata_unavailable' : code, p_fail: fail, p_resume_stage: fail ? 'metadata' : null }).catch(() => {});
    } else await deps.rpc('worker_pipeline_release', claim).catch(() => {});
  }
  if (deps.kick) await deps.kick().catch(() => deps.log('kick_failed'));
  return { processed: 1 };
}

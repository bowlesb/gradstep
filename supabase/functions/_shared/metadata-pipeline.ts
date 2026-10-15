// Server metadata only. No PDF acquisition, Storage reads/writes, rendering,
// Mathpix client or provider credentials are available in this dependency graph.
import { arxivAtomRecord, arxivCatalogArguments, arxivRawRecord, arxivReuseEvidence, arxivURLs } from './arxiv.ts';
import { SourceError } from './source-xml.ts';
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
const MiB = 1024 * 1024;
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
export function retryAfterSeconds(value: string | null, now: number): number | null {
  if (!value) return null;
  const seconds = /^\s*\d{1,6}\s*$/.test(value) ? Number(value) : Math.ceil((Date.parse(value) - now) / 1000);
  return Number.isFinite(seconds) && seconds >= 0 ? Math.min(seconds, 3600) : null;
}

/** Bounded GET restricted to arXiv hosts; follows at most three same-site redirects. */
export async function fetchArxiv(fetcher: typeof fetch, url: string, maximum: number, accept: string): Promise<Uint8Array> {
  let current = new URL(url);
  for (let hop = 0; hop < 4; hop++) {
    const metadataEndpoint = (['arxiv.org', 'export.arxiv.org', 'www.arxiv.org'].includes(current.hostname) && ['/api/query', '/oai2'].includes(current.pathname)) // egress-ok: parse
      || (current.hostname === 'oaipmh.arxiv.org' && current.pathname === '/oai'); // egress-ok: parse
    if (current.protocol !== 'https:' || current.username || current.password || current.port || !metadataEndpoint) throw new PermanentFailure('metadata_unavailable');
    let response: Response;
    // Unreachable (reset, timeout, DNS): transient, and named so a download that keeps failing says so.
    try {
      response = await fetcher(current.href, { redirect: 'manual', headers: { accept, 'user-agent': 'ScienceReader/0.1 (research paper reader; mailto:support@sciencereader.invalid)' },
        signal: AbortSignal.timeout(60_000) });
    } catch (error) { throw new Error('source_unavailable', { cause: { endpoint: current.hostname, reason: error instanceof Error ? error.name : 'fetch' } }); }
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); void response.body?.cancel().catch(() => {});
      if (!location) throw new Error('arxiv_redirect_invalid');
      current = new URL(location, current); continue;
    }
    if (response.status === 404) { void response.body?.cancel().catch(() => {}); throw new PermanentFailure('metadata_unavailable'); }
    if (response.status === 429 || response.status >= 500) {
      void response.body?.cancel().catch(() => {});
      throw new SourceBusy(current.hostname, retryAfterSeconds(response.headers.get('retry-after'), Date.now()));
    }
    if (response.status !== 200 || !response.body) { void response.body?.cancel().catch(() => {}); throw new Error('source_unavailable', { cause: { endpoint: current.hostname, status: response.status } }); }
    const declared = response.headers.get('content-length');
    if (declared && Number(declared) > maximum) { void response.body.cancel().catch(() => {}); throw new PermanentFailure('too_large'); }
    const reader = response.body.getReader(); const parts: Uint8Array[] = []; let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maximum) { void reader.cancel().catch(() => {}); throw new PermanentFailure('too_large'); }
      parts.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
    return bytes;
  }
  throw new Error('arxiv_redirect_loop');
}

export class Deferral extends Error {
  readonly seconds: number;
  constructor(seconds: number) { super('deferred'); this.seconds = seconds; }
}

/** Reserves `slots` consecutive arXiv request slots and waits for the first.
 * Returns the spacing to wait between the reserved requests. A long queue
 * reserves nothing and defers the paper (never sends early). */
async function arxivWait(deps: MetadataDeps, slots = 1): Promise<number> {
  const slot = await deps.rpc<{ reserved: boolean; wait_ms: number; spacing_ms?: number }>('worker_pipeline_arxiv_slot', { p_slots: slots, p_max_wait_ms: 45_000 });
  if (!slot.reserved) throw new Deferral(Math.ceil(slot.wait_ms / 1000));
  if (slot.wait_ms > 0) await deps.sleep(slot.wait_ms);
  return slot.spacing_ms ?? 3000;
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
  const reference = { sourceID: e.source_id, revision: e.requested_revision > 0 ? e.requested_revision : null };
  const urls = arxivURLs(reference);
  // Two arXiv requests in two reserved slots of the global pacing gate: the Atom API (catalog record) and
  // OAI-PMH arXivRaw (license evidence). When the Atom API throttles us or is unreachable, the record comes
  // from arXivRaw instead (same identity, same dates), so a paper is not held up for minutes by one busy
  // endpoint. arXivRaw itself is required: the license evidence exists nowhere else.
  const spacing = await arxivWait(deps, 2);
  const notFound = (error: unknown): never => {
    if (error instanceof SourceError && error.message === 'source_not_found') throw new PermanentFailure('metadata_unavailable');
    throw error;
  };
  let atom: Uint8Array | null = null;
  try { atom = await fetchArxiv(deps.fetch, urls.atom, MiB, 'application/atom+xml'); }
  catch (error) {
    if (!(error instanceof SourceBusy) && !(error instanceof Error && error.message === 'source_unavailable')) throw error;
    deps.log('arxiv_busy', { paper: e.id, endpoint: 'atom', fallback: 'oai' });
  }
  let fromAtom: ReturnType<typeof arxivAtomRecord> | null = null;
  if (atom) { try { fromAtom = arxivAtomRecord(atom, reference); } catch (error) { notFound(error); } }
  await deps.sleep(spacing);
  const raw = await fetchArxiv(deps.fetch, urls.raw, MiB, 'application/xml');
  const record = fromAtom ?? (() => { try { return arxivRawRecord(raw, reference); } catch (error) { return notFound(error); } })();
  const reuse = await arxivReuseEvidence(raw, record, new Date(deps.now()).toISOString());
  const args = arxivCatalogArguments(record);
  // Ineligible papers are source-only by default.  The database records the
  // observed license URL for the versioned source link, but no PDF or derived
  // asset is retained unless a separately reviewed private_permission evidence
  // reference is supplied by a trusted worker.
  const observedLicense = /<license>\s*(https?:\/\/[A-Za-z0-9.-]+\/[ -~]{0,400}?)\s*<\/license>/.exec(new TextDecoder().decode(raw))?.[1] ?? null;
  const entry = await deps.rpc<PaperEntry>('worker_pipeline_metadata', { ...claim, p_revision: record.revision, p_metadata: args.p_metadata,
    p_eligible: reuse.eligible, p_license_uri: reuse.eligible ? reuse.licenseURI : observedLicense, p_evidence: reuse.eligible ? reuse.evidence : null });
  deps.log('metadata', { paper: e.id, eligible: reuse.eligible, reason: reuse.eligible ? null : reuse.reason, record: fromAtom ? 'atom' : 'oai' });
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
    // Which endpoint refused and how (a status or a network failure name): operators see why arXiv is unavailable.
    const cause = error instanceof Error && error.cause && typeof error.cause === 'object' ? error.cause as Record<string, unknown> : null;
    deps.log('metadata_error', { paper: paper.id, code, ...(cause ? { endpoint: cause.endpoint, status: cause.status ?? null, reason: cause.reason ?? null } : {}) });
    if (paper.stage === 'metadata') {
      const failures = paper.failures + 1;
      const fail = error instanceof PermanentFailure || failures >= 10;
      const seconds = error instanceof Deferral ? error.seconds : error instanceof SourceBusy ? error.retryAfterSeconds ?? 60 : Math.min(600, 15 * 2 ** Math.min(failures, 6));
      await deps.rpc('worker_pipeline_defer', { ...claim, p_seconds: fail ? 0 : Math.min(seconds, 3600),
        p_error_code: fail ? 'metadata_unavailable' : code, p_fail: fail, p_resume_stage: fail ? 'metadata' : null }).catch(() => {});
    } else await deps.rpc('worker_pipeline_release', claim).catch(() => {});
  }
  if (deps.kick) await deps.kick().catch(() => deps.log('kick_failed'));
  return { processed: 1 };
}

// Paper pipeline stages driven by the `paper-worker` Edge function. Every
// database transition is fenced by the claim (paper, claim id, generation)
// returned by worker_pipeline_claim; see migration 014. Dependencies are
// injected so Node tests can drive the stages with fakes.
import { PDFDocument } from 'pdf-lib';
import { arxivAtomRecord, arxivCatalogArguments, arxivReuseEvidence, arxivURLs } from './arxiv.ts';
import { unpackReaderZip } from './archive.ts';
import { uploadInventoried } from './asset-upload.ts';
import { sha256 } from './http.ts';
import { MathpixError, mathpixProfile, type MathpixConversion, type MathpixStatus, type MathpixSubmission } from './mathpix.ts';
import { SourceError } from './source-xml.ts';
import { downloadLocations, fetchFirstWebPDF, fetchOpenAlexWork, openAlexWork, openAlexWorkURL, WebSourceError, type ResolveHost } from './web-source.ts';

export const BUCKET = 'paper-assets';
export const RAW_FORMAT = 'science-reader-mathpix-raw-v1';
const MiB = 1024 * 1024;
const URL_SUBMISSION_BYTES = 8 * MiB;

export class PipelineRPCError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; }
}
/** A failure that retrying cannot fix. `resume` names the stage a user retry restarts. */
export class PermanentFailure extends Error {
  readonly code: string; readonly resume: string | null;
  constructor(code: string, resume: string | null = null) { super(code); this.code = code; this.resume = resume; }
}

export interface PaperEntry {
  id: string; owner_id?: string | null; source_id: string; requested_revision: number; revision: number | null; stage: string;
  generation: number; claim_id: string; state_revision: number; failures: number;
  document_id: string | null; document_sha256: string | null; original_path: string | null; original_bytes: number | null; page_count: number | null;
  due?: boolean; raw_manifest_path?: string | null; ocr_run_id?: string | null;
  license_uri?: string | null; title?: string | null; authors?: string[] | null;
  /** Web papers (migration 019): OpenAlex source ID, open-access PDF locations, landing page. */
  source_kind?: 'arxiv' | 'web' | 'upload'; pdf_urls?: string[] | null; landing_url?: string | null;
  /** A reader's PDF this private paper uses at download (migration 039): their own upload, or one
   * supplying a web paper our servers couldn't fetch. Declared size and sha256 (hex). */
  upload?: { id: string; generation: number; sha256: string; bytes: number; parts: number } | null;
  attempt: null | { id: string; state: string; page_limit: number; provider_job_id: string | null; submitted_at: string | null; raw_manifest_path: string | null };
}
export interface PipelinePolicy { max_pdf_bytes: number; max_ocr_pages: number; renderer_version: string; enabled: boolean }

export interface RenderInput {
  /** Complete expanded mmd.zip, keyed by archive path. */
  archive: Map<string, Uint8Array>;
  provenance: { ocr: { api: 'v3/pdf'; profile: string; options_sha256: string }; provider_job_id: string; document: { sha256: string; page_count: number } };
  attribution?: string;
  titleFallback?: string;
}
export interface RenderedBundle { manifestBytes: Uint8Array; manifestSHA256: string; members: Map<string, Uint8Array> }

export interface MathpixPort {
  submitOnce(pdf: Uint8Array, checkpoint: { attemptID: string; documentSHA256: string; optionsSHA256: string; pageLimit?: number }): Promise<MathpixSubmission>;
  submitURL(url: string, checkpoint: { attemptID: string; optionsSHA256: string; pageLimit?: number }): Promise<MathpixSubmission>;
  status(id: string): Promise<MathpixStatus>;
  conversion(id: string): Promise<MathpixConversion>;
  output(status: MathpixStatus, format: 'mmd' | 'mmd.zip' | 'lines.json', conversion?: MathpixConversion): Promise<Uint8Array>;
}

export interface PipelineDeps {
  rpc<T>(name: string, params: Record<string, unknown>): Promise<T>;
  storage: {
    upload(path: string, bytes: Uint8Array, contentType: string): Promise<void>;
    download(path: string, maximumBytes: number): Promise<Uint8Array>;
    signedURL(path: string, seconds: number): Promise<string>;
  };
  fetch: typeof fetch;
  mathpix: MathpixPort;
  render(input: RenderInput): Promise<RenderedBundle>;
  sleep(ms: number): Promise<void>;
  now(): number;
  uuid(): string;
  log(event: string, fields?: Record<string, string | number | boolean | null>): void;
  /** Starts a fresh worker invocation (each gets its own CPU allowance). */
  kick?(): Promise<void>;
  /** Resolves a web PDF host so private and reserved addresses are refused. */
  resolveHost?: ResolveHost;
  /** Readers' uploads (`paper-uploads` bucket, migration 039). Absent: an upload waits for a worker that has it. */
  uploads?: {
    /** Throws `storage_object_missing` when the object isn't there. */
    download(path: string, maximumBytes: number, observed?: (bytes: number) => void): Promise<Uint8Array>;
    remove(paths: string[]): Promise<void>;
  };
}

const hex = (value: string) => '\\x' + value;
const encoder = new TextEncoder();

function canonical(value: unknown): string {
  const order = (v: unknown): unknown => Array.isArray(v) ? v.map(order) : v && typeof v === 'object'
    ? Object.fromEntries(Object.keys(v as Record<string, unknown>).sort().map(k => [k, order((v as Record<string, unknown>)[k])])) : v;
  return JSON.stringify(order(value)) + '\n';
}

export function contentType(path: string): string {
  const ext = path.slice(path.lastIndexOf('.') + 1).toLowerCase();
  return ({ json: 'application/json', html: 'text/html; charset=utf-8', css: 'text/css; charset=utf-8', txt: 'text/plain; charset=utf-8',
    png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', mmd: 'text/plain; charset=utf-8', zip: 'application/zip', pdf: 'application/pdf' } as Record<string, string>)[ext]
    ?? 'application/octet-stream';
}

/** Bounded GET restricted to arXiv hosts; follows at most three same-site redirects. */
export async function fetchArxiv(fetcher: typeof fetch, url: string, maximum: number, accept: string): Promise<Uint8Array> {
  let current = new URL(url);
  for (let hop = 0; hop < 4; hop++) {
    if (current.protocol !== 'https:' || !['arxiv.org', 'export.arxiv.org', 'oaipmh.arxiv.org', 'www.arxiv.org'].includes(current.hostname)) throw new PermanentFailure('download_failed', 'download');
    let response: Response;
    // Unreachable (reset, timeout, DNS): transient, and named so a download that keeps failing says so.
    try {
      response = await fetcher(current.href, { redirect: 'manual', headers: { accept, 'user-agent': 'ScienceReader/0.1 (research paper reader; mailto:support@sciencereader.invalid)' },
        signal: AbortSignal.timeout(60_000) });
    } catch { throw new Error('source_unavailable'); }
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location'); void response.body?.cancel().catch(() => {});
      if (!location) throw new Error('arxiv_redirect_invalid');
      current = new URL(location, current); continue;
    }
    if (response.status === 404) { void response.body?.cancel().catch(() => {}); throw new PermanentFailure('metadata_unavailable'); }
    if (response.status === 429 || response.status >= 500) { void response.body?.cancel().catch(() => {}); throw new Error('rate_limited'); }
    if (response.status !== 200 || !response.body) { void response.body?.cancel().catch(() => {}); throw new Error('download_failed'); }
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

export async function countPages(bytes: Uint8Array): Promise<number> {
  if (bytes.length < 8 || new TextDecoder().decode(bytes.subarray(0, 5)) !== '%PDF-') throw new PermanentFailure('pdf_invalid');
  try {
    const document = await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false, throwOnInvalidObject: false });
    const pages = document.getPageCount();
    if (!Number.isSafeInteger(pages) || pages < 1) throw new Error();
    return pages;
  } catch { throw new PermanentFailure('pdf_invalid'); }
}

type Claim = { p_paper_id: string; p_claim_id: string; p_generation: number };
/** `defer` (seconds) releases the claim with a delay after syncing imports. */
type StepResult = { entry: PaperEntry; stop?: 'release'; defer?: number };

/** Readers' progress is refreshed at most this often per paper (the server throttles each import alike). */
export const PROGRESS_INTERVAL_MS = 5_000;
/** When each claim last told readers something: its stage projection, or a progress report. */
const progressReported = new WeakMap<Claim, number>();

/** Tells the readers waiting on this paper what the worker sees of the current stage (the provider's pages,
 * the PDF's size and pages; migration 029). Best effort: at most every 5 s, starting 5 s after the stage was
 * projected, and a failure never affects the stage. */
async function reportProgress(deps: PipelineDeps, claim: Claim, seen: { pagesDone?: number | null; pages?: number | null; bytes?: number | null }): Promise<void> {
  const last = progressReported.get(claim);
  if (last !== undefined && deps.now() - last < PROGRESS_INTERVAL_MS) return;
  progressReported.set(claim, deps.now());
  try {
    await deps.rpc('worker_pipeline_progress', { ...claim, p_pages_done: seen.pagesDone ?? null, p_pages: seen.pages ?? null, p_bytes: seen.bytes ?? null });
  } catch (error) {
    deps.log('progress_failed', { paper: claim.p_paper_id, code: error instanceof PipelineRPCError ? error.code : 'unknown' });
  }
}

/** Not a failure: the paper is simply not due yet (e.g. arXiv pacing). */
export class Deferral extends Error {
  readonly seconds: number;
  constructor(seconds: number) { super('deferred'); this.seconds = seconds; }
}

/** Reserves `slots` consecutive arXiv request slots and waits for the first.
 * Returns the spacing to wait between the reserved requests. A long queue
 * reserves nothing and defers the paper (never sends early). */
async function arxivWait(deps: PipelineDeps, slots = 1): Promise<number> {
  const slot = await deps.rpc<{ reserved: boolean; wait_ms: number; spacing_ms?: number }>('worker_pipeline_arxiv_slot', { p_slots: slots, p_max_wait_ms: 45_000 });
  if (!slot.reserved) throw new Deferral(Math.ceil(slot.wait_ms / 1000));
  if (slot.wait_ms > 0) await deps.sleep(slot.wait_ms);
  return slot.spacing_ms ?? 3000;
}

async function stageSplit(deps: PipelineDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
  const moved = await deps.rpc<number>('worker_pipeline_split_private', claim);
  deps.log('private_split', { paper: e.id, moved });
  return { entry: e, stop: 'release' };
}

const isWeb = (e: PaperEntry) => e.source_kind === 'web' || e.source_id.startsWith('openalex:');
const isUpload = (e: PaperEntry) => e.source_kind === 'upload' || e.source_id.startsWith('upload:');

/** Web source failures become pipeline failures; `resume` is where a user retry restarts. */
function webFailure(error: unknown, resume: string): never {
  if (error instanceof WebSourceError) throw error.permanent ? new PermanentFailure(error.code, resume) : new Error(error.code);
  throw error;
}

async function stageWebMetadata(deps: PipelineDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
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

async function stageMetadata(deps: PipelineDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
  if (isWeb(e)) return stageWebMetadata(deps, e, claim);
  const reference = { sourceID: e.source_id, revision: e.requested_revision > 0 ? e.requested_revision : null };
  const urls = arxivURLs(reference);
  const spacing = await arxivWait(deps, 2);
  const atom = await fetchArxiv(deps.fetch, urls.atom, MiB, 'application/atom+xml');
  let record;
  try { record = arxivAtomRecord(atom, reference); }
  catch (error) { if (error instanceof SourceError && error.message === 'source_not_found') throw new PermanentFailure('metadata_unavailable'); throw error; }
  await deps.sleep(spacing);
  const raw = await fetchArxiv(deps.fetch, urls.raw, MiB, 'application/xml');
  const reuse = await arxivReuseEvidence(raw, record, new Date(deps.now()).toISOString());
  const args = arxivCatalogArguments(record);
  // Ineligible papers are converted privately; keep the observed license URL
  // (validated server-side) as the private pin's provenance.
  const observedLicense = /<license>\s*(https?:\/\/[A-Za-z0-9.-]+\/[ -~]{0,400}?)\s*<\/license>/.exec(new TextDecoder().decode(raw))?.[1] ?? null;
  const entry = await deps.rpc<PaperEntry>('worker_pipeline_metadata', { ...claim, p_revision: record.revision, p_metadata: args.p_metadata,
    p_eligible: reuse.eligible, p_license_uri: reuse.eligible ? reuse.licenseURI : observedLicense, p_evidence: reuse.eligible ? reuse.evidence : null });
  deps.log('metadata', { paper: e.id, eligible: reuse.eligible, reason: reuse.eligible ? null : reuse.reason });
  return { entry };
}

/** Web downloads are bounded well inside the claim's lease (180 s, renewed by
 * admission) and the invocation's deadline. */
const WEB_DOWNLOAD_MS = 110_000;

/** A reader's upload as this paper's original: exactly the bytes they declared, a readable PDF of at
 * most 250 pages. Anything else spends the upload (a retry won't read the same bad bytes again) and
 * fails the paper; a missing worker storage adapter or a transient Storage error is retried. */
async function readUpload(deps: PipelineDeps, e: PaperEntry, claim: Claim, policy: PipelinePolicy): Promise<{ bytes: Uint8Array; pages: number }> {
  const upload = e.upload!;
  if (!deps.uploads) throw new Error('upload_storage_unavailable');
  const reject = async (code: string): Promise<never> => {
    await deps.rpc('worker_pipeline_upload_rejected', { ...claim, p_upload_id: upload.id });
    deps.log('upload_rejected', { paper: e.id, code });
    throw new PermanentFailure(code, 'download');
  };
  if (upload.bytes < 1 || upload.bytes > policy.max_pdf_bytes || upload.bytes > 67_108_864 ||
      !Number.isSafeInteger(upload.generation) || upload.generation < 1 || !Number.isSafeInteger(upload.parts) || upload.parts < 1 || upload.parts > 16)
    throw new Error('invalid_upload_descriptor');
  const readID = deps.uuid();
  const admitted = await deps.rpc<{ read: boolean; objects: { index: number; id: string; bucket: string; path: string; bytes: number; sha256: string }[] }>(
    'worker_pdf_upload_read', { ...claim, p_read_id: readID, p_upload_id: upload.id, p_upload_generation: upload.generation });
  if (!admitted?.read) throw new Error('upload_read_not_admitted');
  if (!Array.isArray(admitted.objects) || admitted.objects.length !== upload.parts || admitted.objects.some((o, index) => o.index !== index ||
      o.bucket !== 'paper-uploads' || !o.path.startsWith(`${e.owner_id}/${upload.id}/${index}/`) ||
      !/^[0-9a-f-]{36}\/[0-9a-f-]{36}\/(?:[0-9]|1[0-5])\/[0-9a-f-]{36}\.chunk$/.test(o.path) ||
      o.bytes !== Math.min(4_194_304, upload.bytes - index * 4_194_304) || !/^[0-9a-f]{64}$/.test(o.sha256)))
    throw new Error('invalid_upload_descriptor');
  const bytes = new Uint8Array(upload.bytes); let offset = 0, observed = 0;
  try {
    for (const object of admitted.objects) {
      let received = 0;
      try {
        const part = await deps.uploads.download(object.path, object.bytes, count => { received = Math.min(count, object.bytes); });
        received = Math.min(part.length, object.bytes);
        if (part.length !== object.bytes || await sha256(part) !== object.sha256) return await reject('upload_failed');
        bytes.set(part, offset); offset += part.length;
      } finally { observed += received; }
    }
  } catch (error) {
    if (error instanceof Error && ['storage_object_missing', 'storage_object_too_large'].includes(error.message)) return reject('upload_failed');
    throw error;
  } finally {
    await deps.rpc('worker_pdf_upload_read_observed', { p_read_id: readID, p_bytes: observed }).catch(() => {});
  }
  if (bytes.length !== upload.bytes || await sha256(bytes) !== upload.sha256) return reject('upload_failed');
  let pages: number;
  try { pages = await countPages(bytes); } catch { return reject('pdf_invalid'); }
  if (pages > 250) return reject('too_large');
  return { bytes, pages };
}

async function stageDownload(deps: PipelineDeps, e: PaperEntry, claim: Claim, policy: PipelinePolicy, deadline = Infinity): Promise<StepResult> {
  if (!e.revision) throw new Error('revision_missing');
  const webBudget = Math.min(WEB_DOWNLOAD_MS, deadline - deps.now() - 45_000);
  // Not enough time left in this invocation: start the download in a fresh one.
  if (isWeb(e) && !e.upload && webBudget < 30_000) return { entry: e, defer: 0 };
  // Storage caps and (for private copies) owner credits are checked before
  // any bytes are fetched or stored.
  const admission = await deps.rpc<{ admitted: boolean; reason?: string; upload?: PaperEntry['upload'] }>('worker_pipeline_admit_download', claim);
  if (!admission.admitted) {
    deps.log('download_not_admitted', { paper: e.id, reason: admission.reason ?? null });
    return { entry: e, stop: 'release' };
  }
  // The claim snapshot can predate an attachment/cancellation. Only the
  // admission transaction's committed selection decides which bytes to read.
  if ('upload' in admission) e = { ...e, upload: admission.upload ?? null };
  else if (e.upload) throw new Error('upload_admission_unavailable');
  let bytes: Uint8Array;
  let counted: number | null = null;
  if (e.upload) {
    if (!e.owner_id) throw new Error('upload_owner_missing');
    ({ bytes, pages: counted } = await readUpload(deps, e, claim, policy));
    deps.log('upload_read', { paper: e.id, bytes: bytes.length, web: isWeb(e) });
  } else if (isUpload(e)) {
    // An uploaded paper whose upload is gone (rejected or expired): a new upload can supply it.
    throw new PermanentFailure('upload_failed', 'download');
  } else if (isWeb(e)) {
    if (!e.owner_id) throw new Error('web_location_missing');
    const budget = AbortSignal.timeout(webBudget);
    // Locations move: re-read them from OpenAlex (falling back to the recorded ones).
    let urls = e.pdf_urls ?? [];
    try {
      const fresh = downloadLocations(await fetchOpenAlexWork(deps.fetch, openAlexWorkURL(e.source_id)));
      if (fresh.length && fresh.join('\n') !== urls.join('\n')) {
        urls = (await deps.rpc<PaperEntry>('worker_pipeline_web_locations', { ...claim, p_pdf_urls: fresh })).pdf_urls ?? fresh;
        deps.log('web_locations', { paper: e.id, locations: urls.length });
      } else await deps.rpc('worker_pipeline_heartbeat', claim);
    } catch (error) {
      if (!(error instanceof WebSourceError)) throw error;
      await deps.rpc('worker_pipeline_heartbeat', claim);
    }
    // No open copy anywhere: the reader can supply the PDF (upload, or download it on their device).
    if (!urls.length) throw new PermanentFailure('not_open', 'download');
    try {
      const found = await fetchFirstWebPDF(deps.fetch, urls, policy.max_pdf_bytes, deps.resolveHost, budget);
      bytes = found.bytes;
      deps.log('web_download', { paper: e.id, location: urls.indexOf(found.url) });
    } catch (error) { webFailure(error, 'download'); }
  } else {
    await arxivWait(deps);
    bytes = await fetchArxiv(deps.fetch, `https://arxiv.org/pdf/${e.source_id}v${e.revision}`, policy.max_pdf_bytes, 'application/pdf');
  }
  const pages = counted ?? await countPages(bytes);
  if (pages > 250) throw new PermanentFailure('too_large');
  // A slow download: readers see the size and pages while the copy is stored.
  await reportProgress(deps, claim, { pages, bytes: bytes.length });
  const digest = await sha256(bytes);
  const path = `${e.owner_id ? `private/${e.owner_id}/` : ''}originals/${digest}.pdf`;
  await uploadInventoried(deps, claim, 'original', [{ path, bytes, mediaType: 'application/pdf' }], pages);
  const original = { ...claim, p_sha256: hex(digest), p_bytes: bytes.length, p_pages: pages, p_path: path };
  const entry = e.upload
    ? await deps.rpc<PaperEntry>('worker_pipeline_upload_original', { ...original, p_upload_id: e.upload.id })
    : await deps.rpc<PaperEntry>('worker_pipeline_original', original);
  deps.log('original', { paper: e.id, bytes: bytes.length, pages, stage: entry.stage, upload: !!e.upload });
  // Terminal-only batch cleanup runs separately; an old uncertain chunk PUT can still be in flight.
  return { entry };
}

export async function ocrIdentity(documentSHA256: string, pageLimit: number): Promise<{ optionsSHA256: string; requestSHA256: string }> {
  const profile = await mathpixProfile(pageLimit);
  return { optionsSHA256: profile.sha256, requestSHA256: await sha256(encoder.encode(`science-reader/ocr-request/v1\n${documentSHA256}\n${profile.sha256}`)) };
}

async function stageFund(deps: PipelineDeps, e: PaperEntry, claim: Claim, policy: PipelinePolicy): Promise<StepResult> {
  await deps.rpc('worker_pipeline_admit_processing', claim);
  if (!e.page_count || !e.document_sha256) throw new Error('document_missing');
  const pageLimit = Math.min(e.page_count, policy.max_ocr_pages);
  const identity = await ocrIdentity(e.document_sha256, pageLimit);
  const entry = await deps.rpc<PaperEntry & { funding: string }>('worker_pipeline_fund', { ...claim, p_page_limit: pageLimit,
    p_options_sha256: hex(identity.optionsSHA256), p_request_sha256: hex(identity.requestSHA256) });
  deps.log('fund', { paper: e.id, funding: entry.funding, page_limit: pageLimit });
  return { entry, stop: entry.funding === 'waiting' || entry.funding === 'paused' ? 'release' : undefined };
}

const SUBMIT_HEADROOM_MS = 90_000;

async function recordSubmission(deps: PipelineDeps, attemptID: string, result: MathpixSubmission): Promise<PaperEntry> {
  const params = { p_attempt_id: attemptID, p_provider_job_id: result.state === 'accepted' ? result.providerJobID : null,
    p_uncertain_reason: result.state === 'accepted' ? null : result.reason };
  // Keyed by attempt (not lease). Retry: losing this record would make a billed
  // job look uncertain.
  for (let attempt = 0; ; attempt++) {
    try { return await deps.rpc<PaperEntry>('worker_pipeline_submitted', params); }
    catch (error) { if (attempt >= 4) throw error; await deps.sleep(1000 * 2 ** attempt); }
  }
}

async function stageSubmit(deps: PipelineDeps, e: PaperEntry, claim: Claim, _policy: PipelinePolicy, deadline: number): Promise<StepResult> {
  if (!e.attempt || !e.original_path || !e.document_sha256) throw new Error('attempt_missing');
  const pageLimit = e.attempt.page_limit;
  const identity = await ocrIdentity(e.document_sha256, pageLimit);
  // Prepare everything that can fail BEFORE the single grant, so a grant is
  // followed immediately by the POST, with time left to record its result.
  let pdf: Uint8Array | null = null, url: string | null = null;
  if ((e.original_bytes ?? 0) > URL_SUBMISSION_BYTES) url = await deps.storage.signedURL(e.original_path, 3600);
  else {
    pdf = await deps.storage.download(e.original_path, 64 * MiB);
    if (await sha256(pdf) !== e.document_sha256) throw new Error('original_integrity');
  }
  if (deadline - deps.now() < SUBMIT_HEADROOM_MS) return { entry: e, defer: 0 };
  const grant = await deps.rpc<PaperEntry & { granted: boolean; attempt_id?: string }>('worker_pipeline_begin_submit', claim);
  if (!grant.granted || !grant.attempt_id) { deps.log('submit_not_granted', { paper: e.id, stage: grant.stage }); return { entry: grant }; }
  const checkpoint = { attemptID: grant.attempt_id, optionsSHA256: identity.optionsSHA256, pageLimit };
  let result: MathpixSubmission;
  try {
    result = pdf ? await deps.mathpix.submitOnce(pdf, { ...checkpoint, documentSHA256: e.document_sha256 }) : await deps.mathpix.submitURL(url!, checkpoint);
  } catch (error) {
    result = { state: 'submission_uncertain', reason: error instanceof MathpixError ? error.code : 'provider_transport_failed' };
  }
  deps.log('submitted', { paper: e.id, attempt: grant.attempt_id, accepted: result.state === 'accepted',
    provider_job_id: result.state === 'accepted' ? result.providerJobID : null });
  return { entry: await recordSubmission(deps, grant.attempt_id, result) };
}

// Provider errors that retrying the same job cannot fix.
const UNUSABLE_OUTPUT = new Set(['provider_body_limit', 'provider_output_invalid', 'provider_response_incomplete', 'provider_page_count_invalid']);
const PROVIDER_TIMEOUT_MS = 6 * 3600_000;

async function stageWait(deps: PipelineDeps, e: PaperEntry, claim: Claim, _policy?: PipelinePolicy, deadline = 0): Promise<StepResult> {
  const waitUntil = Math.min(deps.now() + 90_000, deadline - 60_000);
  const job = e.attempt?.provider_job_id;
  if (!job || !e.document_sha256 || !e.attempt) throw new Error('attempt_missing');
  const age = e.attempt.submitted_at ? deps.now() - Date.parse(e.attempt.submitted_at) : 0;
  const fail = async (code: string, pages: number) => {
    deps.log('ocr_failed', { paper: e.id, code, pages });
    return { entry: await deps.rpc<PaperEntry>('worker_pipeline_ocr_failed', { ...claim, p_error_code: code, p_pages_billed: Math.min(pages, e.attempt!.page_limit) }) };
  };
  const uncertain = async (code: string) => {
    deps.log('ocr_usage_uncertain', { paper: e.id, code, provider_job_id: job });
    return { entry: await deps.rpc<PaperEntry>('worker_pipeline_ocr_uncertain', { ...claim, p_error_code: code }) };
  };
  // Local age and missing status never prove that remote work stopped or was
  // free. Preserve the known job and full liability until reconciliation.
  let missing = false;
  const poll = async () => {
    try { return await deps.mathpix.status(job); }
    catch (error) {
      if (error instanceof MathpixError && [404, 410].includes(error.httpStatus ?? 0)) { missing = true; return null; }
      if (age > PROVIDER_TIMEOUT_MS) return null;
      throw error;
    }
  };
  // Polling is I/O, not CPU: wait in this invocation for up to ~90 s.
  let polled = await poll();
  for (let polls = 0; polled && polls < 22 && !['completed', 'error'].includes(polled.state) && deps.now() < waitUntil; polls++) {
    await reportProgress(deps, claim, { pagesDone: polled.completedPages, pages: polled.pages });
    await deps.sleep(4000); polled = await poll();
  }
  if (!polled) return uncertain(missing ? 'provider_job_missing' : 'provider_status_unknown');
  const status = polled;
  await deps.rpc('worker_pipeline_heartbeat', claim);
  if (status.state === 'error') return uncertain('provider_usage_unknown');
  if (status.deleted) return uncertain('provider_job_missing');
  if (status.state !== 'completed') return age > PROVIDER_TIMEOUT_MS ? uncertain('conversion_timeout') : { entry: e, defer: age > 120_000 ? 15 : 4 };
  let conversion: MathpixConversion;
  try { conversion = await deps.mathpix.conversion(job); }
  catch (error) { if (age > PROVIDER_TIMEOUT_MS) return uncertain('provider_status_unknown'); throw error; }
  if (conversion.state === 'error') return uncertain('provider_usage_unknown');
  if (conversion.state !== 'completed') return age > PROVIDER_TIMEOUT_MS ? uncertain('conversion_timeout') : { entry: e, defer: 4 };
  let members: Map<string, Uint8Array>;
  try {
    members = new Map<string, Uint8Array>([
      ['standalone.mmd', await deps.mathpix.output(status, 'mmd')],
      ['output.mmd.zip', await deps.mathpix.output(status, 'mmd.zip', conversion)],
      ['lines.json', await deps.mathpix.output(status, 'lines.json')],
    ]);
  } catch (error) {
    if (error instanceof MathpixError && UNUSABLE_OUTPUT.has(error.code)) return fail('conversion_failed', e.attempt.page_limit);
    throw error;
  }
  let processed: number;
  try {
    const lines = JSON.parse(new TextDecoder().decode(members.get('lines.json')!)) as { pages?: unknown[] };
    processed = Array.isArray(lines.pages) ? lines.pages.length : 0;
  } catch { processed = 0; }
  const pages = Math.max(1, Math.min(processed || (status.pages ?? e.attempt.page_limit), e.attempt.page_limit, 250));
  const identity = await ocrIdentity(e.document_sha256, e.attempt.page_limit);
  const memberIdentity: Record<string, { bytes: number; sha256: string }> = {};
  for (const [name, bytes] of members) memberIdentity[name] = { bytes: bytes.length, sha256: await sha256(bytes) };
  const manifestBytes = encoder.encode(canonical({ format: RAW_FORMAT, provider: 'mathpix', provider_job_id: job, api: 'v3/pdf',
    options_sha256: identity.optionsSHA256, page_limit: e.attempt.page_limit, pages, document_sha256: e.document_sha256,
    status: { pages: status.pages, completed_pages: status.completedPages, pipeline_version: status.pipelineVersion }, members: memberIdentity }));
  const manifestSHA = await sha256(manifestBytes);
  await uploadInventoried(deps, claim, 'raw', [...members].map(([name, bytes]) => ({ path: `raw/${manifestSHA}/${name}`, bytes, mediaType: contentType(name) }))
    .concat([{ path: `raw/${manifestSHA}/manifest.json`, bytes: manifestBytes, mediaType: 'application/json' }]));
  const entry = await deps.rpc<PaperEntry>('worker_pipeline_collected', { ...claim, p_pages_reported: pages,
    p_raw_manifest_sha256: hex(manifestSHA), p_raw_manifest_bytes: manifestBytes.length });
  deps.log('collected', { paper: e.id, pages, mmd_bytes: members.get('standalone.mmd')!.length });
  return { entry };
}

export async function loadRaw(deps: PipelineDeps, manifestPath: string): Promise<{ manifest: Record<string, unknown>; manifestSHA: string; members: Map<string, Uint8Array> }> {
  const manifestBytes = await deps.storage.download(manifestPath, 256 * 1024);
  const manifestSHA = await sha256(manifestBytes);
  if (manifestPath !== `raw/${manifestSHA}/manifest.json`) throw new PermanentFailure('raw_integrity', 'render');
  const manifest = JSON.parse(new TextDecoder().decode(manifestBytes)) as Record<string, unknown>;
  if (manifest.format !== RAW_FORMAT) throw new PermanentFailure('raw_integrity', 'render');
  const members = new Map<string, Uint8Array>();
  for (const [name, id] of Object.entries(manifest.members as Record<string, { bytes: number; sha256: string }>)) {
    const bytes = await deps.storage.download(`raw/${manifestSHA}/${name}`, 64 * MiB);
    if (bytes.length !== id.bytes || await sha256(bytes) !== id.sha256) throw new PermanentFailure('raw_integrity', 'render');
    members.set(name, bytes);
  }
  return { manifest, manifestSHA, members };
}

/** The reader bundle's attribution (its NOTICE): the paper, its license or private status, and where the
 * original is. A reader's own upload names no original link. */
export function readerAttribution(e: PaperEntry): string {
  const web = isWeb(e), uploaded = isUpload(e);
  const original = web ? e.landing_url ?? `https://openalex.org/works/${e.source_id.slice('openalex:'.length)}` : `https://arxiv.org/abs/${e.source_id}v${e.revision}`;
  const source = web ? null : `arXiv:${e.source_id}v${e.revision}`;
  const byline = e.authors?.length ? ` by ${e.authors.slice(0, 8).join(', ')}${e.authors.length > 8 ? ' et al.' : ''}` : '';
  const credit = e.title ? `"${e.title}"${byline}${source ? `, ${source}` : ''}` : source ?? original;
  if ((web || uploaded) && !e.owner_id) throw new PermanentFailure('render_failed', 'render');
  return uploaded
    ? `${e.title ? `"${e.title}"` : 'A PDF'} uploaded by its reader. Converted for the personal use of one Gradstep account; not redistributed.`
    : e.owner_id
    ? `${credit}. Converted for the personal use of one Gradstep account; not redistributed. Original: ${original}`
    : `${credit}. Licensed under ${e.license_uri ?? 'its arXiv license'}. Converted to an equation-aware reading format by Gradstep (layout and math rendering changed). Original: ${original}`;
}

async function stageRender(deps: PipelineDeps, e: PaperEntry, claim: Claim, policy: PipelinePolicy): Promise<StepResult> {
  const path = e.raw_manifest_path ?? e.attempt?.raw_manifest_path;
  if (!path || !e.document_sha256 || !e.revision) throw new Error('raw_missing');
  const raw = await loadRaw(deps, path);
  let files;
  try { files = await unpackReaderZip(raw.members.get('output.mmd.zip')!); }
  catch { throw new PermanentFailure('render_failed', 'render'); }
  if (files.filter(f => f.path.toLowerCase().endsWith('.mmd')).length !== 1) throw new PermanentFailure('render_failed', 'render');
  const m = raw.manifest as { provider_job_id: string; options_sha256: string; page_limit: number; pages: number };
  const attribution = readerAttribution(e);
  let bundle: RenderedBundle;
  try {
    bundle = await deps.render({ archive: new Map(files.map(f => [f.path, f.bytes])), attribution, titleFallback: e.title ?? undefined,
      provenance: { ocr: { api: 'v3/pdf', profile: 'science-reader-mmd-v1', options_sha256: m.options_sha256 }, provider_job_id: m.provider_job_id,
        document: { sha256: e.document_sha256, page_count: Math.min(e.page_count ?? m.pages, 250) } } });
  } catch (error) {
    deps.log('render_failed', { paper: e.id, code: error instanceof Error ? error.message.slice(0, 80) : 'unknown' });
    throw new PermanentFailure('render_failed', 'render');
  }
  if (await sha256(bundle.manifestBytes) !== bundle.manifestSHA256) throw new Error('bundle_integrity');
  await uploadInventoried(deps, claim, 'reader', [...bundle.members].map(([name, bytes]) => ({ path: `reader/${bundle.manifestSHA256}/${name}`, bytes, mediaType: contentType(name) }))
    .concat([{ path: `reader/${bundle.manifestSHA256}/manifest.json`, bytes: bundle.manifestBytes, mediaType: 'application/json' }]));
  const entry = await deps.rpc<PaperEntry>('worker_pipeline_published', { ...claim, p_manifest_sha256: hex(bundle.manifestSHA256),
    p_manifest_bytes: bundle.manifestBytes.length, p_renderer_version: policy.renderer_version });
  deps.log('published', { paper: e.id, members: bundle.members.size });
  return { entry };
}

const TERMINAL = new Set(['done', 'source_only', 'failed', 'needs_credits', 'ocr_uncertain']);

export async function processPaper(deps: PipelineDeps, claimed: PaperEntry, policy: PipelinePolicy, deadline: number): Promise<void> {
  const claim: Claim = { p_paper_id: claimed.id, p_claim_id: claimed.claim_id, p_generation: claimed.generation };
  const sync = async () => {
    // Per-import failures back off inside the RPC; never a stage failure.
    try { await deps.rpc('worker_pipeline_sync_imports', claim); }
    catch (error) { deps.log('sync_failed', { paper: claimed.id, code: error instanceof PipelineRPCError ? error.code : 'unknown' }); }
    // A stage projection carries a fresh progress detail; reports wait 5 s from here.
    progressReported.set(claim, deps.now());
  };
  let entry = claimed;
  let projected: string | null = null;
  try {
    // A paper claimed only to project imports runs no stage work.
    for (let step = 0; step < 8 && claimed.due !== false && !TERMINAL.has(entry.stage); step++) {
      if (deps.now() > deadline - 30_000) break;
      const before = entry.stage;
      // Show each stage to the readers waiting on it as it starts (finding, downloading,
      // converting, …), not only when this claim ends.
      if (projected !== before) { await sync(); projected = before; }
      const handlers: Record<string, (d: PipelineDeps, e: PaperEntry, c: Claim, p: PipelinePolicy, deadline: number) => Promise<StepResult>> = {
        metadata: stageMetadata, private_split: stageSplit, download: stageDownload, ocr_fund: stageFund, ocr_submit: stageSubmit,
        ocr_wait: stageWait, render: stageRender };
      const handler = handlers[entry.stage];
      if (!handler) break;
      const result = await handler(deps, entry, claim, policy, deadline);
      entry = result.entry;
      if (result.defer !== undefined) {
        await sync();
        await deps.rpc('worker_pipeline_defer', { ...claim, p_seconds: result.defer });
        return;
      }
      // A fresh submission is waited on in this invocation (polling is I/O; the next
      // minute's run used to add ~40 s); rendering (the CPU-heavy stage) always
      // starts in a fresh invocation.
      if (result.stop === 'release' || entry.stage === before || entry.stage === 'render') break;
    }
    await sync();
    await deps.rpc('worker_pipeline_release', claim);
  } catch (error) {
    if (error instanceof PipelineRPCError && error.code === 'stale_pipeline_claim') { deps.log('stale_claim', { paper: claimed.id }); return; }
    if (error instanceof Deferral) {
      await sync();
      await deps.rpc('worker_pipeline_defer', { ...claim, p_seconds: Math.min(error.seconds, 3600) }).catch(() => {});
      return;
    }
    const permanent = error instanceof PermanentFailure;
    const code = permanent ? error.code : error instanceof PipelineRPCError ? error.code
      : error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'transient_failure';
    const failures = entry.failures + 1;
    deps.log('stage_error', { paper: claimed.id, stage: entry.stage, code, failures, permanent });
    await sync();
    // A funded attempt that repeatedly cannot be prepared releases its hold.
    if (entry.stage === 'ocr_submit' && entry.attempt?.state === 'funded' && (permanent || failures >= 3)) {
      try { await deps.rpc('worker_pipeline_abandon_funding', { ...claim, p_error_code: 'download_failed' }); await deps.rpc('worker_pipeline_release', claim); return; }
      catch { /* fall through to a plain deferral */ }
    }
    // Provider-side stages hold credits: never fail them on transient errors.
    const failable = ['metadata', 'private_split', 'download', 'ocr_fund', 'render'].includes(entry.stage);
    const fail = failable && (permanent || failures >= 5);
    // A download that kept failing because its host was busy or unreachable says so (and is
    // retried automatically later; migration 027).
    const unreachable = entry.stage === 'download' && ['rate_limited', 'download_failed', 'source_unavailable'].includes(code);
    const stageCode = unreachable ? 'source_unavailable'
      : ({ metadata: 'metadata_unavailable', download: 'download_failed' } as Record<string, string>)[entry.stage] ?? 'conversion_failed';
    const resume = permanent ? error.resume : entry.stage === 'private_split' ? 'metadata' : entry.stage;
    await deps.rpc('worker_pipeline_defer', { ...claim, p_seconds: fail ? 0 : Math.min(600, 15 * 2 ** Math.min(failures, 6)),
      p_error_code: fail ? (permanent ? code : stageCode) : code.slice(0, 64), p_fail: fail,
      p_resume_stage: fail ? (['metadata', 'download', 'ocr_fund', 'render'].includes(resume ?? '') ? resume : null) : null }).catch(() => {});
  }
}

/** Advances one claimed paper per invocation, then hands off to a fresh
 * invocation so CPU-heavy stages never accumulate in one Edge isolate. */
export async function runPipeline(deps: PipelineDeps, deadline: number): Promise<{ processed: number }> {
  const policy = await deps.rpc<PipelinePolicy>('worker_pipeline_policy', {});
  // Housekeeping: release chat holds whose invocation died before settling.
  await deps.rpc('worker_expire_stale_chat_operations', {}).catch(() => deps.log('chat_sweep_failed'));
  // Unused future storage phases and expired reader grants can be released;
  // attempted writes and actual deliveries retain their recorded liability.
  await deps.rpc('worker_asset_maintenance', { p_limit: 100 }).catch(() => deps.log('asset_sweep_failed'));
  if (!policy.enabled) return { processed: 0 };
  // Self-healing (migration 027): failed downloads whose automatic retry is due, and failed imports
  // whose paper has since moved on, go back into the pipeline before the next claim. At most one
  // sweep every 20 s; never blocks the pipeline.
  await deps.rpc<{ retried?: number; healed?: number; postponed?: number } | null>('worker_pipeline_auto_retry', { p_min_interval_seconds: 20 })
    .then(r => { if (r && (r.retried || r.healed || r.postponed)) deps.log('auto_retry', { retried: r.retried ?? 0, healed: r.healed ?? 0, postponed: r.postponed ?? 0 }); })
    .catch(() => deps.log('auto_retry_failed'));
  const claimed = await deps.rpc<PaperEntry | null>('worker_pipeline_claim', { p_claim_id: deps.uuid() });
  if (!claimed) return { processed: 0 };
  await processPaper(deps, claimed, policy, deadline);
  if (deps.kick) await deps.kick().catch(() => deps.log('kick_failed'));
  return { processed: 1 };
}

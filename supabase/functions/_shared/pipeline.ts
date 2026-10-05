// Paper pipeline stages driven by the `paper-worker` Edge function. Every
// database transition is fenced by the claim (paper, claim id, generation)
// returned by worker_pipeline_claim; see migration 014. Dependencies are
// injected so Node tests can drive the stages with fakes.
import { PDFDocument } from 'pdf-lib';
import { arxivAtomRecord, arxivCatalogArguments, arxivReuseEvidence, arxivURLs } from './arxiv.ts';
import { unpackReaderZip } from './archive.ts';
import { sha256 } from './http.ts';
import { MathpixError, mathpixProfile, type MathpixConversion, type MathpixStatus, type MathpixSubmission } from './mathpix.ts';
import { SourceError } from './source-xml.ts';

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
  attempt: null | { id: string; state: string; page_limit: number; provider_job_id: string | null; submitted_at: string | null; raw_manifest_path: string | null };
}
export interface PipelinePolicy { max_pdf_bytes: number; max_ocr_pages: number; renderer_version: string; enabled: boolean }

export interface RenderInput {
  mmd: Uint8Array;
  images: Map<string, Uint8Array>;
  provenance: {
    provider_job_id: string; options_sha256: string; page_limit: number; pages: number;
    document_sha256: string; source_id: string; source_revision: number; raw_manifest_sha256: string;
  };
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
    const response = await fetcher(current.href, { redirect: 'manual', headers: { accept, 'user-agent': 'ScienceReader/0.1 (research paper reader; mailto:support@sciencereader.invalid)' },
      signal: AbortSignal.timeout(60_000) });
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

/** Not a failure: the paper is simply not due yet (e.g. arXiv pacing). */
export class Deferral extends Error {
  readonly seconds: number;
  constructor(seconds: number) { super('deferred'); this.seconds = seconds; }
}

async function arxivWait(deps: PipelineDeps): Promise<void> {
  const wait = await deps.rpc<number>('worker_pipeline_arxiv_slot', {});
  // Never send early: a long queue defers the paper instead of sleeping.
  if (wait > 45_000) throw new Deferral(Math.ceil(wait / 1000));
  if (wait > 0) await deps.sleep(wait);
}

async function stageSplit(deps: PipelineDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
  const moved = await deps.rpc<number>('worker_pipeline_split_private', claim);
  deps.log('private_split', { paper: e.id, moved });
  return { entry: e, stop: 'release' };
}

async function stageMetadata(deps: PipelineDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
  const reference = { sourceID: e.source_id, revision: e.requested_revision > 0 ? e.requested_revision : null };
  const urls = arxivURLs(reference);
  await arxivWait(deps);
  const atom = await fetchArxiv(deps.fetch, urls.atom, MiB, 'application/atom+xml');
  let record;
  try { record = arxivAtomRecord(atom, reference); }
  catch (error) { if (error instanceof SourceError && error.message === 'source_not_found') throw new PermanentFailure('metadata_unavailable'); throw error; }
  await arxivWait(deps);
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

async function stageDownload(deps: PipelineDeps, e: PaperEntry, claim: Claim, policy: PipelinePolicy): Promise<StepResult> {
  if (!e.revision) throw new Error('revision_missing');
  await arxivWait(deps);
  const bytes = await fetchArxiv(deps.fetch, `https://arxiv.org/pdf/${e.source_id}v${e.revision}`, policy.max_pdf_bytes, 'application/pdf');
  const pages = await countPages(bytes);
  if (pages > 250) throw new PermanentFailure('too_large');
  const digest = await sha256(bytes);
  const path = `${e.owner_id ? `private/${e.owner_id}/` : ''}originals/${digest}.pdf`;
  await deps.storage.upload(path, bytes, 'application/pdf');
  const entry = await deps.rpc<PaperEntry>('worker_pipeline_original', { ...claim, p_sha256: hex(digest), p_bytes: bytes.length, p_pages: pages, p_path: path });
  deps.log('original', { paper: e.id, bytes: bytes.length, pages, stage: entry.stage });
  return { entry };
}

export async function ocrIdentity(documentSHA256: string, pageLimit: number): Promise<{ optionsSHA256: string; requestSHA256: string }> {
  const profile = await mathpixProfile(pageLimit);
  return { optionsSHA256: profile.sha256, requestSHA256: await sha256(encoder.encode(`science-reader/ocr-request/v1\n${documentSHA256}\n${profile.sha256}`)) };
}

async function stageFund(deps: PipelineDeps, e: PaperEntry, claim: Claim, policy: PipelinePolicy): Promise<StepResult> {
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

async function stageWait(deps: PipelineDeps, e: PaperEntry, claim: Claim): Promise<StepResult> {
  const job = e.attempt?.provider_job_id;
  if (!job || !e.document_sha256 || !e.attempt) throw new Error('attempt_missing');
  const age = e.attempt.submitted_at ? deps.now() - Date.parse(e.attempt.submitted_at) : 0;
  const fail = async (code: string, pages: number) => {
    deps.log('ocr_failed', { paper: e.id, code, pages });
    return { entry: await deps.rpc<PaperEntry>('worker_pipeline_ocr_failed', { ...claim, p_error_code: code, p_pages_billed: Math.min(pages, e.attempt!.page_limit) }) };
  };
  const status = await deps.mathpix.status(job);
  if (status.state === 'error') return fail('conversion_failed', status.completedPages ?? 0);
  if (status.deleted) return fail('conversion_failed', e.attempt.page_limit);
  if (status.state !== 'completed') return age > PROVIDER_TIMEOUT_MS ? fail('conversion_timeout', status.completedPages ?? 0) : { entry: e, defer: age > 120_000 ? 15 : 4 };
  const conversion = await deps.mathpix.conversion(job);
  if (conversion.state === 'error') return fail('conversion_failed', status.pages ?? e.attempt.page_limit);
  if (conversion.state !== 'completed') return age > PROVIDER_TIMEOUT_MS ? fail('conversion_timeout', status.pages ?? e.attempt.page_limit) : { entry: e, defer: 4 };
  let members: Map<string, Uint8Array>;
  try {
    members = new Map<string, Uint8Array>([
      ['standalone.mmd', await deps.mathpix.output(status, 'mmd')],
      ['output.mmd.zip', await deps.mathpix.output(status, 'mmd.zip', conversion)],
      ['lines.json', await deps.mathpix.output(status, 'lines.json')],
    ]);
  } catch (error) {
    if (error instanceof MathpixError && UNUSABLE_OUTPUT.has(error.code)) return fail('conversion_failed', status.pages ?? e.attempt.page_limit);
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
  for (const [name, bytes] of members) await deps.storage.upload(`raw/${manifestSHA}/${name}`, bytes, contentType(name));
  await deps.storage.upload(`raw/${manifestSHA}/manifest.json`, manifestBytes, 'application/json');
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

async function stageRender(deps: PipelineDeps, e: PaperEntry, claim: Claim, policy: PipelinePolicy): Promise<StepResult> {
  const path = e.raw_manifest_path ?? e.attempt?.raw_manifest_path;
  if (!path || !e.document_sha256 || !e.revision) throw new Error('raw_missing');
  const raw = await loadRaw(deps, path);
  let files;
  try { files = await unpackReaderZip(raw.members.get('output.mmd.zip')!); }
  catch { throw new PermanentFailure('render_failed', 'render'); }
  const sources = files.filter(f => f.path.toLowerCase().endsWith('.mmd'));
  if (sources.length !== 1) throw new PermanentFailure('render_failed', 'render');
  const images = new Map(files.filter(f => /\.(jpe?g|png)$/i.test(f.path)).map(f => [f.path, f.bytes]));
  const m = raw.manifest as { provider_job_id: string; options_sha256: string; page_limit: number; pages: number };
  let bundle: RenderedBundle;
  try {
    bundle = await deps.render({ mmd: sources[0].bytes, images, provenance: { provider_job_id: m.provider_job_id, options_sha256: m.options_sha256,
      page_limit: m.page_limit, pages: m.pages, document_sha256: e.document_sha256, source_id: e.source_id, source_revision: e.revision, raw_manifest_sha256: raw.manifestSHA } });
  } catch (error) {
    deps.log('render_failed', { paper: e.id, code: error instanceof Error ? error.message.slice(0, 80) : 'unknown' });
    throw new PermanentFailure('render_failed', 'render');
  }
  if (await sha256(bundle.manifestBytes) !== bundle.manifestSHA256) throw new Error('bundle_integrity');
  for (const [name, bytes] of bundle.members) await deps.storage.upload(`reader/${bundle.manifestSHA256}/${name}`, bytes, contentType(name));
  await deps.storage.upload(`reader/${bundle.manifestSHA256}/manifest.json`, bundle.manifestBytes, 'application/json');
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
  };
  let entry = claimed;
  try {
    // A paper claimed only to project imports runs no stage work.
    for (let step = 0; step < 8 && claimed.due !== false && !TERMINAL.has(entry.stage); step++) {
      if (deps.now() > deadline - 30_000) break;
      const before = entry.stage;
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
      // A fresh submission is polled after the stage delay, not immediately.
      if (result.stop === 'release' || entry.stage === before || (before === 'ocr_submit' && entry.stage === 'ocr_wait')) break;
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
    const stageCode = ({ metadata: 'metadata_unavailable', download: 'download_failed' } as Record<string, string>)[entry.stage] ?? 'conversion_failed';
    const resume = permanent ? error.resume : entry.stage === 'private_split' ? 'metadata' : entry.stage;
    await deps.rpc('worker_pipeline_defer', { ...claim, p_seconds: fail ? 0 : Math.min(600, 15 * 2 ** Math.min(failures, 6)),
      p_error_code: fail ? (permanent ? code : stageCode) : code.slice(0, 64), p_fail: fail,
      p_resume_stage: fail ? (['metadata', 'download', 'ocr_fund', 'render'].includes(resume ?? '') ? resume : null) : null }).catch(() => {});
  }
}

/** Claims and advances papers until the deadline or no work remains. */
export async function runPipeline(deps: PipelineDeps, deadline: number): Promise<{ processed: number }> {
  const policy = await deps.rpc<PipelinePolicy>('worker_pipeline_policy', {});
  if (!policy.enabled) return { processed: 0 };
  let processed = 0;
  while (deps.now() < deadline - 40_000) {
    const claimed = await deps.rpc<PaperEntry | null>('worker_pipeline_claim', { p_claim_id: deps.uuid() });
    if (!claimed) break;
    await processPaper(deps, claimed, policy, deadline);
    processed++;
  }
  return { processed };
}

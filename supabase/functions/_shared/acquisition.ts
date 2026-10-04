import { arxivAtomRecord, arxivCatalogArguments, arxivReference, arxivReuseEvidence, type ArxivRecord } from './arxiv.ts';
import { SourceError } from './source-xml.ts';
import { sha256 } from './http.ts';
import type { MetadataSourceRequest, MetadataSourceResult } from './source-fetch.ts';

export type MetadataAction =
  | { kind: 'link'; accountID: string; importID: string }
  | { kind: 'lookup'; jobID: string; claimID: string }
  | { kind: 'project'; accountID: string; importID: string; intentRevision: number };
export type AcquisitionRPC = 'worker_import_state' | 'worker_acquisition_state' | 'worker_prepare_acquisition' |
  'worker_retry_lookup' | 'worker_link_import_acquisition' | 'worker_project_import_acquisition' |
  'worker_claim_arxiv_stage' | 'worker_finish_arxiv_request' | 'worker_arxiv_request_state' |
  'worker_finish_lookup' | 'worker_fail_acquisition';
export interface AcquisitionRPCRequest { readonly name: AcquisitionRPC; readonly body: string }
export interface MetadataDependencies {
  readonly projectRef: string;
  readonly environment: 'staging';
  /** A pinned, authenticated RPC transport. No automatic retries or redirects.
   * The runner additionally bounds actual response bytes and validates DTOs. */
  readonly rpc: (request: AcquisitionRPCRequest, signal: AbortSignal) => Promise<Response>;
  /** Only a complete EOF plus runtime-proven closure may return complete. */
  readonly source: (request: MetadataSourceRequest, signal: AbortSignal) => Promise<MetadataSourceResult>;
  readonly now?: () => number;
}
const states = ['progress', 'wait', 'disabled', 'terminal', 'reconcile_required'] as const;
const outcomes = ['linked', 'projected', 'metadata_pinned', 'eligible', 'source_only', 'failed', 'retired'] as const;
const scopes = ['claim', 'close', 'result', 'link', 'projection', 'rpc', 'deadline'] as const;
export interface MetadataResult {
  state: typeof states[number];
  jobID: string | null;
  importID: string | null;
  nextAttemptAt: string | null;
  outcome: typeof outcomes[number] | null;
  reconciliation: typeof scopes[number] | null;
}

class Invalid extends Error { constructor() { super('invalid_acquisition_contract'); } }
class RPCFailure extends Error {
  readonly code: string;
  readonly definitive: boolean;
  constructor(code: string, definitive = false) { super('acquisition_rpc_failed'); this.code = code; this.definitive = definitive; }
}
const knownErrors = new Set(['acquisition_unavailable', 'acquisition_retry_unavailable', 'acquisition_source_mismatch',
  'immutable_import_acquisition', 'stale_import_checkpoint', 'import_unavailable', 'account_unavailable',
  'acquisition_control_capacity', 'acquisition_source_capacity', 'acquisition_source_transfer_limit',
  'acquisition_transfer_row_limit', 'arxiv_daily_limit', 'arxiv_outbound_disabled', 'stale_acquisition_lease',
  'stale_arxiv_permit', 'arxiv_attempt_unavailable', 'operation_id_conflict', 'request_rate_limit']);
function object(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Invalid();
  return value as Record<string, unknown>;
}
function id(value: unknown): string {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw new Invalid();
  return value.toLowerCase();
}
function integer(value: unknown, minimum = 0, maximum = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Invalid();
  return value;
}
function flag(value: unknown): boolean { if (typeof value !== 'boolean') throw new Invalid(); return value; }
function text(value: unknown, maximum: number): string {
  if (typeof value !== 'string' || new TextEncoder().encode(value).length > maximum) throw new Invalid();
  return value;
}
function instant(value: unknown): string {
  const raw = text(value, 64), date = Date.parse(raw);
  if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)$/.test(raw) || !Number.isFinite(date) ||
      new Date(`${raw.slice(0, 10)}T00:00:00Z`).toISOString().slice(0, 10) !== raw.slice(0, 10)) throw new Invalid();
  return new Date(date).toISOString();
}
function optional<T>(value: unknown, parse: (value: unknown) => T): T | null { return value === null ? null : parse(value); }
function keys(value: Record<string, unknown>, allowed: string[]) {
  if (Object.keys(value).length !== allowed.length || Object.keys(value).some(key => !allowed.includes(key))) throw new Invalid();
}
export function metadataAction(value: unknown): MetadataAction {
  const input = object(value);
  if (input.kind === 'lookup') {
    keys(input, ['kind', 'jobID', 'claimID']); return { kind: 'lookup', jobID: id(input.jobID), claimID: id(input.claimID) };
  }
  if (input.kind === 'link' || input.kind === 'project') {
    keys(input, ['kind', 'accountID', 'importID', ...(input.kind === 'project' ? ['intentRevision'] : [])]);
    const owner = { accountID: id(input.accountID), importID: id(input.importID) };
    return input.kind === 'link' ? { kind: 'link', ...owner } : { kind: 'project', ...owner, intentRevision: integer(input.intentRevision, 1) };
  }
  throw new Invalid();
}
export function metadataResult(value: unknown): MetadataResult {
  const result = object(value);
  keys(result, ['state', 'jobID', 'importID', 'nextAttemptAt', 'outcome', 'reconciliation']);
  if (!states.includes(result.state as MetadataResult['state']) ||
      (result.outcome !== null && !outcomes.includes(result.outcome as NonNullable<MetadataResult['outcome']>)) ||
      (result.reconciliation !== null && !scopes.includes(result.reconciliation as NonNullable<MetadataResult['reconciliation']>))) throw new Invalid();
  if ((result.state === 'reconcile_required') !== (result.reconciliation !== null) ||
      (result.state !== 'wait' && result.nextAttemptAt !== null)) throw new Invalid();
  return { state: result.state as MetadataResult['state'], jobID: optional(result.jobID, id), importID: optional(result.importID, id),
    nextAttemptAt: optional(result.nextAttemptAt, instant), outcome: result.outcome as MetadataResult['outcome'],
    reconciliation: result.reconciliation as MetadataResult['reconciliation'] };
}
function result(state: MetadataResult['state'], fields: Partial<MetadataResult> = {}): MetadataResult {
  return metadataResult({ state, jobID: null, importID: null, nextAttemptAt: null, outcome: null, reconciliation: null, ...fields });
}

interface Job {
  id: string; sourceID: string; requestedRevision: number | null; sourceRevision: number | null;
  metadataID: string | null; metadata: Record<string, unknown> | null; published: string | null; updated: string | null;
  stage: 'atom' | 'license' | 'complete'; status: string; generation: number; claimID: string | null;
  leaseUntil: string | null; eligibility: 'eligible' | 'source_only' | null; retryable: boolean;
}
function job(value: unknown, expected?: string): Job {
  const j = object(value), key = id(j.id), sourceID = text(j.source_id, 128);
  if (expected !== undefined && key !== expected || j.kind !== 'lookup' || !['atom', 'license', 'complete'].includes(String(j.stage)) ||
      !['queued', 'leased', 'retry_wait', 'no_interest', 'blocked', 'failed', 'complete'].includes(String(j.status)) ||
      ![null, 'eligible', 'source_only'].includes(j.eligibility as null)) throw new Invalid();
  const requestedRevision = optional(j.requested_revision, value => integer(value, 1, 2_147_483_647));
  const ref = arxivReference(`${sourceID}${requestedRevision === null ? '' : `v${requestedRevision}`}`);
  if (ref.sourceID !== sourceID || ref.revision !== requestedRevision) throw new Invalid();
  return { id: key, sourceID, requestedRevision, sourceRevision: optional(j.source_revision, value => integer(value, 1, 2_147_483_647)),
    metadataID: optional(j.metadata_id, id), metadata: optional(j.metadata, object),
    published: optional(j.atom_published_at, instant), updated: optional(j.atom_updated_at, instant),
    stage: j.stage as Job['stage'], status: j.status as string, generation: integer(j.generation),
    claimID: optional(j.claim_id, id), leaseUntil: optional(j.lease_until, instant),
    eligibility: j.eligibility as Job['eligibility'], retryable: flag(j.retryable) };
}
interface ImportState {
  id: string; revision: number; sequence: number; desired: boolean; phase: string;
  sourceID: string; requestedRevision: number | null; metadataID: string | null;
  acquisition: { revision: number; lookupID: string; originalID: string | null; retired: boolean } | null;
  deferred: boolean;
}
function imported(value: unknown, expected: string): ImportState {
  const root = object(value), entry = object(root.entry), key = id(entry.id);
  if (entry.kind !== 'import' || entry.source !== 'arxiv' || key !== expected ||
      !['accepted', 'resolving', 'acquiring', 'ready', 'source_only', 'membership_conflict', 'failed', 'cancelled'].includes(String(entry.phase))) throw new Invalid();
  const sourceID = text(entry.source_id, 128), requestedRevision = optional(entry.requested_revision, value => integer(value, 1, 2_147_483_647));
  const ref = arxivReference(`${sourceID}${requestedRevision === null ? '' : `v${requestedRevision}`}`);
  if (ref.sourceID !== sourceID) throw new Invalid();
  const x = root.acquisition === null ? null : object(root.acquisition);
  return { id: key, revision: integer(entry.intent_revision, 1), sequence: integer(entry.state_seq, 1),
    desired: flag(root.desired_present), phase: entry.phase as string, sourceID, requestedRevision,
    metadataID: optional(entry.metadata_id, id), acquisition: x === null ? null : {
      revision: integer(x.intent_revision, 1), lookupID: id(x.lookup_job_id), originalID: optional(x.original_job_id, id), retired: flag(x.retired),
    }, deferred: root.projection_deferred === undefined ? false : flag(root.projection_deferred) };
}
function pinnedRecord(j: Job): ArxivRecord {
  if (j.metadataID === null || j.sourceRevision === null || j.metadata === null) throw new Invalid();
  const m = j.metadata;
  if (!Array.isArray(m.authors) || m.authors.length > 512 || !Array.isArray(m.categories) || m.categories.length > 64) throw new Invalid();
  const record: ArxivRecord = { sourceID: j.sourceID, revision: j.sourceRevision, metadata: {
    title: text(m.title, 2000), authors: m.authors.map(author => text(author, 256)),
    abstract: optional(m.abstract ?? null, value => text(value, 24_000)), categories: m.categories.map(value => text(value, 64)),
    venue: optional(m.venue ?? null, value => text(value, 1024)), published_at: j.published, updated_at: j.updated,
  } };
  if (!record.metadata.title || (j.requestedRevision !== null && j.requestedRevision !== j.sourceRevision) ||
      (m.published_at ?? null) !== (j.published?.slice(0, 10) ?? null) || (m.updated_at ?? null) !== (j.updated?.slice(0, 10) ?? null)) throw new Invalid();
  arxivCatalogArguments(record); return record;
}

class Run {
  readonly controller = new AbortController();
  readonly now: () => number;
  readonly deadline: number;
  readonly deps: MetadataDependencies;
  calls = 0;
  constructor(deps: MetadataDependencies) {
    this.deps = deps; this.now = deps.now ?? Date.now;
    const started = this.now(); if (!Number.isFinite(started)) throw new Invalid();
    this.deadline = started + 90_000;
  }
  async race<T>(work: (signal: AbortSignal) => Promise<T>, maximum: number): Promise<T> {
    const remaining = Math.min(maximum, this.deadline - this.now());
    if (remaining <= 0 || this.controller.signal.aborted) throw new RPCFailure('deadline');
    const controller = new AbortController(), abort = () => controller.abort();
    this.controller.signal.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(abort, remaining);
    let onAbort: () => void = () => {};
    const stopped = new Promise<never>((_, reject) => {
      onAbort = () => reject(new RPCFailure('deadline'));
      controller.signal.addEventListener('abort', onAbort, { once: true });
    });
    try { return await Promise.race([work(controller.signal), stopped]); }
    finally { clearTimeout(timer); this.controller.signal.removeEventListener('abort', abort); controller.signal.removeEventListener('abort', onAbort); }
  }
  request(name: AcquisitionRPC, parameters: Record<string, unknown>): AcquisitionRPCRequest {
    const body = JSON.stringify(parameters);
    if (new TextEncoder().encode(body).length > 45_000) throw new Invalid();
    return Object.freeze({ name, body });
  }
  async rpc(request: AcquisitionRPCRequest): Promise<unknown> {
    if (++this.calls > 12) throw new RPCFailure('action_limit');
    return this.race(async signal => {
      const response = await this.deps.rpc(request, signal);
      if (response.redirected || response.status >= 300 && response.status < 400) throw new RPCFailure('rpc_transport');
      const parts: Uint8Array[] = []; let size = 0;
      const reader = response.body?.getReader();
      const abort = () => { void reader?.cancel().catch(() => {}); };
      signal.addEventListener('abort', abort, { once: true });
      try {
        if (!reader) throw new RPCFailure('rpc_response');
        while (true) {
          signal.throwIfAborted();
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > 65_536) { void reader.cancel().catch(() => {}); throw new RPCFailure('rpc_response'); }
          parts.push(new Uint8Array(value));
        }
        signal.throwIfAborted();
        const bytes = new Uint8Array(size); let offset = 0;
        for (const part of parts) { bytes.set(part, offset); offset += part.length; }
        let data: unknown;
        try { data = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); }
        catch { throw new RPCFailure('rpc_response'); }
        if (!response.ok) {
          const error = object(data);
          if (response.status === 400 && error.code === 'P0001' && typeof error.message === 'string' && knownErrors.has(error.message)) throw new RPCFailure(error.message, true);
          throw new RPCFailure('rpc_rejected');
        }
        return data;
      } finally { signal.removeEventListener('abort', abort); reader?.releaseLock(); }
    }, 20_000);
  }
  async replay(request: AcquisitionRPCRequest): Promise<unknown> {
    try { return await this.rpc(request); }
    catch (error) { if (error instanceof RPCFailure && error.definitive) throw error; return this.rpc(request); }
  }
}

async function prepareID(project: string, action: Extract<MetadataAction, { kind: 'link' }>, revision: number, previous: string | null) {
  const digest = await sha256(new TextEncoder().encode(JSON.stringify(['science-reader/lookup-command/v1', project, action.accountID, action.importID, revision, previous])));
  // Domain-separated SHA-256 UUIDv8; stable arguments survive a lost prepare ack.
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-8${digest.slice(13, 16)}-${(8 + parseInt(digest[16], 16) % 4).toString(16)}${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
}
async function project(run: Run, action: Extract<MetadataAction, { kind: 'project' }>): Promise<MetadataResult> {
  const request = run.request('worker_project_import_acquisition', { p_account_id: action.accountID, p_import_id: action.importID, p_expected_intent_revision: action.intentRevision });
  try {
    const value = imported(await run.replay(request), action.importID);
    if (value.desired && value.revision !== action.intentRevision) return result('reconcile_required', { importID: value.id, reconciliation: 'projection' });
    return result(value.deferred ? 'wait' : value.desired && ['accepted', 'resolving', 'acquiring'].includes(value.phase) ? 'progress' : 'terminal',
      { importID: value.id, outcome: value.deferred ? null : value.desired ? 'projected' : 'retired' });
  } catch { return result('reconcile_required', { importID: action.importID, reconciliation: 'projection' }); }
}
async function link(run: Run, action: Extract<MetadataAction, { kind: 'link' }>): Promise<MetadataResult> {
  const stateRequest = run.request('worker_import_state', { p_account_id: action.accountID, p_import_id: action.importID });
  const raw = await run.rpc(stateRequest);
  if (raw === null) return result('terminal', { importID: action.importID, outcome: 'retired' });
  const current = imported(raw, action.importID), prior = current.acquisition;
  if (!current.desired || !['accepted', 'resolving', 'acquiring'].includes(current.phase)) {
    if (prior !== null && !prior.retired) return project(run, { ...action, kind: 'project', intentRevision: prior.revision });
    return result('terminal', { importID: action.importID, outcome: 'retired' });
  }
  if (prior?.revision === current.revision && !prior.retired) return project(run, { ...action, kind: 'project', intentRevision: current.revision });
  let previous: Job | null = null;
  if (prior !== null) {
    previous = job(object(await run.rpc(run.request('worker_acquisition_state', { p_job_id: prior.lookupID, p_operation_id: null }))).job, prior.lookupID);
    if (prior.revision >= current.revision || previous.status !== 'failed' || !previous.retryable ||
        previous.metadataID !== current.metadataID) return result('reconcile_required', { importID: current.id, reconciliation: 'link' });
  } else if (current.metadataID !== null) return result('reconcile_required', { importID: current.id, reconciliation: 'link' });
  const operation = await prepareID(run.deps.projectRef, action, current.revision, previous?.id ?? null);
  const prepared = previous === null ? run.request('worker_prepare_acquisition', {
    p_operation_id: operation, p_source_id: current.sourceID, p_requested_revision: current.requestedRevision,
  }) : run.request('worker_retry_lookup', { p_operation_id: operation, p_previous_job_id: previous.id });
  const reply = object(await run.replay(prepared)); flag(reply.replayed);
  const selected = job(reply.job);
  if (selected.sourceID !== current.sourceID || selected.requestedRevision !== current.requestedRevision ||
      current.metadataID !== null && selected.metadataID !== current.metadataID) throw new Invalid();
  const request = run.request('worker_link_import_acquisition', { p_account_id: action.accountID, p_import_id: current.id,
    p_expected_intent_revision: current.revision, p_expected_state_seq: current.sequence,
    p_lookup_job_id: selected.id, p_original_job_id: null });
  try {
    const linked = imported(await run.replay(request), current.id);
    if (linked.revision !== current.revision || linked.acquisition?.revision !== current.revision ||
        linked.acquisition.lookupID !== selected.id || linked.acquisition.retired || !linked.desired) throw new Invalid();
  } catch {
    // Status is authoritative after a lost CAS response, but never changes this
    // action's captured intent revision, source, pins, or selected lookup.
    const linked = imported(await run.rpc(stateRequest), current.id);
    if (linked.revision !== current.revision || linked.acquisition?.revision !== current.revision ||
        linked.acquisition.lookupID !== selected.id || linked.acquisition.retired || !linked.desired) return result('reconcile_required', { importID: current.id, reconciliation: 'link' });
  }
  return project(run, { ...action, kind: 'project', intentRevision: current.revision });
}

async function lookup(run: Run, action: Extract<MetadataAction, { kind: 'lookup' }>): Promise<MetadataResult> {
  const uncertain = (scope: NonNullable<MetadataResult['reconciliation']>) => result('reconcile_required', { jobID: action.jobID, reconciliation: scope });
  let grant: Record<string, unknown>;
  try {
    grant = object(await run.rpc(run.request('worker_claim_arxiv_stage', { p_job_id: action.jobID, p_claim_id: action.claimID,
      p_environment: run.deps.environment, p_reservation_id: null })));
    flag(grant.granted);
  } catch {
    // Even if status reveals a token, a lost one-use grant is not permission to
    // fetch. No second claim POST or source call occurs in this invocation.
    try { await run.rpc(run.request('worker_acquisition_state', { p_job_id: action.jobID, p_operation_id: action.claimID })); } catch { /* retained remotely */ }
    return uncertain('claim');
  }
  const claimed = job(grant.job, action.jobID);
  if (grant.granted === false) {
    if (grant.action === 'disabled') return result('disabled', { jobID: claimed.id });
    if (grant.action === 'wait') return result('wait', { jobID: claimed.id, nextAttemptAt: grant.next_allowed_at == null ? null : instant(grant.next_allowed_at) });
    if (grant.action === 'terminal' || grant.action === 'no_interest') return result('terminal', { jobID: claimed.id,
      outcome: claimed.status === 'failed' ? 'failed' : claimed.status === 'complete' ? claimed.eligibility ?? 'retired' : 'retired' });
    if (grant.action === 'reconcile') return uncertain('claim');
    throw new Invalid();
  }
  const token = id(grant.token), ceiling = integer(grant.byte_ceiling, 1, 1_048_576), expires = instant(grant.request_deadline);
  if (grant.action !== 'perform_stage' || grant.reservation !== null || claimed.status !== 'leased' ||
      claimed.claimID !== action.claimID || claimed.generation < 1 || !['atom', 'license'].includes(claimed.stage) || claimed.leaseUntil !== expires ||
      claimed.stage === 'atom' && (claimed.metadataID !== null || claimed.sourceRevision !== null)) throw new Invalid();
  const pinned = claimed.stage === 'license' ? pinnedRecord(claimed) : null;
  const deadline = Math.min(run.deadline - 15_000, Date.parse(expires) - 15_000, run.now() + 30_000);
  if (deadline <= run.now()) return uncertain('deadline');
  const identity = { p_job_id: claimed.id, p_claim_id: action.claimID, p_generation: claimed.generation };
  const fail = async (code: string, retryable: boolean) => {
    let saved: Job;
    try {
      saved = job(await run.replay(run.request('worker_fail_acquisition', { ...identity, p_error_code: code, p_retryable: retryable })), claimed.id);
      if (!['retry_wait', 'failed'].includes(saved.status) || saved.sourceID !== claimed.sourceID || saved.requestedRevision !== claimed.requestedRevision) throw new Invalid();
    }
    catch { return uncertain('result'); }
    return result(saved.status === 'failed' ? 'terminal' : 'progress', { jobID: claimed.id, outcome: 'failed' });
  };
  let transfer: MetadataSourceResult;
  try {
    transfer = await run.race(signal => run.deps.source(Object.freeze({ reference: Object.freeze({ sourceID: claimed.sourceID,
      revision: claimed.stage === 'atom' ? claimed.requestedRevision : claimed.sourceRevision }), stage: claimed.stage as 'atom' | 'license', byteCeiling: ceiling, deadline }), signal), deadline - run.now());
  } catch { return fail('metadata_unavailable', true); }
  if (transfer.kind === 'uncertain') return fail('metadata_unavailable', true);
  if (transfer.kind !== 'complete' || !(transfer.bytes instanceof Uint8Array) || transfer.bytes.byteLength > ceiling) return uncertain('close');
  const bytes = new Uint8Array(transfer.bytes), status = integer(transfer.status, 100, 599), retry = integer(transfer.retryAfterSeconds, 0, 86_400);
  const close = run.request('worker_finish_arxiv_request', { p_token: token, p_actual_bytes: bytes.length, p_retry_after_seconds: retry });
  try {
    const closed = object(await run.replay(close));
    if (closed.closed !== true || typeof closed.replayed !== 'boolean') throw new Invalid();
  } catch {
    try {
      const state = object(await run.rpc(run.request('worker_arxiv_request_state', { p_job_id: claimed.id, p_claim_id: action.claimID })));
      if (state.closed !== true || id(state.token) !== token || integer(state.actual_bytes) !== bytes.length) return uncertain('close');
    } catch { return uncertain('close'); }
  }
  if (status !== 200) return fail(status === 404 ? 'source_not_found' : status === 429 ? 'rate_limited' : 'metadata_unavailable', status === 429 || status >= 500);
  let value: Record<string, unknown>;
  try {
    if (claimed.stage === 'atom') {
      const record = arxivAtomRecord(bytes, { sourceID: claimed.sourceID, revision: claimed.requestedRevision });
      value = { revision: record.revision, metadata: arxivCatalogArguments(record).p_metadata,
        atom_published_at: record.metadata.published_at, atom_updated_at: record.metadata.updated_at };
    } else {
      const reuse = await arxivReuseEvidence(bytes, pinned!, new Date(run.now()).toISOString());
      value = reuse.eligible ? { eligible: true, license_uri: reuse.licenseURI, evidence: reuse.evidence } : { eligible: false, reason: reuse.reason };
    }
  } catch (error) {
    return fail(error instanceof SourceError && error.code === 'source_not_found' ? 'source_not_found' : 'invalid_source_metadata', false);
  }
  const finished = run.request('worker_finish_lookup', { ...identity, p_result: value });
  try {
    const saved = job(await run.replay(finished), claimed.id);
    if (saved.sourceID !== claimed.sourceID || saved.requestedRevision !== claimed.requestedRevision) throw new Invalid();
    if (claimed.stage === 'atom') {
      if (!['license', 'complete'].includes(saved.stage) || saved.metadataID === null || saved.metadata === null ||
          saved.sourceRevision !== value.revision || saved.published !== value.atom_published_at || saved.updated !== value.atom_updated_at) throw new Invalid();
    } else if (saved.stage !== 'complete' || saved.eligibility !== (value.eligible ? 'eligible' : 'source_only') ||
        saved.metadataID !== claimed.metadataID || saved.sourceRevision !== claimed.sourceRevision) throw new Invalid();
    return result(['complete', 'failed'].includes(saved.status) ? 'terminal' : 'progress', {
      jobID: saved.id, outcome: saved.status === 'failed' ? 'failed' : saved.eligibility ?? 'metadata_pinned',
    });
  } catch {
    try { await run.rpc(run.request('worker_acquisition_state', { p_job_id: claimed.id, p_operation_id: action.claimID })); } catch { /* next scan reconciles */ }
    // Never replace a possibly committed success with worker_fail_acquisition.
    return uncertain('result');
  }
}

/** Pure action runner: no HTTP ingress, scheduler, live transport or enable
 * switch. The eventual service-only host must supply those separate gates. */
export async function runMetadataAction(input: unknown, dependencies: MetadataDependencies, parent?: AbortSignal): Promise<MetadataResult> {
  const action = metadataAction(input);
  const deps = Object.freeze({ ...dependencies });
  if (deps.environment !== 'staging' || !/^[a-z]{20}$/.test(deps.projectRef) || typeof deps.rpc !== 'function' || typeof deps.source !== 'function') throw new Invalid();
  const run = new Run(deps), abort = () => run.controller.abort();
  // Independent elapsed-time fence; a wall-clock rollback cannot extend the
  // sum of individually bounded RPCs past the invocation's total allowance.
  const timer = setTimeout(abort, 90_000);
  if (parent?.aborted) abort();
  parent?.addEventListener('abort', abort, { once: true });
  try {
    if (action.kind === 'lookup') return await lookup(run, action);
    if (action.kind === 'link') return await link(run, action);
    return await project(run, action);
  } catch {
    return result('reconcile_required', { jobID: action.kind === 'lookup' ? action.jobID : null,
      importID: action.kind !== 'lookup' ? action.importID : null, reconciliation: run.controller.signal.aborted || run.now() >= run.deadline ? 'deadline' : 'rpc' });
  } finally { clearTimeout(timer); parent?.removeEventListener('abort', abort); }
}

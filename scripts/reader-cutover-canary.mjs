#!/usr/bin/env node
// Explicit, staging-only reader CDN retirement. Import and --help have no side effects.
// No policy writes, grants, providers, object mutation, email or arbitrary SQL/RPC interface.
// Signed URLs and account credentials live only in this process. Losing the process loses
// its warmed-URL evidence; reports contain hashes and synthetic cleanup IDs, never URLs.
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createInterface } from 'node:readline';
import { validateReaderDescriptor, verifyReaderDelivery } from './reader-workflow.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT = 'coxhjvqpflgxkleydati', ORGANIZATION = 'mhiweqpcwyqtyorgqhla';
const ORIGIN = `https://${PROJECT}.supabase.co`, MANAGEMENT = `https://api.supabase.com/v1/projects/${PROJECT}`;
const MiB = 1_048_576, MAX_BUNDLE = MiB, MAX_MANIFEST = 65_536, MAX_TINY = 16_384;
const CLEANUP_RESERVE = 65_536, FINAL_RESERVE = 2 * MiB, MAX_PATHS = 5000;
export const LIMITS = Object.freeze({ bodyBytes: 8 * MiB, descriptors: 6, requests: 5500,
  drainMs: (400 + 900 + 30) * 1000, propagationMs: 75_000, durationMs: 105 * 60_000 });
const sha = value => createHash('sha256').update(value).digest('hex');
const UUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const HASH = /^[0-9a-f]{64}$/;
const fail = code => { throw new CanaryError(code); };
export class CanaryError extends Error {}
const finiteError = error => error instanceof CanaryError ? error.message : 'unexpected_local_failure';
const uuid = value => { if (typeof value !== 'string' || !UUID.test(value)) fail('invalid_uuid'); return value; };
const integer = value => { const n = Number(value); if (!Number.isSafeInteger(n) || n < 0) fail('invalid_counter'); return n; };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const json = bytes => { try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { fail('invalid_json'); } };
const time = value => { const n = Date.parse(value); if (!Number.isFinite(n)) fail('invalid_time'); return n; };

export function readerPath(value) {
  if (typeof value !== 'string' || value.length > 312 || !/^reader\/[0-9a-f]{64}\/[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(value)
    || value.includes('..') || value.split('/').some(part => !part)) fail('invalid_reader_path');
  return value;
}

export function expiredTokenResponse(status, body) {
  const code = body?.error ?? body?.code, message = body?.message;
  return [400, 401, 403].includes(status) && ['InvalidJWT', 'AccessDenied', 'Unauthorized'].includes(code)
    && typeof message === 'string' && (/\b(expired|expiration)\b/i.test(message)
      // Supabase Storage preserves jose's exact expiry claim failure. Do not
      // mistake nbf/iat or signature failures for observed token expiration.
      || code === 'InvalidJWT' && message === '"exp" claim timestamp check failed');
}

export function saveVerifiedBundle(file, bundle, sourceID) {
  // This export is authorized only for the public cached DPO canary. It is not
  // a general library export and never serializes the descriptor or session.
  if (sourceID !== '2305.18290' || !bundle || !Buffer.isBuffer(bundle.manifestBytes)
    || bundle.manifestBytes.length > MAX_MANIFEST || sha(bundle.manifestBytes) !== bundle.manifestSHA256
    || !(bundle.contents instanceof Map) || bundle.contents.size < 1 || bundle.contents.size > 64) fail('render_export_not_authorized');
  const manifest = json(bundle.manifestBytes);
  if (!Array.isArray(manifest.members) || manifest.members.length !== bundle.contents.size) fail('render_export_integrity');
  const paths = new Set(); let count = 0;
  const members = manifest.members.map(member => {
    const bytes = bundle.contents.get(member.path);
    if (typeof member.path !== 'string' || member.path.length > 240 || member.path.includes('..')
      || !member.path.split('/').every(part => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(part)) || paths.has(member.path)
      || !Buffer.isBuffer(bytes) || bytes.length !== member.bytes || sha(bytes) !== member.sha256) fail('render_export_integrity');
    paths.add(member.path); count += bytes.length;
    if (count > MAX_BUNDLE) fail('render_export_size');
    return { path: member.path, base64: bytes.toString('base64') };
  });
  const artifact = { format: 'gradstep-reader-render-proof-v1', source_id: sourceID,
    manifest_sha256: bundle.manifestSHA256, manifest: bundle.manifestBytes.toString('base64'), members };
  // Never overwrite an earlier proof or follow a symlink at the chosen name.
  writeFileSync(file, JSON.stringify(artifact) + '\n', { mode: 0o600, flag: 'wx' });
  return { member_bytes: count, manifest_bytes: bundle.manifestBytes.length, artifact_sha256: sha(readFileSync(file)) };
}

// Count all response payloads (including Auth, Management and errors). These are payload
// limits, not a claim about TLS/header bytes or whole-project provider invoices.
export class BodyBudget {
  bytes = 0; requests = 0; descriptors = 0; reserve = CLEANUP_RESERVE;
  constructor(prior = {}) {
    if (!prior || typeof prior !== 'object' || Array.isArray(prior)
      || Object.keys(prior).some(k => !['bytes', 'requests', 'descriptors'].includes(k))) fail('prior_usage_invalid');
    this.priorBytes = integer(prior.bytes ?? 0); this.priorDescriptors = integer(prior.descriptors ?? 0);
    this.bytes = this.priorBytes; this.requests = integer(prior.requests ?? 0);
    if (this.priorBytes > MiB || this.requests > 100 || this.priorDescriptors > 2) fail('prior_usage_review_required');
  }
  remaining(cleanup = false) { return LIMITS.bodyBytes - this.bytes - (cleanup ? 0 : this.reserve); }
  admit(maximum, descriptor, cleanup = false) {
    if (!Number.isSafeInteger(maximum) || maximum < 0 || maximum > this.remaining(cleanup)) fail('payload_budget_before_request');
    if (++this.requests > LIMITS.requests - (cleanup ? 0 : 15)) fail('request_budget');
    if (descriptor && (++this.descriptors > LIMITS.descriptors || this.descriptors + this.priorDescriptors > 8)) fail('descriptor_budget');
  }
  consume(count, cleanup = false) {
    this.bytes += count;
    if (this.remaining(cleanup) < 0) fail('payload_budget');
  }
  snapshot() { return { delivered_payload_bytes: this.bytes, requests: this.requests, descriptor_attempts: this.descriptors,
    prior_payload_bytes: this.priorBytes, prior_descriptor_attempts: this.priorDescriptors,
    aggregate_descriptor_attempts: this.descriptors + this.priorDescriptors,
    conservative_reader_admission_bytes: (this.descriptors + this.priorDescriptors) * MiB + 3 * MAX_BUNDLE,
    admission_includes_three_whole_bundle_reservations: true }; }
}

export async function boundedBody(response, maximum, budget, cleanup = false, scalarRPC = false) {
  const length = response.headers.get('content-length'), encoding = response.headers.get('content-encoding');
  // PostgREST adds this row-count header to scalar JSON RPC results. It is not
  // a byte-range response. Reader/Storage requests never receive this exception.
  const rowRange = scalarRPC && response.status === 200 && response.headers.get('content-range') === '0-0/*';
  if ((encoding && encoding.toLowerCase() !== 'identity') || (response.headers.has('content-range') && !rowRange)
    || (length !== null && (!/^\d{1,10}$/.test(length) || Number(length) > maximum))) {
    await response.body?.cancel().catch(() => {}); fail('response_contract');
  }
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader(), chunks = []; let bytes = 0;
  try {
    while (true) {
      const part = await reader.read(); if (part.done) break;
      budget.consume(part.value.length, cleanup); bytes += part.value.length;
      if (bytes > maximum) fail('response_too_large');
      chunks.push(part.value);
    }
  } catch (error) {
    await reader.cancel().catch(() => {}); throw error instanceof CanaryError ? error : new CanaryError('response_read_failed');
  } finally { reader.releaseLock(); }
  if (length !== null && Number(length) !== bytes) fail('response_size');
  return Buffer.concat(chunks, bytes);
}

export function cacheEvidence(response) {
  // No arbitrary header value (especially Location) reaches the report.
  const state = response.headers.get('cf-cache-status')?.toUpperCase();
  const cache = ['HIT', 'MISS', 'EXPIRED', 'DYNAMIC', 'BYPASS', 'REVALIDATED', 'UPDATING', 'STALE'].includes(state) ? state : null;
  const age = response.headers.get('age');
  return { status: response.status, cf_cache_status: cache, age_seconds: /^\d{1,10}$/.test(age ?? '') ? Number(age) : null };
}

export function validateScope(rows) {
  if (!Array.isArray(rows) || !rows.length || rows.length > MAX_PATHS) fail('scope_count');
  const seen = new Set();
  for (const row of rows) {
    readerPath(row.path); if (seen.has(row.path)) fail('scope_duplicate'); seen.add(row.path);
    if (!row.tracked || !['pending', 'verified', 'deleting', 'deleted'].includes(row.state)
      || !HASH.test(row.sha256) || integer(row.bytes) < 1) fail('scope_untracked_or_invalid');
    if (row.physical && (integer(row.physical_bytes) !== integer(row.bytes) || row.state === 'deleted')) fail('scope_physical_discrepancy');
    if (!row.physical && row.state === 'verified') fail('scope_verified_missing');
  }
  // Include absent/deleted historical paths. A provider 404 must be resolved explicitly,
  // not translated into success just because Storage no longer lists that object.
  const sorted = rows.map(row => ({ ...row })).sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
  return { paths: sorted, digest: sha(JSON.stringify(sorted)), count: sorted.length,
    historical_absent: sorted.filter(row => !row.physical).length };
}

const SCOPE = `with tracked as (
 select path,state,byte_count bytes,encode(sha256,'hex') sha256 from app_private.stored_objects
 where bucket='paper-assets' and path like 'reader/%'), physical as (
 select name path,metadata->>'size' physical_bytes from storage.objects where bucket_id='paper-assets' and name like 'reader/%'), scope as (
 select coalesce(t.path,p.path) path,t.path is not null tracked,t.state,t.bytes,t.sha256,
 p.path is not null physical,p.physical_bytes from tracked t full join physical p on p.path=t.path)`;
const SCOPE_SIGNATURE = `${SCOPE} select count(*) count,md5(coalesce(string_agg(row_to_json(s)::text,E'\n' order by path collate "C"),'')) fingerprint from scope s`;
const SNAPSHOT = `select jsonb_build_object('at',clock_timestamp(),
 'policy',(select to_jsonb(p) from app_private.reader_delivery_policy p),
 'asset',(select to_jsonb(p) from app_private.paper_asset_policy p),
 'private_bucket',(select not public from storage.buckets where id='paper-assets'),
 'storage_rls',(select relrowsecurity from pg_class where oid='storage.objects'::regclass),
 'client_storage_policies',(select count(*) from pg_policies where schemaname='storage' and tablename='objects'
   and cmd in ('SELECT','ALL') and roles && array['public','anon','authenticated']::name[]),
 'same_owner',(select count(distinct proowner)=1 and bool_and(prosecdef) from pg_proc
   where oid in ('public.worker_reader_descriptor(uuid,uuid)'::regprocedure,
   'public.worker_reader_delivery_create(uuid,uuid,bytea,text)'::regprocedure)),
 'old_service',has_function_privilege('service_role','public.worker_reader_descriptor(uuid,uuid)','EXECUTE'),
 'old_anon',has_function_privilege('anon','public.worker_reader_descriptor(uuid,uuid)','EXECUTE'),
 'old_authenticated',has_function_privilege('authenticated','public.worker_reader_descriptor(uuid,uuid)','EXECUTE'),
 'current_service',has_function_privilege('service_role','public.worker_reader_delivery_create(uuid,uuid,bytea,text)','EXECUTE'),
 'issuer_function_hash',(select md5(pg_get_functiondef('public.worker_reader_delivery_create(uuid,uuid,bytea,text)'::regprocedure))),
 'legacy_function_hash',(select md5(pg_get_functiondef('public.worker_reader_descriptor(uuid,uuid)'::regprocedure))),
 'environment_transfer',(select coalesce(jsonb_agg(to_jsonb(t)),'[]') from app_private.reader_transfer_months t
   where scope_id='environment' and period=date_trunc('month',now() at time zone 'UTC')::date)) snapshot`;

const CACHED = `select pp.id paper_id,pp.source_id,pp.requested_revision,pp.revision,pp.document_id,pp.artifact_id,
 mo.path manifest_path,encode(mo.sha256,'hex') manifest_sha256,mo.byte_count manifest_bytes,
 ct.vocabulary,ct.method,ct.claim_id,ct.recorded_at,
 count(*) members,sum(o.byte_count) bundle_bytes,min(o.byte_count) smallest_bytes,
 bool_and(o.state='verified') members_verified
 from app_private.pipeline_papers pp join app_private.documents d on d.id=pp.document_id and d.scope='shared_catalog'
 join app_private.catalog_asset_approvals ca on ca.id=pp.approval_id
 join app_private.catalog_tags ct on ct.version_id=ca.version_id
 join app_private.render_artifacts ra on ra.id=pp.artifact_id
 join app_private.stored_objects mo on mo.id=ra.manifest_object_id and mo.state='verified'
 join app_private.paper_asset_manifest_members mm on mm.manifest_object_id=mo.id
 join app_private.stored_objects o on o.id=mm.object_id
 where pp.owner_id is null and pp.stage='done' and pp.claim_id is null and pp.source_id in ('2305.18290','2310.06825')
 group by pp.id,mo.id,ct.version_id order by case pp.source_id when '2305.18290' then 0 else 1 end,pp.requested_revision desc`;

export class ReaderCutoverCanary {
  constructor({ env, emit, fetcher = fetch, now = Date.now, signal, saveBundle, priorUsage = {} }) {
    if (env.SUPABASE_URL !== ORIGIN || env.SUPABASE_PROJECT_REF !== PROJECT
      || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY || !env.SUPABASE_ACCESS_TOKEN) fail('staging_credentials_required');
    Object.assign(this, { env, emit, fetcher, now, signal, saveBundle });
    this.budget = new BodyBudget(priorUsage); this.accounts = []; this.phase = 'new'; this.urls = [];
    this.runID = randomUUID(); this.born = now(); this.started = new Date(now()).toISOString();
  }
  report(event, details = {}) { this.emit({ event, at: new Date(this.now()).toISOString(), phase: this.phase, ...details, budget: this.budget.snapshot() }); }
  headers(token, service = false) {
    const key = service ? this.env.SUPABASE_SERVICE_ROLE_KEY : this.env.SUPABASE_ANON_KEY;
    return { apikey: key, Authorization: `Bearer ${token ?? key}` };
  }
  require(...phases) { if (!phases.includes(this.phase)) fail('wrong_phase'); }
  async http(url, { method = 'GET', body, headers = {}, maximum = 16_384, cleanup = false } = {}) {
    if (!cleanup && this.signal?.aborted) fail('process_interrupted');
    const target = new URL(url);
    if (target.username || target.password || target.hash || target.href !== url) fail('network_origin');
    const managementRead = method === 'GET' && url === MANAGEMENT
      || method === 'POST' && url === MANAGEMENT + '/database/query' && body?.read_only === true;
    const hostedRead = method === 'GET' && ['/functions/v1/reader-artifact', '/functions/v1/reader-member'].includes(target.pathname)
      || method === 'GET' && target.pathname.startsWith('/storage/v1/object/sign/paper-assets/reader/');
    const hostedWrite = method === 'POST' && ['/auth/v1/admin/users', '/auth/v1/token', '/functions/v1/account-delete',
      '/rest/v1/rpc/v1_credit_balance', '/rest/v1/rpc/v3_library_page', '/rest/v1/rpc/v2_begin_import',
      '/rest/v1/rpc/worker_reader_descriptor'].includes(target.pathname)
      || method === 'DELETE' && target.pathname.startsWith('/storage/v1/cdn/paper-assets/reader/');
    if (!managementRead && !(target.origin === ORIGIN && (hostedRead || hostedWrite))) fail('network_route_not_allowed');
    const isDescriptor = target.origin === ORIGIN && target.pathname === '/functions/v1/reader-artifact';
    this.budget.admit(maximum, isDescriptor, cleanup);
    let response;
    try { response = await this.fetcher(url, { method, redirect: 'error',
      headers: { 'Accept-Encoding': 'identity', ...(body === undefined ? {} : { 'content-type': 'application/json' }), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.any([AbortSignal.timeout(60_000), ...(!cleanup && this.signal ? [this.signal] : [])]) }); }
    catch { fail('network_failed'); }
    if (response.redirected || response.url !== url) { await response.body?.cancel().catch(() => {}); fail('response_origin'); }
    const scalarRPC = target.origin === ORIGIN && method === 'POST' && target.pathname.startsWith('/rest/v1/rpc/');
    return { response, bytes: await boundedBody(response, maximum, this.budget, cleanup, scalarRPC) };
  }
  async sql(query, maximum = 32_768, cleanup = false) {
    const r = await this.http(MANAGEMENT + '/database/query', { method: 'POST', maximum, cleanup,
      headers: { Authorization: `Bearer ${this.env.SUPABASE_ACCESS_TOKEN}` }, body: { query, read_only: true } });
    if (r.response.status !== 201 && r.response.status !== 200) fail('management_query_failed');
    const rows = json(r.bytes); if (!Array.isArray(rows)) fail('management_shape'); return rows;
  }
  async rpc(name, params, account, service = false) {
    if (!['v1_credit_balance', 'v3_library_page', 'v2_begin_import', 'worker_reader_descriptor'].includes(name)) fail('rpc_not_allowed');
    const r = await this.http(`${ORIGIN}/rest/v1/rpc/${name}`, { method: 'POST', maximum: 65_536,
      headers: this.headers(service ? null : await this.token(account), service), body: params });
    if (r.response.status !== 200) fail('account_rpc_failed'); return json(r.bytes);
  }
  async token(account, cleanup = false) {
    if (account.access && this.now() - account.tokenAt < 40 * 60_000) return account.access;
    const r = await this.http(`${ORIGIN}/auth/v1/token?grant_type=password`, { method: 'POST', cleanup,
      headers: { apikey: this.env.SUPABASE_ANON_KEY }, body: { email: account.email, password: account.password } });
    if (r.response.status !== 200) fail('synthetic_signin_failed');
    const value = json(r.bytes);
    if (typeof value.access_token !== 'string' || value.access_token.length > 8192 || value.user?.email !== account.email) fail('synthetic_signin_identity');
    const id = uuid(value.user.id); if (account.id && account.id !== id) fail('synthetic_signin_identity');
    account.id = id; account.access = value.access_token; account.tokenAt = this.now(); return account.access;
  }
  async account() {
    if (this.accounts.length >= 2) fail('account_budget');
    const account = { email: `gradstep-check-reader-cutover-${randomUUID()}@example.invalid`, password: randomBytes(36).toString('base64url') };
    // Keep the credentials before the first send so an ambiguous creation can be cleaned
    // up by signing into only this exact synthetic identity, without listing other users.
    this.accounts.push(account);
    const r = await this.http(`${ORIGIN}/auth/v1/admin/users`, { method: 'POST', headers: this.headers(null, true),
      body: { email: account.email, password: account.password, email_confirm: true } });
    if (r.response.status !== 200 && r.response.status !== 201) fail('synthetic_create_failed');
    account.id = uuid(json(r.bytes).id); await this.token(account);
    this.report('synthetic_created', { cleanup_account_id: account.id });
    await this.zeroBalance(account); return account;
  }
  async zeroBalance(account) {
    const balance = await this.rpc('v1_credit_balance', {}, account);
    if (integer(balance.available) !== 0 || integer(balance.held ?? 0) !== 0) fail('synthetic_nonzero_balance');
  }
  async snapshot(mode) {
    const snapshot = (await this.sql(SNAPSHOT))[0]?.snapshot;
    if (!snapshot || snapshot.policy?.mode !== mode || snapshot.asset?.enforced !== true || snapshot.asset?.inventory_discrepancies !== 0
      || !snapshot.private_bucket || !snapshot.storage_rls || snapshot.client_storage_policies !== 0
      || !snapshot.same_owner || !snapshot.current_service || snapshot.old_anon || snapshot.old_authenticated) fail('policy_preflight_failed');
    if (mode === 'bounded' && snapshot.old_service) fail('legacy_issuer_not_fenced');
    if (Math.abs(time(snapshot.at) - this.now()) > 30_000) fail('clock_skew');
    return snapshot;
  }
  async project() {
    const r = await this.http(MANAGEMENT, { headers: { Authorization: `Bearer ${this.env.SUPABASE_ACCESS_TOKEN}` } });
    const p = json(r.bytes);
    if (r.response.status !== 200 || p.id !== PROJECT || p.organization_id !== ORGANIZATION || p.name !== 'science-reader-staging') fail('project_identity');
  }
  async cachedPaper() {
    const vocabulary = readFileSync(join(ROOT, 'supabase/functions/_shared/tag-vocabulary.ts'), 'utf8')
      .match(/export const TAG_VOCABULARY_VERSION = '([a-z0-9-]+)'/)?.[1];
    if (!vocabulary) fail('tag_vocabulary_unknown');
    const candidates = await this.sql(CACHED);
    const paper = candidates.find(p => p.vocabulary === vocabulary && p.method === 'model' && p.claim_id === null && p.recorded_at
      && p.members_verified && integer(p.bundle_bytes) <= MAX_BUNDLE && integer(p.manifest_bytes) <= MAX_MANIFEST
      && integer(p.smallest_bytes) <= MAX_TINY && integer(p.members) > 0 && integer(p.members) <= 64);
    if (!paper) fail('no_small_cached_tagged_shared_paper');
    uuid(paper.paper_id); uuid(paper.document_id); uuid(paper.artifact_id); readerPath(paper.manifest_path);
    if (!HASH.test(paper.manifest_sha256) || integer(paper.revision) < 1) fail('cached_paper_invalid');
    return paper;
  }
  async addCached(account) {
    const before = await this.rpc('v3_library_page', { p_cursor: null, p_limit: 100 }, account);
    if (before.has_more || before.entries?.length) fail('synthetic_library_not_empty');
    const added = await this.rpc('v2_begin_import', { p_operation_id: randomUUID(), p_source_id: this.paper.source_id,
      p_observed_cursor: before.baseline_cursor ?? 0,
      // Do not turn an existing latest-slot cache into a new explicit-revision job.
      p_requested_revision: this.paper.requested_revision || null }, account);
    if (added.result?.status !== 'applied' && !added.replayed) fail('cached_add_refused');
    for (let attempt = 0; attempt < 18; attempt++) {
      const page = await this.rpc('v3_library_page', { p_cursor: null, p_limit: 100 }, account);
      if (!Array.isArray(page.entries) || page.has_more) fail('cached_library_shape');
      const item = page.entries.find(e => e.kind === 'item' && e.readiness === 'converted_ready');
      if (item) {
        uuid(item.id);
        if (item.document_id !== this.paper.document_id || item.artifact_id !== this.paper.artifact_id) fail('cached_artifact_changed');
        return item;
      }
      if (page.entries.some(e => e.kind === 'import' && ['failed', 'source_only', 'cancelled', 'membership_conflict'].includes(e.phase))) fail('cached_import_failed');
      await delay(3000);
    }
    fail('cached_import_timeout');
  }
  async fullBundle(label) {
    let captured; const observed = [], bodies = new Map();
    const fetcher = async (url, init) => {
      const r = await this.http(url, { headers: init.headers, maximum: MiB });
      if (new URL(url).pathname === '/functions/v1/reader-artifact' && r.response.status === 200) captured = json(r.bytes);
      else if (r.response.status === 200) {
        bodies.set(url, r.bytes);
        const type = r.response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
        observed.push({ url_sha256: sha(url), bytes: r.bytes.length,
          media_type: ['text/html', 'text/plain', 'text/css', 'application/json', 'image/png', 'image/jpeg'].includes(type) ? type : 'unexpected',
          declared_length: /^\d{1,10}$/.test(r.response.headers.get('content-length') ?? '') ? Number(r.response.headers.get('content-length')) : null,
          no_referrer: r.response.headers.get('referrer-policy') === 'no-referrer',
          nosniff: r.response.headers.get('x-content-type-options') === 'nosniff',
          private_no_store: r.response.headers.get('cache-control') === 'private, no-store' });
      }
      return Object.defineProperty(new Response(r.bytes, { status: r.response.status, headers: r.response.headers }), 'url', { value: url });
    };
    let result;
    try { result = await verifyReaderDelivery({ backendURL: ORIGIN, anonKey: this.env.SUPABASE_ANON_KEY,
      token: () => this.token(this.owner), item: this.item, fetcher }); }
    catch (error) {
      // The helper's finite codes contain no URLs or response bodies; keep the
      // stage evidence needed to distinguish gateway differences from bad bytes.
      const code = typeof error?.message === 'string' && /^reader_[a-z_]{1,64}$/.test(error.message)
        ? error.message : 'reader_check_failed';
      this.report('bounded_verification_refused', { code, response_headers: observed });
      fail('bounded_bundle_verification_failed');
    }
    const checked = validateReaderDescriptor(captured, this.item, ORIGIN);
    if (result.transport !== 'bounded-v1' || result.bytes !== integer(this.paper.bundle_bytes)
      || captured.manifest_sha256 !== this.paper.manifest_sha256) fail('bounded_bundle_identity');
    // Retain only the fully verified bytes (<=1 MiB + manifest) for an optional
    // local renderer check. No delivery URL, grant or account token crosses that
    // boundary. This can be inspected after initial proof without another GET.
    this.renderBundle = { manifestSHA256: captured.manifest_sha256,
      manifestBytes: Buffer.from(captured.manifest, 'base64'),
      contents: new Map(checked.members.map(member => [member.path, bodies.get(member.url.href)])) };
    this.report(label, { ...result, response_headers: observed }); return checked;
  }
  async descriptor(transport) {
    const url = `${ORIGIN}/functions/v1/reader-artifact?item_id=${this.item.id}&transport=${transport}`;
    const r = await this.http(url, { headers: this.headers(await this.token(this.owner)), maximum: MiB });
    if (r.response.status !== 200) fail('descriptor_refused');
    let checked; const value = json(r.bytes);
    try { checked = validateReaderDescriptor(value, this.item, ORIGIN); } catch { fail('descriptor_invalid'); }
    if (checked.transport !== transport || value.manifest_sha256 !== this.paper.manifest_sha256
      || checked.members.reduce((n, m) => n + m.bytes, 0) !== integer(this.paper.bundle_bytes)) fail('descriptor_identity');
    return checked;
  }
  async redemptionSnapshot() {
    return (await this.sql(`select count(*) n,coalesce(sum(r.byte_ceiling),0) bytes from app_private.reader_delivery_redemptions r
      join app_private.reader_delivery_grants g on g.id=r.grant_id where g.account_id='${uuid(this.owner.id)}'`))[0];
  }
  async negativeProbes(checked) {
    const member = checked.members[0], before = await this.redemptionSnapshot();
    for (const [label, account, extra, status, code] of [
      ['replay', this.owner, {}, 409, 'reader_grant_consumed'],
      ['wrong_account', this.other, {}, 403, 'reader_grant_unavailable'],
      ['range', this.owner, { Range: 'bytes=0-1' }, 416, 'reader_range_unavailable'],
    ]) {
      const r = await this.http(member.url.href, { headers: { ...this.headers(await this.token(account)), ...extra }, maximum: 4096 });
      if (r.response.status !== status || json(r.bytes)?.code !== code) fail(`${label}_not_refused`);
      this.report('negative_probe', { probe: label, status });
    }
    const after = await this.redemptionSnapshot();
    if (JSON.stringify(before) !== JSON.stringify(after)) fail('negative_probe_consumed_storage');
  }
  async raceMember(member) {
    const before = await this.redemptionSnapshot(), maximum = Math.max(member.bytes, 4096);
    if (maximum * 2 > this.budget.remaining()) fail('payload_budget_before_request');
    const headers = this.headers(await this.token(this.owner));
    const settled = await Promise.allSettled([
      this.http(member.url.href, { headers, maximum }),
      this.http(member.url.href, { headers, maximum }),
    ]);
    if (settled.some(result => result.status !== 'fulfilled')) fail('first_redemption_race_transport');
    const replies = settled.map(result => result.value);
    const success = replies.filter(r => r.response.status === 200), consumed = replies.filter(r => r.response.status === 409);
    if (success.length !== 1 || consumed.length !== 1 || json(consumed[0].bytes)?.code !== 'reader_grant_consumed') fail('first_redemption_race_outcome');
    const fresh = success[0];
    if (sha(fresh.bytes) !== member.sha256 || fresh.bytes.length !== member.bytes
      || (fresh.response.headers.has('content-length') && fresh.response.headers.get('content-length') !== String(member.bytes))
      || fresh.response.headers.get('cache-control') !== 'private, no-store'
      || fresh.response.headers.get('x-content-type-options') !== 'nosniff'
      || fresh.response.headers.get('referrer-policy') !== 'no-referrer') fail('fresh_bounded_probe_failed');
    const after = await this.redemptionSnapshot();
    if (integer(after.n) - integer(before.n) !== 1 || integer(after.bytes) - integer(before.bytes) !== member.bytes) fail('first_redemption_race_accounting');
    this.report('first_redemption_race', { successful_downloads: 1, consumed_refusals: 1,
      new_redemptions: 1, authorized_byte_delta: member.bytes, url_sha256: sha(member.url.href) });
  }
  async legacyPair() {
    for (let index = 0; index < 2; index++) {
      if (index) await delay(2100); // createSignedUrls signs exp in seconds; tokens must differ.
      const checked = await this.descriptor('legacy');
      const member = checked.members.filter(m => m.bytes <= MAX_TINY).sort((a, b) => a.bytes - b.bytes || a.path.localeCompare(b.path))[0];
      if (!member || this.urls.length && member.path !== this.urls[0].member.path) fail('tiny_member_missing');
      const fullPath = decodeURIComponent(member.url.pathname.slice('/storage/v1/object/sign/paper-assets/'.length));
      readerPath(fullPath);
      if (fullPath !== `reader/${this.paper.manifest_sha256}/${member.path}`) fail('legacy_path_binding');
      const token = member.url.searchParams.get('token'), parts = token.split('.');
      if (parts.length !== 3) fail('legacy_token_shape');
      const payload = json(Buffer.from(parts[1], 'base64url')), expiry = integer(payload.exp) * 1000;
      if (expiry < this.now() + 600_000 || expiry > this.now() + 930_000) fail('legacy_token_expiry');
      if (this.urls.some(old => old.member.url.href === member.url.href)) fail('legacy_tokens_not_distinct');
      this.urls.push({ member, fullPath, expiry });
    }
    for (const record of this.urls) await this.warm(record, 'initial_warm');
  }
  async warm(record, label) {
    for (let attempt = 0; attempt < 3; attempt++) {
      if (record.expiry < this.now() + 120_000) fail('legacy_expiry_too_close');
      const r = await this.http(record.member.url.href, { maximum: record.member.bytes });
      if (r.response.status !== 200 || r.bytes.length !== record.member.bytes || sha(r.bytes) !== record.member.sha256) fail('legacy_warm_integrity');
      const evidence = cacheEvidence(r.response);
      this.report(label, { url_sha256: sha(record.member.url.href), path_sha256: sha(record.fullPath),
        token_expires_at: new Date(record.expiry).toISOString(), ...evidence });
      if (evidence.cf_cache_status === 'HIT') return;
      await delay(1200);
    }
    fail('legacy_cache_hit_not_observed');
  }
  async start() {
    this.require('new'); await this.project(); this.initial = await this.snapshot('dual');
    for (const kind of ['reader', 'backend']) {
      const row = this.initial.environment_transfer.find(r => r.kind === kind);
      const used = row ? integer(row.authorized_bytes) + integer(row.reserved_bytes) : 0;
      const ceiling = integer(this.initial.policy[kind === 'reader' ? 'environment_bytes_month' : 'backend_environment_bytes_month']);
      if (ceiling - used < 12 * MiB) fail('insufficient_existing_headroom');
    }
    this.paper = await this.cachedPaper();
    if (this.saveBundle && this.paper.source_id !== '2305.18290') fail('render_export_not_authorized');
    this.report('preflight', { snapshot: this.initial, cached_source: this.paper.source_id,
      request_slot: this.paper.requested_revision, manifest_sha256: this.paper.manifest_sha256, bundle_bytes: integer(this.paper.bundle_bytes) });
    this.owner = await this.account(); this.other = await this.account(); this.item = await this.addCached(this.owner);
    const checked = await this.fullBundle('initial_bounded'); await this.negativeProbes(checked);
    await this.zeroPaid('initial_zero_paid');
    if (this.saveBundle) this.report('verified_shared_bundle_saved', this.saveBundle(this.renderBundle, this.paper.source_id));
    this.phase = 'bounded';
    this.report('initial_proof_complete', { commands: ['warm-legacy', 'status', 'abort'],
      note: 'Inspect the bounded bytes/headers before minting legacy URLs. No purge has run.' });
  }
  async warmLegacy() {
    this.require('bounded'); await this.snapshot('dual');
    await this.legacyPair(); this.phase = 'warmed';
    this.report('ready_for_explicit_purge_probe', { commands: ['probe-purge', 'status', 'abort'] });
  }
  async purgePath(path, label) {
    readerPath(path);
    const target = `${ORIGIN}/storage/v1/cdn/paper-assets/${path.split('/').map(encodeURIComponent).join('/')}`;
    for (let attempt = 0; attempt < 3; attempt++) {
      const r = await this.http(target, { method: 'DELETE', headers: this.headers(null, true), maximum: 4096 });
      const status = r.response.status;
      this.report(label, { path_sha256: sha(path), status, attempt: attempt + 1 });
      if (status === 200 && json(r.bytes)?.message === 'success') return;
      if (status === 404) fail('purge_404_unresolved');
      if (status !== 429 || attempt === 2) fail('purge_not_confirmed');
      const seconds = r.response.headers.get('retry-after');
      if (!/^\d{1,2}$/.test(seconds ?? '') || Number(seconds) > 30) fail('purge_rate_limit_needs_operator');
      await delay(Math.max(1000, Number(seconds) * 1000));
    }
  }
  async probePurge() {
    this.require('warmed'); await this.snapshot('dual');
    await this.purgePath(this.urls[0].fullPath, 'capability_purge');
    this.probeReadyAt = this.now() + LIMITS.propagationMs; this.phase = 'probe_propagating';
    this.report('capability_purge_queued', { rewarm_after: new Date(this.probeReadyAt).toISOString() });
  }
  async probeRewarm() {
    this.require('probe_propagating'); if (this.now() < this.probeReadyAt) fail('purge_propagation_wait');
    for (const record of this.urls) await this.warm(record, 'post_probe_rewarm');
    this.phase = 'purge_capable'; this.report('ready_for_external_fence', { next: 'Apply the reviewed ACL and bounded policy externally, then enter fenced.' });
  }
  async fence() {
    this.require('purge_capable'); this.fenced = await this.snapshot('bounded');
    if (this.fenced.issuer_function_hash !== this.initial.issuer_function_hash || this.fenced.legacy_function_hash !== this.initial.legacy_function_hash) fail('issuer_body_changed');
    const old = await this.http(`${ORIGIN}/rest/v1/rpc/worker_reader_descriptor`, { method: 'POST',
      headers: this.headers(null, true), body: { p_account_id: this.owner.id, p_item_id: this.item.id }, maximum: 4096 });
    if (![401, 403, 404].includes(old.response.status) || !['42501', 'PGRST202'].includes(json(old.bytes)?.code)) fail('old_rpc_not_denied');
    const legacy = await this.http(`${ORIGIN}/functions/v1/reader-artifact?item_id=${this.item.id}&transport=legacy`, {
      headers: this.headers(await this.token(this.owner)), maximum: 4096 });
    if (legacy.response.status !== 426 || json(legacy.bytes)?.code !== 'reader_upgrade_required') fail('legacy_http_not_denied');
    const checked = await this.descriptor('bounded-v1'), member = checked.members.filter(m => m.bytes <= MAX_TINY).sort((a, b) => a.bytes - b.bytes)[0];
    if (!member) fail('tiny_member_missing');
    await this.raceMember(member);
    // Take T0 after both commits AND their proofs. The legacy counter admission occurs
    // before Edge signs: never shorten 400+900 seconds based on its timestamp.
    this.fenced = await this.snapshot('bounded'); this.retireAt = time(this.fenced.at) + LIMITS.drainMs;
    this.phase = 'fenced'; this.report('fence_proved', { snapshot: this.fenced, retire_after: new Date(this.retireAt).toISOString() });
  }
  async stillFenced() {
    const state = await this.snapshot('bounded');
    if (state.policy.legacy_descriptors !== this.fenced.policy.legacy_descriptors
      || state.policy.legacy_last_issued_at !== this.fenced.policy.legacy_last_issued_at
      || state.issuer_function_hash !== this.fenced.issuer_function_hash || state.legacy_function_hash !== this.fenced.legacy_function_hash) fail('fence_changed');
    if (this.now() < this.retireAt || time(state.at) < this.retireAt) fail('issuer_drain_wait');
    return state;
  }
  async scope() {
    const before = (await this.sql(SCOPE_SIGNATURE))[0];
    if (!before || integer(before.count) < 1 || integer(before.count) > MAX_PATHS) fail('scope_count');
    let afterPath = '', rows = [];
    while (rows.length < integer(before.count)) {
      // Every interpolated cursor was checked as an ASCII reader path with no quotes.
      const page = await this.sql(`${SCOPE} select * from scope where path collate "C">'${afterPath}' collate "C" order by path collate "C" limit 250`, 131_072);
      if (!page.length || page.length > 250) fail('scope_pagination');
      for (const row of page) {
        readerPath(row.path); if (Buffer.compare(Buffer.from(row.path), Buffer.from(afterPath)) <= 0) fail('scope_cursor');
        afterPath = row.path; rows.push(row);
      }
      if (rows.length > MAX_PATHS || rows.length > integer(before.count)) fail('scope_changed');
    }
    const after = (await this.sql(SCOPE_SIGNATURE))[0];
    if (JSON.stringify(before) !== JSON.stringify(after) || rows.length !== integer(after.count)) fail('scope_changed');
    return { ...validateScope(rows), signature: after };
  }
  async planPurge() {
    this.require('fenced'); await this.stillFenced(); this.budget.reserve = CLEANUP_RESERVE + FINAL_RESERVE;
    this.plan = await this.scope();
    if (!this.plan.paths.some(p => p.path === this.urls[0].fullPath)) fail('warmed_path_outside_scope');
    this.phase = 'planned'; this.report('purge_plan', { plan_sha256: this.plan.digest, paths: this.plan.count,
      historical_absent: this.plan.historical_absent, scope_signature: this.plan.signature,
      path_sha256s: this.plan.paths.map(p => sha(p.path)), command: `purge ${this.plan.digest}` });
  }
  async purge(digest) {
    this.require('planned'); if (digest !== this.plan.digest) fail('purge_plan_confirmation');
    await this.stillFenced();
    if (JSON.stringify((await this.sql(SCOPE_SIGNATURE))[0]) !== JSON.stringify(this.plan.signature)) fail('scope_changed');
    for (let index = 0; index < this.plan.paths.length; index++) {
      await this.purgePath(this.plan.paths[index].path, 'retirement_purge');
      if (index && index % 50 === 0) await this.stillFenced();
    }
    if (JSON.stringify((await this.sql(SCOPE_SIGNATURE))[0]) !== JSON.stringify(this.plan.signature)) fail('scope_changed');
    this.verifyAt = this.now() + LIMITS.propagationMs; this.phase = 'purged';
    this.report('scope_purge_queued', { paths: this.plan.count, verify_after: new Date(this.verifyAt).toISOString() });
  }
  async verifyRetired() {
    this.require('purged'); if (this.now() < this.verifyAt) fail('purge_propagation_wait');
    await this.stillFenced(); this.budget.reserve = CLEANUP_RESERVE;
    for (const record of this.urls) {
      if (record.expiry >= this.now()) fail('token_not_expired');
      const r = await this.http(record.member.url.href, { maximum: MAX_TINY });
      const body = json(r.bytes);
      // A 404, generic 5xx or a changed/missing object is not proof of token expiry.
      if (!expiredTokenResponse(r.response.status, body)) fail('expired_warmed_url_not_proved');
      this.report('expired_warmed_url_denied', { url_sha256: sha(record.member.url.href), ...cacheEvidence(r.response) });
    }
    await this.fullBundle('final_bounded');
    const paid = await this.zeroPaid('final_zero_paid');
    if (JSON.stringify((await this.sql(SCOPE_SIGNATURE))[0]) !== JSON.stringify(this.plan.signature)) fail('scope_changed');
    this.phase = 'complete'; this.report('retirement_proved', { zero_paid: paid,
      scope_signature: this.plan.signature, limitations: 'Observed two warmed token variants at this network location; provider-wide purge propagation relies on Supabase contract. Original PDFs, Mathpix and browser/offline copies are outside scope.' });
  }
  async zeroPaid(label) {
    for (const account of this.accounts) await this.zeroBalance(account);
    const ids = this.accounts.map(a => `'${uuid(a.id)}'`).join(',');
    const paid = (await this.sql(`select
      (select count(*) from app_private.provider_attempts where account_id in (${ids})) provider_attempts,
      (select count(*) from app_private.metered_operations where account_id in (${ids})) operations,
      (select count(*) from app_private.credit_buckets where account_id in (${ids})) credit_buckets,
      (select count(*) from app_private.credit_ledger where account_id in (${ids})) ledger_rows`))[0];
    if (!paid || Object.values(paid).some(n => integer(n) !== 0)) fail('paid_activity_detected');
    this.report(label, { zero_paid: paid }); return paid;
  }
  async cleanup() {
    for (const account of [...this.accounts].reverse()) {
      let status = 'unconfirmed';
      try {
        const token = await this.token(account, true);
        for (let attempt = 0; attempt < 3; attempt++) {
          const r = await this.http(`${ORIGIN}/functions/v1/account-delete`, { method: 'POST', cleanup: true,
            headers: this.headers(token), maximum: 4096, body: { confirm: 'delete my account' } });
          const result = json(r.bytes);
          if (r.response.status === 200 && result.deleted === true) { status = result.complete === true ? 'complete' : 'closed_worker_cleanup_pending'; break; }
          if (r.response.status !== 409 || result.code !== 'account_busy') break;
          await delay(1500);
        }
      } catch { /* finite cleanup evidence, credentials remain only in memory */ }
      this.report('synthetic_cleanup', { cleanup_account_id: account.id ?? null, status });
      delete account.password; delete account.access;
    }
    this.urls.length = 0;
    delete this.renderBundle;
  }
  async command(line) {
    const parts = line.trim().split(/\s+/), action = parts[0];
    if (action === 'status') { this.report('status', { retire_after: this.retireAt ? new Date(this.retireAt).toISOString() : null,
      probe_rewarm_after: this.probeReadyAt ? new Date(this.probeReadyAt).toISOString() : null,
      verify_after: this.verifyAt ? new Date(this.verifyAt).toISOString() : null }); return; }
    if (action === 'abort') fail('operator_aborted');
    if (parts.length === 1 && action === 'warm-legacy') return this.warmLegacy();
    if (parts.length === 1 && action === 'probe-purge') return this.probePurge();
    if (parts.length === 1 && action === 'probe-rewarm') return this.probeRewarm();
    if (parts.length === 1 && action === 'fenced') return this.fence();
    if (parts.length === 1 && action === 'plan-purge') return this.planPurge();
    if (parts.length === 2 && action === 'purge' && HASH.test(parts[1])) return this.purge(parts[1]);
    if (parts.length === 1 && action === 'verify-retired') return this.verifyRetired();
    fail('unknown_command');
  }
}

function credentials() {
  let directory = ROOT;
  if (!existsSync(join(directory, '.env.staging'))) {
    try { directory = dirname(execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()); } catch { fail('secrets_directory'); }
  }
  const values = Object.fromEntries(readFileSync(join(directory, '.env.staging'), 'utf8').split('\n')
    .filter(line => line.includes('=') && !line.trimStart().startsWith('#')).map(line => {
      const split = line.indexOf('='); return [line.slice(0, split).trim(), line.slice(split + 1).trim().replace(/^(['"])(.*)\1$/, '$2')];
    }));
  for (const key of ['SUPABASE_URL', 'SUPABASE_PROJECT_REF', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_ACCESS_TOKEN'])
    if (process.env[key]) values[key] = process.env[key];
  if (!values.SUPABASE_ACCESS_TOKEN && process.platform === 'darwin') {
    try { values.SUPABASE_ACCESS_TOKEN = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { fail('management_token_required'); }
  }
  return values;
}

async function main() {
  if (process.argv.slice(2).length !== 2 || process.argv[2] !== 'staging' || process.argv[3] !== '--execute') {
    console.log('Usage: node scripts/reader-cutover-canary.mjs staging --execute\nRuns only the initial zero-paid canary; purging needs explicit stdin commands. See docs/reviews/READER_CDN_CUTOVER_20261008.md.');
    return;
  }
  const reportDir = join(ROOT, '.artifacts', 'reader-cutover', `${new Date().toISOString().replaceAll(':', '-')}-${randomUUID()}`);
  mkdirSync(reportDir, { recursive: true, mode: 0o700 }); const events = [];
  const emit = event => {
    events.push(event);
    appendFileSync(join(reportDir, 'events.jsonl'), JSON.stringify(event) + '\n', { mode: 0o600 });
    // Reports contain only explicitly shaped finite values, hashes, policy metadata and synthetic IDs.
    if (event.event !== 'retirement_purge' || event.status !== 200) console.log(JSON.stringify(event));
  };
  let canary, timer, input; const stop = new AbortController();
  const signal = () => stop.abort(); process.once('SIGINT', signal); process.once('SIGTERM', signal);
  try {
    const priorUsage = JSON.parse(process.env.GRADSTEP_READER_CANARY_PRIOR_USAGE ?? '{}');
    canary = new ReaderCutoverCanary({ env: credentials(), emit, signal: stop.signal, priorUsage,
      saveBundle: (bundle, sourceID) => saveVerifiedBundle(join(reportDir, 'verified-bundle.json'), bundle, sourceID) });
    timer = setTimeout(() => stop.abort(), LIMITS.durationMs);
    await canary.start();
    input = createInterface({ input: process.stdin, crlfDelay: Infinity, signal: stop.signal });
    for await (const line of input) {
      try { await canary.command(line); }
      catch (error) {
        const code = finiteError(error);
        if (['wrong_phase', 'unknown_command', 'purge_plan_confirmation', 'purge_propagation_wait', 'issuer_drain_wait'].includes(code)) {
          canary.report('command_refused', { code }); continue;
        }
        throw error;
      }
      if (canary.phase === 'complete') break;
    }
    if (canary.phase !== 'complete') fail(stop.signal.aborted ? 'process_interrupted' : 'stdin_closed_before_completion');
  } catch (error) {
    emit({ event: 'failed', code: finiteError(error), at: new Date().toISOString() }); process.exitCode = 1;
  } finally {
    clearTimeout(timer); input?.close();
    if (canary) await canary.cleanup();
    const tmp = join(reportDir, 'report.tmp'); writeFileSync(tmp, JSON.stringify(events, null, 2) + '\n', { mode: 0o600 });
    renameSync(tmp, join(reportDir, 'report.json'));
    process.removeListener('SIGINT', signal); process.removeListener('SIGTERM', signal);
    console.log(`Safe report: ${join(reportDir, 'report.json')}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(() => { console.error('reader_canary_startup_failed'); process.exitCode = 1; });
}

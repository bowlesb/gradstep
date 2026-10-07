#!/usr/bin/env node
// Gradstep workflow checks: the journeys a user depends on, exercised through the same
// endpoints the app uses, plus guards for the configuration a deploy can break.
// Design, costs, schedule and how to add a check: docs/architecture/WORKFLOW_CHECKS.md
//
//   node scripts/workflow-checks.mjs [--suite=deploy|daily|weekly] [--only=a,b] [--also=a,b] [--skip=a,b]
//        [--cap-usd=N] [--record] [--notify] [--trigger=manual] [--keep-accounts] [--list]
//
// Staging only. No dependencies beyond Node 24. Secrets come from the environment or from
// .env.staging / .env.providers / .env.appstore (a git worktree reads the main checkout's) and the
// macOS keychain ("Supabase CLI"); they are never printed and are redacted from the report.
import { createHash, createPrivateKey, randomBytes, randomUUID, sign } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve4, resolve6 } from 'node:dns/promises';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'coxhjvqpflgxkleydati';
const APP_STORE_APP = '6819313864';
const PRODUCTS = ['com.sciencereader.ios.standard.monthly', 'com.sciencereader.ios.pro.monthly', 'com.sciencereader.ios.credits.400'];
// beta-credits-v1: a chat credit is ⌈provider µ$ / 5000⌉ and an OCR page is 1 credit for $0.005, so
// credits × $0.005 bounds provider spend from above (Tavily searches are priced but prepaid).
const USD_PER_CREDIT = 0.005;
const CAPS_USD = { deploy: 0.05, daily: 0.5, weekly: 1.0 };
// Never let a run take the platform budget below this: testers would lose paid features.
const BUDGET_RESERVE_USD = 0.5;
const PAPER = '2310.06825'; // Mistral 7B: CC BY, shared and converted (no OCR), 9 pages (cheap context).
const CONSENT = 'cloud-ai-v2';
const DELETE_CONFIRMATION = 'delete my account';

// ── Arguments and secrets ────────────────────────────────────────────────────
const args = Object.fromEntries(process.argv.slice(2).map(a => { const [k, ...v] = a.replace(/^--/, '').split('='); return [k, v.length ? v.join('=') : 'true']; }));
const list = value => (value && value !== 'true' ? value.split(',').map(s => s.trim()).filter(Boolean) : []);
const suite = args.suite ?? 'daily';
if (!(suite in CAPS_USD)) { console.error('--suite must be deploy, daily or weekly'); process.exit(2); }
const capUSD = Number(args['cap-usd'] ?? CAPS_USD[suite]);
if (args.trigger && !/^[a-z][a-z0-9-]{0,39}$/.test(args.trigger)) { console.error('--trigger must be lowercase letters, digits and dashes'); process.exit(2); }
if (!(capUSD >= 0)) { console.error('--cap-usd must be a number'); process.exit(2); }

function secretsRoot() {
  if (process.env.WORKFLOW_SECRETS_DIR) return resolve(process.env.WORKFLOW_SECRETS_DIR);
  if (existsSync(join(ROOT, '.env.staging'))) return ROOT;
  try { // A git worktree: the secrets stay in the main checkout.
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (existsSync(join(dirname(common), '.env.staging'))) return dirname(common);
  } catch { /* not a git checkout (a container) */ }
  return null;
}
const dotenv = path => !path || !existsSync(path) ? {} : Object.fromEntries(readFileSync(path, 'utf8').split('\n')
  .filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const secretsDir = secretsRoot();
const KEYS = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_PROJECT_REF', 'PIPELINE_SECRET', 'SUPABASE_ACCESS_TOKEN',
  'ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH', 'ASC_PRIVATE_KEY', 'RESEND_API_KEY', 'WORKFLOW_ALERT_EMAIL', 'WORKFLOW_ALERT_FROM'];
const env = {
  ...dotenv(secretsDir && join(secretsDir, '.env.providers')), ...dotenv(secretsDir && join(secretsDir, '.env.staging')),
  ...dotenv(secretsDir && join(secretsDir, '.env.appstore')),
  ...Object.fromEntries(KEYS.filter(k => process.env[k]).map(k => [k, process.env[k]])),
};
if (env.SUPABASE_PROJECT_REF !== PROJECT_REF || !env.SUPABASE_URL?.startsWith(`https://${PROJECT_REF}.`)) {
  console.error('Staging only: SUPABASE_PROJECT_REF/SUPABASE_URL must name the staging project.'); process.exit(2);
}
let managementToken = env.SUPABASE_ACCESS_TOKEN ?? null;
if (!managementToken && process.platform === 'darwin') {
  try { managementToken = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || null; } catch { /* none */ }
}
const infra = JSON.parse(readFileSync(join(ROOT, 'infra/staging.json'), 'utf8'));
const ack = existsSync(join(ROOT, 'infra/workflow-checks.json')) ? JSON.parse(readFileSync(join(ROOT, 'infra/workflow-checks.json'), 'utf8')).acknowledged ?? {} : {};

// Every secret value (and every token or password made here) is removed from output.
const SECRETS = new Set([managementToken, ...Object.entries(env).filter(([k]) => /KEY|SECRET|TOKEN|PASS|PRIVATE|CREDENTIAL|_ID$/i.test(k) && !/^(ASC_KEY_PATH|GCLOUD_PROJECT_ID)$/.test(k)).map(([, v]) => v)]
  .filter(v => typeof v === 'string' && v.length >= 8));
const redact = text => {
  let out = String(text);
  for (const secret of SECRETS) out = out.split(secret).join('[redacted]');
  return out.replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[jwt]');
};
const log = (...parts) => console.log(redact(`${new Date().toISOString().slice(11, 19)} ${parts.join(' ')}`));
const sha256 = value => createHash('sha256').update(value).digest('hex');
const sleep = (ms, signal) => new Promise((done, fail) => {
  const timer = setTimeout(done, ms);
  signal?.addEventListener('abort', () => { clearTimeout(timer); fail(signal.reason ?? new Error('aborted')); }, { once: true });
});
const host = url => { try { return new URL(url).host; } catch { return String(url); } };
const usd = value => `$${value.toFixed(value < 0.1 ? 3 : 2)}`;

// ── HTTP ─────────────────────────────────────────────────────────────────────
async function http(url, { method = 'GET', headers = {}, body, timeoutMs = 30_000, signal } = {}) {
  const json = body !== undefined && typeof body !== 'string';
  const response = await fetch(url, { method, redirect: 'manual',
    headers: { ...(json ? { 'content-type': 'application/json' } : {}), ...headers },
    body: body === undefined ? undefined : json ? JSON.stringify(body) : body,
    signal: AbortSignal.any([AbortSignal.timeout(timeoutMs), ...(signal ? [signal] : [])]) });
  const text = await response.text();
  let parsed = null; try { parsed = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: response.status, json: parsed, text };
}
const anonHeaders = token => ({ apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token ?? env.SUPABASE_ANON_KEY}` });
const serviceHeaders = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
/** A PostgREST RPC; throws with the database's error text (RAISE messages are codes, never secrets). */
async function rpc(name, params, { token, service = false, signal } = {}) {
  const r = await http(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, { method: 'POST', body: params ?? {}, signal,
    headers: service ? serviceHeaders : anonHeaders(token) });
  if (r.status >= 300) {
    const error = new Error(`${name}: HTTP ${r.status} ${r.json?.message ?? r.json?.code ?? ''}`.trim());
    error.status = r.status; error.code = r.json?.code; error.dbMessage = r.json?.message; throw error;
  }
  return r.json;
}
const management = managementToken ? {
  get: async path => {
    const r = await http(`https://api.supabase.com/v1/projects/${PROJECT_REF}${path}`, { headers: { Authorization: `Bearer ${managementToken}` } });
    if (r.status >= 300) throw new Error(`Management API ${path.split('?')[0]}: HTTP ${r.status}`);
    return r.json;
  },
  // Every query here is a SELECT. The read-only role cannot decrypt Vault, so the snapshot opts out.
  sql: async (query, { readOnly = true } = {}) => {
    const r = await http(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, { method: 'POST', timeoutMs: 60_000,
      headers: { Authorization: `Bearer ${managementToken}` }, body: { query, read_only: readOnly } });
    if (r.status >= 300) throw new Error(`Management API query: HTTP ${r.status} ${String(r.json?.message ?? '').slice(0, 200)}`);
    return r.json;
  },
} : null;

// App Store Connect (dedicated key; the .p8 never leaves secrets/ or Secret Manager).
function ascToken() {
  const pem = env.ASC_PRIVATE_KEY ?? (env.ASC_KEY_PATH && secretsDir && existsSync(join(secretsDir, env.ASC_KEY_PATH)) ? readFileSync(join(secretsDir, env.ASC_KEY_PATH), 'utf8') : null);
  if (!pem || !env.ASC_KEY_ID || !env.ASC_ISSUER_ID) return null;
  const b64 = value => Buffer.from(JSON.stringify(value)).toString('base64url'), now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64({ alg: 'ES256', kid: env.ASC_KEY_ID, typ: 'JWT' })}.${b64({ iss: env.ASC_ISSUER_ID, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })}`;
  const signature = sign('sha256', Buffer.from(unsigned), { key: createPrivateKey(pem), dsaEncoding: 'ieee-p1363' }).toString('base64url');
  const token = `${unsigned}.${signature}`; SECRETS.add(token); return token;
}
async function asc(path) {
  const token = ascToken();
  if (!token) return null;
  return http(`https://api.appstoreconnect.apple.com${path}`, { headers: { Authorization: `Bearer ${token}` } });
}

// ── Pipeline snapshot: one read of everything the config/stuck checks need ───
// Prefers the service-role RPC (migration 024; no management token needed, e.g. in Cloud Run);
// before 024 is applied it runs the same query through the Management API (read-only).
// Keep SNAPSHOT_SQL in step with public.worker_workflow_snapshot().
const SNAPSHOT_SQL = `with resting as (
 select pp.id from app_private.pipeline_papers pp where pp.owner_id is null and pp.stage='private_split'
  and not exists(select 1 from app_private.pipeline_imports pi join app_private.import_requests i on (i.account_id,i.id)=(pi.account_id,pi.import_id)
   where pi.paper_id=pp.id and i.desired_present and i.phase in ('accepted','resolving','acquiring'))),
working as (select pp.* from app_private.pipeline_papers pp where pp.stage not in ('done','failed','source_only','needs_credits')
 and pp.id not in (select id from resting))
select jsonb_build_object(
 'source','management',
 'pipeline_url',(select decrypted_secret from vault.decrypted_secrets where name='science_reader_pipeline_url'),
 'pipeline_secret_sha256',(select encode(sha256(convert_to(decrypted_secret,'UTF8')),'hex') from vault.decrypted_secrets where name='science_reader_pipeline_secret'),
 'cron',(select jsonb_build_object('active',active,'schedule',schedule) from cron.job where jobname='science-reader-pipeline'),
 'worker_calls',(select jsonb_build_object('ok',count(*) filter (where status_code between 200 and 299),
   'unauthorized',count(*) filter (where status_code in (401,403)),'missing',count(*) filter (where status_code=404),
   'server',count(*) filter (where status_code>=500),'timed_out',count(*) filter (where timed_out),
   'last_ok',max(created) filter (where status_code between 200 and 299)) from net._http_response where created>now()-interval '15 minutes'),
 'pipeline_enabled',(select enabled from app_private.pipeline_policy),
 'budget',(select jsonb_build_object('work_enabled',work_enabled,'limit_microusd',limit_microusd,'spent_microusd',spent_microusd,'reserved_microusd',reserved_microusd)
   from app_private.platform_budgets where period=date_trunc('month',now() at time zone 'UTC')::date),
 'stuck',(select coalesce(jsonb_agg(jsonb_build_object('source',source_id,'private',owner_id is not null,'stage',stage,
   'minutes',floor(extract(epoch from (now()-stage_entered_at))/60),'claims',stage_claims,'crashes',stage_crashes) order by stage_entered_at),'[]')
   from working where stage_entered_at<now()-interval '15 minutes'),
 'looping',(select coalesce(jsonb_agg(jsonb_build_object('source',source_id,'stage',stage,'claims',stage_claims,'crashes',stage_crashes)),'[]')
   from working where stage_crashes>=2 or (stage<>'ocr_wait' and stage_claims>=30)),
 'resting_split',(select count(*) from resting),
 'uncertain_ocr',(select count(*) from app_private.ocr_attempts where state='uncertain'),
 'stale_imports',(select count(*) from app_private.import_requests where desired_present and phase in ('accepted','resolving','acquiring')
   and created_at<now()-interval '60 minutes'),
 'crashes_24h',(select coalesce(jsonb_object_agg(stage,n),'{}') from (select stage,count(*) n from app_private.pipeline_events
   where kind='crash' and at>now()-interval '24 hours' group by stage) c),
 'import_failures_24h',(select coalesce(jsonb_object_agg(cause,n),'{}') from (select coalesce(error_code,'unknown') cause,count(*) n
   from app_private.pipeline_events where kind='import' and phase='failed' and at>now()-interval '24 hours' group by 1) f)) as snapshot`;
let snapshotCache = null;
async function snapshot({ fresh = false } = {}) {
  if (snapshotCache && !fresh) return snapshotCache;
  try { snapshotCache = { ...(await rpc('worker_workflow_snapshot', {}, { service: true })), source: 'rpc' }; return snapshotCache; } catch (error) {
    if (!/404|PGRST202|Could not find/.test(`${error.status} ${error.code} ${error.dbMessage}`)) throw error;
  }
  if (!management) throw new Error('needs migration 024 (worker_workflow_snapshot) or a management token');
  snapshotCache = (await management.sql(SNAPSHOT_SQL, { readOnly: false }))[0].snapshot;
  return snapshotCache;
}

// ── Synthetic accounts (service role; @example.invalid; deleted at the end) ──
const accounts = [];
class Account {
  constructor(label, id, email, password, granted) { Object.assign(this, { label, id, email, password, granted, tokenAt: 0, available: granted, touched: false }); }
  static async create(label, credits) {
    const email = `gradstep-check-${label}-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
    SECRETS.add(password);
    const created = await http(`${env.SUPABASE_URL}/auth/v1/admin/users`, { method: 'POST', headers: serviceHeaders, body: { email, password, email_confirm: true } });
    if (created.status >= 300 || !created.json?.id) throw new Error(`creating a synthetic account: HTTP ${created.status}`);
    const account = new Account(label, created.json.id, email, password, credits);
    accounts.push(account);
    if (credits > 0) await rpc('worker_grant_credits', { p_account_id: account.id, p_source: 'adjustment', p_external_key: `operator:workflow-check:${account.id}`,
      p_credits: credits, p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Workflow check synthetic grant' }, { service: true });
    return account;
  }
  async token() {
    if (this.access && Date.now() - this.tokenAt < 40 * 60_000) return this.access;
    const r = await http(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body: { email: this.email, password: this.password } });
    if (r.status !== 200 || !r.json?.access_token) throw new Error(`password sign-in for a synthetic account: HTTP ${r.status}`);
    this.access = r.json.access_token; this.tokenAt = Date.now(); SECRETS.add(this.access);
    return this.access;
  }
  async rpc(name, params, signal) { this.touched = true; return rpc(name, params, { token: await this.token(), signal }); }
  async balance() { const b = await this.rpc('v1_credit_balance', {}); return { available: Number(b.available), held: Number(b.held ?? 0) }; }
  async entries(signal) {
    const all = []; let cursor = null;
    for (let page = 0; page < 5; page++) {
      const r = await this.rpc('v3_library_page', { p_cursor: cursor, p_limit: 100 }, signal);
      all.push(...r.entries);
      if (!r.has_more || !r.next_cursor) return { entries: all, cursor: r.baseline_cursor };
      cursor = r.next_cursor;
    }
    return { entries: all, cursor: null };
  }
  async fn(path, init = {}) {
    this.touched = true;
    return http(`${env.SUPABASE_URL}/functions/v1/${path}`, { ...init, headers: { ...anonHeaders(await this.token()), ...(init.headers ?? {}) } });
  }
}
const pool = {};
async function account(label, credits) { pool[label] ??= Account.create(label, credits); return pool[label]; }

// ── Journey helpers ──────────────────────────────────────────────────────────
async function beginImport(acct, sourceID, signal) {
  const { cursor } = await acct.entries(signal);
  const r = await acct.rpc('v2_begin_import', { p_operation_id: randomUUID(), p_source_id: sourceID, p_observed_cursor: cursor ?? 0 }, signal);
  if (r.result?.status !== 'applied' && !r.replayed) throw new Error(`v2_begin_import ${sourceID}: ${r.result?.status ?? 'no result'}`);
  return r.entry ?? r;
}

const STUCK_SECONDS = { converting: 20 * 60, default: Number(args['stuck-minutes'] ?? 7) * 60 };
/** Waits for an import to become a readable item. Fails early on a terminal phase, a step
 * that does not move for too long (the silent-loop symptom), or a worker crash on its paper. */
async function waitForReady(acct, match, { timeoutS, signal, label }) {
  const started = Date.now(), steps = []; let last = null, stepSince = Date.now(), crashCheckAt = 0;
  while (Date.now() - started < timeoutS * 1000) {
    const { entries } = await acct.entries(signal);
    const imported = entries.find(e => e.kind === 'import' && match(e));
    const item = entries.find(e => e.kind === 'item' && (imported?.library_item_id ? e.id === imported.library_item_id : match(e)));
    if (item?.readiness === 'converted_ready') return { item, seconds: Math.round((Date.now() - started) / 1000), steps };
    if (!imported && !item) throw new Error(`${label}: not in the library`);
    if (imported && ['failed', 'cancelled', 'source_only', 'membership_conflict'].includes(imported.phase))
      throw new Error(`${label}: import ${imported.phase}${imported.error_code ? ` (${imported.error_code}${imported.retryable ? ', retryable' : ''})` : ''} after ${Math.round((Date.now() - started) / 1000)} s`);
    const state = item ? `item:${item.readiness}` : `${imported.phase}:${imported.progress ?? '-'}`;
    if (state !== last) { steps.push({ state, at_s: Math.round((Date.now() - started) / 1000) }); log(`  ${label}: ${state}`); last = state; stepSince = Date.now(); }
    const limit = STUCK_SECONDS[imported?.progress] ?? STUCK_SECONDS.default;
    if (Date.now() - stepSince > limit * 1000) throw new Error(`${label}: stuck in "${state}" for ${Math.round((Date.now() - stepSince) / 60000)} min (silent loop?)`);
    if (management && imported?.source_id && Date.now() - crashCheckAt > 30_000) {
      crashCheckAt = Date.now();
      const since = new Date(started - 5000).toISOString();
      const rows = await management.sql(`select stage,count(*) n from app_private.pipeline_events where kind='crash' and at>='${since}'
        and source_id like '${imported.source_id.replace(/[^\w.:]/g, '')}%' group by stage`).catch(() => []);
      if (rows.length) throw new Error(`${label}: the worker died in ${rows.map(r => `${r.stage} (${r.n}×)`).join(', ')} — lease expired while claimed`);
    }
    await sleep(5000, signal);
  }
  throw new Error(`${label}: not ready after ${timeoutS} s (last state ${last})`);
}

/** Downloads the reader bundle as the app does and verifies every member's SHA-256. */
async function verifyBundle(acct, itemID, signal) {
  const r = await acct.fn(`reader-artifact?item_id=${itemID}`, { signal, timeoutMs: 30_000 });
  if (r.status !== 200 || !r.json?.manifest_sha256) throw new Error(`reader-artifact: HTTP ${r.status} ${r.json?.code ?? ''}`);
  if (sha256(Buffer.from(r.json.manifest, 'base64')) !== r.json.manifest_sha256) throw new Error('reader manifest hash mismatch');
  let bytes = 0;
  for (const member of r.json.members) {
    const response = await fetch(member.url, { signal: AbortSignal.any([AbortSignal.timeout(60_000), signal]) });
    const body = Buffer.from(await response.arrayBuffer()); bytes += body.length;
    if (!response.ok || sha256(body) !== member.sha256) throw new Error(`reader member ${member.path}: ${response.ok ? 'hash mismatch' : `HTTP ${response.status}`}`);
  }
  return { members: r.json.members.length, bytes };
}

/** One answer from functions/v1/chat, streamed and parsed like the app's SSE parser. */
async function chat(acct, body, { signal, timeoutMs = 180_000 } = {}) {
  const started = Date.now();
  const operation = randomUUID();
  const response = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', redirect: 'error',
    headers: { ...anonHeaders(await acct.token()), 'content-type': 'application/json', accept: 'text/event-stream' },
    body: JSON.stringify({ operation_id: operation, consent_version: CONSENT, ...body }),
    signal: AbortSignal.any([AbortSignal.timeout(timeoutMs), signal]) });
  acct.touched = true;
  const result = { operation, status: response.status, answer: '', done: null, error: null, diagram: null, firstTokenMs: null, ms: 0 };
  if (response.status !== 200) { result.error = { code: (await response.json().catch(() => ({}))).code ?? `http_${response.status}` }; return result; }
  const decoder = new TextDecoder(); let buffer = '';
  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let cut;
    while ((cut = buffer.indexOf('\n\n')) >= 0) {
      const block = buffer.slice(0, cut); buffer = buffer.slice(cut + 2);
      const event = /^event: (\w+)/m.exec(block)?.[1], data = /^data: (.*)$/m.exec(block)?.[1];
      if (!event || !data) continue;
      const value = JSON.parse(data);
      if (event === 'delta') { result.firstTokenMs ??= Date.now() - started; result.answer += value.text; }
      else if (event === 'done') result.done = value; else if (event === 'error') result.error = value; else if (event === 'diagram') result.diagram = value;
    }
  }
  result.ms = Date.now() - started;
  return result;
}
const chatSummary = r => r.error ? `error ${r.error.code}` : r.done ? `done ${r.done.stop_reason}, ${r.done.credits} credits` : 'ended without done';

/** The paper used for paper-chat checks (Mistral 7B unless --paper), added once per run. */
async function chatDocument(acct, signal) {
  shared.chatPaper ??= await readyPaper(acct, args.paper ?? PAPER, signal);
  return shared.chatPaper;
}
async function readyPaper(acct, sourceID, signal) {
  const { entries } = await acct.entries(signal);
  let item = entries.find(e => e.kind === 'item' && e.source_id === sourceID && e.readiness === 'converted_ready');
  if (!item) { await beginImport(acct, sourceID, signal); item = (await waitForReady(acct, e => e.source_id === sourceID, { timeoutS: 180, signal, label: sourceID })).item; }
  return item;
}

// Ingest outcome lines (supabase/functions/_shared/chat.ts ingestReport); the last one in an answer wins.
const OUTCOMES = [
  ['queued', /Queued “(.+?)” \((arXiv:[\w./-]+|open-access PDF(?: from ([^)]+))?)\) for your library\./],
  ['present', /“(.+?)” \((arXiv:[\w./-]+|open-access PDF(?: from ([^)]+))?)\) is already in your library\./],
  ['closed', /“(.+?)” isn't openly available \(no arXiv or open-access copy\), so it wasn't added\.(?: It's at (\S+))?/],
  ['not_found', /I couldn't find “(.+?)” on arXiv or as an open-access paper, so it wasn't added\./],
  ['needs_update', /isn't on arXiv\. Adding open-access papers from other sites needs the latest/],
  ['failed', /I found .+ but couldn't add it right now\./],
  ['unavailable', /I couldn't search for “.+?” right now, so it wasn't added\./],
  ['invalid_input', /I couldn’t read the paper’s details, so it wasn’t added\./],
];
function ingestOutcome(answer) {
  let best = null;
  for (const [kind, pattern] of OUTCOMES) {
    const global = new RegExp(pattern.source, 'g'); let m;
    while ((m = global.exec(answer))) if (!best || m.index > best.index) best = { kind, index: m.index, match: m, line: m[0] };
  }
  return best;
}

// ── Check catalog ────────────────────────────────────────────────────────────
// Each check: id, title, suites, timeout (s), estimated provider cost (USD), and run(ctx) that
// returns { status: 'pass'|'fail'|'warn'|'skip', reason, metrics? } or throws (→ fail).
const ALL = ['deploy', 'daily', 'weekly'], SCHEDULED = ['daily', 'weekly'];
const CHECKS = [];
const check = (id, options, run) => CHECKS.push({ id, ...options, run });
const pass = (reason, metrics) => ({ status: 'pass', reason, metrics });
const fail = (reason, metrics) => ({ status: 'fail', reason, metrics });
const warn = (reason, metrics) => ({ status: 'warn', reason, metrics });
const skip = reason => ({ status: 'skip', reason });
const shared = {};

check('config.pipeline-url', { title: 'Pipeline URL is the Cloud Run worker', suites: ALL, timeout: 60 }, async () => {
  const s = await snapshot(), expected = infra.pipeline_worker_url;
  if (!s.pipeline_url) return fail('Vault science_reader_pipeline_url is missing: imports never start');
  if (s.pipeline_url !== expected) {
    const edge = /\.supabase\.co\/functions\/v1\/paper-worker/.test(s.pipeline_url);
    return fail(`Vault points at ${edge ? 'the retired Edge paper-worker' : host(s.pipeline_url)}, not ${host(expected)} (infra pipeline_worker_url)`);
  }
  if (!/\.run\.app$/.test(host(expected))) return fail(`infra pipeline_worker_url ${host(expected)} is not a Cloud Run service`);
  return pass(`Vault → ${host(expected)} (snapshot via ${s.source})`);
});

check('config.worker-endpoint', { title: 'Worker answers /health and refuses calls without the secret', suites: ALL, timeout: 90 }, async () => {
  const base = infra.pipeline_worker_url.replace(/\/$/, '');
  // Cloud Run answers 429 while every instance is busy with a paper (concurrency 1): wait and ask again.
  let health = await http(`${base}/health`, { timeoutMs: 60_000 });
  for (let i = 0; i < 3 && health.status === 429; i++) {
    await new Promise(resolve => setTimeout(resolve, 15_000));
    health = await http(`${base}/health`, { timeoutMs: 20_000 });
  }
  if (health.status === 429) return warn('every worker instance is busy (HTTP 429 for 45 s); the scheduler retries each minute');
  if (health.status !== 200 || health.json?.ok !== true) return fail(`/health answered HTTP ${health.status}`);
  const none = await http(base, { method: 'POST', body: { reason: 'workflow-check' } });
  const wrong = await http(base, { method: 'POST', body: { reason: 'workflow-check' }, headers: { 'x-pipeline-secret': randomBytes(48).toString('base64url') } });
  if (none.status === 429 || wrong.status === 429) return warn('health ok, but the secret checks met busy instances (HTTP 429)');
  if (none.status !== 401 || wrong.status !== 401) return fail(`calls without/with a wrong secret answered HTTP ${none.status}/${wrong.status}, expected 401/401`);
  return pass('health ok; missing and wrong secrets refused (401)');
});

check('config.worker-calls', { title: 'Database scheduler reaches the worker', suites: ALL, timeout: 60 }, async () => {
  const s = await snapshot(), calls = s.worker_calls ?? {};
  if (!s.cron) return fail('pg_cron job science-reader-pipeline is missing: nothing processes imports');
  if (!s.cron.active) return fail('pg_cron job science-reader-pipeline is inactive');
  if (s.cron.schedule !== infra.pipeline_schedule) return fail(`cron schedule ${s.cron.schedule} differs from infra ${infra.pipeline_schedule}`);
  const summary = `last 15 min: ${calls.ok} ok, ${calls.timed_out} past pg_net's timeout, ${calls.unauthorized} refused, ${calls.missing} not found, ${calls.server} server errors`;
  if (calls.unauthorized > 0) return fail(`the worker refuses the Vault secret — ${summary}`);
  if (calls.missing > 0 || calls.server > 0) return fail(`worker errors — ${summary}`);
  if (!calls.ok) return calls.timed_out ? warn(`no call finished inside pg_net's timeout (worker busy or slow) — ${summary}`) : fail(`no worker calls recorded — ${summary}`);
  return pass(summary, { worker_calls_ok: calls.ok });
});

check('config.pipeline-secret', { title: 'Pipeline secret is consistent', suites: ALL, timeout: 60 }, async () => {
  const s = await snapshot();
  if (!s.pipeline_secret_sha256) return fail('Vault science_reader_pipeline_secret is missing');
  if (!env.PIPELINE_SECRET) return skip('no local PIPELINE_SECRET to compare (scheduler acceptance is checked by config.worker-calls)');
  if (s.pipeline_secret_sha256 !== sha256(env.PIPELINE_SECRET)) return fail('Vault pipeline secret differs from .env.staging PIPELINE_SECRET (a rotation half-applied?)');
  return pass('Vault secret matches .env.staging (compared as SHA-256)');
});

check('config.edge-functions', { title: 'Edge functions are deployed and active', suites: ALL, timeout: 60 }, async () => {
  const expected = infra.functions;
  if (management) {
    const deployed = await management.get('/functions');
    const missing = expected.filter(name => !deployed.some(f => f.slug === name));
    const inactive = deployed.filter(f => expected.includes(f.slug) && f.status !== 'ACTIVE').map(f => `${f.slug} ${f.status}`);
    if (missing.length || inactive.length) return fail([missing.length && `missing: ${missing.join(', ')}`, inactive.length && `not active: ${inactive.join(', ')}`].filter(Boolean).join('; '));
    const retired = deployed.some(f => f.slug === 'paper-worker') ? '; retired paper-worker still deployed (unscheduled)' : '';
    return pass(`${expected.length} active${retired}`);
  }
  // Without a management token: each function must exist (the gateway answers 404 NOT_FOUND otherwise).
  const absent = [];
  for (const name of expected) {
    const r = await http(`${env.SUPABASE_URL}/functions/v1/${name}`, { method: 'OPTIONS', headers: { origin: 'https://invalid.example' } });
    if (r.status === 404) absent.push(name);
  }
  return absent.length ? fail(`not deployed: ${absent.join(', ')}`) : pass(`${expected.length} answer (probed; no management token)`);
});

check('config.function-secrets', { title: 'Function secrets exist (names only)', suites: ALL, timeout: 60 }, async () => {
  if (!management) return skip('needs a management token');
  // What the deployed functions read (OCR keys live with the Cloud Run worker, not here).
  const required = ['ADMIN_ORIGINS', 'CHAT_WEB_SEARCH', 'ANTHROPIC_API_KEY', 'TAVILY_API_KEY', 'APP_STORE_BUNDLE_ID', 'APP_STORE_ENVIRONMENTS', 'APP_STORE_ONLINE_CHECKS'];
  const secrets = await management.get('/secrets');
  const missing = required.filter(name => !secrets.some(s => s.name === name));
  if (missing.length) return fail(`missing function secrets: ${missing.join(', ')}`);
  // Values are listed as SHA-256 digests; the web-search switch must match infra.
  const search = secrets.find(s => s.name === 'CHAT_WEB_SEARCH')?.value, want = infra.chat_web_search ? 'on' : 'off';
  if (search && [sha256('on'), sha256('off')].includes(search) && search !== sha256(want)) return fail(`CHAT_WEB_SEARCH is ${want === 'on' ? 'off' : 'on'}, infra says ${want}`);
  return pass(`${required.length} required present; web search ${want}`);
});

check('config.pipeline-budget', { title: 'Pipeline enabled with budget headroom', suites: ALL, timeout: 60 }, async () => {
  const s = await snapshot(), b = s.budget;
  if (!s.pipeline_enabled) return fail('pipeline_policy.enabled is false: no paper converts');
  if (!b) return fail('no platform budget row for this month: paid work (OCR, chat) is refused');
  if (!b.work_enabled) return fail('platform budget work_enabled is false: paid work is paused');
  const limit = b.limit_microusd / 1e6, left = (b.limit_microusd - b.spent_microusd - b.reserved_microusd) / 1e6;
  shared.headroomUSD = left;
  const text = `${usd(left)} of ${usd(limit)} left this month (${Math.round(100 * (1 - left / limit))}% used, ${usd(b.reserved_microusd / 1e6)} reserved)`;
  if (left < BUDGET_RESERVE_USD) return fail(`${text}: paid features stop soon for every tester`);
  if (left < 0.25 * limit) return warn(`${text}: below 25%`, { headroom_usd: left });
  return pass(text, { headroom_usd: left });
});

check('pipeline.stuck', { title: 'No import stuck or crash-looping', suites: ALL, timeout: 60 }, async () => {
  const s = await snapshot({ fresh: true });
  const problems = [];
  for (const p of s.stuck ?? []) problems.push(`${p.source}${p.private ? ' (private)' : ''} in ${p.stage} for ${p.minutes} min (${p.claims} claims, ${p.crashes} crashes)`);
  for (const p of s.looping ?? []) if (!(s.stuck ?? []).some(x => x.source === p.source && x.stage === p.stage)) problems.push(`${p.source} looping in ${p.stage} (${p.claims} claims, ${p.crashes} crashes)`);
  if (s.uncertain_ocr) problems.push(`${s.uncertain_ocr} OCR submission(s) uncertain (operator: pipeline-ops.py resolve)`);
  if (s.stale_imports) problems.push(`${s.stale_imports} import(s) unresolved for over an hour`);
  const crashes = Object.entries(s.crashes_24h ?? {}).map(([stage, n]) => `${stage} ${n}`).join(', ');
  const failures = Object.entries(s.import_failures_24h ?? {}).map(([code, n]) => `${code} ${n}`).join(', ');
  const context = `24 h: crashes ${crashes || 'none'}; failed imports ${failures || 'none'}; ${s.resting_split} idle shared private_split rows not counted`;
  const metrics = { stuck: (s.stuck ?? []).length, crashes_24h: Object.values(s.crashes_24h ?? {}).reduce((a, b) => a + b, 0) };
  if (problems.length) return fail(`${problems.slice(0, 4).join('; ')}${problems.length > 4 ? `; +${problems.length - 4} more` : ''} — ${context}`, metrics);
  // A cluster of one failure cause is usually a systematic bug, not a paywalled paper.
  const cluster = Object.entries(s.import_failures_24h ?? {}).find(([, n]) => n >= 5);
  if (crashes || cluster) return warn(`nothing stuck now, but ${crashes ? 'the worker crashed' : `${cluster[1]} imports failed with ${cluster[0]}`} — ${context}`, metrics);
  return pass(`nothing stuck — ${context}`, metrics);
});

check('auth.providers', { title: 'Sign in with Apple and email codes are on', suites: SCHEDULED, timeout: 30 }, async () => {
  const r = await http(`${env.SUPABASE_URL}/auth/v1/settings`, { headers: { apikey: env.SUPABASE_ANON_KEY } });
  if (r.status !== 200) return fail(`auth settings: HTTP ${r.status}`);
  shared.auth = r.json;
  const off = ['apple', 'email'].filter(p => r.json.external?.[p] !== true);
  return off.length ? fail(`disabled: ${off.join(', ')} — the app's sign-in buttons fail`) : pass('Apple and email enabled');
});

check('auth.google', { title: 'Google sign-in works (the app shows "Continue with Google")', suites: SCHEDULED, timeout: 30 }, async () => {
  const settings = shared.auth ?? (await http(`${env.SUPABASE_URL}/auth/v1/settings`, { headers: { apikey: env.SUPABASE_ANON_KEY } })).json;
  return settings?.external?.google === true ? pass('Google provider enabled')
    : fail('Supabase Auth Google provider is disabled, but the app offers "Continue with Google" (needs a Gradstep OAuth client)');
});

check('auth.email-delivery', { title: 'Email codes can reach new testers', suites: SCHEDULED, timeout: 30 }, async () => {
  const settings = shared.auth ?? (await http(`${env.SUPABASE_URL}/auth/v1/settings`, { headers: { apikey: env.SUPABASE_ANON_KEY } })).json;
  const notes = [];
  if (settings?.disable_signup) notes.push('signups are disabled (invite-only): an address without an account gets no code');
  if (management) {
    const config = await management.get('/config/auth');
    const domain = String(config.smtp_admin_email ?? '').split('@')[1] ?? '';
    if (!config.smtp_host) notes.push("no custom SMTP: Supabase's default sender only reaches team addresses");
    else if (/(^|\.)resend\.dev$/i.test(domain)) return fail(`sender is Resend's test address (@${domain}), which only delivers to the Resend account owner${notes.length ? `; ${notes.join('; ')}` : ''}`);
    else if (/resend\.com$/i.test(config.smtp_host) && (env.RESEND_FULL_ACCESS_KEY ?? env.RESEND_API_KEY)) {
      // Resend sends from a domain only once its DNS records verify (listing needs a full-access key).
      const domains = await http('https://api.resend.com/domains', { headers: { Authorization: `Bearer ${env.RESEND_FULL_ACCESS_KEY ?? env.RESEND_API_KEY}` } });
      const record = domains.status === 200 ? (domains.json?.data ?? []).find(d => d.name === domain) : null;
      if (domains.status === 200 && record?.status !== 'verified') return fail(`sender domain ${domain} is ${record ? record.status : 'not added'} in Resend: codes are not delivered`);
      if (domains.status === 200) notes.unshift(`sender @${domain} verified in Resend`);
    }
    if (config.smtp_host && !notes.some(n => n.startsWith('sender @'))) notes.unshift(`sender @${domain}`);
  }
  const problems = notes.filter(n => !n.startsWith('sender @'));
  return problems.length ? warn(notes.join('; ')) : pass(`${notes.join('; ') || 'email codes on'}${management ? '' : ' (sender not checked: no management token)'}`);
});

check('store.app-price', { title: 'App Store app has a price and availability', suites: SCHEDULED, timeout: 60 }, async () => {
  const price = await asc(`/v1/apps/${APP_STORE_APP}/appPriceSchedule`);
  if (!price) return skip('no App Store Connect key (.env.appstore / ASC_PRIVATE_KEY)');
  if (price.status === 404) return fail('the app has no price schedule: subscriptions and the credit pack cannot be offered');
  if (price.status !== 200) return fail(`appPriceSchedule: HTTP ${price.status}`);
  const availability = await asc(`/v1/apps/${APP_STORE_APP}/appAvailabilityV2`);
  if (availability.status !== 200) return fail(`no app availability (HTTP ${availability.status}): products are not offered`);
  return pass('price schedule and availability set');
});

check('store.products', { title: 'Credit products are ready for sandbox purchases', suites: SCHEDULED, timeout: 60 }, async () => {
  const groups = await asc(`/v1/apps/${APP_STORE_APP}/subscriptionGroups?include=subscriptions&limit=50`);
  if (!groups) return skip('no App Store Connect key (.env.appstore / ASC_PRIVATE_KEY)');
  const iaps = await asc(`/v1/apps/${APP_STORE_APP}/inAppPurchasesV2?limit=50`);
  if (groups.status !== 200 || iaps.status !== 200) return fail(`App Store Connect: HTTP ${groups.status}/${iaps.status}`);
  const states = Object.fromEntries([...(groups.json.included ?? []).filter(x => x.type === 'subscriptions'), ...(iaps.json.data ?? [])]
    .map(p => [p.attributes.productId, p.attributes.state]));
  const usable = ['READY_TO_SUBMIT', 'WAITING_FOR_REVIEW', 'IN_REVIEW', 'PENDING_BINARY_APPROVAL', 'APPROVED'];
  const text = PRODUCTS.map(id => `${id.split('.').slice(-2).join('.')} ${states[id] ?? 'MISSING'}`).join(', ');
  return PRODUCTS.every(id => usable.includes(states[id])) ? pass(text) : fail(`Get credits shows no products for: ${PRODUCTS.filter(id => !usable.includes(states[id])).map(id => id.split('.').slice(-2).join('.')).join(', ')} — ${text}`);
});

// Real open-access locations on different hosts, downloaded through the pipeline's own code
// (fetchFirstWebPDF, with its DNS checks; nothing stored, no OCR). Each found by the 2026-10-07 survey
// (PIPELINE_RELIABILITY.md "Self-healing downloads"). Expected: 'pdf', or the reason readers would see.
const DOWNLOAD_CORPUS = [
  ['zenodo record', 'https://zenodo.org/record/38240', 'pdf'], // the 2026-10-07 incident (406, then landing page)
  ['zenodo DOI', 'https://doi.org/10.5281/zenodo.38240', 'pdf'],
  ['EPrints repository', 'https://research.gold.ac.uk/id/eprint/29758/', 'pdf'],
  ['HAL', 'https://hal.science/hal-04848132', 'pdf'],
  // Downloads from a home or office address, but refuses Google Cloud's (where the worker and scheduled checks run).
  ['DSpace 7 (localhost link)', 'https://aura.abdn.ac.uk/items/669c2d31-a1b5-4561-a9a6-8d0bda892553', 'pdf|source_blocked'],
  ['PubMed Central (open data)', 'https://pmc.ncbi.nlm.nih.gov/articles/PMC4103590/', 'pdf'],
  ['PMLR (http link)', 'https://proceedings.mlr.press/v37/ioffe15.html', 'pdf'],
  ['JMLR', 'https://jmlr.org/papers/v15/srivastava14a.html', 'pdf'],
  ['ACL Anthology (unquoted)', 'https://aclanthology.org/N19-1423/', 'pdf'],
  ['CVF', 'https://openaccess.thecvf.com/content_cvpr_2016/html/He_Deep_Residual_Learning_CVPR_2016_paper.html', 'pdf'],
  ['OpenReview (Turnstile)', 'https://openreview.net/pdf?id=YicbFdNTTy', 'source_blocked'],
  ['arXiv via the web path', 'https://arxiv.org/pdf/1706.03762v7', 'download_failed'], // refused without a request: arXiv has its own path
];
check('downloads.corpus', { title: 'Open-access PDFs download from each kind of host (pipeline code, no OCR)', suites: ALL, timeout: 240 }, async ({ signal }) => {
  const web = await import(pathToFileURL(join(ROOT, 'supabase/functions/_shared/web-source.ts')).href);
  const resolveHost = async name => {
    const answers = await Promise.allSettled([resolve4(name), resolve6(name)]);
    const addresses = answers.flatMap(a => a.status === 'fulfilled' ? a.value : []);
    if (!addresses.length) throw new Error('dns_unresolved');
    return addresses;
  };
  const attempt = async url => {
    const budget = AbortSignal.any([signal, AbortSignal.timeout(60_000)]);
    try { const r = await web.fetchFirstWebPDF(fetch, [url], 64 * 1024 * 1024, resolveHost, budget); return { outcome: 'pdf', bytes: r.bytes.length }; }
    catch (error) { if (error instanceof web.WebSourceError) return { outcome: error.code, transient: !error.permanent }; throw error; }
  };
  const results = [];
  for (let i = 0; i < DOWNLOAD_CORPUS.length; i += 4) {
    results.push(...await Promise.all(DOWNLOAD_CORPUS.slice(i, i + 4).map(async ([name, url, expected]) => {
      let r = await attempt(url);
      if (!expected.split('|').includes(r.outcome) && r.transient) { await sleep(5000, signal); r = await attempt(url); } // one more try for a busy host
      return { name, expected, ...r };
    })));
  }
  // The arXiv path itself (one polite request): arXiv-hosted papers download through it.
  const arxiv = await fetch('https://arxiv.org/pdf/1706.03762v7', { headers: { 'user-agent': web.WEB_USER_AGENT }, signal: AbortSignal.any([signal, AbortSignal.timeout(60_000)]) })
    .then(async r => { const b = Buffer.from(await r.arrayBuffer()); return r.ok && b.subarray(0, 5).toString() === '%PDF-' ? { outcome: 'pdf', bytes: b.length } : { outcome: `http_${r.status}`, transient: r.status === 429 || r.status >= 500 }; })
    .catch(() => ({ outcome: 'unreachable', transient: true }));
  results.push({ name: 'arXiv (arXiv path)', expected: 'pdf', ...arxiv });
  // 'a|b': either outcome is right (a host that refuses some networks but not others).
  const fits = r => r.expected.split('|').includes(r.outcome), refusal = r => !r.expected.split('|').includes('pdf');
  const wrong = results.filter(r => !fits(r) && !r.transient), flaky = results.filter(r => !fits(r) && r.transient);
  const opened = results.filter(r => refusal(r) && r.outcome === 'pdf');
  const text = r => `${r.name}: ${r.outcome}${fits(r) ? '' : ` (expected ${r.expected})`}`;
  const metrics = { downloads_ok: results.filter(r => r.outcome === 'pdf').length, download_mb: +(results.reduce((n, r) => n + (r.bytes ?? 0), 0) / 1e6).toFixed(1) };
  const summary = `${results.length - wrong.length - flaky.length}/${results.length} as expected`;
  if (wrong.filter(r => !opened.includes(r)).length) return fail(`${summary} — ${wrong.filter(r => !opened.includes(r)).map(text).join('; ')} (a reader adding these papers would hit it)`, metrics);
  if (flaky.length || opened.length) return warn(`${summary} — ${[...flaky.map(r => `${text(r)}, host busy or unreachable`), ...opened.map(r => `${r.name} now downloads: update the corpus`)].join('; ')}`, metrics);
  return pass(`${summary}: ${results.filter(r => r.outcome === 'pdf').length} PDFs (${metrics.download_mb} MB), refusals classified (${results.filter(r => refusal(r) || r.outcome !== 'pdf').map(r => `${r.name} → ${r.outcome}`).join(', ')})`, metrics);
});

check('import.arxiv', { title: 'Add an arXiv paper → ready → reader bundle verified', suites: ALL, timeout: 300 }, async ({ signal }) => {
  const acct = await account('library', 60), source = '2305.18290';
  const started = Date.now();
  await beginImport(acct, source, signal);
  const { item, seconds, steps } = await waitForReady(acct, e => e.source_id === source, { timeoutS: 240, signal, label: source });
  const bundle = await verifyBundle(acct, item.id, signal);
  shared.libraryItem = item;
  const metrics = { time_to_ready_s: Math.round((Date.now() - started) / 1000), members: bundle.members, bundle_bytes: bundle.bytes, pages: item.page_count };
  const text = `DPO ready in ${seconds} s (${steps.map(s => s.state).join(' → ') || 'immediately'}); ${bundle.members} members, ${(bundle.bytes / 1e6).toFixed(1)} MB verified`;
  return seconds > 120 ? warn(`${text}: slower than 2 min for an already-converted paper`, metrics) : pass(text, metrics);
});

check('library.sync', { title: 'Archive/unarchive and remove/re-add reach v3_library_changes', suites: ALL, timeout: 120, needs: ['import.arxiv'] }, async ({ signal }) => {
  const acct = await account('library', 60), item = shared.libraryItem;
  const { cursor: start } = await acct.entries(signal);
  let revision = item.membership_revision;
  const changed = async (after, predicate, what) => {
    const r = await acct.rpc('v3_library_changes', { p_after: after, p_limit: 100 }, signal);
    const latest = r.changes.flatMap(c => c.entries).filter(e => e.kind === 'item' && e.id === item.id).at(-1);
    if (!latest || !predicate(latest)) throw new Error(`v3_library_changes does not show ${what}`);
    return r.next_cursor;
  };
  const command = async (fn, params, what) => {
    const operation = randomUUID();
    const r = await acct.rpc(fn, { p_operation_id: operation, ...params }, signal);
    if (r.result?.status !== 'applied') throw new Error(`${what}: ${r.result?.status ?? 'no receipt'}`);
    const again = await acct.rpc(fn, { p_operation_id: operation, ...params }, signal);
    if (!again.replayed || JSON.stringify(again.result) !== JSON.stringify(r.result)) throw new Error(`${what}: replay did not return the same receipt`);
    revision = r.result.revision;
  };
  let cursor = start;
  await command('v2_set_item_archived', { p_document_id: item.document_id, p_archived: true, p_expected_revision: revision }, 'archive');
  cursor = await changed(cursor, e => e.archived === true && e.visible, 'the archive');
  await command('v2_set_item_archived', { p_document_id: item.document_id, p_archived: false, p_expected_revision: revision }, 'unarchive');
  cursor = await changed(cursor, e => !('archived' in e) && e.visible, 'the unarchive');
  await command('v2_set_library_item', { p_document_id: item.document_id, p_present: false, p_expected_revision: revision, p_approval_id: null }, 'remove');
  cursor = await changed(cursor, e => e.visible === false, 'the removal');
  await command('v2_set_library_item', { p_document_id: item.document_id, p_present: true, p_expected_revision: revision, p_approval_id: null }, 're-add');
  cursor = await changed(cursor, e => e.visible === true && e.readiness === 'converted_ready', 'the re-add');
  const stale = await acct.rpc('v2_set_item_archived', { p_operation_id: randomUUID(), p_document_id: item.document_id, p_archived: true, p_expected_revision: revision - 1 }, signal);
  if (stale.result?.status !== 'revision_conflict') throw new Error(`a stale revision was ${stale.result?.status}, expected revision_conflict`);
  const page = (await acct.entries(signal)).entries.find(e => e.kind === 'item' && e.id === item.id);
  if (!page?.visible || page.archived) throw new Error('v3_library_page does not show the paper back, unarchived');
  return pass('archive, unarchive, remove, re-add each applied once (replays identical) and appeared in v3_library_changes; stale revision refused');
});

check('credits.store', { title: 'Credits readable; purchase endpoints refuse forged data', suites: ALL, timeout: 90 }, async ({ signal }) => {
  const acct = await account('library', 60);
  const balance = await acct.balance();
  if (!Number.isFinite(balance.available)) throw new Error('v1_credit_balance returned no number');
  const summary = await acct.rpc('v1_store_summary', {}, signal);
  if (!summary || !('plan' in summary)) throw new Error('v1_store_summary returned no plan field');
  // A self-signed ES256 JWS claiming to be a Sandbox pack purchase for this account (as smoke-store.mjs).
  const { generateKeyPairSync } = await import('node:crypto');
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const b64 = v => Buffer.from(JSON.stringify(v)).toString('base64url');
  const head = b64({ alg: 'ES256', x5c: ['AAAA', 'BBBB', 'CCCC'] });
  const body = b64({ transactionId: '2000000999999998', originalTransactionId: '2000000999999998', bundleId: 'com.sciencereader.ios', productId: PRODUCTS[2],
    purchaseDate: Date.now(), signedDate: Date.now(), type: 'Consumable', quantity: 1, appAccountToken: acct.id, environment: 'Sandbox', inAppOwnershipType: 'PURCHASED' });
  const forged = `${head}.${body}.${sign('sha256', Buffer.from(`${head}.${body}`), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
  const synced = await acct.fn('store-sync', { method: 'POST', body: { transactions: [forged, `${head}.${b64({ environment: 'Xcode' })}.x`] }, signal });
  const outcomes = synced.json?.results?.map(r => r.outcome);
  if (synced.status !== 200 || JSON.stringify(outcomes) !== JSON.stringify(['invalid', 'environment_unavailable'])) throw new Error(`store-sync: HTTP ${synced.status} ${JSON.stringify(outcomes ?? synced.json?.code)}`);
  const anonymous = await http(`${env.SUPABASE_URL}/functions/v1/store-sync`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body: '{}' });
  if (anonymous.status !== 401) throw new Error(`store-sync without sign-in: HTTP ${anonymous.status}`);
  const hook = await http(`${env.SUPABASE_URL}/functions/v1/app-store-notifications`, { method: 'POST', body: { signedPayload: `${head}.${b64({ notificationType: 'REFUND' })}.x` } });
  if (hook.status !== 400) throw new Error(`app-store-notifications accepted an unsigned payload: HTTP ${hook.status}`);
  if ((await acct.balance()).available !== balance.available) throw new Error('a forged purchase changed the balance');
  return pass(`balance ${balance.available} available / ${balance.held} held; store-sync reachable and refuses forged/Xcode data; real purchases need a sandbox Apple Account on a device (not automated)`);
});

check('admin.accounts-gate', { title: 'Admin accounts refuses callers who are not an owner with MFA', suites: ALL, timeout: 60 }, async ({ signal }) => {
  const acct = await account('library', 60);
  const before = await acct.balance();
  const body = { action: 'grant_credits', request_id: randomUUID(), account_id: acct.id, credits: 1, reason: 'Workflow check: must be refused' };
  const anonymous = await http(`${env.SUPABASE_URL}/functions/v1/admin-accounts`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body, signal });
  if (anonymous.status !== 401) return fail(`without sign-in: HTTP ${anonymous.status}`);
  const customer = await acct.fn('admin-accounts', { method: 'POST', body, signal });
  if (customer.status !== 403 || customer.json?.code !== 'owner_mfa_required') return fail(`a customer: HTTP ${customer.status} ${customer.json?.code ?? ''}`);
  if ((await acct.balance()).available !== before.available) return fail('a refused grant changed the balance');
  return pass('anonymous 401, customer 403 owner_mfa_required, balance unchanged');
});

check('chat.smoke', { title: 'General chat streams an answer and settles', suites: SCHEDULED, timeout: 120, costUSD: 0.005 }, async ({ signal }) => {
  const acct = await account('chat', 200);
  const r = await chat(acct, { mode: 'general', messages: [{ role: 'user', text: 'Reply with the single word OK.' }] }, { signal });
  if (r.error || !r.done) return fail(`${chatSummary(r)} after ${(r.ms / 1000).toFixed(1)} s`);
  if (!r.answer.trim()) return fail('done without any text');
  return pass(`${chatSummary(r)} in ${(r.ms / 1000).toFixed(1)} s`, { credits: r.done.credits, total_s: r.ms / 1000 });
});

check('chat.paper', { title: 'Paper chat answer streams and ends with done', suites: SCHEDULED, timeout: 300, costUSD: 0.06 }, async ({ signal }) => {
  const acct = await account('chat', 200);
  const item = await chatDocument(acct, signal);
  const r = await chat(acct, { mode: 'paper', document_id: item.document_id,
    messages: [{ role: 'user', text: 'In two sentences: which attention mechanisms does this model use, and what does each one buy?' }] }, { signal });
  const metrics = { credits: r.done?.credits ?? 0, first_token_s: r.firstTokenMs && r.firstTokenMs / 1000, total_s: r.ms / 1000 };
  if (r.error || !r.done) return fail(`${chatSummary(r)} after ${(r.ms / 1000).toFixed(1)} s`, metrics);
  if (r.answer.trim().length < 40) return fail(`answer only ${r.answer.trim().length} characters`, metrics);
  return pass(`${chatSummary(r)}; first text ${(r.firstTokenMs / 1000).toFixed(1)} s, total ${(r.ms / 1000).toFixed(1)} s`, metrics);
});

check('chat.related', { title: 'Related (web search) answer lists linked sources', suites: SCHEDULED, timeout: 300, costUSD: 0.1, needs: ['chat.paper'] }, async ({ signal }) => {
  const acct = await account('chat', 200);
  const quote = 'grouped-query attention (GQA) for faster inference, coupled with sliding window attention (SWA) to effectively handle sequences of arbitrary length';
  const r = await chat(acct, { mode: 'paper', document_id: (await chatDocument(acct, signal)).document_id, selection: { quote }, action: 'related',
    messages: [{ role: 'user', text: `Find related papers, earlier and recent, with links: ${quote}` }] }, { signal, timeoutMs: 280_000 });
  const links = [...new Set(r.answer.match(/https:\/\/[^\s)\]>"]+/g) ?? [])];
  const metrics = { credits: r.done?.credits ?? 0, links: links.length, total_s: r.ms / 1000 };
  if (r.error || !r.done) return fail(`${chatSummary(r)} after ${(r.ms / 1000).toFixed(1)} s`, metrics);
  if (links.length < 2) return fail(`only ${links.length} link(s) in the answer: web search returned no sources`, metrics);
  return pass(`${links.length} links${/\n\nSources:\n/.test(r.answer) ? ' and a Sources list' : ''}; ${chatSummary(r)} in ${(r.ms / 1000).toFixed(0)} s`, metrics);
});

// The Add paper (Ingest) corpus. `after`: what a queued import must do in this suite —
// 'ready' (free shared conversions, or cheap private ones), or 'cancel' at once (private OCR
// that only the weekly suite pays for). The weekly suite takes every queued import to ready.
const INGEST = [
  { id: 'ingest.arxiv-id', title: 'PaLM by arXiv id, from DPO’s bibliography (paper chat)', mode: 'paper', expect: 'queued', source: /arXiv:2204\.02311/, after: 'ready',
    quote: '[11] A. Chowdhery, S. Narang, J. Devlin, M. Bosma, G. Mishra, A. Roberts, P. Barham, H. W. Chung, C. Sutton, S. Gehrmann, et al. Palm: Scaling language modeling with pathways. arXiv preprint arXiv:2204.02311, 2022.' },
  { id: 'ingest.title-only', title: 'Adam by title only (private arXiv conversion)', mode: 'general', expect: 'queued', source: /arXiv:1412\.6980/, after: 'cancel', pages: 15,
    quote: 'D. P. Kingma and J. Ba. Adam: A method for stochastic optimization. In International Conference on Learning Representations, 2015.' },
  { id: 'ingest.landing-page', title: 'Zenodo landing page listed as the PDF (paper chat)', mode: 'paper', expect: 'queued', source: /open-access PDF from zenodo\.org/, after: 'ready', pages: 4,
    quote: 'S. Gepshtein, A. Shtainman, B. Fishbain, and L. Yaroslavsky. Restoration of atmospheric turbulent video containing real motion using rank filtering and elastic image registration. In Proc. 12th European Signal Processing Conference (EUSIPCO), 2004.' },
  { id: 'ingest.jmlr', title: 'Dropout from JMLR (labelled closed by OpenAlex)', mode: 'general', expect: 'queued', source: /open-access PDF from jmlr/, after: 'cancel', pages: 30,
    quote: 'N. Srivastava, G. Hinton, A. Krizhevsky, I. Sutskever, and R. Salakhutdinov. Dropout: A simple way to prevent neural networks from overfitting. Journal of Machine Learning Research, 15(56):1929–1958, 2014.' },
  { id: 'ingest.closed', title: 'A closed paper says "isn\'t openly available" (paper chat)', mode: 'paper', expect: 'closed',
    quote: 'D. Silver, A. Huang, C. J. Maddison, A. Guez, L. Sifre, G. van den Driessche, et al. Mastering the game of Go with deep neural networks and tree search. Nature, 529(7587):484–489, 2016.' },
  { id: 'ingest.not-found', title: 'A nonexistent paper says "couldn\'t find"', mode: 'general', expect: 'not_found',
    quote: 'A. Quillfeather and B. Marrowind. Recursive lattice annealing for contrastive hyperbolic transformers. In Advances in Neural Information Processing Systems 32, 2019.' },
  { id: 'ingest.extra-fields', title: 'A reference full of venue/pages/DOI fields (paper chat)', mode: 'paper', expect: 'queued', source: /arXiv:2201\.11903/, after: 'ready',
    quote: 'Jason Wei, Xuezhi Wang, Dale Schuurmans, Maarten Bosma, Brian Ichter, Fei Xia, Ed H. Chi, Quoc V. Le, and Denny Zhou. Chain-of-thought prompting elicits reasoning in large language models. In S. Koyejo, S. Mohamed, A. Agarwal, D. Belgrave, K. Cho, and A. Oh (eds.), Advances in Neural Information Processing Systems 35 (NeurIPS 2022), New Orleans, LA, USA, pages 24824–24837. Curran Associates, Inc., 2022. doi:10.48550/arXiv.2201.11903. ISBN 9781713871088.' },
];
const pendingImports = [];
for (const c of INGEST) {
  const estimate = (c.mode === 'paper' ? 0.02 : 0.01) + (c.after === 'ready' || suite === 'weekly' ? (c.pages ?? 0) * USD_PER_CREDIT : 0);
  check(c.id, { title: `Add paper: ${c.title}`, suites: c.suites ?? SCHEDULED, timeout: 180, costUSD: estimate, needs: c.mode === 'paper' ? ['chat.paper'] : [] }, async ({ signal }) => {
    const acct = await account('chat', 200);
    const before = new Set((await acct.entries(signal)).entries.filter(e => e.kind === 'import').map(e => e.id));
    const document = c.mode === 'paper' ? (await chatDocument(acct, signal)).document_id : null;
    const r = await chat(acct, { mode: c.mode, ...(document ? { document_id: document } : {}), selection: { quote: c.quote },
      action: 'ingest', capabilities: ['web_import'], messages: [{ role: 'user', text: `Find and add the paper referenced in this passage: ${c.quote}` }] }, { signal });
    const metrics = { credits: r.done?.credits ?? 0, total_s: r.ms / 1000 };
    if (r.error || !r.done) return fail(`${chatSummary(r)} after ${(r.ms / 1000).toFixed(1)} s`, metrics);
    // The server's own record of the find step (counts and timings only).
    if (management) {
      const [usage] = await management.sql(`select units from app_private.provider_usage_events where provider='ingest' and operation_id='${r.operation}'`).catch(() => []);
      if (usage?.units) Object.assign(metrics, { find_s: usage.units.find_ms != null ? usage.units.find_ms / 1000 : null, ingest_result: usage.units.result, budget_expired: usage.units.budget_expired ?? null });
    }
    const outcome = ingestOutcome(r.answer);
    const tail = r.answer.trim().split('\n').at(-1).slice(0, 160);
    if (!outcome) return fail(`ended without an outcome line (silent) — last line: "${tail}"${metrics.ingest_result ? `; server result ${metrics.ingest_result}` : ''}`, metrics);
    if (metrics.budget_expired) return fail(`the find step ran out of its 45 s budget (${metrics.find_s} s) — "${outcome.line}"`, metrics);
    const want = c.expect === 'queued' ? ['queued', 'present'] : [c.expect];
    if (!want.includes(outcome.kind)) return fail(`expected ${want.join('/')}, got ${outcome.kind}: "${outcome.line.slice(0, 200)}"`, metrics);
    if (c.source && !c.source.test(outcome.line)) return fail(`matched the wrong paper: "${outcome.line.slice(0, 200)}"`, metrics);
    let note = '';
    if (c.expect === 'queued') {
      const { entries } = await acct.entries(signal);
      const added = entries.find(e => e.kind === 'import' && !before.has(e.id) && e.phase !== 'cancelled');
      if (outcome.kind === 'queued' && !added) return fail(`said "Queued" but no new import is in the library: "${outcome.line}"`, metrics);
      if (added && c.after === 'cancel' && suite !== 'weekly') {
        const cancelled = await acct.rpc('v2_cancel_import', { p_operation_id: randomUUID(), p_import_id: added.id, p_expected_revision: added.intent_revision }, signal);
        note = cancelled.result?.status === 'applied' ? '; import cancelled (OCR is weekly only)' : `; cancel returned ${cancelled.result?.status}`;
      } else if (added) { pendingImports.push({ check: c.id, acct, id: added.id, source: added.source_id, queuedAt: Date.now() }); note = `; ${added.source_id} queued`; }
    }
    const find = metrics.find_s != null ? `, find ${metrics.find_s.toFixed(1)} s` : '';
    const text = `"${outcome.line.slice(0, 140)}"${note} (${r.done.credits} credits${find})`;
    // Near the 45 s budget the same paper fails as "couldn't search" on a slower day.
    return metrics.find_s > 30 ? warn(`find step took ${metrics.find_s.toFixed(1)} s of its 45 s budget — ${text}`, metrics) : pass(text, metrics);
  });
}

check('ingest.imports-ready', { title: 'Papers queued by Add paper reach ready', suites: SCHEDULED, timeout: 1500 }, async ({ signal }) => {
  if (!pendingImports.length) return skip('no import was queued by the Add paper checks');
  const results = await Promise.all(pendingImports.map(async p => {
    try {
      const { item, seconds } = await waitForReady(p.acct, e => e.id === p.id || (e.kind === 'item' && e.source_id === p.source), { timeoutS: 1200, signal, label: p.source });
      const bundle = await verifyBundle(p.acct, item.id, signal);
      return { ok: true, text: `${p.source} ready ≤ ${Math.round((Date.now() - p.queuedAt) / 1000)} s after queueing (${item.page_count} p, ${bundle.members} members)` };
    } catch (error) { return { ok: false, text: `${p.check}: ${error.message}` }; }
  }));
  const failed = results.filter(r => !r.ok);
  return failed.length ? fail(failed.map(r => r.text).join('; ')) : pass(results.map(r => r.text).join('; '));
});

// Weekly: the two imports that looped silently on Edge (2026-10-06). 2610.03771 is a private
// (non-CC) conversion, so each fresh account pays its OCR; 2610.02287 is a shared CC BY
// conversion, so it checks delivery of a 49-page bundle without re-rendering it.
for (const [id, source, title, timeoutS, pages] of [
  ['import.large-pdf', '2610.03771', '44.6 MB PDF imports to ready', 1500, 26],
  ['import.long-paper', '2610.02287', '49-page paper imports to ready', 900, 0]]) {
  check(id, { title, suites: ['weekly'], timeout: timeoutS + 120, costUSD: pages * USD_PER_CREDIT, parallel: true }, async ({ signal }) => {
    const acct = await account('heavy', 150), started = Date.now();
    await beginImport(acct, source, signal);
    const { item, seconds, steps } = await waitForReady(acct, e => e.source_id === source, { timeoutS, signal, label: source });
    const bundle = await verifyBundle(acct, item.id, signal);
    const metrics = { time_to_ready_s: Math.round((Date.now() - started) / 1000), pages: item.page_count, bundle_bytes: bundle.bytes };
    return pass(`ready in ${seconds} s (${steps.map(s => s.state).join(' → ')}); ${item.scope}, ${item.page_count} pages, ${bundle.members} members verified`, metrics);
  });
}

// ── Runner ───────────────────────────────────────────────────────────────────
if (args.list) {
  for (const c of CHECKS) console.log(`${c.id.padEnd(24)} ${c.suites.join(',').padEnd(20)} ${c.costUSD ? `~${usd(c.costUSD)}` : 'free'.padEnd(6)}  ${c.title}`);
  process.exit(0);
}
const only = list(args.only), also = list(args.also), skipped = list(args.skip);
const selected = CHECKS.filter(c => (only.length ? only.includes(c.id) : c.suites.includes(suite) || also.includes(c.id)) && !skipped.includes(c.id));
const unknown = [...only, ...also, ...skipped].filter(id => !CHECKS.some(c => c.id === id));
if (unknown.length) { console.error('Unknown checks:', unknown.join(', ')); process.exit(2); }

const runID = randomUUID(), startedAt = new Date();
let commit = null; try { commit = execFileSync('git', ['rev-parse', '--short=12', 'HEAD'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { /* no git */ }
log(`Workflow checks: suite ${suite}, ${selected.length} checks, cap ${usd(capUSD)}, project ${PROJECT_REF}${management ? '' : ' (no management token)'}`);
const results = new Map();
let spentCredits = 0;

async function runCheck(c) {
  const started = Date.now();
  let result;
  const blocked = (c.needs ?? []).find(id => selected.some(s => s.id === id) ? results.get(id)?.status !== 'pass' && results.get(id)?.status !== 'warn' : false);
  const projected = spentCredits * USD_PER_CREDIT + (c.costUSD ?? 0);
  if (blocked) result = skip(`needs ${blocked} (${results.get(blocked)?.status ?? 'not run'})`);
  else if (c.costUSD && projected > capUSD) result = skip(`run cost cap ${usd(capUSD)} reached (${usd(spentCredits * USD_PER_CREDIT)} spent)`);
  else if (c.costUSD && shared.headroomUSD != null && shared.headroomUSD - projected < BUDGET_RESERVE_USD)
    result = skip(`platform budget headroom ${usd(shared.headroomUSD)} would fall below the ${usd(BUDGET_RESERVE_USD)} reserve`);
  else {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new Error(`timed out after ${c.timeout} s`)), c.timeout * 1000);
    try {
      result = await Promise.race([c.run({ signal: controller.signal }),
        new Promise((_, reject) => controller.signal.addEventListener('abort', () => reject(controller.signal.reason), { once: true }))]);
    } catch (error) { result = fail(error?.message ?? String(error)); } finally { clearTimeout(timer); controller.abort(); }
    // Credits spent since the last reading (holds in flight count as spent; a released hold
    // shows up later as a refund). Incremental, so parallel checks never count twice.
    let credits = 0;
    for (const a of accounts.filter(x => x.touched)) {
      try { const b = await a.balance(); credits += a.available - b.available; a.available = b.available; } catch { /* account gone */ }
    }
    spentCredits += credits;
    if (credits > 0) result.credits = credits;
  }
  const acknowledged = ack[c.id];
  if (result.status === 'fail' && acknowledged && new Date(acknowledged.until) > new Date()) {
    result = { ...result, status: 'warn', reason: `${result.reason} [acknowledged until ${acknowledged.until}: ${acknowledged.reason}]` };
  }
  result = { id: c.id, title: c.title, ...result, reason: redact(result.reason ?? '').replace(/\s+/g, ' ').trim(), duration_ms: Date.now() - started };
  results.set(c.id, result);
  log(`${result.status.toUpperCase().padEnd(4)} ${c.id} — ${result.reason}`);
}

for (let i = 0; i < selected.length;) {
  if (selected[i].parallel) {
    const group = []; while (i < selected.length && selected[i].parallel) group.push(selected[i++]);
    await Promise.all(group.map(runCheck));
  } else await runCheck(selected[i++]);
}

// ── Cleanup: delete each synthetic account through account-delete, as a user would ──
const kept = [];
if (!args['keep-accounts']) {
  for (const a of accounts) {
    try {
      const { entries } = await a.entries();
      for (const e of entries.filter(e => e.kind === 'import' && ['accepted', 'resolving', 'acquiring'].includes(e.phase)))
        await a.rpc('v2_cancel_import', { p_operation_id: randomUUID(), p_import_id: e.id, p_expected_revision: e.intent_revision }).catch(() => {});
      let deleted = null;
      for (let attempt = 0; attempt < 12; attempt++) {
        deleted = await a.fn('account-delete', { method: 'POST', body: { confirm: DELETE_CONFIRMATION } });
        if (deleted.status !== 409) break;
        await sleep(15_000); // account_busy: paid work in flight settles first.
      }
      if (deleted.status !== 200) kept.push(`${a.label} ${a.id} (account-delete HTTP ${deleted.status} ${deleted.json?.code ?? ''})`);
    } catch (error) { kept.push(`${a.label} ${a.id} (${error.message})`); }
  }
  // Leftovers from interrupted runs (older than 6 h): closed here, finished by the worker's deletion sweep.
  try {
    const users = await http(`${env.SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=500`, { headers: serviceHeaders });
    const stale = (users.json?.users ?? []).filter(u => /^gradstep-check-[\w-]+@example\.invalid$/.test(u.email ?? '')
      && Date.now() - Date.parse(u.created_at) > 6 * 3600_000 && !accounts.some(a => a.id === u.id));
    for (const u of stale) await rpc('worker_delete_account_begin', { p_account_id: u.id }, { service: true }).catch(() => {});
    if (stale.length) log(`Closed ${stale.length} leftover synthetic account(s); the worker's sweep finishes them`);
  } catch { /* best effort */ }
}
const cleanup = { id: 'cleanup.accounts', title: 'Synthetic accounts deleted through account-delete',
  status: args['keep-accounts'] ? 'skip' : kept.length ? 'warn' : 'pass',
  reason: args['keep-accounts'] ? 'kept on request' : kept.length ? `kept: ${kept.join('; ')}` : `${accounts.length} deleted (personal data removed, billing rows kept)`, duration_ms: 0 };
results.set(cleanup.id, cleanup);

// Measured provider spend for this run's accounts (settled + still reserved), when the database is readable.
let measured = null;
if (management && accounts.length) {
  try {
    const [row] = await management.sql(`select coalesce(sum(actual_microusd) filter (where state='settled'),0)::bigint spent,
      coalesce(sum(spend_ceiling_microusd) filter (where state<>'settled'),0)::bigint reserved
      from app_private.metered_operations where account_id in (${accounts.map(a => `'${a.id}'`).join(',')})`);
    measured = { spent_usd: Number(row.spent) / 1e6, reserved_usd: Number(row.reserved) / 1e6 };
  } catch { /* estimate only */ }
}

// ── Report ───────────────────────────────────────────────────────────────────
const all = [...results.values()];
const counts = Object.fromEntries(['pass', 'fail', 'warn', 'skip'].map(s => [s, all.filter(r => r.status === s).length]));
const report = { run_id: runID, suite, trigger: args.trigger ?? 'manual', environment: 'staging', project_ref: PROJECT_REF, git_commit: commit,
  started_at: startedAt.toISOString(), finished_at: new Date().toISOString(), cap_usd: capUSD,
  cost: { credits: spentCredits, estimated_usd: +(spentCredits * USD_PER_CREDIT).toFixed(4), measured }, counts, results: all };
const out = process.env.WORKFLOW_REPORT_DIR ? resolve(process.env.WORKFLOW_REPORT_DIR) : join(ROOT, '.artifacts/workflow-checks');
mkdirSync(out, { recursive: true });
const file = join(out, `${startedAt.toISOString().replace(/[:.]/g, '-')}.json`);
writeFileSync(file, redact(JSON.stringify(report, null, 1)), { mode: 0o600 });

const width = Math.max(...all.map(r => r.id.length));
console.log(`\n${'Check'.padEnd(width)}  Result  Time    Cost     Reason`);
for (const r of all) {
  console.log(redact(`${r.id.padEnd(width)}  ${r.status.toUpperCase().padEnd(6)}  ${`${(r.duration_ms / 1000).toFixed(0)}s`.padEnd(6)}  ${(r.credits ? usd(r.credits * USD_PER_CREDIT) : '-').padEnd(7)}  ${r.reason.slice(0, 220)}`));
}
console.log(`\n${counts.pass} passed, ${counts.fail} failed, ${counts.warn} warnings, ${counts.skip} skipped; provider cost ≤ ${usd(report.cost.estimated_usd)} (credits × $0.005)` +
  (measured ? `, measured ${usd(measured.spent_usd)} settled + ${usd(measured.reserved_usd)} reserved` : '') + `\nReport: ${file.replace(ROOT + '/', '')}`);

// Optional: record the run for the admin Reliability tab (migration 024) and alert the owner.
if (args.record) {
  try {
    await rpc('worker_record_workflow_check_run', { p_run: { id: runID, suite: only.length ? 'custom' : suite, trigger: report.trigger, git_commit: commit, started_at: report.started_at,
      finished_at: report.finished_at, cost_microusd: Math.round((measured?.spent_usd ?? report.cost.estimated_usd) * 1e6),
      results: all.map(r => ({ check_id: r.id, status: r.status, reason: r.reason.slice(0, 500), duration_ms: r.duration_ms,
        cost_microusd: Math.round((r.credits ?? 0) * USD_PER_CREDIT * 1e6), metrics: Object.fromEntries(Object.entries(r.metrics ?? {}).filter(([, v]) => typeof v === 'number' && Number.isFinite(v))) })) } }, { service: true });
    console.log('Recorded for the admin Reliability tab');
  } catch (error) { console.log(redact(`Not recorded (${error.message}); is migration 024 applied?`)); }
}
if (args.notify && (counts.fail || kept.length) && env.RESEND_API_KEY && env.WORKFLOW_ALERT_EMAIL) {
  const lines = all.filter(r => r.status === 'fail' || r.id === 'cleanup.accounts' && r.status !== 'pass').map(r => `${r.id}: ${r.reason}`);
  const sent = await http('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: `Bearer ${env.RESEND_API_KEY}` },
    body: { from: env.WORKFLOW_ALERT_FROM ?? 'Gradstep checks <checks@gradstep.ai>', to: [env.WORKFLOW_ALERT_EMAIL],
      subject: `Gradstep ${suite} checks: ${counts.fail} failed`, text: redact(`${lines.join('\n')}\n\nRun ${runID} (${report.trigger}, commit ${commit ?? 'unknown'}).`) } }).catch(e => ({ status: e.message }));
  console.log(`Alert email: ${sent.status === 200 ? 'sent' : `not sent (${sent.status})`}`);
}
process.exit(counts.fail ? 1 : 0);

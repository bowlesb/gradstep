#!/usr/bin/env node
// Gradstep fault drill (docs/architecture/RESILIENCE.md §Fault drills): make one provider look throttled or failing for
// one disposable test account on staging, use the affected feature as a reader would, and check what the reader is
// shown, that they are not charged, that the rest of the app still answers, that the failure reached the provider-health
// telemetry, and that the feature recovers once the fault is cleared.
//
//   node scripts/fault-drill.mjs [--provider=anthropic] [--route=chat] [--mode=throttle|midstream|stop|overrun|…] [--minutes=5]
//        [--allow-liability] [--no-recovery] [--keep-account]
//
// Staging only, and only where the functions were deployed with FAULT_INJECTION=on (infra/staging.json fault_injection).
// The fault is a row in app_private.fault_injection for an @example.invalid account made here; the database refuses any
// other account, and the functions ignore the table unless FAULT_INJECTION=on. Synthetic answers never reach the
// provider and are counted under the route `drill`, never moving the shared breaker.
//
// Modes: throttle (429) is the default and the only mode that costs nothing anywhere. overload (529), error (500),
// timeout and malformed look, to the billing ledger, like a provider that may have started work, so each leaves an
// unknown liability on the operation until reconciled; they need --allow-liability.
//
// Early endings (owner decision 2026-10-16, docs/architecture/CHAT.md "When an answer stops early"):
//   midstream  the provider fails as overloaded after the answer's first text: the reader keeps that text, is charged
//              nothing, and the cost is recorded as absorbed (ending `provider`).
//   stop       a slow synthetic answer, three times: a Stop the app records (v1_chat_stop, capability stop_signal) is
//              charged for what was written (`stopped`); the same app dropping the connection is not (`connection`); a
//              build without the capability closing the stream is charged as a Stop, as before (`left`).
//   overrun    no fault: a test account's operation reports more than its ceiling (3 micro-USD over a 1 micro-USD
//              ceiling, through the service RPCs): an anomaly row appears, work_enabled stays true, chat still answers.
// The synthetic answers of midstream and stop, and the overrun's attempt, carry a `drill-` request id and are reconciled
// to zero at the end (worker_fault_drill_reconcile, test accounts only): they never reached a provider.
//
// Secrets come from the environment or .env.staging (a git worktree reads the main checkout's) and are never printed.
// No dependencies beyond Node 24.
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'coxhjvqpflgxkleydati';
const CONSENT = 'cloud-ai-v2';
const DELETE_CONFIRMATION = 'delete my account';
const MODES = ['throttle', 'overload', 'error', 'timeout', 'malformed', 'midstream', 'stop', 'overrun'];
// The fault row each mode sets (migration 079 adds the streamed `midstream` and `slow`); the overrun drill sets none.
const FAULT_MODE = { stop: 'slow', overrun: null };
// The answers these drills ask for: the cheapest profile (Claude Haiku 5.5, low effort, brief).
const HAIKU = { model: 'haiku', effort: 'low', length: 'brief' };
// Modes that leave an unknown (possibly billed) liability on a metered provider's operation.
const LIABLE = { anthropic: ['overload', 'error', 'timeout', 'malformed'] };
// What each mode is recorded as (provider-health outcome) and how many calls the feature makes under it (the chat
// retries a 429/529 once before the first token, RESILIENCE.md step 2).
const OUTCOME = { throttle: ['throttled', 2], overload: ['overloaded', 2], error: ['server_error', 1], timeout: ['timeout', 1], malformed: ['ok', 1],
  midstream: ['transport', 1], stop: ['ok', 3], overrun: [null, 0] };
// The drills wired so far: the provider calls that carry the reader's account (accountProviderFetch).
const DRILLS = { 'anthropic:chat': chatDrill };

const args = Object.fromEntries(process.argv.slice(2).map(a => { const [k, ...v] = a.replace(/^--/, '').split('='); return [k, v.length ? v.join('=') : 'true']; }));
const provider = args.provider ?? 'anthropic', route = args.route ?? 'chat', mode = args.mode ?? 'throttle', minutes = Number(args.minutes ?? 5);
const usage = message => { console.error(message); process.exit(2); };
if (!MODES.includes(mode)) usage(`--mode must be one of ${MODES.join(', ')}`);
if (!Number.isInteger(minutes) || minutes < 1 || minutes > 60) usage('--minutes must be a whole number from 1 to 60');
if (!DRILLS[`${provider}:${route}`]) usage(`No drill for ${provider} on ${route}. Wired: ${Object.keys(DRILLS).join(', ')} (RESILIENCE.md lists what is next).`);
if (LIABLE[provider]?.includes(mode) && !args['allow-liability'])
  usage(`--mode=${mode} on ${provider} leaves an unknown liability on the drill's operation (the ledger can't tell a synthetic ${mode} from a real one); add --allow-liability to run it anyway.`);

function secretsRoot() {
  if (process.env.WORKFLOW_SECRETS_DIR) return resolve(process.env.WORKFLOW_SECRETS_DIR);
  if (existsSync(join(ROOT, '.env.staging'))) return ROOT;
  try { // A git worktree: the secrets stay in the main checkout.
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (existsSync(join(dirname(common), '.env.staging'))) return dirname(common);
  } catch { /* not a git checkout */ }
  return null;
}
const dotenv = path => !path || !existsSync(path) ? {} : Object.fromEntries(readFileSync(path, 'utf8').split('\n')
  .filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const secretsDir = secretsRoot();
const KEYS = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_PROJECT_REF', 'SUPABASE_ACCESS_TOKEN'];
const env = { ...dotenv(secretsDir && join(secretsDir, '.env.staging')), ...Object.fromEntries(KEYS.filter(k => process.env[k]).map(k => [k, process.env[k]])) };
if (env.SUPABASE_PROJECT_REF !== PROJECT_REF || !env.SUPABASE_URL?.startsWith(`https://${PROJECT_REF}.`)) usage('Staging only: SUPABASE_PROJECT_REF/SUPABASE_URL must name the staging project.');
if (!env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) usage('Needs SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY (.env.staging).');
let managementToken = env.SUPABASE_ACCESS_TOKEN ?? null;
if (!managementToken && process.platform === 'darwin') {
  try { managementToken = execFileSync('security', ['find-generic-password', '-s', 'Supabase CLI', '-w'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || null; } catch { /* none */ }
}

const SECRETS = new Set([managementToken, env.SUPABASE_ANON_KEY, env.SUPABASE_SERVICE_ROLE_KEY].filter(v => typeof v === 'string' && v.length >= 8));
const redact = text => {
  let out = String(text);
  for (const secret of SECRETS) out = out.split(secret).join('[redacted]');
  return out.replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[jwt]');
};
const log = (...parts) => console.log(redact(`${new Date().toISOString().slice(11, 19)} ${parts.join(' ')}`));
const sha256 = value => createHash('sha256').update(value).digest('hex');
const sleep = ms => new Promise(done => setTimeout(done, ms));

async function http(url, { method = 'GET', headers = {}, body, timeoutMs = 30_000 } = {}) {
  const json = body !== undefined && typeof body !== 'string';
  const response = await fetch(url, { method, redirect: 'manual', headers: { ...(json ? { 'content-type': 'application/json' } : {}), ...headers },
    body: body === undefined ? undefined : json ? JSON.stringify(body) : body, signal: AbortSignal.timeout(timeoutMs) });
  const text = await response.text();
  let parsed = null; try { parsed = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: response.status, json: parsed, headers: response.headers };
}
const anonHeaders = token => ({ apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token ?? env.SUPABASE_ANON_KEY}` });
const serviceHeaders = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
async function rpc(name, params, { token, service = false } = {}) {
  const r = await http(`${env.SUPABASE_URL}/rest/v1/rpc/${name}`, { method: 'POST', body: params ?? {}, headers: service ? serviceHeaders : anonHeaders(token) });
  if (r.status >= 300) throw new Error(`${name}: HTTP ${r.status} ${r.json?.message ?? r.json?.code ?? ''}`.trim());
  return r.json;
}

// ── The disposable account (the workflow checks' prefix, so their sweep closes one an interrupted drill leaves) ──
class Account {
  static async create(credits) {
    const email = `gradstep-check-drill-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
    SECRETS.add(password);
    const created = await http(`${env.SUPABASE_URL}/auth/v1/admin/users`, { method: 'POST', headers: serviceHeaders, body: { email, password, email_confirm: true } });
    if (created.status >= 300 || !created.json?.id) throw new Error(`creating the drill account: HTTP ${created.status}`);
    const account = Object.assign(new Account(), { id: created.json.id, email, password });
    await rpc('worker_grant_credits', { p_account_id: account.id, p_source: 'adjustment', p_external_key: `operator:fault-drill:${account.id}`,
      p_credits: credits, p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Fault drill synthetic grant' }, { service: true });
    return account;
  }
  async token() {
    if (this.access) return this.access;
    const r = await http(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body: { email: this.email, password: this.password } });
    if (r.status !== 200 || !r.json?.access_token) throw new Error(`password sign-in for the drill account: HTTP ${r.status}`);
    SECRETS.add(r.json.access_token);
    return (this.access = r.json.access_token);
  }
  async rpc(name, params) { return rpc(name, params, { token: await this.token() }); }
  // v1_credit_balance names the held credits `reserved`.
  async balance() { const b = await this.rpc('v1_credit_balance', {}); return { available: Number(b.available), held: Number(b.reserved ?? b.held ?? 0) }; }
  async fn(path, init = {}) { return http(`${env.SUPABASE_URL}/functions/v1/${path}`, { ...init, headers: { ...anonHeaders(await this.token()), ...(init.headers ?? {}) } }); }
}

/** One answer from functions/v1/chat, streamed and parsed like the app's SSE parser. `leaveAfter` closes the stream
 * after that many pieces of text (a Stop or a dropped connection), first awaiting `beforeLeaving` (the app's Stop record). */
async function chat(acct, body, { timeoutMs = 180_000, operationID = randomUUID(), leaveAfter = 0, beforeLeaving = null } = {}) {
  const started = Date.now(), leave = new AbortController();
  const response = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', redirect: 'error',
    headers: { ...anonHeaders(await acct.token()), 'content-type': 'application/json', accept: 'text/event-stream' },
    body: JSON.stringify({ operation_id: operationID, consent_version: CONSENT, ...body }), signal: AbortSignal.any([AbortSignal.timeout(timeoutMs), leave.signal]) });
  const result = { operationID, status: response.status, answer: '', deltas: 0, done: null, error: null, left: false, ms: 0, retryAfterHeader: response.headers.get('retry-after') };
  if (response.status !== 200) { result.error = (await response.json().catch(() => null)) ?? { code: `http_${response.status}` }; result.ms = Date.now() - started; return result; }
  const decoder = new TextDecoder(); let buffer = '';
  try {
    for await (const chunk of response.body) {
      buffer += decoder.decode(chunk, { stream: true });
      let cut;
      while ((cut = buffer.indexOf('\n\n')) >= 0) {
        const block = buffer.slice(0, cut); buffer = buffer.slice(cut + 2);
        const event = /^event: (\w+)/m.exec(block)?.[1], data = /^data: (.*)$/m.exec(block)?.[1];
        if (!event || !data) continue;
        const value = JSON.parse(data);
        if (event === 'delta') { result.answer += value.text; result.deltas++; }
        else if (event === 'done') result.done = value; else if (event === 'error') result.error = value;
      }
      if (leaveAfter && result.deltas >= leaveAfter && !result.done && !result.error) {
        if (beforeLeaving) await beforeLeaving();
        result.left = true; leave.abort(); break;
      }
    }
  } catch (error) { if (!leave.signal.aborted) throw error; }
  result.ms = Date.now() - started;
  return result;
}

/** The operation's settlement and ending as the database recorded them (service role; amounts and codes only). Waits for
 * the function to settle it: after the reader leaves, settlement finishes in the background. */
async function outcomeOf(acct, operationID, { settled = true, tries = 20 } = {}) {
  let outcome = null;
  for (let i = 0; i < tries; i++) {
    outcome = await rpc('worker_operation_outcome', { p_account_id: acct.id, p_operation_id: operationID }, { service: true });
    if (!settled || (outcome?.state === 'settled' && (outcome.kind !== 'chat' || outcome.ending))) return outcome;
    await sleep(1500);
  }
  return outcome;
}

/** This hour's drill counts for one provider and outcome (route `drill` is synthetic traffic only). */
async function drillCalls(outcome) {
  const rows = await rpc('worker_provider_health_recent', { p_minutes: 120 }, { service: true });
  return rows.filter(r => r.provider === provider && r.route === 'drill' && r.outcome === outcome).reduce((n, r) => n + Number(r.calls), 0);
}

// ── The chat drill ───────────────────────────────────────────────────────────
async function chatDrill(acct, step) {
  if (mode === 'midstream') return midstreamDrill(acct, step);
  if (mode === 'stop') return stopDrill(acct, step);
  if (mode === 'overrun') return overrunDrill(acct, step);
  const [outcome, expectedCalls] = OUTCOME[mode];
  const recordedBefore = await drillCalls(outcome);
  const before = await acct.balance();
  const message = { mode: 'general', messages: [{ role: 'user', text: 'Reply with the single word OK.' }] };

  const r = await chat(acct, message);
  const code = r.error?.code ?? null;
  step('the reader sees a specific error, not a broken app', !!code && !r.done && !r.answer.trim(),
    code ? `${code}${r.error.retry_after != null ? `, retry after ${r.error.retry_after} s` : ''} in ${(r.ms / 1000).toFixed(1)} s` : r.done ? `answered (${r.done.credits} credits): the fault was not honoured — is FAULT_INJECTION on?` : 'no error event');
  if (mode === 'throttle' || mode === 'overload') {
    step('the code says the provider is busy', code === 'provider_unavailable', `code ${code}`);
    step('it says when to try again', Number(r.error?.retry_after) >= 1, `retry_after ${r.error?.retry_after ?? 'missing'}`);
  }
  step('the error charges nothing', r.error?.credits == null || Number(r.error.credits) === 0, `credits ${r.error?.credits ?? 'absent'}`);
  // Migration 079 servers say so in the event: charged false, and why.
  step('the error says it was not charged, and why', r.error?.charged === false && typeof r.error?.reason === 'string',
    `charged ${r.error?.charged ?? 'absent'}, reason ${r.error?.reason ?? 'absent'}`);

  // The rest of the app still answers for this reader while the provider "fails" (feature isolation).
  const library = await acct.rpc('v3_library_page', { p_cursor: null, p_limit: 5 }).then(() => true, () => false);
  step('the library still loads', library, library ? 'v3_library_page answered' : 'v3_library_page failed');

  let after = await acct.balance();
  for (let i = 0; i < 10 && (after.held !== 0 || after.available !== before.available); i++) { await sleep(1500); after = await acct.balance(); }
  step('the balance is unchanged and nothing is held', after.available === before.available && after.held === 0,
    `available ${before.available} → ${after.available}, held ${after.held}`);

  // Each synthetic answer is recorded (fire-and-forget from the function, so allow it a moment).
  let recorded = 0;
  for (let i = 0; i < 10 && recorded < expectedCalls; i++) { recorded = (await drillCalls(outcome)) - recordedBefore; if (recorded < expectedCalls) await sleep(1500); }
  step('the provider-health telemetry has it', recorded >= expectedCalls, `${recorded} ${outcome} drill call(s) recorded for ${provider} (want ${expectedCalls})`);
  return { operation_id: r.operationID, code, retry_after: r.error?.retry_after ?? null, charged: r.error?.charged ?? null, reason: r.error?.reason ?? null, recorded };
}

/** This hour's drill telemetry for the mode's outcome, read before and after. */
async function telemetry(step, before) {
  const [outcome, expectedCalls] = OUTCOME[mode];
  let recorded = 0;
  for (let i = 0; i < 10 && recorded < expectedCalls; i++) { recorded = (await drillCalls(outcome)) - before; if (recorded < expectedCalls) await sleep(1500); }
  step('the provider-health telemetry has it', recorded >= expectedCalls, `${recorded} ${outcome} drill call(s) recorded for ${provider} (want ${expectedCalls})`);
  return recorded;
}

// The provider fails as overloaded after the answer's first text (fault `midstream`).
async function midstreamDrill(acct, step) {
  const before = await acct.balance(), recordedBefore = await drillCalls(OUTCOME.midstream[0]);
  const r = await chat(acct, { mode: 'general', profile: HAIKU, messages: [{ role: 'user', text: 'Explain gradient descent in two sentences.' }] });
  step('the reader receives the first text', r.deltas > 0 && r.answer.length > 0, `${r.deltas} piece(s) of text, ${r.answer.length} characters, before the failure`);
  step('then a specific error, not a broken app', r.error?.code === 'provider_unavailable' && !r.done, `${r.error?.code ?? 'no error'} in ${(r.ms / 1000).toFixed(1)} s`);
  step('the error says nothing was charged, because the provider failed',
    Number(r.error?.credits) === 0 && r.error?.charged === false && r.error?.reason === 'provider',
    `credits ${r.error?.credits}, charged ${r.error?.charged}, reason ${r.error?.reason}`);
  const o = await outcomeOf(acct, r.operationID);
  step('settled at no charge, recorded as the provider\'s ending, its cost absorbed (never hidden)',
    o?.state === 'settled' && o.actual_credits === 0 && o.ending === 'provider' && o.charged === false && Number(o.absorbed_microusd) > 0,
    `state ${o?.state}, credits ${o?.actual_credits}, ending ${o?.ending}, absorbed ${o?.absorbed_microusd} micro-USD, liability ${o?.provider_liability_microusd}`);
  let after = await acct.balance();
  for (let i = 0; i < 10 && (after.held !== 0 || after.available !== before.available); i++) { await sleep(1500); after = await acct.balance(); }
  step('the balance is unchanged and nothing is held', after.available === before.available && after.held === 0, `available ${before.available} → ${after.available}, held ${after.held}`);
  const recorded = await telemetry(step, recordedBefore);
  return { operation_id: r.operationID, partial_characters: r.answer.length, error: r.error, outcome: o, recorded };
}

// Stop, a dropped connection, and a build without stop_signal (fault `slow`: a synthetic answer written over a minute).
async function stopDrill(acct, step) {
  const recordedBefore = await drillCalls(OUTCOME.stop[0]);
  const ask = { mode: 'general', profile: HAIKU, messages: [{ role: 'user', text: 'Write a long essay about the history of numerical optimization.' }] };
  const runs = {};
  for (const [name, body, stop, ending, charged] of [
    ['stop', { ...ask, capabilities: ['stop_signal'] }, true, 'stopped', true],
    ['dropped connection', { ...ask, capabilities: ['stop_signal'] }, false, 'connection', false],
    ['older build closes the stream', ask, false, 'left', true],
  ]) {
    const before = await acct.balance(), operationID = randomUUID();
    let stopRecord = null;
    const r = await chat(acct, body, { operationID, leaveAfter: 2,
      beforeLeaving: stop ? async () => { stopRecord = await acct.rpc('v1_chat_stop', { p_operation_id: operationID }); } : null });
    const o = await outcomeOf(acct, operationID);
    let after = await acct.balance();
    for (let i = 0; i < 10 && after.held !== 0; i++) { await sleep(1500); after = await acct.balance(); }
    const paid = before.available - after.available;
    step(`${name}: recorded as ${ending}, ${charged ? 'charged for what was written' : 'charged nothing'}`,
      r.left && o?.ending === ending && o.charged === charged && (charged ? o.actual_credits >= 1 : o.actual_credits === 0) && paid === o.actual_credits && after.held === 0,
      `left after ${r.deltas} pieces in ${(r.ms / 1000).toFixed(1)} s${stop ? `, Stop recorded ${stopRecord?.recorded}` : ''}; ending ${o?.ending}, credits ${o?.actual_credits}, balance ${before.available} → ${after.available}, absorbed ${o?.absorbed_microusd} micro-USD`);
    runs[name] = { operation_id: operationID, deltas: r.deltas, stop_recorded: stopRecord?.recorded ?? null, outcome: o, balance: [before.available, after.available] };
  }
  const recorded = await telemetry(step, recordedBefore);
  return { runs, recorded };
}

// An operation over its ceiling no longer pauses the month (no fault: the service RPCs a provider attempt goes through,
// with a 1 micro-USD ceiling and 3 reported). Refused when the tripwire is near, so the drill can never pause staging.
async function overrunDrill(acct, step) {
  const health = await rpc('worker_budget_health', {}, { service: true });
  if (!health?.work_enabled) { step('paid work is running before the drill', false, 'work_enabled is already false: resume it first'); return { health }; }
  if (Number(health.anomalies_in_window) + 1 > Number(health.overrun_pause_after)) {
    step('the tripwire has room for one drill anomaly', false, `${health.anomalies_in_window} of ${health.overrun_pause_after} in the window: one more would pause staging`); return { health };
  }
  const operationID = randomUUID(), attemptID = randomUUID();
  const digest = value => `\\x${sha256(value)}`;
  await rpc('worker_reserve_operation', { p_account_id: acct.id, p_id: operationID, p_kind: 'chat', p_request_sha256: digest(`overrun-drill:${operationID}`),
    p_rate_version: 'beta-credits-v1', p_credits: 1, p_microusd: 2 }, { service: true });
  const grant = await rpc('worker_provider_attempt_begin', { p_account_id: acct.id, p_operation_id: operationID, p_attempt_id: attemptID, p_provider: 'anthropic',
    p_route: 'chat', p_model: 'claude-haiku-5-5', p_request_sha256: digest(`overrun-drill-attempt:${attemptID}`), p_ceiling_microusd: 1, p_reserved_units: { output_tokens: 1 } }, { service: true });
  step('the drill attempt is admitted with a 1 micro-USD ceiling', grant?.granted === true, `granted ${grant?.granted}, reason ${grant?.reason ?? 'none'}`);
  await rpc('worker_provider_attempt_finish', { p_account_id: acct.id, p_operation_id: operationID, p_attempt_id: attemptID, p_state: 'succeeded',
    p_provider_request_id: `drill-overrun-${attemptID}`, p_actual_microusd: 3, p_actual_units: { output_tokens: 1 }, p_failure_code: null }, { service: true });
  await rpc('worker_settle_operation', { p_account_id: acct.id, p_id: operationID, p_actual_credits: 0, p_actual_microusd: 3 }, { service: true });
  const o = await outcomeOf(acct, operationID, { settled: false }); // settled above, synchronously; it has no chat ending
  const after = await rpc('worker_budget_health', {}, { service: true });
  step('an anomaly row appears for the operation (and its attempt)', o?.anomalies?.length === 2 && o.anomalies.every(a => a.test_account && !a.paused_month),
    (o?.anomalies ?? []).map(a => `${a.kind} ${a.observed_microusd}/${a.ceiling_microusd} micro-USD`).join('; ') || 'none');
  step('work_enabled stays true', after?.work_enabled === true && !after.paused_by_tripwire,
    `work_enabled ${after?.work_enabled}; ${after?.anomalies_in_window} of ${after?.overrun_pause_after} anomalies toward the tripwire; ${after?.anomalies_24h} in 24 h`);
  const r = await chat(acct, { mode: 'general', profile: HAIKU, messages: [{ role: 'user', text: 'Reply with the single word OK.' }] });
  step('chat still answers (nothing is paused)', !!r.done && !!r.answer.trim() && r.done.charged === true,
    r.done ? `answered in ${(r.ms / 1000).toFixed(1)} s, ${r.done.credits} credit(s), charged ${r.done.charged}` : `error ${r.error?.code ?? 'none'}`);
  return { operation_id: operationID, anomalies: o?.anomalies ?? [], budget: { before: health, after }, answer_operation: r.operationID, answer_credits: r.done?.credits ?? null };
}

async function chatRecovery(acct, step) {
  const r = await chat(acct, { mode: 'general', profile: HAIKU, messages: [{ role: 'user', text: 'Reply with the single word OK.' }] });
  step('after clearing, the feature works again', !!r.done && !!r.answer.trim(),
    r.done ? `answered in ${(r.ms / 1000).toFixed(1)} s, ${r.done.credits} credits` : `error ${r.error?.code ?? 'none'}`);
}

// ── Run ──────────────────────────────────────────────────────────────────────
const steps = [];
const step = (label, ok, detail) => { steps.push({ label, ok, detail }); log(`${ok ? 'PASS' : 'FAIL'} ${label}: ${detail}`); };
log(`Fault drill: ${provider} ${mode} on ${route} for ${minutes} min (staging ${PROJECT_REF})`);

if (managementToken) {
  const r = await http(`https://api.supabase.com/v1/projects/${PROJECT_REF}/secrets`, { headers: { Authorization: `Bearer ${managementToken}` } });
  // Values are listed as SHA-256 digests.
  const value = r.status === 200 ? r.json?.find(s => s.name === 'FAULT_INJECTION')?.value : undefined;
  if (r.status === 200 && value !== sha256('on')) usage(`FAULT_INJECTION is ${value === undefined ? 'not set' : 'not on'} for the staging functions; deploy with infra fault_injection true first (scripts/deploy-staging.py).`);
  if (r.status !== 200) log(`Could not read function secrets (HTTP ${r.status}); a fault that isn't honoured will show as a failed step.`);
} else log('No management token: FAULT_INJECTION is not checked first; a fault that isn\'t honoured will show as a failed step.');

let acct = null, fault = null, result = null, failure = null;
try {
  acct = await Account.create(50);
  log(`Drill account ${acct.id} (@example.invalid, 50 credits)`);
  // The database's own rule, checked first: a real-looking account is refused. The overrun drill sets no fault.
  const faultMode = mode in FAULT_MODE ? FAULT_MODE[mode] : mode;
  if (faultMode) {
    fault = await rpc('worker_fault_injection_set', { p_account: acct.id, p_provider: provider, p_route: route, p_mode: faultMode, p_rate: 1,
      p_minutes: minutes, p_reason: `scripts/fault-drill.mjs ${mode}` }, { service: true });
    log(`Fault ${faultMode} set until ${fault.until}`);
  }
  result = await DRILLS[`${provider}:${route}`](acct, step);
} catch (error) { failure = error; step('the drill ran', false, error.message); }
finally {
  if (acct && fault) {
    try { const cleared = await rpc('worker_fault_injection_clear', { p_account: acct.id }, { service: true }); log(`Fault cleared (${cleared} row)`); }
    catch (error) { step('the fault was cleared', false, `${error.message}; it expires on its own at ${fault.until}`); }
  }
}
if (acct && fault && !failure && !args['no-recovery'] && route === 'chat') {
  await sleep(16_000); // The functions cache an account's faults for 15 s.
  try { await chatRecovery(acct, step); } catch (error) { step('after clearing, the feature works again', false, error.message); }
}
// Synthetic answers never reached a provider: their attempts (request id drill-…) are reconciled to zero, releasing any
// held ceiling and synthetic cost from the month (worker_fault_drill_reconcile; test accounts only).
let reconciled = null;
if (acct) {
  try { reconciled = await rpc('worker_fault_drill_reconcile', { p_account_id: acct.id }, { service: true }); log(`Reconciled ${reconciled} synthetic attempt(s) to zero`); }
  catch (error) { log(`Synthetic attempts not reconciled (${error.message}); migration 079 provides worker_fault_drill_reconcile`); }
  if (['midstream', 'stop', 'overrun'].includes(mode)) step('synthetic attempts are reconciled to zero', Number(reconciled) >= 1, `${reconciled ?? 'none'} reconciled`);
}
if (acct && !args['keep-account']) {
  let deleted = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    deleted = await acct.fn('account-delete', { method: 'POST', body: { confirm: DELETE_CONFIRMATION } }).catch(e => ({ status: e.message }));
    if (deleted.status !== 409) break;
    await sleep(15_000); // account_busy: an operation still settling.
  }
  if (deleted.status === 200) log('Drill account deleted through account-delete');
  else log(`Drill account ${acct.id} not deleted (HTTP ${deleted.status}); the workflow checks' sweep closes it after 6 h`);
}

const failed = steps.filter(s => !s.ok);
const report = { provider, route, mode, minutes, finished_at: new Date().toISOString(), account_id: acct?.id ?? null, result, reconciled, steps };
const out = join(ROOT, '.artifacts/fault-drills');
mkdirSync(out, { recursive: true });
const file = join(out, `${report.finished_at.replace(/[:.]/g, '-')}-${provider}-${mode}.json`);
writeFileSync(file, redact(JSON.stringify(report, null, 1)), { mode: 0o600 });
console.log(`\n${steps.length - failed.length} of ${steps.length} steps passed${failed.length ? `; failed: ${failed.map(s => s.label).join('; ')}` : ''}\nReport: ${file.replace(ROOT + '/', '')}`);
process.exit(failed.length ? 1 : 0);

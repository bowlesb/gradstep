#!/usr/bin/env node
// Paid, explicit live check of Your AI usage on staging (migration 0144, `v1_ai_usage`; docs/TESTING.md). One disposable
// account with synthetic credits asks one tiny general question on Haiku at low effort, brief, without a title or
// suggestions (well under $0.02), then reads its usage back as the reader: one row, activity chat, completed, the credits
// the answer's `done` reported, the model, and the same token counts. A second disposable account (no credits, no
// requests) sees nothing; the anonymous key and a bad query are refused. Both accounts are deleted through account-delete.
// Prints ids, counts and codes only; never a token, key or password. Writes .artifacts/ai-usage-20261022/live-check.json.
//
//   node scripts/ai-usage-live-check.mjs
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_REF = 'coxhjvqpflgxkleydati';
const dotenv = path => Object.fromEntries(readFileSync(path, 'utf8').split('\n').filter(l => l.includes('=') && !l.trimStart().startsWith('#'))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]; }));
const env = dotenv(`${ROOT}/.env.staging`);
if (!env.SUPABASE_URL?.startsWith(`https://${PROJECT_REF}.`) || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) { console.error('staging env missing'); process.exit(2); }
const secrets = new Set(Object.values(env).filter(v => typeof v === 'string' && v.length >= 8));
const redact = s => { let o = String(s); for (const x of secrets) o = o.split(x).join('[redacted]'); return o.replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[jwt]'); };
const log = (...p) => console.log(redact(`${new Date().toISOString().slice(11, 19)} ${p.join(' ')}`));
const service = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
const anon = { apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${env.SUPABASE_ANON_KEY}` };
const user = token => ({ apikey: env.SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` });
async function http(url, { method = 'GET', headers = {}, body, timeoutMs = 60_000 } = {}) {
  const r = await fetch(url, { method, headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
  const text = await r.text(); let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  return { status: r.status, json, text };
}
const usage = (headers, params = {}) => http(`${env.SUPABASE_URL}/rest/v1/rpc/v1_ai_usage`, { method: 'POST', headers, body: params });
const check = (ok, label) => { if (!ok) throw new Error(`check failed: ${label}`); log(`ok  ${label}`); };

async function account(label, credits) {
  const email = `gradstep-usage-${label}-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
  secrets.add(password);
  const created = await http(`${env.SUPABASE_URL}/auth/v1/admin/users`, { method: 'POST', headers: service, body: { email, password, email_confirm: true } });
  if (created.status >= 300 || !created.json?.id) throw new Error(`create account ${label}: HTTP ${created.status}`);
  const id = created.json.id;
  log(`account ${label} ${id} created`);
  const a = { id, email, token: null };
  accounts.push(a);
  if (credits) {
    const g = await http(`${env.SUPABASE_URL}/rest/v1/rpc/worker_grant_credits`, { method: 'POST', headers: service, body: { p_account_id: id, p_source: 'adjustment',
      p_external_key: `operator:ai-usage-live:${id}`, p_credits: credits, p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Your AI usage live check synthetic grant' } });
    if (g.status >= 300) throw new Error(`grant: HTTP ${g.status}`);
  }
  const signin = await http(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body: { email, password } });
  if (signin.status !== 200 || !signin.json?.access_token) throw new Error(`sign-in ${label}: HTTP ${signin.status}`);
  a.token = signin.json.access_token; secrets.add(a.token);
  return a;
}

const accounts = [];
const record = { started_at: new Date().toISOString(), checks: [] };
let exit = 0;
try {
  const a = await account('a', 40);
  const empty = await usage(user(a.token), { p_days: 1 });
  check(empty.status === 200 && empty.json.operations.length === 0 && empty.json.totals.operations === 0, 'a new account has no usage');

  // One tiny paid question: general chat, Haiku at low effort, brief; no title, no suggestions.
  const operationID = randomUUID();
  const body = { operation_id: operationID, consent_version: 'cloud-ai-v6', mode: 'general', messages: [{ role: 'user', text: 'Reply with the single word: ok' }],
    capabilities: ['stop_signal'], profile: { model: 'haiku', effort: 'low', length: 'brief' } };
  const t0 = Date.now();
  const r = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'text/event-stream', ...user(a.token) },
    body: JSON.stringify(body), signal: AbortSignal.timeout(120_000) });
  const stream = await r.text();
  const events = [...stream.matchAll(/event: (\w+)\ndata: (.*)\n/g)].map(m => ({ event: m[1], data: (() => { try { return JSON.parse(m[2]); } catch { return null; } })() }));
  const done = events.find(e => e.event === 'done')?.data;
  log(`chat HTTP ${r.status} in ${Date.now() - t0} ms; events ${[...new Set(events.map(e => e.event))].join(',')}`);
  check(r.status === 200 && done, 'the answer finished');
  log(`done: credits ${done.credits}, model ${done.model ?? '?'}, usage ${JSON.stringify(done.usage)}`);
  record.done = { credits: done.credits, model: done.model, usage: done.usage };

  // Read it back as the reader.
  const page = (await usage(user(a.token), { p_days: 1 })).json;
  record.page = page;
  const row = page.operations[0];
  check(page.operations.length === 1 && row.id === operationID, 'one row, the operation just asked');
  check(row.activity === 'chat' && row.outcome === 'completed' && row.paid_by === 'you', `activity ${row.activity}, outcome ${row.outcome}`);
  check(row.credits === done.credits, `credits ${row.credits} = the answer's ${done.credits}`);
  check(/haiku/.test(row.model ?? ''), `model ${row.model}`);
  check(row.parts.every(p => p.part !== 'title' && p.part !== 'suggestions'), `parts ${row.parts.map(p => p.part).join(',')}`);
  const reported = (done.usage.input_tokens ?? 0) + (done.usage.cache_creation_input_tokens ?? done.usage.cache_write_tokens ?? 0);
  log(`tokens: row in ${row.input_tokens} + cache write ${row.cache_write_tokens}, cached ${row.cached_tokens}, out ${row.output_tokens}; done usage in ${reported}, out ${done.usage.output_tokens}`);
  check(row.output_tokens === done.usage.output_tokens, 'output tokens match the answer');
  check(page.totals.operations === 1 && page.totals.credits === done.credits && page.activities.length === 1, 'totals and activities');
  check(!/microusd|provider_request|request_sha|transport|prompt|document|email|Reply with/.test(JSON.stringify(page)), 'no private or dollar fields');

  // A second account sees nothing of the first.
  const b = await account('b', 0);
  const other = await usage(user(b.token), { p_days: 366 });
  check(other.status === 200 && other.json.operations.length === 0 && other.json.totals.operations === 0, 'a second account sees nothing');
  // Refusals: anonymous, a bad query.
  const anonymous = await usage(anon, { p_days: 30 });
  check(anonymous.status >= 400, `anonymous refused (HTTP ${anonymous.status} ${anonymous.json?.code ?? ''})`);
  const bad = await usage(user(a.token), { p_days: 0 });
  check(bad.status >= 400 && /invalid_usage_query/.test(bad.text), 'a bad query is refused');
  record.result = 'passed';
} catch (error) { exit = 1; record.result = `failed: ${redact(error.message)}`; log(`FAILED: ${error.message}`); }
finally {
  for (const a of accounts) {
    let deleted = null;
    if (a.token) deleted = await http(`${env.SUPABASE_URL}/functions/v1/account-delete`, { method: 'POST', body: { confirm: 'delete my account' }, headers: user(a.token) });
    if (!deleted || deleted.status !== 200) {
      const r = await http(`${env.SUPABASE_URL}/auth/v1/admin/users/${a.id}`, { method: 'DELETE', headers: service });
      log(`account-delete ${deleted?.status ?? 'skipped'}; admin delete HTTP ${r.status}`);
    } else log(`account ${a.id} deleted (account-delete HTTP 200)`);
  }
  const users = await http(`${env.SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=500`, { headers: service });
  const remaining = (users.json?.users ?? []).filter(u => accounts.some(a => a.id === u.id));
  log(`cleanup: ${remaining.length === 0 ? 'auth users gone' : 'AUTH USER STILL PRESENT'}`);
  if (remaining.length) exit = 1;
  record.accounts = accounts.map(a => a.id);
  record.finished_at = new Date().toISOString();
  mkdirSync(`${ROOT}/.artifacts/ai-usage-20261022`, { recursive: true });
  writeFileSync(`${ROOT}/.artifacts/ai-usage-20261022/live-check.json`, redact(JSON.stringify(record, null, 1)));
}
process.exit(exit);

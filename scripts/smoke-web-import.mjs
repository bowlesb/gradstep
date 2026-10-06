#!/usr/bin/env node
// Staging check for web imports (migration 019), API level: synthetic account →
// Ingest from an older build (no capability: told to update, nothing added) →
// Ingest from a current build (web paper queued) → v2 reads never show it, v3
// reads do → server conversion of the open-access PDF → reader bundle verified.
// Budget-capped by the database. Usage:
//   node scripts/smoke-web-import.mjs [--citation="..."] [--account=<id>] [--timeout=900]
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const args = Object.fromEntries(process.argv.slice(2).map(a => { const [k, ...v] = a.replace(/^--/, '').split('='); return [k, v.length ? v.join('=') : 'true']; }));
// JMLR 2014: open access at jmlr.org, no arXiv copy under this title.
const citation = args.citation ?? '[34] N. Srivastava, G. Hinton, A. Krizhevsky, I. Sutskever, R. Salakhutdinov. Dropout: A Simple Way to Prevent Neural Networks from Overfitting. JMLR 15, 2014.';
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
let account = args.account, email, password;
if (!account) {
  email = `science-reader-smoke-${randomUUID()}@example.invalid`; password = randomBytes(36).toString('base64url');
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  assert.equal(created.error, null); account = created.data.user.id;
  const grant = await admin.rpc('worker_grant_credits', { p_account_id: account, p_source: 'adjustment', p_external_key: `operator:smoke:${account}`,
    p_credits: Number(args.credits ?? 300), p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Synthetic smoke test grant' });
  assert.equal(grant.error, null, grant.error?.message);
  writeFileSync(new URL(`.artifacts/smoke-${account}.json`, root), JSON.stringify({ account, email, password }), { mode: 0o600 });
} else ({ email, password } = JSON.parse(readFileSync(new URL(`.artifacts/smoke-${account}.json`, root), 'utf8')));
const user = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const signed = await user.auth.signInWithPassword({ email, password }); assert.equal(signed.error, null, signed.error?.message);
const token = signed.data.session.access_token;
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
log('account', account, 'credits', JSON.stringify((await user.rpc('v1_credit_balance')).data));

const entries = async (fn) => { const r = await user.rpc(fn, { p_limit: 100 }); assert.equal(r.error, null, r.error?.message); return r.data.entries; };
async function ingest(capabilities) {
  const response = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST',
    headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ operation_id: randomUUID(), consent_version: 'cloud-ai-v1', mode: 'general', selection: { quote: citation }, action: 'ingest',
      messages: [{ role: 'user', text: 'Find and add the paper referenced in this passage.' }], ...(capabilities ? { capabilities } : {}) }) });
  const text = await response.text(); let answer = '', done = null, error = null;
  for (const block of text.split('\n\n')) {
    const ev = /^event: (\w+)/m.exec(block)?.[1], data = /^data: (.*)$/m.exec(block)?.[1];
    if (!ev || !data) continue;
    const value = JSON.parse(data);
    if (ev === 'delta') answer += value.text; else if (ev === 'done') done = value; else if (ev === 'error') error = value;
  }
  log(`ingest (${capabilities ? 'current build' : 'older build'})`, response.status, error ? `error ${error.code}` : `credits ${done?.credits}`);
  console.log('   ' + answer.trim().split('\n').at(-1));
  return answer;
}

if (!args.skipOld) {
  const answer = await ingest(null);
  assert.match(answer, /needs the latest Science Reader version|is already in your library|Queued .*arXiv/, 'older build: no web import');
  assert.ok(!(await entries('v3_library_page')).some(e => e.source === 'web'), 'older build added nothing from the web');
}
const answer = await ingest(['web_import']);
assert.match(answer, /Queued .*open-access PDF|already in your library/, 'current build: web paper queued');
const v3 = await entries('v3_library_page');
const imported = v3.find(e => e.kind === 'import' && e.source === 'web');
assert.ok(imported, 'web import visible in v3');
assert.match(imported.source_id, /^openalex:W\d+$/);
assert.equal(imported.source_url, `https://openalex.org/works/${imported.source_id.slice(9)}`);
assert.ok(!(await entries('v2_library_page')).some(e => e.source === 'web' || e.source_id === imported.source_id), 'v2 page hides web entries');
const changes = (await user.rpc('v2_library_changes', { p_after: 0 })).data;
assert.ok(!changes.changes.some(c => c.entries.some(e => e.source === 'web')), 'v2 changes hide web entries');
log('import', imported.source_id, imported.phase, '— hidden from v2, shown in v3');

await fetch(`${env.SUPABASE_URL}/functions/v1/paper-worker`, { method: 'POST', headers: { 'x-pipeline-secret': env.PIPELINE_SECRET } });
const started = Date.now(); let item, last = '';
while (Date.now() - started < Number(args.timeout ?? 900) * 1000) {
  const all = await entries('v3_library_page');
  const current = all.find(e => e.kind === 'import' && e.id === imported.id);
  item = current?.library_item_id ? all.find(e => e.kind === 'item' && e.id === current.library_item_id) : null;
  const state = item ? `item ${item.readiness}` : `import ${current?.phase} ${current?.progress ?? ''} ${current?.error_code ?? ''}`;
  if (state !== last) { log(state); last = state; }
  if (item?.readiness === 'converted_ready') break;
  if (current?.phase === 'failed') { console.error('Import failed:', current.error_code, current.retryable ? '(retryable)' : ''); process.exit(1); }
  await new Promise(r => setTimeout(r, 5000));
}
assert.equal(item?.readiness, 'converted_ready', 'conversion did not finish in time');
assert.equal(item.source, 'web'); assert.equal(item.scope, 'owner_private'); assert.match(item.source_url, /^https:\/\//);
log('converted in', Math.round((Date.now() - started) / 1000), 's;', item.page_count, 'pages;', JSON.stringify(item.metadata.title), '; source', item.source_url);
assert.ok(!(await entries('v2_library_page')).some(e => e.id === item.id), 'v2 page hides the web item');

const descriptor = await (await fetch(`${env.SUPABASE_URL}/functions/v1/reader-artifact?item_id=${item.id}`, { headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY } })).json();
assert.ok(descriptor.manifest_sha256, JSON.stringify(descriptor));
assert.equal(createHash('sha256').update(Buffer.from(descriptor.manifest, 'base64')).digest('hex'), descriptor.manifest_sha256);
let total = 0;
for (const m of descriptor.members) {
  const bytes = Buffer.from(await (await fetch(m.url)).arrayBuffer()); total += bytes.length;
  assert.equal(createHash('sha256').update(bytes).digest('hex'), m.sha256, m.path);
}
const notice = descriptor.members.find(m => m.path === 'NOTICE.txt');
const attribution = notice ? (await (await fetch(notice.url)).text()).split('Document attribution').at(1) ?? '' : '';
assert.match(attribution, /Converted for the personal use of one Science Reader account; not redistributed\. Original: https:\/\//, 'private attribution');
assert.ok(!/arXiv:/.test(attribution), 'no arXiv attribution on a web paper');
log('attribution ok:', attribution.trim().split('\n').at(-1).slice(0, 160));
log('reader bundle verified:', descriptor.members.length, 'members,', total, 'bytes');
log('credits after', JSON.stringify((await user.rpc('v1_credit_balance')).data));

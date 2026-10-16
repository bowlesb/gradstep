#!/usr/bin/env node
// API-level staging journey (no UI): synthetic account → recorded credit grant →
// v2_begin_import → server conversion → reader-artifact download + hash checks →
// one paid chat answer. Budget-capped by the database. Prints a short report.
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const args = Object.fromEntries(process.argv.slice(2).map(a => a.replace(/^--/, '').split('=')));
const arxiv = args.arxiv ?? '2305.18290';
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

const page = async () => { const r = await user.rpc('v2_library_page', { p_limit: 100 }); assert.equal(r.error, null, r.error?.message); return r.data.entries; };
if (!args.skipImport) {
  const cursor = (await user.rpc('v2_library_changes', { p_after: 0 })).data?.next_cursor ?? 0;
  const begun = await user.rpc('v2_begin_import', { p_operation_id: randomUUID(), p_source_id: arxiv, p_observed_cursor: cursor });
  assert.equal(begun.error, null, begun.error?.message); log('import', begun.data.entry.phase);
}
// The Cloud Run worker (the Edge paper-worker is retired and undeployed).
await fetch(JSON.parse(readFileSync(new URL('infra/staging.json', root), 'utf8')).pipeline_worker_url, { method: 'POST', headers: { 'x-pipeline-secret': env.PIPELINE_SECRET } });
const started = Date.now(); let item, last = '';
while (Date.now() - started < Number(args.timeout ?? 600) * 1000) {
  const entries = await page();
  const imported = entries.find(e => e.kind === 'import' && e.source_id === arxiv);
  item = entries.find(e => e.kind === 'item' && e.source_id === arxiv);
  const state = item ? `item ${item.readiness} render=${item.render_availability}` : imported ? `import ${imported.phase} ${imported.progress ?? ''} ${imported.error_code ?? ''}` : 'none';
  if (state !== last) { log(state); last = state; }
  if (item?.readiness === 'converted_ready') break;
  if (imported?.phase === 'failed' || imported?.phase === 'source_only') { console.error('Import ended:', imported.phase, imported.error_code); process.exit(1); }
  await new Promise(r => setTimeout(r, 5000));
}
assert.equal(item?.readiness, 'converted_ready', 'conversion did not finish in time');
log('converted in', Math.round((Date.now() - started) / 1000), 's; scope', item.scope, 'pages', item.page_count);

const descriptor = await (await fetch(`${env.SUPABASE_URL}/functions/v1/reader-artifact?item_id=${item.id}`, { headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY } })).json();
assert.ok(descriptor.manifest_sha256, JSON.stringify(descriptor));
const manifest = Buffer.from(descriptor.manifest, 'base64');
assert.equal(createHash('sha256').update(manifest).digest('hex'), descriptor.manifest_sha256);
let total = 0;
for (const m of descriptor.members) {
  const bytes = Buffer.from(await (await fetch(m.url)).arrayBuffer()); total += bytes.length;
  assert.equal(createHash('sha256').update(bytes).digest('hex'), m.sha256, m.path);
}
log('reader bundle verified:', descriptor.members.length, 'members,', total, 'bytes, renderer', descriptor.renderer_version);

async function ask(question, extra = {}) {
  const response = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ operation_id: randomUUID(), consent_version: 'cloud-ai-v1', mode: 'paper', document_id: item.document_id, messages: [{ role: 'user', text: question }], ...extra }) });
  const text = await response.text(); let answer = '', done = null, error = null;
  for (const block of text.split('\n\n')) {
    const ev = /^event: (\w+)/m.exec(block)?.[1], data = /^data: (.*)$/m.exec(block)?.[1];
    if (!ev || !data) continue;
    const value = JSON.parse(data);
    if (ev === 'delta') answer += value.text; else if (ev === 'done') done = value; else if (ev === 'error') error = value;
    else if (ev === 'diagram') { log('diagram', JSON.stringify(value.title), `${value.source.split('\n').length} lines`); if (args.diagramOut) writeFileSync(args.diagramOut, value.source); }
  }
  log('chat http', response.status, error ? `error ${error.code}` : `done ${JSON.stringify(done)}`);
  console.log('--- answer ---\n' + answer.slice(0, 1200) + (answer.length > 1200 ? '…' : '') + '\n--------------');
  if (args.answerOut) writeFileSync(args.answerOut, answer);
}
if (args.question !== 'none') {
  await ask(args.question ?? 'In two sentences, what objective does DPO optimize and why does it avoid an explicit reward model? Cite the equation.');
}
if (args.ingest) {
  // The app's Ingest selection action: the server adds the referenced paper.
  const before = new Set((await page()).filter(e => e.kind === 'import').map(e => e.id));
  await ask(`Find and add the paper referenced in this passage: ${args.ingest}`, { selection: { quote: args.ingest }, action: 'ingest' });
  const added = (await page()).filter(e => e.kind === 'import' && !before.has(e.id));
  log('ingest imports', JSON.stringify(added.map(e => ({ source: e.source_id, phase: e.phase }))));
}
log('credits after', JSON.stringify((await user.rpc('v1_credit_balance')).data));

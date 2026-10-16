#!/usr/bin/env node
// Staging check of account deletion end to end: a synthetic account with keys,
// a support report, a shared and a private paper and a paid answer is deleted
// through the account-delete function; the script then verifies what is gone
// (rows, private files, login) and what is kept (billing). Small paid cost
// (one private conversion and one answer). Usage: node scripts/smoke-account-deletion.mjs
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const args = Object.fromEntries(process.argv.slice(2).map(a => a.replace(/^--/, '').split('=')));
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const email = `science-reader-delete-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
assert.equal(created.error, null); const account = created.data.user.id;
assert.equal((await admin.rpc('worker_grant_credits', { p_account_id: account, p_source: 'adjustment', p_external_key: `operator:delete-smoke:${account}`,
  p_credits: 200, p_starts_at: '2026-01-01T00:00:00Z', p_expires_at: null, p_reason: 'Synthetic deletion smoke grant' })).error, null);
const user = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const signed = await user.auth.signInWithPassword({ email, password }); assert.equal(signed.error, null);
const token = signed.data.session.access_token;
log('account', account);

// Personal data: encryption keys + one encrypted event, a report, two imports.
const device = randomUUID();
const hex = (b, n) => '\\x' + Buffer.alloc(n, b).toString('hex');
assert.equal((await user.rpc('v1_bootstrap_keys', { p_device_id: device, p_public_key: hex(0x11, 32), p_recovery_package: hex(0x22, 60),
  p_management_token: hex(0x33, 32), p_device_envelope: hex(0x44, 92), p_challenge: hex(0xaa, 32) })).error, null);
assert.equal((await user.rpc('v1_create_report', { p_id: randomUUID(), p_title: 'Deletion smoke', p_note: 'Synthetic report',
  p_app_version: '0.1', p_build: '1', p_os_version: 'iOS', p_screen: 'paper' })).error, null);
const cursor = async () => (await user.rpc('v2_library_page', { p_cursor: null, p_limit: 1 })).data.baseline_cursor;
for (const source of ['2305.18290', args.private ?? '1706.03762']) {
  const begun = await user.rpc('v2_begin_import', { p_operation_id: randomUUID(), p_source_id: source, p_observed_cursor: await cursor() });
  assert.equal(begun.error, null, begun.error?.message);
}
// The Cloud Run worker (the Edge paper-worker is retired and undeployed).
await fetch(JSON.parse(readFileSync(new URL('infra/staging.json', root), 'utf8')).pipeline_worker_url, { method: 'POST', headers: { 'x-pipeline-secret': env.PIPELINE_SECRET } });
const started = Date.now();
for (;;) {
  const entries = (await user.rpc('v2_library_page', { p_cursor: null, p_limit: 100 })).data.entries;
  const ready = entries.filter(e => e.kind === 'item' && e.readiness === 'converted_ready');
  if (ready.length === 2) { log('both papers converted; scopes', ready.map(e => e.scope).join(', ')); break; }
  assert.ok(Date.now() - started < 600_000, 'conversion timed out');
  await new Promise(r => setTimeout(r, 5000));
}
const item = (await user.rpc('v2_library_page', { p_cursor: null, p_limit: 100 })).data.entries.find(e => e.kind === 'item');
const answer = await fetch(`${env.SUPABASE_URL}/functions/v1/chat`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY, 'content-type': 'application/json' },
  body: JSON.stringify({ operation_id: randomUUID(), consent_version: 'cloud-ai-v1', mode: 'paper', document_id: item.document_id, messages: [{ role: 'user', text: 'One sentence: what is this paper about?' }] }) });
assert.ok((await answer.text()).includes('event: done'), 'paid answer completed');
// A file inside the private conversion's reader folder (tracked only by its manifest).
const privateItem = (await user.rpc('v2_library_page', { p_cursor: null, p_limit: 100 })).data.entries.find(e => e.kind === 'item' && e.scope === 'owner_private');
const descriptor = await (await fetch(`${env.SUPABASE_URL}/functions/v1/reader-artifact?item_id=${privateItem.id}`, { headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY } })).json();
const readerFile = decodeURIComponent(new URL(descriptor.members.find(m => m.path === 'index.html').url).pathname.replace(/^\/storage\/v1\/object\/sign\/paper-assets\//, ''));
assert.match(readerFile, /^reader\/[0-9a-f]{64}\/index\.html$/);
assert.equal((await admin.storage.from('paper-assets').download(readerFile)).error, null, 'private reader file exists before');
log('private reader file', readerFile);
const privatePrefix = `private/${account}`;
const listed = await admin.storage.from('paper-assets').list(privatePrefix, { limit: 100 });
log('private files before:', listed.data?.length ?? 0, 'top-level entries');

// Delete through the function, as the app does.
const wrong = await fetch(`${env.SUPABASE_URL}/functions/v1/account-delete`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY, 'content-type': 'application/json' }, body: '{"confirm":"yes"}' });
assert.equal(wrong.status, 400, 'confirmation is required');
const deleted = await fetch(`${env.SUPABASE_URL}/functions/v1/account-delete`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY, 'content-type': 'application/json' }, body: '{"confirm":"delete my account"}' });
const result = await deleted.json(); log('delete', deleted.status, JSON.stringify(result));
assert.equal(deleted.status, 200); assert.equal(result.complete, true);

// Verify.
const again = await fetch(`${env.SUPABASE_URL}/functions/v1/reader-artifact?item_id=${item.id}`, { headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY } });
assert.ok(again.status >= 400, 'old token no longer works');
assert.ok((await admin.auth.admin.getUserById(account)).error, 'login deleted');
const after = await admin.storage.from('paper-assets').list(privatePrefix, { limit: 100 });
assert.equal(after.data?.length ?? 0, 0, 'private files deleted');
assert.ok((await admin.storage.from('paper-assets').download(readerFile)).error, 'private reader folder deleted');
const status = await admin.rpc('worker_account_deletion_status', { p_account_id: account });
assert.equal(status.error, null, status.error?.message); log('server status', JSON.stringify(status.data));
assert.equal(status.data.personal_rows, 0, 'no personal rows remain');
assert.ok(status.data.closed && !status.data.login_linked, 'account closed and unlinked');
assert.ok(status.data.billing_rows > 0, 'billing records kept');
console.log('PASS account deletion smoke', account);

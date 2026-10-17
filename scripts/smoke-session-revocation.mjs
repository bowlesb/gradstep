#!/usr/bin/env node
// Opt-in staging auth lifecycle check. No papers, mail, AI calls or credits.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {randomBytes, randomUUID} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';

const env = Object.fromEntries(readFileSync(new URL('../.env.staging', import.meta.url), 'utf8')
  .split('\n').filter(s => s.includes('=')).map(s => { const i = s.indexOf('='); return [s.slice(0, i), s.slice(i + 1)]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY,
  {auth: {persistSession: false, autoRefreshToken: false}});
const evidence = {at: new Date().toISOString(), checks: []};
let account, deleted = false;
async function request(path, body, token) {
  const r = await fetch(`${env.SUPABASE_URL}/${path}`, {method: 'POST', redirect: 'error',
    headers: {'Content-Type': 'application/json', apikey: env.SUPABASE_ANON_KEY,
      ...(token ? {Authorization: `Bearer ${token}`} : {})}, body: JSON.stringify(body)});
  return {status: r.status, body: await r.json()};
}
try {
  const email = `session-revocation-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
  const made = await admin.auth.admin.createUser({email, password, email_confirm: true});
  assert.equal(made.error, null); account = made.data.user.id;
  const first = await request('auth/v1/token?grant_type=password', {email, password});
  const second = await request('auth/v1/token?grant_type=password', {email, password});
  assert.equal(first.status, 200); assert.equal(second.status, 200);
  const deletion = await request('functions/v1/account-delete', {confirm: 'delete my account'}, first.body.access_token);
  assert.equal(deletion.status, 200); assert.equal(deletion.body.deleted, true); assert.equal(deletion.body.complete, true);
  deleted = true;
  evidence.checks.push({action: 'delete on first session', status: deletion.status, complete: true});
  const refresh = await request('auth/v1/token?grant_type=refresh_token', {refresh_token: second.body.refresh_token});
  evidence.checks.push({action: 'refresh second session after deletion', status: refresh.status,
    code: refresh.body.error_code ?? refresh.body.code});
  assert.equal(refresh.status, 400); assert.equal(refresh.body.error_code, 'refresh_token_not_found');
  const rpc = await request('rest/v1/rpc/v1_key_state', {p_device_id: randomUUID()}, second.body.access_token);
  evidence.checks.push({action: 'RPC with unexpired token after deletion', status: rpc.status,
    code: rpc.body.code, reason: ['account_unavailable', 'account_closed', 'authentication_required'].includes(rpc.body.message) ? rpc.body.message : 'unclassified'});
  assert.equal(rpc.status, 403); assert.equal(rpc.body.code, '28000');
  assert.equal(rpc.body.message, 'authentication_required');
  const user = await admin.auth.admin.getUserById(account);
  assert.ok(user.error); evidence.checks.push({action: 'deleted login absent', absent: true});
} finally {
  if (account && !deleted) {
    // Only this synthetic UUID; the production worker completes its normal deletion lifecycle.
    const begun = await admin.rpc('worker_delete_account_begin', {p_account_id: account});
    assert.equal(begun.error, null, 'fixture account cleanup could not begin');
    const finished = await admin.rpc('worker_delete_account_finish', {p_account_id: account});
    assert.equal(finished.error, null, 'fixture account cleanup could not finish');
    assert.equal((await admin.auth.admin.deleteUser(account)).error, null);
  }
  const folder = '.artifacts/feedback/followup-20261017'; mkdirSync(folder, {recursive: true});
  writeFileSync(`${folder}/hosted-session-revocation.json`, JSON.stringify(evidence, null, 2) + '\n', {mode: 0o600});
}
console.log(JSON.stringify(evidence));

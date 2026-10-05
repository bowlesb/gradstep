#!/usr/bin/env node
// Staging check of the App Store purchase functions without Apple data: forged
// or malformed transactions are refused, the plan summary answers, and the
// notification webhook refuses unsigned payloads. A real sandbox purchase is
// still needed to verify Apple-signed data end to end. No cost.
import assert from 'node:assert/strict';
import { randomBytes, randomUUID, generateKeyPairSync, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const root = new URL('../', import.meta.url);
const env = Object.fromEntries(readFileSync(new URL('.env.staging', root), 'utf8').split('\n').filter(l => l.includes('='))
  .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati');
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const email = `science-reader-store-${randomUUID()}@example.invalid`, password = randomBytes(36).toString('base64url');
const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
assert.equal(created.error, null); const account = created.data.user.id;
const user = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const signed = await user.auth.signInWithPassword({ email, password }); assert.equal(signed.error, null);
const headers = { Authorization: `Bearer ${signed.data.session.access_token}`, apikey: env.SUPABASE_ANON_KEY, 'content-type': 'application/json' };

// A self-signed ES256 JWS claiming to be a Sandbox transaction for this account.
const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const b64 = v => Buffer.from(JSON.stringify(v)).toString('base64url');
const head = b64({ alg: 'ES256', x5c: ['AAAA', 'BBBB', 'CCCC'] });
const body = b64({ transactionId: '2000000999999999', originalTransactionId: '2000000999999999', bundleId: 'com.sciencereader.ios',
  productId: 'com.sciencereader.ios.credits.400', purchaseDate: Date.now(), signedDate: Date.now(), type: 'Consumable', quantity: 1,
  appAccountToken: account, environment: 'Sandbox', inAppOwnershipType: 'PURCHASED' });
const forged = `${head}.${body}.${sign('sha256', Buffer.from(`${head}.${body}`), { key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
const xcode = `${head}.${b64({ environment: 'Xcode' })}.x`;

const sync = await fetch(`${env.SUPABASE_URL}/functions/v1/store-sync`, { method: 'POST', headers, body: JSON.stringify({ transactions: [forged, xcode, 'garbage'] }) });
const synced = await sync.json(); console.log('store-sync', sync.status, JSON.stringify(synced));
assert.equal(sync.status, 200);
assert.deepEqual(synced.results.map(r => r.outcome), ['invalid', 'environment_unavailable', 'invalid']);
const empty = await fetch(`${env.SUPABASE_URL}/functions/v1/store-sync`, { method: 'POST', headers, body: '{"transactions":[]}' });
assert.equal(empty.status, 400);
const anonymous = await fetch(`${env.SUPABASE_URL}/functions/v1/store-sync`, { method: 'POST', headers: { apikey: env.SUPABASE_ANON_KEY }, body: '{}' });
assert.equal(anonymous.status, 401);
const summary = await user.rpc('v1_store_summary'); console.log('summary', JSON.stringify(summary.data));
assert.equal(summary.error, null); assert.equal(summary.data.plan, null);
const balance = await user.rpc('v1_credit_balance'); assert.equal(balance.data.available, 0, 'forged purchase granted nothing');

const hook = await fetch(`${env.SUPABASE_URL}/functions/v1/app-store-notifications`, { method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ signedPayload: `${head}.${b64({ notificationType: 'REFUND', notificationUUID: randomUUID(), signedDate: Date.now(),
    data: { bundleId: 'com.sciencereader.ios', environment: 'Sandbox', signedTransactionInfo: forged } })}.x` }) });
console.log('notification', hook.status, await hook.text());
assert.equal(hook.status, 400);
assert.equal((await fetch(`${env.SUPABASE_URL}/functions/v1/app-store-notifications`)).status, 405);
await admin.auth.admin.deleteUser(account);
console.log('PASS store smoke');

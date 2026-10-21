#!/usr/bin/env node
// Staging opt-in check of encrypted note images (docs/architecture/NOTES_AND_SNIPPETS.md, migration 095): two
// disposable @example.invalid accounts. A encrypts a blob as the contract says (AES-256-GCM, account/blob AAD),
// PUTs it, repeats it, GETs it back and decrypts it; a different digest is 409, a wrong digest header 400, an
// oversize body 413; B cannot read A's object and its own object of the same ID stays separate. Both accounts are
// deleted through account-delete and their folders are listed empty. No real user, paper, AI call or credits.
// Usage: node scripts/smoke-note-assets.mjs
import assert from 'node:assert/strict';
import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const env = Object.fromEntries(readFileSync(new URL('../.env.staging', import.meta.url), 'utf8')
  .split('\n').filter(s => s.includes('=')).map(s => { const i = s.indexOf('='); return [s.slice(0, i).trim(), s.slice(i + 1).trim()]; }));
assert.equal(env.SUPABASE_PROJECT_REF, 'coxhjvqpflgxkleydati', 'staging only');
const fixture = JSON.parse(readFileSync(new URL('../tests/fixtures/notes/notes-v1.json', import.meta.url), 'utf8')).blob;
const admin = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const base = `${env.SUPABASE_URL}/functions/v1/note-assets`;
const evidence = { at: new Date().toISOString(), project: env.SUPABASE_PROJECT_REF, checks: [], realUserTouched: false, modelCalls: 0 };
const accounts = [];
const hex = bytes => createHash('sha256').update(bytes).digest('hex');
const record = (action, fields) => { evidence.checks.push({ action, ...fields }); console.log(action, JSON.stringify(fields)); };

async function account(label) {
  const email = `note-assets-${label}-${randomUUID()}@example.invalid`, password = randomBytes(32).toString('base64url');
  const made = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  assert.equal(made.error, null, 'fixture account');
  const entry = { id: made.data.user.id, deleted: false }; accounts.push(entry);
  const signed = await fetch(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, { method: 'POST', redirect: 'error',
    headers: { 'content-type': 'application/json', apikey: env.SUPABASE_ANON_KEY }, body: JSON.stringify({ email, password }) });
  assert.equal(signed.status, 200, 'password sign-in');
  entry.token = (await signed.json()).access_token;
  return entry;
}
/** The contract's blob: fresh key and nonce, AAD binds the account and blob IDs; stored = nonce ‖ ciphertext ‖ tag. */
function encrypt(accountID, blobID, plaintext) {
  const key = randomBytes(32), nonce = randomBytes(12), aad = Buffer.from(`science-reader/snippet-blob/v1\n${accountID}\n${blobID}\n`);
  const cipher = createCipheriv('aes-256-gcm', key, nonce); cipher.setAAD(aad);
  const blob = Buffer.concat([nonce, cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return { key, aad, blob: new Uint8Array(blob) };
}
function decrypt({ key, aad }, blob) {
  const decipher = createDecipheriv('aes-256-gcm', key, blob.subarray(0, 12)); decipher.setAAD(aad);
  decipher.setAuthTag(blob.subarray(blob.length - 16));
  return Buffer.concat([decipher.update(blob.subarray(12, blob.length - 16)), decipher.final()]);
}
const call = (method, blobID, token, body, digest, extra = {}) => fetch(`${base}/${blobID}`, { method, redirect: 'error',
  headers: { apikey: env.SUPABASE_ANON_KEY, ...(token ? { authorization: `Bearer ${token}` } : {}), ...(digest ? { 'x-content-sha256': digest } : {}), ...extra },
  ...(body ? { body } : {}) });
async function listed(accountID) {
  const { data, error } = await admin.storage.from('note-assets').list(accountID, { limit: 100 });
  assert.equal(error, null, 'service listing'); return (data ?? []).map(entry => entry.name).sort();
}
async function inventory(accountID) {
  const { data, error } = await admin.rpc('worker_account_deletion_status', { p_account_id: accountID });
  assert.equal(error, null, 'deletion status'); return data;
}

try {
  const a = await account('a'), b = await account('b');
  const blobID = randomUUID(), plaintext = Buffer.from(fixture.plaintextHex.repeat(64), 'hex');
  const sealed = encrypt(a.id, blobID, plaintext), digest = hex(sealed.blob);

  const preflight = await fetch(`${base}/${blobID}`, { method: 'OPTIONS', headers: { origin: 'https://app.gradstep.ai',
    'access-control-request-method': 'PUT', 'access-control-request-headers': 'authorization, x-content-sha256' } });
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get('access-control-allow-methods') ?? '', /PUT/);
  assert.match(preflight.headers.get('access-control-allow-headers') ?? '', /x-content-sha256/);
  record('browser preflight', { status: preflight.status, origin: preflight.headers.get('access-control-allow-origin') });

  const anonymous = await call('GET', blobID, null);
  assert.equal(anonymous.status, 401); record('GET without a session', { status: anonymous.status });

  const put = await call('PUT', blobID, a.token, sealed.blob, digest);
  const putBody = await put.json();
  assert.equal(put.status, 200); assert.deepEqual(putBody, { state: 'ready', bytes: sealed.blob.length });
  assert.equal(put.headers.get('cache-control'), 'private, no-store');
  record('A PUT encrypted blob', { status: put.status, body: putBody });

  const again = await call('PUT', blobID, a.token, sealed.blob, digest);
  assert.equal(again.status, 200); assert.deepEqual(await again.json(), { state: 'ready', bytes: sealed.blob.length });
  record('A repeats the same PUT', { status: again.status });

  const got = await call('GET', blobID, a.token);
  const bytes = new Uint8Array(await got.arrayBuffer());
  assert.equal(got.status, 200); assert.equal(hex(bytes), digest);
  assert.equal(got.headers.get('content-type'), 'application/octet-stream');
  assert.equal(got.headers.get('cache-control'), 'private, no-store');
  assert.equal(got.headers.get('x-content-sha256'), digest);
  assert.deepEqual(decrypt(sealed, bytes), plaintext);
  record('A GET returns identical bytes that decrypt', { status: got.status, bytes: bytes.length, sha256Match: true, decrypted: true,
    contentType: got.headers.get('content-type'), cacheControl: got.headers.get('cache-control') });

  const other = encrypt(a.id, blobID, Buffer.from('a different image'));
  const conflict = await call('PUT', blobID, a.token, other.blob, hex(other.blob));
  assert.equal(conflict.status, 409); assert.deepEqual(await conflict.json(), { code: 'conflict' });
  record('A PUT another digest for the same blob ID', { status: conflict.status });

  const mismatch = await call('PUT', randomUUID(), a.token, sealed.blob, '0'.repeat(64));
  assert.equal(mismatch.status, 400); assert.equal((await mismatch.json()).code, 'digest_mismatch');
  record('wrong x-content-sha256', { status: mismatch.status });

  const oversize = new Uint8Array(2 * 1024 * 1024 + 29);
  const tooLarge = await call('PUT', randomUUID(), a.token, oversize, hex(oversize));
  assert.equal(tooLarge.status, 413); record('2 MiB + 29 bytes', { status: tooLarge.status, code: (await tooLarge.json()).code });

  // The largest stored blob: a 2 MiB image's ciphertext with its nonce and tag (the bucket's exact size limit).
  const largestID = randomUUID(), largest = encrypt(a.id, largestID, randomBytes(2 * 1024 * 1024));
  assert.equal(largest.blob.length, 2 * 1024 * 1024 + 28);
  const bigPut = await call('PUT', largestID, a.token, largest.blob, hex(largest.blob));
  assert.equal(bigPut.status, 200); assert.deepEqual(await bigPut.json(), { state: 'ready', bytes: largest.blob.length });
  const bigGet = await call('GET', largestID, a.token);
  const bigBytes = new Uint8Array(await bigGet.arrayBuffer());
  assert.equal(bigGet.status, 200); assert.equal(hex(bigBytes), hex(largest.blob)); decrypt(largest, bigBytes);
  record('2 MiB + 28 bytes stored and read back', { put: bigPut.status, get: bigGet.status, bytes: bigBytes.length, decrypted: true });

  const foreign = await call('GET', blobID, b.token);
  assert.equal(foreign.status, 404); assert.deepEqual(await foreign.json(), { code: 'not_found' });
  record('B GET A\'s blob', { status: foreign.status });
  const own = encrypt(b.id, blobID, Buffer.from('B\'s own image'));
  const ownPut = await call('PUT', blobID, b.token, own.blob, hex(own.blob));
  assert.equal(ownPut.status, 200);
  const stillA = await call('GET', blobID, a.token);
  assert.equal(hex(new Uint8Array(await stillA.arrayBuffer())), digest);
  record('B PUT the same blob ID is B\'s own object; A\'s is unchanged', { status: ownPut.status, aUnchanged: true });

  assert.deepEqual(await listed(a.id), [blobID, largestID].sort()); assert.deepEqual(await listed(b.id), [blobID]);
  assert.equal((await inventory(a.id)).note_assets, 2);
  const { data: rootListing } = await admin.storage.from('note-assets').list('', { limit: 1000 });
  record('Storage holds each account\'s objects in its own folder', { aObjects: 2, bObjects: 1, folders: (rootListing ?? []).filter(e => [a.id, b.id].includes(e.name)).length });

  for (const [label, entry] of [['A', a], ['B', b]]) {
    const deletion = await fetch(`${env.SUPABASE_URL}/functions/v1/account-delete`, { method: 'POST', redirect: 'error',
      headers: { 'content-type': 'application/json', apikey: env.SUPABASE_ANON_KEY, authorization: `Bearer ${entry.token}` },
      body: JSON.stringify({ confirm: 'delete my account' }) });
    const body = await deletion.json();
    assert.equal(deletion.status, 200); assert.deepEqual(body, { deleted: true, complete: true });
    entry.deleted = true;
    const status = await inventory(entry.id);
    assert.deepEqual(await listed(entry.id), [], 'folder listed empty');
    assert.equal(status.note_assets, 0); assert.equal(status.personal_rows, 0); assert.equal(status.login_linked, false);
    const after = await call('GET', blobID, entry.token);
    assert.ok([401, 403].includes(after.status));
    record(`${label} deleted through account-delete`, { status: deletion.status, body, folderObjects: 0, inventoryRows: status.note_assets,
      personalRows: status.personal_rows, oldTokenGet: after.status });
  }
} finally {
  for (const entry of accounts.filter(e => !e.deleted)) {
    // Only these synthetic UUIDs: the same resumable deletion the function runs, then the login.
    const begun = await admin.rpc('worker_delete_account_begin', { p_account_id: entry.id });
    const paths = (begun.data?.objects ?? []).filter(o => o.bucket === 'note-assets').map(o => o.path);
    if (paths.length) await admin.storage.from('note-assets').remove(paths);
    await admin.rpc('worker_delete_account_finish', { p_account_id: entry.id });
    await admin.auth.admin.deleteUser(entry.id);
    evidence.checks.push({ action: 'fallback cleanup', account: 'fixture' });
  }
  const folder = new URL('../.artifacts/note-assets/', import.meta.url); mkdirSync(folder, { recursive: true });
  writeFileSync(new URL(`${evidence.at.replace(/[:.]/g, '-')}.json`, folder), JSON.stringify(evidence, null, 2) + '\n', { mode: 0o600 });
}
console.log('PASS note assets staging check');

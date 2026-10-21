// The note-assets function's request handling (docs/architecture/NOTES_AND_SNIPPETS.md "Implementation contract"),
// with an in-memory database and Storage that behave like migration 095 and the private bucket. The blob is the
// shared encryption vector of tests/fixtures/notes/notes-v1.json.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createCipheriv, createDecipheriv, createHash } from 'node:crypto';
import { handleNoteAsset, NOTE_BLOB_MAX_BYTES, noteAssetHeaders, secondsUntilNextMonth, type NoteAssetDeps } from '../../supabase/functions/_shared/note-assets.ts';
import { PublicError } from '../../supabase/functions/_shared/http.ts';

const fixture = JSON.parse(readFileSync(new URL('../fixtures/notes/notes-v1.json', import.meta.url), 'utf8')).blob as {
  accountID: string; blobID: string; keyHex: string; nonceHex: string; aad: string; plaintextHex: string; blobHex: string; blobSHA256: string };
const blob = new Uint8Array(Buffer.from(fixture.blobHex, 'hex'));
const other = '6a1c9a42-8f3e-4b2d-9c71-1d2e3f405162';
const hex = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const url = (id = fixture.blobID) => `https://fixture.invalid/functions/v1/note-assets/${id}`;

/** Migration 095's behavior in memory: per-account rows, quotas counting pending rows, monthly download metering. */
function backend(options: { objects?: number; downloadBytes?: number; tokens?: Record<string, string>; storage?: Map<string, Uint8Array> } = {}) {
  const rows = new Map<string, { sha: string; bytes: number; state: 'pending' | 'ready'; attempts: number }>();
  const storage = options.storage ?? new Map<string, Uint8Array>();
  const calls: string[] = [], uploads: { path: string; upsert: boolean }[] = [], logs: Record<string, unknown>[] = [];
  const downloaded = new Map<string, number>();
  const tokens = options.tokens ?? { 'token-a': fixture.accountID, 'token-b': other };
  const deps: NoteAssetDeps & { corrupt?: boolean } = {
    account: async request => {
      const account = tokens[(request.headers.get('authorization') ?? '').replace(/^Bearer /, '')];
      if (!account) throw new PublicError(401, 'authentication_required');
      return account;
    },
    rpc: async <T>(name: string, p: Record<string, unknown>) => {
      calls.push(name);
      const key = `${p.p_account_id}/${p.p_blob_id}`;
      if (name === 'worker_consume_request') return null as T;
      if (name === 'worker_note_asset_reserve') {
        const sha = String(p.p_sha256).replace(/^\\x/, ''), bytes = p.p_bytes as number, row = rows.get(key);
        if (row) {
          if (row.sha !== sha || row.bytes !== bytes) throw new Error('note_asset_conflict');
          if (row.state === 'ready') return { state: 'ready', bytes, path: key, retry: false } as T;
          row.attempts++; return { state: 'pending', bytes, path: key, retry: true } as T;
        }
        const owned = [...rows.keys()].filter(k => k.startsWith(`${p.p_account_id}/`)).length;
        if (owned + 1 > (options.objects ?? 4000)) throw new Error('note_asset_quota');
        rows.set(key, { sha, bytes, state: 'pending', attempts: 1 });
        return { state: 'pending', bytes, path: key, retry: false } as T;
      }
      if (name === 'worker_note_asset_confirm') {
        const row = rows.get(key); if (!row) throw new Error('note_asset_unavailable');
        if (row.sha !== String(p.p_sha256).replace(/^\\x/, '')) throw new Error('note_asset_conflict');
        row.state = 'ready'; return { state: 'ready', bytes: row.bytes } as T;
      }
      if (name === 'worker_note_asset_download') {
        const row = rows.get(key);
        if (!row || row.state !== 'ready') throw new Error('note_asset_unavailable');
        const used = (downloaded.get(String(p.p_account_id)) ?? 0) + row.bytes;
        if (used > (options.downloadBytes ?? 512 * 1024 * 1024)) throw new Error('note_transfer_limit');
        downloaded.set(String(p.p_account_id), used);
        return { path: key, bytes: row.bytes, sha256: row.sha } as T;
      }
      throw new Error('unexpected rpc ' + name);
    },
    upload: async (path, bytes, upsert) => {
      calls.push('upload'); uploads.push({ path, upsert });
      if (storage.has(path) && !upsert) throw new Error('storage_upload_failed');
      storage.set(path, deps.corrupt ? new Uint8Array(bytes.length) : new Uint8Array(bytes));
    },
    download: async (path, maximum) => {
      calls.push('download');
      const stored = storage.get(path); if (!stored) throw new Error('storage_download_failed');
      if (stored.length > maximum) throw new Error('storage_object_too_large');
      return new Uint8Array(stored);
    },
    log: entry => logs.push(entry),
  };
  return { deps, rows, storage, calls, uploads, logs, downloaded };
}

const put = (body: BodyInit | null, options: { token?: string; digest?: string | null; id?: string; headers?: Record<string, string> } = {}) =>
  new Request(url(options.id), { method: 'PUT', body, headers: { authorization: `Bearer ${options.token ?? 'token-a'}`,
    ...(options.digest === null ? {} : { 'x-content-sha256': options.digest ?? fixture.blobSHA256 }), ...(options.headers ?? {}) } });
const get = (options: { token?: string; id?: string; headers?: Record<string, string> } = {}) =>
  new Request(url(options.id), { headers: { authorization: `Bearer ${options.token ?? 'token-a'}`, ...(options.headers ?? {}) } });
const headers = noteAssetHeaders({ 'Access-Control-Allow-Origin': 'https://app.gradstep.ai', Vary: 'Origin' });

test('the shared vector is a valid stored blob: nonce ‖ ciphertext ‖ tag under the contract AAD', () => {
  assert.equal(hex(blob), fixture.blobSHA256);
  assert.equal(fixture.aad, `science-reader/snippet-blob/v1\n${fixture.accountID}\n${fixture.blobID}\n`);
  const key = Buffer.from(fixture.keyHex, 'hex'), nonce = blob.subarray(0, 12);
  assert.deepEqual(Buffer.from(nonce).toString('hex'), fixture.nonceHex);
  const decipher = createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAAD(Buffer.from(fixture.aad)); decipher.setAuthTag(blob.subarray(blob.length - 16));
  const plain = Buffer.concat([decipher.update(blob.subarray(12, blob.length - 16)), decipher.final()]);
  assert.equal(plain.toString('hex'), fixture.plaintextHex);
  const cipher = createCipheriv('aes-256-gcm', key, nonce); cipher.setAAD(Buffer.from(fixture.aad));
  const again = Buffer.concat([nonce, cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
  assert.equal(again.toString('hex'), fixture.blobHex);
});

test('PUT reserves, writes once, reads the stored bytes back, then marks ready; GET returns the same bytes', async () => {
  const { deps, calls, uploads, rows, storage, logs } = backend();
  const response = await handleNoteAsset(put(blob), deps, headers);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { state: 'ready', bytes: 36 });
  assert.equal(response.headers.get('cache-control'), 'private, no-store');
  assert.deepEqual(calls, ['worker_consume_request', 'worker_note_asset_reserve', 'upload', 'download', 'worker_note_asset_confirm']);
  assert.deepEqual(uploads, [{ path: `${fixture.accountID}/${fixture.blobID}`, upsert: false }], 'a new object never overwrites');
  assert.equal(rows.get(`${fixture.accountID}/${fixture.blobID}`)!.state, 'ready');
  assert.deepEqual(storage.get(`${fixture.accountID}/${fixture.blobID}`), blob);

  const read = await handleNoteAsset(get(), deps, headers);
  assert.equal(read.status, 200);
  assert.deepEqual(new Uint8Array(await read.arrayBuffer()), blob);
  assert.equal(read.headers.get('content-type'), 'application/octet-stream');
  assert.equal(read.headers.get('content-length'), '36');
  assert.equal(read.headers.get('cache-control'), 'private, no-store');
  assert.equal(read.headers.get('x-content-sha256'), fixture.blobSHA256);
  assert.equal(read.headers.get('access-control-allow-origin'), 'https://app.gradstep.ai');
  // Logs: method, status, byte count and time only — never the account, blob ID or digest.
  const text = JSON.stringify(logs);
  for (const secret of [fixture.accountID, fixture.blobID, fixture.blobSHA256, fixture.blobHex]) assert.ok(!text.includes(secret));
  assert.deepEqual(logs.map(l => [l.method, l.status, l.bytes]), [['PUT', 200, 36], ['GET', 200, 36]]);
});

test('repeating a PUT: a ready object is not written again; a pending one is overwritten with the same bytes', async () => {
  const { deps, calls, uploads } = backend();
  await handleNoteAsset(put(blob), deps, headers);
  calls.length = 0;
  const again = await handleNoteAsset(put(blob), deps, headers);
  assert.equal(again.status, 200); assert.deepEqual(await again.json(), { state: 'ready', bytes: 36 });
  assert.deepEqual(calls, ['worker_consume_request', 'worker_note_asset_reserve'], 'no Storage write or read');

  // A first attempt whose read-back failed leaves the object pending; the client repeats the same PUT.
  const flaky = backend(); flaky.deps.corrupt = true;
  const failed = await handleNoteAsset(put(blob), flaky.deps, headers);
  assert.equal(failed.status, 503); assert.equal((await failed.json()).code, 'not_ready');
  assert.equal(failed.headers.get('retry-after'), '10');
  assert.ok(!flaky.calls.includes('worker_note_asset_confirm'), 'never ready without a verified read-back');
  assert.equal(flaky.rows.get(`${fixture.accountID}/${fixture.blobID}`)!.state, 'pending');
  flaky.deps.corrupt = false;
  const retried = await handleNoteAsset(put(blob), flaky.deps, headers);
  assert.equal(retried.status, 200);
  assert.deepEqual(flaky.uploads.map(u => u.upsert), [false, true], 'upsert only for the same pending object');
  assert.equal(flaky.rows.get(`${fixture.accountID}/${fixture.blobID}`)!.attempts, 2);
  assert.equal(uploads.length, 1);
});

test('a different digest for an existing blob ID is a conflict and writes nothing', async () => {
  const { deps, calls, storage } = backend();
  await handleNoteAsset(put(blob), deps, headers);
  calls.length = 0;
  const changed = new Uint8Array(blob); changed[20] ^= 1;
  const response = await handleNoteAsset(put(changed, { digest: hex(changed) }), deps, headers);
  assert.equal(response.status, 409); assert.deepEqual(await response.json(), { code: 'conflict' });
  assert.ok(!calls.includes('upload'));
  assert.deepEqual(storage.get(`${fixture.accountID}/${fixture.blobID}`), blob);
});

test('the declared digest must match the received bytes, before any reservation', async () => {
  for (const digest of [null, 'abc', 'g'.repeat(64)]) {
    const { deps, calls } = backend();
    const response = await handleNoteAsset(put(blob, { digest }), deps, headers);
    assert.equal(response.status, 400); assert.equal((await response.json()).code, 'digest_required');
    assert.equal(calls.length, 0, 'refused before authentication or any database call');
  }
  const { deps, calls } = backend();
  const response = await handleNoteAsset(put(blob, { digest: '0'.repeat(64) }), deps, headers);
  assert.equal(response.status, 400); assert.equal((await response.json()).code, 'digest_mismatch');
  assert.deepEqual(calls, ['worker_consume_request']);
  // Upper-case hex is the same digest.
  const upper = backend();
  assert.equal((await handleNoteAsset(put(blob, { digest: fixture.blobSHA256.toUpperCase() }), upper.deps, headers)).status, 200);
});

test('over 2 MiB + 28 bytes is refused while receiving: by its declared length or by counting the stream', async () => {
  const declared = backend();
  const big = await handleNoteAsset(put(new Uint8Array(16), { headers: { 'content-length': String(NOTE_BLOB_MAX_BYTES + 1) } }), declared.deps, headers);
  assert.equal(big.status, 413); assert.equal((await big.json()).code, 'too_large');
  assert.ok(!declared.calls.includes('worker_note_asset_reserve'));
  let pulled = 0, cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) { pulled += 65536; controller.enqueue(new Uint8Array(65536)); if (pulled > 8 * 1024 * 1024) controller.close(); },
    cancel() { cancelled = true; },
  });
  const counted = backend();
  const streamed = await handleNoteAsset(new Request(url(), { method: 'PUT', body: stream, duplex: 'half',
    headers: { authorization: 'Bearer token-a', 'x-content-sha256': fixture.blobSHA256 } } as RequestInit), counted.deps, headers);
  assert.equal(streamed.status, 413);
  assert.ok(pulled <= NOTE_BLOB_MAX_BYTES + 65536 * 2, 'stopped reading soon after the bound');
  assert.ok(cancelled);
  assert.ok(!counted.calls.includes('worker_note_asset_reserve'));
  // Exactly the largest blob is accepted; fewer than 28 bytes is not a blob.
  const largest = new Uint8Array(NOTE_BLOB_MAX_BYTES).fill(7), fits = backend();
  assert.equal((await handleNoteAsset(put(largest, { digest: hex(largest) }), fits.deps, headers)).status, 200);
  const tiny = new Uint8Array(27), small = backend();
  const refused = await handleNoteAsset(put(tiny, { digest: hex(tiny) }), small.deps, headers);
  assert.equal(refused.status, 400); assert.equal((await refused.json()).code, 'invalid_blob');
});

test('storage quota is 429 {code:"quota"} with nothing written; it does not suggest waiting', async () => {
  const { deps, calls } = backend({ objects: 1 });
  assert.equal((await handleNoteAsset(put(blob), deps, headers)).status, 200);
  const second = new Uint8Array(blob); second[30] ^= 2;
  const response = await handleNoteAsset(put(second, { id: '7b0e8c1d-2a3f-4c5d-8e6f-7a8b9c0d1e2f', digest: hex(second) }), deps, headers);
  assert.equal(response.status, 429);
  assert.deepEqual(await response.json(), { code: 'quota' });
  assert.equal(response.headers.get('retry-after'), null);
  assert.equal(calls.filter(c => c === 'upload').length, 1);
});

test('GET: another account gets 404 and nothing is read; pending objects are not served', async () => {
  const { deps, calls } = backend();
  await handleNoteAsset(put(blob), deps, headers);
  calls.length = 0;
  const foreign = await handleNoteAsset(get({ token: 'token-b' }), deps, headers);
  assert.equal(foreign.status, 404); assert.deepEqual(await foreign.json(), { code: 'not_found' });
  assert.ok(!calls.includes('download'));
  // B's PUT with the same blob ID is B's own object; it never touches A's.
  const mine = new Uint8Array(blob); mine[25] ^= 4;
  const own = backend({ storage: new Map() });
  assert.equal((await handleNoteAsset(put(mine, { token: 'token-b', digest: hex(mine) }), own.deps, headers)).status, 200);
  assert.deepEqual(own.uploads.map(u => u.path), [`${other}/${fixture.blobID}`]);

  const pending = backend(); pending.deps.corrupt = true;
  await handleNoteAsset(put(blob), pending.deps, headers);
  const notYet = await handleNoteAsset(get(), pending.deps, headers);
  assert.equal(notYet.status, 404);
});

test('GET: the monthly allowance is metered before Storage; once used, 429 until the next UTC month', async () => {
  const { deps, calls } = backend({ downloadBytes: 72 });
  await handleNoteAsset(put(blob), deps, headers);
  calls.length = 0;
  assert.equal((await handleNoteAsset(get(), deps, headers)).status, 200);
  assert.equal((await handleNoteAsset(get(), deps, headers)).status, 200);
  const third = await handleNoteAsset(get(), deps, headers);
  assert.equal(third.status, 429);
  const body = await third.json();
  assert.equal(body.code, 'quota');
  assert.ok(body.retry_after > 0 && body.retry_after <= 31 * 86400);
  assert.equal(third.headers.get('retry-after'), String(body.retry_after));
  assert.equal(calls.filter(c => c === 'download').length, 2, 'the refused download read nothing');
  assert.ok(calls.indexOf('worker_note_asset_download') < calls.indexOf('download'));
  assert.equal(secondsUntilNextMonth(new Date(Date.UTC(2026, 9, 31, 23, 59, 0))), 60);
});

test('GET: a stored object that does not match its inventory is never served', async () => {
  const { deps, storage } = backend();
  await handleNoteAsset(put(blob), deps, headers);
  const tampered = new Uint8Array(blob); tampered[0] ^= 1;
  storage.set(`${fixture.accountID}/${fixture.blobID}`, tampered);
  const response = await handleNoteAsset(get(), deps, headers);
  assert.equal(response.status, 503); assert.equal((await response.json()).code, 'integrity_failed');
  storage.delete(`${fixture.accountID}/${fixture.blobID}`);
  assert.equal((await handleNoteAsset(get(), deps, headers)).status, 503);
});

test('authentication, rate limits, methods, paths and ranges', async () => {
  const anonymous = backend();
  const denied = await handleNoteAsset(put(blob, { token: 'nobody' }), anonymous.deps, headers);
  assert.equal(denied.status, 401); assert.deepEqual(anonymous.calls, []);
  assert.equal((await handleNoteAsset(get({ token: 'nobody' }), anonymous.deps, headers)).status, 401);

  const limited = backend();
  limited.deps.rpc = async () => { throw new Error('request_rate_limit'); };
  const slow = await handleNoteAsset(get(), limited.deps, headers);
  assert.equal(slow.status, 429); assert.deepEqual(await slow.json(), { code: 'rate_limited', retry_after: 60 });

  const closed = backend();
  closed.deps.rpc = async () => { throw new Error('account_unavailable'); };
  assert.equal((await handleNoteAsset(put(blob), closed.deps, headers)).status, 403);

  const down = backend();
  down.deps.rpc = async () => { throw new Error('transport'); };
  assert.equal((await handleNoteAsset(get(), down.deps, headers)).status, 503);

  const { deps, calls } = backend();
  const post = await handleNoteAsset(new Request(url(), { method: 'POST', body: blob }), deps, headers);
  assert.equal(post.status, 405); assert.equal(post.headers.get('allow'), 'GET, PUT, OPTIONS');
  assert.equal((await handleNoteAsset(get({ id: 'not-a-uuid' }), deps, headers)).status, 400);
  assert.equal((await handleNoteAsset(new Request('https://fixture.invalid/functions/v1/note-assets', { headers: { authorization: 'Bearer token-a' } }), deps, headers)).status, 404);
  assert.equal((await handleNoteAsset(new Request(`${url()}/extra`, { headers: { authorization: 'Bearer token-a' } }), deps, headers)).status, 404);
  assert.equal((await handleNoteAsset(get({ headers: { range: 'bytes=0-9' } }), deps, headers)).status, 416);
  assert.deepEqual(calls, [], 'refused before authentication, the database or Storage');
  // The deployed runtime's path has no /functions/v1 prefix; upper-case IDs name the same lower-case object.
  const bare = backend();
  const response = await handleNoteAsset(new Request(`https://fixture.invalid/note-assets/${fixture.blobID.toUpperCase()}`,
    { method: 'PUT', body: blob, headers: { authorization: 'Bearer token-a', 'x-content-sha256': fixture.blobSHA256 } }), bare.deps, headers);
  assert.equal(response.status, 200);
  assert.deepEqual(bare.uploads.map(u => u.path), [`${fixture.accountID}/${fixture.blobID}`]);
});

test('CORS lets the reader send PUT with its digest header and read the digest back', () => {
  assert.match(headers['Access-Control-Allow-Methods'], /\bPUT\b/);
  assert.match(headers['Access-Control-Allow-Headers'], /x-content-sha256/);
  assert.match(headers['Access-Control-Expose-Headers'], /X-Content-SHA256/);
  assert.equal(headers['Cache-Control'], 'private, no-store');
  assert.equal(headers['Access-Control-Allow-Origin'], 'https://app.gradstep.ai');
});

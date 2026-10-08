import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createConnection } from 'node:net';
import { Worker } from 'node:worker_threads';
import { createHash } from 'node:crypto';
import { createVerifierServer, health } from '../server.ts';
import { Capacity, runVerification, productionWorker, MAX_CONCURRENCY } from '../thread-runner.ts';
import { POLICY_ID, MAX_BODY_BYTES, type VerificationRequest } from '../protocol.ts';

const request = (): VerificationRequest => {
  const signed_payload = 'a'.repeat(20) + '.bb.cc';
  return { version: 1, attempt_id: '01000000-0000-0000-0000-000000000001', kind: 'transaction', policy_id: POLICY_ID,
    signed_payload, signed_sha256: createHash('sha256').update(signed_payload).digest('hex') };
};
const env = { STORE_VERIFIER_POLICY_ID: POLICY_ID, STORE_VERIFIER_MAINTENANCE: 'false' };
function fixture(mode: string, capture: Worker[]) {
  return () => {
    const worker = new Worker(new URL('./fixtures/worker.ts', import.meta.url), { workerData: { mode }, stdout: true, stderr: true });
    capture.push(worker); return worker;
  };
}
async function start(options: Parameters<typeof createVerifierServer>[0] = {}) {
  const instance = createVerifierServer({ env, ...options });
  instance.server.listen(0, '127.0.0.1'); await once(instance.server, 'listening');
  return { ...instance, url: `http://127.0.0.1:${(instance.server.address() as { port: number }).port}` };
}
const post = (url: string, value: unknown = request()) => fetch(url + '/verify', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(value) });
const until = async (condition: () => boolean) => {
  for (let i = 0; i < 200 && !condition(); i++) await new Promise(resolve => setTimeout(resolve, 5));
  assert.ok(condition(), 'condition reached before deadline');
};

test('capacity has two slots, idempotent release and no hidden queue', () => {
  const capacity = new Capacity();
  const first = capacity.acquire()!, second = capacity.acquire()!;
  assert.equal(MAX_CONCURRENCY, 2); assert.equal(capacity.acquire(), null);
  first(); first(); assert.equal(capacity.active, 1);
  second(); assert.equal(capacity.active, 0);
});

test('success is joined despite leftover handles; worker exception, exit and CPU timeout also join', async () => {
  for (const mode of ['success', 'throw', 'exit', 'hang']) {
    const workers: Worker[] = [];
    const result: any = await runVerification(request(), new AbortController().signal,
      { factory: fixture(mode, workers), timeoutMS: mode === 'hang' ? 80 : 2_000 });
    assert.equal(result.status, mode === 'success' ? 'verified' : 'failed');
    if (mode === 'hang') assert.equal(result.diagnostic.transport_code, 'timeout');
    assert.equal(workers.length, 1); assert.equal(workers[0].threadId, -1, 'actual thread exit precedes resolution');
  }
});

test('abort before start spawns nothing; in-flight abort terminates and joins CPU work', async () => {
  const workers: Worker[] = [];
  const before = new AbortController(); before.abort();
  await runVerification(request(), before.signal, { factory: fixture('hang', workers) });
  assert.equal(workers.length, 0);
  const during = new AbortController();
  const pending = runVerification(request(), during.signal, { factory: fixture('hang', workers) });
  await once(workers[0], 'online'); during.abort();
  assert.equal((await pending as any).code, 'verification_unavailable');
  assert.equal(workers[0].threadId, -1);
});

test('the fixed production worker rejects malformed cryptographic input and joins without network', async () => {
  const workers: Worker[] = [];
  const signed_payload = Buffer.from('{"alg":"ES256"}').toString('base64url') + '.'
    + Buffer.from('{"environment":"Sandbox"}').toString('base64url') + '.AA';
  const result: any = await runVerification({ ...request(), signed_payload, signed_sha256: createHash('sha256').update(signed_payload).digest('hex') },
    new AbortController().signal, { factory: () => { const worker = productionWorker(); workers.push(worker); return worker; } });
  assert.equal(result.status, 'failed'); assert.equal(result.code, 'invalid');
  assert.equal(workers[0].threadId, -1);
});

test('health is finite, maintenance defaults on, arbitrary revisions and environment toggles never relax policy', async () => {
  const off = health({ APP_STORE_ONLINE_CHECKS: 'false', APP_STORE_BUNDLE_ID: 'other', K_REVISION: 'PRIVATE\nVALUE' });
  assert.equal(off.ready, false); assert.equal(off.maintenance, true); assert.equal(off.revision, null);
  assert.equal(off.runtime.apple_library, '3.1.0'); assert.ok(Object.values(off.runtime.capabilities).every(Boolean));
  assert.equal(health({ ...env, K_REVISION: 'gradstep-store-verifier-00001-abc' }).revision, 'gradstep-store-verifier-00001-abc');
  for (const maintenance of ['False', '', '0', undefined]) assert.equal(health({ ...env, STORE_VERIFIER_MAINTENANCE: maintenance }).ready, false);
  const instance = await start({ env: {} });
  try {
    assert.equal((await (await fetch(instance.url + '/health')).json()).ready, false);
    assert.equal((await post(instance.url)).status, 503);
    assert.equal(instance.capacity.active, 0);
  } finally { await instance.shutdown(); }
});

test('HTTP rejects unsupported, malformed, overlarge and oversized chunked input before executor', async () => {
  let calls = 0;
  const instance = await start({ execute: async () => { calls++; return {}; } });
  try {
    assert.equal((await fetch(instance.url + '/verify')).status, 405);
    assert.equal((await fetch(instance.url + '/other')).status, 404);
    assert.equal((await post(instance.url, { ...request(), root: 'PRIVATE' })).status, 400);
    assert.equal((await post(instance.url, { padding: 'x'.repeat(MAX_BODY_BYTES) })).status, 413);
    assert.equal((await fetch(instance.url + '/verify', { method: 'POST', body: '{}' })).status, 400);
    const chunks = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(MAX_BODY_BYTES)); c.enqueue(new Uint8Array(1)); c.close(); } });
    assert.equal((await fetch(instance.url + '/verify', { method: 'POST', headers: { 'content-type': 'application/json' }, body: chunks, duplex: 'half' } as any)).status, 413);
    assert.equal(calls, 0); assert.equal(instance.capacity.active, 0);
  } finally { await instance.shutdown(); }
});

test('two CPU workers reject overflow; timeout responses release only exited workers', async () => {
  const workers: Worker[] = [];
  const instance = await start({ execute: (input, signal) => runVerification(input, signal, { factory: fixture('hang', workers), timeoutMS: 300 }) });
  try {
    const first = post(instance.url), second = post(instance.url);
    await until(() => workers.length === 2);
    const busy = await post(instance.url);
    assert.equal(busy.status, 503); assert.deepEqual(await busy.json(), { error: 'busy' });
    assert.equal(workers.length, 2, 'no third thread or queued verification');
    const results = await Promise.all([first, second]);
    for (const result of results) assert.equal((await result.json()).diagnostic.transport_code, 'timeout');
    assert.ok(workers.every(worker => worker.threadId === -1)); assert.equal(instance.capacity.active, 0);
  } finally { await instance.shutdown(); }
});

test('client disconnect and service shutdown join workers before freeing capacity', async () => {
  const workers: Worker[] = [];
  const instance = await start({ execute: (input, signal) => runVerification(input, signal, { factory: fixture('hang', workers) }) });
  try {
    const abort = new AbortController();
    const response = fetch(instance.url + '/verify', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(request()), signal: abort.signal });
    const rejected = assert.rejects(response);
    await until(() => workers.length === 1); abort.abort(); await rejected;
    await until(() => instance.capacity.active === 0);
    assert.equal(workers[0].threadId, -1);
    const second = post(instance.url); const stopped = assert.rejects(second);
    await until(() => workers.length === 2);
    await instance.shutdown(); await stopped;
    assert.equal(workers[1].threadId, -1); assert.equal(instance.capacity.active, 0);
  } finally { if (instance.server.listening) await instance.shutdown(); }
});

test('slow body occupies a bounded slot, times out without a worker and closes the socket', async () => {
  let calls = 0;
  const instance = await start({ bodyTimeoutMS: 50, execute: async () => { calls++; return {}; } });
  const socket = createConnection({ host: '127.0.0.1', port: (instance.server.address() as { port: number }).port });
  try {
    await once(socket, 'connect');
    let response = ''; socket.on('data', data => { response += data; });
    const ended = once(socket, 'end');
    socket.write('POST /verify HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{');
    await ended;
    assert.match(response, /^HTTP\/1\.1 408/); assert.equal(calls, 0); assert.equal(instance.capacity.active, 0);
  } finally { socket.destroy(); await instance.shutdown(); }
});

test('body admission consumes the same two slots as verification and releases aborted uploads', async () => {
  let calls = 0;
  const instance = await start({ execute: async () => { calls++; return {}; } });
  const sockets = [0, 1].map(() => createConnection({ host: '127.0.0.1', port: (instance.server.address() as { port: number }).port }));
  try {
    await Promise.all(sockets.map(socket => once(socket, 'connect')));
    for (const socket of sockets) socket.write('POST /verify HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{');
    await until(() => instance.capacity.active === 2);
    const rejected = await post(instance.url);
    assert.equal(rejected.status, 503); assert.deepEqual(await rejected.json(), { error: 'busy' });
    assert.equal(calls, 0);
    for (const socket of sockets) socket.destroy();
    await until(() => instance.capacity.active === 0);
  } finally { for (const socket of sockets) socket.destroy(); await instance.shutdown(); }
});

test('oversized headers and malformed UTF-8 fail before parsing or verification', async () => {
  let calls = 0;
  const instance = await start({ execute: async () => { calls++; return {}; } });
  const socket = createConnection({ host: '127.0.0.1', port: (instance.server.address() as { port: number }).port });
  try {
    await once(socket, 'connect');
    const badUTF8 = await fetch(instance.url + '/verify', { method: 'POST', headers: { 'content-type': 'application/json' }, body: new Uint8Array([123, 34, 255, 34, 58, 49, 125]) });
    assert.equal(badUTF8.status, 400);
    let response = '';
    socket.on('data', data => { response += data; }); const ended = once(socket, 'end');
    socket.write('POST /verify HTTP/1.1\r\nHost: test\r\nX-Large: ' + 'x'.repeat(9000) + '\r\n\r\n');
    await ended;
    assert.match(response, /^HTTP\/1\.1 431/); assert.equal(calls, 0); assert.equal(instance.capacity.active, 0);
  } finally { socket.destroy(); await instance.shutdown(); }
});

test('slow headers are closed by the actual Node header deadline before acquiring capacity', async () => {
  const instance = await start();
  const socket = createConnection({ host: '127.0.0.1', port: (instance.server.address() as { port: number }).port });
  try {
    await once(socket, 'connect'); let response = '';
    socket.on('data', data => { response += data; }); const ended = once(socket, 'end');
    const started = Date.now(); socket.write('POST /verify HTTP/1.1\r\nHost:');
    await ended;
    assert.match(response, /^HTTP\/1\.1 408/);
    assert.ok(Date.now() - started < 5_000, '3s header limit plus500ms inspection interval');
    assert.equal(instance.capacity.active, 0);
  } finally { socket.destroy(); await instance.shutdown(); }
});

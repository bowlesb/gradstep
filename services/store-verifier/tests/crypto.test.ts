import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import { Worker } from 'node:worker_threads';
import { appleVerifier } from '../../../supabase/functions/_shared/app-store.ts';
import { verifyNotificationRecord, verifyTransactionRecord } from '../../../supabase/functions/_shared/store-purchases.ts';
import { createVerifierServer } from '../server.ts';
import { runVerification, productionWorker } from '../thread-runner.ts';
import { POLICY_ID, type VerificationRequest } from '../protocol.ts';
import { testPKI, transaction, notification, BUNDLE, type OCSPTimes } from './fixtures/pki.ts';

async function responder(mode: 'good' | 'revoked' | 'stale' | 'bad_signature' | 'unavailable' | 'malformed' | 'hang' = 'good') {
  let requests = 0; let times: OCSPTimes = {};
  const pending = new Set<import('node:net').Socket>();
  let pki: ReturnType<typeof testPKI>;
  const server = createServer(async (req, res) => {
    requests++;
    assert.equal(req.method, 'POST'); assert.equal(req.headers['content-type'], 'application/ocsp-request');
    const chunks: Buffer[] = []; for await (const chunk of req) chunks.push(chunk as Buffer);
    if (mode === 'hang') return;
    if (mode === 'unavailable') { res.writeHead(503).end('PRIVATE_PROVIDER_ERROR'); return; }
    if (mode === 'malformed') { res.writeHead(200).end('PRIVATE_MALFORMED_OCSP'); return; }
    res.writeHead(200, { 'content-type': 'application/ocsp-response' }).end(pki.ocsp(Buffer.concat(chunks), mode, times));
  });
  server.on('connection', socket => { pending.add(socket); socket.once('close', () => pending.delete(socket)); });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  pki = testPKI(`http://127.0.0.1:${(server.address() as { port: number }).port}/ocsp`);
  return { pki, setTimes: (value: OCSPTimes) => { times = value; }, requests: () => requests, connections: () => pending.size,
    verifier: () => appleVerifier({ bundleID: BUNDLE, environments: ['Sandbox'], onlineChecks: true }, [pki.root]),
    close: async () => { server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); } };
}
const request = (signed_payload: string, kind: VerificationRequest['kind'] = 'transaction'): VerificationRequest => ({ version: 1,
  attempt_id: '0199bcde-0000-7000-8000-000000000001', kind, policy_id: POLICY_ID, signed_payload,
  signed_sha256: createHash('sha256').update(signed_payload).digest('hex') });
const factory = (pki: ReturnType<typeof testPKI>, workers: Worker[]) => () => {
  const worker = new Worker(new URL('./fixtures/crypto-worker.ts', import.meta.url), { workerData: { root: pki.root }, stdout: true, stderr: true });
  workers.push(worker); return worker;
};

test('actual SDK verifies signatures, chain and both signed loopback OCSP responses with online checks enabled', async () => {
  const r = await responder();
  try {
    const signed = r.pki.sign(transaction());
    const record = await verifyTransactionRecord(r.verifier(), signed);
    assert.equal(record.transaction_id, '2000000123456789'); assert.equal(r.requests(), 2);
    const decoded = await verifyNotificationRecord(r.verifier(), r.pki.sign(notification(signed)));
    assert.equal(decoded.transaction?.transaction_id, record.transaction_id);
    assert.equal(r.requests(), 4, 'outer verified online, inner signature checked through SDK with its in-thread certificate cache');
    assert.ok(!JSON.stringify(decoded).includes(signed));
  } finally { await r.close(); }
});

test('online path refuses tampering, wrong app, environment and invalid inner data without relaxing signatures', async () => {
  const r = await responder();
  try {
    await assert.rejects(verifyTransactionRecord(r.verifier(), r.pki.sign(transaction(), true)), { code: 'invalid' });
    await assert.rejects(verifyTransactionRecord(r.verifier(), r.pki.sign(transaction({ bundleId: 'other' }))), { code: 'invalid' });
    const before = r.requests();
    await assert.rejects(verifyTransactionRecord(r.verifier(), r.pki.sign(transaction({ environment: 'Production' }))), { code: 'environment_unavailable' });
    assert.equal(r.requests(), before, 'unaccepted environment fails before network');
    await assert.rejects(verifyNotificationRecord(r.verifier(), r.pki.sign(notification(r.pki.sign(transaction(), true)))), { code: 'invalid' });
  } finally { await r.close(); }
});

test('actual online checks distinguish signed revoked/stale/bad-signature/malformed responses from availability failure', async () => {
  for (const mode of ['revoked', 'stale', 'bad_signature', 'malformed', 'unavailable'] as const) {
    const r = await responder(mode);
    try {
      await assert.rejects(verifyTransactionRecord(r.verifier(), r.pki.sign(transaction())), (error: any) => {
        assert.equal(error.code, mode === 'unavailable' ? 'verification_unavailable' : 'invalid');
        assert.equal(error.diagnostic.stage, 'revocation');
        assert.ok(!JSON.stringify(error.diagnostic).includes('PRIVATE')); return true;
      }, mode);
      assert.ok(r.requests() >= 1 && r.requests() <= 2);
    } finally { await r.close(); }
  }
});

test('HTTP + real worker returns only normalized bound records and notification, joined before response', async () => {
  const r = await responder(); const workers: Worker[] = [];
  const service = createVerifierServer({ env: { STORE_VERIFIER_POLICY_ID: POLICY_ID, STORE_VERIFIER_MAINTENANCE: 'false' },
    execute: (req, signal) => runVerification(req, signal, { factory: factory(r.pki, workers) }) });
  service.server.listen(0, '127.0.0.1'); await once(service.server, 'listening');
  const url = `http://127.0.0.1:${(service.server.address() as { port: number }).port}/verify`;
  try {
    const inner = r.pki.sign(transaction({ storefront: 'USA', currency: 'USD', privateClaim: 'PRIVATE_NOT_RETURNED' }));
    for (const input of [request(inner), request(r.pki.sign(notification(inner)), 'notification')]) {
      const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(input) });
      const text = await response.text(); const body = JSON.parse(text);
      assert.equal(response.status, 200); assert.equal(body.status, 'verified');
      assert.equal(body.attempt_id, input.attempt_id); assert.equal(body.kind, input.kind); assert.equal(body.signed_sha256, input.signed_sha256);
      assert.ok(!text.includes('PRIVATE')); assert.ok(!text.includes(inner)); assert.ok(!text.includes('storefront'));
      assert.ok(workers.every(w => w.threadId === -1)); assert.equal(service.capacity.active, 0);
    }
    const failed = request(r.pki.sign(transaction(), true));
    const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(failed) });
    assert.equal(response.status, 200); assert.equal((await response.json()).code, 'invalid');
    assert.ok(workers.every(w => w.threadId === -1));
  } finally { await service.shutdown(); await r.close(); }
});

test('the production fixed worker cannot use the injected test root or make its untrusted OCSP requests', async () => {
  const r = await responder();
  try {
    const reply: any = await runVerification(request(r.pki.sign(transaction())), new AbortController().signal, { factory: productionWorker });
    assert.equal(reply.code, 'invalid'); assert.equal(reply.diagnostic.stage, 'certificate_chain'); assert.equal(r.requests(), 0);
  } finally { await r.close(); }
});

test('parent deadline terminates pending real SDK OCSP network requests, not only a synthetic promise', async () => {
  const r = await responder('hang'); const workers: Worker[] = [];
  try {
    const started = Date.now();
    const reply: any = await runVerification(request(r.pki.sign(transaction())), new AbortController().signal,
      { factory: factory(r.pki, workers), timeoutMS: 500 });
    assert.equal(reply.code, 'verification_unavailable'); assert.equal(reply.diagnostic.transport_code, 'timeout');
    assert.equal(r.requests(), 2); assert.equal(workers[0].threadId, -1);
    assert.ok(Date.now() - started < 3_000, 'parent deadline does not wait for SDK 30-second network timeout');
    for (let i = 0; r.connections() && i < 50; i++) await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(r.connections(), 0, 'thread exit closes the actual OCSP sockets');
  } finally { await r.close(); }
});


test('signed DER freshness covers exact skew boundaries, all missing fields, future and malformed dates', async () => {
  const r = await responder();
  const originalNow = Date.now;
  const now = Math.floor(originalNow() / 1000) * 1000;
  Date.now = () => now; // Test-only fixed instant; production uses the system clock.
  const at = (seconds: number) => new Date(now + seconds * 1000).toISOString().replace(/[-:]/g, '').replace('T', '').replace(/\.\d{3}/, '');
  const cases: { name: string; times: OCSPTimes; accepted?: boolean }[] = [
    { name: 'ordinary current', times: {}, accepted: true },
    { name: 'exact future skew', times: { thisUpdate: at(60), producedAt: at(60) }, accepted: true },
    { name: 'outside future thisUpdate skew', times: { thisUpdate: at(61), producedAt: at(61) } },
    { name: 'outside producedAt skew', times: { producedAt: at(61) } },
    { name: 'exact expiry skew', times: { thisUpdate: at(-120), nextUpdate: at(-60), producedAt: at(-120) }, accepted: true },
    { name: 'outside expiry skew', times: { thisUpdate: at(-120), nextUpdate: at(-61), producedAt: at(-120) } },
    { name: 'ordered cached stale interval', times: { thisUpdate: at(-7200), producedAt: at(-7200), nextUpdate: at(-3600) } },
    { name: 'inverted interval within otherwise allowed skew', times: { thisUpdate: at(30), nextUpdate: at(10), producedAt: at(30) } },
    { name: 'exact producedAt ordering skew', times: { thisUpdate: at(0), producedAt: at(-60) }, accepted: true },
    { name: 'producedAt too far before thisUpdate', times: { thisUpdate: at(0), producedAt: at(-61) } },
    { name: 'unknown status', times: { status: 'unknown' } },
  ];
  for (const key of ['thisUpdate', 'nextUpdate', 'producedAt'] as const) {
    for (const invalid of [null, '', '20260229000000Z', '20261007240000Z', at(0).slice(0, -1), at(0) + '\n', at(0).slice(0, -1) + '.1Z']) {
      cases.push({ name: key + ' missing/invalid ' + String(invalid), times: { [key]: invalid } });
    }
  }
  try {
    for (const item of cases) {
      r.setTimes(item.times);
      const verifying = verifyTransactionRecord(r.verifier(), r.pki.sign(transaction()));
      if (item.accepted) assert.equal((await verifying).environment, 'Sandbox', item.name);
      else await assert.rejects(verifying, (error: any) => error.code === 'invalid' && error.diagnostic.stage === 'revocation', item.name);
    }
  } finally { Date.now = originalNow; await r.close(); }
});

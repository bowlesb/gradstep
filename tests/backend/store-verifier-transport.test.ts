import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createStoreRecordTransport, privateStorePolicy, storeBoundedOperation, storePrivateJSON,
  storeVerificationAttemptID, type StoreTransportDependencies, type StoreStartInput } from '../../supabase/functions/_shared/store-verifier-transport.ts';
import { StoreVerificationError, syncTransactions, handleNotification } from '../../supabase/functions/_shared/store-purchases.ts';
import { POLICY_ID } from '../../supabase/functions/_shared/store-verifier-protocol.ts';

const stamp = Date.now();
const audience = 'https://gradstep-store-verifier-test-uw.a.run.app';
const account = '33000000-0000-0000-0000-000000000001';
const signed = 'eyJmaXh0dXJlIjp0cnVlfQ.eyJmaXh0dXJlIjp0cnVlfQ.dGVzdA';
const transaction = { environment: 'Sandbox', transaction_id: '123', original_transaction_id: '123',
  product_id: 'com.sciencereader.ios.credits.400', type: 'Consumable', purchase_date: stamp, signed_date: stamp };
const notification = { environment: 'Sandbox', notification_uuid: '33000000-0000-0000-0000-000000000004',
  type: 'DID_RENEW', subtype: null, signed_at: new Date(stamp).toISOString(), transaction };
const json = (body: unknown, status = 200) => Response.json(body, { status });
const failure = (error: unknown) => {
  assert.ok(error instanceof StoreVerificationError);
  assert.equal(error.code, 'verification_unavailable');
  assert.equal(error.message, 'verification_unavailable');
  assert.equal('cause' in error, false);
  return true;
};
function harness(changes: Partial<StoreTransportDependencies> = {}, channel: 'app' | 'notification' = 'app') {
  const starts: StoreStartInput[] = [], finishes: unknown[] = [], requests: Record<string, unknown>[] = [];
  let invalidated = 0;
  const deps: StoreTransportDependencies = {
    now: () => stamp,
    identity: { token: async () => 'test-identity', invalidate() { invalidated++; } },
    async start(input) { starts.push(input); return { granted: true, attempt_id: input.p_attempt_id, policy_id: POLICY_ID }; },
    async finish(input) { finishes.push(input); return true; },
    async fetch(input, init) {
      assert.equal(String(input), audience + '/verify');
      assert.equal(init?.redirect, 'error');
      assert.equal(init?.method, 'POST');
      assert.equal(new Headers(init?.headers).get('authorization'), 'Bearer test-identity');
      const { signed_payload, ...binding } = JSON.parse(String(init?.body));
      assert.equal(signed_payload, signed);
      assert.equal(binding.signed_sha256, createHash('sha256').update(signed).digest('hex'));
      requests.push(binding);
      return json({ ...binding, status: 'verified', ...(channel === 'app' ? { transaction } : { notification }) });
    }, ...changes,
  };
  return { starts, finishes, requests, invalidated: () => invalidated,
    transport: createStoreRecordTransport({ audience, channel, accountID: channel === 'app' ? account : null,
      deadline: stamp + 115_000 }, deps) };
}

test('fresh attempt IDs encode time, version and variant; private policy cannot relax checks or environment', () => {
  const values = new Set(Array.from({ length: 100 }, () => storeVerificationAttemptID(stamp)));
  assert.equal(values.size, 100);
  for (const id of values) {
    assert.match(id, /^[a-f0-9]{8}-[a-f0-9]{4}-7[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/);
    assert.equal(parseInt(id.replaceAll('-', '').slice(0, 12), 16), stamp);
  }
  for (const date of [NaN, Infinity, -1, stamp + .1, 0x1000000000000]) assert.throws(() => storeVerificationAttemptID(date), failure);
  const good = { environments: ['Sandbox' as const], bundleID: 'com.sciencereader.ios', onlineChecks: true };
  assert.equal(privateStorePolicy(good), true);
  for (const value of [null, { ...good, onlineChecks: false }, { ...good, bundleID: 'another' },
    { ...good, environments: ['Production' as const] }, { ...good, environments: [] }, { ...good, environments: ['Sandbox' as const, 'Sandbox' as const] }]) {
    assert.equal(privateStorePolicy(value), false);
  }
});

test('a verified transaction follows one admitted send and financial recording remains once-only downstream', async () => {
  const h = harness();
  let grants = 0;
  const recorded = new Set<string>();
  const deps = { recordVerifier: h.transport, async recordTransaction(id: string, value: typeof transaction) {
    assert.equal(id, account); assert.deepEqual(value, transaction);
    if (recorded.has(value.transaction_id)) return { outcome: 'already_recorded' };
    recorded.add(value.transaction_id); grants++;
    return { outcome: 'recorded', credits: 400 };
  }, recordNotification: async () => { throw new Error('unused'); } };
  const first = await syncTransactions(deps, account, { transactions: [signed] });
  const retry = await syncTransactions(deps, account, { transactions: [signed] });
  assert.deepEqual(first, [{ transaction_id: '123', outcome: 'recorded', credits: 400 }]);
  assert.deepEqual(retry, [{ transaction_id: '123', outcome: 'already_recorded' }]);
  assert.equal(grants, 1);
  assert.equal(h.starts.length, 2); assert.equal(h.requests.length, 2); assert.equal(h.finishes.length, 2);
  assert.notEqual(h.starts[0].p_attempt_id, h.starts[1].p_attempt_id);
});

test('outer plus inner notification consumes one anonymous admission; no account is invented', async () => {
  const h = harness({}, 'notification');
  let recorded = 0;
  const result = await handleNotification({ recordVerifier: h.transport,
    recordTransaction: async () => { throw new Error('unused'); }, async recordNotification(value) {
      assert.deepEqual(value, notification); recorded++; return { outcome: 'recorded' };
    } }, { signedPayload: signed });
  assert.deepEqual(result, { status: 200, outcome: 'recorded' });
  assert.equal(recorded, 1); assert.equal(h.requests.length, 1);
  assert.equal(h.starts[0].p_account_id, null); assert.equal(h.starts[0].p_channel, 'notification');
});

test('no send on denied, malformed or lost admission acknowledgment; later batch entries are deferred', async () => {
  for (const answer of [{ granted: false, reason: 'channel_limit' }, { granted: true },
    { granted: true, attempt_id: 'another', policy_id: POLICY_ID }, new Error('PRIVATE_DATABASE_BODY')]) {
    let admissions = 0, sends = 0, identities = 0;
    const h = harness({ async start() { admissions++; if (answer instanceof Error) throw answer; return answer; },
      identity: { token: async () => { identities++; return 'test'; }, invalidate() {} },
      fetch: async () => { sends++; throw new Error('must not send'); } });
    await assert.rejects(h.transport.transaction(signed), failure);
    await assert.rejects(h.transport.transaction(signed), failure);
    assert.equal(admissions, 1); assert.equal(sends, 0); assert.equal(identities, 0); assert.deepEqual(h.finishes, []);
  }
});

test('bounded lost RPC cannot attach a later continuation or resend after its deadline', async () => {
  let release!: (value: string) => void;
  let sawAbort = false, continuation = 0;
  const operation = storeBoundedOperation(signal => {
    signal.addEventListener('abort', () => { sawAbort = true; });
    return new Promise<string>(resolve => { release = resolve; });
  }, 5).then(() => { continuation++; });
  await assert.rejects(operation, failure);
  release('late committed grant');
  await new Promise(resolve => setTimeout(resolve, 1));
  assert.equal(sawAbort, true); assert.equal(continuation, 0);
  const cancelled = new AbortController(); cancelled.abort();
  await assert.rejects(storeBoundedOperation(async () => { continuation++; return ''; }, 50, cancelled.signal), failure);
  assert.equal(continuation, 0);
});

test('response bindings, schema and HTTP semantics are mandatory before any record reaches SQL', async () => {
  const mutations = [
    (r: any) => ({ ...r, attempt_id: 'another' }), (r: any) => ({ ...r, signed_sha256: 'a'.repeat(64) }),
    (r: any) => ({ ...r, kind: 'notification' }), (r: any) => ({ ...r, policy_id: 'other' }),
    (r: any) => ({ ...r, account_token: 'PRIVATE' }), (r: any) => ({ ...r, transaction: { ...transaction, signed_payload: signed } }),
    (r: any) => ({ ...r, transaction: { ...transaction, environment: 'Production' } }),
  ];
  for (const mutate of mutations) {
    let sends = 0;
    const h = harness({ fetch: async (_input, init) => {
      sends++; const { signed_payload: _signed, ...binding } = JSON.parse(String(init?.body));
      return json(mutate({ ...binding, status: 'verified', transaction }));
    } });
    await assert.rejects(h.transport.transaction(signed), failure);
    assert.equal(sends, 1); assert.equal(h.starts.length, 1);
    assert.equal((h.finishes[0] as any).p_outcome, 'verification_unavailable');
  }
  const statusMismatch = harness({ fetch: async (_input, init) => {
    const { signed_payload: _signed, ...binding } = JSON.parse(String(init?.body));
    return json({ ...binding, status: 'verified', transaction }, 503);
  } });
  await assert.rejects(statusMismatch.transport.transaction(signed), failure);
});

test('private HTTP errors/redirects/oversized streams never retry; IAM rejection only invalidates the next identity', async () => {
  for (const response of [() => json({ error: 'busy' }, 503), () => new Response('', { status: 302 }),
    () => new Response('PRIVATE', { status: 500 }), () => new Response('x'.repeat(72 * 1024 + 1), { headers: { 'content-type': 'application/json' } }),
    () => new Response('{}', { headers: { 'content-type': 'application/json', 'content-length': '73729' } }),
    () => new Response('not json', { headers: { 'content-type': 'application/json' } }),
    () => new Response('IAM denied', { status: 403 }), () => { throw new Error('PRIVATE_TOKEN'); }]) {
    let sends = 0;
    const h = harness({ fetch: async () => { sends++; return response(); } });
    await assert.rejects(h.transport.transaction(signed), failure);
    assert.equal(sends, 1); assert.equal(h.finishes.length, 1);
  }
  const iam = harness({ fetch: async () => new Response('', { status: 401 }) });
  await assert.rejects(iam.transport.transaction(signed), failure);
  assert.equal(iam.invalidated(), 1);
});

test('a private response body that stalls is cancelled within its bound', async () => {
  let cancelled = 0;
  await assert.rejects(storePrivateJSON(audience, '/health', 'identity', { timeout: 5, maximum: 100,
    fetch: async () => new Response(new ReadableStream({ cancel() { cancelled++; } }), { headers: { 'content-type': 'application/json' } }) }), failure);
  assert.equal(cancelled, 1);
});

test('finite verifier refusals preserve their outcomes; observation failure cannot undo a verified result', async () => {
  const invalid = harness({ fetch: async (_input, init) => {
    const { signed_payload: _signed, ...binding } = JSON.parse(String(init?.body));
    return json({ ...binding, status: 'failed', code: 'invalid', diagnostic: { stage: 'revocation', apple_status: 'failure' } });
  } });
  await assert.rejects(invalid.transport.transaction(signed), (error: any) => error.code === 'invalid' && error.diagnostic.stage === 'revocation');
  assert.equal((invalid.finishes[0] as any).p_outcome, 'invalid');
  let missed = 0;
  const good = harness({ finish: async () => { throw new Error('PRIVATE_DB_RESPONSE'); }, observationUnavailable() { missed++; } });
  assert.deepEqual(await good.transport.transaction(signed), transaction);
  assert.equal(missed, 1);
});

test('batch deadline keeps earlier final results and defers the rest without fan-out or new admissions', async () => {
  let now = stamp;
  const h = harness({ now: () => now, finish: async () => { now += 60_000; return true; } });
  const result = await syncTransactions({ recordVerifier: h.transport,
    recordTransaction: async () => ({ outcome: 'recorded', credits: 400 }), recordNotification: async () => { throw new Error('unused'); },
  }, account, { transactions: Array(25).fill(signed) });
  assert.equal(result.length, 25);
  assert.deepEqual(result[0], { transaction_id: '123', outcome: 'recorded', credits: 400 });
  assert.ok(result.slice(1).every(value => value.outcome === 'verification_unavailable'));
  assert.equal(h.starts.length, 1); assert.equal(h.requests.length, 1);
});

test('malformed payloads are rejected before any admission, auth exchange or paid service work', async () => {
  const h = harness();
  for (const payload of ['', 'a.b.c', signed + 'é', signed + '=', signed + '.extra', signed + '\n', signed + '\u2028', 'x'.repeat(64_001)]) {
    await assert.rejects(h.transport.transaction(payload), (error: any) => error.code === 'invalid' && error.diagnostic.stage === 'input');
  }
  assert.equal(h.starts.length, 0); assert.equal(h.requests.length, 0);
});

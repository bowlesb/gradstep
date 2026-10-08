import test from 'node:test';
import assert from 'node:assert/strict';
import { createStoreVerifierHealthHandler, isStoreVerifierHealth, STORE_SDK_SOURCE_SHA256, STORE_SDK_PATCHED_SHA256 } from '../../supabase/functions/_shared/store-verifier-health.ts';

const secret = 'synthetic-operator-credential-for-local-fixtures';
const probe = '33000000-0000-4000-8000-000000000033';
const audience = 'https://gradstep-store-verifier-test-uw.a.run.app';
const fixture = () => ({ version: 1, ok: true, policy_id: 'app-store-sandbox-v1', policy_valid: true,
  maintenance: true, ready: false, revision: 'gradstep-store-verifier-00001-fixture',
  runtime: { node: '24.18.0', apple_library: '3.1.0', capabilities: { certificate_parse: true, certificate_string: true,
    certificate_raw: true, public_key_export: true, certificate_verify: true, certificate_info_access: true },
  ocsp_freshness: { policy: 'strict-utc-v1', applied: true, source_sha256: STORE_SDK_SOURCE_SHA256, patched_sha256: STORE_SDK_PATCHED_SHA256 } } });
const request = (headers: Record<string, string> = {}, options: RequestInit = {}, query = '') => new Request('https://example.supabase.co/functions/v1/store-verifier-health' + query,
  { ...options, headers: { authorization: 'Bearer ' + secret, 'x-verifier-probe-id': probe, ...headers } });

test('operator health cannot be used with a user, anon or absent token, wrong method, body or malformed probe', async () => {
  let identities = 0, sends = 0;
  const handler = createStoreVerifierHealthHandler(name => name === 'SUPABASE_SERVICE_ROLE_KEY' ? secret : undefined, {
    connection() { identities++; throw new Error('must not create identity'); },
    fetch: async () => { sends++; throw new Error('must not send'); },
  });
  for (const [input, status] of [
    [request({ authorization: '' }), 401], [request({ authorization: 'Bearer user-jwt' }), 401],
    [request({ authorization: 'Bearer ' + secret.slice(0, -1) + 'x' }), 401],
    [request({}, { method: 'POST', body: 'a receipt must not reach here' }), 405],
    [request({ 'content-length': '1' }), 400], [request({ 'transfer-encoding': 'chunked' }), 400],
    [request({ 'x-verifier-probe-id': 'not-an-id' }), 400], [request({}, {}, '?url=https://elsewhere.example'), 400],
  ] as const) {
    const result = await handler(input); assert.equal(result.status, status);
    assert.equal(result.headers.get('cache-control'), 'no-store');
  }
  assert.equal(identities, 0); assert.equal(sends, 0);
});

test('authorized probe uses fixed GET health path, echoes the nonce, and reports exact finite Node evidence', async () => {
  let sends = 0, connections = 0;
  const observed = '2026-10-08T02:00:00.000Z';
  const handler = createStoreVerifierHealthHandler(() => secret, {
    now: () => Date.parse(observed),
    connection() { connections++; return { audience, identity: { token: async () => 'test-identity', invalidate() {} } }; },
    fetch: async (input, init) => {
      sends++; assert.equal(String(input), audience + '/health'); assert.equal(init?.method, 'GET');
      assert.equal(init?.body, undefined); assert.equal(init?.redirect, 'error');
      assert.equal(new Headers(init?.headers).get('authorization'), 'Bearer test-identity');
      return Response.json(fixture());
    },
  });
  const result = await handler(request());
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { version: 1, probe_id: probe, observed_at: observed, health: fixture() });
  assert.equal(connections, 1); assert.equal(sends, 1);
});

test('extra fields, unknown SDK patch, malformed revision or inconsistent readiness cannot become activation evidence', async () => {
  const mutations = [
    (v: any) => ({ ...v, debug: 'PRIVATE' }), (v: any) => ({ ...v, version: 2 }),
    (v: any) => ({ ...v, revision: 'another-service-00001' }), (v: any) => ({ ...v, ready: true }),
    (v: any) => ({ ...v, runtime: { ...v.runtime, node: 'unknown' } }),
    (v: any) => ({ ...v, runtime: { ...v.runtime, ocsp_freshness: { ...v.runtime.ocsp_freshness, patched_sha256: 'a'.repeat(64) } } }),
    (v: any) => ({ ...v, runtime: { ...v.runtime, capabilities: { ...v.runtime.capabilities, certificate_verify: 'true' } } }),
  ];
  for (const mutate of mutations) {
    const value = mutate(fixture()); assert.equal(isStoreVerifierHealth(value), false);
    const handler = createStoreVerifierHealthHandler(() => secret, { connection: () => ({ audience,
      identity: { token: async () => 'identity', invalidate() {} } }), fetch: async () => Response.json(value) });
    const result = await handler(request());
    assert.equal(result.status, 503); assert.deepEqual(await result.json(), { code: 'service_unavailable' });
  }
  const active = { ...fixture(), maintenance: false, ready: true };
  assert.equal(isStoreVerifierHealth(active), true);
  assert.equal(isStoreVerifierHealth({ ...active, runtime: { ...active.runtime,
    ocsp_freshness: { ...active.runtime.ocsp_freshness, applied: false } } }), false);
});

test('IAM refusal discards the cached identity but never retries this probe', async () => {
  let invalidations = 0, sends = 0;
  const handler = createStoreVerifierHealthHandler(() => secret, { connection: () => ({ audience,
    identity: { token: async () => 'identity', invalidate() { invalidations++; } } }), fetch: async () => {
      sends++; return new Response('PRIVATE_IAM_BODY', { status: 403 });
    } });
  const response = await handler(request());
  assert.equal(response.status, 503); assert.equal(sends, 1); assert.equal(invalidations, 1);
  assert.equal(await response.text(), '{"code":"service_unavailable"}');
});

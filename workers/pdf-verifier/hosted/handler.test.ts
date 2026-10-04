import assert from 'node:assert/strict';
import { createProbeHandler, type ProbeConfig, type ProbeDependencies } from './handler.ts';

const runID = '11111111-1111-4111-8111-111111111111';
const userID = '22222222-2222-4222-8222-222222222222';
const createdAt = 1_791_065_000_000;
const config: ProbeConfig = { project: 'coxhjvqpflgxkleydati', runID, userID, createdAt,
  expiresAt: createdAt + 1_200_000, buildSHA256: 'a'.repeat(64), path: '/pdf-verifier-probe-11111111' };
function fixture() {
  let now = createdAt, initialized = 0, verified = 0, authenticated = 0;
  const logs: Record<string, unknown>[] = [];
  const deps: ProbeDependencies = {
    async authenticate() { authenticated += 1; return { id: userID, app_metadata: { science_reader_check: 'pdf-verifier-probe', check_run_id: runID } }; },
    async initialize() {
      initialized += 1;
      return { coldLoadMS: 12, async verify() {
        verified += 1;
        return { outcome: 'verified' as const, pages: 1, bytes: 300, sha256: 'b'.repeat(64),
          profileID: 'qpdf-wasm-pilot-v1', profileSHA256: 'c'.repeat(64), wasmSHA256: 'd'.repeat(64), elapsedMS: 4 };
      } };
    },
    now: () => now, runtime: { deno: 'fixture', v8: 'fixture', typescript: 'fixture' },
    deploymentID: 'fixture-deployment', executionID: 'fixture-execution', isolateID: '33333333-3333-4333-8333-333333333333',
    memory: () => ({ rss: 80_000_000, heapTotal: 1, heapUsed: 1, external: 67_108_864 }),
    log: event => logs.push(event),
  };
  return { deps, logs, counts: () => ({ initialized, verified, authenticated }), setTime: (value: number) => { now = value; } };
}
function request(body: unknown = { run_id: runID, fixture: 'pages-1' }, authorized = true) {
  return new Request('https://example.invalid/functions/v1' + config.path, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(authorized ? { Authorization: 'Bearer fixture-token-is-never-a-live-credential' } : {}) }, body: JSON.stringify(body) });
}

Deno.test('probe requires authenticated server-owned identity before compilation', async () => {
  const f = fixture();
  const handler = createProbeHandler(config, f.deps);
  assert.equal((await handler(request(undefined, false))).status, 401);
  assert.deepEqual(f.counts(), { initialized: 0, verified: 0, authenticated: 0 });
  for (const user of [null, { id: userID }, { id: userID, app_metadata: { science_reader_check: 'pdf-verifier-probe', check_run_id: 'wrong' } },
    { id: userID, user_metadata: { science_reader_check: 'pdf-verifier-probe', check_run_id: runID } }]) {
    const denied = createProbeHandler(config, { ...f.deps, authenticate: async () => user });
    assert.equal((await denied(request())).status, 403);
  }
  assert.equal(f.counts().initialized, 0);
});

Deno.test('probe refuses arbitrary inputs, routes and oversized bodies before auth', async () => {
  const f = fixture(), handler = createProbeHandler(config, f.deps);
  for (const body of [{ run_id: runID, fixture: 'remote.pdf' }, { run_id: runID, fixture: 'pages-1', url: 'https://elsewhere.invalid' },
    { run_id: 'wrong', fixture: 'pages-1' }, { run_id: runID, fixture: 'x'.repeat(600) }]) assert.equal((await handler(request(body))).status, 400);
  assert.equal((await handler(new Request('https://example.invalid' + config.path))).status, 404);
  const wrong = new Request(request(), { method: 'POST' });
  assert.equal((await handler(new Request(wrong.url + '?query=x', wrong))).status, 404);
  assert.deepEqual(f.counts(), { initialized: 0, verified: 0, authenticated: 0 });
});

Deno.test('expiry is checked again after authorization', async () => {
  const f = fixture(), auth = f.deps.authenticate;
  f.deps.authenticate = async (token, signal) => { const user = await auth(token, signal); f.setTime(config.expiresAt); return user; };
  const handler = createProbeHandler(config, f.deps);
  assert.equal((await handler(request())).status, 410);
  assert.equal(f.counts().initialized, 0);
});

Deno.test('an unclosed valid JSON prefix cannot turn timeout cancellation into EOF', async () => {
  const f = fixture(), handler = createProbeHandler(config, f.deps);
  const body = new ReadableStream<Uint8Array>({ start(controller) {
    controller.enqueue(new TextEncoder().encode(JSON.stringify({ run_id: runID, fixture: 'pages-1' })));
    // Intentionally never close: a cancelled read can report done:true.
  } });
  const value = request();
  const response = await handler(new Request(value.url, { method: 'POST', headers: value.headers, body }));
  assert.equal(response.status, 400);
  assert.deepEqual(f.counts(), { initialized: 0, verified: 0, authenticated: 0 });
});

Deno.test('truncated declared body and request cancellation stay outside authentication', async () => {
  const f = fixture(), handler = createProbeHandler(config, f.deps);
  const truncated = request(); truncated.headers.set('Content-Length', '500');
  assert.equal((await handler(truncated)).status, 400);
  const controller = new AbortController(); controller.abort();
  assert.equal((await handler(new Request(request(), { signal: controller.signal }))).status, 400);
  assert.deepEqual(f.counts(), { initialized: 0, verified: 0, authenticated: 0 });
});

Deno.test('compiled code is reused but every authorized fixture is measured separately', async () => {
  const f = fixture(), handler = createProbeHandler(config, f.deps);
  const first = await (await handler(request())).json(), second = await (await handler(request())).json();
  assert.equal(first.cold, true); assert.equal(second.cold, false);
  assert.equal(first.initialization_wall_ms, 12); assert.equal(second.initialization_wall_ms, 0);
  assert.equal(first.ordinal, 1); assert.equal(second.ordinal, 2);
  assert.equal(first.cpu_ms, null); assert.equal(first.peak_memory_bytes, null); assert.equal(first.hosted_admitted, false);
  assert.deepEqual(f.counts(), { initialized: 1, verified: 2, authenticated: 2 });
  assert.equal(JSON.stringify(f.logs).includes('fixture-token'), false);
});

Deno.test('one isolate does not overlap parser initialization or execution', async () => {
  const f = fixture(), initialize = f.deps.initialize;
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  let started!: () => void;
  const initializing = new Promise<void>(resolve => { started = resolve; });
  f.deps.initialize = async () => { started(); await pending; return initialize(); };
  const handler = createProbeHandler(config, f.deps);
  const first = handler(request()); await initializing;
  assert.equal((await handler(request())).status, 429);
  release(); assert.equal((await first).status, 200);
  assert.equal(f.counts().verified, 1);
});

Deno.test('local invocation cap is enforced without claiming a global quota', async () => {
  const f = fixture(), handler = createProbeHandler(config, f.deps);
  for (let i = 0; i < 40; i++) assert.equal((await handler(request())).status, 200);
  assert.equal((await handler(request())).status, 429);
  assert.equal(f.counts().verified, 40);
});

Deno.test('cancellation during compilation does not start a fresh parser instance', async () => {
  const f = fixture(), initialize = f.deps.initialize;
  let release!: () => void, started!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  const initializing = new Promise<void>(resolve => { started = resolve; });
  f.deps.initialize = async () => { started(); await pending; return initialize(); };
  const handler = createProbeHandler(config, f.deps), controller = new AbortController();
  const first = handler(new Request(request(), { signal: controller.signal }));
  await initializing; controller.abort(); release();
  assert.equal((await first).status, 408);
  assert.equal(f.counts().verified, 0);
});

Deno.test('initialization failures never disclose dependency diagnostics or claim success', async () => {
  const f = fixture();
  f.deps.initialize = () => Promise.reject(new Error('private provider token and document content'));
  const handler = createProbeHandler(config, f.deps), response = await handler(request());
  assert.equal(response.status, 500);
  assert.equal((await response.text()).includes('private'), false);
  assert.equal(JSON.stringify(f.logs).includes('private'), false);
  assert.equal(f.counts().verified, 0);
});

Deno.test('configuration is copied and cannot expand the authorized time or project', async () => {
  const f = fixture(), mutable = { ...config };
  const handler = createProbeHandler(mutable, f.deps);
  mutable.expiresAt += 9999999;
  f.setTime(config.expiresAt);
  assert.equal((await handler(request())).status, 410);
  for (const bad of [{ ...config, project: 'different-project' }, { ...config, expiresAt: config.expiresAt + 1 },
    { ...config, path: '/some-other-function' }]) assert.throws(() => createProbeHandler(bad, f.deps), /invalid_probe_config/);
});

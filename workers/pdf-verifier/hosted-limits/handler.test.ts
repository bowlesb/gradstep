import assert from 'node:assert/strict';
import { BUILD, CASES, createHandler, RUNTIME, SOURCE_HEADER, type Config, type Dependencies, type Event, type WorkCase } from './handler.ts';
import { createAuthenticate } from './auth.ts';

const RUN = '10000000-0000-4000-8000-000000000001', USER = '20000000-0000-4000-8000-000000000001';
const FUNCTION = '30000000-0000-4000-8000-000000000001', SOURCE = 'a'.repeat(64), FIXTURE = 'b'.repeat(64);
const DEPLOYMENT = `coxhjvqpflgxkleydati_${FUNCTION}_1`, CREATED = 1_790_000_000_000;
const ids = CASES.map((_, index) => `40000000-0000-4000-8000-${String(index).padStart(12, '0')}`);
const config = (): Config => ({ project: 'coxhjvqpflgxkleydati', runID: RUN, userID: USER,
  createdAt: CREATED, expiresAt: CREATED + 1_200_000, path: '/pdf-verifier-probe-' + RUN.slice(0, 8),
  buildSHA256: BUILD, requests: CASES.map((name, index) => ({ case: name, attemptID: ids[index] })) });
function fixture(overrides: Partial<Dependencies> = {}) {
  const events: Event[] = [], tasks: Promise<void>[] = [];
  const state = { time: 0, calls: 0, auth: 0, sleeps: 0, recovered: 0 };
  const user = { id: USER, app_metadata: { science_reader_check: 'pdf-verifier-probe', check_run_id: RUN,
    probe_kind: 'hosted-limits-v1', source_manifest_sha256: SOURCE, deployment_id: DEPLOYMENT } };
  const deps: Dependencies = {
    async authenticate() { state.auth++; return user; },
    async synthetic() { state.calls++; return { chunk_iterations: () => 262_144,
      cpu_chunk(seed) { state.time += 1000; return seed + 1; },
      memory: { buffer: new ArrayBuffer(0), grow() { throw new RangeError('sentinel-secret'); } } }; },
    async recover() { state.recovered++; return { outcome: 'verified', pages: 1, sha256: FIXTURE }; },
    fixtureSHA256: FIXTURE, now: () => CREATED + state.time, monotonic: () => state.time,
    async sleep(ms) { state.sleeps++; state.time += ms; }, waitUntil(task) { tasks.push(task); },
    runtimeVersion: RUNTIME, deploymentID: DEPLOYMENT,
    executionID: '50000000-0000-4000-8000-000000000001', isolateID: '60000000-0000-4000-8000-000000000001',
    log(event) { events.push(event); }, ...overrides,
  };
  const handler = createHandler(config(), deps);
  return { handler, state, deps, user, events, tasks };
}
function request(name: string = 'control', overrides: { token?: boolean; source?: string; body?: string; signal?: AbortSignal; path?: string } = {}) {
  const index = CASES.indexOf(name as typeof CASES[number]);
  const headers: Record<string, string> = { 'content-type': 'application/json', [SOURCE_HEADER]: overrides.source ?? SOURCE };
  if (overrides.token !== false) headers.authorization = 'Bearer ' + 'x'.repeat(32);
  return new Request('https://example.invalid' + (overrides.path ?? config().path), { method: 'POST', headers,
    body: overrides.body ?? JSON.stringify({ run_id: RUN, attempt_id: ids[index >= 0 ? index : 2], case: name }), signal: overrides.signal });
}

Deno.test('three fixed denials do no authentication, compilation, allocation or recovery', async () => {
  const f = fixture();
  assert.equal((await f.handler.fetch(request('deny_missing_auth', { token: false }))).status, 401);
  assert.equal((await f.handler.fetch(request('deny_wrong_run', { body: JSON.stringify({ run_id: USER, attempt_id: ids[1], case: 'deny_wrong_run' }) }))).status, 403);
  assert.equal((await f.handler.fetch(request('invalid-case'))).status, 400);
  assert.equal(f.state.calls + f.state.recovered + f.state.auth, 0); assert.equal(f.events.length, 0);
});
Deno.test('control binds observed runtime, source and deployment to finite start/complete', async () => {
  const f = fixture(), response = await f.handler.fetch(request());
  assert.equal(response.status, 200); const value = await response.json();
  assert.equal(value.source_sha256, SOURCE); assert.equal(value.runtime_version, RUNTIME);
  assert.equal(value.hosted_admitted, false); assert.equal(value.cpu_ms, null); assert.equal(value.peak_memory_bytes, null);
  assert.deepEqual(f.events.map(e => [e.event, e.sequence, e.pages]), [['start', 0, null], ['complete', 1, null]]);
  f.handler.beforeUnload(); assert.equal(f.events.length, 2);
  assert.equal(f.state.calls + f.state.recovered, 0);
});
Deno.test('exact attempt binding and per-isolate replay prevention', async () => {
  const f = fixture();
  assert.equal((await f.handler.fetch(request('control', { body: JSON.stringify({ run_id: RUN, attempt_id: ids[4], case: 'control' }) }))).status, 403);
  assert.equal((await f.handler.fetch(request())).status, 200);
  assert.equal((await f.handler.fetch(request())).status, 409);
  assert.equal(f.events.length, 2);
});
Deno.test('source marker, kind, deployment and user must all match before work', async () => {
  for (const key of ['science_reader_check', 'check_run_id', 'probe_kind', 'source_manifest_sha256', 'deployment_id']) {
    const f = fixture(); (f.user.app_metadata as Record<string, string>)[key] = 'wrong';
    assert.equal((await f.handler.fetch(request('cpu-wasm'))).status, 403);
    assert.equal(f.state.calls, 0); assert.equal(f.events.length, 0);
  }
  const f = fixture(); f.user.id = RUN;
  assert.equal((await f.handler.fetch(request())).status, 403);
  assert.equal((await fixture().handler.fetch(request('cpu-wasm', { source: 'c'.repeat(64) }))).status, 403);
});
Deno.test('observed runtime and actual deployment mismatch fail closed', async () => {
  for (const override of [{ runtimeVersion: '2.1.4' }, { deploymentID: DEPLOYMENT.slice(0, -1) + '2' }, { executionID: null }]) {
    const f = fixture(override); assert.equal((await f.handler.fetch(request('cpu-wasm'))).status, 503);
    assert.equal(f.state.auth + f.state.calls, 0);
  }
});
Deno.test('body must be bounded flat JSON with distinct known keys', async () => {
  for (const raw of [
    JSON.stringify({ run_id: RUN, attempt_id: ids[3], case: 'control', bytes: 'secret' }),
    `{"run_id":"${RUN}","attempt_id":"${ids[3]}","case":"control","case":"cpu-wasm"}`,
    '{"run_id":null}', ' '.repeat(513),
  ]) {
    const f = fixture(); assert.equal((await f.handler.fetch(request('control', { body: raw }))).status, 400);
    assert.equal(f.state.auth + f.state.calls, 0);
  }
});
Deno.test('route/query and expiry guards precede workload', async () => {
  const f = fixture();
  assert.equal((await f.handler.fetch(request('control', { path: config().path + '?x=1' }))).status, 404);
  f.state.time = 1_020_000;
  assert.equal((await f.handler.fetch(request())).status, 410);
  const g = fixture(); g.state.time = 650_000;
  assert.equal((await g.handler.fetch(request('background'))).status, 410);
  assert.equal(g.tasks.length, 0);
});
Deno.test('authorization delay cannot extend expiry', async () => {
  const f = fixture({ async authenticate() { f.state.time = 1_020_000; return f.user; } });
  assert.equal((await f.handler.fetch(request('cpu-wasm'))).status, 410);
  assert.equal(f.state.calls, 0);
});
Deno.test('finite CPU fallback reports work, never CPU measurement or host stop', async () => {
  const f = fixture(); const response = await f.handler.fetch(request('cpu-wasm')); const value = await response.json();
  assert.equal(response.status, 200); assert.equal(value.result, 'fallback'); assert.equal(value.work.cpu_chunks, 8);
  assert.equal(value.work.wasm_linear_bytes, 0); assert.equal(value.cpu_ms, null);
  assert.deepEqual(f.events.map(e => e.event), ['start', 'fallback']);
});
Deno.test('allocation refusal is explicit and does not expose error strings', async () => {
  const f = fixture(); const response = await f.handler.fetch(request('memory-wasm')); const text = await response.text();
  assert.equal(response.status, 200); assert.equal(JSON.parse(text).result, 'allocation_refused');
  assert.ok(!text.includes('sentinel')); assert.deepEqual(f.events.map(e => e.event), ['start', 'allocation_refused']);
});
Deno.test('caught workload failures are explicit finite terminal evidence', async () => {
  const f = fixture({ synthetic: () => Promise.reject(new Error('sentinel-secret')) });
  const response = await f.handler.fetch(request('cpu-wasm')); const text = await response.text();
  assert.equal(response.status, 500); assert.ok(!text.includes('sentinel'));
  assert.deepEqual(f.events.map(e => e.event), ['start', 'failed']);
  assert.equal((await f.handler.fetch(request())).status, 200);
});
Deno.test('unusable elapsed clock is null only on failure, never a substitute measurement', async () => {
  const f = fixture({ async synthetic() { f.state.time = NaN; throw new Error('clock'); } });
  assert.equal((await f.handler.fetch(request('cpu-wasm'))).status, 500);
  assert.equal(f.events[1].event, 'failed'); assert.equal(f.events[1].elapsed_ms, null);
});
Deno.test('background registers before launching and retains busy ownership after 202', async () => {
  let release!: () => void;
  const f = fixture({ sleep: () => new Promise<void>(resolve => { release = resolve; }) });
  const response = await f.handler.fetch(request('background'));
  assert.equal(response.status, 202); assert.equal(f.tasks.length, 1);
  assert.equal((await f.handler.fetch(request())).status, 429);
  f.handler.beforeUnload(); f.handler.beforeUnload();
  assert.equal(f.events.filter(e => e.event === 'beforeunload').length, 1);
  f.state.time = 450_000; release(); await f.tasks[0];
  assert.equal(f.events.at(-1)?.event, 'fallback');
  assert.equal((await f.handler.fetch(request())).status, 200);
});
Deno.test('waitUntil registration failure launches no background work', async () => {
  const f = fixture({ waitUntil() { throw new Error('sentinel-secret'); } });
  assert.equal((await f.handler.fetch(request('background'))).status, 500);
  await Promise.resolve(); assert.equal(f.state.sleeps, 0);
  assert.deepEqual(f.events.map(e => e.event), ['start', 'failed']);
  assert.equal((await f.handler.fetch(request())).status, 200);
});
Deno.test('finite background fallback ignores the completed response connection', async () => {
  const controller = new AbortController();
  const f = fixture(); const response = await f.handler.fetch(request('background', { signal: controller.signal }));
  assert.equal(response.status, 202); controller.abort(); await f.tasks[0];
  assert.equal(f.state.sleeps, 45); assert.equal(f.events.filter(e => e.event === 'heartbeat').length, 44);
  assert.equal(f.events.at(-1)?.event, 'fallback'); assert.equal(f.state.time, 450_000);
});
Deno.test('only exact verified one-page recovery emits complete', async () => {
  const f = fixture(); const value = await (await f.handler.fetch(request('recovery'))).json();
  assert.equal(value.pages, 1); assert.equal(value.result, 'complete'); assert.equal(f.state.recovered, 1);
  for (const result of [{ outcome: 'verified', pages: 2, sha256: FIXTURE }, { outcome: 'malformed', pages: null, sha256: FIXTURE },
    { outcome: 'verified', pages: 1, sha256: SOURCE }]) {
    const g = fixture({ recover: async () => result });
    assert.equal((await g.handler.fetch(request('recovery'))).status, 500);
    assert.equal(g.events.at(-1)?.event, 'failed');
  }
});
Deno.test('same-project Auth adapter refuses redirects and bounds returned bytes', async () => {
  let observed: RequestInit | undefined, target = '';
  const auth = createAuthenticate('coxhjvqpflgxkleydati', 'test-anon', (async (url, init) => {
    target = String(url); observed = init; return Response.json({ id: USER });
  }) as typeof fetch);
  assert.deepEqual(await auth('test-token', new AbortController().signal), { id: USER });
  assert.equal(target, 'https://coxhjvqpflgxkleydati.supabase.co/auth/v1/user'); assert.equal(observed?.redirect, 'error');
  for (const value of [new Response('x'.repeat(65_537)), new Response('{}', { headers: { 'content-length': '70000' } }),
    new Response('{}', { headers: { 'content-length': '3' } }), new Response('{}', { status: 302 }), new Response('{}', { status: 201 })]) {
    const bad = createAuthenticate('coxhjvqpflgxkleydati', 'test-anon', (async () => value) as typeof fetch);
    await assert.rejects(() => bad('test-token', new AbortController().signal), /probe_auth_failed/);
  }
});

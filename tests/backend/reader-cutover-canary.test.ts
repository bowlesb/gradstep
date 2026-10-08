import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { BodyBudget, boundedBody, cacheEvidence, LIMITS, ReaderCutoverCanary, readerPath, validateScope } from '../../scripts/reader-cutover-canary.mjs';

const origin = 'https://coxhjvqpflgxkleydati.supabase.co';
const env = { SUPABASE_URL: origin, SUPABASE_PROJECT_REF: 'coxhjvqpflgxkleydati',
  SUPABASE_ANON_KEY: 'public-fixture', SUPABASE_SERVICE_ROLE_KEY: 'private-service-fixture', SUPABASE_ACCESS_TOKEN: 'private-management-fixture' };
const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const objectPath = `reader/${'a'.repeat(64)}/index.html`;
const withURL = (response: Response, url: string) => Object.defineProperty(response, 'url', { value: url });
function canary(fetcher: typeof fetch = async () => { throw new Error('Unexpected network request'); }) {
  const events: any[] = []; let now = 1_800_000_000_000;
  const run: any = new ReaderCutoverCanary({ env, emit: (event: unknown) => events.push(event), fetcher, now: () => now });
  return { run, events, advance: (ms: number) => { now += ms; } };
}

test('import and help need neither credentials nor network and do not start a hosted canary', () => {
  const text = execFileSync(process.execPath, ['scripts/reader-cutover-canary.mjs', '--help'], {
    encoding: 'utf8', env: { PATH: process.env.PATH }, timeout: 5000,
  });
  assert.match(text, /staging --execute/); assert.doesNotMatch(text, /synthetic_created|Safe report/);
  assert.throws(() => new ReaderCutoverCanary({ env: { ...env, SUPABASE_URL: 'https://production.invalid' }, emit() {} }), /staging_credentials_required/);
});

test('payload and descriptor ceilings preserve a cleanup reserve and stop before new sends', () => {
  const b = new BodyBudget();
  for (let i = 0; i < 6; i++) b.admit(4096, true);
  assert.throws(() => b.admit(4096, true), /descriptor_budget/);
  const payload = new BodyBudget(); payload.consume(LIMITS.bodyBytes - 65_536);
  assert.throws(() => payload.admit(1, false), /payload_budget_before_request/);
  payload.admit(4096, false, true); payload.consume(4096, true);
  assert.ok(payload.remaining(true) > 0);
  const requests = new BodyBudget(); requests.requests = LIMITS.requests - 15;
  assert.throws(() => requests.admit(4096, false), /request_budget/);
  requests.admit(4096, false, true);
});

test('actual streams count toward the budget, oversized bodies are cancelled, and compression is refused', async () => {
  let cancelled = false; const budget = new BodyBudget();
  const stream = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(32)); }, cancel() { cancelled = true; } });
  await assert.rejects(boundedBody(new Response(stream), 16, budget), /response_too_large/);
  assert.equal(budget.bytes, 32); assert.equal(cancelled, true);
  await assert.rejects(boundedBody(new Response('payload', { headers: { 'content-encoding': 'gzip' } }), 100, new BodyBudget()), /response_contract/);
  assert.equal((await boundedBody(new Response('payload', { headers: { 'content-length': '7' } }), 7, new BodyBudget())).toString(), 'payload');
});

test('network surface excludes providers, policy writes, object mutation and a different origin', async () => {
  let sent = 0; const { run } = canary(async (url) => { sent++; return withURL(Response.json({}), String(url)); });
  for (const [url, options] of [
    [`${origin}/functions/v1/chat`, { method: 'POST' }],
    [`${origin}/rest/v1/rpc/worker_grant_credits`, { method: 'POST' }],
    [`${origin}/rest/v1/rpc/worker_asset_enforcement`, { method: 'POST' }],
    [`${origin}/storage/v1/object/paper-assets/${objectPath}`, { method: 'DELETE' }],
    [`https://outside.invalid/storage/v1/cdn/paper-assets/${objectPath}`, { method: 'DELETE' }],
    [`https://api.supabase.com/v1/projects/coxhjvqpflgxkleydati/database/query`, { method: 'POST', body: { read_only: false } }],
  ] as const) await assert.rejects(run.http(url, options), /network_route_not_allowed/);
  assert.equal(sent, 0);
  await assert.rejects(run.rpc('worker_grant_credits', {}, {}, true), /rpc_not_allowed/);
});

test('full historical scope includes deleted/absent paths; omissions and discrepancies refuse', () => {
  const live = { path: objectPath, tracked: true, state: 'verified', bytes: 17, sha256: 'b'.repeat(64), physical: true, physical_bytes: '17' };
  const deleted = { ...live, path: objectPath.replace('index.html', 'old.css'), state: 'deleted', physical: false, physical_bytes: null };
  const plan = validateScope([live, deleted]);
  assert.equal(plan.count, 2); assert.equal(plan.historical_absent, 1);
  assert.deepEqual(new Set(plan.paths.map((p: any) => p.path)), new Set([live.path, deleted.path]));
  assert.equal(plan.digest, validateScope([deleted, live]).digest);
  for (const row of [{ ...live, tracked: false }, { ...live, physical_bytes: '18' }, { ...live, physical: false }, { ...deleted, physical: true }])
    assert.throws(() => validateScope([row]), /scope_/);
  for (const path of ['originals/paper.pdf', objectPath + '?token=secret', objectPath.replace('index.html', '../other'), objectPath.replace('reader/', 'reader//')])
    assert.throws(() => readerPath(path), /invalid_reader_path/);
});

test('general canary start stops at bounded proof and never mints legacy URLs or purges', async () => {
  const { run, events } = canary(); const steps: string[] = [];
  run.project = async () => { steps.push('project'); };
  run.snapshot = async (mode: string) => { assert.equal(mode, 'dual'); return {
    environment_transfer: [], policy: { environment_bytes_month: 32 * 1_048_576, backend_environment_bytes_month: 32 * 1_048_576 },
  }; };
  run.cachedPaper = async () => { steps.push('cached-tagged'); return { source_id: '2305.18290', requested_revision: 0, manifest_sha256: 'a'.repeat(64), bundle_bytes: 100 }; };
  run.account = async () => { steps.push('zero-account'); return {}; };
  run.addCached = async () => { steps.push('cached-add'); return {}; };
  run.fullBundle = async () => { steps.push('bounded'); return {}; };
  run.negativeProbes = async () => { steps.push('negative-probes'); };
  run.zeroPaid = async () => { steps.push('zero-paid-confirmed'); };
  run.legacyPair = async () => { assert.fail('Start must never mint legacy URLs'); };
  run.purgePath = async () => { assert.fail('Start must never purge'); };
  await run.start(); assert.equal(run.phase, 'bounded');
  assert.deepEqual(steps, ['project', 'cached-tagged', 'zero-account', 'zero-account', 'cached-add', 'bounded', 'negative-probes', 'zero-paid-confirmed']);
  assert.equal(events.at(-1).event, 'initial_proof_complete');
  await assert.rejects(run.command('fenced'), /wrong_phase/);
});

test('capability purge is explicitly scoped to one tiny object; only observed cache HIT passes rewarm', async () => {
  const sent: any[] = [];
  const { run, events, advance } = canary(async (url, options) => {
    sent.push({ url, options }); return withURL(Response.json({ message: 'success' }), String(url));
  });
  run.phase = 'warmed'; run.snapshot = async () => ({});
  run.urls = [{ fullPath: objectPath }, { fullPath: objectPath }];
  await run.command('probe-purge'); assert.equal(sent.length, 1);
  assert.equal(sent[0].options.method, 'DELETE'); assert.equal(sent[0].url, `${origin}/storage/v1/cdn/paper-assets/${objectPath}`);
  assert.equal(run.phase, 'probe_propagating');
  await assert.rejects(run.command('probe-rewarm'), /purge_propagation_wait/);
  const rewarm: string[] = []; run.warm = async (_: unknown, label: string) => { rewarm.push(label); };
  advance(LIMITS.propagationMs); await run.command('probe-rewarm');
  assert.equal(run.phase, 'purge_capable'); assert.deepEqual(rewarm, ['post_probe_rewarm', 'post_probe_rewarm']);
  const output = JSON.stringify(events); assert.doesNotMatch(output, /index.html|private-service|private-management/);
  assert.ok(output.includes(digest(objectPath)));
  assert.equal(cacheEvidence(new Response(null, { headers: { 'cf-cache-status': 'HIT', age: '5', location: 'private-token' } })).cf_cache_status, 'HIT');
  assert.equal(cacheEvidence(new Response(null, { headers: { 'cf-cache-status': 'private-token', age: 'private' } })).cf_cache_status, null);
});

test('404 and ambiguous success never retire an absent historical path', async () => {
  for (const [status, body] of [[404, { message: 'not found' }], [200, { message: 'unrecognized' }], [503, { private: 'token' }]] as const) {
    const { run, events } = canary(async url => withURL(Response.json(body, { status }), String(url)));
    await assert.rejects(run.purgePath(objectPath, 'retirement_purge'), /purge_404_unresolved|purge_not_confirmed/);
    assert.doesNotMatch(JSON.stringify(events), /token|not found|index.html/);
  }
});

test('policy and legacy counter must remain fenced through the full 400+900+margin window', async () => {
  const { run, advance } = canary();
  const snap = { at: new Date(run.now()).toISOString(), policy: { legacy_descriptors: 2, legacy_last_issued_at: 'known' },
    issuer_function_hash: 'a', legacy_function_hash: 'b' };
  run.fenced = snap; run.retireAt = run.now() + LIMITS.drainMs;
  run.snapshot = async () => ({ ...snap, at: new Date(run.now()).toISOString() });
  await assert.rejects(run.stillFenced(), /issuer_drain_wait/);
  advance(LIMITS.drainMs); await run.stillFenced();
  run.snapshot = async () => ({ ...snap, at: new Date(run.now()).toISOString(), policy: { ...snap.policy, legacy_descriptors: 3 } });
  await assert.rejects(run.stillFenced(), /fence_changed/);
});

test('a scope confirmation mismatch cannot purge; object changes before purge stop without sends', async () => {
  const { run } = canary(); run.phase = 'planned';
  run.plan = { digest: 'a'.repeat(64), signature: { fingerprint: 'before' }, paths: [{ path: objectPath }] };
  await assert.rejects(run.command('purge ' + 'b'.repeat(64)), /purge_plan_confirmation/);
  run.stillFenced = async () => ({}); run.sql = async () => [{ fingerprint: 'after' }];
  await assert.rejects(run.command('purge ' + 'a'.repeat(64)), /scope_changed/);
});

test('account cleanup uses only real self-delete, never service deletion or another identity', async () => {
  const requests: any[] = [], { run, events } = canary(async (url, options) => {
    requests.push({ url, options }); return withURL(Response.json({ deleted: true, complete: true }), String(url));
  });
  run.accounts = [{ id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', access: 'private-user-token', tokenAt: run.now(), password: 'private-password' }];
  run.urls = [{ member: { url: 'private-signed-url' } }];
  await run.cleanup(); assert.equal(requests.length, 1);
  assert.equal(requests[0].url, `${origin}/functions/v1/account-delete`);
  assert.equal(requests[0].options.headers.Authorization, 'Bearer private-user-token');
  assert.equal(JSON.parse(requests[0].options.body).confirm, 'delete my account');
  assert.equal(events.at(-1).status, 'complete'); assert.equal(run.urls.length, 0);
  assert.equal(run.accounts[0].access, undefined); assert.equal(run.accounts[0].password, undefined);
  assert.doesNotMatch(JSON.stringify(events), /private-/);
});

test('interrupt blocks further ordinary requests while preserving the cleanup channel', async () => {
  const stop = new AbortController(); stop.abort(); let sent = 0;
  const run = new ReaderCutoverCanary({ env, emit() {}, signal: stop.signal,
    fetcher: async url => { sent++; return withURL(Response.json({ deleted: true, complete: true }), String(url)); } });
  await assert.rejects(run.http(`${origin}/functions/v1/reader-artifact`), /process_interrupted/);
  assert.equal(sent, 0);
  await run.http(`${origin}/functions/v1/account-delete`, { method: 'POST', cleanup: true }); assert.equal(sent, 1);
});

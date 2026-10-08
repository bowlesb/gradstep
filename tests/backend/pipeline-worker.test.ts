import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { createHandler, HARD_RUN_LIMIT_MS, runInWorker, sameSecret, RunFailure } from '../../services/pipeline-worker/server.ts';

const secret = 's'.repeat(40);
async function serve(run?: Parameters<typeof createHandler>[0], options: Parameters<typeof createHandler>[1] = { maintenance: false }): Promise<{ server: Server; url: string }> {
  const handle = createHandler(run, options);
  const server = createServer((request, response) => { void handle(request, response, secret); });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address() as { port: number };
  return { server, url: `http://127.0.0.1:${address.port}` };
}

test('the Cloud Run worker answers health checks and refuses calls without the pipeline secret', async () => {
  let started = 0;
  const { server, url } = await serve(async () => { started++; return { processed: 1, ms: 1 }; });
  try {
    assert.equal((await fetch(`${url}/health`)).status, 200);
    assert.equal((await fetch(url, { method: 'GET' })).status, 405);
    assert.equal((await fetch(url, { method: 'POST' })).status, 401);
    assert.equal((await fetch(url, { method: 'POST', headers: { 'x-pipeline-secret': 'x'.repeat(40) } })).status, 401);
    assert.equal(started, 0, 'health and invalid requests never create work');
  } finally { server.close(); }
  assert.ok(sameSecret(secret, secret));
  assert.ok(!sameSecret(secret, secret.slice(1)));
});

test('maintenance is healthy but inactive and cannot start any work, including with valid credentials', async () => {
  let started = 0;
  for (const options of [{ maintenance: true, revision: 'fixture-maintenance' }, {}]) {
    // Capture the default without depending on the invoking shell's active switch.
    const previous = process.env.PIPELINE_MAINTENANCE;
    delete process.env.PIPELINE_MAINTENANCE;
    const serving = serve(async () => { started++; throw new Error('must never run'); }, options);
    if (previous !== undefined) process.env.PIPELINE_MAINTENANCE = previous;
    const { server, url } = await serving;
    try {
      const health = await (await fetch(`${url}/health`)).json();
      assert.equal(health.ok, true); assert.equal(health.mode, 'maintenance');
      if ('revision' in options) assert.equal(health.revision, 'fixture-maintenance');
      assert.equal((await fetch(url, { method: 'POST' })).status, 401);
      for (let n = 0; n < 2; n++) {
        const response = await fetch(url, { method: 'POST', headers: { 'x-pipeline-secret': secret } });
        assert.equal(response.status, 503);
        assert.deepEqual(await response.json(), { code: 'maintenance', accepted: false });
      }
      assert.equal(started, 0, 'no pipeline, tag, deletion or renderer thread starts during maintenance');
    } finally { server.close(); }
  }
  const { server, url } = await serve(async () => ({ processed: 0, ms: 0 }), { maintenance: false, revision: 'fixture-active' });
  try { assert.deepEqual(await (await fetch(`${url}/health`)).json(), { ok: true, mode: 'active', revision: 'fixture-active' }); }
  finally { server.close(); }
});

test('authorized HTTP work stays awaited and overlapping wakeups start no additional run', async () => {
  let started = 0, complete!: (value: { processed: number; ms: number }) => void;
  const gate = new Promise<{ processed: number; ms: number }>(resolve => { complete = resolve; });
  const { server, url } = await serve(() => { started++; return gate; });
  const post = () => fetch(url, { method: 'POST', headers: { 'x-pipeline-secret': secret } });
  try {
    let responded = false;
    const first = post().then(response => { responded = true; return response; });
    while (!started) await sleep(1);
    const overlap = await post();
    assert.equal(overlap.status, 202);
    assert.deepEqual(await overlap.json(), { accepted: true, busy: true });
    assert.equal(started, 1);
    assert.equal(responded, false, 'the response cannot end while work is still running');
    complete({ processed: 2, ms: 25 });
    assert.deepEqual(await (await first).json(), { accepted: true, processed: 2 });
    assert.equal((await post()).status, 200);
    assert.equal(started, 2, 'the instance accepts another run after completion');
  } finally { complete({ processed: 0, ms: 0 }); server.close(); }
});

test('thread failure and timeout are HTTP failures, with the instance reusable afterward', async () => {
  let calls = 0;
  const { server, url } = await serve(async () => {
    calls++;
    if (calls <= 2) throw new RunFailure(calls === 1 ? 'run_timeout' : 'worker_failed');
    return { processed: 0, ms: 1 };
  });
  try {
    for (const expected of [504, 500, 200]) {
      const response = await fetch(url, { method: 'POST', headers: { 'x-pipeline-secret': secret } });
      assert.equal(response.status, expected);
      if (expected !== 200) assert.deepEqual(await response.json(), { code: 'run_failed' });
    }
  } finally { server.close(); }
});

async function fixture(source: string, work: (url: URL, directory: string) => Promise<void>) {
  const directory = await mkdtemp(join(tmpdir(), 'gradstep-worker-test-'));
  const path = join(directory, 'fixture.ts');
  try { await writeFile(path, source); await work(pathToFileURL(path), directory); }
  finally { await rm(directory, { recursive: true, force: true }); }
}

test('real Node TS worker imports runtime dependencies, and is joined before success resolves', async () => {
  const runtime = new URL('../../services/pipeline-worker/run.ts', import.meta.url).href;
  await fixture(`
    import { parentPort } from 'node:worker_threads';
    import { appendFileSync } from 'node:fs';
    import { fileURLToPath } from 'node:url';
    const runtime = await import(${JSON.stringify(runtime)});
    if (typeof runtime.runOnce !== 'function') throw new Error('runtime import failed');
    const marker = fileURLToPath(new URL('./heartbeat', import.meta.url));
    appendFileSync(marker, 'ready');
    parentPort!.postMessage({ ok: true, result: { processed: 3, ms: 7 } });
    setInterval(() => appendFileSync(marker, '.'), 1);
  `, async (url, directory) => {
    assert.deepEqual(await runInWorker({ url, timeoutMs: 15_000 }), { processed: 3, ms: 7 });
    const marker = join(directory, 'heartbeat'), stopped = await readFile(marker, 'utf8');
    await sleep(40);
    assert.equal(await readFile(marker, 'utf8'), stopped, 'no background work survives the awaited join');
  });
});

test('hard deadline stops a CPU-bound worker whose event loop cannot run a timer', async () => {
  assert.ok(HARD_RUN_LIMIT_MS < 900_000);
  await fixture('while (true) {}', async url => {
    const started = Date.now();
    await assert.rejects(runInWorker({ url, timeoutMs: 100 }), { code: 'run_timeout' });
    assert.ok(Date.now() - started < 10_000, 'timeout must be enforced by the parent event loop');
  });
});

test('invalid result, reported failure, exception and early exit cannot masquerade as success', async () => {
  for (const [source, code] of [
    ["parentPort.postMessage({ ok: true, result: { processed: -1, ms: 0 } })", 'invalid_worker_result'],
    ["parentPort.postMessage({ ok: false, code: 'do not expose provider details' })", 'worker_failed'],
    ["throw new Error('do not expose provider details')", 'worker_failed'],
    ['process.exit(0)', 'worker_stopped'],
  ]) {
    await fixture(`import { parentPort } from 'node:worker_threads'; ${source}`, async url => {
      await assert.rejects(runInWorker({ url, timeoutMs: 10_000 }), { code });
    });
  }
});

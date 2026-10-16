// Server paper copies retired (docs/architecture/DATA_HANDLING_AND_COSTS.md "Server paper copies: retired"): what counts
// as a paper copy, Storage listing and deletion over a fixture transport, and the storage.no-papers check's verdicts.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runInNewContext } from 'node:vm';
import { CONTROL_BUCKETS, PAPER_BUCKETS, isPaperCopyPath, listBucket, removeObjects, summarize } from '../../scripts/paper-copies.mjs';

const hex = (n: number) => 'a'.repeat(n), account = '81f86a48-84fb-4742-a62f-c4c77f3ff58e';

test('every path the pipeline wrote is a paper copy; other buckets and paths are not', () => {
  for (const path of [`originals/${hex(64)}.pdf`, `private/${account}/originals/${hex(64)}.pdf`, `raw/${hex(64)}/standalone.mmd`,
    `raw/${hex(64)}/output.mmd.zip`, `raw/${hex(64)}/lines.json`, `reader/${hex(64)}/index.html`, `reader/${hex(64)}/manifest.json`,
    `reader/${hex(64)}/assets/${hex(64)}.jpg`]) assert.ok(isPaperCopyPath('paper-assets', path), path);
  assert.ok(isPaperCopyPath('paper-uploads', `${account}/${hex(64)}/0`));
  for (const [bucket, path] of [['paper-assets', 'notes.txt'], ['paper-assets', `reader/${hex(64)}/assets/x/y.jpg`], ['paper-assets', `raw/short/standalone.mmd`],
    ['podcast-assets', `private/${account}/${hex(64)}/audio.m4a`], ['support', `${account}/report.png`], ['private-content', `podcast-sources/${account}/x.txt`]])
    assert.equal(isPaperCopyPath(bucket, path), false, `${bucket}/${path}`);
  assert.deepEqual(PAPER_BUCKETS, ['paper-assets', 'paper-uploads']);
  assert.ok(CONTROL_BUCKETS.every(b => !PAPER_BUCKETS.includes(b)), 'podcast audio, episode text and reports are never paper buckets');
});

/** A Storage fixture: folders are entries without an id, as the list API returns them; pages of 1000. */
function storage(files: Record<string, number>) {
  const present = new Map(Object.entries(files)), calls: { method: string; body: any }[] = [];
  const fetcher = async (url: string, init: any) => {
    const body = JSON.parse(init.body);
    calls.push({ method: init.method, body });
    assert.equal(init.headers.apikey, 'service-fixture-key');
    if (init.method === 'DELETE') {
      const removed = body.prefixes.filter((p: string) => present.delete(p));
      return new Response(JSON.stringify(removed.map((name: string) => ({ name }))), { status: 200 });
    }
    assert.match(url, /\/storage\/v1\/object\/list\/paper-assets$/);
    const prefix = body.prefix ? body.prefix + '/' : '', seen = new Map<string, any>();
    for (const [path, size] of present) {
      if (!path.startsWith(prefix)) continue;
      const rest = path.slice(prefix.length), [head, ...tail] = rest.split('/');
      seen.set(head, tail.length ? { name: head, id: null } : { name: head, id: 'x', metadata: { size } });
    }
    const entries = [...seen.values()].sort((a, b) => a.name.localeCompare(b.name)).slice(body.offset, body.offset + body.limit);
    return new Response(JSON.stringify(entries), { status: 200 });
  };
  return { present, calls, fetcher };
}

test('a bucket is listed recursively, with sizes, across pages; deletion goes 100 paths at a time', async () => {
  const files: Record<string, number> = { [`originals/${hex(64)}.pdf`]: 1000, [`raw/${hex(64)}/standalone.mmd`]: 50 };
  for (let i = 0; i < 1203; i++) files[`reader/${hex(64)}/assets/${String(i).padStart(64, '0')}.jpg`] = 2;
  const fixture = storage(files), saved = globalThis.fetch;
  globalThis.fetch = fixture.fetcher as typeof fetch;
  try {
    const listed = await listBucket('https://fixture.invalid', 'service-fixture-key', 'paper-assets');
    assert.equal(listed.length, 1205);
    const s = summarize(listed);
    assert.deepEqual([s['paper-assets'].objects, s['paper-assets'].bytes], [1205, 1000 + 50 + 2406]);
    assert.deepEqual(Object.keys(s['paper-assets'].prefixes).sort(), ['originals', 'raw', 'reader']);
    assert.ok(fixture.calls.some(c => c.body.offset === 1000), 'the second page of a large folder is read');
    const removed = await removeObjects('https://fixture.invalid', 'service-fixture-key', 'paper-assets', listed.map(o => o.path));
    assert.equal(removed, 1205);
    assert.equal(fixture.calls.filter(c => c.method === 'DELETE').length, 13);
    assert.ok(fixture.calls.filter(c => c.method === 'DELETE').every(c => c.body.prefixes.length <= 100));
    assert.equal(fixture.present.size, 0);
    assert.equal((await listBucket('https://fixture.invalid', 'service-fixture-key', 'paper-assets')).length, 0);
  } finally { globalThis.fetch = saved; }
});

test('storage.no-papers passes only at zero objects, zero live rows and the fence on', async () => {
  const source = await readFile(resolve('scripts/workflow-checks.mjs'), 'utf8');
  const block = source.match(/^check\('storage\.no-papers',[\s\S]*?^\}\);/m)?.[0];
  assert.ok(block, 'Runner registration boundary changed; update the fixture harness');
  assert.match(block, /suites:ALL/, 'the canary, daily and weekly suites all run it');
  let objects: { bucket: string; path: string; bytes: number }[] = [], status: any;
  const checks = new Map<string, (input: { signal: AbortSignal }) => Promise<any>>();
  runInNewContext(block, {
    env: { SUPABASE_URL: 'https://fixture.invalid', SUPABASE_SERVICE_ROLE_KEY: 'service-fixture-key' }, ALL: ['deploy', 'daily', 'weekly'],
    PAPER_BUCKETS, summarize, megabytes: (b: number) => `${(b / 1e6).toFixed(1)} MB`,
    listBucket: async (_u: string, _k: string, bucket: string) => objects.filter(o => o.bucket === bucket),
    rpc: async (name: string) => { assert.equal(name, 'worker_paper_copies_status'); return status; },
    check: (id: string, _o: unknown, run: (input: { signal: AbortSignal }) => Promise<any>) => checks.set(id, run),
    pass: (reason: string, metrics: any) => ({ status: 'pass', reason, metrics }), fail: (reason: string, metrics: any) => ({ status: 'fail', reason, metrics }),
  });
  const registered = checks.get("storage.no-papers")!, run = () => registered({ signal: new AbortController().signal });
  status = { retired_at: '2026-10-16T06:30:00Z', live: 0, objects_deleted: 1631, bytes_deleted: 649268455 };
  let r = await run();
  assert.equal(r.status, 'pass', r.reason);
  assert.match(r.reason, /0 objects in paper-assets and paper-uploads; 0 tracked live; fence on since 2026-10-16; 1631 deleted/);
  objects = [{ bucket: 'paper-assets', path: `originals/${hex(64)}.pdf`, bytes: 5_000_000 }];
  r = await run();
  assert.equal(r.status, 'fail');
  assert.match(r.reason, /1 object\(s\), 5\.0 MB, in Storage: paper-assets originals\/ 1/);
  objects = []; status = { ...status, live: 2 };
  assert.match((await run()).reason, /2 paper copies tracked as live/);
  status = { retired_at: null, live: 0, objects_deleted: 0, bytes_deleted: 0 };
  assert.match((await run()).reason, /the fence is off/);
});

test('the scheduled job image carries the shared module', async () => {
  const target = execFileSync('python3', ['-c',
    'import importlib.util,sys; s=importlib.util.spec_from_file_location("scheduler",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.context())',
    resolve('scripts/schedule-workflow-checks.py')], { encoding: 'utf8' }).trim();
  try {
    const helper = await import(pathToFileURL(resolve(target, 'scripts/paper-copies.mjs')).href);
    assert.equal(typeof helper.listBucket, 'function');
    assert.match(await readFile(resolve(target, 'Dockerfile'), 'utf8'), /COPY scripts\/paper-copies\.mjs scripts\/paper-copies\.mjs/);
  } finally { await rm(target, { recursive: true }); }
});

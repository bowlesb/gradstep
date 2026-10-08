import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runInNewContext } from 'node:vm';
import { verifyReaderDelivery } from '../../scripts/reader-workflow.mjs';
import { deliverReaderMember } from '../../supabase/functions/_shared/reader-delivery.ts';

const origin = 'https://reader-fixture.invalid';
const digest = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');
const withURL = (response: Response, url: string) => Object.defineProperty(response, 'url', { value: url });
function fixture(transport: 'legacy' | 'bounded-v1' = 'bounded-v1', configuredOrigin = origin) {
  const item = { id: randomUUID(), document_id: randomUUID(), artifact_id: randomUUID() };
  const content = [Buffer.from('<p>Fixture</p>'), Buffer.from('{"blocks":[]}')];
  const members = content.map((bytes, i) => ({ path: i ? 'reader.json' : 'index.html', bytes: bytes.length, sha256: digest(bytes),
    media_type: i ? 'application/json' : 'text/html', role: i ? 'index' : 'html' }));
  const manifest = Buffer.from(JSON.stringify({ format: 'reader-bundle-v1', members }));
  const token = 'a'.repeat(64), ids = members.map(() => randomUUID());
  const value: any = { item_id: item.id, document_id: item.document_id, artifact_id: item.artifact_id,
    renderer_version: 'timestep-mathpix-mathml-v1', transport, manifest_sha256: digest(manifest), manifest: manifest.toString('base64'),
    members: members.map((member, i) => ({ ...member, url: transport === 'legacy'
      ? `${configuredOrigin}/storage/v1/object/sign/paper-assets/reader/${digest(manifest)}/${member.path}?token=private-signed-token`
      : `${configuredOrigin}/functions/v1/reader-member?grant=${token}&member=${ids[i]}` })) };
  const requests: { url: string; init: RequestInit }[] = [];
  let tokenReads = 0;
  let respond: (i: number, url: string, init: RequestInit) => Response | Promise<Response> = (i, url) =>
    withURL(new Response(content[i], { headers: { 'content-type': members[i].media_type, 'content-length': String(content[i].length),
      'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' } }), url);
  const fetcher = async (url: string, init: RequestInit) => {
    requests.push({ url, init });
    if (new URL(url).pathname === '/functions/v1/reader-artifact') return withURL(Response.json(value), url);
    const i = value.members.findIndex((member: any) => member.url === url);
    assert.ok(i >= 0, 'No unlisted member can be requested');
    return respond(i, url, init);
  };
  return { item, value, content, members, ids, requests, fetcher, tokenReads: () => tokenReads,
    response: (next: typeof respond) => { respond = next; },
    run: (signal?: AbortSignal) => verifyReaderDelivery({ backendURL: configuredOrigin, anonKey: 'public-fixture-key',
      token: async () => { tokenReads++; return 'account-fixture-token'; }, item, signal, fetcher }) };
}

test('workflow requests bounded-v1 and consumes the actual authenticated member response contract once', async () => {
  const f = fixture(), redeemed = new Set();
  f.response(async (i, url, init) => withURL(await deliverReaderMember(new Request(url, init), {
    account: async request => { assert.equal(request.headers.get('authorization'), 'Bearer account-fixture-token'); return 'fixture-account'; },
    rpc: async <T>(name: string, args: Record<string, unknown>) => {
      if (name === 'worker_reader_delivery_observed') return null as T;
      assert.equal(name, 'worker_reader_delivery_redeem');
      assert.equal(args.p_object_id, f.ids[i]); assert.equal(args.p_account_id, 'fixture-account');
      assert.ok(!redeemed.has(f.ids[i])); redeemed.add(f.ids[i]);
      return { grant_id: randomUUID(), bucket: 'paper-assets', path: 'reader/fixture/' + f.members[i].path,
        bytes: f.members[i].bytes, sha256: f.members[i].sha256, media_type: f.members[i].media_type } as T;
    },
    download: async () => new Uint8Array(f.content[i]),
  }, {}), url));
  assert.deepEqual(await f.run(), { members: 2, bytes: f.content.reduce((n, b) => n + b.length, 0), transport: 'bounded-v1' });
  assert.equal(new URL(f.requests[0].url).searchParams.get('transport'), 'bounded-v1');
  assert.equal(f.requests.length, 3); assert.equal(f.tokenReads(), 3); assert.equal(redeemed.size, 2);
  for (const request of f.requests) {
    assert.equal(request.init.redirect, 'error');
    assert.equal(new Headers(request.init.headers).get('apikey'), 'public-fixture-key');
  }
});

test('only the configured standard hosted bounded endpoint accepts HTML served as plain text', async () => {
  const hosted = 'https://' + 'a'.repeat(20) + '.supabase.co';
  const reply = (f: ReturnType<typeof fixture>, index: number, url: string, overrides: Record<string, string> = {}, corrupt = false) =>
    withURL(new Response(corrupt ? Buffer.alloc(f.content[index].length, 120) : f.content[index], { headers: {
      'content-type': index ? 'application/json' : 'text/plain; charset=utf-8',
      'content-length': String(f.content[index].length), 'cache-control': 'private, no-store',
      'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', ...overrides,
    } }), url);
  const accepted = fixture('bounded-v1', hosted);
  accepted.response((i, url) => reply(accepted, i, url));
  assert.equal((await accepted.run()).transport, 'bounded-v1');
  for (const [transport, configuredOrigin] of [['legacy', hosted], ['bounded-v1', origin], ['bounded-v1', hosted + ':444']] as const) {
    const refused = fixture(transport, configuredOrigin);
    refused.response((i, url) => reply(refused, i, url));
    await assert.rejects(refused.run(), /reader_member_type/);
  }
  for (const [overrides, corrupt, expected] of [
    [{ 'x-content-type-options': '' }, false, 'reader_member_response_contract'],
    [{ 'cache-control': 'public, max-age=60' }, false, 'reader_member_response_contract'],
    [{ 'content-type': 'application/octet-stream' }, false, 'reader_member_type'],
    [{}, true, 'reader_member_integrity'],
  ] as const) {
    const refused = fixture('bounded-v1', hosted);
    refused.response((i, url) => reply(refused, i, url, overrides, corrupt));
    await assert.rejects(refused.run(), { message: expected });
  }
  const jsonAsText = fixture('bounded-v1', hosted);
  jsonAsText.response((i, url) => reply(jsonAsText, i, url, { 'content-type': 'text/plain' }));
  await assert.rejects(jsonAsText.run(), /reader_member_type/);
});

test('streamed bounded members may omit Content-Length but still require exact byte count and hash', async () => {
  for (const mutation of ['none', 'short', 'long', 'corrupt', 'wrong-declared'] as const) {
    const f = fixture('bounded-v1');
    f.response((i, url) => {
      const original = f.content[i];
      const body = mutation === 'short' ? original.subarray(1)
        : mutation === 'long' ? Buffer.concat([original, Buffer.from('x')])
        : mutation === 'corrupt' ? Buffer.alloc(original.length, 120) : original;
      const headers: Record<string, string> = { 'content-type': f.value.members[i].path.endsWith('.html') ? 'text/html' : 'application/json',
        'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' };
      if (mutation === 'wrong-declared') headers['content-length'] = String(original.length + 1);
      return withURL(new Response(body, { headers }), url);
    });
    if (mutation === 'none') assert.equal((await f.run()).bytes, f.content.reduce((n, b) => n + b.length, 0));
    else await assert.rejects(f.run(), /reader_response_size|reader_response_read_failed|reader_member_integrity/);
  }
});

test('current and pre-035 legacy descriptors retain hash checks without forwarding account headers to Storage', async () => {
  for (const old of [false, true]) {
    const f = fixture('legacy'); if (old) delete f.value.transport;
    assert.equal((await f.run()).transport, 'legacy');
    assert.equal(f.tokenReads(), 1);
    for (const request of f.requests.slice(1)) {
      assert.equal(new Headers(request.init.headers).get('authorization'), null);
      assert.equal(new Headers(request.init.headers).get('apikey'), null);
      assert.equal(request.init.redirect, 'error');
    }
  }
});

test('all member URLs are authorized before any redemption, including the last descriptor member', async () => {
  const base = `${origin}/functions/v1/reader-member?grant=${'a'.repeat(64)}&member=${randomUUID()}`;
  const urls = [base.replace(origin, 'https://outside.invalid'), base.replace(origin, origin + ':444'), base.replace('https:', 'http:'),
    base.replace('https://', 'https://private@'), base.replace('https://', 'https://@'), base + '#', base + '#private',
    base + '&range=all', base + '&member=' + randomUUID(), base.replace('reader-member?', 'chat?'),
    base.replace('grant=', 'other='), base.replace('member=', 'other='), base.replace('a'.repeat(64), 'a'.repeat(63)),
    base.replace(/member=.*/, 'member=not-a-uuid')];
  for (const url of urls) {
    const f = fixture(); f.value.members[1].url = url;
    await assert.rejects(f.run(), /reader_member_url/);
    assert.equal(f.requests.length, 1); assert.equal(f.tokenReads(), 1);
  }
  const f = fixture('legacy'); f.value.members[1].url = f.value.members[1].url.replace('/paper-assets/', '/other-bucket/');
  await assert.rejects(f.run(), /reader_member_url/); assert.equal(f.requests.length, 1);
});

test('identity, immutable manifest and exact member bindings are checked before any member GET', async () => {
  const changes = [
    (f: ReturnType<typeof fixture>) => { f.value.item_id = randomUUID(); },
    (f: ReturnType<typeof fixture>) => { f.value.artifact_id = randomUUID(); },
    (f: ReturnType<typeof fixture>) => { f.value.document_id = randomUUID(); },
    (f: ReturnType<typeof fixture>) => { f.value.manifest_sha256 = '0'.repeat(64); },
    (f: ReturnType<typeof fixture>) => { f.value.members[1].bytes++; },
    (f: ReturnType<typeof fixture>) => { f.value.members[1].sha256 = '0'.repeat(64); },
    (f: ReturnType<typeof fixture>) => { f.value.members[1].path = f.value.members[0].path; },
    (f: ReturnType<typeof fixture>) => { f.value.members[1].url = f.value.members[0].url; },
    (f: ReturnType<typeof fixture>) => { f.value.members[1].url = f.value.members[1].url.replace('a'.repeat(64), 'b'.repeat(64)); },
    (f: ReturnType<typeof fixture>) => { f.value.transport = 'new-unknown'; },
  ];
  for (const change of changes) {
    const f = fixture(); change(f);
    await assert.rejects(f.run(), /reader_(descriptor|manifest)/); assert.equal(f.requests.length, 1);
  }
});

test('bounded responses reject redirect, partial, cacheable, misbound, malformed and corrupt replies without retry', async () => {
  const cases: ((f: ReturnType<typeof fixture>, url: string) => Response)[] = [
    (_, url) => withURL(new Response('redirect', { status: 302, headers: { location: 'https://outside.invalid/private' } }), url),
    (_, url) => withURL(new Response('partial', { status: 206 }), url),
    (f) => withURL(new Response(f.content[0]), 'https://outside.invalid/private'),
    (f, url) => withURL(new Response(f.content[0], { headers: { 'content-type': 'text/html' } }), url),
    (f, url) => withURL(new Response(f.content[0], { headers: { 'content-type': 'text/html', 'content-length': String(f.content[0].length), 'cache-control': 'public' } }), url),
    (f, url) => withURL(new Response(f.content[0], { headers: { 'content-encoding': 'gzip' } }), url),
    (f, url) => withURL(new Response(f.content[0], { headers: { 'content-range': 'bytes 0-9/10' } }), url),
    (_, url) => withURL(new Response('x', { headers: { 'content-length': '1' } }), url),
    (f, url) => withURL(new Response(Buffer.alloc(f.content[0].length, 120), { headers: { 'content-type': 'text/html',
      'content-length': String(f.content[0].length), 'cache-control': 'private, no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' } }), url),
  ];
  for (const response of cases) {
    const f = fixture(); f.response((_, url) => response(f, url));
    await assert.rejects(f.run(), error => {
      assert.ok(error instanceof Error); assert.match(error.message, /^reader/);
      assert.doesNotMatch(error.message, /outside|private|grant=|index.html/); return true;
    });
    assert.equal(f.requests.length, 2);
  }
});

test('oversize streams are cancelled, quotas stay finite and abort never consumes another grant', async () => {
  let cancelled = 0;
  const f = fixture();
  f.response((_, url) => withURL(new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(100)); }, cancel() { cancelled++; } })), url));
  await assert.rejects(f.run(), /reader_response_read_failed/);
  assert.equal(cancelled, 1); assert.equal(f.requests.length, 2);
  const quota = fixture();
  quota.response((_, url) => withURL(Response.json({ code: 'reader_transfer_limit', message: 'private-signed-token' }, { status: 429 }), url));
  await assert.rejects(quota.run(), { message: 'reader-member: HTTP 429 reader_transfer_limit' });
  assert.equal(quota.requests.length, 2);
  const aborted = fixture(), control = new AbortController(); control.abort(new Error('private-signed-token'));
  await assert.rejects(aborted.run(control.signal), { message: 'reader_cancelled' });
  assert.equal(aborted.requests.length, 0);
  const cancelFailure = fixture();
  cancelFailure.response((_, url) => withURL(new Response(new ReadableStream({ cancel() { throw new Error('private-signed-token'); } }),
    { headers: { 'content-length': '99999' } }), url));
  await assert.rejects(cancelFailure.run(), { message: 'reader_response_size' });
  const loginFailure = fixture();
  await assert.rejects(verifyReaderDelivery({ backendURL: origin, anonKey: 'public-fixture-key',
    token: async () => { throw new Error('private-signed-token'); }, item: loginFailure.item, fetcher: loginFailure.fetcher }),
  { message: 'reader_authentication_failed' });
  assert.equal(loginFailure.requests.length, 0);
});

test('the allowlisted scheduled-job context contains and imports the standalone reader helper', async () => {
  const target = execFileSync('python3', ['-c',
    'import importlib.util,sys; s=importlib.util.spec_from_file_location("scheduler",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.context())',
    resolve('scripts/schedule-workflow-checks.py')], { encoding: 'utf8' }).trim();
  try {
    const helper = await import(pathToFileURL(resolve(target, 'scripts/reader-workflow.mjs')).href);
    assert.equal(typeof helper.verifyReaderDelivery, 'function');
    const docker = await readFile(resolve(target, 'Dockerfile'), 'utf8');
    assert.match(docker, /COPY scripts\/reader-workflow\.mjs scripts\/reader-workflow\.mjs/);
  } finally { await rm(target, { recursive: true }); }
});

test('every runner check using verifyBundle supplies the complete library item and reports its actual transport', async () => {
  // Execute the actual registered check callbacks with fixture transports. Do not import the
  // operational runner: its top level loads credentials and runs the selected hosted suite.
  const source = await readFile(resolve('scripts/workflow-checks.mjs'), 'utf8');
  const blocks = [
    /^async function verifyBundle\([^\n]*\n[\s\S]*?^\}/m,
    /^check\('import\.arxiv',[\s\S]*?^\}\);/m,
    /^check\('ingest\.imports-ready',[\s\S]*?^\}\);/m,
    /^for \(const \[id, source, title, timeoutS, pages\][\s\S]*?^\}/m,
  ].map(pattern => {
    const block = source.match(pattern)?.[0];
    assert.ok(block, 'Runner registration boundary changed; update the fixture harness');
    return block;
  });
  const calls = (text: string) => (text.match(/\bverifyBundle\s*\(/g) ?? []).length;
  assert.equal(calls(source), calls(blocks.join('\n')), 'Every bundle call must have a fixture journey');
  const checks = new Map<string, (input: { signal: AbortSignal }) => Promise<any>>();
  let active = fixture();
  const acct = { touched: false, token: async () => 'account-fixture-token' };
  const result = (text: string, metrics?: unknown) => ({ text, metrics });
  const context = {
    env: { SUPABASE_URL: origin, SUPABASE_ANON_KEY: 'public-fixture-key' },
    ALL: ['deploy', 'daily', 'weekly'], SCHEDULED: ['daily', 'weekly'], USD_PER_CREDIT: 0.005,
    check: (id: string, _options: unknown, run: (input: { signal: AbortSignal }) => Promise<any>) => checks.set(id, run),
    account: async () => acct, beginImport: async () => {},
    waitForReady: async () => ({ item: active.item, seconds: 1, steps: [] }),
    pendingImports: [{ acct, id: randomUUID(), source: 'fixture-source', queuedAt: Date.now(), check: 'fixture-ingest' }],
    shared: {}, pass: result, warn: result,
    fail: (text: string) => { throw new Error(text); }, skip: () => { throw new Error('Unexpected fixture skip'); },
    verifyReaderDelivery: (args: any) => {
      assert.equal(args.item, active.item, 'The library identity must reach the delivery verifier intact');
      return verifyReaderDelivery({ ...args, fetcher: active.fetcher });
    },
  };
  runInNewContext(blocks.join('\n'), context);
  assert.deepEqual([...checks.keys()].sort(), ['import.arxiv', 'import.large-pdf', 'import.long-paper', 'ingest.imports-ready']);
  for (const [id, run] of checks) {
    for (const transport of ['bounded-v1', 'legacy'] as const) {
      active = fixture(transport);
      const checked = await run({ signal: new AbortController().signal });
      assert.equal(active.requests.length, 3, `${id} must verify both members`);
      assert.ok(checked.text.includes(transport), `${id} must report the actual transport`);
      if (id !== 'ingest.imports-ready') assert.equal(checked.metrics.reader_transport, transport);
    }
  }
});

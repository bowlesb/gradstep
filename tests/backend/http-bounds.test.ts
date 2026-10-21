// Review A24 (2026-10-21): request bodies and third-party answers are read to a bound before they are parsed, with or
// without a declared length; a link whose name turns private after the first check is refused before it is used.
import test from 'node:test';
import assert from 'node:assert/strict';
import { PublicError } from '../../supabase/functions/_shared/http.ts';
import { readJSONCapped, readRequestJSON } from '../../supabase/functions/_shared/bounded-json.ts';
import { handlePodcast, type PodcastAPIDeps } from '../../supabase/functions/_shared/podcast-api.ts';
import { probeLink } from '../../supabase/functions/_shared/identify.ts';

/** A body streamed in 64 KiB chunks with no declared length; `pulled` counts what the reader asked for. */
function streamed(total: number) {
  const state = { pulled: 0 };
  const body = new ReadableStream<Uint8Array>({ pull(controller) {
    if (state.pulled >= total) { controller.close(); return; }
    const size = Math.min(65_536, total - state.pulled); state.pulled += size;
    controller.enqueue(new Uint8Array(size).fill(0x20));
  } });
  return { body, state };
}
const post = (url: string, body: BodyInit | ReadableStream<Uint8Array>, headers: Record<string, string> = {}) =>
  new Request(url, { method: 'POST', body, headers, duplex: 'half' } as RequestInit);

test('request JSON is bounded before parsing, declared or not', async () => {
  assert.deepEqual(await readRequestJSON(post('https://edge.test/add', JSON.stringify({ query: 'arXiv:2305.18290' })), 16_384), { query: 'arXiv:2305.18290' });
  const big = streamed(1_000_000);
  const request = post('https://edge.test/add', big.body);
  assert.equal(request.headers.get('content-length'), null);
  await assert.rejects(readRequestJSON(request, 16_384), (error: unknown) => error instanceof PublicError && error.status === 413 && error.code === 'invalid_request');
  assert.ok(big.state.pulled <= 16_384 + 2 * 65_536, `read ${big.state.pulled} bytes past a 16 KiB bound`);
  await assert.rejects(readRequestJSON(post('https://edge.test/add', '{}', { 'content-length': '999999' }), 16_384),
    (error: unknown) => error instanceof PublicError && error.status === 413);
  for (const body of ['not json', 'ÿþ', '']) {
    await assert.rejects(readRequestJSON(post('https://edge.test/add', body), 16_384), (error: unknown) => error instanceof PublicError && error.status === 400 && error.code === 'invalid_request', JSON.stringify(body));
  }
});

test('third-party JSON is read to a cap, declared or streamed', async () => {
  const json = (body: BodyInit | ReadableStream<Uint8Array>, headers: Record<string, string> = {}) => new Response(body as BodyInit, { headers: { 'content-type': 'application/json', ...headers } });
  assert.deepEqual(await readJSONCapped(json('{"results":[]}'), 1024), { results: [] });
  await assert.rejects(readJSONCapped(json('{"results":[]}', { 'content-length': '5000000' }), 2 * 1024 * 1024), /response_too_large/);
  const flood = streamed(10_000_000);
  await assert.rejects(readJSONCapped(json(flood.body), 2 * 1024 * 1024), /response_too_large/);
  assert.ok(flood.state.pulled <= 2 * 1024 * 1024 + 2 * 65_536, 'the stream is cancelled at the cap');
  await assert.rejects(readJSONCapped(json('{"truncated'), 1024), SyntaxError);
});

test('the podcast API bounds bodies without a declared length and stores nothing for them', async () => {
  const uploads: string[] = [];
  const deps: PodcastAPIDeps = {
    user: async () => ({ accountID: '74000000-0000-4000-8000-0000000000aa', rpc: async () => { throw new Error('no RPC expected'); } }),
    service: async () => { throw new Error('no service RPC expected'); },
    download: async () => { throw new Error('no download expected'); },
    upload: async (_bucket, path) => { uploads.push(path); },
    origin: 'https://edge.test', randomHex: () => 'ab'.repeat(16),
  };
  const big = streamed(5_000_000);
  const request = post('https://edge.test/functions/v1/podcast?action=source', big.body);
  assert.equal(request.headers.get('content-length'), null);
  await assert.rejects(handlePodcast(request, deps, {}), (error: unknown) => error instanceof PublicError && error.status === 413 && error.code === 'invalid_podcast_request');
  assert.ok(big.state.pulled <= 450_000 + 2 * 65_536, `read ${big.state.pulled} bytes past the 450,000-byte bound`);
  await assert.rejects(handlePodcast(post('https://edge.test/functions/v1/podcast?action=start', 'x'.repeat(9_000)), deps, {}),
    (error: unknown) => error instanceof PublicError && error.status === 413, 'the 8 KiB default bound');
  await assert.rejects(handlePodcast(post('https://edge.test/functions/v1/podcast?action=start', ''), deps, {}),
    (error: unknown) => error instanceof PublicError && error.status === 400 && error.code === 'invalid_podcast_request', 'an empty body');
  assert.deepEqual(uploads, []);
});

test('a link whose name turns private after the first check is refused before its answer is used (DNS rebinding window)', async () => {
  const answers = new Map<string, number>();
  // Public for the first lookup, private afterwards: the common rebinding pattern (TTL 0, switch after one answer).
  const rebinding = async (host: string) => { const n = (answers.get(host) ?? 0) + 1; answers.set(host, n); return n === 1 ? ['93.184.216.34'] : ['10.0.0.7']; };
  let bodyRead = false;
  const fetcher = (async () => new Response(new ReadableStream({ pull(c) { bodyRead = true; c.enqueue(new TextEncoder().encode('<title>Internal admin</title>')); c.close(); } }, { highWaterMark: 0 }),
    { status: 200, headers: { 'content-type': 'text/html' } })) as typeof fetch;
  const probe = await probeLink(fetcher, new URL('https://rebind.example.org/paper'), rebinding, new AbortController().signal);
  assert.deepEqual(probe, { kind: 'refused', url: new URL('https://rebind.example.org/paper'), code: 'download_failed' });
  assert.equal(bodyRead, false, 'the page is never read, so nothing from it is echoed');
  assert.equal(answers.get('rebind.example.org'), 2, 'resolved before the request and again after the answer');
  // A redirect's target is checked before and after too.
  const redirect = (async (input: string | URL) => String(input).includes('start.example.org')
    ? new Response(null, { status: 302, headers: { location: 'https://rebind2.example.org/x' } })
    : new Response('<title>x</title>', { headers: { 'content-type': 'text/html' } })) as typeof fetch;
  const hop = await probeLink(redirect, new URL('https://start.example.org/p'), async host => host === 'rebind2.example.org' ? await rebinding(host) : ['93.184.216.34'], new AbortController().signal);
  assert.equal(hop.kind === 'refused' && hop.code, 'download_failed');
  // A stable public name still works.
  const page = await probeLink(redirect, new URL('https://repo.example.org/p'), async () => ['93.184.216.34'], new AbortController().signal);
  assert.equal(page.kind, 'page');
});

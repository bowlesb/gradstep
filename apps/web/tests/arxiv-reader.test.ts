import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ARXIV_PACING, ARXIV_REFUSAL, ArxivReaderError, admitsArxivAsset, fetchArxivAssets, resetArxivPacing, retrieveArxiv, shareInflight } from '../src/lib/arxiv-reader';

const base = 'https://arxiv.org/html/2305.18290v3';
const asset = (n: number) => `${base}/x${n}.png`;
type Served = { status?: number; type?: string; body?: Uint8Array; headers?: Record<string, string>; url?: string; delay?: number; release?: Promise<void> };
/** A fake arXiv: records every request and the number in flight at once. */
function serve(route: (url: string) => Served) {
 const requests: string[] = []; let inFlight = 0, peak = 0;
 vi.stubGlobal('fetch', async (url: string, init: RequestInit) => {
  requests.push(url); inFlight++; peak = Math.max(peak, inFlight);
  const r = route(url);
  try {
   if (r.release) await r.release;
   if (init.signal?.aborted) throw new DOMException('aborted', 'AbortError');
   const response = new Response(r.body ?? new Uint8Array([1, 2, 3]), { status: r.status ?? 200, headers: { 'content-type': r.type ?? 'image/png', ...r.headers } });
   Object.defineProperty(response, 'url', { value: r.url ?? url });
   return response;
  } finally { inFlight--; }
 });
 return { requests, peak: () => peak };
}
const never = new AbortController().signal;

describe('arXiv acquisition pacing', () => {
 beforeEach(() => { vi.useFakeTimers(); resetArxivPacing(); });
 afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

 it('spaces HTML document requests like page visits but loads one page’s assets together', async () => {
  const fake = serve(() => ({ type: 'text/html' }));
  const first = retrieveArxiv(base, 1024, true, never);
  await vi.advanceTimersByTimeAsync(0); await first;
  const second = retrieveArxiv('https://arxiv.org/html/2312.00752v2', 1024, true, never);
  await vi.advanceTimersByTimeAsync(ARXIV_PACING.documentSpacingMs - 1);
  expect(fake.requests).toHaveLength(1);
  await vi.advanceTimersByTimeAsync(1); await second;
  expect(fake.requests).toHaveLength(2);
  const assets = Array.from({ length: 6 }, (_, n) => asset(n));
  const gates: (() => void)[] = [];
  const held = serve(() => ({ release: new Promise<void>(resolve => { gates.push(resolve); }) }));
  const inputs = fetchArxivAssets(assets, base, 1 << 20, never);
  await vi.advanceTimersByTimeAsync(0);
  expect(held.requests).toHaveLength(ARXIV_PACING.assetConcurrency);
  while (gates.length) { gates.shift()!(); await vi.advanceTimersByTimeAsync(0); }
  const result = await inputs;
  expect(held.peak()).toBe(ARXIV_PACING.assetConcurrency);
  expect(result.map(i => i.url)).toEqual(assets);
  expect(held.requests.sort()).toEqual([...assets].sort());
 });

 it('honors Retry-After for every request and reports a long pause as busy at once', async () => {
  serve(() => ({ status: 429, headers: { 'retry-after': '30' } }));
  await expect(retrieveArxiv(asset(1), 1024, false, never)).rejects.toThrow('arXiv is busy');
  const fake = serve(() => ({}));
  const paused = retrieveArxiv(asset(2), 1024, false, never);
  await vi.advanceTimersByTimeAsync(29_000); expect(fake.requests).toHaveLength(0);
  await vi.advanceTimersByTimeAsync(1_000); await paused; expect(fake.requests).toHaveLength(1);
  serve(() => ({ status: 503, headers: { 'retry-after': '3600' } }));
  await expect(retrieveArxiv(asset(3), 1024, false, never)).rejects.toThrow('arXiv is busy');
  const blocked = serve(() => ({}));
  await expect(retrieveArxiv(asset(4), 1024, false, never)).rejects.toThrow('arXiv is busy');
  expect(blocked.requests).toHaveLength(0);
 });

 it('a refusal (403) stops every arXiv request from this browser for a day, kept across reloads', async () => {
  const stored = new Map<string, string>();
  vi.stubGlobal('localStorage', { getItem: (k: string) => stored.get(k) ?? null, setItem: (k: string, v: string) => { stored.set(k, v); }, removeItem: (k: string) => { stored.delete(k); } });
  serve(() => ({ status: 403 }));
  await expect(retrieveArxiv(base, 1024, true, never)).rejects.toThrow('arXiv refused requests from this browser');
  expect(Number(stored.get(ARXIV_REFUSAL.key))).toBe(Date.now() + ARXIV_REFUSAL.pauseMs);
  const after = serve(() => ({}));
  await vi.advanceTimersByTimeAsync(ARXIV_REFUSAL.pauseMs - 1000);
  await expect(retrieveArxiv(asset(1), 1024, false, never)).rejects.toThrow('arXiv refused');
  expect(after.requests).toHaveLength(0);
  // A reload forgets this tab's memory, not the stored refusal.
  const until = stored.get(ARXIV_REFUSAL.key)!;
  resetArxivPacing(); stored.set(ARXIV_REFUSAL.key, until);
  await expect(retrieveArxiv(asset(2), 1024, false, never)).rejects.toThrow('arXiv refused');
  expect(after.requests).toHaveLength(0);
  // A day after the refusal the browser asks again.
  await vi.advanceTimersByTimeAsync(1000);
  await retrieveArxiv(asset(3), 1024, false, never);
  expect(after.requests).toEqual([asset(3)]);
  // A record more than a day ahead was not written by this code and stops nothing.
  resetArxivPacing(); stored.set(ARXIV_REFUSAL.key, String(Date.now() + 10 * ARXIV_REFUSAL.pauseMs));
  await retrieveArxiv(asset(4), 1024, false, never);
  expect(after.requests).toEqual([asset(3), asset(4)]);
 });

 it('says a version without arXiv HTML is its PDF only, and a busy arXiv is not a reason to offer the PDF (build 57)', async () => {
  serve(url => url === base ? { status: 404, type: 'text/html' } : { status: 503, type: 'text/html' });
  const missing = await retrieveArxiv(base, 1024, true, never).catch(e => e);
  expect(missing).toBeInstanceOf(ArxivReaderError);
  expect([missing.kind, missing.message]).toEqual(['no-html', expect.stringContaining('web version')]);
  const asset404 = await retrieveArxiv(asset(1), 1024, false, new AbortController().signal).catch(e => e);
  expect(asset404.kind).toBe('network');
 });

 it('an image arXiv doesn’t serve is missing, and the paper’s other images still come (revision 16)', async () => {
  serve(url => url.endsWith('x1.png') ? { status: 404 } : url.endsWith('x2.png') ? { type: 'text/html' } : {});
  const inputs = await fetchArxivAssets([asset(0), asset(1), asset(2), asset(3)], base, 1 << 20, never);
  expect(inputs.map(i => 'missing' in i ? 'missing' : 'bytes')).toEqual(['bytes', 'missing', 'missing', 'bytes']);
  // A server error is not the image's own: the preparation stops and can be tried again.
  serve(url => url.endsWith('x1.png') ? { status: 500 } : {});
  await expect(fetchArxivAssets([asset(0), asset(1)], base, 1 << 20, never)).rejects.toMatchObject({ kind: 'prepare' });
 });

 it('refuses redirects, wrong types and oversized bodies, and stops the other assets after one failure', async () => {
  serve(url => url.endsWith('x1.png') ? { url: 'https://arxiv.org/html/2305.18290v4/x1.png' } : url.endsWith('x2.png') ? { type: 'text/html' } : { body: new Uint8Array(2000) });
  await expect(retrieveArxiv(asset(1), 1024, false, never)).rejects.toThrow('didn’t return this version’s HTML');
  await expect(retrieveArxiv(asset(2), 1024, false, never)).rejects.toThrow('didn’t return this version’s HTML');
  await expect(retrieveArxiv(asset(3), 1024, false, never)).rejects.toThrow('preparation limits');
  const gates: (() => void)[] = [];
  const fake = serve(url => url.endsWith('x0.png') ? { body: new Uint8Array(2000) } : { release: new Promise<void>(resolve => { gates.push(resolve); }) });
  const inputs = fetchArxivAssets([asset(0), asset(1), asset(2), asset(3), asset(4), asset(5)], base, 1024, never);
  await expect(inputs).rejects.toBeInstanceOf(ArxivReaderError);
  for (const gate of gates) gate();
  await vi.advanceTimersByTimeAsync(0);
  expect(fake.requests.length).toBeLessThanOrEqual(ARXIV_PACING.assetConcurrency);
 });

 it('admits only exact-revision image paths and bounded, unique asset lists', async () => {
  expect(admitsArxivAsset(asset(1), base)).toBe(true);
  for (const bad of ['https://arxiv.org/html/2305.18290v4/x.png', `${base}/../x.png`, `${base}/x.pdf`, `${base}/x.png?x=1`, 'http://arxiv.org/html/2305.18290v3/x.png', `${base}/%2e%2e/x.png`])
   expect(admitsArxivAsset(bad, base)).toBe(false);
  await expect(fetchArxivAssets([asset(1), asset(1)], base, 1024, never)).rejects.toThrow('Invalid paper assets');
  await expect(fetchArxivAssets(['https://evil.example/x.png'], base, 1024, never)).rejects.toThrow('Invalid paper assets');
  await expect(fetchArxivAssets('x', base, 1024, never)).rejects.toThrow('Invalid paper assets');
 });
});

describe('shared preparation', () => {
 it('runs one preparation per source while anyone waits, and stops only when every caller leaves', async () => {
  const registry = new Map();
  let starts = 0, aborted: unknown = null;
  const bundle = { manifestSHA256: 'x' } as never;
  let finish!: (value: never) => void;
  const start = (signal: AbortSignal, progress: (n: number) => void) => { starts++; progress(0.5);
   return new Promise<never>((resolve, reject) => { finish = resolve; signal.addEventListener('abort', () => { aborted = signal.reason; reject(signal.reason); }); }); };
  const a = new AbortController(), b = new AbortController(), seen: number[] = [];
  const first = shareInflight(registry, 'k', start, a.signal, n => seen.push(n));
  const second = shareInflight(registry, 'k', start, b.signal, n => seen.push(n));
  expect(starts).toBe(1); expect(registry.size).toBe(1);
  a.abort(new Error('left'));
  await expect(first).rejects.toThrow('left');
  expect(aborted).toBeNull();
  finish(bundle);
  await expect(second).resolves.toBe(bundle);
  await Promise.resolve();
  expect(registry.size).toBe(0);
  const c = new AbortController();
  const third = shareInflight(registry, 'k', start, c.signal);
  expect(starts).toBe(2);
  c.abort(new Error('gone'));
  await expect(third).rejects.toThrow('gone');
  expect(aborted).toBeInstanceOf(Error);
  await Promise.resolve();
  expect(registry.size).toBe(0);
  expect(seen).toEqual([0.5, 0.5]);
 });
});

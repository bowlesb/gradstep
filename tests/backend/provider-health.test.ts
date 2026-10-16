// Provider health (docs/architecture/RESILIENCE.md, migration 073): every provider call classified and counted, a
// breaker that answers for an open provider at once with an unbilled 429, and fault drills that reach only the account
// they name. No URL path, query, body or account is ever recorded.
import test from 'node:test';
import assert from 'node:assert/strict';
import { breakerVerdict, classifyStatus, noteBreaker, providerFetch, providerForHost, resetBreakers, retryAfterSeconds, routeName,
  rpcFaultSource, rpcRecorder, syntheticResponse, type ActiveFault, type HealthEvent } from '../../supabase/functions/_shared/provider-health.ts';
import { createAnthropicClient, priceAttempts, retryOnceWhenBusy, streamChat } from '../../supabase/functions/_shared/anthropic.ts';

const ANTHROPIC = 'https://api.anthropic.com/v1/messages';
const ok = (status = 200, headers: Record<string, string> = {}) => new Response('{}', { status, headers });
function harness(options: { inner?: (input: unknown) => Promise<Response>; faults?: ActiveFault[]; enabled?: boolean; account?: string | null;
  random?: number; route?: string } = {}) {
  const events: HealthEvent[] = [], sent: string[] = [];
  let clock = 1_000_000;
  const fetcher = providerFetch((async (input: unknown) => { sent.push(String(input)); return options.inner ? options.inner(input) : ok(); }) as typeof fetch, {
    route: options.route ?? 'chat', now: () => clock, random: () => options.random ?? 0,
    record: async event => { events.push(event); return null; },
    account: () => options.account ?? null, faults: async () => options.faults ?? [], faultsEnabled: () => options.enabled ?? false,
  });
  return { fetcher, events, sent, tick: (ms: number) => { clock += ms; }, now: () => clock };
}

test('hosts, outcomes, Retry-After and route names', () => {
  assert.equal(providerForHost('api.anthropic.com'), 'anthropic');
  assert.equal(providerForHost('API.DeepSeek.com.'), 'deepseek');
  assert.equal(providerForHost('aiplatform.googleapis.com'), 'google');
  assert.equal(providerForHost('huggingface.co'), 'huggingface');
  for (const host of ['coxhjvqpflgxkleydati.supabase.co', 'iamcredentials.googleapis.com', 'anthropic.com.evil.test', 'notarxiv.org']) {
    assert.equal(providerForHost(host), null, host);
  }
  // arXiv is counted (never called): the egress counter of ARXIV_DEVICE_ONLY.md §6.5.
  for (const host of ['arxiv.org', 'export.arxiv.org', 'OAIPMH.arxiv.org.']) assert.equal(providerForHost(host), 'arxiv', host);
  assert.deepEqual([200, 304, 400, 404, 408, 429, 500, 502, 503, 504, 529].map(classifyStatus),
    ['ok', 'ok', 'rejected', 'rejected', 'timeout', 'throttled', 'server_error', 'server_error', 'overloaded', 'timeout', 'overloaded']);
  assert.equal(retryAfterSeconds('12'), 12);
  assert.equal(retryAfterSeconds('999999999'), 86_400);
  assert.equal(retryAfterSeconds(new Date(1_000_000 + 30_000).toUTCString(), 1_000_000), 30);
  assert.equal(retryAfterSeconds('soon'), null);
  assert.equal(routeName('pipeline-worker/podcast'), 'pipeline_worker_podcast');
  assert.equal(routeName('---'), 'server');
});

test('every provider call is counted once with its class and latency; anything else passes through untouched', async () => {
  resetBreakers();
  const h = harness({ inner: async input => String(input).includes('crossref') ? ok(429, { 'retry-after': '7' }) : ok() });
  await h.fetcher(ANTHROPIC, { method: 'POST' });
  await h.fetcher('https://api.crossref.org/works/10.1/x?mailto=a@b');
  await h.fetcher('https://coxhjvqpflgxkleydati.supabase.co/rest/v1/rpc/x');
  assert.deepEqual(h.events.map(e => [e.provider, e.route, e.outcome, e.retryAfterS]), [['anthropic', 'chat', 'ok', null], ['crossref', 'chat', 'throttled', 7]]);
  assert.equal(h.sent.length, 3, 'all three requests went out');
  assert.ok(!JSON.stringify(h.events).includes('10.1') && !JSON.stringify(h.events).includes('mailto'), 'no path or query is recorded');
});

test('a timeout is the provider\'s; the reader leaving is nobody\'s', async () => {
  resetBreakers();
  const timeout = harness({ inner: async () => { throw new DOMException('slow', 'TimeoutError'); } });
  await assert.rejects(timeout.fetcher(ANTHROPIC));
  const transport = harness({ inner: async () => { throw new TypeError('reset'); } });
  await assert.rejects(transport.fetcher(ANTHROPIC));
  const deadline = harness({ inner: async () => { throw new DOMException('aborted', 'AbortError'); } });
  await assert.rejects(deadline.fetcher(ANTHROPIC, { signal: AbortSignal.abort(new DOMException('deadline', 'TimeoutError')) }));
  const left = harness({ inner: async () => { throw new DOMException('aborted', 'AbortError'); } });
  const controller = new AbortController(); controller.abort();
  await assert.rejects(left.fetcher(ANTHROPIC, { signal: controller.signal }));
  assert.deepEqual([timeout.events[0].outcome, transport.events[0].outcome, deadline.events[0].outcome, left.events.length], ['timeout', 'transport', 'timeout', 0]);
});

test('an attempt to reach arXiv is counted as refused (our request, not a provider failure) and still refused', async () => {
  resetBreakers();
  const blocked = Object.assign(new Error('arxiv_egress_blocked'), { code: 'arxiv_egress_blocked' });
  const h = harness({ route: 'discover', inner: async () => { throw blocked; } });
  await assert.rejects(h.fetcher('https://export.arxiv.org/api/query?id_list=2305.18290'), /arxiv_egress_blocked/);
  assert.deepEqual(h.events.map(e => [e.provider, e.route, e.outcome]), [['arxiv', 'discover', 'rejected']]);
  assert.ok(!JSON.stringify(h.events).includes('2305'), 'no path or query is recorded');
});

test('an open breaker answers at once with an unbilled 429 and its cool-off; then one probe; a close lets everything through', async () => {
  resetBreakers();
  const h = harness();
  noteBreaker({ provider: 'anthropic', state: 'open', reopenAt: h.now() + 30_000 });
  const fast = await h.fetcher(ANTHROPIC);
  assert.deepEqual([fast.status, fast.headers.get('retry-after'), fast.headers.get('x-gradstep-synthetic')], [429, '30', 'breaker-open']);
  assert.equal(h.sent.length, 0, 'nothing reached the provider');
  assert.deepEqual([h.events[0].outcome, h.events[0].latencyMs], ['breaker_open', 0]);
  // The SDK reads it as a 429 refusal: nothing billed, and too long to retry inside the answer.
  const client = createAnthropicClient({ apiKey: 'test-key', maxRetries: 0, fetch: h.fetcher });
  const outcome = await streamChat(client, { model: 'claude-sonnet-5-5', max_tokens: 10, messages: [{ role: 'user', content: 'hi' }] },
    { signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 100 });
  assert.deepEqual([outcome.status, outcome.httpStatus, outcome.attempts.length], ['failed', 429, 0]);
  assert.ok(outcome.retryAfterMs! >= 29_000);
  h.tick(31_000);
  assert.deepEqual(breakerVerdict('anthropic', h.now()), { allow: true, probe: true }, 'the cool-off over: one probe');
  assert.equal(breakerVerdict('anthropic', h.now()).allow, false, 'not two at once');
  h.tick(31_000);
  assert.equal(breakerVerdict('anthropic', h.now()).allow, true, 'a probe that never answered stops blocking after 30 s');
  noteBreaker({ provider: 'anthropic', state: 'closed', reopenAt: null });
  assert.deepEqual(breakerVerdict('anthropic', h.now()), { allow: true, probe: false });
  // A failed probe's new cool-off starts a new probe window.
  noteBreaker({ provider: 'deepseek', state: 'open', reopenAt: h.now() - 1 });
  assert.equal(breakerVerdict('deepseek', h.now()).allow, true);
  noteBreaker({ provider: 'deepseek', state: 'open', reopenAt: h.now() + 60_000 });
  h.tick(60_001);
  assert.equal(breakerVerdict('deepseek', h.now()).allow, true, 'the next cool-off ends with its own probe');
  resetBreakers();
});

test('fault drills reach only the named account, only where enabled, at their rate and on their route', async () => {
  resetBreakers();
  const throttle: ActiveFault = { provider: 'anthropic', route: null, mode: 'throttle', rate: 1 };
  const off = harness({ faults: [throttle], enabled: false, account: 'a' });
  assert.equal((await off.fetcher(ANTHROPIC)).status, 200, 'FAULT_INJECTION off: real call');
  const noAccount = harness({ faults: [throttle], enabled: true, account: null });
  assert.equal((await noAccount.fetcher(ANTHROPIC)).status, 200, 'no account: real call');
  const on = harness({ faults: [throttle], enabled: true, account: 'a' });
  const faulted = await on.fetcher(ANTHROPIC);
  assert.deepEqual([faulted.status, faulted.headers.get('x-gradstep-synthetic'), on.sent.length, on.events[0].outcome, on.events[0].drill], [429, 'fault-throttle', 0, 'throttled', true]);
  const otherRoute = harness({ faults: [{ ...throttle, route: 'pipeline_worker_podcast' }], enabled: true, account: 'a' });
  assert.equal((await otherRoute.fetcher(ANTHROPIC)).status, 200, 'another route is untouched');
  const rare = harness({ faults: [{ ...throttle, rate: 0.25 }], enabled: true, account: 'a', random: 0.5 });
  assert.equal((await rare.fetcher(ANTHROPIC)).status, 200, 'a draw above the rate is a real call');
  const overload = harness({ faults: [{ ...throttle, mode: 'overload' }], enabled: true, account: 'a' });
  assert.equal((await overload.fetcher(ANTHROPIC)).status, 529, 'Anthropic overloaded is a 529');
  const google = harness({ faults: [{ ...throttle, provider: 'google', mode: 'overload' }], enabled: true, account: 'a' });
  assert.equal((await google.fetcher('https://aiplatform.googleapis.com/v1/x')).status, 503);
  const timeout = harness({ faults: [{ ...throttle, mode: 'timeout' }], enabled: true, account: 'a' });
  await assert.rejects(timeout.fetcher(ANTHROPIC), (error: Error) => error.name === 'TimeoutError');
  const malformed = harness({ faults: [{ ...throttle, mode: 'malformed' }], enabled: true, account: 'a' });
  await assert.rejects((await malformed.fetcher(ANTHROPIC)).json(), 'an unreadable body');
  assert.equal(syntheticResponse('tavily', 'error', 5).status, 500);
});

test('a throttle drill on chat, as scripts/fault-drill.mjs sees it: one retry after its Retry-After, two drill rows, nothing sent or billed', async () => {
  resetBreakers();
  const h = harness({ faults: [{ provider: 'anthropic', route: 'chat', mode: 'throttle', rate: 1 }], enabled: true, account: 'a' });
  const client = createAnthropicClient({ apiKey: 'test-key', maxRetries: 0, fetch: h.fetcher });
  const waits: number[] = [];
  const generate = retryOnceWhenBusy((params, options: { signal: AbortSignal }) => streamChat(client, params, { ...options, onText: () => {}, inputEstimateTokens: 100 }),
    { sleep: async ms => { waits.push(ms); } });
  const outcome = await generate({ model: 'claude-sonnet-5-5', max_tokens: 10, messages: [{ role: 'user', content: 'Reply with the single word OK.' }] },
    { signal: new AbortController().signal });
  assert.deepEqual([outcome.status, outcome.httpStatus, outcome.retryAfterMs, priceAttempts(outcome.attempts)], ['failed', 429, 5_000, 0]);
  assert.deepEqual(waits, [5_000], 'the drill\'s Retry-After (5 s) is inside the retry bound');
  assert.deepEqual(h.events.map(e => [e.provider, e.outcome, e.drill]), [['anthropic', 'throttled', true], ['anthropic', 'throttled', true]]);
  assert.equal(h.sent.length, 0, 'nothing reached Anthropic');
});

test('streamed drills (2026-10-16): midstream fails as overloaded after its first text; slow writes until Stop; both carry a drill- request id', async () => {
  resetBreakers();
  const params = { model: 'claude-haiku-5-5', max_tokens: 100, messages: [{ role: 'user' as const, content: 'Reply with the single word OK.' }] };
  const mid = harness({ faults: [{ provider: 'anthropic', route: 'chat', mode: 'midstream', rate: 1 }], enabled: true, account: 'a' });
  const received: string[] = [];
  const failed = await streamChat(createAnthropicClient({ apiKey: 'test-key', maxRetries: 0, fetch: mid.fetcher }), params,
    { signal: new AbortController().signal, onText: t => received.push(t), inputEstimateTokens: 100 });
  assert.equal(received.join(''), 'This answer comes from a Gradstep fault drill and stops partway');
  assert.deepEqual([failed.status, failed.failure, failed.exact, failed.model], ['failed', 'provider_error', false, 'claude-haiku-5-5']);
  assert.match(String(failed.messageID), /^msg_drill_[0-9a-f]{32}$/, 'the message started: a mid-stream failure');
  assert.match(String(failed.requestID), /^drill-[0-9a-f-]{36}$/);
  assert.deepEqual(mid.events.map(e => [e.outcome, e.drill]), [['transport', true]]); assert.equal(mid.sent.length, 0, 'nothing reached Anthropic');

  const slow = harness({ faults: [{ provider: 'anthropic', route: 'chat', mode: 'slow', rate: 1 }], enabled: true, account: 'a' });
  const reader = new AbortController(), pieces: string[] = [];
  const stopped = await streamChat(createAnthropicClient({ apiKey: 'test-key', maxRetries: 0, fetch: slow.fetcher }), params,
    { signal: reader.signal, onText: t => { pieces.push(t); if (pieces.length === 2) reader.abort(); }, inputEstimateTokens: 100 });
  assert.deepEqual(pieces, ['Drill sentence 1. ', 'Drill sentence 2. ']);
  assert.deepEqual([stopped.status, stopped.failure, stopped.exact], ['failed', 'aborted', false]);
  assert.match(String(stopped.requestID), /^drill-/); assert.deepEqual(slow.events.map(e => [e.outcome, e.drill]), [['ok', true]]);
  // Elsewhere (no streamed API) they answer as a server error.
  const google = harness({ faults: [{ provider: 'google', route: null, mode: 'midstream', rate: 1 }], enabled: true, account: 'a' });
  assert.equal((await google.fetcher('https://aiplatform.googleapis.com/v1/x')).status, 500);
});

test('the database recorder and fault source: bounded, never throwing, cached', async () => {
  resetBreakers();
  const calls: { name: string; params: Record<string, unknown> }[] = [];
  const client = { rpc: async (name: string, params: Record<string, unknown>) => {
    calls.push({ name, params });
    if (name === 'worker_provider_health') return { data: { provider: 'google', state: 'open', reopen_at: '2030-01-01T00:00:00Z' }, error: null };
    return { data: [{ provider: 'anthropic', route: null, mode: 'throttle', rate: 1 }, { provider: 'x', mode: 'explode' }], error: null };
  } };
  const view = await rpcRecorder(client)({ provider: 'google', route: 'podcast', outcome: 'throttled', latencyMs: 12.6, retryAfterS: 5 });
  assert.deepEqual(view, { provider: 'google', state: 'open', reopenAt: Date.parse('2030-01-01T00:00:00Z') });
  assert.deepEqual(calls[0], { name: 'worker_provider_health', params: { p_provider: 'google', p_route: 'podcast', p_outcome: 'throttled', p_latency_ms: 13, p_retry_after_s: 5 } });
  assert.equal(await rpcRecorder({ rpc: async () => { throw new Error('down'); } })({ provider: 'google', route: 'r', outcome: 'ok', latencyMs: 1, retryAfterS: null }), null);
  assert.equal(await rpcRecorder({ rpc: () => new Promise(() => {}) }, 20)({ provider: 'google', route: 'r', outcome: 'ok', latencyMs: 1, retryAfterS: null }), null, 'a hung database never holds a request');
  let clock = 0;
  const source = rpcFaultSource(client, () => clock);
  assert.deepEqual(await source('a'), [{ provider: 'anthropic', route: null, mode: 'throttle', rate: 1 }], 'malformed rows are dropped');
  await source('a'); clock += 16_000; await source('a');
  assert.equal(calls.filter(c => c.name === 'worker_fault_injection_active').length, 2, 'cached for 15 s');
});

test('our own 429s and 503s say when to ask again; other errors don\'t', async () => {
  const { PublicError } = await import('../../supabase/functions/_shared/http.ts');
  const { errorResponse } = await import('../../supabase/functions/_shared/retry-after.ts');
  const limited = errorResponse(new PublicError(429, 'request_rate_limit'), { 'X-Test': '1' });
  assert.deepEqual([limited.status, limited.headers.get('retry-after'), limited.headers.get('x-test'), await limited.json()],
    [429, '60', '1', { code: 'request_rate_limit', retry_after: 60 }]);
  const busy = errorResponse(new PublicError(503, 'search_busy'), {});
  assert.deepEqual([busy.headers.get('retry-after'), (await busy.json()).retry_after], ['5', 5]);
  const own = errorResponse(new PublicError(503, 'something_new'), {});
  assert.equal(own.headers.get('retry-after'), '10', 'an unlisted 503 waits 10 s');
  const plain = errorResponse(new PublicError(403, 'account_unavailable'), {});
  assert.deepEqual([plain.headers.get('retry-after'), await plain.json()], [null, { code: 'account_unavailable' }]);
});

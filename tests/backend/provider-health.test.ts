// Provider health (docs/architecture/RESILIENCE.md, migration 073): every provider call classified and counted, a
// breaker that answers for an open provider at once with an unbilled 429, and fault drills that reach only the account
// they name. No URL path, query, body or account is ever recorded.
import test from 'node:test';
import assert from 'node:assert/strict';
import { breakerVerdict, classifyError, classifyStatus, noteBreaker, providerFetch, providerForHost, resetBreakers, retryAfterSeconds, routeName,
  rpcFaultSource, rpcRecorder, syntheticResponse, type ActiveFault, type HealthEvent } from '../../supabase/functions/_shared/provider-health.ts';
import { priceAttempts, retryOnceWhenBusy } from '../../supabase/functions/_shared/inference.ts';
import { openRouterChat } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { guardedFetch, ModelEgressBlocked } from '../../supabase/functions/_shared/egress.ts';

// Every model call goes to OpenRouter (owner, 2026-10-18 and 2026-10-21); chat pins Google Vertex for Claude and Gemini.
const ROUTER = 'https://openrouter.ai/api/v1/chat/completions';
const pinned = (endpoint: string) => ({ method: 'POST', body: JSON.stringify({ model: 'm', messages: [{ role: 'user', content: 'x'.repeat(10_000) }],
  provider: { only: [endpoint], allow_fallbacks: false }, user: 'u' }) });
const VERTEX = pinned('google-vertex/us');
const ok = (status = 200, headers: Record<string, string> = {}) => new Response('{}', { status, headers });
const attribution = { accountID: 'aaaaaaaa-0000-4000-8000-000000000001', operationID: 'bbbbbbbb-0000-4000-8000-000000000001',
  attemptID: 'cccccccc-0000-4000-8000-000000000001', feature: 'chat', caller: 'chat', dispatch: async () => true };
const haiku = { model: 'anthropic/claude-haiku-5.5', max_tokens: 10, messages: [{ role: 'user' as const, content: 'Reply with the single word OK.' }] };
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
  assert.equal(providerForHost('openrouter.ai'), 'openrouter');
  assert.equal(providerForHost('OpenRouter.AI.'), 'openrouter');
  assert.equal(providerForHost('huggingface.co'), 'huggingface');
  // Direct model hosts are not providers: the egress guard refuses them before any request (OpenRouter only).
  for (const host of ['api.anthropic.com', 'API.DeepSeek.com.', 'aiplatform.googleapis.com', 'coxhjvqpflgxkleydati.supabase.co',
    'iamcredentials.googleapis.com', 'openrouter.ai.evil.test', 'notarxiv.org']) {
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
  await h.fetcher(ROUTER, VERTEX);
  await h.fetcher('https://api.crossref.org/works/10.1/x?mailto=a@b');
  await h.fetcher('https://coxhjvqpflgxkleydati.supabase.co/rest/v1/rpc/x');
  assert.deepEqual(h.events.map(e => [e.provider, e.route, e.outcome, e.retryAfterS]), [['openrouter', 'chat', 'ok', null], ['crossref', 'chat', 'throttled', 7]]);
  assert.equal(h.sent.length, 3, 'all three requests went out');
  assert.ok(!JSON.stringify(h.events).includes('10.1') && !JSON.stringify(h.events).includes('mailto'), 'no path or query is recorded');
});

test('a timeout is the provider\'s; the reader leaving is nobody\'s', async () => {
  resetBreakers();
  const timeout = harness({ inner: async () => { throw new DOMException('slow', 'TimeoutError'); } });
  await assert.rejects(timeout.fetcher(ROUTER, VERTEX));
  const transport = harness({ inner: async () => { throw new TypeError('reset'); } });
  await assert.rejects(transport.fetcher(ROUTER, VERTEX));
  const deadline = harness({ inner: async () => { throw new DOMException('aborted', 'AbortError'); } });
  await assert.rejects(deadline.fetcher(ROUTER, { ...VERTEX, signal: AbortSignal.abort(new DOMException('deadline', 'TimeoutError')) }));
  const left = harness({ inner: async () => { throw new DOMException('aborted', 'AbortError'); } });
  const controller = new AbortController(); controller.abort();
  await assert.rejects(left.fetcher(ROUTER, { ...VERTEX, signal: controller.signal }));
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

test('a direct model host is refused by the egress guard and counted under no provider (never a health row or breaker)', async () => {
  resetBreakers();
  const logs: string[] = [];
  const guarded = guardedFetch((async () => ok()) as typeof fetch, 'chat', { log: line => logs.push(line) });
  const h = harness({ inner: input => guarded(input as string) });
  await assert.rejects(h.fetcher('https://api.anthropic.com/v1/messages', { method: 'POST', body: '{"secret":"x"}' }), ModelEgressBlocked);
  await assert.rejects(h.fetcher('https://texttospeech.googleapis.com/v1/text:synthesize'), ModelEgressBlocked);
  assert.deepEqual(h.events, [], 'no provider row for a request that never left');
  assert.equal(classifyError(new ModelEgressBlocked()), 'rejected', 'our refusal, never a provider failure');
  assert.deepEqual(logs.map(line => JSON.parse(line)), [{ event: 'model_egress_blocked', host: 'api.anthropic.com', caller: 'chat' },
    { event: 'model_egress_blocked', host: 'texttospeech.googleapis.com', caller: 'chat' }], 'the host and caller only; never a path or body');
});

test('an open breaker answers at once with an unbilled 429 and its cool-off; then one probe; a close lets everything through', async () => {
  resetBreakers();
  const h = harness();
  noteBreaker({ provider: 'openrouter', scope: 'chat_vertex', state: 'open', reopenAt: h.now() + 30_000 });
  const fast = await h.fetcher(ROUTER, VERTEX);
  assert.deepEqual([fast.status, fast.headers.get('retry-after'), fast.headers.get('x-gradstep-synthetic')], [429, '30', 'breaker-open']);
  assert.equal(h.sent.length, 0, 'nothing reached the provider');
  assert.deepEqual([h.events[0].outcome, h.events[0].latencyMs], ['breaker_open', 0]);
  // The OpenRouter adapter reads it as a 429 refusal: nothing billed, and too long to retry inside the answer.
  const outcome = await openRouterChat({ apiKey: 'test-key', fetch: h.fetcher })(haiku,
    { attribution, signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 100 });
  assert.deepEqual([outcome.status, outcome.httpStatus, outcome.attempts.length, outcome.exact], ['failed', 429, 0, true]);
  assert.ok(outcome.retryAfterMs! >= 29_000);
  assert.equal(h.sent.length, 0, 'still nothing sent');
  h.tick(31_000);
  assert.deepEqual(breakerVerdict('openrouter', h.now(), 'chat_vertex'), { allow: true, probe: true }, 'the cool-off over: one probe');
  assert.equal(breakerVerdict('openrouter', h.now(), 'chat_vertex').allow, false, 'not two at once');
  h.tick(31_000);
  assert.equal(breakerVerdict('openrouter', h.now(), 'chat_vertex').allow, true, 'a probe that never answered stops blocking after 30 s');
  noteBreaker({ provider: 'openrouter', scope: 'chat_vertex', state: 'closed', reopenAt: null });
  assert.deepEqual(breakerVerdict('openrouter', h.now(), 'chat_vertex'), { allow: true, probe: false });
  // A failed probe's new cool-off starts a new probe window.
  noteBreaker({ provider: 'openrouter', scope: 'chat_deepinfra', state: 'open', reopenAt: h.now() - 1 });
  assert.equal(breakerVerdict('openrouter', h.now(), 'chat_deepinfra').allow, true);
  noteBreaker({ provider: 'openrouter', scope: 'chat_deepinfra', state: 'open', reopenAt: h.now() + 60_000 });
  h.tick(60_001);
  assert.equal(breakerVerdict('openrouter', h.now(), 'chat_deepinfra').allow, true, 'the next cool-off ends with its own probe');
  // A retired provider's breaker row (history) is not a breaker this server keeps.
  noteBreaker({ provider: 'anthropic' as never, state: 'open', reopenAt: h.now() + 60_000 });
  assert.equal(breakerVerdict('anthropic' as never, h.now()).allow, true);
  resetBreakers();
});

test('fault drills reach only the named account, only where enabled, at their rate and on their route', async () => {
  resetBreakers();
  const throttle: ActiveFault = { provider: 'openrouter', route: null, mode: 'throttle', rate: 1 };
  const off = harness({ faults: [throttle], enabled: false, account: 'a' });
  assert.equal((await off.fetcher(ROUTER, VERTEX)).status, 200, 'FAULT_INJECTION off: real call');
  const noAccount = harness({ faults: [throttle], enabled: true, account: null });
  assert.equal((await noAccount.fetcher(ROUTER, VERTEX)).status, 200, 'no account: real call');
  const on = harness({ faults: [throttle], enabled: true, account: 'a' });
  const faulted = await on.fetcher(ROUTER, VERTEX);
  assert.deepEqual([faulted.status, faulted.headers.get('x-gradstep-synthetic'), on.sent.length, on.events[0].outcome, on.events[0].drill], [429, 'fault-throttle', 0, 'throttled', true]);
  const otherRoute = harness({ faults: [{ ...throttle, route: 'pipeline_worker_podcast' }], enabled: true, account: 'a' });
  assert.equal((await otherRoute.fetcher(ROUTER, VERTEX)).status, 200, 'another route is untouched');
  const rare = harness({ faults: [{ ...throttle, rate: 0.25 }], enabled: true, account: 'a', random: 0.5 });
  assert.equal((await rare.fetcher(ROUTER, VERTEX)).status, 200, 'a draw above the rate is a real call');
  const overload = harness({ faults: [{ ...throttle, mode: 'overload' }], enabled: true, account: 'a' });
  assert.equal((await overload.fetcher(ROUTER, VERTEX)).status, 503, 'OpenRouter overloaded is a 503');
  const tavily = harness({ faults: [{ ...throttle, provider: 'tavily', mode: 'overload' }], enabled: true, account: 'a' });
  assert.equal((await tavily.fetcher('https://api.tavily.com/search', { method: 'POST', body: '{}' })).status, 503);
  const timeout = harness({ faults: [{ ...throttle, mode: 'timeout' }], enabled: true, account: 'a' });
  await assert.rejects(timeout.fetcher(ROUTER, VERTEX), (error: Error) => error.name === 'TimeoutError');
  const malformed = harness({ faults: [{ ...throttle, mode: 'malformed' }], enabled: true, account: 'a' });
  await assert.rejects((await malformed.fetcher(ROUTER, VERTEX)).json(), 'an unreadable body');
  assert.equal(syntheticResponse('tavily', 'error', 5).status, 500);
});

test('a throttle drill on chat, as scripts/fault-drill.mjs sees it: one retry after its Retry-After, two drill rows, nothing sent or billed', async () => {
  resetBreakers();
  const h = harness({ faults: [{ provider: 'openrouter', route: 'chat', mode: 'throttle', rate: 1 }], enabled: true, account: 'a' });
  const waits: number[] = [];
  const generate = retryOnceWhenBusy((params, options: { signal: AbortSignal }) => openRouterChat({ apiKey: 'test-key', fetch: h.fetcher })(params,
    { ...options, attribution, onText: () => {}, inputEstimateTokens: 100 }), { sleep: async ms => { waits.push(ms); } });
  const outcome = await generate(haiku, { signal: new AbortController().signal });
  assert.deepEqual([outcome.status, outcome.httpStatus, outcome.retryAfterMs, priceAttempts(outcome.attempts)], ['failed', 429, 5_000, 0]);
  assert.deepEqual(waits, [5_000], 'the drill\'s Retry-After (5 s) is inside the retry bound');
  assert.deepEqual(h.events.map(e => [e.provider, e.outcome, e.drill, e.scope]), [['openrouter', 'throttled', true, 'chat_vertex'], ['openrouter', 'throttled', true, 'chat_vertex']]);
  assert.equal(h.sent.length, 0, 'nothing reached OpenRouter');
});

test('streamed drills answer as a server error where no stream is spoken (Tavily)', async () => {
  resetBreakers();
  const tavily = harness({ faults: [{ provider: 'tavily', route: null, mode: 'midstream', rate: 1 }], enabled: true, account: 'a' });
  assert.equal((await tavily.fetcher('https://api.tavily.com/search', { method: 'POST', body: '{}' })).status, 500);
});

test('the database recorder and fault source: bounded, never throwing, cached', async () => {
  resetBreakers();
  const calls: { name: string; params: Record<string, unknown> }[] = [];
  const client = { rpc: async (name: string, params: Record<string, unknown>) => {
    calls.push({ name, params });
    if (name === 'worker_provider_health') return { data: { provider: 'tavily', state: 'open', reopen_at: '2030-01-01T00:00:00Z' }, error: null };
    return { data: [{ provider: 'openrouter', route: null, mode: 'throttle', rate: 1 }, { provider: 'x', mode: 'explode' }], error: null };
  } };
  const view = await rpcRecorder(client)({ provider: 'tavily', route: 'podcast', outcome: 'throttled', latencyMs: 12.6, retryAfterS: 5 });
  assert.deepEqual(view, { provider: 'tavily', state: 'open', reopenAt: Date.parse('2030-01-01T00:00:00Z') });
  assert.deepEqual(calls[0], { name: 'worker_provider_health', params: { p_provider: 'tavily', p_route: 'podcast', p_outcome: 'throttled', p_latency_ms: 13, p_retry_after_s: 5 } });
  assert.equal(await rpcRecorder({ rpc: async () => { throw new Error('down'); } })({ provider: 'tavily', route: 'r', outcome: 'ok', latencyMs: 1, retryAfterS: null }), null);
  assert.equal(await rpcRecorder({ rpc: () => new Promise(() => {}) }, 20)({ provider: 'tavily', route: 'r', outcome: 'ok', latencyMs: 1, retryAfterS: null }), null, 'a hung database never holds a request');
  let clock = 0;
  const source = rpcFaultSource(client, () => clock);
  assert.deepEqual(await source('a'), [{ provider: 'openrouter', route: null, mode: 'throttle', rate: 1 }], 'malformed rows are dropped');
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

// Review D4: drills reach OpenRouter (the only model gateway) with its own stream format, through the real adapter.
test('D4: OpenRouter midstream and slow drills stream in its format; a drill generation is never looked up for real', async () => {
  resetBreakers();
  const real: string[] = [];
  const drill = (mode: 'midstream' | 'slow') => providerFetch((async (input: unknown) => { real.push(String(input)); return ok(); }) as typeof fetch, {
    route: 'chat', account: () => 'test-account', faultsEnabled: () => true, random: () => 0, record: async () => null,
    faults: async () => [{ provider: 'openrouter', route: null, mode, rate: 1 }] });
  const params = { model: 'anthropic/claude-haiku-5.5', max_tokens: 200, messages: [{ role: 'user' as const, content: 'hi' }] };
  let text = '';
  const midstream = await openRouterChat({ apiKey: 'k', fetch: drill('midstream'), sleep: async () => {} })(params,
    { attribution, signal: new AbortController().signal, inputEstimateTokens: 10, onText: s => { text += s; } });
  assert.match(text, /fault drill/); assert.equal(midstream.status, 'failed'); assert.equal(midstream.failure, 'provider_error');
  assert.match(midstream.requestID ?? '', /^drill-/, 'the drill id is kept for reconciliation to zero');
  const controller = new AbortController(); text = '';
  const stopped = await openRouterChat({ apiKey: 'k', fetch: drill('slow'), sleep: async () => {} })(params,
    { attribution, signal: controller.signal, inputEstimateTokens: 10, onText: s => { text += s; if (text.length > 30) controller.abort(); } });
  assert.equal(stopped.failure, 'aborted'); assert.ok((stopped.attempts[0].readerMicrousd ?? 0) > 0, 'a stopped drill is charged for what it wrote');
  assert.deepEqual(real, [], 'no request reached OpenRouter, not even a receipt read');
});

// Review A13 (migration 0106): OpenRouter carries every model, so its breakers are scoped by route and upstream.
import { breakerScope } from '../../supabase/functions/_shared/provider-health.ts';
test('A13: OpenRouter breakers are scoped by the calling route and the pinned upstream; others keep one per provider', async () => {
  assert.equal(breakerScope('openrouter', 'chat', ROUTER, pinned('google-vertex/us')), 'chat_vertex');
  assert.equal(breakerScope('openrouter', 'chat', ROUTER, pinned('deepinfra/fp8')), 'chat_deepinfra');
  assert.equal(breakerScope('openrouter', 'pipeline_worker_podcast', 'https://openrouter.ai/api/v1/audio/speech', { method: 'POST', body: '{}' }), 'podcast_speech');
  assert.equal(breakerScope('openrouter', 'pipeline_worker_run', ROUTER, pinned('google-vertex/us')), 'run_vertex');
  assert.equal(breakerScope('openrouter', 'chat', 'https://openrouter.ai/api/v1/generation?id=g'), 'chat_read');
  assert.equal(breakerScope('tavily', 'chat', 'https://api.tavily.com/search', { method: 'POST', body: '{}' }), '');
  resetBreakers();
  const events: HealthEvent[] = [], sent: string[] = [];
  const fetcher = providerFetch((async (_input: unknown, init?: RequestInit) => { sent.push(String(init?.body).includes('deepinfra') ? 'deepinfra' : 'vertex'); return ok(); }) as typeof fetch,
    { route: 'chat', now: () => 1_000_000, record: async event => { events.push(event); return null; } });
  // A DeepSeek (DeepInfra) outage has opened its own breaker: Claude and Gemini on Google Vertex still answer.
  noteBreaker({ provider: 'openrouter', scope: 'chat_deepinfra', state: 'open', reopenAt: 1_000_000 + 60_000 });
  assert.equal((await fetcher(ROUTER, pinned('deepinfra/fp8'))).status, 429, 'DeepInfra calls fail fast');
  assert.equal((await fetcher(ROUTER, pinned('google-vertex/us'))).status, 200, 'Vertex calls are not blocked');
  assert.deepEqual(sent, ['vertex']);
  assert.deepEqual(events.map(e => [e.outcome, e.scope]), [['breaker_open', 'chat_deepinfra'], ['ok', 'chat_vertex']]);
  assert.ok(!JSON.stringify(events).includes('xxxx'), 'no request content is recorded');
  // The scope reaches the database, which returns the scoped breaker.
  const calls: Record<string, unknown>[] = [];
  const view = await rpcRecorder({ rpc: async (_name, params) => { calls.push(params); return { data: { provider: 'openrouter', scope: 'chat_vertex', state: 'closed', reopen_at: null }, error: null }; } })(events[1]);
  assert.equal(calls[0].p_scope, 'chat_vertex'); assert.deepEqual(view, { provider: 'openrouter', state: 'closed', reopenAt: null, scope: 'chat_vertex' });
  resetBreakers();
});

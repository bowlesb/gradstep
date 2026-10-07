import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { admittedAnthropic, admittedTavily, referenceLookupSpending, type SpendingDependencies } from '../../supabase/functions/_shared/provider-spending.ts';
import { chatRequestParams, createAnthropicClient, holdFor, promptCharacters, streamChat, WEB_SEARCH_TOOL,
  type ProviderOutcome } from '../../supabase/functions/_shared/anthropic.ts';

const accountID = '10000000-0000-4000-8000-000000000001';
const operationID = '20000000-0000-4000-8000-000000000002';
const privateText = 'do-not-record-this-private-prompt-or-query';
const signal = () => new AbortController().signal;
const params = () => chatRequestParams({ instructions: 'Test instructions', paper: null,
  selection: null, turns: [{ role: 'user', text: privateText }] });
function fixture(options: { grant?: boolean; lostGrant?: boolean; lostFinish?: boolean } = {}) {
  const calls: { name: string; params: Record<string, unknown> }[] = [], logs: unknown[] = [];
  const grants = new Set<string>();
  const deps: SpendingDependencies = {
    accountID, operationID, sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'),
    log: entry => logs.push(entry),
    rpc: async (name, args) => {
      calls.push({ name, params: args });
      if (name === 'worker_provider_attempt_begin') {
        if (options.lostGrant) throw new Error('response_lost');
        const fresh = !grants.has(String(args.p_attempt_id)); grants.add(String(args.p_attempt_id));
        return { granted: fresh && options.grant !== false, state: 'admitted' };
      }
      assert.equal(name, 'worker_provider_attempt_finish');
      if (options.lostFinish) throw new Error('response_lost');
      return null;
    },
  };
  return { deps, calls, logs };
}
const complete = (): ProviderOutcome => ({ status: 'complete', failure: null, messageID: 'msg_test', requestID: 'req_test',
  model: 'claude-sonnet-5-5', stopReason: 'end_turn', refusalCategory: null, exact: true,
  attempts: [{ model: 'claude-sonnet-5-5', estimated: false,
    usage: { input: 100, cacheWrite5m: 50, cacheWrite1h: 0, cacheRead: 20, output: 10 } }] });
const streamOptions = () => ({ signal: signal(), onText: () => {}, inputEstimateTokens: 100 });
const searchInput = { query: privateText, academic: true };

test('model request has an exact bound and durable grant before send, with private text absent from records', async () => {
  const h = fixture(); let sent = 0;
  const generate = admittedAnthropic(h.deps, async () => {
    assert.equal(h.calls.at(-1)?.name, 'worker_provider_attempt_begin'); sent++; return complete();
  });
  assert.equal((await generate(params(), streamOptions())).status, 'complete');
  assert.equal(sent, 1);
  const begin = h.calls[0].params, finish = h.calls[1].params;
  assert.equal(begin.p_ceiling_microusd, holdFor(promptCharacters(params()), params().max_tokens).microusd);
  assert.deepEqual(begin.p_reserved_units, { output_tokens: 8000, web_searches: 0 });
  assert.match(String(begin.p_attempt_id), /^[a-f0-9-]{36}$/);
  assert.match(String(begin.p_request_sha256), /^\\x[a-f0-9]{64}$/);
  assert.equal(finish.p_actual_microusd, 429);
  assert.equal(finish.p_provider_request_id, 'req_test');
  assert.equal(finish.p_state, 'succeeded');
  assert.ok(!JSON.stringify([h.calls, h.logs]).includes(privateText));
});

test('rejected, replayed and ambiguously acknowledged model grants never send', async () => {
  for (const opts of [{ grant: false }, { lostGrant: true }]) {
    const h = fixture(opts); let sent = 0;
    const outcome = await admittedAnthropic(h.deps, async () => { sent++; return complete(); })(params(), streamOptions());
    assert.equal(outcome.status, 'failed'); assert.equal(sent, 0); assert.equal(h.calls.length, 1);
  }
  const h = fixture(); let sent = 0;
  const send = async () => { sent++; return complete(); };
  await admittedAnthropic(h.deps, send)(params(), streamOptions());
  await admittedAnthropic(h.deps, send)(params(), streamOptions());
  assert.equal(sent, 1, 'recreated adapter uses the same first-attempt identity');
});

test('production SDK defaults make exactly one POST after a lost response and preserve full unknown liability', async () => {
  const h = fixture(); let posts = 0;
  const client = createAnthropicClient({ apiKey: 'not-real', fetch: (async () => { posts++; throw new TypeError('response lost'); }) as typeof fetch });
  const outcome = await admittedAnthropic(h.deps, (p, o) => streamChat(client, p, o))(params(), streamOptions());
  assert.equal(posts, 1); assert.equal(outcome.exact, false);
  const finish = h.calls.find(call => call.name === 'worker_provider_attempt_finish')!.params;
  assert.equal(finish.p_state, 'unknown'); assert.equal(finish.p_actual_microusd, null);
  assert.ok(Number(h.calls[0].params.p_ceiling_microusd) > 240_000);
});

test('production SDK 5xx remains unknown; explicit validation rejection records known zero', async () => {
  for (const status of [500, 400]) {
    const h = fixture(); let posts = 0;
    const client = createAnthropicClient({ apiKey: 'not-real', fetch: (async () => {
      posts++; return new Response(JSON.stringify({ error: { type: 'test_error', message: 'do not log this' } }), { status });
    }) as typeof fetch });
    await admittedAnthropic(h.deps, (p, o) => streamChat(client, p, o))(params(), streamOptions());
    const finish = h.calls.at(-1)!.params;
    assert.equal(posts, 1); assert.equal(finish.p_state, status === 400 ? 'rejected' : 'unknown');
    assert.equal(finish.p_actual_microusd, status === 400 ? 0 : null);
    assert.ok(!JSON.stringify(h.calls).includes('do not log this'));
  }
});

test('an unrecordable model result stops continuation and retries only the identical finish, never the provider', async () => {
  const h = fixture({ lostFinish: true }); let sent = 0;
  const outcome = await admittedAnthropic(h.deps, async () => { sent++; return complete(); })(params(), streamOptions());
  assert.equal(outcome.status, 'failed'); assert.equal(outcome.exact, false); assert.equal(sent, 1);
  const finishes = h.calls.filter(call => call.name === 'worker_provider_attempt_finish');
  assert.equal(finishes.length, 3); assert.deepEqual(finishes[0].params, finishes[2].params);
  assert.ok(!JSON.stringify(h.logs).includes(privateText));
});

test('native search cannot bypass the missing verified cost bound even when offered by a caller', async () => {
  const h = fixture(); let sent = 0;
  const outcome = await admittedAnthropic(h.deps, async () => { sent++; return complete(); })({ ...params(), tools: [WEB_SEARCH_TOOL] }, streamOptions());
  assert.equal(outcome.status, 'failed'); assert.equal(sent, 0); assert.equal(h.calls.length, 0);
});

test('all paid search routes use the same pre-send unit grant and record actual usage/request ID', async () => {
  for (const route of ['chat_search', 'ingest_lookup', 'reference_lookup'] as const) {
    const h = fixture(); let posts = 0;
    const search = admittedTavily(h.deps, route, (async () => {
      assert.equal(h.calls.at(-1)?.name, 'worker_provider_attempt_begin'); posts++;
      return Response.json({ results: [], usage: { credits: 1 }, request_id: 'req_search_test' });
    }) as typeof fetch, 'not-real');
    assert.equal((await search(searchInput, signal())).status, 'ok');
    assert.equal(posts, 1); assert.equal(h.calls[0].params.p_route, route);
    assert.equal(h.calls[0].params.p_ceiling_microusd, 0);
    assert.deepEqual(h.calls[0].params.p_reserved_units, { credits: 1 });
    assert.equal(h.calls[1].params.p_state, 'succeeded');
    assert.deepEqual(h.calls[1].params.p_actual_units, { credits: 1, searches: 1 });
    assert.equal(h.calls[1].params.p_provider_request_id, 'req_search_test');
    assert.ok(!JSON.stringify([h.calls, h.logs]).includes(privateText));
  }
});

test('search allowance rejection, lost grant and replay never POST', async () => {
  for (const opts of [{ grant: false }, { lostGrant: true }]) {
    const h = fixture(opts); let posts = 0;
    const outcome = await admittedTavily(h.deps, 'reference_lookup', (async () => { posts++; return Response.json({}); }) as typeof fetch, 'key')(searchInput, signal());
    assert.equal(outcome.status, 'failed'); assert.equal(posts, 0);
  }
  const h = fixture(); let posts = 0;
  const fetcher = (async () => { posts++; return Response.json({ results: [], usage: { credits: 1 } }); }) as typeof fetch;
  await admittedTavily(h.deps, 'ingest_lookup', fetcher, 'key')(searchInput, signal());
  await admittedTavily(h.deps, 'ingest_lookup', fetcher, 'key')(searchInput, signal());
  assert.equal(posts, 1);
});

test('search timeout, 5xx, malformed success and missing usage retain the admitted credit without retry', async () => {
  for (const result of ['lost', '5xx', 'malformed', 'no_usage']) {
    const h = fixture(); let posts = 0;
    await admittedTavily(h.deps, 'chat_search', (async () => {
      posts++;
      if (result === 'lost') throw new TypeError('response lost');
      return result === '5xx' ? new Response('{}', { status: 503 }) : Response.json(result === 'no_usage' ? { results: [] } : {});
    }) as typeof fetch, 'key')(searchInput, signal());
    assert.equal(posts, 1); assert.equal(h.calls.at(-1)!.params.p_state, 'unknown');
    assert.equal(h.calls.at(-1)!.params.p_actual_microusd, null);
    assert.deepEqual(h.calls.at(-1)!.params.p_actual_units, {});
  }
});

test('search completion write failure never releases the grant or returns results usable for another request', async () => {
  const h = fixture({ lostFinish: true }); let posts = 0;
  const outcome = await admittedTavily(h.deps, 'chat_search', (async () => {
    posts++; return Response.json({ results: [], usage: { credits: 1 } });
  }) as typeof fetch, 'key')(searchInput, signal());
  assert.equal(posts, 1); assert.equal(outcome.status, 'failed');
  assert.equal(h.calls.filter(call => call.name === 'worker_provider_attempt_finish').length, 3);
});

test('reference lookup stays free for absent/v1 consent or disabled search, with no paid admission', async () => {
  for (const [consentVersion, enabled] of [[undefined, true], ['cloud-ai-v1', true], ['cloud-ai-v2', false]] as const) {
    const h = fixture();
    const lookup = await referenceLookupSpending(h.deps, { reference: privateText, web: true, consentVersion, enabled,
      apiKey: 'key', fetcher: (async () => { throw new Error('no provider call'); }) as typeof fetch });
    assert.equal(lookup.search, undefined); await lookup.finish(); assert.equal(h.calls.length, 0);
  }
});

test('reference lookup reserves zero credits, fences operation replay, and preserves every admitted finder attempt', async () => {
  const h = fixture(); let reserved = false, posts = 0;
  const rpc = h.deps.rpc;
  h.deps.rpc = async (name, args) => {
    if (name === 'worker_reserve_operation') {
      h.calls.push({ name, params: args });
      assert.equal(args.p_credits, 0); assert.equal(args.p_microusd, 0);
      assert.equal(args.p_kind, 'metadata');
      const replayed = reserved; reserved = true; return { replayed };
    }
    if (name === 'worker_settle_operation') {
      h.calls.push({ name, params: args }); assert.equal(args.p_actual_credits, 0); assert.equal(args.p_actual_microusd, 0); return null;
    }
    return rpc(name, args);
  };
  const input = { reference: privateText, web: true, consentVersion: 'cloud-ai-v2', enabled: true, apiKey: 'key',
    fetcher: (async () => { posts++; return Response.json({ results: [], usage: { credits: 1 } }); }) as typeof fetch };
  const lookup = await referenceLookupSpending(h.deps, input);
  for (let i = 0; i < 3; i++) await lookup.search!({ query: `${privateText}-${i}`, academic: true }, signal());
  await lookup.finish();
  const replayed = await referenceLookupSpending(h.deps, input);
  assert.equal(replayed.search, undefined); assert.equal(posts, 3);
  assert.equal(h.calls.filter(call => call.name === 'worker_provider_attempt_begin').length, 3);
  assert.equal(new Set(h.calls.filter(call => call.name === 'worker_provider_attempt_begin').map(call => call.params.p_attempt_id)).size, 3);
  assert.equal(h.calls.filter(call => call.name === 'worker_settle_operation').length, 1);
  assert.ok(!JSON.stringify(h.calls).includes(privateText));
});

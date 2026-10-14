import test from 'node:test';
import assert from 'node:assert/strict';
import { deepseekMessages, deepseekScriptProvider, deepseekUsage } from '../../supabase/functions/_shared/deepseek.ts';
import { draftRequest, DRAFT_SCHEMA, scriptCost } from '../../supabase/functions/_shared/podcast-script.ts';
import { ratesFor } from '../../supabase/functions/_shared/anthropic.ts';

// DeepSeek as a podcast script provider (2026-10-14): the Anthropic-shaped request becomes a chat completion in JSON
// mode with the schema in the system prompt; usage prices from the card's PEAK rates; rejections and transport failures
// are reported the way the Anthropic adapter reports them.
const params = draftRequest('# Paper\n\nA paragraph with a number 42.', 'A title', 6000, 'Write it.', 'deepseek-v4-pro');

test('messages: the system text and the output schema first, each turn as plain text, the spec model', () => {
  const messages = deepseekMessages(params);
  assert.equal(messages[0].role, 'system');
  assert.ok(messages[0].content.startsWith('Write it.')); assert.ok(messages[0].content.includes(JSON.stringify(DRAFT_SCHEMA)));
  assert.equal(messages[1].role, 'user'); assert.match(messages[1].content, /<paper title="A title">/); assert.match(messages[1].content, /Write the episode script/);
  assert.equal(params.model, 'deepseek-v4-pro');
});

test('usage: cache hits are cache reads, misses are input, missing counts are unusable', () => {
  assert.deepEqual(deepseekUsage({ prompt_tokens: 100, completion_tokens: 10, prompt_cache_hit_tokens: 30, prompt_cache_miss_tokens: 70 }),
    { input: 70, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 30, output: 10 });
  assert.deepEqual(deepseekUsage({ prompt_tokens: 100, completion_tokens: 10 }), { input: 100, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 10 });
  assert.equal(deepseekUsage({ prompt_tokens: 100 }), null); assert.equal(deepseekUsage(undefined), null);
  // The card: peak list prices (input 1.32, cache read 0.044, output 3.96 micro-USD per token); flash is cheaper.
  assert.deepEqual(ratesFor('deepseek-v4-pro').rates, { input: 1.32, cacheWrite5m: 1.32, cacheWrite1h: 1.32, cacheRead: 0.044, output: 3.96 });
  assert.equal(ratesFor('deepseek-flash').rates.output, 1.2); assert.equal(ratesFor('deepseek-v4-pro').known, true);
  const cost = scriptCost({ state: 'succeeded', requestID: 'r', model: 'deepseek-v4-pro', stopReason: 'end_turn', text: '{}', failure: null,
    usage: { input: 50_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 10_000, output: 5_000 } });
  assert.equal(cost.microusd, Math.ceil(50_000 * 1.32 + 10_000 * 0.044 + 5_000 * 3.96));
});

function responding(status: number, body: unknown, headers: Record<string, string> = {}) {
  const sent: { url: string; init: RequestInit }[] = [];
  const provider = deepseekScriptProvider({ apiKey: 'test-key', fetch: async (url, init) => {
    sent.push({ url: String(url), init: init! });
    return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });
  } });
  return { provider, sent };
}

test('generate: JSON mode, the spec model, bearer auth; a completion maps to a succeeded result with usage and request id', async () => {
  const { provider, sent } = responding(200, { id: 'cmpl-1', model: 'deepseek-v4-pro', choices: [{ message: { content: '{"title":"x"}' }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 1000, completion_tokens: 50, prompt_cache_hit_tokens: 0, prompt_cache_miss_tokens: 1000 } });
  const result = await provider.generate(params, AbortSignal.timeout(5000));
  assert.equal(sent[0].url, 'https://api.deepseek.com/chat/completions');
  const body = JSON.parse(String(sent[0].init.body));
  assert.equal(body.model, 'deepseek-v4-pro'); assert.deepEqual(body.response_format, { type: 'json_object' }); assert.equal(body.stream, false);
  assert.deepEqual(body.thinking, { type: 'disabled' }, 'no reasoning tokens inside the script allowance');
  assert.equal(body.max_tokens, 6000); assert.equal((sent[0].init.headers as Record<string, string>).authorization, 'Bearer test-key');
  assert.deepEqual(result, { state: 'succeeded', requestID: 'cmpl-1', model: 'deepseek-v4-pro', stopReason: 'end_turn', text: '{"title":"x"}',
    usage: { input: 1000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 50 }, failure: null });
  const cut = responding(200, { id: 'c2', model: 'deepseek-v4-pro', choices: [{ message: { content: '{' }, finish_reason: 'length' }], usage: { prompt_tokens: 1, completion_tokens: 6000 } });
  assert.equal((await cut.provider.generate(params, AbortSignal.timeout(5000))).stopReason, 'max_tokens');
});

test('generate: 4xx before processing is rejected (unbilled); 5xx, unreadable bodies and transport failures are unknown', async () => {
  assert.equal((await responding(429, { error: 'rate' }).provider.generate(params, AbortSignal.timeout(5000))).state, 'rejected');
  assert.equal((await responding(401, { error: 'key' }).provider.generate(params, AbortSignal.timeout(5000))).failure, 'http_401');
  assert.equal((await responding(503, { error: 'down' }).provider.generate(params, AbortSignal.timeout(5000))).state, 'unknown');
  assert.equal((await responding(200, 'not json').provider.generate(params, AbortSignal.timeout(5000))).failure, 'response_unreadable');
  assert.equal((await responding(200, { id: 'c', choices: [] }).provider.generate(params, AbortSignal.timeout(5000))).failure, 'usage_missing');
  const down = deepseekScriptProvider({ apiKey: 'k', fetch: async () => { throw new Error('ECONNRESET'); } });
  assert.deepEqual(await down.generate(params, AbortSignal.timeout(5000)), { state: 'unknown', requestID: null, model: null, stopReason: null, text: null, usage: null, failure: 'transport_unknown' });
  // The count estimate is conservative and never a request.
  const counted = await down.countTokens(params, AbortSignal.timeout(100));
  assert.ok(counted! > 0 && counted! >= Math.ceil(new TextEncoder().encode(JSON.stringify(deepseekMessages(params))).byteLength / 2.5));
});

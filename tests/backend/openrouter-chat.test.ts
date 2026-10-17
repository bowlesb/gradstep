import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import type Anthropic from '@anthropic-ai/sdk';
import { openRouterAttempt, openRouterChat, openRouterChatParams } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { GEMINI_MODEL, GEMINI_OPENROUTER_MODEL, GEMINI_PRICE_EXPIRES } from '../../supabase/functions/_shared/gemini-pricing.ts';
import { chatRequestParams, priceAttempts, holdForParams } from '../../supabase/functions/_shared/anthropic.ts';
import { publishedProfiles, resolveChoice, providerForModel } from '../../supabase/functions/_shared/chat-profiles.ts';
import { validateChatRequest, runChat, type ChatDependencies, type ChatEvent } from '../../supabase/functions/_shared/chat.ts';
import { admittedAnthropic } from '../../supabase/functions/_shared/provider-spending.ts';

const params = chatRequestParams({ instructions: 'rules', paper: { title: 'Paper', text: '[¶1] Paper text.' },
  actionInstructions: 'explain the figure', turns: [{ role: 'user', text: 'What does this mean?' }],
  tools: [{ name: 'search_web', input_schema: { type: 'object', properties: { query: { type: 'string' } } } }],
  model: { id: GEMINI_MODEL, effort: 'medium', fallbacks: false }, maxTokens: 1000 });
const usage = { prompt_tokens: 1000, completion_tokens: 200, prompt_tokens_details: { cached_tokens: 800, cache_write_tokens: 100 }, cost: 0.001 };
const event = (delta: unknown = {}, rest: Record<string, unknown> = {}) => ({ id: 'gen-test', model: GEMINI_OPENROUTER_MODEL,
  choices: [{ delta, finish_reason: null }], ...rest });
const final = (reason = 'stop', bill: unknown = usage) => event({}, { choices: [{ delta: {}, finish_reason: reason }], usage: bill });
function response(events: unknown[], done = true) {
  // Fragment every SSE frame across byte boundaries, including Unicode.
  const bytes = new TextEncoder().encode(events.map(e => `data: ${JSON.stringify(e)}\r\n\r\n`).join('') + (done ? 'data: [DONE]\n\n' : ''));
  return new Response(new ReadableStream({ start(c) { for (let i = 0; i < bytes.length; i += 17) c.enqueue(bytes.slice(i, i + 17)); c.close(); } }));
}
async function run(events: unknown[], done = true) {
  let text = '', sent: Record<string, any> | null = null;
  const generate = openRouterChat({ apiKey: 'test-key', now: () => GEMINI_PRICE_EXPIRES - 1, fetch: async (_url, options) => {
    assert.equal(new Headers(options?.headers).get('X-OpenRouter-Cache'), 'false');
    sent = JSON.parse(String(options?.body)); return response(events, done);
  } });
  const outcome = await generate(params, { signal: new AbortController().signal, inputEstimateTokens: 2000, onText: s => { text += s; } });
  return { outcome, text, sent: sent! };
}

test('Flash translation pins Google, caps prices, preserves the cache prefix and puts action text after it', () => {
  const body = openRouterChatParams(params) as any;
  assert.equal(body.model, GEMINI_OPENROUTER_MODEL);
  assert.deepEqual(body.provider.only, ['google-vertex/us']); assert.equal(body.provider.allow_fallbacks, false);
  assert.equal(body.provider.data_collection, 'deny'); assert.equal(body.provider.require_parameters, true);
  assert.equal(body.provider.zdr, true);
  assert.deepEqual(body.provider.max_price, { prompt: 0.825, completion: 4.125 }); assert.deepEqual(body.reasoning, { effort: 'medium' });
  assert.equal(body.messages[0].content[0].cache_control.ttl, '5m');
  assert.match(body.messages[0].content[0].text, /Paper text/); assert.doesNotMatch(body.messages[0].content[0].text, /explain the figure/);
  assert.equal(body.messages[1].content[0].text, 'explain the figure');
  assert.throws(() => openRouterChatParams({ ...params, tools: [{ type: 'web_search_20250305', name: 'web_search' }] }), /native_tools/);
  const image = { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'aW1hZ2U=' } };
  const pictured = openRouterChatParams({ ...params, messages: [{ role: 'user', content: [image, { type: 'text', text: 'read it' }] }] } as any) as any;
  assert.equal(pictured.messages[1].content[1].image_url.url, 'data:image/jpeg;base64,aW1hZ2U=');
});

test('streamed Unicode and authoritative cache-inclusive cost reach settlement once', async () => {
  const { outcome, text } = await run([event({ content: 'β = 0.1 [¶1]' }), final()]);
  assert.equal(text, 'β = 0.1 [¶1]'); assert.equal(outcome.status, 'complete'); assert.equal(outcome.stopReason, 'end_turn');
  assert.equal(outcome.exact, true); assert.equal(priceAttempts(outcome.attempts), 1000);
  assert.deepEqual(outcome.attempts[0].usage, { input: 200, cacheRead: 800, cacheWrite5m: 0, cacheWrite1h: 0, output: 200 });
  assert.equal(outcome.attempts[0].cacheStorageTokens, 100);
  assert.ok(holdForParams(params).microusd > priceAttempts(outcome.attempts));
  const calls: { name: string; p: Record<string, unknown> }[] = [];
  const admitted = admittedAnthropic({ accountID: 'a', operationID: 'o', sha256Hex: async b => createHash('sha256').update(b).digest('hex'),
    rpc: async (name, p) => { calls.push({ name, p }); return { granted: true }; } }, async () => outcome);
  await admitted(params, { signal: new AbortController().signal, inputEstimateTokens: 2000, onText: () => {} });
  assert.equal(calls[0].p.p_provider, 'openrouter'); assert.equal(calls[1].p.p_actual_microusd, 1000);
  assert.equal(calls[1].p.p_provider_request_id, 'gen-test'); assert.equal(calls[1].p.p_state, 'succeeded');
  assert.equal((calls[1].p.p_actual_units as Record<string, number>).cache_storage_tokens, 100);
});

test('measured Google bills preserve overlapping cache-storage counts without double-counting input or cost', async () => {
  // Numeric usage from the immutable 2026-10-16 comparison: muon-detail and apertus-unanswerable.
  for (const bill of [
    { prompt_tokens: 47118, completion_tokens: 2231, prompt_tokens_details: { cached_tokens: 47092, cache_write_tokens: 47092 }, cost: 0.013879816666666666 },
    { prompt_tokens: 138011, completion_tokens: 1657, prompt_tokens_details: { cached_tokens: 137980, cache_write_tokens: 0 }, cost: 0.0165855 },
  ]) {
    const attempt = openRouterAttempt(bill);
    assert.ok(attempt); assert.equal(attempt.estimated, false);
    assert.equal(attempt.usage.input + attempt.usage.cacheRead + attempt.usage.cacheWrite5m, bill.prompt_tokens);
    assert.equal(attempt.cacheStorageTokens ?? 0, bill.prompt_tokens_details.cache_write_tokens);
    assert.equal(priceAttempts([attempt]), bill.cost * 1_000_000);
  }
  for (const details of [{ cached_tokens: -1 }, { cache_write_tokens: '100' }, { cached_tokens: 1001 }, { cache_write_tokens: 1001 }]) {
    assert.equal(openRouterAttempt({ ...usage, prompt_tokens_details: details }), null);
  }
});

test('tool fragments and reasoning signatures survive the next round, and search results remain plain text', async () => {
  const { outcome } = await run([
    event({ reasoning_details: [{ index: 0, type: 'reasoning.encrypted', data: 'sig1' }], tool_calls: [{ index: 0, id: 'call1', function: { name: 'search_web', arguments: '{"query":' } }] }),
    event({ reasoning_details: [{ index: 0, type: 'reasoning.encrypted', data: 'sig2' }], tool_calls: [{ index: 0, function: { arguments: '"paper"}' } }] }), final('tool_calls'),
  ]);
  assert.equal(outcome.stopReason, 'tool_use'); assert.deepEqual(outcome.toolCalls, [{ id: 'call1', name: 'search_web', input: { query: 'paper' } }]);
  const continued = openRouterChatParams({ ...params, messages: [...params.messages, { role: 'assistant', content: outcome.content },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'call1', content: [{ type: 'search_result', title: 'T', source: 'https://example.org', content: [{ type: 'text', text: 'Found it' }] }] }] }] } as Params) as any;
  assert.equal(continued.messages[2].reasoning_details[0].data, 'sig1sig2');
  assert.equal(continued.messages[2].tool_calls[0].function.arguments, '{"query":"paper"}');
  assert.equal(continued.messages[3].role, 'tool'); assert.match(continued.messages[3].content[0].text, /https:\/\/example.org/);
});

test('initial or missing usage, transport failures and truncated streams retain liability', async () => {
  for (const events of [[event({ content: 'partial' })], [event({ content: 'partial' }, { usage })], [final('stop', null)]]) {
    const { outcome } = await run(events, false);
    assert.equal(outcome.status, 'failed'); assert.equal(outcome.exact, false); assert.ok(outcome.attempts[0].estimated);
  }
  assert.equal(openRouterAttempt({ ...usage, cost: NaN }), null);
  assert.equal(openRouterAttempt({ ...usage, prompt_tokens: 1 }), null);
  const controller = new AbortController();
  const generate = openRouterChat({ apiKey: 'test-key', fetch: async () => { controller.abort(); throw new Error('secret raw error'); } });
  const failed = await generate(params, { signal: controller.signal, inputEstimateTokens: 1000, onText: () => {} });
  assert.equal(failed.failure, 'aborted'); assert.equal(failed.exact, false); assert.doesNotMatch(JSON.stringify(failed), /secret/);
});

test('provider rejection diagnostics expose only a closed category, never echoed request content', async () => {
  for (const [status, message, reason] of [
    [404, 'No endpoints found matching your data policy (Zero data retention). private question', 'privacy_zdr'],
    [404, 'No endpoints found matching your data policy. private question', 'privacy_policy'],
    [404, 'No endpoints found for this model. private question', 'route_unavailable'],
    [400, 'Invalid parameter: private question', 'request_parameters'],
    [401, 'Invalid API key: secret', 'authentication'],
    [400, 'x'.repeat(9000), 'unknown'],
  ] as const) {
    const generate = openRouterChat({ apiKey: 'test-key', fetch: async () => new Response(JSON.stringify({ error: { message } }), { status }) });
    const outcome = await generate(params, { signal: new AbortController().signal, inputEstimateTokens: 1000, onText: () => {} });
    assert.equal(outcome.rejectionReason, reason); assert.equal(outcome.httpStatus, status);
    assert.doesNotMatch(JSON.stringify(outcome), /private question|secret|xxxx/);
    assert.equal(outcome.exact, true); assert.deepEqual(outcome.attempts, []);
  }
});

test('pre-inference refusals cost zero, 5xx is uncertain, and expired rates make no request', async () => {
  for (const status of [402, 429, 503]) {
    const generate = openRouterChat({ apiKey: 'test-key', fetch: async () => new Response('', { status, headers: { 'retry-after': '2' } }) });
    const outcome = await generate(params, { signal: new AbortController().signal, inputEstimateTokens: 1000, onText: () => {} });
    assert.equal(outcome.failure, status === 402 ? 'provider_billing' : 'provider_error');
    assert.equal(outcome.exact, status !== 503); assert.equal(outcome.retryAfterMs, 2000);
  }
  const expired = openRouterChat({ apiKey: 'test-key', now: () => GEMINI_PRICE_EXPIRES, fetch: async () => { throw new Error('must not send'); } });
  assert.equal((await expired(params, { signal: new AbortController().signal, inputEstimateTokens: 1, onText: () => {} })).exact, true);
  for (const reason of ['length', 'content_filter', 'unexpected']) {
    const { outcome } = await run([final(reason)]);
    assert.equal(outcome.status, reason === 'unexpected' ? 'failed' : 'complete');
    assert.equal(outcome.stopReason, reason === 'length' ? 'max_tokens' : reason === 'content_filter' ? 'refusal' : null);
  }
});

test('Flash is opt-in on the server, consent v5 is mandatory, and older defaults stay unchanged', async () => {
  const table = publishedProfiles({ deepseek: true, gemini: true }), old = publishedProfiles({ deepseek: true });
  assert.deepEqual(table.default, old.default); assert.deepEqual(table.default_auto, old.default_auto);
  assert.deepEqual(table.profiles.slice(0, old.profiles.length), old.profiles);
  assert.deepEqual(table.default_recommended, { model: 'gemini', effort: 'medium', length: 'standard' });
  assert.equal(providerForModel(GEMINI_MODEL), 'openrouter'); assert.ok(!old.models.some(m => m.id === 'gemini'));
  assert.equal(resolveChoice({ model: 'gemini', effort: 'auto', length: 'brief' }, { question: 'Hi', selection: null, figures: 0 })?.effort, 'medium');
  const body = { operation_id: 'aaaaaaaa-0000-4000-8000-000000000001', mode: 'general', messages: [{ role: 'user', text: 'Hello' }],
    consent_version: 'cloud-ai-v4', profile: { model: 'gemini', effort: 'auto', length: 'standard' } };
  assert.throws(() => validateChatRequest(body), { code: 'consent_required' });
  assert.equal(validateChatRequest({ ...body, consent_version: 'cloud-ai-v5' }).choice?.model, 'gemini');
  const emitted: ChatEvent[] = [], calls: string[] = [];
  const deps: ChatDependencies = { accountID: 'a', generate: async () => { throw new Error('must not send'); },
    rpc: async name => { calls.push(name); return null; }, sha256Hex: async () => 'a'.repeat(64), loadPaper: async () => null, log: () => {} };
  await runChat(deps, { ...body, consent_version: 'cloud-ai-v5' }, e => emitted.push(e), new AbortController().signal);
  assert.ok(!calls.includes('worker_reserve_chat')); assert.ok(emitted.some(e => e.event === 'error'));
});


test('the enabled chat orchestrator quotes Flash and settles the reported cost', async () => {
  const calls: { name: string; p: Record<string, any> }[] = [], events: ChatEvent[] = [];
  const rpc: ChatDependencies['rpc'] = async (name, p) => {
    calls.push({ name, p });
    return name === 'worker_reserve_chat' ? { replayed: false } : name === 'worker_provider_attempt_begin' ? { granted: true } : null;
  };
  const accountID = 'aaaaaaaa-0000-4000-8000-000000000001', operationID = 'bbbbbbbb-0000-4000-8000-000000000001';
  const sha256Hex = async (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
  const generate = admittedAnthropic({ accountID, operationID, rpc, sha256Hex }, openRouterChat({ apiKey: 'fixture',
    fetch: async () => response([event({ content: 'An answer.' }), final()]) }));
  await runChat({ accountID, rpc, sha256Hex, generate, gemini: true, loadPaper: async () => null, log: () => {} },
    { operation_id: operationID, consent_version: 'cloud-ai-v5', mode: 'general', messages: [{ role: 'user', text: 'Hi' }],
      profile: { model: 'gemini', effort: 'auto', length: 'standard' } }, e => events.push(e), new AbortController().signal);
  assert.ok(!events.some(e => e.event === 'error'), JSON.stringify(events));
  const quote = calls.find(c => c.name === 'worker_reserve_chat')!.p.p_quote;
  assert.equal(quote.profile, 'gemini-medium-standard'); assert.equal(quote.model, GEMINI_MODEL);
  assert.equal(quote.tariff, 'openrouter-google-flash-vertex-us-20261017');
  assert.equal(calls.find(c => c.name === 'worker_provider_attempt_finish')!.p.p_actual_microusd, 1000);
  assert.ok(events.some(e => e.event === 'done' && e.data.model === GEMINI_MODEL && e.data.credits === 1));
});

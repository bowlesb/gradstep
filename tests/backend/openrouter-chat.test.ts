import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import type Anthropic from '@anthropic-ai/sdk';
import { openRouterAttempt, openRouterChat, openRouterChatParams } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { GEMINI_MODEL, GEMINI_OPENROUTER_MODEL } from '../../supabase/functions/_shared/gemini-pricing.ts';
// A fixed clock: card validity is the database's (migration 0101), not a constant in the adapter.
const NOW = Date.parse('2026-12-01T00:00:00Z');
import { chatRequestParams, priceAttempts, holdForParams } from '../../supabase/functions/_shared/anthropic.ts';
import { publishedProfiles, resolveChoice, providerForModel } from '../../supabase/functions/_shared/chat-profiles.ts';
import { validateChatRequest, runChat, type ChatDependencies, type ChatEvent } from '../../supabase/functions/_shared/chat.ts';
import { admittedAnthropic } from '../../supabase/functions/_shared/provider-spending.ts';

const attribution = { accountID: 'aaaaaaaa-0000-4000-8000-000000000001', operationID: 'bbbbbbbb-0000-4000-8000-000000000001', attemptID: 'cccccccc-0000-4000-8000-000000000001', feature: 'chat', caller: 'chat', dispatch: async () => true };
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
  const generate = openRouterChat({ apiKey: 'test-key', now: () => NOW, fetch: async (_url, options) => {
    assert.equal(new Headers(options?.headers).get('X-OpenRouter-Cache'), 'false');
    sent = JSON.parse(String(options?.body)); return response(events, done);
  } });
  const outcome = await generate(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 2000, onText: s => { text += s; } });
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
  await admitted(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 2000, onText: () => {} });
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
  const failed = await generate(params, { attribution, signal: controller.signal, inputEstimateTokens: 1000, onText: () => {} });
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
    const outcome = await generate(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 1000, onText: () => {} });
    assert.equal(outcome.rejectionReason, reason); assert.equal(outcome.httpStatus, status);
    assert.doesNotMatch(JSON.stringify(outcome), /private question|secret|xxxx/);
    assert.equal(outcome.exact, true); assert.deepEqual(outcome.attempts, []);
  }
});

test('pre-inference refusals cost zero, 5xx is uncertain, and a lapsed card (admission) makes no request', async () => {
  for (const status of [402, 429, 503]) {
    const generate = openRouterChat({ apiKey: 'test-key', fetch: async () => new Response('', { status, headers: { 'retry-after': '2' } }) });
    const outcome = await generate(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 1000, onText: () => {} });
    assert.equal(outcome.failure, status === 402 ? 'provider_billing' : 'provider_error');
    assert.equal(outcome.exact, status !== 503); assert.equal(outcome.retryAfterMs, 2000);
  }
  // A4: admission refuses a lapsed card (app_private.openrouter_tariffs) before the adapter runs: the model is unavailable.
  const refused = admittedAnthropic({ accountID: 'a', operationID: 'o', sha256Hex: async b => createHash('sha256').update(b).digest('hex'),
    rpc: async () => ({ granted: false, reason: 'tariff_expired' }) }, async () => { throw new Error('must not send'); });
  const expired = await refused(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 1, onText: () => {} });
  assert.equal(expired.exact, true); assert.equal(expired.rejectionReason, 'tariff_expired'); assert.deepEqual(expired.attempts, []);
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
    return name === 'worker_openrouter_dispatch' ? true : name === 'worker_reserve_chat' ? { replayed: false } : name === 'worker_provider_attempt_begin' ? { granted: true } : null;
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

// Build 68: saved Claude defaults and every chat auxiliary must use the same funded connection.
import { isRouterClaude, routedClaudeModel, routerClaudeRates } from '../../supabase/functions/_shared/openrouter-claude-pricing.ts';
import { resolveProfile } from '../../supabase/functions/_shared/chat-profiles.ts';
test('Claude routing preserves its cache TTL, effort, tool schema and exact billed usage', async () => {
  for (const model of ['haiku', 'sonnet', 'opus'] as const) {
    const profile = resolveProfile({ model, effort: 'high', length: 'standard' }, true);
    assert.equal(profile.provider, 'openrouter'); assert.equal(profile.fallbacks, false);
    assert.equal(providerForModel(profile.apiModel), 'openrouter'); assert.ok(isRouterClaude(profile.apiModel));
    const request = { ...params, model: profile.apiModel, output_config: { effort: 'high' as const } };
    const wire = openRouterChatParams(request) as any;
    assert.equal(wire.model, profile.apiModel); assert.equal(wire.reasoning.effort, 'high');
    assert.deepEqual(wire.provider.only, ['google-vertex/us']); assert.equal(wire.provider.zdr, true);
    assert.equal(wire.provider.allow_fallbacks, false);
    assert.deepEqual(wire.messages[0].content, params.system);
    assert.equal(wire.messages[0].content.find((b: any) => b.cache_control)?.cache_control.ttl, '1h');
    const attempt = openRouterAttempt({ ...usage, cost: 0.0002 }, profile.apiModel, true)!;
    assert.equal(attempt.model, profile.apiModel); assert.equal(attempt.usage.input, 100);
    assert.equal(attempt.usage.cacheWrite1h, 100); assert.equal(attempt.cacheStorageTokens, undefined);
    assert.equal(priceAttempts([attempt]), 200); assert.ok(holdForParams(request).microusd > 200);
    assert.equal(openRouterAttempt({ ...usage, prompt_tokens_details: { cached_tokens: 800, cache_write_tokens: 300 } }, profile.apiModel), null);
  }
  assert.equal(routerClaudeRates(routedClaudeModel('claude-haiku-5-5'), 100001).input, 0.55);
  const table = publishedProfiles({ deepseek: true, gemini: true, claudeOpenRouter: true });
  assert.equal(table.models.find(m => m.id === 'sonnet')!.provider, 'openrouter');
  assert.equal(table.models.find(m => m.id === 'sonnet')!.consent_version, 'cloud-ai-v5');
  assert.equal(table.profiles[26].id, 'opus-high-detailed');
  assert.equal(table.default_recommended?.model, 'gemini');
});

test('routed Claude plus title and suggestions all admit and settle as OpenRouter; old consent sends nothing', async () => {
  for (const consent of ['cloud-ai-v4', 'cloud-ai-v5']) {
    const calls: { name: string; p: Record<string, any> }[] = [], events: ChatEvent[] = [], models: string[] = [];
    const rpc: ChatDependencies['rpc'] = async (name, p) => { calls.push({ name, p });
      return name === 'worker_openrouter_dispatch' ? true : name === 'worker_reserve_chat' ? { replayed: false } : name === 'worker_provider_attempt_begin' ? { granted: true } : null; };
    const accountID = 'aaaaaaaa-0000-4000-8000-000000000001', operationID = 'bbbbbbbb-0000-4000-8000-000000000002';
    const sha256Hex = async (b: Uint8Array) => createHash('sha256').update(b).digest('hex');
    const generate = admittedAnthropic({ accountID, operationID, rpc, sha256Hex }, openRouterChat({ apiKey: 'fixture', fetch: async (_url, init) => {
      const sent = JSON.parse(String(init?.body)); models.push(sent.model);
      assert.ok(isRouterClaude(sent.model));
      return response([event({ content: sent.response_format ? JSON.stringify({ questions: ['What changes the scale?', 'When are log axes useful?'] }) : 'A complete answer.' }), final()].map(e => ({ ...e, model: sent.model })));
    } }));
    await runChat({ accountID, rpc, sha256Hex, generate, claudeOpenRouter: true, loadPaper: async () => null, log: () => {} },
      { operation_id: operationID, consent_version: consent, mode: 'general', messages: [{ role: 'user', text: 'Hi' }],
        topic_title: true, follow_ups: true, profile: { model: 'sonnet', effort: 'low', length: 'brief' } }, e => events.push(e), new AbortController().signal);
    if (consent === 'cloud-ai-v4') {
      assert.ok(events.some(e => e.event === 'error' && e.data.code === 'consent_required'));
      assert.equal(models.length, 0); assert.ok(!calls.some(c => c.name === 'worker_reserve_chat')); continue;
    }
    assert.ok(!events.some(e => e.event === 'error'), JSON.stringify(events));
    assert.ok(events.some(e => e.event === 'followups'), JSON.stringify(events));
    assert.equal(models.length, 3); assert.equal(models.filter(m => m === routedClaudeModel('claude-haiku-5-5')).length, 2);
    const quote = calls.find(c => c.name === 'worker_reserve_chat')!.p.p_quote;
    assert.equal(quote.model, routedClaudeModel('claude-sonnet-5-5'));
    assert.equal(quote.title_model, routedClaudeModel('claude-haiku-5-5'));
    assert.equal(quote.follow_ups_model, quote.title_model);
    assert.ok(calls.filter(c => c.name === 'worker_provider_attempt_begin').every(c => c.p.p_provider === 'openrouter'));
    assert.ok(events.some(e => e.event === 'done' && e.data.model === 'claude-sonnet-5-5'));
  }
});

import { followUpRequestParams } from '../../supabase/functions/_shared/chat-follow-ups.ts';
test('Vertex Claude forced auxiliaries use a structured schema, never an unsupported tool_choice', async () => {
  const forced = followUpRequestParams({ paperTitle: null, selection: null, question: 'Plot?', answer: 'Axes need units.' });
  forced.model = routedClaudeModel(forced.model);
  const wire = openRouterChatParams(forced) as any;
  assert.equal(wire.tool_choice, undefined); assert.equal(wire.tools, undefined);
  assert.equal(wire.response_format.json_schema.name, 'suggest_follow_ups');
  assert.deepEqual(wire.reasoning, { enabled: false });
  assert.equal(wire.response_format.json_schema.schema.additionalProperties, false);
  for (const content of ['{"questions":["Why units?","What scale?"]}', 'invalid JSON']) {
    let streamed = '';
    const generate = openRouterChat({ apiKey: 'fixture', fetch: async () => response([event({ content }), final()].map(e => ({ ...e, model: forced.model }))) });
    const result = await generate(forced, { attribution, signal: new AbortController().signal, inputEstimateTokens: 2000, onText: s => { streamed += s; } });
    assert.equal(streamed, '', 'auxiliary JSON never leaks into the reader answer');
    assert.equal(result.exact, true); assert.equal(priceAttempts(result.attempts), 1000);
    // A23: an unparsable forced object is dropped (the turn completes with nothing usable; its caller treats it as
    // unusable and the reader is not charged for it), not turned into a provider failure.
    assert.equal(result.status, 'complete');
    if (content === 'invalid JSON') { assert.deepEqual(result.toolCalls, []); assert.equal(result.stopReason, 'end_turn'); }
    else assert.deepEqual(result.toolCalls?.[0].input, { questions: ['Why units?', 'What scale?'] });
  }
});

test('A23: an invalid or cut-off tool call is dropped and the streamed answer is kept', async () => {
  const visualParams = { ...params, tools: [...(params.tools ?? []), { name: 'create_visual', input_schema: { type: 'object' as const, properties: {} } }] };
  const cases: [string, unknown[], string, number][] = [
    // A `length` stop inside a large create_visual call: the text stays, the call is dropped, it is a length stop.
    ['cut off', [event({ content: 'Here is the answer.' }), event({ tool_calls: [{ index: 0, id: 'v1', function: { name: 'create_visual', arguments: '{"html":"<div' } }] }), final('length')], 'max_tokens', 0],
    ['unknown tool', [event({ content: 'Answer text.' }), event({ tool_calls: [{ index: 0, id: 'x1', function: { name: 'delete_everything', arguments: '{}' } }] }), final('tool_calls')], 'end_turn', 0],
    ['missing id', [event({ content: 'Answer text.' }), event({ tool_calls: [{ index: 0, function: { name: 'create_visual', arguments: '{}' } }] }), final('tool_calls')], 'end_turn', 0],
    ['one good, one bad', [event({ content: 'Answer.' }), event({ tool_calls: [{ index: 0, id: 'v1', function: { name: 'create_visual', arguments: '{}' } },
      { index: 1, id: 'v2', function: { name: 'create_visual', arguments: '{' } }] }), final('tool_calls')], 'tool_use', 1],
  ];
  for (const [label, events, stopReason, kept] of cases) {
    let text = '';
    const generate = openRouterChat({ apiKey: 'test-key', now: () => NOW, fetch: async () => response(events) });
    const outcome = await generate(visualParams, { attribution, signal: new AbortController().signal, inputEstimateTokens: 2000, onText: s => { text += s; } });
    assert.equal(outcome.status, 'complete', label); assert.equal(outcome.stopReason, stopReason, label);
    assert.equal(outcome.toolCalls?.length, kept, label); assert.equal(outcome.exact, true, label);
    assert.ok(text.length > 0, label); assert.ok((outcome.content as any[]).some(b => b.type === 'text'), label);
  }
});

// A1 (review 2026-10-21): Stop on an OpenRouter answer charges what was written, never the hold. The real adapter, a
// stream the reader stops after its first words, and OpenRouter's generation record (or its absence).
import { stoppedReaderMicrousd, STOPPED_RECEIPT_WAIT_MS } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { creditsFor } from '../../supabase/functions/_shared/anthropic.ts';
const SONNET = routedClaudeModel('claude-sonnet-5-5');
function stoppable(first: unknown[], signal: AbortSignal | null | undefined, id = 'gen-stop') {
  const bytes = new TextEncoder().encode(first.map(e => `data: ${JSON.stringify(e)}\n\n`).join(''));
  return new Response(new ReadableStream({ start(c) {
    if (bytes.length) c.enqueue(bytes);
    signal?.addEventListener('abort', () => c.error(new DOMException('stopped', 'AbortError')), { once: true });
  } }), { headers: { 'x-generation-id': id } });
}
async function stoppedAnswer(options: { record: 'found' | 'missing'; first: unknown[]; stopAtStart?: boolean }) {
  const accountID = 'aaaaaaaa-0000-4000-8000-000000000001', operationID = 'bbbbbbbb-0000-4000-8000-000000000003';
  const calls: { name: string; p: Record<string, any> }[] = [], events: ChatEvent[] = [], gets: string[] = [];
  const client = new AbortController();
  const rpc: ChatDependencies['rpc'] = async (name, p) => { calls.push({ name, p });
    return name === 'worker_openrouter_dispatch' || name === 'worker_openrouter_receipt' ? true : name === 'worker_reserve_chat' ? { replayed: false }
      : name === 'worker_provider_attempt_begin' ? { granted: true } : name === 'worker_local_chat_context' ? { title: 'A long paper' }
      : name === 'worker_chat_stop_requested' ? true : null; };
  const sha256Hex = async (b: Uint8Array) => createHash('sha256').update(b).digest('hex');
  const generate = admittedAnthropic({ accountID, operationID, rpc, sha256Hex }, openRouterChat({ apiKey: 'fixture', now: () => 1_000, sleep: async () => {},
    fetch: async (url, init) => {
      if (String(url).includes('/generation?id=')) {
        gets.push(String(url));
        if (options.record === 'missing' || gets.length === 1) return new Response(null, { status: 404 });
        // Google Vertex keeps generating after a cancel: 900 output tokens billed, the reader saw a handful.
        return Response.json({ data: { id: 'gen-stop', model: SONNET, provider_name: 'Google', external_user: accountID, session_id: operationID,
          cancelled: true, finish_reason: null, native_tokens_prompt: 40_000, native_tokens_cached: 0, native_tokens_completion: 900, total_cost: 0.12 } });
      }
      // The reader presses Stop after the first words arrive, or (stopAtStart) while the model is still thinking.
      if (options.stopAtStart) setTimeout(() => client.abort(), 5);
      return stoppable(options.first, init?.signal);
    } }));
  const text = 'word '.repeat(30_000); // ~150 KB of paper: the case the review measured (≈89 credits for a Stop)
  const local = { format: 'reader-local-context-v2', membership_id: 'cccccccc-0000-4000-8000-000000000003', source: 'arxiv', source_id: '2305.18290',
    revision: 3, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text };
  await runChat({ accountID, rpc, sha256Hex, generate, claudeOpenRouter: true, loadPaper: async () => null, log: () => {}, sleep: async () => {} },
    { operation_id: operationID, consent_version: 'cloud-ai-v6', mode: 'paper', local_context: local, capabilities: ['stop_signal'],
      messages: [{ role: 'user', text: 'Summarize the method.' }], profile: { model: 'sonnet', effort: 'low', length: 'standard' } },
    e => { events.push(e); if (e.event === 'delta') client.abort(); }, client.signal);
  const reserve = calls.find(c => c.name === 'worker_reserve_chat')!.p, settle = calls.find(c => c.name === 'worker_settle_chat')!.p;
  const finish = calls.find(c => c.name === 'worker_provider_attempt_finish')!.p;
  return { reserve, settle, finish, events, gets, calls };
}

test('a Stop is charged at OpenRouter\'s record of the part written, not the hold; the rest is Gradstep\'s', async () => {
  const { reserve, settle, finish, gets, calls } = await stoppedAnswer({ record: 'found', first: [{ id: 'gen-stop', model: SONNET, choices: [{ delta: { content: 'The method fits' }, finish_reason: null }] }] });
  assert.ok(reserve.p_credits > 100, `the hold is large (${reserve.p_credits} credits)`);
  assert.equal(settle.p_ending, 'stopped');
  // Input 40,000 × $2.20/M = 88,000 µ$; the 900 billed output tokens cost the other 32,000 µ$, of which the reader saw
  // ⌈15 chars / 3⌉ = 5 tokens: 32,000 × 5/900 ≈ 178 µ$. 88,178 µ$ → 18 credits.
  assert.equal(Math.round(stoppedReaderMicrousd(SONNET, 5, true, { id: 'gen-stop', model: SONNET, provider: 'Google', totalMicrousd: 120_000,
    promptTokens: 40_000, completionTokens: 900, cachedTokens: 0, cancelled: true, finishReason: null })), 88_178);
  assert.equal(settle.p_actual_credits, creditsFor(88_178)); assert.equal(settle.p_actual_credits, 18);
  assert.equal(settle.p_absorbed_microusd, 120_000 - 88_178);
  // The attempt is exact (no liability left to reconcile) and its receipt is recorded.
  assert.equal(finish.p_state, 'succeeded'); assert.equal(finish.p_actual_microusd, 120_000);
  assert.equal(gets.length, 2, 'one 404 while OpenRouter writes the record, then the record');
  assert.deepEqual(calls.find(c => c.name === 'worker_openrouter_receipt')!.p.p_metadata,
    { generation_id: 'gen-stop', provider: 'Google', model: SONNET, total_cost_microusd: 120_000 });
});

test('without OpenRouter\'s record a Stop is charged for the streamed output only; the ceiling stays unresolved', async () => {
  const { settle, finish, gets } = await stoppedAnswer({ record: 'missing', first: [{ id: 'gen-stop', model: SONNET, choices: [{ delta: { content: 'The method fits' }, finish_reason: null }] }] });
  assert.equal(settle.p_ending, 'stopped');
  // 5 observed output tokens × $11/M = 55 µ$ → 1 credit, never the input estimate.
  assert.equal(settle.p_actual_credits, 1);
  assert.equal(finish.p_state, 'unknown'); assert.equal(finish.p_actual_microusd, null);
  assert.equal(gets.length, 6, 'bounded reads, then the attempt is left for the reconciler');
  assert.ok(STOPPED_RECEIPT_WAIT_MS <= 8_000);
});

test('a Stop before any text or tool call arrived costs the reader nothing, even with a record', async () => {
  const { settle } = await stoppedAnswer({ record: 'found', first: [{ id: 'gen-stop', model: SONNET, choices: [{ delta: { reasoning_details: [{ index: 0, type: 'reasoning.text', text: 'Thinking' }] }, finish_reason: null }] }], stopAtStart: true });
  assert.equal(settle.p_ending, 'stopped'); assert.equal(settle.p_actual_credits, 0); assert.equal(settle.p_absorbed_microusd, 120_000);
});

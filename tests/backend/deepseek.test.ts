import test from 'node:test';
import assert from 'node:assert/strict';
import type Anthropic from '@anthropic-ai/sdk';
import { createDeepSeekChatClient, DEEPSEEK_ANTHROPIC_BASE_URL, deepseekChatParams, deepseekMessages, deepseekScriptProvider, deepseekUsage,
  streamDeepSeekChat } from '../../supabase/functions/_shared/deepseek.ts';
import { draftRequest, DRAFT_SCHEMA, scriptCost } from '../../supabase/functions/_shared/podcast-script.ts';
import { chatRequestParams, CREATE_DIAGRAM_TOOL, priceAttempts, ratesFor, SEARCH_WEB_TOOL, searchResultContent, WEB_SEARCH_TOOL } from '../../supabase/functions/_shared/anthropic.ts';

// DeepSeek as a podcast script provider (2026-10-14): the Anthropic-shaped request becomes a chat completion in JSON
// mode with the schema in the system prompt; usage prices from the card's PEAK rates; rejections and transport failures
// are reported the way the Anthropic adapter reports them.
const params = draftRequest('# Paper\n\nA paragraph with a number 42.', 'A title', 6000, 'Write it.', 'deepseek-v4-pro');

test('messages: the system text and the output schema first, each turn as plain text, the spec model', () => {
  const messages = deepseekMessages(params);
  assert.equal(messages[0].role, 'system');
  assert.ok(messages[0].content.startsWith('Write it.')); assert.ok(messages[0].content.includes(JSON.stringify(DRAFT_SCHEMA)));
  assert.match(messages[0].content, /compact JSON on one line/, 'pretty-printed JSON spent the output allowance on whitespace (seed 3, 2026-10-14)');
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

// ---- DeepSeek in chat (2026-10-16): the Anthropic chat request on DeepSeek's Anthropic-compatible API ----

const chat = () => chatRequestParams({ instructions: 'Answer.', paper: { title: 'DPO', text: 'The paper.' }, selection: null,
  turns: [{ role: 'user', text: 'What does Figure 2 show?' }], maxTokens: 10_000, model: { id: 'deepseek-flash', effort: 'medium', fallbacks: false },
  figures: [{ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: '/9j/AAAA' } }],
  tools: [CREATE_DIAGRAM_TOOL, SEARCH_WEB_TOOL, WEB_SEARCH_TOOL] });

test('the chat request for DeepSeek: no betas or fallbacks, client tools only, search results as text, everything else unchanged', () => {
  const original = { ...chat(), betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' as const };
  const toolTurn = { ...original, messages: [...original.messages,
    { role: 'assistant' as const, content: [{ type: 'tool_use' as const, id: 'toolu_1', name: 'search_web', input: { query: 'IPO' } }] },
    { role: 'user' as const, content: [{ type: 'tool_result' as const, tool_use_id: 'toolu_1',
      content: searchResultContent([{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO', text: 'A general paradigm.', published: '2023-10-18' }]) }] }] };
  const sent = deepseekChatParams(toolTurn);
  assert.equal(sent.model, 'deepseek-flash'); assert.equal(sent.max_tokens, 10_000);
  assert.equal((sent as { betas?: unknown }).betas, undefined); assert.equal((sent as { fallbacks?: unknown }).fallbacks, undefined);
  assert.deepEqual(sent.thinking, { type: 'adaptive' }); assert.deepEqual(sent.output_config, { effort: 'medium' });
  assert.deepEqual(sent.system, original.system, 'the cached paper block passes unchanged (DeepSeek ignores cache_control)');
  assert.deepEqual(sent.tools!.map(t => (t as { name: string }).name), ['create_diagram', 'search_web'], 'Anthropic\'s server search tool never goes to DeepSeek');
  const question = sent.messages[0].content as { type: string }[];
  assert.deepEqual(question.map(b => b.type), ['image', 'text'], 'the figure stays with the question');
  const result = (sent.messages.at(-1)!.content as { type: string; content: { type: string; text: string }[] }[])[0];
  assert.deepEqual(result.content, [{ type: 'text', text: 'Source: IPO — https://arxiv.org/abs/2310.12036\nPublished 2023-10-18. A general paradigm.' }]);
  // The original request is not changed (it is the admission's digest).
  assert.equal((toolTurn.messages.at(-1)!.content as { content: { type: string }[] }[])[0].content[0].type, 'search_result');
  assert.equal(deepseekChatParams({ ...chat(), tools: [WEB_SEARCH_TOOL] }).tools, undefined);
});

test('a DeepSeek chat stream: its Anthropic endpoint and key, usage as cache misses and hits, priced at the requested model', async () => {
  const seen: { url?: string; headers?: Headers; body?: Record<string, unknown> } = {};
  const events = [
    { type: 'message_start', message: { id: '8bde3cc9-0dd8-4bbe-b312-4d14b95d2f65', type: 'message', role: 'assistant', model: 'deepseek-v4.1-flash', content: [],
      stop_reason: null, stop_sequence: null, usage: { input_tokens: 190, cache_creation_input_tokens: 0, cache_read_input_tokens: 384, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '', signature: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'Look at the panels.' } },
    { type: 'content_block_stop', index: 0 },
    { type: 'content_block_start', index: 1, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: 'Two panels: \\( x^2 \\).' } },
    { type: 'content_block_stop', index: 1 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { input_tokens: 190, cache_creation_input_tokens: 0, cache_read_input_tokens: 384, output_tokens: 113 } },
    { type: 'message_stop' },
  ];
  const client = createDeepSeekChatClient({ apiKey: 'test-deepseek-key', fetch: (async (url: string, init: RequestInit) => {
    seen.url = String(url); seen.headers = new Headers(init.headers); seen.body = JSON.parse(String(init.body));
    return new Response(events.map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(''), { status: 200, headers: { 'content-type': 'text/event-stream' } });
  }) as typeof fetch });
  const text: string[] = [];
  const outcome = await streamDeepSeekChat(client, { ...chat(), betas: ['server-side-fallback-2026-07-01'] } as Anthropic.Beta.Messages.MessageCreateParamsNonStreaming,
    { signal: new AbortController().signal, onText: t => text.push(t), inputEstimateTokens: 1_000 });
  assert.match(seen.url!, /^https:\/\/api\.deepseek\.com\/anthropic\/v1\/messages/);
  assert.equal(seen.headers!.get('x-api-key'), 'test-deepseek-key'); assert.equal(seen.headers!.get('anthropic-beta'), null);
  assert.equal(seen.body!.model, 'deepseek-flash'); assert.equal(seen.body!.stream, true); assert.equal(seen.body!.fallbacks, undefined);
  assert.deepEqual(text, ['Two panels: \\( x^2 \\).'], 'thinking is not answer text');
  assert.equal(outcome.status, 'complete'); assert.equal(outcome.exact, true); assert.equal(outcome.model, 'deepseek-v4.1-flash');
  // Billed as the model the request named, whatever string the response reports.
  assert.deepEqual(outcome.attempts, [{ model: 'deepseek-flash', estimated: false, usage: { input: 190, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 384, output: 113 } }]);
  assert.equal(priceAttempts(outcome.attempts), 190 * 0.3 + 384 * 0.006 + 113 * 1.2);
  assert.equal(DEEPSEEK_ANTHROPIC_BASE_URL, 'https://api.deepseek.com/anthropic');
});

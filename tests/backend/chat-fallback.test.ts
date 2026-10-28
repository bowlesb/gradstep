// An answer's fallback (2026-10-25; chat-fallback.ts, CHAT.md "A fallback when the chosen model fails before writing").
// Owner on TestFlight 92, 16:05 UTC: a figure explainer on Gemini Flash failed twice ("The AI service couldn't finish this
// answer"): HTTP 429 from the pinned Google Vertex endpoint, both times after about 2 s; neither was retried because the
// 429 carried a generation id. These tests drive the real adapter, admission and orchestration with a fake OpenRouter.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { errorKind, openRouterChat } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { admittedModelCalls } from '../../supabase/functions/_shared/provider-spending.ts';
import { runChat, type ChatDependencies, type ChatEvent } from '../../supabase/functions/_shared/chat.ts';
import { chatRequestParams, creditsFor, retryOnceWhenBusy, type ProviderOutcome } from '../../supabase/functions/_shared/inference.ts';
import { FALLBACK_FIRST_DATA_MS, FALLBACK_HAIKU, FALLBACK_MODELS, fallbackEligible, fallbackParams } from '../../supabase/functions/_shared/chat-fallback.ts';
import { GEMINI_MODEL, GEMINI_OPENROUTER_MODEL } from '../../supabase/functions/_shared/gemini-pricing.ts';
import { FIRST_DATA_DEADLINE_MS } from '../../supabase/functions/_shared/openrouter-chat.ts';

const accountID = 'aaaaaaaa-0000-4000-8000-000000000001';
const sha256Hex = async (b: Uint8Array) => createHash('sha256').update(b).digest('hex');
const usage = (cost: number) => ({ prompt_tokens: 1000, completion_tokens: 200, prompt_tokens_details: { cached_tokens: 0, cache_write_tokens: 0 }, cost });
const chunk = (model: string, delta: unknown, rest: Record<string, unknown> = {}) => ({ id: 'gen-x', model, provider: 'Google', choices: [{ delta, finish_reason: null }], ...rest });
const done = (model: string, cost: number) => chunk(model, {}, { choices: [{ delta: {}, finish_reason: 'stop' }], usage: usage(cost) });
function stream(events: unknown[], id = 'gen-x') {
  const bytes = new TextEncoder().encode(events.map(e => `data: ${JSON.stringify(e)}\n\n`).join('') + 'data: [DONE]\n\n');
  return new Response(new ReadableStream({ start(c) { c.enqueue(bytes); c.close(); } }), { headers: { 'x-generation-id': id } });
}
/** OpenRouter's headers, then nothing (keep-alive comments only) until the request is aborted. */
function silent(signal: AbortSignal | null | undefined) {
  return new Response(new ReadableStream({ start(c) {
    c.enqueue(new TextEncoder().encode(': OPENROUTER PROCESSING\n\n'));
    signal?.addEventListener('abort', () => c.error(signal.reason ?? new DOMException('stopped', 'AbortError')), { once: true });
  } }), { headers: { 'x-generation-id': 'gen-silent' } });
}
/** The 2026-10-25 refusal: 429, a generation id, OpenRouter's typed error (its text is never kept). */
const refused429 = () => new Response(JSON.stringify({ error: { code: 429, message: 'Resource exhausted. private question', metadata: { error_type: 'rate_limit_exceeded', provider_code: 'RESOURCE_EXHAUSTED' } } }),
  { status: 429, headers: { 'x-generation-id': 'gen-refused' } });

interface Sent { model: string; provider: Record<string, unknown>; reasoning: unknown; messages: unknown[] }
function harness(route: (sent: Sent, init: RequestInit | undefined, n: number) => Response | Promise<Response>, options: {
  fallback?: boolean; admit?: (p: Record<string, any>) => Record<string, unknown>; firstData?: { view: number; answer: number } } = {}) {
  const operationID = `bbbbbbbb-0000-4000-8000-${String(Math.floor(Math.random() * 1e12)).padStart(12, '0')}`;
  const calls: { name: string; p: Record<string, any> }[] = [], events: ChatEvent[] = [], logs: Record<string, unknown>[] = [], sent: Sent[] = [];
  const rpc: ChatDependencies['rpc'] = async (name, p) => { calls.push({ name, p });
    if (name === 'worker_openrouter_admit') return options.admit?.(p) ?? { granted: true, dispatched: true };
    return name === 'worker_openrouter_dispatch' || name === 'worker_openrouter_receipt' ? true : name === 'worker_reserve_chat' ? { replayed: false } : null; };
  const router = openRouterChat({ apiKey: 'fixture', sleep: async () => {}, firstDataMs: 2_000, waitingMs: 1_000, receiptWaitMs: 50,
    fetch: async (url, init) => {
      if (String(url).includes('/generation?id=')) return new Response(null, { status: 404 });
      const body = JSON.parse(String(init?.body)); sent.push(body);
      return route(body, init, sent.length);
    } });
  const generate = retryOnceWhenBusy(admittedModelCalls({ accountID, operationID, rpc, sha256Hex }, router), { sleep: async () => {}, random: () => 0.5 });
  const deps: ChatDependencies = { accountID, rpc, sha256Hex, generate, gemini: true, fallback: options.fallback ?? true,
    fallbackFirstDataMs: options.firstData ?? { view: 40, answer: 40 }, loadPaper: async () => null, log: e => logs.push(e), sleep: async () => {} };
  return { operationID, calls, events, logs, sent, deps,
    run: (body: Record<string, unknown> = {}) => runChat(deps, { operation_id: operationID, consent_version: 'cloud-ai-v6', mode: 'general',
      messages: [{ role: 'user', text: 'What does the dot mean?' }], profile: { model: 'gemini', effort: 'auto', length: 'standard' }, ...body },
      e => events.push(e), new AbortController().signal) };
}
const answer = (model: string, text = 'The dot is a time derivative.', cost = 0.0004) => stream([chunk(model, { content: text }), done(model, cost)]);

test('a 429 before the answer starts: Haiku on the same pinned route answers at once, labelled, charged only its own cost', async () => {
  const h = harness(sent => sent.model === GEMINI_OPENROUTER_MODEL ? refused429() : answer(sent.model));
  await h.run();
  assert.deepEqual(h.sent.map(s => s.model), [GEMINI_OPENROUTER_MODEL, FALLBACK_HAIKU], 'no same-model retry: the fallback is asked at once');
  // The fallback keeps the primary's privacy terms: the same single endpoint, ZDR, no data collection, no provider fallback.
  for (const s of h.sent) {
    assert.deepEqual(s.provider.only, ['google-vertex/us']); assert.equal(s.provider.zdr, true);
    assert.equal(s.provider.data_collection, 'deny'); assert.equal(s.provider.allow_fallbacks, false);
  }
  assert.deepEqual(h.events.filter(e => e.event === 'status').map(e => e.data), [{ kind: 'switching', model: 'claude-haiku-5-5' }]);
  const doneEvent = h.events.at(-1)!;
  assert.equal(doneEvent.event, 'done');
  assert.equal((doneEvent.data as any).model, 'claude-haiku-5-5', 'the answer is labelled with the model that wrote it');
  assert.equal((doneEvent.data as any).profile, 'gemini-low-standard', 'the reader\'s choice is unchanged');
  assert.equal((doneEvent.data as any).charged, true); assert.equal((doneEvent.data as any).credits, creditsFor(400));
  // Two admitted attempts in the one operation: the refused one at exactly zero, the fallback at its billed cost.
  const admits = h.calls.filter(c => c.name === 'worker_openrouter_admit').map(c => c.p.p_model);
  assert.deepEqual(admits, [GEMINI_MODEL, FALLBACK_HAIKU]);
  const finishes = h.calls.filter(c => c.name === 'worker_provider_attempt_finish').map(c => [c.p.p_state, c.p.p_actual_microusd]);
  assert.deepEqual(finishes, [['rejected', 0], ['succeeded', 400]]);
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.p;
  assert.equal(settle.p_ending, 'completed'); assert.equal(settle.p_actual_microusd, 400); assert.equal(settle.p_absorbed_microusd, 0);
  // The quote froze the chosen model; the fallback fits inside its hold (the database admits it only if it does).
  assert.equal(h.calls.find(c => c.name === 'worker_reserve_chat')!.p.p_quote.model, GEMINI_MODEL);
  assert.deepEqual(h.logs.find(l => l.event === 'chat_fallback'), { event: 'chat_fallback', operation_id: h.operationID, action: 'none',
    from: GEMINI_MODEL, to: 'claude-haiku-5-5', cause: 'rate_limited', status: 429, result: 'answered' });
  const line = h.logs.find(l => l.event === 'chat_answer')!;
  assert.equal(line.fallback, 'answered'); assert.equal(line.served_model, 'claude-haiku-5-5'); assert.equal(line.ending, 'completed');
  assert.doesNotMatch(JSON.stringify(h.logs), /private question|RESOURCE_EXHAUSTED/, 'only closed categories are logged');
});

test('a silent model is given up on at the fallback deadline; its unresolved ceiling is never the reader\'s', async () => {
  const h = harness((sent, init) => sent.model === GEMINI_OPENROUTER_MODEL ? silent(init?.signal) : answer(sent.model, 'Haiku answered.', 0.0003));
  await h.run();
  assert.deepEqual(h.sent.map(s => s.model), [GEMINI_OPENROUTER_MODEL, FALLBACK_HAIKU]);
  const doneEvent = h.events.at(-1)!;
  assert.equal(doneEvent.event, 'done'); assert.equal((doneEvent.data as any).model, 'claude-haiku-5-5');
  assert.equal((doneEvent.data as any).credits, creditsFor(300), 'the reader pays the fallback that answered, nothing for the silent one');
  const finishes = h.calls.filter(c => c.name === 'worker_provider_attempt_finish').map(c => c.p.p_state);
  assert.deepEqual(finishes, ['unknown', 'succeeded'], 'the silent attempt stays for the reconciler with its whole ceiling');
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.p;
  assert.equal(settle.p_ending, 'completed'); assert.equal(settle.p_actual_credits, creditsFor(300));
  assert.equal(h.logs.find(l => l.event === 'chat_fallback')!.cause, 'no_response');
  // The fallback had the whole output allowance (the silent attempt's estimate is not output that was used).
  assert.ok(h.calls.filter(c => c.name === 'worker_openrouter_admit')[1].p.p_reserved_units.output_tokens >= 6_000);
});

test('once the chosen model has written anything, a later failure is never re-asked of another model', async () => {
  const broken = (model: string) => new Response(new ReadableStream({ start(c) {
    c.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(chunk(model, { content: 'The dot' }))}\n\n`
      + `data: ${JSON.stringify({ ...chunk(model, { content: '' }), error: { code: 502, message: 'Upstream died. private', metadata: { error_type: 'provider_unavailable' } } })}\n\n`));
    c.close();
  } }), { headers: { 'x-generation-id': 'gen-x' } });
  const h = harness(sent => broken(sent.model));
  await h.run();
  assert.equal(h.sent.length, 1);
  assert.ok(!h.events.some(e => e.event === 'status' && (e.data as any).kind === 'switching'));
  assert.equal((h.events.at(-1)!.data as any).code, 'provider_unavailable');
  const line = h.logs.find(l => l.event === 'chat_answer')!;
  assert.equal(line.provider_error_type, 'provider_unavailable', 'OpenRouter\'s typed mid-stream cause, never its text');
  assert.equal(line.fallback, undefined);
  assert.doesNotMatch(JSON.stringify(h.logs), /Upstream died|private/);
});

test('no room for the fallback in the hold: the reader hears the chosen model\'s failure, as before', async () => {
  let admits = 0;
  const h = harness(sent => sent.model === GEMINI_OPENROUTER_MODEL ? refused429() : answer(sent.model),
    { admit: () => ++admits === 1 ? { granted: true, dispatched: true } : { granted: false, reason: 'operation_ceiling' } });
  await h.run();
  assert.equal(h.sent.length, 1, 'the fallback was not sent');
  const error = h.events.at(-1)!;
  assert.equal(error.event, 'error');
  assert.deepEqual(error.data, { code: 'provider_unavailable', credits: 0, charged: false, reason: 'provider', retry_after: 10 });
  assert.equal(h.logs.find(l => l.event === 'chat_fallback')!.result, 'not_sent');
  assert.equal(h.calls.find(c => c.name === 'worker_settle_chat')!.p.p_ending, 'provider');
});

test('no fallback where another model can\'t help or mustn\'t be asked, or when the switch is off', async () => {
  // Our key (401), the account's balance (402), the request itself (400) and a moderation refusal (403).
  for (const status of [400, 401, 402, 403]) {
    const h = harness(sent => sent.model === GEMINI_OPENROUTER_MODEL ? new Response(JSON.stringify({ error: { message: 'x' } }), { status }) : answer(sent.model));
    await h.run();
    assert.equal(h.sent.length, 1, `HTTP ${status}`);
    assert.equal(h.events.at(-1)!.event, 'error', `HTTP ${status}`);
  }
  // Off: the 429 gets the same-model retry (fixed: a 429 that names its generation is retried), then fails.
  const off = harness(sent => sent.model === GEMINI_OPENROUTER_MODEL ? refused429() : answer(sent.model), { fallback: false });
  await off.run();
  assert.deepEqual(off.sent.map(s => s.model), [GEMINI_OPENROUTER_MODEL, GEMINI_OPENROUTER_MODEL]);
  assert.equal(off.events.at(-1)!.event, 'error');
  // Models without a fallback (Claude, DeepSeek) are unchanged.
  assert.deepEqual(Object.keys(FALLBACK_MODELS), [GEMINI_MODEL]);
  const claude = harness(sent => refused429());
  await claude.run({ profile: { model: 'sonnet', effort: 'low', length: 'standard' } });
  assert.ok(claude.sent.every(s => s.model === 'anthropic/claude-sonnet-5.5'));
});

test('a figure explainer whose model fails before writing is explained by the fallback, streamed as usual', async () => {
  const walkthrough = JSON.stringify({ summary: 'A plot of reward against KL.', sections: [{ label: '(a)', title: 'Frontier', text: 'DPO is highest [¶2].', paragraphs: [2] }] });
  const h = harness(sent => sent.model === GEMINI_OPENROUTER_MODEL ? refused429() : answer(sent.model, walkthrough, 0.0015));
  const image = { id: 'F1', paragraph: 2, caption: 'Figure 2: Left. The frontier.', media_type: 'image/jpeg', data: Buffer.from([0xff, 0xd8, 0xff, 0xe0, ...Array(20).fill(7)]).toString('base64'), width: 10, height: 10 };
  await h.run({ mode: 'paper', local_context: { format: 'reader-local-context-v2', source: 'local', text: '[¶1] Intro.\n\n[¶2] Figure 2: Left. The frontier.' },
    action: 'figure', selection: { quote: image.caption }, messages: [{ role: 'user', text: 'Figure 2' }], figures: [image],
    capabilities: ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'] });
  assert.deepEqual(h.sent.map(s => s.model), [GEMINI_OPENROUTER_MODEL, FALLBACK_HAIKU]);
  // Haiku reads the same figure (the image block goes with the same request).
  assert.match(JSON.stringify(h.sent[1].messages), /data:image\/jpeg;base64/);
  const names = h.events.map(e => e.event);
  assert.ok(names.includes('figure_summary') && names.includes('figure'), names.join(','));
  const doneEvent = h.events.at(-1)!;
  assert.equal((doneEvent.data as any).model, 'claude-haiku-5-5'); assert.equal((doneEvent.data as any).profile, 'gemini-low-standard');
  // The figure view waits less for a silent model before its fallback than an answer does.
  assert.ok(FALLBACK_FIRST_DATA_MS.view < FALLBACK_FIRST_DATA_MS.answer && FALLBACK_FIRST_DATA_MS.answer < FIRST_DATA_DEADLINE_MS);
});

test('a concept of the paper explainer whose model is silent is asked of the fallback at the view deadline, streamed and labelled', async () => {
  const concept = JSON.stringify({ parts: 2, sections: [{ kind: 'what', title: 'What it is', text: 'A normaliser [¶2].' },
    { kind: 'where', title: 'Where it appears', places: [{ paragraph: 2, note: 'defined' }] }] });
  const h = harness((sent, init) => sent.model === GEMINI_OPENROUTER_MODEL ? silent(init?.signal) : answer(sent.model, concept, 0.0012),
    { firstData: { view: 40, answer: 5_000 } });
  await h.run({ mode: 'paper', local_context: { format: 'reader-local-context-v2', source: 'local', text: '[¶1] Intro.\n\n[¶2] Softmax.' },
    action: 'paper_concept', selection: { quote: 'Concept: Softmax\nKind: background the paper assumes' }, messages: [{ role: 'user', text: 'Go deeper: Softmax' }],
    capabilities: ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'] });
  assert.deepEqual(h.sent.map(s => s.model), [GEMINI_OPENROUTER_MODEL, FALLBACK_HAIKU], 'the view deadline (not the answer\'s) gave up on the silent model');
  // Gemini's minimal reasoning (the explainer's) is Claude's low for the fallback.
  assert.deepEqual(h.sent[1].reasoning, { effort: 'low' });
  const names = h.events.map(e => e.event);
  assert.ok(names.includes('concept_section') && names.includes('paper_concept'), names.join(','));
  assert.deepEqual(h.events.filter(e => e.event === 'status').map(e => e.data), [{ kind: 'switching', model: 'claude-haiku-5-5' }]);
  const doneEvent = h.events.at(-1)!;
  assert.equal((doneEvent.data as any).model, 'claude-haiku-5-5'); assert.equal((doneEvent.data as any).profile, 'gemini-low-standard');
  assert.equal((doneEvent.data as any).charged, true);
  assert.equal(h.calls.find(c => c.name === 'worker_settle_chat')!.p.p_action, 'answer');
  assert.ok(h.logs.some(l => l.event === 'chat_fallback' && l.action === 'paper_concept' && l.result === 'answered'));
});

test('the hold covers whichever model would cost more to write the answer; the reader still pays only what answered', async () => {
  // A long paper: Haiku's byte-estimated prompt passes its 100k-token tier, so its ceiling passes Flash's.
  const paper = { mode: 'paper', local_context: { format: 'reader-local-context-v2', source: 'local', text: `[¶1] ${'The model and its loss. '.repeat(7_000)}` } };
  const held = async (fallback: boolean) => {
    const h = harness(sent => sent.model === GEMINI_OPENROUTER_MODEL ? refused429() : answer(sent.model), { fallback });
    await h.run(paper);
    const ceilings = h.calls.filter(c => c.name === 'worker_openrouter_admit').map(c => c.p.p_ceiling_microusd as number);
    return { hold: h.calls.find(c => c.name === 'worker_reserve_chat')!.p.p_microusd as number, ceilings, h };
  };
  const off = await held(false), on = await held(true);
  assert.equal(off.hold, off.ceilings[0], 'without a fallback: the answer\'s own ceiling, as before');
  assert.ok(on.ceilings[1] > on.ceilings[0], 'Haiku\'s long-prompt ceiling passes Flash\'s here');
  assert.equal(on.hold, on.ceilings[1], 'with one: the larger ceiling, so the fallback fits after a refusal');
  assert.equal((on.h.events.at(-1)!.data as any).credits, creditsFor(400));
});

test('the fallback request: the same request for the other model; Gemini\'s minimal effort is Claude\'s low', () => {
  const params = chatRequestParams({ instructions: 'rules', paper: { title: 'P', text: '[¶1] Text.' }, turns: [{ role: 'user', text: 'Q' }], selection: null,
    model: { id: GEMINI_MODEL, effort: 'low' }, maxTokens: 3_500 });
  const minimal = { ...params, output_config: { ...params.output_config, effort: 'minimal' as const } };
  const next = fallbackParams(minimal, FALLBACK_HAIKU);
  assert.equal(next.model, FALLBACK_HAIKU); assert.equal(next.output_config?.effort, 'low');
  assert.equal(next.max_tokens, 3_500); assert.deepEqual(next.system, params.system); assert.deepEqual(next.messages, params.messages);
  assert.equal(fallbackParams(params, FALLBACK_HAIKU).output_config?.effort, 'low');
});

const failed = (changes: Partial<ProviderOutcome>): ProviderOutcome => ({ status: 'failed', failure: 'provider_error', messageID: 'gen-x', model: GEMINI_MODEL,
  stopReason: null, refusalCategory: null, attempts: [], exact: true, noOutput: true, ...changes });
test('which failures may be asked of a fallback', () => {
  assert.equal(fallbackEligible(failed({ httpStatus: 429 })), true);
  assert.equal(fallbackEligible(failed({ httpStatus: 503 })), true);
  assert.equal(fallbackEligible(failed({ httpStatus: 502, exact: false })), true);
  assert.equal(fallbackEligible(failed({ httpStatus: 404, failure: 'provider_rejected' })), true, 'the endpoint unavailable under the route\'s policy');
  assert.equal(fallbackEligible(failed({ stalled: true, exact: false })), true);
  assert.equal(fallbackEligible(failed({ exact: false })), true, 'a stream broken before its first output');
  for (const status of [400, 401, 402, 403, 413, 422]) assert.equal(fallbackEligible(failed({ httpStatus: status })), false, `HTTP ${status}`);
  assert.equal(fallbackEligible(failed({ noOutput: undefined })), false, 'output had arrived');
  assert.equal(fallbackEligible(failed({ failure: 'aborted' })), false, 'the reader stopped it');
  assert.equal(fallbackEligible(failed({ failure: 'provider_billing', httpStatus: 402 })), false);
  assert.equal(fallbackEligible(failed({ cause: 'limit' })), false); assert.equal(fallbackEligible(failed({ cause: 'server' })), false);
  assert.equal(fallbackEligible(failed({ messageID: null })), false, 'never dispatched by our own server');
  assert.equal(fallbackEligible({ ...failed({}), status: 'complete' }), false);
});

test('OpenRouter\'s typed causes become our closed categories; a 503 refusal is exactly zero', async () => {
  assert.equal(errorKind('rate_limit_exceeded'), 'rate_limited'); assert.equal(errorKind(null, 429), 'rate_limited');
  assert.equal(errorKind('provider_overloaded'), 'overloaded'); assert.equal(errorKind(null, 503), 'overloaded');
  assert.equal(errorKind('provider_unavailable'), 'provider_unavailable'); assert.equal(errorKind(null, 502), 'provider_unavailable');
  assert.equal(errorKind('timeout'), 'timeout'); assert.equal(errorKind(null, 504), 'timeout');
  assert.equal(errorKind('something new'), 'unknown');
  const params = chatRequestParams({ instructions: 'rules', paper: null, turns: [{ role: 'user', text: 'Q' }], selection: null, model: { id: GEMINI_MODEL, effort: 'low' } });
  const attribution = { accountID, operationID: 'bbbbbbbb-0000-4000-8000-000000000099', attemptID: 'cccccccc-0000-4000-8000-000000000099', feature: 'chat', caller: 'chat', dispatch: async () => true };
  for (const [status, reason, exact] of [[503, 'overloaded', true], [502, 'provider_unavailable', false], [429, 'rate_limited', true], [504, 'timeout', false]] as const) {
    const generate = openRouterChat({ apiKey: 'k', fetch: async () => new Response(JSON.stringify({ error: { message: 'no' } }), { status, headers: { 'x-generation-id': 'gen-r' } }) });
    const outcome = await generate(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 10, onText: () => {} });
    assert.equal(outcome.rejectionReason, reason, `HTTP ${status}`); assert.equal(outcome.exact, exact, `HTTP ${status}`);
    assert.equal(outcome.noOutput, true); assert.equal(outcome.firstDataMs, undefined);
  }
  // A request's own first-data deadline (the answer with a fallback) wins over the adapter's.
  const generate = openRouterChat({ apiKey: 'k', firstDataMs: 60_000, sleep: async () => {}, fetch: async (_u, init) => silent(init?.signal) });
  const started = Date.now();
  const stalled = await generate(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 10, onText: () => {}, firstDataMs: 30 });
  assert.equal(stalled.stalled, true); assert.equal(stalled.noOutput, true); assert.ok(Date.now() - started < 5_000);
  // The time to the first output is measured and recorded with the attempt (migration 0161: first_data_ms).
  let clock = 1_000;
  const quick = openRouterChat({ apiKey: 'k', now: () => (clock += 250), fetch: async () => answer(GEMINI_OPENROUTER_MODEL) });
  const ok = await quick(params, { attribution, signal: new AbortController().signal, inputEstimateTokens: 10, onText: () => {} });
  assert.equal(ok.status, 'complete'); assert.equal(ok.noOutput, undefined); assert.ok(typeof ok.firstDataMs === 'number' && ok.firstDataMs > 0);
});

test('first_data_ms is recorded with the finished attempt, as a whole number of milliseconds', async () => {
  const h = harness(sent => answer(sent.model));
  await h.run();
  const finish = h.calls.find(c => c.name === 'worker_provider_attempt_finish')!.p;
  assert.ok(Number.isSafeInteger(finish.p_actual_units.first_data_ms) && finish.p_actual_units.first_data_ms >= 0);
});

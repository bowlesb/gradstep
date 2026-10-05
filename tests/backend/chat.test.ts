import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import type Anthropic from '@anthropic-ai/sdk';
import {
  ADD_PAPER_TOOL, attemptsFromUsage, CHAT_MAX_TOKENS, chatRequestParams, CREATE_DIAGRAM_TOOL, promptCharacters, WEB_SEARCH_TOOL, webSearchHoldMicrousd, createAnthropicClient, creditsFor, FALLBACK_BETA, holdFor, priceAttempts, ratesFor,
  streamChat, UNKNOWN_MODEL_RATES, type ProviderOutcome, type StreamOptions,
} from '../../supabase/functions/_shared/anthropic.ts';
import {
  canonicalRequest, chatInstructions, diagramRequest, ingestReport, paperRequest, sourcesText, readChatBody, RpcFailure, runChat, sseFrame, validateChatRequest,
  type ChatDependencies, type ChatEvent, type LogEntry,
} from '../../supabase/functions/_shared/chat.ts';

const account = 'aaaaaaaa-0000-4000-8000-000000000001';
const operation = 'bbbbbbbb-0000-4000-8000-000000000002';
const documentID = 'cccccccc-0000-4000-8000-000000000003';
const secretQuestion = 'What does the attention scaling factor do? (private-question-marker)';
const paperText = '# Attention\n\nWe scale by \\( 1/\\sqrt{d_k} \\). '.repeat(40);

function paperBody(overrides: Record<string, unknown> = {}) {
  return { operation_id: operation, consent_version: 'cloud-ai-v1', mode: 'paper', document_id: documentID,
    messages: [{ role: 'user', text: secretQuestion }], ...overrides };
}
function generalBody(overrides: Record<string, unknown> = {}) {
  return { operation_id: operation, consent_version: 'cloud-ai-v1', mode: 'general', messages: [{ role: 'user', text: 'Hello' }], ...overrides };
}

test('validation accepts bounded paper and general requests and normalizes identifiers', () => {
  const paper = validateChatRequest(paperBody({ operation_id: operation.toUpperCase(), selection: { quote: 'a passage' } }));
  assert.equal(paper.operationID, operation); assert.equal(paper.documentID, documentID); assert.equal(paper.selection, 'a passage');
  const general = validateChatRequest(generalBody({ document_id: null,
    messages: [{ role: 'user', text: 'q1' }, { role: 'assistant', text: 'a1' }, { role: 'user', text: 'q2' }] }));
  assert.equal(general.documentID, null); assert.equal(general.turns.length, 3);
});

test('validation rejects unknown, missing, misplaced or oversized fields', () => {
  const longTurns = Array.from({ length: 61 }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', text: 'x' }));
  const cases: unknown[] = [
    null, [], 'text', paperBody({ extra: true }), paperBody({ consent_version: 'cloud-ai-v0' }), paperBody({ mode: 'other' }),
    paperBody({ document_id: undefined }), paperBody({ document_id: 'not-a-uuid' }), generalBody({ document_id: documentID }),
    paperBody({ operation_id: '1234' }), paperBody({ messages: [] }), paperBody({ messages: longTurns }),
    paperBody({ messages: [{ role: 'assistant', text: 'x' }, { role: 'user', text: 'y' }] }),
    paperBody({ messages: [{ role: 'user', text: 'x' }, { role: 'assistant', text: 'y' }] }),
    paperBody({ messages: [{ role: 'system', text: 'x' }] }), paperBody({ messages: [{ role: 'user', text: '   ' }] }),
    paperBody({ messages: [{ role: 'user', text: 'x', extra: 1 }] }), paperBody({ messages: [{ role: 'user', text: 7 }] }),
    paperBody({ messages: [{ role: 'user', text: 'é'.repeat(100_001) }] }),
    paperBody({ selection: { quote: 'q'.repeat(4001) } }), paperBody({ selection: { quote: 'q', page: 1 } }), paperBody({ selection: 'q' }),
    paperBody({ action: 'ingest' }), paperBody({ action: 'define', selection: { quote: 'q' } }), paperBody({ action: true, selection: { quote: 'q' } }),
  ];
  for (const body of cases) assert.throws(() => validateChatRequest(body), { code: 'invalid_request' });
  // 4000 Unicode scalars (not UTF-16 units) is the selection bound.
  assert.equal(validateChatRequest(paperBody({ selection: { quote: '𝑥'.repeat(4000) } })).selection?.length, 8000);
});

test('canonical request digests are independent of input key order', () => {
  const a = validateChatRequest(paperBody());
  const b = validateChatRequest(Object.fromEntries(Object.entries(paperBody()).reverse()));
  assert.equal(canonicalRequest(a), canonicalRequest(b));
  assert.notEqual(canonicalRequest(a), canonicalRequest(validateChatRequest(paperBody({ selection: { quote: 'x' } }))));
  const quoted = paperBody({ selection: { quote: 'x' } });
  assert.notEqual(canonicalRequest(validateChatRequest(quoted)), canonicalRequest(validateChatRequest({ ...quoted, action: 'ingest' })));
  assert.equal(canonicalRequest(validateChatRequest(quoted)), canonicalRequest(validateChatRequest({ ...quoted, action: null })));
});

test('pricing follows the beta credit rate card and never undercharges unknown models', () => {
  assert.deepEqual(ratesFor('claude-sonnet-5-5').known, true);
  assert.deepEqual(ratesFor('claude-sonnet-5-5-20261001').known, true);
  assert.deepEqual(ratesFor('claude-sonnet-5').rates.output, 10);
  assert.deepEqual(ratesFor('claude-mystery').rates, UNKNOWN_MODEL_RATES);
  assert.deepEqual(ratesFor(null).rates, UNKNOWN_MODEL_RATES);
  assert.equal(ratesFor('__proto__').known, false);
  // 1M input at $2, 1M output at $10, 1M cache write at $2.50, 1M cache read at $0.20.
  const usage = { input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 0, cacheRead: 1_000_000, output: 1_000_000 };
  assert.equal(priceAttempts([{ model: 'claude-sonnet-5-5', usage, estimated: false }]), 14_700_000);
  assert.equal(priceAttempts([{ model: 'unknown', usage, estimated: false }]), 29_400_000);
  assert.equal(creditsFor(0), 0); assert.equal(creditsFor(1), 1); assert.equal(creditsFor(5_000), 1); assert.equal(creditsFor(5_001), 2);
  // Hold: weighted chars/3 tokens at the cache-write rate plus the whole
  // output budget, times the fallback headroom (3).
  assert.deepEqual(holdFor(300_000, 8_000), { inputTokens: 100_000, microusd: 990_000, credits: 198 });
  assert.equal(holdFor(1, 8_000).microusd, 240_008);
});

test('fallback iterations are priced per serving model', () => {
  const usage = {
    input_tokens: 10, output_tokens: 20, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, cache_creation: null,
    iterations: [
      { type: 'message', model: 'claude-sonnet-5-5', input_tokens: 1000, output_tokens: 50, cache_creation_input_tokens: 400, cache_read_input_tokens: 0,
        cache_creation: { ephemeral_5m_input_tokens: 300, ephemeral_1h_input_tokens: 100 } },
      { type: 'fallback_message', model: 'claude-future-1', input_tokens: 1000, output_tokens: 200, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, cache_creation: null },
    ],
  } as unknown as Anthropic.Beta.Messages.BetaUsage;
  const attempts = attemptsFromUsage('claude-future-1', usage);
  assert.equal(attempts.length, 2);
  assert.deepEqual(attempts[0].usage, { input: 1000, cacheWrite5m: 300, cacheWrite1h: 100, cacheRead: 0, output: 50 });
  assert.equal(priceAttempts(attempts), (1000 * 2 + 300 * 2.5 + 100 * 4 + 50 * 10) + (1000 * 4 + 200 * 20));
  const single = attemptsFromUsage('claude-sonnet-5-5', { input_tokens: 3, output_tokens: 4, cache_creation_input_tokens: null,
    cache_read_input_tokens: 5, cache_creation: null, iterations: null } as unknown as Anthropic.Beta.Messages.BetaUsage);
  assert.deepEqual(single, [{ model: 'claude-sonnet-5-5', estimated: false, usage: { input: 3, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 5, output: 4 } }]);
});

test('request params cache the paper prefix and enable adaptive thinking with server fallback', () => {
  const params = chatRequestParams({ instructions: chatInstructions('paper'), paper: { title: 'A "quoted" <title>', text: paperText },
    turns: [{ role: 'user', text: 'q1' }, { role: 'assistant', text: 'a1' }, { role: 'user', text: 'q2' }], selection: 'the passage' });
  assert.equal(params.model, 'claude-sonnet-5-5'); assert.equal(params.max_tokens, CHAT_MAX_TOKENS);
  assert.deepEqual(params.thinking, { type: 'adaptive' }); assert.deepEqual(params.output_config, { effort: 'low' });
  assert.deepEqual(params.betas, [FALLBACK_BETA]); assert.equal(params.fallbacks, 'default');
  const system = params.system as Anthropic.Beta.Messages.BetaTextBlockParam[];
  assert.equal(system.length, 2); assert.equal(system[0].cache_control, undefined);
  assert.deepEqual(system[1].cache_control, { type: 'ephemeral' });
  assert.ok(system[1].text.startsWith('<paper title="A  quoted   title">\n'));
  assert.ok(system[1].text.endsWith(`${paperText}\n</paper>`));
  assert.match(system[0].text, /\\\( \.\.\. \\\)/); assert.match(system[0].text, /\\\[ \.\.\. \\\]/);
  assert.deepEqual(params.messages[1], { role: 'assistant', content: 'a1' });
  const last = params.messages[2].content as Anthropic.Beta.Messages.BetaTextBlockParam[];
  assert.equal(last[0].text, '<selected_passage>\nthe passage\n</selected_passage>'); assert.equal(last[1].text, 'q2');
  const general = chatRequestParams({ instructions: chatInstructions('general'), paper: null, turns: [{ role: 'user', text: 'q' }], selection: null });
  assert.equal((general.system as unknown[]).length, 1); assert.deepEqual(general.messages, [{ role: 'user', content: 'q' }]);
});

test('ingest requests carry only add_paper; other requests carry only create_diagram', () => {
  const turns = [{ role: 'user' as const, text: 'Find and add the paper referenced in this passage' }];
  const ingest = chatRequestParams({ instructions: chatInstructions('paper', 'ingest'), paper: { title: 'T', text: paperText }, turns, selection: '[12] DPO', tools: [ADD_PAPER_TOOL] });
  assert.deepEqual(ingest.tools, [ADD_PAPER_TOOL]); assert.equal(ingest.tool_choice, undefined);
  const ingestSystem = (ingest.system as Anthropic.Beta.Messages.BetaTextBlockParam[])[0].text;
  assert.match(ingestSystem, /call add_paper once/); assert.doesNotMatch(ingestSystem, /create_diagram/);
  const plain = chatRequestParams({ instructions: chatInstructions('paper'), paper: { title: 'T', text: paperText }, turns, selection: '[12] DPO', tools: [CREATE_DIAGRAM_TOOL] });
  assert.deepEqual(plain.tools, [CREATE_DIAGRAM_TOOL]);
  const plainSystem = (plain.system as Anthropic.Beta.Messages.BetaTextBlockParam[])[0].text;
  assert.match(plainSystem, /explicitly asks for a diagram/); assert.doesNotMatch(plainSystem, /add_paper/);
  const none = chatRequestParams({ instructions: chatInstructions('general'), paper: null, turns, selection: null });
  assert.equal(none.tools, undefined);
  // The hold covers the tool definition too.
  assert.ok(promptCharacters(ingest) > promptCharacters({ ...ingest, tools: undefined }) + JSON.stringify(ADD_PAPER_TOOL).length - 1);
});

test('create_diagram input must be a bounded Mermaid diagram', () => {
  assert.deepEqual(diagramRequest({ title: ' DPO\n pipeline ', mermaid: '%% comment\r\nflowchart LR\r\n a --> b' }),
    { title: 'DPO pipeline', source: '%% comment\nflowchart LR\n a --> b' });
  assert.deepEqual(diagramRequest({ title: 'Seq', mermaid: 'sequenceDiagram\n A->>B: hi' }), { title: 'Seq', source: 'sequenceDiagram\n A->>B: hi' });
  for (const bad of [null, [], 'x', {}, { title: 'x' }, { mermaid: 'graph TD' }, { title: '', mermaid: 'graph TD' }, { title: 'x', mermaid: '<svg/>' },
    { title: 'x', mermaid: 'flowchart LR', extra: 1 }, { title: 'x'.repeat(121), mermaid: 'graph TD' }, { title: 'x', mermaid: 'graph TD\n' + 'a'.repeat(12_001) },
    { title: 'x', mermaid: 'graphic novel' }]) {
    assert.equal(diagramRequest(bad), null, JSON.stringify(bad).slice(0, 60));
  }
});

test('a drawn diagram is relayed once, before done, and never stored or logged as text', async () => {
  let tools: unknown;
  const h = harness({ generate: async (params, stream) => {
    tools = (params as { tools?: unknown }).tools;
    stream.onText('Here is the DPO pipeline.');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'create_diagram', input: { title: 'DPO', mermaid: 'flowchart LR\n x --> y' } }] });
  } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual(tools, [CREATE_DIAGRAM_TOOL]);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'diagram', 'done']);
  assert.deepEqual(h.events[1].data, { title: 'DPO', source: 'flowchart LR\n x --> y' });
  assert.equal((h.events[2].data as { stop_reason: string }).stop_reason, 'end_turn');
  assert.deepEqual(h.logs, [{ event: 'chat_diagram', operation_id: operation }]);

  const invalid = harness({ generate: async (_p, stream) => { stream.onText('x');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'create_diagram', input: { title: 'x', mermaid: '<script>' } }] }); } });
  await runChat(invalid.deps, paperBody(), invalid.emit, new AbortController().signal);
  assert.deepEqual(invalid.events.map(e => e.event), ['delta', 'done']);
  assert.deepEqual(invalid.logs, [{ event: 'chat_diagram_invalid_input', operation_id: operation }]);

  // A diagram without any answer text gets a caption so the answer is kept.
  const bare = harness({ generate: async () =>
    completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'create_diagram', input: { title: 'Flow', mermaid: 'graph TD; a-->b' } }] }) });
  await runChat(bare.deps, paperBody(), bare.emit, new AbortController().signal);
  assert.deepEqual(bare.events.map(e => e.event), ['delta', 'diagram', 'done']);
  assert.deepEqual(bare.events[0].data, { text: 'Diagram: “Flow”' });

  // Cut off by max_tokens, or asked on an Ingest request: never relayed.
  const truncated = harness({ generate: async (_p, stream) => { stream.onText('x');
    return completeOutcome({ stopReason: 'max_tokens', toolCalls: [{ name: 'create_diagram', input: { title: 'x', mermaid: 'graph TD' } }] }); } });
  await runChat(truncated.deps, paperBody(), truncated.emit, new AbortController().signal);
  assert.ok(!truncated.events.some(e => e.event === 'diagram'));
  const ingest = harness({ generate: async (_p, stream) => { stream.onText('x');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'create_diagram', input: { title: 'x', mermaid: 'graph TD' } }] }); } });
  await runChat(ingest.deps, ingestBody(), ingest.emit, new AbortController().signal);
  assert.ok(!ingest.events.some(e => e.event === 'diagram'));
});

test('add_paper input is validated strictly and reports are inert text', () => {
  assert.deepEqual(paperRequest({ title: '  Direct  Preference Optimization ', year: 2023, first_author: ' R.  Rafailov', arxiv_id: '2305.18290' }),
    { title: 'Direct Preference Optimization', year: 2023, firstAuthor: 'R. Rafailov', arxivID: '2305.18290' });
  assert.deepEqual(paperRequest({ title: 'Attention Is All You Need', year: 17 }), { title: 'Attention Is All You Need', year: null, firstAuthor: null, arxivID: null });
  for (const bad of [null, [], 'title', {}, { title: 'ab' }, { title: 'x'.repeat(401) }, { title: 'Valid title', extra: 1 }, { title: 7 }]) {
    assert.equal(paperRequest(bad), null);
  }
  const request = { title: 'A [link](https://evil.example) `x` <b>', year: null, firstAuthor: null, arxivID: null };
  const report = ingestReport(request, null, 'not_found');
  assert.ok(!/[[\]`<>]/.test(report)); assert.match(report, /couldn't find/);
  const dpo = { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 };
  assert.match(ingestReport(request, dpo, 'added'), /Queued “Direct Preference Optimization” \(arXiv:2305\.18290\) for your library/);
  assert.match(ingestReport(request, dpo, 'present'), /is already in your library/);
  assert.match(ingestReport(request, dpo, 'failed'), /couldn't add it right now/);
  assert.match(ingestReport(request, null, 'unavailable'), /couldn't search arXiv right now/);
});

function ingestBody() {
  return paperBody({ selection: { quote: '[12] Rafailov et al. Direct preference optimization. NeurIPS 2023.' }, action: 'ingest' });
}
const toolGenerate = (input: unknown) => async (_params: unknown, stream: StreamOptions) => {
  stream.onText('That is DPO (Rafailov et al., 2023).');
  return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'add_paper', input }] });
};

test('ingest adds one title-matched paper after settlement and reports it in the answer', async () => {
  const found: unknown[] = [], imported: string[] = [];
  let tools: unknown;
  const h = harness({ generate: async (params, stream) => { tools = (params as { tools?: unknown }).tools; return toolGenerate({ title: 'Direct Preference Optimization', year: 2023 })(params, stream); } });
  h.deps.findPaper = async wanted => { found.push(wanted); return { status: 'found', paper: { source_id: '2305.18290', title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', year: 2023 } }; };
  h.deps.importPaper = async id => { imported.push(id); assert.ok(names(h.calls).includes('worker_settle_operation')); return 'added'; };
  await runChat(h.deps, ingestBody(), h.emit, new AbortController().signal);
  assert.deepEqual(tools, [ADD_PAPER_TOOL]);
  assert.deepEqual(found, [{ title: 'Direct Preference Optimization', year: 2023, firstAuthor: null, arxivID: null }]);
  assert.deepEqual(imported, ['2305.18290']);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.match((h.events[1].data as { text: string }).text, /^\n\nQueued “Direct Preference Optimization: Your Language Model is Secretly a Reward Model” \(arXiv:2305\.18290\)/);
  assert.equal((h.events[2].data as { stop_reason: string }).stop_reason, 'end_turn');
  assert.deepEqual(h.logs, [{ event: 'chat_ingest', operation_id: operation, result: 'added' }]);
});

test('ingest reports a missing paper, ignores invalid tool input and never adds for non-ingest requests', async () => {
  const missing = harness({ generate: toolGenerate({ title: 'A Paper Not On arXiv' }) });
  let imports = 0;
  missing.deps.findPaper = async () => ({ status: 'not_found' }); missing.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(missing.deps, ingestBody(), missing.emit, new AbortController().signal);
  assert.match((missing.events[1].data as { text: string }).text, /couldn't find “A Paper Not On arXiv” on arXiv/);
  assert.equal(imports, 0);

  const invalid = harness({ generate: toolGenerate({ title: 'Valid title', url: 'https://evil.example' }) });
  invalid.deps.findPaper = async () => { throw new Error('must not search'); }; invalid.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(invalid.deps, ingestBody(), invalid.emit, new AbortController().signal);
  assert.deepEqual(invalid.events.map(e => e.event), ['delta', 'done']);
  assert.deepEqual(invalid.logs, [{ event: 'chat_ingest_invalid_input', operation_id: operation }]);

  // A tool call on an ordinary question (no tools were offered) is ignored.
  const ordinary = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  ordinary.deps.findPaper = async () => { throw new Error('must not search'); }; ordinary.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(ordinary.deps, paperBody({ selection: { quote: 'x' } }), ordinary.emit, new AbortController().signal);
  assert.equal(imports, 0); assert.equal(ordinary.events.at(-1)?.event, 'done');

  const failing = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  failing.deps.findPaper = async () => ({ status: 'found', paper: { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 } });
  failing.deps.importPaper = async () => { throw new Error('library_active_import_limit'); };
  await runChat(failing.deps, ingestBody(), failing.emit, new AbortController().signal);
  assert.match((failing.events[1].data as { text: string }).text, /couldn't add it right now/);

  const busy = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  busy.deps.findPaper = async () => { throw new Error('search_busy'); }; busy.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(busy.deps, ingestBody(), busy.emit, new AbortController().signal);
  assert.match((busy.events[1].data as { text: string }).text, /couldn't search arXiv right now/);

  // A tool call cut off by max_tokens is never executed.
  const truncated = harness({ generate: async (_p, stream) => { stream.onText('That is DPO.');
    return completeOutcome({ stopReason: 'max_tokens', toolCalls: [{ name: 'add_paper', input: { title: 'Direct Pref' } }] }); } });
  truncated.deps.findPaper = async () => { throw new Error('must not search'); }; truncated.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(truncated.deps, ingestBody(), truncated.emit, new AbortController().signal);
  assert.equal(imports, 0); assert.equal((truncated.events.at(-1)?.data as { stop_reason: string }).stop_reason, 'max_tokens');
});

test('stopping during the ingest search settles the answer and never imports', async () => {
  const client = new AbortController();
  let imports = 0;
  const h = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization', first_author: 'R. Rafailov', year: 2023 }) });
  h.deps.findPaper = async (_wanted, signal) => {
    client.abort(); assert.ok(signal.aborted);
    return { status: 'found', paper: { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 } };
  };
  h.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(h.deps, ingestBody(), h.emit, client.signal);
  assert.equal(imports, 0);
  assert.ok(names(h.calls).includes('worker_settle_operation'));
  assert.deepEqual(h.logs, [{ event: 'chat_ingest', operation_id: operation, result: 'stopped' }]);
  assert.ok(!h.events.some(e => e.event === 'done'));
});

test('the ingest budget bounds post-settlement work', async () => {
  const h = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  h.deps.ingestDeadlineMs = 20;
  h.deps.findPaper = (_wanted, signal) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted'))));
  h.deps.importPaper = async () => 'added';
  await runChat(h.deps, ingestBody(), h.emit, new AbortController().signal);
  assert.match((h.events[1].data as { text: string }).text, /couldn't search arXiv right now/);
  assert.equal(h.events.at(-1)?.event, 'done');
});

test('web search is offered only when the server enables it, and never on Ingest', async () => {
  const seen: unknown[] = [];
  const capture = (generateText: string) => async (params: unknown, stream: StreamOptions) => {
    seen.push((params as { tools?: unknown }).tools); stream.onText(generateText); return completeOutcome();
  };
  const off = harness({ generate: capture('a') });
  await runChat(off.deps, paperBody(), off.emit, new AbortController().signal);
  const on = harness({ generate: capture('b') }); on.deps.webSearch = true;
  await runChat(on.deps, paperBody(), on.emit, new AbortController().signal);
  const ingest = harness({ generate: capture('c') }); ingest.deps.webSearch = true;
  await runChat(ingest.deps, ingestBody(), ingest.emit, new AbortController().signal);
  assert.deepEqual(seen, [[CREATE_DIAGRAM_TOOL], [CREATE_DIAGRAM_TOOL, WEB_SEARCH_TOOL], [ADD_PAPER_TOOL]]);
  assert.deepEqual(WEB_SEARCH_TOOL, { type: 'web_search_20260209', name: 'web_search', max_uses: 3 });
  assert.match(chatInstructions('paper', null, true), /You can search the web/);
  assert.doesNotMatch(chatInstructions('paper', null, false), /search the web/);
  // The hold grows by the search allowance.
  const holdOff = Number(off.calls.find(c => c.name === 'worker_reserve_operation')!.params.p_microusd);
  const holdOn = Number(on.calls.find(c => c.name === 'worker_reserve_operation')!.params.p_microusd);
  assert.ok(holdOn >= holdOff + webSearchHoldMicrousd());
});

test('searches are charged and cited sources are shown with the answer', async () => {
  const h = harness({ generate: async (_p, stream) => {
    stream.onText('DPO has follow-ups such as IPO.');
    return completeOutcome({ webSearches: 2, sources: [{ url: 'https://arxiv.org/abs/2310.12036', title: 'A General Theoretical Paradigm [IPO]' },
      { url: 'javascript:alert(1)', title: 'bad' }, { url: 'https://example.org/blog', title: null }] });
  } });
  h.deps.webSearch = true;
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  const settle = h.calls.find(c => c.name === 'worker_settle_operation')!.params;
  // 900 input at $2 + 300 output at $10 = 4,800 micro-USD, plus two searches at $0.01.
  assert.equal(settle.p_actual_microusd, 24_800); assert.equal(settle.p_actual_credits, 5);
  assert.equal(h.calls.find(c => c.name === 'worker_record_provider_usage')!.params.p_microusd, 24_800);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.equal((h.events[1].data as { text: string }).text,
    '\n\nSources:\n1. A General Theoretical Paradigm IPO — https://arxiv.org/abs/2310.12036\n2. https://example.org/blog');
  assert.equal(sourcesText([]), '');
});

test('SSE frames and bounded body reading', async () => {
  assert.equal(sseFrame({ event: 'delta', data: { text: 'a\nb' } }), 'event: delta\ndata: {"text":"a\\nb"}\n\n');
  const ok = new Request('https://x.invalid', { method: 'POST', body: JSON.stringify(generalBody()) });
  assert.deepEqual(await readChatBody(ok), generalBody());
  await assert.rejects(readChatBody(new Request('https://x.invalid', { method: 'POST', body: 'x'.repeat(101) }), 100), { code: 'invalid_request' });
  await assert.rejects(readChatBody(new Request('https://x.invalid', { method: 'POST', body: '{"a":' })), { code: 'invalid_request' });
  await assert.rejects(readChatBody(new Request('https://x.invalid', { method: 'POST', body: new Uint8Array([0xff, 0xfe]) })), { code: 'invalid_request' });
});

type Call = { name: string; params: Record<string, unknown> };
type Script = Record<string, (params: Record<string, unknown>) => unknown>;
function completeOutcome(changes: Partial<ProviderOutcome> = {}): ProviderOutcome {
  return { status: 'complete', failure: null, messageID: 'msg_01', model: 'claude-sonnet-5-5', stopReason: 'end_turn', refusalCategory: null,
    attempts: [{ model: 'claude-sonnet-5-5', estimated: false, usage: { input: 900, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 300 } }],
    exact: true, ...changes };
}
function harness(options: { script?: Script; generate?: ChatDependencies['generate']; paper?: Uint8Array | null } = {}) {
  const calls: Call[] = [], events: ChatEvent[] = [], logs: LogEntry[] = [];
  let generations = 0;
  const script: Script = {
    worker_consume_request: () => null,
    worker_chat_context: () => ({ bucket: 'paper-assets', path: 'artifacts/x/standalone.mmd', title: 'Attention' }),
    worker_reserve_operation: params => ({ id: params.p_id, state: 'reserved', replayed: false }),
    worker_settle_operation: () => null,
    worker_record_provider_usage: () => null,
    ...options.script,
  };
  const generate = options.generate === undefined
    ? async (_params: unknown, stream: StreamOptions) => { stream.onText('Scaling keeps '); stream.onText('logits bounded.'); return completeOutcome(); }
    : options.generate;
  const deps: ChatDependencies = {
    accountID: account,
    rpc: async (name, params) => {
      calls.push({ name, params });
      const handler = script[name]; assert.ok(handler, `unexpected rpc ${name}`);
      return handler(params);
    },
    loadPaper: async () => options.paper === undefined ? new TextEncoder().encode(paperText) : options.paper,
    generate: generate ? async (params, stream) => { generations++; return generate(params, stream); } : null,
    sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'),
    log: entry => logs.push(entry),
    sleep: async () => {},
  };
  return { deps, calls, events, logs, emit: (event: ChatEvent) => events.push(event), generations: () => generations };
}
const names = (calls: Call[]) => calls.map(call => call.name);
function noPlaintext(logs: LogEntry[]) {
  const serialized = JSON.stringify(logs);
  assert.ok(!serialized.includes('private-question-marker') && !serialized.includes('Attention\n'));
}

test('a paper answer holds, streams, settles once and records usage', async () => {
  const h = harness();
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_chat_context', 'worker_reserve_operation', 'worker_settle_operation', 'worker_record_provider_usage']);
  const reserve = h.calls[2].params, settle = h.calls[3].params, usage = h.calls[4].params;
  assert.equal(reserve.p_kind, 'chat'); assert.equal(reserve.p_rate_version, 'beta-credits-v1'); assert.equal(reserve.p_id, operation);
  assert.match(String(reserve.p_request_sha256), /^\\x[0-9a-f]{64}$/);
  const expected = createHash('sha256').update(canonicalRequest(validateChatRequest(paperBody()))).digest('hex');
  assert.equal(reserve.p_request_sha256, `\\x${expected}`);
  assert.ok(Number(reserve.p_credits) >= 16 && Number(reserve.p_microusd) >= 80_000);
  // 900 input at $2 + 300 output at $10 = 4,800 micro-USD -> 1 credit.
  assert.deepEqual(settle, { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 4_800 });
  assert.equal(usage.p_provider, 'anthropic'); assert.equal(usage.p_provider_event_id, 'msg_01'); assert.equal(usage.p_microusd, 4_800);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.deepEqual(h.events[2].data, { stop_reason: 'end_turn', credits: 1,
    usage: { input_tokens: 900, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 300 } });
  noPlaintext(h.logs); assert.equal(h.logs.length, 0);
});

test('general chat skips paper context', async () => {
  const h = harness();
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_reserve_operation', 'worker_settle_operation', 'worker_record_provider_usage']);
  assert.equal(h.events.at(-1)?.event, 'done');
});

test('client disconnect aborts the provider and still settles actual usage once', async () => {
  const client = new AbortController();
  const h = harness({ generate: async (_params, stream) => {
    stream.onText('partial ');
    client.abort();
    assert.ok(stream.signal.aborted, 'provider signal follows the client');
    stream.onText('late text');
    return { status: 'failed', failure: 'aborted', messageID: 'msg_02', model: 'claude-sonnet-5-5', stopReason: null, refusalCategory: null,
      attempts: [{ model: 'claude-sonnet-5-5', estimated: true, usage: { input: 1000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 100 } }], exact: false };
  } });
  await runChat(h.deps, paperBody(), h.emit, client.signal);
  assert.deepEqual(h.events, [{ event: 'delta', data: { text: 'partial ' } }]);
  const settles = h.calls.filter(c => c.name === 'worker_settle_operation');
  assert.equal(settles.length, 1);
  assert.deepEqual(settles[0].params, { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 3_000 });
  const usage = h.calls.find(c => c.name === 'worker_record_provider_usage')!.params;
  assert.equal((usage.p_units as { estimated: boolean }).estimated, true);
});

test('a provider error mid-stream settles once and reports provider_unavailable', async () => {
  const h = harness({ generate: async (_params, stream) => {
    stream.onText('half an answer');
    return { status: 'failed', failure: 'provider_error', messageID: 'msg_03', model: 'claude-sonnet-5-5', stopReason: null, refusalCategory: null,
      attempts: [{ model: 'claude-sonnet-5-5', estimated: true, usage: { input: 500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 50 } }], exact: false };
  } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.equal(h.calls.filter(c => c.name === 'worker_settle_operation').length, 1);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'error']);
  assert.deepEqual(h.events[1].data, { code: 'provider_unavailable' });
});

test('a thrown provider failure is settled as uncertain input, never left reserved', async () => {
  const h = harness({ generate: async () => { throw new Error('boom'); } });
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  const settles = h.calls.filter(c => c.name === 'worker_settle_operation');
  assert.equal(settles.length, 1); assert.ok(Number(settles[0].params.p_actual_microusd) > 0);
  assert.deepEqual(h.events, [{ event: 'error', data: { code: 'provider_unavailable' } }]);
});

test('a replayed operation never calls the provider or settles again', async () => {
  for (const state of ['reserved', 'settled']) {
    const h = harness({ script: { worker_reserve_operation: () => ({ id: operation, state, replayed: true }) } });
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.equal(h.generations(), 0);
    assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_chat_context', 'worker_reserve_operation']);
    assert.deepEqual(h.events, [{ event: 'error', data: { code: 'operation_replayed' } }]);
  }
});

test('reservation failures map to stable codes without provider calls or settlement', async () => {
  const cases: [string, string][] = [['insufficient_credits', 'insufficient_credits'], ['platform_budget_exhausted', 'platform_budget_exhausted'],
    ['too_many_active_operations', 'rate_limited'], ['operation_id_conflict', 'invalid_request'], ['query returned no rows', 'service_unavailable']];
  for (const [raised, code] of cases) {
    const h = harness({ script: { worker_reserve_operation: () => { throw new RpcFailure(raised); } } });
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.equal(h.generations(), 0);
    assert.ok(!names(h.calls).includes('worker_settle_operation'));
    assert.deepEqual(h.events, [{ event: 'error', data: { code } }]);
  }
  const ambiguous = harness({ script: { worker_reserve_operation: () => { throw new Error('transport'); } } });
  await runChat(ambiguous.deps, paperBody(), ambiguous.emit, new AbortController().signal);
  assert.deepEqual(ambiguous.events, [{ event: 'error', data: { code: 'service_unavailable' } }]);
  assert.deepEqual(ambiguous.logs, [{ event: 'chat_reserve_uncertain', operation_id: operation }]);
});

test('rate limits, missing papers and invalid bodies stop before any hold', async () => {
  const limited = harness({ script: { worker_consume_request: () => { throw new RpcFailure('request_rate_limit'); } } });
  await runChat(limited.deps, paperBody(), limited.emit, new AbortController().signal);
  assert.deepEqual(limited.events, [{ event: 'error', data: { code: 'rate_limited' } }]);
  const unavailable = harness({ script: { worker_chat_context: () => { throw new RpcFailure('document_unavailable'); } } });
  await runChat(unavailable.deps, paperBody(), unavailable.emit, new AbortController().signal);
  assert.deepEqual(unavailable.events, [{ event: 'error', data: { code: 'document_unavailable' } }]);
  for (const paper of [null, new Uint8Array([0xff, 0xfe]), new Uint8Array(2 * 1024 * 1024 + 1)]) {
    const h = harness({ paper });
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.deepEqual(h.events, [{ event: 'error', data: { code: 'document_unavailable' } }]);
    assert.ok(!names(h.calls).includes('worker_reserve_operation'));
  }
  const invalid = harness();
  await runChat(invalid.deps, null, invalid.emit, new AbortController().signal);
  assert.deepEqual(invalid.events, [{ event: 'error', data: { code: 'invalid_request' } }]);
  assert.deepEqual(names(invalid.calls), ['worker_consume_request']);
  const unconfigured = harness({ generate: null });
  await runChat(unconfigured.deps, generalBody(), unconfigured.emit, new AbortController().signal);
  assert.deepEqual(unconfigured.events, [{ event: 'error', data: { code: 'provider_unavailable' } }]);
  assert.ok(!names(unconfigured.calls).includes('worker_reserve_operation'));
});

test('a refusal is settled and reported as refused', async () => {
  const h = harness({ generate: async (_params, stream) => { stream.onText('Partial'); return completeOutcome({ stopReason: 'refusal', refusalCategory: 'bio' }); } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.equal(h.calls.filter(c => c.name === 'worker_settle_operation').length, 1);
  assert.deepEqual(h.events.at(-1), { event: 'error', data: { code: 'refused' } });
  const units = h.calls.find(c => c.name === 'worker_record_provider_usage')!.params.p_units as Record<string, unknown>;
  assert.equal(units.refusal_category, 'bio');
});

test('usage above the hold charges at most the hold but records the true cost', async () => {
  const h = harness({ generate: async () => completeOutcome({ attempts: [{ model: 'claude-sonnet-5-5', estimated: false,
    usage: { input: 5_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 8_000 } }] }) });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  const reserve = h.calls.find(c => c.name === 'worker_reserve_operation')!.params;
  const settle = h.calls.find(c => c.name === 'worker_settle_operation')!.params;
  assert.ok((settle.p_actual_microusd as number) > (reserve.p_microusd as number), 'true provider cost reaches the budget (freezes work)');
  assert.equal(settle.p_actual_credits, reserve.p_credits);
  assert.equal(h.logs[0].event, 'chat_usage_exceeded_hold'); noPlaintext(h.logs);
  assert.equal((h.events.at(-1)!.data as { credits: number }).credits, reserve.p_credits);
});

test('settlement retries only ambiguous transport failures with identical amounts', async () => {
  let attempts = 0;
  const h = harness({ script: { worker_settle_operation: () => { attempts++; if (attempts < 3) throw new Error('transport'); return null; } } });
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  const settles = h.calls.filter(c => c.name === 'worker_settle_operation');
  assert.equal(settles.length, 3); assert.ok(settles.every(s => JSON.stringify(s.params) === JSON.stringify(settles[0].params)));
  const rejected = harness({ script: { worker_settle_operation: () => { throw new RpcFailure('invalid_settlement'); } } });
  await runChat(rejected.deps, generalBody(), rejected.emit, new AbortController().signal);
  assert.equal(rejected.calls.filter(c => c.name === 'worker_settle_operation').length, 1);
  assert.deepEqual(rejected.logs, [{ event: 'chat_settle_failed', operation_id: operation, reason: 'rejected' }]);
});

test('the server deadline aborts generation and reports provider_unavailable', async () => {
  const h = harness({ generate: (_params, stream) => new Promise(resolve => stream.signal.addEventListener('abort', () => resolve({
    status: 'failed', failure: 'aborted', messageID: null, model: null, stopReason: null, refusalCategory: null, attempts: [], exact: true,
  }))) });
  h.deps.deadlineMs = 5;
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events, [{ event: 'error', data: { code: 'provider_unavailable' } }]);
  assert.deepEqual(h.calls.find(c => c.name === 'worker_settle_operation')!.params, { p_account_id: account, p_id: operation, p_actual_credits: 0, p_actual_microusd: 0 });
});

// Real SDK, fake transport: verifies the request on the wire and event handling.
function sseResponse(events: Record<string, unknown>[], hang = false) {
  return (signal?: AbortSignal | null) => new Response(new ReadableStream<Uint8Array>({
    async start(controller) {
      for (const event of events) controller.enqueue(new TextEncoder().encode(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`));
      if (!hang) { controller.close(); return; }
      await new Promise<void>(resolve => signal?.addEventListener('abort', () => resolve(), { once: true }));
      controller.error(new DOMException('aborted', 'AbortError'));
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream', 'request-id': 'req_test' } });
}
function fakeClient(respond: (signal?: AbortSignal | null) => Response, seen: { url?: string; headers?: Headers; body?: Record<string, unknown> } = {}) {
  return createAnthropicClient({ apiKey: 'test-key', maxRetries: 0, fetch: (async (url: string, init: RequestInit) => {
    seen.url = String(url); seen.headers = new Headers(init.headers); seen.body = JSON.parse(String(init.body));
    return respond(init.signal);
  }) as typeof fetch });
}
const usage0 = { input_tokens: 1200, output_tokens: 1, cache_creation_input_tokens: 800, cache_read_input_tokens: 0 };
const start = { type: 'message_start', message: { id: 'msg_live', type: 'message', role: 'assistant', model: 'claude-sonnet-5-5', content: [],
  stop_reason: null, stop_sequence: null, usage: usage0 } };
const text = (index: number, value: string) => [
  { type: 'content_block_start', index, content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index, delta: { type: 'text_delta', text: value } },
  { type: 'content_block_stop', index },
];
const params = () => chatRequestParams({ instructions: chatInstructions('paper'), paper: { title: 'T', text: paperText },
  turns: [{ role: 'user', text: secretQuestion }], selection: null });

test('the SDK adapter streams text, sends the fallback beta and returns exact usage', async () => {
  const seen: { url?: string; headers?: Headers; body?: Record<string, unknown> } = {};
  const client = fakeClient(sseResponse([start, ...text(0, 'Hello '), ...text(1, 'world'),
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { ...usage0, output_tokens: 40 } },
    { type: 'message_stop' }]), seen);
  const received: string[] = [];
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: t => received.push(t), inputEstimateTokens: 2000 });
  assert.deepEqual(received, ['Hello ', 'world']);
  assert.equal(outcome.status, 'complete'); assert.equal(outcome.stopReason, 'end_turn'); assert.equal(outcome.exact, true);
  assert.deepEqual(outcome.attempts, [{ model: 'claude-sonnet-5-5', estimated: false, usage: { input: 1200, cacheWrite5m: 800, cacheWrite1h: 0, cacheRead: 0, output: 40 } }]);
  assert.match(seen.url!, /\/v1\/messages\?beta=true$/);
  assert.ok(seen.headers!.get('anthropic-beta')!.includes(FALLBACK_BETA));
  assert.equal(seen.body!.fallbacks, 'default'); assert.equal(seen.body!.stream, true); assert.equal(seen.body!.model, 'claude-sonnet-5-5');
  assert.deepEqual(seen.body!.thinking, { type: 'adaptive' }); assert.equal(seen.body!.betas, undefined);
});

test('the SDK adapter returns client tool calls from the final message', async () => {
  const client = fakeClient(sseResponse([start, ...text(0, 'That is DPO.'),
    { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'toolu_1', name: 'add_paper', input: {} } },
    { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"title":"Direct Preference Optimization","year":2023}' } },
    { type: 'content_block_stop', index: 1 },
    { type: 'message_delta', delta: { stop_reason: 'tool_use', stop_sequence: null }, usage: { ...usage0, output_tokens: 60 } },
    { type: 'message_stop' }]));
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 2000 });
  assert.equal(outcome.stopReason, 'tool_use');
  assert.deepEqual(outcome.toolCalls, [{ name: 'add_paper', input: { title: 'Direct Preference Optimization', year: 2023 } }]);
  assert.equal(JSON.stringify(ADD_PAPER_TOOL).includes('eager_input_streaming'), false);
});

test('the SDK adapter counts web searches and collects cited sources', async () => {
  const searching = { type: 'content_block_start', index: 1, content_block: { type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: {} } };
  const cited = [
    { type: 'content_block_start', index: 2, content_block: { type: 'text', text: '', citations: [] } },
    { type: 'content_block_delta', index: 2, delta: { type: 'citations_delta', citation: { type: 'web_search_result_location', url: 'https://arxiv.org/abs/2310.12036',
      title: 'IPO', cited_text: 'x', encrypted_index: 'e' } } },
    { type: 'content_block_delta', index: 2, delta: { type: 'text_delta', text: 'IPO generalizes DPO.' } },
    { type: 'content_block_stop', index: 2 },
  ];
  const client = fakeClient(sseResponse([start, ...text(0, 'Searching.'), searching, { type: 'content_block_stop', index: 1 }, ...cited,
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null },
      usage: { ...usage0, output_tokens: 70, server_tool_use: { web_search_requests: 1, web_fetch_requests: 0 } } },
    { type: 'message_stop' }]));
  const received: string[] = [];
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: t => received.push(t), inputEstimateTokens: 2000 });
  assert.deepEqual(received, ['Searching.', 'IPO generalizes DPO.']);
  assert.equal(outcome.webSearches, 1);
  assert.deepEqual(outcome.sources, [{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO' }]);
});

test('the SDK adapter reports refusals with their category', async () => {
  const client = fakeClient(sseResponse([start, ...text(0, 'I can'),
    { type: 'message_delta', delta: { stop_reason: 'refusal', stop_sequence: null, stop_details: { type: 'refusal', category: 'general_harms', explanation: null } },
      usage: { ...usage0, output_tokens: 5 } }, { type: 'message_stop' }]));
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 10 });
  assert.equal(outcome.status, 'complete'); assert.equal(outcome.stopReason, 'refusal'); assert.equal(outcome.refusalCategory, 'general_harms');
});

test('the SDK adapter treats a rejected HTTP request as unbilled', async () => {
  const client = fakeClient(() => Response.json({ type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } }, { status: 529 }));
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 10 });
  assert.equal(outcome.status, 'failed'); assert.equal(outcome.failure, 'provider_error'); assert.deepEqual(outcome.attempts, []);
});

test('the SDK adapter estimates usage after an abort mid-stream', async () => {
  const controller = new AbortController();
  let clock = 1_000;
  const client = fakeClient(sseResponse([start, ...text(0, 'x'.repeat(30))], true));
  const outcome = await streamChat(client, params(), { signal: controller.signal, inputEstimateTokens: 5_000, now: () => clock,
    onText: () => { clock += 2_000; queueMicrotask(() => controller.abort()); } });
  assert.equal(outcome.status, 'failed'); assert.equal(outcome.failure, 'aborted'); assert.equal(outcome.exact, false);
  assert.equal(outcome.messageID, 'msg_live');
  // Input comes from message_start; output is the larger of text/3 and 100 tokens per elapsed second.
  assert.deepEqual(outcome.attempts, [{ model: 'claude-sonnet-5-5', estimated: true, usage: { input: 1200, cacheWrite5m: 800, cacheWrite1h: 0, cacheRead: 0, output: 200 } }]);
});

test('the SDK adapter charges the input estimate when billing is uncertain before message_start', async () => {
  const client = createAnthropicClient({ apiKey: 'test-key', maxRetries: 0, fetch: (async () => { throw new TypeError('network down'); }) as typeof fetch });
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 777 });
  assert.equal(outcome.status, 'failed'); assert.equal(outcome.exact, false);
  assert.deepEqual(outcome.attempts, [{ model: 'claude-sonnet-5-5', estimated: true, usage: { input: 777, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }]);
  const already = new AbortController(); already.abort();
  const skipped = await streamChat(client, params(), { signal: already.signal, onText: () => {}, inputEstimateTokens: 777 });
  assert.deepEqual(skipped.attempts, []);
});

test('non-ASCII prompt text is weighted as one token per UTF-8 byte', async () => {
  const { promptCharacters } = await import('../../supabase/functions/_shared/anthropic.ts');
  const params = (text: string) => ({ model: 'x', max_tokens: 1, messages: [{ role: 'user' as const, content: text }] });
  assert.equal(promptCharacters(params('abc')), 3);
  assert.equal(promptCharacters(params('漢字')), 18);   // 2 chars × 3 bytes × 3
  assert.equal(promptCharacters(params('é')), 6);      // 2 bytes × 3
});

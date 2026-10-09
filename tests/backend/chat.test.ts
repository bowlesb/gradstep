import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import type Anthropic from '@anthropic-ai/sdk';
import {
  ADD_PAPER_TOOL, attemptsFromUsage, CHAT_MAX_TOKENS, chatRequestParams, CREATE_DIAGRAM_TOOL, promptCharacters, WEB_SEARCH_TOOL, webSearchHoldMicrousd, createAnthropicClient, creditsFor, FALLBACK_BETA, holdFor, priceAttempts, ratesFor,
  streamChat, UNKNOWN_MODEL_RATES, statusQuery, STATUS_QUERY_CHARS, type ChatStatus, type ProviderOutcome, type StreamOptions,
} from '../../supabase/functions/_shared/anthropic.ts';
import { publishedProfiles } from '../../supabase/functions/_shared/chat-profiles.ts';
import { cleanTitle, titleRequestParams } from '../../supabase/functions/_shared/chat-title.ts';
import { ACADEMIC_DOMAINS, parseResults, searchInput, tavilySearch, TAVILY_RESULT_CHARS, type SearchOutcome } from '../../supabase/functions/_shared/tavily.ts';
import {
  canonicalRequest, chatInstructionParts, chatInstructions, DIAGRAM_FIX_MAX_TOKENS, diagramRequest, ingestReport, paperRequest, sourcesText, readChatBody, RpcFailure, runChat, sseFrame, validateChatRequest,
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
  // 1M input at $2, 1M output at $10, 1M cache write at $2.50, 1M cache read at $0.10 (Sonnet 5.5: 0.05x input;
  // https://platform.claude.com/docs/en/about-claude/pricing, read 2026-10-08).
  const usage = { input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 0, cacheRead: 1_000_000, output: 1_000_000 };
  assert.equal(priceAttempts([{ model: 'claude-sonnet-5-5', usage, estimated: false }]), 14_600_000);
  // Sonnet 5 (Sonnet 5.5's fallback) reads the cache at $0.20.
  assert.equal(priceAttempts([{ model: 'claude-sonnet-5', usage, estimated: false }]), 14_700_000);
  // Unknown models price at the highest card this route can be served by: Opus 5 / 4.8 ($5 / $6.25 / $0.50 / $25).
  assert.equal(priceAttempts([{ model: 'unknown', usage, estimated: false }]), 36_750_000);
  assert.equal(priceAttempts([{ model: 'claude-opus-5-5', usage, estimated: false }]), 29_200_000);
  assert.equal(priceAttempts([{ model: 'claude-opus-4-8', usage, estimated: false }]), 36_750_000);
  assert.equal(priceAttempts([{ model: 'claude-haiku-4-5-20251001', usage, estimated: false }]), 7_350_000);
  // Haiku 5.5: a prompt over 100,000 tokens pays the long-prompt card for the whole request.
  assert.equal(priceAttempts([{ model: 'claude-haiku-5-5', usage: { input: 50_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 50_000, output: 1_000 }, estimated: false }]),
    50_000 * 0.1 + 50_000 * 0.01 + 1_000 * 0.5);
  assert.equal(priceAttempts([{ model: 'claude-haiku-5-5', usage: { input: 50_001, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 50_000, output: 1_000 }, estimated: false }]),
    50_001 * 0.5 + 50_000 * 0.05 + 1_000 * 2.5);
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
  assert.equal(priceAttempts(attempts), (1000 * 2 + 300 * 2.5 + 100 * 4 + 50 * 10) + (1000 * 5 + 200 * 25));
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
  // Owner feedback 2026-10-07: answers start with their content, not an "Answer:" label.
  for (const mode of ['paper', 'general'] as const) assert.match(chatInstructions(mode), /no label such as "Answer:"/);
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
  for (const bad of [null, [], 'title', {}, { title: 'ab' }, { title: 'x'.repeat(401) }, { title: 7 }]) {
    assert.equal(paperRequest(bad), null);
  }
  // Extra keys a model adds (venue, authors) are ignored, never fatal.
  assert.deepEqual(paperRequest({ title: 'Valid title', venue: 'EUSIPCO 2004', authors: ['S. Gepshtein'], year: 2004 }),
    { title: 'Valid title', year: 2004, firstAuthor: null, arxivID: null });
  const request = { title: 'A [link](https://evil.example) `x` <b>', year: null, firstAuthor: null, arxivID: null };
  const report = ingestReport(request, null, 'not_found');
  assert.ok(!/[[\]`<>]/.test(report)); assert.match(report, /couldn't find/);
  const dpo = { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 };
  assert.match(ingestReport(request, dpo, 'added'), /Queued “Direct Preference Optimization” \(arXiv:2305\.18290\) for your library/);
  assert.match(ingestReport(request, dpo, 'present'), /is already in your library/);
  assert.match(ingestReport(request, dpo, 'failed'), /couldn't add it right now/);
  assert.match(ingestReport(request, null, 'unavailable'), /couldn't search for .* right now/);
  const web = { source_id: 'openalex:W1000000001', title: 'Deep learning', year: 2015, kind: 'web' as const, host: 'repository.example.org' };
  assert.match(ingestReport(request, web, 'added'), /Queued “Deep learning” \(open-access PDF from repository\.example\.org\) for your library/);
  assert.match(ingestReport(request, web, 'failed'), /Try Ingest again later/);
  assert.match(ingestReport(request, web, 'needs_update'), /isn't on arXiv\. Adding open-access papers from other sites needs the latest/);
  const closed = { ...web, host: null, link: 'https://doi.org/10.1038/nature14539' };
  assert.match(ingestReport(request, closed, 'closed'), /“Deep learning” isn't openly available .* It's at https:\/\/doi\.org\/10\.1038\/nature14539$/);
  assert.ok(!ingestReport(request, { ...closed, link: 'https://evil.example/[x](javascript:alert(1))' }, 'closed').includes('evil'));
  assert.ok(!ingestReport(request, { ...closed, link: 'javascript:alert(1)' }, 'closed').includes('javascript'));
});

test('client capabilities: known ones kept, unknown ones ignored, malformed rejected', () => {
  const quoted = paperBody({ selection: { quote: '[3] LeCun et al.' }, action: 'ingest' });
  assert.deepEqual(validateChatRequest({ ...quoted, capabilities: ['web_import', 'future_feature', 'web_import'] }).capabilities, ['web_import']);
  assert.deepEqual(validateChatRequest(quoted).capabilities, []);
  assert.deepEqual(validateChatRequest({ ...quoted, capabilities: null }).capabilities, []);
  for (const capabilities of ['web_import', [1], ['x'.repeat(33)], Array(9).fill('web_import'), { web_import: true }]) {
    assert.throws(() => validateChatRequest({ ...quoted, capabilities }), { code: 'invalid_request' });
  }
  assert.notEqual(canonicalRequest(validateChatRequest(quoted)), canonicalRequest(validateChatRequest({ ...quoted, capabilities: ['web_import'] })));
  assert.equal(canonicalRequest(validateChatRequest(quoted)), canonicalRequest(validateChatRequest({ ...quoted, capabilities: ['unknown'] })));
});

/** The `index`th text event (status events may come between them). */
const delta = (h: { events: ChatEvent[] }, index: number) => h.events.filter(e => e.event === 'delta')[index].data as { text: string };
const statuses = (h: { events: ChatEvent[] }) => h.events.filter(e => e.event === 'status').map(e => e.data);

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
  h.deps.importPaper = async paper => { imported.push(paper.source_id); assert.ok(names(h.calls).includes('worker_settle_operation')); return 'added'; };
  await runChat(h.deps, ingestBody(), h.emit, new AbortController().signal);
  assert.deepEqual(tools, [ADD_PAPER_TOOL]);
  assert.deepEqual(found, [{ title: 'Direct Preference Optimization', year: 2023, firstAuthor: null, arxivID: null }]);
  assert.deepEqual(imported, ['2305.18290']);
  // Progress while the server finds and adds the paper, then its report.
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'status', 'status', 'delta', 'done']);
  assert.deepEqual(h.events.filter(e => e.event === 'status').map(e => e.data), [{ kind: 'finding_paper' }, { kind: 'adding_paper' }]);
  assert.match(delta(h, 1).text, /^\n\nQueued “Direct Preference Optimization: Your Language Model is Secretly a Reward Model” \(arXiv:2305\.18290\)/);
  assert.equal((h.events.at(-1)!.data as { stop_reason: string }).stop_reason, 'end_turn');
  assert.deepEqual(h.logs, [{ event: 'chat_ingest', operation_id: operation, result: 'added' }]);
});

test('ingest reports a missing paper, ignores invalid tool input and never adds for non-ingest requests', async () => {
  const missing = harness({ generate: toolGenerate({ title: 'A Paper Not On arXiv' }) });
  let imports = 0;
  missing.deps.findPaper = async () => ({ status: 'not_found' }); missing.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(missing.deps, ingestBody(), missing.emit, new AbortController().signal);
  assert.match(delta(missing, 1).text, /couldn't find “A Paper Not On arXiv” on arXiv or as an open-access paper/);
  assert.equal(imports, 0);

  const invalid = harness({ generate: toolGenerate({ title: 'ab' }) });
  invalid.deps.findPaper = async () => { throw new Error('must not search'); }; invalid.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(invalid.deps, ingestBody(), invalid.emit, new AbortController().signal);
  // Never silent: the reader is told nothing was added, and the outcome is recorded.
  assert.deepEqual(invalid.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.match(delta(invalid, 1).text, /couldn’t read the paper’s details/);
  assert.deepEqual(invalid.logs, [{ event: 'chat_ingest', operation_id: operation, result: 'invalid_input' }]);
  const recorded = invalid.calls.find(c => c.name === 'worker_record_provider_usage' && c.params.p_provider === 'ingest')!;
  assert.equal((recorded.params.p_units as { result: string }).result, 'invalid_input');

  // A tool call on an ordinary question (no tools were offered) is ignored.
  const ordinary = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  ordinary.deps.findPaper = async () => { throw new Error('must not search'); }; ordinary.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(ordinary.deps, paperBody({ selection: { quote: 'x' } }), ordinary.emit, new AbortController().signal);
  assert.equal(imports, 0); assert.equal(ordinary.events.at(-1)?.event, 'done');

  const failing = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  failing.deps.findPaper = async () => ({ status: 'found', paper: { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 } });
  failing.deps.importPaper = async () => { throw new Error('library_active_import_limit'); };
  await runChat(failing.deps, ingestBody(), failing.emit, new AbortController().signal);
  assert.match(delta(failing, 1).text, /couldn't add it right now/);

  const busy = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  busy.deps.findPaper = async () => { throw new Error('search_busy'); }; busy.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(busy.deps, ingestBody(), busy.emit, new AbortController().signal);
  assert.match(delta(busy, 1).text, /couldn't search for “Direct Preference Optimization” right now/);

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
  assert.match(delta(h, 1).text, /couldn't search for .* right now/);
  assert.equal(h.events.at(-1)?.event, 'done');
});

test('ingest adds an open-access web paper only for builds that show web papers', async () => {
  const deepLearning = { source_id: 'openalex:W1000000001', title: 'Deep learning', year: 2015, kind: 'web' as const, host: 'repository.example.org' };
  const capable = harness({ generate: toolGenerate({ title: 'Deep learning', year: 2015 }) });
  const options: unknown[] = [], imported: unknown[] = [];
  capable.deps.findPaper = async (_wanted, _signal, option) => { options.push(option); return { status: 'found', paper: deepLearning }; };
  capable.deps.importPaper = async paper => { imported.push(paper); return 'added'; };
  await runChat(capable.deps, { ...ingestBody(), capabilities: ['web_import'] }, capable.emit, new AbortController().signal);
  assert.deepEqual(options, [{ web: true, tavily: false }]);
  assert.deepEqual(imported, [deepLearning]);
  assert.match(delta(capable, 1).text, /Queued “Deep learning” \(open-access PDF from repository\.example\.org\)/);

  // An older build: never imported, even if a search returned a web paper.
  const older = harness({ generate: toolGenerate({ title: 'Deep learning', year: 2015 }) });
  let imports = 0;
  older.deps.findPaper = async (_wanted, _signal, option) => { options.push(option); return { status: 'found', paper: deepLearning }; };
  older.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(older.deps, ingestBody(), older.emit, new AbortController().signal);
  assert.deepEqual(options.at(-1), { web: false, tavily: false });
  assert.equal(imports, 0);
  assert.deepEqual(older.logs, [{ event: 'chat_ingest', operation_id: operation, result: 'needs_update' }]);

  const update = harness({ generate: toolGenerate({ title: 'Deep learning', year: 2015 }) });
  update.deps.findPaper = async () => ({ status: 'needs_update', paper: deepLearning });
  update.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(update.deps, ingestBody(), update.emit, new AbortController().signal);
  assert.match(delta(update, 1).text, /needs the latest Gradstep version/);
  const closed = harness({ generate: toolGenerate({ title: 'Deep learning', year: 2015 }) });
  closed.deps.findPaper = async () => ({ status: 'closed', paper: { ...deepLearning, host: null, link: 'https://doi.org/10.1038/nature14539' } });
  closed.deps.importPaper = async () => { imports++; return 'added'; };
  await runChat(closed.deps, { ...ingestBody(), capabilities: ['web_import'] }, closed.emit, new AbortController().signal);
  assert.match(delta(closed, 1).text, /isn't openly available/);
  assert.equal(imports, 0);
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
  // Every request completed (a fractional bigint amount once failed the reservation).
  for (const run of [off, on, ingest]) assert.equal(run.events.at(-1)?.event, 'done', JSON.stringify(run.events.at(-1)));
  assert.ok(Number.isSafeInteger(webSearchHoldMicrousd(39_657)));
  assert.deepEqual(WEB_SEARCH_TOOL, { type: 'web_search_20250305', name: 'web_search', max_uses: 3 });
  assert.match(chatInstructions('paper', null, true), /You can search the web/);
  assert.doesNotMatch(chatInstructions('paper', null, false), /search the web/);
  // The hold grows by the search allowance.
  const holdOff = Number(off.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_microusd);
  const holdOn = Number(on.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_microusd);
  const inputTokens = Math.ceil(promptCharacters(chatRequestParams({ instructions: chatInstructions('paper', null, true),
    paper: { title: 'Attention', text: paperText }, turns: [{ role: 'user', text: secretQuestion }], selection: null,
    tools: [CREATE_DIAGRAM_TOOL, WEB_SEARCH_TOOL] })) / 3);
  assert.ok(holdOn >= holdOff + webSearchHoldMicrousd(inputTokens) - 1);
  assert.ok(webSearchHoldMicrousd(50_000) > 3 * (10_000 + 50_000 * 2.5));
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

test('an answer that lists its own sources gets no second list', async () => {
  const h = harness({ generate: async (_p, stream) => {
    stream.onText('IPO generalizes DPO.\n\nSources:\n1. IPO — https://arxiv.org/abs/2310.12036');
    return completeOutcome({ webSearches: 1, sources: [{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO' }] });
  } });
  h.deps.webSearch = true;
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'done']);
  assert.match(chatInstructions('paper', null, true), /end your answer with a line "Sources:"/);
});

test('a balance between 50 credits and the full hold caps the credit hold, never the budget hold', async () => {
  const run = async (available: number | null, generate?: ChatDependencies['generate']) => {
    const paper = new TextEncoder().encode(paperText.repeat(20));
    const h = harness(generate ? { generate, paper } : { paper });
    if (available !== null) h.deps.availableCredits = async () => available;
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    return { h, reserve: h.calls.find(c => c.name === 'worker_reserve_chat')?.params };
  };
  const full = (await run(null)).reserve!;
  assert.ok(Number(full.p_credits) > 60, `full hold ${full.p_credits}`);
  const capped = (await run(60)).reserve!;
  assert.equal(capped.p_credits, 60); assert.equal(capped.p_microusd, full.p_microusd);
  assert.equal((await run(40)).reserve, undefined, 'clearly insufficient credits are refused before fetching the paper');
  assert.equal((await run(100_000)).reserve!.p_credits, full.p_credits);
  // An answer costing more than the capped hold charges the balance and logs it.
  const costly = await run(60, async (_p, stream) => { stream.onText('x');
    return completeOutcome({ attempts: [{ model: 'claude-sonnet-5-5', estimated: false, usage: { input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 31_000 } }] }); });
  assert.equal(costly.h.calls.find(c => c.name === 'worker_settle_operation')!.params.p_actual_credits, 60);
  assert.ok(costly.h.logs.some(l => l.event === 'chat_credits_capped_at_balance'));
});

test('unavailable or clearly insufficient credits stop before paper context authorization and Storage GET', async () => {
  for (const available of [null, 0, 1, 40]) {
    const h = harness(); let downloads = 0;
    h.deps.availableCredits = async () => available;
    h.deps.loadPaper = async () => { downloads++; return new TextEncoder().encode(paperText); };
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.equal(downloads, 0);
    assert.ok(!h.calls.some(call => ['worker_chat_context', 'worker_reserve_chat'].includes(call.name)));
    assert.deepEqual(h.events.at(-1), { event: 'error', data: { code: available === null ? 'service_unavailable' : 'insufficient_credits' } });
  }
});

test('paper context byte authorization is passed to the single Storage read', async () => {
  const bytes = new TextEncoder().encode(paperText);
  const h = harness({ script: { worker_chat_context: () => ({ bucket: 'paper-assets', path: 'raw/mmd', byte_count: bytes.length }) } });
  let downloads = 0;
  h.deps.loadPaper = async (_bucket, _path, expected) => { downloads++; assert.equal(expected, bytes.length); return bytes; };
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.equal(downloads, 1);
});

test('Ingest paid discovery requires consent v2 and the enabled server switch', async () => {
  for (const [consent, enabled, allowed] of [['cloud-ai-v1', true, false], ['cloud-ai-v2', false, false], ['cloud-ai-v2', true, true]] as const) {
    const h = harness({ generate: toolGenerate({ title: 'A sufficiently precise paper title' }) });
    h.deps.webSearch = enabled;
    h.deps.findPaper = async (_request, _signal, options) => { assert.equal(options.tavily, allowed); return { status: 'not_found' }; };
    h.deps.importPaper = async () => 'failed';
    await runChat(h.deps, { ...ingestBody(), consent_version: consent }, h.emit, new AbortController().signal);
    assert.equal(h.events.at(-1)?.event, 'done');
  }
});

test('native backup is absent when separately gated, even with general web search enabled', async () => {
  const h = harness({ generate: async (params) => {
    assert.ok(!params.tools?.some(tool => tool.name === 'web_search'));
    return completeOutcome();
  } });
  h.deps.webSearch = true; h.deps.nativeSearch = false;
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.equal(h.answers[0].web_search_offered, false);
});

test('pause_turn continuations share one search allowance and never report an unfinished answer as done', async () => {
  const offered: number[] = [];
  const h = harness({ generate: async params => {
    offered.push((params.tools?.find(tool => tool.name === 'web_search') as { max_uses: number }).max_uses);
    return completeOutcome({ stopReason: 'pause_turn', webSearches: 1, content: [] });
  } });
  h.deps.webSearch = true;
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(offered, [3, 2, 1]);
  assert.equal(h.events.at(-1)?.event, 'error');
  assert.equal(h.answers[0].web_searches, 3);
});

test('pause_turn without search progress still obeys the pre-continuation round bound', async () => {
  let requests = 0;
  const h = harness({ generate: async () => { requests++; return completeOutcome({ stopReason: 'pause_turn', content: [] }); } });
  h.deps.webSearch = true;
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.equal(requests, 4); assert.equal(h.events.at(-1)?.event, 'error');
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
  const calls: Call[] = [], events: ChatEvent[] = [], logs: LogEntry[] = [], answers: LogEntry[] = [];
  let generations = 0;
  const script: Script = {
    worker_consume_request: () => null,
    worker_chat_context: () => ({ bucket: 'paper-assets', path: 'artifacts/x/standalone.mmd', title: 'Attention' }),
    // The database columns are bigint: amounts must be whole numbers.
    worker_reserve_chat: params => {
      assert.ok(Number.isSafeInteger(params.p_credits) && Number.isSafeInteger(params.p_microusd), 'reservation amounts are integers');
      return { id: params.p_id, state: 'reserved', replayed: false };
    },
    worker_settle_operation: params => {
      assert.ok(Number.isSafeInteger(params.p_actual_credits) && Number.isSafeInteger(params.p_actual_microusd), 'settlement amounts are integers');
      return null;
    },
    worker_record_provider_usage: () => null,
    ...options.script,
  };
  const generate = options.generate === undefined
    ? async (_params: unknown, stream: StreamOptions) => { stream.onText('Scaling keeps '); stream.onText('logits bounded.'); return completeOutcome(); }
    : options.generate;
  const deps: ChatDependencies = {
    accountID: account,
    // Native-search continuation behavior remains tested explicitly while the
    // production admitted adapter gates native search pending a strict bound.
    nativeSearch: true,
    rpc: async (name, params) => {
      calls.push({ name, params });
      const handler = script[name]; assert.ok(handler, `unexpected rpc ${name}`);
      return handler(params);
    },
    loadPaper: async () => options.paper === undefined ? new TextEncoder().encode(paperText) : options.paper,
    generate: generate ? async (params, stream) => { generations++; return generate(params, stream); } : null,
    sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'),
    // Per-answer count lines go to `answers`; `logs` keeps the event-specific lines tests assert on.
    log: entry => { (entry.event === 'chat_answer' ? answers : logs).push(entry); },
    sleep: async () => {},
  };
  return { deps, calls, events, logs, answers, emit: (event: ChatEvent) => events.push(event), generations: () => generations };
}
const names = (calls: Call[]) => calls.map(call => call.name);
function noPlaintext(logs: LogEntry[]) {
  const serialized = JSON.stringify(logs);
  assert.ok(!serialized.includes('private-question-marker') && !serialized.includes('Attention\n'));
}

test('a paper answer holds, streams, settles once and records usage', async () => {
  const h = harness();
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_chat_context', 'worker_reserve_chat', 'worker_settle_operation', 'worker_record_provider_usage']);
  const reserve = h.calls[2].params, settle = h.calls[3].params, usage = h.calls[4].params;
  assert.equal(reserve.p_rate_version, 'beta-credits-v1'); assert.equal(reserve.p_id, operation);
  // The quote freezes the default profile: exactly the request the function made before profiles.
  assert.deepEqual(reserve.p_quote, { profile_version: 'chat-profiles-v1', profile: 'sonnet-low-standard', model: 'claude-sonnet-5-5',
    effort: 'low', length: 'standard', tariff: 'anthropic-list-prices-2026-10-08', max_output_tokens: 8_000,
    input_estimate_tokens: (reserve.p_quote as { input_estimate_tokens: number }).input_estimate_tokens, max_searches: 0,
    title_model: null, title_max_tokens: null, title_ceiling_microusd: null });
  assert.match(String(reserve.p_request_sha256), /^\\x[0-9a-f]{64}$/);
  const expected = createHash('sha256').update(canonicalRequest(validateChatRequest(paperBody()))).digest('hex');
  assert.equal(reserve.p_request_sha256, `\\x${expected}`);
  assert.ok(Number(reserve.p_credits) >= 16 && Number(reserve.p_microusd) >= 80_000);
  // 900 input at $2 + 300 output at $10 = 4,800 micro-USD -> 1 credit.
  assert.deepEqual(settle, { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 4_800 });
  assert.equal(usage.p_provider, 'anthropic'); assert.equal(usage.p_provider_event_id, 'msg_01'); assert.equal(usage.p_microusd, 4_800);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.deepEqual(h.events[2].data, { stop_reason: 'end_turn', credits: 1,
    usage: { input_tokens: 900, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 300 },
    model: 'claude-sonnet-5-5', profile: 'sonnet-low-standard' });
  noPlaintext(h.logs); assert.equal(h.logs.length, 0);
});

test('general chat skips paper context', async () => {
  const h = harness();
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_reserve_chat', 'worker_settle_operation', 'worker_record_provider_usage']);
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
    const h = harness({ script: { worker_reserve_chat: () => ({ id: operation, state, replayed: true }) } });
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.equal(h.generations(), 0);
    assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_chat_context', 'worker_reserve_chat']);
    assert.deepEqual(h.events, [{ event: 'error', data: { code: 'operation_replayed' } }]);
  }
});

test('reservation failures map to stable codes without provider calls or settlement', async () => {
  const cases: [string, string][] = [['insufficient_credits', 'insufficient_credits'], ['platform_budget_exhausted', 'platform_budget_exhausted'],
    ['too_many_active_operations', 'rate_limited'], ['operation_id_conflict', 'invalid_request'], ['query returned no rows', 'service_unavailable']];
  for (const [raised, code] of cases) {
    const h = harness({ script: { worker_reserve_chat: () => { throw new RpcFailure(raised); } } });
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.equal(h.generations(), 0);
    assert.ok(!names(h.calls).includes('worker_settle_operation'));
    assert.deepEqual(h.events, [{ event: 'error', data: { code } }]);
  }
  const ambiguous = harness({ script: { worker_reserve_chat: () => { throw new Error('transport'); } } });
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
    assert.ok(!names(h.calls).includes('worker_reserve_chat'));
  }
  const invalid = harness();
  await runChat(invalid.deps, null, invalid.emit, new AbortController().signal);
  assert.deepEqual(invalid.events, [{ event: 'error', data: { code: 'invalid_request' } }]);
  assert.deepEqual(names(invalid.calls), ['worker_consume_request']);
  const unconfigured = harness({ generate: null });
  await runChat(unconfigured.deps, generalBody(), unconfigured.emit, new AbortController().signal);
  assert.deepEqual(unconfigured.events, [{ event: 'error', data: { code: 'provider_unavailable' } }]);
  assert.ok(!names(unconfigured.calls).includes('worker_reserve_chat'));
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
  const reserve = h.calls.find(c => c.name === 'worker_reserve_chat')!.params;
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
  assert.deepEqual(outcome.toolCalls, [{ id: 'toolu_1', name: 'add_paper', input: { title: 'Direct Preference Optimization', year: 2023 } }]);
  assert.equal((outcome.content as { type: string }[]).map(block => block.type).join(), 'text,tool_use', 'content kept for a continuation');
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

test('the SDK adapter treats an explicit validation rejection as unbilled', async () => {
  const client = fakeClient(() => Response.json({ type: 'error', error: { type: 'invalid_request_error', message: 'Invalid' } }, { status: 400 }));
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 10 });
  assert.equal(outcome.status, 'failed'); assert.equal(outcome.failure, 'provider_rejected'); assert.deepEqual(outcome.attempts, []);
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

test('an abort after a web search estimates the extra pass and results', async () => {
  const controller = new AbortController();
  let clock = 1_000;
  const searching = { type: 'content_block_start', index: 1, content_block: { type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: {} } };
  const client = fakeClient(sseResponse([start, searching, { type: 'content_block_stop', index: 1 }, ...text(2, 'x'.repeat(30))], true));
  const outcome = await streamChat(client, params(), { signal: controller.signal, inputEstimateTokens: 5_000, now: () => clock,
    onText: () => { clock += 2_000; queueMicrotask(() => controller.abort()); } });
  assert.equal(outcome.webSearches, 1);
  // message_start input (1,200) plus one pass over the prompt estimate and 30k tokens of results.
  assert.equal(outcome.attempts[0].usage.input, 1_200 + 5_000 + 30_000);
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

test('all prompt text and nested tool results use a conservative UTF-8 byte bound', async () => {
  const { promptCharacters } = await import('../../supabase/functions/_shared/anthropic.ts');
  const params = (text: string) => ({ model: 'x', max_tokens: 1, messages: [{ role: 'user' as const, content: text }] });
  const base = promptCharacters(params(''));
  assert.equal(promptCharacters(params('abc')) - base, 9);
  assert.equal(promptCharacters(params('漢字')) - base, 18);
  assert.equal(promptCharacters(params('é')) - base, 6);
  const nested = { ...params(''), messages: [{ role: 'user' as const,
    content: [{ type: 'tool_result' as const, tool_use_id: 's1', content: 'private-result'.repeat(50) }] }] };
  assert.ok(promptCharacters(nested) >= 3 * new TextEncoder().encode('private-result'.repeat(50)).length);
});

test('Related searches the web by instruction; every answer logs counts only', async () => {
  const quoted = paperBody({ selection: { quote: 'multi-head attention' }, action: 'related' });
  assert.equal(validateChatRequest(quoted).action, 'related');
  assert.throws(() => validateChatRequest(paperBody({ action: 'related' })), { code: 'invalid_request' }, 'Related needs a selection');
  assert.throws(() => validateChatRequest({ ...quoted, action: 'similar' }), { code: 'invalid_request' });
  assert.match(chatInstructions('paper', 'related', true), /You must search the web before answering/);
  assert.match(chatInstructions('paper', 'related', false), /could not search the web/);
  assert.doesNotMatch(chatInstructions('paper', null, true), /"Related"/);
  let tools: unknown;
  const h = harness({ generate: async (params, stream) => {
    tools = (params as { tools?: { name?: string }[] }).tools?.map(t => t.name);
    stream.onText('1. **A paper**'); return completeOutcome({ webSearches: 3 });
  } });
  h.deps.webSearch = true;
  await runChat(h.deps, quoted, h.emit, new AbortController().signal);
  assert.ok((tools as string[]).includes('web_search'));
  assert.deepEqual(h.answers, [{ event: 'chat_answer', operation_id: operation, action: 'related', mode: 'paper', web_search_offered: true,
    search_provider: 'anthropic', web_searches: 3, tavily_searches: 0, search_failures: 0, failover: false, sources: 0,
    profile: 'sonnet-low-standard', title: 'not_requested' }]);
  const usage = h.calls.find(c => c.name === 'worker_record_provider_usage')!;
  assert.equal((usage.params.p_units as { web_searches: number }).web_searches, 3);
});

// ---- Web search with Tavily (primary) and Anthropic (backup) ----

const v2 = (body: Record<string, unknown>) => ({ ...body, consent_version: 'cloud-ai-v2' });
type Sent = { messages: { role: string; content: unknown }[]; tools?: { name?: string; type?: string; max_uses?: number }[]; max_tokens: number };
function searchRound(calls: { id: string; input: unknown; name?: string }[], output = 120): ProviderOutcome {
  const toolCalls = calls.map(call => ({ id: call.id, name: call.name ?? 'search_web', input: call.input }));
  return completeOutcome({ messageID: 'msg_round', stopReason: 'tool_use', toolCalls,
    attempts: [{ model: 'claude-sonnet-5-5', estimated: false, usage: { input: 900, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output } }],
    content: [{ type: 'text', text: 'Let me look.' }, ...toolCalls.map(call => ({ type: 'tool_use', ...call }))] });
}
const found: SearchOutcome = { status: 'ok', credits: 1, results: [{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO', text: 'A general paradigm.', published: '2023-10-18' }] };
function searching(h: ReturnType<typeof harness>, outcomes: SearchOutcome[], ready = true) {
  const runs: unknown[] = [];
  h.deps.webSearch = true;
  h.deps.search = { ready: async () => ready, run: async input => { runs.push(input); return outcomes.shift() ?? found; } };
  return runs;
}

test('consent v2 is accepted alongside v1 and keeps its own request digest', () => {
  assert.equal(validateChatRequest(v2(paperBody())).consentVersion, 'cloud-ai-v2');
  assert.equal(validateChatRequest(paperBody()).consentVersion, 'cloud-ai-v1');
  assert.notEqual(canonicalRequest(validateChatRequest(paperBody())), canonicalRequest(validateChatRequest(v2(paperBody()))));
  assert.throws(() => validateChatRequest(paperBody({ consent_version: 'cloud-ai-v3' })), { code: 'invalid_request' });
});

test('Tavily searches run between rounds as search results (not citable: no cache-breaking switch) and are priced for the reader but not as provider spend', async () => {
  const sent: Sent[] = [];
  const h = harness({ generate: async (params, stream) => {
    sent.push(structuredClone(params) as unknown as Sent);
    if (sent.length === 1) { stream.onText('Let me look.'); return searchRound([{ id: 'toolu_s1', input: { query: 'IPO preference optimization', academic: true } }]); }
    stream.onText('IPO generalizes DPO.');
    return completeOutcome({ messageID: 'msg_final', sources: [{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO' }] });
  } });
  const runs = searching(h, [found]);
  await runChat(h.deps, v2(paperBody({ selection: { quote: 'DPO' }, action: 'related' })), h.emit, new AbortController().signal);
  assert.deepEqual(runs, [{ query: 'IPO preference optimization', academic: true }]);
  assert.deepEqual(sent[0].tools?.map(t => t.name), ['create_diagram', 'search_web'], 'Tavily, not Anthropic search');
  // Round two: the first round's content, then the results as search results (citations off) with a cache breakpoint.
  const [assistant, results] = sent[1].messages.slice(-2) as { role: string; content: Record<string, unknown>[] }[];
  assert.equal(assistant.role, 'assistant'); assert.equal(assistant.content[1].id, 'toolu_s1');
  assert.equal(results.role, 'user');
  const result = results.content[0] as { type: string; tool_use_id: string; content: { type: string; source: string; citations: unknown; content: { text: string }[] }[]; cache_control?: unknown };
  assert.equal(result.type, 'tool_result'); assert.equal(result.tool_use_id, 'toolu_s1');
  assert.deepEqual(result.cache_control, { type: 'ephemeral' });
  assert.equal(result.content[0].type, 'search_result'); assert.equal(result.content[0].source, 'https://arxiv.org/abs/2310.12036');
  assert.deepEqual(result.content[0].citations, { enabled: false });
  assert.match(result.content[0].content[0].text, /^Published 2023-10-18\. A general paradigm\./);
  assert.equal(sent[1].max_tokens, CHAT_MAX_TOKENS - 120, 'one output allowance across rounds');
  // The continuation starts a new paragraph.
  const text = h.events.filter(e => e.event === 'delta').map(e => (e.data as { text: string }).text).join('');
  assert.match(text, /^Let me look\.\n\nIPO generalizes DPO\./);
  // Tokens: 2 × (900 × 2 + …) — reader pays tokens + one Tavily credit; provider spend is tokens only.
  const tokens = 900 * 2 + 120 * 10 + 900 * 2 + 300 * 10;
  const settle = h.calls.find(c => c.name === 'worker_settle_operation')!.params;
  assert.equal(settle.p_actual_microusd, tokens);
  assert.equal(settle.p_actual_credits, creditsFor(tokens + 8_000));
  const usage = h.calls.filter(c => c.name === 'worker_record_provider_usage').map(c => c.params);
  assert.deepEqual(usage.map(u => u.p_provider), ['anthropic', 'tavily']);
  assert.equal(usage[0].p_provider_event_id, 'msg_round'); assert.equal(usage[0].p_microusd, tokens);
  assert.deepEqual(usage[1], { p_account_id: account, p_operation_id: operation, p_provider: 'tavily', p_provider_event_id: `operation:${operation}`,
    p_model: 'search-basic', p_microusd: 0, p_units: { searches: 1, credits: 1, failed: 0, list_microusd: 8_000 } });
  assert.deepEqual(h.answers, [{ event: 'chat_answer', operation_id: operation, action: 'related', mode: 'paper', web_search_offered: true,
    search_provider: 'tavily', web_searches: 1, tavily_searches: 1, search_failures: 0, failover: false, sources: 1,
    profile: 'sonnet-low-standard', title: 'not_requested' }]);
  assert.match(text, /Sources:\n1\. IPO — https:\/\/arxiv\.org\/abs\/2310\.12036/);
  noPlaintext(h.logs);
});

test('readers who consented to v1 (Anthropic only), and a paused or exhausted Tavily, use Anthropic search', async () => {
  for (const [body, ready] of [[paperBody(), true], [v2(paperBody()), false]] as const) {
    let tools: string[] = [];
    const h = harness({ generate: async (params, stream) => { tools = ((params as unknown as Sent).tools ?? []).map(t => t.name!); stream.onText('a'); return completeOutcome(); } });
    const runs = searching(h, [], ready);
    await runChat(h.deps, body, h.emit, new AbortController().signal);
    assert.deepEqual(tools, ['create_diagram', 'web_search']); assert.equal(runs.length, 0);
    assert.equal(h.answers[0].search_provider, 'anthropic');
  }
  // Ingest never searches.
  let tools: string[] = [];
  const h = harness({ generate: async (params, stream) => { tools = ((params as unknown as Sent).tools ?? []).map(t => t.name!); stream.onText('a'); return completeOutcome(); } });
  searching(h, []);
  await runChat(h.deps, v2(paperBody({ selection: { quote: 'Rafailov et al. 2023' }, action: 'ingest' })), h.emit, new AbortController().signal);
  assert.deepEqual(tools, ['add_paper']);
});

test('a Tavily failure switches the rest of the answer to Anthropic search; failed searches cost nothing', async () => {
  const sent: Sent[] = [];
  const h = harness({ generate: async (params, stream) => {
    sent.push(structuredClone(params) as unknown as Sent);
    if (sent.length === 1) return searchRound([{ id: 'toolu_s1', input: { query: 'follow-up work' } }]);
    stream.onText('Found via the backup.'); return completeOutcome({ webSearches: 1 });
  } });
  searching(h, [{ status: 'failed', failure: 'limit', retryAfterMs: null }]);
  await runChat(h.deps, v2(paperBody()), h.emit, new AbortController().signal);
  const result = (sent[1].messages.at(-1)!.content as { is_error?: boolean; content: string }[])[0];
  assert.equal(result.is_error, true); assert.match(result.content, /Use the web_search tool instead/);
  const backup = sent[1].tools!.find(t => t.name === 'web_search')!;
  assert.equal(backup.type, 'web_search_20250305'); assert.equal(backup.max_uses, 2, 'the search allowance is shared');
  assert.ok(sent[1].tools!.some(t => t.name === 'search_web'), 'search_web stays defined: the conversation uses it');
  const settle = h.calls.find(c => c.name === 'worker_settle_operation')!.params;
  const tokens = 900 * 2 + 120 * 10 + 900 * 2 + 300 * 10;
  assert.equal(settle.p_actual_microusd, tokens + 10_000, 'the backup search is provider spend');
  assert.equal(settle.p_actual_credits, creditsFor(tokens + 10_000));
  assert.deepEqual(h.logs.filter(l => l.event === 'chat_search_failed'), [{ event: 'chat_search_failed', operation_id: operation, provider: 'tavily', failure: 'limit' }]);
  assert.equal(h.answers[0].failover, true); assert.equal(h.answers[0].search_failures, 1); assert.equal(h.answers[0].web_searches, 1);
  const tavily = h.calls.filter(c => c.name === 'worker_record_provider_usage').find(c => c.params.p_provider === 'tavily')!;
  assert.deepEqual(tavily.params.p_units, { searches: 0, credits: 0, failed: 1, list_microusd: 0 });
});

test('searches beyond the allowance, invalid input and parallel calls are answered without running', async () => {
  const sent: Sent[] = [];
  const h = harness({ generate: async (params, stream) => {
    sent.push(structuredClone(params) as unknown as Sent);
    if (sent.length === 1) return searchRound([{ id: 'a', input: { query: 'one' } }, { id: 'b', input: { query: 'two' } },
      { id: 'c', input: { query: 'x', extra: 1 } }, { id: 'd', input: { query: 'four' } }, { id: 'e', name: 'create_diagram', input: { title: 'T', mermaid: 'flowchart TD\nA-->B' } }]);
    stream.onText('Done.'); return completeOutcome();
  } });
  const runs = searching(h, []);
  await runChat(h.deps, v2(paperBody()), h.emit, new AbortController().signal);
  assert.equal(runs.length, 2, 'two valid searches within three uses');
  const results = sent[1].messages.at(-1)!.content as { tool_use_id: string; is_error?: boolean; content: unknown }[];
  assert.deepEqual(results.map(r => [r.tool_use_id, r.is_error === true]), [['a', false], ['b', false], ['c', true], ['d', true], ['e', false]]);
  assert.match(String(results[3].content), /No searches are left/);
  // The diagram from the search round is still delivered.
  assert.equal(h.events.filter(e => e.event === 'diagram').length, 1);
  assert.equal(h.answers[0].tavily_searches, 2);
});

test('rounds stop at the search allowance; a failed round ends the answer and keeps earlier usage', async () => {
  let rounds = 0;
  const greedy = harness({ generate: async () => { rounds++; return searchRound([{ id: `s${rounds}`, input: { query: `q${rounds}` } }]); } });
  searching(greedy, []);
  await runChat(greedy.deps, v2(paperBody()), greedy.emit, new AbortController().signal);
  assert.equal(rounds, 4, 'three searches and one answer round; an unfinished request is not completion');
  assert.equal(greedy.events.at(-1)!.event, 'error');
  let calls = 0;
  const failing = harness({ generate: async () => {
    if (++calls === 1) return searchRound([{ id: 's1', input: { query: 'q' } }]);
    throw new Error('lost');
  } });
  searching(failing, []);
  await runChat(failing.deps, v2(paperBody()), failing.emit, new AbortController().signal);
  const settle = failing.calls.find(c => c.name === 'worker_settle_operation')!.params;
  assert.ok(Number(settle.p_actual_microusd) > 900 * 2 + 120 * 10, 'the first round and an estimate for the lost one');
  assert.equal(failing.events.at(-1)!.event, 'error');
});

test('the SDK adapter collects search_result citations as sources', async () => {
  const cited = [
    { type: 'content_block_start', index: 1, content_block: { type: 'text', text: '', citations: [] } },
    { type: 'content_block_delta', index: 1, delta: { type: 'citations_delta', citation: { type: 'search_result_location', source: 'https://arxiv.org/abs/2310.12036',
      title: 'IPO', cited_text: 'x', search_result_index: 0, start_block_index: 0, end_block_index: 1 } } },
    { type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: 'IPO generalizes DPO.' } },
    { type: 'content_block_stop', index: 1 },
  ];
  const client = fakeClient(sseResponse([start, ...text(0, 'Answer: '), ...cited,
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { ...usage0, output_tokens: 20 } }, { type: 'message_stop' }]));
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, onText: () => {}, inputEstimateTokens: 2000 });
  assert.deepEqual(outcome.sources, [{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO' }]);
  assert.equal(outcome.webSearches, undefined, 'client searches are not Anthropic searches');
});

test('Tavily input, results and HTTP failures are bounded and typed', async () => {
  assert.deepEqual(searchInput({ query: '  sparse\nattention ' }), { query: 'sparse attention', academic: false });
  assert.deepEqual(searchInput({ query: 'x'.repeat(900), academic: true })?.query.length, 400);
  for (const bad of [null, 'q', {}, { query: 'a' }, { query: 'ok query', academic: 'yes' }, { query: 'ok query', url: 'https://evil' }]) assert.equal(searchInput(bad), null);
  const parsed = parseResults({ results: [
    { url: 'https://a.example/x', title: '', content: 'y'.repeat(5000) },
    { url: 'javascript:alert(1)', title: 'bad', content: 'z' },
    { url: 'https://b.example', title: 'No text', content: '' },
    ...Array.from({ length: 8 }, (_, i) => ({ url: `https://c.example/${i}`, title: `T${i}`, content: 'text', published_date: '2024-01-02' })),
  ], usage: { credits: 1 } })!;
  assert.equal(parsed.results.length, 5); assert.equal(parsed.results[0].title, 'a.example'); assert.equal(parsed.results[0].text.length, TAVILY_RESULT_CHARS);
  assert.equal(parsed.results[1].published, '2024-01-02'); assert.equal(parsed.credits, 1);
  assert.equal(parseResults({ results: [] })!.credits, 1, 'a search is one credit when usage is missing');
  assert.equal(parseResults({ nope: true }), null);

  const requests: { url: string; init: RequestInit }[] = [];
  const reply = (status: number, body: unknown, headers: Record<string, string> = {}) => async (url: string | URL | Request, init?: RequestInit) => {
    requests.push({ url: String(url), init: init! }); return new Response(JSON.stringify(body), { status, headers });
  };
  const ok = await tavilySearch(reply(200, { results: [{ url: 'https://arxiv.org/abs/1', title: 'A', content: 'B' }], usage: { credits: 1 } }) as typeof fetch,
    'tvly-test', { query: 'q', academic: true }, new AbortController().signal);
  assert.equal(ok.status, 'ok');
  const sentBody = JSON.parse(String(requests[0].init.body));
  assert.equal((requests[0].init.headers as Record<string, string>).authorization, 'Bearer tvly-test');
  assert.equal(sentBody.search_depth, 'basic'); assert.equal(sentBody.max_results, 5); assert.equal(sentBody.include_raw_content, false);
  assert.deepEqual(sentBody.include_domains, [...ACADEMIC_DOMAINS]);
  assert.equal(JSON.parse(String((await (async () => { requests.length = 0; await tavilySearch(reply(200, { results: [] }) as typeof fetch, 'k', { query: 'q', academic: false }, new AbortController().signal); return requests[0].init.body; })()))).include_domains, undefined);
  const statuses: [number, string][] = [[432, 'limit'], [433, 'limit'], [401, 'unauthorized'], [400, 'rejected']];
  for (const [status, failure] of statuses) {
    const outcome = await tavilySearch(reply(status, {}) as typeof fetch, 'k', { query: 'q', academic: false }, new AbortController().signal);
    assert.deepEqual(outcome, { status: 'failed', failure, retryAfterMs: null,
      billing: { state: 'rejected', requestID: null, credits: 0, failureCode: `http_${status}` } });
  }
  assert.deepEqual(await tavilySearch(reply(429, {}, { 'retry-after': '7' }) as typeof fetch, 'k', { query: 'q', academic: false }, new AbortController().signal),
    { status: 'failed', failure: 'rate_limited', retryAfterMs: 7_000,
      billing: { state: 'rejected', requestID: null, credits: 0, failureCode: 'http_429' } });
  let tries = 0;
  const flaky = (async () => { tries++; if (tries === 1) throw new TypeError('reset'); return new Response(JSON.stringify({ results: [] }), { status: 200 }); }) as typeof fetch;
  assert.equal((await tavilySearch(flaky, 'k', { query: 'q', academic: false }, new AbortController().signal)).status, 'failed');
  assert.equal(tries, 1, 'a lost response is never automatically resent');
  tries = 0;
  const down = (async () => { tries++; return new Response('{}', { status: 503 }); }) as typeof fetch;
  assert.deepEqual(await tavilySearch(down, 'k', { query: 'q', academic: false }, new AbortController().signal),
    { status: 'failed', failure: 'unavailable', retryAfterMs: null,
      billing: { state: 'unknown', requestID: null, credits: null, failureCode: 'http_503' } });
  assert.equal(tries, 1, 'server error does not create a hidden transport attempt');
});

// ---- Status events (progress while searching or adding a paper) ----

test('status events are SSE frames that older builds skip as an unknown event name', () => {
  assert.equal(sseFrame({ event: 'status', data: { kind: 'searching', query: 'DPO follow-ups' } }),
    'event: status\ndata: {"kind":"searching","query":"DPO follow-ups"}\n\n');
  assert.equal(sseFrame({ event: 'status', data: { kind: 'reading' } }), 'event: status\ndata: {"kind":"reading"}\n\n');
  // Status queries are bounded single lines.
  assert.equal(statusQuery('  DPO\n\u0000follow-ups\t2025 '), 'DPO follow-ups 2025');
  assert.equal(statusQuery('x'.repeat(500))!.length, STATUS_QUERY_CHARS);
  assert.equal(statusQuery('   '), undefined); assert.equal(statusQuery(7), undefined);
});

test('a Tavily round reports searching with its query, then reading; the query is never logged', async () => {
  const secretQuery = 'IPO preference optimization (private-question-marker)';
  let calls = 0;
  const h = harness({ generate: async (_params, stream) => {
    if (++calls === 1) { stream.onText('Let me look.'); return searchRound([{ id: 'toolu_s1', input: { query: secretQuery, academic: true } }]); }
    stream.onText('IPO generalizes DPO.');
    return completeOutcome({ messageID: 'msg_final', sources: [{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO' }] });
  } });
  searching(h, [found]);
  await runChat(h.deps, v2(paperBody({ selection: { quote: 'DPO' }, action: 'related' })), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['status', 'delta', 'status', 'status', 'delta', 'delta', 'done'],
    'Related says it is searching at once; searching and reading come between the rounds');
  assert.deepEqual(statuses(h), [{ kind: 'searching' }, { kind: 'searching', query: secretQuery }, { kind: 'reading' }]);
  noPlaintext([...h.logs, ...h.answers]);
  assert.ok(!JSON.stringify(h.calls).includes('private-question-marker'), 'no query reaches the database');
});

test('failed searches report searching but not reading; parallel searches each report', async () => {
  let calls = 0;
  const h = harness({ generate: async (_params, stream) => {
    if (++calls === 1) return searchRound([{ id: 'a', input: { query: 'one' } }, { id: 'b', input: { query: 'two' } }]);
    stream.onText('Done.'); return completeOutcome();
  } });
  searching(h, [{ status: 'failed', failure: 'unavailable', retryAfterMs: null }, { status: 'failed', failure: 'unavailable', retryAfterMs: null }]);
  h.deps.webSearch = true;
  await runChat(h.deps, v2(paperBody()), h.emit, new AbortController().signal);
  assert.deepEqual(statuses(h), [{ kind: 'searching', query: 'one' }, { kind: 'searching', query: 'two' }], 'no results, so no reading');
});

test('ingest reports finding the paper, and adding it only when it was found', async () => {
  const missing = harness({ generate: toolGenerate({ title: 'A Paper Not On arXiv' }) });
  missing.deps.findPaper = async () => ({ status: 'not_found' }); missing.deps.importPaper = async () => 'added';
  await runChat(missing.deps, ingestBody(), missing.emit, new AbortController().signal);
  assert.deepEqual(statuses(missing), [{ kind: 'finding_paper' }]);
  // Stopped during the search: nothing more is sent.
  const client = new AbortController();
  const stopped = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization', year: 2023 }) });
  stopped.deps.findPaper = async () => { client.abort(); return { status: 'found', paper: { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 } }; };
  stopped.deps.importPaper = async () => 'added';
  await runChat(stopped.deps, ingestBody(), stopped.emit, client.signal);
  assert.deepEqual(statuses(stopped), [{ kind: 'finding_paper' }]);
  assert.equal(stopped.events.some(e => e.event === 'done'), false);
});

test('the SDK adapter reports Anthropic search progress from the stream', async () => {
  const query = 'DPO follow-ups 2025';
  const client = fakeClient(sseResponse([start, ...text(0, 'Let me check. '),
    { type: 'content_block_start', index: 1, content_block: { type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: {} } },
    { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"query":"DPO follow' } },
    { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '-ups 2025"}' } },
    { type: 'content_block_stop', index: 1 },
    { type: 'content_block_start', index: 2, content_block: { type: 'web_search_tool_result', tool_use_id: 'srvtoolu_1', content: [] } },
    { type: 'content_block_stop', index: 2 },
    ...text(3, 'Found it.'),
    { type: 'content_block_start', index: 4, content_block: { type: 'server_tool_use', id: 'srvtoolu_2', name: 'web_search', input: {} } },
    { type: 'content_block_delta', index: 4, delta: { type: 'input_json_delta', partial_json: '{"qu' } },
    { type: 'content_block_stop', index: 4 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null },
      usage: { ...usage0, output_tokens: 70, server_tool_use: { web_search_requests: 2, web_fetch_requests: 0 } } },
    { type: 'message_stop' }]));
  const seen: (string | ChatStatus)[] = [];
  const outcome = await streamChat(client, params(), { signal: new AbortController().signal, inputEstimateTokens: 2000,
    onText: t => seen.push(t), onStatus: s => seen.push(s) });
  assert.deepEqual(seen, ['Let me check. ', { kind: 'searching', query }, { kind: 'reading' }, 'Found it.', { kind: 'searching' }],
    'an unreadable query still reports searching');
  assert.equal(outcome.webSearches, 2);
});

// ---- Chat quality (2026-10-07): Why it matters, Mermaid rules, diagram repairs ----

test('Why it matters uses only the paper: no search tool, even with Tavily ready', async () => {
  const quoted = v2(paperBody({ selection: { quote: 'We use label smoothing of 0.1.' }, action: 'relevance' }));
  assert.equal(validateChatRequest(quoted).action, 'relevance');
  assert.throws(() => validateChatRequest(paperBody({ action: 'relevance' })), { code: 'invalid_request' }, 'Why it matters needs a selection');
  const instructions = chatInstructions('paper', 'relevance', true);
  assert.match(instructions, /Use only the paper's own content: do not search the web/);
  assert.doesNotMatch(instructions, /You can search the web/);
  assert.match(instructions, /create_diagram/, 'A diagram can still be asked for');
  let sent: Sent | undefined;
  const h = harness({ generate: async (params, stream) => { sent = params as unknown as Sent; stream.onText('It regularizes.'); return completeOutcome(); } });
  const runs = searching(h, []);
  await runChat(h.deps, quoted, h.emit, new AbortController().signal);
  assert.deepEqual(sent!.tools?.map(t => t.name), ['create_diagram']);
  assert.equal(runs.length, 0);
  // No search allowance in the hold either.
  const held = Number(h.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_microusd);
  assert.equal(held, holdFor(promptCharacters(sent as unknown as Anthropic.Beta.Messages.MessageCreateParamsNonStreaming)).microusd);
  assert.equal(h.answers[0].web_search_offered, false); assert.equal(h.answers[0].action, 'relevance');
  // Ordinary questions on the same paper still search.
  const plain = harness(); plain.deps.webSearch = true;
  let plainTools: string[] = [];
  plain.deps.generate = async (params, stream) => { plainTools = ((params as unknown as Sent).tools ?? []).map(t => t.name ?? ''); stream.onText('x'); return completeOutcome(); };
  await runChat(plain.deps, paperBody(), plain.emit, new AbortController().signal);
  assert.ok(plainTools.includes('web_search'));
});

test('diagram instructions carry the Mermaid label rules', () => {
  for (const instructions of [chatInstructions('paper'), chatInstructions('general', null, true), chatInstructions('paper', 'related', true), chatInstructions('paper', 'diagram_fix')]) {
    assert.match(instructions, /Use only ASCII in labels/);
    assert.match(instructions, /Wrap any label that contains characters other than letters, digits and spaces in double quotes: A\["Linear \(d -> 4d\)"\]/);
    assert.match(instructions, /never use "end" as an ID/);
  }
  assert.doesNotMatch(chatInstructions('paper', 'ingest'), /Mermaid/);
  assert.match(JSON.stringify(CREATE_DIAGRAM_TOOL.input_schema.properties), /short ASCII labels/);
});

const repairText = 'Title: DPO pipeline\nMermaid error: Parse error on line 2\n\nflowchart TD\n A[Policy (π)] --> B[Loss]';
function repairBody(overrides: Record<string, unknown> = {}) {
  return v2(generalBody({ messages: [{ role: 'user', text: repairText }], action: 'diagram_fix', ...overrides }));
}

test('a diagram repair is a general, single-turn request without a selection', () => {
  assert.equal(validateChatRequest(repairBody()).action, 'diagram_fix');
  const bad = [
    repairBody({ mode: 'paper', document_id: documentID }), repairBody({ selection: { quote: 'x' } }),
    repairBody({ messages: [{ role: 'user', text: 'a' }, { role: 'assistant', text: 'b' }, { role: 'user', text: 'c' }] }),
    repairBody({ messages: [{ role: 'user', text: 'x'.repeat(24_001) }] }),
  ];
  for (const body of bad) assert.throws(() => validateChatRequest(body), { code: 'invalid_request' });
  assert.equal(validateChatRequest(repairBody({ messages: [{ role: 'user', text: 'x'.repeat(24_000) }] })).turns.length, 1);
});

test('a diagram repair is metered: a small hold, settled at its actual cost, one diagram and no caption', async () => {
  let sent: Sent | undefined, system = '';
  const h = harness({ generate: async params => {
    sent = params as unknown as Sent;
    system = ((params as unknown as { system: { text: string }[] }).system)[0].text;
    return completeOutcome({ stopReason: 'tool_use',
      attempts: [{ model: 'claude-sonnet-5-5', estimated: false, usage: { input: 1_400, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 600 } }],
      toolCalls: [{ name: 'create_diagram', input: { title: 'DPO pipeline', mermaid: 'flowchart TD\n A["Policy (pi)"] --> B[Loss]' } }] });
  } });
  searching(h, []);
  await runChat(h.deps, repairBody(), h.emit, new AbortController().signal);
  // No paper, no search, only create_diagram, and the repair's own output allowance.
  assert.ok(!names(h.calls).includes('worker_chat_context'));
  assert.deepEqual(sent!.tools?.map(t => t.name), ['create_diagram']);
  assert.equal(sent!.max_tokens, DIAGRAM_FIX_MAX_TOKENS);
  assert.match(system, /could not draw a Mermaid diagram/); assert.doesNotMatch(system, /Gradstep, an app people use/);
  assert.deepEqual(h.events.map(e => e.event), ['diagram', 'done'], 'no "Diagram:" caption for a repair');
  assert.deepEqual(h.events[0].data, { title: 'DPO pipeline', source: 'flowchart TD\n A["Policy (pi)"] --> B[Loss]' });
  // Held like any answer (input at the write rate plus its whole output allowance, times the fallback headroom)…
  const reserve = h.calls.find(c => c.name === 'worker_reserve_chat')!.params;
  const hold = holdFor(promptCharacters(sent as unknown as Anthropic.Beta.Messages.MessageCreateParamsNonStreaming), DIAGRAM_FIX_MAX_TOKENS);
  assert.equal(reserve.p_microusd, hold.microusd); assert.equal(reserve.p_credits, hold.credits);
  assert.ok(hold.credits <= 25, `a repair holds at most 25 credits (${hold.credits})`);
  assert.ok(hold.credits < holdFor(promptCharacters(chatRequestParams({ instructions: chatInstructions('general'), paper: null,
    turns: [{ role: 'user', text: repairText }], selection: null, tools: [CREATE_DIAGRAM_TOOL] }))).credits / 3, 'far below an answer’s hold');
  // …and settled at its actual cost: 1,400 input × $2 + 600 output × $10 per MTok = 8,800 µ$ → 2 credits.
  const settle = h.calls.find(c => c.name === 'worker_settle_operation')!.params;
  assert.equal(settle.p_actual_microusd, 8_800); assert.equal(settle.p_actual_credits, 2);
  assert.ok(names(h.calls).includes('worker_record_provider_usage'));
  assert.equal(h.answers[0].action, 'diagram_fix'); assert.equal(h.answers[0].web_search_offered, false);
  const logged = JSON.stringify([...h.logs, ...h.answers]);
  assert.ok(!logged.includes('Policy') && !logged.includes('Parse error'), 'neither the source nor the error is logged');
});

test('a repair round cannot exceed its output allowance', async () => {
  const rounds: number[] = [];
  const h = harness({ generate: async params => {
    rounds.push((params as unknown as Sent).max_tokens);
    return completeOutcome({ stopReason: 'max_tokens',
      attempts: [{ model: 'claude-sonnet-5-5', estimated: false, usage: { input: 1_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: DIAGRAM_FIX_MAX_TOKENS } }] });
  } });
  await runChat(h.deps, repairBody(), h.emit, new AbortController().signal);
  assert.deepEqual(rounds, [DIAGRAM_FIX_MAX_TOKENS], 'one round, no continuation');
  assert.ok(!h.events.some(e => e.event === 'diagram'));
  assert.equal(h.events.at(-1)?.event, 'done');
});

test('time to first feedback: Related says it is searching before the paper loads; reads start together', async () => {
  const timeline: string[] = [];
  const h = harness({ generate: async (_params, stream) => { timeline.push('generate'); stream.onText('a'); return completeOutcome(); } });
  const rpc = h.deps.rpc;
  h.deps.rpc = async (name, params) => { timeline.push(name); return rpc(name, params); };
  h.deps.availableCredits = async () => { timeline.push('balance'); return 500; };
  const emit = h.emit;
  searching(h, []);
  const ready = h.deps.search!.ready;
  h.deps.search!.ready = async () => { timeline.push('search_policy'); return ready(); };
  await runChat(h.deps, v2(paperBody({ selection: { quote: 'DPO' }, action: 'related' })), event => { if (event.event === 'status') timeline.push('status'); emit(event); },
    new AbortController().signal);
  // The rate limit, search policy and balance are requested together, before any of them answers.
  assert.deepEqual(timeline.slice(0, 3), ['worker_consume_request', 'search_policy', 'balance']);
  assert.ok(timeline.indexOf('status') < timeline.indexOf('worker_chat_context'), 'the reader sees "Searching the web…" before the paper is fetched');
  assert.ok(timeline.indexOf('worker_chat_context') < timeline.indexOf('worker_reserve_chat') && timeline.indexOf('worker_reserve_chat') < timeline.indexOf('generate'));
  // Other questions do not claim to search before the model decides to.
  const plain = harness(); searching(plain, []);
  await runChat(plain.deps, v2(paperBody()), plain.emit, new AbortController().signal);
  assert.equal(statuses(plain).length, 0);
  // A rate-limited request is still reported as such, whatever its body.
  const limited = harness({ script: { worker_consume_request: () => { throw new RpcFailure('request_rate_limit'); } } });
  await runChat(limited.deps, { not: 'a request' }, limited.emit, new AbortController().signal);
  assert.deepEqual(limited.events, [{ event: 'error', data: { code: 'rate_limited' } }]);
});

test('the paper is cached with the shared instructions; a selection action\'s own instructions follow it', () => {
  const turns = [{ role: 'user' as const, text: 'q' }];
  const paper = { title: 'T', text: paperText };
  const request = (action: 'related' | 'relevance' | null, search: boolean, tools = [CREATE_DIAGRAM_TOOL]) => {
    const parts = chatInstructionParts('paper', action, search);
    return chatRequestParams({ instructions: parts.shared, actionInstructions: parts.action, paper, turns, selection: 'DPO', tools });
  };
  const plain = request(null, true), related = request('related', true);
  const system = (params: ReturnType<typeof request>) => params.system as { text: string; cache_control?: unknown }[];
  assert.deepEqual(system(related).slice(0, 2), system(plain).slice(0, 2), 'a question and Related share the cached prefix');
  assert.deepEqual(system(related)[1].cache_control, { type: 'ephemeral' });
  assert.equal(system(related).length, 3); assert.match(system(related)[2].text, /The reader used "Related"/);
  assert.equal(system(plain).length, 2);
  assert.match(system(request('relevance', true))[2].text, /Why it matters/);
  // The combined text is unchanged (chatInstructions), and without a paper the action stays in the one block.
  assert.equal(`${chatInstructionParts('paper', 'related', true).shared}\n\n${chatInstructionParts('paper', 'related', true).action}`, chatInstructions('paper', 'related', true));
  const general = chatRequestParams({ instructions: chatInstructionParts('general', 'related', true).shared, actionInstructions: chatInstructionParts('general', 'related', true).action,
    paper: null, turns, selection: 'DPO' });
  assert.deepEqual((general.system as { text: string }[]).map(block => block.text), [chatInstructions('general', 'related', true)]);
});

test('without citations, an answer that names no sources gets the searched pages, each search\'s best first', async () => {
  let calls = 0;
  const h = harness({ generate: async (_params, stream) => {
    if (++calls === 1) return searchRound([{ id: 'a', input: { query: 'one' } }, { id: 'b', input: { query: 'two' } }]);
    stream.onText('IPO and KTO both relate.'); return completeOutcome({ messageID: 'msg_final' });
  } });
  const page = (url: string, title: string) => ({ url, title, text: 'x', published: null });
  searching(h, [{ status: 'ok', credits: 1, results: [page('https://arxiv.org/abs/2310.12036', 'IPO'), page('https://example.org/a', 'A')] },
    { status: 'ok', credits: 1, results: [page('https://arxiv.org/abs/2402.01306', 'KTO'), page('https://arxiv.org/abs/2310.12036', 'IPO again')] }]);
  await runChat(h.deps, v2(paperBody({ selection: { quote: 'DPO' }, action: 'related' })), h.emit, new AbortController().signal);
  const text = h.events.filter(e => e.event === 'delta').map(e => (e.data as { text: string }).text).join('');
  assert.match(text, /\n\nSources:\n1\. IPO — https:\/\/arxiv\.org\/abs\/2310\.12036\n2\. KTO — https:\/\/arxiv\.org\/abs\/2402\.01306\n3\. A — https:\/\/example\.org\/a$/);
  // An answer that ends with its own Sources list gets nothing appended.
  let again = 0;
  const own = harness({ generate: async (_params, stream) => {
    if (++again === 1) return searchRound([{ id: 'a', input: { query: 'one' } }]);
    stream.onText('IPO.\n\nSources:\n1. IPO — https://arxiv.org/abs/2310.12036'); return completeOutcome({ messageID: 'msg_final' });
  } });
  searching(own, [found]);
  await runChat(own.deps, v2(paperBody({ selection: { quote: 'DPO' }, action: 'related' })), own.emit, new AbortController().signal);
  const ownText = own.events.filter(e => e.event === 'delta').map(e => (e.data as { text: string }).text).join('');
  assert.equal(ownText.match(/Sources:/g)?.length, 1);
});

// ---- Models, effort and length (chat-profiles.ts) and topic titles (chat-title.ts), 2026-10-08 ----

test('the published profile table is versioned, complete, and its default is exactly today\'s request', () => {
  const table = publishedProfiles();
  assert.equal(table.version, 'chat-profiles-v1'); assert.equal(table.rate_version, 'beta-credits-v1');
  assert.deepEqual(table.default, { model: 'sonnet', effort: 'low', length: 'standard' });
  assert.deepEqual(table.models.map(m => [m.id, m.api_model]), [['haiku', 'claude-haiku-5-5'], ['sonnet', 'claude-sonnet-5-5'], ['opus', 'claude-opus-5-5']]);
  assert.deepEqual(table.efforts.map(e => e.id), ['low', 'medium', 'high']);
  assert.deepEqual(table.lengths.map(l => l.id), ['brief', 'standard', 'detailed']);
  assert.equal(table.profiles.length, 27);
  assert.equal(new Set(table.profiles.map(p => p.id)).size, 27);
  const byID = new Map(table.profiles.map(p => [p.id, p]));
  assert.equal(byID.get('sonnet-low-standard')!.max_output_tokens, CHAT_MAX_TOKENS);
  // Output allowances: the length's answer plus the effort's thinking (max_tokens covers both).
  assert.deepEqual(['brief', 'standard', 'detailed'].map(l => ['low', 'medium', 'high'].map(e => byID.get(`sonnet-${e}-${l}`)!.max_output_tokens)),
    [[3_000, 5_000, 9_000], [8_000, 10_000, 14_000], [12_000, 14_000, 18_000]]);
  for (const p of table.profiles) {
    assert.ok(p.credits.low <= p.credits.high && p.credits.high <= p.credits.max, `${p.id} estimate is ordered`);
    assert.equal(p.max_output_tokens, byID.get(`sonnet-${p.effort}-${p.length}`)!.max_output_tokens, 'allowances do not depend on the model');
  }
  // Models order by cost at every effort and length.
  for (const e of ['low', 'medium', 'high']) for (const l of ['brief', 'standard', 'detailed']) {
    const [h, s, o] = ['haiku', 'sonnet', 'opus'].map(m => byID.get(`${m}-${e}-${l}`)!.credits);
    assert.ok(h.max < s.max && s.max < o.max && h.high < s.high && s.high < o.high, `${e}/${l} orders by model`);
  }
  // Documented examples (CHAT.md): the default, and the two extremes.
  assert.deepEqual(byID.get('sonnet-low-standard')!.credits, { low: 4, high: 24, max: 37 });
  assert.deepEqual(byID.get('haiku-low-brief')!.credits, { low: 1, high: 2, max: 2 });
  assert.deepEqual(byID.get('opus-high-detailed')!.credits, { low: 24, high: 63, max: 114 });
  assert.ok(!JSON.stringify(table).includes('reader chose'), 'prompt text is not published');
});

test('a profile is a strict {model, effort, length}; the default named or not is the same request and digest', () => {
  const chosen = validateChatRequest(paperBody({ profile: { model: 'opus', effort: 'high', length: 'detailed' } }));
  assert.deepEqual(chosen.choice, { model: 'opus', effort: 'high', length: 'detailed' });
  const named = validateChatRequest(paperBody({ profile: { length: 'standard', model: 'sonnet', effort: 'low' } }));
  assert.equal(named.choice, null);
  assert.equal(canonicalRequest(named), canonicalRequest(validateChatRequest(paperBody())));
  assert.equal(canonicalRequest(validateChatRequest(paperBody({ profile: null, topic_title: false }))), canonicalRequest(validateChatRequest(paperBody())));
  assert.notEqual(canonicalRequest(chosen), canonicalRequest(validateChatRequest(paperBody())));
  assert.notEqual(canonicalRequest(validateChatRequest(paperBody({ topic_title: true }))), canonicalRequest(validateChatRequest(paperBody())));
  const repair = { operation_id: operation, consent_version: 'cloud-ai-v2', mode: 'general', action: 'diagram_fix', messages: [{ role: 'user', text: 'Title: x' }] };
  for (const body of [
    paperBody({ profile: { model: 'fable', effort: 'low', length: 'standard' } }), paperBody({ profile: { model: 'opus', effort: 'max', length: 'standard' } }),
    paperBody({ profile: { model: 'opus', effort: 'low', length: 'long' } }), paperBody({ profile: { model: 'opus', effort: 'low' } }),
    paperBody({ profile: { model: 'opus', effort: 'low', length: 'brief', api_model: 'claude-opus-5-5' } }), paperBody({ profile: 'opus' }),
    paperBody({ profile: ['opus', 'low', 'brief'] }), paperBody({ topic_title: 'yes' }), paperBody({ topic_title: 1 }),
    { ...repair, profile: { model: 'haiku', effort: 'low', length: 'brief' } }, { ...repair, topic_title: true },
  ]) assert.throws(() => validateChatRequest(body), { code: 'invalid_request' }, JSON.stringify(body).slice(0, 120));
  assert.equal(validateChatRequest({ ...repair, profile: { model: 'sonnet', effort: 'low', length: 'standard' } }).choice, null);
});

test('each profile sends its model, effort, allowance and length; the paper block is identical across lengths', async () => {
  const sent: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming[] = [];
  const run = async (profile: Record<string, string>) => {
    const h = harness({ generate: async (params, stream) => { sent.push(params); stream.onText('ok'); return completeOutcome({ model: params.model }); } });
    await runChat(h.deps, paperBody({ profile }), h.emit, new AbortController().signal);
    return h;
  };
  const haiku = await run({ model: 'haiku', effort: 'medium', length: 'brief' });
  const opus = await run({ model: 'opus', effort: 'high', length: 'detailed' });
  await run({ model: 'sonnet', effort: 'low', length: 'standard' });
  assert.equal(sent[0].model, 'claude-haiku-5-5'); assert.deepEqual(sent[0].output_config, { effort: 'medium' });
  assert.deepEqual(sent[0].thinking, { type: 'adaptive' }); assert.equal(sent[0].max_tokens, 5_000);
  assert.equal(sent[0].fallbacks, undefined); assert.equal(sent[0].betas, undefined, 'Haiku 5.5 has no fallback models');
  assert.equal(sent[1].model, 'claude-opus-5-5'); assert.deepEqual(sent[1].output_config, { effort: 'high' });
  assert.equal(sent[1].max_tokens, 18_000); assert.equal(sent[1].fallbacks, 'default'); assert.deepEqual(sent[1].betas, [FALLBACK_BETA]);
  assert.equal(sent[2].model, 'claude-sonnet-5-5'); assert.equal(sent[2].max_tokens, 8_000);
  const system = sent.map(params => params.system as Anthropic.Beta.Messages.BetaTextBlockParam[]);
  // Standard adds nothing (today's prompt); brief and detailed add their instructions after the cached paper.
  assert.equal(system[2].length, 2);
  assert.match(system[0][2].text, /brief answers/); assert.match(system[1][2].text, /detailed answers/);
  for (const blocks of system) {
    assert.equal(blocks[0].text, system[2][0].text, 'shared instructions do not change with the profile');
    assert.equal(blocks[1].text, system[2][1].text); assert.deepEqual(blocks[1].cache_control, { type: 'ephemeral' });
  }
  // The answer reports which model and profile answered.
  assert.deepEqual(haiku.events.at(-1)?.data, { stop_reason: 'end_turn', credits: 1,
    usage: { input_tokens: 900, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 300 },
    model: 'claude-haiku-5-5', profile: 'haiku-medium-brief' });
  const quote = opus.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as Record<string, unknown>;
  assert.deepEqual([quote.profile, quote.model, quote.effort, quote.length, quote.max_output_tokens], ['opus-high-detailed', 'claude-opus-5-5', 'high', 'detailed', 18_000]);
});

test('holds use the chosen model\'s rates: Opus at its fallbacks\' Opus 5 card twice, Haiku once at its prompt tier', () => {
  // 100,000 estimated tokens and 8,000 output tokens.
  assert.equal(holdFor(300_000, 8_000, 'claude-opus-5-5').microusd, (100_000 * 6.25 + 8_000 * 25) * 2);
  assert.equal(holdFor(300_000, 8_000, 'claude-haiku-5-5').microusd, 100_000 * 0.125 + 8_000 * 0.5);
  assert.equal(holdFor(300_003, 8_000, 'claude-haiku-5-5').microusd, Math.ceil(100_001 * 0.625 + 8_000 * 2.5));
  assert.equal(holdFor(300_000, 8_000, 'claude-sonnet-5-5').microusd, 990_000, 'Sonnet holds are unchanged');
  assert.equal(holdFor(300_000, 8_000, 'claude-mystery').microusd, (100_000 * 6.25 + 8_000 * 25) * 3);
  // Search holds follow the model too (Haiku's later rounds may cross into the long-prompt tier).
  assert.equal(webSearchHoldMicrousd(10_000, 3, 'claude-sonnet-5-5'), webSearchHoldMicrousd(10_000, 3));
  assert.equal(webSearchHoldMicrousd(10_000, 3, 'claude-haiku-5-5'), Math.ceil(3 * (10_000 + 10_000 * 0.125 + 60_000 * 0.1)));
  assert.equal(webSearchHoldMicrousd(10_001, 3, 'claude-haiku-5-5'), Math.ceil(3 * (10_000 + 10_001 * 0.625 + 60_000 * 0.5)));
  assert.equal(webSearchHoldMicrousd(1_000, 1, 'claude-haiku-5-5'), Math.ceil(10_000 + 1_000 * 0.125 + 60_000 * 0.1));
});

function titleOutcome(changes: Partial<ProviderOutcome> = {}): ProviderOutcome {
  return completeOutcome({ messageID: 'msg_title', model: 'claude-haiku-5-5',
    attempts: [{ model: 'claude-haiku-5-5', estimated: false, usage: { input: 400, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 8 } }], ...changes });
}

test('every admitted request fits the operation hold: the answer\'s first round plus the title', async () => {
  const ceilings: number[] = [];
  let reserved = 0;
  const h = harness({ script: { worker_reserve_chat: params => { reserved = Number(params.p_microusd); return { replayed: false }; } },
    generate: async (params, stream) => {
      ceilings.push(holdFor(promptCharacters(params), params.max_tokens, params.model).microusd);
      if (params.model === 'claude-haiku-5-5' && params.max_tokens === 40) { stream.onText('Scaled attention'); return titleOutcome(); }
      stream.onText('An answer.'); return completeOutcome({ model: params.model });
    } });
  await runChat(h.deps, paperBody({ topic_title: true, profile: { model: 'opus', effort: 'medium', length: 'standard' } }), h.emit, new AbortController().signal);
  assert.equal(ceilings.length, 2);
  assert.equal(ceilings.reduce((a, b) => a + b, 0), reserved, 'the hold is exactly the sum of the admitted ceilings');
  const quote = h.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as Record<string, unknown>;
  assert.equal(quote.title_model, 'claude-haiku-5-5'); assert.equal(quote.title_max_tokens, 40);
  assert.equal(quote.title_ceiling_microusd, Math.min(...ceilings));
});

test('a topic title is written alongside the answer with Haiku 5.5, sent before done, charged, and never logged', async () => {
  const sent: Anthropic.Beta.Messages.MessageCreateParamsNonStreaming[] = [];
  const h = harness({ generate: async (params, stream) => {
    sent.push(params);
    if (params.model === 'claude-haiku-5-5') { stream.onText('"Attention scaling '); stream.onText('explained."\n'); return titleOutcome(); }
    stream.onText('Scaling keeps logits bounded.'); return completeOutcome();
  } });
  await runChat(h.deps, paperBody({ topic_title: true, selection: { quote: 'divide by sqrt(d_k)' } }), h.emit, new AbortController().signal);
  const title = sent.find(params => params.model === 'claude-haiku-5-5')!;
  assert.equal(title.max_tokens, 40); assert.deepEqual(title.thinking, { type: 'disabled' });
  assert.equal(title.tools, undefined); assert.equal(title.fallbacks, undefined);
  const input = JSON.stringify(title.messages);
  assert.match(input, /<paper_title>Attention<\/paper_title>/); assert.match(input, /private-question-marker/); assert.match(input, /sqrt\(d_k\)/);
  assert.ok(!input.includes('We scale by'), 'the title never reads the paper text');
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'title', 'done']);
  assert.deepEqual(h.events[1].data, { text: 'Attention scaling explained' });
  // 900 input + 300 output (Sonnet) + 400 input + 8 output (Haiku 5.5) = 4,800 + 44 micro-USD.
  const settle = h.calls.find(c => c.name === 'worker_settle_operation')!.params;
  assert.equal(settle.p_actual_microusd, 4_844); assert.equal(settle.p_actual_credits, 1);
  const usage = h.calls.find(c => c.name === 'worker_record_provider_usage')!.params;
  assert.equal(usage.p_provider_event_id, 'msg_01'); assert.equal(usage.p_model, 'claude-sonnet-5-5');
  assert.deepEqual((usage.p_units as { attempts: { model: string }[] }).attempts.map(a => a.model), ['claude-sonnet-5-5', 'claude-haiku-5-5']);
  assert.equal(h.answers[0].title, 'written');
  assert.ok(!JSON.stringify([h.logs, h.answers, h.calls]).includes('Attention scaling'));
});

test('no title event without a complete answer or a usable title; the answer is unaffected', async () => {
  const cases: [string, (stream: StreamOptions) => ProviderOutcome, string][] = [
    ['unusable', stream => { stream.onText('   '); return titleOutcome(); }, 'unusable'],
    ['failed', () => titleOutcome({ status: 'failed', failure: 'provider_error', stopReason: null, exact: false }), 'failed'],
    ['cut off', stream => { stream.onText('A very long title that keeps going'); return titleOutcome({ stopReason: 'max_tokens' }); }, 'unusable'],
  ];
  for (const [label, write, logged] of cases) {
    const h = harness({ generate: async (params, stream) => {
      if (params.model === 'claude-haiku-5-5') return write(stream);
      stream.onText('Answer.'); return completeOutcome();
    } });
    await runChat(h.deps, generalBody({ topic_title: true }), h.emit, new AbortController().signal);
    assert.deepEqual(h.events.map(e => e.event), ['delta', 'done'], label);
    assert.equal(h.answers[0].title, logged, label);
  }
  // A refused answer gets no title (its title request is still settled).
  const refused = harness({ generate: async (params, stream) => {
    if (params.model === 'claude-haiku-5-5') { stream.onText('Some title'); return titleOutcome(); }
    return completeOutcome({ stopReason: 'refusal' });
  } });
  await runChat(refused.deps, generalBody({ topic_title: true }), refused.emit, new AbortController().signal);
  assert.deepEqual(refused.events, [{ event: 'error', data: { code: 'refused' } }]);
  assert.equal(refused.calls.filter(c => c.name === 'worker_settle_operation').length, 1);
  assert.equal(Number(refused.calls.find(c => c.name === 'worker_settle_operation')!.params.p_actual_microusd), 4_844);
});

test('a slow title is abandoned shortly after the answer and its attempt is still settled', async () => {
  let titleSignal: AbortSignal | undefined;
  const h = harness({ generate: async (params, stream) => {
    if (params.model !== 'claude-haiku-5-5') { stream.onText('Answer.'); return completeOutcome(); }
    titleSignal = stream.signal;
    await new Promise<void>(resolve => stream.signal.addEventListener('abort', () => resolve(), { once: true }));
    return titleOutcome({ status: 'failed', failure: 'aborted', stopReason: null, exact: false,
      attempts: [{ model: 'claude-haiku-5-5', estimated: true, usage: { input: 400, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }] });
  } });
  const started = Date.now();
  await runChat(h.deps, generalBody({ topic_title: true }), h.emit, new AbortController().signal);
  assert.ok(titleSignal?.aborted);
  assert.ok(Date.now() - started < 6_000);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'done']);
  assert.equal(h.calls.find(c => c.name === 'worker_settle_operation')!.params.p_actual_microusd, 4_840);
  assert.equal((h.calls.find(c => c.name === 'worker_record_provider_usage')!.params.p_units as { estimated: boolean }).estimated, true);
});

test('titles are cleaned to one plain line of at most 80 characters', () => {
  assert.equal(cleanTitle('Title: "Why DPO needs no reward model."'), 'Why DPO needs no reward model');
  assert.equal(cleanTitle('**Scaling in dot-product attention**\nExtra line'), 'Scaling in dot-product attention');
  assert.equal(cleanTitle('“Explainer for a persona paper”'), 'Explainer for a persona paper');
  assert.equal(cleanTitle('Attention‮ reversed\u0007 title'), 'Attention reversed title');
  assert.equal(cleanTitle(''), null); assert.equal(cleanTitle('...'), null); assert.equal(cleanTitle('x'.repeat(81)), null);
  assert.equal(cleanTitle(Array.from({ length: 13 }, (_, i) => `w${i}`).join(' ')), null);
  const params = titleRequestParams({ turns: [{ role: 'user', text: 'q1' }, { role: 'assistant', text: 'a1' }, { role: 'user', text: 'q2' }],
    selection: null, paperTitle: null });
  const text = String(params.messages[0].content);
  assert.match(text, /general conversation/); assert.match(text, /<first_question>q1<\/first_question>/);
  assert.match(text, /<first_answer>a1<\/first_answer>/); assert.match(text, /<latest_question>q2<\/latest_question>/);
});

test('the answer names the model that served it, a fallback model when one ran', async () => {
  const h = harness({ generate: async (_params, stream) => { stream.onText('Answer.'); return completeOutcome({ model: 'claude-sonnet-5' }); } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.equal((h.events.at(-1)?.data as { model?: string }).model, 'claude-sonnet-5');
  const odd = harness({ generate: async (_params, stream) => { stream.onText('Answer.'); return completeOutcome({ model: 'Bad Model!' }); } });
  await runChat(odd.deps, paperBody(), odd.emit, new AbortController().signal);
  assert.equal((odd.events.at(-1)?.data as { model?: string }).model, undefined);
});

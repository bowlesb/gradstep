import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { BUSY_RETRY_MAX_MS, retryOnceWhenBusy } from '../../supabase/functions/_shared/inference.ts';
import {
  ADD_PAPER_TOOL, CHAT_MAX_TOKENS, CHAT_MODEL, chatRequestParams, CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL, promptCharacters, SEARCH_WEB_TOOL, webSearchHoldMicrousd, creditsFor, holdFor, holdForParams, hourCachedCharacters, PAPER_CACHE_TTL, priceAttempts, ratesFor,
  UNKNOWN_MODEL_RATES, statusQuery, STATUS_QUERY_CHARS, type ChatStatus, type ProviderOutcome, type StreamOptions,
} from '../../supabase/functions/_shared/inference.ts';
import type { ModelRequest, TextBlock } from '../../supabase/functions/_shared/model-request.ts';
import { routerClaudeRates } from '../../supabase/functions/_shared/openrouter-claude-pricing.ts';
import { routerDeepSeekRates, ROUTER_DEEPSEEK_TARIFF } from '../../supabase/functions/_shared/openrouter-deepseek-pricing.ts';
import { openRouterChat } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { publishedProfiles } from '../../supabase/functions/_shared/chat-profiles.ts';
import { cleanTitle, titleRequestParams } from '../../supabase/functions/_shared/chat-title.ts';
import { FOLLOW_UP_HOLD_PARAMS, FOLLOW_UP_MAX_TOKENS, followUpRequest, followUpRequestParams, SUGGEST_FOLLOW_UPS_TOOL } from '../../supabase/functions/_shared/chat-follow-ups.ts';
import { EQUATION_MAX_TOKENS, equationSymbols, paragraphCount } from '../../supabase/functions/_shared/chat-equation.ts';
import { figureBox, figureDetail, figureDetailMaxTokens, figureMaxTokens, figureViewEffort, figureWalkthrough, FigureWalkthroughStream, figureWalkthroughText, offeredBoxes,
  type FigureStreamItem } from '../../supabase/functions/_shared/chat-figure-view.ts';
import { openRouterChatParams } from '../../supabase/functions/_shared/openrouter-chat.ts';
import { EMPTY_STUDY_MAP, STUDY_HOLD_PARAMS, STUDY_MAX_TOKENS, studyMap, UPDATE_STUDY_MAP_TOOL } from '../../supabase/functions/_shared/chat-study.ts';
import { ACADEMIC_DOMAINS, parseResults, searchInput, tavilySearch, TAVILY_RESULT_CHARS, type SearchOutcome } from '../../supabase/functions/_shared/tavily.ts';
import {
  canonicalRequest, chatInstructionParts, chatInstructions, DIAGRAM_FIX_MAX_TOKENS, diagramRequest, ingestReport, paperRequest, sourcesText, readChatBody, RpcFailure, runChat, sseFrame, validateChatRequest,
  type ChatDependencies, type ChatEvent, type LogEntry,
} from '../../supabase/functions/_shared/chat.ts';
import { freeModel, switchRefusal, withCheapDefaults } from '../../supabase/functions/_shared/ai-switches.ts';

const account = 'aaaaaaaa-0000-4000-8000-000000000001';
const operation = 'bbbbbbbb-0000-4000-8000-000000000002';
const documentID = 'cccccccc-0000-4000-8000-000000000003';
const secretQuestion = 'What does the attention scaling factor do? (private-question-marker)';
const paperText = '# Attention\n\nWe scale by \\( 1/\\sqrt{d_k} \\). '.repeat(40);
// Every answer goes to OpenRouter (owner, 2026-10-18 and 2026-10-21), so every request carries a consent that names it:
// v6 (OpenRouter, its Google Vertex and DeepInfra routes, Tavily and figures), as current builds send.
const CONSENT = 'cloud-ai-v6';
/** The OpenRouter models and their reviewed cards (micro-USD per token). */
const SONNET = 'anthropic/claude-sonnet-5.5', HAIKU = 'anthropic/claude-haiku-5.5', OPUS = 'anthropic/claude-opus-5.5';
const FLASH = 'deepseek/deepseek-v4.1-flash-1017';

function paperBody(overrides: Record<string, unknown> = {}) {
  return { operation_id: operation, consent_version: CONSENT, mode: 'paper', document_id: documentID,
    messages: [{ role: 'user', text: secretQuestion }], ...overrides };
}
function generalBody(overrides: Record<string, unknown> = {}) {
  return { operation_id: operation, consent_version: CONSENT, mode: 'general', messages: [{ role: 'user', text: 'Hello' }], ...overrides };
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

test('pricing follows the reviewed OpenRouter cards and never undercharges a model without one', () => {
  for (const model of [SONNET, HAIKU, OPUS, FLASH, 'gemini-3.8-flash']) assert.equal(ratesFor(model).known, true, model);
  // Direct-provider names have no card (and no route: they are never sent); they price at the ceiling card.
  for (const model of ['claude-sonnet-5-5', 'claude-sonnet-5', 'deepseek-flash', 'claude-mystery', null, '__proto__']) {
    assert.deepEqual(ratesFor(model), { rates: UNKNOWN_MODEL_RATES, known: false }, String(model));
  }
  const usage = { input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 0, cacheRead: 1_000_000, output: 1_000_000 };
  const card = (model: string) => { const r = ratesFor(model).rates; return r.input * 1_000_000 + r.cacheWrite5m * 1_000_000 + r.cacheRead * 1_000_000 + r.output * 1_000_000; };
  // Sonnet 5.5 through Vertex: $2.20 in, $2.75 five-minute write, $0.11 read (0.05x), $11 out per million.
  assert.equal(Math.round(priceAttempts([{ model: SONNET, usage, estimated: false }])), 16_060_000);
  assert.equal(priceAttempts([{ model: SONNET, usage, estimated: false }]), card(SONNET));
  // Opus 5.5 through Vertex: $4.40 / $5.50 / $0.22 / $22.
  assert.equal(Math.round(priceAttempts([{ model: OPUS, usage, estimated: false }])), 32_120_000);
  // The ceiling card ($5 / $6.25 / $0.50 / $25) is above every reviewed card.
  assert.equal(priceAttempts([{ model: 'unknown', usage, estimated: false }]), 36_750_000);
  for (const model of [SONNET, HAIKU, OPUS, FLASH]) for (const key of ['input', 'cacheWrite5m', 'cacheWrite1h', 'cacheRead', 'output'] as const) {
    assert.ok(UNKNOWN_MODEL_RATES[key] >= ratesFor(model, 200_000).rates[key], `${model} ${key}`);
  }
  // Haiku 5.5: a prompt over 100,000 tokens pays the long-prompt card for the whole request.
  const short = routerClaudeRates(HAIKU, 100_000), long = routerClaudeRates(HAIKU, 100_001);
  assert.equal(priceAttempts([{ model: HAIKU, usage: { input: 50_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 50_000, output: 1_000 }, estimated: false }]),
    50_000 * short.input + 50_000 * short.cacheRead + 1_000 * short.output);
  assert.equal(priceAttempts([{ model: HAIKU, usage: { input: 50_001, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 50_000, output: 1_000 }, estimated: false }]),
    50_001 * long.input + 50_000 * long.cacheRead + 1_000 * long.output);
  // OpenRouter's reported cost wins over any card; an estimate never uses it.
  assert.equal(priceAttempts([{ model: SONNET, usage, estimated: false, billedMicrousd: 123.4 }]), 123.4);
  assert.equal(priceAttempts([{ model: SONNET, usage, estimated: true, billedMicrousd: 123.4 }]), card(SONNET));
  assert.equal(creditsFor(0), 0); assert.equal(creditsFor(1), 1); assert.equal(creditsFor(5_000), 1); assert.equal(creditsFor(5_001), 2);
  // Hold: weighted chars/3 tokens at the cache-write rate plus the whole output budget; Sonnet on Vertex is one attempt
  // (no server-side fallback on this route), a model without a card three at the ceiling card.
  const sonnet = routerClaudeRates(SONNET);
  assert.equal(CHAT_MODEL, SONNET);
  assert.deepEqual(holdFor(300_000, 8_000), { inputTokens: 100_000, microusd: Math.ceil(100_000 * sonnet.cacheWrite5m + 8_000 * sonnet.output),
    credits: creditsFor(Math.ceil(100_000 * sonnet.cacheWrite5m + 8_000 * sonnet.output)) });
  assert.equal(holdFor(1, 8_000, 'unknown').microusd, Math.ceil((1 * 6.25 + 8_000 * 25) * 3));
});

test('request params cache the paper prefix and enable adaptive thinking; no provider-specific fallback', () => {
  const params = chatRequestParams({ instructions: chatInstructions('paper'), paper: { title: 'A "quoted" <title>', text: paperText },
    turns: [{ role: 'user', text: 'q1' }, { role: 'assistant', text: 'a1' }, { role: 'user', text: 'q2' }], selection: 'the passage' });
  assert.equal(params.model, SONNET); assert.equal(params.max_tokens, CHAT_MAX_TOKENS);
  assert.deepEqual(params.thinking, { type: 'adaptive' }); assert.deepEqual(params.output_config, { effort: 'low' });
  assert.equal((params as Record<string, unknown>).betas, undefined); assert.equal((params as Record<string, unknown>).fallbacks, undefined);
  // Owner feedback 2026-10-07: answers start with their content, not an "Answer:" label.
  for (const mode of ['paper', 'general'] as const) assert.match(chatInstructions(mode), /no label such as "Answer:"/);
  const system = params.system as TextBlock[];
  assert.equal(system.length, 2); assert.equal(system[0].cache_control, undefined);
  assert.deepEqual(system[1].cache_control, { type: 'ephemeral', ttl: '1h' });
  assert.ok(system[1].text.startsWith('<paper title="A  quoted   title">\n'));
  assert.ok(system[1].text.endsWith(`${paperText}\n</paper>`));
  assert.match(system[0].text, /\\\( \.\.\. \\\)/); assert.match(system[0].text, /\\\[ \.\.\. \\\]/);
  assert.deepEqual(params.messages[1], { role: 'assistant', content: 'a1' });
  const last = params.messages[2].content as TextBlock[];
  assert.equal(last[0].text, '<selected_passage>\nthe passage\n</selected_passage>'); assert.equal(last[1].text, 'q2');
  const general = chatRequestParams({ instructions: chatInstructions('general'), paper: null, turns: [{ role: 'user', text: 'q' }], selection: null });
  assert.equal((general.system as unknown[]).length, 1); assert.deepEqual(general.messages, [{ role: 'user', content: 'q' }]);
});

test('ingest requests carry only add_paper; other requests carry only create_diagram', () => {
  const turns = [{ role: 'user' as const, text: 'Find and add the paper referenced in this passage' }];
  const ingest = chatRequestParams({ instructions: chatInstructions('paper', 'ingest'), paper: { title: 'T', text: paperText }, turns, selection: '[12] DPO', tools: [ADD_PAPER_TOOL] });
  assert.deepEqual(ingest.tools, [ADD_PAPER_TOOL]); assert.equal(ingest.tool_choice, undefined);
  const ingestSystem = (ingest.system as TextBlock[])[0].text;
  assert.match(ingestSystem, /call add_paper once/); assert.doesNotMatch(ingestSystem, /create_diagram/);
  const plain = chatRequestParams({ instructions: chatInstructions('paper'), paper: { title: 'T', text: paperText }, turns, selection: '[12] DPO', tools: [CREATE_DIAGRAM_TOOL] });
  assert.deepEqual(plain.tools, [CREATE_DIAGRAM_TOOL]);
  const plainSystem = (plain.system as TextBlock[])[0].text;
  assert.match(plainSystem, /call create_diagram once/); assert.match(plainSystem, /call create_visual once/); assert.doesNotMatch(plainSystem, /add_paper/);
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
  assert.deepEqual(tools, [CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL, SHOW_FIGURE_PARTS_TOOL]);
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

test('ingest adds one title-matched paper before settlement and reports it in the answer', async () => {
  const found: unknown[] = [], imported: string[] = [];
  let tools: unknown;
  const h = harness({ generate: async (params, stream) => { tools = (params as { tools?: unknown }).tools; return toolGenerate({ title: 'Direct Preference Optimization', year: 2023 })(params, stream); } });
  h.deps.findPaper = async wanted => { found.push(wanted); return { status: 'found', paper: { source_id: '2305.18290', title: 'Direct Preference Optimization: Your Language Model is Secretly a Reward Model', year: 2023 } }; };
  // The add runs before the settlement (import takes no hold), so an add that fails can cost the reader nothing.
  h.deps.importPaper = async paper => { imported.push(paper.source_id); assert.ok(!names(h.calls).includes('worker_settle_chat')); return 'added'; };
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
  const settled = h.calls.find(c => c.name === 'worker_settle_chat')!;
  assert.ok((settled.params.p_actual_credits as number) > 0, 'an added paper is paid for');
});

test('an add that doesn\'t happen costs the reader nothing and says so; Gradstep absorbs the provider cost', async () => {
  for (const [label, find, importPaper] of [
    ['not found', async () => ({ status: 'not_found' as const }), async () => 'added' as const],
    ['import failed', async () => ({ status: 'found' as const, paper: { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 } }),
      async () => { throw new Error('library_active_import_limit'); }],
    ['search unavailable', async () => { throw new Error('search_busy'); }, async () => 'added' as const],
  ] as const) {
    const h = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
    h.deps.findPaper = find as never; h.deps.importPaper = importPaper as never;
    await runChat(h.deps, ingestBody(), h.emit, new AbortController().signal);
    const settled = h.calls.find(c => c.name === 'worker_settle_chat')!;
    assert.equal(settled.params.p_actual_credits, 0, label);
    assert.equal(settled.params.p_absorbed_microusd, settled.params.p_actual_microusd, `${label}: absorbed`);
    assert.match(delta(h, 1).text, /Not charged\.$/, label);
    assert.equal((h.events.at(-1)!.data as { credits: number }).credits, 0, `${label}: done says 0 credits`);
  }
  // No add asked for (the model couldn't tell which paper): nothing added, nothing charged.
  const none = harness({ generate: async (_p, stream) => { stream.onText('This passage names no paper.'); return completeOutcome({ stopReason: 'end_turn' }); } });
  await runChat(none.deps, ingestBody(), none.emit, new AbortController().signal);
  assert.equal(none.calls.find(c => c.name === 'worker_settle_chat')!.params.p_actual_credits, 0);
  assert.equal(delta(none, 1).text, '\n\nNot charged.');
  // Already in the library: the reader was answered, and pays.
  const present = harness({ generate: toolGenerate({ title: 'Direct Preference Optimization' }) });
  present.deps.findPaper = async () => ({ status: 'found', paper: { source_id: '2305.18290', title: 'Direct Preference Optimization', year: 2023 } });
  present.deps.importPaper = async () => 'present';
  await runChat(present.deps, ingestBody(), present.emit, new AbortController().signal);
  assert.ok((present.calls.find(c => c.name === 'worker_settle_chat')!.params.p_actual_credits as number) > 0);
  assert.doesNotMatch(delta(present, 1).text, /Not charged/);
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
  // A23: the immutable ledger keeps how many keys the model sent, never the model-chosen names.
  assert.equal((recorded.params.p_units as { key_count: number }).key_count, 1);
  assert.ok(!('keys' in (recorded.params.p_units as object)));

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
  assert.ok(names(h.calls).includes('worker_settle_chat'));
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

test('web search is offered only when the server enables it and Tavily is ready, and never on Ingest', async () => {
  const seen: unknown[] = [];
  const capture = (generateText: string) => async (params: unknown, stream: StreamOptions) => {
    seen.push((params as { tools?: unknown }).tools); stream.onText(generateText); return completeOutcome();
  };
  const off = harness({ generate: capture('a') });
  await runChat(off.deps, paperBody(), off.emit, new AbortController().signal);
  const on = harness({ generate: capture('b') }); searching(on, []);
  await runChat(on.deps, paperBody(), on.emit, new AbortController().signal);
  const unready = harness({ generate: capture('d') }); searching(unready, [], false);
  await runChat(unready.deps, paperBody(), unready.emit, new AbortController().signal);
  const ingest = harness({ generate: capture('c') }); searching(ingest, []);
  await runChat(ingest.deps, ingestBody(), ingest.emit, new AbortController().signal);
  assert.deepEqual(seen, [[CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL, SHOW_FIGURE_PARTS_TOOL], [CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL, SHOW_FIGURE_PARTS_TOOL, SEARCH_WEB_TOOL],
    [CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL, SHOW_FIGURE_PARTS_TOOL], [ADD_PAPER_TOOL]], 'our search_web function tool only; no provider-native search');
  // Every request completed (a fractional bigint amount once failed the reservation).
  for (const run of [off, on, unready, ingest]) assert.equal(run.events.at(-1)?.event, 'done', JSON.stringify(run.events.at(-1)));
  assert.ok(Number.isSafeInteger(webSearchHoldMicrousd(39_657)));
  assert.match(chatInstructions('paper', null, true), /You can search the web/);
  assert.doesNotMatch(chatInstructions('paper', null, false), /search the web/);
  // The hold grows by the search allowance.
  const holdOff = Number(off.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_microusd);
  const holdOn = Number(on.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_microusd);
  const inputTokens = Math.ceil(promptCharacters(chatRequestParams({ instructions: chatInstructions('paper', null, true),
    paper: { title: 'Attention', text: paperText }, turns: [{ role: 'user', text: secretQuestion }], selection: null,
    tools: [CREATE_DIAGRAM_TOOL, SEARCH_WEB_TOOL] })) / 3);
  assert.ok(holdOn >= holdOff + webSearchHoldMicrousd(inputTokens) - 1);
  assert.ok(webSearchHoldMicrousd(50_000) > 3 * (10_000 + 50_000 * 2.75));
});

test('an answer that lists its own sources gets no second list', async () => {
  let round = 0;
  const h = harness({ generate: async (_p, stream) => {
    if (++round === 1) return searchRound([{ id: 's1', input: { query: 'IPO' } }]);
    stream.onText('IPO generalizes DPO.\n\nSources:\n1. IPO — https://arxiv.org/abs/2310.12036');
    return completeOutcome();
  } });
  searching(h, [found]);
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.filter(e => e.event !== 'status').map(e => e.event), ['delta', 'done']);
  assert.match(chatInstructions('paper', null, true), /end your answer with a line "Sources:"/);
  assert.equal(sourcesText([]), '');
  assert.equal(sourcesText([{ url: 'javascript:alert(1)', title: 'bad' }, { url: 'https://example.org/blog', title: null }]), '\n\nSources:\n1. https://example.org/blog');
});

test('a balance between 50 credits and the full hold caps the credit hold, never the budget hold', async () => {
  const run = async (available: number | null, generate?: ChatDependencies['generate']) => {
    const paper = new TextEncoder().encode(paperText.repeat(40));
    const h = harness(generate ? { generate, paper } : { paper });
    if (available !== null) h.deps.availableCredits = async () => available;
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    return { h, reserve: h.calls.find(c => c.name === 'worker_reserve_chat')?.params };
  };
  const full = (await run(null)).reserve!;
  assert.ok(Number(full.p_credits) > 60, `full hold ${full.p_credits}`);
  const capped = (await run(60)).reserve!;
  assert.equal(capped.p_credits, 60); assert.equal(capped.p_microusd, full.p_microusd);
  assert.equal((await run(10)).reserve, undefined, 'clearly insufficient credits are refused before fetching the paper');
  assert.equal((await run(100_000)).reserve!.p_credits, full.p_credits);
  // An answer costing more than the capped hold charges the balance and logs it.
  const costly = await run(60, async (_p, stream) => { stream.onText('x');
    return completeOutcome({ attempts: [{ model: SONNET, estimated: false, billedMicrousd: 310_000, usage: { input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 31_000 } }] }); });
  assert.equal(costly.h.calls.find(c => c.name === 'worker_settle_chat')!.params.p_actual_credits, 60);
  assert.ok(costly.h.logs.some(l => l.event === 'chat_credits_capped_at_balance'));
});

test('unavailable or clearly insufficient credits stop before paper context authorization and Storage GET', async () => {
  // Below what the request without its paper already holds (Sonnet: 8,000 output tokens at $11 per million, ~18 credits).
  for (const available of [null, 0, 1, 10]) {
    const h = harness(); let downloads = 0;
    h.deps.availableCredits = async () => available;
    h.deps.loadPaper = async () => { downloads++; return new TextEncoder().encode(paperText); };
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.equal(downloads, 0);
    assert.ok(!h.calls.some(call => ['worker_chat_context', 'worker_reserve_chat'].includes(call.name)));
    assert.deepEqual(h.events.at(-1), { event: 'error', data: available === null ? { code: 'service_unavailable', retry_after: 10 } : { code: 'insufficient_credits' } });
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

test('Ingest paid discovery requires a consent naming Tavily and the enabled server switch', async () => {
  for (const [consent, enabled, allowed] of [['cloud-ai-v5', false, false], ['cloud-ai-v5', true, true], ['cloud-ai-v6', true, true]] as const) {
    const h = harness({ generate: toolGenerate({ title: 'A sufficiently precise paper title' }) });
    h.deps.webSearch = enabled;
    h.deps.findPaper = async (_request, _signal, options) => { assert.equal(options.tavily, allowed); return { status: 'not_found' }; };
    h.deps.importPaper = async () => 'failed';
    await runChat(h.deps, { ...ingestBody(), consent_version: consent }, h.emit, new AbortController().signal);
    assert.equal(h.events.at(-1)?.event, 'done');
  }
});

test('web search without a configured search provider offers no search tool at all (no provider-native backup exists)', async () => {
  const h = harness({ generate: async (params) => {
    assert.ok(!params.tools?.some(tool => tool.name === 'web_search' || tool.name === 'search_web'));
    return completeOutcome();
  } });
  h.deps.webSearch = true;
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.equal(h.answers[0].web_search_offered, false); assert.equal(h.answers[0].search_provider, 'none');
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
// OpenRouter reports each generation's cost (`usage.cost`); 900 input and 300 output tokens here cost $0.0048.
function completeOutcome(changes: Partial<ProviderOutcome> = {}): ProviderOutcome {
  return { status: 'complete', failure: null, messageID: 'gen-01', model: SONNET, stopReason: 'end_turn', refusalCategory: null,
    attempts: [{ model: SONNET, estimated: false, billedMicrousd: 4_800, usage: { input: 900, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 300 } }],
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
    worker_settle_chat: params => {
      assert.ok(Number.isSafeInteger(params.p_actual_credits) && Number.isSafeInteger(params.p_actual_microusd), 'settlement amounts are integers');
      // Migration 079: the ending, and the provider cost Gradstep absorbs, are recorded with the settlement.
      assert.ok(Number.isSafeInteger(params.p_absorbed_microusd) && (params.p_absorbed_microusd as number) >= 0, 'absorbed cost is a whole amount');
      assert.ok(['completed', 'stopped', 'left'].includes(params.p_ending as string) || params.p_actual_credits === 0, 'an uncharged ending charges nothing');
      return null;
    },
    worker_chat_stop_requested: () => false,
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
    // Per-answer count lines go to `answers`; `logs` keeps the event-specific lines tests assert on.
    log: entry => { (entry.event === 'chat_answer' ? answers : logs).push(entry); },
    sleep: async () => {},
  };
  return { deps, calls, events, logs, answers, emit: (event: ChatEvent) => events.push(event), generations: () => generations };
}
// ---- Web search: our search_web tool, run with Tavily ----

/** A consent that names Tavily (v2 and later); every answer now needs v5 or later, which names OpenRouter. */
const v2 = (body: Record<string, unknown>) => ({ ...body, consent_version: CONSENT });
type Sent = { messages: { role: string; content: unknown }[]; tools?: { name?: string; type?: string; max_uses?: number }[]; max_tokens: number };
function searchRound(calls: { id: string; input: unknown; name?: string }[], output = 120): ProviderOutcome {
  const toolCalls = calls.map(call => ({ id: call.id, name: call.name ?? 'search_web', input: call.input }));
  return completeOutcome({ messageID: 'gen-round', stopReason: 'tool_use', toolCalls,
    attempts: [{ model: SONNET, estimated: false, billedMicrousd: 900 * 2 + output * 10, usage: { input: 900, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output } }],
    content: [{ type: 'text', text: 'Let me look.' }, ...toolCalls.map(call => ({ type: 'tool_use', ...call }))] });
}
const found: SearchOutcome = { status: 'ok', credits: 1, results: [{ url: 'https://arxiv.org/abs/2310.12036', title: 'IPO', text: 'A general paradigm.', published: '2023-10-18' }] };
function searching(h: ReturnType<typeof harness>, outcomes: SearchOutcome[], ready = true) {
  const runs: unknown[] = [];
  h.deps.webSearch = true;
  h.deps.search = { ready: async () => ready, run: async input => { runs.push(input); return outcomes.shift() ?? found; } };
  return runs;
}

const names = (calls: Call[]) => calls.map(call => call.name);
function noPlaintext(logs: LogEntry[]) {
  const serialized = JSON.stringify(logs);
  assert.ok(!serialized.includes('private-question-marker') && !serialized.includes('Attention\n'));
}

test('a paper answer holds, streams, settles once and records usage', async () => {
  const h = harness();
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_chat_context', 'worker_reserve_chat', 'worker_settle_chat', 'worker_record_provider_usage']);
  const reserve = h.calls[2].params, settle = h.calls[3].params, usage = h.calls[4].params;
  assert.equal(reserve.p_rate_version, 'beta-credits-v1'); assert.equal(reserve.p_id, operation);
  // The quote freezes the default profile: Sonnet 5.5 through OpenRouter at its reviewed Vertex card.
  assert.deepEqual(reserve.p_quote, { profile_version: 'chat-profiles-v1', profile: 'sonnet-low-standard', model: SONNET,
    effort: 'low', length: 'standard', tariff: 'openrouter-claude-vertex-us-20261017', max_output_tokens: 8_000,
    input_estimate_tokens: (reserve.p_quote as { input_estimate_tokens: number }).input_estimate_tokens, max_searches: 0,
    title_model: null, title_max_tokens: null, title_ceiling_microusd: null });
  assert.match(String(reserve.p_request_sha256), /^\\x[0-9a-f]{64}$/);
  const expected = createHash('sha256').update(canonicalRequest(validateChatRequest(paperBody()))).digest('hex');
  assert.equal(reserve.p_request_sha256, `\\x${expected}`);
  assert.ok(Number(reserve.p_credits) >= 16 && Number(reserve.p_microusd) >= 80_000);
  // OpenRouter's reported cost, 4,800 micro-USD -> 1 credit.
  assert.deepEqual(settle, { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 4_800,
    p_action: 'answer', p_ending: 'completed', p_absorbed_microusd: 0 });
  assert.equal(usage.p_provider, 'openrouter'); assert.equal(usage.p_provider_event_id, 'gen-01'); assert.equal(usage.p_microusd, 4_800);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.deepEqual(h.events[2].data, { stop_reason: 'end_turn', credits: 1,
    usage: { input_tokens: 900, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 300 },
    model: 'claude-sonnet-5-5', profile: 'sonnet-low-standard', charged: true });
  noPlaintext(h.logs); assert.equal(h.logs.length, 0);
});

test('general chat skips paper context', async () => {
  const h = harness();
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(names(h.calls), ['worker_consume_request', 'worker_reserve_chat', 'worker_settle_chat', 'worker_record_provider_usage']);
  assert.equal(h.events.at(-1)?.event, 'done');
});

test('a build without stop_signal closing the stream aborts the provider and is charged as a Stop (left), settled once', async () => {
  const client = new AbortController();
  const h = harness({ generate: async (_params, stream) => {
    stream.onText('partial ');
    client.abort();
    assert.ok(stream.signal.aborted, 'provider signal follows the client');
    stream.onText('late text');
    return { status: 'failed', failure: 'aborted', messageID: 'msg_02', model: SONNET, stopReason: null, refusalCategory: null,
      attempts: [{ model: SONNET, estimated: true, usage: { input: 1000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 100 }, readerMicrousd: 3_000 }], exact: false };
  } });
  await runChat(h.deps, paperBody(), h.emit, client.signal);
  assert.deepEqual(h.events, [{ event: 'delta', data: { text: 'partial ' } }]);
  const settles = h.calls.filter(c => c.name === 'worker_settle_chat');
  assert.equal(settles.length, 1);
  // The reader pays for what was written (3,000); the estimate (1,000 input at $2.20 + 100 output at $11 = 3,300) is
  // the provider spend, and the 300 between them is Gradstep's.
  assert.deepEqual(settles[0].params, { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 3_300,
    p_action: 'answer', p_ending: 'left', p_absorbed_microusd: 300 });
  // Nothing asks whether the reader pressed Stop: the build can't say.
  assert.ok(!names(h.calls).includes('worker_chat_stop_requested'));
  const usage = h.calls.find(c => c.name === 'worker_record_provider_usage')!.params;
  assert.equal((usage.p_units as { estimated: boolean }).estimated, true);
});

test('a provider error mid-stream settles once, charges nothing (Gradstep absorbs it) and reports provider_unavailable', async () => {
  const h = harness({ generate: async (_params, stream) => {
    stream.onText('half an answer');
    return { status: 'failed', failure: 'provider_error', messageID: 'msg_03', model: SONNET, stopReason: null, refusalCategory: null,
      attempts: [{ model: SONNET, estimated: true, usage: { input: 500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 50 } }], exact: false };
  } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.equal(h.calls.filter(c => c.name === 'worker_settle_chat').length, 1);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'error']);
  // Mid-stream (message_start seen; owner decision 2026-10-16): the reader keeps the partial text and pays nothing; the
  // estimated provider cost (500 input at $2.20 + 50 output at $11 = 1,650 micro-USD) is Gradstep's, recorded as absorbed.
  assert.deepEqual(h.events[1].data, { code: 'provider_unavailable', credits: 0, charged: false, reason: 'provider', retry_after: 10 });
  assert.deepEqual(h.calls.find(c => c.name === 'worker_settle_chat')!.params, { p_account_id: account, p_id: operation, p_actual_credits: 0,
    p_actual_microusd: 1_650, p_action: 'answer', p_ending: 'provider', p_absorbed_microusd: 1_650 });
});

test('A13: a provider billing refusal (402) settles without charge and blames the service, not the chosen model', async () => {
  const h = harness({ generate: async () => ({ status: 'failed', failure: 'provider_billing', messageID: null,
    model: SONNET, stopReason: null, refusalCategory: null, attempts: [], exact: true }) });
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events, [{ event: 'error', data: { code: 'service_unavailable', credits: 0, charged: false, reason: 'provider', retry_after: 300 } }]);
  assert.deepEqual(h.logs, [{ event: 'chat_provider_billing', operation_id: operation, provider: 'openrouter' }]);
  const settlements = h.calls.filter(c => c.name === 'worker_settle_chat');
  assert.equal(settlements.length, 1);
  assert.equal(settlements[0].params.p_actual_credits, 0);
  assert.equal(settlements[0].params.p_actual_microusd, 0);
});

test('a thrown provider failure is settled as uncertain input, never left reserved', async () => {
  const h = harness({ generate: async () => { throw new Error('boom'); } });
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  const settles = h.calls.filter(c => c.name === 'worker_settle_chat');
  assert.equal(settles.length, 1); assert.ok(Number(settles[0].params.p_actual_microusd) > 0);
  // Never started: nothing charged to the reader (the attempt keeps the platform's liability). The adapters never throw
  // for a provider's failure, so a throw is our own server failing, and says so.
  assert.deepEqual(h.events, [{ event: 'error', data: { code: 'service_unavailable', credits: 0, charged: false, reason: 'server', retry_after: 10 } }]);
  assert.equal(settles[0].params.p_ending, 'server'); assert.equal(settles[0].params.p_actual_credits, 0);
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
    assert.ok(!names(h.calls).includes('worker_settle_chat'));
    assert.deepEqual(h.events, [{ event: 'error', data: { code, ...(code === 'rate_limited' ? { retry_after: 60 } : code === 'service_unavailable' ? { retry_after: 10 } : {}) } }]);
  }
  const ambiguous = harness({ script: { worker_reserve_chat: () => { throw new Error('transport'); } } });
  await runChat(ambiguous.deps, paperBody(), ambiguous.emit, new AbortController().signal);
  assert.deepEqual(ambiguous.events, [{ event: 'error', data: { code: 'service_unavailable', retry_after: 10 } }]);
  assert.deepEqual(ambiguous.logs, [{ event: 'chat_reserve_uncertain', operation_id: operation }]);
});

test('rate limits, missing papers and invalid bodies stop before any hold', async () => {
  const limited = harness({ script: { worker_consume_request: () => { throw new RpcFailure('request_rate_limit'); } } });
  await runChat(limited.deps, paperBody(), limited.emit, new AbortController().signal);
  assert.deepEqual(limited.events, [{ event: 'error', data: { code: 'rate_limited', retry_after: 60 } }]);
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
  assert.deepEqual(unconfigured.events, [{ event: 'error', data: { code: 'provider_unavailable', retry_after: 10 } }]);
  assert.ok(!names(unconfigured.calls).includes('worker_reserve_chat'));
});

test('a refusal is settled at no charge and reported as refused', async () => {
  const h = harness({ generate: async (_params, stream) => { stream.onText('Partial'); return completeOutcome({ stopReason: 'refusal', refusalCategory: 'bio' }); } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.equal(h.calls.filter(c => c.name === 'worker_settle_chat').length, 1);
  assert.deepEqual(h.events.at(-1), { event: 'error', data: { code: 'refused', credits: 0, charged: false, reason: 'refusal' } });
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.equal(settle.p_actual_credits, 0); assert.equal(settle.p_ending, 'refusal');
  assert.equal(settle.p_absorbed_microusd, settle.p_actual_microusd, 'the refused attempt is Gradstep\'s cost');
  const units = h.calls.find(c => c.name === 'worker_record_provider_usage')!.params.p_units as Record<string, unknown>;
  assert.equal(units.refusal_category, 'bio');
});

test('usage above the hold charges at most the hold but records the true cost', async () => {
  const h = harness({ generate: async (_params, stream) => { stream.onText('A long answer.'); return completeOutcome({ attempts: [{ model: SONNET, estimated: false,
    usage: { input: 5_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 8_000 } }] }); } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  const reserve = h.calls.find(c => c.name === 'worker_reserve_chat')!.params;
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.ok((settle.p_actual_microusd as number) > (reserve.p_microusd as number), 'true provider cost reaches the budget (an anomaly, migration 079)');
  assert.equal(settle.p_actual_credits, reserve.p_credits);
  assert.equal(h.logs[0].event, 'chat_usage_exceeded_hold'); noPlaintext(h.logs);
  assert.equal((h.events.at(-1)!.data as { credits: number }).credits, reserve.p_credits);
});

test('settlement retries only ambiguous transport failures with identical amounts', async () => {
  let attempts = 0;
  const h = harness({ script: { worker_settle_chat: () => { attempts++; if (attempts < 3) throw new Error('transport'); return null; } } });
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  const settles = h.calls.filter(c => c.name === 'worker_settle_chat');
  assert.equal(settles.length, 3); assert.ok(settles.every(s => JSON.stringify(s.params) === JSON.stringify(settles[0].params)));
  const rejected = harness({ script: { worker_settle_chat: () => { throw new RpcFailure('invalid_settlement'); } } });
  await runChat(rejected.deps, generalBody(), rejected.emit, new AbortController().signal);
  assert.equal(rejected.calls.filter(c => c.name === 'worker_settle_chat').length, 1);
  assert.deepEqual(rejected.logs, [{ event: 'chat_settle_failed', operation_id: operation, reason: 'rejected' }]);
});

test('A23: done reports what the settlement recorded, not what it tried', async () => {
  const doneOf = (h: ReturnType<typeof harness>) => h.events.at(-1)!.data as { credits: number; charged: boolean; reason?: string };
  // Refused by the database (here unreadable afterwards): the stale sweep settles it as our server's ending, charging nothing.
  const rejected = harness({ script: { worker_settle_chat: () => { throw new RpcFailure('invalid_settlement'); } } });
  await runChat(rejected.deps, generalBody(), rejected.emit, new AbortController().signal);
  assert.deepEqual([doneOf(rejected).credits, doneOf(rejected).charged, doneOf(rejected).reason], [0, false, 'server']);
  assert.ok(names(rejected.calls).includes('worker_operation_outcome'), 'a conflict may mean another settlement exists: read it');
  // No acknowledgement after the retries: the recorded outcome is read back.
  for (const [state, credits, charged] of [['settled', 1, true], ['reserved', 0, false]] as const) {
    const unknown = harness({ script: { worker_settle_chat: () => { throw new Error('transport'); },
      worker_operation_outcome: () => ({ state, actual_credits: state === 'settled' ? 1 : null, charged: state === 'settled' ? true : null }) } });
    await runChat(unknown.deps, generalBody(), unknown.emit, new AbortController().signal);
    assert.equal(doneOf(unknown).credits, credits, state); assert.equal(doneOf(unknown).charged, charged, state);
    assert.equal(unknown.answers[0].settlement, 'unknown');
  }
  // A settled answer is unchanged (and its log line has no settlement field).
  const ok = harness();
  await runChat(ok.deps, generalBody(), ok.emit, new AbortController().signal);
  assert.equal(doneOf(ok).charged, true); assert.ok(!('settlement' in ok.answers[0]));
});

test('the server deadline aborts generation, charges nothing (our limit) and reports provider_unavailable', async () => {
  const h = harness({ generate: (_params, stream) => new Promise(resolve => stream.signal.addEventListener('abort', () => resolve({
    status: 'failed', failure: 'aborted', messageID: null, model: null, stopReason: null, refusalCategory: null, attempts: [], exact: true,
  }))) });
  h.deps.deadlineMs = 5;
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events, [{ event: 'error', data: { code: 'provider_unavailable', credits: 0, charged: false, reason: 'limit', retry_after: 10 } }]);
  assert.deepEqual(h.calls.find(c => c.name === 'worker_settle_chat')!.params, { p_account_id: account, p_id: operation, p_actual_credits: 0, p_actual_microusd: 0,
    p_action: 'answer', p_ending: 'limit', p_absorbed_microusd: 0 });
});

// The real OpenRouter adapter over a fake transport (its own tests: openrouter-chat.test.ts).
const attribution = { accountID: account, operationID: operation, attemptID: 'cccccccc-0000-4000-8000-0000000000aa', feature: 'chat', caller: 'chat',
  dispatch: async () => true };
function routerStream(events: Record<string, unknown>[]) {
  return () => new Response(events.map(event => `data: ${JSON.stringify(event)}\n\n`).join(''), { status: 200, headers: { 'content-type': 'text/event-stream' } });
}
const routerChat = (respond: () => Response) => openRouterChat({ apiKey: 'test-key', fetch: (async () => respond()) as typeof fetch, sleep: async () => {} });
const params = () => chatRequestParams({ instructions: chatInstructions('paper'), paper: { title: 'T', text: paperText },
  turns: [{ role: 'user', text: secretQuestion }], selection: null });

test('all prompt text and nested tool results use a conservative UTF-8 byte bound', async () => {
  // Three per byte, so the estimate is one token per byte (a 2–3× margin; see promptCharacters for the 2026-10-14 pause).
  const { promptCharacters } = await import('../../supabase/functions/_shared/inference.ts');
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
  let tools: unknown, round = 0;
  const h = harness({ generate: async (params, stream) => {
    tools = (params as { tools?: { name?: string }[] }).tools?.map(t => t.name);
    if (++round === 1) return searchRound([{ id: 's1', input: { query: 'multi-head attention variants', academic: true } }]);
    stream.onText('1. **A paper**'); return completeOutcome();
  } });
  searching(h, [found]);
  await runChat(h.deps, quoted, h.emit, new AbortController().signal);
  assert.ok((tools as string[]).includes('search_web'), 'our search tool; no provider-native search');
  // Reader: both rounds (3,000 + 4,800 reported by OpenRouter) and one Tavily credit at $0.008 = 15,800 -> 4 credits.
  assert.deepEqual(h.answers, [{ event: 'chat_answer', operation_id: operation, action: 'related', mode: 'paper', ending: 'completed', charged: true, credits: 4,
    web_search_offered: true, search_provider: 'tavily', web_searches: 1, tavily_searches: 1, search_failures: 0, sources: 1,
    profile: 'sonnet-low-standard', auto_effort: false, provider: 'openrouter', title: 'not_requested' }]);
  const usage = h.calls.filter(c => c.name === 'worker_record_provider_usage').map(c => c.params);
  assert.deepEqual(usage.map(u => u.p_provider), ['openrouter', 'tavily']);
  assert.equal((usage[0].p_units as { web_searches: number }).web_searches, 0, 'no provider-native searches');
});

test('consent: v1–v6 are read, every answer needs v5 or later (it names OpenRouter), and DeepSeek needs v6', async () => {
  const digests = new Set<string>();
  for (const version of ['cloud-ai-v1', 'cloud-ai-v2', 'cloud-ai-v3', 'cloud-ai-v4', 'cloud-ai-v5', 'cloud-ai-v6']) {
    assert.equal(validateChatRequest(paperBody({ consent_version: version })).consentVersion, version);
    digests.add(canonicalRequest(validateChatRequest(paperBody({ consent_version: version }))));
  }
  assert.equal(digests.size, 6, 'each version keeps its own request digest');
  assert.throws(() => validateChatRequest(paperBody({ consent_version: 'cloud-ai-v7' })), { code: 'invalid_request' });
  // Builds whose consent predates OpenRouter are told to update before anything is held or sent.
  for (const version of ['cloud-ai-v1', 'cloud-ai-v2', 'cloud-ai-v3', 'cloud-ai-v4']) {
    const h = harness();
    await runChat(h.deps, paperBody({ consent_version: version }), h.emit, new AbortController().signal);
    assert.deepEqual(h.events, [{ event: 'error', data: { code: 'consent_required' } }], version);
    assert.deepEqual(names(h.calls), ['worker_consume_request'], version); assert.equal(h.generations(), 0, version);
  }
  for (const version of ['cloud-ai-v5', 'cloud-ai-v6']) {
    const h = harness();
    await runChat(h.deps, paperBody({ consent_version: version }), h.emit, new AbortController().signal);
    assert.equal(h.events.at(-1)?.event, 'done', version);
  }
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
  assert.deepEqual(sent[0].tools?.map(t => t.name), ['create_diagram', 'create_visual', 'show_figure_parts', 'search_web'], 'our search_web tool (Tavily); no provider-native search');
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
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.equal(settle.p_actual_microusd, tokens);
  assert.equal(settle.p_actual_credits, creditsFor(tokens + 8_000));
  const usage = h.calls.filter(c => c.name === 'worker_record_provider_usage').map(c => c.params);
  assert.deepEqual(usage.map(u => u.p_provider), ['openrouter', 'tavily']);
  assert.equal(usage[0].p_provider_event_id, 'gen-round'); assert.equal(usage[0].p_microusd, tokens);
  assert.deepEqual(usage[1], { p_account_id: account, p_operation_id: operation, p_provider: 'tavily', p_provider_event_id: `operation:${operation}`,
    p_model: 'search-basic', p_microusd: 0, p_units: { searches: 1, credits: 1, failed: 0, list_microusd: 8_000 } });
  assert.deepEqual(h.answers, [{ event: 'chat_answer', operation_id: operation, action: 'related', mode: 'paper', ending: 'completed', charged: true, credits: 4,
    web_search_offered: true, search_provider: 'tavily', web_searches: 1, tavily_searches: 1, search_failures: 0, sources: 1,
    profile: 'sonnet-low-standard', auto_effort: false, provider: 'openrouter', title: 'not_requested' }]);
  assert.match(text, /Sources:\n1\. IPO — https:\/\/arxiv\.org\/abs\/2310\.12036/);
  noPlaintext(h.logs);
});

test('a paused or exhausted Tavily offers no search tool: the answer is written without search', async () => {
  {
    let tools: string[] = [];
    const h = harness({ generate: async (params, stream) => { tools = ((params as unknown as Sent).tools ?? []).map(t => t.name!); stream.onText('a'); return completeOutcome(); } });
    const runs = searching(h, [], false);
    await runChat(h.deps, v2(paperBody()), h.emit, new AbortController().signal);
    assert.deepEqual(tools, ['create_diagram', 'create_visual', 'show_figure_parts']); assert.equal(runs.length, 0);
    assert.equal(h.answers[0].search_provider, 'none'); assert.equal(h.answers[0].web_search_offered, false);
  }
  // Ingest never searches.
  let tools: string[] = [];
  const h = harness({ generate: async (params, stream) => { tools = ((params as unknown as Sent).tools ?? []).map(t => t.name!); stream.onText('a'); return completeOutcome(); } });
  searching(h, []);
  await runChat(h.deps, v2(paperBody({ selection: { quote: 'Rafailov et al. 2023' }, action: 'ingest' })), h.emit, new AbortController().signal);
  assert.deepEqual(tools, ['add_paper']);
});

test('a Tavily failure ends search for the rest of the answer, which continues without it; failed searches cost nothing', async () => {
  const sent: Sent[] = [];
  const h = harness({ generate: async (params, stream) => {
    sent.push(structuredClone(params) as unknown as Sent);
    if (sent.length === 1) return searchRound([{ id: 'toolu_s1', input: { query: 'follow-up work' } }]);
    stream.onText('Answered without search.'); return completeOutcome();
  } });
  searching(h, [{ status: 'failed', failure: 'limit', retryAfterMs: null }]);
  await runChat(h.deps, v2(paperBody()), h.emit, new AbortController().signal);
  const result = (sent[1].messages.at(-1)!.content as { is_error?: boolean; content: string }[])[0];
  assert.equal(result.is_error, true); assert.match(result.content, /Web search is unavailable right now\. Answer without it/);
  assert.deepEqual(sent[1].tools!.map(t => t.name), ['create_diagram', 'create_visual', 'show_figure_parts', 'search_web'],
    'search_web stays defined (the conversation uses it); no provider-native search appears');
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  const tokens = 900 * 2 + 120 * 10 + 900 * 2 + 300 * 10;
  assert.equal(settle.p_actual_microusd, tokens, 'provider spend is the two OpenRouter rounds');
  assert.equal(settle.p_actual_credits, creditsFor(tokens), 'the failed search is not charged');
  assert.deepEqual(h.logs.filter(l => l.event === 'chat_search_failed'), [{ event: 'chat_search_failed', operation_id: operation, provider: 'tavily', failure: 'limit' }]);
  assert.equal(h.answers[0].search_failures, 1); assert.equal(h.answers[0].web_searches, 0);
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
  const settle = failing.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.ok(Number(settle.p_actual_microusd) > 900 * 2 + 120 * 10, 'the first round and an estimate for the lost one');
  assert.equal(failing.events.at(-1)!.event, 'error');
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
  assert.deepEqual(sent!.tools?.map(t => t.name), ['create_diagram', 'create_visual', 'show_figure_parts']);
  assert.equal(runs.length, 0);
  // No search allowance in the hold either.
  const held = Number(h.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_microusd);
  assert.equal(held, holdForParams(sent as unknown as ModelRequest).microusd);
  assert.equal(h.answers[0].web_search_offered, false); assert.equal(h.answers[0].action, 'relevance');
  // Ordinary questions on the same paper still search.
  const plain = harness(); searching(plain, []);
  let plainTools: string[] = [];
  plain.deps.generate = async (params, stream) => { plainTools = ((params as unknown as Sent).tools ?? []).map(t => t.name ?? ''); stream.onText('x'); return completeOutcome(); };
  await runChat(plain.deps, paperBody(), plain.emit, new AbortController().signal);
  assert.ok(plainTools.includes('search_web'));
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
      attempts: [{ model: SONNET, estimated: false, billedMicrousd: 8_800, usage: { input: 1_400, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 600 } }],
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
  // Held like any answer (input at the write rate plus its whole output allowance)…
  const reserve = h.calls.find(c => c.name === 'worker_reserve_chat')!.params;
  const hold = holdForParams(sent as unknown as ModelRequest);
  assert.equal(sent!.max_tokens, DIAGRAM_FIX_MAX_TOKENS);
  assert.equal(reserve.p_microusd, hold.microusd); assert.equal(reserve.p_credits, hold.credits);
  assert.ok(hold.credits <= 25, `a repair holds at most 25 credits (${hold.credits})`);
  assert.ok(hold.credits < holdForParams(chatRequestParams({ instructions: chatInstructions('general'), paper: null,
    turns: [{ role: 'user', text: repairText }], selection: null, tools: [CREATE_DIAGRAM_TOOL] })).credits / 2, 'far below an answer’s hold');
  // …and settled at its actual cost: OpenRouter reported 8,800 µ$ → 2 credits.
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
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
      attempts: [{ model: SONNET, estimated: false, usage: { input: 1_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: DIAGRAM_FIX_MAX_TOKENS } }] });
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
  assert.deepEqual(limited.events, [{ event: 'error', data: { code: 'rate_limited', retry_after: 60 } }]);
});

test('the paper is cached with the shared instructions; a selection action\'s own instructions follow it', () => {
  const turns = [{ role: 'user' as const, text: 'q' }];
  const paper = { title: 'T', text: paperText };
  const request = (action: 'related' | 'relevance' | null, search: boolean, tools = [CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL]) => {
    const parts = chatInstructionParts('paper', action, search);
    return chatRequestParams({ instructions: parts.shared, actionInstructions: parts.action, paper, turns, selection: 'DPO', tools });
  };
  const plain = request(null, true), related = request('related', true);
  const system = (params: ReturnType<typeof request>) => params.system as { text: string; cache_control?: unknown }[];
  assert.deepEqual(system(related).slice(0, 2), system(plain).slice(0, 2), 'a question and Related share the cached prefix');
  assert.deepEqual(system(related)[1].cache_control, { type: 'ephemeral', ttl: '1h' });
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
  assert.deepEqual(table.models.map(m => [m.id, m.api_model, m.provider]), [['haiku', HAIKU, 'openrouter'], ['sonnet', SONNET, 'openrouter'], ['opus', OPUS, 'openrouter']]);
  // 2026-10-16: `auto` follows the three efforts, and its profiles follow the 27 explicit ones (tests/backend/chat-profiles.test.ts).
  assert.deepEqual(table.efforts.map(e => e.id), ['low', 'medium', 'high', 'auto']);
  assert.deepEqual(table.lengths.map(l => l.id), ['brief', 'standard', 'detailed']);
  const explicit = table.profiles.filter(p => p.effort !== 'auto');
  assert.equal(explicit.length, 27); assert.deepEqual(table.profiles.slice(0, 27), explicit);
  assert.equal(new Set(table.profiles.map(p => p.id)).size, table.profiles.length);
  const byID = new Map(explicit.map(p => [p.id, p]));
  assert.equal(byID.get('sonnet-low-standard')!.max_output_tokens, CHAT_MAX_TOKENS);
  // Output allowances: the length's answer plus the effort's thinking (max_tokens covers both).
  assert.deepEqual(['brief', 'standard', 'detailed'].map(l => ['low', 'medium', 'high'].map(e => byID.get(`sonnet-${e}-${l}`)!.max_output_tokens)),
    [[3_000, 5_000, 9_000], [8_000, 10_000, 14_000], [12_000, 14_000, 18_000]]);
  for (const p of explicit) {
    assert.ok(p.credits.low <= p.credits.high && p.credits.high <= p.credits.max, `${p.id} estimate is ordered`);
    assert.equal(p.max_output_tokens, byID.get(`sonnet-${p.effort}-${p.length}`)!.max_output_tokens, 'allowances do not depend on the model');
  }
  // Models order by cost at every effort and length.
  for (const e of ['low', 'medium', 'high']) for (const l of ['brief', 'standard', 'detailed']) {
    const [h, s, o] = ['haiku', 'sonnet', 'opus'].map(m => byID.get(`${m}-${e}-${l}`)!.credits);
    assert.ok(h.max < s.max && s.max < o.max && h.high < s.high && s.high < o.high, `${e}/${l} orders by model`);
  }
  // Documented examples (CHAT.md): the default, and the two extremes, at the OpenRouter Vertex cards.
  assert.deepEqual(byID.get('sonnet-low-standard')!.credits, { low: 5, high: 26, max: 41 });
  assert.deepEqual(byID.get('haiku-low-brief')!.credits, { low: 1, high: 2, max: 2 });
  assert.deepEqual(byID.get('opus-high-detailed')!.credits, { low: 27, high: 69, max: 126 });
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
  const sent: ModelRequest[] = [];
  const run = async (profile: Record<string, string>) => {
    const h = harness({ generate: async (params, stream) => { sent.push(params); stream.onText('ok'); return completeOutcome({ model: params.model }); } });
    await runChat(h.deps, paperBody({ profile }), h.emit, new AbortController().signal);
    return h;
  };
  const haiku = await run({ model: 'haiku', effort: 'medium', length: 'brief' });
  const opus = await run({ model: 'opus', effort: 'high', length: 'detailed' });
  await run({ model: 'sonnet', effort: 'low', length: 'standard' });
  assert.equal(sent[0].model, HAIKU); assert.deepEqual(sent[0].output_config, { effort: 'medium' });
  assert.deepEqual(sent[0].thinking, { type: 'adaptive' }); assert.equal(sent[0].max_tokens, 5_000);
  for (const request of sent) assert.equal((request as Record<string, unknown>).fallbacks, undefined, 'no provider-side fallback on OpenRouter');
  assert.equal(sent[1].model, OPUS); assert.deepEqual(sent[1].output_config, { effort: 'high' });
  assert.equal(sent[1].max_tokens, 18_000);
  assert.equal(sent[2].model, SONNET); assert.equal(sent[2].max_tokens, 8_000);
  const system = sent.map(params => params.system as TextBlock[]);
  // Standard adds nothing (today's prompt); brief and detailed add their instructions after the cached paper.
  assert.equal(system[2].length, 2);
  assert.match(system[0][2].text, /brief answers/); assert.match(system[1][2].text, /detailed answers/);
  for (const blocks of system) {
    assert.equal(blocks[0].text, system[2][0].text, 'shared instructions do not change with the profile');
    assert.equal(blocks[1].text, system[2][1].text); assert.deepEqual(blocks[1].cache_control, { type: 'ephemeral', ttl: '1h' });
  }
  // The answer reports which model and profile answered.
  assert.deepEqual(haiku.events.at(-1)?.data, { stop_reason: 'end_turn', credits: 1,
    usage: { input_tokens: 900, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 300 },
    model: 'claude-haiku-5-5', profile: 'haiku-medium-brief', charged: true });
  const quote = opus.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as Record<string, unknown>;
  assert.deepEqual([quote.profile, quote.model, quote.effort, quote.length, quote.max_output_tokens, quote.tariff],
    ['opus-high-detailed', OPUS, 'high', 'detailed', 18_000, 'openrouter-claude-vertex-us-20261017']);
});

test('holds use the chosen model\'s OpenRouter card, one attempt (no server-side fallback); Haiku at its prompt tier', () => {
  // 100,000 estimated tokens and 8,000 output tokens, at the five-minute write rate and the output rate.
  const at = (model: string, input: number, prompt = input) => { const r = routerClaudeRates(model, prompt); return Math.ceil(input * r.cacheWrite5m + 8_000 * r.output); };
  assert.equal(holdFor(300_000, 8_000, OPUS).microusd, at(OPUS, 100_000));
  assert.equal(holdFor(300_000, 8_000, OPUS).microusd, 726_000, '$5.50 write and $22 output per million');
  assert.equal(holdFor(300_000, 8_000, HAIKU).microusd, at(HAIKU, 100_000));
  assert.equal(holdFor(300_003, 8_000, HAIKU).microusd, at(HAIKU, 100_001), 'over 100,000 prompt tokens: the long-prompt card');
  assert.equal(holdFor(300_000, 8_000, SONNET).microusd, at(SONNET, 100_000));
  assert.equal(holdFor(300_000, 8_000, 'claude-mystery').microusd, (100_000 * 6.25 + 8_000 * 25) * 3, 'no card: the ceiling card, three attempts');
  const flash = routerDeepSeekRates(FLASH);
  assert.equal(holdFor(300_000, 8_000, FLASH).microusd, Math.ceil((100_000 * flash.cacheWrite5m + 8_000 * flash.output) * 2), 'DeepSeek: two attempts');
  // Search holds follow the model too (Haiku's later rounds may cross into the long-prompt tier).
  const search = (prompt: number, uses: number) => { const r = routerClaudeRates(HAIKU, prompt + uses * 30_000);
    return Math.ceil(uses * (10_000 + prompt * r.cacheWrite5m + 60_000 * r.input)); };
  assert.equal(webSearchHoldMicrousd(10_000, 3, SONNET), webSearchHoldMicrousd(10_000, 3));
  assert.equal(webSearchHoldMicrousd(10_000, 3, HAIKU), search(10_000, 3));
  assert.equal(webSearchHoldMicrousd(10_001, 3, HAIKU), search(10_001, 3));
  assert.ok(search(10_001, 3) > search(10_000, 3) * 2, 'the long-prompt tier');
  assert.equal(webSearchHoldMicrousd(1_000, 1, HAIKU), search(1_000, 1));
});

// The title, suggestion and map requests are Haiku 5.5 through OpenRouter; their fixtures carry OpenRouter's reported cost.
function titleOutcome(changes: Partial<ProviderOutcome> = {}): ProviderOutcome {
  return completeOutcome({ messageID: 'gen-title', model: HAIKU,
    attempts: [{ model: HAIKU, estimated: false, billedMicrousd: 44, usage: { input: 400, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 8 } }], ...changes });
}

test('every admitted request fits the operation hold: the answer\'s first round plus the title', async () => {
  const ceilings: number[] = [];
  let reserved = 0;
  const h = harness({ script: { worker_reserve_chat: params => { reserved = Number(params.p_microusd); return { replayed: false }; } },
    generate: async (params, stream) => {
      ceilings.push(holdForParams(params).microusd);
      if (params.model === HAIKU && params.max_tokens === 40) { stream.onText('Scaled attention'); return titleOutcome(); }
      stream.onText('An answer.'); return completeOutcome({ model: params.model });
    } });
  await runChat(h.deps, paperBody({ topic_title: true, profile: { model: 'opus', effort: 'medium', length: 'standard' } }), h.emit, new AbortController().signal);
  assert.equal(ceilings.length, 2);
  assert.equal(ceilings.reduce((a, b) => a + b, 0), reserved, 'the hold is exactly the sum of the admitted ceilings');
  const quote = h.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as Record<string, unknown>;
  assert.equal(quote.title_model, HAIKU); assert.equal(quote.title_max_tokens, 40);
  assert.equal(quote.title_ceiling_microusd, Math.min(...ceilings));
});

test('a topic title is written alongside the answer with Haiku 5.5, sent before done, charged, and never logged', async () => {
  const sent: ModelRequest[] = [];
  const h = harness({ generate: async (params, stream) => {
    sent.push(params);
    if (params.model === HAIKU) { assert.equal(stream.purpose, 'topic_title'); stream.onText('"Attention scaling '); stream.onText('explained."\n'); return titleOutcome(); }
    stream.onText('Scaling keeps logits bounded.'); return completeOutcome();
  } });
  await runChat(h.deps, paperBody({ topic_title: true, selection: { quote: 'divide by sqrt(d_k)' } }), h.emit, new AbortController().signal);
  const title = sent.find(params => params.model === HAIKU)!;
  assert.equal(title.max_tokens, 40); assert.deepEqual(title.thinking, { type: 'disabled' });
  assert.equal(title.tools, undefined); assert.equal((title as Record<string, unknown>).fallbacks, undefined);
  const input = JSON.stringify(title.messages);
  assert.match(input, /<paper_title>Attention<\/paper_title>/); assert.match(input, /private-question-marker/); assert.match(input, /sqrt\(d_k\)/);
  assert.ok(!input.includes('We scale by'), 'the title never reads the paper text');
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'title', 'done']);
  assert.deepEqual(h.events[1].data, { text: 'Attention scaling explained' });
  // OpenRouter's reported costs: the answer (Sonnet 5.5) 4,800 and the title (Haiku 5.5) 44 micro-USD.
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.equal(settle.p_actual_microusd, 4_844); assert.equal(settle.p_actual_credits, 1);
  const usage = h.calls.find(c => c.name === 'worker_record_provider_usage')!.params;
  assert.equal(usage.p_provider, 'openrouter'); assert.equal(usage.p_provider_event_id, 'gen-01'); assert.equal(usage.p_model, SONNET);
  assert.deepEqual((usage.p_units as { attempts: { model: string }[] }).attempts.map(a => a.model), [SONNET, HAIKU]);
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
      if (params.model === HAIKU) return write(stream);
      stream.onText('Answer.'); return completeOutcome();
    } });
    await runChat(h.deps, generalBody({ topic_title: true }), h.emit, new AbortController().signal);
    assert.deepEqual(h.events.map(e => e.event), ['delta', 'done'], label);
    assert.equal(h.answers[0].title, logged, label);
  }
  // A refused answer gets no title (its title request is still settled).
  const refused = harness({ generate: async (params, stream) => {
    if (params.model === HAIKU) { stream.onText('Some title'); return titleOutcome(); }
    return completeOutcome({ stopReason: 'refusal' });
  } });
  await runChat(refused.deps, generalBody({ topic_title: true }), refused.emit, new AbortController().signal);
  assert.deepEqual(refused.events, [{ event: 'error', data: { code: 'refused', credits: 0, charged: false, reason: 'refusal' } }]);
  assert.equal(refused.calls.filter(c => c.name === 'worker_settle_chat').length, 1);
  assert.equal(Number(refused.calls.find(c => c.name === 'worker_settle_chat')!.params.p_actual_microusd), 4_844);
});

test('a slow title is abandoned shortly after the answer and its attempt is still settled', async () => {
  let titleSignal: AbortSignal | undefined;
  const h = harness({ generate: async (params, stream) => {
    if (params.model !== HAIKU) { stream.onText('Answer.'); return completeOutcome(); }
    titleSignal = stream.signal;
    await new Promise<void>(resolve => stream.signal.addEventListener('abort', () => resolve(), { once: true }));
    return titleOutcome({ status: 'failed', failure: 'aborted', stopReason: null, exact: false,
      attempts: [{ model: HAIKU, estimated: true, usage: { input: 400, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0 } }] });
  } });
  const started = Date.now();
  await runChat(h.deps, generalBody({ topic_title: true }), h.emit, new AbortController().signal);
  assert.ok(titleSignal?.aborted);
  assert.ok(Date.now() - started < 6_000);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'done']);
  // The answer's reported 4,800 and the abandoned title's estimate (400 input at Haiku's $0.11 per million).
  assert.equal(h.calls.find(c => c.name === 'worker_settle_chat')!.params.p_actual_microusd, Math.ceil(4_800 + 400 * routerClaudeRates(HAIKU).input));
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

const localContext = { format: 'reader-local-context-v1', membership_id: documentID, source: 'arxiv', source_id: '2305.18290',
  revision: 3, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: 'device-only-context-marker x^2' };
test('local reader context is bounded, mutually exclusive with server documents, and bound into replay digest', () => {
  const body = paperBody({ document_id: null, local_context: localContext });
  const parsed = validateChatRequest(body);
  assert.equal(parsed.documentID, null); assert.equal(parsed.localContext?.text, localContext.text);
  for (const change of [{ mode: 'general' }, { document_id: documentID }, { local_context: { ...localContext, revision: 0 } },
    { local_context: { ...localContext, text: 'x'.repeat(2*1024*1024+1) } }, { local_context: { ...localContext, pdf: 'bad' } }])
    assert.throws(() => validateChatRequest({ ...body, ...change }));
  assert.notEqual(canonicalRequest(parsed), canonicalRequest(validateChatRequest({ ...body, local_context: { ...localContext, text: 'changed' } })));
});
test('local-context paper chat authorizes membership before metering and never loads server paper bytes', async () => {
  const h = harness({ script: { worker_local_chat_context: p => {
    assert.equal(p.p_membership_id, documentID); assert.equal(p.p_revision, 3); return {title:'Local HTML paper'};
  } } });
  h.deps.loadPaper = async () => { throw Error('must not fetch a server paper'); };
  await runChat(h.deps, paperBody({ document_id: null, local_context: localContext }), h.emit, new AbortController().signal);
  assert.equal(h.generations(), 1);
  assert.deepEqual(names(h.calls), ['worker_consume_request','worker_local_chat_context','worker_reserve_chat','worker_settle_chat','worker_record_provider_usage']);
  assert.ok(!JSON.stringify([...h.calls,...h.logs,...h.answers]).includes(localContext.text));
});
test('another account or revision cannot use local context to bypass library authority', async () => {
  const h = harness({ script: { worker_local_chat_context: () => {throw new RpcFailure('document_unavailable');} } });
  await runChat(h.deps, paperBody({ document_id: null, local_context: localContext }), h.emit, new AbortController().signal);
  assert.equal(h.generations(), 0); assert.ok(!names(h.calls).includes('worker_reserve_chat'));
});

function followUpOutcome(questions: string[], changes: Partial<ProviderOutcome> = {}): ProviderOutcome {
  return completeOutcome({ messageID: 'msg_follow', model: HAIKU, stopReason: 'tool_use',
    toolCalls: [{ name: 'suggest_follow_ups', input: { questions } }],
    attempts: [{ model: HAIKU, estimated: false, billedMicrousd: 80, usage: { input: 500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 60 } }], ...changes });
}

test('follow-ups are a forced Haiku 5.5 request after the answer: relayed once before done, cleaned and bounded, charged, never logged as text', async () => {
  const sent: ModelRequest[] = [];
  let answered = 0;
  const h = harness({ generate: async (params, stream) => {
    sent.push(params);
    if (params.model === HAIKU) {
      assert.equal(answered, 1, 'the suggestion request waits for the answer');
      return followUpOutcome([' How does β\tscale? ', 'how does β scale?', 'x', 'Why is the reference model frozen?', 'What breaks without the KL term?', 'A fourth question']);
    }
    stream.onText('The answer '); stream.onText('in two parts.'); answered++;
    return completeOutcome();
  } });
  await runChat(h.deps, paperBody({ follow_ups: true, selection: { quote: 'divide by sqrt(d_k)' } }), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'delta', 'followups', 'done']);
  assert.deepEqual(h.events[2].data, { questions: ['How does β scale?', 'Why is the reference model frozen?', 'What breaks without the KL term?'] });
  assert.equal((h.events[3].data as { stop_reason: string }).stop_reason, 'end_turn');
  const suggestion = sent.find(params => params.model === HAIKU)!;
  assert.equal(suggestion.max_tokens, FOLLOW_UP_MAX_TOKENS); assert.deepEqual(suggestion.thinking, { type: 'disabled' });
  assert.deepEqual(suggestion.tools, [SUGGEST_FOLLOW_UPS_TOOL]); assert.deepEqual(suggestion.tool_choice, { type: 'tool', name: 'suggest_follow_ups' });
  const input = JSON.stringify(suggestion.messages);
  assert.match(input, /<paper_title>Attention<\/paper_title>/); assert.match(input, /private-question-marker/); assert.match(input, /sqrt\(d_k\)/);
  assert.match(input, /<answer>The answer in two parts\.<\/answer>/);
  assert.ok(!input.includes('We scale by'), 'the suggestion never reads the paper text');
  // Charged with the answer: 900 input + 300 output (Sonnet) + 500 input + 60 output (Haiku 5.5).
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.equal(Number(settle.p_actual_microusd), priceAttempts([...completeOutcome().attempts, ...followUpOutcome(['a?', 'b?']).attempts]));
  assert.deepEqual((h.events[3].data as { usage: Record<string, number> }).usage, { input_tokens: 1400, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 360 });
  // Logged as counts only.
  const answer = h.answers[0];
  assert.equal(answer.follow_ups, 'written'); assert.equal(answer.follow_up_count, 3);
  assert.ok(!JSON.stringify(h.logs).includes('reference model'), 'questions are never logged');
});

test('follow-ups are held with the answer, only when asked for, and never for Ingest, repairs, refusals or empty answers', async () => {
  // Not asked for: one request, no event, no extra hold.
  const plain = harness();
  await runChat(plain.deps, paperBody(), plain.emit, new AbortController().signal);
  assert.equal(plain.generations(), 1); assert.ok(!plain.events.some(e => e.event === 'followups'));
  const plainQuote = plain.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as Record<string, unknown>;
  assert.ok(!('follow_ups_model' in plainQuote)); assert.equal(plain.answers[0].follow_ups, undefined);
  // Asked for: the hold is the answer's ceiling plus the suggestion's largest request, frozen in the quote.
  let reserved = 0; const ceilings: number[] = [];
  const held = harness({ script: { worker_reserve_chat: params => { reserved = Number(params.p_microusd); return { replayed: false }; } },
    generate: async (params, stream) => {
      ceilings.push(holdForParams(params).microusd);
      if (params.model === HAIKU) return followUpOutcome(['One?', 'Two?']);
      stream.onText('An answer.'); return completeOutcome();
    } });
  await runChat(held.deps, paperBody({ follow_ups: true }), held.emit, new AbortController().signal);
  const suggestionCeiling = holdForParams(FOLLOW_UP_HOLD_PARAMS).microusd;
  assert.equal(FOLLOW_UP_HOLD_PARAMS.max_tokens, FOLLOW_UP_MAX_TOKENS); assert.equal(FOLLOW_UP_HOLD_PARAMS.model, HAIKU);
  assert.equal(ceilings.length, 2);
  assert.equal(ceilings[0] + suggestionCeiling, reserved, 'the hold is the answer ceiling plus the suggestion ceiling');
  assert.ok(ceilings[1] <= suggestionCeiling, 'the real suggestion request never exceeds its held ceiling');
  const quote = held.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as Record<string, unknown>;
  assert.equal(quote.follow_ups_model, HAIKU); assert.equal(quote.follow_ups_max_tokens, FOLLOW_UP_MAX_TOKENS); assert.equal(quote.follow_ups_ceiling_microusd, suggestionCeiling);
  // Unusable input: no event, the answer completes, the outcome is counted.
  const invalid = harness({ generate: async (params, stream) => {
    if (params.model === HAIKU) return followUpOutcome(['', 'ab']);
    stream.onText('x'); return completeOutcome(); } });
  await runChat(invalid.deps, paperBody({ follow_ups: true }), invalid.emit, new AbortController().signal);
  assert.deepEqual(invalid.events.map(e => e.event), ['delta', 'done']);
  assert.equal(invalid.answers[0].follow_ups, 'unusable');
  // A failed suggestion request is settled (estimated) and the answer still completes.
  const failed = harness({ generate: async (params, stream) => {
    if (params.model === HAIKU) throw new Error('provider down');
    stream.onText('x'); return completeOutcome(); } });
  await runChat(failed.deps, paperBody({ follow_ups: true }), failed.emit, new AbortController().signal);
  assert.deepEqual(failed.events.map(e => e.event), ['delta', 'done']);
  assert.equal(failed.answers[0].follow_ups, 'failed');
  assert.ok(Number(failed.calls.find(c => c.name === 'worker_settle_chat')!.params.p_actual_microusd) > priceAttempts(completeOutcome().attempts));
  // A slow suggestion is abandoned after its bound; the answer still completes.
  const slow = harness({ generate: async (params, stream) => {
    if (params.model === HAIKU) { await new Promise(resolve => stream.signal.addEventListener('abort', resolve, { once: true })); return followUpOutcome([], { status: 'failed', failure: 'aborted', stopReason: null }); }
    stream.onText('x'); return completeOutcome(); } });
  slow.deps.followUpTimeoutMs = 20;
  await runChat(slow.deps, paperBody({ follow_ups: true }), slow.emit, new AbortController().signal);
  assert.deepEqual(slow.events.map(e => e.event), ['delta', 'done']);
  // A refused answer makes no suggestion request.
  const refused = harness({ generate: async () => completeOutcome({ stopReason: 'refusal' }) });
  await runChat(refused.deps, paperBody({ follow_ups: true }), refused.emit, new AbortController().signal);
  assert.equal(refused.generations(), 1); assert.deepEqual(refused.events, [{ event: 'error', data: { code: 'refused', credits: 0, charged: false, reason: 'refusal' } }]);
  // Ingest and repairs refuse the flag outright.
  for (const body of [ingestBody(), { operation_id: operation, consent_version: 'cloud-ai-v2', mode: 'general', action: 'diagram_fix', messages: [{ role: 'user', text: 'Title: x' }] }]) {
    assert.throws(() => validateChatRequest({ ...body, follow_ups: true }), { code: 'invalid_request' });
  }
  assert.throws(() => validateChatRequest(paperBody({ follow_ups: 'yes' })), { code: 'invalid_request' });
  // The flag is part of the request digest; the answer's own tools no longer include a suggestion tool.
  assert.notEqual(canonicalRequest(validateChatRequest(paperBody({ follow_ups: true }))), canonicalRequest(validateChatRequest(paperBody())));
  assert.equal(canonicalRequest(validateChatRequest(paperBody({ follow_ups: false }))), canonicalRequest(validateChatRequest(paperBody())));
  assert.doesNotMatch(chatInstructions('paper'), /suggest_follow_ups/);
  assert.equal(sseFrame({ event: 'followups', data: { questions: ['A?'] } }), 'event: followups\ndata: {"questions":["A?"]}\n\n');
});

test('follow-up input is validated strictly: shape, length, duplicates and control characters', () => {
  assert.equal(followUpRequest(null), null); assert.equal(followUpRequest({ questions: 'x' }), null); assert.equal(followUpRequest({ questions: [] }), null);
  assert.equal(followUpRequest({ questions: [1, true, 'ab'] }), null);
  assert.deepEqual(followUpRequest({ questions: ['a'.repeat(121), 'Valid question?'] }), ['Valid question?']);
  assert.deepEqual(followUpRequest({ questions: ['Same?', 'same?', 'Other?'] }), ['Same?', 'Other?']);
  assert.deepEqual(followUpRequest({ questions: ['One?', 'Two?', 'Three?', 'Four?'] }), ['One?', 'Two?', 'Three?']);
  assert.deepEqual(followUpRequest({ questions: ['Line\u0000one\u0007?'] }), ['Line one ?']);
  // The request reads bounded excerpts only, with the tool call forced.
  const params = followUpRequestParams({ paperTitle: 'T'.repeat(400), selection: null, question: 'Q'.repeat(2_000), answer: 'A'.repeat(5_000) });
  const text = (params.messages[0].content as string);
  assert.ok(text.length < 4_200, `bounded excerpts (${text.length})`); assert.ok(!text.includes('<selected_passage>'));
  assert.match(text, /<paper_title>T{300}…<\/paper_title>/);
  assert.equal(params.tool_choice?.type, 'tool');
});

test('a numbered local context (v2) asks for grounded citations; v1 and server-held papers do not', async () => {
  const v2 = { ...localContext, format: 'reader-local-context-v2', text: '[¶1] # Title\n\n[¶2] A paragraph.\n\n[¶3] \\[x^2\\]' };
  assert.equal(validateChatRequest(paperBody({ document_id: null, local_context: v2 })).localContext?.format, 'reader-local-context-v2');
  assert.throws(() => validateChatRequest(paperBody({ document_id: null, local_context: { ...v2, format: 'reader-local-context-v3' } })), { code: 'invalid_request' });
  assert.notEqual(canonicalRequest(validateChatRequest(paperBody({ document_id: null, local_context: v2 }))),
    canonicalRequest(validateChatRequest(paperBody({ document_id: null, local_context: { ...v2, format: 'reader-local-context-v1' } }))));
  const systems: string[] = [];
  const run = async (body: unknown) => {
    const h = harness({ script: { worker_local_chat_context: () => ({ title: 'Local' }) }, generate: async (params, stream) => {
      systems.push((params.system as TextBlock[])[0].text); stream.onText('Cited [¶2].'); return completeOutcome(); } });
    await runChat(h.deps, body, h.emit, new AbortController().signal);
    assert.equal(h.events.at(-1)?.event, 'done');
  };
  await run(paperBody({ document_id: null, local_context: v2 }));
  await run(paperBody({ document_id: null, local_context: localContext }));
  await run(paperBody());
  assert.match(systems[0], /numbered: each paragraph, heading, equation, figure caption and table starts with a marker such as \[¶12\]/);
  assert.doesNotMatch(systems[1], /\[¶12\]/); assert.doesNotMatch(systems[2], /\[¶12\]/);
  // The citation instructions precede the tools block and never reach general chat.
  assert.ok(systems[0].indexOf('[¶12]') < systems[0].indexOf('create_diagram'));
  assert.doesNotMatch(chatInstructions('general', null, false, { citations: true }), /\[¶12\]/);
});

// Study (chat-study.ts): a tutored turn carries the reader's knowledge map; a forced Haiku request updates it after the answer.
const studyContext = { ...localContext, format: 'reader-local-context-v2' };
const studyBody = (overrides: Record<string, unknown> = {}) => paperBody({ document_id: null, local_context: studyContext, action: 'study', study: EMPTY_STUDY_MAP,
  messages: [{ role: 'user', text: 'Start studying this paper.' }], ...overrides });
const sampleMap = { concepts: [{ id: 'scaling', label: 'Scaled dot-product attention', state: 'learning', paragraphs: [3, 4], note: 'Confuses d_k with d_model' },
  { id: 'softmax', label: 'Softmax saturation', state: 'unknown', paragraphs: [4] }],
  links: [{ from: 'softmax', to: 'scaling', kind: 'prerequisite' }], focus: 'scaling', journey: ['scaling', 'softmax', 'scaling'], next: 'verify' };
const studyHarness = (options: Parameters<typeof harness>[0] = {}) =>
  harness({ ...options, script: { worker_local_chat_context: () => ({ title: 'Attention' }), ...options.script } });
function studyOutcome(map: unknown, changes: Partial<ProviderOutcome> = {}): ProviderOutcome {
  return completeOutcome({ messageID: 'msg_study', model: HAIKU, stopReason: 'tool_use',
    toolCalls: [{ name: 'update_study_map', input: map }],
    attempts: [{ model: HAIKU, estimated: false, billedMicrousd: 170, usage: { input: 700, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 200 } }], ...changes });
}

test('a Study turn is a paper action on numbered local context that carries a validated map and no follow-ups', () => {
  const parsed = validateChatRequest(studyBody({ study: sampleMap }));
  assert.equal(parsed.action, 'study'); assert.deepEqual(parsed.study, sampleMap); assert.equal(parsed.selection, null);
  // The map is part of the digest: the same question over a different map is a different request.
  assert.notEqual(canonicalRequest(parsed), canonicalRequest(validateChatRequest(studyBody())));
  assert.match(canonicalRequest(parsed), /"study":\{"concepts"/);
  for (const [label, change] of Object.entries({
    'no map': { study: undefined }, 'null map': { study: null }, 'map without links': { study: { concepts: [] } },
    'unknown state': { study: { ...sampleMap, concepts: [{ ...sampleMap.concepts[0], state: 'mastered' }] } },
    'too many concepts': { study: { ...sampleMap, concepts: Array.from({ length: 61 }, (_, i) => ({ id: `c${i}`, label: 'c', state: 'known', paragraphs: [] })) } },
    'general mode': { mode: 'general', local_context: undefined },
    'server document': { document_id: documentID, local_context: undefined },
    'unnumbered context (v1)': { local_context: localContext },
    'follow-ups beside the tutor': { follow_ups: true },
  })) assert.throws(() => validateChatRequest(studyBody(change as Record<string, unknown>)), { code: 'invalid_request' }, label);
  // Only Study carries a map.
  assert.throws(() => validateChatRequest(paperBody({ study: EMPTY_STUDY_MAP })), { code: 'invalid_request' });
  // A selection may start the study on a passage; it is not required.
  assert.equal(validateChatRequest(studyBody({ selection: { quote: 'divide by sqrt(d_k)' } })).selection, 'divide by sqrt(d_k)');
});

test('the map validator survives one careless element: bad links, journey entries and self links are dropped, long text is cut, ids are slugged', () => {
  const cleaned = studyMap({ ...sampleMap, concepts: [{ id: 'scaling', label: ' Scaled\u0000 dot-product ', state: 'known', paragraphs: [4, 3, 3, 0, 1e9], note: '' },
    { id: 'softmax', label: 'Softmax', state: 'unknown', paragraphs: [] }], links: [...sampleMap.links, ...sampleMap.links, { from: 'softmax', to: 'softmax', kind: 'related' }], focus: null, next: 'sideways' })!;
  assert.deepEqual(cleaned.concepts[0], { id: 'scaling', label: 'Scaled dot-product', state: 'known', paragraphs: [3, 4] });
  assert.equal(cleaned.links.length, 1, 'duplicate links collapse and a self link is dropped'); assert.equal(cleaned.focus, null); assert.equal(cleaned.next, 'calibrate', 'an unknown next step calibrates');
  assert.equal(studyMap({ ...sampleMap, concepts: [...sampleMap.concepts, { id: 'scaling', label: 'dup', state: 'known', paragraphs: [] }] })!.concepts.length, 2, 'a duplicate id keeps the first');
  // A model's id in label form is slugged, and links and the journey written with that form still resolve.
  const slugged = studyMap({ concepts: [{ id: 'Reference Model', label: 'Reference model', state: 'learning', paragraphs: [] }, { id: 'kl', label: 'KL penalty', state: 'unknown', paragraphs: [] }],
    links: [{ from: 'Reference Model', to: 'kl', kind: 'related' }, { from: 'kl', to: 'ghost', kind: 'deeper' }], focus: 'Reference Model', journey: ['kl', 'ghost', 'Reference Model'], next: 'teach' })!;
  assert.deepEqual(slugged.concepts.map(c => c.id), ['reference-model', 'kl']); assert.deepEqual(slugged.links, [{ from: 'reference-model', to: 'kl', kind: 'related' }]);
  assert.equal(slugged.focus, 'reference-model'); assert.deepEqual(slugged.journey, ['kl', 'reference-model']);
  assert.equal(studyMap({ ...sampleMap, concepts: [{ id: '---', label: 'x', state: 'known', paragraphs: [] }], links: [], journey: [], focus: null }), null, 'no usable id is fatal');
  assert.equal(studyMap({ ...sampleMap, focus: 'ghost' })!.focus, null, 'a focus off the map is dropped, not fatal');
  const long = studyMap({ ...sampleMap, concepts: [{ ...sampleMap.concepts[0], label: 'L'.repeat(100), note: 'n'.repeat(200) }, sampleMap.concepts[1]] })!;
  assert.equal([...long.concepts[0].label].length, 80); assert.ok(long.concepts[0].label.endsWith('…')); assert.equal([...long.concepts[0].note!].length, 160);
  assert.deepEqual(studyMap(EMPTY_STUDY_MAP), EMPTY_STUDY_MAP);
  // The model's largest possible map fits the request the hold is sized for.
  assert.ok(promptCharacters(STUDY_HOLD_PARAMS) > 16_000);
});

test('Study: the tutor sees the map after the paper, the map request runs after the answer and is relayed once before done', async () => {
  const sent: ModelRequest[] = [];
  let answered = 0;
  const h = studyHarness({ generate: async (params, stream) => {
    sent.push(params);
    if (params.model === HAIKU) { assert.equal(answered, 1, 'the map request waits for the answer'); return studyOutcome({ ...sampleMap, journey: ['scaling', 'softmax', 'scaling', 'scaling'] }); }
    stream.onText('Partly right. '); stream.onText('**What does dividing by √d_k keep small?**'); answered++;
    return completeOutcome();
  } });
  await runChat(h.deps, studyBody({ study: sampleMap, messages: [{ role: 'user', text: 'Start studying this paper.' }, { role: 'assistant', text: '**What is d_k?**' },
    { role: 'user', text: 'The key dimension, I think (reader-answer-marker)' }] }), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'delta', 'study', 'done']);
  assert.deepEqual(h.events[2].data, { map: { ...sampleMap, journey: ['scaling', 'softmax', 'scaling', 'scaling'] } });
  // The answer's prompt: the tutor protocol and the map follow the paper (cached), no length instructions, no search.
  const answer = sent[0];
  const system = (answer.system as { text: string }[]).map(block => block.text).join('\n');
  assert.match(system, /one step per turn/); assert.match(system, /<study_map>\{"concepts":\[\{"id":"scaling"/);
  assert.ok(system.indexOf('device-only-context-marker') < system.indexOf('<study_map>'), 'the map follows the paper');
  assert.ok(!/Length:|Answer length/i.test(system.slice(system.indexOf('<study_map>'))), 'no profile length after the map');
  assert.deepEqual(answer.tools?.map(t => t.name), ['create_diagram', 'create_visual', 'show_figure_parts']);
  // The map request: previous map, the reader's answer, the tutor's reply; never the paper.
  const update = sent[1];
  assert.equal(update.max_tokens, STUDY_MAX_TOKENS); assert.deepEqual(update.tools, [UPDATE_STUDY_MAP_TOOL]); assert.deepEqual(update.tool_choice, { type: 'tool', name: 'update_study_map' });
  const input = JSON.stringify(update.messages);
  assert.match(input, /<study_map>/); assert.match(input, /reader-answer-marker/); assert.match(input, /<tutor_reply>Partly right\. \*\*What does dividing/);
  assert.ok(!input.includes('device-only-context-marker'), 'the map request never reads the paper');
  // Charged with the answer, held at the map request's largest size, frozen in the quote.
  const quote = h.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as Record<string, unknown>;
  assert.equal(quote.study_model, HAIKU); assert.equal(quote.study_max_tokens, STUDY_MAX_TOKENS);
  assert.equal(quote.study_ceiling_microusd, holdForParams(STUDY_HOLD_PARAMS).microusd); assert.equal(STUDY_HOLD_PARAMS.model, HAIKU);
  assert.equal(quote.max_searches, 0);
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.equal(Number(settle.p_actual_microusd), priceAttempts([...completeOutcome().attempts, ...studyOutcome(sampleMap).attempts]));
  // Logged as counts only.
  assert.equal(h.answers[0].study, 'written'); assert.equal(h.answers[0].study_concepts, 2);
  assert.ok(!JSON.stringify(h.logs).includes('Softmax'), 'concept names are never logged');
});

test('Study: the first turn is no answer; unusable, failed or slow map requests leave the map unchanged and the answer completes', async () => {
  const first = studyHarness({ generate: async (params, stream) => {
    if (params.model === HAIKU) {
      assert.match(JSON.stringify(params.messages), /<reader_answer>none: the first turn<\/reader_answer>/);
      return studyOutcome({ concepts: [{ id: 'attention', label: 'Attention', state: 'learning', paragraphs: [1] }], links: [], focus: 'attention', journey: ['attention'], next: 'calibrate' });
    }
    stream.onText('**In one sentence, what problem does attention solve?**'); return completeOutcome(); } });
  await runChat(first.deps, studyBody(), first.emit, new AbortController().signal);
  assert.deepEqual(first.events.map(e => e.event), ['delta', 'study', 'done']);
  assert.equal((first.events[1].data as { map: { focus: string } }).map.focus, 'attention');
  const invalid = studyHarness({ generate: async (params, stream) => {
    if (params.model === HAIKU) return studyOutcome({ concepts: [{ id: 'x', label: 'x', state: 'fluent', paragraphs: [] }], links: [], focus: null, journey: [], next: 'teach' });
    stream.onText('x'); return completeOutcome(); } });
  await runChat(invalid.deps, studyBody(), invalid.emit, new AbortController().signal);
  assert.deepEqual(invalid.events.map(e => e.event), ['delta', 'done']); assert.equal(invalid.answers[0].study, 'unusable');
  const failed = studyHarness({ generate: async (params, stream) => {
    if (params.model === HAIKU) throw new Error('provider down');
    stream.onText('x'); return completeOutcome(); } });
  await runChat(failed.deps, studyBody(), failed.emit, new AbortController().signal);
  assert.deepEqual(failed.events.map(e => e.event), ['delta', 'done']); assert.equal(failed.answers[0].study, 'failed');
  assert.ok(Number(failed.calls.find(c => c.name === 'worker_settle_chat')!.params.p_actual_microusd) > priceAttempts(completeOutcome().attempts));
  const slow = studyHarness({ generate: async (params, stream) => {
    if (params.model === HAIKU) { await new Promise(resolve => stream.signal.addEventListener('abort', resolve, { once: true })); return studyOutcome(null, { status: 'failed', failure: 'aborted', stopReason: null }); }
    stream.onText('x'); return completeOutcome(); } });
  slow.deps.studyTimeoutMs = 20;
  await runChat(slow.deps, studyBody(), slow.emit, new AbortController().signal);
  assert.deepEqual(slow.events.map(e => e.event), ['delta', 'done']);
  // A refused answer makes no map request; a plain answer makes none and holds nothing for one.
  const refused = studyHarness({ generate: async () => completeOutcome({ stopReason: 'refusal' }) });
  await runChat(refused.deps, studyBody(), refused.emit, new AbortController().signal);
  assert.equal(refused.generations(), 1); assert.deepEqual(refused.events, [{ event: 'error', data: { code: 'refused', credits: 0, charged: false, reason: 'refusal' } }]);
  const plain = studyHarness();
  await runChat(plain.deps, paperBody({ document_id: null, local_context: studyContext }), plain.emit, new AbortController().signal);
  assert.ok(!('study_model' in (plain.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as object))); assert.equal(plain.answers[0].study, undefined);
  // Study never searches, even when search is on.
  const searching = studyHarness({ generate: async (params, stream) => {
    if (params.model === HAIKU) return studyOutcome(EMPTY_STUDY_MAP);
    assert.ok(!params.tools?.some(t => t.name === 'web_search' || t.name === 'search_web'), 'no search tool for the tutor');
    stream.onText('x'); return completeOutcome(); } });
  searching.deps.webSearch = true; searching.deps.search = { ready: async () => true, run: async () => found };
  await runChat(searching.deps, studyBody(), searching.emit, new AbortController().signal);
  assert.equal(searching.answers[0].web_search_offered, false);
});

import { sanitizeVisual, visualDocument, visualRequest } from '../../supabase/functions/_shared/chat-visual.ts';
import { figureImages, figurePartsRequest, IMAGE_HOLD_TOKENS, SHOW_FIGURE_PARTS_TOOL } from '../../supabase/functions/_shared/chat-figures.ts';

test('visual answers: the sanitizer keeps structure, tables and inline SVG, drops images and foreign references, refuses script', () => {
  const fragment = '<h2 style="color:#333">Pipeline</h2><p>Three <b>steps</b>:</p><ol><li>Sample</li><li>Score</li></ol>'
    + '<table><tr><th colspan="2">Model</th></tr><tr><td style="background:#eef">GRPO</td><td>80.8</td></tr></table>'
    + '<svg viewBox="0 0 200 60" width="100%"><defs><marker id="arrow" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto"><path d="M0,0 L6,3 L0,6 z"/></marker></defs>'
    + '<rect x="2" y="10" width="60" height="30" rx="4" fill="#dde"/><text x="32" y="30" text-anchor="middle" font-size="10">Policy</text><line x1="62" y1="25" x2="120" y2="25" stroke="#333" marker-end="url(#arrow)"/></svg>'
    + '<img src="https://evil.example/x.png"><a href="https://arxiv.org/abs/1">paper</a><a href="javascript:alert(1)">bad</a><font color="red">old</font>'
    + '<style>.k{font-weight:bold} td{padding:2px}</style>';
  const out = sanitizeVisual(fragment)!;
  assert.ok(out, 'sanitized');
  assert.match(out, /<h2 style="color:#333">Pipeline<\/h2>/);
  assert.match(out, /<th colspan="2">Model<\/th>/);
  assert.match(out, /<svg viewBox="0 0 200 60" width="100%">/, 'SVG attribute case kept');
  assert.match(out, /<marker id="arrow" markerHeight="6" markerWidth="6" orient="auto" refX="5" refY="3">/);
  assert.match(out, /marker-end="url\(#arrow\)"/);
  assert.ok(!/<img|evil\.example/.test(out), 'images are left out');
  assert.match(out, /<a href="https:\/\/arxiv\.org\/abs\/1" rel="noopener noreferrer" target="_blank">paper<\/a>/);
  assert.ok(!/javascript:/.test(out) && /bad/.test(out), 'a script link keeps its words, loses its href');
  assert.ok(!/<font/.test(out) && /old/.test(out), 'an unknown element is unwrapped');
  assert.match(out, /<style>\.k\{font-weight:bold\} td\{padding:2px\}<\/style>/, 'safe CSS stays as written');
  for (const bad of ['<script>alert(1)</script><p>x</p>', '<p onclick="x()">x</p>', '<iframe src="https://a"></iframe>', '<svg><image href="https://a/b.png"/></svg>',
    '<svg><foreignObject><div>x</div></foreignObject></svg>', '', '   ', '<img src="a.png">', '<p>x</p>'.repeat(5_000), '<!doctype html><p>x</p>']) {
    assert.equal(sanitizeVisual(bad), null, bad.slice(0, 40));
  }
  assert.equal(sanitizeVisual('<p style="background:url(https://a/b)">x</p>'), '<p>x</p>', 'an unsafe style attribute goes');
  assert.equal(sanitizeVisual('<style>@import "x"; p{}</style><p>y</p>'), '<p>y</p>', 'an unsafe style element goes');
  assert.equal(sanitizeVisual('<svg><use href="https://a/b#c"/><rect width="4" height="4"/></svg>'), '<svg><use></use><rect height="4" width="4"></rect></svg>', 'only fragment references');
});

test('create_visual input is a bounded, sanitized fragment; the device document wraps it without scripts or network', () => {
  assert.deepEqual(visualRequest({ title: ' Training\n loop ', html: '<p>a</p>\r\n' }), { title: 'Training loop', html: '<p>a</p>' });
  for (const bad of [null, 'x', {}, { title: 'x' }, { html: '<p>x</p>' }, { title: '', html: '<p>x</p>' }, { title: 'x', html: '<script>1</script>' },
    { title: 'x'.repeat(121), html: '<p>x</p>' }, { title: 'x', html: '<p>' + 'y'.repeat(16_001) + '</p>' }, { title: 'x', html: '<p>x</p>', extra: 1 }]) {
    assert.equal(visualRequest(bad), null, JSON.stringify(bad).slice(0, 50));
  }
  const page = visualDocument('<p>hi</p>', { dark: true, fontSize: 18 });
  assert.match(page, /Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'/);
  assert.ok(!/<script/.test(page) && page.endsWith('<body><p>hi</p></body></html>'));
  assert.match(page, /color-scheme:dark/);
});

test('visual answers follow the capability: offered with it, with diagrams; neither without it; both for builds that name no capabilities', () => {
  const turns = [{ role: 'user' as const, text: 'How does the training loop flow?' }];
  const on = validateChatRequest({ ...paperBody(), capabilities: ['visual_answers'] });
  assert.equal(on.visuals, true);
  assert.equal(validateChatRequest({ ...paperBody(), capabilities: [] }).visuals, false, 'a build with the setting off sends an empty list');
  assert.equal(validateChatRequest(paperBody()).visuals, true, 'an older build says nothing');
  const offered = chatInstructionParts('paper', null, false, { visuals: true }).shared, withheld = chatInstructionParts('paper', null, false, { visuals: false }).shared;
  assert.match(offered, /call create_visual once/); assert.match(offered, /create_diagram once/);
  assert.match(withheld, /turned visual answers off/); assert.doesNotMatch(withheld, /create_visual|create_diagram/);
  const params = chatRequestParams({ instructions: offered, paper: { title: 'T', text: paperText }, turns, selection: null, tools: [CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL] });
  assert.deepEqual(params.tools, [CREATE_DIAGRAM_TOOL, CREATE_VISUAL_TOOL]);
});

test('a visual is relayed once, sanitized, before done; an invalid one is logged and dropped; a build with visuals off gets no visual tool', async () => {
  let tools: unknown;
  const h = harness({ generate: async (params, stream) => {
    tools = (params as { tools?: unknown }).tools;
    stream.onText('Here is the loop.');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'create_visual', input: { title: 'Loop', html: '<p onmouseover="x">no</p>' } }] });
  } });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual((tools as { name: string }[]).map(t => t.name), ['create_diagram', 'create_visual', 'show_figure_parts']);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'done'], 'the handler attribute refuses the visual');
  assert.deepEqual(h.logs, [{ event: 'chat_visual_invalid_input', operation_id: operation }]);

  const good = harness({ generate: async (_p, stream) => { stream.onText('Steps:');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'create_visual', input: { title: 'Loop', html: '<ol><li>a</li></ol><img src="x.png">' } }] }); } });
  await runChat(good.deps, paperBody(), good.emit, new AbortController().signal);
  assert.deepEqual(good.events.map(e => e.event), ['delta', 'visual', 'done']);
  assert.deepEqual(good.events[1].data, { title: 'Loop', html: '<ol><li>a</li></ol>' });
  assert.deepEqual(good.logs, [{ event: 'chat_visual', operation_id: operation }]);

  let offTools: unknown;
  const off = harness({ generate: async (params, stream) => { offTools = (params as { tools?: unknown }).tools; stream.onText('Prose only.'); return completeOutcome({ stopReason: 'end_turn' }); } });
  await runChat(off.deps, { ...paperBody(), capabilities: [] }, off.emit, new AbortController().signal);
  assert.equal(offTools, undefined, 'no tools at all when visuals are off and search is not on');
});

// ---------- Figures (consent v3) ----------
const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(60, 7)]).toString('base64');
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(60, 1)]).toString('base64');
const figure = (changes: Record<string, unknown> = {}) => ({ id: 'F1', paragraph: 12, caption: 'Figure 2: The pipeline.', media_type: 'image/jpeg', data: JPEG, width: 800, height: 600, ...changes });

test('figures: bounded PNG/JPEG images with ids and paragraphs, only under consent v3 in a paper chat', () => {
  assert.deepEqual(figureImages(undefined), []);
  const [one] = figureImages([figure({ caption: ' Figure 2:\n The pipeline. ' })]);
  assert.deepEqual({ ...one, data: '…' }, { id: 'F1', paragraph: 12, caption: 'Figure 2: The pipeline.', mediaType: 'image/jpeg', data: '…', width: 800, height: 600 });
  assert.equal(figureImages([figure({ media_type: 'image/png', data: PNG })])[0].mediaType, 'image/png');
  for (const bad of [[figure({ id: 'F4' })], [figure(), figure()], [figure({ media_type: 'image/gif' })], [figure({ data: PNG })], [figure({ width: 4000 })],
    [figure({ paragraph: 0 })], [figure({ extra: 1 })], [figure({ data: 'not base64!' })], Array.from({ length: 4 }, (_, i) => figure({ id: `F${i + 1}` }))]) {
    assert.throws(() => figureImages(bad), JSON.stringify(bad).slice(0, 60));
  }
  const v3 = (body: Record<string, unknown>) => ({ ...body, consent_version: 'cloud-ai-v3' });
  assert.equal(validateChatRequest(v3(paperBody({ figures: [figure()] }))).figures.length, 1);
  assert.throws(() => validateChatRequest({ ...paperBody({ figures: [figure()] }), consent_version: 'cloud-ai-v2' }), { code: 'invalid_request' }, 'v2 does not name figures');
  assert.throws(() => validateChatRequest(v3(paperBody({ figures: [figure()], action: 'ingest', selection: { quote: '[3] A paper' } }))), { code: 'invalid_request' });
  // The digest covers the image itself.
  const a = canonicalRequest(validateChatRequest(v3(paperBody({ figures: [figure()] })))), b = canonicalRequest(validateChatRequest(v3(paperBody({ figures: [figure({ data: JPEG.slice(0, -4) + 'AAAA' })] }))));
  assert.notEqual(a, b);
});

test('figures go before the question as label and image; the hold counts each image as its tokens, not its base64', () => {
  const turns = [{ role: 'user' as const, text: 'What does Figure 2 show?' }];
  const images = figureImages([figure({ data: Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(90_002, 7)]).toString('base64') })]);
  const blocks = [{ type: 'text' as const, text: '<figure id="F1" paragraph="¶12">Figure 2: The pipeline.</figure>' },
    { type: 'image' as const, source: { type: 'base64' as const, media_type: 'image/jpeg' as const, data: images[0].data } }];
  const params = chatRequestParams({ instructions: 'x', paper: { title: 'T', text: paperText }, turns, selection: null, figures: blocks });
  const last = params.messages.at(-1)!.content as { type: string }[];
  assert.deepEqual(last.map(b => b.type), ['text', 'image', 'text']);
  const without = chatRequestParams({ instructions: 'x', paper: { title: 'T', text: paperText }, turns, selection: null });
  const extra = promptCharacters(params) - promptCharacters(without);
  assert.ok(extra >= IMAGE_HOLD_TOKENS * 3 && extra < IMAGE_HOLD_TOKENS * 3 + 1_000, `an image holds its tokens: ${extra}`);
});

test('show_figure_parts: boxes within the image, tight enough, against an attached figure only; relayed once before done', async () => {
  const images = figureImages([figure()]);
  const parts = figurePartsRequest({ figure: 'F1', title: ' The pipeline ', parts: [{ label: 'Encoder', box: [0, 0, 0.5, 1.2], note: 'Reads the input.' }, { label: 'Decoder', box: [0.5, 0, 1, 1], note: 'Writes the output.' }] }, images);
  assert.deepEqual(parts, { figure: 'F1', paragraph: 12, title: 'The pipeline', parts: [{ label: 'Encoder', note: 'Reads the input.', box: [0, 0, 0.5, 1] }, { label: 'Decoder', note: 'Writes the output.', box: [0.5, 0, 1, 1] }] });
  for (const bad of [{ figure: 'F2', title: 'x', parts: [{ label: 'a', box: [0, 0, 1, 1], note: 'n' }] }, { figure: 'F1', title: 'x', parts: [] },
    { figure: 'F1', title: 'x', parts: [{ label: 'a', box: [0.5, 0.5, 0.51, 0.9], note: 'n' }] }, { figure: 'F1', title: 'x', parts: [{ label: 'a', box: [0, 0, 1], note: 'n' }] }]) {
    assert.equal(figurePartsRequest(bad, images), null, JSON.stringify(bad).slice(0, 60));
  }
  assert.equal(figurePartsRequest({ figure: 'F1', title: 'x', parts: [{ label: 'a', box: [0, 0, 1, 1], note: 'n' }] }, []), null, 'no figure attached');

  let sentParams: { tools?: { name: string }[]; system?: { text: string }[]; messages?: { content: unknown }[] } | null = null;
  const h = harness({ generate: async (params, stream) => {
    sentParams = params as typeof sentParams;
    stream.onText('Figure 2 has two halves.');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'show_figure_parts', input: { figure: 'F1', title: 'Pipeline', parts: [{ label: 'Left', box: [0, 0, 0.5, 1], note: 'The encoder.' }] } }] });
  } });
  await runChat(h.deps, { ...paperBody(), consent_version: CONSENT, figures: [figure()] }, h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'figure_parts', 'done']);
  assert.deepEqual(h.events[1].data, { figure: 'F1', paragraph: 12, title: 'Pipeline', parts: [{ label: 'Left', note: 'The encoder.', box: [0, 0, 0.5, 1] }] });
  assert.deepEqual(h.logs, [{ event: 'chat_figure_parts', operation_id: operation }]);
  const system = sentParams!.system!.map(b => b.text).join('\n');
  assert.match(system, /comes with the figure it refers to, attached as image \(F1\)/);
  assert.match(system, /call show_figure_parts once/);
  assert.match(system, /Write your explanation first/);
  assert.match(system, /put a line \[\[part N\]\] on its own/, 'markers place the crops inline');
  assert.match(sentParams!.tools!.find(t => t.name === 'show_figure_parts') ? JSON.stringify(sentParams!.tools) : '', /\[\[part N\]\]/);

  // Parts without prose: the answer is the parts' notes.
  const bare = harness({ generate: async () => completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'show_figure_parts',
    input: { figure: 'F1', title: 'Pipeline', parts: [{ label: 'Left', box: [0, 0, 0.5, 1], note: 'The encoder.' }, { label: 'Right', box: [0.5, 0, 1, 1], note: 'The decoder.' }] } }] }) });
  await runChat(bare.deps, { ...paperBody(), consent_version: CONSENT, figures: [figure()] }, bare.emit, new AbortController().signal);
  assert.deepEqual(bare.events.map(e => e.event), ['delta', 'figure_parts', 'done']);
  assert.equal((bare.events[0].data as { text: string }).text, 'Pipeline\n\n[[part 1]]\n**Left**: The encoder.\n\n[[part 2]]\n**Right**: The decoder.');
});

test('look_at_figure: offered to devices that can answer it (consent v3), relayed as figure_request, never with a figure attached', async () => {
  const { figureLookRequest } = await import('../../supabase/functions/_shared/chat-figures.ts');
  assert.deepEqual(figureLookRequest({ figure: ' fig. 04 ' }), { figure: 'Figure 4' });
  assert.deepEqual(figureLookRequest({ figure: 'Table 2' }), { figure: 'Table 2' });
  for (const bad of [{ figure: 'the architecture' }, { figure: 'Figure' }, { figure: 'Figure 4a' }, {}, null, 'Figure 4']) assert.equal(figureLookRequest(bad), null, JSON.stringify(bad));

  let sent: { tools?: { name: string }[]; system?: { text: string }[] } | null = null;
  const asks = harness({ generate: async (params, stream) => {
    sent = params as typeof sent;
    stream.onText('Let me look at Figure 4.');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'look_at_figure', input: { figure: 'Figure 4' } }] });
  } });
  await runChat(asks.deps, { ...paperBody(), consent_version: CONSENT, capabilities: ['visual_answers', 'figure_requests'], follow_ups: true }, asks.emit, new AbortController().signal);
  assert.deepEqual(sent!.tools?.map(t => t.name), ['create_diagram', 'create_visual', 'show_figure_parts', 'look_at_figure']);
  assert.match(sent!.system!.map(b => b.text).join('\n'), /call look_at_figure with its number before writing anything/);
  assert.deepEqual(asks.events.map(e => e.event), ['delta', 'figure_request', 'done'], 'no suggestions for an answer that asked for a figure');
  assert.deepEqual(asks.events[1].data, { figure: 'Figure 4' });

  // A build without the capability (or without visual answers) is never offered the tool; consent v2 sends nothing at all.
  for (const body of [{ ...paperBody(), consent_version: CONSENT, capabilities: ['visual_answers'] }, { ...paperBody(), capabilities: ['figure_requests'] },
    { ...paperBody(), consent_version: 'cloud-ai-v2', capabilities: ['visual_answers', 'figure_requests'] }]) {
    let tools: string[] = [];
    const h = harness({ generate: async params => { tools = ((params as { tools?: { name: string }[] }).tools ?? []).map(t => t.name); return completeOutcome({}); } });
    await runChat(h.deps, body, h.emit, new AbortController().signal);
    assert.ok(!tools.includes('look_at_figure'), JSON.stringify(body.capabilities));
  }
  // With a figure attached the tool is still offered (the cached tools stay the same) but a call is not relayed.
  const attached = harness({ generate: async () => completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'look_at_figure', input: { figure: 'Figure 2' } }] }) });
  await runChat(attached.deps, { ...paperBody(), consent_version: CONSENT, capabilities: ['visual_answers', 'figure_requests'], figures: [figure()] }, attached.emit, new AbortController().signal);
  assert.ok(!attached.events.some(e => e.event === 'figure_request'));
});

// The equation view (chat-equation.ts, docs/architecture/EQUATION_VIEW.md): symbols as checked JSON, background as prose,
// both on the chat's own cached prefix.
const equationContext = { ...localContext, format: 'reader-local-context-v2', text: '[¶1] Title\n[¶2] We optimize the policy π_θ with temperature β.\n[¶3] L = -log σ(β x)' };
const equationBody = (overrides: Record<string, unknown> = {}) => paperBody({ document_id: null, local_context: equationContext, action: 'equation',
  selection: { quote: 'L = -\\log \\sigma(\\beta x)' }, messages: [{ role: 'user', text: 'Equation (1)' }], ...overrides });
const equationHarness = (options: Parameters<typeof harness>[0] = {}) =>
  harness({ ...options, script: { worker_local_chat_context: () => ({ title: 'DPO' }), ...options.script } });

test('equation actions: the numbered paper on the device, one turn, a selection; never a title, suggestions or figures', () => {
  assert.equal(validateChatRequest(equationBody()).action, 'equation');
  assert.equal(validateChatRequest(equationBody({ action: 'equation_background' })).action, 'equation_background');
  for (const [label, change] of Object.entries({
    'no selection': { selection: null }, 'unnumbered context (v1)': { local_context: localContext }, 'server document': { document_id: documentID, local_context: undefined },
    'general mode': { mode: 'general', local_context: undefined }, 'title': { topic_title: true }, 'follow-ups': { follow_ups: true },
    'two turns': { messages: [{ role: 'user', text: 'a' }, { role: 'assistant', text: 'b' }, { role: 'user', text: 'c' }] },
  })) assert.throws(() => validateChatRequest(equationBody(change as Record<string, unknown>)), { code: 'invalid_request' }, label);
});

test('the equation view reads the chat cache: same tools, shared instructions and paper as a chat about the paper', async () => {
  const seen: ModelRequest[] = [];
  const h = equationHarness({ generate: async (params, stream) => { seen.push(params); stream.onText('{"summary":"s","symbols":[]}'); return completeOutcome(); } });
  for (const body of [paperBody({ document_id: null, local_context: equationContext, selection: { quote: 'L = -\\log \\sigma(\\beta x)' } }), equationBody(), equationBody({ action: 'equation_background' })])
    await runChat(h.deps, body, h.emit, new AbortController().signal);
  const [chat, symbols, background] = seen;
  for (const other of [symbols, background]) {
    assert.deepEqual(other.tools, chat.tools); assert.equal(other.model, chat.model);
    assert.deepEqual((other.system as unknown[]).slice(0, 2), (chat.system as unknown[]).slice(0, 2), 'shared instructions and the cached paper match');
  }
  assert.match(JSON.stringify((symbols.system as unknown[])[2]), /Reply with only one JSON object/);
  assert.equal(symbols.max_tokens, EQUATION_MAX_TOKENS);
  assert.match(JSON.stringify((background.system as unknown[])[2]), /background to understand it/);
});

test('Flash symbols reserve reasoning as well as the JSON answer, without changing the cached prefix', async () => {
  const sent: ModelRequest[] = [];
  const h = equationHarness({ generate: async (params, stream) => {
    sent.push(params);
    stream.onText('{"summary":"The DPO loss.","symbols":[{"symbol":"β","meaning":"Controls departure from the reference.","source":"paper","paragraph":2}]}');
    return completeOutcome({ model: 'gemini-3.8-flash', attempts: [{ model: 'gemini-3.8-flash', estimated: false,
      billedMicrousd: 12_000, usage: { input: 500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 34_000, output: 3_000 } }] });
  } });
  h.deps.gemini = true;
  const profile = { model: 'gemini', effort: 'medium', length: 'standard' };
  for (const action of ['equation', 'equation_background'])
    await runChat(h.deps, equationBody({ action, profile, consent_version: 'cloud-ai-v5' }), h.emit, new AbortController().signal);
  assert.equal(sent[0].max_tokens, 6_000, '2,000 answer tokens plus 4,000 for medium reasoning');
  assert.deepEqual(sent[0].thinking, sent[1].thinking);
  assert.deepEqual(sent[0].tools, sent[1].tools);
  assert.deepEqual((sent[0].system as unknown[]).slice(0, 2), (sent[1].system as unknown[]).slice(0, 2));
  const reservation = h.calls.find(c => c.name === 'worker_reserve_chat')!.params;
  assert.equal((reservation.p_quote as Record<string, unknown>).max_output_tokens, sent[0].max_tokens);
  assert.ok(Number(reservation.p_microusd) >= 12_000);
  assert.equal(h.events[0].event, 'equation');
  assert.equal(settledWith(h).p_actual_microusd, 12_000);
  assert.equal(settledWith(h).p_ending, 'completed');
});

test('broken equation JSON is never displayed or charged, even when the provider says it finished', async () => {
  for (const [text, stopReason] of [
    ['{"summary":"The DPO', 'max_tokens'],
    ['```json\n{"summary":"The DPO', 'end_turn'],
    ['Here is the result: {"summary":"The DPO', 'end_turn'],
  ] as const) {
    const h = equationHarness({ generate: async (_params, stream) => { stream.onText(text); return completeOutcome({ stopReason }); } });
    await runChat(h.deps, equationBody(), h.emit, new AbortController().signal);
    assert.deepEqual(h.events.map(e => e.event), ['done']);
    const settle = settledWith(h);
    assert.equal(settle.p_actual_credits, 0);
    assert.equal(settle.p_ending, stopReason === 'max_tokens' ? 'limit' : 'provider');
    assert.equal(settle.p_absorbed_microusd, settle.p_actual_microusd);
  }
});

test('symbols are held back, checked and relayed once; a made-up paragraph becomes general; no JSON falls back to the words', async () => {
  const json = '```json\n{"summary":"The DPO loss.","symbols":[{"symbol":"β","latex":"\\\\beta","meaning":"Temperature.","source":"paper","paragraph":2},'
    + '{"symbol":"σ","meaning":"Logistic function.","source":"general"},{"symbol":"x","meaning":"Margin.","source":"paper","paragraph":99},{"symbol":"","meaning":"dropped"}]}\n```';
  const h = equationHarness({ generate: async (_params, stream) => { for (const piece of json.match(/.{1,17}/gs)!) stream.onText(piece); return completeOutcome(); } });
  await runChat(h.deps, equationBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['equation', 'done'], 'no raw JSON reaches the device');
  assert.deepEqual(h.events[0].data, { format: 'equation-symbols-v1', summary: 'The DPO loss.', symbols: [
    { symbol: 'β', latex: '\\beta', meaning: 'Temperature.', source: 'paper', paragraph: 2 },
    { symbol: 'σ', meaning: 'Logistic function.', source: 'general' },
    { symbol: 'x', meaning: 'Margin.', source: 'general' }] });
  const words = equationHarness({ generate: async (_params, stream) => { stream.onText('β is the temperature.'); return completeOutcome(); } });
  await runChat(words.deps, equationBody(), words.emit, new AbortController().signal);
  assert.deepEqual(words.events.map(e => e.event), ['delta', 'done']); assert.deepEqual(words.events[0].data, { text: 'β is the temperature.' });
  // Background streams like an answer; a tool the model calls anyway is never relayed.
  const background = equationHarness({ generate: async (_params, stream) => { stream.onText('It compares two responses'); stream.onText(' [¶2].');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ name: 'create_diagram', input: { title: 't', source: 'flowchart LR\nA-->B' } }] }); } });
  await runChat(background.deps, equationBody({ action: 'equation_background' }), background.emit, new AbortController().signal);
  assert.deepEqual(background.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.equal(equationSymbols('no json here', 3), null); assert.equal(paragraphCount(equationContext.text), 3);
});

// The figure view (chat-figure-view.ts, docs/architecture/FIGURE_VIEW.md): a walkthrough as one checked tool call and one
// part again, more simply, both on the chat's own cached prefix (figure_walkthrough is among the chat's tools for a
// build that has the view).
const figureContext = { ...localContext, format: 'reader-local-context-v2', text: Array.from({ length: 14 }, (_, i) => `[¶${i + 1}] Block ${i + 1}.`).join('\n') };
const toolNames = (p: Params) => (p.tools ?? []).map(t => (t as { name: string }).name);
const FIGURE_DEVICE = ['visual_answers', 'figure_requests', 'figure_view', 'stop_signal'];
const figureBody = (overrides: Record<string, unknown> = {}) => paperBody({ document_id: null, local_context: figureContext, consent_version: CONSENT,
  capabilities: FIGURE_DEVICE, action: 'figure', selection: { quote: 'Figure 2: The pipeline.' }, messages: [{ role: 'user', text: 'Figure 2' }],
  figures: [figure()], ...overrides });
const walkthroughCall = (input: unknown, changes: Partial<ProviderOutcome> = {}) => completeOutcome({ stopReason: 'tool_use',
  toolCalls: [{ id: 'toolu_1', name: 'figure_walkthrough', input }], ...changes });

test('figure actions: the numbered paper on the device, one turn, a selection and exactly one figure, from a build with the view', () => {
  assert.equal(validateChatRequest(figureBody()).action, 'figure');
  assert.equal(validateChatRequest(figureBody({ action: 'figure_simpler', selection: { quote: 'The encoder reads the input.' } })).action, 'figure_simpler');
  assert.equal(validateChatRequest(figureBody({ consent_version: 'cloud-ai-v4' })).figures.length, 1);
  assert.ok(validateChatRequest(figureBody()).capabilities.includes('figure_view'), 'figure_view is a known capability');
  for (const [label, change] of Object.entries({
    'no figure': { figures: undefined }, 'two figures': { figures: [figure(), figure({ id: 'F2' })] }, 'consent v2 (names no figures)': { consent_version: 'cloud-ai-v2' },
    'a build without the view': { capabilities: ['visual_answers', 'figure_requests'] }, 'no selection': { selection: null },
    'unnumbered context (v1)': { local_context: localContext }, 'server document': { document_id: documentID, local_context: undefined },
    'general mode': { mode: 'general', local_context: undefined }, 'title': { topic_title: true }, 'follow-ups': { follow_ups: true },
    'two turns': { messages: [{ role: 'user', text: 'a' }, { role: 'assistant', text: 'b' }, { role: 'user', text: 'c' }] },
  })) {
    assert.throws(() => validateChatRequest(figureBody(change as Record<string, unknown>)), { code: 'invalid_request' }, label);
    assert.throws(() => validateChatRequest(figureBody({ action: 'figure_simpler', ...change as Record<string, unknown> })), { code: 'invalid_request' }, `simpler: ${label}`);
  }
});

test('the figure view reads the chat cache: tools, model, thinking, shared instructions and paper byte-identical to a chat about the paper', async () => {
  const seen: Params[] = [];
  const h = equationHarness({ generate: async (params, stream) => { seen.push(params); stream.onText('Words.'); return completeOutcome(); } });
  searching(h, []);
  const device = { document_id: null, local_context: figureContext, consent_version: CONSENT, capabilities: FIGURE_DEVICE };
  const bodies = [
    paperBody({ ...device, messages: [{ role: 'user', text: 'What does the method optimize?' }] }),
    paperBody({ ...device, messages: [{ role: 'user', text: 'What does Figure 2 show?' }], figures: [figure()] }),
    figureBody(),
    figureBody({ action: 'figure_simpler', selection: { quote: 'The encoder reads the input [¶12].' } }),
  ];
  for (const body of bodies) await runChat(h.deps, body, h.emit, new AbortController().signal);
  assert.equal(seen.length, 4);
  const [chat, asked, walkthrough, simpler] = seen;
  // The cached prefix is tools → system blocks up to the paper's breakpoint; the model and thinking decide whose cache it is.
  const prefix = (p: Params) => Buffer.from(JSON.stringify({ model: p.model, thinking: p.thinking, tools: p.tools, system: (p.system as unknown[]).slice(0, 2) }));
  for (const other of [asked, walkthrough, simpler]) {
    assert.ok(prefix(other).equals(prefix(chat)), 'the cached prefix is byte-identical');
    assert.equal(other.tool_choice, undefined, 'no forced tool: Sonnet 5.5 refuses one, and it is the chat\'s tool_choice');
    assert.deepEqual((other.system as { cache_control?: unknown }[])[1].cache_control, { type: 'ephemeral', ttl: '1h' }, 'the paper keeps its breakpoint');
  }
  assert.deepEqual(toolNames(chat), ['create_diagram', 'create_visual', 'show_figure_parts', 'look_at_figure', 'figure_walkthrough', 'search_web']);
  // Only the action's own instructions (after the paper) and the turn differ.
  const after = (p: Params) => (p.system as { text: string }[])[2]?.text ?? '';
  assert.match(after(walkthrough), /^The reader opened the figure view on the attached figure \(F1/);
  assert.match(after(walkthrough), /Write the whole walkthrough as one JSON object in your reply/, 'written as JSON in the reply: every model streams it (Gemini sends a tool call whole)');
  assert.doesNotMatch(after(walkthrough), /show_figure_parts once/, 'the chat\'s figure-parts instructions do not apply');
  assert.match(after(simpler), /explained more simply \("back up a bit"\)/);
  assert.equal(walkthrough.max_tokens, figureMaxTokens('low'));
  assert.equal(simpler.max_tokens, chat.max_tokens);
  const last = walkthrough.messages.at(-1)!.content as { type: string; text?: string }[];
  assert.deepEqual(last.map(b => b.type), ['text', 'text', 'image', 'text']);
  assert.equal(last[0].text, '<selected_passage>\nFigure 2: The pipeline.\n</selected_passage>'); assert.equal(last[3].text, 'Figure 2');
  // A build without the view keeps exactly the tools (and so the cache) it had.
  const old: Params[] = [];
  const before = equationHarness({ generate: sending(old) });
  await runChat(before.deps, paperBody({ ...device, capabilities: ['visual_answers', 'figure_requests', 'stop_signal'] }), before.emit, new AbortController().signal);
  assert.deepEqual(toolNames(old[0]), ['create_diagram', 'create_visual', 'show_figure_parts', 'look_at_figure']);
  // Visual answers off: the walkthrough tool alone, still the same for a chat and a walkthrough.
  const off: Params[] = [];
  const quiet = equationHarness({ generate: sending(off) });
  for (const body of [paperBody({ ...device, capabilities: ['figure_view'] }), figureBody({ capabilities: ['figure_view'] })]) await runChat(quiet.deps, body, quiet.emit, new AbortController().signal);
  assert.deepEqual(off.map(toolNames), [['figure_walkthrough'], ['figure_walkthrough']]);
});

test('figure_walkthrough input: sections kept in order, bounded, boxes inside the image (at most 12), citations inside the paper', () => {
  assert.deepEqual(figureBox({ x: -0.01, y: 0.5, w: 0.31, h: 0.2 }), { x: 0, y: 0.5, w: 0.3, h: 0.2 }, 'a tiny overshoot is clamped');
  assert.deepEqual(figureBox({ x: 0.7, y: 0.7, w: 0.31, h: 0.3 }), { x: 0.7, y: 0.7, w: 0.3, h: 0.3 });
  for (const bad of [{ x: 0.9, y: 0.9, w: 0.02, h: 0.05 }, { x: 0, y: 0, w: 1, h: 1 }, { x: 0.5, y: 0.5, w: 0.6, h: 0.2 }, { x: 0, y: 0, w: 0.5 }, [0, 0, 0.5, 0.5],
    { x: '0', y: 0, w: 0.5, h: 0.5 }, { x: Number.NaN, y: 0, w: 0.5, h: 0.5 }, null]) assert.equal(figureBox(bad), null, JSON.stringify(bad));
  const box = (x: number) => ({ x, y: 0.1, w: 0.1, h: 0.1 });
  const input = { summary: ' The figure compares RLHF with DPO [¶12][¶40]. ', sections: [
    { label: '(a)', title: 'The RLHF pipeline', text: 'Three stages [¶12]. A made-up block [¶99].\r\n\n\n\nThen a reward model [¶13].', paragraphs: [12, 99, 0, 12.5], box: box(0) },
    { label: '', title: 'Legend', text: 'Colours mark the models.', paragraphs: [], box: { x: 0.9, y: 0.9, w: 0.02, h: 0.05 } },
    { label: '(b)', title: '', text: 'Only a label.', paragraphs: [13] },
    { label: 'x', title: 'No text', text: '  ', paragraphs: [] },
    'not a section',
    { label: '(c)', title: 'C', text: 'c', paragraphs: [], box: box(0.2) },
    { label: '(d)', title: 'D', text: 'd', paragraphs: [], box: box(0.4) },
    { label: '(e)', title: 'E', text: 'e', paragraphs: [], box: box(0.6) },
    { label: '(f)', title: 'F', text: 'f', paragraphs: [], box: box(0.8) },
  ] };
  const walkthrough = figureWalkthrough(input, 14)!;
  assert.equal(walkthrough.format, 'figure-walkthrough-v1');
  assert.equal(walkthrough.summary, 'The figure compares RLHF with DPO [¶12].');
  assert.deepEqual(walkthrough.sections.map(s => [s.label, s.title]), [['(a)', 'The RLHF pipeline'], ['', 'Legend'], ['', '(b)'], ['(c)', 'C'], ['(d)', 'D'], ['(e)', 'E'], ['(f)', 'F']]);
  assert.deepEqual(walkthrough.sections[0], { label: '(a)', title: 'The RLHF pipeline', text: 'Three stages [¶12]. A made-up block .\n\nThen a reward model [¶13].',
    paragraphs: [12, 13], box: { x: 0, y: 0.1, w: 0.1, h: 0.1 } });
  assert.deepEqual(walkthrough.sections.map(s => s.box?.x ?? null), [0, null, null, 0.2, 0.4, 0.6, 0.8], 'the box too small is dropped; the fifth panel is retained');
  assert.equal(offeredBoxes(input), 6, 'the log counts the boxes the model offered');
  // At most 12 sections; a long text ends at a sentence before 1,500 characters; long labels and titles are shortened.
  const many = figureWalkthrough({ summary: 's', sections: Array.from({ length: 13 }, (_, i) => ({ label: 'L'.repeat(70), title: 'T'.repeat(130),
    text: `Sentence ${i} is here. `.repeat(100), paragraphs: [] })) }, 14)!;
  assert.equal(many.sections.length, 12);
  assert.ok([...many.sections[0].text].length <= 1_500 && many.sections[0].text.endsWith('here.'));
  assert.equal([...many.sections[0].label].length, 60); assert.ok(many.sections[0].label.endsWith('…')); assert.equal([...many.sections[0].title].length, 120);
  for (const bad of [null, [], 'x', {}, { summary: 's' }, { summary: 's', sections: 'x' }, { summary: 's', sections: [] }, { summary: 's', sections: [{ label: 'a', title: '', text: '' }] }]) {
    assert.equal(figureWalkthrough(bad, 14), null, JSON.stringify(bad));
  }
  assert.equal(figureWalkthroughText({ summary: 'Only a summary [¶3].', sections: 'x' }, 14), 'Only a summary [¶3].');
  assert.equal(figureWalkthroughText({ summary: 'S.', sections: [{ label: '(a)', title: 'A', text: 'T [¶2].', paragraphs: [2] }] }, 14), 'S.\n\n**(a) A**\n\nT [¶2].');
  assert.equal(figureWalkthroughText(null, 14), '');
});

test('the walkthrough is held back, checked and relayed once; without one the words are the description; nothing shown is not charged', async () => {
  const input = { summary: 'RLHF against DPO.', sections: [{ label: '(a)', title: 'RLHF', text: 'Three stages [¶12].', paragraphs: [12], box: { x: 0.02, y: 0.1, w: 0.45, h: 0.5 } },
    { label: '(b)', title: 'DPO', text: 'One stage [¶13].', paragraphs: [13] }] };
  const h = equationHarness({ generate: async (_params, stream) => { stream.onText('I’ll walk through it.'); return walkthroughCall(input); } });
  await runChat(h.deps, figureBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['figure_progress', 'figure', 'done'], 'no words and no other tool result reach the device');
  assert.deepEqual(h.events[0].data, { stage: 'reading' }, 'the device is told the model is reading the figure');
  assert.deepEqual(h.events[1].data, { format: 'figure-walkthrough-v1', summary: 'RLHF against DPO.', sections: [
    { label: '(a)', title: 'RLHF', text: 'Three stages [¶12].', paragraphs: [12], box: { x: 0.02, y: 0.1, w: 0.45, h: 0.5 } },
    { label: '(b)', title: 'DPO', text: 'One stage [¶13].', paragraphs: [13] }] });
  assert.deepEqual(h.logs, [{ event: 'chat_figure_walkthrough', operation_id: operation, called: true, sections: 2, boxes: 1, boxes_offered: 1, source: 'none', streamed: 0, first_part_ms: null }]);
  assert.equal(settledWith(h).p_action, 'figure'); assert.equal(settledWith(h).p_ending, 'completed'); assert.ok(Number(settledWith(h).p_actual_credits) > 0);
  assert.equal((h.events[2].data as { charged: boolean }).charged, true);
  // Parts, a diagram or a visual the model adds are never relayed in the view.
  const extra = equationHarness({ generate: async () => completeOutcome({ stopReason: 'tool_use', toolCalls: [{ id: 't1', name: 'figure_walkthrough', input },
    { id: 't2', name: 'show_figure_parts', input: { figure: 'F1', title: 'x', parts: [{ label: 'a', box: [0, 0, 1, 1], note: 'n' }] } },
    { id: 't3', name: 'create_visual', input: { title: 'v', html: '<p>v</p>' } }] }) });
  await runChat(extra.deps, figureBody(), extra.emit, new AbortController().signal);
  assert.deepEqual(extra.events.map(e => e.event), ['figure_progress', 'figure', 'done']);
  // No tool call: the model's words, once, as the description (charged: the reader got them).
  const words = equationHarness({ generate: async (_params, stream) => { stream.onText('The figure has two halves'); stream.onText(' [¶12].'); return completeOutcome(); } });
  await runChat(words.deps, figureBody(), words.emit, new AbortController().signal);
  assert.deepEqual(words.events.map(e => e.event), ['figure_progress', 'delta', 'done']); assert.deepEqual(words.events[1].data, { text: 'The figure has two halves [¶12].' });
  assert.equal(settledWith(words).p_ending, 'completed');
  // A call with no usable section: its words.
  const loose = equationHarness({ generate: async () => walkthroughCall({ summary: 'Only the summary.', sections: [{ label: 'a' }] }) });
  await runChat(loose.deps, figureBody(), loose.emit, new AbortController().signal);
  assert.deepEqual(loose.events.map(e => e.event), ['figure_progress', 'delta', 'done']); assert.deepEqual(loose.events[1].data, { text: 'Only the summary.' });
  assert.equal(loose.logs[0].event, 'chat_figure_walkthrough_invalid_output');
  // Nothing to show at all: a finished turn with nothing in it is the provider's, not charged.
  const empty = equationHarness({ generate: async () => walkthroughCall({}) });
  await runChat(empty.deps, figureBody(), empty.emit, new AbortController().signal);
  assert.deepEqual(empty.events.map(e => e.event), ['figure_progress', 'done']);
  assert.deepEqual([settledWith(empty).p_ending, settledWith(empty).p_actual_credits], ['provider', 0]);
  assert.deepEqual([(empty.events[1].data as { charged: boolean }).charged, (empty.events[1].data as { reason: string }).reason], [false, 'provider']);
  // Cut off at its allowance: our limit, not charged.
  const cut = equationHarness({ generate: async (_params, stream) => { stream.onText('Partial'); return completeOutcome({ stopReason: 'max_tokens' }); } });
  await runChat(cut.deps, figureBody(), cut.emit, new AbortController().signal);
  assert.deepEqual([settledWith(cut).p_action, settledWith(cut).p_ending, settledWith(cut).p_actual_credits], ['figure', 'limit', 0]);
});


// The streamed walkthrough (FIGURE_VIEW.md "Streamed walkthrough", 2026-10-22): the summary and each checked part reach the
// device as soon as the model has written them; the final `figure` event is unchanged, so builds that read only it work.
const streamInput = { summary: 'RLHF against DPO [¶12].', sections: [
  { kind: 'panel', label: '(a)', title: 'RLHF', text: 'Three stages, "quoted" {braces} and \\(\\beta\\) [¶12].', paragraphs: [12], box: { x: 0.02, y: 0.1, w: 0.45, h: 0.5 } },
  { label: 'x', title: '', text: '' },
  { label: '(b)', title: 'DPO', text: 'One stage [¶13].\nA second line.', paragraphs: [13], box: { x: 0.5, y: 0, w: 0.5, h: 1 } }] };
const chunks = (text: string, size: number) => Array.from({ length: Math.ceil(text.length / size) }, (_, i) => text.slice(i * size, (i + 1) * size));
const items = (reader: FigureWalkthroughStream, pieces: string[]) => pieces.flatMap(piece => reader.push(piece));

test('the walkthrough stream: the summary, then each checked part as its object closes, equal to the final check in any chunking', () => {
  const json = JSON.stringify(streamInput), final = figureWalkthrough(streamInput, 14)!;
  for (const size of [1, 2, 7, 64, json.length]) {
    const reader = new FigureWalkthroughStream(14);
    const got = items(reader, chunks(json, size));
    assert.deepEqual(got.map(i => i.kind), ['summary', 'section', 'section'], `chunks of ${size}`);
    assert.deepEqual(got[0], { kind: 'summary', summary: final.summary });
    assert.deepEqual(got.slice(1).map(i => (i as Extract<FigureStreamItem, { kind: 'section' }>).index), [0, 1], 'indexes are places in the final walkthrough (the empty part is skipped)');
    assert.deepEqual(got.slice(1).map(i => (i as Extract<FigureStreamItem, { kind: 'section' }>).section), final.sections);
    assert.deepEqual(reader.walkthrough(), final); assert.equal(reader.complete, true); assert.equal(reader.completed, 3);
    assert.equal(reader.length, json.length);
  }
  // Words or a fence around the object are ignored; sections before the summary; a cut-off object keeps its complete parts.
  const fenced = new FigureWalkthroughStream(14);
  assert.deepEqual(items(fenced, ['```json\n', JSON.stringify({ sections: streamInput.sections, summary: 'Last.' }), '\n``` and "more" {words}']).map(i => i.kind),
    ['section', 'section', 'summary']);
  const cut = new FigureWalkthroughStream(14), json2 = JSON.stringify(streamInput);
  const partial = items(cut, [json2.slice(0, json2.indexOf('"(b)"'))]);
  assert.deepEqual(partial.map(i => i.kind), ['summary', 'section']);
  assert.deepEqual(cut.walkthrough(), { format: 'figure-walkthrough-v1', summary: final.summary, sections: [final.sections[0]] });
  assert.equal(cut.complete, false);
  // A part whose object doesn't parse is not shown (the next one still is); nothing before the object counts as written.
  const broken = new FigureWalkthroughStream(14);
  const out = items(broken, ['Sure: {"summary": "S.", "sections": [{"label": "(a)", "title": "A", "text": "x", "box": [0, 0.1}, {"label": "(b)", "title": "B", "text": "y"}]}']);
  assert.deepEqual(out.map(i => i.kind === 'section' ? i.section.label : i.kind), ['summary', '(b)']);
  assert.equal(new FigureWalkthroughStream(14).length, 0);
  // The announced count, first: read as its digits end, in any chunking; a count outside 1–12 is not one.
  for (const size of [1, 3, 50]) {
    const counted = new FigureWalkthroughStream(14);
    const got = items(counted, chunks(JSON.stringify({ parts: 2, ...streamInput }), size));
    assert.deepEqual(got.map(i => i.kind), ['parts', 'summary', 'section', 'section'], `chunks of ${size}`);
    assert.deepEqual(got[0], { kind: 'parts', parts: 2 }); assert.equal(counted.parts, 2);
    assert.deepEqual(counted.walkthrough(), figureWalkthrough(streamInput, 14), 'the count is not part of the walkthrough');
  }
  for (const bad of [0, 13, 1000, '"3"']) {
    const reader = new FigureWalkthroughStream(14);
    assert.ok(!items(reader, [`{"parts": ${bad}, "summary": "S.", "sections": []}`]).some(i => i.kind === 'parts'), String(bad));
    assert.equal(reader.parts, null);
  }
});

test('the walkthrough streams to the device as JSON in the reply: summary, parts, progress, then the same final figure and done', async () => {
  const json = JSON.stringify({ parts: 2, ...streamInput }), final = figureWalkthrough(streamInput, 14)!;
  let clock = 0;
  const h = equationHarness({ generate: async (_params, stream) => {
    for (const piece of chunks(json, 40)) { clock += 100; stream.onText(piece); }
    return completeOutcome();
  } });
  h.deps.now = () => clock;
  await runChat(h.deps, figureBody(), h.emit, new AbortController().signal);
  const kinds = h.events.map(e => e.event);
  assert.equal(kinds[0], 'figure_progress'); assert.deepEqual(h.events[0].data, { stage: 'reading' });
  assert.deepEqual(kinds.filter(k => k !== 'figure_progress'), ['figure_summary', 'figure_section', 'figure_section', 'figure', 'done']);
  assert.ok(kinds.indexOf('figure_summary') < kinds.indexOf('figure_section'), 'the summary first');
  const writing = h.events.filter(e => e.event === 'figure_progress').slice(1).map(e => e.data as { stage: string; characters: number });
  assert.ok(writing.length >= 3 && writing.every(p => p.stage === 'writing'), 'progress while it is written');
  assert.ok(writing.every((p, i) => i === 0 || p.characters > writing[i - 1].characters), 'characters grow');
  assert.ok(writing.every(p => (p as { parts?: number }).parts === 2), 'every writing step carries the announced count (it is the first field)');
  assert.deepEqual(h.events.find(e => e.event === 'figure_summary')!.data, { summary: final.summary });
  const streamed = h.events.filter(e => e.event === 'figure_section').map(e => e.data as { index: number; section: unknown });
  assert.deepEqual(streamed.map(s => s.index), [0, 1]);
  // What a build that predates streaming reads: the one figure event, exactly the checked walkthrough.
  assert.deepEqual(h.events.find(e => e.event === 'figure')!.data, final);
  assert.deepEqual(streamed.map(s => s.section), final.sections, 'the streamed parts are the final parts');
  assert.ok(!kinds.includes('delta'), 'the JSON never reaches the device as words');
  assert.deepEqual(h.logs, [{ event: 'chat_figure_walkthrough', operation_id: operation, called: false, sections: 2, boxes: 2, boxes_offered: 2,
    source: 'text', streamed: 2, first_part_ms: 600 }]);
  assert.equal(settledWith(h).p_ending, 'completed'); assert.equal((h.events.at(-1)!.data as { charged: boolean }).charged, true);
});

test('a walkthrough written as a tool call streams the same way; cut off at its allowance it keeps the parts shown, not charged', async () => {
  const json = JSON.stringify(streamInput), final = figureWalkthrough(streamInput, 14)!;
  const h = equationHarness({ generate: async (_params, stream) => {
    for (const piece of chunks(json, 25)) stream.onToolInput?.({ index: 0, name: 'figure_walkthrough' }, piece);
    return walkthroughCall(streamInput);
  } });
  await runChat(h.deps, figureBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event).filter(k => k !== 'figure_progress'), ['figure_summary', 'figure_section', 'figure_section', 'figure', 'done']);
  assert.deepEqual(h.events.find(e => e.event === 'figure')!.data, final);
  assert.equal(h.logs[0].source, 'tool');
  // Another tool's input never streams as the walkthrough.
  const other = equationHarness({ generate: async (_params, stream) => { stream.onToolInput?.({ index: 0, name: 'create_visual' }, json); return completeOutcome(); } });
  await runChat(other.deps, figureBody(), other.emit, new AbortController().signal);
  assert.ok(!other.events.some(e => e.event === 'figure_section' || e.event === 'figure_summary'));
  // Cut off after the first part: the device keeps what it was shown (the final figure is those parts), and pays nothing.
  const cut = equationHarness({ generate: async (_params, stream) => { stream.onText(json.slice(0, json.indexOf('"(b)"'))); return completeOutcome({ stopReason: 'max_tokens' }); } });
  await runChat(cut.deps, figureBody(), cut.emit, new AbortController().signal);
  assert.deepEqual(cut.events.map(e => e.event).filter(k => k !== 'figure_progress'), ['figure_summary', 'figure_section', 'figure', 'done']);
  assert.deepEqual((cut.events.find(e => e.event === 'figure')!.data as { sections: unknown[] }).sections, [final.sections[0]]);
  assert.deepEqual([settledWith(cut).p_ending, settledWith(cut).p_actual_credits], ['limit', 0]);
  assert.deepEqual([(cut.events.at(-1)!.data as { charged: boolean }).charged, (cut.events.at(-1)!.data as { reason: string }).reason], [false, 'limit']);
  // An unreadable object is never shown as words: nothing to show, not charged.
  const garbled = equationHarness({ generate: async (_params, stream) => { stream.onText('{"summary": "S", "sections": [{"label'); return completeOutcome(); } });
  await runChat(garbled.deps, figureBody(), garbled.emit, new AbortController().signal);
  assert.deepEqual(garbled.events.map(e => e.event).filter(k => k !== 'figure_progress'), ['figure_summary', 'done']);
  assert.equal(settledWith(garbled).p_ending, 'provider');
});

test('the figure view thinks at low effort unless the reader chose an effort for a Claude model', async () => {
  assert.equal(figureViewEffort(null, 'low'), 'low');
  assert.equal(figureViewEffort({ model: 'gemini', effort: 'medium' }, 'medium'), 'low');
  assert.equal(figureViewEffort({ model: 'sonnet', effort: 'auto' }, 'medium'), 'low');
  assert.equal(figureViewEffort({ model: 'sonnet', effort: 'high' }, 'high'), 'high');
  const sent: Params[] = [];
  const h = equationHarness({ generate: async (params, stream) => { sent.push(params); stream.onText(JSON.stringify(streamInput));
    return completeOutcome({ model: 'gemini-3.8-flash', attempts: [{ model: 'gemini-3.8-flash', estimated: false, billedMicrousd: 9_000,
      usage: { input: 500, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 34_000, output: 1_400 } }] }); } });
  h.deps.gemini = true;
  const gemini = { model: 'gemini', effort: 'medium', length: 'standard' };
  for (const body of [figureBody({ profile: gemini }), figureBody({ action: 'figure_simpler', selection: { quote: 'The encoder.' }, profile: gemini }),
    figureBody({ profile: { model: 'sonnet', effort: 'auto', length: 'standard' } }), figureBody({ profile: { model: 'sonnet', effort: 'high', length: 'standard' } }),
    paperBody({ document_id: null, local_context: figureContext, consent_version: CONSENT, capabilities: FIGURE_DEVICE, profile: gemini })]) {
    await runChat(h.deps, body, h.emit, new AbortController().signal);
  }
  assert.deepEqual(sent.map(p => p.output_config?.effort), ['low', 'low', 'low', 'high', 'medium'], 'a chat question keeps the chat\'s effort');
  assert.equal(sent[0].max_tokens, figureMaxTokens('low'));
  assert.equal((openRouterChatParams(sent[0]).reasoning as { effort: string }).effort, 'low', 'Gemini is asked for low reasoning');
  assert.equal((openRouterChatParams(sent[4]).reasoning as { effort: string }).effort, 'medium');
  const quotes = h.calls.filter(c => c.name === 'worker_reserve_chat').map(c => (c.params.p_quote as Record<string, unknown>));
  assert.deepEqual(quotes.map(q => [q.profile, q.effort]), [['gemini-low-standard', 'low'], ['gemini-low-standard', 'low'], ['sonnet-low-standard', 'low'],
    ['sonnet-high-standard', 'high'], ['gemini-medium-standard', 'medium']]);
  // The cached prefix is the chat's whatever the effort (Gemini caches the system message; Claude's thinking is adaptive).
  const prefix = (p: Params) => JSON.stringify({ model: p.model, thinking: p.thinking, tools: p.tools, system: (p.system as unknown[]).slice(0, 2) });
  assert.equal(prefix(sent[0]), prefix(sent[4]));
  // DeepSeek at low effort writes the figure view without thinking (its route has no cache); a chat question keeps it.
  const deep: Params[] = [];
  const d = equationHarness({ generate: async (params, stream) => { deep.push(params); stream.onText(JSON.stringify(streamInput)); return completeOutcome(); } });
  d.deps.deepseek = true;
  const deepseek = (effort: string) => ({ model: 'deepseek', effort, length: 'standard' });
  for (const body of [figureBody({ profile: deepseek('auto'), consent_version: 'cloud-ai-v6' }), figureBody({ profile: deepseek('medium'), consent_version: 'cloud-ai-v6' }),
    paperBody({ document_id: null, local_context: figureContext, consent_version: 'cloud-ai-v6', capabilities: FIGURE_DEVICE, profile: deepseek('low') })]) {
    await runChat(d.deps, body, d.emit, new AbortController().signal);
  }
  assert.deepEqual(deep.map(p => [p.output_config?.effort, p.thinking?.type]), [['low', 'disabled'], ['medium', 'adaptive'], ['low', 'adaptive']]);
  assert.deepEqual(openRouterChatParams(deep[0]).reasoning, { enabled: false });
  // The figures activity's published default: Sonnet at low effort (owner, 2026-10-22).
  assert.deepEqual(publishedProfiles({ deepseek: true, gemini: true }).default_figures, { model: 'sonnet', effort: 'low', length: 'standard' });
  assert.equal(publishedProfiles({ deepseek: true, gemini: true, available: model => !model.includes('sonnet') }).default_figures, undefined, 'not offered without Sonnet');
});

// One part extracted (owner, TestFlight 62: "Extract the subfigure and more context"): `figure_detail`, the walkthrough's
// tool with one section and its box required, on the chat's cached prefix. Deprecated 2026-10-21 (removed from every
// client); these tests keep it working for already-installed builds 63–79 until it is removed (FIGURE_VIEW.md).
const detailBody = (overrides: Record<string, unknown> = {}) => figureBody({ action: 'figure_detail',
  selection: { quote: '(a) The RLHF pipeline\nThree stages: a reward model, then RL [¶12].' }, messages: [{ role: 'user', text: 'Figure 2 (a)' }], ...overrides });
const detailInput = (box: unknown = { x: 0.02, y: 0.1, w: 0.45, h: 0.5 }) => ({ summary: 'The left half: the RLHF pipeline.', sections: [
  { label: '(a)', title: 'The RLHF pipeline', text: 'Up close: three boxes left to right [¶12]; the reward model is fit first [¶13].', paragraphs: [12], box },
  { label: '(b)', title: 'Ignored', text: 'A second section is not the part asked for.', paragraphs: [] }] });

test('figure_detail: validated like the figure view, the chat\'s cached prefix, its own instructions and allowance', async () => {
  assert.equal(validateChatRequest(detailBody()).action, 'figure_detail');
  for (const bad of [detailBody({ figures: undefined }), detailBody({ capabilities: ['visual_answers', 'figure_requests'] }), detailBody({ consent_version: 'cloud-ai-v2' }),
    detailBody({ follow_ups: true }), detailBody({ topic_title: true })]) assert.throws(() => validateChatRequest(bad), /invalid_request/);
  const seen: Params[] = [];
  const h = equationHarness({ generate: async (params, stream) => { seen.push(params); stream.onText('Words.'); return completeOutcome(); } });
  searching(h, []);
  const device = { document_id: null, local_context: figureContext, consent_version: CONSENT, capabilities: FIGURE_DEVICE };
  for (const body of [paperBody({ ...device, messages: [{ role: 'user', text: 'What does the method optimize?' }] }), detailBody()]) {
    await runChat(h.deps, body, h.emit, new AbortController().signal);
  }
  const [chat, detail] = seen;
  const prefix = (p: Params) => Buffer.from(JSON.stringify({ model: p.model, thinking: p.thinking, tools: p.tools, system: (p.system as unknown[]).slice(0, 2) }));
  assert.ok(prefix(detail).equals(prefix(chat)), 'the cached prefix (tools, model, thinking, shared instructions, paper) is the chat\'s');
  assert.equal(detail.tool_choice, undefined);
  const after = (detail.system as { text: string }[])[2].text;
  assert.match(after, /asked to extract one part of it/); assert.match(after, /Include the complete relevant panel/); assert.match(after, /exactly one section/);
  assert.equal(detail.max_tokens, figureDetailMaxTokens('low'));
  const last = detail.messages.at(-1)!.content as { type: string; text?: string }[];
  assert.deepEqual(last.map(b => b.type), ['text', 'text', 'image', 'text']);
  assert.match(last[0].text!, /\(a\) The RLHF pipeline/);
});

test('figure_detail input: the first section with its box; no usable box is no detail', () => {
  assert.deepEqual(figureDetail(detailInput(), 14), { format: 'figure-detail-v1', label: '(a)', title: 'The RLHF pipeline',
    text: 'Up close: three boxes left to right [¶12]; the reward model is fit first [¶13].', paragraphs: [12, 13], box: { x: 0.02, y: 0.1, w: 0.45, h: 0.5 } });
  for (const bad of [null, { x: 0, y: 0, w: 1, h: 1 }, { x: 0.9, y: 0.9, w: 0.02, h: 0.05 }, { x: 0.5, y: 0.5, w: 0.7, h: 0.2 }]) {
    assert.equal(figureDetail(detailInput(bad), 14), null, JSON.stringify(bad));
  }
  const { box: _none, ...boxless } = detailInput().sections[0];
  assert.equal(figureDetail({ summary: 's', sections: [boxless] }, 14), null, 'a section without a box');
  for (const bad of [null, [], 'x', {}, { sections: [] }, { sections: ['x', { label: 'a' }] }]) assert.equal(figureDetail(bad, 14), null, JSON.stringify(bad));
});

test('figure_detail: relayed once with its box and charged; without a box its words, no crop; nothing shown is not charged', async () => {
  const h = equationHarness({ generate: async (_params, stream) => { stream.onText('Looking closely.'); return walkthroughCall(detailInput()); } });
  await runChat(h.deps, detailBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['figure_detail', 'done'], 'no words and no tool result reach the device');
  assert.deepEqual((h.events[0].data as { box: unknown }).box, { x: 0.02, y: 0.1, w: 0.45, h: 0.5 });
  assert.deepEqual(h.logs, [{ event: 'chat_figure_detail', operation_id: operation, called: true, boxes_offered: 1 }]);
  assert.deepEqual([settledWith(h).p_action, settledWith(h).p_ending], ['figure_detail', 'completed']); assert.ok(Number(settledWith(h).p_actual_credits) > 0);
  // The whole figure as its box (no crop to make): the part's words, once, charged.
  const whole = equationHarness({ generate: async () => walkthroughCall(detailInput({ x: 0, y: 0, w: 1, h: 1 })) });
  await runChat(whole.deps, detailBody(), whole.emit, new AbortController().signal);
  assert.deepEqual(whole.events.map(e => e.event), ['delta', 'done']);
  assert.match((whole.events[0].data as { text: string }).text, /^The left half: the RLHF pipeline\.\n\n\*\*\(a\) The RLHF pipeline\*\*/);
  assert.equal(whole.logs[0].event, 'chat_figure_detail_invalid_output'); assert.equal(settledWith(whole).p_ending, 'completed');
  // No call, only words: the words.
  const words = equationHarness({ generate: async (_params, stream) => { stream.onText('The left half up close [¶12].'); return completeOutcome(); } });
  await runChat(words.deps, detailBody(), words.emit, new AbortController().signal);
  assert.deepEqual(words.events.map(e => e.event), ['delta', 'done']); assert.deepEqual(words.events[0].data, { text: 'The left half up close [¶12].' });
  // Nothing at all: the provider's, not charged.
  const empty = equationHarness({ generate: async () => walkthroughCall({}) });
  await runChat(empty.deps, detailBody(), empty.emit, new AbortController().signal);
  assert.deepEqual(empty.events.map(e => e.event), ['done']);
  assert.deepEqual([settledWith(empty).p_action, settledWith(empty).p_ending, settledWith(empty).p_actual_credits], ['figure_detail', 'provider', 0]);
  // Cut off at its allowance: our limit, not charged.
  const cut = equationHarness({ generate: async (_params, stream) => { stream.onText('Partial'); return completeOutcome({ stopReason: 'max_tokens' }); } });
  await runChat(cut.deps, detailBody(), cut.emit, new AbortController().signal);
  assert.deepEqual([settledWith(cut).p_ending, settledWith(cut).p_actual_credits], ['limit', 0]);
});

test('figure_simpler streams words like an answer; tool calls are never relayed; a stray walkthrough in a chat answer becomes its words', async () => {
  const simpler = equationHarness({ generate: async (_params, stream) => { stream.onText('Think of the left half'); stream.onText(' as the old way [¶12].');
    return completeOutcome({ stopReason: 'tool_use', toolCalls: [{ id: 't1', name: 'figure_walkthrough', input: { summary: 's', sections: [{ label: 'a', title: 't', text: 'x', paragraphs: [] }] } }] }); } });
  await runChat(simpler.deps, figureBody({ action: 'figure_simpler', selection: { quote: 'The RLHF pipeline has three stages [¶12].' } }), simpler.emit, new AbortController().signal);
  assert.deepEqual(simpler.events.map(e => e.event), ['delta', 'delta', 'done']);
  assert.equal(settledWith(simpler).p_action, 'figure_simpler'); assert.equal(settledWith(simpler).p_ending, 'completed');
  // A part again with nothing written (only a tool call): nothing shown, not charged.
  const silent = equationHarness({ generate: async () => walkthroughCall({ summary: 's', sections: [{ label: 'a', title: 't', text: 'x', paragraphs: [] }] }) });
  await runChat(silent.deps, figureBody({ action: 'figure_simpler' }), silent.emit, new AbortController().signal);
  assert.deepEqual([settledWith(silent).p_ending, settledWith(silent).p_actual_credits], ['provider', 0]);
  // An ordinary answer that called the view's tool anyway: never a `figure` event; with no words of its own, its words.
  const chat = equationHarness({ generate: async () => walkthroughCall({ summary: 'S.', sections: [{ label: '(a)', title: 'A', text: 'T [¶2].', paragraphs: [2] }] }) });
  await runChat(chat.deps, paperBody({ document_id: null, local_context: figureContext, consent_version: CONSENT, capabilities: FIGURE_DEVICE }), chat.emit, new AbortController().signal);
  assert.deepEqual(chat.events.map(e => e.event), ['delta', 'done']); assert.deepEqual(chat.events[0].data, { text: 'S.\n\n**(a) A**\n\nT [¶2].' });
});

// Resilience (docs/architecture/RESILIENCE.md, fixes 6 and 7): one more try when the provider refused an answer as busy
// before starting it, and the reader told how long to wait when it still can't run.
const refusedBefore = (changes: Partial<ProviderOutcome>): ProviderOutcome => ({ status: 'failed', failure: 'provider_error', messageID: null, model: null,
  stopReason: null, refusalCategory: null, attempts: [], exact: true, ...changes });
test('busy (429) or overloaded (529) before the answer starts: one more try after Retry-After, within 5 s; nothing else retries', async () => {
  const run = async (outcomes: ProviderOutcome[], aborted = false) => {
    const waits: number[] = []; let calls = 0;
    const controller = new AbortController(); if (aborted) controller.abort();
    const generate = retryOnceWhenBusy(async () => outcomes[Math.min(calls++, outcomes.length - 1)],
      { sleep: async ms => { waits.push(ms); }, random: () => 0.5 });
    const outcome = await generate(params(), { signal: controller.signal, onText: () => {}, inputEstimateTokens: 1 });
    return { outcome, calls, waits };
  };
  const busy = await run([refusedBefore({ httpStatus: 429, retryAfterMs: 1_500 }), completeOutcome()]);
  assert.deepEqual([busy.outcome.status, busy.calls, busy.waits], ['complete', 2, [1_500]]);
  const overloaded = await run([refusedBefore({ httpStatus: 529, retryAfterMs: null }), completeOutcome()]);
  assert.deepEqual([overloaded.calls, overloaded.waits], [2, [2_000]], 'no Retry-After: 1–3 s');
  const twice = await run([refusedBefore({ httpStatus: 429, retryAfterMs: 500 })]);
  assert.deepEqual([twice.calls, twice.waits], [2, [500]], 'once only');
  for (const [label, first] of Object.entries({
    'a long Retry-After (a breaker cool-off)': refusedBefore({ httpStatus: 429, retryAfterMs: BUSY_RETRY_MAX_MS + 1 }),
    'a 500': refusedBefore({ httpStatus: 500 }),
    'after the first token': refusedBefore({ httpStatus: 529, messageID: 'msg_x' }),
    'a refusal of the request itself': refusedBefore({ httpStatus: 400, failure: 'provider_rejected' }),
  })) assert.equal((await run([first, completeOutcome()])).calls, 1, label);
  assert.equal((await run([refusedBefore({ httpStatus: 429, retryAfterMs: 100 }), completeOutcome()], true)).calls, 1, 'not after the reader left');
});
test('an answer that can\'t run says how long to wait (the provider\'s Retry-After, else a default)', async () => {
  const waited = harness({ generate: async () => refusedBefore({ httpStatus: 429, retryAfterMs: 30_000 }) });
  await runChat(waited.deps, paperBody(), waited.emit, new AbortController().signal);
  assert.deepEqual(waited.events.find(e => e.event === 'error')?.data, { code: 'provider_unavailable', credits: 0, charged: false, reason: 'provider', retry_after: 30 });
  const plain = harness({ generate: async () => refusedBefore({}) });
  await runChat(plain.deps, paperBody(), plain.emit, new AbortController().signal);
  assert.equal((plain.events.find(e => e.event === 'error')?.data as { retry_after?: number }).retry_after, 10);
});

test('the paper is cached for an hour: held at the one-hour write rate, settled at it, and the turn marker stays five minutes', () => {
  const params = chatRequestParams({ instructions: 'Answer.', paper: { title: 'P', text: 'x '.repeat(20_000) }, turns: [{ role: 'user', text: 'Q' }], selection: null,
    model: { id: SONNET, effort: 'low' } });
  const paperBlock = (params.system as { cache_control?: { ttl?: string } }[])[1];
  assert.equal(PAPER_CACHE_TTL, '1h'); assert.deepEqual(paperBlock.cache_control, { type: 'ephemeral', ttl: '1h' });
  assert.ok(hourCachedCharacters(params) > 0 && hourCachedCharacters(params) < promptCharacters(params));
  const hourHold = holdForParams(params).microusd, fiveMinuteHold = holdFor(promptCharacters(params) + 3 * 1024, params.max_tokens, params.model).microusd;
  assert.ok(hourHold > fiveMinuteHold, 'a one-hour write costs more, and the hold covers it');
  const rates = ratesFor(SONNET, 1000).rates;
  const priced = priceAttempts([{ model: SONNET, estimated: false, usage: { input: 0, cacheWrite5m: 0, cacheWrite1h: 1000, cacheRead: 0, output: 0 } }]);
  assert.equal(priced, 1000 * rates.cacheWrite1h, 'settlement prices one-hour writes at their own rate');
});

// ---------- Automatic effort and DeepSeek (2026-10-16, CHAT.md "Chat redesign from build 57 feedback") ----------
/** The consent that names DeepSeek's OpenRouter route (DeepInfra): v6. */
const v6 = (body: Record<string, unknown>) => ({ ...body, consent_version: 'cloud-ai-v6' });
type Params = ModelRequest;
function sending(sent: Params[], outcome: (params: Params) => ProviderOutcome = params => completeOutcome({ model: params.model,
  attempts: [{ model: params.model, estimated: false, usage: { input: 900, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 300 } }] })) {
  return async (params: Params, stream: StreamOptions) => { sent.push(params); stream.onText('An answer.'); return outcome(params); };
}

test('auto effort is resolved from the question before the hold; the quote, the request and the answer carry the resolved profile', async () => {
  const run = async (profile: Record<string, string>, question: string) => {
    const sent: Params[] = [];
    const h = harness({ generate: sending(sent) });
    const body = paperBody({ profile, messages: [{ role: 'user', text: question }] });
    await runChat(h.deps, body, h.emit, new AbortController().signal);
    const reserve = h.calls.find(c => c.name === 'worker_reserve_chat')!.params;
    return { sent, reserve, quote: reserve.p_quote as Record<string, unknown>, done: h.events.at(-1)!, answers: h.answers, body };
  };
  const why = await run({ model: 'sonnet', effort: 'auto', length: 'standard' }, 'Why does DPO need a reference model?');
  assert.equal(why.sent[0].model, SONNET); assert.deepEqual(why.sent[0].output_config, { effort: 'medium' }); assert.equal(why.sent[0].max_tokens, 10_000);
  assert.deepEqual([why.quote.profile, why.quote.effort, why.quote.max_output_tokens], ['sonnet-medium-standard', 'medium', 10_000]);
  assert.equal(why.done.event, 'done');
  assert.equal((why.done.data as { profile: string }).profile, 'sonnet-medium-standard'); assert.equal((why.done.data as { effort: string }).effort, 'medium');
  assert.equal(why.answers[0].profile, 'sonnet-medium-standard'); assert.equal(why.answers[0].auto_effort, true);
  // The same hold as asking for Medium outright, but its own request (and digest): the body said `auto`.
  const medium = await run({ model: 'sonnet', effort: 'medium', length: 'standard' }, 'Why does DPO need a reference model?');
  assert.equal(why.reserve.p_microusd, medium.reserve.p_microusd); assert.equal(why.reserve.p_credits, medium.reserve.p_credits);
  assert.notEqual(why.reserve.p_request_sha256, medium.reserve.p_request_sha256);
  assert.equal((medium.done.data as { effort?: string }).effort, undefined, 'only an `auto` request is told which effort was picked');
  assert.match(canonicalRequest(validateChatRequest(why.body)), /"effort":"auto"/);
  // A plain question stays at Low; Brief is always Low; Detailed asks for reasoning at High.
  const plain = await run({ model: 'sonnet', effort: 'auto', length: 'standard' }, 'What dataset do they use?');
  assert.deepEqual([plain.quote.profile, (plain.done.data as { effort: string }).effort], ['sonnet-low-standard', 'low']);
  assert.notEqual(plain.reserve.p_request_sha256, (await run({ model: 'sonnet', effort: 'low', length: 'standard' }, 'What dataset do they use?')).reserve.p_request_sha256,
    'auto and the default are different requests even when auto picks low');
  assert.equal((await run({ model: 'haiku', effort: 'auto', length: 'brief' }, 'Derive the loss step by step.')).quote.profile, 'haiku-low-brief');
  const deep = await run({ model: 'opus', effort: 'auto', length: 'detailed' }, 'Derive the loss step by step.');
  assert.deepEqual([deep.quote.profile, deep.sent[0].max_tokens, deep.sent[0].output_config], ['opus-high-detailed', 18_000, { effort: 'high' }]);
  // A diagram repair still takes no profile, auto included.
  assert.throws(() => validateChatRequest({ operation_id: operation, consent_version: 'cloud-ai-v2', mode: 'general', action: 'diagram_fix',
    messages: [{ role: 'user', text: 'Title: x' }], profile: { model: 'sonnet', effort: 'auto', length: 'standard' } }), { code: 'invalid_request' });
});

test('auto reads the equation selection and attached figures', async () => {
  const sent: Params[] = [];
  const h = harness({ generate: sending(sent) });
  await runChat(h.deps, paperBody({ profile: { model: 'sonnet', effort: 'auto', length: 'standard' }, selection: { quote: '\\pi^*(y|x) = \\frac{1}{Z(x)} \\pi_{ref}(y|x)' },
    messages: [{ role: 'user', text: 'What does this say?' }] }), h.emit, new AbortController().signal);
  assert.deepEqual(sent[0].output_config, { effort: 'medium' });
  const pictured = harness({ generate: sending(sent) });
  await runChat(pictured.deps, { ...paperBody({ profile: { model: 'sonnet', effort: 'auto', length: 'standard' }, messages: [{ role: 'user', text: 'What does Figure 2 show?' }] }),
    consent_version: CONSENT, figures: [figure()] }, pictured.emit, new AbortController().signal);
  assert.deepEqual(sent[1].output_config, { effort: 'medium' });
});

test('DeepSeek needs consent v6 (its OpenRouter route) and the server switch; refusals come before any hold', async () => {
  const choice = { profile: { model: 'deepseek', effort: 'auto', length: 'standard' } };
  for (const consent of ['cloud-ai-v1', 'cloud-ai-v2', 'cloud-ai-v3']) {
    assert.throws(() => validateChatRequest({ ...paperBody(choice), consent_version: consent }), { code: 'consent_required' }, consent);
  }
  for (const consent of ['cloud-ai-v1', 'cloud-ai-v2', 'cloud-ai-v3', 'cloud-ai-v4', 'cloud-ai-v5']) {
    const h = harness({ generate: sending([]) }); h.deps.deepseek = true;
    await runChat(h.deps, { ...paperBody(choice), consent_version: consent }, h.emit, new AbortController().signal);
    assert.deepEqual(h.events, [{ event: 'error', data: { code: 'consent_required' } }], consent);
    assert.deepEqual(names(h.calls), ['worker_consume_request'], 'rate-limited, then refused before any hold');
  }
  // Switched off (or no key): the choice is not one the server offers.
  const off = harness({ generate: sending([]) });
  await runChat(off.deps, v6(paperBody(choice)), off.emit, new AbortController().signal);
  assert.deepEqual(off.events, [{ event: 'error', data: { code: 'invalid_request' } }]);
  assert.ok(!names(off.calls).includes('worker_reserve_chat'));
  // v6 changes nothing for a Claude answer: figures and Tavily stay named.
  assert.equal(validateChatRequest(v6(paperBody({ figures: [figure()] }))).figures.length, 1);
});

test('a DeepSeek answer: its OpenRouter model, figures kept, no provider search tool, its DeepInfra card, usage under OpenRouter', async () => {
  const sent: Params[] = [];
  const h = harness({ generate: sending(sent) });
  h.deps.deepseek = true; h.deps.webSearch = true;
  await runChat(h.deps, v6({ ...paperBody({ profile: { model: 'deepseek', effort: 'auto', length: 'standard' }, topic_title: true,
    messages: [{ role: 'user', text: 'What does Figure 2 show?' }] }), figures: [figure()] }), h.emit, new AbortController().signal);
  const answer = sent.find(p => p.model === FLASH)!;
  assert.ok(answer, 'the answer went to DeepSeek V4.1 Flash through OpenRouter');
  assert.deepEqual(answer.output_config, { effort: 'medium' }); assert.deepEqual(answer.thinking, { type: 'adaptive' }); assert.equal(answer.max_tokens, 10_000);
  assert.equal((answer as Record<string, unknown>).fallbacks, undefined); assert.equal((answer as Record<string, unknown>).betas, undefined);
  const tools = (answer.tools ?? []).map(t => (t as { name: string }).name);
  assert.ok(!tools.includes('web_search'), 'never a provider-native search tool');
  assert.ok(tools.includes('show_figure_parts'));
  const last = answer.messages.at(-1)!.content as { type: string; source?: { media_type: string } }[];
  assert.equal(last.find(b => b.type === 'image')?.source?.media_type, 'image/jpeg', 'the figure goes with the question');
  // The title stays on Claude Haiku (through OpenRouter).
  assert.ok(sent.some(p => p.model === HAIKU));
  const reserve = h.calls.find(c => c.name === 'worker_reserve_chat')!.params, quote = reserve.p_quote as Record<string, unknown>;
  assert.deepEqual([quote.profile, quote.model, quote.effort, quote.tariff, quote.max_searches], ['deepseek-medium-standard', FLASH, 'medium', ROUTER_DEEPSEEK_TARIFF, 0]);
  // Held at DeepSeek's own card (twice, for the uncounted tokenizer), far below a Sonnet hold for the same question.
  const sonnet = harness({ generate: sending([]) });
  await runChat(sonnet.deps, v6({ ...paperBody({ profile: { model: 'sonnet', effort: 'medium', length: 'standard' }, topic_title: true,
    messages: [{ role: 'user', text: 'What does Figure 2 show?' }] }), figures: [figure()] }), sonnet.emit, new AbortController().signal);
  const sonnetHold = Number(sonnet.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_microusd);
  assert.ok(Number(reserve.p_microusd) * 4 < sonnetHold, `${reserve.p_microusd} vs ${sonnetHold}`);
  // Without a reported cost: 900 uncached input and 300 output at the DeepInfra card, plus the title's Haiku tokens at its card.
  const flash = routerDeepSeekRates(FLASH), haiku = routerClaudeRates(HAIKU);
  const settle = h.calls.find(c => c.name === 'worker_settle_chat')!.params;
  assert.equal(settle.p_actual_microusd, Math.ceil(900 * flash.input + 300 * flash.output + 900 * haiku.input + 300 * haiku.output));
  const usage = h.calls.find(c => c.name === 'worker_record_provider_usage')!.params;
  assert.equal(usage.p_provider, 'openrouter');
  const done = h.events.find(e => e.event === 'done')!.data as { profile: string; model: string; effort: string };
  assert.deepEqual([done.profile, done.model, done.effort], ['deepseek-medium-standard', 'deepseek-flash', 'medium'], 'the stable client model name');
  assert.deepEqual([h.answers[0].provider, h.answers[0].search_provider], ['openrouter', 'none']);
});

test('DeepSeek searches only through our search_web tool (Tavily), never a provider-native search', async () => {
  const sent: Sent[] = [];
  const deepseekRound = (output: number) => [{ model: FLASH, estimated: false, usage: { input: 900, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output } }];
  const h = harness({ generate: async (params, stream) => {
    sent.push(structuredClone(params) as unknown as Sent);
    if (sent.length === 1) { stream.onText('Let me look.'); return { ...searchRound([{ id: 'toolu_s1', input: { query: 'IPO', academic: true } }]), model: FLASH, attempts: deepseekRound(120) }; }
    stream.onText('IPO is related.'); return completeOutcome({ model: FLASH, attempts: deepseekRound(100) });
  } });
  h.deps.deepseek = true;
  searching(h, [found]);
  await runChat(h.deps, v6(paperBody({ profile: { model: 'deepseek', effort: 'low', length: 'standard' }, action: 'related', selection: { quote: 'preference optimization' } })),
    h.emit, new AbortController().signal);
  const tools = sent[0].tools!.map(t => t.name);
  assert.ok(tools.includes('search_web') && !tools.includes('web_search'));
  assert.equal(h.answers[0].search_provider, 'tavily'); assert.equal(h.answers[0].tavily_searches, 1);
  let rounds = 0;
  const failing = harness({ generate: async (params, stream) => {
    rounds++;
    if (rounds === 1) return { ...searchRound([{ id: 'toolu_s1', input: { query: 'IPO' } }]), model: FLASH, attempts: deepseekRound(120) };
    assert.ok(!(params.tools ?? []).some(t => 'name' in t && t.name === 'web_search'), 'no provider-native search appears');
    stream.onText('Without search.'); return completeOutcome({ model: FLASH, attempts: deepseekRound(100) });
  } });
  failing.deps.deepseek = true;
  searching(failing, [{ status: 'failed', failure: 'unavailable', retryAfterMs: null }]);
  await runChat(failing.deps, v6(paperBody({ profile: { model: 'deepseek', effort: 'low', length: 'standard' } })), failing.emit, new AbortController().signal);
  assert.equal(rounds, 2); assert.equal(failing.answers[0].search_failures, 1);
});

// ---------------------------------------------------------------------------------------------------------------------
// When an answer stops early (owner decision 2026-10-16, docs/architecture/CHAT.md): the reader pays for work that
// finishes, or for the part of an answer they chose to stop; anything else that ends it costs them nothing.
// ---------------------------------------------------------------------------------------------------------------------
const settledWith = (h: ReturnType<typeof harness>) => h.calls.find(c => c.name === 'worker_settle_chat')!.params;
const aborted = (usage: { input: number; output: number }, messageID: string | null = 'msg_stop'): ProviderOutcome => ({ status: 'failed', failure: 'aborted',
  messageID, model: messageID ? SONNET : null, stopReason: null, refusalCategory: null,
  attempts: [{ model: messageID ? SONNET : null, estimated: true, usage: { cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, ...usage },
    // The adapter's observation of what was written (here 1,000 input at $2 + 100 output at $10 = 3,000), below the
    // estimate's liability at the Sonnet card ($2.20 and $11: 3,300), which stays in the platform's spend.
    readerMicrousd: messageID ? usage.input * 2 + usage.output * 10 : 0 }], exact: false });

test('stop_signal is a known capability; builds that send it are told apart from those that do not', () => {
  assert.deepEqual(validateChatRequest(paperBody({ capabilities: ['stop_signal', 'visual_answers'] })).capabilities, ['stop_signal', 'visual_answers']);
  assert.notEqual(canonicalRequest(validateChatRequest(paperBody({ capabilities: ['visual_answers'] }))),
    canonicalRequest(validateChatRequest(paperBody({ capabilities: ['stop_signal', 'visual_answers'] }))));
});

test('a Stop the app recorded (v1_chat_stop) is charged for what the answer used; the title it never showed is Gradstep\'s', async () => {
  const client = new AbortController();
  const h = harness({ script: { worker_chat_stop_requested: params => { assert.equal(params.p_operation_id, operation); return true; } },
    generate: async (params, stream) => {
      if (params.max_tokens === 40) { stream.onText('A title'); return titleOutcome(); }
      stream.onText('partial '); client.abort(); return aborted({ input: 1000, output: 100 });
    } });
  await runChat(h.deps, paperBody({ capabilities: ['stop_signal', 'visual_answers'], topic_title: true }), h.emit, client.signal);
  assert.deepEqual(h.events, [{ event: 'delta', data: { text: 'partial ' } }], 'nothing is sent after the reader left');
  // The written part (3,000 micro-USD) -> 1 credit; the rest of the estimate (300) and the title's 44 micro-USD are absorbed.
  assert.deepEqual(settledWith(h), { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 3_344,
    p_action: 'answer', p_ending: 'stopped', p_absorbed_microusd: 344 });
  assert.equal(h.calls.filter(c => c.name === 'worker_chat_stop_requested').length, 1);
  assert.equal(h.answers[0].ending, 'stopped'); assert.equal(h.answers[0].charged, true);
});

test('a dropped connection (stop_signal, no Stop recorded) charges nothing; a Stop record still arriving gets one more look', async () => {
  const cases: [string, (look: number) => unknown, string, number][] = [
    ['no record', () => false, 'connection', 0],
    ['recorded on the second look', look => look === 2, 'stopped', 1],
    ['the record cannot be read', () => { throw new Error('transport'); }, 'connection', 0],
  ];
  for (const [label, answer, ending, credits] of cases) {
    const client = new AbortController(), waits: number[] = [];
    let looks = 0;
    const h = harness({ script: { worker_chat_stop_requested: () => answer(++looks) },
      generate: async (_params, stream) => { stream.onText('partial '); client.abort(); return aborted({ input: 1000, output: 100 }); } });
    h.deps.sleep = async ms => { waits.push(ms); };
    await runChat(h.deps, paperBody({ capabilities: ['stop_signal'] }), h.emit, client.signal);
    const settle = settledWith(h);
    assert.equal(settle.p_ending, ending, label); assert.equal(settle.p_actual_credits, credits, label);
    assert.equal(settle.p_absorbed_microusd, credits ? 300 : 3_300, label);
    assert.equal(looks, 2, `${label}: two looks`); assert.deepEqual(waits, [1_500], `${label}: one short wait between them`);
  }
});

test('a Stop before the provider started anything charges nothing', async () => {
  const client = new AbortController();
  const h = harness({ script: { worker_chat_stop_requested: () => true },
    generate: async () => { client.abort(); return aborted({ input: 1000, output: 0 }, null); } });
  await runChat(h.deps, paperBody({ capabilities: ['stop_signal'] }), h.emit, client.signal);
  const settle = settledWith(h);
  assert.equal(settle.p_ending, 'stopped'); assert.equal(settle.p_actual_credits, 0); assert.equal(settle.p_absorbed_microusd, settle.p_actual_microusd);
});

test('an answer cut off at its length (max_tokens) charges nothing, asks for no suggestions and says why in done', async () => {
  const h = harness({ generate: async (_params, stream) => { stream.onText('A long answer that runs out'); return completeOutcome({ stopReason: 'max_tokens' }); } });
  await runChat(h.deps, paperBody({ follow_ups: true }), h.emit, new AbortController().signal);
  assert.equal(h.generations(), 1, 'no follow-up request for an unfinished answer');
  assert.deepEqual(h.events.at(-1), { event: 'done', data: { stop_reason: 'max_tokens', credits: 0,
    usage: { input_tokens: 900, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 300 },
    model: 'claude-sonnet-5-5', profile: 'sonnet-low-standard', charged: false, reason: 'limit' } });
  assert.deepEqual(settledWith(h), { p_account_id: account, p_id: operation, p_actual_credits: 0, p_actual_microusd: 4_800,
    p_action: 'answer', p_ending: 'limit', p_absorbed_microusd: 4_800 });
});

test('a completed answer pays for itself and what was relayed; a failed title is Gradstep\'s', async () => {
  const h = harness({ generate: async (params, stream) => {
    if (params.max_tokens === 40) return titleOutcome({ status: 'failed', failure: 'provider_error', stopReason: null, exact: false });
    if (params.tools?.some(tool => 'name' in tool && tool.name === 'suggest_follow_ups')) return followUpOutcome(['Why is the reference model frozen?', 'What breaks without the KL term?']);
    stream.onText('The answer.'); return completeOutcome();
  } });
  await runChat(h.deps, paperBody({ topic_title: true, follow_ups: true }), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['delta', 'followups', 'done']);
  // Answer 4,800 + suggestions (500 x $0.10 + 60 x $0.50 = 80) are charged; the failed title's 44 are absorbed.
  assert.deepEqual(settledWith(h), { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 4_924,
    p_action: 'answer', p_ending: 'completed', p_absorbed_microusd: 44 });
  assert.equal((h.events.at(-1)!.data as { charged: boolean }).charged, true);
});

test('A12: a finished answer stays charged when the connection drops during its suggestions; the unrelayed suggestions are Gradstep\'s', async () => {
  const client = new AbortController();
  let stopLooks = 0;
  const h = harness({ script: { worker_chat_stop_requested: () => { stopLooks++; return false; } },
    generate: async (params, stream) => {
      if (params.tools?.some(tool => 'name' in tool && tool.name === 'suggest_follow_ups')) {
        client.abort(); // the reader's connection drops after the whole answer arrived, before `done`
        return followUpOutcome(['Why is the reference model frozen?', 'What breaks without the KL term?']);
      }
      stream.onText('The answer.'); return completeOutcome();
    } });
  await runChat(h.deps, paperBody({ capabilities: ['stop_signal'], follow_ups: true }), h.emit, client.signal);
  // The answer's 4,800 micro-USD are charged (1 credit); the suggestions' 80 were never relayed and are absorbed.
  assert.deepEqual(settledWith(h), { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 4_880,
    p_action: 'answer', p_ending: 'completed', p_absorbed_microusd: 80 });
  assert.equal(stopLooks, 0, 'a finished answer needs no Stop lookup');
  assert.deepEqual(h.events.map(e => e.event), ['delta'], 'nothing is sent after the reader left');
});

test('A12: a reader who leaves during the title grace after a finished answer still pays for it', async () => {
  const client = new AbortController();
  const h = harness({ generate: async (params, stream) => {
    if (params.max_tokens === 40) { await new Promise(resolve => setTimeout(resolve, 5)); client.abort(); return titleOutcome(); }
    stream.onText('The answer.'); return completeOutcome();
  } });
  await runChat(h.deps, paperBody({ capabilities: ['stop_signal'], topic_title: true }), h.emit, client.signal);
  const settle = settledWith(h);
  assert.equal(settle.p_ending, 'completed'); assert.equal(settle.p_actual_credits, 1);
});

test('a finished turn with nothing to show charges nothing (the provider\'s)', async () => {
  const h = harness({ generate: async () => completeOutcome() });
  await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events.map(e => e.event), ['done']);
  const done = h.events[0].data as { credits: number; charged: boolean; reason: string };
  assert.deepEqual([done.credits, done.charged, done.reason], [0, false, 'provider']);
  assert.equal(settledWith(h).p_ending, 'provider');
});

test('our own limit and our own server are named: provider_unavailable/limit and service_unavailable/server, nothing charged', async () => {
  for (const [cause, code] of [['limit', 'provider_unavailable'], ['server', 'service_unavailable']] as const) {
    const h = harness({ generate: async (_params, stream) => { stream.onText('Half'); return { ...aborted({ input: 900, output: 50 }), failure: 'provider_error', cause }; } });
    await runChat(h.deps, paperBody(), h.emit, new AbortController().signal);
    assert.deepEqual(h.events.at(-1), { event: 'error', data: { code, credits: 0, charged: false, reason: cause, retry_after: 10 } });
    assert.equal(settledWith(h).p_ending, cause);
  }
});

test('the provider overloading mid-stream (a real OpenRouter error event after the first text) charges nothing and keeps the text it sent', async () => {
  const generate = routerChat(routerStream([{ id: 'gen-mid', model: SONNET, choices: [{ index: 0, delta: { content: 'Half an answer ' }, finish_reason: null }] },
    { id: 'gen-mid', error: { code: 503, message: 'Overloaded' } }]));
  const h = harness({ generate: (params, stream) => generate(params, { ...stream, attribution }) });
  await runChat(h.deps, generalBody(), h.emit, new AbortController().signal);
  assert.deepEqual(h.events, [{ event: 'delta', data: { text: 'Half an answer ' } },
    { event: 'error', data: { code: 'provider_unavailable', credits: 0, charged: false, reason: 'provider', retry_after: 10 } }]);
  const settle = settledWith(h);
  assert.equal(settle.p_ending, 'provider'); assert.equal(settle.p_actual_credits, 0);
  assert.ok((settle.p_actual_microusd as number) > 0 && settle.p_absorbed_microusd === settle.p_actual_microusd, 'the estimate is Gradstep\'s cost, never hidden');
});

test('the equation view: symbols that finished are charged; a symbols request cut off at its length is not', async () => {
  const done = equationHarness({ generate: async (_params, stream) => { stream.onText('{"summary":"The DPO loss.","symbols":[]}'); return completeOutcome(); } });
  await runChat(done.deps, equationBody(), done.emit, new AbortController().signal);
  assert.equal(settledWith(done).p_action, 'equation'); assert.equal(settledWith(done).p_ending, 'completed');
  assert.equal((done.events.at(-1)!.data as { charged: boolean }).charged, true);
  const cut = equationHarness({ generate: async (_params, stream) => { stream.onText('{"summary":"The DPO'); return completeOutcome({ stopReason: 'max_tokens' }); } });
  await runChat(cut.deps, equationBody({ action: 'equation_background' }), cut.emit, new AbortController().signal);
  assert.equal(settledWith(cut).p_action, 'equation_background'); assert.equal(settledWith(cut).p_ending, 'limit'); assert.equal(settledWith(cut).p_actual_credits, 0);
});

test('a Study turn pays for the tutor\'s finished reply; a map update that came back unusable is Gradstep\'s', async () => {
  const h = studyHarness({ generate: async (params, stream) => {
    if (params.tools?.some(tool => 'name' in tool && tool.name === 'update_study_map')) return studyOutcome({ concepts: 'not a list' });
    stream.onText('**What does β control?**'); return completeOutcome();
  } });
  await runChat(h.deps, studyBody(), h.emit, new AbortController().signal);
  assert.ok(!h.events.some(e => e.event === 'study'), 'no map relayed');
  // The tutor's 4,800 micro-USD are charged; the map's 700 x $0.10 + 200 x $0.50 = 170 are absorbed.
  assert.deepEqual(settledWith(h), { p_account_id: account, p_id: operation, p_actual_credits: 1, p_actual_microusd: 4_970,
    p_action: 'study', p_ending: 'completed', p_absorbed_microusd: 170 });
});


test('figure card kinds are additive; concept and related-work cards cannot masquerade as image regions', () => {
  const row = {label:'',title:'Prior method',text:'This paper describes it [¶2].',paragraphs:[2],box:{x:0,y:0,w:0.5,h:1}};
  const checked = figureWalkthrough({sections:['panel','concept','related_work','future',undefined].map(kind => ({...row,kind}))}, 3)!;
  assert.deepEqual(checked.sections.map(s => s.kind), ['panel','concept','related_work',undefined,undefined]);
  assert.deepEqual(checked.sections.map(s => !!s.box), [true,false,false,true,true]);
  assert.equal(figureDetail({sections:[{...row,kind:'concept'}]},3),null);
  const many = figureWalkthrough({sections:Array.from({length:15},()=>row)},3)!;
  assert.equal(many.sections.length,12); assert.equal(many.sections.filter(s=>s.box).length,12);
});

test('A1: an estimate without an observation of what was written is never billed to the reader (platform liability only)', async () => {
  const client = new AbortController();
  const h = harness({ script: { worker_chat_stop_requested: () => true },
    generate: async (_params, stream) => { stream.onText('partial '); client.abort();
      return { ...aborted({ input: 150_000, output: 8_000 }), attempts: [{ model: SONNET, estimated: true,
        usage: { input: 150_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 8_000 } }] }; } });
  await runChat(h.deps, paperBody({ capabilities: ['stop_signal'] }), h.emit, client.signal);
  const settle = settledWith(h);
  assert.equal(settle.p_ending, 'stopped'); assert.equal(settle.p_actual_credits, 0);
  assert.equal(settle.p_absorbed_microusd, settle.p_actual_microusd);
});

// The owner's AI switches and free AI (migration 0150; docs/RUNBOOK_SPENDING.md, docs/PRICING_HOW_IT_WORKS.md).
const SWITCHES = { cheap_models_only: false, paused_features: [] as string[], premium_models: 'sonnet|opus', free_models: 'gemini|deepseek|haiku' };

test('switches: a paused figure or equation view and premium models under "cheaper models only" are refused before any hold', async () => {
  assert.equal(switchRefusal(null, 'figure', SONNET), null);
  assert.equal(switchRefusal({ ...SWITCHES, paused_features: ['figures'] }, 'figure_simpler', 'gemini-3.8-flash'), 'platform_budget_exhausted');
  assert.equal(switchRefusal({ ...SWITCHES, paused_features: ['equations'] }, 'equation_background', SONNET), 'platform_budget_exhausted');
  assert.equal(switchRefusal({ ...SWITCHES, paused_features: ['figures'] }, null, SONNET), null, 'a chat question is not a figure');
  assert.equal(switchRefusal({ ...SWITCHES, cheap_models_only: true }, null, SONNET), 'model_unavailable');
  assert.equal(switchRefusal({ ...SWITCHES, cheap_models_only: true }, null, OPUS), 'model_unavailable');
  assert.equal(switchRefusal({ ...SWITCHES, cheap_models_only: true }, null, 'gemini-3.8-flash'), null);
  assert.equal(switchRefusal({ ...SWITCHES, cheap_models_only: true, premium_models: '(' }, null, SONNET), null, 'a broken pattern refuses nothing here (the database still does)');
  assert.ok(freeModel(SWITCHES, 'gemini-3.8-flash') && freeModel(SWITCHES, FLASH) && freeModel(SWITCHES, HAIKU) && !freeModel(SWITCHES, SONNET) && !freeModel(null, FLASH));

  const paused = harness(); paused.deps.aiSwitches = async () => ({ ...SWITCHES, paused_features: ['figures'] });
  await runChat(paused.deps, figureBody(), paused.emit, new AbortController().signal);
  assert.deepEqual(paused.events.map(e => [e.event, (e.data as { code?: string }).code]), [['error', 'platform_budget_exhausted']]);
  assert.ok(!names(paused.calls).includes('worker_reserve_chat') && paused.generations() === 0, 'nothing held or sent');

  const cheap = harness(); cheap.deps.aiSwitches = async () => ({ ...SWITCHES, cheap_models_only: true });
  await runChat(cheap.deps, paperBody(), cheap.emit, new AbortController().signal);
  assert.deepEqual(cheap.events.map(e => [e.event, (e.data as { code?: string }).code]), [['error', 'model_unavailable']], 'the default (Sonnet) is premium');
  const gemini = harness(); gemini.deps.gemini = true; gemini.deps.aiSwitches = async () => ({ ...SWITCHES, cheap_models_only: true });
  await runChat(gemini.deps, paperBody({ profile: { model: 'gemini', effort: 'medium', length: 'standard' } }), gemini.emit, new AbortController().signal);
  assert.equal(gemini.events.at(-1)?.event, 'done', 'Gemini Flash still answers');

  const unreadable = harness(); unreadable.deps.aiSwitches = async () => { throw new Error('down'); };
  await runChat(unreadable.deps, paperBody(), unreadable.emit, new AbortController().signal);
  assert.equal(unreadable.events.at(-1)?.event, 'done', 'unreadable switches never block an answer (the database decides)');
});

test('free AI answers are written without web search; paid ones keep it', async () => {
  const tools: string[][] = [];
  const capture = async (params: unknown, stream: StreamOptions) => { tools.push(((params as { tools?: { name: string }[] }).tools ?? []).map(t => t.name)); stream.onText('ok'); return completeOutcome(); };
  const geminiBody = paperBody({ profile: { model: 'gemini', effort: 'medium', length: 'standard' } });
  for (const free of [true, false]) {
    const h = harness({ generate: capture }); searching(h, []); h.deps.gemini = true;
    h.deps.aiSwitches = async () => SWITCHES; h.deps.freeCredits = async () => free;
    await runChat(h.deps, geminiBody, h.emit, new AbortController().signal);
    assert.equal(h.events.at(-1)?.event, 'done');
    assert.equal((h.calls.find(c => c.name === 'worker_reserve_chat')!.params.p_quote as { max_searches: number }).max_searches === 0, free);
  }
  assert.ok(!tools[0].includes('search_web') && tools[1].includes('search_web'));
  // A premium model never uses free credits, so it keeps search even while free credits remain.
  const sonnet = harness({ generate: capture }); searching(sonnet, []);
  sonnet.deps.aiSwitches = async () => SWITCHES; sonnet.deps.freeCredits = async () => true;
  await runChat(sonnet.deps, paperBody(), sonnet.emit, new AbortController().signal);
  assert.ok(tools[2].includes('search_web'));
});

test('cheaper defaults: every published default moves to Gemini Flash while the switch is on', () => {
  const table = publishedProfiles({ deepseek: true, gemini: true });
  const cheap = withCheapDefaults(table);
  for (const key of ['default', 'default_recommended', 'default_figures'] as const) assert.deepEqual(cheap[key], { model: 'gemini', length: 'standard', effort: 'medium' }, key);
  assert.deepEqual(cheap.default_auto, { model: 'gemini', length: 'standard', effort: 'auto' });
  assert.ok(cheap.profiles.some(p => p.id === 'gemini-medium-standard') && cheap.profiles.some(p => p.id === 'gemini-auto-standard'), 'every default is a published profile');
  const noGemini = publishedProfiles({ deepseek: false, gemini: false });
  assert.equal(withCheapDefaults(noGemini), noGemini, 'without Gemini the table is unchanged');
});

import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { SSEParser, answerActionPrompt, chatTitle, interruptionNote, isSingleEquation, makeRequest, requestBody, resolution, selectionPrompt, boundedText, failureText, retryable, waitingText } from '../src/lib/chat';
import { renderMarkdown } from '../src/lib/markdown';
import { PrivateState, decodeDiagram, decodeEvent, encodeDiagram, encodeEvent, makeDiagram, type PrivateEvent } from '../src/lib/events';

const fixture = JSON.parse(readFileSync(new URL('../../apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/envelopes-v1.json', import.meta.url), 'utf8'));
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const C = id(900), D = id(901);
it('an unavailable cloud model asks for another choice without offering the same retry', () => {
  expect(failureText('model_unavailable')).toContain('Choose another model');
  expect(failureText('model_unavailable')).toContain('isn’t available right now');
  expect(failureText('model_unavailable')).toContain('Your AI credits were not charged');
  expect(failureText('service_unavailable')).toBe('AI answers are unavailable right now. Try again in a few minutes.');
  expect(retryable('model_unavailable')).toBe(false);
  expect(retryable('provider_unavailable')).toBe(true);
});
const message = (n: number, parents: number[], role: 'user' | 'assistant', text: string, extra: Partial<PrivateEvent> = {}): PrivateEvent =>
  ({ kind: 'message', entityID: id(n), parents: parents.map(id), conversationID: C, documentID: D, text, role, status: 'complete', ...extra });

describe('private events', () => {
  it('decodes the frozen Swift fixture and writes it back with uppercase UUIDs, as Swift does', () => {
    const event = decodeEvent(fixture.payload);
    expect(event.entityID).toBe('abcdef01-2345-4678-9abc-def012345678');
    expect(event.anchor?.page).toBe(3);
    expect(encodeEvent(event)).toEqual(fixture.payload);
  });
  it('refuses what Swift refuses and ignores unknown keys', () => {
    expect(() => decodeEvent({ ...fixture.payload, kind: 'poll' })).toThrow();
    expect(() => decodeEvent({ ...fixture.payload, parents: undefined })).toThrow(); // required in Swift
    expect(() => decodeEvent({ ...fixture.payload, role: undefined })).toThrow(); // a message needs its role
    expect(() => decodeEvent({ ...fixture.payload, createdAt: 1.5 })).toThrow();
    expect(() => decodeEvent({ ...fixture.payload, parents: [id(1), id(1)] })).toThrow();
    expect(() => decodeEvent({ ...fixture.payload, text: 'x'.repeat(200_001) })).toThrow();
    expect(decodeEvent({ ...fixture.payload, futureField: true, createdAt: 1_759_000_000_000 }).createdAt).toBe(1_759_000_000_000);
  });
  it('builds branches, follows the causal tip, and summarizes conversations', () => {
    const state = new PrivateState(), device = id(800);
    state.apply({ id: id(10), deviceID: device, payload: { kind: 'conversation', entityID: C, parents: [], documentID: D, text: 'What is DPO?', createdAt: 1000 } });
    state.apply({ id: id(11), deviceID: device, payload: message(11, [10], 'user', 'What is DPO?', { createdAt: 1000 }) });
    state.apply({ id: id(12), deviceID: device, payload: message(12, [11], 'assistant', 'An objective.', { createdAt: 2000 }) });
    // Two devices continue concurrently: two heads.
    state.apply({ id: id(13), deviceID: device, payload: message(13, [12], 'user', 'And PPO?') });
    state.apply({ id: id(14), deviceID: device, payload: message(14, [12], 'user', 'Why no RL?', { createdAt: 3000 }) });
    const branches = state.conversationBranches(C);
    expect(branches.map(b => b.head)).toEqual([id(13), id(14)]);
    expect(branches[1].messages.map(m => m.payload.text)).toEqual(['What is DPO?', 'An objective.', 'Why no RL?']);
    expect(branches[1].complete).toBe(true);
    const [summary] = state.conversationSummaries();
    expect(summary).toMatchObject({ id: C, title: 'What is DPO?', documentID: D, messageCount: 4, startedAt: 1000, lastUsedAt: 3000, latestAnswer: 'An objective.' });
    // A missing parent makes the branch incomplete; a conflicting replay is refused; a tombstone hides the chat.
    state.apply({ id: id(20), deviceID: device, payload: message(20, [99], 'user', 'Orphan') });
    expect(state.conversationBranch(C, id(20))?.complete).toBe(false);
    expect(() => state.apply({ id: id(12), deviceID: device, payload: message(12, [11], 'assistant', 'Changed.') })).toThrow();
    state.apply({ id: id(30), deviceID: device, payload: { kind: 'tombstone', entityID: C, parents: [] } });
    expect(state.conversationBranches(C)).toEqual([]);
    expect(state.conversationSummaries()).toEqual([]);
  });
  it('refuses cycles even when a parent arrives after its child', () => {
    const state = new PrivateState(), device = id(800);
    state.apply({ id: id(1), deviceID: device, payload: message(1, [2], 'user', 'a') });
    expect(() => state.apply({ id: id(2), deviceID: device, payload: message(2, [1], 'user', 'b') })).toThrow();
    expect(state.events.has(id(2))).toBe(false);
  });
  it('round-trips diagrams in the Swift JSON shape', () => {
    const text = encodeDiagram({ title: 'Flow', source: 'graph TD; A-->B', messageID: id(5) });
    expect(text).toBe('{"format":"mermaid-v1","messageID":"00000000-0000-4000-8000-000000000005","source":"graph TD; A-->B","title":"Flow"}'.replace('00000000-0000-4000-8000-000000000005', id(5).toUpperCase()));
    expect(decodeDiagram(text)).toEqual({ title: 'Flow', source: 'graph TD; A-->B', messageID: id(5) });
    expect(decodeDiagram('{"format":"mermaid-v2","title":"x","source":"y"}')).toBeNull();
  });
});

describe('chat requests and streams', () => {
  it('keeps the newest turns within bounds, starting and ending with a question', () => {
    const turns = [{ role: 'assistant' as const, text: 'hi' }, { role: 'user' as const, text: 'a' }, { role: 'assistant' as const, text: ' ' }, { role: 'user' as const, text: 'b' }];
    const request = makeRequest('op', D, turns, '  ', 'related');
    expect(request.turns.map(t => t.text)).toEqual(['a', 'b']);
    expect(request.selection).toBeNull();
    expect(request.action).toBeNull(); // an action needs a selection
    const big = Array.from({ length: 70 }, (_, i) => ({ role: (i % 2 ? 'assistant' : 'user') as 'user' | 'assistant', text: `t${i}` }));
    big.push({ role: 'user', text: 'last' });
    const bounded = makeRequest('op', null, big, null);
    expect(bounded.turns.length).toBeLessThanOrEqual(60);
    expect(bounded.turns[0].role).toBe('user');
    expect(requestBody(bounded)).toMatchObject({ consent_version: 'cloud-ai-v6', mode: 'general' });
    expect(requestBody(bounded)).not.toHaveProperty('document_id');
    expect(requestBody(makeRequest('op', D, [{ role: 'user', text: 'q' }], 'a passage', 'ingest'))).toMatchObject({ mode: 'paper', document_id: D,
      selection: { quote: 'a passage' }, action: 'ingest', capabilities: ['web_import', 'visual_answers', 'stop_signal'] });
    // Visual answers (2026-10-15): always a list, so one without visual_answers says the reader turned them off.
    // stop_signal (2026-10-16) on every request: this browser records the reader's Stop (CHAT.md "When an answer stops early").
    // figure_view (2026-10-16) on every paper chat, whatever the Visual answers setting (FIGURE_VIEW.md: the walkthrough
    // tool is part of the cached prefix); never with Add paper, a diagram repair or a general chat.
    expect(requestBody(makeRequest('op', D, [{ role: 'user', text: 'q' }], null)).capabilities).toEqual(['visual_answers', 'figure_view', 'stop_signal']);
    expect(requestBody(makeRequest('op', D, [{ role: 'user', text: 'q' }], null, null, { visualAnswers: false })).capabilities).toEqual(['figure_view', 'stop_signal']);
    expect(requestBody(makeRequest('op', D, [{ role: 'user', text: 'q' }], 'x', 'diagram_fix')).capabilities).toEqual(['visual_answers', 'stop_signal']);
    expect(requestBody(makeRequest('op', null, [{ role: 'user', text: 'q' }], null)).capabilities).toEqual(['visual_answers', 'stop_signal']);
    expect(() => makeRequest('op', null, [{ role: 'assistant', text: 'x' }], null)).toThrow();
  });
  it('parses deltas across chunk boundaries, ignores pings and unknown events, and refuses malformed known ones', () => {
    const parser = new SSEParser(), enc = (s: string) => new TextEncoder().encode(s);
    const stream = ': ping\r\n\r\nevent: delta\r\ndata: {"text":"Hel"}\r\n\r\nevent: delta\ndata: {"text":"lo \\u2211"}\n\nevent: future\ndata: {}\n\nevent: status\ndata: {"kind":"searching","query":"dpo\\nloss"}\n\nevent: status\ndata: {"kind":"dreaming"}\n\nevent: done\ndata: {"stop_reason":"end_turn","credits":3,"usage":{}}\n\n';
    const bytes = enc(stream), events = [];
    for (let i = 0; i < bytes.length; i += 7) events.push(...parser.consume(bytes.slice(i, i + 7)));
    expect(events).toEqual([{ type: 'delta', text: 'Hel' }, { type: 'delta', text: 'lo ∑' }, { type: 'status', progress: { kind: 'searching', query: 'dpo loss' } },
      { type: 'done', stopReason: 'end_turn', credits: 3 }]);
    expect(() => new SSEParser().consume(enc('event: delta\ndata: {"txt":1}\n\n'))).toThrow();
    expect(() => new SSEParser().consume(enc('event: done\ndata: {"stop_reason":"end_turn","credits":-1}\n\n'))).toThrow();
    expect(new SSEParser().consume(enc('event: error\ndata: {"code":"insufficient_credits"}\n\n'))).toEqual([{ type: 'error', code: 'insufficient_credits' }]);
  });
  it('keeps complete answers, interrupted partials, and nothing for refusals', () => {
    expect(resolution({ kind: 'completed', stopReason: 'end_turn' }, 'x')).toEqual({ status: 'complete', issue: null });
    expect(resolution({ kind: 'completed', stopReason: 'max_tokens' }, 'x')).toEqual({ status: 'interrupted', issue: null });
    expect(resolution({ kind: 'completed', stopReason: 'end_turn' }, ' ')).toEqual({ status: null, issue: 'provider_unavailable' });
    expect(resolution({ kind: 'failed', code: 'refused' }, 'partial')).toEqual({ status: null, issue: 'refused' });
    expect(resolution({ kind: 'failed', code: 'transport' }, 'partial')).toEqual({ status: 'interrupted', issue: 'transport' });
    expect(resolution({ kind: 'cancelled' }, 'partial')).toEqual({ status: 'interrupted', issue: null });
    expect(new TextEncoder().encode(boundedText('é'.repeat(150_000))).length).toBeLessThanOrEqual(200_000);
  });
  it('words selection actions as the app does and shortens their titles', () => {
    expect(selectionPrompt('define', 'the loss')).toBe('Explain in plain terms, including any symbols: the loss');
    // The passage's paragraph marker travels with the question (owner, build 42), never into its title.
    expect(selectionPrompt('define', 'the loss', 24)).toBe('Explain in plain terms, including any symbols: the loss [¶24]');
    expect(chatTitle(selectionPrompt('define', 'the loss', 24))).toEqual({ label: 'Explain', text: 'the loss', truncated: false });
    expect(chatTitle('What is [¶24] about?').text).toBe('What is [¶24] about?');
    expect(selectionPrompt('define', '\\[L = -\\log \\sigma(x)\\]')).toMatch(/^Explain this equation: \\\[L = /);
    expect(isSingleEquation('\\(x\\)')).toBe(false);
    expect(isSingleEquation('\\(a \\leq b\\).')).toBe(true);
    expect(chatTitle(selectionPrompt('similar', 'reward models'))).toEqual({ label: 'Related', text: 'reward models', truncated: false });
    expect(chatTitle(selectionPrompt('define', '$$x=1$$'))).toMatchObject({ label: 'Explain', text: '$$x=1$$' });
    expect(chatTitle('What is DPO?')).toEqual({ label: null, text: 'What is DPO?', truncated: false });
  });
});

describe('answer rendering (markdown-it + Temml, no CDN)', () => {
  it('typesets both delimiter styles, leaves code alone, and escapes raw HTML', () => {
    const html = renderMarkdown(String.raw`The loss \(L = -\log \sigma(x)\) and $a_i$:

\[\sum_i x_i\]

` + '`' + String.raw`\(not math\)` + '` <script>alert(1)</script>\n\n```\n$$ also not $$\n```');
    expect(html).toContain('<math');
    expect(html).toContain('display="block"');
    expect(html).toContain(String.raw`<code>\(not math\)</code>`);
    expect(html).toContain('$$ also not $$');
    expect(html).not.toContain('<script>');
    expect(html).toContain('&lt;script&gt;');
  });
  it('links only http(s) and mailto, opening outside the app', () => {
    const html = renderMarkdown('[x](javascript:alert(1)) [arXiv](https://arxiv.org/abs/2305.18290) https://example.org');
    expect(html).not.toContain('href="javascript');
    expect(html).toContain('href="https://arxiv.org/abs/2305.18290" target="_blank" rel="noopener noreferrer"');
    expect(html).toContain('href="https://example.org"');
  });
  it('keeps an unclosed formula as text while streaming', () => {
    expect(renderMarkdown(String.raw`So \[\frac{a}{`, true)).not.toContain('<math');
    expect(renderMarkdown(String.raw`So \[\frac{a}{b}\]`, true)).toContain('<math');
  });
});

describe('rendering boundaries', () => {
  it('cannot interpolate a formula into a URL or turn private-use text into HTML', () => {
    const html = renderMarkdown(String.raw`[x](https://example.org/\(a\)) 0 <img src=x onerror=alert(1)>`);
    expect(html).not.toContain('<img'); expect(html).not.toContain('href="https://example.org/<math');
    expect(html).toContain('0');
  });
  it('keeps escaped dollar signs, indented code and unequal backtick spans as code/prose', () => {
    expect(renderMarkdown(String.raw`\$5 and \$10`)).not.toContain('<math');
    expect(renderMarkdown('    \\(x\\)')).toContain('<code>\\(x\\)');
    expect(renderMarkdown('``a ` \\(x\\)``')).not.toContain('<math');
  });
  it('rejects credential-bearing, control-character and data links', async () => {
    const { safeLink } = await import('../src/lib/markdown');
    for (const url of ['https://good.example@bad.example', 'data:text/html,x', 'java\nscript:alert(1)', '/relative', 'https://x.test/\n']) expect(safeLink(url)).toBeNull();
  });
});


describe('visual answers', () => {
  it('parses a visual event, drops an unusable one, and keeps the HTML format through the diagram encoding', () => {
    const parser = new SSEParser();
    const events = parser.consume(new TextEncoder().encode('event: visual\ndata: {"title":"Loop","html":"<ol><li>a</li></ol>"}\n\nevent: visual\ndata: {"title":"","html":"<p>x</p>"}\n\nevent: done\ndata: {"stop_reason":"end_turn","credits":3}\n\n'));
    expect(events).toEqual([{ type: 'visual', title: 'Loop', html: '<ol><li>a</li></ol>' }, { type: 'done', stopReason: 'end_turn', credits: 3 }]);
    const visual = makeDiagram('Loop', '<ol><li>a</li></ol>', 'aaaaaaaa-0000-4000-8000-000000000001', 'html-v1')!;
    expect(encodeDiagram(visual)).toBe('{"format":"html-v1","messageID":"AAAAAAAA-0000-4000-8000-000000000001","source":"<ol><li>a</li></ol>","title":"Loop"}');
    expect(decodeDiagram(encodeDiagram(visual))).toEqual(visual);
    expect(decodeDiagram('{"format":"svg-v9","source":"x","title":"T"}')).toBeNull();
    expect(makeDiagram('x', 'y'.repeat(16_001), undefined, 'mermaid-v1')).toBeNull();
    expect(makeDiagram('x', 'y'.repeat(16_001), undefined, 'html-v1')).not.toBeNull();
  });
});

describe('early endings (2026-10-16, CHAT.md "When an answer stops early")', () => {
  const enc = (s: string) => new TextEncoder().encode(s);
  it('reads charged and its reason on done and error, and drops anything else', () => {
    expect(new SSEParser().consume(enc('event: error\ndata: {"code":"provider_unavailable","credits":0,"charged":false,"reason":"provider","retry_after":5}\n\n')))
      .toEqual([{ type: 'error', code: 'provider_unavailable', credits: 0, charged: false, reason: 'provider' }]);
    expect(new SSEParser().consume(enc('event: done\ndata: {"stop_reason":"max_tokens","credits":0,"charged":false,"reason":"limit"}\n\n')))
      .toEqual([{ type: 'done', stopReason: 'max_tokens', credits: 0, charged: false, reason: 'limit' }]);
    expect(new SSEParser().consume(enc('event: done\ndata: {"stop_reason":"end_turn","credits":4,"charged":true,"reason":"provider"}\n\n')))
      .toEqual([{ type: 'done', stopReason: 'end_turn', credits: 4, charged: true }]);
    expect(new SSEParser().consume(enc('event: error\ndata: {"code":"refused","charged":"no","reason":"<b>"}\n\n'))).toEqual([{ type: 'error', code: 'refused' }]);
  });
  it('says under an interrupted answer what it cost', () => {
    expect(interruptionNote(false, { credits: 0, charged: false })).toBe('Interrupted · not charged');
    expect(interruptionNote(false, { credits: 0 })).toBe('Interrupted · not charged');
    expect(interruptionNote(false, { credits: 2, charged: false })).toBe('Interrupted · not charged');
    expect(interruptionNote(true, null)).toBe('Stopped · charged for the part written');
    expect(interruptionNote(true, { credits: 0 })).toBe('Stopped · not charged');
    // An older server (no `charged`), or an end that said nothing: the existing wording.
    expect(interruptionNote(false, null)).toBeNull();
    expect(interruptionNote(false, { credits: 3 })).toBeNull();
  });
});

describe('actions on selected answer text (B1)', () => {
  it('Explain asks as a selection’s Explain (an equation gets the equation prompt); Define asks for terms and symbols', () => {
    expect(answerActionPrompt('explain', 'the KL term')).toBe('Explain in plain terms, including any symbols: the KL term');
    expect(answerActionPrompt('explain', '\\[L = -\\log \\sigma(x)\\]')).toMatch(/^Explain this equation: \\\[L = /);
    expect(answerActionPrompt('define', 'KL divergence')).toBe('Define the terms and symbols in: KL divergence'); // ChatGenerationTests
  });
  it('formulas carry their LaTeX, inline or display, for Copy LaTeX and quotes', () => {
    const html = renderMarkdown('So \\(a<b\\) and \\[x^2\\]');
    expect(html).toContain('<span class="answer-math" data-latex="a&lt;b" data-display="0">');
    expect(html).toContain('<span class="answer-math" data-latex="x^2" data-display="1">');
  });
});


// Servers from 2026-10-25 say when the model hasn't sent anything back yet (`waiting`), then that it started (`thinking`).
it('the model\'s own progress before its first words: waiting with the seconds, then Thinking…', () => {
  const events = new SSEParser().consume(new TextEncoder().encode('event: status\ndata: {"kind":"waiting"}\n\nevent: status\ndata: {"kind":"thinking"}\n\n'));
  expect(events).toEqual([{ type: 'status', progress: { kind: 'waiting' } }, { type: 'status', progress: { kind: 'thinking' } }]);
  expect(waitingText(null, 2)).toBe('Thinking…');
  expect(waitingText(null, 12)).toBe('Thinking… 12 s');
  expect(waitingText({ kind: 'waiting' }, 13)).toBe('Still waiting for the model… 13 s');
  expect(waitingText({ kind: 'thinking' }, 20)).toBe('Thinking… 20 s');
  expect(waitingText({ kind: 'searching', query: 'dpo' }, 20)).toBe('Searching the web for “dpo”');
});

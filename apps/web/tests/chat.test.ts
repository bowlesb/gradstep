import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { SSEParser, chatTitle, isSingleEquation, makeRequest, requestBody, resolution, selectionPrompt, boundedText } from '../src/lib/chat';
import { PrivateState, decodeDiagram, decodeEvent, encodeDiagram, encodeEvent, type PrivateEvent } from '../src/lib/events';

const fixture = JSON.parse(readFileSync(new URL('../../apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/envelopes-v1.json', import.meta.url), 'utf8'));
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const C = id(900), D = id(901);
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
    expect(requestBody(bounded)).toMatchObject({ consent_version: 'cloud-ai-v2', mode: 'general' });
    expect(requestBody(bounded)).not.toHaveProperty('document_id');
    expect(requestBody(makeRequest('op', D, [{ role: 'user', text: 'q' }], 'a passage', 'ingest'))).toMatchObject({ mode: 'paper', document_id: D,
      selection: { quote: 'a passage' }, action: 'ingest', capabilities: ['web_import'] });
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
    expect(selectionPrompt('define', '\\[L = -\\log \\sigma(x)\\]')).toMatch(/^Explain this equation: \\\[L = /);
    expect(isSingleEquation('\\(x\\)')).toBe(false);
    expect(isSingleEquation('\\(a \\leq b\\).')).toBe(true);
    expect(chatTitle(selectionPrompt('similar', 'reward models'))).toEqual({ label: 'Related', text: 'reward models', truncated: false });
    expect(chatTitle(selectionPrompt('define', '$$x=1$$'))).toMatchObject({ label: 'Explain', text: '$$x=1$$' });
    expect(chatTitle('What is DPO?')).toEqual({ label: null, text: 'What is DPO?', truncated: false });
  });
});

// The streamed equation explanation (EQUATION_VIEW.md "Streamed explanation", servers from 2026-10-22): the events checked
// as the final `equation`'s rows are, and the session's result as they arrive (the progress bar's inputs), replaced by the
// final `equation`; a stream that ends without it keeps the symbols it showed, an error drops them.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { SSEParser, type StreamEvent } from '../src/lib/chat';
import { parseEquationSymbol, parseEquationSymbols, type EquationResult } from '../src/lib/equation';

const server = vi.hoisted(() => ({ requests: [] as any[] }));
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string) => name === 'v1_credit_balance' ? { available: 100, reserved: 0 } : name === 'v3_pull_events' ? { events: [], next_cursor: 0, has_more: false } : null };
});
vi.mock('../src/lib/arxiv-reader', () => ({ localChatContext: (reference: { membershipID: string }) => ({ format: 'reader-local-context-v2', membership_id: reference.membershipID,
  source: 'arxiv', source_id: '2601.01234', revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] # Fixture\n\n[¶2] Squares.' }) }));

const s0 = { symbol: 'x', latex: 'x', meaning: 'The value.', source: 'paper' as const, paragraph: 2 };
const s1 = { symbol: '²', meaning: 'Squaring.', source: 'general' as const };
const final = { format: 'equation-symbols-v1' as const, summary: 'It squares x.', symbols: [s0, s1] };

describe('the streamed equation events', () => {
  const frames = (text: string) => new SSEParser().consume(new TextEncoder().encode(text));
  const sse = (name: string, data: unknown) => `event: ${name}\ndata: ${typeof data === 'string' ? data : JSON.stringify(data)}\n\n`;
  it('carry the stage, the characters written and the symbols announced; anything unusable is dropped, never fatal', () => {
    expect(frames(sse('equation_progress', { stage: 'reading' }))).toEqual([{ type: 'equation_progress', stage: 'reading' }]);
    expect(frames(sse('equation_progress', { stage: 'writing', characters: 120, symbols: 9 }))).toEqual([{ type: 'equation_progress', stage: 'writing', characters: 120, symbols: 9 }]);
    expect(frames(sse('equation_progress', { stage: 'writing', characters: 12, symbols: 25 }) + sse('equation_progress', { stage: 'writing', characters: 20, symbols: 0 })))
      .toEqual([{ type: 'equation_progress', stage: 'writing', characters: 12 }, { type: 'equation_progress', stage: 'writing', characters: 20 }]);
    for (const bad of [{ stage: 'writing' }, { stage: 'writing', characters: -1 }, { stage: 'thinking' }, null]) expect(frames(sse('equation_progress', bad))).toEqual([]);
    expect(frames(sse('equation_progress', '{broken'))).toEqual([]);
  });
  it('carry the summary and each symbol at its place, checked as the final rows', () => {
    expect(frames(sse('equation_summary', { summary: ' It squares x.\u0007 ' }))).toEqual([{ type: 'equation_summary', summary: 'It squares x.' }]);
    expect(frames(sse('equation_symbol', { index: 0, symbol: { ...s0, paragraph: 2 } }))).toEqual([{ type: 'equation_symbol', index: 0, symbol: s0 }]);
    // A paragraph only with the paper; a row without a meaning, a bad index: dropped.
    expect(frames(sse('equation_symbol', { index: 1, symbol: { symbol: 'σ', meaning: 'Logistic.', source: 'paper' } })))
      .toEqual([{ type: 'equation_symbol', index: 1, symbol: { symbol: 'σ', meaning: 'Logistic.', source: 'general' } }]);
    for (const bad of [{ index: 0, symbol: { symbol: 'x' } }, { index: -1, symbol: s0 }, { index: 24, symbol: s0 }, { index: 0.5, symbol: s0 }])
      expect(frames(sse('equation_symbol', bad)), JSON.stringify(bad)).toEqual([]);
    // The same row check as the final event's.
    expect(parseEquationSymbols(final)!.symbols).toEqual([parseEquationSymbol(s0), parseEquationSymbol(s1)]);
  });
});

describe('the equation view in the chat session', () => {
  const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001', member = '58000000-0000-4000-8000-000000000003';
  const reference = { format: 'source-membership-v1' as const, membershipID: member, source: 'arxiv' as const, sourceID: '2601.01234', revision: 2 };
  const bundle = { manifestSHA256: 'c'.repeat(64), index: { figures: [], blocks: [], equations: [] } };
  beforeEach(() => { server.requests = []; });
  async function setup(answers: StreamEvent[][]) {
    const { ChatSession } = await import('../src/lib/chat-session');
    const { History } = await import('../src/lib/history');
    const { keyRing, generateBundle } = await import('../src/lib/wire');
    const owner = new AbortController(), ring = await keyRing(generateBundle(account));
    const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
    let turn = 0;
    const chat = new ChatSession(account, history, owner.signal, {
      readConsent: () => true, writeConsent: () => {},
      stream: async function* (_account, request, _signal, opened) { server.requests.push(request); opened?.(); for (const e of answers[Math.min(turn++, answers.length - 1)]) yield e; },
    });
    chat.setSourcePapers(new Map([[member, { reference, load: async () => bundle as any }]]));
    return chat;
  }
  const ask = (chat: Awaited<ReturnType<typeof setup>>, seen: EquationResult[] = [], id = 'e1') =>
    chat.equation(member, { equationID: id, latex: 'x^2', number: '(1)' }, 'equation', r => seen.push(r), new AbortController().signal);
  const done: StreamEvent = { type: 'done', stopReason: 'end_turn', credits: 2, charged: true };

  it('builds the explanation as it streams, with the progress bar’s inputs, and keeps only the final one', async () => {
    const last = { ...final, summary: 'It squares x, finally.' };
    const chat = await setup([[{ type: 'equation_progress', stage: 'reading' }, { type: 'equation_progress', stage: 'writing', characters: 60, symbols: 2 },
      { type: 'equation_progress', stage: 'writing', characters: 30 } as StreamEvent, // never goes back
      { type: 'equation_summary', summary: 'It squares x.' }, { type: 'equation_progress', stage: 'writing', characters: 200, symbols: 2 },
      { type: 'equation_symbol', index: 0, symbol: s0 }, { type: 'equation_symbol', index: 0, symbol: s1 }, // a repeat is ignored
      { type: 'equation_symbol', index: 1, symbol: s1 }, { type: 'equation', symbols: last }, done]]);
    const seen: EquationResult[] = [];
    const result = await ask(chat, seen);
    const loading = seen.filter(r => r.phase === 'loading');
    expect(loading.map(r => r.progress?.stage)).toEqual(['preparing', 'reading', 'reading', 'writing', 'writing', 'writing', 'writing', 'writing', 'writing', 'done']);
    const at = (summary: boolean, parts: number) => loading.find(r => r.progress?.summary === summary && r.progress?.parts === parts)!;
    expect(at(true, 0)).toMatchObject({ symbols: { summary: 'It squares x.', symbols: [] }, progress: { characters: 60, charactersAtLast: 60, announced: 2 } });
    expect(at(true, 1)).toMatchObject({ symbols: { symbols: [s0] }, progress: { characters: 200, charactersAtLast: 200 } });
    expect(at(true, 2)).toMatchObject({ symbols: { symbols: [s0, s1] } });
    expect(result).toMatchObject({ phase: 'done', symbols: last, charged: true, issue: null });
    expect(result).not.toHaveProperty('progress');
    expect(chat.savedEquation(bundle.manifestSHA256, 'e1', 'equation')).toEqual(result);
    expect(server.requests[0]).toMatchObject({ action: 'equation', selection: 'x^2', turns: [{ role: 'user', text: 'Equation (1)' }] });
  });
  it('shows symbols in order: one ahead of its place waits for those before it', async () => {
    const chat = await setup([[{ type: 'equation_summary', summary: 'S' }, { type: 'equation_symbol', index: 1, symbol: s1 }, { type: 'equation_symbol', index: 0, symbol: s0 },
      { type: 'equation', symbols: final }, done]]);
    const seen: EquationResult[] = [];
    await ask(chat, seen);
    expect(seen.filter(r => r.phase === 'loading' && r.symbols).map(r => r.symbols!.symbols.length)).toEqual([0, 0, 2, 2]);
  });
  it('works with a server that sends only the final symbols: Preparing, Reading, then all of them', async () => {
    const chat = await setup([[{ type: 'equation', symbols: final }, done]]);
    const seen: EquationResult[] = [];
    const result = await ask(chat, seen);
    expect(seen.filter(r => r.phase === 'loading').map(r => [r.progress?.stage, r.symbols?.symbols.length ?? 0])).toEqual([['preparing', 0], ['reading', 0], ['done', 2]]);
    expect(result).toMatchObject({ phase: 'done', symbols: final });
  });
  it('drops the streamed symbols on an error; keeps them when it ends without the final one (cut off: not charged); fails with only a summary', async () => {
    const failed = await ask(await setup([[{ type: 'equation_summary', summary: 'S' }, { type: 'equation_symbol', index: 0, symbol: s0 },
      { type: 'error', code: 'provider_unavailable', credits: 0, charged: false, reason: 'provider' }]]));
    expect(failed).toMatchObject({ phase: 'failed', issue: 'provider_unavailable', symbols: null, charged: false });
    expect(failed).not.toHaveProperty('progress');
    const cut = await ask(await setup([[{ type: 'equation_summary', summary: 'S' }, { type: 'equation_symbol', index: 0, symbol: s0 },
      { type: 'done', stopReason: 'max_tokens', credits: 0, charged: false, reason: 'limit' }]]));
    expect(cut).toMatchObject({ phase: 'done', issue: null, symbols: { summary: 'S', symbols: [s0] }, charged: false, reason: 'limit' });
    const summaryOnly = await ask(await setup([[{ type: 'equation_summary', summary: 'S' }, { type: 'done', stopReason: 'end_turn', credits: 0, charged: false, reason: 'provider' }]]));
    expect(summaryOnly).toMatchObject({ phase: 'failed', issue: 'provider_unavailable', symbols: null });
    const dropped = await ask(await setup([[{ type: 'equation_summary', summary: 'S' }, { type: 'equation_symbol', index: 0, symbol: s0 }]]));
    expect(dropped).toMatchObject({ phase: 'failed', issue: 'transport', symbols: null });
  });
  it('background has no progress and ignores symbol events', async () => {
    const chat = await setup([[{ type: 'equation_symbol', index: 0, symbol: s0 }, { type: 'delta', text: 'Background.' }, done]]);
    const seen: EquationResult[] = [];
    const result = await chat.equation(member, { equationID: 'e1', latex: 'x^2', number: null }, 'equation_background', r => seen.push(r), new AbortController().signal);
    expect(seen.every(r => !r.progress && !r.symbols)).toBe(true);
    expect(result).toMatchObject({ phase: 'done', text: 'Background.', symbols: null });
  });
});

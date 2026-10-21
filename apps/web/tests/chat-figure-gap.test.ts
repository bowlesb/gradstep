// A19: the gap between a chat answer that asks for a figure and the same question sent again with it. Stop, storage
// retirement and sign-out there must start no second paid request.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { StreamEvent } from '../src/lib/chat';

const gate = vi.hoisted(() => ({ release: () => {}, waiting: false, images: 0 }));
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string) => name === 'v1_credit_balance' ? { available: 100, reserved: 0 } : name === 'v3_pull_events' ? { events: [], next_cursor: 0, has_more: false } : name === 'v1_append_event' ? 1 : null };
});
vi.mock('../src/lib/arxiv-reader', () => ({ localChatContext: (reference: { membershipID: string }) => ({ format: 'reader-local-context-v2', membership_id: reference.membershipID,
  source: 'arxiv', source_id: '2601.01234', revision: 2, manifest_sha256: 'a'.repeat(64), source_sha256: 'b'.repeat(64), text: '[¶1] # Fixture\n\n[¶2] Two pipelines.' }) }));
const image = { id: 'F1', paragraph: 3, caption: 'Figure 1: Two pipelines.', mediaType: 'image/jpeg' as const, data: 'AAAA', width: 10, height: 10, blockID: 'b-3', assetPath: 'x.jpg', assetPaths: ['x.jpg'] };
vi.mock('../src/lib/chat-figures', async original => {
  const mod = await original<typeof import('../src/lib/chat-figures')>();
  // The question names no figure; the figure the model asks for is prepared only once the test releases it.
  return { ...mod, chatFigureImages: async (question: string) => {
    if (question !== 'Figure 1') return [];
    gate.waiting = true; await new Promise<void>(resolve => { gate.release = resolve; }); gate.waiting = false; gate.images++;
    return [image];
  } };
});

const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001', member = '58000000-0000-4000-8000-000000000003';
const reference = { format: 'source-membership-v1' as const, membershipID: member, source: 'arxiv' as const, sourceID: '2601.01234', revision: 2 };
const bundle = { manifestSHA256: 'c'.repeat(64), index: { figures: [{ id: 'b-3', block_id: 'b-3', caption: 'Figure 1: Two pipelines.', asset_paths: ['x.jpg'] }], blocks: [] } };
const first: StreamEvent[] = [{ type: 'delta', text: 'Let me look at Figure 1.' }, { type: 'figure_request', figure: 'Figure 1' }, { type: 'done', stopReason: 'end_turn', credits: 1 }];
const second: StreamEvent[] = [{ type: 'delta', text: 'Figure 1 has two pipelines.' }, { type: 'done', stopReason: 'end_turn', credits: 2 }];
const requests: unknown[] = [];
const until = async (check: () => boolean) => { for (let i = 0; i < 200 && !check(); i++) await new Promise(r => setTimeout(r, 2)); expect(check()).toBe(true); };

async function setup() {
  const { ChatSession } = await import('../src/lib/chat-session');
  const { History } = await import('../src/lib/history');
  const { keyRing, generateBundle } = await import('../src/lib/wire');
  const owner = new AbortController(), ring = await keyRing(generateBundle(account));
  const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
  let turn = 0;
  const chat = new ChatSession(account, history, owner.signal, {
    readConsent: () => true, writeConsent: () => {}, recordStop: async () => {},
    stream: async function* (_account, request) { requests.push(request); for (const e of [first, second][Math.min(turn++, 1)]) yield e; },
  });
  chat.setSourcePapers(new Map([[member, { reference, load: async () => bundle as any }]]));
  const c = chat.current(member);
  chat.edit(c, 'Break down the most complex figure');
  return { chat, c, sending: chat.send(c), owner };
}
beforeEach(() => { requests.length = 0; gate.images = 0; gate.waiting = false; });

describe('the figure follow-up gap (A19)', () => {
  it('sends the question again with the figure the model asked for', async () => {
    const { c, sending } = await setup();
    await until(() => gate.waiting); gate.release(); await sending;
    expect(requests).toHaveLength(2);
    expect(c.phase).toBe('idle');
  });
  it('Stop in the gap starts no second paid request and keeps what was written', async () => {
    const { chat, c, sending } = await setup();
    await until(() => gate.waiting);
    expect(c.phase).toBe('streaming');
    chat.stop(c); gate.release(); await sending;
    expect(gate.images).toBe(1); expect(requests).toHaveLength(1);
    expect(c.phase).toBe('idle');
    expect(chat.branch(c)?.messages.map(m => m.payload.text)).toEqual(['Break down the most complex figure', 'Let me look at Figure 1.']);
  });
  it('signing out in the gap starts no second paid request', async () => {
    const { chat, c, sending } = await setup();
    await until(() => gate.waiting);
    const settled = chat.settleBeforeSignOut().catch(() => {});
    gate.release(); await sending; await settled;
    expect(requests).toHaveLength(1);
    expect(c.phase).toBe('idle');
  });
});

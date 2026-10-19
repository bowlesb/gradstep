import { afterEach, describe, expect, it, vi } from 'vitest';
import { creditsLabel, parseBalance, parsePlan, planLabel } from '../src/lib/account-summary';
import { PrivateState, encodeDiagram } from '../src/lib/events';

// The account menu's AI credits, Subscription plan and Your assets › Diagrams (browser parity with native Settings,
// owner builds 57–59).

describe('AI credits and Subscription plan', () => {
  it('shows the balance and plan as the server gives them, a dash while unknown, never a made-up value', () => {
    expect(parseBalance({ available: 1240, reserved: 30 })).toEqual({ available: 1240, reserved: 30 });
    for (const bad of [null, {}, { available: -1, reserved: 0 }, { available: 1.5, reserved: 0 }, { available: '10', reserved: 0 }, { available: 10 }])
      expect(parseBalance(bad)).toBeUndefined();
    expect(creditsLabel({ available: 1240, reserved: 0 }, 'en-US')).toBe('1,240');
    expect(creditsLabel(undefined)).toBe('—');
    expect(parseBalance({ available: 100000, reserved: 0, unlimited_testing: true })).toEqual({ available: 100000, reserved: 0, unlimited_testing: true });
    expect(creditsLabel({ available: 100000, reserved: 0, unlimited_testing: true })).toBe('Unlimited testing');
    expect(parseBalance({ available: 100000, reserved: 0, unlimited_testing: 'true' })).toBeUndefined();
    expect(parsePlan({ plan: null, product_id: null })).toBeNull();
    expect(parsePlan({ plan: 'pro', product_id: 'x', expires_at: '2026-11-01T00:00:00Z' })).toBe('pro');
    for (const bad of [null, {}, { plan: 3 }, { plan: '<b>' }]) expect(parsePlan(bad)).toBeUndefined();
    expect([planLabel('pro'), planLabel('standard'), planLabel('team'), planLabel(null), planLabel(undefined)]).toEqual(['Pro', 'Standard', 'Team', 'None', '—']);
  });

  it('reads both from the server each time and keeps one failure to its own row', async () => {
    vi.resetModules();
    const calls: string[] = [];
    vi.doMock('../src/lib/backend', () => ({ rpc: async (name: string) => {
      calls.push(name);
      if (name === 'v1_store_summary') throw new Error('request_failed');
      return { available: 75, reserved: 0 };
    } }));
    const { loadAccountSummary } = await import('../src/lib/account-summary');
    expect(await loadAccountSummary('account')).toEqual({ balance: { available: 75, reserved: 0 }, plan: undefined });
    expect(calls.sort()).toEqual(['v1_credit_balance', 'v1_store_summary']);
  });
  afterEach(() => { vi.doUnmock('../src/lib/backend'); });
});

describe('Your assets › Diagrams', () => {
  const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const device = id(800), paper = id(901);
  const conversation = (n: number, documentID?: string) => ({ id: id(n), deviceID: device,
    payload: { kind: 'conversation' as const, entityID: id(n + 100), parents: [], documentID, text: 'Chat', createdAt: 1000 } });
  const diagram = (n: number, chat: number, createdAt: number | undefined, title: string, format?: 'html-v1') => ({ id: id(n), deviceID: device,
    payload: { kind: 'diagram' as const, entityID: id(n + 100), parents: [], conversationID: id(chat + 100),
      text: encodeDiagram({ title, source: format ? '<p>x</p>' : 'graph TD; A-->B', messageID: id(n + 200), format }), createdAt } });

  it('lists every saved diagram newest first, with its chat’s paper; a deleted chat takes its diagrams with it', () => {
    const state = new PrivateState();
    state.apply(conversation(1, paper)); state.apply(conversation(2));
    state.apply(diagram(10, 1, 1000, 'Older flow'));
    state.apply(diagram(11, 2, 3000, 'Newest visual', 'html-v1'));
    state.apply(diagram(12, 1, 2000, 'Middle flow'));
    state.apply(diagram(13, 1, undefined, 'Undated'));
    const list = state.savedDiagrams();
    expect(list.map(d => d.title)).toEqual(['Newest visual', 'Middle flow', 'Older flow', 'Undated']);
    expect(list[0]).toMatchObject({ format: 'html-v1', documentID: undefined, createdAt: 3000 });
    expect(list[1]).toMatchObject({ format: 'mermaid-v1', documentID: paper, conversationID: id(101) });
    // The chat with three of them is deleted on another device.
    state.apply({ id: id(20), deviceID: device, payload: { kind: 'tombstone', entityID: id(101), parents: [] } });
    expect(state.savedDiagrams().map(d => d.title)).toEqual(['Newest visual']);
    expect(new PrivateState().savedDiagrams()).toEqual([]);
  });
});

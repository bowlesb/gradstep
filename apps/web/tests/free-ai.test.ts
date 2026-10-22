import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  creditRefusalText, freeAILabel, freeAIMessage, freeAIRefusal, parseBalance, parseFree, parsePeriod, planLabel, PLAN_INFO, resumeDate, type FreeAI,
} from '../src/lib/account-summary';

// Free AI and the accepted plans (migration 0150; docs/PRICING_HOW_IT_WORKS.md): the balance's `free` object, the account
// menu's Plan and Free AI rows, and the words a reader sees when free AI can't pay. Same words as the apps, except that
// credits are bought in the Gradstep app.
const NOV = '2026-11-01T00:00:00+00:00';
const free = (changes: Partial<FreeAI> = {}): FreeAI => ({ monthly: 50, available: 32, usable: true, reason: null, resumes_at: NOV, daily: 20, ...changes });

describe('the balance’s free AI', () => {
  it('is read strictly: absent on older servers, null off the free tier, a bad shape makes the balance unknown', () => {
    expect(parseBalance({ available: 32, reserved: 0, free: free() })).toEqual({ available: 32, reserved: 0, free: free() });
    expect(parseBalance({ available: 0, reserved: 0, free: null })).toEqual({ available: 0, reserved: 0, free: null });
    expect(parseBalance({ available: 5, reserved: 0 })).toEqual({ available: 5, reserved: 0 });
    for (const bad of [{}, 'x', free({ reason: 'stolen' as never }), free({ usable: 'yes' as never }), free({ available: -1 }), free({ monthly: 1.5 }),
      free({ resumes_at: 'soon' }), { ...free(), daily: undefined }]) {
      expect(parseFree(bad)).toBeUndefined();
      expect(parseBalance({ available: 1, reserved: 0, free: bad })).toBeUndefined();
    }
    expect(parseFree(free({ usable: false, reason: 'paused', resumes_at: null }))).toEqual(free({ usable: false, reason: 'paused', resumes_at: null }));
  });

  it('names the plan and its billing period; the ⓘ explains every plan in one paragraph', () => {
    expect([planLabel('standard', 1), planLabel('standard', 12), planLabel('pro', 12), planLabel(null), planLabel(undefined)])
      .toEqual(['Plus', 'Plus (yearly)', 'Pro (yearly)', 'Free', '—']);
    expect([parsePeriod({ plan: 'pro', period_months: 12 }), parsePeriod({ plan: 'pro' }), parsePeriod({ plan: 'pro', period_months: 6 })]).toEqual([12, null, null]);
    expect(PLAN_INFO).toBe('Reading papers is always free. AI uses credits. Free: 50 credits a month (about 15 answers) with the fast models, while this month’s free AI lasts. Plus: 600 credits a month (about 200 answers), every model. Pro: 2,000 credits a month (about 650 answers), every model. Credit packs: 300 or 700 credits that never expire. Plan credits renew each month and don’t carry over. Plans and packs are bought in the Gradstep app on iPhone, iPad or Mac.');
  });

  it('labels the Free AI row', () => {
    expect(resumeDate(NOV)).toBe('November 1');
    expect(resumeDate('2026-12-01T00:00:00Z')).toBe('December 1');
    expect(freeAILabel(free())).toBe('32 of 50 left');
    expect(freeAILabel(free({ usable: false, reason: 'pool' }))).toBe('Used up · back November 1');
    expect(freeAILabel(free({ usable: false, reason: 'used', available: 0 }))).toBe('Used up · back November 1');
    expect(freeAILabel(free({ usable: false, reason: 'account' }))).toBe('Used up · back November 1');
    expect(freeAILabel(free({ usable: false, reason: 'daily', resumes_at: '2026-10-23T00:00:00Z' }))).toBe('Back tomorrow');
    expect(freeAILabel(free({ usable: false, reason: 'paused', resumes_at: null }))).toBe('Paused');
  });

  it('says why free AI can’t pay, in the apps’ words', () => {
    expect(freeAIMessage('pool', NOV)).toBe('This month’s free AI has all been used. It comes back on November 1. Reading is unaffected, and credits bought in the Gradstep app work right away.');
    for (const reason of ['used', 'account'] as const)
      expect(freeAIMessage(reason, NOV)).toBe('You’ve used this month’s free AI. It comes back on November 1. Reading is unaffected, and credits bought in the Gradstep app work right away.');
    expect(freeAIMessage('daily', '2026-10-23T00:00:00Z')).toBe('You’ve used today’s free AI. More tomorrow, or credits bought in the Gradstep app work right away.');
    expect(freeAIMessage('paused', null)).toBe('Free AI is paused for now. Reading is unaffected, and credits bought in the Gradstep app work right away.');
    expect(freeAIMessage(null, null, true)).toBe('Free AI covers the fast models (Gemini Flash, DeepSeek and Haiku). Choose one in AI options, or add credits in the Gradstep app for Sonnet and Opus.');
    expect(freeAIMessage(null, null)).toBeNull();
  });

  it('replaces "not enough credits" only when the balance explains it', () => {
    const generic = (code: string) => `generic ${code}`;
    const pool = { available: 0, reserved: 0, free: free({ usable: false, reason: 'pool' as const }) };
    expect(creditRefusalText('insufficient_credits', generic, pool, 'gemini')).toMatch(/^This month’s free AI has all been used/);
    expect(creditRefusalText('platform_budget_exhausted', generic, pool, 'gemini')).toBe('generic platform_budget_exhausted');
    expect(creditRefusalText('insufficient_credits', generic, { available: 0, reserved: 0, free: null }, 'gemini')).toBe('generic insufficient_credits');
    expect(creditRefusalText('insufficient_credits', generic, undefined, 'sonnet')).toBe('generic insufficient_credits');
    // Free AI can pay, but not for the chosen model.
    const usable = { available: 50, reserved: 0, free: free() };
    expect(freeAIRefusal(usable, 'sonnet')).toMatch(/^Free AI covers the fast models/);
    expect(freeAIRefusal(usable, 'opus')).toMatch(/^Free AI covers the fast models/);
    expect(freeAIRefusal(usable, 'gemini')).toBeNull();
    expect(freeAIRefusal(usable, undefined)).toBeNull();
  });

  it('the account summary carries the plan’s billing period', async () => {
    vi.resetModules();
    vi.doMock('../src/lib/backend', () => ({ rpc: async (name: string) => name === 'v1_store_summary'
      ? { plan: 'standard', product_id: 'com.sciencereader.ios.standard.annual', expires_at: '2027-10-01T00:00:00Z', period_months: 12 }
      : { available: 600, reserved: 0, free: null } }));
    const { loadAccountSummary } = await import('../src/lib/account-summary');
    expect(await loadAccountSummary('account')).toEqual({ balance: { available: 600, reserved: 0, free: null }, plan: 'standard', periodMonths: 12 });
  });
  afterEach(() => { vi.doUnmock('../src/lib/backend'); });
});

// Your AI usage (lib/ai-usage.ts): the page parser, the words both clients show (tests/fixtures/ai-usage.json; Swift
// AIUsageTests), and what this browser remembers about where an operation came from. UPDATE_USAGE_FIXTURE=1 rewrites the
// fixture's expectations from this implementation (review the words in the diff).
import { describe, expect, it } from 'vitest';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  activityLabel, activityName, compact, creditsText, grouped, modelLabel, outcomeLabel, parseUsagePage, partLabel, periodLabel, provenanceFor,
  recallProvenance, rememberProvenance, forgetProvenance, reportsTokens, slicesSummary, tokensText, totalsText, unreportedTokens, usageSlices,
  USAGE_ACTIVITIES, type UsageActivityCount,
  type UsageProvenance, type UsageSlice,
} from '../src/lib/ai-usage';

const FIXTURE = resolve(__dirname, '../../../tests/fixtures/ai-usage.json');
const fixture = JSON.parse(readFileSync(FIXTURE, 'utf8')) as {
  page: unknown; provenance: Record<string, UsageProvenance>; models: string[]; numbers: number[]; slice_cases: UsageActivityCount[][];
  expected: { rows: unknown[]; totals: string; models: string[]; compact: string[]; chips: string[]; slices: unknown[] };
};

function render() {
  const page = parseUsagePage(fixture.page)!;
  return {
    rows: page.operations.map(op => ({
      id: op.id, activity: activityLabel(op.activity, fixture.provenance[op.id]), outcome: outcomeLabel(op.outcome), credits: creditsText(op),
      model: modelLabel(op.model), tokens: tokensText(op),
      parts: op.parts.map(p => ({ label: partLabel(p.part), model: modelLabel(p.model), tokens: tokensText(p, true) })),
    })),
    totals: totalsText(page.totals!),
    models: fixture.models.map(modelLabel),
    compact: fixture.numbers.map(compact),
    chips: page.activities!.map(a => activityName(a.activity)),
    // The All view's ring: the page's own activities, then cases for Other, ties, slivers and nothing to compare.
    slices: [page.activities!, ...fixture.slice_cases].map(list => {
      const slices = usageSlices(list);
      return { slices: slices.map(({ activity, label, credits, percent, slot, members }: UsageSlice) => ({ activity, label, credits, percent, slot, members })),
        summary: slices.length ? slicesSummary(slices) : null };
    }),
  };
}

describe('AI usage', () => {
  it('shows the shared fixture exactly as the apps do', () => {
    const rendered = render();
    if (process.env.UPDATE_USAGE_FIXTURE) writeFileSync(FIXTURE, JSON.stringify({ ...fixture, expected: rendered }, null, 1) + '\n');
    expect(rendered).toEqual(JSON.parse(readFileSync(FIXTURE, 'utf8')).expected);
  });

  it('names chat by what the browser knew', () => {
    expect(activityLabel('chat')).toBe('Chat');
    expect(activityLabel('chat', { kind: 'paper' })).toBe('Paper chat');
    expect(activityLabel('chat', { kind: 'general' })).toBe('General chat');
    expect(activityLabel('chat', { kind: 'explain' })).toBe('Explain in Chat');
    expect(activityLabel('figure_explainer', { kind: 'paper' })).toBe('Figure explainer');
    for (const a of USAGE_ACTIVITIES) expect(activityName(a)).toMatch(/^[A-Z]/);
  });

  it('formats costs and numbers', () => {
    expect(creditsText({ outcome: 'completed', credits: 1, credits_held: 0 })).toBe('1 credit');
    expect(creditsText({ outcome: 'failed', credits: 0, credits_held: 0 })).toBe('0 credits');
    expect(creditsText({ outcome: 'in_progress', credits: null, credits_held: 1200 })).toBe('Up to 1,200');
    expect(creditsText({ outcome: 'free', credits: 0, credits_held: 0 })).toBe('Free');
    expect(grouped(1234567)).toBe('1,234,567');
    expect(tokensText({ input_tokens: 0, cached_tokens: 0, cache_write_tokens: 0, output_tokens: 0, searches: 0, audio_ms: 0, estimated: false })).toBe('—');
    expect(periodLabel(30)).toBe('Last 30 days');
    expect(periodLabel(365)).toBe('Last 12 months');
  });

  // TestFlight 92: a question that didn't finish read "132k in · 10k out", what was set aside for it, not what was used.
  it('shows tokens only for requests the provider finished', () => {
    for (const outcome of ['completed', 'stopped', 'free'] as const) expect(reportsTokens(outcome)).toBe(true);
    for (const outcome of ['failed', 'not_charged', 'in_progress', 'checking'] as const) expect(reportsTokens(outcome)).toBe(false);
    expect(unreportedTokens('failed')).toContain('isn’t what was used');
    expect(unreportedTokens('completed')).toBeNull();
    expect(outcomeLabel('failed')).toBe('Didn’t finish · not charged');
  });

  it('refuses a reply that is not a page', () => {
    const page = fixture.page as { operations: Record<string, unknown>[] };
    expect(parseUsagePage(null)).toBeUndefined();
    expect(parseUsagePage({ ...page, operations: [{ ...page.operations[0], credits: -1 }] })).toBeUndefined();
    // A newer server's activity is shown as Other, not refused.
    expect(parseUsagePage({ ...page, operations: [{ ...page.operations[0], activity: 'mining' }] })?.operations[0].activity).toBe('other');
    expect(parseUsagePage({ ...page, operations: [{ ...page.operations[0], activity: 7 }] })).toBeUndefined();
    expect(parseUsagePage({ ...page, operations: [{ ...page.operations[0], outcome: 'won' }] })).toBeUndefined();
    expect(parseUsagePage({ ...page, operations: [{ ...page.operations[0], id: 'x' }] })).toBeUndefined();
    expect(parseUsagePage({ ...page, next: { created_at: 'soon', id: page.operations[0].id } })).toBeUndefined();
    expect(parseUsagePage({ ...page, totals: null, activities: null })?.totals).toBeNull();
  });

  it('remembers where an answer came from, in this browser only', () => {
    const data = new Map<string, string>();
    const storage = { getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => { data.set(k, v); }, removeItem: (k: string) => { data.delete(k); } };
    const context = { format: 'reader-local-context-v2' as const, membership_id: 'm-1', source: 'arxiv' as const, source_id: '2305.18290', revision: 3,
      manifest_sha256: 'a', source_sha256: 'b', text: 'paper' };
    expect(provenanceFor({ documentID: null, localContext: undefined, selection: null, action: null })).toEqual({ kind: 'general' });
    expect(provenanceFor({ documentID: null, localContext: context, selection: null, action: null })).toEqual({ kind: 'paper', membership: 'm-1' });
    expect(provenanceFor({ documentID: null, localContext: context, selection: 'a passage', action: null })).toEqual({ kind: 'explain', membership: 'm-1' });
    expect(provenanceFor({ documentID: null, localContext: context, selection: 'a passage', action: 'related' }).kind).toBe('paper');
    const op = '0d6c3e2a-6f43-4a39-9a7e-1c1a2b3c4d5e';
    rememberProvenance('acct', op, { kind: 'explain', membership: 'm-1' }, storage);
    rememberProvenance('acct', 'not-a-uuid', { kind: 'paper' }, storage);
    expect(recallProvenance('acct', storage).get(op)).toEqual({ kind: 'explain', membership: 'm-1' });
    expect(recallProvenance('acct', storage).size).toBe(1);
    expect(recallProvenance('other', storage).size).toBe(0);
    // Nothing but the kind and the library's own ids: no title, no text.
    expect([...data.values()].join()).not.toMatch(/paper|passage|2305/);
    for (let n = 0; n < 2_005; n++) rememberProvenance('acct', `0d6c3e2a-6f43-4a39-9a7e-${n.toString(16).padStart(12, '0')}`, { kind: 'general' }, storage);
    expect(recallProvenance('acct', storage).size).toBe(2_000);
    forgetProvenance('acct', storage);
    expect(recallProvenance('acct', storage).size).toBe(0);
    expect(recallProvenance('acct', { getItem: () => { throw new Error('blocked'); } }).size).toBe(0);
    expect(() => rememberProvenance('acct', op, { kind: 'paper' }, { getItem: () => null, setItem: () => { throw new Error('full'); } })).not.toThrow();
  });
});

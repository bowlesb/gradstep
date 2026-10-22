// The figures activity's default (owner, 2026-10-22: "Let's try Gemini instead of Sonnet for Figures then"; it was Sonnet ·
// low earlier that day): the table's `default_figures` (Gemini Flash · Standard, run at low effort by the server), else
// Gemini where offered, else the server's default; never the reader's general choice. A saved figures choice is kept,
// except one equal to the short-lived Sonnet default, let go once (`figuresDefaultV3`), so a later explicit Sonnet choice
// sticks. Other activities are unchanged.
import { readFileSync } from 'node:fs';
import { afterEach, expect, it, vi } from 'vitest';
import { decodeProfileTable, type ProfileChoice } from '../src/lib/chat-profiles';
vi.mock('../src/lib/backend', async original => {
  const mod = await original<typeof import('../src/lib/backend')>();
  return { ...mod, rpc: async (name: string, p: any) => name === 'v3_pull_events' ? { events: [], next_cursor: p.p_after, has_more: false }
    : name === 'v1_credit_balance' ? { available: 100, reserved: 0 } : null };
});
const { ChatSession } = await import('../src/lib/chat-session');
const { History } = await import('../src/lib/history');
const { keyRing, generateBundle } = await import('../src/lib/wire');
// The server's table (tests/fixtures/chat-profiles-gemini.json, copied here): recommended Gemini, figures Gemini.
const table = JSON.parse(readFileSync(new URL('./fixtures/chat-profiles-gemini.json', import.meta.url), 'utf8'));
const account = '11111111-2222-4333-8444-555555555555', device = 'aaaaaaaa-0000-4000-8000-000000000001', key = 'gradstep.ai.scenarios.v1';
const sonnetLow: ProfileChoice = { model: 'sonnet', effort: 'low', length: 'standard' }, geminiMedium: ProfileChoice = { model: 'gemini', effort: 'medium', length: 'standard' };
const deepseekLow: ProfileChoice = { model: 'deepseek', effort: 'low', length: 'standard' };

function storage(initial: Record<string, unknown> | null) {
  const stored = new Map<string, string>(initial ? [[key, JSON.stringify(initial)]] : []);
  vi.stubGlobal('localStorage', { getItem: (k: string) => stored.get(k) ?? null, setItem: (k: string, v: string) => { stored.set(k, v); }, removeItem: (k: string) => { stored.delete(k); } });
  return () => JSON.parse(stored.get(key) ?? 'null');
}
async function session(raw: unknown = table, general: ProfileChoice | null = null) {
  const owner = new AbortController(), ring = await keyRing(generateBundle(account));
  const history = new History(account, device, ring, owner.signal, async () => ring); await history.sync();
  const chat = new ChatSession(account, history, owner.signal, { readConsent: () => true, writeConsent: () => {}, fetchProfiles: async () => raw,
    readDefault: () => general, writeDefault: () => {}, stream: async function* () {} });
  await chat.profiles.load();
  return chat;
}
afterEach(() => vi.unstubAllGlobals());

it('a new reader’s figures default is the table’s figures default (Gemini Flash), not the general one', async () => {
  storage(null);
  const chat = await session();
  expect(chat.profileTable!.figuresDefault).toEqual(geminiMedium);
  expect(chat.scenarioProfile('figures')).toEqual(geminiMedium);
  expect(chat.scenarioProfile('general')).toEqual(geminiMedium); expect(chat.scenarioProfile('paper')).toEqual(geminiMedium);
});

it('no longer inherits the reader’s general default (DeepSeek)', async () => {
  storage(null);
  const chat = await session(table, deepseekLow);
  expect(chat.defaultProfile).toEqual(deepseekLow);
  expect(chat.scenarioProfile('paper')).toEqual(deepseekLow); // other activities unchanged
  expect(chat.scenarioProfile('figures')).toEqual(geminiMedium);
});

it('falls back: without default_figures to Gemini where offered, without Gemini to the server’s default', async () => {
  storage(null);
  const { default_figures: _, ...older } = table;
  expect(decodeProfileTable(older)!.figuresDefault).toBeNull();
  expect((await session(older, deepseekLow)).scenarioProfile('figures')).toEqual(geminiMedium);
  const { default_recommended: __, ...noGemini } = { ...older, models: older.models.filter((m: { id: string }) => m.id !== 'gemini'),
    profiles: older.profiles.filter((p: { model: string }) => p.model !== 'gemini') };
  const fallback = await session(noGemini, deepseekLow);
  expect(fallback.scenarioProfile('figures')).toEqual(fallback.profileTable!.autoDefault
    ? { model: fallback.profileTable!.autoDefault.model, effort: fallback.scenarioProfile('figures').effort, length: 'standard' } : fallback.profileTable!.defaultChoice);
  expect(fallback.scenarioProfile('figures').model).toBe('sonnet');
  // A default_figures the table doesn't offer is ignored.
  expect(decodeProfileTable({ ...noGemini, default_figures: geminiMedium })!.figuresDefault).toBeNull();
  expect(decodeProfileTable({ ...table, default_figures: { model: 'gemini', effort: 'medium' } })!.figuresDefault).toBeNull();
});

it('keeps a saved figures choice (DeepSeek, Gemini)', async () => {
  const saved = storage({ figures: deepseekLow, paper: geminiMedium });
  expect((await session()).scenarioProfile('figures')).toEqual(deepseekLow);
  expect(saved()).toEqual({ figures: deepseekLow, paper: geminiMedium, figuresDefaultV3: true });
  storage({ figures: geminiMedium, figuresDefaultV2: true });
  expect((await session()).scenarioProfile('figures')).toEqual(geminiMedium);
});

it('lets go of a saved Sonnet · low figures choice once; a Sonnet choice made after sticks; the recommended default is Gemini', async () => {
  const saved = storage({ figures: sonnetLow, paper: sonnetLow, figuresDefaultV2: true });
  const chat = await session();
  expect(chat.scenarioProfile('figures')).toEqual(geminiMedium); expect(chat.scenarioProfile('paper')).toEqual(sonnetLow);
  expect(saved()).toEqual({ paper: sonnetLow, figuresDefaultV3: true });
  chat.setScenarioProfile('figures', sonnetLow);
  expect(saved()).toEqual({ paper: sonnetLow, figures: sonnetLow, figuresDefaultV3: true });
  const later = await session();
  expect(later.scenarioProfile('figures')).toEqual(sonnetLow);
  // Use the recommended default: the figures default again.
  later.resetScenarioProfile('figures');
  expect(later.scenarioProfile('figures')).toEqual(geminiMedium); expect(saved()).toEqual({ paper: sonnetLow, figuresDefaultV3: true });
});

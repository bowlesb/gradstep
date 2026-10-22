// The figures activity's default (owner, 2026-10-22: "change the default to Sonnet for that one"): the table's
// `default_figures`, else Sonnet · low · Standard where offered, else the server's default; never the reader's general
// choice. A saved figures choice is kept, except one equal to the old recommended default (Gemini · medium · Standard),
// let go once (`figuresDefaultV2`), so a later explicit Gemini choice sticks. Other activities are unchanged.
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
// The server's table (tests/fixtures/chat-profiles-gemini.json, copied here): recommended Gemini, figures Sonnet.
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

it('a new reader’s figures default is the table’s figures default (Sonnet · low), not the general one', async () => {
  storage(null);
  const chat = await session();
  expect(chat.profileTable!.figuresDefault).toEqual(sonnetLow);
  expect(chat.scenarioProfile('figures')).toEqual(sonnetLow);
  expect(chat.scenarioProfile('general')).toEqual(geminiMedium); expect(chat.scenarioProfile('paper')).toEqual(geminiMedium);
});

it('no longer inherits the reader’s general default (DeepSeek)', async () => {
  storage(null);
  const chat = await session(table, deepseekLow);
  expect(chat.defaultProfile).toEqual(deepseekLow);
  expect(chat.scenarioProfile('paper')).toEqual(deepseekLow); // other activities unchanged
  expect(chat.scenarioProfile('figures')).toEqual(sonnetLow);
});

it('falls back: without default_figures to Sonnet · low · Standard, without Sonnet to the server’s default', async () => {
  storage(null);
  const { default_figures: _, ...older } = table;
  expect(decodeProfileTable(older)!.figuresDefault).toBeNull();
  expect((await session(older, deepseekLow)).scenarioProfile('figures')).toEqual(sonnetLow);
  const { default_auto: __, ...withoutAuto } = older;
  const noSonnet = { ...withoutAuto, default: geminiMedium, profiles: older.profiles.filter((p: { model: string; length: string }) => !(p.model === 'sonnet' && p.length === 'standard')) };
  expect((await session(noSonnet, deepseekLow)).scenarioProfile('figures')).toEqual(geminiMedium);
  // A default_figures the table doesn't offer is ignored.
  const unoffered = { ...table, default: geminiMedium, default_figures: sonnetLow, profiles: table.profiles.filter((p: { model: string; length: string }) => !(p.model === 'sonnet' && p.length === 'standard')) };
  expect(decodeProfileTable(unoffered)!.figuresDefault).toBeNull();
  expect(decodeProfileTable({ ...table, default_figures: { model: 'sonnet', effort: 'low' } })!.figuresDefault).toBeNull();
});

it('keeps a saved figures choice (DeepSeek)', async () => {
  const saved = storage({ figures: deepseekLow, paper: geminiMedium });
  expect((await session()).scenarioProfile('figures')).toEqual(deepseekLow);
  expect(saved()).toEqual({ figures: deepseekLow, paper: geminiMedium, figuresDefaultV2: true });
});

it('lets go of a saved Gemini · medium figures choice once; a Gemini choice made after sticks; the recommended default is Sonnet', async () => {
  const saved = storage({ figures: geminiMedium, paper: geminiMedium });
  const chat = await session();
  expect(chat.scenarioProfile('figures')).toEqual(sonnetLow); expect(chat.scenarioProfile('paper')).toEqual(geminiMedium);
  expect(saved()).toEqual({ paper: geminiMedium, figuresDefaultV2: true });
  chat.setScenarioProfile('figures', geminiMedium);
  expect(saved()).toEqual({ paper: geminiMedium, figures: geminiMedium, figuresDefaultV2: true });
  const later = await session();
  expect(later.scenarioProfile('figures')).toEqual(geminiMedium);
  // Use the recommended default: the figures default again.
  later.resetScenarioProfile('figures');
  expect(later.scenarioProfile('figures')).toEqual(sonnetLow); expect(saved()).toEqual({ paper: geminiMedium, figuresDefaultV2: true });
});

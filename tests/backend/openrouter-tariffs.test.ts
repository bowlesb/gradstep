import test from 'node:test';
import assert from 'node:assert/strict';
import { ACCEPT_MARGIN_MS, PUBLISH_MARGIN_MS, tariffOpen, tariffValidity } from '../../supabase/functions/_shared/openrouter-tariffs.ts';
import { publishedProfiles } from '../../supabase/functions/_shared/chat-profiles.ts';
import { runChat, type ChatDependencies, type ChatEvent } from '../../supabase/functions/_shared/chat.ts';

const NOW = Date.parse('2026-12-31T00:00:00Z');
const policy = { tavily_enabled: false, openrouter_tariffs: {
  'gemini-3.8-flash': '2027-01-01T00:00:00+00:00', 'anthropic/claude-sonnet-5.5': '2027-03-01T00:00:00+00:00',
  'anthropic/claude-haiku-5.5': '2027-03-01T00:00:00+00:00', 'anthropic/claude-opus-5.5': '2027-03-01T00:00:00+00:00' } };

test('A4: card validity comes from the table; a lapse is seen a day ahead for publishing and ten minutes for answers', () => {
  const validity = tariffValidity(policy);
  // Gemini lapses in 24 h: no longer published (clients keep the table), still accepted for a moment.
  assert.equal(tariffOpen(validity, 'gemini-3.8-flash', PUBLISH_MARGIN_MS, NOW), false);
  assert.equal(tariffOpen(validity, 'gemini-3.8-flash', ACCEPT_MARGIN_MS, NOW), true);
  assert.equal(tariffOpen(validity, 'gemini-3.8-flash', ACCEPT_MARGIN_MS, Date.parse('2026-12-31T23:55:00Z')), false, 'within ten minutes: refused');
  assert.equal(tariffOpen(validity, 'deepseek/deepseek-v4.1-flash-1017', 0, NOW), false, 'a model without a card is not open');
  assert.equal(tariffOpen(tariffValidity(null), 'gemini-3.8-flash', PUBLISH_MARGIN_MS, NOW), true, 'unreadable: admission decides');
  assert.equal(tariffValidity({ openrouter_tariffs: [] }), null);
});

test('A4: the published table drops a model whose card lapses within a day, and stops recommending it', () => {
  const validity = tariffValidity(policy);
  const table = publishedProfiles({ deepseek: false, gemini: true, claudeOpenRouter: true, available: model => tariffOpen(validity, model, PUBLISH_MARGIN_MS, NOW) });
  assert.ok(!table.models.some(m => m.id === 'gemini')); assert.ok(!table.profiles.some(p => p.model === 'gemini'));
  assert.equal(table.default_recommended, undefined);
  assert.ok(table.models.some(m => m.id === 'sonnet'), 'Claude, valid until March, is still offered');
  const open = publishedProfiles({ deepseek: false, gemini: true, claudeOpenRouter: true, available: () => true });
  assert.deepEqual(open.default_recommended, { model: 'gemini', effort: 'medium', length: 'standard' });
});

test('A4: a request for a model whose card lapses is model_unavailable before any hold, and side requests skip a lapsed model', async () => {
  const calls: string[] = [], events: ChatEvent[] = [];
  const deps: ChatDependencies = { accountID: 'aaaaaaaa-0000-4000-8000-000000000001', claudeOpenRouter: true, gemini: true,
    rpc: async name => { calls.push(name); return null; }, sha256Hex: async () => 'a'.repeat(64), loadPaper: async () => null, log: () => {},
    generate: async () => { throw new Error('must not send'); }, modelAvailable: async model => model !== 'gemini-3.8-flash' };
  await runChat(deps, { operation_id: 'bbbbbbbb-0000-4000-8000-000000000001', consent_version: 'cloud-ai-v6', mode: 'general',
    messages: [{ role: 'user', text: 'Hi' }], profile: { model: 'gemini', effort: 'medium', length: 'standard' } }, e => events.push(e), new AbortController().signal);
  assert.deepEqual(events, [{ event: 'error', data: { code: 'model_unavailable' } }], 'no retry_after: retrying cannot help');
  assert.ok(!calls.includes('worker_reserve_chat'), 'nothing is held');

  // Claude answers; its Haiku title is skipped when Haiku's card has lapsed (never refused after a hold).
  const sent: string[] = [], reserved: Record<string, unknown>[] = [];
  const withTitle: ChatDependencies = { ...deps, modelAvailable: async model => model !== 'anthropic/claude-haiku-5.5',
    rpc: async (name, p) => { calls.push(name); if (name === 'worker_reserve_chat') { reserved.push(p); return { replayed: false }; } return null; },
    generate: async (params, stream) => { sent.push(params.model); stream.onText('An answer.');
      return { status: 'complete', failure: null, messageID: 'm', model: params.model, stopReason: 'end_turn', refusalCategory: null, exact: true,
        attempts: [{ model: params.model, estimated: false, billedMicrousd: 100, usage: { input: 10, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 10 } }] }; } };
  await runChat(withTitle, { operation_id: 'bbbbbbbb-0000-4000-8000-000000000002', consent_version: 'cloud-ai-v6', mode: 'general', topic_title: true,
    follow_ups: true, messages: [{ role: 'user', text: 'Hi' }], profile: { model: 'sonnet', effort: 'low', length: 'brief' } }, () => {}, new AbortController().signal);
  assert.deepEqual(sent, ['anthropic/claude-sonnet-5.5'], 'no title or suggestion request');
  assert.equal((reserved[0].p_quote as Record<string, unknown>).title_model, null);
});

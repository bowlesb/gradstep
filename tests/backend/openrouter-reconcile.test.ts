import test from 'node:test';
import assert from 'node:assert/strict';
import { reconcileOpenRouterAttempts, sameModel } from '../../supabase/functions/_shared/openrouter-reconcile.ts';

const account = 'aaaaaaaa-0000-4000-8000-000000000001', operation = 'bbbbbbbb-0000-4000-8000-000000000001';
const claim = (n: number, extra: Record<string, unknown> = {}) => ({ attempt_id: `cccccccc-0000-4000-8000-00000000000${n}`, account_id: account, operation_id: operation,
  generation_id: `gen-${n}`, transport_model: 'anthropic/claude-sonnet-5.5', feature: 'chat', ...extra });
const record = (id: string, extra: Record<string, unknown> = {}) => ({ data: { id, model: 'anthropic/claude-sonnet-5.5', provider_name: 'Google',
  external_user: account, session_id: operation, native_tokens_prompt: 40_000, native_tokens_cached: 30_000, native_tokens_completion: 900,
  total_cost: 0.0512, cancelled: true, finish_reason: null, ...extra } });

test('A6: unresolved attempts settle at their generation record; misses are recorded for back-off; nothing is bought', async () => {
  const calls: { name: string; p: Record<string, any> }[] = [], gets: string[] = [];
  const result = await reconcileOpenRouterAttempts({
    keyFor: feature => feature === 'chat' ? 'chat-key' : null,
    rpc: async (name, p) => { calls.push({ name, p });
      if (name === 'worker_openrouter_reconcile_claim') return [claim(1), claim(2), claim(3, { generation_id: 'gen-3' }), claim(4, { feature: 'catalog_tags' }), claim(5)];
      if (name === 'worker_openrouter_reconcile') return { reconciled: true };
      return null; },
    fetch: async (url, init) => {
      assert.equal(init?.method, undefined, 'only GETs'); assert.equal(new Headers(init?.headers).get('authorization'), 'Bearer chat-key');
      const id = new URL(String(url)).searchParams.get('id')!; gets.push(id);
      if (id === 'gen-2') return new Response(null, { status: 404 });
      if (id === 'gen-3') return Response.json(record(id, { external_user: operation })); // another account: never believed
      if (id === 'gen-5') return Response.json(record(id, { model: 'openai/other-model' }));
      return Response.json(record(id));
    } });
  assert.deepEqual(result, { claimed: 5, reconciled: 1, missing: 4, failed: 0, assumedZero: 0 });
  assert.deepEqual(gets, ['gen-1', 'gen-2', 'gen-3', 'gen-5'], 'one GET per attempt per run; no key, no request');
  const done = calls.find(c => c.name === 'worker_openrouter_reconcile')!.p;
  assert.deepEqual(done, { p_attempt_id: claim(1).attempt_id, p_generation_id: 'gen-1', p_actual_microusd: 51_200,
    p_receipt: { generation_id: 'gen-1', provider: 'Google', model: 'anthropic/claude-sonnet-5.5', total_cost_microusd: 51_200 },
    p_units: { input_tokens: 10_000, cache_read_tokens: 30_000, output_tokens: 900 } });
  assert.deepEqual(calls.filter(c => c.name === 'worker_openrouter_reconcile_miss').map(c => [c.p.p_attempt_id.slice(-1), c.p.p_outcome]),
    // 0162: a record for another account is still a record of this generation: a mismatch, never "not found".
    [['2', 'not_found'], ['3', 'mismatch'], ['4', 'no_key'], ['5', 'mismatch']]);
  assert.ok(!calls.some(c => c.name === 'worker_openrouter_reconcile_absent'), 'nothing is assumed before the 12th try');
});

test('A6: the run is bounded in time and survives a database refusal', async () => {
  let clock = 0;
  const result = await reconcileOpenRouterAttempts({ keyFor: () => 'k', now: () => (clock += 20_000),
    rpc: async name => { if (name === 'worker_openrouter_reconcile_claim') return [claim(1), claim(2), claim(3)];
      if (name === 'worker_openrouter_reconcile') throw new Error('invalid_reconciliation'); return null; },
    fetch: async url => Response.json(record(new URL(String(url)).searchParams.get('id')!)) }, { budgetMs: 30_000 });
  assert.equal(result.claimed, 3); assert.ok(result.failed + result.reconciled < 3, 'stops when the time budget is spent');
  assert.deepEqual(await reconcileOpenRouterAttempts({ keyFor: () => 'k', rpc: async () => null }), { claimed: 0, reconciled: 0, missing: 0, failed: 0, assumedZero: 0 });
});

test('0162: a clean 404 on a final try (or no generation id) asks the database to assume zero; nothing else does', async () => {
  const calls: { name: string; p: Record<string, any> }[] = [], gets: string[] = [];
  const claims = [
    claim(1, { final: true }),                                   // 404: assumed zero
    claim(2, { final: true }),                                   // our key refused (401): unreadable, never assumed
    claim(3, { final: true, generation_id: null }),              // no generation id was issued: no lookup, assumed zero
    claim(4, { generation_id: null }),                           // the same, before its 12th try: only a miss
    claim(5, { final: true }),                                   // 404 but the database refuses (output arrived, an open operation…)
    claim(6, { assumed_zero: true }),                            // assumed zero earlier; a late record now exists
    claim(7, { assumed_zero: true }),                            // assumed zero earlier; still no record
    claim(8, { final: true }),                                   // a 500: unreadable
    claim(9, { final: true }),                                   // the database call fails
    claim(1, { attempt_id: 'cccccccc-0000-4000-8000-000000000010', final: true, feature: 'catalog_tags' })]; // no key: never assumed
  const result = await reconcileOpenRouterAttempts({
    keyFor: feature => feature === 'chat' ? 'chat-key' : null,
    rpc: async (name, p) => { calls.push({ name, p });
      if (name === 'worker_openrouter_reconcile_claim') return claims;
      if (name === 'worker_openrouter_reconcile_absent') {
        if (p.p_attempt_id.endsWith('9')) throw new Error('invalid_reconciliation');
        return { settled: !p.p_attempt_id.endsWith('5') };
      }
      if (name === 'worker_openrouter_reconcile') return { reconciled: true, corrected: true };
      return null; },
    fetch: async url => {
      const id = new URL(String(url)).searchParams.get('id')!; gets.push(id);
      if (id === 'gen-2') return new Response('expired', { status: 401 });
      if (id === 'gen-8') return new Response('down', { status: 500 });
      if (id === 'gen-6') return Response.json(record(id));
      return new Response(null, { status: 404 });
    } }, { batch: 20 });
  assert.deepEqual(result, { claimed: 10, reconciled: 1, missing: 6, failed: 1, assumedZero: 2 });
  assert.deepEqual(gets, ['gen-1', 'gen-2', 'gen-5', 'gen-6', 'gen-7', 'gen-8', 'gen-9'], 'no GET without a generation id or a key');
  assert.deepEqual(calls.filter(c => c.name === 'worker_openrouter_reconcile_absent').map(c => [c.p.p_attempt_id.slice(-1), c.p.p_generation_id]),
    [['1', 'gen-1'], ['3', null], ['5', 'gen-5'], ['9', 'gen-9']], 'asked only after a clean 404 (or no id) on a final try');
  assert.deepEqual(calls.filter(c => c.name === 'worker_openrouter_reconcile_miss').map(c => [c.p.p_attempt_id.slice(-2), c.p.p_outcome]),
    [['02', 'unreadable'], ['04', 'not_found'], ['07', 'not_found'], ['08', 'unreadable'], ['10', 'no_key']],
    'a refused assumption is recorded by the database itself; a late check that finds nothing stays assumed');
  assert.equal(calls.find(c => c.name === 'worker_openrouter_reconcile')!.p.p_attempt_id, claim(6).attempt_id, 'a late record corrects the assumed zero');
});

test('a dated slug and its undated name are the same model; anything else is a mismatch', () => {
  assert.ok(sameModel('deepseek/deepseek-v4.1-flash', 'deepseek/deepseek-v4.1-flash-1017'), 'read back without the dispatch date');
  // OpenRouter's actual record of the 2026-10-22 DeepSeek attempt (looked up 2026-10-25): the date written in full.
  assert.ok(sameModel('deepseek/deepseek-v4.1-flash-20261017', 'deepseek/deepseek-v4.1-flash-1017'), 'the same date in full');
  assert.ok(sameModel('deepseek/deepseek-v4-pro-20260813', 'deepseek/deepseek-v4-pro-0813'));
  assert.ok(!sameModel('deepseek/deepseek-v4.1-flash-20261018', 'deepseek/deepseek-v4.1-flash-1017'), 'another date');
  assert.ok(!sameModel('deepseek/deepseek-v4.1-pro-20261017', 'deepseek/deepseek-v4.1-flash-1017'), 'another model on the same date');
  assert.ok(sameModel('google/gemini-3.8-flash-20261017', 'google/gemini-3.8-flash'), 'a dated release of the slug');
  assert.ok(sameModel('anthropic/claude-sonnet-5.5', 'anthropic/claude-sonnet-5.5'));
  assert.ok(sameModel('google/gemini-3.8-flash-preview-0915', 'google/gemini-3.8-flash'), 'a longer release, as before');
  assert.ok(!sameModel('deepseek/deepseek-v4.1-flash', 'deepseek/deepseek-v4.1-flash-lite'), 'only a date may be dropped');
  assert.ok(!sameModel('deepseek/deepseek-v4.1', 'deepseek/deepseek-v4.1-flash-1017'));
  assert.ok(!sameModel('openai/other-model', 'anthropic/claude-sonnet-5.5'));
});

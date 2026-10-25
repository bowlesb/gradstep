import test from 'node:test';
import assert from 'node:assert/strict';
import { generationRecord, lookupGeneration, readGeneration } from '../../supabase/functions/_shared/openrouter-generation.ts';

const identity = { accountID: 'aaaaaaaa-0000-4000-8000-000000000001', operationID: 'bbbbbbbb-0000-4000-8000-000000000001' };
const record = { id: 'gen-1', model: 'anthropic/claude-sonnet-5.5', provider_name: 'Google', external_user: identity.accountID,
  session_id: identity.operationID, native_tokens_prompt: 1000, native_tokens_completion: 200, native_tokens_cached: 800,
  total_cost: 0.0012345, cancelled: true, finish_reason: 'stop' };

test('a generation record is believed only for its own generation, account and operation, within bounds', () => {
  const parsed = generationRecord({ data: record }, 'gen-1', identity)!;
  assert.deepEqual(parsed, { id: 'gen-1', model: record.model, provider: 'Google', totalMicrousd: 1235, promptTokens: 1000, completionTokens: 200,
    cachedTokens: 800, cancelled: true, finishReason: 'stop' });
  for (const changed of [{ id: 'gen-2' }, { external_user: identity.operationID }, { session_id: identity.accountID }, { total_cost: -1 },
    { total_cost: 31 }, { total_cost: '0.1' }, { native_tokens_prompt: -1 }, { native_tokens_cached: 1001 }, { model: 'bad model\n' },
    { provider_name: 7 }]) assert.equal(generationRecord({ data: { ...record, ...changed } }, 'gen-1', identity), null, JSON.stringify(changed));
  assert.equal(generationRecord({ data: { ...record, native_tokens_cached: null } }, 'gen-1', identity)?.cachedTokens, 0);
  // An unexpected finish reason is never passed through as text and never reads as `stop`.
  assert.equal(generationRecord({ data: { ...record, finish_reason: 'Stopped by <script>' } }, 'gen-1', identity)?.finishReason, 'other');
});

import { rpcAttribution } from '../../supabase/functions/_shared/openrouter-transport.ts';
test('C6: a dispatch recorded with the admission sends only exactly that metadata, once; anything else asks the database', async () => {
  const calls: string[] = [];
  const deps = { accountID: identity.accountID, operationID: identity.operationID, rpc: async (name: string) => { calls.push(name); return false; } };
  const recorded = { transport_model: 'anthropic/claude-sonnet-5.5', endpoint: 'google-vertex/us', feature: 'chat', caller: 'chat' };
  const attribution = rpcAttribution(deps, 'cccccccc-0000-4000-8000-000000000001', 'chat', 'chat', recorded);
  assert.equal(await attribution.dispatch({ ...recorded }), true); assert.deepEqual(calls, [], 'no second round trip');
  assert.equal(await attribution.dispatch({ ...recorded }), false, 'never twice'); assert.deepEqual(calls, ['worker_openrouter_dispatch']);
  const other = rpcAttribution(deps, 'cccccccc-0000-4000-8000-000000000002', 'chat', 'chat', recorded);
  assert.equal(await other.dispatch({ ...recorded, endpoint: 'deepinfra/fp8' }), false, 'a different endpoint is never sent on the recorded dispatch');
});

test('the lookup waits for a 404 with bounded tries, stops on other errors and never throws', async () => {
  const waits: number[] = [];
  let gets = 0;
  const found = await lookupGeneration({ apiKey: 'k', sleep: async ms => { waits.push(ms); }, fetch: async (url, init) => {
    assert.match(String(url), /^https:\/\/openrouter\.ai\/api\/v1\/generation\?id=gen-1$/);
    assert.equal(new Headers(init?.headers).get('authorization'), 'Bearer k'); assert.equal(init?.method, undefined, 'a GET buys nothing');
    return ++gets < 3 ? new Response(null, { status: 404 }) : Response.json({ data: record });
  } }, 'gen-1', identity, new AbortController().signal);
  assert.equal(found?.totalMicrousd, 1235); assert.deepEqual(waits, [250, 500]);
  let tries = 0;
  assert.equal(await lookupGeneration({ apiKey: 'k', sleep: async () => {}, fetch: async () => { tries++; return new Response(null, { status: 404 }); } },
    'gen-1', identity, new AbortController().signal, 4), null);
  assert.equal(tries, 4);
  tries = 0;
  assert.equal(await lookupGeneration({ apiKey: 'k', fetch: async () => { tries++; return new Response('no', { status: 500 }); } }, 'gen-1', identity, new AbortController().signal), null);
  assert.equal(tries, 1);
  assert.equal(await lookupGeneration({ apiKey: 'k', fetch: async () => { throw new Error('secret'); } }, 'gen-1', identity, new AbortController().signal), null);
  assert.equal(await lookupGeneration({ apiKey: 'k', fetch: async () => new Response('x'.repeat(70_000)) }, 'gen-1', identity, new AbortController().signal), null);
  assert.equal(await lookupGeneration({ apiKey: 'k', fetch: async () => { throw new Error('must not fetch'); } }, 'bad id/../', identity, new AbortController().signal), null);
});

test('0162: only a 404 on every read is "absent"; a record that fails its checks exists; anything else is unreadable', async () => {
  const read = (fetch: typeof globalThis.fetch, id = 'gen-1', tries = 2) =>
    readGeneration({ apiKey: 'k', sleep: async () => {}, fetch }, id, identity, new AbortController().signal, tries);
  assert.deepEqual(await read(async () => new Response(null, { status: 404 })), { missing: 'absent' });
  assert.equal(('record' in await read(async () => Response.json({ data: record }))), true);
  // OpenRouter's record of this generation, for another account or implausible: a record exists (never "not found").
  assert.deepEqual(await read(async () => Response.json({ data: { ...record, external_user: identity.operationID } })), { missing: 'invalid' });
  assert.deepEqual(await read(async () => Response.json({ data: { ...record, total_cost: 31 } })), { missing: 'invalid' });
  // Our expired key, a server error, a timeout, a body that is not this generation's record: nothing is known.
  for (const status of [401, 402, 403, 429, 500, 503]) assert.deepEqual(await read(async () => new Response('no', { status })), { missing: 'unreadable' }, String(status));
  let n = 0;
  assert.deepEqual(await read(async () => ++n === 1 ? new Response(null, { status: 404 }) : new Response('no', { status: 500 })), { missing: 'unreadable' },
    'a 404 then a 500 is not a clean answer');
  assert.deepEqual(await read(async () => { throw new DOMException('timed out', 'TimeoutError'); }), { missing: 'unreadable' });
  assert.deepEqual(await read(async () => new Response('<html>proxy</html>')), { missing: 'unreadable' });
  assert.deepEqual(await read(async () => Response.json({ data: null })), { missing: 'unreadable' });
  assert.deepEqual(await read(async () => Response.json({ data: { ...record, id: 'gen-9' } })), { missing: 'unreadable' });
  assert.deepEqual(await read(async () => new Response('x'.repeat(70_000))), { missing: 'unreadable' });
  assert.deepEqual(await read(async () => { throw new Error('must not fetch'); }, 'bad id/../'), { missing: 'unreadable' });
});

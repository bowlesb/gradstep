import assert from 'node:assert/strict';
import test from 'node:test';
import { recordSpendingOnce, pendingSpendingEntries, retrySpendingObservation } from '../../apps/admin/src/spending-retry.ts';
import type { SpendingObservationDraft, SpendingObservationRequest, SpendingObservationReceipt } from '../../supabase/functions/_shared/spending-observations.ts';

const OWNER = '37000000-0000-0000-0000-00000000000a', OTHER = '37000000-0000-0000-0000-00000000000b';
const draft = (): SpendingObservationDraft => ({ component: 'tavily_subscription', period: new Date().toISOString().slice(0, 7) + '-01',
  measure: 'invoice', amount_microusd: 30_000_000, complete: false, evidence_reference: 'private-vendor-invoice-reference' });
function storage() {
  const entries = new Map<string, string>();
  return { entries, getItem: (key: string) => entries.get(key) ?? null, setItem: (key: string, value: string) => { entries.set(key, value); }, removeItem: (key: string) => { entries.delete(key); } };
}

test('lost acknowledgment and recreated client reuse every field, ID and original timestamp without storing form contents', async () => {
  const journal = storage(), requests: SpendingObservationRequest[] = [], records = new Map<string, string>();
  const receiver = async (request: SpendingObservationRequest): Promise<SpendingObservationReceipt> => {
    requests.push(structuredClone(request)); const existing = records.get(request.request_id);
    if (existing) assert.equal(JSON.stringify(request), existing); else records.set(request.request_id, JSON.stringify(request));
    if (requests.length === 1) throw new Error('lost ack after commit');
    return { id: request.request_id, replayed: !!existing };
  };
  await assert.rejects(recordSpendingOnce('staging', OWNER, draft(), receiver, journal), /lost ack/);
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 1);
  const saved = JSON.stringify([...journal.entries]);
  for (const value of ['private-vendor', 'tavily_subscription', 'invoice', '30000000', 'Bearer']) assert.ok(!saved.includes(value));
  // A fresh helper call models a remount/reload; property order doesn't create another intent.
  const entry = draft(); const reordered = { evidence_reference: entry.evidence_reference, complete: entry.complete,
    amount_microusd: entry.amount_microusd, measure: entry.measure, period: entry.period, component: entry.component };
  const result = await recordSpendingOnce('staging', OWNER, reordered, receiver, journal);
  assert.deepEqual(requests[0], requests[1]); assert.equal(result.replayed, true); assert.equal(records.size, 1);
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 0);
});

test('concurrent identical intents use one ID; acknowledging one intent never erases another pending intent', async () => {
  const journal = storage(), ids = new Map<string, string>(), sent = new Map<string, () => void>();
  const send = (caller: string) => (request: SpendingObservationRequest) => new Promise<SpendingObservationReceipt>(resolve => {
    ids.set(caller, request.request_id); sent.set(caller, () => resolve({ id: request.request_id,
      replayed: [...ids.values()].filter(id => id === request.request_id).length > 1 }));
  });
  const first = recordSpendingOnce('staging', OWNER, draft(), send('first'), journal);
  const second = recordSpendingOnce('staging', OWNER, draft(), send('second'), journal);
  const distinct = recordSpendingOnce('staging', OWNER, { ...draft(), amount_microusd: 40_000_000 }, send('distinct'), journal);
  while (sent.size < 3) await new Promise(resolve => setImmediate(resolve));
  // SHA-256 runs asynchronously; the distinct draft may finish hashing before either identical draft.
  assert.equal(ids.get('first'), ids.get('second')); assert.notEqual(ids.get('first'), ids.get('distinct'));
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 2);
  sent.get('first')!(); await first;
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 1);
  sent.get('second')!(); await second;
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 1);
  sent.get('distinct')!(); await distinct;
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 0);
});

test('owner/environment scopes separate retries and an acknowledged intentional later entry gets a new ID', async () => {
  const journal = storage(), requests: SpendingObservationRequest[] = [];
  const unknown = async (request: SpendingObservationRequest): Promise<SpendingObservationReceipt> => { requests.push(request); throw new Error('unknown'); };
  await assert.rejects(recordSpendingOnce('staging', OWNER, draft(), unknown, journal));
  await assert.rejects(recordSpendingOnce('staging', OTHER, draft(), unknown, journal));
  await assert.rejects(recordSpendingOnce('production', OWNER, draft(), unknown, journal));
  assert.equal(new Set(requests.map(row => row.request_id)).size, 3);
  const success = async (request: SpendingObservationRequest) => ({ id: request.request_id, replayed: false });
  const replay = await recordSpendingOnce('staging', OWNER, draft(), success, journal);
  const next = await recordSpendingOnce('staging', OWNER, draft(), success, journal);
  assert.equal(replay.id, requests[0].request_id); assert.notEqual(replay.id, next.id);
});

test('a peer acknowledgement cannot change the frozen retry identity after the original send loses its response', async () => {
  const journal = storage(); let frozen: SpendingObservationRequest | undefined, lose!: () => void;
  const first = recordSpendingOnce('staging', OWNER, draft(), request => {
    frozen = request; return new Promise((_resolve, reject) => { lose = () => reject(new Error('lost ack')); });
  }, journal);
  while (!frozen) await new Promise(resolve => setImmediate(resolve));
  const peer = await recordSpendingOnce('staging', OWNER, draft(), async request => {
    assert.deepEqual(request, frozen); return { id: request.request_id, replayed: true };
  }, journal);
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 0);
  lose(); await assert.rejects(first, /lost ack/);
  const requests: SpendingObservationRequest[] = [];
  const retry = await retrySpendingObservation('staging', OWNER, frozen, async request => {
    requests.push(request); return { id: request.request_id, replayed: true };
  }, journal);
  assert.equal(retry.id, peer.id); assert.deepEqual(requests, [frozen]);
});

test('fast concurrent first sends receive one identity, and an old retry cannot clear a later pending same-field entry', async () => {
  const journal = storage(), requests: SpendingObservationRequest[] = [];
  const success = async (request: SpendingObservationRequest) => { requests.push(request); return { id: request.request_id, replayed: false }; };
  const [a, b] = await Promise.all([recordSpendingOnce('staging', OWNER, draft(), success, journal), recordSpendingOnce('staging', OWNER, draft(), success, journal)]);
  assert.equal(a.id, b.id);
  let later: SpendingObservationRequest | undefined;
  await assert.rejects(recordSpendingOnce('staging', OWNER, draft(), async request => { later = request; throw new Error('unknown'); }, journal));
  assert.notEqual(later?.request_id, a.id);
  await retrySpendingObservation('staging', OWNER, requests[0], success, journal);
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 1);
  const preserved = await recordSpendingOnce('staging', OWNER, draft(), success, journal);
  assert.equal(preserved.id, later?.request_id);
});

test('unavailable/corrupt/full journal fails before sending; malformed acknowledgement retains retry identity', async () => {
  let calls = 0; const send = async (request: SpendingObservationRequest) => { calls++; return { id: request.request_id, replayed: false }; };
  const broken = storage(); broken.setItem = () => { throw new Error('quota'); };
  await assert.rejects(recordSpendingOnce('staging', OWNER, draft(), send, broken), /retry record/); assert.equal(calls, 0);
  const malformed = storage(); malformed.entries.set(`science-reader.admin.spending-retry.staging.${OWNER}`, '{bad');
  await assert.rejects(recordSpendingOnce('staging', OWNER, draft(), send, malformed), /retry record/); assert.equal(calls, 0);
  const full = storage();
  for (let n = 0; n < 32; n++) await assert.rejects(recordSpendingOnce('staging', OWNER, { ...draft(), amount_microusd: n }, async () => { throw new Error('unknown'); }, full));
  assert.equal(pendingSpendingEntries('staging', OWNER, full), 32);
  await assert.rejects(recordSpendingOnce('staging', OWNER, draft(), send, full), /32 unconfirmed/); assert.equal(calls, 0);
  const journal = storage();
  await assert.rejects(recordSpendingOnce('staging', OWNER, draft(), async () => ({ id: OTHER, replayed: false }), journal), /not confirmed/);
  assert.equal(pendingSpendingEntries('staging', OWNER, journal), 1);
});

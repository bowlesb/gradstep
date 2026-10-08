import assert from 'node:assert/strict';
import test from 'node:test';
import { adminSpending, type AdminSpendingDeps } from '../../supabase/functions/_shared/admin-spending.ts';
import { parseSpendingObservation, dollarsToMicrousd, SpendingInputError } from '../../supabase/functions/_shared/spending-observations.ts';
import { PublicError } from '../../supabase/functions/_shared/http.ts';

const OWNER = '37000000-0000-0000-0000-00000000000a', OTHER = '37000000-0000-0000-0000-00000000000b';
const ID = '37000000-0000-0000-0000-0000000000ab', TOKEN = 'not-a-real-token';
const draft = () => ({ request_id: ID, observed_at: new Date().toISOString(), component: 'tavily_subscription',
  period: new Date().toISOString().slice(0, 7) + '-01', measure: 'invoice', amount_microusd: 30_000_000,
  complete: false, evidence_reference: 'owner-provided:tavily-paid-2026-10-06' });
type Options = { auth?: boolean; owner?: boolean; actor?: string; rateError?: string; recordError?: string; result?: unknown; throwsLog?: boolean };
function harness(options: Options = {}) {
  const calls: Array<{ name: string; params?: Record<string, unknown> }> = [], logs: Record<string, unknown>[] = [];
  const records = new Map<string, string>(); let services = 0;
  const deps: AdminSpendingDeps = {
    authenticate: async request => {
      if (options.auth === false || request.headers.get('authorization') !== `Bearer ${TOKEN}`) throw new PublicError(401, 'authentication_required');
      return { accountID: OWNER, user: { rpc: async (name, params) => { calls.push({ name, params });
        return { data: options.actor ?? OWNER, error: options.owner === false ? { message: 'owner_mfa_required' } : null }; } } };
    },
    service: () => { services++; return { rpc: async (name, params = {}) => {
      calls.push({ name, params });
      if (name === 'worker_consume_request') return { data: null, error: options.rateError ? { message: options.rateError } : null };
      assert.equal(name, 'worker_record_spending_observation', 'no other privileged action is available');
      if (options.recordError) return { data: null, error: { message: options.recordError } };
      const id = params.p_id as string, prior = records.get(id), text = JSON.stringify(params);
      if (prior && prior !== text) return { data: null, error: { message: 'spending_observation_id_conflict' } };
      records.set(id, text);
      return { data: Object.hasOwn(options, 'result') ? options.result : { id, replayed: !!prior }, error: null };
    } }; },
    log: entry => { logs.push(entry); if (options.throwsLog) throw new Error('private logger details'); },
  };
  return { deps, calls, logs, records, services: () => services };
}
function request(body: unknown = draft(), extra: Record<string, string> = {}, method = 'POST') {
  return new Request('https://fixed.supabase.co/functions/v1/admin-spending', { method,
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', ...extra },
    ...(method === 'GET' ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }) });
}
async function send(h: ReturnType<typeof harness>, body: unknown = draft(), extra: Record<string, string> = {}) {
  const response = await adminSpending(request(body, extra), h.deps);
  return { status: response.status, body: await response.json(), headers: response.headers };
}

test('spending append requires the caller-token MFA owner before parsing or constructing service access', async () => {
  for (const options of [{ auth: false }, { owner: false }, { actor: OTHER }]) {
    const h = harness(options), result = await send(h, 'not even JSON');
    assert.equal(result.status, options.auth === false ? 401 : 403);
    assert.equal(h.services(), 0); assert.equal(h.records.size, 0);
    assert.deepEqual(h.calls.map(c => c.name), options.auth === false ? [] : ['v1_admin_actor']);
  }
  const h = harness(); const response = await adminSpending(request(null, {}, 'GET'), h.deps);
  assert.equal(response.status, 405); assert.equal(h.calls.length, 0);
  const allowed = harness(); await send(allowed);
  assert.deepEqual(allowed.calls.map(c => c.name), ['v1_admin_actor', 'worker_consume_request', 'worker_record_spending_observation']);
  assert.deepEqual(allowed.calls[1].params, { p_account_id: OWNER, p_route: 'admin-spending' });
  assert.equal(allowed.calls[2].params?.p_actor_id, OWNER);
});

test('strict contract rejects actor/source/unit/budget injection and overlong or ambiguous financial values', async () => {
  const invalid = [
    { actor_id: OTHER }, { p_actor_id: OTHER }, { source: 'invoice-verified' }, { units: { x: 1 } }, { budget: 99999 },
    { component: '__proto__' }, { component: 'constructor' }, { measure: 'refund' },
    { amount_microusd: 1.5 }, { amount_microusd: -1 }, { amount_microusd: 10_000_000_001 }, { amount_microusd: '30' },
    { complete: 'true' }, { complete: true, amount_microusd: null }, { period: '2026-09-01' }, { period: '2026-13-01' }, { period: '2026-10-02' },
    { period: '2099-10-01' }, { period: '2026-10-01\n' }, { request_id: ID + '\n' }, { request_id: ID.toUpperCase() },
    { observed_at: new Date(Date.now() + 600_000).toISOString() }, { observed_at: '2026-02-31T00:00:00.000Z' },
    { evidence_reference: 'x'.repeat(257) }, { evidence_reference: 'reference\nprivate' }, { evidence_reference: '<script>' },
    { evidence_reference: 'https://invoice.test/path?token=secret' }, { evidence_reference: 'ok' },
  ];
  for (const fields of invalid) { const h = harness(), result = await send(h, { ...draft(), ...fields });
    assert.equal(result.status, 400, JSON.stringify(fields)); assert.equal(h.services(), 0); }
  for (const [body, headers, status] of [['{}', { 'content-type': 'application/jsonx' }, 415], ['x'.repeat(4097), {}, 413],
    ['{}', { 'content-length': '4097' }, 413]] as const) {
    const h = harness(); assert.equal((await send(h, body, headers)).status, status); assert.equal(h.services(), 0);
  }
});

test('invoice appends only evidence, exact retry replays and changed retry conflicts', async () => {
  const h = harness(), entry = draft();
  const first = await send(h, entry); assert.deepEqual(first.body, { id: ID, replayed: false });
  assert.equal(first.headers.get('cache-control'), 'no-store'); assert.equal(first.headers.get('x-content-type-options'), 'nosniff');
  assert.deepEqual(h.calls.at(-1)?.params, { p_actor_id: OWNER, p_id: ID, p_component: 'tavily_subscription', p_period: entry.period,
    p_measure: 'invoice', p_amount_microusd: 30_000_000, p_complete: false, p_observed_at: entry.observed_at,
    p_source: 'owner-entry', p_evidence_reference: entry.evidence_reference, p_units: {} });
  assert.deepEqual((await send(h, entry)).body, { id: ID, replayed: true });
  assert.deepEqual((await send(h, { ...entry, amount_microusd: 31_000_000 })).body, { code: 'observation_id_conflict' });
  assert.equal(h.records.size, 1);
  assert.equal(h.calls.filter(c => c.name === 'v1_admin_actor').length, 3, 'every replay repeats real MFA authorization');
});

test('rate, revoked owner and database failure stop safely, never expose private SQL or false receipts', async () => {
  const rate = harness({ rateError: 'request_rate_limit' }); assert.equal((await send(rate)).status, 429); assert.equal(rate.records.size, 0);
  assert.deepEqual(rate.calls.map(c => c.name), ['v1_admin_actor', 'worker_consume_request']);
  for (const [recordError, code, status] of [['owner_required', 'owner_mfa_required', 403], ['spending_observation_capacity', 'observation_capacity', 409],
    ['SQL includes private owner invoice account token', 'service_unavailable', 503]] as const) {
    const result = await send(harness({ recordError })); assert.deepEqual([result.status, result.body], [status, { code }]);
  }
  for (const result of [null, {}, { id: OTHER, replayed: false }, { id: ID, replayed: 'false' }, { id: ID, replayed: false, secret: 'private' }])
    assert.deepEqual((await send(harness({ result }))).body, { code: 'service_unavailable' });
  const h = harness({ throwsLog: true }); assert.equal((await send(h)).status, 200);
  assert.deepEqual(Object.keys(h.logs[0]).sort(), ['function', 'ms', 'outcome', 'status']);
  for (const privateValue of [OWNER, ID, TOKEN, '30_000_000', draft().evidence_reference]) assert.ok(!JSON.stringify(h.logs).includes(privateValue));
});

test('USD conversion preserves microusd exactly and unknown is distinct from verified zero', () => {
  assert.equal(dollarsToMicrousd('30'), 30_000_000); assert.equal(dollarsToMicrousd('0.100001'), 100_001);
  assert.equal(dollarsToMicrousd('0'), 0); assert.equal(dollarsToMicrousd(''), null); assert.equal(dollarsToMicrousd('10000.000000'), 10_000_000_000);
  for (const value of ['1e2', 'Infinity', 'NaN', '-0', '01', '1,000', '0.0000001', '10000.000001', '30\n'])
    assert.throws(() => dollarsToMicrousd(value), SpendingInputError);
  assert.equal(parseSpendingObservation({ ...draft(), complete: false, amount_microusd: null }).amount_microusd, null);
  assert.equal(parseSpendingObservation({ ...draft(), measure: 'metric', complete: true, amount_microusd: null }).complete, true);
});

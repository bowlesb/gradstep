// Review A21 (migration 127): admin-accounts' revoke_admission action withdraws an address's invitation through the
// owner-checked, audited SQL function; strict input; the response never echoes the reason; refusals map to codes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { adminAccounts, parseAdminAction, type AdminDeps } from '../../supabase/functions/_shared/admin-accounts.ts';
import { PublicError } from '../../supabase/functions/_shared/http.ts';

const OWNER = '12700000-0000-4000-8000-00000000000f';
const TOKEN = 'header.payload.signature';

function harness(result: unknown, error: string | null = null) {
  const calls: { name: string; params: Record<string, unknown> }[] = [], logs: Record<string, unknown>[] = [];
  const service = {
    rpc: async (name: string, params: Record<string, unknown> = {}) => {
      calls.push({ name, params });
      if (name === 'worker_consume_request') return { data: null, error: null };
      if (name === 'worker_admin_revoke_email') return error ? { data: null, error: { message: error } } : { data: result, error: null };
      return { data: null, error: { message: 'unexpected' } };
    },
    auth: { admin: {
      createUser: async () => { throw new Error('no login is created'); },
      updateUserById: async () => { throw new Error('no ban is changed'); },
    } },
  };
  const deps: AdminDeps = {
    authenticate: async request => {
      if (request.headers.get('authorization') !== `Bearer ${TOKEN}`) throw new PublicError(401, 'authentication_required');
      return { user: { rpc: async () => ({ data: OWNER, error: null }) }, accountID: OWNER };
    },
    service: () => service,
    log: entry => logs.push(entry),
  };
  return { deps, calls, logs };
}
const post = (body: unknown) => new Request('https://project.supabase.co/functions/v1/admin-accounts', {
  method: 'POST', headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });

test('revoke_admission parses strictly: exact keys, a valid address and a reason', () => {
  assert.deepEqual(parseAdminAction(JSON.stringify({ action: 'revoke_admission', email: ' Tester@Example.ORG ', reason: 'Left the beta' })),
    { action: 'revoke_admission', email: 'tester@example.org', reason: 'Left the beta' });
  for (const bad of [{ action: 'revoke_admission', email: 'tester@example.org' }, { action: 'revoke_admission', email: 'nope', reason: 'Left the beta' },
    { action: 'revoke_admission', email: 'tester@example.org', reason: 'x' }, { action: 'revoke_admission', email: 'tester@example.org', reason: 'Left', extra: 1 }]) {
    assert.throws(() => parseAdminAction(JSON.stringify(bad)), (error: unknown) => error instanceof PublicError && error.status === 400);
  }
});

test('revoke_admission withdraws through the owner-checked function and reports an existing login; no Auth change', async () => {
  const h = harness({ revoked: true, previously: 'allowed', existing_login: true });
  const response = await adminAccounts(post({ action: 'revoke_admission', email: 'tester@example.org', reason: 'Left the beta' }), h.deps);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { email: 'tester@example.org', revoked: true, previously: 'allowed', existing_login: true });
  assert.deepEqual(h.calls.map(c => c.name), ['worker_consume_request', 'worker_admin_revoke_email']);
  assert.deepEqual(h.calls[1].params, { p_actor_id: OWNER, p_email: 'tester@example.org', p_reason: 'Left the beta' });
  assert.ok(!JSON.stringify(h.logs).includes('tester@example.org') && !JSON.stringify(h.logs).includes('Left the beta'), 'logs carry no address or reason');
});

test('revoke_admission refusals map to the admin codes; an unconfirmed result is not reported as done', async () => {
  const owner = await adminAccounts(post({ action: 'revoke_admission', email: 'owner@example.org', reason: 'Lock out' }), harness(null, 'owner_cannot_be_disabled').deps);
  assert.equal(owner.status, 409);
  assert.deepEqual(await owner.json(), { code: 'owner_cannot_be_disabled' });
  const unknown = await adminAccounts(post({ action: 'revoke_admission', email: 'tester@example.org', reason: 'Left the beta' }), harness({ revoked: false }).deps);
  assert.equal(unknown.status, 503);
});

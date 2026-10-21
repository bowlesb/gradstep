import test from 'node:test';
import assert from 'node:assert/strict';
import { adminAccounts, BAN_DURATION, normalizeEmail, parseAdminAction, readBody, type AdminDeps } from '../../supabase/functions/_shared/admin-accounts.ts';
import { PublicError } from '../../supabase/functions/_shared/http.ts';

const OWNER = '31000000-0000-0000-0000-00000000000a';
const TESTER = '31000000-0000-0000-0000-00000000000b';
const REQUEST = '31000000-0000-0000-0000-0000000000a1';
const TOKEN = 'header.payload.signature';

type Call = { who: 'user' | 'service' | 'auth'; name: string; params?: Record<string, unknown> };
type Options = {
  owner?: boolean; actor?: string; logins?: Record<string, { account_id: string; closed: boolean }>;
  rpcErrors?: Record<string, string>; createError?: { code?: string; status?: number; message?: string }; createdID?: string;
  banError?: boolean; loginAfterCreate?: boolean;
};

function harness(options: Options = {}) {
  const calls: Call[] = [], logs: Record<string, unknown>[] = [];
  const logins = new Map(Object.entries(options.logins ?? {}));
  let serviceCreated = 0;
  const user = { rpc: async (name: string, params?: Record<string, unknown>) => {
    calls.push({ who: 'user', name, params });
    if (name !== 'v1_admin_actor') return { data: null, error: { message: 'unexpected' } };
    return options.owner === false ? { data: null, error: { message: 'owner_mfa_required' } } : { data: options.actor ?? OWNER, error: null };
  } };
  const service = {
    rpc: async (name: string, params: Record<string, unknown> = {}) => {
      calls.push({ who: 'service', name, params });
      if (options.rpcErrors?.[name]) return { data: null, error: { message: options.rpcErrors[name] } };
      switch (name) {
        case 'worker_consume_request': return { data: null, error: null };
        case 'worker_admin_find_login': return { data: logins.get(params.p_email as string) ?? null, error: null };
        case 'worker_admin_admit_email': return { data: null, error: null };
        case 'worker_admin_add_tester': return { data: { account_id: params.p_account_id, status: 'active', starting_credits: params.p_credits, starting_granted: (params.p_credits as number) > 0 }, error: null };
        case 'worker_admin_grant_credits': return { data: { bucket_id: 'b1', credits: params.p_credits, replayed: false }, error: null };
        case 'worker_admin_set_sign_in': return { data: { auth_user_id: params.p_account_id, disabled: params.p_disabled, replayed: false }, error: null };
        default: return { data: null, error: { message: 'unexpected' } };
      }
    },
    auth: { admin: {
      createUser: async (attributes: { email: string; email_confirm: boolean }) => {
        calls.push({ who: 'auth', name: 'createUser', params: attributes });
        if (options.loginAfterCreate !== false) logins.set(attributes.email, { account_id: options.createdID ?? TESTER, closed: false });
        if (options.createError) return { data: { user: null }, error: options.createError };
        return { data: { user: { id: options.createdID ?? TESTER } }, error: null };
      },
      updateUserById: async (id: string, attributes: { ban_duration: string }) => {
        calls.push({ who: 'auth', name: 'updateUserById', params: { id, ...attributes } });
        return { error: options.banError ? { message: 'down', status: 500 } : null };
      },
    } },
  };
  const deps: AdminDeps = {
    authenticate: async request => {
      if (request.headers.get('authorization') !== `Bearer ${TOKEN}`) throw new PublicError(401, 'authentication_required');
      return { user, accountID: OWNER };
    },
    service: () => { serviceCreated++; return service; },
    log: entry => logs.push(entry),
  };
  return { deps, calls, logs, serviceUses: () => serviceCreated };
}

function post(body: unknown, init: { method?: string; headers?: Record<string, string>; raw?: string } = {}) {
  return new Request('https://project.supabase.co/functions/v1/admin-accounts', {
    method: init.method ?? 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', ...init.headers },
    body: init.method === 'GET' ? undefined : init.raw ?? JSON.stringify(body),
  });
}
async function send(h: ReturnType<typeof harness>, body: unknown, init?: Parameters<typeof post>[1]) {
  const response = await adminAccounts(post(body, init), h.deps, { 'Access-Control-Allow-Origin': 'https://admin.example' });
  return { status: response.status, json: await response.json() as Record<string, unknown>, headers: response.headers };
}
const grant = (extra: Record<string, unknown> = {}) => ({ action: 'grant_credits', request_id: REQUEST, account_id: TESTER, credits: 300, reason: 'Beta top-up', ...extra });
const signIn = (extra: Record<string, unknown> = {}) => ({ action: 'set_sign_in', request_id: REQUEST, account_id: TESTER, disabled: true, reason: 'Left the beta', ...extra });

test('admission failure stops before creating or funding a login', async () => {
  const h = harness({ rpcErrors: { worker_admin_admit_email: 'account_disabled' } });
  const r = await send(h, { action: 'add_tester', email: 'blocked@example.org', credits: 100 });
  assert.equal(r.status, 409); assert.equal(r.json.code, 'account_disabled');
  assert.equal(h.calls.some(c => c.name === 'createUser' || c.name === 'worker_admin_add_tester'), false);
});

test('emails: trimmed, lowercased ASCII addresses only', () => {
  assert.equal(normalizeEmail('  Alice.Chen+beta@Example.ORG '), 'alice.chen+beta@example.org');
  assert.equal(normalizeEmail('gradstep-check-x@example.invalid'), 'gradstep-check-x@example.invalid');
  for (const bad of ['', 'alice', 'alice@', '@example.org', 'alice@example', 'alice@@example.org', 'a b@example.org', 'alice@exa mple.org',
    '.alice@example.org', 'alice.@example.org', 'al..ice@example.org', 'alice@example..org', 'alice@-example.org', 'alice@example.org.',
    'alice@[127.0.0.1]', 'alïce@example.org', 'alice@exämple.org', 'alice@exam\nple.org', `${'a'.repeat(65)}@example.org`,
    `a@${'b'.repeat(250)}.org`, 'alice@example.c', 'alice@example.1']) {
    assert.throws(() => normalizeEmail(bad), (e: PublicError) => e.code === 'invalid_email', JSON.stringify(bad));
  }
  assert.throws(() => normalizeEmail(42), (e: PublicError) => e.code === 'invalid_email');
});

test('requests: exact keys per action, bounded credits and reasons', () => {
  assert.deepEqual(parseAdminAction(JSON.stringify({ action: 'add_tester', email: 'New@Example.org', credits: 0 })),
    { action: 'add_tester', email: 'new@example.org', credits: 0 });
  assert.deepEqual(parseAdminAction(JSON.stringify(grant({ request_id: REQUEST.toUpperCase(), reason: '  Beta top-up  ' }))),
    { action: 'grant_credits', request_id: REQUEST, account_id: TESTER, credits: 300, reason: 'Beta top-up' });
  assert.deepEqual(parseAdminAction(JSON.stringify(signIn({ disabled: false }))),
    { action: 'set_sign_in', request_id: REQUEST, account_id: TESTER, disabled: false, reason: 'Left the beta' });
  assert.equal((parseAdminAction(JSON.stringify(grant({ credits: 2000 }))) as { credits: number }).credits, 2000, 'the cap itself is allowed');
  const rejects: [unknown, string][] = [
    ['not json', 'invalid_request'], [[], 'invalid_request'], [null, 'invalid_request'], [{ action: 'delete_account', account_id: TESTER }, 'invalid_request'],
    [{ action: 'add_tester', email: 'a@example.org' }, 'invalid_request'], [{ action: 'add_tester', email: 'a@example.org', credits: 1, password: 'x' }, 'invalid_request'],
    [{ action: 'add_tester', email: 'a@example.org', credits: 2001 }, 'invalid_credits'], [{ action: 'add_tester', email: 'a@example.org', credits: -1 }, 'invalid_credits'],
    [grant({ credits: 0 }), 'invalid_credits'], [grant({ credits: 2001 }), 'invalid_credits'], [grant({ credits: 1.5 }), 'invalid_credits'],
    [grant({ credits: '300' }), 'invalid_credits'], [grant({ credits: 1e21 }), 'invalid_credits'],
    [grant({ reason: 'ab' }), 'invalid_reason'], [grant({ reason: '   ok   ' }), 'invalid_reason'], [grant({ reason: 'x'.repeat(501) }), 'invalid_reason'],
    [grant({ reason: 'two\nlines' }), 'invalid_reason'], [grant({ reason: 'tab\there' }), 'invalid_reason'], [grant({ reason: 42 }), 'invalid_reason'],
    [grant({ request_id: 'not-a-uuid' }), 'invalid_request_id'], [grant({ account_id: `${TESTER}x` }), 'invalid_account'],
    [grant({ extra: true }), 'invalid_request'], [signIn({ disabled: 'true' }), 'invalid_request'], [signIn({ disabled: undefined }), 'invalid_request'],
  ];
  for (const [body, code] of rejects) {
    assert.throws(() => parseAdminAction(typeof body === 'string' ? body : JSON.stringify(body)), (e: PublicError) => e.status === 400 && e.code === code, JSON.stringify(body));
  }
  assert.equal((parseAdminAction(JSON.stringify(grant({ reason: 'x'.repeat(500) }))) as { reason: string }).reason.length, 500);
});

test('bodies: JSON only, at most 4 KiB, valid UTF-8', async () => {
  const request = (body: BodyInit, headers: Record<string, string>) => new Request('https://x/', { method: 'POST', body, headers, duplex: 'half' } as RequestInit);
  assert.equal(await readBody(request('{"a":1}', { 'content-type': 'application/json; charset=utf-8' })), '{"a":1}');
  await assert.rejects(readBody(request('{}', { 'content-type': 'text/plain' })), (e: PublicError) => e.status === 415);
  await assert.rejects(readBody(request('{}', { 'content-type': 'application/json', 'content-length': '5000' })), (e: PublicError) => e.status === 413);
  const stream = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(3000)); c.enqueue(new Uint8Array(3000)); c.close(); } });
  await assert.rejects(readBody(request(stream, { 'content-type': 'application/json' })), (e: PublicError) => e.status === 413, 'an undeclared oversize body');
  await assert.rejects(readBody(request(new Uint8Array([0x7b, 0xff, 0x7d]), { 'content-type': 'application/json' })), (e: PublicError) => e.code === 'invalid_request');
});

test('only an owner with MFA gets past the gate; nothing else runs first', async () => {
  const customer = harness({ owner: false });
  const refused = await send(customer, grant());
  assert.deepEqual([refused.status, refused.json], [403, { code: 'owner_mfa_required' }]);
  assert.equal(customer.serviceUses(), 0, 'the service role is never used for a non-owner');
  assert.deepEqual(customer.calls.map(c => c.name), ['v1_admin_actor']);
  assert.equal((await send(harness({ owner: false }), 'not json', { raw: 'not json' })).status, 403, 'the gate runs before the body is parsed');

  const mismatch = harness({ actor: TESTER });
  assert.equal((await send(mismatch, grant())).status, 403, 'the gate must name the caller’s own account');
  assert.equal(mismatch.serviceUses(), 0);

  const anonymous = harness();
  const response = await adminAccounts(post(grant(), { headers: { authorization: 'Bearer forged' } }), anonymous.deps);
  assert.equal(response.status, 401);
  assert.equal(anonymous.calls.length, 0);

  const wrongMethod = await adminAccounts(post(null, { method: 'GET' }), harness().deps);
  assert.equal(wrongMethod.status, 405);
  const gateDown = harness();
  gateDown.deps.authenticate = async () => ({ user: { rpc: async () => ({ data: null, error: { message: 'connection reset' } }) }, accountID: OWNER });
  assert.deepEqual((await send(gateDown, grant())).json, { code: 'service_unavailable' });
});

test('rate limited per owner before any change', async () => {
  const h = harness({ rpcErrors: { worker_consume_request: 'request_rate_limit' } });
  const result = await send(h, { action: 'add_tester', email: 'new@example.org', credits: 1000 });
  assert.deepEqual([result.status, result.json], [429, { code: 'rate_limited' }]);
  assert.deepEqual(h.calls.filter(c => c.who !== 'user').map(c => c.name), ['worker_consume_request']);
  assert.deepEqual(h.calls[1].params, { p_account_id: OWNER, p_route: 'admin-accounts' });
});

test('add tester: a confirmed login without a password, then the audited starting grant', async () => {
  const h = harness();
  const result = await send(h, { action: 'add_tester', email: ' New.Tester@Example.org ', credits: 1000 });
  assert.equal(result.status, 200);
  assert.deepEqual(result.json, { account_id: TESTER, email: 'new.tester@example.org', created: true, status: 'active', starting_credits: 1000, starting_granted: true });
  assert.equal(result.headers.get('access-control-allow-origin'), 'https://admin.example');
  const create = h.calls.find(c => c.name === 'createUser')!;
  assert.deepEqual(create.params, { email: 'new.tester@example.org', email_confirm: true }, 'no password, no invitation email');
  assert.deepEqual(h.calls.filter(c => c.who !== 'user').map(c => c.name),
    ['worker_consume_request', 'worker_admin_find_login', 'worker_admin_admit_email', 'createUser', 'worker_admin_find_login', 'worker_admin_add_tester']);
  assert.deepEqual(h.calls.at(-1)!.params, { p_actor_id: OWNER, p_account_id: TESTER, p_created: true, p_credits: 1000 });
});

test('add tester is idempotent for an existing email and refuses a closing account', async () => {
  const existing = harness({ logins: { 'reader@example.org': { account_id: TESTER, closed: false } } });
  const result = await send(existing, { action: 'add_tester', email: 'Reader@example.org', credits: 500 });
  assert.equal(result.json.created, false);
  assert.ok(!existing.calls.some(c => c.name === 'createUser'), 'no second login');
  assert.equal(existing.calls.at(-1)!.params!.p_created, false);

  const closing = harness({ logins: { 'closing@example.org': { account_id: TESTER, closed: true } } });
  assert.deepEqual((await send(closing, { action: 'add_tester', email: 'closing@example.org', credits: 0 })).json, { code: 'account_closed' });
  assert.ok(!closing.calls.some(c => c.name === 'worker_admin_add_tester' || c.name === 'createUser'));

  // Added by someone else at the same moment: Auth reports the email exists; the existing account is used.
  const race = harness({ createError: { code: 'email_exists', status: 422 } });
  const raced = await send(race, { action: 'add_tester', email: 'race@example.org', credits: 0 });
  assert.deepEqual([raced.status, raced.json.created], [200, false]);

  const invalid = harness({ createError: { code: 'email_address_invalid', status: 400 }, loginAfterCreate: false });
  assert.deepEqual((await send(invalid, { action: 'add_tester', email: 'odd@example.org', credits: 0 })).json, { code: 'invalid_email' });
  const down = harness({ createError: { status: 500, message: 'Database error creating new user' }, loginAfterCreate: false });
  assert.deepEqual((await send(down, { action: 'add_tester', email: 'odd@example.org', credits: 0 })).json, { code: 'service_unavailable' });
  const noRow = harness({ loginAfterCreate: false });
  assert.deepEqual((await send(noRow, { action: 'add_tester', email: 'odd@example.org', credits: 0 })).json, { code: 'service_unavailable' },
    'a login without its account row is not reported as added');
});

test('grant credits goes through the audited service function with the verified owner', async () => {
  const h = harness();
  const result = await send(h, grant({ credits: 2000, reason: ' Heavy chat tester ' }));
  assert.deepEqual([result.status, result.json], [200, { account_id: TESTER, credits: 2000, replayed: false }]);
  assert.deepEqual(h.calls.at(-1), { who: 'service', name: 'worker_admin_grant_credits',
    params: { p_actor_id: OWNER, p_request_id: REQUEST, p_account_id: TESTER, p_credits: 2000, p_reason: 'Heavy chat tester' } });
  const over = harness();
  assert.deepEqual((await send(over, grant({ credits: 2001 }))).json, { code: 'invalid_credits' });
  assert.equal(over.serviceUses(), 0, 'an over-cap grant never reaches the database');
  for (const [message, status, code] of [['request_id_conflict', 409, 'request_id_conflict'], ['account_closed', 409, 'account_closed'],
    ['owner_required', 403, 'owner_mfa_required'], ['account_unavailable', 404, 'account_unavailable'], ['invalid_grant', 400, 'invalid_credits'],
    ['deadlock detected', 503, 'service_unavailable']] as const) {
    const failing = harness({ rpcErrors: { worker_admin_grant_credits: message } });
    assert.deepEqual(await send(failing, grant()).then(r => [r.status, r.json]), [status, { code }], message);
  }
});

test('disable and enable: audit first, then the Auth ban; owners and failures', async () => {
  const h = harness();
  const disabled = await send(h, signIn());
  assert.deepEqual([disabled.status, disabled.json], [200, { account_id: TESTER, disabled: true, replayed: false }]);
  assert.deepEqual(h.calls.filter(c => c.who !== 'user').map(c => c.name), ['worker_consume_request', 'worker_admin_set_sign_in', 'updateUserById']);
  assert.deepEqual(h.calls.at(-1)!.params, { id: TESTER, ban_duration: BAN_DURATION });

  const enable = harness();
  await send(enable, signIn({ disabled: false, reason: 'Back for round two' }));
  assert.deepEqual(enable.calls.at(-1)!.params, { id: TESTER, ban_duration: 'none' });

  const owner = harness({ rpcErrors: { worker_admin_set_sign_in: 'owner_cannot_be_disabled' } });
  assert.deepEqual((await send(owner, signIn({ account_id: OWNER }))).json, { code: 'owner_cannot_be_disabled' });
  assert.ok(!owner.calls.some(c => c.name === 'updateUserById'), 'refused before Auth is touched');

  const authDown = harness({ banError: true });
  const failed = await send(authDown, signIn());
  assert.deepEqual([failed.status, failed.json], [503, { code: 'sign_in_change_unconfirmed' }]);
});

test('A14: a replayed sign-in request applies the database\'s current state to Auth, never its old intent', async () => {
  // disable "spam" (answer lost) -> later enable -> disable "spam" again reuses the old request ID: the database replays
  // and reports the account enabled now.
  const h = harness();
  const service = h.deps.service();
  const original = service.rpc.bind(service);
  service.rpc = async (name: string, params: Record<string, unknown> = {}) => name === 'worker_admin_set_sign_in'
    ? (h.calls.push({ who: 'service', name, params }), { data: { auth_user_id: TESTER, disabled: false, replayed: true }, error: null })
    : original(name, params);
  h.deps.service = () => service;
  const replay = await send(h, signIn({ disabled: true }));
  assert.deepEqual([replay.status, replay.json], [409, { code: 'request_superseded' }]);
  assert.deepEqual(h.calls.find(c => c.name === 'updateUserById')!.params, { id: TESTER, ban_duration: 'none' }, 'Auth follows the database: not banned');
  // A replay that matches the current state is acknowledged as before.
  const same = harness();
  const sameService = same.deps.service(), sameOriginal = sameService.rpc.bind(sameService);
  sameService.rpc = async (name: string, params: Record<string, unknown> = {}) => name === 'worker_admin_set_sign_in'
    ? { data: { auth_user_id: TESTER, disabled: true, replayed: true }, error: null } : sameOriginal(name, params);
  same.deps.service = () => sameService;
  assert.deepEqual((await send(same, signIn())).json, { account_id: TESTER, disabled: true, replayed: true });
});

import { FinalRequestError, once } from '../../apps/admin/src/retry-key.ts';
test('A14: the admin retry key survives a lost answer but is cleared by any final answer', async () => {
  const store = new Map<string, string>();
  const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); }, removeItem: (k: string) => { store.delete(k); } };
  const ids: string[] = [];
  const params = { account_id: TESTER, disabled: true, reason: 'spam' };
  await assert.rejects(once(OWNER, 'admin-sign-in', params, async id => { ids.push(id); throw new Error('lost'); }, storage));
  await assert.rejects(once(OWNER, 'admin-sign-in', params, async id => { ids.push(id); throw new FinalRequestError('superseded'); }, storage));
  assert.equal(ids[0], ids[1], 'an unknown outcome is retried with the same request ID');
  await once(OWNER, 'admin-sign-in', params, async id => { ids.push(id); return 'ok'; }, storage);
  assert.notEqual(ids[2], ids[1], 'after a final refusal the same change is a new request');
  assert.equal(store.size, 0, 'nothing pending after an acknowledged answer');
});

test('logs carry the action and outcome only', async () => {
  const h = harness();
  await send(h, { action: 'add_tester', email: 'private.person@example.org', credits: 1000 });
  await send(h, grant({ reason: 'Secret project codename' }));
  await send(h, signIn({ reason: 'Personal circumstances' }));
  await send(harness({ owner: false }), grant());
  const text = JSON.stringify(h.logs);
  assert.equal(h.logs.length, 3);
  for (const secret of ['private.person', 'example.org', 'Secret project', 'Personal circumstances', TOKEN, TESTER, OWNER, REQUEST]) {
    assert.ok(!text.includes(secret), `logs leak ${secret}`);
  }
  assert.deepEqual(h.logs.map(l => [l.action, l.status, l.outcome]), [['add_tester', 200, 'ok'], ['grant_credits', 200, 'ok'], ['set_sign_in', 200, 'ok']]);
});

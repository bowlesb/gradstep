// The operator's finish-account-deletion guard (review A10): no network, no credentials; the client is injected.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import test from 'node:test';
import { assertStagingTarget, finishClosedAccount, parseArguments, Refused } from '../../scripts/finish-account-deletion.mjs';

const ACCOUNT = '5a000000-0000-4000-8000-000000000001';
const STAGING = 'coxhjvqpflgxkleydati';
const manifest = { projects: { staging: { id: STAGING } } };
const env = { SUPABASE_PROJECT_REF: STAGING, SUPABASE_URL: `https://${STAGING}.supabase.co`, SUPABASE_SERVICE_ROLE_KEY: 'fixture-key' };

function fakeService(closed) {
  const calls = [];
  return { calls, async rpc(name, params) {
    calls.push(name);
    if (name === 'worker_account_deletion_status') return { data: closed === undefined ? { closed: null } : { closed }, error: null };
    if (name === 'worker_delete_account_begin') return { data: { objects: [] }, error: null };
    throw new Error('unexpected rpc');
  } };
}

test('the account must be typed twice, exactly', () => {
  assert.deepEqual(parseArguments([ACCOUNT, `--confirm=${ACCOUNT}`]), { account: ACCOUNT });
  assert.throws(() => parseArguments([ACCOUNT]), Refused);
  assert.throws(() => parseArguments([ACCOUNT, '--confirm=5a000000-0000-4000-8000-000000000002']), /does not match/);
  assert.throws(() => parseArguments([ACCOUNT, `--confirm=${ACCOUNT}`, '--force']), Refused);
  assert.throws(() => parseArguments(['not-a-uuid', '--confirm=not-a-uuid']), Refused);
  assert.throws(() => parseArguments([ACCOUNT.toUpperCase(), `--confirm=${ACCOUNT.toUpperCase()}`]), Refused);
});

test('only the recorded staging project is a target', () => {
  assert.equal(assertStagingTarget(env, manifest), STAGING);
  assert.throws(() => assertStagingTarget({ ...env, SUPABASE_PROJECT_REF: 'abcdefghijklmnopqrst' }, manifest), /staging project/);
  assert.throws(() => assertStagingTarget({ ...env, SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co' }, manifest), /SUPABASE_URL/);
  assert.throws(() => assertStagingTarget({ ...env, SUPABASE_URL: `https://${STAGING}.supabase.co.example` }, manifest), /SUPABASE_URL/);
  assert.throws(() => assertStagingTarget(env, { projects: {} }), /does not record/);
  assert.throws(() => assertStagingTarget({ ...env, SUPABASE_SERVICE_ROLE_KEY: '' }, manifest), /service key/);
});

test('an open or missing account is refused before any write; a closed one is finished', async () => {
  for (const closed of [false, undefined]) {
    const service = fakeService(closed);
    let completed = false;
    await assert.rejects(finishClosedAccount(service, ACCOUNT, async () => { completed = true; }), Refused);
    assert.deepEqual(service.calls, ['worker_account_deletion_status'], 'begin (which closes and deletes) never runs');
    assert.equal(completed, false);
  }
  const service = fakeService(true);
  const result = await finishClosedAccount(service, ACCOUNT, async (_client, account, begun) => ({ complete: true, account, begun }));
  assert.deepEqual(service.calls, ['worker_account_deletion_status', 'worker_delete_account_begin']);
  assert.deepEqual(result, { complete: true, account: ACCOUNT, begun: { objects: [] } });
});

test('an unreadable status stops the script', async () => {
  const service = { async rpc() { return { data: null, error: { message: 'transport' } }; } };
  await assert.rejects(finishClosedAccount(service, ACCOUNT, async () => ({})), /status_unavailable/);
});

test('run without a confirmation, the script exits 2 before reading any credential', () => {
  let failure;
  try { execFileSync(process.execPath, ['scripts/finish-account-deletion.mjs', ACCOUNT], { stdio: 'pipe', encoding: 'utf8' }); }
  catch (error) { failure = error; }
  assert.equal(failure?.status, 2);
  assert.match(failure.stderr, /--confirm/);
});

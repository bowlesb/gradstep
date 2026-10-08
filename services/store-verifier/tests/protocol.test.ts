import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { parseRequest, parseReply, replyFor, isDecision, MAX_BODY_BYTES, POLICY_ID, type VerificationRequest } from '../protocol.ts';

export const request = (signed = 'a'.repeat(20) + '.bb.cc', kind: VerificationRequest['kind'] = 'transaction'): VerificationRequest => ({
  version: 1, attempt_id: '01000000-0000-0000-0000-000000000001', kind, policy_id: POLICY_ID, signed_payload: signed,
  signed_sha256: createHash('sha256').update(signed).digest('hex'),
});
export const record = { environment: 'Sandbox', transaction_id: '2001', original_transaction_id: '2000', product_id: 'com.sciencereader.ios.credits400',
  type: 'Consumable', purchase_date: 1_700_000_000_000, signed_date: 1_700_000_000_001 };

test('request binds exact ASCII bytes and a closed version/kind/policy envelope', () => {
  assert.deepEqual(parseRequest(request()), request());
  for (const change of [{ version: 2 }, { policy_id: 'production' }, { kind: 'other' }, { online_checks: false }, { signed_sha256: 'a'.repeat(64) },
    { attempt_id: '01000000-0000-0000-0000-00000000000A' }, { signed_sha256: request().signed_sha256.toUpperCase() }, { attempt_id: request().attempt_id + '\n' }, { signed_sha256: request().signed_sha256 + '\n' }]) {
    assert.equal(parseRequest({ ...request(), ...change }), null);
  }
  for (const signed of ['a.b.c', 'a..b', '.a.b', 'a.b.', 'a.b.c.d', 'a+.b.c', 'a=.b.c', 'a/.b.c', 'a\n.b.c', 'a'.repeat(20) + '.b.c\n', 'a'.repeat(20) + '.b.c\u2028', 'é.b.c', 'a.b.👩', 'a'.repeat(64_001) + '.b.c']) {
    assert.equal(parseRequest(request(signed)), null);
  }
  const max = request('a'.repeat(63_996) + '.b.c');
  assert.equal(max.signed_payload.length, 64_000);
  assert.ok(parseRequest(max));
  assert.ok(Buffer.byteLength(JSON.stringify(max)) < MAX_BODY_BYTES);
});

test('reply is bound by the parent; worker extras, wrong kinds and unsafe diagnostics fail closed', () => {
  const decision = { status: 'verified', transaction: record };
  const reply = replyFor(request(), decision);
  assert.equal(reply.status, 200);
  const body = JSON.parse(reply.body);
  const { signed_payload: _, ...binding } = request();
  assert.deepEqual(body, { ...binding, ...decision });
  for (const value of [null, { ...decision, signed_payload: 'PRIVATE' }, { ...decision, attempt_id: 'PRIVATE' },
    { ...decision, transaction: { ...record, raw_claim: 'PRIVATE' } }, { ...decision, transaction: { ...record, environment: 'Production' } },
    { status: 'failed', code: 'PRIVATE', diagnostic: { stage: 'input' } },
    { status: 'failed', code: 'invalid', diagnostic: { stage: 'PRIVATE', message: 'PRIVATE' } },
    { status: 'failed', code: 'invalid', diagnostic: { stage: 'input', transport_code: 'PRIVATE' } },
    { status: 'verified', notification: {} }]) {
    const failed = replyFor(request(), value);
    assert.equal(failed.status, 503);
    assert.equal(JSON.parse(failed.body).code, 'verification_unavailable');
    assert.ok(!failed.body.includes('PRIVATE'));
  }
});

test('response status distinguishes deterministic refusal and unavailable without arbitrary strings', () => {
  for (const code of ['invalid', 'environment_unavailable', 'verification_unavailable'] as const) {
    const result = replyFor(request(), { status: 'failed', code, diagnostic: { stage: 'revocation', apple_status: 'retryable_verification_failure', transport_code: 'timeout' } });
    assert.equal(result.status, code === 'verification_unavailable' ? 503 : 200);
    assert.equal(JSON.parse(result.body).code, code);
  }
});

test('notification schema accepts normalized subsets and never the nested signed transaction', () => {
  const notification = { environment: 'Sandbox', notification_uuid: 'test-id', type: 'DID_RENEW', subtype: null,
    signed_at: new Date(record.signed_date).toISOString(), transaction: record };
  assert.ok(isDecision({ status: 'verified', notification }, 'notification'));
  assert.ok(isDecision({ status: 'verified', notification: { ...notification, transaction: null } }, 'notification'));
  for (const changed of [{ signedTransactionInfo: 'PRIVATE' }, { signed_at: 'yesterday' }, { signed_at: '2023-11-14T00:00:00Z' },
    { transaction: { ...record, environment: 'Production' } }]) {
    assert.equal(isDecision({ status: 'verified', notification: { ...notification, ...changed } }, 'notification'), false);
  }
  assert.equal(isDecision({ status: 'verified', notification }, 'transaction'), false);
});

test('large legitimate normalized fields fit the 72KiB envelope; oversized worker output never escapes', () => {
  const payload = { ...record, product_id: 'x'.repeat(40_000) };
  assert.equal(replyFor(request(), { status: 'verified', transaction: payload }).status, 200);
  const reply = replyFor(request(), { status: 'verified', transaction: { ...record, product_id: 'x'.repeat(MAX_BODY_BYTES) } });
  assert.equal(reply.status, 503);
  assert.ok(Buffer.byteLength(reply.body) < MAX_BODY_BYTES);
});

test('shared reply parser requires every binding and rejects extra or mismatched decision keys', () => {
  const input = request();
  const verified = JSON.parse(replyFor(input, { status: 'verified', transaction: record }).body);
  assert.deepEqual(parseReply(verified, input), verified);
  for (const changed of [{ version: 2 }, { attempt_id: '01000000-0000-0000-0000-000000000002' }, { kind: 'notification' },
    { policy_id: 'production' }, { signed_sha256: '0'.repeat(64) }, { signed_payload: input.signed_payload }, { private_claim: 'PRIVATE' }]) {
    assert.equal(parseReply({ ...verified, ...changed }, input), null);
  }
  for (const key of Object.keys(verified)) {
    const missing = { ...verified }; delete missing[key];
    assert.equal(parseReply(missing, input), null, key);
  }
  assert.equal(parseReply({ ...verified, notification: { environment: 'Sandbox' } }, input), null);
  const failure = JSON.parse(replyFor(input, { status: 'failed', code: 'invalid', diagnostic: { stage: 'revocation' } }).body);
  assert.deepEqual(parseReply(failure, input), failure);
});

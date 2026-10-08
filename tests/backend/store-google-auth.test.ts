import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { createStoreGoogleIdentity, storeGoogleCredentials, storeVerifierAudience,
  STORE_GOOGLE_CALLER, StoreGoogleIdentityUnavailable } from '../../supabase/functions/_shared/store-google-auth.ts';

// Generated test-only credentials. All Google responses below are injected;
// these tests have no live credential, Google network request or IAM authority.
const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
const rawCredentials = {
  type: 'service_account', project_id: 'gradstep', private_key_id: 'a'.repeat(40),
  private_key: keys.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
  client_email: STORE_GOOGLE_CALLER, client_id: '123456789012345678901',
  token_uri: 'https://oauth2.googleapis.com/token', universe_domain: 'googleapis.com',
};
const credentials = storeGoogleCredentials(JSON.stringify(rawCredentials));
const audience = 'https://gradstep-store-verifier-test-uw.a.run.app';
const started = 1_791_422_400_000;
function token(now = started, fields: Record<string, unknown> = {}) {
  return 'e30.' + Buffer.from(JSON.stringify({ iss: 'https://accounts.google.com', aud: audience,
    sub: credentials.clientID, email: credentials.email, exp: Math.floor(now / 1000) + 3600, ...fields })).toString('base64url') + '.dGVzdA';
}
const good = (value = token()) => new Response(JSON.stringify({ id_token: value, expires_in: 3600 }), {
  headers: { 'content-type': 'application/json' },
});
function unavailable(error: unknown): boolean {
  assert.ok(error instanceof StoreGoogleIdentityUnavailable);
  assert.equal(error.message, 'store_google_identity_unavailable');
  assert.equal('cause' in error, false, 'credential/provider errors must not be retained as causes');
  return true;
}

test('only a dedicated explicit service-account credential and canonical verifier audience are accepted', () => {
  assert.equal(credentials.email, STORE_GOOGLE_CALLER);
  assert.ok(Object.isFrozen(credentials));
  assert.equal(storeVerifierAudience(audience), audience);
  assert.equal(storeVerifierAudience('https://gradstep-store-verifier-885355087025.us-west1.run.app'),
    'https://gradstep-store-verifier-885355087025.us-west1.run.app');
  for (const value of [null, '{}', '[]', 'null', 'bad', JSON.stringify({ ...rawCredentials, type: 'external_account' }),
    JSON.stringify({ ...rawCredentials, client_email: 'someone@else.iam.gserviceaccount.com' }),
    JSON.stringify({ ...rawCredentials, project_id: 'another-project' }),
    JSON.stringify({ ...rawCredentials, token_uri: 'https://example.com/token' }),
    JSON.stringify({ ...rawCredentials, credential_source: { executable: { command: 'do-not-run' } } }),
    JSON.stringify({ ...rawCredentials, private_key: 'not a private key' }),
    JSON.stringify({ ...rawCredentials, private_key_id: 'not a key ID' }), 'x'.repeat(16_385)]) {
    assert.throws(() => storeGoogleCredentials(value), unavailable);
  }
  for (const value of [null, 'http://gradstep-store-verifier-test-uw.a.run.app', audience + '/', audience + '/verify',
    audience + '?audience=other', audience + '#fragment', audience + '.example.com',
    'https://user:password@gradstep-store-verifier-test-uw.a.run.app',
    'https://gradstep-pipeline-test-uw.a.run.app', 'https://gradstep-store-verifier-test-uw.a.run.app:443',
    'https://gradstep-store-verifier-885355087025.us-east1.run.app']) {
    assert.throws(() => storeVerifierAudience(value), unavailable);
  }
});

test('the real Google SDK signs the correct assertion; one bounded request serves concurrent callers and cached reuse', async () => {
  let requests = 0, now = started;
  const identity = createStoreGoogleIdentity(credentials, audience, { now: () => now, fetch: async (input, init) => {
    requests++;
    assert.equal(String(input), 'https://oauth2.googleapis.com/token');
    assert.equal(init?.method, 'POST');
    assert.equal(init?.redirect, 'error');
    assert.ok(init?.signal);
    const body = new URLSearchParams(String(init?.body));
    assert.equal(body.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
    assert.deepEqual([...body.keys()].sort(), ['assertion', 'grant_type']);
    const assertion = body.get('assertion')!;
    const [header, payload, signature] = assertion.split('.');
    assert.ok(verify('RSA-SHA256', Buffer.from(header + '.' + payload), keys.publicKey, Buffer.from(signature, 'base64url')));
    const decoded = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    assert.equal(decoded.iss, STORE_GOOGLE_CALLER);
    assert.equal(decoded.aud, 'https://oauth2.googleapis.com/token');
    assert.equal(decoded.target_audience, audience);
    assert.equal(decoded.scope, undefined);
    assert.equal(decoded.sub, undefined);
    assert.ok(decoded.exp - decoded.iat <= 3600);
    return good(token(now));
  } });
  const first = identity.token(), parallel = identity.token();
  assert.equal(first, parallel);
  assert.equal(await first, token());
  assert.equal(await identity.token(), token());
  assert.equal(requests, 1);
  now += 3_500_000;
  assert.equal(await identity.token(), token(now));
  assert.equal(requests, 2, 'refresh inside the safety margin, before expiration');
});

test('Google errors, redirections and oversized responses remain finite and do not trigger SDK retries', async () => {
  const responses = [
    () => new Response(JSON.stringify({ error: 'PRIVATE_ASSERTION', error_description: 'PRIVATE_CREDENTIAL_BODY' }), { status: 503 }),
    () => new Response('', { status: 302, headers: { location: 'https://example.com/token' } }),
    () => new Response('x', { headers: { 'content-length': '16385' } }),
    () => new Response('x'.repeat(16_385)),
    () => new Response('not json'),
    () => { throw new Error('PRIVATE_AUTH_HEADER'); },
  ];
  for (const make of responses) {
    let calls = 0;
    const identity = createStoreGoogleIdentity(credentials, audience, { now: () => started, fetch: async () => { calls++; return make(); } });
    await assert.rejects(identity.token(), unavailable);
    assert.equal(calls, 1, 'even the real SDK POST retry defaults are disabled');
  }
});

test('a malformed or incorrectly scoped Google response is never cached as a usable identity', async () => {
  for (const value of [token(started, { aud: 'https://example.com' }), token(started, { sub: 'another-subject' }),
    token(started, { email: 'another@example.com' }), token(started, { iss: 'https://example.com' }),
    token(started, { exp: started / 1000 + 100 }), token(started, { exp: started / 1000 + 7200 }),
    token(started, { exp: 'future' }), 'not-a-jwt', 'a'.repeat(16_385)]) {
    let calls = 0;
    const identity = createStoreGoogleIdentity(credentials, audience, { now: () => started, fetch: async () => { calls++; return good(value); } });
    await assert.rejects(identity.token(), unavailable);
    await assert.rejects(identity.token(), unavailable);
    assert.equal(calls, 2, 'only an explicit subsequent request may try again');
  }
});

test('invalidation fences a late token response and does not resend an admitted verifier request', async () => {
  let calls = 0;
  let release!: () => void;
  const hold = new Promise<void>(resolve => { release = resolve; });
  let firstEntered!: () => void;
  const entered = new Promise<void>(resolve => { firstEntered = resolve; });
  const identity = createStoreGoogleIdentity(credentials, audience, { now: () => started, fetch: async () => {
    calls++;
    if (calls === 1) { firstEntered(); await hold; }
    return good();
  } });
  const first = identity.token();
  await entered;
  identity.invalidate();
  const second = identity.token();
  assert.equal(await second, token());
  release();
  await assert.rejects(first, unavailable);
  assert.equal(await identity.token(), token());
  assert.equal(calls, 2);
});

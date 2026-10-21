// Review A8: an App Store Server Notification is authenticated in the Edge function before any admission. Throwaway
// chains shaped like Apple's (P-384 root and WWDR-marked intermediate, P-256 App Store leaf, SHA-384 certificate
// signatures, ES256 JWS) prove the positive path; every check has its own negative case; production pins the real root.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createPrivateKey, sign } from 'node:crypto';
import jsrsasign from 'jsrsasign';
import { APPLE_ROOT_CA_G3_SHA256, appleRootG3, authenticateAppleNotification, parseCertificate, signedBy, type NotificationAuthFailure }
  from '../../supabase/functions/_shared/app-store-jws.ts';
import { appleRootCertificates, APPLE_ROOT_CA_G3_SHA256 as VERIFIER_ROOT_SHA256 } from '../../supabase/functions/_shared/app-store.ts';

const { KEYUTIL, KJUR } = jsrsasign as unknown as { KEYUTIL: any; KJUR: any };
const POLICY = { bundleID: 'com.sciencereader.ios', environments: ['Sandbox'] };
const LEAF_MARKER = { extname: '1.2.840.113635.100.6.11.1', extn: '0500' };
const INTERMEDIATE_MARKER = { extname: '1.2.840.113635.100.6.2.1', extn: '0500' };
const CA = { extname: 'basicConstraints', critical: true, cA: true };
const NOW = Date.UTC(2026, 9, 21, 12);

type Options = { leafMarker?: boolean; intermediateMarker?: boolean; intermediateCA?: boolean; leafNotAfter?: string; leafNotBefore?: string;
  forgedIntermediate?: boolean; forgedLeaf?: boolean; leafIssuer?: string; leafCurve?: string };
function chain(options: Options = {}) {
  const pair = (curve: string) => KEYUTIL.generateKeypair('EC', curve);
  const root = pair('secp384r1'), intermediate = pair('secp384r1'), leaf = pair(options.leafCurve ?? 'secp256r1'), stranger = pair('secp384r1');
  const name = (cn: string) => ({ str: `/CN=${cn}/OU=Gradstep Tests/O=Example/C=US` });
  const cert = (subject: string, issuer: string, key: unknown, signer: unknown, ext: unknown[], notbefore = '250101000000Z', notafter = '351231235959Z') =>
    new KJUR.asn1.x509.Certificate({ version: 3, serial: { int: Math.floor(Math.random() * 1e9) }, issuer: name(issuer), subject: name(subject),
      notbefore, notafter, sbjpubkey: key, sigalg: 'SHA384withECDSA', cakey: signer, ext }).tohex();
  const rootHex = cert('Test Root', 'Test Root', root.pubKeyObj, root.prvKeyObj, [CA]);
  const intermediateHex = cert('Test WWDR', 'Test Root', intermediate.pubKeyObj, options.forgedIntermediate ? stranger.prvKeyObj : root.prvKeyObj,
    [...(options.intermediateCA === false ? [] : [CA]), ...(options.intermediateMarker === false ? [] : [INTERMEDIATE_MARKER])]);
  const leafHex = cert('Test Leaf', options.leafIssuer ?? 'Test WWDR', leaf.pubKeyObj, options.forgedLeaf ? stranger.prvKeyObj : intermediate.prvKeyObj,
    options.leafMarker === false ? [] : [LEAF_MARKER], options.leafNotBefore, options.leafNotAfter);
  const b64 = (hex: string) => Buffer.from(hex, 'hex').toString('base64');
  const leafKey = createPrivateKey(KEYUTIL.getPEM(leaf.prvKeyObj, 'PKCS8PRV'));
  return {
    root: Buffer.from(rootHex, 'hex'),
    sign(payload: unknown, header: Record<string, unknown> = {}, tamper = false): string {
      const head = Buffer.from(JSON.stringify({ alg: 'ES256', x5c: [b64(leafHex), b64(intermediateHex), b64(rootHex)], ...header })).toString('base64url');
      const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
      const signature = sign('sha256', Buffer.from(`${head}.${body}`), { key: leafKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      const sent = tamper ? Buffer.from(JSON.stringify({ ...(payload as object), notificationType: 'REFUND' })).toString('base64url') : body;
      return `${head}.${sent}.${signature}`;
    },
    hex: { root: rootHex, intermediate: intermediateHex, leaf: leafHex },
  };
}
const notification = (data: Record<string, unknown> = {}) => ({ notificationType: 'DID_RENEW', notificationUUID: '7e3fb20b-4cdb-47cc-936d-99d65f608138',
  signedDate: NOW, version: '2.0', data: { bundleId: POLICY.bundleID, environment: 'Sandbox', signedTransactionInfo: 'inner.jws.value', ...data } });
const check = (signed: unknown, root?: Uint8Array, now = NOW) => authenticateAppleNotification(signed, POLICY, { root, now });
async function refused(signed: unknown, failure: NotificationAuthFailure, root?: Uint8Array, now = NOW) {
  assert.deepEqual(await check(signed, root, now), { ok: false, failure });
}

test('an Apple-shaped notification signed through its own chain is authenticated', async () => {
  const pki = chain();
  assert.deepEqual(await check(pki.sign(notification()), pki.root), { ok: true });
  // The summary form (a mass renewal-extension notice) names the bundle and environment there.
  assert.deepEqual(await check(pki.sign({ notificationType: 'RENEWAL_EXTENSION', summary: { bundleId: POLICY.bundleID, environment: 'Sandbox' } }), pki.root), { ok: true });
});

test('production pins Apple Root CA - G3: the same bytes as the private verifier, and a test chain never passes without injection', async () => {
  const root = await appleRootG3();
  assert.equal(APPLE_ROOT_CA_G3_SHA256, VERIFIER_ROOT_SHA256);
  assert.deepEqual(Buffer.from(root), appleRootCertificates()[0], 'one pinned root for the Edge check and the verifier');
  // The real root parses with this reader and its self-signature (P-384, ECDSA-SHA384, DER signature) verifies.
  const parsed = parseCertificate(root);
  assert.equal(parsed.curve, 'P-384');
  assert.equal(parsed.hash, 'SHA-384');
  assert.ok(parsed.ca);
  assert.ok(await signedBy(parsed, parsed), 'Apple Root CA - G3 verifies its own signature');
  await refused(chain().sign(notification()), 'root');
});

test('framing, header and chain shape are refused before any certificate work', async () => {
  const pki = chain(), good = pki.sign(notification());
  await refused(undefined, 'framing', pki.root);
  await refused('a.b', 'framing', pki.root);
  await refused(`${good}.extra`, 'framing', pki.root);
  await refused(good.replace('.', '.+'), 'framing', pki.root);
  await refused('x'.repeat(64_001), 'framing', pki.root);
  await refused(`bm90IGpzb24.${good.split('.')[1]}.${good.split('.')[2]}`, 'header', pki.root);
  await refused(pki.sign(notification(), { alg: 'RS256' }), 'header', pki.root);
  await refused(pki.sign(notification(), { alg: 'none' }), 'header', pki.root);
  await refused(pki.sign(notification(), { x5c: [Buffer.from(pki.hex.leaf, 'hex').toString('base64'), Buffer.from(pki.hex.root, 'hex').toString('base64')] }), 'chain_length', pki.root);
  await refused(pki.sign(notification(), { x5c: 'not-a-chain' }), 'chain_length', pki.root);
  await refused(pki.sign(notification(), { x5c: ['AAAA', Buffer.from(pki.hex.intermediate, 'hex').toString('base64'), Buffer.from(pki.hex.root, 'hex').toString('base64')] }), 'certificate', pki.root);
  await refused(pki.sign(notification(), { x5c: ['@@@', 'x', 'y'] }), 'certificate', pki.root);
});

test('the root must be the pinned one, byte for byte', async () => {
  const pki = chain(), other = chain();
  await refused(pki.sign(notification()), 'root', other.root);
});

test('each link of the chain is checked: signatures, issuer names and the CA flag', async () => {
  for (const [options, label] of [[{ forgedIntermediate: true }, 'intermediate not signed by the root'], [{ forgedLeaf: true }, 'leaf not signed by the intermediate'],
    [{ leafIssuer: 'Someone Else' }, 'leaf names another issuer'], [{ intermediateCA: false }, 'intermediate is not a CA']] as const) {
    const pki = chain(options);
    assert.deepEqual(await check(pki.sign(notification()), pki.root), { ok: false, failure: 'chain' }, label);
  }
});

test('Apple marker extensions are required on the leaf and on the intermediate', async () => {
  const leaf = chain({ leafMarker: false });
  await refused(leaf.sign(notification()), 'marker', leaf.root);
  const intermediate = chain({ intermediateMarker: false });
  await refused(intermediate.sign(notification()), 'marker', intermediate.root);
});

test('certificates must be valid now, within a minute of skew', async () => {
  const expired = chain({ leafNotAfter: '261020000000Z' });
  await refused(expired.sign(notification()), 'validity', expired.root);
  const early = chain({ leafNotBefore: '261022000000Z' });
  await refused(early.sign(notification()), 'validity', early.root);
  const pki = chain();
  await refused(pki.sign(notification()), 'validity', pki.root, Date.UTC(2036, 0, 1, 0, 1));
  assert.deepEqual(await check(pki.sign(notification()), pki.root, Date.UTC(2024, 11, 31, 23, 59, 30)), { ok: true }, 'inside the 60 s skew');
});

test('the JWS signature must verify under the leaf key, which must be P-256', async () => {
  const pki = chain();
  await refused(pki.sign(notification(), {}, true), 'signature', pki.root);
  const good = pki.sign(notification()).split('.');
  await refused(`${good[0]}.${good[1]}.${good[2].slice(0, -4)}`, 'signature', pki.root);
  // ES256 needs a P-256 leaf: a P-384 leaf's (96-byte) signature is refused even though its chain is valid.
  const p384 = chain({ leafCurve: 'secp384r1' });
  await refused(p384.sign(notification()), 'signature', p384.root);
});

test('the payload must name our bundle and an allowed environment', async () => {
  const pki = chain();
  await refused(pki.sign(notification({ bundleId: 'com.example.other' })), 'claims', pki.root);
  await refused(pki.sign(notification({ environment: 'Production' })), 'claims', pki.root);
  await refused(pki.sign({ notificationType: 'TEST' }), 'claims', pki.root);
  await refused(pki.sign([1, 2, 3]), 'claims', pki.root);
});

test('the Edge entry point authenticates before it builds a client or consumes admission', async () => {
  const { readFile } = await import('node:fs/promises');
  const source = await readFile(new URL('../../supabase/functions/app-store-notifications/index.ts', import.meta.url), 'utf8');
  const gate = source.indexOf('authenticateAppleNotification('), client = source.indexOf('serviceClient()'), transport = source.indexOf('createStoreRecordTransport(');
  assert.ok(gate > 0 && gate < client && gate < transport, 'the gate precedes the service client and the admitted transport');
  assert.ok(!/authenticateAppleNotification\([^)]*root/.test(source), 'production never injects a root');
  assert.ok(!source.includes("from '../_shared/app-store.ts'"), 'the Edge function never imports the Node-only Apple SDK module');
});

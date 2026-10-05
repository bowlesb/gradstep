import test from 'node:test';
import assert from 'node:assert/strict';
import { createPrivateKey, sign, X509Certificate } from 'node:crypto';
import jsrsasign from 'jsrsasign';
import {
  appleRootCertificates, appleVerifier, claimedEnvironment, FINAL_OUTCOMES, handleNotification, StoreVerificationError, storeConfig,
  syncTransactions, transactionRecord, verificationError, type StoreDeps, type StoreTransactionRecord,
} from '../../supabase/functions/_shared/app-store.ts';
import { VerificationException, VerificationStatus } from '@apple/app-store-server-library';

const { KEYUTIL, KJUR } = jsrsasign as unknown as { KEYUTIL: any; KJUR: any };
const BUNDLE = 'com.sciencereader.ios';
const ACCOUNT = '18000000-0000-0000-0000-00000000000a';

/** A throwaway chain shaped like Apple's: root → intermediate (Apple WWDR OID) → leaf (App Store receipt-signing OID). */
function testPKI() {
  const keypair = () => KEYUTIL.generateKeypair('EC', 'secp256r1');
  const root = keypair(), intermediate = keypair(), leaf = keypair();
  const name = (cn: string) => ({ str: `/CN=${cn}/O=Science Reader Tests/C=US` });
  const cert = (subject: string, issuer: string, publicKey: unknown, signer: unknown, ext: unknown[]) => new KJUR.asn1.x509.Certificate({
    version: 3, serial: { int: Math.floor(Math.random() * 1e9) }, issuer: name(issuer), subject: name(subject),
    notbefore: '250101000000Z', notafter: '351231235959Z', sbjpubkey: publicKey, sigalg: 'SHA256withECDSA', cakey: signer, ext,
  }).tohex();
  const rootHex = cert('Test Root', 'Test Root', root.pubKeyObj, root.prvKeyObj, [{ extname: 'basicConstraints', critical: true, cA: true }]);
  const intermediateHex = cert('Test Intermediate', 'Test Root', intermediate.pubKeyObj, root.prvKeyObj,
    [{ extname: 'basicConstraints', critical: true, cA: true }, { extname: '1.2.840.113635.100.6.2.1', extn: '0500' }]);
  const leafHex = cert('Test Leaf', 'Test Intermediate', leaf.pubKeyObj, intermediate.prvKeyObj, [{ extname: '1.2.840.113635.100.6.11.1', extn: '0500' }]);
  const b64 = (hex: string) => Buffer.from(hex, 'hex').toString('base64');
  const leafKey = createPrivateKey(KEYUTIL.getPEM(leaf.prvKeyObj, 'PKCS8PRV'));
  return {
    root: Buffer.from(rootHex, 'hex'),
    sign(payload: unknown, tamper = false): string {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', x5c: [b64(leafHex), b64(intermediateHex), b64(rootHex)] })).toString('base64url');
      const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
      const signature = sign('sha256', Buffer.from(`${header}.${body}`), { key: leafKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      const sent = tamper ? Buffer.from(JSON.stringify({ ...(payload as object), quantity: 9 })).toString('base64url') : body;
      return `${header}.${sent}.${signature}`;
    },
  };
}
const pki = testPKI();
const now = Date.now();
const transaction = (overrides: Record<string, unknown> = {}) => ({
  transactionId: '2000000123456789', originalTransactionId: '2000000123456789', bundleId: BUNDLE,
  productId: 'com.sciencereader.ios.standard.monthly', purchaseDate: now - 60_000, originalPurchaseDate: now - 60_000,
  expiresDate: now + 30 * 86_400_000, quantity: 1, type: 'Auto-Renewable Subscription', appAccountToken: ACCOUNT.toUpperCase(),
  inAppOwnershipType: 'PURCHASED', signedDate: now, environment: 'Sandbox', transactionReason: 'PURCHASE', storefront: 'USA',
  storefrontId: '143441', price: 9990, currency: 'USD', ...overrides,
});
const config = { bundleID: BUNDLE, environments: ['Sandbox' as const], onlineChecks: false };

test('the bundled Apple root is Apple Root CA - G3', () => {
  const [der] = appleRootCertificates();
  assert.match(new X509Certificate(der).subject, /Apple Root CA - G3/);
});

test('configuration: Production needs the numeric app ID; unknown environments are refused', () => {
  const env = (values: Record<string, string>) => (name: string) => values[name];
  assert.deepEqual(storeConfig(env({ APP_STORE_BUNDLE_ID: BUNDLE, APP_STORE_ENVIRONMENTS: 'Sandbox' })),
    { bundleID: BUNDLE, environments: ['Sandbox'], appAppleID: undefined, onlineChecks: true });
  assert.equal(storeConfig(env({ APP_STORE_BUNDLE_ID: BUNDLE, APP_STORE_ENVIRONMENTS: 'Sandbox,Production' })), null);
  assert.equal(storeConfig(env({ APP_STORE_BUNDLE_ID: BUNDLE, APP_STORE_ENVIRONMENTS: 'Xcode' })), null);
  assert.equal(storeConfig(env({ APP_STORE_ENVIRONMENTS: 'Sandbox' })), null);
  assert.equal(storeConfig(env({ APP_STORE_BUNDLE_ID: BUNDLE, APP_STORE_ENVIRONMENTS: 'Sandbox', APP_STORE_ONLINE_CHECKS: 'false' }))?.onlineChecks, false);
});

test('a transaction signed through an Apple-shaped chain verifies only against its own root', async () => {
  const signed = pki.sign(transaction());
  const decoded = await appleVerifier(config, [pki.root]).transaction(signed);
  assert.equal(decoded.transactionId, '2000000123456789');
  await assert.rejects(appleVerifier(config).transaction(signed), { code: 'invalid' }, 'the real Apple root rejects a test chain');
  await assert.rejects(appleVerifier(config, [pki.root]).transaction(pki.sign(transaction(), true)), { code: 'invalid' }, 'tampered payload');
  await assert.rejects(appleVerifier(config, [pki.root]).transaction(pki.sign(transaction({ bundleId: 'com.example.other' }))), { code: 'invalid' }, 'other app');
  await assert.rejects(appleVerifier(config, [pki.root]).transaction(pki.sign(transaction({ environment: 'Production' }))), { code: 'environment_unavailable' });
  await assert.rejects(appleVerifier(config, [pki.root]).transaction(pki.sign(transaction({ environment: 'Xcode' }))), { code: 'environment_unavailable' },
    'Xcode StoreKit testing data is never accepted');
  await assert.rejects(appleVerifier(config, [pki.root]).transaction('a.b.c'), { code: 'invalid' });
  // An unsigned token claiming alg none.
  const none = `${Buffer.from('{"alg":"none"}').toString('base64url')}.${Buffer.from(JSON.stringify(transaction())).toString('base64url')}.`;
  await assert.rejects(appleVerifier(config, [pki.root]).transaction(none + 'x'), { code: 'invalid' });
});

test('normalized records carry only verified fields, token lowercased', () => {
  const record = transactionRecord(transaction() as any)!;
  assert.deepEqual(record, {
    environment: 'Sandbox', transaction_id: '2000000123456789', original_transaction_id: '2000000123456789',
    product_id: 'com.sciencereader.ios.standard.monthly', type: 'Auto-Renewable Subscription', purchase_date: now - 60_000, signed_date: now,
    expires_date: now + 30 * 86_400_000, app_account_token: ACCOUNT, quantity: 1, ownership: 'PURCHASED', reason: 'PURCHASE',
  });
  assert.equal(transactionRecord(transaction({ appTransactionId: '704289572311' }) as any)!.app_transaction_id, '704289572311');
  assert.equal(transactionRecord(transaction({ transactionReason: 'SOMETHING' }) as any)!.reason, undefined);
  assert.equal(transactionRecord(transaction({ purchaseDate: 'yesterday' }) as any), null);
  assert.equal(transactionRecord(transaction({ transactionId: undefined }) as any), null);
  assert.equal(claimedEnvironment('x.' + Buffer.from('{"environment":"Sandbox"}').toString('base64url') + '.y', false), 'Sandbox');
});

function deps(outcome = 'recorded') {
  const transactions: { accountID: string; record: StoreTransactionRecord }[] = [], notifications: unknown[] = [];
  const value: StoreDeps = {
    verifier: appleVerifier(config, [pki.root]),
    async recordTransaction(accountID, record) { transactions.push({ accountID, record }); return { outcome, credits: 800 }; },
    async recordNotification(input) { notifications.push(input); return { outcome: input.transaction ? outcome : 'no_transaction' }; },
  };
  return { value, transactions, notifications };
}

test('sync records each verified transaction for the caller and reports the rest', async () => {
  const d = deps();
  const results = await syncTransactions(d.value, ACCOUNT, { transactions: [pki.sign(transaction()), pki.sign(transaction(), true),
    pki.sign(transaction({ environment: 'Production' }))] });
  assert.deepEqual(results, [{ transaction_id: '2000000123456789', outcome: 'recorded', credits: 800 }, { outcome: 'invalid' }, { outcome: 'environment_unavailable' }]);
  assert.equal(d.transactions.length, 1);
  assert.equal(d.transactions[0].accountID, ACCOUNT);
  assert.ok(FINAL_OUTCOMES.has('recorded') && FINAL_OUTCOMES.has('already_recorded') && !FINAL_OUTCOMES.has('linked_to_another_account'));
  for (const body of [{}, { transactions: [] }, { transactions: [1] }, { transactions: Array(26).fill('a.b.c') }]) {
    await assert.rejects(syncTransactions(d.value, ACCOUNT, body), /invalid_request/);
  }
});

test('notifications: verified renewals are recorded; bad data is refused; database errors propagate for Apple to retry', async () => {
  const d = deps();
  const notification = (data: Record<string, unknown>, overrides: Record<string, unknown> = {}) => pki.sign({
    notificationType: 'DID_RENEW', notificationUUID: '6c4ab0b9-6c2d-4d1a-9f9a-3c1a6f6f2f10', version: '2.0', signedDate: now,
    data: { bundleId: BUNDLE, environment: 'Sandbox', status: 1, ...data }, ...overrides,
  });
  const renewal = pki.sign(transaction({ transactionId: '2000000123456790', purchaseDate: now, expiresDate: now + 30 * 86_400_000 }));
  assert.deepEqual(await handleNotification(d.value, { signedPayload: notification({ signedTransactionInfo: renewal }) }), { status: 200, outcome: 'recorded' });
  assert.equal((d.notifications[0] as any).transaction.transaction_id, '2000000123456790');
  assert.equal((d.notifications[0] as any).signed_at, new Date(now).toISOString());
  assert.deepEqual(await handleNotification(d.value, { signedPayload: notification({}, { notificationType: 'TEST' }) }), { status: 200, outcome: 'no_transaction' });
  assert.equal((await handleNotification(d.value, { signedPayload: notification({ signedTransactionInfo: renewal }, { notificationUUID: undefined }) })).status, 400);
  assert.equal((await handleNotification(d.value, { signedPayload: notification({ bundleId: 'com.example.other' }) })).status, 400);
  assert.equal((await handleNotification(d.value, { signedPayload: notification({ signedTransactionInfo: 'a.b.c' }) })).status, 400);
  assert.equal((await handleNotification(d.value, { signedPayload: notification({ environment: 'Production' }) })).status, 400);
  assert.equal((await handleNotification(d.value, {})).status, 400);
  assert.equal(d.notifications.length, 2);
  const failing: StoreDeps = { ...d.value, async recordNotification() { throw new Error('database_unavailable'); } };
  await assert.rejects(handleNotification(failing, { signedPayload: notification({ signedTransactionInfo: renewal }) }), /database_unavailable/);
});

test('an unreachable revocation check is retryable: the app keeps the purchase unfinished and Apple gets 503', async () => {
  assert.equal(verificationError(new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE)).code, 'verification_unavailable');
  assert.equal(verificationError(new VerificationException(VerificationStatus.VERIFICATION_FAILURE)).code, 'invalid');
  assert.equal(verificationError(new Error('x')).code, 'invalid');
  const d = deps();
  const unreachable: StoreDeps = { ...d.value, verifier: {
    async transaction() { throw new StoreVerificationError('verification_unavailable'); },
    async notification() { throw new StoreVerificationError('verification_unavailable'); },
  } };
  assert.deepEqual(await syncTransactions(unreachable, ACCOUNT, { transactions: ['a.b.c'] }), [{ outcome: 'verification_unavailable' }]);
  assert.ok(!FINAL_OUTCOMES.has('verification_unavailable'));
  assert.deepEqual(await handleNotification(unreachable, { signedPayload: 'a.b.c' }), { status: 503, outcome: 'verification_unavailable' });
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { StoreVerificationError, handleNotification, syncTransactions, transactionRecord, verifyNotificationRecord, verifyTransactionRecord,
  type StoreDeps, type StoreRecordVerifier, type StoreVerifier } from '../../../supabase/functions/_shared/store-purchases.ts';

const decoded = { environment: 'Sandbox', transactionId: '2001', originalTransactionId: '2000', productId: 'com.sciencereader.ios.credits400',
  type: 'Consumable', purchaseDate: 1_700_000_000_000, signedDate: 1_700_000_000_001, appAccountToken: 'ABC', quantity: 1, transactionReason: 'PURCHASE',
  privateClaim: 'PRIVATE' };
const notice = { notificationUUID: 'test-id', notificationType: 'ONE_TIME_CHARGE', subtype: 'INITIAL_BUY', signedDate: decoded.signedDate,
  data: { environment: 'Sandbox', signedTransactionInfo: 'INNER_JWS', privateClaim: 'PRIVATE' } };
const local = (): StoreVerifier => ({ transaction: async () => decoded as any, notification: async () => notice as any });

test('portable purchase module can load when runtime Apple SDK imports are prohibited', () => {
  const module = new URL('../../../supabase/functions/_shared/store-purchases.ts', import.meta.url).href;
  const code = `import {registerHooks} from 'node:module'; registerHooks({resolve(s,c,n){if(s.includes('app-store-server-library')||s.endsWith('app-store.ts'))throw Error('Node adapter reached portable import'); return n(s,c)}}); await import(${JSON.stringify(module)});`;
  assert.equal(execFileSync(process.execPath, ['--input-type=module', '-e', code], { encoding: 'utf8' }), '');
});

test('pure helpers return only normalized transaction and notification records, without recorder tricks', async () => {
  const record = await verifyTransactionRecord(local(), 'OUTER');
  assert.deepEqual(record, transactionRecord(decoded as any)); assert.equal(record.app_account_token, 'abc');
  const calls: string[] = [];
  const verified = await verifyNotificationRecord({ transaction: async signed => { calls.push(signed); return decoded as any; },
    notification: async signed => { calls.push(signed); return notice as any; } }, 'OUTER');
  assert.deepEqual(calls, ['OUTER', 'INNER_JWS']);
  assert.deepEqual(verified, { environment: 'Sandbox', notification_uuid: 'test-id', type: 'ONE_TIME_CHARGE', subtype: 'INITIAL_BUY',
    signed_at: new Date(decoded.signedDate).toISOString(), transaction: record });
  assert.ok(!JSON.stringify(verified).includes('PRIVATE')); assert.ok(!JSON.stringify(verified).includes('JWS'));
});

test('outer/inner mismatch, invalid normalized fields and retryable inner verification fail before recording', async () => {
  await assert.rejects(verifyNotificationRecord({ ...local(), transaction: async () => ({ ...decoded, environment: 'Production' }) as any }, 'outer'),
    { code: 'invalid', diagnostic: { stage: 'transaction_fields' } });
  await assert.rejects(verifyTransactionRecord({ ...local(), transaction: async () => ({ ...decoded, signedDate: -1 }) as any }, 'outer'), { code: 'invalid' });
  const unavailable = new StoreVerificationError('verification_unavailable', { stage: 'revocation', transport_code: 'timeout' });
  await assert.rejects(verifyNotificationRecord({ ...local(), transaction: async () => { throw unavailable; } }, 'outer'), error => error === unavailable);
  const withoutInner = { ...notice, data: { environment: 'Sandbox' } };
  assert.equal((await verifyNotificationRecord({ ...local(), notification: async () => withoutInner as any }, 'outer')).transaction, null);
});

test('local and remote record verifiers use identical financial flow once, with recorder errors outside verification catches', async () => {
  for (const remote of [false, true]) {
    const calls: unknown[] = [];
    const low = local();
    const recordVerifier: StoreRecordVerifier = {
      transaction: signed => verifyTransactionRecord(low, signed), notification: signed => verifyNotificationRecord(low, signed),
    };
    const deps: StoreDeps = { ...(remote ? { recordVerifier } : { verifier: low }),
      recordTransaction: async (account, record) => { calls.push({ account, record }); return { outcome: 'recorded', credits: 400 }; },
      recordNotification: async record => { calls.push(record); return { outcome: 'recorded' }; },
    };
    const synced = await syncTransactions(deps, 'ACCOUNT', { transactions: ['signed'] });
    assert.match(synced[0].support_reference ?? '', /^[0-9a-f]{64}$/);
    assert.deepEqual(synced.map(({ support_reference: _, ...rest }) => rest), [{ transaction_id: '2001', outcome: 'recorded', credits: 400 }]);
    assert.deepEqual(await handleNotification(deps, { signedPayload: 'signed' }), { status: 200, outcome: 'recorded' });
    assert.equal(calls.length, 2);
    const recordingFailure = new StoreVerificationError('invalid');
    await assert.rejects(syncTransactions({ ...deps, recordTransaction: async () => { throw recordingFailure; } }, 'ACCOUNT', { transactions: ['signed'] }), error => error === recordingFailure);
    await assert.rejects(handleNotification({ ...deps, recordNotification: async () => { throw recordingFailure; } }, { signedPayload: 'signed' }), error => error === recordingFailure);
    assert.equal(calls.length, 2, 'no second or fake recorder callback');
  }
});

test('ambiguous or missing verifier configuration rejects before any verification or money write', async () => {
  let writes = 0;
  const common = { recordTransaction: async () => { writes++; return { outcome: 'recorded' }; }, recordNotification: async () => { writes++; return { outcome: 'recorded' }; } };
  for (const config of [{}, { verifier: local(), recordVerifier: { transaction: async () => transactionRecord(decoded as any)!, notification: async () => { throw Error(); } } }]) {
    const deps = { ...common, ...config } as unknown as StoreDeps;
    await assert.rejects(syncTransactions(deps, 'ACCOUNT', { transactions: ['signed'] }), /invalid_store_verifier_configuration/);
    await assert.rejects(handleNotification(deps, { signedPayload: 'signed' }), /invalid_store_verifier_configuration/);
  }
  assert.equal(writes, 0);
});

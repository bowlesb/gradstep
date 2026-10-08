// Test-root injection exists only in this excluded fixture, never worker.ts.
import { parentPort, workerData } from 'node:worker_threads';
import { appleVerifier, verificationError } from '../../../../supabase/functions/_shared/app-store.ts';
import { verifyNotificationRecord, verifyTransactionRecord } from '../../../../supabase/functions/_shared/store-purchases.ts';
parentPort!.once('message', async request => {
  const verifier = appleVerifier({ bundleID: 'com.sciencereader.ios', environments: ['Sandbox'], onlineChecks: true }, [Buffer.from(workerData.root)]);
  try {
    const record = request.kind === 'transaction' ? await verifyTransactionRecord(verifier, request.signed_payload)
      : await verifyNotificationRecord(verifier, request.signed_payload);
    parentPort!.postMessage({ status: 'verified', [request.kind]: record });
  } catch (error) {
    const failed = verificationError(error);
    parentPort!.postMessage({ status: 'failed', code: failed.code, diagnostic: failed.diagnostic });
  }
});

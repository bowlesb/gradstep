import { installEgressGuard } from '../../supabase/functions/_shared/egress.ts';
import { parentPort } from 'node:worker_threads';
import { sdkPatchProof } from './sdk-patch.ts';
import { appleVerifier, verificationError } from '../../supabase/functions/_shared/app-store.ts';
import { storeVerificationObservation, verifyNotificationRecord, verifyTransactionRecord } from '../../supabase/functions/_shared/store-purchases.ts';
import { parseRequest, unavailable, type VerificationDecision } from './protocol.ts';
// No request from this thread (its own realm and fetch) may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); EGRESS_ARXIV sets report or block.
installEgressGuard('store-verifier/thread');

if (!parentPort) throw new Error('worker_required');
parentPort.once('message', async input => {
  const request = parseRequest(input);
  if (!request || !sdkPatchProof().applied) { parentPort!.postMessage(unavailable()); return; }
  // No configuration or request field can select a test root, disable online
  // checks, change the bundle, accept Production, or choose another verifier.
  const verifier = appleVerifier({ bundleID: 'com.sciencereader.ios', environments: ['Sandbox'], onlineChecks: true });
  let decision: VerificationDecision;
  try {
    decision = request.kind === 'transaction'
      ? { status: 'verified', transaction: await verifyTransactionRecord(verifier, request.signed_payload) }
      : { status: 'verified', notification: await verifyNotificationRecord(verifier, request.signed_payload) };
  } catch (error) {
    const failure = verificationError(error);
    const { outcome: _outcome, ...diagnostic } = storeVerificationObservation(failure.code, failure.diagnostic);
    decision = { status: 'failed', code: failure.code, diagnostic };
  }
  parentPort!.postMessage(decision);
});

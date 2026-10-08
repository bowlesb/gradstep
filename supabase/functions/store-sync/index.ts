// The app reports its App Store transactions here (a purchase it just made,
// renewals and restores StoreKit delivers). Each is verified against Apple's
// root and recorded for the signed-in account; the app finishes a transaction
// only once its outcome is final. See docs/architecture/PURCHASES.md.
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, readBounded } from '../_shared/http.ts';
import { appleVerifier, MAX_SYNC_TRANSACTIONS, REJECTED_DATA, storeConfig, storeRecordingCode, storeRuntimeDiagnostic, storeCryptoCapabilities, syncTransactions, type StoreVerifier } from '../_shared/app-store.ts';

let verifier: StoreVerifier | null = null;
try {
  console.log(JSON.stringify({ function: 'store-sync', event: 'runtime', ...storeRuntimeDiagnostic(Deno.version.deno), ...storeCryptoCapabilities() }));
} catch { /* Observability must never prevent a purchase from being verified. */ }

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const config = storeConfig(name => Deno.env.get(name));
    if (!config) throw new PublicError(503, 'purchases_unavailable');
    const { accountID } = await userClient(request);
    const service = serviceClient();
    await rpc(service, 'worker_consume_request', { p_account_id: accountID, p_route: 'store-sync' });
    let body: unknown;
    try { body = JSON.parse(new TextDecoder().decode(await readBounded(request, MAX_SYNC_TRANSACTIONS * 64_000))); }
    catch (error) { throw error instanceof PublicError && error.status === 413 ? error : new PublicError(400, 'invalid_request'); }
    verifier ??= appleVerifier(config);
    const results = await syncTransactions({
      verifier,
      async beginVerification(account, attempt, digest) {
        const admission = await rpc<{ granted: boolean }>(service, 'worker_store_verification_begin', {
          p_account_id: account, p_attempt_id: attempt, p_submission_sha256: '\\x' + digest,
        });
        return admission.granted === true;
      },
      async finishVerification(account, attempt, outcome, diagnostic) {
        await rpc(service, 'worker_store_verification_finish', {
          p_account_id: account, p_attempt_id: attempt, p_outcome: outcome,
          p_stage: diagnostic?.stage ?? null, p_apple_status: diagnostic?.apple_status ?? null,
          p_transport_code: diagnostic?.transport_code ?? null,
        });
      },
      observeVerification(observation) { console.log(JSON.stringify({ function: 'store-sync', event: 'verification', ...observation })); },
      async recordTransaction(account, record) {
        const { data, error } = await service.rpc('worker_record_store_transaction', { p_account_id: account, p_transaction: record });
        if (error) { if (REJECTED_DATA.test(error.message)) return { outcome: 'invalid', recordingCode: storeRecordingCode(error.message) }; throw new PublicError(503, 'service_unavailable'); }
        return data;
      },
      recordNotification: () => { throw new Error('unused'); },
    }, accountID, body).catch(error => { throw error instanceof Error && error.message === 'invalid_request' ? new PublicError(400, 'invalid_request') : error; });
    console.log(JSON.stringify({ function: 'store-sync', event: 'synced', outcomes: results.map(r => r.outcome) }));
    return Response.json({ results }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

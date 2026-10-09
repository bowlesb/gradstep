// The app reports its App Store transactions here (a purchase it just made,
// renewals and restores StoreKit delivers). Each is verified against Apple's
// root and recorded for the signed-in account; the app finishes a transaction
// only once its outcome is final. See docs/architecture/PURCHASES.md.
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, readBounded } from '../_shared/http.ts';
import { MAX_SYNC_TRANSACTIONS, REJECTED_DATA, storeConfig, storeRecordingCode, syncTransactions } from '../_shared/store-purchases.ts';
import { configuredStoreGoogleIdentity } from '../_shared/store-google-auth.ts';
import { createStoreRecordTransport, privateStorePolicy, storeBoundedOperation, STORE_REQUEST_BUDGET_MS } from '../_shared/store-verifier-transport.ts';

let connection: ReturnType<typeof configuredStoreGoogleIdentity> | undefined;

Deno.serve(async request => {
  const deadline = Date.now() + STORE_REQUEST_BUDGET_MS;
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const config = storeConfig(name => Deno.env.get(name));
    if (!privateStorePolicy(config)) throw new PublicError(503, 'purchases_unavailable');
    const { accountID } = await userClient(request);
    const service = serviceClient();
    const rate = await storeBoundedOperation(signal => service.rpc('worker_consume_request', { p_account_id: accountID, p_route: 'store-sync' })
      .retry(false).abortSignal(signal), 5_000, request.signal);
    if (rate.error) throw new PublicError(rate.error.message === 'request_rate_limit' ? 429 : 503,
      rate.error.message === 'request_rate_limit' ? 'request_rate_limit' : 'service_unavailable');
    let body: unknown;
    try { body = JSON.parse(new TextDecoder().decode(await readBounded(request, MAX_SYNC_TRANSACTIONS * 64_000))); }
    catch (error) { throw error instanceof PublicError && error.status === 413 ? error : new PublicError(400, 'invalid_request'); }
    connection ??= configuredStoreGoogleIdentity(name => Deno.env.get(name));
    const recordVerifier = createStoreRecordTransport({ audience: connection.audience, channel: 'app', accountID,
      deadline, signal: request.signal }, {
      identity: connection.identity,
      async start(input, signal) {
        const { data, error } = await service.rpc('worker_start_store_verifier', input).retry(false).abortSignal(signal);
        if (error) throw new PublicError(503, 'service_unavailable');
        return data;
      },
      async finish(input, signal) {
        const { data, error } = await service.rpc('worker_finish_store_verifier', input).retry(false).abortSignal(signal);
        if (error || data !== true) throw new PublicError(503, 'service_unavailable');
        return data;
      },
      observationUnavailable() { console.warn(JSON.stringify({ function: 'store-sync', event: 'transport_observation_unavailable' })); },
    });
    const results = await syncTransactions({
      recordVerifier,
      // Durable per-account attempt records (migration 038); 033's transport admission is separate.
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
        const { data, error } = await service.rpc('worker_record_store_transaction', { p_account_id: account, p_transaction: record })
          .retry(false).abortSignal(AbortSignal.timeout(5_000));
        if (error) { if (REJECTED_DATA.test(error.message)) return { outcome: 'invalid', recordingCode: storeRecordingCode(error.message) }; throw new PublicError(503, 'service_unavailable'); }
        return data;
      },
      async zeroGrantReason(account, record) {
        const { data, error } = await service.rpc('worker_store_zero_grant_reason', {
          p_account_id: account, p_environment: record.environment, p_transaction_id: record.transaction_id,
        }).retry(false).abortSignal(AbortSignal.timeout(2_000));
        if (error || !['sandbox_monthly_cap', 'sandbox_identity_missing', 'subscription_not_eligible', 'no_credit_grant'].includes(data)) return null;
        return data as 'sandbox_monthly_cap' | 'sandbox_identity_missing' | 'subscription_not_eligible' | 'no_credit_grant';
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

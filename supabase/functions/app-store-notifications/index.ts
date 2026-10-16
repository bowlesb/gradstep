// App Store Server Notifications V2 (renewals, refunds, reversals). Apple signs
// the payload; it is verified against Apple's root before anything is
// recorded. A database failure answers 503 (Apple retries production
// notifications; sandbox ones are not retried).
import { installEgressGuard } from '../_shared/egress.ts';
import { serviceClient } from '../_shared/backend.ts';
import { PublicError, readBounded } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { handleNotification, REJECTED_DATA, storeConfig } from '../_shared/store-purchases.ts';
import { configuredStoreGoogleIdentity } from '../_shared/store-google-auth.ts';
import { createStoreRecordTransport, privateStorePolicy, STORE_REQUEST_BUDGET_MS } from '../_shared/store-verifier-transport.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('app-store-notifications');

let connection: ReturnType<typeof configuredStoreGoogleIdentity> | undefined;
const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

Deno.serve(async request => {
  const deadline = Date.now() + STORE_REQUEST_BUDGET_MS;
  try {
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const config = storeConfig(name => Deno.env.get(name));
    if (!privateStorePolicy(config)) throw new PublicError(503, 'purchases_unavailable');
    let body: unknown;
    try { body = JSON.parse(new TextDecoder().decode(await readBounded(request, 256_000))); }
    catch { throw new PublicError(400, 'invalid_request'); }
    const service = serviceClient();
    connection ??= configuredStoreGoogleIdentity(name => Deno.env.get(name));
    const recordVerifier = createStoreRecordTransport({ audience: connection.audience, channel: 'notification', accountID: null,
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
      observationUnavailable() { console.warn(JSON.stringify({ function: 'app-store-notifications', event: 'transport_observation_unavailable' })); },
    });
    const result = await handleNotification({
      recordVerifier,
      recordTransaction: () => { throw new Error('unused'); },
      async recordNotification(input) {
        const { data, error } = await service.rpc('worker_record_store_notification', { p_environment: input.environment,
          p_notification_uuid: input.notification_uuid, p_type: input.type, p_subtype: input.subtype, p_signed_at: input.signed_at,
          p_transaction: input.transaction }).retry(false).abortSignal(AbortSignal.timeout(5_000));
        // Data the database rejects is answered 200 (logged) so Apple does not retry it forever.
        if (error) { if (REJECTED_DATA.test(error.message)) return { outcome: 'invalid' }; throw new Error('database_unavailable'); }
        return data;
      },
    }, body);
    // Unauthenticated invalid submissions do not allocate durable observation rows.
    console.log(JSON.stringify({ function: 'app-store-notifications', event: 'notification', status: result.status,
      outcome: result.outcome, ...result.diagnostic }));
    return Response.json({ outcome: result.outcome }, { status: result.status, headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    if (!(error instanceof PublicError)) console.warn(JSON.stringify({ function: 'app-store-notifications', event: 'failed' }));
    return errorResponse(failure, headers);
  }
});

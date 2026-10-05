// App Store Server Notifications V2 (renewals, refunds, reversals). Apple signs
// the payload; it is verified against Apple's root before anything is
// recorded. A database failure answers 503 (Apple retries production
// notifications; sandbox ones are not retried).
import { serviceClient } from '../_shared/backend.ts';
import { PublicError, readBounded } from '../_shared/http.ts';
import { appleVerifier, handleNotification, REJECTED_DATA, storeConfig, type StoreVerifier } from '../_shared/app-store.ts';

let verifier: StoreVerifier | null = null;
const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };

Deno.serve(async request => {
  try {
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const config = storeConfig(name => Deno.env.get(name));
    if (!config) throw new PublicError(503, 'purchases_unavailable');
    let body: unknown;
    try { body = JSON.parse(new TextDecoder().decode(await readBounded(request, 256_000))); }
    catch { throw new PublicError(400, 'invalid_request'); }
    verifier ??= appleVerifier(config);
    const service = serviceClient();
    const result = await handleNotification({
      verifier,
      recordTransaction: () => { throw new Error('unused'); },
      async recordNotification(input) {
        const { data, error } = await service.rpc('worker_record_store_notification', { p_environment: input.environment,
          p_notification_uuid: input.notification_uuid, p_type: input.type, p_subtype: input.subtype, p_signed_at: input.signed_at,
          p_transaction: input.transaction });
        // Data the database rejects is answered 200 (logged) so Apple does not retry it forever.
        if (error) { if (REJECTED_DATA.test(error.message)) return { outcome: 'invalid' }; throw new Error('database_unavailable'); }
        return data;
      },
    }, body);
    console.log(JSON.stringify({ function: 'app-store-notifications', event: 'notification', status: result.status, outcome: result.outcome }));
    return Response.json({ outcome: result.outcome }, { status: result.status, headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    if (!(error instanceof PublicError)) console.warn(JSON.stringify({ function: 'app-store-notifications', event: 'failed' }));
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { boundedStorageDownload, deliverReaderMember } from '../_shared/reader-delivery.ts';

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    const service = serviceClient();
    return await deliverReaderMember(request, {
      account: async r => (await userClient(r)).accountID,
      rpc: (name, args) => rpc(service, name, args),
      download: (bucket, path, maximum) => boundedStorageDownload(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, bucket, path, maximum),
    }, headers);
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'reader_not_ready');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

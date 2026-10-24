// Interest index delivery: GET the manifest, GET ?artifact=<id> for an artifact's bytes
// (docs/architecture/INTEREST_INDEX.md §4; handler in _shared/interest-index.ts). Public, account-independent data;
// the reader must be signed in and served. Nothing about the reader is logged.
import { installEgressGuard } from '../_shared/egress.ts';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { handleInterestIndex } from '../_shared/interest-index.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('interest-index');

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = { ...cors(request), 'X-Content-Type-Options': 'nosniff', 'Access-Control-Expose-Headers': 'ETag, Retry-After' };
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    const service = serviceClient();
    return await handleInterestIndex(request, {
      account: async r => (await userClient(r)).accountID,
      rpc: async (name, parameters) => {
        const { data, error } = await service.rpc(name, parameters);
        if (error) throw new Error(error.code ? error.message : 'transport');
        return data;
      },
    }, headers);
  } catch (error) {
    return errorResponse(error instanceof PublicError ? error : new PublicError(503, 'service_unavailable'), headers);
  }
});

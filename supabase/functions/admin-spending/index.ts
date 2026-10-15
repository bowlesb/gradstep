import { installEgressGuard } from '../_shared/egress.ts';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { adminSpending } from '../_shared/admin-spending.ts';
import type { RpcClient } from '../_shared/admin-accounts.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); EGRESS_ARXIV sets report or block.
installEgressGuard('admin-spending');

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    return await adminSpending(request, {
      authenticate: async request => {
        const { user, accountID } = await userClient(request);
        return { user: user as unknown as RpcClient, accountID };
      },
      service: () => serviceClient() as unknown as RpcClient,
      log: entry => console.log(JSON.stringify(entry)),
    }, headers);
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return errorResponse(failure, headers);
  }
});

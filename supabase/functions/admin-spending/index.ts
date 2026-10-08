import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { adminSpending } from '../_shared/admin-spending.ts';
import type { RpcClient } from '../_shared/admin-accounts.ts';

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
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

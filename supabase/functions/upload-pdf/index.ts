// Device-only PDF cutover: reject ingress before reading a request body.
import { installEgressGuard } from '../_shared/egress.ts';
import { cors, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('upload-pdf');
Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = { ...cors(request), 'Access-Control-Allow-Methods': 'POST, PUT, OPTIONS', ...headers };
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (!['POST', 'PUT'].includes(request.method)) throw new PublicError(405, 'method_unavailable');
    await userClient(request);
    void request.body?.cancel().catch(() => {});
    return Response.json({ code: 'pdf_device_only' }, { status: 410, headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(401, 'unauthorized');
    return errorResponse(failure, headers);
  }
});

//039 authenticated upload control + fixed-size chunk ingress; gated by SQL policy.
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, readBounded } from '../_shared/http.ts';
import { handleUpload, handleUploadPart, uploadError, writePdfChunkOnce, type UploadDeps } from '../_shared/pdf-uploads.ts';

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  const reply = (status: number, body: unknown) => Response.json(body, { status, headers });
  try {
    headers = { ...cors(request), 'Access-Control-Allow-Methods': 'POST, PUT, OPTIONS', ...headers };
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (!['POST', 'PUT'].includes(request.method)) throw new PublicError(405, 'method_unavailable');
    const { accountID } = await userClient(request);
    const service = serviceClient();
    const deps: UploadDeps = {
      rpc: async <T>(name: string, params: Record<string, unknown>) => {
        const { data, error } = await service.rpc(name, params);
        if (error) throw new Error(/^[a-z_]{1,64}$/.test(error.message) ? error.message : 'database_error');
        return data as T;
      },
      writeOnce: (path, bytes) => writePdfChunkOnce(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, path, bytes),
    };
    if (request.method === 'PUT') return reply(200, await handleUploadPart(deps, accountID, request));
    let body: Record<string, unknown>;
    try { body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await readBounded(request, 16_384))); }
    catch (error) { if (error instanceof PublicError) throw error; throw new PublicError(400, 'invalid_request'); }
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new PublicError(400, 'invalid_request');
    return reply(200, await handleUpload(deps, accountID, body));
  } catch (error) {
    const failure = uploadError(error);
    return reply(failure.status, { code: failure.code });
  }
});

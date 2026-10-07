// PDF uploads (functions/v1/upload-pdf; migration 031; docs/architecture/PDF_UPLOADS.md).
// POST {action:'begin', upload_id, sha256, byte_count, target, title?|import_id+expected_revision?|source_id?}
//   → a signed token to upload the bytes to paper-uploads/<account>/<upload_id>.pdf (private bucket).
// POST {action:'finalize', upload_id, observed_cursor}
//   → once the object is in Storage with the declared size: the import is created or retried.
// Bytes never pass through this function; the pipeline worker verifies them before conversion.
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { handleUpload } from '../_shared/pdf-uploads.ts';
import { UPLOAD_BUCKET } from '../_shared/pipeline-runtime.ts';

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  const reply = (status: number, body: unknown) => Response.json(body, { status, headers });
  try {
    headers = { ...cors(request), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const declared = request.headers.get('content-length');
    if (declared && Number(declared) > 8192) throw new PublicError(413, 'invalid_request');
    const { accountID } = await userClient(request);
    const service = serviceClient();
    let body: Record<string, unknown>;
    try { body = await request.json(); } catch { throw new PublicError(400, 'invalid_request'); }
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new PublicError(400, 'invalid_request');
    const bucket = () => service.storage.from(UPLOAD_BUCKET);
    const result = await handleUpload({
      rpc: async <T>(name: string, params: Record<string, unknown>) => {
        const { data, error } = await service.rpc(name, params);
        if (error) throw new Error(/^[a-z_]{1,64}$/.test(error.message) ? error.message : 'database_error');
        return data as T;
      },
      signUpload: async path => {
        const { data, error } = await bucket().createSignedUploadUrl(path, { upsert: true });
        if (error || !data?.token) throw new PublicError(503, 'service_unavailable');
        return data.token;
      },
      objectSize: async path => {
        const slash = path.lastIndexOf('/');
        const { data, error } = await bucket().list(path.slice(0, slash), { search: path.slice(slash + 1), limit: 2 });
        if (error) throw new PublicError(503, 'service_unavailable');
        const object = (data ?? []).find(entry => entry.name === path.slice(slash + 1) && entry.id !== null);
        const size = (object?.metadata as { size?: unknown } | undefined)?.size;
        return typeof size === 'number' ? size : null;
      },
    }, accountID, body);
    console.log(JSON.stringify({ function: 'upload-pdf', event: body.action, state: (result as { state?: unknown }).state ?? null }));
    return reply(200, result);
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return reply(failure.status, { code: failure.code });
  }
});

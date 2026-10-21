// Encrypted note images: PUT and GET /note-assets/{blobID} (docs/architecture/NOTES_AND_SNIPPETS.md "Implementation
// contract", migration 095). The handler is _shared/note-assets.ts; this file wires authentication, the database and
// the private `note-assets` bucket with the service key. Nothing about a note is logged.
import { installEgressGuard } from '../_shared/egress.ts';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { boundedStorageDownload } from '../_shared/reader-delivery.ts';
import { handleNoteAsset, NOTE_ASSET_BUCKET, noteAssetHeaders } from '../_shared/note-assets.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('note-assets');

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = noteAssetHeaders(cors(request));
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    const service = serviceClient();
    return await handleNoteAsset(request, {
      account: async r => (await userClient(r)).accountID,
      rpc: async (name, parameters) => {
        const { data, error } = await service.rpc(name, parameters);
        // A database refusal carries its exception as the message; a transport failure stays generic.
        if (error) throw new Error(error.code ? error.message : 'transport');
        return data;
      },
      upload: async (path, bytes, upsert) => {
        const { error } = await service.storage.from(NOTE_ASSET_BUCKET).upload(path, bytes,
          { contentType: 'application/octet-stream', upsert, cacheControl: '0' });
        if (error) throw new Error('storage_upload_failed');
      },
      download: (path, maximum) => boundedStorageDownload(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
        NOTE_ASSET_BUCKET, path, maximum),
      log: entry => console.log(JSON.stringify(entry)),
    }, headers);
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return errorResponse(failure, headers);
  }
});

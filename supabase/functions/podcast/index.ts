// Paper podcasts: catalog, episode details, quote/start/status/cancel and audio
// grants (docs/architecture/PAPER_PODCASTS.md "Client API"). Dark until the
// operator enables podcast_policy; disabled capabilities return empty/unavailable.
import type { SupabaseClient } from '@supabase/supabase-js';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { handlePodcast, podcastError } from '../_shared/podcast-api.ts';
import { boundedStorageDownload } from '../_shared/reader-delivery.ts';

async function call<T>(client: SupabaseClient, name: string, params: Record<string, unknown>): Promise<T> {
  const { data, error } = await client.rpc(name, params);
  if (error) throw podcastError(error.message);
  return data as T;
}

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    const service = serviceClient();
    return await handlePodcast(request, {
      user: async r => {
        const { user, accountID } = await userClient(r);
        return { accountID, rpc: (name, params) => call(user, name, params) };
      },
      service: (name, params) => call(service, name, params),
      download: (bucket, path, maximum) => boundedStorageDownload(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, bucket, path, maximum),
      upload: async (bucket, path, bytes, mediaType) => {
        const { error } = await service.storage.from(bucket).upload(path, bytes, { contentType: mediaType, upsert: true });
        if (error) throw new PublicError(503, 'service_unavailable');
      },
      origin: Deno.env.get('SUPABASE_URL')!,
      randomHex: bytes => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), b => b.toString(16).padStart(2, '0')).join(''),
    }, headers);
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

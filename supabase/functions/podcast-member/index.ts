// Single-use, account-bound podcast audio delivery (see _shared/podcast-delivery.ts).
import { installEgressGuard } from '../_shared/egress.ts';
import type { SupabaseClient } from '@supabase/supabase-js';
import { cors, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { podcastError } from '../_shared/podcast-api.ts';
import { deliverPodcastMember } from '../_shared/podcast-delivery.ts';
import { boundedStorageDownload } from '../_shared/reader-delivery.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); EGRESS_ARXIV sets report or block.
installEgressGuard('podcast-member');

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
    return await deliverPodcastMember(request, {
      account: async r => (await userClient(r)).accountID,
      rpc: (name, args) => call(service, name, args),
      download: (bucket, path, maximum, observed) => boundedStorageDownload(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
        bucket, path, maximum, fetch, observed),
    }, headers);
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

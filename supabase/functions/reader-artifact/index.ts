// Authorizes a customer's offline reader download and returns short-lived
// bounded single-use member URLs (or explicitly legacy signed URLs) plus the
// trusted manifest digest. The app verifies every byte before installation.
import { installEgressGuard } from '../_shared/egress.ts';
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256, uuid } from '../_shared/http.ts';
import { errorResponse } from '../_shared/retry-after.ts';
import { boundedStorageDownload } from '../_shared/reader-delivery.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('reader-artifact');

type Descriptor = { item_id: string; document_id: string; artifact_id: string; renderer_version: string; bucket: string;
  manifest_path: string; manifest_sha256: string; manifest_bytes: number; transport: 'legacy' | 'bounded-v1';
  members?: { id: string; path: string; sha256: string; bytes: number }[] };
type Manifest = { members: { path: string; sha256: string; bytes: number; role: string; media_type: string }[] };

function base64(bytes: Uint8Array): string {
  let binary = ''; for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'GET') throw new PublicError(405, 'method_unavailable');
    const { accountID } = await userClient(request);
    const query = new URL(request.url).searchParams;
    const itemID = uuid(query.get('item_id'));
    const transport = query.get('transport') ?? 'legacy';
    if (!['legacy', 'bounded-v1'].includes(transport)) throw new PublicError(400, 'invalid_reader_transport');
    const service = serviceClient();
    const token = Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('');
    const descriptor = await rpc<Descriptor>(service, 'worker_reader_delivery_create', { p_account_id: accountID, p_item_id: itemID,
      p_token_sha256: '\\x' + await sha256(new TextEncoder().encode(token)), p_transport: transport });
    const prefix = descriptor.manifest_path.replace(/manifest\.json$/, '');
    const manifestBytes = await boundedStorageDownload(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      descriptor.bucket, descriptor.manifest_path, descriptor.manifest_bytes);
    if (manifestBytes.length !== descriptor.manifest_bytes) throw new PublicError(503, 'reader_not_ready');
    if (await sha256(manifestBytes) !== descriptor.manifest_sha256) throw new PublicError(503, 'reader_integrity_failed');
    const manifest = JSON.parse(new TextDecoder().decode(manifestBytes)) as Manifest;
    if (!Array.isArray(manifest.members) || manifest.members.length > 512) throw new PublicError(503, 'reader_integrity_failed');
    const paths = manifest.members.map(m => {
      if (typeof m.path !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._/-]{0,239}$/.test(m.path) || m.path.includes('..')) throw new PublicError(503, 'reader_integrity_failed');
      return prefix + m.path;
    });
    let urls: Map<string, string>;
    if (descriptor.transport === 'bounded-v1') {
      if (!Array.isArray(descriptor.members) || descriptor.members.length !== manifest.members.length) throw new PublicError(503, 'reader_integrity_failed');
      const inventory = new Map(descriptor.members.map(m => [m.path, m]));
      if (inventory.size !== manifest.members.length || manifest.members.some(m => {
        const stored = inventory.get(m.path); return !stored || stored.bytes !== m.bytes || stored.sha256 !== m.sha256;
      })) throw new PublicError(503, 'reader_integrity_failed');
      const origin = Deno.env.get('SUPABASE_URL')!.replace(/\/$/, '');
      urls = new Map(manifest.members.map((m, i) => [paths[i], `${origin}/functions/v1/reader-member?grant=${token}&member=${inventory.get(m.path)!.id}`]));
    } else {
      const signed = paths.length ? await service.storage.from(descriptor.bucket).createSignedUrls(paths, 900) : { data: [], error: null };
      if (signed.error || !signed.data || signed.data.length !== paths.length) throw new PublicError(503, 'reader_not_ready');
      urls = new Map(signed.data.map(s => {
        if (typeof s.path !== 'string' || typeof s.signedUrl !== 'string') throw new PublicError(503, 'reader_not_ready');
        return [s.path, s.signedUrl];
      }));
    }
    const body = JSON.stringify({
      item_id: descriptor.item_id, document_id: descriptor.document_id, artifact_id: descriptor.artifact_id,
      transport: descriptor.transport,
      renderer_version: descriptor.renderer_version, manifest_sha256: descriptor.manifest_sha256, manifest: base64(manifestBytes),
      members: manifest.members.map((m, i) => ({ path: m.path, sha256: m.sha256, bytes: m.bytes, url: urls.get(paths[i]) })),
    });
    if (new TextEncoder().encode(body).length > 1_048_576) throw new PublicError(503, 'reader_integrity_failed');
    return new Response(body, { headers: { ...headers, 'Content-Type': 'application/json' } });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return errorResponse(failure, headers);
  }
});

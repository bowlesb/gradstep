// Authorizes a customer's offline reader download and returns short-lived
// signed URLs for each bundle member plus the trusted manifest digest. The app
// verifies every byte against that digest before installing.
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, sha256, uuid } from '../_shared/http.ts';

type Descriptor = { item_id: string; document_id: string; artifact_id: string; renderer_version: string; bucket: string;
  manifest_path: string; manifest_sha256: string; manifest_bytes: number };
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
    const itemID = uuid(new URL(request.url).searchParams.get('item_id'));
    const service = serviceClient();
    const descriptor = await rpc<Descriptor>(service, 'worker_reader_descriptor', { p_account_id: accountID, p_item_id: itemID });
    const prefix = descriptor.manifest_path.replace(/manifest\.json$/, '');
    const { data, error } = await service.storage.from(descriptor.bucket).download(descriptor.manifest_path);
    if (error || !data || data.size !== descriptor.manifest_bytes) throw new PublicError(503, 'reader_not_ready');
    const manifestBytes = new Uint8Array(await data.arrayBuffer());
    if (await sha256(manifestBytes) !== descriptor.manifest_sha256) throw new PublicError(503, 'reader_integrity_failed');
    const manifest = JSON.parse(new TextDecoder().decode(manifestBytes)) as Manifest;
    if (!Array.isArray(manifest.members) || manifest.members.length > 512) throw new PublicError(503, 'reader_integrity_failed');
    const paths = manifest.members.map(m => {
      if (typeof m.path !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._/-]{0,239}$/.test(m.path) || m.path.includes('..')) throw new PublicError(503, 'reader_integrity_failed');
      return prefix + m.path;
    });
    const signed = paths.length ? await service.storage.from(descriptor.bucket).createSignedUrls(paths, 900) : { data: [], error: null };
    if (signed.error || !signed.data || signed.data.length !== paths.length) throw new PublicError(503, 'reader_not_ready');
    const urls = new Map(signed.data.map(s => [s.path, s.signedUrl]));
    return Response.json({
      item_id: descriptor.item_id, document_id: descriptor.document_id, artifact_id: descriptor.artifact_id,
      renderer_version: descriptor.renderer_version, manifest_sha256: descriptor.manifest_sha256, manifest: base64(manifestBytes),
      members: manifest.members.map((m, i) => ({ path: m.path, sha256: m.sha256, bytes: m.bytes, url: urls.get(paths[i]) })),
    }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

import { installEgressGuard } from '../_shared/egress.ts';
import { cors, rpc, serviceClient, userClient } from '../_shared/backend.ts';
import { PublicError, readBounded, sha256, uuid } from '../_shared/http.ts';
import { inspectImage } from '../_shared/images.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); EGRESS_ARXIV sets report or block.
installEgressGuard('support-assets');

type ObjectDescriptor = { id: string; object_id: string; bucket: string; path: string; state: string; byte_count: number; media_type: string; sha256: string };

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (!['GET', 'POST'].includes(request.method)) throw new PublicError(405, 'method_unavailable');
    const { user, accountID } = await userClient(request);
    const service = serviceClient();
    await rpc(service, 'worker_consume_request', { p_account_id: accountID, p_route: request.method === 'POST' ? 'support-upload' : 'support-download' });
    const url = new URL(request.url);
    const id = uuid(url.searchParams.get('attachment_id'));
    if (request.method === 'GET') {
      const object = await rpc<ObjectDescriptor>(user, 'v1_report_attachment', { p_id: id });
      const { data, error } = await service.storage.from(object.bucket).download(object.path);
      if (error || !data || data.size !== object.byte_count) throw new PublicError(503, 'attachment_not_ready');
      const bytes = new Uint8Array(await data.arrayBuffer());
      if ('\\x' + await sha256(bytes) !== object.sha256) throw new PublicError(503, 'attachment_integrity_failed');
      return new Response(bytes, { headers: { ...headers, 'Content-Type': object.media_type, 'Content-Length': String(bytes.length), 'Content-Disposition': `inline; filename="screenshot-${id}.${object.media_type === 'image/png' ? 'png' : 'jpg'}"` } });
    }
    const reportID = uuid(url.searchParams.get('report_id'));
    // Verify ownership before accepting the body or reserving any storage.
    const thread = await rpc<{ report: { account_id: string } }>(user, 'v1_report_thread', { p_report_id: reportID });
    if (thread.report.account_id !== accountID) throw new PublicError(403, 'report_unavailable');
    const bytes = await readBounded(request, 5 * 1024 * 1024);
    const image = inspectImage(bytes); const digest = await sha256(bytes);
    const object = await rpc<ObjectDescriptor>(service, 'worker_reserve_attachment', {
      p_account_id: accountID, p_report_id: reportID, p_id: id,
      p_sha256: '\\x' + digest, p_byte_count: bytes.length, p_media_type: image.mediaType,
    });
    if (object.state === 'verified') return Response.json({ id }, { headers });
    // A failed/ambiguous upload may have succeeded. Never overwrite; verify the
    // exact bytes that exist before linking them. No source or error-body logs.
    await service.storage.from(object.bucket).upload(object.path, bytes, { contentType: image.mediaType, upsert: false, cacheControl: '0' });
    const { data: stored, error } = await service.storage.from(object.bucket).download(object.path);
    if (error || !stored || stored.size !== bytes.length || await sha256(new Uint8Array(await stored.arrayBuffer())) !== digest) throw new PublicError(503, 'attachment_not_ready');
    await rpc(service, 'worker_publish_attachment', { p_account_id: accountID, p_id: id, p_verified_sha256: '\\x' + digest, p_verified_bytes: bytes.length });
    return Response.json({ id }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

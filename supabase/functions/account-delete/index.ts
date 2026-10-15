// Deletes the caller's account (owner decision 2026-10-05): personal content,
// private files and the login are removed; credit, usage and operation records
// stay under the closed account's ID (see migration 017).
//
// The first database step closes the account. A repeat call (for example after
// a lost response) authenticates with the login alone and resumes; anything
// still incomplete is finished by the paper worker's sweep.
import { installEgressGuard } from '../_shared/egress.ts';
import { authenticatedUserID, cors, serviceClient } from '../_shared/backend.ts';
import { PublicError } from '../_shared/http.ts';
import { closePodcastWork, completeAccountDeletion, DELETION_CONFIRMATION } from '../_shared/account-deletion.ts';
// No request from this function may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); EGRESS_ARXIV sets report or block.
installEgressGuard('account-delete');

Deno.serve(async request => {
  let headers: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  try {
    headers = cors(request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
    if (request.method !== 'POST') throw new PublicError(405, 'method_unavailable');
    const accountID = await authenticatedUserID(request);
    const text = await request.text();
    let body: unknown = null;
    try { body = text.length <= 1024 ? JSON.parse(text) : null; } catch { body = null; }
    if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).length !== 1
      || (body as { confirm?: unknown }).confirm !== DELETION_CONFIRMATION) throw new PublicError(400, 'confirmation_required');
    const service = serviceClient();
    const status = await service.rpc('worker_account_deletion_status', { p_account_id: accountID });
    if (status.error) throw new PublicError(503, 'service_unavailable');
    if (typeof status.data?.closed !== 'boolean') throw new PublicError(403, 'account_unavailable');
    // Podcast work first, in its own committed step (migration 048): queued jobs are
    // canceled and running ones asked to stop, so a retry after account_busy succeeds.
    await closePodcastWork(service, accountID);
    // Open accounts start here; a closed one (earlier request) resumes.
    const begun = await service.rpc('worker_delete_account_begin', { p_account_id: accountID });
    if (begun.error) {
      if (begun.error.message.includes('account_busy')) throw new PublicError(409, 'account_busy');
      throw new PublicError(503, 'service_unavailable');
    }
    const outcome = await completeAccountDeletion(service, accountID, begun.data);
    if (!outcome.complete) {
      console.warn(JSON.stringify({ function: 'account-delete', event: 'account_deletion_incomplete', account_id: accountID, step: outcome.step }));
      // The account is closed and its personal rows are gone; the worker's
      // sweep finishes the remaining step. The app treats this as deleted.
      return Response.json({ deleted: true, complete: false }, { headers });
    }
    return Response.json({ deleted: true, complete: true }, { headers });
  } catch (error) {
    const failure = error instanceof PublicError ? error : new PublicError(503, 'service_unavailable');
    return Response.json({ code: failure.code }, { status: failure.status, headers });
  }
});

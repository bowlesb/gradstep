# Reader CDN cutover candidate

Status: local review only. Pending migration `202610080045_reader_issuer_fence.sql.pending`
is not deployed; assign its final number at promotion. No hosted policy, stored object,
credential or cache was changed for this review. Build 20 supports bounded transport;
build 21's clearer quota errors are not part of that already-shipped evidence.

## Issuer boundary

Migration 035's `worker_reader_delivery_create` locks the delivery policy and refuses
legacy transport in `bounded` mode. The older `worker_reader_descriptor` still has a
service-role grant and bypasses that policy. The candidate removes only that grant
(also explicitly denying PUBLIC, anon and authenticated). Both functions must have
the same owner and be SECURITY DEFINER. The current entry point retains the owner's
internal execute privilege; the old service caller loses direct access.

Local `python3 tests/database/reader_issuer_fence.py` passes actual role calls,
single-use redemption, a two-session policy-switch race and changed-owner/definer
refusal. Objects, function bodies, inventory enforcement, policies and financial
counters stay unchanged by the migration. `--baseline` fails at the expected old-RPC
permission assertion. The ACL does not revoke descriptors already returned to Edge.

## Ordered hosted procedure

1. **Preflight.** Record deployment source hashes, the two RPC owners/ACLs, private
   bucket/RLS policy, delivery counters and remaining headroom. Confirm the only reader
   URL issuer is the current hosted Edge function; service operators must stop minting
   reader URLs. Take the normal encrypted database backup. Do not change inventory
   enforcement or quotas. Update the workflow helper's caller before relying on it.
2. **Short dual-mode canary.** Use a disposable zero-credit account and an already
   verified shared paper: abort if it would require acquisition/OCR. Explicitly switch
   delivery to `dual` with asset enforcement still true. Request `bounded-v1`, require
   that actual transport, verify the manifest/member hashes and browser rendering.
   Test one member's replay/concurrent duplicate refusal without another Storage read.
   Keep a predeclared byte/request budget; one descriptor alone charges 1 MiB. This
   avoids paid AI/OCR, not Storage/invocation overhead. Separately obtain two ordinary
   legacy descriptors and warm the smallest member URL from each; ensure distinct
   tokens and record actual cache-hit evidence without retaining bearer URLs in logs.
3. **Fence.** Promote/apply the reviewed ACL migration and set delivery `bounded`,
   keeping enforcement true. Record database wall-clock time after the **later commit**
   as `T0`. Prove service-role direct legacy RPC denial, authenticated legacy descriptor
   HTTP 426, and fresh bounded success. Record the legacy counter/time; it must stop
   advancing. A deployment rollback must not restore an old issuing path.
4. **Drain then expire.** Earliest retirement point is `T0 + 400s + 900s`, with a
   clock margin. The first interval covers pre-fence hosted Edge execution; the second
   covers its last possible signed token. `legacy_last_issued_at` is an admission
   timestamp **before signing**, so its value alone cannot shorten that horizon.
   The 400s assumption must be rechecked if any issuer runs outside hosted Edge.
5. **Purge the complete reader scope.** After that horizon, enumerate every historical
   `paper-assets/reader/…` path from immutable inventory plus the complete physical
   namespace, including superseded bundles, not just current library entries. Resolve
   discrepancies before claiming completeness. Purge exact objects with the SDK's
   `purgeCache(path)` / `DELETE /storage/v1/cdn/paper-assets/{path}`; no wildcard,
   `transformations:true`, object update/delete, or key rotation. Bound concurrency,
   honor 429/Retry-After, record per-path hashes/results, and stop on unresolved errors.
   Wait at least 60s after the last successful purge, plus a margin.
6. **Prove retirement.** GET the exact previously warmed, now-expired URLs with a
   fresh HTTP client, no added query/cache-buster, and no browser cache. Require a
   denial from each previously observed cache path, then obtain a fresh bounded grant
   and verify bytes/rendering again. Save deployment/policy/ACL timestamps, token
   expiry times and URL hashes, purge coverage, statuses/cache headers, conservative
   charges and observed bytes. A canary that never produced a cache hit does not
   prove retirement of warmed entries. Keep the gap open if any expired URL serves.

## Limits and rollback

- Object purge is documented across CDN edges, but the docs do not separately spell
  out every signed-token variant. Test distinct tokens for one object and existing
  observed regions; that is evidence for the provider contract, not an exhaustive
  observation of all global caches. Browser/offline copies remain and incur no new
  server transfer merely by being read. [Purge API](https://supabase.com/docs/guides/storage/cdn/purge-cdn-cache),
  [signed cache behavior](https://supabase.com/docs/guides/storage/cdn/smart-cdn).
- Supabase documents hosted Edge GET `text/html` becoming `text/plain`. Permit this
  exact transport downgrade in the workflow helper for a trusted HTML manifest member
  while still enforcing origin, exact size, hash, no-store and all other headers.
  Do not change manifest MIME or renderer rules, or allow arbitrary MIME mismatches.
  Capture actual hosted headers in the canary. [Routing](https://supabase.com/docs/guides/functions/http-methods),
  [400-second paid runtime limit](https://supabase.com/docs/guides/functions/limits).
- Mathpix originals are separate: PDFs above 8 MiB get a **3,600-second** signed URL
  from the pipeline, potentially running in Cloud Run. Their `originals/…` or
  `private/{owner}/originals/…` paths are outside this reader purge. Raw OCR files,
  private-content, support and uploads are also outside it. A whole-bucket purge
  would broaden impact and may break expired cached Mathpix fetches; do not substitute
  it silently. This cutover does not cap their replay, all Edge requests, or invoices.
- Current configured reader/backend allowances are separately 256 MiB/account and
  2 GiB/environment per UTC month. Reader admission includes the 1 MiB descriptor
  ceiling plus reserved member bytes; abandoned grants reserve until expiry, and
  consumed/failed transfers stay charged. Backend allowance is also used by chat
  context and upload reads. Preserve all counters across cutover and rollback.
- A rollback to `dual` using the **current** issuer leaves the old RPC fenced but
  reopens signed URL replay. Mark that exposure and restart the whole retirement
  sequence. Regranting the old RPC permits bypass even with mode `bounded` and requires
  a separately reviewed code rollback. Older clients must update for fresh downloads;
  compatible build 20 and installed offline bundles do not require object changes.

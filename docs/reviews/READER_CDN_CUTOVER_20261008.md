# Reader CDN cutover

Status at 09:03 UTC: **045 is applied and delivery is bounded-only; final CDN retirement proof is pending.**
The reviewed, unchanged migration was promoted to `202610080045_reader_issuer_fence.sql` and applied at
09:02:06 UTC after encrypted backup `20261008T080554Z-b827400c4a00`. SHA-256:
`abf05fa9505cbf8fc7e395698f093939d04afd805e46e91f7088e2150e001d7e`. A guarded policy change retained
enforcement and all allowances/counters. Hosted service-role old-RPC denial, legacy HTTP 426 and a two-request
first-redemption race passed: exactly one download, one consumed refusal, one 2,259-byte charge.
T0 is **09:03:24.331444 UTC**; no complete-scope purge is allowed before **09:25:34.331 UTC**.
The live canary holds the two previously observed HIT URLs only in memory. The corrected capability probe
observed exact-byte REVALIDATED responses for both after the explicit purge; that is not final retirement.
Build **21** is available in internal iOS/Mac TestFlight and carries clearer quota/interruption errors.
Earlier diagnostic failures and cumulative usage remain documented below; no stored object was changed.

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

`python3 scripts/test-database.py --reader-issuer-fence-candidate` applies pending
045 only to disposable local fixtures and runs the full database suites plus this
focused review. Without the flag, pending files remain excluded. After promotion to
`.sql`, the normal runner automatically includes the focused review. The standalone
loader accepts exactly one pending/promoted file, tests an already-applied ACL when
present, and its `--baseline` always loads only pre-045 migrations. Pipeline delivery
fixtures use the supported guarded issuer; customer denial of the old RPC remains.

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
   **Before fencing**, explicitly purge only that tiny canary object, require the
   documented API success, wait 75 seconds, then require valid URLs to return the
   same bytes and observe HIT or REVALIDATED for both tokens, recording which occurred.
   Initial warming still requires an actual HIT for each token. This separate capability
   step is never part of general canary startup and does not prove expired-token denial.
   If unsupported, stop before fencing.
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
   Historical paths whose objects are now deleted remain in the plan. Supabase's
   published purge contract does not establish that a 404 means an absent object's
   old cache variants were invalidated. Record its path hash as unresolved and stop;
   do not remove it from coverage, recreate it, or silently widen to a whole bucket.
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

## Canary runner

`scripts/reader-cutover-canary.mjs` starts with one small proof and then pauses.
The operator must already have set **dual**, with inventory enforcement still true.
No command in this runner writes a policy, applies a migration, changes a quota,
grants credits or calls an AI/OCR provider. It authenticates two disposable real
accounts through password login without sending email; customer sign-in UI is not
tested. Its account IDs are recorded for cleanup, and every exit attempts the real
self-delete endpoint. A hard kill can leave a synthetic ID for operator cleanup.

After reviewing the cumulative evidence below, run in a persistent interactive session
(Node 24, normal staging environment and Supabase CLI Keychain token):

```sh
GRADSTEP_READER_CANARY_PRIOR_USAGE='{"bytes":912206,"requests":88,"descriptors":5}' \
node scripts/reader-cutover-canary.mjs staging --execute
```

The explicit prior-usage value is required and must match that reviewed predecessor
report. Missing, malformed, older or larger totals refuse before credentials or hosted
requests. Another interrupted run needs its resulting totals reviewed before a rerun;
do not reuse this command to reset accounting.

Initial work checks private Storage/RLS, existing allowances, a shared verified
bundle at most 1 MiB and current completed model tags. A zero-credit account alone
does not prevent platform-paid tagging, so missing/fallback/stale tags refuse the
run. The Add uses the existing cached pipeline request slot (latest stays latest;
it never creates a new explicit revision slot). The result must identify the exact
preflight artifact. It verifies a complete bounded bundle, safe actual response
headers, replay/wrong-account/range denial and unchanged redemption counters, then
proves both synthetic accounts have zero credits, ledger entries and provider work.
Inspect `initial_proof_complete` before continuing. `abort` cleans up immediately;
it does not undo externally changed delivery policies.

Enter each command only after the previous phase succeeds:

1. `warm-legacy` — obtains two distinct ordinary signed URLs and verifies HIT for
   the same tiny member (at most 16 KiB). Tokens never leave process memory.
2. `probe-purge` — explicitly purges that one object and reports `rewarm_after`.
   At that time, enter `probe-rewarm`; both still-valid URLs must return exact bytes
   and HIT or REVALIDATED. Reports distinguish `cache_hit` from `origin_revalidated`;
   the latter is never labelled HIT. At most three requests per unchanged URL, with
   1.2 seconds between attempts. MISS/EXPIRED can precede a successful observation;
   STALE, UPDATING, BYPASS, DYNAMIC and absent/unknown cache status refuse. There are
   no new descriptor attempts, cache-busters or hidden token refreshes.
3. Apply the separately reviewed issuer ACL migration and bounded policy externally.
   Enter `fenced` to prove actual old-RPC denial, legacy HTTP 426 and fresh bounded
   delivery. Its existing tiny-member grant is requested twice concurrently: exactly
   one response must have the verified bytes, one must report consumed, and the
   account's redemption count/authorized bytes must rise by exactly one member.
   No extra descriptor is issued. The runner records T0 after those proofs and a
   **1,330-second** horizon.
4. After `retire_after`, enter `plan-purge`. It pages the union of all historical
   inventory paths and the current physical reader namespace, including deleted,
   superseded and absent historical objects. A stable count/fingerprint before and
   after pagination is required. Untracked objects, mismatched sizes and missing
   verified objects refuse. Review the path hashes/count and enter the exact printed
   `purge <plan_sha256>` command. That is the only whole-reader purge command.
5. After `verify_after` (75 seconds beyond the final purge), enter `verify-retired`.
   The exact two warmed expired URLs must now fail specifically for expired tokens;
   generic errors or missing objects do not pass. A fresh full bounded bundle, zero
   paid activity and unchanged physical/inventory fingerprint complete the proof.

`status` is available between phases. EOF, SIGINT/SIGTERM, fatal refusal or the
105-minute process deadline ends the run and attempts cleanup. Signed URLs cannot
be recovered after process loss; rerun evidence instead of claiming retirement.

Hard bounds for the next controlled run: six **new** descriptor attempts (initial
bounded, two legacy, refused legacy, post-fence bounded, final bounded), eleven
**aggregate** attempts including the five predecessors, 8 MiB cumulative response
payloads across **all** HTTP calls and 5,500 cumulative requests including cleanup.
At most 5,000 purge paths, one purge at a time and three bounded attempts only for
HTTP 429 with a finite Retry-After. One MiB/bundle and 64 KiB/manifest caps bound the
new run's conservative reader admission at 9 MiB and its manifest backend admission
at 384 KiB. Aggregate reader admission is conservatively bounded by **eleven 1 MiB
descriptor ceilings + three new 1 MiB bundle reservations + 912,206 prior payload
bytes = 15,592,270 bytes, less than 15 MiB**. Counting all prior payloads deliberately
overcounts Auth/Management/error responses while retaining earlier consumed member
bytes after account cleanup. Actual hosted consumed/reserved counters remain
authoritative and are never reset. These are not bounds on TLS/header overhead,
all backend traffic or invoices. Purge must fit the same remaining budget with
reserved final verification and cleanup headroom. No partial plan is reported
complete when a bound is reached.

Evidence is written with mode 0600 below `.artifacts/reader-cutover/<run>/`: an
append-only `events.jsonl`, then `report.json` at exit. Normal stdout excludes the
per-object successful purge stream. Member paths and signed URLs are represented
only by SHA-256; no tokens, credentials, URL query strings or server error bodies are
written. A screenshot/browser check is a separate UI task; this runner proves the
transport and accounting boundary.

### Why post-purge revalidation is valid, and what it does not prove

The prior run's report is
`.artifacts/reader-cutover/2026-10-08T08-36-01.044Z-5cd2d3ba-7fe2-44ca-b88a-d447b816ed80/report.json`.
Both 2,259-byte signed variants first produced MISS then HIT. The object purge
returned the documented success at 08:42:54 UTC; the next first-token request was
about 91 seconds later, beyond the 75-second propagation wait. It produced MISS,
then REVALIDATED twice with exact bytes/hash. The harness required HIT and aborted;
the second token's post-purge check never ran. This is partial capability evidence,
not completed retirement. No issuer fence or bounded-only policy was applied.

Supabase documents queued invalidation across edges, up to 60 seconds to propagate,
and a subsequent origin fetch that repopulates cache. It does not require that every
subsequent request report HIT. The existing 75-second wait remains; no blind longer
wait or additional purge is added. [Supabase purge contract](https://supabase.com/docs/guides/storage/cdn/purge-cdn-cache).

Cloudflare's REVALIDATED means cached content was served after synchronous origin
confirmation. Its `no-cache`/zero-freshness behavior can repeat revalidation instead
of producing HIT; absent Age is valid on that path. The observed headers do not
establish which upstream cache directive caused this run's behavior. We accept the
documented status, not an inferred configuration. [Cloudflare cache responses](https://developers.cloudflare.com/cache/concepts/cache-responses/).

An initial HIT for each exact token remains mandatory. Post-purge HIT/REVALIDATED
proves that the valid URLs still deliver those same cached or origin-confirmed
bytes after an acknowledged purge. It does **not** by itself establish invalidation
of every token/edge. Final proof is unchanged: after fencing, the full drain/expiry
horizon, a complete reader-path purge and propagation wait, the exact two warmed
expired URLs must return the specific expiry denial. Any 200, including HIT or
REVALIDATED, fails. Supabase explicitly separates signed-token expiry from cache
retirement. [Signed URL cache behavior](https://supabase.com/docs/guides/storage/cdn/smart-cdn).

### Cumulative test usage and the one-run extension

The first three local reports under `.artifacts/reader-cutover/` end at these usage
totals; the 08:36 report already carries their subtotal, so do not add it twice:

| Run start (UTC) | Additional payload bytes | Additional requests | Additional descriptor attempts |
|---|---:|---:|---:|
| 08:11:16 | 5,892 | 7 | 0 |
| 08:28:04 | 39,822 | 18 | 1 |
| 08:30:15 | 39,981 | 18 | 1 |
| 08:36:01 | 826,511 | 45 | 3 |
| **Inherited total** | **912,206** | **88** | **5** |

The latter run stopped at the cache-status assertion and cleaned up its accounts;
the URLs were held only in process memory and cannot be recovered from their hashes.
The reviewed next run therefore needs two fresh warmed variants to carry through
final expiry, plus the original bounded/replay/race checks. Its six new descriptor
attempts extend the previous aggregate test ceiling of eight to eleven. This is an
explicit verification allowance, **not** a project quota, spending-policy or counter
change. The cumulative 8 MiB payload and 5,500-request limits remain unchanged.
Earlier API/OCR costs are not inferred from these byte counters; the separate
zero-provider checks remain mandatory.

Local verification for this revision: 36/36 tests passed across
`reader-cutover-canary.test.ts`, `reader-workflow.test.ts` and
`reader-render-proof.test.ts`. New regressions distinguish initial and post-purge
cache proof, reject ambiguous/corrupt responses, retain final expiry denial, and
check exact CLI predecessor evidence plus cumulative payload/request/descriptor
ceilings and conservative prior-member accounting. These tests make no hosted calls.

### Local browser proof using those exact bytes

After complete helper verification the process retains only `renderBundle`:
manifest bytes/digest and a path-to-bytes map, at most 1 MiB plus 64 KiB manifest.
It contains no signed URL, grant or account token and is cleared during cleanup.
For the explicitly authorized public DPO canary only, initial success also writes
`verified-bundle.json` (0600, create-only) beside the report. That bounded snapshot
has only source ID, manifest digest/base64 and member path/base64 values. It never
serializes the descriptor, URL or session. Other source IDs refuse export before
account creation. Run this **local-only** command with the already installed web
dependencies; it makes no hosted descriptor/member read:

```sh
node scripts/reader-render-proof.mjs .artifacts/reader-cutover/<run>/verified-bundle.json
```

The harness builds an in-memory entry through the existing Vite reader plugin,
imports production `verifyBundle` and `frameDocument`, and passes the artifact
through Playwright. It repeats manifest/provenance/image verification and mounts
the same `sandbox="allow-scripts"` iframe and frame CSP. A fresh `127.0.0.1`
listener serves exactly `/` and `/proof.js`; browser routing denies everything
else. The parent CSP additionally has `connect-src 'none'` and `worker-src 'none'`.
No session or Supabase credentials are supplied. Browser execution has a 60-second
deadline; browser/server close in `finally`.

It checks every indexed heading/equation/figure, nonzero MathML layout, decoded
data-URI images, horizontal overflow, bridge headings and selection of real prose.
Six light/dark screenshots and finite `report.json` metrics go into a new
`render-proof/` directory next to the artifact (0700 directory, 0600 files).
That directory must not already exist. A local committed DPO sample passed with
36 headings, 270 equations/MathML nodes, four figures/images, selection in both
themes and zero browser errors; screenshots were visually reviewed. This local
sample validates the harness only. Running on a successful hosted canary artifact
proves those bounded bytes render through the current web frame; it does not prove
hosted sign-in, library navigation, native rendering or global CDN edges.

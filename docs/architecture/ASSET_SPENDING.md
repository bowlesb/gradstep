# Paper storage and delivery spending

Status: implementation in progress, 2026-10-07. This is the contract for migration 034 and the worker/client
transition. It does not describe a deployed limit. The [cost audit](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md)
identified incomplete storage accounting and replayable reader URLs (F5/F6).

## Inventory and admission

`stored_objects` remains the immutable identity of each physical object. Originals, raw MMD/ZIP/JSON,
rendered HTML/index/images/styles/provenance, and both manifests must all have rows **before** an upload starts.
Manifest membership is an immutable relation to those identities. Paper assets retain their document's shared or
owner-private scope; identical private files are never deduplicated across owners. Pending and deleting bytes count
against capacity just like verified bytes. Only confirmed deletion releases their capacity.

Before downloading an original, an atomic per-paper hold reserves the original ceiling (64 MiB), raw output ceiling
(56 MiB plus a 256 KiB manifest), and reader ceiling (32 MiB plus a 256 KiB manifest), including their object slots.
The exact policy is derived from existing upload/renderer bounds, not an increased storage allowance. The environment
remains 5 GiB / 50,000 objects and private documents remain limited to 1 GiB per owner. A global capacity lock makes
concurrent admissions observe committed objects plus all outstanding reservations. The same check precedes paid OCR
for retained originals. Exact planned objects replace their phase reservation before upload; an abandoned partial
attempt stays inventoried and counts until its deletion is confirmed.

The worker declares an exact upload plan bound to paper, claim, generation, document, phase and content identities.
The database validates the stage, owner, path, digest, size, media type and batch ceiling. Originals acquire a document
identity at planning time; source approval and reader availability still wait for successful publication. Every
physical write needs a recorded attempt before it starts. A confirmed write verifies its immutable identity;
uncertain outcomes keep the capacity liability. A stale claim cannot publish or silently release a hold. Published
objects may be reused only with exactly matching identity and scope. Rejected/failed plans remain discoverable.

Lease expiry is not evidence that Storage stopped accepting an in-flight write. Cleanup must not release capacity
for an unresolved upload. Unknown writes remain quarantined until reconciliation proves a terminal result; this is
an operational condition with an age/count, not an invisible free-space assumption. Account deletion includes these
plans and all inventory members. A truncated recursive Storage listing is an explicit incomplete deletion, never
permission to mark all files erased. Legacy prefixes remain a transition fallback, not the new inventory authority.

## Reader transfer

An authenticated descriptor can request `transport=bounded-v1`. Its member URLs address a dedicated member endpoint
on the configured Supabase origin. An opaque random token identifies a short-lived, account/item/artifact-bound
grant. Only token hashes are retained. Each member redemption commits a single-use receipt and its worst-case byte
charge under account and environment monthly counters **before** Storage is fetched. Replay, expiry, removal, account
closure, unsupported ranges and concurrent duplicate redemption cause no Storage GET. A failed or disconnected
attempt retains its conservative charge; a new attempt needs a new grant and additional headroom.

Grant creation checks the entire bundle can fit, so ordinary downloads do not begin an obviously unaffordable bundle.
The enforcing operation is actual redemption, not issuing a URL. Redemption limits cover upstream Storage bytes and
the bounded application response; provider-invoiced traffic can differ. Record authorized ceilings, observed upstream
bytes and response completion separately. Never relabel admission counters as a Supabase invoice. Response bodies and
URLs are not included in telemetry. Offline installed bundles and their hash verification are unchanged.

## Compatibility and deployment

Existing native and web builds reject member URLs outside `/storage/v1/object/sign/`. A server-only switch cannot
both preserve those downloads and enforce a replay limit. Policy therefore explicitly distinguishes `legacy`, `dual`
and `bounded` transport. New clients accept both known paths and request bounded delivery. The legacy response remains
available only during the declared transition and is counted separately as **unbounded replay exposure**. Bounded-only
mode returns an explicit upgrade-required result for a legacy descriptor request. Already installed offline bundles
continue to work. A new descriptor must never masquerade as a Storage signed URL to bypass a client's trust checks.

Deployment order:

1. Apply the additive schema and deploy dual-transport clients/endpoints with the legacy mode explicitly visible.
2. Pause/drain old worker invocations. They upload before recording and must not run alongside enforced admission.
3. Inventory every existing tracked manifest, hash-check its members, and compare a complete bucket listing against
   the database. Report missing, mismatched, unowned and unresolved objects. Do not guess private ownership.
4. Deploy the inventoried worker, verify a no-paid-call fixture journey and account deletion, then enable enforcement.
5. Release the compatible client build and deliberately switch the server to bounded-only delivery. Wait out all
   previously issued signed URLs (currently 15 minutes; the separate Mathpix original URL has its own purpose/expiry).
6. Only after those gates claim the replay gap closed. Record hosted evidence and outstanding reconciliation items.

## Investigation and verification

Operators need committed, pending, deleting and reserved bytes/object counts; account-private totals; oldest uncertain
upload; last complete bucket reconciliation and discrepancy totals; legacy descriptor issuance; bounded grant and
redemption counts; admitted byte ceilings versus observed bytes; failed/expired/replayed requests. Correlate with
paper, artifact and opaque operation IDs, not paper text, bearer URLs, prompts or secrets. Provider billing exports
remain the source of actual invoiced infrastructure cost.

Acceptance includes competing admissions at one remaining slot, stale/late writes, partial-upload crashes, exact
manifest membership, cross-owner deduplication rejection, deletion during upload, >20,000-object incomplete scans,
simultaneous token redemption, expiry/removal/closure/range rejection before Storage access, cross-month redemption,
quota races, lost-response retries, legacy-client behavior and unchanged offline installation.

## Pending PDF-upload branch (reviewed 2026-10-07)

The separate `fed8075` upload branch reserves migration 033 and introduces `paper-uploads`. Its current handler
returns a Supabase signed upload token with `upsert: true`, while its row/quota uses the caller-declared size. A caller
can therefore reserve a small declared file and upload the bucket maximum (64 MiB); finalization detects the mismatch
after the bytes were stored. Its separate upload-policy mutex also does not serialize against paper phase reservations.
This path must join the same physical inventory/capacity model before enabling it with these controls.

Reserving 64 MiB per issued token and disabling upsert would bound the eventual object at one path, but it is not a
complete delivery/erasure design. Supabase's [signed upload tokens](https://supabase.com/docs/reference/javascript/file-buckets-createsigneduploadurl)
last two hours, and those tokens also authorize [resumable uploads](https://supabase.com/docs/guides/storage/uploads/resumable-uploads),
whose upload sessions can remain valid for 24 hours. Token expiry alone is not proof that a previously started upload
has terminated. Parallel temporary uploads and deletion/recreation must not be hidden behind a one-object allowance.
The branch's current upsert mode additionally permits overwriting a staged file after its size was finalized.

Recommended transition, pending integration review: retain the upload action and progress UI, but send bytes through
an authenticated ingress endpoint that durably admits each actual upload attempt, checks the exact byte ceiling while
reading, verifies the hash, and controls its one Storage write. Do not export a Storage write credential. Benchmark the
64 MiB path against Edge memory/CPU limits before choosing Edge; the existing Cloud Run host is the fallback for a
streaming ingress handler. All temporary/chunk objects must be inventoried if chunking is chosen. Store the declared
document size separately from reserved physical capacity; shared and per-owner capacity includes staging files,
processing holds and complete bundles. Closing an account stops new admissions, then waits for issued writes to reach
a known terminal state before physical erasure and capacity release. No timer-only release or token-lifetime shortcut
is approved. The pending upload feature must remain gated until that complete transition is tested.

# Paper storage and delivery spending

Status, 2026-10-08 09:33 UTC: **035 storage accounting, 039 bounded PDF uploads and 045 issuer fencing are applied
on staging** with worker/Edge integration. Enforcement is on, scope-2 inventory certification remains
**03:09:31.700048 UTC**, discrepancies are zero and **delivery mode is `bounded`**. Both `paper-assets` and
`paper-uploads` are certified; the upload policy is enabled. After the full issuer-drain/token-expiry horizon,
all 1,046 historical/physical reader paths were cache-purged successfully, including five absent historical paths.
Two previously HIT token variants now fail for expiry; a fresh complete bounded bundle and concurrent single-use
redemption pass. Quotas and stored objects are unchanged; accrued counters are preserved. [Complete proof and observation
limits](../reviews/READER_CDN_CUTOVER_20261008.md). This closes the scoped reader URL replay gap; it does not
establish live mobile upload acceptance, bound original/Mathpix signed URLs, or cap every infrastructure invoice.

Native descriptor/epoch/queue adoption subsequently shipped in the build-17/18 lineage; 042 repairs v5 library
writes in build 19. The browser remains on its supported v3 library path and does not expose PDF upload. The
2026-10-07 design and implementation checkpoints below are retained history, not instructions to reapply or
renumber migrations. Current release evidence is in [implementation status](../IMPLEMENTATION_STATUS.md). The [cost audit](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md)
identified incomplete storage accounting and replayable reader URLs (F5/F6).

## Inventory and admission

**Migration 046 (branch `podcast-v1`, not applied):** adds the private `podcast-assets` bucket as inventory
**scope 3**. Capacity checks count podcast objects and job holds globally and per owner; inventory begin/finish
require drained podcast workers; podcast work can be enabled only after a scope-3 certification, while existing
upload gates accept scope 2 or 3. Podcast audio uses its own single-use bounded delivery with a `podcast` transfer
kind that also charges the shared reader environment counter. [Paper podcasts](PAPER_PODCASTS.md#v1-implementation-branch-podcast-v1).

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

Worker maintenance releases only future phase holds for failed, source-only or completed papers with no current
claim. It never removes planned objects, verifies an unknown write, or infers absence from a timer. Unused delivery
reservations expire; a consumed delivery remains charged. Failed writes can therefore reduce available capacity until
an operator resolves them, and that condition is visible. Retained originals and published bundles have no automatic
eviction in this release. A safe content-replica/eviction lifecycle remains a separate design before any such deletion.

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

Older installed native and web builds reject member URLs outside `/storage/v1/object/sign/`. Current native/browser
source accepts the two reviewed paths and requests `bounded-v1`; current hosted mode serves bounded
descriptors and refuses legacy requests. A server-only switch cannot
both preserve those downloads and enforce a replay limit. Policy therefore explicitly distinguishes `legacy`, `dual`
and `bounded` transport. The new-client contract accepts both known paths and requests bounded delivery. The legacy response remains
available only during the declared transition and is counted separately as **unbounded replay exposure**. Bounded-only
mode returns an explicit upgrade-required result for a legacy descriptor request. Already installed offline bundles
continue to work. A new descriptor must never masquerade as a Storage signed URL to bypass a client's trust checks.

The completed staging rollout followed this order; future rollouts must preserve it:

1. Apply the additive schema and deploy dual-transport clients/endpoints with the legacy mode explicitly visible.
2. Pause/drain old worker invocations. They upload before recording and must not run alongside enforced admission.
3. Inventory every existing tracked manifest, hash-check its members, and compare a complete bucket listing against
   the database. Report missing, mismatched, unowned and unresolved objects. Do not guess private ownership.
4. Deploy the inventoried worker, verify a no-paid-call fixture journey and account deletion, then enable enforcement.
5. Release compatible clients and complete a reviewed bounded-only cutover, including proof that old/in-flight
   descriptor issuers can no longer mint legacy URLs. Nominal 15-minute token expiry alone does **not** retire
   already-cached URLs. Establish verified CDN invalidation/cache treatment for that outstanding population;
   keep the Mathpix original URL's separate purpose/expiry distinct.
6. Record hosted proof of issuer fencing and cached-URL retirement, as well as new bounded redemption behavior,
   before claiming the replay gap closed. Until then, report the residual legacy exposure explicitly.

**CDN boundary, independently reviewed 2026-10-08:** Supabase documents that a cached signed response can remain
servable after its token expires; token expiry does not purge the cache. The pipeline currently uploads with
`cacheControl: '31536000'` (`pipeline-runtime.ts`), so no 15-minute retirement claim is justified. Observe the
actual cached path and use a reviewed invalidation/cache plan; that option is not authorization to delete paper
artifacts. Auth-key rotation does not revoke Storage signed URLs. The later reviewed cutover used exact-object
cache purges after fencing and full expiry, without object deletion or credential rotation.
[Smart CDN](https://supabase.com/docs/guides/storage/cdn/smart-cdn),
[Storage signing keys](https://supabase.com/docs/guides/storage/serving/downloads#signing-urls).

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

## Reconciliation interfaces and operator tool

The hosted rollout used `scripts/asset-inventory.py` and subsequently certified scope 2. The scoped verification
utility below remains available; its local tests and safety contract are distinct from that deployment evidence.

`scripts/reconcile-paper-assets.py` defaults to a read-only spending-status report. Its explicit `--apply` mode uses
the configured Science Reader project from `infra/account.json` and `SCIENCE_READER_SERVICE_ROLE_KEY` from the process
environment. It never enables enforcement or deletes files. Every report file is created with mode 0600 and contains
path hashes and opaque identifiers, not private paths, paper text, bearer URLs or credentials. A report must be saved
to a new filename. `--max-download-bytes` bounds content reads (default 5 GiB), including overlength probes;
`--max-metadata-bytes` separately bounds aggregate listing/RPC response bodies (default 128 MiB, including a reserved
64 KiB for finalization). Counters label content separately from metadata received before finalization. This scan
uses normal Storage transfer and is not a free provider operation; these payload bounds do not measure HTTP overhead.
The proof payload is saved beside the requested report with suffix `.proof.json` before the database is allowed to
record certification. Both the file and its containing directory are synced. A failed local write leaves the scan active. Final confirmation is a separate wrapper around
that immutable proof hash; a lost database reply does not rewrite its evidence.

The service-only RPC contract is:

- `worker_asset_inventory_begin(scan_id)` requires disabled pipeline execution, no outstanding claims (including
  expired claims), and no unresolved writes. It reserves a scan identity; normal write admission blocks during it.
- `worker_asset_inventory_page(scan_id, after, limit)` returns an ordered cursor page of nondeleted identities and
  authoritative document ownership; the limit is at most 500. No ownership is inferred from uploaded path text.
- `worker_asset_inventory_manifest(scan_id, manifest_id, members)` adds exact member identities only to an already
  verified tracked raw/reader manifest. The trusted operator first verifies that manifest's stored digest, every
  member's size/digest, and the raw manifest's document digest. Canonical MIME identity omits charset parameters.
- `worker_asset_inventory_finish(scan_id, object_count, byte_count, discrepancies, report_sha256)` stores the immutable
  proof hash and exact discrepancy counters: incomplete, mismatched, missing_verified, unowned and untracked. A failed
  scan disables certification; a successful scan records verification but does not enable admission enforcement.
- `worker_asset_enforcement(enabled, delivery_mode)` is a separate reviewed cutover. Enabling requires a completed,
  discrepancy-free scan and all global/per-owner capacity checks. Modes remain legacy, dual or bounded.

The tool requires a short final page in every folder, bounds folder fan-out/depth, object count, metadata responses
and content bytes, and rejects repeated/nonadvancing pages. It compares complete Storage listings before and after
hashing. A changed listing or changed DB identity fails the scan. Untracked files stay untracked and block success;
the tool does not adopt their claimed ownership or delete them. Unknown-write absence cannot become verification.
An interrupted active scan can be resumed with its `--scan-id`; if finalization cannot be confirmed, the saved report
explicitly says the scan may remain active. Keep workers paused until that condition is resolved.

Lock order is budget periods/accounts before papers on financial paths (`pipeline_money_lock` in migration 034),
and owner account before paper before global capacity on upload admission. Maintenance takes paper/capacity before
reader policy. Delivery takes account before reader policy. Account closure shares the account-first order and
withholds its entire physical deletion batch until all issued private writes are terminal; its later finish cannot
release bytes for an unresolved writer. Personal delivery receipts and counters are erased on closure; aggregate
environment transfer totals remain without item/account membership. Late observations cannot recreate removed rows.

Local evidence: original→OCR→raw→render→delivery→deletion SQL lifecycle, actual concurrent PostgreSQL capacity/deletion/
redemption races, quiesced scan and maintenance SQL tests, synthetic nested-listing/hash/changed-snapshot operator tests,
backend delivery/deletion fixtures, complete web unit tests and production build, Swift Core transport validation and
a Catalyst compile against a fixture backend. No hosted scan, deployment, signed-URL retirement, or production-client
cutover has been performed by this work.

## PDF-upload proposal (historical design review, 2026-10-07)

### Existing branch and migration order

The original candidate `7bab6af` renamed a never-applied upload migration from 033 to 039. Its reusable signed
upload token with `upsert: true` and caller-declared size were rejected: a one-byte reservation could admit a much
larger physical upload, and the token could overwrite bytes after finalization. The bounded chunk implementation
below replaced that path before the 039 staging rollout; do not restore the rejected transport.

Migration **033 was later assigned to the private purchase-verifier transport** and is applied. Migrations
034–038 are applied safeguards/diagnostics; **039** is the applied PDF-upload migration. Applied files are immutable.
The earlier plan to leave 033 unused is superseded; no renumbering or placeholder is required.

### Transport choice

Recommend **fixed 4 MiB chunks through an authenticated Edge endpoint, assembled and verified by the existing pipeline
worker**. This is a small application upload protocol, not a partial TUS implementation. It keeps account admission at
the only service that can authorize a physical write, while allowing an interrupted client to resend one unfinished
chunk. Each chunk has a new immutable path per physical attempt. The client receives no Storage write credential.

| Option | Useful properties | Limitation for this product | Decision |
|---|---|---|---|
| Direct Supabase TUS | Standard clients, progress, resumability; little custom transfer code | Reusable credentials can create distinct upload sessions at one path; we have not established atomic admission for every temporary upload or its terminal cleanup | Reconsider only with a demonstrated capacity/revocation contract |
| Server-created S3 multipart session with presigned parts | Standard part protocol and server-controlled completion; avoids worker concatenation | Must prove signed part size/digest enforcement, replay liability and terminal abort semantics on Supabase's supported subset | Worth a future narrow prototype; not an established simpler safety contract |
| One buffered Edge upload, at most 64 MiB | Fewest endpoints and objects; straightforward exact-byte verification | Full-file retries on poor connections; multiple buffers and hashing must fit tight Edge limits | Do not make it the only 64 MiB path |
| Authenticated 4 MiB Edge chunks + existing worker | Bounded Edge body, durable per-chunk progress, exact inventory, existing PDF verification | Additional objects/RPCs and a modest client state machine; uncertain attempts require reconciliation | Recommended, subject to measurements and independent lifecycle review |
| New public Cloud Run streaming ingress | More control over memory, CPU and request lifetime | New public authentication/abuse boundary; existing worker endpoint must remain privileged | Fallback host for the same chunk protocol if Edge measurements fail |

Supabase recommends resumable uploads for files above 6 MB or unreliable connections. TUS upload URLs can last
24 hours, distinct sessions may target the same path, and `x-upsert` makes the last completion win. Those documented
semantics do not establish a single-use application write grant or a cap on temporary bytes; this is why we cannot
treat one reserved destination object as the whole liability. [Supabase resumable uploads](https://supabase.com/docs/guides/storage/uploads/resumable-uploads)

S3 multipart is a credible alternative to revisit, but S3 compatibility alone is insufficient evidence. Supabase lists
supported/unsupported headers separately and documents automatic multipart abort after 24 hours. AWS itself warns
that in-flight parts may complete after abort, requiring repeated abort/part verification. We must establish the
exact Supabase behavior and maximum simultaneous part liability before exporting presigned part credentials; neither
an automatic expiry nor an empty ordinary object listing proves temporary parts are gone.
[Supabase S3 compatibility](https://supabase.com/docs/guides/storage/s3/compatibility),
[S3 uploads](https://supabase.com/docs/guides/storage/uploads/s3-uploads),
[AWS abort semantics](https://docs.aws.amazon.com/AmazonS3/latest/API/API_AbortMultipartUpload.html)

Hosted Edge Functions have 256 MB memory, 2 seconds of active CPU per request, a 400-second paid-plan worker lifetime,
and a 150-second request idle timeout. Four MiB leaves substantially more body-buffer headroom than 64 MiB, but safe
concurrency and SHA-256 CPU time still require measurement on the actual runtime. `waitUntil` does not remove those
limits or make assembly durable. [Edge limits](https://supabase.com/docs/guides/functions/limits),
[background tasks](https://supabase.com/docs/guides/functions/background-tasks)

A direct 64 MiB Cloud Run request is not an automatic fallback: an HTTP/1 server has a 32 MiB request limit; HTTP/2
removes that particular size limit. Keep the current worker's privileged authentication and use its existing durable
jobs for assembly. If a separate ingress service becomes necessary, use the same small-chunk contract rather than
silently enlarging a privileged worker's attack surface. [Cloud Run limits](https://docs.cloud.google.com/run/quotas)

### Durable identities and physical capacity

The proposed upload session records account, client operation ID, immutable request digest, target/source and target
revision, whole-file byte count/SHA-256, fixed chunk size, bounded part identities, expiry, state revision, and eventual
paper/import references. The part index determines its offset and exact size; the final part is the exact remainder.
At 64 MiB there are at most 16 parts. The client supplies all part digests when beginning the session, after locally
hashing the file. Same operation ID and digest returns the same session; changed size, digest, target or part list
conflicts. No client-provided path, filename, account ID or MIME type controls Storage identity.

Before accepting any body, reserve staging bytes/object slots **and** future original/raw/reader capacity under the
same `paper_storage_capacity` mutex. Sessions not yet attached to a paper need session-owned future holds; do not
create a runnable placeholder pipeline paper just to satisfy a foreign key. Capacity checks must include both buckets,
both kinds of future hold, and all pending/verified/deleting objects. Owner totals include staged uploads and private
paper assets together. The current 5 GiB environment / 1 GiB owner allowances do not increase.

For a new 64 MiB upload, the initial conservative reservation is 64 MiB staging plus the existing 152.5 MiB processing
ceiling: **216.5 MiB / 227,016,704 bytes and 534 object slots** (16 chunks plus 518 pipeline objects). This is reserved
headroom, not a claim that every paper stores that much. A smaller upload reserves its exact staging length while
retaining the existing pipeline ceiling. There is no separate uploaded manifest object: the bounded part list is
database state. Physical retry objects require additional capacity; a lost write acknowledgement never restores it.

When a session is attached to a paper, transfer its future holds into the paper's phase holds in one transaction under
the capacity lock. Existing paper holds are counted once; excess session holds can be released only as part of that
transfer. Exact object plans replace reservations rather than adding a hidden second budget. An already uploaded
file must not routinely stall because raw/reader capacity was never reserved. Capacity is checked again on every
replacement attempt and any changed processing requirement.

The implementation should extend 035's inventory/lifecycle helpers rather than keep a second quota authority in
`pdf_upload_policy`. Session limits may remain separate policy fields: the branch's 10 unfinished sessions per owner,
200 per environment and bounded expiry are additional limits, not substitutes for byte and object accounting.
Admission must also reject a closed or spending-suspended account and an active inventory scan.

### Request and recovery lifecycle

1. **Begin.** Authenticate, check rate/session limits and the exact request, reserve capacity, and return a session ID,
   revision and received-part bitmap. Store only operational identifiers and encrypted personal descriptors. No URL
   token authorizes a later unobserved Storage write. A credits precheck improves feedback; OCR still uses the normal
   later provider reservation and never relies on that precheck as a financial hold.
2. **Receive a part.** Authenticate and apply a separate chunk route/concurrency allowance before consuming the body.
   Stream-read with an exact part-length ceiling and a deadline shorter than the platform timeout, cancel immediately
   on overflow, and verify SHA-256. Do not trust `Content-Length`, accept compressed/multipart bodies, or buffer an
   unbounded request. Recheck account/session/target state after reading; an account closed during a slow request must
   not acquire a write grant. A client disconnect before any write grant creates no uncertain physical object.
3. **Authorize one physical send.** Atomically select or allocate an attempt, register its exact immutable inventory
   identity, and convert its reserved part capacity. The object path includes an opaque attempt UUID. Record a single
   write grant, then perform one `upsert: false` Storage PUT. Replayed attempt IDs return status only, never a fresh
   send authorization. SDK transport retries must not silently replay a physical PUT. Distinguish a definitive response
   from an unknown outcome; retain unknown capacity and allow only confirmation RPCs to retry freely.
4. **Resume.** Status is database-only, authenticated and bounded. It returns verified part indices, pending/uncertain
   attempts, expiry and revision, without doing a Storage GET for every poll. Lost responses prompt status recovery.
   A verified part is never uploaded again. A replacement for an uncertain part uses a new attempt ID/path and fresh
   capacity; the first attempt stays charged. Proposed initial ceiling: three physical attempts per part, including
   the first, with explicit retry/status rate and concurrency limits. Exhaustion is a visible recoverable stop, not
   an automatic new session loop.
5. **Finish receiving.** Compare-and-swap the session revision only when every declared part has one selected verified
   object. Freeze that ordered selection and a generation; reject further part starts. Attach/create the import with
   the existing stable command identity and target revision. Keep future holds on the session until the worker atomically transfers them before its first GET. Return durable processing
   state, not an assertion that the file is already verified. Repeated finish returns the same result. A late retry
   cannot resurrect an import removed after its captured membership revision.
6. **Verify and publish.** A fenced pipeline job downloads only the frozen selected chunks. Reserve known upstream
   read ceilings before those GETs, enforce actual response bounds, assemble at most 64 MiB, and verify the whole-file
   hash, PDF syntax and current page policy before publishing the original. Reuse the existing verifier and immutable
   original write protocol. Assembly belongs in the existing worker; the Edge request never waits for OCR. A duplicate
   finalize or stale worker cannot publish another original or create a second paid conversion.
7. **Clean up.** Once the original's write and publication are confirmed, close the ingress generation and physically
   delete known terminal staging objects in an exact recorded batch. Confirm removal before marking them deleted or
   releasing capacity. Failed assembly, cancellation, expiry and account deletion use the same fenced cleanup. Release
   never-issued future holds only after no new writer can receive them. Every uncertain physical attempt remains
   inventoried and charged until positive terminal evidence permits cleanup.

Use distinct receiving/checking/verified/consumed states: finishing receipt is not the data model's verified
finalization. Pin the exact supplied session and generation on the import/pipeline job; replace the branch's lookup
of the newest finalized upload for `(account, source)`. A later upload cannot silently change the bytes selected by
an active job. If a target already acquired a verified document, reject the stale replacement or create an explicitly
new private document/version through a separate command; never overwrite bytes beneath saved anchors or offline copies.

Receiving a complete chunk into memory before obtaining the write grant deliberately separates a resumable mobile
disconnect from an uncertain Storage side effect. A crash after a grant but before PUT remains conservative uncertainty.
An old attempt can finish after a replacement was selected; it then becomes a known unused object to erase, without
changing that frozen selection. Unique attempt paths and non-upsert writes prevent that old attempt from replacing
the chosen bytes. Absence in one Storage listing, an expired client session, a worker lease timeout or a cancelled
HTTP request is not proof that an issued write can never land later.

For positive reconciliation, a bounded exact-size/hash GET can establish that the one immutable object was written;
the write protocol must prove there is no second physical send still permitted at that path. A negative observation
alone cannot establish `not_written`. The production operator procedure for uncertain attempts needs independent
review alongside the protocol; until then they remain visible quarantine, with no timer-based capacity release.

### Locking, closure and inventory integration

Use account-first admission. A begin without an existing paper takes account → session → global capacity. Operations
that attach an existing target take account → the existing import/library/paper locks in their established order →
session → global capacity. All target and paper locks must be acquired before capacity; do not call a legacy import
RPC from inside a capacity-locked section if it acquires those locks later. A session-to-paper transfer may need a
private helper that separates the locked membership mutation from reservation transfer. No money lock is acquired
after capacity; normal OCR funding remains its own transaction using 034's budget/account/paper order.

Account closure acquires the same account fence before either paper or session rows. It stops new admissions and
withholds physical deletion authority while an issued owner write is unresolved. Once all relevant writes are terminal,
it returns an exact deletion generation; a later receipt cannot recreate a removed ownership row. Cancelling a session
does not wait for the entire account to close, but it follows the same no-new-grants/terminal-writes rule. Suspended
accounts may retrieve non-billable status and request cleanup; they cannot start replacement uploads or assembly reads.

Extend the reconciliation tool, begin/finish guards and admin status atomically with this feature. A clean scan must
cover `paper-assets` **and** `paper-uploads`, reject active ingress admissions/unresolved attempts, hash the same object
identities, and compare complete initial/final listings in both buckets. A prior one-bucket certificate cannot certify
the expanded scope: use an inventory-scope version and perform the required quiesced scan before enabling uploads.
Keep existing paper-assets enforcement active; the additional scope check gates the new upload capability rather
than temporarily weakening the already deployed controls.
The old token-returning endpoint must be absent or explicitly disabled; bucket policies must give clients no direct
write path. Verify the actual deployed configuration, not only the handler's code.

### Personal titles and installed clients

The initial upload branch copied the PDF/file/typed title into plaintext metadata and library projections. That
proposal conflicted with the [private display-name and filename plan](DATA_MODEL.md#import-identity-and-membership)
and was replaced before deployment by the encrypted descriptor below. Uploaded PDF content itself remains service-readable for
the authorized verification/OCR pipeline; encrypting a custom title does not make the PDF end-to-end encrypted.

The reviewed descriptor design uses an account-owned, versioned encrypted envelope containing display name and
optional original filename, using the existing device-held account keys and authenticated binding to account, stable
upload/source identity, descriptor revision and key epoch. Sync its opaque bytes through the compatible library
metadata/command protocol, with a stable mutation ID and revision conflict checks. Persist it independently of the
temporary ingress session so successful staging cleanup does not delete the library's title. Its byte length and
retained revisions must fit the existing encrypted-content quotas. The server catalog, query projection, reader
attribution and operational logs use a neutral placeholder; clients decrypt the title for display and local search.
No private title/filename is copied into a provider prompt, Storage object metadata or an unencrypted local queue file.

This is an explicit new encrypted descriptor type, requiring a cross-client fixture and compatibility review. Do not
smuggle it into an unrelated note event. The current Swift `PrivateEvent.Kind` decoder rejects new enum values; merely
emitting a new history kind would break an installed client's sync. Returning an optional opaque descriptor only to
upload-capable library clients avoids changing the old history stream, but all library read versions and source-kind
filters still need testing. Old builds continue to use their supported sources and offline bundles. Upload UI becomes
available only after an explicit server capability advertises this ingress and descriptor version; it never falls
back to a signed Storage upload token.

#### Proposed descriptor wire contract (separate review before crypto/client implementation)

Freeze the proposed format in [the synthetic cross-client vector](../../tests/fixtures/library-descriptor/v1.json).
The vector is a specification fixture produced with the existing independent Node crypto helper. Native and browser
implementations must both reproduce/decrypt it before activation; producing the vector does not establish that
cross-client verification has already passed.

- **Identity and payload:** one account/source-owned descriptor has a stable random `descriptor_id`. Its plaintext is
  UTF-8 JSON with sorted keys, no whitespace or escaped forward slashes, containing `display_name` and optional
  `filename` (absent, not null, when omitted). No other keys in format 1. The name is 1–500 Unicode scalar values and
  at most 2,000 UTF-8 bytes; a filename is 1–255 scalar values and at most 1,024 bytes. Apply the exact normalization
  below before sealing and enforce a 4,096-byte encoded plaintext ceiling. These are private
  display descriptors, never paths or a basis for globally matching a publication.
- **Key and ciphertext:** use the content key for the envelope's epoch, deriving a dedicated 32-byte key with
  HKDF-SHA256, salt = lowercase account UUID as UTF-8, info = UTF-8 `science-reader/library-descriptor/key/v1`.
  AES-256-GCM uses a fresh random 12-byte nonce and a 16-byte tag. Combined bytes are nonce || ciphertext || tag,
  canonical padded Base64 on the JSON wire; accepted decoded length is 28–4,124 bytes. The `sha256` field is lowercase
  hex of those combined bytes. Nonces in the fixture are test-only. Retrying a mutation reuses its exact persisted
  envelope rather than re-encrypting under that mutation ID.
- **Envelope:** `{descriptor_id, revision, mutation_id, device_id, epoch, format, ciphertext, sha256}`. UUIDs are
  canonical lowercase. Revision/epoch are integers 1–2,147,483,647; format is exactly 1. Account is taken from the
  authenticated session, and `source_id` comes from the authorized import/source, not from a path supplied by a client.
  For a new PDF it is `upload:<client-upload-UUID>`. A revised name retains descriptor/source identity and increments
  revision exactly once. No timestamp participates in conflict resolution.
- **AAD:** the exact UTF-8 text below, replacing angle-bracket values and including the final newline. Source IDs are
  already canonical, 1–128 printable ASCII bytes (U+0021–007E), preserving case and excluding whitespace. Their
  source-specific grammar remains the authorized source resolver's responsibility. This binds the encrypted value to its account, source, identity,
  revision, logical mutation, author, epoch and format.

```text
science-reader/library-descriptor/v1
<account-uuid>
<source-id>
<descriptor-uuid>
<revision-decimal>
<mutation-uuid>
<device-uuid>
<epoch-decimal>
1
```

**Text normalization is independent of locale and Unicode library version.** First reject invalid Unicode scalar
sequences, including every unpaired UTF-16 surrogate in JavaScript and invalid UTF-8 after decryption. In the display
name only, map this fixed set to U+0020, collapse runs and trim both ends: U+0009–000D, U+0020, U+0085, U+00A0,
U+1680, U+2000–200A, U+2028–2029, U+202F, U+205F, U+3000. Then reject any remaining C0/C1 control (U+0000–001F or
U+007F–009F). In the optional filename preserve the scalar sequence exactly and reject all C0/C1 controls, including
tabs/newlines; require at least one scalar outside that whitespace set. Neither field applies NFC, NFKC, case folding,
or locale transformations. Composed and combining spellings remain distinct. Readers require the decrypted payload
to be already normalized, valid and canonically encoded; they do not silently repair tampered/invalid content.
Canonical JSON emits non-ASCII scalars as UTF-8 and escapes only JSON quotes/backslashes (controls were rejected),
which also rejects escaped lone surrogates rather than accepting a parser's replacement character.

**Write authority and conflicts.** A descriptor command carries its management token, author device, expected revision
(0 for creation), and immutable envelope. Lock account → keyring → normal library/import rows → descriptor/session →
capacity; any monetary admission remains an earlier separate transaction. Verify the existing management-token
authority and nonrevoked device under the same keyring lock used by rotation. An already accepted exact mutation can
return its recorded outcome after a rotation, provided the caller still proves current authority. A new write must
use the current key epoch. A changed envelope under the same mutation ID is a conflict. A stale expected revision
returns the current descriptor reference without overwriting it; the client fetches/decrypts that revision and either
accepts it or explicitly creates a new mutation for its edit. The server never merges encrypted title text.

Command caller and envelope author are separate fields. `caller_device_id` must name a currently approved, nonrevoked
device and the command must prove the **current** management token under the keyring lock. For a new mutation,
`envelope.device_id` must equal that caller and its epoch must be current. For an exact already-accepted mutation, a
different surviving or newly recovered/approved device may query/replay the recorded result using current authority,
even if the original envelope author has since been revoked. Replay compares the complete stored request digest and
cannot insert, reseal or change a revision. An old token alone is never sufficient. A revoked original author cannot
create a new write or replay using its revoked caller identity. This permits recovery of lost acknowledgements
without attributing a new mutation to a device that no longer has write authority.

Retain the current envelope plus bounded idempotency receipts containing digest/revision/result, not all historical
plaintext or ciphertext versions. Use the library command retention contract for receipts; an expired receipt must
not let an old expected revision overwrite a newer value. Count current descriptor ciphertext in the same encrypted
storage allowance, with transactional account/environment projections. Do not call it a history `event_count`.
Descriptor changes advance the account's library change sequence and invalidate its query generation; references on
the import and resolved item update in one grouped change. Deletion removes descriptor envelopes, receipts and
personal projections; only unrelated de-identified financial records remain. Session cleanup retains the descriptor.

**Read and cache compatibility.** Immutable public metadata UUIDs keep their meaning. A mutable custom title must not
be inserted into `catalog_metadata` or returned as different plaintext under the same cached metadata UUID. Compact
entry state carries a descriptor reference (ID, revision, epoch, digest), with bounded owner-authorized hydration by
exact ID/revision. The hydration response has its own format, account binding and byte cap; it uses library transfer
admission. If a requested revision was superseded, return an explicit stale-reference result so the client catches up,
not replacement ciphertext disguised as that revision. Clients cache ciphertext by account/descriptor/revision,
decrypt only with the matching historical epoch key, and retain the highest observed revision for that descriptor.
A locked or unsupported key shows a neutral placeholder and must not discard ciphertext or reset its revision.
An unsupported format or corrupt descriptor likewise preserves the opaque ciphertext/reference, exposes a neutral
title with a local error state, and cannot fail the entire library sync or trigger any plaintext fallback.

The reviewed API split keeps installed v3 full reads and existing v4 compact/query/hydration signatures limited
to arXiv/web source kinds; retain the pending branch's v5 full reads for upload-capable native clients. Add v5 compact
page/changes/metadata/query facades that share v4's internal algorithms and add the explicit upload/descriptor contract.
This avoids PostgreSQL overload/default-argument ambiguity and preserves web loading performance. Use separate
capability-bound cursor identities; a cursor from a different source visibility or format restarts explicitly.
Unsupported entries must still advance a legacy delta's completed high-water mark without leaking an unknown source.
Installed full-read clients require every `has_more` page to be nonempty and its next cursor to equal the last visible
sequence. Indexed per-level journal identity seeks therefore skip hidden-only batches before `LIMIT + 1`, with
authoritative filtering of each batch's entries. A hidden-only remainder finishes at the requested high-water mark;
it does not emit an empty intermediate page. Legacy metadata hydration rejects unsupported-source IDs consistently.
Existing v4 query projection includes neutral upload rows for the new facades, but legacy queries filter them before
paging; counts, cursor fingerprints and tie breaks use the same visibility. Full v5 may return only the descriptor
reference and use the same bounded hydration. No format 1 encrypted history events change, so mixed-version devices
continue to sync chats normally. Verify these rules against installed native/web codecs before enabling uploads.

Persist a minimum source-visibility level on projected entries and tombstones before deleting their source row;
do not infer a removed upload's type from missing metadata. Baseline, delta, current query, counts and hydration all
apply that same level. Old-client deltas filter each grouped change and strip descriptor references, but complete at
the requested high-water mark when the remaining entries were all hidden. A tombstone for an upload the old client could never
see stays hidden; a tombstone for supported content is still delivered. Public-source metadata and existing cursor
formats retain their validation; the rollout bumps the dataset epoch where a rebuilt projection is required. New
facades bind cursors to the upload-capable visibility, and every mutation still advances query generation even if
the legacy visible set did not change. Thus a legacy query may restart conservatively, but never mix two generations
or leak hidden rows in counts. No source-changing reuse of an existing item identity is permitted.

**Frozen-vector acceptance:** Node reference, Swift CryptoKit and browser WebCrypto produce/open identical bytes with
the test nonce; modification of every AAD field, nonce, ciphertext or tag fails authentication. Cover Base64 aliases,
wrong digest/length, unknown format, unavailable historical key, revoked author, rotation-vs-create/rename races,
exact lost-response replay, concurrent rename CAS, account switch, descriptor deletion and v3/v4/v5 mixed libraries.
Persist encrypted local outbox data before sending and reconcile accepted mutations before resealing after rotation.

Local codec verification, 2026-10-07: Swift CryptoKit and browser WebCrypto both reproduce all three independent
frozen vectors exactly. They reject modified identities/ciphertext, Base64 aliases, invalid UTF-8, noncanonical
JSON (including duplicate keys, escape alternatives and BOM), and unavailable keys; historical reads survive key
rotation. Swift explicitly compares payload text by UTF-8 bytes rather than canonical-equivalence String equality.
Browser descriptor keys are separately derived and nonextractable, with the same account lifetime as existing
event keys. Core 223 and web131 tests pass, including existing Swift/WebCrypto interoperability, and the browser
production build passes. The native codec also received independent browser-side review. This is codec evidence
only: server authorization/races, encrypted outbox persistence, mixed-version reads and client UI remain activation
requirements. No descriptor data has been written to hosted infrastructure.

### UX, cost and operational evidence

Keep Choose PDF, device-download fallback, Share and Library progress in their current locations. The native queue
persists the account/session identity and local file, uploads at most one part at a time initially, and resumes from
the server bitmap after foregrounding or a network change. A later background `URLSession` implementation can use
bounded file-backed parts; it must preserve those identities and never retry an uncertain Storage write as a new one
without admission. The browser can resume while its file handle is available; after permission/file loss it asks for
the same file and verifies its digest before resuming. Signing out cancels sending and fences late UI completions to
the captured account. Progress distinguishes Uploading, Checking PDF and Converting; users do not see chunk internals.

One full-size upload ordinarily adds 16 Edge body requests plus begin/status/finish calls, and one PDF's worth of
staging reads for assembly. The direct-token branch already read a complete staging PDF, so chunking mainly adds
request overhead rather than another full-file read. Reconciliation and assembly retries are additional reads and
must use the same transfer admission ledger. Temporary staging is an extra physical copy until confirmed deletion;
it is not charged as an AI operation. Rate counters must separate session begin, chunk, status and finish so the old
40-begins/hour allowance is not accidentally treated as 40 chunks/hour.

Supabase's published Pro quotas include 2 million Edge invocations, 100 GB Storage and 250 GB egress, shared across
the organization rather than dedicated to this project. Beyond quota, invocations are billed in whole million-request
packages at $2, including error responses; Storage uses GB-hours (about $0.0213/GB-month), and published uncached
egress is $0.09/GB. These are billing inputs, not a promise that Science Reader or a failed request is free.
[Organization billing](https://supabase.com/docs/guides/platform/billing-on-supabase),
[invocations](https://supabase.com/docs/guides/platform/manage-your-usage/edge-function-invocations),
[Storage size](https://supabase.com/docs/guides/platform/manage-your-usage/storage-size)

For scale only, 1,000 maximum-size uploads would add 16,000 chunk invocations and about 67.1 decimal GB of staging reads
(roughly $6.04 if all those reads were uncached billable overage). Keeping all their staging bytes for a full 24 hours
would total about 1,611 GB-hours, roughly $0.047 at the published overage rate. These arithmetic examples exclude final
assets, retries, responses, worker compute and OCR, and exceed the beta's simultaneous storage allowance if retained
together. Measure actual project usage and invoice attribution; database byte reservations are not billed GB-hours.

Expose upload session counts/states, accepted/verified/uncertain/deleting bytes and objects, future holds, unknown-write
age, retry counts/reasons, capacity rejection, selected-vs-orphan parts, cleanup age, admitted vs observed assembly/read
bytes, invocation route counters and worker durations. Correlate by opaque session/attempt/paper IDs without names,
file hashes, paths or response bodies in ordinary logs. The audit detail may retain hashes in access-controlled
inventory. Link these records to 037's spend view without relabeling them provider invoices. Rejected unauthenticated
requests can still incur platform invocation cost; application admission alone does not establish a dollar-hard cap.

### Acceptance before enabling 039

- Real database races across staging and paper capacity; declaration of one byte with a larger body; exact last-part
  length/index/digest; duplicate/concurrent attempt and finalize; conflicting target revision; expired/suspended/closed
  accounts; global and owner byte/object limits including future holds and abandoned attempts.
- Network fault injection before body completion, before/after grant commit, during PUT, after Storage success but
  before receipt, during assembly/original publication, and during deletion. Prove one grant gives at most one PUT,
  lost acknowledgements do not release bytes, replacement paths remain separately charged, and late writes cannot
  invalidate an authorized deletion batch. A corrupt assembled PDF never reaches paid OCR.
- Unknown-attempt recovery with positive exact hash evidence; negative probes remain quarantined. No status poll or
  automatic reconnect loop performs unadmitted Storage reads. Bound every retry, status response and worker read.
- Extend the full-bucket reconciliation fixtures and race tests for both buckets, scope-version invalidation and
  ingress drain. Exercise closure after partial chunks, selected original, unknown retry, and lost delete response.
- Local Edge profiling with real 4 MiB hashing/Storage mocks and controlled concurrency, then a separately approved
  hosted no-provider-call smoke test. Record CPU, peak memory, slow-body behavior, end-to-end 64 MiB time and restart
  recovery; no claim that local profiling proves hosted limits. If limits fail, reuse the protocol on a reviewed
  ingress host rather than raise quotas silently.
- Native Simulator/Mac/browser interruption and resume; account switch; source/import fallback; encrypted title across
  trusted devices; locked-key placeholder; title rename conflict; older-client history/library compatibility; unchanged
  offline reading. Verify private title/filename absence from database projections, logs and unencrypted queue files.

The lead reviewed and approved this transport/reservation/recovery direction and the encrypted-descriptor contract
for local implementation. The feature remains gated; this approval does not enable hosted ingress or replace the
measurement, client compatibility and explicit rollout gates above.


### Local ingress implementation checkpoint — 2026-10-07

At this pre-deployment checkpoint, migration 039 and the upload Edge/worker code implemented receiving → frozen →
checking → consumed, with abandoned as a terminal cancellation/expiry state and a disabled migration default.
The old signed/upsert transport and plaintext title parameters were removed from server ingress. Native adoption
and hosted enablement followed; current rollout status is at the top of this document.

Freeze records the selected immutable part identities and their digest, session generation, original target
revision and observed library cursor. A separate idempotent attachment transaction uses the existing library
command lock order and publishes the exact bound import/intent reference. Session future holds remain fully
charged across a crash between those transactions. Worker download admission pins that exact session and
generation, transfers future holds to the paper under the common capacity mutex, and only then grants any
assembly GET. Admission returns that committed descriptor, so an earlier claim snapshot cannot bypass a supplied
PDF attached in between. A per-paper admitted claim/generation marker prevents attachment from changing an already
admitted physical source; finalize returns `upload_target_busy` and retains the frozen selection/holds for retry
after the attempt terminates. A source past download cannot accept an unused replacement. A stale target is rejected;
neither attachment nor the worker substitutes a newer session.

Lock order is explicit:

- Migration 039 takes its accounts-table `EXCLUSIVE` gate before any existing-relation DDL lock, then retains it
  through commit. Pausing pipeline workers does not pause customer imports. An import that already holds its account
  lock must be able to finish against the old schema before the migration takes its downstream import/paper locks;
  new account-scoped mutations wait at the gate. The populated 038→039 test observes that actual lock wait, completes
  an authenticated import, and verifies its receipt and pipeline link survive. A late gate reproduced a real deadlock.
- Begin/part write: owner account `NO KEY UPDATE` → session → capacity → inventory rows. Begin rechecks the
  feature switch under the capacity lock, so disabling it prevents a waiting admission from slipping through.
- Freeze: owner account → session; it takes neither library policy nor capacity.
- Attach: owner account → known owner-private paper → existing library policy/import order → session. It never takes
  capacity. The account lock excludes concurrent same-owner import mutations; shared metadata-paper FK locks remain
  compatible with their worker's `NO KEY UPDATE` lock.
- Worker admission/publication/rejection: owner account → known paper fence → exact session → capacity
  and the existing document/publication locks. No session-first path subsequently discovers a paper lock.
- Positive write callback: owner account (closed allowed) → session → capacity → attempt/object. It records
  terminal success after closure but cannot revive an abandoned selection. No negative/absence callback exists.
- Janitor: capture a bounded candidate set, prelock all captured owner accounts and known papers in UUID order,
  then sessions/capacity; skip changed paper bindings. Never acquire a newly discovered account or paper after
  capacity. Future-unused holds may be released, but every physical attempt remains inventoried. No deletion
  batch is issued until every physical PUT for that session has terminal positive proof. Candidate discovery excludes
  already-clean terminal receipts and unknown-only terminal sessions with no future holds, and skips live checking
  intents before the bounded `LIMIT`; neither cohort can starve independently deletable sessions. Issuing a batch
  durably paces its retry for 15 minutes, so a whole window of failing removals cannot monopolize the next sweep.
  Batch failures are isolated; confirmed successes still contribute to progress. Confirmation remains valid and
  idempotent during pacing, and issuing/failing/expiring a batch never reduces its physical byte liability.
- Account deletion: account `FOR UPDATE` → private papers → sessions → capacity → existing deletion flow.
  Closure persists while uncertain writes block physical removal. Finish retains035's paper-write fence and
  also checks ingress writes before deleting session/read/attempt references.

Positive recovery makes a separately admitted, paced GET and requires the exact part size/hash. A failed, absent
or mismatched response leaves the PUT uncertain. A single-use physical write grant plus raw nonretrying,
nonredirecting, nonupsert transport is required for a matching object to prove that the one PUT is complete.
Every assembly/recovery GET keeps its authorized byte ceiling even when its outcome is lost; observations are
reported separately. Reconciliation discovery durably paces each candidate for 15 minutes before returning it,
including when subsequent read admission is refused. Candidate failures are isolated, so one exhausted account's
allowance cannot block another's positive recovery. Late observations after account closure cannot recreate personal
transfer counters.

Rejection and unused-session retirement clear only their exact paper/session/generation pin under owner → paper →
session locks. They retain all physical objects and unknown writes. A replacement on the same import must bind a
newer wanted intent; it cannot revive the rejected selection or attach to the old intent during its failure-projection
gap. The following admitted worker transfers that replacement's holds and returns its exact descriptor.

Encrypted descriptor bytes and count share the existing encrypted-storage allowance without masquerading as history
events. `v1_sync_usage` and the admin overview expose additive `descriptor_bytes`, `descriptor_count` and
`accounted_storage_bytes`; existing `ciphertext_bytes` still means encrypted history only. New native/browser usage
displays must consume the total when they adopt descriptor capabilities. Only the current ciphertext envelope is
retained; existing bounded library-command receipts preserve digest/result replay, including a currently authorized
surviving device resolving an old author's accepted mutation after rotation.

The inventory utility negotiates one-bucket scope on035 or two-bucket scope on039. Both complete listings are
compared before/after, and all verified staging bytes are hashed against their preexisting owner-bound inventory.
An unknown staging pathname never becomes ownership authority. Only a complete scope 2 scan can enable ingress.

Validation at this checkpoint: full fresh local PostgreSQL suites through 039 plus14 real upload/descriptor/append
interleavings and replacement/cleanup progress fixtures; 280 backend tests (51 targeted worker/pipeline/ingress);
15 inventory utility tests and the upload Edge Deno type check. An independent reviewer reproduced the lifecycle,
descriptor and 14-race checkpoint; deletion retry pacing received a further focused review. These are synthetic local
receipts/fetches, not hosted Edge CPU/memory or slow-mobile-body evidence. Hosted measurements, full client
protocol/descriptor integration, capability rollout and an explicitly reviewed feature enablement remain gates.

The subsequent composed checkpoint folds the reviewed visibility implementation into 039 and includes spending
head `7cdef54`. The full fresh database suite, populated 038→039 upgrade with concurrent client import, 15 upload/descriptor/append/cleanup
interleavings, 289 backend tests, 228 Core tests, 139 browser tests and 103 operations tests pass. Browser production
build and a generic Simulator build using fixture-only API settings pass; no physical device or live provider was
used. Restore quarantine now atomically closes current pipeline, upload, tagging and provider admission as well
as legacy gates, and rotates both library epochs. Full-schema preservation tests keep all other records, counters,
leases and holds unchanged; malformed present policy tables roll back every gate change.

At that checkpoint the original native queue and optimistic `libraryReadVersion = 5` transport had not yet been
migrated. The adoption work below subsequently supplied the capability/epoch, encrypted queue/descriptor and
resume contracts; build 19 additionally fixes v5 ordinary library writes with 042. Preserve those contracts when
reviewing later clients. A feature flag alone never proves protocol adoption or real-device upload acceptance.

## Native adoption implementation design — approved locally, 2026-10-07

Historical implementation contract after `5fdd261`, subsequently adopted in native source. The paragraphs below
retain the design's imperative wording and local acceptance gates; they do not mean 039 is still unapplied.
The original scope covered Swift/Core, the Apple app and fixture-only tests, without provisioning Apple identifiers
or changing the browser. The existing
Add sheet, file picker/drop/share entry points, Library upload banners and paper navigation remain in place.

### Capability and replicated-library boundary

Use an explicit `LibraryReadContext` bound to deployment, account, endpoint family, body format, source level and
optional dataset epoch. Distinguish **v3 full** (body format 2, source level 3, no epoch) from **v5 full** (body format 2,
source level 4, required upload epoch). V4 compact has body format 4 and v5 compact has body format 5; neither may be
decoded as a full page or reuse a full continuation. This stage keeps the native full-replication path and the existing
4,000-entry ceiling. It does not silently adopt server query pagination or raise library capacity.

The initial native branch optimistically tries v5 and resends the same failed request against v3. Replace this with
account-session capability negotiation followed by a reconciler reset when the selected family changes. A v5 request
carries its immutable context; its baseline cursor preserves `read_level=4` and `dataset_epoch`, and every delta
request sends `p_dataset_epoch`. Validate context on every page before accepting any row/cursor. A capability/epoch
change invalidates pending page tickets; a late response cannot choose the next account's mode.

**Server join point for separate review:** 039 has no authenticated capability advertisement today. Add a small,
account-bound read RPC, proposed `v1_reader_capabilities()`, returning format/account plus supported full-read version,
wire format/source level, upload dataset epoch, descriptor format and ingress protocol/limits/enabled state. The
upload flag reflects policy, required inventory scope and current account admission, but remains advisory: every real
admission still checks authoritative policy. No Storage paths, credentials, management token, budget details or
provider secrets belong in this response. A disabled ingress must not hide already-synced upload papers/descriptors.
Root should own/approve this small server addition while this subtask owns its native consumer and fixtures.

Only an exact missing-RPC response for that endpoint permits a legacy v3 baseline, and only when this account/deployment
has never durably adopted v5. A transient error, unauthorized response, malformed capability, missing v5 dependency or
schema-cache inconsistency must not downgrade a v5 replica. Keep its last encrypted presentation, pause new uploads
and retry negotiation. After a server upgrades from a remembered v3 session, the next foreground/session negotiation
starts a fresh v5 baseline; it never sends an old v3 `after` or continuation to v5. A rollout reversal from already
adopted v5 to a genuinely older server is an explicit unavailable state, preserving upload rows and pending work.

### Durable cache, restore epochs and offline eligibility

Bump the sealed local presentation format for the descriptor field and read context. Persist its context, complete
cursor and row manifest in the same authenticated SQLite transaction as the rows. Existing format 1–3 snapshots stay
readable for offline presentation but require a fresh baseline; they do not acquire a fabricated epoch. Retain their
reader bundles and queued library mutations. No partial baseline/page advances the durable complete checkpoint.

A fully validated same-context v5 checkpoint can seed a new reconciler in **catching-up**, never ready: a fresh
authenticated server delta must complete before producing a `LibraryCompleteObservation`, settling a command or
authorizing a new reader download. Keep `CachedLibraryPresentation` as a presentation-only type; add a separate
validated resume seed produced by the encrypted store, with scope/context/row checks. V3 continues to baseline on
launch because its epochless protocol cannot prove continuity after a restore. A corrupt seed preserves the cache
for diagnosis and starts a bounded fresh pull; it never silently deletes pending work or reader policy.

On a changed v5 epoch, stage a fresh complete baseline plus its fixed-boundary catch-up. Only then atomically replace
the old replica, including lower cursors and absent old rows. Monotonic sequence/identity comparisons apply within
one dataset context; removing their guards globally would permit stale-state overwrite. Same-context compaction
still uses the existing bounded reset and strict identity rules. The authenticated checkpoint records the new context
with its rows, so a crash cannot pair a new epoch with the old high-water mark.

Reader-bundle eligibility needs the same context boundary; its current global cursor/item-state comparison would
reject a restored lower baseline. Preserve installed ciphertext and exact document/artifact/manifest bindings. During
transition ordinary previously readable bundles remain available offline. When the new complete observation arrives,
missing/removed items become unavailable and changed artifacts stay blocked. Carry explicit quarantine/incompatibility
and previously removed membership across domains; a lower restored revision alone cannot clear them. A previously
blocked/removed installation remains blocked: the current reader-artifact endpoint is not epoch-bound and cannot
prove current-domain authorization. A separately reviewed server proof plus current membership and exact
manifest/files/renderer compatibility will be needed for recovery; authorization alone cannot clear a locally
unsafe artifact. This first slice implements no such clearing path. Context changes do not discard sticky policy or
treat cache repair as authorization; this is an explicit transition, not a global relaxation of cursor checks.

Pending command receipts also carry their observation context. After an epoch change, an old numerical receipt floor
cannot be compared with a new cursor. Retain the encrypted intent in needs-review rather than automatically replaying
a mutating RPC whose receipt may have been lost in the restore. A fresh current-domain observation alone is not proof
of that command's outcome. The current server has no read-only receipt resolver; automatic recovery across this
boundary must wait for a separately reviewed resolver, or use the existing explicit review/retry flow with fresh
preconditions. Same-domain lost replies still replay their exact operation identity normally. Never invent a new
operation ID or silently mark an old-domain command complete.

### Descriptor hydration, journal and local title index

Add optional `descriptor_ref` to full item/import DTOs without changing `PrivateEvent.Kind`. Public metadata remains
immutable and neutral. Descriptor reference changes are mutable state changes, not new catalog identity. Apply every
grouped journal batch atomically, including import/item pairs and tombstones, and publish only complete observations.
Treat an omitted descriptor in an old-shaped command acknowledgment as **not observed**, not an instruction to clear
a cached reference. Native commands continue to use acknowledgments as observation floors, then read the canonical
journal. If the general reconciler accepts a command entry, its explicitly tagged acknowledgment merge may ignore only
that omitted additive field; all other identity/state equality checks remain strict. Two canonical observations at the
same revision with different descriptor references are still a conflict.

Use a separate bounded descriptor coordinator/store, scoped to deployment/account/source. Hydrate at most 24 exact
ID/revision references per request. Validate response format/account/source, reference identity/revision/epoch/digest
and envelope bounds before decrypting with the existing reviewed codec. A stale-reference response triggers bounded
library catch-up; it cannot replace ciphertext under the requested old cache key. Cache ciphertext/reference with
an authenticated local manifest. Unknown formats, missing historical keys or corrupt envelopes retain bounded opaque
evidence and expose a neutral `Uploaded PDF`/locked-title state; they do not fail the whole library pull, erase a title
revision, fall back to plaintext or repeat hydration on every render.

Persist descriptor writes in a dedicated encrypted outbox, not the history event stream or the existing item/import
receipt enum. Its record contains source, expected revision, exact immutable envelope, mutation ID, local intent,
phase and recorded result. Seal once and durably commit before sending; retries reuse the exact envelope. Current
management token and caller device are supplied at dispatch and are not part of the immutable request identity.
After rotation/recovery, the currently authorized surviving device can replay a historically authored envelope.
An unaccepted stale-epoch mutation is replaced only after authoritative rejection/catch-up proves its state, using a
new mutation and current keys. Revision conflicts preserve the local edit and current remote reference for review;
the server cannot merge ciphertext and the client must not silently overwrite the other device's title.

Descriptor create happens after begin has established source ownership and before freezing a new-paper session.
The applied descriptor result is checked against the persisted expected envelope/reference; a subsequent status/read
confirms the current source reference. An attached paper's rename is complete only after a fresh library observation
and exact descriptor hydration. Creating a descriptor for a not-yet-attached session has no library row yet, so it
uses its authoritative receipt plus upload status rather than waiting for a nonexistent journal member.

Use the current complete native library as the title-index population; hydrate every distinct referenced descriptor
for visible/archived items and displayed imports, not only rows on screen. Decrypt off the main actor and combine the
private display name with existing public search fields for the whole account. A descriptor/key/context generation
change invalidates in-flight searches and rebuilds title sort/search over all candidates. Never send private names or
filenames to server-title queries or provider prompts. Pending or locked titles are explicitly incomplete (`Updating
titles`/`Some titles are locked`), with deterministic placeholder ordering; do not present a partial private-title
search as a complete no-results result. An actual journey will place a matching private title beyond the first page,
rename it from another device, and verify filter/order, offline reopening and account switch.

### Durable bounded PDF queue and recovery

Replace signed token/path fields and plaintext `job.json` with a versioned encrypted job plus encrypted 4 MiB chunk
records in the existing account-scoped local SQLite store. Each record is bound by AAD to deployment/account/job/
part and is authenticated by the job manifest; the whole-file and per-part hashes are computed while adopting the
selected file. A transaction publishes the job only after every bounded chunk is durable. Use opaque IDs, preserve
the user's original file, and retain no private title/filename in local SQL columns, URLs, logs or unencrypted queue
metadata. Intake reads one chunk at a time; it must not buffer every queued PDF. Local queue limits are separate
logical queue allowances (10 jobs and 512 MiB ciphertext), never hard filesystem limits or representations of server
storage allowance. SQLite WAL, temporary intake files and filesystem overhead require additional physical space.

Extend the existing local store format transactionally with encrypted descriptor/outbox/upload manifests and tables;
all current history/draft/library/cache records survive. Unknown/corrupt rows are preserved and stop affected work,
not silently removed by the old directory loader. Legacy local upload jobs are imported once under the authenticated
account, rechecking their files and sealing their title and protocol state before deleting the old `job.json`/copy.
They receive no automatic new server identity or signed-token fallback; conflicts remain visible for review.

The share extension has no account keys and must keep that separation. It cannot persist a PDF's supplied filename or
private title in plaintext `item.json`. Use an opaque temporary PDF name and omit optional PDF title/origin strings
until main-app adoption; derive PDF metadata locally in memory and seal the descriptor then. File/drop intake carries
any suggested filename in memory into the encrypted job. Protect/exclude temporary files from backup and delete owned
temporary copies after durable adoption. Do not create new app-group identifiers or provisioning profiles. Original
external files and temporary PDF contents themselves are not claimed to be end-to-end encrypted by this descriptor.

One account-session-owned queue sends one part at a time. Persist an attempt UUID before the first PUT and send only
to this configured project's authenticated `upload-pdf` endpoint, with exact bytes/type and no redirects. Status is
database-only. After a disconnect/relaunch, query status and replay the same part/attempt identity if needed; server
single-send admission makes replay safe. Verified parts are never resent. Unknown attempts stay visible and charged;
a paced replacement uses a new persisted attempt ID and fresh server capacity, up to the declared per-part ceiling.
Exhaustion stops with a useful action; it never creates a new session automatically. Progress distinguishes verified
bytes from in-flight bytes so an uncertain response is not reported as a completed upload.

Freeze persists the exact session generation, latest verified revision, original target/import revision and observed
library cursor before the request. Lost finalize responses replay that tuple; a status of frozen/checking/consumed
resumes the same selection. `upload_target_busy` keeps the frozen session, encrypted descriptor and chunks, and retries
with paced backoff after the existing download can finish. It is neither an invalid-PDF error nor a reason to create
a fresh upload. A terminal stale target preserves a retryable local copy and offers the existing new-paper action
only as an explicit new user intent, never by silently retargeting.

Cancel is itself a durable intent. Stop new local part starts immediately, retain an exact cancellation request and
retry it after reconnection. Only a positive abandoned response permits dropping the server-cancellation record;
unknown PUT liability remains the server's ledger responsibility. If attach already won (`upload_already_attached`),
refresh the canonical import and route an explicit withdrawal through the existing import cancellation command with
its current revision. A frozen cancellation cannot resurrect an import. Sign-out stops dispatch and retires callback
ownership, but keeps encrypted unfinished work for that same account; account deletion erases local jobs/parts/titles
after the normal server deletion confirmation. A different account or a newly opened same-account session cannot
accept stale progress, erase a new job or inherit the prior caller's token.

An expired receiving session is not an automatic restart loop. Resolve cancellation/terminal status first, retain the
old record until its outcome is known, and require explicit retry to create a new upload/source identity and descriptor.
Reopening or pressing Retry cannot reset part/session lifetime limits. Every persistence failure pauses dispatch;
there is no `try? save` followed by a network side effect.

### Usage presentation, checkpoints and acceptance

Add a compact encrypted-storage line to the existing Account/Sync area. Use `accounted_storage_bytes` against
`storage_limit_bytes`, with optional detail for history and descriptors; legacy responses without descriptor fields
are history-only, never assumed to be zero descriptor usage on a v5 account. PDF staging/processed assets and local
downloads are different allowances; do not label the encrypted-content number as all cloud storage. Show server
storage/receipt/attempt/rate rejections in the existing upload banner without guessing a credit refund or free space.
Keep pending cancellation/reconciliation possible while new-admission limits are exhausted.

Implement and commit in reviewable slices:

1. Context-bound full wire/reconciler, durable epoch checkpoint/resume, receipt compatibility and offline eligibility
   transition. Frozen actual SQL legacy fixtures remain unchanged and gain v5 response fixtures.
2. Descriptor cache/hydration/outbox, account/key recovery and complete local title-index projection.
3. Encrypted chunk/job storage, exact bounded transport, resumable/frozen/busy/cancel lifecycle and legacy queue intake.
4. Existing Add/Library/Account integration and fixture-only workflow/UI verification; keep live ingress disabled.

Acceptance includes process-stop/reopen after every durable/network boundary; missing RPC vs transient failure;
v3→v5 and restore with a lower cursor; v5 full/compact cursor swaps; mixed grouped changes; omitted-ack vs observed
descriptor; accepted write with lost reply across author revocation/recovery; stale hydration and corrupt ciphertext;
same/different-account callback races; partial chunks, same-attempt replay, uncertain replacement, limit exhaustion,
busy finalize, attach/cancel ordering and failed persistence. Scan SQLite/WAL and app-owned queue metadata for synthetic
private titles/filenames. Retain existing offline removal/quarantine/repair tests. Run targeted Core/native tests after
each slice, then full relevant suites and complete native journeys. Simulator UDID must be reserved with root before
boot/install; generic fixture-only builds need no physical phone. Browser follow-up must implement the same capability,
epoch, descriptor outbox/hydration and complete private-title index contracts using its compact v5 wire and IndexedDB.

**Lead approved for local incremental implementation:** this subtask owns the small authenticated capability RPC,
same-context sealed resume, conservative cross-epoch eligibility, encrypted chunk storage/limits and omission of
plaintext PDF-share metadata. Account key-share precedes capability rate/transfer accounting. Old-domain commands
remain review-required and previously blocked installations stay blocked without a separately reviewed recovery
proof. Commit and test slice 1 before layering 2–4. The crypto envelope and server ingress lifecycle remain unchanged.

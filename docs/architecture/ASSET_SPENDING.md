# Paper storage and delivery spending

Status: migration 035 and its worker/client transition are locally implemented and independently reviewed, 2026-10-07.
The upload proposal below is design only and still needs review before implementation. Neither describes a deployed
limit. The [cost audit](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md)
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

## Reconciliation interfaces and operator tool

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

## PDF-upload proposal (design review, 2026-10-07)

### Existing branch and migration order

The separate upload candidate is now `7bab6af`, after its main merge `386a2b6`. It renames never-applied migration 033
to 039 without changing the upload implementation reviewed at `2ce8f81`/`fed8075`, and introduces `paper-uploads`.
Its current handler returns a Supabase signed upload token with `upsert: true`, while its
row/quota uses the caller-declared size. A caller can reserve one byte and upload the bucket maximum of 64 MiB;
finalization detects the mismatch after storage. Its separate upload-policy mutex does not serialize with migration
035's paper reservations, and 035 currently sums only `paper-assets`. The existing upsert token can also overwrite
the staged file after finalization. These are implementation gaps to replace before the feature is enabled.

Keep the never-applied upload migration at **039**, after safeguards 034–038. Leave 033 unused, with no placeholder.
The repository's migration-ledger check verifies a sorted source prefix; it does not require contiguous numbering.
This lets the reviewed cost controls ship independently while uploads remain disabled. Before renaming, verify that
no target database has recorded the old version; an applied migration must instead be preserved and corrected
forward. Root completed the rename and the branch's documentation/test references at `7bab6af`, with an explicit
blocked-rollout note. This document does not change that upload branch, and deploying 039 will need its own reviewed
prerequisite/worker transition.

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
   the existing stable command identity and target revision, and transfer the future holds. Return durable processing
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

The upload branch currently copies the PDF/file/typed title into plaintext upload metadata and library projections.
That conflicts with the [private display-name and filename plan](DATA_MODEL.md#import-identity-and-membership).
Preserve that plan unless the owner explicitly changes it. Uploaded PDF content itself remains service-readable for
the authorized verification/OCR pipeline; encrypting a custom title does not make the PDF end-to-end encrypted.

Recommended descriptor design for review: an account-owned, versioned encrypted envelope containing display name and
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
  already canonical ASCII and contain no newline. This binds the encrypted value to its account, source, identity,
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

Proposed API split to review: keep installed v3 full reads and existing v4 compact/query/hydration signatures limited
to arXiv/web source kinds; retain the pending branch's v5 full reads for upload-capable native clients. Add v5 compact
page/changes/metadata/query facades that share v4's internal algorithms and add the explicit upload/descriptor contract.
This avoids PostgreSQL overload/default-argument ambiguity and preserves web loading performance. Use separate
capability-bound cursor identities; a cursor from a different source visibility or format restarts explicitly.
Unsupported entries must still advance a legacy delta's high-water mark without leaking an unknown source; empty
filtered pages cannot create an infinite loop. Legacy metadata hydration rejects unsupported-source IDs consistently.
Existing v4 query projection includes neutral upload rows for the new facades, but legacy queries filter them before
paging; counts, cursor fingerprints and tie breaks use the same visibility. Full v5 may return only the descriptor
reference and use the same bounded hydration. No format 1 encrypted history events change, so mixed-version devices
continue to sync chats normally. Verify these rules against installed native/web codecs before enabling uploads.

Persist a minimum source-visibility level on projected entries and tombstones before deleting their source row;
do not infer a removed upload's type from missing metadata. Baseline, delta, current query, counts and hydration all
apply that same level. Old-client deltas filter each grouped change and strip descriptor references, but advance to
the recorded scan boundary even when every entry was hidden. A tombstone for an upload the old client could never
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

Review decision requested: approve this transport/reservation/recovery direction and the encrypted-descriptor
compatibility design before allocating the 039 schema or changing upload APIs. The feature remains gated; no upload
schema, handler, client, hosted infrastructure or paid-provider change is implemented by this proposal.

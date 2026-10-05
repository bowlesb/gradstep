# Original acquisition execution — local integration

Status: **independently reviewed design; spool, portable transfer/verifier handoff,
Linux verifier compatibility and disabled candidate 013 locally tested; no hosted migration, runtime admission,
Storage integration or live source traffic**.
This document defines the next
original-only slice after the tested Linux metadata action. It does not change
applied 001–011, pending 012, any enabled flag, the PDF parser profile, or the paid
Mathpix contract. The isolated binary spool and SQL prerequisites are implemented
below; their tests need no source or Storage credentials. Actual loopback
transfers now feed the unchanged parser through a sealed readback FD. A separate
Linux compatibility fixture verifies the paused cross-UID handoff and exact
waits. Connecting the complete workflow to durable SQL and an admitted host
remains unfinished.

Reviewed source boundaries:

- [011 acquisition](../../supabase/migrations/202610030011_acquisition.sql),
  SHA-256 `30c2db5b6d1211dac4ccbbd93b732fb747a6dddcb06ceefc9970ba3bc3a09f03`.
- [Pending 012](../../supabase/migrations/202610030012_metadata_execution.sql.pending),
  SHA-256 `63239b21c78870c157c4c297d582de7e18c09ebf242f823dfc9c63419a32df7b`.
- [Executor lifetime](EXECUTOR_LIFETIME.md),
  [Linux metadata admission](LINUX_METADATA_ADMISSION.md), and the
  [local action protocol](../../workers/source-gateway/INTEGRATION.md).
- [Frozen PDF verifier](../../workers/pdf-verifier/README.md), build
  `39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610`.

## Deliverable and exclusions

The first complete local journey starts from an eligible metadata job in a real
disposable database. It obtains one bounded PDF from a loopback source, uploads
the exact candidate once to a private loopback object-service fixture, reads the
stored object back, verifies those reread bytes with the pinned parser, publishes
the original through 011's immutable catalog rules, and projects `pdf_ready` to
the importing account. It must prove the associated request, resource and storage
accounting, including failure and lost-acknowledgement schedules. A loopback
object-service result is not Supabase Storage acceptance evidence.

This ends at a verified original and approval suitable for the later quoted,
funded [Mathpix pipeline](MATHPIX_PIPELINE.md). It does not submit OCR, expose a
customer original-PDF proxy, deploy a scheduler, add an orphan collector, adopt
legacy originals, solve recovery after host/database restore, or claim a live
import-to-reader product journey. Published bytes and all immutable approval pins
remain retained. Unknown work stays reserved; bounded capacity can refuse new
work instead of guessing that an old operation stopped.

The disabled additive migration 013 follows 012. It replaces only the necessary
function definitions and constraints in a new file; neither predecessor file is
edited. It remains disabled by default and creates no login or credential.

## Reuse and concrete incompatibilities

| Existing implementation | Reuse | Required change in the additive slice |
|---|---|---|
| 011 eligible lookup, metadata/version/license pins and interests | Eligibility, current surviving interest and source-only behavior | New original preparation must create `execution_contract='original-v1'`; never revive a legacy original job |
| 011 paper reservation, candidate immutability and storage caps | One generated `originals/<reservation UUID>/original.pdf` path and immutable candidate | Freeze candidate at the accepted **download** checkpoint, before any upload grant; 011 freezes it after upload |
| 012 authority, attempts, immutable receipts and scoped Linux binding | One authority/epoch, no grant replay, observer role, retained resources | Kinds, required resources, byte ceilings and original-chain bindings must be extended explicitly |
| Linux paused source child, separate SQL callers, guardian and scope fence | COMMIT-before-GO, exact child/scope identity and durable small checkpoints | Original streaming output and binary spool are separate from the 1 MiB metadata body/base64 protocol |
| 011 verification profile/result, integrity records and publisher | Exact bytes/pages/profile, canonical object, approval conflicts and availability outbox | New claim/result wrappers require original execution and stored-read evidence; old timer-based routes stay revoked |
| Frozen qpdf WASM runtime | Exact parser policy, numeric ABI, byte hash and resolved page count | New Linux receiving/retirement/measurement wrapper; the runtime's `elapsedMS` is not a CPU/peak-memory attestation |
| 010/011 import and library projection | Per-account current intent, removal fences, retained pins, `state_seq`/cursor | Narrow wrapper may call existing projection code after global publication; no account mutation under global execution locks |

Pending 012 deliberately revokes original preparation, claims, upload results,
verification, publication, read grants, probes and GC. Regranting an 011 wrapper
does not repair its lifetime contract. The additive migration must keep those old
public entry points inaccessible to `service_role`, customer roles and the new
worker logins.

Three shared 012 assumptions must change together:

1. `execution_pending`, `execution_entry`, authority status, grant occupancy,
   activation/retirement and unresolved scans derive resources from one immutable
   kind mapping. They must not invent an arXiv hold for a verifier or upload.
2. `legacy_execution_unsettled()` must qualify a reservation through its owning
   job's immutable execution contract. New `original-v1` reservations are handled
   by their actual attempts and storage liabilities. Existing legacy reservations,
   legacy source grants and customer read grants continue to block admission;
   their status/age is not proof of settlement.
3. The original job's headroom includes attempts and resource receipts, not just
   011's steps/results. Existing metadata jobs retain their exact 24-unit contract.

The old metadata receipt/state APIs currently lack a kind check because the
table could contain only metadata. Add `atom|license` + `metadata-v2` checks to
`worker_record_metadata_quiescence` and `worker_metadata_execution_state`, including
their replay paths, and filter the metadata unresolved scan accordingly. The
observer cannot use a metadata receipt to close an original attempt. The generic
new scan/state path is the explicit cross-kind interface. Cross-kind denial must
be tested with the real roles, not inferred from a UI or caller convention.
Preparation explicitly refuses an active legacy original with the same
version/reuse/acquisition profile. 011's partial unique index spans execution
contracts; an unissued legacy job can occupy it without an unsettled reservation.
Do not rewrite that job or widen the index to work around the conflict.

## One authority, separate stage permissions

Keep the existing singleton `executor_authority`, epoch, host/boot pins, global
arXiv gate and `max_executors=1`. Preserve `active_policy_id` and the metadata
deployment pin for existing callers. Add an optional `original_policy_id`,
`original_deployment_id` and disabled `original_admitted` flag on that same row.
An immutable original policy binds the complete original host source, Storage
adapter semantics, four stage recipes, spool policy and verifier host profile.
It is not installed or selected by a job worker.

A new admitter-only activation accepts both selected policy/deployment references
in one revision-CAS transaction, with the same project, environment, host and
boot. It requires the authority disabled, no pending resource of any kind, and
no unresolved legacy/recovery block before changing the epoch. A metadata-only
legacy activation retains its old interface but may not silently erase or bypass
an original policy/hold. Whole-authority retirement disables metadata, original
and verification admission and retains all old attempts. Exact receipts remain
accepted after retirement. No per-job active-policy switching is permitted.

At reserve, while holding the authority mutex, permanently pin the selected
original policy ID, deployment ID, host ID and boot ID to the original job (null
before reserve; write once). The reservation already pins its verification
profile. Every later grant must match those pins. A drained policy/deployment
change may block an old queued job, but may not silently mix a download under
one policy with an uploader under another. This first slice has no compatibility
override or cross-boot spool adoption; mismatches retain the job and capacity.

Only one hosted environment may own outbound arXiv access. The initial possible
deployment is staging; production and every developer runner remain outbound
disabled. A second project is not another independent arXiv authority. Enabling
production later requires retiring/draining the old authority and an explicitly
reviewed single-gateway deployment, not copying a rate-limit table.

The immutable mapping for this slice is:

| Attempt kind | Maximum fresh attempts per original job | Required resources |
|---|---:|---|
| Existing `atom`, `license` | Existing three each, on metadata jobs | `executor`, `arxiv_connection` |
| `original_download` | 2 | `executor`, `arxiv_connection` |
| `original_upload` | 1 | `executor`, `object_write` |
| `original_readback` | 2 | `executor`, `object_read` |
| `original_verify` | 1 | `executor` |

For required-resource predicates, an unknown attempt or resource name is an
error; a known resource not required by that kind is not pending and cannot
receive a receipt. Keep metadata DTOs and their two-resource order unchanged.
The new generic scan/authority view can expose original kinds to authorized
callers; an old metadata scanner must not feed an upload into a metadata runner.

All stage grants take the authority mutex. Executor occupancy counts pending
`executor` resources across **all** kinds/epochs. Source grants also require the
single arXiv gate clear and its closure cooldown passed. A subsequent stage or
retry of an original job requires all predecessor resources of that job closed.
An uncertain object write continues to occupy its reservation and blocks that
original job; after its executor is proven retired it need not falsely occupy an
arXiv connection or prevent an unrelated metadata action. Activation/restore
checks, however, consider every outstanding resource, including object writes.

Prepaid future headroom/storage is not an active external resource. Preparing a
job does not create four fictitious running executors. Each one-use permission
and its required holds arise together only after that stage's paused execution
has been identified. No download permission transfers to a later uploader.
This deliberately refines the combined download/upload and read/verifier wording
in `EXECUTOR_LIFETIME.md`; that broader document is not silently rewritten here.

## Immutable chain and state transitions

Each new `execution_attempts` row retains its existing request, epoch, binding,
claim, generation, creation time and deadlines, plus the following original-only
columns. They are immutable and absent/null on old metadata rows:

- `reservation_id`, `predecessor_operation_id`, `predecessor_result_sha256`;
- candidate SHA-256/byte count for every stage after download;
- exact input spool-descriptor SHA-256 for upload/verify, and expected object
  bucket/path identity for upload/readback (derived from the reservation);
- reserved verification profile ID, parser build SHA-256 and host-policy SHA-256
  where verification is relevant;
- charge kind/period/ceiling, including an explicit source request day for new
  downloads and the worker-read month for readback.

Kind-specific constraints preserve the metadata ceiling at exactly 1 MiB; new
download/readback attempts use the reservation's 5 MiB ceiling, upload uses the
fixed candidate length, and verifier uses that length only as a local input
bound. Verifier has no external byte-charge kind/period; do not invent a transfer
charge or refund for reading its already-accounted local FD. Existing metadata
charge periods remain byte-for-byte unchanged and no request day is guessed for
old rows. All new external resources have no automatic reclaim timestamp;
`safe_after`, lease expiry and reporting expiry remain scheduling facts only.

The predecessor pair identifies the **immediate** immutable accepted step result
from the same reservation, not the current mutable job entry. The first download
points to reserve; upload points to the accepted download; first stored read
points to upload; verifier points to the accepted stored read. A read/download
retry instead points to its immediately preceding failed attempt. SQL follows
that attempt's immutable predecessor once more to the settled upload/reserve
input, verifies both results and confirms closed resources; retry depth is at
most two attempts for those stages. This needs no second uncounted predecessor
record. No caller supplies a target URL or path.

Use a new binding version for original policies rather than changing the closed
metadata-v2 binding. It preserves project/epoch, admitted deployment and source
hashes, host/boot, PID/start identity, one-use child UUID, and the exact retained
scope/capture identity. The original request descriptor and its SHA-256 are
captured before grant and included in the grant digest. SQL derives the same
descriptor from the job/reservation/stage; guardian compares the returned bytes
before GO. A changed revision, profile, candidate or predecessor means no GO and
retirement of that paused execution. Identity alone does not prove URL identity.

The proposed job stages add only `upload` and `readback` to 011. The reservation
states can be retained:

| Accepted transition | Job after transition | Reservation after transition |
|---|---|---|
| Prepare + reserve, in separate short SQL operations | `download / queued` | `reserved`, maximum 5 MiB held, fixed profile/path |
| Fresh download grant | `download / leased`, generation +1 | `reserved`, generation bound to that claim |
| Complete source body, retired source execution, guardian-sealed spool and accepted download result | `upload / queued` | `reserved`, **candidate hash/bytes permanently set** |
| Fresh upload grant with candidate and predecessor | `upload / leased`, generation +1 | `uploading` |
| Positive upload settlement and executor closure, then accepted upload result | `readback / queued` | `pending_verification` |
| Upload response missing/ambiguous | `upload / blocked` after explicit failure checkpoint | `upload_uncertain`, full reservation retained; write hold remains |
| Fresh stored-read grant | `readback / leased`, generation +1 | `pending_verification` |
| Complete matching stored bytes, retired read execution, sealed readback and accepted result | `pending_verification / queued` | `pending_verification` |
| Fresh verifier grant | `pending_verification / leased`, generation +1 | `verifying`, verification generation +1 and attempt count 1 |
| Positive verifier result with admitted resource evidence and executor closure | `publish / queued` | `verified` with immutable verification result ID |
| SQL-only publication | `complete / complete` | `published`, or 011's retained losing duplicate |

Preparation alone creates no interest. Between prepare and reserve, the original
executor calls existing `worker_import_state` and then
`worker_link_import_acquisition(account_id, import_id, expected_intent_revision,
expected_state_seq, lookup_job_id, original_job_id)` in its own account-scoped
transaction. Reserve/grant recheck `acquisition_has_interest`. A cancellation
visible at the final post-wait interest check prevents new permission; a cancel
committing after that read may overlap the already-admitted shared work. Do not
add an inverse global account lock to imply stronger serialization. Projection
still honors the current removal fence, and no bypass is added merely because a
global job exists. After publication, global lookup binding and existing
`worker_project_import_acquisition` are separate calls, with that account's exact
intent fence. A second interested account can link the same original job through
the same existing rules.

Positive, stage-advancing result acceptance requires the current job
claim/generation, immutable chain, unexpired reporting authority, active relevant
profile and the required receipts.
Every fresh external grant advances the job generation; verification additionally
advances its existing verification generation. SQL-only reserve/publication each
have one operation/step and a current generation fence; they need no external
execution row. Publication remains replayable after acknowledgement loss.

A nonadvancing failure may be recorded while a required resource remains pending,
as in 012's failure contract. In particular an unknown upload records its bounded
failure in the existing step and enters `blocked / upload_uncertain` without
closing `object_write`, refunding charges or authorizing a subsequent stage.
Logical failure and resource retirement are separate facts.

Late resource evidence names the original attempt/reservation, not today's job
claim. It never advances a replaced generation, clears another hold, refunds a
different attempt or re-enables a retired authority. Known grant replay is always
`granted:false`, even after stage advancement or policy disable. Reusing a claim
with changed arguments is a conflict, not a new attempt.

Only closed, known failed downloads/reads may consume their second attempt, using
the same 011 retry-age/backoff policy and a new claim. The candidate cannot change
after it is frozen. A complete stored-object mismatch, parser refusal, resource
limit, timeout or verifier-internal failure is terminal for this first profile;
no automatic verifier retry. A stale positive result is not republished under a
fresh lease. Expiration of the 24-hour reservation stops new work/publication; it
does not clear resources, delete local spools or release remote storage capacity.

A bounded SQL-only expiry finalizer handles an issued step after its report
deadline without inventing an external retry. It CAS-checks the exact current
job/claim/generation/attempt, accepts exact replay of its own terminal result,
and otherwise stores one fixed expired-negative in that existing step. A
different existing terminal result is immutable; an old attempt cannot expire
a newer current generation. It creates no row, permission, receipt or refund.
Download/read retries become eligible only when all relevant resources are
closed and age/count permits; upload/verifier expire terminal or blocked with
all remaining holds and bytes retained. Negative finalization may run after
admission is disabled; it grants no positive result authority. A later receipt
can still settle its named resource without changing that terminal result.

## Proposed RPC and role surface

Names below are proposed exact entry points, not implemented capabilities:

```text
worker_prepare_original_v1(operation_id, eligible_lookup_job_id)
worker_reserve_original_v1(job_id, operation_id, reservation_id)
worker_claim_original_stage_v1(job_id, claim_id, environment, stage,
                              expected_request_sha256, executor_binding)
worker_finish_original_stage_v1(job_id, claim_id, generation, attempt_id, result)
worker_fail_original_stage_v1(job_id, claim_id, generation, attempt_id,
                             error_code, retryable)
worker_expire_original_stage_v1(job_id, claim_id, generation, attempt_id)
worker_finish_original_verification_v1(job_id, claim_id, generation, attempt_id,
                                      verification_generation, result)
worker_publish_original_v1(job_id, operation_id, reservation_id,
                           expected_verification_result_id)
worker_original_execution_state(job_id, claim_id)
worker_original_job_state(job_id)
worker_scan_original_jobs_v1(after_job_id?, limit=50)
worker_scan_unsettled_executions(after_attempt_id?, limit=50)
worker_record_original_quiescence(attempt_id, receipt_id, resource,
                                  evidence_kind, facts)
worker_bind_lookup_original_v1(lookup_job_id, original_job_id)
```

`stage` is one of the four original kinds; it is checked against SQL state, never
an extensible operation string. Successful claims return the full immutable job,
execution, required resources, exact request descriptor and one fresh permission.
The small result/failure object is a closed, stage-specific schema, at most 8 KiB.
Status has no permission, credentials or object body. The unresolved scan is
resource-aware and independent of status, expiry, account existence and epoch.
It does not substitute for job discovery: the bounded UUID-keyset original job
scan also finds queued reserve/next-stage/publication work when no resource is
pending. It returns at most 100 original-v1 job IDs/stage revisions, with verifier
callers restricted to the verification stage. Detailed state is bounded by the
one reservation/six-attempt envelope. No scan grants I/O or retries an expired
lease. The first fixture drives its known job from a durable local intent; these
reads permit later recovery without introducing a scheduler table.

Use a new `science_reader_original_executor` capability for preparation, reserve,
the three transfer stages, their results/failures, publication and binding. Extend
the existing `science_reader_pdf_verifier` capability only with the verifier grant
and result surface; it cannot upload, publish or submit observer evidence.
`science_reader_execution_observer` alone submits final original resource
receipts. `science_reader_executor_admitter` alone installs/selects policies and
profiles. Keep actual separate LOGIN/NOINHERIT/SCRAM-TLS callers with one narrow
SET-role capability each, as in the tested metadata fixture. All capabilities are
NOLOGIN in migration; no PUBLIC/anon/authenticated/service-role execution grants,
table privileges or owner membership are introduced. Exposed SECURITY DEFINER
functions check the effective caller role, not their definer's `current_user`.
Explicitly grant the original executor the existing account-fenced import
state/link/project RPCs for the ordering above; it does not call through an owner
or service-role session. `worker_bind_lookup_original_v1` binds only the global
lookup/approval and is not the account-interest link. Legacy projection semantics
and their reserved foreground cancellation headroom remain unchanged.

The source child has no DB, Storage or observer secret. The transfer supervisor
has no SQL credential. The fixed uploader/read adapter receives only the exact
object capability required for its request, separately from SQL permission; the
SQL executor cannot manufacture observer evidence. The verifier has no network
or Storage credential and receives one owned readback input. The root guardian
owns durable checkpoints, descriptors and privileged scope observation, not
arbitrary caller-selected file paths. The loopback fixture uses only synthetic
capabilities; actual Supabase credential/RLS provisioning is a separate admission
gate, not a reason to give this process `service_role`.

## Binary spool: implementation prerequisite

Do not raise metadata `MAX_BODY=1,048,576`, `MAX_OUTPUT=1,572,864`, its base64
protocol, or the fixed 4 MiB/32-name action journal to carry PDFs. Add a narrow
`OriginalSpool` component and streaming transport entry under
`workers/source-gateway/linux/`; share existing TLS/framing, identity and guardian
mechanisms where their contract applies. No second general HTTP or storage layer
is needed.

The proposed public component interface is:

```text
OriginalSpool(root, slot_identity) -> locked_context
prepare(locked_context) -> preopened_producer_directory
    # Guardian only, under the reservation lock; refuses another retained leaf.
create_producer(preopened_producer_directory, binding) -> producer_handle
    # Supervisor only, in the exact pre-reserved leaf. No caller path.
append(producer_handle, bytes) -> bounded byte/hash progress
finish_producer(producer_handle, complete_transfer_facts) -> small final witness
seal(root, binding, trusted_complete_witness, retirement) -> SpoolDescriptor
open_sealed(root, expected_descriptor, reader_intent, validate_reader)
    -> locked_read_handle
retire_slots(root, expected_descriptor_or_partial_capture, retirement,
             downstream_settlement) -> durable_cleanup_receipt
```

Allocation, seal, reopen and cleanup run under **one root-owned reservation-level
publication lock**, not a separate lock per purpose or attempt. The
retirement/settlement arguments are validated trusted guardian records, never a
caller boolean. The isolated spool tests may inject that already-validated proof
boundary; doing so proves file mechanics only, not systemd/SQL retirement.

The closed `SlotIdentity` is exactly `{reservation_id, claim_id, purpose}`. The
claim UUID is the already planned operation/scope ID. It is available before
spawning; the separate SQL execution attempt ID is generated only by a committed
grant. `prepare` uses only SlotIdentity and does not invent a capture or grant.
The producer directory is prepared/passed before READY, but no producer bytes
are accepted until the full post-grant binding is delivered with GO.

The closed binding and descriptor schema are UTF-8 canonical JSON with a trailing
LF, at most 4,096 bytes. Reject unknown/missing fields and noncanonical encodings;
`bytes` is an integer, not boolean, in 1…5,242,880. Device values are canonical
unsigned decimal strings and inode values positive decimal strings, each within
uint64. UUIDs and SHA-256 strings are canonical lowercase. The
binding is captured before transfer; content/inode fields are filled by the
owning process and checked by the guardian:

```json
{
  "format": "original-spool-v1",
  "reservation_id": "<uuid>",
  "claim_id": "<uuid>",
  "attempt_id": "<uuid>",
  "purpose": "source_download|stored_readback",
  "request_sha256": "<64 hex>",
  "binding_sha256": "<64 hex>",
  "capture_sha256": "<64 hex>",
  "sha256": "<64 hex>",
  "bytes": 12345,
  "producer": {"device": "<decimal>", "inode": "<decimal>"},
  "guardian": {"device": "<decimal>", "inode": "<decimal>"}
}
```

The binding has **exactly** `reservation_id`, `claim_id`, `attempt_id`, `purpose`,
`request_sha256`, `binding_sha256` and `capture_sha256`, with the same values as
the descriptor. It has no separate format field. The descriptor adds exactly
`format`, `sha256`, `bytes`, `producer` and `guardian`; each inode object has
exactly `device` and `inode`. A hash of either
object includes its canonical trailing LF. Guardian checks the full binding
against the exact committed SQL grant and saved READY/capture before GO. Capture
a value-owned binding before any producer write or asynchronous handoff; later
caller mutation cannot change a slot. Allocation identities and full bindings
must agree exactly on their three common fields.

Hash the entire descriptor as the chain's `spool_descriptor_sha256`. It contains
neither arbitrary path nor credential. Derive directories only from the fixed
trusted base, reservation UUID, purpose enum and claim UUID. The fixed base is
`/var/lib/timestep-source/original-spools`. Each `<reservation hex>/` is root 0700
and contains `publication.lock` plus **at most one** generated directory
`<purpose>-<claim hex>/`. That active leaf is root 0700 and contains only
`producer/` (UID/GID 62401, 0700) and `guardian/` (root, 0700). Refuse a second or
unexpected leaf even if the first looks empty, partially initialized or expired.
The guardian opens the exact producer directory before privilege drop and passes
that directory FD only to its supervisor; the source receives no directory FD.
Root 0700 ancestors need not become traversable to the transfer child.
Ancestor ownership/modes, device/inode, regular-file type, no-follow opens and
exact link counts are checked on every reopen. Do not accept a redirecting symlink
or another mounted/device view as the same slot.

The source child UID 62402 writes only to a dedicated binary pipe, in chunks no
larger than 64 KiB. It has no spool directory/payload FD, DB credential or
control-FD export route. Supervisor UID 62401 drains into one exclusive producer inode, never more
than **5,242,880 bytes**; it counts/hashes incrementally and drains/cancels within
the existing finite transport/watchdog contract. The separate control result is
small: status, framing, complete-byte/hash facts, request binding and disposition.
No PDF bytes, base64, XML/parser DTO or arbitrary error text enters the journal.
Wire/protocol/header limits are separate from the PDF body ceiling; define and
test their original-specific constants without weakening metadata limits.

Only a 200 response with accepted complete HTTP framing, no redirect or content
encoding, bounded nonempty bytes and exact retired producer/source ownership can
become a candidate. Magic/type checks remain preliminary, not page-count or
structural verification. Partial/empty/non-200 bodies may have diagnostic counts;
they do not become a candidate. Whole-body SHA-256 is absent for incomplete input.

After complete framing and trusted exact retirement, root reads the stable
producer inode, independently hashes/counts it, copies into one guardian inode,
fsyncs payload and directory, and then publishes/fsyncs the descriptor. This is
immutable through ownership, exact identity and retirement of all writers;
`chmod(0400)` alone cannot revoke an already-open writable FD. The receiver
rechecks the entire stored descriptor and bounded file/hash before each use.
The input FD handed to the uploader/verifier is read-only; the caller cannot
substitute another path after validation.

`open_sealed` is a context-managed handle retaining the reservation lock. Before
spawning a reader or exporting any FD, the guardian fsyncs the planned reader
claim/kind/descriptor intent in the existing action journal and the trusted
validator refuses any unresolved earlier reader. This is an intent, not a future
READY/capture or a grant. After that paused reader exists, bind its actual capture
and committed execution before GO. Closing the guardian's own descriptor does not
prove a duplicated child FD is gone. Normal release requires exact retirement
of that captured reader; cleanup also checks every retained reader intent and
downstream settlement. Guardian death releases the OS lock but leaves that intent
unresolved, so another guardian cannot delete/reallocate the pair merely because
it can acquire `flock`. Scope/SQL observation belongs to the enclosing guardian,
not this file component. No user-selected reader token can assert retirement.
Reopening after a crash also requires that reader-intent gate before handing out
a new FD; a free lock is not fresh read authority.

There are at most **two distinct payload inodes**, one producer and one guardian,
each at most 5 MiB, plus one descriptor inode at most 4 KiB and one zero-byte lock.
Closed names: producer `payload.pending`/`payload`; guardian
`payload.pending`/`payload`, `descriptor.pending`/`descriptor.json`; reservation
root `publication.lock`. A pending/final pair must be aliases of the same inode; count
both names but its bytes once. Maximum: seven names, 10,489,856 retained logical
bytes including the descriptor. Directory/filesystem overhead and free-space
margin are additional; at most four reservation-owned directories exist (the
reservation root, active leaf and its two children). This arithmetic is not a
physical disk quota. New allocation requires completed exact-leaf removal and
parent-directory fsync, never implicit replacement under a new attempt name.

Recovery checks the accepted guardian final and descriptor **before allocating
anything**. It never creates a third payload copy. An existing pending target can
be reused in place only with the exact saved trusted completion and retired
producer identity; a conflicting accepted final is never overwritten. A payload
published before descriptor fsync can be recovered only with that saved proof,
not from a plausible size/hash alone. Reopening an already sealed guardian file
after a durable producer unlink does not require the old producer path to exist;
the producer inode remains provenance, not a live dependency. Unexpected names,
links, partial descriptors or identity changes fail closed with slots retained.
Final descriptor recovery must match the expected candidate hash/length, guardian
inode and exact active leaf as well as the immutable binding. It cannot adopt a
different same-sized file discovered during a scan.

Phases are serialized. Keep source slots until the upload is positively settled
and its executor retired. Then durably remove those **exact** local slots and
record cleanup before allocating the stored-readback pair. A closed failed
download/readback similarly disposes its exact partials before a permitted retry.
No deletion occurs while a possible reader/writer remains. Unknown upload keeps
its source spool and write hold; no readback/probe is allocated in this first
slice. The verifier consumes only the guardian file produced by stored readback.
This keeps one 10 MiB pair per reservation without concealing a second readback
copy. Old descriptor/cleanup digests remain in bounded SQL/action records.

## Grant, GO, result and receipt ordering

For each external stage, retain the tested Linux order:

1. Check source/profile/capacity and local free-space reservations. Capture the
   immutable action bundle, exact stage request and any input descriptor. Spawn
   the identified paused execution; verify UID/GID/capability, host/boot,
   PID/start, invocation and retained scope. No operation, parsing or network
   execution is authorized before GO. A fixed read-only input FD may already be
   inherited; the trusted paused wrapper must defer reading/parsing it until GO.
   Fsync the exact capture and capture-bound permanent **future-start fence**
   before any grant intent/RPC. This is distinct from stop or GO: the running
   invocation may continue, but a replacement start for its unit is refused.
2. Fsync the grant intent and identities before invoking the claim **once** with
   the narrow SQL caller. Record monotonic time immediately before the RPC.
3. Require successful transaction COMMIT acknowledgement, not a streamed SELECT
   row. Validate the returned immutable execution and derived request. Convert
   `deadline-created_at` durations relative to the pre-RPC clock, subtracting all
   RPC time; use the same admitted Linux suspend-aware clock in guardian and child.
4. Fsync the exact grant and GO intent, recheck cancellation/deadline/current
   binding immediately before the one control send, then GO only that execution.
   Never rebind a paused child or mint an upload in the download process.
5. After the operation, obtain actual exact-child retirement or the reviewed
   permanent-fence/empty retained-scope proof. Record the trusted witness, resource
   evidence and exact planned receipt bodies durably before observer calls.
6. For complete transfers, seal the spool/acknowledgement evidence before result
   submission. Record exact result arguments before their RPC. Validate returned
   execution, receipt facts and canonical receipt ID; a duplicate proof may return
   the already accepted receipt ID. Persist exact acknowledgements.
7. Only after all stage receipts and result acknowledgement are reconciled may
   the next separate stage start. Publication is another short SQL operation,
   followed by lookup binding and per-account projection in separate transactions.

A lost grant/COMMIT acknowledgement always means no GO. A null status read is
not proof an older transaction cannot later commit. Retain the paused-execution
retirement witness and intent, reconcile by status, and never call grant as a
status query. For an upload whose grant may have committed, this first contract
has no separately admitted never-started-write proof: it conservatively retains
the write hold even if local GO was withheld. It can close the proven executor.

Observer-only recovery cannot spawn source/Storage/verifier work, parse a PDF,
advance a stage or publish. Complete already-checkpointed result recovery is a
separate executor/verifier action with the exact original arguments. Current
guardian-death and boot/restore ambiguity stays quarantined; a recreated PID,
cgroup, file or downloaded object is not the lost original witness.

## Upload settlement and readback

An upload grant atomically records the sole upload attempt, fixes its candidate,
prior download result, exact path, descriptor, maximum request bytes and required
`object_write` hold. Candidate hash/length already exist and cannot be supplied
from a later GET. Upload uses a fixed no-overwrite request, no redirect, no retry,
no resumable/multipart fallback and no SDK retry behavior. Request bodies are
streamed from the validated read-only spool.

A normal `storage_upload_ack_v1` receipt requires the already-admitted Storage
adapter's exact terminal success semantics: complete bounded success response to
that POST, exact bucket/path and request binding, acknowledged commit, and retired
local uploader. The durable proof binds attempt/candidate/path, response digest
and storage-policy identity. It is submitted by the observer, after executor
closure. It grants no content verification; stored readback is still required.
For the first loopback fixture the server can explicitly model commit-before-ACK.
Actual Supabase response/status/body semantics require a later authenticated
staging contract check and fixed adapter policy before this evidence kind is
admitted there.

Supabase documents default no-overwrite uploads and first-completion-wins at a
shared path; those facts support a never-reused path, not timeout settlement.
[Standard uploads](https://supabase.com/docs/guides/storage/uploads/standard-uploads)
and [Storage errors](https://supabase.com/docs/guides/storage/debugging/error-codes)
also mean a conflict is not a successful acknowledgement of this attempt.
INSERT-only RLS can exclude overwrite/delete authority;
[Storage access control](https://supabase.com/docs/guides/storage/security/access-control)
is a separate credential boundary. A two-hour
[signed upload URL](https://supabase.com/docs/reference/javascript/file-buckets-createsigneduploadurl)
is a reusable bearer capability, not our one-use grant or proof of retirement.

Only a positively captured, durably checkpointed acknowledgement can be replayed
to recover a lost SQL receipt response. If the POST might have reached Storage
but its terminal acknowledgement is absent, record `upload_uncertain`, retain
the full storage reservation/local spool and leave `object_write` pending.
Scope/process/socket retirement closes the executor, **not** the remote writer.
No successor upload, publication or capacity release follows. A later matching
GET proves bytes, and an absent GET proves one observation; neither by itself
settles the old writer. Online probes and operator resolution of that uncertainty
are intentionally outside this first finite schedule. This is a bounded liveness
cost, not a fabricated successful recovery.

Stored readback requires the exact settled upload result and path, a fresh
already-bound executor, a prepaid worker-byte ceiling and an `object_read` hold.
Its transport is separate from arXiv and never consumes an arXiv permit. A complete
200 response is streamed into the fresh readback spool and compared to the fixed
candidate after actual retirement. A mismatch is a truthful permanent integrity
failure; partial/oversized bodies never claim a complete SHA. A missing/transient
read may use its one bounded retry only after closure, never by clearing a lease.

The new object-read policy must explicitly cover retirement of the owned request
and response transfer. It does not assert that arbitrary remote application work
has stopped. Normal complete-read evidence and scope-only unknown-body closure
are different closed schemas: only the former can carry hash/length or refund.
Executor closure precedes object-read closure. If later hosted semantics cannot
support cancellation settlement, that receipt kind remains unadmitted and the
read hold stays pending; a local socket close is not silently promoted to a
stronger service guarantee.

## Verifier boundary and allowed profile

The only proposed parser is the unchanged `qpdf-wasm-pilot-v1` in build `39980de…`:
5 MiB, 50 pages, fixed 64 MiB WASM memory/2 MiB stack, qpdf 12.4.2, no recovery,
encryption or warnings, and the existing structural/decompression/token limits.
Keep `hosted_admitted:false` and the original source/profile/build files intact.
The complete immutable asset bundle is installed/accounted separately from the
small action source graph and journal, and the actual Linux Deno executable and
wrapper graph are pinned. A successful compatibility test is not host admission.

The verifier reads the validated **stored-readback** FD, owns its bytes, rehashes
them against the candidate, invokes the frozen numeric ABI once and returns only
the finite measurement. No Storage/SQL/HTTP capability is present in that parser
process. A separate restricted verifier caller submits the result only after
guardian evidence for the exact execution and measurements is available.

The current measurement contains `elapsedMS`, hash, bytes, outcome, page count
and parser/profile identities. It cannot fill 011's `cpu_ms` or
`peak_host_bytes`. Linux cgroup `memory.peak` is peak **charged** memory, including
descendants; retain that literal observation separately. It is not whole-worker
peak residency and cannot be substituted into the existing field. A cgroup CPU
quota is a rate limit, not a total-CPU budget.

The proposed immutable host measurement policy is
`owned-process-rss-upper-envelope-v1`: a fresh fixed verifier set consisting of
the Deno process and its dedicated supervisor, with exact Linux `wait4` rusage
for each waited child. Linux's supervisor wait includes CPU from children it
reaped, and its `ru_maxrss` includes their maximum; these are not disjoint
own-process records. Preserve both raw records and compute the conservative
overlapping envelope as `1024 * (S.ru_maxrss + D.ru_maxrss)`. Do not sum S and D
CPU. Reaper RSS is separate supervision overhead. This upper envelope, not a
sampled RSS or cgroup peak, is the proposed
meaning of the new profile's `peak_host_bytes`. Record raw per-process identity,
rusage and aggregation evidence separately; bind its digest to the receipt.
Measure total CPU from the fresh retained verifier scope's `cpu.stat` before and
after, and full wrapper wall duration from the admitted clock. Startup, WASM
compilation, input copy, parser and teardown costs are included.

This host policy is **not admitted**. Existing metadata/transfer helpers use
`waitpid`; the portable receiver owns direct-child `wait4` evidence. The
[Linux compatibility fixture](LINUX_VERIFIER_COMPATIBILITY.md) now additionally
retains both supervisor and Deno waits and fresh-slice CPU/charged-memory facts.
It does not establish the complete lifetime process/thread policy. Lost wait
authority/rusage after parent death means
unknown, even if the cgroup is later empty. Host admission must prove the complete
process/thread set, exact zero/initial counters and preserved final counters,
positive empty-scope retirement, peak-RSS aggregation, and independent bounded
CPU/memory/wall termination. It must budget guardian/OS/shared-asset overhead
outside the measured verifier set. The metadata `TasksMax=2`/single-thread check
cannot be reused blindly for Deno's runtime threads. A finite separate verifier
unit/profile and its negative tests must be reviewed before selecting the exact
task bound. Missing or over-limit metrics mean no positive verification result;
the implementation must not fabricate values to satisfy 011.

The additive wrapper can reuse 011's measured profile/result shape only after
that precise host definition is reviewed and represented in a new immutable DB
profile. The DB profile is a new host/measurement envelope referring to the
unchanged parser-profile SHA-256
`c8478d6e1b1f7a8631132789a471a7f525123f40d2e893890254fb1660b54962`
and exact build; do not pass its different envelope hash to the frozen runtime
as though it were the parser profile. Validate both identities explicitly.
Raw rusage/cgroup evidence stays in bounded local checkpoints with its digest
bound into the step result; send only the accepted closed metric fields to the
011-compatible record. Parser profile/build remain unchanged. A failed parser result may be
recorded with truthful finite negative facts, but it neither proves closure nor
returns positive pages. Readback integrity failures need a new stage-fenced
route into the existing bounded integrity record: 011's old route requires a
verifier claim, so the caller must not invent such a claim for a failed read.

## Capacity and charging

Prepay this exact original schedule at preparation. A held unit is an 8 KiB
logical control-record allowance, not a PostgreSQL disk/WAL estimate:

| Retained item | Maximum units |
|---|---:|
| Reserve + six external stage steps + publication | 8 |
| External execution attempts | 6 |
| Required resource receipts: 2×2 + 1×2 + 2×2 + 1 | 11 |
| One original reservation | 1 |
| One verification result + one integrity result allowance | 2 |
| **Original job-held envelope** | **28** |

The two result allowances are deliberately both reserved even when a given path
uses only one. Failures/arming/reconciliation update the existing immutable step
result once; no separate uncounted event/probe ledger exists. Preparation-command
receipts and the job row remain separately counted under 012's admission formula.
Policy/profile envelopes remain counted; adding fields/kinds does not excuse the
fixed policy pool or its eight-policy cap. Keep the existing 32 MiB control-data,
100,000-step, request and transfer caps. The new constraint permits exactly 28
held units for `original-v1`; metadata stays exactly 24, legacy no more than 24.
No old job grows its headroom. Retain original headroom through terminal states
in this slice; do not prune receipts or release unfinished obligations.

Grant helpers consume the reserved schedule and count attempts, steps, results
and receipts together. 011's `acquisition_add_step` does not count execution rows
and cannot be used unmodified. Completion/negative/late-receipt paths do not call
general admission or reacquire `acquisition_policy` after locking a job. A full
or reduced pool must still permit the exact reserved terminal/receipt rows.

Remote paper capacity remains 512 MiB/2,000 objects/four active original
reservations, at most 5 MiB each. Count any unresolved resource and retained
upload uncertainty as active irrespective of reservation status or expiry.
Before download reserve one object and the full 5 MiB. Only settled exact upload
and matching stored read may shrink retained object bytes to actual length.
No publication may double-count or forget the reservation-to-object transition;
losing duplicates retain their physical capacity until a future admitted cleanup.

For local disk, preflight and reserve six 4 MiB small-action envelopes, one
10 MiB spool pair/4 KiB descriptor, and one 64 KiB job-control envelope:
**35,721,216 logical bytes per original job**. Four unfinished jobs therefore
reserve 142,884,864 logical bytes before filesystem/free-space margin and
separately installed immutable runtime assets. The job envelope has eight fixed
8 KiB records (prepare intent/ACK, reserve intent/ACK, publication intent/ACK,
capacity and final local-cleanup receipt) plus a zero-byte lock. Its sole pending
alias either occupies a missing final slot or aliases that final inode; maximum
ten file names, no extra body inode. These are separate from each action's
32-name limit and the spool's seven-name limit. Never accumulate uncounted
per-retry job records.

Original small-action journals need a closed layout of their own within the
existing 4 MiB/32-name arithmetic. The metadata journal hardcodes `tsmetadata`
units, parser input/output and arXiv receipt names; it is not already a generic
original journal. Reuse its publication/inventory machinery with an explicit
original layout: replace its two unused parser slots with spool/cleanup facts,
and its second-resource slots with the stage's one optional external resource.
Retain all byte/name ceilings and count the actual rendered original units and
source graph. Actual usage is expected smaller; do not rely on that to admit
work. Pending/final hardlinks count as separate names and one inode's bytes. If
the chosen original source graph exceeds its declared small-graph allowance,
return for review instead of silently increasing the metadata envelope.

Reserve a local action envelope **before spawn**, not only when SQL grants an
attempt. Pregrant wait/disabled/no-interest actions and an ambiguous grant already
own a paused scope/journal and count toward this finite local pool. A definitive
committed non-grant could return its local slot only after exact local retirement
and durable cleanup; the first driver may instead stop at six retained action
envelopes. It must never create a seventh because no SQL retry was charged.
Ambiguous/no-row grant status never returns a slot. This local accounting neither
burns a SQL source retry nor gives a reused claim new execution permission.

Charge each admitted download's full 5 MiB and one source request before GO; a
valid complete-body/retired-source receipt can refund unused bytes only in that
attempt's original source month. Unknown body retains full charge and requests
are never refunded. Capture the actual charged request day explicitly for new
original attempts; do not infer it from `created_at` across a lock-wait midnight.
Keep the gate cooldown at least three seconds after confirmed closure, extended
to any longer supported Retry-After delay. An unsupported delay keeps the source
hold, not merely a local scheduler pause.

Stored reads reserve the full 5 MiB ceiling against the existing worker-read
budget, including failed reads. Unknown reads retain full charge; known complete
refunds affect only the captured original month. Upload reserves at most the
fixed candidate length and is counted once as a retained upload liability; add
an explicit environment `object_upload_bytes` window with the existing 1 GiB
source-download cap as its upper limit rather than leaving upload traffic
unaccounted. It is an additional constraint, not extra provider allowance.
No unknown POST refunds any part. New-period admission includes outstanding older
liability once, without rewriting old rows or double-counting current-period
charges. Window/row-cap admission is bounded and receipts never create a new
window to refund. No paid provider balance is touched.

## Lock order, publication and migration checks

No network or filesystem I/O occurs under SQL locks. Proposed row order:

| Transaction | Lock order |
|---|---|
| Prepare original | Acquisition policy → eligible lookup/original job NKU; no authority lock afterward |
| Reserve original | Authority → paper capacity → original job NKU → reservation/step; read policy only |
| Download grant | Authority → paper capacity → arXiv gate → original job NKU → reservation NKU → step → transfer capacity/windows |
| Upload/read/verifier grant | Authority → paper capacity → original job NKU → reservation NKU → step → applicable transfer capacity/windows |
| Original resource receipt | Authority → arXiv gate only for source → immutable attempt → matching step/receipt → original transfer window; no account/catalog/paper lock afterward |
| Stage/verifier result | Authority → paper capacity → original job NKU → reservation NKU → step/result; no later acquisition-policy lock |
| Original publication | Authority → paper capacity → exact document FOR UPDATE/hash insertion → original job NKU → reservation/step/object → library catalog policy → outbox |
| Account projection | Existing one-account → document KEY SHARE → library policy/state order; no authority/paper lock afterward |

Use `FOR NO KEY UPDATE` on mutable job/reservation/step identity rows where FK
KEY SHARE can occur. Preserve the document FOR UPDATE exception before catalog
policy. The new reservation/attempt predecessor FKs must be checked against these
orders; do not acquire a parent account lock by an FK in a global transaction.
After waiting on final transfer locks, reread enable/profile/caps and surviving
interest before creating a grant. Wait/cooldown/disabled/no-interest returns
allocate no step, generation, retry, charge or reservation mutation.

Publication reuses the exact 011 rules for hash/page identity, approval pin
conflicts, duplicate originals, `stored_objects`, `paper_originals`, availability
and durable outbox. It adds the all-required-resources-closed and accepted-chain
checks; it does not duplicate catalog policy. Bind the lookup and project account
availability separately. A cancelled/removed membership stays removed. Original
availability does not invent a render artifact or successful Mathpix output.

Migration preflight requires all operational flags off and a reviewed DDL barrier
order, including original reservation/verification identity tables. It preserves
old policy rows and every old execution/receipt byte. Tests must exercise actual
FK contention and catalog writers. Applying 013 locally after 001–012 is not
permission to apply either pending migration to staging.

## Smallest decisive acceptance sequence

1. **Spool in isolation.** Stream exact 5 MiB and cap+1 without whole-body JSON;
   interrupted writes/copy/link/fsync; final-first recovery; producer removed
   after accepted seal; substituted/mutated/symlinked file, extra link/name and
   duplicate final refusal; actual worst-overlap inode/name/byte counts. No third
   copy on replay; absent trusted completion or retirement never seals a file.
2. **Additive SQL.** Disposable real PG17 with unchanged 001–012 then candidate;
   real separate callers and cross-role denials; complete finite headroom;
   old metadata-v1/v2 replay/permission tests unchanged; resource-aware occupancy,
   legacy qualification, single source gate and simultaneous metadata/original
   schedules. Reduce every cap to its exact boundary, including completion under
   exhaustion and delayed original-month refund/day preservation.
3. **Normal complete local original.** Loopback eligible source + exact PDF +
   no-overwrite Storage model. One source GET, one POST, one different stored GET,
   one pinned verifier invocation; actual DB hashes/length/pages/profile/object
   IDs, approval and account cursor checked. Verify the parser FD is the readback
   inode. Gate positive publication on actual admitted measurement evidence,
   never a fixture-supplied CPU/RSS number.
4. **Download/GO failures.** Lost COMMIT/late-visible grant, source revision or
   profile changed while paused, cancellation at the fsync/send boundary, source
   supervisor death, truncated/encoded/oversized/non-200 response and Retry-After.
   No wrong GET/candidate; closure and full unknown charges differ from success.
5. **Upload uncertainty.** Commit then drop response; fail before/after durable
   ACK; exact replay; wrong candidate/path/descriptor and no-overwrite conflict.
   At most one POST; ambiguous write holds survive executor closure, timeout,
   matching/absent fixture observations, cancellation, rollover and restart.
   No readback, publication, retry, delete or released capacity bypasses the hold.
6. **Stored-read/verifier failures.** Missing/truncated stored response, correct
   length with wrong bytes, stale/unavailable spool, encrypted/malformed/bomb/page
   limit input, measured resource overrun, killed verifier and missing rusage.
   Partial hash stays null; no false page count/approval; only closed read failures
   may consume the second read. Fresh scope identity and full process metrics are
   tested separately from the parser's return value.
7. **Replay/publication/projection.** Lose each receipt/result/publication response,
   use a fresh observer-only process, compare exact immutable facts, absolute
   cooldown/backoff, periods/charges and generation before/after. Late old result
   cannot publish; late receipt can close only its own hold. Duplicate/hash pin
   conflicts and Remove during publication retain existing 010/011 behavior.
8. **Retention boundary.** Observer restart with intact same-boot witness can
   replay only known evidence. Guardian death/boot change/restore remains blocked;
   a new empty cgroup or recreated spool is refused. Test cleanup removes only
   fixture-owned settled resources, retains uncertain evidence and never performs
   production orphan deletion.

Keep fixture evidence numeric/identity-bound and small, alongside exact source,
runtime, SQL and policy hashes. No actual arXiv, Storage, Mathpix or paid-provider
request is necessary for these local schedules.

## Implementation order and remaining decisions

The isolated `OriginalSpool` prerequisite passes the file-mechanics checks
below, and candidate 013 passes the local SQL authority, role, envelope,
concurrency and populated-upgrade checks. Separate portable source/upload/
stored-read components now implement the binary handoff described below. The
portable receiver connects that handoff to the frozen parser and records actual
direct-child rusage. The separate Linux verifier fixture now passes paused
cross-UID execution, paired waits, failure retirement and restart denial. Next
finish the admitted host policy and durable SQL/action ordering. Combine them
in one opt-in disposable-PG/loopback fixture before any hosted credentials or
outbound switch is considered.

The remaining substantive admission decisions are the exact Linux verifier
process/thread and enforcement policy, the reviewed Storage success/
read-settlement response schema, and the actual narrow deployment/credential
binding. They block positive live admission, not isolated spool or SQL work.
Existing cloud-account selection and an approved fixed/variable budget are needed
for hosting; this proposal creates neither a hosting dependency nor a Mathpix
charge during local development. It intentionally leaves ambiguous remote writes
reserved rather than broadening this milestone into a general recovery service.

## Verified isolated spool checkpoint — 2026-10-04

Independent structural review cleared the proposal at source SHA-256
`1cce98d6323948fc1058ea81e077bbd08fdc3af19feca7e4b9e13cf65887f3de`, before
this implementation-status addition. The implementation is
[`original_spool.py`](../../workers/source-gateway/linux/original_spool.py),
with independent source review clear at SHA-256
`7efcdb48db4833360f6f062172fc4aa3c3cf3db76c012d73541069bdcf5300df`.

The actual API is a guardian `OriginalSpool(root, SlotIdentity)` context holding
the reservation lock, `prepare(validate_allocation)` returning one producer
directory FD, and a separate `Producer(fd, Binding)` with `append`/`finish`.
`seal(binding, completion, validate_retirement)` returns canonical descriptor
bytes. `open_sealed(descriptor, validate_reader)` yields a read-only FD inside
the same locked context. `capture_cleanup(binding, validate_retirement)` produces
the exact partial/complete inventory; `retire_slots(capture, validate_settlement)`
requires that inventory's durable external intent and performs replayable exact
deletion. Validator arguments are owned copies; validators must raise on
uncertainty and return `None` on success. They have no permissive defaults.

All **26 portable tests pass**. They cover the exact 5 MiB limit and one byte
over, short writes/disk-full, incomplete/mismatched transfer facts, owned inputs,
eight interrupted publication boundaries, partial-descriptor quarantine,
actual writer-process exit and fresh-process recovery, changed/replaced/truncated
files, refused reader/retirement validators, writable ancestry/symlinks/FIFO/
alias/namespace violations, close errors with reused FD numbers, read-only access,
seven simultaneous alias names, producer unlink followed by restart, and cleanup
replay at five boundaries including one removed hardlink alias and a failed final
directory barrier. Recovery uses the same guardian payload inode. The producer
has no append/restart API for an existing file. A conflicting accepted descriptor
or payload is never overwritten.

The complete portable Linux-worker discovery run is **205 total, 189 passing,
16 Linux-only skips** on the Mac. The first broad invocation omitted the existing
gateway `PYTHONPATH` and could not import `test_metadata_bridge`; the documented
command below passes. Both logs are retained under `.artifacts/`:

```sh
PYTHONPATH=workers/source-gateway:workers/source-gateway/linux python3 -B -m unittest discover -s workers/source-gateway/linux -p 'test_*.py' -v
```

Evidence: `.artifacts/original-spool-linux-portable.log` and
`.artifacts/original-spool-summary.json`. The tests use synthetic payloads and
**injected trusted-validator boundaries**, not real retirement, reader intents,
SQL authority, Storage settlement or physical disk reservations. The module is
not in the frozen metadata bundle and grants no network or parser access.
No original SQL migration, live acquisition, Storage upload, verifier host
admission, Mathpix request, Linux VM restart or physical-phone action occurred.

## Verified disabled SQL checkpoint — 2026-10-04

[`202610040013_original_execution.sql.pending`](../../supabase/migrations/202610040013_original_execution.sql.pending)
implements the additive SQL contract at SHA-256
`e41d5ed45894e213ebfb247e5aaf53374786a3af760481ffcbc71cf1e49f4c06`.
It is an explicit local candidate, not a hosted migration. Applied 001–011 and
pending 012 are unchanged. No login is created; no worker or read switch is
enabled by the migration.

The only installable original policy is `original-loopback-scope-v1`, and its
profile is `original-loopback-verifier-v1`. Both require `local_fixture_only:true`.
Verifier reports require the `synthetic-sql-fixture` host-evidence kind. The
profile's legacy measured-shaped columns do not establish a measured host;
production admission needs a separately reviewed policy/installer extension.
Changing a fixture boolean cannot turn this checkpoint into live authority.

Disposable PostgreSQL 18 checks cover the complete synthetic download → upload
→ stored read → verification → publication → account library projection. The
resulting library entry is `pdf_ready`; the import request itself is `ready`.
The maximum chain uses two downloads, one upload, two stored reads and one
verification. All eight steps, six attempts, eleven resource receipts, one
reservation and two result allowances fit the prepaid 28-slot envelope, even
when no capacity remains for a new command. Unknown transfers retain their
ceiling; a positive stored read can shrink the storage reservation only after
upload settlement. Shared publication still uses 011's exact-byte document and
approval rules.

The same checks exercise closed policy/profile and binding schemas, actual
digest/version/deadline/NULL constraints, descriptor canonical hashes and inode
separation, immutable candidates and policy pins, cross-kind and caller-role
denials, verifier limits, and stored-byte mismatch quarantine. Exact grant,
receipt, result and publication replays allocate or charge nothing extra.
The unchanged metadata SQL and concurrency suite passes after 013.

Three accounting cases insert explicitly synthetic historical chains without
editing an issued immutable attempt. Real role APIs then settle or expire them:
source/read refunds affect only the captured old month, source request days stay
in UTC under a non-UTC session, and unresolved upload/read liabilities count once
toward new-period admission. One-byte-short and exact-cap cases distinguish a
missing or double-counted liability. Logical failure and retirement retain the
holds; late receipts cannot revive the result or release stored-byte capacity.
These seeded histories do not prove a real historical execution.

Twelve original concurrency groups use observed database blockers, including a
bounded traversal through tuple-lock queues. They cover duplicate prepare/grant
and closure, a shared metadata/PDF gate, cancellation and policy changes during
admission, library/FK publication order, durable projection catch-up, simultaneous
exact-hash publication, conflicting approval pins, expiry versus result, unknown
upload settlement, and late closure during authority retirement. Five populated
upgrade groups verify disabled-state preflight and byte preservation of every
existing private-table column through 012→013, including v1/v2 metadata behavior
and refusal to adopt an unissued legacy original.

Restore quarantine now conditionally clears original admission with the other
switches, retaining epoch, policy pins, immutable receipts and resource holds.
All 13 restore tests pass, including an actual 013 schema with a retired executor
and unresolved source connection. The final complete database run passes in
43.250 seconds: the legacy 001–011 suite, metadata before/after 013, the original
SQL/accounting/concurrency suite, and populated upgrade checks. Source hashes
are unchanged throughout that run. Evidence is
`.artifacts/original-execution-final.log`,
`.artifacts/original-restore-quarantine.log`, and
`.artifacts/original-execution-summary.json` (SHA-256
`478ac142bfef72599c2e040641587c206bf445296060694905a3809479321108`).

Reproduce the explicit candidate checks with:

```sh
python3 scripts/test-database.py --candidate supabase/migrations/202610030012_metadata_execution.sql.pending --original-candidate supabase/migrations/202610040013_original_execution.sql.pending
python3 -m unittest discover -s tests/operations -p test_restore_quarantine.py -v
```

These tests submit synthetic process, transfer, file and host facts. They do not
connect `OriginalSpool` to SQL, fetch a PDF, contact an object service, run the PDF
parser, or demonstrate actual cgroup retirement. The Linux integration and
measured host evidence above remain required. No hosted state, provider, VM or
physical device was changed for this checkpoint.

## Portable original transfer boundary — 2026-10-04

[`original_transport.py`](../../workers/source-gateway/linux/original_transport.py)
implements separate source GET, object POST and stored-object GET actions against
numeric loopback TLS fixtures. Its closed input carries the exact 21-field
stage-request shape and an opaque PostgreSQL request hash; re-encoding the request
in Python does not recreate that SQL hash. The wrapper validates shape and local
binding, not a committed SQL grant. No live destination, resolver, proxy,
credential, redirect, retry or PDF parser is available in this component.

GET bodies leave through one nonblocking binary pipe in chunks of at most 64 KiB.
They are capped at 5,242,880 bytes, with a separate 6,291,456-byte received HTTP
plaintext ceiling. That ceiling excludes TLS framing/handshake and kernel traffic;
it is not billable network accounting. The shared strict HTTP parser retains its
16 KiB header, 64-field and 64 KiB aggregate chunk-line limits. Its new per-instance
protocol limit defaults to the existing metadata value of 2 MiB. Metadata's 1 MiB
body/base64 envelope and journal ceilings are unchanged.

One absolute shared clock deadline bounds handshake, socket reads/writes and
nonblocking pipe writes. Content-Length totals are checked explicitly after all
bounded reads; the standard library can otherwise return a short final read
without raising. Chunked success requires the final zero chunk, and a
close-delimited body requires clean TLS EOF. Partial/empty/non-200 transfers cannot
finish a PDF spool. Unsupported Retry-After remains a distinct classification,
not an assumed safe zero cooldown. The future SQL adapter must retain its hold.

POST consumes one borrowed, read-only regular FD. After GO and before any request
byte, it checks size, hashes offset-independent reads and checks stable file
identity. The upload sends fixed Content-Length with no overwrite; it checks the
stream hash and file identity again. Only a complete bounded 201 response with the
fixture's exact attempt/request/bucket/path/hash/length/committed ACK can succeed.
Raw ACK data is capped at 4 KiB and replaced by its digest in the small control
result. `sent_bytes` counts chunks whose `sendall` returned successfully: it is a
diagnostic lower bound after failure, and zero never proves a POST did not reach
the server. Missing or mismatched ACKs remain uncertain even when the fixture has
committed the object. This ACK schema is deliberately **not** presented as
Supabase Storage's response or a hosted settlement policy.

[`original_session.py`](../../workers/source-gateway/linux/original_session.py)
captures exactly four child modules (`protocol`, `transport`, `original_transport`
and `original_child`) into a private bundle before spawning. Its loader executes
the captured, verified bytes with isolated Python imports; READY binds input,
bundle and process. GO binds the same attempt and absolute deadline, is consumed
before the first send, and must be followed by control EOF. The child receives
only the binary write pipe or read-only upload FD, never a spool directory.
Network and upload payload reads wait for GO.

The session concurrently drains binary/control/stderr, counts and hashes binary
bytes, and forwards bounded chunks to the caller's `Producer`. A valid control
result is insufficient: complete GET needs binary EOF, matching count/hash, and
an actual wait for that exact child. Upload completion also requires its exact
child wait. IPC cleanup is a separate reported fact. A close error keeps that
fact uncertain even after the child has been waited; detached raw FD numbers are
never retried because the OS may already have reused them. Still-open file
objects remain referenced for later cleanup, and every independent close is
attempted. Such cleanup uncertainty prevents candidate completion. A framed
non-200 response may retain status/accounting facts while
the session reports no candidate. The session never calls `Producer.finish`,
seals, cleans up slots, releases a SQL hold or starts a successor on its own.
Cancellation/append failures leave the caller's partial spool available for
later reconciliation. Deadline checks around caller append do not constitute
an OS bound on arbitrary filesystem/callback latency.

The fixture [`original_tls_fixture.py`](../../workers/source-gateway/linux/original_tls_fixture.py)
models one immutable object, at most sixteen connections and bounded request
observations, including commit-before-lost-ACK, mismatched ACK, truncated readback
and changed readback bytes. Separate actual child processes can exercise
download → producer completion → guardian seal → read-only upload → acknowledged
local cleanup → fresh stored-readback allocation → seal/hash comparison. The
portable spool validators and request predecessor facts are explicitly synthetic;
they are not trusted Linux/SQL/remote-writer proofs.

The bundle identifies the Python executable and records Python/TLS versions. It
does not measure or pin every OS/stdlib/TLS dependency, admit a Linux sandbox,
observe cgroups, or implement guardian-death recovery. The parent coordinator is
also still a portable component, not an admitted frozen execution recipe.
Changing shared `transport.py` gives newly captured metadata recipes a new
identity. Previously retained metadata bundles and their evidence are unchanged;
they do not admit the new recipe. A new combined Linux runtime check is required
before admitting it. Candidate migrations 012 and 013 remain unhosted.

### Verified portable checkpoint

All **48 new transport/session tests pass** on both Python 3.9.6/LibreSSL 2.8.3
and Python 3.13.3/OpenSSL 3.5.0. The full Mac Linux-worker discovery run is
**253 total, 237 passing, 16 Linux-only skips** in 12.920 seconds. The existing
31 metadata transport/coordination regressions pass on both runtimes. The
Python 3.13 core run combines those 31 with the 30 new transport tests; its
18 session tests run separately.

The tests include exact-limit streaming/upload, multi-read truncation, missing
chunk termination, blocked/broken sinks, mismatched and oversized ACKs, changed
upload inputs, final close errors, malformed control types, no pre-GO work,
tampered captures, cancellation/disk-full retention, EOF without a result,
a result without process retirement, and reused descriptor numbers after a close
error. The maximum-size workflow uses three actual children and connections,
compares the sealed readback to the fixed candidate, and refuses fresh readback
allocation while the source slots still exist. Independent reviews corrected
control validation and close-error ownership; the initial session run also
needed two missing test-owned spool base directories to be created explicitly.

Reproduce the complete portable run with the command in the isolated-spool
checkpoint above, or run just the two new modules:

```sh
PYTHONPATH=workers/source-gateway:workers/source-gateway/linux python3 -B -m unittest test_original_transport test_original_session -v
```

Evidence is `.artifacts/original-transfer-summary.json` (SHA-256
`d23b86056e326fb29f5a75d41ff39d58480d23cb24e467e83bfaa10afa78051e`),
the five logs it identifies, and retained reproduction bundles under
`.artifacts/original-transfer-bundles/`. The summary verifies unchanged source
hashes through the final test window and all thirteen applied/pending migrations
equal to the prior commit. The existing spool implementation is unchanged.
No database, hosted service, provider, VM or physical device was changed for
this checkpoint. SQL/guardian integration, measured verifier execution and
real Storage response/settlement admission remain required.

## Portable verifier receiver — verified 2026-10-04

[`original_verifier.py`](../../workers/source-gateway/linux/original_verifier.py)
and its captured `.mjs` entry point connect the stored-readback spool to the
unchanged `39980de…` parser. The local TLS/spool test now completes download →
upload → source-slot cleanup → fresh stored readback → seal → actual PDF parse,
returning the exact 610-byte fixture hash and one resolved page. Its guardian
callbacks and SQL-shaped request facts remain explicitly synthetic. There is
no database publication, real Storage response or paid provider submission.

The receiving interface deliberately separates pre-grant and post-grant IDs:

```text
capture_verifier_bundle(parent, exact_build_id, exact_deno_path)
VerifierSession(bundle, input, input_fd=sealed_readback_fd)  # READY only
go(execution_id, binding_sha256, absolute_deadline_ns)       # once, then EOF
finish()                                                  # result + wait4 facts
```

The closed input binds the verifier claim, exact 21-field `original_verify`
request, opaque SQL request hash and canonical raw spool descriptor. The
descriptor's **claim** matches the predecessor operation; its execution attempt
is a different identity. The complete descriptor digest, reservation, purpose,
candidate hash/length and frozen build/profile must match before spawn. The
grant-generated execution UUID first appears in GO. These comparisons validate
the local handoff; they do not establish that SQL committed a grant.

Deno receives an already-open read-only regular file as stdin, with a separate
small inherited pipe for control. No spool pathname or directory is passed.
The parent owns a duplicate FD, checks its sealed inode, read-only access, exact
size, stable metadata and zero initial offset, and retains it until exact child
retirement. The duplicate shares the caller's file offset: the caller must keep
the spool lock/reader context and must not seek/read that FD concurrently.
READY leaves the offset unchanged. GO and control EOF precede PDF reads,
parser imports and WASM compilation. Input is bounded at 5 MiB, read in at most
64 KiB pieces with an exact-length EOF probe and a complete hash check before
parser import. An unlinked read-only file works in the actual Mac probe; a
regular `/dev/fd` reopen is not used as a substitute for inherited stdin.

[`original_verifier_bundle.py`](../../workers/source-gateway/linux/original_verifier_bundle.py)
first validates the full original build, then captures unchanged `runtime.ts`,
`wasm.ts`, generated glue/WASM, profile and identity plus the new receiver.
The private directory is mode 0500 and its eight files, including the manifest,
are mode 0400. The manifest binds every file and the selected executable's exact
identity/hash; aliases, unexpected files and changed identities are refused.
The original full build/library remains untouched. The wrapper has no static
imports and uses computed URLs into the capture only after GO and PDF hashing.
No working-tree, `current-build.json`, `dist` or smoke-test loader is an import
source. Filesystem modes and prelaunch checks trust the current owner; they are
not protection against a hostile owner/root swapping files between checks.

The actual runtime is Deno 2.9.6, SHA-256
`b3ac3bd206e48c26026cadd80c1367e96c149f9c66130952382a642b09fa8a71`.
The npm executable had two hardlinks, so an identical, separately owned
80,915,104-byte copy was made under the project's ignored tools directory; no
runtime was downloaded or installed globally. The child has an explicit minimal
environment, disabled config/lock/npm/remote imports/code cache and denied
network, environment, subprocess, FFI, write and system-info permissions. Its
read allowance covers only the private code capture and fixed control-pipe
alias. `DENO_DIR` points to the mode-0500 capture; actual execution leaves its
exact inventory unchanged. These are local capabilities, not Linux OS isolation.

[`wait4_child.py`](../../workers/source-gateway/linux/wait4_child.py) is the sole
reaper for the exact retained `Popen` child. It never calls the Popen polling,
waiting or signaling helpers, which could discard rusage. Actual terminal wait
status is retained even when metrics are invalid; missing wait authority forbids
signaling and leaves the owner retained under a finite 32-owner admission cap.
Signals and waits serialize through that owner. Raw user/system CPU and peak
RSS retain their native units (Mac bytes, Linux KiB), with conservative derived
CPU milliseconds and process-peak bytes. These are **direct-child** facts only.
`spawn_to_wait_wall_ms` includes runtime startup, loading, compilation and input
handling through the parent's observed wait. Frozen `elapsedMS` is still only
the parser-call measurement; neither value is relabeled as the other's metric.

The independent parent deadline watcher can kill synchronous WASM even while
the caller is not draining output. The child also makes cooperative relative
time checks; it never compares `performance.now()` to the parent's absolute
kernel clock. A finite bound result, exact successful wait4, valid rusage,
stdout/stderr EOF, stable input and successful IPC cleanup are all required.
Cancellation/deadline checks also guard final acceptance. Cleanup attempts every
independent handle, never retries a possibly reused raw FD number, and retains
uncertainty after close errors. Startup/watcher failures retain the exact owner.
No failure retries parsing, releases a SQL hold or deletes the caller's spool.

All **52 new checks** pass on Python 3.9.6 and 3.13.3. Full portable discovery is
**305 total: 289 passing, 16 Linux-only skips** in 21.891 seconds. The second
runtime's focused 52 checks pass in 9.507 seconds. Tests include the actual
four-stage journey, one/50-page success, 51-page refusal, encrypted/corrupt/
unsupported PDFs, decoded-stream exhaustion and object-stream OOM followed by a
fresh successful instance. The retained CLIP paper verifies as 16 pages; the
near-limit FlashAttention paper retains its parser-resource refusal. Both paper
hashes/lengths are checked against the tracked local-only corpus manifest.
Malformed/BOM/duplicate control, missing EOF, wrong identities/hash, delayed
exit, active watchdog termination, unavailable rusage, result-number encoding,
late cancellation, watcher failure and actual FD reuse are covered. Independent
review corrected those lifecycle and cross-language JSON boundaries before the
final runs.

Evidence is `.artifacts/original-verifier-linux-portable.log`,
`.artifacts/original-verifier-python313.log`, the retained capture/direct-child
proof and `.artifacts/original-verifier-summary.json`. Reproduce on this Mac:

```sh
PYTHONPATH=workers/source-gateway:workers/source-gateway/linux python3 -B -m unittest test_wait4_child test_original_verifier_bundle test_original_verifier -v
```

`TIMESTEP_VERIFIER_DENO` can select an explicit private ordinary runtime file for
the receiver tests. No Linux/cross-UID runtime check, cgroup/thread admission,
whole-supervisor RSS/CPU measurement, guardian-death recovery, SQL result adapter
or real Storage settlement is established here. In particular, pending 013's
synthetic-only host-evidence schema cannot accept these local observations;
they must not be relabeled as synthetic evidence to obtain publication. Applied
001–011, pending 012/013, the parser/profile and hosted switches remain unchanged.
The VM stays stopped and physical iPhone work remains paused.

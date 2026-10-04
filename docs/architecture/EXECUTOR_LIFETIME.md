# Executor lifetime and external-operation settlement

Status: **reviewed additive contract; metadata-only local candidate verified,
not deployed or admitted**. Reviewed against
immutable migration `202610030011_acquisition.sql`, SHA-256
`30c2db5b6d1211dac4ccbbd93b732fb747a6dddcb06ceefc9970ba3bc3a09f03`.
All acquisition, verification and original-read switches remain disabled. This
document changes neither those switches nor 011. The disabled local candidate is
`202610030012_metadata_execution.sql.pending`; applied SQL remains immutable.

## Decision and present gaps

Keep useful-work authority, result-reporting authority and resource occupancy
separate. An expired or rejected claim stops a result from publishing; it does
not prove that its executor, socket or remote write has stopped. Record the latter
explicitly and keep its capacity reserved until there is adequate evidence.

The current [acquisition contract](ACQUISITION.md) already records the verifier
lifetime blocker. The concrete 011 paths needing correction are:

1. `worker_claim_original_verification` does not extend reservation `safe_after`.
   A claim immediately before the reservation's 24-hour expiry can overlap
   `worker_claim_original_orphans`, even while its reporting lease is live.
2. A verification result, integrity failure or `input_unavailable` clears the
   verification lease. The last route permits another attempt after 30 seconds.
   Neither a negative result nor an aborted input read proves resource retirement.
   Scans and the active-reservation count must not free occupied execution capacity
   because a row became quarantined or its reporting lease expired.
3. `worker_claim_arxiv_stage` reopens an unclosed source gate after the installed
   hard deadline. The 450-second value is an assumption awaiting admission, not
   evidence about every deployed executor or the source-facing connection.
4. Original upload recovery and orphan deletion use `safe_after` plus an absence
   observation. A request accepted by Storage can outlive its client. Killing
   that client, then observing absence and deleting/releasing the path, does not
   exclude a later server-side commit recreating the object.
5. The original-read grant bounds and charges one range, but its 120-second expiry
   is not an acknowledgement that its input read or client response ended. The
   current deletion of old grant receipts must not delete outstanding holds.

No new mutable document identities, account-history events, OCR credit semantics
or library cursor protocol are required. Existing immutable claim/results,
no-overwrite paths, verification profiles, transfer ceilings and library
availability projections remain useful.

## Minimal records

Use finite relational records, not a heartbeat log or an arbitrary workflow
engine. Names below are the proposed public contract for implementation review.

| Record | Required meaning |
|---|---|
| `executor_policies` | Immutable, size-bounded policy and SHA-256. Bind runner/build, host/runtime configuration, allowed operation kinds, resource-specific closure semantics, maximum useful/reporting durations, concurrency bounds and any admitted external enforcement bound. A runtime version or an experiment result is not such a policy. |
| `executor_authority` | Small capacity/authority mutex with the current project/environment and random activation epoch, active policy references, disabled-by-default admission, configured limits, and a restore/recovery block binding any unresolved predecessor epoch. Retiring an epoch stops grants without clearing old occupancy. |
| `execution_attempts` | One immutable identity per accepted external attempt. Acquisition/verification attempts may reference their retained immutable job/step identities; original reads use the detached snapshot below. Retain grant digest, epoch, policy, job/reservation/object identity where applicable, claim generation, exact executor binding, useful deadline, report deadline and required resources. Replays never return execution permission. |
| `execution_quiescence` | At most one immutable final receipt per attempt and required resource. Bind evidence ID/digest, kind, exact attempt/executor identity, bounded evidence fields and database acceptance time. No free-text logs, secrets, raw document content or unbounded diagnostics. |

The closed operation kinds are initially `atom`, `license`, `download`, `verify`,
`original_read`, `object_probe` and `orphan_delete`. Required resource kinds are a finite set:
`executor`, `arxiv_connection`, `object_read`, `object_write`, and `object_delete`.
The claim RPC determines them; the caller cannot omit a hold. A download reserves
both its source connection and its potential upload before starting. A verifier
reserves its executor and stored-object read. A read proxy reserves its executor
and Storage read, including the lifecycle of its outgoing response in the
executor's closure protocol. Pure SQL publication/projection needs no external
attempt.

### Original reads survive account and receipt deletion

An original-read attempt must **not** have an FK to `accounts`, `library_items`
or the `(day, account_id, operation_id)` read-grant key. Both a cascading FK that
erases a hold and a restrictive FK that obstructs account deletion/day pruning
are wrong. Instead, admission stores a detached immutable snapshot of object ID,
object SHA-256 and byte length, first/last byte, charged ceiling, charge period,
charge kinds, epoch, policy and deadlines. The retained object identity may be
referenced; it is independent of account/library deletion.

Bind the originating authorization with a domain-separated SHA-256 of a canonical
tuple containing project, epoch, account UUID, read day, operation UUID, item UUID,
existing request digest, object identity and range/ceiling. Store the digest, not
new copies of raw account, item or operation IDs. The random operation identity
helps avoid a bare account-ID hash. This is a pseudonymous integrity binding,
**not** an authentication credential or a claim that the ledger is anonymous; no
new HMAC key-management dependency is needed. Account-window identity, if needed
in the charge snapshot, is likewise bound by digest rather than duplicated as a
raw UUID. Existing transfer accounting remains unchanged and is never refunded
merely because an account or read receipt disappears.

The short-lived read grant may reference the durable attempt ID in the **grant →
attempt** direction. Deleting that grant then leaves the attempt and its holds
intact. Exact grant replay remains status-only; after grant pruning, old-day
requests still cannot obtain new authority. State lookup and late quiescence
operate on the attempt ID and authenticated executor binding, without reloading
the account or deleted read grant. Admission inserts the snapshot, resource holds,
charges and grant in one transaction under the normal read-account lock. Global
capacity and observer/GC decisions inspect retained attempts, never a join whose
account cascade can silently remove occupancy. Test both account deletion and
old-day pruning with a deliberately outstanding read.

Keep a separate nullable `reclaim_not_before` **per required resource**. A nonnull
value must be derived by SQL from the attempt's immutable admitted policy and
recorded binding. It is not supplied by the worker, inferred from a timeout, or
shortened by changing today's active policy. NULL means no automatic time-based
reclaim. Even a nonnull value only permits the particular policy's retirement
procedure; do not treat a generic timestamp comparison as evidence for every
resource. The conservative first implementation supports explicit receipts only.

Executor binding contains project, authority epoch, function/service identity,
deployment/configuration identity, platform execution identity when available,
and a fresh attempt identity. An isolate may serve multiple requests: its ID
alone is not the attempt ID. The runner obtains a grant from inside the already
identified owning invocation; there is no transferable permit for a later
unidentified executor. No authority is inferred merely from fields supplied in
JSON. Narrow credentials and the reviewed deployment establish who may assert
each evidence kind.

For acquisition jobs, reserve the **entire finite history envelope at job
preparation**, under the existing policy → job admission order. It includes
maximum execution attempts, their resource receipts, upload arming, bounded
reconciliation probes and deletion completion. Later grants consume job-held
slots; they do not call `acquisition_admit` or acquire the policy lock after a job
lock. There are at most five resource receipts per attempt, with the actual
smaller set fixed at admission. Preserve completion/deletion headroom and bounded
transfer history while recomputing 011's slot/control-byte admission formulas.

Detached original reads and published-object probes use a separately bounded
history pool serialized by `executor_authority`; each grant reserves its full
attempt/terminal-receipt envelope before I/O. The migration divides the approved
control-byte ceiling between job envelopes and this fixed detached pool. Existing
policy/profile admission deducts the fixed pool reservation, not its fluctuating
usage, and never needs the authority lock. Resizing that split is a separate
disabled-maintenance operation with authority → policy order; it is not an
automatic grant-time top-up. A readonly gate wait creates no row, generation, charge
or retry consumption. Unknown attempts consume outstanding capacity across day
and month boundaries. Closed history also has a cap; exhaustion blocks new work
rather than deleting fences. Do not cascade global holds away on account deletion.
Admission must include unsettled external-transfer liability from older windows;
retaining an old receipt alone must not make that liability disappear when a new
period starts. Keep the original receipt period immutable rather than rewriting
history to implement this carry-forward check.
The existing `slots_held <= 24` bound is not assumed sufficient: derive the new
reservation from each job's finite attempts and resource receipts, and migrate
that check together with the control-capacity calculation. Do not increase
monetary, transfer or concurrent-work allowances merely to fit audit records.

## Proposed API behavior

Add versioned grants rather than giving an old caller new authority it cannot
honor:

```text
worker_claim_arxiv_stage_v2(job, claim, environment, executor_binding, reservation?)
worker_prepare_original_upload_v2(attempt_id, operation, sha256, byte_count)
worker_claim_original_verification_v2(reservation, claim, executor_binding)
worker_authorize_original_read_v2(account, item, operation, day, range,
                                  executor_binding)
worker_claim_object_probe_v2(object_or_reservation, operation, purpose,
                             executor_binding)
worker_claim_original_orphan_v2(reservation, operation, executor_binding)
worker_execution_state(attempt_id)
worker_scan_unsettled_executions(after_attempt_id?, limit=50)
worker_executor_authority_state()
worker_record_execution_quiescence(attempt_id, evidence_id, resource,
                                    evidence_kind, bounded_evidence)
```

The exact argument digest includes the immutable binding and all existing
operation arguments. A fresh admitted claim atomically reserves existing quota,
execution capacity and every resource hold; it returns `granted:true` once, plus
the attempt ID, deadlines and fixed resource identities. A replay, lost grant
response or status query never reissues permission. A grant whose useful deadline
has elapsed must not start outbound work. The current worker must stop on policy,
epoch or binding mismatch. Cancelling one account's import only retires its
interest under 011; it cannot cancel another account's shared work. An explicit
executor/authority retirement, or no surviving global interest under existing
rules, may revoke future result authority and request stop. None fabricates a
quiescence receipt.

After a download has been completely hashed but before any upload POST,
`worker_prepare_original_upload_v2` freezes the candidate hash/length against the
already-reserved path, executor and write hold. It returns one-use write authority
only on the fresh transition, within the current useful deadline; exact replay is
status-only. Loss of this response permits no upload. Candidate identity must not
be reconstructed later from whichever bytes happen to occupy an uncertain path.
This bounded substep consumes pre-reserved receipt headroom, not another arXiv
request or an unmetered retry.

`object_probe` is the only proposed online reconciliation/recovery read. Its
purpose is one of `upload_reconcile`, `original_recovery`, or `delete_confirm`;
SQL derives the fixed target and permits only the reviewed bounded HEAD/GET
needed for that purpose. Claiming it reserves an executor/read hold, the maximum
allowed response/transfer charge and receipt headroom before I/O. Hash-based
recovery uses a complete bounded read, never HEAD metadata as a content digest.
A stalled/aborted probe remains held just like another read. Existing availability
recovery and delete-confirmation routes must require its exact result/evidence,
or remain disabled. The evidence observer cannot bypass this grant by fetching
Storage inside its quiescence callback; no caller-supplied URL is accepted.

The unsettled scan is a bounded, readonly keyset scan ordered by immutable attempt
ID, with `1 <= limit <= 100`. It returns pending resource kinds and necessary
public routing/binding identities, not object credentials or raw account identity.
It is independent of job status, account existence, current epoch and all lease
deadlines, so failed/no-interest/completed jobs and pruned read grants cannot hide
holds. After a full pass the reconciler restarts from the beginning to discover
new IDs inserted behind its cursor. It allocates no receipts, changes no state
and does not itself permit I/O. The separate bounded authority status exposes a
restore/predecessor recovery block even when there are no surviving attempt IDs.

Result RPCs receive an attempt ID and retain existing exact replay, generation,
profile, hash and byte checks. Logical results and quiescence are independent:

- A valid result can be durably recorded while cleanup remains unresolved.
  Publication, another attempt and resource reuse wait for their required holds.
- A trusted normal completion may record its result and already-established
  quiescence atomically. It cannot close an outstanding resource by assertion
  merely because it has a result. Parsing return is not remote-upload settlement.
- The quiescence RPC is allowed after the useful/report deadline, cancellation,
  policy disable or claim replacement. It can close **only the named old
  attempt's resource**. It cannot accept an expired result, publish, advance the
  job, clear another attempt or revive an epoch.
- An evidence ID replay requires the same digest. A new evidence ID for an
  already-closed resource returns its existing receipt without replacing it or
  allocating a new history row. Contradictory facts are an operator-visible
  integrity error. An operator cannot override that with a bare `force=true`.

SQL does not verify arbitrary platform logs. A narrowly authorized observer
normalizes and authenticates the evidence, checks the deployment/attempt mapping,
and submits the allowed scalar fields plus an immutable evidence-artifact digest.
The runtime role can submit only normal resource-completion evidence permitted by
its policy; it cannot claim a supervisor event or admit a new policy. An observer
has no result/publication authority. A separate operator manages admissions and
epoch retirement. None of these roles is granted to customers.

## Evidence that can release a hold

| Resource | Sufficient only under its admitted adapter/host contract | Insufficient by itself |
|---|---|---|
| Executor | Trusted wrapper has ended this attempt, released parser/input resources, joined all of its tasks and made its attempt token permanently unusable; or an authenticated supervisor confirms termination of the exact owning execution/process | HTTP response, `waitUntil` registration, an exception, an expired lease, `beforeunload`, deleted function, absent log or another execution's shutdown |
| arXiv connection | The admitted controller confirms retirement of every exclusively owned source socket, connection task and future start capability; the contract must cover any owned gateway/proxy hop too | Complete response body alone, cancel requested, local client object dropped, isolate termination without an admitted ownership/teardown contract, or a 450-second timer |
| Object read | The bounded read reached complete EOF and its owning transport is retired, or the admitted read controller confirms cancellation/closure with no continued remote transfer | Local abort request, incomplete digest, expired read URL/grant or CPU termination alone |
| Object write | A final completed upload response under a reviewed synchronous-commit contract, or reconciliation proves the unique immutable write committed/terminated under the storage service's operation/visibility contract | Killed executor, closed client socket, upload timeout, a single HEAD/GET returning absent, or a DELETE acknowledgement while an old write can still commit |
| Object delete | All possible writers/readers are already retired; the fixed never-reused path is then confirmed absent under the storage contract | Absence observed while an older writer remains uncertain |

These are attempt-scoped guarantees. The wrapper need not kill an otherwise idle
host isolate after a normal successful attempt if its reviewed code can prove
that attempt has no remaining task or resource and cannot start again. Conversely,
a self-written `stopped:true` without that lifecycle contract proves nothing.

For arXiv, record closure and byte accounting separately. A proven close with
unknown complete bytes may release the connection while retaining the full
issued transfer ceiling; it must not invent an exact byte count or a complete
body. Start the next request no earlier than database receipt time plus three
seconds and any longer `Retry-After`. The receipt time is deliberately conservative
relative to an earlier actual close. The proposed direct-transport policy below
defines retirement of controlled socket ownership, not termination of arbitrary
work on the source server or acknowledgement of every TCP teardown packet. An
unretired proxy-owned upstream socket is outside a direct-child exit proof. If
the admitted ownership scope cannot be established, leave the gate held; do not
silently relabel the requirement as “one JS fetch at a time.”

For uploads, distinguish settled from uncertain immutable bytes. Do not retry or
delete the same path merely because the old executor ended. A matching complete
object can settle a lost upload acknowledgement only when the reviewed Storage
contract establishes that visibility means that unique request finished its
write and cannot write again later. An observed mismatch is quarantine. An absent
object with an unresolved server-side operation stays uncertain. If Storage has
no suitable final-operation or cancellation proof, leave the path and its full
reserved bytes charged. A separately admitted new attempt may use a fresh path
only if both retained old occupancy and new worst-case capacity fit. Never reuse
a deleted or abandoned reservation path.

## Claims, reuse and garbage collection

Use one shared **action-specific** SQL readiness helper, consumed by claims,
scans, publication, capacity accounting, orphan claim and delete confirmation.
It checks relevant predecessor holds rather than only the latest claim or
`safe_after`; it does not make every resource wait for every unrelated resource.
There is no side door through a legacy claim or active-count query.

| Action | Required settled scope, in addition to normal identity/quota/interest checks |
|---|---|
| Next arXiv request | Prior `arxiv_connection` plus cooldown. That download's independent upload may still be active; execution-capacity admission is checked separately. |
| Release execution concurrency | This attempt's `executor` only. An uncertain remote write still retains its own bytes/path/operation occupancy. |
| Start/retry verification | Prior verifier executor/read for this verification scope and all possible writes to the candidate; no deletion fence. An unrelated object's work does not block it. |
| Publish this verified candidate | Valid current verification result, its verifier executor/read closed, all candidate writes settled, no deletion fence. This does not release other attempts' capacity. |
| Retry an upload | All predecessor write/start capabilities for this path retired, exact frozen candidate and the storage service's safe retry/absence contract; no deletion fence. |
| Claim orphan deletion | All predecessor readers/writers and their future I/O-start capabilities for that path retired; atomically set the deletion fence and create the deletion attempt. |
| Confirm that deletion | Same deletion fence/generation; all predecessor readers/writers remain retired; accept this deletion's own terminal evidence and proved absence atomically. Do not wait for its own `object_delete` receipt before allowing that receipt to commit. |
| Release reserved object bytes/count | Confirmed deletion, no unresolved predecessor writer/read authority, and its deletion operation settled. Executor capacity is accounted independently. |

A verifier that starts close to reservation expiry holds the object until its
read and executor are quiescent. Expiry may prevent publication but cannot make
that object reclaimable. `input_unavailable`, structural rejection, resource
failure, timeout, cancellation and lost responses all retain unresolved holds.
Retry delay and retry allowance are additional conditions, not substitutes.

Canonical exact-byte reuse still requires 011 verification/profile/availability
evidence. A duplicate upload that loses publication remains a separate physical
reservation with its own outstanding holds and bytes. Reusing the winner does
not erase the loser's cleanup obligation. A valid existing canonical asset can
be read without waiting for an unrelated losing uploader, provided its own
availability/authority is valid.

GC first fences new claim/start authority and checks all possible writers and
readers have settled. It then claims the fixed path for deletion. Confirmation
rechecks that same fence and absence before releasing bytes/object capacity.
A late observation for an earlier deletion generation cannot release a new one.
Confirmed paths are never reused. An uncertain deletion may be reconciled or
repeated against that same permanently retired path under a bounded cleanup
attempt policy; it may not race any new creator.
Use the one-reservation `worker_claim_original_orphan_v2` grant above, backed by
the job's pre-reserved deletion/probe envelope. An orphan scan only nominates
candidate IDs and cannot hand out external deletion permission. The old batch
claim must be revoked or converted to a non-granting compatibility response.

## Lock ordering and concurrency

Add one short-held `executor_authority` mutex as the **first** lock on grants,
quiescence/execution-capacity transitions, and operations that decide reclaim/publication
safety. It serializes admission and retirement across operation kinds. It is
never held during network I/O. Under it, preserve existing 011 order:

- Source: optional paper capacity, then source gate, job `NO KEY UPDATE`,
  reservation/step, execution/evidence records, transfer capacity/windows.
- Verification and orphan cleanup: paper capacity, job `NO KEY UPDATE`,
  reservation, execution/evidence records.
- Publication: paper capacity, document, job, reservation/object, relevant
  execution records, catalog policy, availability outbox.
- Original-read admission: read-policy mutex, one account, document, then
  execution and transfer records. It must not enter the paper/job/catalog lane.
- Object probe: paper capacity, document when targeting a published object,
  job/reservation if applicable, then execution and transfer records. It has no
  account lock; job-linked probes consume held slots and detached probes consume
  the separate authority-serialized pool.
- Source-only close: source gate, matching step, execution/evidence, transfer
  windows; no account or job mutation afterward.
- Metadata completion: acquisition policy/capacity, source slot/job, then
  catalog policy if needed; no document or account lock afterward.

**Chosen capacity ordering:** existing prepare/retry/profile-admission writers
retain policy → job and never acquire `executor_authority` later. Their expanded
finite envelope is admitted before future external grants. A v2 grant holding
authority → job consumes only that envelope and must not call
`acquisition_admit`, a trigger that locks policy, or any equivalent policy writer.
This explicitly avoids authority → job → policy opposing an unchanged policy →
job preparer. Metadata completion that genuinely needs policy takes authority →
policy → job, never policy after job. Detached-pool admission uses only the
authority mutex for history capacity and the existing ordered transfer locks for
charges. Verify the actual helper/trigger call graph, not just wrapper order.

Observers resolve immutable routing IDs before entering one ordered transaction;
they do not lock an execution row first and then discover they need its job or
gate. Keep FK-referenced identity rows immutable and use `NO KEY UPDATE` for
mutable lifecycle fields, retaining the deliberate document serialization lock.
No existing account, policy, job, reservation or outbox holder may acquire the
new mutex afterward. Examine all SQL helpers, triggers, FK locks and unique-index
conflicts before migration; test the real opposing schedules. Account fanout
remains a separate transaction and never acquires this mutex.

## Migration and restore

Ship a disabled additive migration first. Add bounded records and grants, replace
unsafe scan/reclaim predicates, and revoke or make old external-grant APIs return
`executor_contract_required` without mutation. Do the same for legacy result or
safe-close routes that could bypass evidence. Database-only publication helpers
must enforce the new holds even when called directly. Do not leave old granting
functions callable beside v2. Preserve immutable 011 result/command replay data.

Before rollout, verify actual state rather than assuming the disabled staging
environment is empty. Any preexisting issued external operation without new
evidence becomes a conservative legacy hold with no automatic reclaim bound.
Previously verified publication remains immutable; unknown old ownership is not
upgraded into proof. No policy, executor credential, timer, ingress or schedule
is enabled by this migration. Update the contract checker and restore quarantine
for the new authority; back up and test restore before applying it.

Restore keeps outbound/publication/read authority disabled and preserves unknown
holds, charges, receipts and remote paths. A restored database must receive a
fresh activation epoch; the copied epoch cannot prove it is the only running
authority. Before activation, retire/revoke the old deployment and reconcile its
accepted attempts against external evidence. Rotate credentials or broker
capabilities as required to stop old admission; that does not undo requests
already accepted by arXiv or Storage. Restoring to a new project does not permit a
second independent global arXiv gateway. Old-epoch callbacks may provide evidence
only through controlled reconciliation, never obtain new authority. The live
activation/deployment identity must be verified outside the restored snapshot.
The snapshot can also predate a committed grant: inventory the old authority's
post-snapshot tail from its surviving database/controller journal. If that tail
cannot be reconstructed, retain an epoch-wide unknown hold and reconcile the
external namespace/capacity conservatively. An empty restored attempts table is
not proof that nothing was issued, and a single storage listing is not proof
that an accepted write cannot still arrive. Never reuse old-epoch reservation
paths while that uncertainty remains.
This is the authority row's explicit recovery block, not a fabricated ordinary
attempt. Clearing it requires a retained bounded recovery-evidence digest and
the independently verified predecessor retirement/settlement scope.

An operator recovery runbook should have just four safe outcomes: record a
validated exact stop/settlement proof, keep the attempt quarantined, retire an
entire proved-drained authority and admit a new epoch, or abandon an unresolved
path while retaining its cost/capacity. “It has been long enough” is not a fifth
outcome. A reviewed hard bound can later automate the matching retirement step;
record its policy and derivation as evidence instead of adding a magic timeout.

## Metadata-only local implementation checkpoint

Pending migration 012 implements only `atom` and `license` operations with
`executor` and `arxiv_connection` receipts. It uses the shared record family
above, leaving original download, verification, Storage reconciliation, deletion
and original reads without operational grants. It installs no policy, login,
secret, operational role membership, ingress, scheduler or network adapter. Authority starts
disabled with predecessor recovery required. No hosted migration or admission is
implied by local tests.

Three `NOLOGIN` capabilities divide the API: `science_reader_metadata_executor`
prepares and processes metadata jobs, `science_reader_execution_observer` records
owned-child retirement, and `science_reader_executor_admitter` installs immutable
policies and changes authority using an expected-revision comparison. The new
grant/receipt/admission functions are unavailable to customer, service and PDF
verifier roles. Each privileged function also checks the explicitly selected
role; `current_user` inside a security-definer function is its owner and cannot
identify the caller. Operational login provisioning and deployment admission are
separate work. A supplied binding or evidence hash alone is not an attestation.

Each new lookup has immutable `execution_contract='metadata-v2'` and reserves
24 history units before work: three Atom attempts plus three license attempts,
each with one existing acquisition step, one execution identity and two final
resource receipts. Successful and failed outcomes update their own step rather
than allocate another terminal row. Completion never shrinks that reservation.
Legacy jobs retain their old contract and envelope; preparing a new generation
does not rewrite their commands or manufacture retirement proof.

The unchanged 32 MiB logical control ceiling reserves 32 units of 8 KiB for the
authority and at most eight immutable policies. Admission accounts for source
slots as well as jobs, commands, profiles and prepaid history. An otherwise empty
pool therefore admits at most 150 distinct-source lookups (27 units each). This
is a bounded logical-history allowance, not a measurement of PostgreSQL physical
disk use or a production-scale capacity claim. Exhaustion denies new work while
retaining room for already reserved receipts. Detached read/probe capacity is
zero in this slice. Capacity changes require a separate reviewed configuration
decision rather than grant-time top-ups or deletion of fences.

A grant records one already identified child and returns permission only once.
Exact replay returns state. Busy waits consume no attempt, history or transfer
allowance. All unsettled children and source connections occupy the single lane
across expiry, job completion and authority retirement. Only the observer can
record an exact joined-child receipt. Unknown bodies retain their full 1 MiB
charge; complete accepted framing permits payload-byte accounting. SQL starts
the source cooldown when it accepts connection evidence, for at least three
seconds and any longer Retry-After period. A metadata result needs the matching
accepted response digest, current epoch and reporting deadline. Eligible license
evidence must carry that same response digest.

The migration conservatively treats any retained legacy source grant, original
reservation or original-read grant as unresolved, including legacy records that
claimed closure under the old contract. Such history blocks activation. There is
no generic legacy reconciliation/conversion API in 012; empty staging admission
must be established by inspection, and a nonempty old installation remains
blocked until a separately reviewed recovery procedure exists.

The [restore quarantine](BACKUP_AND_RESTORE.md) advances authority revision even
for an empty or already blocked snapshot, preserves all evidence and holds, and
requires new predecessor reconciliation. Local tests apply actual 001–012 schema
and exercise stale activation, held connections and status-only grant replay.
They do not establish encrypted-checkpoint recovery or hosted recovery.

The development [source adapter](../../workers/source-gateway/README.md) currently
uses real loopback TLS fixtures and isolated child processes only. Its owned
executor scope is transport, framing, hashing and reference cleanup; the existing
TypeScript XML parser and database result handling run outside that scope. Before
integration, the parent must derive the exact target/request from the granted
immutable job and compare it with the paused child's captured request and final
result. A matching process binding alone does not identify the source request.
Lost grant acknowledgement never starts I/O. An unknown parent/child lifetime
retains its hold; a timer alone never produces a receipt.

## What the hosted experiment can establish

The [bounded experiment](../../workers/pdf-verifier/hosted-limits/README.md)
remains diagnostic. A correctly correlated platform shutdown can establish that
the identified isolate ended, conditional on the reviewed host event semantics.
It can detect a broken CPU/memory/wall-clock hypothesis and exercise observation
and cleanup. It cannot prove all future executions use that policy, measure peak
OS memory, attest per-document CPU in a reused worker, settle a remote write, or
show a source-facing connection ended; the experiment makes no source or Storage
request. Successful deletion of the probe is not proof of execution quiescence.

Supabase currently documents a 400-second paid worker lifetime, 2 seconds CPU per
request, 256 MB memory, and a separate 150-second response-idle timeout. A worker
can serve multiple requests. These are useful admission inputs, not a deployment
configuration digest or a remote-write completion guarantee. [Hosted limits](https://supabase.com/docs/guides/functions/limits)

The pinned 1.77.0 source drops the runtime and awaits supervisor finalization
before forwarding its completed worker event; this supports the limited
shutdown interpretation above. It also contains a per-request timer strategy
that can reset a wall timer while requests remain outstanding. The version alone
does not identify the selected policy. [Worker event path](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/worker_inner.rs#L300),
[per-request strategy](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/supervisor/strategy_per_request.rs#L187)

Deno documents `HttpClient.close()` and client pool configuration, but its general
API page does not establish that the hosted Edge implementation synchronously
ended a particular upstream server connection. Test and inspect the actual
admitted adapter; do not infer that from the existence of this API. [Deno fetch API](https://docs.deno.com/api/deno/fetch/)

### Selected next development adapter

Independent review of the pinned Edge implementation did not establish a joined
connection-retirement acknowledgement: fetch clones its client, `close()` removes
the runtime resource, and connection tasks have a separate lifecycle. Its client
also incorporates process-level proxy configuration that the function's separate
environment map does not attest. Hyper may race IPv4/IPv6 connection attempts;
its cancellation retry concerns a reused connection canceled before writing,
not evidence that ordinary GET bodies are automatically replayed. Automatic
decompression can remove the original response's encoding/length headers before
the current adapter checks them. These are concrete admission gaps, not a claim
that Edge networking is generally unsuitable. [Pinned client](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/vendor/deno_fetch/lib.rs),
[proxy handling](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/vendor/deno_fetch/proxy.rs),
[environment map](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/ext/env/lib.rs),
[connector](https://github.com/hyperium/hyper-util/blob/v0.1.7/src/client/legacy/connect/http.rs),
[decompression](https://github.com/tower-rs/tower-http/blob/tower-http-0.6.2/tower-http/src/decompression/future.rs).

Prototype one supervised Python HTTP/1 child on the existing development machine,
with loopback TLS fixtures only until the source-grant integration is reviewed.
This creates no hosting commitment and is not an always-on deployed beta service.
The child has no database credentials, descendants or inherited source sockets.
It selects one resolved address, verifies the canonical TLS hostname, derives its
fixed route from a normalized source ID/stage, and performs no proxy lookup,
pooling, redirects, retries, address failover or decompression. Bound protocol
bytes, headers, body, subprocess output and elapsed work separately. Identify and
pause the child before its grant; a lost grant response never releases socket
work. The supervisor, not a child-written `closed` message, witnesses exit.

Keep response framing, peer TLS closure and owned-resource retirement separate.
`HTTPResponse` can finish at Content-Length or a terminal chunk before peer
closure, and its file wrapper must be closed as well as the socket. Use
`suppress_ragged_eofs=False` to distinguish abrupt TLS termination. A correctly
framed response may remain complete after an incomplete TLS close; a
close-delimited body needs a valid closure alert. Neither fact claims TCP or
server-side application completion. [Python TLS](https://docs.python.org/3/library/ssl.html#ssl.SSLContext.wrap_socket),
[RFC 9112 §9.8](https://www.rfc-editor.org/rfc/rfc9112.html#section-9.8).

Under an explicitly admitted direct-owner OS policy, a supervisor's exact child
kill and join can establish executor/socket retirement after timeout. Retain the
full issued byte ceiling and accept no successful metadata result. A parent
crash or lost process/boot-epoch identity remains unresolved until positively
reconciled; elapsed time alone clears nothing. Normal completion must join all
owned resources before its receipt too. The initial prototype admits no policy
and has no source-network authority. A future deployed supervisor must separately
establish the same ownership, restart, credentials, resource limits and budget
contract before providing continuous service.

If required host enforcement cannot be admitted, retain Supabase orchestration
and use a one-shot verifier controlled by an external watchdog, bounded memory
and confirmed task/process exit. That selection needs a separate budget and
deployment review. No extra service is provisioned by this proposal. Metadata can
be enabled independently only once its own gateway connection/authority contract
is admitted; a working PDF parser is not a prerequisite for metadata and cannot
grant metadata network authority.

## Required deterministic schedules

1. Verification begins just before reservation expiry. GC and another verifier
   cannot claim it while any hold remains, including past the reporting lease.
2. Success, malformed input, oversize/integrity failure, `input_unavailable` and
   timeout each finish logically while a fake read/executor stays alive. No
   successor, byte release or deletion occurs until the matching stop proof.
3. A grant commits and its response is lost. Exact replay is status-only;
   overlapping schedulers do not execute, burn another attempt or skip a hold.
4. A paused old worker resumes after cancellation/deadline/epoch retirement. It
   obtains no new permission. Its late result is rejected; its exact valid
   quiescence evidence can close only its old resource.
5. Source EOF occurs while the connection remains open. No next permit. Later
   proved close with unknown bytes retains the charge and begins spacing at the
   database receipt, including `Retry-After`.
6. Upload is accepted, the executor dies, absence is observed, then the server
   commits. GC/retry/capacity release remain blocked throughout the uncertainty.
7. A late exact stop proof arrives after a later attempt exists. It neither
   releases the later hold nor changes the later lease/result. Changed evidence
   under the same ID rejects; exact evidence replay adds no row.
8. Same-byte dedup publishes the winner while the loser's upload is uncertain.
   The loser remains charged and cannot be deleted prematurely.
9. Capacity/control history reaches its cap with unresolved work. Completion
   and quiescence still fit reserved headroom; new grants fail without erasing
   removal/command/execution fences. Midnight and account closure release none.
10. An old source deployment continues across restore. New-epoch activation and
    global gateway use stay blocked until external retirement is proved; copied
    deadlines and revoked credentials alone do not settle accepted work.
11. Change or disable the active policy during lock wait. No stale admission or
    shortened old horizon; receipt replay/old stop reconciliation still works.
12. Run opposing FK/lock schedules for claim, observer, projection, original read,
    publication and GC. All follow the new prefix and existing family order.
13. Lose the observer's local cursor/IDs, prune read grants and make jobs terminal.
    A fresh unsettled scan still discovers every open resource, including retired
    epochs. A recovery read without an object-probe grant is denied and a lost
    probe grant never becomes another GET.
14. Lose pre-upload arming acknowledgement. No POST is issued and retry is
    status-only. A later observed object cannot replace the frozen candidate
    hash/length; account deletion does not remove the detached read snapshot.

Implementation review should settle exact field types and caps, then test this
additive contract locally while every hosted flag remains disabled. Production
admission is a later explicit checkpoint backed by the selected resource
contracts, not the stress experiment's pass/fail summary.

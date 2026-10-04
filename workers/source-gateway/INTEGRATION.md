# Local metadata executor integration proposal

Status: plan only, against disabled migration 012 candidate at commit `19de3be`.
No grant adapter, role credential, activation, source DNS/GET, scheduler or
deployment is implemented here. The first integration uses a disposable local
Postgres database and loopback TLS fixtures. It is not a deployed beta gateway.

## Ownership and immutable inputs

The supervisor owns a single transport child and every IPC endpoint. The child
has no database credentials, proxy configuration, descendants or exported socket
descriptors. Its scope is TLS, one HTTP request, framing, body hashing and cleanup.
The observer derives its evidence from the supervisor's exact child-exit witness;
child output alone cannot issue receipts. The controller owns catalog parsing and
result writes after transport ends. Those tasks are outside the child executor.

Use three separate capability surfaces: executor for grant/status/result,
observer for exact-child receipts, and admitter for policy/epoch activation.
The local action runner receives no admitter capability. The child receives none
of the three. Role-scoped calls must not use `service_role` or silently escalate.
For local tests only, the fixture database installs its test policy/authority in
the harness, independently from the action runner; no such setup runs on hosted
infrastructure.

Freeze a finite bundle before launching: controller/RPC transport as
`runner_sha256`, child/protocol/bootstrap as `transport_sha256`, parent witness
validation/receipt serialization as `observer_sha256`, and reviewed runtime/OS
ownership limits as `admission_sha256`. Hash exact captured bytes and a canonical
manifest, not mutable source after execution. Pin Python/TLS/executable and
dependency identities separately in that admission manifest. The current
two-module `child_recipe_sha256` is not a substitute for these complete identities.

## One action, in order

1. Read authoritative job/authority state and capture the proposed source DTO.
   Create a fresh claim UUID and child UUID; never reuse a process for another
   claim. Launch the frozen child with bounded pipes, `-I -S -B`, no credentials,
   closed inherited descriptors and no source socket. It emits one bounded READY
   frame and then blocks on one GO-or-STOP frame. No DNS, TLS context work that
   opens a socket, or source I/O occurs before GO. A finite READY/GO wait exits
   without I/O if the controller disappears.
2. Bind the real child: host UUID, kernel boot identity, PID and kernel process
   start identity, plus child UUID, deployment/bundle, epoch and policy. Verify
   PID/start identity through the platform adapter while the exact `Popen` child
   is alive. A random UUID or application wall-clock launch timestamp is not a
   kernel start identity. Implement and review the macOS/Linux identity adapter
   before any admitted use; absence of a supported adapter must refuse execution.
3. Immediately before the grant transaction record `monotonic_ns()` as `m0`.
   Call `worker_claim_metadata_stage_v2` once. The role-scoped SQL adapter must
   retain the SELECT response until COMMIT acknowledgement succeeds. Streaming
   SELECT rows, socket EOF or a driver timeout do not establish committed grant
   authority. No automatic mutation retry, transaction retry or redirect is used.
4. Only a fresh, committed `granted:true` reply can permit GO. Validate the exact
   job/claim/generation, execution kind, all binding fields, policy/epoch and
   one-MiB ceiling. Derive the canonical source DTO again from that reply and
   compare its exact canonical bytes with the already-paused child's capture.
   If stage/source/revision/ceiling changed, cancel and join this child without
   GO; do not rebind it to the newer work. A later action uses a new child/claim.
5. Derive useful/report durations from the DB's `deadline - created_at`, validate
   their bounds, then map them to `m0 + duration`. Subtract all RPC/COMMIT latency
   by checking the current monotonic time against those deadlines. Do not compare
   client and DB wall clocks. GO carries the earlier of that useful deadline and
   the transport's fixed 30-second limit, as decimal monotonic nanoseconds, plus
   execution ID and captured source digest. The same-host child verifies it is
   still unexpired immediately before opening its only socket. Parent watchdog
   and child share that deadline; the fixture's relative startup/grace split is
   not the future grant protocol.
6. After GO, neither caller cancellation nor failure permits another GET. Stop
   and join the exact child. Bound IPC, cancellation and post-stop drain. If exit
   is unconfirmed, discard body output and retain both SQL resource holds; no
   receipt or successor is allowed. A timer, peer EOF, PID disappearance without
   an admitted identity check, or caller timeout cannot manufacture the witness.
7. Independently verify result binding, canonical target, framing, body length
   and SHA against the captured grant-derived DTO. Freeze one executor receipt
   and one source-connection receipt with stable receipt UUIDs. Durably checkpoint
   the joined-child witness and exact planned receipt bodies before mutation.
   Commit the two
   `worker_record_metadata_quiescence` calls under observer authority. A lost
   acknowledgement permits status lookup/exact same-body replay, never new I/O
   or a changed receipt. Both holds must be absent before advancing the action.
8. On a complete HTTP 200 body, run the existing TypeScript XML/arXiv helpers in
   a separate bounded, network-disabled parser invocation. Reuse
   `arxivAtomRecord`, `arxivCatalogArguments` and `arxivReuseEvidence`; do not
   duplicate XML parsing in Python. Send exact body SHA and bounded derived
   result to `worker_finish_metadata_stage_v2`, after the exact result arguments
   have a durable local checkpoint. Retain Atom UTC instants for
   version/license checks and map dates only at catalog persistence. A malformed
   body or non-200 response uses `worker_fail_metadata_stage_v2` with finite
   reason/retry semantics after resource settlement. Parser failure does not
   reopen transport. Result acknowledgement loss uses status/exact replay, never
   a failure write that can overwrite an already-committed success. Quiescence
   may reconcile after deadline/retirement; a metadata result still requires its
   current epoch, generation and report deadline. Expiry never authorizes another
   source request in this action.

## Source and result DTOs

The source DTO remains `{source_id, revision, stage, byte_ceiling}`. Atom uses
the granted job's requested revision (possibly null); license uses its pinned
source revision. The OAI route itself is unversioned: parent parsing must compare
its evidence to the exact pinned revision and Atom timestamps. Canonical URL
derivation remains shared and bounded; no arbitrary URL is introduced.

Add local READY/GO/result envelopes with version, child UUID, captured recipe and
source digests; GO additionally binds execution ID and monotonic deadline.
Capture these before awaiting anything and copy any returned diagnostic objects.
Keep the source DTO digest distinct from SQL's grant request digest and process
binding hash. SQL currently hashes `jsonb::text` for `binding_sha256`; Python/JS
canonical JSON is not byte-equivalent. Validate every returned binding field,
then retain that authenticated DB digest as the opaque receipt binding rather
than silently recomputing it with a different serializer. The observer must
validate the source DTO independently; the process binding alone proves no URL.

The current TypeScript action runner uses 011 claim/close/fail RPCs and wall-clock
source deadlines. It cannot be connected unchanged. Add a versioned executor
adapter using 012 RPCs and the parent-owned monotonic/source facts above. The pure
XML helpers remain reusable. Existing source-fetch's `close()` promise is not the
admitted connection-retirement boundary for this integration.

## Receipt mapping and accounting

| Observed transport result after exact join | 012 source facts | Effect |
|---|---|---|
| Complete Content-Length or chunked body, including abrupt TLS close | matching framing; payload count/hash/status; `peer_eof` only when clean TLS EOF was observed | Refund unused payload ceiling; only status 200 can produce metadata |
| Complete close-delimited body | `close_delimited`, clean TLS EOF required, payload count/hash/status | Same bounded payload accounting |
| Timeout, kill, truncation, encoding/redirect refusal, invalid output, or never sent GO | `unknown`; null body count/hash; known header status/Retry-After only | Retain full one-MiB charge; no metadata result |
| HTTP 204 with explicit Content-Length: 0 | `content_length`, zero payload and empty-body SHA, status 204 | Valid retirement; non-success metadata outcome |
| HTTP 204 reported as `no_body` without framing header | `unknown`, null body count/hash, status 204 | No invented Content-Length and no schema expansion needed; retain full charge |

`peer_eof` means the child's observed clean TLS EOF, not HTTP parser EOF, TCP close
or remote application completion. `disposition=exited` requires normal observed
exit; a killed/crashed child cannot retain a complete-body refund. Executor facts
contain only the validated DB binding digest and disposition. Source facts also
contain the fields required by 012. Record executor before source so source-gate
release cannot precede the executor receipt within this action.

The one-MiB charge/refund unit is body payload, not two-MiB TLS-plaintext protocol
bytes or encrypted wire traffic. Keep protocol/header counts as bounded local
diagnostics; do not report them as `actual_bytes`. Unknown bodies retain the full
charge even when some bytes were observed or GO was never sent. HTTP 429 preserves
bounded Retry-After even with a rejected/truncated body; 012 now supports this.
The SQL cooldown is at least three seconds, extended to a longer Retry-After.
HTTP 404 maps to nonretryable `source_not_found`; 429 to retryable `rate_limited`;
5xx to retryable `metadata_unavailable`; invalid 200 XML to nonretryable
`invalid_source_metadata`. Other non-200 statuses do not become catalog success.

Before live admission, tighten Retry-After observations: the fixture currently
caps parsed values at 86,400 seconds and uses local wall time for HTTP dates.
Those are fixture limits, not proof that clock skew or a longer server delay can
be shortened safely. Preserve a finite absent/delta/date/invalid/over-limit
classification for the future adapter. Unsupported delay evidence must block the
database source lane for review: with 012 unchanged, retain `arxiv_connection`
unresolved and send no source receipt. The exact executor receipt may commit.
Merely stopping this local runner after a zero/shorter source receipt is unsafe:
another scheduler could reuse the released gate. Never silently shorten delay.
This is a DTO/policy prerequisite, not a change to applied SQL in this plan.

## Lost acknowledgements and recovery

Before requesting a grant, retain a bounded local intent containing job/claim,
exact source DTO and recipe, process/boot identity, and a no-GO state. Checkpoints
use bounded temporary files, flush and `fsync` the file, atomically rename within
the owned run directory, and `fsync` that directory before sending the dependent
grant/receipt/result mutation. Verify these filesystem operations on the local
host; a failed durability checkpoint prevents that mutation. Never overwrite an
already-frozen intent or receipt with different arguments. A lost or
failed COMMIT acknowledgement means STOP and join without source I/O. A subsequent
status lookup may reveal the committed attempt, but never grants GO. If its
transaction is still unresolved, keep the intent: a null early status read does
not prove it cannot commit later. Once the exact attempt is visible, observer
receipts can settle the already-ended child with unknown body/full charge.

After exact join, checkpoint the witnessed process identity, disposition,
bounded body/hash and immutable planned receipt/result arguments with the same
durability sequence before any observer or result mutation. Retain them until
their commits are resolved. Status-only recovery may
reparse those same bytes; it never refetches to reconstruct missing output. Erase
the body only after the durable result/receipts are confirmed. A first local
harness has one action and a finite artifact directory, not an unbounded daemon
journal.

Parent death is deliberately not auto-recovered in the first harness. A PID-only
record cannot recreate a `Popen.wait()` witness after reparenting. Leave SQL holds
and authority recovery blocked unless a separately reviewed durable supervisor
can supply the exact process/boot-scoped witness. There is no timer-based reclaim
and no inference from an empty restored local journal. Always-on host admission,
OS isolation, resolver bounds and crash recovery remain later deployment work.

## Required local schedules before expanding beyond fixtures

- READY observed but no committed grant: zero fixture connections; STOP/join.
- SELECT returns true, then COMMIT fails or its acknowledgement is lost: no GO;
  late status exposes the same attempt; full-charge receipt replay is immutable.
- Pre-grant atom/source capture differs from granted license/source state: no GO,
  no child rebinding, exact stopped-child receipts only.
- Positive/negative wall-clock skew and delayed grant reply consume monotonic
  authority; expired GO opens no socket. Partial/duplicate GO is refused.
- Actual fixture truncation, late error, retained FD, stop, kill and unresolved
  drain preserve the existing prototype's no-false-body/no-false-exit guarantees.
- One receipt commits and the next acknowledgement is lost: replays allocate no
  extra row/charge/request, and a successor waits for every required hold.
- Complete 200 versus malformed XML, 404, 429 with incomplete body, 503 and both
  204 framings: correct delay, body accounting and result/failure behavior.
- File/rename/directory-sync failure before a grant or receipt/result mutation
  prevents that mutation; ambiguous database state never deletes the checkpoint.
- Unsupported Retry-After produces an executor receipt only; another scheduler
  remains blocked by the unresolved database connection hold.
- Parent dies before grant, before GO, during receive, or after result but before
  receipt: no reconstructed permission or fabricated join after restart.
- Ready/GO/result/receipt DTO mutation, wrong source target, changed recipe or
  process-start identity rejects; status-only replay never runs the child again.

These tests exercise one reviewable local action end to end. They do not authorize
source traffic, hosted activation, new credentials or an always-on service.

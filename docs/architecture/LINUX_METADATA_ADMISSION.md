# Linux metadata executor admission

Status, 2026-10-04: **independently reviewed for disabled local implementation;
not implemented or admitted**. This
document proposes a narrow extension to the unapplied
[`012` candidate](../../supabase/migrations/202610030012_metadata_execution.sql.pending).
It changes no SQL, enabled flag, credential or executable. Applied migrations
001–011 remain immutable. Its scope is one Atom or license action, not original
PDF acquisition, verification, Mathpix or a general scheduler.

The [execution contract](EXECUTOR_LIFETIME.md) and
[local integration](../../workers/source-gateway/INTEGRATION.md) already separate
one-use permission, committed results and resource retirement. The
[Linux fixture](../../workers/source-gateway/linux/README.md), committed as
`a20cd4c`, adds a tested same-boot process-group observation. It does **not** yet
connect that observation to database authority. References in
[ACQUISITION.md](ACQUISITION.md) assigning paid processing to “012” predate the
metadata-execution candidate; they do not authorize paid work in this proposal.

## Meaning and limits

Keep these three facts independent:

| Fact | What it permits |
|---|---|
| Complete, validated HTTP response retained with an admitted exact-child join | Existing bounded payload accounting and, for HTTP 200, metadata parsing/result validation |
| Captured Linux scope is permanently start-fenced and its exact retained cgroup has no living processes | Retirement of that scope's executor and owned source socket; **no body, exit code, refund or metadata success is inferred** |
| Body, join or group identity is unavailable | Preserve the corresponding uncertainty; absence of output is neither proof of a live process nor proof of retirement |

The second row depends on an admitted ownership policy: the source socket has no
owners outside the scope, descriptors cannot be exported, and contained work
cannot migrate out or restart. It does not claim that arbitrary remote server
work stopped. A stop command, expired lease, missing directory, PID disappearance
or client timeout is insufficient. No elapsed-time release is added.

## Proposed database delta

Reuse `executor_policies`, `executor_authority`, `execution_attempts` and the two
prepaid `execution_quiescence` rows. Add no orchestration table or event stream.

**Policy.** Add kind `metadata-linux-scope-v1`, retaining the current ten policy
keys, `version: 1`, `connection_model: direct-owned-socket-v1`, one executor and
existing deadline limits. `admission_sha256` identifies the reviewed host/runtime,
unit templates, confinement, credential access and journal durability policy;
the digest alone is not an attestation. The old `metadata-owned-child-v1` policy
continues to accept only binding version 1 and existing evidence.
Keeping that fixture-compatible branch does not admit it as a hosted policy.

**Authority.** Add nullable `admitted_host_id UUID`, `admitted_boot_id UUID` and
`admitted_deployment_id TEXT` to the singleton. They are mandatory for Linux
activation, validated with the existing UUID/deployment syntax, exposed in state,
and compared exactly before every fresh grant. Introduce
`worker_activate_metadata_executor_v2(expected_revision, project_ref, policy_id,
host_id, boot_id, deployment_id, recovery_evidence_sha256)` for the Linux policy;
the existing activation RPC must reject that policy kind. Only the admitter can
activate it. Keep the current disabled/recovery-required defaults, revision-CAS,
fresh epoch, empty predecessor checks and restore quarantine. The pin prevents
accidental host/boot/deployment drift; it is not remote hardware attestation.

**Binding.** Linux grants require `version: 2`, the current fourteen top-level
keys with their existing meanings, and exactly one additional key, `scope`:

```json
{
  "kind": "linux-systemd-cgroup-v1",
  "scope_id": "<canonical UUID equal to claim_id>",
  "invocation_id": "<32 lowercase hex characters>",
  "cgroup_device": "<canonical unsigned decimal string>",
  "cgroup_inode": "<canonical positive decimal string>",
  "capture_sha256": "<64 lowercase hex characters>"
}
```

The fifteen top-level and six nested keys are exact; missing, extra, null or
wrongly typed fields reject. Decimal strings have at most twenty digits, no
leading zero except device `"0"`, and values no greater than `2^64 - 1`. Keep the
whole binding within 2,048 PostgreSQL JSON-text bytes. Existing child PID/start,
host/boot, deployment, hashes, policy, epoch and source-argument checks still
apply. SQL binding SHA remains the opaque authenticated `jsonb::text` digest;
do not substitute Python canonical JSON.

Add nullable `execution_attempts.scope_id UUID`, constrained to equal the nested
value for v2 and to be null for v1, with uniqueness on
`(host_id, boot_id, scope_id)`. Retain existing child/process/operation uniqueness
and immutable rows. This prevents another grant from rebinding a retained scope;
do not overload the database-generated execution ID as its pre-grant identity.

For this policy, derive names rather than accepting paths:
`tsmetadata<scope UUID without hyphens>.service` and the matching `.slice`, with
retained cgroup `/<slice name>`. The root-owned journal directory is
`/var/lib/timestep-source/attempts/<scope UUID without hyphens>/`.

**Receipt.** Extend the existing observer-only
`worker_record_metadata_quiescence` with `evidence_kind=owned_scope_retired_v1`.
It is valid only for an execution granted under the Linux policy/binding above.
Executor facts have exactly these five string fields:

```json
{
  "binding_sha256": "<database binding digest>",
  "scope_id": "<captured scope UUID>",
  "capture_sha256": "<pre-grant capture digest>",
  "fence_sha256": "<durable stop-fence digest>",
  "observation_sha256": "<durable positive observation digest>"
}
```

Source-connection facts have those five fields plus exactly:

```json
{
  "framing": "unknown",
  "peer_eof": false,
  "actual_bytes": null,
  "body_sha256": null,
  "status_code": null,
  "retry_after_seconds": 0
}
```

`status_code` may instead be a durably retained integer from 100 through 599;
`retry_after_seconds` may be a retained integer from 0 through 86,400. All other
values above are fixed. In particular there is **no `disposition` field**: group
emptiness cannot provide an `exited`/`killed` process status. Digests are lowercase
64-character hex; scope/capture/binding must match the immutable execution. Both
facts objects remain within the existing 2,048-byte limit.

The observer, not SQL, validates the actual kernel observation and retained
documents. SQL enforces the policy, binding, exact schema, capability and replay
rules; supplied digests cannot substitute for the trusted observer. Require an
accepted executor receipt before accepting a v2 source-connection receipt.
Record each resource once. Existing canonical receipt replay, same-ID conflicts
and identical-proof/new-ID alias handling remain unchanged. Never replace an
already accepted receipt with a different proof kind or observation. Recovery
first reads state and reuses the original checkpoint or canonical accepted facts.

The normal `owned_child_joined` path remains available for v2 when its actual
durable parent-wait witness exists. If that witness is absent, retained response
bytes alone cannot upgrade scope-retirement evidence to a complete-body receipt.

## Capture, grant and GO ordering

1. The executor captures job/authority state, source DTO and a fresh claim/scope
   UUID. The trusted launcher creates the never-reused unit and retained slice,
   starts the captured transport supervisor and identifies its paused child.
   There is no source DNS or socket before GO. The observer is outside the slice.
2. Before the grant, the observer checks the actual boot, invocation, transport
   supervisor PID/start, child PID/start/parentage, both scope memberships, exact unit bytes,
   retained cgroup device/inode and the policy-bound bundle. It validates the
   complete READY schema and source digest, rather than trusting child JSON.
3. Publish a root-owned, private `capture.json` with file and directory `fsync`
   and no overwrite. Its exact schema is: `schema_version: 1`,
   `kind: linux_metadata_capture_v1`, `job_id`, `claim_id`,
   `binding_without_capture_sha256`, `source_request`, `source_sha256`,
   `supervisor`, `unit_sha256`, `slice_sha256`. The binding is the proposed v2
   object with only `scope.capture_sha256` omitted; `supervisor` contains integer
   `process_id` and decimal-string `process_start_id`. Other types follow their
   binding/source schemas. The source DTO remains
   `{source_id, revision, stage, byte_ceiling}`. Hash compact, sorted UTF-8 JSON
   and insert that digest into the final binding. No circular SQL binding hash or
   not-yet-created execution ID appears in the capture.
4. Persist the final grant intent before invoking the grant **once**. Retain
   SELECT output until COMMIT acknowledgement succeeds. Use the existing
   pre-RPC `CLOCK_BOOTTIME` origin and `deadline - created_at` durations, consuming
   all RPC latency; do not compare independent wall clocks.
5. Validate and persist a fresh committed grant. Derive the source DTO from its
   job/stage/revision/ceiling and compare it byte-for-byte to the paused capture.
   Recheck the live child/scope identity, cancellation and remaining deadline
   immediately before the one GO control write. Mismatch, missing acknowledgement
   or expired authority means no GO and no child rebinding.
6. Complete through the existing exact-child path where possible. Persist body
   once, witness and exact receipt arguments before observer mutations; persist
   exact parser-result arguments before result mutation. Parsing/result handling
   remain outside the transport executor and reuse the frozen TypeScript parser.

The Linux capture/fence/observation additions need a measured byte/file envelope
reserved before the grant. Bound each of those new documents to 16 KiB and keep
the complete action within the existing 4 MiB/32-file journal envelope, including
the one-MiB body and worst-case Unicode result. If that envelope cannot be met,
review the bound before admission; never discover known capacity exhaustion
after granting work. A failed durability barrier blocks the dependent action.

## Same-boot scope retirement

The observer reopens and validates the bounded capture without following links,
including every nested source/process/bundle field. It must not reconstruct a
parent-wait witness from `/proc` or use a new unit bearing an old name.

Before requesting stop, durably publish root-owned `stop-fence.json`, exactly
`{schema_version: 1, kind: linux_metadata_stop_fence_v1, scope_id,
capture_sha256}`. The captured service has
`ConditionPathExists=!<journal>/stop-fence.json`, `Restart=no`, one permitted
activation, `KillMode=control-group`, no delegation and a retained parent slice.
The source UID cannot remove the fence, alter units, start services, migrate
processes or transfer source descriptors outside the scope. Guardian startup
reconciles fenced work; it never starts an old scope. Unit files and journal
remain available until receipt outcomes are known.

Request stop outside SQL; then require all of the following from the admitted
systemd/cgroup interfaces before freezing a positive observation:

- Same current kernel boot and retained slice path/device/inode as the capture;
  symlinks, missing/recreated groups and changed unit bytes reject.
- The permanent start condition still points to the exact durable fence. The
  service is inactive/failed, `MainPID=0`, has no pending job, and its invocation
  is either the captured invocation or empty. A different nonempty invocation
  rejects; the empty case reflects observed systemd 255 behavior only.
- The retained parent slice is still loaded/active and its recursive
  `cgroup.events` reports integer `populated=0`. A stopped but living process
  prevents this observation.

The positive document has exactly `schema_version: 1`,
`kind: linux_metadata_scope_empty_v1`, `binding_sha256`, `capture_sha256`,
`fence_sha256`, `boot_id`, `scope_id`, `captured_invocation_id`,
`observed_invocation_id`, `service`, and `group`. `service` is exactly
`{active_state: "inactive"|"failed", main_pid: 0, pending_job: false}`; `group`
is exactly `{path, device, inode, populated: 0}`, using the derived retained path
and captured decimal-string device/inode. Invocation values follow the checks
above; all other fields follow the binding/fence schemas. Validate exact types,
digests and permitted states before using it. Freeze its digest and
receipt UUIDs/bodies, successfully sync them, and only then issue observer RPCs.
Do not regenerate timestamps or observation bodies when an acknowledgement is
lost. The existing fixture's `fixture_cgroup_empty_v1` is never accepted directly.

This evidence can settle holds after lease expiry, cancellation, policy disable
or epoch retirement. It cannot revive result permission, clear restore
quarantine or activate a host. Cleanup stops/removes the retained slice and exact
unit definitions only after confirmed resource settlement; unknown stop,
observation or database outcomes retain them. Preserve journal/body/result
checkpoints until all their mutation outcomes are reconciled as well. A failed
cleanup is not permission to reuse the name.

## Recovery, charge and retry behavior

| Recovered state | Required action |
|---|---|
| Grant acknowledgement missing; status currently null | Never GO. Fence/retire the captured scope and retain its journal. Null MVCC state does not prove the original transaction cannot commit later. |
| Grant later appears for that same intent | Settle the already-retired scope against its exact binding; do not regrant or fetch. |
| Transport supervisor died; same-boot scope still populated | Stop the captured scope; keep both holds until positive evidence exists. |
| Scope retired, body unavailable or parent witness missing | Scope receipts only: unknown body, full charge, no metadata result. |
| Exact joined witness and valid body/receipt/result checkpoints exist | Replay the existing normal path; never regenerate an attempted result's `observed_at` or refetch missing data. |
| Executor receipt committed; connection acknowledgement lost | Read/replay the frozen connection receipt. No successor while a required hold remains. |
| Known unsupported, over-limit or uncertain Retry-After | Executor may settle; leave the **database connection hold** unresolved for reviewed delay handling. A local-only pause cannot protect the global lane. |
| Changed boot, missing/replaced scope, lost capture, restored disk or uncertain predecessor identity | Quarantine; no new observation or automatic activation. Cold-boot/restore recovery is outside this milestone. |

Scope settlement retains the full 1 MiB payload charge even when GO was never
sent. It releases occupancy, not attempt counts or prepaid history. Source
cooldown begins at database receipt acceptance: at least three seconds, extended
to any longer supported Retry-After delay. Missing durable headers provide no
invented status or delay; known unsupported headers must not be discarded.

If the existing result authority is still current, unavailable transport can
record the existing retryable `metadata_unavailable` failure. Otherwise, do not
fabricate a stale failure/result; the existing job claim/retry rules must decide
whether a **new** action is possible after settlement. A retry uses a new
claim/scope/child and consumes the existing stage/transfer limits; it is never a
replayed GET. Missing or invalid metadata cannot become `source_only` or readable.

## Capability and operating-system boundary

| Component | Permitted authority |
|---|---|
| Executor/controller outside the attempt scope | Dedicated executor login; prepare/grant/status/result and existing projection RPCs. Owns parser/result work. No observer/admitter membership. |
| Fixed transport supervisor inside the scope | No DB, Supabase, provider or admission credential. Owns the exact paused child and normal wait witness. |
| Source child inside the scope | Separate unprivileged OS identity; one direct canonical request after GO, bounded output; no inherited source FDs, credential files, process-debug authority or descriptor-passing channel. |
| Guardian/observer outside the scope | Restricted observer login; root-owned journal and narrow exact-unit control. Validates captures/witnesses/emptiness. Cannot grant source work, write metadata results or activate policy. |
| Human-controlled admission path | Separate admitter login, absent from the worker. Reviews deployment and predecessor retirement before activation. |

The launcher must implement the supervisor/child UID boundary without giving the
child service-manager or cgroup privileges. Its control protocol accepts only
the fixed bundle, finite source DTO and never-reused scope; no arbitrary command,
path, unit or URL. The precise privilege-drop mechanism and effective kernel
restrictions require review and negative tests before admission. The tested
fixture used one credential-free UID for supervisor and child; it does **not**
establish this production separation. Root/host compromise remains outside the
trust model; hashes and role names do not remove that dependency.

Use distinct restricted login connections with certificate-verified DB TLS and
the existing allowlisted RPC/COMMIT discipline. Do not weaken `LocalRPC`'s fixture
guards, use database-owner/service-role credentials, or claim that `SET ROLE` in
an owner session constitutes provisioned separation. Journal and source bytes
are private local state, not logs. Budgeted deployment, bounded local disk,
backup/restore quarantine and host identity remain admission inputs.

## Smallest decisive integration checks

Run real disposable PostgreSQL plus the Linux lifecycle and loopback TLS; no
source request is needed for these checks:

1. Normal Atom → license → existing library projection with actual restricted
   logins, one source connection per fresh grant, exact parser timestamps, and
   truthful source-only/eligible-but-not-readable states.
2. Independently kill the executor controller and the transport supervisor
   during TLS. Restart only the observer, verify nonempty scope blocks
   settlement, then fence/stop/observe and settle both resources at full charge
   with no body result. A later action must wait for all holds and cooldown; the
   old action never reconnects.
3. Grant COMMIT acknowledgement loss, initially invisible original transaction,
   later commit, and source-stage drift before grant: zero GO on ambiguity or
   mismatch, exact same captured scope settles without regrant.
4. Database outage after observation and lost receipt acknowledgement: preserve
   exact durable bodies; recover without extra receipt/history/charge or GET.
   Include mixed normal-executor/scope-source evidence and conflicting replay.
5. Fence/capture/receipt fsync failure, cancellation during GO checkpoint, failed
   stop and explicit post-fence start: no dependent authority, no replacement
   invocation/socket, and uncertain cleanup retains definitions and journal.
6. Wrong boot/invocation/inode/source/bundle, malformed restored fields and
   missing group reject. Demonstrate from the source identity that credentials,
   guardian controls and cgroup migration are denied; configuration alone is not
   evidence that those denials work.
7. Partial 429 with supported delay, unsupported delay and saved bytes without a
   parent witness: correct database hold, full charge and no invented result.
8. Actual maximum binding, one-MiB body, Unicode metadata and recovery documents
   fit the reserved local/SQL envelope. Exhausted admission capacity still
   permits both prepaid retirement receipts after disable/expiry. Preserve the
   existing grant order (authority → source gate → job/step → transfer capacity
   and windows) and receipt order (authority → source gate when needed → step →
   transfer window when refunding). Scope uniqueness uses the same serialized
   authority path; no system call or file/network wait occurs while holding a
   database transaction.
9. Scope-only closure and identical receipt replay leave the original UTC daily
   `source_requests` charge unchanged, including actions that never received GO.
   A measured normal-body refund uses the execution's original `charge_period`,
   even when the receipt arrives in a later month; it does not credit today's
   transfer window.

The Linux checkpoint's 23 tests and the earlier integration's 54 tests validate
their separate fixture contracts. None of the combined checks above is claimed
complete by this proposal. Cold reboot, clone/restore, host replacement and
arbitrary kernel-stuck work remain quarantined, rather than being prerequisites
we pretend have already been tested.

Independent review checked the existing candidate-012 grant/receipt/refund
paths and the committed lifecycle fixture. It found no structural blocker in
this scope, including executor-before-source receipt ordering, ambiguous COMMIT
handling and separate authority roles. That review does not establish any of
the combined checks, production UID separation or host admission.

## Single outbound authority and rollout boundary

There is **one aggregate automated arXiv authority across staging, production,
developer tools, refresh and retry workers**. The first admitted deployment is
staging-only; production stays outbound-disabled. A second independently active
project-local gate is prohibited. Production later uses the same narrow source
authority, or takes over after a drained, quarantined handoff that disables the
old environment. This proposal does not build that cross-project routing layer.
Inventory other controlled callers before activation without expanding the
user's NAS permissions.

Next work is the local combined action and reviewed pending-012 delta. A hosting
account is needed only for actual deployment and host admission. Keep original
download/verification/read and paid-provider paths disabled; obtaining metadata
does not complete the reader. Provision no host or credentials from this
document, and make no additional commitment beyond the agreed $100/month
incremental beta budget.

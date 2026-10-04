# Linux metadata executor admission

Status, 2026-10-04: **database delta implemented, independently reviewed and
tested locally; combined Linux runtime not implemented or admitted**. The
extension lives only in the unapplied
[`012` candidate](../../supabase/migrations/202610030012_metadata_execution.sql.pending).
No hosted migration, enabled flag or credential changed. Applied migrations
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

## Local database delta

Reuse `executor_policies`, `executor_authority`, `execution_attempts` and the two
prepaid `execution_quiescence` rows. Add no orchestration table or event stream.

The frozen SQL SHA-256 is
`63239b21c78870c157c4c297d582de7e18c09ebf242f823dfc9c63419a32df7b`;
the final contract-test hash is
`01f6d58693df740e5bd8332f3e7ab5a6e73fb74a6af52ddeac0ee129691816e6`.
Independent review covers authority/binding pins, scope uniqueness, immutable
receipt ordering/replay, unknown-body accounting, original-period refunds,
role separation and v1 compatibility. The separate rolled-back Linux test block
also exercises normal joined-executor proof followed by unknown-body scope
source retirement, without inferring a successful response or refund.

The full local runner passed the immutable 001–011 SQL, concurrency and upgrade
checks, then stopped on an extra parenthesis in the new test fixture. That
test-only correction is preserved in the final hash; the focused rerun passed
the candidate SQL contracts and all ten existing real-session/upgrade schedules.
Evidence is `.artifacts/metadata-linux-full.log` and
`metadata-linux-focused.log`; the first log retains its failed ending.
Six additional real-caller compatibility checks pass in
`metadata-linux-compatibility.log`: actual-schema empty/unsettled restore
quarantine, normal Atom transport through catalog publication, lost grant
acknowledgement without GO, and exact replay after lost receipt/result
acknowledgements. These use disposable loopback PostgreSQL databases and TLS
fixtures; no temporary databases remain. They do not connect the Linux cgroup
fixture to SQL or establish deployed confinement, separate credentials or source
admission.

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

## Combined adapter launcher — local prerequisite verified

This policy is implemented and locally verified for the launcher/ingress
prerequisite described below. It does not admit a host or change candidate 012.
The separately authorized exact isolated guest may run the launcher/ingress
tests; package installation and combined SQL runtime remain unapproved.
Use two dedicated locked, non-login OS accounts: selected fixture UID/GID
`62401` for the transport supervisor and `62402` for the source child. Refuse
existing ID/name collisions; do not repurpose `nobody`. Freeze the chosen numeric
IDs in the host admission recipe. Neither account has other services, a login
shell, supplementary groups, sudo/polkit rules or database credentials.

Prefer a short **SETPCAP-assisted bootstrap** over retaining dormant capability
bounding bits. The system-manager service runs the fixed root-owned launcher
with its default root identity, omitting explicit `User`/`Group` directives and
requiring all actual real/effective/saved/filesystem UID/GID values to be zero.
It has only `CAP_SETUID CAP_SETGID CAP_SETPCAP` in its capability
bounding set, an empty ambient set, `NoNewPrivileges=yes`, no keep-caps behavior
and no privileged `+`/`!` command prefix. Its argv contains only the fixed bundle
and derived scope identity. Python uses `-I -S -B`, a finite environment, no
shell, no user-site loading and no source input before the drop. The launcher is
single-threaded; its only pre-drop inputs are trusted captured code/configuration
and bounded kernel state.

This directive choice is deliberate: the first exact guest test with explicit
`User=0` stopped at the initial privilege check. It observed P/E `320`, I `256`
and B `448`, rather than P/E/B `448` with empty I/A. In systemd 255,
`exec_invoke`'s explicit-valid-user/seccomp condition enables
`keep_seccomp_privileges`; its later UID path drops SETUID unless ambient and
retains SETPCAP. The system manager's default-root path avoids that adjustment.
No capability requirement, syscall filter or permanent-drop check is relaxed,
and ambient capability fallback remains forbidden. This is a system service,
not a user-manager service. [systemd 255 execution implementation](https://raw.githubusercontent.com/systemd/systemd/v255/src/core/exec-invoke.c).

The fixed sequence is:

1. Check root real/effective/saved/filesystem IDs, `NoNewPrivs=1`, the exact three
   permitted/effective/bounding capabilities, empty inheritable/ambient sets and
   one thread. Clear supplementary groups. Refuse unexpected securebits; lock
   `KEEP_CAPS` and `NO_SETUID_FIXUP` **off**, and ambient capability raising off.
   Set dumpable to zero. Every syscall result is checked.
2. While SETPCAP is still effective, drop every supported bounding bit with
   `PR_CAPBSET_DROP`; verify the entire bounding set is zero. Drop SETPCAP from
   the permitted/effective sets too, retaining only SETUID/SETGID for the next
   two steps. Do not exec another privileged launcher. Linux's bounding-set
   operation changes the bounding set without removing the current permitted
   SETUID/SETGID authority. [Linux 6.8 capability implementation](https://raw.githubusercontent.com/torvalds/linux/v6.8/security/commoncap.c),
   [bounding-set API](https://man7.org/linux/man-pages/man2/PR_CAPBSET_DROP.2const.html).
3. Create the one child with the captured absolute Python/entrypoint and
   `Popen(user=62402, group=62402, extra_groups=(), close_fds=True,
   pass_fds=(), start_new_session=True, umask=0o077)`. Inherit only its three
   anonymous control/output pipes, never a socket, credential, journal directory
   FD or supervisor control FD. Do not use `preexec_fn`. Keep the original
   Popen handle; do not recreate it from a PID. CPython 3.12.3 performs group/UID
   changes before exec; the child must still verify its resulting saved IDs.
   [CPython implementation](https://raw.githubusercontent.com/python/cpython/v3.12.3/Modules/_posixsubprocess.c),
   [Popen credential parameters](https://docs.python.org/3.12/library/subprocess.html).
4. Before reading application READY/GO/body data or opening the request record,
   permanently drop the parent with `setgroups([])`,
   `setresgid(62401,62401,62401)`, then `setresuid(62401,62401,62401)`. Set/check
   dumpable zero again after the identity change. Require all five capability
   sets — effective, permitted, inheritable, ambient **and bounding** — to be
   zero; real/effective/saved/filesystem UID/GID must all equal the supervisor's
   IDs, groups must be empty, and keep-caps/fixup checks must still match.
   [Permanent ID changes](https://man7.org/linux/man-pages/man2/setresuid.2.html),
   [dumpable resets](https://man7.org/linux/man-pages/man2/PR_SET_DUMPABLE.2const.html).
5. The captured child entrypoint performs the equivalent post-exec self-check
   for its different IDs, zero capability sets, no-new-privileges, empty groups
   and dumpable zero **before reading stdin**. Only then may the unprivileged
   supervisor send the finite request and consume READY. The outside guardian
   verifies both actual `/proc` identities, capability/NNP fields, parentage and
   memberships before capture and again before GO. Self-reported JSON alone
   does not replace those checks. Failed initialization means no grant/GO;
   the outside guardian retires the scope.

`NoNewPrivileges` is compatible with the privileged drop syscalls above: its
irreversible restriction covers privilege acquisition through exec, not an
already-authorized `setuid`. No keep-caps/ambient setting may defeat the intended
drop. The alternative with only SETUID/SETGID could clear active privileges but
would leave those two bounding bits; it relies additionally on NNP to prevent
exec-based reacquisition. It is **not** the selected all-zero policy, and there
is no automatic fallback to it if SETPCAP/bootstrap verification fails.
[Kernel NNP contract](https://www.kernel.org/doc/html/latest/userspace-api/no_new_privs.html),
[systemd 255 execution settings](https://raw.githubusercontent.com/systemd/systemd/v255/man/systemd.exec.xml).

After separation, the supervisor can still wait for its exact child but cannot
signal a different UID without additional authority. Adapt cancellation and
timeout handling accordingly: close the control pipe where possible, wait only
within the remaining bounded allowance, then report unresolved and request the
outside guardian's existing fence/whole-scope stop. Add no retained CAP_KILL,
privileged signal helper, PID-based replacement handle or invented exit status.
A normal exact wait plus complete response retains the existing joined-child
path; a lost supervisor instead requires scope evidence and full charging.
[Linux signal permissions](https://man7.org/linux/man-pages/man2/kill.2.html),
[child-wait semantics](https://man7.org/linux/man-pages/man2/waitpid.2.html).

The unit keeps the reviewed protections and requires
`SystemCallArchitectures=native` plus
`RestrictAddressFamilies=AF_INET AF_INET6`. Explicitly deny `socketpair`,
`io_uring_setup`, `io_uring_enter`, `io_uring_register`, `ptrace`,
`process_vm_readv`, `process_vm_writev` and `pidfd_getfd` through the unit's
syscall filter. There is no socket activation, inherited socket or inherited
io_uring FD. Address-family filtering alone covers `socket(2)`, not alternative
socket-creation paths: Linux 6.8's io_uring socket operation directly calls
`__sys_socket_file`. Blocking all three io_uring syscalls and alternative ABIs
is part of this synchronous Python policy, not an optional hardening measure.
[systemd 255 address-family limits](https://raw.githubusercontent.com/systemd/systemd/v255/man/systemd.exec.xml),
[Linux 6.8 io_uring socket creation](https://raw.githubusercontent.com/torvalds/linux/v6.8/io_uring/net.c).
Control communication uses anonymous pipes and guarded files, not a source-owned
Unix socket. Keep `RestrictNamespaces=yes`, `ProtectControlGroups=yes`, no
delegation, read-only system files and inaccessible credential/guardian paths.
For this strictly single-threaded transport, require `TasksMax=2` on the service
and retained slice: supervisor plus source child, with parser/DB work outside.
This also prevents a source child from leaving a live descendant during a normal
parent-wait path. If its supervisor dies, only scope evidence remains valid.
Task limits count threads too; actual Python/TLS behavior must pass rather than
silently increasing the limit. [systemd task accounting](https://raw.githubusercontent.com/systemd/systemd/v255/man/systemd.resource-control.xml).
`TasksMax=2` does not replace the syscall restrictions. Before admission, a
bounded negative probe in the actual service context must verify the effective
native-ABI policy and denial of all three io_uring syscalls, `socketpair` and
non-allowed address families without attempting an external connection.
The fixture remains loopback-only. The prerequisite run verifies the finite
denials listed below; it does not establish exhaustive process-escape resistance,
execution of an alternative ABI or kernel BPF filtering of external destinations.

The prerequisite implements the following adapter changes, preserving the
original same-UID fixture contract:

- Split `PausedChild` construction into **spawn only**, with no request-file
  read, stdin write or READY consumption, followed by a separate bounded
  request/READY handshake after the supervisor's permanent drop. Keep the same
  exact Popen handle across both phases. The original constructor still performs
  the immediate handshake; the Linux launcher uses the explicit spawn-only API.
- Add a Linux identity check pinned to the **source** UID/GID `62402`, not the
  supervisor's current UID. Read all four `Uid` and `Gid` values and `Groups`
  from `/proc/<pid>/status`, plus the required capability/NNP fields; retain
  exact PPID, kernel start ID, boot, invocation and cgroup checks. Do not infer
  these IDs from ownership of the `/proc/<pid>` directory; one inode owner does
  not establish all UID/GID fields. The outside guardian performs the process
  checks; a process that cannot inspect a peer must not substitute self-report.
  `uid_policy.process_identity` supplies the separate Linux check.
- Add the dedicated large-witness publisher/recovery path below. The current
  `linux/common.publish` has a 64 KiB limit and creates a new temporary before
  checking whether the destination exists. Raising that limit would not provide
  the required crash-safe two-slot bound. The separate `witness_slots` implementation
  preserves that bound without changing the small-record publisher.

## Ingress ownership and reserved action envelope

Keep the authoritative journal at the derived root-owned `0700` path above.
Place service input/control under a separate root-owned `0750` scope directory,
group-readable only by the supervisor, and give that supervisor a private `0700`
ingress subdirectory. The source UID cannot traverse either. Both processes may
read the shared root-owned immutable bundle; neither can modify it. Only the
guardian writes capture, grant/GO checkpoints, fences, observations, receipt
arguments and acknowledgements. The executor supplies its bounded grant/result
messages; it cannot submit a parent-wait witness on the supervisor's behalf.
The service receives no database/Supabase environment or credential FD.

The supervisor publishes one closed, fsynced, no-overwrite ingress witness. The
guardian checks owner, regular-file type, source/attempt/process identity, exact
schema, body length/hash and retained wait provenance, then copies those exact
bytes into a root-owned no-overwrite checkpoint and syncs file and directory.
Only after that barrier may it unlink/sync the ingress copy. An incomplete or
changed ingress file is not recovered as a successful body. Source bytes occur
once in the retained witness; parser input checkpoints contain a hash/reference,
not another base64 copy. A later terminal witness contains no body. A scope
observation never manufactures a normal witness.

Use **two fixed body slots**, each at most `MAX_OUTPUT=1,572,864` bytes: one
supervisor-owned ingress inode and one guardian-owned publication inode. Each
slot has only a fixed pending name and a fixed final name; a pending/final pair
may be hardlinks to the **same** inode. Do not allocate random body temporaries.
The supervisor publishes once and is never restarted to reproduce a witness.
Before accepting its final name, the guardian requires the producer's file to
be closed and stable and accounts for any retained pending alias. An incomplete
ingress slot remains unavailable body evidence; it does not trigger a second
source request.

The guardian serializes publication/recovery for this action with one local
exclusive lock, never inherited by the service. A busy lock is not taken over
on a timer. This lock protects file operations only; it is not a grant or proof
of resource retirement. Under that lock, recovery inventories the fixed names
before allocation and rejects unexpected files, excess names/bytes, symlinks,
non-regular files, wrong ownership or unexplained link counts. Open and inspect
through trusted directory FDs with no symlink following. Then apply these rules:

1. **A guardian final already exists:** validate its complete witness against
   the captured action and any retained ingress copy, and successfully fsync
   its FD and the guardian directory before relying on it. A prior crash may
   have exposed the final link before its directory sync completed. Do not copy
   the body again. Any guardian pending name must alias that exact inode; a
   different pending inode is a protocol violation that retains the action for
   review, not permission to allocate or discard another body. Remove/sync the
   known alias, then remove/sync the matching ingress names after the durable
   guardian barrier. A valid final with ingress already absent is normal replay.
2. **Only a guardian pending inode exists:** retain and account for it. If it
   is complete, validate it against the still-retained closed ingress before
   publication. If it is partial, and is the single root-owned unlinked-to-final
   slot (`st_nlink=1`), bounded copying may truncate/rewrite that **same inode**
   from validated ingress; it must not allocate a replacement temporary. Never
   truncate an inode that has a final alias. Missing/changed ingress or an
   unexplained alias makes this path unresolved; do not manufacture a body or
   fall back to a new body inode.
3. **Neither guardian name exists:** exclusively create the fixed pending slot
   and copy at most `MAX_OUTPUT` bytes from validated ingress into that one inode.
   A retained partial ingress or guardian slot already consumes its full
   reservation; it is not free space for an additional copy.
4. Fsync the complete guardian pending inode, link it to the final name without
   replacement, then fsync the directory. Only after that barrier may pending
   aliases and ingress names be removed and their directories synced. If the
   final link already exists, return to rule 1 without a fresh allocation.
   Any failed barrier blocks dependent receipt/result RPCs and leaves the same
   bounded slots for recovery.

The ordinary JSON-journal reopen path must recognize and validate these fixed
pending/final slots through this recovery routine before exposing the witness
as durable. Do not call the existing generic publisher on a large witness, even
on replay. In particular, final-link → directory-fsync → crash before ingress
unlink leaves both full inodes; a retry validates that final and creates **no
third `MAX_OUTPUT` body**. The separate 64 KiB temporary allowance below cannot
be borrowed for a body copy.

Reserve the following **serialized-byte** envelope before a grant. The two
body slots include simultaneous ingress and guardian publication; hard-link
publication may add a name, not another body inode. Allow at most one ordinary
checkpoint publication at a time.

| Reserved category | Maximum bytes |
|---|---:|
| Two witness storage slots, each existing `MAX_OUTPUT` | 3,145,728 |
| Eight metadata records at 64 KiB: input, intent, grant, grant-status, parser-input, parser-output, result, result-ack | 524,288 |
| Eight 16 KiB records: capacity, capture, fence, observation, both receipt arguments and both acknowledgements | 131,072 |
| Six 4 KiB controls: READY, GO intent/control, privilege check, stop request, terminal witness | 24,576 |
| Captured source/parser/manifest and rendered-unit allowance | 262,144 |
| One simultaneous ordinary publication temporary | 65,536 |
| **Total** | **4,153,344** |

This leaves 40,960 bytes below the existing 4 MiB bound. Enforce each named slot,
the total and at most 32 action file names across journal, ingress/control,
rendered units and temporary publications; do not independently allow 32 files
in every directory. A hardlink alias consumes a name even though its body bytes
are counted once by inode. The planned maximum is 30 names: 22 metadata/control
records, four witness names, two rendered unit files, one ordinary publication
temporary and one zero-byte action lock. Retained partials and aliases count;
resolve the existing ordinary temporary before allocating another. No per-poll
records, unbudgeted lock files or raw diagnostic logs enter this set.
If the actual captured graph or worst-case RPC/Unicode envelope exceeds a slot,
reject before granting and review the layout; do not truncate metadata or raise
limits while an action is running.

The concrete storage choice for review is a shared, content-addressed immutable
bundle instead of copying its many members into every attempt. Its full bounded
source size remains charged in the table even though its member files are outside
the 32 mutable action names. This differs from the Mac fixture's conservative
per-attempt bundle file count and must be explicit in the Linux implementation.
Retain referenced bundles until their journals settle. Executable/runtime storage,
filesystem metadata and PostgreSQL are separate bounded host disk inputs; 4 MiB
is not a promise of physical allocation or RAM usage. Require a separate free
disk reserve before admission, and never delete unresolved evidence to make room.

## Guest readiness and finite dependency plan — no package installation performed

The retained [`platform-and-cleanup.json`](../../.artifacts/linux-lima/platform-and-cleanup.json)
and [`review-bundle.json`](../../.artifacts/linux-lima/review-bundle.json) establish
Ubuntu 24.04.4/aarch64, Linux 6.8.0-117, systemd 255.4, Python 3.12.3 and OpenSSL
3.0.13. The previous tests also invoked the guest's OpenSSL CLI. The saved
preflight/configuration disables package resolution and upgrades. Neither the
earlier logs nor manifests inventoried PostgreSQL, Deno, Node or esbuild. The
subsequently authorized prerequisite boot inspected the required PATH and named
packages: PostgreSQL server/client, Deno, Node and esbuild were absent from that
targeted inventory. The existing UID/GID 62401/62402 and proposed account names
were unused. Temporary locked accounts were created only for the tests and
removed afterward; no package was installed. The local checkout has only
Darwin-arm64 Deno/esbuild executables. The exact isolated guest is stopped again.

Before any combined SQL/parser run, review the exact finite dependency
transaction below; the prerequisite authorization did not permit installation:

- PostgreSQL **17** server/client, matching the hosted major, from the PostgreSQL
  project's signed Noble/arm64 repository. Review the exact minor/package
  dependency transaction first; no distribution upgrade, automatic main-cluster
  creation or enabled database service. The harness initializes a fresh private
  cluster and loopback certificate-verified TLS, then creates disposable distinct
  capability logins after migrations. No owner-session SET ROLE substitutes for
  those callers. [Official Ubuntu packages](https://www.postgresql.org/download/linux/ubuntu/).
- The exact lockfile tarballs `@deno/linux-arm64-glibc@2.9.6` and
  `@esbuild/linux-arm64@0.28.2`, verified against their existing SHA-512 integrity
  entries before bounded extraction. The native executables can be invoked
  directly; Node/npm, a compiler toolchain and install scripts are not required
  for the current parser builder. Copy only its captured TS inputs and existing
  `saxes@6.0.0`/`xmlchars@2.2.0` JS/JSON graph. Downloads, if required, are package
  preparation only and need the separately reviewed install step; no arXiv call.

Build a **new Linux parser identity** using the unchanged captured
[`build-metadata-parser.py`](../../scripts/build-metadata-parser.py) under the
actual guest Python, pinned Linux esbuild and pinned Linux Deno. Retain the
builder/source/compiler/runtime/output hashes and exact Deno version, and keep
the runtime-hash equality check. Compare the generated JS against the reviewed
current parser output; a changed output requires review. Do not relabel the Mac
manifest or require its machine-specific Deno hash on Linux. Freeze the resulting
Linux parser and gateway bundle together, including the actual Python/Deno/psql
executable identities and observed systemd/kernel/TLS versions. Hashes preserve
provenance; they do not establish OS admission by themselves.

Before combined SQL tests, the narrow launcher checks must show all real,
effective, saved and filesystem IDs and all capability sets, empty groups,
NNP/keep-caps/dumpable behavior, denied privilege reacquisition, source denial of
supervisor controls/credentials/ptrace/FD export/cgroup writes, and a real normal
cross-UID wait. Failure injection must include a drop syscall failure, attempted
extra task, cancellation that cannot signal the child, and guardian retirement
without a forged wait result. The maximum-body test must observe both copies and
every publication name at the worst overlap. Inject restart after partial copy,
file fsync, final link, directory fsync and before ingress unlink; include a
retained hardlink alias. Recovery must reuse the existing pending inode or final
publication, never allocate a third body, and stay below both byte/name limits.
Failed repeated fsync must cause zero dependent RPCs. Conflicting pending/final
inodes, changed ingress and unexpected names remain unresolved without deletion.
These gates precede any claim that the combined local adapter is ready; cloud
host/account selection and source-network admission remain separate.

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

The original Linux checkpoint's 23 tests, the launcher/ingress evidence below
and the earlier integration's 54 tests validate separate fixture contracts.
None of the combined database/runtime checks above is claimed complete.
Cold reboot, clone/restore, host replacement and arbitrary kernel-stuck work
remain quarantined rather than being treated as already tested.

Independent review checked the existing candidate-012 grant/receipt/refund
paths and the committed lifecycle fixture. It found no structural blocker in
this scope, including executor-before-source receipt ordering, ambiguous COMMIT
handling and separate authority roles. That review does not establish any of
the combined checks, production UID separation or host admission.

## Launcher/ingress verification checkpoint

The isolated guest passed **41 tests in 8.080 seconds**, including the original
23 lifecycle checks and five new real systemd/TLS schedules. The new schedules
verify a one-MiB response with exact cross-UID parent wait, the all-zero
post-drop privilege sets, 19 finite kernel denials, refusal of missing bootstrap
capabilities, cancellation of a stopped child that its supervisor cannot signal,
and guardian-only retirement after supervisor death. The two body-slot tests
cover partial copies, failed barriers, aliases, conflicting data and recovery;
filled synthetic records reach 4,153,344 serialized bytes and 30 names. This is
the reserved envelope, not yet admission of actual combined SQL journal records.

After that guest run, one additional local test actually exits the writer at
four publication boundaries without cleanup and recovers in a fresh isolated
Python process. The local suite passes 29 checks with 13 Linux-only skips; the
extra process-crash test was not rerun in Linux and is not a power-loss test.
All 23 direct-gateway and eight coordination regressions pass after the shared
spawn/handshake refactor. Post-spawn setup failures preserve ownership of the
exact Popen handle and never invent a wait witness.

Evidence is `.artifacts/linux-prerequisite-guest-final.log`,
`linux-prerequisite-local-final.log`, `linux-prerequisite-v1-gateway.log` and
`linux-prerequisite-v1-coordination.log`. The retained guest source snapshot is
`.artifacts/linux-prerequisite/becc0dfaab1ac7061473b5464fb491bfc97c28068926f3efc8e5db456c3f6659/`;
runtime bundle identity is
`b1bb7ab854eda341899f9c25dba32395bb72ab2b74d1df9078feb21b1cd54906`.
The first capability refusal and sanitized kernel state remain in the earlier
guest logs and `linux-prerequisite-bootstrap-failure.json`. No capability/filter
was relaxed to pass that refusal; the default-root directive correction above
was reviewed before rerunning.

Cleanup observed no owned units, attempts, bundles, fixture accounts or groups;
the sole authorized guest is stopped. No package, credential, source request or
SQL change belongs to this checkpoint. The source-to-guardian copy still requires
the combined adapter's strict captured-action/wait-witness validator before it
can support an observer RPC. The fixture callback and empty-scope observation
have no database authority. Whole-action journal enforcement, distinct database
logins, actual Linux parser identity and combined recovery remain next work.

## Single outbound authority and rollout boundary

There is **one aggregate automated arXiv authority across staging, production,
developer tools, refresh and retry workers**. The first admitted deployment is
staging-only; production stays outbound-disabled. A second independently active
project-local gate is prohibited. Production later uses the same narrow source
authority, or takes over after a drained, quarantined handoff that disables the
old environment. This proposal does not build that cross-project routing layer.
Inventory other controlled callers before activation without expanding the
user's NAS permissions.

Next work is the local combined action against the already reviewed, unapplied
012 delta, after reviewing the exact dependency/runtime preparation transaction.
A hosting account is needed only for actual deployment and host admission. Keep original
download/verification/read and paid-provider paths disabled; obtaining metadata
does not complete the reader. Provision no host or credentials from this
document, and make no additional commitment beyond the agreed $100/month
incremental beta budget.

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
restrictions require review and negative tests before admission. The original
lifecycle fixture used one credential-free UID; the split-UID prerequisite below
adds local evidence, not production admission. Root/host compromise remains outside the
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

### Pinned dependency proposal, 2026-10-04

This is a **metadata-only review**, not an executed installation. The exact guest
remained stopped. PGDG's Noble `InRelease`, dated 2026-09-30, verifies under
fingerprint `B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`; its SHA-256 entries match
the retained `main/binary-arm64` and `17/binary-arm64` indexes. The selected
packages below match hosted PostgreSQL 17.11. Use both components and pin
`libpq5` explicitly: `main` currently offers libpq 18 as its newest version.
Do not install the unversioned PostgreSQL metapackages.
[PGDG Ubuntu repository](https://www.postgresql.org/download/linux/ubuntu/),
[PostgreSQL 17.11 release](https://www.postgresql.org/docs/release/17.11/).

| Package | Exact version / architecture | SHA-256 from signed index |
|---|---|---|
| `postgresql-17` | `17.11-1.pgdg24.04+2` / arm64 | `4f70a5f9101cab17348f40e4534ea96f9e70b8bb4e44a2b4c8b314e3dee2aca7` |
| `postgresql-client-17` | same / arm64 | `07d62cc509748510bb8e862fbe58d1050e99fb1d457f09036f04253d9995aba7` |
| `libpq5` (component `17`) | same / arm64 | `31fff8c4df7f2ef61f0cf579cd2b9b9fa101a842e1a01ad940c0855587010aea` |
| `postgresql-common` | `293.pgdg24.04+1` / all | `4393363fa55e5351c6948939927c48419d804197bf638e295a78824daecff6b3` |
| `postgresql-client-common` | same / all | `80ae115f63ba67fbba442f6b75a468a559b77a3ee3b0be357a4c49e70bf860c5` |

These five packages total 18,851,700 download bytes and 73,395 installed KiB,
**excluding dependencies**. Server requirements include libllvm19, libicu74,
locales, ssl-cert and the ordinary Noble runtime libraries; common also needs
Perl/libjson-perl, ucf and init helpers. The current schema needs no separate
pgvector/extension package. The retained guest inventory does not contain full
dpkg status, package indexes or existing service policy, so the complete closure
and its upgrade/removal set are not yet known. Do not label this table an exact
APT transaction until the next inventory/simulation closes that gap.

The Linux Deno/esbuild registry metadata matches the committed lockfile's exact
URLs and SHA-512 SRI. ECDSA registry signatures verify against the fetched npm
registry key; this verifies the signed name/version/integrity, not an independently
reviewed build-provenance attestation. No binary tarball was downloaded here.
Deno advertises three files / 84,906,430 unpacked bytes; esbuild three files /
10,289,789 bytes. Later extraction must validate those actual files and SRI,
reject links/traversal/duplicates, and run no npm lifecycle or shell installer.
Keep total compressed tool downloads within 96 MiB, extracted Deno within 96 MiB
and esbuild within 16 MiB; these are refusal limits, not measured download sizes.
[npm signature contract](https://docs.npmjs.com/about-registry-signatures/).

Raw signed indexes, registry metadata/signature checks, package paths, sizes and
both full SRI values are retained in `.artifacts/linux-dependency-review/`.
`review-manifest.json` SHA-256 is
`a9d1f941a061b2a6e9b2f0da7c6b2c97db80489de65498c0e96735e5c01df1ec`.
Package and tool payload verification remains required after any later download.

The root's current project-volume `df` observation is approximately **11 GiB
available**; each retained native diagnostic build tree uses about 338–339 MiB.
Do not infer available space from the guest's 20 GiB sparse-disk ceiling. Before
any preparation, recheck both actual host and guest free space. Reserve at least
8 GiB host free initially and a projected 4 GiB remaining margin, allowing up to
512 MiB host package/tool staging, 3 GiB additional guest allocation, 128 MiB
evidence and one 350 MiB native build. Check actual allocation after each phase;
APT Installed-Size is not a physical-space guarantee. No VM disk growth beyond
that allowance, full-disk rollback copy or deletion of baseline/evidence/unrelated
files is implied. A space shortfall pauses preparation for root review.

### Finite preparation transaction proposed for root review

1. On the **same authorized guest only**, first capture full dpkg status,
   `dpkg --audit`, exact APT sources/preferences/hooks, active package managers,
   free disk, existing PostgreSQL users/clusters/units and `policy-rc.d`. This
   proposal itself does not authorize that boot. Use a private APT lists/cache
   directory and a single explicit signed PGDG/Noble source set; disable
   translations, retries and inherited proxy settings. Resolve with
   `--no-install-recommends`, exact versions and `--no-remove`; record every
   package/version/architecture/hash and installed-size delta. Reject existing
   package upgrades/downgrades/removals, third-party repositories, kernel/init/
   Python/TLS upgrades, or an unexpected package before installation. A necessary
   existing-library update requires a revised transaction and runtime review.
2. Freeze/download only that reviewed closure; allow at most 384 MiB of package
   archives and 1 GiB additional installed files, with at least 4 GiB free guest
   space. Inspect the **verified exact** `.deb` control scripts/triggers and unit
   files before root accepts the install step. Those scripts have not been
   inspected in this metadata-only pass. Use no development/docs/metapackages,
   recommendations, Node/npm or compiler toolchain.
3. Before package configuration, preserve any existing service policy and refuse
   an unreviewed collision. Set PostgreSQL's `create_main_cluster=false` and
   `start_conf=disabled`; use the documented service-policy denial (`101`) for
   maintainer start/restart actions and mask the exact reviewed PostgreSQL units.
   Install helpers/common first, verify the cluster policy, then install the
   versioned server/client closure. No `main` cluster, enabled service or listener
   may appear. Explicitly check package-trigger side effects: the package-owned
   postgres account/directories, ssl-cert material and alternatives are expected
   system changes, not fixture credentials or proof of a clean rollback.
   [Cluster defaults](https://manpages.debian.org/unstable/postgresql-common/pg_createcluster.1.en.html),
   [service policy](https://manpages.debian.org/unstable/init-system-helpers/invoke-rc.d.8.en.html).
4. Stage Deno/esbuild in the task-owned tool prefix, retaining their package JSON
   and exact lockfile. Recreate the parser builder's finite expected layout,
   invoke native esbuild directly, and require Deno's observed version and hash
   to match the new Linux manifest. No implicit package resolver is used.
   Bound package/tool/build/cluster/journal work together to 2 GiB excluding the
   separately capped installed packages, and stop admission below the disk reserve.
5. Treat installation as non-atomic. On failure, retain the transaction/logs,
   confirm no package service/listener escaped the suppression, and stop the
   guest. Do not run a broad repair/upgrade/autoremove or delete uncertain action
   evidence. Exact rollback is a separately reviewed restoration/recreation of
   this disposable task guest from its pinned base, not a claim that `apt purge`
   reverses every script. On success, keep the verified tools installed for this
   task, package services disabled, and clean only confirmed fixture resources.

### Phase 1 inventory and signed-metadata simulation completed

On 2026-10-04, the exact task guest `timestep-lifecycle-646` was started only for
inventory and dependency resolution, then stopped normally. This phase installed
nothing and downloaded no `.deb` or tool payload. The full before/after dpkg
status, package list, APT policy/source hashes, archive key, account/UID and
PostgreSQL-path checks match. There are 266 installed packages and one unrelated
residual `config-files` entry; all installed versions were pinned against change,
and the residual package against reinstallation. No PostgreSQL unit, cluster or
account exists, and 62401–62403 remain free.

The base image has Docker packages/sources and Ubuntu ESM APT hooks. The private
resolver inherited neither: its first-read `APT_CONFIG` replaces source, key,
status, preferences, lists, cache and configuration-part paths, clears hooks, and
uses no proxy, redirect, retry, recommendation or insecure-repository fallback.
The initial direct update failed DNS resolution for both official repository
hosts. Guest networking was left unchanged. Instead, 24,150,742 bytes of official
HTTPS metadata were fetched on the host with redirect/proxy refusal, checked
against signed releases, and copied into an owned local-file mirror. Guest APT
independently verified those releases and indexes. Ubuntu signatures use
`F6ECB3762474EDA9D21B7022871920D1991BC93C`; PGDG uses the fingerprint above.
The retained initial refusal logs also record the harmless inventory-parser
correction needed to distinguish the residual configuration entry from a
partially configured package.

The successful unprivileged `apt-get --simulate --no-install-recommends
--no-remove --no-upgrade --no-download install` retained the five exact PGDG
pins above and resolved these seven additional packages:

| Dependency | Exact version / architecture | Archive bytes | Installed KiB |
|---|---|---:|---:|
| `libjson-perl` | `4.10000-1` / all | 81,896 | 238 |
| `ssl-cert` | `1.1.2ubuntu1` / all | 17,826 | 66 |
| `libicu74` | `74.2-1ubuntu3.1` / arm64 | 10,806,898 | 36,201 |
| `libxml2` | `2.9.14+dfsg-1.3ubuntu3.9` / arm64 | 737,396 | 2,211 |
| `locales` | `2.39-0ubuntu8.9` / all | 4,231,704 | 16,716 |
| `libllvm19` | `1:19.1.1-1ubuntu1~24.04.2` / arm64 | 27,428,566 | 121,821 |
| `libxslt1.1` | `1.1.39-0exp1ubuntu0.24.04.3` / arm64 | 166,772 | 456 |

The complete transaction is **12 new packages, zero upgrades and zero removals**:
62,322,758 archive bytes (59.44 MiB) and 251,104 installed KiB (245.22 MiB).
Those metadata totals fit the reviewed 384 MiB archive / 1 GiB installed caps;
physical usage and maintainer-script effects remain unmeasured. In particular,
this does not inspect or approve package service/account/certificate/locale
scripts. Existing libc, Python, TLS, kernel and init packages remain unchanged.

Evidence is under `.artifacts/linux-dependency-review/phase1-2ae69ec54fe3/`.
`closure.json` records every exact package URL/version/architecture/size/SHA-256,
release/index evidence and command hashes; its SHA-256 is
`4b6169ea25983525967f19711b62d18d96e2535bca02f76faa37567e0712ccf8`.
`resolver-r3/simulation.stdout` contains the transaction, `update.stderr` the
successful signature checks, `unchanged-state.json` the inventory comparison,
and `stopped-state.json` confirms only the owned guest is stopped. Signed raw
compressed metadata remains on the host; the guest's isolated resolver trees
are retained for review, allocating 245,702,656 bytes in total. Guest free space
was 18,474,143,744 bytes after resolution; host free space was 11,419,500,544 bytes
after stop. Recheck both reserves and the captured dpkg state before another
phase. No further boot, payload fetch, package script or installation is implied
by this completed simulation.

### Phase 2 payload inspection completed; installation still proposed

The 12 frozen archives were downloaded from their exact official HTTPS URLs with
no proxy, redirect or retry, then matched against all lengths and SHA-256 values
in the Phase 1 closure before inspection. Their total remains 62,322,758 bytes.
Host-only archive inspection retained all control files, member inventories and
relevant helper/configuration/unit text; it read 254,387,413 regular-file bytes
without installing them. No maintainer script, downloaded executable, guest
service or database was run. The guest remained stopped throughout.

The pinned Linux tool tarballs also verify against the lockfile SHA-512 SRI and
npm registry signatures. Together they use 45,280,793 compressed bytes, below
96 MiB. Each contains exactly three regular files: package JSON, README and its
binary (`package/deno` or `package/bin/esbuild`), with no links or lifecycle
scripts. Bounded extraction retained them as non-executable mode 0400 files.
Deno uses 84,906,430 extracted bytes, below 96 MiB; esbuild uses 10,289,789 bytes,
below 16 MiB. Their package identities are 2.9.6 and 0.28.2; runtime versions have
**not** been observed by execution. The AArch64 ELF hashes are respectively
`d08d392418df53f4e6e88a08909c0e1bccbf9adcead7232df72b6ad6075ec416`
and `90bd269553d258e80b19e3ccab4f98f0831f87442a2f056510ce24fd1b425fc2`.
Registry signatures do not substitute for a reviewed provenance attestation.

The verified scripts make the following installation effects explicit:

| Payload | Effects requiring the later install scope |
|---|---|
| `postgresql-common` | Creates postgres user/group/home, adds ssl-cert membership, owns config/socket/log/cache directories, registers pg_config diversion, manages createcluster.conf through ucf, builds dictionaries, writes `/etc/apt/apt.conf.d/02autoremove-postgresql`, reloads systemd, registers SysV startup and requests enable/start of postgresql.service. Its legacy cleanup can remove old PG APT/sysctl files. |
| `postgresql-17` | Its shared configure helper normally creates `17/main`, updates alternatives/APT policy, reloads systemd and invokes PostgreSQL startup. Explicit `create_main_cluster = false` must already be effective before this package is configured. |
| `ssl-cert` | Direct postinst creates the ssl-cert group and snakeoil key/certificate/hash link, adjusts `/etc/ssl/private` using dpkg-statoverride, then enables/starts ssl-cert.service. Service denial does **not** suppress the direct certificate operation. |
| `locales` | Debconf/configuration can migrate `/etc/default/locale` to `/etc/locale.conf`, populate locale.gen and invoke locale-gen. Its default regeneration removes existing locale archives/directories except `C.utf8`; this is not harmless on an arbitrary host. |
| Client packages and libraries | Client packages manage obsolete conffiles and manpage alternatives. Five library packages activate ldconfig; libjson-perl has no maintainer script. Existing trigger handlers still require the narrow pre-install check below. |

No cron or sysusers payload is present. PostgreSQL supplies one tmpfiles rule
for socket/log directories, a generator that attaches only auto-start clusters,
and seven backup/WAL service/timer templates in addition to its two main units.
Those templates have no instance enabled by the inspected package scripts.
The logrotate configuration only rotates the package log directory; logrotate
itself is not in the resolved transaction. Dictionary triggers can write the PG
cache and links from existing hunspell/myspell inputs, so those inputs belong
in the collision inventory too.

The smallest proposed installation is still **two bounded package stages**, with
these preconditions and suppression, not a general machine provisioning script:

1. Recheck host/guest reserves, exact dpkg state, inactive package managers and
   the 12 payload hashes. Read the existing dpkg configuration, trigger registry,
   applicable installed trigger scripts, init-system-helpers and ucf helpers.
   The Phase 1 package list includes libc-bin and systemd but no man-db; do not
   infer the full trigger set from the new packages' own trigger files. Refuse
   unexpected execution hooks, pending configuration or changed dependencies.
2. Before mutation, capture the exact unit/mask/wants/SysV links, PG account/group,
   directories/diversions/alternatives, service policy, the exact legacy
   `/etc/apt/apt.conf.d/01autoremove-postgresql*` and PG sysctl paths, and the
   logrotate file plus its ucf/ucfr registrations (which common purges on first
   configuration). Also capture the
   ssl-cert group/statoverride and certificate **metadata only**, locale files,
   generated locale directories, debconf values, `/var/lib/locales/supported.d/*`,
   `/usr/local/share/i18n/SUPPORTED` and custom locale inputs, plus the dictionary
   input inventory.
   Require no existing PG state or conflicting policy/unit/diversion. Existing
   custom certificate state, generated locales other than `C.utf8`, active locale
   selections or custom dictionary inputs require review; never overwrite them
   by assuming the disposable base is empty. Phase 1's bare template show query
   failed; its separate complete unit-file inventory establishes absence, not
   that failed query. Those additional reads were deferred to the read-only
   pre-install checkpoint below.
3. With an absent policy-rc.d confirmed, create a temporary owned policy returning
   101 and persistent administrator masks for the exact ten shipped PG/ssl-cert
   units/templates. Check the installed helper preserves administrator masks;
   its own unmask bookkeeping is not a replacement for that check. Keep these
   masks while the fixture uses its separate explicit cluster unit. Reject
   activation and verify masks after each configure step. Package scripts may
   still create enable links; disable only those newly owned PG/ssl-cert links
   afterward, and disable the newly registered PostgreSQL SysV links.
   [Policy denial](https://manpages.debian.org/bookworm/init-system-helpers/invoke-rc.d.8.en.html),
   [systemd invocation helper](https://manpages.debian.org/bookworm/init-system-helpers/deb-systemd-invoke.1p.en.html).
4. In a fresh isolated APT configuration using the **real** dpkg status for the
   approved mutation, retain the installed-version pins, disable inherited hooks
   and network acquisition, and simulate the exact local files again. Install
   the 11 non-server archives first with `--no-download --no-remove --no-upgrade
   --no-install-recommends`, noninteractive debconf and no forced dependencies.
   Preseed no generated locales and default `None` only after the locale checks
   permit it; use explicit `C.UTF-8` for the fixture. Accept package-owned postgres,
   snakeoil material, locale-file migration, alternatives, cache and APT policy
   changes as recorded effects of this stage, never as fixture credentials.
5. After postgresql-common has finished its ucf processing, set the owned
   createcluster.conf to explicit `create_main_cluster = false` and
   `start_conf = 'disabled'`, preserving the reviewed template's other settings.
   Require the effective pg_conftool boolean to be `off` and the start setting
   `disabled`, with no conflicting include files or cluster. Only then install
   the final exact postgresql-17 archive. This ordering avoids asking ucf to
   preserve a pre-created policy file during its first configuration.
6. Verify all 12 exact versions configured, dpkg audit clean, no cluster/server
   process/listener or active package unit, persistent masks intact, generated
   startup links disabled and all global changes confined to the reviewed set.
   Remove the temporary policy only after these checks and its exact owned hash
   match; retain it on uncertainty. Stop the guest on failure without automatic
   repair, purge or broad rollback. The tools/parser build and disposable SQL
   fixture are subsequent explicit actions, not part of package configuration.

This authorizes no install by itself. The package scripts and proposed masks
have been read, but suppression on the actual guest, existing-helper/trigger
behavior, fresh collision checks and observed Linux tool execution remain
unverified. Phase 2 evidence is retained under
`.artifacts/linux-dependency-review/phase2-5913d6512f49/`:
`acquisition.json` binds all verified payloads; `package-inspection.json` binds
control/data inventories and saved text; `tool-inspection.json` binds the exact
safe tool members. The finite final manifest supplies their hashes and bounds.
No source-network, provider, hosted migration or credential authority changed.

### Read-only pre-install checkpoint and exact runner candidate

The authorized follow-up inventory started only `timestep-lifecycle-646`, read
the installed helpers/configuration and collision state, then stopped that guest
normally. Its dpkg status still matches Phase 1, with no pending triggers or
active package manager observed. No package, service, account, credential or
configuration mutation was performed. The 29-file evidence manifest is
`.artifacts/linux-dependency-review/preinstall-54a1f27d5129/manifest.json`, SHA-256
`16dd9c019ff77f773cbddcdcd599418c4edad78fef58e25ce746f7e690e54a29`.
After stop, host free space was 11,081,187,328 bytes; guest free space observed
during inventory was 18,461,831,168 bytes. These are historical observations;
the reserved margins still require fresh checks before installation.

The only applicable installed trigger is libc-bin's `ldconfig` branch. Dpkg has
no execution hook in its captured configuration; its existing documentation and
translation exclusions remain intact. Actual systemd helpers preserve the
administrator masks when their own mask bookkeeping is absent, and policy101
prevents their start request. The ten package units, associated helper state,
aliases/drop-ins, PostgreSQL paths/accounts/diversions/alternatives, dictionary
inputs and legacy configuration collisions are absent. Both automatic-APT timers
are enabled and active; their services were inactive. The runner must inhibit
them across both stages rather than treating that observation as a durable lock.

`/etc/locale.conf` is exactly `LANG=C.UTF-8`, with the existing legacy symlink;
only `C.utf8` is generated and no custom locale inputs/selections were found.
The ssl-cert account and snakeoil paths are absent; `/etc/ssl/private` is empty.
Only certificate/private-key **metadata** was inspected. NSS uses files for
accounts and files/DNS for hosts; there is no hostname entry, so the reviewed
certificate helper's `hostname -f` fallback matters. No adduser local hook is
present. These findings permit a concrete candidate, not an installation claim.

The proposed runner is
`.artifacts/linux-dependency-review/install-proposal-b57f82ca019e/install.py`,
SHA-256 `d49310ea286f257e8ef3baf87cdb51a11787a2835c7bc778964d91ab78ce5337`,
with its exact command, input paths and failure model in `REVIEW.md` and the
frozen inputs in that directory's `manifest.json`. Its policy
SHA-256 is
`0285457efb2bf7ef5e14149194d5c59b86d124e0011beaa708ccec9677e21e93`.
It rechecks the captured helper/collision facts, original package status, exact
twelve archives and every non-directory payload destination before mutation.
Two additional preconditions remain **unexecuted**: `/etc/ucf.conf` must be absent
or comment-only, and debconf must use only the finite standard local File/Stack
database configuration. Other configuration refuses before package mutation;
the password database is never read or exported by those checks.

The candidate runs with an explicit small environment inside a distinct private
network namespace, checks down-loopback-only interfaces, local hostname/NSS and
systemd AF_UNIX control, and strips inherited PG/Perl/APT/loader overrides. This
blocks direct IP networking, without asserting that every proxy path through an
existing Unix service is removed. Namespace compatibility has not been tested.
It durably records and creates persistent masks for both APT timers/services and
all ten package units, plus temporary policy101. It only stops the timers after
checking inverse stop dependencies; an active/racing package transaction causes
refusal and is never stopped. Package/helper children use explicit umask022;
private evidence stays under umask077 with exact owned file modes.

The two simulated package stages are the eleven prerequisites, then the server
only after effective `off`/`disabled` cluster policy is verified. The existing
locale must survive unchanged. Source/tool/parser/SQL work is outside this
runner. It reserves its own bounded log/checkpoint bytes before publication and
continues draining/waiting when package output exceeds a cap or a log write
fails; it never kills apt/dpkg on an elapsed timer. Package filesystem growth is
checked between stages, not misrepresented as an enforced disk quota. Incomplete
installation retains masks and policy across boots, with no automatic repair or
retry. Verified success still leaves automatic APT inhibited. The separate
`restore-automatic-apt` action requires a later explicit root decision and
revalidation; it retains the package-service masks. If restored timers start a
normal package job, that job must finish before guest shutdown.

Seven host-only boundary tests pass using temporary files and fake children:
exact permissions under private umask, allocation refusal before publication or
spawn, output-overflow/write-error drain and wait, inverse timer-stop refusal,
and preserved file identity. They establish no real package, namespace or service
outcome. Independent review cleared the frozen runner and verified all nine
manifest members, modes and hashes. The retained architecture snapshot predates
that closing verdict. Invocation and automatic-APT restoration remain separately
subject to root authorization; the guest stays stopped and source/hosted admission
stays off.

### First install refusal and corrected namespace-observer candidate

Root authorized the first frozen runner's INSTALL action once. It refused at
the initial interface check, before creating service guards or invoking package
commands. The original dpkg hash remains
`1d32ae764c3bf460d6b73a815a235cd8d52da790997e11953658501805faf1be`;
no owned mask or policy was created. The exact guest was stopped normally after
two quiet-package checks. The original staging directory and single transaction
checkpoint remain intact; no automatic retry, repair or restoration occurred.
The 39-file attempt/diagnostic manifest is
`.artifacts/linux-dependency-review/install-attempt-0eab15cf9302/manifest.json`,
SHA-256 `70348929f30e446f03c2ba06fc007fe6f43dc7239e9b33f72504d24335801af3`.
It retains 63,008,598 bytes, primarily the exact transfer archive. Host free space
after stop was 9,983,467,520 bytes; fresh reserves are still required next time.

The independently reviewed read-only diagnosis found the error in the observer:
the process was in a distinct private namespace, but inherited `/sys/class/net`
showed the original namespace's docker0/eth0/lo and its up loopback flags. A fresh
socket/ioctl in the current namespace found only lo/index1, flags8/down and no
IPv4 address. The existing `ip` utility independently reported the same down
loopback, empty address information, and empty IPv4/IPv6 route arrays across all
tables. Raw proc IPv6 null/unreachable entries were retained only as diagnostic
data. No interface, route, mount or network setting was changed.
[Kernel sysfs namespace tagging](https://docs.kernel.org/networking/sysfs-tagging.html).

The new candidate is isolated under
`.artifacts/linux-dependency-review/install-proposal-13e0bc58497a/`, with fresh
staging/transaction identities. Runner SHA-256 is
`3664f410751db106bbfe43f0d9a25ffa35f25ca3340aaa074e68a79edd8871f3`;
policy SHA-256 is
`36ff7843a8cc835f70effb6d2f98ee20ab5aaa2d76d14c308006d1d704872642`.
Its `DELTA.md`, exact source/policy diffs and manifest identify the limited change:
replace both sysfs checks with four fixed, successful current-namespace `ip` JSON
queries, each bounded to 64 KiB, plus the fresh-socket corroboration. The exact
existing `/usr/bin/ip` is pinned at 812,352 bytes and SHA-256
`0729cf10c20144fcfe1c758eb618102cf438d9f1573399264e999ffd230b85ed`.
Only a down loopback, empty addresses and empty routes in both families pass;
extra interfaces, UP state, malformed/duplicate/nonfinite/truncated data,
nonzero exit and output overflow refuse. Distinct namespace identity, NSS and
systemd checks remain. No remount or proc-sentinel workaround is introduced.

All package identities/choreography, suppression, locale/cluster checks, failure
retention and separate restoration remain unchanged. The baseline and inventory
derivative are byte-identical to the first candidate. Thirteen host-only tests
pass, covering the original ownership/bounds checks and the new parser, helper
failure and inherited-sysfs-independence cases. Independent source review cleared
the correction. The corrected runner has not been invoked and needs a new root
authorization after the final manifest verification.
The remaining real debconf/UCF/NSS/service and unchanged-state gates still apply.

### Combined fixture bootstrap and distinct callers

Create one private cluster with versioned absolute `initdb`/`postgres`/`psql`
paths, C.UTF-8/UTC, checksums, fsync/full-page writes and synchronous commit on.
Run the server as its unprivileged package account under an exact owned unit,
with `listen_addresses=127.0.0.1` and a fresh task CA/server certificate carrying
the IP SAN. A private Unix socket permits peer-authenticated fixture bootstrap
only; reject every other local client. TCP admits only the exact test database
and three finite SCRAM login names over TLS; non-TLS and unmatched users reject.
The action callers use explicit `sslmode=verify-full`, CA, numeric host/port,
`gssencmode=disable`, connection timeout and `psql -X -w`, with no inherited PG
service/options/default connection. [TLS verification](https://www.postgresql.org/docs/17/libpq-ssl.html),
[HBA matching](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html).

The privileged fixture setup applies the unchanged bootstrap and migrations
001–012, then creates three disposable LOGIN/NOINHERIT/NOSUPERUSER/NOBYPASSRLS/
NOCREATEDB/NOCREATEROLE/NOREPLICATION callers, each with a short expiry and only
its corresponding 012 membership (`INHERIT FALSE, SET TRUE, ADMIN FALSE`).
Grant CONNECT to the test database and no direct table/schema-write privilege.
Each transaction can `SET LOCAL ROLE` only to its one capability; it starts as
that restricted login, never the database owner. Check `session_user`, role and
TLS on the real connections, plus negative cross-role/table/owner checks.
[PostgreSQL role membership](https://www.postgresql.org/docs/17/role-membership.html).

Keep the executor/controller outside the transport slice under a new collision-
checked locked UID/GID 62403, with only its executor password file. The root
guardian has only the observer credential; the fixture bootstrap/admission path
closes its separate admitter session, makes that login NOLOGIN and removes its
password-file copy before the action, without retiring the activated DB authority.
Source and
supervisor retain 62402/62401 and receive no DB credential, password-file path or
FD. Password files are private, selected explicitly and never logged or passed
on argv. Parsing remains the executor's trusted, denied-permission Deno task,
outside the two-process transport scope; this does not claim a new OS sandbox
for the parser. [Password-file permissions](https://www.postgresql.org/docs/17/libpq-pgpass.html).

Use a Linux-specific restricted-login adapter and frozen fixture connection
descriptor rather than relaxing the existing Mac-only `LocalRPC` guard. Preserve
SELECT → COMMIT → private acknowledgement-marker semantics, one grant call,
exact durable receipt/result replay and independent guardian ownership. Admission
activates only the disposable fixture DB with synthetic host/project identity;
actual source networking stays absent. No SQL layout change is needed.

The new bundle must bind its actual Python/Deno/psql and dynamic runtime package
inventory, parser output/manifest, supervisor/child/observer/controller modules,
templates and bootstrap. A preliminary union of existing relevant source plus
parser/manifest is 233,356 bytes, leaving only 28,788 bytes below the 262,144-byte
source allowance **before** new glue/manifests. Reuse the reviewed mechanics and
measure the final captured graph before granting; do not silently expand the
4 MiB/32-name layout. Installed executable files and OS libraries remain separate
host-storage/runtime inputs, not mutable action journal members.

After fixture execution, settle or explicitly retain every action first. Stop
the exact cluster unit, confirm process/socket retirement, then remove only its
confirmed database directory, short-lived logins/passwords and owned service
accounts/units; preserve unresolved journal/body/unit identities. The final
guest stop and cleanup inventory are required even when no action reached GO.

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

### Guarded Linux dependency transaction

The first corrected invocation ran the isolated namespace and read-only
preflight checks, created fourteen reviewed masks and the owned `policy-rc.d`,
then refused before APT configuration because masking the two APT timers left
them `masked/failed/failed/resources` with no job. The APT services and
PostgreSQL/ssl-cert units were masked and job-free. That refusal is frozen in
`.artifacts/linux-dependency-review/install-attempt-31c96248d05b/`, manifest
SHA-256 `c51064d5334da77e1d764162fc49a82bb1b22e2991ecc454b4d3910436e08c16`.
The original dpkg status SHA was
`1d32ae764c3bf460d6b73a815a235cd8d52da790997e11953658501805faf1be`.

The continuation was then advanced only through fresh, hash-bound staging
directories. Each refusal retained its state and suppression; no candidate was
retried in place. The archived boundaries are:

* `.artifacts/linux-dependency-review/install-attempt-cont-20261004-96750ae2bffb/`
  (`26c85a19aad2f3ca4691aefa77f9c34a363a2d83ca79f7ff1ac0729b6bb454ee`):
  canonical APT handoff refused because `--no-download` passed a basename to
  dpkg when the archive was not present in APT's cache.
* `.artifacts/linux-dependency-review/install-attempt-cache-20261004-34a1869f7e5c/`
  (`8a8c79e4a5031f029c5b2c9c388ed1397719048c76e7ed7b743242914943d4d6`):
  the cache candidate refused before its transaction because reboot changed
  the preserved archive-lock mode from `0600` to `0640`.
* `.artifacts/linux-dependency-review/install-attempt-cachebind-20261004-1011a0509d87/`
  (`6db79d6a6a3db4ad6b782691af8ae4ffa09dde8f6b5dd9b3babffd65d9272d35`):
  a binder schema bug expected ownership fields that candidate manifests do
  not contain; the guest state was empty and package state was untouched.
* `.artifacts/linux-dependency-review/install-attempt-cachebind2-20261004-8a965ff43a76/`
  (`4995ce2b056c2ff57c17e25965842eb8f7f650350eaf8d8131cdcf41b8d19e14`):
  the frozen upstream state exposed four exact post-reboot metadata deltas
  (archive lock, two APT logs, and the terminal log) with unchanged bytes.
* `.artifacts/linux-dependency-review/install-attempt-cachebind3-20261004-2e7fd9de9faa/`
  (`42222bca561eb8801ff27a85c052bce5ca631840e91293bbbbcb0b95ab50819b`):
  preflight found exactly the two debconf records deliberately seeded before
  the failed APT stage; it created a 23-file journal but did not run a package
  stage. Dpkg status and audit remained unchanged and clean.

The final cachebind4 transaction is complete under
`.artifacts/linux-dependency-review/install-attempt-cachebind4-20261004-d77f61eccc21/`,
attempt manifest SHA-256
`8e0b03b753dcaaab6d06beb58bb255fd2157d1d94831a4c2fa6c9745e2d7fd5c`, candidate
manifest SHA-256
`d77f61eccc217d96816090b8f590372af816bb62878cccd3951a5a3ba0048421`, and
runner SHA-256
`1f80c88a26271d0faa91ea2eb544b72af3415858af3b172fdb23586e9a787fb9`. It
created an offline canonical APT archive cache, completed both package stages,
and verified all twelve exact requested archives. The success journal has 128
state files and SHA-256
`70aedd055660b1733bb61d3f42495175751918f89c3a721d73f7f097d58d0dfa`; the
final `/var/lib/dpkg/status` SHA-256 is
`7aecd81bad376b84d330cb2930ee26697aad6cf5753e9fb8f3b857427e553ed1` and
`dpkg --audit` is clean. No package process remains, no PostgreSQL cluster or
server process exists, and the fourteen reviewed masks plus the exact
`policy-rc.d` remain. The success journal records `tools_executed=false` and
`sql_executed=false`; no source/provider request or credential was used.

Automatic APT remains deliberately inhibited. Restoring the normal APT and
service policy is a separate reviewed action and has not been performed. This
transaction establishes the guarded Linux prerequisite layer; it does not
complete hosting, database migrations, or application deployment.

### Restricted caller checkpoint — 2026-10-04

`linux/restricted_rpc.py` now implements the finite Linux-fixture connection
descriptor, separate executor/observer/admitter RPC allowlists, private password
and CA files, verified TLS with default client certificates disabled, and
SELECT → COMMIT → acknowledgement handling. Before an RPC, the connection checks
the actual login, database, TLS, exact capability membership/options, absence of
owner/privileged roles and stable SQL string handling. The observer can read the
same execution state during recovery. Unicode NEL/line/paragraph separators in
valid JSON remain inside the JSON record; only LF separates psql records.

Shared pipe transport and pure source/deadline/execution/witness checks live in
`rpc_support.py` and `execution_contract.py`. The Mac fixture retains its existing
local database guard and owner-session limitations. Its frozen bundle includes
both modules. Linux can reuse these helpers without importing the Mac database
caller or its coordinator. The prospective existing-source union is 133,139
bytes; adding the earlier 88,806-byte parser/manifest estimate leaves 40,199
bytes for the remaining glue/manifests/units. This is planning evidence only:
the final actual Linux graph still needs measurement before admission.

Independent source review cleared caller SHA-256
`019a5fa0aaa3494d627bb9657375c83cee9aabe648ab9b92e61ce8cd6b5a0871`.
Fourteen new offline tests pass; the complete Linux-oriented local suite is
43 pass / 13 expected Linux-only skips. Eight existing coordination checks and
all 23 real disposable Mac PostgreSQL/loopback transport integration tests pass
after helper extraction. The latter log is
`.artifacts/linux-restricted-caller/mac-integration.log`.

No VM, hosted SQL, credential provisioning or source/provider action was run for
this checkpoint. The new caller has not yet connected to the Linux PostgreSQL
17 fixture. Actual restricted-login/TLS/negative-permission checks, combined
controller/guardian journal enforcement, grant-to-GO integration and scope-only
recovery remain required. Candidate 012 retains its frozen hash above.

# Linux lifecycle fixture

Status: implemented local fixtures, including the combined PostgreSQL metadata
workflow, supervisor interruption and observer-only replay described below.
The original lifecycle checkpoint passed
23 tests; the separate UID/ingress prerequisite now passes **41 tests on the
isolated Linux guest** (8.080 seconds), including all original 23 scenarios.
This is not a deployed metadata gateway.
Candidate migration 012 remains unapplied to hosted Supabase. The shared
paused-child API has a backward-compatible
spawn/handshake split, with the existing gateway regressions passing. Source
networking and production credentials are absent. The combined fixture uses a
private, disposable loopback PostgreSQL database.

## VM review boundary

`fixture-vm.yaml` proposes a **new** Apple-Virtualization/Lima guest: one CPU,
1 GiB RAM and a 20 GiB sparse disk. It uses the already-cached compressed image
whose SHA-256 is pinned in the file. Root reviewed the exact resolved config
before the sole new guest, `timestep-lifecycle-646`, was booted. The guest reports
Ubuntu 24.04.4 LTS, Linux 6.8.0-117-generic/aarch64, systemd 255.4,
Python 3.12.3/OpenSSL 3.0.13 and unified cgroup v2 with `CLOCK_BOOTTIME`.
There is no package installer or automatic update in the configuration.

Use a fresh task-only `LIMA_HOME`, a new name beginning `timestep-lifecycle-`,
and review Lima's resolved configuration before boot. Do not start, modify or
reuse `colima` or `colima-scrut2`. The proposed guest has no host filesystem
mount, no forwarded SSH agent, no host public keys, no container runtime and no
automatic application-port forwarding. Source files must be explicitly copied
into it. Lima's ordinary guest NAT is not a network sandbox; application-level
loopback-only validation remains mandatory. The service also requests systemd
IP address filtering, whose kernel support must be checked before relying on it.

The data-only guest marker is required by the lifecycle harness. It does not
admit the VM as a source executor. Do not create/start the guest until root has
reviewed this exact configuration. No creation/start command runs from a test.

## Smallest service and observation contract

Each attempt has a never-reused UUID, one service and a separately retained
parent slice. The service runs the captured controller and existing paused
loopback transport child as UID/GID 65534. It has no capabilities, database
access, cgroup delegation or automatic restart. The observer is the explicit
fixture operator outside the attempt slice; it is not a background daemon.

The parent slice is retained while the service stops, so an observer can inspect
its recursive `cgroup.events` rather than infer retirement from a disappearing
service directory. Before any fixture GO, capture the kernel boot ID, slice and
service identities, systemd invocation ID, cgroup device/inode and exact child
PID/start identity. Persist the capture before the dependent action. On restart,
reopen only that captured slice and refuse any changed boot, path or inode.

The root-owned stop marker is also an immutable unit start condition. It is
durable before the stop request and inhibits later manual starts; the unit also
allows only one start in its lifetime. systemd 255 clears a fully stopped
service's invocation ID. An empty ID is accepted only in the inactive/failed,
zero-MainPID, no-job state under that start fence; a different nonempty ID rejects.
Root administrative mutation of unit files, markers or counters is outside this
fixture trust boundary. These controls still need a deployed capability review.

Only an explicit stop fence followed by `populated 0` in that exact retained
slice can produce `fixture_cgroup_empty_v1`. A missing directory, successful
stop command, expired timer or changed PID is not that observation. It says
only that the owned group has no living processes; it says nothing about remote
application work. It is **not** `owned_child_joined`, has no SQL receipt adapter,
and cannot release 012 resource holds. The normal path may separately retain
the existing exact-parent wait witness. Cold-boot recovery stays unresolved.

The Linux tests observe the retained slice, verify the child's membership before
GO, and show that a stopped-but-living child remains populated until group stop.
They do not establish resistance to every process escape or hostile root action.
UID 65534, empty capabilities, `NoNewPrivileges`, read-only control groups and IP
filters are configured restrictions; adversarial escape resistance and kernel
BPF enforcement were not tested. The transport independently restricts its
actual destination to numeric `127.0.0.1`. An unsupported identity/property or
inconclusive observation fails closed; no alternative evidence is invented.

## Scope of this checkpoint

The fixture uses the existing protocol, TLS transport, child, identity adapter
and parent join implementation, captured before execution. It does not invoke
the XML parser, claim a database grant, simulate a successful SQL receipt or
start an admission/scheduling loop. Its GO is explicitly test-only authority to
contact one local TLS server. Real grant/COMMIT/result integration remains the
separately tested existing gateway contract.

The guest package must be captured under the actual guest Python executable.
A package produced on macOS cannot pretend to bind a different Linux runtime.
OS libraries, systemd and the guest image remain separately recorded runtime
assumptions; source hashes alone do not establish a host security boundary.

## Verification and remaining schedules

Host command (original checkpoint: 15 pass and eight Linux tests skipped;
current prerequisite checkpoint: 29 pass and 13 Linux tests skipped on macOS):

```sh
python3 -m unittest discover -s workers/source-gateway/linux -p 'test_*.py' -v
```

Inside the marked isolated guest, using an explicitly copied source tree:

```sh
sudo env TIMESTEP_LINUX_FIXTURE_RUN=1 python3 -m unittest discover -s /path/to/captured/gateway/linux -p 'test_*.py' -v
```

The copied tree retains the parent gateway files enumerated by
`package.GATEWAY_FILES`; no host mount is needed. Each test creates an immutable
bundle under its actual Linux Python and launches services from those captured
bytes. Tests never create or boot a VM, install packages, use database credentials
or contact a source hostname. The test TLS certificate contains source names for
SNI verification but all actual connections use loopback addresses.

Completed schedules:

1. Successful preflight on the marked Linux guest, recording the exact
   kernel/systemd/Python identities and required cgroup/clock interfaces.
2. Normal READY/GO/response: one loopback connection and exact child join.
3. Kill the controller before GO: no source connection; external observation
   is separate from the now-unavailable parent join witness.
4. Kill the controller during a slow TLS response; stop the exact service and
   inspect the retained slice. A living child prevents an empty observation.
5. Restart the observer with the same durable capture; never restart the action.
6. Fail capture/fence checkpoints and reopening durability barriers; no dependent
   GO or stop follows the failure. Repeat a fresh observer from the same capture.
7. Reject changed invocation, source recipe, boot or cgroup identity; missing
   directories and reused unit names are not successful retirement.
8. Attempting a manual restart after the durable stop fence produces no new
   invocation or socket; a second fresh observer reports the same empty group.

The preflight refusal paths for an unmarked host, non-systemd PID 1 and missing
cgroup/clock interfaces are implemented but were not negatively exercised in
this run. There is no actual lost-control-acknowledgement injection. The
changed-boot case is a deterministic injected identity mismatch, not an actual
crash/reboot/restore drill. Those drills, host replacement, power-loss durability
and unreapable kernel tasks remain unverified. Cold-boot recovery stays disabled;
an empty journal cannot establish prior retirement.

Tests create only their uniquely named runtime units and fixture directories.
Cleanup stops the exact service, observes its retained slice empty, then stops
the slice before deleting unit definitions and the attempt directory. An
uncertain stop or nonempty group retains all definitions/checkpoints for later
inspection; a regression checks this ordering. Cleanup never stops unrelated
services. No SQL migration is modified. The original checkpoint left gateway
source unchanged; the later shared-session refactor is described below.

Saved local evidence under `.artifacts/linux-lima/`:

- `preflight.json` and `boot.log`: exact isolated config check and boot.
- `source-75499fe7a1f6.json` / `.tar`: finite source snapshot used for the passing
  Linux run; the README has since been updated with these results.
- `linux-tests-75499fe7a1f6.log`: 23/23 pass in 4.786 seconds.
- `platform-and-cleanup.json`: observed runtime plus zero remaining owned
  runtime-unit files and attempt directories.
- `review-bundle.json`: captured Linux recipe SHA-256
  `b3f2945ab9bb22879a275c3504a21cdd14a2ac7586cea7bc03ab33b88ed81ec1`.
- `evidence.json`: final hashes, source/SQL immutability checks and VM status.

The guest's `sudo` emits a nonfatal local-hostname resolution warning, retained
in the log. No source request is involved. The generic guest OS/NAT is not
claimed to be an offline sandbox. The new guest is stopped after verification;
the two pre-existing Colima guests remain stopped and untouched.

Primary references: [Lima 2.1.4 configuration](https://raw.githubusercontent.com/lima-vm/lima/v2.1.4/templates/default.yaml),
[systemd slice ownership](https://raw.githubusercontent.com/systemd/systemd/v257/man/systemd.slice.xml),
[kernel cgroup v2 events](https://docs.kernel.org/admin-guide/cgroup-v2.html).

## UID and ingress prerequisite — local evidence only

The separately reviewed [Linux metadata admission plan](../../../docs/architecture/LINUX_METADATA_ADMISSION.md)
now has a concrete prerequisite implementation. `prerequisite.service.in` and
`prerequisite.slice.in` are separate from the original UID-65534 fixture units.
The new captured launcher uses only SETUID/SETGID/SETPCAP during bootstrap,
clears every bounding capability and drops SETPCAP, creates the source child,
then permanently drops the supervisor to UID/GID 62401 before consuming input or
READY. The source child uses UID/GID 62402. Both check all four UID/GID values,
empty supplementary groups, five zero capability sets, locked securebits,
no-new-privileges and dumpable zero. The guardian independently reads the kernel
status IDs, parentage and retained scope before capture. The shared `PausedChild`
keeps its existing constructor behavior and adds explicit spawn/handshake and
identity/stop strategies; Linux cancellation has no signal helper or CAP_KILL.

The first actual launch refused the unexpected capability state produced by
systemd 255's **explicit** `User=0` plus seccomp path. The reviewed correction
uses the system manager's default root identity, with the same exact root IDs
and P/E/B=448, I/A=0 bootstrap requirements. It does not add ambient capabilities
or relax a filter. `prerequisite_failure` logs contain only finite phase/errno
and kernel privilege fields; no exception text, request or response bytes.
The failed run and sanitized initial state remain in
`.artifacts/linux-prerequisite-guest-first.log`, `linux-prerequisite-guest-phase.log`
and `linux-prerequisite-bootstrap-failure.json`.

The syscall policy restricts the native ABI, permits AF_INET/AF_INET6, and denies
socketpair, all three io_uring calls, ptrace, process-memory access and pidfd FD
retrieval. `TasksMax=2` admits only supervisor and source child. Actual guest
negative tests observed denial of privilege reacquisition, source access to
guardian/control/parent-FD paths, cgroup writes, Unix sockets, the listed syscalls
and an extra fork. The signal check is an actual cross-UID `kill(pid, 0)` permission
probe. No non-native executable or external destination was attempted; exhaustive
escape resistance and kernel BPF filtering remain unclaimed.

`witness_slots.py` retains at most two bounded body inodes, with fixed pending and
final names. Recovery validates/fsyncs an existing final before using it, reuses
one retained partial inode, counts every hardlink name, and never writes a fresh
body merely because a publication acknowledgement was lost. A local exclusive
lock serializes file operations and conveys no database authority. Unexpected
aliases, incomplete ingress, conflicting data or failed barriers retain state.
The guardian callback must validate the captured action and exact parent-wait
provenance before publication; this storage module does not invent that proof.

The new guest schedules cover a complete **one-MiB** loopback body under the split
UIDs, exact cross-UID parent wait, unsupported initial capability sets, kernel
denials, a stopped child that cannot be signalled by its supervisor, and lost
supervisor recovery using only the outside guardian's empty-scope observation.
Witness failure schedules cover partial copy, file sync, final link, directory
sync and ingress cleanup; repeated fsync failure never returns a durable witness.
Filled synthetic slots reach exactly **4,153,344 serialized bytes and 30 names**
within the 4 MiB/32-name limits, including both pairs of hardlink aliases. This
tests the reserved envelope; the future combined SQL coordinator still needs to
apply its full action-journal admission and strict receipt/result validation.

Current local tests discover 42 cases: 29 pass and 13 Linux-only cases skip.
This includes one additional post-guest test that actually terminates the writer
without cleanup at four publication boundaries and recovers in a fresh isolated
Python process. That additional process-crash evidence is on the local Mac; it
was not rerun in the guest. Neither exception injection nor process exit is a
power-loss/filesystem durability test. The existing direct-gateway tests' 23 cases
and eight coordination regressions also pass locally.

Evidence:

- `.artifacts/linux-prerequisite-guest-final.log`: 41/41 on the guest, including
  the original lifecycle suite and new prerequisite scenarios.
- `.artifacts/linux-prerequisite-local-final.log`: 29 pass / 13 expected skips,
  including actual writer exit and fresh-process recovery.
- `.artifacts/linux-prerequisite-v1-gateway.log` and
  `linux-prerequisite-v1-coordination.log`: 23 and eight existing checks pass.
- `.artifacts/linux-prerequisite/becc0dfaab1ac7061473b5464fb491bfc97c28068926f3efc8e5db456c3f6659/`:
  frozen guest source, runtime manifest and immutable reconstructed runtime
  bundle. Runtime identity is
  `b1bb7ab854eda341899f9c25dba32395bb72ab2b74d1df9078feb21b1cd54906`;
  its member bytes were checked against both the copied source and current runtime
  files. The subsequent test-only crash case and this README are outside that
  guest source snapshot; no runtime member changed.
- `.artifacts/linux-prerequisite-platform-cleanup.json`: actual Linux/Python/TLS
  identity and zero owned runtime units, attempts, active bundles, fixture
  accounts or groups after cleanup. The evidence bundle was archived on the host
  and its temporary guest copy then removed. `timestep-lifecycle-646` is stopped.

The harness creates only the two previously unused locked fixture accounts and
removes them after confirmed group retirement. It refuses collisions and retains
definitions/journals when cleanup is uncertain. Ubuntu may delete the matching
unused group with `userdel`; cleanup accepts absence only after the exact owned
account deletion. No PostgreSQL/Deno/Node/esbuild package was installed: the
targeted guest inventory found them absent. Combined Linux SQL execution,
production credential separation, host admission and live source traffic remain
unfinished. Candidate 012 and all applied SQL files are unchanged.

## Restricted database caller checkpoint — 2026-10-04

The later guarded PostgreSQL dependency installation is recorded in the
[admission document](../../../docs/architecture/LINUX_METADATA_ADMISSION.md#guarded-linux-dependency-transaction);
the no-package statement above describes the earlier prerequisite run.

`restricted_rpc.py` now provides the separate capability callers for the planned
combined fixture, using explicit verified TLS and a private local descriptor.
It shares bounded pipe transport and pure validators with the existing Mac
integration without importing that integration's owner connection. Source review
and 14 new offline tests pass. The full local Linux-oriented suite now has
43 passing tests and 13 Linux-only skips; all 23 existing Mac database/transport
integration checks also pass after extraction. These are not actual Linux
database connection tests. The combined action and its recovery remain
unfinished; no hosted worker or source networking was enabled.

## Combined action source — 2026-10-04

The combined guardian/controller is now written. `metadata_bridge.py` connects
separate executor and observer callers; `metadata_host.py` owns the exact Linux
scope. `action_journal.py` supplies one held lock and immutable, recoverable fixed
records; `metadata_scope.py` and `metadata_settlement.py` translate verified
capture/retirement into 012 receipts. The source supervisor receives the actual
granted execution ID and absolute deadline. Recovery cannot grant or start a
source service.

The permanent start fence precedes grant intent. A saved GO can be repaired only
after the retained scope is empty. Complete interrupted checkpoints preserve
their original receipt IDs, bytes, inode and first acknowledgement; partial or
conflicting records remain unresolved. These paths pass portable file/pipe tests
with simulated SQL/kernel boundaries. Actual Linux execution is still required.

The new `fixed-record-inodes-v2` capacity uses 327,680 bytes for the full shared
source/parser/manifest/rendered-unit graph. Ordinary pending records use their
own slot's inode allowance, with no extra generic temporary bytes. The tested
maximum remains 4,153,344 bytes and 30 names under the unchanged 4 MiB/32-name
limits. Earlier prerequisite reservations/evidence retain their legacy layout;
reopen compares the explicit version and complete immutable capacity record.

The source-only `fixture_database.py` provisions a disposable, loopback PG17
cluster with verified TLS and separate capability logins. Its offline tests do
not establish that the real guest connection or combined workflow works. See
[the admission checkpoint](../../../docs/architecture/LINUX_METADATA_ADMISSION.md#combined-runtime-source-checkpoint--2026-10-04)
for exact evidence and remaining checks.

## Combined Linux normal workflow — verified 2026-10-04

`test_metadata_integration.py` now passes in the marked isolated PG17 guest:
actual restricted TLS logins, Atom → license → 011 source-only library projection,
and both completed-action recoveries with no extra grant, GET or charge. The
final fresh run also removes its temporary scopes, database, accounts and TLS
files. Both Linux descendant-retirement tests pass. The portable suite has 116
passes and two Linux-only skips.

The exact captured bundle charges 303,984 source bytes. Evidence and failure
corrections are recorded in the
[combined Linux checkpoint](../../../docs/architecture/LINUX_METADATA_ADMISSION.md#combined-linux-verification-checkpoint--2026-10-04).
The guest is stopped; only immutable inputs/bundle and bounded evidence remain.

The harness is explicit opt-in and needs the documented `TIMESTEP_METADATA_*`
inputs; ordinary test discovery performs no provisioning. Its test-only
`recover_cleanup_action` handles the exact definitions-removed, journals-intact
case after a saved cleanup proof. It does not relax `ActionJournal` or create a
new retirement receipt. Missing, changed or partially deleted files are retained
for review.

The supervisor-interruption schedule and observer entry are verified in the
next checkpoint. Guardian-death controller-family ownership remains open.
These loopback results do not enable hosted workers, external source requests,
PDF acquisition or paid Mathpix/AI work.

## Supervisor interruption and observer-only replay — verified 2026-10-04

`metadata_observer` accepts only an existing job/claim and observer descriptor.
It can settle the captured transport resources; it cannot start a controller,
grant, publish GO, parse, finalize a job or clean up the action. A pending GO
publication remains unresolved. Resource closure does not prove retirement of
a separate controller family after guardian death.

The integration harness selects exactly one fresh workflow using
`TIMESTEP_METADATA_SCENARIO=normal` (the default) or `supervisor_death`.
The latter uses an exact Linux process handle to kill the supervisor after
response headers while the fixture withholds the body. The original guardian
retains its wait authority. One request stays fully charged at 1,048,576 bytes,
both resources receive ordered scope-retirement receipts with unknown body
facts, and the job records an acknowledged retryable failure. A fresh
observer-only process preserves all receipts, results, charge periods, cooldown
and retry state, with no additional connection.

The fault scenario passes in 37.300 seconds; the final normal regression passes
in 11.282 seconds, including full cleanup in each case. Only the explicit fault
fixture permits one named `reset-failed` after durable fault/settlement/empty
scope proof and rechecking the original unit/fence under the held lock. The
independent start fence survives reset and unit removal and is deleted last.

The final Mac discovery run passes 163 tests with 16 Linux-only skips:

```sh
PYTHONPATH=workers/source-gateway:workers/source-gateway/linux python3 -B -m unittest discover -s workers/source-gateway/linux -p 'test_*.py' -v
```

Bundle `1c1b040f8bab4835c718a0d8a36475c8bdc72c5e1a36e30b91677f73339eb161`
charges 309,005 source bytes. Source and saved database/cleanup evidence passed
independent review. The final readback finds no owned actions, accounts, units or
PostgreSQL server/cluster, and the guest is stopped. Evidence is
`.artifacts/linux-restricted-caller/observer-0f2bf6c2521b/summary.json`; the
[admission checkpoint](../../../docs/architecture/LINUX_METADATA_ADMISSION.md#supervisor-interruption-and-observer-only-replay--2026-10-04)
records the exact scope and remaining recovery limits.

## Isolated original-PDF slots — verified 2026-10-04

`original_spool.py` implements the separately reviewed original file handoff.
It retains at most two 5 MiB payload inodes under one reservation lock, publishes
a closed canonical descriptor, rechecks file identity and every byte on reopen,
and replays interrupted copies/cleanup without allocating a third payload.
Allocation uses the preplanned claim ID; the full post-grant binding also pins
the actual database execution ID. Required guardian callbacks validate the
external allocation, retirement, reader intent and downstream settlement.

The 26 new portable tests pass, including process exit, maximum/oversized bodies,
short writes, partial files, inode substitution, hardlink cleanup, reader holds
and close-error handling. Complete discovery using the `PYTHONPATH` command above
passes 189 tests with 16 Linux-only skips (205 total). Evidence and the remaining
integration boundary are in
[Original execution](../../../docs/architecture/ORIGINAL_EXECUTION.md#verified-isolated-spool-checkpoint--2026-10-04)
and `.artifacts/original-spool-summary.json`.

This is a file-mechanics checkpoint with injected trusted validators. It is not
part of the admitted metadata bundle or a connected original-PDF execution path.

## Portable original transfers — verified 2026-10-04

`original_transport.py`, `original_child.py` and `original_session.py` implement
separate loopback-only PDF download, single upload and stored readback actions.
The child gets only a nonblocking binary pipe or read-only sealed input FD.
READY/GO/control EOF precedes I/O; complete transfer facts, matching binary EOF
and an actual child wait precede caller-controlled spool completion. The session
preserves partials and reports IPC cleanup uncertainty separately from retirement.

The maximum-size process/spool workflow passes through source download, guardian
seal, read-only upload, exact fixture ACK, source-slot cleanup, new readback slots
and final hash comparison. All 48 new cases pass on both local Python/TLS
runtimes; full Mac discovery is 253 total, 237 passing and 16 Linux-only skips.
The 31 metadata transport/coordination regressions also pass on both runtimes.
Reproduction, evidence and reviewed boundaries are in
[Original execution](../../../docs/architecture/ORIGINAL_EXECUTION.md#portable-original-transfer-boundary--2026-10-04).

This does not combine original execution with SQL or Linux scope authority, run
the verifier, or establish real Supabase response/settlement semantics. The
portable bundle is not a production admission recipe. The shared strict parser's
new per-instance protocol ceiling retains metadata defaults but changes newly
captured source identities. Retained older bundles are untouched; new metadata
captures need fresh combined Linux verification before admission. The VM remains
stopped, and pending migrations 012/013 remain unhosted.
There is no new SQL migration, live source/Storage traffic, Linux runtime admission,
physical disk quota or whole-host verifier measurement claim. The existing guest stays off.

## Portable verifier receiver — verified 2026-10-04

`original_verifier.py` now receives the sealed stored-readback FD through stdin
and controls a separately captured Deno wrapper through one bounded inherited
pipe. READY/GO/EOF precedes input reads, imports and compilation. The complete
local TLS/spool journey now reaches the unchanged `39980de…` parser and returns
the correct fixture hash, length and page count. The surrounding request and
guardian facts in that test are still synthetic.

`original_verifier_bundle.py` captures seven pinned payload files plus a closed
manifest into a private read-only directory. `wait4_child.py` exclusively owns
the exact child's terminal status and rusage; it retains lost authority instead
of inventing metrics. The session enforces an independent wall deadline and
requires exact retirement, bounded output, valid measurements and successful
IPC cleanup before accepting a result. These are direct-child portable facts,
not the complete Linux host policy.

All 52 new checks pass on both local Python runtimes. Full Mac discovery passes
289 checks with 16 Linux-only skips (305 total). The suite exercises actual
parser outcomes, retained research papers, malformed control, cancellation,
resource/cleanup failures and readback → parser handoff. Reproduction, raw
evidence and limitations are recorded in
[Original execution](../../../docs/architecture/ORIGINAL_EXECUTION.md#portable-verifier-receiver--verified-2026-10-04).
The frozen build, existing spool and all migrations remain unchanged. Linux
process/thread limits, cross-UID FD access, complete host measurements, SQL
integration and real Supabase Storage settlement remain required. No VM,
physical device, hosted service or provider was changed for this checkpoint.

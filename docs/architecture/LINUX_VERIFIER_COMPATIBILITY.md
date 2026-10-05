# Linux PDF verifier compatibility

Status: **local Linux compatibility verified on 2026-10-04**. Eight actual
systemd schedules and 60 guest contract tests pass. Full Mac discovery is 357
tests: 335 passing and 22 Linux/opt-in skips.
This checkpoint grants no host admission, SQL authority, provider access, or
permission to enable acquisition. Pending migrations 012/013 remain unchanged.

## Purpose

Connect the existing paused verifier to Linux privilege separation and kernel
accounting without changing frozen parser build
`39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610`.
The first proof uses the retained, isolated `timestep-lifecycle-646` guest and
already reviewed Deno 2.9.6 executable. No new service purchase or package
installation is required. The portable handoff remains a separate supported
component; its successful child measurements are not whole-host measurements.

This evaluates one hosting option. It does not establish that a separate
production server is required: the same frozen parser already passed a temporary
Supabase Edge Function experiment, recorded in
[implementation evidence](../IMPLEMENTATION_STATUS.md). The remaining choice is
where the complete acquisition/verification lifecycle can meet its required
bounds. No dedicated production worker has been provisioned.

## Process and ownership model

The process tree is outside guardian G, systemd/PID1, trusted reaper R,
dedicated supervisor S, then Deno D. R alone owns `wait4(S)`; S alone owns
`wait4(D)`. All three service processes start inside one fresh retained parent
slice. G owns the spool lock, initial/final cgroup observations, permanent start
fence and scope termination. Moving a running process into a scope is excluded:
it loses earlier accounting and is not equivalent to a service sandbox.

The fixed numeric roles are supervisor 62401, Deno 62402 and reaper 62403, each
with its matching primary GID and no supplementary groups. The guest must show
these IDs unused before the fixture begins. No persistent login is required.
R starts S while its initial bounded root capabilities are still intact; then
R permanently drops. S independently begins its drop, creates the exact
read-only control pipe, spawns D using ordinary Popen numeric user/group options,
and permanently drops before application handshake. No `preexec_fn` is used.
Both dropped parents have empty permitted/effective/inheritable/bounding/ambient
capabilities and no-new-privileges. Existing metadata UID checks are unchanged.

The new service uses Type=exec, Restart=no, RemainAfterExit=no, and
KillMode=control-group. Before the first child spawn, R durably creates a
root-owned launch-spent marker. Its absence is a start condition. A later
capture-bound permanent fence is installed before GO and retained through
retirement. These fences cover distinct pre-capture and post-capture windows.
Missing either exact wait record forbids positive measured completion even if
G proves the scope empty. A failed parent cannot have its rusage reconstructed
from PID1 status, sampled RSS or RUSAGE_CHILDREN.

A process-free active target holds a Wants reference to the service until G
finishes observing its actual exit. Without that reference, systemd can unload
a successfully exited service before G reads its exit code and invocation/start
facts. The target has no executor or restart policy; service Type=exec,
RemainAfterExit=no and KillMode=control-group still govern process lifetime.
G stops the target only after final observation and the restart-denial check.

## Files and paused input

Portable bundle v1 remains owner-private (directory 0500, files 0400).
An explicit installed Linux v2 policy uses root ownership, Deno's fixed GID,
directory 0550 and files 0440. It is a new capture with a closed versioned
manifest, never a chmod of a retained v1 capture. All parser assets remain
byte-for-byte unchanged; Deno checks the installed graph after GO. S verifies
and captures all launch inputs before dropping, because its final UID cannot
traverse D's code directory. The selected root-owned runtime and its dynamic
library inventory are recorded separately.

For the compatibility fixture, systemd opens the guardian-derived sealed path
read-only with StandardInput=file:. G retains the spool lock and validates the
complete path and original FD. R/S compare inherited fd0's type, access mode,
device/inode, length and offset against the retained descriptor. They forward
that open file description to D's stdin without allocating another PDF copy.
The manager's opening has a different offset from G's original FD, so G also
observes D's actual fd0 offset at READY under checked boot/PID/start identity.
There is no PDF read or parser import/compile before one GO followed by EOF.

Linux reopens `/proc/self/fd/N` under inode permissions. The control pipe's
reader group is therefore selected before spawning D and its mode is 0440;
only its read end is inherited. No supplementary group, writable spool path,
network credential or database capability is passed to the service.

## Measurement definitions and finite bounds

Linux wait4 for S includes CPU of the children S reaped. Its ru_maxrss is the
maximum of S's own and waited-descendant peaks. Do not sum S and D CPU. Preserve
both raw records, and use fresh retained-slice cpu.stat for aggregate R+S+D CPU.
The conservative two-record RSS envelope is
`1024 * (S.ru_maxrss + D.ru_maxrss)`; these are overlapping maxima, not two
disjoint own-process peaks. Reaper memory is additional separately budgeted
supervision overhead. Slice memory.peak is charged memory, never process RSS.

The finite compatibility policy starts at TasksMax=64, MemoryMax=256MiB,
MemorySwapMax=0 and a five-second useful-work budget. These are probe limits,
not admitted production values. No automatic limit increase is allowed.
G has an independent absolute CLOCK_BOOTTIME deadline and stops the exact
captured scope if the service fails to complete. systemd RuntimeMaxSec supplies
an additional active-runtime fallback; it does not prove a suspend-inclusive
deadline after G dies. Task limits count threads and processes. Deno requires
runtime threads and JIT-compatible memory; metadata's two-task policy cannot
be silently reused. Samples are not lifetime task peaks.

Deno's ordinary exec may reset dumpability. This checkpoint must record the
actual boundary and must not inherit the Python child's dumpable=0 claim.
Distinct UIDs and empty capabilities are observed independently; Internet socket
creation and ptrace/process_vm/pidfd_getfd are denied by the captured policy.
No-extra-process proof, hard total CPU enforcement,
complete guardian-loss/suspend recovery and admitted lifetime accounting remain
separate host-admission requirements.

The first actual Linux startup refused before READY: Deno 2.9.6's Tokio 1.47.1
signal handler panicked when the inherited seccomp policy denied its anonymous
Unix socketpair. A separate diagnostic capture reproduced that error without
GO or a PDF read; it cannot supply positive compatibility evidence. The verifier
unit now permits this local runtime IPC operation while still denying socket,
connect, bind, listen, accept and accept4. No cross-role socket is inherited and
the metadata service policy is unchanged. [Tokio signal implementation](https://github.com/tokio-rs/tokio/blob/tokio-1.47.1/tokio/src/signal/unix.rs).
RestrictAddressFamilies does not filter socketpair arguments. Datagram pairs
can address another Unix endpoint without connect; this prerequisite therefore
does not prove complete Unix IPC isolation. A strict admitted policy still needs
a reviewed argument filter or equivalent boundary, in addition to the existing
fixed-graph and Deno permission checks.

## Verification and evidence

The decisive first schedule is exact installed graph, cross-UID READY with D's
PDF offset still zero, one GO, actual frozen-parser success, both exact wait4
records, and final recursive emptiness of the same retained slice inode.
Negative schedules cover wrong input identity/hash, missing GO, parent/child
death, restart denial and missing reports. A fresh valid parse follows refusal.
Retain raw bounded reports, boot/unit/invocation/cgroup identities, UID/capability
observations, runtime/build pins, counters and cleanup results. Unknown facts
remain unknown. Real partial measurements are never relabeled as the synthetic
SQL host evidence accepted by the current disabled candidate 013 fixture.

### Actual guest checkpoint

The final run is `probe-c5f2c9ea5235`, on the existing isolated aarch64 guest,
Linux 6.8.0-117-generic, systemd 255.4-1ubuntu8.15 and Python 3.12.3. The retained
Deno executable is version 2.9.6, SHA-256
`d08d392418df53f4e6e88a08909c0e1bccbf9adcead7232df72b6ad6075ec416`.
All 77 staged members match both the archive and the current source files.

| Schedule | Observed result |
|---|---|
| Valid document | READY at input offset zero; GO; actual frozen parser verifies the 610-byte, one-page fixture; both exact waits and successful reaper exit retained |
| Wrong hash | Complete measured refusal with `input_mismatch`; no parser result |
| Deno death while paused | Exact Deno wait records SIGKILL before GO; no accepted verification |
| Supervisor death while paused | Exact supervisor wait records SIGKILL; Deno metrics remain unknown |
| Reaper death while paused | No runtime report; PID1 records SIGKILL; neither child measurement is invented |
| Guardian stop | The watcher uses its preopened cgroup kill handle; no runtime report or accepted result |
| Missing GO | Deadline refusal with no GO forwarding or parser result; missing Deno retirement remains unknown |
| Fresh recovery | A new service verifies the same valid fixture after the negative schedules |

The guardian-stop case induces the living watcher's deadline; it does not test
guardian death. The death injections do not establish interruption during WASM
execution, and fresh recovery does not resume an earlier uncertain attempt.

All eight preserve the service start/invocation identity through actual exit and
the denied restart, prove the original retained scope empty with zero tasks,
retire the local spool slots, and remove their owned units. Target identity,
Wants edge and active-at-start state are checked by the captured guardian;
separate raw target readback dictionaries are not retained. The saved service
exit and restart readbacks directly establish the required retained exit facts.

For the first valid case, Deno CPU is 52 ms and peak RSS is 50,716,672 bytes.
Supervisor wait CPU is 231 ms **including its reaped child**. Whole-slice CPU is
371,130 microseconds; the conservative overlapping RSS envelope is 101,433,344
bytes, excluding reaper RSS. Peak charged slice memory is separately 47,484,928
bytes. Startup through proven emptiness takes 698.116459 ms. These are fixture
measurements, not production or maximum-document guarantees.

The portable suite passes 335 tests with 22 Linux/opt-in skips (357 total),
including the unchanged parser corpus checks. All 60 installed-bundle/runtime/
guardian contract tests pass as root in the isolated guest. An earlier contract
run exhausted the one-GiB guest because a short-write test's MagicMock retained
every large call argument. Replacing that test-only recording wrapper with the
same non-recording callable fixes the test allocation; no worker or VM memory
limit was raised.

Earlier failed captures are retained: `probe-f42d276b90f7` refused before READY
under the socketpair prohibition; separate `diagnostic-cf50f55da37b` identified
the Tokio panic. `probe-06fdd608bf00` parsed successfully but was correctly
rejected after systemd unloaded its service and discarded exit/start facts.
The process-free reference target fixes that observation lifetime in the final
run. None of these earlier runs supplies a successful checkpoint.

Evidence lives under `.artifacts/linux-verifier-compatibility/`:

- `.artifacts/linux-verifier-summary.json` consolidates the final test, source,
  migration-pin, case and cleanup checks (this file is one directory above).
- `probe-c5f2c9ea5235/stage.json`, `source.tar`, `guest-run.log`,
  `guest-contract.log`, and `retained/evidence/` with exact case/control records.
- Final source archive SHA-256
  `be5b1a9da43fd0515e4b276227e69409fe324fbe271f63389d9a145c4474119d`;
  captured Python graph
  `535887e5ffc12b0cded6fdf8c6fbe5a03bbb66bb7ade4df7338d46430009c682`;
  installed verifier bundle
  `24f3ac7ae444807b5972f103d2b49123b51c627fd7c5615af2655569a0be8688`.
- `retained-evidence.tar` preserves all four runs, including failures, SHA-256
  `48ab200a6423a1ccabfa0e6cb495b3d70d57ea530f0e52ef0dc3782b56c8e5ba`;
  `evidence-export.json` records every exported file hash.
- `.artifacts/linux-verifier-full-portable.log` records the full Mac suite.
- `cleanup-preflight.json`, `cleanup.json` and `vm-stopped.json` record absence
  of owned processes/units/cgroups, removal of the eleven retained case
  directories and the failed contract-test directory after evidence export,
  and the isolated VM's final stopped state. Source/evidence archives remain.

Independent source/evidence review is clear at guardian SHA-256
`6644aa0a16cc45260f3e2194a1c2f87e81f6946fb1ea047dc87c334267bbd270`.
Both successful and failed captures were preserved locally before cleanup;
the isolated VM is stopped.

The existing spool, frozen parser/profile, applied 001–011 and pending 012/013
remain byte-for-byte unchanged. This checkpoint does not establish hard total
CPU enforcement, lifetime process/thread bounds, complete Unix IPC isolation,
guardian-loss/suspend/restore recovery, a physical spool quota, or host admission.
SQL ordering, live Supabase Storage settlement, funded Mathpix conversion and
authenticated delivery to the reader still require their combined workflows.

Reviewed references: [systemd 255 input opening](https://github.com/systemd/systemd/blob/v255/src/core/exec-invoke.c),
[service lifetime](https://www.freedesktop.org/software/systemd/man/255/systemd.service.html),
[unit reference/garbage-collection rules](https://raw.githubusercontent.com/systemd/systemd-stable/v255.4/man/systemd.unit.xml),
[Linux 6.8 cgroups](https://www.kernel.org/doc/html/v6.8/admin-guide/cgroup-v2.html),
[wait accounting](https://github.com/torvalds/linux/blob/v6.8/kernel/exit.c),
[rusage aggregation](https://github.com/torvalds/linux/blob/v6.8/kernel/sys.c),
[inherited FD permissions](https://man7.org/linux/man-pages/man5/proc_pid_fd.5.html),
and [exec privilege behavior](https://man7.org/linux/man-pages/man2/execve.2.html).

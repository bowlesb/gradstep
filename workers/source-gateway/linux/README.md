# Linux lifecycle fixture

Status: implemented local fixture. **23 tests pass on the isolated Linux guest**
(15 contract tests and eight real systemd/loopback TLS schedules, 4.786 seconds).
This is not a deployed metadata gateway.
Migration 012 and the existing gateway are unchanged. Source networking,
database access and production credentials are absent from this fixture.

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

Host command (15 pass, eight Linux tests explicitly skipped on macOS):

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
services. No SQL migration or existing gateway source is modified.

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

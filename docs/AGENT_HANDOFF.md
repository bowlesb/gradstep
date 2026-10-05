# Science Reader agent handoff

Prepared 2026-10-04 Pacific time, 2026-10-05 UTC, for an agent starting a fresh
conversation in the existing workspace. The user is transferring work because
the previous agent is nearly out of credits. Continue the project from its
verified state; do not restart the design or mistake the prototypes for a
finished product.

The intended product is a paid native iPhone/iPad ML-paper reader with a
dedicated Supabase backend, shared eligible article conversions, private
libraries, encrypted conversations, subscriptions and credits, an admin usage
dashboard, and screenshot-based internal feedback. A browser reader is also
authorized after the iOS work. The preferred name is Timestep, conditional on
availability. There is no complete usable beta yet.

## Start here

Workspace: `/Users/benbowlwes/science-reader`, on the user's Mac. Read these
files in order, then the source relevant to your next change:

1. [Project instructions](../AGENTS.md).
2. [Product decisions](DECISIONS.md).
3. [Implementation evidence and remaining work](IMPLEMENTATION_STATUS.md).
4. [Original PDF execution](architecture/ORIGINAL_EXECUTION.md) and
   [Linux verifier compatibility](architecture/LINUX_VERIFIER_COMPATIBILITY.md).
5. [Mathpix pipeline](architecture/MATHPIX_PIPELINE.md).
6. [Native chat rendering](architecture/NATIVE_CHAT_RENDERING.md).
7. [Deployment manifest](architecture/DEPLOYMENT_MANIFEST.md), then
   [privacy and sync](architecture/PRIVACY_AND_SYNC.md),
   [data model](architecture/DATA_MODEL.md), and
   [UX parity](UX_PARITY.md) as needed.

`IMPLEMENTATION_STATUS.md` records successive historical checkpoints; test counts
attached to older paragraphs are not the current totals. Architecture documents
also contain proposed requirements alongside verified evidence. Read their
status and limitations before interpreting a component as deployed.

## Constraints that persist

- The NAS is read-only, and only
  `/volume1/@home/selfhost/science-reader` through `Ben@192.168.1.203` may be
  visited. No other NAS folder, symlink escape, write, service action or database
  change is authorized. The local `reference/web/` snapshot is sufficient for
  normal work; its historical `CLAUDE.md` does not authorize NAS operations.
- TextBrain is a read-only reference for account access and patterns. Do not
  edit, deploy or operate its app/database. Existing project scripts reference
  its retained PostgreSQL tool binaries; the Science Reader test cluster has its
  own data directory, described below.
- Physical iPhone work is paused. Do not query, install, launch, test or capture
  the phone until the user explicitly resumes it. Simulator work is allowed.
- No legacy migration is needed. Preserve the original page arrangement,
  navigation, selection actions and paper/general-chat distinction. Subtle
  typography, spacing, accessibility and animation improvements are authorized.
  Material interaction changes need a concrete proposal for the user.
- The user prefers careful implementation over speed and explicitly requested
  independent subagent reviews for complex architecture and UX. Use them when
  available. Keep runtime ownership centralized: reviewers should not start
  competing builds, simulators, databases, VMs or deployments.
- The incremental beta budget is $100/month, separate from TextBrain. The
  deployment plan allocates at most $30/month aggregate provider work across
  staging and production. Track actual costs and reservations before paid work.
- Do not introduce borrowed production credentials, plaintext-chat fallback,
  fake customer entitlements, client-only spending enforcement, or ad hoc tables.
  Never put credentials in source, logs, screenshots or handoff documents.
- Applied migrations 001–011 are immutable. Candidates 012 and 013 remain local
  `.sql.pending` files, not hosted migrations. Their local tests do not authorize
  applying them or enabling processing switches without satisfying deployment
  gates. Use additive changes for applied schema corrections.
- The user authorized independent implementation and deployment within the
  agreed scope. Do not repeatedly request permission for routine reversible
  work. Public App Store release remains a later user review.

## Exact takeover state

The last implementation commit is **`e569276`**,
`Add isolated Linux PDF verifier compatibility harness`, on local `main`.
The working tree was clean before this handoff document was added. Recent
implementation history:

| Commit | Completed work |
|---|---|
| `e569276` | Isolated Linux verifier compatibility and retained exit evidence |
| `3f3a4c5` | Paused PDF verifier receiver and exact direct-child measurements |
| `adca386` | Bounded original PDF transfers and portable worker handoff |
| `5c7e319` | Disabled original-execution SQL candidate and recovery tests |
| `6a06c09` | Bounded original PDF spool and execution design |

No new implementation was made after `e569276`. The user then asked for
overnight progress. Three subagents inspected the next workstreams, but all
stopped for this handoff with **no edits, partial files, tests, builds, runtime,
VM, provider or device actions**. Their findings are captured below. There is no
unfinished root test command from that planning interval.

The transfer was requested before overnight implementation began. Do not report
the proposed workstreams as accomplished or imply work continued after this
handoff.

## What already works and what remains

| Area | Verified scope | Remaining gap |
|---|---|---|
| Native app | Simulator navigation, library commands, encrypted SQLite, offline bundle installation/reopening, figures/equations and saved paper questions | Complete live populated import flow, broader device/accessibility/resource acceptance |
| Supabase | Dedicated staging, applied schema, hosted account isolation/encrypted sync/support upload checks | Processing integration, production environment, remaining quotas/operations/restore gates |
| PDF transfer | Actual bounded local TLS download, sealed-file upload, stored readback and exact hashes | Combined original SQL/guardian workflow and live Storage semantics |
| PDF verifier | Frozen parser, portable receiver, separate Linux privilege/accounting/lifecycle fixture | Admitted host policy and measured SQL publication bridge |
| Mathpix reader | Retained-output adapter and renderer with synthetic provider-shaped output; offline iPhone/iPad journeys | Funded submission lifecycle, real provider compatibility, durable hosted collection/publication/delivery |
| Chat | Encrypted saved messages/drafts; standalone completed prose/math renderer proof | Native renderer integration, live AI, streaming, general Markdown/table/code formatting and settlement |
| Admin and release | Local admin browser checks and hosted screenshot/report APIs | Admin hosting, real OAuth/email journeys, purchases, TestFlight, browser reader |

The full **add paper → acquire/store/verify → Mathpix → synced/offline reader →
live chat** journey is not complete. Original PDF delivery alone is not the
equation-aware reader. Saving an encrypted question is not an AI response.

Supabase can download PDFs and run WASM; earlier temporary hosted experiments
successfully ran the frozen parser. Those temporary functions and test accounts
were removed. The Linux worker is an evaluated hosting option, not proof that
Supabase cannot do the job or a separately provisioned production server.
Supabase remains the preferred backend. The stricter whole-execution resource
and retirement requirements still need a proven deployment configuration.

Realtime is planned as a refresh hint. Current native synchronization uses
foreground/explicit catch-up and durable cursors; do not claim live Realtime
paper-ready notifications are wired.

## Latest verifier evidence

Read [the compatibility checkpoint](architecture/LINUX_VERIFIER_COMPATIBILITY.md)
for the exact identities and limits. The final local run is
`.artifacts/linux-verifier-compatibility/probe-c5f2c9ea5235/`.

- Full Mac portable suite: **357 total, 335 passing, 22 Linux/opt-in skips**.
- Guest installed-bundle/runtime/guardian contract suite: **60 passing**.
- **Eight actual Linux schedules passed**: valid PDF, wrong hash, Deno death,
  supervisor death, reaper death, guardian stop, missing GO and fresh recovery.
- Both independent source/evidence reviews were clear. All 77 staged source
  members matched the archive and implementation. Final archive SHA-256 is
  `be5b1a9da43fd0515e4b276227e69409fe324fbe271f63389d9a145c4474119d`.
- `.artifacts/linux-verifier-summary.json` consolidates source/migration pins,
  tests, measurements and cleanup. The earlier failed captures and diagnostic
  run are retained; do not erase or promote them into successful evidence.
- Frozen parser build remains
  `39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610`;
  profile remains `qpdf-wasm-pilot-v1` with SHA-256
  `c8478d6e1b1f7a8631132789a471a7f525123f40d2e893890254fb1660b54962`.

Important limits: death injections occurred while roles were paused, not during
WASM execution. Guardian stop exercised the living watcher's deadline, not
guardian loss. Recovery used a fresh service, not a resumed uncertain attempt.
The successful Linux PDF was a 610-byte one-page fixture, not a maximum-size
paper. This does not establish hard total CPU enforcement, lifetime task bounds,
complete Unix IPC isolation, guardian-loss/suspend/restore recovery or production
host admission. Missing measurements stay unknown.

Linux `wait4(S)` includes CPU of children S reaped. Do not add S CPU to D CPU.
The documented RSS envelope conservatively adds overlapping S/D maxima; reaper
RSS is outside it. Cgroup peak charged memory is not process RSS. The retained
process-free target prevents systemd from discarding service exit facts before
observation. Deno required anonymous socketpair support; allowing it is not
complete Unix IPC confinement.

## Next workstream for the paper pipeline

The independently reviewed immediate checkpoint is **actual download → upload →
stored readback with disposable PostgreSQL, ending at `pending_verification`**.
This is a useful intermediate milestone, not the complete product flow. Connect
existing components instead of starting another general worker framework:

- `workers/source-gateway/linux/original_transport.py`, `original_session.py`
  and `original_child.py` implement bounded loopback TLS and binary streaming.
- `original_spool.py` holds the reservation lock, bounded producer/guardian
  files, sealed descriptor and read-only FD borrowing.
- `action_journal.py`, `witness_slots.py`, `lifecycle.py`, and the metadata
  guardian/observer implementation provide established durability and ordering
  patterns. The metadata adapter itself is schema/scope-specific; do not blindly
  widen its accepted inputs or change already verified metadata behavior.
- `restricted_rpc.py` and `fixture_database.py` provide real TLS/SCRAM fixture
  sessions. Pending 013 defines original reservations, grants, receipts and
  stage transitions.

Resolve this concrete protocol mismatch first: the portable transfer requires
`attempt_id` before spawn and uses it as GO's execution ID, but SQL creates the
execution UUID during the grant after READY. Introduce an explicit protocol
version using claim identity before the grant; GO must bind the actual returned
execution ID and exact request/binding digests. Preserve capture → durable
future-start fence → grant intent → one committed grant → validated durable GO.
Split spawn from handshake where required so the Linux supervisor drops
privileges before reading application input. Cross-UID `kill()` cannot be
assumed to work; the outside scope guardian owns retirement.

Add a purpose-specific original adapter and an explicit versioned original
fixture mode through 013. The current DB fixture only provisions metadata
executor/observer/admitter callers through 012. Add a separate original-executor
login and finite RPC vocabulary with cross-role/table/owner-denial checks. Owner
setup stays outside the action; admission credentials retire before transfers.
A verifier login is unnecessary for the first D/U/R checkpoint. Binary PDF
bytes must stay out of journal JSON.

Do not submit actual parser/wait observations through 013's positive verifier
path: it explicitly accepts `host_evidence.kind='synthetic-sql-fixture'` and
stores `original-loopback-verifier-v1:synthetic-sql-fixture`. Those positive SQL
tests remain a separate model. Real readback may finish and a separate parser
diagnostic may run, but publication must remain unadvanced until a reviewed,
separately versioned measured-host profile/evidence contract exists. Do not
fabricate CPU/RSS or weaken the contract to obtain a green end-to-end test.

UID **62403** also needs deliberate treatment before combined verification: it
owns the credential-bearing SQL controller in the metadata fixture, while the
standalone verifier uses it for a credential-free reaper. D/U/R can retain
controller 62403, supervisor 62401, source 62402. Do not run the standalone
verifier's unused-62403 preflight inside that combined fixture. Later verification
needs a distinct reviewed reaper UID or an explicitly reviewed credential and
concurrency boundary.

First acceptance cases: one exact D/U/R chain with a fresh stored read; replay
after completion without another GET/POST/grant; lost grant acknowledgement
without GO; ambiguous upload retaining `object_write` and blocking readback;
truncation/hash mismatch refusing advancement; and original/metadata sharing
the aggregate authority/gate. Verify charges, retirement and final
`pending_verification`. A later GET or process exit cannot settle an uncertain
remote write. Keep infrastructure work tied to these concrete workflows.

## Next workstream for visible native chat progress

The existing transcript is
`apps/apple/ScienceReader/Views/ChatTranscript.swift`. The reviewed browser
components are in `scripts/chat-renderer-proof/`; see
[native chat rendering](architecture/NATIVE_CHAT_RENDERING.md).

The next scope is **completed prose and math**, preserving the current table,
bubbles, composer, navigation, encrypted format and scroll-anchor owner. The
current proof does not format general Markdown headings/lists/tables/code; do
not describe it as a complete Markdown chat renderer.

The previous two-display proposal cannot meet the documented dense-row test.
Root and design review agreed a new finite **Simulator experiment**: one
serialized typesetter plus four reusable display surfaces, enough to test three
visible rich rows plus one retained selected/focused row. This decision is newer
than the current architecture document and must be recorded there before
implementation. It is not measured production capacity approval.

- Count attached, idle, loading, executing, selected, focused and retiring
  surfaces. Bound offscreen selection/focus retention to one extra surface.
  Capacity exhaustion must preserve stable selectable source without allocation
  or retry churn. Four displays do not cover every possible dense iPad layout.
- Keep the existing proposed two-request/64-KiB pending bound and 8-MiB/16-entry
  account/session-partitioned cache. Include all retained source/sidecar/output.
- Fresh typesetting realms prevent macros crossing messages. Unknown execution
  remains quarantined globally, including across accounts. Timeout, navigation,
  `stopLoading` and dropping a Swift reference are not retirement proofs. A late
  exact terminal callback may retire old work, but cannot publish into a new
  account or conversation.
- Parameterize actual bounded font, width and theme. The proof currently uses
  fixed 17px/320px math parameters and 16px body padding; do not copy those into
  native bubbles unchanged. Preserve Dynamic Type and the existing spacing.
- Render limits are not persistence limits: the renderer's 32-KiB ceiling must
  not truncate saved messages, whose existing limit is 200,000 bytes. Failure
  keeps the entire literal source selectable/copyable.
- Copy must resolve validated original-source ranges/equation IDs. Whole-message
  Copy returns exact stored text. Keep links inert and assistive MathML present
  once; raw-LaTeX labels are not an accessibility substitute.
- Fence render/height/copy callbacks by account session, composer, current row
  membership, message/source identity, geometry and surface/load lease. Capture
  the current visible anchor immediately before applying height updates.

No native DTO/export/display/ownership API was frozen and no integration files
were created. Next: settle that narrow contract, implement browser native
entry/display packaging and native document/pool/surface components, then add
the narrow transcript integration. Begin with explicit Debug Simulator opt-in;
production adoption follows evidence, including the still-paused physical checks.

Root verification should cover existing tokenizer/output-policy suites, actual
isolated-world execution, exact Copy and mixed selection, encrypted restart,
three visible rich rows plus retained selection/focus, fifth-row pressure,
reuse/late callbacks, branch/account changes, scrollback/keyboard/Dynamic Type/
rotation, and separate app/WebContent measurements. Include paper and figure
WebViews when reporting whole-app resource costs. Do not infer WebContent peak
memory from app RSS.

## Local runtime and test operations

The **only task VM** is `timestep-lifecycle-646`. Its stopped state was freshly
verified during handoff. Do not operate another Lima/Colima VM. It uses VZ,
aarch64, one CPU, 1 GiB RAM, 20 GiB disk, no host mounts, no forwarded host keys
or agent, no proxy propagation, and no non-SSH forwarded ports. Its required
marker is `/etc/timestep-source-lifecycle-fixture.json`, with
`mode=loopback_lifecycle_fixture`, `source_network_enabled=false` and
`hosted_admitted=false`.

```sh
LIMA_HOME=/Users/benbowlwes/science-reader/.artifacts/linux-lima /opt/homebrew/bin/limactl list --json timestep-lifecycle-646
```

Only start it when the next reviewed Linux test requires it; stop it after that
checkpoint. Eleven verifier case directories and the failed test's temporary
directory were cleaned after exporting evidence. Immutable source/evidence
archives remain under `/opt/timestep-verifier-lab/` in the guest. The pinned Linux
Deno 2.9.6 binary is retained at
`/opt/timestep-metadata-lab/combined-df8e8f44f20c/parser-source/node_modules/.bin/deno`,
SHA-256 `d08d392418df53f4e6e88a08909c0e1bccbf9adcead7232df72b6ad6075ec416`.
Do not download or install replacements casually.

The existing **Mac PostgreSQL test cluster is running**, last observed PID
16437, data directory `.artifacts/postgres`, socket directory
`.artifacts/pg-socket`, listening only on `127.0.0.1:55431`, PostgreSQL 18.
Recheck identity before control actions because PIDs may change. This is
Science Reader's test data, not TextBrain's database. The retained executable
comes from the tool path already configured in `scripts/test-database.py`.
Fresh disposable databases use the `science_reader_test_<12 hex>` namespace.
The isolated Linux integration uses PostgreSQL 17; staging was last verified
as 17.11. A passing PG18 check is not hosted compatibility evidence.

Useful existing checks, to run when relevant to a change rather than all again
merely to recreate the handoff:

```sh
PYTHONPATH=workers/source-gateway:workers/source-gateway/linux python3 -B -m unittest discover -s workers/source-gateway/linux -p 'test_*.py'
python3 scripts/test-database.py --candidate supabase/migrations/202610030012_metadata_execution.sql.pending --original-candidate supabase/migrations/202610040013_original_execution.sql.pending --original-only
swift test --package-path apps/apple/ScienceReaderCore
```

Native project configuration is `apps/apple/project.yml`, application target
`ScienceReader`, internal scheme `ScienceReader-Internal`; tests are
`ScienceReaderTests` and `ScienceReaderUITests`. Use an explicit iOS Simulator
destination. Signed Simulator tests require `CODE_SIGNING_ALLOWED=YES
CODE_SIGN_IDENTITY=-` for the real Keychain path. Do not use phone discovery or
an ambiguous device destination. Inspect existing test/build logs for the exact
available Simulator IDs and project-generation setup.

`.artifacts/` contains ignored evidence and retained dependencies. It is not in
a normal git clone. A new agent using this same Mac/workspace can reuse it;
another computer needs a deliberate artifact/environment transfer. Never add
ignored credentials or blanket-copy private artifacts into git.

## Hosted state and later account gates

Dedicated staging project: `coxhjvqpflgxkleydati`, organization
`mhiweqpcwyqtyorgqhla`, Pro/Micro, US West. Production is not provisioned.
Native bundle ID: `com.sciencereader.ios`, Apple team `3BJ33TT599`, registered
bundle resource `33Q7BMJ45Z`. Native Apple capability/audience and six-digit
email-code settings were configured and read back; real provider login is
unverified. New signups remain disabled. Google and dedicated SMTP setup need
account/branding/sender access described in the deployment manifest. No App
Store app record or TestFlight build exists.

Use existing repository operators and their narrow configuration locators for
authorized access. Do not print complete environment files or credentials.
There were no hosted changes or paid provider calls in the latest verifier or
handoff work. Do not assume the last recorded cloud state substitutes for a fresh
preflight when a deployment is actually ready.

Timestep has existing App Store and related software uses. A qualified title was
proposed but neither reserved nor legally cleared. Do not rename schema/crypto
identifiers or claim name availability. The original user wants a coherent paid
app, working Mathpix equations, shared conversion cost savings, reliable offline
and multi-device behavior, and careful UX. Keep those product outcomes visible
in progress updates instead of reporting only worker machinery or test counts.

# Bounded hosted lifetime experiment

Status: **implemented, independently reviewed, and exercised in staging**.
The final eight-request run observed all three target shutdown causes, then
verified the fixed one-page PDF in a later invocation. Cleanup is verified.
Acquisition, verification and original reading remain disabled; no schema or processing-policy change,
executor-policy admission or paid-provider call is part of this experiment.
The successful [compatibility probe](../hosted/README.md) established that the
selected qpdf build runs; it did not establish an executor reclaim horizon.

Each run uses one temporary staging function and at most eight serial
requests, with a closed set of synthetic cases. Its positive evidence is a
platform shutdown event linked to the exact execution while a stress case is
still active. A client timeout, missed heartbeat, allocation exception, fallback
return, `beforeunload` notification, or deleted function is insufficient.

## Hosted evidence — 2026-10-04 UTC

The completed run is
`.artifacts/pdf-verifier/hosted-limits/0f1ad5d9-2c17-4138-a6da-6fbc0b5a473a/`.
Source-manifest SHA-256 is
`46ac243cb907e20a5495052c0b88869115f029022d6a4d7cb199a5aafe5ec0d5`;
the platform-emitted bundle hash is separately
`f03a6ebd53760c095999a4ed115d4298190c645e34b00a6e9f81727f892f0309`.
Function UUID `23efacbf-03a1-48bb-91e4-fd6364746fd0`, version 1, was bound to the
exact staging project and recorded deployment before any test request.

The three denial requests returned 401/403/400 without workload events. Control
completed; CPU and memory responses were 546, the background response was 202,
and recovery returned 200 with a verified one-page completion. HTTP status was
not used as termination proof. The correlated platform events were:

| Active case | Shutdown reason | Application start to shutdown | Worker-accounted CPU | Shutdown memory snapshot |
|---|---|---:|---:|---:|
| CPU WASM | `CPUTime` | 7.054 s | 7,038 ms | 13,853,981 bytes |
| Memory WASM | `Memory` | 3.196 s | 150 ms | 273,245,821 bytes |
| Background task | `WallClockTime` | 399.927 s | 40 ms | 13,534,583 bytes |

These are observed execution/accounting values, not configured limits, peak
memory, per-document CPU or a universal stop horizon. In particular the CPU
observation does **not** establish the documentation's two-second CPU bound.
All three stops occurred before an observed workload terminal/fallback event.
Log delivery is not guaranteed complete; retain the attribution limits below.

The operator sent exactly eight POSTs, used 19 bounded log GETs, 34 control calls
and nine cleanup calls. The final merged window contains 65 normalized rows.
`report.json` records complete observation, three target stops, completed
recovery, no failure and verified exact function/Auth/account cleanup. Its SHA-256
is `6e3b20c6474e00ad04c946200f124e6156a1dd82565357846d90ef1274a78df7`;
`evidence.json` is
`6d987c551547522b01dd0c5c5d93bd235ab9f0645aaac38865cc88ea2903a4ae`.
The operator/classifier source snapshot is preserved separately from deployed
worker source. A subsequent read-only project check confirms all four processing
switches false, no active verification profile, and zero acquisition jobs/original
reservations. This run never grants hosted admission.

The earlier run `7bf7589f-c609-4103-9089-fa3644356e91`, source manifest
`f90129fd120da6a3291865998d4e03373401d2a4a0d35cf220a8a34dfc1acc4d`,
stopped after six POSTs with `ambiguous_start` and also cleaned up completely.
One separately recorded historical query after cleanup obtained the delayed
memory start and matched `Shutdown/Memory`; it did not resume the run or replace
its failed report. That case exposed out-of-order log delivery. The earlier CPU
case exhausted its smaller finite operation ceiling before a subsequent CPU
shutdown, so it remains `fallback_only`. The new run used fresh identities,
bounded delayed-start observation, and the separately reviewed CPU ceiling below;
no request or immutable package was replayed or overwritten.

## What the reviewed source establishes

The observed hosted runtime identifies itself as
`supabase-edge-runtime-1.77.0 (compatible with Deno v2.1.4)`. The reviewed upstream
tag resolves to commit `e847536d7b276428415d7cf9877803d99a16fde5`:

- [Supervisor policies](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/pool.rs#L51)
  include `PerWorker` and `PerRequest`. The source default does not attest the
  configuration deployed by Supabase. In particular, an outstanding request can
  reset the [per-request wall timer](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/supervisor/strategy_per_request.rs#L187).
- A [limit decision](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/supervisor/strategy_per_worker.rs#L452)
  requests a V8 interrupt. The callback invokes
  [`terminate_execution`](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/supervisor/v8_handler.rs#L25).
  A supervisor warning alone is not the final event.
- The [user driver](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/driver/user.rs#L76)
  first waits for `runtime.run` to finish. The
  [worker event path](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/worker_inner.rs#L300)
  then drops the runtime and awaits supervisor finalization before forwarding the
  shutdown event. A correctly correlated event therefore supports completed
  isolate termination for that execution, conditional on the hosted event having
  these semantics; it does not attest an OS process exit or configuration digest.
- [Shutdown accounting](https://github.com/supabase/edge-runtime/blob/e847536d7b276428415d7cf9877803d99a16fde5/crates/base/src/worker/supervisor/mod.rs#L310)
  reports V8 used heap plus external memory at shutdown. This is not peak OS RSS.
  The driver replaces CPU usage with runtime accounting for the worker. Several
  requests or background activity can contribute; do not label it per-call CPU.

The published [hosted limits](https://supabase.com/docs/guides/functions/limits)
currently state 256 MB memory, 2 seconds of CPU per request, 400 seconds of worker
lifetime on a paid plan, and a separate 150-second idle response timeout.
[Background tasks](https://supabase.com/docs/guides/functions/background-tasks)
remain subject to limits. These are policy documentation, not measurements from
this experiment. The [shutdown guide](https://supabase.com/docs/guides/troubleshooting/edge-function-shutdown-reasons-explained)
describes the platform reasons and execution identifier used below.

## Fixed cases and finite fallbacks

The request body will contain only `run_id`, `attempt_id`, and a fixed case name;
the latter two must match the operator's sealed eight-entry request manifest.
It accepts no PDF, URL, allocation size, iteration count, sleep duration, object
path, reservation, callback, or executable input. The implemented bounds are:

| Order | Case | Bounded work | Evidence sought |
|---|---|---|---|
| 1–3 | Missing auth, wrong run, invalid case | Existing bounded authentication/body rejection | Expected 401/403/400; no workload start |
| 4 | `control` | Authenticate, emit fixed identity, return | Correlation works before stress |
| 5 | `cpu-wasm` | A separately identified synthetic WASM loop; 262,144 xorshift32 rounds per chunk, at most 32,768 chunks (2^33 rounds); check an 8-second wall/monotonic fallback between chunks | `Shutdown/CPUTime` during active work |
| 6 | `memory-wasm` | Retain one synthetic WASM memory, grow and touch pages in 8 MiB steps to at most 320 MiB; at most 40 steps and a 10-second fallback deadline | `Shutdown/Memory` during active work |
| 7 | `background` | Respond 202, keep one `waitUntil` promise, bounded 10-second timer steps; at most 45 heartbeats and a 450-second absolute fallback deadline | `Shutdown/WallClockTime` before fallback |
| 8 | `recovery` | One fixed, valid one-page PDF with qpdf build `39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610` | Verified one-page completion in a later request |

Each round executes several integer instructions; rounds are not an instruction
count or CPU measurement. CPU chunks are synchronous and finite. A clock check between chunks is a
cooperative fallback, not proof of an enforced eight-second cutoff during one
chunk. A frozen operation ceiling still applies if the clock behaves unexpectedly.
Local offline validation checks chunk cost and the computed checksum. The timing
is not a universal bound for other hosts. No infinite loop or
unbounded allocation is acceptable, even when host termination is the goal.

The memory case specifically exercises WASM/external-memory accounting. It does
not test every JS allocation category or peak process memory. Keep the original
qpdf memory/profile unchanged: the growing-memory module is a separate synthetic
artifact. A caught grow/allocation failure ends with `allocation_refused`; that
does not prove that the host killed the isolate. CPU termination during memory
pressure is a real stop with the wrong cause for the memory hypothesis.

The background timer checks its deadline before logging or scheduling each next
step, including after suspension. A `beforeunload` handler may emit one advisory
enum but must neither extend work nor write a completion receipt. Closing the
202 response must not cancel the intentional `waitUntil` task. No experiment
request remains connected for 450 seconds.

All requests are serial. A case executes at most once in the operator journal.
Per-isolate replay/concurrency guards add defense, but are not a global durable
quota: a restarted isolate cannot remember an old request. The bounded trusted
operator, secret Auth token, expiring run, and no-retry rule are essential to this
experiment. These are not a production spending-control design.

An uncertain response does not authorize another POST, including a retry of the
same attempt. Obtain evidence for the outstanding case first. A matching hard
shutdown or a confirmed workload terminal event permits the next planned case.
Otherwise stop the sequence and mark later cases `not_requested`. The final
recovery request is conditional on prior work being accounted for; a request
budget is a ceiling, not a requirement to continue after an unresolved execution.

Recovery proves that a later invocation can verify the fixture. It does not prove
same-isolate recovery from a terminated isolate. Retain all execution/isolate
identities. The classifier makes no same-isolate recovery claim.

## Authentication, identity, and authority

Reuse the existing short-lived tagged synthetic Auth user and guarded cleanup
from `../hosted/run.py`. The handler performs only the bounded same-project Auth
user lookup, checking exact user ID plus server-owned run marker before allocating
or compiling. Bind the source manifest in that marker as well. No reusable bypass
password, management token, service key read, database call, Storage call, paid
provider, receipt publication, or production acquisition switch belongs in the
handler. Supabase injects ambient credentials; this is not credential-free
isolation. The existing operator may use its separately held authority to create
and remove the tagged Auth fixture and its pristine account.

`package.build(run_id, user_id, created_at_ms, attempt_ids)` returns `directory`,
`function`, `source_manifest_sha256`, `source_bytes`, `config`, and exactly eight
`requests = [{case, attempt_id}]`. The manifest includes the same request list.
Its config has `project`, `runID`, `userID`, `createdAt`, `expiresAt`,
`buildSHA256`, `path`, and the same attempts as `{case, attemptID}` entries.
The function slug remains `pdf-verifier-probe-<first eight run UUID characters>`.

The operator packages, deploys once, pins the returned deployment, then creates
the already-selected synthetic user once. Server-owned Auth metadata must contain
`science_reader_check = pdf-verifier-probe`, `probe_kind = hosted-limits-v1`,
`check_run_id`, `source_manifest_sha256` and `deployment_id`. The request header
`x-probe-source-sha256` must match that trusted marker. The deployment marker must
match the actual `DENO_DEPLOYMENT_ID`, whose project and version-one form are
validated. A complete manifest cannot contain its own digest; the Auth marker
provides that binding and the operator independently verifies its association
with deployed bytes. A caller field never supplies the trusted source hash.
Logs use the observed `Deno.version.deno` unchanged and check it against the
reviewed runtime; the expected string is not substituted as an observation.

Capture exact source bytes before packaging. Preserve an exclusive run directory
containing all source, synthetic WASM bytes/recipe, selected immutable qpdf bundle
identity, fixture bytes/hash, configuration and file manifest. Refuse overwrite.
Record the source-manifest SHA separately from the Management API's emitted
bundle hash, function UUID, deployment ID, version and runtime version. The server
may transform source during bundling. Before any POST, verify the exact staging
project/organization and the unique function's identity. A changed deployment or
runtime stops the run; it is not an equivalent experiment.

The eight deployed files are `index.ts`, `handler.ts`, `workloads.ts`, `auth.ts`,
`runtime.ts`, `wasm.ts`, `verifier.mjs` and generated `assets.ts`. The manifest
binds each file plus `supabase_config_sha256` for exact CLI-consumed
`supabase/config.toml` bytes. `captured_files` binds producer snapshots, the
synthetic WASM recipe/binary, raw verifier identity, fixture manifest and unchanged
recovery PDF. Sources/config are read-only; `supabase/.temp` stays writable for
the CLI's link/cache state. The operator verifies the pinned configuration
immediately before deployment.

Foreground successful responses use HTTP 200; background acceptance uses 202.
They contain the finite event identity fields plus `schema_version`, `result`,
`pages`, finite `work` counters (or null), `elapsed_ms`, null `cpu_ms` and
`peak_memory_bytes`, and `hosted_admitted: false`. They are not termination
receipts. Replayed valid attempts return 409; overlapping work returns 429;
expiry returns 410. Caught workload failures return a fixed 500 error and emit
`failed` terminal evidence without raw exception details. Only `failed` may have
null elapsed time; no timing is clipped or invented.

Compile a package expiry at most 20 minutes from package creation. Each case
also checks expiry immediately before starting, with enough remaining time for
its complete fallback plus observation/cleanup margin. No start within the final
three minutes. `background` requires at least ten minutes remaining. An operator
pause that misses these windows ends the run; it never extends the same package.

## Evidence, log budget, and interpretation

Log reads use only the exact owned function ID and bounded UTC
windows through:

`GET /v1/projects/<staging-ref>/analytics/endpoints/logs`

`observe.py` uses URL-encoded `sql`, `iso_timestamp_start`, and
`iso_timestamp_end` values. The API rounds those parameters to minutes; the
adapter widens them and adds exact UTC predicates to its bounded query. It uses
`logs.timestamp` explicitly because ClickHouse expands the formatted `timestamp`
output alias inside an unqualified WHERE predicate. A scoped live query caught
that distinction before the first deployment. The query selects `timestamp`,
`event_message` and explicit `log_attributes` fields from `logs`, constrains
`source = 'function_logs'` and the exact owned `function_id`, and uses `LIMIT 50`.
Retain deployment/execution ID, event type, reason and bounded numeric accounting
fields when actually supplied. Do not silently invent absent identity fields.

The reviewed operator journals at most eight function POSTs and at most 24 log
GETs, with no simultaneous requests and no automatic transport retries. The
observer queries 180-second slices and splits any full 50-row page; overlapping
boundary records are deduplicated. Unsplittable pages, missing required fields,
uncovered windows, changed identities and exhausted poll budgets are inconclusive.
Final observation rereads sealed slices for late records. Control-plane requests
and independently journaled cleanup have separate caps of 64 and 24; exhausting
the former preserves cleanup authority.

Only parse application log JSON with the finite schema in `classify.py`. Drop
unknown messages rather than persist their raw text. The adapter records whether
all intended pages were obtained without truncation. Neither the classifier nor a caller-provided flag
proves the actual remote query was complete; the operator/transport must establish
that separately. Repeated identical rows across overlapping reads can be deduped.

Application `start` links run, attempt, fixed case, source manifest, deployment,
platform execution, fresh isolate ID and runtime version. Platform `Shutdown`
must be linked by the query's exact function and that execution ID. Function-ID
and deployment attributes, when supplied by a row, must agree too. A start's
claimed execution ID must equal the platform envelope. Multiple starts for one
attempt, overlapping active cases, contradictory terminal events, or two shutdown
records for one execution are ambiguous and cannot yield positive evidence.
Valid events arriving before their start remain incomplete and permit only the
remaining bounded log GETs. They cannot authorize a successor POST. A delayed
start must agree with the entire retained sequence and binding before that
attempt can classify; conflicting starts still fail immediately.

A complete bounded query is not a guarantee that the platform delivered every
application log. The positive conclusion concerns the correlated isolate's final
shutdown cause, not the exact WASM instruction interrupted. In particular,
missing terminal text cannot independently prove uninterrupted execution. Reject
damaged structured records; retain this limitation even when the remaining
records are consistent. A reusable enforcement guarantee needs the host-policy
binding and external stop semantics, not absence of a completion message.

| Observation | Classification |
|---|---|
| Matched `CPUTime`, `Memory`, or `WallClockTime` while the intended case is active | Hard limit stop observed for this execution; record actual cause |
| Same with a different cause from the case's hypothesis | Hard stop observed, target limit not established |
| Workload emits fallback or allocation refusal first | Finite workload stopped itself; target host limit unproven |
| Matching `EarlyDrop`, `EventLoopCompleted`, or `TerminationRequested` during stress | Isolate ended for another reason; target host limit unproven |
| Matched `UncaughtException` or `BootFailure` before workload completion or its shutdown | Workload attribution inconclusive, even if a later limit shutdown confirms that the isolate ended |
| Application `failed` terminal event, including an unusable clock | Workload attribution inconclusive; a later cumulative limit is not a successful stress test |
| 504/546, client timeout, missing heartbeat, `beforeunload`, missing/truncated logs, or only deletion | Inconclusive |

Retain runtime failures only as their finite event type, timestamp and execution
ID. Raw exception messages are discarded, including from deduplication keys.
Failures in another execution do not contaminate the matched case. A failure
after an earlier case completed is not attributed retroactively to that case;
a subsequent case on that failed execution cannot claim a healthy continuation.
An exception followed by cumulative CPU shutdown proves the final stop, not a
successful CPU-pressure test. The classifier keeps these conclusions separate.

Keep `cpu_time_used` labelled **worker-accounted CPU** and memory fields
labelled **shutdown snapshots**. Never rename either to peak process memory,
per-document CPU, or a hard configured limit. The offline classifier intentionally
does not copy these optional numeric fields into its conclusion. Raw returned
metrics may be retained by a separately reviewed finite-field adapter with their
original scope. It always returns `hosted_admitted: false`.

## Failure and cleanup model

Persist mutation intent before creating the tagged user or function, and request
intent before sending a POST. Auth/deploy/execute response loss is uncertainty;
do not repeat the mutation. Keep credentials only in process memory. The cleanup
journal records public IDs, hashes, timestamps and finite stages, never bearer
tokens, passwords, source bodies, raw exceptions or arbitrary log messages.

After the experiment, remove the exact function with existing ID/version/hash
guards, verify absence, remove the exact tagged Auth user, and delete only its
proved-pristine generated account using the existing guarded harness. Attempt
independent cleanup even when another cleanup step fails. Identity mismatch stops
that resource's deletion and produces a retained cleanup failure for review.

Deletion blocks future invocations but is not proof an already running worker
stopped. If a case lacks terminal evidence, stop new work, revoke ingress through
the tagged fixture/function cleanup, preserve the uncertainty, and perform only
the remaining bounded log observation. Finite workload fallbacks reduce exposure;
their deadlines are not promoted to external stop guarantees. Do not release any
production job, capacity or claim on the basis of this experiment's cleanup.

The immutable report must distinguish workload evidence, observation completeness,
and verified resource cleanup. A cleanup failure does not erase prior logs; a
successful cleanup does not turn an inconclusive stress case into a pass.

## Scope of the offline classifier

`classify.py` is a pure, no-network classifier of a **normalized, operator-bound
evidence envelope**. It validates public identities, fixed request order/budget,
timestamps and application log schemas; joins platform shutdown events; and
fails closed on ambiguity. It does not authenticate a caller, query Supabase,
validate a remote server bundle, or measure a host. Input is limited to 512 KiB
through the command-line entry point; errors have fixed codes only.

Run the local tests without network or credentials:

```sh
python3 -m unittest discover -s workers/pdf-verifier/hosted-limits -p 'test_*.py'
```

Current local checks: 44 classifier, six packager, 13 observer and 13 operator
tests pass: 76 combined Python tests. The 23 handler/workload tests and three
explicit-package tests pass, and the generated entry point passes Deno checking.
The existing compatibility operator's 21 regressions also pass after its
additive cleanup-hook change. Offline classifier events are
synthetic, not hosted CPU, memory or lifetime measurements.

The preserved first local package, with the earlier 16,384-chunk CPU ceiling, is
`.artifacts/pdf-verifier/hosted-limits/4d84a2f0-a8d5-416b-90d1-ea59442e7535/`,
with source-manifest SHA-256
`1078a3d6eb22af61dfdfbd2f10aa738767d6677b35c3ccd7faee8928a9da5f15`.
Its `local-resource.json` records two isolated local Deno children, each with a
12-second parent process timeout and network denied. CPU fallback completed in
8,046.772 ms process wall time / 7,999.387 ms workload wall time after 16,156
chunks. The one-chunk checksum was `1010791896`; two observed cold chunk times
were 0.811 and 0.779 ms. Retained/touched memory stopped at exactly 40 steps /
335,544,320 WASM bytes in 4,269.677 ms process wall time. These are local fallback
results, not hosted terminations. Memory fields are post-work snapshots;
CPU/peak process memory remain null. The 450-second background schedule was
tested with an injected clock, not a real 450-second worker lifetime.

The CPU ceiling is now 32,768 chunks because the earlier hosted case completed
all 16,384 chunks before its subsequent CPU shutdown; that was correctly a
fallback, not an observed stop during active work. The per-chunk work and
8-second dual-clock fallback are unchanged. A fresh local package at
`.artifacts/pdf-verifier/hosted-limits/66073386-d76e-4fb9-a676-5d3c1b22e62b/`
has source-manifest SHA-256
`2625ba4234497d1a7c2454f69d7a5b3c8b9976c52f10c8cccc5b3852ca6aee51`.
Its separate `local-resource.json` records a network-denied CPU child with a
12-second external timeout: fallback after 15,577 chunks in 8,062.645 ms process
wall time / 8,000.034 ms workload wall time, first-chunk checksum `1010791896`.
The 23 handler/workload tests pass with the new ceiling. Memory, background and
the pinned qpdf profile are unchanged; this local result grants no hosted
admission and does not replace the earlier evidence.

Run handler/workload tests locally with network denied:

```sh
node_modules/@deno/darwin-arm64/deno test --no-config --deny-net workers/pdf-verifier/hosted-limits/handler.test.ts workers/pdf-verifier/hosted-limits/workloads.test.ts
```

`package.test.ts` takes an explicit `local-package-result.json` path after `--`
and needs read access to this source directory and that package directory.
`local_case.ts` takes that result path plus `cpu-wasm` or `memory-wasm`; run it
only in a network-denied child with an external 12-second timeout. No local
check enables a profile or stands in for a host result.

Local checks cover workload ceilings/checksums, authorization before allocation,
recovery binding, source capture, identity/expiry/redirect refusal and background
registration failure. Independently reviewed operator schedules cover response
loss without replay, delayed/missing starts, exhausted observation, changed
function/user identities, late records, full pages, and optional evidence-write
failure that cannot block cleanup. Its bounded ownership journal excludes bulk
logs; locked cleanup rechecks all server-owned Auth markers before account deletion.

Even three observed target shutdowns will not alone admit the verifier. The
deployment policy still needs a trusted identity, a memory accounting scope
compatible with the selected host, and an independent reclamation horizon.
Installed migration 011 does not extend reservation `safe_after` on verifier
claim. Successor claims, scans, orphan cleanup, reporting and capacity release
must respect a proved stop boundary through a future reviewed change. If Edge
cannot provide it, retain Edge orchestration and use a one-shot verifier with an
external watchdog, OS memory limit and confirmed process exit.

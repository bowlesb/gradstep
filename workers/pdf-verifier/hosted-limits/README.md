# Hosted lifetime experiment proposal

Status: **proposal and offline evidence classifier only**. No workload, packager,
operator, deployment, network experiment, profile admission, or SQL change is
implemented here. Acquisition, verification, and original reading remain disabled.
The successful [compatibility probe](../hosted/README.md) established that the
selected qpdf build runs; it did not establish an executor reclaim horizon.

The proposed experiment uses one temporary staging function and eight serial
requests, with a closed set of synthetic cases. Its positive evidence is a
platform shutdown event linked to the exact execution while a stress case is
still active. A client timeout, missed heartbeat, allocation exception, fallback
return, `beforeunload` notification, or deleted function is insufficient.

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
path, reservation, callback, or executable input. Constants below are proposed
limits to review and locally validate before writing a deployable workload.

| Order | Case | Bounded work | Evidence sought |
|---|---|---|---|
| 1–3 | Missing auth, wrong run, invalid case | Existing bounded authentication/body rejection | Expected 401/403/400; no workload start |
| 4 | `control` | Authenticate, emit fixed identity, return | Correlation works before stress |
| 5 | `cpu-wasm` | A separately identified synthetic WASM loop; fixed chunks and at most 2^32 integer operations; check a monotonic 8-second fallback deadline between chunks | `Shutdown/CPUTime` during active work |
| 6 | `memory-wasm` | Retain one synthetic WASM memory, grow and touch pages in 8 MiB steps to at most 320 MiB; at most 40 steps and a 10-second fallback deadline | `Shutdown/Memory` during active work |
| 7 | `background` | Respond 202, keep one `waitUntil` promise, bounded 10-second timer steps; at most 45 heartbeats and a 450-second absolute fallback deadline | `Shutdown/WallClockTime` before fallback |
| 8 | `recovery` | One fixed, valid one-page PDF with qpdf build `39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610` | Verified one-page completion in a later request |

CPU chunks are synchronous and finite. A clock check between chunks is a
cooperative fallback, not proof of an enforced eight-second cutoff during one
chunk. A frozen operation ceiling still applies if the clock behaves unexpectedly.
Local offline validation must bound individual chunk cost and verify the computed
checksum so the compiler cannot remove the intended work. No infinite loop or
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

Capture exact source bytes before packaging. Preserve an exclusive run directory
containing all source, synthetic WASM bytes/recipe, selected immutable qpdf bundle
identity, fixture bytes/hash, configuration and file manifest. Refuse overwrite.
Record the source-manifest SHA separately from the Management API's emitted
bundle hash, function UUID, deployment ID, version and runtime version. The server
may transform source during bundling. Before any POST, verify the exact staging
project/organization and the unique function's identity. A changed deployment or
runtime stops the run; it is not an equivalent experiment.

Compile a package expiry at most 20 minutes from package creation. Each case
also checks expiry immediately before starting, with enough remaining time for
its complete fallback plus observation/cleanup margin. No start within the final
three minutes. `background` requires at least ten minutes remaining. An operator
pause that misses these windows ends the run; it never extends the same package.

## Evidence, log budget, and interpretation

Future log reads must use only the exact owned function ID and bounded UTC
windows through:

`GET /v1/projects/<staging-ref>/analytics/endpoints/logs`

The existing successful method uses URL-encoded `sql`, `start`, and `end` values,
with a window no longer than 24 hours. The query selects `timestamp`,
`event_message` and explicit `log_attributes` fields from `logs`, constrains
`source = 'function_logs'` and the exact owned `function_id`, and uses `LIMIT 50`.
Retain deployment/execution ID, event type, reason and bounded numeric accounting
fields when actually supplied. Do not silently invent absent identity fields.

The future operator must journal at most eight function POSTs and at most 24 log
GETs, with no simultaneous requests and no automatic transport retries. Split
time windows or filter by an already verified execution ID so a full 50-row page
is never treated as complete. Any full page, missing required field, uncovered
window, changed identity or exhausted poll budget is inconclusive. Authentication,
deployment identity reads, and independently journaled cleanup have separate
small fixed budgets; exhaustion must preserve cleanup authority. The exact
pagination/poll implementation still needs independent review before activation.

Only parse application log JSON with the finite schema in `classify.py`. Drop
unknown messages rather than persist their raw text. The query adapter is not
implemented. Its future output must identify whether all intended pages were
obtained, without truncation. Neither the classifier nor a caller-provided flag
proves the actual remote query was complete; the operator/transport must establish
that separately. Repeated identical rows across overlapping reads can be deduped.

Application `start` links run, attempt, fixed case, source manifest, deployment,
platform execution, fresh isolate ID and runtime version. Platform `Shutdown`
must be linked by the query's exact function and that execution ID. Function-ID
and deployment attributes, when supplied by a row, must agree too. A start's
claimed execution ID must equal the platform envelope. Multiple starts for one
attempt, overlapping active cases, contradictory terminal events, or two shutdown
records for one execution are ambiguous and cannot yield positive evidence.

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
| 504/546, client timeout, missing heartbeat, `beforeunload`, missing/truncated logs, or only deletion | Inconclusive |

Retain runtime failures only as their finite event type, timestamp and execution
ID. Raw exception messages are discarded, including from deduplication keys.
Failures in another execution do not contaminate the matched case. A failure
after an earlier case completed is not attributed retroactively to that case;
a subsequent case on that failed execution cannot claim a healthy continuation.
An exception followed by cumulative CPU shutdown proves the final stop, not a
successful CPU-pressure test. The classifier keeps these conclusions separate.

Keep `cpu_time_used_ms` labelled **worker-accounted CPU** and memory fields
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

Current local evidence: 37 classifier tests pass. All events in those tests are
synthetic; they are not hosted CPU, memory, or lifetime measurements.

Required future tests cover workload bounds/checksums, authorization before any
allocation, final recovery fixture binding, source capture before build, journal
crash schedules, identity/expiry/refused redirects, query completeness and safe
cleanup. The classifier tests are not substitutes for those tests or for an
independent review before remote activation.

Even three observed target shutdowns will not alone admit the verifier. The
deployment policy still needs a trusted identity, a memory accounting scope
compatible with the selected host, and an independent reclamation horizon.
Installed migration 011 does not extend reservation `safe_after` on verifier
claim. Successor claims, scans, orphan cleanup, reporting and capacity release
must respect a proved stop boundary through a future reviewed change. If Edge
cannot provide it, retain Edge orchestration and use a one-shot verifier with an
external watchdog, OS memory limit and confirmed process exit.

# Paper import reliability

> **Initial Cloud Run checkpoint, 2026-10-06 20:10 PDT:** migrations 022/023 applied to staging; worker deployed to Cloud Run
> (`gradstep-pipeline`, project `gradstep`, us-west1, image built locally and pushed to Artifact Registry, runtime
> identity `gradstep-pipeline@gradstep.iam.gserviceaccount.com` with access to its five secrets only); staging's
> `science_reader_pipeline_url` points at it. The 49-page paper that looped since 2026-10-05 rendered and published
> on Cloud Run within a minute. Deploy: `python3 scripts/deploy-pipeline-worker.py deploy --project gradstep`.

Owner, 2026-10-06: "adding a pdf is a thing that needs to be absolutely bullet proof, and should even have analytics on
how long it takes generally and failure rates." Approved: move the heavy work to Google Cloud Run (owner sets up the
Google Cloud project).

## What failed (measured 2026-10-06)

Two imports looped silently on staging. Edge Functions kill a run that exceeds a platform limit before it can record a
failure; the lease then expires and the next run claims the same paper again, forever, with `failures = 0`.

| Paper | Step | Need (measured locally, Node 24) | Edge Function limit |
|---|---|---|---|
| 2610.02287 (49 pages) | render | 1.5 s CPU, 174 MB heap / 394 MB resident | 2 s CPU, 256 MB |
| 2610.03771 (44.6 MB PDF) | download | several in-memory copies of 45 MB (chunks, joined buffer, upload body, PDF parse) | 256 MB |
| `paper-worker` itself | deploy | 27 MB bundled (mathpix-markdown-it pulls in MathJax) | 20 MB (local bundling), 5 MB (server-side) |

The render loop ran 512 times since 2026-10-05; the download loop twice before both were failed by hand. Every
`paper-worker` deploy now fails (413 / internal error), so the Edge worker cannot be fixed in place. Supabase has
queues (pgmq) but no compute beyond Edge Functions, whose limits are fixed on every plan.

## Architecture

### Spending-control hardening (deployed; configuration verified 2026-10-08 UTC)

Request-based Cloud Run billing uses a bounded, awaited request lifecycle. The HTTP process runs
each pipeline invocation in a Node worker thread, awaits its result, and terminates/joins the thread before replying.
A hard 840-second limit leaves 60 seconds before Cloud Run's 900-second request timeout. A timeout is a failure;
it must not settle an unknown provider submission as free, release a still-uncertain liability, or start a retry.
Existing durable provider grants and fenced queue leases allow later reconciliation. Each instance admits one
run; health checks, invalid methods, unauthorized requests and overlapping wakeups do not create another thread.
This boundary also covers account-deletion and tag projection loops, whose per-request network timeouts did not
previously establish an overall run limit. Expensive renderer imports live in the worker, not the HTTP process.

Deployment explicitly selects `--cpu-throttling`, zero minimum instances, and a maximum of three at both
service and revision scope, then reads back the configuration. The billing-flag correction reached staging in
`3e28a55`; the bounded thread lifecycle and maintenance/activation controls subsequently reached staging with
the coordinated spending-control rollout. The one-minute scheduler remains a recovery wakeup;
it is not permission to run outside the HTTP request. The scheduled pg_net caller now has a 600-second deadline;
the immediate import wakeup remains a short best-effort request, and either caller's timeout does not establish that
a pipeline run failed. Google documents that HTTP/1.1 client disconnects
are not propagated to the container; the server still awaits the run. Cloud Run's own timeout is the upper bound
that must be avoided. Any future HTTP/2, streaming-response, detached-task or periodic-background change requires
rechecking this lifecycle before rollout. No claim of free hosting follows from choosing request-based billing.
[Billing settings](https://docs.cloud.google.com/run/docs/configuring/billing-settings),
[request timeout](https://docs.cloud.google.com/run/docs/configuring/request-timeout),
[client disconnect behavior](https://docs.cloud.google.com/run/docs/troubleshooting#client-disconnect).

**Staging rollout, 2026-10-09:** revision `gradstep-pipeline-00019-2d9` is active at 100% traffic after the paused
deployment/readiness/activation procedure. The scheduler's old 5-second pg_net timeout was an Edge acknowledgement
window and caused false timeout rows while the awaited Cloud Run run was finishing in roughly 4–5 seconds. Migration
`202610090054_pipeline_cron_timeout.sql` recreates the named `science-reader-pipeline` job with a 600-second timeout,
below the worker's 840-second hard bound; the immediate import wakeup remains a 1-second best-effort request. The
first post-change scheduler responses were HTTP 200. This is an acknowledgement timeout correction, not permission to
detach work or to treat a timed-out provider request as settled.

The initial hardening rollout followed migrations 034–038 and asset enforcement, through paused revision 00008
and activated revision 00009. Subsequent uploads use migration 039. At **2026-10-08 09:00:47 UTC**, read-only
configuration evidence records **`gradstep-pipeline-00012-9xj`** receiving all traffic: maintenance off,
request-based CPU, minimum 0 / maximum 3 at both service and revision scope, concurrency 1, 900-second request
timeout, 1 vCPU and 2 GiB memory. All six secret references are numeric and pinned: five at version 11 and
Anthropic at version 5. Evidence: `.artifacts/takeover-20261008/pipeline-policy-readback.json`. This metadata
readback does not independently exercise the thread lifecycle or establish measured allocation and invoices.

**Historical pre-rollout inspection, 2026-10-08 00:11:16 UTC:** revision `gradstep-pipeline-00007-j5l` had
request-based CPU, revision maximum 3, but **service maximum 20** and no maintenance switch. This is the observed
older configuration, superseded by the 09:00:47 readback above. The allowlisted report is
`.artifacts/pipeline-readiness-schema-20261007.json`; it verifies API/image-digest response shapes, not an invoice
or a successful cutover.

- **Supabase stays the system of record and the queue.** `pipeline_papers` rows with fenced leases are the queue;
  pg_cron + pg_net call the worker every minute with the pipeline secret, as today.
- **The worker moves to Cloud Run** (`gradstep-pipeline`): the same `runPipeline` code under Node 24 (the shared
  modules already run under Node in tests), 2 GiB memory, 1 vCPU, concurrency 1, up to 3 instances, 900 s request
  timeout, scale to zero. Secrets come from Secret Manager. It also runs the account-deletion sweep. The Vault URL
  `science_reader_pipeline_url` is switched to the service; the Edge `paper-worker` stays deployed but unscheduled
  until the cutover is verified, then is deleted.
- **Downloads hold one copy.** The PDF is read into one buffer sized from `content-length` (bounded by the policy's
  maximum), hashed and counted from that buffer, and uploaded from it.
- **Cost:** the original $0–2/month estimate was unsupported by the deployed instance-based billing mode.
  The [dated infrastructure inspection](../reviews/PIPELINE_SPENDING_EVIDENCE_20261007.md) measured 22.49 aggregate
  billable instance-hours in a 24-hour window; no invoice was retrieved. The request-based billing correction was
  deployed separately, followed by the bounded thread hardening. Current configuration is verified above;
  full-period allocation and invoice reconciliation remain outstanding. See
  [operations](OPERATIONS_AND_BILLING.md) for the unchanged budget, dated metrics and fixed commitments.

### Deferred deployment and explicit activation (implemented 2026-10-07; used in staging rollout)

The [spending rollout](SPENDING_CONTROLS.md) requires a maintenance interval. Installing code, changing policy,
and enabling work are separate operations:

- `deploy-staging.py staging --defer-activation` deploys the selected Edge bundles without modifying the
  pipeline Vault URL/secret or schedule and without workflow checks. It requires the existing pipeline secret
  and refuses secret rotation. Use `--skip-migrations --functions chat add-reference` for the admitted Edge
  bundles before 034, after the operator has paused work. A `store-sync` deploy still requires 038's actual
  active purchase-observation cleanup job. `--skip-checks` alone does **not** defer activation.
- `deploy-pipeline-worker.py deploy --project gradstep --defer-activation` installs
  `PIPELINE_MAINTENANCE=true`, verifies the resulting revision/configuration/health, and skips import retries
  and workflow checks. Authenticated POSTs return 503 before a thread, tag, deletion, renderer or import starts.
  Missing or misspelled activation values also select maintenance. GET `/health` reports the exact revision
  and `mode: maintenance`; this means the process can answer health, not that work is enabled.
  Each secret is bound to the numeric version returned by its creation, rather than `latest`; missing or
  ambiguous creation acknowledgements stop deployment before building/routing the revision. Activation checks
  all six dedicated references and pinned versions. An image digest and service ETag alone cannot freeze a
  mutable secret alias. [Cloud Run secret versions](https://docs.cloud.google.com/run/docs/configuring/services/secrets).
- `cutover --url https://gradstep-pipeline-885355087025.us-west1.run.app --defer-activation` verifies maintenance
  health and changes only the Vault URL. It does not disable an already enabled scheduler or old revision.
  The operator must preserve the paused state throughout the cutover.
- Normal deploy, retry and workflow-check commands refuse a maintenance worker. A normal worker deploy also
  refuses a legacy revision without an explicit active switch, so an ordinary deployment cannot accidentally
  perform the first activation.

Local tests exercise an absent `worker_provider_attempt_begin` RPC (PostgREST `PGRST202`) after an otherwise
successful legacy reservation: Anthropic, chat search, ingest lookup and reference lookup send no provider
request. Already warm **admitted** adapters recheck every subsequent attempt; native-search fallback is refused
before transport even if offered by a caller. These results do not protect an already running **old bundle**
that never called admission. Every old paid route, including the unscheduled legacy `paper-worker`, must be
covered by the retirement evidence below. No test used a paid provider.

The read-only report is produced after migrations 034–038 and asset reconciliation/enforcement:

```sh
python3 scripts/deploy-pipeline-worker.py readiness --project gradstep \
  --expected-revision gradstep-pipeline-REVISION \
  --output .artifacts/rollout-evidence/readiness.json
```

It verifies the dedicated project/service/region, exact paused revision, immutable image digest, service and
revision limits, sole 100% traffic target, maintenance health, immutable migration prefix, paused budget/pipeline/
tag policies, disabled native search, purchase cleanup and reconciled asset inventory. It reports unresolved
provider liabilities without clearing them. Pipeline claims, legacy open chat operations, unresolved asset
writes or an active inventory scan block activation. A nonzero retained provider liability can be valid, but its
attribution and reconciliation must be reviewed in the evidence; an empty queue is never shutdown proof.
Legacy/dual reader delivery remains allowed for old clients and is explicitly reported as replayable signed-URL
delivery, not a fully bounded transfer guarantee.

### Evidence that old executions ended

`readiness` does not certify remote process termination. The following are supported operator evidence paths;
none are executed by deployment tooling. Keep timestamped, allowlisted metadata under
`.artifacts/rollout-evidence/`. Exclude credentials, raw environment, user prompts, request bodies and signed URLs.

**Cloud Run:** capture the complete old revision list before routing changes, then capture service traffic after
the maintenance revision receives all traffic. Remove old revision tags as well as weighted traffic; a tag is a
separate invocation path. Read-only inventory commands can use:

```sh
gcloud run revisions list --project gradstep --region us-west1 --service gradstep-pipeline \
  --format='json(metadata.name,metadata.uid,status.conditions,status.observedGeneration)'
gcloud run services describe gradstep-pipeline --project gradstep --region us-west1 \
  --format='json(metadata.uid,metadata.generation,status.observedGeneration,status.traffic,spec.traffic)'
```

For **every** old revision, retain its terminal `RETIRED` condition (not `RETIRING`, `RESERVE`, zero traffic or
zero minimum instances) and the readback that it has no routable tag/traffic. Google describes a retired revision
as having its infrastructure retired. Alternatively, a separately reviewed deletion of an old revision is a
supported irreversible operation: retain the exact revision UID, completed successful deletion operation and
subsequent absence/deleted-state readback. Google disallows deleting current/routable revisions; deletion also
prevents accidentally routing back to the old code. A lost deletion acknowledgement or incomplete old revision
inventory is unresolved and requires readback/platform confirmation. These are control-plane observations,
not an inference from a quiet metric. [Revision lifecycle and deletion](https://docs.cloud.google.com/run/docs/managing/revisions),
[revision condition reasons](https://docs.cloud.google.com/run/docs/reference/rest/v2/Condition).

Cloud Run documents SIGTERM followed by forced termination during actual instance shutdown. A request timing
out or returning 504 does not initiate that guarantee; the container can keep executing. Use recorded retirement,
deletion or platform-confirmed termination, not “900 seconds elapsed.”
[Container shutdown](https://docs.cloud.google.com/run/docs/container-contract#instance-shutdown),
[request timeout](https://docs.cloud.google.com/run/docs/configuring/request-timeout).

**Supabase Edge:** before cutover, record each old paid function's deployment ID/version and enumerate its
execution IDs from complete Boot/invocation metadata. Capture the replacement deployment's successful status,
version and source artifact hash. In the project's Edge Functions logs/Logs Explorer, correlate every old
execution with its actual structured `ShutdownEvent` (`event.Shutdown.reason` and `metadata.execution_id`),
including background `waitUntil` work. `EventLoopCompleted`, `EarlyDrop` or a runtime termination reason is
terminal evidence for that execution; an HTTP response or a generic wall-clock warning is insufficient. Keep
query bounds, pagination/completeness, deployment ID, execution ID, timestamps and terminal reason in the
operator's export. Do not copy private application log text. Supabase documents these terminal events and
external termination requests, but this repository has no supported per-isolate kill API.
[Runtime shutdown events](https://supabase.com/docs/guides/troubleshooting/edge-function-shutdown-reasons-explained),
[function logging](https://supabase.com/docs/guides/functions/logging),
[wall-clock warning caveat](https://supabase.com/docs/guides/troubleshooting/edge-function-wall-clock-time-limit-reached-Nk38bW).

A deployment acknowledgement alone does not prove all old isolates ended. Logs with retention gaps, sampling,
truncation or missing execution IDs do not establish a complete inventory. If complete per-execution evidence
cannot be obtained, retain the pause and obtain Supabase confirmation scoped to the old deployment IDs and
cutover time; do not substitute “400 seconds elapsed.” Disable/remove any legacy paid endpoint that cannot be
replaced with the admitted bundle before declaring its routing retired. This is an operator action, not something
the readiness script silently performs.

**Liabilities:** ending a local process does not cancel an already accepted remote OCR/model/search request or
an uncertain Storage write. Record all known request/job IDs, old holds and pending writes, their attribution and
the positive evidence used for settlement/reconciliation. Unknown provider jobs retain their ceilings; absent
responses, lease expiry and object absence alone do not justify release. The asset scan stays blocked by unresolved
writes. A retirement document must never direct an operator to zero these records to obtain a green report.

### Scoped operator attestation and activation

The manifest has `format: 1`, `decision: "approved"`, a timezone-qualified `observed_at`, and the report's exact
`scope`, `revision`, `image_digest`, `database_sha256` and `configuration_sha256`. Its `documents` array contains
one `{kind, path, sha256}` for each of:

- `old_cloud_run_invocations_terminated`: complete revision inventory and retirement/deletion evidence.
- `old_edge_invocations_terminated`: complete old deployment/execution inventory and terminal evidence, or
  scoped platform confirmation.
- `admitted_edge_deployments_verified`: versions and reviewed source/build hashes for all paid entry points.
- `legacy_liabilities_reviewed`: attribution and reconciliation decisions, with unknown amounts retained.

Document paths resolve inside `.artifacts/rollout-evidence/`; source documents are bounded to 32 MiB each and
the manifest to 64 KiB. Prepare a manifest with `decision: "pending"` until the review is complete. A recent
timestamp is an evidence freshness requirement, never a grace period that proves shutdown. The script verifies
scope, file hashes and freshness; it labels the result **operator attestation verified for scope and integrity**.
It does not interpret the files as an independently verified termination certificate.

```sh
python3 scripts/deploy-pipeline-worker.py activate --project gradstep \
  --expected-revision gradstep-pipeline-REVISION \
  --evidence .artifacts/rollout-evidence/approval.json
```

Activation repeats the read-only checks and makes one conditional Cloud Run service update using its observed
ETag. It pins the observed image digest, clears only the maintenance switch, waits for the resulting operation,
and verifies that operation's exact new revision, unchanged image, pinned secret versions and all other reviewed
runtime settings. Another concurrent revision cannot be mistaken for the completed activation. Conflicts or ambiguous acknowledgements
are not automatically retried; inspect current state first. Database policy and scheduler changes remain separate
operator steps, and no workflow checks or paid calls run as part of activation. Keep other deployment/policy
mutations frozen during this multi-system operation; the ETag protects the Cloud Run update, not a distributed
transaction with Supabase. The [Cloud Run update API](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.services/patch)
returns a long-running operation; its [service ETag](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.services)
detects concurrent service modifications.

## Loop breaker (migration 022)

A lease that expires while still claimed means the worker died (a normal release clears the claim). Before every
claim, expired claims are swept:

- the paper's `stage_crashes` increases and a `crash` event is recorded;
- in stages without provider work (`metadata`, `private_split`, `download`, `render`), the third crash in the same
  stage fails the paper with a retryable error (`metadata_unavailable`, `download_failed`, `conversion_failed`) and
  `resume_stage` set, so Retry resumes that stage (render reuses the stored OCR result; nothing is charged again);
- otherwise the paper waits 2, 4, 8 … (at most 30) minutes before it can be claimed again.

Entering a new stage resets the counters.

## Telemetry (migration 022)

`app_private.pipeline_events` (append-only, 180-day retention, no account IDs):

- `stage`: a paper left a stage — from/to stage, error code, time in stage, claims, whether private.
- `crash`: a lease expired while claimed.
- `import`: an import changed phase — phase, error code, seconds since the import was requested.

`v1_admin_pipeline_metrics(p_days)` (owner with MFA) returns, for the admin Reliability tab:

1. **Time to ready** — per day, median and 90th percentile from Add to readable.
2. **Outcomes** — per day, imports started, ready, failed, cancelled; failure rate.
3. **Failures by cause and step** — counts by import error code and by pipeline stage, plus crashes.
4. **Step durations** — median / 90th percentile per stage.
5. **Stuck now** — papers in a non-terminal stage longer than 15 minutes, with crashes and claims.

## Admin graphs

The admin **Reliability** tab (owners, 7 / 30 / 90-day window; `apps/admin/src/reliability.tsx`) draws these as inline
SVG: headline counts and failure rate, time to ready per day (gaps where nothing finished), outcomes per day with the
daily failure rate, failures by cause, crashes by step, step durations, stuck papers, and recent failures (adjacent
events for one paper and cause are grouped). Every value is also in a table. The headline median is approximate — a
median of daily medians weighted by ready imports — because the RPC returns no window-wide percentile. Development
builds render sample data with `?fixture=reliability`; production builds exclude the fixture.

## App

> **2026-10-07:** superseded for servers with migration 029 by [import progress](IMPORT_PROGRESS.md): the step in the
> reader's words, percent and time left from the server. The behaviour below remains the fallback for older servers.

Import rows show how long the current step has taken; past 3 minutes they say it is taking longer than usual and keep
Cancel available. Failed imports keep Retry.

Implemented 2026-10-06 (no wire change): the app notes when it first sees an import on a step (queued, finding,
preparing, downloading, converting, building the reader), in memory only, so a relaunch starts counting again. The
status reads "Downloading PDF…" for the first minute, then "Downloading PDF · 1 min", "· 2 min", and from 3 minutes
"Downloading PDF · Taking longer than usual" (secondary text, updated once a minute without animation; VoiceOver reads
the step and the time, e.g. "Downloading PDF, 4 minutes, taking longer than usual"). The table and detailed rows show
the same; the table's Progress column has a spinner and the step's one word, the time beneath. Cancel import and Retry import (failed, retryable) stay in the
long-press menu and are also a trailing swipe on list rows, like Remove and Archive on papers. Failure messages name
what failed: `metadata_unavailable` reads "Couldn’t get this paper’s details" and `license_unverified` "Couldn’t
confirm this paper’s license" (they read "Couldn’t import this paper" before); the other codes were already
specific. Unit tests: `LibraryMetadataTests` (injected clock); screens: `library-slow-import`,
`library-slow-import-table` (`--slow-import-fixture`).

## Self-healing downloads (migration 027)

> **Status 2026-10-07:** migration `202610070027_download_retry.sql` applied to staging; worker deployed
> (revision gradstep-pipeline-00004); the deploy's one-time retry retried 3 failed papers and healed 4 imports, and
> the owner's three failed imports (2610.03771, 2610.02287, the Zenodo paper) are now ready. Check
> `downloads.corpus` passes 13/13 against real hosts. App codes ship with the next TestFlight build. Decision:
> [DECISIONS](../DECISIONS.md#self-healing-downloads-decided-2026-10-07).

### Root causes on staging (2026-10-07, read-only)

| Import(s) | Paper | Cause | Reproduced locally | Status |
|---|---|---|---|---|
| owner, Zenodo W1572676502 | private, `failed download_failed` | Zenodo answered 406 to a PDF-only Accept; its record page needed `citation_pdf_url` | downloads (653 KB, 5–9 s) | fixed already (2026-10-07 ~04:02 UTC); needs a retry |
| synthetic, Zenodo (1) | private, `failed` | same | same | fixed already; needs a retry |
| synthetic, Zenodo (3) | private, **`done`** | same, then a later import of the same paper succeeded | — | stranded: failed imports were never re-projected → **healing** |
| owner, 2610.03771 | private, `failed download_failed` | 44.6 MB download exceeded Edge memory; failed by hand | ready in 37 s on Cloud Run | fixed already (Cloud Run); needs a retry |
| owner, 2610.02287 (`conversion_failed`) | shared, **`done`** | 49-page render exceeded Edge CPU; failed by hand; later done | — | stranded → **healing** |

No currently failed import was truly unavailable. A survey of real open-access locations from OpenAlex (~120
works, 40 sources) found these patterns, all now handled (tests in `tests/backend/download-sources.test.ts`):

| Pattern | Hosts seen | Before | Now |
|---|---|---|---|
| `citation_pdf_url` over http | PMLR, JMLR, CVF | refused (not https) | fetched over https |
| unquoted attributes | ACL Anthology | link not found | parsed |
| `citation_pdf_url` = `http://localhost:4000/…` | DSpace 7 (Aberdeen) | refused | rebased on the page's host |
| PDF in an `<iframe>` | IEEE stamp pages | no link | followed |
| browser-only PDF (proof-of-work) | PubMed Central | failed | NLM open data on S3 (`pmc-oa-opendata/PMC<id>.1/…pdf`) |
| PDF served as `text/html`, page served as `application/pdf` | various | misread | bodies sniffed (`%PDF-` / `<`) |
| sign-in round trip with a long token | Springer, HighWire | refused (> 1000 chars) | redirect hops up to 4096 chars (stored locations stay ≤ 1000) |
| incomplete TLS chain | books.nips.cc | transient (5 retries) | permanent for that location |
| bot checks (Cloudflare, AWS WAF/CloudFront, Akamai, Radware, Turnstile) | ACM, OUP, Wiley, T&F, Elsevier, Science, PNAS, ACS, SAGE, IOP, Cell, PeerJ, SSRN, eScholarship, OpenReview, IUCr, Lancet, DSpace@MIT | `download_failed` | `source_blocked`; those hosts' copies tried last |

Not fixable without a browser (and not attempted): bot checks, OpenReview's Turnstile, HighWire's access check
(genome.cshlp.org). A per-download cookie jar was tested and not needed (Springer completes without cookies;
HighWire refuses with them too).

### Locations

`downloadLocations(work)` (pipeline only; at most three, the stored limit): explicit PDFs on hosts that serve them,
then PMC copies via open data, then open repository records (landing pages that declare the PDF: Zenodo DOIs, DSpace
handles, HAL), then explicit PDFs on hosts that challenged every request. `openPDFLocations` (what Ingest calls
"openly available") is unchanged.

### Reasons readers see

| Code | When | Automatic retry | App |
|---|---|---|---|
| `download_retrying` | a retry is scheduled (entry also has `auto_retry_at`) | — | "Couldn’t download yet · Trying again automatically" / "Retrying soon" |
| `source_unavailable` | busy (429/5xx) or unreachable for 5 tries | yes | "The paper’s website isn’t responding" |
| `source_blocked` | bot check, 403/405/451 | yes | "The paper’s website blocked the download" |
| `not_pdf` | a page that declares no PDF, or a non-PDF file | yes | "The paper’s link doesn’t lead to a PDF" |
| `download_failed` | gone, refused redirect, private host, TLS, crash loop | yes | "Couldn’t download this paper" |
| `pdf_restricted` | 401/402, a password field, an IdP/login URL, paywall wording | no (Retry kept) | "This PDF needs a sign-in or subscription" |
| `too_large` | over 64 MiB / 250 pages / owner quota | no (Retry kept) | "This PDF is too large to convert" |

With several locations, transient wins (the stage retries soon); otherwise the most telling permanent reason
(too large > sign-in > blocked > no PDF > failed).

### Retry design

- **Schedule** (trigger `pipeline_auto_retry_schedule`): a paper entering `failed` with `resume_stage = download`
  and a retryable code gets `auto_retry_at` = now + 15 min / 2 h / 12 h by `auto_retries` (0/1/2); none after three.
  Leaving `failed` clears it; leaving `download` forward resets `auto_retries`.
- **Sweep** (`worker_pipeline_auto_retry`, called by the worker before each claim, at most every 20 s): due,
  unclaimed papers are locked (claims skip them); each failed, retryable, wanted import is moved back exactly as the
  reader's Retry does (phase, new `state_seq`, error cleared; the `pipeline_link_import` trigger makes the next claim
  resume the paper) but keeps its intent revision. Readers at the active-import limit: +15 min, not counted. Nobody
  waiting: schedule dropped. The same sweep **heals** failed, retryable imports whose paper is no longer failed.
- **After a deploy** (`worker_pipeline_retry_failed(label)`, called by `deploy-pipeline-worker.py deploy`, or
  `retry-failed --label`): every failed paper resumable without charge (metadata, download, render; not
  `too_large`) once per label, plus healing.
- **Projection**: `worker_pipeline_sync_imports` writes `download_retrying` and the import's `auto_retry_at` with the
  new `state_seq`; `library_import_entry` adds `auto_retry_at` only for a failed import with a schedule, so every
  other entry is byte-for-byte 019's (tested against 019's definition).
- Metrics: each automatic retry is an `import` phase change, so a retried import can count as failed more than once
  in the daily outcomes; `download_retrying` shows as its own cause.

### Verification

- `tests/database/test_download_retry.sql`: the 15 min / 2 h / 12 h ladder then the cause; no retry for paywall and
  size; Retry while scheduled; healing after another reader's import; deploy retry once per label (not for size);
  cancel drops the schedule; active-import limit postpones; crash loops scheduled; entries equal 019's otherwise;
  workers only. `tests/backend/download-sources.test.ts` and `web-source.test.ts`: every pattern above.
- Workflow check `downloads.corpus` (free `deploy` suite): 12 real locations (Zenodo record and DOI, EPrints, HAL,
  DSpace 7, PMC, PMLR, JMLR, ACL Anthology, CVF; OpenReview expected `source_blocked`; arXiv refused on the web
  path) through `fetchFirstWebPDF`, plus one arXiv-path PDF. Run locally 2026-10-07: 13/13 as expected, 28 s, 10.5 MB.

## Self-healing imports (migrations 040, 041; owner, build 17)

Owner, 2026-10-08: "we need to build maintenance and this type of cleanup into general use so these things are self
cleaning or fixing but never just sitting there." Every waiting or failed import is now either moving, visibly
waiting with a reason, or failed with a reason and an action; the server retries what can change by itself.

| Situation | What happens | Reader sees |
|---|---|---|
| Needs credits (040) | Restarted once the account's spendable balance (less restarted, unfunded needs) covers it, oldest first, skipping what does not fit; sweep before each claim, wakeup when a balance grows | "Needs credits", then progress |
| arXiv throttles the metadata lookup (040 + worker) | Atom API throttled: the record comes from arXivRaw. Both throttled: waits (Retry-After honored) for ~55 min before failing | "Waiting to continue" (step `waiting`, `reason: source_busy`) |
| Budget pause / account at its operation limit at funding | Retried every 5 min by the normal claim (034) | "Waiting to continue" at once (041) |
| Failed: details unavailable, throttled, unreachable (resume at metadata) | Retried 10 min, 30 min, 1 h, 3 h, 6 h, 12 h (041) | Its own reason + Retry (entry carries `auto_retry_at`) |
| Failed: re-render (resume at render; stored OCR, nothing charged) | Same six retries (041) | "Conversion failed" + Retry |
| Failed download (027) | 15 min, 2 h, 12 h | "Couldn't download yet · Trying again automatically" |
| Failed at a paid stage (OCR funding or submission) | No automatic retry (a failed OCR may already be billed) | Reason + Retry |
| Permanent (too large, sign-in, not open, not a PDF, invalid, license) | No automatic retry | Reason + Retry where it can help, supply the PDF when not open, Remove |
| A non-paid stage unchanged for 6 h while someone waits (silent loop) | Failed with the stage's code by `worker_pipeline_heal`, then the retries above | Reason + Retry |
| Retryable failure without a schedule (before 041, e.g. 2610.07426) | Scheduled at once by `worker_pipeline_heal` (and by 041 itself) | Retried |
| Expired claim | 022's crash sweep before each claim | — |

Retries are 027's restart (the reader's Retry as a worker checkpoint): the normal claim, funding, credit checks and
spending admission run for the paper the reader asked for; nothing paid is retried automatically. After the last
automatic retry a failure stays in the library with its reason and actions; nothing is removed on the reader's behalf.

`worker_pipeline_heal` (worker, before each claim, at most once a minute) locks only unclaimed paper rows (SKIP LOCKED)
and then the policy throttle row. `pipeline.stuck` measures imports from their last change (`progress_at`), reports
deliberate waits (`service_paused`, `storage_full`) apart, and fails when a retryable failure has no schedule or an
automatic retry is 15 minutes overdue. Idle shared `private_split` rows (no import waits on them) stay as they are:
they do no work. Tests: `test_resume_credits.sql`, `test_source_waits.sql`, `test_self_healing.sql`,
`credit_resume_concurrency.py`.

## Verification

- Database tests: crash sweep, three-crash failure per stage, backoff, provider stages never auto-fail, counters
  reset on stage change, events and metrics, owner-only access.
- Worker: Node tests of the server entry (secret check, one paper per call, deadline), and a large-PDF download test.
- Live: re-run both failed papers on staging through Cloud Run; a daily canary import feeds the graphs.
- Continuous: [workflow checks](WORKFLOW_CHECKS.md) — after every deploy and on a schedule: the Vault URL is the
  Cloud Run worker, nothing is stuck or crash-looping, and imports (including the 44.6 MB and 49-page papers,
  weekly) reach ready within limits. 2026-10-07: 2610.03771 ready in 37 s on Cloud Run.

## arXiv OAI identifier encoding — 2026-10-15

The metadata stage asks OAI-PMH for `GetRecord` with `identifier=oai:arXiv.org:<id>`. Built through `URLSearchParams`
the colons were percent-encoded; on 2026-10-14 arXiv's OAI server stopped answering that form (the connection stays
open until the worker's 60 s timeout; `source_unavailable`; retried on backoff up to ten times), while the literal
form answers in a quarter second. `arxivURLs` now writes the query by hand with literal colons (the id is validated
before). The worker's `metadata_error` log names the endpoint and the HTTP status or the failure name, so the next
such change is read off the log instead of reproduced by hand. Reproduction that found it: the worker image run
locally against staging (`deploy-pipeline-worker.py build` then `run`, kicked at `POST /run` with the pipeline
secret) failed identically, which ruled out Cloud Run's network; the exact request inside the image then timed out
only in its encoded form.

## Idle metadata in Health — 2026-10-18

The hosted check flagged arXiv 2406.09246 as stuck for 29 hours, with zero claims. Readback showed no attached
imports and `pipeline_interest=false`: the worker correctly ignores an orphan, but the health snapshot still
counted it as active work. The observation contract now separates unclaimed metadata with no interested reader
into `resting_metadata`. Claimed rows and metadata needed by a live import stay in stuck/crash detection. No
paper, membership, import state or billing record is rewritten. Migration 090 and an isolated regression verify
the idle case alongside genuinely stalled and claimed cases.

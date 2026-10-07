# Paper import reliability

> **Status 2026-10-06 20:10 PDT:** migrations 022/023 applied to staging; worker deployed to Cloud Run
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

### Spending-control hardening (2026-10-07, implementation branch; not deployed)

Use request-based Cloud Run billing only with a bounded, awaited request lifecycle. The HTTP process will run
each pipeline invocation in a Node worker thread, await its result, and terminate/join the thread before replying.
A hard 840-second limit leaves 60 seconds before Cloud Run's 900-second request timeout. A timeout is a failure;
it must not settle an unknown provider submission as free, release a still-uncertain liability, or start a retry.
Existing durable provider grants and fenced queue leases allow later reconciliation. Each instance admits one
run; health checks, invalid methods, unauthorized requests and overlapping wakeups do not create another thread.
This boundary also covers account-deletion and tag projection loops, whose per-request network timeouts did not
previously establish an overall run limit. Expensive renderer imports live in the worker, not the HTTP process.

Deployment will explicitly select `--cpu-throttling`, zero minimum instances, and a maximum of three at both
service and revision scope, then read back the configuration. The one-minute scheduler remains a recovery wakeup;
it is not permission to run outside the HTTP request. The pg_net wakeup callers have short client deadlines, and
their timeout does not establish that a pipeline run failed. Google documents that HTTP/1.1 client disconnects
are not propagated to the container; the server still awaits the run. Cloud Run's own timeout is the upper bound
that must be avoided. Any future HTTP/2, streaming-response, detached-task or periodic-background change requires
rechecking this lifecycle before rollout. No claim of free hosting follows from choosing request-based billing.
[Billing settings](https://docs.cloud.google.com/run/docs/configuring/billing-settings),
[request timeout](https://docs.cloud.google.com/run/docs/configuring/request-timeout),
[client disconnect behavior](https://docs.cloud.google.com/run/docs/troubleshooting#client-disconnect).

The first deployment must wait for the spending-control backend changes that preserve uncertain provider and
upload liability. Record the new revision, billing mode, limits, timeout and measured allocation after cutover.
No live change has been made by this implementation branch.

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
  billable instance-hours in a 24-hour window; no invoice was retrieved. Request-based billing is implemented on
  the spending-controls branch and still needs a coordinated cutover and measured follow-up. See
  [operations](OPERATIONS_AND_BILLING.md#fixed-commitments) for the unchanged budget and fixed commitments.

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

## Verification

- Database tests: crash sweep, three-crash failure per stage, backoff, provider stages never auto-fail, counters
  reset on stage change, events and metrics, owner-only access.
- Worker: Node tests of the server entry (secret check, one paper per call, deadline), and a large-PDF download test.
- Live: re-run both failed papers on staging through Cloud Run; a daily canary import feeds the graphs.
- Continuous: [workflow checks](WORKFLOW_CHECKS.md) — after every deploy and on a schedule: the Vault URL is the
  Cloud Run worker, nothing is stuck or crash-looping, and imports (including the 44.6 MB and 49-page papers,
  weekly) reach ready within limits. 2026-10-07: 2610.03771 ready in 37 s on Cloud Run.

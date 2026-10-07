# Paper import reliability

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

- **Supabase stays the system of record and the queue.** `pipeline_papers` rows with fenced leases are the queue;
  pg_cron + pg_net call the worker every minute with the pipeline secret, as today.
- **The worker moves to Cloud Run** (`gradstep-pipeline`): the same `runPipeline` code under Node 24 (the shared
  modules already run under Node in tests), 2 GiB memory, 1 vCPU, concurrency 1, up to 3 instances, 900 s request
  timeout, scale to zero. Secrets come from Secret Manager. It also runs the account-deletion sweep. The Vault URL
  `science_reader_pipeline_url` is switched to the service; the Edge `paper-worker` stays deployed but unscheduled
  until the cutover is verified, then is deleted.
- **Downloads hold one copy.** The PDF is read into one buffer sized from `content-length` (bounded by the policy's
  maximum), hashed and counted from that buffer, and uploaded from it.
- **Cost:** within Cloud Run's free tier at beta volume (estimate $0–2/month); recorded in
  [operations](OPERATIONS_AND_BILLING.md#fixed-commitments) once billed.

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

## App

Import rows show how long the current step has taken; past 3 minutes they say it is taking longer than usual and keep
Cancel available. Failed imports keep Retry.

Implemented 2026-10-06 (no wire change): the app notes when it first sees an import on a step (queued, finding,
preparing, downloading, converting, building the reader), in memory only, so a relaunch starts counting again. The
status reads "Downloading PDF…" for the first minute, then "Downloading PDF · 1 min", "· 2 min", and from 3 minutes
"Downloading PDF · Taking longer than usual" (secondary text, updated once a minute without animation; VoiceOver reads
the step and the time, e.g. "Downloading PDF, 4 minutes, taking longer than usual"). The table and detailed rows show
the same, the table's Status column on two lines. Cancel import and Retry import (failed, retryable) stay in the
long-press menu and are also a trailing swipe on list rows, like Remove and Archive on papers. Failure messages name
what failed: `metadata_unavailable` reads "Couldn’t get this paper’s details" and `license_unverified` "Couldn’t
confirm this paper’s license" (they read "Couldn’t import this paper" before); the other codes were already
specific. Unit tests: `LibraryMetadataTests` (injected clock); screens: `library-slow-import`,
`library-slow-import-table` (`--slow-import-fixture`).

## Verification

- Database tests: crash sweep, three-crash failure per stage, backoff, provider stages never auto-fail, counters
  reset on stage change, events and metrics, owner-only access.
- Worker: Node tests of the server entry (secret check, one paper per call, deadline), and a large-PDF download test.
- Live: re-run both failed papers on staging through Cloud Run; a daily canary import feeds the graphs.

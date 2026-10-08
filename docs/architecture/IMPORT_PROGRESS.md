# Import progress

> **Status 2026-10-07:** implemented locally (migration 029, worker reports, app); database, backend, Core and app
> unit tests pass; Simulator screens reviewed. **Not applied to staging and the worker is not redeployed** (the main
> session does both). Until 029 is applied, apps show the previous step-and-timer status.

Owner, 2026-10-07: "when items are processing, we should have a better UX, ideally, we have an estimate of the total
time, and have a percent done, with stages that make more sense to the user (What does 'Converting...' mean?) What is
a reader to the user? Think about this from users POV." Decisions: [DECISIONS](../DECISIONS.md#import-progress-owner-asked-2026-10-07).

## What the reader sees

An import row says what is happening, how far along it is and roughly how long is left:

```
Reading equations and figures (page 12 of 27)
▬▬▬▬▬▬▬▭▭▭  62% · About 40 s left  ⓘ
```

| Pipeline stage(s) | Step | Extra |
|---|---|---|
| (not started; offline queue) | Waiting to start | |
| `metadata` (and the private split) | Finding the paper | |
| `download` | Downloading the PDF | size, once known: "(40.8 MB)" |
| `ocr_fund`, `ocr_submit`, `ocr_wait` | Reading equations and figures | "(page 12 of 27)", or "(27 pages)" |
| `render`, `done` | Preparing it for reading | |
| paused by the platform budget | Waiting to continue | |
| failed download the server will retry (027) | Couldn't download yet | "Trying again automatically" |
| failed metadata or free re-render the server will retry (041) | The failure's plain-language reason | "Trying again automatically" |

Time: "A few seconds left", "About 40 s left" (5 s steps under 30 s, then 10 s), "About a minute left", "About 3 min
left", "Almost done" once the estimate runs out, "Taking longer than usual" when the server says it is backing off or
paused, or the estimate is well past (twice it, at least 30 s more). Before the page count is known the estimate is for
a typical paper and is said loosely: "Usually under a minute" / "Usually about a minute" — no count-down. VoiceOver
reads one sentence ("Reading equations and figures, page 12 of 27, 62 percent, about 40 seconds left"); the info button
is its own element ("Why does this take a minute?") and opens a medium sheet, **Getting a paper ready**, that explains
the four steps once. The readable result is called "a readable version" there; rows don't need a noun ("Preparing it
for reading"). No row says converting, rendering, reader or bundle.

The bar is neutral (secondary), slim (4 pt) and 96 pt wide beside the status in rows; the accent bar stays the reading
progress of papers. Older servers (no detail) keep the spinner and "Downloading the PDF · 2 min" timer of 2026-10-06.

## Wire

Active import entries carry a top-level `progress_detail`:

```json
"progress_detail": {"step": "reading_equations", "percent": 62, "eta_seconds": 40, "pages_done": 12, "pages": 27}
```

- `step`: `finding` | `downloading` | `reading_equations` | `preparing` | `waiting` (unknown values: clients fall back
  to the coarse `progress`).
- `percent`: 0–99; never lower than the import's previous detail within an attempt (intent revision).
- `eta_seconds`: seconds left, only when the estimate can be trusted; otherwise `"delayed": true` (backing off after
  errors or crashes, budget pause, `ocr_uncertain`, more than 60 s until the next attempt, or 3× the stage's usual time
  plus a minute).
- `pages` (being read: the paper's pages up to the OCR cap), `pages_done` (provider progress during OCR), `bytes`
  (during download). Absent until known. **Without `pages` the estimate is for a typical paper.**

Stored in `import_requests.progress_detail` and written only with a new `state_seq` (trigger
`import_progress_stamp`, on insert and every `state_seq` change), so an entry's JSON at a given `state_seq` never
changes; finished imports and entries without a stored detail are byte-identical to before (`library_import_entry_base`
is the earlier entry function, kept and extended — it composes with 027's `auto_retry_at`). Clients before this ignore
the key; the app decodes it leniently (bad values dropped, never a rejected entry).

## Estimate (server)

`app_private.pipeline_estimate(paper)`: each stage's expected time from `pipeline_events` (median of the last 30 days,
at least 5 successful exits; `pipeline_measure_timing`, cached 15 min in `pipeline_timing`), else defaults from the
2026-10-07 staging canary (metadata 5 s, download 6 s, fund 1.5 s, submit 3 s, OCR 5 s + 0.8 s/page, render 3 s +
0.3 s/page, done 1.5 s; typical paper 20 pages, or the 30-day median). OCR and render scale with the pages being read.

- Percent = (expected time of finished stages + the current stage's fraction × its expected time) / total. The
  fraction is time-based (capped at 0.9); during OCR at least 0.85 × the provider's pages done / pages.
- Time left = the current stage's remainder (at least 10 % of it) + later stages. During OCR, once a quarter of the
  pages are done, the remainder follows the provider's observed rate (elapsed × (1 − f) / f + 3 s).
- A paper waiting to restart (retry, split) counts from the start of that stage.

## Updates and throttling

- **Stage changes** already project with a new `state_seq` (`worker_pipeline_sync_imports`, library-write rate); the
  trigger recomputes the detail then.
- **Between stages** the worker calls `worker_pipeline_progress(paper, claim, generation, pages_done, pages, bytes)`:
  during OCR polling (provider `num_pages_completed` / `num_pages`) and after a download (size and pages). The worker
  sends at most one report per 5 s, starting 5 s after the stage's projection; a failed report is logged, never
  affects the stage.
- The RPC records the observation (`pipeline_observations`, without locking the paper row) and re-projects an import
  only if its last detail is ≥ 5 s old **and** the reader would see something new: a different step, page count,
  pages done, size or delay, or an estimate that drifted from the client's own count-down (clients move the bar as
  `percent + (99 − percent) × min(1, t / eta)` and count `eta − t` down from receipt; the server re-sends when its new
  estimate differs by ≥ max(10 s, 25 %) or ≥ 5 points). Each projection spends the per-account `library-progress`
  rate (720/hour, 6,000/hour environment), separate from library writes; over it, the projection is skipped silently.
- Journal cost: an import adds roughly one entry per 5 s during OCR on top of its ~6 stage entries.

## App

- `ScienceReaderCore.LibraryImportProgressDetail` (wire), `LibraryImportRecord.progressDetail`.
- `ImportProgress` / `ImportProgressPresentation` / `ImportTimeLeft` / `ImportProgressTracker`
  (`Services/ImportProgress.swift`): pure; the tracker remembers when each detail arrived and the highest percent shown
  (in memory only; a retry starts again).
- `ImportProgressView` (`Views/ImportProgressView.swift`): `ImportProgressView(progress:style:explain:)`, styles
  `.row` and `.compact` (a ~100 pt table column: "Reading 62%", the bar, "40 s left"); `ImportProgressBar`,
  `ImportProgressInfoButton`, `ImportProgressExplainer` (presented by `model.showImportHelp = true`).
- `LibraryRowFacts.importProgress` and `ReaderModel.importProgress(for:)` give the table what it needs; List rows
  use the view now. The Library keeps polling while any failed import has a server retry scheduled. Such rows count
  as underway rather than Failed and do not offer a competing Retry button. A scheduled retry has no percentage or
  countdown; passing its time does not authorize the client to restart work.
- `LibraryImportRecord.autoRetryAt` decodes optional `auto_retry_at` leniently, preserving older servers and dropping
  malformed timestamps without rejecting the library. Download failures also retain the older `download_retrying`
  fallback. Metadata/re-render retries keep their actual failure reason instead of saying the PDF download failed.
  Presentation checkpoint format 5 forces one fresh snapshot after an app upgrade: older offline rows remain readable
  but cannot seed a replica missing this newly decoded field at the same server sequence. The repair whitelist adds
  only this presentation field; identity and artifact pins remain strict.
- Tests: `ImportProgressTests` (app), `ImportProgressWireTests` (Core). Screens: `library-import-progress`,
  `library-import-progress-help`, `library-import-progress-table` (`--import-progress-fixture`).

## Verification

- `tests/database/test_progress.sql`: new import (typical estimate), each stage, fencing and validation, the 5 s
  throttle, "no news, no write", provider pages for two readers, the progress rate, stage changes over that rate,
  monotonic percent when the page count grows, delay and budget pause, retry resets, ready/failed entries identical to
  the earlier entry, the news rule, measured medians, the profile cache; every projection matches the journal at its
  `state_seq`.
- `tests/backend/pipeline.test.ts`: reports every ≥ 5 s during OCR polling, a failed report never touches the stage,
  slow vs quick downloads.
- Not yet: a live staging import after 029 is applied (the estimate's defaults are from one canary; the medians take
  over after 5 imports per stage).

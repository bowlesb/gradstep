# Workflow checks

> **Status 2026-10-07:** runner `scripts/workflow-checks.mjs` built and run against staging (results below);
> deploy hooks added to `deploy-staging.py` and `deploy-pipeline-worker.py`; migration
> `202610070024_workflow_checks.sql` written and tested locally, **not applied**; Cloud Scheduler jobs
> written (`scripts/schedule-workflow-checks.py`), **not created**.

Owner, 2026-10-07: "we need better integration tests … to catch these things proactively … if they don't work,
users will abandon immediately … it needs to be bulletproof."

The checks exercise what a tester does — add a paper, read it, ask, Add paper from a reference, Related, archive,
buy credits — through the **same endpoints the app uses** (`v2_begin_import`, `v3_library_page/changes`,
`reader-artifact`, `chat` with the app's exact request bodies, `store-sync`), with disposable synthetic accounts.
Configuration guards cover what a deploy or a console change can silently break. Every check has a timeout and a
one-line reason a person can act on.

## What is checked

| Check | Proves | Would have caught (2026-10-06/07) | Suites | Provider cost |
|---|---|---|---|---|
| `config.pipeline-url` | Vault `science_reader_pipeline_url` = `infra/staging.json` `pipeline_worker_url` (Cloud Run) | deploy script re-pointing the pipeline at the retired Edge worker | all | 0 |
| `config.worker-endpoint` | worker `/health` 200; POST without / with a wrong secret → 401 | worker down or open | all | 0 |
| `config.worker-calls` | pg_cron job active, on the infra schedule; pg_net calls in the last 15 min reached it (2xx, none refused) | secret mismatch, cron off, worker URL dead | all | 0 |
| `config.pipeline-secret` | Vault secret = `.env.staging` `PIPELINE_SECRET` (SHA-256 compared) | half-applied rotation | all | 0 |
| `config.edge-functions` | every infra function deployed and ACTIVE | failed deploy | all | 0 |
| `config.function-secrets` | required secret **names** exist; web-search switch = infra | missing key after a project change | all | 0 |
| `config.pipeline-budget` | pipeline enabled; this month's platform budget exists, is enabled, has headroom (fail < $0.50, warn < 25%) | paid work silently paused | all | 0 |
| `pipeline.stuck` | no paper in a working stage > 15 min, no crash loop, no uncertain OCR, no import unresolved > 1 h; warns on crashes or ≥ 5 failures of one cause in 24 h | the silent infinite loops | all | 0 |
| `downloads.corpus` | 12 real open-access locations (Zenodo record/DOI, EPrints, HAL, DSpace 7, PubMed Central, PMLR, JMLR, ACL Anthology, CVF; OpenReview → `source_blocked`; arXiv refused on the web path) download through the pipeline's `fetchFirstWebPDF` (DNS checks on; nothing stored), plus one arXiv-path PDF; a deterministic change fails, a busy host warns (2026-10-07: 13/13, 28 s) | landing-page and host-pattern regressions (the Zenodo 406, http/unquoted `citation_pdf_url`) | all | 0 |
| `auth.providers` / `auth.google` / `auth.email-delivery` | Apple and email on; Google on (the app shows "Continue with Google"); sender domain verified in Resend, signups state | Google never enabled; test sender; invite-only codes | daily, weekly | 0 |
| `store.app-price` / `store.products` | app price schedule and availability; the three products at READY_TO_SUBMIT or later | Get credits empty (no price; MISSING_METADATA) | daily, weekly | 0 |
| `import.arxiv` | add DPO (shared conversion) → ready; reader bundle downloaded and every member's SHA-256 verified; time to ready | worker/trigger/sync broken | all | 0 |
| `library.sync` | archive, unarchive, remove, re-add each applied once (replays identical) and visible in `v3_library_changes`; stale revision → `revision_conflict` | sync regressions | all | 0 |
| `credits.store` | balance and plan readable; `store-sync` refuses forged and Xcode transactions; notifications refuse unsigned | store endpoints down | all | 0 |
| `chat.smoke` | general answer streams, ends with `done`, settles | chat down | daily, weekly (+deploy when `chat` is deployed) | ≈ $0.005 |
| `chat.paper` | paper answer (Mistral 7B, 9 pages, shared; `--paper=<arXiv id>` to change) streams and ends with `done`; first-text and total time | paper context broken | daily, weekly | ≈ $0.04 |
| `chat.related` | Related answer has ≥ 2 links (Sources) | web search returning 0 sources | daily, weekly | ≤ $0.18 (35 credits; Tavily is prepaid) |
| `ingest.*` (7) | Add paper ends with a clear outcome line of the expected kind and paper; a "Queued" line has a new import; find step under budget (warn > 30 s) | silent end; extra-key rejection; find over 45 s; Zenodo landing page | daily, weekly (+deploy: `not-found`) | ≈ $0.005–0.02 each |
| `ingest.imports-ready` | papers queued above reach ready and their bundles verify (PaLM, CoT shared; Zenodo private, 4 pages) | downloads that always fail | daily, weekly | ≈ $0.02 |
| `import.large-pdf` | 2610.03771 (44.6 MB PDF, 26 pages, private) → ready ≤ 25 min | the 45 MB download loop | weekly | ≈ $0.13 |
| `import.long-paper` | 2610.02287 (49 pages, shared) → ready, 49-page bundle verified | — (render not re-exercised: shared conversion reused) | weekly | 0 |

The Add paper corpus: PaLM by arXiv id from DPO's bibliography, Adam by title only, the Zenodo case (Gepshtein
et al., EUSIPCO 2004), Dropout (JMLR), a closed paper (AlphaGo, *Nature* 2016 → "isn't openly available"), a
nonexistent paper (→ "couldn't find"), and a Chain-of-Thought reference full of venue/editor/page/DOI fields. Four
run in paper chat. Private OCR (Adam 15 pages, Dropout 30) is cancelled at once except in the weekly suite.

While an import is awaited, a step that does not move for 7 min (20 min while converting) fails immediately as
"stuck in <step>", and a `crash` event for that paper fails it as "the worker died in <stage>" — the loop shows up
in minutes, not at the timeout.

## Suites, schedule and cost

| Suite | When | Provider spend | Runtime |
|---|---|---|---|
| `deploy` | end of every `deploy-staging.py` / `deploy-pipeline-worker.py` run (opt out: `--skip-checks`); every 6 h as a canary | 0 (≈ $0.01 when `chat` was deployed) | ≈ 30 s |
| `daily` | 14:00 UTC, Monday–Saturday | measured ≈ $0.27 per run (first run) | ≈ 4 min |
| `weekly` | Sundays 15:00 UTC | ≈ $0.63 (daily + large PDF $0.13 + Adam/Dropout to ready $0.23) | ≈ 6 min |

Monthly ≈ $9.50 (26 × $0.27 + 4 × $0.63) plus cents for chat deploys. **That does not fit the current staging
provider cap** ($9.80 for October, $1.38 left on 2026-10-07): it needs the owner's decision on November's cap, or
the paid daily suite on fewer days (`schedule-workflow-checks.py --daily-days=1,3,5` ≈ $6/month). The free
6-hourly canary keeps catching loops, configuration drift and broken imports either way. Nothing here raises a
budget.

Spending is bounded three ways: (1) each paid check declares an estimate and is skipped once the run's credits ×
$0.005 plus the estimate would pass the cap (`--cap-usd`, defaults $0.05 / $0.50 / $1.00); (2) a paid check is
skipped if it would take the platform budget below a $0.50 reserve, so testers keep paid features; (3) the
synthetic accounts' credit grants (60 / 200 / 150) bound what the server lets them spend. Credits × $0.005 is an
upper bound of provider spend (chat credits are ⌈µ$ / 5,000⌉; Tavily searches are priced but prepaid); with a
management token the runner also reports the settled spend from `metered_operations`.

Real App Store purchases, Apple/Google sign-in pages, email arriving in an inbox and the physical iPhone are
not automated (the store check proves the products are purchasable in sandbox and the endpoints refuse forgeries).

## How failures surface

- **Terminal**: a table (check, result, time, cost, reason) and `.artifacts/workflow-checks/<timestamp>.json`
  (secrets and tokens redacted; no emails or account IDs). Exit code 1 on any failure.
- **Deploys**: the deploy scripts end with "Deployed, but workflow checks FAILED" and exit non-zero.
- **Admin Reliability tab** (after migration 024): `--record` stores each run (`worker_record_workflow_check_run`,
  service role, idempotent per run ID); `v1_admin_workflow_checks(p_days)` (owner with MFA) returns the last run per
  suite, recent runs, and per check its latest status/reason, history and counts. The tab needs a small panel
  reading it ("Workflow checks: last run, pass/fail per check") — not built here.
- **Owner email**: scheduled runs pass `--notify`; failures are emailed through Resend (verified `gradstep.ai`
  sender) to `WORKFLOW_ALERT_EMAIL`. Unset → no email.
- **Known, accepted failures**: `infra/workflow-checks.json` `{"acknowledged": {"<check>": {"reason": "…", "until":
  "YYYY-MM-DD"}}}` reports that check as a warning until the date, then as a failure again. None are acknowledged.

## Accounts, data and secrets

Each run creates `gradstep-check-<label>-<uuid>@example.invalid` users with the service role, signs in with the
password grant, and grants credits with `worker_grant_credits` (`operator:workflow-check:<id>`). At the end each
is deleted **through `account-delete`**, as a user would (personal rows and private files removed; ledger rows
kept de-identified, per the deletion decision); pending imports are cancelled first and `account_busy` is retried
for 3 min. Accounts left by interrupted runs (> 6 h old) are closed with `worker_delete_account_begin` and finished
by the worker's deletion sweep. `--keep-accounts` keeps them for inspection.

Secrets come from the environment or `.env.staging` / `.env.providers` / `.env.appstore` (a git worktree reads the
main checkout's) and the keychain ("Supabase CLI"). They never appear in output: every secret value, password and
access token is redacted from logs and the report. The project ref is asserted (staging only).

Without a management token (the Cloud Run job) the runner reads `worker_workflow_snapshot()` (migration 024) and
public endpoints; `config.function-secrets`, the email sender check, the ingest find timings and the crash watch
are skipped. Before 024 is applied it runs the same snapshot query through the Management API.

## Scheduling

`python3 scripts/schedule-workflow-checks.py plan` prints, and `apply` creates, in Google Cloud project `gradstep`
(us-west1): a runtime service account that can read only its five secrets (three already exist for the pipeline
worker; the anon key and Resend key are added), a Cloud Run job from `services/workflow-checks/Dockerfile` (Node 24,
512 MiB, 45 min, **no retries** so a paid check never re-runs by itself), and three Cloud Scheduler HTTP jobs
calling the Jobs API `:run` with argument overrides, through a scheduler identity holding only
`roles/run.jobsExecutorWithOverrides` on that job. Cost: within the Cloud Run and Scheduler free tiers (three jobs).

## Adding a check

```js
check('library.example', { title: 'What the user would notice', suites: ['daily', 'weekly'], timeout: 120, costUSD: 0.01 },
  async ({ signal }) => {
    const acct = await account('library', 60);           // synthetic account, deleted at the end
    const r = await acct.rpc('v3_library_page', { p_limit: 10 }, signal);
    return r.entries ? pass('…what was proven…', { some_metric: 1 }) : fail('…what is broken for the user…');
  });
```

Rules: go through the endpoint the app uses, with the app's request shape; name the incident it would catch;
bound its time (`timeout`, `signal`) and its cost (`costUSD`, credit grant); prefer shared conversions (no OCR);
clean up what the schema allows; reasons are one line saying what a user would hit. Run it alone with
`--only=<id>`; `--list` shows the catalog.

## First run (staging, 2026-10-07 04:27 UTC)

`--suite=daily --also=import.large-pdf,import.long-paper`: **24 passed, 3 failed, 3 warnings**; measured provider
spend **$0.40** settled (credits bound $0.46), of which $0.13 is the large PDF's OCR. Report
`.artifacts/workflow-checks/2026-10-07T04-27-46-128Z.json`.

| Result | Check | Finding |
|---|---|---|
| FAIL | `ingest.not-found` | A paper that doesn't exist exhausts the 45 s find budget (45,001 ms, twice) and the reader is told "I couldn't search for … right now" instead of "couldn't find". `provider_usage_events` (provider `ingest`): every closed or unmatched lookup today took 24–45 s (closed 24.0, 39.6, 40.9 s; one web add 40.7 s; not-found 45.0 s ×2); matched ones take 0.2–0.8 s. The slow path is the paced arXiv title search plus the Tavily fallback after OpenAlex finds nothing. Product bug in `chat/index.ts` `findPaper`. |
| FAIL | `store.products` | Standard and Pro monthly are MISSING_METADATA (the 400-credit pack is READY_TO_SUBMIT): Get credits cannot offer plans. |
| FAIL | `auth.google` | Supabase Auth's Google provider is off while the app shows "Continue with Google". |
| WARN | `config.pipeline-budget` | $1.38 of $9.80 left for October (86% used). |
| WARN | `pipeline.stuck` | Nothing stuck; 10 imports failed `download_failed` in 24 h (tonight's incidents). 22 shared `private_split` rows were left out: they rest there by design, but `v1_admin_pipeline_metrics` lists them as **stuck** on the admin Reliability tab (false positives that would hide a real one). |
| WARN | `auth.email-delivery` | Sender `@gradstep.ai` is verified in Resend; signups are disabled, so an address without an account gets no code (invite-only, as decided). |
| PASS | `import.large-pdf` | 2610.03771 (44.6 MB, 26 pages, private) ready in 37 s on Cloud Run: download 5 s, OCR 21 s, render 10 s. |
| PASS | `ingest.*` (6) | PaLM, Adam, Zenodo (the landing-page case), Dropout, AlphaGo (closed, but 39.6 s) and the Chain-of-Thought reference all ended with the right outcome line; PaLM, Zenodo and CoT became readable. |

## Simulator journeys

`LiveJourneyTests` runs against staging with a synthetic account from `scripts/live-journey.mjs` (`--derived=<path>`
sets DerivedData). Existing: add a paper → convert → download → read → ask → relaunch; delete account (which only
*records* the products shown). Added 2026-10-07:

- `testGetCreditsListsEveryProduct` (`--store`): Settings › Get credits must list Pro, Standard and 400 Credits.
  Free. Depends on the Simulator reaching the StoreKit sandbox; `store.products` checks the same states directly.
- `testReferenceAddToLibraryImportsThePaper` (`--reference=11:PaLM`): DPO → Introduction → citation 11 → its
  reference → Add to library → consent → the answer says "Queued …PaLM…" → the Library row becomes readable and
  opens. About $0.10 (one Add paper answer on a 27-page paper; PaLM is shared).

Proposed next (fixture-free, staging): **selection actions** — select a passage, run Explain, Why it matters and
Related, each must end with an answer (Related with tappable sources); and **Add paper from a selection** for a web
paper (Zenodo), checking the import row's step and time text until ready. Selection reachability itself is already
covered with fixtures (`testTouchTextSelectionKeepsEveryActionReachable`).

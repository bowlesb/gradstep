# Resilience: a failing response costs one feature, never the app

**Status, 2026-10-15: server side built and deployed to staging (fixes 4, 5 and 7, server `retry_after`, fault
switches and the drill script; [as built](#server-side-as-built)); the first fault drill (Anthropic throttled on chat)
passed 8 of 8 on staging. Client side built (below). **2026-10-16: fix 1 (contain overruns) and the failed-answer
decision are built and deployed to staging (migration 079, chat function; [as built](#fix-1-and-early-endings-as-built--2026-10-16));
four live drills passed.** Owner: "I don't want the entire app to break if a response starts failing; we need to think
and plan carefully there."

**Built on the clients (2026-10-15):**
- **Browser:** an error boundary per region (reader, chat, library, feed, Listen, side panel, player, dialogs) with "…
  hit a problem · Try again · Report it", a last-resort app boundary and `error`/`unhandledrejection` handlers that
  record a code, never content (`lib/faults.ts`; reports carry the last two). Launch retries `v1_key_state` by itself
  (1, 2, 4 s… up to a minute, jittered, the server's wait honoured) behind "Can't reach Gradstep · Trying again in N s ·
  Try now" (fix 2, fix 3 except the last-session library). Library polls jitter while healthy and back off while
  failing (fix 8). A 429 without a specific code is `throttled` and carries `Retry-After`/`retry_after` (fix 9).
  Last-good, said "as of": the episode list and the credit balance (the feed already kept its page; chat profiles
  keep their table).
- **Apple apps:** `BackendError.throttled(retryAfter:)` for 429s without a specific code (fix 9); RPCs on their own
  session bounded at 180 s, streams and downloads at 15 minutes (fix 11); a chat answer silent for 100 s ends as
  interrupted (`IdleBoundedChatTransport`); first-device setup that can't reach Gradstep says so, retries by itself
  and never opens the recovery sheet (fix 6); the import poll and sync jitter and back off, honouring the server's
  wait (fix 8); last-good, said "as of": the feed page, the episode list and the credit balance (fix 10).
- **Fault fixtures:** native `--chat-fixture-mode=throttled|overloaded|stall`, `--chat-idle-deadline=`,
  `--backend-fault=<path>:<status>|timeout|malformed`, `--podcast-fixture-catalog-fault=always|after-first`,
  `--feed-fixture-fault`; browser `POST /__fault {path, kind, times}` on the e2e fixture backend. Journeys:
  `ResilienceJourneyTests` (8) and `e2e/resilience.spec.ts` (5 × desktop, phone, tablet, tablet-large).
- **Not yet:** the browser's last-session library while offline needs the browser to reopen its keys without the
  server (native does, from its cached device); that is a key-handling change for review, not a quiet addition.

Scope: every external dependency and our own backend paths, on every surface — the shared Swift app (iPhone, iPad,
Mac), the browser app, Edge functions, the Cloud Run worker and the admin. Findings cite `file:line` at `ef81285`.
Related: [ADMIN_HEALTH.md](ADMIN_HEALTH.md), [ARXIV_DEVICE_ONLY.md](ARXIV_DEVICE_ONLY.md),
[DATA_HANDLING_AND_COSTS.md](DATA_HANDLING_AND_COSTS.md).

## Summary

The native app is already offline-first where it matters most: a signed-in device opens its library and its
downloaded papers from local storage before any request (`ReaderModel.swift:1590-1602`), opening a paper talks only
to arXiv and the local store (`ReaderModel.swift:2596-2680`), chat failures are per answer with specific wording
(`ChatStream.swift:398-417`), and sync backs off to five minutes (`ReaderModel.swift:3802-3804`). Most single-provider
outages therefore already degrade one feature.

Five couplings break more than one feature:

1. **One operation's overrun pauses all paid work for everyone** (fixed 2026-10-16, migration 079: now a recorded
   `budget_anomaly`; [as built](#fix-1-and-early-endings-as-built--2026-10-16)). Settlement set the month's `work_enabled=false`
   when a single operation's actual or uncertain provider cost exceeds its ceiling
   (`202610070034_provider_accounting.sql:289-291`, `:348`). Chat, Study, the equation view and podcasts then answer
   "AI answers are paused right now" for every account until an operator resumes it — the message the owner saw on
   build 38. A pricing estimate bug or a provider's late usage report becomes a platform-wide outage.
2. **The browser app has no error boundary.** `apps/web/src/main.tsx:8` renders the whole tree with no
   `ErrorBoundary` and no `error`/`unhandledrejection` handler; a render-time exception from one malformed response
   (any panel) blanks the entire page.
3. **The browser waits on the server at every launch.** `App.tsx:83` shows nothing but `KeySetup` until
   `prepare()` (`lib/keys.ts:176-184`) has fetched `v1_key_state`; a Supabase blip at launch blocks reading,
   the library and chat alike, with one manual "Try again".
4. **Search shares one platform-wide arXiv slot.** `discover/index.ts:106-111` reserves `worker_pipeline_arxiv_slot`
   (one arXiv request every 3 s for all users and imports together); under load it returns `503 search_busy`, and
   OpenAlex keyless usage caps ranking at about 50 searches a day (`discover/index.ts:93-100`). Being replaced
   (ARXIV_DEVICE_ONLY.md step 4).
5. **Transient provider throttling fails an episode for good.** A pre-processing 429 from Anthropic, DeepSeek or
   Google becomes `script_rejected`/`speech_rejected` (`podcast-script.ts:322`, `podcast-speech.ts:249-251`,
   `podcast-worker.ts:291-292`, `:539-540`) and `worker_podcast_fail` settles the job as `failed`
   (`202610080048_paper_podcasts.sql:1913-1925`) — no requeue. (The reader is not charged; the episode just fails.)

And one gap makes all of it hard to see: provider throttling and errors are not recorded anywhere the admin reads.
A chat 429 before the first token leaves no durable row (`chat.ts:1069` returns early without attempts); podcast
failures appear only as job failure codes; the Health tab has no provider-error series.

## Principles

1. **Feature isolation.** A failure degrades only the feature that made the call, with one honest, specific message
   in that feature's place and a way to retry. No feature's call sets an app-wide failure state, presents an
   unrelated sheet, or blocks launch.
2. **Local first, last-good second.** What the device holds (library, downloaded papers, chats) opens without the
   network. Where a cached answer is safe (feed, capabilities, chat profiles, podcast catalog, credit balance), the
   last good copy is shown, marked as possibly out of date, instead of an error.
3. **Bounded time everywhere.** Every request has a timeout and every spinner has an end; a stream has an idle
   deadline. Total time, not just idle time, is bounded.
4. **Retries only where safe.** Only idempotent reads, or writes with an operation id the server deduplicates, are
   retried; exponential back-off with full jitter; honour `Retry-After`; a small maximum; never a retry loop on a
   4xx other than 408/409/425/429.
5. **No retry storms.** Clients back off on failure (polls slow down, they don't keep their fast cadence) and add
   jitter; the server can tell clients to wait (`retry_after` in error bodies and a capability flag), and
   capability-driven kill switches stop a feature's requests at the source.
6. **Circuit breakers on the server, per provider.** After repeated 429/5xx/timeouts within a window a provider is
   marked *open*: new calls fail fast with a specific code (or use a fallback) for a cool-off, then one *half-open*
   probe decides. Breaker state is shared across function instances (a database row), so many instances don't each
   rediscover the outage.
7. **Money safety without platform outages.** Budget limits stay hard, but a single operation's anomaly isolates
   that operation and alerts; it pauses everything only if the month's projected spend would cross the limit.
8. **Visible before reported.** Every provider failure class is counted per hour and shown on the admin Health
   tab with an Attention rule; a user report should never be the first signal.

## Failure propagation map

Severity: **App** = the whole app or every account; **Screen** = one screen or flow unusable; **Feature** = one
feature degraded with a message; **Cosmetic**.

### Launch and sign-in

| Path | Failure | Today | Severity | Where |
|---|---|---|---|---|
| Native launch, signed in, device cached | Supabase down / 5xx / timeout | Library and downloaded papers open from local storage; sync shows "Saved on this device · Sync paused", retries 15 s → 60 s → 300 s | Feature (good) | `ReaderModel.swift:1458-1461`, `:1590-1612`, `:3802-3804` |
| Native first sign-in on a device (no cached device) | `v1_key_state` 5xx/timeout in `DeviceKeys.prepare()` | Throws; sets "Couldn't prepare your private library…" and presents the **recovery sheet**, as if keys were missing | Screen (misleading) | `ReaderModel.swift:1463`, `:1384-1387` |
| Native email sign-in | Resend/Supabase email 429 | Mapped to `rateLimited(retryAfterSeconds:)`, shown with the wait | Feature (good) | `BackendClient.swift:956-964` |
| Native token refresh | Auth 5xx | Error surfaces to the caller; the session is kept (not signed out) | Feature (good) | `BackendClient.swift:781-805` |
| Browser launch | `v1_key_state` 5xx/timeout/429 | `KeySetup` shows "failed" with Try again; nothing else of the app renders | **App (browser)** | `App.tsx:83`, `lib/keys.ts:176-184`, `ui/Keys.tsx:60-63` |
| Browser token refresh | Auth 5xx | `connection` error to the caller; 400/401/403 sign out (correct) | Feature (good) | `lib/backend.ts:302-340` |
| Browser render | Any malformed value reaching a component | React unmounts the whole tree: blank page | **App (browser)** | `main.tsx:8` |

### Library, sync and reading

| Path | Failure | Today | Severity | Where |
|---|---|---|---|---|
| Native library refresh | RPC 5xx/malformed | Local rows stay; library issue banner | Feature (good) | `ReaderModel.swift:1788…` |
| Native sync | Any | Paused status, back-off (no jitter) | Feature | `ReaderModel.swift:1634-1650` |
| Native open paper | arXiv 5xx/timeout | Device-only; 30 s request / 90 s resource timeouts; specific "couldn't be prepared" message; a previously prepared copy is shown with a fallback notice | Feature (good) | `ArxivHTMLReader.swift:122-124`, `ReaderModel.swift:2620-2680` |
| Native imports polling | Server down | Polls every 1 s for 20 s, 4 s, then 15 s regardless of failures; no jitter | Cosmetic → load | `ReaderModel.swift:1762`, `:1779` |
| Browser library | Server down | 60 s focus poll plus fast import poll with no back-off on failure, no jitter | Cosmetic → load | `ui/useLibrary.ts:87`, `:98-105` |
| Browser open paper | arXiv slow | Per-request timeout, asset concurrency bounded | Feature (good) | `lib/arxiv-reader.ts:35-58`, `:64-78` |

### AI features

| Path | Failure | Today | Severity | Where |
|---|---|---|---|---|
| Chat / Study / Equation view | Anthropic 429/529/5xx before start | `provider_unavailable`, no charge (no message id), no durable record of the 429 | Feature; **invisible** | `anthropic.ts:470-473`, `chat.ts:693`, `:829`, `:1069` |
| Chat | Anthropic fails mid-stream | Since 2026-10-16 (owner decision): nothing charged, the partial text kept, the cost recorded as absorbed (`error … charged: false, reason: "provider"`) | Feature (good) | `chat.ts` `answerEnding`; [CHAT.md](CHAT.md#when-an-answer-stops-early--2026-10-16) |
| Chat | Any operation's cost exceeds its ceiling | Since 2026-10-16: a `budget_anomaly` row and a Health › Attention line; the month pauses only on the hard limit, more than 5 in an hour, or an operator | Feature (good); was **App (all accounts' AI)** | migration `202610160079_contained_overruns_and_early_endings.sql` |
| Chat web search | Tavily down | Native Anthropic search as the backup | Feature (good) | `tavily.ts:2`, `:96` |
| Chat retries | Provider 429 | `maxRetries: 0`; no retry, no alternative model for availability (fallbacks are refusal fallbacks only) | Feature | `anthropic.ts:296`, `:352-357` |
| Podcasts | Provider 429/5xx | Episode fails (`script_rejected`, `speech_rejected`, `*_outcome_unknown`); no requeue | Feature (permanent) | `podcast-worker.ts:291-292`, `:539-540` |

### Search, feed, add paper

| Path | Failure | Today | Severity | Where |
|---|---|---|---|---|
| Search | OpenAlex fails | `Promise.allSettled`, falls back to arXiv search | Feature (good) | `discover/index.ts:99-101` |
| Search | arXiv slot busy (any user or import holds it) | OpenAlex-ranked only, else `503 search_busy` | Feature, **scales badly** | `discover/index.ts:106-111` |
| Search | OpenAlex keyless budget spent | Ranking silently lost after ~50 searches/day | Feature | `discover/index.ts:93-100` |
| Add paper by DOI | Crossref/OpenAlex slow | 8–12 s timeouts, no retry | Feature | `identify.ts:162`, `:233`, `:257` |
| Feed pool | arXiv RSS down | Pool keeps its rows (conditional fetch) | Feature (good) | `feed-pool.ts:171-174` |

### Purchases and admin

| Path | Failure | Today | Severity |
|---|---|---|---|
| StoreKit / App Store Server API | Apple 5xx | Store sync retries with a counter; credits appear later | Feature (good) |
| Admin Health | Provider errors | Not visible (no series); podcast failure codes only | — |

## Per-dependency table

| Dependency | Failure modes | User-visible behaviour (target) | Mechanism | Owner |
|---|---|---|---|---|
| Anthropic | 429 (org tier), 529 overloaded, 5xx, slow stream | Chat: "AI answers are busy; trying again…" then the per-answer error with Retry; reading, library and sync unaffected | Server: one retry after `retry-after`/jittered 1–3 s for pre-start 429/529 only; breaker per model family; optional availability fallback (Sonnet → Haiku with the model named in the answer footer) behind a flag; record every failure class | Chat |
| DeepSeek | Slow, 5xx (no published rate limit) | Episode waits longer, then retries; writer falls back to Claude for the job if DeepSeek's breaker is open. Chat (2026-10-16, when the reader chose DeepSeek): the per-answer error with the wait (`provider_unavailable`, `retry_after`), unbilled when it never started; Claude answers unaffected | Worker requeue with back-off (step 4); per-job writer fallback recorded. Chat: the same one pre-start retry as Anthropic; calls to `api.deepseek.com` count under `deepseek` with their own breaker (shared by podcasts and chat), never Anthropic's; no automatic switch to Claude (a different processor than the reader chose) | Podcasts, Chat |
| Google Vertex TTS | 429 quota, 5xx | Episode retries later; never a terminal failure for a quota 429 | Requeue with back-off; quota raise as an ops action | Podcasts |
| Tavily | 429, 5xx, credits exhausted | Answer without web results, saying so (already); backup search | Breaker so a dead Tavily isn't tried on every answer | Chat |
| OpenAlex (V1: removed) | Budget 429 | — | Removed (owner decision 2026-10-15) | Search |
| Crossref | 429 (polite pool 10/s single, 3/s query) | "Couldn't look up this DOI right now; try again" | Cache by DOI; breaker | Add paper |
| DataCite (planned) | 429 (1,000/5 min/IP), 5xx, lag | Feed shows the last pool with its date; browser search falls back to the library | Last-good pool; fixed egress IP for the server; browser per-IP | Feed, search |
| Hugging Face | 429/5xx | Feed without the trending signal | Optional input; cached | Feed |
| arXiv (devices) | 429/503 busy, 403 refusal, slow | One paper: "arXiv is busy; trying again in N s" or "arXiv refused this device for now (until …)" | Per-device pacer with back-off and a 24 h stop after 403 (built on the arXiv branch) | Reader |
| Supabase PostgREST | 5xx, timeouts, pool exhaustion | Native: local-first; browser: see step 2 | Client back-off with jitter; last-good caches | All |
| Supabase Auth / Resend | Email 429 (project 100/h set 2026-10-15; Resend plan) | "Too many sign-in emails; wait N min, or use Apple/Google" | Already mapped natively; same in browser; Apple/Google always offered | Sign-in |
| Supabase Storage | 5xx | Podcast audio/support attachments retry; reading unaffected | Bounded retries | Podcasts, support |
| Supabase Edge runtime | Cold start, 5xx, wall-clock limit | Chat/podcast/search per-feature error; sync still works | Timeouts below the platform limit (chat 130 s) | — |
| Cloud Run worker | Down, slow | Imports' server stages stall (device reading unaffected); podcasts wait | `pipeline.stuck` check; Health Attention | Pipeline |
| Cloudflare Pages | Edge cache poisoning, outage | Browser app unreachable | Deploy live check (done); 404 for missing admin assets (done) | Web |
| Apple StoreKit / Server API | 5xx | Purchase pending; credits later | Existing retry; notice | Purchases |
| Sign in with Apple / Google | Outage | Email code still works | Offer the other methods | Sign-in |

## Ranked fixes

| # | Fix | Severity fixed | Where | Effort |
|---|---|---|---|---|
| 1 | **Done 2026-10-16 (migration 079).** **Contain overruns.** An operation whose actual or uncertain cost exceeds its ceiling is recorded and alerted (Health Attention, a `budget_anomaly` row) instead of setting `work_enabled=false`; pause the month only when `spent + reserved + projected` crosses the limit, or when anomalies exceed N per hour (a tripwire), or by the operator. Keep the hard monthly limit. | App (all AI) | `202610070034_provider_accounting.sql:289-291`, `:348` (new migration superseding both) | M (migration + DB tests + admin copy) |
| 2 | **Browser error boundaries.** One per pane (reader, chat, library, feed, podcasts, dialogs) with "This panel hit a problem — Reload panel · Report"; a top-level boundary and `error`/`unhandledrejection` handlers that record a code (never content) for reports. | App (browser) | `main.tsx:8`, `ui/App.tsx` panes | S |
| 3 | **Browser launch without the server.** Retry `v1_key_state` automatically (3 tries, 1/2/4 s with jitter) before showing failure; keep the library list from the last session (encrypted, per browser) so a blip shows "Offline — showing your library from earlier" instead of a blocked app. | App (browser) | `lib/keys.ts:176-184`, `ui/Keys.tsx:60-63`, `ui/App.tsx:83` | M |
| 4 | **Podcasts requeue on transient failures.** A pre-processing 429/503 (`rejected` with `http_429`/`http_503`) parks the job with `retry_at` (back-off 1, 5, 15, 60 min, 4 tries) instead of failing; `unknown` outcomes keep today's liability handling. | Feature (permanent → temporary) | `podcast-worker.ts:291-292`, `:539-540`, migration for `retry_at` | M |
| 5 | **Provider telemetry and breakers** (below): record every failure class per provider per hour; breakers for Anthropic, Tavily, DeepSeek, Google, Crossref, DataCite. | Visibility, storms | new `_shared/provider-health.ts`, migration | M |
| 6 | **Native first-device key preparation**: a network/5xx failure in `prepare()` shows "Couldn't reach Gradstep to set up this device. Try again" with automatic retry, not the recovery sheet; recovery only for `.recoveryRequired`. | Screen (misleading) | `ReaderModel.swift:1384-1387`, `:1463` | S |
| 7 | **Chat retries once on pre-start 429/529** after `retry-after` (≤ 3 s, jittered), inside the existing hold; show "busy, retrying" via a `status` event. | Feature | `anthropic.ts:470-473`, `chat.ts` generateAnswer | S |
| 8 | **Client back-off with jitter for polls**: native import poll and sync, browser library/import polls slow down after consecutive failures (×2 to a cap) and add ±20 % jitter; honour a server `retry_after`. | Load / storms | `ReaderModel.swift:1762`, `:1779`, `:3802-3804`; `ui/useLibrary.ts:87`, `:98-105` | S |
| 9 | **Native `Retry-After` and 429 mapping** outside sign-in: `BackendError.rateLimited(seconds)` from any 429, surfaced per feature. | Feature | `BackendClient.swift:1001-1037` | S |
| 10 | **Last-good caches** on the native and browser clients for capabilities, chat profiles, podcast catalog, feed and credit balance, each shown "as of" when stale. | Feature | `ReaderModel.swift:458` (profiles), feed/podcast centers, `lib/feed.ts`, `lib/podcast.ts` | M |
| 11 | **Total-time bounds** on native RPCs (`timeoutIntervalForResource` is the 7-day default on the main session) — e.g. 120 s, streams excepted. | Spinner that never ends | `BackendClient.swift:153-155` | XS |
| 12 | **Search off the shared slot** — device search (ARXIV_DEVICE_ONLY.md step 4), no OpenAlex. | Feature, scale | `discover/index.ts:93-111` | in progress |

## Telemetry: "throttled or failing, by provider"

**What:** counts only, never content or identifiers of people: per hour, per provider, per route, per outcome class
— `ok`, `throttled` (429, quota), `overloaded` (529/503), `server_error` (other 5xx), `timeout`, `transport`
(connection/aborted mid-stream), `rejected` (other 4xx), `breaker_open` (failed fast) — plus p50/p95 latency of the
`ok` calls and the largest `retry_after` seen.

**Where:** a new table, not `provider_usage_events` (that is per paid event and needs an operation; most failures
have none):

```sql
create table app_private.provider_health_hours (
  hour timestamptz not null,                 -- date_trunc('hour', now())
  provider text not null check (provider ~ '^[a-z][a-z0-9_]{0,31}$'),
  route text not null check (route ~ '^[a-z][a-z0-9_]{0,31}$'),
  outcome text not null check (outcome in ('ok','throttled','overloaded','server_error','timeout','transport','rejected','breaker_open')),
  calls integer not null default 0,
  latency_ms_total bigint not null default 0,
  latency_ms_max integer not null default 0,
  retry_after_max_s integer,
  primary key (hour, provider, route, outcome)
);
-- RLS on, no grants; written only through:
create function public.worker_provider_health(p_provider text, p_route text, p_outcome text, p_latency_ms integer,
  p_retry_after_s integer default null) returns void ... -- upsert-increment; never raises to the caller; 90-day retention
create table app_private.provider_breakers (
  provider text primary key, state text check (state in ('closed','open','half_open')),
  opened_at timestamptz, reopen_at timestamptz, consecutive_failures integer not null default 0);
```

`_shared/provider-health.ts` wraps each provider call site (Anthropic, Tavily, DeepSeek, Google, Crossref, DataCite,
Hugging Face) and the worker's: classify the outcome, fire-and-forget the RPC (bounded, never blocks the answer),
consult/update the breaker (open after 5 consecutive `throttled|overloaded|server_error|timeout` within 60 s; cool
off 30 s doubling to 5 min; one half-open probe).

**Health tab:** `v1_admin_health` adds `providers: { daily: [{ day, by_provider: { anthropic: { ok, failed, throttled } } }],
last_hour: [...] }`; a "Provider errors" chart (stacked failed/throttled per provider per day; hour view for 7 days)
beside Spend per day; the Reliability tab gets the hour-level table. **Attention rules:** any provider with ≥ 5 %
failed or throttled calls in the last hour (and ≥ 20 calls); any breaker open now; `work_enabled` false; a
`budget_anomaly` in the last 24 h.

## Fault injection

**Server switches** (staging and local only; never production):

- `app_private.fault_injection(provider text, route text, mode text check (mode in ('throttle','overload','error','timeout','malformed')), rate numeric, until timestamptz)`,
  read by `provider-health.ts` before the real call; honoured only when the request's account is a test account
  (`@example.invalid`/`@example.test`) **and** the environment is not production (`SCIENCE_READER_ENVIRONMENT`), so a
  forgotten row can't hurt a real reader. Operator RPC to set/clear, audit-logged.
- `scripts/fault-drill.mjs --provider=openrouter --mode=throttle --minutes=5` (`anthropic` until 2026-10-18): sets the row, runs the affected
  workflow checks (chat smoke, podcast short, search, add DOI) with a disposable account, asserts the user-visible
  outcome and the telemetry counts, clears the row.

**Client fixtures:** native `ChatFixtureTransport` modes `throttled`, `overloaded`, `stall` (no bytes for 120 s) and
a `BackendFaultProtocol` (`--backend-fault=<path-prefix>:<status>|timeout|malformed`) for any RPC; browser
`e2e/fixture-backend.mjs` gains the same switches (`?fault=rpc:v1_key_state:503`), plus an arXiv fault for the
reader (`429` with `Retry-After`, `403`).

**Journeys that must stay usable** (each a UI journey per surface, run in the slow tier):

| Dependency down | Must still work |
|---|---|
| Anthropic | Library, reading downloaded and new arXiv papers, figures and equations shown (not described), sync, podcasts already made, settings |
| Supabase (all) | Native: library from this device, reading downloaded papers, local chats; browser: a clear offline state, no blank page |
| Supabase Edge only | Library sync and reading; chat/search/podcast show their own errors |
| Cloud Run worker | Reading, chat, sync; imports show "waiting" not failure; podcasts queue |
| arXiv | Downloaded papers, library, chat about downloaded papers |
| Email (Resend) | Sign in with Apple and Google |
| Podcasts' providers | Everything except new episodes; existing episodes play |
| Any one search source | Library search and the feed's last pool |

## Implementation order

1. **Contain overruns** (fix 1) and its Attention rule — highest blast radius; M, ~1 day with DB tests.
2. **Browser error boundaries** (fix 2) — S, half a day; e2e that injects a malformed RPC body per pane.
3. **Telemetry table, `provider-health.ts`, Health chart and Attention** (fix 5, recording only) — M, ~1 day.
4. **Podcast requeue** (fix 4) — M, ~1 day with DB tests.
5. **Browser launch retry + last-session library** (fix 3) — M, ~1 day.
6. **Native first-device key preparation copy and retry** (fix 6), **native 429 mapping** (fix 9), **resource
   timeout** (fix 11) — S, half a day together.
7. **Chat one retry on pre-start 429/529** (fix 7) — S.
8. **Client back-off with jitter** (fix 8) — S.
9. **Breakers** on top of the telemetry (fix 5, second half) — M.
10. **Fault-injection switches, drill script and the must-stay-usable journeys** — M, ~1–2 days.
11. **Last-good caches** (fix 10) — M.

## Server side as built

Migration `202610150073_provider_resilience.sql`; tests `tests/database/provider_resilience.sql`,
`tests/backend/provider-health.test.ts`, and additions to `chat.test.ts` and `podcast.test.ts`. Where it differs from
the proposal above, the reason is given.

**Telemetry.** `app_private.provider_health_hours` as proposed, written only by `worker_provider_health` (service role;
returns that provider's breaker; never raises; 90 days kept). Latency is kept as total and maximum per hour (an
average and a worst case), not p50/p95: an hourly upsert can't keep percentiles without storing samples.
`_shared/provider-health.ts` records every request to a known provider host (Anthropic, DeepSeek, Google's
`aiplatform` speech, Tavily, Crossref, DataCite, OpenAlex, Hugging Face) exactly once: `installProviderHealth` wraps the
realm's `fetch` in chat, discover, add-paper, add-reference, feed-refresh and paper-worker and in the Cloud Run worker
(pipeline and podcast runs); `accountProviderFetch` carries the reader's account for the chat's Anthropic and Tavily
calls and the podcast's Anthropic, DeepSeek and speech calls (the only calls a drill can reach). Nothing about the
request is recorded beyond provider, route, outcome, latency and Retry-After. `v1_admin_health` gains `providers`
(daily failed/throttled/paused per provider, the last hour, open breakers) and `v1_admin_provider_hours(p_hours)` feeds
Reliability's hour-by-hour table. Health shows a "Provider errors" chart under "Is it working?" and three Attention
rules: a breaker open now, ≥ 5 % failed or throttled in the last hour with ≥ 20 calls, and the existing
`work_enabled` rule.

**Breakers** (`app_private.provider_breakers`, one row per provider, shared by every instance). Five failures
(`throttled`, `overloaded`, `server_error`, `timeout`, `transport`), each within 60 s of the previous, open it for
30 s; each reopening doubles the cool-off to at most 5 min; any `ok` closes it. After the cool-off it is half-open:
each instance lets one probe through per 30 s. `rejected` (our request's fault) and `breaker_open` never count. While
open the wrapper answers at once with a synthetic 429 (`Retry-After` = the remaining cool-off,
`x-gradstep-synthetic: breaker-open`), so every caller's existing 429 handling applies: nothing billed, the chat says
`provider_unavailable` with `retry_after`, a podcast requeues. Instances learn the state from each recorded call's
reply and, at start, from `worker_provider_breakers()`.

**Chat retry (fix 7).** `retryOnceWhenBusy` in `anthropic.ts`: one more try, same model, only when the first ended
before any message started with a 429 or 529; it waits the provider's `Retry-After` when that is at most 5 s, else
1–3 s jittered, and gives up at once when the wait would be longer or the reader left. Each attempt has its own grant
(`admittedAnthropic`): a 429 settles at zero, a 529 keeps the platform's liability rule unchanged, and the reader is
charged only for the answer that runs. The bound is 5 s rather than the proposed 3 s so a breaker's or a drill's 5 s
`Retry-After` is honoured. The "busy, retrying" status line is a client change left to the client work.

**Podcast requeue (fix 4).** `worker_podcast_requeue` parks a job whose script or speech stage was refused with
`http_429` (`rejected`: the provider says it did nothing), with `retry_at` after 1, 5, 15 and 60 minutes (×0.8–1.2
jitter); a fifth refusal fails as before (`retries_exhausted`). It requeues only when every refused attempt is
`rejected`, and only when the job's paid work can resume from its saved state (`podcast_resume_state`), so nothing
already paid is bought twice. A 503 or a timeout is recorded `unknown` (the provider may have done and billed the
work) and keeps today's liability handling: re-sending it could pay twice and grow the operation's liability toward
the overrun pause (fix 1). `worker_podcast_claim` skips jobs before their `retry_at`; pg_cron
`science-reader-podcast-retries` kicks the worker each minute while a requeued job is due.

**Our own `retry_after`.** Chat error events carry `retry_after` (seconds) for `rate_limited` (60),
`provider_unavailable` (the provider's Retry-After, else 10) and `service_unavailable` (10). Every function's JSON 429
or 503 sends a `Retry-After` header and `retry_after` (`errorResponse` in `_shared/http.ts`; the header is exposed to
browsers through CORS).

### Fault drills

**Switches.** `app_private.fault_injection` rows (account, provider, route or all, mode `throttle | overload | error |
timeout | malformed`, rate, until — at most 60 minutes ahead; cleared rows are kept). The database refuses a row for
any account that is not an open `@example.invalid` or `@example.test` account, and checks again on every read
(`worker_fault_injection_active`). The functions read the table only when `FAULT_INJECTION=on`, which
`deploy-staging.py` sets only for the staging environment with `fault_injection: true` in `infra/staging.json` (there
is no production configuration, and the flag defaults off) — the environment check the proposal named
`SCIENCE_READER_ENVIRONMENT`. Operators set one with `v1_admin_fault_injection_set` (owner with MFA, audited as
`fault_injection_set`); scripts with the service-role `worker_fault_injection_set` / `worker_fault_injection_clear`.
A synthetic answer never reaches the provider, is recorded under the route `drill` (left out of the admin views) and
never moves the shared breaker, so a drill on one test account can't pause a provider for everyone.

**`scripts/fault-drill.mjs`** (staging only): checks `FAULT_INJECTION` is on (management API digest), makes a
disposable `gradstep-check-drill-…@example.invalid` account with 50 credits, sets the fault, asks the general chat for
one word, and checks: an `error` event, not an answer; `provider_unavailable` with `retry_after` (throttle and
overload); nothing charged and nothing held; the library still loads; the expected `drill` rows in the telemetry
(two for a throttle: the first call and the one retry). It then clears the fault, waits out the functions' 15 s
fault cache, checks a real answer arrives (about $0.005), and deletes the account through `account-delete`. Modes
other than `throttle` on Anthropic need `--allow-liability`: the ledger can't tell a synthetic 529, 500, timeout or
unreadable answer from a real one, so each leaves an unknown liability on the drill's operation.

**Early-ending drills (2026-10-16, migration 079).** Three more modes, each on its own disposable account, each
reconciling its synthetic attempts to zero at the end (`worker_fault_drill_reconcile`: test accounts only, attempts whose
provider request id starts `drill-`, so nothing is left as a liability and no synthetic cost stays in the month):
`--mode=midstream` (fault `midstream`: a streamed answer that fails as overloaded after its first text; checks the text
arrived, `provider_unavailable` with `credits: 0, charged: false, reason: "provider"`, the balance unchanged, the
ending `provider` with its cost absorbed, one `transport` drill row), `--mode=stop` (fault `slow`: a synthetic answer
written over a minute; the drill leaves after two pieces of text three times: with `stop_signal` and a recorded Stop →
`stopped`, charged; with `stop_signal` and no Stop → `connection`, nothing; without the capability → `left`, charged)
and `--mode=overrun` (no fault: through the service RPCs a test account's operation reports 3 micro-USD over a 1
micro-USD attempt ceiling; checks the two anomaly rows, `work_enabled` still true, and a real Haiku answer; it refuses
to run when one more anomaly could trip the tripwire). Recovery answers use Claude Haiku 5.5 (about $0.0002 each).

Wired today: OpenRouter on chat (Anthropic until the OpenRouter-only cutover of 2026-10-18; chat no longer calls
Anthropic, so an Anthropic drill injected nothing — review D4, 2026-10-21). The overrun drill admits its synthetic
attempt as `openrouter`/`chat`/`anthropic/claude-haiku-5.5`. The streamed `midstream`/`slow` faults are synthesized
only for the Anthropic and DeepSeek stream formats in `provider-health.ts`; an OpenRouter-format synthetic stream is
needed before `--mode=midstream`/`stop` exercise the live path. Next: Tavily on chat (needs a question that reliably searches); podcasts (the
worker's environment needs `FAULT_INJECTION`; `deploy-pipeline-worker.py` doesn't pass it yet); search and add-paper
(their provider calls carry no account yet).

**First drill.** After migration 073 and the functions are deployed to staging:
`node scripts/fault-drill.mjs --provider=anthropic --mode=throttle --route=chat --minutes=5` (today: `--provider=openrouter`, the default).

### Scoped breakers, per-feature keys and billing blame — 2026-10-21 (review A13, migration 0106; not deployed)

After the OpenRouter switch every model shares one host, so the per-provider breaker turned any route's trouble into
everyone's: five failures in 60 s from a DeepInfra outage (DeepSeek), a podcast's speech errors or a tag job's 429s
failed every Claude and Gemini chat with synthetic 429s for 30 s–5 min. One key also let a runaway podcast or tag job
drain the balance chat needs, and a 402 told readers to "choose another AI model" when every model shares the account.

- **Scoped breakers.** `provider_breakers` is keyed by provider and `scope`. For OpenRouter the scope is the calling
  route and the upstream the request pins, read from the end of the request body without parsing or recording content:
  `chat_vertex` (Claude and Gemini), `chat_deepinfra` (DeepSeek), `run_vertex` (catalog tags), `podcast_vertex` /
  `podcast_deepinfra` (scripts), `podcast_speech`, and `*_read` for receipt GETs. A scope's failures open only its own
  breaker; other providers keep one breaker each. `worker_provider_health(..., p_scope)` (named arguments of the earlier
  signature still resolve); health hours are unchanged (per provider and route); Health › Attention names the scope.
- **Per-feature keys.** `OPENROUTER_TAGS_API_KEY` and `OPENROUTER_PODCAST_API_KEY` are used when present, each meant to
  carry OpenRouter's own per-key credit limit; otherwise the chat key, as before. The reconciler reads each generation
  with the key of the feature that created it. **Provisioning is an owner step not done here:** create the two keys in
  OpenRouter with per-key limits that fit inside the month's provider limit, add them to `.env.providers` and the
  pipeline worker's secret list (`scripts/pipeline_readiness.py`), then redeploy the worker.
- **Billing blame.** A 402 from the gateway is answered `service_unavailable` with `retry_after: 300` (and a
  `chat_provider_billing` log line and the existing Health › Attention count), never `model_unavailable`.

## Fix 1 and early endings as built — 2026-10-16

Migration `202610160079_contained_overruns_and_early_endings.sql` (staging 2026-10-16), the chat function, tests
`tests/database/contained_overruns.sql`, `tests/backend/chat.test.ts`, `provider-spending.test.ts`,
`provider-health.test.ts`.

**Contained overruns.** The three places that set `work_enabled=false` on a single overrun — migration 003's settlement
(now `app_private.settle_operation_before_034`), 034's `provider_attempt_apply` (an attempt over its ceiling, or an
operation's attempts over the operation's) and 034's `worker_settle_operation` (known cost plus unresolved ceilings over
the operation's) — now call `app_private.record_budget_anomaly` instead. `app_private.budget_anomalies` keeps one row per
operation and kind (`attempt_over_ceiling` with the attempt, `operation_over_ceiling`): the ceiling, the largest cost
seen, whether the account is a test account, and whether that row paused the month. The tripwire
(`app_private.paid_work_guard`: 5 operations, 60 minutes) counts operations, not rows, and starts afresh after its last
pause, so an operator who resumes the month is not paused again by the next single anomaly. The hard limit check in
`worker_reserve_operation` and the operator's switch are unchanged. A pause set by the tripwire marks its row
`paused_month`; `worker_budget_health` (the scheduled budget check) adds `anomalies_in_window`, `anomalies_24h` and
`paused_by_tripwire`; `v1_admin_health` adds `anomalies` (the tripwire's numbers, the window's count, the last day's, the
latest ten with their ceilings and costs). **Attention:** "N operations cost more than their ceiling in the last 24
hours" (recorded, not paused; the largest), and, when the tripwire paused the month, that it did and how to resume.

**Early endings.** [CHAT.md](CHAT.md#when-an-answer-stops-early--2026-10-16) has the definitions and the contract;
the abuse guard's **Attention** line names each real account with more than 20 unpaid early endings today and what
Gradstep paid for them.

**Live on staging, 2026-10-16 06:27–06:33 UTC** (chat function deployed after the migration; deploy checks 19 passed,
including the chat smoke, which recorded the first `completed` ending):

| Drill | Result | Operation | Reader charged | Provider cost |
|---|---|---|---|---|
| `--mode=throttle` (429 before the start) | 9 of 9 | `cb605a6a-9fae-4aa1-a643-62fcc54983df`: two `rejected` attempts, ending `provider` | 0 (`charged: false, reason: "provider"`), balance 50 → 50 | $0 |
| `--mode=midstream` (overloaded after the first text) | 8 of 8 | `6d02ef34-d00c-4eb9-9c8e-596bf03ab086`: 63 characters streamed, then `provider_unavailable`; ending `provider`, 12 micro-USD absorbed; the 2,241 micro-USD held ceiling released by the drill's reconciliation | 0, balance 50 → 50 | $0 (synthetic) |
| `--mode=stop` | 6 of 6 | Stop recorded: `8da20b6a-3867-4dd6-9dcc-7a155de4575c` `stopped`; dropped: `9a873b71-7100-4627-9ba6-881cce00e20e` `connection`; no capability: `9e42aa9e-e9e5-4bc4-a92c-299540132e5a` `left` | 1, 0 and 1 credit (balance 50 → 49 → 49 → 48) | $0 (synthetic) |
| `--mode=overrun` | 5 of 5 | `89bc1980-fc2b-442c-b008-d4602322a369`: 3 over a 1 (attempt) and 2 (operation) micro-USD ceiling, two test-account anomaly rows, `work_enabled` true, 1 of 5 toward the tripwire; then `4f582107-8371-4f3b-a893-f7b190161353` answered (1 credit) | — | 3 micro-USD, reconciled to $0 |

Each drill's recovery answer (Claude Haiku 5.5, 1 credit) cost 234 micro-USD; the four drills together spent about
$0.001 of provider money. Afterwards: October $26.87 spent, $0 reserved, no unresolved attempts or open operations,
`work_enabled` true. The overrun drill's two anomaly rows (test account) show in Health › Attention for 24 hours.

## Owner decisions

- **Resend plan — decided 2026-10-16 (owner: "Still on the free one").** Stay on the free plan for the private beta:
  100 emails a day (3,000 a month), account-wide; the project allows 100 sign-in emails an hour (set 2026-10-15).
  Revisit before the public release, or sooner if sign-in emails approach 100 a day; a paid plan (about $20/month)
  removes the daily wall and would count against the $100 budget.
- **Anthropic tier:** limits are per organisation and rise with cumulative purchases; check the console tier before
  launch and decide whether to pre-purchase to reach the next tier.
- **Charging for failed answers — decided 2026-10-16 (owner: "we need to better define the situation. If we were
  charged by the provider, the onus is now on us to provide the value back to the owner").** The reader pays for work
  that finishes, or for the part of an answer they chose to stop. Anything else that ends it early — the provider
  failing or overloading mid-stream, our server failing, our own time limit (the 130 s deadline) or length limit
  (`max_tokens`), the connection between our server and the reader dropping, or a refusal — costs the reader nothing:
  the hold is released, Gradstep pays the provider, and the cost is recorded as platform-absorbed (in the month's
  spend, Health and the tripwire's view; never hidden). Partial text stays the reader's. Definitions per feature:
  [CHAT.md](CHAT.md#when-an-answer-stops-early--2026-10-16). Abuse guard: more than 20 unpaid early endings for one
  account in a UTC day raise a Health › Attention line; the reader is never blocked.
- **Availability fallback model:** allow Sonnet → Haiku (named in the answer) when Sonnet is throttled?
- **Overrun policy (fix 1) — decided 2026-10-16 (owner: "Yes, I agree with your suggestions").** An operation whose
  actual or uncertain provider cost exceeds its ceiling is recorded and alerted (a `budget_anomaly` row, Health ›
  Attention) and does not pause the month. The month pauses only when (1) spent + reserved + a new hold would pass the
  hard monthly limit (unchanged), (2) more than **5** operations overran within a rolling hour (the tripwire), or (3) an
  operator pauses it.
- **Fixed egress IP** for the server that calls DataCite (Cloud Run with Cloud NAT, a small monthly cost), so per-IP
  limits aren't shared with other tenants.

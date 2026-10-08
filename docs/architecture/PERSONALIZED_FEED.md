# Personalized feed ("For you")

Status, 2026-10-08 UTC: **option A backend built and tested locally; native/web For you UI remains a proposal.
Both server switches default off.** Nothing is applied to staging or deployed. Migration `202610070043_personalized_feed.sql` (renumbered from the never-applied 044 during takeover; follows 042). The owner decisions this needs are listed at the end.

Owner request (2026-10-07): "I think we need to also invest in a better feed, it should feel relevant to a users
interests and be kept up to date and changing but have cost under control".

## How the Feed works today (measured before designing)

| Aspect | Today |
|---|---|
| What the reader sees | Category chips (at most six arXiv categories from the library's own papers — a category needs two papers unless it is core ML — else cs.LG, cs.CL, cs.AI, cs.CV), named with the tag vocabulary ("Natural language processing"); List or Table; Add; Refresh in the "…" menu (`ReaderModel.feedCategories`, `FeedView`, `FeedTable`) |
| Sourcing | Every chip load calls `discover?category=X` (Edge). The function rate-limits (`discover`: 60/account/h, 600/environment/h), reserves the shared arXiv pacing slot (`worker_pipeline_arxiv_slot`, 3 s spacing shared with the pipeline and arXiv search, at most 8 s wait), then **fetches `rss.arxiv.org/rss/X` live** and returns the first 25 `new`/`cross` announcements |
| Caching | None on the server. The app keeps the last list in memory only; opening the Feed with no results, changing chip, pulling to refresh or Refresh each fetch arXiv again |
| Charging | No credits; one Edge invocation (inside the Pro plan's quota) and one arXiv request per load. No arXiv/provider fee, but database/Edge/egress consume plan capacity and **arXiv traffic scales per user per refresh**, and a busy pacing slot shows "Feed unavailable" |
| Personalization | Only the choice of categories. No ranking, reasons, dismissals or "new since last visit" |
| Legacy web app | Topic feed from the library's top 8 keywords via Semantic Scholar, last 30 days, refreshed per topic after 6 h, items pruned after 45 days, papers already in the library hidden, chips with counts, "Updated Xh ago" ([gap audit](../LEGACY_GAP_AUDIT.md)) |
| Browser reader | Category Feed shipped with milestone 1 at app.gradstep.ai; personalized For you is not implemented |

**arXiv volume, measured** (one request from a workstation, 2026-10-07 21:31 PDT, the 2026-10-08 announcement):
`rss.arxiv.org/rss/cs.LG+cs.CL+cs.CV+cs.AI+stat.ML+cs.RO+cs.IR+cs.NE+cs.MA+cs.SD+eess.AS+eess.IV` is one
**2.5 MB** response with **1,191 items, deduplicated across categories**: 714 new, 111 cross-lists (825 papers new
to these categories) and 366 replacements. cs.LG alone: 512 items, 1.09 MB. Responses carry an `ETag` and
`Cache-Control: max-age≈86,400`; the feed is rebuilt once per announcement day (`lastBuildDate` 04:31 UTC,
Monday–Friday). The cost model below uses the requested 300–600 papers/day and shows the measured 825 where it
matters.

## Goals and limits

- Relevant: ranked by what the reader's library and Feed choices say they care about, with a reason per paper.
- Up to date and changing: a shared pool refreshed from arXiv every announcement day; freshness decay, diversity and
  a little daily exploration so the top of the list moves.
- Cost under control: **no per-user provider calls**. One shared arXiv request per refresh no matter how many
  readers; ranking is a bounded database query plus arithmetic. Every cap is enforced on the server.
- Not changed: chips, List/Table, Add, Refresh and the Feed's place in the app. "For you" is one more chip.
- Never fails worse than today: with the switch off, an empty pool or any For you error, the app shows the category
  chips exactly as before.

## Interest signals

Server ranking uses only data the server already holds. Encrypted or device-local signals can only ever be used on
the device.

| Signal | Where it lives | Server-visible | Used |
|---|---|---|---|
| Papers in the library (and whether archived) | `library_items` | Yes | Server ranking (A). Archived papers count half |
| Their arXiv categories, authors, title | `catalog_metadata` (public arXiv metadata) | Yes | Server ranking: category and author affinity; the title appears in "Because you added …" |
| Catalog tags (vocabulary, per paper version) | `library_items.catalog_tags` | Yes | Server ranking: topic affinity |
| Personal tags (own, and removed catalog tags) | `library_items.user_tags`, `hidden_tags` | Yes ([owner decision 2026-10-07](../DECISIONS.md#topic-tags-owner-asked-2026-10-07-agent-decisions-reversible)) | Own tags weigh 1.5× and are also matched as phrases in new abstracts ("In your tag: RLHF"); removed tags are not counted |
| Imports in flight (including Adds from the Feed) | `import_requests` (+ metadata once found) | Yes | Counted like library papers, so an Add changes For you at once. The server cannot tell a Feed Add from another Add, and does not need to |
| Uploaded PDFs | Title is an encrypted descriptor; metadata is a placeholder | Title: no | Only their personal tags count; never anchors a reason |
| Papers opened, reading progress | Device-local encrypted `ReadingActivity`, never synced | No | Not used now. Phase 3: an on-device re-rank of the server's list (boost topics of papers opened in the last 14 days, "Because you're reading …") |
| Conversations, passages, notes | End-to-end encrypted events | No | Never on the server. Possible on-device use in Phase 3 |
| Not interested / More like this | New `feed_feedback` (one row per account and paper) | Yes (new, disclosed) | Server ranking: hidden at once; features of the paper (topics, authors, categories) are snapshotted so the signal outlives the pool's 30 days |
| Explicit follows of topics/authors | Proposed `feed_follows` | Yes, when built | **Not built.** Comes with the onboarding proposal below |
| How many readers added a new paper | Aggregate of library membership | Only as an aggregate | Small boost and the "Added by several readers this week" reason, **only when at least three accounts** added it |

## Candidate generation: one shared pool

- **Source: arXiv's RSS, one combined request** for the twelve ML categories above (`feed_policy.categories`).
  Conditional (`If-None-Match`), checked every 2 hours: twelve requests a day, eleven of them `304 Not Modified`, one
  full 2.5 MB download per announcement day. Only `new` and `cross` items are kept (replacements are old papers).
  arXiv's [API terms](https://info.arxiv.org/help/api/tou.html) ask for one request every three seconds; the request
  still goes through the shared pacing slot so it never competes with imports.
  - Rejected for the daily pool: the arXiv API (`export.arxiv.org`, the endpoint we were throttled on; date-sorted
    category queries are slow) and per-category RSS (twelve times the requests for the same data).
  - Backfill: not needed — the first refresh brings the day's ~825 papers. A 14-day backfill, if ever wanted, is a
    one-off OAI-PMH `ListRecords` run (`set=cs`, `from=`; paged, 3 s apart); not built.
  - Other free sources, considered for later and not built: OpenAlex (citation counts for the pool, ~17 batched
    requests a day: a "trending" signal), Hugging Face daily papers (community upvotes; unofficial API terms), Semantic
    Scholar recommendations (per seed paper; usable for "More like this" only if cached per paper, never per user).
    Papers with Code was retired in 2025.
- **Pool:** `app_private.feed_papers`, one row per arXiv paper: title, ≤ 12 authors (and normalized author keys),
  abstract (≤ 2,000 characters), categories, topic tags, announcement date, first seen. 30 days are kept (≈ 25,000
  rows at the measured rate), at most 60,000 rows; the For you window is the last 14 days.
- **Topic tags without a model:** `feed-topics-v1` (`supabase/functions/_shared/feed-topics.ts`) maps title and
  abstract to the same 120-tag vocabulary readers' papers are tagged with, by curated keyword rules (e.g.
  "Mixture of experts" ← `mixture[- ]of[- ]experts|\bMoE\b|expert routing`), plus the category tags. It is free,
  deterministic, versioned (rows record the rule version) and tested on real abstracts. It is coarser than the Haiku
  catalog tagger, which is why paying to tag the pool is option C below.
- **Scheduler: pg_cron inside the database, waking an Edge function only when work is due.** A job every 30 minutes
  runs `app_private.feed_refresh_kick()`, which does nothing unless refreshing is on and the source is due (or a claim
  has expired); then it posts to the `feed-refresh` Edge function with a dedicated secret from Vault (pg_net, as the
  pipeline wake-up does). No always-on service and nothing on the Cloud Run worker, so it is independent of the
  pending wake-on-work decision. The function claims the source with a 5-minute lease, fetches, parses, upserts in
  batches, and records the outcome; failures back off (15 min doubling to 6 h), a busy pacing slot retries in 10 min.

## Ranking

Split so ranking can change without migrations:

1. **SQL, per request** (`worker_feed_candidates`, ~tens of ms, bounded): builds the inputs and a generous
   prefilter. Excludes papers in the library, in flight or marked Not interested. Returns the reader's profile
   (≤ 300 most recent library papers: tags, categories, ≤ 4 author keys each, title), their feedback, and ≤ 400
   candidates from the 14-day window: those sharing a topic, an author or a phrase-matched personal tag with the
   profile (best 250 by a coarse score), plus up to 100 that only share a category, plus up to 50 of the newest
   papers, each set ordered by a per-account-per-day hash so the sample changes daily.
2. **TypeScript in `discover`** (`_shared/feed-rank.ts`, unit-tested):
   - Weights: each library paper `w = (archived ? 0.5 : 1) × (0.4 + 0.6·e^(−age/120 d))`; in-flight imports 1;
     More like this `1.5·e^(−age/90 d)`; Not interested `−1·e^(−age/90 d)` on the paper's topics and authors.
   - Topic affinity: sum of tag weights over the candidate's topics and matched personal tags (area tags ×0.35, own
     tags ×1.5), normalized by the largest tag weight, squashed `1 − e^(−x)`. Author affinity `1 − e^(−Σ weights)`.
     Category share: weight of the candidate's categories over all category weight (primary 1, others ½).
   - `relevance = 0.5·topic + 0.3·author + 0.2·category (+0.1 if ≥ 3 readers added it)`, times a penalty
     `e^(−0.7·overlap with dismissed papers)`.
   - Freshness: half-life 5 days, `score = relevance × (0.4 + 0.6·0.5^(age/5)) + 0.03·u`, where `u` is a
     deterministic per-account-per-day random number: stable within a day, different tomorrow.
   - Diversity (greedy, MMR-like): each pick lowers remaining papers sharing its lead topic (×0.8 per repeat), first
     author (×0.7) or primary category beyond three (×0.9).
   - Exploration: every fifth slot (5, 10, 15 …) takes the freshest well-scored paper that matches only by category
     ("Something different: Robotics"); if there is none, the slot is ranked normally.
   - 50 papers per response.
3. **Reasons** (one per paper; the app writes the sentence, the server also sends English text as a fallback):

   | Kind | Shown | Chosen when |
   |---|---|---|
   | `author` | By Noam Shazeer, an author in your library | An author key matches a library or More-like-this paper |
   | `tag` | In your tag: RLHF | One of the reader's own tags matches (topic or phrase) |
   | `more_like` | More like "Mamba: Linear-Time Sequence…" | Overlaps a paper marked More like this |
   | `added` | Because you added "Direct Preference Optimization…" | Shares a topic tag with a library paper (the most recent such paper, never an upload) |
   | `popular` | Added by several readers this week | ≥ 3 accounts added it, and no stronger reason |
   | `category` | New in Computer vision | Category match only, or cold start |
   | `explore` | Something different: Robotics | An exploration slot |

- **Cold start** (no library papers, imports or feedback with any feature): newest papers across the core
  categories, diversified by category, reason `category`, response flag `cold_start`; the app shows one line
  ("Add papers or use More like this to tune For you") and the category chips work as today. **Onboarding topic
  picks** (choose 3–5 topics on first opening the Feed, stored as follows) are proposed, not built.
- Category chips are served from the pool too when the switch is on (newest 25 in that category, Not interested
  papers removed), so chip loads stop calling arXiv. Categories outside the pool keep the live RSS path.

## Freshness and "new since last visit"

- The pool refreshes every 2 hours (conditional), so a new announcement is in For you within ~2.5 hours of arXiv
  publishing it (≈ 04:30 UTC, Monday–Friday). The response carries `refreshed_at`.
- Each paper carries `first_seen` (when the pool first saw it). The app keeps the last time this device showed For
  you (device-local `UserDefaults`, never sent) and marks papers first seen after it with **New** at the start of the
  reason line. The visit time updates when For you is left or the app goes to the background, so the marks stay
  while reading the list.
- The daily seed changes exploration and tie order every UTC day even without new papers (weekends).

## Cost model

Assumptions: 22 announcement days a month; 300–600 new papers a day (measured 825); each active reader opens the
Feed ~10 times a day; responses ≈ 55 KB (50 papers). Prices are list prices checked 2026-10-07: Supabase Pro
(already paid; includes 2 M Edge invocations, 250 GB egress, 8 GB disk per project; overage $2 per million
invocations, $0.09/GB egress, $0.125/GB disk); Anthropic Haiku 4.5 $1/$5 and Sonnet 5.5 $2/$10 per million
input/output tokens, Message Batches −50 %; embeddings $0.02 per million tokens (OpenAI `text-embedding-3-small`,
Voyage `voyage-3.5-lite`; third-party price listings — confirm on the vendor page before approval).

| Cost line (per month) | A: heuristic, no paid API — **backend built** | B: + shared embeddings via an API | C: + an LLM in the loop |
|---|---|---|---|
| arXiv (RSS) | $0 — 360 requests, ~55 MB | same as A | same as A |
| Provider API, 20 readers | $0 | $0.08–0.11 (4–5.4 M tokens: every pool paper once, ~300 tokens; library papers once ≈ $0.01) | C1 tag every pool paper with Haiku (measured $0.0038/paper): **$25–68** (Batches–standard; 6,600–18,000 papers). C2 per-reader LLM re-rank + generated reasons (Haiku, ~6k in/1k out per refresh, daily): **$6.60** |
| Provider API, 1,000 readers | $0 | $0.10–0.15 + one-time ≈ $0.30 for ~50k library papers | C1 unchanged ($25–68); C2 **$330** |
| Edge Functions | $0 — refresh ~360 + reader 6,000 invocations (1,000 readers: 300,000), inside 2 M | same as A + ~30 embedding batches | same as A |
| Supabase database compute | $0 incremental — existing Micro ($10, already committed). Hosted candidate-query capacity has not been measured; 1,000 readers ≈ 10k queries/day | +vector similarity, ~5–20 ms/query | same as A |
| Database storage | $0 — pool ≤ 60k rows ≈ 180 MB worst case (≈ 75 MB typical); feedback ≤ 1,000 rows/account | +~80 MB (512-dim vectors + index) | same as A |
| Egress | $0 — 0.33 GB (20 readers), 16.5 GB (1,000 readers) of 250 GB | same as A | same as A |
| Cloud Run | $0 — not used | $0 (B′ alternative below) | $0 |
| **Total incremental** | **No provider fee; expected $0 additional within remaining plan capacity, not a capacity guarantee** | **≈ $0.10 (20) / ≈ $0.15 (1,000); hard cap $1** | **C1 $25–68 regardless of readers (can exceed the $25 provider limit); C2 $6.60 → $330** |

- **Recommended: A now** (no provider fee, backend built), then consider **B** after two weeks of measuring A, with a **$1/month** feed embedding
  allowance inside the existing $25 provider limit — or **B′** (a small open embedding model in the request-billed
  worker on refresh: ~825 papers × ~15 ms ≈ 12 vCPU-s a day, inside Cloud Run's free tier, but it waits for the
  wake-on-work decision and adds ~130 MB to the worker image). On-device embeddings (Apple NaturalLanguage) are the
  way to use reading activity and chats privately (Phase 3).
- **C is not justified.** C1 costs more than the whole AI/OCR allocation for a quality gain the keyword rules and
  embeddings mostly cover; C2 is the per-reader scaling the owner asked to avoid. A narrower C (Haiku tags only for
  papers that reach someone's top 50, ≈ 200–400/day ≈ $10–25/month) still fails the cost test.
- Database, shared Edge/egress allowance and feedback storage must be measured with the rest of the product. At 1,000 readers, up to one million retained feedback rows are possible; the pool-only estimate above excludes them. Do not assume all Pro allowance remains available. If database compute becomes the bottleneck, if the candidate query's measured CPU passes
  ~50 % of Micro sustained, cache each reader's ranked list for 10 minutes before considering a compute upgrade
  (Small, +$15/month, an owner decision).

### Hard caps (server-side) and what happens when one is hit

| Resource | Cap (default) | Enforced by | When hit |
|---|---|---|---|
| Serving | `feed_policy.serving`: `off` (default) / `staff` / `all` | `worker_feed_candidates`, `worker_feed_category`, `v1_feed_feedback` | Off: `404 feed_unavailable`; the app hides For you and shows the chips as today; chips use live RSS |
| Refreshing | `feed_policy.refresh_enabled` (default off); interval 120 min (30–1,440); 5-min lease | `feed_refresh_kick`, `worker_feed_refresh_claim` | The pool ages; For you keeps serving it until the 14-day window is empty, then `feed_unavailable` |
| arXiv | One conditional request per due refresh; shared 3 s slot (≤ 20 s wait); 16 MB and 3,000 items per response | `feed-refresh`, `worker_pipeline_arxiv_slot` | Busy: retry in 10 min. Failure or oversize: back off 15 min → 6 h; the pool is unchanged |
| Pool size | 30 days, 60,000 rows | `worker_feed_upsert` prunes in every committed batch; finish also prunes | Oldest papers dropped |
| For you requests | Existing `discover` rate: 60/account/h, 600/environment/h | `worker_consume_request` | 429; the app shows its usual failure with Try again |
| Feedback | 120/account/h, 3,000/environment/h; 1,000 rows/account | `v1_feed_feedback` | 429; the oldest feedback is dropped past 1,000 |
| Response | 50 papers, abstracts ≤ 700 characters | `discover` | — |
| B (future) | Platform-funded metered operation per embedding batch through `worker_provider_attempt_begin` (`route: feed_embeddings`); a separate monthly allowance ($1) checked at claim | Database admission, like [provider spending](PROVIDER_SPENDING.md) | Refused or failed: those papers have no vector and are ranked by A's score; retried next day at most twice. The feed never fails for it |

## App and web (proposal; arrangement unchanged)

- **"For you" chip first**, selected when the Feed opens if the server offers it. The app learns that from the
  `feed.for_you` flag on any Feed response (remembered on the device), so nothing appears while the switch is off and
  no extra request is made. If For you later reports `feed_unavailable`, the chip disappears and the first category
  loads.
- **Why line**: List rows add one footnote line under the metadata, with a small sparkle symbol ("New · In your tag:
  RLHF"); the Table puts it in the title cell's second line before the first author ("In your tag: RLHF · Lin et al.").
- **Actions on For you rows**: long-press (right-click on the Mac) offers Add to library, **More like this**, **Not
  interested**, View on arXiv; List rows also get a trailing swipe **Not interested**. Not interested removes the row
  at once with one banner "Hidden · Undo" (the existing `StatusBanner`); More like this confirms with "We'll show
  more like this" and its menu item turns into "Less like this" (clears it). Category chips keep today's rows and
  menus.
- **Cold start**: one info line atop For you.
- **Mac**: same SwiftUI code (Catalyst); the menu bar gets no new items (row actions are context menus, like the
  Library's).
- **Web (For you proposal; the category Feed is already live):** extend the existing Feed tab with
  For you first, the same `discover?feed=for_you` and `v1_feed_feedback` calls, the reason line under
  each row, a row "…" menu with the same actions, keyboard support (↑/↓, Return to expand, `x` Not interested), and
  "new since last visit" from IndexedDB. Device-local reading activity in the browser could later re-rank the list
  on the page.

## Privacy

- Proposed notice text (gradstep.ai/privacy and Settings › Privacy & data), to add when serving goes to `all`:
  "**For you** in the Feed suggests new arXiv papers using what our servers already keep for your library — the papers
  you add, their public titles, authors and arXiv categories, their topic tags and the tags you give them — and the
  papers you mark *Not interested* or *More like this*. Our servers keep those Feed choices, like your tags; they are
  not end-to-end encrypted. Your conversations, notes, reading progress and the titles of PDFs you upload are not
  used. Suggestions are computed on our servers; no one else receives your interests. A paper is described as added by
  several readers only when at least three did."
- arXiv receives one shared request with no account information. No data goes to any new third party (option A).
- Feed feedback is deleted with the account (a trigger on account closure, so the reviewed deletion function is not
  re-wrapped) and lives in the private schema behind `security definer` RPCs, like tags.

## Rollout

1. Owner reviews this document and the decisions below.
2. Lead applies 043 to staging after an encrypted backup (after 042), generates `FEED_REFRESH_SECRET`
   (`.env.staging`), and deploys `feed-refresh` and `discover` (explicit `scripts/deploy-staging.py staging --skip-migrations --functions feed-refresh discover`; the routine
   function list deliberately does not include the unpublished refresh function yet). This command stores the
   Vault URL and dedicated secret and the function secret.
3. `select public.worker_set_feed_policy('off', true)` — refresh on, serving off. After 24 h check
   `worker_feed_status()`: one successful refresh per announcement day, mostly `not_modified`, pool ≈ 800 papers/day.
4. `worker_set_feed_policy('staff', true)` with a TestFlight build containing the app change: owner and support/tester
   roles see For you. Measure the candidate query on staging (p50/p95), adds and dismissals in aggregate.
5. Privacy notice updated, then `worker_set_feed_policy('all', true)`. Older builds are unaffected except that their
   category chips are served from the pool (same shape).
6. After two weeks, decide on B with measured numbers.

Rollback: `worker_set_feed_policy('off', false)`; the app returns to the chips on its next Feed load. The pool and
feedback stay until pruned (30 days) or account deletion; nothing else depends on them.

## Implementation (option A)

| Piece | Where |
|---|---|
| Schema, RPCs, cron kick, account-closure cleanup | `supabase/migrations/202610070043_personalized_feed.sql` |
| Pool refresh (RSS parse, topic rules, refresh loop) | `supabase/functions/feed-refresh/index.ts`, `_shared/feed-pool.ts`, `_shared/feed-topics.ts` |
| Ranking and reasons; For you and pool-served chips | `_shared/feed-rank.ts`, `supabase/functions/discover/index.ts` |
| Deployment wiring | `supabase/config.toml` (explicit refresh-function deploy only until rollout), `scripts/deploy-staging.py` (Vault + secret when `FEED_REFRESH_SECRET` is set) |
| App — planned, not implemented | `ScienceReaderCore/Discovery.swift` (reasons, `first_seen`, `feed` info), `Services/FeedPersonalization.swift`, `Views/ForYouViews.swift`, small hooks in `ReaderModel` (Feed section), `RootView` (`FeedView`, `DiscoveryRow`), `FeedTableView`, `BackendClient` |

Local takeover validation (2026-10-08 UTC): the full database/upgrade/concurrency suite passed before final
hardening; focused `test_feed.sql` plus `feed_concurrency.py` pass again after fixing full-account exclusions
and both account-closure race orders. Backend feed tests pass (23). Evidence is in the branch's private
`.artifacts/takeover/` logs. No hosted capacity or user-facing For you journey is claimed.

Ranking inputs stay capped at the newest 300 library papers, 50 active imports and 300 feedback choices.
Eligibility is separate: **all** owned papers (including archived), desired-present imports (including failed)
and retained Not interested choices are excluded through an account-indexed set. Feedback takes an account
share lock before rate windows and the per-account feedback lock, so closure either cleans a committed write
or causes a late write to fail; deleted feedback cannot be recreated by an in-flight request.

## Decisions for the owner

1. **Approve option A for staging rollout** (no paid API; expected to fit existing infrastructure, to be measured) and the rollout steps above.
2. **UI**: "For you" as the first chip and the Feed's default when available; the why line; More like this / Not
   interested in the long-press menu and the Not interested swipe; the "New" marker. (Additive; the Feed's
   arrangement is unchanged.)
3. **Privacy**: storing Not interested / More like this on the server (not end-to-end encrypted, like tags) and the
   notice text above; the "added by several readers" aggregate with a threshold of three.
4. **Category chips served from the shared pool** when the switch is on (stops per-user arXiv calls).
5. **Later, separately**: option B with a $1/month allowance (or B′ in the worker); onboarding topic picks
   (follows); on-device re-ranking with reading activity.

## Independent takeover review — 2026-10-08 UTC

A separate reviewer reproduced a storage-cap bypass when a refresh committed batches but died before
`worker_feed_refresh_finish`. The final implementation prunes retention and excess rows **inside every
claim-fenced upsert transaction**, using the same helper at finish. The sole upstream claim row serializes
pool writers; multiple upstream writers would require a reviewed common capacity lock. Real committed
400-row batches at a 1,000-row cap, abandonment, expired-claim replacement, and another batch all preserve
the cap and remove aged pool metadata. No reader library entries are pruned.

Independent review found no further blocking account-isolation, closure-lock, eligibility or default-activation
issues. Final focused SQL and true-session tests pass. Hosted query/Edge capacity and the proposed UI/privacy
choices remain activation gates; no paid ranking or public rollout was performed.

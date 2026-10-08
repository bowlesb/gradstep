# Personalized feed ("For you")

Status, 2026-10-08 UTC: **option A backend built and tested locally; build 21 feedback (specific topics, Topics and
Popularity columns) built locally for the server and iPhone/iPad; nothing new applied or deployed. Both server
switches remain off.** Migration `202610070043_personalized_feed.sql` was applied to staging at 2026-10-08 07:42 UTC
as the prerequisite to subscription repair044, after encrypted backup. Readback confirms `serving=off`,
`refresh_enabled=false`, an empty pool/feedback and no sources. The scheduled gate returns before network work; no
refresh function or personalized UI was deployed. Evidence: `.artifacts/takeover-20261008/feed-dark-deployment.json`.
Migration `202610080048_feed_topics_popularity.sql` (topics, popularity) is written and tested locally, **not
applied**. The owner accepted For you as the default and the use of server-visible library metadata on 2026-10-08
([decision](../DECISIONS.md#personalized-feed-owner-asked-2026-10-07-for-you-accepted-2026-10-08)); enabling serving
or refresh on staging is the lead's step after review ([enable steps](#enable-048-on-staging-lead)). The browser
(apps/web) and Mac-only polish moved to Codex on 2026-10-08; the [response contract](#discover-response-contract-for-clients)
below is what the web side builds on.

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

## Specific topics and popularity (owner feedback on build 21, 2026-10-08)

Owner, on the Feed's chips (screenshot: "Natural language processing", "Machine learning", "Computer vision"):
"Machine learning and artificial intelligence are too generic it need to be specific to the individual tastes and
their nuances". On the Columns sheet: "Why not topics? And can we put a popularity score?"

### Chips: For you, then the reader's own topics

- **For you is the first chip and the Feed's default** whenever the server offers it. The app learns that from any
  Feed response (`feed.for_you`) and keeps it on the device; on first use it tries For you once and falls back to the
  category chips on `404 feed_unavailable` (one request per install while serving is off).
- **Topic chips follow For you**, at most eight, ordered by the reader's interest. They are computed by the server on
  each For you request (`feed-interests.ts`, no model) from what it already holds for the library:
  - Candidates: the vocabulary tags on the reader's library papers (catalog tags minus removed ones, plus their own
    tags, normalized to vocabulary spelling), their own free-text tags, topics of papers marked More like this, and
    **curated combinations** of vocabulary tags with researcher names: *RL for reasoning* (Reasoning + RL / Policy
    optimization / Reward modeling), *Multimodal reasoning*, *Diffusion language models*, *Diffusion policies*, *Robot
    foundation models*, *Coding agents*, *Agent safety*, *Agentic RAG*, *LLM multi-agent systems*, *Efficient long
    context*, *Speech language models*, *Medical imaging*, *Graph transformers*, *Video world models*, *3D generation*
    (15; adding one is free). A library paper's narrower tag implies its broader one for matching combinations
    (Mathematical reasoning → Reasoning, Policy optimization → Reinforcement learning, …).
  - Interest: the sum of the library papers' weights (the ranking's: fading from 1 to 0.4 over months, archived half,
    own tags ×1.5, More like this 1.5 decaying over 90 days).
  - Evidence: at least two library papers, or a tag the reader gave, or More like this. Generic organizational tags
    ("to read", "important", …) never count.
  - Pool: at least two eligible papers in the 14-day window (not in the library, not Not interested) and **at most 20 %
    of the window** (so "Large language models" is not a chip). Counts come from `worker_feed_candidates_v2`.
  - **Broad category areas are never chips** (the 11 vocabulary areas that are an arXiv category's name: Machine
    learning, Natural language processing, Computer vision, Artificial intelligence, Robotics, …). Other areas
    (Recommender systems, Time series, AI safety, …) can be, at half weight.
  - Order: interest × specificity, where specificity = clamp(ln(1/share) / ln(100), 0.35, 1) — 1 at ≤ 1 % of the pool,
    0.5 at 10 %, 0.35 at 20 %. A single tag that a chosen combination explains (its interest ≤ 1.25× the
    combination's) is dropped, so *RL for reasoning* does not also show *Reasoning* and *Policy optimization*.
- **More topics** (a chip-styled menu after the topics) lists the broad arXiv categories: the library's own first, then
  the core ML ones, one per name. Picking one shows it as a selected chip while it is shown; its papers are newest
  first, as before. Without For you, the header is exactly the old category chips.
- Selecting a topic chip asks `discover?feed=topic&topic=NAME`: the server resolves the name to a combination, a
  vocabulary tag, or one of the reader's own tags (matched as a phrase; the database checks the tag is theirs), takes
  up to 300 eligible window papers with it, and ranks them with For you's ranking (no exploration slots; the topic
  itself is never the "why"). A chip that no longer exists returns `400 invalid_feed_topic` and the app returns to For
  you.
- Why the keyword rules and not a model: the pool's topics come from `feed-topics-v1` (curated rules mapping title and
  abstract onto the same vocabulary as catalog tags, tested on real abstracts), and the reader's side comes from the
  Haiku catalog tags they already have. No per-reader or per-request model call exists. The legacy app's free LLM
  keywords (`reference/web/lib/metadata.ts`, 5–10 per paper) drifted between papers, which is why tags became a
  vocabulary; combinations recover the useful multi-word phrases ("RL for reasoning") without that drift.

### Topics per paper

Every discover result now carries `topics`: up to four specific topics, most specific first (rule strength order),
other areas after them, and the broad category areas only when nothing more specific applies. Pool papers use their
stored rule topics; live RSS and search results are tagged on the fly with the same rules (pure TypeScript, no I/O).
The Feed table's **Topics** column (stored key `topic`, so saved column choices carry over) shows them as chips;
List rows show them in the details line. An older server's results fall back to the arXiv category names.

### Popularity: Hugging Face Papers upvotes

| Source | Checked 2026-10-08 | Used |
|---|---|---|
| **Hugging Face Papers** `GET https://huggingface.co/api/daily_papers?date=YYYY-MM-DD&limit=100&p=N` (in Hugging Face's published OpenAPI spec, `huggingface.co/.well-known/openapi.json`; no key) | 2026-10-07 listed **73 papers**, upvotes 162, 87, 75, 40 … (one request, 388 KB). Coverage is the community-submitted daily list: roughly 5–10 % of the ~825 new ML papers a day, the ones people are talking about | **Yes** — the Popularity value |
| Semantic Scholar `POST /graph/v1/paper/batch` (citationCount; unauthenticated) | Every paper from the last week had **0 citations** (the 162-upvote paper included); 2 of 4 unauthenticated requests from one workstation returned **429** ("apply for a key"), and Edge egress IPs are shared with other tenants | No: zero signal for new papers and an unreliable shared anonymous limit. Reconsider only for a longer window, with a dedicated free S2 key |
| arXiv listing | RSS/API carry no views, downloads or votes | No signal available |
| Gradstep's own "added by N readers" | Already the `popular` reason (≥ 3 readers, 14 days) | Kept as a reason, not shown as a number (privacy threshold, tiny beta) |

- **Rate limits and terms.** Hugging Face's Hub API limit is **500 requests per 5 minutes per IP for anonymous
  callers** (1,000 for a free account token), reported in `RateLimit`/`RateLimit-Policy` headers; over it, `429`
  ([Hub rate limits](https://huggingface.co/docs/hub/rate-limits)). The refresh makes **at most 12 requests per run**
  (six days × two pages, normally one page), one second apart, and runs at most every 2 hours (≈ 50–70 requests a
  day in steady state). Hugging Face's Terms of Service do not restrict reading this public API beyond its policies
  and limits; upvote counts are facts about public papers, shown with attribution ("Upvotes on Hugging Face Papers"
  in the Columns sheet, VoiceOver and the why line). No account information is sent: the request is a date.
- **When it runs.** Only inside the pool refresh (`feed-refresh`, pg_cron-woken, under the arXiv source's claim and
  before it is released), never per reader request. `worker_feed_signal_plan` chooses up to six listing days: days
  never fetched first, newest first; the last four days are re-read after 110 minutes (upvotes accumulate there);
  older days in the 14-day window once a day; a failed or throttled day waits ≥ 25 minutes. A 429 records the day
  as busy and ends the pass; two failed days end it. `worker_feed_signals_record` writes upvotes onto pool rows that
  exist (papers outside the pool are ignored), strictly validated. `feed_policy.popularity_enabled` (default on) turns
  only these requests off: `select public.worker_set_feed_popularity(false)`.
- **Unknown is a dash.** `upvotes` is null until the paper appears in a fetched daily list; it is never estimated and
  never 0 by default. The Popularity column shows "▲ 162" or "—", and its sort puts unknown last in both directions.
- **Ranking v2** (`feed-heuristic-v2`) adds `0.1 × min(1, ln(1+u)/ln(101))` to relevance (a 100-upvote paper gains
  as much as the "≥ 3 readers" aggregate), lets up to 30 well-upvoted eligible papers (≥ 5) into the candidate set,
  and gives a paper with ≥ 20 upvotes and no personal reason the why line **"Popular on Hugging Face Papers"**.
- **Cost:** $0 provider spend; a few hundred KB per request from Hugging Face; the pool's popularity state is one
  small table (≤ 90 days × one row) and two columns on pool rows.

### Discover response contract (for clients)

All Feed requests are `GET /functions/v1/discover` with the reader's session and `abstract=full` (newer clients). The
fields below are additive; older clients ignore them.

| Request | Response |
|---|---|
| `?feed=for_you&abstract=full` | `{ results: Result[], feed: { for_you: true, ranking: "feed-heuristic-v2", cold_start, refreshed_at, pool, topics: Chip[] } }` |
| `?feed=topic&topic=NAME&abstract=full` | `{ results: Result[], feed: { for_you: true, ranking, cold_start, refreshed_at, pool, topic: { name, kind } } }` |
| `?category=cs.CL&abstract=full` | `{ results: Result[], feed?: { for_you: true, refreshed_at? } }` — `feed` is present exactly when For you is offered to this reader |
| errors | `404 {code:"feed_unavailable"}` (For you not offered or empty pool: show category chips), `400 {code:"invalid_feed_topic"}` (chip no longer valid: go back to For you), `429` rate limit (`discover`: 60/account/h), `503` |

- `Chip`: `{ name: string (1–40 chars), kind: "combined" | "topic" | "own", papers: number }` in display order (most
  interesting first). Send `name` back unchanged as `topic=`.
- `Result`: `{ source_id, revision, title, authors[≤12], year, abstract (≤700 preview), full_abstract?, abstract_truncated?,
  categories[≤12], topics: string[≤4], upvotes: number | null, reason?: { kind, label, text }, first_seen?, announced? }`.
  `reason` is present on For you and topic results; `kind` is one of `author`, `tag`, `more_like`, `added`, `popular`,
  `trending`, `category`, `explore` (show `text`; the kind only picks a symbol). `upvotes` is Hugging Face Papers
  upvotes, `null` when unknown (show "—"). Pool-served results set `abstract_truncated: true` only when the pool had to
  shorten the abstract (2,000 characters; arXiv allows 1,920).
- Category chips are served from the pool (with `topics` and `upvotes`) when the reader is served and the pool is
  fresh, including `abstract=full` requests (this stops per-reader arXiv requests); otherwise live RSS with `topics`,
  and `upvotes` from the pool when the reader is served.
- The web client should mirror iOS: For you first and default when `feed.for_you`, chips from `feed.topics`, More
  topics for the library-derived categories, a why line from `reason.text`, topics and "▲ n"/"—" per paper, and sort
  options Suggested (server order, For you/topics only), Newest, Popularity.

### Optional one-time labeling pass (not run; question for the lead)

A free alternative is already in place; this would only measure and tune it. **Proposal:** tag a sample of **500 pool
papers once** with the existing Haiku catalog tagger (same prompt and vocabulary as library papers) through Message
Batches, compare with `feed-topics-v1`, and tune the keyword rules from the disagreements (precision/recall per tag),
then bump the rules' version. Cost from the measured $0.0038 per paper (TAGS.md) at the Batches discount (−50 %):
**≈ $0.95 total, hard cap $1** through a platform-funded hold; no recurring cost. Expected benefit: modest — mainly
recall of specific topics phrased unusually in abstracts. Recommendation: run it only if chips on the first real
pool look thin or noisy. It needs the pool (refresh on) first.

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

## App and web (arrangement unchanged)

Built for iPhone and iPad (2026-10-08, local; Simulator-verified, not shipped): the For you chip, topic chips, More
topics, the why line, and the Topics and Popularity columns. Not built yet: More like this / Not interested actions,
the "New" marker. The browser reader and Mac-only polish are Codex's (owner, 2026-10-08); the Catalyst build compiles
the same SwiftUI code.

- **"For you" chip first**, selected when the Feed opens if the server offers it. The app learns that from the
  `feed.for_you` flag on any Feed response (remembered on the device). Before it knows, it tries For you once and, on
  `feed_unavailable`, remembers that and loads the first category, so the category chips work as before. If For you
  later reports `feed_unavailable`, the chip disappears and the first category loads.
- **Why line**: List rows add one footnote line under the authors, with a small sparkle symbol ("In your tag:
  RLHF"; an arrow for "Popular on Hugging Face Papers"); the Table puts it in the title cell's second line before the
  first author ("In your tag: RLHF · Lin et al.").
- **Columns** (Feed › … › Columns): Popularity ("Upvotes on Hugging Face Papers", "▲ 162" or "—"), Topics ("Its
  specific topics, from title and abstract"), Published, Authors, arXiv ID, Abstract. Popularity and Topics are on by
  default; readers who saved column choices before build 22 get Popularity once (a "seen columns" record makes turning
  it off stick). Sort by adds Popularity, and Suggested (the server's ranking) for For you and topics, which is their
  default; categories stay newest first.
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
| Topics and popularity (048) | `supabase/migrations/202610080048_feed_topics_popularity.sql`, `_shared/feed-signals.ts` (Hugging Face), `_shared/feed-interests.ts` (chips, combinations), `displayTopics` in `_shared/feed-topics.ts`, ranking v2 in `_shared/feed-rank.ts`, `discover` and `feed-refresh` |
| App (iPhone/iPad) | `ScienceReaderCore/Discovery.swift` (topics, upvotes, reasons, `feed` info), `Services/FeedPersonalization.swift`, `Views/FeedTableView.swift` (columns, chips bar, why line), small hooks in `ReaderModel` (Feed section), `RootView` (`FeedView` header, `DiscoveryRow`), `TableColumns` (introduced columns), `BackendClient` |
| Tests | `tests/database/test_feed_topics_popularity.sql`, `tests/backend/feed-personal.test.ts`, Core `DiscoveryTests`, app `FeedPersonalizationTests`, `PaperTableTests`, UI `FeedForYouTests` |

Local takeover validation (2026-10-08 UTC): the full database/upgrade/concurrency suite passed before final
hardening; focused `test_feed.sql` plus `feed_concurrency.py` pass again after fixing full-account exclusions
and both account-closure race orders. Backend feed tests pass (23). Evidence is in the branch's private
`.artifacts/takeover/` logs. No hosted capacity or user-facing For you journey is claimed.

Ranking inputs stay capped at the newest 300 library papers, 50 active imports and 300 feedback choices.
Eligibility is separate: **all** owned papers (including archived), desired-present imports (including failed)
and retained Not interested choices are excluded through an account-indexed set. Feedback takes an account
share lock before rate windows and the per-account feedback lock, so closure either cleans a committed write
or causes a late write to fail; deleted feedback cannot be recreated by an in-flight request.

## Enable 048 on staging (lead)

Prerequisites: review of this branch; encrypted backup as for 043. Nothing below spends provider money.

1. Apply `202610080048_feed_topics_popularity.sql` with `scripts/migrate-supabase.py` (after 045–047; it depends only
   on 043 and 030). Read back: `select public.worker_feed_status()` shows `policy.popularity_enabled=true`,
   `pool.with_upvotes=0`, `popularity.days=0`; switches unchanged.
2. Deploy the functions explicitly: `scripts/deploy-staging.py staging --skip-migrations --functions feed-refresh discover`
   (migration before functions: the new `discover` calls `worker_feed_candidates_v2`, `worker_feed_category_v2` and
   `worker_feed_details`; category chips fall back to live RSS if 048 is missing, For you would answer 503).
3. Refresh on, serving off: `select public.worker_set_feed_policy('off', true)`. Within ~30 minutes the cron kick wakes
   `feed-refresh`; check `worker_feed_status()`: `sources[0].last_status` `updated`, pool ≈ 800 new papers per
   announcement day, `popularity.ok` ≥ 1, `pool.with_upvotes` > 0. Edge logs: `event: popularity` with
   `requests ≤ 12`, no `busy`.
4. Staff serving with a build containing this app change: `select public.worker_set_feed_policy('staff', true)`.
   Check For you, two topic chips and the Popularity column on a tester account; measure `worker_feed_candidates_v2`
   (p50/p95; it now also counts topics over the window).
5. Rollback: `worker_set_feed_policy('off', false)`; popularity alone: `worker_set_feed_popularity(false)`.

**Cost statement.** Expected provider spend **$0** (no model; Hugging Face and arXiv are free, unauthenticated).
Supabase: two to three more database calls per For you request (candidates v2, details; topic counts add one pass over
the ≈ 10,000-row window inside the same call), one more per topic chip; ≤ 12 Hugging Face requests and ≤ 7 small
writes per refresh run; pg_cron unchanged (one job every 30 minutes that usually does nothing); storage ≈ 16 bytes per
pool row plus ≤ 90 rows of day state. Hosted query cost is unmeasured until step 4.

## Decisions for the owner

1. **Approve option A for staging rollout** (no paid API; expected to fit existing infrastructure, to be measured) and the rollout steps above.
2. **UI**: decided 2026-10-08 — "For you" is the first chip and the Feed's default when available, with the why line
   (built). Still proposed: More like this / Not interested in the long-press menu and the Not interested swipe; the
   "New" marker. (Additive; the Feed's arrangement is unchanged.)
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

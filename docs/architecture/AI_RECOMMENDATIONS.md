# AI recommendations (similar papers, added for you)

Status, 2026-10-21: **designed and implemented on a branch; not deployed.** Migration
`202610210143_recommendations.sql`, Edge function `recommend`, native iPhone/iPad/Mac and browser clients. The deploy
steps and the one paid live check are at the end. Proposal and owner exchange: [proposal](../proposals/AI_RECOMMENDATIONS.md).

Owner, TestFlight 78 (2026-10-21): "I want two more features: an AI recommendations, it uses AI with our server to search
for the most similar papers and just adds them, users should have the option of requesting 1, 3 or 5." On the proposal's
open questions: "For your similar papers, just take your best judgement, and try to create a good experience out of it."
"Chat about this paper" (the proposal's second part) is not covered by that answer and is not built here.

## Decisions (agent, under the owner's delegation; reversible)

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | Review first, or add at once? | **Add at once**, then show what was added with a reason each, **Remove** on each paper and **Undo** for all. | The owner asked for "just adds them". Showing the picks while they arrive, with one tap to take any back, keeps that speed without the reader wondering what changed in their library. A review step would turn one tap into a second screen and a second decision. |
| 2 | How many? | **1, 3 or 5** (the owner's numbers), as three rows of one submenu. | No new screen to choose; a count above 5 would flood the library. |
| 3 | Price | **1 credit per request, whatever the count, charged only when at least one paper was added.** Shown before the tap ("1 credit") and after ("Added 3 papers · 1 credit"). Undo does not refund. | One model call costs the same for 1 or 5 (~$0.002 measured at Haiku's card for the bounded prompt; 1 credit = $0.005). A flat price is easy to state up front. A refund on Undo would need the server to tie library removals back to a request; the amount is a fifth of a cent. |
| 4 | Limits | **20 requests per account per rolling 24 h** (database, `recommendation_policy.daily_runs`) and **30 an hour** at the request gate (`api_rate_rules`), plus the existing 3 open operations per account, platform budget and testing caps. | Server-side only, as AGENTS.md requires. 20/day is far above a reader's use and caps a runaway client at ~$0.04/day. |
| 5 | Model | **Claude Haiku 5.5 through OpenRouter** (Google Vertex US, the route and card catalog tags already use), reasoning off, at most 700 output tokens, structured JSON whose `id` must be one of the candidates. | Cheapest Claude, already priced and admitted (`openrouter_tariffs`), good at short English judgements; it can only choose among real papers, never invent one. |
| 6 | Where do candidates come from? | **No model**: DataCite searches built from the paper's keywords (as Find similar papers does) plus the shared Feed pool's full-text index, merged, de-duplicated and stripped of everything already in the reader's library, then capped at 40. | Servers never contact arXiv (ARXIV_DEVICE_ONLY.md); DataCite and the pool are the allowed server sources. The model only ranks and explains. |
| 7 | What is excluded? | Every paper the reader has or had: every import (any phase, removed included), every library item (removed included), papers marked **Not interested** in the Feed, and the seeds. | Never suggest what the reader already has, and never bring back what they removed. |
| 8 | Which catalog? | **The catalog the reader is viewing**, like any Add. | Respects the current catalog. A separate "Recommended" catalog would hide the papers from where the reader just asked for them; the owner asked that they be added. |
| 9 | Where it lives | Directly under **Find similar papers** in the Library row menu, Paper ⋯ (iPhone/iPad/Mac and browser) and Mac's Paper menu: **Recommend similar papers ›** with **Add 1 paper**, **Add 3 papers**, **Add 5 papers** and the price as the section's note. The Library's ⋯ menu gains **Recommend for this catalog ›** with the same three rows. | Next to the feature it extends; one tap. The catalog entry is the "whole library" option, scoped to what the reader is looking at. |
| 10 | While it runs | A sheet (medium height on iPhone, a popover-sized sheet on iPad/Mac, a dialog in the browser): "Finding papers like *title*…", then each paper as it is added with its reason, an × to remove it, then "Added 3 papers to *catalog* · 1 credit", **Undo**, **Done**. Closing the sheet early does not stop the request: the papers are still added (server-side), and the reader sees them in the Library. | Streams results as they arrive; makes the change visible and reversible in the same place. |
| 11 | Why shown | One line per paper, at most ~14 words, naming the specific connection to the source paper or, for a catalog, to the library paper it relates to. Kept on the server with the request (for replays and for a later "Why recommended" in Paper ⋯); not yet shown after the sheet closes. | Trustworthy without clutter. Persisting the reason on the Library row needs a library wire change; recorded below as a follow-up. |
| 12 | Which papers can seed it? | Papers the server has details for: arXiv and open-access web papers in the reader's library. Not local PDFs (their title never leaves the device), not samples, not while signed out. | Privacy boundary unchanged. |
| 13 | Consent | No new consent screen. | Only public catalog metadata (titles, abstracts, author names of the source and candidate papers) is sent, the same class as catalog tags (TAGS.md). Settings › AI credits' "How credits are used" lists the feature and its price; the privacy line below states what is sent. |

## Flow

```
device ──POST functions/v1/recommend {operation_id, count, scope, seeds:[{source_id, keywords}]}──▶ recommend (Edge)
  1. auth, body bounds, request gate `recommend` (30/h per account)
  2. worker_recommend_begin          — replay? daily limit, seeds from the reader's own library, exclusions,
                                        hold (kind `recommend`, 1 credit, $0.015 ceiling), run row `running`
     ◀── data: {"type":"status","phase":"searching"}
  3. candidates (free): DataCite relevance search per keyword (≤3 queries, 20 each, 8 s) +
     worker_recommend_pool (Feed pool tsvector, ≤20) → merge, drop excluded, ≤40
     ◀── data: {"type":"status","phase":"choosing","candidates":34}
  4. one admitted OpenRouter call (route `chat`, feature `recommend`, Haiku 5.5): streamed JSON; each complete pick is
     parsed as it arrives →
  5. v2_add_paper_once(derived operation id, source_id) as the reader (idempotent per request and paper)
     ◀── data: {"type":"paper","ordinal":1,"paper":{source_id,revision,title,authors,year,reason,status,import_id}}
  6. worker_recommend_finish         — picks recorded, settled: 1 credit if any paper was added, else 0
     ◀── data: {"type":"done","added":3,"requested":3,"credits":1,"charged":true}
```

- **Streaming.** `text/event-stream`, one JSON object per `data:` line, `: ping` every 15 s. Errors after authentication
  are `{"type":"error","code":…,"charged":false}` events. Codes: `invalid_request`, `rate_limited`, `daily_limit`,
  `insufficient_credits`, `platform_budget_exhausted`, `seed_unavailable`, `search_unavailable`, `model_unavailable`,
  `in_progress`, `unavailable` (switched off), `service_unavailable`.
- **Nothing related.** When the model picks none, or no candidate survives the exclusions, the stream ends with
  `done {added: 0, reason: "none_related"}` and nothing is charged.
- **The work outlives the connection.** Like chat (`EdgeRuntime.waitUntil`), a closed sheet or a dropped connection does
  not stop the adds or the settlement. Sending the same `operation_id` again replays a finished request (its papers and
  `done`, no new charge, no new call) or answers `in_progress`.
- **Idempotent adds.** Each add's import id is derived from the request and the paper
  (`sha256(["gradstep/recommend-add/v1", operation, source_id])` as a UUID), so a retry never queues a paper twice;
  `v2_add_paper_once` also answers `present` for a paper the reader already has. Each added import uses the reader's
  own library rate limits.
- **Catalog.** Catalog assignments are encrypted on the device (LIBRARY_CATALOGS.md), so the client writes each added
  paper's assignment (`source:<id>` key) to the catalog it was viewing when the reader tapped, as it does after any
  server Add (`addPaperOutcome`), then refreshes the library.
- **Undo / Remove.** The client removes through the normal library paths (cancel the import, or remove the item once it
  has become one). Nothing new on the server.
- **Stale requests.** A run left `running` (a killed function) is settled uncharged by the stale sweep
  (`worker_expire_stale_chat_operations`, which now also covers kind `recommend` after 30 minutes) and by the account's
  own next request after 10 minutes, so its hold never blocks the reader.

## Data

Migration `202610210143_recommendations.sql` (additive):

- `metered_operations.kind` admits `recommend`.
- `app_private.recommendation_policy` (singleton): `enabled` (on), `daily_runs` 20, `credits` 1, `hold_microusd` 15,000.
- `app_private.recommendation_runs` (account, operation id = the metered operation, request digest, seeds, requested
  count, scope, state `running|finished|failed`, picks ≤5 `{source_id, title, reason, status, import_id}`, added, credits,
  failure code, times). Library-membership-class data, server-visible like the library itself, not end-to-end
  encrypted. Deleted with the account (`worker_delete_account_begin`, counted by `worker_account_deletion_status`);
  the operation and its provider attempts stay as the de-identified billing record.
- `api_rate_rules` `recommend` (3600 s, 30 per account, 600 for the service).
- Functions (service role only): `worker_recommend_begin`, `worker_recommend_pool`, `worker_recommend_finish`;
  `worker_expire_stale_chat_operations` extended; `app_private.cost_feature` maps feature `recommend` to
  `recommendations` (Admin › Costs); `admin_health_extra` adds `recommendations` (runs, papers added, charged and
  failed, last 24 h and 30 days) for Admin › Health.

No provider-route change: Haiku 5.5 on route `chat` is already admitted for non-podcast operations, with its tariff row.

## Prompt (bounded)

System: what to choose (the papers someone reading the source would most want next: the work it builds on, direct
follow-ups, strong alternatives on the same problem; avoid duplicates and surveys unless nothing else fits; fewer than N
when fewer are genuinely related) and how to write the reason (plain, specific, ≤14 words, no hype). User: the source
paper (title, ≤3 authors, ≤1,500 characters of abstract) or, for a catalog, up to 8 library papers (title, ≤300
characters), then up to 40 candidates as `[cN] title (year) — authors` and ≤600 characters of abstract. The hold is
computed from the actual request (`holdForParams`); candidates are dropped from the end until it fits the operation's
$0.015 ceiling. Measured size: ~14k input tokens, ~250 output tokens ≈ $0.0017 at Haiku 5.5's Vertex card.

## Privacy

Sent to OpenRouter (Anthropic's Claude on Google Vertex): the source paper's or catalog papers' public title, authors
and abstract, and the candidates' public titles, authors and abstracts; the account UUID as OpenRouter's `user`. Not
sent: the reader's other papers (except the catalog's own seeds for a catalog request), chats, notes, keywords' origin,
catalog names or reading history. No zero-retention claim is made. DataCite receives only the search words.

## Budget

At 1,000 requests a month ≈ $2 of the $25 metered-provider allowance inside the $100/month private-beta budget; no
fixed commitment. The reader pays 1 credit ($0.005) per request that adds papers; the platform absorbs failures.

## Tests

- `tests/database/recommendations.sql`: begin/finish/replay, daily limit, seeds only from the reader's library
  (another account's paper refused), exclusions (removed and Not interested included), pool search, settlement (1
  credit only when added, none otherwise), stale sweep, account deletion, grants, cost feature, health block.
- `tests/backend/recommend.test.ts`: request validation, candidate merge/exclusion/cap, prompt bounds, incremental pick
  parsing, the whole run with fakes (events in order, adds idempotent, settlement), replay, failures uncharged, and
  the real OpenRouter adapter's attribution (`feature: recommend`, Haiku, Vertex route).
- Native: `RecommendationsTests` (model: catalog assignment, Undo/Remove, event decoding) and the UI journey
  `RecommendationJourneyTests` with `--recommend-fixture` (no network). Browser: unit tests and `recommend.spec.ts`
  (desktop and phone) against the fixture backend.

## Follow-ups (not built)

- "Why recommended" after the sheet closes (Paper ⋯), read from `recommendation_runs`.
- Better candidates through embeddings over the Feed pool (PERSONALIZED_FEED.md option B).
- "Chat about this paper" (the proposal's second part) awaits the owner.

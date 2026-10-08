# Paid AI chat

Status 2026-10-05: deployed to staging and verified live (API smoke and the Simulator journey: consent, streamed paid answer with typeset math, relaunch). Ingest verified live through the API (DPO passage citing PPO → arXiv 1707.06347 queued, 26 credits); its Simulator path is covered by unit tests only.

## Contract: `POST functions/v1/chat`

- Auth: user JWT verified in the handler (`verify_jwt = false`, `userClient`); RPCs run as service role. Origin/method/auth failures are HTTP JSON `{code}`; after authentication every outcome is `200 text/event-stream`.
- Body (strict, unknown keys rejected, ≤ 512 KiB raw): `{operation_id: uuid, consent_version: "cloud-ai-v1", mode: "paper"|"general", document_id?: uuid (paper only), messages: [{role: "user"|"assistant", text}] (1–60, first and last user, non-empty, ≤ 200,000 UTF-8 bytes total), selection?: {quote ≤ 4,000 Unicode scalars}, action?: "ingest" | "related" | "relevance" (each requires a selection) | "diagram_fix" (general mode, exactly one user turn ≤ 24,000 bytes, no selection), capabilities?: ["web_import"] (≤ 8 strings ≤ 32 characters; unknown values ignored)}`.
- Events: `delta {text}`, `diagram {title, source}`, `status {kind, query?}` (2026-10-07, below), `done {stop_reason, credits, usage}`, `error {code}` with codes `insufficient_credits`, `platform_budget_exhausted`, `rate_limited` (route limit or 3 active operations), `document_unavailable`, `provider_unavailable`, `refused`, `invalid_request`, `operation_replayed`, `service_unavailable`. Comment lines (`: ping`) every 15 s keep idle connections open.
- Order: `worker_consume_request(account,'chat')` → validate → paper context (`worker_chat_context` → Storage `standalone.mmd`, ≤ 2 MiB, strict UTF-8) → hold → `worker_reserve_operation` → stream → `worker_settle_operation` → `worker_record_provider_usage` → final event.

## Provider request

`@anthropic-ai/sdk` 0.131.0 (`npm:` import map entry and root `package.json`). Model `claude-sonnet-5-5`, `max_tokens` 8,000, adaptive thinking at effort `low` (the model guidance for chat; it skips thinking on simple turns and keeps time-to-first-token and cost low), thinking display omitted. Server-side refusal fallback `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`); for this model it retries `cyber`/`frontier_llm` declines on Claude Sonnet 5, which matters for an ML-paper reader. Final `stop_reason: "refusal"` becomes `error refused`. System prompt = short instructions (cite sections/equations, LaTeX with `\( \)`/`\[ \]`, no "Answer:" label since 2026-10-07) + `<paper title>` MMD block with `cache_control: ephemeral` (cached prefix). The selected passage is a separate text block before the last question. One SDK retry; a 130 s generation deadline leaves time to settle inside the Edge wall-clock limit.

## Ingest (selection action)

The existing Ingest action ("Find and add the paper referenced in this passage") sends `action: "ingest"`. Only then
does the request carry one client tool, `add_paper {title, year?, first_author?, arxiv_id?}`, plus instructions to
identify the referenced paper (using the paper's bibliography for in-text citations) and call the tool once. It stays
a single provider call, so the hold and settlement are unchanged (the tool schema counts toward the hold).

After settlement, and only when the turn ended in the tool call (`stop_reason: tool_use`, calls after the last
fallback block), the server validates the input strictly and searches arXiv through the shared pacing (optional id
lookup, oldest-first title phrase, then all title words; one paced request at a time, stopping at the first match).
`matchPaper` accepts a candidate only with a near-identical title (token F1 ≥ 0.9, or an exact main title of 3+
words before a colon), the cited year within [year−3, year+1], the cited first author among the first three
authors, and no negation-word difference; without an author the title must be exact, and titles under four words
need author and year. A visible library entry or active import for that source reports "already in your library";
otherwise `v2_begin_import` runs **as the user** (their JWT; the app starts chat streams with ≥ 5 minutes of token
validity), exactly like the app's Add, so normal conversion, credit holds and quotas apply. Post-settlement work has
a 45 s budget; Stop cancels it and nothing is imported. Results are appended as inert text: queued, already in the
library, not found, search unavailable, not openly available (with an https link), needs a newer app, or could not
be added. A `tool_use` stop is reported as `end_turn`.
The app refreshes the library when an Ingest answer completes. Paper text could steer the model to a different
title (prompt injection); the bound is one strictly matched paper per explicit Ingest, which the reader can
cancel in the Library.

**Web papers** (migration 019, [decision](../DECISIONS.md#ingest-adds-papers-from-the-web-owner-asked-2026-10-05)).
When arXiv has no match, OpenAlex is searched (cited title, year ±1). Among strictly matching works, one with an
arXiv copy wins (imported through arXiv), then one with an open-access PDF not on arXiv, then any. An open-access
match is added with `v2_begin_web_import` (source `openalex:W…`) **only if the request carries
`capabilities: ["web_import"]`** (body field; unknown capability values are ignored, malformed ones rejected; part
of the request digest when present). The app sends it on Ingest requests from builds that show web papers. Older
builds get "needs the latest Science Reader version"; a match without an open copy gets "isn't openly available".
The presence check reads `v3_library_page` (all sources). The paper worker then reads the work from
`api.openalex.org` itself (metadata and up to three open-access PDF locations, never arXiv-hosted) and converts a
private copy for the account; see [pipeline](PAPER_PIPELINE.md#web-papers) and the hardened download in
`supabase/functions/_shared/web-source.ts`.

## Diagrams

Ordinary (non-Ingest) requests carry one client tool, `create_diagram {title, mermaid}`, with instructions to use it
only when the reader explicitly asks for a diagram, after the text. After settlement and only on a `tool_use` stop,
the server validates the input (title ≤ 120 characters, source ≤ 12 KB starting with a known Mermaid diagram type)
and relays it once as an SSE `diagram {title, source}` event before `done`; it stores and logs nothing of it. The
device keeps it only with a complete answer, sealing an encrypted `diagram` event (`ChatDiagram`, format
`mermaid-v1`, with the answer's message entity ID) in the same batch as the answer. The answer shows "View diagram";
Settings/Library → All diagrams lists saved diagrams. Rendering is on device with the bundled Mermaid 12.1.0
(`scripts/vendor-mermaid.mjs`, hash-pinned) in a web view whose page allows no scripts, network or navigation;
Mermaid runs in `securityLevel: 'strict'` from an app-owned user script. This restores the legacy app's diagrams in a
narrower form (Mermaid only; no arbitrary HTML/SVG).

**Fewer broken diagrams (2026-10-07).** The diagram instructions and the tool description carry the legacy app's Mermaid
label rules (ASCII labels, quote labels with punctuation, safe characters, no `end` IDs). Before a diagram is kept, the
device parses it with the bundled Mermaid (`mermaid.parse`, in an off-screen web view set up like the drawing one;
`MermaidCheck`). One that fails is sent back **once** as a separate request, `action: "diagram_fix"`: general mode, one
user turn (`Title: …`, `Mermaid error: …` ≤ 600 characters, the source), no conversation, paper, selection or search;
instructions to call `create_diagram` with the same content made valid; **2,000 output tokens** (`DIAGRAM_FIX_MAX_TOKENS`).
It is metered like any answer — its own operation, held for the request and its 2,000-token output allowance, then
settled at actual usage, logged as `chat_answer` with `action: "diagram_fix"`. The deterministic test’s
1,400-input/600-output-token example costs 2 credits ($0.0088 provider spend); live repair cost has not been
measured. The answer shows "Fixing
the diagram…" meanwhile and is saved with the corrected source if that parses, else with the original (the answer's
title is kept). A correction is used only after a successful final event: a lost stream, failure or truncated
response keeps the original and does not start a second repair. A request that fails (no credits, an older server)
also keeps the original. A diagram that still cannot be
drawn says "Couldn't draw this diagram", with its source collapsed. Server-side parsing was ruled out: Mermaid
12.1's parser bundles to 5.25 MB minified (over the 5 MB server-side bundling limit before the function's own code)
and its flowchart parser needs a DOM (DOMPurify).

### Chat-quality validation — 2026-10-07, local only

The recovered chat branch includes main through `7327ff3` (reader navigation and offline recovery). Verified:
224 backend tests, the chat Edge function's Deno type check, 213 Core tests, 48 selected app regressions (chat
ownership, outcomes, drafts, titles and history), six chat-history UI journeys, the broken-diagram journey and
opening/reopening a valid diagram. The real bundled Mermaid parser is exercised in Simulator. The formerly
reported broken-diagram failure did not reproduce on the first clean run; its test now dismisses the keyboard
before sending so the brief "Fixing the diagram…" state cannot finish during keyboard dismissal. A separate
regression rejects a valid correction frame followed by failure, EOF or `max_tokens`, keeping the completed
answer and original source without another repair.

The conversation title now fits the actual space between History and New chat. Toolbar items have separate
SwiftUI hosting roots; a small UIKit background measures their shared window coordinates after layout, including
pane resizing. The visible label truncates to that space because a toolbar Menu otherwise keeps its intrinsic
label width. The saved title and VoiceOver label remain complete. iPhone geometry assertions pass. The iPad resize journey also passes with title bounds checked at the default,
minimum (300 pt), widened and relaunched widths, including hide/show and rotation; its screenshots were inspected
under `.artifacts/chat-ipad-header-attachments/`. Dark screenshots of diagram failure, the paper-chat menu and This paper history were captured and inspected under
`.artifacts/visual/chat-quality-20261007/iphone-dark/`. A universal Mac Catalyst build passes; this is compile
coverage, not a signed-in Mac runtime check.

No provider requests were made for this review; repair pricing and real-model success rates are unmeasured.
The app's new `relevance` and `diagram_fix` actions require deploying the matching chat function before shipping.
When combined with the pending spending controls, preserve the 2,000-token repair ceiling and both actions'
search exclusion; its conservative per-attempt admission replaces the earlier character-based hold.

## Web search (on in staging)

Search is on when `CHAT_WEB_SEARCH=on` (`infra/<env>.json` `chat_web_search`, or `deploy-staging.py --chat-web-search on|off`;
on in staging since 2026-10-05). Two providers (owner decision 2026-10-06, [decisions](../DECISIONS.md#web-search-providers-and-pricing-owner-decided-2026-10-06)):

- **Tavily, primary** — `search_web`, a client tool the chat function runs (`_shared/tavily.ts`): a basic search
  (1 Tavily credit), 5 results, each cut to 1,500 characters (≈2.5k tokens per search, against ~10k for Anthropic's
  search), `academic: true` restricts to scholarly sites (arXiv, OpenReview, ACL Anthology, proceedings, journals).
  Results return as `search_result` blocks with citations **off** (2026-10-08): turning citations on mid-answer
  invalidated the prompt cache after the tool definitions, so the round after the searches rewrote the whole paper
  (staging: `cache_read` 0 and ~15k–56k tokens written again). Claude names its sources itself (below).
  Used only when the request carries consent `cloud-ai-v2` (whose text names Tavily), `TAVILY_API_KEY` is set, this
  instance has not paused Tavily after a failure, and the Tavily credits recorded in the last 31 days are under
  `TAVILY_SEARCH_ALLOWANCE` (default 3,900 of the plan's 4,000; `worker_provider_units_recent`, migration 021).
- **Anthropic's `web_search_20250305`, backup** — used when Tavily is not available for an answer, for consent-v1
  builds (TestFlight ≤ 11), and mid-answer: if a Tavily search fails, its result tells Claude to use `web_search`,
  which is added for the rest of the answer with the remaining allowance. (`web_search_20260209` is not used: its
  dynamic filtering ran model-written code that failed in production on 2026-10-06.)

Answers run in **rounds**: a round that ends in `search_web` calls is answered with their results (searches in one round
run in parallel) and the answer continues, the next round starting a new paragraph. All rounds share one 8,000-token
output allowance; each round's input ends with one cache breakpoint so the next round reads it from the cache. At most
3 searches per answer (5 for Related), counting failed ones; extra calls get "No searches are left" and the answer
ends after one more round. A `pause_turn` from a long Anthropic search turn is sent back to continue it. Calls from
any completed round (a diagram drawn alongside a search) are delivered.

Failures pause Tavily on that function instance: plan or pay-as-you-go limit (HTTP 432/433) 6 h, bad key 1 h,
rate limit `Retry-After` or 60 s, outage or timeout (after one quick retry) 2 min; a rejected query does not pause.
Every failure is logged as `chat_search_failed` (provider, failure code; never the query).

**Pricing (rate card, `beta-credits-v1`):** a reader pays for what an answer would cost at list prices, whichever
provider served it: tokens at 2×, Anthropic's $0.01 per search at 2×, and Tavily's pay-as-you-go $0.008 per credit at
2× (1.6 credits per search). **Provider spend** (the `platform_budgets` cap) counts tokens and Anthropic's per-search
fee; Tavily searches inside the prepaid plan add nothing (it is a fixed commitment, [operations](OPERATIONS_AND_BILLING.md#fixed-commitments)).
Settlement passes the two amounts separately (credits from the priced amount, micro-USD from the spend). The hold
is sized for Anthropic's search (per search: the fee, a pass over the whole prompt at the cache-write rate, two reads
of 30k result tokens), which also bounds Tavily rounds and a mid-answer switch; for DPO (27 pages, ~40k prompt
tokens) it goes from 108 to 245 credits, capped at the balance from 50 credits. Usage: the Anthropic event as before
(`web_searches` = Anthropic searches) plus, when Tavily ran, a `tavily` event (`operation:<id>`, model `search-basic`,
units `searches`, `credits`, `failed`, `list_microusd`; 0 micro-USD). `chat_answer` logs `search_provider`,
`web_searches` (both providers), `tavily_searches`, `search_failures`, `failover` and `sources`.

Measured on staging with Anthropic's search (2026-10-06, four answers): $0.06–$0.12 provider cost per searched
answer (12–24 credits), mostly result tokens (15–35k input tokens). Tavily figures: see
[decisions](../DECISIONS.md#web-search-providers-and-pricing-owner-decided-2026-10-06).

Sources: answers end with a "Sources:" list (`N. Title — https://…`) that the app shows as tappable sources (a tap
shows the full address and asks before opening Safari); when the answer writes no list, the server appends Anthropic
search's citations or, for Tavily, the searched pages (each search's best first, at most 8). Consent `cloud-ai-v2` (build 12+) says queries go to Tavily, or Anthropic's search
provider as a backup, and that search services see only the searches; accepting v1 does not cover Tavily, so newer
builds ask once more.

## Progress (`status` events, 2026-10-07)

While an answer waits on server work, the stream carries `status {kind, query?}` (legacy gap 9):
`searching` (with the query, a single line of at most 200 characters) when a Tavily `search_web` call is about to run
or when Anthropic's server-side `web_search` block ends (its query streams in as the block's input; an unreadable
input reports `searching` without a query); `reading` when a Tavily round's results are in (at least one search
succeeded) or Anthropic's `web_search_tool_result` block starts; `finding_paper` before the Ingest lookup and
`adding_paper` before its import (only when a paper was found). Nothing is sent after a client disconnect. The query
goes only to the reader's own stream; logs and the database keep counts only, as before (tests assert neither
contains it). Backward compatible: installed builds' parser returns nil for unknown event names (verified against
the shipped `ChatSSEParser` with a status frame before this change); `scripts/workflow-checks.mjs` also ignores
them. The app keeps the latest status per answer and shows it as one footnote line under the streaming answer
("Searching the web for “…”", "Reading results…", "Finding the paper…", "Adding to your library…"), or in place of
"Thinking…" before the first text; it clears when text resumes or the answer ends. Malformed or unknown statuses
are ignored, never fatal.

## Money

Rate version `beta-credits-v1`: credits = ⌈micro-USD / 5,000⌉ (1 credit ≈ $0.01 at 2× provider cost).

| Model | Input | Cache write 5 m / 1 h | Cache read | Output ($/MTok) |
|---|---|---|---|---|
| `claude-sonnet-5-5`, `claude-sonnet-5` | 2 | 2.50 / 4 | 0.20 | 10 |
| Any other serving model | 4 | 5 / 8 | 0.40 | 20 |

- Hold = ⌈prompt characters / 3⌉ tokens at the 5-minute cache-write rate + 8,000 output tokens. If the reader's available balance is at least 50 credits but below that hold, the credit hold is capped at the balance (owner decision 2026-10-05); the platform-budget (micro-USD) hold is never reduced, and an answer costing more charges the balance and logs `chat_credits_capped_at_balance`. Request digest = SHA-256 of a fixed-key-order canonical body (`\x<hex>`).
- A replay (`replayed: true`, any state) never calls the provider or settles; it returns `operation_replayed`. Reserve errors never settle. An ambiguous reserve transport failure is logged by operation ID for reconciliation.
- After a hold, settlement happens exactly once on every path (success, refusal, provider error, deadline, client disconnect). It retries only ambiguous transport failures, with identical amounts (the RPC is idempotent for equal amounts). Settled amounts never exceed the hold; overruns settle at the hold and log `chat_usage_exceeded_hold`. Recorded provider usage keeps the true estimate.
- Usage: final `usage.iterations` (per serving model, fallback included) or top-level usage. Without final usage: input from `message_start` and output = max(visible chars / 3, 100 tokens per elapsed second), capped at `max_tokens`. A typed HTTP rejection before `message_start` is unbilled. A lost connection before `message_start` charges the input estimate at the uncached rate. Estimates are marked `estimated: true` in `worker_record_provider_usage` units (event ID = message ID, else `operation:<id>`).

## Privacy

- Plaintext leaving the device per answer: the question, earlier turns of that branch (bounded as above), an optional selected passage and, for paper chat, the paper MMD that the server already holds. Prompts are built on the device from decrypted history; nothing else (notes, other chats, keys) is sent.
- The function stores no chat text: no tables, queues or logs. Logs carry only event names, operation IDs, counts and codes. The answer returns to the device, which seals it with the existing encrypted append path.
- Anthropic processes and may retain request content under its API terms; no zero-retention claim is made. Consent copy says so.
- First-use consent is per environment/account in the device Keychain (`<env>.<account>.cloud-ai-consent` = `cloud-ai-v1`), not in chat history. The question is saved locally first; consent then binds the request to that saved turn. Declining keeps the question and offers “Get answer”.

## Native behavior and failures

- After the user message commits, `ReaderModel` captures the turn (session, account, device, composer, conversation, document, message ID, selection quote) and streams via `BackendClient.chatStream` (configured host only, bounded 2 MiB stream, bounded SSE parser in ScienceReaderCore). The streaming row uses the pre-allocated assistant ID, so sealing replaces it without a row change. A thinking placeholder shows only before the first token.
- Seal: `.complete` for `end_turn`/`stop_sequence`; `.interrupted` for `max_tokens`, Stop, transport loss, provider error or EOF without `done`; nothing for empty output or refusals (partial refusal text is discarded). Errors are inline per composer with Try again; controls are restored.
- Ownership: generations are keyed by composer and checked against the account session. New chat, history or paper switches leave the answer fenced to its own conversation (it is sealed there; it never renders elsewhere). Sign-out/account change cancels all answers and keeps non-empty partials as interrupted turns in the old store before it retires. Releasing the stream cancels the HTTP request; the server then aborts the provider and settles.
- Settings shows `v1_credit_balance()` (available, held).
- `--chat-fixture` (Debug Simulator only, implies the durable draft fixture) replaces the transport with scripted answers; `--chat-fixture-mode=answer|slow|interrupt|insufficient_credits|refusal`; `--chat-fixture-consented` pre-accepts in-memory consent.

## Open items

UI journeys for Stop and Ingest; formulas SwiftMath cannot typeset fall back to LaTeX source; long papers raise the per-question hold (context is the whole MMD). The stale-hold sweep exists (migration 015).

## Selection actions and Related (2026-10-06)

The reader's selection actions are shown as **Explain**, **Why it matters**, **Related** and **Add paper** (identifiers
unchanged: define/relevance/similar/ingest). **Related** sends `action: "related"` (requires a selection; app
builds from 2026-10-06): the server adds instructions to search the web on distinct angles (up to 5 searches; the
hold is sized for 5) and list 4–8 related papers with arXiv/DOI links. Without web search it says so and never
invents links. Searches go to Tavily, with Anthropic's basic `web_search_20250305` as the backup ([web search](#web-search-on-in-staging));
Tavily's `academic` flag keeps paper searches on scholarly sites. Each answer logs `chat_answer` with counts only.

**Why it matters** sends `action: "relevance"` (2026-10-07): no search tool and no search hold even when search is on,
and instructions to explain the passage's role using only the paper's content (the legacy prompt: "Using ONLY the
paper's content (do NOT search the web)"). Follow-up questions in that chat are ordinary and may search. An older
server rejects the action as `invalid_request` before any hold, so the chat function must be deployed before a build
that sends it ships. **Explain** on a single equation (displayed, or inline with a relation) asks "Explain this equation:
‹formula›" followed by one line asking for the background needed, its overall message, each symbol and how its
notation compares with ML conventions (the legacy equation prompt, shortened); other selections keep "Explain in plain
terms, including any symbols: ".

## Time to first text (owner feedback build 16 #8, 2026-10-08)

Measured on staging before the change (`chat.related`, Mistral 7B paper, client on a home connection, server times
from `provider_attempts`): first `status` 4.3 s, first text 15.2 s, done 18 s. Server timeline from the reservation:
round 0 (thinking and choosing queries) 2.9 s; three parallel Tavily searches 3.3–3.9 s; round 1 to its first text
~6.9 s; about 1.3 s before the reservation (auth, policy, rate limit, balance, paper context and download, reserve).
Round 1 read nothing from the prompt cache on every multi-round answer on staging (`cache_read` 0): citable search
results switched citations on and invalidated the cached paper.

Changes (server only; deployed with 040):

- Related emits `status {kind: "searching"}` as soon as the rate limit and the search policy answer, before the
  paper loads and the first model round (fakes: ~1 RPC after the request instead of after round 0).
- The search-policy lookup starts with the request and the balance read runs alongside the rate limit; the paper's
  context still follows the credit check because it authorizes and accounts the Storage read (fakes, 40 ms RPCs:
  first provider call 293 → 208 ms; 80 ms RPCs: 563 → 398 ms).
- Search results with citations off, so round 1 reads tools + instructions + paper from the cache (verify after
  deploy: round 2's `cache_read_tokens` ≈ the paper). Saves the uncached prefill (largest on long papers) and about
  $0.13 per Related answer on a 56k-token paper.
- A selection action's own instructions (Related, Why it matters) follow the paper after its cache breakpoint, so
  Related right after a question on the same paper reuses that question's cache.
- Related asks for its searches together in one step (it usually did already: 3–4 parallel searches, two rounds).

Not changed: the model's thinking before round 1's text and Tavily's ~3.5 s are now the largest parts. Options for
later, each needing a measured check: show thinking progress (`thinking.display: "updates"` notes as status lines;
app work), a shorter search allowance for Related, or a per-search time limit.

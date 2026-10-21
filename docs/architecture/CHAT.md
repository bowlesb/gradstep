# Paid AI chat

Current local-answering policy: iPhone/iPad exclude the answering models and MLX runtime. Mac replacement models remain unqualified and its model catalog is empty; see [Local AI](LOCAL_AI.md). Every cloud route uses the shared OpenRouter backend.

Historical Local AI prototype (2026-10-17, TestFlight 68 on iOS and Mac): the composer offers Cloud AI or an explicitly downloaded local MLX model. Local requests use bounded device context, never the cloud transport or credits; model choice is captured with each turn. Structured Study and cloud search tools are not supported locally. See [LOCAL_AI.md](LOCAL_AI.md) for the tested limits and accuracy failures.

2026-10-16 owner decision after the comparison: **Gemini 3.8 Flash is selected as the next default**. The
[OpenRouter → Google integration](GEMINI_FLASH_CHAT.md) is **enabled as of 2026-10-17 19:54 UTC**: the live table
recommends Flash for updated clients, with consent v5, old-client compatibility and server accounting. The owner
explicitly waived the account logging/data-use verification hold; those switches remain unverified. A fresh
published-default request completes on Flash in 4.5 seconds. Older clients' compatibility default remains Sonnet,
and existing chats/saved choices keep their selected model. Native apps fetch the table once per session: restart
to refresh it, and select Flash in Answer options for an existing Sonnet chat.
On 2026-10-17 at 04:43 UTC the owner's Sonnet request failed for the Anthropic account balance, again at 14:32 UTC.
A fresh Flash probe also failed because AI Studio cannot satisfy the account's ZDR policy. Migration 086 and the
adapter now pin Google Vertex US with explicit ZDR; seven deployed-route generations pass. Build 68 and the browser distinguish model-balance failure as
`model_unavailable`, preserve the question and offer a different model instead of retrying the unfunded one. Since
every model now shares one OpenRouter account, the server answers a gateway 402 as `service_unavailable` with
`retry_after: 300` instead (2026-10-21, review A13; [RESILIENCE.md](RESILIENCE.md)); `model_unavailable` now means the
chosen model's own price card has lapsed (A4).
Activation is established by the later published-table readback and ordinary default smoke. The dated model research below is historical.

Build 65 feedback (2026-10-17 UTC; browser `91c7d07f`, TestFlight 66): the native Answer options sheet has no title or
Done row; its drag handle and accessibility escape dismiss it (Mac retains an X). “New chats currently start with
‹model · length›” always states the saved default. The owner's label “Reset default settings” replaced “Use for new
chats”; it saves the visible choices as the new default, is disabled while they match, and becomes accented when
they differ. Since c4d15d9 the apps read “Use for new ‹activity›” (general chat, paper chat, equation explanations,
figures and tables); the browser matches since the 2026-10-21 review fixes (B10/B11). Model/length selection and provider consent are
unchanged. Its existing desktop dialog header/X remain.
The same feedback batch removes the empty-chat accent glow on both clients; starter positions and actions stay the same.

2026-10-13 direction: preserve all paper/general-chat interactions while adding a versioned local-context route
for [HTML-first papers](HTML_FIRST_READER.md#paper-chat-and-other-derived-work). Its bounded text/TeX snapshot comes
from the device's verified bundle; no PDF, server MMD object or fabricated document identity is required. Account
authorization, explicit cloud-AI consent, encrypted history and server-side holds/settlement still apply. This
route is deployed on staging with `reader-local-context-v1` and `worker_local_chat_context`. The `worker_chat_context`/Storage contract below remains only for historical document-backed papers.

Status 2026-10-05: deployed to staging and verified live (API smoke and the Simulator journey: consent, streamed paid answer with typeset math, relaunch). Ingest verified live through the API (DPO passage citing PPO → arXiv 1707.06347 queued, 26 credits); its Simulator path is covered by unit tests only.

## Agent v2 (2026-10-14): numbered context, grounded citations, follow-ups

Three additions to the same request/stream contract, built once on the server and shown by both clients:

- **Numbered paper context** (`local_context.format: "reader-local-context-v2"`). A device-prepared paper is sent
  block by block from its verified index, each block starting with `[¶N]` (N is 1-based in index order): headings as
  `#…`, display equations as `\[ … \]` LaTeX, `[Figure] caption`, `[Table] text`, `- list item`. The browser
  (`apps/web/src/lib/paper-context.ts`) and ScienceReaderCore (`PaperChatContext`) produce the same text;
  `tests/fixtures/reader-arxiv/local-context-v2.txt` is the shared golden output both test against. `v1` (plain
  block text) is still accepted. The format is part of the request digest. Server-held (historical) papers are
  not numbered and get no citation instructions.
- **Grounded citations.** For a v2 context the system prompt asks the model to cite the exact block as `[¶N]` after
  the statement it supports. Clients render each marker as a small control (browser: `<span class="cite"
  data-cite="N">`, native: a `gradstep-cite://N` link in the selectable answer text). A tap resolves N against the
  open paper's index to the block ID and sends the existing passage request with `block` set; the shared reader
  bridge lands on the whole block when no quote is given (or when the quote isn't found), with the same Back as a
  citation jump. A marker the paper lacks shows "This answer cites a passage this paper doesn't have." Older
  clients show the marker as plain text. Nothing about citations is stored or logged by the server.
- **Follow-up questions.** A request with `follow_ups: true` (every ordinary answer from the current clients; refused
  on Ingest and diagram repairs) gets two or three questions the reader might ask next. They come from a second small
  request after the answer (`chat-follow-ups.ts`): Claude Haiku 5.5 with the `suggest_follow_ups` tool call forced,
  reading only the paper's title, the selected passage, the question and the first 2,400 characters of the answer,
  never the paper's text or earlier turns. The server validates the input (2–3 distinct one-line questions of 3–120
  characters), relays them once as an SSE `followups {questions}` event before `title`/`done`, counts them in
  `chat_answer` (`follow_ups: written|unusable|failed|skipped`, `follow_up_count`), and stores nothing. A complete,
  non-refused answer with text is the only one that asks; a suggestion still unanswered after 8 s is abandoned (its
  attempt is settled). Clients show them as one-tap suggestions under the newest complete answer only; a tap fills
  the message box (nothing is sent until the reader sends), and the next question clears them. They are never
  written to encrypted history. Old clients neither send the flag nor pay for it.

Costs: the suggestion request is held with the answer at its largest possible size (every excerpt at its limit,
`FOLLOW_UP_HOLD_PARAMS`) and frozen in the quote (`follow_ups_model`, `follow_ups_max_tokens`,
`follow_ups_ceiling_microusd`); a real one is about 1,000 input and 60 output Haiku tokens, under a tenth of a cent,
and about 1–2 s after the answer's last text. The first design offered the tool to the answering model inside its
own turn; the live check on 2026-10-14 showed Sonnet at low effort ending its turn without calling it, so the forced
side request replaced it (one mechanism, model-independent, testable).

## Study — 2026-10-14 (experimental; staging)

Owner direction (2026-10-14): "an experimental feature that combines quizzes you and teaches you about a paper. It
uses its knowledge of you to ask questions, and backs up when it seems like you don't know, and if you do know, it
either goes deeper where applicable, or goes to a new tangential topic within the context of the paper… It should
make clear the mental model that is being built up of your knowledge, and display it in some type of flow, html, or
graph." This is the first slice, built to learn from; the product angle is still open
([proposals/LEARNING_GUIDE.md](../proposals/LEARNING_GUIDE.md)).

- **One mechanism, no new storage.** A study is an ordinary paper conversation whose turns carry `action: "study"`.
  It needs the paper numbered on the device (local context v2), because the tutor cites `[¶N]`; a selection may
  start it on a passage but is not required (the only action without one). The reader's **knowledge map** is the
  state: concepts with a state (`unknown` could not answer · `learning` taught, not verified · `known` answered once ·
  `verified` answered a second, different check), links between them (`prerequisite`, `deeper`, `related`), the
  concept in focus, the journey (ids in the order explored, revisits included) and the step planned next
  (`calibrate|teach|verify|deeper|tangent|revisit`). The client sends the map with every study turn (an empty map
  first) and keeps the one that comes back; the server stores nothing, logs counts only, and the map is never written
  to encrypted history or the browser (it lives with the open chat, in memory; a new chat or sign-out drops it).
- **The tutor** (`chat-study.ts`, `STUDY_INSTRUCTIONS`): one step and exactly one bold question per turn, under 180
  words. It judges the reader's last answer (correct, partly, not yet; never flattery), then teaches from the paper
  with citations when the answer was wrong or partial and asks a simpler check, verifies once after teaching with a
  different check, goes deeper on a known concept or moves to a related one, and returns to an earlier `unknown` or
  `learning` concept once the focus is solid. On the first turn it asks a calibrating question. The map goes in the
  system prompt after the paper (the action's own text), so the cached paper is reused; the profile's length
  instructions are left out (the tutor's length is its own); no web search.
- **The map update** is a forced tool call to Claude Haiku 5.5 after the answer (`update_study_map`, like follow-ups):
  it reads the previous map, the reader's answer (the first turn is "none") and the tutor's reply, never the paper,
  and returns the whole updated map (states change only on evidence; the tutor's final question sets the focus and
  extends the journey). The server validates it (`studyMap`): the shape must be usable (concept arrays, at most 60
  concepts / 120 links / 16 KiB, every concept with a usable id, label and state), while one careless element is
  repaired rather than fatal (an id in label form is slugged, a link to an unknown concept, a self link, a duplicate
  or a journey entry off the map is dropped, a long label or note is cut). The first live study on 2026-10-14 lost
  its third map update to the strict version of this check, hence the tolerance. The map is relayed once as SSE
  `study {map}` before `done`; an unusable or late (12 s) update leaves the client's map as it was. Follow-up suggestions are refused beside a study (the tutor's question is the follow-up).
- **Cost:** the update request is held with the answer at its largest (`STUDY_HOLD_PARAMS`: a full map and both
  excerpts at their limits) and frozen in the quote (`study_model`, `study_max_tokens`, `study_ceiling_microusd`); a
  real update is about 1,500 input and 300 output Haiku tokens. `chat_answer` logs `study: written|unusable|failed|skipped`
  and `study_concepts` (a count, never a name).
- **Clients.** Browser: "Study this paper" in the empty paper chat and beside the title; a knowledge-map panel above
  the message box (summary line, "Now: concept · step", Map as a Mermaid flowchart in the sandboxed diagram frame,
  Journey as chips in order, Concepts with state, note, links and `¶N` buttons that land in the paper; End study).
  Native: "Study this paper" in the empty paper chat and the chat's "…" menu; a knowledge-map bar above the message
  box with View (a sheet: Map/Journey/Concepts, the Mermaid canvas drawn by the diagram renderer) and End study; the
  message box reads "Your answer". The fixture backends tutor deterministically for the journeys.

## Contract: `POST functions/v1/chat`

- Auth: user JWT verified in the handler (`verify_jwt = false`, `userClient`); RPCs run as service role. Origin/method/auth failures are HTTP JSON `{code}`; after authentication every outcome is `200 text/event-stream`.
- Body (strict, unknown keys rejected, ≤ 512 KiB raw): `{operation_id: uuid, consent_version: "cloud-ai-v2" (the earlier "cloud-ai-v1" is still accepted and turns Tavily search off; "cloud-ai-v3" adds figures, "cloud-ai-v4" DeepSeek, [below](#chat-redesign-from-build-57-feedback--2026-10-16)), mode: "paper"|"general", document_id?: uuid (paper only), messages: [{role: "user"|"assistant", text}] (1–60, first and last user, non-empty, ≤ 200,000 UTF-8 bytes total), selection?: {quote ≤ 4,000 Unicode scalars}, action?: "ingest" | "related" | "relevance" (each requires a selection) | "study" (paper mode with local context v2; a selection is optional; see [Study](#study--2026-10-14-experimental-staging)) | "diagram_fix" (general mode, exactly one user turn ≤ 24,000 bytes, no selection), capabilities?: ["web_import"] (≤ 8 strings ≤ 32 characters; unknown values ignored), profile?: {model, effort, length}, topic_title?: boolean, follow_ups?: boolean, study?: {concepts, links, focus, journey, next}} ` (`study` is required with `action: "study"` and refused otherwise; `follow_ups` is refused with it; the last two flags since 2026-10-08: [models, effort and length](#models-effort-and-length-2026-10-08), [topic titles](#topic-titles-2026-10-08); `follow_ups` since 2026-10-14, [above](#agent-v2-2026-10-14-numbered-context-grounded-citations-follow-ups)).
- `GET` (2026-10-08) returns the versioned profile table, below.
- Events: `delta {text}`, `diagram {title, source}`, `status {kind, query?}` (2026-10-07, below), `title {text}` (2026-10-08), `followups {questions}` (2026-10-14, above), `study {map}` (2026-10-14, [Study](#study--2026-10-14-experimental-staging)), `done {stop_reason, credits, usage, model?, profile, charged, reason?}` (`model`/`profile` since 2026-10-08; `charged`/`reason` since 2026-10-16, [below](#when-an-answer-stops-early--2026-10-16)), `error {code, credits?, charged?, reason?}` (`credits` since 2026-10-14: what the failed answer cost the reader; since 2026-10-16 every error after the hold carries `credits: 0, charged: false` and a `reason`, and an error without `charged` came before anything was held) with codes `insufficient_credits`, `platform_budget_exhausted`, `rate_limited` (route limit or 3 active operations), `document_unavailable`, `provider_unavailable`, `refused`, `invalid_request`, `operation_replayed`, `service_unavailable`, `consent_required` (2026-10-16: DeepSeek chosen under a consent before v4). `done` also carries `effort` when the request asked for `auto` (2026-10-16). Comment lines (`: ping`) every 15 s keep idle connections open.
- Order: `worker_consume_request(account,'chat')` → validate → paper context (`worker_chat_context` → Storage `standalone.mmd`, ≤ 2 MiB, strict UTF-8) → hold → `worker_reserve_chat` (migration 047: `worker_reserve_operation` plus the frozen quote; until 2026-10-08 `worker_reserve_operation`) → stream (and the title, in parallel; then the follow-up suggestions, from the finished answer) → `worker_settle_operation` → `worker_record_provider_usage` → final event.

## Provider request

`@anthropic-ai/sdk` 0.131.0 (`npm:` import map entry and root `package.json`). By default (no `profile`, and every request before 2026-10-08) model `claude-sonnet-5-5`, `max_tokens` 8,000, adaptive thinking at effort `low`; a reader's profile changes the model, effort, allowance and length instructions ([below](#models-effort-and-length-2026-10-08)). Effort `low` is the model guidance for chat: it skips thinking on simple turns and keeps time-to-first-token and cost low. Thinking display omitted. Server-side refusal fallback `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`; Sonnet and Opus only, Haiku 5.5 has no fallback models); for Sonnet 5.5 it retries `cyber`/`frontier_llm` declines on Claude Sonnet 5, which matters for an ML-paper reader. Final `stop_reason: "refusal"` becomes `error refused`. System prompt = short instructions (cite sections/equations, LaTeX with `\( \)`/`\[ \]`, no "Answer:" label since 2026-10-07) + `<paper title>` MMD block with `cache_control: ephemeral` (cached prefix). The selected passage is a separate text block before the last question. One SDK retry; a 130 s generation deadline leaves time to settle inside the Edge wall-clock limit.

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
otherwise the paper is imported **as the user** (their JWT; the app starts chat streams with ≥ 5 minutes of token
validity), exactly like the app's Add, so normal conversion, credit holds and quotas apply. Since review A5
(2026-10-21) the presence check and the import are one locked RPC, `v2_add_paper_once`, and the import's operation
UUID is derived from the chat operation, so a finished `source_only` paper is present and a retry never queues it
twice ([HTML_FIRST_READER.md](HTML_FIRST_READER.md#server-adds-without-duplicates-review-a5-2026-10-21-migration-120-not-deployed)). Post-settlement work has
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
of the request digest when present). Other capabilities: `visual_answers`, `figure_requests`, `stop_signal` (below)
and `figure_view` (2026-10-16: the apps send it on every paper chat request, never Add paper or a repair, so the figure
view's walkthrough shares the chat's cached tools; [FIGURE_VIEW.md](FIGURE_VIEW.md); its actions are `figure`,
`figure_simpler` and, since TestFlight 62's feedback, `figure_detail`, one part extracted with more context). The app sends `web_import` on Ingest requests from builds that show web papers. Older
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

### Browser copy controls — 2026-10-08

The browser exposes copy only after an explicit user action: `Copy answer` copies a completed assistant message,
and `Copy Mermaid` copies the source inside the collapsed diagram details. The client uses the secure Clipboard API
when available and a short-lived textarea fallback otherwise; it never writes answer or diagram text to storage,
logs, or the server. A visible Copied/Copy failed label and disabled state prevent duplicate clicks while the
clipboard operation is settling. The production-CSP Playwright journey covers both controls without a provider call.

## Web search (on in staging)

Current (2026-10-21): web search is only our `search_web` function tool. The model calls it through OpenRouter like
any tool; our server runs the search with Tavily (prepaid plan, admitted as provider `tavily`) and returns the pages
as tool results. Its cost to Gradstep is the prepaid plan, not OpenRouter; the reader pays Tavily's list price per
credit. The Anthropic server-side search backup described below was gated off from 2026-10-14 and its code was removed
with the OpenRouter-only decision; a paused or exhausted Tavily now means the answer is written without search.

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

## Models, effort and length (2026-10-08)

Owner request (2026-10-08): "chats should have the ability to customize the length and effort and model right there
in the chat in a clear UX". Status: migration 047 applied and the function deployed to staging on 2026-10-09, with a paid profile check
(three profiles, $0.14; [implementation status](../IMPLEMENTATION_STATUS.md#chat-controls-and-titles-on-staging--2026-10-09-utc)).
The native controls shipped in build 23; the browser controls in the first browser release.

The server owns a versioned profile table (`chat-profiles-v1`, `supabase/functions/_shared/chat-profiles.ts`). A
request names a choice; the server accepts only the table's combinations, sends the matching request, holds the
maximum at that model's rates, freezes the quote with the hold and settles actual usage once. Clients only display the
table's labels and estimates.

### Profile table v1

Model IDs and capabilities checked with `GET /v1/models` (staging key, 2026-10-08): all three accept adaptive thinking
and `output_config.effort`; `allowed_fallback_models` is Sonnet 5 for Sonnet 5.5, Opus 4.8 and Opus 5 for Opus 5.5, and
none for Haiku 5.5. **Claude Haiku 5.5 exists** (`claude-haiku-5-5`, listed since 2026-10-07, 1M context, 128K
output); it replaces Haiku 4.5 here (10× cheaper, effort and adaptive thinking like the others). Prices: [Money](#money).

| Choice | API request |
|---|---|
| Model: Haiku · Sonnet (default) · Opus | `claude-haiku-5-5` (no `fallbacks`) · `claude-sonnet-5-5` · `claude-opus-5-5` (both `fallbacks: "default"`) |
| Effort: Low (default) · Medium · High | `thinking: {type: "adaptive"}` with `output_config.effort` `low` · `medium` · `high`; thinking allowance 2,000 · 4,000 · 8,000 tokens |
| Length: Brief · Standard (default) · Detailed | answer allowance 1,000 · 6,000 · 10,000 tokens; Brief and Detailed add an instruction after the paper, Standard adds none |

`max_tokens` = answer allowance + thinking allowance (it covers both, across every search round):

| Length \ Effort | Low | Medium | High |
|---|---:|---:|---:|
| Brief | 3,000 | 5,000 | 9,000 |
| Standard | **8,000** (today) | 10,000 | 14,000 |
| Detailed | 12,000 | 14,000 | 18,000 |

Sonnet · Low · Standard is exactly the request the function made before profiles (asserted at module load and in
tests). Answers still stop at the 130 s generation deadline, so the largest allowances (Opus, High, Detailed) can end
as interrupted answers on long questions; they are kept and, since 2026-10-16, not charged (our own limit,
[below](#when-an-answer-stops-early--2026-10-16)).

Published credit estimates (`credits: {low, high, max}`), a **planning basis, not measurements**: a question about a
25-page paper (41,500 prompt tokens). `high`: the first question, writing the paper to the prompt cache; `low`: a
follow-up reading it back with 1,800 tokens of conversation; typical answers of 250 · 900 · 2,200 tokens by length
and thinking of 200 · 1,200 · 3,000 by effort; `max`: the whole prompt written to the cache plus the full allowance,
one attempt, no search. The server's hold is larger (below).

| Model | Length | Low | Medium | High |
|---|---|---|---|---|
| Haiku | Brief | 1–2 · max 2 | 1–2 · max 2 | 1–2 · max 2 |
| Haiku | Standard | 1–2 · max 2 | 1–2 · max 3 | 1–2 · max 3 |
| Haiku | Detailed | 1–2 · max 3 | 1–2 · max 3 | 1–2 · max 3 |
| Sonnet | Brief | 3–22 · max 27 | 5–24 · max 31 | 9–28 · max 39 |
| Sonnet | Standard | 4–24 · max 37 | 6–26 · max 41 | 10–29 · max 49 |
| Sonnet | Detailed | 7–26 · max 45 | 9–28 · max 49 | 12–32 · max 57 |
| Opus | Brief | 5–44 · max 54 | 9–48 · max 62 | 17–55 · max 78 |
| Opus | Standard | 8–47 · max 74 | 12–51 · max 82 | 19–58 · max 98 |
| Opus | Detailed | 13–52 · max 90 | 17–56 · max 98 | 24–63 · max 114 |

**Local verification (2026-10-08, main merged through `7d4af7b`).** Database suite (047 applies after 046, both
phases), 430 backend tests, the chat function's Deno type check, 258 Core Swift tests, the wire check (titles and
answer labels), 402 iOS unit tests (5 skipped), the chat-controls journeys, All chats and Discuss in chat (iPhone
10/10, iPad 4/4; light and dark screenshots inspected) and a universal (arm64 + x86_64) Catalyst build. Model IDs,
prices and thinking rules re-read from Anthropic's price list, models overview and thinking guide the same day: the
tariff above matches (Sonnet 5.5 cache reads $0.10), and Haiku 5.5 accepts the title request's
`thinking: {type: "disabled"}` at its default effort (`medium`; only `xhigh`/`max` reject it). No provider request.

Haiku 5.5 is new: before it is presented as a cheaper substitute it should pass factual/equation checks
([pricing recommendation](../research/PRICING_RECOMMENDATION_20261008.md#more-models-effort-and-tools)); the paid check
should include it.

### Client contract (for the web composer and any other client)

**`GET functions/v1/chat`** — user JWT as for `POST` (CORS allows GET). Returns `200 application/json`, the table:

```json
{"version":"chat-profiles-v1","rate_version":"beta-credits-v1","tariff":"anthropic-list-prices-2026-10-08",
 "microusd_per_credit":5000,"default":{"model":"sonnet","effort":"low","length":"standard"},
 "models":[{"id":"haiku","label":"Haiku","detail":"Fastest and cheapest","api_model":"claude-haiku-5-5"},…],
 "efforts":[{"id":"low","label":"Low","detail":"Thinks only when needed; quickest"},…],
 "lengths":[{"id":"brief","label":"Brief","detail":"A few sentences"},…],
 "profiles":[{"id":"haiku-low-brief","model":"haiku","effort":"low","length":"brief","api_model":"claude-haiku-5-5",
   "max_output_tokens":3000,"credits":{"low":1,"high":2,"max":2}},…27 entries],
 "estimate_note":"For a question about a typical 25-page paper. Web searches add about 2 credits each."}
```

The exact server output is checked in as
`apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/chat-profiles-v1.json`
(`tests/backend/chat-profiles-fixture.test.ts` fails if they differ; regenerate deliberately with
`node tests/backend/chat-profiles-fixture.test.ts --write-fixture`). Decoding (Swift `ChatProfileTable.decode`, web
`lib/chat-profiles.ts`): refuse a body over 64 KiB, another `version`, or a `default` that isn't offered; skip unknown
models/efforts/lengths and entries whose credits aren't `0 ≤ low ≤ high ≤ max`; a choice not listed isn't offered.
Show "Usually ‹low›–‹high› credits · up to ‹max›", or "About ‹n› credit(s) · up to ‹max›" when low = high, then the
note. A server from before profiles answers `405 {"code":"method_unavailable"}`: show no estimates and send neither
new field.

**Request fields** (part of the request digest when present):

- `profile`: exactly `{"model": "haiku"|"sonnet"|"opus"|"deepseek", "effort": "low"|"medium"|"high"|"auto", "length": "brief"|"standard"|"detailed"}`
  (`deepseek` and `auto` since 2026-10-16: [automatic effort and DeepSeek](#server-implementation--2026-10-16-staging-migration-078-chat-function-redeployed)).
  Any other key or value is `invalid_request` (before any hold). Absent, `null` and the default
  `{sonnet, low, standard}` are the same request with the same digest. Clients send it only when it isn't the default.
- `topic_title: true` asks for a topic title; absent, `null` or `false` don't.
- Neither is accepted with `action: "diagram_fix"` (a repair always uses the default model and needs no title).
- Send either only after `GET` has returned the table: a server without profiles rejects unknown keys as
  `invalid_request`. With the default choice and no title the body is byte-for-byte today's.

**Answer metadata** — `done` gains `model` (the model that served the final attempt: `claude-sonnet-5` when Sonnet
5.5's refusal fallback answered; omitted unless it matches `^[a-z0-9][a-z0-9.-]{0,63}$`) and `profile` (the profile
ID, e.g. `opus-high-detailed`, or `diagram_fix`). Clients keep a label only if it is ASCII letters, digits, `-`, `.`
or `_` and at most 64 bytes, else drop it (never fatal), and save both on the answer (below). Under an answer clients
show "‹Model› · ‹Effort› · ‹Length›" from the profile ID, plus "· by ‹Claude Sonnet 5›" when the serving model isn't
the profile's (`ChatProfileText.answeredBy`); nothing for answers saved without labels.

**Which choice a chat uses** (as built in the iOS app): a choice made in the chat's control and not yet used; else the
profile of the conversation's newest answer that has one (encrypted, so it follows the chat to every device); else
the device's Chat defaults (Sonnet · Low · Standard until changed). A selection action (Explain, Why it matters,
Related, Add paper) starts its new conversation with the choice the chat pane shows. The question is asked with the
choice shown when Send is pressed; a retry asks with the same.

### Holds, quotes and settlement

- Hold rule per model (`holdRule` in `anthropic.ts`): Sonnet 5.5 — its own rates ×3, unchanged; Opus 5.5 — every token
  at its fallbacks' higher Opus 5 rates, ×2 (the requested attempt and one fallback); Haiku 5.5 — one attempt at the
  tier of the estimated prompt (the byte estimate never undercounts tokens, so it never wrongly picks the cheaper
  tier); any other model — the unknown card ×3. Input is held at the 5-minute cache-write rate, output at the full
  allowance. Search holds use the same model's rates. The per-round admission (`admittedAnthropic`) computes each
  request's ceiling from its own model with the same rule, so the answer's first round plus the title exactly fill the
  hold, and later rounds must fit what remains ("stop before a round that can't fit", unchanged).
- The title's whole ceiling (Haiku 5.5, 40 output tokens, its prompt at the cache-write rate) is added to the hold.
- **Quote (migration 047).** `worker_reserve_chat(account, id, request_sha256, rate_version, credits, microusd, quote)`
  reserves exactly like `worker_reserve_operation(…, 'chat', …)` and, in the same transaction, records
  `app_private.chat_quotes`: `profile_version`, `profile`, `model`, `effort`, `length` (`repair` for a diagram fix),
  `rate_version`, `tariff`, `max_output_tokens` (thinking included), `input_estimate_tokens`, `max_searches`,
  `title_model`, `title_max_tokens`, `title_ceiling_microusd`, since migration 059 (2026-10-14) the optional
  `follow_ups_model`, `follow_ups_max_tokens`, `follow_ups_ceiling_microusd` group (all three keys when a
  suggestion request is held, none otherwise; nulls for earlier quotes), and the credit and spend ceilings. Immutable,
  service-role only, RLS on, no prompt or title text; a replay must carry the identical quote (else
  `operation_id_conflict`); a malformed quote is `invalid_reservation` and rolls the hold back. Kept with the operation
  on account deletion.
- Settlement is unchanged: actual usage of every attempt (answer rounds, fallbacks and the title) priced per serving
  model, rounded to credits once, never above the hold; no re-quote, no automatic escalation, no extra paid fallback.
- Logs add `profile` (ID) and `title` (`written`, `unusable`, `failed`, `not_requested`) to `chat_answer`; never text.
- Not changed: `worker_provider_attempt_begin`'s per-attempt `pricing_snapshot` (migration 034) still records the
  2026-10-07 Sonnet/Haiku 4.5/fallback card as evidence; the authoritative tariff for a chat is the quote's `tariff`
  and the function's rate card. Updating the snapshot needs a function redefinition and is left for a later migration.

### Prompt caching

The shared instructions and the paper block (its `cache_control` breakpoint) are byte-identical across every model,
effort and length; a length's instruction follows the paper with a selection action's own, so it never invalidates the
cached paper. Caches are per model, so changing a chat's model starts a new cache, and an effort change may too
(model-specific); a chat keeps its choice, so its follow-ups read the cache as before. The title request has no
cache breakpoint (its prompt is small).

## Topic titles (2026-10-08)

Owner feedback (TestFlight build 21): "Each chat should have a labeled title on the topic of the chat in the same way
that ChatGPT does ("Explainer for a persona paper") and this should be embedded everywhere in the app".

**Design: a parallel Haiku 5.5 request in the same operation.** With `topic_title: true` the function starts a second,
small request as soon as the answer's hold exists: `claude-haiku-5-5`, `thinking: {type: "disabled"}`, `max_tokens`
40, no tools or fallbacks, instructions to reply with a 3–7 word sentence-case topic ("Explainer for a persona paper").
Its input is the paper's title, the selected passage (≤ 400 characters), the first question (≤ 1,200), and for a
conversation titled late its first answer (≤ 800) and newest question (≤ 400); never the paper's text. It runs beside
the answer, so it adds no wait; a title still running when the answer completes gets 4 s, then is abandoned (its
attempt is still settled). Chosen over asking the main model for a stripped title line: that needs instructions and
output at Sonnet/Opus rates (similar or higher cost: ~15 output tokens are $0.00015 on Sonnet, $0.0003 on Opus), holds
back the stream to strip a line, and is lost when an answer ends in a tool call, is cut off or forgets the format.
**Cost:** about 1,000 input and 10 output tokens, ≈ $0.0001 (0.02 credit) per title, inside the answer's single
rounded charge; its ceiling (≈ 400–1,000 micro-USD) is held with the answer.

**Stream:** `title {text}` once, before `done`, only when the answer completes (not a refusal, error or interruption)
and the reply is usable: first line only, labels, quotes, Markdown and final punctuation removed, control and
bidirectional-override characters dropped, at most 12 words and 80 characters (`cleanTitle`). The server never logs
or stores the title. Clients clean it again (`ChatTopicTitle.clean`: one line, ≤ 80 characters) and ignore an unusable
one.

**Encrypted storage (wire format 1, additive optional keys).** A title is a **new revision of the conversation entity**,
sealed in the same batch as the complete answer it came with:
`{kind: "conversation", entityID: ‹conversation›, parents: ‹every current revision's event ID›, documentID, anchor,
createdAt (copied from the current revision), text: ‹title›, titleSource: "generated"}`. A rename is the same with the
reader's text and `titleSource: "renamed"`. An answer message gains `model` and `profile`. Readers validate the three
new keys **only by length (≤ 64 UTF-8 bytes) on any kind** and accept any `titleSource` value, so a later build's
values never stop an older one decoding (and syncing). Builds from before these keys ignore them: they show the newest
revision's `text`, so they show topic titles too, and their history keeps working (a message's parent is still the
original conversation revision, which stays). Concurrent titles resolve like any revision (lowest event ID; a rename
supersedes all). Fixture: `apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/labelled-events-v1.json`
(a generated title, a renamed title with Unicode, a `titleSource` from a later build, and an answer with `model` and
`profile`), sealed by Node and checked by `node scripts/check-wire.mjs` (Swift opens, validates and reseals each; Node
reads Swift's back), by Swift Core tests and by the web unit tests.

**Client rules:** ask for a title whenever the conversation's current revision has no `titleSource` (new chats, and
existing chats lazily on their next question; no background generation); keep a generated title only with a complete
answer, and only if the conversation still has none (a rename or another device's title wins); show a titled
conversation's `text` as it is, and an untitled one's derived title (`ChatTitle.display`, "Explain · ‹passage›") as
before; Rename writes `renamed` (≤ 80 characters; an empty name is ignored).

### Clients

- **iPhone/iPad (and Mac through Catalyst, shared code).** The message box is one glass pill: the question on top, and
  on the row under it the answer settings control ("Sonnet · Low · Standard", a capsule) and Send, as in Gemini's
  message box; with little height (a keyboard in landscape) everything is one row and the control shows only its
  symbol. The control opens "Answers in this chat" (a popover on iPad and Mac, a half-height sheet on iPhone): Model,
  Effort and Length as segmented controls (menus at accessibility text sizes), each with what the chosen option means,
  the estimate and its note, then "Use for new chats" and Reset when the chat differs from the defaults. Settings ›
  Chat defaults (above Reading) holds the same choices for new chats (this device). A quiet line under each answer
  names its profile. The chat header, All chats (rows, search, the delete confirmation), the chat title menu's "Chats
  about this paper" and "Chats about this passage" show topic titles; Rename is in the chat title menu and All chats'
  long-press (and VoiceOver actions). Without the table (an older server or offline) the control shows the chat's
  choice with "Couldn't load the answer choices" and Try again, and requests stay exactly as before. Mac menu commands
  for these controls are left to the Mac work.
- **Web.** Ownership moved to Codex on 2026-10-08, so this branch leaves `apps/web` exactly as on main (its web
  work was removed when main was merged in). A first implementation of this contract, written before the handover,
  remains in history for reference: commits `338e628` and `c286bdf` (composer control and panel, answer labels, titles
  with Rename, account menu › Chat defaults, an e2e fixture serving the profile table; vitest 206, build and Playwright
  passed at the time, against the pre-merge web). It is not part of the branch's result; Codex may reuse or replace it.

- **Transcript follow (both clients, 2026-10-14; owner report, build 35: scrolling up while an answer streams
  snapped back down).** The transcript follows new text only while the reader is at its end. Their own scroll
  decides: at the end (within 2 px/pt: `transcriptFollows`, `apps/web/src/lib/chat-follow.ts`; native
  `TranscriptTable.gestureTolerance`) following is on, anywhere else it is off until they return to the end or use
  "Latest message" / "Latest". The transcript's own scrolls (following a flush, "Latest") are marked and never read
  as the reader's (web `programmatic`; native ignores layout restores while `userScrolling`). Layout and chrome
  changes keep their 80 pt slack natively, because a keyboard or banner moving the readable area is not a choice.

### Native transcript sizing audit — 2026-10-20 UTC

iPhone/iPad and Mac TestFlight 76 include this repair; both are VALID / IN_BETA_TESTING with notes verified.
Motion is verified with iPhone and iPad Simulator fixtures; physical-phone feel is unverified.

The owner's back-and-forth shaking reproduces with completed, synthetic messages and no network. Restoring the
old row renderer as a fixture-only negative control produces 116 pt of height variation in unchanged messages
and 113.67 pt of visible-text displacement beyond the finger's movement, measured after layout. The earlier
keyboard/scrollback journeys checked the final reading position and missed intermediate motion. Table offset
alone also missed it: estimated-height corrections can preserve the row origin while the rendered text moves.

`UIHostingConfiguration` propagated changing window safe-area insets into the self-sizing messages. The trial
using only `.ignoresSafeArea()` still failed the real-drag regression. The replacement keeps the same table,
virtualization, message views and follow/anchor policy, with contained, reusable `UIHostingController` rows whose
`safeAreaRegions` is empty. The table owns chrome and keyboard insets. This is the custom scroll-container use
described by [Apple's safe-area API](https://developer.apple.com/documentation/swiftui/uihostingcontroller/safearearegions).
Intrinsic sizing tracks message changes; reuse resolves the new SwiftUI content before the table measures it,
and retirement removes child controllers and their message content.

Streaming snapshots are coalesced during dragging and deceleration, then applied at the final reading anchor.
The transport and saved answer continue advancing throughout. Measured row heights are reused as estimates by
message identity (invalidated for width/font changes), so a text update does not replace known geometry with the
generic 240 pt estimate. A message's own dynamic content still resizes through intrinsic-size invalidation.
An update to an unrealized offscreen answer updates the stored row data without reapplying an identical table
snapshot. Reapplying that snapshot was observed moving the visible passage 213.67 pt before anchor restoration
on the next layout pass. Prepared/prefetched cells still reconfigure; newly realized cells use the latest data.

The opt-in `--chat-scroll-audit=static|stream` fixtures use 24 alternating short questions and tall scientific
answers through the encrypted fixture store. Simulator journeys drag in both directions and flick across rows,
with an additional growing answer for `stream`. `--chat-scroll-audit-growing-row` starts that answer with a long
prefix, so the reader also drags and rests within the answer that is still arriving. DEBUG + FIXTURE_HOST records numeric geometry only, never chat
text, after layout at the end of each sampled main-run-loop pass. The initial display-link callback probe sampled
before layout and included intermediate compensation; those diagnostic traces are not accepted display evidence.
Assertions require text to track the finger within 3 pt, unchanged completed-message heights within 1 pt at the
same width, and a stable passage within 3 pt while idle in scrollback. A fixture-only switch restores the old row
renderer so the probe must also detect the known defect. The trace is written in the Simulator's temporary
directory; the probe and negative control do not exist in shipped builds.
The old-renderer control detects the defect and the repaired motion checks pass; exact counts, retained failures,
keyboard/selection coverage and limitations are recorded in [Testing](../TESTING.md#native-chat-motion-audit--october-20-utc).

### Deploy order

1. Apply migration `202610080047_chat_profiles.sql` (additive): `python3 scripts/migrate-supabase.py staging`.
2. Deploy the `chat` function: `python3 scripts/deploy-staging.py staging --skip-migrations --functions chat`. Before
   step 1 its reservations fail (`worker_reserve_chat` missing) as `service_unavailable`, before any provider
   request; deploy both together. The deploy runs the free deploy suite plus `chat.smoke` and `ingest.not-found`
   (≈ $0.01, default requests: no profile, no title) unless `--skip-checks`.
3. Paid check (lead): `node scripts/workflow-checks.mjs --only=chat.profiles,chat.profiles-max --cap-usd=0.75`
   ([workflow checks](WORKFLOW_CHECKS.md)). `chat.profiles` (≈ $0.25 estimated) compares `GET chat` with the
   checked-in table, asks the Mistral 7B question once per model at Low · Brief with a topic title, checks
   `done.profile`, `done.model` and the `title` event, asks a Sonnet follow-up that must read the paper from the
   cache, and compares each `chat_quotes` row and its Anthropic `provider_attempts` (state, title attempt, settled
   credits ≤ the quoted ceiling). `chat.profiles-max` (≤ $0.40 estimated) does one Opus · High · Detailed answer.
   Titles print to the console only. The runner skips a check whose estimate would pass the cap or leave the
   platform budget under its $0.50 reserve; synthetic accounts are deleted afterwards.
4. Ship clients. Older clients are unaffected (no new fields sent; `title` events and `done` labels are ignored).

## Money

Rate version `beta-credits-v1`: credits = ⌈micro-USD / 5,000⌉ (1 credit ≈ $0.01 at 2× provider cost).

Tariff `anthropic-list-prices-2026-10-08`, from [Anthropic's price list](https://platform.claude.com/docs/en/about-claude/pricing) read
2026-10-08 ($/MTok):

| Model | Input | Cache write 5 m / 1 h | Cache read | Output |
|---|---|---|---|---|
| `claude-haiku-5-5`, prompt ≤ 100,000 tokens | 0.10 | 0.125 / 0.20 | 0.01 | 0.50 |
| `claude-haiku-5-5`, prompt > 100,000 tokens (whole request) | 0.50 | 0.625 / 1 | 0.05 | 2.50 |
| `claude-haiku-4-5` (catalog tags, not chat) | 1 | 1.25 / 2 | 0.10 | 5 |
| `claude-sonnet-5-5` | 2 | 2.50 / 4 | **0.10** | 10 |
| `claude-sonnet-5` (Sonnet 5.5's fallback) | 2 | 2.50 / 4 | 0.20 | 10 |
| `claude-opus-5-5` | 4 | 5 / 8 | 0.20 | 20 |
| `claude-opus-5`, `claude-opus-4-8` (Opus 5.5's fallbacks) | 5 | 6.25 / 10 | 0.50 | 25 |
| Any other serving model | 5 | 6.25 / 10 | 0.50 | 25 |

Correction (2026-10-08): the price list gives Sonnet 5.5 cache reads at 0.05× input, $0.10/MTok; the earlier card
charged $0.20, overstating cache reads twice. Unknown models now price at the highest card this route can be served
by (Opus 5/4.8, $5/$25), not Opus 5.5's.

- Hold (Sonnet 5.5, unchanged) = ⌈prompt characters / 3⌉ tokens at the 5-minute cache-write rate + the output allowance (8,000 by default), ×3. Other models: [holds](#holds-quotes-and-settlement). If the reader's available balance is at least 50 credits but below that hold, the credit hold is capped at the balance (owner decision 2026-10-05); the platform-budget (micro-USD) hold is never reduced, and an answer costing more charges the balance and logs `chat_credits_capped_at_balance`. Request digest = SHA-256 of a fixed-key-order canonical body (`\x<hex>`).
- A replay (`replayed: true`, any state) never calls the provider or settles; it returns `operation_replayed`. Reserve errors never settle. An ambiguous reserve transport failure is logged by operation ID for reconciliation.
- After a hold, settlement happens exactly once on every path (success, refusal, provider error, deadline, client disconnect), through `worker_settle_chat` since 2026-10-16 (migration 079: `worker_settle_operation` and the answer's ending in one transaction). It retries only ambiguous transport failures, with identical amounts (the RPC is idempotent for equal amounts). Settled amounts never exceed the hold; overruns settle at the hold and log `chat_usage_exceeded_hold`. Recorded provider usage keeps the true estimate, and since migration 079 an overrun is a budget anomaly, never a pause by itself ([RESILIENCE.md](RESILIENCE.md#owner-decisions)).
- What the reader pays depends on how the answer ended: [When an answer stops early](#when-an-answer-stops-early--2026-10-16).
- Usage (OpenRouter, since 2026-10-18): the final chunk's `usage` with `cost` is the exact bill. A stream cut short (Stop, dropped stream, our deadline) reads OpenRouter's generation record (≤6 reads in 7 s) and settles exact when it matches; otherwise the attempt keeps its whole ceiling as unresolved liability (`estimated: true` in `worker_record_provider_usage` units) until the reconciler resolves it. The reader is charged only the written part (`readerMicrousd`), never the estimate. A typed HTTP rejection before the stream (400/401/402/403/404/413/422/429) is unbilled.

## When an answer stops early — 2026-10-16

Owner decision (2026-10-16): "we need to better define the situation. If we were charged by the provider, the onus is
now on us to provide the value back to the owner." **The reader pays for work that finishes, or for the part of an
answer they chose to stop. Anything else that ends it early costs the reader nothing: the hold is released, Gradstep
pays the provider, and the cost is still recorded as platform-absorbed** (it counts toward the month's budget, Health
and the anomaly tripwire; it is never hidden). Text already streamed stays the reader's: the clients keep it, marked
interrupted. Status: server built and deployed to staging 2026-10-16 (migration 079, chat function); the clients'
part is listed at the end of this section.

### How an answer can end

| How it ends | What the reader's app receives | The reader pays | Recorded ending (`reason` when unpaid) |
|---|---|---|---|
| **Finished**: the model ended its turn (`end_turn`, `stop_sequence`, or a tool call the server completed) with something to show | `done {charged: true, credits}` | the answer's usage, plus a title, suggestions or map update that was relayed; never above the hold | `completed` |
| **The reader pressed Stop**, and their app recorded it (`v1_chat_stop`, capability `stop_signal`) | nothing more (they left) | the part written so far (since 2026-10-21: OpenRouter's generation record for the input and the observed share of the output, else the observed output only; [PROVIDER_SPENDING.md](PROVIDER_SPENDING.md#stopped-answers-and-unresolved-attempts-a1-a6)); nothing if no text or tool call had arrived | `stopped` |
| **A build without `stop_signal` closed the stream** (builds up to 60: Stop and a dropped connection look the same) | nothing more | as a Stop (unchanged) | `left` |
| **The provider failed or overloaded**: refused before the start (429/529/5xx, its breaker open), failed mid-stream (an error event, the connection to it lost), or finished a turn with nothing to show | `error provider_unavailable {credits: 0, charged: false, reason: "provider", retry_after}` (an empty finished turn: `done {charged: false, reason: "provider"}`) | nothing | `provider` |
| **Our server failed**: a send it could not admit or record, a fault in our code, an instance that died (the 30-minute stale-hold sweep settles those) | `error service_unavailable {credits: 0, charged: false, reason: "server", retry_after: 10}` (a dead instance sends nothing) | nothing | `server` |
| **Our time limit**: the 130 s generation deadline | `error provider_unavailable {credits: 0, charged: false, reason: "limit"}` | nothing | `limit` |
| **Our length limit**: `max_tokens` (or the model's context window), or a next round that no longer fits the hold or the search allowance | `done {stop_reason: "max_tokens", credits: 0, charged: false, reason: "limit"}`, or the error above | nothing | `limit` |
| **The connection between our server and the reader dropped** (an app with `stop_signal` that recorded no Stop) | nothing (it is gone) | nothing | `connection` |
| **A refusal** (`stop_reason: refusal`, after any server-side fallback) | `error refused {credits: 0, charged: false, reason: "refusal"}` | nothing | `refusal` |

A refusal is a refusal even if the reader also left; a finished turn with something to show is **completed** even if the
reader left as it finished or afterwards (since 2026-10-21, review A12: the connection dropping during the title's
grace, the suggestions or the map no longer makes a finished answer free; those side requests, never relayed, are
Gradstep's). Otherwise the reader leaving while the answer was written decides first, then a deadline that cut the
answer short, then the provider's or our own failure, then a length limit. The server can only see a connection drop
when it happens before the answer is handed to the network: an answer that finished and was written into a
connection that then failed is charged as finished.

### Each paid feature

| Paid feature | Finishes (the reader pays) | Ends early (nothing) | Its side requests |
|---|---|---|---|
| **Chat answer**, and the selection actions (Explain, Why it matters, Related) | a finished turn with text, a diagram, a visual, figure parts or a figure request | every unpaid row above | **Title** (Haiku, beside the answer): paid only with a completed answer whose title was relayed; failed, unusable or abandoned after its 4 s grace, or with an answer that ended early, it is Gradstep's. **Follow-ups**: asked only after a finished answer (since 2026-10-16 not after `max_tokens`); relayed → paid; failed, unusable or later than 8 s → Gradstep's. |
| **Study turn** | the tutor's reply finished | as an answer | **Map update**: asked only after a finished reply; relayed → paid; failed, unusable or later than 12 s → Gradstep's, and the map stays as it was |
| **Equation view** (symbols) | the model's JSON, or its words shown as the description | cut at its 2,000-token allowance (`limit`); no words at all (`provider`) | — |
| **Equation background** | finished prose | as an answer | — |
| **Figure view** (walkthrough, FIGURE_VIEW.md) | the checked walkthrough, or its words shown as the description | cut at its allowance (`limit`); nothing usable to show (`provider`) | — |
| **Figure view, more simply** | finished prose | as an answer | — |
| **Diagram repair** (`diagram_fix`) | a finished turn with the corrected diagram | as an answer | — |
| **Add paper** (Ingest) | the model identified the citation | as an answer | The lookup and add run after settlement: a lookup or add that fails afterwards is reported in the answer but not refunded (open item below) |
| **Podcast episode** (unchanged, migration 048) | `ready`: known usage, at most the length's maximum | failed for any reason (script, speech, evidence check, provider, retries exhausted), `unknown_provider`, quarantined: 0 credits, the cost recorded as the job's `platform_loss_microusd` | **Cancel** (the reader stops it): known usage so far, at most the maximum — the part they chose to stop |

### How it is recorded

- `worker_settle_chat(account, operation, credits, microusd, action, ending, absorbed_microusd)` settles exactly as
  `worker_settle_operation` (the provider spend reported to the month is unchanged: every attempt's cost, paid or not)
  and writes `app_private.chat_endings` (operation, action, ending, `charged`, credits, `absorbed_microusd`) in the same
  transaction. An unpaid ending must charge 0; an identical replay is a no-op, any other conflicts. The stale-hold sweep
  records a dead instance's operation as `server` with its held attempts' cost absorbed. `absorbed_microusd` is the
  provider cost the reader did not pay: everything for an unpaid ending, the undelivered side requests for a completed
  one (a Stop's unrelayed title too). Codes and amounts only; kept with the operation like its quote.
- The chat function logs `ending`, `charged` and `credits` in `chat_answer`. Our own causes reach it as `cause` on the
  provider outcome (`server`: an admission refused or unrecorded, a throw in our code; `limit`: `operation_ceiling`,
  the round or search bound); a failure without one is the provider's.
- **What `done` reports (2026-10-21, review A23).** `credits`/`charged` are what the settlement recorded. A settlement
  the database refused, or one never acknowledged, is read back (`worker_operation_outcome`); an operation still open
  is reported `charged: false, reason: "server", credits: 0` (the stale sweep settles it that way) and the log line
  carries `settlement: rejected|unknown`. Ingest's ledger row keeps the number of keys the model sent (`key_count`),
  never the model-chosen names.
- **Stop.** An app that sends `capabilities: ["stop_signal"]` calls `v1_chat_stop(p_operation_id)` (authenticated, its
  own chat operation only; `{recorded, settled}`) and waits for it, at most about 3 s, before it cancels the stream.
  When the stream closes the function asks `worker_chat_stop_requested`, once more after 1.5 s if not found; found
  → `stopped`, otherwise `connection`. A request the provider never started charges nothing even when stopped.
- **Abuse guard.** An app could drop every stream instead of pressing Stop. An account with more than **20** unpaid
  early endings in a UTC day (`app_private.paid_work_guard.uncharged_endings_daily_attention`) is listed in the admin's
  Health › Attention with what Gradstep paid; the reader is never blocked for it. Test accounts are left out of that list
  (their cost is still counted).
- **Health.** `v1_admin_health` adds `early_endings` (answers by ending over the window, unpaid ones, absorbed cost,
  today's, the accounts over 20) and `worker_budget_health` adds `uncharged_endings_today` and
  `absorbed_microusd_today` for the scheduled budget check.
- Evidence: `tests/backend/chat.test.ts` (one test per ending, each side request, the equation view and Study, a real
  SDK mid-stream error event), `tests/backend/provider-spending.test.ts` (our causes),
  `tests/database/contained_overruns.sql`; live on staging 2026-10-16: `node scripts/fault-drill.mjs --mode=throttle`,
  `--mode=midstream`, `--mode=stop` and `--mode=overrun` ([RESILIENCE.md](RESILIENCE.md#fault-drills)).

### For the clients

Status: **iPhone, iPad, Mac** built in `f99a86d` (after build 60); **browser** built 2026-10-16
(`chat.ts` `stop_signal`, `charged`/`reason`, `interruptionNote`; `chat-session.ts` records the Stop then cancels;
unit tests in `tests/chat.test.ts` and `tests/chat-session.test.ts`; journey `e2e/chat.spec.ts` "Stop, navigation while
streaming…" with the fixture's `midstream` mode and `v1_chat_stop`), deployed from main by the owner. The notes are
kept for the session only; an answer reopened later keeps "Answer interrupted" (browser) / "Response interrupted"
(apps).

Builds 57–60 keep working unchanged: they ignore the new fields, already show "No credits were used" for an error with
`credits: 0` (native) or "No credits used" (browser), and a Stop from them is charged as before (`left`).

- Send `"stop_signal"` in `capabilities` on every chat request (with the others the build sends). On Stop: call
  `v1_chat_stop({p_operation_id})` with the request's operation id, wait for it (at most 3 s, ignore its failure), then
  cancel the stream. Then refresh the balance.
- Read `charged` (boolean) on `done` and on `error`; when it is `false`, `reason` is one of `provider`, `server`,
  `limit`, `refusal` (`connection` and `stopped` are recorded but never sent: the reader has gone). An `error` without
  `charged` came before anything was held: nothing was charged.
- Copy under a kept, interrupted answer that was not charged: **"Interrupted · not charged"**; for a refusal, the
  existing refusal message followed by "Not charged." After the reader's own Stop: **"Stopped · charged for the part
  written"** (or **"Stopped · not charged"** when the server said 0 credits). A `done` with `charged: false` (a
  `max_tokens` answer) is interrupted too. The equation view shows no credit counts at all (owner, build 59).

Native, October 21 (code review A3, A8, A9; local, not released): only the reader's own Stop records a Stop. Closing an
equation or figure sheet leaves its chat answer running under that sheet's composer, as Chat does when the
conversation changes, and saves it there. A complete answer whose save on the device fails stays readable; its Try
again saves that same answer and never asks (or pays) again. A question about a paper still being prepared on the
device shows "Preparing the paper on this device…" with Stop, which withdraws it before anything is sent (the question
stays saved, with Get answer).

### Open items

- **Add paper after settlement** (closed 2026-10-16). Ingest now finds and adds the paper before the settlement (the
  import takes no hold), so an add that doesn't happen for a reason that isn't the reader's (`not_found`, `unavailable`,
  `failed`, `closed`, `needs_update`, an `add_paper` call the server couldn't read, or no call at all because the model
  couldn't tell which paper the passage names) settles 0 credits with the provider cost absorbed, and its report ends
  "Not charged." An add (`added`) or a paper already there (`present`) is paid as any answer; the reader's own Stop pays
  for the part written. `done.credits` is 0. Live (staging, 2026-10-16): `scripts/chat-live-smoke.mjs --ingest=…`.
  Tests: `chat.test.ts` "an add that doesn't happen costs the reader nothing…".
- **Aborted attempts stay unknown.** A Stop or a dropped connection leaves the provider attempt `unknown` (no final
  usage) until an operator reconciles it; the scheduled budget check flags any older than an hour
  ([SPENDING_CONTROLS.md](SPENDING_CONTROLS.md), audit item 1).

## Privacy

- Plaintext leaving the device per answer: the question, earlier turns of that branch (bounded as above), an optional selected passage and, for paper chat, the paper MMD that the server already holds. Under consent v3, the image of a figure or table the question names ("Figures in chat"). Prompts are built on the device from decrypted history; nothing else (notes, other chats, keys) is sent.
- The function stores no chat text: no tables, queues or logs. Logs carry only event names, operation IDs, counts and codes. The answer returns to the device, which seals it with the existing encrypted append path.
- Anthropic processes and may retain request content under its API terms; no zero-retention claim is made. Consent copy says so. Since 2026-10-16 a reader may choose DeepSeek (consent v4): DeepSeek then processes the answer's request (question, earlier turns, selection, paper text, figures) under its API terms, while the title and follow-up suggestions still go to Anthropic.
- First-use consent is per environment/account in the device Keychain (`<env>.<account>.cloud-ai-consent` = `cloud-ai-v2`, the current consent text; a stored `cloud-ai-v1` is re-asked), not in chat history. The question is saved locally first; consent then binds the request to that saved turn. Declining keeps the question and offers “Get answer”.

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

## Visual answers — 2026-10-15 (owner: "The chat needs a html tool… mermaid diagrams… an option for the users to disable")

Beside an answer the model may show one visual: a Mermaid diagram (`create_diagram`, as before) or an HTML fragment
(`create_visual`): a flow chart or pipeline drawn as inline SVG, a timeline, a decision tree, a comparison table,
annotated steps. The written answer stays complete on its own; the model is told to call at most one of the two.

- **Server** (`supabase/functions/_shared/chat-visual.ts`): the fragment is untrusted. `sanitizeVisual` keeps a finite
  vocabulary (structure, text, lists, tables, `<style>` and inline CSS without external references, inline SVG shapes
  and markers with fragment references only, links to https only), drops images and media quietly, and refuses the
  whole visual on anything script-like (`script`, `iframe`, `object`, handler attributes, `javascript:` URLs). Input
  at most 16 KB (the tool asks for under 12 KB so a Standard answer fits), output at most 24 KB. The sanitized
  fragment is relayed once as the SSE event `visual {title, html}` before `done` (`chat_visual` /
  `chat_visual_invalid_input` in the logs; never the text). Builds before the event ignore it.
- **Setting.** "Visual answers" (Settings › Chat on the apps; AI chat options in the browser), per device, on by default.
  The request's `capabilities` list carries `visual_answers` when on and is sent empty when off; a request that names
  no capabilities at all (builds before the setting) still gets diagrams. Off, the model is told to answer in prose and
  neither tool is offered.
- **Storage.** The device keeps a visual as a `diagram` event with `format: "html-v1"` (`ChatDiagram`; browser
  `makeDiagram`), encrypted like a Mermaid diagram; builds that know only `mermaid-v1` ignore it rather than fail.
- **Rendering.** iPhone, iPad and Mac: `HTMLVisualWebView`, a WKWebView with content JavaScript off, a non-persistent
  store, a page of its own with CSP `default-src 'none'; style-src 'unsafe-inline'`, navigation cancelled; opened from
  the answer's "View visual" button and listed under All diagrams. Browser: an inline `<iframe sandbox="">` (no
  scripts) with the same document, and "Full size" in a dialog.
- **Cost.** The tool's schema is part of the prompt the hold already counts; the fragment is output tokens within the
  profile's allowance; drawing costs nothing. No new accounting.
- **Proof.** `node scripts/chat-live-smoke.mjs --question="…as a visual…"` (about $0.25): on 2026-10-15 the model
  answered a pipeline question with a 2.3 KB visual (`style div h3 span`) relayed as `visual` and a flow question with
  a Mermaid diagram. Tests: `tests/backend/chat.test.ts` (sanitizer, request validation, capability gating, relay),
  `ChatVisualTests` (native format, request capability, page policy), `apps/web/tests/chat.test.ts` (event, format).

Not built: figure crops (`docs/proposals/CHAT_TOOLS.md`), which need a consent for sending figures to the model.

## Figures in chat — 2026-10-15 (owner: "the agent has the ability to break figures into cropped sub sections… and explain each component"; "Sending figures to model should be ok?")

A question that names a figure or table ("What does Figure 2 show?", "compare Fig. 3 with Table 1", or a selected
passage that names one) carries that figure's image, so the model reads the figure itself, not only its caption.

- **Device** (`ChatFigureFinder`): finds the figures by their captions in the open paper's bundle, at most two, and
  prepares each image as the provider reads it best (at most 1,568 px on a side and about 1.15 megapixels, JPEG on
  white). The image is the paper's own figure from arXiv's HTML, already on the device; no PDF, nothing new fetched.
- **Consent `cloud-ai-v3`.** The consent screen now lists "When you ask about a figure or table, its image from the
  paper"; readers who accepted v2 are asked once more. The server accepts figures only under v3, only in a paper chat,
  never with Add paper or a diagram repair (`chat-figures.ts`: ids F1–F3, a paragraph number, a bounded PNG/JPEG
  whose bytes match their type). The request digest covers the images. Settings › Privacy's summary says so too.
- **Cost.** An image is held as 1,600 input tokens (Anthropic bills about width × height / 750); the hold no longer
  counts its base64 as text. About half a cent per figure on Sonnet.
- **Figure parts.** The model may call `show_figure_parts` with 1–8 boxes (fractions of the image) and a label and note
  each. The server checks them against the attached figure and relays `figure_parts`; with no prose of its own the
  answer becomes the parts' notes. The device keeps them as a `diagram` event of format `figure-parts-v1`
  (`StoredFigureParts`: the parts and where the image is in the bundle, never the image) and shows the crops under
  the answer; a tap opens the whole figure with the parts outlined and numbered, each crop with its note. Without
  the paper on the device, the notes alone. The tool is offered with Visual answers on, in paper chats; it is part
  of the cached prefix, so a figure question costs no extra cache write.
- **Proof** (staging, 2026-10-15): `node scripts/chat-live-smoke.mjs --figure=1 --question="What does Figure 1 show?
  Walk me through each part of it."` on DPO: the answer read the figure's own details (the trophy marking the
  preferred response, the example prompt) and gave five parts with boxes that crop the right regions (rendered by
  `FigurePartsRenderingTests`). 5 credits with the paper cached.
- **Asking for a figure** (2026-10-15, owner: "Not able to do this"; "Even when I referenced a figure it still didn't
  work"): a question about a figure that names no number ("break down the most complex figure") attached nothing. A
  device that holds the paper now sends the `figure_requests` capability; under consent v3 the server then offers
  `look_at_figure` beside the parts tool (in every such request, so the cached tools never change), and the model
  names the figure it means. The server relays `figure_request` ("Figure 2"), skips suggestions for that answer, and
  the device asks the same question again once with that figure attached; the first answer was only the request and is
  not kept. Both apps and the browser say "Looking at Figure 2…" while a figure goes with a question. Proof on
  staging (`scripts/chat-live-smoke.mjs --look`): the model asked for DPO's Figure 2, the second answer split it into
  four parts; 25 credits for the first request (it wrote the paper to the cache) and 5 for the second.
- **Figures of several panels** ("Figure 1" with (a) and (b)): the converter keeps picture panels under one caption
  as one figure (renderer revision 12), and chat sends the panels as one image, stacked at the widest panel's width
  with 2 % gaps; the stored parts list every panel (`assetPaths`) so either surface composes the same image to crop.
- **Browser** (2026-10-15): the same rules (`apps/web/src/lib/chat-figures.ts`): consent v3 (readers who accepted v2
  are asked once more, the dialog names figures), at most two named figures from the open paper's bundle prepared as
  JPEG on white with a canvas, the `figure_parts` event kept as the same `figure-parts-v1` JSON the apps write (so either
  surface shows the other's parts), crops under the answer and the whole figure with numbered outlines in a dialog.
  Images are shown as `data:` URLs (the page's image policy admits no `blob:`). Journey: `e2e/arxiv-html.spec.ts`.
- **Crops inline, where the answer discusses each part** (2026-10-15, owner: "It should display sub figures at the
  bottom the crops should be inline, right as the chat discusses each one"). The model writes a line `[[part N]]` on its
  own right before the paragraph about part N, then calls `show_figure_parts` with the parts in that order; with no
  prose of its own the fallback answer carries the same markers. The apps (`FigurePartMarkers`, `InlineFigurePartsAnswer`)
  and the browser (`chat-figures.ts`, `Diagram.tsx`) show part N's crop with its number and label at its marker, and
  the whole figure, small with the parts outlined and numbered, at the bottom (a tap opens it). A marker is never
  text: it is left out while streaming (with a half-arrived one at the end), when copying, in previews, and when its
  part does not exist. Answers saved before keep the strip of crops under the answer. Proof on staging: DPO's Figure 1,
  `[[part 1]]` before the three RLHF steps and `[[part 2]]` before the DPO pipeline, 28 credits, 14.8 s. Journeys:
  `WorkflowJourneyTests/testFigurePartsAreInlineWhereTheAnswerDiscussesThem` (`--chat-fixture-mode=figure_parts`) and
  `e2e/arxiv-html.spec.ts` (text, part, text, part, text in order).

## Chat redesign from build 57 feedback — 2026-10-16

Owner, TestFlight build 57 (four reports, 2026-10-16 02:41–02:48 UTC), with Gemini screenshots as the design reference:
"the user should set the length, and the effort level should be chosen intelligently based on a sensible default";
"deep seek should be an option. We need one that supports images"; "an option to set the current options as the
default for chats, which should also be available in settings (same options here and in chat)"; "a link Read about AI
chat options… where the same options are listed (defaults can be chosen) but more detail is provided on how many
credits are likely to be used"; "literally nothing else is needed on this UI"; "We can't have the typing window
awkwardly to the right side"; "put the chat settings in the top right drop down with the other options. Please also put
in there Enter Study Mode"; "Change Chat to Ask Anything about the Paper"; "Use the Gemini screen shot to provide starter
questions, have a list of good ones, not always the same boring ones."

One design, expressed on iPhone, iPad, Mac and the browser:

1. **Answer options** (the sheet/popover): Model — Haiku · Sonnet · Opus · DeepSeek, with its one-line detail; Length —
   Brief · Standard · Detailed, with its detail; **Use for new chats** (shown when the chat's choice differs from the
   default; afterwards "New chats start with these"); a link **About AI chat options** that opens Settings › AI chat
   options. Nothing else: no effort control, no credit estimate, no Reset.
2. **Effort is automatic.** New clients send `effort: "auto"`; the server picks low, medium or high from the length and
   the question (below) before it holds credits, and holds and records the effort it picked. Older builds keep sending
   explicit efforts, which stay valid.
3. **Settings › AI chat options** (renamed from Chat defaults): the same Model and Length pickers, setting the defaults
   new chats start with; then per-model detail (what it is good at, who processes the request) and the credit table
   from the server's published estimates (usually X–Y credits per question for each model and length, and the most
   one answer can cost); one line saying effort is chosen automatically.
4. **The chat's ⋯ menu** gains **Answer options…** (subtitle: the current "Sonnet · Standard") and **Study mode**
   (enter; **End study mode** while studying). The composer no longer carries the options chip; the empty chat no
   longer carries the Study button or its description.
5. **The composer** is one full-width pill: the field, then Send (Stop while answering) inside the pill on the right.
   Nothing beside the pill: the keyboard is dismissed by scrolling the transcript, tapping outside the field, or Esc.
   Placeholder: **Ask anything about the paper** (paper chat), **Ask anything** (general chat), **Your answer** (study).
6. **Starter questions** (Gemini's layout): in an empty chat, three rows directly above the composer, each a small icon
   and one line of text, left-aligned, no heading. A tap fills the message box and focuses it; nothing is sent until
   the reader sends (as follow-ups). A soft accent glow rises behind the lower part of the empty chat (dark and light).
   - Chosen on the device from a pool (`tests/fixtures/chat-starters.json` holds the pool and the selection cases both
     clients test against): three different categories, at least one about this paper's own structure when it has any
     (a figure, a numbered equation, a table or a method section), drawn afresh for each new chat and stable while
     that empty chat is shown.
   - Paper categories: overview, method, figure, equation, table, results, critique, background. General chat: a pool
     of ML research starters.

### Automatic effort (server)

`effort: "auto"` resolves before the hold: Brief → low. Standard → low, or medium when the question asks for reasoning
(derive, prove, show that, step by step, why does/is, compare, trade-off, intuition, explain equation/term, how does …
work) or carries an equation or figures. Detailed → medium, or high when the question asks for reasoning. The quote and
the answer record the resolved profile (`sonnet-medium-standard`); the published table lists `auto` profiles with the
estimate of the effort usually picked and the maximum of the highest.

### DeepSeek in chat

`deepseek` → `deepseek-flash` (DeepSeek V4.1 Flash: image input, tools, thinking, streaming; 1M context) through
DeepSeek's Anthropic-compatible API (`https://api.deepseek.com/anthropic`), so the request is the Anthropic request with
another base URL, key and model. Priced at DeepSeek's peak list rates. Allowed only under a consent version that names
DeepSeek; web search through Tavily (our tool), never a provider search tool. Offered only after a recorded check of
equation handling, figure questions, citations ([¶n]) and the visual tool on the evaluation papers.

### All chats (owner, build 57, 2026-10-16 02:51–02:55 UTC)

"You can put All to the left and make that the default"; "Last read not last used"; "The paper should only be in its
column not duplicated on left column"; "Poor use of space at the top. Please have the search bar at the top with the
three lines at the right of the search bar… done can be an option remove it. All chats message can also go. simplify".

- The top is one row: the search field, and beside it a ≡ button (three lines) holding the options: Sort by, Columns,
  and Close. No title, no Done button (the sheet still closes by swiping down or Esc).
- Filter chips: **All** first and chosen by default, then This paper (when opened from a paper), Paper chats, General.
- The time column is **Last read**.
- With the Paper column chosen, the conversation's second line is its passage or newest answer, never the paper title.

### Server implementation — 2026-10-16 (staging; migration 078, chat function redeployed)

Status: deployed to staging on 2026-10-16 (~03:20–03:28 UTC): migration `202610160078_chat_deepseek.sql` applied and
verified, the `chat` function deployed with `CHAT_DEEPSEEK=hidden` for the recorded check below and then with
`CHAT_DEEPSEEK=on`; the deploy suite passed both times (19 passed, `chat.smoke` included). The clients' answer options,
consent v4 and settings are the client agents' work; until they ship, nothing a reader can send changes.

**Automatic effort** (`chat-profiles.ts`: `parseChoice`, `autoEffort`, `resolveChoice`). A request may name
`effort: "auto"`; `low`, `medium` and `high` stay valid. `runChat` resolves it from the newest question, the selected
passage and the attached figures before anything is held, then builds, holds, quotes and records the resolved profile
(`sonnet-medium-standard`): the quote's `effort` is never `auto`, so `chat_quotes` is unchanged. The request digest
keeps `"effort":"auto"` (what was sent), so `{sonnet, auto, standard}` is its own request even when it resolves to the
default. Every path that consumes the profile reads the resolved one (the answer's model, effort and allowance, the
equation view, Study, the hold and quote); titles, follow-ups and Study maps keep their own fixed Haiku requests.
Rules, deterministic and pure (a table of 25 questions in `tests/backend/chat-profiles.test.ts`):

| Length | Effort picked |
|---|---|
| Brief | low |
| Standard | medium when the question asks for reasoning, carries an equation (in the question or the selected passage) or has a figure attached; otherwise low |
| Detailed | high when the question asks for reasoning; otherwise medium |

"Asks for reasoning": derive/derivation, prove/proof, show that/why/how, step by step, walk me through, why
does/is/do/are/… (and the negated forms), compare/comparison/versus/vs./difference between, trade-off, intuition,
explain … equation/term/formula/expression/objective/loss/derivation/theorem/lemma/proof/bound, how does/do/… work.
"An equation": a LaTeX command (`\frac`, `\sigma`), `\( \)` or `\[ \]` or `$…$`, a sub- or superscript (`x_i`), a
single-letter variable set equal to something, or a mathematical symbol or Greek letter. Only the question is read
for reasoning (a passage saying "we derive" asks nothing). `done` carries the resolved `profile` and, for an `auto`
request only, `effort` (the pick); `chat_answer` logs `auto_effort` and `provider`.

**Published table** (`GET functions/v1/chat`, still `chat-profiles-v1` with the default `sonnet-low-standard`, because
builds 57/58 refuse any other version or an unknown default). Additive only: the 27 Claude profiles first and byte for
byte as before; then DeepSeek's nine explicit profiles; then 12 `auto` profiles (one per model and length); 48 in all,
so everything is within the 64 the old decoders read. Old decoders skip unknown model and effort ids and ignore
unknown keys; `tests/backend/chat-profiles.test.ts` decodes the new table with a frozen copy of the build 57/58 rules
against the table those builds shipped with (`tests/fixtures/chat-profiles-v1-build57.json`) and requires the same
result, and the live table was checked the same way on staging. New fields for new clients:

```json
{"version":"chat-profiles-v1", "default":{"model":"sonnet","effort":"low","length":"standard"},
 "default_auto":{"model":"sonnet","effort":"auto","length":"standard"},
 "models":[…,{"id":"deepseek","label":"DeepSeek","detail":"Low cost; processed by DeepSeek","api_model":"deepseek-flash",
   "provider":"deepseek","consent_version":"cloud-ai-v4"}],          // every model also carries "provider"
 "efforts":[…,{"id":"auto","label":"Automatic","detail":"Chosen for each question"}],
 "profiles":[…27 Claude…, …9 deepseek-{low,medium,high}-{length}…,
   {"id":"sonnet-auto-standard","model":"sonnet","effort":"auto","length":"standard","api_model":"claude-sonnet-5-5",
    "max_output_tokens":10000,"credits":{"low":4,"high":24,"max":41}}, …]}
```

An `auto` profile shows the estimate of the effort usually picked for its length (brief → low, standard → low,
detailed → medium) and the maximum and allowance of the highest it can pick (low, medium, high). Clients should start
new chats from `default_auto`, send `effort: "auto"`, offer DeepSeek only when the table lists it, and send it only with
consent `cloud-ai-v4`. DeepSeek's detail is not "lowest cost": at list prices Claude Haiku 5.5 ($0.10/$0.50 per million
input/output tokens) is cheaper than DeepSeek Flash even off-peak ($0.15/$0.60); DeepSeek's estimates sit between
Haiku's and Sonnet's (Standard: 1–3 credits, at most 5; Sonnet 4–24, at most 37).

`CHAT_DEEPSEEK` (infra `chat_deepseek`, `deploy-staging.py --chat-deepseek on|hidden|off`): `on` publishes and accepts
DeepSeek, `hidden` accepts it without publishing it (for the recorded check), `off` does neither. Since 2026-10-18
DeepSeek is served through OpenRouter (DeepInfra) with `OPENROUTER_CHAT_API_KEY`; no `DEEPSEEK_API_KEY` exists any more
(2026-10-21: the deploy removes a leftover one and the check fails on it). A DeepSeek choice the
server does not accept is `invalid_request`; the deploy check `config.function-secrets` compares the switch with infra.

**DeepSeek request** (`deepseek.ts`: `deepseekChatParams`, `streamDeepSeekChat`; `chat/index.ts` routes by model). The
answer's Anthropic-shaped request goes through the same SDK to `https://api.deepseek.com/anthropic/v1/messages` with
DeepSeek's key and `model: "deepseek-flash"`, adaptive thinking and `output_config.effort` as for Claude, the paper
block with its one-hour `cache_control` (accepted, ignored; DeepSeek caches on its own), figure images in base64 and
our client tools (`create_diagram`, `create_visual`, `show_figure_parts`, `look_at_figure`, `search_web`). It drops
Anthropic's betas and refusal fallbacks, never carries Anthropic's server `web_search` tool (stripped in the adapter,
never offered by `runChat`, never a failover target), and sends our Tavily results as text blocks (DeepSeek does not
accept `search_result`). Every DeepSeek attempt is priced as the requested model (DeepSeek bills by the name sent).
The title, follow-up suggestions and Study map stay on Claude Haiku 5.5. A live probe on 2026-10-16 (two tiny calls,
under $0.001) established the usage shape: `input_tokens` are cache misses and `cache_read_input_tokens` hits (a repeat
read 384 of 574 from cache), no cache writes; thinking streams as `thinking` blocks and counts as output; the response
names `deepseek-flash`; there is no request-id header (the message id is recorded); a 1360×501 figure was 411 input
tokens (held as 1,600).

**Prices and holds.** Tariff `deepseek-peak-list-prices-2026-10-16` in the quote ($0.30 per million input tokens on a
cache miss, $0.006 on a hit, $1.20 output; [DeepSeek's pricing](https://api-docs.deepseek.com/quick_start/pricing/),
re-read 2026-10-16; off-peak is half, so readers and the budget are never under-charged). Held at those rates with two
attempts' headroom (`DEEPSEEK_HOLD_ATTEMPTS`: no fallback, but no token count before the request either), so a DPO
answer holds about 59 credits with search offered (its first round's ceiling about $0.10) against a measured
$0.004–0.013.

**Accounting.** Each DeepSeek round is admitted as provider `deepseek` on the `chat` route (migration 078 admits only
`deepseek-flash` there; any other DeepSeek model or route stays `invalid_provider_route`, and a DeepSeek attempt that
reserves provider searches is denied `native_search_unbounded`), with pricing snapshot
`deepseek-token-rates-peak-20261016`; its Haiku title and suggestions are Anthropic attempts in the same operation.
Each attempt writes its own `provider_usage_events` row under its provider; migration 078 keeps the chat function's
operation summary (now recorded under the answering provider) out when model attempts already carry the spend. Health:
calls to `api.deepseek.com` are counted under `deepseek` with their own breaker, so a DeepSeek outage never opens
Anthropic's (and an answer refused by it ends as `provider_unavailable` with `retry_after`, unbilled).

**Consent `cloud-ai-v4`.** v3's text plus DeepSeek, named as the processor when the reader chooses it. The server
accepts v1–v4; v4 behaves as v3 for Claude answers (Tavily and figures named); a DeepSeek choice under v1–v3 ends as
`error {code: "consent_required"}` before any hold (after the request is counted against the rate limit). Proposed
wording for the clients (the v3 list, with the first sentence and one bullet changed and one added):

- Opening line: "Answers come from Claude, an AI model by Anthropic, or from DeepSeek when you choose it in Answer
  options. To answer, Gradstep sends:"
- New bullet: "When you choose DeepSeek, your question, the paper's text and any figure go to DeepSeek, which writes the
  answer; Claude still writes the chat's title and suggested follow-up questions"
- Closing paragraph: "Anthropic, or DeepSeek when you choose it, processes this to write the answer and may keep it for
  a limited time under its API terms; search services see only the searches and may keep them under their own terms.
  Gradstep's servers pass it through without saving it; your saved conversation stays encrypted with your device keys."

**Replacement for "chat uses Claude only"** (How Gradstep works, SettingsPages.swift and HowGradstepWorks.tsx): "Chat
answers come from Anthropic's Claude models, or from DeepSeek when you choose it in Answer options (Claude still writes
the chat's title and suggested questions); podcast scripts can also be written by DeepSeek when you choose it for an
episode."

### Recorded check of DeepSeek — 2026-10-16 (staging, before it was published)

`node scripts/chat-live-smoke.mjs --profile=deepseek-auto-standard --eval` with `CHAT_DEEPSEEK=hidden`: a disposable
account (deleted through account-delete), the DPO v3 metadata membership and its numbered local context v2, four
questions each in a new conversation under consent v4; every `\( \)` and `\[ \]` segment typeset with the browser's
temml (errors thrown), citations resolved against the paper's blocks, the quote and provider attempts read back from
the database. Report: `.artifacts/chat-eval/2026-10-16T03-26-41-846Z-deepseek-auto-standard.json`.

| Question | Profile picked | Equations (valid/all) | [¶N] resolvable | Tools | First text / total | Credits | DeepSeek cost |
|---|---|---|---|---|---|---|---|
| Why does DPO need a reference model, and which equation defines the loss? | deepseek-medium-standard | 30/30 | 29/29 | — | 7.9 s / 15.9 s | 3 | $0.0124 |
| Derive the DPO loss from the KL-constrained objective, step by step. | deepseek-medium-standard | 48/48 | 40/40 | visual (3,050 B) | 22.6 s / 38.5 s | 2 | $0.0084 |
| Show me how the DPO training pipeline works, as a visual. | deepseek-low-standard | 23/23 | 17/17 | Mermaid flowchart | 8.0 s / 15.1 s | 3 | $0.0121 |
| What does Figure 1 show? Walk me through each part of it. (Figure 1 attached) | deepseek-medium-standard | 3/3 | 7/7 | 4 figure parts, `[[part N]]` markers | 10.1 s / 19.7 s | 1 | $0.0038 |

All five checks passed: (a) equations: 104 of 104 segments typeset, no `$` delimiters (six display equations used
`\tag{n}`, which temml typesets; native SwiftMath support for `\tag` is unverified and worth a client check); (b) citations: 93 markers, all
resolvable, placed after the statements they support (Eq. 7 at [¶33], the SFT reference at [¶24]); (c) the figure
answer read the image itself (the example prompt "write me a poem about the history of jazz", the trophy on the
preferred response, the teal "maximum likelihood" and red "reinforcement learning" labels; none of it is in the text)
and its four part boxes crop the right regions; (d) the visual and diagram tool calls and `show_figure_parts` parsed
and relayed; (e) every answer streamed (700–2,071 `delta` events). Quotes recorded `deepseek-*-standard`,
`deepseek-flash`, the DeepSeek tariff; every DeepSeek attempt's `actual_microusd` equals its tokens at peak rates
exactly; one usage row per attempt, none twice. Whole check: 9 credits, $0.038 of provider spend (Haiku titles and
suggestions included). Noted: DeepSeek thinks before it writes, so the first text came 8–23 s in (medium effort).

The same four questions on Sonnet `auto` (`--profile=sonnet-auto-standard --eval`, after DeepSeek was published; report
`.artifacts/chat-eval/2026-10-16T03-30-18-172Z-sonnet-auto-standard.json`) are also the live check of automatic effort
on the default new clients will use: it picked medium, medium, low and medium (the same picks as for DeepSeek), every
quote recorded the resolved `sonnet-*-standard` profile and effort, `done.effort` named the pick, and all settled.
Sonnet: equations 70/70, citations 71/71 resolvable, a visual (1,433 B) for the pipeline question, the figure read
from the image but no `show_figure_parts` call this time, first text 2.0–2.9 s, 57 credits and $0.273 (the first
answer wrote the paper to the one-hour cache: $0.207). DeepSeek gave longer, more heavily cited answers for about a
seventh of the cost, and slower first text.

### DeepSeek at low effort, and choosing the default (2026-10-16 ~16:05 UTC)

Owner: "We should consider making DeepSeek, or another provider, the default… which models have highest bang for buck…
if people run out of credits all the time it will be annoying." `--profile=deepseek-low-standard --eval`
(`.artifacts/chat-eval/2026-10-16T16-04-48-898Z-deepseek-low-standard.json`): 1 credit per answer, equations 80/80
typeset, citations 57/57 resolvable (the first answer cited none), Figure 1 read from the image with 3 parts; but the
pipeline question drew no visual, and first text still came 7.5–14.9 s in (8–23 s at medium): DeepSeek's latency is
the service's, not the effort's.

At list prices (rate card in `anthropic.ts`, $/M tokens: input · 1-hour cache write · cache read · output) Sonnet 5.5 is
2 · 4 · 0.10 · 10, DeepSeek Flash (peak) 0.30 · 0.30 · 0.006 · 1.20, Haiku 5.5 0.10 · 0.20 · 0.01 · 0.50 (×5 above 100k
prompt tokens). A paper's first question writes the paper to the cache: ~$0.19 on Sonnet (≈40 credits), ~$0.01 on
Haiku. That was a short-paper estimate, not evidence that Haiku is universally fastest or cheapest. The later
matched comparison below measures native token counts, length tiers, cache state and answer latency. Haiku reads
images and keeps Anthropic as the only processor (no consent change);
it has not been run through `--eval` yet (the staging Anthropic balance ran out the same afternoon). Next: the same eval
and a figure walkthrough on Haiku, then pick the default (published table `default`/`default_auto`; a Haiku default is a
known profile older builds accept, a DeepSeek default would need consent v4 from every reader).

Owner, same day: "Are you sure Haiku 5.5 is really smart enough? are there other cost efficient options out there?"
Prices re-read from the providers' own pages 2026-10-16 ($/M input · output): Haiku 5.5 0.10 · 0.50 (≤100k prompt);
DeepSeek Flash 0.15 · 0.60 off-peak, 0.30 · 1.20 peak, image input; Gemini 3.8 Flash 0.75 · 3.75, doubling to
1.50 · 7.50 on 2027-01-01, cache reads 0.075 plus 0.50/M per hour of storage; Gemini 3.5 Flash-Lite 0.30 · 2.50;
Gemini 2.5 Flash-Lite 0.10 · 0.40 (older generation). That initial shortlist was incomplete. The owner subsequently requested a broader quality-per-dollar evaluation,
including Chinese providers, without using adapter maintenance as an exclusion criterion. The earlier claim that
no provider is cheaper than Haiku is withdrawn; compare actual tokenization, reasoning, length tiers and cache
charges on the same workload. A customer rollout would still need the corresponding consent and adapter. Anthropic's pricing
page confirms Sonnet 5.5 cache reads at $0.10/M (the rate card is right). Third-party benchmark sites put Sonnet ahead on
reasoning and nearly level on long-context reading, so Haiku's quality is measured on our tasks before it becomes the
default: the four `--eval` questions plus harder DPO questions with known answers (a misconception to correct, the
gradient's weighting, a result read from a plot, Theorem 1's condition) on Haiku medium and high, Sonnet as the
baseline and DeepSeek, graded side by side (under $1). Blocked on the staging Anthropic balance (still "credit balance
is too low" at 17:09 UTC).

### Finalist continuation (2026-10-16, ~23:15 UTC; default unchanged)

The three economical finalists now have 27 attempts each: Haiku medium and Gemini Flash medium return 27 written
answers, Luna high 24 (three requests end at an unavailable native-table image). Independent grading covers four
new questions; source checks preserve disagreements and identify smaller unsupported claims. No score averages
mix the old rubric with the new factual-error/required-omission/optional-background rubric. Calibration consists
of six agent-verified short cases per judge, not human expert validation. [Finalist results](../reviews/MODEL_COMPARISON_FINALISTS_20261016.md).

The earlier uncertain charges are reconciled; experiment total $9.6865303832, no outstanding holds, under the
$10 funded cap. More full-source grading cannot fit the remaining $0.3135. Higher-end Chinese comparisons,
repeated critical cases and deployed-adapter/figure-explainer validation remain open. Sonnet remains the default.
The observed table tool dead ends are retained for the later adapter/tool review, not silently retried or fixed
mid-experiment. OpenRouter research is still separate from the pending staging Anthropic figure-detail check.

### Matched model screening (2026-10-16, ~21:25 UTC; historical checkpoint)

The owner's funded OpenRouter comparison now has 12 matched questions across five papers and 13 usable settings,
with whole production paper-chat instructions and prepared images. Argon high graded all completed responses;
Sol high checked three questions for seven settings, and consequential claims were checked directly against the
paper and plots. [Measured results](../reviews/MODEL_COMPARISON_RESULTS_20261016.md) preserve the answers, grades,
costs and disagreements. Gemini Flash is the provisional next-validation lead, with Haiku and Luna still relevant
for further testing; maintenance effort is not an exclusion criterion. Haiku high's good average did not prevent
a real algebra error. DeepSeek/Qwen misread a plotted series, and MiMo made unsupported mathematical/resource
claims. No model is declared equivalent to Sonnet from this small sample, and Sonnet remains the default.

The long-paper price tier and native tokenization matter: Haiku medium's cold Apertus question cost $0.1869,
versus $0.0184 for DeepSeek/DeepInfra on that question. Haiku high's apparent $0.0465 total reused medium's cache;
with medium's cache conditions its estimated total is $0.2595, not a 37× saving over Sonnet. The whole experiment
reported $8.655776 plus $0.228190 unresolved holds. The 27-question finalist extension and actual deployed-adapter /
figure-explainer checks remain pending. OpenRouter evidence is not a successful staging Anthropic live check.

### Browser (2026-10-16, local fixtures; not deployed)

- **Table decoding** (`apps/web/src/lib/chat-profiles.ts`): `chat-profiles-v1` with or without the additions. `auto`
  profiles (any profile whose effort is `auto`), an `auto` effort label, `default_auto` (used only when it names an
  offered `auto` profile) and a `deepseek` model decode additively; a table without them decodes exactly as before.
  Stored choices (a chat's, the browser default, a saved question, the journal) keep a concrete effort, so older tabs
  read them unchanged; the request sends `effort: "auto"` (always, Sonnet · Standard included) where the table offers
  an `auto` profile for that model and length, else the stored effort as before (the standard profile still unsent).
  DeepSeek is listed only when the table lists it (and left out if the table ties it to a consent other than v4); the
  model's `provider` id is shown as Anthropic or DeepSeek, and its `detail` is the server's. Summaries are model ·
  length everywhere (menu, retry line, consent, the line under answers). Fixtures: the e2e fixture backend serves
  `apps/web/tests/fixtures/chat-profiles-v1.json` (staging's table) by default and, with `__chat-fixture
  {profiles:'v1'}`, `tests/fixtures/chat-profiles-v1-build57.json` (no additions).
- **Consent `cloud-ai-v4`** for every request (readers who accepted v3 are asked once more), worded as on the apps:
  the opening line naming Claude and DeepSeek, the v3 list plus the DeepSeek bullet, the closing paragraph.
- **Chat ⋯ menu** (`chat-menu`): Answer options… (with the summary) and Study mode / End study mode (`study-start`,
  `study-end-menu`). **Answer options** is a dialog: Model, Length, Use for new chats / "New chats start with these.",
  About AI chat options (opens the account menu's **AI chat options**: the same pickers for new chats, each model's
  detail and provider, the credit table from the `auto` estimates or else low effort's, the effort line, Visual
  answers).
- **Composer and empty chat**: the pill (field, then Send/Stop), placeholders as above; the draft status and balance
  stay as one fine line under it. Starters: `chooseStarters` with `starterPaper(index)` from the open paper's verified
  bundle (figures from figure captions, tables from any figure caption or block text starting "Table N", display
  equations, heading titles; an empty structure when the paper has no bundle on this device; `null` for general chat),
  seeded per new empty chat, hidden once the box holds anything but a starter; the glow is `--chat-glow` and is
  dropped under `prefers-contrast: more`, `prefers-reduced-transparency` and forced colors.
- **All chats**: search and ≡ (New general chat, Sort by, Columns — Paper, Messages, Started, kept in this browser —
  and Close; Esc closes the menu first, then the sheet), All first and chosen, Last read; a window under 600 px shows
  Conversation and Last read with the paper as the second line.
- Evidence: vitest; Playwright `chat-redesign`, `chat-controls`, `study` (desktop and phone) and the chat-adjacent
  journeys, against the local fixture backend only (no staging request from the browser yet).


## Broader model comparison — 2026-10-16 takeover, unpaid

The earlier under-$1 Haiku-only plan is superseded by the owner's OpenRouter evaluation authorization (up to $25,
including judges). [Protocol and verified readiness](../reviews/MODEL_COMPARISON_20261016.md): 27 questions on five
exact paper revisions; 13 settings across 11 models; the production prompt builder, actual browser figure
preparation, blind grading, durable spend reservations and provider-side key limit. At this checkpoint all 27
requests pass dry construction and all contestant routes pass catalogue checks, but **no paid answer or quality
ranking exists** because available credit is zero. Sonnet remains the default. Neither recent publication dates
nor first-party routing prove training-set exclusion or unquantized weights.

## Build-69 feedback implementation — 2026-10-18

Native and browser composers show the actual model beside the input, with answer options nearby. The successful
Draft saved label is removed; durable draft persistence is unchanged. New chat and its paper subtitle align left.
Native dictation uses an explicit microphone action and only `requiresOnDeviceRecognition`; unsupported languages
or denied permissions produce a visible explanation. It never records a file, uploads audio or sends the draft.
It stops on context/account changes, backgrounding, manual edits or the 55-second deadline. Simulator uses a
fixture for draft/permission-independent UI acceptance; real microphone and phone language availability are not
claimed. Speech and microphone usage descriptions are present in the signed application's Info.plist.

Equation and figure sheets now embed real encrypted conversations (see their architecture documents). A browser
nested-dialog regression revealed that React's close event bubbled from Answer options into its parent sheet;
the handler now acts only on its own dialog. Browser contextual composers cannot be evicted as empty main drafts,
and unloaded model tables do not pin a provisional Sonnet choice over the published Flash default.

The Mac target grants the sandbox microphone and hardened-runtime audio-input entitlements for explicit
dictation, and both generated Info.plist and `project.yml` carry the microphone/speech purpose strings. These
are checked in the signed archive; a deterministic microphone fixture does not verify actual speech recognition.
See [Apple’s Catalyst microphone requirements](https://developer.apple.com/forums/thread/825449).

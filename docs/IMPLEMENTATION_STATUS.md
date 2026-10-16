# Implementation status

Updated 2026-10-16 UTC (figure view server; Mac Close/New fixed, reader revision 16; browser build-59 parity and Listen on legacy items; server paper copies deleted). Earlier deployment checkpoints below are retained as history.

## Figure view, server — 2026-10-16, ~07:45 UTC (staging)

- Chat actions `figure` (a walkthrough: one checked `figure_walkthrough` call relayed as a `figure` event,
  `figure-walkthrough-v1`) and `figure_simpler` (one part again, streamed) on the chat's cached prefix
  ([FIGURE_VIEW.md](architecture/FIGURE_VIEW.md#server--as-built-phase-1-2026-10-16-staging), with the exact JSON).
  New capability `figure_view`: a build with the view sends it on every paper chat so its chats carry the tool; not a
  forced tool (Sonnet 5.5 refuses one). Migration **082** (after 081, ledger verified) lets settlement record the two
  actions; `chat` deployed (deploy suite 20/20).
- Live: DPO Figure 1, InfoVis Figures 4 and 13, InfoVis Table 1 (rendered as an image), Mistral 7B Figure 5: 2–5
  sections each, read from the images; 4–5 credits per walkthrough and 3–4 per "more simply" with the paper cached
  (a walkthrough after a chat question read the 49,199 cached tokens the question wrote); 9–12 s. $0.82 of provider
  spend in all.
- **Open:** the model gave no crop box in 8 walkthroughs, so box placement is unchecked live (phase 4); apps and
  browser not built (phases 2–3).

## Mac File menu fixed; reader revision 16 (an image arXiv doesn't serve never refuses) — 2026-10-16, ~07:45 UTC

- **TestFlight 61** (8b23301): iOS and Mac uploaded and VALID (00:14 / 00:20 PDT).
- **Mac ⌘N did nothing**: `CommandGroup(replacing: .newItem)` never reached the File menu (Add Paper…, New Chat were
  missing); now `after: .newItem`. **⌘W closed the tag sheet with a tag being typed**: the system's Close is swapped in
  place for the app's (`MacClose`), which asks the frontmost sheet's guard, dismisses an unguarded sheet, waits for an
  alert, and closes the window only when nothing is presented (MAC_APP.md "Known issues"). Evidence: MacKeyboardTests
  4/4 on this Mac (previously 2 pass, ⌘N and the dirty-tag step failing).
- **Revision 16**: one image arXiv doesn't serve (404/4xx, redirect, wrong type, empty, over the per-image limit) is
  that figure's note and the paper opens, on the apps and in the browser (HTML_FIRST_READER.md, after "One figure the
  device can't prepare"). arXiv busy/refusing, 5xx, a lost connection and the paper's byte budget still stop the
  preparation. Devices re-prepare papers compiled by revision 15 when opened. Evidence: `npm test`; native
  ArxivHTMLReaderTests + ArxivCompilerIdentityTests on Mac Catalyst (5/5); `reader-device-compile.mjs` on 2610.19820,
  2610.16784, 2610.20570 ok (3/3, 13/13, 1/1 images). Not yet in a build or deployed.

## Browser: build 59 parity, early endings, Listen on legacy arXiv items — 2026-10-16 (built; not deployed)

The browser now matches the apps' build-59 changes (native commits `9903f50`, `5e4c1d2`, `f99a86d`, `e9b2a1b`):

- **Equation view** ([EQUATION_VIEW](architecture/EQUATION_VIEW.md)): opens with the equation and, side by side,
  **Explain** and **Ask in chat**; nothing is requested on opening (Explain asks the chat's consent first), More
  background only after the explanation, no credit counts.
- **Contents** in the reader's side panel: Contents · Figures · Tables · Equations (Contents first, quiet segmented
  tabs). Figures/Tables rows "Figure 1 — caption" (two lines) open the figure viewer with the whole caption and Show in
  paper; Figures starts with View as tiles (the gallery); Equations rows "Equation (n)" with the LaTeX as text go to the
  equation with Back (`showEquation` in the frame shim calls the bridge's `__scienceReaderShowEquation`). As in the
  apps, only figures and tables with images are listed (an HTML table is not in the bundle's figure index).
- **AI chat options**: "Default options for new chats" (Model, Length, Visual answers); its ⓘ opens About AI chat
  options (models, who processes them, credits per question); Answer options' link opens About directly. Every ⓘ
  bubble darkens the rest of the page (black at 40 %) and flips above its ⓘ when it would run off its dialog.
- **Early endings** ([CHAT](architecture/CHAT.md#when-an-answer-stops-early--2026-10-16)): `stop_signal` on every
  request; Stop records `v1_chat_stop` (at most 3 s) before cancelling; "Interrupted · not charged", "Stopped · charged
  for the part written", "Stopped · not charged" under a kept answer.
- **Listen on a legacy arXiv item**: the text prepared in the tab goes as a device source named by the library item
  (migration 081, applied to staging); nothing is sent when the paper can't be prepared, and Listen says to open it.
- **Wording**: Privacy & data says the servers keep no copies of papers; account deletion, Add by link, import
  failures and a PDF-only legacy row no longer speak of papers converted on the server.
- **Tests**: `npm test` passes (browser units with new `paper-contents`, chat early-ending and shim tests). Journeys,
  desktop and phone: equation-view (with the new Contents journeys), chat, chat-controls, chat-redesign, owner-58,
  server-copies-retired (with Listen on a legacy item), podcast-workspace, reader, layout, arxiv-html: all pass
  (skips by their own conditions). The compiler-freshness failure in `.claude/worktrees` checkouts noted below is a
  missing `supabase/functions/node_modules` (Deno's vendored packages, which esbuild resolves first in the main
  checkout); with it present the check passes.
## Server paper copies deleted on staging — 2026-10-16, 06:36 UTC

Owner: "Yes, we can even delete them now, so it's obvious we have zero on our system" (design, inventory and client
behaviour: DATA_HANDLING_AND_COSTS.md "Server paper copies: retired").

- **Deleted:** 1,631 objects, 649,268,455 bytes (619.2 MiB), all of `paper-assets`: originals 28 (209.1 MB), private
  47 (170.7 MB), raw 300 (163.5 MB), reader 1,256 (106.0 MB), from 86 documents (75 still had files). `paper-uploads`
  was already empty. Storage's listing and `storage.objects` now show 0 paper objects; 0 tracked live. Controls
  unchanged: `podcast-assets` 18 objects / 12,308,378 bytes before and after; `private-content` and `support` 0.
- **Migration 080** applied after 079 (ledger verified): retirement RPCs, a fence refusing new paper-copy rows,
  `document_unavailable` for chat on a deleted text, local-context chat for legacy arXiv items. Rows kept; 1,749
  `paper-assets` rows are `deleted`; 172 availability rows and all 96 library rows (23 accounts) say unavailable at a
  newer revision, ids kept.
- **Probed on real rows (rolled back):** a legacy arXiv item answers `reader_unavailable`, `document_unavailable`, no
  podcast pin, and accepts device-text chat; a web item answers the same and refuses device text.
- **Browser** deployed from this branch before the deletion (Pages `768a86a0` then `afa4262f`), and again with How
  Gradstep works saying the earlier copies were deleted (`efa73b53` then `e855f3c6`): legacy arXiv items open from
  arXiv and ask with the tab's text; no-HTML revisions offer the PDF; papers from other sites say "No reading copy".
  The apps' How Gradstep works sentence changes with their next build.
  **Native 57–60 unchanged:** they stop asking `reader-artifact` (the row is unavailable), open arXiv items from arXiv,
  keep installed copies, say "no reading copy on the server" for web papers; chat on a legacy item says "isn't ready
  for questions yet" until a native build sends device text (server ready).
- **Guard:** `storage.no-papers` (all suites) passed recorded, locally (run `ff75035f`) and on the hosted job (image
  `e1139ca-1792132666`, run `963fdb5a`); schedules unchanged.
- **Tests:** database suite (full, plus 079+080 together); backend 597 pass, 1 skip; operations 16; egress scan; browser
  units 434; browser journeys reader, chat, parity, arxiv-html, podcast-workspace, resilience, layout and the new
  server-copies-retired on desktop and phone: 81 passed, 15 skipped by their own conditions; Swift Core LibraryReconciler
  and OfflineCache, 54; app LegacyArxivReaderTests and OfflineModelTests on the iPhone 17 Pro Max Simulator, 19. The
  compiler-freshness gate fails only when built from a `.claude/worktrees` path (identical 58 inputs; built from the
  main checkout it equals the committed bundle).
- **Not covered:** 7-day database backups still name the deleted files (no bytes); encrypted manual checkpoints on the
  developer's Mac (`.artifacts/backups/`, Oct 3–9) include them; Mathpix's own retention.

## Releases — 2026-10-16

- **TestFlight 58** (iOS 19:57, Mac ~20:00 PDT Oct 15, VALID): papers without arXiv HTML open their PDF; ML paper search
  rename; simpler podcasts.
- **TestFlight 59** (`b5f5029`; iOS 21:36, Mac 21:41 PDT, VALID) and **60** (`0fda2ae`, the expanded-title fix; iOS
  22:18, Mac 22:23 PDT, VALID): the chat redesign, Settings, Feed and Library changes below, consent v4, reader
  revision 15. Built from clean checkouts.
- **Browser**: app.gradstep.ai deployed from main twice (two phases verified; live bundle carries the redesign, consent
  v4 and the revision-15 compiler). **Landing preview** republished (noindex) with DeepSeek named for chat.
- iPhone UI regression (10 suites): 74 passed; 2 failures then fixed (expanded Feed titles capped at two lines) or
  passing on rerun (broken-diagram journey). iPad: ChatControls, ChatHistoryTable, Settings pass after the empty-chat
  hit-testing fix.

## Contained overruns; answers that stop early cost the reader nothing (server) — 2026-10-16, ~06:35 UTC

- Owner decisions 2026-10-16 (RESILIENCE fix 1; failed answers), server half, on **staging**: migration 079 applied and
  verified (no settlement path clears `work_enabled` any more; only the tripwire can); `chat` deployed, deploy suite 19/19
  with the chat smoke recording the first `completed` ending. Clients still to ship (send `stop_signal`, call
  `v1_chat_stop` on Stop, read `charged`/`reason`, "Interrupted · not charged"); admin Health Attention built, not
  deployed to admin.gradstep.ai.
- **Overruns**: a `budget_anomaly` row and an Attention line, never a pause by itself; the month pauses on the hard
  limit, more than 5 overrunning operations in an hour (counted afresh after a pause), or the operator.
- **Early endings** ([CHAT](architecture/CHAT.md#when-an-answer-stops-early--2026-10-16)): provider failure or overload,
  our server, our 130 s or `max_tokens` limit, a dropped connection (with `stop_signal`) and refusals charge 0, cost
  recorded as absorbed (`chat_endings`); Stop (recorded) and older builds' closed streams pay what was used; undelivered
  titles, suggestions and map updates are absorbed; more than 20 unpaid endings per account per day → Attention.
- **Live drills** (each 100 %): throttle 9/9 (`cb605a6a…`, 0 credits), midstream 8/8 (`6d02ef34…`, 0 credits, 63
  characters kept), stop 6/6 (`8da20b6a…` stopped 1 credit, `9a873b71…` connection 0, `9e42aa9e…` left 1), overrun 5/5
  (`89bc1980…`, two test-account anomaly rows, `work_enabled` true, then a 1-credit answer). About $0.006 of provider
  spend including the deploy smoke; staging left with $0 reserved and no unresolved attempts
  ([RESILIENCE](architecture/RESILIENCE.md#fix-1-and-early-endings-as-built--2026-10-16)).
- Local: `npm test`, `deno check` of the chat entry point, the database final and search-switch phases with
  `contained_overruns.sql`, `npm run build:admin`.

## Native chat redesign, Settings, Feed and Library from builds 57–58 — 2026-10-16, ~05:00 UTC

- **iPhone, iPad, Mac** (CHAT.md "Chat redesign from build 57 feedback"): starters above one pill message box (the
  browser's pool and seeded selection; parity-tested on tests/fixtures/chat-starters-cases.json) with a soft glow;
  "Ask anything about the paper"; keyboard dismiss inside the pill on iPhone only; ⋯ › Answer options… (model and
  length; DeepSeek as the server lists it; Use for new chats; About AI chat options) and Study mode; requests send
  `effort: auto` and consent `cloud-ai-v4`; Settings › AI chat options with per-model credit tables.
- **All chats**: search and ≡ (Sort, Columns, Close) on top; All first and default (a paper's own "Chats about this
  paper" still opens on it); Last read; the paper only in its column.
- **Settings**: account row without sign-in methods; AI credits; Subscription plan; ⓘ explanations; no text-size
  sliders; Your assets (Chats, Diagrams); Report a problem and My reports by About; a grey Admin section (operators,
  internal builds); Privacy & data with "Papers and arXiv" (device-only, pacing, ToU link, acknowledgement) and the
  outdated server-fetch line removed.
- **Feed / ML paper search Add**: the Library's spinner (percent while preparing) until ready; a tap shows the Library.
  **Library**: a row being added keeps its final height.
- iPad regression found and fixed before shipping: an empty chat's message box took no taps without its band (b5f5029).
- Evidence: Core 323 tests; ChatStarters/ChatHistory/ChatVisual unit tests; UI ChatControls, ChatHistoryTable,
  Settings, LibraryWrites on iPhone 17 Pro and iPad Pro 13 (screens reviewed); `npm test` on merged main.

## Reader revision 15: one figure never refuses a paper; flat wide tables — 2026-10-16, ~03:50 UTC

- Builds 57–58 reports: ActionOPD (2610.19820v1) refused `svg_id`, InfoVis (2610.16784v1) refused `image_dimensions`
  ("exceeds the device reader's preparation limits"). An image the device can't prepare now becomes a note in its
  figure ("This figure couldn’t be shown here; the PDF has it.") and the paper opens; only the paper's totals,
  structure and host inputs refuse (HTML_FIRST_READER.md, after "Images on the device"). Both papers now open with
  every figure: an SVG id given twice that nothing refers to is dropped, an over-large SVG is drawn smaller.
- "I really dislike this gradient": the reader bridge's scroll shadows on wide tables and equations are gone on every
  surface (iPhone, iPad, Mac and the browser share `reader-bridge.js`); the boxes are flat and still scroll sideways,
  with a 1 px hairline on an edge that has more beyond it, light and dark.
- Evidence (not yet in a build or deployed): `reader-device-compile.mjs` on both papers ok (3/3 and 13/13 images), on
  the 22 papers with cached assets 22 ok (rev 14: 20; 2312.14235's 25 large PNGs close the harness's headless page on
  rev 14 and 15 alike); sweep replay of the union of the 110 recorded reports (117 cached papers) 0 fail / 8 warn;
  equivalence against `432c023` with `--ignore-ids`: 150 sources, 287 runs identical; `npm test`; browser
  `arxiv-compiler.spec.ts` on Chromium, WebKit and Firefox, and the reader, layout and HTML-paper journeys (desktop);
  iPad Simulator: the native tier (ArxivHTMLReaderTests, PDFUploadTests) and PaperWebViewTests 28 (one rerun after
  the Simulator killed its runner).

## Browser: chat redesign and builds 57–58 reports — 2026-10-16 (deployed to app.gradstep.ai ~04:55 UTC, two phases verified)

- **Chat** ([CHAT](architecture/CHAT.md#browser-2026-10-16-local-fixtures-not-deployed)): ⋯ menu with Answer options
  (Model incl. DeepSeek when listed, Length, Use for new chats, About AI chat options) and Study mode; `effort: "auto"`
  where the table offers it, the stored effort otherwise; consent `cloud-ai-v4` worded as on the apps; Settings-style
  **AI chat options** (per-model detail and provider, credit table, ⓘ explanations); one-pill composer and the new
  placeholders; three seeded starters with icons above it and an accent glow; All chats with search and ≡, All first,
  Last read, the paper only in its column.
- **Account menu**: who and sync state; About with Privacy &amp; data, Report this screen and My reports for everyone;
  operator tools in a grey Admin group. **Privacy &amp; data** (new): notes, AI answers (Anthropic or DeepSeek), Papers
  and arXiv (device-only, pacing, terms link, acknowledgement; a PDF opens from arXiv in a new tab), Reports.
- **Feed / ML search Add**: the Library's spinner from Add until the paper is prepared here (percent under it once
  known; a click shows the Library), then ✓ In library. **Library**: a paper being added reserves two title lines (and
  the authors line when shown under the title), so the row never grows when its details arrive.
- Not in the browser: Your assets › Diagrams (there is no diagrams list here), AI credits / Subscription plan groups
  and text-size settings (the browser has no settings page with them).
- Evidence: vitest 433/433; Playwright desktop and phone for the changed journeys (chat-redesign, chat-controls,
  study, owner-58, support-reports, parity, paper-search, layout, library*, chat, podcast-workspace and others).

## Automatic effort and DeepSeek in chat (server) — 2026-10-16, ~03:30 UTC

- Build 57 feedback ("the effort level should be chosen intelligently"; "deep seek should be an option. We need one
  that supports images"), server half, on **staging**: migration 078 applied and verified; `chat` deployed with
  `CHAT_DEEPSEEK=hidden`, checked, then `on`; deploy suite 19/19 both times. Clients still to ship (answer options,
  consent v4, settings).
- **Automatic effort**: `effort: "auto"` resolves before the hold (Brief low; Standard medium for reasoning, an equation
  or a figure; Detailed high for reasoning); quote, request, `done.profile`/`done.effort` carry the pick. Live: four
  Sonnet `auto` answers picked medium/medium/low/medium and settled (57 credits, $0.273).
- **DeepSeek** (`deepseek-flash` via DeepSeek's Anthropic-compatible API): consent `cloud-ai-v4` only
  (`consent_required` otherwise), peak list prices, own admission, usage rows and breaker; Tavily is its only search.
  Recorded check on DPO before publishing: equations 104/104 typeset, 93/93 citations resolvable, figure read from the
  image with 4 parts, visual and Mermaid tools parsed, streaming; $0.038 for four answers, each attempt's cost equal to
  its tokens at peak rates ([CHAT](architecture/CHAT.md#recorded-check-of-deepseek--2026-10-16-staging-before-it-was-published)).
- **Published table** stays `chat-profiles-v1`, default `sonnet-low-standard`; 27 Claude profiles first and unchanged,
  then 9 DeepSeek and 12 `auto` profiles, `default_auto`, `provider` per model. Live GET verified: equal to the checked-in
  fixture, and the build 57/58 decoders' view unchanged.
- Local: `npm test`, the database final phase with `chat_deepseek.sql`, `deno check` of chat and podcast entry points.

## Papers without arXiv HTML open their PDF — 2026-10-16, ~02:55 UTC

- Build 57 report (Cortex, 2610.20399v1): arXiv has no HTML for it ("No HTML for '2610.20399v1'… conversion failure").
  The screen said "you can still open … its PDF" and offered only Try again. Now iPhone/iPad/Mac say **No web version
  of this paper** with **Open PDF**, which downloads that exact revision's PDF from arXiv on the device (encrypted local
  store, Gradstep User-Agent, honours a recorded arXiv refusal) and opens it; a compiler refusal offers Open PDF beside
  Try again; arXiv busy/refused/unreachable offers neither. The browser shows the same screen; Open PDF opens
  arxiv.org/pdf/<id>v<n> in a new tab from the browser.
- Evidence: live iPhone Simulator journey against staging (`node scripts/live-journey.mjs --pdf-only
  --arxiv=2610.20399 --title=Cortex`, passed: screen, then the PDF); browser journey `arxiv-html.spec.ts` (desktop,
  phone); unit tests on both. The live journeys' row selector now matches the phone's Library table.

## Reader revisions 13 and 14 — 2026-10-16, ~00:40 UTC

- **TestFlight 56** (rev 13; iOS 17:18, Mac 17:23 PDT) and **57** (rev 14 + rotated device-PDF pages; iOS 17:32,
  Mac 17:37 PDT) all VALID; browser on rev 14 through the two-phase publish (both phases verified live).
- **Revision 13**: unknown math styling/attributes are left out, not refused (YouZhi 2606.05868 from build 55;
  2312.14235); a picture title takes the catalog's name as text (VideoJev); wordless headings no longer break Contents
  (2207.00729). The reader sweep now runs the app's validator (it had reported VideoJev fixed while devices refused it).
- **Revision 14**: figures arXiv's HTML lost say so and point to the PDF (CyberArena 2610.19005, 2610.20570);
  placeholder template authors give way to the catalog's names; a formula footnote mark reads as a mark.
- Equivalence against the last shipped revision changed only the intended papers each time; 40 sweep reports
  replay with 0 failures.

## Resilience, journey triage, device-only groundwork — 2026-10-15, ~20:45 UTC

- **TestFlight 55** iOS (13:37 PDT) and Mac (13:42 PDT) both VALID, built from a clean checkout of `a8ad34a`.
- **Resilience** (RESILIENCE.md): server side on staging (provider-health telemetry and Health chart, breakers, one
  chat retry before the first token, podcast requeue on 429, retry_after, fault injection for test accounts); the
  first drill (Anthropic throttled on chat) passed 8/8. Client side in browser and apps (per-region error boundaries,
  launch auto-retry, throttled errors with the server's wait, polls with back-off and jitter, bounded native request
  times, last-good feed/episodes/credits). Overspend containment and three charging/fallback questions await the owner.
- **Journey triage**: all 30 iPad failures pass or skip with a reason; full iPad and iPhone suites clean; three product
  fixes. Browser: 263 journeys on desktop, phone and both tablets; native 457 unit tests.
- **arXiv device-only** (ARXIV_DEVICE_ONLY.md): egress guard live in report mode; device metadata, DataCite client and
  device search without OpenAlex merged and deployed, all switched off; search evaluation favours the new path.
- **Web deploys** publish in two phases (the browser was briefly blank after a deploy; the cause is fixed and proven).

## Equation view, parity, reading mode, arXiv step 0 — 2026-10-15, ~17:10 UTC

- **TestFlight 54** iOS (09:59 PDT) and Mac (10:05 PDT) both VALID, built from a clean checkout of `1938621`; browser
  Pages **`4d66d4f3`** (live asset check passed).
- **Equation view** on all surfaces (EQUATION_VIEW.md): the equation large (100–400 %, scroll sideways), each symbol
  from the paper with its ¶ or as general meaning, More background, Ask in chat; chat actions on the chat's cache.
- **Parity audit** (owner: "make sure all changes I've been testing on the iPhone app are properly updated on Mac,
  iPad and web"): native and browser gaps fixed (see the two "Parity audit" commits); iPad full run 113 journeys,
  re-run with layout-aware navigation; Mac Catalyst unit suite 407 run; triage of the remaining iPad journeys in progress.
  Mac UI journeys cannot start here without macOS automation permission (an owner setting).
- **Line width and reading mode** (READING_MODE.md): Comfortable / Wide / Full width on Mac, iPad and the browser;
  a full-screen reading mode (⇧⌘R on the Mac, F in the browser).
- **arXiv** (ARXIV_DEVICE_ONLY.md, proposal): the required acknowledgement and disclaimer on every product surface,
  Gradstep User-Agents with a reachable contact on every server (functions and the Cloud Run worker redeployed),
  stale copy corrected. Steps 1–3 (guardrails in report mode, additive device-metadata support, DataCite client,
  all switched off) in progress; owner decisions open (DataCite for shared data, legacy server copies, episode source
  retention).
- **Account deletion** sweeps private episode folders (migration 070, on staging).

## Monitoring for 100 → 1,000 people, and figure parts inline — 2026-10-15, ~14:40 UTC

Owner: "the crops should be inline, right as the chat discusses each one" and "Imagine the graphs I need to monitor,
what are they, how do I access them, does it feel seamless? Please build".
- **Health tab** (docs/architecture/ADMIN_HEALTH.md), first for the owner at `https://admin.gradstep.ai/#health/30`:
  an Attention list, then people (accounts, active this week / 30 days, came back, sign-ups; active accounts per day
  with a 7-day line), use (papers, chat answers, podcasts per day), reliability (failed paper adds and podcasts with
  their reasons, unsettled chat answers, open reports) and cost (month to date, forecast against the budget, per active
  account, projections at 100 and 1,000 accounts, spend per day by provider, credits, prompt-cache share). 7/30/90 days,
  refreshed every minute while open. Migration 069 (`account_activity_days` rollup, `v1_admin_health`, owner + MFA):
  338 database tests pass; applied and verified on staging. Admin Pages `b71d1f6a`, Home Screen manifest and icons.
- **Access**: "Operations dashboard" in Settings (apps) and the account menu (browser) for owner/support accounts.
- **Deploy hazard fixed**: a new admin script cached as HTML during propagation blanked the admin; the admin now has a
  real 404 and `deploy-web.mjs` verifies every script and stylesheet live (ADMIN_HOSTING.md).
- **Figure parts inline** (CHAT.md): crops at `[[part N]]` markers, the outlined whole figure below; chat function on
  staging, live proof on DPO.
- **Shipped**: TestFlight **53** iOS (07:34 PDT) and Mac (07:39 PDT) both VALID, from `80d0dfd`; browser Pages
  **`7aab13f3`** (live asset check passed); admin Pages **`b71d1f6a`**.
- **Equation view** (EQUATION_VIEW.md): server actions `equation` / `equation_background` deployed to staging and proven
  live on DPO's loss (11 symbols, 10 from the paper; background read the cached paper, 5 credits). Apps and browser
  in progress.

## Figures in chat when you don't name one, and figures with panels — 2026-10-15, ~11:45 UTC

Owner, on CaLIF (2610.19525): "Not able to do this", then "Even when I referenced a figure it still didn't work".
- **The model asks for the figure** (`look_at_figure`, `figure_request`, the `figure_requests` capability): the
  device asks again once with that figure; the first answer is not kept. Server, both apps and the browser.
- **Panels are one figure** (`ARXIV_RENDERER_REVISION` 12): picture panels under one caption; six cached papers change,
  all with panels; both sweep corpora replay with 0 failures. Chat sends the panels stacked as one image and stores
  every panel's path so the parts crop the same image anywhere.
- **Visible attachment**: "Looking at Figure N…" while a figure goes with a question.
- Named figures already worked from build 47: the app's finder on this paper's real bundle prepares Figures 2, 3 and 4
  (`ChatFigureTests` with `TEST_RUNNER_FIGURE_BUNDLE`, the bundle from `reader-device-compile.mjs --out`).

Evidence: backend chat tests 99 (with the figure request), converter tests 44, `npm test`; browser units 381 and the
HTML-paper journey (an unnamed figure question makes a second request with Figure 1 and shows its parts); Simulator: 63
unit tests and the figure tests on CaLIF; live on staging, `chat-live-smoke.mjs --look`: Figure 2 requested, then
four parts.

Deployment (commit `12b55ee`): chat Edge function on staging; browser Pages **`af0cbb1b`**; TestFlight **build 52** iOS and
Mac VALID (04:41 and 04:46 PDT).

## The arXiv converter in components; Library tag chips and remembered filters; stale journeys repaired — 2026-10-15, ~09:30 UTC

- **Converter split** (READER_ARCHITECTURE_RETHINK.md step 2): `arxiv-html.ts` keeps the API and the order of the
  passes; the components live in `reader/arxiv/`. `scripts/arxiv-converter-equivalence.mjs` proves a restructuring
  changes nothing (113 cached sources, 210 runs, all identical). `ARXIV_RENDERER_REVISION` 11.
- **Library** (owner-approved follow-ups of 2026-10-07): a tag chip in a row filters the Library by its tag (again:
  all papers); the filter and the tag are remembered between launches (native and browser). Dates in the table are
  the day with the time under it at the old width: build 46's one-line form no longer fit a phone in portrait.
- **On-device model**: two crops recognised at once (two thirds of the time); the screen stays on during a reading and
  iPhone and iPad say to keep the app open.
- **Journeys repaired**: the browser's reader, layout and UX-review journeys reached the real arXiv since the
  HTML-first change (legacy fixture papers try their official HTML first) and read its HTML instead of the fixture;
  they block arXiv now, as the chat journeys do. Two journeys expected progress wording from before "Preparing…", one
  the suggested questions without their toggle; the native reference and landscape table journeys were updated for
  the edit menu and a Simulator frame quirk.

Evidence: `npm test`; the equivalence script; browser suite on desktop 100 % (layout, reader, UX review, Library,
chat, HTML paper, compiler); Simulator: 63 unit tests, `LibraryLayoutTests` (5 journeys including the tag chip),
`ReaderNavigationTests` (two), `DeviceModelJourneyTests`.

Deployment (commits `32f23a5`, `c559093`): browser Pages **`33f2a79a`**; TestFlight **build 51** iOS and Mac VALID (02:07 and 02:13 PDT).

## The on-device PDF model in the app (experimental); figures in browser chat — 2026-10-15, ~08:00 UTC

Owner: "create a version of the on device model into the app knowing it won't always work… prepare a message for the
other model building agent." Design and status: [DEVICE_PDF_ROUTE.md](architecture/DEVICE_PDF_ROUTE.md); the message:
[DEVICE_MODEL_FEEDBACK.md](proposals/DEVICE_MODEL_FEEDBACK.md).
- **The route**: the desktop's frozen port kit (converter 0.1.0, layout-fcos-v5, texteller-ft-v4 int8, inline-tagger-v4)
  as a Swift text layer equal to pdfplumber, the three Core ML models from Swift (equal to PyTorch on their samples),
  and the converter rules in TypeScript (equal to the Python route given the same inputs) running in JavaScriptCore.
  Output is this app's reader vocabulary (unsure formulas as page images, `reader-math-image`), verified by the same
  Swift verifier as every bundle (`ReaderProfile.devicePDF`).
- **Fixtures, end to end on this Mac**: 8/8 convert and verify; 3 pass every gate of the desktop's
  `bundle_conformance.py`; 13 to 150 s a paper, the recogniser about 0.17 s a formula. Font smoothing off in page
  renders was the largest single fix.
- **App**: Settings › Experimental; "Read with the on-device model" in a paper's options (and an added PDF's view);
  progress with Stop; the reading under its banner with Report and "Show the HTML reading"; readings kept per account
  in `device-model-readers`. The models (365 MB, `scripts/device-models.mjs`, digests in `device-models.lock.json`) are
  compiled into the app by both TestFlight scripts.
- **Simulator**: the stateful recogniser does not load there; the route degrades to formulas as images and says so.
- **Browser figures in chat**: consent v3, named figures sent from the open paper, the parts cropped under the answer
  and outlined in the whole figure, stored as the apps' `figure-parts-v1`. Report screenshots in the browser now show
  (the page's image policy blocked their `blob:` URLs; both use `data:` URLs).
- **Converter**: `ARXIV_RENDERER_REVISION` 10 (the validator's device-PDF vocabulary is in the shared compiler).

Evidence: `npm test` (with the device-PDF compiler freshness step and 15 converter tests); `swift test` in
ScienceReaderCore (300 tests, including the text layer and host tests); browser journeys 24/24 (HTML paper with a
figure question, compiler, chat, chat controls, study, support reports, device PDF, library); iPhone Simulator: 63
unit tests including `DeviceModelRouteTests` (a generated paper to a verified, stored bundle; a fixture paper's first
three pages in 12 s) and the journeys `DeviceModelJourneyTests` and `testHTMLPaperInPageLinksOfferBack`.

Deployment (commit `ff555dd`, then `79bbbae`/`82794ce`): browser Pages **`d284d86f`**; TestFlight **build 49** iOS and
Mac VALID (01:02 and 01:07 PDT) with the models (348 MB in the app); **build 50** (two crops at once, screen kept on)
iOS and Mac VALID (01:14, 01:20 PDT). Not yet tried on an iPhone: TestFlight is the owner's test.

## Build 46 feedback: headers, diagrams in the answer, suggested questions on request, exact times, oversized images — 2026-10-15, ~07:30 UTC

Six TestFlight items on build 46 (`docs/OWNER_FEEDBACK.md` "TestFlight, 2026-10-15 05:50–06:07 UTC").
- **Converter, `ARXIV_RENDERER_REVISION` 9.** The title-page fold (logo figures, author tables, notes split at their
  marks, project-page lines), an author table after the abstract, line breaks in headings, a name run into the
  affiliations split at the catalog's name, corresponding-author lines as notes. An image past the device's bounds
  (16,384 px a side, 80 MP; `inspectImage(bytes, bounds)`) is left out of its figure and counted instead of refusing
  the paper; `image_dimensions_exceeded` and `invalid_image` are in both apps' failure tables, and the category test
  reads the image codes too.
- **Chat.** Native: a Mermaid diagram is drawn in the answer from an offscreen render (`DiagramPreview`), an HTML
  visual inline; a tap opens the full view. The suggested questions fold behind "Suggested questions (N)". Browser:
  the diagram draws inline without zoom tools and "Full size" opens the dialog; the questions fold the same way.
- **Library.** Added and Opened say the time (`LibraryFormat.tableDate`; the browser's `formatDateTime`).

Evidence: fragment tests 42/42; device compile of 1904.01201v2 (3.5 MiB), 2610.18072v1, 2610.10478v1, 1707.03017v5;
sweep replays 58 + 22 papers, 0 refusals; `npm test` passes; browser journeys 18/18 (chat, HTML paper, chat controls,
study); iPhone Simulator: 72 unit tests (LibraryMetadata with the new date test, ChatVisual, ChatFigure,
FigurePartsRendering, PaperWebView, PaperPassage, ImportProgress, ArxivHTMLReader) and the journeys for diagrams (now
asserting the drawing in the answer and the folded questions), a broken diagram, chat controls and all seven reader
navigation journeys. The reference journey still expected the build-43 dialog; it uses the edit menu now.

Deployment (commit `8c4767b`): browser Pages **`91d5ffac`**; TestFlight **build 48** iOS and Mac both VALID (23:45 PDT).

## Visual answers in chat; the fresh-paper sweep's next refusals — 2026-10-15, ~06:00 UTC

- **Visual answers** (owner: "The chat needs a html tool… mermaid diagrams… an option for the users to disable";
  CHAT.md "Visual answers"): `create_visual` beside `create_diagram`; the server sanitizes the HTML fragment
  (`chat-visual.ts`) and relays it as the `visual` event; the apps keep it as a `diagram` event of format `html-v1`
  and show it in a scriptless WKWebView ("View visual"), the browser inline in a sandboxed frame; the "Visual
  answers" setting (Settings › Chat; Chat defaults in the browser) sends the `visual_answers` capability or an empty
  list, and off, the model answers in prose with neither tool. Proof on staging: a pipeline question answered with a
  2.3 KB visual, a flow question with a Mermaid diagram (`scripts/chat-live-smoke.mjs --question=…`). Tests: backend
  95, native ChatVisualTests, browser chat tests. Figure crops stay proposed.
- **Sweep.** The 25 newest cs.LG/cs.CL/cs.CV/cs.AI papers (22 with HTML) refused three; all three degrade now: a
  graphic that is not one of the paper's assets (page chrome, an empty `src`) is left out and counted; several
  captions in one figure read as its caption and paragraphs; images past the figure's limit are left out and counted;
  pictures without an id are named; stray HTML inside a picture is dropped; a dropped block's equations leave the
  index; math in the date line is accounted for. `ARXIV_RENDERER_REVISION` **8**. The sweep carries a silent-loss
  ledger (`--ledger`: source figures, tables, algorithms, tabulars and listings against the reader's) with `losses`
  warnings, and names the ancestors of math a coverage refusal could not place. Both corpora replay with 0 refusals.

Evidence (commit `3044a07`): backend 95 (chat) and 41 (compiler fragments) tests; native ChatVisualTests, ChatTitleTests,
ArxivHTMLReaderTests 12/12; browser chat tests 16; live smokes on staging (visual 2.3 KB; diagram). Deployment: chat
Edge function deployed; browser Pages **`5dd5f179`**; TestFlight **build 45** iOS and Mac both VALID (22:04 PDT).

## Figures in chat: the figure a question names is sent; its parts are cropped under the answer — 2026-10-15, ~07:00 UTC

Owner: "Sending figures to model should be ok?" Yes, under consent v3, which names figures (CHAT.md "Figures in
chat"). Server: `chat-figures.ts` (validation, image blocks before the question, `show_figure_parts` and its checks,
the hold counting an image as 1,600 tokens), consent v3 accepted with v1/v2 (v2 and v3 name Tavily), the digest
covering images, the `figure_parts` relay with the notes as the answer when the model writes none. Apps:
`ChatFigureFinder` (captions, 1,568 px JPEG on white), consent v3 copy, `figure-parts-v1` storage, crops under the
answer and a full view with numbered outlines. Proof on staging with DPO's Figure 1 (five parts, correct crops).
Tests: backend chat 98; native ChatFigureTests, FigurePartsRenderingTests and the suites around them. The browser
keeps v2 and shows the text only, for now.

Deployment (commit `191bfdf`): chat Edge function deployed; TestFlight **build 47** iOS and Mac both VALID (23:06 PDT).

## Build 44 feedback: Back says where, no Back from the top, the store conflict behind failed re-preparations, Adding…, auto-download setting, reference edit menu — 2026-10-15, ~06:30 UTC

Six TestFlight items on build 44 (`docs/OWNER_FEEDBACK.md` "TestFlight, 2026-10-15 04:32–04:40 UTC"). The one real
bug: `DeviceReaderStore.install` refuses a second copy of the same paper revision (`revisionConflict`), and the
re-preparation installed before removing the old copy, so every re-preparation of a stored paper failed; the old copy
leaves first now and the notice names the store's reason. Back names the section it returns to and has an X; a chat
jump into an unread paper offers no Back; the web content process dying reloads the page once; the server's import
stage says "Adding…"; a paper already in the library when its import row goes is downloaded too; Settings › Library
"Download new papers automatically"; a tapped reference opens the native edit menu.

Tests: the reader web view and passage suites ran in full for the first time since the Back hardening of `beba14c`,
whose tests still scrolled by script without the reader input that now ends Back; they dispatch a wheel event first,
wait for an in-page link's animated jump, and expect no Back from a chat jump at the top. The passage highlight keeps
the found range registered (paintless) so Go to passage stays checkable. iPhone Simulator: 60 unit tests (ImportProgress,
LibraryMetadata, ArxivHTMLReader, ChatVisual, PaperWebView, PaperPassage) and the journeys
`testHTMLPaperInPageLinksOfferBack` and `testCitationGoesToItsReferenceAndBackReturnsToTheSamePlace` pass; the journey's
screenshots show "Back to 1 Introduction" with its X and the reference's edit menu (Copy · Open on arXiv · …).

Deployment (commit `5ace580`): TestFlight **build 46** iOS and Mac both VALID (22:35 PDT). These are app-only changes;
the browser and the server are unchanged since build 45.

## Build 43 feedback: unresolved citations, math colours, table pictures, the passage highlight, stored copies open at once — 2026-10-15, ~05:00 UTC

Nine TestFlight items on build 43 (`docs/OWNER_FEEDBACK.md` "TestFlight, 2026-10-15 04:04–04:11 UTC"), all on one
paper (ProAS, 2610.18683) and two reopened papers. Converter (`ARXIV_RENDERER_REVISION` **7**): a macro definition
left as a paragraph goes; citations LaTeXML printed as a bold "?" go with their parentheses and are counted in the
closing note; math colours and backgrounds are left out (the reader owns its colours); a second line of marked
names is authors; a picture on its own inside a figure is the figure's image; headings have their own bottom
margin (the gap under "Abstract"). Reader bridge: the passage highlight is a box over the whole passage, equations
included, fading like a citation flash and cleared by a tap. App: a stored copy opens at once whichever app compiled
it; an older one is prepared again behind the page with a Reload bar when ready; a failure names its reason
(network errors included). Fragment tests 36.

Evidence (commit `556a95d`): compiler fragment tests 36/36; fast tier green; headless device compile ok for
2610.18683 (1.5 MiB); sweep replay 0 of 58 fail; iPhone Simulator unit tests 23/23 (ArxivHTMLReader,
ArxivCompilerFailure, ImportProgress, LibraryMetadata) and the reader journey
`ReaderNavigationTests/testHTMLPaperInPageLinksOfferBack` passed. Deployment: browser Pages **`27550fa8`** (the
live host serves it; the compiler chunk carries revision 7); TestFlight **build 44** iOS and Mac both VALID
(21:24 PDT). Stored papers prepared by build 43 or earlier open at once and are prepared again behind the page.

## Build 42 feedback: the device image budget, the header from the title page, the add-to-reading flow — 2026-10-15, ~04:30 UTC

Nine TestFlight items on build 42 and four chat messages within an hour (`docs/OWNER_FEEDBACK.md` "TestFlight,
2026-10-15 03:02–03:17 UTC"). What changed:

- **Device images.** Apertus 1.5 refused `image_total_limit` on the device path, which the sweep never ran. Each
  paper's images now share the 64-million-pixel budget (`pixelBudget`, at most 3 million each; a raster the reader's
  admission accepts within it is kept as it came, so every device stores the same bytes; pictures and over-large
  rasters are drawn scaled). `scripts/reader-device-compile.mjs` runs the whole device path in headless Chromium on
  cached papers (TESTING.md) and caught the next two refusals: a TikZ picture referencing a pattern LaTeXML defined
  elsewhere in the page (`svg_fragment`, then `svg_id`); shared definitions travel with the picture. Apertus: 9.1 MiB,
  31 images; PhysCodeGym 12.3 MiB; 2610.14075 16.4 MiB. The PNG admission's zlib has a browser adapter
  (`scripts/arxiv-compiler/zlib.ts`).
- **Header.** An author block set as a table reads by cells and rows; several names in one creator split by their
  marks; affiliations and notes on their own lines in a smaller face; a custom title page without an author block
  folds into the catalog header (names with marks, affiliations, "Corresponding authors"; date, report and e-mail
  lines go; a subtitle stays). `ARXIV_RENDERER_REVISION` **5**. Sweep replay: 0 of 58 fail. Fragment tests 33.
- **The flow from Add to reading.** Import rows no longer show a fixed 15 %: "Preparing…" with a spinner during the
  server's metadata stage; the paper is then downloaded and prepared on this device at once (`prepareOnDevice`),
  with "Downloading… 37%" in the row and in the Feed control, so opening it is immediate. Two device symbols
  (check / cloud); tapping the cloud or "Download to this device" prepares it; a dot marks papers added in the last
  three days and not yet opened; the Feed's checkmark opens the paper.
- **The reader says why.** A stored copy shown because re-preparation failed carries a notice with the reason and
  Try again (`readerFallbackNotice`, `reprepareSelectedPaper`). "Back to chat" after a chat citation opened the paper.
- **Chat.** A selection question carries the passage's paragraph marker ("[¶24]"), both surfaces; titles drop it.
- **Leaked commands.** Size and style commands LaTeXML leaves in running text (`\scriptsize①`, the owner's 03:17
  screenshot) are left out. `ARXIV_RENDERER_REVISION` **6**.
- **Proposals.** `docs/proposals/CHAT_TOOLS.md` (HTML answers, Mermaid, a "Visual answers" setting, figure crops).

Evidence (commits `cc5d4a2`, `ff41d48`): compiler fragment tests 34/34; fast tier green; headless device compile ok
for 2610.15542 (Apertus, 9.1 MiB), 2610.17288, 2610.10238, 2610.14075 and 2610.15371; sweep replay 0 of 58 fail;
iPhone Simulator unit tests 45/45 (ImportProgress, LibraryMetadata, ArxivHTMLReader, ArxivCompilerFailure,
ChatTitle, ReaderBundleLoader, LegacyArxivReader) plus the paragraph-marker title test; native journey
`ReaderNavigationTests/testHTMLPaperInPageLinksOfferBack` passed; browser typecheck and chat tests green.
Deployment: browser Pages **`38407158`** (live host serves it; the compiler chunk carries revision 6); TestFlight
**build 43** iOS and Mac both VALID (20:49 PDT). Stored papers prepared by build 42 or earlier are prepared again
once on first open.

## Refusals become degradations, the catalog heads the paper, two-word progress — 2026-10-15, ~03:45 UTC

Owner (chat): "maybe you could ask for an audit by a subagent" and "let's simplify [the paper prep step]. We only
need Downloading… and Preparing… with a total percentage value". `docs/OWNER_FEEDBACK.md` "Chat, 2026-10-15
(builds 39–40)" rows 4–6; the audit is in `docs/proposals/READER_ARCHITECTURE_RETHINK.md` "Independent audit".

- **Converter (rethink step 1).** Every audit finding applied, each with a fragment test: the caption-only figure
  branch only when nothing else has text; a text-only "equation" is a paragraph; a figure inside a list item follows
  the list; a TikZ label holding a table is a table; a top-level `svg` is a figure; over-long blocks are excerpted;
  a paper without an `h1` is headed by the catalog title (a stub page stays `source-unavailable`); the library's
  names head a paper whose HTML has no author block; front matter reads first when LaTeXML put a figure or a venue
  line before the title; publication notes under the title (a revision date, a venue, DOI, ISBN) are left out; a
  math mark beside a name is its symbol and an icon mark is no mark; a footnote in running text keeps its mark
  once; empty paragraphs (rules) are no blocks; panels laid out in a tabular of graphics are the figure's images.
  A logo on a custom title page is no figure (2610.15371, the owner's 19:42 screenshot on build 41: refused as
  `arxiv_title`; it opens now with the catalog title). Block ids are issued from a counter, never reused after a
  removal. `ARXIV_RENDERER_REVISION` **4** (stored bundles are prepared again once). Both apps pass the catalog
  record (authors, title) to the asset-planning call as well as the compile, so a paper without an `h1` plans too.
- **Refusals say why.** iOS carries the compiler's reason code (`ArxivHTMLError.compiler`, `ArxivCompilerFailure`:
  the browser frame's categories and words) and logs the code (`os.Logger`, category `arxiv-reader`; never source
  text). `tests/backend/reader-failure-categories.test.ts` extracts every converter code and requires a category on
  both surfaces and the same table in both.
- **Sweep.** The same 58 papers: **0 fail**, 2 warnings (51 unsupported commands in 2610.07591; a `\boxed` leak),
  3 without HTML — against 16 refusals and 1 failure before. Report
  `.artifacts/reader-sweep/sweep-2026-10-15T02-38-58-581Z.json`; `--replay=<report>` reruns a report's papers from
  the cached sources.
- **Limits.** The arXiv source limit (8 MiB) is `ARXIV_SOURCE_BYTES` in `profile.ts`, apart from the Mathpix
  renderer's `LIMITS.sourceBytes` (2 MiB again), which is part of that renderer's identity: raising it in `af9d9e5`
  had changed the identity of the committed Mathpix sample and failed the backend tier. Restored; the committed
  sample matches again.
- **Progress.** Library rows and the opening paper say "Downloading…" or "Preparing…" with one percentage
  (`ImportProgress.presentation`, `LibraryImportStep`, `ReaderModel.openingProgress` and `ArxivHTMLReader.phase`;
  web `progress.ts` and `Reader.tsx`); a download the server will retry reads "Downloading…".

Evidence (commit `61ee891`): compiler fragment tests 30/30 and the category test; fast tier green (compiler
freshness, backend, browser units); iPhone Simulator ImportProgressTests, LibraryMetadataTests,
ArxivHTMLReaderTests, ArxivCompilerFailureTests, ReaderBundleLoaderTests, LegacyArxivReaderTests 34/34; native
journey `ReaderNavigationTests/testHTMLPaperInPageLinksOfferBack` passed; browser reader journeys (arxiv-compiler,
arxiv-html, device-pdf) passed in 19.5 s; sweep replay on the final compiler 0 fail / 2 warn / 3 without HTML.
Deployment: browser Pages **`62b81784`** (02:55 UTC; the deployed compiler chunk carries the revision-4 converter);
TestFlight **build 42** iOS and Mac both VALID (19:57 PDT); the owner's 2610.15371 validates on this compiler
(480 blocks, 24 figures, 104 headings).

## Stale bundles re-prepared, 8 MiB sources, the fresh-paper sweep, the rethink — 2026-10-15, ~03:00 UTC (commit `af9d9e5`)

Owner (chat, builds 39–40): the PRISM header still old (a bundle stored by the older build was reopened as is),
Apertus 1.5 refused as over the limit, "set up a test suite so you detect more of these issues proactively", and
"it might be time for a rethink of what the architecture is… how quality is assured for each" with the suggestion of
a subagent audit. `docs/OWNER_FEEDBACK.md` "Chat, 2026-10-15 (builds 39–40)" has the rows.

- **Compiler identity in the store.** `scripts/build-arxiv-compiler.mjs` writes `arxiv-reader-build.json` beside the
  compiler; `ArxivCompilerIdentity` reads it; `openHTMLReader` prepares a stored bundle again when its manifest names
  another compiler (offline, the stored copy still reads). `ARXIV_RENDERER_REVISION` 3. The Xcode project is
  regenerated (`xcodegen generate`) so the new resource ships; the identity test passes.
- **Limits.** Source cap 8 MiB on the compiler, the browser and the native acquisition (Apertus: 863 blocks, 149 ms).
- **Sweep.** `scripts/reader-sweep.mjs` (TESTING.md "Slow, reader sweep"). First run, 58 papers: 16 refused
  (`arxiv_math_coverage` 9, `arxiv_nested_content` 2, `arxiv_title` 2, `arxiv_equation` 1, `arxiv_block_text` 1), 1
  empty author mark, 41 warnings (mostly the sweep's own macro check, since refined). Report under
  `.artifacts/reader-sweep/`.
- **Rethink.** `docs/proposals/READER_ARCHITECTURE_RETHINK.md`: components, real contracts, a quality gate each, and
  a three-step plan whose first step — refusals become degradations with a ledger, the header from catalog
  metadata, the sweep as the gate — follows the independent audit now in progress.

Deployment: TestFlight **build 41** iOS VALID (19:13 PDT), Mac VALID (19:18 PDT); browser Pages **`49a4000e`**;
both carry the identity, the limit and everything before.

## Template-broken title pages read by macro — 2026-10-15, ~02:00 UTC (commit `8d481e9`; deployed)

Owner screenshot (build 39, arXiv 2610.18356 "Urbex"): abstract above the title, "[ [" after the authors, a bare
date line. The compiler now keeps LaTeXML's error markers as empty spans naming their macro and reads a pre-title
paragraph of them by macro: the abstract goes after the authors, affiliations and contribution notes fold into the
author block, the plumbing stays out; punctuation-only affiliations and the `ltx_dates` line are dropped
(HTML_FIRST_READER.md "Title pages a template left in pieces"). Evidence: compiler tests 18/18, DPO and Urbex block
order, iPhone Simulator ArxivHTMLReaderTests and LegacyArxivReaderTests, browser types/build and the compiler and
arxiv-html journeys. Deployment: browser Pages **`43aef05a`** (the live compiler carries the change); TestFlight
**build 40** iOS VALID (18:52 PDT), Mac uploaded 18:5x PDT (processing when written).

## October platform cap raised — 2026-10-15, 01:30 UTC (owner: "push ahead")

The owner's chat refused with "AI answers are paused" at $23.20 of October's $25. On the owner's instruction the
limit is $30 now (schema ceiling), migration **068** raises the ceiling to $50, and October is set to $40 after it
applies; all inside the $100/month incremental budget (SPENDING_CONTROLS.md "October cap raised"). A chat live proof
after the raise answered in full (27 credits). Migration 068 applied and verified on staging 2026-10-15 ~01:40 UTC; October's limit is $40.00 (spent ≈ $23.5).

## Imports unstuck (arXiv OAI identifier), PDF Contents, device-availability rows — 2026-10-15, early (deployment noted below)

Owner (chat, with a Library screenshot): imports stuck at "Finding 15%"; how podcast jobs run and whether they
survive closing the app; Contents for older PDFs; whether a device holds a paper. `docs/OWNER_FEEDBACK.md`
"Chat report, 2026-10-15" has the four rows.

- **Imports.** The metadata stage's OAI-PMH request percent-encoded the identifier's colons; arXiv's OAI server began
  hanging on that form on 2026-10-14 (60 s timeout, `source_unavailable`, retried on backoff). Found by running the
  worker image locally with new failure diagnostics (`metadata_error` now carries `endpoint`, `status`, `reason`).
  `arxivURLs` builds the identifier with literal colons; verified inside the image (GetRecord 200 in 0.25 s).
- **PDF Contents.** `LocalPDFReaderView` lists the PDF's own outline (`PDFOutlineEntry`, four levels, 500 entries)
  and goes to the entry's destination; a PDF without an outline explains itself.
- **Device availability.** `PaperDeviceCopy` (reader / pdf / cloud / unavailable) from `ReaderModel.deviceCopy(for:)`
  on every Library row (`PaperTableTitleCell`), the browser's row badge, and Listen's refusals by state.
- **Podcast lifecycle** answered from the code (server job; polling while open; re-attached on reopening Listen).
  Proposed, not built: a "Your episodes" list across papers and a notice when one finishes.

Evidence (local): backend tests (arxiv, metadata-pipeline, pipeline-worker: 27); browser types and units (374);
iPhone Simulator `LibraryMetadataTests`, the Library table journey and the offline reader journey. Deployment
(2026-10-15 PDT): pipeline worker revision **00041** (GetRecord 200 in the image) and `paper-worker` at ~00:56 UTC;
all three stuck imports completed on their next retry (00:57, 00:59 and 01:05 UTC, records from the Atom API);
browser Pages **`ff4f6b0c`**; TestFlight **build 39** iOS and Mac VALID (17:59 and 18:03 PDT).
Commit `238d435`. The server asks arXiv only for metadata (Atom API, OAI-PMH); every paper's content is fetched by
the device — the owner's question is answered in OWNER_FEEDBACK.md row 5.

## Episodes from the paper on this device — 2026-10-14, late night (migration 066; built, deployment noted below)

Owner (TestFlight, build 35): Listen refused every paper read on this device ("we should have stopped storing PDFs at
all on the server… the message is also very off putting"). A private episode is now written from the paper's own
numbered text on the device: the client stores the text once (`podcast?action=source`), the quote names it by digest
with the paper's identity, and the pipeline runs unchanged from that text (PAPER_PODCASTS.md "Episodes from the paper
on this device", design and as-built). Shared catalog episodes and Mathpix-era private episodes are unchanged.

Evidence (local): database suite with `podcast_device_sources.sql`; backend tests 472+ (the `source` action, the
quote descriptor, marker stripping); browser types and the podcast/arxiv journeys (10 passed); iPhone Simulator
`PodcastTransportTests` (incl. the device source test), the private generation and transcript evidence journeys.

Deployment (2026-10-14/15 PDT): migrations **066** and **067** applied and verified on staging (067 supersedes
`worker_podcast_asset_plan`, which read the Mathpix source row strictly: the first five-minute proof failed at
"publishing" with `database_error`); `podcast` function deployed; pipeline worker revision **00040** (device text
accepted, marker rule and strip); browser Pages **`e7764deb`**; the private bucket **`private-content`** provisioned
(512 KB, text/plain; now in `infra/staging.json` as `podcast_source_bucket` and verified by `deploy-staging.py`
whenever `podcast` deploys); TestFlight **build 38** iOS and Mac VALID (17:16 and 17:20 PDT). Live proof
(`scripts/podcast-device-smoke.mjs --profile=podcast-5min-v1`, disposable account, deleted after): the DPO text
(274 blocks, 111 KB) stored by digest, quoted (5 min, DeepSeek, 150 credits max), started, **ready in 85 s for 31
credits**; the paper lookup by membership id returned the episode with `document_id` = membership and the arXiv
source; transcript 19 segments, 12 evidence quotes, none carrying a paragraph marker; opening "Welcome to Gradstep.
Today we are looking at Direct Preference Optimization…". Two earlier proof runs failed and charged zero: a Short
(150 s) DeepSeek draft of 710 words (`spoken_too_long`, `word_budget`; the writer ignored the Short length — a
known DeepSeek variance, not a device-source fault) and the 067 bug above. Their known costs ($0.10 + $0.26) took the
month's podcast quality losses to the $0.75 allocation, which paused private generation (`podcast_paused`), so the
podcast policy's `quality_allocation_microusd` was raised to **$2.00** (revision 10, reason recorded; inside the $25
provider cap, no budget change) and the proof passed.

## TestFlight screenshots on builds 33–36: author blocks, Listen copy, menu wording — 2026-10-14, late night (built; deployment noted below)

Six screenshot reports (`docs/OWNER_FEEDBACK.md`, "TestFlight screenshots, 2026-10-14"). The arXiv compiler's author
block now covers per-author "Affiliation:" contacts (numbered marks), e-mail, project pages and dagger notes, and
takes the library's author names from both apps for logo-only names (HTML_FIRST_READER.md "Authors block", second
paragraph). Listen's two refusals are reworded (no "server copy of the paper"; what to do next) and the Listen menu's
"Refresh episodes" reads "Check for new episodes". The browser compiler journey's second case now uses a page without
an article (LaTeXML error markers are tolerated since `c615af3`). Episodes from the paper's own text on the device are
designed in PAPER_PODCASTS.md and built next.

Evidence (local): compiler tests 17/17; `npm test`; browser types, units, arxiv-html and arxiv-compiler journeys;
iPhone Simulator `ArxivHTMLReaderTests`, `LegacyArxivReaderTests`, `OfflineModelTests`, the HTML Back journey and
the Listen filter journey. Deployment: commit `c2ad885`; browser Pages `fa19e107` (2026-10-14 16:58 PDT); TestFlight
**build 37** iOS and Mac VALID (16:59 and 17:02 PDT). Build 38 (above) carries these too.

## Owner reports: authors list, Back after a jump, scrolling while streaming — 2026-10-14, night (built; deployment noted below)

Owner (chat): "make sure that the authors list is presented nicely on all surfaces"; "the 'Back to where you were'
… no longer is there (all surfaces)"; "when the text is coming out (streaming) in chat, and I try to scroll up …
it won't let me stay where I am (all surfaces)". `docs/OWNER_FEEDBACK.md` has the three rows.

- **Authors.** The arXiv HTML compiler renders LaTeXML's author block as names with single marks, then affiliations
  and notes on their own lines, without "footnotemark:" labels or e-mail (`authorsBlock`, HTML_FIRST_READER.md
  "Authors block"); the device compiler was rebuilt for both surfaces. One author rule set on both surfaces:
  `apps/web/src/lib/authors.ts` (`compactAuthors`, `authorLine`, `firstAuthorLine`) and native `LibraryFormat`
  (`shortAuthors` now three family names, `authorLine`): library rows/columns, feed rows/cards, podcast cards and the
  player's "Paper by", pending imports, bylines.
- **Back.** Not reproduced; verified three ways (new native journey `testHTMLPaperInPageLinksOfferBack` on the HTML
  fixture, the browser arXiv journey with the chat pane open and Back `toBeInViewport`, a WebKit harness on the real
  DPO paper by mouse and touch). Bridge hardening: the landing place waits for the page to stop (6 s, not 1.5 s), and
  Back outlives only the reader's own wheel/touch/key scrolling (`movedSinceJump`).
- **Streaming scroll.** Following resumes only at the end of the transcript (2 px/pt) after the reader's own scroll;
  programmatic scrolls are ignored (CHAT.md "Transcript follow").
- **Also:** three `podcast-evidence` tests still assumed Markdown cut a turn (stripped since `ce17eb9`); they now use
  unreadable math and unsupported numbers.

Evidence (2026-10-14 night, local): compiler tests 15/15; `npm test` fast suite; browser units (`authors`,
`chat-follow`); browser journeys arxiv-html, chat, reader-drafts, library, feed-abstract; iPhone Simulator
`LibraryMetadataTests`, `ReaderNavigationTests` (all, incl. the new HTML journey), the chat follow journey and the
figure gallery Back journey. Commit `beba14c`.

Deployment (2026-10-14 PDT): browser Pages **`943836e8`** (the live `arxiv-reader.js` carries the author block and the
app bundle the bridge hardening, author rules and transcript follow); TestFlight **build 36** iOS uploaded 16:31 and
VALID on App Store Connect, Mac uploaded 16:34 (processing when written). No server function or migration changed.
Owner acceptance of builds 31–36 remains open.

## Study tutor, audit fixes, native sync scheduler — 2026-10-14, midday (commit `bafae2d` and after; deployment noted below)

Owner (chat): address the open audit items, look at the podcast feature, and "take a stab at an experimental feature
that combines quizzes you and teaches you about a paper… adaptive… display [the mental model] in some type of flow,
html, or graph."

- **Study (experimental).** A paper chat with `action: "study"`: the tutor judges the reader's answer, then teaches
  with `[¶N]` citations, verifies, goes deeper, moves to a related concept or returns to an earlier gap, one bold
  question per turn; a forced Haiku 5.5 request updates the reader's knowledge map after each answer and the server
  relays it as a `study` event; the clients send it back with every turn and keep it in memory only. Browser: "Study
  this paper", a knowledge-map panel (Mermaid map, journey chips, concepts with state, note, links and ¶ buttons),
  End study. Native: the same from the empty paper chat and the chat menu, a map bar above the message box with a
  Map/Journey/Concepts sheet. Design record in [DECISIONS.md](DECISIONS.md#study-an-adaptive-tutor-on-one-paper-owner-asked-2026-10-14-agent-decisions-experimental-reversible),
  contract in [CHAT.md](architecture/CHAT.md#study--2026-10-14-experimental-staging).
- **Cost and credit audit** ([review](reviews/COST_CREDITS_AND_SYNC_AUDIT_20261014.md)): items 2, 4, 5, 6 and the
  byte-counting part of 3 are built (migration 060: budget rows create themselves monthly, `worker_budget_health`
  with a scheduled `budget.health` check, the stale sweep books no spend, `sync_page_too_large` for old builds;
  failed answers charge nothing and say so); item 1 has a release tool (`pipeline-ops.py attempts|reconcile`); the
  store copy no longer sells OCR pages. The smaller byte count for holds (item 3) went live in function 118 and was
  **reverted in 121 the same hour**: a follow-up attempt's actual cost exceeded its per-attempt ceiling and paused
  all paid work on staging for about eleven minutes (16:53–17:04 UTC); the switch was set back on at the same limit.
  Still open: 3 in full (a real token count), 7 (refund reconciliation), 8 (audited grants RPC), 9 (spend history;
  the podcast cap at balance is in the podcast pass), 10
  ([SPENDING_CONTROLS.md](architecture/SPENDING_CONTROLS.md#budget-periods-failed-answers-and-the-stale-hold-sweep--2026-10-14-migration-060-staging)).
- **Sync audit:** items 1, 2 (both surfaces), 3 (native 60 s scheduler with 15/60/300 s backoff, command drain,
  named codes, acknowledgement tolerance), 4 (the browser keeps the storage-persistence answer and says "Saved in this
  browser. It may clear this when space runs low." when declined) and 5 (honest copy for an unsupported journal) are
  built; 6 (hosted two-device evidence on format 2) remains.
- **Podcast UX** (merged from the worktree branch, commit `78e1ba4`): a read-only review ranked eight improvements
  and the four obvious ones are built: the player's heading, slider, transport, Download and pane picker are a fixed
  header and only the pane scrolls; a job that finishes while its sheet is closed raises "Your episode of … is
  ready" with Play (an alert, or a banner inside an open player or Listen sheet), the progress screen states the
  expected wait per length, and the 1,800 s polling limit says "Still preparing" instead of going quiet; the Listen
  sheet shows "Available: N credits" at once, greys lengths whose maximum exceeds the balance, quotes on choice and on
  opening so Create is the one confirm step, pinned at the bottom; the playback speed is remembered per device
  (UserDefaults). The fixture maxima are v2 (140/300/530). No local notifications (owner decision). Evidence: 20 unit
  tests (PodcastTransport, 4 new PodcastPresentation, PodcastFixture) and the iPhone PodcastJourneyTests 16 of 17
  (one iPad-only skip) with four new journeys; the same journeys on the 13-inch iPad fail at their first step because
  the wide layout has no tab bar (pre-existing; the doc records them on the iPhone). Still open from the review:
  Listen's visibility on the paper and in lists, the reader's own episode list, play-before-download feedback,
  browser parity, the mini-player's Stop, and the Mac player capture's black title bar (likely a capture artefact).
- **Podcasts cannot be created (owner, afternoon):** two causes, both recorded in
  [OWNER_FEEDBACK.md](OWNER_FEEDBACK.md#chat-report-2026-10-14-afternoon-i-was-not-able-to-create-a-podcast-at-all):
  device-prepared papers have no server text to write from (the Listen notice now says so instead of blaming the
  synced library), and every generation for legacy papers since 2026-10-09 has failed at the evidence checker's word
  floor after removals. The repair (commit `c43b538`, migration **062**: route `podcast_script_repair`, version-3
  profiles with the extra call, one bounded second draft from quoted evidence, no second review) is **deployed**:
  migration applied and verified at 18:08 UTC, `podcast` and `podcast-member` functions deployed, the policy moved to
  the version-3 profiles through the audited operator path (revision 6), quotes now say up to 180/200/360/610 credits
  and the app fixture matches. Evidence: backend podcast tests 55, database suite with `podcast_script_repair.sql`,
  native podcast tests 21. Not yet verified live: a real generation through the repair needs either the owner trying a
  pre-cutover paper or one more seed, and October's seed allowance has $0.58 of $3.00 left, which no profile's ceiling
  fits; raising it is the owner's call. Episodes from the device's own numbered text are a design change still to
  write up.
- **DeepSeek writes podcast scripts (owner: "set up DeepSeek, prove it works with podcasts").** A second script
  provider, built the same afternoon: `supabase/functions/_shared/deepseek.ts` sends the worker's Anthropic-shaped
  script calls to DeepSeek's chat completions in JSON mode with the draft or review schema in the system prompt,
  thinking disabled (on by default there, and its tokens come out of the output allowance: a 60-token probe returned
  only reasoning), and reports usage in the adapter's shape; the rate card carries `deepseek-v4-pro` (peak list
  $1.32 / $3.96 per million, cache hits $0.044) and `deepseek-flash` ($0.30 / $1.20). Migration **063** adds the
  provider, admits it for the three script routes, takes the provider from the profile spec, names it in the quote
  ("DeepSeek (script)") under consent `podcast-private-v2`, and adds version-4 profiles (DeepSeek V4 Pro) whose
  maxima are 140 / 150 / 280 / 500 credits against 180 / 200 / 360 / 610 for the Sonnet profiles. The worker picks
  the provider the spec names; the pipeline worker builds both from their keys. The browser's quote handling no longer
  pins the Anthropic label, the 150-credit maximum or consent v1 (it had refused every quote since the v3 move);
  the native quote already read providers and consent from the server. Evidence: backend 60 podcast, adapter and
  evidence tests; database suite with `podcast_deepseek_profiles.sql`; web podcast tests 36; a live probe of both
  aliases through the adapter. **Proven live** on the fourth seed (job `fe9e26d4`, CoTrace, profile v5 after three
  failed seeds taught three fixes: a trim repair for over-length drafts, a tolerance band on the version-2 word
  range, and larger output caps with compact JSON): an episode of 5 min 35 s, 686 words, three turns removed within
  limits, released as `c7a9a3e4` pending the owner's seed review. Cost of that run: DeepSeek draft $0.061 (33k input,
  4.3k output) and review $0.050, speech $0.152; the script stage was $0.111 against about $0.35 for the same two
  calls on Sonnet, and the two earlier DeepSeek runs with cache hits cost $0.05 and $0.12. Deployed: migrations 063
  and 064, pipeline worker revision **00037**, policy revision 8 on the version-5 profiles (maxima 140/150/300/520
  credits), Pages **`9b227fa2`**. October's seed allowance was raised from $3 to $4 for the proof (four seeds, $2.87
  committed). Caveat: DeepSeek's drafts vary more than Sonnet's (604, 876 words and one runaway in four tries), which
  is why the tolerance and the trim exist; if the owner's own episodes fail, `podcast-ops.py policy --set
  profile_version=3` returns to Sonnet. The proposal in [proposals/CHEAP_PROVIDER.md](proposals/CHEAP_PROVIDER.md) is
  superseded by this build for podcasts; chat still uses Anthropic only.
- **Writer choice (owner, evening):** readers pick who writes the script. Migration **065** lets a length be offered
  under one allowed version per writer and lists them (`podcast_lengths().writers`, default first, each with its
  own maximum, estimate and consent version); the quote takes `writer` and resolves that version, so the quote's
  providers and consent follow the choice; a replay with another writer conflicts. The native Listen sheet shows
  "Written by" (DeepSeek V4 Pro / Claude Sonnet 5.5) above the lengths and re-quotes on change; the browser dialog
  offers the same before the estimate. The policy (revision 9) offers both writers for all four lengths with DeepSeek
  as the default: 140/150/300/520 credits for DeepSeek and 180/200/360/610 for Sonnet. Evidence: database suite with
  `podcast_writer_choice.sql`, backend podcast tests 44, web podcast tests 36, native podcast tests 22 (a writer-choice
  case among them), the full native tier before the build. Deployed: migration 065, the podcast function, Pages
  **`c4737d77`**; **TestFlight build 35** (iOS and Mac) uploaded at 12:53 and 12:57 PDT after the native tier passed.
- **Openings and spoken markup (owner, after the first episode):** the episode opened mid-answer because the checker
  had cut the opener (an unanswered question) and four turns for markup. Readable markup is now stripped and the turn
  kept; the writer opens with a welcome and closes with a sign-off; a passing check that leaves the dialogue broken
  runs the repair or refuses the episode; the version-2 word band is 80%–125% of the writer's range. Worker revision
  **00039**; backend podcast tests 51. Verified on seed `8dd7ac8f` (release `9e90fb77`, pending the owner's review):
  24 turns kept, opens "Welcome to Gradstep…". October's seed allowance now has $0.70 of $4.00 left.
- **Test fixture:** OfflineModelTests no longer fetch a real arXiv paper (a 5 s timeout since c615af3; the fixture
  answers arxiv.org in-process); the fixture host gains `--study-fixture` (the shared arXiv HTML fixture as a
  numbered membership) for the `study-bar`/`study-sheet` captures.

**Evidence (local):** backend 91 chat tests; web units 370 (37 files); browser journeys study, arxiv-html and
chat-controls 11 pass on desktop, phone and WebKit (10 skipped by capability); database suite passes with
`budget_period.sql` and `chat_study_quotes.sql`; Core `swift test` 294 in 38 suites; iPad Simulator
ChatGenerationTests 34 (Study flow included), OfflineModelTests 15, SyncSchedulerTests 6, LegacyArxivReaderTests 4.
Captures `.artifacts/visual/study/` (iPhone, iPad, Mac; light and dark): the map bar after one answer and the map
sheet; the iPad sheet draws the map, the first phone sheet capture was taken before the renderer finished.

**Deployment (2026-10-14, 16:53–17:10 UTC):** migrations **060** and **061** applied and verified on staging (the
pre-migration backup attempt exceeded its 12-minute limit again, as before 059; the newest complete checkpoint is still
2026-10-09); chat function **118 → 121 → 122** (121 restored the hold sizing after the pause above; 122 makes the map
validator tolerant of one bad link or journey entry); browser Pages **`0a4c0f85`**. Migration 061 was found by the
first live study turn: function 118 sent the three study quote keys and `worker_reserve_chat` (059) refused the key
set as `invalid_request`. Live study smoke after 061 and the switch (`chat-live-smoke.mjs --study`, 17:05 UTC): three
tutored turns on DPO v3, 4/4, 4/4 and 5/5 citations resolvable, maps after turns one and two (3 concepts, 3 links,
focus and journey as the tutor's replies implied), the third turn's map update dropped by the strict validator (hence
122), 31 credits in all. **TestFlight build 34** (iOS and Mac) was archived from the merged tree after the full
native tier passed and uploaded at 10:22 and 10:25 PDT; the iOS upload was VALID on App Store Connect when this was
written, the Mac upload still processing. Build 34 carries the Study tutor, the podcast pass, the native sync
scheduler, the sync copy, the zero-cost failed answers and the credits-store copy.

## Owner report and the iPad/Mac audit — 2026-10-14, early morning (built; deployment noted below)

Owner (chat, build 31): papers already in the library don't open; new papers still fail with "Couldn't open this
paper"; frame what is downloaded better. In parallel: an iPad and macOS UX and reliability audit. Everything here is
in the working tree; the deployment state is in the last paragraph.

- **Legacy library papers.** The owner's 42 visible pre-cutover items all read as available on the server (every
  one with a bundle, approval, metadata and original; read-only query), so the failure was on the device: a legacy
  item opened only through the server-bundle path, which could end silently on an actionless "Paper download
  needed". Legacy arXiv items now open through the on-device HTML reader by their exact revision (the same path as
  new papers), the installed server copy still opens offline, the server bundle is the fallback, and every refusal
  has a reason and an action. Browser: the same through `readingSource`; chat keeps the item's server document.
  Library rows say "Opens from arXiv" until a paper is prepared on this device.
- **New papers.** The nine papers the owner added on 2026-10-13/14 were fetched with the paced corpus tool
  (`READER_CORPUS_SET=owner-20261014`; all nine have arXiv HTML) and replayed offline: **five of nine refused to
  compile** (`arxiv_conversion_error` ×1, `arxiv_nested_content` ×3, inline TikZ pictures ×2 of those and one
  more at the SVG admission). The compiler now drops and counts LaTeXML conversion markers, leaves out and counts
  graphics in running text, reads a lone graphic paragraph as a figure, reads TikZ text boxes as paragraphs and
  keeps TikZ diagram labels as SVG text, and derives its asset and inline-SVG lists from a dry compile; a closing
  note in the paper says what was left out. Nine of nine compile in Node; browser replay evidence below.
- **Audit.** [docs/reviews/IPAD_MAC_AUDIT_20261014.md](reviews/IPAD_MAC_AUDIT_20261014.md): 472 iPad captures (two
  sizes, light/dark, both orientations, every scenario) and 26 Mac captures per appearance through a new
  permission-free Mac capture path (`VisualCapture.swift`, `--devices=mac`), with the findings and what still needs
  the owner's eye. The `--appearance` and `--window-size` arguments and the `--wide-mode`, `--visual-ask`,
  `--visual-show-*` staging arguments were added to the fixture app for it.

- **Build 31 screenshots (15:34 UTC), same morning:** a figure drawn 0.65 em tall (a graphic wrapped in a figure
  paragraph was treated as a legend symbol; now the figure's full-size image, and a caption-only figure reads as its
  caption), no "Back to where you were" after an in-page citation link in HTML papers (the bridge now jumps with Back
  for every in-page link, on both surfaces, asserted by the browser journey), and poor scrolling while an answer
  streams (flush interval now grows with the answer; the end-of-answer jump still needs the owner's eye). Rows in
  [OWNER_FEEDBACK.md](OWNER_FEEDBACK.md#build-31-2026-10-14-iphone-3-items-testflight-screenshots-15341536-utc).

**Evidence (local, final tree):** fast suite passes (compiler freshness, backend 447 → the compiler tests grew from
9 to 13, browser units 362); the owner's nine papers replay in Chromium **18 of 18** (every HTML compiles, verifies and
renders; every PDF imports on the device); the pinned corpus replays **16 of 16** with DeepSeek-V2 v1 now a supported
paper (271 blocks, 225 equations, 6 figures, one dropped marker noted) and KAN v1 still refused at the pixel limit
as recorded; browser journeys arxiv-html, reader-drafts and chat pass on desktop Chromium (14 of 14 chat journeys; the
chat journey now aborts arXiv so its legacy fixture item falls back to the server bundle, as production would offline); iPad Simulator native tier passed with the final compiler bundle, plus
LegacyArxivReaderTests (4 new), LibraryModelTests, PaperPassageTests and ArxivHTMLReaderTests; Swift Core chat
tests 23. The pinned lock gained DeepSeek-V2's six assets; no pinned HTML digest changed.

**Deployment:** browser Pages **`4fdd4675`** (app.gradstep.ai) with the compiler and legacy reading; TestFlight **build 32**
uploaded for iOS and Mac (one upload VALID on App Store Connect at the time of writing, the other processing); the
build-31 screenshot fixes went to Pages and **build 33** afterwards (handoff); no Edge function or migration changed (the compiler
runs on the device and in tests only).

### Native sync reliability — 2026-10-14 (working tree; not committed or deployed)

From the read-only sync audit: the native app never polled or retried sync, mapped `reader_update_required` to a generic
message, and reported a failed `v1_acknowledge_cursor` as "Sync paused". Now `ReaderModel` runs `synchronize()` every
60 s while the scene is active and an account is activated, backs off 15 s → 60 s → 300 s after failures, drains
pending library commands on the same tick, never starts beside a running sync, and stops when the scene is inactive or
the account signs out (two pulls a minute per device, against the server's 1,000 sync reads an hour per account).
`reader_update_required` and `sync_page_too_large` read "Update Gradstep to keep syncing this history. Everything on
this device stays available."; `ReaderError` cases carry their own copy; an undecryptable remote entry is named
(`invalidEvent`) instead of "Sync could not finish"; the session timeline records each sync's outcome code, never text.
A failed acknowledgement after a complete pull is logged and sent again next sync, as the browser does.

**Evidence (local):** Core `swift test` 290 tests in 37 suites; iPad Simulator SyncSchedulerTests 6 of 6 (interval,
back-off order 1 → 2 → 3, stop when inactive, resume, sign-out, acknowledgement tolerance, update copy, unreadable
entry, codes), LibraryModelTests 12 (1 skipped), PDFUploadTests 6, LiveSyncTests skipped (hosted fixture absent).
OfflineModelTests: 14 of 15 pass; `testDownloadQuotaAndUpgradeReasons…` times out identically on an untouched HEAD
checkout (since c615af3 a legacy fixture item first fetches the real arXiv paper 2404.00001 before the server-bundle
fallback the test observes within 5 s), so it is a fixture follow-up, not a regression here.

## Agent v2 on staging — 2026-10-14 (deployed)

Owner direction (2026-10-14): a materially better agent ("new tools, new capabilities, better performance, more
stable, better design and UX"), more UX work before each build, and one answer per hard problem across surfaces.
Design: [CHAT.md, Agent v2](architecture/CHAT.md#agent-v2-2026-10-14-numbered-context-grounded-citations-follow-ups);
decisions: [DECISIONS.md, Agent v2 and framework stance](DECISIONS.md#agent-v2-and-framework-stance-agent-decisions-2026-10-14-reversible);
pre-build review: [UX_REVIEW.md](UX_REVIEW.md). This release also carries the post-cutover maintenance below
(arXiv acquisition pacing, shared preparation, Go to passage across renderer revisions, dead PDF code removed).

- **Numbered paper context** (`reader-local-context-v2`): a device-prepared paper is sent block by block with `[¶N]`
  markers by both clients (`apps/web/src/lib/paper-context.ts`, Core `PaperChatContext`), tested against the same
  golden fixtures (`tests/fixtures/reader-arxiv/local-context-v2.txt`, `figures-local-context-v2.txt`).
- **Grounded citations**: answers cite `[¶N]`; the marker is a control on iPhone, iPad, Mac and the browser that lands
  on the block with Back; a marker the paper lacks shows a notice. Server-held (historical) papers are not numbered.
- **Follow-up suggestions**: two or three one-tap questions under the newest answer (fill the message box, never
  send). Built first as an optional tool for the answering model; the first live check returned 15 citations and no
  follow-ups (Sonnet at low effort ended its turn without the call), so it became a forced Claude Haiku 5.5 side
  request after the answer (`chat-follow-ups.ts`, request flag `follow_ups: true`, held and frozen in the quote by
  **migration 059**). One mechanism, model-independent, covered by tests.
- **Browser composer and waits**: one short status line instead of a repeated storage caveat; "Thinking… N s" after
  five seconds.
- **Review tooling**: `node scripts/ux-review.mjs` (48 browser captures, light/dark, desktop/phone),
  `scripts/visual-check.mjs capture --label=agent-v2` (iPhone chat screens) and the paid, explicit
  `scripts/chat-live-smoke.mjs` ([TESTING.md](TESTING.md)).

**Deployed:** migration 059 applied and verified in the ledger (`python3 scripts/migrate-supabase.py staging`);
`chat` function deployed twice (the second carries the side request and the quote fields); browser Pages
`6cb0d781` (app.gradstep.ai); native **build 31 is VALID on App Store Connect for both the iOS and the Mac upload** (uploaded 23:19 and 23:23 PDT;
`BUILD_NUMBER=31 scripts/upload-testflight.sh`, then the Mac script); owner device acceptance is still open. An encrypted backup checkpoint was started before the migration and **failed after its time limit**
("Backup time limit exceeded"; the partial `20261014T060655Z-fb0a0dd6b47f` was discarded by the tool), so the newest
complete checkpoint remains `20261009T194433Z-3ae85413991f`. Migration 059 adds three nullable columns and replaces
one function; nothing was deleted or rewritten. The backup tool's limit against the current bucket size is a
maintenance item. Admin `91c1eb33` and Cloud Run `gradstep-pipeline-00033-2jw` unchanged.

**Evidence (local):** fast suite **447 backend + 362 browser unit tests** plus compiler freshness in about 10 s
(chat contracts 87, including the forced side request, its hold and quote, the flag rules and the validator); the
database suite on the local fixture **321 steps pass** including migration 059 and
`tests/database/chat_follow_up_quotes.sql`; Swift Core ChatStreamTests + ChatProfilesTests **23 pass** (the request
contract now includes `follow_ups`) and DeviceReaderTests golden-context comparison 5 pass; browser journeys on
desktop Chromium (arxiv-html, chat, chat-controls) **17 pass** after the fixture backend began gating follow-ups on
the flag, with journal and reader-drafts passing earlier in the night; iPad Simulator ArxivHTMLReaderTests,
PDFUploadTests, ChatGenerationTests (follow-up chips, cited answer) and PaperPassageTests passed (83 s) before the
request flag was added (those suites use the fixture transport; the body is covered by the Core tests).

**Evidence (hosted, staging, real model; disposable account deleted each run, DPO 2305.18290v3 metadata membership,
274-block local context v2):**

| Run (UTC) | Question | Citations (resolvable) | Follow-ups | Credits | First text | Total |
|---|---|---|---|---|---|---|
| 05:52, before the side request | reference model and loss | 15 (15) | 0 | 27 | 3.4 s | 11.3 s |
| 06:14, Q1 | same | 22 (22) | 3 | 27 | 3.0 s | 12.2 s |
| 06:14, Q2 = first suggested follow-up | β in practice (cache read 47,062 tokens) | 14 (14) | 3 | 4 | 2.1 s | 9.6 s |

Topic titles arrived on the first turn ("Reference model role in DPO loss"). Provider attempts for the three smokes:
**$0.279296** (7 attempts). Platform budget readback at 06:25 UTC: **$21.023497 spent of $25, $0 reserved, work
enabled** (Anthropic attempts in October $5.501806 across 122 attempts; the rest of the platform figure is earlier
Mathpix and other provider spend). Captures reviewed: browser `.artifacts/ux/web/index.html`, iPhone
`.artifacts/visual/agent-v2-sheet.png` (chips and citation controls in light and dark at phone width).

**Not done / limitations:** owner acceptance of build 31 on a device (physical iPhone work remains paused); the
`chat.profiles` workflow check does not send `follow_ups` yet (the next paid workflow run should, expecting three
provider attempts per titled answer); the 1-hour prompt cache remains an owner cost decision; "Explain this figure"
with an image attachment and a library-aware tool were considered and not built (see DECISIONS.md).

## Post-cutover maintenance — 2026-10-13, late (local only; nothing deployed)

*Superseded 2026-10-14: these changes shipped with Agent v2 above (browser `6cb0d781`, build 31, the deleted server code).*

A repository review after the cutover found and fixed the following. All changes are in the working tree with the
rest of the HTML-first work; **none is deployed**: native build 30, browser Pages `a3127547`, admin `91c1eb33`,
migration 058 and Cloud Run `gradstep-pipeline-00033-2jw` are unchanged.

- **Opening a paper was slow by design.** Every arXiv request waited three seconds, so a sixty-figure paper
  (`2610.12978v1`) took about three minutes to prepare, on every browser reload. Both clients now space only the
  HTML document request and load one paper's assets four at a time with no artificial delay, still bounded and
  still honoring `Retry-After` (a pause over a minute is reported as busy at once). [Design](architecture/HTML_FIRST_READER.md#maintenance-after-cutover--2026-10-13-late-local-not-deployed).
- **The browser could prepare the same paper twice** (reader and a paper question asked meanwhile). One
  in-flight preparation per exact revision is now shared, with progress forwarded to every waiter.
- **Go to passage broke after any renderer revision.** Native and browser refused anchors whose bundle digest
  differed from the current compile (the browser silently); the v1 → v2 renderer bump already made every earlier
  browser anchor unreachable. The digest now only decides whether the block hint applies; the quote cascade finds
  the passage, and the "couldn't find" notice is reserved for a quote that is really absent.
- **Dead PDF/OCR code removed.** Server: `pipeline.ts`, `reader-adapter.ts`, `pdf-uploads.ts`, `asset-upload.ts`,
  the Mathpix HTTP client and the web PDF downloader, with their tests (the metadata pipeline owns its types; the
  historical OCR identity stays for retained bundles). Browser: the chunked upload transport and PUT helper.
  Native: `PaperAddingService`/`BackendClient` upload methods, tickets, chunk digests, back-off and the fixture's
  upload script. A pre-cutover queued file is offered **Save on this device** instead of a retry that could never
  succeed; the Simulator test covers both the refused and the saved outcomes.
- Evidence (local): fast suite **443 backend + 356 browser unit tests** and compiler freshness pass in about
  10 s; Swift Core **287 tests** pass; web and admin TypeScript, Deno Edge checks and the Node worker entry
  type-check. Slow checks rerun for the touched areas: authored browser reader journeys on desktop Chromium plus
  the Firefox compiler project, **6 pass** (13.5 s; the pinned-HTML journey still sees exactly two arXiv
  requests and zero PDF/artifact requests); iPad Simulator **13 XCTest cases pass** (PDFUploadTests 6, including
  the new refused-then-saved legacy-file case, and PaperPassageTests 7) alongside the two WebKit compiler
  tests, 81 s including build. The real-source corpus and WebKit/phone browser projects were not rerun: no
  adapter, validator, CSP or bridge contract changed.

The working tree still holds the entire HTML-first cutover **uncommitted** (about 200 files, including the
deployed migration 058). Committing it is the owner's call; the pre-review tree is saved as a patch in the
session scratchpad, so the review's changes can be separated from the cutover if wanted.

## Fast/slow integration baseline — 2026-10-13 evening

Owner-directed [fast/slow policy](TESTING.md) is implemented: `npm test` is the routine fast suite; browser journeys,
real-source corpus, Simulator, database and hosted checks remain explicit slow commands. The runner saves source
fingerprints, selections, durations and logs; `npm run test:status` reports prior evidence without rerunning it.
Unchanged slow behavior does not need another run after unrelated edits.

Verified baseline: **499 backend + 349 browser unit tests** and compiler freshness in **10.2 s**; **13 authored
browser journeys pass / 3 WebKit key-capability skips** in **23.9 s**; **40 real-corpus checks pass / 8 WebKit
account skips** in **145.7 s**; **6 native PDF + 2 WKWebView tests pass** on iPad Simulator in **75.1 s**.
The corpus has eight PDFs / **278 pages**, up to **36.2 MB**. All eight pass Chromium and Firefox local intake
and membership reload, plus native PDFKit checks, encrypted installation, exact-byte reopen and first/middle/last
page rendering. PDF bytes never leave this development device. No paid providers were called.

Across Chromium, Firefox and WebKit, **six HTML papers prepare and render successfully**; KAN v1 is explicitly
unavailable because it exceeds the 64-million-image-pixel limit, and DeepSeek-V2 v1 contains an official source
conversion error. These six expected-unavailability assertions across three engines are not successful reader
conversions. No limits or completeness checks were weakened. [Exact revisions and evidence](verification/2026-10-13-reader-integration.md).

The expanded Firefox journey found a real sign-in stall: awaiting optional `navigator.storage.persist()` held
up key preparation while permission remained unanswered. Verified key storage/readback remains mandatory; the
advisory permission request is now nonblocking. Four fast regressions cover pending, denied, rejected and throwing
requests; all eight Firefox PDF journeys subsequently pass. Browser Pages **`a3127547`** is deployed; the live
`app.gradstep.ai` index and both referenced JS/CSS assets match the tested build hashes with production CSP.
Evidence: `.artifacts/reader-integration-hosted-assets.json` and `.artifacts/reader-integration-deploy.log`.
Native remains build 30; backend/admin are unchanged. The native baseline was not needlessly rerun for this
browser-only correction. Physical iPhone work stays paused. Budgets and provider spending are unchanged.

## HTML figure compatibility fix — 2026-10-13 evening

The screenshot identifies **Before They Can Solve**, `2610.10478v1`. Its failure was reproduced: a LaTeXML
container includes several numbered image/caption pairs, and MuPDF SVG glyphs carry inert `data-text` annotations
that were wrongly interpreted as CSS. **Learning Representations to Guide Pixel Diffusion Transformers**,
`2610.12978v1`, visible next in the sidebar, also failed on inline SVG legends and MathML background colors.

Browser Pages **`16b9e4ce`** implements renderer/provenance v2. It preserves each captioned panel, standalone images,
legend prose and rasterized inline vector symbols; maps the finite LaTeXML background-color property to MathML;
and strips only MuPDF's non-rendering glyph metadata before SVG admission. V1 bundles remain readable. External
assets remain pinned to exact arXiv revisions; inline vectors are derived from the hashed HTML and receive separate
provenance, never fabricated fetch URLs. Source scripts, unsafe SVG, external SVG resources and incomplete content
remain rejected. Error categories from the earlier diagnostic release `e9d6522a` are retained.

All five real papers (the original three plus these two) pass Chromium, Firefox and WebKit compilation (15/15),
and their packages independently pass the Node validator. The reported paper has 247 blocks / 301 equations /
12 figures; the second has 250 blocks / 262 equations / 29 figures, with all eight inline legend symbols retained.
Regression checks pass: backend 499; browser 345; Core device-reader 5; iPad Simulator WebKit compiler 2;
six production-CSP browser journeys, with one authenticated WebKit skip for its existing key-persistence gate.
Hosted checks confirm both papers on the live site: the reported paper shows all 12 figures / 301 equations,
and the second shows all 29 figures / 262 equations, nine inline images (eight SVG markers and one bitmap), with
zero broken images. Selection actions pass and figure/caption/legend screenshots were visually inspected.
The initial combined check stopped at a test assertion expecting eight rather than nine inline images; the
corrected second-paper check passed. It fetched one HTML plus 60 image assets directly from arXiv, with zero
PDF/artifact requests, provider attempts, usage or charges; both disposable accounts were successfully deleted.
Evidence: `.artifacts/html-figures-hosted/` and `.artifacts/html-figures-second-hosted/`.
The inert XML parser emits CSP style warnings; a targeted pixel check confirms admitted SVG style colors survive
rasterization under the unchanged restrictive policy (red test pixel `[255,0,0,255]`). No script/network policy
was relaxed, and there were no page exceptions. Other regression evidence is in `.artifacts/html-figures-*`.

Native **build 30 is VALID and IN_BETA_TESTING for iOS and Mac**, confirmed at 2026-10-14 02:29:46 UTC.
Build IDs: iOS `e9179467-4517-49ed-8109-09967b9b01b5`; Mac `578886dc-8bae-4164-ace1-ba298e485ab6`.
Backend services are unchanged. No PDF acquisition or provider call was made for these checks. Physical iPhone work remains paused.

## HTML-first/device-only PDF release — 2026-10-13

**Staging backend and browser are live.** New imports stop at metadata; exact official arXiv HTML is fetched and
compiled on the reader’s device. PDF choose/drop/Share/download paths stay on device. No server PDF upload,
acquisition, OCR or Mathpix fallback is admitted. Existing page/navigation/selection and paper/general chat remain.
A local model for difficult PDFs is future work. Historical server originals and conversions remain retained;
no legacy migration, rerender or bulk deletion occurred.

- Migration `202610130058` applied and its ledger hash verified. Uploads reject with HTTP 410 before reading PDF
  bodies; original/OCR/render admission and legacy processing-job claims are fenced. New encrypted source-bound
  events use envelope format 2 and `v3_pull_events`; older pull APIs require a reader update when they encounter it.
- Cloud Run `gradstep-pipeline-00033-2jw` has 100% traffic, metadata-only code and no Mathpix environment secrets.
  Edge `chat`, `paper-worker` and `upload-pdf` deployed. Cutover admission paused with zero pipeline claims,
  unresolved provider attempts/liability and unfinished asset writes, then resumed after verification.
- Browser `https://app.gradstep.ai`: Pages **`50ecbc01`**, following the functional release `a95696d2` and a help-copy
  correction. Admin `https://admin.gradstep.ai`: Pages **`91c1eb33`**, with accurate metadata/device-reader status.
- Native **build 29 is VALID and IN_BETA_TESTING on iOS and Mac**, confirmed by App Store Connect at
  2026-10-14 00:45:46 UTC. It includes the corrected “How Gradstep works” explanation. Build 28 is the earlier
  functional upload. iOS build ID `0824387c-2ee4-447b-ab1e-596c5f4e2dbd`; Mac build ID
  `79b14c95-fd18-40e3-b24e-b562895fc5fa`. This is an internal TestFlight release, not public App Store release.
  No physical iPhone was queried, installed, launched or tested.
- Scheduled workflow image `sha256:44332d6d02360b00ac5bc66ed6df382a85bbed9d73669b4773ed80384cb04e8e`
  removes the server PDF corpus. Its image-only refresh preserved IAM/configuration; schedules were paused for
  replacement then restored. Historical PDF journey checks explicitly skip. The admin Reliability tab contains
  the new upload-refusal, exact-version metadata, source archive/tag and replay checks.

Verification: backend 497 tests; Core 286 tests; native app 410 tests with
five optional skips and zero failures, followed by targeted iPad HTML/PDF/library checks; browser 343 unit tests
and four desktop/phone production-CSP journeys. The first live probe found `/oai` missing from the metadata
allowlist; the corrected worker and regression passed the final live run (4 checks including account cleanup).
Deployment tooling has 39 passing tests and the image-only refresh has 6 passing tests.

The hosted real-source check prepared **DPO v3** directly from arXiv: 261 MathML equations, eight source assets,
selection actions and local-context paper-chat admission. Reload and a second isolated browser recovered the
question from encrypted server history. Three HTML and 24 image requests, **zero PDF or server reader-artifact
requests**, zero provider attempts/usage/charges, zero credit holds, and successful account deletion were observed.
The database readback also recorded zero new PDF objects and Mathpix attempts since migration 058, with zero unfinished asset writes.
A zero-credit refusal tested live admission; it does not establish a new successful paid-answer configuration.
Auth used a real password session seeded for the disposable account; email/OAuth UI and physical-device approval
were not re-tested. Evidence: `.artifacts/html-hosted/hosted-browser-zero-credit-summary.json`.

Browser PDF bytes stay in the selected local file/tab; the encrypted membership survives reload, which asks for
that file again. Browser reader bundles retain the existing bounded RAM cache; durable browser offline bundles
are not claimed. Missing or unsupported official HTML remains a clear unavailable-reader result with local PDF
access. Native originals and prepared bundles use separate encrypted, backup-excluded stores.

Budget: October metered provider spend remains **$20.744201 / $25**, with **$0 reserved and $0 unresolved liability**
after verification; this rollout’s live checks spent $0. The total incremental budget stays $100/month. No new
subscription/service commitment was introduced. October overhead observations are missing for all eight ledger
components (Tavily, domains, Supabase, Cloud Run, storage/egress, builds/registry, backups and web hosting), so the
whole-month forecast is explicitly incomplete; those costs are unknown, not zero.

The full codebase (1,163 source files plus Git history, refreshed after the figure compatibility fix) is copied to
`192.168.1.32:/home/ben/science-reader-html-20261013`. Every source SHA-256 and `git fsck --full` verified;
credentials, dependencies and build artifacts are excluded. The earlier `/home/ben/science-reader` checkout is
preserved. The SSH machine runs no PDF-processing service.

## Historical release checkpoint — 2026-10-09

**Build 26 is VALID and available for internal iOS and Mac testing; build 27 is VALID for internal iOS and Mac testing; the integrated browser reader is deployed as Pages `8820991e`, and the admin site is deployed.**
This is a development/release checkpoint, not public-release acceptance. Earlier checkpoint prose (including
removed executor work) is retained below where useful and in git history.

## Purchase credit diagnostic — 2026-10-09 UTC

The owner’s current TestFlight purchase symptom is accounted for. Staging recorded the latest Sandbox pack and
subscription transactions, but the account had already consumed the deliberate October Sandbox allowance (400 +
400 + 200 = 1,000 credits), so those later records correctly granted zero. Migration `056` adds the read-only,
service-role `worker_store_zero_grant_reason` diagnostic; `store-sync` returns its finite code and the native purchase
sheet explains `sandbox_monthly_cap`. The migration is applied and verified on staging, and `store-sync` is deployed;
the RPC returns that code for the owner’s recorded zero-credit transaction. This preserves the spending guard and does
not change Production grants. Build 26 (iOS and Mac, uploaded 2026-10-09 and confirmed `VALID`) carries the native
copy and applies it to Restore Purchases when the receipt was already recorded by an earlier build. The owner-only,
audited 400-credit tester grant `cd4aac8a-3144-481f-abbe-b7844c0b7030` leaves the owner account at 490 available / 0
held for continued TestFlight work; it changes neither Apple's Sandbox allowance nor Production policy. The focused
Catalyst purchase suite passes 6/6.

## Current podcast and pipeline rollout — 2026-10-09 UTC

- **Podcast v2 is live on staging.** After encrypted backups
  `.artifacts/backups/20261009T141446Z-366edfad87a1` and `.artifacts/backups/20261009T143431Z-9646540fb7ee`
  (1,539 encrypted objects and verified database snapshots), migrations `051`–`055` were applied and verified.
  Migration 051 makes default-license arXiv papers source-only
  unless the exact source has a rights-verified reuse approval; CC0/CC BY shared processing remains available. The
  podcast profiles keep their stable IDs but now point to version 2: Short / 5 / 10 / 20 minutes have maximums
  140 / 150 / 300 / 530 credits. The 530 ceiling is deliberate: Vertex's serving limit is 16,384 audio tokens per
  call, so the six-call 20-minute profile must reserve six full grants. All four profiles are allowlisted atomically;
  private generation and catalog delivery remain bounded by the existing account, daily and $25 platform limits.
- **Worker rollout:** Cloud Run revision `gradstep-pipeline-00031-l5v` is active at 100% traffic with request-based
  billing, zero minimum instances, max three instances, one request per instance, pinned secrets and the bounded
  worker-thread lifecycle. The staging scheduler points at it; the legacy Edge `paper-worker` is retained only as an
  unscheduled rollback surface. Migration 054 changes the scheduler's pg_net timeout from the old 5-second Edge
  acknowledgement window to 600 seconds, below the worker's 840-second hard bound. Readiness, activation and aggregate
  liability evidence are under `.artifacts/rollout-evidence/`. Revision 00031 contains the v2 length/coherence and substantive-review repair
  hardening plus the raised explicit word-target prompt; each maintenance-to-active cutover preserved the reviewed
  configuration and immutable image digest.
- **Verification:** the full local database suite, podcast worker journey, 483 backend tests, web build/unit suite and
  universal Catalyst build pass. The staging deploy suite passed all feature and spending-safety checks with no
  provider spend before this revision. The active revision's health endpoint is healthy. The final focused check at
  15:21 UTC recorded **15/15 scheduler calls as HTTP 200, with zero timeouts, refusals, missing workers or server
  errors**, and zero provider cost. A fresh post-activation sample at **15:41 UTC recorded 16/16 HTTP 200 calls**, with
  zero timeouts, refusals, missing workers or server errors and zero provider cost. The earlier paused-gate `maintenance`
  503 is retained only as rollout history. Migration 054 gives the scheduler a 600-second acknowledgement timeout.
- **Published pilots:** “The Persona Hierarchy Model” (3:54) and “Decoupling Exploration from Optimization in RLVR”
  (3:22) are shared, chaptered and single-use delivered. The pilot's two successful speech calls cost $0.27 and $0.30;
  total seed spend is $1.94 of the authorized $5 period. Short, 10-minute and 20-minute private generation is now
  enabled with the revised ceilings. The current October curated-catalog period is configured by migration 055 at a
  `$3` hard allowance and `max_episodes=10`; admissions remain operator-selected and review-gated, so no catalog
  episode is generated automatically without an explicit seed operation.
- **Length and coherence hardening (live in revision 00031):** v2 worker jobs now enforce each profile's declared word shape and accept audio
  only inside a 0.8–1.25× target-duration window (v1 jobs retain their historical bounds). The checker remembers
  removed turns when deciding whether a question still has an answer, preventing an unrelated later turn from hiding a
  dangling prompt. The active worker revision was deployed through the paused-gate readiness procedure; this rollout
  spent no provider credits.
- **Podcast review repair hardening (live in revision 00031):** the review prompt now requires substantive,
  evidence-grounded replacements and an explicit post-correction word-count check. A short acknowledgment or generic
  filler cannot be used to get back over a profile's lower bound. The deployment's fresh scheduler check at 16:02 UTC
  recorded 15/15 HTTP 200 calls with zero provider cost.
- **Catalog quality gate exercise:** two post-rollout CC BY candidates were correctly stopped before speech because
  the checker found unsupported claims and/or a post-cleanup word-budget failure. Their script/review usage settled at
  `$0.472822`, no audio was generated, and neither release was published. The draft prompt now states an exact target
  (792 words for the 650–800-word five-minute profile) so later removals do not make an otherwise supported episode
  too short.
- **Overlong source UX:** `source_too_large` is now a first-class client outcome. Native and browser listeners say
  that the shared full-paper limit applies at every available length, confirm that no credits were charged, avoid a
  retry dead end, and offer a direct return to reading; native and the signed-in browser can also open the shared
  Listen catalog. Section-based episodes remain a future capability. The browser fix is live at `app.gradstep.ai`
  (Pages deployment `c1cf0744`); the native change is in iOS/Mac TestFlight build 27, now confirmed VALID by App Store
  Connect and ready for owner acceptance.

## Commercial arXiv content gate — 2026-10-09

The rights review is recorded in [ARXIV_CONTENT_HOSTING_20261009](research/ARXIV_CONTENT_HOSTING_20261009.md). The
current `owner_private` conversion path for default-license papers is not treated as launch-cleared: arXiv's API
terms restrict server storage and serving of e-prints unless the copyright holder or submitted license permits it.
Until arXiv's commercial/API response and counsel review are complete, only rights-verified server retention and
derived processing (currently CC0/CC BY) may be enabled; default or uncertain licenses fall back to metadata and
direct source links. No public paid launch promise should say that every arXiv paper syncs across devices.

The implementation checkpoint is migration `051` (`rights_aware_arxiv_delivery`), now applied and verified on staging.
It adds a durable `rights_mode` decision,
classifies pre-change private rows as `legacy_private` for audit, and makes the production default-license path
`source_only` before download admission. Native and browser labels now say “Available on arXiv” / “Open on arXiv” for
that path. Native now also has a migration-free, encrypted `DevicePaperStore`, a direct source-only download action,
and a local PDF viewer; the store is bounded, account-fenced, crash-safe and covered by Core tests. The staging rights
rollout is live. Approved-device transfer, reader-bundle installation,
offline structured reading remain gated as described in
[DEVICE_LOCAL_PAPERS](architecture/DEVICE_LOCAL_PAPERS.md).
Local Mathpix processing is no longer planned under the 2026-10-13 decision.

## Data and cost explainer — 2026-10-09 UTC

The native About screen (including Mac Catalyst) and the signed-in browser account menu now expose **How Gradstep
works**. It explains device-local versus synced paper paths, encrypted chat synchronization, the plaintext boundary
when a user requests Mathpix or cloud AI work, provider handling limits, credits/holds/settlement, token-based cost,
shared OCR and podcast reuse, model profiles, and account/platform spend gates. DeepSeek is documented as a research
candidate only; no traffic or routing policy changed. The browser build and 1440px desktop light/dark workflow pass;
the Catalyst app builds successfully. See [DATA_HANDLING_AND_COSTS](architecture/DATA_HANDLING_AND_COSTS.md).

## Cost UX and owner test balance — 2026-10-09 UTC

Migration `057` (`podcast_price_ux`) is applied and verified on staging after encrypted backup
`.artifacts/backups/20261009T194433Z-3ae85413991f` (1,539 objects, encrypted). It changes quote copy only: the five-minute
v2 option now says that recent beta examples used about 55–60 credits and keeps the 150-credit maximum visible;
profile ceilings, holds, settlement, prices and provider routing are unchanged. The browser and native credits surfaces
now show a compact capacity guide and explain actual-versus-maximum usage. The full local database suite, 342 browser
tests/build, and Catalyst build pass. The business proposal is
[BUSINESS_MODEL_AND_COST_GUARDRAILS_20261009](reviews/BUSINESS_MODEL_AND_COST_GUARDRAILS_20261009.md).

For continued TestFlight testing, the staging owner account has an explicit audited 100,000-credit nonexpiring test
grant (external key `owner-testing-20261009`), leaving 100,490 credits available at the time of the grant. This is
not a production billing bypass: provider budgets, rate limits, storage limits and unresolved-liability controls still
apply. The normal Apple purchase path remains separately diagnosed; the grant removes the Sandbox allowance from the
owner's critical testing loop without changing Production grants.

## On-device paper processing research — 2026-10-09 UTC

Historical research checkpoint, superseded in direction on 2026-10-13: the note compares PDFKit/Vision, Tesseract,
pix2tex, Surya, Nougat, PaddleOCR and the DeepSeek-OCR family for a layered local path. No model is bundled or
enabled from this research. The proposed order is PDF text extraction, on-device general OCR, then a licensed,
quality-gated equation model; the former Mathpix fallback is no longer permitted. Initial structured reading now
targets arXiv HTML. See [ON_DEVICE_PAPER_PROCESSING_20261009](research/ON_DEVICE_PAPER_PROCESSING_20261009.md).

## Current web/Mac candidate — 2026-10-09 UTC

- **Browser release:** source is commit `7dcbf5e` on main; Pages deployment `64d5e280` is live at
  [app.gradstep.ai](https://app.gradstep.ai). The deployment script's build/output gates passed, and the custom
  domain served the new asset after the edge refreshed. Anonymous HTTPS checks returned 200 with the expected CSP,
  HSTS, no-transform cache policy and same-origin isolation. No account, provider, OCR or paid request was made by
  these checks.
- **Browser verification:** 342 unit tests across 30 files pass; the integrated production-CSP Playwright run is
  **156 passed / 108 expected skips / 0 failures** across desktop, phone and WebKit. The WebKit screenshot-report
  journey is explicitly gated on the same durable X25519-key capability as the other authenticated browser journeys;
  WebKit's current refusal is reported as an expected skip rather than a false failure. The skips are not Safari
  support evidence. The web app now follows the native Feed, library actions/columns, encrypted draft and
  interrupted-answer journal, reader passage/reference actions, chat profiles/titles, podcast workspace/player,
  and the authenticated foreground PDF-upload path. The deployed reader also exposes the Library's epoch-checked
  paper menu (tag editing, archive/unarchive and remove) from the paper toolbar, plus the browser screenshot
  support-report flow. Background/offline upload and Safari key persistence remain separate gates.
  The browser key-activation screen now keeps its security explanation behind a compact disclosure; the primary copy is
  “Save unfinished chats” with “Save drafts” / “Skip for now”. Signed-in users can now choose Account → Report this screen… to attach a PNG/JPEG or capture an explicitly selected
  browser tab/window, then follow the thread under My reports. Images are redrawn without metadata and bounded to
  2,560 px/5 MiB. If the web connection fails, the composer stays open for retry; unsent web drafts are not persisted
  offline. Mac already has the native Help → Report This Screen… command and encrypted offline outbox.
- **Gate-2 foundation:** the local main tree now has an explicit schema-3 activation (`activateLibraryStorage`),
  three separate encrypted-domain stores, bounded key inventory, and device-fenced multi-head compare-and-swap in
  `libraryAccess`. The new `library-storage.ts` codec seals a complete v5 presentation checkpoint (authenticated
  head, per-row ciphertext, exact digests/counts and bounded capacity) and rejects missing, substituted or orphaned
  records. It is covered by the library-storage and checkpoint suites and is not enabled by the deployed browser UI.
  Descriptor writes, complete v5 library adoption, saved copies and cold startup remain gated pending the epoch-bound
  descriptor PUT contract and measured copy-install limits.
- **Still gated:** durable library/saved-reader-copy customer behavior (Gate 2), cold offline startup (Gate 3), live browser
  provider consent/identity acceptance, Safari key persistence, background/offline browser PDF upload and purchases. The
  browser now supports a foreground, authenticated PDF upload from the Add sheet: it validates `%PDF-`, hashes the exact
  4 MiB parts, writes the encrypted title descriptor, refreshes the session revision and finalizes against the current
  library cursor. The selected File and upload session stay in memory while the tab remains open; reload/background
  resumability remains deliberately gated until Gate 2 storage is wired. The native PDF upload
  queue now matches the deployed authenticated chunk protocol and writes the required encrypted descriptor, covered by
  7 focused simulator tests; **TestFlight build 25** carries this fix and still needs real-device acceptance. The browser now has bounded
  Google/Apple PKCE controls and callback validation; provider-side acceptance remains a release gate. Podcast generation remains backend-dark and no
  paid podcast or ranking request was made. The web client displays capability-unavailable states until those server
  contracts are live.
- **Mac:** the merged-main universal Catalyst build is signed for development on arm64 and x86_64. The full native
  unit suite passes **385 tests, 4 expected skips, 0 failures** on the current main checkout; the Settings toolbar regression is fixed
  in `beff20c`. Mac QR approval is now connected to `RecoveryView` and the shared `DeviceKeys` enrollment path, and
  the signed focused enrollment/QR suites pass **10/10**. Mac menu, drag/drop, QR camera and keyboard UI runtime
  checks remain open because XCTest automation still needs the local Accessibility/Screen Recording permissions.
  **TestFlight build 25 is now uploaded and VALID / IN_BETA_TESTING for both iOS and Mac** (App Store Connect build
  `3a42b560-396d-46d7-8f3c-f544487a2244`; iOS and Mac share this build record).
  No owner-device acceptance is claimed by this candidate.
  The current main source also contains the Mac-specific purchase-settings copy (`fe0dd2b`); a fresh universal
  Catalyst build-for-testing and focused Mac execution passed **11/11** (approval and StoreKit purchase suites).

## Current rollout — 2026-10-08 UTC

- **Historical podcast v1 design note:** the initial branch `podcast-v1` was later applied and superseded by the v2 rollout
  above. Owner asked to "build the
  notebook LM podcasts feature"; Decisions 2 (≤ $2, ≤ 2 seed episodes, $0.75 each, inside the $25 cap) and 3
  (bounded private generation) recorded in [DECISIONS](DECISIONS.md#paper-podcasts-v1-owner-asked-2026-10-08).
  Migration 048 (every switch off), worker `POST /podcast` (Sonnet 5.5 two-pass script + deterministic evidence
  checker, Gemini 3.8 Flash TTS on Vertex via an impersonated dedicated service account, ffmpeg mono AAC 64 kbit/s with
  chapters), Edge `podcast`/`podcast-member`, native client and a first browser client. **Four lengths** (owner): Short / 5 / 10 / 20 min at 110 / 150 / 220 / 360 credits maximum, ten and twenty minutes
  staged with chunked speech; seeds stay five-minute. Local tests only; **no paid
  provider call**. The lead's $2 seed-pilot runbook: [Paper podcasts](architecture/PAPER_PODCASTS.md#seed-pilot-runbook-2-the-lead-runs-this).

- **iOS and Mac TestFlight build 22**, source `298e66b`, are now **VALID / IN_BETA_TESTING**. The iOS upload
  completed at 16:41 PDT and the Mac upload at 16:46 PDT; both are internal-only builds and are available to
  the existing internal testing group. Build 22 includes the current Mac wide-workspace direction, the
  Catalyst purchase-settings wording, QR device approval, and the accumulated library/chat/reader fixes.
  Archive/export evidence is `.artifacts/Paperstep-22.xcarchive`, `.artifacts/export-22.log`,
  `.artifacts/Gradstep-mac-22.xcarchive` and `.artifacts/export-mac-22.log`. No physical-device or owner
  acceptance claim is made here.

- **Reader cutover completed at 09:33 UTC.** Migration 045 fences the old issuer; delivery is bounded-only.
  After the full in-flight/expiry horizon, all 1,046 historical/physical reader paths were cache-purged, including
  five absent historical paths. Both formerly cached token variants then returned explicit expiry denial; a
  fresh nine-member bundle passed exact size/hash/header checks. Replay, wrong-account, range and simultaneous
  double redemption also passed. Quotas, charged counters, inventory enforcement and stored objects are preserved.
  All nine diagnostic accounts are deleted with zero residual Auth/sync/import/provider/credit/operation rows.
  No AI/OCR cost.
  The proof relies on Supabase's global purge contract plus two locally observed variants, not every CDN edge;
  Mathpix originals and infrastructure invoices remain separate. [Cutover evidence](reviews/READER_CDN_CUTOVER_20261008.md).
- **Scheduled checks image updated at 09:21 UTC**, immutable digest `f02d8422…aeeb`, source `40cb237`.
  Image-only guarded readback preserves runtime, secrets, IAM, alert settings and all three existing schedules.
  The packaged reader verifier now authenticates bounded downloads. No manual job or notification was sent;
  the next scheduled run and actual inbox delivery remain unverified. [Workflow checks](architecture/WORKFLOW_CHECKS.md).
- **Next browser durability milestone reviewed, design only:** compatibility/update handling first, then an
  encrypted draft/history journal, saved papers with complete v5 read/write parity, and cold offline startup.
  Multi-tab retirement, key rotation, failed saves and legacy-tab activation barriers have independent review.
  Current browser drafts remain tab-memory only. [Implementation gates](architecture/BROWSER_OFFLINE_STORAGE.md).
- **iOS and Mac TestFlight build 21**, source `c10e54c`, both **VALID / IN_BETA_TESTING** at 08:49 UTC.
  iOS `26f12155-c57b-4bb4-9102-059134323c56`, Mac `71c46182-fbcc-4b2e-afa7-9223433576f8`;
  `.artifacts/takeover-20261008/build-21-processing.json`. Includes all build 20 fixes plus actionable reader
  quota, interrupted-download and update-required errors. The error body has its own 4 KiB bound even when
  the requested asset is smaller. All 35 focused native tests pass; signed iOS and universal Catalyst archives
  uploaded successfully. No physical-device or owner acceptance claim.
- **Spending evidence API deployed**, `admin-spending` v1 from reviewed `31bcf1b`; all six deployed modules
  match source. Anonymous callers receive 401 and customers 403; a hosted lookup verifies no observation was
  recorded, zero-credit balances stayed unchanged and the disposable account was deleted. No provider cost
  or holds. The owner/MFA form passed local desktop/phone/dark, lost-response/reload, invoice-versus-allocation
  and SQL checks. No invoice was entered and no real owner/MFA journey is claimed. `admin-spending-source-proof.json` and
  `admin-spending-postdeploy-verified.log` contain the redacted deployment evidence.
- **Admin hosting is live at https://admin.gradstep.ai**, Pages **349d3859**, dedicated `gradstep-admin`
  direct-upload project with a custom domain and proxied CNAME, free static hosting and no Functions.
  At 08:31 UTC the hosted sign-in smoke passed HTTPS 200, strict CSP/HSTS/no-transform, desktop/phone-dark
  layout, no browser errors or unexpected requests, and exact-origin CORS for `admin-spending`,
  `admin-accounts` and `support-assets`. An audited bootstrap granted the existing verified account the owner
  role without changing its password or MFA factors. **Real owner password/TOTP sign-in and hosted owner actions
  remain untested**; ordinary MFA is required and no invoice evidence has been entered.
  Evidence: `admin-live-smoke.json`, `admin-hosting-provision.json`, `admin-owner-bootstrap.json` under
  `.artifacts/takeover-20261008/`. [Admin hosting](architecture/ADMIN_HOSTING.md).
- **Interrupted-worktree audit completed:** ten apparently unmerged commits on the library-descriptor,
  upload-visibility and purchase-runtime branches are patch-equivalent to main. The 23 remaining source files
  in the two dormant runtime worktrees are byte-identical to merged `a2b4a38`; later main changes explain
  their differences. No abandoned implementation was found. Worktrees and artifacts were preserved.
- **Subscription credit retention 044 is live on staging** (07:42 UTC, reviewed source `1a10051`). Upgrades
  retain each period's credits until its original expiry; malformed copied receipts cannot create perpetual
  subscription credits or fill identity after refusal. Full database/lifecycle/concurrency and independent
  review pass. Both verifier channels were CAS-paused, with complete session visibility and a satisfied
  ten-minute admission quiet window. Encrypted backup `20261008T073303Z-950e99dcb0da` contains 1,346 verified
  objects and a 2,698,364-byte database dump. Ledger and all three exact function bodies/permissions read back;
  purchase records, grant terms, products, allowances and provider limit are unchanged. Both channels restored
  enabled at revision 4. Hosted checks: **4 pass / 0 fail / 1 warning** (7 imports waiting for credits), no paid
  provider cost or reservation, test account deleted. Evidence: `subscription-rollout-state.json`,
  `subscription-postdeploy.log`, `.artifacts/workflow-checks/2026-10-08T07-43-26-051Z.json`.
- **iOS and Mac TestFlight build 20**, source `bd2e0f2`, uploaded October 7 at 23:43 PDT. Apple confirms both
  **VALID / IN_BETA_TESTING**: iOS `74725990-aedc-4ac3-b609-347cb4d2a0e6`, Mac
  `cea77106-c5e9-45f4-9245-3759a0816f5e`; `.artifacts/takeover-20261008/build-20-processing.json`.
  Includes all of 19 plus full expanded Feed titles/abstracts in table and list layouts, explicit Library links
  in chat that preserve drafts/history, and reference actions without repeating bibliography text. Focused
  validation: Core 248 Swift Testing + 6 XCTest, 68 native cases, five UI journeys, light/dark and accessibility-XL
  coverage, and universal Catalyst build. No new iPad UI or physical-device claim; screenshots in `native-build20/`.
- **Full abstracts are live in discover v78**, opt-in `abstract=full`; existing preview clients keep the old
  response. All 11 deployed modules match reviewed source `35209d4`. Three real zero-credit requests verified
  legacy compatibility, exact complete arXiv abstract (1,604 characters), and a bounded 25-paper Feed. Zero
  provider usage or holds and complete disposable-account deletion: `discover-full-hosted-smoke.json`.
- **Browser column/full-abstract follow-up deployed**, Pages `67f5547c` from `0fb60c7`. Library columns are
  optional and persistent; Title stays pinned during horizontal scrolling. Expanded Feed cards show full titles
  and abstracts. Six Library workflows include 4,000-entry desktop/390 px libraries; four combined column/Feed
  workflows pass. Production build and live HTTP/CSP/HSTS/no-console-error check pass (`web-columns-live-smoke.json`).
  Earlier browser chat and hosted encrypted-history evidence below remain applicable, with their stated limits.
- **Real hosted chat/diagram proof:** a disposable account received a general-chat answer in 4.9 s, drew its
  five-node Mermaid diagram in an isolated frame, and recovered both after reload. The successful request used
  2 credits / $0.006266 provider cost / zero outstanding holds. Including harness retries: two paid answers,
  $0.012572 total, all three test accounts deleted (`hosted-browser-diagram-total-cost.json`). Auth UI was seeded;
  email/OAuth UI, Safari and physical camera remain unverified. Visual review prompted a whole-graph Fit view
  with bounded zoom; six local production-CSP diagram journeys pass, with four intentional phone skips.
  That follow-up is **live as Pages `e15a5614` / `0db9809`**; production build and matching-asset HTTP/CSP/HSTS/
  no-console-error smoke pass (`web-diagram-live-smoke.json`). No additional provider call was needed.
- **iOS and Mac TestFlight build 19**, source `b4b7ad7`, uploaded October 7 at 22:56 PDT. App Store Connect
  confirms both **VALID / IN_BETA_TESTING**: iOS `6bda87b4-c0b8-45e4-a760-a6328beb979d`,
  Mac `d6bf3f5e-8d8f-4936-a0fa-039d2369651b`. Evidence:
  `.artifacts/takeover-20261008/build-19-processing.json`. This does not mean the owner installed or tested build 19.
- **Native changes in 19:** epoch-checked Add/Retry/tags/archive/remove; configurable horizontally scrolling tables
  with pinned columns; newest-first discovery; native paper/equation selection menus; clearer chat links;
  Feed/reader text-size controls; stable background-update layout; automatic-retry status and improved dark Feed
  Add contrast. Purchase copy reports actual granted credits, including Sandbox allowance outcomes.
  Native candidate `650d1dc`: Core 248, app 379 (5 skips), Catalyst 351 (4 skips), 27 focused UI journeys and
  iPhone/iPad Feed Add journeys pass. Physical-phone work remains paused.
- **Browser milestone 2 is live at https://app.gradstep.ai**, Pages `68faefdb` from `b4b7ad7`: encrypted
  paper/general chat and history, streaming/Stop, selection/passage tools, Markdown/math and isolated Mermaid.
  Local evidence: 189 unit/Swift-interop checks; production build; combined shared-bridge journeys: 9 pass / 7
  intentional phone skips; earlier StrictMode 3 and WebKit refusal 1 pass. Hosted smoke confirms HTTP 200,
  CSP/HSTS and no browser errors (`.artifacts/takeover-20261008/web-live-smoke.json`). A separate hosted Chromium
  journey passed real key bootstrap, cached DPO Add/read (4.9 s, 271 MathML nodes), passage selection, encrypted
  question acknowledgement before insufficient-credit refusal, reload and second-browser recovery/history.
  Server accounting confirms zero provider attempts/usage/cost/holds; account deletion completed 200. Evidence:
  `.artifacts/takeover-20261008/hosted-browser-zero-credit-summary.json`. Its real Auth session was seeded via
  synthetic-account password login; email/OAuth UI was not tested, and this earlier journey made no paid request. Safari's secure-key
  persistence gate and tab-memory drafts/outbox remain. [Browser contract](architecture/BROWSER_READER.md).
- **Staging schema through 045 is applied.** 043 was applied disabled as a prerequisite to 044; see below.
  Before the earlier 042, encrypted checkpoint
  `20261008T051522Z-5ffa9efe26a9` captured the database and 1,332 objects; migration hash, grants and search paths
  were read back. Targeted hosted v5 Add/archive/unarchive/tags/remove/re-add, exact replay, deltas and
  stale-epoch refusal pass with a zero-credit synthetic account, then cleanup: **2 pass, 0 fail, $0 spent/reserved**
  (`.artifacts/workflow-checks/2026-10-08T05-42-22-627Z.json`). Build 18's disabled-v5-write regression is addressed
  by the build 19 client plus 042; the ordinary hosted command test does not invoke OCR or chat.
- **Spending controls 034–038 and uploads 039 are deployed.** Provider attempt coverage starts
  2026-10-08 02:40:51.785121 UTC; asset enforcement is on with complete scope-2 inventory and zero discrepancies.
  Reader delivery is now **bounded-only**, with scoped cached legacy URL retirement proved at 09:33 UTC.
  The 09:08 UTC provider snapshot is **$14.017212 spent / $0 reserved / $25 limit**, with no unresolved attempts;
  it is not an invoice or total infrastructure cost.
  [Spending evidence and limits](architecture/SPENDING_CONTROLS.md).
- **Purchases:** three observed real Sandbox packs granted 400 + 400 + 200 = 1,000, with replays recorded separately.
  Production subscriptions/renewals/refunds remain unverified. 044 fixes the prior-period-credit policy discrepancy;
  exact purchase recording and actual credits granted remain distinct.
- **Personalized Feed 043:** **applied with serving off and refresh disabled**, pool and feedback empty, no sources.
  The scheduled gate exists but returns before network/profile work. Hosted readback: `feed-dark-deployment.json`.
  The owner accepted For you as the default and server-visible library metadata for ranking (2026-10-08, build 21
  feedback). **046 (specific topic chips, Topics per paper, Hugging Face popularity) is built and tested locally, not
  applied**; the matching `discover`/`feed-refresh` and the iPhone/iPad Feed (For you default, topic chips, More
  topics, why line, Topics and Popularity columns) are local only. No Feed refresh function or personalized UI was
  deployed, and no paid ranking is enabled. [Enable steps](architecture/PERSONALIZED_FEED.md#enable-046-on-staging-lead).
- **Historical pricing note:** the initial `$2` pilot proposal is superseded. The active podcast economics are the
  reviewed `$3` October curated allowance (maximum 10 operator-selected, review-gated episodes) inside the existing
  `$25` provider budget; private generation remains bounded by account and profile caps. [Economics](research/PRICING_RECOMMENDATION_20261008.md),
  [podcast proposal](architecture/PAPER_PODCASTS.md).

## Podcasts: first two episodes published — 2026-10-09 UTC

- **Fix 3** (checker v4: review reason codes, repair before rejecting):
  - Applied migration `202610080051_podcast_seed_cap.sql` (seed cap $5, owner-approved) from a podcast-only branch,
    so Codex's unapplied `202610090051_rights_aware_arxiv_delivery.sql` and its pipeline change stay with Codex.
  - Backup `20261009T050530Z-9acee00abba2` was taken first and exited 0.
  - Worker `gradstep-pipeline-00016-2j2`.
- **Fix 4** (worker `gradstep-pipeline-00017-bxw`, also from the podcast-only branch):
  - Seeds passed every script check, then got HTTP 400 from Vertex.
  - Probes (under $0.001) showed `gemini-3.8-flash-tts` rejects any `maxOutputTokens`. The request no longer sends
    it, and the grant is kept beside the request.
  - With no cap, a call is bounded only by the 16,384-token serving limit. A chunk granted less is now refused before
    anything is bought (`speech_grant_below_serving_limit`).
  - Five minutes (one call, 16,384) is unaffected. **Short, 10 and 20 minutes need revised profiles (new versions,
    a migration) before they can be enabled.**
- **Published:** "The Persona Hierarchy Model" (3 min 54 s, 23 turns, 5 chapters) and "Decoupling Exploration from
  Optimization in RLVR" (3 min 22 s).
  - The lead read both transcripts: grounded, evidence-linked numbers. The RLVR episode has one abrupt spot: an
    unanswered "Give me a concrete number" where the checker removed the reply.
  - `podcast.catalog` passes against a real episode (2,074,026 audio bytes verified).
  - Pilot spend: $1.94 of $5 (two episodes, $0.27 and $0.30; the rest went to the failed attempts).
- **Private generation now allowlists all four v2 profiles** (`podcast-short-v1:2`, `podcast-5min-v1:2`,
  `podcast-10min-v1:2`, `podcast-20min-v1:2`); the policy status was read back from staging after the rollout.
- **TestFlight build 24** is VALID (iOS and Mac).

## Podcasts on staging and the first seed attempt — 2026-10-09 UTC

- **Deployed, switched off by default:**
  - Migration 048 (encrypted backup `20261009T012613Z-ab58c8ef35d2` taken first).
  - The `podcast` and `podcast-member` functions, and the `podcast-assets` bucket.
  - Worker `gradstep-pipeline-00013-mh2`, with checks 17/17.
  - The speech service account `gradstep-podcast-speech` (custom role: `aiplatform.endpoints.predict` only; the
    pipeline account can mint its tokens), configured in `infra/staging.json`.
  - The local amd64 image build now needs Docker's buildx plugin (installed via Homebrew).
- **Inventory:** scope 3 certified (uploads paused briefly) with zero discrepancies.
- **Zero-spend rehearsal passed.** A labeled fixture episode went through the real worker, database and storage. The
  new `podcast.catalog` workflow check verified the catalog listing, transcript (6 segments) and chapters (3), and an
  exact-bytes audio download (223,621 bytes); reusing the download grant was refused (409). The fixture was then
  withdrawn and fixtures switched off.
- **Seed pilot, first attempt: both 5-minute jobs failed with `script_incomplete`.** Each review pass stopped at its
  4,000-token output cap; the drafts were 4,497–4,785 tokens. No speech call was made.
  - Spend: $0.44 of the $2 seed allowance. Those two failures used up the period's two-episode count.
  - Fix in progress: the review pass returns corrections instead of a full rewrite (worker only), and migration 049
    counts only in-flight and published seed episodes. The $2 dollar cap still binds.
  - Policy now: catalog and delivery on, seeding on, generation off.
- **Second attempt (worker `gradstep-pipeline-00014-92c`, checker v2, migration 049):**
  - Migration 049 was applied *before* its backup succeeded. The backup had failed on podcast objects, and a piped
    command hid the failure; `backup.py` now includes `paper-uploads` and `podcast-assets`. The first good checkpoint
    after 049 is `20261009T023219Z-4bb34a6e49a6`.
  - Both seeds passed draft and review, then failed `script_evidence_rejected` (~$0.19 each). Pilot spend is now
    $0.82 of $2.
  - Diagnosed without paying, from the worker's own logs: the evidence quotes matched. Both drafts failed the
    spoken-number rule (`unsupported_number:s9`; `number_not_in_evidence:s13`, first of 3).
  - Fix ready on a branch, not yet applied or deployed: checker v3 and migration 050
    ([Seed pilot fix 2](architecture/PAPER_PODCASTS.md#seed-pilot-fix-2-checker-v3-and-checker-reports-2026-10-08)).
    It matches quotes in one shared normal form and stores the paper's own span, drops individual bad items and
    removes unsupported claims within 30% limits, sizes five-minute speech to fit, and records a text-free checker
    report with each job. Re-admit the seeds one at a time: $0.82 committed leaves room for one $0.75 hold.
- **Third attempt** (migration 050 applied after a successful backup, `20261009T032625Z-6a31787ca23b`; worker
  `gradstep-pipeline-00015-f9q`, checker v3):
  - The checker verified all 11 evidence quotes and would have kept 20 of 22 turns.
  - The review model nonetheless returned "reject" with no corrections, which failed the job (~$0.18).
  - Pilot spend: $1.00 of $2. The owner then raised the pilot cap to **$5 total** (2026-10-08, "Raise to $5 total"),
    still ≤ $0.75 per admission and ≤ 2 published episodes, inside the $25 provider cap.
  - Fix ready on a branch, not yet applied or deployed: checker v4 and migration 051
    ([Seed pilot fix 3](architecture/PAPER_PODCASTS.md#seed-pilot-fix-3-review-reasons-checker-v4-and-the-5-cap-2026-10-08)).
    The review gives reason codes with segment ids and repairs before rejecting; a reject naming only unsupported
    claims, wrong numbers or speculation becomes removal of those turns within the 30% limits; other rejects stand
    and record why. 051 raises the database bound to $5. Deploy: backup, apply 051, redeploy the worker, raise the
    period with `podcast-ops.py seed-period --limit-usd 5`, then retry both seeds (they fit together).
- **TestFlight build 24** (iOS and Mac, main `3cd874f`): build 23 plus the podcast client (Listen filter, player,
  lengths) and the floating-tab-bar fix (find-in-paper bar, regression tests). Upload succeeded; processing pending.

## TestFlight build 23 and For you serving — 2026-10-09 UTC

- **TestFlight build 23** (iOS and Mac), from main `9ca3202`: build 22 plus the chat model/effort/length control and
  generated chat titles. Both uploads succeeded; Apple processing is pending. Podcasts and the floating-tab-bar fix
  come in a later build.
- **Feed serving set to `staff`.** Builds 22+ show For you, specific topic chips, Topics and Popularity to owner and
  tester accounts. Pool: 825 papers (2026-10-08), 29 with upvotes.

## Chat controls and titles on staging — 2026-10-09 UTC

- **Backup:** encrypted checkpoint `.artifacts/backups/20261009T001040Z-c2602a33734d`.
- **Migration 047** (`chat_profiles`) applied and verified, then the `chat` function deployed.
  Workflow checks: 18/18 pass, $0.007.
- **Paid profile check** (`chat.profiles`, `chat.profiles-max`, cap $0.75): 3/3 pass, $0.14 measured.

  | Profile | Credits | Cost |
  |---|---|---|
  | Haiku · Low · Brief | 1 | $0.0020 |
  | Sonnet · Low · Brief | 9 | $0.0401 |
  | Opus · Low · Brief | 17 | $0.0809 |
  | Sonnet follow-up | 1 | $0.0033 (read 15,112 cached tokens) |
  | Opus · High · Detailed | 3 | $0.0126 (first text 3.2 s) |

  Quotes agreed with the provider attempts. Generated titles arrived ("Attention mechanisms in Mistral 7B").
- **Local tests:** backend 430/430, database 229 PASS, wire check, Core 258, iOS unit tests 402 (5 skipped), chat
  UI journeys 10/10 on iPhone and 4/4 on iPad, Catalyst build.
- **Not yet done:** Haiku 5.5 has not been quality-checked on facts and equations. The app side ships in the next build.

## Feed topics and popularity on staging — 2026-10-08

- **Encrypted backup:** checkpoint `.artifacts/backups/20261008T184847Z-234de2ccffd2` (1,405 objects).
- **Migration 046** (`feed_topics_popularity`, renumbered from 048) applied and verified, then `discover` and
  `feed-refresh` deployed.
- **Workflow checks:** 16/16 pass, $0 provider cost.
- **Live policy:** pool refresh is on (every 120 min via the existing 30-min cron) and Hugging Face popularity is on.
  **Serving is off.** For you and topic chips reach readers only after `worker_set_feed_policy('staff', true)`, which
  waits for an iOS build containing the app change. First refresh 19:30 UTC: 825 pool papers, 27 with Hugging Face upvotes, no failures.
- **Local tests before deploy:** backend 413/413, database suite 226 PASS, Simulator build OK.

## Ownership split and browser durability handover — 2026-10-08

- **Ownership:** at the owner's direction, Codex owns the web app (`apps/web`) and Mac-specific work. Claude owns
  iPhone/iPad, the backend and the shared native views. Server contracts for the web versions of today's features
  are documented in CHAT.md, PAPER_PODCASTS.md, PERSONALIZED_FEED.md and READER_RENDERER.md as each feature merges.
- **Browser durability, compatibility-only checkpoint:** merged to main (`76ad197`, status note `1779caa`); not
  deployed. When Gradstep updates in another tab, this tab finishes the writes it started, stops active answers
  (saving the partial text as interrupted), keeps unsent text visible to copy and explains what to close or reload.
  IndexedDB stays at version 1; there is no service worker.
  - Tests: web 199/199 unit tests; three two-tab Playwright journeys; build passes.
  - **Nothing new survives a reload yet.**
- **Gate 1 draft:** on branch `wip/browser-journal-gate1` (`5f47f5e`, `7fd85c8`). It is not wired into the app and
  has no tests of its own. It is for Codex to review or discard, not gate-1 evidence.
- **Pitfall:** the Playwright ports 54329 and 4317 are hard-coded, so parallel worktree runs collide.

## Codex worktrees retired — 2026-10-08

The owner confirmed Codex had stopped. All 14 `codex/*` branches were checked against main:
- Every commit is in main, either merged or as an identical copy (`git cherry` reports all `-`).
- The only uncommitted work was in `store-runtime` and `store-runtime-ops`, from 2026-10-07 18:23–18:39. It was the
  purchase-verifier transport, the health check and deploy tooling. Main has every file, identical or later-fixed
  (the remaining Codex-only lines are earlier versions of lines main has since corrected).

Before removal, the branches were saved as a git bundle and the uncommitted edits and untracked files as patches and
tarballs, in `.artifacts/codex-archive-20261008/` (not in git). All Codex worktrees and branches are removed.
`/Users/benbowlwes/science-reader-review-2026-10-02` is an older review snapshot, not a worktree, and was left in
place.

## Earlier backend and build 18 rollout — retained evidence

- **Migration 040** (`credit_resume_and_source_waits`) applied to staging with the pipeline paused (migrate-supabase.py:
  earlier applied files verified, 040 applied and verified), then the pipeline re-enabled.
- **Pipeline worker** `gradstep-pipeline-00011-lmv` (normal deploy): its workflow checks passed 13/13 with one warning
  (7 imports waiting on credits). Within minutes the new sweep resumed one owner-account import (2508.02518, 13 pages)
  that had been waiting on credits since 2026-10-07 23:49.
- **Chat function** deployed. Its checks passed 15 of 16 (`chat.smoke` 2.6 s, `ingest.not-found`; $0.007 settled).
  `pipeline.stuck` failed on that same resumed import: it counts age from the original Add, and the import was then
  waiting out an OCR funding pause. Fixed by the self-healing work (041).
- **Migration 041** (self-healing imports) applied the same night, then worker `gradstep-pipeline-00012-9xj`
  (checks 13/13, one warning: 7 imports waiting on credits). The owner's stray import 2610.07426 ("Details
  unavailable") is now `done`.
- **QR device approval** shipped in build 18 and the browser reader (no migration): a browser shows a QR and a six-digit number,
  and the phone approves it under Settings › Account › Add a device. Tests: web 146/146; wire check passes, including
  Swift approving a Node key and refusing a substituted one; the iOS Simulator build succeeds. Ship order: iOS/Mac
  build 18 first, then the web reader. Not yet tried against staging or with a physical camera.
- **TestFlight build 18** (iOS and Mac, main `08381c7`): build 17 plus QR device approval. Both confirmed VALID by
  App Store Connect on takeover. The owner installed 18 and confirms Add remains disabled and tables inadequate.
  Build 18 contains neither fix; the client/table changes are in build 19 above.
- **Browser reader redesign, milestone 1**, live at https://app.gradstep.ai (Pages deployment `8820991e`, same
  commit). Layout: side panel, the paper or library in the centre, a chat panel, as in the legacy web app. Also: a
  full-width library table, a contents tree, find in paper, a figure gallery, the Feed, Add paper by DOI or link, and
  QR approval on the restore screen. Before deploying: web tests 152/152, Playwright 51 passed with 27 skipped. After
  deploying: the live page and gradstep.ai/app load the sign-in screen with no console errors. The chat panel
  was a placeholder in that deployment; milestone 2 is now deployed as recorded above.
- **Hosted OAuth callback repair (2026-10-09):** Google sign-in previously returned a valid Supabase code without
  the client-supplied `state` value, while the browser rejected the callback as expired. The client now carries its
  short-lived browser binding as `client_state` in the exact `redirect_to` URL, leaving Supabase's provider state
  under server control. The local Supabase-style fixture, desktop/phone Playwright journeys and callback rejection
  test cover the behavior; web unit tests (342) and build pass. The fix is deployed in Pages `8820991e` and the live
  asset contains the new callback path. **Apple web sign-in remains an account setup gate:** staging currently has
  native-only `com.sciencereader.ios` with no OAuth secret. It needs a separate Apple Services ID (for example
  `com.sciencereader.auth`) associated with the Science Reader App ID, `app.gradstep.ai` and Supabase's
  `/auth/v1/callback`, followed by a Science Reader client-secret JWT and Supabase configuration. A secret from
  TextBrain must not be reused.
- **Hosted OAuth fallback fix (2026-10-09):** staging Auth still had `site_url=http://localhost:3000` from local
  development. It is now `https://app.gradstep.ai`; the native callback and both hosted callback entries remain in the
  redirect allowlist. This prevents provider fallback/error redirects from returning a hosted user to localhost.
- **Browser paper-state boundary:** the browser currently reads verified artifacts delivered by the server. The planned
  rights-aware local-ingest gate will sync metadata, tags, reading state and encrypted chats while keeping
  default/uncertain-license PDFs and derived bundles in the device's encrypted browser partition. A new browser will
  show the paper and its state, then require source retrieval, preparation or approved-device transfer before reading;
  it must not imply that a device-local PDF is already cloud-available.
- **Branded OAuth hostname preparation:** the browser client now accepts a separate public `VITE_AUTH_URL` for the
  authorization and PKCE token exchange, and the generated CSP allows that origin alongside the data API. It defaults
  to the current backend, so this preparation has not changed today's deployment. Supabase's read-only custom-domain
  check returns `entitlement_required`; enabling `auth.gradstep.ai` requires the paid custom-domain add-on (about
  $10/month), DNS CNAME/TXT verification, and adding the branded callback to the Google and Apple provider consoles.
  The owner is deferring that recurring cost for now; `VITE_AUTH_URL` remains unset and the optional preparation is
  intentionally dormant.
- **Migration 042 (`library_v5_commands`) is now on staging**, merged in main `b993c23` after independent review.
  Encrypted checkpoint `20261008T051522Z-5ffa9efe26a9` includes the database and 1,332 objects. The migration
  ledger checksum and all six authenticated RPC grants/search paths were read back. Zero-provider-cost
  deployment checks: **10 pass, 0 fail, 1 warning** (7 imports waiting for credits), evidence
  `.artifacts/workflow-checks/2026-10-08T05-26-28-507Z.json`. Live paid import/chat journeys were not run.
  Client validation: Core 245 + 4 OAuth, native 373 (5 expected skips), all 39 SQL suites plus upgrade/concurrency,
  restore 20, iPhone/iPad Add → In library → Library journeys, and Catalyst build. Build 18 still disables
  library writes; build 19 carries the client fix. The later zero-cost hosted command proof and final native
  release checks are recorded above; owner installation is not claimed.

## Library foundation and independent reviews — 2026-10-07

The owner authorized additive database work on `codex/library-v4-foundation-20261007`. Migrations 031/032 separate
compact synchronization, account-authorized immutable metadata and bounded indexed library queries. Query
continuations restart after meaningful edits; progress updates preserve them. Old v2/v3 clients, command receipts,
grouped changes and current quotas remain unchanged. Migrations 031/032 were **applied and ledger-verified on staging at 15:37 PDT**, after an encrypted checkpoint. Deploy checks passed (13 passed, zero failed; one warning about earlier failed imports). Client adoption and larger quotas remain separate work.
Independent reviews cover upgrade compatibility, paging, isolation and concurrent deletion; the
[contract and validation evidence](architecture/LIBRARY_V4.md) records the exact scope. Synthetic 10k/50k read-model
benchmarks do not establish end-to-end product capacity.

The requested [credit, identity and cost audit](reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md) is complete, with
open findings and local reproductions. Priorities include live Cloud Run billing, Tavily admission coverage,
invisible provider retries, unresolved Mathpix liability, and storage/download accounting. Fixed-cost forecasts
were corrected. The audit itself deployed nothing; reviewed fixes 033–039 were subsequently deployed. Continuous
monitoring and invoice completeness do not follow from that rollout, and legacy delivery remains open. Heavy-user estimates separate
credits, provider expense, platform overhead and store commission. The $100 incremental beta budget is unchanged.

The [paper-podcast feasibility report](research/PAPER_PODCAST_FEASIBILITY_20261007.md) recommends a metered,
paper-only experiment after spending-control repairs. It compares two-speaker APIs, scientific fidelity, source
rights, private/shared reuse, latency and 5/10/20-minute costs. Research only: no audio generation or deployment.

## Historical native takeover checkpoint — 2026-10-07

Build **16 uploaded** at 16:13 PDT from main `1aeaea2`; Apple read-back confirms **VALID / IN_BETA_TESTING**. It includes the
floating chrome and feedback #4–#6, reviewed offline-save compatibility repair (`cf67138` → `274366b`) and
passage-linked conversations (`e0dc706` → `1aeaea2`). The fresh combined build passes 20 app regressions and three
complete iPhone Simulator passage/offline journeys. The offline candidate also passed 207 Core + 4 OAuth tests,
321 iPhone tests (5 skips), 298 Catalyst tests (4 skips) and a universal signed Mac build. No physical phone work.
Reader navigation is now merged (`b7a7c31` → `6bd877b`) for the next build: Find in paper, Contents hierarchy,
figure gallery and the resizable/hideable iPad/Mac chat column. Its independent review passed 68 app tests (2 skips),
11 iPhone and 5 iPad journeys, and a fresh universal Catalyst build. Main `bf01894` adds decoded thumbnail cache
accounting. Chat quality `80724a5` is reviewed and merged as `2b5d7d4`: narrow titles fit, paper-specific history is
available, equation prompts are clearer and diagram repairs require a complete validated response. Combined checks
pass 224 backend, 213 Core, 48 app regressions, eight iPhone journeys, iPad resize/rotation/relaunch and a universal
Catalyst build. The matching backend was subsequently deployed; build 17/18 and now19 supersede this checkpoint.
See the current section of the [handoff](HANDOFF_20261007.md) for the latest deployment boundaries.

**Purchase incident, updated at takeover:** the earlier `store-sync` v36 probe identified missing Edge certificate
operations; the private Node verifier and 033–038 were subsequently deployed. At 05:14 UTC on October 8,
read-only staging evidence confirms three Sandbox packs granted 400 + 400 + 200 credits, with exact replays
recorded separately. The last grant reached the Sandbox monthly allowance. No production purchase claim follows.
At that 05:14 UTC snapshot the applied ledger contained39 files through 041, all matching main's SHA-256 checksums;
042 was applied and verified afterward.
See [current purchase status](architecture/PURCHASES.md) and [original incident](reviews/PURCHASE_DIAGNOSTICS_HOTFIX_20261007.md).

## First browser/Mac release — historical evidence, 2026-10-07

- **Browser reader: https://app.gradstep.ai** (Cloudflare Pages `gradstep-app`, free tier, staging backend), deployed
  with the new `scripts/deploy-web.mjs` (public-value gates, strict CSP/HSTS). `gradstep.ai/app` redirects there.
  Edge functions' allowed origins include it (they had been reset to local origins by later deploys); staging Auth's
  redirect allowlist gained the reader URLs (appended). Live evidence: headers, sign-in page, and a synthetic invited
  account reaching the email-code step (deleted afterwards). Code verification, keys, library and reading on the hosted
  build are not yet run; Safari remains gated. See [deployment](architecture/BROWSER_READER.md#deployment--2026-10-07).
- **Mac TestFlight build 17** (main `937ef34`): uploaded, VALID, internal testing (group "Owner"). Not yet installed or
  signed in on a Mac. See [Mac TestFlight](architecture/MAC_APP.md#testflight--2026-10-07).

## Earlier Browser/Mac integration validation — local evidence

The owner authorized merging `codex/web-mac-integration-20261007` on 2026-10-07. Work was developed at
`/Users/benbowlwes/science-reader-web-mac`, recovering the browser and floating-control branches. Integration
includes `main` through `5f95c97`, preserving its newer chat-title fixes and TestFlight build 15 feedback records.
The combined source passes a fresh universal Mac Catalyst Debug test build using public local fixtures, plus
71 web unit/interop tests, the production build and 42 browser checks (15 known WebKit capability skips).
Signed-in Mac journeys and distribution remain unverified; merge validation does not deploy a build.
Mac sheet shortcuts now guard unsaved tags (including text still being typed) and busy report submission; Browse
offers Find in Paper on ⌘F. The app and test targets compile for arm64 and x86_64. The keyboard runtime attempt
started no assertions and was interrupted; developer-tool and Computer Use permissions still need resolution.
See the [Mac checkpoint](architecture/MAC_APP.md#validation-checkpoint--2026-10-07).

The owner selected **React + TypeScript + Vite for both browser reader and admin** after the
[framework evaluation](architecture/WEB_FRAMEWORK_EVALUATION.md). The 168-sample comparison supports windowing
and better data handling as the main large-library work; it does not establish 50,000-paper product capacity.

Browser work now retires keys, pending requests and reader caches with their login lifetime; protects newer logins
from delayed refresh/sign-out/verification; preserves request deadlines; stops disposed import polling; and prevents
late reading saves from recreating forgotten device data. Device records must survive an IndexedDB roundtrip and
remain usable before enrollment, including on retry/reload. Live tags now update through the reader bridge without
replacing the document or losing the selection, reading place or citation return. Local validation: production build,
**71 unit/interop tests**, **42 production-CSP browser checks** and **17 development Strict Mode journeys** pass.
Direct paper URLs now wait for encrypted reading activity to load before restoring the paper, and received scroll
reports no longer lose the last update to a second throttle. **Fifteen WebKit key-dependent journeys remain
capability skips**, with safe refusal tested: WebKit cannot currently read back the non-extractable X25519 keys in
this environment. Full Safari support requires further design/work; see
[browser evidence and release gate](architecture/BROWSER_READER.md#evidence).

The 4,000-entry browser fixture now verifies search, live tags, filters, sorting and reading while an import
progresses. Empty catch-up and progress ticks no longer rerender the entire library. In short local production
observations, progress-window script work fell from 825–1,097 ms to 9–18 ms; this still renders every row and does
not increase supported capacity. See [measurement scope](architecture/BROWSER_READER.md#library-update-isolation--2026-10-07).

Library commands now wait for a complete observation after their receipt, including the changed target, rather
than publishing a single returned entry. Add captures the displayed cursor. Failed reads retain pending state;
recovery completes the accepted form without a duplicate request, and stale actions show revision conflicts.
See [command publication](architecture/BROWSER_READER.md#command-acknowledgements-and-complete-library-views).

The [capacity plan](architecture/LIBRARY_CAPACITY.md) records the path to larger libraries: encrypted warm caches,
compact sync, consistent paged queries and reviewed record retirement. The first backend foundation is implemented
on staging in 031/032; client adoption, larger limits and record retirement remain separate acceptance gates.

Remaining larger-library work includes accessible windowing and client adoption of the reviewed compact/query
protocols. This earlier fixture checkpoint is separate from the later hosted release evidence above.

## Earlier hosted end-to-end evidence

**Add paper → paid conversion → offline reader → paid answer** is implemented and verified against
hosted staging (`coxhjvqpflgxkleydati`) with real arXiv, Mathpix and Anthropic calls:

| Step | Evidence |
|---|---|
| Add arXiv paper (existing Library + flow, `v2_begin_import`) | `scripts/smoke-pipeline.mjs` and the Simulator journey (`LiveJourneyTests`) |
| Metadata, license, PDF download, Storage, paid Mathpix OCR, MathML render | DPO (arXiv 2305.18290, CC BY) converted in 31 s; 27 pages settled 27 credits; bundle 765 KB, 9 members |
| Shared reuse | A second account adding DPO got the converted reader in <1 s with no charge and no second OCR |
| Private conversion (non-CC) | LoRA (2106.09685, arXiv license) split into a per-account private conversion and converted (26 pages) |
| Authorized download + verification | `reader-artifact` signed URLs; every member hash checked; installed through the encrypted offline store |
| In-app reading | Simulator: converted paper listed with real metadata, opened offline, title/authors/abstract and the real table of contents |
| Paid answer | `chat` streamed a correct, equation-citing answer about DPO (26 credits) and about LoRA |
| Full Simulator journey | `LiveJourneyTests` passed on iPhone and iPad Simulators: synthetic sign-in + recovery code, add, convert, download, read offline, consent, paid streamed answer with typeset math, terminate/relaunch, reader and saved answer intact |

Also added overnight: **arXiv search** in the Library's arXiv segment (originals ranked first, Add stays in
search), a **research Feed** of the newest papers in the library's own arXiv categories (derived on device),
**native math in chat** (SwiftMath; headings, lists, code/tables), **live import progress** (bounded
polling while converting), and a **stale chat-hold sweep** (migration 015).

**Ingest** (the existing selection action) now works: the answer identifies the cited paper (using the
bibliography for in-text citations) and the server queues it through the user's own import after a strict
arXiv match. Verified on staging: a DPO passage citing "PPO; [39]" queued arXiv 1707.06347, and a repeat reported
it was already in the library. See [chat](architecture/CHAT.md#ingest-selection-action).

**Library and design** (owner requests 2026-10-05/06): a Library Table on every size (the shared `PaperTable`, also
the Feed's Table layout; sortable columns, reading activity) and detailed rows; a one-row search header (search, Add, one … menu; Cancel and the Library/arXiv switch
while searching); and an independent design audit of every screen against the owner's principles
([DESIGN](DESIGN.md), [audit 1](design-audits/2026-10-06-audit1.md)) with its findings applied: one menu/button
style per screen, one status banner, type scale and margins, 720 pt columns on iPad, quieter chat and settings.
Checked with before/after screenshots on iPhone and iPad, light and dark, and a second independent verification
pass ([audit 2](design-audits/2026-10-06-audit2.md)). Shipped in TestFlight build 11 (2026-10-06).

**Reader citations and archive** (owner requests 2026-10-06): numeric, keyed and unambiguous author–year citations
link to their bibliography entry with a native Back control; tapping a reference offers Open, Add to library and
Copy; a year · venue · arXiv line follows the authors ([reader](architecture/READER_RENDERER.md)). Library items can
be archived (synced, migration 020) from the row menu or a swipe. Selection actions read Explain, Why it matters,
Related and Add paper; Related searches the web for related papers.

**Web search (original2026-10-06 comparison, migration 021):** the owner selected Tavily first with Anthropic's
search as a backup. The later 034 rollout gates Anthropic native search off pending a proven cost bound; Tavily now
uses an evidence-dated calendar-month allowance. The prepaid subscription is a fixed commitment, not metered spend. Live on staging: the same Related request cost $0.047 with Tavily against $0.111
with Anthropic's search (15 vs 23 credits). Consent v2 names Tavily. **TestFlight build 12** (uploaded 2026-10-06 18:39 PDT, processed VALID) carries citations, archive, the selection-action changes and consent v2; unit 256, Core 170, backend 181, database suites pass; full iPhone and iPad UI suites pass except the known rotation flake, which passed after a Simulator reboot. See [chat](architecture/CHAT.md#web-search-on-in-staging)
and [decisions](DECISIONS.md#web-search-providers-and-pricing-owner-decided-2026-10-06).

**Reliability (2026-10-06 night):** paper processing moved to Cloud Run with a loop breaker and timing records
([reliability](architecture/PIPELINE_RELIABILITY.md)); repository landing pages (Zenodo) are followed to their PDF;
Add paper finds papers in about a second and never ends silently; **Add to library** on a reference queues the
paper directly (no chat); automated user-workflow checks run after deploys and on a schedule
([workflow checks](architecture/WORKFLOW_CHECKS.md)) with results in the admin Reliability tab. One paper table
(`PaperTable`) serves Library and Feed at every size.

**Admin Accounts tab** (overnight 2026-10-07; [decision](DECISIONS.md#admin-accounts-agent-decisions-overnight-2026-10-07-owner-asleep-all-reversible)):
owners with MFA list every account (email, status, plan, credits, library size, sign-in methods, created, last
sign-in; search and sort; synthetic test logins marked), add testers (confirmed login, no email sent, starting
credits once), grant credits (audited, at most 2,000) and disable/enable sign-in (audited Auth ban). Migration
`…028_admin_accounts.sql` was applied to staging and the `admin-accounts` function deployed on 2026-10-07 (the
deploy check `admin.accounts-gate` refuses anonymous and customer callers). Verified: database suite (new `test_owner_accounts.sql`), backend suite (10 new cases with
fakes), Deno type-check, admin build, and the tab rendered from `?fixture=accounts` in headless Chromium (light,
dark, 390 px phone, dialogs). The static admin is now hosted and staging anonymous/customer deny checks pass;
the Accounts tab's privileged actions have not been exercised with a real owner MFA session.

**Chat answers (2026-10-07, legacy gaps 4, 2, 9; [decision](DECISIONS.md#chat-answers-tables-papers-named-progress-agent-decisions-2026-10-07-overnight-mandate)):**
Markdown tables render as native tables (pipe text only while incomplete during streaming); **Papers in this
answer** lists arXiv IDs and DOIs an answer names, with Open (confirmed) and Add to library; a `status` stream event
shows "Searching the web for “…”", "Reading results…", "Finding the paper…", "Adding to your library…" under the
streaming answer. Owner feedback (build 14, items 3, 10, 11): selected answer text offers Ask about this, Explain and
Define next to Copy; formulas offer Copy LaTeX and Copy as text; the "Answer:" label is gone; bold around inline math
renders. Verified with Core/unit/backend tests and Simulator UI journeys on the chat fixture (iPhone and
iPad, light and dark). The `status` events need the chat function deployed (not yet); live search/add
progress and live DOI adds from an answer are unverified against staging.

### Reader navigation pass — local verification

Owner request 2026-10-07 (legacy gaps 7, 10, 6, 5; [decision](DECISIONS.md#reader-navigation-find-contents-levels-figures-ipad-chat-column-owner-asked-2026-10-07-agent-decisions-reversible)).
The interrupted navigation branch was rebuilt from a clean, private build folder after merging main's verified
offline-save and passage work (`1aeaea2`, merge `70d5d31`). It contains Find in paper, section levels in Contents,
a figure gallery with Show in paper and Back, and the wide Reader's hideable, resizable chat column.

- **iPhone Simulator:** 68 applicable app tests pass, with two opt-in screenshot tests skipped; 11 applicable UI
  journeys pass. Coverage includes heading levels, numbering and the DPO appendix, figure labels and navigation,
  selection/anchored passage chats, draft ownership, equation actions, citation return and saved reading positions.
  The real-paper Contents screenshots and light/dark figure gallery screens were inspected.
- **Failures resolved:** Contents buttons intentionally span their full row, so their accessibility frames do not
  measure text indentation. The test now asserts spoken levels and ordering; screenshots confirm the actual indent.
  Find scrolls the matching last line of a wrapping list item into view, leaving its earlier lines above the viewport;
  the assertion checks that last line, then verifies the same reading position after a chat round trip. The older
  figure-sheet journey passes from the isolated build without a production change.
- **Draft fix:** reopening an unsent paper draft or explicitly starting a new paper chat now reveals a hidden chat
  column. Unit regressions verify that the earlier draft stays available and its text survives.
- **iPad Simulator:** all five selected journeys pass on the 11-inch iPad: hide/resize, full-width reading in both
  orientations, hardware-keyboard Find, Browse isolation, hidden state/chosen split width after relaunch,
  passage-linked chats, Browse-to-chat navigation and the latest reply above a growing composer. Screenshots were
  reviewed. At the default narrow chat width, a long title overlaps its toolbar buttons; the shared header fix is
  owned by the chat-quality workstream and remains an integration follow-up.
- **Mac:** a clean unsigned Catalyst `build-for-testing` passes for arm64 and x86_64 (app and both test bundles).
  This is compilation evidence; this pass does not verify Mac keyboard/pointer workflows or live services.

Evidence in this navigation worktree: `.artifacts/reader-navigation-review-20261007-4f918777ed/`, including
`iphone-verified.xcresult`, `iphone-final.xcresult`, `ipad-verified.xcresult`, exported screenshots and
`catalyst-build.xcresult`.
All builds use public local fixtures (`https://fixture.invalid`); no hosted call, deployment or physical-phone work.

**Ingest from the web** (owner request, migration 019): a cited paper with no arXiv copy is added from a freely
available PDF that OpenAlex lists (open-access copies and free ML venues), converted privately for the account.
Installed builds keep working (their library reads leave web papers out; Ingest tells them to update). Verified
on staging 2026-10-05 (`scripts/smoke-web-import.mjs`): Dropout (JMLR 2014, no arXiv copy) queued from
jmlr.csail.mit.edu, converted in 90 s (30 pages, 30 credits), reader bundle and attribution verified. Reviewed
adversarially before applying; all findings fixed (download time budget, refreshed locations, DNS checks, cached
v2 snapshots, stored import progress). The app's "Open access" labels ship with the next build.
See [pipeline](architecture/PAPER_PIPELINE.md#web-papers).

**Diagrams** (restored from the legacy app, Mermaid only): asking for a diagram yields a "View diagram" button on
the answer and an entry in All diagrams; the source is stored encrypted on device and drawn with a bundled,
sandboxed Mermaid. Verified live on staging (a DPO loss-flow diagram, rendered) and by a Simulator journey with
the chat fixture.

**Chat quality (2026-10-07 local checkpoint, subsequently deployed):** the legacy Mermaid
label rules in the diagram instructions; each diagram parsed on device before it is kept, with one metered
`diagram_fix` retry and "Couldn't draw this diagram" (source collapsed) when that fails too; "Why it matters" without
web search (`action: "relevance"`); a dedicated prompt for Explain on a single equation; a "This paper" filter in All
chats and the paper's other chats in the chat title menu. A repair needs its successful final event before replacing
the original diagram. The chat title now fits between History and New chat, including the minimum iPad column,
while keeping the full saved and accessibility title. Local verification: 224 backend, 213 Core, 48 selected app
regressions (including the bundled Mermaid parser), eight iPhone UI journeys, the iPad resize/hide/rotation/relaunch
journey, three inspected dark screens and a universal Mac Catalyst build. No live model or Mac runtime check was
made. Evidence and deployment ordering: [chat validation](architecture/CHAT.md#chat-quality-validation--2026-10-07-local-only). See
[decisions](DECISIONS.md#chat-quality-equations-diagrams-why-it-matters-a-papers-chats-owner-asked-2026-10-07-agent-decisions-reversible).

**Original web-search proof (2026-10-05, superseded routing):** up to three Anthropic searches per answer,
a consent line naming it, and tappable Sources under the answer that show the full address before opening Safari.
That path was verified live and with a Simulator fixture. Current 034 policy keeps native Anthropic search disabled
because its internal token bound is unresolved; use the current provider contract, not this historical price/hold
observation, when changing search. Tavily remains the admitted search path.

**Account deletion** (App Store requirement; owner decision 2026-10-05: billing records are kept de-identified):
Settings › Account › Delete account… (type DELETE) calls `account-delete`, which closes the account, deletes personal rows,
private and support files (including the account's private conversions' `raw/` and `reader/` folders) and the
login, and keeps credit, usage and operation records under the closed account's ID. Incomplete deletions are
finished by the paper worker's sweep. Migration `…017_account_deletion.sql` is applied to staging. Verified live:
`scripts/smoke-account-deletion.mjs` (keys, a report, a shared and a private conversion, a paid answer; afterwards
no personal rows, no files, login gone, billing kept) and an in-app Simulator run
(`node scripts/live-journey.mjs --delete`), which also found and fixed a sheet that never presented.
The browser has the same flow in its account menu (2026-10-16; BROWSER_READER.md › Delete account): typed DELETE,
`account-delete`, then this browser's keys, records and account-named storage are erased and it signs out. Verified
against the fixture backend only (desktop, phone, tablet); not deployed and not run against staging.

**App Store purchases** (owner-approved plans: Standard $9.99 = 800 credits/month, Pro $19.99 = 1,800, $4.99 pack =
400): Settings › Credits › Get credits (StoreKit store, restore, manage) and Get credits beside "Not enough credits" in chat and the Library, server verification against Apple's root in
`store-sync` and `app-store-notifications`, migration `…018_app_store_purchases.sql` applied to staging. Each verified
transaction grants once; refunds, reversals, upgrades and deleted-account restores are handled; Sandbox (free)
purchases are capped at 1,000 credits per account and Apple Account per month. Two independent reviews' findings were
fixed. Verified: local database/backend/app tests and a staging smoke test (forged and malformed data refused,
nothing granted). Later033–038 runtime/accounting repairs produced the observed real Sandbox pack grants recorded
above. Production subscriptions/renewals/refunds remain unverified; 044 later repaired the approved upgrade-credit
policy as recorded above. See
[purchases](architecture/PURCHASES.md).

**TestFlight**: App Store Connect record "Gradstep" (owner decision 2026-10-06; renamed from "Paperstep"), bundle
`com.sciencereader.ios`, manual App Store signing, builds 1–5 uploaded to the internal "Owner" group (build 3 adds account
deletion, build 4 Get credits, build 5 Get credits beside "Not enough credits" in chat and the Library) (`scripts/upload-testflight.sh`). Email sign-in codes are sent through Resend (generic sender
`onboarding@resend.dev`, which only delivers to the Resend account's own address until a domain is verified);
sign-up is invite-only (`disable_signup`).

**Real papers verified on staging** (converted, validated, audited in WebKit at iPhone and iPad widths with the
app's reader script): DPO, LoRA, Mamba, Mistral 7B, Adam, PPO, Attention Is All You Need, DDPM, ViT, BERT, Scaling
Laws, Chain-of-Thought — no render failures, no page-level sideways scrolling, every equation fits at iPad width.
Known cosmetic issue: WebKit places bar/hat accents on italic letters slightly left (no TeX skew).

**Reader quality on real papers**: aligned derivations now align (WebKit ignores `mtable` column alignment),
equation numbers stay visible, wide math fits or scrolls in its own box instead of the whole page scrolling
sideways (4 of 6 papers on iPhone), and sentences split by page breaks are rejoined in new conversions. See
[reader renderer](architecture/READER_RENDERER.md).

An independent security review of the new functions, SQL and app paths found no cross-account access and
no way to spend another account's credits; its five findings were fixed (true chat cost reaches the budget
freeze, download admission with storage/owner quotas — migration 016, inert links in chat answers,
secret-safe Vault writes with the pipeline secret rotated, tighter per-account search rate). A real-paper
renderer bug (equation order in table captions, Mamba) was found by the Simulator journey and fixed; the
failed paper resumed at render on Retry with no second charge.

Design and failure handling: [paper pipeline](architecture/PAPER_PIPELINE.md), [chat](architecture/CHAT.md),
[reader renderer](architecture/READER_RENDERER.md). Migrations `202610050014_paper_pipeline.sql`, `…015_stale_chat_holds.sql` and `…016_download_admission.sql`
are applied to staging (hash in the ledger; immutable from now on). Two independent adversarial reviews of the money and
concurrency design were completed and their findings fixed before it was applied.

**Library as a proper table** (owner request 2026-10-07, [decision](DECISIONS.md#library-as-a-proper-table-owner-asked-2026-10-07)):
the Table is the Library's default (List the alternative; Detailed rows removed), with a column chooser (Library
options › Columns, per iPhone / iPad-Mac), Tags (own tags else topics) and Source/Pages columns, every column
sortable, quick filters (Tags ⌄, All, Unread, Reading, Failed n, Archived), arrow keys/Return/hover on iPad and Mac,
and an inline Retry / Get credits / Remove on stopped imports (Retry shows the row downloading at once). Verified in
the Simulator only (iPhone 17 Pro, iPad Pro 11"): `PaperTableTests`, `LibraryModelTests` (Retry through the real
command queue against the fake server), `LibraryLayoutTests`, and visual scenarios `library-table`,
`library-columns`, `library-filter-failed`, `library-retry`, `library-filter-tag` in light and dark. Not yet seen with
a real signed-in library, a hardware keyboard on a device, or on the Mac build.

**Library metadata view** (owner decision 2026-10-05, [decision](DECISIONS.md#library-metadata-view-owner-decided-2026-10-05)):
Since 2026-10-06 the Table is one app-drawn `PaperTable` on every size (iPhone portrait: Title, Year, Progress;
more columns as they fit), shared with the Feed's Table layout; see the decision's update. Verified in the Simulator
only (iPhone 17 Pro, 17e, iPad Pro 11"; light, dark, largest text and an accessibility size; portrait and
landscape): `PaperTableTests` (columns by width, header sorting, Feed order), `LibraryLayoutTests` (phone, iPad and
Feed tables), visual scenarios `library-table`, `library-table-browse`, `library-slow-import-table`, `feed-table`,
`feed-table-abstract`; the List, Detailed rows and the Feed List are pixel-identical to before. The original
implementation, for the record:
"Sort and details" adds Layout: List (default, unchanged) / Table. iPad shows a native sortable table (Title,
Authors, Year, Topics, Added, Opened, Read, Chats; Pages hidden; Status only when not ready; column visibility and
order persist); iPhone landscape shows an app-drawn table with the same sortable columns; narrow containers and
accessibility text sizes show detailed rows. New sorts: Authors, Year, Opened, Progress, Chats. Opened/Read come
from device-local encrypted reading activity, which also makes reading positions survive relaunch
([privacy and sync](architecture/PRIVACY_AND_SYNC.md#device-local-reading-activity-2026-10-05)). Verified in the
Simulator only (iPhone 17 Pro Max, iPad Pro 13"): unit tests for formatting, sorting and persistence,
`LibraryLayoutTests` (switch layout, sort by header/menu, open from the table), visual scenarios `library-table`,
`library-detailed`, `library-metadata-list` in light/dark/XL and landscape; the default List is pixel-identical
before/after. Not yet seen with a real signed-in library or on a device.

**All chats as a table** (owner request 2026-10-07, [decision](DECISIONS.md#all-chats-as-a-table-owner-asked-2026-10-07)):
a dense, sortable table of conversations (Conversation, Paper, Messages, Started, Last used; newest first), search,
All · Paper chats · General, unsent drafts on top, Open paper and Delete (a conversation tombstone, confirmed first).
New events carry an encrypted `createdAt`; older history shows "—" and sorts by arrival. Verified in the Simulator
only (iPhone 17 Pro, iPad Pro 11"): Core `ConversationSummaryTests`, app `ChatHistoryTests`, UI `ChatHistoryTableTests`
and the existing chat-history journeys; visual scenarios `chat-history-table`, `chat-history-search`,
`chat-history-actions`. Not yet seen with a real signed-in history or on a device.

## Adding any paper (039 deployed; device acceptance remains)

Owner: "adding a pdf needs to be absolutely bullet proof." Add takes an arXiv ID, a DOI or any link
(`functions/v1/add-paper`); PDFs upload from Files, by drag and drop, or through Share › Gradstep, into private
upload sessions (migration `202610070039_pdf_uploads.sql`, `functions/v1/upload-pdf`, bucket `paper-uploads`)
verified by the Cloud Run worker and converted privately with credits; failed web imports a website refused
offer Download on this device. Uploaded papers reach the app through new v5 library reads (and compact v4).
Design: [PDF uploads](architecture/PDF_UPLOADS.md). Original local checkpoint (2026-10-07, after merging main's
031/032): every database suite including `test_pdf_uploads.sql`; 234 backend tests; Core 205; app unit 336 (5
skipped; one web-view load timeout under Simulator load that passes alone); UI `AddPaperFlowTests` (6) and
`LibraryLayoutTests` on iPhone 17 Pro, light and dark, and two Add journeys on iPad Pro 11"; Mac Catalyst builds
(the extension is iOS only). Screens: `.artifacts/visual/pdf-uploads-2026-10-07/`. Migration 039, functions, bucket and worker were subsequently
deployed with scope-2 inventory. Remaining acceptance: Share extension provisioning (App Group, App ID/profiles),
real upload/device-download and system-share journeys, and physical-device checks. Do not treat hosted ordinary
v5 commands as proof of those PDF paths.

**Passage-linked conversations** (owner request 2026-10-07, [decision](DECISIONS.md#passage-linked-conversations-owner-asked-2026-10-07-agent-decisions-all-reversible),
legacy gap 1): selection actions save a `TextAnchor` (artifact, block, quote, 32 characters each side) inside the
conversation's encrypted event (wire format unchanged); **Go to passage** from the chat's title menu, its "…" menu
and All chats opens the paper, lands on the passage with Back, and falls back to the legacy text-search cascade on
another conversion ("Couldn't find the passage…" when nothing matches); passages with chats are underlined (CSS
custom highlights, no DOM change) and a tap opens the chat, or a chooser when several share it; Settings › Reading can
hide the underlines; All chats shows the passage as a wide row's second line. Verified in the Simulator only (iPhone
17 Pro, iPad Pro 11"): Core `PassageAnchorTests`, app `PaperPassageTests` (bridge: context, cascade, short quotes,
formulas, marks vs selection/citations/layout/position, taps, native request), UI `PassageJourneyTests`; screenshots
light, dark and iPad. Browser passage actions/marks are now implemented and locally exercised in milestone 2.
Real cross-device passage-history and signed-in Mac interaction/device checks remain separate evidence.

## Earlier local verification (historical counts)

- Database: full local PostgreSQL suite including `tests/database/test_pipeline.sql` (shared/private
  flows, reuse, credit holds and settlement, single submission grant, lost acknowledgements, operator
  resolution, withdrawn funders, fencing, permissions).
- Node: 149 backend tests (pipeline worker stages with fakes plus a real-render integration on retained
  DPO output, chat validation/pricing/settlement, renderer hostile-input and tamper checks, Mathpix,
  archive, arXiv).
- Swift: ScienceReaderCore package tests (166) and app unit tests (248, 3 skipped; 2026-10-05 library metadata view); iPhone and iPad UI suites.
- Recovery code ↔ Apple Passwords (2026-10-06, Simulator only): fill-from-Passwords handles "none saved"; Save to
  Passwords reaches Apple's save sheet, which the Simulator can't complete without iCloud Keychain. Needs a device check.

## Foundations from earlier checkpoints (still true)

Dedicated Supabase Pro organization with staging on Micro compute and database TLS enforced; production not
provisioned. Device-held encryption keys with recovery code, cross-runtime crypto envelopes, encrypted
SQLite journal, two-device hosted sync check, encrypted-history quotas. Screenshot feedback with private
support storage and MFA-gated admin dashboard (now including a pipeline/paid-attempt panel). Native Apple
capability and six-digit email-code settings configured. The owner subsequently confirmed native Apple/Google
sign-in; browser OAuth and current-release device acceptance remain separate.

## Spending (October 2026, staging)

Readback **2026-10-14 06:25 UTC** (`app_private.platform_budgets`, read-only query): **$21.023497 spent, $0 reserved,
$25 limit, work enabled.** The Agent v2 live smokes that night cost $0.279296 in provider attempts. The earlier
snapshots below are retained.

The October provider budget snapshot at **2026-10-08 09:08 UTC** is **$14.017212 spent, $0 reserved, $25 limit**
(`.artifacts/takeover-20261008/spend-current-readback.json`), with no unresolved provider attempts.
This supersedes the earlier $9.80 cap/$5.32–$6.56 observations and the 05:14 UTC $13.677389 snapshot.
Headroom at that moment is not a fresh authorization to spend. Fixed subscriptions, infrastructure allocations,
prepaid search units and provider liability remain separate; keep the approved $100/month incremental beta ceiling.
Supabase invoice attribution is incomplete; do not retain the old approximately-$35 guess as a verified bill.
See [operations](architecture/OPERATIONS_AND_BILLING.md) and [spending controls](architecture/SPENDING_CONTROLS.md).
Use the owner Spending/Processing views or `python3 scripts/pipeline-ops.py status` for current observations;
the scoped reader signed-URL gap was closed through issuer fencing and verified CDN retirement at 09:33 UTC.
Original/Mathpix delivery, general invocation traffic and actual infrastructure invoices remain separate boundaries.

## Sign-in on TestFlight (owner report 2026-10-06)

Apple works. Google fails because the Google provider was never configured on staging (`external_google_enabled`
false, no client): the server answers "Unsupported provider". Email codes fail for any address without an account
because sign-up is closed (`signup_disabled`); the app showed "Sign-in isn’t available in this build" and now says
the email has no account (next build). Codes to the owner's existing account are accepted by the server; delivery
uses Resend's shared test sender, which delivers only to the Resend account's own address. The app has no password
sign-in (replaced by email codes on 2026-10-04); only the admin site uses a password (now hosted; owner MFA acceptance pending).
Update 22:20 PDT: codes now come from `codes@gradstep.ai` (verified domain) and reach any invited address.
Update 22:45 PDT: Google sign-in is configured: OAuth web client in Google Cloud project `gradstep` (Google Auth
Platform, External audience in testing mode, test users only; branding gradstep.ai and its privacy page), redirect
`https://coxhjvqpflgxkleydati.supabase.co/auth/v1/callback`; Supabase's Google provider enabled with it
(credentials kept in `.env.providers`). Authorize now redirects to Google; an on-device sign-in is still to be tried.
Update 2026-10-07: the owner signed in on device with Google and with Apple; both land in the same account as the
email code (Supabase links identities that share a provider-verified email: email code, Apple and Google on one
account). This also confirms that pre-created testers can use Apple or Google with the same address. Apple's "Hide My
Email" relay address would create a separate account (no linking); testers should share their real email.

## Still required

**Queued follow-ups (owner approved 2026-10-07, "item 5"; collected from finished agents' reports so none is stranded):**

- A full private storage quota shows "too large"; give it its own reason and message.
- Reliability charts count each automatic retry's failure again.
- Exact automatic-retry countdown remains optional: build 19 now shows scheduled retry state without misleading percentages or a competing Retry button.
- Failure wording pass ("Conversion failed", "…to convert this paper").
- VoiceOver: the new chat selection/formula actions and the library rows' swipe and long-press actions.
- Library: tap a tag chip to filter by it; remember filters between launches; show tags on papers still importing.
- Admin: disabling sign-in should also end open sessions (today an open session lasts until its token expires).


- **Sign-in/recovery:** native Apple/Google and invited-address email delivery were confirmed earlier; browser
  OAuth, camera QR approval and Passwords save/fill still need their own acceptance. Sign-up is invite-only;
  Simulator fixture results are not current physical-device proof.
- **Chat polish**: long papers raise the per-question hold (context is the
  whole paper's MMD). Math that SwiftMath cannot parse is now rewritten first, and symbols it lacks are
  registered (57 of 904 real-paper equations fell back to source before; none fail to parse now).
- **Accessibility**: an opt-in XCTest audit (`TEST_RUNNER_SCIENCE_READER_AX_AUDIT=1`, test
  `testAccessibilityAuditOfMainScreens`) covers Library, reader, chat with an answer and diagram, the diagram and
  Settings. First run (2026-10-05): the custom tab bar is flagged for capped Dynamic Type (it follows Apple's
  pattern: capped size plus the large content viewer); with the keyboard dismissed, chat text passes contrast and only
  the small secondary-colored sync caption and the glass "Latest" button are flagged (standard iOS styles, kept);
  truncated library rows and non-interactive diagram labels are expected. No VoiceOver walkthrough on a device yet.
- **Search quality** (fixed 2026-10-05 after the owner's "Cnn" search led with a physics paper): topic searches are
  ranked with OpenAlex (relevance and citations, arXiv works only), arXiv supplies metadata, ML categories and exact
  titles lead; arXiv's own search is the fallback. Checked live on staging for CNN, vision transformer, diffusion
  models, LoRA, RLHF, DPO, Mamba, GNNs, mixture of experts. Queries are sent from the server to OpenAlex and arXiv
  with no account or device data. Ambiguous short terms can still mix fields; no judged benchmark yet.
- **Operations:** reader fencing/CDN retirement and the scheduled-check image refresh are complete. Verify the
  next scheduled execution and actual alert delivery; reconcile invoice attribution and remaining original/Mathpix
  delivery boundaries; exercise owner/MFA admin flows against hosting. Complete production provisioning only after
  review. Existing hold cleanup, storage admission and encrypted backup tooling must remain intact.
- **Purchases:** Production subscription/renewal/refund acceptance and current product-metadata readiness.
  Prior-period-credit retention is now implemented in 044; the local lifecycle proof is not a real StoreKit
  subscription purchase. App Store Server API reconciliation/refund-consumption responses need
  an In-App Purchase key; final review screenshots remain. Observed Sandbox pack grants are already verified
  through the private Node verifier, not unsupported Edge certificate primitives.
- **Product:** browser OAuth/Safari secure-key persistence, durable encrypted browser drafts/offline support,
  owner acceptance of build 21's accumulated screenshot fixes, accessibility on real papers and physical-device checks (paused).
  Feed 043/046 activation is the lead's step after review (For you itself is decided); podcast scope/privacy/pilot and
  public-pricing changes remain owner decisions.
- **Account deletion follow-ups before public release**: revoke the Sign in with Apple token on deletion,
  release a deleted account's App Store subscription binding, and expire deleted data from backups.
- **App Store listing**: final name and icon (the legacy artwork is a placeholder), privacy label from the
  manifest draft (email, user ID, other user content, customer support), screenshots.
- **Applied-but-unused**: migration 011's acquisition tables/RPCs remain in the database; a later additive
  migration can drop them.

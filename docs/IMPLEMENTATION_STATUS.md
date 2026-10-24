# Implementation status

## TestFlight 91 — 2026-10-24 UTC (iOS uploaded; Mac uploading)

Release gate on the merged main: `npm test`, `npm run test:imports` 15/15, `swift test` 451 + 66 XCTest, all pass; the
arXiv compiler is unchanged since 90 (no sweep needed). iOS app 35 MB with the on-device models as the On-Demand
Resources pack `device-pdf-models` (364.6 MB, 19 files, checked by `check-device-model-pack.mjs`). Converter port
revision 12 (Show in PDF's provenance rows, 11, plus the weakness explorer's rules). Admin redeployed (interest index
Health card). Not yet seen on a device; first checks on 91: the model download from TestFlight on iPadOS 18.7.8, Show in
PDF, full-text search, the Feed's Why column and sections, the divider drag.


- **The on-device PDF model is a separate download** on iPhone and iPad (owner request 2026-10-24; DECISIONS.md,
  DEVICE_PDF_ROUTE.md "The models as a download"): an On-Demand Resources tag hosted by the App Store with the build,
  checked file by file against `device-models-pack.json` (written by `scripts/device-models.mjs` from the locked exports)
  and kept in Application Support, excluded from backup. Offered where it is used ("Download PDF reading model (about
  365 MB)", then the reading starts); one Settings row (Downloaded with Remove, Not downloaded with Download). The Mac app
  keeps the models inside the app. iOS app built on this Mac (Internal, unsigned, device): 83.6 MB, was 447.6 MB; the asset pack beside it is 364.6 MB.
  Verification: `npm test` (fast) and `swift test` (437 + 59 XCTest, one opt-in skipped) pass; the journey downloads the
  pack in the iPhone 17 Simulator (iOS 26.4) and reads the fixture paper. Not verified until TestFlight: App Store hosting
  of the pack, real download times, background behaviour, the iPad on iPadOS 18.7.8.

- **Show in PDF** for on-device readings (branch `worktree-agent-aa0ba2fe38a9c93ff`; owner request 2026-10-24;
  FIGURE_VIEW.md "Show in PDF", DECISIONS.md): the last item of a text selection's menu and of a tapped equation's menu
  opens the PDF on this device at the passage, its lines highlighted, framed and zoomable, with previous/next page. Converter
  **port revision 11** records each block's page and boxes in provenance (`blocks`); the reading is unchanged. Older
  readings search the whole PDF; no words found shows the block's recorded place; nothing at all says so. arXiv HTML readings
  unchanged. A passage on part of a line opens readable, from its column's left edge. Verification: `npm test` (fast tier)
  passes; `swift test` 437 + 50 XCTest (one opt-in skipped) pass; the opt-in real-reading check on 2305.18290v3 (374
  passages: 293 word for word, 75 approximate, 6 by the block's place, all on a recorded page) and the opt-in journey
  passed on the iPhone 17 Pro and iPad Pro 13-inch (M5) Simulators; the Mac app builds. Not seen on a device; the slot
  sheet beside a second slot and the equation menu's entry were not exercised by a journey.
- **Library search over every saved paper's text** (branch `worktree-agent-a95c83cd39d83f3b5`; owner question 2026-10-24;
  DECISIONS.md "Library search over every paper's text"; NATIVE_LIBRARY_SEARCH.md "Full-text index"): an encrypted
  on-device inverted index (ScienceReaderCore `FullText/`) replaces the 200-paper / 10,000-word in-memory term set.
  Words and `"phrases"`, all required; the word being typed matches as a prefix; BM25 by field (title > tags, authors,
  abstract > notes > body) with a small recency boost orders the default Recent sort; metadata substring matching is
  kept, so results are never fewer. Indexes title, authors, tags, abstract, notes and snippets, and the text of every
  reading saved on this device; incremental, built in the background on first run, rebuilt only on a version change.
  Segments, manifest and texts are AES-GCM sealed under the account's local key (complete protection, no backup); no
  plaintext on disk (tested). A result matched in the text shows one secondary line with the words highlighted under
  its title (List and table); opening it opens Find in paper on those words. Measured at 2,000 papers on the iPad
  Simulator: 72 KB/paper on disk, 57–74 ms to load, index queries 0.3–4 ms, the whole Library search 11–18 ms median
  with 100 snippets. Verification: `swift test` 450 + 38 pass (13 new full-text tests); app unit tests for search
  (LibraryFullTextSearch, LibrarySearchCoordinator/Model, PaperTable, LibraryMetadata, OfflineModel) pass;
  WorkflowSafetyTests' `testAskFromBrowseEntersReaderAndKeepsThePaperConversationDraft` fails on iPhone and iPad
  Simulators (it expects the Mac's `browsing` rule; none of that code changed here); `npm test` passes. UI (iOS 26.4,
  `-O`): new `LibraryFullTextJourneyTests` (body word → snippet row → paper opens with Find "1 of 2", keyboard down)
  passes on iPhone 17 Pro and iPad Pro 11-inch; `IPadShapesJourneyTests/testSearchKeepsTheListAfterOpeningAResult` and
  `PaperToolsTests` find-bar journey pass (the latter 3/3 after one timeout under a machine load average of ~200);
  `WorkflowJourneyTests` `testSearchOpenReturnNoMatches…` and `testSearchScopeNameFits…` fail at the ML paper search
  switch on this branch and on the base commit alike. Not yet on a device.
- **TestFlight 90 follow-ups** (branch `worktree-agent-adc76ef2c76c020c8`): the built-in sample paper names today's menus
  (Copy · Explain in Chat · Save snippet; Chat about Equation · Focus · Copy as Text; a reference's menu), its bundle
  regenerated as `8ffacaf4…` and pinned in `ReaderBundleLoader`. iPad Wide: the Feed's A− / A+ is the first row of the
  Feed's ⋯ instead of floating over the list (Tall unchanged). iPad and Mac: a tapped author (Find papers by …) and a
  passage with several chats (Chats about this passage) open the system's pull-down menu at what was tapped, as a
  reference's does, never a centred dialog; the iPhone keeps its action sheets. On-device model readings of an arXiv
  paper get the paper AI Explainer, figure and equation explainers and paper chat from the reading's own numbered text
  (same membership and request as the HTML reading; no PDF upload, no server change); a reading of another revision and a
  PDF the reader added still have none (DEVICE_PDF_ROUTE.md). Flaky ⌘1 check: on the Simulator the first hardware key
  event of a launch never runs a SwiftUI keyboard shortcut (3/3 launches; typed letters arrive); the journey now types a
  letter into the search field first (4/4, and in the full run). Stale tests fixed (they failed on main too, the app is
  as designed): the two ML paper search journeys wait for its idle state "Search by title, author or topic" (since
  2026-10-18), and `testAskFromBrowse…` sets up the iPad's Browse (the Library place with the paper beside it) on iOS.
  Verification (iOS 26.4 Simulators, a machine load average of 200–650 from other sessions): `npm test` passes;
  `swift test` 451 + 50 XCTest (one opt-in skipped) pass, including the new model-reading context test; reader renderer
  23/23; iPad Pro 13-inch IPadShapesJourneyTests 15/15 (one launch timeout under load passed on rerun; ⌘1 passed),
  MenusJourneyTests 8/8 plus the new author test (iPad and iPhone 17 Pro), MenusJourneyTests text selection on iPhone,
  WorkflowJourneyTests' two search journeys (iPhone; the first also iPad), WorkflowSafetyTests 29/29 (iPad),
  PaperWebViewTests' contents-selection test and PodcastTransportTests on the new sample. Not run: a journey for Chats
  about this passage (no fixture with two chats on one passage; it shares the author's menu code), the Mac app, and a
  real model reading's explainer (no on-device reading in the Simulator fixtures). Not yet on a device.
- **iPad Wide: a table no longer spills past the screen's left edge while the divider narrows it** (branch
  `worktree-agent-a6be7aa186da05692`; owner report 2026-10-24). Cause: `PaperTable` measured its row width on the header
  through `.frame(maxWidth: .infinity)`, which takes its content's width when that is wider; with the sideways-scrolling
  arrangement every header column has a fixed width, so the measurement could never shrink. The rows kept the old
  width and were centred in their cells, so the title column ran off the slot's (the screen's) left edge, and stayed
  there after the finger lifted. Fix: the width comes from `offeredWidth` (`.frame(minWidth: 0, maxWidth: .infinity,
  alignment: .leading)`), always the width the List offers; rows take exactly their width from the leading edge.
  Safety net: `TwoSlotLayout`'s slots align to their leading edge and clip at their sides only (`SlotClip`; content still
  runs under the status bar and home indicator; menus, popovers and slot sheets are outside it); the Mac's `ReaderSplit`
  panes align to their leading edge. Verification (iPad Pro 11-inch (M5) Simulator, iOS 26.4): new hosting test
  `PaperTableWidthTests` (a scrolling table narrowed 12 pt at a time from 760 to 280 pt and back, a jump, and the width
  source) failed before (rows 868 pt wide at x = −284 in a 300 pt slot) and passes; the new journey
  `IPadShapesJourneyTests/testTablesStayInsideTheirSlotWhileTheDividerNarrowsThem` (Library and Feed tables, the divider
  dragged slowly left in held steps to 280 pt and back) failed before (Title header at x = −29 after the first step) and
  passes; IPadShapesJourneyTests 16/16; PaperTableTests 24/24 (`testFiltersAndTagsNarrowTheLibraryAndItsSearch` fails on
  a second run on the same Simulator: it leaves `library.filter` saved, unrelated); `npm test` and `swift test` (451 + 50
  XCTest) pass. XCUITest can't look while the finger is down, so mid-drag frames are covered by the hosting test, which
  also checks the leading edge one frame after each step. Screenshots: `.artifacts/divider-overflow/{before,after}/`.
  Not seen on a device; the Mac app was not built.

### Interest index, step 2: server layer — 2026-10-24 UTC (staging; serving `staff`; no client uses it yet)

Design and as-built record: [architecture/INTEREST_INDEX.md](architecture/INTEREST_INDEX.md). Lead's interim decisions
(180-day corpus, rebuild every two weeks until about 50k papers then weekly, due-based with back-off, privacy line
pending owner approval, Homebrew PostgreSQL 17 + pgvector for local tests) are in DECISIONS.md.

- **Staging:**
  - Migrations 0152 (pgvector, fingerprints, map, term vectors, artifacts, RPCs, the pool-ingest hook, cron, health)
    and 0153 (due-based rebuild: weekend 06:00–10:00 UTC window or 24 hours overdue; back-off 10 min / 1 h / 6 h;
    kick heartbeat), each after an encrypted backup.
  - Edge function `interest-index`, and worker revision `gradstep-pipeline-00054-m9n` (`POST /interest`, gte-small
    fp32 ONNX baked in by checksum, built with Cloud Build).
- **Backfill:** 9,970 papers (9,890 pool, 80 catalog) embedded, 0 failed. Map version 1 published at 16:34 UTC:
  20 / 68 / 246 nodes, cohesion 0.9214; 56,972 phrases; map 143 KB, terms 285 KB, 3 shards (8,230 papers, 2.6 MB).
  Cloud Run 3,965 instance-seconds in all (≈ $0.12 list, inside the free tier). Database 81 MB. AI spend $0.
- **End to end with two synthetic tester accounts (deleted afterwards):**
  - Not served without the role (404 / `interest_unavailable`). With it, the manifest is 200 and every artifact matches
    its SHA-256 and ETag (304 on `If-None-Match`) and decodes.
  - The library RPC returns exactly the caller's own papers, with q8 fingerprints, leaves and terms. It omits another
    reader's paper and a catalog-only paper (no oracle).
  - Anonymous RPC 401; tables not exposed.
  - Workflow check `interest.health` passes; `budget.health` still fails on the existing 83 % of October's $40.
- **Tests:**
  - `npm test` passes, with new `tests/backend/interest-*.test.ts`: tokenizer equal to Hugging Face on 81 fixtures with
    padding off, n-grams equal to scikit-learn, codecs, map build, delivery and job guards.
  - The database fixtures `interest_index.sql` and `interest_rebuild_due.sql` pass on PostgreSQL 17 + pgvector. They
    cover RLS and grants, sync rules, the no-oracle RPC, publish and the stability gate, a missed window, two failures
    then success, a weekday 24 hours overdue, heartbeat and an unreachable worker.
  - The slow embedder parity test passes (20 reference vectors at cos ≥ 0.9999).
- **Testing change:** the database suite now needs pgvector (`SCIENCE_READER_PG_BIN`, new `SCIENCE_READER_PG_PORT`;
  docs/TESTING.md). The shared portable PostgreSQL 18.4 server on 55431 has none, so the full suite stops there with
  instructions.
- **Not done or known:**
  - The admin site was not redeployed: the Health card is built and type-checks, and the database side is live.
  - ONNX Runtime telemetry is **closed** (branch `interest-ort-telemetry`; worker revision `gradstep-pipeline-00055-vzm`,
    deployed 17:07 UTC):
    - ORT 1.30's official build has Microsoft 1DS telemetry on by default (`mobile.events.data.microsoft.com`).
    - The image now sets the documented opt-out `ORT_DISABLE_TELEMETRY=1`, and the embedder refuses to load without it.
    - Captures:
      - the old image (no CA bundle) looked up the collector repeatedly;
      - the new image made no lookup;
      - a full `/interest` run against staging resolved and connected only to `coxhjvqpflgxkleydati.supabase.co`.
    - Before the fix: revisions 00053/00054 probably reached the collector's TLS but could not send events. The local
      measurements on the owner's Mac probably sent ORT's device and model metadata, never paper text; their state was
      deleted.
    - Details: INTEREST_INDEX.md "ONNX Runtime telemetry".
  - No device or browser consumes the index (step 3).
  - The privacy-notice line needs owner approval before `serving='all'`.

- **Feed grouped by why** (branch `worktree-agent-ac55b186b5ae6f69c`; owner decision 2026-10-24, DECISIONS.md, PERSONALIZED_FEED.md
  "Client presentation"): the Table has a **Why** column ("Your tag: RLHF", "Like: Muffin…", "Author: Tri Dao",
  "Popular ▲ 48", "Category: cs.CL", "Explore"; full sentence for VoiceOver and as the Mac tooltip), on by default
  where papers have reasons, sortable by group; the title's second line drops the reason while it shows. The List
  groups For you into sections (one per tag, Like papers you added, From authors you read, Popular this week, By
  category, Something different) with counts, the server's order within; rows drop what the header says. Category
  chips (no reasons) look as before. On iPhone in portrait Why now sits beside the title and Popularity scrolls in.
  App-only; no server change (For you already returns up to 50). Verification: `npm test` (fast tier) passes;
  `swift test` 437 + 57 XCTest (one skipped) pass, including 7 new `FeedWhyTests`; `FeedPersonalizationTests` and
  `PaperTableTests` pass; `FeedForYouTests` (7, including the new grouped List, Why column and sideways-iPad tests)
  pass on the iPhone 17 Pro and iPad Pro 13-inch (M5) Simulators, `ResilienceJourneyTests` feed refresh and
  `TableColumnsTests` feed columns on iPhone; the Mac Catalyst app builds (not run). Before/after screenshots in
  `.artifacts/feed-why/`. Not seen on a device or with a real 50-paper For you list.

## On-device PDF route: weakness explorer, glyph-verified formulas, line returns — 2026-10-24 (in TestFlight 91)

Owner, 2026-10-24: a tool to clarify the route's weaknesses, and a faster, more accurate route. Full numbers:
[review](reviews/DEVICE_PDF_WEAKNESSES_20261024.md); design: [DEVICE_PDF_ROUTE](architecture/DEVICE_PDF_ROUTE.md#weakness-explorer-and-port-revision-11--2026-10-24).

- **Weakness explorer** (`scripts/device-route-weaknesses.mjs`): 35-category error taxonomy with stage attribution, impact per
  10 pages, worst examples as page crops beside both readings, per-page stage timings, `--baseline`. Before (83 papers,
  2,140 pages): inline math missed 2.59, inline boundaries 2.41, displays left as images 1.81 (1,835 of 2,281 read right but
  held back by the gate), text missing 1.74, inline typeset wrong 1.56.
- **Converter port revision 12** (merged after Show in PDF's revision 11), on in the app: `verifyGlyphs` (displays typeset 43 % → 81 % test, 25 % → 61 % venue;
  scored typeset precision 0.976 → 0.958 test, 0.816 → 0.778 venue), `lineReturns` (text F1 +0.003 to +0.006, whole blocks
  +0.005 to +0.013, inline found and right up), `ligatures`, `compounds`, `reuseRecognitions` (18–27 % fewer recogniser
  crops). `displayLines` built, off. Total impact 19.8 → 17.0 per 10 pages. Host: per-page timings; recogniser batches by
  the formula's glyph count. No wall-time gain measurable on the loaded Mac (interleaved A/B ×1.04).
- Evidence: `npm test` passes; `swift test` 437 + 38 XCTest pass. Not verified: any iPhone (paused), the Simulator journey,
  timing on a quiet machine. Needs a TestFlight build to reach the app.

## TestFlight 90 — 2026-10-24 UTC (iOS and Mac uploaded)

- **Also in 90:** TestFlight 89's iPad Wide work (places button top-left, a double-tapped divider lets the list cover the
  window, live divider drag, the open paper centred and tinted after turning upright); Feed Add/loading/checkmark keep one
  size; iPad Wide Library ⋯ has one Catalog row with Manage Catalogs inside; Settings is in the places menu under Search
  and in no ⋯ menu in Wide; MacKeyboardTests uses ⌘2 for the Library. Release gate on the merged main: `npm test`,
  `npm run test:imports` 15/15, `swift test` 437 + 38 XCTest, all pass. Not yet seen on a device. Known: the built-in
  sample paper still names Define/Relevance/Similar/Ingest; in Wide the paper's text-size control floats over the Feed
  list; two unanchored confirmation dialogs (author, Chats about this passage) may still centre over the paper.
- Reader **revision 23** (branch `reader-fixes-90`, build 88 reports): one list marker per item, the paper's own label, with
  no empty lines under it (2610.28711v1, 2610.14162v1); multi-line diagram labels drawn line by line without phantom
  struts (2610.14162v1 Figure 3). 125-paper replay and a fresh 60-paper sweep: no new failures; iPad screenshots in
  `.artifacts/reader-fixes-90/`. Saved papers need Update this paper.
- Reader **revision 24** (branch `reader-header-90`, fresh-paper sweep fail on VLA-Δ 2610.21306v1, also in revision 22):
  a formula in a title or heading that Unicode spells is text, so titles and Contents read "VLA-Δ", "τ²-bench", "λ < 1",
  "FID ↓" instead of "VLA- \Delta :" (a fraction or a script Unicode lacks stays math); an affiliation keeps its
  bracketed web address ("Zhejiang University (zju.edu.cn)") instead of "()" plus a line per author, brackets emptied by
  a dropped e-mail go, a repeated project page is listed once and an icon-only link (ORCID) leaves no empty line. Fresh
  60-paper sweep and 125-paper cached replay: 0 fail, findings otherwise unchanged. The Library row's title is the
  catalog's (`$\Delta$` as arXiv writes it), not the reader's; unchanged.

- **iPad menus, explainers and prompts** (branch `ipad-menus-90`; owner feedback on TestFlight 88, DECISIONS.md › Menus,
  explainers and prompts on iPad): upright, the AI Explainer, equation view and figure page cover the page as on iPhone;
  Why it matters, Related papers, Add paper, Draw snippet and the system's Look Up/Translate/Search Web/Share/Speak are
  gone from a text selection's menu (Copy · Explain in Chat · Save snippet), an equation's is Chat about Equation · Focus ·
  Copy as Text; a reference opens the system's pull-down menu with symbols; the Feed opens as a table; in Wide a slot's
  prompts (model chooser, consent, Columns, Snippets' sheets…) cover that slot only, and app-level sheets are the iPhone's
  sheet scaled up. Verification (Simulator iOS 26.4, iPad Pro 13-inch M5 and
  iPhone 17 Pro; Mac Catalyst on this Mac): `swift test` 437/437; new `MenusJourneyTests` pass on iPad (8) and iPhone
  (the 5 that apply), `testMacRightClickMenus` passes on the Mac; IPadShapesJourneyTests 14/15 (the ⌘1 place shortcut
  check fails, as noted for TestFlight 88; `testReadAndDiscussKeepThePaperInPlace` failed once and passed on rerun);
  selection, equation and reference journeys in WorkflowJourneyTests and ReaderNavigationTests pass on both;
  ChatTitle/ChatGeneration/PaperTable unit tests pass. MacKeyboardTests' stale ⌘4 Browse check was updated to ⌘2 on main. The Feed's checkmark state after Add isn't reached in the fixture;
  rows keep their top and height from Add to loading. iPadOS 18 sizing not run on an 18 Simulator (only 26.4 installed).
- Figures of on-device readings zoom out onto the PDF page (branch `figure-zoom-out`; converter port revision 10; FIGURE_VIEW.md "Zoom out onto the page").

## New AI gateway key, iPad Wide places — 2026-10-24 UTC (TestFlight 88, iOS and Mac uploaded)

- **AI key restored on staging:** the owner supplied a new dedicated OpenRouter key (key info: $50 key limit, unused)
  into `.env.providers`; `deploy-staging.py staging` set the function secrets and deployed the functions, including the
  401 → `service_unavailable` hardening; `deploy-pipeline-worker.py deploy --project gradstep` serves revision
  gradstep-pipeline-00052-rbz. Workflow checks after both: `chat.smoke` PASS (a real answer, 1 credit, 4.2 s); the
  one FAIL is `budget.health` — $32.91 of the $40.00 October provider budget spent (82%) and one OpenRouter attempt
  from the expired-key window still unknown. Budget not raised (owner's call). The key was pasted in chat; rotating it is
  recommended.
- **TestFlight 88:** the iPad Wide places menu and each place's own two slots (branch ipad-places-menu, entry below)
  with every divider starting in the middle (owner). IPadShapesJourneyTests on 88's code: 12/13; the ⌘1 place shortcut
  check failed once, and its rerun failed earlier on the stale-Simulator "Landscape" assertion (not rerun after a reboot).

## Google sign-in return and expired AI key message — 2026-10-23 UTC (TestFlight 87, iOS and Mac uploaded)

Owner report on iPad build 86: Google sign-in returned to the sign-in screen with no message; a figure AI Explainer read
"The AI service couldn't finish this answer". Staging logs: every native Google attempt since 10-04 got a code from
Supabase and never exchanged it; the iPad now hands a `sciencereader://auth/callback` that reaches the app's link
handler to the open Google attempt (PKCE still binds it) and says so when Google doesn't finish
(NATIVE_AUTHENTICATION.md). Not yet confirmed on a device. The explainer failure was the staging OpenRouter key expiring
(401 "API key expired") between 14:44 and 19:47 UTC; a 401 now reads "AI answers are unavailable right now" (server part
deploys with the replacement key, an owner step). TestFlight 87 carries both app changes; `npm test`, import acceptance
15/15.

## Figure AI Explainer "couldn't finish": the staging OpenRouter key expired — 2026-10-23 UTC (branch only; not deployed or released)

Owner, build 85/86 on iPad, 2026-10-23: "I did the AI Explainer on iPad for a figure, it says the AI Service couldn't
finish this answer". Staging, read-only: three figure walkthroughs (Gemini Flash, low) at 19:47–19:50 UTC, each rejected
by OpenRouter in under 0.4 s with HTTP 401 (`chat_provider_rejected`, reason `authentication`; nothing charged, no
provider cost). OpenRouter's key endpoint answers the configured `OPENROUTER_CHAT_API_KEY` (same digest in
`.env.providers` and the staging secret) with "API key expired"; the last success was 14:44 UTC. Not a code or request
change: every cloud model route on staging (chat, figure, equation, paper explainer, Study, tags, podcasts, the browser)
fails the same way until the owner creates a new key without an expiry (or a later one), puts it in `.env.providers`,
and sets it on staging and the pipeline worker. Hardening on branch `fix/openrouter-key-auth-blame`: a 401 from the
gateway is answered like A13's 402 (`service_unavailable`, `retry_after: 300`, log `chat_provider_authentication`),
and the apps and browser word `service_unavailable` as "AI answers are unavailable right now. Try again in a few
minutes." instead of the generic "couldn't be completed". Evidence: `npm test`; Core `swift test --filter ChatStream`.

## Browser: where credits come from, said plainly — 2026-10-23 UTC (app.gradstep.ai deployed)

Owner, 2026-10-23, after asking what happens to someone using the web without an iPhone: "add messages where needed to
clarify." Every place the browser sends a reader to buy (free-AI refusals, chat, podcasts, recommendations, credit-blocked
imports, the composer balance's tooltip) now uses one sentence, `WHERE_TO_BUY` in `apps/web/src/lib/account-summary.ts`:
credits can't be bought on the web yet; with an iPhone, iPad or Mac, credits added in the Gradstep app work here right
away. Settings › AI credits has a new row, Add credits · Not on the web yet. The library's credit-blocked pill reads
"Needs credits" (was "Get credits in the app"). Web checkout (Stripe or a merchant of record) is not built; the
recommendation given to the owner is to add it at public launch, with web-only sign-up. Evidence: `npm test`; Playwright
account-assets and pricing 17 passed; deployed bundle checked for the new row.

## Browser UX audit, first release — 2026-10-22 UTC (app.gradstep.ai deployed)

Owner: the web "seems extremely cluttered with an inconsistent placement of buttons and styling". Four audits (web reader,
other web screens, CSS inventory, iPad/Mac) are in the session scratchpad; decisions in DECISIONS.md "Tall and Wide
layouts, two slots". Deployed to app.gradstep.ai (verified the served bundle carries the new code):
- Styling foundation: `tokens.css` (one colour set per theme, type/spacing/radius/layer/motion scales) with a lint guard in
  `test:fast`; every button has hover/press/focus; one menu, chip, segmented, banner and dialog look; information
  dialogs close with ✕, task dialogs have Cancel + verb.
- Search (owner's bug: typing while reading showed nothing): a Papers list in the left panel; a result opens in the middle
  and the list stays; Esc restores the panel. Library and Feed have one ⋯ each (Add paper first); a Settings window
  replaces the 23-row account menu.
- Reader: selection actions are a capsule at the selection (Explain · Save snippet · ⋯, right-click too); the figure,
  equation and paper AI Explainer pages cover the paper iPhone-style; the find bar floats; no balance line under the
  composer; starters stable; about 25 audit bugs fixed.
Evidence: `npm test` 731 pass, build passes; Playwright desktop/phone on the touched specs 211 passed, 3 failed — reader
"live tags…" (fails identically on the base commit) and one flaky library-window phone run (passed 3/3 on re-run).
Not yet: the Tall/Wide single-row, two-slot layout on the web (iPad first, in a branch); an empty grey strip above the
figure page's message box.

## iPad Wide: owner corrections after TestFlight 88 — 2026-10-23 (branch `ipad-slots-2`, not merged)

DECISIONS.md "iPad Wide: owner corrections after TestFlight 88"; DESIGN.md › Tall and Wide. The places button in the
window's top-left corner (the leftmost slot's row starts after it); a double tap on the divider lets the list (or the
companion) cover the window, with a grabber at the far edge, and picking from it splits again; the divider drag is live
(both slots follow the finger, the closing slot dims past its minimum), and on iPad the paper keeps the paragraph at its
top through every width change; turned upright, the Library's open paper (or the Feed's picked article) is centred in the
Tall list and tinted, the tint fading like the figure outline. Evidence: Core `swift test` 437 (Swift Testing) + 33
(XCTest) pass; iOS (iPad Pro 13" Simulator) and Mac Catalyst builds; `IPadShapesJourneyTests` 15/15 on the iPad Pro 13"
(M5) Simulator after a Simulator reboot (⌘1 in the places test failed twice on a stale Simulator, then passed);
`ReadingModeTests` and `PaperPassageTests` (reader bridge) pass; the turning test then passed for both the List and the
Table. Live drag on the Simulator: the paper reflows each frame at about 45–55 fps with two or three hitches of up to
~150 ms a second, the same paragraph kept at the top. Not measured on a device; VoiceOver's reading of a covered slot not
checked with VoiceOver itself (XCUITest still lists the covered slot's UIKit-hosted elements). Screenshots:
`.artifacts/ipad-slots-2/`.

## iPad Wide: places menu and each place's own two slots — 2026-10-23 (branch `ipad-places-menu`, not merged)

The owner's direction of 2026-10-23 for the iPad sideways (DESIGN.md › Tall and Wide; DECISIONS.md "iPad Wide: a places
menu…"): the places menu in the top-right corner, Library | paper, Feed | abstract, Paper promoted with the list toggle
and its companions on its right, draggable remembered dividers, the paper's controls floating. Tall, the Mac and the
web unchanged. Evidence: Core `swift test` 437 pass; iOS (iPad Pro 13" Simulator) and Mac Catalyst builds;
`IPadShapesJourneyTests` 13/13 on the iPad Pro 13" Simulator; affected iPad journeys pass (ReaderNavigation tablet
landscape, ReadingMode 3/3, Notes wide, Passage tablet split, Workflow Browse/Ask and split chat).
`LibraryLayoutTests/testTableSortsByColumnHeadersAndOpensAPaper` fails on the fixture's tag values ("Preference
optimization" where it expects "Alignment, RLHF"), not on layout; not yet compared with `main`. Not yet seen by the owner
on a device. Screenshots: `.artifacts/ipad-places-menu/`.

## iPad Tall and Wide, second pass — 2026-10-23 UTC (TestFlight 85, iOS and Mac uploaded)

Merged to `main` and uploaded as TestFlight build 85 (iOS and Mac). Gates on the merge: `npm test` passed, import
acceptance 15/15. Not yet reviewed by the owner on a device. The browser's figure and equation pages also lost the grey
strip above the message box (the contextual chat now uses the page's background and shows no transcript before the
first message; figure-view and equation-view journeys 69 passed; deployed to app.gradstep.ai, served stylesheet checked).


On top of the merged Tall/Wide work: no bottom band or reserved room on Wide (the page's own CSS gives the room after
its end, which also removed a light strip the scroll-view inset drew); the page on the app's background in Wide (no dark
seam with the chat); All chats as a clock in the Wide row; figure pages from Contents in the left slot keep Snippet, Chat
and AI Explainer; Continue in Chat hands the explainer's frame to the chat while the paper glides left (one shared
frame; no motion with Reduce Motion). Not yet: Settings as Sections | Page, the Mac's own Wide step. Evidence: Core
`swift test` 437 pass; `IPadShapesJourneyTests` 8/8 on the iPad Pro 11" Simulator and 8/8 on 13" across runs (Browse
failed once on 13" waiting for the paper, passed on rerun); iPhone 17: ChatHistoryTable 6/6, the Tall gallery,
`PassageJourneyTests` portrait passes after the journey closes Settings with Done (it tapped the tab bar under the
sheet). `ReaderNavigationTests/testReferenceActions…` fails at "the cursor is in the message box" on this Simulator
identically on 37345457 (before the Tall/Wide merge), on the merge and on this branch: environmental, not this change.
Screenshots (upright): `.artifacts/ux-audit-20261022/ipad-shapes/`.

## iPad Tall and Wide — 2026-10-22 UTC (merged)

The owner's "One app, two shapes" and "Two slots, a few views" for the iPad. Tall (upright, any window under 900 × 600 or
taller than wide) is the iPhone app; Wide (sideways) has one 52 pt top row with the places capsule and two slots on one
container (Read, Browse, Navigate, Explain, Discuss, Chats; Snippets as Collections | Collection). Spec: DESIGN.md "Tall
and Wide". Mac: the toolbar's five places only.

## On-device PDF route on publishers' PDFs: ten rules, text recognition, a longer recogniser cache — 2026-10-23 (TestFlight 86, iOS and Mac uploaded)

Merged to `main` and uploaded as TestFlight 86 (iOS and Mac) with the iPad second pass. Gates on the merge: `npm test`,
import acceptance 15/15, Core `swift test` 437 passed. Not yet measured on a phone.

Owner, 2026-10-22: "if it works it will be a big unlock for non arXiv papers." Full measurements:
[review](reviews/DEVICE_PDF_ROUTE_20261023.md); design: [DEVICE_PDF_ROUTE](architecture/DEVICE_PDF_ROUTE.md#non-arxiv-layouts--port-revisions-69-2026-10-2223).

- **New evaluation set**: 31 open-access venue PDFs (ACL, CVPR, ICML/AISTATS, NeurIPS, JMLR, ICLR, SciPost/TACL/Quantum)
  scored against the same papers' arXiv HTML, with their arXiv PDFs as a control (local research copies on the Mac,
  manifest with sources and licences); 7 PDFs with no arXiv version reviewed from screenshots; 4 scanned copies. The
  harness (`scripts/device-route-accuracy.mjs`) adds per-template scores, a control PDF (`--pdf`), a shared-content text
  F1, and scores the truth's formulas through Temml like the device's; replays merge records (`--also`).
- **Converter port revision 9**: ten rules on in the app (`DeviceModelReading.rules`): equation numbers out of the
  recogniser's crop (shown as the tag), overlapping displays as one, line bands (no more interleaved lines), font aliases
  (MathDesign, mathabx, PLOS's renamed Computer Modern), caption math, word gaps for justified/tracked text, bibliographies
  without a heading, display punctuation, text accents, first-page venue notices. The display gate stays 0.95.
- **Host**: a page with an empty or unreadable text layer is read by Vision's on-device text recogniser
  (`DevicePDFOCR.swift`, `Options.ocrFallback`); the host forwards any converter rule (and `name=number` options).
- **Recogniser**: the same weights exported with a 512-token decoder cache (`texteller-ft-v4-mf8-int8-l512`, desktop CPU
  export; `scripts/device-models.mjs` and the lock updated): cut-off recognitions read whole, all others unchanged; display
  glyph-right +0.010 to +0.013; decoder step +13 %, a batch's state 0.41 → 0.51 GB. No fine-tune was run; the review has
  the plan (display boxes first, then training crops cut the way the app cuts them).
- **Results** (before → after, the 512-token recogniser included): arXiv test text F1 0.857 → 0.890, display glyph-right
  0.801 → 0.892 (typeset precision 0.924 → 0.976), inline found 0.777 → 0.841; dev 0.876 → 0.896, displays 0.775 → 0.902;
  venue text F1 0.795 → 0.844, shared-content 0.872 → 0.899 (the arXiv PDFs of the same papers: 0.898), displays
  0.533 → 0.622; a CVPR PDF with no usable text layer 0.00 → 0.51; scans from no text at all to text F1 0.82.
- Evidence: `npm test` passes; `swift test --filter DevicePDF` 18 tests pass; the Mac Catalyst app builds; Simulator
  `DeviceModelJourneyTests` (iPhone 17 Pro) passes. Not verified: any iPhone (paused); timing on a quiet machine (the Mac
  was shared throughout); the 512-token recogniser on a phone (state memory on 6 GB devices).

## TestFlight 84, browser and admin release — 2026-10-22 UTC

iOS and Mac build 84 uploaded (the Mac archive was retried once after a derived-data permission error); browser and
admin redeployed. Adds since 83: the Your AI usage credits ring under All (owner's build-82 feedback), a figure part's
label no longer repeats its type ("Concept · Concept", build-83 feedback). Admin: Continue with Google for operator
accounts made with Google or Apple (the owner's account is Apple-only with no password); `https://admin.gradstep.ai`
added to staging Auth's redirect allow list (workflow check updated). Apple web sign-in still lacks a Services ID
secret. Gates: `npm test` passes; Core `swift test` 437 pass; iPhone 17 `AIUsageJourneyTests` 3/3; import acceptance
15/15. Not verified: an owner Google sign-in end to end, iPad/Mac journeys, physical device (paused).

## Credits by activity in Your AI usage — 2026-10-22 UTC (apps and browser local, not released)

Owner, build-82 feedback: "The very top before the list when on All a pie chart summarizing the cost types and their
cost." Your AI usage › All now shows a thin ring of the period's credits by activity under the totals line, with a
legend (name, credits, share); a segment or legend row chooses that activity's chip; Other gathers activities under 4%
or past the fourth. iPhone/iPad/Mac (`Views/AIUsageRing.swift`, Swift Charts) and the browser (`UsageRing`, inline SVG).
No server change: the slices come from `v1_ai_usage`'s per-activity totals. Decisions:
[DECISIONS](DECISIONS.md#your-ai-usage-owner-request-2026-10-22-agent-decisions-reversible); spec: DESIGN.md "Credits by
activity". Evidence: `npm test` passes; Core `swift test` AIUsageTests 7/7 (`theRingIsTheBrowsers` against the shared
fixture); Playwright `ai-usage.spec.ts` desktop + phone 6/6 (light and dark); iPhone 17 Simulator `AIUsageJourneyTests` 3/3
(the ring's words, legend chooses the chip, none when filtered or empty; the list check now scrolls to rows the ring
pushes below the fold); Mac Catalyst builds; Core `swift test` 437 pass. Screenshots `.artifacts/ai-usage-20261022/*-ring.png`,
`.artifacts/ai-usage-ring-native/`. Not verified: iPad and Mac journeys, physical device (paused).

## TestFlight 83 and browser release — 2026-10-22 UTC

iOS and Mac build 83 uploaded; browser redeployed. Adds since 82 (owner's build-82 feedback): the paper AI Explainer's
one Key concepts card, its cards (with ¶ links and the drawn diagram) carried into Chat by Open in Chat, summaries that
never stop mid-word, minimal reasoning on Gemini (staging summary 16 s → 6–8 s); Download your assets (a .zip built on
the device) and the Snippets row's chevron. Gates: `npm test` passes; Core `swift test` 436 pass; iPhone 17 Simulator
`StudyExplainerJourneyTests` 3/3 and `AssetsExportJourneyTests` 1/1 pass on merged main; import acceptance 15/15 on the
uploaded source. Not verified: iPad/Mac journeys, physical device (paused).

## Paper AI Explainer, build-82 feedback: Key concepts, cards in Chat, no cut-off summary, faster on Gemini — 2026-10-22 UTC (server on staging; apps and browser local, not released)

- **Server (staging):** `chat` deployed 15:08 UTC from this branch (base `50dd3c50`): Gemini explainer at `minimal`
  reasoning, summary under 450 characters asked, sentence-boundary bounding (`boundedText`), "never a background concept
  again" in the prompt. Backup `.artifacts/backups/20261022T150936Z-f688225d1a67` (taken just after the deploy; the
  worktree's own backup attempt failed on a missing local file; no database change). Deploy suites 18 passed;
  `budget.health` fails on the existing 82% of October's $40.
- **Live (staging, DPO, Gemini):** summary 6.0 / 8.4 s, whole 11.9 / 13.9 s, 2 credits each (was 16.3 / 21.3 s).
  Model alone: `minimal` first words 2.1–3.3 s in 5/5 runs vs `low` 1.5–33.8 s (CHAT.md "Build-82 feedback").
- **Apps and browser (local):** one "Key concepts" card with Background / This paper markers; Open in Chat shows the same
  cards (summary, concepts with ¶ links, drawn diagram); progress says "the key concepts".
- **Evidence:** `npm test` passes (new backend tests: minimal reasoning and its quote, bounded summaries, the streamed
  summary bounded the same); Core `swift test` 433 pass; iPhone 17 Simulator
  `StudyExplainerJourneyTests/testThePaperExplainerStreamsCitesDrawsAndOpensInChat` passes (now also checks the cards,
  ¶ link and drawn diagram in Chat); Playwright `paper-explainer.spec.ts` desktop and phone pass (also checks the cards in
  Chat). Not run: iPad and Mac journeys, physical device (paused).

## Download your assets — 2026-10-22 UTC (apps and browser local, not released)

Owner, build 82: "Need a download assets button". Decisions:
[DECISIONS](DECISIONS.md#download-your-assets-owner-build-82-built-not-released).

- **Apps:** Settings › Your assets ends with **Download your assets** (ⓘ: what is in it; downloaded papers aren't).
  `AssetsExporter` gathers this device's chats, diagrams, every snippet collection (images decrypted here, downloaded
  encrypted only when missing) and the explanations kept here; `AssetsExport` (Core) writes the files and the zip off the
  main thread; progress shows "n of N snippet images"; what was left out shows under the row and in the README. Share
  sheet on iPhone/iPad, save panel on the Mac. The Snippets row now has a chevron like the rows around it.
- **Browser:** account menu › Your assets › **Download your assets** opens a small dialog (what is in it, progress,
  "Downloaded …", what was left out); the zip is the same format, made by `lib/assets-export.ts` from
  `lib/assets-export-gather.ts`; `NotesStore.imageBytes` gives the verified bytes the image URLs already used.
- **Evidence:** `npm test` passes (browser units include `tests/assets-export.test.ts`: the shared fixture's files and zip
  SHA-256, the zip read back, names, empty export); Core `swift test` 436 pass, `AssetsExportTests` produces the same
  files and the same zip SHA-256 as the browser from the same fixture; `unzip -t` and macOS `ditto` open the fixture zip;
  Playwright `assets-export.spec.ts` desktop and phone pass (the downloaded zip has README first, the collection with its
  comment, and a decrypted PNG/JPEG; no remote request), `account-assets.spec.ts` updated and passing; iPhone 17 Simulator
  `AssetsExportJourneyTests` passes (share sheet offered, the zip's paths include the collection, no PDF); Mac Catalyst
  builds. Not verified: physical device (paused), iPad and Mac UI journeys, very large exports (the zip is built in
  memory; snippet images are at most 2 MB each).

## Study mode reworked, the paper's AI Explainer, App Store pricing applied — 2026-10-22 UTC (server, browser and TestFlight 82 released)

- **Study mode** (owner: "too complex"): "Enter Study Mode – Quiz me and help me learn" is a starter in an empty paper
  chat and always the last suggestion after an answer. Studying is the paper chat with a tutor that asks one question at
  a time and backs off when the reader asks for an explanation; a slim row above the composer offers Hint · Explain
  instead · Stop. The tutor's hidden notes on the reader (`study_state`) ride in the answer and are filtered out of what
  the reader sees; the old study map, its tool call and the Study screens are gone (old builds' map requests are
  accepted and ignored).
- **The paper's AI Explainer** (paper ⋯ › AI Explainer): In short, Background and Key ideas with ¶ links ("Back to AI
  Explainer" after a jump), a concept diagram, its own conversation with Open in Chat; streamed with the explainers'
  progress bar; kept per paper revision and model (Settings › Your assets › Paper explanations). Settles as an ordinary
  answer (no migration); Your AI usage lists it as Chat.
- **Visual suggestions:** a generic "draw a diagram / visual explanation" suggestion only when the model offered no picture.
- **Free AI refusals** in both paper explainers (browser and apps), as in chat, figures and equations.
- **Server:** chat function deployed 13:40 UTC from main `c8768872` (pricing switches and Study mode together) after
  backup `.artifacts/backups/20261022T133918Z-98774b4e5c63`; deploy suites 18 passed, `budget.health` fails on the
  existing 81% of October's $40.
- **Live (staging, DPO):** Sonnet: summary 3.7 s, first entry 4.5 s, whole explainer 13.2 s, 47 credits ($0.23, mostly the
  one-hour cache write of the paper). Gemini Flash low (the default): summary 16.3 s, whole explainer 21.3 s, 2 credits.
  Streamed entries equal the final ones in both.
- **Browser:** deployed to app.gradstep.ai (Pages `f67bba68`).
- **TestFlight 82:** iOS and Mac uploaded after import acceptance 15/15 on the uploaded source.
- **App Store Connect (owner approved, "I approve"):** `asc-pricing-plan.mjs --apply --owner-approved=2026-10-22` made the
  8 API changes; read-back matches (Plus $7.99 + $3.99 first month, Plus yearly $79.99, Pro 2,000 credits, Pro yearly
  $199.99, packs 300/700). Manual steps left: OWNER_ACTIONS 13.
- **Evidence:** `npm test` passes; Core `swift test` 433 pass; iPhone 17 Simulator `StudyExplainerJourneyTests` 3/3 pass
  after the merge. The branch's agent reported the journeys on iPad Pro 13 and Mac Catalyst before the merge; not rerun.
  Known older failures, unrelated: ChatVisualTests consent v5, two Podcast length-limit tests, LibraryModelTests (local
  artifacts), ChatControlsTests (expects DeepSeek in the picker). Not verified: physical device (paused).

## Pricing accepted: free AI pool, plans, Spend vs income, alerts, owner switches — 2026-10-22 UTC (server and admin on staging; apps and browser local, not released)

Owner: "I will take your defaults", then "the complexity of the pricing system and what debug strategies I'll have if my
spend somehow becomes very high in relation to my incoming money." Plain-language overview:
[PRICING_HOW_IT_WORKS](PRICING_HOW_IT_WORKS.md); operator steps: [RUNBOOK_SPENDING](RUNBOOK_SPENDING.md); decisions:
[DECISIONS](DECISIONS.md#pricing-accepted-with-safeguards-against-spend-outrunning-income-owner-2026-10-22-built-staging).

- **Server (staging):** migrations **0150** (free AI pool on the existing hold machinery, accepted products and annual
  months, `ai_controls` switches, Spend vs income, alerts with a 10-minute pg_cron/pg_net tick) and **0151** (Sandbox
  purchases reported as test money). Applied 06:41 and 06:48 UTC after encrypted backups
  `.artifacts/backups/20261022T064011Z-eeffccb218a0` and `20261022T064745Z-580cc1b48cea`. Chat function deployed 06:45 UTC
  from this branch merged with main (figures default Gemini, streamed equations kept): switch refusals before any hold,
  no web search on free answers, Gemini defaults under "cheaper models only". Resend key stored in Vault; alerts go to the
  owner account's address (no `OWNER_ALERT_EMAIL` set). Deploy suites: 18 passed; `budget.health` fails on the
  existing 81% of October's $40 (not raised).
- **Admin (staging):** Admin › Spend vs income (Pages `faa47296`, admin.gradstep.ai): headline figures, spend by
  funding/feature/model, estimated proceeds by product, free pool with audited resize, seven switches with a 7-day
  preview and two-step confirm, alerts with delivery state.
- **Live read-only checks (06:50 UTC):** ledger ends 0150, 0151; `ai_controls` at the accepted defaults; seven products
  (Standard 600/$7.99/intro $3.99, Pro 2,000, yearly plans, 300/700 packs, 400 kept); the first tick raised **50% and
  80%** for October ($32.32 of $40) and sent one digest, Resend answered **200**; October spend by funding: granted $11.53,
  Sandbox purchases $4.48, platform $3.38, your testing $1.49, free $0 (no free-tier account exists yet: 50 of 51 open
  accounts are synthetic checks, the other is the owner's testing allowance).
- **Apps and browser (local):** Settings › AI credits gains **Plan** with the ⓘ explainer and **Free AI this month**; the
  free-AI messages replace "not enough credits" where they explain it (chat, figures, equations, recommendations); new
  products listed (StoreKit shows those on sale); Standard shows as Plus; `model_unavailable` reworded. Browser parity in
  the account menu.
- **App Store:** nothing changed. Read-only plan `node scripts/asc-pricing-plan.mjs`
  (`.artifacts/pricing/asc-plan-readonly-20261022.txt`): 8 API changes and 5 manual steps await the owner (OWNER_ACTIONS 13).
- **Evidence:** `npm test` passes (backend incl. new chat switch tests, browser units incl. `free-ai.test.ts`);
  `npm run test:database` passes (834 steps; `free_ai_and_spend.sql`, the 12-reader pool concurrency check: 4 admitted,
  free worst case $0.48 ≤ $0.50 pool); Playwright `pricing.spec.ts` and `account-assets.spec.ts` desktop/phone 17 pass;
  admin loopback journey `scripts/check-spend-income.mjs` passes (`.artifacts/spend-income/`); native Core `swift test`
  416 + 28 pass, app unit tests 42 pass, iPhone 17 Simulator journeys `testPlanAndFreeAIInSettings` and
  `testAnAnswerRefusedWhenTheMonthsFreeAIIsUsedUp` light/dark pass (`.artifacts/pricing-native/`), Mac Catalyst builds,
  test build after merging main succeeds. Not verified: physical device (paused), iPad/Mac UI journeys, a real
  Production purchase, inbox delivery of the alert (Resend accepted it).
- **For other branches:** the paper explainer's migration was dropped instead (it settles as an answer); see the Study
  mode entry above.

## Full screen on touch; equation explainer streamed; figures default Gemini again — 2026-10-22 UTC (server on staging; apps and browser local, not released)

Owner: "when you try to click into a subfigure and zoom. The transition needs to be improved … whenever you try to interact
with it, it becomes a full screen thing, with the outline fading away … with not really any in-between … the equations AI
explainer needs the same progress with the progress bar"; later: "Let's try Gemini instead of Sonnet for Figures then."
Design: [FIGURE_VIEW.md "Full screen on touch"](architecture/FIGURE_VIEW.md#full-screen-on-touch--2026-10-22-apps-and-browser-local-not-released),
[EQUATION_VIEW.md "Streamed explanation"](architecture/EQUATION_VIEW.md); decisions:
[DECISIONS](DECISIONS.md#equation-explainer-streamed-figure-parts-full-screen-on-touch-owner-request-2026-10-22-agent-decisions-with-evidence-reversible),
[figures default](DECISIONS.md#figures-default-gemini-flash-again-owner-decision-2026-10-22-deployed-to-staging-clients-local).

- **Server (staging; no migration).** Equation symbols stream (`equation_progress`, `equation_summary`, `equation_symbol`;
  final `equation` unchanged), read by `JsonListStream` (now shared with the figure walkthrough); symbols at low effort for
  Gemini/auto; `default_figures` = Gemini Flash (run at low). Chat function deployed 04:46 UTC (backup
  `.artifacts/backups/20261022T044455Z-d8a4cfd1ad90`, deploy suite 19/0); the study-mode agent's 05:12 deploy carried the
  equation streaming; redeployed 05:58 UTC from that deployed build plus the figures default (backup
  `…/20261022T055356Z-4a3671a898cc`), so neither change undoes the other. Suite at 05:55: 18 pass, 1 fail —
  `budget.health`: the staging platform budget is at 80 % ($32.08 of $40 this month; unrelated to this code). Read back:
  `GET chat` publishes `default_figures` Gemini; live equation runs stream.
- **Live, before → after** (DPO's loss, staging, disposable accounts): the default (Gemini) showed nothing for 9.3–12.3 s
  then everything; now the summary at 2.9–5.9 s, first symbol 3.3–6.5 s, everything 6.5–8.9 s, same 2 credits. Sonnet low:
  summary 3.0–4.2 s, everything 7.7–8.5 s, 4 credits warm / 45 with its cache write. Model alone: EQUATION_VIEW.md "Speed".
- **Apps (iPhone/iPad/Mac) and browser:** part cards (and the apps' whole-figure card) open full screen on any touch in one
  motion from the card (matched geometry; outline fades over ~1 s; double tap whole ↔ part; close back onto the card;
  Reduce Motion cross-fade); streamed equation symbols under the shared progress bar with placeholders; framing record
  `opened`/`opens`; figures default Gemini with the Sonnet default let go once; new figures ⓘ text.
- **Evidence.** `npm test` passes (backend 717; browser units incl. new `equation-progress`, `equation-stream`, updated
  `figure-framing-record`, `figures-default`); `swift test` filters `EquationViewTests|FigureProgressTests|FigureViewTests|
  FigureFramingTests|ChatProfilesTests` pass; app `FiguresDefaultTests` 3/3 and `FigureViewAppTests` pass (iPhone 17 Pro
  Simulator, iOS 26.4). Native journeys on that Simulator, one at a time: `testTouchingAPartOpensFullScreenFromItsCard`
  light and dark (pass; the dark one also failed once at launch on "The paper is ready" while a screenshot loop ran, then
  passed), `testEquationSymbolsStreamWithAProgressBar` light/dark, `testAnOlderServersEquationSymbolsStillShow`,
  `testEquationViewDescribesSymbolsAndLeadsToThePaperAndTheChat`, and the existing `testExplainWalksThroughAFigure…`,
  `testPartsAreFramedByConfidence…` (updated: a tap opens full screen on the part) and `testTheWalkthroughStreams…`.
  Playwright: `figure-view.spec.ts` desktop + phone 29 pass / 5 skip (real-paper cases need `.artifacts/reader-sweep`;
  the mid-transition rectangle check is Chromium-only); `equation-view.spec.ts` desktop + phone 18 pass. Mac Catalyst:
  the app builds for Mac Catalyst (unsigned compile; its journeys were not run).
- **Screenshots (reviewed).** Native: `.artifacts/figure-fullscreen/native/` — `{light,dark}-opening-start-on-the-card.jpg`,
  `{light,dark}-opening-mid-transition.jpg`, `{light,dark}-closing-mid-transition.jpg` (Simulator frames with the motion
  slowed 40×), and `light/`, `dark/` (card, settled with outline, outline faded, whole figure); `.artifacts/equation-progress/native/shots/`
  (bar and placeholders, mid-stream, done; light/dark; older server). Browser: `.artifacts/figure-fullscreen/web/`
  (opening start, mid-transition, settled with outline, faded, whole, reduced motion; desktop and phone, light/dark) and
  `.artifacts/equation-progress/web/`.
- **Spend:** ≈ $0.87 of the $1 allowed (EQUATION_VIEW.md "Speed").
- **Not done / open:** TestFlight and the browser deploy (not asked); physical phone (paused); iPad and Mac journeys of the
  new full-screen viewer not run (Mac builds; it keeps its window-sized sheet and fades instead of moving from the card).
  A later deploy of the chat function from a branch without commit "Figures default back to Gemini Flash" would put
  Sonnet back as the published figures default.

## Your AI usage — 2026-10-22 UTC (server on staging; apps and browser local, not released)

Owner: "a table of my recent AI token spend for all the different activities … each row being an activity, and the exact
cost, so that a user can figure out where their credits are going." Settings › AI credits › Your AI usage (and Get
credits, including its Unlimited testing page; browser account menu): one row per metered request, newest first, with
activity, the paper's title from this device's library, model, tokens, credits; Stopped / Didn't finish · not charged /
In progress / Free labeled; parts on opening a row; activity chips, period in ⋯, totals, ⓘ; 25 a page, more on
scrolling. Credits and tokens only (no dollars: OWNER_ACTIONS #12). Design: [Operations](architecture/OPERATIONS_AND_BILLING.md#your-ai-usage--2026-10-22).

- **Server (staging):** migration `202610220144_account_ai_usage.sql` (`v1_ai_usage`, read only; rate rule
  `account-usage`) applied 05:43 UTC by `scripts/deploy-staging.py staging --functions` (no function changed) after the
  encrypted backup `.artifacts/backups/20261022T054157Z-a9f669e7a1b6` (25 objects, 10.3 MB database). Deploy checks 17
  pass, 3 skip, 1 warn, 1 fail — the fail and warn are the month's provider budget already at 80 % ($32.08 of $40 spent
  before this change; `budget.health`), unrelated to it.
- **Live read-back** (`node scripts/ai-usage-live-check.mjs`, record `.artifacts/ai-usage-20261022/live-check.json`): a
  disposable account asked one general question on Haiku 5.5 (low, brief, no title/suggestions; 970 in / 4 out tokens,
  ≈ $0.001 provider cost, 1 synthetic credit); `v1_ai_usage` returned exactly that operation — chat, completed, 1
  credit, `anthropic/claude-haiku-5.5`, the same tokens — with totals; a second disposable account saw nothing; anonymous
  (401) and a bad query refused; both accounts deleted through account-delete.
- **Evidence (local):** `npm run test:database` passed (95 s; `tests/database/account_usage.sql`: own rows only, a second
  and an empty account see nothing, activities/outcomes/parts/tokens, three keyset pages without gaps, totals, filter,
  window, closed account refused, read only); `tests/backend/ai-usage.test.ts` 5/5 (every chat action, route and kind
  named; server and both clients' names identical; no dollar or private fields); browser `ai-usage.test.ts` 5/5 and Core
  `AIUsageTests` 6/6 against the shared `tests/fixtures/ai-usage.json`; Playwright `ai-usage.spec.ts` desktop + phone 6/6;
  native `AIUsageJourneyTests` on an iPhone 17 Pro Simulator (run one at a time). Screenshots:
  `.artifacts/ai-usage-20261022/` (`usage-iphone-{light,dark}-{list,parts}.png`, `browser-{desktop,phone}-{light,dark}-{list,parts}.png`).
- **Not done:** iPad/Mac journeys (the wide column layout is built, not screenshot-checked), browser deploy, TestFlight,
  physical phone (paused). Requests made on another device show their activity without a paper (titles stay on the
  device that asked).

## Collapsible snippet cards — 2026-10-22 UTC (apps and browser local, not released)

Owner request: each snippet in a collection is its own card with the crop/quotation in a framed inner box; a chevron
collapses it to one line (time · short paper title · first words of the comment), remembered per device (never synced);
the collection's ⋯ adds Collapse all / Expand all. iPhone/iPad/Mac share the SwiftUI view; the browser matches it and
the shared fixture `tests/fixtures/notes/collapsed-lines.json`. Evidence: Core `NoteCollapseTests`, browser
`note-collapse.test.ts`, native `NotesJourneyTests.testSnippetCardsCollapseAndRemember` /
`testSnippetCardsDarkAndLargeText` (iPhone 17 Pro Simulator), Playwright `notes.spec.ts` desktop + phone; screenshots in
`.artifacts/snippets-20261022/`. Not run: iPad/Mac journeys, physical device (paused). Details:
[Notes and snippets](architecture/NOTES_AND_SNIPPETS.md#collapsible-snippet-cards-owner-2026-10-22-local-source-not-released).

## TestFlight 81 and browser release — 2026-10-22 UTC

iOS and Mac build 81 uploaded; browser redeployed. Adds since 80: the streamed figure walkthrough (summary and each
validated part as they arrive; final walkthrough still sent for older builds), the figure progress bar (stages, part k of N
only when N is known, never backwards), Sonnet 5.5 at low effort as the figures default, low effort for figures on
Gemini/auto and no thinking on DeepSeek. Live on staging before release: summary 3.6–4.5 s and full walkthrough 10–12 s on
Sonnet (was 14–24 s with nothing shown on the old Gemini-medium default); details in FIGURE_VIEW.md "Speed". Gates:
`npm test` passes; import acceptance 15/15 on the uploaded source. Not verified: physical device (paused).

## Figure explainer: streamed, faster, with a progress bar; figures default Sonnet — 2026-10-22 UTC (server on staging; apps and browser local, not released)

Owner: "very very slow … unusable at this speed. Also it needs a progress bar"; then "change the default to Sonnet for
that one". Design and measurements: [FIGURE_VIEW.md "Speed"](architecture/FIGURE_VIEW.md#speed-a-streamed-walkthrough-at-low-effort-with-a-progress-bar--2026-10-22-server-on-staging-apps-and-browser-local-not-released);
decisions: [DECISIONS](DECISIONS.md#figure-explainer-streamed-at-low-effort-owner-request-2026-10-22-agent-decision-with-evidence-reversible).

- **Server (staging, chat function deployed 02:17 and 02:50 UTC after an encrypted backup
  `.artifacts/backups/20261022T021542Z-9d899fdbba30`; deploy suite 19 pass / 0 fail both times; no migration):** the
  walkthrough is written as JSON in the reply and streamed part by part (`figure_summary`, `figure_section`,
  `figure_progress`), each part checked as the final `figure` is (unchanged for older builds); figure actions at low
  effort for Gemini and automatic effort; DeepSeek at low without thinking; `default_figures` = Sonnet low in the
  published table; the paper's membership read overlaps the balance check.
- **Live, before → after** (DPO, as the apps send it): Gemini (the previous figures default) 24.1 s and 13.8 s with
  nothing shown until the end → summary 7.2 s / 4.6 s, whole 15.4 s / 9.4 s; PRISM Figure 5 summary 6.7 s, four parts by
  15.6 s (the model alone took 45 s at medium). Sonnet low (new default): summary 3.6–4.5 s, whole 10–12 s, $0.022 a
  walkthrough on a cached paper ($0.24 when it first writes the paper). DeepSeek: medium (the owner's runs, 19–97 s) 23 /
  38 s → low without thinking 3.5 / 18.8 s. Cost per Gemini walkthrough $0.0115–0.0167 → $0.0081–0.0118.
- **Apps (iPhone/iPad/Mac) and browser:** progressive rendering, skeleton and an honest progress bar from shared rules
  (`FigureProgress.swift` / `figure-progress.ts`, one fixture), old-server compatibility, figures default from
  `default_figures` with a one-time migration of the old recommended Gemini choice, new ⓘ text.
- **Evidence:** `npm test` passes (backend 715 including new stream, effort, DeepSeek and default tests; browser units
  including `figure-progress`, `figure-view`, `figures-default`); `swift test` 412 pass (new `FigureProgressTests`,
  `FigureViewTests`, `FigureFramingTests`, `ChatProfilesTests`); app unit tests `FigureViewAppTests` (incl.
  `FiguresDefaultTests`), `UnsentDraftTests`, `ChatGenerationTests` pass on the iPhone 17 Simulator; Playwright
  `figure-view.spec.ts` desktop and phone 27 pass / 1 skip (streaming layout, reduced motion, older server), AI-options
  journeys pass; native `FigureViewJourneyTests` streaming light/dark and older server on iPhone 17, streaming on iPad Pro 13
  and Mac Catalyst, the existing walkthrough journeys on iPhone (5/5). Screenshots: `.artifacts/figure-streaming/`
  (browser) and `.artifacts/figure-streaming/native/`, reviewed. Live records: `.artifacts/figure-view/2026-10-22T02-*`,
  `.artifacts/figure-speed/`. Spend ≈ $0.92 of the $2 allowed.
- **Known:** `ChatControlsTests/testDefaultOptionsInSettings` fails at its last step (tapping the Chat tab while Settings
  is open; "New chat" not found) — reproduced identically on the code before these changes, so not caused by them. The
  Mac `FigureViewJourneyTests` no longer compiled (`pinch` is unavailable on macOS); that step is now skipped on the Mac.
  Not done: browser deploy, TestFlight, phone (paused). Open: Gemini's five-minute cache (a walkthrough after five idle
  minutes writes the paper again: +4–8 s); moving DeepSeek's pin to Together (2–3.5× faster, needs consent naming it) is
  a proposal for the owner.

## TestFlight 80 and browser release — 2026-10-22 UTC

iOS and Mac build 80 uploaded ~00:10 UTC (iOS VALID at the time of writing); browser redeployed. Adds since 79: figure parts
as confidence-framed viewports into the whole figure (tap to expand; local-only interaction record), "Extract the
subfigure" removed (server still accepts `figure_detail` from older builds), exact parts from arXiv multi-image figures
plus the count-disagreement fallback, the browser history-store revision fix (spurious local_storage on slow devices),
AI recommendations clients (server live since 2026-10-21), and the on-device PDF route speed/accuracy work (≈2.8× faster;
new batched recogniser in DeviceModels, lock updated). Gates: `npm test` passes; import acceptance 15/15 on the uploaded
source. Not verified: physical device (paused), iPad/Mac journeys after the final merges, device-route speed on a phone.

## On-device PDF route: faster, steadier, measured against arXiv HTML — 2026-10-21 (local source; not released)

Owner, 2026-10-21: keep developing the on-device model (too slow, not accurate enough); Mathpix is not built
([DECISIONS](DECISIONS.md#pdfs-without-arxiv-html-keep-developing-the-on-device-model-no-mathpix-owner-2026-10-21)).
Full measurements and before/after: [review](reviews/DEVICE_PDF_ROUTE_20261021.md); design: [DEVICE_PDF_ROUTE](architecture/DEVICE_PDF_ROUTE.md#development-after-the-port-kit--port-revision-5-2026-10-21).

- **Recogniser**: the same weights (texteller-ft-v4) exported as one multifunction package (`prefill`/`step` sharing one
  state, batch 8, int8; `scripts/device-pdf-models/export_texteller.py`; lock updated) — same tokens on its samples (a few formulas differ on whole papers), per-crop
  GPU cost about a fifth.
- **Host**: pages read ahead, recognition in the background in batches (converter port revision 5: `submit`/`collect`),
  a reading shown before its formulas are read (`onPreview`; the app keeps the reading place when the finished reading
  replaces it), and determinism restored (tagger and recogniser never predict at once; same PDF → same bundle under load).
- **Converter rules** on in the app (each kept only when it measured better on two separate 32-paper sets): simple
  inline formulas from the text layer (58 % of formulas never reach the recogniser), font-found math, tidied LaTeX,
  title page by metadata, no duplicate headings or contents lists, reference entries split, line ownership.
- **Results on 32 fresh papers (this Mac)**: whole conversion 4,263 s → 1,529 s (4.89 → 1.75 s a page, ×2.8; median paper 105 → 43 s), a reading on screen after a median 15 s; headings 0.905/0.725 → 0.920/0.765 (recall/precision), whole
  blocks 0.59 → 0.72, inline formula images halved, displays typeset 0.37 → 0.41; text F1 0.854 → 0.856. Display
  formulas (still mostly images) and tagger boundaries are the open accuracy problems; the renderer is not one.
- **Evaluation tooling**: `scripts/device-route-accuracy.mjs` (fresh arXiv papers scored against the app's own arXiv
  HTML reading), `scripts/device-route-replay.mjs` (converter rules re-run on recorded model outputs in Node),
  `DevicePDFRouteTool --bench-steps / --bench-recogniser / --check-determinism / --replay-converter / --record / --rules`.
- Evidence: `npm test` passes; `swift test --filter DevicePDF` (15 tests) passes; the Catalyst app builds; Simulator `DeviceModelJourneyTests` passes with the new converter (it failed twice under heavy machine load and passed on a rebooted Simulator on a quiet machine, so recorded as load-sensitive); fixture conformance with the new models (rules off) unchanged except a few formulas (LaTeX agreement within 0.004 either way; one rendered-formula flag on 2610.11253v1 now narrowly fails, 0.952 → 0.950). Not verified: any iPhone (paused; the iPhone figures in the review are estimates), the
  recogniser in the iOS Simulator (it never loads there; the route degrades to images, as before).

## Structure first and the count check — 2026-10-21 (local source; not released, not deployed)

Subfigure round 3's integration steps 1 and 3 on iPhone/iPad/Mac (one SwiftUI path) and the browser, from one set of
rules and shared fixtures. **Structure first:** a figure whose bundle entry has several images (15.7 % of arXiv figures)
gets exact parts from its own markup — images, "(a) …" sub-captions (else the caption's letters when they number the
images), each a full-width band of the unchanged composed image. The walkthrough request's selection is the caption plus
a short description of those sub-figures and bands, so the model's sections line up; sections are matched to sub-figures
by letter or label, by a box on one band (IoU ≥ 0.6), or in order when the counts agree, and a matched part is shown as
its band, tight (even without a box). **Count check:** two or more parts whose number is neither the caption's lettered
panels nor the figure's own sub-figures show the whole figure with the part outlined (score capped at 0.3); this replaces
the old "more parts than the caption: −0.3". Chat's figure parts use the same structure and check. Browser fullscreen no
longer squeezes a tall figure into the window height. No server, prompt, schema, storage or spend change. Design:
[FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Structure first and the count check".

Evidence (fixtures and Simulator only; no provider call, no deploy, no physical phone): `npm test` passes (backend,
browser units incl. new `figure-structure.test.ts`, 26 cases, and `figure-framing.test.ts`, 18 cases). Core
`swift test --filter "FigureStructureTests|FigureFramingTests|FigureCropCompletionTests"` passes: Swift reproduces every
structure, note, quote, section match (13) and framing case (18, six new on `stacked-subfigures.png`). Real paper:
2610.22353v1 compiled by the shipped device compiler (`reader-device-compile.mjs`, 22 images); all six multi-image figures
get a structure (Figures 1–3, 6, 7 lettered from sub-captions, including math in sub-captions; Figure 4 six images → the
first four, unlettered). Playwright `figure-view.spec.ts` + `arxiv-html.spec.ts`, desktop and phone: 25 passed, 1
pre-existing desktop skip, including the new real-paper journeys (the request's quote carries the structure; (a), (b)
boxed, (c) exact and tight at the band's aspect; grouped "(a) and (b)" + (c): the group whole and outlined, (c) exact).
iPhone 17 Simulator (iOS 26.4), one at a time: new `testARealMultiImageFiguresPartsAreItsOwnSubfigures` light and dark,
`testGroupedPartsOfARealMultiImageFigureShowTheWholeFigure`, and the existing walkthrough, two-plot crops and
framed-by-confidence journeys; app units `FigureViewAppTests`, `ChatVisualTests`, `FigurePartsRenderingTests` 9/9.
Screenshots (iPhone light/dark, browser desktop/phone light/dark, grouped, expanded): `.artifacts/figure-structure/`.
Not verified: iPad/Mac journeys (same SwiftUI path), a live model's answer to the structure note, physical device (paused).

## Flaky notes-store eviction test fixed — 2026-10-21 (local source; not released, not deployed)

Cause (product): browser `History.commit` planned against the journal revision, so this tab's own sync writes that add
no events (snippets marked uploaded, outbox acks, cached downloads, draft checkpoints) during sealing were conflicts;
three in a row surfaced as `local_storage` on a Save or sent message. Fix: plan against the event count (`expectedEvents`);
event writes still conflict. Eviction test holds the upload and awaits sync; new deterministic tests fail on old code.
Evidence: eviction test, 300 runs at 10-way concurrency: 5 `local_storage` failures before, 0 after; full browser tier
6×4 concurrent + 8 CPU hogs: 24/24 pass (also 0/24 failures before; tier rarely hits it); `npm test` passes.

## Extract the subfigure removed — 2026-10-21 (local source; not released, not deployed)

Owner: "Let's not do extract the subfigure … consistently create one good product experience in the AI result that comes
back." The walkthrough (summary + parts as viewports) is the single figure result on iPhone/iPad/Mac and the browser.
Removed from every client: the part-menu item "Extract the subfigure and more context", its loader, "Up close" card,
no-crop note, retry, framing/record surface, snippet source, request, event parsing, models, fixtures and journey steps.
Kept: Explain more simply (words under the part, in the walkthrough); no "more parts" request ever existed. Old kept
detail answers are hidden (native: never looked up, not listed in Your assets; browser: dropped on restore); no migration.
Server still accepts `figure_detail` from builds 63–79, marked DEPRECATED in `chat-figure-view.ts` / `chat.ts`, to be
removed once no supported build sends it; the live smoke no longer asks for it. Design: [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md)
"Extract the subfigure removed"; decision in DECISIONS.md.

Evidence (no provider call, no deploy, no physical phone): `npm test` passes (backend 698 including the deprecated
`figure_detail` cases, browser units 600); Core `swift test` 398 pass (new `extractTheSubfigureIsGoneButOldAnswersStillRead`:
no action, event ignored, an old sealed detail answer decodes and is not shown/listed); app units `FigureViewAppTests` +
`ChatVisualTests` 8/8; on a fresh iPhone 17 Pro Simulator (iOS 26.4), run one at a time: `FigureViewJourneyTests`
walkthrough journey (asserts no Extract in the part menu, simpler, Show in the paper, kept on reopen, Ask about a part),
Ask in chat (dark), two-plot crops, framed-by-confidence light and dark — 5/5. Playwright `figure-view.spec.ts` desktop +
phone 17 passed, 1 pre-existing desktop skip; menus asserted as Explain more simply · Show in the paper · (Save snippet) ·
Ask in chat about this. Screenshots (iPhone light/dark, browser desktop/phone light/dark, the menus):
`.artifacts/figure-detail-removal/`. Not run: iPad/Mac journeys (same SwiftUI path; no layout change), physical device.

## Figure parts as viewports, framed by confidence — 2026-10-21 (local source; not released, not deployed)

Owner-approved design: part cards are viewports into the whole figure, framed by confidence (tight as the crop looked;
looser with the part outlined; the whole figure with the part outlined), expandable to the whole figure, never a
misleading crop; "Shown whole…" is gone. Extract (since removed, above)/simpler/chat parts stay under the same rules; parts beyond a caption's
named panels become outlines on the whole figure. Save snippet from a part captures what its card shows. A local-only,
geometry-only framing record (arXiv figures only, in memory, cleared on sign-out) is the one place a future opt-in upload
would attach; nothing is collected (DECISIONS.md proposal). Design and thresholds: [Parts as viewports](architecture/FIGURE_VIEW.md).
iPhone/iPad/Mac (one SwiftUI/UIKit path) and browser; no server, prompt, schema, storage or spend change.

Evidence: shared fixture `tests/fixtures/figure-crops/framing.json` (12 cases on the real figures plus letter cases):
browser `figure-framing.test.ts` and Swift `FigureFramingTests` agree on every level, reason, score, frame and region;
record tests on both. `npm test` passes (browser units 600). Core suite 398 pass. iPhone 17 Pro Max Simulator (iOS 26.4),
run alone: the new `testPartsAreFramedByConfidenceAndExpandToTheWholeFigure` light and dark, the other five
`FigureViewJourneyTests` (the walkthrough journey failed once at launch on "The paper is ready" and passed alone),
`ChatVisualTests`, `FigurePartsRenderingTests`; iPad Pro 11 Simulator: the new journey (light). Playwright desktop + phone:
`figure-view.spec.ts` (incl. the new framing journey), `arxiv-html.spec.ts` (chat parts) pass. `equation-view.spec.ts`
"equation explanation … encrypted history" fails on both projects expecting the selection toolbar's old "Add to note"
(now "Save snippet" from the snippets rename): a stale expectation not touched here. Before/after screenshots on DPO's
two-plot figure with a deliberately imprecise right box (light/dark; browser desktop/phone, native iPhone, iPad after):
`.artifacts/figure-framing/`. Not verified: Mac Catalyst run, a physical device (paused), Save snippet's composer on
native (menu item and capture path built; not driven by a journey), framing quality on live AI boxes at scale.

## TestFlight 79 and browser release — 2026-10-21 UTC

iOS and Mac build 79 uploaded ~17:32 UTC (iOS VALID at the time of writing); browser redeployed to https://app.gradstep.ai.
Adds since 78: Notes renamed Snippets (cards, comment-only stream text, snippet Chat, Your assets › Snippets), podcast
defaults and model-choice ⓘ explainers, crop completeness with a background margin on every presented crop and equation,
the build-78 feedback (figure/table/equation top row Snippet · Chat · AI Explainer; Focus; instant Contents jumps; double
tap → Contents; keyword chip editor; section spacing; lower tab bar), the after-screenshot report offer back on by default.
Gates: `npm test` passes; import acceptance 15/15 on the uploaded source (`.artifacts/import-acceptance/2026-10-21T17-14-50-887Z.log`);
figure journeys 5/5 and Notes journeys pass on an iPhone 17 Pro Simulator. Not verified: physical device (paused), iPad/Mac
journeys after the final merge.


## AI recommendations — 2026-10-21 UTC (branch `worktree-agent-a6b735d13259a6476`; not deployed, not released)

Owner, TestFlight 78: "uses AI with our server to search for the most similar papers and just adds them … 1, 3 or 5";
decisions delegated ("just take your best judgement"). Design, decisions and deploy order:
[AI_RECOMMENDATIONS.md](architecture/AI_RECOMMENDATIONS.md); decisions also in [DECISIONS.md](DECISIONS.md).

Built: migration `202610210143_recommendations.sql` (kind `recommend`, policy 20/day and 1 credit, runs table deleted
with the account, begin/pool/finish, stale runs swept uncharged, Costs feature and Health counts); Edge function
`recommend` (DataCite and Feed pool candidates, never arXiv; one admitted Haiku 5.5 call through OpenRouter, feature
`recommend`; picks added as the reader as they stream; 1 credit only when a paper was added; replay free); admin Costs
and Health; iPhone/iPad/Mac menus under Find similar papers (and Mac's Paper menu), Recommend for this catalog,
the streamed sheet with reasons, Remove and Undo, filing into the catalog being viewed; the browser equivalents (the
catalog entry is a Recommend button beside Catalogs: the browser has no Library ⋯ menu); privacy draft paragraph;
explicit paid check `recommend.smoke`.

Verified locally (no provider call, no deployment, no physical phone): `npm test` passes (backend 698, browser units
580); `npm run test:database` passes (121 s; `recommendations.sql` in the final phase, also alone with
`python3 scripts/test-database.py --recommendations-only`); `tests/backend/recommend.test.ts` 11/11 (including the real
OpenRouter adapter's attribution against a fake stream); Playwright `recommend.spec.ts` 12/12 desktop and phone, and
`library-actions`, `catalogs`, `parity` 39 passed, 1 pre-existing conditional skip; native Core `RecommendationsTests`
4/4, app `RecommendationsAppTests` 4/4 and `LibraryModelTests/testRecommendationsStreamAndFileAddedPapersWhereTheReaderAsked`
(real transport, paper filed to the chosen catalog with the sheet closed); UI journeys on fresh iPhone 17 Pro and iPad
Pro 13 Simulators (add 3 → reasons → Remove one → Undo; daily limit; closing the sheet keeps the request, dark); Mac
Catalyst build compiles (no Mac UI test). The wider native regression run had one failure that needs the downloaded
real-paper corpus absent from this worktree (`testOfflineReportedPaperRegressionsThroughNativeLibrary`). Evidence and
screenshots: `.artifacts/recommendations/` (native) and `.artifacts/recommendations/browser/`.

Not verified: the live model's choices and cost (the one paid check, ~$0.001 estimated, is in the deploy steps);
"Why recommended" after the sheet closes is a follow-up; "Chat about this paper" is not built.

## Snippets, Podcasts default and AI defaults explainer — 2026-10-21 UTC (local source, not released)

Owner requests and build-78 feedback, iPhone first with iPad, Mac and browser parity: Notes is renamed **Snippets** (a
named group is a collection); the collections list shows cards; the stream has no separate Add text (the comment is the
one place for the reader's words, set apart with an accent bar) and dates sit closer to their entries; a snippet's
Chat starts the paper's chat with the crop attached (figure F3) and Back to snippets; Settings › AI defaults by activity
gains **Podcasts** (the episode writer, sent through the existing quote `writer` field) and an ⓘ explainer per activity
and for the section. Details: [NOTES_AND_SNIPPETS.md](architecture/NOTES_AND_SNIPPETS.md),
[PAPER_PODCASTS.md](architecture/PAPER_PODCASTS.md), [CHAT.md](architecture/CHAT.md), DESIGN.md "Cards".

Verified: `npm test`; browser unit tests 62 files / 558 tests; Playwright `notes.spec.ts` (desktop, phone) and the
podcast-default journey (desktop, phone, tablet); native unit `PodcastPresentationTests` (the new case passes; two
older tests fail on stale fixture maxima from the 2026-10-18 profiles 6/7 — 140/150/300/520 expected, 230/240/380/590
listed — not changed here); UI journeys on fresh iPhone 17 Pro and iPad Pro 13-inch Simulators and the Mac: cards,
Podcasts default and explainer, snippet Chat (iPhone), the wide Snippets layout (iPad, Mac), the main snippet journey,
Settings from every menu and Your assets (iPhone). `testAddSelectionToNote` fails: the long-press shows no edit menu
at all on this Simulator. Not done: the figure/equation pages' "Add to note" label (files under parallel change); a
crop in a general chat (needs the server to accept figures there). The final native date spacing (day label −6 pt
below) built but its iPhone screenshot was not re-taken: under a load average of ~250 from other work the journey
timed out at "paper is ready" (it passed with the previous 2 pt spacing). `npm test` passed on its second run; the
first failed once in `notes-store.test.ts` (unchanged code; passes alone). No server, deployment, upload or physical phone.

## Build 78 screenshot feedback — 2026-10-21 (local source; not released, not deployed)

Owner feedback 14:35–15:14 UTC ([log](OWNER_FEEDBACK.md)), one commit per item on `worktree-agent-a61e736ed1dc7b2f7`,
merged with main (Snippets rename, 2176da36). Changes: keyword chip → Edit tags with its two searches on top (native,
browser); Contents/gallery/Go to figure jump at the tap (native; the browser already did); "Manage catalogs"; figure,
table and equation pages' top row = Snippet, Chat, AI Explainer in words, no ⋯/Report/X on touch screens (Mac and
browser keep the X), after-screenshot report offer on by default (owner reconsidered the build-78 note); paper chat prepares its paper on the device
(`readerBundleForChat`) and names a failure's reason (native `reader_unprepared`, browser `reader_no_html` /
`reader_retrieval` / `reader_unprepared`); keyword fallback to narrower arXiv subjects plus a visible Add keywords chip
(Swift/server lists compared by `tests/backend/tags.test.ts`; `arxiv-source-metadata.js` rebuilt, reader compiler and
revision 22 unchanged); section spacing 2em/1.6em → 1.4em/1.25em in the bridge (no revision bump); equation menu
"Focus" asks nothing; double tap: a selection elsewhere no longer blocks it and a stale Contents flag self-heals; tab bar
6 pt lower; the offline sample shows no keyword row. Not done: headers higher (system navigation bar did not move with
negative safe-area padding or a reduced navigation-controller safe area; reverted). Proposal written:
[AI recommendations](proposals/AI_RECOMMENDATIONS.md).

Evidence (iPhone 17 Pro Simulator, iOS 26.4, run alone): app units PaperTableTests, PaperWebViewTests (the four
pre-existing "Gradstep Keywords" Contents failures are fixed: the bridge's own heading is no longer a section),
ChatGenerationTests (arXiv answered by a fixture, no network) and the screenshot-offer test pass, 97 tests, 0 failures;
UI journeys pass: FigureViewJourneyTests figure walkthrough (Snippet/Chat/AI Explainer row, swipe to close), figure
gallery, equation view (Focus then AI Explainer), Contents levels/discovery, repeated Contents/paper chat reading place,
the new `testDoubleTapOpensContentsDeepInThePaperAfterAnEquationMenuAndAFling` (light) and all 9 NotesJourneyTests after
the merge (including `testAddSelectionToNote`: long-press shows the edit menu with Save snippet; 2 consecutive passes).
Result bundles and screenshots: `.artifacts/b78/` (`ui-2`, `ui-3`, `ui-4`, `sel-1`, `sel-2`, `unit-2`;
`review-figure-toprow-light.png`, `review-gallery-figure-dark.png`) and `.artifacts/visual/b78-after/` (paper, library,
chat, settings, light and dark). Browser: vitest passes (63 files, 566 tests before the merge, plus the new preparation test); Playwright desktop + phone
`equation-view`, `figure-view`, `build-62` 33 passed (2 load timeouts at 2 workers pass when rerun alone), 1 by-design
skip. `npm test` passes after the merge (every fast-tier group, including compiler freshness). Section gaps measured on cached real papers (2610.17288v1, 2610.10478v1) at 402 px: 47 → 34
px above a section, 33 → 27 px above a subsection. Not verified: a physical device (paused), iPad and Mac UI journeys,
the owner's exact double-tap moment.

## Complete figure crops and presentation margins — 2026-10-21 (local source; not released, not deployed)

Owner-approved quick win from the [subfigure detector review](reviews/SUBFIGURE_DETECTOR_20261021.md) (integration
step 1): every AI-written figure crop — walkthrough panel cards, "Extract the subfigure" details and chat figure parts —
is completed on the device over the ink its box cuts, on the exact image the request carried, or shown as the whole
figure when no crop can hold all of it; every crop and whole-figure card sits on a margin of white background. No model,
server, prompt, schema, storage or spend change. Design and limits: [Complete crops](architecture/FIGURE_VIEW.md).
Owner, same day: margins wherever a figure or equation is presented alone — the figure/table page's image now has 12 px
of its white background inside the white surface (shared `reader-bridge.js`, both clients; before, ink touched its edges
in dark mode); the native equation view draws the equation inside a bordered surface (8 pt + 8 px inside it; the browser
already had a bordered stage with 14/18 px); equation tiles fit with 8 px/pt more room on each side; the native fullscreen
figure keeps 16 pt around the image; the browser's figure-parts overview pads the whole figure by 8 px. The native
walkthrough's whole figure (8 pt white) and gallery thumbnails already had margins.

Evidence: shared golden fixtures `tests/fixtures/figure-crops/` (8 cases on 4 images, exported from
`scripts/subfigure-detector/app_crops.py`) reproduced exactly by Swift and TypeScript, including component digests;
Core 391 tests pass; `npm test` passes (browser units 564, backend 686); app unit `ChatVisualTests`/figure-parts render
pass. iPhone 17 Pro Simulator (iOS 26.4), run alone: all 5 `FigureViewJourneyTests` (including the new two-plot light
and dark cases), equation view light/dark, equation tiles light/dark and the figure gallery pass. Playwright desktop +
phone: `figure-view.spec.ts` and `equation-view.spec.ts` 27 passed (1 by-design desktop skip), `arxiv-html.spec.ts` (chat
figure parts) 4 passed. On the real two-plot figure the right crop before the change cut its title, legend, x-axis and
y-label and showed a sliver of the left plot, with the coverage note; after, both crops hold their whole plot, the note
is gone. Before/after screenshots (light and dark, native and browser): `.artifacts/figure-crops/compare-*.png` and the
`before-*`/`after*` files beside them. `PaperWebViewTests` has 4 failing Contents cases ("Gradstep Keywords" listed as a
heading) that fail identically with the original `reader-bridge.js`: pre-existing, not addressed here. Not verified: a
physical device (paused), Mac and iPad layouts, completion quality on a corpus of live AI boxes (the review's simulation
is the only quantitative evidence; the app gates were chosen on its fixtures, not measured on the validation set).

## TestFlight 78 and browser release — 2026-10-21 UTC

iOS build 78 uploaded 12:52 UTC and VALID in App Store Connect; Mac build 78 uploaded 13:01 UTC (processing at the time of
writing). Browser deployed to https://app.gradstep.ai (Pages 308f1938; association and asset types verified). Contents:
native and browser Notes and snippets (server `note-assets` live since 06:37 UTC), the native/browser/server review fixes,
the build 73–76 owner feedback, OpenRouter-only inference with the admin Costs tab, and no import quota (migrations through
0142 applied; deploy checks 19 passed, 0 failed). Gates: `npm test` passes; import acceptance 15/15 on the uploaded source
(`.artifacts/import-acceptance/2026-10-21T12-37-09-860Z.log`); Notes 5/5, figure page 3/3 (alone; 0/3 under heavy load,
"paper is ready" timeouts) and authentication journeys pass on an iPhone 17 Pro Simulator after a fix: a sign-in begun from
the Settings sheet now returns to Settings. Not verified: a physical device (paused), cross-device Notes sync, Mac UI
journeys after the final merge. Local store format v7 cannot be opened by builds before 78.

## Native code review fixes — October 21 UTC (local source; not released)

The [native code review](reviews/NATIVE_REVIEW_20261021.md)'s findings were each re-read against `82c8656` before
changing them; its status table lists what is fixed (commits `1d0ed71`…`27c9cab`), what is partly done and what was
left, with reasons. No server, database, deployment, paid model call, release or physical-phone access was involved.
The browser part of A5/A6 is source only (not deployed). Builds 77/browser `27c45ca0` remain the released clients.

Fixed: a refused token refreshes once and replays once before the session ends, with skew-tolerant expiry (A1); a
selection action and a paid answer survive a local save failure, and Try again re-saves instead of re-asking (A2, A3);
sign-out cancels and clears per-account and per-paper work (A4), which also exposed and fixed sign-out starting a
download of the old account's paper; adds report the server's outcome and web papers join the selected catalog under a
stable `source:` key, in the app and the browser (A5, A6; [catalogs](architecture/LIBRARY_CATALOGS.md)); opening joins a
running download (A7); a question waiting for its paper is in flight and Stop withdraws it (A8); closing an explainer
sheet is no longer a paid Stop (A9, [CHAT.md](architecture/CHAT.md)); the fullscreen figure no longer restarts the
explanation (A10); model-reading runs have identities (A11); archiving a source paper applies at once and keeps its
keywords derived (A12, A13); retired Mac local models fall back to cloud (A14). Performance: an unchanged store
generation re-renders nothing (C1); keyword derivation 15.2–46.7 → 0.37 ms/paper uncached and ~0.002 ms repeated with
identical output (C2; `-O`, 500 synthetic papers, machine under heavy load); typing re-renders the message box only
(C6); no per-token observation writes (C7); a bounded cache of composed figure images (C8); the figure view decodes once,
off the main actor (C9). Parity: the Mac's commands were tried on an iPad keyboard and taken back out (B1; the iPad
keeps its own ⌘F/⇧⌘R; see the review row and [Mac app](architecture/MAC_APP.md)); ⌘Return sends and Escape closes the
fullscreen figure on iPad too; equation/figure threads use Chat's message row and ⌘Return (B2/B3, partly); author
search shows the Library on every layout (B4; main's `searchPapers` now does it) and the chat beside the paper knows its
placement; more menu-bar items (B5, partly), with the Mac's Find in Paper opened through the paper view's checks. Hygiene: dead code, the resource
probe's SwiftMath dependency, the two Core concurrency warnings (D7, D10, partly).

Evidence (dedicated Simulators, derived data under the worktree's `.artifacts/`; the machine ran at load averages of
600–970 from parallel agents, so WebKit-backed checks were slow): ScienceReaderCore `swift test` 359 tests in 47
suites pass. App unit tests: the affected suites (chat generation/transport, authentication, library model/transport,
drafts/workspace, workflow safety, branches, figure view, reading mode) pass, with four WebKit-timing failures under
load that pass when rerun alone (two import compiles, the Mermaid check, an equation-overflow page). An earlier full
`ScienceReaderTests` run (before the B/C6/D commits) had seven failing tests outside the changed code: five
`PaperWebViewTests` (the "Gradstep Keywords" heading added in de722cf; a load timeout) and two podcast-limit tests
(writer maxima changed in de722cf); they were not re-run at `82c8656`. `npm test`: its first step, arXiv compiler
freshness, fails here at `82c8656` too (a fresh build of an unchanged input graph differs from the committed bundle);
the other fast steps pass (device-PDF compiler freshness, backend 671 pass/1 skip, operations 18, arXiv egress scan,
browser units 496 in 53 files); browser `tsc` is clean. Mac Catalyst `build-for-testing` succeeds and
`MacKeyboardTests` pass 5/5. iPhone journeys pass for Add (6), catalogs, Find in paper, figure walkthrough, figure
Ask in chat (rerun) and chat default options; two `ChatControlsTests` fail on stale assertions about unchanged code
(the keyboard-dismiss button's position, and a helper that looks for a removed model segmented control). Mac
`LocalAIJourneyTests` local-model cases could not run: the fixture model was disabled by the memory-admission check
("1 GB free app memory required") on the saturated machine. Screenshots of the iPhone and Mac message box were
reviewed (unchanged appearance). Logs: the worktree's `.artifacts/*.log` (result bundles and derived data pruned after review).

After merging main (`66bb4c6`: Notes, the single model control, catalog adds, keyword specificity): ScienceReaderCore
388 tests in 51 suites pass. `npm test` passes in full, including compiler freshness (main's 5ef1bce fixed it):
backend 700, browser units 528 in 57 files, and the type checks. The backend's 500 ms timing test failed once under load
and passed on the rerun. iOS and Mac Catalyst `build-for-testing` succeed. The iPhone unit suites (chat
generation/transport, authentication, library model/service, workflow safety, figure view) pass, 143 tests; two
diagram checks timed out under load and passed alone. On an erased iPhone Simulator, the earlier chat-profile failures
didn't recur: they were settings left by `ChatControlsTests`. iPhone journeys pass for Add (6), catalogs and Find in
paper. `ChatControlsTests` fails 3 on main's own stale tests: a removed `chat.profile.model` control, profile retry,
and New chat under main's new Settings sheet (8143fd7). Mac `MacKeyboardTests` pass 5/5. iPad: two of three reading-mode
journeys pass; the dark one timed out at the self-hiding bar under load, and it passed on the fresh iPad before the
merge. The iPad ⌘F step of `testTabletReaderHidesAndResizesTheChatColumn` fails on this branch and also on main
(`9ee4884`, built separately, 2 of 2) on the same Simulator. After a second merge of main (`c82a377`, no `apps/apple`
changes), `npm test` passes in full (backend 686, browser units 553 in 61 files) and browser `tsc` is clean.

## Browser review fixes — October 21 UTC (local; not deployed)

The browser findings of the [2026-10-21 review](reviews/WEB_SERVER_REVIEW_20261021.md#fix-status--2026-10-21-browser-built-and-tested-locally-not-deployed)
are fixed on branch `worktree-agent-a07aac6f6943c5a8b`, one commit per finding or group (the review's table lists
them). **Not deployed**: no Pages build was published and no hosted request or staging account was used. The
released browser is still Pages `27c45ca0`. iPhone sources were read for wording and behaviour, not changed.

- **Correctness**: links out of a paper open in a new tab and the frame keeps the paper (A18; frame sandbox and CSP
  unchanged). Stop, storage retirement and sign-out reach the gap between a figure answer's two passes (A19). A
  temporary sync failure no longer refuses the next question; key, capacity, conflict and local-storage failures still
  do (A20). The A19 and A20 unit tests fail on the old code.
- **Parity with the apps**: actions on selected answer text and formulas (B1); Papers in this answer (B2); every visit
  starts with all tags (B3); kept explanations survive reloads, sealed with the device's local key (B4); crop or
  redact a report's screenshot (B5); AI model first for explainers and the composer, the answering model named,
  Change AI (B7); chat text size (B8); Library Venue/Source/Pages/Chats and All chats Kind/Topics/Answer length (B9);
  the smaller B10 differences, with player options, account Sync and About's version and acknowledgements.
  Not done: approving another device from the browser (B6, needs a cross-device run), Other lengths… in the player,
  and the sign-in method in the account menu (the owner removed it in build 58).
- **Performance** (temporary render probe, desktop, DPO fixture; not committed):

  | Measure | Before | After |
  |---|---|---|
  | 40 reader scroll steps: app / chat / library model / reader renders | 80 / 80 / 80 / 80 | 0 / 0 / 0 / 50 |
  | ~225-delta streamed answer: branch scans / summaries / chat renders | 707 / 14 / 342 | 3 / 2 / 151 |
  | Four figure frames: `frameDocument` | 69.2 ms | 1.0 ms |
  | Initial JS (entry + preloads; production build, staging env) | 1,034.3 kB (310.9 kB gzip) | 806.8 kB (241.2 kB gzip) after C5; 892.8 kB (267.0 kB gzip) after merging main (browser Notes ~42 kB, the feedback branch ~5 kB) and the B features (~10 kB) |

  Caches are bounded (C8), the journal counts records with `count()`, and the compiler no longer ships in `dist/`.
- **Shared code** (D8, browser side): the browser uses the server's arXiv parser, `visualDocument` (now
  `_shared/visual-document.ts`) and `parseBalance`. Consent versions, the study/figure/equation pairs (E4) and
  Retry-After parsing were not changed. **D11**: error codes in words, DOI/web papers go into the viewed catalog,
  diagrams follow the app theme, the podcast route line names OpenRouter, five unused exports removed.
- **Journeys failing on main before this work** now pass. The tests were stale for account-delete, reader, build-62,
  library-actions, chat-controls, chat-redesign, equation-view, journal and arxiv-html (current wording, consent v6,
  three model/length groups, Find similar papers first, the saved-draft hint going away). The app was wrong for
  owner-58: Privacy &amp; data still mentioned a backup search provider; it now uses the apps' wording. One app
  regression of this work was caught by arxiv-html (the lazy reader asked arXiv twice) and fixed in 114df10.
- **Evidence** (after merging main at 5a38d04): `apps/web` unit tests 552 passing; root `npm test` (fast tier) passes
  every step, compiler freshness included: backend 686, browser units 552, operations, egress scan, Edge and admin
  type checks. Playwright (after the 5ef1bce merge; main changed no browser code after it) on desktop and phone for 22 affected specs (account-assets, account-delete, arxiv-html,
  build-62, catalogs, chat, chat-controls, chat-redesign, equation-view, figure-view, journal, layout, library,
  library-actions, library-columns, library-commands, notes, owner-58, parity, podcast-workspace, reader,
  support-reports): 207 passed, 25 skipped by their engine or width gates, none failing. Stale tests found on the way
  were updated and rerun: account-assets (b54d0d8, the tab-only wording), figure-view and library-actions (22d8991, after
  main's feedback branch). Two cases failed once under load and passed when repeated (an opaque diagram, 12 of 12; the
  phone podcast workspace, whose paper download was still at 57% after 10 s). notes-capture with its own config: 10
  passed; its arXiv cases skip without the local corpus. Screenshots reviewed in light and dark under `.artifacts/`
  (web-chat, web-columns, web-support, figure views, web-build62, owner-58, web-podcast-workspace).
- **Limits**: browser Notes adds about 42 kB to the first load and could be loaded lazily next. WebKit keeps its
  durable-key limitation. The compiler freshness check failed in this worktree until main's 5ef1bce (packages resolve
  from the repository's node_modules only); after merging it the check passes and the moved copy in
  `apps/web/src/reader/` matches the app's.

## OpenRouter exclusively, cost per account, no import quota — October 21 UTC (built and tested locally; not deployed)

Owner directives of 2026-10-21 ([decisions](DECISIONS.md)). Nothing deployed; no hosted, paid or phone check run; the
browser and Apple apps untouched. Designs: PROVIDER_SPENDING.md "OpenRouter only (2026-10-21)",
OPERATIONS_AND_BILLING.md "OpenRouter exclusively and cost per account", LIBRARY_CAPACITY.md "No import quota".

- **Code:** direct-provider cards, the Anthropic SDK client/stream adapter, the fallback beta, native search and the
  `claudeOpenRouter` switch removed; `anthropic.ts` → `inference.ts`, own request types in `model-request.ts`,
  `admittedAnthropic` → `admittedModelCalls` (always `worker_openrouter_admit`); `@anthropic-ai/sdk` removed from
  `deno.json`, `package.json` and the pipeline worker (locks pruned offline). Web search is our Tavily `search_web` tool
  only. provider-health maps only real providers; the egress guard still refuses direct model hosts and logs them.
- **Config:** `deploy-staging.py` stops setting `CHAT_CLAUDE_OPENROUTER` and deletes `ANTHROPIC_API_KEY`,
  `DEEPSEEK_API_KEY` and `CHAT_CLAUDE_OPENROUTER` from the project; the worker deploy accepts no Vertex identity;
  `infra/staging.json` loses its unused entries; `config.function-secrets` fails on a direct key; `budget.health` fails on
  OpenRouter attempts only and names legacy ones.
- **Migrations (after 0100–0135, in order):** 0140 OpenRouter-only reporting (legacy named, held, kept), 0141
  `v1_admin_account_costs`, 0142 no import quota (lifetime limits NULL; in-flight backstop 100/2,000). Fixtures:
  `openrouter_only_reporting.sql`, `account_costs.sql`, `no_import_quota.sql`.
- **Admin:** Costs tab (sortable, per-account feature/model breakdowns, this month and last 30 days); Health shows legacy
  attempts apart from OpenRouter ones. Screenshots (fixture): desktop light and phone dark, no horizontal overflow.
- **Evidence (local):** `npm test` all nine steps pass (backend 683/683 — direct-adapter and native-search tests removed,
  chat tests now use OpenRouter models, reported costs and consent v6 as production requires; browser 520/520;
  operations Node 24 and Python 124; Edge `deno check`; admin `tsc`); `npm run test:database` passed (824 steps, 127 s);
  `npm run test:ops` passed. `scripts/check-admin-build.mjs` needs the production backend environment, absent in this
  worktree; the built bundle contains no Costs fixture data (checked by search).
- **Deploy order:** (1) migrations through `scripts/deploy-staging.py` (0140 needs 0102/0108/0128; 0141 needs 0037/0140);
  (2) every routine Edge function (all import the changed `egress.ts`/`provider-health.ts`; chat the rest) — the same
  run sets the secrets and removes the retired ones; (3) the Cloud Run worker (`scripts/deploy-pipeline-worker.py`:
  tags, podcasts, provider-health, no SDK); (4) the admin site (`node scripts/deploy-web.mjs admin`).
- **Live checks (read-only, unpaid):** `worker_budget_health()` has `unknown_openrouter_attempts_over_1h` and
  `reconciliation.legacy` (`by_provider` `{"anthropic":1}`, held 138 micro-USD until the Oct 17 attempt is settled, then
  0); the Management API secret list has no `ANTHROPIC_API_KEY`/`DEEPSEEK_API_KEY`/`CHAT_CLAUDE_OPENROUTER`;
  `node scripts/workflow-checks.mjs --only config.function-secrets,budget.health` passes; `GET functions/v1/chat` lists
  every model with `provider: "openrouter"` and `tariff: "openrouter-reviewed-cards"`; `app_private.library_policy` shows
  NULL lifetime limits and 100/2,000 in flight; Admin › Costs loads for the owner and its month cost equals Spending's
  month `reported + estimated` for attempts; Admin › Health shows legacy separately. Paid (owner's choice, ~$0.005): one
  chat answer appears in Costs under that account, feature chat, model `anthropic/claude-sonnet-5.5` or `gemini-3.8-flash`.
- **Not done here:** the Swift and browser copies of the chat profile fixture and the apps' quota/limit strings and
  4,000-entry bound (app agents; listed in LIBRARY_CAPACITY.md); dropping the still-evaluated lifetime count queries
  (perf, review C7/E2); provisioning per-feature OpenRouter keys (owner).

## Notes and snippets, native — October 21 UTC (local; not released)

The iPhone, iPad and Mac client of the [Notes contract](architecture/NOTES_AND_SNIPPETS.md#native-client-status--iphone-ipad-and-mac-implemented-locally-not-released-2026-10-21-utc)
is implemented on branch `worktree-agent-a59beff74b009e4ac` (codec `443f04d`, store/transport `6aa4cc4`, iPhone UI
`8143fd7`, iPad/Mac `7e9857a`, browser-interop alignment `8ccf4f7` and follow-ups). **Not in TestFlight**; clients
remain build 77. All Simulator work used two devices created for this run (iPhone 17 Pro, iPad Pro 13-inch M5, iOS 26.4)
and the Mac (Catalyst), then deleted; the physical iPhone stayed paused.

- **Core** (`swift test`, ScienceReaderCore): **383 tests pass** (50 suites). New: `NotesTests` (15) — the six fixture
  records re-encode byte for byte, the five invalid records fail with their stated reasons, the future record is kept,
  the encryption vector matches (blob hex, SHA-256, AAD, descriptor), tamper/account/type checks, reducer ordering,
  versions and their resolution, immutable fields, tombstones, incomplete entries, catalogs ignored both ways, format-1
  envelopes; `NoteStoreTests` (9) — atomic save and its failure, holds and release, dependent edits, key-rotation
  rebasing, idempotent uploads with quota/timeout/conflict, verified on-demand downloads into the encrypted cache,
  format 6→7 migration, a missing unsent blob refused, cache eviction; `NotesInteropTests` (2) — see below. Four older
  legacy-format tests now strip the new metadata keys; one migration test expects schema 6.
- **Cross-client records** (`tests/fixtures/notes/cross-client-v1.json`): the browser codec (`apps/web/src/lib/notes.ts`,
  bundled by a scratch script) read **6/6** Swift-written edge-case records and re-encoded each byte for byte; Swift
  reads, validates and re-encodes the **6/6** browser-written ones. Swift's validators were aligned to the browser's
  bounds first (offsets ±1,440, 80-scalar titles, revision ≥ 1, block IDs `[0-9A-Za-z_-]`, nullable anchor identity).
- **Staging** (opt-in `NotesLiveAssetsTests`, 2026-10-21 08:33:59 UTC, project `coxhjvqpflgxkleydati`): a disposable
  `@example.invalid` account; the app's own `BackendNoteAssets` uploaded a real capture's PNG (11,122 B stored) and JPEG
  thumbnail (8,062 B) from an `EncryptedStore`, which then released the held entry; a repeat PUT was 200; a second
  store downloaded, verified, decrypted and cached both; a different digest was 409 and an unknown ID 404. The account
  was deleted through `account-delete` (`{deleted:true, complete:true}`). No paid calls.
- **App tests** (`NotesAppTests`, 7/7): every deployed note-assets status and body, `X-Content-SHA256` checked; text crops
  stay PNG at full size with no camera/place/time metadata; large and photographic crops fit the limits (JPEG fallback);
  PDF regions render exactly the chosen part, rotated pages included; model writes through the encrypted fixture store
  (create, trimmed titles, capture with sealed images, exact retry, text, comment, rename, new note with its first
  entry, search, delete, reopen); Settings presentation rules.
- **UI journeys** (`NotesJourneyTests`): iPhone — Draw snippet → Save to a new note → Open note → full size → Edit comment →
  Rename → Add text → Delete (with name and count); selection › Add to note; a figure page's Add to note with the whole
  figure preselected; Settings from the Library, Feed, Paper, Chat, Notes and note menus returning to each (Report this
  screen just above it); light and dark — **all pass**. Wide layout — Notes beside Feed/Library/Reader/Browse/General
  Chat, list beside the note, capture beside the chat column, Settings round trip: **passes on iPad (light and dark) and
  on the Mac (light and dark)** (menu-bar Draw Snippet; Escape cancels drawing). `SettingsTests` 6/6 with the new navigation.
- **Regression context**: the full app unit bundle (510 tests) has failures unrelated to Notes — four
  `PaperWebViewTests` Contents cases fail identically on the base commit `82c8656`; two podcast tests follow main's
  podcast-script change; one needs the local import corpus; three timed out only while other suites shared the machine
  and pass alone. A stale Simulator stalled WebKit loading until rebooted (as recorded before).
- **`npm test`**: its first step fails — `arxiv-reader.js` is stale against shared server modules changed on main after
  the last compiler build (no compiler input changed here; rebuilding the shipped reader is left to its owner). The
  remaining fast-tier steps pass when run individually: backend 697, operations 24, Python operations 124, arXiv egress
  scan, Edge type check, admin type check, browser units 519/520 — the one failure was the Swift interop executable's cold
  `swift run` build inside its test window, and `tests/interop.test.ts` passes 5/5 once built.

Not done natively (also listed in the architecture document): encrypted composer/comment drafts, "Keep both", a New
snippets jump, two-tap corners and richer VoiceOver capture announcements, Open in paper for local PDF sources,
adjusting an equation-page capture, and an end-to-end native ↔ browser sync through staging.

## Builds 66–76 open feedback — October 21 UTC (feedback branch; not merged, not released)

Implemented on branch `worktree-agent-a9ba7e1c4135d32c0` from `641541c`, then merged with `main` at `fa1f69f` (browser
Notes client, server review fixes; conflicts kept both sides); per-item status and commits are in the
[triage report §0](reviews/FEEDBACK_TRIAGE_20261021.md#0-implementation-status--2026-10-21-on-the-feedback-branch-not-merged-not-released).
Current clients remain build 77 / browser `27c45ca0`: nothing was uploaded or deployed, and the physical phone was not
used. Reader **revision 22** (plot labels upright, affiliations and contacts in the header) is built into both compiled
copies but unreleased; saved papers need ⋯ › Update this paper once it ships.

Checks run (a heavily loaded shared Mac: load average 650–950; one stalled run found its Simulator shut down):

- `npm test` passes after the merge: backend 700/700, browser units 527 (57 files), compiler freshness, operations
  (incl. Python), egress, edge and admin type checks. The first pre-merge run failed the source-metadata extractor
  freshness gate after the vocabulary change; the extractor was rebuilt (5993578), the compiler bundle unchanged.
- Swift Core: `PaperDiscoveryTests` (generic keywords) and `LibraryCSVTests` (shared fixture byte for byte) pass.
- iPhone 17 Pro Simulator (iOS 26.4, Debug), unit: UnsentDraftTests, WorkflowSafetyTests, LibraryCommandCoordinatorTests,
  PaperTableTests, LibraryMetadataTests, ContentsEquationLabelTests and the touched LibraryModelTests cases pass
  (92 tests, `unit-2`); the two PaperWebViewTests cases (whole-name links, abstract list, keyword chips) and the
  NativeSafetyTests report-snapshot and screenshot-offer cases pass in `unit-3` (the WebView cases had first timed out
  loading under load, the existing named-reference case included).
- iPhone UI journeys: FigureViewJourneyTests (all three, incl. the promoted chat's title and the new Report this
  screen journey), LibraryCatalogTests (rename without flash, Export as CSV share sheet, catalog left of search, Add
  paper… in ⋯), LibraryLayoutTests.testFiltersTagsAndRetryOnAFailedImport (tag search; search start/Cancel clear the
  tag), LocalAIJourneyTests.testDictationOnlyFillsTheDraftAndModelsLiveInSettings (one composer model control) and
  AddPaperFlowTests.testAddByDOIAndLink pass. First-run failures were investigated: a stale "Alignment" tag query
  (catalog tags give way to derived keywords since build 70), a share sheet the test could not dismiss, an accessibility
  server crash, and a real add bug since ca5c3e1 (a catalog write that can't be saved reported a server-successful
  DOI add as failed; fixed in edbd9c5). `ChatControlsTests.testStartersAnswerOptionsAndTheTopicTitle` still fails on
  pre-existing stale assertions (a DeepSeek segment and "Reset default settings" from before the build-69/71 model rows);
  its composer-layout assertion was corrected.
- iPad Pro 11-inch Simulator: FigureViewJourneyTests (all three), LibraryCatalogTests and
  LibraryLayoutTests.testFiltersTagsAndRetryOnAFailedImport pass (one first-run launch timeout at 10 s passed on rerun).
- Mac Catalyst: the app builds (Debug). Mac UI journeys were not run, and the scripted Mac screen capture could not read
  the app's sandbox container from this session (EPERM), so no Mac screenshots were reviewed.
- The CSV share sheet draws "Research.csv" with Save to Files after ~20 s on this loaded Simulator (two earlier
  captures, taken sooner, showed it still blank).
- `scripts/visual-check.mjs` light/dark on iPhone (library table and options, chat, paper, Settings end): Add paper… is
  the first row of Library "…", no + beside Search, one model control in the composer, and the Settings toggle; contact
  sheet `.artifacts/visual/fb21-sheet.png`.
- Screenshots reviewed: the promoted Figure 1 chat titled "Figure 1" with one model control; the figure page with
  equal capsules and "…"; Report this screen over Contents with the app's own snapshot; Catalogs with "…" and the share
  sheet; the Tags menu with Search ML papers first. Evidence: `.artifacts/feedback-20261021/` in this worktree (logs and screenshots exported from the result bundles;
  the bundles themselves were pruned for disk space).
- After the merge, Playwright catalogs, library, paper-search, figure-view, parity, layout and notes specs pass on desktop
  and phone, except notes-capture (it needs its own config, where it passes 2 + 2 skipped for an uncached source) and
  a library.spec selector that the new "Search ML papers for “…”" also matched (anchored; passes).
- Browser (from the parity sub-task, cherry-picked unchanged): `npm run test:fast --prefix apps/web` 502/502; affected
  Playwright specs pass on desktop and phone (tablet where in the project) apart from pre-existing wording failures in
  account-delete, reader "invite-only", arxiv-html consent v5→v6 and owner-58 privacy text; library-commands showed one
  intermittent timeout per full run that passes alone. Light/dark screenshots of each changed screen were reviewed.
- Compiler (from the compiler sub-task): the 123-paper cached replay has no failures and unchanged findings; device
  compile of 2610.22371v1, 2610.22353v1, 2610.19892v1, 2201.11903v6 and 2610.15542v1 succeeds; before/after renders
  of Gen4P Figure 3 and the 2610.22353v1 header were inspected.

Not verified here: physical-phone behavior, the 15-case import gate (`npm run test:imports`; required before the next
native upload because RootView.swift and importPaper changed), Mac Catalyst journeys and screenshots, and an actual
screenshot gesture (the offer was exercised by posting the system notification). TestFlight's own screenshot feedback
and ReplayKit session recordings cannot be redacted by the app.

## Server, admin and scripts review fixes — October 21 UTC (built and tested locally; not deployed)

Fixes for the verified server/admin/scripts findings of the [2026-10-21 review](reviews/WEB_SERVER_REVIEW_20261021.md)
(per-finding status and commits there). Nothing was deployed, no hosted or paid check was run, and the browser and
Apple apps were not touched. Designs: PROVIDER_SPENDING.md "Review fixes — 2026-10-21", SPENDING_CONTROLS.md (pauses
across months, operator budget command, testing-allowance safeguards, hot paths), RESILIENCE.md (scoped breakers),
CHAT.md (Stop charging, endings, `done` reporting), and the sections the paper-add, store, podcast and admission fixes
name.

- **Money:** a Stop charges what was written (OpenRouter's generation record, else the streamed output; never the
  hold); a finished answer stays charged when the reader leaves during side requests; unresolved OpenRouter attempts
  reconcile automatically from generation records (pipeline worker, bounded, audited); attempt capacity is a 24-hour
  window of granted attempts (counter rows); OpenRouter card validity is a renewable table with a six-week warning and
  chat stops offering a model before its card lapses; pauses hold across months and test accounts cannot trip them;
  the operator budget command and the testing allowance are owner-attributed and audited, the allowance capped at
  **$25/month by default** (deploying 0105 applies it to the owner's current allowance). No limit is raised; the
  $100/month operating budget and the month's provider limit are unchanged.
- **Migrations (apply in order):** 0100 attempt windows, 0101 tariff validity, 0102 automatic reconciliation, 0103
  pauses across months, 0104 owner budget limit, 0105 testing-allowance safeguards, 0106 scoped breakers, 0107 admit and
  dispatch in one call, 0108 hot-path indexes and stale-sweep failures, 0120 server add once, 0125 podcast device-source
  deletion, 0126 podcast source reservation, 0127 beta-admission revocation, 0128 deletion sweep back-off, 0135 default
  privileges. Each has a fixture in `tests/database` (`--spending-fixes-only` runs 0100–0108's).
- **Evidence (this branch, local):** `npm test` all nine steps pass (backend 697/697, browser 495/495, operations Node
  24/24 and Python 124, Edge `deno check`, admin `tsc`, both compiler-freshness checks); `npm run test:database` passed
  (815 steps, 150.5 s, PostgreSQL 18); `npm run test:ops` 145 Python + 24 Node tests. A timing test
  (`reader-flow` "pathological lines stay fast") failed twice only while the database suite ran alongside; it passes
  alone and was not changed.
- **Deploy order (for the owner):** (1) migrations as listed, with `scripts/deploy-staging.py` (it runs
  `migrate-supabase.py`); (2) every routine Edge function — the chat function needs 0101, 0106 and 0107 (until 0107
  exists every OpenRouter admission is refused), add-paper/add-reference need 0120, podcast needs 0126, admin-accounts
  needs 0105 and 0127; also account-delete, app-store-notifications, feed-refresh, podcast-member, upload-pdf (D9);
  (3) the Cloud Run worker (`scripts/deploy-pipeline-worker.py`: reconciler, per-feature keys, deletion sweep);
  (4) the admin site (`node scripts/deploy-web.mjs admin`).
- **Live checks (unpaid unless marked):** read-only SQL — `provider_spending_policy` shows 50,000/10,000 per 24 h and
  `provider_attempt_hours` has rows (A2); `openrouter_tariffs` has 7 rows valid to 2027-01-01 and
  `scripts/pipeline-ops.py tariffs` lists them (A4); both budget months have the same switch (A7); the owner's
  `testing_allowances.monthly_cap_microusd` is NULL — uncapped, as the owner authorized on 2026-10-19 (A9: only
  allowances turned on later default to $25); `provider_breakers` has a
  `scope` column (A13); `stale_sweep_failures` is empty or named in the budget check (C7). Admin: Overview shows this
  month's spend and the right Pause/Resume (A3); Spending shows `attempt_capacity`; Accounts marks the owner's
  allowance; Support pages and closes (D10). Drill (`FAULT_INJECTION=on`, test account, no real provider):
  `node scripts/fault-drill.mjs --mode=stop` and `--mode=midstream` now reach OpenRouter (D4, A1 path), and a throttle on
  one route leaves another answering (A13). Paid, owner's choice (~$0.05): a Stop a few words into a Sonnet answer on a
  long paper settles `stopped` with credits near input + written share and the attempt `succeeded` at the generation's
  cost (A1); if the record was late, within ~5 minutes the attempt is `reconciled` with evidence
  `openrouter-generation:<id>` (A6). The forks' checks (A5, A8, A15–A17, A21, A22, A24, D5, D9) are in the review's
  status table notes and their sections.
- **Not done here:** the browser A18–A20 and parity items; App Store notification-history reconciliation (needs App
  Store Server API credentials); provisioning the per-feature OpenRouter keys (owner step, RESILIENCE.md); the
  account-delete body bound (deletion work is another agent's); the Anthropic SDK test transport (review E1).

## Notes and snippets, browser — October 21 UTC (local; not deployed)

The browser client of the [Notes contract](architecture/NOTES_AND_SNIPPETS.md#browser-client-status--implemented-locally-not-deployed-2026-10-21-utc)
is implemented on branch `worktree-agent-a9b813b0dfc3cc40f` (codec `6197453`, storage/sync `76ed829`, UI `ad3fc2f`,
capture `58e4fff`, then follow-ups). **Not deployed**: no Pages build, no hosted request, no staging account was used;
the released browser remains Pages `27c45ca0`. Everything below ran locally against the fixture backend, whose
`note-assets` route follows the deployed contract (idempotent PUT, 409/413/429 `quota`, GET `no-store`).

- **Codec and crypto** (`apps/web/tests/notes.test.ts`, 16 cases): all six fixture records decode and re-encode
  byte for byte; the five invalid fixture records fail with their stated reasons; the future record is counted and
  its note marked; ordering, renames, concurrent comments/titles (two versions; choosing writes after every head),
  tombstones defeating stale edits, counters after deletion, entries before their note, malformed counts; Library
  catalogs ignore Notes records and Notes ignore catalogs (both directions). The encryption vector matches byte for
  byte (stored blob, SHA-256, AAD, descriptor); length/digest/tag/account/blob/type tampering is refused; header
  dimensions are checked (PNG IHDR, JPEG SOF).
- **Storage and sync** (`notes-store.test.ts`, 6 cases, real WebCrypto and spec IndexedDB): one transaction holds
  sealed blobs, the new note and the entry (a fresh tab reopens them, no plaintext in IndexedDB); offline, the note
  root is sent and the entry held with "Waiting to sync"; on Retry the same blob IDs and bytes are uploaded, then
  the entry; a full store (429) holds the entry while a chat is sent and a dependent comment edit waits with it;
  repeated Save keeps one identity; text entries need no journal; on-demand fetch prefers the local copy, verifies a
  download (tampering refused), caches it encrypted and revokes object URLs on retire; blob records stay outside the
  range an older release counts and are removed with the browser's keys; cache eviction never removes unsynced crops
  and an over-capacity save commits nothing. `notes-capture.test.ts` (3): capture replies are bounded and bound to the
  open bundle; anchors keep only verified blocks and clamped rectangles; the frame CSP string and the shim's
  no-network rule are unchanged.
- **Capture fidelity** (opt-in `notes-capture.playwright.config.ts`, 20/20): the real reader frame (bundle CSP,
  sandbox, shim, bridge) on the DPO Mathpix sample and on the official arXiv HTML of 2305.18290v3 compiled by the
  shipped device compiler; text, display MathML, a figure, a mixed region and an off-screen equation; light and
  dark; Chromium 1× and 2×, Firefox, WebKit 2×, each compared with the browser's own screenshot of the same pixels.
  Chromium and Firefox: text and the off-screen equation match exactly (mean 0.00), display math and mixed
  regions within a mean of 0.1; figures differ by image resampling only (at most 0.4% of pixels without a match
  within one device pixel, Firefox). WebKit places some text lines one device pixel differently (strict mean up to
  3.9; within one pixel, mean ≤0.2 for text and math, ≤0.7 for figures, ≤0.06% unmatched). The first WebKit run left
  figures blank (WebKit paints pictures inside an SVG image only after its first paint); the frame's own decoded
  pictures are now painted over the render. No network request was made. Images and metrics: `.artifacts/notes-capture/` (this worktree).
- **Journeys** (`e2e/notes.spec.ts`, desktop and phone, 3 each): navigation (desktop Library · Feed · Notes; phone
  Feed · Library · Paper · Chat · Notes and ⋯ › Settings); new note, Add text, selection › Add to note, Paper ⋯ › Draw
  snippet with the exact PNG previewed, Saved to … · Open note, two encrypted uploads (no image signature on the
  server), thumbnail and zoom, edit comment, rename, dark mode; a second browser of the account syncs the note,
  downloads and decrypts the crop; Open in paper; search; delete snippet and note with confirmations; a full snippet
  store keeps the crop through a reload, says why and uploads it on Retry; figure and equation pages add their item;
  Escape cancels drawing; Whole view + Use snippet by keyboard. Screenshots reviewed in light and dark:
  `.artifacts/web-e2e/notes/`. One phone run of the quota journey raced the test's own quota switch after reload;
  the journey now waits for the held state before lifting the quota.
- **Regression**: Affected existing journeys were rerun on this branch and, for comparison, on base `82c8656`
  extracted locally (same machine and fixture). Desktop layout, library, library-actions, reader, reader-drafts,
  parity and owner-58: 31 pass / 5 fail / 1 skip on both, the same five failures. Phone layout, reader, parity,
  figure-view, equation-view, library, library-actions, library-window, catalogs, account-assets, owner-58,
  feed-personal, reader-drafts, build-62, chat and podcast-workspace: base 67 pass / 7 fail / 15 skip; this branch had
  three more failures. podcast-workspace used the phone's old top-navigation Chats button (the same All chats dialog
  is now ⋯ › Your assets › Chats, and the test takes that path on a phone); figure-view Find measured a scroll clamp
  at the end of a short fixture paper that the phone destination bar makes reachable (the test now requires the match
  to stay in view when the paper is scrolled to its end, otherwise the 3 px bound); library-window passed on two
  reruns (load-dependent). Afterwards figure-view, podcast-workspace and notes pass on desktop and phone, 34/34. The
  failures present on base as well — stale copy and consent version, model labels, Find similar papers ahead of Reader
  version details, draft-status text and others in account-delete, arxiv-html, build-62, chat-controls, chat-redesign,
  equation-view, journal, library-actions, owner-58 and reader — are pre-existing and unchanged here. A complete run
  of every journey was not finished (stopped after 64 desktop tests with only base failures).
- `npm test`: browser units 56 files / 520 tests (25 for Notes), backend 685 (+1 skipped), operations 18, egress scan
  and device PDF freshness pass; **compiler freshness fails** (`apps/apple/.../arxiv-reader.js` differs from a fresh
  esbuild of the unchanged compiler inputs in this worktree's `npm ci`); no compiler input changed on this branch.

Limits: see the Notes document's browser section — no encrypted composer drafts, session-only last destination,
no "Keep both", no hold menu or local-PDF capture; real Safari, the hosted function and native ↔ browser records are
untested; Playwright WebKit cannot persist device keys, so full journeys are Chromium-only. No paid call, physical
phone or NAS access.

## Notes images server — October 21 UTC (staging live)

The server half of the [Notes contract](architecture/NOTES_AND_SNIPPETS.md#server-status--blob-api-live-on-staging-2026-10-21-utc)
is deployed to staging: `PUT`/`GET /functions/v1/note-assets/{blobID}`, the private `note-assets` bucket, the
`note_assets` inventory with quotas (128 MiB/4,000 objects per account, 512 MiB environment, pending counted;
downloads 512 MiB/account and 4 GiB/environment per UTC month, metered before reading), account deletion of every
`{account}/` object with a verifying re-list, backup coverage and a Note images panel on the admin Spending page.
Native and browser Notes clients are separate work; nothing here is evidence of client encryption or sync.

- **Migration 095** applied by `scripts/deploy-staging.py` (via `migrate-supabase.py`) at **06:37:37 UTC**, ledger
  SHA-256 `646df2f48e47e470d36ea57538c5a015c6f858e83c7539b55eb8d49b846d3c45` matching source; 001–094 re-verified.
  Pre-migration encrypted checkpoint `20261021T063543Z-8bc9ea5dac4b` restores **212 tables / 15 objects** locally.
- **Bucket** `note-assets` created and verified: private, 2,097,180-byte limit, `application/octet-stream` only;
  staging has no `storage.objects` policies, so clients have no direct grant. **Functions** `account-delete` (06:37)
  and `note-assets` deployed; the final `note-assets` revision (refused bodies drained, below) was redeployed with the
  same Supabase CLI command at ~06:49 UTC from commit `8dfa578`'s sources.
- **Live check** `node scripts/smoke-note-assets.mjs` passes (runs started **06:51:10** and, with the maximum-size case, **06:51:34 UTC**) with two disposable
  `@example.invalid` accounts: preflight 204 (PUT and `x-content-sha256` allowed); no session 401; A's contract-
  encrypted 540-byte blob PUT 200 `{state:"ready",bytes:540}`, repeated PUT 200, GET 200 with identical SHA-256,
  `application/octet-stream`, `private, no-store`, decrypting under its account/blob AAD; another digest for the
  same ID 409; wrong digest header 400; 2 MiB + 29 B 413; 2 MiB + 28 B stored and read back (200/200); B's GET of A's
  blob 404 and B's same-ID object stored in B's folder with A's unchanged; both accounts deleted through
  `account-delete` → `{deleted:true, complete:true}`, folders listed empty, zero inventory and personal rows, old
  tokens 401. Afterwards: zero inventory rows, totals 0/0, bucket empty, personal counters erased; the environment
  month records 6 downloads and 6 read-backs (~2.0 MiB each).
- The **first live run** (06:40 UTC) found that Supabase's gateway held the 413 for an unread 2 MiB body until a
  504; unauthenticated 1 MiB PUTs reproduced it (504 after 160 s) and cancelling the stream did not help. The
  function now reads and discards up to 4 MiB of a refused body; re-probed 401s return in ~1.2–1.4 s. That run's
  fallback cleanup deleted both fixtures (0 rows, 0 objects). The same gateway behavior may affect other upload
  functions' early refusals; not investigated here.
- **Deploy workflow suite** (06:37 UTC): 17 pass, 1 warning (pipeline budget 76% used), 1 failure `budget.health`
  from a pre-existing unknown Anthropic chat attempt created 2026-10-17 14:48 UTC; `cleanup.accounts` deleted 5
  check accounts through the new deletion path.
- **Local tests:** `npm test` passes (after the final change too). `npm run test:database` passes in full, including
  `tests/database/note_assets.sql` (privileges/RLS, idempotency, conflicts, bounds, account/object/environment quotas
  with pending rows, two-account isolation, monthly limits with no charge on refusal, admin summary, deletion grace,
  plan, release and status) and `note_assets_concurrency.py` (one remaining slot of eight, eight identical PUTs → one
  row, eight digests for one ID → one winner, eight downloads at a three-download allowance → three). Backend:
  `note-assets.test.ts` 13/13 (uses the `notes-v1.json` encryption vector), `account-deletion.test.ts` 9/9. Deno type
  check passes. `tests/operations/test_staging_deployment.py` passes except the pre-existing stale DeepSeek fixture
  (no OpenRouter key); five other stale fixtures were repaired by adding that key to the default. `test_restore_quarantine.py`
  keeps its pre-existing `pdf_device_only` fixture error. Admin `check-spending-dashboard.mjs` passes; panel
  screenshots (desktop light, phone dark) were reviewed. Admin Pages **8aee70b1** is deployed and its live assets verified.

Evidence (main checkout): `.artifacts/note-assets/` (three check reports, deploy log, workflow report, screenshots),
`.artifacts/backups/20261021T063543Z-8bc9ea5dac4b`. No paid model call, owner account, physical phone or NAS access.
The Cloud Run worker's deletion sweep still runs the previous shared module (it removes every inventoried object but
does not re-list) until its next deploy. The admin panel was not viewed with live data, which needs an owner session.

## Notes and snippets — October 20 local / October 21 UTC (design/prototype only)

The owner-requested Notes/capture experience has a source-grounded [architecture and UX proposal](architecture/NOTES_AND_SNIPPETS.md)
and an interactive prototype at `docs/prototypes/notes-snippets.html`. It covers replacing Settings with Notes in
the compact tab bar, Settings in all top-right menus, capture/annotation/destination choice, ordered entries,
management, encrypted media and existing sync/key integration. It distinguishes the working encrypted event
journal from the missing encrypted image service and explicitly gates browser arbitrary-region capture.

No production app code, database migration, bucket, paid call or release is part of this design. Current clients
remain build 77/browser `27c45ca0`. Prototype interactions and simulated sync states are not evidence of Notes
encryption, offline durability or device-to-device synchronization. Implementation and the affected runtime
acceptance gates remain outstanding.

Local Chromium prototype review passes at **2026-10-21 05:40:54 UTC**: Settings round trips through all five
destinations; pointer capture and keyboard resizing; existing/new note destinations; optional comments; editing,
rename/search and deletion; standalone writing; hold/selection; simulated offline and missing-source states.
Control bounds pass in light/dark at 320, 390 and 736 px, with no JavaScript errors. Screenshots of capture,
composition, list and stream were visually reviewed, including narrow dark mode. The review corrected ambiguous
form labels, duplicate state restoration, overlapping small-box handles, region labels and empty-comment previews.
Report/screenshots: `.artifacts/notes-design/`; final prototype SHA-256:
`876a5c171aead2a5053b4b79f29c0d55a27185c9ef86b8cc18a7df19703913ac`.
JavaScript parsing and whitespace checks pass. No production test suite was rerun for documentation/mockup-only
changes; native capture, browser rasterization, media cryptography and hosted sync are expressly untested here.

## Recent-change parity and responsiveness — October 20 UTC (TestFlight 77 and browser live)

The iPad/browser/Mac audit covers named catalogs, account-return handling, queued keyword recovery, OpenRouter
routing and attribution, owner testing allowance, explainers and chat navigation. Existing release evidence is
kept separate from the new checks in the [platform review](reviews/PLATFORM_PARITY_20261020.md).

New repairs: iPad Contents uses page sizing after the height test reproduced the short centered form; the browser
routes immediately while the account-owned draft finishes saving; browser transcript following respects the whole
touch gesture, including the pointer cancellation when a pan starts; promoted figure/equation chat focuses its
retained composer. Native paper configuration uses one equivalent JSON encoding pass and composer focus no longer
waits a fixed 300 ms. The native build-76 scrolling repair remains intact.

Catalog, draft/navigation, paper/figure motion and contextual-chat promotion pass at four browser sizes. The final
eight motion cases pass after negative controls reproduce 1,541 px jumps. Mac wheel/stream/idle geometry, catalog
management and the full figure/focus journey pass; iPad catalogs, split-chat keyboard, equation tiles and full-height
Contents/discovery/relaunch pass; the shared Contents change also passes on iPhone Simulator. Native screenshots
were reviewed. The routine suite and final 495 browser unit checks pass. Playwright WebKit's eight durable-key
capability skips are not Safari acceptance; physical iPhone access remains paused.

iPhone/iPad and Mac TestFlight **77**, source **562ba8b**, are **VALID / IN_BETA_TESTING**, with both platform
states and release notes read back at **15:55:20 UTC**. ASC IDs: iOS `599071dc-b0dd-4c98-af29-ab116161a20e`;
Mac `5ebff063-3045-4837-a00c-a58adf3cb7ee`. The fresh optimized import/session gate passes **15/15, zero skips**
at **15:23:10 UTC**. Both signed archives pass executable/dSYM identity and test-probe exclusion checks;
iOS includes iPhone/iPad and excludes local answering runtimes/models, while Mac includes arm64/x86_64 and an
empty model catalog. The first Mac archive failed its final packaging step; the unchanged-source retry completed
cleanly. Its original error and undiagnosed cause are retained in the review, not relabeled as a product fix.

Browser Pages **27c45ca0** uses the same **562ba8b** source. At **15:22:21 UTC**, the live domain's three entry
scripts/styles and Apple app association match the release byte for byte. Release readbacks, signed archive
identities and the import gate are under `.artifacts/releases/77/`.

The requested no-markup USD balance, per-request spend log and category view remain **design only**, documented
in [Dollar balance](architecture/DOLLAR_BALANCE.md). No fractional settlement prototype is included in this release.
Replacement local models remain unqualified and the Mac catalog remains empty. No paid model calls, backend
migrations or additional infrastructure commitment are part of this parity work.

## Native chat scrolling — October 20 UTC (TestFlight 76 on iPhone/iPad and Mac)

The reported vibration reproduces offline: unchanged messages change height as the old hosted rows cross screen
edges. The fixture-only old-renderer control measures 116 pt height drift and 113.67 pt movement beyond the finger.
The replacement keeps the same table and interaction, uses contained hosting controllers with row safe areas
disabled, resolves stale reused heights before measurement, and retains measured estimates. Streaming presentation
waits through dragging/coasting; unrealized offscreen updates no longer reapply the whole table snapshot. The
static and streaming checks pass, including reading within the growing answer. Final iPhone checks pass 3/3;
iPad motion has zero measured tracking error across 9,370 comparisons, and both split-layout keyboard journeys
have passing runs. Light/dark rendering and selection/formula actions were checked. The fast suite passes.
Architecture and evidence: [Chat](architecture/CHAT.md#native-transcript-sizing-audit--2026-10-20-utc)
and [Testing](TESTING.md#native-chat-motion-audit--october-20-utc).

iPhone/iPad and Mac TestFlight **76**, source **365aeaa**, are **VALID / IN_BETA_TESTING**, with both platform states
and release notes read back at **05:51:31 UTC**. ASC IDs: iOS `d452b1d6-d795-45de-892e-ac37b11c80da`;
Mac `9a358dae-92ec-4197-8f74-150b2d68174b`. The fresh optimized import/session gate passes
**15/15, zero skips**, at **05:26:18 UTC**; the Mac chat show/hide and Settings-return journey passes **1/1**.
The signed iOS archive passes signature, dSYM identity and local-answering-runtime exclusion checks; the motion
probe and old-renderer control are absent from both release binaries. Mac 76 uploaded at **05:48:37 UTC** from
the same source; its signed universal archive, both architecture dSYMs and empty local-model catalog pass verification.
Evidence: `.artifacts/releases/76/`, including `release-76-provenance.json`. No browser deployment, physical-phone
access or paid model call was needed for this repair/release.

## Unlimited owner testing — October 19 UTC (server/browser live)

Migration 094 is applied and verified. The freshly signed-in owner account has an audited testing policy that
replenishes its dedicated real credit bucket before each new operation. Initial readback: 100,000 available,
zero reserved, one grant and one audit. Installed build 75 works with this balance immediately; its number
replenishes automatically. Purchased credits, actual provider charges and platform spending controls remain
separate. The native **Unlimited testing** label is included in iPhone/iPad and Mac TestFlight **76**.
Browser Pages **a19c9248**, source **c461f6b**, includes the new label.

The affected database suite passes, including OpenRouter accounting and account lifecycle, plus eight concurrent
replay contenders and three independent refill contenders. `npm test`, the browser production build and native
balance decoding pass. Backup `20261019T173906Z-1cb0404ffc5d` restores 211 tables / 15 objects locally. No physical
iPhone or paid model call was used. Evidence: `.artifacts/testing-allowance-*` and the private grant readback under
`.artifacts/credits/owner-unlimited-20261019/`. The separate $5 offer awaits the purchase interval clarification;
normal plans and prices remain unchanged. Subfigure training status below is unchanged; no new run was started.

## Account deletion / return and stuck keyword edits — October 19 UTC

The owner's repeated OAuth lockout was the unchanged global signup block after deletion erased the precreated
Auth login. Staging now keeps exact verified-address beta admission independently of the account. Migrations
091–093 and the Auth hook are applied/verified; unknown public signup is denied. Two synthetic delete → public
self-creation → verified login/account-RPC cycles pass, with fresh UUIDs and old tokens rejected. The prior owner
address is admitted without recreating or impersonating the owner. Deleted content, roles and credits stay deleted.
The local SQL suite covers revocation, ACLs and stale admin-command replays. The final encrypted checkpoint
`20261019T044047Z-2362347ee4c9` restores **211 tables / 15 objects** into an isolated local database; hosted recovery
is not claimed. Details: [Native authentication](architecture/NATIVE_AUTHENTICATION.md).

The browser now shows invitation refusals instead of treating `access_denied` as silent cancellation; desktop/phone
OAuth journeys pass **8/8**, and Pages **e8aa027f** is deployed with served assets checked. Native auth unit checks
pass **45/45**, Core callback checks **5/5**. iPhone/iPad TestFlight **74** is **VALID / IN_BETA_TESTING**,
with release notes read back. Mac 74 uploaded at **05:20:40 UTC** and is also **VALID / IN_BETA_TESTING** (read back **05:24 UTC**),
with its release notes verified. Both archives use **028a7f6**;
the required native acceptance gate passes **15/15**, none skipped. Binary hashes and the exact gate are in
`release-74-provenance.json`. Actual interactive Apple/Google provider and physical-phone acceptance remain
unverified. No physical iPhone was accessed.

The Library refresh banner has a separate proven cause: the native transport rejects valid `v5_set_source_details`
requests before HTTP. Its allowlist and source-edit byte bound are corrected; the regression first fails with
`invalidMutation` with a valid small edit. Recovery of the same persisted operation through real transport now
passes for small and full-size edits; all **23** affected transport/coordinator cases pass. Core source-keyword
bounds/receipt checks pass **4/4**. The full Core run passes all behavior checks except an outdated Google processor
label expectation; correcting that test to the already shipped “Google Vertex through OpenRouter” passes the
affected **12/12** profile cases. The
required native gate now includes that path and visible Apple/Google refusal handling (**15 cases**). `npm test`
passes. Evidence is under `.artifacts/feedback/catalogs-20261019/`. Named catalogs are now available in the browser
and iPhone/iPad/Mac build 75, which also includes these access and queued-edit repairs.

## Named Library catalogs — October 19 UTC (browser and TestFlight 75 live)

Native and browser Catalogs offer create, rename, switch, default selection and explicit deletion dispositions:
move to another catalog, move to a named new catalog, or remove the papers through existing library commands.
New arXiv and local-PDF additions capture the selected catalog; existing paper/chat identities remain intact.
Catalog metadata uses existing encrypted notes, without a new backend schema. Seven Core and seven browser
projection cases pass. Eleven native model/PDF cases pass (one optional corpus check skipped); iPhone and iPad
catalog screen journeys pass, as do all six desktop/phone browser journeys. The final mandatory import gate
passes 15/15, none skipped, including the real-paper corpus, at **05:49:03 UTC**. `npm test` passes; native and
browser screenshots were reviewed. The iPad's first attempt never started an app test: its CoreSimulator launch
stalled; the stack/log are retained, and the restarted Simulator completed the flow. The earlier numeric-receipt
fixture crash is fixed and verified by both screen journeys.

Browser Pages **3f363fda** is deployed from **0344e4d**, with live entry assets and app association verified.
iPhone/iPad **75** uploaded at **05:56:04 UTC** and is **VALID / IN_BETA_TESTING**, with release notes verified.
Mac 75 uploaded at **06:04:04 UTC** and is also **VALID / IN_BETA_TESTING**, with release notes verified.
Both platform states were read back at **06:07:35 UTC**. Evidence and exact counts are in
`catalog-release-verification.json`; archive hashes and acceptance identity are in `release-75-provenance.json`.
No physical iPhone or paid model call was used.

## Subfigure round 3 — 2026-10-23 (research; no new model adopted; gates not met)

The arXiv HTML already splits 15.7% of figures into exact images (no model needed); single-image figures (74%)
remain the model's job. A bottom-up ink-grouping model (components + learned affinity, 2.9 MB) removes clipping
by construction but scores 68.5% fully right / 24% harmful on validation versus 77.3% / 12.2% for the 10-22
detector, so it is not adopted. A local Qwen2.5-VL-7B judge (Apache-2.0) is reliable for single/compound (92%),
panel count (85%) and letter reading (97%) but degenerate for ownership, grouping and split verification; as a
label filter it gave no measurable gain. Count disagreement is a strong offline "unsure" signal (87% vs 21%
perfect splits) and is proposed for the explainer flow. A fresh test-3 candidate set and an independent review
packet are prepared. Details: [round 3](reviews/SUBFIGURE_DETECTOR_20261023.md).

## Subfigure detector release candidate — 2026-10-22 (research; not released; gates not met)

A rights-clean release candidate (RT-DETRv2-M trained only on corpus-derived and synthetic data, plus
completion, OCR letter grouping, caption-constrained decoding and two-view agreement) was frozen on validation
and scored once on a **new never-seen test** (240 figures, 201 papers from unused author families, annotated
before any model saw it): **73.3% (95% CI 67.8–79.0) fully right, 18.8% harmful, panel recall 84.1%**
(previous v13 detector: 52.9% / 29.6%; 10-21 system: 70.4% / 21.2%). The gates (≥ 95% recall, < 2% wrong
crops) are **not met**; clipping and framed diagrams dominate the errors, and the targeted class data gave no
clear per-class gain. Core ML FP32 exports (132 MB R50-M, 80 MB R18) give identical delivered crops; FP16 and
int8 weight compression change decisions; ONNX runs in Chromium via onnxruntime-web WASM (1.7–2.7 s).
`scripts/subfigure-detector/` is now a documented package with configs, a pytest suite and the reference
on-device `decide()` API (parts P1… or "whole" fallback) for step-2 integration. $0 model spend; no app code
changed. Details: [Subfigure detector 10-22](reviews/SUBFIGURE_DETECTOR_20261022.md).

## Subfigure detector from the PDF corpus — 2026-10-21 (research; not released)

A new app-level evaluation scores crops as displayed: complete panels, no false splits, correct counts.
On a new held-out arXiv final test (235 figures, 201 papers in unseen author families), the previous best
detector is fully right on **59.1%** of figures and shows wrong crops on 24.7%. The 17K-paper corpus was turned
into a data engine (exact labels from 35,779 figure PDFs' drawing operations, caption-verified whitespace and
LaTeX sub-figure labels, synthetic compounds, agreement-filtered pseudo-labels). The frozen system
(RT-DETRv2-M + completeness post-processor + caption-constrained decoding + two-view agreement), scored once:
**80.4% (95% CI 75.3–85.3) fully right, 8.9% harmful**; on the old SCI-3000 test 91.9% vs 88.1%. It does
**not** meet the acceptance gates (panel recall 80%), so it is a candidate-part provider, not an automatic
cropper. The model-free completeness step alone fixes many clipped crops (test 59.1% → 64.7%; simulated AI boxes
with 6% error: perfect splits 43% → 90%) and is the recommended first integration. A rights-clean model
(no SCI-3000) is equally good. FP32 Core ML (identical delivered crops) and ONNX exports verified on the Mac/host.
$0 model spend; no app code changed. Details, integration plan and failure galleries:
[Subfigure detector](reviews/SUBFIGURE_DETECTOR_20261021.md).

## Owner GPU subfigure training — updated 2026-10-19 UTC (research; not released)

Fine-tuning experiments ran in an isolated workspace on the explicitly authorized RTX 3090 host. The selected real
corpus contains 1,846 figures from 398 papers, with 235 figures/60 papers reserved for an unscored final test.
The fresh-start/spatial-variation run finds 284/297 panels on 89 compound validation figures at IoU .75, with
8 false crops (95.62% recall, 97.26% precision). Across all 297 validation figures, precision is only 89.76%
because single figures are also falsely split. Shared context and some panel letters remain incomplete; no
model meets the acceptance gates. Composite augmentation and a natural-sampling run did not improve quality.
A learned single/compound gate improves all-figure precision to 92.51%, still short of the target. Offline Mac
OCR, containment loss and generated shared context
have not qualified a model. An earlier trained checkpoint passes FP32 Core ML parity on seven development
figures; this is not crop-quality acceptance. Source rights/annotation review, final test and full Mac runtime
acceptance remain open. No application source, catalogue or deployment changed. Dataset, training, cost and
evidence details: [Subfigure training](reviews/SUBFIGURE_TRAINING_20261018.md).

The owner's PDF-saving service was found: `gradstep-acquire.service` in `/home/ben/mathpix` on the same host,
with 17,372 arXiv PDFs and 525 PMC PDFs. That folder/service remains unchanged by this work. A verified 12-paper,
69 MiB sample was copied to the Mac; PDF parsing/rendering stayed local. Automatic figure labels exposed clipped
and contaminated candidates. The first development annotation batch has 30 training figures and 16 validation
figures from separate papers, with explicit shared-context relationships and checked duplicate/author boundaries.
These are Codex visual annotations, not independent human review. Only extracted images/annotations went to the
GPU workspace. The original 235-image final test remains byte-identical and unscored.

The prior model gets only 32/38 panels with 6 false crops on these new validation papers at threshold .6; shared
context remains poor. `mathpix-v11-fresh` completed on the combined 1,728-image dataset but regressed: 29/38 new
panels with 8 false crops, and worse original-cohort results. It is rejected. The completed `mathpix-v12-gentle`
adaptation gives 31/38 new panels with 6 false crops and lower original-cohort recall; it is also not accepted.
The same validation cohorts/annotations remain fixed. No GPU job remains running at 00:35:35 UTC; no new API spend.
Source archives also preserve original figure images: eight PCBWorld assets match the exact original archive,
and a source-pixel/PDF-text recovery proof reconstructs all six panels of a previously truncated figure with
their labels. This improves the next annotation workflow, not the detector's measured accuracy.

Source-assisted expansion now adds **35 reviewed training figures from 15 further papers**, with 113 panels and
54 required-context links. Full decoded source-image/PDF identity and printed subcaptions guide the annotations;
shared headings and contaminated margins required visual corrections. The combined set has 1,763 training images,
with the 313 validation and 235 final-test files unchanged. `source-v13-gentle` completed: combined false crops
fall from 61 to 42, but found panels fall from 514 to 513, with compound recall also lower. Required-context links
retained rise from 56/120 to 64/120; this remains far below acceptance. `source-v14-laststage` also completed:
513 matched panels / 51 false crops / 30 missed, with context only 57/120. It gains one matched new-domain panel
versus the baseline but loses two original-domain panels. Neither run is accepted. No GPU training job remains
active after 01:03:15 UTC. The Mathpix project remains read-only, PDF processing stays on the Mac, and paid spend
is $0. These are measured validation tradeoffs, not a qualified model or release.

A targeted continuation adds **41 training figures / 34 papers / 67 panels / 40 required-context links**, including
24 native source figure PDFs rendered and reviewed only on the Mac. Combined training is 1,804 images; both
held-out sets are unchanged. `targeted-v15-gentle` completed at 02:06:04 UTC: **506 matched panels / 44 false crops /
37 missed**, context **60/120**. It improves the small new cohort but loses nine original-cohort matches versus
v13 and is not accepted. Visual review confirms merged chemistry panels and clipped image/axis edges. Most
missing context comes from absent/mislocalized heading detections, not a small edge-margin defect.
`targeted-v16-balanced` also fails: 510 matched / 55 false / 33 missed, with context 53/120. Fresh-training v17
finishes at 02:31:08 UTC: 507 matched / 57 false / 36 missed, context 31/120. None improves overall on v13.
All three comparisons are complete, and no GPU training job remains running. The new context-failure report
reconciles its counts with the crop scorer; OCR/margin and confidence diagnostics do not establish a fix.
Forty-four regression checks pass on Mac and GPU host; `npm test` passes. No paid model calls, Mathpix writes
or release. Qualification remains open.


## Later October 18 feedback — TestFlight 73 on iPhone/iPad and Mac; browser deployed

iPhone/iPad build **73** is **VALID / IN_BETA_TESTING**, read back after its 21:34:36 UTC upload.
ASC ID `4fdf3cd5-74a4-4813-b605-0108f1a81fe9`; release notes were written and read back. Its signed archive
contains production source **1262117** and passes the local-answering-runtime/catalog/resource exclusion guard.
Subsequent native verification commits change tests, research scripts and documentation, not the archived application source.
Mac **73** (production source identical, verification commit **1e86de7**) is also **VALID / IN_BETA_TESTING**;
ASC ID `a2a01f17-a94a-49ad-9292-6e51d2067eb5`, uploaded 21:40:46 UTC. Both platforms and their release notes were
verified at **2026-10-18T21:45:12.181Z**. The archived Mac model catalogue is empty, reflecting the retirement of
unqualified prototypes. Binary hashes, catalogue checks and the import result are retained in `release-73-provenance.json`
under `.artifacts/feedback/build71-20261018/`.

Six additional reports at 20:45–20:56 UTC are implemented: full-height Contents; a touch double-tap opens it with
persisted first-use discovery; instant section jumps; all reference actions visible together; separate
Library Device/Authors columns; and no visible keyword Edit label. The missed animation was a second bridge path
that still explicitly requested smooth scrolling. Native and browser frame timing now verifies the jump without
Reduce Motion. The existing complete figure-card change and Mac prototype retirement are included in this source.

Seven unique affected iPhone Simulator journeys pass, including figure/chat, Contents/equations, reference actions,
double-tap/relaunch and Library columns. Saved screenshots were reviewed. Two native bridge regressions and all
four targeted browser desktop/phone cases pass; `npm test` passes. Browser Pages **8d2514ec** is deployed with live
asset/AASA verification. App Store feedback readback contains 203 reports and no further unseen reports. The fresh
optimized import gate passes **13/13, zero failures/skips**, matching production source at **21:22:26 UTC**. Mac
Library/model-retirement journeys pass; the corrected Contents/equation viewport journey passes at **21:30:19 UTC**.
Saved screenshots and the Catalyst accessibility hierarchy were reviewed.
Mac chat-generation and Library-column units pass **54/54** with a complete result bundle. Disabling coverage collection
for this focused run allowed result finalization; the earlier completed-test logs with unfinished bundles remain
retained rather than being represented as valid result bundles.

Admin Pages **a0540bb2** is deployed and its live assets verified. The billing-refusal warning now distinguishes
logical model-provider groups from the current OpenRouter billing gateway and directs investigations to the
recorded attempt details in Spending. The account UUID/receipt drill-down from **2506e98b** remains intact.

## Build 71 feedback and OpenRouter consolidation — 2026-10-18 (TestFlight 72 on iPhone/iPad)

iPhone/iPad build **72**, source **de722cf**, is **VALID / IN_BETA_TESTING**, read back at 20:36 UTC.
ASC ID `2f20c64f-0444-4275-ac9d-4d606f9c2b42`; release notes were written and read back. Its signed archive
passes the local-model/MLX exclusion guard. The source-matching import gate passed 13/13 at 20:19:10 UTC.
Mac model retirement and the eighth figure-card report are subsequent work, not included in this iOS build.

Seven screenshot reports are implemented and their affected native regressions pass; exact diagnoses and test
coverage are in [OWNER_FEEDBACK.md](OWNER_FEEDBACK.md). The initial import gate exposed an asynchronous test race;
waiting for the real library search retains the rendering assertions. The fresh optimized import/session gate
passes **13/13, no skips**, at the timestamp in `.artifacts/import-acceptance/latest.json`. This does not resolve
or erase the separate, older intermittent Rubric Judgments/DocPilot failures.

Migrations **089 and 090**, the chat function and pipeline worker **00049-ghn** are deployed on staging. All remote
inference entrypoints use OpenRouter; direct model-host egress is blocked. Every paid dispatch requires the durable
account/service UUID, operation and unique attempt grant; receipts retain serving provider/model, generation ID,
timestamps, token counts and actual cost, with uncertain bills held. Admin Pages **2506e98b** and browser Pages
**5a1533bc** are deployed. Owner access after account recreation was restored only after matching the verified
email against the original owner audit evidence; normal MFA remains required. No credit/budget increase occurred.

Wire chat/script/speech checks and hosted paper chat pass. Full hosted podcasts exposed reasoning-policy and
quality failures; completed episodes are not yet claimed for this rollout. Details and exact amounts are in
[PROVIDER_SPENDING.md](architecture/PROVIDER_SPENDING.md). One preexisting direct-Anthropic $0.000138 uncertainty
remains held, with no receipt permitting settlement. Migration 090 excludes orphan, unclaimed metadata with no
interested reader from stuck-job alerts while keeping claimed/interested work covered.

The iPhone/iPad build now excludes local answering MLX code/catalog/resources; an archive guard enforces this
before upload. Device-only PDF extraction remains. Mac replacements are undergoing actual offline qualification;
Qwen 9B and Gemma 12B failed critical scientific checks. Neither is promoted merely because it fits or runs.
Subfigure research/fine-tuning design is updated; no detector or newly trained model is claimed released.

## Later figure-card feedback and Mac retirement — 2026-10-18 (included in TestFlight 73)

The eighth report (3DCodeVerse-2M Figure 2) adds typed panel/concept/related-work cards and complete-image coverage.
The backend is deployed; browser Pages **37ef6b86** passes asset/AASA checks. Cards retain their full overview,
measure the union of displayed crops and explicitly label incomplete coverage. Both clients round outward to
whole pixels. Backend (136), Core figure (10), browser figure (14), routine fast tests and all 12 desktop/phone
figure journeys pass. Screenshots were inspected; a cropped-image fullscreen control width defect was also fixed.
The live Flash walkthrough/detail check costs $0.029884 and returns two full-height halves whose union covers the
source image. This is not broad detector qualification. Details: FIGURE_VIEW.md and OWNER_FEEDBACK.md.

The Mac catalogue retires all four small prototypes; historical encrypted answers remain readable and only their
app-owned public weights are removed. No replacement has passed the scientific gate. Settings says so explicitly;
no candidate is offered as a qualified model. Local store/admission tests pass 7/7. Mac integration exposed and
fixed loss of the explicit local engine during a selection action; 32 affected chat-generation tests pass. The
requested two accepted options remain outstanding. Qwen 27B is pinned/downloaded but lacks available test memory;
other user applications were not closed. New subfigure geometry replay and fine-tuning implications are recorded
in LOCAL_FIGURE_REGIONS.md and its measured review. No training or paid GPU job has been started.
The proposed official RT-DETRv2-S baseline has also been converted and replayed locally with networking denied:
FP32 passes numerical parity on seven figures; FP16 and a mixed-precision variant fail. These generic COCO weights
are not trained or accepted as a scientific-panel detector. The measured evidence changes the fine-tuning/export
baseline to FP32, without adding a model to either application.

## Build 70 feedback — 2026-10-18 (TestFlight 71 on iOS/iPadOS and Mac; browser deployed)

Build **71**, source **c4d15d9**, is **VALID / IN_BETA_TESTING** for iOS/iPadOS, confirmed at
**2026-10-18T17:04:13.483Z**. Its internal-only upload succeeded and release notes were written and read back.
ASC build ID: `4fbc78aa-e0f0-4eab-b13a-553cf38687c1`. Mac build **71**, source **927cbe9**, is also
**VALID / IN_BETA_TESTING**, with both platforms and their notes verified at **2026-10-18T18:02:37.560Z**. Mac build ID:
`867811b7-ec6b-41c5-aa4e-dfeab31932e9`; upload succeeded at 17:59:15 UTC. Browser Pages **13724098** is deployed.

Twenty new screenshots after build 70 were downloaded and inspected individually; no new support/crash reports
were found at intake. Exact IDs and requests are in [OWNER_FEEDBACK.md](OWNER_FEEDBACK.md). Work includes:

- App-owned Find with an occurrence list, previous/next, bounded non-mutating highlights and dismissal on tab
  changes. Source-only papers now save/restore position: the old path incorrectly required a legacy artifact ID.
  References jump directly. A citation from an explainer offers return to its exact saved paper/bundle/item.
- Fullscreen figure/crop viewing before zoom; table-specific loading text; promotion of the same contextual
  conversation into Chat with its draft/model/explanation/image. Prompt repair replaces explicit thin-slice
  guidance with complete panels and interpretation. A 2% display margin protects nearby labels, while whole
  images remain available. The live FDE-Gym Figure 5 run passes all three actions for $0.039627; `chat` is deployed.
- Settings defaults for general chat, paper chat, equations, and figures/tables. Explicit/current conversation
  choices win over defaults; their reason is visible. Cancelling a chooser drops temporary choices. No evidence
  identifies why the particular historical screenshot showed DeepSeek; there is no invented causal diagnosis.
- Keywords before Introduction with attribution/Edit, generic AI/ML terms excluded, specific title/abstract
  terms, and customized/cleared user tags retained. A bounded in-memory index rebuilds terms from encrypted
  installed native bundles and removes them with paper contents/account retirement. This is not a trained keyword
  classifier or a corpus-wide TF-IDF evaluation. The FDE-Gym one-item abstract list uses the body's reading width.
- Optional field criteria with AND semantics, Find similar, clearer search progress, and Source URL/Gradstep
  sharing. Installed links open the matching paper; missing papers open Search without import. AASA and signed
  Associated Domains are part of release verification; physical-phone universal-link launch remains unverified.
  DOI links preserve the source identity but do not promise every publisher is available in the discovery catalog.
- Mermaid/HTML actions alongside suggested follow-ups. Browser parity includes cloud activity defaults, search,
  keyword presentation, links, Find, fullscreen, citation return and promotion. Browser model inference remains cloud.

Verification: the routine fast suite, Core FigureViewTests (8), PaperDiscoveryTests (3), native Find journeys (3)
and Local AI fixture journeys (6) pass. Final iPhone retests pass for Library metadata/account retirement, scenario
and conversation ownership, the complete figure journey and the local figure journey. The Settings journey
changes paper and figure defaults independently and verifies the new paper chat's selection. Exact FDE-Gym
rendering passes both themes with 25 headings/63 equations/seven images, no horizontal overflow and working
selection. Browser Find/search/link and figure journeys pass, including the final display-margin assertions.
The initial iOS release-optimized import/session gate passes **13/13, zero failures/skips**, matching source at
**16:57:23 UTC** (`.artifacts/import-acceptance/2026-10-18T16-48-10-757Z.xcresult`). Both signed build-71 archives
pass identity/signature, compiler/catalog/resource and Associated Domains checks. No downloaded LLM weights or
environment files are bundled. The deployed `chat` and `discover` functions need no new migration; browser Pages
**13724098** passes entry-asset checks and an exact AASA JSON/app-identity readback at `https://app.gradstep.ai`.
Release feedback readback at 18:03 UTC still contains 189 screenshots, no next page or new submissions.

Mac Library/draft units, the figure Ask-in-Chat journey and four keyboard journeys pass. The full figure retest
initially encountered a macOS system dialog; the owner's subsequent Continue resumed the ordinary app test,
which passed without inspecting or controlling that dialog. Visual review then caught a separate acceptance
gap: Catalyst displayed the fullscreen figure in a small sheet. The final Mac correction uses a fitted sheet
sized from its owning reader window. The complete journey passes at 17:40 UTC, including visible-window geometry,
X/Escape/⌘W, extraction, citation return and Chat transfer; fullscreen and transferred-draft screenshots were
inspected (`mac-fullwindow-sheet.xcresult`). The shared wrapper also passes the full iPhone figure journey at
17:49 UTC, with fullscreen and transferred-draft screenshots inspected. The replacement signed Mac archive,
source `927cbe9`, passes signatures, both architecture/dSYM UUIDs, entitlements and resource identity checks.

The fresh import/session gate passes **13/13, zero failures/skips** at **17:53:29 UTC**
(`.artifacts/import-acceptance/2026-10-18T17-49-34-442Z.xcresult`), followed by three bounded corpus repetitions:
**21/21 reported-paper imports and offline reopens** at 17:56 UTC (`import-repeat-diagnostics.xcresult`).
Two earlier Simulator runs failed intermittently: Rubric Judgments preparation timed out, then a separate replay
accepted that paper but refused DocPilot. Their precise causes remain unproven. No speculative production import
change was made; test diagnostics now preserve the reader timeline and fail at the first error instead of
producing misleading follow-on offline errors. The original timeout and acceptance criteria are unchanged.
Passing later runs is not presented as a root-cause fix. Mac 71 was uploaded after the passing checks and is
available as recorded above. Commit `863cdca` adds only test diagnostics/documentation after the signed app source.
The earlier signed archive is retained but is not the final Mac candidate. Physical-phone access remains paused, including
universal-link launch. Artifacts: `.artifacts/feedback/build70-20261018/`.

Local subfigure research has a working Mac Core ML prototype and documented shared-context architecture.
The 18.8 MB detector runs at median 23 ms after loading on M1 Max, but misses workflow regions and clips heatmap
labels at high confidence. AGPL research weights are not bundled. No physical iPhone, battery or memory acceptance.
See [experiment](reviews/LOCAL_FIGURE_REGIONS_20261018.md) and [design](architecture/LOCAL_FIGURE_REGIONS.md).

Previous checkpoint, 2026-10-18 UTC: TestFlight **70**, source `2e461b4`, was VALID / IN_BETA_TESTING on iOS/iPadOS and Mac at `2026-10-18T07:20:34.040Z`, with browser Pages **6ddf4887**, migration 088 and author search deployed. Flash remains recommended. Earlier checkpoints are historical.

## Build 69 feedback — 2026-10-18 (TestFlight 70 and browser deployed)

All 169 screenshot submissions were checked; 19 new build-69 reports and four earlier unclosed UI requests are
tracked in [OWNER_FEEDBACK.md](OWNER_FEEDBACK.md). The final feedback read still returns 169, with no next page.

- Equation and figure explanations share a view with anchored, encrypted conversational follow-ups. Main-chat
  drafts are restored on exit; account changes retire the contextual owner. Cloud failure recovery stays in place.
  The composer names the actual model; local attribution omits the compatibility cloud profile. Model choices
  use two rows. Local downloads/defaults and measured memory/performance details live in Settings; downloading
  no longer requires inference headroom. Physical iPhone inference remains unverified and larger models still
  require enough app memory. The current distribution profile lacks the optional increased-memory entitlement.
- Equation zoom now scales after fitting and pans automatically; the reported routing-cases and quantum-ket
  expressions typeset. Figure crops pinch/pan, including a usable gesture area for tiny bitmaps. Equation actions
  start with Chat about Equation, remove the duplicate/Why actions, and copy the full LaTeX as text.
- Paper keywords are editable before the introduction, including explicitly clearing all inferred tags. Author
  taps offer an author-only search; the browser checks an actual search request, including a fixed stale-query
  race and DataCite’s reversed name order (live author query: 40 papers). Library shows 0 chats and the source's real Added date; Adding titles are centered in equal-height rows.
  Account/sync and chat heading/draft-label changes are included. Explicit on-device dictation fills a draft;
  microphone/speech purpose strings and Mac audio entitlements are included. Actual microphone input is not
  certified by the deterministic UI fixture.
- Reader revision **21** repairs the affiliation/contact block in **2610.22353v1**. Exact-source full compilation
  retains 224 blocks, 369 equations, 7 figures, 22 images and all non-whitespace paragraph text. The exact
  cached source also passes native WebKit compilation and independent admission in 2.94 s with `-O`. Existing saved
  papers use Reader version details → Update this paper. Shared validator changes also rebuild device-PDF
  converter **4**, without changing its extraction behavior. The 123-paper cached sweep has zero failures
  (eight retained warnings, one source without HTML); full device compilation passes the reported paper and
  2610.16794v1, 2610.20584v1 and 2610.20592v1. The last three caught a pre-release affiliation formatter defect:
  flattening superscript math marks left dangling equation-index entries. Revision 20 preserves those marks and contacts. Revision 21 also repairs WebKit-only encoded image
  overflow on 2610.20592v1: bounded downsampling retains all seven figures and 347 equations, without raising
  admission limits. All four native real-paper cases pass; the largest completes in 13.74 s. Final revision-21
  sweep: `sweep-2026-10-18T06-57-19-355Z.json` (123 papers, zero failures, eight unchanged warnings).
- Migration **088** is deployed and verified, projecting immutable source creation dates and preserving explicit
  custom/empty keywords through deltas and archive operations. The discover function is deployed. Browser
  Pages **6ddf4887** is deployed at app.gradstep.ai; entry asset MIME checks pass, and the hashed virtual
  compiler module actually imported by the browser matches local revision 21 byte-for-byte.
- Fast tier, full database suite plus final targeted metadata replay, focused Core checks and 20 desktop/phone
  browser journeys pass. Native cloud recovery, Settings/dictation controls, local chat/equation/figure flows,
  saved-answer recovery, equation overflow/typesetting and crop pinch journeys pass. Final iPhone follow-up acceptance passes with two completed answers visible above the keyboard and reopening
  the saved conversation. The iPad figure-chat, Settings/dictation and wide-equation journeys pass. The Mac
  equation journey passes after replacing an unsupported Catalyst edit-menu presenter; it clicks the equation,
  opens AI Explainer, renders its answer and closes the view. The source-matching import/session gate passes **13/13, zero failures/skips**, finished at 07:02:20 UTC
  (`.artifacts/import-acceptance/2026-10-18T06-57-10-500Z.xcresult`). Fast tier: **660 backend / 479 browser** tests.
  Both signed archives match the tested revision-21 compiler, device-PDF converter 4 and local-model catalog.
  Speech purpose strings, Mac microphone/audio entitlements and MLX Metal resources are present; model weights
  and environment files are absent. Internal-only uploads and both release-note readbacks are verified.
  Xcode reported an iOS post-build file-removal permission error after writing the archive. Its content/signature
  audit and executable/dSYM UUID match passed; exporting that completed archive passed Apple validation and
  upload, followed by VALID / IN_BETA_TESTING. No permissions or release gates were bypassed.
  Evidence: `.artifacts/feedback/all-20261018/`. No paid AI calls or physical-phone access in this batch.

## Build 68 feedback: Equations hang and unfunded Claude route — 2026-10-17

- The actual feedback paper, **1805.03662v2**, has 105 display equations. The native markup scanner repeatedly
  lowercased the remaining HTML for every tag, for every equation. The old optimized replay exceeded 90 seconds;
  the repaired bulk scan extracts all 105 complete fragments in **0.0417 seconds**. The actual-paper Simulator
  journey passes: open Equations, switch tabs, select a formula and reopen Contents. The regression also covers
  long Unicode tails, missing IDs and out-of-order IDs. No paper re-import or reader-version update is required.
- The owner's 22:39 and 22:45 UTC Sonnet failures were direct-Anthropic **provider_billing** rejections with zero
  cost; the next Flash requests on funded OpenRouter succeeded. Migration **087** and
  `CHAT_CLAUDE_OPENROUTER=on` now route Claude chat/explainers, titles, suggestions and study maps through the
  pinned OpenRouter → Google Vertex US endpoint. Flash remains recommended; saved choices remain respected.
  Separate catalog/podcast adapters are unchanged. New attempts freeze the distinct route/rates; historical bills,
  named consent, server spending admission and the existing budget remain intact.
- Live checks cover Haiku equation symbols, figure walkthrough/simpler/detail, three study exchanges and maps,
  Sonnet chat/title/suggestions and unchanged Flash chat: **17 successful hosted generations**, reconciled to
  provider receipts. A forced-tool HTTP 404 was reproduced and fixed using the same tool's structured-response
  schema; ordinary chat/figure tools are unchanged. Opus is covered offline; its live request was stopped before
  inference by the existing $1 cap. No Opus quality claim. Repair spend **$0.05471376** including diagnostics.
- The native chooser now names and selects the cloud model, waits for the published table, and offers **Change AI**
  on the failed explainer itself. Saved answers name the model that wrote them. Billing failure copy explains the
  provider's insufficient balance and that the reader's AI credits were not charged. Browser Pages **f1494d2a** is
  deployed with corrected routing disclosures and billing-error copy. Native build 69 is available on iOS and Mac.
- Fast tier, Deno check, full database suite, 21 focused Core tests and the exact-paper Simulator journey pass.
  Required import/session gate: **13 passed, zero skips**, matching current source at 23:27:41 UTC;
  `.artifacts/import-acceptance/2026-10-17T23-23-03-206Z.xcresult`. Cloud recovery UI acceptance also passes:
  provider-balance explanation, inline model selection and a successful structured answer naming Haiku;
  `cloud-recovery-final.xcresult`, screenshot reviewed.
  No physical phone was accessed. Evidence: `.artifacts/equations-feedback-20261017/`;
  [equations](architecture/EQUATION_VIEW.md), [routing](architecture/GEMINI_FLASH_CHAT.md),
  [costs](architecture/OPERATIONS_AND_BILLING.md).

Release source **f72c51c**. iOS is **VALID / IN_BETA_TESTING**, first confirmed 23:40:01 UTC; both iOS and Mac
are **VALID / IN_BETA_TESTING**, confirmed **23:46:40 UTC**. Both signed archives pass
the source-matching import gate and contain the tested revision-18 compiler, pinned Local AI catalog and MLX Metal
resource, without downloaded LLM weights. Archive identity/signature checks, TestFlight states and release notes
are recorded in `.artifacts/equations-feedback-20261017/`.

## Flash activation — 2026-10-17 19:54–19:55 UTC (deployed and verified)

The owner said **“I am over riding the check, please make open router work again.”** `chat_gemini` is now `on`,
persisted in infrastructure configuration and deployed. The live authenticated profile table offers Gemini and
recommends `gemini-medium-standard`; the ordinary default smoke follows that table and completes in **4.506 s**.
Exact provider cost **$0.001296075**, one reader credit, no new outstanding hold. The existing $1 verification cap,
$40 staging allocation and $100 monthly ceiling remain. Unfunded old-consent rejection still happens before any
operation or provider attempt. Both new fixtures were deleted; `npm test` passes.

Build 68 already supports this: restart the app to refresh its model table; old conversations/saved defaults keep
their explicit choice and can select Flash in Answer options / Settings → AI chat options. Anthropic's unfunded
title/suggestion extras remain separate. Request-level ZDR and all routing/consent/accounting protections remain;
the account opt-ins are unverified, not declared off. No new native/browser build or phone access.
Evidence: `.artifacts/flash-activation-20261017/`; [current route status](architecture/GEMINI_FLASH_CHAT.md).

## TestFlight 68: local AI prototype and cloud-service diagnosis — 2026-10-17

- iOS and Mac are **VALID / IN_BETA_TESTING**, confirmed 15:08:42 UTC, native source `12d5552`. Tap Cloud AI
  above the chat composer to choose Local AI; figure/equation AI Explainer offers the same choice. Download and
  remove models explicitly. The smaller vision option is Qwen3.5 2B; larger models are offered only with sufficient
  app memory. No downloaded weights are bundled. This is an experiment, with the measured limitations below.
- Both signed archives contain the pinned model catalog and MLX Metal resource. The required source-matching
  import/session gate passed **13/13, zero skips** under release optimization before upload. Prior local inference,
  integrity, routing, saved-answer and UI evidence remains applicable. No physical phone was accessed.
- Cloud root causes: the owner's 14:32 UTC Sonnet request was rejected for the **Anthropic balance**, while the
  funded Flash option was still hidden. A fresh Flash probe also reproduced HTTP 404: its pinned AI Studio endpoint
  cannot satisfy the account's **zero-data-retention policy**. Migration 086 and chat now pin Google Vertex US,
  require ZDR explicitly, and retain no fallback/data collection/response cache. New route token rates are 10%
  higher; quotas and the $100/month budget are unchanged. Historical pricing snapshots stay intact.
- Seven deployed-route generations pass: paper answer; figure walkthrough, simpler explanation and extracted crop;
  OpenVLA reference add; equation symbols and background. Actual provider spend **$0.063910955**; one cancelled
  Anthropic title retains **$0.000138** unknown liability. No private reader content was used. Flash remains hidden
  until the account's private input/output logging and OpenRouter data-use opt-ins are confirmed off.
- Build 68 and browser Pages **f747c676** show an actionable nonretryable message for a model balance failure,
  preserving the question and suggesting another model. Backend rejection logs use closed categories only.
  Live smoke scripts now fail on streamed errors/empty results; the scheduled chat check follows the published
  recommendation rather than the compatibility default. No successful ordinary-reader Flash activation is claimed.
- Full database suite (including 086), fast tier, focused adapter/chat and Core profile/error checks pass.
  Evidence: `.artifacts/release-68/`, `.artifacts/import-acceptance/2026-10-17T14-46-54-922Z.xcresult`;
  [route diagnosis](architecture/GEMINI_FLASH_CHAT.md), [cost accounting](architecture/OPERATIONS_AND_BILLING.md#testflight-68-cloud-route-repair--2026-10-17-1503-utc).

## Local AI prototype — 2026-10-17 (measured; included in TestFlight 68)

- Native chat, equation and figure explainers offer Cloud AI / Local AI; local models download explicitly, verify
  pinned file hashes, can be cancelled/removed, and run with a bounded prompt/image budget. Existing reader
  LaTeX, paragraphs, captions and figure images are used. No Mathpix, server PDF handling, provider fallback or
  credit charge was added. Kept local explanations retain their engine choice and encrypted storage.
- Actual MLX inference tested on this M1 Max Mac: Qwen3 0.6B, Qwen3.5 2B/4B and Gemma4 E2B. Qwen4B gives stronger
  explanations in this small comparison, but neither larger model passes the numerical figure checks cleanly.
  Tight crops help, without making the answers exact. Network-denied inference completes. Total process footprint
  is much larger than MLX allocation alone; iOS checks conservative memory headroom before download/use and load.
- `npm test` passes; Core 340 + 23 tests and four model-store integrity tests pass. The first integrated native
  acceptance passes 35 chat/lifecycle tests and eight affected UI journeys (including local saved-answer reopen).
  iOS Release and Mac Catalyst builds pass. Final memory-guard/local-PDF acceptance is recorded in
  [Local AI](architecture/LOCAL_AI.md). Release acceptance is recorded above; no physical-phone testing or
  cloud-default change is claimed.
- [Measured answers and limits](reviews/LOCAL_AI_20261017.md). Local-prototype provider spend: $0.

## Fresh owner test account: 100,000 credits — 2026-10-17 08:39 UTC

One explicitly requested, nonexpiring adjustment through `worker_grant_credits`, with one immutable admin audit
record. Readback: 100,000 available, zero reserved, one grant and one audit entry. Existing subscription/purchase
behavior and provider budget are unchanged: $40 allocated, $28.993489 spent, zero reserved before and after.
Evidence: `.artifacts/credits/owner-100k-20261017/verified.json`; [billing](architecture/OPERATIONS_AND_BILLING.md#fresh-owner-test-account--2026-10-17).

## Post-deletion login access repaired — 2026-10-17 08:30 UTC

The original account's Auth deletion/refresh audit events establish its exact verified address. A fresh confirmed
login now exists for that address, with a new open account UUID. No provider-identification question was needed,
and no app rebuild was required. Original deleted data/credits remain deleted; no password, message, new credit
grant or public-signup change. Today's actual failed attempts were HTTP 422 `signup_disabled`.

The hosted deletion check now includes re-admission and a successful email-code exchange/account RPC on the new
synthetic UUID (HTTP 200/200); both fixture accounts are removed. No email or AI call. Auth subsequently records
the owner's own successful sign-in at 08:34:48 UTC; the agent did not authenticate as the owner. Evidence:
`.artifacts/feedback/login-access-20261017/` and `.artifacts/auth-lifecycle/2026-10-17T08-31-42-852Z.json`.

## Build 66 follow-up — 2026-10-17 UTC (browser and TestFlight 67 iOS/Mac available)

- Reproduced remote deletion with two real staging sessions, without mail, papers or AI. The second session's
  refresh fails with `refresh_token_not_found`; its unexpired JWT receives SQL `28000` / `authentication_required`.
  The native client had retained that rejected session and visible cached account. Backend/model retirement now
  clears credentials and presentation across cloud actions while retaining encrypted files/keys. Transient failure
  preserves offline access. Browser RPC/stream rejection receives the same retirement behavior.
- Red native regression: three failures on build-66 code. Green: 44 focused native checks under release optimization,
  including concurrency, late response/account boundaries, transient recovery, Keychain failure, local retention and
  the actual sign-in/restart screen. Two desktop/phone browser journeys pass; screenshots reviewed. Fast tier:
  **652 backend / 477 browser** passes. Local evidence: `.artifacts/feedback/followup-20261017/`.
- FDE-Gym's official HTML leaks font configuration into its opening paragraph. Renderer revision 18 removes the
  finite recognized prefix, preserving seven images and 63 equation entries. The seventh reported paper joins the
  offline native corpus. Existing readable copies update only on the reader's explicit version-details action.
- The upload gate now includes 13 required import/session checks and fingerprints the authentication implementation
  too. Its first run blocked release because the startup explanation disappeared (12 passed, one failed). The
  explanation now stays beside Sign in and in Settings; the final screen journey requires it. Final gate:
  **13 passed, zero failed/skipped**, `.artifacts/import-acceptance/2026-10-17T06-38-58-152Z.xcresult`;
  the final session-ended and sign-in screenshots were reviewed.
  No physical device accessed; no new paid AI call. Flash activation and a fresh beta
  invitation still require the already-requested owner information.

Release source **1d5f7aa**. Browser Pages **103582dd** is live at https://app.gradstep.ai: all three entry assets
serve their expected types, and the live revision-18 compiler matches the tested bytes exactly. iOS uploaded at
**06:49:49 UTC** and is **VALID / IN_BETA_TESTING**, first confirmed **06:53:31 UTC**. Mac uploaded at
**06:55:03 UTC**; both platforms are **VALID / IN_BETA_TESTING**, confirmed **06:57:42 UTC**.
Both archives contain the same tested compiler (build identity
`95ce288282650346bae024054dea84a8a4f02be01b47b9b493c4e97985d88b3f`) and pass the source-matching release gate
before upload. Release evidence: `browser-release.json`, `archive-identities.json`, `build67-status.json` and
upload logs under `.artifacts/feedback/followup-20261017/`. This is internal beta availability, not physical-phone
acceptance or restored owner sign-in.

## Build 65 follow-up — 2026-10-17 UTC (browser deployed; TestFlight 66 available)

- **DocPilot:** two sequential failures reproduced: unsupported SVG text badges inside MathML, then algorithm
  misclassification as a figure. Renderer revision 17 handles that finite badge shape as text and excludes math
  graphics from figure classification. Full device compilation and native encrypted install/reopen succeed.
- **More Methods:** the exact official HTML revision returns 404; the PDF is available. Native offline replay
  verifies the existing Open PDF path, device download, encrypted storage, PDFKit rendering and reopen. Automatic
  PDF opening is a proposed interaction change awaiting the owner.
- **Import release gate:** seven native acceptance methods include all six reported papers, real local PDFs and
  damaged input, cancellation, explicit retry, no sync retry loop, repeated taps, out-of-order images, offline
  reopen and actual row/spinner geometry. Release optimization is mandatory. Both upload scripts reject missing,
  skipped, failed or stale evidence. Final gate: **7 passed, zero failed/skipped**, release optimization,
  `.artifacts/import-acceptance/2026-10-17T05-17-25-813Z.xcresult`; upload gate readback matches current source.
  Both rows measure 84 pt; the spinner is 20 pt and centered. Source **a539550** is archived for build 66 on iOS and
  Mac; both contain the tested revision-17 compiler byte for byte and pass the upload gate again. Uploads succeeded
  at **05:37:59 UTC** (iOS) and **05:41:59 UTC** (Mac). Both are **VALID / IN_BETA_TESTING**, confirmed
  **05:45:52 UTC** (iOS first confirmed 05:42:42 UTC).
- **Library/Answer options:** reserve consistent row space, center/enlarge the spinner; remove the native Answer
  options title/Done row and implement the owner's default wording/button state. Browser affected journeys pass
  (12, with four desktop-only scenarios intentionally skipped on phone). The empty-chat glow is removed on both
  clients; four light/dark browser journeys pass after that change. Native Settings defaults passes, followed by
  the corrected light/dark Answer options and missing-profile-table journeys (2/2); Mac starters/options/Close
  passes (1/1). The first dismissal assertion missed the sheet's intermediate half-height detent after About;
  the test now uses the actual grabber and both pulls. Screenshots reviewed. `npm test` passes 650 backend and
  469 browser cases.
- **Chat:** at 04:43 UTC Sonnet plus auxiliary Haiku calls were rejected for the Anthropic account balance.
  OpenRouter still has $10.205283699, but the Flash route remains hidden pending account privacy-switch confirmation.
  No new paid call was made. Existing successful deployed-Flash evidence is retained; no working-chat claim.
- **Deleted account:** Auth deletion completed at 04:48:45 UTC; disabled public signup prevents OAuth recreating
  the login. A fresh beta invitation awaits the exact provider/address. Deletion/error copy now explains that
  restriction; no old account, content, keys or credits restored.

Evidence: `.artifacts/feedback/import-reliability-20261017/`, `.artifacts/import-acceptance/`;
[feedback details](OWNER_FEEDBACK.md), [test gate](TESTING.md). No physical-phone access.
Browser Pages **91c7d07f** is live at https://app.gradstep.ai; all three entry scripts/styles served with their
expected types after the phased deployment. It includes revision 17, the flat chat background, default-button
wording/state and re-invitation copy. Flash remains hidden. Native release evidence:
`build66-status.json`, `archive-identities.json`, `upload-66.log`, `upload-mac-66.log` in the feedback artifact
directory. This is internal TestFlight availability, not physical-phone acceptance or a public release.

## Build 64 `invalid`: root cause and native fix — 2026-10-17 ~04:25 UTC (Oct 16 PDT)

The latest screenshot identifies VLA-Δ 2610.21306v1 and `Code: invalid`. The native Library flow reproduces it
with `-O`, while the same flow passes under `-Onone`. Swift 6.3 loses the image index in
`return (index, try await acquire(...))` inside the task's `do/catch`: successful downloads all return zero,
overwrite the first slot and leave the rest empty. The final guard rejects that incomplete input array.
This also reproduces in a standalone Swift program with no network/WebKit. The fix awaits the bytes before
constructing the tuple; before/after optimized regression evidence is retained.

The authored ten-image regression and cached native replay of Rubric Judgments, ManiFusion and MetaShare pass
with `-O` after the fix. Existing one-image fixtures and debug real-paper replays had missed the bug. The native
test tier now uses `-O` and whole-module compilation; guard diagnostics name their stages. No renderer revision
bump is needed. Full Library verification with `-O` and whole-module compilation succeeds for all four reported
papers: VLA-Δ downloads/installs/reopens in 8.71 s; the original three, started together, in 21.74 s. The native
reader suite is five passes / one unrelated live-DPO skip. `npm test` passes. Source **940e574**.
TestFlight **65** uploaded successfully for iPhone/iPad at **04:30:19 UTC**, and Mac at **04:33:15 UTC**;
Both are **VALID / IN_BETA_TESTING**, confirmed **04:35:57 UTC** (iOS first confirmed 04:33:41 UTC).
No physical-phone acceptance is claimed. Physical phone access remains paused;
this investigation incurs no AI cost. Upload evidence: `.artifacts/export-65.log`, `.artifacts/export-mac-65.log`;
processing evidence: `.artifacts/feedback/20261017-invalid/build65-status.json`.
[Feedback and evidence](OWNER_FEEDBACK.md).

## Build 64 still fails on the phone — 2026-10-17 ~04:00 UTC (Oct 16 PDT)

The owner reports the same reading failure after installing build 64. There was no established root cause or
reader fix in that release; its diagnostic addition only records during an explicitly started local test session.
The follow-up Simulator check now covers the omitted native network/Library/storage flow: all three reported
papers download concurrently, install, and open in 22.6 seconds (one test, zero failures). The uploaded archive's
compiler bytes match the tested app. This narrows the investigation, **not** the phone failure's status: unresolved.
No further app build or product change has been shipped. Existing ⓘ failure code requested; physical-phone access
remains paused. Evidence and release expectations: [owner feedback](OWNER_FEEDBACK.md).

## Latest build-63 feedback and hidden Flash rollout — 2026-10-17 ~03:25 UTC (Oct 16 PDT)

- **New feedback:** “All of theee can’t be read ?” (App Store Connect `AOdhYANzVPZB-0xNEpmOwaM`, build 63):
  MetaShare 2610.21887v1, ManiFusion 2610.21433v1 and Rubric Judgments 2610.21214v1 fail preparation on the phone.
  Exact official HTML, full image compilation and native iPhone 17 Pro Simulator replay all succeed. Native counts:
  674/354/214 blocks; 343/597/498 equations; 1.2–4.2 seconds. **Phone failure remains unresolved**; the owner was
  asked for the failure screen's ⓘ code. No physical phone was queried. New opt-in cached-paper replay test and
  local session-recording failure code for background Library preparation; no claim of a reader fix.
- **Flash staging:** migration 085 and chat are deployed with `chat_gemini: "hidden"`, persisted in infra. OpenRouter
  routes to Google AI Studio only. Two chat turns, three figure actions and both equation actions are verified.
  The first symbol request hit its old 2,000-token limit: fixed to include medium reasoning (6,000 total), then
  repeated successfully with 11 symbols. Malformed JSON is no longer displayed or charged as an explanation.
- **Cost:** eight generations, **$0.108185933** actual ($0.108191 rounded server ledger), **no outstanding holds**;
  the account has **$10.205283699 left from $20 funded**. $1 test allocation was not exceeded. The existing key was
  reassigned solely to app use; the comparison harness's key variable was removed and its $20 lifetime limit kept.
  Three Anthropic auxiliary title/suggestion calls still refuse for billing, at zero cost; Flash answers complete.
- **Verification:** final fast tier 647 backend / 469 browser units; chat+adapter regressions 142/142; Deno checks
  the entry point; native test target builds, cached native reader suite 4 pass / 1 live-network skip. The prior
  affected DB, Core, profile and figure UI evidence is reused for unchanged behavior. Browser equation, figure and HTML journeys pass on desktop and phone (6/6), with consent v5. Evidence `.artifacts/flash-rollout-20261017/` and
  `.artifacts/feedback/20261017-current/`.
- **Activation still pending:** ordinary app traffic keeps Sonnet. Computer Use denied Chrome access, so the
  OpenRouter account's input/output logging and data-use switches could not be inspected; owner confirmation is
  pending. Privacy copy now names Google/OpenRouter and removes retired server PDF processing.
  Client/deployment evidence follows below.
  [Route, accounting and activation](architecture/GEMINI_FLASH_CHAT.md); [feedback](OWNER_FEEDBACK.md).

## Client release 64 and browser deployment — 2026-10-17 ~03:39 UTC (Oct 16 PDT)

Source **428a608**, following the Flash integration **345d35b**. TestFlight 64 for iPhone/iPad uploaded at
03:32 UTC; Mac uploaded at 03:35 UTC. **Both are VALID / IN_BETA_TESTING**, confirmed at **03:39 UTC**.
This is an internal beta, not public release.
The build includes Flash/consent v5 support, accurate provider copy and background preparation codes in an active
local session recording. It does **not** claim a fix for the three papers in the latest phone report.

Browser Pages **d3b06988** is live at https://app.gradstep.ai (three entry assets verified), admin Pages
**04ecd963** at https://admin.gradstep.ai (two entry assets verified), and the existing privacy page is updated
in site Pages **ace695d9** at https://gradstep.ai/privacy/ (provider and device-only paper wording read back).
The separate website redesign remains a draft. The admin's local development environment file was preserved and
restored after the deploy, which used only the approved staging configuration.

Flash is still **hidden** in the published profile table; neither this release nor the new credit changes that.
Old consent is rejected before a hold/provider call (hosted fixture: zero operations and attempts). No additional
paid checks are planned. Read [Gemini activation](architecture/GEMINI_FLASH_CHAT.md) before enabling the default.
Evidence: `.artifacts/flash-rollout-20261017/`, `.artifacts/export-64.log`, `.artifacts/export-mac-64.log`.

## Model finalist extension — 2026-10-16, ~23:15 UTC, responses complete; review partial

Haiku medium, Gemini Flash medium and Luna high now each have 27 attempted questions. The 45 new requests all
completed: Haiku/Gemini produced 15 written answers each and Luna 13, with two unanswered native-table image
requests. Four of the 15 new questions have independent claim-review grades. Two judges agree on six short
calibration cases each; direct agent source checks identify smaller unsupported claims and grader/reference
disagreements. [Finalist results](reviews/MODEL_COMPARISON_FINALISTS_20261016.md) preserve those limits; no combined
27-question quality score or default switch is claimed. Higher-end Chinese models remain untested.

The old five uncertain calls reconcile to $0.03395231. Total experiment spend is now **$9.6865303832**, no holds
or overruns, within **$10 funded** and the existing **$25 authorization**. Remaining funded room $0.3134696168
cannot admit the outstanding full-source grading requests. No paid process or balance watcher remains running.
The original evidence archive is unchanged; the new archive includes 213 attempts, 19 grading records and two
calibrations. Routine fast checks, seven targeted accounting/grade checks and actual-app rendering of all 196
completed responses pass. All 27 questions are available in the responsive answer comparison. No product code,
deployed model, physical-device, NAS or TextBrain change is included.

## Model comparison screening — 2026-10-16, ~21:25 UTC, historical checkpoint

The matched 12-question screening covers 13 usable settings across five papers: 151 completed responses, five
timeouts and nine empty table requests. DeepSeek's own endpoint had 12 separate pre-inference policy refusals;
the tested alternative is DeepInfra FP8, with the existing privacy restriction preserved. Argon high graded all
completions; Sol high independently checked three questions for seven settings. Source and image checks confirmed
errors the first grader missed, including Haiku high's equation explanation. **Gemini Flash is the provisional
lead for further testing; Sonnet remains the default.** See [the results](reviews/MODEL_COMPARISON_RESULTS_20261016.md)
and the committed raw evidence. The 27-question finalist extension and actual deployed-adapter/figure-explainer
checks are still pending; this is not a production model rollout.

Charges are $8.655776 completion-reported plus $0.228190 held for interrupted calls, within $10 funded credit and
the owner's $25 authorization. The lower provider aggregate is unreconciled and not used to expand spending.
Fast tests, six budget/reference/grade tests and offline math/diagram rendering pass. The answer viewer was
checked at desktop/360px/320px. No app or backend deployment, physical phone, NAS or TextBrain work in this continuation.

## Claude takeover and build 63 release — 2026-10-16, ~20:00 UTC

- Recovered Claude's active session, all three merged build-62 feedback branches and four saved model-question
  drafts. Main's client source is `505d661` (including merge fix `6147be5`); no new product interaction was added
  during takeover. Physical iPhone work remains paused; no NAS/TextBrain access or changes.
- **Browser shipped:** Pages `836089d4` at https://app.gradstep.ai, published with the existing two-phase release
  procedure. Verified the new index and all three script/style entry assets have their expected content types.
  This ships the build-62 parity, reader/version recovery screens, extraction UI and saved-explanation lists
  described below. The browser still has no on-device PDF model.
- **TestFlight 63:** iOS/iPad upload succeeded at **19:57 UTC**, Mac at **20:02 UTC**. Both are
  **VALID / IN_BETA_TESTING**, confirmed in App Store Connect at **20:05 UTC**. Server figure-detail and billing
  changes were already deployed by Claude; the paid figure-detail live check remains unverified after the earlier
  Anthropic credit refusal. Evidence: `.artifacts/takeover-20261016/build63-status.json`, `export-63.log` and
  `export-mac-63.log` under `.artifacts/`. No public release.
- **Verification:** `npm test` passes after harness changes; browser UX review 4/4 (50 captures, light/dark,
  desktop/phone). The recovered merged iPhone 17 Pro Simulator run finished **22 passed, 2 tablet-only skips,
  0 failures** (`.artifacts/xr-merge-1234`, summary in `.artifacts/takeover-20261016/native-summary.json`). Reviewed
  its figure top row, walkthrough, equation Contents and dark captures. Existing iPad/Mac feature evidence below
  is reused because their implementation is unchanged. Owner acceptance on the physical device remains open.
- **Model comparison:** 27 reference questions on five exact revisions, 13 model settings; all requests pass dry
  construction and first-party catalogue preflight. Corrected attachment ids, actual browser figure preparation,
  output/deadline parity, durable spending holds, grade validation and stale-result handling. Five new budget and
  validation tests pass. OpenRouter credit/usage are $0/$0 at **20:03 UTC**, so no inference or quality ranking exists. Default model
  unchanged. [Protocol and prices](reviews/MODEL_COMPARISON_20261016.md); [spending record](architecture/OPERATIONS_AND_BILLING.md#model-comparison-reservation--2026-10-16-takeover).
- Stopped the two old Claude balance-polling processes after checking what they do; there is no unattended paid
  experiment or promised future watcher. Resume explicitly from the recorded commands when credit is available.
- Recovery/harness commits: `029a2e2`, `3b91a4c`. Historical "not shipped" checkpoints below describe their state
  when written; this release supersedes those labels for the build-62 client changes.

## Browser: build 62 parity — 2026-10-16, ~17:30 UTC (local fixtures only; not deployed)

- The browser matches the apps' build-62 changes with their wording
  ([BROWSER_READER.md](architecture/BROWSER_READER.md#build-62-parity-2026-10-16-local-fixtures-only-not-deployed)):
  one top row on the figure page, the equation view and a figure/table reference — **Explain in Chat** and **AI
  Explainer** on the left, a round X on the right, no Done or action bar; a tapped equation's "Equation" is now **AI
  Explainer** and asks at once (consent first); an explainer's heading is a menu of the paper's equations or figures
  (one switched to waits for AI Explainer); Contents › Equations rows read "Equation (n)" / "Equation · section" with
  **View as tiles** (one sandboxed document typeset by the reader's MathML/CSS); **one failure screen** ("Read this
  paper as its PDF", one reason, Open PDF, code behind ⓘ; "Couldn't reach arXiv" with Try again only when busy or
  unreachable); ⋯ › **Reader version details** (versions from the apps' `reader-versions.json`, Update this paper keeping
  the copy until ready, a failure with reason and code); Your assets › **Equation explanations** / **Figure
  explanations** (this tab's, None yet, ⓘ; a row reopens the paper there without a request); diagram Full size starts
  across the width and pinches, ctrl/⌘-wheels, drags and double-clicks back.
- No apps or server changes. The compiler host now posts its listed failure code beside the category (compiler bundle
  unchanged).
- Evidence: `npm test` (fast tier, browser units 51 files); Playwright desktop + phone: figure-view 8/8, equation-view
  10/10, arxiv-html 4/4, build-62 4/4, account-assets, owner-58, server-copies-retired, reader-drafts, reader, layout,
  study, chat, library-actions; screenshots reviewed light and dark (`.artifacts/web-build62/`, `.artifacts/figure-*`,
  `.artifacts/equation-view-*`, `.artifacts/contents-equation-tiles-*`, `.artifacts/web-chat/*-tall-diagram-*`).
- Not done here: the browser has no on-device PDF model, so its failure screen has no second button; the tablet
  projects were not run.

## Contents in one glass row, Equations by number with tiles, kept explanations in Your assets, diagrams zoom (TestFlight 62 feedback, items 9–13) — 2026-10-16 (apps; not shipped)

- **Contents** (iPhone, iPad, Mac): one glass top row, the four tabs in a glass capsule (each as wide as its name, one
  weight so choosing a tab shifts nothing) and a round glass X; no title, no Done (DESIGN.md "Sheet top row";
  `Views/SheetChrome.swift`). Pushed tiles have a glass Back and X; a figure or table page keeps its own top row.
- **Equations**: rows "Equation (4)" as printed, or "Equation · 3.2 Method" without a number; no flattened LaTeX.
  **View as tiles**: one web page with the bundle's stylesheet, each equation typeset from its element and scaled to its
  tile, light and dark; a tile goes where its row goes (EQUATION_VIEW.md "Contents › Equations and Your assets").
- **Your assets › Equation explanations / Figure explanations**: kept answers now seal what they explain
  (`ExplanationSubject`); listed newest first, each item once, "None" when empty; a row opens the paper at that
  equation or figure with its kept explanation. A reopened equation or figure now finds its kept answer even when the
  default model or options resolve differently (after a relaunch they did, so the kept answer wasn't shown).
- **Diagrams full size**: the drawing at its own size in a page as wide as it, opening fitted to the width (a wide one
  no longer runs off the left edge, out of reach), pinch up to 8×; visuals pinch up to 8× too.
- Evidence: ScienceReaderCore 331 + the store's new listing test; iPhone 17 Simulator: PaperToolsTests (Contents,
  Tables, equation tiles light and dark), ExplanationAssetsTests (both lists, None), DiagramZoomTests,
  FigureViewJourneyTests, ReaderNavigationTests and the WorkflowJourneyTests diagram, equation-view and installed-paper
  journeys (results in the commit message).

## Figure, table and equation pages: one top row; AI Explainer — 2026-10-16 (apps; not yet in a build)

- Owner, build 62 (OWNER_FEEDBACK.md items 6, 7, 14; DESIGN.md "Sheet top row", "Explain actions"): every figure or
  table page, the walkthrough and the equation view have one glass row at the top: **Explain in Chat** and **AI
  Explainer** (tinted) as glass capsules in the bar's middle, a round **X** on the right, no title, no Done; a pushed
  page keeps the system Back. Show in paper / previous / next stay in the bottom bar. `SheetChrome.swift`.
- The walkthrough and the equation view open with a heading, **Figure 3 ⌄** / **Equation (4) ⌄**, a menu of the
  paper's other figures (tables) or display equations; one switched to shows what is kept or waits for AI Explainer.
- The tapped equation's menu item **Equation** is now **AI Explainer** and asks for the explanation at once.
- Evidence (merged with main's figure_detail and reader batch): iPhone 17 Simulator FigureViewJourneyTests 2/2, the
  equation view (both), installed-paper, Contents tabs/Tables/gallery and figure-reference journeys 9/9, app unit
  `FigureViewAppTests` 3/3 (new: a figure switched to waits); iPad Pro 13 the same set 9/9 (the gallery journey once on
  a rerun: its sample paper hadn't loaded); Mac FigureViewJourneyTests 2/2 (its Mac scroll now clears the top row) and
  MacKeyboardTests 4/4. Screenshots reviewed: iPhone light/dark (figure page, walkthrough, table, equation view, the
  equation menu), iPad, Mac. Not covered by a journey: switching from a heading (the fixture paper has one figure and
  one display equation).

## Figure view: one part extracted (TestFlight 62 feedback) — 2026-10-16, ~15:50 UTC (server on staging; apps and browser built, not shipped)

- Owner (build 62): "Extract the subfigure and more context… opens up a loader below, gets the info, and puts it
  below". New chat action `figure_detail` on the chat's cached prefix: the walkthrough's tool with one section and a
  required box, relayed as `figure_detail` (`figure-detail-v1`); words without a box. Apps and browser: the part's menu
  item, a loader, then the crop and the closer reading under the part; kept with the walkthrough
  ([FIGURE_VIEW.md](architecture/FIGURE_VIEW.md#one-part-extracted-owner-testflight-62-2026-10-16)).
- Migration 083 (`figure_detail` in `chat_endings` and `worker_settle_chat`) and the chat function deployed to staging;
  deploy checks 19 pass, `chat.smoke` failed only on the Anthropic credit balance. No live extract yet for that reason.
- Evidence: backend, database (full suite), core, iPhone Simulator journeys (FigureViewJourneyTests 2/2 with the new
  steps), browser units and `figure-view.spec.ts` desktop/phone 6/6, `npm test`.

## Build 62 feedback: reader on the phone, versions, billing — 2026-10-16, ~15:50 UTC (not yet in a build)

- **Broken?? (Related papers)**: the staging Anthropic account's credit balance ran out about 15:00 UTC; every Claude
  request (plain questions too) answered 400 "Your credit balance is too low" (reproduced with the server's own request
  params, `chat-live-smoke.mjs --action/--caps`). Owner to top up. Now recorded as `provider_billing`; migration 084 adds
  `provider_billing` to v1_admin_health (DeepSeek's 402 too) and the admin's Attention says to top up. Database suite and
  backend tests pass; staging deploy waits for the figure-detail branch (its migration 083 is already applied there).
- **MLExpert retried forever**: every library sync reopened the selected paper and started another preparation after a
  failure; now only the reader's own action retries (`failedHTMLOpens`).
- **Papers failing only on the phone** (2504.02792, 2610.22083 re-preparations; 2610.22344 first open): all prepare on
  the Mac and in the iOS Simulator with the app's own code and the catalog's authors and title (2–12 s). Hardened without
  a device: one compile at a time (`ArxivCompileGate`), a killed or stalled compile runs once more with the downloads it
  has, and the real reason is kept as a code (`ArxivHTMLError.code`), shown behind an ⓘ and in Reader version details.
- **One failure screen**: "Read this paper as its PDF" — Open PDF and Read with the on-device model (fetches the PDF
  first); Try again only for arXiv busy/unreachable. **No banner**: ⋯ › Reader version details (this paper's version,
  the app's, what changed, Update this paper); `reader-versions.json` (revisions 3–16 by build identity), kept current
  by the compiler build check; READER_VERSIONS.md.
- **Formula images from the on-device model** are cleaned of the neighbouring lines' fragments and given an even margin
  (converter revision 3; DEVICE_PDF_ROUTE.md).
- Evidence: `npm test`; database suite; ArxivCompilerFailureTests + ArxivHTMLReaderTests + ArxivCompilerIdentityTests +
  ArxivCompileGateTests on Mac Catalyst; ReaderVersionTests on the iPhone 17 Pro Simulator; device-PDF tests (core 330 +
  23, backend 16).

## On-device PDF model: formula crops cleaned (port revision 3) — 2026-10-16 (not yet in a build)

- Owner, TestFlight 62 (Waypoint-OPD read by the on-device model): formula images carried the cut tails of the lines
  above and below. The converter now asks the host to clean each formula crop (`clean: { em, margin }`): pieces of ink
  at the crop's edge, outside the formula's own ink with a clear gap and small for a line of text, are dropped; the
  image is trimmed and given an even margin (0.25 em display, 0.12 em inline) and sized/aligned from where it now
  sits (DEVICE_PDF_ROUTE.md "Formula crops are cleaned"). `DEVICE_PDF_PORT_REVISION` 2 → 3.
- Evidence: `DevicePDFFormulaCleanTests` (7), `device-pdf.test.ts` (16), `npm test`, ScienceReaderCore 330 + 23;
  before/after on Waypoint-OPD (14 formula images) and Mamba's first 10 pages (63): every neighbour's tail gone, bars,
  scripts, roots and equation numbers kept, dark mode checked. A cut word wider than 0.3 em at a side stays.

## Figure view, apps — 2026-10-16, ~08:35 UTC (iPhone, iPad, Mac; not yet in a build)

- Owner, build 59: a figure page has **Explain** and **Ask in chat** side by side; Explain opens a walkthrough in the
  equation view's look — the figure, what it shows, one card per part with its crop where the walkthrough gives a
  box and `[¶N]` links; a part's menu explains it more simply (inline, kept), shows it in the paper, or asks about it
  in chat. Kept on the device (sealed); no credit counts. An HTML table (from a reference) is drawn on the device as
  an image to send ([FIGURE_VIEW.md](architecture/FIGURE_VIEW.md#apps--as-built-phase-2-2026-10-16-iphone-ipad-mac-not-yet-in-a-build)).
- Every paper chat request now sends `figure_view` (with the equation view's and the figure view's actions), so a
  walkthrough reads the chat's cached paper; production ignores it until its `chat` function has the view.
- Evidence: core suite 329 (new `FigureViewTests`), app unit bundle 460 (new `FigureViewAppTests`; the stale
  `ChatVisualTests` expectation fixed), `FigureViewJourneyTests` 2/2 on the iPhone 17 and iPad Pro 13 Simulators and on
  this Mac, neighbouring journeys (Contents, gallery, figure reference, equation view, figure parts) pass. Fixtures
  only: no live walkthrough from the app yet.

## TestFlight 62 and the figure view live from the app — 2026-10-16, ~10:00 UTC

- **Build 62** (8a93ce3), iPhone/iPad and Mac uploaded and VALID (10:06 UTC): the figure view (Explain and Ask in chat on every figure and table
  page; walkthrough part by part with crops; Explain more simply, Show in the paper, Ask in chat about this), Contents ›
  Tables listing the paper's real tables (index `tables`, reader revision 16), an image arXiv doesn't serve is that
  figure's note (revision 16), Listen on legacy arXiv items, Mac ⌘N and ⌘W fixed, diagrams that can't be drawn keep
  their height, Contents jumps after its sheet closes. Not in 62: thin spaces between touching `[¶N]` (789204b).
- **Evidence on merged code**: iPhone 17 Pro FigureView, PaperTools and Workflow journeys 40/40; iPad Pro 13 FigureView
  and PaperTools 8/8 (a table from Contents offers Explain); Mac FigureView 2/2 and MacKeyboardTests 4/4; app unit tests
  on Mac 430 XCTest + 21 Swift Testing; ScienceReaderCore 330.
- **Live from the app** (`live-journey.mjs --figure-view`, iPhone 17 Pro Simulator, staging; the whole journey passes): DPO Figure 1 explained
  after consent, the walkthrough reading the image's own details (the jazz-poem prompt, the trophy, the arrow labels)
  with `[¶N]` links. Live boxes: InfoVis Figure 2 got two, each on its band (FIGURE_VIEW.md "Open").

## Browser deployed; Add paper refunds; checks — 2026-10-16, ~08:30 UTC

- **Browser deployed** to app.gradstep.ai (~08:25 UTC, two phases verified) from main 17590db: reader revision 16 with
  the tables list, Contents › Tables, the figure view (staging server), AI credits / Subscription plan / Your assets in
  the account menu, build-59 parity, Listen on legacy items. The heading-jump fix below is not in it yet.
- **Add paper from chat** (chat function on staging): an add that doesn't happen costs nothing and says "Not charged."
  (CHAT.md "Add paper after settlement"). Live on staging: a made-up reference (no add) and Bradley–Terry 1952 (not
  found as an open copy) each 0 credits, balance unchanged; before the change the first cost 38 credits.
- **Checks**: `npm test`; browser journeys (figure view, equation view with Contents/Tables, account assets, owner-58,
  chat, chat redesign) desktop and phone 48 passed; `arxiv-compiler.spec.ts` Chromium, WebKit, Firefox; reader sweep
  replay of 123 cached papers 0 fail / 8 warn (as revision 15); MacKeyboardTests 4/4, MacChatRedesignTests 1/1.
- **iPhone regression** (10 UI classes, iPhone 17 Pro): 75 passed, 2 failed, both test mechanics on that device,
  confirmed with app logging and the run's screen recording. The broken-diagram journey tapped the answer's diagram
  while the transcript was still moving (passes on iPhone 17); the installed-paper journey tapped a Contents row
  sitting at the bottom edge of the half-height sheet (the new tabs push rows down), which landed on the screen's
  edge. The journeys now tap once the element is still (`tapWhenSettled`) and drag Contents' own list until the row is
  well inside it; both pass. App changes alongside: a diagram that can't be drawn in the answer keeps its place's height
  ("Couldn't draw it here") instead of collapsing; Contents jumps once its sheet has closed, as the gallery does.
- Known flakes under load: `spending-retry` concurrency and `reader-flow` "pathological lines stay fast" (pass alone).

## Figure view, browser — 2026-10-16 (built; not deployed)

- The browser's figure page has **Explain** and **Ask in chat** under the figure; Explain (after the chat's consent)
  shows What it shows and Part by part, with a crop where the model drew a box, `[¶N]` links with Back, and a ⋯ per
  part: Explain more simply, Show in the paper, Ask in chat about this
  ([FIGURE_VIEW.md](architecture/FIGURE_VIEW.md#browser--as-built-phase-3-2026-10-16)). Every browser paper chat now
  sends `figure_view`. Kept for the session; no credit counts.
- Evidence: browser units (`figure-view.test.ts`, `chat.test.ts`), `figure-view.spec.ts` desktop and phone, the
  equation-view, reader-drafts, chat, chat-redesign and arxiv-html journeys desktop and phone (35 passed, 9 skipped by
  their own conditions), `npm test`. Not live: the browser isn't deployed with it, and the staging walkthroughs so far
  drew no boxes (phase 4).

## Browser: AI credits, Subscription plan and Your assets — 2026-10-16 (built; not deployed)

- The account menu shows **AI credits** (available, and held while answers are in progress) and **Subscription plan**
  (Pro / Standard / None) from `v1_credit_balance` and `v1_store_summary`, read each time it opens, each with an ⓘ
  (what credits pay for; bought in the Gradstep app on iPhone, iPad or Mac; the browser sells nothing). A failed read
  is a dash; the menu keeps working. **Your assets**: Chats (All chats) and **Diagrams** (All diagrams, newest first,
  one opens as in its answer). BROWSER_READER.md "AI credits, Subscription plan, Your assets".
- Evidence: `npm test`; vitest `account-assets.test.ts`; Playwright `account-assets.spec.ts` desktop and phone (light,
  dark; plan None; a failed plan read; a drawn diagram listed and opened) and `owner-58.spec.ts` (menu items now start
  with Chats, Diagrams); screenshots `.artifacts/account-assets/` reviewed.

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

## Contents › Tables lists a paper's real tables (reader revision 16) — 2026-10-16 (not yet in a build or deployed)

- The Tables tab listed only tables arXiv published as images, so most papers said "No tables" (browser parity
  report). Revision 16's index now lists captioned tables (`tables: [{id, caption}]`, optional; HTML_FIRST_READER.md,
  after "An image arXiv doesn't serve"). iPhone, iPad, Mac (`PaperContentsSheet`, `GalleryFigure.tables`) and the
  browser (`contentsTables`) list them beside image tables in page order, "Table 3 — caption…"; a row opens the table
  with its whole caption and Show in paper (Back). "Algorithm 1" now reads as a number on both (`GalleryFigure.label`,
  `figureLabel`). The app's study fixture bundle (`ReaderSamples/arxiv-fixture.json`) is recompiled with revision 16.
- Evidence: `npm test` (backend 617 incl. `arxiv-tables-index`, browser units incl. `paper-contents`, `bundle`);
  `swift test --filter DeviceReaderTests` (6/6); iPhone 17 Simulator: `PaperToolsTests` (new Tables journey and the
  Contents tabs journey), `PaperWebViewTests` (label, tables), `ReaderNavigationTests.testHTMLPaperInPageLinksOfferBack`
  5/5; Playwright `equation-view.spec.ts -g Contents` desktop and phone 6/6; `reader-device-compile.mjs` on 13 cached
  papers (2610.19820: 9 listed). The device-PDF converter and metadata extractor bundles are unchanged.

## Browser: build 59 parity, early endings, Listen on legacy arXiv items — 2026-10-16 (built; not deployed)

The browser now matches the apps' build-59 changes (native commits `9903f50`, `5e4c1d2`, `f99a86d`, `e9b2a1b`):

- **Equation view** ([EQUATION_VIEW](architecture/EQUATION_VIEW.md)): opens with the equation and, side by side,
  **Explain** and **Ask in chat**; nothing is requested on opening (Explain asks the chat's consent first), More
  background only after the explanation, no credit counts.
- **Contents** in the reader's side panel: Contents · Figures · Tables · Equations (Contents first, quiet segmented
  tabs). Figures/Tables rows "Figure 1 — caption" (two lines) open the figure viewer with the whole caption and Show in
  paper; Figures starts with View as tiles (the gallery); Equations rows "Equation (n)" with the LaTeX as text go to the
  equation with Back (`showEquation` in the frame shim calls the bridge's `__scienceReaderShowEquation`). As in the
  apps, only figures and tables with images were listed (an HTML table was not in the bundle's figure index; revision
  16 lists them, entry above).
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
- **Account menu**: who and sync state (corrected 2026-10-21, B11: the menu had no sync state until the browser review
  fixes added Sync with Sync now); About with Privacy &amp; data, Report this screen and My reports for everyone;
  operator tools in a grey Admin group. **Privacy &amp; data** (new): notes, AI answers (Anthropic or DeepSeek), Papers
  and arXiv (device-only, pacing, terms link, acknowledgement; a PDF opens from arXiv in a new tab), Reports.
- **Feed / ML search Add**: the Library's spinner from Add until the paper is prepared here (percent under it once
  known; a click shows the Library), then ✓ In library. **Library**: a paper being added reserves two title lines (and
  the authors line when shown under the title), so the row never grows when its details arrive.
- Not in the browser at that point: Your assets › Diagrams, AI credits / Subscription plan (added below, "Browser:
  AI credits, Subscription plan and Your assets"); text sizes stay where the reader reads, as on the apps (corrected
  2026-10-21, B11: the apps also size chat text separately; the browser's chat ⋯ gained Smaller / Larger text then).
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

# Implementation status

Updated 2026-10-08 UTC. **Build 20 is available for internal iOS and Mac testing; browser chat and chosen columns are deployed.**
This is a development/release checkpoint, not public-release acceptance. Earlier checkpoint prose (including
removed executor work) is retained below where useful and in git history.

## Current rollout — 2026-10-08 UTC

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
- **Staging schema through 044 is applied.** 043 was applied disabled as a prerequisite to 044; see below.
  Before the earlier 042, encrypted checkpoint
  `20261008T051522Z-5ffa9efe26a9` captured the database and 1,332 objects; migration hash, grants and search paths
  were read back. Targeted hosted v5 Add/archive/unarchive/tags/remove/re-add, exact replay, deltas and
  stale-epoch refusal pass with a zero-credit synthetic account, then cleanup: **2 pass, 0 fail, $0 spent/reserved**
  (`.artifacts/workflow-checks/2026-10-08T05-42-22-627Z.json`). Build 18's disabled-v5-write regression is addressed
  by the build 19 client plus 042; the ordinary hosted command test does not invoke OCR or chat.
- **Spending controls 033–038 and uploads 039 are deployed.** Provider attempt coverage starts
  2026-10-08 02:40:51.785121 UTC; asset enforcement is on with complete scope-2 inventory and zero discrepancies.
  **Reader delivery remains `legacy`**, so replayable signed-URL exposure is still open; token expiry alone does not retire CDN-cached responses. The 05:14 UTC provider
  snapshot is **$13.677389 spent / $0 reserved / $25 limit**; it is not an invoice or total infrastructure cost.
  [Spending evidence and limits](architecture/SPENDING_CONTROLS.md).
- **Purchases:** three observed real Sandbox packs granted 400 + 400 + 200 = 1,000, with replays recorded separately.
  Production subscriptions/renewals/refunds remain unverified. 044 fixes the prior-period-credit policy discrepancy;
  exact purchase recording and actual credits granted remain distinct.
- **Personalized Feed 043:** **applied with serving off and refresh disabled**, pool and feedback empty, no sources.
  The scheduled gate exists but returns before network/profile work. Hosted readback: `feed-dark-deployment.json`.
  For You as default and use of server-visible metadata await the owner's answer; no Feed refresh function or
  personalized UI was deployed, and no paid ranking is enabled.
- **Pricing and podcasts:** research/model and reviewed design merged; live offers are unchanged. Podcast v1
  scope/privacy and a **$2 total pilot inside the existing $25 provider cap** await owner acceptance. No podcast
  schema, provider generation or paid ranking was deployed. [Economics](research/PRICING_RECOMMENDATION_20261008.md),
  [podcast proposal](architecture/PAPER_PODCASTS.md).

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
- **Browser reader redesign, milestone 1**, live at https://app.gradstep.ai (Pages deployment `a405d26c`, same
  commit). Layout: side panel, the paper or library in the centre, a chat panel, as in the legacy web app. Also: a
  full-width library table, a contents tree, find in paper, a figure gallery, the Feed, Add paper by DOI or link, and
  QR approval on the restore screen. Before deploying: web tests 152/152, Playwright 51 passed with 27 skipped. After
  deploying: the live page and gradstep.ai/app load the sign-in screen with no console errors. The chat panel
  was a placeholder in that deployment; milestone 2 is now deployed as recorded above.
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

The October provider budget snapshot at **2026-10-08 05:14 UTC** is **$13.677389 spent, $0 reserved, $25 limit**
(`.artifacts/takeover-20261008/budget.json`). This supersedes the earlier $9.80 cap/$5.32–$6.56 observations.
Headroom at that moment is not a fresh authorization to spend. Fixed subscriptions, infrastructure allocations,
prepaid search units and provider liability remain separate; keep the approved $100/month incremental beta ceiling.
Supabase invoice attribution is incomplete; do not retain the old approximately-$35 guess as a verified bill.
See [operations](architecture/OPERATIONS_AND_BILLING.md) and [spending controls](architecture/SPENDING_CONTROLS.md).
Use the owner Spending/Processing views or `python3 scripts/pipeline-ops.py status` for current observations;
legacy signed-URL delivery remains the explicit open replay/egress gap.

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
- **Operations:** bound the remaining legacy reader-delivery exposure; re-audit scheduled checks/alerts and
  invoice attribution; exercise owner/MFA admin flows against hosting; complete production provisioning only after
  review. Existing hold cleanup, storage admission and encrypted backup tooling must remain intact.
- **Purchases:** Production subscription/renewal/refund acceptance and current product-metadata readiness.
  Prior-period-credit retention is now implemented in 044; the local lifecycle proof is not a real StoreKit
  subscription purchase. App Store Server API reconciliation/refund-consumption responses need
  an In-App Purchase key; final review screenshots remain. Observed Sandbox pack grants are already verified
  through the private Node verifier, not unsupported Edge certificate primitives.
- **Product:** browser OAuth/Safari secure-key persistence, durable encrypted browser drafts/offline support,
  owner acceptance of build 20's screenshot fixes, accessibility on real papers and physical-device checks (paused).
  Feed 043 activation, podcast scope/privacy/pilot and public-pricing changes remain owner decisions.
- **Account deletion follow-ups before public release**: revoke the Sign in with Apple token on deletion,
  release a deleted account's App Store subscription binding, and expire deleted data from backups.
- **App Store listing**: final name and icon (the legacy artwork is a placeholder), privacy label from the
  manifest draft (email, user ID, other user content, customer support), screenshots.
- **Applied-but-unused**: migration 011's acquisition tables/RPCs remain in the database; a later additive
  migration can drop them.

# Browser, admin and server review — 2026-10-21

Status: review, owner request of 2026-10-20 (night); fixes for its server, admin and scripts findings, and separately for its browser findings, are listed under "Fix status" below (2026-10-21, not deployed). The review itself touched no code, configuration, database, deployment, phone
or NAS. Scope: `apps/web`, `apps/admin`, `supabase/functions` (every function and `_shared`),
`supabase/migrations`, `scripts/` and `tests/`, with emphasis on the 26 commits since 2026-10-16 (OpenRouter for all
inference, Gemini chat, owner testing allowance, durable beta admission, library catalogs, private-table RLS).
Browser/iPhone parity was checked against `apps/apple` source, `docs/UX_PARITY.md`,
`docs/reviews/PLATFORM_PARITY_20261020.md` and recent `IMPLEMENTATION_STATUS.md` entries.

**Confidence labels.** *Verified*: the defect was confirmed by reading the cited code (and, where noted, by running
it). *Likely*: the code path is confirmed but the runtime effect depends on something not exercised here (a hosted
service, a browser, live data). *Uncertain*: plausible, needs a reproduction before acting.

**What was run (all local, no paid calls):** backend unit tests `node --test tests/backend/*.test.ts` — 672/672
pass; browser units `apps/web` vitest — 495/495 pass; `deno check --frozen` of all 17 Edge function entry points —
passes (strict). A reviewer also ran the Python operations tests that no npm script runs: **7 of 141 fail** (D5).
A sourcemapped production build was made in the scratchpad to measure the bundle (C5).

## Summary — fix these first

1. **A1** Pressing Stop on any OpenRouter answer charges close to the whole hold, not the part written.
2. **A2** Lifetime provider-attempt counters will permanently refuse all AI work (20,000 per account, 100,000 total).
3. **A3** The admin Overview/Health read *next* month's budget row: $0 spent, wrong paused state, wrong button.
4. **A4** Every OpenRouter tariff expires 2027-01-01 00:00 UTC (about 10 weeks); chat keeps offering models that
   will then fail.
5. **A5** Add / Add to library / Ingest create duplicate imports of papers the reader already has.
6. **A6–A8** Unreconciled OpenRouter attempts and month-boundary budget handling can pause, or silently un-pause,
   paid work for everyone; App Store notifications can be blocked by anyone.
7. **A9–A11** Operator paths (testing allowance, account-deletion script, `pipeline-ops.py`) lack actor checks,
   audit rows or confirmation.

Totals: 24 correctness/security findings (A), 11 parity gaps (B), 8 performance (C), 11 structure/debt (D),
6 larger refactors (E).

## Fix status — 2026-10-21 (server, admin and scripts; built and tested locally, not deployed)

Each finding was re-verified against the code before it was changed; all of those below were real. Browser findings
(A18–A20, B, C1–C5, C8, D8, D11) were out of this pass's scope (other agents work in `apps/web` and `apps/apple`), as were
D2, D3 and the E refactors. Migrations: 0100–0108 (spending), 0120 (paper add), 0125–0128 (podcast, admission,
deletion), 0135 (default privileges). Deploy order and live checks: IMPLEMENTATION_STATUS.md, 2026-10-21.

| Finding | Status | Commit(s) | Notes |
|---|---|---|---|
| A1 | Fixed | 864233e | Generation record after a cut-short stream; reader pays the written part, never the hold; nothing if no text/tool call. |
| A2 | Fixed | fbaa583 (0100) | 24 h window of granted attempts in counter rows; limits raisable by policy; 80% warning on Spending and the budget check. |
| A3 | Fixed | cae0d61 | Overview and Health select the current UTC month. |
| A4 | Fixed | 0a0b8fd (0101) | Renewable tariff table (owner, audited, ≤183 days); chat stops offering a model 24 h before; six-week Health warning. |
| A5 | Fixed | 74113b7 (0120) | `v2_add_paper_once`; retry-stable operation id. Browser `add.ts` unchanged (not in scope). |
| A6 | Fixed | aa999f2 (0102) | Pipeline worker reconciles from generation records, bounded and audited; what cannot be (no id, retired providers, including the 2026-10-17 Anthropic attempt) is named on Health. |
| A7 | Fixed | aae2e46 (0103) | Pause/resume and the tripwire apply to later months; test accounts excluded from the tripwire. |
| A8 | Fixed | 95d3edd | Outer JWS chain and signature checked in the Edge function before admission. Notification-history reconciliation not done: needs App Store Server API credentials. |
| A9 | Fixed | 53e24b3 (0105) | Owner actor and audit, owner/tester target, disable in any state, ends with a sign-in disable, $25/month default cap, Accounts control. |
| A10 | Fixed | 6640cc0 | Closed accounts only, staging project only, typed confirmation. |
| A11 | Fixed | f1e9cab (0104) | Owner-audited UTC limit for this and later months, never the switch; `grant`/`resolve` removed. The old setter keeps its service grant (about 25 fixtures use it). |
| A12 | Fixed | b376cc0 | Ending decided when the answer ended; a finished answer is `completed`; unrelayed side requests are Gradstep's. |
| A13 | Fixed | 86f4260 (0106) | Route/upstream-scoped breakers; per-feature keys used when present (provisioning is an owner step); 402 → `service_unavailable`. |
| A14 | Fixed | c30e7ed | Auth follows the database state; superseded replays answer 409; final answers clear the retry key. |
| A15 | Fixed | 7d49e6a | OpenAlex only on an explicit `true`, failing closed; code kept behind the owner's switch. |
| A16 | Fixed | 4bab39d (0125) | Device-source records deleted with the account (and those of accounts closed earlier). |
| A17 | Fixed | 818d5c4 (0126) | Reserve (quota, rate, policy) before the upload. |
| A18–A20 | Fixed in the browser pass | — | See "Fix status — 2026-10-21 (browser)" below. |
| A21 | Fixed | 78813f0 (0127) | Audited withdrawal; no transfer through deletion; admit refuses suspended accounts. Supersedes the 10-19 linked-address re-admission. |
| A22 | Fixed | 4a3b036, 39f54af (0128) | Back-off ordering, no 30-day cut-off, stalls on Health; compatible with 095's note-asset sweep. |
| A23 | Fixed | 0abd0a4 | Invalid tool calls dropped with the text kept; `done` reports the recorded settlement; `key_count` in the ledger. |
| A24 | Fixed, one part deferred | 3886527, 42cdcc6 | Bounded bodies and third-party JSON; rebinding window narrowed (residual risk in PDF_UPLOADS §1); helpers kept out of the compiler's `http.ts`. Account-delete body bound deferred to the deletion work. |
| C6 | Fixed | f432f08 (0107) | Token check and account read together; admit+dispatch in one call; receipt concurrent with finish. Local JWKS verification not attempted. |
| C7 | Fixed | 9255ee3 (0108) | Partial indexes; stale sweep records failures and moves on. Lifetime import counters left to E2. |
| D1 | Fixed | 90b7017, fa2ba64 | Removed `deepseek.ts`, the direct podcast script and speech providers; then (owner 2026-10-21, OpenRouter exclusively) the SDK adapter, direct cards, fallback beta, native search, `claudeOpenRouter` and the `@anthropic-ai/sdk` dependency; tests run on the OpenRouter adapter. |
| D4 | Fixed | 0f26222, 35c3cba | Scripts, admin labels, docs; drills stream in OpenRouter's format. |
| D5 | Fixed | 53e3851 (0135) | `test:ops`, the 7 failures, widened fingerprints, `deno check` and admin `tsc` in fast, no silent skips, default-grant emulation, current-schema phase. |
| D6 | Fixed | 0c44802 | Wrangler shortcuts and unused plugin removed; Wrangler pinned. |
| D7 | Fixed | b3d98c0 | Obsolete/risky scripts removed; dedicated App Store Connect key; one PostgreSQL tools resolver. Provisioning and research scripts kept (still referenced). |
| D9 | Fixed | 6c93427 | `feed-refresh` in the routine deploy; every function in `config.toml`; admission hook declared (not verified against a local stack). |
| D10 | Fixed | 5ba4bc0 | Support paging and Close/Reopen; Accounts truncation notice; 30 s RPC bound; missing messages; abandoned TOTP enrolment removed. |

## Fix status — 2026-10-21 (browser; built and tested locally, not deployed)

The browser findings (A18–A20, B, C1–C5, C8, browser parts of D8 and D11), on branch
`worktree-agent-a07aac6f6943c5a8b`. Each was re-verified against the code first; all were real except where noted.
iPhone wording and behaviour were read from `apps/apple/ScienceReader` (unchanged). Nothing was deployed: the released
browser is still Pages `27c45ca0`. Evidence: `npm test` (fast tier, all steps) and `apps/web` (552 unit cases) after merging main, the affected Playwright
journeys on the desktop and phone projects (screenshots reviewed in light and dark), and before/after render counts and
bundle sizes for C. Details: IMPLEMENTATION_STATUS.md, 2026-10-21 (browser review fixes).

| Finding | Status | Commit(s) | Notes |
|---|---|---|---|
| A18 | Fixed | 13035ba | `frame-shim.js` takes a click on an outside link that the bridge didn't handle (not while text is selected) and posts it; the app opens https links without credentials in a new tab with `noopener`. Frame sandbox and CSP unchanged. Re-verified in the code (nothing handled such a click); the `arxiv-html` journey now follows a link and keeps the paper. |
| A19 | Fixed | c9a86a6 | One controller stays registered across both passes; Stop, storage retirement and sign-out are checked again after the figure images. New unit test fails on the old code. |
| A20 | Fixed | cb6b7d9 | Only key/authority, capacity, conflict and local-storage failures block sending; a connection or rate-limit failure leaves sending on. Two unit tests fail on the old code. |
| B1 | Fixed | 27ed2de | Selected answer text: Quote in Chat, Explain, Define; a formula adds Copy LaTeX and Copy as text (ChatRichTextView). |
| B2 | Fixed | 117ea96 | Papers in this answer: a port of `ChatPaperMentions.swift` (its test cases pass); Library opens a paper you have, Add to library adds one (arXiv by ID, DOI through `add-reference`). |
| B3 | Fixed | e9fee0c | The tag filter is no longer saved; the old key is removed. The status filter is still remembered. |
| B4 | Fixed | 5d9ba2e | Kept explanations sealed with the device's local key in IndexedDB, at most 400 per kind; deleted with Forget this device. A figure's image is prepared again from the paper. |
| B5 | Fixed | 69e2771 | Crop or redact: Cover private text and Crop, drawn into the uploaded image; previews are `data:` URLs. |
| B6 | Not done | — | A browser approver changes who holds key authority and needs a cross-device acceptance run (iPhone paused); not small and safe. Still documented as Not done in DECISIONS.md. |
| B7 | Fixed | d0e494a, fac8641 | Explainers ask AI model (Default / Choose model) first, name the answering model and offer Change AI; the composer's model button opens the same choice (AISelectionButton), with Length still in ⋯ › Answer options. |
| B8 | Fixed | e4ddbd0 | Chat ⋯ › Smaller text / Larger text (13–26 px), separate from the paper's A−/A+; contextual chats keep the standard size, as on iPhone. |
| B9 | Fixed | 2714d4d, 8ae1b18 | Library: Venue, Source, Pages, Chats (Chats on by default; added once to saved choices). All chats: Kind, Topics, Answer length. |
| B10 | Mostly fixed | bd27a29, 134c7ac | Use for new ‹activity›; Copy as Text on a tapped equation; Back to Table Explainer; passage chats by title; Go to passage in the chat ⋯ and All chats; Underline passages with chats; player options with Report a problem at ‹time› and Clear progress; account Sync with Sync now; version and Acknowledgements. Not done: Other lengths… (the paper's Listen has no length chooser once an episode exists) and the sign-in method in the menu (the owner removed it in build 58; `owner-58.spec.ts` asserts it stays out). |
| B11 | Fixed | 958603d | The six docs corrected in place, each marked "Corrected 2026-10-21, B11". |
| C1 | Fixed | cc9c3b3 | Activity and playback position live in external stores; 40 scroll steps: `Signed` renders 80 → 0, chat 80 → 0, library model 80 → 0, reader 80 → 50. |
| C2 | Fixed | cc9c3b3 | Branches and summaries cached per history change; streamed deltas published every 100 ms (first at once); running byte count. ~225-delta answer: branch scans 707 → 3, summaries 14 → 2, chat renders 342 → 151. |
| C3 | Fixed | cc9c3b3 | `PrivateState` indexes events by entity and caches derived views per change; catalogs and device PDFs derived once per state. Catalog-deletion batching (one refresh) not changed. |
| C4 | Fixed | cc9c3b3 | `frameDocument` keeps one parsed template per bundle: four figure frames 69.2 ms → 1.0 ms. |
| C5 | Fixed | 7ace3d9, 114df10 | Reader, account dialogs and approval QR load when needed (the reader chunk is fetched right after sign-in); the compiler moved to `src/reader/`. Initial JS 1,034.3 → 806.8 kB (310.9 → 241.2 kB gzip); after merging main (browser Notes about 42 kB in the entry, the feedback branch about 5 kB) and the B features (about 10 kB), 892.8 kB (267.0 kB gzip). Podcast, Feed and Notes stay in the first load; lazy Notes would be the next step. |
| C8 | Fixed | cc9c3b3 | LRU caps (200 equation, 24 figure results); contextual composers released when their view closes; the journal counts records with `count()`. The second decryption in `History.restore` is a different layer (event envelopes, not journal records), not a duplicate. |
| D8 | Partly fixed (browser) | dea3b6a | The browser uses the server's arXiv parser and `visualDocument` (new `_shared/visual-document.ts`) and `parseBalance`. Not done: consent-version registry, study/figure/equation server pairs (E4), Retry-After parsing. |
| D11 | Fixed (browser) | dea3b6a | Catalog and item errors in words; DOI/web additions go into the viewed catalog and a placement failure no longer fails the add; diagrams follow the app's theme; the podcast route line names OpenRouter; five unused exports removed. Kept: `add.ts`'s capabilities (the apps send the same `web_import`, `pdf_upload`) and `library-storage.ts` (deliberately staged). |

Journeys failing on `main` before this work (listed by the Notes agent) now pass (ef0b49d): the tests were stale for
account-delete, reader (invite-only wording), build-62 and library-actions (Find similar papers now first; a broad
tag the vocabulary refuses), chat-controls (three radio groups, consent v6, the saved-draft hint going away,
per-activity defaults), chat-redesign (model groups), equation-view (Gradstep Keywords, toolbar), journal (saved-draft
hint) and arxiv-html (consent v6). The app was wrong for owner-58: Privacy &amp; data still described a backup search
provider; it now uses the apps' wording. Found stale on the way and updated: account-assets (b54d0d8: the kept
explanations' wording since B4), and after merging main's feedback branch figure-view (its new promoted-chat test
lacked B7's model step) and library-actions (main's 9446667 no longer shows the generic "Large language models";
22d8991).

---

## A. Correctness and security bugs

### A1. Stop (or a dropped stream on older builds) charges about the full hold — High · verified

- **Where:** `supabase/functions/_shared/openrouter-chat.ts:127-130` (`failed()` substitutes an estimated attempt of
  `input: inputEstimateTokens, output: params.max_tokens` when no final usage arrived);
  `supabase/functions/_shared/chat.ts:857` (`credits = charged && (complete || answer.messageID) ? min(creditsFor(priced), hold.credits)`).
- **Problem:** OpenRouter reports usage only with the finish event (the adapter deliberately ignores earlier
  counters). When the reader stops, the stream read is aborted, so the estimate (full output allowance, input counted
  at one token per ~3 bytes) is priced. `stopped` and `left` are charged endings, and `messageID` is already set from
  the `x-generation-id` response header, so the "never started → nothing" guard no longer protects either.
- **Failure:** Sonnet, ~150 KB paper, Stop after a few sentences → about 89 credits charged for 1–3 credits of real
  cost. Contradicts `docs/architecture/CHAT.md:623` ("the answer's own usage so far"). The owner's unlimited testing
  allowance hides this from the owner's own testing. No test covers it (chat tests use fake generators).
- **Fix:** after a non-exact outcome, look up the exact cost with `GET /api/v1/generation?id=` (already done in
  `openrouter-speech.ts:73-85`) before settling, or settle later; as a fallback, charge from streamed characters, and
  charge nothing if no content chunk arrived. Keep the conservative estimate only for platform liability. Add a chat
  test with the real OpenRouter adapter and an abort.

### A2. Lifetime attempt counters will permanently refuse all paid work — High · verified

- **Where:** `supabase/migrations/202610180089_openrouter_all_inference.sql:45-48`
  (`(select count(*) from app_private.provider_attempts)>=pol.attempt_limit`, and per account); limits and their
  check-constraint maxima in `202610070034_provider_accounting.sql:16-18` (100,000 total, 20,000 per account).
- **Problem:** counts are over every row ever stored; nothing prunes `provider_attempts`; refused (`denied`) attempts
  are inserted and count too; the constraints forbid raising the limits without a migration. The 80% warning
  `attempt_capacity_eighty_percent` is computed by the server but never displayed
  (`apps/admin/src/spending.tsx:22` only types it). The limit is undocumented.
- **Failure:** a chat with title and suggestions uses ~3 attempts, so the owner's testing account is locked out
  after ~6,600 answers and the platform after ~33,000; every chat, tag and podcast then fails as
  `service_unavailable`. Each admission also runs a full `count(*)` while holding the operation/budget/policy locks.
- **Fix:** additive migration: count per rolling window (or non-final states only) with an index-backed counter row,
  relax the constraint maxima, show the anomaly in Admin › Spending and alert at 80%.

### A3. Admin Overview and Health show next month's budget — High · verified (code; not compared with live data)

- **Where:** `apps/admin/src/main.tsx:113` (Health) and `:220` (`BudgetPanel`) use `overview.budgets[0]`;
  `v1_admin_overview` sorts budgets `period desc` (`202610020004_support_admin.sql:136`); since
  `202610140060_sync_fence_and_budget_periods.sql:47-50` a next-month row always exists.
- **Failure:** Overview shows Incurred $0 / Reserved $0; after a pause or tripwire pause the badge still says
  "Enabled" and the button offers "Pause", so the owner cannot resume from the UI; Health's paused and 80% warnings
  (`health.tsx:170,182-183`) never fire. The Spending tab picks the current month and disagrees.
- **Fix:** select the current UTC period explicitly (server-side in the overview, or by `period` in the client).

### A4. All OpenRouter work stops on 2027-01-01, and chat keeps offering it — Medium-high · verified

- **Where:** `202610180089_openrouter_all_inference.sql:50` (`now()>='2027-01-01' → tariff_expired`); TS constants in
  `gemini-pricing.ts:6`, `openrouter-claude-pricing.ts:4`, `openrouter-deepseek-pricing.ts:7`,
  `openrouter-speech.ts:46`; `openrouter-chat.ts:133` checks DeepSeek against `GEMINI_PRICE_EXPIRES`
  (`ROUTER_DEEPSEEK_EXPIRES` is unused); `chat/index.ts:35` computes `claudeAvailable` and never uses it.
- **Failure:** at the date, `GET chat` still publishes Claude (the flag is the constant `claudeOpenRouter = true`),
  requests reserve credits and then fail as `service_unavailable` with `retry_after: 10`, so clients retry in a loop.
  Tags and podcasts stop too.
- **Fix:** keep tariff validity in one table read by SQL and TS; gate publishing and acceptance on it; return a
  distinct `model_unavailable`/`tariff_expired`; add a 30-day expiry warning to Admin › Health.

### A5. Adding a paper the reader already has creates a duplicate import — Medium-high · verified

- **Where:** `supabase/functions/_shared/find-paper.ts:95-111` (`importPaper`, shared by add-paper, add-reference
  and chat Ingest); `v2_begin_import` (`202610030010_library_import_contract.sql:396-416`) does not deduplicate.
- **Problem:** "present" means `kind==='item'` or phase `accepted|resolving|acquiring`, but since migration 058
  finished arXiv imports end in phase `source_only`; only the oldest 300 library entries are read (ascending
  `created_seq`); every call uses a fresh `crypto.randomUUID()` operation id (and so does the browser,
  `apps/web/src/lib/add.ts:41`).
- **Failure:** re-adding or retrying adds another `import_requests` row and duplicate library rows, consuming the
  lifetime 2,000-per-account / 20,000-per-environment import limits (same lifetime-count pattern as A2).
- **Fix:** one server RPC "begin import unless this source is present for the account" that treats `source_only` as
  present; a retry-stable operation id derived from the request id.

### A6. Unresolved OpenRouter attempts hold their full ceiling until a human reconciles them — Medium · verified

- **Where:** `provider-spending.ts:113-114` (non-exact → state `unknown`, cost `null`); settle keeps unknown
  ceilings in reserved liability (migration 079); manual reconcile only (`scripts/pipeline-ops.py:60-66`).
- **Failure:** every Stop, mid-stream 5xx, timeout or dropped stream reserves the attempt's whole ceiling (A1's
  over-estimate) against the $100/month budget. A provider outage or many Stops can reach
  `platform_budget_exhausted` and pause AI for every tester until someone runs the script. DECISIONS.md (2026-10-18)
  requires actual-cost reconciliation.
- **Fix:** background generation-id lookup for every non-exact attempt (as speech does), then `reconcile`
  automatically with the receipt as evidence.

### A7. Budget pauses are lifted on the 1st; test-account anomalies can pause everyone — Medium · verified / likely

- **Where:** `202610140060_sync_fence_and_budget_periods.sql:47-50` creates next month's row on the first daily run
  of the current month, copying `work_enabled`/limit at that moment; owner pause (`202610020004_support_admin.sql:147`)
  and the overrun tripwire (`202610160079…sql:97`) change only the current month.
- **Failure:** an emergency pause on the 20th is silently undone at 00:00 UTC on the 1st; a mid-month limit change
  does not carry over. Separately, `anomalies_toward_tripwire` (079:72-80) does not exclude `test_account`, so more
  than 5 drill/fixture overruns in an hour pause AI for all (likely).
- **Fix:** apply pauses and limit changes to existing future rows (or create the next row only at the boundary);
  exclude test accounts from the tripwire count.

### A8. Anyone can exhaust the App Store notification quota — Medium · verified (code)

- **Where:** `supabase/functions/app-store-notifications/index.ts:29-55` → `store-verifier-transport.ts:145-148`
  consumes the global `notification` channel quota (60/h, 200/day, 1,000/month; migration 033) before the private
  verifier checks Apple's signature; the only earlier check is JWS shape.
- **Failure:** a script posting JWS-shaped junk to the public, predictable URL uses the quota; real notifications
  then get 503. Sandbox (the only allowed environment) does not retry reliably *(uncertain)*, and nothing reconciles
  from notification history, so refunds/revocations can be lost.
- **Fix:** a secret path token in the notification URL checked before admission; separate quotas for unverified vs
  verified; a daily reconciliation from the App Store Server API notification history.

### A9. Owner testing allowance: no actor check, misattributed audit, no cap — Medium · verified

- **Where:** `202610190094_owner_testing_allowance.sql:16-53` and `:94-118`.
- **Problems:** no `p_actor_id`/`require_owner_account`, no check that the target is an owner or tester; the audit
  row records the *target* as actor with a hard-coded `'explicit-owner-direction'`; disabling is refused for a
  suspended account (line 23), and re-enabling sign-in clears suspension, silently restoring unlimited credits;
  within the shared budget there is no per-account monthly cap; no script or admin control calls it (enabled by
  hand-written SQL) and Admin › Accounts shows ~100,000 credits with no marker.
- **Failure:** any service-role path can give any user self-refilling credits without a traceable actor; a runaway
  loop on the owner's client can spend the whole month's budget and pause AI for every tester. (It cannot exceed the
  platform ceiling: reservation still checks the budget.)
- **Fix:** route through `admin-accounts` with an owner actor and reason; require an owner/tester role; allow
  disabling regardless of suspension; add a per-account testing spend cap; show it in Accounts.

### A10. `finish-account-deletion.mjs` will delete any open account — Medium · verified

- **Where:** `scripts/finish-account-deletion.mjs:10-15` calls `worker_delete_account_begin` with the service key
  for any UUID; that function closes and deletes open accounts too (`202610050017_account_deletion.sql:80-99`).
- **Failure:** a wrong or pasted UUID permanently deletes a tester's (or the owner's) library and login. There is no
  project assertion or confirmation, and two agents alternate on this repository.
- **Fix:** require `closed_at` already set, assert the staging project ref, require a typed confirmation.

### A11. `pipeline-ops.py budget`/`grant` bypass the budget and audit safeguards — Medium · verified

- **Where:** `scripts/pipeline-ops.py:79-86`; `worker_set_platform_budget` (`202610050014_paper_pipeline.sql:799-807`)
  takes no actor and writes no audit row.
- **Failure:** `budget` always sends `p_enabled = not --disable`, so changing a limit silently resumes a
  tripwire-paused month; it uses the Mac's local date (evening of the last day in Pacific time updates the previous
  month); next month keeps the old limit. `grant` issues uncapped, unaudited credits (the admin site caps at 2,000 and
  audits). This conflicts with "do not silently increase the budget". `resolve` handles only retired Mathpix OCR.
- **Fix:** keep the switch unless asked, use UTC, require an owner actor and reason with an audit row and ceiling,
  update next month too; remove `grant` and `resolve`.

### A12. A finished answer becomes free if the connection drops during side requests — Medium · verified

- **Where:** `chat.ts:835` evaluates `readerLeft: signal.aborted` only after the title grace, suggestions, study map
  and stop check; `answerEnding` (`chat.ts:1000-1006`) lets "reader left" decide before "complete".
- **Failure:** a client with `stop_signal` that disconnects after receiving all text but before `done` gets
  `connection` (uncharged). CHAT.md (after the endings table) says such an answer "is charged as finished". A
  modified client can avoid paying for every answer.
- **Fix:** capture `readerLeft` when `generateAnswer` returns, or treat a complete answer with delivered output as
  `completed` regardless of later aborts.

### A13. One OpenRouter breaker and one key for everything; billing failure blames the model — Medium · verified

- **Where:** breaker keyed by host (`provider-health.ts:34-38`, `openrouter.ai → openrouter`); one
  `OPENROUTER_CHAT_API_KEY` for chat (`chat/index.ts:28`), tags and podcasts (`services/pipeline-worker/run.ts`,
  `podcast-run.ts`); 402 mapped to `model_unavailable` (`chat.ts:988-990`) with browser text "Choose another AI model"
  (`apps/web/src/lib/chat.ts:358`).
- **Failure:** five failures in 60 s from any route (a DeepInfra outage, TTS errors in a podcast, tag-job 429s) fail
  every Claude and Gemini chat with synthetic 429s for 30 s–5 min; a runaway podcast/tag job drains the balance chat
  needs; readers are told to switch models when every model shares the empty account.
- **Fix:** breakers keyed by provider+model/route from dispatch metadata; per-feature keys with OpenRouter per-key
  limits; a service-wide "AI temporarily unavailable" code for 402.

### A14. Admin sign-in replay applies the old intent to Auth — Medium · verified

- **Where:** `supabase/functions/_shared/admin-accounts.ts:185-190` bans/unbans with `request.disabled` and echoes it;
  on replay the database returns the *current* state (`202610070034…sql:408-410`, restated in 093); the admin's
  `once()` (`apps/admin/src/mutations.ts:6-14`) reuses a request id after any thrown attempt.
- **Failure:** disable "spam" (response lost) → later enable → later disable "spam" again reuses the old id: Auth bans
  the user for 100 years while the database says enabled and admission says allowed, and the UI reports success.
- **Fix:** use `result.disabled` for `updateUserById` and the response; reject replays whose intent differs from the
  current state; clear the retry key once an answer is final.

### A15. The owner's "OpenAlex off" decision is not enforced — Medium · verified

- **Where:** migration `202610160075_device_search_on.sql:9` sets `openalex_enabled=false`; only `identify.ts:270`
  honours it. `find-paper.ts:23-49` (first lookup for Add/add-reference/Ingest) and `reference.ts:121,182` call
  OpenAlex unconditionally; add-reference never reads the policy; `add-paper/index.ts:47` fails open on a policy error.
- **Failure:** readers' add queries keep going to a service the owner dropped (privacy and policy drift).
- **Fix:** pass the policy into `paperFinder` and `resolveReference`; treat an unreadable policy as off.

### A16. Podcast device-source records survive account deletion — Medium · verified (code)

- **Where:** `202610140066_podcast_device_sources.sql:9-27` — `owner_id`, `membership_id`, arXiv `source_id`,
  `title`, `authors`, protected by `immutable_record()` (blocks every UPDATE/DELETE); no deletion path scrubs it.
- **Failure:** the link between a deleted user and the papers they made podcasts of remains indefinitely, contrary to
  the account-deletion promise and PAPER_PODCASTS.md's deletion section *(policy conflict: likely)*.
- **Fix:** allow a deletion-only scrub (null owner/title/authors, or delete) when `app_private.deleting_account` is
  set, mirroring how the ledger keeps billing records de-identified.

### A17. Podcast `source` upload writes before quota, rate limit or policy checks — Medium-low · verified

- **Where:** `supabase/functions/_shared/podcast-api.ts:75-84` uploads to `private-content`, then calls
  `worker_podcast_source_register`, which enforces the 64 MB/account and 2 GB global quotas.
- **Failure:** when registration fails, the ≤400 KB object stays without a `stored_objects` row until account
  deletion (prefix sweep); no `worker_consume_request` limit or podcast policy gate, so any tester can grow storage
  even while podcasts are switched off.
- **Fix:** register a pending row (quota + rate limit + policy) first, upload, then verify.

### A18. External links inside a browser paper likely replace the paper with an error — Medium-low · likely

- **Where:** the arXiv adapter keeps external `<a href="https://…">` (`_shared/reader/arxiv/inline.ts:55`); the frame
  is `sandbox="allow-scripts"` (`apps/web/src/ui/Reader.tsx:497`) under page CSP `frame-src 'self'`;
  `src/reader/frame-shim.js` has no click interception. Native intercepts and opens Safari
  (`apps/apple/ScienceReader/Views/PaperView.swift:1316-1323`). Also a parity gap.
- **Failure:** clicking a dataset/code link navigates the frame, the CSP blocks it, the reading position is lost.
- **Fix:** in `frame-shim.js` intercept `a[href^="https:"]`, post `{type:'link'}`, open with `noopener` after
  `safeLink`; add an e2e case.

### A19. Browser Stop is ignored during the figure follow-up gap — Medium-low · verified

- **Where:** `apps/web/src/lib/chat-session.ts:1010` removes the stream in `finally`, then awaits
  `chatFigureImages` (`:1014`) before the second pass; `stop()` returns early when no stream is registered (`:856-857`);
  after the await only `this.signal.aborted` is checked.
- **Failure:** a Stop, storage retirement or sign-out in that window is ignored and a second paid request starts.
- **Fix:** keep one controller registered across both passes; re-check `stopping`, `retiredStorage`, `accepting`
  after the await.

### A20. One failed background sync blocks sending in the browser — Low-medium · verified

- **Where:** any sync failure sets `history.issue` (`apps/web/src/lib/history.ts:162-166`); sending refuses while it is
  set (`chat-session.ts:755`, `ui/ChatPane.tsx:148`).
- **Failure:** a transient 30-second background sync failure (`connection`, rate limit) refuses the next question
  although the durable journal could commit it locally — the opposite of "degrade, don't refuse".
- **Fix:** block only on errors that need key/authority action.

### A21. Beta admission gaps — Low-medium · verified / likely

- **Where:** `202610190091_durable_beta_admission.sql`.
- **Problems:** no revoke function — an invitation retained for a deleted account or a mistyped address can only be
  removed with hand SQL (verified); the deletion trigger admits every verified address on the login at that moment,
  so a tester can transfer their invitation by changing email before deleting (likely); `worker_admin_admit_email`
  refuses only on an Auth ban, not on `accounts.spending_suspended`, and the Edge function bans after the database
  commit, so an admit in that window re-allows a disabled user (likely).
- **Fix:** owner-checked, audited `worker_admin_revoke_email`; retain only the originally admitted address; check
  suspension too.

### A22. Account-deletion sweep can stall and silently gives up after 30 days — Low-medium · likely

- **Where:** `supabase/functions/_shared/account-deletion.ts:124-135` takes the first 3 pending accounts ordered by
  `closed_at`; accounts that can never finish (more than 20,000 objects, `asset_write_uncertain`) occupy those slots on
  every run; closed accounts leave the pending list after 30 days with no alert.
- **Fix:** order by last attempt with back-off; alert on closed accounts that still own personal rows or objects.

### A23. OpenRouter adapter edge cases lose answers or misreport — Low · verified

- **Where/what:** `openrouter-chat.ts:197-201` — an unknown tool name, missing id or unparsable arguments (for
  example a `length` stop inside a large `create_visual` call) throws and turns an already streamed answer into
  `provider_unavailable` instead of a `limit` ending; `chat.ts:1243-1258` — a failed settlement is only logged, while
  `done` still says `charged:true, credits:N` (the stale sweep later charges 0); `chat.ts:460` writes model-chosen key
  names into the immutable `provider_usage_events` ledger, breaking "codes and counts only".
- **Fix:** drop invalid calls and keep the text, map `length` to `max_tokens`; report the settlement outcome; store a
  key count or hash.

### A24. Input bounds and a DNS-rebinding window — Low · verified / uncertain

- **Where:** unbounded bodies — `account-delete/index.ts:23` (`request.text()` before the 1,024-character check),
  `add-paper/index.ts:32` and `add-reference/index.ts:31` (`request.json()`), `podcast-api.ts:36-40` when
  `content-length` is absent; uncapped third-party JSON — `find-paper.ts:33`, `identify.ts:247`, `reference.ts:114`;
  `identify.ts:167-172` resolves a host for the private-address check and `fetch` resolves it again *(rebinding
  exploitability uncertain; titles of fetched pages are echoed back)*.
- **Fix:** use the existing `readBounded`/`readCapped` everywhere; enforce the address check at connect time or let
  the device probe links.

## B. Parity gaps: iPhone has it, the browser does not (or differs)

Deliberate differences were excluded: purchases, on-device PDF model and Mac local AI, offline reading/downloads,
Safari key storage, offline support-report retry. The browser Feed's "More like this"/"Not interested" are a gap in
the other direction.

### B1. No actions on selected answer text or formulas — Medium · verified

iPhone: Quote in Chat, Explain, Define; formulas add Copy LaTeX and Copy as text
(`apps/apple/ScienceReader/Views/ChatRichTextView.swift:204-235`, `ReaderModel.swift:3562-3612`). Browser: only
whole-answer Copy (no match for "Quote in", "copy latex" in `apps/web/src`). Listed as deferred in
`docs/architecture/BROWSER_READER.md:825`. Fix: a selection toolbar on `Answer` that reuses the send path.

### B2. No "Papers in this answer" list — Medium · verified

iPhone lists arXiv IDs/DOIs named in an answer with Add/Open (`ChatRichTextView.swift:620-760`, used in
`ChatTranscript.swift:206`). Browser: absent. Fix: move mention detection into shared code and reuse the browser's
Add paper (after A5 is fixed, so repeated adds don't duplicate).

### B3. Browser still restores the last tag filter — Medium · verified

The owner reported launching into an empty library because an old tag filter came back; iPhone now always starts
with all tags (`ReaderModel.swift:304-310`). Browser saves and restores `gradstep.library.tag`
(`apps/web/src/ui/App.tsx:40,250-256`), cleared only incidentally when the catalog id changes
(`ui/Library.tsx:272`). Fix: stop persisting the tag; keep the status filter.

### B4. Kept explanations last only for the tab's lifetime — Medium · verified

iPhone stores equation/figure explanations on the device (`ReaderModel.swift:4002-4011`,
`Views/KeptExplanationsView.swift`). Browser keeps them in memory (`lib/chat-session.ts:583-596, 642-646`), so after a
reload reopening one is a new paid request — the same complaint the owner made on iPhone. Documented as interim.
Fix: store them in the existing encrypted browser storage.

### B5. Support screenshots cannot be cropped or redacted — Medium · verified

iPhone: "Crop or redact" with "Cover private text" (`Views/ReportComposer.swift:36-40,127-149`). Browser: Remove only
(`ui/SupportReports.tsx:88-95`), and "Capture this screen…" uploads the whole tab. Private paper or chat text can reach
support; crop/redact is a requirement in `docs/TESTING_FEEDBACK.md`. Fix: a canvas crop/cover step before upload.

### B6. The browser cannot approve another device — Medium-low · verified (documented "Not done")

iPhone: Settings › Account › Add a device, waiting-device list and banner (`Views/SettingsPages.swift:136-138`,
`Views/DeviceApprovalViews.swift:146,203`). A new Mac's screen tells the user to use that menu
(`Mac/MacDeviceApproval.swift:103`), which a browser-only user lacks. Fix: no-camera number-comparison approval in
the browser.

### B7. Explainers handle the model choice differently — Low-medium · verified

iPhone asks Default/Choose model before explaining, offers "Change AI" on failure, and names the model
(`Views/EquationView.swift:221,244,306,453`; `Views/FigureExplainView.swift:169-173,373`). Browser starts at once with
the default, offers only "Try again", shows no model (`ui/FigureView.tsx:155-177`, `ui/EquationView.tsx:165,178`); the
composer's model button opens the full Answer options dialog (`ui/ChatPane.tsx:306`), not the simpler first step the
owner asked for. Recovering from a provider billing failure (A13) needs a detour.

### B8. No chat text size control — Low-medium · verified

iPhone: chat "…" › Smaller/Larger text (`Views/RootView.swift:1215`). Browser: reader A−/A+ only
(`ui/Reader.tsx:443-444`). `docs/UX_PARITY.md` requires separate paper and chat font sizes.

### B9. Missing Library and All chats columns — Low · verified

iPhone Library has Chats (on by default; the owner asked it to show 0), Venue, Source, Pages and phone defaults
including Added/Opened (`Services/LibraryMetadata.swift:225-226`, `Views/LibraryTableView.swift:33-43`); browser
lacks them (`lib/library-columns.ts:2-15`). iPhone All chats has Kind, Topics, Answer length
(`Views/ChatHistoryView.swift:23-36`); browser only Paper, Messages, Started (`ui/ChatPane.tsx:363`).

### B10. Smaller interaction differences — Low · verified

- Tapped equations lack Copy as text/LaTeX (`Mac/MacSupport.swift:296-340` vs `ui/Reader.tsx:502-515`).
- A table explainer's return button says "Back to Figure Explainer" (`ui/Reader.tsx:125,454,556`); iPhone says Table
  (`Views/PaperView.swift:678`) — an owner-reported wording problem.
- Passage marks: no "Underline passages with chats" setting; several chats on one passage show "Chat 1/2" instead of
  titles (`ui/Reader.tsx:517`); "Go to passage" only in the chat heading.
- Podcast player lacks Other lengths…, Clear progress, "Report a problem at 12:34"
  (`Views/PodcastPlayerViews.swift:189-204`).
- Default-model button still reads "Reset default settings" (`ui/ChatProfile.tsx:76-77`); iPhone reads
  "Use for new ‹activity›" since c4d15d9.
- Account menu lacks sync status/Sync now, sign-in method, app version and Acknowledgements (Mermaid, Temml,
  htmlparser2, DataCite CC0) (`ui/App.tsx:758-830` vs `Views/RootView.swift:1762`).

### B11. Docs that claim parity the code does not have — Low · verified

`docs/IMPLEMENTATION_STATUS.md:1106-1111` (account menu "sync state"; "text sizes … as on the apps"),
`docs/architecture/CHAT.md:22` (same button wording), `docs/DECISIONS.md:1265` (says the browser lacks passage marks;
it has them), `docs/DECISIONS.md:1392` and `docs/architecture/PRIVACY_AND_SYNC.md:158` (new Mac restores only with a
recovery code; it now shows a QR code), the "columns/explainers" row of `PLATFORM_PARITY_20261020.md` (true only for
the Device/Authors split), and `docs/UX_PARITY.md` (chat font size; it also still calls Mathpix conversion a reader
gate, contradicting the 2026-10-13 HTML-first decision).

## C. Performance

### C1. Reading position and podcast playback re-render the whole browser app — Medium · verified

`Signed` in `apps/web/src/ui/App.tsx:115-750` (~635 lines, 37 `useState`, 15 effects) owns the activity map, set on
every reader scroll report (~8/s: `ui/Reader.tsx:258-264` → `record`, `App.tsx:311-316`), and hosts
`usePodcastPlayer`, whose `positionMs` updates on every `timeupdate` (`ui/Podcast.tsx:232,354`). `PaperReader` and the
chat pane are not memoized, so reader, chat, header and library rail re-render 4–8 times a second, each running C2's
history scans. Fix: move activity and playback position into small external stores with selective subscribers;
memoize `Reader`/`ConnectedChat` with stable callbacks.

### C2. The chat pane rescans the whole history on every render and every streamed token — Medium · verified

`ConnectedChat` calls `chat.profileFor(c)` (`ui/ChatPane.tsx:91`), `profileReason` (`:326`) and `retryProfile`
(`:291`); each goes through `branch()` → `conversationBranches()` (`lib/events.ts:251`), which walks every event (up to
20,000) and rebuilds `deleted()`. `ChatSession` publishes once per streamed event (`chat-session.ts:1005`) and per
keystroke; All chats (`ChatPane.tsx:396-398`) rebuilds `conversationSummaries()` per event in a non-virtualized
table. Streaming also re-encodes the whole accumulated text per delta to count bytes (`chat-session.ts:991`). Fix:
memoize branch/summary results by history version, coalesce publishes during streaming (the 80 ms display cadence
already exists), keep a running byte count.

### C3. Derived library state is rebuilt from all events — Medium · verified

On each history version: `useCatalogs.ts:7` builds a new `LibraryCatalogs` (all events), whose new identity re-sorts
the library (`ui/Library.tsx:80`); `conversationSummaries()` runs twice (`App.tsx:534`, `ChatPane.tsx:78`);
`diagramsByMessage()`/`savedDiagrams()` call `revisions()` per diagram (O(diagrams × events), `lib/events.ts:355-380`);
`useDevicePDFs.ts:29` calls `revisions()` per local PDF. `currentState()` constructs a fresh `LibraryCatalogs` per call:
twice per `assign` (`ui/useCatalogs.ts:31`), per catalog row (`ui/Catalogs.tsx:36,52`) and per paper in
`deleteCatalogPapers` (`ui/useLibrary.ts:205-208`, O(papers × events)), which also makes two sequential round trips
per paper (`useLibrary.ts:206-212` plus a full `refresh()` per command). Fix: cache derived state per version; index
`PrivateState` events by entity; batch catalog-deletion commands and refresh once.

### C4. Each figure view rebuilds and re-embeds the entire paper — Medium · verified

`ui/Figures.tsx:50` and `ui/Reader.tsx:683` call `frameDocument(bundle, {figureID})`, which re-parses the whole HTML,
base64-encodes every image and embeds the full index plus the 136 KB bridge script — per ←/→ step and again for the
fullscreen iframe. Image-heavy papers (the WebKit encoded-size limit was already hit, e2d7e38) pay this repeatedly.
Fix: a figure-only document (the block plus its assets) or a cached encoded-asset map.

### C5. Initial JavaScript is 1.03 MB (311 KB gzip); the arXiv compiler ships twice — Medium · verified

Measured: react-dom 207 KB; the 136 KB reader-frame script string (needed only when a paper opens); Podcast ≈ 52 KB;
Feed/PaperSearch ≈ 26 KB; Keys + `uqr` ≈ 20 KB; Support 9 KB. Mermaid (5.5 MB) and Markdown/Temml (306 KB) are already
lazy. `apps/web/public/arxiv-reader.js` (163 KB) is copied to `dist/` although it is only read at build time and
inlined into `_virtual_arxiv-compiler` (`apps/web/vite.config.ts:33`). Fix: lazy-load Reader (with
`virtual:reader-frame`), Listen/Podcast, Feed, Keys/approval and Support (~35–40% smaller first load); move the
compiler out of `public/`.

### C6. Six sequential database round trips before the first token — Medium-low · verified

Per chat: `userClient` (Auth `getUser` + `v1_account_context`, `_shared/backend.ts:12-24`), consume-request, context,
`worker_reserve_chat`, `worker_provider_attempt_begin`, then `worker_openrouter_dispatch`
(`openrouter-transport.ts:47`); afterwards the receipt RPC is awaited before the result returns
(`openrouter-chat.ts:207`), delaying `done` and the suggestions request. add-paper runs its rate limit and policy
reads sequentially (`add-paper/index.ts:38,46`). Fix: fold dispatch into attempt-begin (one transaction), verify JWTs
locally (JWKS) where possible, record receipts via `waitUntil` or with finish.

### C7. SQL hot paths scan growing tables under global locks — Medium-low · verified

Besides A2's `count(*)`: `reserve_operation_before_034` counts all of an account's operations under the budget lock
(`…094…sql:74`); `v2_begin_import` counts every import in the environment per call (`…010…sql:408-409`);
`worker_expire_stale_chat_operations` (`…079…sql:288-303`) runs on every pipeline invocation without a partial index,
always retries the same oldest 50, and swallows every error (`exception when others then null`), so 50 permanently
failing operations block it and keep `reserved_microusd` inflated. Fix: partial indexes on
`metered_operations … where state<>'settled'`, counter rows instead of counts, record and skip failing sweeps.

### C8. Browser caches never evict; journal start-up reads twice — Low-medium · verified

`figureResults` (base64 JPEGs up to ~1.5 MB each, `chat-session.ts:642,704`) and `equations` (`:582,634`) never
evict; contextual composers are created by merely viewing a figure/equation (a side effect inside `useMemo`,
`ui/ContextualChat.tsx:10`), never removed, each holding a Web Lock. `journal.ts:300` runs `getAll` over the whole
partition (up to ~96 MB) only to count records, and `History.restore` decrypts everything again
(`history.ts:90`). Fix: LRU caps, create composers on first input, `count()`/`getAllKeys`.

## D. Structure, duplication and debt worth fixing now

### D1. Direct-provider code that production can no longer reach — Medium · verified

Owner direction (2026-10-18) is "remove direct-provider fallback". Unreachable from any entry point: `anthropic.ts`
`streamChat`/`createAnthropicClient`/`attemptsFromUsage`/`FALLBACK_BETA`/web-search tools and direct `KNOWN_RATES`;
all of `deepseek.ts` (150 lines); `podcast-script.ts:294` `anthropicScriptProvider`; `podcast-speech.ts:178-260`
(Vertex speech); the constant `claudeOpenRouter = true` and its branches in `chat-profiles.ts:99-103,239-243` and
`chatQuote`; native-search failover and `pause_turn` handling in `chat.ts` (`nativeSearch` is hard-coded false and
`provider-spending.ts:88` refuses web search); anthropic/deepseek synthetic streams in `provider-health.ts:128-221`.
`chat.test.ts`, `deepseek.test.ts`, `provider-health.test.ts` and `podcast.test.ts` still exercise these adapters,
overstating coverage of the live OpenRouter path. The podcast model-change check can never fire
(`podcast-worker.ts:588` with `openrouter-script.ts:25`). The `@anthropic-ai/sdk` dependency survives mainly for types.

### D2. Retired server-copy and Mathpix surfaces are still deployed, provisioned or shipped — Medium-low · verified

`reader-artifact`, `reader-member` and `upload-pdf` remain in `infra/staging.json:60-75` although after migration 080
they can only answer `reader_unavailable`/410; the browser still calls `reader-artifact` on every open of a non-arXiv
item (`ui/Reader.tsx:177-181`). `deploy-staging.py:109-121` still creates `paper-assets`/`paper-uploads` and raises the
project upload limit to 64 MiB (config.toml says 32 MiB). About 1,750 lines of Mathpix renderer
(`_shared/reader/{index,bundle,render,validate,flow,mathvariant}.ts`, `mathpix.ts`, `mathpix-result.ts`, `archive.ts`),
`scripts/render-mathpix-reader.ts`, and the `markdown-it@9.1.0`/`mathpix-markdown-it` dependencies are reachable only
from tests and that script (`arxiv-html.ts` needs only the `ReaderIndex` type). Fix: 410 stubs then removal; drop the
bucket provisioning; move `ReaderIndex` to a types file and archive the rest.

### D3. Retired provider and pipeline surface in SQL — Low · verified

About 70 retired functions (acquisition, OCR/Mathpix, PDF uploads, reader delivery, originals) are still granted to
`service_role` (fences in 077/080/089 block their effects); `worker_provider_attempt_begin` accepts
`anthropic|mathpix|google|deepseek` and carries dead pricing branches (`…089…sql:23-31,80-108`); it now exists in nine
full copies (034→089); 35 `*_before_NNN` wrapper layers remain (`v1_admin_health` is four deep; 080's
`worker_chat_context` does the same work twice). Several migrations alter constraints without `lock_timeout` or
`NOT VALID` (082:10-11, 083:7-8; 076, 084), taking full-table exclusive locks on money tables. Fix: revoke retired
families now; see E2.

### D4. Operations tooling still targets Anthropic after the OpenRouter switch — Medium · verified

`scripts/fault-drill.mjs:57` defaults to `--provider=anthropic`; chat now calls only `openrouter.ai`, so throttle
drills inject nothing, `midstream`/`slow` drills fire only for anthropic/deepseek hosts (`provider-health.ts:218`) and
emit Anthropic-format SSE, and the overrun drill (`:295`) admits as `anthropic`/`chat`, which 089 rejects
(`invalid_provider_route`) after reserving an operation (left to the stale sweep). `scripts/workflow-checks.mjs:963-964`
filters `provider='anthropic'`, so `chat.profiles`/`chat.profiles-max` would fail "provider attempts none" after ~$0.65
of paid calls. Admin labels still say "OpenRouter (Google chat)" and keep Anthropic/DeepSeek as providers
(`apps/admin/src/health.tsx:18-20`, `provider-hours.tsx:8`); the Processing tab still shows paid OCR attempts
(`main.tsx:136-151`). `docs/architecture/RESILIENCE.md:240,366` and `docs/TESTING.md:241` give the stale command.

### D5. Test organization hides failures and stale evidence — Medium · verified (run)

- 12 `tests/operations/test_*.py` files and `workflow-packaged-runner.test.mjs` are run by no npm script or doc;
  running them gives **7 failures of 141** (six staging-deployment tests still supply direct Anthropic/DeepSeek keys,
  `test_staging_deployment.py:20,111,116`; `test_restore_quarantine.py:426` enables PDF uploads, now forbidden).
  `docs/TESTING.md:231` says fast covers `tests/operations/`.
- `scripts/test-tiers.mjs:9-10` fingerprints only `apps/web`, `apps/apple`, the reader `_shared`, `tests/` and a few
  scripts, so `test:status` says "source unchanged" after edits to other `supabase/functions`, `apps/admin`,
  `services/` or migrations — undermining the "reuse recorded evidence" policy.
- `scripts/test-database.py:76-81` runs the ~50 general `test_*.sql` suites (ledger invariants, provider accounting,
  owner accounts) only against migrations before 058; the current reserve (094) and settle (079) are covered only by
  narrow fixtures. `acquisition_concurrency.py` and `library_concurrency.py` are never called.
- `tests/database/bootstrap.sql` does not reproduce Supabase's default EXECUTE grants to `anon`/`authenticated`
  (migration 001:8 revokes only `PUBLIC`), so a forgotten revoke would pass every `has_function_privilege` check.
  (Today all 320 final public functions are correctly granted — checked by replaying all migrations.)
- No tier type-checks Edge functions (`deno check` passes today but runs only by hand) or `apps/admin`.
- Fix: `test:ops`; widen the fingerprint; a current-schema general DB phase; emulate default grants plus an
  "no public function executable by anon" check and a migration revoking the default privileges; add `deno check`
  and admin `tsc` to fast.

### D6. Root `npm run deploy`/`preview` are wrangler leftovers that bypass the deploy gates — Medium-low · verified

`package.json:18-19` (`npm run build:admin && wrangler deploy` / `wrangler dev`), added incidentally in 40e441f with
caret-ranged `@cloudflare/vite-plugin` (unused) and `wrangler`; no wrangler config is tracked. With autoconfig,
`wrangler deploy` at the root would try to deploy a Worker, skipping `scripts/deploy-web.mjs`'s credential, fixture
and CSP checks — contrary to ADMIN_HOSTING's "pinned Pages mode prevents an implicit Worker deployment". Fix: delete
both scripts and the plugin; pin wrangler exactly.

### D7. Scripts: obsolete, risky or duplicated helpers — Low-medium · verified

- `scripts/read-nas-provider-config.py` reads the NAS `.env.local` over SSH (`:12-14`) for retired Mathpix and direct
  providers and reads `../textbrain/.env` (`:31`) — delete.
- `scripts/configure-native-auth.py:176-187` signs with TextBrain's App Store Connect key; AGENTS.md requires dedicated
  Science Reader credentials (`asc.mjs` already uses `.env.appstore`).
- Unreferenced since Oct 3–5: `deploy-support.py` (rewrites `ADMIN_ORIGINS` and deploys `support-assets` outside
  `deploy-staging.py`'s gates), `configure-apple.py`, `provision-supabase.py`, `enforce-database-tls.py`,
  `setup-store-products.mjs`; research tools `openrouter-wire-smoke.mjs`, `local-model-eval.mjs`,
  `model-bakeoff-archive.mjs`, `model-bakeoff-render-check.mjs`; finished-cutover `reader-cutover-canary.mjs` (50 KB)
  whose 27 KB test runs in every fast run.
- The env-file loader exists 15 times in JS and 7 in Python with different trimming/quoting; four scripts default
  Postgres binaries to `/Users/benbowlwes/textbrain/...` (`backup.py:28`, `restore-local.py:23`,
  `test-database.py:11`, `benchmark-library-query.py:26`); `reader-sweep.mjs:22` puts the owner's personal Gmail in a
  User-Agent where others use `hello@gradstep.ai`.

### D8. Browser/server logic duplicated by hand, already drifting — Medium-low · verified

- arXiv identity parser: `apps/web/src/lib/arxiv.ts:8-48` vs `_shared/arxiv.ts:21-56` (control-character set, ASCII
  check, default-port handling and byte-vs-character 128 limit differ).
- `lib/study.ts` ↔ `chat-study.ts`, `lib/figure-view.ts` ↔ `chat-figure-view.ts`, `lib/equation.ts` ↔
  `chat-equation.ts`, `visualDocument` in `ui/Diagram.tsx:6` ↔ `chat-visual.ts:118` (drifted colours/font despite
  "kept alike"). The browser already imports `_shared` modules (`tag-vocabulary`, `paper-search`, `source-metadata`).
- Consent versions are scattered (`chat.ts:28-39`, `chat-profiles.ts:31-32`, `openrouter-deepseek-pricing.ts:6`,
  a literal at `chat/index.ts:52`); the browser's `DEEPSEEK_CONSENT` is a stale `'cloud-ai-v4'`
  (`apps/web/src/lib/chat-profiles.ts:77`). Haiku rates live in three places (`openrouter-claude-pricing.ts:16`,
  `tags.ts:22`, the 089 SQL snapshot); `GET chat` still reports `tariff: TARIFF` (Anthropic list prices,
  `chat-profiles.ts:235`). Retry-After is parsed four ways. Credit-balance validation exists twice
  (`chat-session.ts:567-570` does not use `account-summary.ts:11 parseBalance`).
- Every Edge `index.ts` repeats the CORS/method/catch skeleton with inconsistent rate-limit codes (`rate_limited` vs
  `request_rate_limit`); admin errors skip `errorResponse` (no Retry-After); the store verifier adapters are copied
  between `store-sync/index.ts:36-50` and `app-store-notifications/index.ts:29-43`; two service-client factories
  differ in timeout (`backend.ts:11` 20 s, `pipeline-runtime.ts:15` 60 s). Misnamed modules: `anthropic.ts` is the
  pricing/hold engine, `admittedAnthropic` wraps OpenRouter, `pdf-upload.ts` is local-only; the comment at
  `provider-spending.ts:73-76` still says Claude is admitted as `anthropic`.

### D9. Deploy configuration drift — Low-medium · verified / uncertain

`feed-refresh` (live via pg_cron) is not in the routine deploy list (`infra/staging.json` `functions`), so shared
fixes such as de722cf's direct-model-host egress block never reach it. `supabase/config.toml` has no entries for
`add-paper`, `add-reference`, `upload-pdf` (gateway `verify_jwt=true`, unlike every other function — impact
uncertain). `config.toml` enables email signup but does not declare the before-user-created hook, which only
`scripts/configure-beta-admission.py` sets via the Management API; local stacks admit anyone and a
`supabase config push` could re-open signup *(uncertain)*.

### D10. Admin console misreports or truncates — Low-medium · verified / likely

Support lists only the latest 50 reports with no paging, offers no Close/Reopen although operators may set
`verified`, so the open count only grows (`apps/admin/src/main.tsx:85,257`). Accounts requests `p_limit: 500` and shows
no truncation notice (`accounts.tsx:29,85`); closed synthetic smoke-test accounts accumulate. Admin `rpc()` has no
timeout or size cap (`apps/admin/src/backend.ts:93`); missing messages for `account_disabled`, `invalid_observation`
make validation errors read "not confirmed, retry". `docs/architecture/ADMIN_HEALTH.md:36` still says "Not yet
deployed". An abandoned TOTP enrolment may block re-enrolment *(uncertain)*.

### D11. Small browser correctness and dead code — Low · verified

`ui/Catalogs.tsx:18` shows raw codes (`library_revision_conflict`, `item_unavailable`); `ui/Library.tsx:567-570`
assigns the catalog after a successful add and reports the whole add as failed if assignment throws, while
`useLibrary.ts:165` assigns before — and DOI/web papers never get a catalog key, despite "New papers go into the
catalog you're viewing"; `ui/Diagram.tsx:19` ignores the app's forced theme; `ui/Podcast.tsx:781`'s pre-quote privacy
line names "Anthropic"/"DeepSeek" and "Google" instead of OpenRouter routes (consent copy accuracy);
`lib/add.ts:3,41` still advertises `pdf_upload` (and opts into server `web_import`) *(server effect uncertain)*;
`lib/library-storage.ts` (336 lines) is deliberately not yet used by the UI; unused exports `isLocalPDF`,
`isJournalID`, `NOT_YET`, `FRAME_SCRIPT_HASH`, `FIGURE_PARTS_FORMAT`.

## E. Larger refactors to propose (not overnight)

### E1. Split the chat server and unify the OpenRouter adapters

`chat.ts` (1,295 lines) mixes validation, prompts, ingest, event types, orchestration, search rounds, ending policy,
quoting and settlement; `anthropic.ts` (573) is now the pricing/hold engine plus tool definitions under a dead
client's name. Proposed modules: `pricing.ts`, `chat-request.ts`, `chat-validate.ts`, `chat-prompts.ts`,
`chat-rounds.ts`, `chat-billing.ts`; one OpenRouter transport family for chat/script/speech with shared timeout,
retry, usage/receipt and generation-lookup handling. Do D1's deletions first.

### E2. Table-driven routes, models, tariffs and consent

Replace hard-coded provider/model allowlists, pricing snapshots and the 2027-01-01 literal in nine copies of
`worker_provider_attempt_begin` with one `provider_routes` table (model, endpoint, rates, valid-until) read by SQL and
generated into TS constants; a consent-version registry used by server and browser; rolling-window counters and a
retention policy for every lifetime-counted table (`provider_attempts`, `import_requests`). Fixes A2/A4 at the root
and stops one migration per model change.

### E3. Browser state architecture

Break up `Signed` (`App.tsx`) and `PaperReader` (`Reader.tsx:101-563`); external stores for activity, playback and
streaming text; memoized panes; a derived-state cache keyed by history version with an entity index in
`PrivateState`; split `chat-session.ts` (1,086 lines) into explainer requests (its `equation()` and `figure()` are
~80% the same, `:599-709`), draft checkpoints, answer runner and preferences; one capped reader-bundle cache instead
of four copies of insert-and-evict (`App.tsx:227,237,244`; `Reader.tsx:185`).

### E4. Shared core modules across browser, server and Swift fixtures

Import `_shared` study/figure-view/equation/visual/arXiv modules in the browser as it already does for tags and
paper search, or move them to a small `packages/core` with JSON fixtures that the Swift tests also consume. Removes
D8's drift class.

### E5. Spending resilience for a single upstream

Automatic reconciliation of non-exact OpenRouter attempts (A1/A6), per-feature keys with OpenRouter per-key limits,
route-scoped breakers (A13), and per-account testing caps (A9) — designed together in PROVIDER_SPENDING.md before
migrations, per the project rules.

### E6. Edge handler wrapper and operations hygiene

A shared `serve()` wrapper for CORS, method, auth, bounded bodies, error mapping and consistent rate-limit codes
(D8, A24); `scripts/lib/env.{mjs,py}`; an `archive/` folder for finished one-off scripts; periodic folding of
migration wrapper chains; the `test:ops` tier and widened fingerprint (D5).

---

## Checked and found sound

- **Grants and RLS.** Replaying all 93 migrations: none of the 320 final `public` functions is executable by `anon`;
  only `v*_` and `admin_catalog_promote` by `authenticated`; every `v*_admin_*`/`admin_*` is gated by
  `is_operator('owner')` (owner role plus MFA); every `worker_*` is service-role only; every SECURITY DEFINER function
  sets `search_path=''`; all tables live in unexposed `app_private` with RLS on and no policies (092 closed the last
  four).
- **Admission.** A client cannot admit itself; the hook is executable only by `supabase_auth_admin`.
- **Edge auth.** No function trusts a user id from the body; admin functions verify the caller's own token and
  owner/MFA before using the service role; operator secrets are compared in constant time; CORS refuses unknown
  origins and sends no credentials; no secrets or reader text appear in error responses or logs reviewed.
- **Browser security.** Every `postMessage` handler checks `event.source` (and the frame shim checks origin); the
  answer sanitizer is an allowlist over `markdown-it` with HTML off; keys and plaintext are not in local storage
  beyond the session token; the production CSP and deploy gates (`scripts/deploy-web.mjs`) are strict.
- **Admin builds.** Fixtures load only under `import.meta.env.DEV` and the deploy gate scans for fixture strings.
- **Billing core.** Reservation keeps a uniform budget → account → bucket lock order; the testing allowance cannot
  exceed the platform ceiling; OpenRouter costs are taken from the provider's reported `usage.cost` when present.

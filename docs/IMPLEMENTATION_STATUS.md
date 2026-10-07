# Implementation status

Updated 2026-10-06 (citations, archive, Tavily search; earlier: the 2026-10-05 overnight build). A development checkpoint, not a release declaration. Earlier
checkpoint prose (including the removed Linux executor work) is in git history before `e272037`.

## Works end to end on staging

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

**Web search: Tavily first, Anthropic's search as the backup** (owner decision 2026-10-06, migration 021): one rate
card whichever provider serves; Tavily's prepaid searches are a fixed commitment, not metered spend; a 31-day
allowance keeps within the plan. Live on staging: the same Related request cost $0.047 with Tavily against $0.111
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
dark, 390 px phone, dialogs). Not yet exercised against staging or with a real owner session.

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

**Web search in chat** is on in staging (owner decision 2026-10-05): up to three Anthropic searches per answer,
a consent line naming it, and tappable Sources under the answer that show the full address before opening Safari.
Verified live (searches charged at tokens + $0.01 each; the hold covers them) and by a Simulator UI test with the
chat fixture. The per-question hold is capped at the reader's balance once it is at least 50 credits.

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
nothing granted). **Not yet verified with a real sandbox purchase** (needs the subscriptions out of Missing Metadata; TestFlight
build 4 has the store). See [purchases](architecture/PURCHASES.md).

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

## Verified locally

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
capability and six-digit email-code settings configured (real provider sign-in still unverified).

## Spending (October 2026, staging)

Provider spend is capped by `platform_budgets` (October limit $9.80 after the first manual test).
Recorded 2026-10-05 23:10 PDT: $5.32 of provider spend for October (Mathpix for the real-paper conversions and
smoke tests, Anthropic for answers, Ingest, diagram and web-search tests, the web-import check), nothing reserved;
$4.48 left under the cap. On 2026-10-06 at 17:20 PDT the cap showed $6.56 spent. Fixed commitments (Supabase ≈ $35,
Tavily Project plan $30 from 2026-10-06) are recorded in [operations](architecture/OPERATIONS_AND_BILLING.md#fixed-commitments).
Run `python3 scripts/pipeline-ops.py status` or the admin Processing/Usage tabs for live numbers.

## Sign-in on TestFlight (owner report 2026-10-06)

Apple works. Google fails because the Google provider was never configured on staging (`external_google_enabled`
false, no client): the server answers "Unsupported provider". Email codes fail for any address without an account
because sign-up is closed (`signup_disabled`); the app showed "Sign-in isn’t available in this build" and now says
the email has no account (next build). Codes to the owner's existing account are accepted by the server; delivery
uses Resend's shared test sender, which delivers only to the Resend account's own address. The app has no password
sign-in (replaced by email codes on 2026-10-04); only the local admin site uses a password.
Update 22:20 PDT: codes now come from `codes@gradstep.ai` (verified domain) and reach any invited address.
Update 22:45 PDT: Google sign-in is configured: OAuth web client in Google Cloud project `gradstep` (Google Auth
Platform, External audience in testing mode, test users only; branding gradstep.ai and its privacy page), redirect
`https://coxhjvqpflgxkleydati.supabase.co/auth/v1/callback`; Supabase's Google provider enabled with it
(credentials kept in `.env.providers`). Authorize now redirects to Google; an on-device sign-in is still to be tried.

## Still required

- **Real sign-in**: Apple/Google provider journeys on a device; email codes need a verified Resend domain before
  testers other than the owner can receive them. Sign-up is invite-only. Simulator tests use a Debug-only
  synthetic-account hook.
- **Chat polish**: tables render as monospaced text; long papers raise the per-question hold (context is the
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
- **Operations**: hold-cleanup sweep for chat requests killed mid-stream, storage quotas/cleanup for
  paper assets, independent backups, admin hosting, production environment.
- **Purchases**: a real sandbox purchase end to end (Apple's online revocation check has not run in Edge yet);
  subscriptions in App Store Connect still show Missing Metadata; App Store Server API reconciliation and refund
  consumption answers need an In-App Purchase key (owner action); final review screenshots.
- **Product**: browser reader, accessibility pass on real papers, physical-device checks (paused by the owner).
- **Account deletion follow-ups before public release**: revoke the Sign in with Apple token on deletion,
  release a deleted account's App Store subscription binding, and expire deleted data from backups.
- **App Store listing**: final name and icon (the legacy artwork is a placeholder), privacy label from the
  manifest draft (email, user ID, other user content, customer support), screenshots.
- **Applied-but-unused**: migration 011's acquisition tables/RPCs remain in the database; a later additive
  migration can drop them.

# Implementation status

Updated 2026-10-05 (overnight build). A development checkpoint, not a release declaration. Earlier
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
| Full Simulator journey | `LiveJourneyTests` passed: synthetic sign-in + recovery code, add, convert, download, read offline, consent, paid streamed answer with typeset math, terminate/relaunch, reader and saved answer intact |

Also added overnight: **arXiv search** in the Library's arXiv segment (originals ranked first, Add stays in
search), a **research Feed** of the newest papers in the library's own arXiv categories (derived on device),
**native math in chat** (SwiftMath; headings, lists, code/tables), **live import progress** (bounded
polling while converting), and a **stale chat-hold sweep** (migration 015).

**Ingest** (the existing selection action) now works: the answer identifies the cited paper (using the
bibliography for in-text citations) and the server queues it through the user's own import after a strict
arXiv match. Verified on staging: a DPO passage citing "PPO; [39]" queued arXiv 1707.06347, and a repeat reported
it was already in the library. See [chat](architecture/CHAT.md#ingest-selection-action).

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

## Verified locally

- Database: full local PostgreSQL suite including `tests/database/test_pipeline.sql` (shared/private
  flows, reuse, credit holds and settlement, single submission grant, lost acknowledgements, operator
  resolution, withdrawn funders, fencing, permissions).
- Node: 132 backend tests (pipeline worker stages with fakes plus a real-render integration on retained
  DPO output, chat validation/pricing/settlement, renderer hostile-input and tamper checks, Mathpix,
  archive, arXiv).
- Swift: ScienceReaderCore package tests (155) and app unit tests (232); app builds for Simulator.

## Foundations from earlier checkpoints (still true)

Dedicated Supabase Pro organization with staging on Micro compute and database TLS enforced; production not
provisioned. Device-held encryption keys with recovery code, cross-runtime crypto envelopes, encrypted
SQLite journal, two-device hosted sync check, encrypted-history quotas. Screenshot feedback with private
support storage and MFA-gated admin dashboard (now including a pipeline/paid-attempt panel). Native Apple
capability and six-digit email-code settings configured (real provider sign-in still unverified).

## Spending (2026-10-04/05 overnight, staging)

Provider spend is capped by `platform_budgets` (October limit $9.80 after the first manual test).
Recorded by 2026-10-05 01:15 PDT: $1.50 of provider spend for October (about $0.69 Mathpix for seven
conversions, about $0.82 Anthropic for answers and Ingest tests), nothing reserved.
Run `python3 scripts/pipeline-ops.py status` or the admin Processing/Usage tabs for live numbers.

## Still required

- **Real sign-in**: Apple/Google provider journeys and email-code delivery (needs a dedicated SMTP sender);
  new signups are still disabled. Simulator tests use a Debug-only synthetic-account hook.
- **Chat polish**: tables render as monospaced text; long papers raise the per-question hold (context is the
  whole paper's MMD). Math that SwiftMath cannot parse is now rewritten first (0 of 904 real-paper equations
  fall back, from 57).
- **Search quality**: arXiv's API ranking is weak; a Semantic Scholar API key (owner action) would allow
  better relevance and citation-aware ranking.
- **Operations**: hold-cleanup sweep for chat requests killed mid-stream, storage quotas/cleanup for
  paper assets, independent backups, admin hosting, production environment.
- **Product**: StoreKit subscriptions and allowances, TestFlight, browser reader, iPad/accessibility passes
  on real papers, physical-device checks (paused by the owner).
- **Applied-but-unused**: migration 011's acquisition tables/RPCs remain in the database; a later additive
  migration can drop them.

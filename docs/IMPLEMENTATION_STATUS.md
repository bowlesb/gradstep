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

Design and failure handling: [paper pipeline](architecture/PAPER_PIPELINE.md), [chat](architecture/CHAT.md),
[reader renderer](architecture/READER_RENDERER.md). Migration `202610050014_paper_pipeline.sql` is applied
to staging (hash in the ledger; immutable from now on). Two independent adversarial reviews of the money and
concurrency design were completed and their findings fixed before it was applied.

## Verified locally

- Database: full local PostgreSQL suite including `tests/database/test_pipeline.sql` (shared/private
  flows, reuse, credit holds and settlement, single submission grant, lost acknowledgements, operator
  resolution, withdrawn funders, fencing, permissions).
- Node: 110 backend tests (pipeline worker stages with fakes plus a real-render integration on retained
  DPO output, chat validation/pricing/settlement, renderer hostile-input and tamper checks, Mathpix,
  archive, arXiv).
- Swift: ScienceReaderCore package tests (147) and app unit tests; app builds for Simulator.

## Foundations from earlier checkpoints (still true)

Dedicated Supabase Pro organization with staging on Micro compute and database TLS enforced; production not
provisioned. Device-held encryption keys with recovery code, cross-runtime crypto envelopes, encrypted
SQLite journal, two-device hosted sync check, encrypted-history quotas. Screenshot feedback with private
support storage and MFA-gated admin dashboard (now including a pipeline/paid-attempt panel). Native Apple
capability and six-digit email-code settings configured (real provider sign-in still unverified).

## Spending (2026-10-04/05 overnight, staging)

Provider spend is capped by `platform_budgets` (October limit $9.80 after the first manual test).
Recorded so far: Mathpix ~$0.40 (DPO twice incl. the spike, LoRA), Anthropic ~$0.40 (several answers).
Run `python3 scripts/pipeline-ops.py status` or the admin Processing/Usage tabs for live numbers.

## Still required

- **Real sign-in**: Apple/Google provider journeys and email-code delivery (needs a dedicated SMTP sender);
  new signups are still disabled. Simulator tests use a Debug-only synthetic-account hook.
- **Chat polish**: math in chat bubbles currently shows LaTeX source (`\(...\)`); rich math rendering,
  Markdown tables/code, and a long-paper context strategy (holds scale with paper length).
- **Operations**: hold-cleanup sweep for chat requests killed mid-stream, storage quotas/cleanup for
  paper assets, independent backups, admin hosting, production environment.
- **Product**: StoreKit subscriptions and allowances, TestFlight, browser reader, iPad/accessibility passes
  on real papers, physical-device checks (paused by the owner).
- **Applied-but-unused**: migration 011's acquisition tables/RPCs remain in the database; a later additive
  migration can drop them.

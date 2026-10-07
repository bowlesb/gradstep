# Science Reader agent handoff

Updated 2026-10-05 (after the owner's morning decisions). Continue from the verified state; read
[`AGENTS.md`](../AGENTS.md), [decisions](DECISIONS.md) and [implementation status](IMPLEMENTATION_STATUS.md)
first. The previous handoff (Linux executor plan) is obsolete and in git history before `e272037`.

## What exists

- **Server (Supabase staging `coxhjvqpflgxkleydati`)**: migrations 001–011 plus `014_paper_pipeline`,
  `015_stale_chat_holds`, `016_download_admission`, `017_account_deletion`, `018_app_store_purchases` and
  `019_web_import` applied (immutable). Edge functions:
  `paper-worker` (pipeline, cron every minute + import trigger via `pg_net`, plus the account-deletion sweep),
  `reader-artifact` (authorized reader download), `chat` (paid Claude Sonnet 5.5 answers, web search on in
  staging), `discover` (arXiv search), `support-assets` (screenshots), `account-delete`, `store-sync` and
  `app-store-notifications` (App Store purchases).
- **Auth**: email codes through Resend SMTP (`scripts/configure-email.py`, key in ignored `.env.providers`);
  sign-up invite-only.
- **Pipeline**: see [PAPER_PIPELINE.md](architecture/PAPER_PIPELINE.md). Shared CC BY/CC0 conversions are
  reused across accounts; other papers convert privately per account. Every credit hold has an exit.
  Two independent reviews' findings were fixed before 014 was applied.
- **Renderer**: [READER_RENDERER.md](architecture/READER_RENDERER.md) — MathML reader bundles rendered in
  Edge (`supabase/functions/_shared/reader/`).
- **App**: imports with live progress, arXiv search with Add, research Feed, automatic verified download into
  the encrypted offline store, streaming paid chat with consent, native math in chat (SwiftMath with a LaTeX
  normalizer), Ingest (adds the cited paper from arXiv or, for builds that send `capabilities: ["web_import"]`, a
  freely available PDF found through OpenAlex; library reads are v3, v2 hides web papers from older builds),
  Library List / Table (iPad ≥ 980 pt) / detailed rows with reading activity, a one-row search header,
  diagrams from answers (encrypted, drawn on device with bundled
  Mermaid), reader layout fixes for real papers (aligned derivations, pinned equation numbers, no sideways page
  scroll), credits in Settings, app icon (legacy artwork) and privacy manifest. Existing navigation is preserved;
  the compact tab bar now sits behind the software keyboard like a system tab bar. The live journey passes on
  iPhone and iPad Simulators; Release and Internal device builds compile (unsigned).
- **Account deletion**: Settings › Delete account… → `account-delete`; billing kept de-identified (owner decision).
  See [privacy and sync](architecture/PRIVACY_AND_SYNC.md).
- **Purchases**: [PURCHASES.md](architecture/PURCHASES.md); products created by `scripts/setup-store-products.mjs`
  (idempotent; also sets sandbox notifications to staging); `node scripts/smoke-store.mjs` checks the deployed functions.
- **TestFlight**: App Store Connect app "Gradstep" (renamed from "Paperstep" 2026-10-06), `scripts/upload-testflight.sh` with
  `BUILD_NUMBER=N` (ASC API key in ignored `.env.appstore` / `secrets/`), internal group "Owner".
- **Admin**: MFA dashboard with budgets, provider usage and a Processing tab (papers, paid attempts).

## How to verify / operate

```sh
npm test                                         # backend (Node type stripping)
python3 scripts/test-database.py                  # local PG18 cluster on 127.0.0.1:55431
swift test --package-path apps/apple/ScienceReaderCore
python3 scripts/deploy-staging.py staging [--skip-migrations] [--functions NAME ...]
python3 scripts/pipeline-ops.py status|budget --usd N|enable|disable|grant|resolve|kick
node scripts/smoke-pipeline.mjs [--arxiv=ID] [--question=...|none]   # API journey, small paid cost
node scripts/live-journey.mjs [--arxiv=ID --title=T --search=Q --question=...] [--device=SIM-ID]  # Simulator journey
node scripts/live-journey.mjs --delete            # in-app account deletion on staging, then server checks
node scripts/smoke-account-deletion.mjs           # API deletion check with real data (small paid cost)
BUILD_NUMBER=N scripts/upload-testflight.sh       # archive, sign, upload to TestFlight
node scripts/vendor-mermaid.mjs                   # re-vendor the hash-pinned Mermaid build into the app
TEST_RUNNER_SCIENCE_READER_AX_AUDIT=1 xcodebuild test … -only-testing:ScienceReaderUITests/WorkflowJourneyTests/testAccessibilityAuditOfMainScreens
```

If several rotation-based iPad UI tests fail together, reboot the iPad Simulator (`xcrun simctl shutdown/boot`)
before suspecting code; don't run `xcodegen generate` while a test run is using the project.

Function deploys occasionally fail with a Supabase-side HTTP 500; retry. The journey scripts create
synthetic `@example.invalid` accounts with operator credit grants and keep them for inspection
(`.artifacts/smoke-*.json`, `.artifacts/live-journey-*.json`; mode 0600).

## Money rules

The October platform budget is the hard provider cap (`pipeline-ops.py budget`). The owner set a
$10 cap for the 2026-10-04 overnight session; later caps are separate decisions. Never enable paid work
in production without the owner. Uncertain Mathpix submissions are never retried automatically —
reconcile with `pipeline-ops.py resolve ATTEMPT --job ID | --pages N`.

- **Design**: [DESIGN.md](DESIGN.md) (owner principles + pattern spec, shared code in `Views/DesignSystem.swift`);
  [design audit 1](design-audits/2026-10-06-audit1.md) applied. Visual checks: [VISUAL_CHECK.md](VISUAL_CHECK.md).
- **Session review**: [SESSION_REVIEW.md](SESSION_REVIEW.md) — the owner records sessions in Internal builds.

## Next priorities

1. Purchases: get the subscriptions out of Missing Metadata, upload a TestFlight build with the store, and verify a
   real sandbox purchase, renewal and refund on staging (watch `store-sync` logs for `verification_unavailable`).
2. Verified Resend domain so other testers receive email codes; owner to rotate the Resend key.
3. Account-deletion follow-ups before public release (Apple token revocation, subscription binding, backups).
4. Accessibility pass on real papers (VoiceOver over MathML, large text), iPad multitasking widths.
5. Cleanup of private originals that are never funded; drop the unused 011 acquisition tables in a later migration.
6. Browser reader (authorized by the owner after the iOS delivery; reuse `reader-bridge.js` layout logic).

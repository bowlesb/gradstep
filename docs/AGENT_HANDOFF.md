# Science Reader agent handoff

Updated 2026-10-05 (overnight build, second half). Continue from the verified state; read
[`AGENTS.md`](../AGENTS.md), [decisions](DECISIONS.md) and [implementation status](IMPLEMENTATION_STATUS.md)
first. The previous handoff (Linux executor plan) is obsolete and in git history before `e272037`.

## What exists

- **Server (Supabase staging `coxhjvqpflgxkleydati`)**: migrations 001–011 plus `014_paper_pipeline`,
  `015_stale_chat_holds` and `016_download_admission` applied (immutable). Edge functions: `paper-worker` (pipeline, cron every
  minute + import trigger via `pg_net`), `reader-artifact` (authorized reader download), `chat` (paid
  Claude Sonnet 5.5 answers), `discover` (arXiv search), `support-assets` (screenshots).
- **Pipeline**: see [PAPER_PIPELINE.md](architecture/PAPER_PIPELINE.md). Shared CC BY/CC0 conversions are
  reused across accounts; other papers convert privately per account. Every credit hold has an exit.
  Two independent reviews' findings were fixed before 014 was applied.
- **Renderer**: [READER_RENDERER.md](architecture/READER_RENDERER.md) — MathML reader bundles rendered in
  Edge (`supabase/functions/_shared/reader/`).
- **App**: imports with live progress, arXiv search with Add, research Feed, automatic verified download into
  the encrypted offline store, streaming paid chat with consent, native math in chat (SwiftMath with a LaTeX
  normalizer), Ingest (adds the cited arXiv paper), diagrams from answers (encrypted, drawn on device with bundled
  Mermaid), reader layout fixes for real papers (aligned derivations, pinned equation numbers, no sideways page
  scroll), credits in Settings. Existing navigation is preserved. The live journey passes on iPhone and iPad
  Simulators.
- **Admin**: MFA dashboard with budgets, provider usage and a Processing tab (papers, paid attempts).

## How to verify / operate

```sh
npm test                                         # backend (Node type stripping)
python3 scripts/test-database.py                  # local PG18 cluster on 127.0.0.1:55431
swift test --package-path apps/apple/ScienceReaderCore
python3 scripts/deploy-staging.py staging [--skip-migrations] [--functions NAME ...]
python3 scripts/pipeline-ops.py status|budget --usd N|enable|disable|grant|resolve|kick
node scripts/smoke-pipeline.mjs [--arxiv=ID] [--question=...|none]   # API journey, small paid cost
node scripts/live-journey.mjs [--arxiv=ID --title=T --search=Q --question=...]  # Simulator journey
```

Function deploys occasionally fail with a Supabase-side HTTP 500; retry. The journey scripts create
synthetic `@example.invalid` accounts with operator credit grants and keep them for inspection
(`.artifacts/smoke-*.json`, `.artifacts/live-journey-*.json`; mode 0600).

## Money rules

The October platform budget is the hard provider cap (`pipeline-ops.py budget`). The owner set a
$10 cap for the 2026-10-04 overnight session; later caps are separate decisions. Never enable paid work
in production without the owner. Uncertain Mathpix submissions are never retried automatically —
reconcile with `pipeline-ops.py resolve ATTEMPT --job ID | --pages N`.

## Next priorities

1. Real sign-in on the dedicated registrations (Apple first), SMTP sender for email codes, beta signups.
2. TestFlight build (app record, signing, StoreKit products and allowances decision).
3. Account deletion (App Store requirement before public release; needs a retention decision for billing records).
4. Accessibility pass on real papers (VoiceOver over MathML, large text), iPad multitasking widths.
5. Cleanup of private originals that are never funded; drop the unused 011 acquisition tables in a later migration.
6. Browser reader (authorized by the owner after the iOS delivery; reuse `reader-bridge.js` layout logic).

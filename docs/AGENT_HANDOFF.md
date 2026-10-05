# Science Reader agent handoff

Updated 2026-10-05 after the first overnight build by a new agent. Continue from the verified state; read
[`AGENTS.md`](../AGENTS.md), [decisions](DECISIONS.md) and [implementation status](IMPLEMENTATION_STATUS.md)
first. The previous handoff (Linux executor plan) is obsolete and in git history before `e272037`.

## What exists

- **Server (Supabase staging `coxhjvqpflgxkleydati`)**: migrations 001–011 plus `014_paper_pipeline`
  and `015_stale_chat_holds` applied (immutable). Edge functions: `paper-worker` (pipeline, cron every
  minute + import trigger via `pg_net`), `reader-artifact` (authorized reader download), `chat` (paid
  Claude Sonnet 5.5 answers), `discover` (arXiv search), `support-assets` (screenshots).
- **Pipeline**: see [PAPER_PIPELINE.md](architecture/PAPER_PIPELINE.md). Shared CC BY/CC0 conversions are
  reused across accounts; other papers convert privately per account. Every credit hold has an exit.
  Two independent reviews' findings were fixed before 014 was applied.
- **Renderer**: [READER_RENDERER.md](architecture/READER_RENDERER.md) — MathML reader bundles rendered in
  Edge (`supabase/functions/_shared/reader/`).
- **App**: imports with live progress, arXiv search with Add, automatic verified download into the
  encrypted offline store, streaming paid chat with consent, native math in chat (SwiftMath), credits
  in Settings. Existing navigation is preserved.
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
3. Reader polish on real papers (tables, long equations, figures), iPad journeys, accessibility pass.
4. Paper-asset storage quotas/cleanup; drop the unused 011 acquisition tables in a later migration.
5. Browser reader (authorized by the owner after iOS).

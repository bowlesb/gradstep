# Science Reader

Native iPhone/iPad research-paper reader with Supabase, reusable article conversions, private user libraries, metered AI, and an operator dashboard.

Public name: **Gradstep**. Current direction, 2026-10-13: official arXiv HTML feeds the existing structured reader;
every PDF is downloaded and processed only on the user's device. A future local model handles challenging PDFs,
with no Mathpix fallback. See the [HTML-first architecture](docs/architecture/HTML_FIRST_READER.md).
The HTML-first backend and browser are deployed on staging; native build 30 is valid and available for internal iOS and Mac testing. Historical server copies remain retained. The [implementation status](docs/IMPLEMENTATION_STATUS.md) records the latest verified releases and the
remaining work. The [paper pipeline](docs/architecture/PAPER_PIPELINE.md) describes the historical server flow.

## Start here

- [Agent takeover handoff](docs/AGENT_HANDOFF.md)
- [Decisions and outstanding questions](docs/DECISIONS.md)
- [arXiv HTML bundles and device-only PDFs](docs/architecture/HTML_FIRST_READER.md)
- [Data model and invariants](docs/architecture/DATA_MODEL.md)
- [Privacy, key custody, and synchronization](docs/architecture/PRIVACY_AND_SYNC.md)
- [Encrypted wire contract](docs/architecture/ENCRYPTED_WIRE_FORMAT.md)
- [Backup and restore contract](docs/architecture/BACKUP_AND_RESTORE.md)
- [Infrastructure, billing, and recovery](docs/architecture/OPERATIONS_AND_BILLING.md)
- [Internal testing and feedback](docs/TESTING_FEEDBACK.md)
- [Existing UX to preserve](docs/UX_PARITY.md)
- [Implementation sequence and acceptance evidence](docs/IMPLEMENTATION_PLAN.md)

`reference/web/` is a local archival source copy from the permitted NAS folder. It is evidence for interaction behavior and processing logic, not a production backend. Its older operational instructions do not authorize any NAS writes. Live credentials, databases, uploaded papers, build output, and dependencies were excluded from the copy. See [snapshot metadata](reference/snapshot-metadata.json).

The listed tests provide evidence for specific behaviors. They do not establish complete feature delivery or replace an independent security review.

## Development checks

Use Node 24+, Xcode 26.4, Swift 6, and PostgreSQL client tools 18. Set `SCIENCE_READER_PG_BIN` to your PostgreSQL tool directory when it differs from the local development default. Local database checks require this project's disposable cluster on `127.0.0.1:55431`; they refuse hosted targets. Backup tooling additionally uses `age` and `requirements-ops.txt` in a Python virtual environment.

```sh
npm ci
npm ci --prefix apps/web
npm test
npm run build:admin
```

`npm test` is the **fast** default (backend + browser units and compiler freshness, about 10 seconds locally).
Browser journeys, real-paper/PDF corpora, Simulator, database and hosted checks are **slow / opt-in**. Run them once
for a baseline and selectively for related changes or reported issues; do not repeat them for unrelated edits.
See [testing commands and saved evidence](docs/TESTING.md). `npm run test:status` shows previous run results.

Hosted checks in `scripts/check-staging.py`, `check-support.mjs`, `check-native-support.mjs`, and `check-backup.mjs` create narrowly scoped synthetic staging data and remove it afterward. They do not send email or invoke paid providers. The browser support check expects the local admin server. Native tests use a signed simulator build (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) so they exercise the protected Keychain path. Physical-device file-protection checks are explicitly skipped in Simulator.

Staging operations: `python3 scripts/deploy-staging.py staging` (migrations, bucket, secrets, functions, schedule), `python3 scripts/pipeline-ops.py status|budget|enable|disable|grant|resolve|kick`, `node scripts/smoke-pipeline.mjs` (API journey) and `node scripts/live-journey.mjs` (Simulator journey). The latter two create synthetic `@example.invalid` accounts and incur small, budget-capped provider costs.

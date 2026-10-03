# Science Reader

Native iPhone/iPad research-paper reader with Supabase, reusable article conversions, private user libraries, metered AI, and an operator dashboard.

Status, 2026-10-03: foundation implementation. Dedicated Supabase staging is live on Pro/Micro with database TLS enforced; production is not provisioned. Isolation, concurrency, credits, support, key rotation, and hosted Auth/RPC checks pass. Native encrypted SQLite storage, cross-runtime crypto envelopes, conversation branches, screenshot feedback, and account boundaries have running tests. The admin dashboard and authenticated screenshot/reply workflow pass browser tests. A signed encrypted database/object backup restores into a local quarantine. Provider ingestion/chat, subscription integration, independent backup hosting, admin hosting, and TestFlight delivery are still in progress. See [implementation evidence](docs/IMPLEMENTATION_STATUS.md). The public name is being considered separately from the stable internal project/protocol names.

## Start here

- [Decisions and outstanding questions](docs/DECISIONS.md)
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
npm test
npm run build:admin
npm run test:database
swift test --package-path apps/apple/ScienceReaderCore
node scripts/check-wire.mjs
```

Hosted checks in `scripts/check-staging.py`, `check-support.mjs`, `check-native-support.mjs`, and `check-backup.mjs` create narrowly scoped synthetic staging data and remove it afterward. They do not send email or invoke paid providers. The browser support check expects the local admin server. Native tests use a signed simulator build (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) so they exercise the protected Keychain path. Physical-device file-protection checks are explicitly skipped in Simulator.

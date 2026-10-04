# Infrastructure, spending, and recovery

Status: implementation underway; product decisions approved. The separate Science Reader organization is Pro, staging is healthy on Micro in US West (Oregon), and migrations 001–011 are applied and immutable. Private support storage, encrypted-history capacity limits, and library/import/acquisition SQL contracts are deployed and tested. Metadata, original acquisition, verification, and original reads remain disabled; no runtime acquisition is deployed. Production, provider processing, independent backups, and distribution remain in progress.

## Environments and deployment

- Create dedicated Science Reader staging and production Supabase projects with separate auth configuration, buckets, secrets, jobs, entitlements, and budget counters. Prefer the same supported region for both, initially US West near the owner, subject to actual availability and audience/data requirements.
- TestFlight initially uses staging with Apple sandbox purchases. Production preparation must not copy staging users or synthetic entitlements. The build identifies its environment visibly to testers.
- Use Supabase Auth, Postgres, private Storage, bounded Edge Functions, durable Queues, and scheduled reconciliation. Separate API ingress from work execution. Queue payloads contain identifiers and approved work options, not private plaintext conversations.
- A managed worker outside Edge Functions is a contingency for demonstrated CPU/memory/runtime needs. Select it using measured workloads and the approved budget. Do not put an infinite polling process inside one Edge invocation or use the NAS as a production dependency. [Supabase runtime limits](https://supabase.com/docs/guides/functions/limits)
- Recommended admin hosting is a static React application on managed static hosting, backed by authenticated Supabase APIs. Cloudflare Pages is a candidate; account access, domain, and final cost are not yet verified. No server secrets belong in the bundle. [Cloudflare Pages limits](https://developers.cloudflare.com/pages/platform/limits/)
- Backend schema, functions, roles/grants, buckets, cron/queue configuration, and environment-specific nonsecret settings are versioned. Use the same reviewed migrations in staging and production. No first-request schema creation or undocumented dashboard fixes.
- Apply least-privilege service identities. Provider, Apple signing, database, and management credentials are distinct. Establish dedicated Science Reader provider keys/workspaces so monitoring or limits cannot interrupt TextBrain.

## Acquisition staging checkpoint — 011

On 2026-10-03, reviewed migration 011 was applied with SHA-256 `30c2db5b6d1211dac4ccbbd93b732fb747a6dddcb06ceefc9970ba3bc3a09f03` (commit `a33f807`); the authoritative `science_reader_migrations.versions` prefix was verified. The pre-011 encrypted backup restored all 92 tables and the applied ledger locally before deployment. Hosted evidence is in `.artifacts/acquisition-011/hosted-migration.log` and `hosted-contract.log`: real Auth/REST isolation checks and rolled-back metadata/source-only/cancel/replay fixtures pass, and the tagged account was removed. These checks made no arXiv, Storage, verifier, or paid-provider call.

`metadata_enabled`, `original_enabled`, `verification_enabled`, and `paper_read_policy.enabled` are false. The active verification profile is null, the profile table is empty, and the narrow verifier role has no login/credential. Atomic source claim+permit admission and its quotas are installed; no acquisition ingress, schedule or live transport is deployed. The pure metadata runner passes 19 focused cases and the 56-test backend suite, using mocked transports (`.artifacts/acquisition-runner-backend-suite.log`).

Internal beta defaults include 1,000 source requests/day, 1 GiB/month source-byte admission, 512 MiB/2,000 retained-or-reserved original objects, four active reservations, and a 5 MiB/50-page pilot profile ceiling. Worker reads and customer reads each have a 2 GiB/environment/month limit; customer reads additionally cap at 256 MiB/account/month. Control records, receipts and read grants have separate bounds in [ACQUISITION.md](ACQUISITION.md). These are installed safeguards, not measured invoice ceilings or paid-plan allowances. PDF execution admission, global connection lifetime, storage/read adapters, runtime reconciliation and independent backup operations must pass before enabling the corresponding path. Mathpix authorization/processing stays separate and disabled.

## $100 private-beta operating budget

Planning allocation, not vendor quotes:

| Category | Maximum allocation |
|---|---:|
| Fixed hosting, database projects, storage/backup commitments | $50/month |
| AI, OCR, external search, and other controllable metered operations | $30/month |
| Contingency and unavoidable metered overhead | $20/month |
| Total incremental operating budget | $100/month |

Before provisioning, inspect current organization billing and compute costs, then record the actual incremental commitments. A Supabase Pro organization starts at $25/month and additional Micro projects start at $10/month; these are not necessarily the incremental charges in the existing organization. [Supabase pricing](https://supabase.com/pricing)

If a worker or backup arrangement cannot fit, change the proposed allocation or service selection before purchase. Do not treat unused contingency as an automatic recurring upgrade. Alerts use incurred costs plus outstanding reservations and forecast fixed costs. Pause new discretionary provider work before exhausting its allocation. Apply provider-side hard limits where supported and reconcile delayed provider invoices. This is a controlled budget, not a guarantee that every vendor's delayed invoice can be stopped at precisely $100.

## Credit and cost accounting

Maintain distinct units:

1. Customer credits: a published, versioned allowance/rate system.
2. Provider usage: input/output/cache token counts, OCR pages, search operations, model, and provider IDs.
3. Provider expense: measured/estimated USD cost using the applicable pricing version, later reconciled to provider records.
4. Service spend reservations: committed worst-case in-flight costs, including owner/admin work and background maintenance.

Reserve both customer credits and service spending before any paid call. Commit under database locks so concurrent calls cannot all pass a stale balance check. Reservations belong to a stable operation ID; exact retries return the same operation. Bound inputs, outputs, tool iterations, search depth, pages, concurrency, and retry policy. Each tool step must fit within the existing authorized envelope or obtain another reservation before it runs.

Settle actual consumption with an immutable ledger entry and release unused allowance in one transaction. An expired client request does not automatically release a reservation while a provider job is still running. Reconciliation determines whether work completed, failed, or remains uncertain. A provider error may still incur cost; customer refunds and provider expenses are recorded independently.

A job claim and a money reservation must be coordinated. Enqueue via a transactional outbox or a queue write in the same database transaction. Failed/duplicate publication cannot create unreserved paid jobs. A retry is not authorized to spend merely because the original job once passed a budget check.

Record costs for metadata extraction, search, diagram generation, OCR, and retries as well as visible chat turns. No direct provider keys in apps or the admin browser. If the balance service is unavailable, new paid work stops while ordinary local reading continues.

Credit operations include grants, holds, captures, releases, refunds, adjustments, and entitlement-related corrections. Each admin adjustment records actor, reason, delta, and affected operation. The dashboard can reconstruct a balance from the ledger and compare it with materialized counters.

## Shared conversions and fair attribution

Proposed v1 rule: an already-ready shared conversion consumes no OCR credits. The requester who authorizes a new conversion funds that operation once, within a displayed maximum; other concurrent requesters attach as waiters without another OCR charge. Catalog preloading requested by the owner charges the platform budget, not an arbitrary customer.

Use atomic work-key claims so two users cannot both fund/submit the same shared conversion. Release losing reservations. Once work is submitted, one waiter leaving does not destroy a result others need. Record actual conversion costs separately from estimated avoided costs. Report reuse across distinct users as well as ordinary repeated reads so the savings metric is interpretable.

If this funding rule proves confusing in the benchmark, propose a platform-funded shared conversion allowance with per-user new-page quotas before publishing the rate card. Do not silently change the rule after charging subscribers.

### Import cancellation and retry — installed account contract, pending paid workflow

Migrations 010/011 install durable account import/membership commands, replay/removal fences, bounded acquisition claims, and separate account projections; hosted contract checks pass. The [data contract](DATA_MODEL.md) and [acquisition contract](ACQUISITION.md) separate account intent from shared work. The funding/submission behaviors below remain requirements for the future paid-processing implementation; they are not established by a source-only database fixture. Migrations 001–011 are immutable. Review additive paid authorization, attempt identity, lock order, quotas and recovery before any provider traffic.

A quote binds verified page count, document/options, rate version, credit ceiling, service spend ceiling, and expiry. Record the user's authorization before a new paid operation is reserved. Final authorization rechecks current cache/work state atomically: an already-ready result or concurrent existing job cannot create another OCR charge. Display saved/imported membership separately from readable/artifact-ready status.

| Situation | Durable behavior and cost rule |
|---|---|
| Ready eligible exact-byte conversion | Attach account membership to the compatible verified artifact; no OCR reservation |
| Existing active shared conversion | Attach an account request as a waiter; no second funding operation or paid submission |
| New conversion | Atomically choose the consenting funding requester, reserve both balances, and enqueue durable work |
| Waiter cancels/removes | Detach its interest and preserve its later membership revision; do not cancel another account's work |
| Funding requester cancels before submission | Serialize cancellation against submission, release its unspent hold, and pause unsubmitted work; if waiters remain, require fresh funding authorization before continuing |
| Cancellation/removal after submission | Keep cost reconciliation and shared result collection alive; disclose that removing a paper does not prove provider cancellation or eliminate incurred cost |
| Submission outcome uncertain | Keep the reservation and quarantine; reconcile provider identity before any further submission |
| Download, metadata, or rendering failure | Resume only the failed stage from verified durable inputs; metadata/render retries cannot rerun OCR |
| Terminal OCR failure/cancellation | Explicit retry transition with a new attempt identity; reconcile/settle the prior operation, and obtain fresh authorization/reservation if another paid submission is required |

An exact request replay returns its current state. It must not recreate removed membership or turn a terminal job into a new paid attempt. Late workers are fenced by both job lease and import/membership revision. Define attempt-to-operation relationships before schema changes: the current one-job/one-operation representation cannot by itself express every terminal retry or replacement funding case.

Search, feed refresh, metadata classification, downloads, and paper assets need their own rate, storage/egress, concurrency, and retention limits. Cache eligible public metadata; coalesce equivalent refreshes and bound provider retries. A user refresh does not bypass global limits. Report actual last successful refresh and partial-source failures. Classification uses source/version/input/classifier identity and a separate budgeted operation; it is not an unmetered tail of every OCR request.

### Discovery and import failure schedules required

The combined live discovery/paid/rendering schedules below remain release obligations. Local and hosted 010/011 fixtures already cover their database membership, replay, cancellation, quota and source-only portions; they do not establish paid-provider or end-to-end acquisition behavior. Use deterministic provider/network stubs first; run the same observable contract fixtures against native and browser clients. Record workflow screenshots, transition outcomes, timings, and credit/submission counts without logging private content.

- Double-add, add from two devices, and simultaneous adds by two accounts: one eligible OCR submission, one funding operation, no duplicate account membership.
- Resolve arXiv/DOI aliases to equal bytes, then use a different revision or annotated PDF: reuse only the authorized exact file.
- Restart during upload, download, submission, collection, and classification: resume the checkpoint without losing the row or repeating paid work.
- Remove/cancel, then deliver earlier add/worker responses: membership stays removed. Explicitly add again: one deliberate restoration.
- Cancel the funding requester while waiters remain, including a race with submission: no silent charge transfer, premature release, or unreserved submission.
- Time out after provider acceptance without returning its ID: quarantine; repeated refresh/retry cannot resubmit. Restore from backup with the same ambiguity and reconcile before resuming work.
- Fail topic generation or rendering after successful OCR: preserve the readable/verified work that exists and retry only the failed stage. A missing asset/checksum prevents an offline-ready claim.
- Search A then B, switch source/account, and deliver responses out of order: only current results apply. Preserve cached results when a source fails; distinguish partial results from no matches.
- Page more than 500 papers with equal sort values and concurrent adds/removals: deterministic continuation and reconciliation lose no membership and display no duplicates.
- Concurrent encrypted tag add/remove/rename on two devices, including an older client: follow the documented merge and compatibility rules without exposing labels or discarding pending events.

Exercise optional/long metadata, missing PDFs, slow/offline networks, quota exhaustion, accessibility text sizes, and browser keyboard navigation at the transitions above. Adding from discovery must leave existing reading usable, preserve query/scroll state, and show durable progress beside the library. A visual walkthrough complements assertions; it is not proof of billing or restart correctness.

## Subscription lifecycle

Use StoreKit subscriptions with server verification of signed transactions and Apple server notifications. Validate bundle/app identity, environment, ownership mapping, expiration, revocation/refund state, and signed data. Never accept a client-written `is_pro` or balance.

Build for duplicate and delayed notifications, upgrades/downgrades, cancellation at period end, billing retry/grace, refunds, reinstatement, and purchase restoration. Derive entitlements from verified state, not notification arrival order. Reconcile periodically against the provider when events are missed. Bind each original transaction to one app account; account reassignment is an audited support operation.

Give subscription allowance periods stable identities and use UTC boundaries with documented anniversary/calendar rules. Annual subscriptions granting monthly allowances require idempotent monthly issuance. A refund may revoke future spending or require a compensating adjustment; it cannot rewrite past provider expense.

Benchmark Standard/Pro at the approved provisional price points using actual ML-paper workloads. Set allowances after app-store fees, OCR/search/AI costs, storage, and retry overhead. Separately purchased credit packs, if offered, do not expire. Keep them distinguishable from subscription-period service allowances and validate the published terms against Apple's rules. [Apple purchase guidelines](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase)

## Abuse and cost containment

- Verified account and entitlement for new paid work; bounded trial grants; global caps remain effective even across many accounts.
- Rate and concurrency limits on expensive calls, imports, metadata mutations, storage uploads, signed downloads, and report attachments.
- Server-validated PDF type, byte/page limits, archive expansion limits, HTTPS source allowlists/policies, and redirect/DNS checks. Never carry the NAS app's arbitrary server-local file ingestion into production.
- No automatic full-paper conversion merely because a discovery feed found an article.
- Cache eligible public metadata and paper context; avoid repeated OCR during renderer-only fixes.
- Bound hosted storage/egress independently of AI credits. Observe quotas and error states before accepting uploads the system cannot retain.
- Admin/tester traffic remains visible and included in global cost caps; development does not use an unlimited billing bypass.

## Migrations and client compatibility

### Encrypted-history capacity and transfer contract

Migration 009 extends the existing request-rate system. These are internal beta safety limits, not finalized paid-plan allowances: at most 64 MiB of event ciphertext and 100,000 events per account; 512 MiB and 500,000 events across an environment. Track ciphertext bytes and row counts separately, because many tiny events still consume indexes and database overhead. Materialized usage is derived from the immutable event rows, changes in the same transaction, and can be reconstructed. Exact replay consumes no additional storage. A rejected append must not consume a cursor or discard a local outbox entry. Explicit account cleanup releases storage; ordinary tombstones retain their encrypted history and do not pretend to free bytes.

Before installing accounting triggers, lock event writes and backfill both account and environment totals in the migration transaction. Preserve existing data even if a newly configured limit is already exceeded; reject new growth until resolved. Lock order for new writes is request window, account keyring, environment storage counter, account storage counter. Future deletion jobs must acquire the keyring before deleting event rows. Client roles have no counter or policy write access. Provider credits do not bypass these limits, and these quotas do not replace separate paper/support/key-material limits.

Cap encrypted-history download content at 512 MiB/account/month and 10 GiB/environment/month (UTC), reserving measured JSON bytes plus 1 KiB/request overhead transactionally before returning a successful result. These conservative application counters are not a claim to meter every byte on the Supabase invoice. Read/write request windows also apply: 1,000 successful requests/account/hour and 10,000/environment/hour per route. Failed transactions roll back counters; gateway-level denial-of-service protection remains separate. The existing maintenance routine prunes old request windows, and `worker_prune_sync_usage` retains the current and two prior transfer periods for reconciliation. Scheduling these routines remains a beta release gate. The environment aggregate continues to include traffic from subsequently deleted accounts.

The new `v2_pull_events` returns `events`, `next_cursor`, and `has_more`, with at most 200 events and 1 MiB of JSON per response. Select the page and continuation from one database snapshot. The client follows `has_more`, not a short event count: large encrypted events can fill a byte-bounded page early. The format of an individual encrypted event does not change. `v1_pull_events` remains valid for a complete count-bounded page that fits; it returns an explicit update-required error if byte truncation would make an older client mistake the page for the end of history. This is essential before rebasing unpublished events after rotation. Deploy the server contract before switching the native client; no public builds currently depend on v1.

Keep usage reads and key recovery available when the history transfer budget is exhausted. Exhaustion pauses cloud history writes/downloads with a clear local-save status; it never resets encryption keys, deletes history, or silently purchases capacity. Add the storage/transfer totals to the MFA-protected admin overview. Remaining quotas for key management and all other data-bearing APIs must be completed before beta access is opened.

Each migration specifies forward behavior, old-client behavior, lock/backfill impact, and rollback/roll-forward recovery. Use expand/backfill/contract where appropriate. Deploy readers compatible with both formats before switching writers, and retain the old read path until its support window is explicitly closed.

Wire protocol, encrypted payload, database migration, renderer, and pricing versions are separate. Do not overload an app build number to represent all of them. Never introduce a plaintext compatibility path for encrypted history. Devices returning from a long offline period either resynchronize safely or receive an explicit update/recovery path without losing their local outbox.

Run migrations from a clean database and from the prior released schema. Test RLS/grants under real anon/authenticated/operator roles, not only with a service role. Use provider stubs and Apple sandbox scenarios before limited, metered live checks. Destructive changes require a concrete restore/roll-forward plan and suitable authorization; the clean initial database does not make future customer data disposable.

## Backups and restore

The pre-011 encrypted checkpoint restored 92 tables locally before application. The post-011 checkpoint `.artifacts/backups/20261004T000013Z-52920c7237a9` exported 798,108 database bytes and zero verified objects; local quarantine restore recovered 112 tables, the applied ledger and zero objects in 1.44 seconds. Reports are `.artifacts/post-acquisition-backup.json` and `post-acquisition-restore.json`. Neither local drill establishes hosted Auth/MFA disaster recovery, an independent off-site destination, or the target recovery SLA.

Supabase database backups include object metadata, not Storage file bytes. Back up originals, converted bundles, private ciphertext blobs, and support attachments according to their lifecycles as well as Postgres. Keep a checksummed manifest for a restorable checkpoint and use an independent backup destination within budget. The destination and credentials must be selected before real beta data is accepted. [Supabase backup scope](https://supabase.com/docs/guides/platform/backups)

Proposed beta recovery objectives: no more than 24 hours of server-side loss and restoration within one working day. These are targets until a timed restore drill passes, not an SLA. Client outboxes may reduce loss but are not a server backup.

An encrypted chat backup remains encrypted and requires the user's keys. A restore must preserve event identities, account mapping, key epochs, billing idempotency keys, and deletion records. Resume processing only after reconciling outstanding provider jobs and reservations; restoring old `queued` rows must not rebill completed OCR or mint duplicate subscription credits.

Before TestFlight use with real data, perform a restore into a separate environment and verify files/checksums, document rendering, encrypted-history recovery, deletion behavior, and spending reconciliation. Record retention, scheduled cleanup, backup expiry, and operator procedure. Never claim account deletion instantly removes data from all backups.

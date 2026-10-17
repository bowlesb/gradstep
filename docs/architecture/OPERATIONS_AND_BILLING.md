# Infrastructure, spending, and recovery

> **Historical audit, 2026-10-07:** The independent [credits, identity and cost audit](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md) found unreserved Tavily lookup paths, hidden SDK retries, uncertain Mathpix liability and storage/delivery gaps in that deployment. The audit itself deployed no fixes. Subsequent staging migrations 034–039 and provider/worker controls are deployed; use [Spending controls](SPENDING_CONTROLS.md) and [asset accounting](ASSET_SPENDING.md) for the current safeguards and remaining boundaries. The provider ledger is not a complete infrastructure invoice cap. Statements below about disabled acquisition gates and the 5 MiB/50-page pilot describe the superseded 011 design.

Status: implementation underway; see [current implementation evidence](../IMPLEMENTATION_STATUS.md) for staging and client milestones. Applied migrations are immutable. The 011 acquisition checkpoint below is historical; it does not describe the currently running paid pipeline. Production and independent backup operations remain unfinished.

## Environments and deployment

- Create dedicated Science Reader staging and production Supabase projects with separate auth configuration, buckets, secrets, jobs, entitlements, and budget counters. Prefer the same supported region for both, initially US West near the owner, subject to actual availability and audience/data requirements.
- TestFlight initially uses staging with Apple sandbox purchases. Production preparation must not copy staging users or synthetic entitlements. The build identifies its environment visibly to testers.
- Use Supabase Auth, Postgres, private Storage, bounded Edge Functions, durable Queues, and scheduled reconciliation. Separate API ingress from work execution. Queue payloads contain identifiers and approved work options, not private plaintext conversations.
- The pipeline now runs on Cloud Run; review its billing mode and scheduling together against the approved budget (see below). Do not use the NAS as a production dependency. [Pipeline reliability](PIPELINE_RELIABILITY.md).
- Static React clients use Cloudflare hosting, backed by authenticated Supabase APIs. The admin is live at `https://admin.gradstep.ai` on its own static Pages project; real owner MFA acceptance remains pending. No server secrets belong in the bundle. [Admin hosting evidence](ADMIN_HOSTING.md), [browser deployment status](BROWSER_READER.md#where-it-lives).
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

### Fixed commitments and observed usage — updated 2026-10-08 UTC

The incremental beta budget stays **$100/month**, excluding existing TextBrain costs. Read-only evidence at
**2026-10-08 09:08:20 UTC** records the October provider ledger at **$14.017212 spent, $0 reserved, $25 limit**,
with zero recorded unresolved provider attempts and no cost observations entered. These are point-in-time ledger
values, not reconciled invoices or a cap on all infrastructure charges. The controls in
[Spending controls](SPENDING_CONTROLS.md) are deployed; no new allowance or subscription increase is authorized here.
Evidence: `.artifacts/takeover-20261008/spend-current-readback.json`.

| Commitment | Since | Monthly | Evidence and limits |
|---|---|---:|---|
| Supabase staging, Micro | 2026-10-02 | $0.01344/hour gross compute (about $10/month); net incremental bill unverified | Read-only Management API confirms Pro organization and Micro as the only selected project addon. Attribute actual organization compute credits/invoice and exclude TextBrain; do not automatically charge the entire organization subscription to this product |
| Tavily Project, 4,000 search credits | 2026-10-06 | $30 | Owner supplied the paid October 6 invoice and November 6 renewal for November 6–December 6. Owner confirmed turning pay-as-you-go **off** on October 7 |
| gradstep.ai (2 years, $179.96) and gradstep.shop (1 year, $0.98 + $0.20 fee), Namecheap | 2026-10-06 | ≈ $7.60 amortized | One-off $181.14 already purchased by the owner; amortization is not a new monthly cash charge |
| Cloud Run pipeline, dedicated Google Cloud project `gradstep` | 2026-10-06 | Usage-dependent | At 2026-10-08 09:00:47 UTC, revision `gradstep-pipeline-00012-9xj` has request billing, 1 vCPU / 2 GiB, concurrency 1, a 900-second request timeout and minimum 0 / maximum 3 at both service and revision scope. This is configuration evidence, not an invoice or a monthly guarantee |
| Cloudflare Pages: `gradstep-site` (gradstep.ai), `gradstep-app` (app.gradstep.ai, browser reader), `gradstep-admin` (admin.gradstep.ai) | 2026-10-07 (reader); 2026-10-08 UTC (admin) | $0 | Free static Pages, no Functions or new paid tier. Admin deployment `349d3859` and its custom domain are live; HTTPS/CSP/HSTS/no-transform and denied-caller checks pass. [Hosting evidence](ADMIN_HOSTING.md). This does not price other providers or establish an owner MFA session |

The current pipeline readback gives `gradstep-pipeline-00012-9xj` all traffic, with maintenance off and six numeric
Secret Manager references: five pinned to version 11 and Anthropic to version 5. Both instance ceilings are now 3;
the service maximum of 20 in the earlier audit is superseded. Evidence:
`.artifacts/takeover-20261008/pipeline-policy-readback.json`. Configuration does not measure actual allocation or
prove a full month's cost. The bounded, awaited worker lifecycle is described in [pipeline reliability](PIPELINE_RELIABILITY.md).

**Historical usage evidence:** the October 7 audit's instance-billed idle estimate of roughly $54/month described
the previous billing mode. After the owner-approved request-billing change, the 23:40 UTC observation recorded
43.2 billable instance-seconds, 86.4 GiB-seconds and 64 requests in the preceding complete hour
(`.artifacts/pipeline-spending-economics-20261007.json` in the spending worktree). That audit found no Monitoring
alert policies or billing-export datasets in this project; it did not rule out an export elsewhere, and those
inventories were not rechecked in the October 8 configuration readback. The low-activity forecast of roughly
$0–3/month remains a forecast, not a measured full-period bill.

At **2026-10-08 09:00:12 UTC**, Supabase cron readback confirms an active minute-by-minute pipeline wakeup,
store-verifier maintenance at minute 23 each hour and purchase-observation maintenance at minute 17. The Feed
gate is scheduled every 30 minutes, while its serving and refresh policies remain off. An active schedule does
not establish successful execution or authorize paid work. Evidence:
`.artifacts/takeover-20261008/supabase-cron-readback.json`. Wake-on-work remains a separate approved design to
show the owner before deployment; it has not replaced the one-minute pipeline schedule.

The existing workflow-check job's image-only refresh was verified at **2026-10-08 09:21:12 UTC**, to digest
`sha256:f02d84224ecbee907129a434ad5e0a3ae913c6d09c45fe07f2df496d9c55aeeb`. Job configuration, IAM and its three
existing schedules were preserved: one task, zero retries and a 2,700-second timeout. The update executed no
suite and sent no notification; alert email configuration is present but owner inbox delivery remains unverified.
Evidence: `.artifacts/takeover-20261008/workflow-image-apply.json.verified.json` and [workflow checks](WORKFLOW_CHECKS.md).

Supabase configuration was read back at 2026-10-08 00:02:31 UTC (October 7 locally): staging is active/healthy,
the organization is Pro, and the only selected addon is Micro at $0.01344/hour. The filtered, credential-free evidence
is `.artifacts/supabase-billing-configuration-20261007.json`. This endpoint reports configuration and pricing,
not billed hours or allocation of the organization's shared $10 compute credit. The published Micro rate is about
$10 per full month; project compute is charged hourly and is outside Supabase's usage spend cap.
[Addon API](https://supabase.com/docs/reference/api/v1-list-project-addons),
[compute billing](https://supabase.com/docs/guides/platform/manage-your-usage/compute).

### Economical search plan

At 23:35 UTC on October 7, Tavily's read-only `/usage` endpoint reported **37 of 4,000 credits used**, all search,
for both the dedicated key and account. Evidence: `.artifacts/tavily-usage-20261007T233535Z.json`. Its `paygo_limit`
was null, which did not establish whether overage was enabled; the owner's subsequent confirmation establishes
that it was turned off. Refresh usage after quiescing old paid paths before configuring a new admission baseline.
Do not assume this first day's test volume predicts a full public month.

**Recommendation, not yet accepted or applied:** downgrade to Researcher Free at the **November 6 renewal**, retain
pay-as-you-go off, allocate 900 of its 1,000 search credits to the application and leave 100 as operational headroom.
Show approaching-limit warnings in admin and reassess from measured usage before expanding. One basic search costs
one Tavily credit; one answer may issue several searches. The $30 Project subscription is not justified by the
observed beta volume. Future usage-priced search needs both vendor limits and explicit dollar admission/accounting;
do not turn on overage while treating its attempts as prepaid zero-dollar work.
[Published plan and search prices](https://docs.tavily.com/documentation/api-credits),
[plan changes](https://help.tavily.com/articles/2808196592-how-does-upgrading-or-downgrading-my-plan-work).

Tavily documents **calendar-month credit resets**, separate from subscription billing on the sixth. Its November 6
invoice period therefore must not become a rolling 31-day search allowance. Migration 034's dated period/baseline
replaces that old approximation. The exact boundary timezone must be verified before an automatic period rollover;
there is no blind automatic allowance replenishment in this work.
[Credit resets](https://help.tavily.com/articles/6846808029-understanding-api-credits-reset),
[billing versus reset dates](https://help.tavily.com/articles/3950309978-understanding-pay-as-you-go-and-billing-resets).

Keep the current provider allocation within the approved total, reuse eligible verified OCR conversions, and retain
Cloud Run request billing with no idle minimum. Forecast Supabase, backups, secrets/registry/builds, domain
amortization and metered providers separately; unknown components remain unknown in admin. Invoice attribution and
whether the Apple Developer Program is incremental remain open. No claim of a fully reconciled monthly total yet.

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

### Owner cost-evidence entry — deployed 2026-10-08

The **Spending → Record cost evidence** form is deployed at [the admin site](https://admin.gradstep.ai), backed
by `admin-spending` v1 and the existing migration 037 append-only observation RPC. Each submission/retry verifies
the caller's open account and owner/MFA status using that caller's JWT before invoking the service-only RPC.
It records an observation; it does not change customer credits, provider budgets, reservations or live offers.
Anonymous/customer denial and exact admin-origin CORS are verified. The owner role is provisioned through an
audited bootstrap, but **real owner sign-in/TOTP and a successful hosted entry remain untested; no invoices were written**.

Choose a component, **reporting month**, measure (`commitment`, `forecast`, `invoice` or `metric`), known USD
amount or unknown, evidence completeness and a short reference without credentials or account/invoice contents.
The reporting month groups the observation; it does not assert the vendor's service period. Leave completeness
unchecked when attribution or the covered period is uncertain. Verified zero and unknown are different.
For example, the supplied paid October 6 Tavily invoice confirms $30 paid but gives no prior service period;
the separate upcoming November 6 renewal explicitly covers November 6–December 6. Neither has been entered here.

Commitment/forecast amounts represent the component's total for the selected reporting month; the latest
planning observation is used, not the sum of invoice line items. Invoice and metric observations remain separate
from planning/provider totals. Do not mix individual line items with a full-month amount or count prepaid
Tavily searches again as metered dollars. Records are permanent; corrections append a new observation.
An unconfirmed submission keeps its original request UUID and observation time on retry, including a reload
in the same tab while its retry journal remains available and the same fields are re-entered. Do not deliberately
start a different entry to resolve an unknown outcome.
The dashboard currently browses at most 40 current-month observations; accepted earlier/future entries are
retained but do not yet have month navigation. [Deployment and verification evidence](ADMIN_HOSTING.md).

## Shared conversions and fair attribution

Proposed v1 rule: an already-ready shared conversion consumes no OCR credits. The requester who authorizes a new conversion funds that operation once, within a displayed maximum; other concurrent requesters attach as waiters without another OCR charge. Catalog preloading requested by the owner charges the platform budget, not an arbitrary customer.

Use atomic work-key claims so two users cannot both fund/submit the same shared conversion. Release losing reservations. Once work is submitted, one waiter leaving does not destroy a result others need. Record actual conversion costs separately from estimated avoided costs. Report reuse across distinct users as well as ordinary repeated reads so the savings metric is interpretable.

If this funding rule proves confusing in the benchmark, propose a platform-funded shared conversion allowance with per-user new-page quotas before publishing the rate card. Do not silently change the rule after charging subscribers.

### Import cancellation and retry — installed account contract, pending paid workflow

Migrations 010/011 install durable account import/membership commands, replay/removal fences, bounded acquisition claims, and separate account projections; hosted contract checks pass. The [data contract](DATA_MODEL.md) and [paper pipeline](PAPER_PIPELINE.md) separate account intent from shared work. The funding/submission behaviors below remain requirements for the future paid-processing implementation; they are not established by a source-only database fixture. Migrations 001–011 are immutable. Review additive paid authorization, attempt identity, lock order, quotas and recovery before any provider traffic.

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

## Staging Anthropic spend, 2026-10-08 → 16 (recorded 2026-10-16, after the balance ran out ~15:00 UTC)

From the provider ledger (`app_private.provider_attempts`, every call the staging functions and the podcast worker
make, priced by our rate card):

| | Calls | USD |
|---|---|---|
| Chat (Sonnet 5.5 $8.88, Opus $0.09, Haiku titles/suggestions $0.02) | 272 | 8.99 |
| Podcast script + review (Anthropic, 2026-10-09; DeepSeek since) | 24 | 2.57 |
| Catalog tags (Haiku) | 24 | 0.09 |
| **Anthropic total** | 320 | **11.65** |

By account: the owner's testing $7.11; synthetic accounts (workflow checks, live smokes, evals) $4.53. Peak day
2026-10-16 $3.02 (figure-view live runs and checks). Chat cost is dominated by **cache writes** (2.54 M tokens: the
whole paper written on a paper's first question, or the first after the 1-hour cache lapses) against 2.32 M cheap cache
reads and 0.11 M output tokens; a cold figure walkthrough is ~35–60 credits (~$0.20–0.30), a warm one ~5.

**Evidence limit, corrected during takeover:** these figures do not establish what depleted the prepaid balance.
We have not reconciled the opening balance, top-ups, provider invoice or direct development-script calls. The key's
historical source was the NAS project file (`scripts/read-nas-provider-config.py`); that does not prove the NAS app
is currently running or spending. No NAS access was performed during takeover. Organization-level billing and
other API keys are possible contributors, not measured attribution. A Claude subscription quota is also distinct
from the application's API balance. Reconcile Anthropic's Usage by key/workspace before assigning the missing spend.
The $7.11/$4.53 account split is based on account-email patterns, not an independently audited classification.
Cache token totals mix models, historical rates and cache durations, so multiplying all 2.54 M by today's Sonnet
hourly-write price would not give a valid dollar breakdown. Dedicated Science Reader credentials remain required.


## Model comparison reservation — 2026-10-16 takeover

The owner approved OpenRouter and **up to $25 total including grading** in the recovered Claude conversation.
Current experiment admission cap: **$18**; the existing provider-enforced, non-resetting key limit is **$20**.
Read-only account check at takeover: purchased credit **$0**, provider usage **$0**, outstanding inference
reservations **$0**. No recurring commitment was added, no inference was sent, and the $100/month operating
budget is unchanged. The maximum planned experiment exposure is $18; a measured cost forecast and remaining
monthly headroom must be reconciled before any later expansion. The initial cold/warm workload cost forecast
remains unmeasured; list token prices are not an answer-cost forecast.

`scripts/model-bakeoff.mjs` keeps an atomic per-request spend/hold ledger under `.artifacts/bakeoff/`, separate from
the staging database ledger because these are local research calls through OpenRouter. Missing usage retains a
full reservation, including after interruption; report actual and outstanding amounts together. The provider key
limit is required in addition to local admission. Do not count an OpenRouter balance top-up as consumed model
usage, or silently count this experiment as free just because it bypasses staging. See
[comparison protocol](../reviews/MODEL_COMPARISON_20261016.md).

**Funded continuation, 2026-10-16 20:16 UTC:** OpenRouter reports a $10 top-up, $0 prior usage, and the unchanged
$20 non-resetting key limit. No new recurring commitment. Working admission initially reduced to $9 total, with $7 for
the contestant phase to leave grading room; this does not increase the $100 operating budget or $25 research
authorization. The six-answer smoke settled at **$0.03148947**, $0 unresolved. A matched 12-question screening
across all 13 settings began at this checkpoint, with selected extensions planned within the remaining funding.
The ledger is `.artifacts/bakeoff/spend-ledger.json`; its holds are reservations, not consumed usage. Final actuals
and outstanding amounts are recorded below. The initial planning range was $5–9 including grading and
extensions, conditional on measured costs and admission; do not top up automatically to finish.

**Funded hold adjustment, same run:** $0.50 of the existing $10 funding cushion was reassigned to admission,
making the working ceiling **$9.50**. This allowed a deferred long-context request's conservative temporary hold;
the request actually reported $0.0174. No additional purchase, recurring commitment, operating-budget increase,
privacy-setting change or increase to the owner's $25 authorization was made. Completion-reported charges exceed
OpenRouter's aggregate usage reading; preserve both and control admission using the larger local ledger exposure.

**Round completed, ~21:25 UTC:** contestant requests **$6.059726**, primary grading **$2.113472**, independent
grading **$0.482578**: total **$8.655776 completion-reported**. Five interrupted requests retain **$0.228190**
holds, so conservative total exposure is **$8.883966**. Further planned spend for this round is **$0**. The last
image-grading request required $9.63 of temporary exposure under the existing **$10 funded ceiling**; no reservation
overrun occurred. There was no further purchase, fixed commitment or change to the $100/month operating budget.
The provider's account/key endpoints still reported **$3.451502566** usage at 21:25 UTC. This lower figure is
unreconciled with the response records and is not used as permission to spend the difference. Generation metadata
returned 404 even for a known completed call. Details and retained non-secret evidence:
[measured comparison](../reviews/MODEL_COMPARISON_RESULTS_20261016.md). The 27-question finalist extension is
pending; do not treat its cost as zero or expand it using the stale/lower account reading.

**Finalist continuation, ~23:15 UTC:** the first-screen generation metadata now resolves all five interrupted
requests: **$0.03395231** actual replaces **$0.228190** held. Corrected first-screen total **$8.6897285082** matches
account/key usage at 22:50 UTC to rounding; original failures and the original evidence snapshot are preserved.
The additional 45 contestant requests cost **$0.535841875**, four independent grading requests **$0.440760**,
and two short calibration requests **$0.020200**. Experiment totals: contestant requests **$6.6295203832**;
grading **$3.0368100000**; calibration **$0.0202000000**; **total $9.6865303832**, **outstanding $0**, no overruns.

Purchased credit remains **$10**, leaving **$0.3134696168** by the authoritative request ledger. The latest
aggregate reading at 23:19 UTC was $9.413856053 and still lagging; it is not extra spending room. Full conservative
holds prevented further grading before inference. Current forecast for additional paid work is **$0 until
funding is confirmed**; no unattended paid process remains. The owner's $25 research authorization, $20 key
limit, tighter $18 harness maximum and $100/month operating budget are unchanged. The request to fund the rest
of the approved $25 is pending; no top-up or fixed commitment was made. Research is actual usage within the
existing operating budget, not part of staging's separate provider ledger.

[Finalist results](../reviews/MODEL_COMPARISON_FINALISTS_20261016.md) record cache conditions and remaining
quality checks. The four new Argon grading calls reported zero cached tokens, so their $0.322660 prompt cost must
not be forecast as a discounted cache read. Source evidence, reconciliation receipts and raw answers are kept
in the new immutable comparison archive; no invoice-level reconciliation or direct-provider price equivalence
is claimed.

## Gemini Flash integration — 2026-10-17 ~00:08 UTC (Oct 16 PDT)

The owner selected Gemini Flash for chat. Local implementation and verification incurred **$0 additional model
inference**, **$0 new fixed commitments**, **$0 new reservations** and no credit purchase. OpenRouter's account/key
now reports **$9.686530368 used from $10 funded**, reconciling to the experiment ledger's $9.6865303832 within
rounding; about **$0.31** remains. No paid process is running. The $100/month operating budget is unchanged.

[OpenRouter Standard](https://openrouter.ai/pricing) passes through model token prices and charges **5.5% on credit
purchases**, with a [minimum $0.80 fee](https://openrouter.ai/blog/tutorials/any-coding-agent/). $25 credit would cost
about **$26.38 before tax**. This is a quoted future purchase, not a receipt; the fee/tax on the prior $10 purchase
has not been invoice-reconciled. Credit-purchase fees belong in overhead, separate from metered `usage.cost`, and
must not be counted twice. No higher plan, automatic top-up or budget increase is enabled.

Flash's current Google list rates double on 2027-01-01; the new tariff gate and provider price caps prevent an
unreviewed increase. Near-term additional usage forecast remains **$0 pending funded service credentials**; then
declare a bounded allocation for the focused live checks before enabling app traffic. Customer usage must remain
inside existing server-side reservations and monthly controls. [Integration and rollout](GEMINI_FLASH_CHAT.md).

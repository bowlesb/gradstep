# Spending controls and investigation

Status, 2026-10-08 UTC: **migrations 034–038 and their provider/worker controls are deployed on staging**;
039 upload accounting is also applied. Read-only takeover evidence at
`.artifacts/takeover-20261008/spending-policies.json` records provider admission enabled with coverage beginning
**2026-10-08 02:40:51.785121 UTC**, asset enforcement on, scope-2 inventory verified at 03:09:31.700048 UTC with
zero discrepancies, and **reader delivery still `legacy`**. Storage admission is enforced; the signed-URL replay
exposure is not closed. This is a dated configuration observation, not a continuous monitor or vendor invoice.

The owner requested closing the [audit findings](../reviews/CREDIT_IDENTITY_COST_AUDIT_20261007.md) and transparent records for investigating unexpected costs. Customer credits, provider expense, unresolved liability, prepaid units and infrastructure bills remain distinct. The incremental beta budget stays $100/month.

## Accounting contract

- Existing metered_operations reserve platform USD once. Child provider_attempts allocate within that ceiling; they never add a second USD hold while the operation is active.
- Customer settlement records known expense and releases customer credits. Outstanding child ceilings remain platform reserved after settlement, in metered_operations.provider_liability_microusd. Reconciliation is append-only and separately releases liability into recorded expense; prior customer debits remain immutable.
- Each attempted transport requires a one-time durable grant; every replay grants false. Admitted attempts without a final record remain held, even after worker death. No blanket age-based release. Requested grant denial is durable where an operation exists and record capacity permits.
- Numeric-only unit records; no private prompts, replies, queries, titles, URLs or raw provider errors. Provider IDs/operation/account/route/model/rate and pricing snapshot permit investigations. Records retained under existing de-identified financial-account policy.
- Tavily prepaid usage reserves exact units in a verified dated billing period and per-account UTC-day allowance. Unknown attempts retain units. Period starts/ends and baseline usage must be configured from provider evidence; migration default disabled. Legacy usage is not silently treated as complete.
- Table capacity100k attempts/environment,20k/account,64/operation; bounded JSON/events. Growth stops admission instead of erasing financial/replay history. New analytics distinguishes coverage cutoff/historical legacy-only records.
- Financial operations take budget -> account -> attempt-policy/provider-period -> operation/attempt. Pipeline funding and settlement acquire budget/account locks before the paper fence. Tag claim/record retains its existing tag-row serialization; generic financial RPCs never acquire a tag row afterward.
- The credit-resume sweep (040) restarts imports waiting on credits without reserving anything: it locks accounts
  (id order, NO KEY UPDATE, so grants/purchases/reservations, which take them FOR UPDATE, cannot change a balance
  under it), then the pipeline policy throttle row, then library locks; never budget, bucket, purchase gate or paper
  rows. Funding later reserves once per paper as before; suspended and closed accounts are never restarted.
- Accounts can be suspended for new spending. Existing owner disable action sets that guard transactionally before the Auth API, and grant/read admissions honor it. Known in-flight liabilities still reconcile.
- Read-only MFA-owner investigation APIs expose incurred/reserved/uncertain costs, provider units, operation attempts, anomalies, overhead evidence freshness and reconciliation, separate from customer credits and vendor invoices. No claim of whole-system100USD guarantee absent vendor/infra limits.

## Coordinated rollout

Provider attempt admission (034), complete asset accounting and bounded delivery (035), Sandbox identity allowances (036), and owner investigation APIs (037) are additive. Existing applied migrations stay immutable. Drain old workers before enabling new accounting: rejecting their final writes cannot undo already-sent provider calls or unregistered uploads. Verify vendor allowance baselines and reconcile the existing bucket inventory before enabling enforcement.

Older installed Apple/web readers validate only Storage signed URLs. Current native and browser source accepts both authorized transports and requests `bounded-v1`, but the observed server policy still returns the legacy path. Complete the reviewed client/expiry cutover before retiring legacy issuance; existing downloaded bundles remain readable offline. The legacy path cannot be described as a hard replay cap, and a cutover needs explicit minimum-client handling, old/in-flight issuer fencing and verified CDN cache retirement.
Nominal token expiry is insufficient: cached signed responses may outlive it. See the [CDN cutover boundary](ASSET_SPENDING.md#compatibility-and-deployment).

Cloud Run request-based billing requires a bounded awaited execution lifecycle. A parent request waits for its isolated worker to finish or terminate before replying, with its deadline below the platform request timeout. Confirm live flags and observed allocation after deployment; forecast amounts and measured instance allocation are not invoices.

## Investigation and monitoring

The implemented owner-only Spending page replaces the former Usage tab with bounded time-window summaries and paged operation detail: account, feature, provider/model, attempt ID, provider request ID, timestamps, outcome, numeric units, customer credits, known cost, held liability, and reconciliation history. Keep private content out of these records. Show platform-funded work and uncertain failures rather than making them disappear after a customer refund.

Track fixed commitments, infrastructure observations and invoice adjustments with source/evidence dates; unknown or stale components make the forecast explicitly incomplete. Include thresholds and computed anomalies for budget utilization, provider allowance, aged unknown attempts, unmatched legacy usage, asset discrepancies and infrastructure drift. Alerts visible in the dashboard do not replace admission controls or imply an external notification was delivered.

Sandbox purchases require a stable verified Apple app-transaction identity for new free credit grants; missing identity grants no Sandbox credits and is inspectable. Production signature/receipt behavior is unchanged. Serialize both account/month and Apple-identity/month consumption; refunds do not replenish the free allowance. The existing upgrade-credit policy discrepancy is a separate product-policy reconciliation, not permission to silently change owner-approved allowances.

### Sandbox allowance implementation (036)

Every Sandbox app report, notification, restore and refund reversal acquires the single Sandbox `store_policy`
row `FOR UPDATE` before the shared purchase lock protocol below. This deliberately serializes free test-credit
admission across both allowance dimensions, avoiding an ownership-resolution race when a deleted account's purchase
moves while a notification arrives. Sandbox volume is already rate limited and does not justify a second financial
counter. Production bypasses this Sandbox gate; its grant/refund rules remain unchanged.

Both environments then take transaction-scoped advisory gates for the exact, validated environment and transaction
ID (two-integer namespace `741801`) and original purchase ID (namespace `741802`), in that order. The transaction's
recorded original must match before entering the original's gate. These explicit, separate namespaces are reserved
for purchase recording; a hash collision within either namespace only serializes unrelated purchases at that layer.
There is no global Production admission mutex.

With that original stable, recording captures the caller, signed token, current/previous owner and every historical
transaction owner for the original, then locks existing account rows in UUID order. Those historical accounts matter:
a later upgrade can still revoke an older bucket belonging to a deleted account. Only afterward may recording lock
`store_seen`, ownership and buckets or acquire their implicit foreign-key locks. This agrees with 034's multi-account
funding order. Account closure takes an account first and does not acquire purchase gates, ownership or financial
history rows; it therefore completes or waits without adding the opposite ordering.

Unknown token accounts remain unattributed, preserving the newest verified signed state. If an account absent from
the captured set becomes visible later, recording raises `store_account_changed` and rolls back for caller retry,
instead of acquiring a new account lock out of order. The notification wrapper performs only a plain duplicate read
before the shared recorder, and appends its notification record afterward. Sandbox identity preflight is read-only;
identity updates also follow the shared recorder. Neither entry point can bypass the protocol.

The durable allowance history is each transaction's granted `credits` and `granted_at`; refunds do not decrement
these fields. Separate indexed sums bound the current UTC month's grants by account and by verified Apple
app-transaction identity, each to at most 1,000 credits. The effective grant is the smaller remaining allowance.
Deleting/recreating an app account does not reset the Apple-identity history. Prior grants without a recorded
Apple identity still count for their account, but historical cross-account attribution cannot be reconstructed
without new verified evidence and must remain visible as a coverage limitation.

The newest-copy table retains the first verified non-null Sandbox app-transaction identity even when a transaction
is initially unattributed. A later verified copy can fill an absent identity; it cannot replace an existing one.
An omitted field may use that transaction's previously verified identity, never a client-supplied substitute or
another transaction's identifier. Without either source, a new grant is zero, the transaction is still recorded,
and an append-only decision names the missing identity. Decisions include requested/granted credits, allowance
period, account/identity usage before the grant, cap and reason. They contain no signed receipt, user content or
authentication token. Ordinary purchase outcomes stay compatible with installed clients.

Acceptance requires real concurrent database sessions using distinct app accounts and original transaction IDs
with the same Apple identity, plus a shared account using distinct Apple identities; combined grants cannot exceed
either allowance. Replays, missing/changed identities, unattributed-first reports, refunds/reversals, deleted-account
restore and Production regression cases must preserve that invariant. The plan-change credit policy is unchanged.

### Owner spending investigation (037 applied; UI locally verified)

The owner-only **Spending** page replaces Usage and requires the existing MFA gate. Its 7/30/90-day summaries
separate reported provider costs, conservative estimates, customer debits, and unresolved liabilities. An all-date
unresolved filter includes old prepaid search attempts even when their dollar ceiling is zero. Operation and
event-history pages use bounded keyset cursors; details show recorded pricing, provider request IDs, numeric units,
refunds and later reconciliations. Private prompts and paper contents never enter these views.

The operating forecast includes the full provider allocation plus dated overhead evidence. Missing components
remain **not recorded** and make the forecast incomplete. The dashboard does not manufacture invoices from metrics
or promise an infrastructure-wide vendor spending cap. External cost observations remain append-only.

Local PostgreSQL checks pass for MFA/role boundaries, account scope, held versus expensed cost, refunds,
immutable evidence, bounded pagination and unresolved attempts older than the selected window. The admin production
build and `node scripts/check-spending-dashboard.mjs` pass. The loopback-only journey uses synthetic data to check
details/history paging, keyboard focus and return, filters with delayed responses, zero-dollar unresolved work,
empty/error states, phone-width layout and dark appearance. Screenshots under `.artifacts/spending-dashboard/`
were inspected; development fixtures are excluded from production. Migration 037 and its APIs were subsequently
applied to staging. This UI proof remains local fixture evidence; a live owner/MFA dashboard journey has not been
re-audited in this takeover.

## Current evidence and remaining limits — 2026-10-08 UTC

The 05:14 UTC budget snapshot is **$13.677389 spent, $0 reserved, $25 limit** for October; recorded provider
headroom was $11.322611 at that instant (`.artifacts/takeover-20261008/budget.json`). It is not the remaining
whole-system budget. Fixed subscriptions, runtime, Storage/egress, logs and invoices remain separate evidence;
keep the approved $100/month incremental beta ceiling and [operations record](OPERATIONS_AND_BILLING.md).
Tavily's observed configured period is October 1–November 1 UTC, limit 3,900 and baseline 37 of the 4,000-credit
Project plan; PAYGO was confirmed off by the owner. Native Anthropic search remains disabled. The proposed Free
plan/900 allowance is not applied, and later usage must be read before any new allocation.

The private Apple verifier (033) and purchase observations (038) are deployed. Staging records three real
Sandbox credit-pack grants **400 + 400 + 200 = 1,000**, with replays recorded separately. This verifies that
observed Sandbox path, not Production purchases, subscriptions, renewals or refunds. The subscription upgrade
policy discrepancy remains open: owner-approved retained prior-period credits versus the recorder expiring the
replaced period's unused credits. Do not hide that business-rule decision inside accounting changes.

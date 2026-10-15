# Spending controls and investigation

Status, 2026-10-08 UTC: **migrations 034–038 and their provider/worker controls are deployed on staging**;
039 upload accounting is also applied. Read-only takeover evidence at
`.artifacts/takeover-20261008/spending-policies.json` records provider admission enabled with coverage beginning
**2026-10-08 02:40:51.785121 UTC**, asset enforcement on, scope-2 inventory verified at 03:09:31.700048 UTC with
zero discrepancies. A subsequent **09:33 UTC** readback confirms **bounded-only reader delivery**, with 045
fencing the old issuer and complete reader-scope CDN retirement proved after the full drain/expiry horizon.
All 1,046 purge paths succeeded; two formerly HIT tokens now fail for expiry and fresh bounded reads pass.
Quotas and counters were preserved. [Cutover evidence and scope limits](../reviews/READER_CDN_CUTOVER_20261008.md).
These are dated observations, not a continuous monitor or a bound on original/Mathpix URLs and vendor invoices.

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

Older installed Apple/web readers validate only Storage signed URLs and must update for fresh downloads.
Current deployed native/browser clients request `bounded-v1`; hosted mode is now bounded-only. Existing native
downloaded bundles remain readable offline. Migration 045 fences the old issuer, and the reviewed full-drain,
expiry and exact-object CDN purge procedure completed successfully. Nominal token expiry alone would have been
insufficient because cached signed responses can outlive it. See the [CDN cutover boundary](ASSET_SPENDING.md#compatibility-and-deployment).

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

### Owner spending investigation (037 applied; admin deployed; owner session unverified)

The owner-only **Spending** page is deployed at `https://admin.gradstep.ai`, Pages **349d3859**. It replaces Usage
and requires the existing MFA gate. Its 7/30/90-day summaries
separate reported provider costs, conservative estimates, customer debits, and unresolved liabilities. An all-date
unresolved filter includes old prepaid search attempts even when their dollar ceiling is zero. Operation and
event-history pages use bounded keyset cursors; details show recorded pricing, provider request IDs, numeric units,
refunds and later reconciliations. Private prompts and paper contents never enter these views.

The operating forecast includes the full provider allocation plus dated overhead evidence. Missing components
remain **not recorded** and make the forecast incomplete. The dashboard does not manufacture invoices from metrics
or promise an infrastructure-wide vendor spending cap. External cost observations remain append-only.

#### Owner evidence entry (API and frontend deployed 2026-10-08)

`admin-spending` v1 is deployed from reviewed **31bcf1b**, with all six served modules matched to source. The
frontend is live in Pages **349d3859**, with exact admin-origin CORS verified. Anonymous callers receive 401 and
customers 403; the hosted denial check recorded no observation and left credits/provider expense unchanged.
The public sign-in screen passed HTTPS/CSP/HSTS/no-transform and desktop/phone checks. An audited bootstrap
granted the existing verified account the owner role without changing its password or MFA factors. **A real
owner password/TOTP session, privileged dashboard journeys and successful hosted evidence entry remain untested;
no invoice has been entered.** [Hosting and redacted deployment evidence](ADMIN_HOSTING.md).

The Spending page has a small form for reporting month, component, measure, USD amount, completeness and an
evidence reference. A reporting month is an allocation bucket, not an inferred invoice service interval. Record
commitments/forecasts separately from invoices/metrics: only the latest commitment or forecast per component feeds
the plan, so an invoice does not charge the provider budget or add the same subscription a second time. Unknown
amounts and partial evidence remain explicit. For example, the owner's paid October 6 Tavily invoice establishes
$30 paid, but not its prior service interval; the separately supplied upcoming November 6–December 6 interval is
known. Neither observation invents coverage for October 6–November 6.

The deployed `admin-spending` Edge route validates Auth through `userClient`, then runs `v1_admin_actor` on that same
caller's token and checks the returned account. Only an owner with real `aal2` can reach the service-role client.
It consumes the existing `admin-spending` rate window, then calls the already applied
`worker_record_spending_observation`, which rechecks that the actor is an open owner. An owner UUID or a service
credential alone is not the browser authorization path. The request has a closed, 4 KiB schema; actor, source
(`owner-entry`) and empty numeric units are set by the server. Responses and logs carry finite outcomes, never
evidence text, amounts, accounts, tokens or raw database errors. No migration or budget/credit mutation is needed.

Each submission freezes its UUID, observation timestamp and fields until acknowledged. A bounded, account-scoped
session retry journal stores only the fields' SHA-256 digest, UUID and timestamp; evidence and other form contents
stay in memory. Re-entering the same fields after a reload uses that exact retry identity. An unavailable journal
fails before sending. A successful exact replay is acknowledged once; a lost response never silently creates a
new observation. Different entries are explicit new actions. The supplied invoice has not been entered:
deployment is complete, but a real owner/MFA session remains required.

The form records the component's amount for the reporting month; a planning entry replaces that component's
previous total, rather than summing individual line items. It supports the existing eight cost components and
four measures without arbitrary unit/source editing. Current observation browsing still shows the newest 40 rows
for the current UTC month only; past/future month entries are acknowledged with their month, not presented as
currently visible records. The session journal holds at most 32 unconfirmed intents and is not a cross-tab or
permanent receipt archive. Closing the browser session can remove it; a mounted form always retries its frozen
request even if a concurrent acknowledgment already removed that journal entry.

Independent review checked caller-token MFA, the service-only writer, closed inputs, immutable exact retries and
financial isolation. Local verification covers the actual PostgreSQL RPC's role boundaries, replay/conflict,
invoice-versus-allocation separation and unchanged budget/credit tables; 21 focused Node tests (including the
existing admin-accounts gate) pass. The new loopback `check-spending-entry.mjs` journey covers a committed request
whose response is lost, retry after reload, private-free journal metadata, full-component allocation replacement,
unknown amount, keyboard focus and desktop/390px light/dark forms. The existing spending-dashboard journey,
production admin build and Deno entrypoint check also pass. Screenshots and the synthetic summary are in
`.artifacts/spending-entry/`; these are not hosted owner/MFA evidence or vendor invoices.

Local PostgreSQL checks pass for MFA/role boundaries, account scope, held versus expensed cost, refunds,
immutable evidence, bounded pagination and unresolved attempts older than the selected window. The admin production
build and `node scripts/check-spending-dashboard.mjs` pass. The loopback-only journey uses synthetic data to check
details/history paging, keyboard focus and return, filters with delayed responses, zero-dollar unresolved work,
empty/error states, phone-width layout and dark appearance. Screenshots under `.artifacts/spending-dashboard/`
were inspected; development fixtures are excluded from production. Migration 037 and its APIs were subsequently
applied to staging and the admin frontend is now hosted. These privileged UI journeys remain local fixture
evidence; the live sign-in-screen and denied-caller checks do not establish a real owner/MFA dashboard journey.

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
observed Sandbox path, not Production purchases, subscriptions, renewals or refunds. Independently reviewed
**migration044 now enforces the approved upgrade policy**: each period's credits keep their original expiry.
It also rejects malformed copied receipts that could produce a nonexpiring subscription grant. Staging rollout
used a verifier pause/drain, encrypted backup, zero-history guard, unchanged purchase/grant terms and exact
function/permission readback before restoring both channels. No price, allowance, balance backfill or provider
limit changed. [Retention contract and evidence](../reviews/SUBSCRIPTION_UPGRADE_RETENTION_20261008.md).


## Budget periods, failed answers and the stale-hold sweep — 2026-10-14 (migration 060; staging)

From the [cost and credit audit](../reviews/COST_CREDITS_AND_SYNC_AUDIT_20261014.md), items 2, 4, 5 and 6, and the
hold-sizing part of item 3:

- **The monthly budget row creates itself.** `worker_ensure_platform_budget()` (service role) creates this month's
  row from the latest earlier period and next month's from this month's, same limit and same work switch, never
  larger; pg_cron runs it daily at 03:07 UTC (`science-reader-budget-period`) and the migration ran it once. The
  budget is still only ever raised by hand (`scripts/pipeline-ops.py budget`); copying the same limit forward does not
  increase it. Without any earlier row nothing is created (a fresh environment still needs its first row by hand).
- **One readback for alerting.** `worker_budget_health()` (service role) returns the period, limit, spent, reserved,
  the work switch, provider attempts left `unknown` for over an hour, operations open for over an hour and whether
  next month's row exists. The scheduled workflow check `budget.health` (`scripts/workflow-checks.mjs`, every suite)
  fails, and so emails the owner through the existing Resend path, on paused work, 80 % of the limit spent plus
  reserved, aged unknown attempts, aged open holds or a missing next month.
- **The stale-hold sweep books no spend.** `worker_expire_stale_chat_operations` settles a chat operation that never
  reached the provider at 0 credits and 0 micro-USD (it used to settle at the full ceiling and add it to
  `spent_microusd` for good). Staging's `spent` of $21.03 against $9.59 of recorded provider attempts predates this;
  it is not corrected retroactively.
- **Unknown attempts have a release tool.** `scripts/pipeline-ops.py attempts [--hours N]` lists provider attempts
  still `unknown` or `admitted` after N hours (id, operation, route, model, ceiling, request id, age) read-only;
  `scripts/pipeline-ops.py reconcile <attempt> --actor <owner account id> --microusd <actual> --evidence <provider
  request or message id> --reason <text>` resolves one through `worker_provider_attempt_reconcile` (owner-audited,
  idempotent per request id), which releases the rest of its ceiling from the platform's reserved liability. Staging
  had none older than an hour on 2026-10-14 17:00 UTC. Automatic resolution of aborted chat attempts from their
  `message_start` usage is still open (audit item 1).
- **Failed answers.** An answer the provider never started (no `message_start`: a 5xx, an overload, a dropped
  connection) charges the reader 0 credits; the `error` event carries `credits` and both clients show "No credits
  used". The provider attempt keeps the platform's liability until it is resolved (audit item 1, still open).
- **Hold sizing: tried and reverted the same hour.** Chat function 118 (16:53 UTC) counted prompt bytes once instead
  of three times, a third of the earlier input estimate. At 16:57 the first live answer's follow-up attempt cost 271
  micro-USD against a 242 micro-USD per-attempt ceiling (the real prompt tokenized at about 2.3 bytes per token, under
  the ÷ 3 estimate), the overrun set October's `work_enabled` to false, and every paid request on staging answered
  `platform_budget_exhausted` until 17:04, when the switch was set back on at the same $25 limit
  (`pipeline-ops.py budget --usd 25`; nothing raised). Function 121 restored the one-token-per-byte estimate with
  a note saying why; the per-attempt ceiling is sized from the same estimate as the hold, so any estimate below the
  real count pauses the platform. Audit item 3 therefore stays open in full: a real token count (the count-tokens
  endpoint) is the only safe way to shrink holds, and "needs N available" in the estimate is still to do.
- **Sync fence.** `v2_pull_events` raises `sync_page_too_large` (which builds up to 27 render as an update notice)
  instead of `reader_update_required` (which they rendered as "try again") when a page holds a format-2 event.

Evidence: `tests/database/budget_period.sql` (ensure creates next month once, copies and never raises, health
readback, permissions, the sweep releases a two-hour-old hold without charge or booked spend) in the cutover phase of
`scripts/test-database.py`; backend chat tests for the zero charge and the `credits` on `error`.

## October cap raised on the owner's instruction — 2026-10-15 01:30 UTC

The owner's chat refused with "AI answers are paused right now" (`platform_budget_exhausted`): October stood at
**$23.20 spent of the $25 limit**, and a Sonnet answer's hold no longer fit. The owner, shown the day's spending, said
"it's all fine with me, just push ahead". Done, and recorded here rather than silently: October's limit was set to
**$30.00** at once (the schema's hard ceiling; `worker_set_platform_budget`), migration **068** raises that hard
ceiling from $30 to **$50** a month, and October's limit is then set to **$40.00**. Both stay inside the approved
$100/month incremental beta budget; November's row keeps $25 until the owner says otherwise. What the evening cost:
the device-source podcast proofs ($0.10 + $0.26 failed, $0.11 ready), the chat live proof after the change ($0.25,
27 credits), the authors/Back/scroll work nothing. Forecast for the rest of October at the owner's testing pace
(a few answers and an episode or two a day): $5–8, within the $40.

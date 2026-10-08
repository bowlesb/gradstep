# Subscription upgrade credit retention

Status: independently reviewed, **migration044 deployed to staging 2026-10-08 07:42 UTC**. The baseline regression
reproduced the defect. The final normal database command passes after removal of temporary candidate
selectors; focused migration, lifecycle and concurrency checks also pass. Independent review and its
focused rerun include the additional malformed-receipt guard. Prices and allowances stay unchanged.

Root deployment evidence: `.artifacts/takeover-20261008/subscription-rollout-state.json`. Both verifier channels
were CAS-disabled from revision 2 to 3; all-session stats visibility was proven, no recorder transaction remained,
and no admitted start occurred within ten minutes. Encrypted checkpoint `20261008T073303Z-950e99dcb0da` captured
the database and 1,346 verified objects. After 043 applied with both Feed switches off, 044 applied and its ledger,
three exact function bodies, definer/search paths and private permissions matched reviewed source. Purchase
records, original grant/bucket terms, allowances, products and the $25 provider cap were unchanged; current
spendable balances were allowed to follow ordinary hold/settlement activity. Both channels restored enabled at
revision 4. Hosted checks: 4 pass, 0 fail, 1 known insufficient-credit-import warning; forged purchases/admin
requests refused, synthetic account deleted, zero provider spend/holds. No real subscription was bought.

The following deployment procedure records the reviewed requirements, not remaining rollout work. Local fixture
verification below remains distinct from hosted purchase/refund acceptance.

## Approved behavior and defect

[DECISIONS](../DECISIONS.md#subscriptions-and-credits-owner-approved-2026-10-05) says an upgrade grants the new
plan's credits immediately and leaves the old period's credits until expiry. This is overlapping validity of two
existing transaction grants, not rollover or indefinite credit accumulation. Genuine refunds still remove that
purchase's unspent credits, preserving already-reserved work; refund reversals restore only what was removed.

Migration036 contradicts that rule in three places:

1. `store_grant` revokes earlier subscription buckets when a different product is purchased mid-period.
2. It refuses an earlier unexpired period first reported after the upgrade.
3. `record_store_transaction_locked` refuses to reinstate an earlier refunded period after an upgrade.

Apple describes upgrades as immediate, with a prorated monetary refund and a new billing period. That does not
set our credit expiry policy. Apple's per-transaction `expiresDate` is static across renewals; a renewal is a
different transaction. Preserve the credit bucket's original expiry, including when a newer signed copy changes
the stored transaction's expiry metadata. This repair does not add credit allowance for a renewal-date extension.
[Apple subscription changes](https://developer.apple.com/app-store/subscriptions/),
[expiresDate](https://developer.apple.com/documentation/appstoreserverapi/expiresdate).

## Narrow candidate

Replace three migration036 private functions in a new migration (initially `.sql.pending`, now locally promoted
to044 after independent review). Remove those three
upgrade-specific credit restrictions and their obsolete comments/variables; add the required copied-receipt
validation below. Preserve:

- One bucket and one grant for each `(environment, transaction_id)`; immutable grant history and receipt identity.
- The newest verified signed state, duplicate-notification behavior, and older-receipt refusal to reverse refunds.
- The Sandbox policy gate, verified Apple identity requirement, account/month and Apple-identity/month caps,
  and audit decisions. Reversing a refund restores an existing grant; it does not replenish either allowance.
- Transaction/original advisory gates, ordered complete historical-account locks, account closure and ownership.
- Genuine refund removal, in-flight holds, settlement, credit expiry and soonest-expiring-first allocation.
- Product IDs, amounts, storefronts, signatures/OCSP, transport, role grants, financial/provider budgets and prices.

An unexpired old period first seen after an upgrade receives its one ordinary grant, subject to the same Sandbox
caps. An expired first sight receives no grant. A reversed refund of an already-granted expired bucket may restore
the historical ledger balance but its original expiry makes those credits unspendable. A period first seen already
refunded receives its ordinary grant only if the reversal is still eligible. The new period's refund does not
revoke the old period, and vice versa. Credits forfeited on account deletion never move to a new account.

Restore has an existing distinction that the older phrase “future periods only” obscured: **already recorded**
transactions and their buckets stay on the original account after closure, including recorded zero grants. A
**never-recorded**, still-valid transaction can receive its one first grant on the account that restores the
purchase, even if its purchase date predates the old account's closure. This preserves the existing deleted-token
restore rule and its tests. An upgrade no longer makes arrival order suppress that otherwise eligible first grant.
Account deletion gates future spending; it does not zero or revoke the preserved accounting bucket. No closed
account gains permission to spend, and old recorded balances are never transferred or re-granted on the new account.

No helper override that makes `store_replaced` always false, no dynamic source-string patch at migration time,
and no applied migration edits. Explicit function bodies make the financial diff reviewable. The now-unused
private helper may remain for migration history; callers no longer use it for credit eligibility.

### Missing-expiry reversal found during review

The prior recorder checked subscription/consumable product terms only at first sight. A subscription first seen
already refunded could later receive a newer normalized reversal **without `expires_date`**; the private grant's
`NULL <= now()` comparison did not reject it, so it created 800 credits with no expiry. The local reproducer
confirmed this before the guard; evidence: `.artifacts/subscription-upgrades/missing-expiry-reproducer.json`.
Removing the replaced-period veto makes this particularly relevant to formerly suppressed old periods.

The final candidate validates known-product type, quantity, ownership and required/bounded subscription expiry on
every copy before newest-state or financial writes, preserving the existing `unsupported` outcome. The private
grant also rejects missing/nonfinite subscription expiry. The Sandbox wrapper fills missing verified identity
only when the core recorder did not refuse the product terms; otherwise an unsupported copy could still alter
the old identity row after returning. Valid identity fills, caps, replay behavior and renewal-extension metadata
remain as before. No new column or alternate expiry policy is introduced.

Both environments test omitted/null subscription expiry, wrong type/quantity/ownership, an overlong period and
consumable expiry/type/quantity/ownership mismatches. Fingerprints include buckets, immutable ledger, transaction
records, newest signed state and Sandbox decisions, including previously missing Apple identity. Refusal changes
none of them; a later valid reversal still follows normal credit and Sandbox allowance rules.

## Existing data and deployment gate

Root's read-only staging inventory at 2026-10-08 06:41:38 UTC found **zero subscription transactions/buckets and
zero `store-superseded` revoked buckets**; the only transactions were three Sandbox packs totaling 1,000 credits.
Evidence: `.artifacts/takeover-20261008/subscription-upgrade-inventory.json` in the main checkout.

Accordingly, this candidate contains **no retrospective grant or bucket rewrite**. The migration checks
that **all** subscription transaction/bucket history is still empty, including zero-grant transactions, and
rejects otherwise. Immediately before any later deployment, repeat the inventory. If affected records have appeared,
stop for a separately reviewed repair:
only open accounts, unexpired original buckets, an unrefunded latest verified transaction, and the exact amount
removed by the immutable supersession ledger entry can be considered. Distinguish an existing superseded bucket
from a never-granted replaced period, refund-at-first-sight, missing Sandbox identity, exhausted allowance and
deleted ownership. Replays must not create a general grant escape hatch. Never re-grant expired or forfeited
credits, refund consumed allowance, rewrite ledger history, or blindly clear all revocations.

Deployment sequence, **not executed by this workstream**:

1. Review is complete and the migration is locally promoted to `202610080044_subscription_upgrade_credits.sql`.
   Recheck ledger/order before applying; local promotion is not hosted application. Migration043 is the preceding
   dependency and must remain disabled if applied as a prerequisite; this work does not activate its feed.
   Do not edit or renumber already-applied migrations.
2. Snapshot `store_verifier_policy` for `channel IN ('app','notification')`, including `policy_id`, `enabled`,
   `revision`, `account_hour_limit`, `hour_limit`, `day_limit`, `month_limit`, `retained_limit` and `clock_floor`.
   Use the existing `worker_set_store_verifier_enabled(p_channel, p_expected_revision, p_enabled := false)`
   compare-and-set for both channels and retain its returned revision. Only `enabled` and, when changed,
   `revision` may change; preserve all limits and usage counters.
   Pause other operator/test purchase recorders too. Stopped attempts remain retryable through existing app/Apple
   delivery behavior; do not fabricate purchase acknowledgments.
3. Require ten quiet minutes since the newest **admitted** `store_verifier_starts.started_at`. Count completed
   verifier starts too: successful signature verification precedes financial recording. This exceeds the current
   115-second adapter budget and 400-second Edge runtime, but must be re-evaluated if that runtime changes.
   Inspect `pg_stat_activity` for active or idle-in-transaction calls to `worker_record_store_transaction`,
   `worker_record_store_notification` or their private recorder and require none before proceeding. A request
   timeout alone is not evidence that its database transaction ended. Stop rather than kill unrelated sessions.
4. Take the encrypted backup while paused; recheck the exact zero-subscription inventory, channel states and drain
   evidence immediately before migration. The migration holds policy/inventory table locks and rechecks disabled
   channels, quiet admission and zero history transactionally. **Those locks are not a substitute for draining an
   already-running old PL/pgSQL body.** Any refusal rolls back without changing functions or financial rows.
5. Apply the promoted reviewed migration, verify the ledger and function hashes, and verify existing pack/balance
   records are unchanged. Re-read each channel's current revision and restore its saved `enabled` value through
   that same compare-and-set operation only after successful checks. A revision conflict requires inspection,
   not an unconditional update. A previously disabled channel stays disabled. Do not reset counters or raise caps.
6. Complete separately authorized zero-paid hosted checks; retain local synthetic purchase evidence as such.
   Production subscription, renewal and refund verification still requires a separate StoreKit lifecycle test.

No StoreKit purchase or paid provider call is needed for the SQL review. Applied migrations, live prices and the
platform budget remain intact. This candidate does not introduce a new online rollout or billing-admission system.

## Verification plan

The regression must fail against the unchanged schema before the candidate is applied. Tests use only disposable
`science_reader_test_*` databases on `127.0.0.1:55431`, with inherited libpq overrides removed.

| Case | Required result |
|---|---|
| Standard → Pro, both report orders | Both unexpired transaction grants remain; exact original expiries |
| Upgrade with a reservation / partly spent old period | Existing hold unchanged; no credit minting; settlement once |
| Replays, older/newer signed copies and duplicate notifications | No second bucket/grant/reinstatement |
| Old or new period refunded independently | Only that period loses spendability; in-flight holds survive |
| Old refund reversed before/after upgrade | Exact removed credits restored, original expiry unchanged |
| Natural expiry / first sight already expired | Old credits become unavailable; no new grant or expiry extension |
| First seen refunded, then reversed | At most one eligible grant; expired reversal grants nothing |
| Sandbox upgrade | Standard 800 + at most Pro 200 in one UTC month; two separate caps remain enforced |
| Missing or changed verified Sandbox identity | Zero grant or identity conflict; no new fallback identity |
| Closure / restore to a different account | Recorded history stays closed; a never-recorded valid receipt follows the existing first-grant restore rule |
| Concurrent app/notification upgrade and reservations | Serializable grant/hold outcomes; no deadlock or duplicate grant |
| Schema and role boundaries | No direct client execution of the private recorder/grant; current public service-only boundary |

## Commands and evidence

- `python3 tests/database/subscription_upgrade_credits.py --baseline` fails at the expected policy assertion:
  Standard → Pro leaves 1,800 instead of 2,600. Reproducer/design commit: `0651a61`; evidence
  `.artifacts/subscription-upgrades/baseline.log`.
- `python3 tests/database/subscription_upgrade_credits.py` passes four migration refusals (enabled channel,
  recent completed verification, zero-credit subscription, granted subscription), unchanged function/financial
  fingerprints after refusal, the lifecycle SQL and six real-session races. Evidence: `focused-promoted.log` in that folder.
- The independent reviewer reran the final focused suite in its own randomized databases and reviewed all three
  final function deltas against036, including the malformed-copy and missing-identity cases. No blocking findings.
  Evidence: `independent-focused.log`; exact source comparison: `final-function-diff.txt` and `final-source-proof.json`.
- The new malformed-copy checks cover 22 refused copies across both environments plus a direct missing-expiry
  grant refusal in each. No bucket, ledger, transaction, newest signed state or identity/cap decision changes;
  later valid reversals still succeed within the original Sandbox limits.
- Before promotion, both the explicitly selected candidate suite and complete original-schema suite exited 0.
  Evidence: `full-candidate.log` and `full-baseline.log`. Nothing was skipped to avoid contradictory old assertions.
- Local promotion removes all temporary candidate selectors. `python3 scripts/test-database.py` exits 0 and includes044,
  all 40 existing SQL suites, the new lifecycle suite, every existing migration/concurrency check and the six new
  races. The ordinary purchase and historical-lock assertions require retained credits. The new lifecycle/race
  fixture runs in a separate disposable phase: its real expiry boundary requires committed transactions and
  must not leave an account in older suites that intentionally assert exact global counts. Evidence: `full-promoted.log`.
- The standalone `--baseline` reproducer explicitly loads only migrations before044 and still fails at the
  original 1,800-versus-2,600 assertion; it is not part of the normal success suite. The focused runner separately
  checks migration refusal against that historical schema, then applies044 and tests the retained-credit contract.
  The post-promotion reproduction is recorded in `baseline-promoted.log` (expected exit 1 at that assertion).

Local SQL fixtures do not establish Apple production subscription, renewal, refund or accelerated Sandbox
end-to-end behavior. No hosted mutation, paid/provider call, purchase, price or allowance change was performed.

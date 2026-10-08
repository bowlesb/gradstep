# Subscription upgrade credit retention

Status: design and regression reproduction; isolated candidate, not deployed. The existing approved prices and
allowances stay unchanged. The normal release must receive an independent financial/identity review.

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

Replace the two migration036 private functions in a new, initially `.sql.pending` migration. Remove only those
three upgrade-specific credit restrictions and their obsolete comments/variables. Preserve:

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

No helper override that makes `store_replaced` always false, no dynamic source-string patch at migration time,
and no applied migration edits. Explicit function bodies make the financial diff reviewable. The now-unused
private helper may remain for migration history; callers no longer use it for credit eligibility.

## Existing data and deployment gate

Root's read-only staging inventory at 2026-10-08 06:41:38 UTC found **zero subscription transactions/buckets and
zero `store-superseded` revoked buckets**; the only transactions were three Sandbox packs totaling 1,000 credits.
Evidence: `.artifacts/takeover-20261008/subscription-upgrade-inventory.json` in the main checkout.

Accordingly, this candidate contains **no retrospective grant or bucket rewrite**. Immediately before any later
deployment, repeat the inventory. If affected records have appeared, stop for a separately reviewed repair:
only open accounts, unexpired original buckets, an unrefunded latest verified transaction, and the exact amount
removed by the immutable supersession ledger entry can be considered. Distinguish an existing superseded bucket
from a never-granted replaced period, refund-at-first-sight, missing Sandbox identity, exhausted allowance and
deleted ownership. Replays must not create a general grant escape hatch. Never re-grant expired or forfeited
credits, refund consumed allowance, rewrite ledger history, or blindly clear all revocations.

Deployment sequence: independent review → fresh local schema/upgrade/concurrency checks → current staging
inventory and encrypted backup → assign the reviewed next migration number → apply and verify exact hashes →
zero-paid local/hosted recorder checks as separately authorized. No StoreKit purchase or paid provider call is
needed to validate this SQL. Applied migrations, live prices and the platform budget remain intact.

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
| Sandbox upgrade | Standard800 + at most Pro200 in one UTC month; two separate caps remain enforced |
| Missing or changed verified Sandbox identity | Zero grant or identity conflict; no new fallback identity |
| Closure / restore to a different account | Forfeited old credits stay on closed account; only eligible new periods grant |
| Concurrent app/notification upgrade and reservations | Serializable grant/hold outcomes; no deadlock or duplicate grant |
| Schema and role boundaries | No direct client execution of the private recorder/grant; current public service-only boundary |

The existing purchase and Sandbox suites must pass with their obsolete upgrade expectations updated explicitly.
The existing purchase/account/funding lock suite remains required, including historical closed-account locks.
The full database suite should be run once the focused candidate and independent review pass. Local SQL fixtures
do not establish Apple production subscription, renewal, refund or accelerated Sandbox end-to-end behavior.

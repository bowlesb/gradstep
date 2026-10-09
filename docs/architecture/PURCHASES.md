# App Store purchases

Status, 2026-10-08: **private Node verification deployed; real Sandbox credit-pack grants observed on staging.**
The earlier Edge runtime incompatibility is documented in the
[incident evidence](../reviews/PURCHASE_DIAGNOSTICS_HOTFIX_20261007.md) and repaired by the
[private verifier](PURCHASE_VERIFICATION_RUNTIME.md), with Apple signature and revocation checks intact.
Read-only verification at 05:14 UTC found three Sandbox pack transactions, grants of 400 + 400 + 200 credits,
and successful exact replays. The third reached the 1,000-credit monthly Sandbox allowance. Durable verification
observations and credit records are deployed (033–038); raw receipts are not diagnostic records.
This does not verify production purchases or the full subscription/refund lifecycle.

**Migration036 is deployed:** it closes the concurrent Sandbox identity allowance gap and
requires a current or previously verified app-transaction identity for new free grants.
See [spending controls](SPENDING_CONTROLS.md#sandbox-allowance-implementation-036). The historical upgrade
behavior below still conflicts with the owner's decision to retain earlier period credits;036 does not change it.

Owner decision 2026-10-05: Standard $9.99 = 800 credits a month, Pro $19.99 = 1,800 credits a month, a $4.99
pack = 400 credits that never expire; TestFlight testers get 1,000 credits by operator grant.

## Recorded purchases with no new credits

A verified transaction can be recorded with `credits: 0` when the bounded policy does not admit a grant. The
read-only service-role function `worker_store_zero_grant_reason(account_id, environment, transaction_id)` returns
one of a finite set of explanations without exposing receipt contents or changing the ledger. Sandbox allowance
exhaustion returns `sandbox_monthly_cap`; an absent Sandbox app-transaction identity returns
`sandbox_identity_missing`; an ineligible subscription period returns `subscription_not_eligible`; other zero-grant
cases return `no_credit_grant`. `store-sync` includes that code on the final response, and the native client gives
the owner a specific TestFlight explanation instead of a generic success message. It also performs the read-only
lookup for an `already_recorded` restore, so a receipt submitted by an older app build gets the same explanation.
Migration `056` and the deployed `store-sync` path are live on staging; the owner account's recorded zero-credit
transaction returns `sandbox_monthly_cap`. This diagnostic path does not raise the cap, retry a paid grant, or alter
Production policy.

## Model

**Every verified App Store transaction grants at most one credit bucket, once.** A subscription purchase and
each renewal are separate transactions; each grants that product's monthly credits, starting at the
transaction's purchase date and expiring at its expiry date (plan credits do not roll over). A pack transaction
grants its credits × quantity with no expiry. Holds spend the soonest-expiring credits first, so plan credits are
used before pack credits.

**The newest signed copy of a transaction decides its state.** Every verified copy, from the app or a
notification, attributed to an account or not, updates `store_seen` only if it is newer than what is there, so
an older copy reported later can never undo a refund.

| Event | Effect |
|---|---|
| First verified sight of a transaction | Bind its purchase to an account (below), record it, grant once |
| Same or older copy again (replay, restore) | Nothing |
| Newer copy with a revocation date (refund) | The bucket keeps only credits held by answers in flight; the rest is removed |
| Newer copy without a revocation date after a refund (refund reversed) | The removed credits are restored, or granted if the purchase was first seen already refunded |
| A subscription period that already ended (restored history) or a refunded first sight | Recorded, nothing granted |
| Plan change mid-period (upgrade) | The new plan's credits are granted; the earlier plan's unspent credits end (Apple refunds its unused time). A replaced period reported later grants nothing |
| Renewal-date extension | Recorded (periods up to 400 days); later refunds still apply |
| Sandbox purchase (TestFlight, sandbox testers: free) | At most 1,000 new credits per account and verified Apple app-transaction identity per UTC month. Migration036 serializes admission; missing identity grants zero with an audit reason. Refunds do not replenish the allowance |
| Unknown product, wrong type, family sharing | Refused (`unknown_product`, `unsupported`) |

There is no separate mutable "entitlement" whose state could be regressed by an out-of-order or re-signed
message: the plan shown in Settings (`v1_store_summary`) is the latest unexpired, unrefunded subscription
transaction. Billing-retry and grace states come from StoreKit on the device; no credits are granted for a
period until Apple reports the renewal transaction. This supersedes migration 007's
`worker_record_subscription` (dropped by 018; its tables remain unused).

A refund cannot recover provider spend already incurred; it only removes unspent credits. Partial refunds
are treated as full revocations of the unspent credits. Apple's consumption-information requests (used in its
refund decisions) are not answered yet.

## Ownership

A purchase (its original transaction ID) belongs to one account, bound on first verified sight:

- From the app: the signed-in account. The app sets `appAccountToken` to the account ID on every purchase and
  offers no purchase without it. A token for another open account is refused (`linked_to_another_account`); a
  token for a deleted account binds to the caller. A purchase without a token (for example an offer code
  redeemed in the App Store) binds to the account that first reports it.
- From a notification: the purchase's `appAccountToken`, if it names an open account; otherwise it is logged
  as `unattributed` (its newest state is still kept) and waits for the app to report it.
- Once bound, another open account cannot claim it, and a report from another account is answered
  `linked_to_another_account`. If the bound account was deleted, the next account to report the purchase takes
  it over (future periods only; the deleted account's credits were forfeited).
- The app hides plans when the Apple Account's current plan belongs to another account, so an upgrade bought
  there cannot land on the other account.

## Purchase/account lock ordering (migration036, local)

The spending review reproduced a deadlock between a deleted-account restore and multi-account OCR funding:
purchase ownership's foreign-key checks could lock the new account before the old one while funding locked the
same accounts in UUID order. This affects Production as well as Sandbox and concerns availability/retries, not a
demonstrated duplicate grant.

Migration036 retains018's purchase rules and adds a shared ordered lock protocol. After the Sandbox-only allowance
gate, both environments take a transaction advisory gate, reject inconsistent transaction/original binding, take
that original's advisory gate, and lock all captured accounts in UUID order before ownership/ledger foreign-key
checks. The captured set includes historical transaction owners whose older buckets may be affected by refunds or
upgrades. Unknown attribution remains supported; a late account discovery aborts for retry rather than expanding
the locked set. The detailed ordering and namespace allocation are in
[spending controls](SPENDING_CONTROLS.md#sandbox-allowance-implementation-036).

The applied018 migration is unchanged. Removing only the lock additions from036's replacement recorder yields
018's original purchase body byte for byte; the existing upgrade-credit discrepancy is not changed by this repair.

Local verification: the complete fresh database suite passes, including eight independent-session purchase cases.
Four run actual account-closure, OCR-funding and purchase RPCs together (Production/Sandbox, recorded restore and
first-seen deleted-token binding). Two use the composed funding account-lock prefix to verify historical upgrade
buckets; the remaining cases cover late account creation and conflicting original IDs. Restoring the unchanged018
recorder in a disposable database reproduces the original deadlock under the same actual Production RPC schedule.
Evidence is under `.artifacts/purchase-lock-review/` in the spending worktree; no hosted mutation was performed.

## Verification

`_shared/app-store.ts` uses Apple's `@apple/app-store-server-library` `SignedDataVerifier`: the certificate
chain must lead to the bundled Apple Root CA - G3 (fingerprint checked at load), with Apple's intermediate and
leaf extension OIDs, revocation checked online (OCSP), and the signature verified with the leaf key. The bundle
ID must be `com.sciencereader.ios` and the environment one this deployment accepts: staging accepts
`Sandbox` (TestFlight and sandbox testers) only. Xcode StoreKit-testing data (unsigned, environment `Xcode`) is
never accepted. Production will need `APP_STORE_APP_APPLE_ID` and a decision on whether App Review's sandbox
purchases are accepted there.

The database functions re-validate every field shape and are callable only by the service role.

Apple documents `appTransactionId` as stable for an Apple Account and app across redownloads, refunds, repurchases
and storefront changes. It is distinct from an individual purchase's original transaction ID. Use only Apple's
verified value, including a previously verified value for the same transaction; the app account token is not a
substitute. [Apple app transaction information](https://developer.apple.com/documentation/appstoreserverapi/get-app-transaction-info).

## Flows

- **Entry points**: Settings › Credits › Get credits, and a "Get credits" button beside "Not enough credits" on a
  chat answer and on a Library import that failed for lack of credits (owner approved 2026-10-05). After buying,
  the reader taps Try again (chat) or Retry import (Library).

- **Purchase in the app** (StoreKit 2): the app buys with `appAccountToken = account ID`, sends the signed
  transaction to `store-sync`, and finishes the transaction only when the outcome is final (`recorded`,
  `updated`, `already_recorded`). Anything else stays unfinished. If the server was unreachable or Apple's
  revocation check was (`verification_unavailable`), the app retries after 15 s, 1, 5 and 15 minutes, and
  again whenever it returns to the foreground. Xcode StoreKit-testing transactions are finished on the device
  and never reported.
- **Renewals, refunds, reversals**: App Store Server Notifications V2 to `app-store-notifications` (configured
  per environment in App Store Connect). Each notification is logged once by its UUID; the transaction it carries
  is recorded like one from the app. Database failures and an unreachable revocation check answer 503; Apple
  retries production notifications for several days, but not sandbox ones.
- **App launch / restore**: the app reports unfinished transactions and current entitlements, so a missed
  notification is caught the next time the app opens.

## Still required

- Periodic reconciliation with the App Store Server API (needs an In-App Purchase key, an owner action) to catch
  missed notifications for people who do not open the app.
- Production: accepted environments, App Review sandbox policy, `APP_STORE_APP_APPLE_ID`.
- Apple's consumption-information requests for refund decisions (optional) are ignored for now.
- Sign in with Apple token revocation on account deletion (separate follow-up).

## Verification diagnostics (2026-10-07, local implementation)

The reported purchases have not been verified end to end. The app's old generic message covered
both temporary verification outages and permanently refused data, so it does **not** establish
OCSP as the cause. A public, real Apple signing-certificate chain from Apple's library tests
passes the pinned library's online checks locally in Node 24 and Deno 2.9.6. This is evidence
about those local runtimes, not the deployed Edge runtime or the owner's signed transaction.
The hosted v36 public-root probe subsequently proved missing certificate primitives; see the incident linked above.
This branch preserves its finite runtime/console probes alongside the durable admission and observation records
below. Console failures cannot alter the durable finish or credit recording, and each admitted attempt has at most
one finish and one console observation. Sandbox revocation checks stay enabled. Production configuration must
never disable them.

Migration `202610070038_purchase_verification_observations.sql` adds a separate, bounded
diagnostic record; it does not alter credit grants, StoreKit transaction ownership, or refunds.
Deployment requires the complete ordered migration prefix and a working database cleanup job.

- `worker_store_verification_begin(account, attempt, submission_sha256)` admits one actual
  verification call. Its digest is SHA-256 of a versioned domain, authenticated account UUID,
  and the exact signed submission. Replaying an attempt grants no second call. There are
  50 admissions/account/hour, 1,000/environment/hour, and retained-row caps of 2,048/account
  and 50,000/environment. Unavailable admission leaves StoreKit transactions unfinished.
- `worker_store_verification_finish(account, attempt, outcome, stage, apple_status, transport_code)`
  records finite codes only. No signed JWS, certificate, error message/body, transaction identity,
  Apple identity, or unverified claimed field enters these records. The customer receives the
  same opaque digest as a support reference. An ambiguous finish acknowledgement never causes
  another credit grant; the existing transaction ledger remains authoritative.
- An observation is one admitted attempt, not proof of a purchase. Owner + MFA diagnostics
  group by account-bound submission and show the newest outcome, retries and timings. Different
  signed copies may describe the same purchase. A started attempt older than ten minutes is
  shown as interrupted/unconfirmed, without changing any financial state.
- Observations expire after 30 days and are deleted by a database-only hourly cleanup job;
  admission also makes bounded cleanup progress. Readiness reports the actual schedule, so a
  missing hosted job cannot silently pass deployment checks. Account closure deletes these
  support records. Admission locks the account before the policy; cleanup never locks accounts,
  and account closure never takes the policy lock.
- One temporary Apple verification failure defers the rest of that request's batch. It does not
  make 24 more identical failing OCSP calls or create observations for attempts never made.
- The app retains only bounded, safe outcomes in memory for support. Temporary failures say
  that credits are pending; invalid/environment/refused purchases explain that the server could
  not confirm that purchase. A restored active plan is not inferred from an unverified submission.

The real-purchase regression remains required before calling the purchase flow repaired. No
Sandbox online-check exception, hosted schema change, new purchase or physical-device action is included
in the local evidence above. Apple's reference implementation and test certificate chain are
at [apple/app-store-server-library-node](https://github.com/apple/app-store-server-library-node).

Owner purchase detail now labels a successful verification **Receipt recorded**. Submission counts are neither
sales nor credit grants: several signed submissions may describe one transaction, and a recorded receipt can grant
zero credits. A selected submission opens a separate **Account transaction ledger**. It is account-wide, with no
claim that the opaque submission digest identifies any particular transaction.

The read-only `v1_admin_store_account_transactions(account_id, cursor, limit)` RPC in the still-unapplied migration
038 reads existing `store_transactions`, the account's matching `credit_buckets`, and its latest matching
`store_sandbox_decisions` entry. It does not create financial or diagnostic records or change grant/refund rules.

- Signed-in owner + AAL2 is required; anonymous, service-role, ordinary customer and support sessions cannot call
  this RPC. Apple transaction/original IDs remain inside this access-controlled view. `app_transaction_id`, signed
  JWS and unverified identity claims are not returned.
- Pages default to 25 and cannot exceed 50 transactions. The exact account-bound continuation contains version 1,
  account UUID, UTC `recorded_at`, environment and transaction ID. All fields are validated, including existence
  of the exact boundary row in that account. Descending `(recorded_at, environment, transaction_id)` continues
  through ties without duplicates. Two indexes cover account continuation and the latest account/transaction
  Sandbox decision. Candidate transactions are limited before the bucket/decision joins.
- Each record separates the **original actual credit grant**, **currently spendable** amount, and **reserved**
  amount. Revoked/expired credits have zero spendability while existing reservations remain visible for work in
  progress. Fully spent and future-start buckets are distinguished from a receipt with no grant.
- A matching Sandbox decision shows its finite reason, requested amount, granted amount and UTC allowance month.
  A missing bucket or absent decision never becomes an inferred allowance-exhaustion reason. Production receipts
  do not join Sandbox decisions with a coincident transaction ID.
- Pages show balances at their own read time, not a consistent historical snapshot across pages. The dashboard
  retains one page, offers Older/Newest navigation, and fences results after a new account, selected submission,
  Refresh or page request. Ledger loading/error/retry is independent of the submission's verification history.

Local ledger validation: fresh migrations and the complete database suite, including 170 transactions across
7-row pages with tied timestamps and environments, invalid/cross-account cursors, every access boundary, actual
partial/zero Sandbox grants, refunded/expired reservations and an unchanged financial-record digest. Index plans
are checked after fixture statistics are analyzed. The admin production build and expanded synthetic browser
journey pass; desktop, 390-point narrow and dark ledger captures were visually reviewed. Delayed completions
exercise account/submission/Refresh/page races, alongside empty/error/retry and missing-decision cases. These are
local checks; migration 038 and the dashboard addition still require the coordinated live rollout.

Local checks: all 224 backend tests; 12 purchase tests under both Node and Deno, including
the real SDK against a loopback OCSP responder returning HTTP 503; the database suites and
five independent-session admission/replay/deletion/cleanup races; six StorePurchaseTests on
the iPhone Simulator; iOS/iPad test build; admin production build and the synthetic Purchases
browser journey at desktop and narrow widths, with dark mode and keyboard focus checked.
`scripts/check-purchase-diagnostics.mjs` runs that browser fixture without contacting hosted
services. It does not establish hosted verification or credit delivery.

This change adds no provider purchase or external worker. Each admitted verification adds
two database RPCs (admit and finish), while the hourly cleanup runs inside the existing
database. Each owner ledger page adds one read-only RPC; its two indexes add database storage and write maintenance
to the existing financial tables. Live diagnostic rows are capped; Postgres indexes, WAL and backups still contribute
to the existing database allocation. Review actual database growth after deployment. The
existing $100/month operating budget is unchanged.


Integration checkpoint, 2026-10-07: main `8d716ba` (the deployed v36 finite console/runtime probes and updated
purchase refusal wording) is merged into the local spending-controls branch. The durable 038 admission and
finish calls, opaque support references, batch deferral and owner ledger remain intact. Console observation is
separate and nonfatal; recording errors cannot be recategorized as signature refusals or finish one attempt twice.
Migrations 034–038, grant/refund rules and admin ledger queries are unchanged; uploads 039 are not included.
Combined checks pass: 275 backend tests, 20 focused purchase tests in Node and Deno, production type-checks for
both purchase Edge entry points, the complete disposable database suite with purchase/allowance/observation
races, and six native purchase tests with a compiled empty backend URL/key. Evidence is under
`.artifacts/purchase-main-merge/`. This merge is local and does not repair the incompatible hosted runtime.

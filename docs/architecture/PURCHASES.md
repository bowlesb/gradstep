# App Store purchases

Status: implemented and tested locally (migration `202610050018_app_store_purchases.sql`, Edge functions `store-sync` and
`app-store-notifications`, Settings › Get credits); App Store Connect products created. An independent review's findings were
fixed. Not yet verified with a real sandbox purchase.
Owner decision 2026-10-05: Standard $9.99 = 800 credits a month, Pro $19.99 = 1,800 credits a month, a $4.99
pack = 400 credits that never expire; TestFlight testers get 1,000 credits by operator grant.

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
| Sandbox purchase (TestFlight, sandbox testers: free) | Credits capped at 1,000 per account per UTC month (`store_policy`) |
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

## Verification

`_shared/app-store.ts` uses Apple's `@apple/app-store-server-library` `SignedDataVerifier`: the certificate
chain must lead to the bundled Apple Root CA - G3 (fingerprint checked at load), with Apple's intermediate and
leaf extension OIDs, revocation checked online (OCSP), and the signature verified with the leaf key. The bundle
ID must be `com.sciencereader.ios` and the environment one this deployment accepts: staging accepts
`Sandbox` (TestFlight and sandbox testers) only. Xcode StoreKit-testing data (unsigned, environment `Xcode`) is
never accepted. Production will need `APP_STORE_APP_APPLE_ID` and a decision on whether App Review's sandbox
purchases are accepted there.

The database functions re-validate every field shape and are callable only by the service role.

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
Sandbox revocation checks stay enabled. Production configuration must never disable them.

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

Local checks: all 224 backend tests; 12 purchase tests under both Node and Deno, including
the real SDK against a loopback OCSP responder returning HTTP 503; the database suites and
five independent-session admission/replay/deletion/cleanup races; six StorePurchaseTests on
the iPhone Simulator; iOS/iPad test build; admin production build and the synthetic Purchases
browser journey at desktop and narrow widths, with dark mode and keyboard focus checked.
`scripts/check-purchase-diagnostics.mjs` runs that browser fixture without contacting hosted
services. It does not establish hosted verification or credit delivery.

This change adds no provider purchase or external worker. Each admitted verification adds
two database RPCs (admit and finish), while the hourly cleanup runs inside the existing
database. Live diagnostic rows are capped; Postgres indexes, WAL and backups still contribute
to the existing database allocation. Review actual database growth after deployment. The
existing $100/month operating budget is unchanged.

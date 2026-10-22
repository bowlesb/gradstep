# Dollar balance and OpenRouter usage

Owner direction, October 20: show remaining dollars, each user's complete OpenRouter request log, and a category
view; remove customer-facing credits. **No app markup for now.** This is the implementation design, not a claim
that dollar settlement has been deployed.

Status: design only. Exact dollar settlement, the self-service usage APIs and client dollar screens are not yet
implemented or enabled. The October 20 parity release retains existing accounting on every platform. An unfinished
receipt-precision prototype is retained locally at `.artifacts/parity-20261020/pending-dollar-receipts.patch`;
it was removed from the release source because the deployed receipt RPC does not yet accept its new fields.

Related, built 2026-10-22: **Your AI usage** lists each request's credits and tokens from the existing ledger
(`v1_ai_usage`, migration 0144; [Operations](OPERATIONS_AND_BILLING.md#your-ai-usage--2026-10-22)). It is the credit-unit
precursor of the request log above, not dollar settlement; a dollar column waits on this design and OWNER_ACTIONS #12.

## Financial authority

Retain the existing account-owned funding buckets, append-only financial ledger, allocation order, purchase
ownership/refund rules, platform budget and durable provider attempts. Do not introduce a second mutable wallet
whose balance can disagree with those records.

The existing internal unit represents $0.005 of provider capacity. Permit exact decimal fractions in bucket
balances, ledger deltas and actual operation charges; existing whole-unit history remains unchanged.
Older clients receive a conservative whole-unit projection from `v1_credit_balance`. New clients receive USD
decimal strings and never display this compatibility unit. An existing allowance carries forward its remaining
provider capacity; historical rounded charges are labeled historical and are not rewritten as exact receipts.
Read-only staging inventory found 90 unreserved purchased units and adjustment allowances; inspect transaction
environments before updating purchase grants.

For newly enabled dollar operations, settle from OpenRouter's reported `usage.cost` or generation `total_cost`,
without per-answer ceiling-to-credit rounding. Retain the original decimal cost alongside the existing
conservative integer microdollar budget amount. Validate receipt identity, account, operation, route and bounds.
No client submits a cost. Provider expense and the customer's balance debit are separate:

- Completed answers and explicit user stops are eligible for their associated OpenRouter costs.
- Failed work and platform-funded work remain visible as provider expense without a customer charge.
- Known receipt costs are debited once, identified by attempt UUID and allocated against the operation's holds.
  A cap overrun is absorbed, never an unannounced overdraft.
- A missing receipt is **pending**, not a zero-cost or estimated customer debit. Preserve only the needed hold
  while the provider result is unresolved. A later authenticated receipt settles that same attempt once.
  Rejection releases the unused hold. Retries and concurrent receipt/settlement calls cannot duplicate debits.
- Disabling testing, refunds, account closure and refund reversal must preserve fractional amounts and in-flight
  liability. No balance or testing policy follows a deleted account into a new UUID.
- Unlimited owner testing continues through its audited adjustment bucket; show **Unlimited testing** and actual
  usage, not an invented infinite dollar balance. Shared OpenRouter funds and platform limits remain finite.

No-markup pricing refers to reported generation charges. OpenRouter funding fees, App Store fees and other
platform overhead are not silently added to individual generation costs. They remain operating expenses under
the existing budget. Published purchase intervals are not changed by replacing credit labels; each reviewed USD
offer must grant the same USD usage amount it advertises, with its existing expiry/refund terms stated plainly.

Provider references checked October 20:
[Usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting) describes `usage.cost` as
the account charge; [generation metadata](https://openrouter.ai/docs/api/api-reference/generations/get-request-&-usage-metadata-for-a-generation)
provides the asynchronous receipt. [OpenRouter pricing](https://openrouter.ai/pricing) separates funding fees from
per-request inference charges. Do not use upstream BYOK cost or a rate-card estimate as the user's receipt.

## Read model and access

An authenticated reader sees only their current account. Server RPCs derive the UUID from the authenticated
actor; there is no caller-selected account parameter. Keep the existing owner/MFA investigation APIs separate.

The balance summary includes available USD, reserved USD, testing status, receipt coverage and category totals.
A keyset-paginated request history includes every recorded OpenRouter attempt for that account: UTC start/end,
category, feature, requested/served model, provider, operation/attempt/generation IDs, numeric token usage,
reported cost, precision/source, outcome and balance debit. Include zero-cost refusals and platform-paid work;
distinguish admission without dispatch. Do not expose prompts, answers, titles, paper text, raw errors or secrets.

Category totals are computed over the complete selected history, not just loaded pages. Categories cover chat,
equations, figures, diagrams, study, podcasts, titles/suggestions and catalog metadata. Preserve an explicit Other
category for future features. Account-bound cursors carry a snapshot boundary and selected category and validate
their boundary row; concurrent inserts cannot duplicate or skip older entries. Late receipt updates remain
visible on refresh and are not represented as an immutable historical snapshot.

Costs below one cent display enough precision to be useful; an unknown cost never prints `$0.00`. A request's
provider expense is not necessarily its balance debit. Historical operations that lack per-attempt debit
attribution expose the operation debit separately rather than distributing an invented charge across calls.

## Clients and rollout

The same account APIs and formatting rules serve iPhone, iPad, Mac and browser. Settings opens **AI balance**,
with remaining balance, reserved work, a request log and category totals. History loading, empty, error/retry,
pagination and account-switch cancellation are explicit. The owner testing state still opens the usage log.
The backend is authoritative even if an older installed app continues to use credit terminology.

Use an additive migration with dollar charging initially disabled. Verify populated upgrade, exact decimal
settlement, late receipts, idempotency, concurrency, isolation, deletion and refund behavior locally. Back up
staging before applying; deploy receipt-aware transports and verify them before enabling the audited billing
policy. Do not enable a mode in which existing workers systematically leave completed requests awaiting receipts.
Read back the deployed policy and perform bounded validation. No additional infrastructure commitment is needed.

## Acceptance

Required evidence includes charges smaller than one compatibility unit, exact $5 funding/remaining balance,
multiple attempts and categories, more than one history page, simultaneous receipt and settlement, a repeated
receipt, refund/reversal of a fractional balance, unknown then rejected/confirmed calls, stale-account completions,
and the unchanged global provider cap. Native and browser screen checks must cover ordinary and unlimited
accounts without contacting a paid model. Release status belongs in IMPLEMENTATION_STATUS.md only after readback.

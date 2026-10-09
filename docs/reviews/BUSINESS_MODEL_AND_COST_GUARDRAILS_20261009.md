# Business model and cost guardrails

2026-10-09. Proposal for making Gradstep sustainable without making normal research
feel rationed. This document is a recommendation; it does not change prices,
credit grants, provider routing or subscription terms.

## The business we should build

Gradstep should sell a reliable research workspace, with metered AI work included
in a transparent allowance. The subscription pays for the library, sync,
equation-aware reading, chat, support and the infrastructure that makes them
reliable. Credits are the common budget for work that has a provider cost. They
are not presented as dollars and they are not an unlimited promise.

The product should make the low-cost path the easiest path:

- reading, metadata, library search, tags, reading state and shared podcast
  playback should feel like ordinary included product features;
- an eligible paper converted once can be reused by other readers, so Mathpix
  cost is not multiplied by every account;
- a chat reuses the paper cache and charges only measured provider usage;
- a failed or quality-rejected paid operation charges no customer credits;
- a private podcast uses the same measured-credit system as other metered work;
  the shared catalog is the free first choice.

This is a better long-term proposition than hiding the cost in an unlimited
plan. One unusually large paper, repeated search, or a long podcast must never
turn a fixed subscription into an uncapped vendor bill.

## Current unit economics

The current beta rate card treats one internal credit as **$0.005 of reserved
provider-equivalent cost**. It is deliberately separate from the retail value
of a credit in an Apple purchase:

| Offer | Gross price | Credits | Provider-equivalent allowance | Gross less provider allowance | Gross less provider allowance after 30% platform commission |
|---|---:|---:|---:|---:|---:|
| Standard monthly | $9.99 | 800 | $4.00 | $5.99 | $2.99 |
| Pro monthly | $19.99 | 1,800 | $9.00 | $10.99 | $4.99 |
| Credit pack | $4.99 | 400 | $2.00 | $2.99 | $1.49 |

The last column is a conservative sensitivity case before taxes, refunds,
fixed infrastructure, support, platform-funded work and unresolved provider
liability. At a 15% commission the corresponding cushions are $4.49, $7.99
and $2.24. These are not net-profit claims; they show why the product cannot
promise every customer unlimited expensive work.

The allowance is intentionally larger than the average provider bill because
many customers will not consume all credits. That unspent capacity is what lets
the product feel generous. The margin must be measured by cohort, however:

```
net customer proceeds
  - settled provider expense
  - platform-funded quality and tagging work
  - infrastructure and storage allocation
  - refunds, support and payment losses
  - expected unresolved liability
= contribution margin
```

The admin Spending page already separates customer debits, provider expense,
uncertain liability and dated overhead evidence. We should use that ledger for
this calculation rather than treating a credit debit as revenue or a provider
hold as an invoice.

## What customers should see

The customer-facing explanation should be short and consistent across iPhone,
Mac and web:

1. **Before an expensive action:** show an expected range, the hard maximum,
   and the rule that an unsuccessful quality-checked operation is not charged.
2. **After it finishes:** show “held / used / released”, for example “150 held ·
   58 used · 92 released”.
3. **In the credits screen:** show capacity examples, not a token-price essay:
   “about 1 credit per new Mathpix page”, “a typical paper chat is a few to a
   few dozen credits”, “shared episodes use no generation credits”.
4. **At 50%, 80% and 100% of a plan:** show a calm usage summary and the next
   option. Do not interrupt reading with a sales prompt.
5. **In the information page:** explain that provider names and models can
   change only behind a quality and cost review, and that the service never
   uses a user's credits twice for a replayed provider attempt.

The user should not need to understand cache tokens, provider reservations or
Apple's commission to decide whether to ask a question. Those details belong
in the expandable cost and privacy explanation and in the owner dashboard.

### Seamless batch behavior

The most damaging failure would be allowing a user to start five long episodes,
let the first few consume the balance, and only then reveal that ordinary chat
and reading actions cannot continue. Every action that can fan out into several
paid operations needs a preflight:

- calculate the expected total and the hard maximum for the whole batch;
- show how many jobs are affordable now and the balance left afterward;
- offer “start the affordable set”, “add credits”, or an explicit “use my
  remaining balance” choice;
- create holds and queue jobs one at a time, so a later job cannot spend money
  that an earlier job has already reserved;
- keep an unactioned remainder in a visible queue and resume it when credits
  are added, without making the user re-enter the request.

For a single expensive job, use a soft everyday reserve (a percentage and
minimum chosen from measured usage, rather than a permanent magic number). If
an action would consume that reserve, explain the consequence and let the user
override it. The reserve is a calm protection against an accidental all-day
batch, not a hidden denial. If the user deliberately chooses to spend the
remaining balance, the confirmation should say what ordinary actions will wait
until more credits arrive.

This same pattern applies to large imports, repeated chat actions and future
batch tools. It makes the cost boundary appear before the irreversible work,
while the existing credit-resume sweep handles the normal case where a user
later buys or receives more credits.

## Podcast policy

Episodes should initially be a retention feature, not the main profit center.

- Existing shared episodes are free to play and download after authentication.
- Private generation uses the ordinary measured-credit path, with no separate
  podcast markup. The recent five-minute examples used 55–60 credits; the
  current 150-credit maximum is a safety hold, not the expected price.
- Short, ten-minute and twenty-minute generation remain optional until there
  are enough measured runs to publish observed median and p90 costs. Their
  current maxima are safety limits, not promises about typical usage.
- A curated catalog may spend a small, explicit platform budget (the current
  proposal is $3/month inside the existing provider cap) because one episode
  can serve many users. Every generated episode still needs review, provenance
  and a cost record.

“At cost” should mean “no podcast surcharge and settlement at measured
provider-equivalent usage”, which is already the private-generation behavior.
A literal dynamic App Store charge is a poor fit because Apple products are
fixed, taxes and fees are separate, and a provider can return an uncertain
outcome. If the engagement effect is strong after 10–20 measured episodes, the
safe experiment is one included five-minute generation per paid plan per
month, versioned as a separate allowance. Further episodes use ordinary
credits. The experiment must have a monthly platform subsidy cap and be
reversible without changing the value of existing subscriptions or packs.

## Tiers and monetization

Keep the current Standard, Pro and nonexpiring pack until we have a real usage
cohort. Do not lower allowances or raise podcast prices because a maximum hold
looks large. Instead, evaluate these later additions in order:

1. **Standard** for an individual reader who imports and discusses papers each
   week. Its examples should emphasize a mix of reading, OCR and ordinary
   chats.
2. **Pro** for a researcher who works most days, uses longer answers or makes
   occasional private episodes. The value is headroom and priority, not a
   different privacy promise.
3. **Packs** for an occasional burst, with no expiry and no requirement to
   upgrade a subscription.
4. **Team/lab** only after the individual ledger is stable. It should pool a
   bounded credit allowance across seats and expose an administrator's usage
   view; it should not begin as an unlimited plan.

The free experience should be useful but bounded: browse metadata, open shared
catalog items, read locally available content, and try the product. Expensive
conversion and model work should require a verified account and an explicit
credit quote. This creates a real upgrade path without putting the company at
risk through anonymous use.

## Stop-loss rules before public launch

These are operating rules, not user-facing scare copy:

- Set a combined Science Reader monthly ceiling across staging and production,
  with a separate smaller beta ceiling. A per-database budget is not the same
  as the owner's total budget.
- Keep provider admission disabled when the dated allowance, invoice evidence
  or unresolved-liability headroom is stale. Never infer a vendor limit from an
  empty queue.
- Cap per-account paid work by credits, request rate, concurrent operations,
  source pages, storage and delivery. Keep retries bounded and never retry a
  paid step automatically.
- Keep unknown provider outcomes quarantined as liability until reconciled;
  do not release a hold merely because a worker timed out.
- Alert on any provider attempt without a reservation, any customer debit
  without a provider operation, excessive quality-loss subsidy, storage or
  egress anomalies, and a customer whose provider cost is far above the cohort
  p95.
- Pause new paid work before the fixed-cost budget is exhausted. Existing
  readers can still open local and shared content while the operator resolves
  the cause.

The owner dashboard should show a simple “safe to admit” state derived from
these checks, alongside the detailed ledger. A dashboard warning is not itself
a spending control; admission must enforce the same policy in the database and
workers.

### Owner testing

The owner needs to exercise long and repeated workflows without repeatedly
buying Sandbox products. Staging therefore uses an explicit, audited owner
grant rather than an `unlimited` branch in customer billing. The current
staging owner account has a 100,000-credit test grant (2026-10-09); it is
nonexpiring and visible in the credit ledger. Provider admission, platform
budgets, rate limits, storage limits and unresolved-liability handling still
apply. This gives the owner practical freedom to test while preserving the
same failure and accounting behavior that customers will encounter.

Production has no equivalent bypass. If the test balance is exhausted, a new
audited grant is the deliberate operator action; an automatic infinite refill
would hide real cost regressions.

## Decision gates

### Gate 1: before public launch

- 10–20 successful podcast runs per profile, with median and p90 provider cost;
- a representative month of chat, search, OCR, retry and quality-failure data;
- a real Apple Sandbox and production receipt/purchase acceptance path;
- a reconciled forecast for both environments and every fixed invoice;
- a cohort report showing provider expense per paying account and the fraction
  of customers who consume 25%, 50%, 75% and 100% of their allowance.

### Gate 2: after the first paying cohort

Review at 25, 50 and 100 paying accounts. Keep the plans if the p90 paying
cohort remains contribution-positive after the conservative commission case,
platform-funded work and fixed allocations. If not, change the cheapest cause
first: improve cache reuse, share eligible OCR, route a quality-tested simple
task to a cheaper model, or tighten an unusually abusive path. Do not silently
change a model or reduce an allowance for existing customers.

### Gate 3: podcast subsidy decision

Only add an included five-minute episode after shared listening, return visits
and episode completion show a retention benefit. Fund it from an explicit
monthly engagement budget; stop or revise it if the p90 subsidy, not the
average, threatens the plan margin. Keep a shared episode free even if private
generation is paused, so the retention loop survives a cost incident.

## Recommendation

Keep the current prices and credit grants for the beta. Finish the cost
explanation and observed-versus-maximum quote work, collect the measured
cohort, and keep podcasts on the no-markup measured-credit path. Treat one
included private five-minute episode as a reversible later experiment, not as
an unlimited feature or a new App Store product. This gives users a generous,
understandable product while ensuring every expensive path has a bounded
liability and an owner-visible stop condition.

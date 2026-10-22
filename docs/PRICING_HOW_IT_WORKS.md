# How Gradstep pricing works

For the owner, in plain words. Accepted 2026-10-22 ([DECISIONS](DECISIONS.md#pricing-accepted-with-safeguards-against-spend-outrunning-income-owner-2026-10-22-built-staging));
the numbers come from the [pricing proposal](proposals/PRICING_PROPOSAL_20261022.md). If spend looks high, go straight to
the [spending runbook](RUNBOOK_SPENDING.md).

## The whole system in five sentences

1. **Reading is free.** Papers, library, sync, notes, the Feed and offline copies run on the device and cost almost nothing.
2. **AI uses credits.** One credit is half a cent of model cost; a typical Gemini Flash answer is about 3 credits.
3. **People buy credits from Apple**: Plus (600 a month), Pro (2,000 a month) or a pack (300 or 700, never expire).
   They prepay with a margin, so their AI use pays for itself.
4. **Free accounts get 50 credits a month** for the fast models. All free accounts together share one **free pool of
   $15 a month**, which is the most free AI can ever cost you.
5. **Before any AI call, the server reserves its worst-case cost** against three limits: the reader's credits, the month's
   provider limit (October: $40) and, for free credits, the free pool. If a limit can't take it, the call never happens.

## What readers see

| | Free | Plus | Pro | Packs |
|---|---|---|---|---|
| Price | $0 | $7.99/month or $79.99/year (first month $3.99) | $19.99/month or $199.99/year | $4.99 = 300, $9.99 = 700 |
| AI each month | 50 credits (about 15 answers), fast models only, while the month's free AI lasts | 600 (about 200 answers) | 2,000 (about 650 answers) | Never expire |
| Sonnet, Opus, podcasts, web search | No (a pack unlocks them) | Yes | Yes | Yes |

In the app, Settings › AI credits shows **Plan** (Free, Plus, Pro) with an ⓘ that says exactly this:

> Reading papers is always free. AI uses credits.
>
> Free: 50 credits a month (about 15 answers) with the fast models, while this month’s free AI lasts.
> Plus: 600 credits a month (about 200 answers), every model.
> Pro: 2,000 credits a month (about 650 answers), every model.
> Credit packs: 300 or 700 credits that never expire.
>
> Plan credits renew each month and don’t carry over. Prices are shown in Get credits.

A free reader also sees **Free AI this month: 32 of 50 left**. When the pool is used up they see *"This month’s free AI
has all been used. It comes back on November 1. Reading is unaffected, and a plan or credit pack works right away."*
The browser says the same, pointing to the app for purchases.

## The moving parts (all existing machinery, one new rule)

| Part | What it does | Where |
|---|---|---|
| Credit buckets | Each grant (free month, plan month, pack, your testing allowance) is a bucket; spending takes the soonest-expiring first | migrations 003, 094, 0150 |
| Hold → settle | Each AI request holds its maximum, then is charged what it actually cost | `worker_reserve_operation` |
| Provider limit | The month's hard cap on all model spend; a pause switch | `platform_budgets`, Admin › Overview |
| **Free pool** (new) | Free-funded requests are marked; their worst case must fit $15 a month, $0.25 per account, 20 credits a day | `ai_controls`, migration 0150 |
| App Store | Apple's signed transactions are verified and grant credits; refunds take unspent credits back | `store-sync`, `app-store-notifications` |
| Spend vs income (new) | This month's spend by who pays, feature and model, next to estimated proceeds | Admin › Spend vs income |
| Alerts + switches (new) | Email at 50/80/100% and when the pool or the spend/income ratio trips; switches to stop the expensive part | [RUNBOOK_SPENDING](RUNBOOK_SPENDING.md) |

What you decide, and where: the provider limit (`scripts/pipeline-ops.py budget`), the free pool and the switches (Admin ›
Spend vs income, owner with two-factor), prices (App Store Connect). Nothing raises a limit by itself.

## Why spend can't run away from income

- **Paying readers prepay.** A credit sells for 1.7–2.8× its model cost after Apple's 15%. Their spend is already paid.
- **Free readers share a capped pool.** $15 a month whatever the number of accounts; new accounts only split it thinner.
- **Everything shares the provider limit.** Even a bug or abuse stops at the month's limit (October $40), and the
  OpenRouter key's own credit limit is the external backstop (OWNER_ACTIONS).
- What is **not** capped by this: fixed costs (Supabase, Tavily, domains). They are recorded on Admin › Spending and
  shown beside the ratio.

## App Store: the plan awaiting your approval

Nothing in App Store Connect has been changed. The read-only plan (`node scripts/asc-pricing-plan.mjs`, read back
2026-10-22, `.artifacts/pricing/asc-plan-readonly-20261022.txt`) found Standard $9.99/800, Pro $19.99/1,800 and the 400
pack, and lists these changes:

| # | Change | Product |
|---|---|---|
| 1 | Description "2,000 AI credits each month" | `com.sciencereader.ios.pro.monthly` ($19.99, unchanged) |
| 2 | Create Pro yearly, $199.99, level 1 | `com.sciencereader.ios.pro.annual` |
| 3 | Rename "Standard" → "Plus", description "600 AI credits each month" | `com.sciencereader.ios.standard.monthly` |
| 4 | Price $9.99 → $7.99 (existing subscribers move at renewal) | `com.sciencereader.ios.standard.monthly` |
| 5 | Introductory offer: first month $3.99, pay up front | `com.sciencereader.ios.standard.monthly` |
| 6 | Create Plus yearly, $79.99, level 2 | `com.sciencereader.ios.standard.annual` |
| 7, 8 | Create consumables 300 ($4.99) and 700 ($9.99) | `com.sciencereader.ios.credits.300`, `.credits.700` |
| Manual | Remove the 400 pack from sale; enroll in the Small Business Program; review screenshots for new products; submit them with the next app version | App Store Connect web UI |

To apply after you approve: `node scripts/asc-pricing-plan.mjs --apply --owner-approved=2026-10-DD`, then run it again
without `--apply` to read the result back. The server already grants the new allowances (migration 0150), and the apps
already list all six products (StoreKit shows only the ones on sale), so the order doesn't matter. Existing Sandbox
purchases of Standard and the 400 pack keep working; a Standard renewal now grants 600 credits.

## Known limits

- **Proceeds are an estimate**: verified transactions × the configured US price × 85%. Not Apple's financial report (no
  VAT, currency or payout timing). Apple's Sales and Trends report is the source of truth.
- The free allowance is per account, not per Apple ID: new accounts on one device each get 50 credits, but they all
  draw on the same $15 pool.
- One account's $0.25 share is checked before each request (a request is admitted while the account is under it), so
  its last request can take it slightly over; the $15 pool is checked against every request's full worst case and is
  never passed.
- Free answers don't search the web. If an older chat function were deployed again, it could offer search on a free
  answer; the pool still pays for and bounds it.

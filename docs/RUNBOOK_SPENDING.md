# Runbook: AI spend is high compared with income

For the owner. Start here when an alert email arrives or Admin looks wrong. How pricing works:
[PRICING_HOW_IT_WORKS](PRICING_HOW_IT_WORKS.md). Design: migration 0150 and [SPENDING_CONTROLS](architecture/SPENDING_CONTROLS.md).

## The layers that already protect you

| Layer | What it stops | Where you see it |
|---|---|---|
| Reader credits | A reader can't spend more than they hold; every request holds its worst case first | Admin › Costs, per account |
| Free pool | Free AI can't cost more than the pool ($15/month) | Admin › Spend vs income › Free AI pool |
| Provider limit | All model spend stops at the month's limit (October $40) | Admin › Overview › Provider spending |
| Alerts | Email at 50/80/100% of the limit, free pool used up, spend above 0.6× proceeds | Your inbox; Admin › Spend vs income › Alerts |
| Switches | Stop the expensive part without stopping everything | Admin › Spend vs income › Safety switches |
| OpenRouter key limit | Stops OpenRouter itself if everything above failed | openrouter.ai › Settings › Keys (OWNER_ACTIONS) |

Alerts are evaluated by the database every 10 minutes and each kind is emailed at most once a month; the Alerts list
shows whether it was emailed. They go to `OWNER_ALERT_EMAIL` (in `.env.staging`, written to Vault by
`scripts/deploy-staging.py`) or, when that is unset, to the owner account's sign-in address.

## Symptoms → where to look

| Symptom | Look at | What it tells you |
|---|---|---|
| "80% of the provider limit" email, early in the month | Spend vs income: **Forecast to month end** and **By who pays** | Whether the month will run out, and who is spending |
| "Spend high vs income" email | Spend vs income: **Spend ÷ proceeds**, **By who pays** | High **Paid** share is fine (prepaid with a margin). High **Free**, **Your testing**, **Granted** or **Platform** is money you fund |
| "Free AI pool used up" email | Free AI pool: readers using it, Spend vs income › By feature | Normal if many new readers; abuse if few accounts used most (check Costs) |
| One feature dominates | Spend vs income › By feature, then **By model** | e.g. podcasts or Sonnet figures loading whole papers into the cache |
| One account dominates | Admin › **Costs** (sort by This month) | A heavy paying reader (fine), a tester, or abuse |
| Spend with no reader activity | Admin › **Spending** (unresolved attempts, held liability) and **Health** › Attention (overruns, reconciliation) | Stuck or unreconciled provider attempts, not real use |
| Proceeds look wrong | Spend vs income › Income by product, then App Store Connect › Sales and Trends | The estimate counts verified transactions at configured US prices; Apple's report is the truth |

## Actions, in order of least effect on readers

Each switch is in Admin › Spend vs income (owner with two-factor). Press **Preview** first: it shows how many requests,
accounts (and paying accounts) and dollars the switch would have stopped in the last 7 days. Every change needs a
reason, is written to the audit log, and is undone with the same button.

1. **Do nothing yet** if the **Paid** share explains the spend and the forecast stays under the limit: paying readers
   are covering it.
2. **Fix stuck spend**: Admin › Spending › unresolved attempts; `python3 scripts/pipeline-ops.py attempts` lists them;
   the automatic reconciler settles OpenRouter ones (Health › Attention shows any it can't).
3. **Shrink the free pool** (Free AI pool › Set pool) if free use is the cost; readers see "free AI comes back on the
   1st" sooner. Paying readers are unaffected.
4. **Pause free AI** if free use looks like abuse. Free readers see "Free AI is paused for now."
5. **Pause one feature**: podcasts, recommendations, figures or equations, whichever By feature points at. Readers of
   that feature see "AI is paused"; everything else works.
6. **Cheaper models only**: every default becomes Gemini Flash; Sonnet and Opus say they are unavailable. Use when By
   model shows premium models driving cost (for example first-on-a-paper cache loads).
7. **Pause all AI**: every AI request says "AI answers are paused right now." Reading, library and sync are untouched.
   This is the existing switch (also on Overview) and holds across the month boundary until you resume.
8. **Lower the provider limit** for the month: `python3 scripts/pipeline-ops.py budget --usd N --actor <owner id> --reason "…"`
   (audited). Never needed to stop spend (pausing does that); use it to change the month's ceiling.
9. **Account-level**: Admin › Accounts › disable sign-in for an abusive account (ends its spending and any testing
   allowance).

If you can't reach Admin: OpenRouter's key limit stops all model calls (openrouter.ai › Keys › edit limit, or disable the
key). Readers then get "AI answers are paused" style errors and are not charged for unfinished answers.

## How to verify it worked

- The switch shows **On** and the Alerts/audit log has your reason (database: `app_private.admin_audit_events`,
  action `ai_switch` or `free_pool`).
- Spend vs income: refresh after 10–15 minutes; **AI spend this month** stops growing in the paused feature
  (By feature), and **held** falls as in-flight requests finish.
- Admin › Costs: the account or feature you targeted has no new calls.
- For the free pool: a free account's balance shows the free AI message (Settings › AI credits › Free AI this month).
- Resume in the same place when it's over; the preview tells you what readers will get back.

## Things to know

- Proceeds are an estimate (verified transactions × configured US price × 85%), Production only; Sandbox purchases are
  test money and never count. The ratio is blank until real Production income exists.
- The forecast is a straight line from the month so far; it is marked "early in the month" for the first three days.
- Fixed costs (Supabase, Tavily, domains) are not in the ratio; record them on Admin › Spending so the footnote shows them.
- The figure/equation switches are enforced by the chat function, and as a backstop by the database for podcasts,
  recommendations, premium models and free AI. If an older chat function were deployed, use **Pause all AI** or
  **Cheaper models only** instead of the figure/equation switches.

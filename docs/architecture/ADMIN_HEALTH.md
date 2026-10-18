# Service health in the admin (2026-10-15)

**Live on staging, 2026-10-15:** migration `202610150069_admin_health.sql` applied and verified; admin Pages
`b71d1f6a` at `https://admin.gradstep.ai/#health/30`. Called as the owner on staging (rolled-back transaction): 1 real
account, 97 papers added, 58 chat answers, 22 podcast episodes (16 failed, 10 of them the script's evidence check),
$25.06 provider spend this month, 25 % of chat input read from the prompt cache. Fixture: `?fixture=health` in the
admin dev server (a service growing to about 1,000 accounts at staging rates; `&state=quiet`, `&state=empty`).

Owner: "imagine there are 100 users that added the app and it looks like it could be 1000. Imagine the graphs I need
to monitor, what are they, how do I access them, does it feel seamless? Please build."

## What to watch, and why

The admin's **Health** tab (the first tab for the owner at `https://admin.gradstep.ai`) answers four questions at a
glance, each over 7, 30 or 90 days, with daily points and a headline for the window:

| Question | Graphs | Source |
|---|---|---|
| **Are people coming and staying?** | Accounts and sign-ups per day; active accounts per day; 7- and 30-day active; returning this week | `app_private.accounts` with their Auth user; `app_private.account_activity_days` (below) |
| **What do they do?** | Papers added per day; chat answers and chatting accounts per day; podcast episodes started per day | `import_requests`, `metered_operations` (chat), `podcast_jobs` |
| **Is it working?** | Paper adds that failed (and why); chat answers settled vs not; podcast jobs failed (and why); open support reports | the same tables, `support_reports` |
| **What does it cost?** | Provider spend per day by provider; month to date against the budget and a straight-line forecast; spend per active account; credits consumed and granted; the chat's prompt-cache share | `provider_usage_events`, the platform budget, `credit_ledger` |

An **Attention** list heads the tab: the month's forecast over its budget, paper adds failing (over 10 % in a day with
at least 5), podcast failures, open reports. Every number has its window and definition beside it.

What the server cannot see is said on the page, not guessed: reading happens on the device (the arXiv HTML is fetched
and compiled there), so a reader's preparation failures reach the owner through TestFlight and support reports only.
Counting them would need a new, consented device report; that is a separate decision.

**Added 2026-10-16 (migration 079, [RESILIENCE.md](RESILIENCE.md#fix-1-and-early-endings-as-built--2026-10-16)).**
Attention lists operations that cost more than their ceiling in the last 24 hours (recorded, not paused; the largest,
and how many count toward the hourly tripwire), says when the tripwire paused new paid work, and names any real
account with more than 20 answers that ended early without charge today, with what Gradstep paid (they are still
served). "Is it working?" shows answers not charged over the window and the provider cost Gradstep absorbed for them
(`v1_admin_health.early_endings`; `anomalies`). Not yet deployed to `admin.gradstep.ai`; the database side is live on
staging.

## Who counts

**OpenRouter cutover, 2026-10-18:** the billing-refusal alert's provider groups retain their historical/logical
model identity; they are not necessarily the service charging the account. The alert now names OpenRouter as
the current model gateway and directs the operator to Spending's attempt transport/receipt details. It must not
tell an operator to top up Anthropic directly for a routed Claude request. No old ledger entry is relabeled.
Admin Pages **a0540bb2** is deployed; the production build gates pass and the new wording was verified in live assets.

Test accounts are left out of the people and use graphs: an Auth address ending `@example.invalid` (the live smoke
scripts) or `@example.test` (fixtures). Accounts are counted while open. Spending includes everything, since tests
cost real money; the page says so.

## Active accounts: a daily rollup

`app_private.api_rate_windows` already records each account's requests per hour and route, but it is a limiter, kept
two days. Active-account history needs its own rows:

`app_private.account_activity_days (day date, account_id uuid, routes text[], primary key (day, account_id))` — one row
per account per UTC day it used the service, with the routes it used (`library-read`, `sync-write`, `chat`, …). A
trigger on `api_rate_windows` adds the row (and a route not yet listed) when a window is created or counts up; a row
that already lists the route is not rewritten. Rows older than 400 days are deleted once a day by the same trigger.
Backfilled from the rate windows, synced events, paid operations and paper adds already stored.

Privacy: this is service metadata the limiter already holds (an account id, a day and route names), retained longer
and only for these counts; no content, device or address. It is private to the database (no grants); the admin reads
aggregates through `v1_admin_health`, never rows. Account deletion removes the account's rows.

## Access

`public.v1_admin_health(p_days)`: owner with MFA (`app_private.is_operator('owner')`), as every admin metric. The
admin keeps its sign-in (password, then the authenticator code); the session stays signed in on that browser until it
expires. To make it feel like an app: the admin has a web manifest and icon, so "Add to Home Screen" on the iPhone
opens it full screen; the Health tab refreshes itself every minute while open; the URL remembers the tab and window
(`#health/30`). The iPhone, iPad and Mac apps show "Operations dashboard" in Settings, and the browser reader in its
account menu, for an owner or support account (roles from `v1_account_context`; the owner lands on Health, support on
Support). The link only opens the site, which checks for itself. Journeys: `SettingsTests/testOperationsDashboardRowIsForOperatorsOnly`
(`--operator-fixture`, Debug only), `e2e/support-reports.spec.ts`.

## What it cannot see

- **Papers prepared on the device.** The reader is made on the device from arXiv's HTML (or the on-device model); a
  paper that fails to open never reaches the server. TestFlight feedback and support reports carry those; the tab says
  so. A device-side failure count would need an opt-in diagnostic event, a separate decision.
- **Per-person cost from the Health average.** Use Spending's account UUID filter and individual attempt details
  for that investigation (OpenRouter transport/receipts added 2026-10-18). Spend per active account on Health is
  the window's spend over accounts active in 30 days, a straight line
  to 100 and 1,000 accounts. At staging rates (a chat answer about 2.5 ¢ with the paper cached, an episode about 11 ¢),
  1,000 accounts chatting like the fixture cost about $400 a month, four times the $100 provider budget; the server's
  budget limit pauses paid work before that, and the Attention list says so first.

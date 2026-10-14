# Cost and credit system, and sync reliability: audit — 2026-10-14

Owner request: "audit the cost and credit system and try to identify gaps… What about issues with syncing, does it
work reliably?" Read-only review of code, migrations, tests and docs, plus read-only staging queries. Nothing here
is fixed yet; each item has a proposed fix and a rough size. File references are to the tree at commit `453d6ed`.

## Cost and credits

**What holds up (verified).** Holds and settlement are idempotent per operation id and amounts; a replayed operation
never reaches the provider; holds and settlement spend the soonest-expiring buckets first; the platform budget's
`spent` is kept in step with provider attempts at settlement and by late results; purchases grant once per signed
transaction with refund, reversal and upgrade handling; the Anthropic rate card in `anthropic.ts` matches the
provider's price page as of today; the published profile table is the client's estimate by construction. No
double-charge path was found. Staging ledger (read-only): 315 operations, all settled; 139 credit buckets with no
over-reservation, negative balance or expired bucket holding credits; chat ceilings average 82× the actual cost
(median 63×; average ceiling 185 credits, average actual 10).

Ranked gaps:

1. **Aborted or dropped answers accumulate platform liability with no release tool.** Every Stop, deadline or
   dropped stream ends its attempt `unknown` and its whole ceiling stays in `platform_budgets.reserved`, counted at
   every later reserve; `worker_provider_attempt_reconcile` has no caller. With the budget at $21.03 of $25, a few
   Stops can refuse everyone (`platform_budget_exhausted`). Fix: an admin "resolve attempt" action and a script;
   auto-resolve aborted chat attempts from `message_start` usage when a message id exists. ~8 h.
2. **Failed answers are charged, invisibly.** A provider error after send bills the input estimate at the uncached
   rate (one token per UTF-8 byte, 3–4× real: about 64 credits for a 27-page paper outage); the client only says
   "Try again" and shows no cost. Fix: charge nothing when no `message_start` arrived, bill aborts at observed input
   plus visible characters ÷ 3, send `credits` with the error event and show it. ~6 h.
3. **The hold floor refuses readers the estimate says can pay.** `FALLBACK_HOLD_FACTOR = 3` × byte-count tokens at
   the cache-write rate plus the full output allowance gives about 108 credits for DPO (245 with search) while the
   composer shows "Usually 4–24 · up to 37"; `HOLD_CAP_MINIMUM_CREDITS = 50` refuses paper chat under 50 credits and
   holds a 50–107 balance whole for one answer. Fix: size input with the free token-count endpoint (or bytes ÷ 3.5),
   drop the ×3 to one fallback share, say "needs N available" in the estimate. ~1 day with tests.
4. **The monthly budget row is created by hand.** Without a November row every chat is `service_unavailable`
   (logged as `chat_reserve_uncertain`); only `scripts/pipeline-ops.py budget` creates it. Fix: a scheduled function
   that pre-creates next month's row and a readiness check. ~2 h.
5. **No external alerting; any overrun pauses everyone.** `work_enabled` flips off on any actual above ceiling until
   an operator unpauses; anomalies and the 80 % notice are dashboard-only. Fix: hourly pg_cron/pg_net post to the
   owner on paused, ≥80 %, aged unknown attempts, Tavily paused. ~4 h.
6. **The stale-hold sweep inflates `spent`.** `worker_expire_stale_chat_operations` settles at the full ceiling for
   operations without an admitted attempt and adds it to `spent_microusd` permanently; it runs only inside the paper
   worker after 30 minutes, during which the three-operation cap can block the reader. Fix: settle such operations at
   0 micro-USD (new migration). ~2 h. Staging shows the effect already: `spent` ($21.03) equals the sum of settled
   operations, while recorded provider attempts total $9.59 (OCR settled at its ceiling, pre-accounting estimates).
7. **Missed refund notifications are never caught.** Notifications answer 503 on a database failure and sandbox ones
   are not retried; restore reports only unfinished transactions and current entitlements, where a revoked
   consumable never appears. Fix: on restore also report revoked transactions (~3 h); an App Store Server API
   reconciliation job once the key exists (~1 day).
8. **Service-role grants bypass the admin cap and audit.** Admin grants are capped at 2,000 and audited;
   `pipeline-ops.py grant` calls `worker_grant_credits` directly (the owner's 100,000-credit grant went this way).
   Fix: route scripts through an audited RPC with actor and override reason. ~2 h.
9. **Product gaps.** No spend history for the reader (only the balance), no refund path for refused answers, podcast
   quotes hold 140–530 credits with no cap at balance, and the store copy still sells OCR page conversion after
   those charges ended on 2026-10-13. Fix: a `v1_credit_history` RPC and Settings list (~8 h), copy update (~1 h),
   podcast "needs N available" (~2 h).
10. **Minor.** The SQL pricing snapshot still records an old Sonnet cache-read rate and a Haiku 4.5 card (evidence
    only, but misleading in the dashboard); the subsidy from `chat_credits_capped_at_balance` is logged but never
    aggregated. ~1 h each.

Not verified: that the hosted cron still invokes the stale-hold sweep after the HTML-first worker change; Apple's
production notification retry window; whether `chat_reserve_uncertain` has ever fired on staging.

## Sync reliability

**What works (verified).** Events are commit-ordered under a per-account keyring lock; both clients require the next
cursor, verify every ciphertext digest and commit a page with its cursor in one transaction; duplicates are rejected
by id and a replayed push returns the original cursor; writes are local-first (drafts through the retirement
barrier, messages committed with their outbox entry in one SQLite transaction); concurrent replies are kept as
branches with a picker; library cursors reset through `library_resync_required` and commands replay by operation
id and digest. Staging (read-only): the owner's four devices are all at cursor 113 of 113, 122 events across three
accounts, all format 1; no owner report of a lost chat or draft exists.

Ranked gaps:

1. **Older builds stop syncing entirely, and are told "try again".** Migration 058 makes `v2_pull_events` raise
   `reader_update_required` when any event on the page has format 2; native pulls before pushing, so a build on the
   v2 RPC (by commit order, builds up to 27; not verified against the binaries) neither receives nor sends once one
   format-2 event exists, and the client maps the unknown code to "The server could not complete this request.
   Please try again." No format-2 event exists on staging yet, so nothing is stuck today. Fix: raise
   `sync_page_too_large` instead (old builds already render it as "Update the app to sync this history"), update
   `tests/database/html_first_cutover.sql`, add the code to the native known set. ~1.5 h.
2. **Any undecodable remote event parks sync with generic copy and no code.** Fail-closed is the policy, but the
   reader sees "Sync could not finish." (native) or "Reload the page to try again." (browser) with no distinction
   between update needed, recovery needed, quota or rate limit; the session timeline logs path and status only.
   Fix: map error codes to specific copy; log code and cursor. ~3 h native, ~1.5 h browser.
3. **Native never polls and never retries.** Sync runs on activation, foreground, after local writes and key
   refresh; failure sets "Sync paused" and waits; library commands drain only on refresh. The browser polls every
   30 s (chat) and 60 s (library). An iPad or Mac left in the foreground shows "Synced" while other-device chats and a
   failed push wait indefinitely. Fix: a foreground scheduler (60 s active; 15/60/300 s backoff after failure)
   covering sync and the command drain, within the 1,000/h read rule. ~4 h.
4. **The browser ignores the storage-persistence answer.** `persist()` is called and its result discarded; evictable
   storage is then labelled "Saved on this device." Fix: keep the outcome, show best-effort copy, re-request on
   the next visit. ~2 h.
5. **A browser without Web Locks or BroadcastChannel loses chat with a reload instruction that cannot help.** Fix:
   treat it as session-only with honest copy; add a lifecycle test. ~1.5 h. Which browsers hit this is not verified.
6. **Hosted two-device evidence predates format 2.** `LiveSyncTests` still probe the v2/v1 RPCs and skip without
   environment; no post-058 two-device run exists. Fix: update to v3 and format 2 and run the opt-in check once.
   ~2 h plus the run.
7. **Minor.** Native treats a failed cursor acknowledgement as a sync failure ("Sync paused" after a complete sync);
   key rotation and device revocation have no client caller, so a lost device cannot be revoked in-product.

## Suggested order

Sync 1 (one evening, prevents a stuck device the day a format-2 chat happens), credits 2 and 4 (readers charged for
outages; a November outage), credits 1 and 5 (budget liability and alerting), then credits 3 (hold sizing, the
biggest felt change for small balances), then the rest.

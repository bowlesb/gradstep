# Independent credit, identity, and cost audit — 2026-10-07

**Status: findings open; this audit does not fix, deploy, or configure monitoring.**
Reviewed main e2b9b95 through the library-v4 worktree. Migrations 031/032 being developed in that worktree are outside this audit's implementation scope.

The credit ledger has substantial protections, including atomic reservations and purchase replay protection. It is **not yet an end-to-end limit on the application's expense**. The highest priorities are the deployed worker's billing mode, provider calls outside admission, and uncertain requests that can be billed without being fully accounted for. These should be addressed before broadening beta access or describing the product as having a hard whole-system spending cap.

## Scope and evidence

The owner requested an independent adversarial review of credits, identity, cost abuse, and heavy-user economics. Reviewed backend entry points, provider clients, migrations 001–030, worker/deployment configuration, operator grants, purchase handling, relevant tests, and architecture/decision documents. No application, schema, or infrastructure changes were made by this review. This file is the only authorized documentation write.

Evidence levels used below:

- **Source-confirmed:** reachable code and its prerequisites were inspected; not a claim about unseen hosted settings.
- **Locally reproduced:** in-memory fake-provider fixtures exercised the real application code, with no network/provider calls, real credentials, or database writes.
- **Live read-only:** narrowly inspected the existing Science Reader Cloud Run configuration and staging pipeline cron. No deployment, paid work, attack traffic, or configuration changes.
- **Unverified:** actual invoices, instance uptime, provider dashboard overage settings, hosted Auth enrollment/linking settings, and most vendor hard limits.

Existing tests were read, not represented as a newly executed full suite. No NAS, TextBrain, or physical iPhone operations were performed.

Path shorthand: shared TypeScript filenames below are under supabase/functions/_shared/. Migration numbers identify the uniquely numbered SQL file in supabase/migrations/ (for example, 018 is 202610050018_app_store_purchases.sql). File line numbers refer to the reviewed e2b9b95 baseline.

## Findings

### F1 — High: the deployed worker can consume most of the beta budget while nearly idle

**Evidence:** scripts/deploy-pipeline-worker.py:81–84 deploys one CPU, 2 GiB, concurrency 1, minimum 0, maximum 3, timeout 900 seconds, and --no-cpu-throttling. infra/staging.json:41 schedules a request every minute. The expected $0–2 worker cost in docs/architecture/OPERATIONS_AND_BILLING.md:50 is not justified by those settings.

Live read-only observations on 2026-10-07:

| Resource | Observed setting |
|---|---|
| Google Cloud project / region / service | gradstep / us-west1 / gradstep-pipeline |
| Serving revision | gradstep-pipeline-00006-g87, 100% traffic |
| Revision CPU throttling | false: instance-based billing |
| Revision CPU / memory / concurrency / request timeout | 1 / 2 GiB / 1 / 900 s |
| Revision maximum scale | 3 |
| Minimum scale | No explicit minimum annotation; deployment specifies 0 |
| Service maximum scale annotation | 20; the current revision also has its own maximum of 3 |
| Startup CPU boost / ingress | true / all |
| Staging cron | science-reader-pipeline, active, * * * * * |

Instance-based billing covers instance lifetime, including idle time. Repeated minute requests can keep an instance warm; minimum zero alone does not establish low cost. At current us-west1 list rates, one continuously warm instance for 30 days is **$57.02 before free allowance**, or **$51.80 if all applicable monthly free allowance is available**. Three continuously warm instances would be $171.07 / $165.85 respectively. Free allowance is shared at the billing-account level. These are scenarios, **not an observed invoice or proof of uninterrupted uptime**. [Cloud Run pricing](https://cloud.google.com/run/pricing), [billing settings](https://docs.cloud.google.com/run/docs/configuring/billing-settings).

The service awaits pipeline and tagging work before responding (services/pipeline-worker/server.ts:65–88,105–109), so request-based CPU billing appears compatible with the present lifecycle. Verify that assumption against all handlers before changing it. Public ingress also means unauthenticated traffic can cause billable service work before the application rejects it.

**Fix direction:** inspect billed instance time; review request-based billing and a due-work wakeup strategy; keep a deliberate instance ceiling; regression-check the deployed billing flags. A budget alert is monitoring, not a hard stop. Do not raise the owner's $100 incremental budget.

### F2 — High: Tavily allowance and consent are bypassed by paper discovery

**Prerequisites:** an authenticated open account and a configured Tavily key; no customer credits or existing paper membership are needed to call add-reference.

**Evidence:** supabase/functions/add-reference/index.ts:19–39 validates a reference and operation UUID, rate-limits, then constructs the finder using the raw key. The operation UUID is not used after validation, so replaying it does not deduplicate discovery. supabase/functions/_shared/find-paper.ts:74–85 directly calls Tavily without a provider reservation, allowance check, spend pause, consent check, or Tavily usage event.

The endpoint is rate-bounded at 120 requests/account/hour and 2,000/environment/hour (migration 026:8); those are not limits on monthly search credits. A reference can invoke the finder up to three times: two candidate titles, then a Crossref or final OpenAlex candidate (reference.ts:160–179,194). Each finder can make one logical Tavily search. tavily.ts:73–101 may retry a lost response, 5xx, or malformed success once, so a request can initiate up to six HTTP search attempts when the 25-second endpoint deadline permits. Six is a code-path ceiling, not a claim that every request reaches it.

Ingest has the same direct-key finder (chat/index.ts:39; chat.ts:430–451), invoked after the chat settles. It can make one logical Tavily search, with up to two transport attempts. This is reachable with cloud-ai-v1 consent and even with CHAT_WEB_SEARCH off: the ordinary chat search consent gate does not cover this path.

Even ordinary Tavily chat only reads recent usage once before execution (chat/index.ts:58–61). It does not atomically reserve units. Concurrent requests can pass a stale allowance check. Only successful logical searches increment usage; logging is best effort after the answer (chat.ts:557–560,612–621). Lost successful responses, retry attempts, function termination, or a failed usage write can therefore undercount.

**Impact:** the 3,900-credit/31-day guard is not a systemwide hard bound. With vendor pay-as-you-go disabled, the likely consequence is premature prepaid depletion, failures, and higher-cost fallback. If pay-as-you-go is enabled, overage can also escape the application's budget. Its actual hosted setting was not verified. The owner approved $30/month for 4,000 prepaid credits; this audit does not change that commitment. [Tavily pricing](https://docs.tavily.com/documentation/api-credits).

**Test gap:** tests/backend/chat.test.ts:877–893 checks that Ingest offers no model search tool, but mocks the finder and therefore does not prove the finder avoids Tavily.

**Coherent fix:** one durable provider-attempt admission interface used by chat, Ingest, and reference lookup. Atomically reserve units against the actual provider billing cycle, bind them to stable operation/step/attempt IDs, enforce consent, and retain conservative allowance for unknown outcomes. Free reference discovery can remain a product feature under an explicit bounded platform allowance and free-catalog fallback. Fixing only add-reference or only the chat readiness check leaves other paths open.

### F3 — High: SDK retries can hide an additional billable Anthropic attempt

**Evidence:** anthropic.ts:264–268 defaults maxRetries to 1. A successful stream records only the returned request's usage and labels it exact (anthropic.ts:350–372). A lost first response followed by a successful SDK retry is therefore represented as one exact attempt.

**Locally reproduced:** injected fetch threw on the first HTTP attempt and returned valid SSE on the second. Observed **2 transport posts, 1 reported attempt, exact=true**. The application cannot establish that the first request was not processed/billed from that transport failure. No real provider request was sent.

Separately, failure before message_start estimates input only and zero output (anthropic.ts:307–313). A remote request can have done more work before the response was lost. chat.ts:392–405 settles that estimate and releases the remaining hold. The conservative stale-hold recovery in migration 015 does not cover a request already settled this way.

**Impact:** the atomic database reservation is strong, but the amount finally recorded can be below actual provider expense, permitting later operations against an overstated remaining budget. This is not a claim that every retry is billed twice.

**Test gap:** the existing fake client in tests/backend/chat.test.ts:665–670 explicitly sets maxRetries to 0, unlike production.

**Fix direction:** disable hidden transport retries, or explicitly admit and journal each transport attempt before sending it. Keep an unresolved provider liability for ambiguous outcomes and reconcile against provider records. Do not call a later successful attempt exact for the entire operation while an earlier attempt is unresolved. Customer charging/refunds can remain separate from conservative platform liability. Tagging already sets maxRetries=0 (tags.ts:132–134); Mathpix's one-shot submission and quarantine are useful patterns.

### F4 — Medium–High: pause_turn continuations can exceed the advertised answer search cap

**Evidence:** chat.ts:506–541 repeatedly passes the original Anthropic web_search tool. Its max_uses applies per API request, while the product intends 3 searches per ordinary answer or 5 for Related. The pause_turn path continues without lowering/removing that tool. The round guard is checked after generation and uses round > cap.

**Locally reproduced:** a fake provider returned pause_turn with three searches and minimal tokens on each round. The code made **five requests, each offering max_uses=3**, recorded 15 searches, and emitted done with stop_reason=pause_turn. Related could analogously offer seven requests × five searches. The overall output allowance and deadline still constrain the operation; this is not an infinite loop. [Anthropic web search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool).

**Impact:** search cost/input rereads can exceed the specifically quoted search envelope, and an unfinished answer is reported as successful. The general hold has extra headroom, so not every such sequence necessarily exceeds the total hold.

**Fix direction:** maintain remaining searches across all provider requests, lower/remove the server tool before each continuation, check the round guard before generating, and handle unfinished pause_turn explicitly. Add cross-provider failure/continuation tests. No existing pause_turn test was found.

### F5 — High before broader access: reader delivery has no hard byte budget and signed URLs are replayable

**Evidence:** reader-artifact/index.ts:25–43 authorizes a library member, downloads its manifest, and signs up to 512 member URLs for **900 seconds**. worker_reader_descriptor (migration 014:758–770) checks ownership/availability and consumes a request-rate counter. The reader-download rule is 300/account/hour and 3,000/environment/hour (014:121). The older acquisition read-byte accounting is not called by this renderer delivery path.

**Prerequisites:** access to one's own ready reader artifact. One valid signed URL can then be fetched repeatedly, or copied to another caller, during its validity without another descriptor authorization or credit check. Short-lived bearer URLs are a deliberate storage pattern; they do not constitute a per-use download or expense cap. Closing the account does not itself revoke already issued URLs immediately.

**Impact:** request counts do not bound actual delivered bytes. Cached traffic is cheaper, not necessarily free beyond its included quota. The applicable hosted Supabase Spend Cap setting was not verified. Also, chat loads up to 2 MiB of stored paper context before reserving customer credits (chat.ts:324–359), so insufficient-credit requests still consume backend work.

**Fix direction:** account for the complete bundle's bytes and enforce a transfer allowance when issuing grants; make refresh/cache behavior explicit. To enforce a hard per-use limit, actual delivery must pass a controlled serving/token-validation layer rather than relying solely on replayable storage URLs. Use real egress metrics to reconcile delivered bytes; avoid asserting that a descriptor counter is a hard bandwidth bound.

### F6 — High before larger libraries: storage admission does not count all stored assets or reserve bytes atomically

**Evidence:** migration 016:20–37 checks a 5 GiB environment allowance, 50,000 objects, and 1 GiB owner-private usage by summing stored_objects, with room for one maximum PDF. It does not create durable byte reservations. The pipeline stores original objects, but raw and rendered bundles register **their manifest only** (014:632–633,680–681). pipeline.ts:396–397,447–448 uploads the bundle members before those database records.

Consequences:

- Raw MMD, ZIP, JSON, rendered HTML/images, and duplicate or failed uploads are not all included in the claimed byte/object totals.
- Concurrent admissions can observe the same headroom. The later original-object lock (014:394) does not recheck this total.
- A crash between upload and recording, or a rejected fenced result, can leave objects not represented by the database inventory. Manifest-driven account deletion cannot discover every unregistered attempt prefix; migration 017:139–142 itself notes that only manifests are tracked.

**Impact:** the advertised quota counters are incomplete; storage can grow past them. Private-account erasure and orphan cleanup also need an authoritative inventory, not merely cheaper storage pricing.

**Fix direction:** design an immutable asset/member inventory with exact sizes and scope, durable reserved bytes, committed bytes, reference ownership, and fenced orphan reconciliation. Reserve bounded original + raw + rendered space before upload, including temporary duplicate/retry space. Verify counters against actual bucket inventory. Keep owner-private assets separate; do not make privacy-sensitive deduplication a storage shortcut.

### F7 — Medium, staging identity: the per-Apple-account Sandbox credit cap races across app accounts

**Evidence:** migration 018:164–167 computes monthly usage across either the app account or app_transaction_id. The locks cover the individual store transaction, original transaction owner, and app account (018:211–216,275–301), not the shared Apple app transaction identity.

**Prerequisites:** two valid Sandbox receipts with distinct transaction/original transaction IDs and distinct app account owners but the same app_transaction_id, processed concurrently. Both can observe zero shared usage and each grant 800 credits, exceeding the intended 1,000-credit monthly Apple-identity limit. Same-account and same-transaction paths are serialized; this is not a way to forge Apple signatures or duplicate a Production transaction.

**Evidence level:** source-confirmed concurrency gap; no live receipt or concurrent database attack was run. tests/database/test_store_purchases.sql:205–209 covers only sequential cross-account usage.

app_transaction_id is optional in normalized signed data (app-store.ts:143). A legitimate receipt without it cannot be subject to this shared-identity cap; define the fallback policy explicitly rather than assuming that identifier is always present.

**Fix direction:** serialize a durable allowance row keyed by environment + Apple app identity + period, in a documented lock order, and retain the account cap. Add a simultaneous two-account test and a deliberate missing-identity policy. The global provider budget limits the eventual financial damage when accounting is otherwise complete.

### F8 — Medium: a still-running Mathpix job can lose most of its reserved liability at timeout

**Evidence:** pipeline.ts:339–368 polls a known submitted job. After six hours, a status that still reports processing causes conversion_timeout with pages_billed = completedPages ?? 0. Migration 014:649–657 then marks the attempt failed and settles that amount with no customer charge. No provider cancellation or final billing confirmation precedes the transition. A 404/410 is instead conservatively settled at the full page limit (pipeline.ts:353,363).

**Prerequisite:** a valid submitted OCR job remains pending beyond six hours, or terminal error usage is incomplete. The last progress count is not necessarily final billable usage, and a local timeout does not prove remote work stopped. A failed attempt no longer participates in the active-attempt exclusion; another funded attempt can follow, subject to the two-failure guard in 014:463–473. The exposure is bounded per document by that guard and the page limit, not an infinite retry loop.

**Evidence level:** source-confirmed accounting transition, not evidence of an actual Mathpix overcharge. Existing tests/backend/pipeline.test.ts:279–285 covers the conservative missing-job path; a late still-pending job needs its own regression.

**Fix direction:** preserve a conservative platform liability and uncertain remote-job state until final usage/cancellation is established. Customer refunds do not require releasing the platform reserve. Test a submitted job older than six hours whose status remains processing with zero completed pages: it must not be treated as a final zero-cost provider outcome or permit overlapping replacement work. Reuse the provider-attempt reconciliation design rather than a special timeout refund shortcut.

## Identity and ledger protections worth retaining

No new direct customer-to-service-role grant route or Production receipt replay duplication was established in the inspected code. That is not a blanket identity certification.

| Boundary | Existing protection / evidence |
|---|---|
| Caller identity | backend.ts:12–23 verifies the token with Auth, resolves v1_account_context, and requires its account UUID to equal the verified user's UUID. Client-provided email is not used as the owner key. |
| Service-only money mutations | Billing and store worker functions revoke public/anon/authenticated execution; the private schema has RLS and no customer table access. See migration 018:367–375 and migration 003. |
| Spend admission | Migration 003:167–201 locks budget, account, and credit buckets; reserves both units and money; checks replay digest/rate/amounts; limits active operations to three. Existing tests/database/concurrency.py exercises competing credit holds. |
| Settlement | Migration 003:208–234 settles once and releases unused holds; actual expense above the reserved ceiling freezes further paid work. That requires complete provider accounting, which F2/F3 weaken. |
| Abandoned chat | Migration 015 conservatively settles stale chat holds at the provider ceiling without charging the customer; it does not incorrectly sweep OCR submissions. |
| OCR submissions | pipeline.ts:308–332 grants submission durably before one paid POST; recording can retry without resubmitting; uncertain submissions quarantine. Migration 014:105–106 prevents another active OCR attempt for the same document. |
| Mathpix bounds | Exact PDF hash/options, a verified PDF, maximum size/page limits, and a submission profile bind the paid request. mathpix.ts:17–28,182–197; migration 014. |
| App Store authenticity | app-store.ts:83–100 verifies Apple's signed chain, environment, and bundle; online revocation checks default on. Migration 018 grants each transaction once, binds the original transaction owner, and gives the newest signed refund state precedence. |
| Refund handling | Unspent credits are removed; in-flight holds remain. Previously incurred provider expense cannot be refunded by changing the ledger. |
| Operator authority | Migration 001:34–39 requires a server-side operator role and JWT aal2. admin-accounts.ts:140–145,199–205 checks the caller before using the service client. Migration 028:157–173 rechecks owner authority, locks the account, bounds and deduplicates grants, and audits them. |

Release/follow-up conditions:

- Hosted Auth signup, anonymous login, automatic/manual linking, Google/Apple flows, CAPTCHA/rate limits, and SMTP configuration were not reverified by this audit. Local enable_signup=true is not proof of hosted public enrollment; the provisioning script intends disable_signup=true. Verify provider identities with verified email and stable Auth UUIDs, account switching, Apple relay addresses, provider removal, and reauthentication for linking.
- Admin "disable sign-in" changes Auth ban state; it is not an explicit application-level suspension of all already-issued JWT/RPC access or queued spending. If an abuse kill switch is intended, model and enforce a suspension state at admission/worker boundaries.
- App Store periodic reconciliation and consumption-information handling remain listed as unfinished in PURCHASES.md:90–96. Missed refunds can remain unnoticed for users who do not reopen the app. Verify real Sandbox purchases before treating local tests as hosted acceptance.
- The long-lived worker can read a full Supabase service-role secret. A worker compromise has backend-wide authority. A narrower worker capability/role is a future reduction in blast radius, not an observed customer exploit.
- App Store receipts without appAccountToken use first verified claimant ownership; deleted-account purchases can move for future periods. Treat signed receipts as bearer-sensitive data and test those intentional rules.

## Hard bounds versus monitoring or assumptions

| Cost path | Present meaningful bound | What remains outside that bound |
|---|---|---|
| Metered chat/OCR | Atomic USD + credit reservation, output/page/size/active-operation bounds | F2/F3/F4/F8; estimates versus provider invoices |
| Tavily prepaid searches | Vendor plan, if overage is disabled; partial application counter | Finder calls, retries, concurrent admission, lost accounting |
| Tagging | Platform-funded reservation, $0.01 per-attempt ceiling, six-attempt cap per version | No customer debit; a user can consume shared tagging capacity by adding many new versions |
| Reader traffic | Descriptor request rate and URL expiry | Repeated bearer-URL downloads; actual GB |
| Paper storage | Partial original/manifest counts and size bounds | All bundle members, temporary/orphan objects, reservation races |
| Encrypted chat sync | Dedicated storage/transfer limits in migration 009 | It does not cover all paper, support, or provider traffic |
| Paid workflow checks | Shared provider budget; script allowance estimates | Concurrency of soft script checks; infrastructure/fixed provider costs |
| Cloud Run | Configured CPU/memory/instance count | Billing while idle, active duration, public request load |
| $100 incremental beta budget | Documented owner limit and per-environment provider budgets | No verified cross-vendor ledger or cross-environment hard total |

The current staging October provider allowance is documented as $9.80; migration-level policy bounds do not centrally apportion future staging and production bills. A per-database $30 ceiling is not the owner's combined monthly $100 limit. Maintain explicit allocations and one aggregate forecast.

Operational/financial tables are append-only for good reasons, but need a retention/archive design that preserves idempotency and purchase evidence. Repeated zero-cost failures and new operation IDs can still add rows and database load after provider spend stops. Do not simply delete financial records to reduce disk.

## Economics and heavy-user scenarios

All prices below are USD list prices checked against official sources on **2026-10-07**. These are workload calculations, not invoice reconciliation or a promise of a particular customer's bill.

### Approved tiers

Owner pricing is recorded in DECISIONS.md:139–150, PURCHASES.md:6–7, and migration 018:28–31. The implementation maps one credit to $0.005 of provider-equivalent usage; Tavily's customer charge uses its list-equivalent search cost even when prepaid.

| Product | Gross price | Credits | Provider-equivalent allowance | Remainder at 15% Apple commission | Remainder at 30% commission |
|---|---:|---:|---:|---:|---:|
| Standard month | $9.99 | 800 | $4.00 | $4.49 | $2.99 |
| Pro month | $19.99 | 1,800 | $9.00 | $7.99 | $4.99 |
| Nonexpiring pack | $4.99 | 400 | $2.00 | $2.24 | $1.49 |

Remainders exclude taxes, refunds, payment adjustments, platform-funded work, infrastructure, support, and the findings above. The two commission columns are sensitivity scenarios; eligibility, storefront, and contract matter. Apple describes 70% first-year subscription proceeds and 85% after a year or through its qualifying Small Business Program, before applicable taxes. [Apple subscription economics](https://developer.apple.com/app-store/subscriptions/).

A deliberate owner-approved exception caps a chat's customer hold at a remaining balance of at least 50 while retaining the full platform-dollar hold (chat.ts:244–248,348–351,400). This is a subsidy if the answer costs more than those customer credits. Refunds, plan changes after credits were consumed, free metadata tagging, and failed provider work also weaken a simple "credits × $0.005 equals maximum cost" claim. Monitor those separately.

### Explicit monthly workloads

Assume each ordinary paper answer uses 20,000 cached-paper tokens, 2,000 fresh instruction/history/question tokens, and 1,000 output tokens including thinking. Sonnet 5.5 is $2/M fresh input, $10/M output, $2.50/M five-minute cache write, and $0.20/M cache read. Such a turn costs $0.018 warm / $0.064 cold, rounded to 4 / 13 reader credits. Assume 80% warm, 20% cold: $0.0272 and 5.8 credits on average. Cache reuse depends on actual time between requests and prompt layout; 80% is an assumption, not a measured cohort. [Sonnet pricing](https://platform.claude.com/docs/en/models/sonnet-5-5/overview).

Assume 20-page imports. Fresh Mathpix conversions cost $0.005/page at the current v3/pdf volume tier. In light/heavy examples, half the imports reuse an already-ready legally shareable exact-byte conversion; in the extreme example all need new conversions. Web imports and non-shareable papers remain owner-private, so do not assume those users benefit from cross-account OCR savings. [Mathpix pricing](https://mathpix.com/pricing/api).

For Related, use the project's recorded example of $0.047 Anthropic expense, 15 reader credits, and 3 prepaid Tavily units per request; it is a benchmark illustration, not a guaranteed rate for every answer.

| Monthly workload | Light | Heavy | Extreme illustration |
|---|---:|---:|---:|
| Imports | 10, half reused | 30, half reused | 100, none reused |
| Newly OCR'd pages | 100 | 300 | 2,000 |
| Ordinary paper answers | 50 | 200 | 1,000 |
| Related requests | 10 | 20 | 100 |
| Metered Mathpix + Anthropic | **$2.33** | **$7.88** | **$41.90** |
| Reader credits | 540 | 1,760 | 9,300 |
| Prepaid Tavily units | 30 | 60 | 300 |
| Extra tagging at observed $0.0038/new version | up to $0.038 | up to $0.114 | up to $0.38 |
| Example plan fit | Standard | Pro, little headroom | Pro + 19 packs provides 9,400 credits |

Keeping the same token sizes but varying ordinary-answer cache reuse from all warm to all cold makes the metered totals **$1.87–4.17 light, $6.04–15.24 heavy, $32.70–78.70 extreme**. Higher costs require more credits; the heavy cold-cache endpoint does not fit one Pro allowance. Longer papers/history, bigger outputs, repeated search, fallback, and uncertain attempts widen the range further.

The extreme example is a future commercial workload, not a statement that the current private-beta budget or storage admission will admit it. Even the illustrative heavy user could consume most of the documented $9.80 staging provider allowance.

### Infrastructure, retained data, and fixed commitments

Supabase Pro's current public rates include the first Micro using a $10 compute credit, then additional Micro projects from $10/month. It includes 100 GB object storage, 8 GB disk/project, 250 GB each cached/uncached egress, and 100,000 MAU. Overage is $0.0213/GB-month storage, $0.125/GB disk, $0.03/$0.09 per cached/uncached egress GB, and $0.00325/MAU. Edge includes 2M calls then $2/M; Realtime includes 5M messages then $2.50/M and 500 peak connections then $10/1,000. Included quantities are not per-user allowances. [Supabase pricing](https://supabase.com/pricing).

Illustrative retained data: a 10 MB original + 2 MB raw bundle + 3 MB reader is 15 MB/paper. Two hundred unique papers retain about 3 GB, around $0.064/month marginal object storage after the included pool is exhausted. Downloading 150 three-MB bundles to two devices is 0.9 GB, $0.027 cached or $0.081 uncached marginal egress. Private copies multiply storage/conversion expense; eligible shared assets reduce it. These examples exceed the intended 1 GiB owner-private allowance if all papers are private and therefore require an explicit later capacity decision. Current quota gaps in F6 do not authorize expanding it.

Storage is usually a smaller cost than model use, but retention persists after the user stops asking questions. Egress abuse and large database histories differ from average-user economics. DB compute, authentication email, backups of actual storage objects, logs, secrets, registry, builds, scheduler jobs, and account-recovery/support work also need allocation. Database backup does not by itself establish backup coverage for every object.

Only **incremental Science Reader costs** count toward the owner's $100 limit; existing TextBrain expense is excluded. The organization's bill and compute-credit allocation must establish that incremental amount. Do not assign the whole organization subscription to Science Reader automatically.

| Monthly normalized commitment / scenario | Amount |
|---|---:|
| Tavily Project, owner-approved | $30.00 |
| Existing purchased Gradstep domains, amortized per operations doc | approximately $7.60 |
| Cloudflare Pages static serving | $0 under the static plan; functions have separate billing |
| Incremental Supabase allocation if Pro was already committed elsewhere | Could be only added compute, e.g. $10/Micro; credit allocation/invoice needed |
| New Pro organization with one Micro, if entirely incremental | $25 |
| New Pro organization with two Micro projects, if entirely incremental | $35 |
| One continuously warm deployed Run instance, full free allowance available | approximately $51.80 |
| Apple Developer Program, if incremental | Separate from the documented budget table; confirm allocation |

Thus the warm-worker scenario is **$89.40/month before the incremental Supabase allocation, metered AI, and other items**. If Supabase adds $10, almost no room remains; if it adds $25–35, the scenario reaches $114.40–124.40 before metered AI. If Supabase adds $0, adding the documented $9.80 metered allowance already reaches approximately $99.20. These are forecasts requiring real billing data, not claims about current charges. Domains were bought upfront; amortization is not the month's cash invoice.

Static Cloudflare Pages requests are free; do not extend that claim to Functions or other services. [Cloudflare Pages billing](https://developers.cloudflare.com/pages/functions/pricing/). Supabase's optional Spend Cap covers specified usage quotas, not arbitrary dollar limits or every product such as compute/PITR/custom domains. Its actual hosted state was not verified. [Supabase cost control](https://supabase.com/docs/guides/platform/cost-control).

## Highest-value monitors and regression checks

No new monitor or recurring job was installed by this audit.

1. **One provider-attempt ledger:** operation, account, environment, exact provider request/attempt ID when available, state before sending, reserved units/USD, known usage, unknown liability, and final reconciliation. Alert on spend without a reservation, unknown attempts, provider usage lacking an operation, and discrepancies against vendor totals.
2. **Aggregate $100 forecast:** separately show incremental fixed allocations, incurred invoices/usage, held/unknown exposure, month-end forecast, and the next irreversible commitment. Include both environments and workflow checks. Keep existing TextBrain spending separate. Alerts at explicit owner-reviewed thresholds; alerts alone are not admission.
3. **Search units:** all Tavily call sites, allowance held/consumed/unknown, days left in actual billing cycle, vendor overage setting, and Anthropic searches per logical answer. Test allowance-1 with concurrent requests; zero-credit reference lookup; replayed operation UUID; all three finder invocations; v1/off Ingest; lost-success retry; termination before usage write.
4. **Provider failure accounting:** run the fake-SDK fixture below with production defaults; add cases for lost response before message_start, abort after stream start, fallback iterations, and pause_turn through the last allowed search. Assert transport attempts cannot disappear from liability and unfinished turns are not done. Add the still-pending Mathpix timeout scenario in F8 and reconcile terminal failures with incomplete usage.
5. **Storage/delivery reconciliation:** actual bucket bytes versus inventory/reservations; orphan age/bytes; bundle member counts; private-account erasure; actual cached/uncached GB per account/artifact; signed URL replay. Test two admissions racing at remaining capacity and upload followed by DB rejection/crash.
6. **Purchase/identity:** concurrent shared-Apple-identity Sandbox claims, same transaction replay, out-of-order refunds, cross-account restore, deleted-account rebinding, optional missing appTransactionId, consumed-credit upgrades/refunds, and missed notification reconciliation. Add real Sandbox acceptance before public release.
7. **Per-account margin:** provider expense versus actual customer debits/revenue, 50-credit subsidy frequency/amount, platform-funded tags, failed OCR/provider cost, purchase/refund loss, OCR reuse across distinct users, and retained storage/delivery. A small average can conceal one costly account.
8. **Infrastructure drift:** billing mode, instances, cron cadence, CPU/memory, active/idle billed duration, vendor quota/PAYG settings, per-project compute size, storage growth, and anomaly traffic. Check after every infra deployment.

## Reproduction notes

### Local in-memory SDK retry and pause_turn fixtures

Run from the audited worktree on Node 24 with its locked SDK dependency available. During this audit the worktree had no root node_modules; the existing dependency in the main checkout was resolved read-only through a Node resolution hook. The following setup never loads environment files or contacts providers:

~~~js
import { createRequire, registerHooks } from 'node:module';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const sdkURL = pathToFileURL(
  createRequire('/Users/benbowlwes/science-reader/package.json')
    .resolve('@anthropic-ai/sdk')
).href;
registerHooks({
  resolve(specifier, context, next) {
    return specifier === '@anthropic-ai/sdk'
      ? { url: sdkURL, shortCircuit: true } : next(specifier, context);
  }
});
const { createAnthropicClient, chatRequestParams, streamChat } =
  await import('./supabase/functions/_shared/anthropic.ts');
~~~

For F3, supply the real SDK with a fake fetch. A transport failure is deliberately treated as ambiguous, not proof that the real provider charged:

~~~js
let posts = 0;
const usage = {
  input_tokens: 1200, output_tokens: 1,
  cache_creation_input_tokens: 800, cache_read_input_tokens: 0
};
const events = [
  { type: 'message_start', message: {
    id: 'msg_audit', type: 'message', role: 'assistant',
    model: 'claude-sonnet-5-5', content: [],
    stop_reason: null, stop_sequence: null, usage
  }},
  { type: 'content_block_start', index: 0,
    content_block: { type: 'text', text: '' } },
  { type: 'content_block_delta', index: 0,
    delta: { type: 'text_delta', text: 'fixture' } },
  { type: 'content_block_stop', index: 0 },
  { type: 'message_delta', delta: {
    stop_reason: 'end_turn', stop_sequence: null
  }, usage: { ...usage, output_tokens: 40 } },
  { type: 'message_stop' }
];
const client = createAnthropicClient({
  apiKey: 'not-a-real-key',
  fetch: async () => {
    posts++;
    if (posts === 1) throw new TypeError('synthetic response lost after request sent');
    return new Response(events.map(event =>
      'event: ' + event.type + '\ndata: ' + JSON.stringify(event) + '\n\n'
    ).join(''), { headers: { 'content-type': 'text/event-stream' } });
  }
});
const outcome = await streamChat(client, chatRequestParams({
  instructions: 'Fixture', paper: null, selection: null,
  turns: [{ role: 'user', text: 'Fixture' }]
}), {
  signal: new AbortController().signal, onText: () => {},
  inputEstimateTokens: 2000
});
console.log({ posts, reportedAttempts: outcome.attempts.length, exact: outcome.exact });
// Observed: { posts: 2, reportedAttempts: 1, exact: true }
~~~

For F4, inject a provider that pauses after its allowed searches. All RPCs are in-memory stubs, with no database or real credit effect:

~~~js
const { runChat } = await import('./supabase/functions/_shared/chat.ts');
const calls = [], emitted = [], offered = [];
let rounds = 0;
await runChat({
  accountID: '10000000-0000-4000-8000-000000000001',
  webSearch: true,
  rpc: async (name, params) => {
    calls.push({ name, params });
    return name === 'worker_reserve_operation'
      ? { replayed: false, state: 'reserved' } : null;
  },
  loadPaper: async () => null,
  sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'),
  log: () => {}, sleep: async () => {},
  generate: async params => {
    rounds++;
    offered.push(params.tools.find(tool => tool.name === 'web_search')?.max_uses);
    return {
      status: 'complete', failure: null, messageID: 'fake-' + rounds,
      model: 'claude-sonnet-5-5', stopReason: 'pause_turn',
      refusalCategory: null, exact: true, webSearches: 3, content: [],
      attempts: [{
        model: 'claude-sonnet-5-5', estimated: false,
        usage: { input: 1, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 1 }
      }]
    };
  }
}, {
  operation_id: '20000000-0000-4000-8000-000000000001',
  consent_version: 'cloud-ai-v1', mode: 'general',
  messages: [{ role: 'user', text: 'Synthetic audit fixture' }]
}, event => emitted.push(event), new AbortController().signal);
console.log({ rounds, offered, last: emitted.at(-1) });
// Observed: rounds=5, offered=[3,3,3,3,3], last.event='done',
// stop_reason='pause_turn'; provider usage recorded 15 searches.
~~~

To reproduce, concatenate the setup and either fixture through node --input-type=module using a quoted stdin heredoc. No real provider key is needed.

### Narrow live configuration recheck

Read-only equivalent commands, with existing authenticated gcloud tooling. Limit output fields; do not dump environment or secret values:

~~~sh
gcloud run services describe gradstep-pipeline --project gradstep --region us-west1   --format='json(metadata.annotations,status.traffic,status.latestReadyRevisionName,spec.template.metadata.annotations,spec.template.spec.containerConcurrency,spec.template.spec.timeoutSeconds,spec.template.spec.containers.resources)'

gcloud run revisions describe gradstep-pipeline-00006-g87 --project gradstep --region us-west1   --format='json(metadata.annotations,spec.containerConcurrency,spec.timeoutSeconds,spec.containers.resources)'
~~~

The staging scheduler check used a narrowly scoped read-only query through existing Science Reader administration access:

~~~sql
select jobname, schedule, active
from cron.job
where jobname = 'science-reader-pipeline';
~~~

Do not print cron command text: it can embed authentication data. These configuration checks do not establish actual instance uptime, shared free-tier availability, invoices, or account-wide budgets.

## Documentation and policy discrepancies to resolve

- DECISIONS.md:149 says upgrades preserve the earlier plan's credits until expiry. PURCHASES.md:28 and migration 018:173–177 remove the earlier period's unspent credits. This is an **unresolved owner-policy/code conflict**. Do not silently choose the code's behavior over the recorded owner decision.
- OPERATIONS_AND_BILLING.md:47–54 overstates confidence in the worker's $0–2 forecast, uses an unclear Supabase allocation, and its arithmetic does not establish the $100 aggregate constraint after the newer Tavily commitment. Reconcile against actual incremental commitments and billing evidence.
- scripts/workflow-checks.mjs:896 describes spent customer credits × $0.005 as a provider-cost upper bound. That misses approved balance-capped subsidies, free tagging, provider failures/unknowns, and infrastructure. Its measured provider totals/reservations are more relevant, though still depend on complete accounting.
- Supabase hosted Spend Cap, Tavily pay-as-you-go off, and vendor/organization billing allocations remain checks to perform, not completed safeguards.

Recommended execution order: establish the real worker/budget baseline; centralize provider-attempt admission and repair unknown-attempt/search accounting; design complete asset/transfer accounting; close the Sandbox identity race and purchase reconciliation gaps; then widen cohorts with the above monitors and regression evidence. Preserve the existing atomic ledger and one-shot OCR submission design throughout.

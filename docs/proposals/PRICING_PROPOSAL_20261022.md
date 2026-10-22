# Gradstep pricing proposal: free reading, a capped free AI allowance, Plus and Pro

2026-10-22 UTC. **A proposal for owner review. It changes no price, product, budget or code.** It supersedes the
plan shapes in [PRICING_RECOMMENDATION_20261008](../research/PRICING_RECOMMENDATION_20261008.md) (500/1,200 credits,
a 250 pack) and answers the open "$5 of usage" question in [DECISIONS](../DECISIONS.md#owner-testing-allowance-and-5-usage-pricing-2026-10-19-testing-allowance-deployed).
No paid call, purchase or account was made for it. Staging data was read with read-only SQL, and only aggregates were
read. No personal data, emails or keys appear here.

Owner, 2026-10-22: *"Sure go for it. I suspect you can design the cost structure better than I can. My only issue is
that I am investing relatively little in this app — I can't really afford to subsidize much AI usage off the bat. But
otherwise all your suggestions sound reasonable. I'm also curious whether in this realm the number of users could even
be enough to make actual money; from my perspective even if it's not, but a good number of people love it, that's still
a win for me."*

## The recommendation in one table

| | **Free** | **Plus** | **Pro** | **Credit packs** |
|---|---|---|---|---|
| Price | $0 | **$7.99/month** or **$79.99/year** | **$19.99/month** or **$199.99/year** | **$4.99 = 300**, **$9.99 = 700** |
| AI each month | **50 credits** ("about 15 answers"), fast models only, while the month's free pool lasts | **600 credits** ("about 200 answers") | **2,000 credits** ("about 650 answers, or about 20 papers studied in depth with Sonnet") | Never expire; any model |
| Reading, library, sync, notes, Feed, shared podcasts, offline | Included | Included | Included | n/a |
| Premium models (Sonnet, Opus) | No (a pack unlocks them) | Yes, priced in credits | Yes, priced in credits | Yes |
| Podcast generation, web search in chat | No (a pack unlocks them) | Yes | Yes | Yes |
| Unused credits | Expire at month end | Expire with the period | Expire with the period | Never expire |

**The owner's maximum subsidy is one number: the free AI pool, proposed at $15/month in total across every free
account**, enforced by the server's existing hold-before-call machinery, so free use cannot exceed it (§2.2). All other
AI spend is prepaid by the person using it, with a margin.

How many paying users the plan needs (§3; typical plan mix, Small Business 15% commission, half the allowance used):

| Goal | Paying subscribers | Active users needed at 2% conversion |
|---|---:|---:|
| Cover fixed costs and the free pool (lean ≈ $60/month) | **≈ 11** | ≈ 550 |
| Same, at today's configuration (≈ $115/month) | ≈ 21 | ≈ 1,050 |
| Clear **$1,000/month** after costs | **≈ 190–200** | ≈ 10,000 |
| Clear **$5,000/month** after costs | **≈ 910** | ≈ 45,000 |

Fixed costs are small because reading runs on the device. The free tier cannot grow the bill. So the app pays for
itself with a few dozen subscribers. $1k/month is plausible for a well-liked niche app; $5k/month needs Gradstep to
become one of the usual tools in ML circles (§4).

### Owner decisions this asks for

1. Accept Plus/Pro/pack prices and allowances above (or adjust; §2.3 explains each choice).
2. Set the **free pool cap** (proposed **$15/month**) and whether it may later grow automatically to 10% of the
   previous month's App Store proceeds (proposed: yes, with the cap visible in Admin).
3. **Figures default.** On 2026-10-22 the owner made Sonnet (low) the figures default. Under this plan, the first
   Sonnet figure on a paper costs ≈ 48 credits (≈ $0.24), about a month of free allowance or 8% of Plus. Recommendation:
   Gemini Flash (low) as the default on every plan (≈ 2 credits, measured 8–11 s); keep Sonnet one tap away with its
   price shown. If Sonnet stays the default, Free must use Gemini anyway (Free has fast models only).
4. **The Gemini price change on 2027-01-01** (Gemini 3.8 Flash list prices double). A default answer goes from ≈ 3 to
   ≈ 5 credits. Before mid-December choose: switch the chat default to DeepSeek V4.1 Flash (1 credit; faster on
   Together AI, OWNER_ACTIONS #9) or Haiku 5.5, or keep Gemini and change the "about N answers" copy.
5. Enroll in Apple's **Small Business Program** (owner action in App Store Connect) before the first production sale.
6. Downgrade Tavily to its free tier at the next renewal (already recommended in OPERATIONS_AND_BILLING; saves $30/month).
7. Drop the customer-facing **dollar balance with no markup** design ([DOLLAR_BALANCE](../architecture/DOLLAR_BALANCE.md),
   October 20) in favour of credits described as "about N answers". At zero markup every App Store sale loses money (§1.3).

## 1. Unit economics at today's tariffs

### 1.1 Credits and tariffs as they are

- **One credit = $0.005 of provider cost** (`MICROUSD_PER_CREDIT = 5_000`, `supabase/functions/_shared/inference.ts`).
  An operation costs ⌈provider µ$ / 5,000⌉ credits (`beta-credits-v1`). Rounding up per operation makes cheap
  operations cost at least 1 credit, so actual provider cost per credit charged is usually 60–90% of $0.005. That
  cushion is **not** counted in the margins below.
- **OpenRouter prices** in the tariff files (US $ per million tokens, input / output; Vertex's 10% uplift included):
  Sonnet 5.5 2.20 / 11.00 (cache read 0.11, 1-hour cache write 4.40); Opus 5.5 4.40 / 22.00; Haiku 5.5 0.11 / 0.55
  (×5 above 100k prompt tokens); Gemini 3.8 Flash 0.825 / 4.125 until 2026-12-31, then double; DeepSeek V4.1 Flash
  0.20 / 0.60 (cache read 0.006). Sources: `openrouter-claude-pricing.ts`, `gemini-pricing.ts`,
  `openrouter-deepseek-pricing.ts`; [CHAT](../architecture/CHAT.md#money).
- **OpenRouter charges 5.5% on credit purchases** (min $0.80) on top of the per-request costs
  ([OPERATIONS_AND_BILLING](../architecture/OPERATIONS_AND_BILLING.md#gemini-flash-integration--2026-10-17-0008-utc-oct-16-pdt)).
  It is included as overhead below.
- Web search: Tavily, prepaid (free tier: 1,000 searches/month). Readers pay 1.6 credits per search on top of the
  answer's tokens.

### 1.2 Measured cost per activity (staging ledger)

Read-only query of `app_private.provider_attempts` joined to `metered_operations`, grouped by operation (all attempts
of one answer, including its title and follow-up suggestions), last 30 days. Ledger coverage starts 2026-10-08, so the
window is effectively **2026-10-08 → 10-22, 640 attempts, $20.64 in total**. Of 121 accounts, 118 are now deleted:
synthetic check accounts are deleted after each run, and the owner has recreated accounts, so test traffic cannot be
separated from the owner's real use. **These are per-operation costs, not usage patterns**; samples are small (n
shown). "Cold" = the request wrote the paper into the model's prompt cache (the first premium request on a paper);
"warm" = it read the paper from the cache.

| Activity (default in **bold**) | n | Cost p50 | Cost p90 | Credits now | Credits from 2027-01-01 |
|---|---:|---:|---:|---:|---:|
| **Chat answer, Gemini 3.8 Flash** (paper in context) | 56 | $0.0115 | $0.0168 | **3** (p90 4) | 5 (p90 7) |
| Chat answer, DeepSeek V4.1 Flash | 15 | $0.0008–0.0032 | $0.0043 | 1 | 1 |
| Chat answer, Haiku 5.5, warm / cold | 4 / 5 | $0.0013 / $0.011 | $0.0016 / $0.012 | 1 / 3 | 1 / 3 |
| Chat answer, **Sonnet 5.5 warm** | 62 | $0.0175 | $0.0244 | 4 | 4 |
| Chat answer, **Sonnet 5.5 cold** (first on a paper) | 70 | $0.125 | $0.225 | **25** (p90 45) | same |
| Chat answer, Opus 5.5 (2 measured; rate is 2× Sonnet) | 2 | $0.047 | n/a | ≈ 7 warm, ≈ 50 cold (estimate) | same |
| Figure walkthrough, Gemini low ([FIGURE_VIEW "Speed"](../architecture/FIGURE_VIEW.md)) | 6 + bench | $0.007–0.011 | $0.018 | 2–3 | 4 |
| Figure walkthrough, **Sonnet low** warm / cold | 6 + bench | $0.022–0.024 / $0.23–0.25 | $0.245 | 5 / **48** | same |
| Figure walkthrough, DeepSeek low | 17 | $0.0015 | $0.0043 | 1 | 1 |
| Equation explanation, Gemini | 8 | $0.0085 | $0.0103 | 2 | 4 |
| Study / paper explainer, Gemini | 5 | $0.006–0.008 | $0.0084 | 2 | 3 |
| Searched answer, Gemini (≈ 3 Tavily searches) | model | ≈ $0.03 | n/a | ≈ 7 | ≈ 13 |
| AI recommendations (Haiku), flat | 2 | $0.0013 | n/a | 1 | 1 |
| Paper podcast, 5 min, completed (DeepSeek V4 Pro writer + Gemini TTS) | 7 | $0.26–0.30 | $0.30 | ≈ 56 (max hold 150) | ≈ 82 (TTS doubles) |
| Topic tags per catalog paper (Haiku 4.5), **platform-funded** | 24 | $0.0039 | $0.0040 | 0 | 0 |
| Reading, library, sync, offline, device PDFs | n/a | ≈ $0 marginal | | 0 | 0 |

Notes. (a) The lead's note quoted "~24 credits" for the first Sonnet figure on a paper. Under the current rate card it
is **≈ 48 credits** (≈ $0.24; DECISIONS 2026-10-22: 49,000 tokens written into the 1-hour cache). The ≈ 24 figure is
the measured **p50 of all Sonnet figure requests**, which mixes cold and warm ones. (b) A Sonnet chat on the same paper
fills the same cache, so a figure after a Sonnet chat is warm. (c) Podcasts: 22 of the 29 podcast operations in the
window failed review or were pilot work, costing $0.05–0.37 each with no charge to the customer. Podcast generation
carries the largest uncharged-failure risk. (d) A Gemini answer's cost is mostly output, including
medium-effort thinking (≈ 1,800 output tokens ≈ $0.0074 of $0.0115), so shorter thinking, not caching, is the lever.

### 1.3 Margin after Apple, per activity

Net revenue per credit if every credit in the allowance is used: Plus $7.99 × 0.85 / 600 = **$0.0113**; Pro
$19.99 × 0.85 / 2,000 = **$0.0085**; $4.99 pack × 0.85 / 300 = **$0.0141**. At Apple's standard 30%: $0.0093 / $0.0070 /
$0.0116. Cost includes OpenRouter's 5.5% funding fee.

| Activity | Cost | Credits | Margin, Plus (15% / 30%) | Margin, Pro (15% / 30%) |
|---|---:|---:|---:|---:|
| Gemini answer | $0.0115 | 3 | 64% / 57% | 52% / 42% |
| DeepSeek or Haiku answer | ≈ $0.0015 | 1 | 86% / 83% | 81% / 77% |
| Sonnet answer, warm | $0.0175 | 4 | 59% / 50% | 46% / 34% |
| Sonnet first on a paper (chat or figure) | $0.125–0.24 | 25–48 | 53% / 43% | 38% / 25% |
| Opus (estimate) | $0.035 / $0.25 | 7 / 50 | 53% / 43% | 38% / 25% |
| Searched Gemini answer | $0.0315 | 7 | 58% / 49% | 44% / 32% |
| 5-minute podcast (before uncharged failures) | $0.28 | 56 | 53% / 43% | 38% / 25% |

Every activity is positive on every plan, even at 30% commission and full use. That holds because a credit sells for
1.7–2.8× its provider cost. **The "$5 of usage" question:** a $4.99 purchase that granted $5 of OpenRouter usage
would return $4.24 from Apple (15%) or $3.49 (30%), so it would lose $0.76–$1.51 **per sale before any fixed cost**.
Breaking even on the sale alone needs a markup of 1/0.85 = 1.18× (15%) or 1.43× (30%). Covering fixed costs and free
users needs ≈ 2–3×, which is what the proposed packs and plans charge. Answer to the owner: **a $4.99 pack buys 300
credits, about 100 answers with the default model, which is about $1.50 of model cost at provider prices.** Packs
answer the "$5 of usage" question and never expire. Subscriptions are monthly allowances.

### 1.4 Three personas (monthly)

Baskets are assumptions built from the per-activity costs above, not observed users. (For scale, the busiest staging
account, the owner's testing including Sonnet chats and podcasts, recorded **$8.45 in 30 days**.)

| Persona | Basket | Cost now | Credits now | Credits from 2027 | Fits |
|---|---|---:|---:|---:|---|
| **Light learner** (student, a few papers) | 6 papers; 20 Gemini answers, 6 Gemini figures, 3 equations, 1 recommendation | **$0.31** | **79** | 137 | Free covers ~60% of it; Plus with lots of room. With the **Sonnet figures default**, the same basket costs $1.70 / 355 credits: 4.5× more, entirely from cache loads |
| **Regular** (reads and asks most days) | 12 papers; 80 Gemini answers, 20 figures, 10 equations, 6 searched answers, 2 papers in depth with Sonnet (12 warm answers, 4 figures), 1 podcast, 3 recommendations | **$2.22** | **519** | 801 | Plus (600) now. Needs a pack or a cheaper default after Gemini's price change |
| **Heavy premium** (Sonnet as a daily tool) | 25 papers with Sonnet (300 warm answers, 100 figures), 1 paper with Opus, 10 searched Sonnet answers, 4 podcasts, 20 Gemini answers | **$13.02** | **2,812** | 2,956 | Pro (2,000) plus a $9.99 and a $4.99 pack (3,000 credits): we receive $29.72 at 15% for $13.74 of cost (incl. fee) |

Per-subscriber contribution (proceeds after Apple 15% and 2% refunds, minus provider cost × 1.055 OpenRouter fee × 1.10
uncharged/failed work, minus $0.10 infrastructure; US prices, no VAT):

| Plan | Proceeds | 30% used | 50% used | 100% used | 100% used at Apple 30% |
|---|---:|---:|---:|---:|---:|
| Plus monthly $7.99 / 600 | $6.66 | $5.51 | $4.81 | $3.07 | $1.90 |
| Plus annual $79.99 (per month) | $5.55 | $4.41 | $3.71 | $1.97 | $0.99 |
| Pro monthly $19.99 / 2,000 | $16.65 | $13.07 | $10.75 | $4.95 | $2.01 |
| Pro annual $199.99 (per month) | $13.88 | $10.30 | $7.98 | $2.18 | **−$0.27** |
| Pack $4.99 / 300 (all redeemed) | $4.16 | | | $2.42 | $1.68 |
| Pack $9.99 / 700 (all redeemed) | $8.32 | | | $4.26 | $2.79 |

Only Pro annual can lose money, and only in the combined worst case (30% commission and every credit used every
month). Small Business enrollment removes the problem. Without it, Pro annual should be $219.99 or 1,800 credits.
Non-US storefronts include VAT in the price, so proceeds there are ≈ 15–20% lower. Every row stays positive at 15%
commission even with 20% VAT except Pro annual at full use (≈ −$0.1).

## 2. Plan design

### 2.1 Principles

- **Reading is free forever:** papers, library, sync, notes and snippets, the Feed, offline copies and playing shared
  podcasts. It runs on the device and costs about nothing per reader.
- **AI is metered in credits and described in answers.** Every plan and pack shows "about N answers with the default
  model". N comes from the server's measured trailing median, so copy changes when tariffs do.
- **Fast models are the default** (Gemini Flash today; see decision 4 for 2027). Premium models (Sonnet, Opus) are an
  explicit choice that shows its price before use.
- **Never "unlimited".** Allowances, packs, a visible balance and graceful fallbacks.
- **No feature is held back for Pro.** Pro buys a larger allowance at a lower price per credit (100 credits per dollar
  vs Plus 75). Equations, offline access, export and recovery stay on every plan.

### 2.2 Free tier and the hard free pool

**Allowance.** 50 credits per UTC month per account, about 15 default answers or 25 figure walkthroughs on Gemini. It
works only with fast models (Gemini Flash, DeepSeek Flash, Haiku), excludes web search and podcast generation (they
spend shared prepaid capacity and are the costliest per request), and does not roll over. Recommendations (1 credit)
are allowed. One account can cost at most 50 × $0.005 = **$0.25 a month**.

**Pool cap: $15/month to start.** That is ≈ 1,300 default answers across all free accounts, and it fits inside the
$30/month metered allocation of the existing $100 budget. Proposed growth rule, for the owner to accept: the cap
becomes max($15, 10% of the previous month's App Store proceeds). Paying users then fund the free tier, and the owner
never funds more than $15. The rule changes the cap only through the audited budget command, and Admin shows it.

**Why there is no surprise subsidy.** The pool is enforced by the machinery that already bounds platform spend: every
paid call first reserves its worst-case ceiling against the month's `platform_budgets` row under a lock, then settles
the actual cost ([SPENDING_CONTROLS](../architecture/SPENDING_CONTROLS.md#accounting-contract)). The proposal adds:

1. A second monthly budget row (scope `free_ai`, limit = the pool cap) next to the platform row, created and rolled
   forward by `worker_ensure_platform_budget` (migration 060), raised only by the operator budget command (0104).
2. A credit bucket source `free_monthly`, granted lazily at the account's first AI request of the month (the refill
   pattern of the testing allowance, migration 094), expiring at month end. An account still has to be verified to get
   it. In the app, the grant is also tied to the Apple app-transaction identity, as the Sandbox grants are (migration
   036), so new accounts on one device don't multiply it.
3. Any operation funded from a `free_monthly` bucket reserves its full ceiling against **both** the platform row and
   the `free_ai` row in the same transaction (lock order budget → account → bucket, unchanged). If the `free_ai` row
   can't take the ceiling, the request is refused before any provider call.
4. A per-account monthly cap of $0.25 on free-funded provider cost, checked under the same locks. This is the
   testing allowance's `monthly_cap_microusd` mechanism (migration 0105, not yet deployed), applied to free buckets.
   A daily limit of 20 credits stops a few accounts draining the pool on the 1st.

Holds reserve worst-case ceilings, so free spend cannot exceed the cap, even with concurrent requests or abandoned
streams. Uncertain attempts keep their hold until reconciled, as today. Account farming can only share out the capped
pool; it cannot enlarge it. When the pool runs out, free users see *"This month's free AI has all been used. It comes
back on November 1. Reading is unaffected. Plus starts at $7.99, or a $4.99 pack gives about 100 answers."* No paid
user is affected.

**Other free-user costs** are not AI: authentication, encrypted sync, storage and egress, budgeted at ≤ $0.02 per
monthly active free user (Supabase Pro includes 100k MAU and the transfer allowances in
[PRICING_RECOMMENDATION](../research/PRICING_RECOMMENDATION_20261008.md#podcast-unit-costs-and-hard-holds)). Platform
work that serves everyone (catalog tags ≈ $0.004 per paper, the curated podcast catalog at $3/month) stays under the
existing platform budget, not the free pool.

### 2.3 Paid plans, packs, annual and students

| Product | Price | Credits | Per credit to the reader | Why |
|---|---:|---:|---:|---|
| Plus monthly | $7.99 | 600/month | $0.0133 | The student and practitioner price point: below ChatGPT Go ($8), Readwise ($9.99–12.99), Explainpaper ($16), SciSpace (~$12–20). A Regular reader's month (519 credits) fits. Worst case (every credit used) still clears $3.07 |
| Plus annual | $79.99 | 600 each month | $0.0111 | "2 months free" ($6.67/month); annual plans retain better (§4) |
| Pro monthly | $19.99 | 2,000/month | $0.0100 | Sonnet as a daily tool: ≈ 20 papers studied in depth (≈ 93 credits each: one cache load, 12 answers, 4 figures). Same price as Claude Pro, ChatGPT Plus and Google AI Pro, but sold as "the paper reader with Sonnet built in" |
| Pro annual | $199.99 | 2,000 each month | $0.0083 | Needs Small Business (§1.4) |
| Pack S | $4.99 | 300, never expire | $0.0166 | The "$5" answer; pay-as-you-go for Free users; dearer per credit than any plan, so subscribing stays the better deal |
| Pack L | $9.99 | 700, never expire | $0.0143 | Top-up for heavy months |

- **Allowance timing.** Monthly plans grant on each verified renewal, as now. Annual plans grant 600/2,000 at the
  start of each monthly anniversary within the paid year. This needs the idempotent monthly issuance that
  [OPERATIONS_AND_BILLING §Subscription lifecycle](../architecture/OPERATIONS_AND_BILLING.md#subscription-lifecycle)
  already requires.
- **Spending order** (unchanged): soonest-expiring first, so free, then plan credits, then packs. A premium-model
  request skips the free bucket.
- **Upgrades** keep the existing rule: the new plan's credits arrive at once.
- **No free trial.** StoreKit reports a $0 trial transaction, and our server would grant the full allowance, which is
  exactly the subsidy the owner wants to avoid. Instead, an **introductory pay-up-front offer**: first month of Plus for
  $3.99 (one per subscription group; Apple supports pay-as-you-go and pay-up-front intros). If a free trial is ever
  wanted, grant only the Free allowance during it; the transaction's offer type identifies trials.
- **Student pricing: not at launch.** Apple has no student verification. Competitors currently give students AI for
  free (Google AI Pro free for a year to US college students through 2026-12-31; OpenAI's back-to-school months of Plus;
  Perplexity $10), so a discount would not win on price. Plus annual at $6.67/month is the student price. Later option:
  verify an academic email on the website and issue App Store **offer codes** for Plus annual at $49.99.
- **Family Sharing:** off. Apple doesn't allow it for consumables, and a shared subscription allowance would need its
  own accounting.

**What premium models cost, shown in the model picker and before sending:**

| Model | First request on a paper | Each later request (within the hour) |
|---|---:|---:|
| Gemini Flash (default) | ≈ 3 | ≈ 3 (≈ 5 from 2027) |
| DeepSeek Flash / Haiku | 1–3 | 1 |
| **Sonnet 5.5** | **≈ 25 for chat, ≈ 48 for a figure** (loads the paper into its cache for an hour) | ≈ 4–5 |
| **Opus 5.5** | ≈ 50–95 (estimate, 2× Sonnet) | ≈ 7–10 |

Cost reduction to try before launch: for a Sonnet request when the reader hasn't used Sonnet on this paper in the last
hour, write a 5-minute cache (1.25× input) instead of a 1-hour one (2×). That cuts the cache write from ≈ $0.22 to
≈ $0.14 (a cold figure ≈ 48 → ≈ 32 credits). The cost is that reads after 5 idle minutes re-load the paper.

### 2.4 "Price before you run it" rules

Today the server publishes estimates ("Usually 4–24 credits · up to 37") and the apps show them along with the charge
afterwards. The proposal adds a confirmation only where a surprise is possible:

| Situation | What the reader sees |
|---|---|
| Estimate ≤ 10 credits (default answers, figures, equations, recommendations) | No interruption. The estimate shows near Send; "3 credits · 412 left" shows after |
| First premium request on a paper (the server predicts a cold cache from the last use of that model on that paper) | One-tap confirm: "Sonnet reads the whole paper first: about 48 credits, then about 5 per figure for the next hour." Choices: Continue · Use Gemini (about 2) · Don't ask again for Sonnet |
| Usual cost > 10 credits, or maximum > 25 (Opus, long searched answers) | Same confirm, showing usual and maximum |
| Podcast generation | Always confirm: "Usually about 55–60 credits · up to 150. Charged only if the episode is ready." |
| Web search turned on | "+ about 2 credits per search" next to the toggle |
| A choice that exceeds the balance | The out-of-credits sheet below, before anything is sent |

The thresholds are server-published (`confirm_above_credits`, `first_use` flags in the profile table), so they can be
tuned without a release. No silent model escalation, re-quote or paid retry, all of which are already guaranteed.

### 2.5 When credits run out

Never a silent failure, and nothing already read or saved becomes unavailable (downloaded papers, saved explanations,
chats and podcasts stay).

1. **Low balance** (below 10% of the plan, or below the next request's usual cost): a quiet line under the composer:
   "18 credits left this month (about 6 answers). Renews Nov 3."
2. **Not enough for this request:** the server's `insufficient_credits` response lists the profiles that **do** fit. The
   sheet offers: **"Answer with Gemini Flash instead (about 3 credits)"** first, then **Buy 300 credits ($4.99)**, then
   **Upgrade to Pro**, then **Wait until Nov 3**. The draft stays in the composer.
3. **Zero balance:** AI controls stay visible and lead to the same sheet. Reading, search in the library, notes and
   shared podcasts are unaffected.
4. **Free pool exhausted:** the message in §2.2; packs and Plus remain available.
5. **Platform budget paused** (the owner's safety cap): the existing "AI answers are paused right now" message. The cap
   must scale with paid usage (§5) so paying users never hit it in normal operation.

## 3. Break-even

### 3.1 Fixed monthly costs

| Item | Monthly | Source / status |
|---|---:|---|
| Supabase staging (Micro compute) | ≈ $10 | OPERATIONS_AND_BILLING "Fixed commitments" (0.01344/h); net of the org's compute credit unverified |
| Supabase **production** project (Micro) | ≈ $10 | **Not yet provisioned**; needed before public launch ([Supabase pricing](https://supabase.com/pricing)) |
| Supabase Pro organization base | $0–25 | Shared with TextBrain; attribution **unknown** |
| Tavily | $30 today → **$0** on the free tier | Owner invoice Oct 6; downgrade recommended at the Nov 6 renewal |
| Domains (gradstep.ai 2 yrs $179.96, gradstep.shop) | ≈ $7.60 amortized | Already paid; not a new cash charge |
| Apple Developer Program | $8.25 ($99/yr) | Whether it is incremental is **unknown** (OPERATIONS_AND_BILLING) |
| Cloud Run pipeline + workflow checks | ≈ $0–3 | Request billing, forecast, not an invoice |
| Cloudflare Pages (site, browser reader, admin) | $0 | Free tier |
| Curated podcast catalog | $3 | DECISIONS 2026-10-09 allowance |
| Backups, Resend alert email, Secret Manager/registry | **unknown**, est. ≤ $5 | Not invoice-attributed |
| OpenRouter 5.5% funding fee, Google TTS, model calls | Variable | Included in per-user costs above |
| **Free AI pool** | **$15** | This proposal |
| **Total, lean** (Tavily free, no org base, Apple already paid) | **≈ $60** | |
| **Total, today's configuration** (Tavily $30, org base $25) | **≈ $115** | |

### 3.2 Subscribers needed

Contribution per subscriber at 50% of the allowance used: All-Plus $4.81 (Apple 15%) / $3.64 (30%). Typical mix (55%
Plus monthly, 25% Plus annual, 15% Pro monthly, 5% Pro annual) $5.59 / $4.13. Pro-heavy mix (40/20/30/10) $6.69 /
$4.90. Packs add margin on top and are left out.

| Fixed costs | Mix | Apple | Break-even | +$1,000/month | +$5,000/month |
|---|---|---|---:|---:|---:|
| $60 | Typical | 15% | **11** | **190** | **906** |
| $60 | Typical | 30% | 15 | 257 | 1,225 |
| $60 | All Plus | 15% | 13 | 221 | 1,051 |
| $60 | Pro-heavy | 15% | 9 | 159 | 757 |
| $115 | Typical | 15% | 21 | 200 | 916 |
| $115 | Typical | 30% | 28 | 270 | 1,238 |
| $115 | All Plus | 30% | 32 | 307 | 1,406 |

If every subscriber used every credit, the typical-mix contribution drops to $3.03 (15%) and the $1k target needs
≈ 350 subscribers. The worst case still makes money; it just takes more subscribers. With the free pool growth rule,
10% of proceeds funds the free tier, which adds ≈ 17% to the $1k/$5k subscriber counts (≈ 225 / ≈ 1,060).

### 3.3 Sensitivity to conversion

Payers needed ÷ conversion = monthly active users (MAU) needed (typical mix, 15%):

| Conversion of MAU to paid | Break-even (11–21) | $1k/month (≈ 200) | $5k/month (≈ 910) |
|---|---:|---:|---:|
| 1% | 1,100–2,100 | 20,000 | 91,000 |
| 2% (RevenueCat freemium median) | 550–1,050 | 10,000 | 45,500 |
| 3% | 370–700 | 6,700 | 30,300 |
| 5% (top-quartile freemium) | 220–420 | 4,000 | 18,200 |

Because of churn, those subscribers must be kept up continuously. At 8–12% monthly churn (AI apps churn ≈ 30% faster
than others), holding 200 payers needs **16–24 new payers a month**, about **800–1,200 downloads a month at 2%**.
Holding 900 needs 72–108 new payers, about **3,600–5,400 downloads a month**. Annual plans reduce this.

**Apple's cut:** Small Business (15%) versus standard (30% in a subscriber's first year) moves every target by
≈ 25–35%. Linking out to web purchase in the US is currently commission-free under the Epic injunction, but the
Supreme Court took the case on 2026-06-30, and Apple has proposed a 5–15% commission. Don't build on 0%.

## 4. Market view: can this make real money?

**What the comparables charge** (checked 2026-10-21; third-party sources marked):

| Product | Price | Notes |
|---|---|---|
| Readwise Reader | $12.99/mo; $9.99/mo annual | 50% academic discount by request |
| Explainpaper | Free tier; Pro $16/mo | Claims 400k+ researchers |
| Paper2Audio (paper podcasts) | Free tier; Plus $16/mo | Closest match to podcasts |
| Undermind | Pro $16/mo annual | |
| SciSpace | ≈ $20/mo; ≈ $12/mo annual (third-party) | |
| Consensus | ≈ $10–15/mo (third-party) | ≈ 40% student discount reported |
| Elicit | Free basic; Pro $49/mo | Aimed at professionals |
| alphaXiv, Semantic Reader | Free | alphaXiv raised a $7M seed (Nov 2025) |
| ChatGPT Go / Plus | $8 / $20 | Free months of Plus for US students (2026 offer) |
| Claude Pro, Perplexity Pro | $20 ($17 annual), $20 (students $10) | |
| Google AI Plus / AI Pro (incl. NotebookLM, now "Gemini Notebook") | $9.99 / $19.99 | **AI Pro free for a year to US college students** through 2026-12-31 |

The market accepts $8–20/month for research AI. Plus at $7.99 is at the low end and Pro at the mainstream $19.99.
General assistants already give students paper chat for free, so Gradstep can't win on AI volume per dollar. It has
to win on what they don't do well: a native iPad/iPhone reader of the exact arXiv paper, typeset equations, figure
walkthroughs that point at the right panel, passage-linked chat, offline reading and device-held encryption.

**Audience size.** arXiv served ≈ 410M downloads in 2025 (≈ 34M/month; 38–50M/month in 2026) and receives ≈ 30k
submissions a month (a record 40k in September 2026). NeurIPS 2025 had ≈ 26k registrants. The US awards ≈ 46k science
and engineering doctorates a year and has ≈ 190k CS graduate students (fall 2025, secondary source). There is no
credible count of ML practitioners. **Inference:** the people who read ML papers every week number a few hundred
thousand to low millions worldwide. A specialist iPad/iPhone reader is a niche inside that, but a real one.

**Calibration.** RevenueCat's 2026 report (2025 data): median download-to-paid within 35 days is 2.0% (freemium 2.1%,
top quartile > 4.5%; North America 2.8%). Revenue per install is $0.27–0.38 by day 14–60 for freemium. Education's median
yearly price is $44.99. AI apps keep 21% of annual subscribers after a year vs 31% for other apps. Consensus reported
≈ 400k MAU at ≈ $1.5–2M ARR at its 2024 Series A (≈ $4–5 per MAU-year), with a broader product and a sales team.

**Realistic for a solo-maintained app (inference):**

| Outcome | What it looks like | Monthly net |
|---|---|---|
| Hobby that pays for itself | 1–3k MAU, 20–60 payers | ≈ $50–300 |
| Good niche app | 5–15k MAU, 150–400 payers; known in a few labs and ML Twitter/Bluesky circles | ≈ $800–2,200 |
| Breakout in its niche | 40k+ MAU, 900+ payers; the reader people recommend for arXiv on iPad | ≈ $5,000+ |

The second row is reachable with steady word of mouth (≈ 1,000 downloads a month). The third needs the app to be the
default answer to "how do you read papers on an iPad", plus a browser presence that converts. **Because the free tier
is capped and reading costs nothing, a "loved but not lucrative" outcome cannot lose money.** That suits the owner's
stated goal.

**Who pays.** ML practitioners at companies pay most readily (often expensed; Pro and Sonnet). PhD students are the
largest group and the most price-sensitive, and are courted by free offers from Google, OpenAI and Perplexity; they
want Plus annual and packs. Researchers and faculty are fewer but loyal. **Lab or institutional licences** (a seat
pack sold on the web, credits pooled per lab) are a sensible later option once ≈ 5 labs ask. They need web billing,
invoices and seat management, so not at launch.

**What "a good number of people love it" looks like in numbers:** ≥ 1,000 weekly active readers; ≥ 35–40% of new
readers who open three papers still reading in week 4; ≥ 4.6★ with 100+ App Store ratings; ≥ 100 paying subscribers
(which by §3 already covers every cost several times over); and unprompted mentions or recommendations in a few ML
communities each month. Admin can track all of these except ratings and mentions.

## 5. Implementation notes (no code changed)

**Already in place** (staging): credit buckets with expiry and soonest-first spending; StoreKit verification,
renewals, refunds, upgrades and replay safety (`store_products` maps three products: `standard.monthly` 800,
`pro.monthly` 1,800, `credits.400`; Sandbox only, no production sales); per-operation holds and settlement against the
monthly `platform_budgets` row (October: $40 limit, $32.08 spent at reading time); per-attempt provider ledger with
account, feature and model, and Admin › Costs per account (0141, local, not deployed); server-published per-profile
estimates; the per-question hold capped at the balance; the audited operator budget command (0104) and per-account
monthly provider caps (0105), both not yet deployed; the Sandbox identity allowance (036); budget health alerts (060).
The reader usage table being built now is where "about N answers" and per-activity history belong.

**What changes:**

| Area | Change |
|---|---|
| App Store Connect | Products: keep `standard.monthly` (display name "Plus", price $7.99) and `pro.monthly` ($19.99); add `standard.annual` ($79.99), `pro.annual` ($199.99), `credits.300` ($4.99), `credits.700` ($9.99); retire `credits.400` for new sales but keep its mapping for existing receipts. Intro offer on Plus. Small Business enrollment. Production Supabase project before the first production sale |
| Server (one additive migration) | Allowance changes in `store_products` (versioned by effective date; existing transactions keep what they were sold). Annual monthly issuance. `free_monthly` bucket and lazy grant. `free_ai` budget row with dual reservation. Per-account free cap and daily limit. Model eligibility per bucket. `insufficient_credits` returns fitting profiles. Profile table publishes `confirm_above_credits`, `first_use` prediction (last use of that model on that paper per account), and "about N answers" figures from trailing medians |
| Platform budget | Split the single cap into: free pool (owner money), platform work (tags, catalog podcasts, uncharged failures; owner money), and customer-funded spend (prepaid by credits sold). The global safety cap stays, alerts at 80%, and is raised by the owner as paid volume grows, never automatically |
| Apps and browser | Paywall / Get credits sheet with plans in answers. Premium confirm sheet. Out-of-credits sheet with the cheaper-model offer. Low-balance line. Free-pool message. Settings shows plan, renewal date and balance in answers. Purchases stay in the apps; the browser shows balance and plan and says where to buy (no web checkout at launch; later Stripe or a merchant of record such as Paddle at ≈ 5% + 50¢, with US link-out) |
| Copy and legal | Plan descriptions, "never unlimited" wording, expiry rules (packs never expire, per guideline 3.1.1), terms and privacy policy (OWNER_ACTIONS #6) |
| Admin | Free pool remaining. Proceeds by product (from verified transactions). Contribution per plan. Share of free users who use AI |

**Order:**

1. Owner decisions (top of this document). Record them in DECISIONS.md.
2. Owner: Small Business enrollment; Tavily downgrade at renewal; production Supabase project plan.
3. Decide the 2027 default model (decision 4) and the figures default (decision 3), because "about N answers" depends
   on them. If DeepSeek on Together is chosen, ship its consent version with the next release.
4. Server migration: products and allowance versions, annual issuance, free bucket and pool, eligibility, confirm and
   fitting-profile fields. Database tests for the pool bound under concurrency, which is the one property that keeps
   the owner's promise.
5. Clients: paywall, confirm, out-of-credits and low-balance sheets; Settings. Simulator and browser journeys.
6. Sandbox purchase journeys for every product, including annual issuance and an upgrade. Then TestFlight with the free
   tier on a small pool ($2) to watch real free usage.
7. Measure for a month: credits per active user per plan, free-to-paid conversion, share of the free pool used. Adjust
   allowances before public launch rather than after.

## Sources

Internal: [DECISIONS](../DECISIONS.md) (subscriptions and credits 2026-10-05; $5 usage 2026-10-19; dollar balances
2026-10-20; figures default 2026-10-22); [PRICING_RECOMMENDATION_20261008](../research/PRICING_RECOMMENDATION_20261008.md);
[OPERATIONS_AND_BILLING](../architecture/OPERATIONS_AND_BILLING.md); [SPENDING_CONTROLS](../architecture/SPENDING_CONTROLS.md);
[PROVIDER_SPENDING](../architecture/PROVIDER_SPENDING.md); [PURCHASES](../architecture/PURCHASES.md);
[DOLLAR_BALANCE](../architecture/DOLLAR_BALANCE.md); [CHAT](../architecture/CHAT.md); [FIGURE_VIEW "Speed"](../architecture/FIGURE_VIEW.md);
[PAPER_PODCASTS](../architecture/PAPER_PODCASTS.md); [OWNER_ACTIONS](../OWNER_ACTIONS.md); tariff files under
`supabase/functions/_shared/`; staging ledger (read-only, 2026-10-22 ≈ 05:30 UTC).

External (read 2026-10-21; [3p] = third-party, not confirmed on the vendor's page):
- Apple: [Small Business Program](https://developer.apple.com/app-store/small-business-program/);
  [auto-renewable subscriptions, offers, 30%→15%](https://developer.apple.com/app-store/subscriptions/);
  [App Review Guidelines 3.1.1 (credits may not expire), 3.1.2](https://developer.apple.com/app-store/review/guidelines/);
  [Family Sharing](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases/);
  [price points](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price/).
- US link-out: [Courthouse News, 2026-08-11](https://www.courthousenews.com/apples-fight-over-commissions-for-linked-out-app-store-purchases-continues-in-federal-court/);
  [Mac Observer on Apple's proposed rates](https://www.macobserver.com/news/apple-epic-link-out-commission-proposal-15-percent/).
- Web payments: [Stripe pricing](https://stripe.com/pricing); [Paddle](https://www.paddle.com/pricing);
  [Lemon Squeezy](https://www.lemonsqueezy.com/pricing).
- Providers: [OpenRouter pricing](https://openrouter.ai/pricing); [Supabase pricing](https://supabase.com/pricing);
  [Tavily credits](https://docs.tavily.com/documentation/api-credits).
- Comparables: [Readwise](https://readwise.io/pricing); [Explainpaper](https://www.explainpaper.com/);
  [Paper2Audio](https://www.paper2audio.com/pricing); [Undermind](https://www.undermind.ai/pricing);
  [Elicit](https://elicit.com/pricing); [Google AI plans](https://one.google.com/about/plans);
  Consensus [3p: toolsforhumans](https://www.toolsforhumans.ai/ai-tools/consensus), [3p: CostBench](https://costbench.com/software/ai-research-tools/consensus);
  SciSpace [3p: CostBench](https://costbench.com/software/ai-research-tools/scispace/);
  ChatGPT Go [3p: Daring Fireball, 2026-01-16](https://daringfireball.net/linked/2026/01/16/chatgpt-go),
  [OpenAI student offer](https://help.openai.com/en/articles/20001493-chatgpt-back-to-school-offer-for-students);
  Perplexity students [3p](https://www.layer3labs.io/guides/perplexity-student-discount);
  Google AI Pro for students [3p: MacRumors, 2026-08-19](https://macrumors.com/2026/08/19/students-free-year-google-ai-pro);
  alphaXiv [SiliconANGLE, 2025-11-19](https://siliconangle.com/2025/11/19/alphaxiv-raises-7m-funding-become-github-ai-research/);
  Consensus revenue [3p: Pulse 2.0](https://pulse2.com/consensus-ai-based-scientific-research-search-engine-raises-11-5-million-series-a).
- Audience: [arXiv monthly submissions](https://arxiv.org/stats/get_monthly_submissions),
  [arXiv monthly downloads](https://arxiv.org/stats/get_monthly_downloads);
  [NeurIPS 2025 fact sheet](https://media.neurips.cc/Conferences/NeurIPS2025/press/NeurIPS2025-Fact_Sheet.pdf);
  [NSF NCSES doctorates 2024](https://ncses.nsf.gov/pubs/nsf26315); [CRA Taulbee 2025](https://datavisualization.cra.org/TaulbeeReports/2025/).
- Conversion and churn: [RevenueCat State of Subscription Apps 2026](https://www.revenuecat.com/state-of-subscription-apps);
  [TechCrunch on AI-app retention, 2026-03-10](https://techcrunch.com/2026/03/10/ai-powered-apps-struggle-with-long-term-retention-new-report-shows);
  [9to5Mac on annual renewals, 2026-05-27](https://9to5mac.com/2026/05/27/new-report-shows-annual-app-subscribers-rarely-return-after-they-cancel/).

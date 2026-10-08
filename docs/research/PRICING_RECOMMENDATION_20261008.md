# Gradstep pricing and shared-podcast economics

2026-10-08. **Recommendation for owner review, not a price change or spending authorization.**
The approved offers remain Standard $9.99/800 credits, Pro $19.99/1,800, and a $4.99/400-credit
nonexpiring pack. This work makes no provider call, purchase, deployment or production-revenue claim.
Reproduce the calculations with `python3 scripts/unit-economics.py` or `--json`.
Podcast implementation design: [PAPER_PODCASTS.md](../architecture/PAPER_PODCASTS.md).

## Recommendation

Keep the **$9.99 and $19.99 monthly price points**. For public launch, propose **500 and 1,200 credits**,
with a **$4.99/250-credit pack**, subject to the workload/value gate below. Both paid tiers get the complete
reading, library, sync and chat experience; Pro buys 2.4 times the allowance for twice the price. Every
supported model/tool is metered on both plans. Do not sell unlimited generation or reserve scientific
correctness, offline access to downloaded papers, or recovery/export for the expensive tier.

This is a conservative starting offer, not proof that the current allowances lose money. At ordinary
utilization the approved plans have useful contribution; at full utilization they have less room for
support, refunds, free users and quality repairs. The recommendation combines that risk with a substantial
specialist-reader product, approximately 300-credit light and 1,000-credit regular monthly workloads,
and the ability to buy extra credits. It must survive actual workflow measurement before launch: do not
cut allowances simply to make a simultaneous worst-case fee/tax/usage scenario look attractive.

Make shared podcasts an included reason to return to Gradstep: **browse and play already-created episodes
without generation credits**, subject to clear transfer limits. Curate a small platform-funded catalog;
charge credits only for an explicitly requested private generation. Start with one English paper, a
five-minute target, two fixed synthetic hosts, evidence-linked transcript and offline playback. Ten-minute
and custom variants follow quality/cost evaluation. No music, voice cloning or personal-chat input in v1.

Current offers and purchased benefits must survive any accepted change. The existing pack product ID says
`credits.400`; a 250-credit pack needs a new product ID, not a changed meaning for existing receipts. Pin
allowance policy by verified product/transaction, preserve nonexpiring pack balances, and do not silently
reduce an existing subscriber's renewal benefit. A public offer transition needs StoreKit disclosures and
an explicit legacy-product policy. There is also an existing unresolved upgrade discrepancy: the owner
approved keeping prior-period credits, whereas the recorder currently ends the replaced period's unused
credits. Resolve and test that policy separately; neither outcome is hidden in this model.

## Evidence and limits

Read-only staging observations collected by the takeover lead in `.artifacts/takeover-20261008`:

| Evidence | Meaning |
|---|---|
| Provider budget $25; recorded spent $13.677389; reserved $0 | $11.322611 of recorded provider headroom at that instant; not total operating-budget headroom |
| 12 recent chat attempts: mean $0.073520, median $0.068097, p95 $0.181499 | Tiny beta sample of transport attempts, **not complete answers or a representative user cohort** |
| Eight tag calls: mean $0.00393 | Platform-funded classification expense, not customer chat credits |
| Sandbox packs granted 400 + 400 + 200 | Verifier/grant proof up to the Sandbox cap, **not sales or revenue** |

The financial baseline is stronger than the original podcast report: migrations034–038 and the private
purchase verifier are deployed; Cloud Run is now request-billed. Storage inventory is deployed, but current
reader delivery still has a legacy compatibility mode with replayable signed URLs. New podcast delivery
must be bounded from its first release. See [spending controls](../architecture/SPENDING_CONTROLS.md),
[provider accounting](../architecture/PROVIDER_SPENDING.md) and
[asset accounting](../architecture/ASSET_SPENDING.md). These controls do not include every infrastructure
invoice, customer-support hour or exposure from free accounts.

## What the allowance buys

One credit currently represents **$0.005 of provider-equivalent usage**, not $0.005 of proceeds or a
universal retail price. A new Mathpix page is one credit at the deployed $0.005/page route. An eligible
exact shared conversion already in the catalog needs no new OCR. Private copies cannot borrow another
account's conversion. These examples use full-new-page costs; shared reuse improves them.
[Mathpix's route pricing](https://mathpix.com/pricing/api).

Answer prices below are **scenario assumptions**, not a promise derived from twelve attempts. They include
all model rounds for an answer; search units and any extra tool execution must be included in the actual
versioned quote. Paper size, cached context, answer length and effort can change the result considerably.

| Monthly reading basket | Illustrative credits | Fit |
|---|---:|---|
| Eight new 12-page papers; 20 short answers at 10 credits; four shared episode listens | 96 + 200 = **296** | Proposed Standard leaves 204 |
| Sixteen new 20-page papers; 40 answers at 15 credits; one new five-minute private episode at a 53-credit planning allowance | 320 + 600 + 53 = **973** | Proposed Pro leaves 227 |
| Forty new 20-page papers; 100 complex answers at 30 credits; four private five-minute episodes at 53 credits | 800 + 3,000 + 212 = **4,012** | Heavy use needs packs or a future measured higher tier; no unlimited claim |

The private-episode planning allowance is cost-equivalent with quality/runtime allowances, not the exact
customer charge: actual credit settlement excludes platform-funded retries, runtime and QA unless the
published rate policy explicitly includes them. A larger temporary hold may be required before generation.
Without other usage, 500 credits could fund 25 new 20-page papers, or roughly 16–50 answers at 30–10 credits;
1,200 could fund 60 such papers, or 40–120 such answers. Those are alternatives, not additive entitlements.

Value check: Readwise Reader currently costs $12.99 month-to-month ($9.99/month billed annually), including
Readwise. Google's US AI Pro page lists $19.99/month and includes NotebookLM among a broader bundle.
Gradstep needs to earn its price through reliable equations, paper-to-chat passages, scientific evidence,
native/offline reading and a useful ready-to-play library, not claim the most raw AI calls per dollar.
[Readwise pricing](https://readwise.io/pricing/reader),
[Google AI plans](https://one.google.com/about/google-ai-plans/).

Before adopting the proposed allowance, measure at least 30 complete representative journeys across short,
long, equation-heavy and search-heavy papers, then a beta cohort's full-month distribution. Include every
provider attempt, refusal/fallback, search, failed job and cache miss. Publish representative examples and
the actual maximum before use. If a regular researcher's basket does not fit Pro comfortably, first improve
cache/tool use and offer a quality-tested cheaper model; revisit allowance/price with measured evidence.

## Contribution scenarios

Apple's reduced 15% commission needs **approved Small Business Program enrollment**, not merely a developer
account or signed agreements. Standard subscriptions generally yield 70% in year one and 85% after a
subscriber's first year, before applicable taxes. Model 30% until eligibility is evidenced. The 20% tax
example is an illustrative tax-inclusive storefront; VAT rates, local price points, FX and proceeds differ
by territory. Do not apply tax removal twice to Apple's actual proceeds reports.
[Small Business Program](https://developer.apple.com/app-store/small-business-program/),
[subscription proceeds](https://developer.apple.com/app-store/subscriptions/),
[tax categories](https://developer.apple.com/help/app-store-connect/manage-app-information/set-a-tax-category).

Model: `proceeds = price / (1 + included tax) × (1 − commission) × (1 − refund fraction)`.
Subtract utilized credits × $0.005; add 10% of that usage for uncharged failed/uncertain/repaired provider
work; subtract a planning variable-infrastructure allowance of $0.30 Standard/$0.50 Pro. Refunds reduce
proceeds without assuming already-incurred provider cost disappears. Packs are modeled at eventual **100%
redemption** with no separate monthly infrastructure allocation; unused nonexpiring packs are liabilities,
not assumed breakage. The 10%, refund rates, utilization and infrastructure amounts are assumptions.

Contribution **before fixed operating costs, customer support, salaries, acquisition and income tax**:

| Scenario | Approved Standard 800 | Approved Pro 1,800 | Proposed Standard 500 | Proposed Pro 1,200 |
|---|---:|---:|---:|---:|
| Ordinary: 50% utilization, 15% fee, no included tax, 2% refunds | $5.82 | $11.20 | $6.65 | $12.85 |
| Same ordinary utilization, 20% included tax | $4.43 | $8.43 | $5.26 | $10.08 |
| Heavy: 100% utilization, 15% fee, 20% included tax, 2% refunds | $2.23 | $3.48 | $3.88 | $6.78 |
| Stress: 100% utilization, 30% fee, 20% included tax, 3% refunds | $0.95 | $0.91 | $2.60 | $4.21 |

The current 400-credit pack contributes $1.26 in the ordinary tax-inclusive fee scenario and $0.62 under
stress, versus $2.09/$1.45 for the proposed 250 pack. These figures are not profit and do not establish a
whole-system ceiling. A 10% uncharged-cost allowance could be insufficient if quality is poor; display
observed rates separately and stop generation when its quality/sub-budget gate is hit.

## Fixed costs, free users and Tavily

Illustrative first-month envelope: $25 Supabase + $30 Tavily + $2 request-based worker allowance + $8 for
backup/build/registry/secrets/domain allocation + **$2 one-time podcast pilot = $67**. Later months in this
example total $65 before variable provider use, with no recurring podcast seed allowance. Only the $30 Tavily
commitment is taken directly from the owner's invoice; Supabase may be incremental $10 for another project
in an already-paid organization instead of $25, and the remaining numbers are placeholders requiring invoice
attribution. The $2 podcast allocation is **inside** the existing $25 provider cap, never on top of it;
retain the $100 total incremental beta ceiling. Taxes on vendor bills can also add costs.

At a 50/50 Standard/Pro payer mix, covering that $67 alone takes approximately 11 approved-offer payers or
nine proposed-offer payers in the ordinary tax-inclusive scenario; 72 or 20 in stress. This is infrastructure
coverage, not a viable salary/support business. At 100 such proposed subscribers, ordinary contribution is
about $767 before those $67 fixed costs; support, unpaid users and acquisition still have to be paid.

**Recommend downgrading Tavily at the next renewal if the owner's measured calendar-month demand stays
below 800 credits**, with PAYGO remaining off and a 900-credit internal cap plus verified baseline. Its free
tier advertises 1,000 credits/month; the $30 Project commitment supplies 4,000. Their usage reset is the first
of the calendar month, separate from the sixth-of-month invoice. Record the actual provider timezone and
used baseline before switching; never reset the allowance because a subscription changed. Exhaustion should
disable extra web search clearly while paper-only answers and free metadata remain usable. Native Anthropic
search is currently gated off because its hidden result-token cost lacks a proven bound; it is not an
automatic uncapped fallback. A free-plan scenario lowers this illustrative first-month envelope from $67
to $37, and later fixed months from $65 to $35; variable provider use remains separate.
[Tavily pricing and resets](https://www.tavily.com/pricing).

Free download should permit reading retained papers and a small shared podcast sample, with **no automatic
recurring AI grant**. A free listener still costs authentication, delivery and support: 1,000 free listeners
at an assumed $0.05 each add $50/month. If offering an introductory AI trial later, cap its total platform
allocation and verified identity grants; do not multiply an unrestricted free grant by every OAuth account.
Sandbox's 1,000-credit allowance is for testing, not a public trial design. Do not delete existing files or
invalidate downloaded reading simply because a plan lapses. Storage/transfer allowances require separate
admission and clear product wording; initial paid private storage stays within the existing 1 GiB/account.

## Podcast unit costs and hard holds

At current public rates Sonnet 5.5 costs $2/M input and $10/M output tokens. Gemini 3.8 Flash TTS costs
$0.50/M text input and $9/M audio output through December 2026, then $1/$18 from January; audio uses 25
tokens/second. OpenAI mini TTS is $0.60/M text input and $12/M audio output, with a 2,000-input-token request
limit; no assumed output-token/minute conversion should become a guaranteed quote. Keep it as a separately
bounded comparison adapter, not an automatic paid fallback.
[Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing),
[Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing),
[OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[OpenAI speech model](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts).

Assume a 20,000-token paper and 200 spoken-text tokens/minute. Two script passes consume `44,000 + spoken`
input and `spoken + 2,000` output tokens; speech includes 500 direction tokens. No cache savings assumed.
Planning column adds 25% quality/failed-work allowance, $0.01 runtime, and an optional $0.003/minute QA
transcription allowance (a planning amount, not a newly selected production transcription provider).

| Target | Clean current | Planning current | Clean January | Planning January |
|---|---:|---:|---:|---:|
| Five minutes | $0.188 | $0.260 | $0.257 | $0.346 |
| Ten minutes | $0.268 | $0.375 | $0.405 | $0.546 |
| Twenty minutes, later option | $0.428 | $0.605 | $0.701 | $0.946 |

Twenty-minute values are density estimates; required chunk/context repetition can add cost. New OCR for
20 pages adds $0.10. Thirty ten-minute generations/month therefore budget about $11.26 now/$16.37 January
before OCR, fixed costs or human review: do not include thirty free custom generations in a $19.99 plan.

**An expected $0.26 episode is not a $0.26 spend cap.** Proposed initial five-minute profile: two script
calls, each bounded to 80,000 conservative input tokens including instructions/metadata, maximum 6,000 then
4,000 output tokens, no hidden fallback or tools; one speech call reserves its full serving limit of
8,192 input/16,384 output tokens at January prices. Calculated provider ceiling is $0.723104, rounded to a
**$0.75 / 150-credit maximum**. A smaller transcript or requested duration is not proof of a smaller billing
limit. If full request accounting exceeds these bounds, refuse/requote before sending; do not truncate a
paper silently. Two speech calls require at least $1.026208/206 credits before further headroom. Provider
serving-limit and usage reconciliation tests must pass before enabling this adapter.
[Gemini model limits](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts).

The app should say “Usually about 40–70 credits; maximum 150” **only after real measurements support that
range**. Initially label estimates as estimates; show the hold, actual charge and released amount. No
automatic paid repair or full regeneration in v1. Quality failures release customer credits while retained
provider expense consumes the platform quality allowance. Cancellation after submission settles known
incurred usage up to the disclosed maximum, stops future calls, and preserves unknown provider liabilities.

At mono 64 kbit/s, a ten-minute episode is about 4.8 MB. Ten thousand retained episodes are 48 GB, roughly
$1.02/month at the marginal $0.0213/GB storage rate. One hundred thousand full downloads are 480 GB, roughly
$14.40 cached or $43.20 uncached egress before included allowances. Supabase Pro lists 100 GB storage and
250 GB in each egress pool, shared with the rest of the organization. Our authenticated proxy path must not
be assumed cached; budget uncached transfer until observed, including both storage and response legs where
applicable. Delivery bandwidth, temporary WAVs, retries, Edge invocations and logs still need counting.
[Supabase pricing](https://supabase.com/pricing).

The existing worker uses request billing. A modeled 1 vCPU/2 GiB for 60–300 seconds costs roughly
$0.00174–$0.00870 before free allowances at the cited active rates; this is not measured deployment cost.
Await work within a bounded request, minimum instances zero, reserve wall/CPU/concurrency, and include
transcoding/temp storage. Do not restore an always-awake loop for audio.
[Cloud Run pricing](https://cloud.google.com/run/pricing).

## More models, effort and tools

Offer **Quick / Standard / Deep** as server-versioned profiles, with the exact model available under a
disclosure. Standard keeps the deployed Sonnet 5.5 low-effort behavior. Quick should evaluate current Haiku
5.5 for short grounded explanations; Deep initially uses the same Sonnet with a larger explicit reasoning/
output budget, not a switch to an unbounded “best available” model. Quick must pass factual/equation fixtures
before it is marketed as a cheaper substitute. The current Haiku 5.5 published input/output tariff is
$0.10/$0.50 per million for prompts up to 100,000 tokens, rising to $0.50/$2.50 above that boundary; quote
the correct whole-request tier. Existing Haiku 4.5 tagging is a separate route; no silent model replacement.
[Model pricing](https://platform.claude.com/docs/en/about-claude/pricing).

Changing model, effort or enabled tools changes **both** expected and maximum credits. Freeze profile,
model snapshot, rate version, input hash, maximum output (including reasoning), search count, tool-result
bytes and total rounds in the quote. Reserve each actual transport from the parent envelope; stop before a
next round that cannot fit. Settle actual complete usage once, round credits once per operation, and explain
uncertain or interrupted charges. No hidden re-quote, automatic model escalation or extra paid fallback.

Prioritize useful bounded tools: compare selected papers, explain a passage/equation, extract assumptions
and limitations, evidence-linked study questions, and search related work. Retrieval has account, source,
document-count and context-byte caps; deterministic math/code tools run in an isolated CPU/time/network
sandbox and are never arbitrary server execution. Tool-written library changes still require user intent
and the current dataset epoch. Podcast generation is an explicit quoted action, never an implicit model
tool expenditure. Measure cost per completed answer/profile, not just transport attempt averages.

## Three decisions to close before activation

1. **Public offers:** accept 500/1,200 and a new 250 pack as a launch candidate, preserving existing benefits,
   with the stated workload gate; or retain 800/1,800/400 pending more beta evidence. Recommendation: adopt
   the candidate for evaluation, change no live offers yet, and verify Small Business enrollment.
2. **Shared catalog funding:** authorize up to **$2 total** for the first two five-minute curated episodes,
   admitted at up to $0.75 each, inside the current $25 provider allocation. Remaining allowance supports
   explicit QA only; no automatic replenishment. Recommendation: platform-funded seeds and free reuse;
   defer public customer sponsorship and marketplace/revenue sharing.
3. **Private generation contract:** accept server-readable private source-derived audio/transcripts with
   the same access/deletion boundary as private PDFs, E2EE listening history, no private-chat input, actual
   usage billed within an explicit maximum, and no paid auto-retry. Recommendation: this bounded v1 contract;
   background podcasts derived from personal chats need a separate encrypted-job design.

The architecture and financial primitives must receive independent review before a migration or real
generation. A paid quality comparison is a separate concrete bounded run within the accepted allocation.

# Gradstep price and credit UX audit

2026-10-09. This is a product and cost-transparency review of the current beta. It does not change
StoreKit prices, credit grants or provider routing. Provider ceilings and customer charges are separate:
the server reserves a bounded maximum before paid work, then settles measured usage once.

## The direct answer on providers

The deployed product does not use DeepSeek. Current routes are:

| Feature | Provider and model | Customer accounting |
|---|---|---|
| Paper chat | Anthropic Claude Sonnet 5.5 by default; Haiku and Opus are explicit choices | Actual measured provider usage, within the quoted hold |
| Podcast script and review | Anthropic Claude Sonnet 5.5 | Actual measured script/review usage |
| Podcast speech | Google Vertex AI Gemini 3.8 Flash TTS | Actual measured speech usage |
| Equation-aware preparation | Mathpix | One credit per admitted OCR page, with shared eligible conversions avoiding repeat OCR |
| Search | Tavily under the bounded prepaid route, with Anthropic search still gated | Search units plus the answer's model usage |
| Automatic topic tags | Claude Haiku, platform-funded | No customer credits |

DeepSeek is present only in the legacy reference app and in a research comparison. It is not a fallback and
receives no current Gradstep traffic.

## What a credit means

A credit is a provider-equivalent accounting unit, currently **$0.005 of reserved provider cost**. It is not a
retail dollar and does not have one fixed consumer price because the plans bundle different quantities:

| Offer | Retail price | Credits | Retail value of one credit if fully used |
|---|---:|---:|---:|
| Standard monthly | $9.99 | 800 | 1.25¢ |
| Pro monthly | $19.99 | 1,800 | 1.11¢ |
| Credit pack | $4.99 | 400 | 1.25¢ |

This is financially sound as a beta accounting model, but the difference between “provider equivalent” and
“retail value” should be explained in the product. A user should never be led to believe that one credit is
one cent or that a maximum hold is the expected charge.

## Current user journeys

| Action | Measured or published guidance | Hard customer maximum | UX assessment |
|---|---:|---:|---|
| Mathpix preparation | 1 credit per page; shared eligible work can be free | Up to 80 pages in the current pipeline policy | Predictable and easy to explain; show the page count before confirmation |
| Sonnet chat on a typical 25-page paper | Usually about 8–27 credits depending on length/effort; default is in this range | Usually up to 37 credits before search/title additions | Good structure; the profile picker already exposes a range and maximum |
| Web search | About 1–2 credits per search, added to the answer | Up to 3 searches for ordinary answers, 5 for Related | Explain that Related can use more searches before the user confirms |
| Five-minute private podcast | Two real staging successes settled at 55 and 60 credits | 150 credits held before work | The implementation is fair; the copy is too alarming because it shows only the maximum |
| Short private podcast | No production sample yet | 140 credits | Short and five-minute maximums are close because the speech provider requires a full serving grant; explain this rather than implying a proportional discount |
| Ten-minute private podcast | No production sample yet | 300 credits | Offer only with a clear maximum and a “no charge if quality checks fail” explanation |
| Twenty-minute private podcast | No production sample yet | 530 credits | A premium, optional action; do not describe it as ordinary plan usage |
| Shared catalog podcast playback | No generation credits | Authenticated transfer limits only | Excellent value; make this the first choice when an episode already exists |

The podcast settlement path charges only known measured usage for a successful or deliberately canceled job.
Quality failures, source-too-large refusals and platform interruptions charge zero customer credits. Unknown
provider outcomes retain an internal liability and do not silently retry or exceed the disclosed maximum.

## Findings

1. **The system is more generous than the podcast quote suggests.** The five-minute maximum is a safety
   reserve, not the expected charge. The current quote says “actual usage” but gives no observed range.
2. **Chat already has the right shape.** It offers model, effort and answer length, shows a range and maximum,
   and settles actual usage. Haiku is an available lower-cost option, but Sonnet remains the sensible default
   until scientific quality measurements justify changing it.
3. **OCR is the clearest price.** Page-based pricing is understandable, and shared rights-cleared conversions
   prevent users from paying repeatedly for the same eligible paper.
4. **Short podcast pricing looks unintuitive.** The near-equal Short/5-minute maximum comes from the speech
   provider's serving limit, not from charging users for unused audio. The interface should say this plainly.
5. **DeepSeek is a cost opportunity, not a current hidden expense.** Its apparent token savings do not prove
   equivalent equation, citation, long-paper or privacy quality. A cheaper profile should be opt-in and tested
   against the same grounded-paper benchmark before production routing.
6. **The plan allowance supports a lot of ordinary work.** A Standard month can cover roughly ten 10-page OCR
   papers plus dozens of short or standard chat answers, or a mixture of reading, chat and a private episode.
   A Pro month gives substantially more room. These are examples, not promises, because paper size and profile
   choices vary.

## Recommended product changes

### Immediate, low-risk

- Change the podcast quote to show a recent observed range where evidence exists: “Recent five-minute examples
  used about 55–60 credits; actual usage varies; maximum 150 credits.” Keep the hard maximum prominent before
  confirmation.
- For Short, add one sentence that the maximum is close to five minutes because the speech provider requires a
  full serving reservation; actual usage is settled after the take.
- Keep shared catalog episodes visibly free to generate and play. A user should see the shared option before
  the private-generation action.
- In the credits area, show three compact examples: “OCR: about 1 credit/page · Chat: usually a few to a few
  dozen credits · Shared episodes: no generation credits.” Avoid a large pricing essay.

### Before public launch

- Replace the two-episode podcast sample with at least 10–20 successful runs across short, five, ten and twenty
  minutes. Publish observed median and p90 ranges separately from the hard ceiling.
- Measure a representative month of chat profiles, OCR page counts, searches, retries and quality failures. Use
  the p90 basket to test whether Standard feels generous and whether Pro is clearly comfortable for a regular
  researcher.
- Benchmark a candidate cheap script profile (Haiku first, DeepSeek only as an isolated comparison) on equation
  narration, evidence quotes, numbers, limitations, long papers, latency and provider retention. Keep Sonnet as
  reviewer or fallback until the benchmark passes; never silently switch existing profiles.
- Reconcile provider invoices against the operation ledger and publish aggregate ranges in the admin dashboard.
  Customer credits, provider cost, platform-funded quality losses and unresolved liabilities must stay separate.

## Should private podcasts be sold at cost?

This is a sensible engagement strategy, but “at cost” needs a precise definition. The current five-minute
settlement already charges only measured provider-equivalent usage: the two staging successes used 55 and 60
credits, or about $0.275 and $0.300 at the internal $0.005-per-credit rate. The customer does not pay a second
podcast surcharge. However, the credits came from bundles whose retail value is about 1.11–1.25 cents each, so
the plan as a whole still has room for Apple fees, infrastructure, support, failed work and the rest of the
product. The apparent gap is the plan's contribution margin, not a hidden episode markup.

For that reason, the safest launch policy is:

1. Keep the shared Listen catalog free to generate and play for users. It is the strongest retention loop and
   lets one reviewed episode serve many readers.
2. Keep private generation on the existing measured-credit path, with no additional podcast multiplier. Make
   the observed range and the maximum visible before confirmation, and show the final charge and released hold
   afterward.
3. Treat any “at-cost episode” offer as an explicit experiment after the price ledger has at least 10–20 measured
   successes. It should use a separate, versioned podcast allowance or offer, so a change cannot silently alter
   the value of existing subscriptions or packs.

A direct per-episode App Store price would not be literally provider cost: Apple commission, included VAT, storage,
   delivery, quality review and uncertain provider outcomes still exist, and a dynamic post-generation charge is
   a poor fit for fixed StoreKit products. If the experiment is approved, a better first version is one included
   private five-minute generation per month on each paid plan (subject to the same hold and quality rules), with
   further private episodes consuming ordinary credits. That gives users a clear engagement benefit without
   promising unlimited audio or pretending that platform overhead is zero.

The product should measure episode retention, repeat listening, shared-catalog discovery and the provider cost per
completed episode separately from customer credits. If private episodes drive return visits but remain a small
share of usage, the subsidy is doing its job; if they become the dominant workload, the allowance or profile needs
to be revisited using measured p90 cost rather than the worst-case hold alone.

## Launch recommendation

Do not lower the current subscription allowances or raise podcast prices based on the maximum holds alone. The
current safer product decision is to make the actual-versus-maximum distinction visible, make shared episodes the
free default, and collect a larger measured sample. If the measured p90 monthly basket does not fit comfortably
inside Standard, improve cache reuse and add a quality-tested cheaper profile before changing the plans.

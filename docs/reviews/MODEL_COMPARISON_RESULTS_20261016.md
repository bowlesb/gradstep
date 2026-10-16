# Paper-chat model comparison: measured screening

**Later update, ~23:15 UTC:** the [finalist extension](MODEL_COMPARISON_FINALISTS_20261016.md) has all 45 additional
responses and partial independent review. The five interrupted first-screen calls reconciled to $0.03395231,
making the corrected first-screen total **$8.6897285082**, with no holds. Reconciled screening contestant totals
for MiMo Flash and GLM Flash are **$0.0846504456** and **$0.10084738**. The costs and outstanding-hold readings
below are retained as the original 21:25 checkpoint; the new report supersedes their billing status.

2026-10-16. This is a first screening, not a completed default-model decision. **Gemini 3.8 Flash medium is the
leading candidate for the next validation round.** Haiku remains competitive, but an independently confirmed
algebra error in its high-effort answer prevents treating its high average score as a clean quality pass.
Sonnet remains the deployed default. No new customer provider, consent flow or model routing was deployed.

## What ran

The same 12 questions from five papers went to 13 usable settings across 11 underlying models. There were
156 contestant attempts: 151 completed responses, five timeouts, and nine completed responses that only asked
for an unavailable table. That leaves 142 substantive explanations. DeepSeek's own endpoint separately refused
all 12 requests under the account's existing data-use policy, before inference; it has no quality score.
The usable DeepSeek results are specifically the **DeepInfra FP8** route, with `data_collection: deny` and no
fallback. This routing filter is not a verified retention guarantee.

Each request used the production paper-chat prompt and tools, the exact paragraph-numbered paper, prepared
figure images where requested, and the app's 130-second request deadline. All 151 completed responses passed
the offline formula/diagram renderer checks. That checks syntax and rendering, not mathematical truth.
The source hashes, questions, reference answers and method are in the
[protocol](MODEL_COMPARISON_20261016.md) and `tests/model-bakeoff/`.

Argon high graded all 151 responses blind against the full source, images and reference criteria. Sol high
independently checked three difficult questions for seven settings; those checks are reported separately rather
than unevenly changing the primary averages. Direct source checks confirmed several consequential errors.
The remaining 15 prepared questions have **not** been run: this is 12-question coverage, not a 27-question claim.

## Results

The table's score is the primary grader's overall assessment, with timeouts and empty answers counted as zero.
It measures delivery with the current app prompt as well as explanation quality. The unavailable-table cases
are an interaction between model tool choice and the current client's image finder, not proof of low reasoning
ability. The primary grader also favored extensive coverage; its scores are subjective and sometimes disputed
by the second grader. Differences of a few tenths on 12 questions do not establish model superiority.

| Model / setting | App score / 10 | Nonempty / 12 | First text, median seconds | Cost for 12 requests |
|---|---:|---:|---:|---:|
| Sonnet 5.5 · medium | 9.50 | 12/12 | 1.9 | $1.7541 |
| Gemini 4 Argon · medium | 9.33 | 12/12 | 4.7 | $1.4048 |
| Haiku 5.5 · high | 9.25 | 12/12 | 9.9 | $0.2595 estimate† |
| Gemini 3.8 Flash · medium | 9.17 | 12/12 | 10.0 | $0.1551 |
| MiMo V2.6 Pro | 8.92 | 12/12 | 13.3 | $0.1580 |
| Haiku 5.5 · medium | 8.75 | 12/12 | 9.1 | $0.2543 |
| Qwen3.8 Flash | 8.50 | 11/12 | 31.0 | $0.0795 |
| GPT-6.1 Sol · medium | 8.17 | 12/12 | 3.9 | $0.9795 |
| DeepSeek V4.1 Flash · DeepInfra FP8 | 8.08 | 11/12 | 17.6 | $0.0552 |
| GPT-6.1 Sol · low | 7.67 | 11/12 | 2.1 | $0.9693 |
| GPT-6 Luna · high | 7.00 | 11/12 | 8.0 | $0.0518 |
| MiMo V2.6 Flash | 5.83 | 8/12 | 19.2 | $0.0751 + holds |
| GLM-5.3 Flash | 4.50 | 6/12 | 90.6 | $0.0764 + holds |
| DeepSeek · own endpoint | Not tested | 0/12 | — | $0.0000 |

Costs are **completion-reported OpenRouter charges**, not reconciled invoices or direct-provider forecasts.
They include the actual mix of cold and warm requests. Failed calls with missing usage have additional held
amounts, detailed below. First-text medians exclude requests that produced no text; a single run is not a latency
distribution or service-level guarantee.

**Haiku high's $0.0465 observed total benefited from cache written by Haiku medium.** Its price is not lower
because the effort is higher. All 12 paired requests had identical prompt-token counts and one round. Keeping
medium's measured input charges and substituting high's output-token charges gives an estimated **$0.2595** for
high under medium's cache pattern, versus medium's measured **$0.2543**. This is a normalization estimate, not
another measured bill. It puts the Sonnet comparison near 6.8×, rather than the misleading 37.7× raw ratio.

In this controlled sample, hourly cache writes account for **$1.5682 of Sonnet's $1.7541 (89.4%)** and
**$0.2242 of Haiku medium's $0.2543 (88.2%)**. These figures apply to this experiment; they do not retroactively
price the staging ledger's mixed historical cache tokens.

The long Apertus question illustrates why list price alone is misleading. Haiku counted 182,458 prompt tokens,
crossing its 100K price tier; the cold request cost **$0.1869**. DeepSeek/DeepInfra counted 123,775 and cost
**$0.0184**, with a correct answer on that question. The same experiment later found a serious plot-reading error
in DeepSeek, so this cheap success does not make it the best general default.

## Findings that matter more than the averages

- **Haiku high, Mamba equation:** its displayed equation is correct, but its explanation drops a factor of Δ
  while simplifying the input coefficient, and then describes an integral containing B while omitting B.
  Argon scored the answer 9; Sol caught the error and scored it 6. A scalar counterexample independently confirms
  it. Haiku is capable, but this result does not support an automatic default switch.
- **DeepSeek and Qwen, Mamba plot:** both confused the green Mamba 6.9B bar with the orange Transformer 1.3B bar.
  The image shows 1,814 versus 364 tokens/s, approximately 5×; their wrong series selection changes the conclusion.
  Sonnet, Haiku high and Gemini Flash got that central comparison right. DeepSeek took 63.6 seconds to start this
  answer; Qwen's overall median was 31 seconds.
- **MiMo Pro, Muon theorem:** it invents a stronger squared-gradient bound at paragraph 300. The source gives an
  unsquared norm with a different rate. Both graders and the direct source check identified the problem.
- **Both MiMo variants, Apertus energy:** they say the resource estimate includes other projects; paragraph 370
  explicitly excludes them. Flash also incorrectly includes idle time. They correctly decline to invent an exact
  dollar bill, but misdescribe supporting evidence.
- **Luna, Mamba equation:** its central formula and explanation are correct. Argon scored it 6 for missing
  background; Sol scored it 8 with no factual errors. Luna deserves further testing as an economical, concise
  option, rather than rejection based solely on the primary overall average. It also returned one unanswered
  table request in this sample.
- **Sonnet is not error-free:** both graders identified a misleading sign-convention discussion in its DPO
  derivation. It nevertheless had the best primary overall score and the fastest median first text here.
- **Gemini Flash also needs validation:** the second grader flagged its loose description of a stationarity
  bound as convergence of iterates to a point, and its implication that an approximate QR basis conflicts with
  the theorem. A time-averaged gradient bound is weaker than convergence to a point; the source permits arbitrary
  predictable orthonormal bases. The leading candidate is not a flawless model.

The strongest next comparison is **Gemini Flash versus Haiku**, with Sonnet retained as a control and Luna
included for economical concise answers. Gemini Flash's current measured cost and its performance on the plot
and algebra checks make it particularly interesting. Pricing promotions, cache behavior and direct-adapter
behavior need verification before a production forecast. Maintenance effort does not disqualify any contender.

## Chinese providers beyond this screening

Xiaomi MiMo Pro/Flash, Z.AI GLM Flash, Alibaba Qwen Flash and DeepSeek Flash were tested. More expensive Chinese
models are still unmeasured, not established losers. Qwen3.8 Max supports images and long context; the tested
catalogue's Alibaba route for `qwen/qwen3.8-max-0902` quotes $2/M input and $6/M output, with separate cache-write
pricing. [Alibaba's model documentation](https://www.alibabacloud.com/help/en/model-studio/qwen3-8-max)
distinguishes regions and cache rates. Kimi K3 is another vision/long-context candidate;
[Moonshot's announcement](https://forum.moonshot.ai/t/kimi-k3-is-here-our-most-capable-model/480) and
[current cache-pricing explanation](https://platform.kimi.ai/docs/pricing/chat) describe its capabilities and
separate cache writes. No paper-specific quality conclusion is made about either.

The current catalogue lists GLM-5.3 and DeepSeek V4 Pro 0813 as text-only. They could be evaluated as text
specialists alongside a vision model; they were not included as a uniform text-and-figure default. Z.AI's
[current price page](https://docs.z.ai/guides/overview/pricing) lists GLM-5.3 at $1.40/M input and $4.40/M output.
The dated catalogue snapshots are preserved with the evidence; advertised coding results are not substituted
for this application's scientific reading tasks.

## Spend, evidence and remaining work

Completed at approximately 21:25 UTC: **$8.655776 completion-reported**, comprising $6.059726 contestant requests, $2.113472 primary grading and $0.482578 second-grader checks. With unresolved holds, total conservative exposure is **$8.883966**. Further planned spend for this round is $0. The provider account/key summary still reports **$3.451502566** usage from **$10** funded credit at 21:25 UTC; it is not reconciled with the request records.

The five interrupted requests retain their full **$0.228190** reservations: two MiMo Flash and three GLM Flash.
Generation-metadata lookups returned 404 even for a known completed request, so there is no basis for treating
them as free. OpenRouter's aggregate account usage is lower than the sum of completion-reported charges;
both readings are preserved, and the larger ledger amount controls admission. No additional top-up or recurring
service was purchased. The owner's $25 research authorization and $100/month operating budget are unchanged.
Working admission used the existing $10 funding; one image-grading request needed a $9.63 total temporary
exposure because the conservative estimate counts encoded image bytes as tokens. No reservation overrun occurred.

Raw answers, component grades, separate second-grader judgments, manual source checks, price snapshots and
unresolved holds are retained in [evidence.json](model-comparison-20261016/evidence.json), with a SHA-256 file.
The exact public-paper bundles remain local and hash-pinned. The answer comparison lets the owner inspect the
responses rather than relying on the scores.

Before a default change: finish the 27-question finalist set with a calibrated rubric, repeat consequential
plot/algebra cases, verify the actual deployed adapter and figure-explainer workflow, and measure cold and warm
costs under the intended production route. This screening does not prove equivalent quality, production
integration, privacy terms, or a safe monthly price for any unintegrated provider.

Verification: `npm test` passes, six targeted reservation/reference/grading tests pass, and the answer viewer
passed 504 model/question/layout checks at 736px, 360px and 320px widths, with light/dark visual review.
The evidence checksum and viewer rebuild from the archive also pass. No physical phone, NAS or TextBrain work
was performed.

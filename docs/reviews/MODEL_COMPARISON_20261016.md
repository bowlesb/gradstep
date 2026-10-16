# Paper-chat model comparison, 2026-10-16

**Current status, ~21:25 UTC: the matched 12-question screening and independent spot checks are complete.**
Read the [measured results](MODEL_COMPARISON_RESULTS_20261016.md) before using the prices or selecting a default.
Reported cost is $8.655776, plus $0.228190 unresolved holds. No further paid request is running. Gemini Flash is
the provisional next-validation lead; Sonnet remains the default. The 27-question extension and deployed-adapter
validation are still pending. The working admission ceiling reached the already-funded **$10** for one image
grading reservation; no new purchase or increase to the owner's $25 authorization occurred.

Historical resumption checkpoint, 2026-10-16 20:16 UTC: OpenRouter now has **$10 purchased credit**. The six-answer smoke completed
for **$0.03148947**, with no unresolved charges. The comparison is running; **no quality ranking yet**.
The owner approved up to $25 including grading; this funded phase uses a tighter **$9.50 total admission cap**
(initially $9, with $0.50 of the funded cushion reassigned to conservative temporary holds; contestant screening initially capped at $7) and the existing $20 provider-enforced key limit.
Sonnet remains the app default. Browser and TestFlight 63 are shipped independently of this experiment.

### Funded screening and extension

Before the full matrix, every setting receives the same 12 questions in `_screening.json`, covering all five papers:
long-context synthesis and an unanswerable question, a derivation, exact training settings, two plot readings,
an equation, a visual request, appendix details, a theorem limitation, a layout and a false premise.
The six smoke answers are reused, including the weak ones; there are no selective quality retries.
Blind grading uses Argon high with a 16,000-token output allowance, followed by a second judge on close finalists and manual source checks. This keeps grading within the $10 funded balance; the original Opus plan can be used in a separately funded extension. Then the remaining 15 questions go to promising settings and a Sonnet control if the funded
budget permits. Report screening and finalist coverage separately; never compare a 12-question mean to a
27-question mean. A reliable low-cost answer is the objective, not raw score divided by price regardless of errors.
Use correctness/faithfulness, material mistakes, answer availability, latency and cost together. Review the close
finalists with a second judge and manual source checks. Small samples do not establish general model superiority.

The smoke exposed a product limitation: `look_at_figure` can name a native HTML table the current chat image finder
does not supply. Such a call with no answer is retained as an empty answer, not retried until it succeeds or silently
excluded. Generation ids are now kept with the durable holds so later interrupted calls can be reconciled through
[OpenRouter's generation metadata](https://openrouter.ai/docs/api/api-reference/generations/get-generation).
Cold/warm charges must be separated: medium/high settings of the same underlying model can share a cached prefix,
so their observed average bills are not independent cold-start comparisons.

DeepSeek's own endpoint was refused by OpenRouter's account-wide paid-training restriction (HTTP 404, zero charge).
No account setting was changed. A separately named **DeepSeek / DeepInfra FP8** setting is added as an alternate
host, with explicit `data_collection: deny`, exact route pinning and no fallback; if the account still refuses it,
it remains untested. This is a host/precision variant, not evidence for DeepSeek's own endpoint. The routing filter
uses [OpenRouter's policy metadata](https://openrouter.ai/docs/guides/routing/provider-selection#requiring-providers-to-comply-with-data-policies),
not an independently verified zero-retention guarantee. DeepInfra's catalogue prices at this checkpoint are
$0.14/M input and $0.42/M output. The interrupted calls' metadata lookups currently return 404 (including a known
completed call); their full reservations remain. Completion-reported costs also exceed the account usage summary;
preserve both readings and use the larger amount for admission until reconciled.

The final implementation admits the most expensive price tier that the conservative serialized-byte token
bound can reach. It excludes a long-context surcharge only when its numeric `min_prompt_tokens` is strictly
above that upper bound; unknown and time-based overrides remain included. Boundary tests cover this rule.
It still reserves all encoded image bytes and the full output allowance, with a 25% margin. Secondary spot checks
are retained separately; they do not unevenly reweight the primary judge's common-question averages.

## Question set and protocol

`tests/model-bakeoff/` has 27 questions: DPO v3 (6), Mamba v2 (5),
2610.19844v1 / residual-corrected subspace optimization (6), 2610.14704v1 / PRISM (5),
2610.15542v1 / Apertus (5). Four reference drafts were recovered from local Claude artifacts; the missing
optimizer set was completed against its numbered paper. Each has reference answers, source paragraph numbers,
key points, specific errors and grading notes. `_sources.json` pins the exact reader index, manifest and numbered-context hashes; changed sources refuse until references are reviewed. References are evaluation rubrics, not objective gold truth:
the judge must prefer the source when they disagree. Review disagreements manually before selecting a default.
Public older papers may be in training data. Recent papers reduce that risk but do not prove exclusion.

The 13 settings cover 11 models: Sonnet medium; Haiku medium/high; Luna high; Sol low/medium;
Gemini Flash medium; Argon medium; MiMo Pro/Flash; GLM Flash; Qwen Flash; DeepSeek Flash.
Whole-paper text comes from the browser context builder, and `runChat` builds the production instructions and
tools with local stubs. The request is then translated to OpenRouter. This tests that prompt through an adapter,
not the complete deployed chat runtime, latency distribution, retention policy or billing path.
Output uses the production builder's 10,000-token allowance and a 130-second request deadline. Different
reasoning settings can consume different fractions of the allowance; truncation is recorded as incomplete.
Figure requests repeat once with the requested image, and both calls count toward cost.

Figure images now run through the **actual browser `figureImage` implementation** in local Chromium: all allowed
panels, white background, JPEG quality and resolution limits. A paper's Figure 11 is still attachment **F1**;
the original harness incorrectly sent F14 and the server rejected it. The grader receives the prepared image.
Diagram Mermaid and fallback walkthrough words are included in the graded answer; invalid visual tool outputs
are identified as not shown to the reader. Layout quality still requires visual/manual review.

Reference placeholders beginning `_` are excluded from scored runs. Every selected question, source paragraph
and figure is validated before inference. Cached answers bind to their inputs; grading binds to answers and
references; incomplete or stale grades are excluded. Scores require every requested label exactly once,
finite values in 0–10, and valid key-point indices. The report shows answered/expected coverage and separates
completion-reported spend from outstanding uncertain charges. Unequal or partial coverage is not a model ranking.

## Prices checked at takeover

USD per million tokens, from OpenRouter's live endpoint catalogue, first-party route, base input / cached input /
output. These are **token prices**, not prices per million words or a quality-per-dollar result. The dated raw
responses, including tiers, quantization and supported parameters, are in `.artifacts/bakeoff/catalogue/`.
Each model links to the API response used for verification.

| Model | Input | Cache read | Output | Qualifications |
|---|---:|---:|---:|---|
| [Sonnet 5.5](https://openrouter.ai/api/v1/models/anthropic/claude-sonnet-5.5/endpoints) | 2.00 | 0.10 | 10.00 | 1-hour cache write 4.00 |
| [Haiku 5.5](https://openrouter.ai/api/v1/models/anthropic/claude-haiku-5.5/endpoints) | 0.10 | 0.01 | 0.50 | At 100K prompt tier: 0.50 / 0.05 / 2.50; hourly write 0.20 → 1.00 |
| [GPT-6 Luna](https://openrouter.ai/api/v1/models/openai/gpt-6-luna/endpoints) | 0.10 | 0.01 | 0.50 | At 272K tier: 0.20 / 0.02 / 0.75 |
| [GPT-6.1 Sol](https://openrouter.ai/api/v1/models/openai/gpt-6.1-sol/endpoints) | 2.00 | 0.10 | 10.00 | At 272K tier: 4.00 / 0.20 / 15.00 |
| [Gemini 3.8 Flash](https://openrouter.ai/api/v1/models/google/gemini-3.8-flash/endpoints) | 0.75 | 0.075 | 3.75 | Catalogue marks 50% discount; do not forecast permanently |
| [Gemini 4 Argon](https://openrouter.ai/api/v1/models/google/gemini-4-argon/endpoints) | 2.00 | 0.10 | 10.00 | Catalogue marks 50% discount |
| [MiMo V2.6 Pro](https://openrouter.ai/api/v1/models/xiaomi/mimo-v2.6-pro/endpoints) | 0.435 | 0.0036 | 0.87 | Xiaomi's own endpoint declares FP8 |
| [MiMo V2.6 Flash](https://openrouter.ai/api/v1/models/xiaomi/mimo-v2.6-flash/endpoints) | 0.14 | 0.0028 | 0.28 | Xiaomi's own endpoint declares FP8 |
| [GLM 5.3 Flash](https://openrouter.ai/api/v1/models/z-ai/glm-5.3-flash/endpoints) | 0.15 | 0.03 | 0.50 | Z.AI's own endpoint declares FP8 |
| [Qwen 3.8 Flash](https://openrouter.ai/api/v1/models/qwen/qwen3.8-flash/endpoints) | 0.15 | 0.016 | 0.47 | Alibaba route; catalogue also offers a regional route |
| [DeepSeek V4.1 Flash](https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints) | 0.15 | 0.003 | 0.60 | Peak overrides double these rates |

First-party routing makes the tested host explicit; **it does not guarantee unquantized weights**. The original
Claude handoff's opposite implication was incorrect. Nor is a universal 1.5× tokenizer penalty established for
these five papers. Record each model's actual prompt/cache/output/reasoning tokens. Cache writes, long-context
tiers, time-of-day pricing, tool reliability, refusals and latency can change the useful-answer cost materially.
The broader research notes remain in the recovered Claude session; unsupported benchmark claims are not promoted
to a product decision. This shortlist does not prove that excluded models are worse.

## Spend admission and resuming

Before paid work, catalogue checks verify the exact route, image/tool/reasoning support and prices. A bounded,
non-resetting provider key limit (at most the owner-approved $25) is mandatory; the current key limit is $20.
One process holds a paid-run lock. Each request writes a durable reservation **before** sending, counting all
other reservations. Its conservative bound counts serialized UTF-8 bytes plus framing as input tokens, every
allowed output token, the highest declared length/cache-write tier and 25% margin. These are deliberately large
holds, not a forecast or an unconditional guarantee about provider billing. `max_price` also bounds routing prices.
Usage settles the hold only when cost is reported; interruption/missing usage retains it. An overrun stops further
admission. There are no automatic transport retries. Explicit retries retain earlier attempt costs in the ledger.
Provider usage must be reconciled before clearing stale locks or unresolved holds.

Offline preparation and catalogue-only checks:

```sh
node scripts/model-bakeoff.mjs dry
node scripts/model-bakeoff.mjs preflight
node --test tests/backend/model-bakeoff.test.ts
```

After credit exists, start with three questions on Haiku and one different provider, inspect their images,
tool output, usage and stopping behavior, then broaden. Both answer generation and judging share the same spend cap. Grading allows 400 seconds and 32,000 output tokens per question (its output is a batch of scores, not a reader answer); contestants retain the 130-second deadline:

```sh
node scripts/model-bakeoff.mjs run --models=haiku-medium,mimo-flash --questions=dpo-detail,dpo-figure,prism-false_premise --concurrency=2
node scripts/model-bakeoff.mjs run --concurrency=2
node scripts/model-bakeoff.mjs judge --judge=opus --concurrency=1
node scripts/model-bakeoff.mjs report
```

Use a second judge on disagreements and close finalists if budget remains. Do not exceed funded credit or the owner-approved $25; keep temporary holds in the admission total.
Before selecting a default, inspect critical wrong answers, compare identical question coverage and cold/warm
costs, and run the finalist through the actual staging adapter/figure workflow. No direct-provider integration,
customer consent change or default switch is included in this unpaid checkpoint.

The five prepared figure images were also visually checked against the recovered numeric and layout references.

Verification: all 27 requests construct successfully without inference; all 13 contestant settings have matching
catalogue routes; five new fast tests cover reservation concurrency/restart/unknown cost/overrun, price tiers,
reference validation and malformed grades. An attempted paid command stops in preflight on zero credit.
No paid quality claim follows from those checks. The funded screening above supersedes the initial zero-credit
checkpoint; final measured results will be recorded separately after grading.

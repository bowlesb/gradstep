# Paper-chat finalists: complete responses, partial independent review

2026-10-16, ~23:15 UTC. **Haiku medium, Gemini Flash medium and Luna high now each have 27 attempted questions.**
This continuation adds the same 15 questions to each candidate, reusing the original 12 without selective retries.
The 45 new requests all completed, but two Luna responses only requested unavailable table images. Independent
grading covers four of the 15 new questions; it is not complete. **Sonnet remains the deployed default.**
Gemini Flash remains a promising candidate, not an established winner or an error-free replacement.

Read the [first-screen results](MODEL_COMPARISON_RESULTS_20261016.md) for the matched comparison with Sonnet,
MiMo, GLM, Qwen and DeepSeek. Those settings still have 12-question coverage. Do not compare a 12-question
quality mean with a 27-question mean or blend the two grading protocols.

## What the extension adds

| Setting | New written answers / 15 | New request cost | Written answers / all 27 | Request cost / all 27 | Median first text / all 27 |
|---|---:|---:|---:|---:|---:|
| Haiku 5.5 medium | 15 | $0.2737 | 27 | $0.5280 | 8.7 s |
| Gemini 3.8 Flash medium | 15 | $0.2014 | 27 | $0.3565 | 9.5 s |
| GPT-6 Luna high | 13 | $0.0608 | 24 | $0.1126 | 7.9 s |

Costs are actual recorded OpenRouter charges for this sequence of cold and warm requests. They are not
independent cold-start measurements or a production subscription forecast. First-text medians exclude responses
with no text. All three use their maker's pinned route; this is the production prompt translated through
OpenRouter, not a deployed-adapter test.

Luna's two new unanswered cases are `dpo-false_premise` and `muon-false-premise`; its earlier unanswered case is
`apertus-synthesis`. It requests a table image even though the table's text is in the paper context. The current
app's image finder handles indexed figures, not native HTML tables. This is a model/tool/application interaction,
not proof that Luna cannot reason about tables. Haiku and Gemini answer those two false-premise questions
correctly. No prompt or application behavior was changed during the comparison.

## Quality findings and uncertainty

Argon high independently reviewed three answers each for `mamba-explain`, `mamba-detail`, `muon-explain` and
`prism-explain`: **12 new answers**, with no central material error flagged in that subset. Its revised rubric
separates factual errors, missing required content and optional background. Those grades remain separate from
the first-screen grades. Both Argon and Sol also agreed with six short, agent-verified calibration cases covering
missing factors, squared versus unsquared norms and experimental-setting confusion. This is not human expert
calibration, and six checks do not establish general judge reliability or erase earlier misses.

Direct source checks by Codex, separately identified in the evidence, found:

- All three correctly handle the checked Muon virtual-iterate derivation, Apertus training settings, Mamba
  activation-memory numbers and central readings of the two new plots. All three refuse to invent the missing
  DPO timing comparison and PMRC dollar cost.
- Gemini's PRISM explanation introduces two unsupported details: it calls patch-blurring sensitivity maps
  gradient/attention heatmaps, and assumes uniform flow-time sampling where the cited paragraph specifies only
  a general density. The correct sensitivity method is at paragraph **195**, not its heading at 194. Its later
  critique also overstates the maps' exclusion of background sensitivity.
- Haiku's PRISM critique correctly notices that completion times are measured only on successful trials, but
  then claims the faster times partly reflect easier trials. The paper does not establish that causal direction.
- Luna's Muon explanation correctly states both update rules and the motivation. Argon gives it 7 for omitting
  proof techniques and residual-weight scaling. Those details are reasonably optional for the question asked;
  this is a disputed completeness judgment, not a demonstrated factual failure. The original grade is preserved.
- The PRISM reference also needs a qualification: the main three-task study uses one backbone, but paragraph
  103 includes a second-backbone drive-insertion ablation. The review annotation records this without changing
  the paid questions or their hashes after the fact.

These checks cover requested central claims and identified disagreements, **not every assertion in all 45
answers**. Longer explanations offer useful detail but also more opportunities for unsupported claims. Remaining
independent review, repeated critical cases and the actual figure-explainer workflow are still needed before a
default change. Higher-end Chinese candidates such as Kimi K3 and Qwen Max remain untested, not ruled out.

## Cost and caching

The new answers cost **$0.535841875**; new independent grading **$0.440760**; calibration **$0.020200**.
The extension therefore consumed **$0.996801875**. Entire experiment to this checkpoint:

| Category | Recorded USD |
|---|---:|
| Contestant requests, including reconciled interrupted requests | 6.6295203832 |
| Independent grading | 3.0368100000 |
| Calibration | 0.0202000000 |
| **Total** | **9.6865303832** |
| Outstanding uncertain charges | **0** |

The five interrupted first-screen generations now return authoritative charge metadata: **$0.03395231** in
actual charges replaces their **$0.228190** holds. The corrected first-screen total is **$8.6897285082**, matching
the account/key total of $8.689728496 at 22:50 UTC to rounding. The original evidence snapshot is immutable;
the new archive includes the reconciliation receipt and preserves the failed outcomes.

The latest aggregate account/key reading, at 23:19 UTC, was still catching up: **$9.413856053** usage from
**$10** funded. Admission uses the larger request ledger, leaving **$0.3134696168**. There are no outstanding
holds or reservation overruns. Remaining grading requests require conservative reservations of at least $0.35,
and $1.18–1.41 for the long Apertus source, so they were refused locally before inference. No new top-up, fixed
commitment or operating-budget increase occurred. The existing $25 authorization includes grading, but only
$10 has been funded; the request to fund the remaining $15 is pending. Further planned paid spend at this
checkpoint is **$0** until funding is confirmed. The provider key limit remains $20, and the harness maximum
remains the tighter $18 within the $25 authorization.

Caching still dominates some costs. Haiku's first new Apertus question writes 182,217 tokens and costs $0.183755;
the following text and figure answers cost $0.014751 and $0.014081 with cache hits. Gemini's corresponding
charges are $0.016585, $0.026090 and $0.027075; its usage records combine cache writes and reads on some calls,
so a zero cached-token count is not a universal cold/warm classifier across providers. Luna's are $0.015310,
$0.002090 and $0.015695. These are different answer lengths and cache conditions, not a normalized model-price
ratio. The four new Argon grading requests report **zero cached tokens** and $0.322660 of prompt charges despite
explicit breakpoints. Investigate that route before forecasting grading savings; do not assume a cache hit from
the presence of a cache-control field. [OpenRouter's caching documentation](https://openrouter.ai/docs/guides/best-practices/prompt-caching)
describes provider-specific behavior and TTLs, not a guarantee for these requests.

## Evidence and next work

The [new evidence archive](model-comparison-finalists-20261016/evidence.json) contains all 213 attempt records,
19 grading records, two calibration records, source checks, price snapshots and the reconciliation receipt.
Its SHA-256 file accompanies it; the original [first-screen archive](model-comparison-20261016/evidence.json)
is unchanged. The side-by-side answer comparison includes all 27 questions, distinguishes unrun settings and
ungraded responses, and exposes agent source checks separately from paid grader notes.

With funding confirmed, complete the 11 remaining independent question reviews, use a second judge on disputed
or consequential claims, repeat the plot/algebra cases, and extend the higher-end Chinese comparison before
settling the quality/cost choice. Keep a matched question set and preserve every failure. A later production
decision also needs adapter/tool validation and cold/warm pricing under the intended route.

Verification: routine `npm test`, seven targeted reservation/reference/grading checks, all 196 completed
responses through the actual app math parser and Mermaid engine (zero invalid math or diagrams), archive
checksum/fallback rebuild, and 1,134 answer-comparison checks at 736/360/320px with light/dark visual review.
The later account reading and verification receipt accompany the archive; its 23:12 snapshot is unchanged.
Renderer success establishes syntax, not
mathematical truth. No product code, deployed model choice, physical device, NAS or TextBrain was changed here.

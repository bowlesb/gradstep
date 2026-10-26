# Complete inline-equation coverage — 2026-10-26

Status: quality gates passed locally; integrated into `main` as one standalone commit after `5056fd1a`.
Port 17 and the v5a model pack are verified; no TestFlight upload or deployment. The completed worktree is retired
after preserving its evidence.

The preceding integrity fix keeps uncertain formulas as original PDF crops. It does not repair a tagger span that
ends inside a formula. The desktop already has v5a: a two-layer bidirectional GRU trained with 24 neighboring glyphs
from each adjacent line, additional table-cell examples and 3,600 training papers. Its Core ML export is on this Mac
under `~/gradstep-mac/inline-tagger-v5a-coreml`. The current app still uses v4 and ten input features; v5a needs twelve.

## Goal and gates

- At least **10% fewer cut/split detections** than shipped v4 on the same complete labeled test lines, counting
  every gold glyph and span. Use fixed model weights and their development-selected thresholds.
- No decrease in text F1 or inline glyph accuracy on the recorded arXiv and publisher comparisons using the
  current converter. Review concrete PDF examples as well as aggregate automatic scores.
- No dropped tail when context fills the model's 400-glyph input. Long lines need bounded windows, with predictions
  stitched back to the original positions before forming equation spans. Context predictions cannot become content.
- Verify Core ML output, feature-width/vocabulary compatibility, correct weight digest and pack manifest. Keep
  device-only processing, official arXiv HTML precedence, reader interactions and paused physical-phone work intact.

## Initial evidence and implementation design

The existing desktop prototype adds neighboring context but truncates a line to `400 - before - after` glyphs.
The previous training report also scores only that prefix, giving v4 and v5a slightly different gold counts.
This comparison must be rerun on the same complete lines. The new evaluator uses exact-length batches so
bidirectional recurrence does not see batch-padding tokens that are absent in the actual Core ML call.

Short-line inputs match the evaluated prototype. A long line is covered by bounded windows with neighboring
context, preserving its original line-relative geometry. Output logits are assigned once per original glyph and
then converted into spans, allowing a span to continue across a window boundary. Context is drawn only from the
same layout region; table cells remain independent. The host validates the model's feature width against its
vocabulary instead of hard-coding ten columns. The model lock and generated pack identity must name the actual
v5a package, not the prototype's stale v4 digest.

## Fixed labeled comparison

The old reports were not a fair acceptance test: truncation changed the gold denominator, and padding a variable-length
batch changed the bidirectional model's backward pass. `evaluate_tagger_coverage.py` scores complete lines with
equal-length batches and records hashes of the checkpoints, training reader and every data file.

The available development split is **399 papers, 30,803,703 glyphs**; the held-out split is **30 papers,
2,222,698 glyphs and 24,908 gold spans**. Paper-family overlap between train/development/test is zero. The separate
arXiv/publisher conversion corpora also have zero family overlap with those training, development or labeled test sets.

The exported 0.8 threshold gave only 3.6% fewer cut/split errors on the complete held-out set. Calibration then used
development data only: 0.6/0.65/0.7/0.75/0.8. **0.7** balances boundary coverage and precision: development cut/split
errors fall from 5,725 to 4,197 (26.7%); span precision rises from 85.49% to 88.44% and glyph precision from 95.14% to
96.86%. Lower thresholds lose precision; higher ones leave more cut boundaries. This policy was fixed before the
subsequent held-out evaluation. No weights were trained or selected on these conversion corpora.

| Complete held-out labels | Shipped v4, 0.7 | v5a, 0.7, complete windows |
|---|---:|---:|
| Cut / edge-cut / split errors | 830 | **682 (−17.8%)** |
| Same errors in prose lines only | 665 | **554 (−16.7%)** |
| Exact span F1, all item kinds | 80.53% | 83.78% |
| Exact span F1, prose lines | 86.87% | 90.17% |
| Glyph precision / recall | 96.39% / 93.27% | 98.27% / 96.83% |
| Input glyphs omitted by truncation | 3,778 | **0** |

The prototype v5a omitted 4,501 held-out glyphs because context consumed input space. The complete-window policy
omits none on either split. These are automated label comparisons across prose, display rows and table cells;
they do not imply that every formula in a real PDF is correct.

## Complete paper comparison

Baseline is main `5056fd1a` / port 16 / v4. Candidate is port 17 / v5a / threshold 0.7. Both are scored now against
the same current HTML reader, including the preceding operator-integrity guard. Do not compare these numbers with
older desktop score files that used a different reader/compiler.

All **93 PDFs / 2,532 pages** replay with **zero missing tagger or recogniser answers**. Of these, **83 PDFs / 2,140
pages** have an accepted exact-revision HTML reference; the same ten reference refusals are excluded on both sides.
Existing local Core ML answers are reused, with **372 sampled inputs / 25,763 glyphs** checked against the rebuilt
export, bit-identical. New windows use real Core ML outputs. All **700 new recogniser crops** (228 development,
183 test, 289 publisher) were rendered and recognised on this Mac using the unchanged locked recogniser. Evaluation
replays use blank image pixels for scoring, not for visual verification; the examples below use the actual PDFs.

| Corpus | Papers | Text F1, before → after | Inline glyph match, before → after | Inline recall, before → after |
|---|---:|---:|---:|---:|
| arXiv development | 26 | 90.0% → 90.0% | **91.4% → 93.3%** | 87.7% → 88.5% |
| arXiv test | 30 | 89.9% → 89.9% | **91.8% → 92.7%** | 86.7% → 86.9% |
| Publisher PDFs | 27 | 85.4% → 85.6% | **81.5% → 84.5%** | 81.4% → 82.9% |

Here “inline glyph match” is the fraction of **aligned whole equations** whose normalized glyph sequence agrees
with the HTML reference, not individual-character accuracy or a guarantee of mathematical correctness. Typeset
inline precision also rises: 92.4% → 94.2%, 92.4% → 93.1%, and 86.0% → 87.9%, respectively.

**Tradeoff:** table-cell F1 changes 78.3% → 78.2%, 74.7% → 74.4%, and 75.0% → 76.7%. The small arXiv decreases are
retained and disclosed; table-content fidelity remains separate work. Display glyph-match scores are unchanged
on the test and publisher sets. Layout and recogniser weights are unchanged.

Visually checked examples (`visual-examples.json`, six rendered PNGs):

- arXiv `2610.26815v1`, PDF page 17: `Δₖ = rₖ cos θ` used to have separate equation regions around `Δₖ = rₖ` and
  `θ`, leaving `cos` out. The new region covers and typesets the whole expression.
- SciPost `other-scipost-16-1-012`, PDF page 4: `Tⱼᵢ = Tⱼ − Tᵢ` used to tag only `=` and `−`. The new region covers
  the complete equation. This verifies a concrete improvement on a non-arXiv PDF.

## Apple runtime and packaging

The Swift host validates the vocabulary's context/max length against the loaded model's feature width. The model
uses twelve features; the old ten-feature input is still supported for v4 fixtures. Context is restricted to the
same region, table cells stay independent, and output is stitched before spans are formed.

The actual compiled Core ML model matches **5,348 / 5,351** sampled PyTorch glyph decisions (60 inputs). Three
threshold-adjacent decisions differ with the fp16 export; maximum absolute logit difference 0.0791, mean 0.0155.
This is measured parity with a stated precision limit, not an exact-equivalence claim.

The native checks also exposed intermittent entirely zero output buffers, including during a sequential replay
under CPU load. Those runs were rejected. The host now retries invalid length, non-finite or all-zero outputs once
on the same worker's model instance and fails explicitly if they persist. This prevents silent “all prose” decisions;
it does not claim to solve every source of Core ML nondeterminism. Reused source records contain no all-zero lines.

The prototype metadata incorrectly retained v4's digest. The pack is rebuilt from the actual v5a package:

- Tagger package SHA-256: `bf495a7c8e50c62e4545e743ddf354d219de56f51054d92cc92743ed4ee8bc5f`.
- Threshold **0.7** is pinned in the model lock and copied into the pack vocabulary; the source export is read-only.
- Pack version: `22a94b3b0cf1102d03fb63a46b33a43e778d31cb6aedf78aa0df3eae0ce1d6e1`.
  All 19 files, sizes and hashes, the version digest, vocabulary policy and lock identities are verified.

Verification: `npm test`; five new converter regressions covering tails, crossing equations, context exclusion,
regional/table isolation and malformed outputs; native model-contract, retry and pack tests; actual Mac Core ML +
JavaScriptCore conversions with JIT disabled of the complete five-page `2610.28350v1` and ten-page publisher PDF
`cvf-cvpr2024-ungeneralizable-examples`, both with no conversion warnings. This is Mac evidence; the physical phone
remains paused, and no new iPhone latency or release claim is made.

## Evidence and limits

Inputs, snapshots, original and completed records, labeled scores, before/after corpus scores, crop answers, native
logs, manifest and visual examples are retained outside the worktree in the main checkout's
`.artifacts/pdf-span-coverage-20261026/`. `complete_span_replay.mjs` refuses incomplete recogniser answers before
scoring; its audit records original PDF/record hashes and original provenance instead of silently rewriting history.

Partial layout regions, equations crossing physical lines, scans with poor OCR, and uncertain recogniser output
remain product gaps. This work improves inline detection; it does not reconstruct arbitrary missing PDF geometry.
The earlier integral integrity regressions remain covered by their tests. Official arXiv HTML stays the primary
reader path, every PDF stays on device, and existing readings are not migrated. No paid usage or new infrastructure.

# Subfigure detector, release-candidate round — 2026-10-22

Status: **complete for this round; the release candidate does not meet the gates.** Research only; no
application code, model catalogue or release changed. Builds on [the 10-21 report](SUBFIGURE_DETECTOR_20261021.md); gates from
[Local figure regions](../architecture/LOCAL_FIGURE_REGIONS.md): ≥ 95% panel recall and < 2% wrong crops.
Goal of this round: integration step 2 — detector parts P1, P2… offered to the figure explainer, Mac first.

## Summary

- **Release candidate (rights-clean, RT-DETRv2-M, epoch 10, + completion + OCR letter grouping + caption
  decoding + two-view agreement)** on the new never-seen final test 2 (240 figures, 201 papers, scored once):
  **73.3% (95% CI 67.8–79.0) fully right, 18.8% (13.9–23.9) harmful**, panel recall 84.1% (77.8–89.9), crop
  precision 97.8%, single false splits 5.6%. Versus the previous v13 detector on the same test: +20.4 points
  fully right (13.9 to 26.9), −10.8 points harmful (−17.2 to −4.5); versus the 10-21 frozen system (which used
  SCI-3000): +2.9 (0.0 to 6.0) and −2.5 (−5.7 to 0.4). **Gates (≥ 95% panel recall, < 2% wrong crops): not met.**
- The largest failure on test 2 is **clipping** (30 figures, mostly plot grids: 99.5% of their panels are
  found but a few pixels to 9% of a panel's ink fall outside the crop; 10 of the 30 lose < 2%). Framed
  diagrams (44% right) and touching raster panels (40%, n = 10) remain the weakest classes.
- **Targeted data did not clearly fix the targeted classes** on validation (small classes, wide intervals):
  touching raster 64.7 → 70.6%, lettered plot groups 35.3 → 23.5% (the model now keeps more of them whole,
  harmful 47 → 41%), framed diagrams 56 → 52%. The overall validation gain over the clean baseline is small
  (76.1 → 77.3%, harmful 16.4 → 12.2%). OCR letter grouping adds about one point.
- **Integration step 2 (parts offered to the explainer):** if the explainer groups plotting-level parts
  correctly, 73.8% of test-2 figures are usable (65% of compound figures groupable) — barely above the
  direct-crop score, because the remaining errors are clipping and abstention, not over-splitting.
- **Exports:** Core ML FP32 of the RC (132 MB R50-M; 80 MB R18 comparator) gives **identical delivered crops**
  on 40 validation figures (edges within 0.001 px), 41 ms / 32 ms warm on the M1 Max. FP16 (66 / 40 MB) and
  int8 weights (34 MB) **fail** (crop edges move up to 660 px; counts change). ONNX matches PyTorch to 5e-5 and
  runs in Chromium via onnxruntime-web WASM (2.7 s R50-M, 1.7 s R18 per figure; WebGPU unsupported ops).
- **Pipeline:** `scripts/subfigure-detector/` is now the documented `sfd` package with configs, seeds, a
  README of exact commands and a 28-test pytest suite; `policy.decide()` is the reference for the apps.
- Cost: $0 model/API (no vision LLM); about 6 GPU-hours on the RTX 3090; electricity not priced.

## What changed since 10-21

1. **Release-candidate data is rights-clean**: no SCI-3000 images; pseudo-labels come from a teacher (r7)
   that never saw SCI-3000. Configs: `scripts/subfigure-detector/configs/`.
2. **Targeted data for the failure classes** (all from training-split papers):
   - *lettered parts made of several plots*: `letter_groups.py` assigns each plotting area of a figure PDF to
     its printed letter from the PDF text layer ('(a)', '(a) Title', 'a)' or bold single letters), top or
     bottom layout by majority, rejecting overlaps — **163 figures** (of 568 lettered figures with more areas
     than letters; 405 lack a clean a…L letter set in the text layer). Visual QA: 14 of 16 correct. Plus 159
     row/column-grouped figures from 10-21 and **2,500 synthetic** lettered groups whose plots are sibling
     panels of one real compound figure.
   - *framed diagram panels joined by arrows*: **1,500 synthetic** rounded/tinted frames with titled letters,
     arrows as shared context.
   - *touching raster panels*: **2,000 synthetic** gutter-free tiles cut from real raster figures, letters
     printed inside the tiles; 30% are the same grids without letters, labelled one figure (policy: unlettered
     example grids are single).
   - *grids of ≥ 5 panels*: **1,500 synthetic** 5–12-panel lettered grids.
   - clean pseudo-labels: 5,641 compound + 8,433 single (two-view + caption agreement, teacher r7 e09).
3. **Post-processing**: OCR letter grouping — when the caption names L parts and Mac Vision OCR finds exactly
   the letters a…L once each, detected plotting areas are grouped under their letters (same geometry as the
   miner). Policy file `configs/systems/policy-letters-decode-agree-t05.json`.
4. **A new, never-seen final test** (below), annotated before any model saw it.
5. **Pipeline**: `scripts/subfigure-detector/` is now the `sfd` package — one module per stage, checked-in
   configs, seeded randomness, README with exact commands and rights notes, pytest suite (27 tests, Mac, no
   GPU). Removed: ensemble fusion and ad-hoc shell drivers (ensembles did not help on 10-21).
6. **One reference implementation of the on-device decision**: `policy.decide()` (used by every evaluation;
   reproduces the 10-21 frozen validation numbers exactly: 75.63% / 96.17%).

## New final test (test 2)

Sampled from test-split papers whose **whole author/family component** never contributed to the 10-21
validation or test sets (`fresh_test.py`: 955 of 1,406 test-pool papers), 2 figures per paper at most, half from
captions naming ≥ 2 panel letters, half from the natural remainder; single-file figure environments as the app
receives them. A separate annotator pass labelled all 247 candidates before any model saw them: **240 figures,
201 papers; 168 compound / 72 single; 535 panels in compound figures**; 7 excluded (4 with > 12 panels, 3
ambiguous). Per-class (compound): plot-grid 82, framed-diagrams 36, many-panels 17, touching-raster 14,
other 13, lettered-plot-groups 6. Locked hashes: annotations `4f2b41c8…56a7`, GT `fb373b9c…48ed`
(`data/eval-test2/LOCKED.sha256`). Claude visual annotations, not independent human review.

## Exports

| Format | Size | Delivered-crop parity (40 validation figures) | Latency |
|---|---|---|---|
| **RC R50-M, Core ML FP32** | 132 MB | **identical** (≤ 0.001 px, 40/40) | 41 ms warm, 0.33 s first (M1 Max, ALL units) |
| RC R18, Core ML FP32 | 80 MB | identical (≤ 0.001 px, 40/40) | 32 ms warm, 0.18 s first |
| RC R50-M / R18, Core ML FP16 | 66 / 40 MB | **fails**: 25/40 figures move a crop edge > 1 px; 2 / 1 change count | 127 / 85 ms |
| RC R50-M, ONNX opset 17 (onnxruntime 1.31 CPU) | 132 MB | max box error 3e-5, probability 5e-5 (30 figures) | host CPU |
| 10-21 R50-M, Core ML FP32 (ML Program) | 132 MB | identical (≤ 0.03 px) | 40 ms warm (M1 Max, ALL units) |
| 10-21 R50-M, Core ML FP16 compute | 66 MB | **fails**: 25/40 figures move a crop edge > 1 px, 2 by > 290 px, 1 changes count | 128 ms |
| 10-21 R50-M, FP32 + int8 weights | 34 MB | **fails**: 8/40 change, 2 by > 370 px | 184 ms (CPU) |
| 10-21 R50-M, ONNX opset 17, onnxruntime 1.31 CPU | 132 MB | max box error 1e-4 | 202 ms (host CPU) |
| 10-21 R50-M / R18 ONNX in headless Chromium 153, onnxruntime-web 1.20.1 **WASM** (`sfd/export/web/`) | 132 MB (R50-M) / 80 MB (R18) | max probability diff 1e-5, box 4e-5 | 2.7 s / 1.7 s per figure; WebGPU fails (unsupported AveragePool ceil mode; adapter error) |

DETR-style decoders pick the top queries by score, so small numeric changes swap which queries survive; FP16
and post-training int8 therefore change decisions, not just coordinates. A smaller model needs quantization-
aware fine-tuning or a smaller FP32 backbone (R18, 80 MB).

## On-device API for the integration (step 2: parts P1, P2… offered to the explainer)

Reference implementation: `scripts/subfigure-detector/sfd/core/policy.py` (`letterbox_transform`,
`decode_outputs`, `decide`, `caption_letters`, `letters_from_text`). End-to-end golden cases (raw model outputs
→ expected parts) are produced by `sfd/export/golden.py` into `.artifacts/subfigure-detector-20261022/golden/`;
they are not placed in `tests/fixtures/figure-crops/` (owned by the completeness-port work).

**Call (per displayed image asset, never across stacked-asset boundaries):**

```
detectFigureParts(image: RGBA8 bitmap as displayed/sent, caption: String, ocrLines: [TextLine]?)
  -> FigureParts { status: "split" | "whole", reason: String, parts: [Part], modelSHA256, policyRevision }
Part { id: "P1"…, box: {x, y, width, height} in original image pixels (before the 2% display margin),
       score: Float (detector confidence of the part, 0–1) }
TextLine { text: String, box: {x0, y0, x1, y1} in image pixels }   // Mac: VNRecognizeTextRequest, .accurate
```

**Preprocessing (identical for both runs):** composite alpha over white; RGB; for zoom z ∈ {1.0, 0.75}:
`s = min(640/W, 640/H)·z`, `rw = max(1, round(W·s))`, `rh = max(1, round(H·s))`, bilinear resize to rw×rh,
paste at `left = floor((640−rw)/2)`, `top = floor((640−rh)/2)` on a 640×640 white canvas; float32 NCHW, /255.

**Model:** input `images` [1,3,640,640]; outputs `logits` [1,300,2] (class 0 = panel, 1 = shared context) and
`boxes` [1,300,4] (normalized cx, cy, w, h in the 640 canvas). **Decode:** p = sigmoid(logits), class = argmax,
score = max, keep score ≥ 0.03, `x0 = (cx·640 − w·320 − left)/sx` etc., clamp to the image.

**Policy (`decide`, constants in `configs/systems/*.json`):** ink = min(R,G,B) < 235; panel boxes ≥ 0.5;
suppress IoU > 0.5 or containment > 0.85; a box ≥ 85% of the image means one figure; completion; optional OCR
letter grouping; caption-constrained decoding when the caption names L ≥ 2 letters (candidates ≥ 0.15, exactly
L non-overlapping boxes covering ≥ 70% of the ink); the 0.75-zoom run must agree (same count, pairwise
IoU ≥ 0.7). Parts are ordered in reading order (rows top to bottom, then left to right).

**"Unsure → fall back":** `status == "whole"` with `reason` ∈ {`single-or-unsure`, `views-disagree`}. The app
then behaves exactly as today (whole figure; the explainer may still write its own boxes, which the
completeness check guards). `split` parts are candidates, not ground truth: the explainer chooses, groups or
ignores them by id.

**Prompt contract (proposal):** send `<figure_parts>P1 [x,y,w,h] P2 […]</figure_parts>` (normalized
top-left x, y, width, height, 4 decimals) with the figure; add an optional `parts: ["P1", "P2"]` field to
walkthrough sections and `show_figure_parts` parts. The server validates ids against the parts sent; the device
crops its own boxes (plus the display margin) for the chosen ids, union for groups. No coordinates need come
from the model when parts exist.

**Resources (Mac):** run once per image in a cancellable background task; two model runs per figure (≈ 80 ms
warm FP32 R50-M on the M1 Max, plus ≈ 0.9 s first load); one model instance; cache by image SHA-256 + model
SHA-256 + `policyRevision`.

## Selection rule (declared before the last R50-M epochs finished and before any test-2 prediction)

The release candidate is the checkpoint of `rc-r50m-clean` or `rc-r18-clean` with the highest mean app success
over the two validation sets under `policy-letters-decode-agree` at threshold .5 or .6; ties go to the lower
arXiv harmful rate, then to the smaller model. Test 2 is then scored once for that system, with the 10-21 frozen
system and v13 as fixed comparators.

## Validation results and the frozen release candidate (18:16 UTC, before any test-2 prediction)

Policy `policy-letters-decode-agree` (completion + OCR letter grouping + caption decoding + two-view agreement).
Mean = mean app success over the two validation sets.

| Checkpoint | arXiv val app success | arXiv harmful | arXiv panel recall | Frozen val app success | Mean |
|---|---|---|---|---|---|
| 10-21 frozen R50-M r4 e04 (includes SCI-3000) + letters | 76.5 | 13.0 | 80.2 | 96.2 | 86.3 |
| r7 R50-M clean (no targeted data) e09 + letters | 76.1 | 16.4 | 82.9 | 93.9 | 85.0 |
| **rc-r50m-clean e10, t .5 (selected)** | **77.3** | **12.2** | 79.2 | 93.6 | **85.5** |
| rc-r50m-clean e15, t .5 | 77.7 | 11.3 | 79.4 | 92.7 | 85.2 |
| rc-r18-clean e13, t .6 (best small model) | 75.2 | 14.3 | 80.6 | 94.9 | 85.1 |

Frozen: `rc-r50m-clean` EMA e10 SHA `decb1569…8863`, system `e99e0772…a6aa`, policy.py `12a8d0c9…28b0`;
size comparator `rc-r18-clean` EMA e13 SHA `1d27aa38…f0f9` at t .6. Declared test-2 systems: the RC, the R18
comparator, the 10-21 frozen system (its own policy) and v13 raw.

## Final test 2 (scored once, 2026-10-21 ≈ 18:40 UTC)

`sfd/evaluation/score_test2.sh` verified the locked GT/annotation hashes, hashed the frozen checkpoints,
systems, policy code and test OCR, then predicted and scored each declared system once (5,000 paper-level
bootstrap resamples). Test-2 OCR (Mac Vision) is a system input, run without inspecting the images.

| Test 2 (240 figures, 201 papers; 168 compound / 72 single) | Fully right | Harmful | Single false split | Compound perfect | Count right | Panel recall | Complete panels | Crop precision | Full coverage | Kept whole | Groupable |
|---|---|---|---|---|---|---|---|---|---|---|---|
| v13 raw (10-19) | 52.9 (46.5–59.8) | 29.6 | 12.5 | 38.1 | 61.9 | 66.5 | 54.6 | 75.3 | 62.7 | 25.0 | 40.5 |
| v13 + completion | 58.3 (52.0–64.7) | 24.2 | 12.5 | 45.8 | 61.9 | 68.2 | 60.6 | 77.2 | 87.3 | 25.0 | 49.4 |
| 10-21 frozen (R50-M, SCI-3000) | 70.4 (64.4–76.4) | 21.2 | 6.9 | 60.7 | 79.2 | 82.1 | 74.0 | 92.4 | 93.2 | 11.9 | 63.1 |
| **Release candidate (R50-M, clean)** | **73.3 (67.8–79.0)** | **18.8 (13.9–23.9)** | 5.6 | 64.3 | 83.9 | 84.1 (77.8–89.9) | 75.7 | 97.8 | 94.6 | 11.3 | 64.9 |
| R18 comparator (clean, 80 MB) | 71.7 (65.6–77.5) | 20.4 | 8.3 | 63.1 | 82.7 | 83.9 | 75.9 | 98.0 | 95.3 | 11.3 | 63.1 |

RC outcomes: 108 perfect + 68 correct whole; 19 compounds kept whole; 30 clipped, 7 merged, 4 false splits,
3 wrong boxes, 1 extra. Decision reasons: caption-decoded 89, single/unsure 74, detector 48, caption mismatch
→ detector 13, views disagree 13, letter-grouped 3.

| Class (test 2) | Figures | RC fully right | RC harmful | RC panel recall | 10-21 frozen fully right |
|---|---|---|---|---|---|
| plot grid | 82 | 76.8 | 23.2 | 99.5 | 75.6 |
| single | 72 | 94.4 | 5.6 | — | 93.1 |
| framed diagrams | 36 | 44.4 | 33.3 | 66.3 | 36.1 |
| many panels (≥ 5) | 21 | 61.9 | 19.0 | 80.1 | 71.4 |
| other | 13 | 61.5 | 15.4 | 71.0 | 61.5 |
| touching raster | 10 | 40.0 | 20.0 | 54.5 | 20.0 |
| lettered plot groups | 6 | 66.7 | 33.3 | 100.0 | 33.3 |

Test 2 is harder than the 10-21 test for every system (v13: 52.9% vs 59.1%; 10-21 frozen: 70.4% vs 80.4%):
more framed diagrams and more clipping-prone plot grids. The RC is 4 points below its validation score.
Galleries: `.artifacts/subfigure-detector-20261022/galleries/test2-rc-*.jpg` (viewed after scoring only).

## Against the gates, and what this means for integration

Panel recall 84% (gate 95%) and wrong crops on 18.8% of figures (gate < 2%): **automatic cropping is not
justified.** Step 2 can still be offered safely *as candidates*: the explainer sees parts P1… and may use,
group or ignore them, and every crop it shows still passes the completeness check. Recommended order:
(1) completeness check everywhere (in progress by the integration agent); (2) parts as optional candidates on
the Mac behind a flag, with the whole-figure fallback when `status == "whole"`; (3) no iPhone model until a
quantization-aware or smaller model keeps FP32-identical decisions — the iPhone size target proposed here is
≤ 40 MB, which only the R18 at FP16 reaches today and it fails parity.

## What did not work (this round)

- Targeted synthetic classes and letter-grouped labels: no clear per-class gain on validation; small classes.
- FP16 and int8 weight compression: decisions change (DETR top-k query selection is discontinuous).
- WebGPU in headless Chromium: unsupported AveragePool ceil mode (R18) and an adapter error (R50-M).
- Removing SCI-3000 costs ~2.5 points on the old SCI-3000-style validation set (93.6 vs 96.2), not on arXiv.

## Next

1. Clipping is now the dominant error: train with completion-consistent targets (panel boxes that already
   include every pixel the completion step would add), and evaluate the integration agent's background margin
   on these sets.
2. Framed diagrams: real data — the LaTeX sub-figure page composites (5,443) matched the class but did not help
   as a fine-tune; try them inside full training with diagram-heavy sampling.
3. Quantization-aware fine-tuning or a distilled R18 at FP16 for iPhone; repeat crop-level parity.
4. An independently human-reviewed test before any automatic-cropping claim.

## Evidence

`.artifacts/subfigure-detector-20261022/`: `final-test2/` (all test-2 results, frozen inputs and hashes,
validation per-class and step-2 results), `export/` (Core ML parity reports, RC FP32 packages, browser harness
output), `golden/golden-cases.json` (24 validation figures: raw outputs of both runs → expected `decide()`
parts, RC checkpoint SHA `decb1569…`), `galleries/`, `data-engine/` (QA sheets of letter groups and the class
synthesizers). GPU host: `/home/ben/science-reader-subfigures/d21/` (`runs/rc-*`, `eval/frozen-rc/`,
`eval/final-test2/`, `data/eval-test2/`).

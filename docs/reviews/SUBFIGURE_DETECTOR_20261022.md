# Subfigure detector, release-candidate round — 2026-10-22

Status: **in progress** (sections are filled as results arrive). Research only; no application code, model
catalogue or release changed. Builds on [the 10-21 report](SUBFIGURE_DETECTOR_20261021.md); gates from
[Local figure regions](../architecture/LOCAL_FIGURE_REGIONS.md): ≥ 95% panel recall and < 2% wrong crops.
Goal of this round: integration step 2 — detector parts P1, P2… offered to the figure explainer, Mac first.

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

## Exports (measured on the 10-21 frozen R50-M checkpoint; repeated for the RC below)

| Format | Size | Delivered-crop parity (40 validation figures) | Latency |
|---|---|---|---|
| Core ML FP32 (ML Program) | 132 MB | identical (≤ 0.03 px) | 40 ms warm (M1 Max, ALL units) |
| Core ML FP16 compute | 66 MB | **fails**: 25/40 figures move a crop edge > 1 px, 2 by > 290 px, 1 changes count | 128 ms |
| Core ML FP32 + int8 weights | 34 MB | **fails**: 8/40 change, 2 by > 370 px | 184 ms (CPU) |
| ONNX opset 17, onnxruntime 1.31 CPU | 132 MB | max box error 1e-4 | 202 ms (host CPU) |
| ONNX in headless Chromium 153, onnxruntime-web 1.20.1 **WASM** | 132 MB (R50-M) / 80 MB (R18) | max probability diff 1e-5, box 4e-5 | 2.7 s / 1.7 s per figure; WebGPU fails (unsupported AveragePool ceil mode; adapter error) |

DETR-style decoders pick the top queries by score, so small numeric changes swap which queries survive; FP16
and post-training int8 therefore change decisions, not just coordinates. A smaller model needs quantization-
aware fine-tuning or a smaller FP32 backbone (R18, 80 MB).

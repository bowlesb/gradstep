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

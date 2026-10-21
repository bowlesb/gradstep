# Subfigure detector round 3: structure first, bottom-up ink grouping, local VLM judge — 2026-10-23

Status: **complete for this round; no approach meets the gates and none beats the 10-22 release candidate.** Research only; no application code, model catalogue or
release changed. Previous rounds: [10-21](SUBFIGURE_DETECTOR_20261021.md), [10-22](SUBFIGURE_DETECTOR_20261022.md).
Gates: ≥ 95% panel recall and < 2% wrong crops. All development uses the 238-figure arXiv validation set and the
313-figure frozen validation set; test 2 is spent and is not used here.

## Summary

- **Structure first:** in the 152,680 figure elements of the corpus HTML, **15.7% already have ≥ 2 images**
  (exact parts, no model; 9.6% with sub-captions). The model is needed only for single-image figures (74%); one
  in eight of those names ≥ 2 parts in its caption (8.9% of all figures).
- **Bottom-up ink grouping** (components → learned pairwise affinity → average-linkage clustering, 2.9 MB model,
  55 ms per figure) does what it promises structurally — every ink pixel ends in a crop, clipping drops — but on
  arXiv validation it reaches only **68.5% (62.5–74.0) fully right with 24% harmful** versus **77.3% / 12.2%** for
  the 10-22 detector policy; without the detector prior 55.9%. It under-splits touching/framed panels (one
  connected component) and over-splits lettered plot groups and legends. Used to refine the detector's crops it
  changes nothing (orphan attachment) or hurts (re-seeding). Not adopted.
- **Local VLM judge** (Qwen2.5-VL-7B-Instruct, Apache-2.0): good at single-vs-compound (92%), panel count (85%)
  and reading the letter of a boxed part (97%); **degenerate** on ownership (shared vs owned), "one lettered
  panel?" and verifying a split (it always answers the same word). As an agreement filter on noisy training
  labels it keeps clean labels but mostly discards correct pseudo-labels; an R18 fine-tune with filtered labels
  scores 75.6% vs 74.8% unfiltered on validation (+0.8 points, 2 figures — within noise). As an offline check,
  disagreement between its count and the detector's split flags the bad splits well (21% perfect when they
  disagree vs 87% when they agree).
- **Gates (≥ 95% panel recall, < 2% wrong crops): not met** by anything in this round; the 10-22 release
  candidate (test 2: 73.3% fully right, 18.8% harmful, 84% recall) remains the best system. Test 2 is spent; a
  fresh test-3 candidate set (227 figures from unused author families) and an independent-review packet are
  ready, not yet labelled.
- Cost: $0 paid API; RTX 3090 ≈ 2 GPU-hours (VLM ≈ 1 h, two detector fine-tunes ≈ 40 min, predictions) plus CPU; electricity not priced.

## 1. Structure first: how often the HTML already splits a figure

`sfd/mine/html_structure.py` parses every `<figure class="ltx_figure">` (tables excluded) in the official
`arxiv.html` of all **18,627** corpus papers, counting graphics (`<img>` and SVG `<object>` with class
`ltx_graphics`), nested sub-figures with their own captions, and the caption's panel letters.

| Figure elements (152,680) | Count | Share |
|---|---|---|
| **≥ 2 images** — parts already exact, no model needed | 24,036 | 15.7% |
| ↳ with sub-figure captions | 14,639 | 9.6% |
| ↳ without sub-figure captions | 9,397 | 6.2% |
| One image, caption names ≥ 2 panel letters — needs the model | 13,548 | 8.9% |
| One image, no panel letters (single figure or unlettered compound) | 98,876 | 64.8% |
| No raster/SVG graphic (TikZ rendered as markup, text, algorithms) | 16,220 | 10.6% |

The app already stacks multi-image figures and keeps each image's rectangle, so those parts are exact
(no ML): the detector should run per image and never across stacked images. The model matters for the 74% of
figures that are a single image; about one in eight of those names its parts in the caption. (The 10-21/10-22
validation and test sets sampled exactly this single-image case.)

## 2. Bottom-up ink grouping

Design (`sfd/group/`): the figure is decomposed into ink components (ink = min(R,G,B) < 235, components after a
square dilation of radius 0.3% of the long side, so glyphs join into words and ticks stay with their axis).
Candidate pairs are each component's 8 nearest neighbours plus all pairs of large components. A gradient-boosted
classifier (scikit-learn `HistGradientBoostingClassifier`, 400 trees, ≈ 2.9 MB) predicts "same panel" from 35
geometric features (gaps, overlaps, sizes, text-likeness, ink in the gap, clean whitespace gutters between them)
and, optionally, a detector prior (both components inside the same RT-DETR panel box). Average-linkage
agglomeration merges components while the mean affinity ≥ 0.5; clusters holding ≥ 4% of the ink are panels and
smaller clusters (letters, legends, stray labels) attach to their most affine panel. With caption letters, the
merge history is replayed to the stage with exactly L panels. Crops are the bounding boxes of whole components,
so a crop cannot cut a component and every ink pixel lands in some crop. Optionally, components spanning two or
more detector boxes (touching panels, shared spines) are cut along those boxes.

Training data: 14,084 training-split figures (6,000 vector compounds, 2,500 vector singles, 163 letter groups,
623 letter-verified whitespace compounds, 1,000 whitespace singles, 1,800 synthetic compounds/negatives,
2,400 class synthetics), giving 2.55 M labelled pairs (component truth = the vector/synthetic panel box holding
≥ 90% of its ink; shared components only as negatives).

| Variant (arXiv validation, 238 figures) | Fully right | Harmful | Single false split | Compound perfect | Panel recall | Crop precision | Clipped | Not split | Merged |
|---|---|---|---|---|---|---|---|---|---|
| RC detector + policy (10-22, for reference) | 77.3 | 12.2 | 0.0 | 69.3 | 79.2 | 90.2 | 13 | 25 | 7 |
| Grouping, no detector prior (pair AUC .929), + caption | 55.9 | 30.3 | 9.7 | 43.8 | 57.5 | 77.0 | 10 | 33 | 39 |
| Grouping + R18 detector prior (pair AUC .986) | 64.3 | 21.0 | 11.3 | 55.7 | 65.5 | 79.1 | 7 | 35 | 13 |
| + detector-guided component splitting | 65.5 | 22.7 | 12.9 | 58.0 | 69.0 | 78.0 | 7 | 28 | 12 |
| + caption-count replay | 68.1 | 23.5 | 12.9 | 61.4 | 72.2 | 80.0 | 9 | 20 | 18 |
| v2: prior from an early detector checkpoint, split-consistent training (pair AUC .974), + split + caption | 68.5 (62.5–74.0) | 24.0 | 9.7 | 60.8 | 72.4 | 80.0 | 10 | 18 | 19 |
| Seeded: RC crops rebuilt from whole components | 73.5 | 16.0 | 0.0 | 64.2 | 76.4 | 87.2 | 14 | 25 | 13 |
| Seeded: RC crops + learned orphan attachment only | 77.3 | 12.2 | 0.0 | 69.3 | 79.1 | 90.2 | 13 | 25 | 7 |

What it fixes and what it does not: clipping falls (7–9 clipped figures vs 13–16 for the detector) and every
split covers 100% of the ink, as designed. But the grouping **under-splits** (35 compounds kept as one) because
touching or framed panels are one connected ink component or are bridged by connectors, and it **over-splits**
lettered plot groups and figures with large legends. Merge threshold (0.3–0.7) and panel-ink share (2–8%) do not
change this (66.8–68.5%). The v2 prior (weaker detector during training, so the model does not over-trust it) did
not help either.

Used as a refinement of the detector's crops it does not help: rebuilding crops from components lowers the
score (components that straddle panels drag crops together), and learned orphan attachment leaves every outcome
unchanged. A diagnostic of the RC's 13 clipped validation figures explains why: 76% of the missing ink belongs to
components lying entirely outside every crop and 24% to components cut by a crop edge — the completion step
already attaches the reachable ones, and the rest are elements whose ownership the annotator and the geometry
disagree on (legends between panels, column headings), not pixels a better grouping can recover.

Size and speed: the pair model is 2.9 MB; components + features + clustering take 55 ms median (98 ms p90;
38 components median) per figure in Python on one core. Without the detector prior it fits easily under the
40 MB iPhone target but scores 55.9%; with the R18 prior the bundle is ≈ 83 MB FP32 (the R18 export fails FP16
parity, 10-22).

## 3. Local VLM as judge (never coordinates)

Model: **Qwen2.5-VL-7B-Instruct**, Hugging Face `Qwen/Qwen2.5-VL-7B-Instruct` revision
`cc594898137f460bfe9f0759e9844b3ce807cfb5`, license **Apache-2.0** (permits commercial use of outputs);
transformers 4.51.3, bf16, SDPA attention, greedy decoding, images ≤ 0.8 MP with boxes drawn on them; it only
answers fixed words (`sfd/vlm/judge.py`). Throughput on the RTX 3090: **0.69 s per query** (batch 2, ≈ 17 GB).

| Decision (validation truth) | n | Accuracy (95% CI) | Notes |
|---|---|---|---|
| single vs compound | 238 | 92.0% (88.7–95.0) | says SEVERAL for 18 of 62 singles; when it says ONE it is right 44/45 |
| panel count (compound) | 176 | 85.2% (80.1–90.3) | errors are mostly large over-counts (2 → 11) |
| letter ↔ part (box drawn) | 109 | 97.2% (93.6–100) | truth = caption letters in reading order (approximation) |
| "are these plots one lettered panel?" | 79 | 92.4% | **degenerate**: always DIFFERENT (0/6 SAME correct) |
| shared vs panel-owned element | 112 | 56.2% | **degenerate**: almost always SHARED |
| verify a drawn split (complete & correctly grouped?) | 151 | 80.8% | **degenerate**: always CORRECT (0/29 wrong splits caught) |

So the 7B judge is usable for **single/compound (when it says ONE), panel count and letter reading**, and must
not be used for ownership, grouping or split verification. As a gate on the RC detector's validation output:
when its count agrees with the system's crop count, 86.9% of those splits are perfect (137 figures); when it
disagrees, only 21.4% are (14 figures). Its "ONE" answers changed nothing (the RC already keeps those singles).

### The judge as a labeler (agreement filter on noisy training labels)

The count question was put to the VLM for 1,500 sampled teacher pseudo-labels and all 1,043 unverified
whitespace (XY-cut) compound labels (0.69 s each; 2,543 queries ≈ 45 min with batching and a shared GPU). It agrees
with 85.8% of the pseudo-labels and 89.6% of the whitespace labels. A visual check of 12 kept and 12 dropped
figures per source (my review, development only):

| Source | Kept by VLM: labels correct | Dropped by VLM: labels correct |
|---|---|---|
| Teacher pseudo-labels | 12/12 | ≈ 10/12 (the VLM over-counted small plots, "11"/"12") |
| Whitespace labels | ≈ 11/12 | ≈ 7/12 |

So the filter removes some wrong whitespace labels but mostly discards correct pseudo-labels; its count errors
are systematic over-counts of plots inside lettered parts. Validation disagreements between the VLM count and
the ground truth (26 figures, `.artifacts/subfigure-detector-20261023/review-queue/`) are, on inspection, mostly
VLM over-counts, with two genuinely debatable groupings — the review queue works as a way to find label
ambiguity, but it is not a source of ground truth.

## 4. Fresh test proposal

A test-3 candidate pool is drawn from the 611 test-split papers whose author components never contributed to
the validation, test or test-2 sets: 227 single-image figures (`d23/data/eval-test3/`). Proposal: an independent
human reviewer labels them with the existing block/vector annotation sheets (no model output shown), double-checks
25% with a second reviewer, and the set is locked before any model run; VLM/detector disagreements on training
data form a separate review queue that never mixes with the test.

## 5. What this means for integration

1. Use HTML structure first: multi-image figures already have exact parts (15.7% of figures).
2. Keep the 10-22 detector policy as the candidate-part provider for single-image figures, behind the
   "whole" fallback; keep the model-free completeness check on every crop.
3. **Count agreement as an unsure signal:** the strongest new evidence is that a second opinion on the *number of
   parts* separates good from bad splits (offline: 87% vs 21% perfect). In the app the explainer model already
   sees the figure; if its own panel count (or its chosen parts) disagrees with the detector's count, fall back to
   the whole figure. This needs no on-device VLM.
4. No iPhone model yet: the only component under 40 MB that works is the grouping model without a detector, and
   it is far below the detector.

## What did not work

- Bottom-up grouping as a replacement (−9 points) and as a refinement (no gain).
- Detector-guided component splitting, a weaker training-time prior, caption-count replay: each ≤ 3 points.
- The VLM on ownership, grouping and split verification (degenerate answers); as a label filter, no measurable
  gain.

## Next

1. Label test 3 with an independent human reviewer (packet in `.artifacts/subfigure-detector-20261023/
   test3-review-packet/`), lock it, then score the release candidate once.
2. Prototype the count-agreement fallback in the explainer flow (integration step 2), measured on validation
   with the explainer's own answers.
3. For touching/framed panels, a per-pixel instance head (rather than connected components) is the remaining
   bottom-up idea; it needs real per-pixel labels, which the vector data provides for plots but not for photos.

## Evidence

`.artifacts/subfigure-detector-20261023/`: `html-structure.json`, `vlm-val-accuracy.json`, `vlm/` (answers,
label-filter QA sheets), `review-queue/` (VLM-vs-GT count disagreements), `test3-review-packet/`. GPU host:
`/home/ben/science-reader-subfigures/d23/` (`runs/aff-v*` grouping models, `eval/grp-*.json`, `runs/ft-r18-*`,
`data/qwen2.5-vl-7b-instruct` pinned at revision `cc594898…`). Code: `scripts/subfigure-detector/sfd/group/`,
`sfd/vlm/`, `sfd/mine/html_structure.py`; 33 pytest tests pass on the Mac.

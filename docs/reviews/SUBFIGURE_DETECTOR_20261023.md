# Subfigure detector round 3: structure first, bottom-up ink grouping, local VLM judge — 2026-10-23

Status: **in progress** (filled as results arrive). Research only; no application code, model catalogue or
release changed. Previous rounds: [10-21](SUBFIGURE_DETECTOR_20261021.md), [10-22](SUBFIGURE_DETECTOR_20261022.md).
Gates: ≥ 95% panel recall and < 2% wrong crops. All development uses the 238-figure arXiv validation set and the
313-figure frozen validation set; test 2 is spent and is not used here.

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
| RC detector + policy (10-22, for reference) | 77.3 | 12.2 | 4.8 | 69.3 | 79.2 | 87.0 | 13 | 20 | 4 |
| Grouping, no detector prior (pair AUC .929) | *pending* | | | | | | | | |
| Grouping + R18 detector prior (pair AUC .986) | 64.3 | 21.0 | 11.3 | 55.7 | 65.5 | 79.1 | 7 | 35 | 13 |
| + detector-guided component splitting | 65.5 | 22.7 | 12.9 | 58.0 | 69.0 | 78.0 | 7 | 28 | 12 |
| + caption-count replay | 68.1 | 23.5 | 12.9 | 61.4 | 72.2 | 80.0 | 9 | 20 | 18 |

What it fixes and what it does not: clipping falls (7–9 clipped figures vs 13–16 for the detector) and every
split covers 100% of the ink, as designed. But the grouping **under-splits** (35 compounds kept as one) because
touching or framed panels are one connected ink component or are bridged by connectors, and it **over-splits**
lettered plot groups and figures with large legends. Merge threshold (0.3–0.7) and panel-ink share (2–8%) do not
change this (66.8–68.5%).

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

## 4. Fresh test proposal

A test-3 candidate pool is drawn from the 611 test-split papers whose author components never contributed to
the validation, test or test-2 sets: 227 single-image figures (`d23/data/eval-test3/`). Proposal: an independent
human reviewer labels them with the existing block/vector annotation sheets (no model output shown), double-checks
25% with a second reviewer, and the set is locked before any model run; VLM/detector disagreements on training
data form a separate review queue that never mixes with the test.

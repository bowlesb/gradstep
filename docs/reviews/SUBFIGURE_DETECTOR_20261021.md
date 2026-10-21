# Subfigure detector from the 17K-paper corpus — 2026-10-21

Status: **research, not qualified for automatic cropping, not released.** No application code, model
catalogue, backend or build changed. Final test scored once at 2026-10-21 12:43 UTC after freezing the system
on validation. Earlier work and acceptance gates: [training 10-18/19](SUBFIGURE_TRAINING_20261018.md),
[Local figure regions](../architecture/LOCAL_FIGURE_REGIONS.md). Evidence:
`.artifacts/subfigure-detector-20261021/` (metrics, galleries, export parity, Core ML package); runs and
data on the GPU host in `/home/ben/science-reader-subfigures/d21/`.

## Summary

- **The earlier evaluation hid the real problem.** On a new held-out arXiv test (235 single-image figures from
  201 papers in unseen author families — the image the app actually sends), the previous best detector
  (`v13`) is fully right (single figure kept whole, or every panel cropped completely with no extra crop) on
  only **59.1% (95% CI 52.8–65.5)** of figures and shows wrong crops on 24.7%; it scored 93.6% on the older
  SCI-3000-based validation set.
- **Frozen system** — RT-DETRv2-M trained on the corpus data engine + completeness post-processor + caption
  -constrained decoding + two-view agreement — on that final test: **80.4% (75.3–85.3)** fully right,
  **8.9% (5.5–12.6) harmful** (wrong crops shown), 6.6% of single figures split, compound panels found 80.1%,
  delivered-crop precision 96.9%. Paired difference versus v13: **+21.3 points (15.4–27.5)** fully right,
  **−15.7 points (−21.2 to −10.2)** harmful. On the old SCI-3000 final test (never scored before): 91.9%
  (87.4–95.8) versus 88.1%, harmful 1.7% versus 8.5%.
- **It does not meet the acceptance gates** (≥ 95% panel recall, < 2% wrong crops). The system abstains
  (keeps the whole figure) on 14% of compound figures, and lettered groups of several plots, framed diagram
  panels and touching raster panels still fail. It is suitable as a *candidate-part provider and a crop
  checker*, not as an unsupervised cropper.
- **The completeness step is the cheapest win and fixes the owner's complaint class directly.** Growing each
  crop over the ink it cuts and attaching orphan letters/legends (pure geometry, ~31 ms) lifts the old
  detector from 59.1% to 64.7% on the test and full-ink coverage of split figures from 65% to 87%. On
  simulated model-written boxes off by up to 6% of a panel, perfect splits rise from 43% to 90%. It can check
  the AI's own boxes today, with no model download.
- **The corpus became a data engine:** exact panel labels from the drawing operations of 35,779 figure PDFs,
  8,078 caption-verified whitespace labels, 5,443 LaTeX sub-figure page composites, 7,000 synthetic compounds
  and hard negatives built from real panels, 11,748 agreement-filtered teacher pseudo-labels, and two new
  annotated evaluation sets (473 figures, 406 papers). Vector supervision alone gave most of the gain.
- A **rights-clean** model trained without the SCI-3000 images scores the same within error on both tests
  (81.7% / 90.2%), so a distributable recipe exists.
- FP32 **Core ML** export of the frozen checkpoint (132 MB) gives identical delivered crops on 20 validation
  images (edges within 0.03 px; 40 ms warm on the M1 Max); **ONNX** (132 MB) matches PyTorch to 1e-4.
- Cost: **$0** model API, no rented GPU; owner’s RTX 3090 for about 6.5 GPU-hours (electricity not priced).

## What the app needs, and how it is measured

The figure explainer shows a crop per part. A crop is only useful if it contains **every pixel of its
panel** (axes, ticks, labels, letter, own legend/colorbar), the figure is **not split when it is one
figure**, and the **number of parts** is right. AP/IoU does not measure that, so `evaluate.py` scores the
crops exactly as the app displays them (2% margin, outward rounding, as `figure-view.ts`/`FigureView.swift`):

- a crop *matches* a panel when it holds ≥ 90% of that panel's own ink and that panel is ≥ 60% of the crop's
  non-shared ink (a whole-figure crop cannot match several panels);
- a matched panel is *complete* when the displayed crop holds ≥ 99.5% of its own ink pixels (ink inside its
  annotated box and no other panel's box; overlap zones of touching panels are required of neither);
- single figures end *correct_whole* or *false_split*; compound figures end *perfect* or fail as
  *not_split*, *clipped*, *merged_panels*, *extra_crops*, *missed_panels*, *wrong_boxes*;
- **app success** = share of figures that are correct_whole or perfect. Also reported: single false-split
  rate, compound perfect rate, count correctness, panel recall, complete-panel rate, crop precision and whether
  the union of crops covers all ink when split. Intervals are 95% paper-level bootstrap (2,000 resamples).

| Set | Figures (papers) | Compound / single | Panels in compounds | Labels |
|---|---|---|---|---|
| Frozen validation (`real-v3` + 16 arXiv dev, 10-18/19) | 313 (70) | 97 / 216 | 327 | SCI-3000 upstream + earlier Codex review |
| **New arXiv validation** (this work) | 238 (205) | 176 / 62 | 525 | Claude visual review |
| **New arXiv final test** (this work; locked, not yet scored) | 235 (201) | 174 / 61 | 502 | Claude visual review, separate pass |

The new sets are single-file figure environments from papers in held-out author families: exactly the image
an arXiv HTML figure shows. Half were drawn from captions naming ≥ 2 panel letters, half from the natural
remainder (itself 49% compound); at most two figures per paper. Labels: accepted vector proposals (74 val /
68 test), regrouped vector proposals (17 / 25), whitespace-block groups (0 / 19), hand boxes tightened to ink
(104 / 78), singles (43 / 45); 2 + 2 excluded (> 12 panels or ambiguous grouping). Policy: a panel is a part
the figure's own letters/headings name; unlettered separate axes are panels; connected diagrams, tables,
single heatmaps and unlettered example grids are one figure. **These are Claude visual development labels, not
independent human review.** The test labels were made by a separate agent pass before any model saw those
images; the main pipeline has never read test predictions. Hashes: validation annotations
`c3b973bf…68`, GT `e9d4a50f…b9`; test annotations `92e419d6…ff8`, GT `f04e9cbd…f87`.

## The corpus as a data engine

All corpus work ran on the GPU host, reading `/home/ben/mathpix/data/arxiv` (never writing; the
`gradstep-acquire` service was not touched). The owner's pipeline keeps each paper's extracted source in
`build/src`; its **original figure files** are what arXiv HTML renders as the figure image, so a
figure-level dataset needs no page parsing. 17,179 of the catalogued papers are CC BY 4.0 and 233 CC0; every
paper used for training/evaluation here is one of those (`metrics-v1/data-licenses.json`).

1. **Index** (`corpus_index.py`, 4 s): 18,606 papers, 144,226 figure environments, 108,909 with exactly one
   `\includegraphics` (77,237 vector PDFs, 30,577 PNG/JPG). 13,486 single-file figures have captions naming
   ≥ 2 panel letters.
2. **Split** (`split.py`): papers joined by shared first/last author (first name + surname) or arXiv family
   into 10,059 components; whole components go to train (15,668 papers), validation (1,504) or test (1,406).
   The 56 papers used in the 10-18/19 training additions stay in training; the author component of the 4
   earlier validation papers (28 papers) is excluded from new training and new test.
3. **Vector-graphics supervision** (`vector_labels.py`, ~13 min for 77K PDFs on 26 cores). In a figure PDF
   from matplotlib/pgfplots/R, every plotting area is a clip rectangle. Distinct content-bearing clips are
   seeds (nested ones are insets; thin ones are colorbars that join a neighbour or are shared). The figure is
   rendered at 1,280 px; every PDF text segment (split at glyph gaps, so one PDF line cannot join two panels'
   tick labels) and every other ink component is assigned to the plotting area it touches or is nearest to;
   rotated y-labels go to the plot on their right; elements spanning several columns/rows (suptitles, shared
   legends, shared axis labels) become shared context. The panel box is the union of all assigned ink, so it
   is complete by construction. Ambiguity is rejected, not guessed. Of 77,237 PDFs, **35,779 are accepted**
   (14,782 single, 20,997 compound); 28,357 have no plotting areas (diagrams), 6,417 overlap, 2,821 bridge.
   Training keeps those whose count agrees with the caption letters and printed letter tokens:
   **16,849 compound + 11,770 single figures (≈5,700 papers)**; 82% are matplotlib.
4. **Caption-grouped vector labels**: when a caption names fewer parts than plotting areas and exactly one of
   rows/columns gives that count, axes are grouped (159 figures). Visual QA: ~2 in 3 correct; used at low
   weight. (The first version, which tried rows before columns, was ~50% wrong and was discarded.)
5. **Caption-verified whitespace supervision** (`xycut_labels.py`) for raster figures and diagrams: recursive
   XY-cut at four gutter widths; large leaves are panel bodies, small leaves (letters, subcaptions, tick
   labels) join a body or become shared. Accepted **only when the body count equals the caption's letter
   count**; for PDFs with a text layer each panel must also contain exactly one printed letter. Of 7,051
   lettered training figures: **1,666 accepted** (623 letter-verified); 3,871 count mismatches, 2,343 dense
   backgrounds, 493 overlaps, 362 letter-layout mismatches. Unlettered figures cutting into one body give
   **6,412 single-figure negatives**. QA: verified labels look right; ~1 in 6 unverified compound labels and
   ~1 in 10 negatives are wrong.
6. **Synthetic compounds** (`synth_compose.py`): 6,000 layouts of 2–8 real training panels (vector singles,
   vector panels cut at their complete boxes, raster/diagram figures), row-packed to a common row height,
   gutters from touching to wide, letters in seven styles and four positions, subcaptions, shared legend
   strips, suptitles and rotated shared y-labels; 1,000 hard negatives (one plot with a pasted framed inset or
   a large side legend, labelled one panel). The first layout generator left panels floating in oversized cells
   and was discarded after visual review.
7. **Teacher–student pseudo-labels** (`pseudo.py`): the r2 checkpoint labels 21,196 unlabeled training
   figures (incl. 5,340 lettered figures every labeler rejected) at two placements. Kept only when both views
   agree crop-for-crop (IoU ≥ .85), after completion, and the crop count equals the caption's letters
   (unlettered: every score ≥ .85; singles need a confident whole-figure box): **4,725 compound + 7,023 single**.
   QA: 15 of 16 sampled look right.

8. **LaTeX sub-figure page composites** (`subfig_pages.py`), aimed at the failure category above: on the
   original arXiv PDF pages of training papers, a "Figure N" caption line anchors a figure region (bounded by
   body text, running headers and the column); printed subcaptions starting with consecutive letters (a), (b), …
   define one cell each (between row neighbours, down to the subcaption). A labelling is kept only if cell
   boundaries cross no ink, every cell holds a graphic above its subcaption, nothing but captions lies below
   the last row, and the region is not a table. This yields real lettered compounds of every kind — framed
   diagrams, photo/sample grids, heatmaps, plots — with panel identity printed in the text layer:
   **5,443 figures from 2,441 papers** (2–12 panels). QA: the first version included running headers,
   paragraph tails and a table; after fixes, 14 of 16 sampled are right (two keep a page header or section
   title as shared context).

Paid vision-LLM labelling was not used: the only OpenRouter key on this Mac is the app's production chat key,
which the project explicitly keeps out of research runs. Spend **$0**.

## Crop policy on top of the detector (`policy.py`)

1. Panel boxes above a threshold; suppression of duplicates/nested boxes; a near-whole-figure box means
   "one figure".
2. **Completion**: dilated ink components that a crop cuts are pulled in (only labels/letters/ticks or the
   crop's own clipped body, never more than 8% of another crop's box); ink owned by no crop is attached to the
   nearest crop(s), equidistant shared context to all of them, unless that would swallow another panel.
   Median 31 ms (p90 65 ms) per figure on the host CPU.
3. **Two-view agreement**: the detector also runs at a 0.75 zoom placement; if the two views disagree on the
   crop count or geometry (IoU < .7), keep the whole figure.
4. **Caption count/grouping** (on-device: the caption is already sent with the figure): if the caption names
   L ≥ 2 letters, use the highest threshold yielding exactly L crops; if the detector found more plotting areas,
   merge them by rows or columns when exactly one of those gives L; otherwise fall back to step 1–3 output.
5. **Caption-constrained decoding** (replaces 4 when selected): from every panel candidate scoring ≥ .15,
   greedily choose exactly L mutually non-overlapping boxes by score, require them to cover ≥ 70% of the
   figure's ink, complete them, and require the 0.75-zoom view to agree; otherwise use steps 1–3.

## Results on validation (all selection happened here)

App success with 95% CI; other columns are point estimates. All new rows use completion.

| System (arXiv validation, 238 figures) | App success | Single false split | Compound perfect | Count right | Panel recall | Complete panels | Crop precision | Full coverage |
|---|---|---|---|---|---|---|---|---|
| v13 (previous best), raw boxes | **50.8** (44–57) | 21.0 | 40.9 (33–48) | 61.4 | 66.7 | 56.0 | 62.2 | 56.6 |
| v13 + completion | **57.1** (50–63) | 21.0 | 49.4 (42–56) | 61.4 | 67.4 | 60.6 | 62.9 | 82.1 |
| r1 vector data only | **69.3** (63–75) | 17.7 | 64.8 (58–72) | 73.9 | 77.7 | 73.3 | 78.6 | 86.5 |
| r1 + caption/agreement | **73.1** (67–79) | 4.8 | 65.3 (58–72) | 75.0 | 73.5 | 69.9 | 86.7 | 87.7 |
| r2 all sources | **71.0** (65–77) | 9.7 | 64.2 (57–71) | 73.9 | 78.5 | 73.5 | 80.3 | 87.2 |
| **r2 + caption/agreement** | **73.5** (68–79) | 4.8 | 65.9 (59–72) | 77.3 | 75.0 | 70.1 | 84.9 | 85.5 |
| r3 rights-clean (no SCI-3000) + caption/agreement | **71.0** (65–77) | 4.8 | 62.5 (55–70) | 72.7 | 72.4 | 67.6 | 87.2 | 86.7 |
| r5 + pseudo-labels + caption/agreement (t .6) | **73.1** (67–78) | 3.2 | 64.8 (57–71) | 74.4 | 74.5 | 69.7 | 85.6 | 88.6 |

| System (frozen validation, 313 figures) | App success | Single false split | Compound perfect | Count right | Panel recall | Complete panels | Crop precision | Full coverage |
|---|---|---|---|---|---|---|---|---|
| v13 raw | **93.6** (90–96) | 1.9 | 83.5 (75–91) | 89.7 | 92.4 | 89.6 | 99.3 | 87.9 |
| v13 + completion | **94.9** (92–97) | 1.9 | 87.6 (79–94) | 89.7 | 92.4 | 91.4 | 99.3 | 97.8 |
| r1 + agreement | **96.2** (94–98) | 0.0 | 87.6 (81–94) | 92.8 | 85.6 | 81.7 | 96.9 | 100.0 |
| r2 + agreement | **95.5** (93–98) | 1.4 | 88.7 (82–95) | 91.8 | 85.6 | 84.1 | 97.6 | 98.9 |
| r3 rights-clean + agreement | **94.6** (92–97) | 0.5 | 83.5 (76–90) | 86.6 | 75.8 | 74.9 | 96.1 | 100.0 |
| r5 + agreement | **96.5** (94–99) | 0.0 | 88.7 (82–95) | 90.7 | 80.7 | 80.1 | 97.4 | 100.0 |

(The frozen set has no captions, so its caption step is inactive.) Differences among r1/r2/r5 with the full
policy are within the intervals.

**Caption-constrained decoding** (policy step 5, two-view agreement, threshold .5 / .6 for unlettered
figures) improves every model on arXiv validation without hurting the frozen set:

| Model | arXiv app success t .5 / .6 | arXiv harmful rate t .6 | Frozen app success t .5 / .6 |
|---|---|---|---|
| r1 vector | 74.4 / 72.7 | 14.7 | 96.2 / 95.8 |
| **r2 all sources** | **75.2 / 75.2** | 15.5 | 95.5 / 95.5 |
| r3 rights-clean | 72.3 / 72.3 | 15.1 | 94.2 / 94.6 |
| r5 + pseudo-labels | 72.7 / 73.5 | 16.0 | 96.5 / 96.5 |

*Harmful rate* = share of figures where the app would show wrong crops (false split, clipped, extra, merged,
missed or wrong boxes); keeping a compound figure whole is a safe miss, because the reader still sees
everything. v13 raw: 36.1% harmful. Of the 16 clipped figures left with r2 + caption/agreement, half lose
≤ 2% of one panel's ink and the worst loses 9% (v13 raw: 28 clipped, worst 10%).

**Selection rule (declared 05:20 PDT, before the last R50-M epochs finished):** the frozen system is the
checkpoint with the highest mean app success over the two validation sets under the caption-decoding +
agreement policy at threshold .5 or .6, ties broken by lower arXiv harmful rate. Interim: R50-M (r4) epoch 4
gives 75.6% arXiv / 96.2% frozen (harmful 13.4%), r2 75.2% / 95.5%. The LaTeX sub-figure fine-tune (r6, from
r5 e07, 6 epochs) did **not** help: 72.3% arXiv / 94.6% frozen at its best epoch — the page composites are
real compounds but differ from the single-image figures the app sends (wider gutters, paper fonts, subcaptions
in body type), and the fine-tune slightly over-split singles (9.7% false splits).

**Frozen system (12:41 UTC, before any final-test prediction):** r4-r50m-pseudo EMA epoch 4 (RT-DETRv2-M,
R50; SHA `f7736570…a167`) + completion + caption-constrained decoding + two-view agreement, threshold .5
(system file SHA `17520d8b…ebe3`, policy.py `3fe5b49b…697f`). Its validation results: arXiv 75.6% (95% CI
69.8–81.0), harmful 13.4%, single false splits 4.8%, compound perfect 68.8%, crop precision 87.9%;
frozen 96.2% (93.8–98.2), harmful 1.6%. Declared test comparators: the rights-clean r3 e05 with the same
policy, and v13 raw / v13 + completion.

**Ensembles did not help.** Weighted box fusion of r1+r2+r5 (or r2+r5) reaches 73.5% / 72.7% on arXiv
validation with the full policy — no better than r2 alone — and 97.1% on frozen validation. The models make
correlated errors; the limit is the training data for non-plot compounds, not variance.

**Where the r2 system failed on validation** (r2 + caption-count policy, arXiv validation): perfect 116/176 compounds,
not split 24, clipped 16, extra crops 10, merged 6, wrong boxes 3, missed 1; false splits 3/62 singles.
By label type: vector plot figures 93%, regrouped plots 71%, singles 93%, **hand-boxed non-plot compounds
52%** (v13: 32%). By file: vector PDF 74%, raster 70%. By panel count: 2 → 75%, 3–4 → 62%, 5+ → 38%.
Galleries (green = ground truth, blue = shared context, red = delivered crop): `galleries/r2e07-*.jpg`;
the same categories for v13 in `galleries/v13raw-*.jpg`.

- *Not split*: framed lettered diagram panels, lettered rows of image strips, image grids with letters.
- *Extra crops*: mostly granularity — the caption names a lettered group of 3 plots and the detector crops
  each plot (training data labels unlettered axes individually). Caption grouping fixes some; ambiguous
  row-vs-column layouts are deliberately not guessed.
- *Clipped*: touching panels with overlapping labels; long titles running over the neighbour.

## Final test (scored once, 12:43 UTC, after freezing)

`final_test.sh` refused to run if results existed, hashed the frozen checkpoint, system, policy code and both
GT files (`final-test/eval/final/frozen-inputs.sha256`), then predicted and scored. No threshold, policy or
model was changed afterwards. Intervals: 5,000 paper-level bootstrap resamples.

| New arXiv final test (235 figures, 201 papers; 174 compound / 61 single) | Fully right | Harmful | Single false split | Compound perfect | Count right | Panel recall | Complete panels | Crop precision | Full coverage | Kept whole (compound) |
|---|---|---|---|---|---|---|---|---|---|---|
| v13 (previous best), raw | **59.1** (52.8–65.5) | 24.7 (19.2–30.3) | 16.4 | 50.6 | 65.5 | 72.5 | 64.1 | 77.6 | 65.4 | 21.8 |
| v13 + completion | **64.7** (58.5–70.7) | 19.1 (14.0–24.2) | 16.4 | 58.0 | 65.5 | 72.5 | 69.3 | 77.6 | 86.8 | 21.8 |
| **Frozen system (R50-M + policy)** | **80.4** (75.3–85.3) | **8.9** (5.5–12.6) | 6.6 | 75.9 (69.5–82.1) | 82.2 | 80.1 | 77.9 | 96.9 | 91.9 | 14.4 |
| Rights-clean comparator (r3 R18 + same policy) | **81.7** (76.6–86.6) | 11.9 (8.0–16.0) | 4.9 | 77.0 | 84.5 | 86.9 | 83.9 | 91.8 | 90.6 | 8.6 |

Paired paper-level bootstrap, frozen system minus v13 raw: fully right **+21.3 points (15.4 to 27.5)**,
harmful **−15.7 points (−21.2 to −10.2)**. Outcomes of the frozen system: 132 perfect + 57 correct whole;
25 compounds kept whole; 8 clipped, 4 false splits, 3 extra-crop, 3 merged, 3 wrong-box figures.
By file: raster 83.9% (56), vector PDF 79.3% (179). By panels: single 93.4%, 2 → 83.7%, 3–4 → 75.0%,
5+ → 25.0% (12). By label type: vector-proposal figures 92.6%, hand-boxed non-plot compounds 67.9%, regrouped
plot groups 64.0%. Stratum: caption-lettered 72.9%, natural remainder 88.0%. The test is a few points easier
than validation (75.6%); both are inside each other's intervals.

| Old SCI-3000 final test (235 figures, 60 papers; never scored before) | Fully right | Harmful | Single false split | Compound perfect | Panel recall | Crop precision |
|---|---|---|---|---|---|---|
| v13 raw | 88.1 (82.6–93.1) | 8.5 | 1.8 | 78.9 | 84.6 | 96.9 |
| v13 + completion | 89.4 (84.1–94.1) | 7.2 | 1.8 | 81.3 | 83.5 | 95.7 |
| **Frozen system** | **91.9** (87.4–95.8) | **1.7** | 0.0 | 84.6 | 69.0 | 98.7 |
| Rights-clean comparator | 90.2 (85.1–94.6) | 3.0 | 2.7 | 83.7 | 66.5 | 98.7 |

Paired: +3.8 points (0.7 to 7.1) fully right, −6.8 points (−11.2 to −3.0) harmful. On this biomedical-heavy
set the new system abstains more (panel recall 69% vs 85%) — it trades recall for far fewer wrong crops, the
right trade for an app that otherwise shows the whole figure.

**Acceptance gates: not met.** Panel recall 80% (gate 95%) and wrong-crop rate 8.9% of figures / crop precision
96.9% (gate < 2% extra crops) on the app's domain. Galleries of every outcome on the test:
`galleries/final-test-*.jpg` (viewed only after scoring). Remaining failure modes, same as validation: lettered
parts that are groups of several plots (the detector crops each plot, or abstains), framed diagram panels
joined by arrows, touching raster panels with overlapping labels, and 5+ panel grids.

FDE-Gym regression figures (the owner's crop-complaint paper; development set, not test): the two-panel
overview and the (a)/(b) scatter pair are split into complete crops; the workflow diagram, worked-example
panel, stacked bars, heatmap and grouped bar chart are kept whole (`galleries/fde-gym-frozen-system.jpg`).
The earlier detectors put an extra crop inside the scatter plot and cut the heatmap's labels.

## Runs

All runs: official Apache-2.0 RT-DETRv2 (revision `df2a96c8`), COCO initialisation, classes panel/shared,
640 letterbox, AdamW 2e-4 (backbone ×0.1, frozen one epoch), cosine, EMA, bf16 autocast, 16,000 weighted
draws/epoch, content-preserving zoom/position jitter, resolution and JPEG degradation, one GPU at a time
where possible. Checkpoint selection by mean app success over both validation sets.

| Run | Data | Epochs (best) | Time / peak VRAM | Notes |
|---|---|---|---|---|
| r1-r18-vector | vector 28.6K + old 1.8K | 10 (7) | 33 min / 6.1 GB | EMA e07 SHA `583c11b0…` |
| r2-r18-all | + whitespace 8.1K + synthetic 7K | 12 (7) | 74 min / 6.1 GB | EMA e07 SHA `235392cd…`; teacher for r5 |
| r3-r18-clean | r2 without SCI-3000 (rights-clean) | 11 (5) | 76 min / 6.1 GB | ran concurrently with r2 |
| r5-r18-pseudo | r2 + grouped 159 + pseudo 11.7K | 12 (7) | 49 min / 6.1 GB | |
| **r4-r50m-pseudo** | r5 data, RT-DETRv2-M (R50, COCO EMA init) | 10 (4) | 88 min (partly shared GPU) / 14.1 GB | **frozen system**, EMA e04 SHA `f7736570…a167` |
| r6-r18-subfig-ft | r5 data + 5,443 LaTeX sub-figure composites, fine-tuned from r5 e07, LR 1e-4 | 6 (3) | ≈45 min (shared GPU) / 6.1 GB | no gain; rejected |

Exact configs, source/data hashes, per-epoch metrics, predictions and resource samples are in each
`runs/<id>/` on the GPU host (`d21/`), with copied summaries under
`.artifacts/subfigure-detector-20261021/metrics-v1/`.

## Export

`export_coreml.py` (Mac, coremltools 9.0, Torch 2.8, FP32 ML Program, macOS 14 target) converts the frozen
R50-M checkpoint and replays 20 arXiv validation images through PyTorch and Core ML, including the complete
crop policy. **Delivered crops are identical on all 20** (same count, edges within 0.03 px). Raw outputs match
to < 1e-4 on 19 images; on one image a low-probability query is matched to a different near-tied query
(box 0.70 normalized, probability 0.006), the DETR top-k reordering already seen in the 10-18 export. Package
132.3 MB; trace 4.3 s, conversion 7.6 s; first prediction 0.89 s, warm median 40 ms. An earlier R18 checkpoint
exports to 80.3 MB with max box error 0.00027. **ONNX** (opset 17, `export_onnx.py`): frozen R50-M 132.4 MB,
max box error 0.00009 and probability error 0.00004 against PyTorch in onnxruntime 1.31 on 30 validation
images (202 ms median, busy host CPU); R18 r2 80.2 MB, max box error 0.00061. Package and parity reports:
`.artifacts/subfigure-detector-20261021/export/`. App memory, cancellation, iPhone and browser timing remain
unmeasured; physical-device work stays paused.

## Integration proposal (not implemented)

1. **Completeness check on every displayed crop, now** — pure geometry on the exact image the request
   carried, in Swift and TypeScript: grow each AI box over the ink it cuts (never into another part), attach
   unowned ink to the nearest part, then the existing 2% margin; if ink coverage is still below 100%, show the
   whole figure for that card. No model download, no new spend.
2. **Detector parts given to the model by name.** On figure open (local, cancellable), run the detector per
   displayed asset, apply the policy above, and send `<figure_parts>P1 [x,y,w,h] …` with the request; the
   walkthrough/`show_figure_parts` tools gain an optional `parts: ["P1","P2"]` per section, which the device
   maps to its own boxes. Coordinates then come from the device; the model keeps freedom to group parts or
   use none. When the detector abstains, today's behaviour plus step 1 applies. Server change: prompt text,
   schema field, ID validation.
3. For arXiv figures whose panels are separate images the device already knows each panel's rectangle in the
   stacked image; run per asset and never cross asset boundaries.
4. Cache accepted parts as an encrypted sidecar keyed by image hash + model hash + preprocessing + policy
   revision (as in LOCAL_FIGURE_REGIONS).
5. Mac first (FP32 Core ML, on-demand pinned download). iPhone/iPad after physical-device measurement.
   Browser via onnxruntime-web needs a smaller (INT8/FP16) variant with its own parity test.

## Rights and data handling

Training/evaluation figures come only from the owner's corpus papers marked CC BY 4.0 (≈ 99%) or CC0
(`metrics-v1/data-licenses.json`), project-generated plots/composites, and (r1, r2, r4, r5) the earlier
SCI-3000-derived set whose redistribution rights are unresolved. **r3 excludes SCI-3000** and matches the
frozen system within error on both tests; a distributable model should be retrained with that clean recipe on
the R50-M backbone and carry CC BY attribution for the arXiv sources. PDFs and sources were read on the GPU
host under this task's explicit authorization (earlier runs processed PDFs only on the Mac); nothing under
`/home/ben/mathpix` was written and its service was not touched. No paper content left the owner's machines.
Annotations are Claude visual development labels, not independent human review.

## Cost

$0 model/API spend (no vision LLM was used: the only OpenRouter key on the Mac is the app's production chat
key). No rented GPU or new commitment. GPU: about 6.5 hours of RTX 3090 time across 6 training runs plus
evaluation (peak 14.1 GB for R50-M; 85 °C stop guard, max sampled 74 °C, 379 W); CPU labelling ≈ 1 hour on 20–28 cores.
Electricity is not priced. The $100/month service budget is unchanged.

## What did not work

- The first synthetic layout generator (panels floating in cells) and the first caption-grouping rule
  (rows before columns, ~50% wrong) — discarded after visual review.
- LaTeX sub-figure page composites as a fine-tune: no gain (72.3% vs 73.5% validation).
- Pseudo-labels: no measurable gain over r2 at R18 (+/- 1 point); kept for the R50-M run.
- Weighted-box-fusion ensembles: no gain; errors are correlated.
- The rights-clean run is not worse; SCI-3000 adds nothing measurable on arXiv figures.

## Next

1. Ship the **completeness check** for AI-written crops (integration step 1) — model-free, directly targets
   the TestFlight complaints.
2. Retrain the R50-M recipe **without SCI-3000** for a distributable checkpoint; re-export and re-run parity.
3. Fix the dominant failure — lettered groups of several plots — with labels at the caption's granularity:
   group vector axes by printed letter positions (letters sit at group corners), and teach a "part" vs "axes"
   distinction; add more framed-diagram compounds from single-image sources.
4. A larger, independently (human) reviewed test before any automatic-cropping release; measure on the Mac app
   and, once resumed, the phone.

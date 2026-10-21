# Subfigure detector from the 17K-paper corpus — 2026-10-21

Status: **research, not qualified, not released.** No application code, model catalogue, backend or build
changed. This report is updated in increments; the final-test result is added only after the system is
frozen on validation. Earlier work and acceptance gates: [training 10-18/19](SUBFIGURE_TRAINING_20261018.md),
[Local figure regions](../architecture/LOCAL_FIGURE_REGIONS.md).

## Summary (first complete version, 04:30 PDT)

- **The old measurement hid the real problem.** On the new arXiv validation set — single-file figures from
  held-out author families, i.e. the image the app actually sends — the previous best detector (`v13`) gives a
  fully correct result (single kept whole, or every panel cropped completely with no extra crop) for only
  **50.8% of figures (95% CI 44–57)**, versus 93.6% on the older frozen validation set. 21% of single figures
  are split, 31 of 176 compound figures are not split at all, and 28 are clipped.
- **A deterministic completeness step fixes clipped crops cheaply.** Growing each crop over the ink it cuts
  (never into another crop) and attaching orphan ink (letters, shared legends) raises the same old detector
  to 57.1% and full-ink coverage of split figures from 57% to 82%, with no retraining. On simulated
  model-written boxes off by up to 6% of a panel, it raises perfect compound splits from 43% to 90%.
  This step can also check the AI's own boxes today.
- **The corpus became a data engine:** 35,779 figure PDFs labelled exactly from their drawing operations
  (28,619 used for training), 8,078 caption-verified whitespace labels, 7,000 synthetic compounds/hard
  negatives built from real panels, and 11,748 teacher pseudo-labels kept only when two views and the caption
  agree. 2 new human-style evaluation sets were annotated (473 figures, 406 papers).
- **Best system so far** (RT-DETRv2-S trained on that data + completion + caption-count/grouping +
  two-view agreement): **73.5% (68–79) on new arXiv validation**, 95.5% on frozen validation; single false
  splits 4.8%; crop precision 85%. That is +22.7 points over the previous detector on the app's domain, but
  **it does not meet the acceptance gates** (95% panel recall, <2% wrong crops): panel recall is ~75%.
- Remaining failures are concentrated in **non-plot compounds** (framed diagrams, lettered image grids,
  touching raster plots): 52% correct, versus 93% for vector plot figures. A larger backbone run, an
  ensemble and a LaTeX-subfigure page-composite data source are in progress.
- FP32 Core ML export of a trained two-class checkpoint matches PyTorch on 20 validation images (max box error
  0.00027, identical delivered crops). Cost: **$0 model API**, owner's GPU (electricity not priced).

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

## Results on validation (selection only; final test not yet scored)

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

(The frozen set has no captions, so its caption step is inactive.) Selection between r2, r5 and the
running r4/r6 is still open; differences among r1/r2/r5 with the full policy are within the intervals.

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

**Ensembles did not help.** Weighted box fusion of r1+r2+r5 (or r2+r5) reaches 73.5% / 72.7% on arXiv
validation with the full policy — no better than r2 alone — and 97.1% on frozen validation. The models make
correlated errors; the limit is the training data for non-plot compounds, not variance.

**Where the best system still fails** (r2 + policy, arXiv validation): perfect 116/176 compounds,
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
| r4-r50m-pseudo | r5 data, RT-DETRv2-M (R50) | running | | |
| r6-r18-subfig-ft | r5 data + 5,443 LaTeX sub-figure composites, fine-tuned from r5 e07, LR 1e-4 | 6 (3) | ≈45 min (shared GPU) / 6.1 GB | no gain; rejected |

Exact configs, source/data hashes, per-epoch metrics, predictions and resource samples are in each
`runs/<id>/` on the GPU host (`d21/`), with copied summaries under
`.artifacts/subfigure-detector-20261021/metrics-v1/`.

## Export

`export_coreml.py` converts a two-class checkpoint (here r1's best) to an FP32 ML Program on this Mac
(coremltools 9.0, Torch 2.8) and replays 20 arXiv validation images: max matched box error 0.00027,
probability error 0.00055, **identical delivered crops (count and edges within 0.0002 px)**. Package
80.3 MB; first prediction 1.17 s, warm median 85 ms on a busy M1 Max. ONNX (opset 17,
`export_onnx.py`) of r2's EMA e07 (SHA `235392cd…`) is 80.2 MB and matches PyTorch in onnxruntime 1.31 on 30
validation images (max box error 0.00061, probability error 0.00004; 120 ms median on the busy host CPU). The selected final checkpoint will be re-exported; physical-device memory/thermals
remain unmeasured (paused).

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

## Rights

Training uses the CC BY 4.0 / CC0 arXiv corpus, project-generated plots, and (r1/r2/r5) the earlier
SCI-3000-derived set whose redistribution rights are unresolved. **r3 excludes SCI-3000** and is 2.5 points
lower on arXiv validation (within the interval); a distributable model should come from the clean recipe,
with CC BY attribution for the arXiv sources.

## Next

Finish r4 (R50-M), evaluate ensembles, add the LaTeX-subfigure page-composite source (real framed
diagrams/photo panels with subcaptions, positions from PDF placements), freeze the system on validation,
score the final test once, export the selected checkpoint and update this report.

# Subfigure detector training — 2026-10-18

Status: research training on the owner's RTX 3090, not an accepted or distributed model. No application source,
model catalogue or release changed. Architecture and acceptance gates: [Local figure regions](../architecture/LOCAL_FIGURE_REGIONS.md).

## What the dataset is

The source is [TobiPoni/CompoundFigureSeparation](https://huggingface.co/datasets/TobiPoni/CompoundFigureSeparation),
pinned to `6439d75905c5486a17ff9b343239faba5a9c7da2`. Its real figures come from
[SCI-3000](https://zenodo.org/records/8357124), covering computer science, physics, chemistry, medicine and
technology. The source Label Studio export provides rectangle annotations and explicit panel-to-shared-context
relations. Its metadata identifies manual annotations; this is not independent verification by us.

The selected real corpus contains **1,846 figures from 398 papers**: 701 admitted records from the annotated
compound collection, plus 1,145 source-curated single figures. Of these, 691 have multiple retained leaf panels;
the other 1,155 have one. Single figures teach the model to avoid unnecessary splitting. Enclosing category boxes
are kept in the provenance but excluded as extra panels when explicit child panels exist. The importer retains
source annotation IDs, classes, relations, revisions, removed parents and rejection reasons.

| Real split | Figures | Papers | Multi-panel figures | Panel boxes | Explicit context links |
|---|---:|---:|---:|---:|---:|
| Train | 1,314 | 272 | 479 | 2,422 | 976 |
| Validation | 297 | 66 | 89 | 505 | 75 |
| Final test, not yet scored | 235 | 60 | 123 | 560 | 175 |

Training has 59 shared legends, 67 titles, 92 shared X-axis regions and 89 shared Y-axis regions. Validation has
only **2 legends, 28 titles, 2 X-axis regions and 1 Y-axis region**. This scarcity limits any broad claim about
shared-context performance. Many ordinary axes/legends are already inside the panel rectangles and are not
separately annotated. Panel-box area retention cannot prove that every critical character is preserved.

The frozen `real-v3` split groups papers, matching first/last author identities, exact-image duplicates and
near-duplicate image families. Prior pilot training/validation exposure stays out of the final test. This is not
a guarantee that every coauthor, laboratory or visual template is disjoint. All source image dimensions and
SHA-256 hashes are checked before training; training, validation and test have no intersecting recorded paper,
family or exact-image identity. No final-test prediction or threshold selection has been performed.

Twenty-four source-curated single examples and selected annotated validation cases were visually inspected,
including microscopy grids, shared color bars, Bode plots and stacked plots. Most annotations have not received
independent local review. Upstream's 2,500 synthetic charts are excluded: their generator/provenance was not
established. A further **384 project-generated Matplotlib plots** are admitted to training only, with exact
renderer-derived bounds. The augmented dataset has **1,698 training figures** and retains the real validation/test
files byte-for-byte. It adds 1,535 panel boxes, 376 shared legends, 384 titles and 189 shared labels on each axis.
Generated labels are programmatic, explicitly identified and not independent human review. Visual inspection
rejected an initial layout generator with overlapping legends/axis labels; the admitted revision rejects clipped
annotations and unintended panel/context overlap (139 rejected candidates). Eight generated examples were
visually reviewed after correction. The discarded/partial generations were never used for training.

The next generated set (`shared-v8`) replaces those 384 plots with examples of shared row/column headings,
shared color bars and explicitly declared legends inside panels. It contains 1,543 generated panels, 796 titles,
382 legends and 192 shared labels on each axis; 125 unintended/clipped layouts were rejected. These layouts
address observed validation failures, so they are development augmentation, not new independent evidence.

`composites-v10` adds another **384 composites assembled only from real training single figures**. It preserves
each complete source image, adds panel letters above/below/in wider margins, and records the source paper,
image hash, original dimensions and paste transform. Labels cover the complete image plus its letter. The
result has **2,082 training images: 1,314 real, 384 rendered plots and 384 real-image composites**. Validation
and final-test files remain byte-identical to `real-v3`. Eight composites were visually reviewed; they are
programmatic augmentations, not 384 additional real papers or independently annotated examples. The underlying
image-rights limitations remain unchanged. The earlier smoke generation is not used in training.

## Source rights and workspace

The annotation repository declares MIT. SCI-3000's Zenodo metadata declares CC BY 4.0, whereas its actual archive
LICENSE says CC BY-SA 4.0. Preserve this discrepancy. Public DOAJ/Crossref checks found permissive CC BY/BY-SA/CC0
license URLs for 192 of the 398 papers; 206 remain unresolved. This is provenance evidence, not a blanket
distribution clearance. **Current weights are research-only.** No MedICaT images or AGPL figpanel weights were
used for this fine-tuning.

Only public figure images, annotations and publication/license metadata enter the isolated training workspace.
No PDFs, private reader library, production credentials, NAS data or app account content enter that workspace.
The later read-only use of an existing, separate PDF research project is documented below; its PDFs are parsed
only after copying a bounded sample to the Mac.
Bulk data/checkpoints stay under `/home/ben/science-reader-subfigures` on `ben@192.168.1.32`. The earlier source
checkout and unrelated processes are unchanged. The isolated venv and complete dependency lock are in `env/`
and `runs/environment.lock.txt`; no GPU driver or global Python package was changed.

## Training recipe and measured results

Official Apache-2.0 RT-DETRv2-S/R18, upstream revision `df2a96c8c3a098567a1149bf0248da6efe6d495d`, starts from
the published COCO checkpoint with SHA-256 `2ace52184b620204004509b72752ac7bfe64aadaf7fc1d076b18df8ab5a5c77e`.
The class heads become panel, shared legend, shared title, shared X axis and shared Y axis. The pretrained
backbone initially stays frozen, then the last stage or whole backbone is fine-tuned at a smaller learning rate.
Model predictions are matched one-to-one to reference rectangles; classification, box-coordinate and overlap
losses update the weights. AdamW, gradient clipping, EMA checkpoints and bounded early stopping are recorded.

Images preserve their aspect ratio within a white 640-square input, using RGB bilinear resize and the exact
rounded X/Y scales. Contrast/grayscale variation never mirrors text or removes figure content. Training is
deterministic-seeded, with source/config/data/checkpoint hashes and resumable optimizer/RNG state retained per run.
Later runs record GPU temperature/power/memory and stop at 85 C. No model API participates in the training loop.

| Run | Training set | Validation finding | Time / peak allocated GPU memory |
|---|---|---|---|
| `baseline-real-v1` | 90 real figures | Tiny pilot: 18/18 panels found, 3 extra crops at threshold .6; inadequate precision | 73.7 s / 3.11 GB |
| `real-v2-laststage` | 488 real figures | 89 compound figures: 279/297 panels found, 12 false crops at .7; recall 93.94%, precision 95.88% | 234.4 s / 3.11 GB |
| `real-v3-full` | 1,314 real figures, including singles | Full-backbone tuning reduced compound-panel recall; rejected as an improvement | 386.3 s / 4.95 GB |
| `real-v4-baseline` | 1,314 real; compound sampling weight 4; last stage | Best compound mean AP50/AP75 .9510, below the earlier .9696 | 480.9 s / 3.11 GB |
| `real-v5-containment` | Same real data, with inward-edge loss weight 2 | Mean retained panel area improved, but compound recall fell; not accepted | 265.9 s / 3.11 GB |
| `plots-v6-baseline` | 1,314 real + 384 generated | Best compound mean AP50/AP75 .9530; adding generated plots alone did not improve real validation | 334.2 s / 3.11 GB |
| `plots-v7-fresh-jitter` | Same 1,698 figures, fresh COCO start and spatial variation | Compound: 284/297 found, 8 extra at .6 (95.62% recall, 97.26% precision); all figures: 482/505 found, 55 extra (95.45% / 89.76%) | 613.5 s / 3.11 GB |
| `shared-v8-head` | 1,314 real + 384 shared-layout plots; tune v7 with backbone frozen | Best compound mean AP50/AP75 .9650, below v7 .9747; no improvement accepted | 321.5 s / 2.98 GB |
| `composites-v9-fresh` | 2,082 images from `composites-v10`, fresh COCO start | Compound: 272/297 found, 13 false crops at .6 (91.58% recall, 95.44% precision); no improvement | 570.4 s / 3.11 GB |
| `real-v10-fresh-balanced` | 1,314 real, natural sampling distribution, fresh COCO; select on all figures | At .7: all 475/505 found, 31 false (94.06% / 93.87%); compound 271/297, 11 false (91.25% / 96.10%). Lower recall; not accepted | 308.3 s / 3.11 GB |
| `mathpix-v11-fresh` | 1,314 real + 384 generated + 30 new arXiv figures, explicit source weighting | At .6, original cohort 460 TP / 111 FP / 45 FN; new cohort 29 / 8 / 9. Regression in both cohorts; rejected | 430.0 s / 3.11 GB |
| `mathpix-v12-gentle` | Same data, start from v7, backbone frozen, LR .00002 | At .6, original cohort 478 TP / 49 FP / 27 FN; new cohort 31 / 6 / 7. Slightly fewer old false crops but lower recall; not accepted | 281.4 s / 2.98 GB |

All detection counts above require IoU at least .75. An oversized whole-figure box cannot match multiple panels;
duplicates count as false crops. AP and point-threshold precision/recall are distinct. Validation is used for
checkpoint/threshold decisions, so these are development measurements, not final-test generalization estimates.
The best second run's mean AP50/AP75 is .9696 on the 89 compound images, but **that does not mean 96.96% of crops
are correct or complete**. At .7 only 226/279 matched panels retained at least 99% of their annotated area after
the 2% context margin. Visual review confirmed omitted panel-letter footers despite high prediction confidence.

The expanded real set improved single-figure behavior but did not improve compound detection. Follow-up runs
separate three hypotheses: oversampling compound figures with only the final backbone stage trainable; an
additional inward-edge penalty against clipped margins; and generated examples of shared context. Existing
L1/overlap losses remain active so the extra containment penalty cannot simply reward arbitrarily large boxes.
The completed comparisons above do not meet the quality gate. The composite and natural-sampling runs change
more than one training factor, so their differences are not an isolated causal estimate for a single parameter.

A diagnostic on **128 sampled training images** at epoch 8 of `plots-v6-baseline` found AP50 1.0 on all five
generated classes and the sampled real panel/title/legend classes (real X axis .9327; no Y-axis target in that
sample). In contrast, real validation shared-legend/X/Y AP remained zero at epoch 5. This is evidence of
overfitting/domain mismatch, not failure to execute the training loss. Generated global titles/outside legends
do not adequately represent the validation set's shared column headings, internal legends and shared color bars.
A fresh-start run from the pinned COCO weights adds content-preserving training scale/position variation; no
image pixels, text or labels are cropped out. It improves compound detection to the v7 result above, but shared
context remains weak and single-figure false splits remain frequent. Its 97.26% precision is specifically the
compound subset, not the full validation population. The scoring tools now explicitly report both populations;
threshold selection and detection gates must account for both. Earlier frozen run scripts/results are retained.

Six single-figure failure cases were visually reviewed. The detector splits chemical reaction mechanisms,
separates a pie chart from its legend, divides a connected physics diagram, and invents smaller regions in a
sequence alignment. These are actual model errors, not a reason to remove single-figure negatives or silently
change the ground truth. The newly added composites teach complete labelled image boundaries. They do not by
themselves demonstrate that these errors are fixed.

Validation-only duplicate suppression and two-checkpoint ensemble ablations also fail the detection target.
The best tested union ensemble reaches 287/297 compound panels with 7 false crops (96.63% / 97.62%), still short
of the false-crop target before considering single-figure negatives and required context. It is not selected
for distribution. Checkpoint selection by mean AP50/AP75 is only a development objective, not a qualification gate.

A separate diagnostic (`compound_classifier.py`) trains a small single/compound head on pooled features from
the frozen v7 detector. It uses only the 1,314 real training figures, with content-preserving augmented views;
validation selects the head. This tests global figure coherence without retraining the answering LLM. It is
complete in 22.39 s. Its selected head has validation ROC-AUC **.98936** (epoch 7). Classification alone does not
qualify a crop policy. At a conservative compound threshold .02 and panel threshold .65, the combined policy
retains 174 figures whole and rejects no true compound figure: all-figure recall/precision **95.45% / 92.51%**
(482 TP, 39 FP, 23 FN); compound **95.29% / 97.59%** (283 TP, 7 FP, 14 FN). It still misses/clips 24 required
context links. A stricter gate improves precision but misses genuine compounds. No tested policy qualifies.
`classifier_policy.py` explicitly counts a rejected compound as missed panels, even when one dominant panel
overlaps the whole figure. It verifies classifier/detector hashes and image identity before combining outputs.

## Existing PDF-saving service and new arXiv figures — October 19 UTC

The owner's `mathpix` folder is **`/home/ben/mathpix` on `192.168.1.32`**. This is the separate local Mathpix-replacement
research project, not Mathpix API output. Its `gradstep-acquire.service` is active, with the acquisition loop idle
and zero backlog at inspection. `src/gradstep/data/acquire.py` writes each paper's `arxiv.pdf`, official HTML,
abstract metadata and source archive beneath `data/arxiv/<revision>/`. We only read its code/manifests/status;
we did not invoke its pipeline, edit files, inspect secrets, change the service or request new downloads.

At **2026-10-19 00:24:01 UTC**, a one-directory-level inventory found:

| Existing collection | Top-level PDF files | PDF bytes |
|---|---:|---:|
| `data/arxiv` | 17,372 | 81,127,515,050 |
| `data/pmc` | 525 | 2,575,247,356 |

These are file counts, not deduplicated unique papers. `data/arxiv/papers.jsonl` has 17,412 records: 17,179 marked
CC BY 4.0 and 233 CC0. Its main categories are ML (6,090), computer vision (3,917), AI (3,802) and language (3,593).
The service and inventory evidence is `.artifacts/subfigure-training/mathpix-source/service-inventory.json`.
The copied catalog SHA-256 is `6d2f4a7ef8bab0b1e6fb8d49f5f2eb21aa7ad4b39a15750953209e339a3232c5`.

`mathpix_sample.py` selected **12 papers / 69 MiB** with original PDF, HTML/abstract, recompiled `build/plain.pdf`,
silver `build/labels.json`, layout check and original/recompiled comparison. It checks source hashes, bounds
and file stability; all 84 copied files match their recorded bytes. The sample manifest SHA-256 is
`3d8f338b9649d09f24a7b5ba43a040e9f4caec2a7e0ed9a848a37e2443b9900b`. Keep a small local copy because the Mac
has about 4 GiB free. No PDF was sent into the GPU training workspace or processed there.

**Label geometry refers to the recompiled `plain.pdf`, not necessarily the original `arxiv.pdf`.** All 12 paired
layout checks report identical glyph placement. The Mac rendered those exact PDFs; a Poppler full-page render
was also visually inspected. The candidate pass produced 83 regions (73 roots), rejecting 32 unmatched/multi-box
or invalid candidates. Its automatic bounds are not reliable ground truth: inspected examples include author
text, adjacent body/table content, duplicate groups of separately captioned figures and truncated axes/panels.
Twenty-seven root candidates remain deferred with reasons; there is no automatic admission of every source label.

`annotations/mathpix-panels-v1.json` records **46 visually annotated complete figures** with 133 panel boxes,
52 shared-context regions and 192 explicit panel/context links. These are **Codex visual development annotations,
not independent human review**. Candidate identities/hashes, corrected crop bounds and exact transforms are kept.
Connected diagrams remain whole; independent plots/comparison images are panels; insets stay with their parent.
This is an explicit development labeling policy, not a claim that every possible conceptual subdivision has a
unique right answer. Selection and annotations were fixed before detector inference. Every final crop/overlay
was inspected. A long heatmap heading clipped in the first annotation draft was corrected into required context
before any training/evaluation; the discarded `mathpix-curated-v1` was never trained or scored.

| Added development split | Figures | Papers | Compound figures | Panels | Required context links |
|---|---:|---:|---:|---:|---:|
| Training | 30 | 7 | 7 | 95 | 147 |
| Validation | 16 | 4 | 8 | 38 | 45 |

The paper-family hash assigns splits before figure selection. First/last-author identities and exact/perceptual
image comparisons against both new and existing splits found no conflicts. This does not prove all authors,
laboratories, templates or visually related images are independent. Source abstract pages confirm the selected
article licenses; redistribution of the combined trained weights remains blocked by the older corpus's unresolved
rights and incomplete independent review. No final-test papers/images were inspected or scored for this addition.

Admitted dataset **`mathpix-v2`** has **1,728 training / 313 validation / 235 unchanged final-test figures**. The
dataset manifest SHA-256 is `e47d9f1d047f492a7c655063a1c0b7d1eaa1c2e19af5ad9ca28334314c4937e4`; annotations SHA-256
`326ca84cddf0800dd5408af7263ef0cb76af655778255f98a1b636fb80beffc6`. New training records have explicit 8x source
weight, resulting in **9.59% expected draws** after compound weighting; `sampling.json` records the actual mix.
Sampling never changes validation/test. Only the resulting figure PNGs/annotations were copied to
`/home/ben/science-reader-subfigures/data/reviewed/mathpix-v2/` and `data/manifests/mathpix-v2/`.

Before retraining, the existing v7 checkpoint was evaluated on exactly that validation set at threshold .6:

| Cohort | Panel TP / FP / FN | Recall | Precision |
|---|---|---:|---:|
| Original 297 figures | 482 / 55 / 23 | 95.45% | 89.76% |
| New 16 arXiv figures | 32 / 6 / 6 | 84.21% | 84.21% |
| New 8 compound figures only | 26 / 3 / 4 | 86.67% | 89.66% |

On the new cohort, 33 of 39 required-context links on matched panels are missing/clipped; another 6 links belong
to missed panels. These small, selected development examples expose a domain/context gap; they are not an
unbiased estimate for all 17,000 papers. The fresh-start comparison uses the same official COCO checkpoint with v7's
last-stage/augmentation settings, trains with the added examples and reports original/new cohorts separately.
This comparison uses no paid API. Labels are agent-authored from visual inspection, not human ground truth;
the detector's predictions were not used to author them. No strong-performance or release claim follows.

The fresh-start run completed **15 epochs / 430.04 s**, best epoch 2, at **2026-10-19 00:29:30 UTC**. It regressed
at the same .6 operating point: original cohort **460 TP / 111 FP / 45 FN** (91.09% recall, 80.56% precision),
new cohort **29 / 8 / 9** (76.32% / 78.38%). On the new cohort, 19 of 33 context links on matched panels are
missing/clipped, and 12 belong to missed panels. Some context recognition improved, but localization regressed;
the checkpoint is rejected as an improvement. This does not show that more PDFs are useless; it shows that this
particular data/training change did not improve the measured task. `mathpix-v12-gentle` therefore adapts the prior
best checkpoint at LR .00002 with the backbone frozen, keeping the same new data and validation set.
Saved fixed-threshold comparisons: `runs/mathpix-v11-fresh/cohort-comparison.json` and the local
`.artifacts/subfigure-training/mathpix-comparisons/v11.json`.

The gentle run completed **10 epochs / 281.43 s**, best epoch 1, at **2026-10-19 00:35:35 UTC**. At .6 it gives
original-cohort **478 TP / 49 FP / 27 FN** (94.65% recall, 90.70% precision) and new-cohort **31 / 6 / 7**
(81.58% / 83.78%). It reduces some old false splits but misses more panels. New shared-context retention improves
from 6 to 11 of the 45 annotated links, counting links on missed panels as missing; this is still inadequate.
Neither new checkpoint is accepted. The previous v7 checkpoint remains the comparison baseline, itself
unqualified. No GPU training remains running at this checkpoint. Evidence: `runs/mathpix-v12-gentle/` and local
`mathpix-comparisons/v12.json`. Next data work should broaden verified source figures and resolve annotation
boundaries before repeating small-batch parameter trials; more PDF volume alone has not improved this detector.

Further source inspection found original image assets under `build/src/` and the matching saved
`source.archive`. For PCBWorld (`2607.05915v4`), the official HTML explicitly names six subfigures in `S4.F5`,
whereas the automatic PDF root crop was incomplete. All six native board images exist, along with two other
framework illustrations. A read-only **954,256-byte** asset copy and the **3,832,400-byte** source archive were
verified locally: the archive SHA matches the frozen catalog, and all eight copied PNG hashes match their exact
original archive entries. No archive code was executed and no files were extracted into the source project.
The six images were visually inspected; they preserve complete boards that the PDF candidate lost.
This provides a better source for the next annotation batch, including explicit HTML subfigure identities;
these assets have **not** yet been admitted for training. Evidence:
`.artifacts/subfigure-training/mathpix-source/native-assets-v1-verification.json` and `pcbworld-native-subfigures.jpg`.

A full-page Poppler review confirmed the exact silver-label failure: the supposed Figure 5 root spanned the
top of both columns, mixing two of its panels with the neighboring Figure 6 and excluding its lower four panels.
On the Mac, each of the six original PNGs was matched to its PDF image occurrence by dimensions/fingerprint,
then confirmed with the full decoded RGB **SHA-256**. Exact PDF text identifies the corresponding `(a)`–`(f)`
labels. Nominal text bounds clipped some rendered descenders in the first proof; a bounded raster-ink check plus
outward padding corrected those before admission. All six corrected panels/labels were visually reviewed in
`pcbworld-recovered-figure5-v2-review.png`; the source/geometry/hash record and executed proof script are alongside it.
This is a verified source-assisted annotation recovery example, **not** detector inference or measured model
improvement, and is not inserted into the frozen dataset. The Mathpix source project remains untouched.

Inference-only resolution ablations on the earlier checkpoint also failed: at threshold .7 compound recall /
precision fell from .9394/.9588 at 640 to .7811/.8467 at 960 and .3805/.7386 at 1280. Larger inputs need their own
appropriate training; simply changing inference size is not a fix. The resolution-dependent anchor grids are
regenerated explicitly, with learned-parameter shape mismatches still rejected.

## Mac OCR and crop-policy comparison

Mac Vision accurately-mode OCR ran on all **297** validation figures with networking denied by `sandbox-exec`.
It completed in **39.03 s** wall time, with **214,827,008-byte maximum RSS** and **188,762,240-byte measured peak
memory footprint**. Each record binds image hash/dimensions, OS and Vision revision, recognized text boxes,
confidence and timing. These are a separate OCR aid, not independent ground-truth text annotations.

The experimental policy preserves raw panel geometry, adds a bounded crop margin and completes nearby OCR lines.
Text shared by several panels remains separate common context. Color bars/legend markers require image context;
recognized text alone cannot substitute for them. Raw, duplicate-filtered and OCR-assisted outputs are compared
on the same real validation figures. Whole-figure presentation coverage and independent critical-label review
remain outstanding. No policy qualifies a model merely by averaging away a visibly clipped label.

Scripts: `scripts/subfigure-training/`; immutable real manifests: `data/manifests/real-v3/`; saved run configs,
predictions, metrics, resource logs and checkpoints: `runs/` on the training host. Mac visual/OCR evidence:
`.artifacts/subfigure-training/`. The seven already viewed FDE-Gym figures remain development regressions.
The 235-figure final test stays reserved until the model and complete inference policy are frozen.

## Export of the actual trained checkpoint

The earlier `real-v2-laststage` checkpoint now also has a verified FP32 Core ML conversion, with networking denied.
Its weight SHA-256 is `856a2c7f9cf296c4076f905ab42adb7cdfbce4eef501208313bb49455d7018ae`, with an explicit five-class
checkpoint manifest and matching training-data provenance. The package is **80.286 MB**. All seven already seen
FDE-Gym figures pass numerical parity: maximum matched normalized box error .00028235, class-probability error
.00011958. Warm prediction median is **29.39 ms**; first prediction in this conversion process was **411.38 ms**.
This first prediction is not a standalone app cold-launch measurement or a memory/cancellation acceptance test.

The visual replay still finds an incorrect additional crop within the left scatter plot and overlapping
rectangles in a text-heavy diagram. The heatmap prediction includes its surrounding labels, unlike the earlier
research baseline, but this does not establish all-label preservation broadly. The export therefore remains a
research artifact. Evidence: `.artifacts/subfigure-training/v2-coreml-fp32/` and `v2-coreml-fde-review.jpg`.
Both the original 80-class COCO parity replay and this five-class replay pass; the routine `npm test` tier and
28 independent metric/geometry/context-loss/admission checks pass on both the Mac and GPU host,
including a case where perfect compound detections
must fail qualification because a single figure is falsely split. No slow app release suite is warranted by these
research-only script/document changes.

## Cost and release status

This work uses the owner's existing machine. New model API spend, GPU rental, dataset purchase, fixed service
commitments and provider reservations are all **$0**. Electricity cost is unknown; no zero-total-cost claim is
made. The $100/month service budget is unchanged. The trained scientific detector has a numerical export proof,
but has not passed crop-quality, distribution or full app-runtime qualification.

## Source-assisted training expansion — 2026-10-19 UTC

The owner asked to continue after the six-panel source-recovery proof. `source_sample.py` reads only the
authorized Mathpix corpus and selects **training-family papers only**, using the existing split seed. Its bounded
sample copies **24 papers / 239.6 MiB** of saved HTML, abstract metadata, source archives, recompiled PDFs and layout
checks to this Mac. Selection favors explicit HTML subfigure groups and raster assets; it is not representative
of the archive. The budget filled across ML, computer vision and AI before admitting language papers. The source
project, its services and its files remain unchanged; no archive code was executed or new PDF acquired remotely.

`source_figures.py` reads bounded archive members without extraction, verifies full decoded RGB SHA-256 against
embedded PDF images, and requires unambiguous same-page geometry. It refuses missing, duplicated, transformed or
unmatched assets. PDF work occurs only on the Mac. The final candidate pass has **36 figures from 15 papers**;
34 candidates lack an unambiguous original asset and four fail exact pixel matching. Two initially considered
HTML groups actually contain separately numbered figures and were excluded. No detector prediction authored
these annotations. Source selection and matching failures remain in the manifest rather than silently becoming
single-panel labels.

Visual inspection exposed two further preparation defects before training: image identity alone omits external
subcaptions, and filtering text by panel column can incorrectly append the right half of a full-width Figure
caption. The tool now recovers multiline subcaptions and fences them using complete PDF lines before column
filtering. Independent synthetic regressions cover both cases. Automatic bounds still require review: one
18-panel histogram figure needed its two source-identified column headings recovered above the image bounds;
three final crop edges needed explicit correction to exclude neighboring caption/article ink. A source asset
that was itself a page screenshot remains deferred. Candidate/annotation drafts were **never trained or scored**.

The admitted **`source-v2`** addition is **35 training figures / 15 papers / 30 compound figures / 113 panels**,
with 14 context regions (10 titles, three Y axes, one color legend) and 54 explicit required-context links.
Single-image assets containing several plots were manually subdivided; connected workflows and their legends
remain whole. All final crops/overlays were visually reviewed, including corrected letters, column headings and
multiline subcaptions. These are **Codex development annotations, not independent human ground truth**.
Article abstract pages confirm the catalog licenses; first/last-author and exact/perceptual cross-split checks
found no conflicts. This does not establish all-coauthor/lab/template independence or resolve older corpus rights.

Combined training now has **1,763 images**, including the original 384 generated plots and 65 new arXiv figures
from 22 papers across both additions. Do not count synthetic identifiers as real papers. The **313 validation**
and **235 final-test** records are byte-for-byte unchanged from `mathpix-v2`; no final-test inference was run.
New-source records retain weight 8 and compound weight 3, giving **25.10% expected arXiv draws**. This changes
the sampling mix as well as adding examples; any result is not an isolated causal estimate of annotation quality.

Dataset manifest SHA-256: `69d600ce65ddab0612b75389003f9680a92e7e38e470775dda9be39a37cdcdc5`.
Committed labels: `scripts/subfigure-training/annotations/source-panels-v2.json`.
Local source/candidate/correction evidence: `.artifacts/subfigure-training/mathpix-source/source-sample-v1.json`,
`source-tools-v3/`, `source-figures-v4/` and `source-curated-v2/`. The correction script preserves the preceding
candidate-manifest hash and the changed PDF crop transform. Only reviewed PNGs/annotations/provenance were copied
to GPU `data/reviewed/source-v2/` and `data/manifests/source-v2/`; no PDFs or source archives entered that workspace.

The first comparison, `source-v13-gentle`, starts from the same v7 checkpoint with v12's frozen backbone,
LR .00002, compound weighting, spatial augmentation, seed and early-stopping settings. It finished at
**00:58:30 UTC**, **10 epochs / 278.80 s / 2.98 GB peak allocated VRAM**, with best epoch 1. At the same .6 panel
confidence / .75 IoU operating point (existing context threshold .25), it produces:

| Validation cohort | Baseline TP / FP / FN | Source v13 TP / FP / FN | v13 recall / precision |
|---|---|---|---|
| Original 297 figures | 482 / 55 / 23 | **482 / 36 / 23** | 95.45% / 93.05% |
| New 16 arXiv figures | 32 / 6 / 6 | **31 / 6 / 7** | 81.58% / 83.78% |
| Combined 313 figures | 514 / 61 / 29 | **513 / 42 / 30** | 94.48% / 92.43% |

This is an observed reduction in false detections, **not an across-the-board improvement**. Original compound
recall falls from 284/297 to 280/297; combined compound recall falls from 310/327 to 305/327. On the newer cohort,
required-context links retained rise from **6/45 to 18/45**, but original links fall from 50/75 to 46/75. Combined
retention is **64/120**, versus 56/120 before, counting links on missed panels as missing. This is far below the
quality gate. No checkpoint is accepted for deployment.

The four changed new-cohort images were visually reviewed. One four-plot figure gains a correctly bounded panel;
a two-heatmap figure is wrongly merged; a line plot's legend becomes entangled with panel detection. Removing an
extra detection from a connected workflow also leaves part of that workflow outside the remaining box. The last
case illustrates why fewer false positives alone cannot qualify a crop or replace complete-content inspection.
No validation annotation was changed in response to these predictions.

A paired 10,000-resample paper-group diagnostic estimates combined precision change at +0.73 to +5.77 percentage
points, but recall change at -1.76 to +1.32 points (95% percentile intervals). These are descriptive intervals on
selected, repeatedly used validation data, **not independent-test evidence or adjustment for checkpoint selection**.
Only four papers comprise the new cohort; its intervals are much wider. Evidence: GPU
`runs/source-v13-gentle/cohort-comparison.json`; local `source-comparisons/source-v13-gentle/`,
`v13-paired-review.json`, `v13-new-validation-changes.jpg`. A separate Poppler full-page render confirms the two
recovered histogram column headings against the original page layout.

Replaying the previously explored duplicate-suppression policy (.6 panel threshold, .4 overlap) also fails the
gate. On v13 it reduces false crops to 33 but loses three more matched panels (510 TP / 33 FP / 33 FN); the
baseline under that same policy is 512 / 51 / 31. Its delivered rectangles with the existing 2% whole-image
margin score worse still. This is another measured tradeoff, not a reason to substitute the more flattering
raw-detector score for actual crop quality. Reports: `source-comparisons/baseline-deduplicate.json` and
`source-comparisons/source-v13-gentle/deduplicate.json`. No new policy is selected.

The follow-up `source-v14-laststage` keeps the dataset, initialization, LR, seed and comparison fixed while
allowing the last backbone stage to adapt (backbone LR .000002). It finished at **01:03:15 UTC**, **9 epochs /
259.36 s / 3.11 GB peak allocated VRAM**, with best epoch 0. At .6, original figures give **480 TP / 46 FP / 25 FN**;
new arXiv figures give **33 / 5 / 5**; combined **513 / 51 / 30** (94.48% recall, 90.96% precision). Combined
compound counts are **308 / 15 / 19**. It finds more new-domain panels than either v7 or v13 but loses two original
panels versus v7, and its context retention is only **57/120** (46/75 original, 11/45 new). It does not recover the
required combination of panel recall, low false crops and complete context. It is **not accepted**.

Both comparisons are complete and **no GPU training job remains running**. v13 has the stronger reduction in
false crops; v14 has slightly better panel matching on the small new cohort. Neither dominates all requirements,
and neither is a replacement model. The original v7 remains an unqualified comparison baseline; no app catalogue,
backend, release or physical-device state changed. The next data priorities are independently reviewed shared
legends/axes, multi-plot heatmaps and connected-diagram negatives, with broader paper/domain coverage. Source-asset
matching helps produce reviewable labels, but it does not solve grouping within a single asset or establish
independent accuracy. Preserve the fixed validation/final-test boundary during that work.

Final comparisons and exact provenance: GPU `runs/source-v14-laststage/cohort-comparison.json`; local
`.artifacts/subfigure-training/source-comparisons/source-v14-laststage/`. Source/identity/geometry regression
checks total **35 passing on both the Mac and GPU host**. No paid provider spend, new reservation or service
commitment; local electricity remains unpriced.

## Targeted heatmaps, shared context and complete diagrams — 2026-10-19 UTC

The next sample targets caption mentions of heatmaps, legends and diagrams, excluding all earlier sampled paper
families and using the same training-only split rule. Three bounded passes admit **38 paper packages / 190 files /
248.50 MiB** from the existing read-only corpus. Language papers are explicitly included. Caption selection is
neither representative sampling nor automatic panel annotation. Source files/services remain unchanged; there
are no remote PDF acquisitions or Science Reader PDF processing jobs.

The embedded-raster method recovers 18 candidates. Many remaining HTML PNG paths actually refer to previews of
native source figure PDFs. `source_native.py` recovers 25 more candidates by requiring a unique archive PDF,
an explicit TeX `includegraphics` reference and a unique caption page in the compiled paper. It reads bounded
archive members as data, executes no TeX and renders PDFs only on this Mac. Each one-page asset was visually
compared with its paper-page render. This is reviewed source correspondence, **not** the full pixel-identity
proof used for embedded raster images. The curation gate binds that review to the exact parent-render hash.

Of 43 candidates, two remain deferred: an ambiguous attention-transition sequence and overlapping chart/axis
labels that need a more careful multi-region interpretation. The admitted **41 figures / 34 papers / 67 panels**
include 24 native assets and 17 embedded raster crops: 12 language, 11 computer vision, 10 ML and eight AI figures.
Fourteen compound figures and 27 single figures/connected diagrams provide both positive and negative examples.
The 14 explicit context regions are three legends, five titles, two X axes and four Y axes, with **40 required
links**. Examples include three clinical heatmaps sharing a colorbar/method axis; three scatter plots with a
legend only in the last plot; six correlation matrices sharing visit identities; and complete workflows with
their final output preserved. Native assets containing several plots are manually subdivided.

Final overlays were reviewed before training. One vertical MSE-axis annotation was expanded after the first
overlay revealed clipping. Draft annotations/curation were never trained or scored. These remain **Codex
development annotations**, not independently human-reviewed ground truth. License/first-last-author/image
checks found no exclusions; they do not establish all-author/lab/template independence or resolve older rights.

The **`targeted-v2`** dataset has **1,804 training images**: 1,314 original real figures, 384 generated plots and
106 arXiv figures from 56 papers across the additions. Both held-out files remain byte-identical: **313 validation
figures** and **235 final-test figures**. No final-test inference or visual inspection was performed. New records
retain sampling weight 8; with compound weight 3, total arXiv expected draws rise from 25.10% to **33.40%**.
Thus data and sampling mix change together; this is not an isolated causal estimate of any one annotation choice.

Manifest SHA-256: `00f4f091406a36bcc77f05ba5f7d06bb7a1c74060945c5133c98b9a3d153100c`.
Annotation SHA-256: `e3a4c47bd1e065402a5724396d4666349031b1efc9f742a024529ee6f518e6df`.
Labels: `scripts/subfigure-training/annotations/targeted-panels-v2.json`.
Local evidence: `.artifacts/subfigure-training/mathpix-source/targeted-final-v1.json`, `targeted-tools-v3/`,
`targeted-review-v2/`, `targeted-curated-v2/`, and the native-source paired page sheets. Only 41 reviewed PNGs
(15,521,867 bytes) and annotation/provenance files went to GPU `data/reviewed/targeted-v2/` and
`data/manifests/targeted-v2/`. **40 regression tests pass on both machines.** New provider/service spend is $0.

`targeted-v15-gentle` uses v13's v7 initialization, frozen backbone, LR .00002, seed 20261018, batch 8,
compound weight 3, spatial jitter, epoch cap 40 and patience 8. It compares the expanded data on the same
validation set and fixed operating points. Measured outcomes follow; no candidate is qualified by the
expanded dataset alone.

The run completed at **02:06:04 UTC**, **9 epochs / 255.88 s / 2.98 GB peak allocated VRAM**, best epoch 0.
At the fixed .6 panel threshold / .75 IoU (context .25), the result is:

| Cohort | v13 TP / FP / FN | Targeted v15 TP / FP / FN | v15 retained context |
|---|---|---|---|
| Original 297 | 482 / 36 / 23 | **473 / 40 / 32** | 45/75 |
| New 16 arXiv | 31 / 6 / 7 | **33 / 4 / 5** | 15/45 |
| Combined 313 | 513 / 42 / 30 | **506 / 44 / 37** | **60/120** |

Combined compound results are 301 TP / 14 FP / 26 FN. The small new cohort improves panel matching, but the
overall result regresses against v13 and is **not accepted**. Visual review confirms substantial errors rather
than just score fluctuations: five separately labeled chemistry routes merge into one; a photograph loses its
left edge; a single plot loses the upper axis/tick. The newer line-plot pair separates correctly again, while
the paired heatmap still has an overbroad second box and incomplete context detection. No validation labels changed.

A hash-bound diagnostic reproduces the existing context scorer and attributes v15's 60 missing required links:
**45 have no eligible same-class context box at IoU .5, six have a detected but clipped context box, and nine are
on missed panels**. Of the 45, 36 are titles/headings. The corresponding v13 counts are 38 / 9 / 9 (56 missing).
This identifies the recorded failure stage; it is not proof of why learning failed, nor a semantic association
test. Contexts available as separate crops remain an optimistic geometry measurement. Evidence:
`source-comparisons/targeted-v15-gentle/{cohort-comparison,context-failure-audit}.json`, `v15-changed-images.json`,
`v15-review-*.jpg`, and `targeted-tools-v3/context-failure-audit.py`.

The next single-factor check reduces only the latest 41 records' sampling weight from 8 to 2; all 1,804 images,
labels, held-out records, initialization and optimization settings are unchanged. Earlier arXiv examples retain
weight 8, so total expected arXiv draws become **27.36%**, close to v13's 25.10%. This tests whether oversampling
contributes to regression; it does not assume that explanation is correct. Immutable data revision
`targeted-balanced-v1`, manifest SHA `5241c35dec350fb3db703977be7327139d5c24a06bb1695c57ff179add53e625`;
run `targeted-v16-balanced`. No paid spend or release.

The sampling comparison completed at **02:13:30 UTC**, **9 epochs / 256.03 s / 2.98 GB peak allocated VRAM**,
best epoch 0. Original figures score **479 TP / 48 FP / 26 FN**; newer figures **31 / 7 / 7**; combined
**510 / 55 / 33**, with compound counts **305 / 17 / 22**. Context retention falls to **53/120** (46/75 original,
7/45 newer), and 16 single figures are falsely split. Reducing the latest examples' weight recovers some v15
misses but worsens false crops and context; it does not establish oversampling as the cause or qualify a model.
The context audit attributes 67 missing links to 52 unavailable boxes, five clipped boxes and ten missed panels.
Visual replay confirms the incomplete photograph, a split chart/key, disconnected diagram pieces and an inset
separated from its parent microscopy panel. No validation labels changed. Evidence:
`source-comparisons/targeted-v16-balanced/`, `v16-changed-images.json` and `v16-review-*.jpg`.

Both gentle runs select epoch 0. The declared comparison, `targeted-v17-fresh`, therefore uses the exact v7
fresh-training recipe (original COCO initialization, LR .0002, freeze three epochs then last backbone stage,
60-epoch cap, patience 12, compound weight 3 and spatial jitter) on `targeted-balanced-v1`. This compares learning
the expanded examples from the start with continued fine-tuning. It changes the training recipe as a bundle;
it is not an isolated causal estimate of initialization alone. Validation/final-test boundaries remain fixed.

The fresh run completed at **02:31:08 UTC**, **25 epochs / 737.44 s / 3.11 GB peak allocated VRAM**, best epoch 12.
At the same fixed .6 operating point:

| Cohort | v13 TP / FP / FN | Fresh v17 TP / FP / FN | v17 retained context |
|---|---|---|---|
| Original 297 | 482 / 36 / 23 | **475 / 51 / 30** | 21/75 |
| New 16 arXiv | 31 / 6 / 7 | **32 / 6 / 6** | 10/45 |
| Combined 313 | 513 / 42 / 30 | **507 / 57 / 36** | **31/120** |

Combined compound counts are **299 / 18 / 28**; 19 single figures are falsely split. The 89 missing context
links comprise 63 without usable context boxes, five with clipped boxes and 21 on missed panels. Only three of
48 unique context regions are retained for every linked panel. The final epoch has worse title AP50 than the
selected checkpoint (.086 vs .108), but higher legend AP50 (.313 vs .279); its full fixed-threshold crop replay
has not been run. Visual replay of the selected checkpoint confirms merged chemical routes, missing map
margins, a dropped chart key and an extra crop of a
connected workflow's output. Some individual figures improve, including a timeline, but the overall result is
**not accepted**. Evidence: `source-comparisons/targeted-v17-fresh/`, `v17-changed-images.json`, `v17-review-*.jpg`.

Best checkpoint hashes, kept on the GPU host (no model binary copied to the nearly full Mac):

| Run | SHA-256 |
|---|---|
| v15 | `fa1c8ff16a0388b751e94b9c588a4a94111a12fa2b3995d71e63b2f93930afdb` |
| v16 | `71144ff9a0b64f48888c896cd36c1a50e4b2cb7392df379de76ed1f1313a4aaa` |
| v17 | `61a0c7514f26f7724bc9aafeac40abeef2586f8fa28b136c8cfb7e693a0ba8f3` |

Each run retains an `evidence-hashes.json` binding checkpoint, predictions, metrics, source, sampling, resources
and completion record. The copied v17 evidence hashes were verified locally. These three comparisons are
complete; no GPU training process remains running. Adding this targeted data has **not** produced an overall
improvement over v13. It remains a research reference, not a qualified model. No app/catalogue/deployment change.

### Offline OCR replay and context limits

The unchanged Mac Vision OCR tool now covers the remaining 16 validation figures: 374 text lines, with a summed
Vision-request duration of 1.6811 s (not total wall time or cold-start latency). Execution denied all networking.
Combining those records with the earlier 297 gives 313 hash/dimension-verified OCR records; final-test figures
remain excluded. OS 26.3.1(a), Vision revision 3. Combined OCR SHA-256:
`b9dc25a25868a865095917a38541fa44a3fbbe9629dc2b0c42a50054c63a377c`.
Evidence: `.artifacts/subfigure-training/combined-validation-ocr-provenance.json` and the bound input/output files.

Replaying the two existing OCR crop policies, with duplicate suppression at .4, panel confidence .6 and context
confidence .25, does **not** qualify either checkpoint. These measurements include suppression and margin changes;
they are not an isolated estimate of OCR's causal effect. Report actual delivered rectangles separately:

| Checkpoint / existing margin policy | Deduplicated detector TP / FP / FN | Delivered crop TP / FP / FN | Retained context on delivered matched panels, of 120 |
|---|---|---|---|
| v13 / bounded | 510 / 33 / 33 | **500 / 43 / 43** | **32** |
| v13 / 2% whole-image | 510 / 33 / 33 | **479 / 64 / 64** | **16** |
| v15 / bounded | 504 / 38 / 39 | **496 / 46 / 47** | **34** |
| v15 / 2% whole-image | 504 / 38 / 39 | **478 / 64 / 65** | **17** |

The standard margin keeps more context on originally matched detections but makes rectangles too broad for the
localization test. The bounded policy preserves more localized rectangles while leaving more context outside.
Neither resolves missing separate headings/legends. Reports are `ocr-313.json` and `ocr-bounded-313.json` under
each local run directory. No new crop policy or app behavior is selected.

The 120 required panel-context links refer to **48 unique context regions**: 36 titles/headings, six legends,
four Y axes and two X axes. Several panels share a region, so link counts are not 120 independent examples.
Ten validation figures have missing context in each of v13/v15/v16. Among their unique regions, 15/16/12,
respectively, are retained for every linked panel. Current training has 108 real title regions and 384 generated
ones, but only 66 real legends; these counts motivate wider real-context coverage rather than claiming the
dataset already represents the problem well. The fixed validation set is repeatedly used development evidence.

The attribution is now a reusable `scripts/subfigure-training/context_report.py` command, with image/split
identity checks and explicit reconciliation against the existing crop scorer. Four geometry/identity
regressions cover shared-region denominators, missed panels, missing versus clipped context, and context already
inside a panel. The complete research suite is **44 passing on both Mac and GPU host**; the project's `npm test`
fast tier also passes. New `context-report.json` artifacts reproduce the earlier v13/v15/v16 attribution counts.

Raw context-class detection is also weak: v13/v15/v16 title AP50 is .177/.188/.170 and legend AP50 is
.274/.303/.352; shared-axis AP50 stays at or below .011. These are small validation populations (36 titles, six
legends, three X-axis boxes, four Y-axis boxes, including one axis without a required panel link). They do not
support a general accuracy claim, but they do rule out presenting strong panel AP as strong context detection.

A saved-proposal diagnostic further separates low confidence from missing geometry. Of v13's 25 unique regions
with no usable context box at .25, 17 have a same-class proposal at IoU .5 below that cutoff; eight have no
localized saved proposal. Only each query's top class at score >= .03 is saved, so this cannot characterize
unretained logits. Lowering the cutoff alone is not established as a fix: across all 49 annotated context boxes,
v13 at .25 has **19 matches / 164 unmatched proposals / 30 misses**; at .1, **29 / 871 / 20**; at .03,
**40 / 5,514 / 9**. These are raw proposals without suppression or semantic association; unmatched proposals can
also include ordinary internal text outside the shared-context annotation policy. The check exposes the cost of
simple threshold lowering, not final user-visible false crops. No threshold is changed. Reproducible evidence:
`targeted-tools-v3/context-{proposal,threshold}-probe.py` and corresponding per-run JSON reports.

# Local figure regions

Status, 2026-10-23: structure first (15.7% of arXiv figures already have exact per-image parts); bottom-up
ink grouping and a local VLM judge were measured and not adopted; the 10-22 release candidate remains the best
detector, below the gates. Count disagreement is proposed as an extra "whole figure" fallback. See
[round 3](../reviews/SUBFIGURE_DETECTOR_20261023.md).

Status, 2026-10-22: the rights-clean release candidate scores 73.3% fully right / 18.8% wrong crops / 84%
panel recall on a new never-seen arXiv test; gates not met, nothing bundled. The on-device API for offering
parts P1… to the explainer (with a "whole" fallback) and Core ML FP32 parity are specified in
[Subfigure detector 10-22](../reviews/SUBFIGURE_DETECTOR_20261022.md); FP16/int8 compression fails parity.

Status, 2026-10-21: a corpus-trained detector + completeness/caption policy reaches 80.4% fully-right figures
(8.9% wrong crops) on a new held-out arXiv final test versus 59.1% for the previous detector; still below the
gates below, so not bundled. The model-free completeness check is the first integration: built on 2026-10-21 for
every AI-written crop on iPhone/iPad/Mac and the browser (local source, not released; [Complete
crops](FIGURE_VIEW.md#complete-crops--2026-10-21-local-source-not-released-not-deployed)). See
[Subfigure detector](../reviews/SUBFIGURE_DETECTOR_20261021.md).

Earlier status, updated 2026-10-19 UTC: iterative scientific-panel fine-tuning has run on the owner's GPU machine. The real corpus
has 1,846 figures from 398 papers; 235 figures from 60 papers are reserved for the final test. No detector is
qualified or bundled with the app. See [training/data evidence](../reviews/SUBFIGURE_TRAINING_20261018.md) and
[earlier Mac export results](../reviews/LOCAL_FIGURE_REGIONS_20261018.md). No physical iPhone measurements.
The new 46-figure arXiv development addition exposed further failures; neither of its first two training runs
is accepted. Original source assets plus PDF image/text identity successfully recover one previously malformed
six-panel annotation. The source-assisted workflow now adds 35 reviewed training figures from 15 further papers;
the 313 validation / 235 final-test records remain fixed. The gentle run reduces combined false crops from 61 to 42
but finds one fewer panel; required-context retention remains inadequate. The last-backbone-stage comparison is
also complete, with a different tradeoff (513 matched panels / 51 false crops / 30 missed; context 57/120).
Neither run is accepted. These are validation tradeoffs; the new labels are
Codex development review, not independent human review.

Targeted source recovery adds 41 more training figures from 34 papers, with shared heatmap/scatter context and
complete diagrams. Native figure PDFs are rendered only on the Mac and visually matched to their paper pages;
they are not automatically admitted by basename matching. The 1,804-image training revision keeps both held-out
files fixed. v15 improves the small new cohort but regresses overall (506 matched / 44 false / 37 missed;
context 60/120) and is rejected. Reduced-sampling v16 also fails (510 matched / 55 false / 33 missed;
context 53/120). Fresh-training v17 also regresses (507 matched / 57 false / 36 missed; context 31/120).
All three comparisons are complete; no model is qualified. The reproducible failure report separates missed
panels, absent context detections and clipped context. Existing OCR/margin policies and simple confidence
reduction do not establish a solution; these models remain excluded from the app.

## Authorized training workspace — 2026-10-18

The owner authorizes iterative fine-tuning over SSH on `ben@192.168.1.32`. Write only in the new project directory
`/home/ben/science-reader-subfigures`: `source/` for reviewed training scripts and the pinned official detector,
`env/` for an isolated Python environment, `data/sources/` for source assets/licenses, `data/manifests/` for frozen
splits/annotation revisions, `data/generated/` for reproducible synthetic plots, and `runs/<run-id>/` for configs,
logs, checkpoints, metrics and resource measurements. Keep the existing October 13 checkout and unrelated jobs
unchanged. No production secrets or private papers belong here. No paid model API is needed for the first pilot.

Begin with one bounded GPU job, record elapsed time/VRAM/temperature and stop on non-finite loss or resource
failure. Save resumable checkpoints, the exact script/dataset/config hashes and validation predictions. Do not
install packages globally or change the GPU driver. The RTX 3090 has 24 GB VRAM; leave headroom for the desktop.
The $100 monthly service budget is unchanged: no rented GPU or fixed commitment is added; electricity cost is
unknown and must not be described as zero. Small reports/checkpoints may return to the Mac, whose disk is nearly full.

Treat the seven already inspected FDE-Gym images as development regressions. New paper/family-disjoint test
examples must not be used for early stopping, threshold selection or hard-example training. Record annotation
origin and review status honestly; automated/generated labels are not human review. First measure a frozen-backbone
baseline, then last-stage fine-tuning. Broaden the training data in response to validation failures, and qualify
the selected model on real held-out figures before claiming the requested strong performance.

The owner asked for a purpose-built local model to extract subfigures and plots, shared by Figure AI Explainer and ordinary chat, regardless of the chosen cloud/local answering model. Geometry belongs on the device; explanation belongs to the chosen chat model. A small detector can locate panels without an LLM generating coordinates or receiving a whole PDF. PDFs, figure acquisition and cropping remain device-only, as in [HTML_FIRST_READER](HTML_FIRST_READER.md).

## One figure context for every conversation

The existing verified figure image, caption, numbered surrounding paragraphs and structured equations remain authoritative inputs. The proposed `FigureRegionSet` adds candidate regions to that exact image. It contains the image SHA-256, decoded pixel dimensions/orientation, detector identity and weight hash, preprocessing revision, and normalized top-left `x/y/width/height` coordinates. A stable region ID derives from those inputs and the accepted geometry, never from a model-generated title. Multiple image assets use the exact same compositing transform as the displayed figure; boxes cannot silently move to a different composite or revision.

Keep detector boxes separate from explanation claims. A candidate is a geometric region, not proof that it is panel (b), a legend, or the evidence for a particular claim. Caption labels and local OCR can help associate candidates, but unresolved associations keep the whole figure. Nested insets, shared legends and table/diagram structures need explicit representation rather than forced nonoverlapping panels. A retained region may require additional context boxes, especially a legend shared with another panel.

For a prototype, opening a figure may prepare candidates locally in a cancellable background task. Selecting a region gives the same context to the existing figure conversation or main chat: crop, a small whole-figure overview, caption, relevant numbered paragraphs, and exact LaTeX when relevant. The small overview preserves shared context without sending every PDF page. Cloud transmission still requires the existing consent and an explicit question; local detection itself uses no AI credits. A selected local text-only model cannot interpret the pixels and must say so.

The explainer and Chat retain one composer, selected model and conversation. Fullscreen offers Whole figure / Selected part. Returning from a citation reopens the saved explanation without another request. Region extraction should improve that shared context, not create a second conversation or separate credit-consuming feature. An unsure detector leaves the whole figure visible; a future manual region adjustment can be proposed with a concrete interaction before implementation.

## Storage and admission

Do not modify a verified reader bundle. Cache accepted geometry as an account-isolated encrypted sidecar using the existing local encrypted-storage conventions. Cache key includes image hash, detector hash and preprocessing revision. Derived image crops need not be persisted: reproduce them from the original image. Clear sidecars and in-memory regions with paper-content removal and account removal. No server schema, uploaded PDFs or plaintext persistent search index is needed.

Before admitting a region, validate finite coordinates, positive extent, bounds, minimum rendered detail, image identity and transform. Detect duplicate/near-identical and crossing boxes; preserve legitimate insets separately. Check that axes, tick labels, panel labels and legends needed to interpret the plot are included. Offline Mac OCR and an experimental containment policy have been measured on all 313 real validation figures, but are not yet qualified or integrated. A confidence threshold is insufficient: the tested heatmap lost labels at 0.92 confidence. When checks disagree, retain the whole figure and permit answering from it.

Bound image dimensions, concurrent work (one detector run), result count and cache size. Run inference outside the UI thread, cancel on paper/account change, and allow memory pressure to discard model/results. Model installation must use a pinned manifest/hash and verified license. Reuse the app's Local models download/error conventions if a separate download is needed. Never download another chat model merely to crop a figure.

## Verification before inclusion in a build

Build a human-reviewed corpus across ML plots, scientific diagrams, microscopy, tables, insets, shared legends, vector-rendered figures and scans. Include the owner's failed FDE-Gym crops. Split papers/authors between tuning and evaluation. Record panel recall, incorrect extra crops, IoU, exact panel association, and preservation of axes/labels/legends. A whole-figure fallback counts as a missed extraction rather than a successful split. Evaluate downstream answers with the same caption/paragraph context using both cloud and local chat, including unsupported questions.

Test the complete preprocessing/export pipeline, not just the source weights. Pin resize/letterbox rules, orientation, output decoding, NMS and original-image coordinate conversion. Replay fixtures offline on each change. Measure first use separately from steady-state, peak app memory, thermal behavior and cancellation on the intended phone once physical-device testing resumes. Mac speed is not iPhone evidence.

Distribution remains gated on a suitable license and quality. The current figpanel weights and inference tooling carry AGPL terms; they are research inputs only. Next candidates are a permissively licensed/trainable small detector and the Florence-2 plot adapter, with both base and adapter licenses checked. The research does not justify shipping the current detector as an automatic cropper.

## Fine-tuning plan, 2026-10-18 (Mac prototype; research training underway)

The new owner direction makes local answering models Mac-only. Keep this detector experiment on Mac too; no new
model is included in the iPhone/iPad app. The localization component remains independent of the answering model,
so a selected region can feed either OpenRouter chat or Mac-local chat through the same figure conversation.

The later owner direction permits **read-only** use of `/home/ben/mathpix`, an existing public-paper research
collection on that host. Its acquisition/processing services remain unchanged. Copy a bounded, hash-verified
sample to the Mac; source layout labels refer to the recompiled `build/plain.pdf`, not necessarily `arxiv.pdf`.
PDF parsing/rendering remains on the Mac. Only extracted public images and reviewed annotations enter the GPU
workspace. Correct or defer bad source bounds, retain captions/licenses/transforms, and quarantine cross-split
paper/first-last-author/exact/perceptual-image conflicts. Codex visual annotations are development labels,
not independent human qualification. The first 46-figure addition and its limitations are recorded in the review.

Use a small detector first, then deterministic text/legend containment. Fine-tuning the answering LLM to emit
coordinates couples unrelated failure modes and adds a much larger runtime. It remains a comparison baseline,
not the first deployment design. The existing heatmap failure demonstrates why confidence alone is insufficient.

### Candidates and data rights checked against primary sources

- [Official RT-DETR/RT-DETRv2](https://github.com/lyuwenyu/RT-DETR) is Apache-2.0 and documents custom-data fine-tuning.
  Start with its R18/S model, not the differently licensed Ultralytics distribution. Its published COCO scores and
  GPU speeds do not measure scientific panels or Core ML performance. Prove conversion of the precise checkpoint,
  input geometry and output decoding before investing in a training run.
- The [Florence-2 plot adapter](https://huggingface.co/amayuelas/plot-visualization-florence-2-lora-32)
  describes LoRA tuning of [Microsoft Florence-2-base-ft](https://huggingface.co/microsoft/Florence-2-base-ft).
  Both cards declare MIT. Compare it as a smaller vision-language localization baseline; neither the card nor a
  nominally small parameter count proves crop quality, Apple runtime support or complete training-data rights.
- [MedICaT](https://github.com/allenai/medicat) contains 7,507 panel/subcaption annotations on 2,069 compound figures.
  Its README limits the dataset to non-commercial use and records varying source-article licenses. The repository's
  Apache license is not blanket permission for its images. Use only for an allowed research evaluation; exclude it
  from distributed-model training until the applicable rights are resolved.
- [FigEx2](https://arxiv.org/html/2601.08026v1) combines an 8B captioner and detector. Its authors report detection
  mAP .291 on MedICaT versus .726 on BioSci-Fig-Cap. This supports a cross-domain evaluation requirement, not a claim
  that either figure is attainable here. Caption-assisted localization is a later ablation if simpler detection fails.

### Training and comparison recipe

1. Freeze a test set by **paper and near-duplicate figure family**, before annotating training examples. Include the
   seven FDE-Gym failures as regression cases, plus held-out ML plots, algorithm diagrams, heatmaps, shared legends,
   nested insets, tables, scanned plots and single-panel negatives. Hold out author/lab/template families where possible.
2. Label an interpretation-complete panel box, its panel label, and separate required-context boxes for axes, ticks,
   legends and shared labels. A single broad full-figure box is not a successful answer to a panel request. Record
   source-image hash, dimensions, transform, source/license, annotator and review status. A crop can need more than
   one context region; do not force shared legends into a neighboring panel.
3. Pilot with 300–500 reviewed, rights-cleared real figures plus generated plots whose layout/label boxes are known.
   These are proposed sample counts, not a completed dataset. Use synthetic plots to vary grids, margins, fonts,
   scales, colors, line thickness and legends; do not let synthetic templates dominate the held-out test.
4. RT-DETR pilot: replace the detection head, briefly train the head with the backbone frozen, then unfreeze the
   final backbone stage at a lower learning rate. Compare full fine-tuning only after that baseline. Start from the
   upstream AdamW recipe, tune learning rate and early stopping on validation panel recall and critical-label loss.
   Preserve aspect ratio; avoid flip/mosaic/crop augmentations that remove scientific labels or invent panel semantics.
5. Florence comparison: freeze the image backbone and test rank-8/16 LoRA on language attention/projection layers,
   using its documented object-detection coordinate format. Only then test unfreezing the visual projection. Treat
   malformed coordinates, out-of-image boxes and wrong panel association as failures. Rank/learning rate are
   experiments, not endorsed settings or measured results.
6. Compare detector-only, detector plus local OCR containment, and Florence on the **same** untouched images.
   Rank by panel recall, false crops, correct label association, and retention of interpretation-critical text.
   Add downstream plot-reading questions with fixed caption/paragraph/LaTeX context. Whole-image fallback is counted
   separately, never relabeled as a successful extraction.
7. Export the selected trained checkpoint to Core ML, beginning with FP32; replay identical images through source and exported
   models, including orientation and wide/tall composites. The measured RT-DETRv2 baseline below does not preserve
   numerical parity in FP16. Reduce precision only if those results and downstream answers
   remain acceptable. Measure cold start, steady latency, peak process memory, cancellation and concurrent-reader
   behavior on Mac. No paid GPU training or dataset purchase has been started.

Proposed acceptance gate: at least 95% panel recall on the reviewed in-scope set, at least 99% retention of required
label/legend area on accepted crops, no known critical-label regression, and fewer than 2% incorrect extra crops.
Report uncertainty and per-domain counts; these thresholds are targets, not current results. A low-confidence or
containment-failing result stays on the whole figure. Only after this evaluation should detection become automatic
in the shared figure view. The next useful work is annotation and an exportable small-detector baseline, not more
unreviewed prompt/coordinate heuristics.

Training evaluation clarification: report the compound-figure subset and the complete population including
single-figure negatives separately. A model that finds compound panels but splits single charts/connected diagrams
unnecessarily fails the gate. Threshold selection must include both populations; compound AP alone is insufficient.

Research ablation: a small binary single/compound classifier can consume pooled features from the frozen
detector encoder. Train that head only on real training figures and validate it on the same real held-out
validation papers. It tests whether global figure context reduces the observed splitting of connected diagrams
and legends. It does not replace localization or qualify a fallback as extraction. Any later gating policy must
count rejected compound figures as missed panels and repeat exact-checkpoint export/runtime checks. No classifier
is included in the app catalogue. The measured head reaches validation AUC .9894, but its combined crop policy
still fails: retaining 174 single figures whole gives all-figure precision 92.51%, compound precision 97.59%,
and leaves 24 required context links missing/clipped. AUC alone does not qualify it.

### Official detector export feasibility, 2026-10-18

The pinned official RT-DETRv2-S COCO checkpoint now runs on this Mac through Core ML with networking denied.
Its **FP32** export is 80.44 MB and matches the source prediction set on all seven local figures: maximum matched
normalized coordinate error 0.000171 and class-probability error 0.0000811. Warm prediction median is 30.4 ms;
first prediction is 4.68 seconds, separately from conversion. These measurements do not establish panel accuracy
or app memory use. The generic COCO checkpoint is a conversion baseline, not a trained scientific detector.

The **FP16** export is 40.35 MB but fails parity on all seven images, including after one-to-one query matching;
confidence drift reaches 0.352 and credible-box coordinate drift 0.303. A mixed-precision comparison, keeping
geometry/normalization/nonlinear operations in FP32, also fails; the exact cause remains unresolved.
Do not silently accept that export merely
because it compiles or is smaller. Use the full-precision model as the first fine-tuning/export baseline; reduced
precision needs its own diagnosis and replay after training. Exact scripts, checkpoint provenance, timing and
permutation-aware comparison are in [the measured review](../reviews/LOCAL_FIGURE_REGIONS_20261018.md).


## Whole-image coverage feedback and tuning implications — 2026-10-18

The later 3DCodeVerse-2M Figure 2 report requires all pixels to remain represented in the card presentation, with
panels allowed to share a card. This adds a hard presentation invariant to the earlier detection metrics. Keep
**core panel bounds**, **required context** (axes/labels/shared legends), and **presentation groups** as separate
annotations. Train the detector on panels/context; do not call a full-image box a successful split or improve an
IoU score by labeling every figure as one enormous panel. Reviewed groups may overlap to preserve shared context.

The baseline now has a reproducible geometry replay, `scripts/subfigure-coverage.py`, consuming retained inference
output without another download or model call. Of the seven FDE-Gym images, only the two-panel overview has complete
multi-crop coverage after the 2% context margin; the scatter plots cover 98.46%, the heatmap 97.75%. Four outputs
have no admitted subfigure crops (whole-image boxes are excluded). These are **pixel coverage measurements**, not
accuracy, panel recall or proof of label completeness. The overview still needs semantic/legend review. See the
[experiment](../reviews/LOCAL_FIGURE_REGIONS_20261018.md).

Fine-tuning ablations must report both detection quality and accepted presentation quality: detector alone;
detector plus OCR/context containment; and caption-assisted grouping. Keep original source bounds during resizing
and export, and replay the same outward pixel rounding used by the clients. Measure uncovered pixels exactly,
critical text cut by each individual card, omitted panels, duplicate cards and false panel associations. A split
is accepted only when its presentation union covers 100% of pixels and its required context passes inspection.
Otherwise preserve the complete figure with an explicit fallback, without another paid model request. This
mechanical guarantee is separate from semantic model quality; the fallback counts as a missed extraction.

Prefer annotation and small-detector head/last-stage tuning before a larger generative localization model. The
new feedback reinforces a **panel + context relationship** task; simply increasing detector confidence or training
on tighter boxes optimizes the wrong outcome. The authorized local GPU runs now use real and generated figures,
with a reserved final test and unresolved data-rights/annotation limits recorded above. No GPU rental, licensed
data purchase or trained-model acceptance is claimed. Local extraction remains a Mac prototype shared by
local/cloud conversations.

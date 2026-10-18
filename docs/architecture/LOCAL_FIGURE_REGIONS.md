# Local figure regions

Status, 2026-10-18: investigated with a working Mac PyTorch/Core ML experiment. No detector is bundled with the app. No physical iPhone measurements. See [measured results](../reviews/LOCAL_FIGURE_REGIONS_20261018.md). This is the design for the next prototype, not a released capability.

The owner asked for a purpose-built local model to extract subfigures and plots, shared by Figure AI Explainer and ordinary chat, regardless of the chosen cloud/local answering model. Geometry belongs on the device; explanation belongs to the chosen chat model. A small detector can locate panels without an LLM generating coordinates or receiving a whole PDF. PDFs, figure acquisition and cropping remain device-only, as in [HTML_FIRST_READER](HTML_FIRST_READER.md).

## One figure context for every conversation

The existing verified figure image, caption, numbered surrounding paragraphs and structured equations remain authoritative inputs. The proposed `FigureRegionSet` adds candidate regions to that exact image. It contains the image SHA-256, decoded pixel dimensions/orientation, detector identity and weight hash, preprocessing revision, and normalized top-left `x/y/width/height` coordinates. A stable region ID derives from those inputs and the accepted geometry, never from a model-generated title. Multiple image assets use the exact same compositing transform as the displayed figure; boxes cannot silently move to a different composite or revision.

Keep detector boxes separate from explanation claims. A candidate is a geometric region, not proof that it is panel (b), a legend, or the evidence for a particular claim. Caption labels and local OCR can help associate candidates, but unresolved associations keep the whole figure. Nested insets, shared legends and table/diagram structures need explicit representation rather than forced nonoverlapping panels. A retained region may require additional context boxes, especially a legend shared with another panel.

For a prototype, opening a figure may prepare candidates locally in a cancellable background task. Selecting a region gives the same context to the existing figure conversation or main chat: crop, a small whole-figure overview, caption, relevant numbered paragraphs, and exact LaTeX when relevant. The small overview preserves shared context without sending every PDF page. Cloud transmission still requires the existing consent and an explicit question; local detection itself uses no AI credits. A selected local text-only model cannot interpret the pixels and must say so.

The explainer and Chat retain one composer, selected model and conversation. Fullscreen offers Whole figure / Selected part. Returning from a citation reopens the saved explanation without another request. Region extraction should improve that shared context, not create a second conversation or separate credit-consuming feature. An unsure detector leaves the whole figure visible; a future manual region adjustment can be proposed with a concrete interaction before implementation.

## Storage and admission

Do not modify a verified reader bundle. Cache accepted geometry as an account-isolated encrypted sidecar using the existing local encrypted-storage conventions. Cache key includes image hash, detector hash and preprocessing revision. Derived image crops need not be persisted: reproduce them from the original image. Clear sidecars and in-memory regions with paper-content removal and account removal. No server schema, uploaded PDFs or plaintext persistent search index is needed.

Before admitting a region, validate finite coordinates, positive extent, bounds, minimum rendered detail, image identity and transform. Detect duplicate/near-identical and crossing boxes; preserve legitimate insets separately. Check that axes, tick labels, panel labels and legends needed to interpret the plot are included. OCR/text-block containment is useful here, but is not yet implemented or proven. A confidence threshold is insufficient: the tested heatmap lost labels at 0.92 confidence. When checks disagree, retain the whole figure and permit answering from it.

Bound image dimensions, concurrent work (one detector run), result count and cache size. Run inference outside the UI thread, cancel on paper/account change, and allow memory pressure to discard model/results. Model installation must use a pinned manifest/hash and verified license. Reuse the app's Local models download/error conventions if a separate download is needed. Never download another chat model merely to crop a figure.

## Verification before inclusion in a build

Build a human-reviewed corpus across ML plots, scientific diagrams, microscopy, tables, insets, shared legends, vector-rendered figures and scans. Include the owner's failed FDE-Gym crops. Split papers/authors between tuning and evaluation. Record panel recall, incorrect extra crops, IoU, exact panel association, and preservation of axes/labels/legends. A whole-figure fallback counts as a missed extraction rather than a successful split. Evaluate downstream answers with the same caption/paragraph context using both cloud and local chat, including unsupported questions.

Test the complete preprocessing/export pipeline, not just the source weights. Pin resize/letterbox rules, orientation, output decoding, NMS and original-image coordinate conversion. Replay fixtures offline on each change. Measure first use separately from steady-state, peak app memory, thermal behavior and cancellation on the intended phone once physical-device testing resumes. Mac speed is not iPhone evidence.

Distribution remains gated on a suitable license and quality. The current figpanel weights and inference tooling carry AGPL terms; they are research inputs only. Next candidates are a permissively licensed/trainable small detector and the Florence-2 plot adapter, with both base and adapter licenses checked. The research does not justify shipping the current detector as an automatic cropper.

## Fine-tuning plan, 2026-10-18 (Mac prototype; not yet trained)

The new owner direction makes local answering models Mac-only. Keep this detector experiment on Mac too; no new
model is included in the iPhone/iPad app. The localization component remains independent of the answering model,
so a selected region can feed either OpenRouter chat or Mac-local chat through the same figure conversation.

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
7. Export the selected trained checkpoint to Core ML FP16; replay identical images through source and exported
   models, including orientation and wide/tall composites. Quantize only if those results and downstream answers
   remain acceptable. Measure cold start, steady latency, peak process memory, cancellation and concurrent-reader
   behavior on Mac. No paid GPU training or dataset purchase has been started.

Proposed acceptance gate: at least 95% panel recall on the reviewed in-scope set, at least 99% retention of required
label/legend area on accepted crops, no known critical-label regression, and fewer than 2% incorrect extra crops.
Report uncertainty and per-domain counts; these thresholds are targets, not current results. A low-confidence or
containment-failing result stays on the whole figure. Only after this evaluation should detection become automatic
in the shared figure view. The next useful work is annotation and an exportable small-detector baseline, not more
unreviewed prompt/coordinate heuristics.


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
on tighter boxes optimizes the wrong outcome. The first pilot should use rights-cleared figures and generated
plots, then hold out complete paper/template families. No GPU rental, training job, licensed data purchase or
trained-model acceptance is claimed. Local extraction remains a Mac prototype shared by local/cloud conversations.

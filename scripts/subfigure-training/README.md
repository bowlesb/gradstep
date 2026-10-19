# Subfigure research training

This is an offline research pipeline, not an app model installer or a paid-provider client.
Read `docs/architecture/LOCAL_FIGURE_REGIONS.md` and
`docs/reviews/SUBFIGURE_TRAINING_20261018.md` for acceptance gates, data limitations and measured results.

The authorized host workspace is `/home/ben/science-reader-subfigures` on `ben@192.168.1.32`.
Use its project `env/`; do not modify the driver/global packages, other checkouts or unrelated workloads.
Run one GPU job at a time. No PDFs, private reader data or production credentials belong there.

- `fetch_real.py`: pinned HTTP-range extraction of public real figure images/annotations, with checksums.
- `prepare.py`: small initial real-only pilot; excludes the upstream synthetic data.
- `prepare_real.py`: source Label Studio panels/context relations plus curated singles; frozen paper/author/
  duplicate-family splits, source image/annotation hashes and attribution.
- `article_rights.py`: resumable public DOAJ/Crossref evidence. An unresolved license stays unresolved.
- `generate_plots.py`: training-only, seeded plots with renderer-derived boxes and explicit context relations.
  Rejects clipping and unintended context/panel overlap; intentional shared legends inside panels are declared.
  `--shared-layouts` adds row/column headings and shared color bars. No synthetic images enter validation/test.
- `generate_composites.py`: copies complete images from the real training split into labelled layouts, preserving
  source hashes/transforms and underlying rights. No held-out images are used; these are programmatic augmentations.
- `train.py`: official pinned RT-DETRv2 training/evaluation; image/split hashes, loss checks, bounded time and
  temperature, resumable checkpoints, immutable script/config copies, predictions and resource logs.
- `figure-ocr.swift`: Mac Vision OCR with hash/geometry binding and resumable records; run with network denied.
- `crop_policy.py`: explicit validation-only threshold/overlap/OCR-policy comparisons. Detector and delivered-crop
  measurements remain separate. Geometry/annotation-area scores are not independent critical-text review.
- `review.py`, `review_coreml.py`: static visual audit sheets bound to the source images/saved predictions.
- `ensemble.py`: validation-only two-checkpoint comparison; no ensemble has passed the quality gate.
- `compound_classifier.py`: small single/compound classification head on frozen detector features. Uses real
  training labels and validation selection only; classification accuracy is not crop/localization qualification.
- `classifier_policy.py`: validation-only combined classifier/detector comparison. A compound figure retained
  whole counts as missed panels; both the compound and complete populations must pass.
- `mathpix_sample.py`: read-only manifest sampler for the owner's existing `/home/ben/mathpix` corpus. Never
  imports its code, modifies its files/services, visits secrets or processes PDFs. Copy only its selected paths.
- `mathpix_figures.py`: on the Mac, verify that copy and render candidate regions from `build/plain.pdf` using
  the matching silver labels. The candidates are a review queue, not training truth. Preserve the original copy.
- `annotations/mathpix-panels-v1.json`: explicit visual development annotations, including source hashes,
  corrected figure bounds, panel/context relationships and deferred examples. No independent human review claimed.
- `curate_mathpix.py`: materialize those annotations into separate figure images; check source licenses,
  first/last-author and exact/perceptual cross-split overlap; preserve the original final-test bytes. Whole-figure
  bounds and panel/context bounds are separate. Only resulting images/annotations transfer to the GPU workspace.
- `test_metrics.py`: independent known-answer cases for matching, false crops, retained context, transforms and
  the containment-loss gradient. Run with the project Python environment.
- `test_curate.py`: crop-coordinate, required-context and duplicate/author-identity admission cases.
- `cohort_report.py`: fixed-threshold comparisons from saved validation predictions, separated into original
  and new arXiv cohorts. Counts required context on missed panels explicitly; never reads/scans the final test.
- `source_sample.py`, `source_html.py`: a separate, bounded, read-only **training-only** sample of saved source
  archives and exact HTML/PDF pairs. No source-project code runs, and no validation/reserved-test HTML is inspected.
- `source_figures.py`: Mac-only source-assisted review candidates. Read bounded archive members without extracting
  or executing them; match full decoded RGB SHA-256 to a unique PDF occurrence and recover printed subcaptions.
  Full-width figure captions fence the text search before filtering by panel column. These are review candidates,
  not automatic annotations: source assets may contain multiple plots, page screenshots, or omit outside headings.
- `annotations/source-panels-v2.json`: 35 additional visually reviewed training figures from 15 papers, 113 panel
  boxes and 54 required-context links. Shared headings, source-internal plots and contaminated margins required
  explicit corrections. Codex review is not independent human ground truth. `curate_mathpix.py --training-only`
  retains validation **and** final-test bytes and checks author/image conflicts against the existing cohorts.
- `test_source.py`: source/path/decoded-pixel identity, archive ambiguity, complete subcaptions and full-width
  caption-contamination regressions. PDF-dependent preparation stays Mac-only; these pure-data tests also run
  on the GPU host without a PDF processing dependency.

## Run and inspect

Run from the remote workspace. Preserve the source file actually executed, rather than editing it during a job:

```sh
cp source/training/train.py runs/example.train.py
env/bin/python -u runs/example.train.py \
  --root . --repo source/RT-DETR --data data/manifests/plots-v7 \
  --weights data/sources/rtdetrv2-s.pth --out runs/example \
  --epochs 60 --freeze-epochs 3 --backbone last --batch 8 --workers 4 \
  --lr .0002 --compound-weight 3 --selection compound --spatial-jitter \
  --max-hours 1 --patience 12
```

This is an example, not an instruction to repeat a completed experiment. Check current jobs/results first.
Run directories must be new; resume requires explicit `--resume` and the recorded last checkpoint.
The base checkpoint/repository are pinned in `train.py`. Fine-tuned initial checkpoints must match every learned
parameter shape; only declared, deterministic resolution-dependent anchor buffers may be regenerated.

`best-metrics.json`, `best-predictions.json`, `epochs.jsonl`, `provenance.json`, `resources.jsonl` and
`completion.json` contain the evidence. A best validation checkpoint is not automatically better than the
previous run, and a higher AP is not proof of complete or correct crops. Training-fit diagnostics must never
be presented as held-out performance. Training-only scale/position augmentation preserves every source pixel;
validation preprocessing stays fixed. Do not flip scientific text or crop away labels as augmentation.
Report compound and all-figure precision/recall separately. Good compound detections cannot compensate for
unwanted splits of single figures; both populations must pass the detection gate.

New domain examples may carry an explicit, bounded `sampling_weight` in their immutable training records.
The sampler multiplies that by the existing compound weight and records expected source proportions in
`sampling.json`; it never changes validation/test selection. `mathpix-v2` adds 30 training figures and 16
validation figures from separate papers, with an 8x source weight (9.59% expected training draws after the
compound weighting). The 1,728-image training set still contains the original 384 generated plots. These small,
visually selected development cohorts do not establish broad domain accuracy or replace the final test.

`source-v2` expands that frozen base to **1,763 training images**, adding 35 source-assisted figures. Its 313
validation / 235 final-test files are byte-identical to `mathpix-v2`. The 65 total new arXiv training figures
have 8x source weight: together they account for 25.10% expected draws with compound weight 3. This changes the
training distribution; it is not an unbiased sample of all archived PDFs. Keep the 384 generated examples
distinct from real papers when reporting counts. The first comparison uses v12's gentle settings and v7 start;
report the fixed .6 operating point on both original and new validation cohorts before deciding whether it helps.

The 235-image real final test remains unscored. Freeze model hash, preprocessing, threshold and crop policy before
using its explicit CLI acknowledgement. Do not tune to final-test errors and continue to call it untouched.
Failed extraction/whole-figure fallback counts as a miss. Current weights remain research-only pending source
rights, complete-label review, held-out quality and Mac runtime/cancellation acceptance.

```sh
env/bin/python -m unittest discover -s source/training -p 'test_*.py' -v
```

Core ML conversion/replay lives in `scripts/subfigure-rtdetr-export.py` and `scripts/subfigure-rtdetr-parity.py`.
A fine-tuned export requires an explicit checkpoint manifest with its hash, class list and training-data identity;
the generic COCO result cannot qualify a different checkpoint. FP32 is the measured baseline. Numerical parity,
warm prediction timing and a visually sensible screenshot are separate from app-quality acceptance.

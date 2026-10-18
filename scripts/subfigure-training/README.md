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
- `test_metrics.py`: independent known-answer cases for matching, false crops, retained context, transforms and
  the containment-loss gradient. Run with the project Python environment.

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

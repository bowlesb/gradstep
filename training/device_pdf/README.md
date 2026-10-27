# On-device PDF development

This is the current entry point and progress log for model development. Start here, then read only the linked
evidence relevant to your experiment. The app contract remains [DEVICE_PDF_ROUTE](../../docs/architecture/DEVICE_PDF_ROUTE.md).
All PDFs are processed on the owner's devices. This directory contains source and recipes, not private papers or weights.

## Current work

In progress: import the existing desktop training implementations into this repo, verify numerical parity, and
close the rejected-transcription leak described below. The selected app models remain layout-fcos-v5,
texteller-ft-v4 and inline-tagger-v5b-journal. No new weights or release are implied by a source import.

## Ranked work and measurable gates

Rank reflects likely reader impact and the evidence already available, not a universal model leaderboard.
Targets below are prospective until a baseline and a fixed evaluation set are recorded.

| Rank | Reader problem / prior work | Measurement and proposed acceptance | Approach |
|---|---|---|---|
| 1 — active | A rejected formula is displayed as its PDF crop, but the guessed transcription remains in search, copied text, accessibility and AI context. Confirmed in the [journal review](../../docs/reviews/DEVICE_PDF_PAPERS_MODEL_20261026.md). | **Zero rejected guesses in delivered text/metadata**, on every available frozen recording; accepted formulas, source crops, IDs and locations unchanged. Test image failures and budget exhaustion too. This measures trust boundaries, not recognition accuracy. | Enforce the existing acceptance decision at emission; use an explicit untranscribed-equation marker downstream. Keep raw answers only in diagnostic records. |
| 2 | Crops clip symbols or include neighboring lines. More training cannot recover ink absent from a crop. [Integrity review](../../docs/reviews/DEVICE_PDF_MATH_INTEGRITY_20261026.md). | Freeze source-reviewed cases; count clipped meaningful glyphs and foreign ink separately. Aim for **≥50% fewer bad crops**, no new missing symbol on the protected set, no text duplication. Report complete-expression success, not box IoU alone. | Inspect the existing crop-cleaning and layout experiments first; combine native glyph ownership with image bounds. Train layout only if the error precedes crop assembly. |
| 3 | Tables, captions and reading order can change scientific meaning even in papers with little math. [Table review](../../docs/reviews/DEVICE_PDF_TABLES_20261024.md), [continuity review](../../docs/reviews/DEVICE_PDF_READING_QUALITY_20261026.md). | Pairwise reading-order accuracy, missing/duplicated words, cell-to-header association and caption-to-object accuracy, macro-averaged per paper. Target **≥30% fewer reviewed severe incidents**, no content/location loss. | Extend the existing weakness explorer with source-reviewed journal examples; use held-out families. Reuse table work before introducing another parser. |
| 4 | Detecting more math increases waiting time. The journal examples took 12.8→22.2 s and 13.7→15.0 s on this Mac (single runs). | Interleaved repeated A/B: median and p95 total time, first-readable time, peak memory, failure/cancel rate; stratify by pages and formula count. Target **≥20% lower median** with identical output and no p95/memory regression. | Audit existing reuse, batching and decoder experiments. GPU training speed is not Apple inference speed. Physical-device timing remains paused. |
| 5 | Correct formulas remain images; a few accepted formulas can still be wrong. | Risk–coverage curves: source-reviewed number/operator/unit errors per 1,000 accepted expressions against typeset coverage, split by journal/arXiv/scanned. Target fewer semantic errors at fixed coverage, with paper-level uncertainty intervals. | Calibrate on fresh development families, freeze before holdout; compare constrained decoding and recognizer adaptation only after crop errors are separated. |

Additional reporting: complete-paper success, worst-decile papers, failures per 10 pages, and paper-bootstrap
intervals. Do not let thousands of easy glyphs obscure a few meaning-changing mistakes. Do not repeatedly tune on
revealed test sets. Keep threshold selection and model selection on development families.

## Existing evidence and data

- The [weakness explorer](../../docs/reviews/DEVICE_PDF_WEAKNESSES_20261024.md) already categorizes 83 papers / 2,140
  pages. Reuse its stage attribution and recorded replay; it is not a new independent holdout.
- The [journal adaptation](../../docs/reviews/DEVICE_PDF_PAPERS_MODEL_20261026.md) used 3,103 PDF candidates / 2,978
  families. Selected held-out statistics improved 0/104→99/104, with 0/103 prose controls. This is not whole-PDF accuracy.
  Run A's replay/font-dropout adaptation regressed; run B's stronger replay and teacher preservation passed.
- Header/footer and paragraph fixes already have 99-PDF conservation evidence. Do not repeat them as new work:
  [margins](../../docs/reviews/DEVICE_PDF_MARGIN_TEXT_20261026.md), [continuity](../../docs/reviews/DEVICE_PDF_READING_QUALITY_20261026.md).
- Desktop `/home/ben/science-reader-device-pdf/` holds tagger, layout, tables-work, speed-work, CoreGraphics scores
  and the mirrored Papers corpus. `/home/ben/mathpix/data/` holds existing arXiv/PMC datasets, source builds,
  recognizer/layout checkpoints and renderer benchmarks. These are local research inputs, not a Mathpix service.
  Historical source and runs remain read-only. A checkpoint called v6 is not evidence it outperforms the app's v5.
- Mac `~/gradstep-mac/corpora/papers-library-20261026` holds the copied library; existing native recordings live
  alongside the dated evidence paths linked from the reviews. No NAS access is needed.
- New evidence for this work goes under `science-reader/.artifacts/device-pdf-development/` on the Mac.
  Keep one result manifest per experiment inside that root; update this log instead of adding near-duplicate reports.

No new collection is needed for the active trust-boundary repair. For a later scan/table study, first inventory
the reserved local families; acquire additional owner-device PDFs only to fill a measured coverage gap.

## Core source and running it

`src/science_reader_pdf/` owns the three architectures/trainers, PDF glyph extraction, dataset readers and scoring.
`source-provenance.json` records the original desktop file hashes. `desktop-environment.json` records the runtime
actually used; it is an inventory, not a portable dependency lock. The separate `pyproject.toml` targets Python 3.12;
it does not alter the app's dependencies. The existing desktop environment can run this code without reinstalling:

```sh
cd /home/ben/science-reader-training
export PYTHONPATH="$PWD/training/device_pdf/src"
export SR_PDF_DATA_ROOT=/home/ben/mathpix/data
export SR_PDF_TAGGER_ROOT=/home/ben/science-reader-device-pdf/tagger
export SR_PDF_MODELS_ROOT="$PWD/.artifacts/device-pdf-development/models"
export SR_PDF_RUNS_ROOT="$PWD/.artifacts/device-pdf-development/runs"
PY=/home/ben/mathpix/.venv/bin/python
"$PY" -m science_reader_pdf paths
```

The environment supplies libraries; all `science_reader_pdf` and journal workflow code comes from this checkout.
Alternatively install `training/device_pdf` editable in a dedicated Python 3.12 environment, selecting PyTorch
for your platform (the recorded desktop uses CUDA 12.6 wheels). Keep heavyweight environments out of Git.

| Component | Entry point | Inputs |
|---|---|---|
| Journal tagger adaptation | `scripts/device-pdf-models/papers_train_tagger.py` | Research `train.npz`/`splits.json`, original `papers.json`/`data/*.npz`, parent checkpoint |
| Tagger evaluation / prediction / export | `papers_eval_original.py`, `papers_tag_predict.py`, `papers_export_tagger.py` | Explicit data and checkpoint paths; architecture is always repo-owned |
| Layout training | `python -m science_reader_pdf train-layout CONFIG.json` | Keyword arguments of `models/train_layout_fcos.py:train`; `init` can be an absolute existing model directory |
| Formula recognizer training | `python -m science_reader_pdf train-recognizer CONFIG.json` | `models/train_texteller.py:TrainConfig`; `base_model` can be an absolute existing model directory |
| Layout fine-tuning from the L1/L2 experiments | `python -m science_reader_pdf.layout.fine_tune --help` | Existing COCO exports, explicit `--init`; hard-page JSON paths are explicit |
| Historical tagger feature extraction / base training | `python -m science_reader_pdf.tagger.extract N WORKERS`, `python -m science_reader_pdf.tagger.train run NAME` | Existing instrumented source PDFs; set a **new** tagger root for extraction |
| Core ML exports | `scripts/device-pdf-models/export_texteller.py`, `papers_export_tagger.py`; `models/coreml_layout.py:export` | Existing checkpoint; Core ML numerical/reader verification still required on Mac |

The historical v5 base trainer retains its original padded/truncated batches for reproducibility. New adaptation
and scoring use complete windows and exact-length batches in the repo's journal/coverage scripts. Missing requested
NPZ files now fail explicitly. `--training-root` denotes **data only**; external `--training-source` and `--evaluator`
arguments are retired. Historical reports retain their original commands; use the current commands here.

Reproduce the selected journal recipe into a fresh directory (not the published run):

```sh
"$PY" scripts/device-pdf-models/papers_train_tagger.py \
  --root /home/ben/science-reader-device-pdf/papers-model-20261026 \
  --training-root "$SR_PDF_TAGGER_ROOT" \
  --checkpoint "$SR_PDF_TAGGER_ROOT/runs/v5a/tagger.pt" \
  --run "$SR_PDF_RUNS_ROOT/journal-reproduction" \
  --steps 10000 --save-steps 1500,4000 --lr 0.00005 \
  --replay 0.8 --font-dropout 0 --distill 4 --replay-papers 720 --replay-items 180000
```

The recipe records hashes of the actual repo source. The original dataset family splits and parent weights remain
required inputs; code being available is not a guarantee of bit-identical retraining across library/GPU versions.
For layout/recognizer JSON configs, use a new `run` name, select an absolute local parent checkpoint and specify
the existing dataset name. The CLI refuses an existing model output directory. It never provisions a service.

## Progress log

### 2026-10-26/27 — source consolidation and rejected-transcription boundary

- Audited the desktop source and prior handoffs. Core training was split between `mathpix/src/gradstep` and
  loose `science-reader-device-pdf/tagger` scripts; the newer journal scripts were already in this repo.
- Inventoried existing layout L1/L2, speed, table and CoreGraphics work. The desktop's old Science Reader checkout
  has uncommitted documentation; preserve it and create a fresh linked worktree for this revision.
- Confirmed the emitter reused `f.latex` for rejected equations' `data-latex`, sidecar, image alt and image-failure
  fallback. Acceptance must govern every delivered representation, not just whether MathML is drawn.
- Next: import the exact core source with configurable paths, check parity, measure the existing exposures and
  implement/test the emission boundary. Do not claim a new recognition-accuracy gain from this repair.

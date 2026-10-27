# On-device PDF development

This is the current entry point and progress log for model development. Start here, then read only the linked
evidence relevant to your experiment. The app contract remains [DEVICE_PDF_ROUTE](../../docs/architecture/DEVICE_PDF_ROUTE.md).
All PDFs are processed on the owner's devices. This directory contains source and recipes, not private papers or weights.

## Current work

Completed locally: the desktop training implementations are repo-owned, port 20 closes the rejected-transcription
leak, and **port 21 reduces neighboring-line contamination in inline formula fallback images**. Selected app models
remain layout-fcos-v5, texteller-ft-v4 and inline-tagger-v5b-journal. No new weights or release are implied.

**Latest result:** in the fixed 61-crop journal regression, **25 confirmed contaminated crops → 6 (76% fewer)**;
foreign dark pixels **3,255→76 (97.7% fewer)**. No source-reviewed own-line ink changes. All **60 cleaner controls /
24 papers / 57 pages** preserve their dark and gray own ink. This is a presentation repair, not improved recognition,
new held-out accuracy or recovery of already-clipped symbols. Exact scoring, failed approaches and limits are below.

**Previous result:** across **101 PDFs / 2,721 pages**, rejected guesses in delivered equation metadata
fell **4,973→0**. All **56,193 accepted formulas**, other page content, crop requests, IDs and PDF locations are
preserved. There are 97 affected papers. This prevents unverified guesses entering text consumers; it does not
mean those guesses were all wrong or improve the recognizer's accuracy. Raw diagnostic `index.json`/recordings
retain model answers and their rejection status; the delivered `reader.json` does not.

**Next task:** finish rank 2's upstream completeness problem: a tagged span may omit part of a statistic or a
detached operator before any crop cleaning. Freeze complete-expression labels on fresh reserved development families,
separate tagging/layout/text-layer causes, and compare context-aware span expansion against a tagger objective that
penalizes cut expressions. Preserve prose false-positive and accepted-math gates. Do not tune further on these two
revealed journals or start another broad recognizer fine-tune. Ranks 3–5 remain prospective.

## Ranked work and measurable gates

Rank reflects likely reader impact and the evidence already available, not a universal model leaderboard.
Targets below are prospective until a baseline and a fixed evaluation set are recorded.

| Rank | Reader problem / prior work | Measurement and proposed acceptance | Approach |
|---|---|---|---|
| 1 — verified | A rejected formula is displayed as its PDF crop, but the guessed transcription remains in search, copied text, accessibility and AI context. Confirmed in the [journal review](../../docs/reviews/DEVICE_PDF_PAPERS_MODEL_20261026.md). | **Zero rejected guesses in delivered text/metadata**, on the current 99-paper recordings plus both journal articles; accepted formulas, source crops, IDs and locations unchanged. Image failures and budget exhaustion also pass. This measures trust boundaries, not recognition accuracy. | Port 20 enforces the existing acceptance decision at emission; an explicit untranscribed-equation marker reaches text consumers. Raw answers stay only in diagnostic records. |
| 2 — contamination verified; completeness open | Crops clip symbols or include neighboring lines. More training cannot recover ink absent from a crop. [Integrity review](../../docs/reviews/DEVICE_PDF_MATH_INTEGRITY_20261026.md). | Contamination target ≥50% passed: **25→6**, own-ink loss zero, 60 protection controls pass. This measures other-line intrusions, not clipping recovery. Next: complete-expression recall with no increased prose false positives on newly frozen families. | Port 21 uses native line bounds only for presentation cleaning. Next isolate upstream incomplete spans before choosing tagger or layout training. |
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
- Prior negative results to avoid repeating: recognizer v5 (more data) and v6 (more long crops) scored 0.906/0.899
  versus v4's 0.914 on the cited display benchmark; the [field audit](../../docs/reviews/DEVICE_PDF_ROUTE_20261023.md#4-the-display-formula-recogniser-why-v5-and-v6-were-negatives-and-what-to-do-next)
  separates crop errors from recognition errors. Table row-merging, ruling-line grouping and narrower cell gaps
  regressed one or more corpora; the [table experiments](../../docs/reviews/DEVICE_PDF_TABLES_20261024.md#3-rules-tried)
  explain why. Recognition reuse reduced crop count, but its prior noisy timing comparison did **not** establish
  a speed gain. The old cross-state decoder had expensive shape transitions; current exports already use a later
  multifunction implementation. Re-read the relevant evidence before proposing these as new optimizations.
- Mac `~/gradstep-mac/corpora/papers-library-20261026` holds the copied library; existing native recordings live
  alongside the dated evidence paths linked from the reviews. No NAS access is needed.
- New evidence for this work goes under `science-reader/.artifacts/device-pdf-development/` on the Mac.
  Keep one result manifest per experiment inside that root; update this log instead of adding near-duplicate reports.

No new collection was needed for either repair. For a later scan/table study, first inventory
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

## Verification and evidence map

One current evidence root on the Mac: `/Users/benbowlwes/science-reader/.artifacts/device-pdf-development`.
On the desktop, `/home/ben/science-reader-training/.artifacts/device-pdf-development` holds the source parity,
prediction and optimizer smoke evidence. Raw data and weights remain at the older paths listed above.

| Evidence | What it establishes |
|---|---|
| `source-parity.json` | On the RTX 3090: 61,589 real glyphs / 1,185 items load identically; tagger logits are exact at lengths 2/17/64/399/400; four real crop preprocessed tensors, recognizer answers/confidences and one layout page's 300 detections match the original source. This is relocation parity, not accuracy. |
| `workflow-check.json` | Repo prediction CLI matches all 1,487 recorded journal inputs / 138,439 glyphs exactly. The repo trainer completes 12 optimizer steps with finite, changed weights. Smoke weights are not promoted. |
| Desktop `original-eval-smoke.json` | Complete-window evaluation CLI covers all 102,351 glyphs in one existing development paper; this smoke score is not a new model quality estimate. |
| `transcription/manifest.json`, `transcription/results.json` | SHA-bound 101-paper A/B against port 19. All actual model answers are available (zero replay misses), gates and diagnostic outputs identical. Only rejected delivered representations change. Replay pixels are placeholders; crop requests and asset behavior are protected, not newly judged for visual correctness. |
| `transcription/native/`, `transcription/native-check.json` | Fresh 11-page journal conversion with actual Core ML and JavaScriptCore JIT disabled: 177 blocks, 215 accepted equations, 54 rejected equations, zero rejected metadata exposures. Existing model pack; 23.6 s once, not a speed benchmark. |
| `fast-tests.log`, `evaluation-tests.log` | `npm test` passes; five Python evaluation tests pass. Four new boundary tests and the extended 600-equation image-budget test cover accepted, rejected, malformed and missing recognitions, crop failure, image alt and delivered index text. |
| `crops/gold.json`, `crops/gold-bands.json`, `crops/scored/score.json` | Frozen source/baseline review and independent source-line bands; all 61 actual CoreGraphics crop pairs at 216 dpi. Original baseline asset pixels match 61/61; 25 confirmed other-line failures become 6, own-ink RGB unchanged. Comparison sheets retain source/before/after. |
| `crops/conservation/report.json`, `crop-jobs.json` | Port 20→21: 101 PDFs / 2,721 pages, 61,166 equation decisions, all recognition requests, source bounds, trace and synthetic-pixel reader output unchanged; zero replay misses. 3,045 of 5,863 image requests gain a hint; 61 journal jobs are bound to exact local PDF hashes. This is conservation, not corpus-wide visual accuracy. |
| `crops/protection.json`, `crops/protection/final/results.json` | Deterministic 60-control sample from 24 existing source builds: stable labels across factory-v2/v3/current, prior foreign count zero. All 48 copied PDFs SHA-verified; native plain/instrumented rasters align. 16,559 dark and 33,484 visible own pixels preserved. Source-label bands test the cleaner, not native tagger bounds. |
| `crops/swift-clean-tests.log`, `crops/crop-bounds-tests.log`, `crops/fast-tests.log` | 16 Swift cleaner tests, 32 focused converter/rule tests, final 10-stage `npm test` (874 backend, 734 browser tests). Covers malformed hints, scripts, primes, operators, gray rims, composed-accent abstention and unchanged provenance. |
| `crops/native/`, `crops/native-check.json`, `crops/native-replay.log` | Fresh 11-page Core ML conversion, JIT disabled: 54 fallback image bytes exactly match scored outputs; reader index and provenance remain equal to port 20 except adapter and unique image count (57→53 after deduplication). Recorded JSC replay has zero misses. One earlier failed read-stage attempt is retained separately, not counted as a success. |

Re-run source parity only when moving/changing core training code:

```sh
"$PY" training/device_pdf/check_source_parity.py \
  --legacy-src /home/ben/mathpix/src --tagger-root "$SR_PDF_TAGGER_ROOT" \
  --data-root "$SR_PDF_DATA_ROOT" \
  --tagger-checkpoint /home/ben/science-reader-device-pdf/papers-model-20261026/run-b/step-10000.pt \
  --recognizer /home/ben/mathpix/data/models/texteller-ft-v4 \
  --layout /home/ben/mathpix/data/models/layout-fcos-v5 \
  --out "$SR_PDF_RUNS_ROOT/source-parity.json"
```

The test alone imports legacy source to compare it; production training never does. Formula render scoring needs
the existing offline `gradstep-tex:v1` image. Optional historical PaddleX benchmark helpers need their own runtime;
they are not dependencies of the three core trainers or part of the parity claim.

The transcription audit is `node scripts/device-pdf-models/audit_transcription_boundary.mjs BASELINE_CHECKOUT
MANIFEST.json REPORT.json`. Use a clean checkout of `738488db` (port 19) as baseline and the saved manifest of local
record directories; the current main branch is no longer a baseline after integration. The audit fails on missing
model answers, duplicate PDFs, changed accepted math/content/regions, any rejected exposure or an unaffected baseline.
This is a regression set with disclosed prior use, not fresh held-out mathematical accuracy. Existing saved readings
retain their old contents until explicitly regenerated; no data migration or deployment occurred.

### Reproducing the crop regression

Use a clean checkout of **738515bc** as the port-20 baseline, not the integrated current branch. Scripts are in
`scripts/device-pdf-models/`; `EVIDENCE` below is the existing local `.artifacts/device-pdf-development` root.

```sh
node scripts/device-pdf-models/audit_formula_crops.mjs BASELINE_CHECKOUT \
  "$EVIDENCE/transcription/manifest.json" "$EVIDENCE/crops/pdf-map.json" "$EVIDENCE/crops/conservation"
DevicePDFRouteTool --clean-formula-crops "$EVIDENCE/crops/conservation/crop-jobs.json"
python3 scripts/device-pdf-models/score_formula_crops.py "$EVIDENCE/crops/gold-bands.json" \
  "$EVIDENCE/crops/conservation/crop-jobs.json" "$EVIDENCE/crops/scored"
python3 scripts/device-pdf-models/score_crop_protection.py --manifest "$EVIDENCE/crops/protection.json" \
  --pdf-root "$EVIDENCE/crops/protection/pdfs" --tool /absolute/path/DevicePDFRouteTool \
  --out "$EVIDENCE/crops/protection/new-run"
```

Build the Tool from `apps/apple/ScienceReaderCore` with `swift build -c release --product DevicePDFRouteTool`.
The run used `crops/swift-build` as its scratch path. Python scorers need NumPy/Pillow; the protection scorer also
needs SciPy/PyMuPDF. They never write source PDFs. The second scorer refuses an existing run directory; use
`--score-only` for saved renders. Private PDFs and labels remain outside Git.

Gold was reviewed before candidate pixels: `gold.json` SHA256
`499770634699e132a3e697ef14f8d597cdb1592d941e7a1484b9a7b615c75540`; source-band manifest
`9a558b2fd22ca60705b9e2f3f58c7ab4f8a9df93387db5b8f7b4cd51e097e994`. The original 26 positive labels remain
recorded. Pixel review found case 32 already clean (same-line punctuation is outside the target); it is explicitly
reported as a baseline disagreement and **not counted as a repair**. The confirmed denominator is 25. A resolved
case has zero <100 dark pixels outside the independently reviewed source line. Own-ink comparison maps both
trimmed images back to original pixel coordinates and requires identical RGB for retained <192 own-line pixels.
Six residual cases (7, 19, 31, 34, 41, 47) retain small fragments. Cases 24, 54, 55 are already-incomplete detections;
this change does not repair them. All 61 source/before/after images were reviewed.

The controls' frozen manifest SHA is `41d44fd23997a05d36bddbd0f7b8333d7e4d3875a3ebd4c40ae76f2801896661`.
These are prior-used controls (56 train, 4 dev), mostly scripts/accents, not fresh scientific-article accuracy truth.
Their colored-source oracle is a proxy; geometry, native raster registration and nonempty visible ink are gated.
Synthetic tests additionally protect fractions/radicals/integrals. No claim covers scans, rotated text or display
formula improvements: those retain legacy cleaning. Existing readings require explicit regeneration.

## Progress log

### 2026-10-27 — neighboring-line crop cleanup (port 21)

- Re-audited desktop experiments before implementing. L1/L2 layout fine-tunes reduced display F1 to 0.9289/0.9296
  versus v5's 0.9399 (v6: 0.9426); their overall F1 also failed to beat the selected baseline. Reuse this evidence,
  not their run names, when deciding whether to retrain. Old masked-benchmark labels drifted: only 3/37 proposed
  contamination examples survived later label checks. Selected stable preservation controls instead.
- Froze all 61 journal fallback crops and source-only line bands. The old cleaner treated interior foreign ink as
  part of the formula and canceled removal when small statistics contained less ink than their neighboring line.
- Added an optional absolute 216 dpi protected line band. Same-line neighboring glyphs, detached scripts and
  partial punctuation are preserved across the full crop width. Displays, OCR, rotations, vertically clipped
  neighboring glyphs and crops overlapping actually composed accents abstain. Recognition inputs stay unchanged.
- Rejected first implementation: abstaining for any horizontal neighbor yielded only 2/61 hints. Full-width
  protection addresses the stated other-line target without erasing same-line punctuation. The first pixel rule
  removed 81.4% of foreign ink but left 19 contaminated crops, failing the ≥50% complete-cleanup gate. Loose font
  ascent boxes still overlapped descenders. Reused the existing <0.45-em edge-tail size limit and required those
  tails' midpoints outside the band; final confirmed failures fall 25→6 with no own-ink RGB changes.
- Code review caught composed accents emptied before band calculation. Added a narrow actual-composition guard,
  including integer crop rounding, with failure-first macron and adjacent-line tests. This removes 57 hints from
  the corpus (3,102→3,045) while leaving the 61 journal jobs byte-identical. Prior attempts are summarized in
  `crops/attempts`; they are not alternate current results.
- Copied (never moved) 48 plain/instrumented PDFs from the GPU desktop: 170,370,168 bytes total, exact SHA matches.
  No NAS access or new collection. An initial <90 registration check falsely flagged gray/antialiased ink; retained
  all 60 controls, verified source alignment and added a stricter <245 visible-own-ink preservation gate. Both pass.
- Final conservation, fast tests, native image pairs and protection controls pass. No weights, recognition gates,
  reader interactions, PDF source locations, services or released binaries change. Continue with upstream span
  completeness on fresh reserved families; do not turn this known-case result into a general accuracy claim.
- Fresh native conversion initially failed after `read 4/11` with `device_pdf_internal` / `[object Object]`, before
  image emission. Saved the failed log; recorded no-JIT replay passed, a diagnostic wrapper exposing existing bounded
  error detail passed, then the unmodified compiler passed (21.3 s once; no timing claim). All 54 resulting fallback
  images exactly match the pixel audit. Cause remains unresolved; native tagger retry exhaustion is only a hypothesis.
  If it recurs, capture compiler `detail` and the failing host stage rather than rerunning blindly. This is not a
  reliability fix or evidence of zero import failures. The generated bundle's existing template-literal whitespace
  makes `git diff --check` warn; compiler freshness is the authority for this generated file.

### 2026-10-26/27 — source consolidation and rejected-transcription boundary

- Audited the desktop source and prior handoffs. Core training was split between `mathpix/src/gradstep` and
  loose `science-reader-device-pdf/tagger` scripts; the newer journal scripts were already in this repo.
- Inventoried existing layout L1/L2, speed, table and CoreGraphics work. The desktop's old Science Reader checkout
  has uncommitted documentation; preserve it and create a fresh linked worktree for this revision.
- Confirmed the emitter reused `f.latex` for rejected equations' `data-latex`, sidecar, image alt and image-failure
  fallback. Acceptance must govern every delivered representation, not just whether MathML is drawn.
- Imported source in `738488db`; no original dataset or checkpoint moved. Created the desktop training worktree;
  original checkout/documentation preserved. Source/prediction parity and the optimizer/evaluation smoke checks pass.
- Port 20 applies the existing acceptance decision to `data-latex`, `reader.json`, block excerpts, image alt and
  missing-image text. It preserves the original diagnostic trace for honest model scoring. The 101-paper gate
  passes: 4,973→0 exposures, 56,193 accepted formulas unchanged. Fresh native conversion confirms the boundary.
- Rejected implementation detail: plain human text in a `reader-math-fallback` violates the existing bundle contract.
  Kept its LaTeX-shaped placeholder instead of broadening the shared validator; image alternatives use plain words.
  The budget regression also caught a test mistakenly matching the letter `q` inside “Equation”; corrected it to
  match a whole token. No product assertion was weakened.
- Routine gate initially lacked this worktree's browser dependency link; linked the existing installation and
  reran successfully. An old October 15 native binary rejected newer CLI arguments; used the already-built current
  journal host. These were setup failures, not successful checks.
- Next: freeze the crop-error denominator for rank 2 and compare native boundaries before deciding whether a
  layout model change is justified. Keep app weights fixed until a measured candidate passes the promotion gates.

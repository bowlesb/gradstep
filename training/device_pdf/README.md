# On-device PDF development

This is the current entry point and progress log for model development. Start here, then read only the linked
evidence relevant to your experiment. The app contract remains [DEVICE_PDF_ROUTE](../../docs/architecture/DEVICE_PDF_ROUTE.md).
All PDFs are processed on the owner's devices. This directory contains source and recipes, not private papers or weights.

## Current work

Completed locally: repo-owned training, the port-20 rejected-transcription boundary, port-21 crop cleanup, and
**independent on-device recovery when Core ML repeatedly returns invalid tagger output**. The selected learned
models remain layout-fcos-v5, texteller-ft-v4 and inline-tagger-v5b-journal at threshold 0.65. The pack now includes
1.20 MB of the same tagger weights for a separate CPU implementation. That recovery uses the existing checkpoint;
the new research below trained candidates without promoting them.

**Model protection:** Apple keys, the encrypted reference-weight carrier, asynchronous loading and release checks
are implemented. Full-pack encryption remains blocked by the encrypted stateful recognizer on this Mac; the
explicit-cache workaround exceeded baseline memory by at least 5.835 times and was rejected. Do not substitute
plaintext in a release or infer complete-pack success from the carrier. The
[runtime walkthrough and encryption evidence](../../docs/architecture/DEVICE_PDF_ROUTE.md) explain the full path,
the minimal reproduction and the next bounded research direction. The canonical evidence directory is
`.artifacts/device-pdf-development/encryption/`; no failed encrypted pack replaces the usable local pack.

**Latest research result — no model promotion:** a new source-reviewed benchmark contains **468 complete
single-line expressions / 165 prose controls**, from 72 previously unaudited development families. Expanded training
labels repair 7 of 20 incomplete expressions; adding a whole-expression objective repairs 9, with no new errors on
those labels or prose controls. Both candidates nevertheless fail the original-corpus recall-preservation gate
on **399 papers / 30,803,703 glyphs**, so the selected app weights and threshold remain unchanged. A separate
rule-based decoder also failed its confirmation gate and introduced two wrong boundaries. The measured results,
reusable training code, and unused final reservation are described under [Span completeness](#span-completeness).

**Verified runtime result:** all **2,029 inputs / 188,464 glyphs** run successfully through the independent implementation,
with **zero tagging-decision disagreements** against frozen PyTorch output. Forcing both Core ML attempts to fail
on each input gives **2,029/2,029 successful recoveries** through the production policy. Recovery takes **1.23 ms
median / 1.52 ms p95** on this Mac. These are runtime parity and injected-failure results, not whole-import success
rates or new scientific-article accuracy. Two fresh native imports preserve all **330 blocks / 302 equations /
22 pages**, including PDF locations and real figure images; neither needed recovery. The original opaque failure's
exact cause is still unproven. A paired experiment separately reproduced six exhausted Core ML retries.

**Crop result:** in the fixed 61-crop journal regression, **25 confirmed contaminated crops → 6 (76% fewer)**;
foreign dark pixels **3,255→76 (97.7% fewer)**, with zero own-line ink changes and all 60 preservation controls passing.
This repairs presentation, not recognition or already-clipped symbols. Exact scoring and limits are below.

**Previous result:** across **101 PDFs / 2,721 pages**, rejected guesses in delivered equation metadata
fell **4,973→0**. All **56,193 accepted formulas**, other page content, crop requests, IDs and PDF locations are
preserved. There are 97 affected papers. This prevents unverified guesses entering text consumers; it does not
mean those guesses were all wrong or improve the recognizer's accuracy. Raw diagnostic `index.json`/recordings
retain model answers and their rejection status; the delivered `reader.json` does not.

**Next task:** diagnose the original-corpus recall losses before proposing another adaptation. The two fixed
span-training runs are finished and rejected; do not widen that experiment, tune its threshold, or open the reserved
final cohort to rescue it. A new retention-focused experiment needs its own fixed budget and preservation gate.
Do not tune further on the two revealed journals or start another broad recognizer fine-tune. Ranks 3–5 remain
prospective. The CPU implementation
is also a candidate for rank 4, but changing the primary backend needs an interleaved complete-import benchmark
and broader decision-parity checks; its isolated-call speed is not evidence of faster complete imports.

## Ranked work and measurable gates

Rank reflects likely reader impact and the evidence already available, not a universal model leaderboard.
Targets below are prospective until a baseline and a fixed evaluation set are recorded.

| Rank | Reader problem / prior work | Measurement and proposed acceptance | Approach |
|---|---|---|---|
| 0 — verified recovery | An invalid tagger buffer can abort the entire import after the existing retry. Diagnostics previously collapsed to `[object Object]`. | Actual paired workload: 6 retry exhaustions. Independent implementation: zero invalid outputs or threshold disagreements on 2,029 inputs; production policy recovers all 2,029 forced failures. No measured whole-import failure-rate claim. | Keep Core ML first and its one retry, then evaluate the identical checkpoint once with a separate CPU GRU; validate output or fail. Preserve bounded stage/page/line diagnostics. |
| 1 — verified | A rejected formula is displayed as its PDF crop, but the guessed transcription remains in search, copied text, accessibility and AI context. Confirmed in the [journal review](../../docs/reviews/DEVICE_PDF_PAPERS_MODEL_20261026.md). | **Zero rejected guesses in delivered text/metadata**, on the current 99-paper recordings plus both journal articles; accepted formulas, source crops, IDs and locations unchanged. Image failures and budget exhaustion also pass. This measures trust boundaries, not recognition accuracy. | Port 20 enforces the existing acceptance decision at emission; an explicit untranscribed-equation marker reaches text consumers. Raw answers stay only in diagnostic records. |
| 2 — contamination verified; completeness candidates rejected | Crops clip symbols or include neighboring lines. More training cannot recover ink absent from a crop. [Integrity review](../../docs/reviews/DEVICE_PDF_MATH_INTEGRITY_20261026.md). | Contamination **25→6**, own-ink loss zero, 60 controls pass. New completeness benchmark: **448/468** selected-model baseline; two training candidates **455/468 / 457/468**, both 0/165 prose FP. Both lose original-dev recall beyond the fixed 0.01 percentage-point allowance. | Port 21 remains selected. Keep the measured span failures and whole-expression supervision/objective; solve retention before another candidate. Rejected scalar expansion remains research-only. |
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

No new collection was needed for these repairs. For a later scan/table study, first inventory
the reserved local families; acquire additional owner-device PDFs only to fill a measured coverage gap.

## Span completeness

This work is isolated on `codex/pdf-span-completeness`, starting at `c0be647b`. Mac evidence is under the main
checkout's `.artifacts/device-pdf-development/spans/`; desktop training evidence is under the same relative path in
`/home/ben/science-reader-training`. The desktop source worktree is `/home/ben/science-reader-pdf-span-completeness`.
Historical checkouts, NAS data, app model packs and the physical phone were not changed.

### Measurement and rejected decoder

The initial 24-family sample was split into 12 diagnosis and 12 confirmation families before predictions. Source
review froze 128 complete expressions and 69 prose controls. A single fixed extension added 48 different families,
340 expressions and 96 controls. Family selection used only the existing development split, source page statistics,
and seeded hashes, excluding the 16 previously audited development families. The resulting 468 positive expressions
occur in 54 papers. There are three non-scientific library prose controls; this is a selected-expression benchmark,
not full-paper accuracy. Cross-line expressions, displays, unextracted glyphs and all unannotated math are outside
its denominator. Unlabeled math is never counted as a false positive.

Every positive and control crop was source-reviewed before that cohort's first tagger predictions. Review repaired
proposal ends that omitted uncertainty, powers of ten, or chained comparisons, and added source-visible relations
such as multi-letter statistics. Retain native glyph identities even when embedded fonts misname symbols. The
selected error glyphs exist in their native lines; all extension error pages have `ocr:false`. This establishes
tagging/identity/typography failures, not an OCR-fallback, missing-ink or line-ownership diagnosis.

`decoder-result.json` is the entry point for the rejected relation decoder. Diagnosis improved **65→69/69**, but
first confirmation stayed **58/59**. The predeclared extension produced **325→327/340**; combined confirmation
was **383→385/399**, or **16→14 incomplete expressions (12.5% reduction)** against a ≥30% gate. The minimum
eight-error denominator was satisfied. All 130 confirmation prose controls remained negative, yet reviewing every
changed line found two harmful completions of `F’s < …` into `s < …`. Pure-prose controls alone would miss this
boundary error. The prototype is preserved in `scripts/device-pdf-models/relation_completion.ts`, explicitly outside
the reader; `audit_relation_completion.mjs` records decoded spans separately without fabricating model logits.

Prior work was checked first: broad touching-glyph expansion, larger context, recognizer arbitration and cross-line
merging already had negative results. Ordinary boundary weighting also existed in the base trainer. The new training
objective below emphasizes the weakest positive glyph in an entire labeled expression, rather than repeating those
approaches.

### Two fixed training arms; both rejected

The existing 200-family native training audit supplied **194 usable training papers / 15,879 windows** after proposal
filtering. `papers_statistics_labels.py --complete-expressions` adds multi-letter statistics, powers of ten, uncertainty,
fractional degrees of freedom and chained comparisons. Mixed-line glyphs outside proposals remain **unknown**;
only conservative pure-prose lines supply negative labels. Neighbor context remains unknown. This yields **3,391
partial positive proposals / 25,974 positive glyphs / 712,956 negative glyphs**, not fully labeled training pages.

A frozen source-review sample selected 96 changed/new proposal lines by `span-training-review-v1` hash, at most four
lines per paper: **118 spans from 46 training papers**. Of these, **116 matched the source**; two had uncertain crop
alignment. Both entire rows were excluded before packing, removing five proposals in total. The 116/118 result is a
sample audit, **not verification of all 3,391 proposals**. `training/supervision-review.json` records the exact IDs.

Both arms start from selected `inline-tagger-v5b-journal` checkpoint
`d705b191ddd7eb33cc36cbf8e47e71c1363e5389fb41dbea3936720858188d0c`. The frozen
`training/plan.json` specifies **6,000 steps each**, learning rate `2e-5`, 80% original-training replay from 720 papers,
180,000 replay items, no font dropout, teacher weight 4 on replay, and teacher weight 1 on unknown native own-glyphs.
Seed is 2711; threshold stays 0.65. Only each final checkpoint is evaluated. Exact-length batching and the architecture
are unchanged. The arms differ only in `--complete-span-weight`: zero versus 0.5. The latter adds the mean maximum
positive logistic loss per contiguous labeled expression; unknown glyphs never acquire a negative target.

| Evaluation | Selected baseline | Expanded labels | Labels + whole-expression objective |
|---|---:|---:|---:|
| Complete expressions, now-revealed development | 448/468 | 455/468 | 457/468 |
| Incomplete expressions | 20 | 13 | 11 |
| Existing incomplete expressions repaired / newly broken | — | 7 / 0 | 9 / 0 |
| Prose controls detected | 0/165 | 0/165 | 0/165 |
| Original-dev glyph precision, all content | 96.79% | 96.86% | 96.84% |
| Original-dev glyph recall, all content | 94.62% | 94.53% | 94.54% |
| Original-dev inline-text glyph recall | 96.14% | 96.04% | 96.05% |
| Original-dev exact-span F1, all content | 83.95% | 84.07% | 84.06% |

The 399-paper original-development check covers **30,803,703 glyphs / 250,995 gold spans**, including 134,097
inline-text spans. The fixed maximum recall loss was **0.01 percentage point**. Actual losses of **0.09 / 0.08
percentage point** fail that gate despite improved precision and span F1. These are the existing scorer's rounded
metrics; the losses are well outside rounding uncertainty. No threshold search or additional training arm followed.

Paired paper bootstrap on the new development benchmark uses 54 positive-gold papers, 10,000 resamples, seed 2711.
The expanded-label complete-recall gain is **1.50 percentage points** (95% interval **0.40–3.01**); the whole-expression
gain is **1.92 points** (**0.57–3.67**). Relative incomplete reductions are 35% (interval 11.1–60.0%) and 45%
(22.7–61.9%). These are development intervals after candidate selection, not independent confirmation claims.
The extra objective repairs only two additional examples in one paper; it is not a demonstrated general improvement.
Candidate comparisons use the same PyTorch backend for baseline and both arms. The independent native reference
gives identical labeled scores, with three threshold differences among all 927,445 glyph outputs (including context).
This broader check is recorded separately; it does not extend the earlier 2,029-input zero-disagreement claim.

**Decision:** retain selected production weights. `training/result.json` summarizes the completed experiment;
`training/original-dev-full.json` and each arm's `development-score.json` contain its detailed evidence. The fixed
48-family / 96-page final reservation in `training-confirmation/selection.json` remains **unscored**: native source
extraction/layout ran, but no final gold review or tagger predictions were opened after both arms failed preservation.
Do not consume it to rescue these candidates. No Core ML export or native reader promotion was attempted.

Reusable checks: `test_complete_expression_training.py` verifies masked supervision and objective gradients in the
recorded PyTorch environment; `test_papers_evaluation.py` verifies completeness, prose spill, explicit decoder outputs
and paired paper bootstrap. `papers_score_statistics.py --baseline …` computes the intervals without modifying logits;
`papers_review_crops.py --include-prose` renders control sheets. `npm test` and the focused research checks pass.

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
| Independent CPU tagger export | `scripts/device-pdf-models/export_tagger_reference.py` | Explicit trusted checkpoint and exact app vocabulary, both pinned by SHA-256; unchanged weights, native parity required |
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
| `reliability/manifest.json` | Single summary of frozen plans, identities, final source revision, report hashes and integration/pack verification. |
| `reliability/buffer-probe/`, `reliability/paired/` | Three buffer readers agree on the reproduced all-zero result. 81,160 primary native calls compare FP16/FP32, quiet and under CPU load; 22/18 invalid primaries and 3/3 retry exhaustions. No established FP32 reliability gain. Raw attempts retained. |
| `reliability/reference/native-score.json`, `reliability/reference/policy-check.json` | Actual CPU parity on 2,029 inputs; zero invalid outputs or threshold flips. The latter forces two invalid buffers for every input through the production helper and recovers all 2,029. Existing journal score stays 99/104 complete statistics, 0/103 prose controls (`reliability/reference/statistics-score.json`). |
| `reliability/native-check.json` | Two fresh native conversions, no JIT: 22 pages, 330 blocks, 302 equations; no content/gate/location/real-figure changes, recognition failures or replay misses. No recovery was needed; this checks healthy-path conservation. |
| `reliability/recovery-tests.log`, `reliability/fast-tests.log`, `reliability/reference/ios-typecheck.log` | 31 focused release Swift tests (including full private recovery corpus), all 10 `npm test` stages, and arm64 iOS 18 Simulator typecheck of the CPU helper pass. Typecheck is not a Simulator journey or physical-device test. |
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

### Reproducing native reliability checks

`reliability/manifest.json` binds the reports and source; `plan.json` and `recovery-plan.json` preserve the gates
chosen before their results. Use a fresh output directory for repeated experiments. Private inputs and trained
weights stay outside Git. The committed tiny H=2 fixture is synthetic and tests the GRU equations separately.

```sh
EVIDENCE=/Users/benbowlwes/science-reader/.artifacts/device-pdf-development
DEVICE_PDF_RECOVERY_CORPUS="$EVIDENCE/reliability/recovery-corpus.json" \
  swift test -c release --package-path apps/apple/ScienceReaderCore \
  --filter 'DevicePDF(Error|Host|ReferenceTagger|ReferenceRecoveryCorpus)Tests'
DevicePDFRouteTool --tag-reference-inputs /absolute/path/to/inputs.json \
  --reference-manifest /absolute/path/to/tagger-reference.json \
  --reference-weights /absolute/path/to/tagger-reference.bin --out /new/path/predictions.json
```

The opt-in corpus configuration names `inputs`, `gold` (frozen PyTorch), `manifest`, `weights` and `report` paths.
Copy that configuration and change `report` when preserving an earlier result. Without the environment variable,
the private corpus case explicitly skips; the remaining focused cases need no private data. The selected reference
export is `~/gradstep-mac/inline-tagger-v5b-journal-reference/`. For a new export:

```sh
python scripts/device-pdf-models/export_tagger_reference.py \
  --checkpoint /trusted/path/step-10000.pt --checkpoint-sha256 EXPECTED_CHECKPOINT_SHA256 \
  --vocab apps/apple/DeviceModels/tagger-vocab.json --vocabulary-sha256 EXPECTED_APP_VOCAB_SHA256 \
  --out /new/path/reference-export
```

Selected checkpoint SHA: `d705b191ddd7eb33cc36cbf8e47e71c1363e5389fb41dbea3936720858188d0c`; exact app vocabulary:
`02887629cd17b6d51699310b0d201a9f7a301731a1314858b85e75aed3a79e77`. The raw Python export's differently formatted
vocabulary has a different hash; do not substitute it. Binary SHA:
`54c00488b893fbc7e9cf5e305e50a8c7ed9b9a8503c73a4e62374dcaf79b9eb7`.
`scripts/device-models.mjs` verifies the reference and Core ML export name the same checkpoint, checks the lock and
exact app vocabulary, and builds the local pack. Never use `--update-lock` to bypass an unexplained mismatch.

For paired Core ML experiments, compile `scripts/device-pdf-models/audit_tagger_runtime.swift` with
`swiftc -O`, then pass the positional arguments `BASELINE.mlmodelc CANDIDATE.mlmodelc INPUTS.json REFERENCE.json
OUTDIR`, followed by `--passes 10 --warmup 16 --phase quiet` (or `cpu-load`). `papers_export_tagger.py --precision float32` is available
for reproducing the rejected candidate; default FP16 and the selected primary model remain unchanged. Runtime
failure measurements do not estimate complete-import failure rates without a separately designed paper-level run.

## Progress log

### 2026-10-27 — native runtime recovery verified

- Prioritized the unresolved import failure before span training. Existing code already serialized tagger/recognizer
  predictions and retried invalid tagger buffers once. Prior failures included all-zero and partially zero output;
  repeating those mitigations would not address exhausted retries.
- Fixed definite diagnostic defects: Swift stringified the compiler's bounded `{code, detail}` as `[object Object]`,
  and `try?` discarded the tagger error. The bridge now retains bounded own string fields without invoking getters,
  records deterministic numeric page/line/glyph counts and whitelisted reasons, and leaves UI error codes stable.
  It never includes input text, paths, arbitrary native error descriptions or logits in these details.
- Rejected stale-stride diagnosis: 798 fresh allocations were dense; all three readers agreed on one all-zero
  result among 6,090 sequential predictions, with no stride changes or out-of-bounds reads. That result came from
  model output, and the existing retry recovered it. This did not identify the original opaque import's cause.
- Tested identical-weight FP32 Core ML before promoting anything. `plan.json` froze 20,290 primary calls per
  precision in each quiet/two-worker CPU-load phase, using the existing 2,029-input PyTorch reference. Across
  **40,580 calls per precision**, FP16 had 22 invalid primaries and FP32 18; **each exhausted its retry three times**.
  Paired exact p=0.618: no established reliability improvement. FP32 removed two unique false-math threshold
  disagreements and was modestly faster, but is **not selected** as the reliability fix. Prewarming alone is also
  unsupported: failures occurred after early calls. The workers were stopped; raw attempts remain under `paired/`.
- Froze `recovery-plan.json`, then added an independent Accelerate CPU implementation of the same two-layer
  bidirectional GRU. Healthy Core ML results and the existing single retry remain unchanged. Only two invalid
  buffers trigger one independent evaluation; invalid recovery still fails. Thrown Core ML errors still propagate.
  Finite but incorrect logits that pass the existing guard do not trigger recovery.
  No placeholder prose logits, new weights, changed threshold or silent math removal. A local counter records use.
- SHA-bound manifest, exact app vocabulary and binary bind recovery to the selected Core ML checkpoint. Loader
  rejects wrong shapes, overlapping/missing tensors, nonfinite weights and invalid inputs. Old packs without this
  optional reference retain their prior behavior. New packs add 1,196,996 binary bytes and reference provenance.
- Native parity passes all 2,029 inputs / 188,464 glyphs (102,290 own glyphs): zero invalid outputs or threshold
  disagreements. Mean/max absolute logit error is 0.000347/0.010852, so this is not bit-identical inference. All
  six observed exhausted-retry events (five unique inputs) produce valid matching decisions independently.
  Median/p95 recovery is 1.23/1.52 ms; weights load in 7.8 ms on this Mac, not a phone performance claim.
- Production-policy fault injection makes 4,058 invalid Core ML calls and recovers every one of the 2,029 inputs,
  with zero threshold disagreements. The previously selected journal test remains 99/104 complete statistics and
  0/103 prose false positives. This is conservation on prior-used data, not new held-out semantic accuracy.
- Final gates: 31 focused release Swift tests, routine fast gate, CPU helper's iOS Simulator typecheck, and two
  fresh whole-article native imports pass. Across 22 pages, text, 302 equation decisions, PDF places and real figure
  bytes match prior results; 2,287 recorded tag arrays are unchanged. Both imports used zero recoveries, so they
  establish healthy-path conservation only. The original opaque failure remains unattributed; the measured invalid
  buffer class is now recoverable. No server work, NAS, physical phone, interaction change or release.

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

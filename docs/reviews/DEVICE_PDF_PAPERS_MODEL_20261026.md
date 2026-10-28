# Journal-PDF model adaptation — 2026-10-26 PDT

Status: locally verified; selected for the experimental on-device model pack. No TestFlight upload or deployment.
Base code: `83867423`, converter port 19. Training ran on the owner's RTX 3090 desktop; native validation ran on
this Mac. The original PDFs stayed on the owner's devices. No NAS access, paid model call or physical-phone work.

## Problem and outcome

The v5a inline-math tagger relies heavily on fonts represented in its original training. It fails to capture
complete statistics in journal fonts such as Berkeley and OneGulliver. Ordinary `F(2,30)=103.65` remains plain
text; more seriously, an unnamed comparison glyph can appear to the reader as `P(cid:3).001`. A complete detected
region lets the existing recognition/verification pipeline typeset the statistic or retain its original PDF image.

The new **inline-tagger-v5b-journal**, threshold **0.65**, retains the existing architecture and vocabulary:
two-layer bidirectional GRU, hidden size 96, twelve numeric features and font/character embeddings, 24 glyphs
of adjacent-line context, maximum input length 400. It is an on-device component, not a remote language model.
Layout and formula-recognizer weights, converter rules and reader interactions are unchanged.

| Frozen evaluation | v5a at 0.7 | v5b-journal at 0.65 |
|---|---:|---:|
| Complete selected held-out statistics | 0/104 | **99/104 (95.2%)** |
| Mean per-paper recall, 15 papers with statistics | 0% | **91.1%** |
| False detections in reviewed prose controls | 0/103 | **0/103** |
| Original 30-paper regression: cut/edge-cut/split errors | 682 | **533 (−21.8%)** |
| Same errors in prose lines | 554 | **424 (−23.5%)** |
| Original regression glyph precision | 98.27% | **98.30%** |
| Original regression glyph recall | 96.83% | **96.82%** |
| Original regression exact-span F1 | 83.78% | **84.38%** |

The original regression contains 2,222,698 glyphs and 24,908 labeled spans. The new journal score is recall of
selected, source-reviewed, single-line statistics—not general PDF accuracy, mathematical correctness, or a
representative estimate across all sciences. The separate original regression has been used in earlier model work;
only the new journal holdout was unopened until this checkpoint and threshold were frozen.

## Corpus, supervision and separation

The copied archive has 3,393 PDF-named source files, 3,109 unique byte sequences and 31 catalog snapshots.
Six unique files are HTML/error responses; the **3,103 PDF candidates contain 69,202 pages**, with no parse
exceptions in the profile, 11 repaired PDFs and 6,132 pages with fewer than 100 extracted characters.
Catalog metadata was recovered for 3,085 unique files. This collection mainly covers neuroscience/psychology.
Originals and catalogs are immutable research inputs outside Git; nothing is migrated into the product database.

Connected components unite normalized DOI, distinctive title, complete normalized text and first-two-page text
before a deterministic 80/10/10 family split. There are **2,978 families**: training 2,397 (2,494 files), development
289 (297 files), test 292 (312 files). There are 104 multi-file families. Matching titles/DOIs against all 3,600
readable original tagger-training metadata records found zero matches. Missing identifiers and changed editions
can still hide near duplicates; this does not establish absence from every component's pretraining.

Native extraction sampled 351 pages from 200 training families, selected by metadata, text statistics and font
diversity. Partial supervision from 194 families supplies **2,937 proposed statistics**, 22,841 positive glyphs
and 764,056 negative glyphs in 15,699 windows. These are conservative **weak training labels**, not evaluation
truth. Unknown glyph positions and adjacent-line context are excluded from the training loss.

Development uses 95 visually reviewed expressions and 96 text-reviewed prose controls across 16 families.
The separate test selection was fixed before candidate predictions: 24 pages from 24 families, yielding 104
reviewed statistics in 77 lines from 15 families and 103 prose controls, with **21 families represented in the
final labels**. Positive proposals were checked against source-only rendered crops. Two incomplete exponent
proposals were extended to include the superscript −4; one variable-containing prose proposal and one garbled
line were excluded before freezing. The label record keeps these changes. Coordinate triples and cross-line
expressions are outside the primary metric. The statistic can be part of a larger valid mathematical span, but
swallowing a labeled prose word does not count as a complete detection.

## Training and model selection

Run A fine-tuned with 60% original-data replay and font dropout. Although it recovered 94/95 development
statistics, the full original development corpus exposed unacceptable regressions. Three checkpoints, conservative
weight interpolations and threshold calibration were evaluated on development only; Run A was rejected.

Run B starts again from the frozen v5a parent. It combines new partial journal supervision with **80% replay**
from 720 original training papers (180,024 complete sequences) and a **distillation loss weighted 4** against the
frozen parent's predictions. This teaches journal patterns while constraining drift on existing inputs. AdamW,
learning rate 0.00005, weight decay 0.01, positive-label weight 2, gradient clipping 1, seed 727, no font dropout;
10,000 steps, checkpoints at 1,500, 4,000 and 10,000. Batches group equal lengths and never pad backward-GRU context.
Replay uses neither original development/test papers nor new development/test families.

Run B recovers 93/95 development expressions with zero detections in 96 controls. Selection uses all **399
original development papers / 30,803,703 glyphs**, not just the initial 50-paper screening sample. Step 10,000 at
0.65 gives the fewest cut/split errors among tested candidates satisfying the original precision/recall gates:
4,197 → 3,897 (−7.1%); glyph precision 96.86% → 96.79%, recall 94.61% → 94.62%. The checkpoint and threshold were
frozen at **2026-10-27 03:08:08 UTC**, before test predictions. Neither was adjusted after seeing test results.

Predeclared acceptance: held-out complete recall at least 80%, improvement at least 30 percentage points,
mean per-paper recall at least 75%, prose-control false-positive line rate at most 1%; original glyph precision
and recall drops at most 0.3 percentage points and cut/split increase at most 3%. Both all-item and prose-only
original checks pass. All-off/all-on negative controls respectively fail recall and prose specificity. Five small
evaluation tests cover window stitching, context exclusion, partial/overgrown spans, invalid output and transitive
duplicate grouping.

## Apple runtime and actual reader checks

The fp16 Core ML export keeps the iOS 18 deployment target and the existing input contract. On **1,487 actual
held-out inputs / 138,439 glyphs**, Core ML differs from PyTorch on four threshold-adjacent glyph decisions;
maximum absolute logit difference is 0.0897 or less and mean is about 0.0152. The complete-statistic/prose-control
scores remain **99/104 and 0/103**. This is measured agreement, not bit-identical inference or physical-phone timing.

The audit found and fixed two host issues required for reliable model use:

- Glyph extraction previously used absolute MediaBox offsets while rasterization normalized the displayed
  CropBox. Forty of the 200 selected training papers had nonzero MediaBox origins. Extraction now normalizes
  the crop origin once, applies rotation, and excludes wholly off-crop glyphs. Training/evaluation were regenerated
  after this repair. Both baseline and candidate use the corrected host, so the model gain is measured separately.
  An independent raster test checks shifted/inherited MediaBox, smaller CropBox and all four rotations; the
  original exact glyph fixture still passes.
- One Core ML call returned 32 valid logits followed by 35 zeros; a repeat returned ordinary negative logits.
  The existing all-zero-buffer retry now also rejects runs of eight exact zeros, while permitting isolated zeros.
  It retries once on the same worker instance, then fails explicitly if output stays invalid. The final full
  inference run no longer has the large buffer discrepancy. The recorded first attempt remains available.

Two complete 11-page journal PDFs ran through the actual Core ML reader with JavaScriptCore JIT disabled:
*Altered Cortical Network Dynamics* (Berkeley fonts, unnamed comparison glyphs) and *Ventrolateral prefrontal
cortex and self-initiated semantic elaboration during memory retrieval* (OneGulliver, shifted page origin).
All **330 text blocks**, their ordering, figure images and PDF source locations are conserved. The checker
reconstructs each new formula from the original native glyphs at its claimed rectangle, then compares every
normalized text block, including tables, captions and references, against baseline.

Actual complete-reader regions contain 46/47 and 12/12 selected statistics respectively. All nine reviewed
CID-containing statistics have complete regions and no exposed CID token in the recovered expression. The existing
recognition guard correctly keeps several incorrectly transcribed comparisons and `F(1,15)` as source images.
Across the entire Berkeley article, exposed CID strings fall 50 → 20; symbols outside the recovered math remain.
Visual inspection includes source contact sheets and actual generated reader paragraphs, not just model logits.

Mac conversion timings, one final run each excluding model load: **12.8 → 22.2 seconds** and **13.7 → 15.0 seconds**.
Detecting more math invokes the recognizer more often. These are individual timings, not a device benchmark.
Fast tests (`npm test` / `test:fast`), 19 focused Swift text-layer/host tests and the five evaluation tests pass.

## Identity, local artifacts and reproduction

- Parent checkpoint: `786c1d91496742adb2193ee8c285bc72225e77e72050d71030e74fccb11d3234`.
- Selected checkpoint: `d705b191ddd7eb33cc36cbf8e47e71c1363e5389fb41dbea3936720858188d0c`.
- Core ML package: `4729bf925b14bf1e7f43f7dfd7628343055396debd0bc15f31fcbcbef6687e27`.
- Pack: `81701d81e3d63493c37edaac3de2851ed03f3e4dc90597a7babad2fd2b7cecc7`, 19 files, about 364.6 MB.
- Test gold: `f7dae51f7fcfff20a7e399d2845e5ac4edef53c8da7ce8ec9d7b1e8ab8ff7740`.

Mac corpus: `~/gradstep-mac/corpora/papers-library-20261026`; export:
`~/gradstep-mac/inline-tagger-v5b-journal-coreml`. Evidence, private labels, source images, snapshots of both runs,
all checkpoint choices and exact commands: `science-reader/.artifacts/papers-model-20261026`.
Desktop mirror/research: `/home/ben/science-reader-device-pdf/{corpora/papers-library-20261026,papers-model-20261026}`.
Run metadata binds inputs/checkpoints/training source; `replay-inputs-sha256.json` hashes all 720 replay files.
The copied source files were independently SHA-256 verified on both devices before this work.

Tools under `scripts/device-pdf-models/papers_*` profile/group the corpus, build inputs with the production tagger
feature functions, propose partial labels, make source-only review sheets, pack training windows, train with
replay/distillation, score exact-length predictions, export Core ML and check native text/source preservation.
`DevicePDFRouteTool --audit-pages JOBS --models DIR` writes native glyph/layout records; use fresh output paths
when changing the host or models. The artifacts retain the obsolete pre-coordinate-fix records separately.

To reproduce the selected training, use `papers_train_tagger.py --root RESEARCH --training-source ORIGINAL/train.py
--checkpoint ORIGINAL/runs/v5a/tagger.pt --run NEW_RUN --steps 10000 --save-steps 1500,4000 --lr 0.00005
--replay 0.8 --font-dropout 0 --distill 4 --replay-papers 720 --replay-items 180000`. The original training reader
and data remain a pinned local dependency. Export with `papers_export_tagger.py` at threshold 0.65; build the pack
with `node scripts/device-models.mjs` from the frozen export. Evaluate new work on fresh reserved families rather
than repeatedly tuning against the now-revealed journal test set.

## Remaining limitations

- Five test expressions remain incomplete/missed: two small `n` expressions and three bold caption statistics.
  This model does not solve arbitrary equations, scans, tables, reading order, captions or cross-line statistics.
- Some source-image formulas retain neighboring punctuation or fragments of adjacent lines. The model also
  tags an author-affiliation letter and fragments some acquisition parameters in the native examples. Detection
  recall and text conservation do not establish perfect presentation or formula-boundary precision.
- Formula-recognizer guesses remain in diagnostic/index/alt metadata even when the visible reading uses a
  verified source-image fallback. Do not treat that metadata as verified mathematics for downstream chat.
- The control sample is small, the corpus is subject-biased, and weak-label errors are possible. The 99-paper
  converter replay from earlier work was not rerun for this model; current evidence is the large labeled
  regression, new family-held-out statistics, actual Apple inference and two complete native articles.
- No physical iPhone/iPad, battery, TestFlight or new download-hosting claim is made. Existing readings are not
  migrated; the new model applies to newly prepared/explicitly regenerated on-device readings. Official arXiv
  HTML remains the initial structured-reading path.

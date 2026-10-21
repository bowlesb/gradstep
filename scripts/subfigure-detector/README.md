# Subfigure detector pipeline (`sfd`)

Research pipeline behind `docs/reviews/SUBFIGURE_DETECTOR_20261021.md` and `..._20261022.md`. It finds the
parts (panels) of a scientific figure image so the figure explainer can crop them. Nothing here ships in an app
by itself; `sfd/core/policy.py` is the reference implementation that the Swift/TypeScript ports must match.

Runs on the owner's GPU host in `/home/ben/science-reader-subfigures/d21/` with `PYTHONPATH=pkg` (this folder
synced to `d21/pkg/`) and the project venv `d21/env`. The arXiv corpus `/home/ben/mathpix/data/arxiv` is read
only. Every stage is a module with `--help`; all randomness is seeded (`--seed`, default 20261021/20261022).

## Layout

| Package | Stage |
|---|---|
| `sfd/core/` | `policy.py` (crop policy, `decide()` on-device reference, decoding, caption letters), `evaluate.py` (app-level metric) |
| `sfd/mine/` | corpus mining and label generation (index, split, vector, letter groups, whitespace, synthetic, pseudo-labels, manifests) |
| `sfd/annotate/` | evaluation candidates, annotation sheets, GT building, failure-class tags, galleries |
| `sfd/train/` | RT-DETRv2 training (`train.py`) and prediction (`predict.py`) |
| `sfd/evaluation/` | policy sweeps, frozen-system evaluation with bootstrap CIs, AI-box simulation |
| `sfd/export/` | Core ML (FP32/FP16, weight quantization) and ONNX export with parity replay |
| `configs/` | label-source mixes (`sources/`), run configs (`runs/`), crop policies (`systems/`) |
| `annotation/` | the reviewed annotation records for validation and both final tests |
| `tests/` | pytest suite (Mac, no GPU): policy, metric, miners |

## Commands (host, from `d21/`)

```sh
P="env PYTHONPATH=pkg env/bin/python -m"
C=/home/ben/mathpix/data/arxiv
# 1 corpus index and author/family-disjoint split
$P sfd.mine.corpus_index --corpus $C --out data/index
$P sfd.mine.split --papers data/index/papers.jsonl --out data/split \
   --prior ../data/manifests/mathpix-v2/mathpix-train.jsonl ../data/manifests/mathpix-v2/mathpix-validation.jsonl \
           ../data/manifests/source-v2/mathpix-train.jsonl ../data/manifests/targeted-v2/mathpix-train.jsonl
# 2 labels (training split only)
$P sfd.mine.vector_labels --corpus $C --figures data/index/figures.jsonl --out data/vector-v3
$P sfd.mine.manifests_v1 --vector data/vector-v3/labels.jsonl --split data/split/paper-split.json \
   --old ../data/manifests/targeted-balanced-v1 --old-root /home/ben/science-reader-subfigures --out data/train-v1
$P sfd.mine.letter_groups --vector data/vector-v3/labels.jsonl --split data/split/paper-split.json --out data/train-v4/vector-letter-groups.jsonl
$P sfd.mine.render_pool --corpus $C --figures data/index/figures.jsonl --split data/split/paper-split.json --vector data/vector-v3/labels.jsonl --out data/pool-v1
$P sfd.mine.xycut_labels --corpus $C --figures data/index/figures.jsonl --split data/split/paper-split.json --vector data/vector-v3/labels.jsonl --out data/xycut-v2 --singles
$P sfd.mine.synth_compose --pool data/synth-pool.jsonl --out data/synth-v2-s1 --n 1500 --negatives 250 --seed 20261021   # s1..s4
for k in groups framed touching many; do $P sfd.mine.synth_classes --pool data/synth-pool-v2.jsonl --out data/synth-cls-$k --kind $k --n 1500; done
$P sfd.mine.manifests_v2 --xycut data/xycut-v2/labels.jsonl --synth "data/synth-v2-s*/rows.jsonl" --split data/split/paper-split.json --out data/train-v2
# 3 teacher pseudo-labels (clean teacher), then train the release candidate
$P sfd.train.predict --repo ../source/RT-DETR --checkpoint <teacher.pth> --base <coco.pth> --arch r50m --gt data/teacher-pool.jsonl --out data/pseudo-v2/pred-z100.json
$P sfd.train.predict ... --zoom .75 --out data/pseudo-v2/pred-z75.json
$P sfd.mine.pseudo --rows data/teacher-pool.jsonl --pred-a data/pseudo-v2/pred-z100.json --pred-b data/pseudo-v2/pred-z75.json --split data/split/paper-split.json --out data/pseudo-v2/pseudo-all.jsonl
$P sfd.train.train --config pkg/configs/runs/rc-r50m-clean.json --sources pkg/configs/sources/rc-clean-20261022.json \
   --repo ../source/RT-DETR --val data/train-v1/frozen-validation-gt.jsonl data/eval-validation/gt.jsonl --out runs/rc-r50m-clean
# 4 evaluation (validation only while developing; final tests once, with --acknowledge-final-test)
$P sfd.train.predict --repo ../source/RT-DETR --checkpoint runs/<run>/ema-eNN.pth --base <coco.pth> --arch r50m --gt data/eval-validation/gt.jsonl --out <pred.json>  # and --zoom .75
$P sfd.evaluation.final_eval --system pkg/configs/systems/policy-letters-decode-agree-t05.json --gt data/eval-validation/gt.jsonl \
   --pred <pred.json> --pred-b <pred-z75.json> --ocr eval/d22/val-ocr.jsonl --classes data/eval-validation/classes.json --out <result.json>
# 5 export (Mac: coremltools; host: onnxruntime)
python -m sfd.export.coreml --repo <RT-DETR> --checkpoint <pth> --arch r50m --images <validation pngs> --out <dir>   # --precision fp16
python -m sfd.export.quantize --package <fp32.mlpackage> --repo <RT-DETR> --checkpoint <pth> --images <pngs> --mode int8 --out <dir>
$P sfd.export.onnx_export --repo ../source/RT-DETR --checkpoint <pth> --base <coco.pth> --arch r50m --gt data/eval-validation/gt.jsonl --out <dir>
```

Tests (Mac): `python -m pytest -q scripts/subfigure-detector/tests` with numpy, scipy, Pillow, PyMuPDF,
matplotlib and pytest installed. They cover completion, suppression, caption decoding, row/column and letter
grouping, two-view agreement, `decide()`, decoding/letterbox, the app metric, and the vector/whitespace/letter
miners on generated figures.

## Data provenance and rights

- arXiv corpus papers are CC BY 4.0 (≈99%) or CC0; only training-split papers (author-family disjoint from
  validation/test) produce training rows. Figures are rendered from the authors' source files; nothing under the
  corpus is written. Distributed weights must carry CC BY attribution for the arXiv sources.
- Synthetic rows are composed from training-split panels or generated by matplotlib; they inherit those rights.
- `arxiv-reviewed-1018` (106 figures) are corpus figures annotated on 10-18/19 (Codex review).
- The 10-18 SCI-3000 set (unresolved redistribution rights) is used only by research runs r1/r2/r4/r5 and
  **not** by the release-candidate configs (`configs/sources/rc-clean-20261022.json`). Pseudo-labels for the RC
  come from a teacher trained without SCI-3000 (r7).
- Evaluation labels are Claude visual development annotations, not independent human review.

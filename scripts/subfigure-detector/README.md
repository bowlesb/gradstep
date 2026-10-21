# Subfigure detector, 2026-10-21 research pipeline

Report: `docs/reviews/SUBFIGURE_DETECTOR_20261021.md`. Runs live on the owner's GPU host in
`/home/ben/science-reader-subfigures/d21/` (own venv `d21/env`, which layers PyMuPDF/OpenCV/ONNX on the
earlier `env/`). The owner's corpus `/home/ben/mathpix/data/arxiv` is read, never written.

| Step | Script | Output |
|---|---|---|
| Figure index from LaTeX sources | `corpus_index.py` | `data/index/{figures,papers}.jsonl` |
| Author/family-disjoint paper split | `split.py` | `data/split/paper-split.json` |
| Vector-graphics panel labels (clip rectangles + ink assignment) | `vector_labels.py` | `data/vector-v3/labels.jsonl` |
| Caption-verified whitespace labels for non-plot compounds, single negatives | `xycut_labels.py` | `data/xycut-v2/labels.jsonl` |
| Synthetic compounds from real training panels, hard negatives | `synth_compose.py` | `data/synth-v2-s*/rows.jsonl` |
| LaTeX sub-figure page composites from arXiv PDF pages | `subfig_pages.py` | `data/subfig-v2/rows.jsonl` |
| Training manifests | `build_train.py`, `build_train2.py` | `data/train-v1/`, `data/train-v2/` |
| Evaluation candidates / annotation sheets / GT | `eval_candidates.py`, `annotate_sheet.py`, `build_gt.py`, `annotation/` | `data/eval-{validation,test}/` |
| App-level metric and crop policy (completion post-processor) | `evaluate.py`, `policy.py`, `sweep.py`, `final_eval.py` | per-run sweeps |
| Training (RT-DETRv2, official pinned revision) | `train2.py`, `predict.py`, `eval_run.sh` | `runs/<id>/` |
| Teacher pseudo-labels | `render_rejects.py`, `pseudo.py` | `data/pseudo-*` |
| Box-fusion ensembles (validation only) | `fuse.py` | `eval/ens/` |
| Simulated imprecise AI boxes + completion | `ai_box_sim.py` | `eval/ai-box-sim-validation.json` |
| The apps' completeness step on AI crops (reference for Swift/TypeScript) | `app_crops.py`, `export_crop_fixtures.py` | `tests/fixtures/figure-crops/` |
| Final test, scored once | `final_test.sh` | `eval/final/` |
| Export | `export_coreml.py` (Mac), `export_onnx.py` (host) | parity JSON |

The final-test GT (`data/eval-test/gt.jsonl`) is read only by `final_eval.py --acknowledge-final-test`,
once, after the system is frozen on validation. Annotations are Claude visual review, not independent human
review.

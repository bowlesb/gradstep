# Local subfigure extraction experiment — 2026-10-18

Result: a small detector is technically feasible on Apple hardware, but the tested model is not reliable enough to ship as an automatic cropper. It separates two side-by-side plots well, misses logical regions in illustrated workflows, and clips labels in a heatmap despite high confidence. Use the [shared figure-context design](../architecture/LOCAL_FIGURE_REGIONS.md) for the next prototype, retaining whole-figure fallback.

## Candidates and primary evidence

| Candidate | What it provides | Fit for this prototype |
|---|---|---|
| [figpanel YOLOv12](https://huggingface.co/mermermer/figpanel-yolov12) | Small subplot/caption detector; card describes training on roughly 5,000 predominantly biomedical figures and limitations on insets/continuous figures | Actually tested below. AGPL-3.0; not bundled or distributed. Domain shift needs testing. |
| [Florence-2 plot adapter](https://huggingface.co/amayuelas/plot-visualization-florence-2-lora-32) | LoRA adapter for quantitative/qualitative plot regions; card labels adapter MIT | Candidate comparison, not tested. Requires the base model, its license review and a mobile export path. No scientific-panel quality claim from the card alone. |
| [FigEx2](https://arxiv.org/html/2601.08026v1) | Caption-assisted subfigure separation using an 8B captioner and DAB-DETR | Useful research direction, heavier than the first phone prototype. Reported BioSci mAP 0.726 versus 0.697 detector-only, but 0.291 on MedICaT demonstrates dataset sensitivity. Those are authors' results, not ours. |
| [figcrop](https://github.com/tadalab-keio/figcrop) | PDF/vector/text-aware extraction with layout detection | Useful ideas for preserving text and legends; not a drop-in bitmap detector for iOS. Review AGPL/PyMuPDF dependencies before use. No server PDF processing is proposed. |

## Reproducible local run

`scripts/subfigure-prototype.py` loads only the pinned checkpoint with reviewed torch globals and restricted tensor loading. No provider API or paid call was used. Inputs were seven already-local images from the verified FDE-Gym reader bundle (`2610.22350v1`), including the figure family in the owner's crop feedback. This is a diagnostic sample, not a representative benchmark.

- Model: `mermermer/figpanel-yolov12`, HF revision `f723a0931d6e9ddc0835d8ea0afd0a42df41cdea`, `v4.pt` (18,915,859 bytes).
- SHA-256: `3220e816bd0be353deea196c8b6069e6a83d82fbc42efc0b3f35568f1a5a24b5`.
- Mac: Apple M1 Max. PyTorch 2.8.0, Ultralytics 8.4.182, coremltools 9.0, Python 3.9.6. PyTorch CPU uses four threads.
- Export: `format=coreml`, `imgsz=640`, `nms=True`, `quantize=16`. Result: 18,771,659-byte `.mlpackage`, 9.23M parameters. [Official Core ML export documentation](https://docs.ultralytics.com/integrations/coreml/).
- Artifacts: `.artifacts/subfigure-prototype/` (ignored); per-image hash/dimensions/normalized boxes/timings in each `results.json`, rendered boxes in PNGs, export log retained. Weights are not committed.

| Runtime / preprocessing | First prediction call | Median of remaining six | Notes |
|---|---:|---:|---|
| PyTorch, 1024, rectangular letterbox | 3,295 ms | 251 ms | Overlapping/spanning boxes; increasing input size did not improve this sample. |
| PyTorch, 640, rectangular letterbox | 1,135 ms | 121 ms | Cleaner scatter-plot split; duplicate overview crop. |
| PyTorch, 640, fixed square letterbox | 1,194 ms | 168 ms | Preprocessing matched to Core ML. |
| Core ML, 640, fixed square letterbox | 12,057 ms | 23 ms | First call includes package loading/compilation. Subsequent calls 19–33 ms, default compute-unit selection. |

These are wall-clock prediction calls, not isolated accelerator timings or phone estimates. Core ML and matched square PyTorch produced the same box counts/classes on all seven images; maximum normalized coordinate difference was 0.00220 (about 0.22% of an image dimension). Rectangular and square preprocessing produced materially different detections, so preprocessing belongs in the model's identity. No memory, battery or physical iPhone result is claimed.

## Image inspection

All seven annotated Core ML outputs were viewed individually.

| Figure asset suffix | Observation |
|---|---|
| `-4`, overview | Two major panels located; right-hand plot still relies on labels/colors elsewhere in the whole image. A crop alone loses that shared meaning. |
| `-24`, workflow | One box around the whole image. The four logical workflow regions were not extracted. |
| `-49`, illustrated example | One whole-image box; five content blocks were not separated. |
| `-83`, scatter plots | Two distinct plots located with axes and most annotations; edge text still warrants padding/containment checks. |
| `-87`, stacked bars | Correctly remains one plot with its legend. No reason to split individual model rows. |
| `-92`, heatmap | Main box clips long row labels at the left; an extra box covers column headings and a small logo is classified as a caption. Main confidence 0.92 does not prevent this failure. |
| `-98`, grouped bars | Remains one plot with its shared legend and model labels. |

Do not report a precision/recall score from these observations. Ground-truth panel annotations and interpretation-critical text bounds have not yet been created. In particular, whole-image boxes on workflows are missed extraction, not successful detection of every requested subfigure.

## Decision

Proceed with the architecture and a small offline corpus before an in-app detector download. Compare a permissible small detector with Florence-2, including the exact reported figures and harder domains. Keep localization separate from the answering model, reuse one conversation and pass caption/paragraph/LaTeX context with each crop. The first shipping gate is preservation of the information needed to read a panel, not an attractive average latency. Physical iPhone testing remains paused by owner direction.

Example reproduction (after obtaining the pinned research weights and disposable dependencies):

```sh
.artifacts/subfigure-prototype/venv/bin/python scripts/subfigure-prototype.py \
  --weights .artifacts/subfigure-prototype/v4.pt \
  --bundle .artifacts/feedback/followup-20261017/fde-after/2610.22350v1 \
  --out .artifacts/subfigure-prototype/fde-square --size 640 --square
```

Use `--export-coreml` to export and `--coreml --size 640` to run the exported package on the Mac. The script does not download papers, change app behavior, or run during routine tests.


## Coverage replay after the later owner feedback

`python3 scripts/subfigure-coverage.py .artifacts/subfigure-prototype/fde-coreml/results.json
--out .artifacts/subfigure-prototype/coverage-20261018.json` reuses the pinned predictions; no inference/network.
The output binds the input report and image/weight hashes. Near-whole-image boxes are excluded as extractions.
With the same 2% display margin and outward pixel rounding as the clients:

| Image suffix | Admitted crops | Pixel coverage | Interpretation |
|---|---:|---:|---|
| -4 | 2 | 100% | Complete geometric union; shared meaning still needs review. |
| -24 | 0 | 0% | Whole-image fallback, not a workflow split. |
| -49 | 0 | 0% | Whole-image fallback, not five extracted blocks. |
| -83 | 2 | 98.46% | Uncovered pixels remain between/around the plots. |
| -87 | 0 | 0% | Single-plot overview is appropriate; no extraction claimed. |
| -92 | 2 | 97.75% | Coverage remains incomplete; prior critical-label failure remains. |
| -98 | 0 | 0% | Single-plot overview is appropriate; no extraction claimed. |

Zero means zero admitted **crop** coverage; the app still presents the full original image. These figures do not
supply semantic ground truth and cannot be turned into an accuracy score. The result supports separate panel,
required-context and presentation-group annotations for fine-tuning, with whole-image coverage checked mechanically.

## Official RT-DETRv2-S export feasibility — 2026-10-18, 21:30 UTC

The proposed alternative now has an actual Core ML conversion check, before spending time or money training it.
This uses the [official Apache-2.0 implementation](https://github.com/lyuwenyu/RT-DETR/tree/df2a96c8c3a098567a1149bf0248da6efe6d495d/rtdetrv2_pytorch),
revision `df2a96c8c3a098567a1149bf0248da6efe6d495d`, and its published
`rtdetrv2_r18vd_120e_coco_rerun_48.1.pth` checkpoint (81,198,974 bytes,
SHA-256 `2ace52184b620204004509b72752ac7bfe64aadaf7fc1d076b18df8ab5a5c77e`). The checkpoint is loaded with
`weights_only=True`; the backbone download is disabled. The model has ordinary COCO classes, **not scientific
panel labels**. No crop-quality score can be inferred from this conversion check.

`scripts/subfigure-rtdetr-export.py` uses the same seven already-local FDE-Gym images, RGB bilinear aspect-fit into
a white 640-square canvas, float32 NCHW pixels divided by 255. It exports raw logits and normalized cx/cy/w/h
boxes, leaving postprocessing outside the network. Torch 2.8.0 / coremltools 9.0 / Python 3.9.6, four Torch CPU
threads, M1 Max, Core ML `ALL` compute units. `sandbox-exec` denied all networking during all three complete runs.
coremltools warns that its latest tested Torch release is 2.7; the numerical comparisons below are therefore
required evidence rather than relying on nominal compatibility. Static-shape trace warnings are retained.

| Export | Package | First prediction | Median of six warm predictions | Numerical parity |
|---|---:|---:|---:|---|
| FP32 | 80,440,457 bytes | 4,677 ms | 30.4 ms | 7/7 pass |
| FP16 | 40,350,214 bytes | 955 ms | 79.3 ms | 0/7 pass |
| Mixed: FP16 conv/linear/matmul, other operations FP32 | 40,710,295 bytes | 5,110 ms | 29.3 ms | 0/7 pass |

First prediction excludes the separate trace/conversion phases and is not a cold application-launch benchmark.
These are seven sequential wall-clock calls, not repeated performance distributions. Memory, thermal behavior,
app integration and trained scientific-panel quality remain unmeasured for this model.

`scripts/subfigure-rtdetr-parity.py` preserves the raw errors and then makes a one-to-one assignment of **all 300**
predictions, minimizing normalized box L1 distance plus maximum class-probability difference. This accounts for
query reordering at close encoder top-k scores, rather than hiding a box mismatch by independently taking nearest
neighbors. The explicit numerical gate is maximum coordinate error ≤1/640 and probability error ≤0.001.
FP32's worst matched coordinate error is **0.0001710** (0.11 pixels at input resolution), and worst probability
error **0.0000811**. One image has reordered queries; its raw positional error remains in the evidence.
FP16's matched coordinate error reaches **0.9529**, probability error **0.3522**; even restricting attention to
pairs where either confidence is ≥0.25 leaves coordinate drift up to **0.3031**. The smaller export is rejected.
Keeping geometry, normalization and nonlinear operations in FP32 while converting only conv/linear/matmul also
fails (maximum matched coordinate error 0.9632, probability error 0.3580). That ablation rules out claiming that
simply upcasting coordinate decoding fixes this export. The exact source of reduced-precision drift has not been isolated.
Choosing FP32 is an evidence-based baseline,
not a claim that every future trained checkpoint will preserve these errors or timings.

Artifacts: `.artifacts/subfigure-prototype/rtdetr-coreml/`, `rtdetr-coreml-fp32/` and `rtdetr-coreml-mixed/`, each containing complete
Torch/Core ML predictions, a hashed provenance report, model package and `parity.json`; export logs are retained.
No paid inference, GPU training, dataset purchase, application download or shipped detector was added.

```sh
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  .artifacts/subfigure-prototype/venv/bin/python scripts/subfigure-rtdetr-export.py \
  --repo .artifacts/subfigure-prototype/RT-DETR \
  --weights .artifacts/subfigure-prototype/rtdetrv2-s.pth \
  --bundle .artifacts/feedback/followup-20261017/fde-after/2610.22350v1 \
  --out .artifacts/subfigure-prototype/rtdetr-coreml-fp32 --precision fp32
.artifacts/subfigure-prototype/venv/bin/python scripts/subfigure-rtdetr-parity.py \
  .artifacts/subfigure-prototype/rtdetr-coreml-fp32/results.json
```

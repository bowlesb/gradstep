# On-device paper processing feasibility

Status: candidate research from 2026-10-09; product direction superseded on 2026-10-13. The owner selected initial
arXiv HTML adaptation and future device-only PDF processing, with no Mathpix fallback. No model has been selected,
bundled or enabled. [Current architecture](../architecture/HTML_FIRST_READER.md).

The product can reduce cloud processing and give users a stronger privacy option, but a full replacement for
Mathpix is not ready to assume. Equation recognition, reading order, tables and figures are coupled problems. A
local system that produces readable plain text can still produce a reader that is wrong in a way a user cannot see.

## Recommendation

Use retained Mathpix captures only as comparison evidence and build a layered local path behind quality gates:

1. Use the PDF's existing text layer and layout wherever it is reliable.
2. Use Apple's on-device Vision OCR for pages or regions with no usable text layer.
3. Add a local equation model only for an identified equation crop, after its model/data license is cleared and its
   output passes rendering and semantic checks.
4. When the local result is incomplete or ambiguous, keep the local original and report that structured preparation
   is unavailable. Do not send the PDF to Mathpix or another remote processor.

Initially, only official arXiv HTML supplies the structured reader. The future PDF engine must pass a representative
benchmark before its output is presented as a finished reader; local PDF viewing remains available meanwhile.

## What is practical on each surface

### iPhone and iPad

`PDFKit` can read a page's embedded text and character bounds, so born-digital PDFs can avoid OCR entirely when the
text layer is sound. Apple's Vision framework performs text recognition on the device and supports offline use; it is
well suited to missing text, scans and labels, but its documented API is general text recognition rather than a
scientific equation-to-LaTeX pipeline. It should therefore be treated as a text/layout fallback, not as proof that
equations were recovered correctly.

A downloaded Core ML model is technically possible. Apple documents quantizing models and downloading/compiling them
on the device, and Core ML can use CPU, GPU and Neural Engine. The practical limits are model size, memory pressure,
battery, thermal throttling, tokenizer/runtime support and the oldest supported device. Autoregressive formula
models are substantially harder to convert and validate than a small classifier. We should not put a large model in
the App Store bundle or make it a required first-run download before measuring those limits.

### Mac Catalyst

Mac is the best place to trial a heavier local model. Apple Silicon has more memory and sustained compute, and a model
can be downloaded on demand or run as a separately managed local helper. This still needs a clear progress state,
cancel/resume, disk quota, model versioning and a clean uninstall path. A Mac-only preview can establish quality and
performance before any iPhone model is attempted.

### Browser

The browser can use the PDF text layer and perhaps small WASM OCR for a page, but a full neural scientific parser is
too large and variable for a dependable default browser workflow. Browser processing should stay a later experiment;
it should not hold up native local processing or initial HTML adaptation.

## Candidate projects and licensing risks

The code license is not enough: model weights, tokenizer, checkpoints, training data and runtime dependencies each
need an explicit commercial-use review.

| Candidate | What it offers | Product assessment |
|---|---|---|
| Apple PDFKit + Vision | Existing PDF text, bounds and on-device general OCR | Safe first layer; no per-page provider cost; does not solve equation-to-LaTeX by itself. |
| Tesseract | Mature Apache-2.0 OCR engine | Good permissive baseline for plain text, weak fit for scientific layout and equations. |
| pix2tex / LaTeX-OCR | Equation-image to LaTeX; MIT code | Promising crop-level experiment. The project asks users to double-check output and says smaller images work best; checkpoint and dataset licensing still need a separate inventory before shipping. |
| Texify | Equation plus nearby text, LaTeX/Markdown output | The repository is deprecated in favor of Surya, is crop-sensitive and reports a 420×420 training limit. Its weights are CC BY-SA 4.0. Do not make it the production dependency. |
| Surya | Layout/OCR/table pipeline; current release describes a ~650M model and Apple-Silicon/CPU support | Interesting Mac benchmark candidate, but the model weights use a modified CC BY-NC-SA/OpenRAIL-style commercial policy with revenue/funding thresholds and a possible dual license. It is not launch-cleared for a paid app without written licensing review. |
| Nougat | Full scientific PDF parser with LaTeX math and tables; MIT code | Closest conceptual match, but the official model weights are CC BY-NC 4.0. That is incompatible with silently bundling it in a paid product without a commercial license. Its reference runtime is also much heavier than a phone-friendly component. |
| PaddleOCR PP-StructureV3 / FormulaNet | Open document layout and formula-recognition pipeline | Worth testing on Mac or a controlled worker. It is not an iOS-native drop-in, and each model's license/redistribution terms must be checked. |
| DeepSeek-OCR family | Open document OCR with Markdown/grounding modes | The official examples target CUDA/vLLM and A100-class throughput, so this is a server/Mac experiment rather than an iPhone path. Model and code terms must be reviewed separately. |

The attractive quality numbers in project READMEs are not a product guarantee: several benchmarks are self-reported,
may overlap with training data, and measure text edit distance rather than whether a displayed equation means the same
thing. We need our own held-out paper set.

## Quality and safety gates

Before a local engine can produce a normal reader bundle:

1. Build a held-out corpus of at least 50 papers with multi-column text, inline/display equations, tables, figures,
   scanned pages and unusual fonts. Use only papers and assets cleared for the test.
2. Keep the current Mathpix output as a comparison, then have a reviewer score equation render equivalence, text
   correctness, reading order, figure/table placement, section links and passage anchors. Mathpix is a reference, not
   an assumed ground truth.
3. Measure on the oldest supported iPhone/iPad and a representative Apple-Silicon Mac: wall time per page, peak
   memory, battery/thermal impact, model download size, cancellation and recovery after termination.
4. Validate every generated equation and HTML/MathML asset. If a page fails, preserve the PDF and mark structured
   preparation as unavailable; never silently mix an unverified local page into a finished bundle.
5. Record `engine`, `model_version`, `renderer_version`, source revision, confidence and validation warnings in the
   local bundle. Local attempts spend no provider credits; there is no Mathpix fallback.
6. Audit all licenses and notices before shipping weights or a converted runtime. “Open source code” does not grant
   commercial rights to non-commercial model weights or training data.

## Rollout shape

- **Phase A:** add a device-local “Preview text” path using PDFKit plus Vision. It is free, private and clearly marked
  as a preview; it does not claim equation-aware preparation.
- **Phase B:** benchmark pix2tex, Paddle formula recognition and a current Mac-capable candidate on the held-out set.
  Keep all model downloads and output local to the test machine.
- **Phase C:** if one candidate passes quality, license and device gates, ship it as an optional downloaded model with
  a device capability check. Start on Mac and selected iPad hardware; keep iPhone behind an explicit opt-in.
- **Phase D:** offer local bundles and approved-device transfer through the existing AirDrop design. Rights remain
  unchanged: local processing avoids our server copy, but it does not create permission to publish or share a paper.

The former local-preview versus Mathpix choice is superseded. Keep the current reader experience using arXiv HTML;
future successful local PDF preparation can add a verified bundle without deleting the original or changing the
identity beneath the user's notes. The model candidate inventory above is dated research, not current license or
performance verification.

## Sources

- [Apple: Recognizing text in images](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Apple: PDFPage text and character bounds](https://developer.apple.com/documentation/PDFKit/PDFPage)
- [Apple: Reducing the size of a Core ML app](https://developer.apple.com/documentation/coreml/reducing-the-size-of-your-core-ml-app)
- [Apple: Downloading and compiling a Core ML model on the user's device](https://developer.apple.com/documentation/coreml/downloading-and-compiling-a-model-on-the-user-s-device)
- [Apple: Analyzing Core ML performance](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode)
- [Tesseract official repository and Apache-2.0 license](https://github.com/tesseract-ocr/tesseract)
- [pix2tex / LaTeX-OCR official repository](https://github.com/lukas-blecher/LaTeX-OCR)
- [Texify official repository and model terms](https://github.com/VikParuchuri/texify)
- [Surya official repository and commercial-usage terms](https://github.com/datalab-to/surya)
- [Nougat official repository](https://github.com/facebookresearch/nougat) and [its model license](https://github.com/facebookresearch/nougat/blob/main/LICENSE-MODEL.md)
- [PaddleOCR PP-StructureV3 formula-recognition documentation](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/pipeline_usage/PP-StructureV3.en.md)
- [DeepSeek-OCR official repository](https://github.com/deepseek-ai/DeepSeek-OCR)

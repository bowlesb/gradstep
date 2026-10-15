# Differential check of the on-device PDF converter against the desktop reference

The TypeScript converter (`supabase/functions/_shared/reader/device-pdf/`) ports the desktop's Python reference
(`src/gradstep/bundle/device_pdf.py`, converter 0.1.0). These scripts run both on the same recorded signals with
deterministic stand-ins for the tagger (glyphs of math font families) and the recogniser (a crop read by its size),
and compare the reference-shaped `index.json` field by field. Read-only towards the desktop: copy its `src/` here.

1. Layout detections with the exported Core ML detector (Python 3.9 + coremltools, pypdfium2, Pillow):
   `LAYOUT_EXPORT=<layout-fcos-v5-coreml> python -I record_layout.py paper.pdf paper.layout.json`
2. The reference (Python 3.10+, numpy, Pillow, pdfplumber, pypdfium2; torch is stubbed):
   `DEVICE_REF_SRC=<copy of src/> TAGGER_VOCAB=<vocab.json> python harness.py paper.pdf paper.layout.json out-py paper.signals.json`
3. The port: `node --experimental-strip-types run_ts.mjs paper.signals.json out-ts <vocab.json> paper.pdf`
4. `python compare.py out-py/index.json out-ts/index.json` (only image paths may differ: the reference numbers them,
   the reader names them by content).

The committed fast-tier fixture `tests/fixtures/device-pdf/synthetic-reference.json` is step 2 on the synthetic
paper of `tests/backend/device-pdf/paper.ts` (`harness_synth.py <signals.json> synthetic.pdf out-py`, where the
signals are `{pdf, tagger, pages}` from `synthetic.ts` and `synthetic.pdf` holds the bytes `%PDF-synthetic\n`).

Result on 2026-10-15 for the eight fixtures of `device-route-fixtures-2026-10-14` (1,574 blocks, 3,899 equations):
no difference other than image paths. The tagger's inputs match the reference's own feature code on 758 real lines
(largest difference 1.2e-7, float32 rounding).

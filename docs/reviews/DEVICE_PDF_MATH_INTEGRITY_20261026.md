# On-device PDF equation integrity — 2026-10-26

Status: converter port **16**, locally verified and merged into `main`, based on `09e71c2f`.
This quality change is a separate commit from the full-screen PDF preview. No model pack or client release has
changed; no GPU training was needed for this acceptance-rule failure.

## Product gaps and selected goal

The local route combines layout FCOS v5, inline tagger v4 and Texteller v4 with a TypeScript reader compiler.
The model lock is `apps/apple/device-models.lock.json`; training assets are on the desktop under
`/home/ben/science-reader-device-pdf`, with Core ML exports under `~/gradstep-mac` on this Mac.
Official exact-revision arXiv HTML remains the primary reading route. This work affects device-converted PDFs.

The existing [weakness review](DEVICE_PDF_WEAKNESSES_20261024.md) and
[table review](DEVICE_PDF_TABLES_20261024.md) identify these concrete bad experiences:

| Gap | Reading consequence | Next useful intervention |
|---|---|---|
| Inline spans cut short, overgrown or missed | Half an equation appears as prose; symbols attach to the wrong words | Evaluate the existing v5a tagger candidate on actual device crops before a model promotion; cross-line and table context matter |
| Display region missed or cropped | An equation disappears or loses a line | Evaluate layout v6 on Core Graphics page renders; avoid a heuristic already shown to reduce precision |
| Adjacent table cells merged, wrapped cells split | Values can appear under the wrong column | Separator/merge prediction with the proposed small table model and held-out paper families |
| Recognition runs to the token limit | A few formulas delay the final reading | Measure the existing continuous-batching candidate and bounded decoding on a quiet Mac; GPU speed is not phone speed |
| Uncertain recognition promoted despite a missing operator | A clean-looking formula can change the paper's meaning | **Selected:** strengthen agreement with the original PDF before allowing low-confidence typesetting |

The earlier review manually found a missing integral sign among formulas promoted by `verifyGlyphs`.
The implementation compares a sorted subset of characters; important mathematical operators are omitted.

**Goal:** reproduce real operator disagreements, keep them as their original PDF crop rather than uncertain
typeset math, and retain at least **98% of the currently typeset equations in each** recorded arXiv development,
arXiv test and publisher corpus. Preserve text, equation identities, source regions and the existing crop fallback.
Development records guided the change; test/publisher records were the subsequent checks. Do not claim general
semantic correctness: glyph agreement cannot prove fraction, script or spatial structure.

## Evidence

`scripts/device-pdf-math-audit.mjs` replays recorded pages, tags and recognitions through the actual gate, without
inference or placeholder image rendering. It records source hashes, replay misses, every equation and whether it
is typeset. A comparison rejects any changed model inputs, blocks, formula content, order or source region.
The preserved inputs and results live in the main checkout's `.artifacts/device-pdf-quality-20261026/`.
The inputs are the desktop's recorded `m0-dev`, `m0-test` and `m0-venue` Core ML runs with the locked model IDs and
hashes, preserved under `records/` in that evidence directory. Reports retain each uncompressed record's SHA-256.

## Implementation and measured result

The original character-evidence check remains required. A second check includes mathematical operators and
radicals drawn by MathML's `msqrt`/`mroot`. Equivalent dot, set-difference and circle encodings are normalized.
Every unnamed PDF glyph must have a corresponding unmatched operator or balanced grouping delimiter in MathML;
it cannot simply disappear. An unnamed symbol's **identity** remains unproved. Replacement/object characters
remain inconclusive. This change only narrows the old gate's promotions.

Rejecting all unnamed glyphs initially lost about 2.6% of previously typeset equations in the test and publisher
samples, failing the target. Accounting for symbols and grouping delimiters retains correct readings while
rejecting an omitted integral. The test/publisher retention results informed this refinement: the final table
is validation on known corpora, **not an untouched holdout or human gold**.

| Recorded corpus | PDFs / pages | Equation instances | Typeset before → after | Retained | New crop fallbacks |
|---|---:|---:|---:|---:|---:|
| arXiv development | 30 / 862 | 22,172 | 20,320 → 20,246 | **99.64%** | 74 |
| arXiv test | 32 / 872 | 20,392 | 19,500 → 19,408 | **99.53%** | 92 |
| Publisher PDFs | 31 / 798 | 17,425 | 15,169 → 15,002 | **98.90%** | 167 |
| Total | 93 / 2,532 | 59,989 | 54,989 → 54,656 | **99.39%** | 333 |

All three exceed the 98% retention target. **Zero previously refused equations are newly typeset.** Every replay
has zero missing tagger and recognition answers. Block text, formula LaTeX, identities, order, confidence and PDF
regions are identical before/after. These are retention measurements, not equation accuracy. The 333 fallbacks
are not 333 proven errors; some correct equations now use images because their evidence is insufficient.

Two real regressions were inspected against the PDF: **2610.27022v1, pages 18 and 23**, equations
`e-61c3e26839bd-687` and `e-61c3e26839bd-942`. Recognition omitted an integral at each region's right edge;
both previously passed verification and now use the original crop. The region itself cuts the integral, so this
preserves the original visible ink but **does not repair the incomplete span**. Full-page Poppler renders and
the exact Apple Core Graphics crops were inspected. The focused
[before/after comparison](../../.artifacts/device-pdf-quality-20261026/visual-proof.html) shows the limitation.
The PDF digest, glyphs, model LaTeX and coordinates are retained in
`tests/backend/device-pdf/math-integrity-real.json`.

## Verification and remaining limits

- **28 focused tests pass**, including six new tests covering the recorded failures, mathematical operators,
  radicals, unknown glyphs, equivalent encodings and complete inline/display bundle crop fallback. The actual
  bundled image and source provenance are checked, not just a helper boolean.
- **`npm test` passes**, including compiler freshness, backend tests, types and browser units. The embedded
  JavaScript and build identity are regenerated at revision 16.
- **Apple JavaScriptCore replay passes**, with ordinary settings and `JSC_useJIT=false`, on the complete 30-page
  failing paper using the generated compiler and recorded host answers. That replay uses placeholder images;
  it proves runtime compatibility, not phone performance or visual fidelity.
- The comparison's actual crops use `wk1/DevicePDFRouteTool --render-crops` at 216 dpi. Its rendered screenshot
  was inspected. Viewer interaction is unchanged and reuses the prior Simulator audit; physical iPhone work stays paused.

High-confidence recognitions keep their existing gate. Character counts cannot establish fraction/script
geometry, ordering, delimiter shape or an unnamed symbol's identity. Existing image-budget and crop-failure
fallbacks still apply. Metadata still contains model LaTeX; this is the visual gate, not a new downstream chat
confidence contract. Existing readings use the new converter through their normal reprocessing path. No server
PDF handling, model download change, migration, paid call or deployment occurred.

Reproduce from the main checkout, substituting `test` or `venue` for `dev`:

```sh
node scripts/device-pdf-math-audit.mjs \
  --records .artifacts/device-pdf-quality-20261026/records/m0-dev \
  --out .artifacts/device-pdf-quality-20261026/recheck-dev.json \
  --baseline .artifacts/device-pdf-quality-20261026/before-dev.json
```

`before-*.json` and `after-*.json` contain every equation; `integration.json` records source and verification receipts.
Next model experiment: evaluate the existing v5a tagger and cross-line context against **complete source-region
coverage**, as well as equation recall, on both arXiv and publisher PDFs before any model-pack promotion.

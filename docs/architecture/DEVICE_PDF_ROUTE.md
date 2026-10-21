# The on-device PDF route (experimental) — design, 2026-10-15

Owner: "It would be cool to try to create a version of the on device model into the app knowing it won't always
work but we can try and give feedback." The model-building agent froze the route on the desktop as the **port
kit** (`/home/ben/mathpix/docs/DEVICE_ROUTE_SPEC.md`, converter 0.1.0; layout `layout-fcos-v5`, equations
`texteller-ft-v4`, inline tagger `inline-tagger-v4`, all three exported to Core ML; the Python converter
`src/gradstep/bundle/device_pdf.py` is the reference and eight fixture bundles are the acceptance test). This app
implements it as an **experiment beside the arXiv HTML reader**, never in its place: the HTML reader stays the
first-class path (owner direction, 2026-10-13), the PDF never leaves the device, and nothing here touches the server.

## Components

| Piece | Where | What it does | Gate |
|---|---|---|---|
| Signals host (Swift) | `ScienceReaderCore/DevicePDF/` | Opens the PDF (PDFKit), renders pages (150 dpi for layout and recogniser crops, 216 dpi for formula images), reads the text layer as glyphs, runs the three Core ML models, decodes the layout's boxes (per-class thresholds, NMS 0.6, best 300) and the recogniser's tokens (byte-level BPE with the tokenizer's space clean-up), cuts and encodes crops | `swift test` on macOS: decode, tokenizer, crop geometry; the CLI below |
| Converter (TypeScript, pure) | `supabase/functions/_shared/reader/device-pdf/` | Every rule of the spec in order: furniture, front matter, glyph ownership, orphan lines, reading order, authors, captions, blocks, tables as cells, formulas, the confidence gate, Temml MathML; emits **this app's reader vocabulary** and composes a `reader-bundle-v1` | Node tests on recorded glyph/model fixtures (fast tier); the shared HTML validator; conformance on the eight fixtures |
| Host bridge | JavaScriptCore `JSContext` in-process | Runs `device-pdf-reader.js` (esbuild IIFE, global `GradstepDevicePDF`); the host functions below are synchronous Swift closures | The CLI run on the fixtures |
| CLI (macOS) | `ScienceReaderCore` executable `DevicePDFRoute` | `DevicePDFRoute <paper.pdf> <out-dir> --models <dir> --compiler <device-pdf-reader.js> [--trace]` writes the bundle and, with `--trace`, the Python-shaped `index.json` the desktop's `bundle_conformance.py` reads | Fixture conformance, timings per stage |
| App | `ScienceReader` | Settings › Experimental; "Read with the on-device model" on a paper whose PDF is on the device; progress by stage; the result opens in the same reader with a banner (model-read, report a problem, back to the HTML version) | Simulator journey with a fixture PDF |
| Models | `apps/apple/DeviceModels/` (not committed) | Compiled `.mlmodelc` copies of the exports with `device-models.json` (thresholds, tagger vocabularies, tokenizer); `scripts/device-models.mjs` copies them from the Mac's export directories and checks their digests against `apps/apple/device-models.lock.json` | The script's digest check; the app hides the experiment when they are absent |

## The contract between the host and the converter

`GradstepDevicePDF.convert(input, host)` runs synchronously and returns the bundle or throws `{code}`.

```
input = { pdf: { sha256, bytes, name }, pages: n, title?: catalog title, paper?: { source_id, revision },
          models: [{ role, id, sha256 }], tagger: { vocab, prior, cvocab, threshold, max_len }, trace?: bool,
          transcribe?: bool (simple inline formulas from the text layer, below), record?: bool (evaluation, below) }
host.page(i)      -> { width, height (points), image_width, image_height (150 dpi pixels), scale (s_canvas),
                       glyphs: { text[], x0[], top[], x1[], bottom[], size[], font[], upright[] } (stream order),
                       detections: [{ cls, score, box: [x0, y0, x1, y1] (canvas pixels) }] (decoded, score order) }
host.tag(lines)   -> logits[][]   lines: [{ x: number[T*10], font: int[T], cls: int[T], char: int[T] }]
host.recognise(c) -> [{ latex, probs[] }]   c: [{ page, rect: [x0, y0, x1, y1] (150 dpi pixels, halo included) }]
                     the host pastes the crop on white with the 8 px margin, preprocesses, decodes greedily
host.image(r)     -> { png (base64), width, height, rect? }   r: { page, dpi: 150 | 216, rect: [x0, y0, x1, y1] (pixels at dpi),
                     clean?: { em, margin } (pixels at dpi; formula crops) }; with `clean` the host trims the crop (below)
                     and returns where the image now sits, `rect`, in the same pixels
host.progress(stage, done, total); host.cancelled() -> bool
host.submit(c)    -> ticket   (optional, with collect; port revision 5) c as for recognise, each with display: bool;
                     the host cuts the crops now and recognises them in the background while the converter reads on
host.collect(t)   -> [{ latex, probs[] } | null]   that submission's results, waited for (after the last page)
host.preview(b)   (optional) b: a complete bundle made before any formula is read (every formula its image), same shape
                     as the result; the app shows it while the recogniser finishes
result = { manifest (base64 of canonical bytes), manifest_sha256, members: { path: base64 }, summary, trace?, record? }
```

Since port revision 5 (2026-10-21, [review](../reviews/DEVICE_PDF_ROUTE_20261021.md)) the host overlaps the stages:
the pages' layout and text are read ahead on two threads (each with its own `CGPDFDocument`; `host.page(i)` waits for
page i), the tagger's lines run on four threads, and the recogniser runs in the background on batches of eight crops
of one placement, narrowest first (`DevicePDFPipeline.swift`). Results are the same as one crop at a time: the batched
export decodes every crop's tokens exactly as the one-crop export does (20/20 and 80/80 on the export's samples, the
same bundles on the fixtures).

Crop rectangles are computed by the converter exactly as the reference does (integer pixel rounding included),
so the rules live in one place; the host only renders, cuts, encodes and infers.

**Formula crops are cleaned** (port revision 3, 2026-10-16; owner, TestFlight 62: "an outline clean step where excess
pixels around the edge are cleaned and then with margin"). A formula's crop is its layout box with 2 pt of padding,
so the lines above and below left their cut glyph tails along its edges (Waypoint-OPD 2610.21601 on the phone). The
converter asks for `clean: { em: font size × 3, margin: 0.25 em display, 0.12 em inline }`; the host
(`DevicePDFRaster.cleanFormula`) finds the ink's 8-connected pieces, drops a piece only when it touches the crop's edge,
lies wholly outside the formula's own ink (the pieces clear of the edges, specks aside) with a clear gap, and is small
for a line of text (under 0.45 em tall above or below, 0.3 em wide beside), plus specks in the zone of the pieces
dropped; nothing is dropped when that would take a quarter of the ink (a formula its box cut into is never cut
further). It trims to the kept ink with a one-pixel rim and adds the margin in white (dark mode inverts it with the
image). The image is sized and aligned from its returned `rect`: display width = its width in points over the font
size; inline height likewise, and its bottom as far below the formula's box as on the page, on a line's descender
(0.22 em). Tests: `DevicePDFFormulaCleanTests` (tails above and below with their grey rims, a tall integral with limits,
a fraction, nothing to trim, a clipped formula, specks, a side sliver), `device-pdf.test.ts` (requests, sizing, a host
whose rectangle disagrees). On Waypoint-OPD and Mamba (first 10 pages) every neighbour's tail went and every bar,
script, root and equation number stayed; a cut word wider than 0.3 em at a side ("an|d B̄ = …") stays.

## Output: this app's reader vocabulary, not the Python bundle's

The fixtures' HTML is the desktop's own vocabulary. The app's reader and validator (`html-validate.ts`, Swift
`ReaderBundle.swift`) admit a stricter one, so the converter emits:

- blocks with `id`, `data-reader-block` (= id) and `data-reader-kind`; exactly one `h1`, the paper's title (the
  detected title, else the library's title);
- a display formula as a `p` equation block; a recognised formula as `span.reader-equation` with sanitized Temml
  MathML; **an unsure formula as its crop image** — a new representation for this renderer only:
  `span.reader-equation.reader-math-image > img` whose `style` is restricted to
  `height:<em>;vertical-align:<em>` (inline, sized from the line's font size so it scales with the reader's text)
  or `width:<em>` (display);
- each reference entry as its own `li` block under `ul.reader-references` (the Python route chunks them);
- a listing with formulas as a paragraph with line breaks (`pre > code` holds only text);
- a table as cells (`div.reader-table > table > tbody`) or, when the grid places too little, as a figure;
- footnotes as `p.reader-footnote`.

Degrade, never refuse (owner, 2026-10-15): past the bundle's image budget (members, pixels) formulas fall back to
their LaTeX text (`reader-math-fallback`) and figures are scaled down; the closing summary counts what changed.

Provenance (`device-pdf-reader-provenance-v1`) carries the PDF's size and digest, the page count, the models and
their weight digests, the two gates, the converter revision, warnings, the unowned-glyph share, and per equation
its confidence, whether it rendered, and its source page and box (docs/EQUATION_SOURCE_REGION.md on the desktop).

## Known differences from the reference (to report, not to hide)

- **Text layer.** The reference reads pdfplumber's characters (boxes from the font's ascent and descent at the
  baseline). PDFKit's character bounds and font names differ in places; conformance measures the effect.
- **Recogniser length.** The Core ML decoder step has a 256-token cache; the reference decodes up to 1,024 tokens.
- **Image resampling.** Core Graphics and vImage instead of PIL and torchvision's antialiased bicubic.
- **Compute units.** The stateful decoder does not load on the Neural Engine (macOS 26, coremltools 9): the
  recogniser runs on CPU and GPU, the layout and tagger on the Neural Engine.

## Status — 2026-10-15, ~08:00 UTC

Built and running on this Mac and in the iOS Simulator; not yet tried on an iPhone (TestFlight is the owner's test).

- **Text layer** (`DevicePDFTextLayer*`, `DevicePDFFonts*`, `DevicePDFCMap`): equals pdfplumber's characters on all
  eight fixture PDFs and 18 more papers (text, box within 0.05 pt, font, size, upright: 100 %); 2 to 10 ms a page.
- **Models from Swift**: layout 91/91, tagger 60/60 lines, recogniser 20/20 token sequences against the exports'
  samples. Core ML pads the layout's output rows (strides `[32, 1]`); the reader reads through the strides.
- **Converter** (`device-pdf/`, `device-pdf-reader.js`, 345 KB): equals the Python route on the fixtures given the
  same inputs; port revision 2 (the conversion time is no longer in the bundle, so a PDF read twice is the same bundle).
- **End to end** (`scripts/device-route-eval.mjs`): all eight fixtures convert and pass the app's own verifier; three
  meet every conformance gate (one only fails the script's table check on a paper without tables), the rest are
  close (block match 0.86 to 0.98). Page renders turn font smoothing off: macOS's stem thickening made the
  recogniser read regular letters as bold and the layout split paragraphs (worst paper 0.87 → 0.97 blocks).
- **Recognition two at a time**: each page's crops are decoded two at once (`recogniserConcurrency`), the same output
  in two thirds of the time (2610.04747v1: 46.7 s → 31.5 s); three in flight gains little more.
- **iOS Simulator**: the stateful recogniser does not load ("Network translation error"); the route reads the paper
  without it (formulas as page images) and the banner says the formula model can't run on this device. A real
  fixture paper's first three pages take 12 s there.
- **App**: Settings › Experimental "On-device PDF reader" (on while testing); "Read with the on-device model" in a
  paper's options when its PDF is on the device, and in an added PDF's own view; a progress bar with the stage,
  elapsed time and Stop; the reading opens in the same reader under a banner (pages, time, formulas typeset) whose
  menu offers "Report a problem with this reading" (the report carries counts and times, never the paper's text)
  and "Show the HTML reading". Readings are kept in a store of their own (`device-model-readers`, encrypted like the
  others) and reopen at once. Models: 365 MB in the app (layout fp16, recogniser int8, tagger).
- **Feedback for the model-building agent**: `docs/proposals/DEVICE_MODEL_FEEDBACK.md`.

### Port revision 4 — 2026-10-18

The shared HTML validator now admits the arXiv compiler's bounded affiliation-line span. Device-PDF output itself
is unchanged; the embedded converter is rebuilt and its port identity advanced because its dependency bytes
changed. The compiler freshness check caught the stale embedded bundle before release.

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
| Text recognition (Swift, since 2026-10-23) | `DevicePDFOCR.swift` | A page whose text layer is empty (a scan) or unreadable (codes without a Unicode mapping, letters that are no words) gets its glyphs from Vision's on-device text recogniser on the 150 dpi render (each word's characters spread over its box, font `GradstepOCR`); `Options.ocrFallback` (on), the tool's `--no-ocr` | `DevicePDFOCRTests`; scanned copies of arXiv papers scored against their HTML |
| Models | `apps/apple/DeviceModels/` (not committed) | Compiled `.mlmodelc` copies of the exports with `device-models.json` (thresholds, tagger vocabularies, tokenizer); `scripts/device-models.mjs` copies them from the Mac's export directories and checks their digests against `apps/apple/device-models.lock.json`. Since 2026-10-21 the recogniser is one multifunction package, `DeviceRecogniser.mlmodelc` (functions `prefill` and `step`, batch 8; `scripts/device-pdf-models/export_texteller.py`); since 2026-10-23 with a 512-token cache. Since 2026-10-24 a separate download on iPhone and iPad (below) | The script's digest check; the app hides the experiment when the build has neither the models nor their description |
| Evaluation (Mac) | `scripts/device-route-accuracy.mjs`, `scripts/device-route-replay.mjs` | Fresh arXiv papers (PDF + the exact revision's HTML) scored against the app's own arXiv HTML reading; `--record` runs replayed through the converter in Node to try rule changes in seconds | [Review 2026-10-21](../reviews/DEVICE_PDF_ROUTE_20261021.md) |

## The models as a download — 2026-10-24

Owner: *"We should make the on device model a separate download, instead of in the app, can we do that"*. The models
were 365 MB of the app (TestFlight builds measured 382 MB; this Mac's unsigned Internal device build 447.6 MB, of which
DeviceModels 364.6 MB). Decision and alternatives: [DECISIONS](../DECISIONS.md) "The on-device PDF model is a separate
download".

**Packaging.** `node scripts/device-models.mjs` still compiles the locked exports into `apps/apple/DeviceModels` (the
pack) and now also writes `apps/apple/DeviceModelsManifest/device-models-pack.json` (both untracked):

```
{ schema: "gradstep-device-models-pack-v1", version: sha256("<path>\t<size>\t<sha256>\n" for each file in path order),
  tag: "device-pdf-models", folder: "DeviceModels", lock: { role: package sha256 from device-models.lock.json },
  files: [{ path, size, sha256 }] }
```

In the iOS target the `DeviceModels` folder carries the On-Demand Resources tag `device-pdf-models` (`project.yml`
`resourceTags`; `ENABLE_ON_DEMAND_RESOURCES` YES for iOS, NO for Mac Catalyst), so Xcode builds it into one asset pack
beside the app (`OnDemandResources.plist` maps the tag to it) and `xcodebuild -exportArchive` uploads it with the build;
the App Store and TestFlight host it. The description is an ordinary resource inside the app. The Mac app (no On-Demand
Resources on macOS; `NSBundleResourceRequest` ignores Mac Catalyst) copies the tagged folder into the app as before.
`node scripts/check-device-model-pack.mjs <archive>` (run by `upload-testflight.sh` before the upload) checks that the
iOS app has the description and not the models, that the tag maps to an asset pack, and that the asset pack's every file
has the described size and SHA-256, and that the description's lock digests are `device-models.lock.json`'s;
`--mac <archive>` checks the Mac app's own copy. The lock remains the single source of truth: a new export still
reaches the app only through `device-models.mjs` and a lock update, and any changed file is a new pack version.

**On the device** (`ScienceReaderCore/DevicePDF/DevicePDFModelPack.swift`, app `DeviceModelAssets.swift`):

- *Locating* (`DevicePDFModelLocator`): a folder named by `GRADSTEP_DEVICE_MODELS` (tests and tools; for app-hosted tests
  `TEST_RUNNER_GRADSTEP_DEVICE_MODELS`), else the verified download of this build's version in
  `Application Support/DevicePDFModels/<version>/` (excluded from backup), else the models inside the app (the Mac, or a
  build with On-Demand Resources off), else none: the experiment stays offered and asks for the download.
- *Downloading*: `NSBundleResourceRequest(tags: ["device-pdf-models"])`, urgent when the reader asked; progress from its
  `Progress` (the first 90 % of the bar), then every described file is copied to a staging folder and the copy's size and
  SHA-256 are checked (the last 10 %); `.mlpackage` folders, if a pack ever carries them, are compiled on the device to the
  `.mlmodelc` of the same name; a `.verified` marker naming the version is written last and the folder renamed into
  place, so a copy cut short or a mismatched file is never used (nothing else in the pack is copied). Then the request
  ends and the tag's preservation priority drops to 0 so the system can purge its own copy. The copy-and-check runs under
  a background task assertion.
- *Updates*: a build with a new description is a new version; at launch the old version is removed (it can't be used with
  the new converter) and, for a reader who had downloaded before, the new one downloads by itself at the first network
  answer that is not cellular or Low Data Mode; otherwise the offer appears where it is used.
- *Removing*: Settings › Experimental › On-device PDF model › Remove deletes every version and stops automatic updates.

**Interface** (owner: minimal screens, controls where used). "Read with the on-device model" without the models shows,
in the bar where the reading's progress shows, "Download PDF reading model (about 365 MB)" with Cancel and, on cellular,
"Wi-Fi is better for a download this size"; during the download its percentage, a progress bar and Cancel; a failure says
why with Try Again. When the models are in, the reading starts by itself. Settings › Experimental has one row under the
toggle: "On-device PDF model — Downloaded · 364.6 MB" with Remove, "Not downloaded · about 365 MB" with Download, or
"Downloading · n %" with Cancel; the row is not shown on the Mac.

**Verified** (2026-10-24, this Mac, iPhone 17 Simulator on iOS 26.4): the journey `DeviceModelJourneyTests` taps "Read
with the on-device model" on a build without the models, gets the offer, downloads the asset pack through the
Simulator's On-Demand Resources service from the build folder, installs version `37bc13a456de` into Application Support
(excluded from backup) and reads the fixture paper; Settings then says "Downloaded · 364.6 MB" and Remove takes it away.
Of nine runs, five passed end to end (four through the download, one with the models already in; the last on the final
code after rebooting the Simulator); four failed at an assertion on the web view's text, two of them before the on-device
model was touched, while other agents' Simulators ran, with the reading on screen in the captured screenshots (the
known stale-Simulator flake). App-hosted `DeviceModelRouteTests` passes with `TEST_RUNNER_GRADSTEP_DEVICE_MODELS`. Size: the unsigned Internal device build is 83.6 MB (447.6 MB
before), the asset pack 364.6 MB; `check-device-model-pack.mjs` passes on that build and on the Mac Catalyst build, which
still carries the models. Core unit
tests (`DevicePDFModelPackTests`): the description and its version, refused descriptions, install and verification,
tampered and missing files, a model update and removal of the old version, removal, on-device compilation of a package,
the locator's order. **Not verified until a TestFlight build:** the App Store's hosting of the asset pack for TestFlight
(forum reports from 2020 describe ODR failures in TestFlight that Apple fixed server-side), real download speed, whether
the system keeps downloading while the app is in the background (ODR downloads are made by a system service; the request
is kept and the install finishes under a background task), the owner's iPad on iPadOS 18.7.8, and cellular behaviour.

**Later: Background Assets.** Apple deprecates On-Demand Resources as of iOS 27 and recommends Apple-hosted Background
Assets (`AssetPackManager`, iOS/iPadOS/Mac Catalyst 26+, packs made with `xcrun ba-package` and uploaded apart from the
build). It needs a downloader-extension target and an App Group shared with the app, which the developer account does
not have yet. When it does, add a second source for the same pack on 26+ (the description, verification, store and
interface stay as they are) and keep On-Demand Resources below 26.

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
on the fixtures a few formulas differ in LaTeX, agreement with the reference within 0.004).

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
its confidence, whether it rendered, and its source page and box (docs/EQUATION_SOURCE_REGION.md on the desktop):
`equations` rows `[id, confidence, rendered (0/1), page, x0, y0, x1, y1, baseline or -1]`. Since port revision 10,
`figures` rows `[id, page, x0, y0, x1, y1, page width, page height]` (each shown figure's crop); since port revision 11,
`blocks` rows `[block id, page, x0, y0, x1, y1]` for every emitted block, one per layout region it was read from, in
reading order (the union of the region's glyphs, its layout box when it has none; a figure's crop then its captions).
All boxes are points from the top left of the page as shown (its crop box turned by its /Rotate), the text layer's
coordinates. The reading never uses them; the apps do (FIGURE_VIEW.md "Zoom out onto the page" and "Show in PDF"). A
row the app can't read is dropped, never the reading; older readings simply have fewer rows.

## Known differences from the reference (to report, not to hide)

- **Text layer.** The reference reads pdfplumber's characters (boxes from the font's ascent and descent at the
  baseline). PDFKit's character bounds and font names differ in places; conformance measures the effect.
- **Recogniser length.** The Core ML decoder step has a 512-token cache (256 until 2026-10-23); the reference decodes up to 1,024 tokens.
- **Image resampling.** Core Graphics and vImage instead of PIL and torchvision's antialiased bicubic.
- **Compute units.** The stateful decoder does not load on the Neural Engine (macOS 26, coremltools 9): the
  recogniser runs on CPU and GPU, the layout on the Neural Engine, the tagger on the CPU. (2026-10-21: a batch-8 int8
  encoder sent to the Neural Engine compiler was still compiling after more than 100 CPU-minutes; not pursued.)
- **Since 2026-10-21 the app no longer matches the reference rule for rule:** converter rules measured against arXiv
  HTML are on in the app (below); the fixtures' conformance holds only with them off (the tool's default).

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

### Port revision 10 — 2026-10-24

Provenance gains `figures`: each shown figure's page, crop and page size in points, so the apps can zoom out of a crop
onto the PDF on the device (FIGURE_VIEW.md "Zoom out onto the page"). The reading itself is unchanged.

### Port revision 11 — 2026-10-24

Provenance gains `blocks`: where each emitted block's text sits on the PDF, so the apps can show a selected passage on the
PDF on the device (FIGURE_VIEW.md "Show in PDF"). The reading itself is unchanged (the synthetic reference's trace and the
bundle tests are equal); the compiled converter and its identity are rebuilt. A parallel converter change (accuracy and
speed rules) may take a later revision number; the rows are independent of it.

## Development after the port kit — port revision 5, 2026-10-21

Owner, 2026-10-21: keep developing the on-device route (too slow, not accurate enough); Mathpix is not built. Measured
on 32 fresh arXiv papers against their arXiv HTML reading: [review](../reviews/DEVICE_PDF_ROUTE_20261021.md).

**The recogniser.** The time was the recogniser (88 %), and mostly per-call overhead: the port kit's export decodes one
crop at a time and passes the encoder's cross-attention keys and values (77 MB as float32) into every decoder step. The
app now ships the same weights (texteller-ft-v4) as one **multifunction package** with a batch of eight:
`prefill(pixel_values [8,1,448,448])` runs the encoder and writes the keys and values into a state, `step(token [8,1],
position [1])` reads them; a state made by one function serves the other (checked on CPU and GPU before relying on it),
both have fixed shapes so Core ML never re-specialises between calls (the cost that sank the desktop's single-function
"cross-state" export). Per crop on this Mac's GPU: encoder 35 ms (60), decoder step 1.7 ms (12.7, plus 30 ms of
conversion per crop); same tokens as the port kit's export on its samples (20/20, 80/80 batched; on whole papers a few formulas differ). 285 MB
compiled (299 before). A batch holds about 0.4 GB of state: two batches run at once only on devices with 7.5 GB of
memory or more.

**The host** (`DevicePDFRoute.swift`, `DevicePDFPipeline.swift`) overlaps the stages: two threads read pages ahead
(render, text layer, layout; each with its own `CGPDFDocument`); the recogniser runs in the background (`submit` per page,
`collect` at the end), batches of one placement, narrowest crops first; with `onPreview` the converter hands over a
complete reading before any formula is read (every formula its page image), which the app shows under the progress bar
and replaces when the formulas are done, keeping the reading place (same block ids). **Determinism:** under load,
tagger predictions made while a recogniser prediction ran on the GPU gave different logits for the same line (25 of 920
lines in one paper, logit differences up to 10), so the same PDF read differently; the tagger and the recogniser now never
predict at the same time (`DevicePDFModels.exclusive`), layout predictions are serialised, the read-ahead draws the layout
canvas from the same pixels as the on-demand path, and the tagger runs on one thread. Two conversions of one paper run
at once on a loaded Mac now give byte-identical readings, equal to the serial port kit order (a residue remains under extreme load: between two full corpus runs, 7 of 32 papers differed by a few formulas).

**Converter rules** (input flags, on in the app via `DeviceModelEngine.rules`; off in the tool unless `--rules`), each
kept only when it measured better on the 32-paper test corpus and on a separate 32-paper set:

| Rule | What it does | Effect (test corpus) |
|---|---|---|
| `transcribe` | An inline formula whose glyphs are letters, digits and plain symbols in known math fonts, on one baseline with one level of scripts, is written as LaTeX from the text layer (`transcribe.ts`) and never reaches the recogniser | 58 % of all formulas; inline typeset share 0.86 → 0.92, glyph accuracy unchanged |
| `fontMath` | Math the tagger missed, found by its fonts (math italic, symbol, blackboard) in lines and table cells, when it can be transcribed | +150 inline formulas |
| `tidy` | A confident recognition Temml refuses (LaTeXML-style rows with bare `&`, `\mathbbm`, `\scalebox`) is tidied and typeset | display typeset share 0.37 → 0.41 |
| `frontMatter` | The library's title and authors find the title page's title and author lines when the layout called them headings | fewer stray headings |
| `headingDupes` | No heading twice: the library's title, "ABSTRACT", a printed contents list | heading precision |
| `lineOwners` | A text line's run belongs to the region holding most of it (headings no longer lose their first or last letters to a neighbouring box) | heading recall and precision |
| `splitReferences` | A references region holding several entries reads as its entries (labels, hanging indents) | whole blocks 0.59 → 0.72 |
| `extendSpans` (off) | Grow tagged formulas over digits, operators and operator names | measured worse on both corpora |

Together: headings 0.91/0.73 → 0.92/0.77 (recall/precision), whole blocks 0.59 → 0.72, inline formula images halved
(2,027 → 1,107), display typeset 0.37 → 0.41, text F1 0.854 → 0.856; inline typeset precision 0.934 → 0.924 (the
newly typeset formulas are the same partial spans that were images before: the tagger's boundaries, not the writing).

**Evaluation tools.** `node scripts/device-route-accuracy.mjs fetch|run|score` (corpus, Mac runs, scores against the
arXiv HTML reading); the tool's `--record` writes the host's answers and `node scripts/device-route-replay.mjs --from
<variant> --to <variant> --set <rule>=true` re-runs the converter on them in Node; `DevicePDFRouteTool --bench-steps`,
`--bench-recogniser`, `--check-determinism`, `--replay-converter` (the converter alone in JavaScriptCore, which has no JIT
in this tool as on the phone). Fixture conformance (`scripts/device-route-eval.mjs`) is unchanged with the rules off.

**Browser.** No change: the browser has no on-device model; a PDF added there is viewed as the PDF.

## Non-arXiv layouts — port revisions 6–9, 2026-10-22/23

Owner, 2026-10-22: "if it works it will be a big unlock for non arXiv papers." Measured on a new corpus of 31 venue PDFs
(ACL, CVF, PMLR, NeurIPS, JMLR, ICLR, SciPost/TACL/Quantum) whose arXiv HTML is the truth, with each paper's arXiv PDF as
a control, besides the two arXiv corpora: [review 2026-10-23](../reviews/DEVICE_PDF_ROUTE_20261023.md).

Ten more converter rules, on in the app, each kept only when it did not lose on any of the three corpora (the harness's
`--also` replays measure each one's own contribution with the others on):

| Rule | What it does | Main effect (test / dev / venue) |
|---|---|---|
| `equationNumbers` | A display's number ("(12)", "(A.3)") set apart, or flush with the box's right edge, is left out of the recogniser's crop and shown as the equation's tag (`reader-tagged`); the image, when the formula is shown as one, keeps it | with `mergeDisplays`: display glyph-right 0.801 → 0.879 / 0.770 → 0.892 / 0.526 → 0.609 |
| `mergeDisplays` | Overlapping display boxes (a group and a row of it) read as one display | (with the above) |
| `lineBands` | A glyph joins a text line by its centre (within the line's band widened by a third of its height) and only widens the band when two thirds inside it, so a script's or a lowered delimiter's box no longer merges two lines | text F1 0.862 → 0.890 / 0.879 → 0.896 / 0.818 → 0.844 |
| `fontAliases` | A font missing from the tagger's vocabulary is read as the one it stands for (Latin Modern sizes, MathDesign, mathabx, MnSymbol, URW Symbol, PLOS's renamed Computer Modern; PLOS's misnamed ( ) =) | venue inline found 0.767 → 0.796, typeset precision 0.807 → 0.884 |
| `captionMath` | Captions keep their math as marked text (formulas owned by the figure's block) | inline found +0.018 / +0.028 / +0.010 |
| `wordGaps` | Word gaps from the line's own letter spacing between text-font letters (justified lines), and the document's when it is set with negative tracking (PLOS) | text F1 +0.005 / +0.003 / +0.006 |
| `bibliography` | A bibliography without a heading read as references (two numbered entries in a reference box); nested boxes of a numbered list merged; an entry continued across regions; it ends at the first non-entry | whole blocks 0.778 → 0.810 / 0.779 → 0.814 / 0.784 → 0.787 |
| `displayPunctuation` | The full stop or comma just outside a display's box joins its LaTeX | display glyph-right +0.005 / +0.002 / +0.011 |
| `accents` | TeX's text accents compose with their letter of the same font ("Naïve") | text F1 +0.001 |
| `venueNotice` | The first page's proceedings line, copyright and open-access watermark (small type, top or bottom band) dropped | venue text F1 +0.001 |
| `displayGate=<n>` (option, not set) | The display gate's threshold | 0.9 loses typeset precision on all three corpora; stays 0.95 |

All on: arXiv test text F1 0.857 → 0.890, display glyph-right 0.801 → 0.879 (typeset precision 0.924 → 0.971), inline
found 0.777 → 0.839; venue text F1 0.795 → 0.844 and shared-content F1 0.872 → 0.899 (the same papers' arXiv PDFs read at
0.898 before). The rules change the reading only; the host's protocol is unchanged (the host now forwards any rule name,
and `name=number` options, to the converter).

**The recogniser** (same weights, longer cache): six in ten field display misses were crops and boxes the model never saw
in training (equation numbers inside, rows cut apart), which the converter now mostly fixes. The app's recogniser is now
`texteller-ft-v4-mf8-int8-l512`: the batched multifunction export with a 512-token decoder cache (`export_texteller.py
--max-len 512`), so recognitions the 256-token cache cut off are read whole; every other recognition is unchanged.
Display glyph-right +0.013 / +0.010 / +0.013, nothing else changes; decoder step 14.1 → 16.0 ms per batch of eight on
the Mac's GPU, a batch's state about 0.41 → 0.51 GB. The review has the plan for the display boxes and a recogniser
trained on crops cut the way the app cuts them.

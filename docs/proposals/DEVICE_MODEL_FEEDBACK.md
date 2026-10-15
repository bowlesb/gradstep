# For the model-building agent: the Mac's numbers and what to work on next (2026-10-15)

From the Science Reader app's agent, after running `docs/MAC_AGENT_INSTRUCTIONS.md` Job 1 on the owner's Mac and
porting the device route into the app (Job 2 inputs). Machine: Apple M1 Max, macOS 26.3.1 (25D771280a), Python 3.9.6,
coremltools 9.0, numpy 2.0.2. Exports copied from `/home/ben/mathpix/data/models/*-coreml` at `21aa26c`.

## Job 1: latency and agreement (your script, unchanged)

| Export | Compute units | Load | Latency | Agreement |
|---|---|---|---|---|
| layout-fcos-v5 fp16 (64.7 MB) | CPU_AND_NE | 4.1 s | 111.5 ms/page median | 91/91 |
| layout-fcos-v5 int8 (32.7 MB) | CPU_AND_NE | 4.6 s | 109.1 ms/page | **88/91** |
| layout-fcos-v5 fp16 | CPU_ONLY | 0.5 s | 211.2 ms/page | 91/91 |
| texteller-ft-v4 fp16 | CPU_AND_NE | **fails to load** | — | — |
| texteller-ft-v4 int8 | CPU_AND_NE | **fails to load** | — | — |
| texteller-ft-v4 fp16 | ALL | 49.5 s | enc 109.9 ms, dec 9.0 ms/token; inline 181 ms, display 696 ms per crop | 20/20 |
| texteller-ft-v4 int8 | ALL | 49.2 s | enc 109.0 ms, dec 8.8 ms/token; inline 179 ms, display 684 ms | 20/20 |
| texteller-ft-v4 fp16 | CPU_AND_GPU | 2.0 s | enc 39.2 ms, dec 9.2 ms/token; inline 110 ms, display 656 ms | 20/20 |
| texteller-ft-v4 int8 | CPU_AND_GPU | 1.6 s | enc 62.2 ms, dec 8.7 ms/token; inline 132 ms, display 647 ms | 20/20 |
| texteller-ft-v4 fp16 | CPU_ONLY | 1.8 s | enc 119.4 ms, dec 11.3 ms/token; inline 203 ms, display 873 ms | 20/20 |
| inline-tagger-v4 (0.67 MB) | CPU_AND_NE | 0.2 s | 5.80 ms/line median | 60/60 lines, 4085/4085 glyphs |

Inline crops average 8 tokens, display crops 66. The recogniser's CPU_AND_NE failure, verbatim:

```
RuntimeWarning: You will not be able to run predict() on this Core ML model. Underlying exception message was: { }
Exception: This model was not loaded with the Core ML Framework. Cannot get state.   (at dec.make_state())
```

The script prints the fp16 sizes for the int8 export too (it reads `encoder_mb`/`decoder_mb` from the copied
`export.json`); on disk the int8 packages are 112 MB (encoder) and 191 MB (decoder-step).

## The same exports in Swift, inside the app's code

The app's Swift wrappers (Core ML from Swift, the app's own canvas, NMS, tokenizer and TexTeller preprocessing)
reproduce your samples exactly: **layout 91/91, tagger 60/60 lines, recogniser 20/20 token sequences and 20/20
decoded strings** (int8, CPU_AND_GPU). Two details you may want in the spec: Core ML returns the layout's
`[30704, 11]` scores and `[30704, 4]` boxes with **strides `[32, 1]`** (padded rows; reading them flat gives garbage),
and the tokenizer's `clean_up_tokenization_spaces: true` must be applied on decode (" ," → ",") to match your strings.

## What to work on next, in order of what it would change for a reader

1. **The decoder's per-token cost is not compute.** 8.7 to 11.3 ms per token on CPU, GPU or both alike, so the
   step is dominated by fixed overhead. The likeliest cause is passing `cross_k`/`cross_v` (2 × 12×1×16×785×64,
   float32 at the input, 2 × 38.6 MB) into every step. Make the cross-attention keys and values part of the state
   (written once per crop by a prefill function of a multifunction model, or an encoder that writes the decoder's
   state), or at least accept float16 inputs. If a step falls to ~2 ms, a display crop goes from ~650 ms to ~150 ms
   and a typical paper (700 inline, 100 display) from ~3 minutes to under one.
2. **The stateful decoder never reaches the Neural Engine** (load failure above). If the ANE matters for phone
   battery and heat, an export the ANE accepts (a fixed-shape KV cache passed in and out, or the ANE's own state
   rules) is the experiment; otherwise state that CPU_AND_GPU is the target and drop ALL (49 s first load).
3. **Decoder length.** The export's cache is 256 tokens (255 generated); the Python reference decodes up to 1,024.
   Long displays (your own analysis: 240+ characters at 0.73) are truncated on the device. Either export a longer
   cache or have the route treat a decode that hits the cache limit as unsure (an image), and say so in the spec.
4. **Batching.** Your route batches crops on the GPU; the device reads one crop at a time. A batch dimension on the
   encoder (and a batched decoder state) would let inline crops of one page share passes.
5. **int8.** It halves the download and costs nothing for the recogniser (20/20) but loses 3/91 layout detections;
   the app ships int8 for the recogniser and fp16 for the layout. A layout int8 that keeps 91/91 (per-channel,
   palettized, or excluding the head) would save 32 MB.

## Job 2: the port's bundles against your fixtures

The app now carries the whole route: a Swift text layer that reproduces pdfminer's characters, the three Core ML
models from Swift, and the converter rules ported to TypeScript (run in JavaScriptCore on the device). Given the same
inputs (your Core ML layout detections, pdfplumber glyphs, fixed tagger and recogniser stand-ins), the port's output
equals your Python route's on all eight fixtures: 1,574 blocks and 3,899 equations identical in kind, text, ids,
LaTeX, confidence, rendered flag and source box. The Swift text layer equals pdfplumber's characters exactly on all
eight PDFs (text, box within 0.05 pt, font, size and upright: 100 %; 481k glyphs).

End to end on this Mac (CoreGraphics rendering, the app's Core ML runs; layout fp16 on CPU_AND_NE, tagger CPU,
recogniser int8 on CPU_AND_GPU), `scripts/bundle_conformance.py` against `fixtures/<id>/bundle`:

| Paper | Pages | Seconds | Blocks | Order | Headings | Equations | LaTeX = | Rendered = | Figures | Tables | Fails |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2603.22973v3 | 20 | 20 | 0.989 | 0.973 | 0.982 | 1.000 | 0.989 | 0.978 | 4/4 | 30/30 | — |
| 2608.10295v2 | 17 | 18 | 0.984 | 0.968 | 1.000 | 1.000 | 0.980 | 0.990 | 6/6 | 8/8 | — |
| 2610.00668v1 | 21 | 146 | 0.978 | 0.957 | 1.000 | 0.989 | 0.976 | 0.967 | 0/0 | 0/0 | tables* |
| 2610.04747v1 | 19 | 52 | 0.966 | 0.936 | 1.000 | 0.984 | 0.946 | 0.975 | 0/0 | 2/2 | order, latex |
| 2610.10076v1 | 18 | 150 | 0.984 | 0.961 | 0.926 | 1.000 | 0.956 | 0.984 | 2/2 | 10/10 | headings |
| 2610.11253v1 | 44 | 82 | 0.945 | 0.893 | 0.979 | 0.993 | 0.945 | 0.952 | 7/7 | 5/5 | blocks, order, latex |
| PMC13605388.1 | 17 | 44 | 0.903 | 0.832 | 0.947 | 0.995 | 0.963 | 0.974 | 11/11 | 5/5 | blocks, order, headings |
| PMC13635322.1 | 19 | 13 | 0.862 | 0.767 | 0.958 | 1.000 | 0.857 | 1.000 | 24/23 | 8/8 | blocks, order, latex, figures |

\* `bundle_conformance.py` fails `tables` whenever the fixture has none (`text_match` is 0 / max(1, 0)); worth a fix.

Seconds include about 6 s of model loading per run. The recogniser is most of the rest: 795 formulas took 137 s on
2610.00668v1 (0.17 s each); layout is about 0.12 s a page, the tagger 0.15 s a page, the rules and MathML 0.1 to 0.3 s
a page here (JavaScriptCore has no JIT on the phone: expect several times that).

### What the gap is made of

1. **Rendering, and one large fixable part of it.** CoreGraphics on macOS smooths fonts by thickening stems; with it
   on, the recogniser read regular letters as bold (`\bm{X}` at 0.36 where your run reads `X` at 0.99) and the
   layout split and merged paragraphs. Turning smoothing off (iOS never smooths) raised 2610.04747v1 from 0.867 to
   0.966 blocks, 0.767 to 0.936 order and 0.859 to 0.946 LaTeX, and took 2608.10295v2 to a pass. The rest of the
   raster difference (CoreGraphics against pdfium antialiasing) remains: on 2610.04747v1's first six pages the same
   Core ML layout gives 52 of 57 detections at IoU 0.9 on the app's canvas and on a pdfium + PIL canvas; the misses
   are boxes near a class threshold (a paragraph scored 0.60 to 0.63 splits from its neighbour). **Training with
   CoreGraphics renders (or renderer augmentation: stem weight, gamma, antialiasing) would make the layout and the
   recogniser robust to the device's own pixels.** The app cannot ship pdfium's rasteriser.
2. **Models in Core ML instead of PyTorch** (fp16 layout, int8 recogniser, fp16 logits for the gate): small, and
   mostly visible in formulas near the 0.8 / 0.95 gates.
3. **Publisher PDFs** are the weakest (the two PMC fixtures): more layout disagreement, and on PMC13635322.1 two
   extra figure detections.

### The phone

- **The iOS Simulator cannot load the stateful decoder** ("Network translation error … std::bad_cast", with
  CPU_AND_GPU and CPU_ONLY alike). The app then reads the paper without the recogniser: every formula is its page
  image, and the banner says so. Whether an iPhone loads it is the first thing the owner's TestFlight run will show;
  the app retries on the CPU before giving up and reports which happened.
- A two-page paper drawn by UIKit reads with run-together words in its 17 pt bold title ("ASynthetic PaperAbout"):
  the words-by-gaps rule (a gap over 0.2 × glyph size) misses UIKit's tighter bold spacing. Arxiv PDFs were fine.

## Two contract details the conformance does not show

- **The text layer.** PDFKit cannot serve as `pdftext.read_pages`: its attributed string reports every glyph's
  font as Helvetica, its character bounds are ink boxes, and its string adds synthetic spaces and line breaks
  (3,288 characters against pdfplumber's 2,822 on 2610.00668v1 page 2). The app therefore carries a content-stream
  reader that reproduces pdfminer's characters (fonts, ToUnicode, encodings and Differences, Type1 headers, CID
  fonts, Type3, form XObjects). A spec section on the exact text-layer contract (pdfminer's `LTChar` geometry, the
  `(cid:N)` fallback, the STIX baseline correction) would help any future port.
- **The bundle vocabulary.** The fixtures' HTML is not what the app's reader and validator admit (an equation image
  inside `span.reader-equation` with a `style`, references chunked into `div.reader-list`, `div.reader-table` without
  `tbody`, `pre` holding formula spans, `data-reader-block="<kind>"`). The port emits the app's vocabulary and writes
  your `index.json` shape beside it only for conformance. If the spec adopted the app's vocabulary
  (`supabase/functions/_shared/reader/html-validate.ts` in the Science Reader repo), future fixtures would be the
  app's bundles directly.

## Requests, in short

1. A decoder step that does not take the cross-attention keys and values as inputs every token (state or prefill).
2. A decoder that loads in the iOS Simulator and (ideally) on the Neural Engine, or a statement that it never will.
3. A longer cache, or "hit the limit means unsure" in the spec.
4. Renderer augmentation in training (CoreGraphics renders without font smoothing are what the phone sees).
5. Fix `bundle_conformance.py`'s `tables` check for papers without tables; consider the app's bundle vocabulary for
   future fixtures (`html-validate.ts`).

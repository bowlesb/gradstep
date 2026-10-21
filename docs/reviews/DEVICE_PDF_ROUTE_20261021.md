# The on-device PDF route: where the time and the errors go, and what changed (2026-10-21)

Owner, 2026-10-21: "Ok, well maybe we can just continue to develop the on device version then? The current version feels
too slow, and not accurate enough, but maybe we can improve it?" (decision recorded in
[DECISIONS](../DECISIONS.md#pdfs-without-arxiv-html-keep-developing-the-on-device-model-no-mathpix-owner-2026-10-21)).
This review measures the route as it shipped (converter port revision 4, the port kit's models), changes it, and
measures again on the same papers. Design: [DEVICE_PDF_ROUTE](../architecture/DEVICE_PDF_ROUTE.md).

## Summary

- **Speed: about 2.8× faster on this Mac, and the paper is on screen in a fraction of the time.** Over 32 fresh papers
  (872 pages, 19,494 formulas), run interleaved with the old route: 4,263 s → 1,529 s (4.89 → 1.75 s a page; median
  paper 105 s → 43 s; per paper ×1.4 to ×6.4, median ×2.4). A reading with every formula as its page image now appears
  while the formulas are still being read: median 15 s after the start, 16 % of the old wait. Of the gain, the
  recogniser's new export and the pipelined host give ×2.5 (first interleaved run: 4,450 s → 1,811 s); writing simple
  inline formulas from the PDF's own text layer (58 % of all formulas never reach the recogniser) gives the rest — less
  than its share of formulas, because the formulas it takes are the cheap short ones.
- **The time was the formula recogniser** (88 % of it), and mostly fixed per-call overhead: one crop at a time, the
  encoder's 77 MB of cross-attention keys converted and passed into every decoder step. The fix is a new export of the
  same weights — one Core ML package whose two functions share one state, eight crops per pass — that gives the same
  tokens on the export's samples (20/20, 80/80 batched); on whole papers a handful of formulas read differently (batched GPU arithmetic): on the eight fixtures LaTeX agreement with the Python reference moved by at most 0.004 either way.
- **Accuracy before:** text 0.85 F1 in reading order (0.92 of words present in any order), 95 % of paragraphs found,
  reading order 0.97, headings 0.91 recall / 0.73 precision; inline formulas 78 % found, 86 % of them typeset, 93 % of
  typeset ones exactly right; display formulas 77 % found but only 37 % typeset (the rest shown as images), 89 % right
  when typeset; tables 0.55 word F1.
- **Accuracy after** (seven converter rules, each kept only when it improved two separate 32-paper sets): headings
  0.92 recall / 0.77 precision; whole paragraphs and entries 0.59 → 0.72 (reference lists no longer run together);
  inline formulas shown as images halved (2,027 → 1,107), 92 % of inline formulas typeset; displays typeset 37 % → 41 %;
  text F1 0.854 → 0.856; tables 0.553 → 0.568. Inline typeset precision 0.934 → 0.924 (explained in §4).
- **What did not improve, and why:** display formulas (still mostly images, 77 % right when read) and inline formula
  boundaries (the tagger's) are the remaining errors. Neither is a renderer problem (CoreGraphics crops read as well as
  the training renderer's, 2,290 crops); the display gap is the recogniser. One rule tried here made things worse and
  is off (`extendSpans`).
- **The pipelined host first read some papers differently from run to run** under load (Core ML's CPU tagger gave
  different answers while the GPU recogniser ran); fixed by never running the two at once. A small residue remains on
  a heavily loaded Mac (7 of 32 papers differed by a few formulas between two runs; aggregates within 0.003).
- **iPhone:** not measured (physical-phone work is paused). Estimate (§6): the old route about 4–7 minutes for a
  20-page paper, the new one about 1½–2½ minutes, the paper on screen in roughly 15–30 s.

## How it was measured

**Machine.** This Mac (Apple M1 Max, 32-core GPU, macOS 26.3.1) through `DevicePDFRouteTool`, which runs the app's own
code: the Swift text layer and Core ML models, the converter in JavaScriptCore. The Mac was shared with other agents'
work (an iOS Simulator running the app, Codex, Photos analysis): GPU utilisation from others sat between 50 and 80 %.
Absolute seconds are therefore noisy; the before/after timing was run **interleaved per paper** (before then after,
after then before on the next paper) so the load falls on both alike. No iPhone was used; the iPhone figures are
estimates and say so.

**Papers.** A fresh corpus of 32 arXiv papers submitted in the week before 2026-10-21 (after every model in the route was
trained, so none can be in their training data), four from each of cs.LG, cs.CL, cs.CV, stat.ML, math.OC, quant-ph,
hep-th and cond-mat.stat-mech by primary listing (16 ML/CS/statistics and 14 physics/maths among the 30 scored; 5 to 76
pages, 872 pages in all), each with the exact revision's PDF and arXiv HTML, fetched on this Mac at the app's pace and
kept in `~/gradstep-mac/device-route-corpus`. Two papers are timed but not scored: the app's own arXiv HTML reader
refuses their HTML (`arxiv_nested_content`). A second set of 32 newer papers (`~/gradstep-mac/device-route-corpus-dev`,
no overlap) was used to decide which rule changes to keep, so the rules are not chosen on the papers they are scored on.
The desktop's eight fixture papers were also re-run against the port kit's Python reference (`scripts/device-route-eval.mjs`):
unchanged from 2026-10-15 (three pass every gate; block match 0.86–0.99).

**Ground truth.** The app's own arXiv HTML reader (`convertArxivHTML`) on the same revision: the reading an arXiv paper
gets today. `scripts/device-route-accuracy.mjs` reads both bundles' pages as blocks of words and formulas and scores:

| Measure | What it is |
|---|---|
| text F1 | words (letters only) aligned in order (longest common subsequence) between the two pages; recall and precision against each side |
| bag recall | the same words in any order: the gap to text F1 is reading order and duplication |
| blocks found, whole | each HTML block (6+ words) found in one device block (half its words in order); "whole" when the device block is the same block (≥ 0.8 of both); otherwise merged (the device block holds it and more) or split |
| order | pairs of found blocks in the same order on both sides |
| headings | HTML h1–h4 titles (run-in `\paragraph` titles that open a device paragraph left out) found among the device's headings; precision counts a heading made twice |
| formulas | each HTML formula paired with the device formula of the same placement nearest in glyphs, between the words matched around it; then **glyph match**: both render to the same MathML characters (NFKC, spacing ignored) — robust to macros where LaTeX strings are not. Recall = paired / HTML formulas; typeset share = shown as MathML / device formulas; typeset precision = typeset and glyph-equal / typeset paired (the errors a reader cannot see). Numbers set in math (`$48$`) count as text on both sides |
| tables, figures | counts, and the words inside tables in order |

Two things the HTML has that the PDF does not print are left out of the truth: arXiv's "Cited by"/"External links"
back-references in each bibliography entry, and the HTML reader's h5/h6 theorem and proof labels.

## 1. Where the time went (before)

The route as shipped (TestFlight builds since 49: port kit export, two crops in flight), 32 papers, busy seconds per
stage on this Mac:

| Stage | Seconds | Share | Per unit |
|---|---|---|---|
| formula recognition (encoder + greedy decoding, GPU) | 3,889 | 88 % | 0.20 s a formula (19,493 formulas) |
| converter (JavaScriptCore: the rules, Temml, PNG and bundle work, and the bridge) | 207 | 4.7 % | 0.24 s a page |
| inline tagger (CPU, one prediction per line) | 172 | 3.9 % | 0.20 s a page |
| layout (Neural Engine) | 117 | 2.6 % | 0.13 s a page |
| page rendering, formula and figure images, text layer | 43 | 1 % | |
| **wall** | **4,450** | | **5.10 s a page; median paper 125 s (22 s to 6 min)** |

Physics and maths papers carry twice the formulas of ML papers: 6.8 s a page against 3.7.

Measured underneath the recogniser (`DevicePDFRouteTool --bench-steps`, blank crops): the port kit's export spends 60 ms
in the encoder, 30 ms converting its float16 output to the float32 the decoder takes, then 12.7 ms per token, on a GPU
step whose compute is tiny — the step's time is dispatch and the 77 MB of keys and values passed in each call. Batching
that export does not help (8 crops: 4.2 ms a crop-token with float16 inputs, 28–34 ms a crop of encoder; the inputs grow
with the batch). The desktop's "cross-state" export (keys and values in state, written on the first step) was slower per
crop on this Mac in October (200 + 160 ms of shape re-specialisation per crop). What works: a **multifunction package**
whose `prefill` and `step` functions share one state (a state made by one function serves the other; verified on CPU
and GPU), fixed shapes in both. At a batch of eight: encoder 35 ms a crop, decoder step 14 ms for eight crops (1.7 ms a
crop-token), no conversion. Batch 16 gains little (1.5 ms; 2× the state memory); float16 weights instead of int8 save
another 17 % of encoder time for 100 MB more of app (not taken).

The converter alone, replayed in JavaScriptCore on recorded host answers (`--replay-converter`): 0.07–0.16 s a page.
JavaScriptCore runs without a JIT in this tool, as an app's `JSContext` does on iOS (a tight loop measured at
interpreter speed with and without `JSC_useJIT`), so this is the phone's case up to CPU speed.

## 2. Speed changes and what they gave

1. **The batched multifunction recogniser** (above), same tokens on the samples, a handful of formulas different on whole papers.
2. **Background recognition** (port revision 5's `submit`/`collect`): formulas are read while the converter reads the
   following pages, in batches of one placement, narrowest first; two batches in flight on large-memory devices.
3. **Pages read ahead**: render, text layer and layout of the next pages on two threads while the converter works.
4. **A reading before the formulas are read** (`onPreview`): the app shows the paper, every formula its page image, under
   the progress bar ("Typesetting formulas · n of m"), and swaps in the finished reading at the same place.
5. **Simple inline formulas from the text layer** (`transcribe`, a converter rule): 58 % of all formulas never reach the
   recogniser (11,314 of 19,484 on the test corpus).
6. **Determinism**: the pipelined host first read some papers differently from run to run under load — Core ML's CPU
   tagger gave different logits for the same line while the GPU recogniser predicted (25 of 920 lines on one paper, logit
   differences up to 10). The tagger and the recogniser now never predict at once, layout predictions are serialised,
   and two conversions of one paper on a loaded Mac give byte-identical readings equal to the serial order. (The first
   interleaved run below predates this fix; its timings stand, its accuracy is not used.)

Two interleaved runs against the old route, 32 papers each (the second under heavier load from other work on the Mac,
so its old-route time is its own):

| | Run 1: old | Run 1: new (1–4, 6 not yet) | Run 2: old | Run 2: new with rules (1–6) |
|---|---|---|---|---|
| wall seconds | 4,450 | 1,811 (×2.46) | 4,263 | 1,529 (×2.79) |
| seconds a page | 5.10 | 2.08 | 4.89 | 1.75 |
| median paper | 125 s | 47 s | 105 s | 43 s |
| per paper | | ×1.3 to ×4.0 (median ×2.3) | | ×1.4 to ×6.4 (median ×2.4) |
| reading on screen (preview) | at the end | median 14 s | at the end | median 15 s (39 % of the new total, 16 % of the old) |
| recogniser busy seconds | 3,889 | 2,926 (two batches at once) | 3,737 | 2,352 |

Where the new route's time goes now (run 2, busy seconds; stages overlap): recogniser 2,352 (11,314 of 19,494 formulas
transcribed instead), tagger 214, layout 190 (two pages at a time on the Neural Engine), page renders 40, images 22,
text 4. The JavaScript thread's own share (rules, Temml, bundle) is about 0.1 s a page.

Not done, measured: running the encoder on the Neural Engine (the compile of the batched int8 encoder had not finished
after 100 CPU-minutes); more tagger threads (gave wrong answers under load, above).

## 3. Where the errors were (before)

Thirty scored papers (two are refused by the HTML reader); the second set of 26 scored dev papers in brackets.

| Measure | Test | (Dev) | Reading |
|---|---|---|---|
| text F1 in order / bag recall | 0.854 / 0.920 | (0.873 / 0.942) | words are nearly all there; order and duplication cost 7 points |
| blocks found / whole / merged / split | 0.953 / 0.589 / 0.216 / 0.159 | (0.970 / 0.615) | paragraphs are 85 % whole; **reference entries are merged** (66 % of bibliography items share a block with a neighbour) |
| order (pairs / adjacent) | 0.974 / 0.931 | (0.976 / 0.933) | |
| headings recall / precision | 0.905 / 0.725 | (0.776 / 0.667) | false headings: printed contents lists, the title or "ABSTRACT" twice, headings cut at a box edge ("ic droplet size") |
| inline formulas: found / glyph-right / typeset / typeset right | 0.783 / 0.909 / 0.858 / 0.934 | (0.811 / 0.905 / 0.853 / 0.938) | of the formulas not found, half sit in tables, 16 % in captions, 30 % in paragraphs; of typeset errors, 53 % are boundaries (the tagger cut the formula: "cos θ" typeset as θ), the rest content or pairing |
| display formulas: found / glyph-right / typeset / typeset right | 0.767 / 0.769 / 0.374 / 0.894 | (0.823 / 0.714 / 0.389 / 0.869) | **most displays are images**: the gate passes 37 %; 72 confident recognitions were images only because Temml refuses their LaTeXML-style rows |
| tables (cells / truth, word F1) | 195 / 221, 0.553 | (120 / 153, 0.515) | |
| figures | 265 / 259 | (219 / 209) | |

ML papers read better than physics and maths (text 0.858 against 0.849; display formulas right 0.83 against 0.74) and
have fewer inline formulas found in the text (0.74 against 0.81: more of theirs sit in tables).

**The gate** (displays: second-lowest token probability ≥ 0.95; inline: lowest ≥ 0.8) is where it should be on these
papers: lowering the display threshold to 0.8 would typeset 72 % of paired displays instead of 39 %, at 0.85 precision
instead of 0.89. That is a choice of errors that look right over images; it was not changed.

**Rendering is not the recogniser's problem.** The desktop's equation bench (2,290 gold crops) cut from the Mac's
CoreGraphics renders reads as well as from the bench's own pdfium renders (display 0.799 against 0.795, inline 0.938
against 0.935; identical outputs for 91 % and 98 %; the 166 held-out-family crops: equal). Truncation at the 255-token
cache touches 3 of 790 displays. So fine-tuning on device renders would not pay; the display gap is the model.

## 4. Accuracy changes

Converter rules, each a switch, each tried on the recorded runs of both corpora by replay and kept only when both
improved (the full table is in [DEVICE_PDF_ROUTE](../architecture/DEVICE_PDF_ROUTE.md#development-after-the-port-kit--port-revision-5-2026-10-21)):

| Rule | Test corpus effect (replay) | Dev corpus effect (replay) | Decision |
|---|---|---|---|
| `transcribe` | inline typeset 0.859 → 0.921, typeset right 0.934 → 0.920, glyph-right 0.909 → 0.910 | 0.853 → 0.909, 0.938 → 0.929, 0.905 → 0.904 | on (speed; same accuracy) |
| `fontMath` (with transcribe) | +150 inline formulas, found 0.782 → 0.784 | 0.811 → 0.815 | on |
| `tidy` | display typeset 0.374 → 0.412, right 0.894 → 0.888 | 0.389 → 0.410, 0.869 → 0.872 | on |
| `frontMatter` | heading precision +0.5 | +0.1 | on |
| `headingDupes` | heading precision +0.4 | +0.6 | on |
| `lineOwners` | headings 0.905/0.725 → 0.923/0.755 | 0.776/0.667 → 0.799/0.695 | on (formula effect checked in a real run: none) |
| `splitReferences` | whole blocks 0.589 → 0.718 | 0.615 → 0.738 | on |
| `extendSpans` | glyph-right 0.910 → 0.888, typeset right 0.920 → 0.900 | 0.904 → 0.879, 0.929 → 0.914 | **off** |

All seven together, real runs (not replays):

| Measure | Test before | Test after | Dev before | Dev after |
|---|---|---|---|---|
| text F1 / precision | 0.854 / 0.865 | 0.856 / 0.870 | 0.873 / 0.879 | 0.876 / 0.884 |
| whole blocks, mean per paper | 0.589 | 0.721 | 0.615 | 0.746 |
| headings recall / precision | 0.905 / 0.725 | 0.920 / 0.765 | 0.776 / 0.667 | 0.799 / 0.705 |
| tables word F1 | 0.553 | 0.568 | 0.515 | 0.521 |
| inline formulas found / glyph-right / typeset / typeset right | 0.782 / 0.909 / 0.859 / 0.934 | 0.781 / 0.914 / 0.923 / 0.924 | 0.811 / 0.905 / 0.853 / 0.938 | 0.818 / 0.908 / 0.909 / 0.932 |
| inline formulas shown as images | 2,027 | 1,107 | 1,805 | 1,132 |
| display formulas typeset / typeset right | 0.374 / 0.894 | 0.412 / 0.888 | 0.389 / 0.869 | 0.410 / 0.870 |

All blocks pooled on the test corpus: merged 0.216 → 0.079, split 0.159 → 0.169. Formulas typeset in all: 15,875 → 17,049
of about 19,480.

The one number that moved the wrong way, inline typeset precision (0.934 → 0.924), is the rules typesetting what was an
image before: the same span of glyphs the tagger chose, now written as math. Where the tagger cut a formula short the
image showed the same partial formula; what changes is that it is now text and the metric counts it as typeset-wrong.

## 5. What did not improve

- **Display formulas** are still mostly images (41 % typeset) and 77 % glyph-right when read. The recogniser is the limit
  (bench: 0.80 normalised exact on displays), not the renderer, the crop or the cache. The desktop's two later
  fine-tunes (v5, v6) were negatives; a better display model is the main open accuracy problem.
- **Inline formula boundaries**: the tagger's spans decide them, and its remaining errors are mostly glyphs the text layer
  cannot tell from prose (upright `\mathrm`/`\text` runs, lone letters in the text font; the desktop's error analysis).
  Growing spans by rule made things worse (`extendSpans`, off).
- **Inline formulas in tables and captions**: half and a sixth of the misses. `fontMath` finds some in cells; captions keep
  their math as plain text (the converter writes captions as text, not marked text).
- **Tables**: 0.57 word F1. Cells come from the text layer by gaps; spans and multi-line cells are the losses.
- **Reading order of references** in two-column bibliographies without a "References" heading (REVTeX).

## 6. The iPhone (estimate, not measured)

Nothing here ran on a phone (physical-phone work is paused; the iOS Simulator cannot load the stateful recogniser). The
estimate scales the Mac's per-stage times by stated assumptions, and should be replaced by the owner's first TestFlight
reading: the banner's report ("Report a problem with this reading") carries the per-stage seconds.

| Stage | Mac (M1 Max) | Assumption for an iPhone 16/17 Pro | Phone estimate |
|---|---|---|---|
| recogniser (GPU) | old 4.3 s a page; new about 1.5 s a page of wall time | a phone GPU has about a fifth of this Mac's compute and memory bandwidth; per-call overhead does not shrink. Factor 3–5 | old 13–22 s a page; new 4–7 s a page |
| layout (Neural Engine) | 0.13 s a page | the A17 and later Neural Engine is faster than the M1's: factor ≤ 1 | ≤ 0.13 s, read ahead |
| tagger, converter, rendering (CPU) | about 0.45 s a page | one phone performance core is as fast or faster than one M1 Max core; the converter already runs without a JIT here, as on iOS | about 0.4–0.5 s a page |

So for a 20-page paper of average formula density (about 22 formulas a page): the old route about 4–7 minutes, the new
one about 1½–2½ minutes, with the reading on screen after the layout and reading pass, roughly 15–30 s. The recogniser's
share is larger on a phone than on the Mac, so batching and transcription should gain at least as much there as here. On
phones with less than 7.5 GB of memory only one batch is in flight (each holds about 0.4 GB of state), which costs about
12 % of recogniser throughput on the Mac. Untested risks: whether a phone loads the multifunction stateful package (the
desktop's single-function stateful decoder never reached a phone either; the route degrades to formula images and says
so if it does not), and memory pressure on 6 GB phones.

## 7. What's next

1. **Measure on a phone.** One TestFlight reading of a paper the owner knows, reported from the banner, gives the
   per-stage seconds and whether the multifunction recogniser loads; that settles the estimate above and the
   batches-in-flight rule.
2. **Display formulas** are the largest accuracy gap (59 % still images, 77 % right when read). Options, in order of
   cost: beam search for displays only (measure accuracy against time on the bench); a recogniser trained with more
   display data or a larger decoder (the desktop's v5/v6 runs were negatives, so this needs a new idea, not more
   steps); letting the owner choose a lower display gate (72 % typeset at 0.85 precision instead of 39 % at 0.89).
3. **Inline boundaries and misses**: formulas in captions (written as plain text today: captions are not marked text);
   a tagger with image features or a joint boundary-and-transcription pass for the upright-math cases the text layer
   cannot tell from prose.
4. **Encoder cost on the phone**: the encoder is now most of the recogniser's per-crop time. A float16 prefill saves
   17 % on this Mac for 100 MB; the Neural Engine would be the real win on a phone but the batched int8 encoder's compile
   did not finish; a one-crop float16 encoder for the Neural Engine is the experiment to try, on a phone.
5. **Tables** (0.57 word F1): a structure model was in the desktop's plan; cells by gaps lose spans and multi-line cells.
6. **Layout v6** (the desktop's renderer-jittered detector, 0.913/0.854 against v5's 0.910/0.844 on its own pixels, and
   cleared for int8, 31 MB smaller): not evaluated end to end here for lack of a quiet machine; it is one run of
   `device-route-accuracy.mjs` with `~/gradstep-mac/variants/mf8-v6i8` away.
7. **Residual nondeterminism** under extreme load (a few formulas on a few papers): find which prediction still
   interferes (layout on the Neural Engine alongside the tagger is the candidate) before relying on byte-identical
   re-reads.

## Checks

- `npm test` passes; `swift test --filter DevicePDF` (15 tests) passes; the Catalyst app builds.
- Fixtures (`scripts/device-route-eval.mjs --conformance`, new models and host, rules off): conformance unchanged apart
  from a few formulas read differently by the batched recogniser — LaTeX agreement 0.945 → 0.949, 0.956 → 0.953,
  0.945 → 0.943 on three fixtures, and the rendered-formula flag on 2610.11253v1 now narrowly fails (0.952 → 0.950).
  Conversion time on the fixtures is about half (e.g. 152 → 65 s).
- Simulator `DeviceModelJourneyTests` (iPhone 17 Pro): failed twice with the new converter while the machine was under
  heavy load (the reader stayed on "Preparing…"; the same bundle converted correctly on the Mac), passed on a rebooted
  Simulator on a quieter machine. Recorded as load-sensitive, not as fixed.
- Not run: any iPhone (paused), the recogniser in the Simulator (it does not load there).

## Files

- Corpora (this Mac, not committed): `~/gradstep-mac/device-route-corpus` (test), `~/gradstep-mac/device-route-corpus-dev`.
- Runs and scores: `.artifacts/device-route/accuracy/<variant>/` (`baseline`, `pipe1`, `pipe3`, `final1`, `final2`,
  `dev-pipe3`, replays `*-r-<rule>`), each with `accuracy.json`.
- Exports: `/home/ben/science-reader-device-pdf/exports/` on the desktop (batched and multifunction variants), copied to
  `~/gradstep-mac/exports`; the shipped one is `texteller-ft-v4-mf8-int8`.
- Recogniser renderer bench: `/home/ben/science-reader-device-pdf/runs/cg-bench*/` (`scripts/device-pdf-models/cg_equation_bench.py`).

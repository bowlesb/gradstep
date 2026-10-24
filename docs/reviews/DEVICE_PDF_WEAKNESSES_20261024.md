# The on-device PDF route's weaknesses, measured, and the first fixes (2026-10-24)

Owner, 2026-10-24: "I like it so far, I want to build a tool that will help clarify its weaknesses so we can improve them
… Also just generally improving the model and making it faster and accurate." Design:
[DEVICE_PDF_ROUTE](../architecture/DEVICE_PDF_ROUTE.md); earlier rounds: [2026-10-21](DEVICE_PDF_ROUTE_20261021.md),
[2026-10-23](DEVICE_PDF_ROUTE_20261023.md). Local source and evaluation only; nothing released, uploaded or deployed.

## Summary

- **A weakness explorer** (`scripts/device-route-weaknesses.mjs`, section 1): every difference between the route's reading
  and the arXiv HTML reading of 83 papers (2,140 pages: 30 arXiv test, 26 arXiv dev, 27 venue PDFs) sorted into 35
  categories with a stage, a severity and a place on the page; impact = severity-weighted incidents per 10 pages; the
  worst examples as page crops beside both readings; time per stage per page; rerunnable with `--baseline`. Reports:
  `.artifacts/device-route-weaknesses/base/` (before) and `after/` (after, with the change beside every number).
- **The biggest weaknesses before** (impact per 10 pages, all corpora): inline math missed 2.59 (tagger; a third in
  tables, a quarter numbers with ± that read the same as text), inline math cut short or overgrown 2.41 (tagger spans),
  **displays left as images 1.81 — 1,835 of 2,281 of them were read right and held back only by the confidence gate**,
  text missing 1.74 (mostly convention; the real part was lines read twice over and interleaved), inline formulas typeset
  wrong 1.56, inline formulas left as images 1.02 (1,701 of 2,722 right), displays missed 1.01 (the layout boxed no display:
  read as inline fragments), words split, joined or misread 0.98 (ligatures, compounds at line ends, interleaved lines).
  By stage: converter 6.3, tagger 5.0, recogniser 3.7, layout 3.4, text layer 1.4.
- **Fixed** (converter port revision 11; each rule measured by replay on all three corpora, then in real runs of the app's
  models): `verifyGlyphs` typesets a reading under the gate when its letters, digits, accents and operators are the page's
  own glyphs — displays typeset 43 % → 81 % (test), 43 % → 78 % (dev), 25 % → 61 % (venue), inline 92 % → 97 %; `lineReturns`
  stops two lines merging through a script's box — text F1 +0.006 / +0.003 / +0.005, whole paragraphs +0.013 / +0.005 /
  +0.011, inline formulas found and right +0.007 to +0.009; `ligatures` and `compounds` (words); `reuseRecognitions` reads
  a repeated formula once (18–27 % fewer recogniser crops). Total impact 19.8 → 17.0 per 10 pages (−15 %); displays left as
  images 1.81 → 0.78, inline images 1.02 → 0.40, words 0.98 → 0.51, text missing 1.74 → 1.16.
- **The price, stated**: typeset displays whose glyphs differ from the truth rise from 2.4 % to 4.2 % of typeset displays on
  the arXiv test corpus by the strict scorer (typeset precision 0.976 → 0.958; venue 18 % → 22 %, 0.816 → 0.778). Reading the 21 newly
  "wrong" test displays and 63 venue ones one by one: most are the scorer's (author macros the truth cannot render, \bar
  against \overline, a venue version that renamed its variables), a few carry their equation number inside, about eight
  are a layout box that cut the formula (its image showed the same cut), one is a misread (a missing integral sign).
- **Speed**: not shown. The recogniser now does 18–27 % fewer crops and orders its batches by the formula's glyph count
  (simulated on the recorded lengths: 11 % fewer decoder batch steps), but an interleaved A/B on 12 papers on a Mac at
  load 120–300 measured no difference (623 s against 599 s, per paper ×0.68 to ×1.65). Where the time goes is now
  measured per page: 73 % of a conversion is spent after the last page waiting for the recogniser (section 3).
- **Not kept**: `displayLines` (a numbered display the layout read as a paragraph's line becomes a display: +0.010 displays
  found on every corpus, but their typeset precision 0.004–0.006 lower; off, available); `dedupeGlyphs` (no gain; removed).
  No model was retrained: the report points at the tagger and the layout's display boxes, not the recogniser (section 5).

## 1. The weakness explorer

`node scripts/device-route-weaknesses.mjs --runs <variant>@test,<variant>@dev,<variant>@venue --name <name> [--baseline <name>]`

It reads runs of the route made with `device-route-accuracy.mjs run … -- --record --trace` (or Node replays of them), the
same papers' arXiv HTML reading (the app's own `convertArxivHTML`, as the accuracy harness), and the run's record (the
page's glyphs and layout regions as the host gave them). For every paper it aligns the two readings and sorts every
difference into one of 35 categories, each incident with a severity from 0 to 1, a location on the PDF page and the
stage that most likely caused it:

| Group | Categories | How an incident is found | Stage |
|---|---|---|---|
| Text | missing, added, read twice, out of place, words split/joined/misread | gaps between the in-order word alignment; a run found (in order) elsewhere on the other side is *out of place*; a run located in the PDF's text layer and the layout region holding it decide the stage | no layout region / inside a figure or table box → layout; in a text region → converter; not in the text layer → truth (HTML-only text) or text layer; letters of two lines interleaved → converter (line building) |
| Order | blocks out of order | matched blocks off the longest in-order chain (figures, tables, references left out) | converter |
| Furniture, footnotes | page furniture, footnotes in the flow, footnotes and floats placed differently | added text in the page's top or bottom band; footnote regions or `reader-footnote` blocks | converter; placement is a convention (no impact) |
| Headings | missed, spurious, wrong level | HTML h1–h4 against device headings, run-in titles and lettered section numbers ("Appendix A", "II") left out | the layout's class at the heading's place |
| Displays | missed, split, merged, typeset wrong, left as image | each HTML display paired with a device display (as the harness pairs, then the same glyphs nearby); token edit distance of the normalised LaTeX | split/merged/missed → layout; image or wrong → recogniser |
| Inline math | missed, cut or overgrown, typeset wrong, left as image | as displays; a table's formulas paired by glyphs first (the readers order cells differently); numbers with ± or × read as text, or a formula inside a longer device formula, count at low severity | tagger (spans); recogniser; converter for a wrong transcription |
| Tables | missed, flattened to text, shown as image, cells wrong | each HTML table against device tables by word overlap; cells by word F1 | layout; converter |
| Figures, captions | missed, badly cropped, spurious, caption detached | paired by caption words; the crop against what the PDF draws near it (PyMuPDF: images and vector drawings, `scripts/device-route-graphics.py`): coverage and IoU | layout |
| References | merged, split, missing | each HTML entry (its "Author (year)" label left out) against device entries and paragraphs | converter |
| Front matter | title, authors, abstract | title words, author names' recall, abstract word F1 | converter |

Conventions the two readers simply differ on carry no impact but are listed: citations the HTML writes "Evans (1979)"
where the PDF prints "[12]", bibliographies LaTeXML regenerates in its own order and format (compared entry by entry, not
as running text), footnotes at their mark against at the foot of the page, floats where the source defines them against
where they are printed, and text the PDF does not print.

**Impact** is severity-weighted incidents per 10 pages; the report is sorted by it. Each category's severity rule is
printed in the report (for example: a missing run of words, words/30 up to 1; a display typeset wrong, its LaTeX token
error but at least 0.3; a display left as an image 0.25, 0.15 when its reading was right; inline math missed 0.25).

**The page** (`.artifacts/device-route-weaknesses/<name>/index.html`) has the measures per corpus (with the change from
`--baseline`), the categories by impact with their stages, impact by stage and by corpus, the time per stage per page,
the papers by impact, and for each category the worst examples (at most two per paper): the PDF page crop rendered by
the route's own Core Graphics path with font smoothing off (`DevicePDFRouteTool --render-crops`), the incident outlined
in red over the layout's regions (the device crop or formula box in blue, what the PDF draws in green), the device's
reading (its HTML, MathML or formula image) and the HTML truth side by side. `report.json` and `incidents.json` hold the
numbers and every incident for scripts; `--baseline <name>` puts an earlier report's numbers beside every measure.

**Per-page timing.** The host now keeps busy seconds per page and stage (`host_pages` in the tool's conversion.json):
render, text, OCR and layout per page (read ahead), the tagger's and the converter thread's time while the page is read
(`read`), image crops, and the page's share of its recogniser batches; `finish` is the time after the last page
(waiting for the recogniser, then the bundle).

## 2. How it was measured

The three corpora of the [2026-10-23 review](DEVICE_PDF_ROUTE_20261023.md): 32 fresh arXiv papers (test, 30 scored), 32
newer ones (dev, 26 scored; rules are kept only when they win on both) and 31 open-access venue PDFs scored against the
same papers' arXiv HTML (27 scored). No new papers were fetched. Runs: `DevicePDFRouteTool` frozen per variant
(`~/gradstep-mac/tools/wk0`: the shipped host and converter revision 10 with the app's 17 rules; `wk1`: this round's host
and converter revision 11), every run recorded. Rule effects are replays of the baseline's records with one rule on, then
confirmed in real runs (`wk1`) with ablation replays of their records (`--also` the baseline's, so a rule's absence finds
its crops). The Mac was shared throughout (load averages 25 to 500, Simulators and builds of other agents; the disk ran out
twice and runs were resumed); accuracy does not depend on it, seconds do.

## 3. Weaknesses before (baseline: the app as of TestFlight 90)

All 83 papers, by impact (severity-weighted incidents per 10 pages); the last column is after this round's rules (section 4):

| # | Category | Impact | Incidents | per 10 pages | Papers | Stages | Largest kinds | After |
|---|---|---|---|---|---|---|---|---|
| 1 | Inline math missed | 2.59 | 2,870 | 13.4 | 80 | tagger | in a paragraph 977; in a table 700; numbers with ± or × read as text 692 (low severity) | 2.40 |
| 2 | Inline math cut or overgrown | 2.41 | 1,526 | 7.1 | 78 | tagger | cut short 714; read as two formulas 315; only digits or punctuation outside 312 | 2.75 |
| 3 | Display left as image | 1.81 | 2,281 | 10.7 | 78 | recogniser (gate) | **right but held back by the gate 1,835**; a wrong reading held back 444 | 0.78 |
| 4 | Text missing | 1.74 | 3,032 | 14.2 | 83 | truth 1,746; converter 1,100; layout 186 | citations written differently 543 (convention); in a paragraph region 469 | 1.16 |
| 5 | Inline math typeset wrong | 1.56 | 555 | 2.6 | 57 | recogniser 285; transcription 270 | | 1.53 |
| 6 | Text added | 1.37 | 2,394 | 11.2 | 83 | truth 1,426; text layer 608; converter 229; layout 131 | printed in the PDF, not the HTML 1,426 (no impact); unreadable runs 608; two lines read as one 131 | 0.99 |
| 7 | Inline math left as image | 1.02 | 2,722 | 12.7 | 78 | recogniser | right but held back 1,701 | 0.40 |
| 8 | Display missed | 1.01 | 269 | 1.3 | 52 | layout | read as inline formulas 198 | 1.00 |
| 9 | Words split, joined, misread | 0.98 | 2,593 | 12.1 | 82 | text 1,652; converter 941 | ligatures (ﬁ, ﬂ), compounds at a line end ("threedimensional"), interleaved letters | 0.51 |
| 10 | Text out of place | 0.67 | 437 | 2.0 | 74 | converter | | 0.67 |
| 11 | Blocks out of order | 0.63 | 462 | 2.2 | 71 | converter | | 0.60 |
| 12 | Table cells wrong | 0.52 | 212 | 1.0 | 45 | converter | word F1 under 0.5: 89 | 0.52 |
| 13 | Heading at the wrong level | 0.45 | 478 | 2.2 | 62 | converter | | 0.45 |
| 14 | References split | 0.37 | 533 | 2.5 | 49 | converter | | 0.36 |
| 15 | Table flattened to text | 0.37 | 98 | 0.5 | 38 | layout | no table box 40; boxed as a listing 32 | 0.37 |
| 16 | Headings missed | 0.34 | 182 | 0.9 | 45 | layout 122 | | 0.33 |

Below these: spurious headings 0.29, figures missed 0.26 (their caption read as text 67), references merged 0.19
(a bibliography read as paragraphs 174), captions detached 0.19, page furniture 0.16, figures badly cropped 0.15 (mean IoU
of figure crops against what the PDF draws there: 0.82), abstract 0.14, text read twice 0.13. By stage: converter 6.3,
tagger 5.0, recogniser 3.7, layout 3.4, text layer 1.4 (truth/convention 4,313 incidents, no impact).

By corpus the order holds; venue PDFs are worse on everything textual (text missing 2.74 against 1.04–1.50 per 10 pages,
added 2.37 against 0.74–1.06), and inline math (missed 3.40, typeset wrong 2.33). Per template (mean impact per 10 pages):
PMLR 22, ACL 19, NeurIPS 19, ICLR 20, other 28, CVF 36 (the CVPR PDF with no usable text layer), JMLR 42 (long derivations).
The worst single paper (2610.26832v1, 69) is a maths paper whose inline formulas the tagger mostly missed.

**What the examples show** (the report's crops):

- *Inline boundaries.* A formula broken across a line end ("p =" | "p₀ẑ"), a tagger span that stops at an operator
  ("W" for "W ≠ 0", "∑(c_m − N_min)" for "N_c = ∑ w_m = ∑(…)"), operator names left out ("θ" for "cos θ"). Spans that only
  leave digits outside ("±" for "2.73 % ± 1.84 %") are a quarter of them and read the same.
- *Displays missed* are almost all numbered displays the layout boxed as part of a paragraph or not at all (their lines then
  orphans), read as a row of inline formulas.
- *Interleaved text* ("tfoioontp, rtihnet seyvsatleum…"): a line's subscripts widen its band down to the next line's top,
  and the next line, starting again at the left, joins it. 25 of 56 arXiv papers had at least one such line.
- *Figures*: crops are mostly right (IoU 0.82); the cut ones are subfigure grids boxed as several figures and figures
  whose axis labels fall outside the box. A figure "missed" is usually one whose caption the layout read as text.
- *Tables*: cells by gaps lose spanning headers and multi-line cells; 40 tables had no table box at all.

**Time per stage per page** (busy seconds on this loaded Mac, 2,140 pages; stages overlap):

| Stage | Mean | p50 | p90 | Max |
|---|---|---|---|---|
| render (150 dpi) | 0.07 | 0.02 | 0.15 | 9.9 |
| text layer | 0.006 | 0.004 | 0.011 | 0.65 |
| OCR (unreadable pages only) | 0.02 | 0 | 0 | 3.5 |
| layout (Neural Engine) | 0.21 | 0.21 | 0.23 | 0.66 |
| tagger | 0.36 | 0.27 | 0.68 | 3.6 |
| recogniser (the page's share of its batches) | 3.44 | 1.71 | 9.06 | 34.5 |
| converter thread, the page read (`read`, tagger and crops included) | 0.48 | 0.38 | 0.86 | 4.8 |
| image crops | 0.03 | 0.02 | 0.08 | 0.47 |

2.25 s a page of conversion, the reading on screen (preview) after a median 20.8 s, 0.37 busy seconds per recognised
formula. **73 % of each conversion is spent after the last page is read, waiting for the recogniser.** The slowest pages
are not the formula-dense ones: a NeurIPS page with 10 recognised formulas took 32 s, because a batch runs until its longest
reading ends and a reading that runs on to the 512-token cache (20 of 8,307 crops on the test corpus) holds seven others.

## 4. What changed (converter port revision 11, host)

| Change | What it does | Test | Dev | Venue | Decision |
|---|---|---|---|---|---|
| `verifyGlyphs` | A reading under the confidence gate (confidence 0.5 and up) is typeset when its letters, digits, accents (ˆ ˜ ¯ ˙ ¨ ˚ …) and plain operators (= + − , ; < > ≤ ≥ × ∗ ′) are exactly the formula's glyphs in the text layer, as many of each; delimiters and bars, which the text layer names inconsistently, are left out | display typeset 0.43 → 0.81, typeset precision 0.973 → 0.952; inline typeset 0.92 → 0.97, precision 0.938 → 0.935 | 0.43 → 0.78, 0.964 → 0.954; 0.91 → 0.96, 0.940 → 0.929 | 0.25 → 0.61, 0.812 → 0.773; 0.80 → 0.88, 0.888 → 0.879 | **on** |
| `lineReturns` | A glyph that returns to the left below its line's own text (its first glyph's bottom) starts a new line even when the line's scripts widened its band | text F1 +0.006, whole blocks +0.013, inline found +0.009, glyph-right +0.007, typeset precision +0.006 | +0.003, +0.005, +0.004, +0.006, +0.005 | +0.005, +0.011, +0.009, +0.007, +0.008 | **on** |
| `ligatures` | ﬁ ﬂ ﬀ ﬃ ﬄ written as letters in text | text F1 +0.001 | ±0 | +0.002, headings 0.920/0.781 → 0.930/0.790 | **on** |
| `compounds` | A hyphen at a line's end stays when the paper prints the same pair hyphenated within a line ("three-dimensional"); otherwise TeX's hyphenation goes as before | +0.001 (words split or joined 366 → 169) | +0.002 | +0.001 | **on** |
| `reuseRecognitions` | A formula whose glyphs repeat an earlier one's exactly (characters, fonts, sizes, places in its box) takes its reading instead of being recognised again | accuracy unchanged; recogniser crops −20 % | −18 % | −27 % | **on** (speed) |
| Batches by glyph count (host, protocol) | Crop requests carry the formula's glyph count; the background recogniser batches like counts together instead of like crop widths | simulated on the recorded reading lengths: 47,350 → 42,156 decoder batch steps (−11 %; the bound with true lengths: 34,432) | | | in the host |
| `displayLines` | A line of a paragraph (or a line the layout boxed not at all) that is nearly all math, indented, with an equation number at the column's right edge becomes a display; its rows join it | displays found 0.777 → 0.787, glyph-right 0.898 → 0.894, typeset precision 0.958 → 0.952 | 0.828 → 0.837, 0.902 → 0.895, 0.958 → 0.954 | 0.801 → 0.811, 0.621 → 0.615, 0.778 → 0.773 | off (loses typeset precision on all three) |
| `dedupeGlyphs` (tried) | Glyphs printed twice at the same place read once | no change | slight loss | | removed |

Numbers for `verifyGlyphs`, `lineReturns` and `displayLines` are real runs with ablation replays; the others are replays of
the baseline's records (they change no crop). For context, lowering the gate instead: display gate 0.85 typesets 68 % of
test displays at 0.958 precision, 0.5 typesets 96 % at 0.926; verification typesets 81 % at 0.958.

**After, all of it as the app now runs it** (`verifyGlyphs`, `lineReturns`, `ligatures`, `compounds`, `reuseRecognitions`
added to the 17 earlier rules; before → after):

| Measure | arXiv test | arXiv dev | Venue |
|---|---|---|---|
| text F1 | 0.889 → 0.898 | 0.895 → 0.899 | 0.844 → 0.853 |
| shared-content F1 | 0.896 → 0.902 | 0.902 → 0.905 | 0.899 → 0.907 |
| whole blocks | 0.809 → 0.824 | 0.814 → 0.819 | 0.786 → 0.802 |
| headings recall / precision | 0.917 / 0.765 → 0.919 / 0.766 | 0.801 / 0.711 → 0.802 / 0.711 | 0.920 / 0.781 → 0.930 / 0.790 |
| inline found / glyph-right | 0.832 / 0.919 → 0.845 / 0.929 | 0.864 / 0.916 → 0.868 / 0.918 | 0.798 / 0.831 → 0.806 / 0.836 |
| inline typeset share / precision | 0.924 / 0.929 → 0.972 / 0.935 | 0.910 / 0.937 → 0.962 / 0.929 | 0.796 / 0.884 → 0.880 / 0.879 |
| display found / glyph-right | 0.777 / 0.893 → 0.777 / 0.898 | 0.826 / 0.902 → 0.828 / 0.902 | 0.799 / 0.622 → 0.801 / 0.621 |
| display typeset share / precision | 0.428 / 0.976 → 0.812 / 0.958 | 0.425 / 0.972 → 0.784 / 0.958 | 0.245 / 0.816 → 0.608 / 0.778 |
| recogniser crops (real runs) | 8,307 → 6,646 | 9,934 → 8,148 | 8,862 → 6,517 |

The weakness report after (`.artifacts/device-route-weaknesses/after/`, `--baseline base`): total impact 19.8 → 17.0 per
10 pages; displays as images 1.81 → 0.78, inline images 1.02 → 0.40, words 0.98 → 0.51, text missing 1.74 → 1.16, text
added 1.37 → 0.99; inline boundaries rise 2.41 → 2.75 because partial spans that were images are now typeset and counted
as what they are (the tagger's spans are now the largest single weakness). By stage: recogniser 3.7 → 2.4, converter
6.3 → 5.2, text layer 1.4 → 0.9; tagger 5.0 → 5.2, layout 3.4 → 3.3.

**Speed.** Interleaved A/B per paper (12 test papers, 223 pages; A = the shipped host and converter, B = this round's with
`reuseRecognitions`; frozen binaries, load 120–300 throughout): 599 s against 623 s, per paper ×0.68 to ×1.65, median ×1.05;
crops 2,063 → 1,910; recogniser busy 938 → 976 s. The work is smaller (fewer crops, simulated fewer decoder steps) but the
time on this machine moved with other agents' load, not with the change: no speed gain is claimed. Not interleaved, the
full corpora's recogniser busy seconds fell 14 %, 3 % and 11 %.

## 5. What to do next (from the report)

1. **The tagger's spans** are now the largest weakness (cut short or overgrown 2.75, missed 2.40 per 10 pages). The
   examples show three kinds the converter cannot fix safely by rule (`extendSpans` lost on 2026-10-21): formulas broken
   across a line end, operators and operator names at a span's edge, and table cells. A tagger retrained with cross-line
   context and table-cell lines (on the desktop, `/home/ben/science-reader-device-pdf`) is the next model step; the
   explorer's `inline.boundary` and `inline.missed` examples are its error set.
2. **Display boxes** (displays missed 1.00): the layout boxes numbered displays as paragraph lines. `displayLines` recovers
   them but its new displays are read less accurately (the crops are the glyphs', not trained on); layout v6 or a layout
   fine-tune on numbered displays, then turning `displayLines` on, measured as here.
3. **Recogniser time**: cap a reading's length by its crop's width (a reading of more than 0.8 tokens per pixel of width
   is always a runaway on the test corpus, 10 of 8,307 crops, each holding a batch of eight to 512 steps), and measure on a
   quiet machine or a phone; 73 % of the wall time is the wait for the recogniser after the last page.
4. **Tables** (cells wrong 0.52, flattened 0.37): a structure model, as planned before.

## 6. Checks

- `npm test` passes (backend with the new rule tests in `tests/backend/device-pdf-rules.test.ts`: glyph verification,
  line returns, display lines, ligatures and compounds, reused recognitions; both compiler freshness checks).
- `swift test` (ScienceReaderCore): 437 tests and 38 XCTest pass.
- Not run: any iPhone (paused), the Simulator journey (the host's protocol change is an optional field), timing on a quiet
  machine.

## Files

- `scripts/device-route-weaknesses.mjs`, `scripts/device-route-graphics.py`; `DevicePDFRouteTool --render-crops`;
  per-page timings in `DevicePDFPipeline.swift`/`DevicePDFRoute.swift`; records may be gzipped (`record.json.gz`).
- Runs: `.artifacts/device-route/accuracy/wk0-{test,dev,venue}` (before), `wk1-*` (after, `displayLines` on), `app-*`
  (the app's rules, replayed from `wk1`), `tA-test`/`tB-test` (timing A/B); reports `.artifacts/device-route-weaknesses/{base,after}`.
- Frozen tools: `~/gradstep-mac/tools/wk0`, `wk1`.

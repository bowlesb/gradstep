# The on-device PDF route on non-arXiv layouts (2026-10-23)

Owner, 2026-10-22: "the on device pdf extractor is also in need of work, if it works it will be a big unlock for non
arXiv papers." Until now the route was measured only on arXiv preprints ([review 2026-10-21](DEVICE_PDF_ROUTE_20261021.md)).
This review measures it on the PDFs the route exists for — publishers' and proceedings' own PDFs — fixes what that
showed, and analyses the display-formula recogniser. Design: [DEVICE_PDF_ROUTE](../architecture/DEVICE_PDF_ROUTE.md).
Local source; nothing here is released, uploaded or deployed.

## Summary

- **Measured on publishers' PDFs for the first time.** 31 open-access venue PDFs (ACL, CVPR, ICML/AISTATS, NeurIPS, JMLR,
  ICLR, SciPost/TACL/Quantum), each scored against the arXiv HTML of the same paper, with the paper's own arXiv PDF as a
  control. Before this round the venue PDFs read clearly worse than their arXiv versions (shared-content text F1 0.872
  against 0.898); the worst were a CVPR paper with no usable text layer (no text read at all), JMLR (two lines read as
  one, letters interleaved), SciPost (math fonts the tagger did not know) and two-column displays (equation numbers inside
  the recogniser's crops).
- **After ten converter rules, text recognition for unreadable pages and a longer recogniser cache**, the venue PDFs read
  as well as their arXiv versions did (shared-content F1 0.899; text F1 0.795 → 0.844; inline formulas found 0.72 → 0.80;
  displays glyph-right 0.53 → 0.62), and the arXiv corpora improved as much: text F1 0.857 → 0.890 (test) and
  0.876 → 0.896 (dev); whole paragraphs 0.72 → 0.81; inline formulas found 0.78 → 0.84; displays glyph-right
  0.80 → 0.89 (test) and 0.78 → 0.90 (dev), with typeset precision 0.92 → 0.97. Scanned papers, which read as no text at
  all before, now read as prose with display images (text F1 0.82).
- **Display formulas**: six in ten of their field errors were crops and boxes, not recognition (numbers inside, rows cut
  apart) — which is why the desktop's v5 and v6 fine-tunes could not show in the app. The converter fixes most crops; the
  same weights exported with a 512-token cache read the cut-off formulas whole (+0.010 to +0.013 glyph-right, nothing
  else changes; decoder step +13 %) and are now the app's recogniser. The display gate stays at 0.95. No fine-tune was run;
  the next steps are the layout's display boxes, then training crops cut the way the app cuts them (section 4).
- **Still short of "good enough"**: displays (62 % right on venue PDFs, a quarter typeset), inline math in tables,
  tables themselves, and no phone measurement.

## How it was measured

**Machine and tool.** This Mac (M1 Max) through `DevicePDFRouteTool` (the app's Swift host, Core ML models and the
converter in JavaScriptCore), as in the previous review. The Mac was heavily shared (load averages of 60 to 250 from
other agents' builds and Simulators), so seconds are not compared here; accuracy is.

**The venue corpus (new).** 31 papers whose official venue PDF is open access and which also have arXiv HTML
(`~/gradstep-mac/device-route-venue`, manifest with sources and licences; local research copies, never redistributed):

| Template | Papers | Source | Licence recorded |
|---|---|---|---|
| ACL Anthology (two-column) | 5 | ACL 2024 long, EMNLP 2024 | CC BY 4.0 |
| CVF open access (two-column) | 5 | CVPR 2024, CVPR 2025 | CVF open access; IEEE/authors |
| PMLR | 5 | ICML 2024 (2), AISTATS 2024 (3) | © the authors and PMLR |
| NeurIPS proceedings | 4 | NeurIPS 2024 | not stated on the page |
| JMLR | 4 | volumes 25, 26 | CC BY 4.0 |
| ICLR (proceedings.iclr.cc; OpenReview refused automated access) | 4 | ICLR 2025 | not stated |
| Other | 4 | SciPost Physics (2), TACL, Quantum | CC BY 4.0 |

Each paper's truth is the app's own arXiv HTML reading of the arXiv revision closest to the venue version (the latest
with HTML). Four papers cannot be scored because the app's arXiv HTML reader refuses their (older) HTML, so 27 are
scored. Each paper also keeps that revision's own arXiv PDF: the **control**, read by the same route, separates what the
venue's layout costs from what differs in content between the two versions.

Content differs more than expected, and it bounds every venue score: CVPR's arXiv versions carry their supplements
(11 venue pages against up to 44 on arXiv), NeurIPS 2024 venue PDFs end with the paper checklist, some JMLR and NeurIPS
revisions differ in wording. So besides text F1 this review reports **shared-content F1**: the same in-order word
measure over the blocks both readings have (a section only one side has is left out; what the reading did to the text
both have stays in).

**No-arXiv set (new).** Seven open-access PDFs with no arXiv version (arXiv title search): two ACL Anthology papers
(ACL 2024, SIGDIAL 2024), a JMLR and an AISTATS paper, a CVPR 2024 workshop paper, PLOS Computational Biology and eLife
(`~/gradstep-mac/device-route-noarxiv`), reviewed from screenshots of the tool's bundles in the browser.

**Scanned copies (new).** Four arXiv test papers rasterised to image-only PDFs (200 dpi greyscale), scored against
the same arXiv HTML: the case of a scan, which has no text layer at all.

**The arXiv corpora** are the previous review's: 32 test papers (30 scored) and 32 dev papers (26 scored). Rules were
judged on all three corpora; ablations are replays of the final run's recorded model outputs through the converter
with one rule off (`scripts/device-route-replay.mjs --also` merges the baseline's records, so a rule's absence finds the
recognitions and tagger lines it needs).

Three scorer changes, applied to every number below (baselines re-scored with them, so the previous review's figures
for the same runs differ slightly): reference-list entries are left out of the order measure (LaTeXML regenerates some
bibliographies in alphabetical order, e.g. 2610.25953v1, where the PDF prints citation order); words are compared after
Unicode NFC; and the truth's formulas are reduced to glyphs from their LaTeX through Temml, as the device's are, falling
back to LaTeXML's MathML when Temml refuses it or leaves an author's macro unexpanded (LaTeXML's MathML rewrites some
symbols: the ";" of an argument list `\rho(\theta,N^{o};N)` becomes ",", so a correct reading counted as wrong). The
last change raises display glyph-right for every run (the arXiv test baseline 0.769 → 0.801, the venue baseline
0.495 → 0.533); before/after comparisons below use one scorer throughout.

## 1. Before: the route as of 2026-10-21 on venue PDFs

The route with the seven rules on in the app (converter port revision 5), per template. "Control" is the same papers'
arXiv PDF; the difference between the two rows is what the venue's PDF costs.

| Measure | arXiv test | Venue control | Venue PDF | ACL | CVF | ICLR | JMLR | NeurIPS | Other | PMLR |
|---|---|---|---|---|---|---|---|---|---|---|
| papers scored | 30 | 27 | 27 | 5 | 4 | 4 | 3 | 3 | 3 | 5 |
| text F1 | 0.857 | 0.840 | 0.795 | 0.841 | 0.578 | 0.846 | 0.735 | 0.743 | 0.866 | 0.905 |
| shared-content F1 | 0.879 | 0.898 | 0.872 | 0.879 | 0.790 | 0.910 | 0.837 | 0.888 | 0.881 | 0.907 |
| (control, shared F1) | | | | 0.893 | 0.881 | 0.910 | 0.879 | 0.917 | 0.908 | 0.902 |
| blocks found / whole | 0.951 / 0.722 | 0.954 / 0.794 | 0.891 / 0.715 | 0.932 / 0.735 | 0.625 / 0.480 | 0.964 / 0.875 | 0.832 / 0.558 | 0.927 / 0.805 | 0.970 / 0.710 | 0.971 / 0.798 |
| headings recall / precision | 0.920 / 0.765 | 0.951 / 0.765 | 0.894 / 0.774 | 0.970 / 0.860 | 0.523 / 0.652 | 0.923 / 0.805 | 0.833 / 0.667 | 0.903 / 0.707 | 0.983 / 0.711 | 0.980 / 0.804 |
| inline found (control) | 0.777 | 0.774 | 0.716 | 0.619 (0.684) | 0.451 (0.757) | 0.628 (0.622) | 0.792 (0.804) | 0.770 (0.819) | 0.566 (0.864) | 0.780 (0.782) |
| inline typeset precision | 0.928 | 0.891 | 0.863 | 0.956 | 0.976 | 0.853 | 0.787 | 0.805 | 0.841 | 0.913 |
| display glyph-right (control) | 0.801 | 0.585 | 0.533 | 0.622 (0.644) | 0.531 (0.606) | 0.765 (0.731) | 0.396 (0.441) | 0.560 (0.640) | 0.607 (0.735) | 0.628 (0.640) |
| display typeset precision | 0.924 | 0.818 | 0.791 | 1.000 | 0.875 | 1.000 | 0.571 | 0.778 | 0.900 | 0.926 |
| tables word F1 | 0.568 | 0.484 | 0.447 | 0.412 | 0.426 | 0.720 | 0.160 | 0.402 | 0.179 | 0.643 |

(The control's CVF text F1, 0.646, is low partly because the word aligner gives up on one 44-page arXiv version against
its 11-page venue PDF; shared-content F1 is not affected.)

Reading the table:

- **ICLR and PMLR venue PDFs read as well as their arXiv versions** (the same template on both sides). ACL is close.
- **CVF is the worst template, and one paper explains most of it**: a CVPR 2025 PDF whose fonts have no Unicode mapping
  (its text layer is `(cid:N)` codes and wrongly named letters). The route read nothing (text F1 0.00); the arXiv version of
  the same paper reads at 0.99 of its words. The other CVF losses are the arXiv supplements the venue PDF does not have.
- **JMLR** lost 0.04 of shared text: in its venue PDFs two text lines were often read as one, letters interleaved
  ("tahtennXij(⋅)umrabnedroomf"): a lowered delimiter's box reaching into the next line joined the two lines (the
  arXiv version, typeset the same, reads at 0.95). The same fault, rarer, garbles some arXiv papers too (2610.26815v1).
- **"Other" (SciPost)**: inline formulas found 0.57 against 0.86 for the control: SciPost sets math in MathDesign fonts the
  inline tagger has never seen (its font vocabulary is arXiv's), so it reads them as prose.
- **NeurIPS**: shared text is close to the control; the gap in plain text F1 is the venue's paper checklist.
- **Formulas are weaker on this set even in the control** (display glyph-right 0.59 against 0.80 on fresh arXiv papers;
  JMLR's long derivations read at 0.40–0.44 on both sides). The venue PDF costs a further 0.05 on displays, mostly
  equation numbers inside the recogniser's crops (two-column layouts set them close to the formula).
- **The first-page notices** (ACL's proceedings footer, CVF's watermark, PMLR's and NeurIPS's footnotes) were read as
  paragraphs.

From the no-arXiv set's screenshots: PLOS's text came out with most word spaces missing ("Recentadvancesinsingle-cell…":
PLOS justifies with negative letter spacing, so its word gaps are under the route's fixed fifth of an em) and its
symbols misnamed (ð Þ for parentheses, ¼ for "=": PLOS's embedded Computer Modern names them wrongly); TeX accents came
apart in names ("Na¨ıve"); eLife, ACL, JMLR, AISTATS and the CVPR workshop paper read well.

## 2. What changed (converter port revisions 6–9, host)

Each converter rule is an input switch (`DevicePDFInput`, on in the app through `DeviceModelReading.rules`; the Swift
host now forwards any rule name, and `name=number` for options). Each was kept only when it did not lose on any of the
three corpora; the effect below is the final run with that one rule turned off and replayed (so it is the rule's own
contribution with everything else on). Display measures are glyph-right and typeset precision; "inline" is found.

| Change | What it does | arXiv test | arXiv dev | Venue |
|---|---|---|---|---|
| `equationNumbers` + `mergeDisplays` | A display's number ("(12)", "(A.3)", set apart or flush with the box's right edge) is left out of the recogniser's crop and shown as the equation's tag; display boxes that overlap (a group and a row of it) are one display | displays 0.801 → 0.879, typeset precision 0.932 → 0.971 | 0.770 → 0.892, 0.910 → 0.972 | 0.526 → 0.609, 0.789 → 0.814 |
| `lineBands` | A glyph joins a text line by its centre, and only a glyph mostly inside the line widens it: a script's or a lowered delimiter's box no longer merges two lines into one with interleaved letters | text F1 0.862 → 0.890; inline found 0.787 → 0.839; whole blocks 0.762 → 0.810 | 0.879 → 0.896; 0.843 → 0.867 | 0.818 → 0.844; 0.755 → 0.796; inline typeset precision 0.829 → 0.884 |
| `fontAliases` | A font the inline tagger's vocabulary lacks is read as the one it stands for (Latin Modern size variants, MathDesign, mathabx, MnSymbol, URW Symbol, PLOS's renamed Computer Modern; PLOS's misnamed ( ) =) | inline found 0.833 → 0.839 | text F1 0.895 → 0.896 | inline found 0.767 → 0.796, inline typeset precision 0.807 → 0.884, text F1 0.839 → 0.844 |
| `captionMath` | Figure and table captions keep their math as marked text | inline found 0.821 → 0.839; tables 0.578 → 0.590 | 0.839 → 0.867 | 0.786 → 0.796 |
| `wordGaps` | A justified line's spaces under a fifth of an em still split words (between letters of text fonts, from the line's own letter spacing), and a document set with negative tracking (PLOS) takes its word gap from its letters | text F1 0.885 → 0.890 | 0.893 → 0.896 | 0.838 → 0.844 |
| `bibliography` | A bibliography without a heading (REVTeX) is read as references once two numbered entries open a reference box; nested reference boxes of a numbered list merged; an entry broken by a column continued; it ends at the first region that is not an entry | whole blocks 0.778 → 0.810 | 0.779 → 0.814 | 0.784 → 0.787 |
| `displayPunctuation` | The full stop or comma just outside a display's box (often unowned) is added to its LaTeX | displays 0.874 → 0.879 | 0.890 → 0.892 | 0.598 → 0.609 |
| `accents` | TeX's text accents compose with their letter of the same font ("Na¨ıve" → "Naïve"); math accents stay | text F1 0.889 → 0.890, whole blocks +0.003 | 0.895 → 0.896 | 0.843 → 0.844 |
| `venueNotice` | The first page's proceedings line, copyright and open-access watermark (small type, top or bottom band, from the first line naming the venue) are dropped | ±0 | ±0 | text F1 0.843 → 0.844 |
| Text recognition (host) | A page whose text layer is empty (a scan) or unreadable (codes without Unicode mapping, letters that are no words) is read by Vision's on-device recogniser; its displays are cut from the layout's boxes | — | — | the broken CVPR 2025 paper: text F1 0.00 → 0.51, shared-content 0.55 → 0.88 (its arXiv version: 0.87) |

Small costs, reported rather than hidden: `lineBands` and `fontAliases` find many more formulas, of which a smaller
share is typeset (venue inline typeset share 0.820 → 0.795: the newly found SciPost formulas are often images);
`lineBands` lowers the display glyph-right *rate* slightly (test 0.880 → 0.879, dev 0.895 → 0.892, venue 0.616 → 0.609)
because it finds more displays (venue 0.774 → 0.799 of the truth's), harder ones among them — one JMLR paper gains 18
displays of which 4 are right; the ablation of `accents` shows −0.002 on test displays, which is the replay lacking
recognitions for the few crops the accent changed (a real run recognises them).

**Tried and not kept.** The display gate at 0.9 or 0.85 (owner's question from the last review). With the crop fixes the
recogniser is more often confident: 0.9 typesets 58 % of displays instead of 43 % on both arXiv corpora, but typeset
precision falls on all three corpora (test 0.971 → 0.959, dev 0.972 → 0.967, venue 0.814 → 0.759); 0.85 typesets 68 %
at 0.954 / 0.965 / 0.741. The gate stays at 0.95. **A LaTeX normaliser for refused recognitions** is not needed any
more: with `tidy` (2026-10-21), of 2,634 recognitions on six papers only 22 fail Temml, and those are truncated or
unbalanced output (0 of 111 confident displays).

## 3. After: all rules on

Final converter (port revision 9) and host, real runs on all three corpora (the numbers are the final runs' records
replayed through the final converter, which differs from the run only in the `bibliography` and `accents` details
settled after it).

| Measure | arXiv test before → after | arXiv dev before → after | Venue before → after | Venue control (before) |
|---|---|---|---|---|
| text F1 | 0.857 → 0.890 | 0.876 → 0.896 | 0.795 → 0.844 | 0.840 |
| shared-content F1 | 0.879 → 0.896 | 0.888 → 0.902 | 0.872 → 0.899 | 0.898 |
| words present (bag recall) | 0.919 → 0.962 | 0.942 → 0.965 | 0.870 → 0.926 | 0.934 |
| blocks found / whole | 0.951 / 0.722 → 0.984 / 0.810 | 0.969 / 0.746 → 0.983 / 0.814 | 0.891 / 0.715 → 0.945 / 0.787 | 0.954 / 0.794 |
| order (pairs) | 0.977 → 0.982 | 0.972 → 0.977 | 0.963 → 0.963 | 0.970 |
| headings recall / precision | 0.920 / 0.765 → 0.923 / 0.767 | 0.799 / 0.705 → 0.801 / 0.706 | 0.894 / 0.774 → 0.918 / 0.780 | 0.951 / 0.765 |
| inline found / typeset precision | 0.777 / 0.928 → 0.839 / 0.934 | 0.814 / 0.935 → 0.867 / 0.938 | 0.716 / 0.863 → 0.796 / 0.884 | 0.774 / 0.891 |
| display glyph-right | 0.801 → 0.879 | 0.775 → 0.892 | 0.533 → 0.609 | 0.585 |
| with the 512-token recogniser (section 4) | → 0.892 | → 0.902 | → 0.622 | |
| display typeset share / precision | 0.412 / 0.924 → 0.428 / 0.971 | 0.410 / 0.916 → 0.425 / 0.972 | 0.228 / 0.791 → 0.242 / 0.814 | 0.261 / 0.818 |
| tables word F1 | 0.568 → 0.590 | 0.521 → 0.529 | 0.447 → 0.458 | 0.484 |

**Per template (venue PDF, after; before in brackets; the control is the arXiv PDF of the same papers before):**

| Template | text F1 | shared F1 (control) | inline found | display glyph-right (control) | whole blocks |
|---|---|---|---|---|---|
| ACL | 0.855 (0.841) | 0.893 (0.893) | 0.649 (0.619) | 0.830 (0.644) | 0.775 (0.735) |
| CVF | 0.718 (0.578) | 0.884 (0.881) | 0.456 (0.451) | 0.893 (0.606) | 0.639 (0.480) |
| ICLR | 0.864 (0.846) | 0.918 (0.910) | 0.657 (0.628) | 0.830 (0.731) | 0.910 (0.875) |
| JMLR | 0.865 (0.735) | 0.877 (0.879) | 0.931 (0.792) | 0.416 (0.441) | 0.730 (0.558) |
| NeurIPS | 0.752 (0.743) | 0.894 (0.917) | 0.820 (0.770) | 0.640 (0.640) | 0.823 (0.805) |
| Other (SciPost, TACL, Quantum) | 0.895 (0.866) | 0.900 (0.908) | 0.785 (0.566) | 0.679 (0.735) | 0.768 (0.710) |
| PMLR | 0.927 (0.905) | 0.919 (0.902) | 0.813 (0.780) | 0.758 (0.640) | 0.841 (0.798) |

The venue PDFs now read as well as the arXiv PDFs of the same papers did before (shared-content F1 0.899 against the
control's 0.898), and better on PMLR, ICLR and ACL. CVF's text F1 stays low because the arXiv truth carries supplements
the venue PDF does not have (shared-content F1 0.88); NeurIPS's because of the checklist. JMLR's displays remain the
weakest (0.42; the control 0.44): long multi-line derivations (section 4).

**Scans** (four arXiv papers as image-only PDFs): before, the route read no text at all (no text layer: 2 words of a
7-page paper, its displays as images; checked with `--no-ocr`); now text F1 0.823
(the same papers' real text layers: 0.799 — recognition reads inline math as words, so more words match and fewer
formulas exist), blocks found 0.98, displays glyph-right 0.53 (0.70 with the text layer: the crops are the layout's boxes,
not the glyphs'), and no inline formulas (prose only). Recognition took 3–5 busy seconds a page on this Mac under heavy
load (two pages at a time); the broken CVPR paper had 7 of its 11 pages recognised.


## 4. The display-formula recogniser: why v5 and v6 were negatives, and what to do next

**The bench and the field measure different things.** The desktop's fine-tunes were judged on bench-v3: 790 gold display
crops, cut by the data factory around the equation's own glyphs (colour-tagged at compile time, equation numbers
excluded). On it texteller-ft-v4 reads 0.914 of displays exactly (normalised); v5 (36 % more data) scored 0.906 and v6
(long displays sampled three times as often) 0.899. In the app the same model was right on 0.80 of paired displays.
Classifying every wrong display on the arXiv test corpus (glyphs of the device's formula against the truth's):

| Kind of display miss | Before (264 of 1,327) | After the converter changes (162 of 1,339) | And the 512-token cache (144) |
|---|---|---|---|
| equation number inside the crop (alone, or with other errors) | 67 (25 %) | 6 (4 %) | 8 |
| rows split (part of the truth: the layout boxed a group's rows apart) or crop cut | 66 (25 %) | 34 (21 %) | 31 |
| more than the truth (two displays read as one) | 14 (5 %) | 25 (15 %) | 25 |
| trailing punctuation outside the box | 11 (4 %) | 3 (2 %) | 3 |
| no glyphs: LaTeX that does not render (mostly cut off at the 256-token cache) | 31 (12 %) | 31 (19 %) | 18 |
| recognition proper: ≤ 5 % of glyphs wrong / 5–20 % / more | 17 / 25 / 33 (28 %) | 21 / 15 / 27 (39 %) | 22 / 15 / 22 |

So in October **six in ten of the field's display errors were crops and boxes, not recognition** (numbers inside them,
a group's rows cut apart, punctuation left out), one in eight was the decoder's 256-token cache, and fewer than three in
ten were the recogniser misreading a well-cut crop. More of the same data (v5) or more long crops (v6) could only move
that last part, which on gold crops was already small: neither change could show in the app. The converter now cuts
crops much as the factory did (displays 0.801 → 0.879 test, 0.775 → 0.892 dev); the 512-token cache removes 13 of the 31
unrenderable outputs. What remains is about evenly split between the layout's display boxes (rows split, displays
merged: 56 of 144) and recognition (59 of 144, 4.4 % of all displays), with 18 outputs that still do not render.

**Truncation: the same weights with a 512-token cache** (no training). `export_texteller.py --max-len 512` on the desktop
(CPU, `/home/ben/science-reader-device-pdf/exports/texteller-ft-v4-mf8-int8-l512`; 20/20 on the export's samples).
Re-reading every paper that had a cut-off recognition: 4,489 of the 4,534 crops both runs read came out identical, 44 of
the 45 that changed were the cut-off ones now read whole (the other is the run-to-run residue). With all rules on:

| | arXiv test | arXiv dev | Venue |
|---|---|---|---|
| display glyph-right, 256 → 512 | 0.879 → 0.892 | 0.892 → 0.902 | 0.609 → 0.622 |
| display typeset share | 0.428 → 0.428 | 0.425 → 0.425 | 0.242 → 0.245 |
| display typeset precision | 0.971 → 0.976 | 0.972 → 0.972 | 0.814 → 0.816 |
| everything else | equal (inline within ±0.002: the tagger's run-to-run residue) | equal | equal |

Cost: the decoder step reads a cache twice as long, 14.1 → 16.0 ms per batch of eight on this Mac's GPU (+13 %; the
encoder, most of a crop's time, is unchanged), and a batch's state grows from about 0.41 to 0.51 GB (the rule of two
batches in flight only on devices with 7.5 GB or more still holds). It wins on every display measure and loses nothing
else, so **it is now the app's recogniser** (`scripts/device-models.mjs`, lock updated: `texteller-ft-v4-mf8-int8-l512`).

**The plan for the recogniser and the display boxes (not started; no GPU time was spent on training in this round):**

1. *Display boxes first* (56 of the 144 remaining misses). The layout detector (fcos v5) boxes a multi-row display as
   several, or two displays as one. Two cheap steps before any training: a converter rule that joins vertically adjacent
   display boxes whose rows align (shared left edge or `=` column, gap under one line), measured as the rules here were;
   then layout v6 (renderer-jittered, already exported, never measured end to end) on the three corpora.
2. *Field-shaped recogniser crops.* Run the layout model and the converter's crop rules over factory-v4's page renders,
   match each predicted display to its gold equation (IoU of the glyph boxes ≥ 0.5) and keep the gold LaTeX: crops cut
   exactly as the app cuts them (about 150 k displays), with the residual failure shapes as augmentation (a number set
   0.5–3 em to the right, a cut neighbouring row at an edge, closing punctuation outside), target unchanged.
3. *Train v7 from v4* on half field-shaped, half gold crops, display weight 3, max 512 target tokens, about 10 k steps at
   lr 1e-5 (the 3090: about 2½ hours; work in `/home/ben/science-reader-device-pdf`, reading `/home/ben/mathpix` only).
4. *Judge it where it matters:* bench-v3 must not fall (display ≥ 0.909, inline ≥ 0.964) and on this harness, final rules,
   all three corpora, display glyph-right and typeset precision must both rise with inline unchanged. Only then export it
   (batch 8, multifunction, int8, 512 cache) and update the lock.
5. *Re-fit the gate on field crops* once the model changes (today 0.9 loses precision on every corpus).
6. *If recognition still dominates:* row-wise decoding (each row of a multi-row display read alone, rows from the text
   layer's lines, joined as aligned rows) shortens sequences, which is where accuracy falls (the desktop: 0.73 for
   references over 240 characters).

## 5. Papers without an arXiv version (screenshots)

Seven open-access PDFs, final rules, read by the tool and shown with the reader's own stylesheet in a browser at
phone width:

- **eLife** (single column, journal front matter): reads cleanly; the assessment box, correspondence and funding lines
  come out as short paragraphs before the abstract.
- **PLOS Computational Biology**: before, words ran together throughout and parentheses and equals signs came out as
  ð Þ ¼; now the text reads normally and the symbols are right. Remaining: a few spaces missing after full stops and
  commas inside sentences ("level,such"), "Abstract" repeated after the author summary, and display formulas shown as
  images (MathType-style fonts the recogniser reads less confidently).
- **ACL 2024 and SIGDIAL 2024**: clean two-column order, figures in place, the proceedings footer gone.
- **JMLR**: correct, with most displays typeset; one derivation where the layout found no display box reads as a
  paragraph with inline formulas.
- **AISTATS (PMLR)**: tables read as cells; "Naïve" now composed.
- **CVPR 2024 workshop**: aligned derivations typeset correctly; a stray fragment of a neighbouring word ("atrix") under
  one display.


## 6. What still blocks "good enough for non-arXiv papers"

1. **Display formulas.** 62 % of venue displays (89–90 % on arXiv) are glyph-right, and only a quarter (43 % on arXiv)
   are typeset; the rest are shown as page images, which read correctly but cannot be selected or explained as math. The
   plan is in section 4; the next steps are the layout's display boxes and training crops cut the way the app cuts them.
2. **Inline formulas in tables and ACL/CVF-style papers** (inline found 0.46–0.66 on ACL, CVF, ICLR): most misses are
   symbols in table cells (±, ↑, ✓) the tagger leaves as text, and tables themselves (word F1 0.46 venue, 0.59 arXiv:
   cells from gaps lose spans and multi-line cells).
3. **Venue content the reader shows as text**: NeurIPS checklists, eLife's assessment boxes, PLOS's author summary are
   read, correctly, as part of the paper; nothing marks them as back matter.
4. **Unusual PDFs.** One of 31 venue papers had no usable text layer; it now reads at 0.88 of shared text through
   text recognition, but without inline math. Scanned papers read as prose with display images. Neither was measured on
   a phone (Vision's recognition is on-device on iOS too; speed on a phone is unmeasured).
5. **Speed** (unchanged by this round, not re-measured on a quiet machine): about 1.5–3 s a page on this Mac; the phone
   estimate from the previous review stands untested (physical-phone work is paused).


## 7. Checks

- `npm test` passes (backend, operations, browser units, both compiler freshness checks); the converter's rule tests
  cover every new rule (`tests/backend/device-pdf-rules.test.ts`, 16 tests).
- `swift test --filter DevicePDF`: 18 tests pass (new: `DevicePDFOCRTests` — unreadable layers, recognised words as
  glyphs in points; `testConverterRulesAreNamesOrNumericOptions`).
- The Mac Catalyst app builds (Debug, fixture configuration, no signing).
- Simulator `DeviceModelJourneyTests` (iPhone 17 Pro, quiet machine at load 5) passes with the new host and converter.
- Fixture conformance (`scripts/device-route-eval.mjs`) is unchanged by design: every new rule is off in the tool unless
  passed with `--rules`, and the port kit's fixtures are read with the rules off.
- Not run: any iPhone (paused), the recogniser in the iOS Simulator (it does not load there), timing on a quiet machine
  (the Mac was shared throughout; no speed claim is made here beyond the recogniser's step benchmark, taken at load 5).

## Files

- Corpora (this Mac, not committed): `~/gradstep-mac/device-route-venue` (31 papers, `manifest.json`),
  `~/gradstep-mac/device-route-noarxiv` (7), `~/gradstep-mac/device-route-scan` (4 scanned copies);
  the arXiv corpora as before.
- Runs: `.artifacts/device-route/accuracy/` in the worktree: `base-*` (before), `ctrl-venue` (control), `final-*` (after,
  real runs with records), `FT-*`, `FD-*`, `FV-*` (replays: `all3` is the final converter, `no<rule>` the ablations,
  `g90`/`g85` the gate), `l512f-*` and `LC-*` (512-token recogniser), `final-scan`.
- The 512-token export: `/home/ben/science-reader-device-pdf/exports/texteller-ft-v4-mf8-int8-l512` (copied to
  `~/gradstep-mac/texteller-ft-v4-mf8-int8-l512`, compiled as `~/gradstep-mac/variants/mf8-l512`).


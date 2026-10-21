# The on-device PDF route: where the time and the errors go, and what changed (2026-10-21)

Owner, 2026-10-21: "Ok, well maybe we can just continue to develop the on device version then? The current version feels
too slow, and not accurate enough, but maybe we can improve it?" (decision recorded in
[DECISIONS](../DECISIONS.md#pdfs-without-arxiv-html-keep-developing-the-on-device-model-no-mathpix-owner-2026-10-21)).
This review measures the route as it shipped (converter port revision 4, the port kit's models), changes it, and
measures again on the same papers. Design: [DEVICE_PDF_ROUTE](../architecture/DEVICE_PDF_ROUTE.md).

## How it was measured

**Machine.** This Mac (Apple M1 Max, 32-core GPU, macOS 26.3.1) through `DevicePDFRouteTool`, which runs the app's own
code: the Swift text layer and Core ML models, the converter in JavaScriptCore. The Mac was shared with other agents'
work (an iOS Simulator running the app, Codex, Photos analysis): GPU utilisation from others sat between 50 and 80 %
during the runs. Absolute seconds are therefore noisy; every before/after comparison was run **interleaved per paper**
(before then after, after then before on the next paper) so the load falls on both alike. No iPhone was used (physical
iPhone work is paused); the iPhone figures below are estimates and say so.

**Papers.** A fresh corpus of 32 arXiv papers submitted 2026-10-20/21 (after every model in the route was trained, so
none can be in their training data), four from each of cs.LG, cs.CL, cs.CV, stat.ML, math.OC, quant-ph, hep-th and
cond-mat.stat-mech (17 ML/CS/statistics, 15 physics/maths; 7 to 76 pages, 925 pages in all), each with the exact
revision's PDF and arXiv HTML, fetched on this Mac at the app's pace and kept in `~/gradstep-mac/device-route-corpus`. A
second set of 32 newer papers (`~/gradstep-mac/device-route-corpus-dev`) was fetched for tuning so rules are not chosen
on the papers they are scored on. The desktop's eight fixture papers were also re-run against the port kit's Python
reference (`scripts/device-route-eval.mjs`).

**Ground truth.** The app's own arXiv HTML reader (`convertArxivHTML`) on the same revision: the reading an arXiv paper
gets today. `scripts/device-route-accuracy.mjs` reads both bundles' pages as blocks of words and formulas and scores:

| Measure | What it is |
|---|---|
| text F1 | words (letters only) aligned in order (longest common subsequence) between the two pages; recall and precision against each side |
| bag recall | the same words in any order: the gap to text F1 is reading order and duplication |
| blocks found, whole | each HTML block (6+ words) found in one device block (half its words in order); "whole" when the device block is the same block (≥ 0.8 of both) |
| order | pairs of found blocks in the same order on both sides |
| headings | HTML h1–h4 titles (run-in `\paragraph` titles that open a device paragraph left out) found among the device's headings; precision counts a heading made twice |
| formulas | each HTML formula paired with the device formula of the same placement nearest in glyphs, between the words matched around it; then **glyph match**: both render to the same MathML characters (NFKC, spacing ignored) — macro-proof where LaTeX strings are not. Recall = paired / HTML formulas; typeset share = shown as MathML / all device formulas; typeset precision = typeset and glyph-equal / typeset paired (the errors a reader cannot see). Numbers set in math (`$48$`) count as text on both sides |
| tables, figures | counts, and the words inside tables |

Two things the HTML has that the PDF does not print are left out of the truth: arXiv's "Cited by"/"External links"
back-references in each bibliography entry, and the HTML reader's h5/h6 theorem and proof labels.

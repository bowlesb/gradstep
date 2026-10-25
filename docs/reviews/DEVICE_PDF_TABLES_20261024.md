# The on-device PDF route's tables: causes, converter rules and a structure model (2026-10-24)

Follow-up to the [weakness review](DEVICE_PDF_WEAKNESSES_20261024.md) (tables: cells wrong 0.52, flattened 0.37 per 10
pages; section 5 item 4 "a structure model, as planned before"). Design: [DEVICE_PDF_ROUTE](../architecture/DEVICE_PDF_ROUTE.md).
Local source and evaluation only; nothing released, uploaded or deployed; no model trained.

## Summary

- **Causes.** Most of what the explorer called table failures were not cell structure. Of 91 "flattened" tables, 58 are
  arXiv HTML conventions (algorithms, prompt boxes and code that LaTeXML writes as tables, and tables it has only as a
  picture); 34 are real tables the layout boxed as something else or not at all (16 with no box). Of 211 "cells wrong",
  19 are the same conventions; of the rest, the largest single cause was the **caption's place** (the device always put it
  first; the PDF and the HTML put it under the table for a third of tables), then the box's contents (words outside the box,
  neighbouring text inside it). The explorer's word-order measure hid the grid itself: measured cell by cell, the
  reference converter merged columns under every spanning header (cell F1 0.69 / 0.69 / 0.65 on the arXiv test, arXiv dev
  and venue corpora; 0.74–0.78 on 5,285 labelled tables).
- **Ships (converter port revision 13, three rules on in the app):** `tableColumns` (columns from the body's grid; a
  spanning header spans them), `cellLines` (a wrapped cell read line by line, not interleaved), `tableCaptionBelow` (a
  caption printed under its table follows it). Real runs against their own ablations, test / dev / venue: cell F1
  0.691 → 0.747 / 0.696 → 0.783 / 0.651 → 0.750; whole rows 0.452 → 0.499 / 0.587 → 0.652 / 0.376 → 0.488; table word F1
  0.682 → 0.722 / 0.660 → 0.713 / 0.564 → 0.635; whole blocks +0.005 / +0.006 / +0.014; inline formulas found +0.020 /
  +0.007 / +0.010; text F1 ±0 / ±0 / +0.002. On the factory's labelled tables: cell F1 0.744 → 0.917 (dev split),
  0.784 → 0.931 (test split); adjacency F1 0.792 → 0.930, 0.832 → 0.947. Table impact 0.73 → 0.54 per 10 pages.
- **Built, off:** `narrowCellGaps` (cells apart at 0.45 glyph heights instead of 0.6): +0.013 / +0.006 cell F1 on the
  labelled tables and +0.050 on the arXiv test corpus, but a tie on dev and −0.003 cell F1 (−0.005 rows) on venue PDFs.
- **Tried and dropped:** a rule joining wrapped text lines to the row above (lost on all three corpora), the PDF's ruling
  lines (booktabs rules as row separators: +0.001 to +0.003 at best, and only with a host change; vertical rules and
  "ruled between rows" grouping lost), a caption boxed inside the table (never fired).
- **No structure model now.** The rules leave 7–9 % of labelled cells wrong (half of them two cells of a row read as
  one, a third multi-line rows); on the papers, what remains is mostly the layout's boxes and the tagger's math in cells.
  A concrete proposal (section 5) is ready for when the GPU is free; the data (51,538 labelled table crops) and the
  benchmark already exist.

## 1. How it was measured

- **Runs.** The weakness explorer's earlier records were gone (their worktree was removed), so the 75 papers of the three
  corpora whose arXiv HTML has a table (27 arXiv test, 23 arXiv dev, 25 venue; 68 scored, 1,715 pages) were read again
  with `DevicePDFRouteTool --record` (the frozen `wk1` host, the app's rules) **without the recogniser**: tables, text and
  the tagger do not depend on it (the scorers count words; formulas are not words), and runs took a fifth of the time on
  a Mac shared with other agents. Inline and display scores below are therefore with every non-transcribed formula as
  its image; only their changes mean anything.
- **Same tagger outputs.** The baseline run (load 700–1,000) and the rule runs (load 5–30) read some tagger lines
  differently (the residual nondeterminism under load); every comparison is therefore between a run and replays of that
  run's own records (`--also` the other runs, so a rule's absence finds its tagger lines).
- **New measures** (`scripts/device-route-accuracy.mjs`): **cell F1** (each truth table paired with the device table
  sharing most cells; cells keyed by their letters and digits, formulas left out; recall over all truth tables) and **row
  F1** (whole rows); the earlier table word F1 is word order with captions, which rewards little of the grid.
- **Labelled tables** (`scripts/device-route-table-bench.py` → `.mjs`): the desktop factory's table index
  (`factory-v4/tables/index.jsonl`, LaTeXML grids aligned to arXiv PDFs; read-only) gives 2,685 dev-split and 2,600
  test-split tables with their cells' boxes. The bench reads each table's text-layer characters (pdfplumber, the route's
  text-layer reference) inside the table's own box, runs `tableCells` with the app's line rules, maps glyphs to label cells
  and scores exact cells and ICDAR-2013-style adjacency. It isolates the grid from the layout's boxes and the tagger; rules
  were tuned on dev and confirmed on test.
- **Where.** Recorded runs on this Mac (Core ML), at low priority; replays, scoring, the explorer and the bench on the
  desktop (`/home/ben/science-reader-device-pdf/tables-work`, Node 24 in that folder; nothing in `/home/ben/mathpix`
  written).

## 2. Causes, with counts (before; 68 papers, 1,715 pages)

| Explorer category | Incidents | Impact /10 pages | Split |
|---|---|---|---|
| Table flattened to text | 91 | 0.154 (0.424 before conventions were separated) | **58 conventions**: 47 algorithms, prompt boxes and code LaTeXML writes as tables (the layout rightly read them as listings or text), 11 tables the HTML has only as a picture. **34 real tables**: no table box 16, boxed as a caption 6, as a figure 5, a table box whose glyphs another region owned 3, listing 1, paragraph 1, display 1 |
| Table cells wrong (word F1 < 0.75) | 211 | 0.567 (0.649) | 19 conventions as above; the rest, by pairing each table and splitting its loss (`tcause`, pairs may repeat when several HTML tables meet one device table): **caption placed differently** 77, words outside the table's box 61, other text inside the box 37, caption read differently 12, columns or spans 8, multi-line cells split into rows 2 |
| Table missed | 1 | 0.006 | |
| Inline math missed in a table | 1,288 (700 in the full review with the recogniser) | 0.32 | tagger |

**The grid itself**, which the word-order measure hardly sees: cell F1 0.691 / 0.696 / 0.651 and row F1 0.452 / 0.587 /
0.376 on the papers; on the labelled tables cell F1 0.744 (dev) and 0.784 (test). Why labelled cells were wrong (dev, the
reference): two cells of one row in one cell 46,846 cells' worth (the reference's columns are the union of every line's
runs, so one spanning header or a wide caption-like line bridges two columns and every row under it merges), split across
rows 3,024, merged with the cell above or below 3,030, table not read 2,496, other 1,461.

## 3. Rules tried

Replays first (seconds per corpus), then real runs of the winners with ablation replays of their records.

| Rule | What it does | Test | Dev | Venue | Decision |
|---|---|---|---|---|---|
| `tableColumns` | Columns from the lines with the most common number of runs (at least two; ties to more), so spanning headers no longer bridge columns; a run starting under a spanning cell joins it; every line's runs again when the grid's lines give fewer than two columns | cell F1 +0.053, rows +0.040, word −0.002, inline found +0.017 | +0.082, +0.058, +0.007, +0.004 | +0.099, +0.111, +0.012, +0.008 | **on** |
| `cellLines` | A cell joined from several lines keeps them: each line is tagged and written on its own, joined by a space (the reference sorted the joined glyphs by x and interleaved the lines' words) | word +0.020, cell +0.003, rows +0.007 | +0.019, +0.006, +0.007 | +0.023, ±0, +0.001; text F1 +0.001 | **on** |
| `tableCaptionBelow` | A caption whose centre is below its table's follows the table (block text, emission and equation order) | word +0.021, blocks +0.003, inline found +0.016 | +0.032, +0.006, +0.002 | +0.041, +0.012, +0.002 | **on** |
| `narrowCellGaps` | Cells apart at 0.45 glyph heights, not 0.6 (tuned on the dev split: 0.4 split loosely set text cells on the test split, cell F1 0.931 → 0.833; 0.5 and up merge narrow columns) | cell F1 +0.050, rows +0.018 | ±0, ±0 | −0.003, −0.005 (4 more tables read as cells, word +0.004) | off (loses on venue) |
| `tableRows` (removed) | A line with fewer cells, no figures and spacing no wider than the table's tightest continues the row above | cell −0.001, word −0.007 | −0.006, −0.006 | −0.007, −0.005 | dropped |
| Ruling lines (removed; PDF rules from pdfplumber injected into the records, a host would have to supply them) | Horizontal rules spanning a third of the table block a row join; vertical rules split columns; a table ruled between most rows reads the lines between two rules as one row | all three: cell −0.062; rules blocking joins alone: +0.000, word +0.002 | +0.014; +0.000, +0.001 | −0.053; +0.001, +0.002 | dropped (vertical rules and row grouping lose; blocking joins is +0.001–0.003 and needs a Swift text-layer change) |
| `tableCaptions` (removed) | A "Table N:" line boxed inside the table becomes its caption | no change | no change | no change | dropped (the layout boxes captions apart) |
| Gap and width sweeps (bench only) | Cell gap 0.3–1.0; wide-run cut 0.3–0.6; the reference's join gap 0–1.0 or text-only joins | gap 0.45 best (above); width ±0.001; join variants −0.001 to −0.005 | | | `narrowCellGaps` only |

Effects are each rule's own contribution in real runs (the others on). All three shipped rules together, against the same
records with all three off: cell F1 0.691 → 0.747 / 0.696 → 0.783 / 0.651 → 0.750; rows 0.452 → 0.499 / 0.587 → 0.652 /
0.376 → 0.488; word 0.682 → 0.722 / 0.660 → 0.713 / 0.564 → 0.635; whole blocks 0.812 → 0.817 / 0.817 → 0.823 / 0.799 →
0.813; inline found 0.832 → 0.852 / 0.857 → 0.864 / 0.748 → 0.757; text F1 0.8916 → 0.8923 / 0.8960 → 0.8964 / 0.8407
→ 0.8424; tables read as cells 195 / 119 → 120 / 228 → 229. **The price:** shared-content F1 −0.0008 / −0.0005 / −0.0009
(cell lines and the caption's place reorder a few words the HTML orders otherwise), text out of place 0.731 → 0.774 per 10
pages, inline glyph-right among found formulas −0.003 / −0.002 / +0.004 (more table formulas found, without the
recogniser here). Weakness report (conventions separated): table impact 0.727 → 0.539 per 10 pages (cells 0.567 → 0.393,
flattened 0.154 → 0.140); inline math missed 3.44 → 3.12 (in tables 1,288 → 1,138); text missing 1.30 → 1.13; total
26.4 → 25.7 (no-recogniser runs: not comparable with the review's 17.0).

## 4. What ships

Converter port revision 13 (`tables.ts`, `convert.ts`, `emit.ts`; rules are input flags, the reference unchanged with them
off), on in the app via `DeviceModelEngine.rules` (`DeviceModelReading.swift`): `tableColumns`, `cellLines`,
`tableCaptionBelow`. `narrowCellGaps` is built and off. Evaluation: `scripts/device-route-accuracy.mjs` scores cell and row
F1; the weakness explorer files algorithms, prompt boxes and code that the HTML writes as tables, and tables it has only as
pictures, under "truth" (no impact); `scripts/device-route-table-bench.{py,mjs}` scores the grid on labelled tables. The
host is unchanged.

## 5. A table structure model — proposal (not now)

**Is it needed?** Not clearly. After the rules, the grid is right for 91–93 % of labelled cells (adjacency 0.93–0.95), and
on the papers the remaining table losses are mostly the layout's boxes (34 real tables flattened, words outside or inside
the box) and math in cells (the tagger). A structure model would address the rest of the grid: on the dev split, of the
labelled cells still wrong, about half are two cells of a row read as one (columns closer than 0.6 glyph heights, or
abutting right- and left-aligned columns), a third rows (a wrapped cell's lines read as rows, or two rows merged), the
rest spans and unread tables. Ceiling: cell F1 0.917 → about 0.97 on the labelled tables; on the papers less (about +0.03
to +0.05 cell F1), since the box and the HTML conventions do not change.

**Data.** `factory-v4/tables` on the desktop: 51,538 table crops at 150 dpi (46,253 train / 2,685 dev / 2,600 test, split
by paper family) with LaTeXML grids aligned to the PDF: row, column, row and column spans, header flags, cell text and
cell boxes. Rendered from arXiv PDFs with pypdfium2; jitter the renderer as layout v6 did (Core Graphics in the app).
PubTables-1M (CDLA-Permissive) only if the arXiv set proves too narrow.

**Model.** A split-and-merge structure model, not a sequence decoder: a small CNN (the layout model's backbone at half
width, or MobileNetV3-small; 2–4 M parameters) over a grey table crop of fixed height 384 and width up to 1,024, with two
1-D heads (per pixel row: "row separator"; per pixel column: "column separator", trained on separators derived from the
cell boxes) and a merge head over the resulting grid (spans). Cell text stays the text layer's, assigned to the predicted
grid as now; the converter keeps the geometric rules as the fallback when the model's grid places too few glyphs.
TATR (DETR, 29 M parameters, ~58 MB fp16) and SLANet-plus (Paddle, harder to convert) were the alternatives in the plan;
both are larger and decode objects or tags, which the text layer makes unnecessary.

**Core ML and pack.** Fully convolutional, fixed shapes (two or three width buckets), so it compiles for the Neural Engine
like the layout model; fp16 about 4–8 MB, int8 2–4 MB, a few per cent of the 365 MB model pack (the On-Demand Resources
pack grows by that). One prediction per table, about 10–20 ms on the Neural Engine.

**Plan.** (1) Train on the desktop's 3090 when the tagger retrain is done (a few hours); (2) score on the bench (`--model`
mode to add: grid from the model's separators) against the rules (0.917 / 0.931 cell F1); (3) export, add to the host as
an optional fourth model, then the three corpora as here. Ship only if it beats the rules on the bench's test split and on
the arXiv test and dev corpora without losing on venue.

**First, cheaper:** the layout's table boxes (34 real tables flattened; words outside the box) belong to the layout
fine-tune the layout agent is doing; table pages from the same factory set can join its training data.

## 6. Checks

- `npm test` passes; `swift test` (ScienceReaderCore): 451 tests and 66 XCTest (1 skipped) pass.
- New tests in `tests/backend/device-pdf-rules.test.ts`: columns under a spanning header; narrow gaps; a wrapped cell
  read line by line and a caption below its table, end to end.
- Not run: the recogniser (these runs had none; the rules do not touch formulas' readings), any iPhone, the Simulator.

## Files

- `supabase/functions/_shared/reader/device-pdf/{tables,convert,emit,types}.ts`; `apps/apple/ScienceReader/DeviceModelReading.swift`.
- `scripts/device-route-accuracy.mjs` (cell and row F1), `scripts/device-route-weaknesses.mjs` (HTML conventions as
  truth), `scripts/device-route-table-bench.py` and `.mjs` (labelled tables).
- Runs: `.artifacts/device-route/accuracy/tb0-*` (reference, recorded under heavy load), `tb1-*` (the three rules),
  `tb2-*` (with `narrowCellGaps`), replays `rp-*`; reports `.artifacts/device-route-weaknesses/tbl-{before,after}` on the
  desktop (`/home/ben/science-reader-device-pdf/tables-work/repo`).

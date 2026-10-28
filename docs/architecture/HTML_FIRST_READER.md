# arXiv HTML reader and device-only PDFs

Status: implemented; staging backend and browser deployed 2026-10-13. Native build 30 is VALID and IN_BETA_TESTING for iOS and Mac, including the v2 figure compatibility extension; see IMPLEMENTATION_STATUS.md for evidence.
This document supersedes the PDF/Mathpix acquisition direction in earlier designs. Existing deployment evidence
remains historical evidence for that configuration, not evidence that PDFs now stay on devices.

Testing policy: [fast/slow commands and corpus](../TESTING.md). Real-source downloads and multi-engine/Simulator
checks are opt-in slow evidence, with cached exact bytes and checksums. PDF corpus work runs only on the user's
device. Reviewed unavailable sources remain separate from successful HTML preparations; no resource limit or
source-completeness rule is relaxed just to make the corpus green.

## Product contract

- Every PDF is downloaded, opened, stored and processed on the user's device. This includes CC-licensed arXiv
  papers, publisher PDFs, chosen files, drag/drop, Share intake and retry/recovery paths. No server PDF download,
  upload, proxy, Storage copy or Mathpix submission is part of the new flow.
- Initially, the structured reader uses **only the official HTML version of the exact arXiv paper revision**.
  Adapting existing HTML is a deterministic conversion, with no PDF OCR or paid model required.
- The Library, Feed, Paper, Contents, figures, selection actions, passage return and paper/general-chat arrangement
  stay the same. Change the content supplier beneath those surfaces; do not replace the reader with an arXiv iframe.
- A future on-device model will prepare challenging PDFs. It is a later implementation and quality milestone,
  with no automatic or optional Mathpix fallback under this decision.
- The $100/month incremental budget, device-held account keys, rights review and paused physical-iPhone work remain
  unchanged. The owner clarified that the SSH transfer request is for the codebase, not a PDF; copying the project
  does not authorize using that machine as the application's PDF processor.

The owner specified the source and PDF boundary. The device-side HTML adapter and protocol details below are
engineering choices to realize that boundary while preserving the existing rights and interaction constraints.

## Acquisition and availability

Resolve bibliographic metadata on the existing metadata service and pin `(arxiv_id, revision)` before content work.
Follow the official abstract page's HTML link for that revision, verifying the final version after redirects.
Do not substitute a newer revision, a third-party HTML mirror, TeX source or an OCR service when HTML is absent.
arXiv reports that HTML coverage is incomplete and conversions may have errors, so absence and invalid content are
normal, distinct outcomes. [arXiv HTML documentation](https://info.arxiv.org/about/accessible_HTML.html)

The default content path is direct device retrieval of HTML and its required assets, followed by local conversion
and encrypted installation. Source licenses remain recorded; HTML does not create permission for server hosting
or redistribution. Any future server HTML cache needs the existing exact-version rights approval and a separate
implementation review. [arXiv API terms](https://info.arxiv.org/help/api/tou.html)

PDF acquisition is independent of HTML readiness. The device may retain the exact revision's original alongside
the bundle; a PDF failure must not discard a valid HTML reader, and a valid PDF must not be labelled a prepared
reader. A PDF can be absent without inventing a page count or blocking the HTML reader.

| Source outcome | Existing reader surface | Recovery |
|---|---|---|
| HTML and all required assets validate | Normal structured reader, including offline reopen | Reuse the installed immutable bundle |
| HTML is absent for that revision | Metadata plus “HTML reader unavailable for this version” | Existing source/PDF action downloads or opens only on this device |
| HTML/asset retrieval interrupted or throttled | Preparation state and a retryable explanation | Bounded retry, cancellation, respect Retry-After |
| HTML math, content or an asset cannot be represented safely | Preparation failure; retain the previous verified bundle if present | Open local PDF/source; never publish a silently incomplete reader |
| PDF file or non-arXiv source added | Local PDF viewing and normal metadata membership | Structured preparation awaits the future local PDF engine |

Native URLSession and browser fetch are separate feasibility gates. Ordinary browser JavaScript cannot assume
that arXiv permits cross-origin response reads. Verify CORS on HTML and every asset type before promising direct
web preparation. Where unavailable, keep the source/PDF action and use a separately verified approved-device import
when available; do not deploy a general content proxy or claim that opening a new tab imports the file. Manual local
file intake remains local and does not justify sending PDFs to the existing upload endpoint. A broader browser
intake interaction, such as a required extension, needs a concrete owner proposal.

**Who talks to arXiv (restated 2026-10-16; ARXIV_DEVICE_ONLY.md §6.0.3):** only the reader's device, as that person's
own agent: the official HTML revision and, when the reader asks, the PDF (and, on the apps, the export API for a paper
without HTML and for the person's own searches). Our servers make no request to any arXiv host. The import pipeline
names a paper from DataCite, where arXiv registers each paper's DOI and metadata (CC0): the catalog record and the
latest version's licence; the first line of this section's "existing metadata service" is that DataCite stage. Devices
also send the metadata they read from the HTML for their own account's import. Until the deploy of steps 5–7 (not yet
done when written), the deployed pipeline still asked arXiv's Atom API and OAI-PMH, paced.

## HTML-to-bundle adapter

### Sweep failures: refusals degrade, author lines repaired (revision 29, 2026-10-28; not yet released)

The fresh-paper sweep of 2026-10-28 (30 papers, revision 28) had five failures, each identical under revision 27. A
refusal is a first-open failure, so each construct now degrades to the best faithful reading (JUDGMENT_LOG 56).

- **2610.37645v1, `arxiv_math_element`.** A display reads "\text{\color{gray}{Attention} \citep{vaswani2017attention}:}
  \quad O = softmax(QKᵀ+M)V": LaTeXML put the citation's HTML (`cite` holding an `a`) inside an `mtext`, and `mathNode`
  admits only MathML. HTML phrasing inside a formula (`cite`, `em`, `b`, `small`, `sub`, …) is now its words, as text of
  the token around it or a text token of its own (`arxiv/math.ts` `MATH_PHRASING`): "Attention (Vaswani et al.,
  2017): O = …". The citation is not a link there (MathML holds no links). 1 cached paper (6 citations in its formulas) has the construct.
- **Any formula the reader can't draw** (an element outside its MathML vocabulary, a picture in a formula that isn't a
  text badge, a `semantics` without one presentation, an empty presentation) shows its LaTeX in the shared
  `reader-math-fallback` form (the validators' text representation: the LaTeX for a display, `\(…\)` inline) instead of
  refusing the paper; an equation number follows it as text (`drawnMath`, `numbered`). An aligned group holding such a
  formula reads a line per formula. No cached paper takes this path today. The test that refused DocPilot-style SVG
  badges which aren't badges (`arxiv-html.test.ts`) now checks the fallback: nothing of the picture reaches the page and
  its label is not passed off as the formula. A TeX annotation disagreeing with the alttext still refuses
  (`arxiv_math_mismatch`): that is a damaged source, not a reading choice.
- **2610.37481v1, `arxiv_math_source`.** Table 4's boxed answer `\fbox{$15$}` is a block `math` with neither alttext nor
  a TeX annotation. Its LaTeX is now read back from its MathML (`latexFromMathML`: tokens, rows, scripts, fractions,
  roots, under/over; `\text{}` for `mtext`): "15". The MathML is drawn as before. 1 cached paper (1 formula).
- **2610.37633v1, `arxiv_unresolved_fragment`.** The bibliography's back-references ("Cited by: §1, …, Figure 5, Table
  1") point at `S6.F5.2` and `S6.T1.2`, ids the HTML never wrote (the citations inside those captions). A link to an id
  the page doesn't hold now goes to the nearest bound element around the target when the target exists, else to the
  element LaTeXML named it after (its id without its last parts: `S6.F5`, Figure 5); a link to nothing reads as its
  words (`arxiv/finish.ts` `linkTarget`, `unwrapLinks`). 1 cached paper (2 links).
- **2610.37651v1, author line "Zack Yu1*,4,11*411".** One creator holds every name with its own marks ("Zack Yu¹*, Nicholas
  Lee¹*, Minjae Lee⁴ …"). With the library's names (the app always passes them), the rule for a name run together with its
  affiliations (2610.10478) matched "Zack Yu" at the start, took every mark of the line as his and made the other names
  an affiliation line. It no longer fires when marks sit between words; the line splits into names as without the library.
  Siblings: the catalog headers of 19 more cached papers (11 with marks run together, as `</sup><sup>` in the names; 8
  with the other names read as an affiliation: ViT 2010.11929v2, WorldCast 2610.20731v2, 2610.09823v1, …), all now as the
  HTML-only reading or better. The sweep now fails on marks run together in the names (`authors_marks`).
- **2610.37619v1, "Daniela Rus† https://t…".** Four `\thanks` on the last author: "$ˆ1$ Massachusetts Institute of
  Technology …" lines (TeX the author typed, which LaTeXML left as text, `^` as "ˆ"), "E-mail: {<a>delpreto</a>,
  <a>rus</a>}@csail.mit.edu; …" (the mailto links left out, so "{, }@csail.mit.edu;" stayed: the e-mail rule ran on each
  piece before they were joined), and "Project website and video: <a>…</a>" (the address moved to its own line, leaving the
  label). Now: a TeX-typed mark is the mark (`texMarks`: `$^1$`, `$ˆ{2}$`, `$^\dagger$`) and the tie "˜" a space; in a note,
  a line of numbered marks joins the affiliations, a contact line its left-out addresses emptied goes ("E-mail:",
  "Correspondence to:"; "Corresponding author: …" says who and stays), a link stays in its words, a symbol mark after
  words starts a line; addresses are removed after the pieces join (`tidy`); a note left with nothing marks no name. The
  header reads the names, the four affiliations, then "*These authors contributed equally… Corresponding author: Joseph
  DelPreto." and "Project website and video: https://tennis-vision.csail.mit.edu". Sibling: 2407.04620v1 (TTT: "˜$ˆ†$ Joint
  advising", "˜˜˜ $ˆ1$ Stanford University. ˜$ˆ2$ UC San Diego …", "Correspondence to:,,.", "Code available in and."); and
  e-mail-only notes that left "Correspondence to." or a mark pointing at nothing (2404.19756v1, 2406.02528v1/v7,
  2610.06903v1). The sweep now fails on TeX typed as text or address pieces anywhere in the header; e-mails count only in
  the names, since the contact paragraph after an abstract joins the affiliation lines whole (revisions 20 and 22).
- Found on the way: a parbox whose later paragraphs are marked affiliations (2610.13166v1: names, then "¹University of
  Science and Technology of China", one paragraph each) read as one run in which the institutions were names; each
  paragraph is now a line (also 2610.31650v1).

Evidence: `tests/backend/arxiv-sweep-fixes.test.ts` (one test per construct on LaTeXML's reduced markup; all seven fail on
revision 28) and the updated refusal tests in `arxiv-html.test.ts`; `npm test` passes. Replay of every cached source against
revision 28 (`arxiv-converter-equivalence.mjs --rev=65545895 --ignore-ids`: 243 sources, 474 runs, 48 differ; by paper, 229
papers, 466 runs): 31 papers change, none newly refused, no output changes outside the 3 formerly refused papers and 28
author headers, each reviewed; the 8 refusals left are identical (1412.6980v9 is a pointer to the PDF; 6 papers without an
`h1` refuse `arxiv_title` only when compiled without the catalog title, which the apps always pass). Fresh-paper sweep
(`--recent=40`, 30 papers, the same listing as the morning's): no failures, one existing warning (Honeycomb-Surfels' 708
dropped commands). Device path (`reader-device-compile.mjs`, headless Chromium): 2610.37645v1, 2610.37481v1, 2610.37651v1
and 2610.37619v1 prepare with every image. Screenshots (Playwright WebKit, 393 pt, light and dark, before and after):
`.artifacts/reader-sweep-fixes/`.

**Still not opening: 2610.37633v1 on a device.** Its HTML now converts, but its 16 images are 48 MB of PNG (up to 8.4 MB
each), over the hosts' per-paper download budget (40 MiB: `ArxivAcquisitionPolicy.totalBytes` in the app,
`ARXIV_LIMITS.totalBytes` in the browser), so acquisition stops with "too large", and the compiler's own input check
(`device-compiler.ts`: source plus downloaded images ≤ 32 MiB, before any image is redrawn) refuses `bundle_limit`. The
reader showed the PDF screen before (for the fragment) and still does. 2312.14235v1 (≈ 90 MB of images) is the same class.
Proposal, not built (it changes both hosts and needs the Simulator): an image past the budget arrives `missing`, so its
figure says the PDF has it, and the compiler counts the redrawn images' bytes rather than the downloads'.

### Figure panels set apart from their captions (revision 28, 2026-10-28; not yet released)

Agent report: 2610.20608v1's Figure 2 showed only "(a) Strong correlation of gFID and CKNNA", "(b) …", "(c) …" and its
caption, and the paper's closing note counted its three plots as left-out graphics (before revision 27 too). The source
draws the three plots in one row and captions them in the next. LaTeXML wrote a flex figure: one
`p.ltx_figure_panel` holding the pictures (a PNG `img` and two `object type="image/svg+xml"`, each in a raised
`span.ltx_text`), a flex break, three sub-figures (`figure.ltx_figure_panel`) holding only their `figcaption`, then the
figure's caption. The panel rule (revision 12, `imagePanels`) wants every sub-figure to hold its picture, so the figure
took the compound route, every child its own block: the paragraph of pictures became a paragraph, where a graphic
outside a figure is left out and counted (the rule for logos in running text), then three caption paragraphs. The
pictures were never planned or fetched; the SVG `object`s, their sizes and paths, and revision 25's SVG `<image>`
inspection played no part. Figure 8 of the same paper has the same shape.

- **Pictures apart from caption-only sub-figures** (`panelsApart`, `arxiv/figures.ts`): a figure with one caption of
  its own whose sub-figures each hold only a caption, and whose pictures sit outside them in layout without words
  (paragraphs, spans, flex cells, links), is one figure. The i-th picture joins the i-th sub-figure, above its caption
  when the pictures come first, below it when the captions do; the figure then reads as panels do (picture, its
  caption, …, the figure's caption), the shape the figure viewer reads parts from. When the counts differ, the
  pictures and captions keep page order inside the one figure. A picture with words beside it (a legend) or any other
  content keeps the old reading.
- **The tabular form** (`labelledPanels`): a figure float (not a table float) whose one tabular holds rows of single
  pictures and rows of words, each words row next to a row of as many pictures, with no spanning cells and nothing else
  besides its caption: each picture with its label, under it, or over it when the words row comes first. Batch
  Normalization's Figure 1 (1502.03167v3: three plots, then "(a)", "(b) Without BN", "(c) With BN") had read as a
  table of three labels; 2610.09823v1's galleries (rows of four photos, each with a row of names) and 2610.31644v1's
  Figure 10 (names over pictures) read the same way.
- Every source id inside such a figure (the row of pictures, a table cell) resolves to the figure block. Past the
  16-picture figure limit the first pictures show and a label whose picture is left out stays as words (2610.09823v1:
  16 of 24 photos with their names, then 8 names).
- Unchanged: a grid with row or column headings (a method per row, a scene per column) still reads as a table of its
  words with the pictures left out and counted: 18 figures with 588 pictures in 5 cached papers (2610.31644v1 Figures
  5, 6, 12–18; 2012.03912v1; 2610.19847v1 Figure 3; 2610.20584v1 Figure 10; 2610.22371v1 Figures 6–8), and 28 table
  floats with pictures in cells (613, in 10 papers, mostly icons and thumbnails). Showing them needs pictures inside
  reader tables, a vocabulary change for the three validators (validate.ts, ReaderBundle.swift, apps/web bundle.ts),
  left for a proposal. Also unchanged: the 16-picture figure limit (2610.20608v1's Figures 10–13, 72 small pictures
  each).

Evidence: `tests/backend/arxiv-figure-panels.test.ts` (both layouts, captions over pictures, counts that differ, a
panel the device couldn't prepare, labels over and under, the grid, table float and uneven rows that stay tables, a
composed bundle the shared validator admits); they fail on revision 27's flow. All 243 cached sources replayed against
revision 27: 4 papers change (61 pictures in 7 figures: 2610.20608v1 Figures 2 and 8, 1502.03167v3 Figure 1,
2610.09823v1 Figures 1, 10 and 11, 2610.31644v1 Figure 10), nothing else differs, none newly refused; the closing
notes of the 219 sweep and corpus papers that compile count 2,669 left-out graphics in 74 papers (2,730 in 75 before). The
reported layout itself occurs only in 2610.20608v1 among them. Device compile (`reader-device-compile.mjs`, headless
Chromium and WebKit): the four papers prepare with every picture and no note. 2610.09823v1 now carries 71 images
(26.1 MiB, 9.2 before); 71 images exceed the per-image share of the 64-million-pixel budget, so each is redrawn as PNG
and preparing it takes 25 s in WebKit on a Mac (1.7 s before), likely about a minute on a phone, within the 90 s guard.
Fresh-paper sweep (30 papers, 2026-10-28): 5 failures, each identical under revision 27 (not this change; see
IMPLEMENTATION_STATUS.md). Playwright WebKit screenshots at iPhone width, before and after, light and dark:
`.artifacts/figure-panels/` (Figure 2, Figure 8, Batch Normalization's Figure 1).

### Floats before the first section (revision 27, 2026-10-25; not yet released)

TestFlight 92 feedback for WorldCast (2610.20731v2): "Is the Figure displayed in the right place". LaTeXML keeps a
float where the source wrote it; WorldCast wrote Figures 1 and 2 after `\maketitle`, before `\section{Introduction}`
(the PDF sets them at the foot of page 1 and the top of page 2), so the phone read the abstract, Figure 1's caption,
Figure 2, the keywords row and only then "1 Introduction", whose second paragraph cites Figure 1 (Figure 2 is cited
nowhere). On paper the eye takes in a page-top float beside the text citing it; a phone's single column has no page.
Rule (`float-placement.ts`, the arXiv adapter's `arxiv/floats.ts`; JUDGMENT_LOG 43):

- A **float** is what one source `figure` element became (a figure, a table float, an algorithm, with panels and
  captions), plus the uncaptioned picture right above a caption-only float (`\captionof`). One of captions alone whose
  picture became something else (2610.07591's diagram read as its labels) can't move, nor can any float before it.
- A **citation** is an in-page link from prose (a paragraph or a list; not a caption or a table) before the references.
- A float between the title and the first section (the first `h2`–`h6` after the title other than Abstract or
  Contents) moves when the first section (with its subsections) cites it: to just after the whole LaTeXML paragraph
  (`ltx_para`) holding the first citation, so a citing sentence keeps its displays and closing words. Every later
  float before the first section then moves too, to its own first citation in the body or right behind the float
  before it, so floats stay in their numbered order. No float passes a float of the body (it waits right above it), and
  none reaches the references or an appendix.
- Unchanged: a front float the first section doesn't cite, ahead of any that moves (a teaser such as DDPM's samples,
  cited in §4; a figure cited only in the appendix or never), and every float in the body. On the 186 cached sources,
  614 of 1,509 cited figures still sit before their first citation (635 before this revision), half within 500
  characters and 302 in an earlier section, most at the top of the section discussing them; moving those is the wider
  option not taken.
- Ids are issued in source order before the pass, so the move changes no id or alias (links, Show in PDF, explanations,
  snippets); `reorder` reads the index's blocks, equations and figures back in page order.

The reader bridge's keywords row (`paperTagsPlace`) now sits right after the abstract heading's paragraphs, before the
first figure, table, caption or section after it, for every bundle version, so a teaser kept under the abstract comes
after the row; a page without an abstract heading before the first section keeps the row before the first section.

Evidence: `tests/backend/arxiv-float-placement.test.ts`; 186 cached sources replayed against revision 26: 21 change
(35 floats moved, none changed otherwise), 0 newly refused, all pass the validator; fresh-paper sweep (30 papers) 0
failures; iPhone 17 Pro Simulator screenshots of WorldCast compiled by revisions 26 and 27 under `.artifacts/tf92-figures/`
(`ReaderNavigationTests.testTestFlight92FigurePlacement`). On-device model readings take the same rule with named
citations (DEVICE_PDF_ROUTE.md, port revision 15).

### Aligned equations and accents (revision 26, 2026-10-25; not yet released)

TestFlight 92 feedback for 2610.27450v1 ("Ask to Distill"): equation (2), `align` with two column pairs, read as eight
centred lines, and (3)'s `\bar{p}^U_M` had its bar off to the left. Causes and changes:

- **Alignment.** LaTeXML writes align/alignat/eqnarray as an HTML table (`ltx_eqn_table`, rows `ltx_eqn_row`, cells
  `ltx_align_right`/`ltx_align_left`, a `math` per cell); the flow made each `math` a display of its own. `arxiv/align.ts`
  now reads the rows and makes one display equation per number: a MathML `mtable` (`displaystyle`, `columnalign` per cell
  from its column, `columnspan` for spanning cells), its LaTeX the cells' own as `aligned` (or `array{…}` for other column
  patterns; one line of one relation as itself), every source formula accounted for and its id aliased to the equation.
  Lines belong to the next number (a continued line, first column empty, to its own; trailing unnumbered lines to the
  last). A cell holding anything but formulas and plain words falls back to the previous reading. An operator opening the
  cell after a relation's `&` gets `form="infix"`, spaced as LaTeX spaces `&=`. Groups of one-formula lines with two or
  more numbers carry each number on its own line.
- **Cell alignment CSS.** `MATH_TABLE_CSS` (arXiv and on-device stylesheets): `mtd[columnalign]` sets `text-align`
  and, for Chromium, which ignores both, `justify-items`; a relation's two sides lose the cells' inner padding. It is in
  the bundle, so the paper, the equation view and the Equations tiles align alike (the bridge's own rule covers only the
  reader page).
- **Accents** (`accents.ts`, shared with the on-device route). WebKit positions an accent's glyph by its own ink height:
  spacing accents float an x-height up, and stretched ¯ ^ ~ use STIX Two Math's smallest wide form, wider than A, W or μ
  (the bar reaching left, scripts pushed away). Over a single token the mark becomes a low-set twin with no operator
  spacing: ¯ → en dash, ^ → ‸, ~ unstretched, ˙ → ⋅, ¨ → ⋅⋅, ˚ → ∘; over a group the stretched mark stays. Checked on the
  iOS 26.4 Simulator's Safari, Playwright WebKit, Chromium and Firefox. Acute, grave, breve and check still float in
  WebKit (no low-set twin; none in the 185-source cache).

Evidence: `tests/backend/arxiv-equations.test.ts`; 185 cached sources replayed against revision 25 (132 change, 0 newly
refused); fresh-paper sweep (30 new papers) 0 failures; iPhone 17 Pro and iPad Pro 11-inch Simulator before/after
screenshots under `.artifacts/tf92-equations/`.

### Leaked font options (revision 18, 2026-10-17; browser / TestFlight 67 iOS and Mac released)

Build 66 feedback for FDE-Gym `2610.22350v1` shows fontspec options before its title page. The exact official HTML
contains those options as plain text, followed by the title, project links, contributors and affiliations in the
same paragraph. The adapter removes only a complete leading sequence of recognized font options in the first
custom title paragraph, before any heading/section. Unknown fields, incomplete groups and body examples remain.
It preserves the paragraph's content and records the discarded setup commands in the existing closing note.
Two authored regressions pass; the full device compile preserves all seven images and 63 equation entries.
Pinned source/asset responses join the native import gate. Existing working copies retain their version until
the reader chooses **Reader version details → Update this paper**, as requested by the owner.

### Math text badges and algorithm classification (revision 17, 2026-10-17; browser deployed, TestFlight 66)

Build 65 feedback for DocPilot `2610.21327v1` reproduces `arxiv_math_element`: Algorithm 1's action set
contains four SVG text badges inside MathML `mtext`. The adapter recognises a bounded LaTeXML foreignObject text
label surrounded only by one or two closed, axis-aligned rounded rectangles. It retains Navigate, Extract,
Focus and Solve as MathML text. No SVG, foreignObject, source CSS or event attributes enter the output. Other
vector math remains an explicit failure; arbitrary drawings must not be reduced to their labels.

The full device-compiler replay then exposed `figure_structure`: the algorithm was classified as an image figure
because the image scan counted these SVGs inside math. Figure classification now excludes graphics owned by math,
keeping this algorithm as a text listing. Separate regressions cover both failures, label retention and rejection
of non-decorative paths. The full real-paper compile preserves all 13 images; native acceptance is a separate gate.

### Figure compatibility extension (2026-10-13, implemented; browser deployed)

The reported `2610.10478v1` groups multiple numbered image/caption pairs in a single LaTeXML figure. Split
those pairs into ordered reader figures. `2610.12978v1` embeds SVG legend symbols and their text inside figure
containers. Preserve those symbols by the same bounded, network-disabled SVG rasterizer used for external SVG.
Do not drop legend text or draw guessed substitutes.

Use renderer `gradstep-arxiv-html-mathml-v2` and provenance `arxiv-html-reader-provenance-v2` for this extension;
keep v1 admission for installed bundles. V2 additionally records `inline_image_inputs`, keyed by unique source SVG
IDs, with the hash of the parser's canonical SVG serialization and the admitted PNG identity/dimensions. These
bytes derive from the already hashed HTML and never become fetch URLs. External `image_inputs` keep their exact
revision URL constraints. All referenced PNGs must belong to a declared figure and be accounted for by provenance.
Only the v2 HTML validator admits bounded inline raster images and legend paragraphs inside a figure; no inline
SVG, source CSS, scripts or new remote resources enter the reader. Every client must recognize v2 independently.

Retain `reader-bundle-v1` and `reader-index-v1`. Introduce a real source/profile pair:
`source.kind = arxiv-html`, `renderer.id = gradstep-arxiv-html-mathml-v1`, and
`arxiv-html-reader-provenance-v1`. Never label HTML as `mathpix-mmd` or manufacture an OCR job/PDF digest to pass
today's validators. The Node/backend, native Core, native WebView and browser verifiers must all recognize the
profile independently before a client accepts it. A source-profile addition must not weaken existing profiles.

The adapter accepts bounded UTF-8 source bytes, a verified versioned source URL and an explicitly supplied asset
map. Parsing and rendering perform no network operations. A separate acquisition layer owns redirects, host rules,
timeouts, byte limits, rate limits and cancellation. It validates every final URL, rejects credentials/non-HTTPS
URLs, and admits only official arXiv content origins verified for this source. An asset fetched from another paper
or arbitrary URL is not trusted merely because the HTML referenced it.

1. Parse without executing source scripts or loading resources. Select the paper's article content, excluding
   navigation, feedback widgets and site chrome. Validate identity against the pinned source revision.
2. Convert the article tree to a source-neutral intermediate structure. Preserve paragraph/list order, headings,
   abstract/authors, bibliography, footnotes, equation numbers, figures/captions, tables, algorithms and internal
   references. Unsupported substantive content is an explicit conversion error, not dropped text.
3. Preserve sanitized MathML for display and original TeX from source annotations/attributes for equation Copy and
   selection. Normalize only known delimiter forms, recording `source_form` correctly; do not reconstruct TeX
   from visual text. Missing or inconsistent math representation fails the relevant readiness gate. Remove active
   attributes, foreign namespaces, external resources and unsafe annotation markup.
4. Map source IDs deterministically to safe bundle block/equation IDs. Rewrite section, equation, citation and
   footnote fragments through the same mapping; preserve an explicit reference destination when it exists instead
   of relying solely on citation heuristics. Duplicate IDs, unresolved required destinations and nested reader
   blocks fail validation. IDs bind the source digest and adapter revision so changed content never inherits old
   anchors accidentally.
5. Admit images using the existing bounded image checker, rewrite to content-addressed member paths and emit
   dimensions, caption, alt text and figure ownership. Account for all figures and table cells. Source SVG, WebP
   or other unsupported assets need a separately bounded device rasterizer before admission; they cannot be
   passed through, fetched at reading time or silently omitted. V1 may reject these inputs until supported.
6. Emit generator-owned HTML/CSS, the existing index, provenance, notices and image members. Include no remote
   styles, scripts, fonts, frames or runtime resource fetches. Use the existing restrictive CSP and reader bridge.
7. Independently validate DOM/index correspondence, math/figure ownership, fragments, member hashes, paths, limits
   and provenance, then atomically install into the account's encrypted store. A digest received alongside an
   untrusted package is not an authentication proof. Direct builds trust their local validated acquisition;
   transferred builds additionally require the approved-device package authentication.

Provenance binds the canonical source URL, arXiv ID and exact revision, raw HTML byte count/SHA-256, each source
asset's URL/input digest and published member digest, adapter revision/build digest. Observed license evidence remains in the metadata catalog, bound to the same source ID and exact revision; the device bundle makes no separate licensing or redistribution claim.
It contains no provider job, PDF hash or claimed page count. Notices retain applicable adapter dependencies and
source attribution. Keep fetched-at time in the local acquisition record, outside deterministic output identity.

Limits: 8 MiB source (`ARXIV_SOURCE_BYTES`; 2 MiB until 2026-10-15, when a 2.6 MB technical report was refused;
copied by hand into both apps' acquisition policies), and from the MathML profile 8 MiB output HTML, 4 MiB index, 256 KiB manifest and provenance,
32 MiB bundle, 512 members, 20,000 blocks, 1,000 headings, 4,000 equations, 256 figures and 64 million total image
pixels. Acquisition also bounds cumulative input asset bytes and decoded pixels; final bundle limits alone are
insufficient. Real-paper measurements can motivate a versioned limit change, not an unbounded fallback.

## Identity, persistence and synchronization

Library membership must name a logical paper/version without requiring a server `document_id`,
`original_object_id`, PDF approval or OCR run. The existing model and `canRead`/native presentation checks require
some of these today. Design an additive, capability-versioned membership/read contract before a schema change;
do not fill required columns with fake objects, bypass integrity checks or reinterpret an old protocol field.

Use independent records for:

| Record | Identity and content |
|---|---|
| Synced membership | Account, stable membership ID, source kind/ID, exact revision, metadata, tags and removal state |
| Local original | Account, source/version or local-file identity, PDF digest, encrypted blob, local availability |
| Local prepared reader | Account, membership/source version, HTML digest, renderer revision, manifest digest and encrypted members |
| Encrypted conversation/anchor | Existing encrypted event plus a versioned logical-paper binding and exact bundle/block identity |

A chosen PDF without an arXiv match gets an account-scoped random identity and an encrypted filename/title
descriptor; a guessed DOI or title is not byte identity. No PDF digest needs to be sent as a substitute cloud asset.
The existing `DevicePaperStore` is the starting point, but its arXiv-only PDF record is not yet the general
local-document/bundle store. Preserve account retirement fences, quotas, atomic publication, crash recovery,
corruption detection, key recovery semantics and explicit local removal. Exclude local originals and bundles from
automatic OS/cloud backup so device-only paper storage is not undone by platform backup defaults.

Other approved devices synchronize membership and encrypted user state, then independently acquire the same exact
source version or use approved-device transfer after that mechanism is implemented. Local availability belongs to
the device and is never synchronized as “ready everywhere.” Browser eviction, lost devices and cleared storage can
remove the only local PDF; a recovery code recovers keys, not absent files. Reading activity remains device-local
under its current contract; this design does not silently add reading-position sync.

Do not remap notes, selection anchors or chats to another rendering using ordinal position or title matching.
Keep their original bundle identity, retain the old local bundle while referenced when feasible, and offer a clear
source-version mismatch if the exact content cannot be reopened. New binding formats require explicit old-client
compatibility handling. No bulk migration/reprocessing of old papers or encrypted history is requested.

## Paper chat and other derived work

General chat, model/effort/length controls, encrypted history, consent, streaming, Stop and selection actions remain
as they are. New paper chat must not require `worker_chat_context` to read server `standalone.mmd`.

Define a versioned local-context request: logical membership/source revision, exact bundle digest, bounded plain
text/TeX snapshot derived from the verified reader index, selected block IDs/text and normal conversation inputs.
Do not include PDF bytes, source HTML, figure images or an arbitrary fetch URL. Preserve the current 2 MiB paper
context ceiling and token/output budgets; never silently truncate a full-paper question.

The server authenticates the account and membership, treats the supplied context as untrusted user content,
validates its shape and size, freezes its digest with the operation, and reserves/settles credits from server-side
token/cost bounds. A client digest proves neither publication authenticity nor entitlement and must not authorize
shared-cache publication. Replaying the same operation with different context conflicts. No raw local context in
logs, queues, support diagnostics, Storage or durable job records; use request memory for synchronous chat and
retain only bounded operational identifiers/digests. A timeout follows existing uncertain-spend accounting.

The existing cloud-AI consent still applies: asking a paper question sends the necessary paper text and passage to
the service and model provider in plaintext for that computation. PDF-local processing does not mean cloud chat
is on-device, and does not promise provider zero retention. Future PDF-engine text needs this same explicit
request boundary; there is no background upload of extracted content.

Podcasts keep their existing rights, quotation and spending controls. Existing permitted catalog playback is
separate from acquisition. New HTML-based generation must bind script evidence to the HTML bundle. The durable
podcast job design cannot silently persist device-only text; a local-source podcast route needs its own reviewed
context/retention contract before activation and cannot fall back to uploading a PDF.

## Cutover and verification sequence

### Implementation contract (2026-10-13, work in progress)

- Source-only import records are the genuine metadata membership for locally prepared papers. Their stable import
  UUID is explicitly a **membership** identity, never a `documents.id`. Add a `source-membership-v1` capability
  and typed source reference; leave existing document-backed records and their historical bundles intact.
  Source membership archive/tag changes use their own replayable, revision-checked commands. No fake PDF,
  catalog approval, page count, OCR run or artifact is inserted to make a local reader appear ready.
- New encrypted paper events carry `paperReference` (format, membership ID, source kind/ID and exact revision).
  They omit the legacy `documentID` field. Local passage anchors carry the exact manifest digest and omit the
  legacy artifact UUID. An explicit encrypted-envelope version and compatible pull API prevent old clients from
  misreading these events as general chat; an old pull that encounters this format returns an upgrade error.
  Existing events retain their original identities and encoding; there is no history migration.
- Native HTML bundles use a separate `device-readers` encrypted directory, manifest and AES-GCM AAD domain beside
  the existing PDF store. Publication is atomic and account retirement drains accepted writes. Bundle/source
  identity and member integrity are verified on every reopen; compilation independently validates inert HTML
  against the reader index and native admission fully decodes each image. Both directories are excluded from
  OS backup. The device compiler runs in an ephemeral WebKit context with no network access.
- Direct HTML/asset acquisition uses only exact `https://arxiv.org/html/<id>v<revision>` identities and the
  corresponding asset path. Cross-version/host redirects are refused. Pacing (revised 2026-10-13, late): a paper's
  HTML document request is spaced three seconds from the previous document request on that client, like a new
  page visit; the declared assets of that one paper then load with at most four in flight and no artificial
  spacing, the way a browser loads one page's images. A `Retry-After` pauses every request on the client, and a
  pause longer than a minute is reported as "busy" immediately. Source and cumulative asset bytes are bounded
  (2 MiB source, 16 MiB per asset, 32 MiB in total), and failures leave any previously installed copy intact.
  Source SVGs are admitted as bounded, external-resource-free vectors and rasterized on the device; source SVG
  is never installed in a reader bundle. PDF acquisition remains independent.

These contracts are implemented in migration 058 and native/browser clients. Deployment and measured checks are recorded below; the following sequence also remains the regression checklist.

1. **Adapter proof:** authored hostile-input fixtures and a representative, rights-cleared arXiv HTML corpus,
   pinned to exact revisions. Measure equation/TeX equivalence, figures/tables, bibliography, fragment links and
   deterministic output. Include missing HTML, unsupported assets, malformed MathML and changed same-version bytes.
2. **Native path:** new profile admission, metadata-only paper identity, local acquisition/install and encrypted
   offline reopen. Route choose/drop/Share/download/retry into the local store. Verify iPhone/iPad Simulators and
   Mac Catalyst, cancellation, termination, disk full, account switching and deletion. Physical iPhone remains
   paused until the owner resumes it.
3. **Chat parity:** implement the versioned local context/binding protocol and prove paper/general chat, Copy,
   Explain, Quote, Ingest, passage return, encrypted sync, two-account isolation, replay and server spending limits.
4. **Server enforcement:** reject new PDF upload sessions/chunks/freeze/attach and server PDF acquisition/OCR
   admission, including requests from old clients. Fence already leased workers so stale jobs cannot start a PDF
   download, parse, re-render or paid submission. Stop accepting additional PDF bytes before reading request bodies.
   Existing provider attempts still need metadata/status-only reconciliation; do not collect/process their PDF
   outputs or release uncertain holds without evidence. Do not repurpose rights_mode as a processing-location flag.
5. **Browser path:** independently prove CORS/intake, encrypted browser quota/eviction handling, new profile
   validation and offline reading with local context chat. Reuse the same golden bundle/index corpus across clients.
6. **Coordinated rollout:** additive contracts and compatible clients first, explicit switch/fencing plan,
   then enabled HTML acquisition. Verify network/storage/provider traces show zero new server PDF bytes or Mathpix
   submissions across all intake and retry paths. Old clients receive a bounded upgrade/local-only response, not an
   infinite retry. Rollback may pause imports; it must never restore a prohibited PDF/Mathpix path.

Inventory retained server originals and PDF-derived artifacts separately. No automatic data migration, broad
deletion or rerender follows from this design change. Stop new PDF processing at cutover; removal of existing
copies requires an explicit retention/cleanup operation with backup and spending consequences recorded. Do not
advertise “no PDFs on our servers” while historical copies remain.

**Retired 2026-10-16 (owner decision):** the historical copies (1,631 objects, 649 MB in `paper-assets`) are deleted by
the explicit operation in [Data handling: server paper copies retired](DATA_HANDLING_AND_COSTS.md#server-paper-copies-retired)
(migration 080, `scripts/delete-paper-copies.mjs`, the `storage.no-papers` check). A legacy item's server bundle is no
longer a fallback: the library says it is unavailable, an arXiv item reads only from its official HTML on the device,
and the browser's paper chat for it sends the device's text.

## Costs and future local model

New HTML adaptation and local PDF work incur no Mathpix/OCR credit charge. Cloud chat/search/podcast charges remain
metered as before. Fixed commitments, actual usage, outstanding reservations and forecast remain separate; past
Mathpix spend and unresolved attempts remain in the ledger. Any projected savings start after verified cutover and
do not increase the $100/month cap or change subscription allowances. No hosting/model-download commitment is made.

The future PDF engine is a local producer of the same reader/index contract with its own honest PDF/model
provenance. Evaluate text/layout extraction, on-device OCR and a scientific-document model against a held-out
corpus, commercial model/weight rights, memory, battery, thermal behavior, cancellation and recovery. Ship only
after equations, reading order, tables and figures pass. Until then, difficult PDFs remain viewable originals;
Mathpix is retained only as historical comparison evidence, not an executable fallback.

## Implementation boundary at adoption

Present code has the strict MathML renderer/verifiers, encrypted bundle stores, a native arXiv source-only PDF
store/viewer and the existing reader bridge. It does **not** have this HTML adapter/profile, general local-PDF
intake, paper membership independent of server PDFs, local-context chat, complete browser intake or the universal
server PDF stop. No schema, worker, provider switch or deployed client changed when this design was recorded.

### Local verification update (2026-10-13, before deployment)

The native adapter, exact-revision transport, independent bundle admission,
encrypted device reader/PDF stores, explicit source membership and format-2
private events are implemented locally. All 286 Core tests pass, including the
shared HTML fixture, encrypted reopen and new envelope checks. The compiler also
passes its WebKit integration test on an iPhone Simulator. The database suite
checks legacy accounting before cutover and the new metadata-only contract after
058; both pass. This is local evidence, not deployment evidence.

Chosen local PDFs use encrypted `local_paper` events containing a bounded title,
page count, creation time, archive state and tags. File bytes and digests never
enter cloud sync. Other devices can see the membership and request a local file.
A PDF chosen for an existing source membership is associated locally with that
membership. It cannot provide structured context until local parsing is available.

Browser reading initially retains its existing session-memory bundle policy.
This cutover does not claim the separately gated browser offline-cache work is
complete. The source metadata service retains observed arXiv license evidence;
HTML preparation does not infer a distribution license or authorize a shared cache.


## Staging cutover evidence — 2026-10-13 PDT

- Migration `202610130058` applied and ledger hash verified. It blocks PDF upload/read/admission, original writes,
  OCR funding/submission, legacy processing-job claims and reader asset publication. Historical accounting and
  stored originals remain; no bulk migration, rerender or deletion occurred.
- Cloud Run `gradstep-pipeline-00033-2jw`, 100% traffic, metadata-only code, no Mathpix environment secrets.
  Admission was paused after observing zero pipeline claims, unresolved provider attempts/liability and asset writes,
  then resumed after the migration and worker cutover. Edge `upload-pdf`, `chat` and `paper-worker` deployed.
- The scheduled workflow job no longer contains the PDF-download corpus. Its image-only refresh preserved IAM,
  schedule configuration and secrets; schedules were paused for the replacement and restored. New zero-credit
  checks prove HTTP 410 upload refusal, exact DPO v3 metadata with no document/artifact identity, source archive/tags,
  and idempotent command replay. The first live probe exposed the `/oai` allowlist mismatch; the fix and regression
  test passed before the final live check. Reports retain both observations.
- Browser Pages `50ecbc01` (help-copy follow-up to `a95696d2`): direct official HTML/assets, isolated deterministic compiler, existing verified reader
  and local-context paper chat. Browser PDF bytes remain in the selected device file/tab; encrypted membership
  persists, and reopening the tab asks the user to choose the file again. Browser bundles retain the existing
  bounded RAM cache; this release does not claim durable browser offline bundles.
- Local evidence: backend 497 tests; Core 286 tests; app 410 tests
  (5 optional skips); targeted iPad reader/PDF/library tests; browser 343 unit tests and four desktop/phone
  production-CSP journeys for HTML/math/figures/chat and local PDF membership/reload. Real DPO, Mamba and
  MatMul-free HTML corpus conversion independently validated. No physical iPhone was queried or tested.
- No future local PDF model is installed. Missing or unsupported official HTML remains an explicit unavailable
  reader outcome with device-local PDF access. Existing historical document-backed readers keep their identities.

Evidence lives under `.artifacts/html-*` (not source-controlled and not transferred to SSH). The hosted real-source
browser check and final Apple processing states are summarized in `docs/IMPLEMENTATION_STATUS.md`.

The screenshot identified `2610.10478v1`; its grouped captions and SVG glyph metadata reproduced the reported
failure. The sidebar's `2610.12978v1` additionally requires inline SVG legends and MathML background colors.
The v2 extension above is deployed in browser `16b9e4ce`, with all five real corpus papers passing Chromium,
Firefox and WebKit. Specific finite error messages from `e9d6522a` remain; raw exceptions/source content are
never sent as diagnostics. See the current implementation-status entry for hosted and native release evidence.

### Maintenance after cutover — 2026-10-13, late (local, not deployed)

- **Acquisition pacing.** The first cutover spaced *every* request three seconds apart, so a paper with sixty
  figures took about three minutes to open in the browser on each reload and once per device natively. Both
  clients now pace only document requests and load one paper's assets with bounded concurrency (above).
- **One preparation per paper.** In the browser the reader and a paper question asked before the reader was
  ready each started their own acquisition and compilation; `prepareArxivReader` now shares one in-flight
  preparation per exact source revision, forwards progress to every waiter and stops only when all have left.
- **Go to passage across compiles.** Both clients refused a saved passage whose anchor named a different bundle
  digest, and the browser did so silently. The digest changes with every renderer/CSS revision (v1 → v2 happened
  the same day) and a browser recompiles on every reload, so saved chats stopped navigating. The digest now only
  decides whether the block hint applies; the existing quote cascade finds the passage, and "Couldn't find the
  passage" appears only when the quote is genuinely absent.
- **Code removal.** The server-side PDF pipeline (`pipeline.ts`), Mathpix HTTP client, upload-session module,
  asset uploader, web PDF downloader and their tests are deleted; the metadata pipeline owns its own types, and
  the historical OCR identity remains only so retained `mathpix-mmd` bundles stay verifiable. The browser's
  chunked upload transport and the native `PaperAddingService` upload methods, `BackendClient` upload calls and
  queue back-off are deleted. A native queue record written by a pre-cutover build is now offered **Save on this
  device** (installs the queued file locally, then clears the record) instead of a retry that could never succeed.
- Evidence: fast suite 443 backend + 356 browser unit tests and compiler freshness pass; Swift Core 287 tests
  pass. Slow reader journeys and the iPad Simulator checks for the touched areas are recorded in
  `IMPLEMENTATION_STATUS.md`. Nothing was deployed; native build 30 and browser Pages `a3127547` remain live.

### Compiler tolerance and legacy items — 2026-10-14 (owner report: "quite a few 'couldn't open this paper'")

The owner's nine papers added on 2026-10-13/14 were replayed offline (`READER_CORPUS_SET=owner-20261014`): five of
nine refused to compile, for three structural reasons, none of which should cost a reader the paper. The adapter
now reads them all, and says in the paper what it left out:

- **LaTeXML conversion markers** (`ltx_ERROR`, an undefined preamble macro such as `\pdfauthor`; one paper carried
  288) no longer refuse the paper: the markers are dropped and counted; over 1,000 still refuses (`arxiv_conversion_error`).
- **Graphics in running text** (an affiliation logo in the author line, a TikZ mark in a sentence) were refused as
  `arxiv_nested_content`. Outside a figure the reader has no inline-image vocabulary, so they are left out and
  counted; a paragraph whose only content is one graphic (an unwrapped `\includegraphics`) is a figure.
- **TikZ pictures** (`svg.ltx_picture`) draw their labels as `foreignObject` HTML, which the device SVG admission
  refuses. A lone picture whose labels hold text (a framed "Finding" box) reads as paragraphs with the frame left
  out and counted; a picture inside a figure keeps its labels as centred SVG `<text>` (best-effort placement). Math
  inside a picture counts as carried by it, not as a missing equation. Since revision 23 (build 88, 2610.14162v1
  Figure 3) a label of several lines (paragraphs, table rows, `\\`) is drawn line by line, a minipage's from its
  top-left corner wrapped to its width at an estimated half an em a letter, and `\phantom` struts are not drawn. Text
  that overflows a box overflows as in arXiv's own page (LaTeXML's box sizes, not the reader's).
- When anything was left out the paper ends with one paragraph: "Note: arXiv's HTML conversion of this version
  left out N unsupported commands and M inline graphics. The PDF is complete."
- **Asset planning is the compile.** `arxivHTMLAssets` and `arxivInlineImages` now come from a dry compile, so what
  is fetched, what is published and what provenance lists are the same set by construction (a left-out graphic is
  never downloaded), and a structural refusal surfaces before any image is fetched.

**Legacy arXiv items** (library items from before the cutover, with a server-processed bundle and no source
membership) open through the same on-device HTML reader by their exact revision; an installed server copy still
opens offline, and the server bundle is the fallback when arXiv has no usable HTML for that revision. Chat for
such an item keeps its server document (no numbered local context). The library says "Opens from arXiv" for an
arXiv paper not yet prepared on this device, and the reader never dead-ends on "download needed" without a reason
and an action. Both clients (`ReaderModel.openLocalPaperIfNeeded`, `Reader.tsx` with `readingSource`).

### Authors block — 2026-10-14 (owner request: "the authors list presented nicely on all surfaces")

LaTeXML's `div.ltx_authors` prints every affiliation mark twice (`ltx_note_mark` in the text and again inside the
note's content with a "footnotemark:" label and its tag), inlines "thanks:" notes and lists e-mail contacts; emitted
as one paragraph it read "Rafael Rafailov 22footnotemark: 2 ††thanks: Equal contribution…". The compiler's
`authorsBlock` now writes the one `p.reader-authors` block (same vocabulary, same block count, same index text
position) as: each `ltx_creator`'s `ltx_personname` once with its marks as one superscript ("Rafailov<sup>2,†</sup>";
a note beside the name, such as an equal-contribution dagger, marks the name); then, after a `<br>`, the affiliations
("<sup>2</sup>Stanford University · <sup>3</sup>CZ Biohub"): a creator that starts with a mark, the lines after a
`<br>` in a name, and `ltx_author_notes` contacts other than e-mail, de-duplicated; then each note with content
("<sup>†</sup> Equal contribution…") on its own line. `ltx_role_email` contacts and `mailto:` links are left out.
Math inside is converted as everywhere (the coverage check holds); every source id inside the block is bound to it,
so `href="#id1"` to a note resolves. Without any `ltx_creator` the block is emitted as before. Test: `tests/backend/
arxiv-html.test.ts` ("the authors block reads as names with single marks…"). Rows and cards on the surfaces use the
shared author rules (`apps/web/src/lib/authors.ts`, native `LibraryFormat.shortAuthors` / `authorLine` /
`firstAuthor`): compact "Family, Family, Family +N", full names up to six, "Family et al." bylines.

Later the same night (four more owner screenshots): `ltx_contact_name` labels ("Affiliation:") and `ltx_role_email`
contacts are dropped, e-mail addresses inside affiliation text are removed, a project page (`a[href^=http]` in the
block) goes on its own line, and when no name carries a numeric mark but authors have their own affiliations, the
distinct affiliations are numbered in order of first appearance and each author gets the numbers of theirs
("Chenghao Yue<sup>1</sup>, Hao Wang<sup>2</sup> … <sup>1</sup>Tsinghua University · <sup>2</sup>Dalian
University of Technology"). A name that was a graphic (a team logo followed by " Team") or no name at all is replaced
by the **library's author metadata**, which both apps now pass to the device compiler (`prepare(…, inputs,
{authors})`; native `ArxivHTMLReader.prepare(_:authors:)`, web `prepareArxivReader(…, {authors})`): the names are part
of the bundle, so every device of one library compiles the same bundle, and a library whose metadata differs compiles
a different one (its own manifest digest). Empty emphasis wrappers left by a dropped logo are removed. Checked on
2305.18290, 2610.16334, 2610.14704, 2610.16352 and 2610.17288 (`.artifacts/back-repro/authors-check.mjs`, local).

**Title pages a template left in pieces (2026-10-15, 2610.18356).** LaTeXML marks every macro it does not know with
`ltx_ERROR`; a custom report template can leave the whole title page as one such paragraph before the document title
(logo path, running title, date, author list, "1]Wuhan University" affiliation lines, "[†]Project leader" contribution
notes, and the abstract itself under `\reportabstract`). The compiler now keeps each marker as an empty span naming
its macro (`data-reader-macro`; never printed) and, for a paragraph before the title with two or more markers,
reads it by macro (`templatePreamble`): the segment of a macro whose name contains "abstract" becomes the Abstract
heading and paragraph right after the authors; `contribution`/`thanks`/`footnote` segments become notes with their
marks; lines of the form `1]Institution` become marked affiliations; everything else is left out with the macros
(counted in the closing note). Affiliations with no letter or digit (a template's "[") are dropped, and the
`ltx_dates` line is left out, since the paper line says the year and revision.

### Degradations, not refusals — 2026-10-15 (rethink step 1)

The converter refuses a paper only for safety or size (`arxiv_article` for a page that is only a pointer to the PDF,
the source and bundle limits, duplicate ids, unresolvable references, unsafe MathML). A structure it does not
recognise degrades instead and the paper still opens: a figure in a list item follows the list, a TikZ label holding
a table is a table, a top-level picture is a figure, a tabular of graphics is the figure's panels, a text-only
"equation" is a paragraph, an over-long block is excerpted, a math or icon mark beside a name reads as its symbol or
not at all, a footnote keeps its mark once, empty paragraphs and publication notes under the title are left out.
The header leans on the catalog record both apps pass with the source (`authors`, `title`) to the asset-planning
call and the compile: the catalog title heads a paper without an `h1` (a repeated bold paragraph is dropped), the
library's names head a paper with no author block, and front matter reads first when LaTeXML put a figure or a venue
line before the title. What the HTML left out is said in the paper's closing note. The fresh-paper sweep
(`scripts/reader-sweep.mjs`, TESTING.md) is the gate: 0 of 58 refused on 2026-10-15 against 16 the day before.

Images on the device (2026-10-15, build 42's Apertus refusal): a paper's images share the bundle's pixel budget
(`pixelBudget`: at most 3 million pixels each and 64 million together, so a paper never refuses over its figure
count); a raster the reader's own admission accepts within the budget is kept as it came (the same bytes on every
device); a picture, or a raster over the budget or outside the admission, is drawn scaled and encoded as PNG. A
TikZ picture carries the patterns and symbols LaTeXML defined elsewhere in the page in its own `defs`; a reference
nothing defines is left out. `scripts/reader-device-compile.mjs` exercises this path in a headless browser.

Versions, updates and failure codes on the device: [READER_VERSIONS.md](READER_VERSIONS.md) (build 62).

One figure the device can't prepare is that figure's loss, never the paper's (revision 15, 2026-10-16; build 58
refused ActionOPD 2610.19820 over `svg_id` and InfoVis 2610.16784 over `image_dimensions`). `device-compiler.ts`
`prepare` catches an image's own refusals (`unpreparable`: the SVG admission's `svg_*` codes, `image_dimensions`,
the shared inspector's `image_dimensions_exceeded` and `invalid_image`, `image_decode`, `image_timeout`, an
over-large drawing's `image_limit`, a broken UTF-8 picture, and the browser's `EncodingError`/`SecurityError`/
`InvalidStateError` from decoding) and hands the composer `null` for that URL; the paper's totals (`bundle_limit`,
`image_total_limit`, the image count), its structure and the host's inputs (`arxiv_asset_set`, `base64_limit`) still
refuse. The converter (`arxiv/figures.ts`) puts *"Part of this figure couldn’t be shown here; the PDF has it."* in
place of a lost panel (once for panels side by side, once before the caption for a lost legend symbol), and a figure
left with no image reads as its caption paragraph opened by *"This figure couldn’t be shown here; the PDF has it."*,
the same shape as a figure arXiv's own HTML lost (revision 14), so no figure without an image reaches the index. A
lost image still takes its place in the figure's 16-image allowance, so planning, fetching and placement agree
whatever a device can show. Provenance lists the published images only. Before falling back to the note, two
pictures are now drawn: an id an SVG gives twice is kept on its first element and dropped from the later ones when
nothing refers to it (a fragment, `url(#…)` or a style selector naming it still refuses that picture, as
ambiguous), and a picture over the pixel limit at twice its size is drawn at the largest size the reader allows.
`reader-device-compile.mjs` reports "N not shown" per paper. Tests: `tests/backend/arxiv-unshown-figures.test.ts`
and `apps/web/e2e/arxiv-compiler.spec.ts` (Chromium, WebKit, Firefox).

An image arXiv doesn't serve is that figure's loss too (revision 16, 2026-10-16). The device's download of one
declared image that answers not found or another 4xx, a redirect, a type other than PNG/JPEG/SVG, an empty body or
more than the per-image limit goes to `prepare` as `{url, missing: true}` and reads as the same note; the host still
stops for a 5xx, arXiv busy (429/503) or refusing (403), a lost connection, and the paper's remaining byte budget, so
those are tried again rather than stored with notes. Native: `ArxivHTMLError.assetMissing` in
`ArxivHTMLAcquisition.fetch`, caught per asset in `fetchAssets`; browser: `ArxivReaderError` kind `asset` in
`retrieveArxiv`, caught in `fetchArxivAssets`. Tests: the backend case above, `apps/web/tests/arxiv-reader.test.ts`,
`ArxivHTMLReaderTests.anImageArxivDidntServeIsItsFiguresLossNotThePapers`.

**Native optimized acquisition failure (2026-10-17 UTC; build 64 feedback).** The new per-image `do/catch`
in commit `c603266` exposed a Swift 6.3 optimizer failure: returning `(index, try await acquire(...))` inside
that catchable task returned index **zero for every successful download** under `-O`. Downloads succeeded,
but overwrote `inputs[0]`; the other slots stayed empty and the final guard reported `invalid`. The same code
worked under `-Onone`. This was reproduced with VLA-Δ 2610.21306v1 through native Library acquisition and with
Rubric Judgments 2610.21214v1 from cached official sources; a standalone Swift program reproduces it without
WebKit, networking or app state. A deliberately missing download keeps its correct index through the catch.

The native host now awaits into a local `bytes` first, then returns `(index, bytes)`. The standalone `-O` case
fills all 1/4/10/36 expected slots after this change (before: 1/1/1/1). The authored native regression downloads
ten distinct URLs concurrently, completes out of order and omits one: it fails with the old expression and passes
with the fix, retaining the nine correct captions and the missing-figure note. Earlier authored fixtures used
one unique image, so they could not expose this bug; earlier real-paper native checks used `-Onone`. The explicit
native tier now uses `-O` and whole-module compilation, as the distributed build does. Native guard codes name
their stage (`asset_input_missing`, response/type/resource codes) instead of all reporting `invalid`; no paper
content is included. This changes acquisition, not the deterministic renderer: revision 16 and its bundle identity
remain correct. Before/after evidence: `.artifacts/feedback/20261017-invalid/`; release status in
[implementation status](../IMPLEMENTATION_STATUS.md).

The index lists the paper's captioned tables (revision 16, 2026-10-16; browser parity report: Contents › Tables listed
only tables arXiv published as images, which are figures, so most papers said "No tables"). `reader-index-v1` gains an
optional `tables: [{id, caption}]`, in page order: `id` is a `table` block, `caption` its caption text read as figure
captions are (math as its LaTeX, whitespace collapsed, excerpted to the text bound), at most 512 (`INDEX_TABLES`,
arxiv/tables.ts; the first ones are listed, never a refusal). The caption is the table's own (`p.reader-caption` from
its `figcaption`), else the one the flow found beside it (tables.ts): a table float whose parts became separate blocks
has its captions as paragraphs, paired in order with as many tables (2610.20608's Tables 1 and 2: captions in a row
above tables in a row), or one caption naming the group's first table while its sub-tables aren't listed alone
(2610.19820's Table 1); a caption set in a minipage (`\captionof`, `span.ltx_caption`, 2610.20608's Table 6) is read
from the source. A table without a caption (a layout box, a code listing) isn't listed; an algorithm float is
("Algorithm 1 ActionOPD"). Validators (validate.ts, ReaderBundle.swift, apps/web bundle.ts) accept an index with or
without the list; each entry must name a table block once with a non-empty caption. Earlier bundles, the authored
sample and the device-PDF route have no list, and clients then show only the image tables. Cached papers:
2610.19820 lists 9 (Tables 1–8 and Algorithm 1; the empty front-matter box is left out), 2610.20608 11 of 12 table
blocks, 2610.16784 24 of 25, 2610.18072 17/17, 2606.05868 5/5. Tests: `tests/backend/arxiv-tables-index.test.ts`,
`DeviceReaderTests.indexTablesAreOptionalAndNameTableBlocks`, `apps/web/tests/bundle.test.ts`.

The header: the catalog's title and author names are the ground truth; LaTeXML's author block contributes marks,
affiliations and notes (an author block set as a table reads by rows and cells; several names in one creator split
by their marks), and a custom title page without an author block folds into the header the same way. Affiliations
and notes sit on their own lines under the names (`reader-affiliations`, `reader-notes`).

Colours and citations (build 43): the reader owns its colours, so a source colour or background on math is left
out as the HTML's own colours are; a citation LaTeXML could not resolve (a bold "?") is left out with its
parentheses and counted in the closing note; a macro definition left as a paragraph (TeX parameter tokens) goes.
A copy stored on the device opens at once whichever app compiled it; one compiled by an older app is prepared again
behind the page, and the newer copy is offered with a Reload bar or shown on the next opening.

### Paper availability on a device — 2026-10-15 (owner question: "should we make it more obvious whether you do or do not have a pdf on a device?")

One model, said once. A library paper is in one of four states **on this device**, and every feature that needs the
paper's text reads from the same place:

| State | Means | Reading | Chat, Study, Listen |
|---|---|---|---|
| **On this device** (`PaperDeviceCopy.reader`) | Its official arXiv HTML was prepared here (the verified bundle is installed) | Offline | Have its numbered text |
| **PDF on this device** (`.pdf`) | A PDF file kept here (device-only PDFs; no server processing) | As a PDF, with the PDF's own outline as Contents | Nothing structured yet (the local model is future work); Listen says so |
| **Not on this device yet** (`.cloud`) | In the synced library (a membership, or an older server-processed item) but not prepared here | Opens from arXiv (or the server's copy) when online, then becomes *On this device* | Need the paper opened here first; Listen says "Open this paper first so its text is ready on this device" |
| **No readable copy** (`.unavailable`) | Not converted, quarantined, or source unavailable | — | — |

The Library table now puts device availability (check/cloud) and Authors in separate, selectable columns
(owner follow-up, 2026-10-18); Title does not repeat them below itself. The cloud control still downloads on this
device. Existing saved column choices gain Device/Authors once, then respect subsequent explicit removal. Pending
and completed rows reserve the same title geometry. Other list/card arrangements retain their own metadata.

### Budget at cutover

The incremental ceiling remains $100/month and the metered provider cap remains $25. The live October ledger
before cutover showed $20.744201 spent, $0 reserved and $0 unresolved provider liability. The zero-credit cutover
checks spent $0. This deployment adds no recurring service or subscription; Cloud Run, registry and hosting retain
existing service limits. All eight fixed/overhead components currently lack October observations in the spending
ledger (Tavily, domains, Supabase, Cloud Run, storage/egress, builds/registry, backups and web hosting). Their amounts
are unknown, not zero, and the total-month forecast remains incomplete. No budget was increased.

## Import creation date in Library (build 69 feedback, 2026-10-18; migration 088 deployed)

Source-only memberships use import entries, whose format-2 projection omitted `created_at`; native projection
therefore had no Added date. Add optional top-level `added_at` from the existing immutable import creation time.
Older clients ignore it; new clients accept old entries without it and show an unknown marker rather than a blank.
Do not substitute catalog publication/metadata time or the device's current date. Reproject existing visible import
entries with fresh state sequences under the normal account/library locks, so incremental clients receive the
field without an equal-revision conflict. No new table, PDF processing, data acquisition or legacy migration.
Native/browser wire decoding and offline storage preserve the timestamp; identity checks reject changes to a
known date. Migration 088 is applied on staging. The full database suite and a fresh-schema replay of
`import_metadata.sql` pass, including the final archive-only/custom-keyword distinction. Native projection checks
cover the actual source creation date, explicitly cleared keywords and account retirement.

Revision 20 closes the full-corpus admission regression from the affiliation layout: superscript `\dagger`/
`\ddagger` formulas must stay in the rendered tree with their equation IDs, and inline contact text stays intact.
The three failing real sources (2610.16794v1, 2610.20584v1, 2610.20592v1) pass full device preparation after the
fix; all 123 cached sweep sources have zero failures. Revision 19 was a browser-only checkpoint.

### List markers and diagram labels, revision 23

Build 88 (2610.28711v1's author list, 2610.14162v1's contributions): LaTeXML writes each item's label as text
(`span.ltx_tag_item`; a numbered reference's `ltx_tag_bibitem`) and turns the browser's marker off, so the reader showed
its own bullet beside the paper's, and the item's `div.ltx_para > p` closed with two line breaks (about 90 pt per
one-line name). The paper's label is now the item's one marker, the same `li.reader-custom-marker > span.reader-marker`
vocabulary device-PDF lists use (`arxiv/flow.ts`); a math label reads as its symbol and is accounted, a graphic label is
counted and the list's own marker stands in. An item's (and a description list's) leading and trailing breaks go;
breaks between paragraphs inside an item stay. The bridge hangs the label in the list's indent (right-aligned in
1.5 em; a wider label pushes only its first line) and hides it in a one-item abstract list. Figure 3 of 2610.14162v1
was an adaptation fault, not arXiv's: arXiv's own page shows the step texts (overflowing their boxes, as LaTeXML sized
them); the reader drew every label as one centred line with the `\phantom{Ag}` struts as text. See the TikZ bullet above.

### Heading formulas and bracketed addresses, revision 24

The fresh-paper sweep before TestFlight 90 failed VLA-Δ (2610.21306v1; revision 22 gave the same header). The title
rendered as math on the page, but the index writes every equation as its LaTeX (`outText`, mirrored by the validator's
`domText`), and a heading's index text is its title everywhere: the index title, Contents, equation section labels and
the page's `<title>` read "VLA- \Delta : Learning…". The index format and the validator are unchanged (an installed or
synced bundle must keep validating); instead a formula in a heading that Unicode spells exactly is written as text
(`arxiv/math.ts` `mathAsText`, used by `inline(…, asText)` for `h1`–`h6`): tokens as their characters (a styled
letter through `applyMathVariant`, a one-letter Latin or Greek variable in `<em>`), relations and binary operators
between operands spaced, a sub- or superscript only when every character has a Unicode script form ("τ²", "𝒮₀",
"Sₘᵢₙ"). Anything else (a fraction, "p_T", "π_{0.5}", "r_{novelty}") stays an equation, so its LaTeX is still the index text; 9
of 122 heading formulas in the 174 cached sources are of that kind, none in a title. A text formula is accounted as used,
not an indexed equation. Running text is unchanged.

The author block's "Zhejiang University ()" came from the address rule: every web link in the block moved to its own
line, so a domain LaTeXML kept in brackets left them empty and each of the eight authors added a line. A link with a
bracket on both sides now stays in its affiliation ("Zhejiang University (zju.edu.cn)", as arXiv's page shows it); an
address on its own is listed once per href and text, and none when its words were a dropped icon (2610.19857v1's ORCID
badges left two empty lines). `tidy` removes brackets left empty (or holding only commas) after an e-mail or icon
was dropped; brackets with words stay.

### Encoded image total, revision 21

The real-source native replay of 2610.20592v1 exposed a boundary the Chromium run did not: identical input
assets total 32,747,061 bytes, and Chromium produces a 32,868,722-byte bundle, while WebKit's rasterized PNGs
exceed the existing 32 MiB limit. Keep the source/member/pixel/bundle ceilings. If composition specifically
refuses the encoded bundle size, resample its prepared images with a smaller pixel budget, reserving source
bytes plus 4 MiB for HTML/index/metadata. Preserve original input hashes, every image reference and all
equations; do not drop figures, refetch assets or increase limits. At most three reductions are permitted;
other failures retain their original classification. The exact cached source now passes optimized native WebKit
compilation and independent admission in 13.74 s, retaining 338 blocks, seven figures and 347 equations. The
other three replay papers also pass; five native tests pass and the unrelated opt-in live-download test is
skipped. Evidence: `native-reader-21.xcresult` under
`.artifacts/feedback/all-20261018/`.

## Server adds without duplicates (review A5, 2026-10-21; migration 120, not deployed)

The three server paths that add a paper for the reader (Add by DOI/link/text through `add-paper`, a reference's Add to
library through `add-reference`, and chat Ingest) shared `find-paper.ts importPaper`. It paged the oldest 300 library
entries and treated a paper as present only as an `item` or an import in `accepted/resolving/acquiring`. Since the
HTML-first cutover a finished arXiv import rests in `source_only`, so re-adding a paper the reader already has (or a
retried request) created another import and another visible membership. Each call also minted a fresh operation UUID,
so a retried request was never recognised, and each duplicate used up the lifetime per-account and environment
import allowances.

Design (additive; existing client commands unchanged):

- **One authenticated RPC, `v2_add_paper_once(p_operation_id, p_source_id, p_web)`**, called with the reader's own
  token (like `v2_begin_import`). It takes the same rate rule (`library-write`) and the same locks in the same order:
  account, then library policy and the account's sync state. It replays an earlier receipt for the operation UUID
  first. It then decides presence under those locks, so two concurrent adds of one paper cannot both insert:
  - an import of that source that is `desired_present` in `accepted`, `resolving`, `acquiring` or `source_only` (the
    visible, not-failed memberships), or
  - a visible library item (`removed_at is null`) whose approval's catalog metadata names that source.

  Present returns `{status:'present', kind, id}` with the current entry. It writes no receipt and no change, and uses
  no import, active-import or receipt capacity, so asking again later (for example after the reader removed the paper)
  starts a real import. A failed, cancelled or conflicting import is not present: Add after a failure starts a new
  attempt, as the app's own Add does. Otherwise it inserts exactly what `v2_begin_import`/`v2_begin_web_import` insert,
  with the same capacity checks. The observed cursor is the account's current sequence, read under the lock: the
  server has seen the whole library. It writes the receipt under its own digest (`server-add-v1`, web flag, source),
  so it can never be confused with a client's `v2_begin_import` receipt.
- **A retry-stable operation UUID.** The caller derives it from its own request identity: the add-paper or
  add-reference `operation_id`, or the chat operation for Ingest. It is the SHA-256 of a domain-separated tuple
  (request id, kind, source id), shaped as a UUID. A retried request therefore replays its receipt (`added` again)
  instead of queuing another import. Without a request identity (no current caller) a random UUID is used.
- **Index.** `import_requests(account_id, source_id) where desired_present` keeps the presence check off a scan of the
  account's import history.
- **Unchanged.** `v2_begin_import`, `v2_begin_web_import` and the v5 wrappers keep their contracts. The browser still
  calls `v2_begin_import` directly for arXiv IDs with a fresh UUID (`apps/web/src/lib/add.ts`); moving it to this RPC is a
  separate client change. The lifetime import counters themselves are not changed here; migration 0142 (2026-10-21)
  removed them ([no import quota](LIBRARY_CAPACITY.md#no-import-quota-2026-10-21)).

Evidence: `tests/database/server_add_once.sql` (presence by import phase and by item, replay, capacity untouched,
another account, web sources, grants) and `tests/backend/add-paper.test.ts` (derived identity, outcome mapping).
Deploy order: apply migration 120, then deploy `add-paper`, `add-reference` and `chat` (the functions call the new RPC
and report `failed` until it exists). Live check: on staging, add the same arXiv ID twice through Add › "arXiv ID, DOI
or link" with a DOI that names it (or Add to library on a reference twice); the second answers "already in your
library" and `import_requests` gains one row, not two.

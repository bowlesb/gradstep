# Reader renderer (`timestep-mathpix-mathml-v1`)

Current direction, 2026-10-13: retain this renderer/profile for historical verified bundles; new preparation uses
the [arXiv HTML adapter](HTML_FIRST_READER.md#html-to-bundle-adapter). It keeps `reader-bundle-v1`/`reader-index-v1`
and the bridge but adds `gradstep-arxiv-html-mathml-v1` / `arxiv-html` with honest HTML provenance and independent
validation in each client. HTML must never be mislabeled as Mathpix output. The adapter is implemented and verified on native and browser clients. No new PDF/OCR work is authorized by the historical implementation description below.

Status, 2026-10-05: deployed in the `paper-worker` Edge Function on staging; real conversions (DPO, LoRA, Mamba, Mistral, Adam, PPO) render, validate and open in the Simulator journey.

## Shape

`supabase/functions/_shared/reader/` turns Mathpix's `mmd.zip` (expanded by `unpackReaderZip`) into a `reader-bundle-v1` bundle. It uses only `markdown-it@9.1.0`, `mathpix-markdown-it@3.0.1`, `htmlparser2@12.0.0`, `node:zlib` and `node:crypto` — no child processes, filesystem reads, network or SVG.

- `renderMathpixReader({archive, provenance, attribution?, titleFallback?})` → `{manifestBytes, manifestSHA256, members, index, stats}`. Exactly one `*.mmd` in the archive is the source; figures resolve relative to it.
- `renderRetainedMathpixResult(MathpixRenderInput)` revalidates a retained raw capture and takes provenance from its manifest.
- `validateReaderBundle(manifestBytes, members, expectedSHA256)` is a pure, rejecting check of a whole bundle; the producer runs it before returning.
- `scripts/render-mathpix-reader.ts` renders a retained capture into a content-addressed directory.

Math: each Mathpix math token is replaced by a placeholder during rendering, then emitted as sanitized MathML (`<math display="block">` for display) inside `span.reader-equation[data-reader-equation][data-latex]`. WebKit lays out MathML natively, so equations scale with Dynamic Type. Styled letters become Unicode math alphanumerics; a single `\tag` is shown beside the equation. TeX errors or unsupported MathML fall back to visible LaTeX (`reader-math-fallback`) with the same index entry. Copy uses the index LaTeX and `source_form` exactly as before.

Blocks: every top-level node is a block (`p`, `h1`–`h6`, `figure`, `div.reader-table`, `pre`), a list whose items are blocks, or `hr`; blocks never nest and no prose sits outside a block. IDs are `b-<sha12>-N` / `e-<sha12>-N` from the MMD hash. Figures are `<figure data-reader-figure>` with `img`s and an optional `figcaption`; alt text falls back to the caption's first sentence.

Reading flow: before rendering, `flow.ts` joins a paragraph that Mathpix split at an explicit `\pagebreak` when
the first half stops mid-sentence and the second starts in lower case; page footnotes and figures/tables found
between the halves keep their order and move after the joined paragraph. Only that marker is used (column breaks,
display-math continuations and complete sentences are untouched). On six real papers this removed every
page-break split (3–5 per paper) with identical equation and figure counts. `RENDERER_REVISION` is 2 from this
change (manifests record the new build hash). Staging conversions made before it are disposable test data (owner,
2026-10-05): no re-render path is needed for them.

Device presentation (`reader-bridge.js`, applied to every bundle version without changing content): per-cell
`columnalign` (WebKit ignores it on `mtable`/`mtr`, which centered aligned derivations), equation numbers pinned
visible while a wide equation scrolls, display/inline math scaled to the column when within 75% (otherwise it
scrolls in its own box; the page never scrolls sideways) and edge shadows on scrollable equations and tables.
At iPhone width this fixed page-level sideways scrolling on 4 of 6 real papers; at iPad width every equation fits.

Citations and references (owner feedback on build 11, 2026-10-06; same bridge, no re-render): the bibliography is
the section under a "References"/"Bibliography"/"Works Cited" heading — `ul.reader-references` items, or paragraphs
with one entry per line. Entries are keyed by `[n]`/`n.` (or `ol` position), by label (`[Bel+15]`), or by first
author surname + year; each gets `data-sr-reference="ref-<key>"` (block IDs are untouched — they are the selection
and position identity). In-text citations become `span.sr-cite[role=link]` wrappers around existing text: numbered
`[16]`, `[3, 5]`, `[1–4]` when every number is in the bibliography, labelled keys likewise, and author–year
citations when exactly one entry fits (below). Math, code, links, headings and the bibliography itself are skipped;
every block's text is unchanged. A tap scrolls to the
entry (smooth unless Reduce Motion), highlights it briefly and shows a native Back that returns to the block-relative
place left; Back disappears on return (by Back or by scrolling there), after scrolling two screens away (one before
build 21's feedback), or on a Contents jump. While Back is shown the saved reading position stays at the place left.
Tapping an entry offers, without a title row (build 21), Open (arXiv ID, then DOI, then an `https` link), Discuss in
chat (this paper's chat with `About “<entry>”: ` in the message box, focused, unsent — Quote in Chat's wording; a new
conversation unless the paper's current chat is still empty), Add to library (the `add-reference` call) and Copy.

Author–year citations (owner feedback 2026-10-07: "Stadter et al, 2021" did not link; same bridge, no re-render).
The matching is a pure section of `reader-bridge.js` (`CitationMatcher`, between `BEGIN/END CITATION MATCHER`)
that `scripts/citation-harness.mjs` evaluates unchanged in Node.

- **Entries** are parsed once into authors (surname words folded — lower case, diacritics removed — with the last
  word as key), years with suffix letters (an arXiv ID's year when none is printed) and whether the list ends in
  "et al.". Formats: "Ashish Vaswani, Noam Shazeer, and …", "Vaswani, A., Shazeer, N., and …", "Duchi, John, Hazan,
  Elad, …", "Smith JA, Doe B", "P.Städter, Y. Schälte" (missing space), particles ("Aäron van den Oord",
  "van der Maaten, L."), multi-word surnames ("Erik F. Tjong Kim Sang"), groups ("BIG-bench collaboration") and
  organisations ("OpenAI", "XLA"). The list ends at the first stop after a word (not an initial), a quote, a year or
  "In:". A bibliography paragraph line starting with a lower-case particle and a surname ("de Freitas, N., …") is a
  new entry, and a paragraph that starts an appendix ("Appendix", "B Experiment details", no year) ends the
  bibliography (ViT's appendix had been swallowed, hiding its citations).
- **Citations** are found per block over the block's whole text (text nodes joined; skipped elements, cell and item
  boundaries become U+2063), so one split by `<em>` or a `<br>` still links — in pieces, one focus stop. Each year
  is read backwards for the names before it: parenthetical and bracketed `(Stadter et al, 2021)`,
  `[Krizhevsky et al., 2012]`, `(Gu, Goel, and Ré 2022)`, `(Kingma & Ba, 2015)`, narrative `Stadter et al. (2021)`,
  `van der Maaten and Hinton (2008)`, `Y. Li et al. 2023`, "et al" with or without period or comma, semicolon and
  comma lists, and further years of the same names (`(Peters et al., 2017, 2018a)`, `(Wu et al., 2022a,b)`,
  `(Radford et al., 2018; 2019)`), each pair its own link; a lone year or letter carries an `aria-label` with the
  names. A year counts only inside brackets, directly after the names in brackets, or after "et al.".
- **Resolution**: first author by the longest matching end of the cited name ("Following Vaswani" → Vaswani), the
  year, later cited names in order; then, among several, the cited names in their places, the author count (one name
  without "et al." is the one-author entry; "et al." prefers three or more), initials ("J. Ba" is Jimmy Ba, not Jimmy
  Lei Ba), the suffix letter (or entry order when the bibliography prints no letters), and one copy of a duplicated
  entry. A leading word that is no known author is dropped ("BiRNN, Schuster and Paliwal"). Still several → no link.
- **Look**: author–year links use the numbered links' color; on touch screens (`hover: none`) every citation link has
  a faint underline (1 px, 40% of the link color). Tap, Back and the reference actions are unchanged.

Measurement (`node scripts/citation-harness.mjs`, headless WebKit, 22 papers: 12 from the retained `.artifacts/bundles`
and 10 author–year or unusual ones downloaded read-only from staging `paper-assets/reader/` — `091b956f`, `2821790`,
`32198d5`, `40637fd`, `a144b53`, `a5be95c`, `be18585`, `c64887c`, `37ec638`, `264dd07`, manifest hashes verified — into
`.artifacts/cite-bundles/staging/`; ground truth is an independent oracle: each year's preceding words against each
entry's first author and year). Unambiguous author–year citations linked to the expected entry:

| Paper | Unambiguous | Before | After |
|---|---:|---:|---:|
| Mamba | 228 | 216 (94.7%) | 228 (100%) |
| ViT (An Image is Worth 16x16 Words) | 99 | 82 (94.3%) | 99 (100%) |
| LoRA | 129 | 128 (99.2%) | 129 (100%) |
| BERT | 96 | 92 (95.8%) | 96 (100%) |
| Chain-of-Thought Prompting | 145 | 139 (95.9%) | 145 (100%) |
| PaLM | 366 | 349 (95.4%) | 366 (100%) |
| Neural Machine Translation (Bahdanau) | 59 | 51 (86.4%) | 59 (100%) |
| TimeSformer | 111 | 108 | 110 (99.1%) |
| Dropout | 70 | 65 (92.9%) | 70 (100%) |
| Layer Normalization (`[Name et al., 2012]`) | 56 | 0 (0%) | 54 (96.4%) |
| Training Numerical Intelligence ("Städter et al., 2021") | 89 | 40 (44.9%) | 89 (100%) |
| Attention, Adam, Motion Tokenizers, Batch Norm | 123 | 123 (100%) | 123 (100%) |
| **All** | **1,571** | **1,393 (89.5%)** | **1,568 (99.8%)** |

No wrong link against the oracle; 28 of the 29 citations the oracle could not decide link correctly by author count,
position or initials (the one left, "Luong et al. (2015)" in Attention's table, fits two three-author entries). The
three misses are an OCR'd "[Amari] 1998]" and "|2016|" and a "2019a" the bibliography prints as "2019b". A manual check
of 30 random author–year links (seed 7) found 30 correct. Numbered and labelled papers keep exactly their links
(DDPM 112, PPO 28, Scaling Laws 38, Mistral 29, DPO 91); all links 1,791 → 1,987; no block text changed; slowest paper
(PaLM) ready in under 0.3 s.

Spot check (`--sample=30 --seed=7`, each read against the sentence and the entry; all correct): PaLM — Du et al.,
2021 → GLaM (twice); Patterson et al., 2021 → carbon emissions; Jouppi et al., 2020 → TPU v4 supercomputer; Lee et al.,
2021 → deduplicating training data; Vaswani et al., 2017 → Attention (twice); Austin et al. (2021) → program synthesis;
Chen et al., 2021 → Codex. Mamba — Hendrycks and Gimpel 2016 → GELUs; Ivanov et al. 2021 → data movement; Hoffmann
et al. 2022 → Chinchilla. CoT — Lan et al. (2021) → MWPToolkit; Marasović et al., 2022 → few-shot self-rationalization;
Ling et al., 2017 → program induction; Rajagopal et al., 2021 → SelfExplain. BERT — Dai and Le, 2015 → semi-supervised
sequence learning; Clark et al., 2018 → cross-view training (not Clark & Gardner 2018); Peters et al., 2018a → ELMo.
TimeSformer — Radford et al., 2019 → GPT-2; Fan et al., 2019 → bLVNet; Stroud et al., 2020 → D3D. Training Numerical
Intelligence — Gandhi et al., 2025 → ResearchCodeAgent. Bahdanau — Hochreiter and Schmidhuber (1997) → LSTM; Forcada and
Neco, 1997 → hetero-associative memories. LoRA — Lester et al., 2021 → prompt tuning; Jaderberg et al., 2014 → low-rank
expansions. Batch Norm — Srivastava et al., 2014 → Dropout. ViT — Wang et al., 2019 → deep Transformers for MT;
Wang et al., 2020a → Axial-DeepLab.

Tests: `PaperWebViewTests` — `testAuthorYearFormsLinkEachNameAndYear` (a synthetic page with every form above, the
split and caption cases, focus stops, labels, color, touch underline, a tap on "b" and Back) and
`testAuthorYearCitationsLinkOnlyOnAnUnambiguousMatch`; `testAuthorYearCitationScreenshots` captures a real bundle
light/dark before and after a jump when `TEST_RUNNER_SCIENCE_READER_CITATION_BUNDLE` is set (skipped otherwise).
2026-10-07, iOS 26.4 Simulators: all citation tests and `ReaderNavigationTests` pass on iPhone and iPad; on iPad two
older tests (`testContentsPreserveArtifactAnchorsAndUseThemForNavigation`, 38 pt off;
`testInvalidDOMAndUnlistedImagesFailThenFreshVerifiedBundleLoads`, load timeout) fail the same way without this change.

Bracketed citations without a comma (owner feedback on build 14, 2026-10-07: `[Gelfond and Lifschitz 1991]`,
`[Lobo et al. 1992; Eiter et al. 1997b]` in "The DLV System for Knowledge Representation and Reasoning" did not link).
Build 14 was archived at 22:45 on 2026-10-06 with the numbered-only bridge (`d7e8040`); the author–year matcher above
already handles ACM's form, so the fix reaches the owner with the next build. Measured on that paper (staging bundle
`c270ada8`, downloaded read-only, manifest hash verified, now in the harness's default set — 23 papers): unambiguous
author–year citations linked 3 of 209 (1.4%) with build 14's bridge → 210 of 210 (100%), no wrong link; every one of
the 258 unambiguous bracketed citations in the set links (`[Name 1991a; 1991b]`, `[Name, Name, and Name 1991]`,
`Name and Name [1991]`). Not linked, correctly: `[Cadoli et al. 1997]` (two three-author Cadoli 1997 entries) and
`[… Baral 2002]` (the bibliography has Baral 2003). Added for small capitals as OCR prints them: "AND"/"And" between
names and "ET AL." in citations, "And"/"AND" between authors in entries ("Leone, N., And Pfeifer, G.", two DLV
entries) and two-letter capital surnames (`[LI AND WU 2020]`). Every link span is identical to the previous bridge's
on all 39 distinct local papers (none of them prints capitals). Harness totals: 23 papers, 1,778 of 1,781
unambiguous (99.8%), 0 wrong, no block text changed; build 14's bridge on the same set: 1,396 (79.0%), 1 wrong.

Hyphenated and accented surnames (owner feedback on build 21, 2026-10-08: "Brafman ref missed" in "Knows what it
knows", Li, Littman, Walsh and Strehl, Machine Learning 2011; staging bundle `07e8979c6769`). Mathpix joins a word
broken at a line end and keeps the hyphen, so the text read "(…; Brafman and Ten-nenholtz 2002; …)" against the entry
"Brafman, R. I., & Tennenholtz, M. (2002)". Surname keys on both sides now drop every hyphen (ASCII, U+2010/2011, soft
U+00AD) and fold spacing accents OCR prints ("Ce´sar"), letters NFKD keeps whole (ø, ł, æ, œ, ß, đ, ı, þ) and
combining marks; a word broken by a hyphen and a space or line break ("Ten- nenholtz", "Ten-<br>nenholtz", not before
"and"/"et") is one word in citations and in entries ("Wiewio- ra, E."). Measured with `node scripts/citation-harness.mjs`
on every staging conversion (64 bundles, downloaded read-only with manifest and member hashes checked, plus the 13
retained local bundles; 55 distinct titles): unambiguous author–year citations linked 2,578 → 2,579 of 2,603 (99.0% →
99.1%), 0 wrong, and exactly one link span changed across 9,354 blocks — the owner's Brafman citation (KWIK 106 → 107
of 107). The 24 still missed are organisation authors ("U.S. Bureau of Labor Statistics", 18 in one paper), OCR damage
("[Amari] 1998]", "|2016|") and years the bibliography doesn't print. Tests: `tests/backend/reader-bridge-matchers.test.ts`
(Node, the matcher section unchanged) and `PaperWebViewTests.testHyphenatedAndAccentedAuthorYearCitationsLink`.

## Figure, table and algorithm references

Owner feedback on build 21 (2026-10-08): "When figures are referenced you should be able to link directly to them …
And there should also be a 'return to reading location' option in a sensible location". Same bridge, no re-render.

- **Targets** are read from what the paper prints, never guessed: a pure section of `reader-bridge.js`
  (`FigureReferences`, between `BEGIN/END FIGURE REFERENCES`) reads a caption's label — "Figure 3:", "Fig. 2.",
  "FIGURE 12a |", "Figure A. 1:", "Table 1 Parameter counts", "TABLE II", "Algorithm 1 Training" (a following word in
  lower case is prose: "Table 5 lists …") — from `figure` captions (or the index caption), `.reader-table` captions and
  the first line of a code block (Mathpix prints algorithms as `pre`). The kind comes from the label's word, not the
  element (Mathpix prints some tables as images and some figures as tables). A caption kept as its own paragraph
  ("Table 6: …", needs ":", "." or "|") names its one unlabelled neighbouring figure/table/code block, else itself. A
  second label after a colon inside a caption counts when nothing else carries it (DDPM's "Figure 3: … Figure 4: …").
  A label two different elements print (restarted supplementary numbering, two "Table 4"s) links nowhere; the same
  caption printed twice is one target.
- **References**: "Fig. 1", "Figure 3(b)", "Figs. 2 and 3", "Figures 2, 3, and 5" (comma lists only after a plural),
  "Tables 7–10" (both ends), "Figure 2 or 3", "Algorithm 1", "Table II", "Figure S3", "Fig. A.1", "figure 5"; each
  number is its own `span.sr-cite.sr-figref[data-sr-figure][role=link]` with an `aria-label` ("Figure 3(b)"),
  citation colour and touch underline. A caption never links to itself; headings, code, math, links and bibliography
  entries are skipped (text the bibliography's walk took in after the references, such as an appendix without its own
  heading, is still read). Block text is unchanged.
- **Tap**: a figure, table or algorithm posts `{type:'figureref', manifest_sha256, id, label}`; the app shows it on its
  own (the figure view, which now also takes a table or code block of the bundle) in a half-height sheet titled by
  the label, with **Go to figure / table / algorithm**, which calls `__scienceReaderShowFigure(id, reduced, true)`: the
  element is centered and flashed, Back returns to the reference and flashes it. A caption paragraph with nothing to
  show is gone to directly with Back.
- **Back** ("Back to where you were", owner feedback build 21) is the one Back for every jump: citations, figures,
  the paper's own contents rows, Show in paper and Go to passage. It sits at the left of the A− / A+ row, its right
  edge kept clear of that control, above the tab bar ("Back" alone when the words don't fit). It now lasts until the
  reader goes back, scrolls **two** screens from where the jump landed (was one), or scrolls back to the place left by
  hand (then they have returned). The app's Contents sheet still ends it, as before.

Measured (`node scripts/citation-harness.mjs`, same 55 papers; the harness checks every link's target independently:
its caption — or, for a caption paragraph's neighbour, that paragraph — must print the link's label): 1,236 of 1,291
references found are linked (95.7%), 1,244 links in 53 papers, **0** whose target doesn't print the label; 30 random
links read by hand (seed 7) all correct. Not linked, correctly: figures whose caption Mathpix lost (MLLMs' Figures 2–3,
DDPM's Table 2), restarted supplementary numbering (Neural Spline Fields' Figures 1–10), PaLM's Tables 38–43 (beyond the
80-page OCR cap), a number inside math ("Figure 13S5"), OCR's "Tables 46". The KWIK paper: 20 of 20, including the
owner's "Fig. 1". Bridge ready time unchanged within noise (slowest paper 205 ms). Tests: the Node test above,
`PaperWebViewTests` (`testFigureTableAndAlgorithmReferencesLinkOnlyToTheirLabelledElement`,
`testFigureReferenceInABundleShowsItsElementAndGoesThereWithBack`, `testFigureReferenceMessagesNameTheBundlesOwnFiguresTablesOrCode`,
Back's two screens in `testCitationJumpsToItsReferenceAndBackReturnsToTheExactPlace`) and the iPhone journeys in
`ReaderNavigationTests` (`testReferenceActionsHaveNoTitleAndDiscussInChatQuotesTheEntry`,
`testFigureReferenceShowsTheFigureAndGoToFigureReturnsWithBack`, each light and dark, Back checked clear of A− / A+ and
the tab bar). 2026-10-08, iOS 26.4 iPhone 17 Pro Simulator: `PaperWebViewTests` + `ChatGenerationTests` 48 passed, 2
skipped (environment-gated screenshot tests), 1 page-load timeout (`testContentsPreserveArtifactAnchorsAndUseThemForNavigation`)
that passes alone; the KWIK screenshot test (`TEST_RUNNER_SCIENCE_READER_CITATION_BUNDLE`, text "Ten-nenholtz") passes
and was checked by eye light and dark; `ReaderNavigationTests`, `PaperToolsTests` and `PassageJourneyTests` pass on
iPhone (iPad-only cases skipped), with `testFindInPaperGoesToAMatchAndKeepsThatReadingPlace` passing alone after one
keyboard-timing failure in the full run; Node 6/6; the Mac Catalyst build compiles (not run).

**Browser reader hooks (for the web owner, Codex; not built here).** The browser frame loads this bridge unchanged, so
figure links already appear there and a caption-paragraph target already jumps with the existing Back. Still needed in
`apps/web`: (1) `readFrameMessage` should accept `{type:'figureref', manifest_sha256, id, label}` (id a figure, or a
table/code block of the index; label `^(Figure|Table|Algorithm) [A-Z0-9][A-Za-z0-9.]{0,9}$`) and show that element —
`frameDocument(bundle, {figureID: id})` now renders a table or code block on its own too — with a "Go to figure" that
sends a frame command calling `__scienceReaderShowFigure(id, reduced, true)` (the shim's `showFigure` passes only the
id, which the gallery's Show in paper still uses); (2) reference actions (`{type:'reference'}` with `text`, `links`)
could offer "Discuss in chat": open the paper's chat and prefill the composer with `About “<entry text>”: `, unsent,
focused (the native wording of Quote in Chat); (3) the Back button could read "Back to where you were".

## The paper's own contents

Owner feedback on build 14 (2026-10-07): a paper's printed table of contents ("Contents 1 Introduction ..... 1 2 Core
Language ..... 3 2.1 Syntax ..... 3 …") rendered as one run-on paragraph — Mathpix keeps it as one `<p>` whose lines
are newlines, which HTML collapses. Same bridge, no re-render: existing bundles are fixed.

- **Detection** is a pure section of `reader-bridge.js` (`ContentsParser`, between `BEGIN/END CONTENTS PARSER`) over
  a paragraph block's own children (text, `<br>`, whole inline elements such as an equation). A block becomes a list
  only when all of its text is entries, after an optional caption line ("Contents", "Table of Contents", "List of
  Figures/Tables/…"): with dot leaders (".....", ". . .", "…", "·····") and a page (arabic or lower-case roman), at
  least three entries, one per line (a wrapped title may take two lines) or run together, pages mostly running
  forwards; without leaders ("1 Introduction 1"), only after a contents caption (in the block or the heading just
  before it), at least four entries, section numbers in reading order (next sibling, first child, next of an
  ancestor, letters for appendices) and pages never going back. Bibliography, author and abstract blocks, figures,
  tables and list items are never considered.
- **Presentation** wraps the block's own text in spans: one entry per line (flex), indented by depth (`2.1` one
  step, `3.1.1` two), top-level entries semibold when the list is nested, the dot leader drawn as a faint dotted
  rule (its dots stay in the text at font size 0, hidden from VoiceOver), the page right-aligned, muted and tabular.
  The block's text, IDs, equations and selections are unchanged (a selection still quotes the dots); the app's
  Contents sheet is unchanged; citation linking skips these blocks.
- **Links**: an entry whose number and title match a heading ("1 Introduction" ↔ "1. INTRODUCTION"; same number and
  most words; an unnumbered entry by title alone) — or, for a numbered subsection with no heading, the one line in the
  paper starting with that number and title and a stop (ACM run-in heads, "3.3.1 Exams Scheduling. Let us…") —
  becomes `role=link` in the citation color with an `aria-label` ("2.1 Syntax, page 3"). A tap or Return goes there
  (heading at the top, as a Contents jump; smooth unless Reduce Motion), highlights it briefly and offers the citation
  Back, which returns to the list. Lists of figures and tables are formatted but never linked. No match → plain row.

Measurement (`node scripts/citation-harness.mjs`, which now reports every formatted block, its links and any link
whose target disagrees with the entry): the 23 default papers plus the other 25 staging conversions (downloaded
read-only into `.artifacts/toc-bundles/`, `--all-titles`, 48 in all) — 5 lists formatted in 3 papers, exactly the
real ones: DLV contents (40 entries, 35 linked: 22 headings, 13 run-in heads; the rest have no heading in the
conversion or a title with an equation), PaLM contents (44, 39 linked; the conversion has no G.3/H headings), Scaling
Laws contents (13/13) and its lists of figures (24) and tables (6). No other block changed, no block text changed, no
disagreeing link; bridge ready times unchanged within noise (DLV median 93 → 122 ms).

Tests (`PaperWebViewTests`): `testPaperContentsBecomeAListThatJumpsToItsSections` (leader, plain-line and run-together
lists; prose with leaders, a numbered list without caption, out-of-order numbers and mixed prose left alone; depth,
alignment, muted pages, labels, a tap to a heading with Back, Return to a run-in head),
`testPaperContentsInABundleKeepSelectionsAndContents` (the sample bundle with a contents block: links, the app's
Contents, a selection quoting the exact text) and `testBracketedAuthorYearCitationsWithoutACommaLink`;
`testPaperContentsScreenshots` captures a real bundle light/dark when `TEST_RUNNER_SCIENCE_READER_CONTENTS_BUNDLE`
is set (skipped otherwise; `TEST_RUNNER_SCIENCE_READER_SHOTS` also writes the PNGs to a folder). 2026-10-07, iOS 26.4
iPhone 17 Pro Simulator: `PaperWebViewTests` 21 run, 20 passed, 1 skipped (`testAuthorYearCitationScreenshots`, no
bundle set), with `testPaperContentsScreenshots` run on the DLV bundle — the list light and dark, a run-in head reached
from it, and `[… Gelfond and Lifschitz 1991; …]` linked — checked by eye; `ReaderNavigationTests` (UI) 3 passed,
1 skipped (iPad only). A first run on the freshly booted Simulator timed out loading three older tests' pages; all
passed on the next two runs.

Publication line: native passes `year · venue · source` (`Paper.publicationLine`) and the bridge inserts it after the
authors (or the title) as a `data-sr-chrome` element before the first layout. It is `user-select: none`, outside every
block, and skipped by selections, so anchors, quotes and positions are unaffected. The bundled sample shows none.

## Contents outline, find and Show in paper

Reader navigation pass (2026-10-07, [decision](../DECISIONS.md#reader-navigation-find-contents-levels-figures-ipad-chat-column-owner-asked-2026-10-07-agent-decisions-reversible));
same bridge, no re-render.

- **Contents outline** is a pure section of `reader-bridge.js` (`ContentsOutline`, between `BEGIN/END CONTENTS
  OUTLINE`): headings in, `{id, title, level, depth}` out for the app's Contents sheet. Title, "Abstract" and a printed
  "Contents" heading are dropped; depth is the level's distance from the shallowest shown, or — when one level holds a
  section and its own subsection ("A" and "A. 1"; with Roman sections, a numeral and a letter) — the depth the section
  number gives. DPO: 39 entries, "5.1"/"6.1" one step in (h3), "A. 1"–"D. 3" one step in by number (flattened to h2).
- **Find** is WebKit's own (`isFindInteractionEnabled` on the paper's web view only). It highlights without a DOM
  selection, so the bridge's selection handling and block text are untouched.
- **Show in paper** (`window.__scienceReaderShowFigure(id)`, its own section after the figure handlers) reuses the
  citation jump: the figure is centered (from the top when taller than the page) and flashed, and Back returns to the
  place left; positions are not reported while Back is offered.

Tests (`PaperWebViewTests`): `testContentsIndentByLevelAndSkipAbstractAndPrintedContents`,
`testContentsInferDepthFromNumberingWhereLevelsWereFlattened`, `testContentsOfARealConversionNestAppendixSections`,
`testGalleryFiguresReadTheirNumberAndCaption`, `testShowFigureCentersItHighlightsItAndBackReturns`; UI tests in
`PaperToolsTests`. The 2026-10-07 takeover ran them after a clean merge with offline-save and passage support:
Contents levels and actual DPO indentation, find/close/chat-return reading position, and gallery/Show in paper/Back
pass on iPhone (light and dark figure screenshots reviewed). The earlier figure-sheet and touch-selection journeys
also pass. Contents assertions use accessible levels rather than full-row button frames; find assertions allow the
wrapping match's earlier lines above the viewport while its last, matching line remains visible.

## Sanitization

Provider HTML is rebuilt from an allowlist, never passed through. Scripts, styles, SVG, forms, embeds and Mathpix sidecars are dropped with their content; other unknown elements are unwrapped; all provider attributes except table spans are discarded. Links survive only as normalized `https:` URLs with `rel="noopener noreferrer"` or fragments resolved to generated IDs; everything else keeps only its text. `PaperView` already opens activated `https:` links in Safari and allows only same-document fragment navigation. The validator then requires an exact skeleton (CSP, no scripts), a parse/serialize fixed point, HTML5-stable content models, allowlisted tags/attributes/classes, member-backed images and full DOM/index agreement.

TeX macro definitions (`\newcommand`, `\def`, `\let`, …) are refused: MathJax keeps them in module state that would leak between documents in a reused isolate. Provider parser logging is muted during the synchronous render.

## Images

Only referenced archive images are admitted. JPEG: one 8-bit baseline/extended/progressive Huffman frame, 1 or 3 components, complete scans, EOI last; APP0/ICC/Adobe kept, EXIF/XMP/comments removed. PNG: 8-bit RGB/RGBA non-interlaced, CRCs checked, zlib extent and filter bytes verified, ancillary chunks removed, IDAT re-chunked without recompression. Published paths are `assets/<sha256>.jpg|png` of the canonical bytes. Natively, `ReaderJPEGValidator` (Core) or `ReaderPNGValidator` runs before a forced ImageIO decode.

## Provenance and limits

`provenance.json` is canonical JSON `mathpix-reader-provenance-v2`: `ocr {api, profile, options_sha256}`, `provider_job_id`, `document {sha256, page_count}`, `source {archive_path, bytes, sha256}`, `renderer {id, build_sha256}`, sorted `image_inputs [{archive_path, input_sha256, published_path, published_sha256, media_type, width, height}]`. `NOTICE.txt` carries third-party notices plus an optional document attribution. `build_sha256` hashes the profile (revision, packages, options, limits, CSP, CSS, notices); bump `RENDERER_REVISION` whenever output can change.

| Limit | Value | Limit | Value |
|---|---|---|---|
| MMD source | 2 MiB | Equations | 4,000 |
| Figures / images per figure | 256 / 16 | Blocks / headings | 20,000 / 1,000 |
| Bundle / member | 32 / 16 MiB | HTML / index | 8 / 4 MiB |
| Image | 8,192 px side, 16 M px | All images | 64 M px |

Native `ReaderProfile` applies these to this renderer only; the authored `timestep-mmd-v1` sample keeps its original limits and PNG-only images. The synthetic `timestep-mathpix-mmd-v1` pilot and its fixture were removed.

## Measurements (DPO: 116 KB MMD, 270 equations, 4 JPEG figures)

| Runtime | Module load | Render + validate (wall) | Process CPU | Heap after render |
|---|---|---|---|---|
| Deno 2.9.6 | ~350 ms CPU | ~300 ms | ~470 ms | 72–86 MB |
| Node 24.18 | ~420 ms CPU | ~340 ms | ~550 ms | 77–84 MB |

Process CPU includes V8 background threads; both runs also pass under a 150 MB heap cap. Node and Deno produce byte-identical bundles. The DPO bundle is 767 KB (HTML 262 KB, index 181 KB, four JPEGs 303 KB). A synthetic 1.36 MB source (DPO ×12, 3,240 equations) took 1.7 s wall / 2.7 s process CPU and 136 MB heap, so sources near the 2 MiB cap may exceed the Edge CPU budget. Deployment size is unmeasured: the npm graph is large (`deno info` reports 122 MB of package files) and may need pre-bundling.

The committed app fixture `ReaderSamples/cd902bcd…` is this renderer's output for the DPO capture, with CC BY 4.0 attribution in its `NOTICE.txt`; `tests/backend/reader-render.test.ts` checks it byte-for-byte when the capture is present locally.

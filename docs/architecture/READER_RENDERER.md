# Reader renderer (`timestep-mathpix-mathml-v1`)

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
place left; Back disappears on return, after scrolling a screen away, or on a Contents jump. While Back is shown the
saved reading position stays at the place left. Tapping an entry offers Open (arXiv ID, then DOI, then an `https`
link), Add to library (the Ingest action with the entry as the passage) and Copy.

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

Publication line: native passes `year · venue · source` (`Paper.publicationLine`) and the bridge inserts it after the
authors (or the title) as a `data-sr-chrome` element before the first layout. It is `user-select: none`, outside every
block, and skipped by selections, so anchors, quotes and positions are unaffected. The bundled sample shows none.

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

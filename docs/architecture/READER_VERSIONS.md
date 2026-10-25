# Reader versions

Each arXiv paper is prepared on the reader's device from arXiv's official HTML by the reader's compiler
(HTML_FIRST_READER.md). The compiler has a **revision** (`ARXIV_RENDERER_REVISION` in
`supabase/functions/_shared/reader/arxiv-html.ts`), bumped whenever the same source would read differently. A stored
paper keeps the version that prepared it; a newer app shows it as it is and offers the update instead of doing it
behind the page (owner, build 62: "We don't need to interrupt an otherwise working reader experience").

## Where readers see it

⋯ › **Reader version details** (iPhone, iPad, Mac): this paper's version, this app's, what changed since, and **Update
this paper**, which prepares it again with this app's reader while the current copy stays on screen; the new copy then
replaces it near the same place. A failed update says why, with its code (`ArxivHTMLError.code`: a compiler reason such
as `arxiv_math_coverage`, or the device's own `web_process_ended`, `timeout`, `load_failed`, `result_invalid`,
`package_invalid`, `source_mismatch`, `compiler_threw`, or a network one: `arxiv_busy`, `retrieval`, `arxiv_refused`).
The same code is behind the ⓘ on the "Read this paper as its PDF" screen and in the session log.

After the build-64 `invalid` report, native host guards name their stage: `request_url_invalid`, `response_not_http`,
`html_response_url`, `asset_response_url`, `html_content_type`, `html_empty`, `asset_url_invalid`,
`asset_input_missing`, `compiler_resource_missing`, `compiler_resource_unreadable`, `compiler_not_loaded`.
The reproduced failure was `asset_input_missing`: Swift's optimized task returned index zero for successful image
downloads. Awaiting the bytes before constructing the result tuple fixes it. This is a native acquisition fix,
so the compiler revision stays 16; already prepared papers need no update. See [the cause and regression](HTML_FIRST_READER.md).

The browser reader's ⋯ has the same item (`apps/web/src/ui/ReaderVersion.tsx`), reading this list and
`arxiv-reader-build.json` directly. It prepares a paper afresh each time it opens, so its copy is normally its own
version; Update this paper is offered for an older copy (a legacy server copy) and keeps it on screen until the new one
is ready. Its codes are `ArxivReaderError.code` (the compiler's listed reason, or `timeout`, `compiler_start`,
`result_invalid`, `source_mismatch`, `unavailable`, `no_html`, `arxiv_busy`, `retrieval`, `arxiv_refused`).

## The list

`apps/apple/ScienceReader/Resources/reader-versions.json` names every revision with its build identity
(`build_sha256`, which every bundle's manifest carries) and one plain line about what changed. `node
scripts/build-arxiv-compiler.mjs --check` (the fast tier) fails when the shipped revision is missing from it, so a
revision bump always adds its line.

| Version | Date | What changed |
|---|---|---|
| 27 | 2026-10-25 | Not yet released (after TestFlight 93). A figure printed before the Introduction reads after the paragraph that first cites it (owner, TestFlight 92: "Is the Figure displayed in the right place", WorldCast 2610.20731v2). LaTeXML keeps a float where the source wrote it, so WorldCast's Figures 1 and 2 (the foot of page 1 and the top of page 2 in the PDF) read between the abstract and "1 Introduction", whose second paragraph cites Figure 1. A figure or table between the title and the first section that the first section cites now moves to just after the whole LaTeX paragraph citing it; later floats before the first section follow it, each to its own first citation or right behind the one before, never past a float of the body or into the references; a teaser the Introduction doesn't cite, and every float in the body, stay where the paper put them (`arxiv/floats.ts`, `float-placement.ts`; JUDGMENT_LOG 27). Ids are unchanged. The reader's keywords row now sits right after the abstract (the bridge, every version). Of 186 cached sources 21 change (35 floats moved), none newly refused; the fresh 30-paper sweep has no failures. On-device model readings move the same floats (device port revision 15). Papers already prepared keep their copy until **Update this paper**. |
| 26 | 2026-10-25 | Not yet released (after TestFlight 92). Aligned equations read as the paper sets them, and a bar sits over its letter (owner, TestFlight 92: "Is this equation displayed correctly?", 2610.27450v1). LaTeXML writes align, alignat and eqnarray as an HTML table with a formula per cell, and every cell had become its own centred display ("A_t", then "= Top-K(p_S),"): equation (2) took a screen. A group is now one display per number: a MathML table with a row per line and each column aligned as LaTeX aligns it (relations under one another, the two sides of `&=` joined), scrolling sideways only where a row is wider than the screen, its number beside it, its index LaTeX the rows as `aligned` (an `array` for other column patterns). Rows numbered apart, (4) and (5), are equations of their own with their own numbers (not aligned with each other); a continued line stays with its number; words in a cell (`\mbox`) are kept; a cell holding anything else keeps the old reading. Lines of one formula each with several numbers (gather) now carry each number on its own line. Accents: WebKit drew LaTeXML's stretchy ¯ wider than a letter and to its left (equation (3)'s \bar{p}^U_M), wide hats and tildes across A, W, μ with their subscripts pushed off, and dots an x-height above; over a single letter a bar is now an en dash, a hat the caret ‸, a tilde the unstretched ~, a dot ⋅ (two for ¨), a ring ∘, with no operator spacing, drawn over the letter in WebKit, Chromium and Firefox; over a group the stretched mark stays. The arXiv and on-device stylesheets align table cells by `columnalign` (with `justify-items` for Chromium). Of 185 cached sources 132 change (526 aligned groups, 1,226 fewer index equations), none newly refused; the fresh 30-paper sweep has no failures. Papers already prepared keep their copy until **Update this paper**. |
| 25 | 2026-10-24 | Not yet released (TestFlight 92 candidate). A figure drawn as SVG with photos or screenshots inside it shows in the paper instead of "This figure couldn’t be shown here; the PDF has it." (owner, TestFlight 91: 2610.29989v1's Figure 1, LaTeXML's PDF-to-SVG overview with two embedded PNG panels). The device's SVG admission (device-compiler.ts `svgImage`) now allows `<image>` whose source is a base64 PNG or JPEG in the picture itself that the shared inspector reads within a standalone image's sizes and whose bytes match the declared type; a link, another SVG or unreadable bytes are still refused, and the figure reads as its note as before. Of 212 cached SVG figures 3 (in 3 papers) carry pictures; 2610.29989v1 and 2610.28711v1 now prepare every image (Chromium and WebKit). Papers already prepared keep their copy until **Update this paper**. |
| 24 | 2026-10-24 | Not yet released (TestFlight 90 candidate). Symbols in titles and headings read as characters: a formula Unicode spells exactly (letters, digits, operators, sub- and superscripts Unicode has) is text in the heading, a one-letter variable in italics, so the title, Contents and the page's `<title>` read "VLA-Δ: Learning…" instead of "VLA- \Delta : Learning…" (fresh-paper sweep, 2610.21306v1; the index writes an equation as its LaTeX, and a heading's index text is its title everywhere). A fraction or a script Unicode lacks ("p_T") stays math. In the author block an affiliation keeps a web address it put in brackets ("Zhejiang University (zju.edu.cn)"; it had become "()" and eight copies of the address), brackets emptied by a dropped e-mail go, a repeated project page is listed once, and a link whose words were an icon (ORCID) leaves no empty line. Of 174 cached sources 43 change (headings, fewer indexed equations, four author blocks); the fresh 60-paper sweep and the 125-paper replay have no failures and otherwise unchanged findings. Papers already prepared keep their copy until **Update this paper**. |
| 23 | 2026-10-23 | Not yet released (TestFlight 90 candidate). List items show one marker, the paper's own label ("•", "–", "(ii)", "1.", a reference's "[12]"), with no empty lines under each: LaTeXML's `ltx_tag_item` label sat as text beside the list's own bullet, and each item's `div`/`p` left two line breaks (build 88, Qwen-Audio 2610.28711v1 §7, Next-Concept Modeling 2610.14162v1). A diagram label of several lines or in a minipage is drawn line by line, wrapped to the minipage, without `\phantom` struts ("Agand"); every label had been one centred line running across the figure (2610.14162v1 Figure 3). The 125-paper replay: no failures, findings unchanged. Papers already prepared keep their copy until **Update this paper**. |
| 22 | 2026-10-21 | Not yet released. Plot labels no longer drawn mirrored; affiliations and contact lines read in the header. A picture's labels were flipped twice (their own counter-flip kept on the group, plus another on the new text), so every tick and axis label of a pgfplots/TikZ picture read upside down (build 73, 2610.22371v1 Figure 3; also Chain-of-Thought 2201.11903v6 and Apertus 1.5 2610.15542v1), and a math label showed its TeX beside the symbol ("σ\sigma"). Affiliation paragraphs after the abstract, with the e-mail paragraph right after them, now join the header's affiliation lines, every institution, mark and address kept (build 69, 2610.22353v1). The 123-paper replay: no failures, findings unchanged, three headers changed (2610.16794v1, 2610.19892v1, 2610.20592v1). Papers already prepared keep their copy until **Update this paper**. |
| 21 | 2026-10-18 | TestFlight 70 on iOS/Mac and browser deployed. Image-heavy papers reduce bitmap sizes when needed to fit the existing bundle limit, keeping every figure. Native replay of 2610.20592v1 passes. |
| 20 | 2026-10-18 | Affiliation lines retain their indexed math marks and contact details. 123-paper replay: no failures. |
| 19 | 2026-10-18 | Separate affiliation lines after the abstract, including 2610.22353v1; browser-only checkpoint, superseded by 20. |
| 18 | 2026-10-17 | Font setup text no longer appears on custom title pages, including FDE-Gym. Browser deployed; TestFlight 67 on iOS and Mac. |
| 17 | 2026-10-17 | Text badges inside equations retain their labels; their algorithms remain text listings. Browser deployed; TestFlight 66 on iOS and Mac. |
| 16 | 2026-10-16 | Contents › Tables lists the paper's tables; an image arXiv doesn't serve leaves a note in its figure instead of stopping the paper. |
| 15 | 2026-10-15 | A figure the device can't prepare says so in place instead of stopping the paper; very large drawings are drawn smaller. |
| 14 | 2026-10-15 | Figures missing from arXiv's page say so; placeholder author lists give way to the paper's real authors. |
| 13 | 2026-10-15 | Unusual math styling is left out rather than stopping the paper. |
| 12 | 2026-10-15 | Panels under one caption read as one figure. |
| 11 | 2026-10-15 | The converter reorganised; the papers read the same. |
| 10 | 2026-10-15 | Shared checks with the on-device PDF reader. |
| 9 | 2026-10-14 | Title pages and author tables; very large images left out. |
| 8 | 2026-10-14 | Fewer papers refused on first open. |
| 7 | 2026-10-14 | Unresolvable citations and leftover macros removed; the reader sets math colours. |
| 6 | 2026-10-14 | Author names and affiliations laid out more cleanly. |
| 3–5 | 2026-10-14 | The first versions shipped to testers. |

## Preparing on a phone

A preparation's web compiler runs one at a time on the device (`ArxivCompileGate`), so a paper opened while others
prepare waits its turn instead of adding another WebKit process and its images to memory. When the system ends the
compiler's process, or it stalls past 90 s, the compile runs once more in a fresh one with the downloads already there
(no new arXiv request). A preparation that failed is tried again only by the reader's own action (opening the paper,
Try again, asking about it, Update): a library sync never retries it (build 62: MLExpert "keeps trying to Download
repeatedly and failing").

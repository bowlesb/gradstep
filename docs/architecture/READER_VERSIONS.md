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

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
page-break split (3–5 per paper) with identical equation and figure counts.

Device presentation (`reader-bridge.js`, applied to every bundle version without changing content): per-cell
`columnalign` (WebKit ignores it on `mtable`/`mtr`, which centered aligned derivations), equation numbers pinned
visible while a wide equation scrolls, display/inline math scaled to the column when within 75% (otherwise it
scrolls in its own box; the page never scrolls sideways) and edge shadows on scrollable equations and tables.
At iPhone width this fixed page-level sideways scrolling on 4 of 6 real papers; at iPad width every equation fits.

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

The committed app fixture `ReaderSamples/d874c0ed…` is this renderer's output for the DPO capture, with CC BY 4.0 attribution in its `NOTICE.txt`; `tests/backend/reader-render.test.ts` checks it byte-for-byte when the capture is present locally.

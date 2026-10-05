# Offline reader bundle renderer

Status: local authored-fixture renderer, October 2026. It builds the app's **Offline sample** (`timestep-mmd-v1` / `authored-mmd`) through the actual math renderer and complete bundle validation. Mathpix output is rendered by the Edge-compatible [`timestep-mathpix-mathml-v1`](../../docs/architecture/READER_RENDERER.md) renderer in `supabase/functions/_shared/reader/`; this worker's earlier synthetic `timestep-mathpix-mmd-v1` entry was removed. No network, provider credentials, remote storage or database calls are made here. Its `node_modules` also supplies `scripts/chat-renderer-proof/`.

From this directory, on Node 24 (validated on 24.18.0):

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
node cli.mjs
```

The last command prints one small JSON result and writes a complete content-addressed directory under `tests/fixtures/reader/generated/<manifest-sha256>/`. Files are validated before directory publication; an existing directory is compared byte-for-byte rather than overwritten. It does not install the result into the app. The native caller must pin the reviewed manifest SHA separately. `tests/fixtures/reader/make-figures.mjs` reproduces the two original PNG diagrams without fonts, third-party images, or drawing dependencies.

## Rendering and trust boundary

`render-document.mjs` adapts pinned Mathpix markdown-it tokens. Every equation's ID, exact token LaTeX, source form, MathML and SVG are emitted from the same parser token. Inline math and delimited display math use `source_form: "body"`; equation/align environment tokens use `"environment"` and require display mode. Delimiters are not inferred from HTML order or guessed by a native regex. The sidecar LaTeX is the parser token content: delimiters are excluded for body tokens, and environment syntax is preserved for environment tokens. Source bytes have their own SHA-256.

Repeated equations receive separate IDs. SVG and MathML internal IDs and every fragment reference are renamed together. Source label collisions fail instead of choosing a different equation. Headings, block ownership, figure assets and all claimed nodes are checked again after sanitization. Titles and heading text are limited to 2,000 UTF-8 bytes; other text/LaTeX is limited to 20,000 bytes. Index IDs use only ASCII letters, digits, hyphens and underscores, at most 200 bytes.

Each public `renderMMD` call runs in a fresh, short-lived process. Mathpix's reset clears tags but does not clear user TeX macros, so a reused MathJax module graph is not a document boundary. The internal renderer rejects a second call. Synthetic regressions cover successful and failed document A defining a macro followed by document B trying to use it. A dedicated result pipe prevents upstream parser diagnostics from becoming HTML, a result envelope, or an archived error. No browser MathJax, auto-render, SRE, CDN, JavaScript, or font resource is included in the bundle.

Raw HTML parsing is disabled. The independent `sanitize-html`/`htmlparser2` pass rejects unsupported elements, attributes, namespace changes, active SVG/MathML, external resources, CSS imports/URLs, unresolved fragments and duplicate IDs. Source-controlled MathJax HTML-extension attributes are rejected in semantic MathML, including macro-expanded `\style`, `\class`, `\cssId`, and `\href`; a syntactically valid CSS string is not enough to admit an equation. MathJax errors and oversized equation dimensions fail publication. The HTML skeleton and stylesheet are owned by the generator and checked independently by `validateBundle`.

This deliberately restricted authored profile excludes external bibliography/navigation links, raw MathML input, author CSS, inline images embedded in prose, and unsupported renderer constructs. A figure is a standalone Markdown image whose title is its caption and whose alt text is required. Failed parsing, a missing asset, or an unused supplied image is an error, never a silently partial bundle.

Visible SVG is hidden from accessibility while clipped, present MathML remains in the same equation container. LaTeX is retained in a hidden sibling for correspondence checks, but native selection must resolve the sidecar rather than rely on hidden text selection. Actual WebKit/VoiceOver behavior, large text layout, scrolling, figure expansion, and chat-return interaction require native tests; this renderer does not establish those outcomes.

## Frozen v1 artifact shape

`manifest.json` has format `reader-bundle-v1`, renderer `{id:"timestep-mmd-v1",build_sha256}`, source `{kind:"authored-mmd",sha256,provenance_path}`, `entrypoint`, `index_path`, and `members`. Each member has `path`, `role`, `media_type`, exact `bytes`, and `sha256`. Image members additionally require positive `width`/`height`; other roles omit dimensions. The manifest does not list itself. Account, document and backend artifact identities are bound separately by the native caller, not invented by this fixture.

Roles/MIME types are `html:text/html`, `index:application/json`, `provenance:application/json`, `style:text/css`, `notice:text/plain`, and `image:image/png`. Paths are ASCII relative segments beginning with an alphanumeric character and containing only letters, digits, `_`, `.`, `-`; no `.`/`..` segments, case collisions, or path over 240 bytes. Limits: 512 members, 32 MiB total, 16 MiB/member, 256 KiB manifest, 8 MiB HTML, 2 MiB index. No resource outside the manifest is needed.

`reader.json` uses `reader-index-v1` and contains:

```text
title: string
headings: [{id, level, title}]
blocks: [{id, kind, text}]
equations: [{id, block_id, latex, display, source_form: body|environment}]
figures: [{id, block_id, asset_paths, caption, alt}]
```

Block kinds are `heading`, `paragraph`, `equation`, `figure`, `table`, `list`, `code`. Heading ID equals its block ID; figure ID equals its block ID; equation IDs are distinct from block IDs. Equation/figure parents must exist. DOM `id` and corresponding `data-reader-block`, `data-reader-equation`, `data-reader-figure` values agree exactly. The title's H1 is a heading block; Contents contains the five existing H2 sections. Caps are 500 headings, 5,000 blocks, 512 equations, and 128 figures.

PNG admission is limited to 8-bit RGB/RGBA, non-interlaced, IHDR/contiguous IDAT/IEND, at most 512 chunks, and no other chunks. Every chunk name and CRC is checked. Bounded zlib inflation must consume the exact compressed extent, produce the exact scanline bytes, and use valid filters. Pixels are decoded and canonically re-encoded, removing all input container variability. Each image is at most 8,192 pixels per dimension; aggregate admission is at most 16,000,000 pixels (64,000,000 RGBA bytes). These are explicit bounds, not a claim that every accepted image fits a hosted worker. JPEG is not supported in this pilot.

## Provenance, dependencies and reproducibility

The fixture is original application content adapted from the project's existing sample, not a paper capture or provider result. `sample.mmd`, `provenance.json`, original artwork source, and input PNGs are retained. Published provenance binds original source bytes and both original/published image hashes. No local benchmark papers are redistributed.

The isolated package pins `mathpix-markdown-it@3.0.1`, its matching `markdown-it@9.1.0`, `sanitize-html@2.18.0`, and `htmlparser2@12.0.0`. The lockfile pins transitive packages and npm integrity values. Mathpix's package is broad (including React, chemistry, SRE and its older HTML parser); those parts are not included as client runtime. The independent current sanitizer/parser pair is intentional. The headless token adapter uses pinned package internals and must be reviewed on upgrades. `NOTICE.txt` retains Mathpix/markdown-it/sanitizer/parser MIT notices and MathJax's Apache-2.0 license for generated math output.

Primary references: [Mathpix package/API](https://github.com/Mathpix/mathpix-markdown-it), [Mathpix license](https://github.com/Mathpix/mathpix-markdown-it/blob/master/LICENSE), [MathJax SVG output](https://docs.mathjax.org/en/v3.2/options/output/svg.html), [htmlparser2](https://github.com/fb55/htmlparser2), [sanitize-html package](https://www.npmjs.com/package/sanitize-html). Lockfile license metadata is mostly permissive; it also contains the tooling-only caniuse-lite CC-BY-4.0 data, Python-2.0 argparse, Artistic-2.0 domain-browser, and dual LGPL-or-MIT xmldom-sre. No node_modules code is vendored or shipped in the reader bundle. This is dependency provenance, not a legal opinion or a vulnerability audit.

The renderer build digest binds production source files, profile/options, CSS/template, notices, exact lockfile, and Node/V8/zlib versions. The CLI captures that digest before importing the renderer and rechecks it before publication; each math child independently captures/rechecks the same identity. Same-process calls and fresh-process builds are compared byte-for-byte in tests. Use a clean `npm ci` with unchanged dependencies: the lockfile does not itself prove that an already installed node_modules tree is untampered. This is a local reproducible build record, not an immutable deployed renderer attestation.

The local CLI uses a 60-second outer process-group watchdog and 30-second individual rendering deadline, with 256 MiB V8 heap limits. It bounds actual file reads and aggregate retained input bytes. Copied inputs, PNG pixels and process overhead need additional headroom. The outer timeout and handled cancellation terminate descendant processes too. V8 heap is not total process RSS; these settings are not a hosted CPU/memory guarantee or an OS network sandbox against an independently compromised dependency.

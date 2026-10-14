# Reader integration corpus, 2026-10-13 PDT

Owner requested broader PDF/integration tests and an explicit fast/slow split. Commands and rerun policy are in
[TESTING.md](../TESTING.md). The baseline uses local cached official sources, not a hosted PDF processor or an
unversioned live corpus. No paid provider, NAS, TextBrain or physical iPhone was used.

## Exact sources

| Paper revision | PDF pages | PDF bytes | HTML expectation |
|---|---:|---:|---|
| [DPO 2305.18290v3](https://arxiv.org/html/2305.18290v3) | 27 | 1,299,212 | Ready: 254 blocks / 261 equations / 5 figures |
| [Mamba 2312.00752v2](https://arxiv.org/html/2312.00752v2) | 36 | 1,168,615 | Ready: 566 / 558 / 15 |
| [MatMul-free 2406.02528v7](https://arxiv.org/html/2406.02528v7) | 26 | 1,414,451 | Ready: 268 / 367 / 9 |
| [Before They Can Solve 2610.10478v1](https://arxiv.org/html/2610.10478v1) | 31 | 1,460,372 | Ready: 247 / 301 / 12; reported caption/glyph regression |
| [Learning Representations 2610.12978v1](https://arxiv.org/html/2610.12978v1) | 26 | 36,220,083 | Ready: 250 / 262 / 29; inline-vector regression |
| [KAN 2404.19756v1](https://arxiv.org/html/2404.19756v1) | 48 | 12,936,964 | Unavailable: `image_total_limit`, exceeds 64 million rasterized image pixels |
| [DeepSeek-V2 2405.04434v1](https://arxiv.org/html/2405.04434v1) | 50 | 1,576,608 | Unavailable: official HTML has an undefined `reportnumber` / `ltx_ERROR` node |
| [Learning to Learn at Test Time 2407.04620v1](https://arxiv.org/html/2407.04620v1) | 34 | 1,713,478 | Ready: 382 / 490 / 19; algorithms, nested figures, derivations |

All eight PDFs (278 pages total) passed local browser intake and native PDFKit admission. Native tests passed
original-byte equality after encrypted installation and store reopen, and rendered first/middle/last page
thumbnails. This is automated render/admission evidence, not a visual review of every page or structured PDF OCR.
Authored worker cases separately cover text, image-only pages, rotation, object streams, 250/251-page boundaries,
zero pages and malformed bytes. Native fixtures include an actual password-encrypted PDF and rejection of it.

HTML tests compile in an opaque network-disabled iframe under production parent CSP; independently verify the
complete package, provenance, member hashes and ownership; then check all raster images decode, all fragment
targets exist, and MathML count agrees with the index. Existing authored app journeys additionally cover the
real reader and paper-chat context. Expected failures require a precise finite category and no partial bundle;
they are not counted as ready papers. No limits were raised and no bad source nodes were discarded.

## Failure found and correction

The Firefox real-PDF journey stalled at “Preparing this browser…” because key setup awaited the optional
`navigator.storage.persist()` permission promise. Durable key write/readback had already succeeded. Make that
advisory permission request nonblocking, without changing the required key checks or storage/account fencing.
A fast regression reproduced the stall before the fix and now exercises pending, denied, rejected and synchronously
throwing permission requests. The existing key integrity/recovery tests remain in the fast suite.

During test development, the raw bundle-render harness initially omitted the browser frame's data-image CSP
adaptation, so its images were blocked. The authored image-PDF generator also needed a standalone Uint8Array
because pdf-lib's JPEG reader uses its backing buffer from offset zero. Both were harness issues, not product
failures. The interrupted Firefox run is retained as pre-fix evidence; final runs are recorded below.

## Evidence

- Fast: 499 backend tests, 349 browser unit tests and compiled reader freshness pass (10.2 seconds).
- Authored slow browser journeys: 13 pass, 3 explicit WebKit account/key capability skips (23.9 seconds).
- Native slow iPad Simulator: six PDF tests plus two WKWebView HTML tests pass (75.1 seconds including build/start).
- Corpus: 40 pass / 8 WebKit account-capability skips (145.7 seconds). Includes 18 successful HTML preparations,
  six explicit unavailable-source outcomes, and 16 PDF intake/reload journeys across Chromium and Firefox.
- Browser fix deployed as Pages `a3127547`; live index and both referenced assets match the tested local build
  hashes, with production CSP. No repeat hosted account/provider journey was needed for this browser-only fix.

Local logs/reports: `.artifacts/test-tiers/`, `.artifacts/reader-corpus-results/`,
`.artifacts/reader-integration-build/Logs/Test/`. PDF/source bytes remain solely in `.artifacts/reader-corpus/`.
Checked-in fixtures contain authored input and corpus identity/checksum metadata, not downloaded papers.

# Reader position to a local PDF overlay

Status: full-screen/two-finger interaction audited on iPhone/iPad Simulators, 2026-10-25 PDT. Merged into main as one standalone commit on 2026-10-26; not released.
The desktop implementation started at `78f33b6`; the Mac integration uses `a993d838`.
Physical-device work remains paused. The HTML-first runtime cutover is already verified;
older claims in the portable handoff that it is pending are superseded by the current implementation status.

## Interaction

A simultaneous two-finger single tap on the reader opens a full-screen PDF, anchored at the midpoint of the
touches. It is separate from the existing one-finger double tap for Contents; a moving pinch or drag stays with
WebKit. The existing **Show in PDF** button uses selected text or the upper-quarter visible passage. Capturing
never changes the DOM, selection or scroll. The full-screen host lives above RootView's Tall/Wide switch.

On opening, the PDF moves from the matched page to its approximate area in 350 ms. The outline uses the figure
explainer's violet, begins fading immediately and disappears after one second. PDFKit converts the target for
cropped/rotated pages; no annotation or permanent text highlight is written. Normal PDF scrolling and pinch zoom
remain available. The **X** (also Escape/VoiceOver escape) or a downward swipe on the top row returns to the exact
reader state. Reduce Motion skips the zoom and hides the outline after one second. On Mac the viewer uses a
window-sized sheet. Ambiguous/unsupported text gets an honest browsable fallback without an invented outline.

## Local architecture

The existing verified bundle and account/document scope bind the snapshot. Capture text from app-owned isolated
WebKit code, check manifest and block membership natively, and bound the query. The toolbar anchor is a visible line
near the upper quarter of the reading viewport; selected text takes priority. A two-finger tap instead uses its
midpoint, ignoring a previous selection for targeting without clearing it. This is a reading-position
estimate, not eye tracking. Short selections and equations use their immediate neighboring prose when useful and
explicitly say “Nearby text”. Context windows stay around the actual anchor even inside a multi-screen block;
they never restart at that block’s beginning. Tapped-equation queries omit its LaTeX and compare adjacent prose.

Use an app-bundled deterministic lexical retrieval model in JavaScriptCore with no network APIs. Normalize
Unicode ligatures, whitespace and line-end hyphenation while preserving original UTF-16 offsets. Retrieve
candidate positions with rare words; score local windows with token coverage and ordered pairs. Require a
minimum text signal and separation from the next distinct location; progress never overrides contradictory
text. The same source runs unchanged in the Linux corpus harness and on device. No model download, paid call,
server PDF/text transfer, credentials, schema change or operating-budget commitment is needed.

PDFKit extracts the device-local PDF's text on a background actor; the main-thread viewer owns its own PDFDocument.
Only bounded primitive ranges cross that boundary. PDFKit resolves ranges to page-space selections, avoiding
manual coordinate transforms on rotated/cropped/two-column pages. Cache one bounded index per open reader scope
and PDF digest; release it on scope change/backgrounding. Presentation and worker ownership live in the reader model,
with full-screen presentation hosted above RootView’s Tall/Wide switch so iPad rotation preserves the preview and zoom. Cancel pending work and reject stale completions on
dismissal, navigation, account change or retirement. PDF bytes remain in the existing encrypted DevicePaperStore;
plaintext/index/query live only in memory. No persistent plaintext cache or telemetry of passages.

For an exact arXiv revision without a local original, the viewer offers an explicit device download through the
existing bounded fetcher and encrypted store. The final URL must name that exact arXiv revision. Never use the
server original, PDF upload queue or Mathpix. Unsupported source identity has a clear unavailable state. Scanned
PDFs without text remain browsable; OCR/model support is a separate future quality gate.

## Verification

- Unit tests run the shipped matcher: ligatures, hyphenation, changed text, duplicate passages, short queries,
  negative controls, page boundaries, UTF-16 ranges, bounded resource refusal and deterministic outputs.
- Corpus harness reads existing local originals/HTML without modifying them, deterministically splits by paper,
  records hashes/counts, evaluates known-location perturbed prose plus independent HTML exact-phrase anchors,
  and reports abstention separately from incorrect acceptance. No raw corpus content in checked-in reports.
- Apple tests and Simulator journeys must cover live snapshot/selection, PDFKit selection geometry, scope fencing and overlay dismissal.
  Linux retrieval timings do not establish iPhone/iPad latency; Simulator/build and device gates stay explicit.

## Evidence and limits — 2026-10-25

The read-only source corpus is `/home/ben/mathpix/data/arxiv`: 19,110 original `arxiv.pdf` files with saved
`arxiv.html`. No corpus files were copied into the app or changed. Development used 64 papers; a 512-paper
calibration run exposed paragraph continuations separated from their openings by footnotes/floats. Requiring
opening-word/order evidence eliminated those 12 observed mislocalizations. The final holdout excluded all
canonical paper IDs from both earlier samples, selected at most one local revision per paper, and did not
change the model after measurement. One of 1,024 requested files failed extraction/read checks.

| Fresh holdout (1,023 papers; 26,251 pages) | Queries | Correct region | Wrong region | Abstained |
|---|---:|---:|---:|---:|
| Perturbed PDF passages with known locations | 5,017 | 4,918 | 0 | 99 |
| Saved HTML, unique exact-phrase silver anchors | 5,105 | 4,979 | 1 | 125 |
| Unrelated negative prose | 1,023 | 1,023 rejected | 0 accepted | — |
| Other papers’ academic prose, absent opening | 1,020 | 1,020 rejected | 0 accepted | — |

Positive checks require page **and overlapping character range**, not merely the correct paper. The remaining
wrong silver match (`2610.15039v1`) selected a later part of a technical paragraph whose opening shared terms
with its continuation. These are automatic silver/perturbation labels, not a human quality audit. Formula-only,
figure/table regions, OCR errors, arbitrary publisher PDFs and scanned documents do not have accuracy proof.
The first version finds text regions and labels surrounding-prose matches “Nearby text”; it does not infer a
figure’s full graphical bounding box or run OCR. The current local store also accepts historical arXiv identifiers and Files-import identities.
Device-converted readings select their original by its recorded digest; they do not guess an arXiv source.

Shipped matcher SHA-256: `7cbe5214ca97d8c45159d0771939c01f76c02e719117cec8bf6bbe3e0e198137`.
Linux/Node 18 holdout timings: warm query p50 **0.45 ms**, p95 **1.87 ms**; index p50 **10.05 ms**, p95 **24.60 ms**.
These exclude PDF extraction, downloading and UI rendering and are not Apple/device performance claims.
The index is built on first use, reused while the same reader is open, and released on document/account/background
changes. A matched region is outlined only if PDFKit accepts its character ranges; otherwise the viewer reports
that a reliable area is unavailable.

[Machine-readable holdout and file hashes](../reviews/pdf-peek-20261025/holdout.json) contain no passage text.
The two selection manifests beside that file reproduce the holdout exclusions. Run from the repo root:

```sh
node tests/reader/pdf-position-matcher.test.mjs
python3 scripts/pdf-position-corpus.py --root /home/ben/mathpix/data/arxiv --count 1024 --split evaluation \
  --exclude-report docs/reviews/pdf-peek-20261025/development-selection.json \
  --exclude-report docs/reviews/pdf-peek-20261025/calibration-selection.json --output /tmp/pdf-peek-holdout.json
```

Nine matcher unit tests pass. The existing bridge matcher regression suite passes. The actual reader bundle and
bridge pass Chromium DOM checks at 390 and 1024 px: live viewport capture, current text selection, nearby equation
context, unchanged selection/scroll/DOM. A continuation audit added passing regressions for a viewport near the
end of a multi-screen paragraph, a short selection within a word, and an equation deep in a long block. These
exposed and fixed context that previously reset to a block’s beginning; short selections now retain neighboring
whole words without introducing artificial spaces inside the selected word. Run `tests/reader/pdf-position-bridge.mjs` with a local Playwright module
and Chromium path as its header describes. Chromium is **not** WKWebView/Simulator proof.

## Mac integration and verification (2026-10-25 PDT)

The portable handoff archive hash is `26781d88ba8b4a198c0ed959c25cf683b7e4d2746a7849d551ce7c58bd4f34d0`.
Only feature-specific code and measured reports were ported. The owner's follow-up replaces the initial sheet and
persistent text fill with the full-screen interaction above. The existing selection/equation provenance viewer
remains intact. The work based on `a993d838` was squashed into `main` as one standalone commit on 2026-10-26.
Its completed worktree/branch are retired; the evidence is retained in main’s `.artifacts/pdf-peek-complete/`.
Nothing is deployed.

The toolbar appears in compact, wide and reading-mode bars. The native gesture is one tap with two direct touches;
its normal recognition failure leaves moving pinches/drags with WebKit. A bounded normalized point reaches the
app-owned bridge. Capture verifies manifest/block membership and preserves DOM, selection and scroll.

Eighteen distinct focused checks are verified per iPhone/iPad Simulator, iOS 26.4, Xcode 26.4, Swift `-O`:
nine worker/store/scope/geometry tests, three live WKWebView captures, four PDF UI journeys, the existing one-finger
Contents double-tap regression, and one cached real-paper replay. They include actual two-touch input, neighboring
paragraphs on different PDF pages, native stroke/zoom/fade, X/top-row dismissal, reader-position preservation,
PDF pan/pinch, iPad reading mode, rotation, largest text and background dismissal. The cropped/rotated PDF test draws
in a real window, verifies opacity reaches zero, and preserves manual zoom on a later layout. Reduce Motion is
covered by the cached-paper check. Screenshots were inspected. The tablet toolbar test's expected page was corrected
from the earlier touch's page 2 to the live viewport's page 3; the affected journey then passed both Simulators.
Application code was unchanged by that final rerun. [Exact native evidence](../reviews/PDF_PEEK_NATIVE_20261025.md).

The native gate is `bash scripts/test-pdf-peek-apple.sh SIMULATOR_UDID`. It validates only Simulators and uses separate
sequential Xcode invocations. Optional `PDF_PEEK_PDF` points to the existing hash-pinned DPO v3 original; no corpus
or live endpoint is downloaded. Scripted HTTP separately covers the real bounded downloader, wrong-revision
rejection, encrypted install and fresh-model offline reopening. UI acquisition is a synthetic fixture compiled
only under `DEBUG && FIXTURE_HOST`.

`npm test` passes all ten fast steps, including nine matcher tests. Chromium capture regressions pass at 390/1024 px;
WKWebView independently verifies selection, viewport, touch-point and long-block context. The unchanged large
corpus is not rerun for native interaction edits. Final cached 27-page native timings were 225.76/214.82 ms cold
(phone/tablet), and warm p50/p95 0.82/4.03 and 0.85/5.21 ms. They exclude download/rendering and vary with host load;
physical-device and end-to-end opening latency are not established.

Physical phone work remains paused. Mac Catalyst's window-sized sheet, a browser PDF viewer and live arXiv
acquisition were not newly exercised. This is not a new complete paper/general-chat journey audit. Scans without
text and unsupported/ambiguous regions remain honest browsable fallbacks. Correct page and approximate area are
the owner's utility target; this version does not promise precise word or figure localization.

Budget: new fixed commitments $0/month, paid usage $0, outstanding reservations $0, forecast incremental
service spend $0/month. Existing project spending and the $100/month cap are unchanged. Nothing deployed.

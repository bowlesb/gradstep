# Reader-position PDF: full-screen interaction audit

Implemented and Simulator-verified, October 25 PDT / October 26 UTC 2026; not released to TestFlight.
Based on `a993d838c4b92f1e337e10c68794845622d1cc7c`; squashed into `main` as one standalone commit on 2026-10-26.
The original branch/worktree are retired. Exported evidence is retained in main’s `.artifacts/pdf-peek-complete/`;
`.artifacts/pdf-peek-evidence` links to its evidence directory. This merge reuses the native evidence below.

The owner's requested interaction now replaces the first integration's sheet and persistent yellow highlight:

- **One simultaneous two-finger tap** opens the original PDF full screen at the passage under the fingers. It is
  distinct from the existing one-finger double tap, which still opens Contents. A moving pinch stays with WebKit.
- The PDF moves from the matched page into the approximate area over **350 ms**, with the figure explainer's violet
  outline. The outline starts fading immediately and is gone after **one second**. It writes no PDF annotation.
- The PDF keeps ordinary scrolling and pinch zoom. A visible **X**, VoiceOver escape, Escape, or a downward swipe on
  the top row returns to the unchanged reader. Dragging the document itself browses it.
- The existing **Show in PDF** toolbar button uses the selected text or the live upper-quarter viewport anchor.
  Touch-point capture takes priority over a previous selection without clearing that selection. iPad reading mode
  and the Tall/Wide rotation switch retain the root presentation host.
- Reduce Motion lands directly and removes the outline after one second. Compact status text keeps the PDF and X
  usable in landscape at the largest accessibility text size. No match/no searchable text remains a browsable PDF
  with an honest status and no invented outline.

The original stays on device. Exact arXiv revisions use the encrypted local store or an explicit device download;
Files readings use the original's converter-recorded digest. Existing converter-provenance selection/equation menu
paths remain intact. See [architecture](../architecture/READER_PDF_PEEK.md) for acquisition and corpus evidence.

## Verification

**All 18 distinct focused checks are verified on each Simulator.** Xcode 26.4 (17E192), iOS Simulator 26.4,
Swift `-O` and whole-module compilation. iPhone 17 Pro `B6CD74CE-CB0C-417E-9E9B-F68175B5094D`; iPad Pro 13-inch
(M5) `B8DEE99E-FCD3-472F-BAFC-E01E5B952A36`. No physical device was queried or tested.

| Checks | iPhone | iPad |
|---|---:|---:|
| Worker, scope, encrypted store, cancellation, invalid ranges, PDFKit geometry/fade | 9 passed | 9 passed |
| Live WKWebView selection, viewport, and touch-point capture | 3 passed | 3 passed |
| Full-screen UI journeys, including two-touch input and PDF pan/pinch | 4 passed | 4 passed |
| Existing one-finger Contents double tap after menus, selection and scrolling | 1 passed | 1 passed |
| Hash-pinned cached DPO replay, native timings and Reduce Motion | 1 passed | 1 passed |

The full matrix ran from `scripts/test-pdf-peek-apple.sh` with `PDF_PEEK_PDF` pointing at the already cached DPO
original. The phone passed 18/18. The tablet passed 17/18, with one **test expectation** corrected after reviewing
its recording: the test expected the toolbar to reuse the earlier touch's page 2, but the taller tablet viewport's
upper quarter correctly addressed page 3. The corrected test now explicitly expects page 3 for that tablet toolbar
capture. The affected journey was rerun on **both** Simulators and passed, including the previously unreached
header swipe and unchanged reader position. No application code changed between the full matrix and this rerun.
The other checks reuse their unchanged passing evidence, per the owner's test policy.

Result bundles (Xcode may prune older bundles; exported attachments and logs are retained):

- Full matrix, phone: `Test-ScienceReader-2026.10.25_22-27-42--0700.xcresult` (18/18).
- Full matrix, tablet: `Test-ScienceReader-2026.10.25_22-35-05--0700.xcresult` (17/18 before the assertion correction).
- Final affected journey, phone: `Test-ScienceReader-2026.10.25_22-40-59--0700.xcresult` (1/1).
- Final affected journey, tablet: `Test-ScienceReader-2026.10.25_22-42-40--0700.xcresult` (1/1), finished **05:43:29 UTC**.

Logs: `.artifacts/pdf-peek-fullscreen-native-final.log` and `.artifacts/pdf-peek-fullscreen-return-verified.log`.
The final two invocations and their runner exited successfully. Summary JSON and attachments are retained in
`.artifacts/pdf-peek-evidence/fullscreen-{phone,ipad}/` and `return-{phone,ipad}/`.

`npm test` passed all ten fast steps, including nine matcher tests, in **24.4 s**, finishing 05:17:52 UTC.
Its JavaScript is unchanged by the later native visual adjustments. Report: `.artifacts/test-tiers/fast.json`.
The optional Chromium capture checks also pass at 390 and 1024 px, including local touch-point context and unchanged
DOM, selection and scroll. Native WKWebView checks independently verify those guarantees on both Simulators.

## Visual and interaction audit

The exported images were inspected. The real PDFKit test puts the viewer in a window, checks actual scale growth,
visible stroke geometry and decreasing opacity, then checks zero opacity after a second and unchanged annotations.
It covers a cropped page rotated 90 degrees; manual zoom survives a later layout. The UI journeys use native
simultaneous two-touch input, rather than calling the callback directly. Their synthetic PDF puts two neighboring
reader paragraphs on different pages, proving that the tap location is used. The tablet also exercises this from
reading mode. After PDF pan/pinch and X or top-row swipe, the original paragraph's position is unchanged within 3 pt.

- [Visible outline on a rotated/cropped page](../../.artifacts/pdf-peek-evidence/fullscreen-phone/outline-visible.png)
  and [the same view after it fades](../../.artifacts/pdf-peek-evidence/fullscreen-phone/outline-faded.png).
- [Phone full-screen PDF](../../.artifacts/pdf-peek-evidence/return-phone/pdf-fullscreen.png) and
  [tablet full-screen PDF](../../.artifacts/pdf-peek-evidence/return-ipad/pdf-fullscreen.png).
- [Phone largest-text landscape](../../.artifacts/pdf-peek-evidence/fullscreen-phone/pdf-large-text-landscape.png) and
  [tablet largest-text landscape](../../.artifacts/pdf-peek-evidence/fullscreen-ipad/pdf-large-text-landscape.png).
- [Tablet reading-mode tap at the second paragraph](../../.artifacts/pdf-peek-evidence/fullscreen-ipad/pdf-tapped-paragraph.png).

The audit corrected the large status message that could consume the viewport at accessibility sizes. It also replaced
permanent text fill with a transient stroke above PDFKit's rendering layers. The earlier native integration had
already corrected a landing below the previous page and a presentation host that disappeared during tablet rotation.
The live reader and chat arrangement are preserved; this was not a new complete paper/general-chat audit.

## Real-paper replay and limits

The unchanged 27-page DPO v3 original is pinned to SHA-256
`92cb3a2b71362acda98a789b03d88688fd33cf5fcf13f81d2b1de30ee7d3b67a`. A known passage resolves to page 2 and a real
PDFKit region. Each run measures one cold extraction/index/match and 100 warm queries:

| Simulator | Cold | Warm p50 | Warm p95 |
|---|---:|---:|---:|
| iPhone | 225.76 ms | 0.82 ms | 4.03 ms |
| iPad | 214.82 ms | 0.85 ms | 5.21 ms |

[Phone timing JSON](../../.artifacts/pdf-peek-evidence/fullscreen-phone/timing.json),
[tablet timing JSON](../../.artifacts/pdf-peek-evidence/fullscreen-ipad/timing.json).
These exclude acquisition/rendering and vary with host load; they do not establish physical-device latency.

The matcher hash remains `7cbe5214ca97d8c45159d0771939c01f76c02e719117cec8bf6bbe3e0e198137`. Its desktop holdout used
automatic silver/perturbation labels: 9,897 of 10,122 positives overlapped the expected region, 224 abstained and one
accepted another region; all 2,043 negatives were rejected. This is not human gold or universal PDF accuracy proof.
Scans, formula-only passages, graphical figure localization and arbitrary publisher layouts remain limitations.
No OCR or remote model is invoked. The UI fixture substitutes acquisition; scripted HTTP separately verifies the
real bounded fetcher, exact-revision rejection, encrypted storage and fresh-model offline reopening.

Physical iPhone work remains paused. Mac Catalyst's window-sized presentation, live arXiv acquisition and a browser
PDF viewer were not newly exercised. Existing selection/equation menus still use their original provenance viewer.
No deployment, server processing, GPU training, paid usage, reservation or fixed commitment was added. Incremental
service forecast remains $0/month; the existing $100/month project cap is unchanged.

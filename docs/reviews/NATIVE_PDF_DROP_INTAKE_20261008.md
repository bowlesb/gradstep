# Native PDF drop intake review — 2026-10-08

Source reviewed: `44bf3c2`. Shared native ownership is Claude's; this note proposes a focused repair and does not change shared code. These are source-level findings, not claims from a live account or a physical device.

## Account changes while a file provider is loading

`Views/PDFUploadViews.swift:145–150` checks only whether uploads are active before starting `loadDropped`. After the provider's asynchronous callback, it calls `PDFUploadIntake.add` with the mutable `ReaderModel`. `Views/AddPaperView.swift:106–111` has the same gap. `PDFUploadIntake.add` then uses the upload center's current context (`PDFUploadViews.swift:14`).

`Services/PDFUploadQueue.swift:325–332` captures and checks account ownership after `add` begins, so it does not cover time already spent loading the drop. A drop accepted for account A can arrive after sign-out/sign-in to B and be queued for B. A→B→A and deployment changes also need a session-generation fence, not only equal account IDs.

Proposed shared repair: synchronously capture an intake ticket when accepting a drop or presenting a picker. Bind it to the upload context's account, deployment and activation generation. Require the ticket at `PDFUploadCenter.add` entry and after each suspension (PDF check/adoption), including after A→B→A. Reject stale tickets with cancellation and avoid publishing errors or dismissing a replacement sheet. Existing queue jobs remain account scoped. Use the same ticket for a multi-file drop.

Focused deterministic reproduction: an `NSItemProvider` fixture holds its file callback; accept under A, deactivate and activate B, then release the provider. Assert no job or persisted PDF is created for B and no stale alert appears. Repeat A→B→A and a deployment change. This needs no network or paid operation.

## Temporary copies are never released

`PDFUploadIntake.loadDropped` (`PDFUploadViews.swift:22–41`) correctly copies the provider's transient file before returning from its callback, but hands out bare URLs. Neither caller removes the copied file or its UUID directory after the upload store adopts it. The Add sheet takes only `urls.first`, silently leaving every other PDF unqueued and every temporary copy behind (`AddPaperView.swift:109–111`). Failed copies can leave their directory as well.

Proposed shared repair: return an owned temporary-file value with idempotent cleanup, and release all copies with `defer` on success, refusal, cancellation and stale intake. Prefer loading and adopting sequentially to avoid accumulating all source bytes. The Add sheet should either queue every accepted PDF (matching the Library) or explicitly refuse a multi-file drop before loading; do not silently accept and discard extras. Report provider load failures instead of returning success with no visible result.

Focused tests: two valid PDFs both queue once; one invalid PDF does not hide the valid result; every intake temp directory is absent after success/failure/cancellation/account change. Assert original provider/user files remain intact. A Mac Finder→Library drag and Finder→Add sheet drag can then verify the pointer path using the scripted upload service.

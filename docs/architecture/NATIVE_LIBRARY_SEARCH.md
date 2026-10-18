# Native library search

## Installed-paper body terms (2026-10-18; release candidate 71)

`DevicePaperTextIndex` adds a disposable in-memory term set from installed verified bundles to the existing
library search worker's snapshot. It bounds each paper at 500,000 text characters/10,000 distinct terms and the
cache at 200 papers. It loads/decrypts one installed copy at a time off the UI thread and checks account/session
and removal epochs before publishing. Queries still use the existing worker/generation fences. This bounded
cache does not promise full-text coverage of every paper in an arbitrarily large library. No plaintext index is
persisted. Paper content deletion, library removal and account retirement invalidate terms and pending work.
Metadata keywords remain derived separately; this index is not yet a corpus-wide keyword ranker.


Status, 2026-10-04: asynchronous integration and the optimized maximum-library rerun pass. The original baseline found an 812–828 ms main-thread no-match scan. LibraryView could request that computation several times per render. This slice changes scheduling and result ownership; matching, row fields and navigation remain the same.

## Matching and ownership

Retain whitespace-separated AND terms and `localizedStandardContains` across the existing fields, including hidden abstracts/topics and exact source revisions. Paper authors remain the existing joined author field; pending imports retain their separate author fields. Title sorting compares localized titles and then stable row IDs. Recent sorting compares creation sequences and then source position. Filter once and sort the combined result once.

One immutable candidate snapshot contains metadata and row IDs only. It cannot retain a `Paper`, reader bundle, selected document, auth client or mutation capability. Query changes reuse it. A coalesced main-actor preparation turn collects synchronous model mutations after a coherent library/command publication. Searchable source changes advance a local revision, including cached restores, samples and imports; live server publication generation alone is insufficient.

The model keeps a current row lookup separately. Verified bundle hydration with unchanged searchable text refreshes those rows without starting a new scan. The worker returns IDs, which are resolved against that current lookup. Paper removals prune that lookup and the displayed matches synchronously. Existing paper selection still resolves the captured row against current membership/artifact eligibility.

When a source notification rebuilds an exactly equivalent candidate snapshot, a completed result can be reused only if it belongs to the pre-rebuild candidate revision and the current session/account/query/sort. The lookup still refreshes. An equivalent notification during an unfinished newer search cannot reuse older completed matches.

### Sort fields (2026-10-05)

The library metadata view adds sort fields beside Recent and Title: Authors (first author's family name), Year,
Opened, Progress and Chats, each with a natural direction (A→Z for text, newest/most first otherwise) that table
headers can reverse. Rows without a value for the field stay last in either direction; ties keep recent order.
Recent and Title order exactly as before. `LibrarySearchEngine.ordered` is the only ordering: the worker uses it
and the table's header comparator delegates to it. Candidates carry the extra sort keys; Opened/Progress/Chats are a
snapshot of this device's reading activity and private chat counts, refreshed when those change while such a sort
is active (progress after scrolling settles). Searching still filters first, then sorts by the chosen field.

## Scheduling and publication

The coordinator owns one detached computation and one replaceable pending input. Every submission has a fresh nonce. Supersession cancels current work, replaces the pending input and joins the old worker before starting its replacement. Check cancellation per row, term, field and sort comparison. Cancellation does not claim an uncooperative worker already exited.

The caller's key includes account, session, local source revision, durable-command generation, exact query and sort. Both key and nonce must match before publishing. A → B → A is fresh intent. Source/query changes invalidate publication synchronously, before deferred preparation. Sign-out clears display and current metadata references immediately; an old completion cannot publish into the replacement session.

Getters only expose stored state; neither SwiftUI body evaluation nor a getter schedules work. Query and account changes hide obsolete matches and display a short searching/loading state. Same-query source refreshes and sort changes (2026-10-05: tapping a table header must not blank the table) retain the existing rows, so that scroll position is preserved; a completed result is reused only for the same sort. The updating indicator is delayed and overlaid, not inserted as a list row (owner feedback, build 16 #7), so short background updates do not flash or shift every paper. Only a completed current request can display “No matching papers.” Filtering never changes selected paper/chat context. Existing imports and queued commands use the same mapping-based display deduplication, without resolving durable command authority.

## Verification and measurement

Deterministic held-worker tests must establish one active worker, latest-pending replacement, cancellation joins, nonce/session/source fencing, current-row resolution and main-actor availability. Existing search/command fixtures await the actual accepted search instead of relying on a second synchronous implementation or arbitrary sleeps.

The resource probe's format 2 reports submit-to-accepted-result latency separately from background work and main-actor snapshot/publication time. Moving a scan off-main does not make its computation disappear or establish lower memory use. Rerun the optimized 4,000-row workflow and preserve its raw results. Whole-library hydration, settled retention, WebContent memory and lowest-supported-device headroom remain separate concerns in [Native resource acceptance](NATIVE_RESOURCE_ACCEPTANCE.md).

The complete native suite in `.artifacts/native-search-verified.xcresult` passes 171 cases with three expected live/device skips and no failures. It includes twelve coordinator tests and five model tests covering cancellation-ignoring workers, one-active/latest-pending scheduling, MainActor availability, A → B → A, account/session replacement, synchronous removal pruning, current-row hydration, and equivalent metadata during an unfinished newer search. Independent review found and corrected same-query List remounting; its final scheduling/ownership reread found no remaining blocker. The first test build exposed an async Foundation thread-check restriction in the test helper; the verified run includes its corrected synchronous observation.

All three optimized resource journeys pass in `.artifacts/offline-resource-search.xcresult`. Across five measured iterations after warm-up, the no-match worker takes 789–808 ms and request-to-result takes 795–814 ms. Initial main-actor candidate preparation takes 10.5–12.9 ms; accepted no-match publication takes 0.046–0.058 ms. Query changes reuse that prepared metadata. These values measure the identified code phases; they are not a complete frame-time trace or physical-device acceptance. Raw attachments, metrics, generated checker policies and exact source/binary hashes are preserved beside the result bundle.

Both normal iPhone Simulator journeys pass in `.artifacts/native-search-ui.xcresult`: search → open → return → no-match recovery → external-scope separation, and encrypted install → terminate → relaunch → Contents/equation/figure/chat. These run the ordinary UI and the existing isolated fixtures, with no provider traffic or physical phone access.

The subsequent constant-row List layout leaves matching, metadata ownership and
navigation unchanged. Its optimized complete-library no-match rerun passes five
measured iterations: 803.5–810.3 ms background work, 808.8–815.9 ms request latency,
10.2–13.4 ms initial main-actor preparation and 0.050–0.061 ms publication.
iPhone/iPad search/open/return/no-match/scope journeys also pass. Reduced row
construction and post-restore footprint are recorded in
[Native resource acceptance](NATIVE_RESOURCE_ACCEPTANCE.md#constant-row-library-layout);
whole-catalog restoration and remaining metadata memory still need review.

The subsequent [per-row restoration projection](NATIVE_OFFLINE_BUNDLES.md#authenticated-per-row-restoration-projection) preserves all native search fields and canonical input order. Real encrypted-store tests cover Unicode, optional fields, hidden import mappings, cross-field AND terms and global sorting. The new optimized no-match journey scans the same 4,000-row catalog: 787.2–797.2 ms worker time, 792.5–802.6 ms request latency, 10.9–11.5 ms initial MainActor preparation and 0.047–0.051 ms accepted publication. Both iPhone/iPad search journeys pass. This verifies search continuity alongside lower offline restoration memory; it does not establish live-refresh or physical-device acceptance.

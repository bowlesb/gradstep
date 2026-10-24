# Native library search

## Full-text index (2026-10-24; unreleased, after TestFlight 90)

Replaces the bounded in-memory term set below (owner: *"is it searching full text from all papers instantly?"*).
Decisions: [DECISIONS.md](../DECISIONS.md) "Library search over every paper's text". Code: `ScienceReaderCore/FullText/`,
the app's `LibraryFullTextIndexer` and `LibrarySearchEngine.run`.

**What is searched.** Every library paper's title, authors, tags (with its arXiv keywords and source reference),
abstract and the text of its notes and snippets; and the full text of every reading saved on this device (both device
stores: arXiv HTML readings and on-device model readings, each store holding up to 128). A paper not downloaded here is
found by its metadata only: its text is not on the device. A paper opened from a reading outside those stores (the
sample, an older server reading) is indexed when opened.

**Tokens.** `FullTextTokenizer` (version 1): letters, digits and combining marks; NFKC plus case/diacritic/width
folding; apostrophes inside words dropped; "." and "," between digits kept ("2106.09685", "0.5"); soft hyphens
ignored; a hyphenated compound gives its parts consecutive positions and its joined form at the first part's position;
a light plural stemmer on ASCII words (sses → ss, ies → y, ches/shes/xes/zes → drop "es", s → drop except after s/u/i).
Words over 64 bytes take a position but are not indexed.

**Query.** `FullTextQuery`: words and `"quoted phrases"` (straight or curly quotes), all required. A hyphenated word
matches its parts as a phrase or its joined form. The last word while typing (no space after it) also matches the 64
most frequent indexed words it begins; an unclosed quote's last word likewise. Each clause matches a paper through the
index or, as before, as a localized substring of one of the row's metadata fields, so results are never fewer than the
metadata search gave. Imports and queued rows match by substring only, as before.

**Ranking.** BM25 per field (k1 1.2; length normalisation b 0.3 for title/authors/tags, 0.5 abstract/notes, 0.75 body),
weighted title 6, tags/authors/abstract 3, notes 2, body 1, summed per clause times the clause's IDF over papers; a
clause matched only by substring adds 1. The score is multiplied by 1 + 0.1 × the paper's place between the oldest and
newest in the library. Used for the default Recent order (newest first) when there is a query; every other order and
table column sorts exactly as before. Ties keep recent order.

**Snippets.** For the first 100 result rows whose match was in the paper's text: the densest cluster of matches (most
distinct clauses within 12 words, then most matches), from about 40 bytes before it to about 160 bytes, whitespace
collapsed, "…" at cut ends, phrase matches highlighted as one range. The List row shows it as one footnote line under
the title, secondary, the matched words primary and semibold; the table's title cell likewise. Rows matched only in
metadata show nothing new. Opening a row with a snippet opens the paper as before and then Find in paper with the first
highlighted words (the existing `__scienceReaderFind`), the keyboard left down.

**Storage.** `FullTextIndexStore`, one actor per account, in `<account>/search-index/`:
- `manifest.bin`: format and tokenizer version, segments, and per document its segment, slot, fingerprint and text file.
- `seg-N.bin`: an immutable segment: documents with per-field position ranges, a sorted term dictionary, postings
  (document delta, frequency, position deltas, varints). Fields are two positions apart so no phrase spans fields.
- `txt-ID.bin`: one body's text in 16 KB LZFSE blocks with tokenizer resume points every 32 words.

Each file is AES-GCM sealed with the account's local-store key; associated data binds it to the account and file
(`science-reader/search-index/{manifest,segment,text}/v1/<account>[/<id>]`). The directory has complete file
protection and is excluded from backup. Writes are atomic: segment and texts first, then the manifest; unreferenced
files are removed at open. Decrypted segments exist only in memory, loaded at the first search (or merge) and released
by `unload()` or sign-out. Account deletion removes the account folder with it.

**Updates.** A paper is two documents, metadata and body, so a tag or note edit reindexes only the small one. A commit
writes one new segment for its added/replaced documents and drops replaced ones from the manifest; more than 8 segments
merge the smallest (keeping 4 + the merged one), and a segment more than half out of date is rewritten. The indexer
runs at utility priority after a library, reading or notes change (coalesced), compares fingerprints (metadata: SHA-256
of its fields; body: the stored reading's digest), commits metadata changes and removals together, then decrypts each
new reading once and commits bodies 16 at a time; a running search reruns after each commit. Deleting a downloaded copy
removes its body at once. Sign-out cancels the indexer and closes the store with the account's other writers. A changed
version or an unreadable file empties the index; the next pass rebuilds it from the encrypted bundles.

**Reuse.** `FullTextSnapshot.documentFrequency(_:)`, `documentFrequencies()` and `termFrequencies(group:fields:)`
expose per-paper term counts and document frequencies over the same tokens, for the interest index's full-text TF-IDF
and later semantic search. Nothing uses them yet.

### Measurements

`swift run -c release FullTextBenchTool <folder of .txt>` (Core) and the opt-in `FullTextBenchTests` (Simulator, with
`TEST_RUNNER_FULLTEXT_BENCH_CORPUS`) index a synthetic library that repeats 16 real arXiv papers' text (93 KB average,
rotated paragraphs and 150 paper-specific words each), reopen it and time ten queries (20 runs each after a warm-up).
The repetition makes common words match most papers, so these are pessimistic for match counts and snippets.

2026-10-24, 2,000 papers (186 MB of text), this M-series Mac (`-c release`) and the iPad Pro 11-inch (M5) Simulator,
iOS 26.4 (`-O`, whole module):

| | Mac | iPad Simulator |
|---|---|---|
| Build (tokenize, seal, write; merges included) | 19.5 s, 9.7 ms/paper | 17.9 s, 8.9 ms/paper |
| On disk | segments 64.6 MB + texts 79.9 MB = 72 KB/paper | same |
| Open (manifest) / load all segments | 33 ms / 60 ms | 30 ms / 57–74 ms |
| Index query, median (p95) | 0.3–3.3 ms (≤ 3.9) | 0.3–4.0 ms (≤ 18) |
| Snippet, one paper: text not yet read / cached | 0.33 / 0.06 ms | 0.44–0.52 / 0.06 ms |
| Whole Library search (index + metadata substring + ranking + 100 snippets), median | — | 11–18 ms (max 22) |
| First search after launch (loads the index) | — | 91 ms |

Index queries: `attention` 0.5 ms, `diffusion model` 0.8, `"language models"` 3.4, `transfo` 0.8, `in-context learning`
3.4, `state space model` 1.4, a word in no paper 0.05. Phrases cost most (positions are decoded per candidate paper).
The whole-search median includes the unchanged metadata substring pass over the 2,000 rows (~13 ms with no match) and
snippets for the first 100 rows (decoded in parallel, texts cached after the first keystroke). Decrypted segments take
about 32 KB of memory per paper (65 MB at 2,000; 4 MB at 128). The earlier measurements below (4,000-row metadata
fixture) are unchanged by this work; that fixture has no paper text.

**Limits.** Only text saved on this device is searchable (each reader store holds up to 128 readings). The first search
after launch decrypts the segments (about 90 ms at 2,000 papers). During the first build, a running search reruns after
each 16 papers, so results grow while it runs, and a large merge can delay one search by a few hundred milliseconds.
Rows after the first 100 matches show no snippet. Find in paper searches the page's text for the snippet's words; a
match the page renders differently (inside an equation) can find nothing there.

## Installed-paper body terms (2026-10-18; TestFlight 71 on iOS/iPadOS and Mac; replaced by the full-text index)

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

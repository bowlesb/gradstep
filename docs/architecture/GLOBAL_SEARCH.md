# Global search (as built)

Built 2026-10-25 from the approved proposal [GLOBAL_SEARCH_AND_MORE.md](../proposals/GLOBAL_SEARCH_AND_MORE.md), phase 1's
search (section B). Native iPhone, iPad and Mac; local source, not released. The bar (Library · Paper · Chat · More + 🔍),
the More screen and the `.search` place are a separate navigation branch; until it merges, the screen opens with the DEBUG
launch argument `--global-search` and the Mac's **⌘K** (Edit › Search Everything…). Nothing new goes to the server.

## The interface with the navigation branch

- `GlobalSearchView(model: ReaderModel)` is the place's whole content (Tall: the list; Wide and Mac: the list on the left and
  the picked result on the right). It brings the keyboard up itself when it appears with no words (`@FocusState`).
- `ReaderModel.openGlobalSearch(scopePaper: Paper.ID? = nil)` is every entry point (⌘K, 🔍, a paper's "Search in this
  paper"). It sets the screen's state and, in this branch, `globalSearch.shown`, which RootView presents as an overlay.
  **Merge:** that line becomes `tab = .search`, and the overlay in RootView (`model.globalSearch.shown`) is deleted;
  `closeGlobalSearch()` then returns to the place search was opened from (or does nothing: the bar is the way out).
- Opening a result (`ReaderModel.openSearchResult(_:wide:)`) closes search in Tall and goes to the result's place; in Wide
  a paper, chat or collection is shown beside the list (`globalSearch.picked`) and search stays.

## What is searched

| Source | Index | Fields (weights: title 6, tags 3, notes 2, body 1) | Opens |
|---|---|---|---|
| Library papers (metadata and the text of readings saved here) | the Library's `search-index/`, through `LibrarySearchEngine.run` (unchanged: results agree with the Library's field) | as the Library | `select(paper)`, with Find in paper for a match in its text |
| Conversations | `everything-index/` | title · paper title · the passage it began from | `openConversation` |
| Messages (questions and answers, every branch) | `everything-index/` | body: readable text (`SearchText.chat`) | the chat, its branch, **scrolled to the message and marked** |
| Diagrams, visual answers, figure breakdowns | `everything-index/` | title · labels and notes (Mermaid syntax left out) | `openDiagram` |
| Kept equation / figure / paper explanations | `everything-index/` | label and paper · symbols or parts or Key concepts · summary · the rest | `openExplanation` (the kept answer, no request) |
| Snippet collections | `everything-index/` | name | `openNote` |
| Snippets | `everything-index/` | collection name, paper title, section, label (tags) · comment · quotes, reading text under a region, recognised text | `openNote(id, entry:)` |
| Feed's current page | memory (`MemorySearch.match`) | title, abstract, authors, reason | the Feed with its details |
| Tags | memory (prefix of each word) | the Library's tags with counts | `showLibraryPapers(taggedWith:)` |
| Settings | memory (prefix of each word of the title or its other words, never the ⓘ text) | `GlobalSearchSettings.rows` | Settings scrolled to the row, tinted; Account, Your AI usage and About open their page |
| The open paper ("In this paper") | memory (`MemorySearch.passages`) | its reading's blocks | the paper at the block, then Find |
| ML paper search | network, only from its row | — | `searchPapers(q)`, the Library in ML scope |

Kept explanations are on the device that made them (they are not synced); the ⓘ says so.

## The everything index

`EverythingIndex` (Core, `GlobalSearch/`) wraps `FullTextIndexStore` with the namespace `everything-index`: its own folder
`<account>/everything-index/` beside `search-index/`, and its own associated data
(`science-reader/everything-index/{manifest,segment}/v1/<account>[/<id>]`), so a file of one index never opens as the other.
Same sealing: AES-GCM under the account's local-store key, complete file protection, excluded from backup, removed with the
account folder on account deletion. One **metadata-part document per item**, so no per-item text file is written; excerpts
come from the source (in memory: `PrivateState`, `NotesState`; one sealed read for an explanation, `ExplanationCache`).

Each item's kind, paper, container (conversation or collection), date and whether the reader wrote it are kept beside its
words in the **sealed manifest** (`FullTextDocument.info`, the manifest's `m` key), not in a separate `catalog.bin` as the
proposal sketched: one atomic write instead of two. Group IDs are `<kind>:<id>` (an entity or event ID, or a kept
explanation's file digest). Recent searches are `recent.bin` in the same folder, sealed with their own associated data
(at most 10 kept, 5 shown, never in UserDefaults).

**Incremental.** `EverythingIndexer` (app) builds stubs for every item from the sources (values captured on the main actor)
and rebuilds only those whose fingerprint changed: a message is an immutable event (its ID and status), an explanation a file
and its date (`EquationResultStore.fileStamps()`, no decryption), the rest their words. Removed items (tombstones, deleted
conversations with their messages, merged deletions from another device, pruned explanations) leave the index in the same
commit. Triggers: every `privateState` publication (local writes and sync merges), kept explanations, recognised snippet
text, library size changes. Commits are coalesced: 2 s after the last change, at once after 64 changes, and when the app
goes to the background; 512 items a commit while building, with a progress line ("Indexing chats and explanations · 45%")
when a pass has more than 200. A running search reruns after each commit. Streaming answers are indexed once saved.

**Versions.** `FullTextTokenizer.version` 2 rebuilds both indexes once (the Library's from its encrypted readings, as
before). `SearchItem.format` is in every fingerprint, so a change to an item's fields reindexes all items.

**Memory and sign-out.** Decrypted segments are in memory only, dropped on a memory warning. Sign-out detaches the indexer,
closes the index with the account's other writers, clears the screen, its rows and the explanation cache, and removes ML
paper search's cached results. The sealed files stay with the account's other sealed local data (as `private-state.enc`
and `search-index/` do) and are deleted with the account.

## Tokenizer v2 (both indexes)

| Input | v1 | v2 |
|---|---|---|
| `α`, `\alpha`, `alpha`, `Α`, `𝛼` | α / alpha / alpha | all `alpha` (every Greek letter is its name; `ϵ ε \varepsilon` → epsilon, `ϑ` → theta, `ς Σ` → sigma, `µ` → mu) |
| `\mathrm{softmax}(QK^\top)` | mathrm softmax qk top | softmax qk (layout commands dropped without taking a position; their arguments kept) |
| `∇θ`, `∂L`, `∞`, `∑`, `∏`, `∫` | θ, l | nabla theta, partial l, infinity, sum, prod, integral (`\infty`, `\int` agree) |
| `α̅ₜ`, `θ2`, `βVAE` | αt, θ2, βvae | alpha t, theta 2, beta vae (split where Greek meets Latin or a digit) |
| compounds, IDs, numbers | parts + joined; `2106.09685`; `0.5` | unchanged (`α-divergence` → alpha, alphadivergence, divergence) |

A Greek letter or symbol typed last is never a prefix ("α" doesn't match "alphafold"). Snippets' own search uses the same
tokens, so `\sqrt` and `\frac` are no longer words there either. A snippet's resume point is never at a LaTeX command.

**Readable text.** `SearchText.chat` turns a message into what the reader sees: Markdown marks, figure-part markers, `[¶N]`
citations and the sources list removed; links as text and address; tables' cells joined; inline and display math through
`SearchText.math` (Greek letters and symbols as characters, a transpose as ⊤, layout commands dropped). It is a light
line-based pass (0.12 ms an answer), not the transcript's parser (0.4 ms). Diagrams: Mermaid labels and messages,
visual answers' text, figure breakdowns' parts and notes.

## Typos and partial results

Only when nothing matches: each word of 4+ letters that no index holds is replaced by the closest indexed word — one edit
(two from 8 letters; insertion, deletion, substitution or a swap), the nearest first, then the one in most documents — over
both indexes' dictionaries (`FullTextTypos.correction`): `atention` → attention, `softmx` → softmax, `difusion` → diffusion,
`transfromer` → transformer, `regularisation` → regularization. The screen says "No exact matches · showing attention".
Still nothing with two or more words: results with some of the words, most words first, each with its strength ("67%");
"Results with some of your words".

## Ranking and grouping

- Within a group: BM25F with the Library's field weights, × 1.3 when the query's words are adjacent in the item (an extra
  phrase query, even unquoted), × 1.3 for the reader's own questions, × up to 1.2 for recency (linear over 90 days).
  Papers keep the Library's ranking.
- Groups in a fixed order, never mixed: Passages (scoped), Papers, Chats, Explanations, Snippets, Diagrams, Feed, Tags,
  Settings. Empty groups are hidden. All shows each group's best 3 and "See all N".
- All collapses Chats to one row per conversation (the conversation itself when its title matched, else its best message)
  with "+N more in this chat", and Snippets to one row per collection likewise. A chip lists every item, uncollapsed,
  50 at a time (the next page loads at the end of the list); its header says "N matches in M chats".
- Rows have fixed heights: one title line with matched words marked, a quiet line (who and when, or the paper), and two
  reserved lines for the excerpt (`SearchHighlighter`'s excerpt with ranges in Find's yellow, as `SearchMatchLine`).
  Papers and partial results show the match strength; other rows show the excerpt alone (a "title, full text" label means
  little for a chat message). The excerpt comes from the field the index found the most of the words in.

## The screen

Empty: recent searches (Clear) and up to 5 recently opened (papers read here, chats used, collections edited, explanations
kept; data the app already has). An ⓘ after the field says what is searched and that it stays on the device. As you type: a
search per keystroke, no debounce, one worker at a time with the latest words pending (`GlobalSearchCoordinator`, the
Library coordinator's pattern); results stay on screen until the next arrive (no blanking). Chips appear once there is a
query. "In this paper" is a removable token in the field when opened with a paper. The last row is always "Search ML papers
for “…”", with the offline line when offline. Return opens the first result and remembers the words; Escape and Cancel
close. VoiceOver: group titles are headers; each row is one element ("Chat message. Seabirds and their flight. You · 3 days
ago. …") with a hint; the result count is announced a second after typing stops.

Wide and Mac: the list (36% of the window, 320–440 pt) beside the picked result: the paper (`PaperView`), the chat
(`ChatView`) or the collection (`NoteDetailView`); diagrams, Feed, tags and Settings go to their places. The divider is
fixed for now (follow-up: a `SlotArrangement.search` divider kept as `wide.divider.search`, with the places branch).

## ML paper search cache (privacy fix)

Before: each query's results for 24 h as plaintext JSON in `Caches/arxiv-search/<sha256>.json`. Now `SealedCacheFiles` in
`Caches/arxiv-search/<account>/`: AES-GCM under the local-store key, associated data binding account, cache and file name,
complete file protection, excluded from backup; in memory only while signed out. Sign-out removes the folder; plaintext
files an earlier build left are removed at activation and sign-out.

## Measurements

`swift run -c release FullTextBenchTool everything owner heavy`, or opt-in
`EVERYTHING_BENCH=owner,heavy swift test -c release -Xswiftc -enable-testing --filter EverythingBenchTests` (asserts p95 < 100
ms). A deterministic synthetic corpus (`EverythingBench.corpus`): Zipf-like function words, ML vocabulary with compounds,
model names, arXiv IDs and Greek letters, 14,000 rare words, equations in LaTeX and Unicode; messages alternate questions
and 2–4 paragraph answers (a third with display math). M-series Mac, release build, 2026-10-25, while other agents loaded
the machine (load average 9–70):

MEASUREMENTS_TABLE

"Grouped + excerpts" is what a keystroke costs for the everything index: the query, ranking, grouping and collapsing every
hit, and excerpts for each group's first three rows. The Library's papers run alongside through their own engine (measured
11–18 ms at 2,000 papers, NATIVE_LIBRARY_SEARCH.md). Not measured on a phone (paused); the proposal's estimate is 1.5–2× this
Mac for an A15–A12.

## Tests

- Core (`swift test`): `GlobalSearchTests` (tokenizer v2, typos, ranking boosts, grouping and collapse, chips, scope,
  partial, excerpt ranges, incremental add/replace/remove, nothing plaintext on disk in UTF-8 or UTF-16 including paper IDs,
  another account's key or the Library's namespace can't open it, closing, recent searches, the sealed ML cache, chat and
  diagram text, Settings matching), `EverythingBenchTests` (the corpus; the opt-in budget), `NoteSearchTests` (v2 tokens).
- App (`ScienceReaderTests/GlobalSearchAppTests`, `DeviceSearchTests`): the indexer over a real `PrivateState` (writes,
  tombstones, nothing re-committed when unchanged), the engine (collapse, chip, diagrams, tags, Settings, typo, partial),
  the router for each kind, Wide's picked result, sign-out's reset, every Settings row in `SettingsView`; the ML cache sealed
  and removed at sign-out.
- UI (`ScienceReaderUITests/GlobalSearchJourneyTests`, slow, opt-in, one iPhone Simulator): typing shows grouped results,
  chips and a typo's correction; a chat result opens the chat at its message; an explanation result opens it; In this
  paper; the ML row. Fixture `--search-fixture` (a kept equation explanation, "Zanzibar").

## Not done (phase 1 leftovers for the wiring, and phase 2)

- Wiring into the bar, the More screen and the Wide 🔍 circle (navigation branch); Wide's draggable divider; ↑/↓ to move
  the selection in results with a hardware keyboard; a model-held scroll anchor so 🔍 returns to the same place in the list.
- Phase 2 (proposal): exact passages for a paper hit outside the scope (today: Find with the words), All chats' field
  through this index, podcast transcripts, uploaded PDFs' text layer.

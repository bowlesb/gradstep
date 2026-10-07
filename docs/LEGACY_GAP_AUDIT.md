# Legacy gap audit: Science Reader web app → Gradstep

Status: read-only source audit, 2026-10-06. Compared `reference/web/` (archival Next.js app, every page, component, API
route, `lib/`, worker, docs and README) with `apps/apple/`, `supabase/`, `apps/admin/` and `docs/`. Nothing was built,
run or deployed, so every Gradstep finding below comes from reading the source, not from watching the app run. Some
gaps are deliberate design choices; those are listed separately so nobody re-adds them.

Already being worked on tonight, so not proposed again: topic tags, the library table with a column chooser, the All
chats table, self-healing downloads and the macOS app. Legacy details those efforts might miss are in
[Notes for tonight's work](#notes-for-tonights-work).

Effort: **S** ≤ 1 day · **M** 1–3 days · **L** more than that, or it needs a migration plus server and app changes.
Legacy paths are relative to `reference/web/`. Gradstep paths are relative to the repository root.

## Top 10 gaps, ranked

| # | Gap | Impact | Effort |
|---|---|---|---|
| 1 | Conversations aren't linked to the passage they came from: no "Go to passage", no marks in the paper | High | M |
| 2 | Papers named in an answer can't be opened or added (links don't work; no batch add from chat) | High | M |
| 3 | Only arXiv papers can be added: no PDF upload, no general URL, no share sheet, one ID at a time | High | M–L |
| 4 | Markdown tables in chat show as raw pipe text | High | M |
| 5 | iPad: the paper can't be read full width; the chat column can't be resized or hidden | Medium–high | S–M |
| 6 | No figure gallery for a paper | Medium–high | S–M |
| 7 | No find in paper | Medium | S |
| 8 | Library search has no relevance order or word-form matching | Medium | S–M |
| 9 | No progress shown while the assistant searches or adds papers | Medium | S–M |
| 10 | Contents is a flat list with no section levels | Medium | S |

### 1. Conversations linked to their passage

**Status 2026-10-07:** built (Simulator-verified); see [the decision](DECISIONS.md#passage-linked-conversations-owner-asked-2026-10-07-agent-decisions-all-reversible).

- **Legacy:** each chat stored `highlight_text` and `highlight_anchor` (`lib/db.ts:80-90`). Passages you had asked
  about were underlined in the paper, and tapping one opened its chat (`components/MarkdownReader.tsx:168-184`,
  `app/page.tsx:1121-1144`). The chat header had **Go to Selection** (phone) or **Selected Text** (desktop), which
  scrolled the paper back to the passage after waiting for the reader to be ready (`components/ChatPanel.tsx:605-636`,
  `691-714`; `app/page.tsx:1334-1358`). History rows showed the quoted passage, and tapping the quote jumped to it
  (`ChatPanel.tsx:1189-1215`).
- **Gradstep today:** a selection is turned into quote text and folded into the prompt
  (`apps/apple/ScienceReader/ReaderModel.swift:1929-1957`). The conversation's title is the first 100 characters of
  that prompt (`:1993`), so selection chats are titled "Explain in plain terms, including any symbols: …". The paper
  shows no marks, and the chat offers "Return to paper" but not "go to passage". `docs/UX_PARITY.md:25,78` lists this as
  required but not implemented. The encrypted event format already has an `anchor: TextAnchor` field (artifact, quote,
  prefix, suffix, element ID) that nothing writes (`apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/PrivateState.swift:4-40`).
- **Impact:** this is the paper ↔ chat loop the old app was built around. Without it, you can't find the question you
  asked about a passage.
- **Approach:** on a selection action, write a `TextAnchor` on the conversation event: manifest/artifact, first block
  ID as `elementID`, quote, and about 32 characters of prefix and suffix. The anchor is encrypted like the rest of the
  event, so this adds no format version. Add **Go to passage** to the chat's title area and "…" menu, reusing the
  bridge's heading-jump and Back mechanism. Have the bridge underline the anchored blocks for the open artifact;
  tapping one opens its conversation. When the block ID doesn't resolve (a different artifact), fall back to the
  legacy text-search cascade (see [Worth porting](#worth-porting-as-is)). Title these chats "Explain · ‹quote›".

### 2. Act on papers named in an answer

- **Legacy:** chat had an `ingest_paper` tool in every chat, batching up to 10 papers ("add #2 and #5")
  (`app/api/chat/route.ts:177-206`, `765-821`; `lib/paper-search.ts:281-305`). **Similar** searched both your library
  and the web, so answers said what you already had (`app/page.tsx:799-800`; `search_library` at
  `route.ts:207-222`, `857-884`). Links in answers opened.
- **Gradstep today:** links in an answer are deliberately shown as text, not followed
  (`apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/ChatRichText.swift:179-184`). **Related** lists 4–8 papers
  with arXiv/DOI links (`supabase/functions/_shared/chat.ts:165`), but you can't open or add any of them. `add_paper`
  is only offered on the **Add paper** selection action, for one paper (`_shared/chat.ts:177`, `336-339`). Only the
  "Sources:" list can be tapped (`apps/apple/ScienceReader/Views/ChatRichTextView.swift:124-156`).
- **Impact:** the discovery loop (Related → add the good ones) dead-ends. Today you would have to copy each ID into
  Add by hand.
- **Approach:** do it on the device, with no model call: after an answer completes, pull arXiv IDs and DOIs out of
  its text and show a **Papers in this answer** list under it, styled like Sources. Each row gets Open (with
  confirmation, as Sources does), **Add to library** (existing `v2_begin_import` for arXiv, or `add-reference` for a
  DOI) and an "In your library" mark from `librarySourceIDs`. A general-chat "add these papers" tool can come later.

### 3. Add papers that aren't on arXiv

> **Update 2026-10-07:** built (not deployed): Add takes a DOI or any link, PDFs upload from Files or by drag and
> drop, failed web imports can be downloaded on the device, and a Share extension queues PDFs and links. Bulk folder
> import is not done. See [PDF uploads](architecture/PDF_UPLOADS.md).

- **Legacy:** the upload sheet took a dropped or chosen PDF, or any PDF URL (`components/UploadModal.tsx`,
  `app/api/upload/route.ts`, `app/api/ingest/route.ts:15-104`), plus bulk folder import (`ingest-local.sh`). External
  search returned Semantic Scholar open-access PDFs as well as arXiv (`lib/paper-search.ts:357-396`).
- **Gradstep today:** Add accepts only "arXiv link or ID" (`apps/apple/ScienceReader/Views/RootView.swift:1028-1030`,
  `ReaderModel.swift:1451-1459`), and search covers arXiv works only. Papers off arXiv arrive only indirectly, through
  a reference's Add to library or the chat's Add paper (OpenAlex web import). Upload sessions are designed but not
  built (`docs/architecture/DATA_MODEL.md:61-63`).
- **Impact:** high for ML readers: OpenReview submissions, workshop and proceedings PDFs, journal papers and
  colleagues' drafts can't be added directly.
- **Approach, in stages:**
  - **S:** paste several IDs or links at once.
  - **M:** accept a DOI, an OpenReview or proceedings URL, or any `https` PDF link in Add, through the existing
    hardened web import (`supabase/functions/_shared/web-source.ts`), converted privately.
  - **M:** a Share extension (Safari → Gradstep) for the same path.
  - **L:** private PDF file upload with the designed upload session.

### 4. Tables in chat

- **Legacy:** GFM tables rendered as real tables, with math typeset in the cells (`components/ChatPanel.tsx:918-924`).
- **Gradstep today:** a Markdown table becomes monospaced pipe text and cell math isn't typeset
  (`ChatRichText.swift:122-139`; `docs/architecture/NATIVE_CHAT_RENDERING.md:6`). This is listed under "Still
  required" in `docs/IMPLEMENTATION_STATUS.md` but has no owner.
- **Impact:** comparison tables (methods × benchmarks) are among the most common ML answers, and they are unreadable
  on a phone.
- **Approach:** parse header, separator and rows into a `.table` block. Render it as a native `Grid` inside a
  horizontal `ScrollView`, reusing `ChatRichTextView`'s inline math for each cell. Keep the pipe-text form for
  streaming and partial rows so text doesn't jump while it streams.

### 5. iPad: full-width paper and a resizable chat

- **Legacy:** the desktop Reader was a resizable 50/50 split where either pane could be collapsed, with "Show PDF" /
  "Show Chat" handles (`app/page.tsx:1843-2016`, `components/CollapseHandle.tsx`). On a tablet the paper filled the
  screen and a **Chat** button switched to the chat (`app/page.tsx:1612-1841`).
- **Gradstep today:** at widths of 850 pt and up, Reader always puts a chat column of 320–400 pt beside the paper
  (`apps/apple/ScienceReader/Views/RootView.swift:13`, `168-171`). There is no way to read the paper alone on a
  full-screen iPad, and no way to widen the chat. `UX_PARITY.md:15` asks to preserve "panel controls".
- **Approach:**
  - **S:** a Hide/Show chat control in the Paper "…" menu and toolbar.
  - **M:** a draggable divider, with the chosen width remembered.

### 6. Figure gallery

- **Legacy:** a **Figs** button opened a grid of every figure with its number and caption. A figure opened full
  screen with previous/next, pinch and double-tap zoom, a caption sheet and **Go to figure in paper**
  (`components/FigureViewer.tsx`: gallery 630-783, gestures 102-250, caption 473-625; `app/page.tsx:1260-1293`).
- **Gradstep today:** tapping a figure in the text opens just that figure in a sheet
  (`apps/apple/ScienceReader/Views/PaperView.swift:232-247`, `675-692`; `apps/apple/ScienceReader/Resources/reader-bridge.js:653-663`).
  There is no gallery and no paging between figures.
- **Impact:** skimming the figures is a core way of triaging a paper.
- **Approach:** the bundle index already lists every figure with its block ID, caption and alt text. Add **Figures**
  to the Paper "…" menu: a grid of verified images with captions. Its detail view pages through figures and has
  **Show in paper**, which jumps by block ID using the citation Back control.

### 7. Find in paper

- **Legacy:** the browser's find (⌘F) searched the paper's iframe. The browser provided this, not app code.
- **Gradstep today:** `PaperWebView` doesn't enable WebKit's find interaction (`PaperView.swift:432-462`).
- **Approach:** set `isFindInteractionEnabled`, add **Find in paper** to the Paper "…" menu, and bind ⌘F. Check that
  find highlighting doesn't disturb the saved reading position.

### 8. Library search: relevance order and word forms

- **Legacy:** PostgreSQL full-text search with weights (title A, authors B, abstract and keywords C, venue D) and
  results ordered by rank. It accepted quoted phrases, `OR` and `-exclusion`, matched word stems ("transformers" finds
  "Transformer"), and fell back to `ILIKE` (`lib/db.ts:43-55`, `409-441`).
- **Gradstep today:** whitespace-separated terms must all appear as substrings, and results follow the current sort
  (Recent by default), so a paper whose title matches can sit below papers that match only in the abstract
  (`apps/apple/ScienceReader/Services/LibrarySearchCoordinator.swift:100-144`). Plurals and other word forms don't match.
- **Approach:** while a query is active, order by a field-weighted score (title > authors > topics > abstract, then
  the chosen sort as tie-breaker). Match on a folded, lightly stemmed form (strip a trailing s/es). Support quoted
  phrases. Show no percentage: `DATA_MODEL.md:55` rules it out.

### 9. Progress while the assistant searches or adds papers

- **Legacy:** the server streamed `status` events such as `Searching: "…"`, "Reading results…", `Ingesting paper:
  "…"` and "Queued 3/5 papers", and the UI showed them under the partial answer
  (`app/api/chat/route.ts:666-677`, `757-831`; `app/page.tsx:676-686`).
- **Gradstep today:** the stream has only `delta`, `diagram`, `done` and `error` events
  (`supabase/functions/_shared/chat.ts:253-256`). A Related answer (14–16 s, up to 5 searches) shows a placeholder,
  then goes silent between search rounds.
- **Approach:** add a `status {kind: "searching", query?}` event for each search round and for the Add paper lookup.
  The app shows it as a one-line footnote under the streaming answer. The query text goes only to its own device's
  stream; server logs keep counts only, as they do now. Installed builds already ignore unknown events
  (`apps/apple/ScienceReaderCore/Sources/ScienceReaderCore/ChatStream.swift:185`, `default: return nil`).

### 10. Contents hierarchy

- **Legacy:** Contents was indented by heading level. When Mathpix flattened every level, the depth was inferred from
  the section numbering (Roman numeral, then capital letter, then number). The title, "Abstract" and in-paper
  "Contents" headings were skipped; References was kept (`lib/mathpix-cleanup.ts:290-367`,
  `components/TableOfContents.tsx`).
- **Gradstep today:** the bundle index has heading levels, but the bridge drops `level` (`reader-bridge.js:381-385`)
  and the Contents sheet is a flat list of titles (`PaperView.swift:221-231`).
- **Approach:** pass `level` through, indent by its distance from the shallowest level, skip the title and Abstract,
  and port `inferDepthFromNumbering` for flat outputs.

### Next tier (11–20)

| Gap | Legacy | Gradstep | Effort |
|---|---|---|---|
| Long papers are cut off without notice: OCR stops at page 80 | Converted the whole PDF (`lib/mathpix.ts`) | `page_limit = min(pages, 80)` (`docs/architecture/PAPER_PIPELINE.md:24`); the reader doesn't say so | S to say so ("first 80 of N pages"); M to convert the remaining pages |
| Explaining an equation uses a generic prompt | Dedicated prompt: prerequisites, overall message, each symbol, notation conventions in ML (`components/MarkdownReader.tsx:786-796`) | "Explain in plain terms, including any symbols: ‹LaTeX›" (`ReaderModel.swift:1932`) | S: use the legacy prompt when the selection is a single equation |
| Answer style changed | "Thorough… define background terms… prefer longer, educational responses" (`app/api/chat/route.ts:125`) | "Lead with the answer… keep answers focused" (`_shared/chat.ts:151-154`) | S, but **owner decision**: longer answers cost more credits |
| Diagrams fail more often than they need to | Prompt spelled out Mermaid label rules (ASCII only, quote labels that contain punctuation) and checked the syntax with `mermaid.parse` before saving (`route.ts:51-82`, `109`) | No syntax rules in `DIAGRAM_INSTRUCTIONS` (`_shared/chat.ts:170-172`); a broken diagram shows its source | S: port the rules text. M: validate on the server and give the model one retry round |
| "Why it matters" may search the web | Relevance was "Using ONLY the paper's content (do NOT search the web)" (`app/page.tsx:798`) | Web search tool is offered (`_shared/chat.ts:339`) | S: `action: "relevance"` leaves search out |
| No actions when text is selected in an answer | Define, Relevance, Ingest and Similar worked on chat text too (`ChatPanel.tsx:291-349`, `838-881`) | Plain system text selection only (`ChatRichTextView.swift:26-64`) | M |
| A paper's own conversations aren't shown when you open it | Opening a paper showed that paper's History tab: chats, passage, date, message count (`app/page.tsx:516`; `ChatPanel.tsx:1126-1231`) | Only the global All chats list (`RootView.swift:716`) | S once the All chats table exists: filter it to "This paper" |
| Assistant can't see your library | `search_library` tool; general chat could answer "what do I have on X" (`route.ts:207-222`) | None | M. Library membership is server-visible, but sending it to Anthropic needs consent copy |
| Hardware keyboard on iPad | Enter sends, Shift-Enter adds a line, Esc closes overlays (`ChatPanel.tsx:364-374`, `app/page.tsx:224-236`) | Only Esc to dismiss the keyboard (`RootView.swift:699`) | S: ⌘↩ to send, Esc on sheets, ⌘F (see #7) |
| No way to invite or manage accounts | AdminPanel created and deleted users (`components/AdminPanel.tsx`) | Admin tabs: Overview, Usage, Processing, Reliability, Support (`apps/admin/src/main.tsx:77`). Sign-up is invite-only and testers need accounts made for them | S–M: an owner-only Accounts tab (invite, credit grant, disable). **Built 2026-10-07** (migration 028, `admin-accounts`; not yet deployed) |

## Notes for tonight's work

These are legacy details the in-progress efforts could easily miss.

- **Topic tags**
  - Legacy keywords came from a prompt asking for "5–10 ML/AI keyword terms… established terms from the ML
    literature, not paper-specific jargon" (`lib/metadata.ts:7-16`).
  - Focusing the search field showed the top 20 keywords by count as filter chips, with "Clear filter" and a
    "Filtered: X" placeholder; typing cleared the filter (`components/LibraryView.tsx:108-140`, `195-250`).
  - Rows showed up to 5 chips (`components/PaperTable.tsx:107-132`), and keywords were in search at weight C.
  - The legacy **Feed was built from these topics**: the top 8 keywords, papers from the last 30 days, each topic
    refreshed after 6 h, items pruned after 45 days, papers already in the library hidden, chips with counts, and
    "Updated Xh ago" (`lib/feed-discovery.ts`, `lib/db.ts:902-1023`, `lib/paper-search.ts:281-349`). Gradstep's Feed
    shows the newest 25 entries of an arXiv category's RSS feed (`ReaderModel.swift:1411-1418`;
    `supabase/functions/_shared/discover.ts:221-224`), which is far coarser than topics. Once tags exist, the feed
    should use them, for example through OpenAlex with a `from_publication_date` filter.
- **Library table**
  - Legacy columns were Title (with keyword chips), Authors, Year, Added, Last Opened and Status. A Match column
    appeared only while searching, and rows were ordered by rank (see #8).
  - A failed row's tooltip showed the actual error (`PaperTable.tsx:361-547`).
  - "Last opened" lived on the server, so all devices shared it. Gradstep's Opened and Progress are device-local
    only. The encrypted `position` event kind exists and is unused (`PrivateState.swift:4`), so syncing them is an M.
- **All chats table**
  - Legacy sorted by last activity, newest first. Columns: Paper, Chat, Type (Paper/General), Started, Last Active,
    Msgs. It had a **New general chat** button, and opening a paper chat opened the paper and its chat together
    (`components/AllChatsView.tsx`, `app/page.tsx:890-942`).
  - Gradstep's list currently follows `PrivateState.entities`, which **sorts by UUID string**, so the order is
    effectively random (`PrivateState.swift:186-189`, `RootView.swift:904-960`).
  - Also missing: a "This paper" filter, the passage excerpt (#1), titles without the prompt boilerplate, and delete
    or rename. No UI writes the tombstone kind.
  - All diagrams in legacy showed description, paper, chat and date, plus **Open Paper + Chat**
    (`components/AllDiagramsView.tsx`). Gradstep lists titles only.
- **Self-healing downloads**
  - Legacy let you save or remove each paper for offline use, up to 20, with an "Offline" badge and an offline pill in
    the header (`PaperTable.tsx:269-310`, `lib/offline-store.ts`, `LibraryView.tsx:412-438`). `UX_PARITY.md:27`
    requires "offline download actions".
  - Gradstep prefetches the newest 12 papers automatically (`ReaderModel.swift:1805-1825`) and has no keep/remove
    control. The local quota is 100 installations or 512 MiB with no automatic eviction
    (`docs/architecture/NATIVE_OFFLINE_BUNDLES.md:9`), and there is no UI to free space. A large library will hit the
    limit and stop downloading. Add per-paper Keep offline / Remove download and a storage line in Settings.
- **macOS app**
  - Carry over the desktop habits: Return sends and Shift-Return adds a line; Esc steps back (figure → gallery →
    close; `components/FigureViewer.tsx:252-267`).
  - Resizable, collapsible panes (#5), PDF drag-and-drop onto Add (`UploadModal.tsx` `handleDrop`), scroll-wheel
    zoom on figures, ⌘F (#7), and hover-revealed row actions.

## Full inventory

Status: **Have** (equal or better) · **Partial** · **Missing** · **Dropped** (removed on purpose; see below) ·
**Tonight** (covered by in-flight work).

| Area | Feature | Legacy | Gradstep | Status |
|---|---|---|---|---|
| Navigation | Phone tabs Feed / Library / Paper / Chat / Settings; Library first; Paper tab off until a paper is open | `components/MobileTabBar.tsx` | `RootView.swift` tab bar | Have |
| Navigation | Wide modes Feed / Library / Reader / Browse / General Chat | `app/page.tsx:25` | `ReaderModel.swift:12`, `RootView.swift:146-176` | Have |
| Navigation | Resizable and collapsible paper/chat panes; full-screen paper on tablet | `app/page.tsx:1612-2016` | Fixed chat column | Missing (#5) |
| Navigation | Esc closes overlays; Enter sends | `app/page.tsx:224`, `ChatPanel.tsx:364` | Partial | Partial |
| Library | Sort by title, authors, year, added, last opened (header click reverses) | `PaperTable.tsx:358-405` | `PaperTable.swift`; more sorts (Progress, Chats) | Have |
| Library | Ranked full-text search with stemming and operators | `lib/db.ts:409-441` | Substring AND, no ranking | Partial (#8) |
| Library | Keyword chips on rows and as a filter | `LibraryView.tsx:108-250` | Topics column/toggle; no filter | Tonight |
| Library | Delete paper with confirmation; delete a queued item | `PaperTable.tsx:311-349`, `app/page.tsx:1093` | Remove, Archive, swipe (`LibraryTableView.swift:216-276`) | Have |
| Library | Import status badges; failure reason; Retry failed; queue summary | `PaperTable.tsx:52-85`, `LibraryView.tsx:582-627` | Progress column, step timer, Retry/Cancel per item | Have |
| Library | Service-degraded banner (Mathpix, LLM, search) | `lib/api-health.ts`, `LibraryView.tsx:532-580` | Admin Reliability and workflow checks; nothing shown to users | Partial (low) |
| Library | Empty state | `LibraryView.tsx:651-670` | `ContentUnavailableView` plus sample | Have |
| Library | Last opened shared across devices | `lib/db.ts:460-466` | Device-local only | Partial |
| Library | Edit or fix metadata (chat `fix_metadata`, `/api/backfill`, `/api/reprocess/metadata`) | `route.ts:885-933` | None (source metadata from arXiv/OpenAlex) | Missing (low) |
| Add | Upload a PDF (drag and drop) | `UploadModal.tsx`, `api/upload` | None | Missing (#3) |
| Add | Any PDF URL; batch URLs; local folder | `api/ingest/route.ts`, `ingest-local.sh` | arXiv ID or link only, one at a time | Missing (#3); folder import Dropped |
| Add | External search (Semantic Scholar + arXiv, PDFs off arXiv included) | `lib/paper-search.ts:357-396` | arXiv search ranked with OpenAlex | Partial |
| Add | Add from search without leaving it | `PaperTable.tsx:156-225` | `DiscoveryRow` stays in search | Have |
| Add | Duplicate detection | chat `delete_duplicates` | Source identity and "already in your library" | Have (differently) |
| Feed | Topics from the library's keywords; Semantic Scholar, last 30 days | `lib/feed-discovery.ts` | arXiv category RSS, newest 25 | Partial (tonight's tags) |
| Feed | Topic chips with counts, "All", Updated Xh ago, citation counts | `components/ResearchFeed.tsx` | Category chips; Refresh; no counts, citations or age | Partial |
| Feed | Add, then "See in Library" | `ResearchFeed.tsx:350-366` | Add stays in place; table and list layouts | Have |
| Reader | Selection actions Define / Relevance / Similar / Ingest | `MarkdownReader.tsx:824-871` | Explain / Why it matters / Related / Add paper | Have (renamed) |
| Reader | Tap an equation, then Explain | `MarkdownReader.tsx:383-449` | Equation tap selects it, then Explain (`reader-bridge.js:631-637`) | Have; prompt Partial |
| Reader | Citation tap shows the reference with Ingest | `MarkdownReader.tsx:452-628` | Jump to the entry with Back; Open / Add / Copy (`PaperView.swift:256-323`) | Have (better) |
| Reader | Underlines for passages with chats; tap opens the chat | `MarkdownReader.tsx:168-184` | None | Missing (#1) |
| Reader | Go to passage from a chat | `ChatPanel.tsx:605-714` | None | Missing (#1) |
| Reader | Contents overlay with levels | `TableOfContents.tsx`, `mathpix-cleanup.ts:290-367` | Flat list | Partial (#10) |
| Reader | Paper and chat text size, remembered | `app/page.tsx:166-193` | Paper "…" and Settings, 14–26 pt | Have |
| Reader | Dark mode toggle in the reader bar | `app/page.tsx:1758-1781` | Settings › Theme (Light / Dark / Match device) | Have (moved) |
| Reader | Remembered reading position | None (reopened at the top) | Per artifact, restored after relaunch (device-local) | Have (better) |
| Reader | Find in page | Browser ⌘F | None | Missing (#7) |
| Reader | Native Copy / Look Up | Suppressed (`MarkdownReader.tsx:52-59`) | Kept | Have (better) |
| Figures | Gallery, paging, zoom, caption sheet, Go to figure | `components/FigureViewer.tsx` | Single-figure sheet on tap | Partial (#6) |
| Chat | Paper and General modes with a switch | `ChatPanel.tsx:765-813` | Segmented picker | Have |
| Chat | Streaming; Stop keeps the partial answer; interrupted marker | `app/page.tsx:590-779` | Sealed `.interrupted` answers; ownership fencing | Have (better) |
| Chat | Status lines for tool steps | `route.ts:666-831` | None | Missing (#9) |
| Chat | Markdown tables | `ChatPanel.tsx:918` | Monospaced pipe text | Missing (#4) |
| Chat | Math in `$` and `\(` styles | `ChatPanel.tsx:178-184` + KaTeX | SwiftMath plus a normalizer | Have |
| Chat | Selection actions on answer text | `ChatPanel.tsx:291-349` | None | Missing |
| Chat | Web search (Tavily) | `route.ts:475-521` | Tavily first, Anthropic backup, tappable Sources | Have (better) |
| Chat | Links in answers can be tapped | react-markdown `<a>` | Shown as text by design; only Sources open | Partial (#2) |
| Chat | Ingest papers from any chat, up to 10 per call | `route.ts:765-821` | Add paper selection action only, one paper | Partial (#2) |
| Chat | Library search tool | `route.ts:857-884` | None | Missing |
| Chat | Inline `live-html` visuals (HTML, SVG, KaTeX) | `ChatPanel.tsx:12-173` | Mermaid diagrams only | Dropped (security) |
| Chat | Diagrams saved, listed and opened | `route.ts:822-856`, `AllDiagramsView.tsx` | "View diagram", All diagrams, sandboxed Mermaid | Have (narrower) |
| Chat | Per-paper history: passage, date, message count | `ChatPanel.tsx:1068-1233` | Global list only | Partial (tonight + next tier) |
| Chat | All chats, newest first, with columns | `AllChatsView.tsx` | List in UUID order | Tonight (fix the ordering) |
| Chat | Empty-state prompts naming the paper | `ChatPanel.tsx:882-897`, `1011` | "Ask about this paper" with the paper under the title | Have |
| Chat | Composer grows up to 6 lines; New chat button | `ChatPanel.tsx:351-362`, `986-1001` | Vertical TextField; compose button | Have |
| Chat | Model fallback when overloaded (Sonnet → Haiku) | `route.ts:428-470` | One SDK retry; refusal fallback only | Partial (low) |
| Offline | Per-paper save or remove, cap 20, badge, offline listing | `lib/offline-store.ts`, `hooks/useOffline.ts` | Automatic newest-12 prefetch, encrypted store, badge | Partial (tonight) |
| Offline | "Offline" indicator | `LibraryView.tsx:412-438` | None | Missing (low) |
| Settings | Appearance, report a bug, account, sign out | `app/page.tsx:1362-1409` | Plus credits, delete account, recovery, sync | Have |
| Feedback | Bug report: note, up to 5 screenshots, past reports with status | `components/BugReportForm.tsx` | Report this screen; one screenshot; My reports with replies and status | Have (1 screenshot vs 5) |
| Admin | User management | `components/AdminPanel.tsx` | Usage, processing, reliability, support; no accounts tab | Partial (next tier) |
| Pipeline | Mathpix whole PDF, metadata by LLM, keywords | `lib/ingest.ts` | Pinned profile, credit holds, shared/private conversions; 80-page cap | Have; cap Partial |
| Pipeline | Reprocess all papers with new cleanup without paying again | `api/reprocess/route.ts` | Renderer revisions rerender retained raw OCR without new OCR | Have (better) |
| Pipeline | Stuck-job recovery, 3 retries | `lib/db.ts:735-767` | Cloud Run worker, loop breaker, metrics | Have (better) |

## Worth porting as-is

| Logic | Legacy source | Use in Gradstep |
|---|---|---|
| Find a passage by its text, falling back step by step: exact → first line → 80/60/40/25-character prefixes → 40-character needle with whitespace collapsed | `components/MarkdownReader.tsx:117-166` | Fallback for "Go to passage" (#1) when `elementID` doesn't resolve |
| Wait for "reader ready", then scroll, with a 5 s safety timeout | `app/page.tsx:1334-1358` | Already done natively for heading jumps; use the same pattern for passages |
| Infer Contents depth from numbering; skip title, Abstract and Contents headings | `lib/mathpix-cleanup.ts:290-367` | Contents sheet (#10) |
| Split a bibliography crammed into one paragraph at `(?=\[\d+\])` | `lib/mathpix-cleanup.ts:81-103` | Fallback in `reader-bridge.js` `lineRanges` when one line holds 3 or more `[n]` markers |
| Sentence-case ALL-CAPS table captions, keeping acronyms of 5 letters or fewer and Roman numerals | `lib/mathpix-cleanup.ts:161-199` | Renderer (`supabase/functions/_shared/reader/render.ts`, bump `RENDERER_REVISION`). Check how often real MMD captions are all caps first |
| Find in-paper "Contents" sections (over 100 characters with dotted leaders or numbered entries) | `lib/mathpix-cleanup.ts:105-123` | Collapse behind a disclosure rather than hide, since the old fully hidden version cost text |
| Repair URLs broken across lines ("https: //", "github. com") | `lib/mathpix-cleanup.ts:65-79`, `208-215` | Renderer link and text normalization, if MMD shows the artifact |
| Equation-explain prompt | `components/MarkdownReader.tsx:791-794` | Explain on an equation-only selection |
| Selection prompts: Relevance limited to the paper; Similar covering library and web | `app/page.tsx:795-803` | `action` handling in `_shared/chat.ts` |
| Mermaid label rules for the model, plus a `mermaid.parse` check that returns errors so the model can fix them | `app/api/chat/route.ts:51-82`, `109` | `DIAGRAM_INSTRUCTIONS` |
| Figure-number regex `(?:figure\|fig\.?)\s*([S]?\d+[a-z]?)` and tiny-image filter (under 80×80 px, under 30 px attributes, logo/icon names) | `lib/figure-extraction.ts:149-182` | Gallery labels ("Figure 3b") and skipping logo crops (#6) |
| Search field weights A/B/C/C/D | `lib/db.ts:43-55` | Ranking order for #8 |
| Feed refresh rules: per-topic staleness of 6 h, 1.1 s pacing, 429 backoff, 45-day prune, hide papers already in the library by lowercased title | `lib/feed-discovery.ts`, `lib/paper-search.ts:281-349`, `lib/db.ts:975-1023` | Topic-based feed after tags |
| Keyword-extraction prompt | `lib/metadata.ts:7-16` | Tonight's topic tags |
| Agent status strings | `app/api/chat/route.ts:666-831` | #9 |

## Deliberately not ported (do not re-add)

- **Pre-abstract figure hiding, generic adjacent-`div` merging and ordinal regex equation association**
  (`mathpix-cleanup.ts` steps 2c and 6; `embedLatexAttributes`). `docs/architecture/MATHPIX_PIPELINE.md` rules them
  out, and the MMD renderer doesn't need them. The `<br>` and hyphen fixes, CDN font stripping and inline-math
  promotion were artifacts of Mathpix's HTML output only.
- **`lib/word-splitter.ts`** (wordninja). It has no callers in the legacy app; it was dead code.
- **Local-network auth bypass, password accounts and first-user setup** (`middleware.ts`, `LoginForm.tsx`). These
  were replaced by Apple, Google and email-code sign-in.
- **Arbitrary server-local file ingestion** (`action: "ingest-local"`).
  `docs/architecture/OPERATIONS_AND_BILLING.md:139` forbids it.
- **Inline `live-html` visuals with arbitrary HTML or SVG in chat.** Narrowed to sandboxed Mermaid for security
  (`docs/architecture/CHAT.md#diagrams`).
- **Relevance percentage badge.** `DATA_MODEL.md:55` rules it out; ordering by relevance (#8) is still wanted.
- **PWA `screen.height` workaround and 11 px chat text.** `UX_PARITY.md:72` rules them out.
- **DeepSeek metadata provider; chat tools for metadata status and duplicate deletion.** These were operator
  utilities that the new pipeline's source identity and admin dashboard replace.

## Beyond legacy (noticed while auditing; not regressions)

- **Notes and highlights** are an agreed requirement (`docs/DECISIONS.md`: "notes, highlights"). The `note` event kind
  and `TextAnchor` already exist and nothing uses them.
- **Data export.** With device-held keys, the server can't export your chats. Exporting a conversation as Markdown,
  or a library as BibTeX, would let people take their work with them.
- **Cross-device resume.** Legacy didn't remember reading positions at all. Gradstep does, per device, and the unused
  `position` event kind would let it sync them.

# Global search and a "More" place (proposal, 2026-10-25)

**Status:** phase 1's search (section B) is built, as described in [GLOBAL_SEARCH.md](../architecture/GLOBAL_SEARCH.md)
(local, not released); the navigation (section A) is a separate branch.

Owner, 2026-10-25: *"One more feature - one of our UX issues is we have 6 icons but only room for 5. Lets change to the
way Slack does it. slack has three at the bottom, a [fourth] icon with the words More, and then if you click you get a
screen with the other three options. For the fifth, it's a search icon. For this, we need to build a global search
that cuts across everything - papers, AI equation explanations, snippets, everything. And have it be well thought out."*

This proposal covers the iPhone, iPad (Tall and Wide) and Mac apps, with notes for the paused browser reader. It names the
code it would change, and every number in it was measured on this Mac unless it is marked as an estimate. The
throwaway benchmark is described in the appendix and was not committed.

## Summary

- **Bar (iPhone):** `Library · Paper · Chat · More` in the capsule, and a round 🔍 beside it, as iOS 26 places its search
  tab. More opens a screen with three rows: **Feed, Snippets, Settings**. These three stay in the bar because the app
  opens to Library, and Paper ↔ Chat is the reading loop (about 25 code routes land in Paper or Chat; 2 land in Feed and
  3 in Snippets). Alternative: `Feed · Library · Paper`, with Chat under More.
- **iPad:** upright at full width, keep the six places you asked for on 2026-10-24 and add 🔍. Narrow windows use the
  iPhone bar. Sideways (Wide), the places menu already has room for all six, so it needs no More; a 🔍 circle sits
  beside it. **Mac:** the toolbar keeps its five places, gains a search field, and **⌘K** opens it.
- **Global search runs only on the device, over encrypted indexes.** Papers keep the existing full-text index (title,
  authors, tags, abstract, snippets and full text). A second index of the same kind, `everything-index/`, holds chat
  titles and messages, equation, figure and paper explanations, snippets with their recognised text, collections and
  diagrams. Settings, tags and the Feed's current page are searched in memory. ML paper search runs only when you tap
  its row, as today. Nothing new goes to the server.
- **Measured** (M1 Max, owner-scale and heavy synthetic corpora): an index query takes 0.1–6 ms, and 0.1–14 ms with
  ranking and highlighted excerpts. The new index is 3.8 MB on disk for 5,820 items and 10.8 MB for 21,450 items, using
  0.6–6 MB of memory. SQLite FTS5 is about as fast, but its database is plaintext (57 MB at the heavy scale), so it is
  rejected again, as on 2026-10-24.
- **Phases:** (1) navigation plus search over everything that already has text, about 12–16 agent-days; (2) exact
  passages, the "This paper" scope, podcasts and the text of uploaded PDFs, about 7–10 days; (3) a "Related" section,
  first from the public paper fingerprints with no new model (2–3 days), then an optional on-device embedder (8–12 days,
  sharing the interest index's model-download decision).

### Open questions (answers in a word)

1. **The bar's three:** "Library · Paper · Chat", with Feed, Snippets and Settings under More? *Recommend: yes.* (The
   other choice: "Feed · Library · Paper", with Chat under More.)
2. **iPad upright:** keep all six places plus 🔍 when they fit, or use the iPhone's bar? *Recommend: all six.* That keeps
   your 2026-10-24 decision, and Split View halves fall back to the iPhone bar.
3. **Settings on iPhone:** take it out of every ⋯ menu now that More holds it? *Recommend: yes.* That matches the iPad,
   where you called ⋯ "a confusing place for it".
4. **Keyboard on Search:** bring the keyboard up as soon as 🔍 is tapped, when the field is empty? *Recommend: yes.*
   Typing is the screen's only job. Returning to results that are already showing leaves the keyboard down.

## What this changes in earlier decisions

| Earlier decision | Effect |
|---|---|
| "No Search place on iPad (G6)", 2026-10-24: *"if I want a search, I could just go and search the library"* | Superseded by this request. 🔍 is a destination on every surface. The Library's own field stays (see "Existing searches"). |
| iPhone: "Settings as every ⋯'s last section" (2026-10-20) | Settings becomes More's third row. Removing it from ⋯ is open question 3. |
| iPad upright "six along the bottom" (2026-10-24) | Kept when the window is wide enough (open question 2). |
| `PlacesMenuButton` docs, "no Search" (`WideShape.swift:454-461`) | A 🔍 circle joins the places button in Wide. |

---

## A. Navigation

### A.1 Today (from the code)

The six places are `enum ReaderTab` (`ReaderModel.swift:7-17`): Feed, Library, Paper, Chat, `notes` (labelled
"Snippets") and Settings. `ReaderTab.phoneTabs` holds the first five. `ReaderTab.places` adds Settings on iPad only.
`ReaderModel.tab` defaults to `.library`, is not saved across launches, and sign-out resets it to `.library`
(`ReaderModel.swift:2544`). The app therefore always opens to the Library.

| Surface | What shows the places | Settings | Search today |
|---|---|---|---|
| iPhone, portrait and landscape (always Tall) | Custom glass capsule: 5 items, 58 pt tall, at most 520 pt wide (`RootView.tabBar`, `RootView.swift:139-166`; `TabBarItem`, `Chrome.swift:260`). It hides while the software keyboard is up. Paper is dimmed until a paper is open. | Last section of every ⋯ (`SettingsMenuSection`, `SettingsPresentation.swift:10-23`, used at 6 sites); it opens as a sheet | Library field with a Library / ML paper search switch; Snippets field; All chats field; Find in paper (⋯) |
| iPad Tall | Same capsule with 6 items: Settings is sixth, widened to 624 pt | Sixth item; opens as a sheet | As iPhone. ⌘F is Find in paper only (`PaperView.swift:714-720`). |
| iPad Wide | `PlacesMenuButton` (`WideShape.swift:462-511`): a 44 pt circle at the top left; one list of six rows | Sixth row; opens as a sheet | As iPhone. ⌘1…⌘5 and ⌘, are hidden buttons inside the places menu, so they work only in Wide. |
| Mac (Catalyst, always Wide) | NSToolbar segmented "Places", 5 segments (`MacToolbarController`, `MacSupport.swift:640-755`), and the View menu with ⌘1…⌘5 (`MacCommands.swift:85-92`) | ⌘, and ⋯; replaces the window's panes (`tab = .settings`) | ⌘F is Find in Paper while reading, otherwise Search Library; ⌥⌘F Search Library; ⇧⌘F Search ML Papers (`MacCommands.swift:69-81`) |
| Browser (paused) | Phone ≤ 640 px: `PhoneTabs` with the same five (`App.tsx:1063-1076`). Desktop: top nav (Library, Feed, Snippets, Chats). | Account menu › Settings… | One field: Library, ML, or a "rail" list off the Library; ⌘K |

No bar item carries a badge or progress today. The podcast mini-player stacks above the capsule.

### A.2 The bar: recommendation

```
 iPhone (Tall), any place                       iPad upright, full width (open question 2)
 ┌───────────────────────────────────────┐      ┌──────────────────────────────────────────────────────┐
 │                                       │      │                                                      │
 │  ╭──────────────────────────────╮ ╭─╮ │      │ ╭──────────────────────────────────────────────╮ ╭─╮ │
 │  │ 📚     📄     💬     •••      │ │🔍│ │      │ │ 📚     📄     💬     📡     ✂      ⚙        │ │🔍│ │
 │  │Library Paper  Chat   More    │ ╰─╯ │      │ │Library Paper Chat   Feed  Snippets Settings │ ╰─╯ │
 │  ╰──────────────────────────────╯     │      │ ╰──────────────────────────────────────────────╯     │
 └───────────────────────────────────────┘      └──────────────────────────────────────────────────────┘
```

- **The capsule holds four items; 🔍 is its own 58 pt glass circle, 8 pt to its right.** This is how iOS 26 draws a
  search tab, and it keeps "the fifth is a search icon" visually separate from the places. On a 393 pt iPhone each
  item keeps about 72 pt, as five do today (about 71 pt); on a 375 pt iPhone, about 67 pt. *Alternative:* 🔍 as a
  fifth item inside the capsule, labelled "Search".
- **Order** follows your sentence: three places, then More, then Search.
- **More's glyph** is a new `gradstep.more` (three dots, drawn like the other `GradstepSymbol`s) with the word "More".
  Its label tells it apart from the ⋯ screen-options circle.

**Which three stay in the bar**

| Evidence | Library | Paper | Chat | Feed | Snippets | Settings |
|---|---|---|---|---|---|---|
| What the app opens to | ✓ (default `.library`; sign-out resets to it) | | | | | |
| Code routes that land there (A.5 table) | 6 | about 15 (every `select(paper)`, citations, passages, snippet sources) | 10 (Explain, Continue in Chat, figure/equation/reference/snippet chats, Return to chat) | 2 | 3 | sheet |
| Used while reading | list ↔ paper | ✓ | ✓ (the Paper ↔ Chat loop) | | capture happens in Paper | |
| Mentions in OWNER_FEEDBACK.md (rough) | 54 | 121 | 94 | 63 | 16 | 18 |
| Already demoted on iPhone | | | | | | in ⋯ |

**Recommendation: `Library · Paper · Chat`.** These three are the loop you read in. Feed is the one real cost: it is
where For you (the interest index, your current priority) shows. Under More it is two taps.

**Alternative: `Feed · Library · Paper`**, with Chat under More. Contextual chats still open in place (every
Explain, Continue in Chat or Ask lands in Chat by itself, and Return to paper / Back to chat close the loop). What gets
deeper is starting a general chat and reopening the last chat.

### A.3 Per platform

- **iPhone:** the bar above. Settings leaves every ⋯ if question 3 is yes. That removes `SettingsMenuSection` from
  Library, Feed, Chat, Paper, Snippets and Listen ⋯ (`RootView.swift:670, 1248, 1685`; `PaperView.swift:1045`;
  `NotesViews.swift:235`; `PodcastViews.swift:166`).
- **iPad Tall:** if the window is at least 730 pt wide (6 × 104 pt + 8 pt capsule padding + 8 pt gap + 58 pt 🔍 + 2 × 16 pt margins), show all six places plus
  🔍. That covers every iPad upright, iPad mini (744) included. Narrower windows (Split View, Slide Over, Stage Manager)
  show the iPhone bar. This is UIKit's own tab bar rule: more places where they fit, More where they don't. If question
  2 is "iPhone's", iPad Tall shows the iPhone bar at every width.
- **iPad Wide:** the places menu keeps its single list of six rows, so it needs no More. A **🔍 circle (44 pt) sits right
  of the places button** in the top-left corner, in every view. `WideMetrics.placesReserve` goes from 52 to 104 pt for
  the leftmost row (the Library's field, the Feed's chips, and so on). That 52 pt of width is the only cost. No row is
  added, so the vertical budget is unchanged.
- **Mac:** keep the five-segment toolbar and Settings (⌘,). Add an `NSSearchToolbarItem` at the toolbar's trailing edge.
  Search results take the window as a two-slot place (A.4 and B.5). Shortcuts:
  - **⌘K** (new) focuses search everywhere, as the browser does already (`App.tsx:496`).
  - ⌘F, ⌥⌘F and ⇧⌘F keep their meanings.
  - Edit › Find gains "Search Everything… ⌘K".
- **Browser (paused):** phone widths would get the same bar, and the desktop's existing search field would become global
  search, with results in its left "rail" list. The browser's private data lives in its encrypted IndexedDB journal, so
  it needs its own sealed index (B.3 notes). Do this when browser work resumes.

### A.4 The More screen

```
 iPhone, More                                      iPhone, Feed opened from More
 ┌───────────────────────────────────────┐         ┌───────────────────────────────────────┐
 │                 More                  │         │ (For you)(Agents)(RLHF)…          (⋯) │
 │ ╭───────────────────────────────────╮ │         │                                       │
 │ │ 📡  Feed                        › │ │         │  …the Feed exactly as today…          │
 │ │ ✂   Snippets                    › │ │         │                                       │
 │ │ ⚙   Settings                    › │ │         │                                       │
 │ ╰───────────────────────────────────╯ │         │                                       │
 │                                       │         │ ╭──────────────────────────────╮ ╭─╮  │
 │ ╭──────────────────────────────╮ ╭─╮  │         │ │Library Paper  Chat  [More]   │ │🔍│  │
 │ │Library Paper  Chat  [More]   │ │🔍│  │         │ ╰──────────────────────────────╯ ╰─╯  │
 └─╰──────────────────────────────╯─╰─╯──┘         └───────────────────────────────────────┘
```

- **Layout:** one inset-grouped list, as in Slack. Each 52 pt row has the place's glyph in accent, its one-word name and
  a chevron, with no descriptions. The title is "More", inline in the system's own title bar, like Paper, Chat and
  Settings. Rows keep their `tab.*` identifiers (`tab.feed`, `tab.notes`, `tab.settings`); the list is `more.list`.
- **Opening a row:** Feed and Snippets become the current place exactly as today (`model.tab = .feed`). They are not
  pushed under More, and they have no Back button; the bar is the way out. **Settings opens as today's sheet** over
  the More list, and Done returns to the list.
- **The bar while in a More place:** More stays selected (accent), keeps its label, and VoiceOver reads "More, Feed".
  Tapping More again returns to the list, as a second tap on Snippets returns to its list today
  (`RootView.swift:151`).
- **Memory:** from another place, More always opens its list, as you described. The places themselves keep their state
  (A.5): the Feed's results and topic, the open collection.
- **Badges and progress:** none exist today on any bar item, and none are added. The "N waiting to sync" line stays at
  the top of Snippets, and import progress stays in the Library. A dot would say less than those lines and could go
  stale.

### A.5 State, routing and every place switch

**Model changes (small):**
- `ReaderTab` gains `.more` (the list) and `.search`.
- `barPlaces` is computed by width: `[.library, .paper, .chat]`, or all six on a full-width iPad.
- `morePlaces = [.feed, .notes, .settings]`. `phoneTabs` keeps its meaning for the Mac toolbar and View menu.
- The bar's selection is derived from `model.tab`:
  - a bar place → its item;
  - a More place, or `.more` → More;
  - `.search` → 🔍;
  - Settings presented → More on iPhone, or Settings on a full-width iPad.
- **No existing call site changes.** Every route below still sets the same `tab`; only the selection drawn in the bar
  differs.

| Route (file:line) | Lands in | Bar shows (iPhone) |
|---|---|---|
| Any `select(paper)` (`ReaderModel.swift:3324`): Library and Feed rows, `openLibraryResult`, `openLibraryPaper`, podcast "Open paper", deep link `openPaperLink` (`PaperShareMenu.swift:32`), `openSample`, device-model reading, kept explanations (`openExplanation`, 4789), AI usage rows | Paper (iPad Wide: Library/Feed with the paper on the right) | Paper |
| `goToPassage`, `goToCitedBlock`, `openNoteSource`, empty collection "Open Paper", `showEvidence`, reading mode from Settings, `promotePaper`, `openCompanion`, `toggleContentsPanel`, Discuss ✕, the divider drag | Paper | Paper |
| `returnToChat` 3542, `askAboutSelectedPaper` 3860, `openConversation` 3865, `openUnsentDraft` 3902, `continueInChat` 4171, `discussReference` 4180, `selectionAction` 4218, `askAboutEquation` 4511, `chatAboutNoteEntry` 4536, `askAboutFigure` 4813, `openMarkedConversations`, the explainers' "Continue in Chat" (`PaperExplainView:34`, `FigureExplainView:192`, `EquationView:271`) | Chat | Chat |
| `searchPapers` 2701 (author "Find papers by", Find similar, a tag's ML search, a deep link not in the library), `showLibraryPapers(taggedWith:)` 2707, `showLibrary` 3530, a vanished paper 3308, sign-out 2544, a chat mention's fallback (`ChatRichTextView.swift:670`), Mac Add Paper and Search | Library | Library |
| `openNote` (`ReaderModel+Notes.swift:265`), "Saved to…" Open (`SnippetCapture.swift:431`), `returnToNote` 4582, Settings › Your assets › Snippets (`RootView.swift:1889`) | Snippets | More |
| Podcast "Browse episodes" (`PodcastGenerateSheet.swift:242`), `showListBesidePaper` (Wide) | Feed | More |
| `openSettings` (`ReaderModel+Notes.swift:238`), Mac `showSettingsPlace` | Settings sheet (Mac: place) | More |
| `openAllChats` 1131 | Sheet (iPad Wide: Chat place) | unchanged |
| New: a search result (B.5) | its place | that place |

**State while switching.**
- *Kept by the model today:* the open paper and its reading position (`paperLocations`), the conversation and its
  draft, the Library's query, filters and sort, the Feed's results and pick, the open collection.
- *Not kept today:* the scroll positions of the Library, Feed and Snippets lists. Tall rebuilds each place's view on
  every switch (`destination(tab)` is a plain `switch`, `RootView.swift:175-193`), and on Tall the paper's web view is
  recreated, restoring its position.
- Phase 1 adds a model-held scroll anchor for the Search results list, so 🔍 returns to the same place in the results.
  The same anchor pattern can be applied to the Library and Feed lists separately; it is not needed for this request.
- Keeping each place's views alive (a ZStack) is not proposed. It would keep a web view per place in memory.

**Deep links, Continue in Chat and the figure/explainer flows** are unchanged. The universal link still opens the
paper or an ML search, and no new deep link is needed.

### A.6 Accessibility and input

- **VoiceOver:**
  - Bar items stay buttons with their text labels and the selected trait. 🔍 reads "Search"; More reads "More", with
    the open More place as its value. Both get the Large Content Viewer, as today.
  - More rows read "Feed, button".
  - Search results: group headings carry `.isHeader`, so the Headings rotor jumps between Papers, Chats, and so on.
    Each row is one element, for example "Chat message. ‘…why divide by root d k…’ In: Why does attention scale.
    3 days ago", with the hint "Opens the chat at this message".
  - The result count ("24 results") is announced once typing has paused for about one second.
- **Dynamic Type:** bar labels stay capped at xxxLarge with the Large Content Viewer (`Chrome.swift:266`). The More list
  and result rows grow freely; at accessibility sizes, a result's excerpt may take a third line. Filter chips scroll
  sideways.
- **Landscape iPhone:** still Tall, with the same bar. While the keyboard is up the bar hides (existing rule) and the
  search field's Cancel is the way out.
- **iPad Split View, Slide Over, Stage Manager:** the width rule in A.3 decides the bar. Wide/Tall still follows
  `LayoutShape.of(size:)`.
- **Hardware keyboard (iPad and Mac):**
  - ⌘K opens Search in both shapes. On iPad, ⌘K and the existing ⌘1…⌘5 / ⌘, move to a hidden button group on the root
    view, so they also work in Tall (today they live inside `PlacesMenuButton`, which exists only in Wide).
  - In results: ↑/↓ move the selection, Return opens it, Esc clears the field and then leaves Search.
  - ⌘1…⌘5 keep their places (⌘1 Feed … ⌘5 Snippets). Numbers name places, not positions, so nobody's habits change.

### A.7 What moves or goes away (each is a material change)

1. iPhone: **Feed and Snippets leave the bar** for More (requested).
2. iPhone: **Settings leaves every ⋯** (question 3).
3. iPad narrow windows: the iPhone bar replaces today's six-item capsule (question 2).
4. iPad Wide: the leftmost row starts 52 pt further right to make room for 🔍.
5. Mac: a toolbar search field and ⌘K are added; nothing is removed.
6. Nothing else moves. The Library's search field, the Library / ML switch, All chats' and Snippets' fields, Find in
   paper and the places menu all stay.

---

## B. Global search

### B.1 Sources

"Already text?" means plain text is on the device today. "Indexed?" means the existing full-text index (FTI) or
`NoteSearch` covers it.

| Source | Fields indexed | Lives today | E2EE / synced | Already text? | Indexed? | Opens | Phase |
|---|---|---|---|---|---|---|---|
| Library paper metadata | title; authors; tags (own, catalog, derived keywords, arXiv areas, ID); abstract; snippets' quote and comment (notes field) | Library cache rows sealed in `private-state.enc`; local PDFs are `local_paper` events | arXiv metadata and tags are visible to the service; a local PDF's title and tags are E2EE | yes | **FTI** (`FullTextLibrary.metadata`) | `openLibraryResult` (`ReaderModel.swift:3316`) | 1 (reuse) |
| Paper full text: arXiv HTML readings **and on-device model readings** | block text, equation LaTeX, figure captions/alt, table captions | `device-readers/`, `device-model-readers/` (128 each) | device only, sealed | yes | **FTI** body | paper + Find in paper prefilled (phase 2: the exact block) | 1 (reuse) |
| Uploaded PDF with no model reading | the PDF's text layer | `device-papers/` | device only | **no** (no PDFKit extraction exists) | no | paper | 2 |
| Conversations | title (topic, renamed or first question), display title ("Explain · …"), the anchored passage quote, the paper's title | `PrivateState` `conversation` events (in memory) | E2EE, synced | yes | All chats substring only (`ChatHistoryQuery.matches`) | `openConversation` | 1 |
| Messages: questions, answers, study turns, Explain and retired "Why it matters" chats, explainer follow-ups | text, after `ChatPreview.plain` strips `[¶N]`, figure markers and sources; LaTeX cleaned (B.3) | `message` events | E2EE, synced | yes (Markdown + LaTeX) | **answers are not searched anywhere** | conversation scrolled to the message (**new**: the transcript has row anchors but no "land on message" API) | 1 |
| Diagrams (Mermaid, visuals, figure breakdowns in chat) | title, node and edge labels, parts' labels and notes | `diagram` events | E2EE, synced | needs stripping (Mermaid/HTML) | no | `openDiagram` (1101) | 1 |
| **Equation explanations** | label ("Equation (7)"), paper title, symbols summary, each symbol's LaTeX and meaning, background text | `equation-answers/` (`EquationResultStore`, ≤ 400) | device only, **not synced** | yes | no | `openExplanation(subject)` → the kept answer in its paper | 1 |
| Figure explanations | label, paper title, walkthrough summary, part titles and text | `figure-answers/` | device only | yes | no | `openExplanation` | 1 |
| Paper AI Explainer | summary, Key concepts (names, lines, paragraphs), ideas, link labels | `paper-answers/` | device only | yes (`.text`) | no | `openExplanation` | 1 |
| Snippet collections | name | `note` events | E2EE, synced | yes | `NoteSearch` (prefix scan) | `openNote(id)` | 1 |
| Snippets | comment, quote, anchor quote, source title/authors/ID/section/label, the reading's blocks under a drawn region, **text Vision recognised in the image** | `note` events; OCR in `snippet-text/recognised.sealed` | E2EE (OCR and block text device-derived, never synced) | yes | `NoteSearch` | `openNote(id, entry:)` | 1 |
| Tags | your tags and the tag vocabulary | memory (`LibraryTags`, `TagVocabulary`) | as metadata | yes | no | `showLibraryPapers(taggedWith:)` | 1 |
| Feed (the current page) | title, authors, abstract, reason label | memory only (`feedResults`; the approved "last page kept" is not built here) | public | yes | no | `feedDetail` / `feedPickID` | 1 (scanned, not indexed) |
| Settings | row title, ⓘ text, a few synonyms ("dark mode" → Theme) | hand-written `Form` (`SettingsView`, `RootView.swift:1734-1982`); no row model | — | **no catalog** | no | Settings scrolled to the row (**new**) | 1 |
| Podcasts you downloaded | title, topic, chapters, transcript segments | `podcasts/podcast-downloads.enc` (≤ 100) | device only | yes | no | `play(episode, at:)` | 2 |
| Recommendations | — | in memory while the sheet is open; reasons not kept | — | — | — | added papers are library papers | not a source |
| ML paper search (arXiv, DataCite) | — | network | — | — | — | `searchPapers(q)`, only on a tap | 1 (existing route) |

Underlined passages ("chats on this passage") come from conversation anchors and are covered by the Conversations row.
Kept explanations are device-only today: one made on the iPad is not found on the iPhone. The search screen's ⓘ says so.
Syncing them is outside this proposal.

### B.2 Privacy

- **Everything is searched on the device.** Queries, results and the index never leave it. No new network call is made.
  ML paper search runs only when its row is tapped, and sends only the words, as today (to arXiv/DataCite from the
  device, or the server's DataCite path when `searchesOnDevice` is off).
- **The index is sealed like the stores it mirrors.** `EncryptedStore` keeps every row AES-GCM sealed inside SQLite
  (`private-state.enc`). The existing `FullTextIndexStore` seals:
  - every manifest, segment and text file with the account's local-store key;
  - with associated data bound to the account and the file (`science-reader/search-index/{manifest,segment,text}/v1/<account>[/<id>]`);
  - in a folder with complete file protection, excluded from backup, deleted with the account.

  The new `everything-index/` uses the same code under its own namespace. Decrypted segments exist only in memory,
  dropped on a memory warning (`LibraryFullTextIndexer` already does this) and at sign-out.
- **Recent searches** are a sealed file in the same folder, never UserDefaults.
- No query or result text goes into logs, `support_reports` diagnostics or analytics.
- **Found while checking (outside this change):** ML paper search caches each query's results for 24 h as **plaintext
  JSON** in `Caches/arxiv-search/<sha256(query)>.json` (`DeviceSearch.swift:5-72`). The file is named by a hash, but
  its contents (the results) are readable. Recommend sealing it with the local key, as every other cache is.

### B.3 Index design

**Engine: extend the existing custom index; don't add FTS5.** The 2026-10-24 decision chose a custom inverted index
because encrypting FTS5 pages needs SQLCipher or a custom VFS. Re-measured here on the same corpora:

| Heavy corpus (21,450 items, 18 MB of text) | App engine, sealed | SQLite FTS5 (system 3.51, unicode61, prefix 2/3) |
|---|---|---|
| Build | 3.6 s | 1.5 s |
| On disk | **10.8 MB, AES-GCM sealed** | **57.0 MB, plaintext** (it stores the text; a contentless table is smaller but still plaintext terms) |
| Query (median): softmax · attention · "policy gradient" · learning rate · the | 0.7 · 1.3 · 0.7 · 2.8 · 6.4 ms | 2.1 · 4.1 · 0.8 · 5.7 · 21 ms (top 60 with bm25 and a snippet) |
| Encryption | built in | needs SQLCipher (new dependency) or a VFS |

`CSQLite` (`Sources/CSQLite/module.modulemap`) just links the system `sqlite3`. FTS5 and its trigram tokenizer are
available, but nothing in them encrypts.

**Two indexes per account:**
1. **`search-index/`** (exists): papers, as today. Its Library behaviour, ranking, excerpts and Find hand-off stay as
   they are. Global search runs the same `LibrarySearchEngine` query.
2. **`everything-index/`** (new): **one document per item**, written as a metadata-part document so that no per-item
   text file is created (measured 0 bytes of text files). Excerpts are taken from the source text, which is already in
   memory (`PrivateState`, `NotesState`) or one small sealed read (an explanation).

Why two, not one:
- BM25's document counts and lengths stay per corpus. Short messages don't skew paper bodies.
- Each rebuilds on its own: rebuilding the paper index decrypts readings, while the new one rebuilds from memory in
  seconds.
- Commits stay smaller. Each commit reseals the store's manifest, which lists every document; see "Incremental" below.

**Code:**
- `FullTextIndexStore` gains a `namespace` (folder and AAD prefix); about 20 lines.
- New `EverythingIndexer` in the app, shaped like `LibraryFullTextIndexer`: off the main actor, utility priority,
  fingerprints so nothing unchanged is reindexed.
- New `SearchItemKind` in Core: conversation, message, diagram, equation, figure, paperExplainer, collection, snippet,
  podcastSegment.
- A sealed `catalog.bin` in the same folder maps group → kind, paper ID, container (conversation or collection), date
  and fingerprint, for grouping, the paper scope and recency without decrypting sources.
- Group IDs are `<kind>:<id>`.

**Fields per kind** (the existing `FullTextField` slots and weights: title 6, tags/authors/abstract 3, notes 2, body 1):

| Kind | title | tags | notes | body |
|---|---|---|---|---|
| Conversation | display title | paper title | anchored passage quote | — |
| Message | — | — | — | plain text (questions and answers) |
| Equation / figure / paper explanation | label + paper title | symbol names, part titles, Key concept names | summary | the rest of the text |
| Collection | name | — | — | — |
| Snippet | collection name | paper title, section, label | comment | quote, anchor text, blocks under the region, recognised text |
| Diagram | title | — | — | labels and notes |

**Tokenizer v2.** Shared by both indexes; it bumps `FullTextTokenizer.version`, so both rebuild once in the background.
Today's rules, measured on scientific strings:

| Input | Today (v1) | Problem | v2 |
|---|---|---|---|
| `\alpha` / `alpha` / `α` | alpha / alpha / **α** | "alpha" never finds α, and "α" never finds `\alpha` (0 hits on the corpus) | each Greek letter also indexes its name at the same position (α → alpha); a query "α" searches "alpha"; covers ϵ/ϑ/ϕ/ς variants |
| `\mathrm{softmax}(QK^\top)` | mathrm softmax qk **top** | layout commands become words ("top" matches every transpose) | inside math delimiters (`$…$`, `\(…\)`, `\[…\]`, `$$…$$`) and explanation symbol fields, drop layout commands (`\mathrm \mathbf \mathcal \mathbb \operatorname \text \left \right \frac \sqrt \top \quad \cdot \,`) and keep their arguments; keep named symbols (`\nabla` → nabla, `\log`) |
| `∇θ` | θ | ∇ is dropped | ∇ → nabla, ∂ → partial, ∞ → infinity, Σ (operator) → sum |
| `α̅ₜ` | αt | subscripts glue to the letter | split where a Greek letter meets a Latin letter or digit |
| `self-attention`, `KL-divergence`, `GPT-4o`, `Llama-3.1-8B`, `2106.09685`, `x_t` | already good (parts plus the joined form; IDs kept) | — | unchanged |

**Prefix and typo tolerance.**
- *Prefix* exists already: the word being typed matches its 64 most frequent completions (`transfo` → 503 matches at
  0.4 ms).
- *Typos* are new and run only when a word matches nothing. A Damerau distance of ≤ 1 (≤ 2 for words of 8+ letters) is
  checked over both term dictionaries, and the most frequent candidate wins:
  - `atention` → attention; `softmx` → softmax; `difusion` → diffusion; `transfromer` → transformer;
    `regularisation` → regularization.
  - 0.5–2.2 ms over a 14.6k-term dictionary.
  - The paper bodies' dictionary is larger: the five sample papers already have 12.3k distinct words, and an estimate
    for 256 bodies is about 80–100k terms, so about 10–15 ms, and only on a zero-result query.
  - The screen then says "No exact matches · showing *attention*".
  - If some words match but not all, it shows "Results with some of your words" using today's match-strength line
    ("67% · title, abstract").

**Incremental, including sync merges.**
- *Triggers:* the indexer listens to every `PrivateState` publication (local append, `ingest` of a synced page,
  tombstones), `NotesCenter` changes, `SnippetTextStore` recognitions, writes and prunes in the three explanation
  stores, and podcast downloads (phase 2).
- *Change detection:* messages are immutable events, so their fingerprint is the event ID plus status. Conversation and
  note revisions fingerprint their revision; explanations, their file and `savedAt`. A tombstone removes the document.
- *Streaming answers* are indexed once, when complete, never per token.
- *Cost:* committing one item costs 22 ms median (p95 51) at owner scale and 81 ms (p95 209) at heavy scale, because the
  sealed manifest is rewritten each time. So commits are coalesced: after 2 s of quiet or 64 documents, and on going
  to the background.
- *Search never waits for indexing:* a snapshot is immutable, and a running search reruns after a commit, as the
  Library does.

**Rebuild and versioning.** The pattern is the existing one: a format or tokenizer change, or an unreadable file, empties
the index, and it rebuilds in the background. Measured full build: 0.5 s for 5,820 items and 3.6 s for 21,450 items on
this Mac. Estimate: up to 2–3× that on an older iPhone, at utility priority. The paper index rebuild was already
measured at about 9 ms a paper.

**Size, memory and battery** (measured, M1 Max, release build):

| | Owner scale: 300 chats / 3,000 messages / 1,200 explanations / 1,200 snippets / 80 diagrams / 40 collections | Heavy: 1,000 / 12,000 / 4,000 / 4,000 / 300 / 150 |
|---|---|---|
| Text | 4 MB | 18 MB |
| Everything index on disk | 3.8 MB (661 B an item) | 10.8 MB (503 B an item) |
| Open + load all segments (cold) | 20 + 6–8 ms | 71 + 20 ms |
| Memory when loaded | +0.6 MB | +6 MB |
| Full build | 0.5 s | 3.6 s |

Papers (existing measurement, NATIVE_LIBRARY_SEARCH.md): 72 KB on disk and about 32 KB of memory per paper with a
body, and only papers downloaded here have bodies (two stores of 128). There is **no 1,000-paper cap**: the only paper
count limit is `LibraryWire.maximumRetainedEntries = 4,000`. The heavy profile is pessimistic for explanations, since
each answer store keeps at most 400 (1,200 in all).

Battery: indexing runs only after changes, coalesced, at utility priority. Searching is CPU-only, in milliseconds,
with no network.

### B.4 Ranking

- **Within a kind:** BM25F with the existing weights. Then:
  - × 1.3 when the query's words appear as a phrase (adjacent) in the title or text, even unquoted;
  - × 1.3 for words in your own questions over the AI's answers (your words are the stronger signal);
  - × up to 1.2 for recency (last used or saved, linear over 90 days);
  - papers keep today's × up to 1.1 for the newest.
- **One message per conversation** in the All view, with "+3 more in this chat". A conversation whose title matches
  appears as the conversation itself.
- **Across kinds: grouped, never one mixed list.** BM25 scores from different corpora are not comparable, and a fixed
  order keeps rows from jumping between keystrokes. The order: **Papers, Chats, Explanations, Snippets, Diagrams,
  Feed, Tags, Settings**. Empty groups are hidden. Each group shows its best 3 and "See all N".
- **Settings** rows appear only on a word or prefix match of a row's title or synonyms, never from ⓘ text alone.
- **Phase 3, "Related" (no new model):** the top 3 paper hits' public gte-small fingerprints (already on the device for
  library papers and the Feed pool) give a centroid. Cosine ≥ 0.88 picks related library and Feed papers that share no
  words with the query, the same threshold as Filter + related. Nothing is sent.
- **Optional, later:** an on-device gte-small, shared with the interest index's uploads question: fp16 Core ML is about
  67 MB and would be an On-Demand Resource. It would embed chats, explanations and snippets in chunks, int8 and sealed;
  brute-force cosine over 21k × 384 is a few milliseconds. The app has no text embedder today (`LibraryInterest.swift:11`).

### B.5 The search screen

```
 Empty (🔍 tapped; keyboard up, question 4)       Typing "softm"
 ┌───────────────────────────────────────┐        ┌───────────────────────────────────────┐
 │ ╭───────────────────────────────╮     │        │ ╭───────────────────────────╮         │
 │ │🔍 Search everything           │ ⓘ   │        │ │🔍 softm                 ✕ │ Cancel  │
 │ ╰───────────────────────────────╯     │        │ ╰───────────────────────────╯         │
 │ Recent                         Clear  │        │ (All) Papers Chats Explanations Snip→ │
 │  🕘 policy gradient                   │        │ PAPERS · 3                            │
 │  🕘 "kl divergence"                   │        │ 📄 Attention Is All You Need          │
 │  🕘 newton schulz                     │        │    100% · full text                   │
 │ Recently opened                       │        │    …the ▓softmax▓ of the scaled dot…  │
 │  📄 Direct Preference Optimization    │        │ 📄 …                                  │
 │  💬 Why does the loss use σ? · DPO    │        │    See all 3 papers                 › │
 │  ∑  Equation (7) · DPO                │        │ CHATS · 24                            │
 │  ✂  Muon notes · 4 snippets           │        │ 💬 Why divide by √d_k first? · DPO    │
 │                                       │        │    You · 3 days ago                   │
 │                                       │        │    …so the ▓softmax▓ saturates when…  │
 │ ╭──────────────────────────────╮ ╭─╮  │        │    +3 more in this chat               │
 │ │Library Paper  Chat  More     │ │🔍│  │        │    See all 24                       › │
 │ ╰──────────────────────────────╯ ╰─╯  │        │ EXPLANATIONS · 9 …                    │
 └───────────────────────────────────────┘        │ ───────────────────────────────────── │
                                                  │ 🌐 Search ML papers for “softm”     › │
                                                  │ [ keyboard ]                          │
                                                  └───────────────────────────────────────┘

 "See all" (Chats chip)                            From a paper: scoped
 ┌───────────────────────────────────────┐        ┌───────────────────────────────────────┐
 │ │🔍 softmax                 ✕ │ Cancel│        │ │🔍 [In this paper ✕] softmax │Cancel │
 │ All Papers (Chats) Explanations Snip→ │        │ PASSAGES · 6                          │
 │ 24 messages in 9 chats                │        │ ¶ 3.2 Attention · …a ▓softmax▓ over…  │
 │ 💬 Why divide by √d_k first? · DPO    │        │ ¶ 3.2.1 · …apply ▓softmax▓ to obtain… │
 │    …so the ▓softmax▓ saturates when…  │        │ CHATS ABOUT THIS PAPER · 2            │
 │ 💬 Sparse attention vs. … · Mamba     │        │ EXPLANATIONS · Equation (1)           │
 │ …                                     │        │ SNIPPETS · 1                          │
 └───────────────────────────────────────┘        └───────────────────────────────────────┘

 iPad Wide / Mac: Search is a place with two slots, like Mail
 ┌─────────────────────────────┬────────────────────────────────────────────────┐
 │ (≡)(🔍) ╭softmax       ✕╮ ⋯ │                                                │
 │ All Papers Chats Explan…    │   the picked result: the paper at the passage, │
 │ PAPERS · 3                  │   the conversation at the message, or the      │
 │ ▸ Attention Is All You Need │   collection at the snippet                    │
 │ CHATS · 24                  │                                                │
 │ …                           │                                                │
 └─────────────────────────────┴────────────────────────────────────────────────┘
```

- **Empty state:** up to 5 recent searches (sealed; "Clear") and up to 5 recently opened items. The recent items come
  from data the app already has: reading activity, chats' last use, collections, explanations' `savedAt`. Nothing else
  appears: no tips and no footer. A single **ⓘ** after the field says what is searched and that it stays on this
  device.
- **As you type:** a search runs on every keystroke in one cancellable worker. It uses `LibrarySearchCoordinator`'s
  pattern: one active worker, the latest input pending, nonce-fenced publication. There is no debounce, because the
  index is fast; segments load as the screen appears.
- **Chips:** All · Papers · Chats · Explanations · Snippets · More kinds (Diagrams, Feed, Tags, Settings, and phase 2
  Podcasts). They appear under the field only once there is a query, as the Library / ML switch does today.
- **Rows:** fixed heights, with the title on one line and the excerpt's two lines reserved, so rows don't jump. They
  reuse `SearchMatchLine` (`RootView.swift:928`) and `SearchHighlighter`: the match-strength label, the excerpt, and
  matched words in Find's yellow. Math in excerpts shows as the v2 cleaner's text, not raw LaTeX.
- **Paper scope:** opening 🔍 while Paper is the current place adds a removable **In this paper** token. Passages are
  found by running the highlighter over the open reading's blocks (the DPO sample is about 108 KB; the measured cost for
  100 abstract-sized texts is about 3–4 ms). They are followed by that paper's chats, explanations and snippets.
  Elsewhere, a paper row's context menu offers "Search in this paper".
- **The last row is always "Search ML papers for “…”".** It is the only network action, and runs `searchPapers(q)`
  exactly as today.
- **Wide and Mac:** the left slot is the results list and the right slot is the picked item. The right slot reuses
  the detail views the Library, Chat and Snippets places already put there (`TwoSlotLayout`). The list stays, the
  divider is remembered as `wide.divider.search`, and this follows the 2026-10-22 decision "Search lives at the top of
  the left list, like Mail".

**What each result opens:**

| Result | Opens (existing function unless marked) |
|---|---|
| Paper, metadata match | `openLibraryResult` → Paper |
| Paper, text match | `openLibraryResult` with `pendingPaperFind` (Find opens with the words and the keyboard down). Phase 2: `PaperPassageRequest` to the exact block, then Find. |
| Passage (paper scope) | `PaperPassageRequest(paperID, TextAnchor(elementID: block))`, then Find |
| Conversation | `openConversation` |
| Message | `openConversation`, then **new** `ChatTranscript` scroll-to-message with a brief highlight; selects the branch holding it (`ConversationBranchSelections`) |
| Equation / figure / paper explanation | `openExplanation(subject)` (the kept answer, no new request) |
| Diagram | `openDiagram` |
| Collection / snippet | `openNote(id)` / `openNote(id, entry:)` |
| Feed paper | the Feed with its detail (`feedDetail` Tall, `feedPickID` Wide) |
| Tag | `showLibraryPapers(taggedWith:)` |
| Setting | `openSettings`, then **new** scroll to the row (rows already have stable `accessibilityIdentifier`s, for example `settings.passageMarks`) with a 1 s accent fade; nested pages (Your AI usage, Account, About) open the page |
| Podcast segment (phase 2) | `play(episode, at: startMS)` |
| ML papers | `searchPapers(q)` → Library in ML scope |

After opening a result, the bar shows the item's place, and 🔍 brings back the same query, chip and scroll position.

### B.6 Existing searches: what stays and what folds in

| Search | Recommendation |
|---|---|
| Library field, with the Library / ML switch | **Stays.** It filters the list and table with sorts, tags, Filter + related and columns, none of which global search replaces. Global search's Papers group uses the same engine, so the results agree. |
| ML paper search | **Stays, unchanged.** Global search reaches it only through its explicit last row, and every route that lands there today still does. |
| Snippets field (`NoteSearch`) | **Stays** as the collection-centred filter. Global search indexes the same words (comment, quote, anchor text, OCR) with ranking. |
| All chats field | **Stays.** It doesn't search answers today. Phase 2 can have it ask the everything index, so the two agree. |
| Find in paper (⋯, ⌘F) | **Stays.** "In this paper" is the list view of the same words. |
| Mac ⌘F / ⌥⌘F / ⇧⌘F | **Stay.** ⌘K is added. |

### B.7 Targets, offline, failure

| Target (heavy profile) | Budget | Measured on M1 Max | Device estimate |
|---|---|---|---|
| Keystroke → grouped results with excerpts (everything index) | p95 ≤ 50 ms on an iPhone 13-class phone, ≤ 100 ms on the oldest supported (A12) | 0.1–14 ms | A15's single core is within about 1.5× of this Mac, A12 about 2×: ≤ 30 ms. Estimate, not measured on a phone (paused). |
| + papers (existing whole-Library search) | in the same budget, run in parallel | 11–18 ms at 2,000 papers (iPad Simulator) | ≤ 40 ms |
| First search after launch (both indexes load) | ≤ 250 ms, hidden by loading on appear | 91 ms papers (2,000) + 91 ms everything (heavy, open + load) | ≤ 250 ms |
| Feed page scan (≤ 100 papers) | ≤ 10 ms | 2.8–4.1 ms | ≤ 10 ms (the whole session's 3,000 would be 80–90 ms, so only the current page) |
| Index a sent message | off the main actor, coalesced | 22 / 81 ms a commit | — |

- **Offline:** everything works except the ML row, which shows the existing offline line ("You’re offline. What’s on
  this device still works.").
- **While indexing** (first launch after the update, or after a rebuild): one quiet line under the chips with the app's
  one loading sign, "Indexing chats and explanations · 45%", which goes away when done. There is no partial "No
  results" for a source that isn't ready.
- **Damaged or old index:** emptied and rebuilt (existing pattern).
- **Memory warning:** unload; the next keystroke reloads (≤ 100 ms).
- **Full disk:** the last good index stays usable; new items are found once there is room. The Settings storage line
  says so.
- **Stale hit** (an item deleted on another device and not yet merged): dropped when its source is read for the row.

---

## Phases and effort

Effort is in agent-days at this codebase's pace, including tests, excluding owner review and TestFlight waits.

| Phase | Contents | Effort |
|---|---|---|
| **1. Navigation + search over what has text** | Bar (3 + More + 🔍; iPad width rule), the More screen, Settings out of iPhone ⋯ (if question 3 is yes), Wide 🔍 circle, Mac toolbar field and ⌘K, iPad ⌘ keys in Tall · `FullTextIndexStore` namespace, `EverythingIndexer`, the sealed catalog, tokenizer v2 (with the paper index rebuild), typo fallback, recent searches · the search screen (Tall, Wide, Mac), chips, grouping, `SearchMatchLine` rows, the open-target router, land-on-message, the Settings catalog and scroll-to-row, the Feed page scan, tags · UI test identifier updates (about 101 `tab.*` references in 19 files keep working; add `tab.more`, `tab.search`, `more.list`) | **12–16** |
| **2. Full text and depth** | Exact passages (keep block offsets with each body so a hit lands on its block), the "In this paper" scope, podcast transcripts, a PDFKit text layer for uploaded PDFs without a model reading (on the device), All chats answers through the index, Unicode math in excerpts | **7–10** (browser port, when resumed: about 6–8 more) |
| **3. Semantic** | 3a "Related" from public fingerprints (no model) · 3b optional on-device gte-small as an On-Demand Resource for chats, explanations and snippets (decide together with the interest index's uploads) | **2–3** · **8–12** |

Phase 1 is useful on its own. It is the first time chat answers, explanations, diagrams and Settings can be searched at
all, and the first time one field covers papers, chats and snippets.

## Testing

- **Core unit tests (fast):**
  - tokenizer v2: α/alpha/`\alpha`, layout commands, ∇, subscripts, and v1's compound and ID cases kept;
  - query parsing, typo candidates and choice, BM25F and boosts;
  - everything-index add, replace and tombstone, coalesced commits, version rebuild;
  - **sealed at rest:** write a corpus with a marker word and scan every file in `everything-index/` for it in UTF-8
    and UTF-16;
  - AAD binding (another account's key or file name fails);
  - unload and reload.
- **App tests (fast):**
  - `EverythingIndexer` over the existing fixtures: `ChatHistoryFixture` (30 conversations, 109 messages),
    `SnippetsFixture` (3 collections, 8 entries; "Kaleidoscope" exists only in an image's pixels), plus a new kept
    equation/figure/explainer fixture;
  - the open-target router for every kind;
  - every Settings catalog identifier exists in `SettingsView`;
  - the bar's selection mapping (every route in A.5).
- **UI journeys (slow, opt-in, Simulator):**
  - iPhone: each place reachable, More highlight and second tap, Settings sheet from More, search → open a message →
    🔍 returns to the same results, ML row hand-off;
  - iPad upright full width (six + 🔍) and Split View (More);
  - iPad Wide: 🔍 two-slot search, and the leading reserve at 104 pt;
  - Mac: ⌘K and the toolbar field;
  - VoiceOver labels and headings; AX5 text with the Large Content Viewer;
  - visual scenarios `more-list`, `search-empty`, `search-typing`, `search-grouped`, `search-scoped`.
- **Performance (opt-in):** promote the throwaway benchmark into `FullTextBench` as owner and heavy profiles. Report
  build, size, load, the query table and one-item commits. Run it on the Mac in release and in the Simulator. Check it
  on a phone when phone testing resumes.

## Appendix

### Measurements

A throwaway Swift package depending on this worktree's `ScienceReaderCore` (release build, M1 Max, macOS):
- **Corpus:** synthetic items built from 1,629 paragraphs of five real paper texts (Apertus, DPO, Mamba, Muon, PRISM),
  plus ten ML equations and symbol lines in LaTeX and Unicode (`\mathrm{softmax}…`, the DPO loss, SSM recurrence,
  PPO clip, Newton–Schulz, …). Messages alternate short questions and 2–4 paragraph answers, a third of them with an
  equation.
- **Engine run:** the items were indexed with `FullTextIndexStore` (sealed, one metadata-part document each), closed,
  reopened, and 17 queries were timed 20 times after a warm-up. Each query was timed as the index alone, and with AND
  filtering, ranking and top-5-per-kind `SearchHighlighter` excerpts.
- **Comparisons:** a Foundation case- and diacritic-insensitive linear scan took 0.56–4.7 s for most queries, which rules out
  scanning without an index. FTS5 used the same items. A Damerau scan ran over the term dictionary, and a highlighter
  scan over abstract-sized texts.

| Query (heavy profile) | Matches: chats / messages / explanations / snippets / diagrams / collections | Index ms (p95) | + rank + excerpts ms |
|---|---|---|---|
| softmax | 1 / 243 / 167 / 10 / 0 / 0 | 0.72 (0.87) | 2.1 |
| attention | 3 / 754 / 598 / 148 / 6 / 0 | 1.30 (1.79) | 4.2 |
| kl divergence | 0 / 35 / 35 / 6 / 0 / 0 | 0.86 (1.01) | 3.6 |
| "policy gradient" | 0 / 15 / 10 / 3 / 0 / 0 | 0.69 (0.87) | 3.8 |
| `\alpha` = alpha | 0 / 618 / 695 / 7 / 0 / 0 | 0.97 (1.26) | 2.5 |
| α | 0 everywhere (the v1 gap) | 0.66 | 0.7 |
| transfo (prefix) | 7 / 933 / 729 / 205 / 4 / 0 | 1.35 (1.77) | 4.4 |
| atention (typo) | 0 (fallback finds "attention") | 0.50 | 0.5 |
| learning rate | 4 / 1,018 / 1,095 / 129 / 2 / 0 | 2.80 (3.20) | 6.2 |
| the | 15,426 in all | 6.36 (9.24) | 14.0 |

The owner-scale profile ran about 3–4× faster on every query (0.14–1.63 ms for the index, ≤ 5.9 ms in all).

### Smaller findings (outside this change; record or fix separately)

- The ML paper search cache is plaintext JSON (B.2).
- Snippets saved on a non-arXiv paper store `sourceID = paper.id.wire` (`SnippetCapture.swift:295`), so they don't join
  that paper's notes field in the Library index. Drawn regions add only their comment there, not the recognised text.
- iPad ⌘1…⌘5 and ⌘, work only in Wide, because they live inside `PlacesMenuButton` (fixed in phase 1, A.6).
- The podcast toast and device-approval banner decide "is there a bar" with `width >= 850 || isMac`
  (`PodcastPlayerViews.swift:563`, `DeviceApprovalViews.swift:219`), not the 900/600 shape rule.
- Out-of-date comments:
  - `RootView.swift:12` says Wide starts at 1000 pt.
  - `ReaderModel.swift:1210-1214` describes a "five-item tab bar" and "the header gear".
  - `NotesViews.swift:1125` mentions the "places capsule".
  - `MacSupport.swift:600-602` describes the toolbar as the iPad's capsule.

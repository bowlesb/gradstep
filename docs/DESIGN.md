# Design principles and patterns

Content-source change, owner 2026-10-13: use official arXiv HTML to build the existing structured reader; every PDF
is downloaded and processed only on the user's device. Preserve the page arrangement, navigation, selection
actions and paper/general-chat behavior. Missing HTML gets a clear availability explanation and the existing
source/local-PDF action, with no cloud OCR fallback. Implementation contract and status:
[HTML-first reader](architecture/HTML_FIRST_READER.md). Staging implementation and verification are recorded there and in IMPLEMENTATION_STATUS.md.

Owner principles (2026-10-05): well-considered margins; details and options tucked away until needed; visual
hierarchy (primary large, secondary smaller); as much open space as possible — "like walking into a living room
and seeing mostly open space, but have useful options tucked away"; and one uniform, well-thought-out way to reach
options just below the surface, across the whole app.

Patterns (from [design audit 1](design-audits/2026-10-06-audit1.md); shared code in
`apps/apple/ScienceReader/Views/DesignSystem.swift`):

- **Screen options**: one "…" menu (SF Symbol `ellipsis`), the rightmost top-bar item. Inside, in order: view/sort/
  show choices as submenus that show the current choice, the screen's actions, then "Report this screen".
- **Top bar**: left = where to go (contents, history); right = create (+, compose), then "…". Buttons are 44 pt
  glass circles with 17 pt semibold accent symbols (`HeaderButtonLabel` for app-drawn headers).
  *Library exception* (owner, build 75, 2026-10-19: "Move the catalog to the left of the search bar and move the +
  option as a new row inside the dialogue on the far right"): the Library header is the catalog (a compact glass
  control, only when there is a choice of catalogs, hidden while searching), the search field, then "…"; **Add
  paper…** is the first row of that "…", and there is no + beside the field. Other screens keep the rule above.
- **Floating chrome** (2026-10-07, after Gemini; shared code in `Views/Chrome.swift`): bars float over content, which
  runs to the screen's edges behind them and fades out softly.
  - *Tab bar*: one glass capsule, 58 pt tall, 16 pt from the sides (at most 520 pt wide on iPad), sitting in the home
    indicator's area, 14 pt above the screen's edge on a phone with a home indicator (owner, build 78: "the icons at the
    very bottom could be lowered a bit"; it was 20 pt). Each screen keeps room for it inside its NavigationStack (`tabBarSpace()`), so the last row
    scrolls clear of it with an 8 pt gap. It hides while a software keyboard is up; over the reader's docked find bar
    (after Search) it sits just above the bar. It does not shrink on scroll.
  - *Headers*: the controls (Library catalog, search and …; Feed topics and …) float on a
    band (`chromeBand(.top)`) that is 94–100 % the screen's background behind them, then fades out over 22 pt.
    Taps on the band stay with it; the fade below lets them through. Over a table the band stays solid (the column
    titles pin right under it). System title bars (Paper, Chat, Settings) keep the system's own treatment.
  - *Chat*: nothing sits between the title bar and the conversation, which runs the full height, under the title
    bar, the message box and the tab bar. Paper chat / General chat is the title's menu (chevron after the title;
    under it the paper, tap to return, or "General chat"). The message box is a glass pill with the placeholder
    "Ask anything about the paper" ("Ask anything" in general chat; owner, build 57) and, on its lower line, one
    model control (the model's name: Default or Choose model, whose page also has the length, Use for new chats and
    About; owner, build 69: one control, not a model button and an options slider), dictation and Send/Stop on the
    right, 10 pt above the tab bar on the bottom band (`chromeBand(.bottom)`); while the keyboard is up on iPhone a
    hide-keyboard button sits inside it. Answer options stay in the chat's "…".
  - *Paper*: the page sits between the title bar and the tab bar's room; the reader's floating controls (selection
    actions, Back, a reference's outcome) float over its last lines on the bottom band, which also fades the page
    under the tab bar. The page's viewport never changes size as controls come and go: reading positions and
    heading and citation jumps are measured in it (running the page under the tab bar, or shrinking it for the
    selection bar, moved the reading position near a paper's end).
  - *Panes* (iPad and Mac Reader): the paper and its chat column are split by a hairline with a grabber; drag it to
    resize (applied when the drag ends; double-tap for the default width), or Paper "…" › Hide chat for a full-width
    paper, with a chat button in the paper's bar to bring it back. Both are kept per device (`Views/ReaderSplit.swift`).
  - *Surfaces* (`chromeSurface`): Liquid Glass on iOS 26, a material with a hairline and soft shadow before it.
    With Reduce Transparency every surface is solid (secondary system background with a separator hairline) and
    every band is the plain background.
- **Icons**: the app's own symbols (`GradstepSymbol`; `Assets.xcassets/Symbols`, drawn by `tools/icons`): rounded
  lines like the Nabla mark, each with one amber point — Feed (feed arcs from the point), Library (spines, the
  middle one banded), Paper (page with the reading point), Chat (bubble with · · •), Settings (gear around the
  point), plus new chat, All chats (a list: bullets and lines), contents and the mark. The selected tab draws the line in accent and the
  point in amber (palette rendering) on a light accent capsule; other tabs are in the label color. Header buttons
  and menus draw them monochrome in accent. Universal actions keep system symbols (+, …, search, text size).
- **Margins and rhythm**: 16 pt side margins; spacing steps 4/8/12/16/24 (4 within a row, 12 row padding, 24
  between sections). On iPad, scrolling columns are at most 720 pt and centered (the reader's text column is its own).
- **Type**: titles `.headline`; secondary `.subheadline` in secondary color; tertiary (metadata, status)
  `.footnote` in secondary color. Accent color only for tappable things.
- **Status**: one `StatusBanner` (inset rounded card, symbol, one message, a chevron or ≤ 2 text buttons; light
  accent for information, orange for problems), shown only when the reader can act, scrolling with content. A library
  change waiting to sync is not mentioned until it has waited 30 s or failed three times, and then calmly ("1 change
  hasn't synced yet. Gradstep will keep trying." · Details); orange only when the reader must act (sign in again,
  review a refused change). Temporary failures retry by themselves (5 s, 15 s, 1 min, then every 5 min); no message
  asks the reader to Refresh (owner, build 73: "Awful. Unclear product experience").
- **Sheets**: information sheets have a round X on the right (see Sheet top row; no Done) — except figure, table and
  equation pages, which have no X on a touch screen (below); task sheets have Cancel on the left and the confirming action
  on the right; short sheets open at medium height. Catalogs' "…" ends with **Report this screen**. Contents, whose tabs
  fill its top row on a phone, ends each list with a quiet Report this screen row.
- **Sheet top row** (owner, build 62, 2026-10-16: "the top horizontal space is poorly used… use Liquid Glass… remove Done,
  use an X"): an information sheet (Contents, a figure or table, the equation view, an explainer) has one glass row at
  the top: its controls on the left (tabs, or the page's actions), a round glass **X** on the right. No centred title
  when the controls already say where you are (Contents' tabs name the tab; a figure page's caption names the figure),
  no Done. Glass = `ChromeSurface` (Liquid Glass on iOS 26, a material before it, solid with Reduce Transparency); tabs
  are a glass segmented control. A pushed page keeps a round glass Back on the left of the same row. Code:
  `Views/SheetChrome.swift` (`SheetTopRow`, `GlassTabs`, `SheetRowTitle`; the round buttons are `HeaderButtonLabel`);
  first used by Contents (iPhone, iPad, Mac). Figure, table and equation pages use the same file's `sheetTopRow(...)`,
  which puts their actions in the sheet's own navigation bar, in the middle (between a pushed page's system Back and
  the right edge), as one item that shrinks to fit (iOS 26 moves bar buttons that don't fit into a "More" menu).
  *Figure, table and equation pages* (owner, build 78, 2026-10-21: "The report this screen isn't needed. The snippet
  icon is inconsistent. use txt at top Snippet, Chat, AI Explainer. X also not needed"): the row is only words —
  **Snippet** (Add to note), **Chat** (VoiceOver: "Chat about Figure/Table/Equation") and **AI Explainer** — with no
  icons, no "…" and no X. The sheet swipes down to close (VoiceOver: the escape gesture); the Mac, which has no swipe,
  keeps its X, and so does the browser's dialog (Esc also closes it). A pushed explainer keeps its Open in Chat symbol.
  The after-screenshot Report this screen offer is off unless turned on in Settings; Settings › Report a problem remains.
- **Explain actions**: wherever a figure, table or equation is shown on its own, the top row offers **Chat** (a draft in
  the paper's chat, nothing sent; on the equation view, its conversation below) and **AI Explainer** (the walkthrough /
  symbol explanation, requested only then), after **Snippet**. They are peers and look the same: glass capsules with
  accent words, none tinted (owner, build 76: "Confusing that only one is purple?"). A tapped equation's menu offers
  **Focus** right after Chat about Equation (owner, build 78: "Let's change AI explainer to Focus… we should not
  necessarily assume they need an AI explainer"): it opens the equation view large and asks nothing; the view's AI
  Explainer asks. An explainer's title is a small
  menu (⌄) listing the paper's other figures or equations, to switch without going back to Contents.

- **Figure parts** (owner, 2026-10-21: "present it as a crop of the whole thing, that they can expand, rather than an
  actual crop"): a part of a figure is never a cropped-away bitmap but a viewport into the whole figure, always on the
  figure's white. How tightly it frames the part follows its confidence: tight (looks as a crop with its white margin),
  looser with the part outlined, or the whole figure with the part outlined — an unobtrusive outline (2 pt, the light
  accent in both appearances), never a fallback message. Tap expands to the whole figure (the part outlined, starting
  from its frame); pinch reveals what is around it; double tap returns. A caption that names its panels caps the parts;
  extras are outlines on the whole figure. Details: [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Parts as viewports".

- **One AI result per explainer** (owner, 2026-10-21: "Let's not do extract the subfigure … consistently create one good
  product experience in the AI result that comes back"): the figure walkthrough is the only result; looking closer is
  zooming or expanding a part's viewport, never another AI request that makes new crops or a different layout. A part's
  menu keeps one AI follow-up, **Explain more simply** (words under the part, inside the walkthrough), plus the non-AI
  Save snippet, Show in the paper and Ask about this part. A new follow-up is added only if it returns words into the
  same walkthrough. [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Extract the subfigure removed".

- **Contents discovery** (owner, 2026-10-18): open at full height. On touch devices, double-tapping article text opens
  Contents; links, equations, figures, reference entries and selections retain their own actions. Long-press selection
  remains available, and Mac double-click still selects text. Above the four tabs, show “Double tap anywhere while
  reading the article for this menu” until the gesture succeeds; remember that fact on this device across launches.
  Contents and reference jumps land immediately, including with Reduce Motion off. Bibliography entries show all
  their actions together in a vertical native menu, without a horizontal More page.

- **Rows**: `.headline` title (≤ 2 lines), `.subheadline` authors, `.footnote` details/status; 16 pt side and 12 pt
  vertical padding; at most one trailing icon; navigation rows have a chevron, action rows accent text.
- **Tables**: one `PaperTable` (`Views/PaperTable.swift`) wherever papers show as a table (Library, Feed). A pinned
  header of `.footnote` semibold titles in secondary color; the sorted one in accent with a chevron (tap to sort, again
  to reverse; "· Added ⌄" beside Title when the sorted column doesn't fit). Title column: `.subheadline` semibold
  title (≤ 2 lines, truncated). Library uses separate Device and Authors columns, enabled by default; the title does
  not repeat those details below it. Pending and completed rows reserve the same two title lines. The reader chooses columns (screen
  options › Columns, a half-height sheet of toggles; Title always shows). Every chosen column remains available:
  when they do not fit, the title stays pinned and the other columns scroll sideways, settling at column boundaries.
  Feed's Add and All chats' Last read stay pinned at the right. Wide cells wrap or truncate within the scrolling
  region so a chosen column can be fully read; the Feed's expanded row still holds the full abstract. Values are
  `.subheadline` secondary (numbers trailing), tags small `.caption` chips (≤ 2 lines), statuses an icon and a few
  plain words. A row that needs the reader (a failed import) shows its one action as a small bordered capsule
  (Retry, Get credits, Remove) in its status cell — or under the title when that column isn't shown — never only in
  a menu. Rows: 16 pt sides, 10 pt vertical; pointer hover and the arrow-key row get a quiet fill; tap or Return =
  the screen's primary action, long-press = actions, swipe = delete-type actions when the columns do not overflow
  (sideways scrolling takes priority when they do); each row is one VoiceOver element
  reading every chosen column, its action button a separate one. At accessibility text sizes the screen's rows
  replace the table. All chats (`Views/ChatHistoryView.swift`) is the same pattern for conversations: one-line
  question with a muted second line, ~52 pt rows (7 pt vertical padding), Last read rightmost, a search field and
  filter chips above. Library adds an optional Venue column; Feed offers Topic, Published, Authors, arXiv ID and
  Abstract with a Hide papers in my library filter; All chats also offers Topics, Kind and Answer length (latest
  answer's full word count). Column choices are saved separately for phone and larger screens. Feed does not offer
  updated/relevance columns until those values exist in its discovery response.
- **Filters**: quick filters are `ChipButton`s in one horizontally scrolling row that scrolls away with the rows
  (open space while browsing); a menu chip comes first (Tags ⌄); only filters that would change the list appear,
  and the row is hidden when none would. A problem count (Failed 2) is orange. The Tags menu starts with **Search ML
  papers for "X"** (the chosen tag, or a submenu of tags; owner, build 75). A tag filter never carries into search:
  starting a search or Cancel clears it.
- **New papers**: a paper added in the last three days and not opened on this device says **New** in plain secondary
  words where "—" would be (the Progress cell; the list's details line), not a dot (owner, build 75: "The purple dot
  beside the checkmark is confusing"; the signal itself is the build 42 request).
- **Usage table** (Your AI usage, owner 2026-10-22): one row per request, newest first. On a phone the Rows pattern —
  activity `.headline`, the paper `.subheadline` secondary (≤ 2 lines), "time · model · tokens" `.footnote` secondary,
  the credits trailing in `.subheadline` semibold with an outcome word under it (orange only for Didn't finish and Being
  checked). At regular width (≥ 640 pt, not accessibility text sizes) and in the browser: columns Time · Activity ·
  Model · Tokens · Cost under a quiet `.footnote` header. A tap opens the row's parts beneath it (no animation with
  Reduce Motion). Chips follow Filters; the period is a ⋯ submenu; the totals carry the ⓘ. Code: `Views/AIUsageView.swift`;
  browser `ui/UsageDialog.tsx`, `usage.css`.
- **Empty states**: `ContentUnavailableView`, one sentence, one prominent button; hide controls that can't work.
- **Details on demand**: screen options in "…"; per-item actions on long-press (swipe for delete-type actions);
  long explanations behind a row.
- **Cards** (owner, 2026-10-21, the Notes list: "each needs a very pleasant border around it, so it looks like a bunch of
  cards"): a list of named things the reader made (Snippets' collections) shows each as a card: 16 pt continuous
  corners, the grouped secondary surface, a 1 pt separator edge, a soft shadow in light mode only, 14/12 pt padding
  inside, 10 pt between cards, 16 pt side margins. The open one (beside the list) has a light accent fill and an accent
  edge; Mac hover a quiet fill. Solid in every mode (nothing changes with Reduce Transparency); Increase Contrast draws
  an opaque edge. Swipe and long-press actions work as on rows. Code: `ContentCard` / `.contentCard(selected:)` in
  `DesignSystem.swift`; browser `.note-row` in `notes.css`. Paper tables and chat lists stay rows.
  *Snippet entries* (owner, 2026-10-22: "a bit cleaner separation still between the cards with the actual snippet itself
  being a slightly more clear 'box' in a card"): each entry in a collection's stream is the same card (10 pt apart, the
  day label 6 pt above its first card; no timeline line), and its crop or quotation sits in an inner **snippet box**:
  10 pt continuous corners, the grouped tertiary fill (one step from the card in both appearances), a 1 pt separator
  edge (opaque with Increase Contrast), 8 pt around a crop. A leading chevron (44 pt target; VoiceOver "Collapse
  snippet"/"Expand snippet", value Collapsed/Expanded) folds the card to one line — time · short paper title (20
  characters on a phone, 32 wider) · first words of the comment, wrapping to three lines at accessibility sizes; the
  line itself also expands it. Remembered per device, never synced; the collection's ⋯ starts with **Collapse all** /
  **Expand all** (each only when it changes something). No animation with Reduce Motion. Code: `NoteEntryView`,
  `.snippetBox()` in `NotesViews.swift`, `NoteCollapsedLine` in Core; browser `.note-entry`, `.snippet-frame`.

Each UI change follows the [visual check loop](VISUAL_CHECK.md); significant redesigns get an independent audit
against this page.

## Build-69 feedback — contextual conversations and model choice

Equation/figure views contain the structured explanation followed by their conversation; Chat about Equation/Figure
opens it without sending. AI Explainer requests the initial explanation. The bottom composer has the actual model,
text input, native dictation and send/stop; it does not redirect follow-ups to the main Chat tab. The main unsent
draft is retained. Model choice starts with default/cloud/local; downloads, defaults, measured requirements and
compatibility are in Settings. Cloud model controls use separate Anthropic and other-provider rows.

Library Search, zero Chats and actual import Added date replace the old placeholders. The temporary title stays
vertically centered in the reserved row height. Keywords are editable immediately before the introduction;
author names offer an author search. Working papers keep their reader version until explicitly updated.

Builds 73–76 (2026-10-21): a keyword chip in the paper offers **Search ML papers for "X"**, **Show library papers
tagged "X"** and **Edit keywords…** (tapping beside the chips still opens the editor); generic keywords (LLM, Large
language models, Reasoning, Evaluation, …) are never derived or shown from the catalog. A catalog's ⋯ in Catalogs
offers **Export as CSV…** (share sheet / Save to Files; browser: a download). A screenshot taken in Gradstep offers a
small, non-blocking **Report this screen** at the top for six seconds (Settings › Offer to report after a screenshot);
in-app report screenshots cover the recovery code and other codes in black.

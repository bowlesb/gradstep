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
  - *Tab bar*: one glass capsule, 58 pt tall, 16 pt from the sides (each item at most 104 pt wide), with 🔍 in its own
    58 pt glass circle 8 pt after it (2026-10-25; *The bar, More and 🔍* under Tall and Wide), sitting in the home
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
    hide-keyboard button sits inside it. Answer options stay in the chat's "…". **The keyboard waits for a tap** (owner,
    2026-10-24: "wait for the person to click on the keyboard before bringing the keyboard up"): opening or moving to a
    chat — Continue in Chat, Ask in chat about a figure or equation, a snippet's Chat, a reference's Discuss in chat, New
    chat, the Chat place or tab — never focuses the message box on iPhone or iPad; Continue in Chat keeps the keyboard up
    only when it was already up in the explainer's box. Actions inside the chat or explainer whose purpose is to type
    there (Quote in Chat, a tapped follow-up or starter, the explainer's Chat button and Ask about this part, Chat about
    Equation) still put the cursor in the box. The Mac, with no on-screen keyboard, focuses as before.
  - *Paper*: the page sits between the title bar and the tab bar's room; the reader's floating controls (selection
    actions, Back, a reference's outcome) float over its last lines on the bottom band, which also fades the page
    under the tab bar. The page's viewport never changes size as controls come and go: reading positions and
    heading and citation jumps are measured in it (running the page under the tab bar, or shrinking it for the
    selection bar, moved the reading position near a paper's end).
  - *Panes* (Mac Reader, until the Mac's own step): the paper and its chat column are split by a hairline with a
    grabber; drag it to resize (applied when the drag ends; double-tap for the default width), or Paper "…" › Hide chat
    for a full-width paper. Both are kept per device (`Views/ReaderSplit.swift`). The iPad uses the two slots below.
  - *Surfaces* (`chromeSurface`): Liquid Glass on iOS 26, a material with a hairline and soft shadow before it.
    With Reduce Transparency every surface is solid (secondary system background with a separator hairline) and
    every band is the plain background.
- **Tall and Wide** (owner, 2026-10-22, "One app, two shapes"; places and per-place slots owner 2026-10-23;
  `LayoutShape` in ScienceReaderCore, `Views/WideShape.swift`, `Views/ReaderSplit.swift`). The window's size alone decides
  the layout, never the device, idiom or size class:
  - *The rule*: a window at least as wide as it is tall, at least 900 pt across and at least 600 pt tall is **Wide**
    (iPad sideways 1194/1376, iPad mini sideways 1133, a foldable phone unfolded ~920×880). Every other window is
    **Tall** (iPhone in either orientation, iPad upright 834/1032, Split View halves, narrow windows). One constant,
    `LayoutShape.of(size:)`, unit-tested with those sizes. The Mac stays Wide until its own step.
  - *Tall* is the iPhone app exactly: the places capsule at the bottom, one screen at a time, the iPhone's bars and
    budget. The bar is Library · Paper · Chat · More with 🔍 beside it, or all six places on a full-width iPad upright
    (*The bar, More and 🔍* below). No ⋯ menu on iPhone or iPad has Settings, in either shape; only the Mac's do.
  - *The bar, More and 🔍* (owner, 2026-10-25: "we have 6 icons but only room for 5. Lets change to the way Slack does
    it… three at the bottom, a [fourth] icon with the words More… For the fifth, it's a search icon"; calls in
    [JUDGMENT_LOG.md](JUDGMENT_LOG.md) 13–16; design in [GLOBAL_SEARCH_AND_MORE.md](proposals/GLOBAL_SEARCH_AND_MORE.md)
    A). **As built (2026-10-25, apps; not yet in a build):**
    - *Which bar* (`TallBar.of(window:)` in ScienceReaderCore, unit-tested with phone, iPad, Split View and Slide Over
      sizes): a Tall window at least 730 pt wide and 600 pt tall shows all six places (Feed · Library · Paper · Chat ·
      Snippets · Settings; every iPad upright, iPad mini's 744 included); every other Tall window (a phone in either
      orientation, Split View and Slide Over, a narrow Stage Manager window) shows **Library · Paper · Chat · More**. The
      window's size alone decides, as for the shape: a phone sideways is wide enough but under 600 pt tall.
    - *🔍* is its own 58 pt glass circle 8 pt after the capsule (`SearchCircle`, `tab.search`, VoiceOver "Search"),
      beside either bar, as iOS 26 draws a search tab. It opens the **Search place** (`ReaderTab.search`, content
      `GlobalSearchView`, [GLOBAL_SEARCH.md](architecture/GLOBAL_SEARCH.md)), scoped to the open paper when Paper is the
      place, the keyboard up when nothing is typed. Selected (accent on the light accent fill) while Search shows. Cancel
      returns to the place it was opened from; 🔍 again brings back the same words, at the result opened last. The
      capsule's items keep at most 104 pt each (four: about 72 pt on a 402 pt iPhone).
    - *More* (`gradstep.more`: three dots, the last the amber point, drawn by `tools/icons`; the word "More" under it
      tells it from ⋯) opens the **More list** (`MoreView`, `more.list`): one inset-grouped list titled "More" in the
      system title bar, rows Feed, Snippets, Settings (the place's glyph in accent, its one word, a chevron; 52 pt,
      growing with the text size), no descriptions, no badges. Rows keep `tab.feed`, `tab.notes`, `tab.settings`.
    - *Opening a row:* Feed and Snippets become the place exactly as from the old bar (`model.tab = .feed`), keeping
      their state (the Feed's results and topic, the open collection); they are not pushed under More and have no Back.
      **More stays highlighted** and VoiceOver reads "More, Feed". **More always opens its list**, from any place, so a
      second tap from Feed or Snippets returns to it. Settings opens over the More list as today's sheet; Done returns
      to the list (More highlighted under it).
    - *The highlight is derived, never routed* (`ReaderTab.barSelection`): a bar place is its own item; Feed, Snippets
      and the More list are More; Search is 🔍; Settings over any screen is More (or Settings in the full bar). Every
      existing "go to X" (a paper's `select`, Continue in Chat, citations, a snippet's source, explainers, deep links,
      Mac menu commands, Open a collection, Browse episodes) sets the same place as before; unit tests cover each route
      group (`PlacesNavigationTests`).
    - *A window that changes bar:* the More list belongs to the compact bar; growing to six places or turning Wide
      while it shows goes to the Library (`tallBarChanged`). Feed and Snippets opened from More stay.
    - *Keys:* ⌘1…⌘5 (⌘1 Feed … ⌘5 Snippets: numbers name places, not positions), ⌘, (Settings) and ⌘K (Search) are
      hidden buttons on the root on iPhone and iPad, so they work in both shapes (they lived in the Wide places menu and
      did nothing upright); reading mode keeps them off. The Mac's menus bind the same keys.
    - *Accessibility:* bar labels capped at xxxLarge (they shrink to 80 % rather than cut), the Large Content Viewer on
      every item and on 🔍; More's value names the place under it; the More list's rows grow freely.
    - *Banners above the bar* (the podcast's ready notice, a new device waiting) decide "is there a bar" with the shared
      shape rule (`WindowShape.isWide(proxy:)`), not a width of their own (they used `width >= 850`).
    - *Browser (paused):* not changed. Parity when it resumes: phone widths get the same four items and 🔍; the
      desktop's search field becomes global search (A.3).
  - *The philosophy (Wide, owner 2026-10-23)*: each place owns one two-slot arrangement. The **left slot is the place
    itself** (its list); the **right slot is what was picked from it**. Positions never jump: the list sits on the left
    from the start, at the divider's position, whether or not anything is picked. The divider is draggable wherever two
    slots show and remembered per place. Navigation never adds a row: it sits at the end of a row the view already
    needs, or floats.
  - *The places menu* (`PlacesMenuButton`; replaces the places capsule that sat in the Wide row): one 44 pt glass circle in
    the window's **top-left corner, the same spot in every view** (owner correction, 2026-10-23: "I meant the top left";
    a list covering the window included), showing the current place's own symbol in accent, so it also says where you
    are ("Places, Library" to VoiceOver, `places.menu`). Its menu, one list with no separator (owner, TestFlight 91: "why
    is there a larger space between snippets and search?"): Feed, Library, Paper (needs a paper), Chat, Snippets with the
    current one checked, then Settings (owner, 2026-10-24: "beside Snippets"; it opens over the place). It holds every
    place, so Wide needs no More. **🔍 is a 44 pt glass circle 8 pt right of it** (owner, 2026-10-25; it supersedes "no
    Search row"), the same spot in every view; while Search is the place the button shows ≡ ("Places, Search") and no row
    is checked. The rows keep their `tab.*` identifiers (`tab.settings`). ⌘1…⌘5, ⌘, and ⌘K work with a hardware keyboard
    in both shapes (the root's). The leftmost slot's row or floating controls start `placesLeadingReserve` (104 pt: the
    two circles and 8 pt after each; 52 before 🔍) in from the edge,
    after them: the Library's search field, the Feed's chips, All chats' search, Collections' search, Contents'
    tabs, Listen's chips, and the paper's list toggle and ☰ when the paper is leftmost. Each slot keeps its own ⋯ at its
    own top-right for its own content (the left list's ⋯ ends the left row; the rightmost ⋯ at the window's edge), and a
    companion's ✕ sits left of its ⋯. Settings is the places menu's last row and in no ⋯ (a sheet on iPad in both
    shapes). No brand row, no gear, no segmented switch. Reading mode has no places button.
  - *Rows only where a slot needs one* (`WideBar`, 52 pt: 44 pt controls with 4 pt above and below, the page's background
    and a hairline under it; side-by-side rows share one centre line with the places button): the Library list (search
    field … ⋯; while searching, Cancel and the Library / ML paper search switch under it), the Feed list (topic chips …
    ⋯, as the iPhone's header), All chats (search), a conversation (title, New chat, ⋯; beside the paper: clock · title ·
    ✕ · ⋯), the Snippets list (search, +), a collection (its name … ⋯), Contents (its tabs and ✕). **The paper has no
    row**: glass buttons float over its top corners on the same centre line — the list toggle and ☰ Contents at the
    left (after the places button when the paper is leftmost), ⋯ at the right — and the page's own CSS starts its title below them (`topInset`); the text scrolls under them.
    The figure page, equation view and AI Explainer keep their own bar (Snippet · Chat · AI Explainer, Open in Chat, ✕);
    the Feed's abstract pane has no controls above its content. Reading mode, Find and the rest are rows of ⋯.
  - *Vertical budget (Wide)*: above content, the status bar and at most one 52 pt row (≤ 56 pt, asserted by
    `IPadShapesJourneyTests`); over the paper 0 pt (asserted). Below, only the chat's message box (its status line sits
    above it). The paper has no bottom bar and no bottom band: text size and line width float at its corner as on iPhone,
    with room after the page's end (the page's own CSS, in either slot). A list's text size (the Feed's A− / A+) is the first row of its ⋯ in Wide, so nothing floats over a list's slot (Tall keeps the iPhone's floating control). The page draws on the app's background
    (`systemBackground`; in dark mode the reader's own #0F0F0F would meet the chat's black at the divider). The find bar
    (under the floating controls), notices and sync status float over content and never move the text.
  - *Two slots* (`TwoSlotLayout`, the one reusable container; at most two columns): it owns the widths, the divider and
    the animated hand-offs (respecting Reduce Motion), and keeps the main view's identity, so a paper keeps its load and
    place whichever side the other slot is on. It knows nothing about papers. The divider is a hairline with a 24 pt
    hit area and a grabber. **A drag is a real drag** (owner, 2026-10-23: "that doesn't feel like a real drag"): the
    divider and both slots follow the finger on every frame (no preview line), each slot stopping at its minimum; the
    position is kept when the finger lifts. The paper reflows as it goes and keeps the paragraph at its top, at the same
    point within it (the reader bridge restores its place on every change of width on iPad, turns included; WebKit has
    no CSS scroll anchoring). VoiceOver adjusts it in 5% steps and has Reset and Cover. Positions are kept
    on the device as fractions of the width per arrangement (`SlotFractions`; `wide.divider.<arrangement>`), so turning
    and Stage Manager keep proportions. Every divider starts in the middle (owner, 2026-10-23: one panel splitting into
    two "should break apart… in the middle"). Minimums: Library and Feed list ≥ 280 pt, paper ≥ 420 pt; All chats and
    Collections ≥ 280, conversation or collection ≥ 320; Contents ≥ 420 each side; paper ≥ 420 beside a companion ≥ 320.
    Dragging a list more than 40 pt past its minimum collapses it (the paper becomes the Paper place; Contents closes);
    dragging a companion that far past its minimum closes it. While the drag is past that point the closing slot stays
    at its minimum, dimmed to half, so letting go visibly closes it.
  - *Covering* (owner, 2026-10-23: "When you double tap, have the list be right over the entire paper, the same way as
    the iphone, not in the middle"): a double tap on the divider lets the list (or the companion, on the paper's right)
    cover the whole window; the slot beneath stays loaded at its place, transparent, untouchable and hidden from
    VoiceOver (the covering slot is modal within the two slots). A small glass handle with a chevron at the far edge
    (`slots.uncover`; "Show the paper beside") brings the two slots back with a tap or a drag inward, at the kept
    divider, and so does a second double tap. Picking from the covering list (a paper, an article, a conversation, a
    collection, the open one again included) splits the slots again, the picked thing on the right. The places button
    stays in its corner and the list's row starts after it. For this run only: a new launch starts split.
  - *Library* = Library list | paper. The list shows the table with the columns that fit the slot (more as the divider
    moves right; rows at accessibility sizes); the right slot shows the open paper (usually the last one read) or "No
    paper open · Choose a paper to read it here". Picking a paper opens it on the right and the place is still Library
    (its row highlighted). The Library's own field searches the Library (owner 2026-10-24: "if I want a search, I could
    just go and search the library"), with the Library / ML paper search switch under the row while searching; results
    in the list, the one picked on the right. It stays now that global search is a place (🔍, 2026-10-25). Routes that
    search (an author's "Find papers by", Find similar papers, a tag's ML paper search) land there with the query.
  - *Paper* = the paper as the left primary item. Its floating **list toggle** (`sidebar.left`, "Hide library" / "Hide
    feed") promotes the paper beside a list: the list slides away and the same paper, at the same place, takes the width
    (Read, its column centred). In Paper the same button ("Show library" / "Show feed") returns it beside the list it
    came from (`paperOrigin`, the Library by default). Paper chosen from the places menu, a citation, a snippet's passage
    or a chat's paper is the Paper place. Beside it: **Contents** on the left (Navigate, ☰), or a **companion** on the
    right — the AI Explainer, the equation view, a figure page, or the chat (Discuss: Ask, a selection's Explain, Continue
    in Chat) — with ✕ and the divider; ✕ returns the paper to the whole width at its place. A helper opened while the
    paper is beside the Library or Feed promotes it first, and a chat, list or Contents taking a side closes a helper:
    never three columns. Opening or closing a helper (the AI Explainer, the equation view, a figure or table page) moves
    nothing on screen: the list leaving, the paper going to the left and the helper arriving happen at once (owner,
    TestFlight 91: "maybe it might work just not to have an animation, just to go there"; `ExplainerCompanion`), as
    with Reduce Motion; the list toggle, Discuss's chat and a covering list keep their 0.32 s slide. Continue in Chat hands the explainer's companion slot to the chat (one shared frame,
    `matchedGeometryEffect`, `WideSlotTransition`; no motion with Reduce Motion). Discuss's All chats is a clock, so it
    never reads as Contents' list beside it.
  - *Feed* = feed list | details. The list is on the left half from the start (not a centred column); a quiet "No article
    picked" placeholder on the right. Picking a row (the table's or the list's; highlighted) shows `FeedAbstractPane`:
    title, all authors, month, arXiv number, popularity, topics and categories, why For you suggests it, the whole
    abstract, and the row's own actions (Add to library, its progress, Read once it is here, View on arXiv). Picking never
    adds a paper. Read opens the paper in the right slot, still the Feed; its list toggle promotes it as in the Library.
    Listen (the Feed's podcasts) is one slot with its chips and ⋯ in its row.
  - *Chat* = All chats | conversation (like Messages) and *Snippets* = Collections | collection, both with the divider.
    Chat opens on the conversation the reader was last in, a paper's chat included (owner, 2026-10-24: "it needs to take
    me to the chat that I was just looking at, and that specific chat should be selected… on the left"): its row is
    tinted (the Feed's picked-row accent, 12%), marked selected for VoiceOver and scrolled into view, and picking a row
    shows it there, the list staying (`chatBesideList`; on the Mac Chat is still the general chat). A paper's chat says
    its paper under the title. The list's ⋯ (after its search field) has **Sort by** (Last read, Started, Messages,
    Conversation, Paper; kept for the run), as the Library list's ⋯ has; the rows have no Columns. Beside the list the
    chat's ⋯ and title menu have no All chats: no sheet repeats the list (owner, same day: "we're never gonna have this
    middle thing show up"). A paper's chat opened from the paper (Ask, Continue in Chat, a selection) is Discuss.
    **Every route to All chats is this list** (owner, 2026-10-24: "remove the middle pop up window and make [them] go on
    top of their side panel"): the Library's ⋯, a paper's "Chats about this paper", Discuss's clock, the chat's ⋯ and
    title menu beside the paper, and Settings › Your assets › Chats show the Chat place, the list on This paper when the
    route comes from a paper (whose chat is then the conversation beside it) and on All otherwise; Chat from the places
    menu shows All. Never a centred All chats sheet in Wide; Tall and the Mac keep the sheet.
  - *Turning or resizing* (rotation, Stage Manager, fold/unfold) keeps the place, the selection, the open paper and its
    place, the open companion and any draft. Tall's Chat about a paper becomes Discuss; Discuss turned upright is the
    Chat tab with Back to the paper; the Library or Feed with a paper beside them upright are those tabs (the paper is the
    Paper tab), and an explainer beside the paper is the iPhone's sheet. Turned upright on the Library with a paper
    beside it (owner, 2026-10-23: "make sure that the paper we were just reading appears in the middle of the list, and
    it's initially highlighted… and then it dims"), the full-screen list (table or rows) scrolls that paper's row to its
    vertical centre and tints it with the selected-row accent (12%, the Feed's picked-row look), marked selected for
    VoiceOver; the tint fades on its own as the figure explainer's part outline does (full for 0.9 s, the turn included,
    then an ease-in fade over `FigureFullscreenStage.fadeDuration`, 1 s; with Reduce Motion it stays as long, then goes at
    once). The Feed does the same for its picked article. A row not in the list (filtered out, searched past) gets
    nothing; sideways again, the same paper is on the right (`RowReveal`, `RevealTint`).
  - *Selection actions* stay in the system edit menu next to the selection on every shape; no bar of actions sits over
    the page. A text selection's menu is **Copy · Explain in Chat · Save snippet** and nothing else (owner, 2026-10-24:
    "many of the options suck… translate, related papers on a random text selection? It needs to be better thought
    out"): the system's Look Up, Translate, Search Web, Share, Speak and Writing Tools are removed (`ReaderWebView.
    buildMenu` keeps only the system's Copy), and Why it matters, Related papers, Add paper and Draw snippet are not in
    it. Draw snippet stays in the paper's ⋯ and, on the Mac, a right-click with nothing selected. A tapped equation:
    **Chat about Equation · Focus · Copy as Text**. A reference entry: the system's pull-down menu at the entry (a
    vertical list with symbols: Copy, Open on arXiv, Add to library, Discuss in chat), as on the Mac; a tap outside or a
    scroll closes it. Figure pages' text selections get the same trimming (Copy only). The Mac's Paper menu has one
    "Explain Selection in Chat" (⌥⌘1).
  - *Prompts as on iPhone* (owner, 2026-10-24: "make the UX same as iPhone find all instances where this guidance
    applies"): on iPad nothing floats as a centred card over the two slots. In Wide a prompt raised from something in a
    slot (an explainer's model chooser or cloud consent, the equation view's, the chat's consent and answer options, a
    list's Columns, Snippets' sheets, the paper's Find matches, reader version, figure gallery or figure reference)
    covers **that slot only** (`slotSheet`, `Views/SlotSheet.swift`): the slot dims, the sheet rises from its bottom edge
    with a grabber and rounded top corners at the same detent as on iPhone, and closes with its Cancel or ✕, a drag on its
    grabber, a tap on the dimmed slot or VoiceOver's escape (none of them while it asks not to be, as with unsaved text);
    the other slot stays visible, undimmed and usable. A prompt that belongs to the whole app (Settings, sign-in,
    recovery, Get credits, Add paper, reports, Listen's player…) and every sheet upright is the iPhone's sheet scaled up
    (`appSheet` / `phoneSheetSizing`): the window's width upright, a page's size sideways, never the small form sheet
    (iPadOS 18 and later; iPadOS 17 keeps the form sheet). Upright, the AI Explainer, the equation view and a figure page
    cover the page exactly as on iPhone (owner, 2026-10-24: "no need for a UX difference there"). System alerts,
    confirmation dialogs anchored to their control and popovers anchored to their control stay the system's.
  - *Not yet*: Settings as Sections | Page (still a sheet); the Mac's own Wide step (its toolbar holds the five places;
    its Reader is the paper beside a resizable chat column, `ReaderSplit`; pane bars, Return to send and density are
    unchanged). Contents' figure pages in the left slot keep Snippet, Chat and AI Explainer; what they choose applies to
    the paper beside them.
  - *Superseded on Wide (2026-10-23)*: the places capsule in the one top row; one row spanning every pane; "Explain"
    covering the paper's slot (explainers are now companions on its right); "the Library and Feed tables are not in the
    container" (they are each place's left slot); Browse as a view of the Paper place with a ✕ on its list (the Library
    place itself now has the paper on its right); the places button in the top-right corner, with the rightmost slot's
    row ending short of it; a double tap on the divider returning it to the middle; a divider drag that showed a line
    and moved the slots only when it ended.
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
  *Browser* (owner-approved rule, 2026-10-22): information dialogs (Usage, Explanations, Diagrams, Privacy & data, How
  Gradstep works, Keyboard shortcuts, Catalogs, My reports, Columns, AI chat options, Snippet, Listen) open with
  `SheetTop` (`ui/common.tsx`): title or controls on the left, one round ✕ on the right, no Done or Close button
  (Columns' Reset is a link at the end of its list). Task dialogs (Add paper, Report, Sign out, Delete account, New
  collection, Save snippet, Download your assets, Open source, Cloud AI answers) have the title on the left and no ✕;
  Cancel then the verb sit bottom right (a desktop adaptation of the native top-bar placement).
- **Browser tokens** (2026-10-22): `apps/web/src/tokens.css` maps these rules for the web — colour roles written once
  for light and dark, six type steps (24/18/15/14/13/12/11), 4/8/12/16/24 spacing with a 16 px gutter, control heights
  28/32/34/40, radii 4/6/8/12/16/capsule, three elevations, named layers and three motion durations (instant with
  Reduce Motion). Other stylesheets use the names; `tests/style-tokens.test.ts` fails on a new raw font size, radius,
  layer or duration. Components: one Button family (primary, secondary, link) with hover and pressed states, a round
  IconButton, one Menu (32 px rows, accent icons, scrolls within the window), one Segmented, one Chip, one selected look
  (accent words on the accent tint), one Banner for notices in place and one Toast.
- **Browser search, screen options and Settings** (owner, 2026-10-22): off the Library route, searching papers is a mode
  of the left panel, like Mail (`ui/SearchRail.tsx`): its own field with ✕, the Library | ML papers switch inside the
  panel, then a list (title, authors · year). A result opens in the middle; beside the paper the list stays with the open
  paper highlighted (a drawer closes on opening). Esc clears, a second Esc or ✕ puts the panel back as it was (Contents
  or closed). On the Library its field filters the table and the switch sits in its title row. Library and Feed have one
  round "…" at the right of their title rows (`MenuButton` with `SubMenu`s showing the current choice; Library's first
  row is Add paper…). The account menu holds who, Settings…, Keyboard shortcuts, Report this screen… and Sign out…;
  Settings is an information dialog with the apps' sections in their order (`ui/Settings.tsx`).
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
  accent in both appearances), never a fallback message. A caption that names its panels caps the parts; extras are
  outlines on the whole figure. Details: [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Parts as viewports".
  *Full screen on touch* (owner, 2026-10-22: "whenever you try to interact with it, it becomes a full screen thing … with
  not really any in-between"): a card never zooms or pans in place (the page scrolls over it). Any touch — tap, double
  tap, pinch, sideways drag, VoiceOver activate, keyboard, or the Full screen button — opens the full-screen viewer in one
  motion from the card's own place and framing; the part's outline fades over about a second while the whole figure is
  the reader's to pan and zoom (double tap: whole figure ↔ part); X, Escape or a swipe down returns onto the card. Reduce
  Motion: a cross-fade, the outline shown briefly. [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Full screen on touch".

- **Explainer progress** (owner, 2026-10-22: "it needs a progress bar"; "the equations AI explainer needs the same
  progress"): the figure walkthrough and the equation's symbols arrive piece by piece under one progress bar: a stage label
  always, "part k of N" / "symbol k of N" and a filled bar only when N is known, never backwards; placeholders where the
  result will appear, the bar below the last piece shown (nothing above moves), fading at the end; VoiceOver hears stage
  changes only; Reduce Motion: nothing pulses or fades. [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Speed",
  [EQUATION_VIEW.md](architecture/EQUATION_VIEW.md) "Streamed explanation".

- **One AI result per explainer** (owner, 2026-10-21: "Let's not do extract the subfigure … consistently create one good
  product experience in the AI result that comes back"): the figure walkthrough is the only result; looking closer is
  zooming or expanding a part's viewport, never another AI request that makes new crops or a different layout. A part's
  menu keeps one AI follow-up, **Explain more simply** (words under the part, inside the walkthrough), plus the non-AI
  Save snippet, Show in the paper and Ask about this part. A new follow-up is added only if it returns words into the
  same walkthrough. [FIGURE_VIEW.md](architecture/FIGURE_VIEW.md) "Extract the subfigure removed".

- **Study mode** (owner, 2026-10-22: "'Study Mode' is too complex… have 'Enter Study Mode – Quiz me and help me learn' as an
  entry in the suggested questions"): no map, journey or state display. The entry is a row after the starter questions in
  an empty paper chat and the last suggested question under an answer (a command: one tap sends the opening turn); the
  chat's ⋯ keeps Study mode / End study mode. While studying, one slim row sits above the message box — the words
  **Study mode**, then **Hint**, **Explain instead** (each sends at once) and **Stop** (leaves the mode, sends nothing) —
  and the message box reads "Your answer". The tutor's turns are ordinary answers (citations, math, copy, snippets);
  no suggestions beside them. [LEARNING_GUIDE.md](proposals/LEARNING_GUIDE.md).

- **Paper AI Explainer** (owner, 2026-10-22: "in the Paper Settings, have an option that takes you to an optional AI
  Explainer, with background list, and a diagram… with the opening to a chat"): Paper ⋯ › **AI Explainer** opens a page in
  the figure explainer's look and top row (the Open in Chat symbol, the same handoff into Chat): "In short", **Background**
  (one line per prerequisite with its ¶ links), **How it fits together** (one diagram drawn on the device; tap for full
  screen) and the explainer's conversation at the bottom. It streams with the figure explainer's progress rules and is
  kept per paper (Your assets › Paper explanations).

- **Contents discovery** (owner, 2026-10-18): open at full height. On touch devices, double-tapping article text opens
  Contents; links, equations, figures, reference entries and selections retain their own actions. Long-press selection
  remains available, and Mac double-click still selects text. Above the four tabs, show “Double tap anywhere while
  reading the article for this menu” until the gesture succeeds; remember that fact on this device across launches.
  Contents and reference jumps land immediately, including with Reduce Motion off. Bibliography entries show all
  their actions together in a vertical native menu, without a horizontal More page: the system's pull-down menu with
  each action's symbol, anchored at the entry on iPhone, iPad and Mac (owner, 2026-10-24: the action sheet "doesn't follow
  the native iOS style").

- **Rows**: `.headline` title (≤ 2 lines), `.subheadline` authors, `.footnote` details/status; 16 pt side and 12 pt
  vertical padding; at most one trailing icon; navigation rows have a chevron, action rows accent text.
- **Tables**: one `PaperTable` (`Views/PaperTable.swift`) wherever papers show as a table (Library, Feed). Both open as
  the table unless the reader chose List (Feed: owner, 2026-10-24, "Why is the feed default view not a table like the
  library"; at accessibility text sizes both show rows; `FeedLayout(saved:)`). A pinned
  header of `.footnote` semibold titles in secondary color; the sorted one in accent with a chevron (tap to sort, again
  to reverse; "· Added ⌄" beside Title when the sorted column doesn't fit). Title column: `.subheadline` semibold
  title (≤ 2 lines, truncated). Library uses separate Device and Authors columns, enabled by default; the title does
  not repeat those details below it. Pending and completed rows reserve the same two title lines; without the Progress
  column a pending row's title keeps to the first and its spinner and one word (or its problem and action) take the
  second (JUDGMENT_LOG 17, 27). The reader chooses columns (screen options › Columns, a half-height sheet of
  toggles; Title always shows). Every chosen column remains available:
  when they do not fit, the title stays pinned and the other columns scroll sideways, settling at column boundaries.
  Feed's Add and All chats' Last read stay pinned at the right. Wide cells wrap or truncate within the scrolling
  region so a chosen column can be fully read; the Feed's expanded row still holds the full abstract. Values are
  `.subheadline` secondary (numbers trailing), tags small `.caption` chips (≤ 2 lines), statuses an icon and a few
  plain words. A row that needs the reader (a failed import) shows its one action as a small bordered capsule
  (Retry, Get credits, Remove) in its status cell — or, mini, in the title's second line when that column isn't
  shown — never only in a menu. Rows: 16 pt sides, 10 pt vertical; pointer hover and the arrow-key row get a quiet fill; tap or Return =
  the screen's primary action, long-press = actions, swipe = delete-type actions when the columns do not overflow
  (sideways scrolling takes priority when they do); each row is one VoiceOver element
  reading every chosen column, its action button a separate one. At accessibility text sizes the screen's rows
  replace the table. All chats (`Views/ChatHistoryView.swift`) is the same pattern for conversations: one-line
  question with a muted second line, ~52 pt rows (7 pt vertical padding), Last read rightmost, a search field and
  filter chips above. Library adds an optional Venue column; Feed offers Why (For you and topics: why it is suggested,
  sortable by group, an ⓘ beside its header; owner, 2026-10-24), Upvotes (named Popularity until TestFlight 91), Topics, Published, Authors, arXiv ID and Abstract with a Hide papers
  in my library filter, and its List groups For you into sections by why; All chats also offers Topics, Kind and Answer length (latest
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
- **Credits by activity** (Your AI usage › All, owner build 82): a 112 pt ring (inner radius 74%, 1 pt angular inset /
  2 px surface gap between segments) with the period's credits in its centre, and a legend beside it (stacked under it at
  accessibility text sizes): swatch, name (Other lists its members in `.caption` secondary), "credits · share" trailing
  in tabular digits. At most four named segments plus Other, coloured by size from the chart palette — light
  `#2a78d6 #eb6834 #1baf7a #eda100`, Other `#8c8a85`; dark `#3987e5 #d95926 #199e70 #c98500`, Other `#6b6a66` — so
  neighbours are always adjacent slots (validated for colour-blind and normal-vision separation on both surfaces).
  Text never takes a series colour. Tapping a named segment or legend row chooses its chip. The ring's accessibility
  label is the whole chart in words. Code: `Views/AIUsageRing.swift`; browser `UsageRing` in `ui/UsageDialog.tsx`;
  slices `AIUsageFormat.slices` / `usageSlices`.
- **Library topics** (Library › All, owner decision 4, 2026-10-24): under the filter chips, so a chip never moves; one
  header row (chevron, "Topics" and the count, the chosen topic as a ✕ chip, ⓘ) that collapses the chart (remembered).
  Open: the Credits by activity ring at 104 pt (inner radius 72 %), the papers in topics in its centre, and a legend
  (swatch, label on one line, "papers · share" trailing; two columns at regular width with more than four topics). Up
  to eight largest topics coloured by size from the chart palette's eight slots — light `#2a78d6 #eb6834 #1baf7a
  #eda100 #e87ba4 #008300 #6250d6 #e34948`, dark `#3987e5 #d95926 #199e70 #c98500 #d55181 #008300 #9085e9 #e66767`
  (adjacent pairs validated on white and black) — or the reader's colour; the rest is a neutral Other whose row opens
  the smaller topics, "Outside topics" and hidden ones. A slice or row filters the list (selected row tinted, other
  slices dimmed); touch and hold: Rename…, Colour, Hide topic. Code: `Views/LibraryTopicsChart.swift`.
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
  A collection's card is two lines (owner, TestFlight 91): its name, then "N snippets" ("No snippets yet" when empty);
  no date, preview or papers. The open collection's name is edited in place where it is shown (its bar or row), Return
  or leaving the field saves, Escape restores.
  *Snippet entries* (owner, 2026-10-22: "a bit cleaner separation still between the cards with the actual snippet itself
  being a slightly more clear 'box' in a card"): each entry in a collection's stream is the same card (10 pt apart, the
  day label 6 pt above its first card; no timeline line), and its crop or quotation sits in an inner **snippet box**:
  10 pt continuous corners, the grouped tertiary fill (one step from the card in both appearances), a 1 pt separator
  edge (opaque with Increase Contrast), 8 pt around a crop. A leading chevron (44 pt target; VoiceOver "Collapse
  snippet"/"Expand snippet", value Collapsed/Expanded) folds the card to one line — time · short paper title (20
  characters on a phone, 32 wider) · first words of the comment, wrapping to three lines at accessibility sizes; the
  line itself also expands it. Remembered per device, never synced; the collection's ⋯ starts with **Collapse all** /
  **Expand all** (each only when it changes something; one step without animation). No
  animation with Reduce Motion. *Drawing a snippet* shows only the box with its corners and **Use snippet** in the
  page's bottom-right corner (owner, TestFlight 91); Cancel is the bar's. Code: `NoteEntryView`,
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

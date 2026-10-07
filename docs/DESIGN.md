# Design principles and patterns

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
- **Floating chrome** (2026-10-07, after Gemini; shared code in `Views/Chrome.swift`): bars float over content, which
  runs to the screen's edges behind them and fades out softly.
  - *Tab bar*: one glass capsule, 58 pt tall, 16 pt from the sides (at most 520 pt wide on iPad), sitting in the home
    indicator's area. Each screen keeps room for it inside its NavigationStack (`tabBarSpace()`), so the last row
    scrolls clear of it with an 8 pt gap. It hides while a software keyboard is up. It does not shrink on scroll.
  - *Headers*: the controls (Library search, + and …; Feed topics and …) float on a
    band (`chromeBand(.top)`) that is 94–100 % the screen's background behind them, then fades out over 22 pt.
    Taps on the band stay with it; the fade below lets them through. Over a table the band stays solid (the column
    titles pin right under it). System title bars (Paper, Chat, Settings) keep the system's own treatment.
  - *Chat*: nothing sits between the title bar and the conversation, which runs the full height, under the title
    bar, the message box and the tab bar. Paper chat / General chat is the title's menu (chevron after the title;
    under it the paper, tap to return, or "General chat"). The message box is a glass pill with the placeholder
    "Chat" and Send/Stop inside it on the right, 10 pt above the tab bar on the bottom band (`chromeBand(.bottom)`);
    the hide-keyboard button is a glass circle beside it (not on the Mac).
  - *Paper*: the page sits between the title bar and the tab bar's room; the reader's floating controls (selection
    actions, Back, a reference's outcome) float over its last lines on the bottom band, which also fades the page
    under the tab bar. The page's viewport never changes size as controls come and go: reading positions and
    heading and citation jumps are measured in it (running the page under the tab bar, or shrinking it for the
    selection bar, moved the reading position near a paper's end).
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
  accent for information, orange for problems), shown only when the reader can act, scrolling with content.
- **Sheets**: centered inline title; information sheets have Done on the right; task sheets have Cancel on the
  left and the confirming action on the right; short sheets open at medium height.
- **Rows**: `.headline` title (≤ 2 lines), `.subheadline` authors, `.footnote` details/status; 16 pt side and 12 pt
  vertical padding; at most one trailing icon; navigation rows have a chevron, action rows accent text.
- **Tables**: one `PaperTable` (`Views/PaperTable.swift`) wherever papers show as a table (Library, Feed). A pinned
  header of `.footnote` semibold titles in secondary color; the sorted one in accent with a chevron (tap to sort, again
  to reverse; "· Added ⌄" beside Title when the sorted column doesn't fit). Title column: `.subheadline` semibold
  title (≤ 2 lines, truncated) and the first author in `.footnote` secondary. The reader chooses columns (screen
  options › Columns, a half-height sheet of toggles; Title always shows); of those, columns are added by priority
  while they fit, never scrolling sideways, and the chooser says "Shown when there's room" for the rest. Values are
  `.subheadline` secondary (numbers trailing), tags small `.caption` chips (≤ 2 lines), statuses an icon and a few
  plain words. A row that needs the reader (a failed import) shows its one action as a small bordered capsule
  (Retry, Get credits, Remove) in its status cell — or under the title when that column isn't shown — never only in
  a menu. Rows: 16 pt sides, 10 pt vertical; pointer hover and the arrow-key row get a quiet fill; tap or Return =
  the screen's primary action, long-press = actions, swipe = delete-type actions; each row is one VoiceOver element
  reading every chosen column, its action button a separate one. At accessibility text sizes the screen's rows
  replace the table. All chats (`Views/ChatHistoryView.swift`) is the same pattern for conversations: one-line
  question with a muted second line, ~52 pt rows (7 pt vertical padding), Last used rightmost, a search field and
  filter chips above.
- **Filters**: quick filters are `ChipButton`s in one horizontally scrolling row that scrolls away with the rows
  (open space while browsing); a menu chip comes first (Tags ⌄); only filters that would change the list appear,
  and the row is hidden when none would. A problem count (Failed 2) is orange.
- **Empty states**: `ContentUnavailableView`, one sentence, one prominent button; hide controls that can't work.
- **Details on demand**: screen options in "…"; per-item actions on long-press (swipe for delete-type actions);
  long explanations behind a row.

Each UI change follows the [visual check loop](VISUAL_CHECK.md); significant redesigns get an independent audit
against this page.

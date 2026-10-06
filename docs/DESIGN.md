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
- **Empty states**: `ContentUnavailableView`, one sentence, one prominent button; hide controls that can't work.
- **Details on demand**: screen options in "…"; per-item actions on long-press (swipe for delete-type actions);
  long explanations behind a row.

Each UI change follows the [visual check loop](VISUAL_CHECK.md); significant redesigns get an independent audit
against this page.

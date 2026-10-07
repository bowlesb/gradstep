# Visual checks

How a UI change is confirmed and refined, not thrown over the fence: reproduce the screen, capture it before and
after across devices and appearances, review the images, iterate, then lock the result in with a test. Used for
feedback from [test sessions](SESSION_REVIEW.md) and for any UI change.

## Scenarios

`apps/apple/ScienceReaderUITests/VisualScenarioTests.swift` holds named, deterministic screens built from fixtures
(no network, no account): `library`, `library-search`, `library-table`, `library-table-browse` (iPad landscape: the
table in the Browse column), `library-detailed`, `library-metadata-list`, `library-slow-import`, `library-slow-import-table` (an import taking
longer than usual, one a minute into downloading, one failed), `library-import-progress`, `library-import-progress-help`,
`library-import-progress-table` (imports at every step with percent and time left; the explainer sheet), `library-swipe`, `feed`, `feed-results` (the Feed's
List over fixture results), `feed-table`, `feed-table-abstract` (a row's abstract open), `paper`, `paper-contents`, `chat-conversation`, `chat-keyboard`,
`chat-answer`, `chat-diagram`, `chat-sources`, `chat-credits`, `store`, `store-signedout`, `settings`, `settings-end`, and for the
design audit the layer below the surface: `library-options`, `library-add`, `paper-options`, `paper-selection`,
`chat-history`, `signin`; All chats over ~30 fixture conversations (`--chat-history-fixture`): `chat-history-table` (with
an unsent draft), `chat-history-search` ("DPO"), `chat-history-actions` (a row's long-press menu), `chat-title` (a selection action's
conversation opened: its short title); signed in (`--chat-fixture`) `settings-account`, `settings-account-end` and
`account` (the Account page), and signed out `about` and `acknowledgements`; and over the real DPO fixture (`--offline-reader-fixture --mathpix-reader-fixture`) `paper-top` (publication line),
`paper-citation`, `paper-reference` (after a citation, Back shown) and `paper-reference-actions`. Add a scenario
when feedback concerns a screen that isn't covered; reproduce the state from the session timeline (tab, sheet,
keyboard, orientation, device). Screens that need real data use the staging journey (`scripts/live-journey.mjs`).

The `library-*` layout scenarios use `--library-metadata-fixture` (varied authors, years, topics, added dates,
this device's opened/progress values, chats, a converting and a credit-blocked import) and `--library-layout=table`
or `=detailed`; the table is the shared paper table on every device, with more columns in landscape and on iPad
(at the `xl` accessibility size it shows detailed rows, so use `xxl` to see the table at large text). The Feed's
table scenarios add `--feed-fixture --feed-layout=table`. Fixture runs reset both layouts to List unless an
argument names one.

## Commands

```sh
node scripts/visual-check.mjs capture --label=before --scenarios=chat-keyboard,store \
     --devices=iphone,small,ipad --variants=light,dark,xl [--landscape]
# … change the code …
node scripts/visual-check.mjs capture --label=after  --scenarios=chat-keyboard,store --devices=iphone,small,ipad --variants=light,dark,xl
node scripts/visual-check.mjs compare --before=before --after=after
```

- Parallel sessions use their own Simulators and build folder: `--udids=iphone:<UDID>,ipad:<UDID>` runs those device
  names on the given Simulators (same models), and `--derived=/private/tmp/<session>/derived` keeps builds apart.
- Devices: `iphone` (17 Pro), `small` (17e), `max` (17 Pro Max), `ipad` (Pro 11"), `ipad13` (Pro 13"), `mini` (iPad mini). Variants:
  `light`, `dark`, `xxl` (the largest text below the accessibility sizes), `xl` (accessibility extra large text). The status bar is pinned to 9:41 and full battery.
- Output: `.artifacts/visual/<label>/<device>-<variant>/<scenario>.png`, a contact sheet `<label>-sheet.png`, and
  for compare `compare-<before>-<after>/` with side-by-side images (before | after | changed pixels in red) and
  `report.md` sorted by the share of changed pixels. Over 0.3 % is flagged: confirm every flagged screen changed
  on purpose (the caret and animations cause small differences).

## Loop for a piece of feedback

1. Find the moment in the session (frame + timeline) and restate the feedback as an expected result.
2. Capture `before` for the scenarios that show it (add one if needed) on the devices and variants it affects.
3. Change the code; capture `after`; compare. Look at the after images next to the session frame: does it now do
   what the feedback asked, on every device and variant? Iterate until yes. Check flagged unrelated screens.
4. Lock it in: a UI assertion when the result is measurable (an element visible above the keyboard, not clipped,
   inside its container), otherwise keep the scenario so later comparisons catch regressions.
5. Report with the before/after images; anything the Simulator can't judge (feel, timing, real data, device
   keyboard) is marked "needs your eye" and goes to the next TestFlight build.

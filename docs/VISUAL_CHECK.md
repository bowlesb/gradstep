# Visual checks

How a UI change is confirmed and refined, not thrown over the fence: reproduce the screen, capture it before and
after across devices and appearances, review the images, iterate, then lock the result in with a test. Used for
feedback from [test sessions](SESSION_REVIEW.md) and for any UI change.

## Scenarios

`apps/apple/ScienceReaderUITests/VisualScenarioTests.swift` holds named, deterministic screens built from fixtures
(no network, no account): `library`, `feed`, `paper`, `paper-contents`, `chat-conversation`, `chat-keyboard`,
`chat-answer`, `chat-diagram`, `chat-sources`, `chat-credits`, `store`, `settings`, `settings-end`. Add a scenario
when feedback concerns a screen that isn't covered; reproduce the state from the session timeline (tab, sheet,
keyboard, orientation, device). Screens that need real data use the staging journey (`scripts/live-journey.mjs`).

## Commands

```sh
node scripts/visual-check.mjs capture --label=before --scenarios=chat-keyboard,store \
     --devices=iphone,small,ipad --variants=light,dark,xl [--landscape]
# … change the code …
node scripts/visual-check.mjs capture --label=after  --scenarios=chat-keyboard,store --devices=iphone,small,ipad --variants=light,dark,xl
node scripts/visual-check.mjs compare --before=before --after=after
```

- Devices: `iphone` (17 Pro), `small` (17e), `max` (17 Pro Max), `ipad` (Pro 11"), `mini` (iPad mini). Variants:
  `light`, `dark`, `xl` (accessibility extra large text). The status bar is pinned to 9:41 and full battery.
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

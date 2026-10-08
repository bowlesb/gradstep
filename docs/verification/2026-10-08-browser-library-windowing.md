# Browser library windowing — local verification, 2026-10-08

Status: implemented and locally verified in an isolated web worktree, based on integration `e67309d`.
Not deployed. Full native table rendering remains the default. Default windowing is not approved: the
owner's browser-menu Find tradeoff question is still pending. No client limits, backend quotas,
replication, search semantics, private storage or supported-capacity claims change.

## Behavior and boundaries

- Columns offers **Show rows as you scroll** for at least 100 matching rows. The preference and viewport
  live only in the current account session, and survive reader navigation. A new session starts with
  all rows. Search, filters, ordering and counts still use the complete retained model.
- The optional window uses pinned `@tanstack/react-virtual` 3.14.13 with measured native table rows,
  stable item keys and a spacer for every unmounted gap. Header and title-column stickiness remain
  native CSS. Logical row indices and the complete result count remain exposed.
- Arrow, Home/End and Page keys address logical readable rows, including unmounted rows. The focused
  row stays mounted. A removed focused row lands focus on the table region. Portaled controls retain
  their row while focus is under `data-library-row-owner="item:<uuid>"`; leaving that owner releases it.
- Tab, keyboard Select All, native text selection and keyboard Find expand real rows. Both modes use
  the same keyed row wrappers, preserving the selected/focused nodes. Full mode remains chosen after
  these interactions and through reader return. Existing text selection prevents switching back to
  windowing until it is cleared.
- Browser-menu Find has no page event, and **cannot find unmounted rows while windowing is opted in**.
  The Columns control explains this and the full screen-reader browsing boundary. Full rendering as
  the default preserves existing browser-menu Find behavior. No hidden text mirror is used.
- Anchors use stable row key plus pixel inset and horizontal position. They are restored after live
  reorder, columns/width/font changes, reader return and printing. A removed anchor falls back to its
  former logical position, bounded by the surviving rows; an inset is clamped if its row becomes shorter.
  Explicit query/sort changes begin at the first result. New wheel, touch, pointer and keyboard input
  cancels pending restoration.
- Scroll capture uses binary search over mounted native rows, including in full mode. Complete measured
  snapshots are taken at navigation/click/print boundaries, not every scroll event. Completed measured
  layouts also update the cheap anchor because row measurement can move content without a scroll event.
- Printing temporarily expands every matching row, removes clipping/stickiness, and restores the prior
  window, anchor and focus afterward. The tests exercise print events and print CSS, including the cancel
  path. A real browser print dialog, printed PDF pagination and physical printer were not exercised.

## Checks

`npm run build` passes (the existing large diagram chunk warning remains). All 211 unit tests pass.

Twenty targeted Chromium journeys cover desktop 1280×860 and phone-width 390×844 under production CSP:

- Seven new cases per viewport: opt-in/default and keyboard/reader return; distant retained focus plus
  native Tab/Shift+Tab; selection node identity and keyboard Find; width/columns/20px text/reduced motion
  and return after another width change; live tag reorder and removal of the focused row; print expansion
  and cancellation; and focus ownership in a portaled row menu.
- The existing two chosen-column/storage-failure cases and complete-library live-import/search case
  pass at both sizes. The overflow assertion now reads both widths atomically, avoiding comparison across
  the workspace's compact-breakpoint transition. The reader-return test explicitly focuses without
  Playwright click auto-scroll before recording its expected anchor.

The main run passed 18 cases; the two test-only corrections above were followed by four passing focused
reruns (both viewports). Final production source is the same across those accepted runs. No full browser
suite ran concurrently. No hosted/provider calls, physical phone, NAS or desktop automation were used.
Safari key persistence, VoiceOver traversal and default windowing rollout are not established by these checks.

Commands, from `apps/web`:

```sh
npm ci --ignore-scripts
npm test
npm run build
WEB_E2E_FIXTURE_PORT=54379 WEB_E2E_APP_PORT=4367 WEB_LIBRARY_LABEL=windowed-opt-in npx playwright test e2e/library-window.spec.ts e2e/library-columns.spec.ts e2e/library.spec.ts --project=desktop --project=phone
WEB_E2E_FIXTURE_PORT=54379 WEB_E2E_APP_PORT=4367 npx playwright test e2e/library-window.spec.ts e2e/library-columns.spec.ts --project=desktop --project=phone --grep 'stable key|chosen columns' --output ../../.artifacts/web-e2e/library-window-rerun
```

## Local observations and artifacts

The fixture has 4,000 retained entries and 3,999 matching rows; it tests the client wire bound, not the
backend item/import quota mix. Initial recovery renders all rows before the explicit opt-in. The timed
~3.21-second idle window then observes one ticking import with all detail columns chosen.

| Observation | Desktop | Phone width |
| --- | ---: | ---: |
| Matching rows | 3,999 | 3,999 |
| Mounted rows after opting in | 22 | 21 |
| Recovery to full default library | 1,329 ms | 786 ms |
| Search to matching result | 16 ms | 15 ms |
| Script during observation | 1.94 ms | 1.84 ms |
| Task duration during observation | 20.68 ms | 16.54 ms |
| Layout during observation | 1.11 ms | 1.71 ms |

These are one-run local observations, not capacity acceptance budgets or a scrolling benchmark. CDP's
renderer-wide node count includes the initial full DOM and detached allocations, so it is not used as
proof of bounded live rows or retained memory. No 10k/50k claim is made.

Local artifacts remain under `.artifacts/web-library/windowed-opt-in-*-metrics.json`,
`.artifacts/web-columns/`, and `.artifacts/web-e2e/results/library-window-opt-in-keyb-*/`.
The desktop and phone `windowed-dark.png` and `windowing-choice-dark.png` screenshots were visually
inspected; the real table and Columns dialog fit their viewports with the Find choice visible.

Relevant platform references: [TanStack Virtual API](https://tanstack.com/virtual/latest/docs/api/virtualizer),
[React flushSync and printing](https://react.dev/reference/react-dom/flushSync), and
[ARIA row count](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Attributes/aria-rowcount).

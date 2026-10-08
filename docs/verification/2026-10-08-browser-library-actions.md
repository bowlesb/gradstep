# Browser library actions — local verification, 2026-10-08

Implemented in `codex/web-library-actions-20261008`, based on `c70723f` plus the reviewed
windowing change `4ffa84e` (local cherry-pick parent `8640400`). The action commit is the
integration unit; do not cherry-pick the duplicate windowing parent again.

No deployment or hosted/provider call was made. These are v2 public-library commands over the
existing v3 read path. Private uploads/v5 and shared native/backend code remain outside this change.

## Behavior and integration

- Full and compact libraries each own one `useLibraryActions` controller and
  `LibraryActionSurface`. Rows contain only a trailing `PaperMenuButton`; no per-row dialog trees.
  `useLibraryModel` exposes its existing library controller to the compact view, so no App, Feed,
  or Reader hook is required.
- Edit tags follows `PaperTags.swift`, `TagEditorView`, and migration 030: removable chips,
  canonical vocabulary names, category/removed/other-paper suggestions, Add, Cancel and Save.
  Normalization enforces 40 Unicode scalars, 120 UTF-8 bytes, 12 own and 8 hidden tags,
  case-insensitive uniqueness, and rejects lone JS surrogates. Own tags remain service-visible;
  the dialog says they are not end-to-end encrypted.
- Dirty Escape/backdrop dismissal preserves the draft. Explicit Cancel discards it. Save cannot
  silently ignore text still in the Add field. A revision conflict retains the chosen tags and
  disables another save until explicit **Reload current tags** captures the latest complete item.
- Archive, Unarchive and Remove require confirmation. Removal follows the existing membership
  command and clears personal tags. Existing import Retry/Remove behavior is unchanged.
- Item commands bind the receipt to the frozen item ID, document ID and membership revision.
  `expectedItemID` is local and never sent as an RPC argument. Tag arrays are copied before the
  first await, so a retry sends the same operation UUID and payload even if the caller changes
  its draft. Both the UI and hook limit these new actions to visible `shared_catalog` items.
- User-visible success follows `useLibrary`'s complete post-receipt observation, never an
  optimistic row update. A received receipt plus failed pull locks the form and offers
  **Refresh library**. Focus/background refresh can finish that same receipt without resubmission.
- Menu arrow/Home/End/Enter/Escape/Tab, pointer dismissal and button toggle are supported. Menus
  and dialogs carry `data-library-row-owner="item:<uuid>"`. The windowing owner approved the tiny
  `LibraryRowsCommands.beforeSequentialNavigation()` hook: portal Tab expands all real rows,
  preserves the existing skip-restore behavior, then resumes native traversal at the trigger.
  Default rendering remains full; optional windowing is unchanged.
- An intentionally empty effective tag list no longer falls back to categories when a real tag
  projection exists. Unprojected rows retain their existing category fallback.

## Verification

Local worktree: `/Users/benbowlwes/science-reader-web-library-actions-20261008`.
Fixture/app ports: `54389` / `4377`. Browser slot was released to root after the focused run.

| Check | Result |
| --- | --- |
| `npm test` | 264 passed in 23 files, including 19 new tag/command tests |
| `npm run build` | Passed; existing bundle-size advisory remains |
| Initial desktop action journeys | 10 passed |
| Actions + existing command/windowing regression run, desktop and phone | 49 passed / 1 measurement-timing failure; see below |
| Isolated original phone selection/Find test, without an anchor source fix | Passed |
| Final focused production-CSP Chromium run | 26 passed: 22 action journeys plus desktop/phone native Tab and selection/Find |
| `git diff --check` | Passed |

The 11 action journeys at each width verify menu keyboard/pointer behavior and Cancel,
Unicode limits and canonical suggestions, hiding all catalog tags, server-committed/lost-response
replay with the identical UUID/body and only one receipt, revision races with/without a failed
post-receipt pull, refresh-only recovery, archive/unarchive filters, mixed removal/live and completed
import mapping, compact editing without navigation, actual dialog/menu ownership with optional
windowing, and external auth retirement while an accepted response is delayed.

The final real-portal test additionally checks that Tab expands 399 actual rows and focuses the
exact adjacent title link. Existing command tests all passed in both widths; those prove grouped
receipt observation, older in-flight reads, concurrent commands, and failed-refresh recovery.

Artifacts (ignored, local):

- `.artifacts/library-actions/chromium.log` and `chromium/`: the 49/50 run and original failure trace.
- `.artifacts/library-actions/phone-selection.log`: isolated unmodified selection test passing.
- `.artifacts/library-actions/final-focused.log` and `final-focused/`: final 26/26, with desktop and
  phone tag-editor, saved-tag and conflict screenshots. The final phone editor and desktop conflict
  screenshots were visually inspected; controls remain within the dialog and long tags wrap.

### Original selection-test failure

The phone 4,000-entry test kept the selected text node, text and row identity but observed an
11.40625 px inset difference (threshold remains less than 3 px). Trace:
`chromium/library-window-native-text-d7a82--preserving-selection-nodes-phone/trace.zip`.

The trace shows the synthetic deep scroll beginning at 167214 ms, saved-anchor evaluation at
167234–167245 ms, and selection at 167245–167254 ms. The setup only waited for `scrollTop > 29000`;
it did not establish settled row measurements. Locator evaluation return values are absent from
that trace, so the sign of the original saved inset cannot be recovered. The exact case passed in
isolation before changing any production anchor code.

At root's request, `deep()` now waits for the actual row key, inset, scroll top and row height to
agree within 0.25 px over four successive animation-frame samples. It is bounded at 120 frames
and reports its last five samples on failure. The subsequent less-than-3-px anchor check and exact
row/selection identity checks are unchanged. No production anchor/restoration workaround was made.
Both desktop and phone selection/Find and native Tab cases pass with this settled setup.

## Remaining boundaries

Root still independently reviews and runs the combined App/profile/podcast acceptance suite.
This checkpoint does not establish hosted readiness, Safari durable-key support, or physical-device
behavior. The fixture follows the migration 010/020/030 receipts and revision contracts; it is not a
live database integration test.

The command queue and tag drafts are session memory only. One automatic lost-response resend
uses the same UUID. A received receipt survives a failed refresh in that mounted account session;
reloading/signing out does not persist its pending form. After two connection failures the UI tells
the reader to check the library before retrying. This is not a durable command outbox claim.

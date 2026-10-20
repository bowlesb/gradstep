# Recent changes across iPad, browser and Mac

Status: implementation and verification in progress; not yet released. Owner request, October 20: take recent
changes to iPad, web and macOS as well. The responsiveness repairs are included. The no-markup dollar-balance
request remains a separate, unfinished accounting change, with its shared-client contract in
[Dollar balance](../architecture/DOLLAR_BALANCE.md); it is not relabeled as a completed port.

## Baseline

iPad shares the native iOS target; Mac uses the Catalyst target. Both TestFlight 76 archives were built from
365aeaa and are verified VALID / IN_BETA_TESTING. Browser Pages a19c9248 contains c461f6b.
Shared source is evidence of inclusion, not of every platform interaction working.

| Change | iPad | Browser | Mac |
|---|---|---|---|
| Account deletion and returning invited users | Shared deployed Auth repair; native callbacks tested | Deployed; refusal handling and hosted synthetic lifecycle tested | Same server and native callbacks; build 74 onward |
| Recover queued keyword edits | Native transport repair, build 74 onward | Existing source-details transport; no corresponding allowlist defect | Same repaired transport, build 74 onward |
| Named catalogs, defaults and deletion dispositions | Screen journey passed; build 75 onward | Create/rename/default/restart/add/move/delete journeys now pass at four screen sizes | Dedicated create/rename/default/switch/move-delete journey now passes |
| OpenRouter for every cloud model and account attribution | Deployed shared backend | Deployed shared backend | Deployed shared backend |
| Contents, equation/figure explainers, references, columns and instant section jumps | Included in build 73 onward; affected journeys recorded | Deployed parity; affected journeys recorded | Included in build 73 onward; affected journeys recorded |
| Unlimited owner testing | Server policy; label in build 76 | Policy and label deployed | Policy and label in build 76 |
| Stable native chat rows and deferred streaming during gestures | Motion and keyboard evidence recorded; build 76 | Paper and figure chat touch/wheel/idle checks pass at four screen sizes after the follow repair | Real wheel motion in both directions and streaming/idle anchor checks now pass |
| Faster navigation response | Single-pass paper configuration and composer focus without fixed delay | Draft checkpoint no longer blocks routing; account-owned persistence and failures remain tracked | Same native changes; exact configuration equality and instant Contents jump verified |
| Actual dollar balance, detailed provider spending and category view | Pending new accounting contract | Pending same contract and UI | Pending same contract and UI |

Mac-only local answering remains intentional. No replacement model has passed qualification, so its downloadable
model catalog remains empty; do not ship an unqualified model merely to fill the picker. Subfigure training is
research and is not a released feature on any platform.

The new iPad journey exposed a missing adaptation: `.large` alone still opened Contents as a short centered form
(tabs at y=400 on a 1376-pt screen). Explicit iOS 18+ page sizing now opens the existing sheet at full reading height.
The tabs, X, navigation and double-tap discovery stay the same; Catalyst retains its existing window sheet.
The full-height/discovery/relaunch and equation-tile journeys pass after the change. Apple's
[presentation sizing contract](https://developer.apple.com/documentation/swiftui/view/presentationsizing(_:))
was checked before implementation; screenshot inspection confirms the actual displayed height.

## Navigation and scrolling changes under review

The browser's app-level navigation used to await `ChatSession.flushCheckpoints()`. This drained asynchronous
encryption, IndexedDB and earlier accepted writes before applying the route. The session already owns the draft
independently of the mounted chat. Navigation now starts the checkpoint immediately, applies the route, and reports
any later storage failure against that same live account. Sign-out, deletion and storage retirement keep their
existing barriers. A deliberately blocked encryption call reproduces the original delay; the repaired journey
can leave, return, edit, release the block and reload the exact latest draft without a model request.

Browser transcript following used a one-event boolean to ignore its own scroll. A real input could occur between
the programmatic position change and its event. Input now takes ownership before text can follow again; only a
matching programmatic position is ignored. A real touch held during streaming moves the old implementation
**1,541 CSS pixels**; the repaired paper and figure journeys stay within **1 pixel**, then exercise wheel
scrollback, completed-content stability and Latest message. Unit checks cover delayed events and held input.
Moving that finger also exposed a second cause: browser pan recognition sends `pointercancel` before the finger
lifts. Treating it as release allowed the same jump. Touch ownership now ends at the final `touchend` or
`touchcancel`; pointer release remains appropriate for mouse/stylus. The final journey requires the real
touch-move cancellation before measuring incoming-text growth and position.

Figure/equation promotion now focuses the exact retained main-chat composer after the dialog releases focus.
The browser regression preserves separate unsent main/figure drafts, promotes, reloads and sends only explicitly.
It passes on desktop, phone and both tablet sizes. Native paper configuration now encodes once rather than making
a Foundation JSON round trip on the main thread. Both configurations are semantically identical. On this Mac,
40 DPO configurations take 0.1211 s before and 0.0523 s after (about 3.0 → 1.3 ms each). This is a small measured
setup improvement, not a claim that all navigation latency is resolved.

## Separate unresolved feedback

The four outstanding October 18 screenshots in OWNER_FEEDBACK.md are not being relabeled as fixed by this audit:
keyword-menu ordering, clipped subfigures, returning to the wrong chat position, and figure double-tap zoom.
Their remaining implementation/quality work is distinct from porting an already completed change.

## Evidence

Artifacts live under `.artifacts/parity-20261020/`:

- `web-parity-current.log`: 24 passing catalog/navigation/paper-motion cases; four promotion-focus failures,
  retained as the evidence that led to the focus fix.
- `promotion-navigation-final.log`: promotion/reload passes at all four sizes. Its four old podcast assertions
  are superseded by `web-podcast-navigation-final.log` (4/4): later navigation wins even while persistence waits.
- `web-motion-navigation-final.log`: paper and figure motion pass at all four sizes (8 cases). The four obsolete
  podcast route assertions in that run are superseded by the later focused run.
- `navigation-before.log` and `web-motion-negative-control.log`: old behavior fails the new checks.
- `web-pointer-cancel-before.log`: the intermediate repair still jumps 1,541 px when touch movement cancels its
  pointer. `web-motion-final.log` passes all **8/8** paper/figure cases at four sizes with that gesture included.
- `mac-navigation.xcresult`: exact paper configuration, instant Contents jump and four Mac keyboard journeys pass.
- `mac-parity-final.xcresult`: real wheel/streaming/idle motion passes. Its catalog test assumed every row in a
  compact Catalyst form was instantiated; `mac-catalog-scroll.xcresult` passes after scrolling to the final action.
  Earlier alert/menu-selector and test-compilation failures remain in their original result bundles.
- `mac-figure-focus.xcresult`: the full figure journey passes, including a viewer sized to its actual window,
  keyboard dismissal, and typing into the promoted composer without first tapping it. Its screenshot was reviewed.
- `webkit-parity.log`: eight capability skips, **not Safari acceptance**. This Playwright WebKit engine cannot
  complete the existing durable nonextractable X25519 key probe. No key-storage restriction was relaxed.
- `web-figure-final.log`: 4/4 figure-chat motion journeys, strengthened to require a decoded, in-viewport figure
  on opening. Scrolling the outer sheet to its contextual chat can intentionally put that figure above the visible
  area; the exploratory post-scroll visibility assertion was not a rendering defect.
- `ipad-parity.xcresult`: configuration equality, catalog management, equation tiles and split-chat keyboard pass.
  The short Contents sheet failure led to the sizing repair. Its crop-pinch failure is a test-input issue:
  the recorded event starts its fingers only 6.2 pt apart and moves each about 11.1 pt in the 140×160 pt crop.
  `ipad-contents-figure.xcresult` passes all three affected journeys after the page-sizing repair and a wider test
  pinch; the actual crop changes from **100% to 170%**. The zoom implementation is unchanged.
  The full figure journey also verifies typing into the promoted composer without first tapping it.
- `fast.log`: the complete routine tier passes; the final changed browser units also pass **495/495** in
  `web-units-final.log`. `web-build.log` records the earlier production build and deployment-output checks;
  the final build is recorded separately in `web-build-final.log`.

Release checks and deployment identities will be recorded as they finish. Existing unchanged behavior
retains its evidence in TESTING.md, IMPLEMENTATION_STATUS.md and release 76. Physical iPhone access remains paused.
These checks use local synthetic answers and make no paid provider requests.

# Test session review

The owner uses the app with a recording running; the agent finds problems from the recording and its event log,
confirms them against the code, and fixes them with tests. No per-bug reports needed. Built 2026-10-05 after
TextBrain's attempt (its lessons are below); expect several rounds of tuning, measured in the
[ledger](session-reviews/LEDGER.md).

## Recording (owner, on the phone)

1. TestFlight build → Settings › Testing › **Record a test session** (optionally **Include my voice** first). Allow
   the screen-recording prompt.
2. Use the app normally. A slim strip on the right edge shows the session is running: **⚑** marks a moment
   ("something's off here"), **■** stops. Talking is optional; the review does not depend on it.
3. Stop. The share sheet opens with one zip: **AirDrop it to the Mac** (it lands in Downloads). Sessions stay on the
   phone until deleted (Settings › Testing › Recorded sessions keeps the newest five) and are never uploaded.

## What is recorded

- `screen.mp4`: the app's screen (ReplayKit records app content only, not the status bar or system sheets such as
  the App Store purchase sheet, Safari or the share sheet) and, with voice on, the microphone.
- `timeline.jsonl`: events in seconds since the start (monotonic clock), written as they happen:
  - `state`: changes to what is visible: tab, sheet, selected paper (short ID), messages shown (`error`,
    `chat_issue`, `reader_issue`, `library_issue`, …), activity (`busy`, `answering`, `opening_paper`, imports),
    credits, sync status. The full state is logged once when recording starts.
  - `touch` (began/ended, x/y in points), `request` (method, path without query, status, ms, bytes), `hang`
    (main thread stalled > 400 ms), `keyboard`, `orientation`, `scene`, `memory_warning`, `mark`, `chrome` (the
    recorder strip's frame), `sync_band`.
  - Never paper or chat text; message texts are the app's own wording.
- `meta.json`: build, device, iOS version, whether video and voice were recorded.

The app shows a magenta band across the top edge for 0.7 s when recording starts; the review tool finds it in the
video to line up video time and timeline time (TextBrain drew a marker but never scanned for it).

## Preparing the review (Mac)

```sh
node scripts/session-review.mjs            # newest paperstep-session-*.zip in ~/Downloads
node scripts/session-review.mjs path.zip   # or a specific zip / unpacked folder
node scripts/simulator-session.mjs         # pipeline regression check: a scripted Simulator session
```

This unpacks into `.artifacts/sessions/<id>/` (gitignored) and runs `tools/session-review` (Swift; AVFoundation,
Vision, Speech; nothing to install). Output in `<id>/review/`:

- `review.md`: header (sync result, recorder strip position), **Signals** (problems detected from the timeline:
  messages shown, failed or slow requests, hangs, repeated taps — 3+ taps within 1.5 s and 44 pt, long waits,
  memory warnings, marks, narration with problem words), **Narration** (transcribed on device with Apple's
  SpeechAnalyzer, which works from a command-line tool without a permission prompt), and **Timeline by screen** with
  frame links.
- `frames/*.jpg`: 600 px keyframes at every signal, after every state change and touch, and every 1.5 s when the
  screen changed (near-identical frames dropped; at most 90). Red rings mark touches within 0.35 s.
- `review.json`: the same data, plus on-screen text (Vision OCR) per frame.

## Review procedure (agent)

Follow it in order every round so results are comparable.

1. **Check the header.** If the sync marker was not found, treat frame timing as ±1 s.
2. **Signals first.** For each, open its frame and the frames around it; decide expected vs actual. Classify as
   bug, UX problem, expected behaviour, or test artefact (the recorder strip, a deliberate test action).
3. **Narration and marks.** Every remark and every ⚑, flagged ones first; open the frames around them.
4. **Visual pass, screen by screen.** Look at one or two frames per screen segment for layout defects: clipped or
   overlapping text, truncation, unreadable contrast, controls hidden by the keyboard, stale or wrong content, a
   spinner that does not end, inconsistent state between screens.
5. **Behaviour pass.** Taps followed by no state change, request or visible change within 1.5 s (dead taps);
   back-and-forth navigation; repeated attempts at the same action.
6. **Confirm in the code** before calling anything a bug: find the view or model path, explain the cause. Never
   report from one ambiguous frame; say "unsure" instead. The recorder strip and ReplayKit's missing system sheets
   are not app problems.
7. **Write findings** to `<id>/review/findings.md`, one block each:
   `F<n> · mm:ss · bug|ux|unsure · confidence high|medium|low` — evidence (frames), expected, actual, cause
   (file:line), proposed test.
8. **Fix confirmed findings with tests first**: a UI or unit test that reproduces the problem and fails before the
   fix (fixtures for UI where possible; a fixture that models the wrong behaviour is worse than none). Then fix,
   run the test and the affected suites. For anything visual, follow the [visual check loop](VISUAL_CHECK.md):
   before/after screenshots across devices and appearances, compared with the session frame, iterated until right.
9. **Report** to the owner: findings with frames, what was fixed, what is unsure and needs their eye.
10. **Update the [ledger](session-reviews/LEDGER.md)**: confirmed, false and unsure findings, fixes and tests; and
    later, problems the owner points out that the review missed. Precision = confirmed / (confirmed + false).

## Privacy

Recordings can show private library and chat content. They stay on the phone and in `.artifacts/sessions` on the
Mac; they are never uploaded or committed. Findings, commits and docs quote only the app's own interface text, never
paper or chat content from a frame.

## Lessons from TextBrain (2026-08)

TextBrain's recorder worked once end to end and was then abandoned. What we changed: it depended on narration and
pins (pins were never used; narration was vague or failed to transcribe on the Mac) — here the event log carries
the review and narration is optional; uploads (50 MB object limit, a queue one bad bundle blocked, re-encoding that
crashed the app) — here AirDrop, no upload, no re-encoding on the phone; a sync marker nobody scanned — here it is
scanned and checked by `simulator-session.mjs`; recorder controls covering the UI under review — here a slim edge
strip whose position is logged; manual frame picking each time — here frames are chosen from the log.

## Known limits

- ReplayKit does not run in the Simulator; the Simulator check uses `simctl io recordVideo` instead.
- System sheets (App Store purchase, Safari, share sheet) are not in device recordings; the timeline still shows
  that they were opened.
- Frame rate is variable (~12–30 fps): fine for finding bugs, not for measuring animation timing.
- The microphone usage string is in `Info.plist` for Internal builds; remove it from App Store builds if the
  recorder stays Internal-only.

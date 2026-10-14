# iPad and macOS: UX and reliability audit — 2026-10-14

Owner request (2026-10-14): "I'm also curious if the iPad and macOS implementations have been given adequate love.
Can you please do a UX and reliability audit and bring them to a tested, predictable and design unified state."
This records what was captured, what was judged against [DESIGN.md](../DESIGN.md) and
[MAC_APP.md](../architecture/MAC_APP.md), what changed, and what still needs the owner's eye on a device.

## Method and evidence

| Surface | Captures | Where |
|---|---|---|
| iPad Pro 11" and 13", light and dark, portrait and landscape | every UI-test scenario (59 each), 472 screens | `.artifacts/visual/ipad-audit/`, sheet `ipad-audit-sheet.png` |
| Mac Catalyst, 1280×820 window, light and dark | 26 launch-argument scenarios each | `.artifacts/visual/mac-audit/`, sheet `mac-audit-sheet.png`; sheets in `mac-sheets/` |

The Mac captures are new: XCUITest on macOS failed to initialise ("The test runner failed to initialize for UI
testing") because it needs an interactive automation permission, so `scripts/visual-check.mjs --devices=mac` now
launches the fixture app directly and the app renders its own window (`VisualCapture.swift`; see
[VISUAL_CHECK.md](../VISUAL_CHECK.md)). The window toolbar (view switch, Settings) is AppKit and outside the capture.
Two capture artefacts, not product defects (the Mac sheet backdrop is painted by the tool, not the app): landscape iPad screenshots are saved in portrait pixel orientation, and
a small grey arc shows at one corner of every iPad capture (the Simulator's rounded-corner mask).

Reliability runs on the audited tree: iPad Simulator native tier (WKWebView compiler, PDF admission, encrypted
reopen) passed, plus LegacyArxivReaderTests, LibraryModelTests, PaperPassageTests and ArxivHTMLReaderTests;
Swift Core ChatStreamTests and ChatProfilesTests 23 pass. A full Catalyst unit run was not done tonight (the
2026-10-08 Mac review's 10 signed Catalyst tests remain the Mac unit evidence); the Mac app was built and launched
for every capture.

## What the screens show (judged against the design principles)

- **One layout model, two chromes.** Phone: floating tab bar. iPad at 850 pt and wider, and the Mac always: the
  wide workspace (Feed · Library · Reader · Browse · General Chat) with the view switch in the iPad header and in
  the Mac window toolbar. Panes, bars, buttons and the 720 pt reading column are the same code on both. The Mac
  table spans the window (right for a table); lists and chat keep the centred column. Verdict: unified.
- **Reader split** (paper + chat with a draggable hairline, Hide chat) looks the same on iPad landscape and the
  Mac; the paper header (contents · title and subtitle · "…"), A−/A+, and the chat header (history · title chip
  with its paper · new chat · "…") match. Dark mode is consistent on both.
- **Library table** on iPad landscape and the Mac: pinned title column, Year/Tags/Added/Opened/Chats/Progress,
  chips for filters, Retry/Get credits as capsules in the status cell. Browse (library beside paper) highlights the
  open paper in accent on both.
- **Chat** general and paper modes, follow-up chips and citation controls (Agent v2) render on iPad and the Mac in
  light and dark; the composer's profile chip and send button match the phone.
- **Settings** on the Mac is the iPad sheet with Done; theme segmented control, text-size sliders, Testing section.
- **Mac sheets** (sign-in, Get credits, All chats, Add paper, tag editor): Catalyst hosts them in their own window,
  so the first captures showed only the window beneath; the capture now draws presented controllers over the
  window with a backdrop (`mac-sheets`, light and dark). Sign-in reads as on iPad (Cancel · title · Apple, Google,
  email); Get credits in the fixture shows "Finish setting up this device", the state before activation.

## Defects found and fixed tonight (both surfaces)

These came from the owner's parallel report, reproduced on the Simulator and offline rather than from the captures:

- Legacy arXiv library items (server-processed bundles) could dead-end on "Paper download needed" with no action
  and no reason; they now open through the on-device HTML reader like every other arXiv paper, the server bundle
  is the fallback, and every refusal has a reason and an action ([OWNER_FEEDBACK.md](../OWNER_FEEDBACK.md)).
- The library said "Not downloaded" for arXiv papers; it now says "Opens from arXiv" until a paper is prepared on
  the device, and "Reader unavailable" only for non-arXiv items without a server bundle.
- Five of the owner's nine new papers refused to compile (conversion markers, inline graphics, TikZ pictures);
  the compiler now tolerates them with a closing note ([HTML_FIRST_READER.md](../architecture/HTML_FIRST_READER.md#compiler-tolerance-and-legacy-items--2026-10-14-owner-report-quite-a-few-couldnt-open-this-paper)).

## Still open (needs the owner on a device, or a later pass)

- Mac keyboard and pointer: ↑/↓ row selection and Return in tables, ⌘Return to send, ⌘W on sheets, hover fills.
  The code paths exist (`PaperTable.keyCommands`, `macSheetKeys`, `macRowHover`); they need runtime verification
  that only a person at the Mac can give (XCUITest is blocked by the automation permission).
- Mac window at its minimum (720×520): captures were taken at 1280×820 only; `--window=720x520` can capture the
  minimum next.
- The chat header density the owner flagged on build 15 was not re-judged on iPad; the current header is title chip
  plus three circles on every surface.
- The Mac unit suite on Catalyst and TestFlight build 32 on a Mac with a signed-in staging account.

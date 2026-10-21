# TestFlight screenshot feedback triage — 2026-10-21

Read-only triage of all 216 TestFlight screenshot submissions (App Store Connect `betaFeedbackScreenshotSubmissions`,
builds 13–76; none exist for build 77). Every item from build 66 onward (79 items) was opened and inspected. So were
the 44 build 57–62 items, whose status was unclear in OWNER_FEEDBACK.md. Status was checked against **current main
(`82c8656`)**, not against the docs. App code on main is identical to the build 77 source (`562ba8b`):
`git diff 562ba8b HEAD -- apps supabase services web` is empty. No code was changed and nothing was released.
Physical-phone access remains paused, so nothing here is owner-device acceptance.

Screenshots (temporary, not committed):
`/private/tmp/claude-501/-Users-benbowlwes-science-reader/5a96b04d-7ac1-43e8-a0d4-69cc27e75f80/scratchpad/tf-feedback/shots/`
(downscaled copies in `../small/`). The signed URLs in `feedback.json` expire around 2026-10-28. Re-fetch with
`node …/scratchpad/tf-feedback.mjs <outdir>`. One image could not be fetched (HTTP 500 from Apple): the fifth ChatGPT
inspiration image in `APvKLlmyyygSM6UlVANkQ-Y`. The other six images in that report were inspected.

Kind: **Bug** = wrong behavior; **Design** = requested change in how something looks or works.
Platforms: native code is one SwiftUI target for iPhone, iPad and Mac (Catalyst). `reader-bridge.js` is shared by
native and browser; the browser lives in `apps/web/src`.

## 0. Implementation status — 2026-10-21 (on the feedback branch; not merged, not released)

The open owner items below were implemented on branch `worktree-agent-a9ba7e1c4135d32c0` (from `641541c`, merged with
`main` at `fa1f69f`). Nothing
was uploaded to TestFlight or deployed; the physical phone was not used. "Done" means implemented with the checks
listed in IMPLEMENTATION_STATUS.md ("Builds 66–76 open feedback"), not owner acceptance. Conflicts C1–C4 were settled
by the owner's own requests (C1: the build-75 request is an explicit Library exception, recorded in DESIGN.md; C2: keep
the meaning, show "New" in words; C3: promotion stays, AHYZ fixed, no morph transition yet; C4: equal capsules).

| Item | Status | Native commit | Browser commit | Notes |
|---|---|---|---|---|
| AHYZ (73) Back to chat after an explainer | Done | 5d3d917 | 640d2c6 | Promoted chat titled by its item; one Back at a time; browser "Back to Table Explainer" too |
| AOog (75) tag filter left on in search | Done | ed96c7d | 17e4623 | Search start/Cancel and every route into ML search clear it |
| AExY (75) catalog rename flash | Done | 6d2b4eb | — | No inline row or disabled list; "Saving…" only after 0.5 s |
| AMZ1 (73) orange "Refresh" banner | Done | 0bf5618 | — (no browser queue) | Quiet ≥ 30 s / 3 tries; automatic 5 s/15 s/1 min/5 min retry; titles and Try now in Pending changes |
| AG-KC (68) endless Equations spinner | Done | 455a452 | — (browser can't hang) | Index-based list within 1.5 s, numbers fill in |
| APZf (76) "Chat about Figure" on tables; one purple action | Done | 4c8564f | 715f3c5 | Equal glass capsules; "Chat about Table" |
| AL-V0 (73) mirrored plot labels | Done (compiler rev 22) | 32126ff | same bundle | Cause: `svgTextLabels` double flip (pictures.ts); paper 2610.22371v1 Fig. 3; saved copies need Update this paper. Double-tap zoom in the plain figure sheet: **not done** |
| ADtu (69) affiliations/e-mails after the abstract | Done (rev 22) | 32126ff | same bundle | Folded into the header, every address kept |
| AIW2 (70) abstract width / h6 | Done | 4eaa957 (bridge) | shared | Runs without keywords; h1–h6 and p; list item indent reset |
| AB5R / G3 (70) generic keywords | Done (stoplist) | 9446667 | 9446667 | Shared GENERIC_KEYWORDS; reader-typed tags kept. Library-rarity ranking: **not done** |
| AIm3 (71) whole-name links | Done | 4eaa957 (bridge) | shared | Sec./Section/§/Appendix A/Lemma/Theorem/Alg./Fig (no dot), name in its own span |
| AJ_g (69) two model controls in the composer | Done (native) | 1a3e8ad | no change | Browser already has one model control; its credits line kept (build-57 rule enforced by chat-controls.spec) |
| ACN1/AHgU (73/75) Search ML papers for keyword/tag | Done | 4eaa957 + 70b422b | f29c394 | Chip dialog (search / library / edit); Tags menu first entry |
| ACLs (75) catalog CSV | Done | 90cd5a3 | 161271d | Shared fixture `tests/fixtures/library-csv/catalog.json`; browser has no DOI data |
| AHI8 (75) catalog left of search, + into the far-right menu | Done | 0681a4c | d148697 | Browser: Add paper… is the first row of the account menu (it has no Library "…") |
| AK1U (75) purple dot | Done | 72ac289 | f61ab4a | "New" in Progress (native) / Opened (browser) |
| TreeCut duplicate rows | Client check done | 4181aa4 | 8a82365 | Server-side duplicate-add idempotency is on `main` separately; merging existing duplicate rows remains open |
| (found in testing) a DOI/reference add reported as failed | Fixed | edbd9c5 | — | Since ca5c3e1, an unsaved catalog note turned a server-successful add into "Couldn't add it right now" |
| §1 hardening: screenshot offer, sheet reports, codes covered | Done (native) | e8ef2c7 | — | Recovery code etc. black in in-app snapshots; TestFlight/ReplayKit captures can't be redacted |
| Stale docs (§4) | Done | docs commit | — | DESIGN.md placeholder, Sheets/X, Last read; SESSION_REVIEW Settings › Admin |

Not in this pass (unchanged status below): G1 crop clipping, AKUp morph transition, the plain figure sheet's zoom
(AL-V0 design half), G4 keyword-heading naming, browser microphone/Copy as Text/"Related papers"/two-step chooser,
Terms of Service row, the second failure screen, recovery-code rotation, and the AA7q persisted status filter.

## 1. "Screen share feedback feature is now missing" (build 77)

**Conclusion:** neither the build 75–77 app code nor any App Store Connect configuration removed or hid a feedback
path. Build 77 is installed from TestFlight but has received no feedback yet. The most likely cause is on the device
or in TestFlight itself, and can't be confirmed while phone access is paused. One real, older change is noted in
item 3 below.

Evidence:

1. **TestFlight side (read-only App Store Connect API).**
   - The only beta group, "Owner", is internal with `feedbackEnabled: true` and `hasAccessToAllBuilds: true`.
     The tester state is `INSTALLED`.
   - iOS and Mac 77 are `VALID`, not expired, with audience `INTERNAL_ONLY`, the same as 74–76.
   - Per-build usage: iOS 77 has 2 installs, 13 sessions and **0 feedback**. iOS 76 has 3 installs, 21 sessions
     and 1 feedback. Mac 77 has 0 installs.
   - So build 77 *is* installed from TestFlight on two iOS devices, and nothing has been submitted from it.
   - The upload scripts (`scripts/upload-testflight*.sh`) and the release script that sets the notes only write
     `betaBuildLocalizations`. No script touches beta groups or feedback settings. The upload logs for 76 and 77 are
     identical apart from process IDs.
2. **App binaries.**
   - The `Info.plist` of the 76 and 77 archives differ only in `CFBundleVersion`.
   - Bundle contents are identical. Development-signed entitlements are identical for 75, 76 and 77.
   - The strings "Report this screen", "Record a test session" and "Operations dashboard" are present in all of
     the 74–77 binaries.
3. **App code, 74 → 77** (`git diff 028a7f6 562ba8b`).
   - `project.yml`, `Info.plist`, `Config/`, `SessionCapture/`, `SettingsPages.swift`, `ReportComposer.swift` and
     `MacCommands.swift` are unchanged.
   - `RootView.swift` only gained the Catalogs sheet, the catalog menu, a "Catalogs" row and a composer-focus change.
   - "Report this screen" is still the last item of the Library, Feed, Paper, Chat and Listen "…" menus. Settings
     still has "Report a problem" and "My reports".
   - In the Internal configuration, which TestFlight uses (`SWIFT_ACTIVE_COMPILATION_CONDITIONS: INTERNAL`),
     Settings › Admin always shows **Record a test session** (`RootView.swift` 1430–1449, `showsAdmin`).
   - The one Admin row that *did* disappear is **Operations dashboard**. It only shows for an account with operator
     roles. The owner's account was deleted and recreated on 10-17 and again on 10-19, and roles were deliberately
     not restored (NATIVE_AUTHENTICATION.md: "no … owner-role assignment"). This happened before 75, so it isn't a
     75–77 change.
   - No code uses `userDidTakeScreenshotNotification`, `screenshotService` or a secure-field capture trick that
     could interfere with the system screenshot flow.
4. **Device and OS context.**
   - All build 70–76 reports came from an iPhone18,1 on iOS 26.7.1.
   - Builds 13, 16 and 65 also had reports from a second device, an iPhone19,3 on **iOS 27.0**.
   - If build 77 is being used on that iOS 27 device, or after an OS update, the screenshot editor's
     "Share Beta Feedback" entry may have moved or disappeared. TestFlight controls that UI; the app doesn't.
   - The Mac has never had TestFlight screenshot feedback; Mac 77 has 0 installs anyway.

Owner checks to resolve this, on the phone, in this order:

1. Open TestFlight › Gradstep and check that build 77 lists **Send Beta Feedback**.
2. In Gradstep, take a screenshot, open the preview, tap Share or Done, and look for **Share Beta Feedback**.
3. If it's still missing, use **…› Report this screen**, or Settings › **Report a problem**. Both are present in 77.

Also, two docs are stale: SESSION_REVIEW.md says "Settings › Testing › Record a test session", but the section has
been called **Admin** since 9a3a6ee (10-15).

Recommended hardening, so in-app feedback doesn't depend on TestFlight:

- Implement the screenshot-shortcut half of TESTING_FEEDBACK.md: on `userDidTakeScreenshotNotification`, show a small
  "Report this screen" toast that captures the app's own snapshot.
- Add "Report this screen" to the sheets that have no "…" menu: figure, table and equation explainers, Contents,
  Catalogs and All chats. These are exactly where the recent feedback was given.
- Files: `ReaderModel.beginReport`, `SheetChrome.swift`, `RootView.swift`.

**Security note (`AErzjCC5McPTtgzaA1McbGU`, build 75, no comment).**
- This screenshot shows the full **recovery code** on "Save your recovery code". It now sits in App Store Connect.
- The local copy was deleted after inspection.
- `.privacySensitive()` doesn't redact screenshots, and the app can't block a TestFlight screenshot.
- The app has no recovery-code rotation. Recommend that the owner deletes that feedback item in App Store Connect.
  Consider adding "Replace recovery code" and keeping the code hidden until a "Show code" tap (`RootView.swift` ~1607).

## 2. Builds 66–76, item by item

Abbreviations: *n* = native (iPhone/iPad/Mac), *b* = browser.

### Build 66 (2026-10-17; account-deletion session failure)

All six session reports had one root cause, recorded in OWNER_FEEDBACK.md: an invalid cached session after remote
account deletion.

| Date (UTC) | Comment | Screenshot | Status | Evidence | Proposed change | Platforms | Kind |
|---|---|---|---|---|---|---|---|
| 10-17 06:05 | "Broken" (figure explainer: "connection was interrupted") | b66_2026-10-17T0605_AJuyKkNNTiFeAV5MuZ2QlqI_0.jpg | Addressed | 1d5f7aa: definitive refresh/RPC rejection retires the session (`ReaderModel.swift` `authenticationRetirement`, ~1784, 2055) | — | n+b | Bug |
| 10-17 06:06 | (none) chat "Sign-in couldn't be completed" | b66_2026-10-17T0606_ACVQHdRz8bI5W8FDZlRTYSg_0.jpg | Addressed | same | — | n+b | Bug |
| 10-17 06:06 | "Fail" (FDE-Gym font options at the start of the title page) | b66_2026-10-17T0606_AAd00453-BHJNB4hJmBIBRo_0.jpg | Addressed | Revision 18 prefix removal; `tests/backend/arxiv-html.test.ts:17-27`. The build 70 screenshot confirms it. | Unreported leftover: FDE-Gym's custom title paragraph still repeats the title and authors under the header (seen in `ABsD30…`). Fold or drop it in the compiler. | n+b | Bug |
| 10-17 06:07 | "Fail" (Feed unavailable) | b66_2026-10-17T0607_AEYSbX5tCmVlpQe5bpyIBZo_0.jpg | Addressed | session retirement (1d5f7aa) | — | n+b | Bug |
| 10-17 06:08 | "If sign in can't be completed why am I seeing my articles" | b66_2026-10-17T0608_ABg02E4ni_mpLk_1RHT_4Us_0.jpg | Addressed | same; returns to normal sign-in | — | n+b | Bug |
| 10-17 06:08 | "Sign in can't be completed??" (Delete account sheet) | b66_2026-10-17T0608_AA65AIWSKfwR6apOpDiZXsc_0.jpg | Addressed | the stale deletion sheet closes on a session change (`RootView.swift` `.onChange(of: readerSessionID)`) | — | n | Bug |
| 10-17 06:10 | "Why can't it be added?" (reference add) | b66_2026-10-17T0610_ACqjeCBOh_0IA889ZdKG9Vk_0.jpg | Addressed | same | — | n+b | Bug |

### Builds 67–68

| Date | Build | Comment | Screenshot | Status | Evidence | Proposed change | Platforms | Kind |
|---|---|---|---|---|---|---|---|---|
| 10-17 08:44 | 67 | "New chat should be left aligned with what's below it" | b67_2026-10-17T0844_AKs7SR4wVXNI88s6V0BwZ7s_0.jpg | Addressed | 10228c5: leading title stack, `RootView.swift` 1171–1208; browser `.chat-heading` | — | n+b | Design |
| 10-17 08:45 | 67 | "Draft saved message not needed" | b67_2026-10-17T0845_AHZ7kJjPRjyb0R38c9Ph43k_0.jpg | Addressed | 10228c5: only draft *failures* show (`RootView.swift` 1001–1006) | Delete the dead `chatDraftStatusText` (`ReaderModel.swift` 632–640) | n+b | Design |
| 10-17 08:48 | 67 | "ChatGPT inspiration: microphone and an easy chat-settings toggle" | b67_…APvKLlmyyygSM6UlVANkQ-Y_{0,1,2,3,5,6}.jpg | Addressed (n), partly (b) | Native composer has model, options, mic and Send (`RootView.swift` 1044–1059; `ChatDictation.swift`) | Browser has no microphone; add one with Web Speech where available, or record the omission | b | Design |
| 10-17 08:49 | 67 | "Still broken" (OpenVLA reference add) | b67_2026-10-17T0849_ALgpsts9zZmv6PsboQse3BY_0.jpg | Addressed / superseded | Provider billing; all inference now goes through OpenRouter (de722cf) | — | server | Bug |
| 10-17 16:16 | 68 | "arXiv should be in the middle of the row vertically" | b68_2026-10-17T1616_AEHfQ2RMLuN3d5lH8wDtk0g_0.jpg | Addressed | Title overlay over two reserved lines (`PaperTable.swift` 567–605; 10228c5, 1262117) | Probable regression: the overlay ignores `title.highlighted`, so the selected iPad Browse row loses its accent title. Add `.foregroundStyle(title.highlighted ? .accentColor : .primary)` and check on iPad | n (iPad) | Bug |
| 10-17 16:17 | 68 | "Hanging" (Contents › Equations shows only a spinner) | b68_2026-10-17T1617_AG-KC-bgu7HdtwNQhuQ1LBk_0.jpg | Partly | f72c51c made the scan one pass and cancellable (`EquationView.swift` core 72–81). The tab still shows a bare `ProgressView()` with no timeout or fallback (`PaperContentsSheet.swift` 147–149) | List index-based labels immediately and fill printed numbers in later, or time out after ~3 s with labels or "Couldn't list equations / Retry". The browser can't hang this way | n | Bug |

### Build 69 (2026-10-18 00:53–05:09)

| Date | Comment | Screenshot | Status | Evidence | Proposed change | Platforms | Kind |
|---|---|---|---|---|---|---|---|
| 00:53 | "I want to zoom here" (explainer crop) | b69_2026-10-18T0053_ALwRw3t1IcviLG-AEohCJXY_0.jpg | Addressed | Pinch and double-tap toggle on every explainer image, plus fullscreen (`FigureExplainView.swift` 406–455, 472–517) | — | n+b | Design |
| 00:56 | "Equation rendering fail" (raw `\longmapsto`, cases, `\ket` in chat) | b69_2026-10-18T0056_AELl5FEzHTGgvHM9ZVZOZzo_0.jpg | Addressed | `ChatMathTypesetting.swift` 18, 36 (10228c5); test `UnsentDraftTests.swift` 58–67; browser Temml supports them | — | n+b | Bug |
| 04:39 | "Redesign: explainer must morph into chat; no navigating out" | b69_2026-10-18T0439_AGzcvn1gg3maCYx7j1nUA9o_0.jpg | Addressed (single view) | Explanation, thread and composer are in one view (`FigureExplainView.swift` 111–183, `EquationView.swift` 270–295) | See conflict C3 (AKUp) | n+b | Design |
| 04:41 | Remove "Scroll sideways"; show − + % | b69_2026-10-18T0441_ABYO8P1SY4632Iona4eyyuk_0.jpg | Addressed | `EquationView.swift` 337–350; browser `EquationView.tsx` 145–147 | Remove the stale "Scroll sideways" comment (`EquationView.swift` 476) | n+b | Design |
| 04:42 | "Cloud AI is not needed, Gemini says enough" | b69_2026-10-18T0442_AOGV8iwN8oALZBCIwiyBJOA_0.jpg | Addressed | Real model names from the server (`chat-profiles.ts` 44–48) | — | n+b | Design |
| 04:45 | Author tap → search their other papers | b69_2026-10-18T0445_ACo538NX-0smYuNu1fjpQoQ_0.jpg | Addressed | `reader-bridge.js` 1171–1189; `PaperView.swift` 480–485; `Reader.tsx` 544 | Names are only tappable when they exactly match the catalog spelling | n+b | Design |
| 04:45 | "Broken sources list" (affiliations in one tab-spaced row, e-mails after the abstract, 2610.22353) | b69_2026-10-18T0445_ADtu4d3nuppfXDfMCpltx2o_0.jpg | Partly | `frontAffiliations` (10228c5, `front-matter.ts` 150–166) only breaks lines. The block stays after the abstract, the e-mail paragraph is kept (and a test asserts it, `arxiv-html.test.ts` 623–631), and the header fold never runs because the catalog author list is empty | Move affiliations into `p.reader-authors`, drop or fold the adjacent e-mail-only paragraph, bump `ARXIV_RENDERER_REVISION` (21) and rebuild both `arxiv-reader.js` copies. Saved copies need "Update this paper" | n+b | Bug |
| 04:47 | "Why is there nothing under Added" | b69_2026-10-18T0447_AFApSc2oh3EHD6gjW7Dvlgo_0.jpg | Addressed | imports carry `added_at` (migration 0088); `LibraryTableView.swift` 265 | — | n+b | Bug |
| 04:47 | "0 instead of nothing for 0 chats" | b69_2026-10-18T0447_ABpFobeCnmum1y5oQ6eXJaY_0.jpg | Addressed (n) | `LibraryTableView.swift` 268 | The browser has no Chats column (a parity gap, not a defect) | n | Design |
| 04:48 | Keywords before the intro, editable | b69_2026-10-18T0448_AH4X0rcoCTrD7GMa8ZVhJoI_0.jpg | Addressed | `reader-bridge.js` 1142–1169 | See group G4 | n+b | Design |
| 04:50 | No "Cloud AI"; real model name; "(local)" suffix | b69_2026-10-18T0450_AF8s3goTA3zCRKQgfDCo5Tk_0.jpg | Addressed | `ReaderModel.swift` 661; the "Cloud AI" fallback is unreachable (`LocalAIController.swift` 89, 213) | — | n+b | Design |
| 04:51 | "Search Library" → "Search" | b69_2026-10-18T0451_AJmP3AGjSBDc_lSKXki3Sbg_0.jpg | Addressed | `RootView.swift` 407 | — | n+b | Design |
| 04:57 | Equation menu: Chat about Equation first; drop Why it matters and the duplicate copy; Copy as Text = full LaTeX | b69_2026-10-18T0457_AEhYxws8LHOkth-WZbiHQKg_0.jpg | Addressed (n), partly (b) | Native: Chat about Equation, AI Explainer, Related papers, Copy as Text (`MacSupport.swift` 323–341) | Browser bar (`Reader.tsx` 503–515) has no Copy as Text and says "Related"; rename it "Related papers" and add Copy | b | Design |
| 04:59 | Two model rows: Anthropic (3) and Other providers (2) | b69_2026-10-18T0459_ANzwcWN12jtwwn5VOe4xxr4_0.jpg | Addressed | `ChatProfileControls.swift` 42–43; `ChatProfile.tsx` 26–27 | — | n+b | Design |
| 05:00 | "Sync Now not clickable when Synced" | b69_2026-10-18T0500_AFMWFCg4drJsFsphnc5r7q8_0.jpg | Addressed | `SettingsPages.swift` 130 | — | n | Design |
| 05:01 | "The face icon can go" | b69_2026-10-18T0501_AEMnPGx7JyLldpyKPDyoOXI_0.jpg | Addressed | `SettingsPages.swift` 79–96 | Fix the stale comment at line 84 | n | Design |
| 05:02 | "Nothing about local models?" | b69_2026-10-18T0502_AMZILJ5QrDuQxRe1s68Qh-g_0.jpg | Superseded | iPhone/iPad local answering was removed by owner direction (de722cf). The Mac-only UI is in `AIChoiceView.swift` 67–204, and its catalog is empty (2dcfd16) | — | Mac only | Design |
| 05:07 | Local model UI is bad; default/cloud/local; download in Settings; per-iPhone table | b69_2026-10-18T0507_AF3va71uyfJl9SS2unSsRVQ_0.jpg | Superseded (iPhone/iPad) | same; local defaults are nil off the Mac (`ReaderModel.swift` 702–703) | — | Mac only | Design |
| 05:09 | "Cloud AI · credits is redundant, consolidate" | b69_2026-10-18T0509_AJ_ghNZCc2TPoLQcQI64ss4_0.jpg | Partly | The label is gone, but the main composer now has **two** controls for the same thing: the model button (Default / Choose model) and the slider button (Answer options, which repeats model and length; `RootView.swift` 1044–1050) | Remove the slider and move "Use for new chats" and "About" into Choose model, as the explainer composer already does (`EquationView.swift` 713–717). Browser: move the "N credits" line (`ChatPane.tsx` 319–323) into Answer options | n+b | Design |

### Build 70 (2026-10-18 13:29–15:24)

| Date | Comment | Screenshot | Status | Evidence | Proposed change | Platforms | Kind |
|---|---|---|---|---|---|---|---|
| 13:29 | "Looking at table" (a table explainer said "Looking at the figure…") | b70_2026-10-18T1329_AOxhjTUj5Opevk-Il8QEe7Q_0.jpg | Addressed | `FigureExplainView.swift` 258; `FigureView.tsx` 126 (c4d15d9) | `lib/chat.ts` 141 still falls back to "Looking at the figure…" for table questions without a query | n+b | Bug |
| 13:29 | "Zoom works, but full screen it beforehand" (table) | b70_2026-10-18T1329_AHQ6KQmwNL2yCmG3G5J0sRw_0.jpg | Addressed in explainer | Fullscreen button (`FigureExplainView.swift` 192–200) | The plain figure sheet still has no fullscreen or zoom (see AL-V0) | n+b | Design |
| 13:31 | Sections should state the authors' argument ("because X>Y, the authors believe Z") | b70_2026-10-18T1331_AJujgmmq5eRFrgxrjf4vUzg_0.jpg | Addressed (figures) | prompt `chat-figure-view.ts` 68–71 (c4d15d9) | Add the same instruction to the equation explainer prompt | server | Design |
| 13:36 | No "Back to Table Explainer"; landed at top | b70_2026-10-18T1336_ABsD30JFf1gsmDpSTepGRm8_0.jpg | Addressed (n), partly (b) | `FigureExplainView.swift` 389–396; `PaperView.swift` 669–680 | The browser always says "Figure" for tables: add `'table'` to `explainerReturn.kind` (`Reader.tsx` 125, 454, 556) | b | Bug |
| 13:41 | "The crop dimensions are not good" (panel B clipped) | b70_2026-10-18T1341_APkeR39IIELErvOzT54Freg_0.jpg | Not addressed | See group G1 | See G1 | n+b+server | Bug |
| 13:42 | Reference jumps animate heavily; go directly | b70_2026-10-18T1342_AOkAOUHyt7v6c8t9W3bRWwk_0.jpg | Addressed | `behavior:'instant'` in `reader-bridge.js` 1278, 1370, 1409 (1262117) | Fix the stale "smooth" comment at 1323 | n+b | Design |
| 13:48 | Chat icon left of X that transitions gracefully into Chat with the figure loaded | b70_2026-10-18T1348_AKUpnsmo22QanrGf9iVxe6o_0.jpg | Partly | The icon exists (`SheetChrome.swift` 56–63), but it closes the sheet and switches tab (`PaperView.swift` 632). There's no morph | Decide C3 first. Then either a shared-element transition, or present Chat inside the sheet's stack | n+b | Design |
| 13:51 | Text not as wide as it could be (abstract indented) | b70_2026-10-18T1351_AIW2SzNnfmiwSiRJIhzKH1c_0.jpg | Partly, likely ineffective | `data-sr-abstract-list` (c4d15d9, `reader-bridge.js` 1113, 1155) searches `h2,h3,p`, but the compiler emits the abstract heading as **h6** (`arxiv/flow.ts` 34, 40). It also only runs inside `installPaperTags` and has no test | Search `h1–h6`; also cover `blockquote`/`.reader-abstract`; better, unwrap the list in the compiler. Add a `PaperWebViewTests` case | n+b | Bug |
| 13:54 | Keywords as a header; name the source (Gradstep or arXiv Keywords); "(edit)" | b70_2026-10-18T1354_AFNROYs1C2shOq6_tVetGQk_0.jpg | Mostly addressed | `<h2>Gradstep Keywords` (de722cf) | Heading is hard-coded even for user-edited keywords ("Your keywords" appears underneath), and an "arXiv Keywords" source never exists. The sheet says "Edit tags". See G4 | n+b | Design |
| 15:05 | Find: an icon listing all occurrences | b70_2026-10-18T1505_ADpoeQ6c6bAiCu8el1W1Ye8_0.jpg | Addressed | `PaperFind.swift` 70–91; `Reader.tsx` 465, 471 (c4d15d9) | — | n+b | Design |
| 15:05 | "Ended up here after leaving Find" (tab bar at the top, page half black) | b70_2026-10-18T1505_ALOAfmV3YuPNtl-N7CpOIhk_0.jpg | Addressed | WebKit find bar removed; SwiftUI `PaperFindBar`; keyboard reset on tab change (`PaperView.swift` 297, 997, 1045; `RootView.swift` 57–60; c4d15d9) | The test (`PaperToolsTests.swift` 116–132) closes Find before switching tabs. Add a case that switches with the find field focused and asserts the web view's height. `Chrome.swift` `ignoresKeyboardFrame` is now dead | n | Bug |
| 15:06 | "Also this after leaving Find" (Feed, same broken layout) | b70_2026-10-18T1506_AGKm2VZUi8E9wuaEpQ-zo1M_0.jpg | Addressed | same (duplicate of the above; earlier occurrence build 21 `ACxg…`) | same | n | Bug |
| 15:07 | "Find similar papers" in the row menu | b70_2026-10-18T1507_AHqnfqgG6QhAxsiiXCycKw8_0.jpg | Addressed | `LibraryTableView.swift` 442; `LibraryActions.tsx` 133 | — | n+b | Design |
| 15:09 | Hard no on AI/ML keywords; distinctive keywords; fast on-device index deleted with the paper | b70_2026-10-18T1509_AB5RbQvOOBVm5rcCw7dVdFI_0.jpg | Partly | Exact-match blocklist of only AI/ML/statistical ML (`PaperKeywords.swift` 5–7; `lib/paper.ts` 10). "LLM", "Large language models", "Reasoning" and "Evaluation" still pass (seen on build 75). `DevicePaperTextIndex` exists (in memory, native only, capped at 200, deleted with the paper) but is only used for library search | See G3 | n+b | Design |
| 15:12 | Share: arXiv/publisher URL and a Gradstep deep link | b70_2026-10-18T1512_ABQMRH-P_HMeXzuVVvFJhvs_0.jpg | Addressed (papers) | `PaperShareMenu.swift`, `PublicPaperLink.swift`, `onOpenURL`, applinks; browser `/p/` route (c4d15d9) | Path parsers reject `/p/arxiv/<id>/figure/...` (they need to accept extra segments before explainer links can work), and a link to a different arXiv version falls through to search | n+b | Design |
| 15:13 | "'Find papers' text redundant" | b70_2026-10-18T1513_AHnfxB7MNfJSOayC2DDJQKE_0.jpg | Partly | "Find papers" is gone, but the idle state still repeats itself: "Search by title, author or topic" over "Search ML papers by title, author, topic or arXiv ID…" (`RootView.swift` 1668–1669) | Keep only the description (as the browser does); delete the dead `"Find papers"` branch (`RootView.swift` 304) | n | Design |
| 15:15 | Basic search, expandable to a field-based advanced search | b70_2026-10-18T1515_ACMcVM602Rz-vXruEFQ43Fo_0.jpg | Addressed | `AdvancedPaperSearch.swift`; `PaperSearch.tsx` 91–98 | — | n+b | Design |
| 15:17 | Checkmark and percent too small, not centred | b70_2026-10-18T1517_ABsQQla8nqWJpFfXRh1hecE_0.jpg | Addressed (n) | `.title3` in a 44-pt frame (`FeedTableView.swift` 310–328) | The browser's preparing percent is still 10.5 px (`style.css` 314) | b | Design |
| 15:23 | HTML and Mermaid options in the suggested questions | b70_2026-10-18T1523_AKzAZhje38OzGFDx5K8czRo_0.jpg | Addressed | `ChatTranscript.swift` 254–262; `ChatPane.tsx` 280–282 | They only appear when the server returned suggestions | n+b | Design |
| 15:24 | Why DeepSeek? Scenario defaults in Settings | b70_2026-10-18T1524_ABOb4eqeePw0LqdsgW6pBZM_0.jpg | Addressed | "AI defaults by activity" (`RootView.swift` 1355–1362; `AIScenarioDefaults.swift`; `App.tsx` 755) | — | n+b | Design |

### Builds 71–72 (2026-10-18)

| Date | Build | Comment | Screenshot | Status | Evidence | Proposed change | Platforms | Kind |
|---|---|---|---|---|---|---|---|---|
| 18:08 | 71 | "I open to this screen" (no papers tagged "Machine learning") | b71_2026-10-18T1808_AA7qkZeMDULoabnV9nJltRg_0.jpg | Addressed | Tag filter no longer persisted (`ReaderModel.swift` 304–310; de722cf) | The *status* filter (Unread/Archived) is still persisted (`:301`), so an empty Archived view can return after relaunch. Consider starting at All | n+b | Bug |
| 18:49 | 71 | Remove "on this device" | b71_2026-10-18T1849_AGaNyh3RbfCpwDS8YAPMU98_0.jpg | Addressed | de722cf | — | n+b | Design |
| 18:50 | 71 | Whole "Figure 1" should be the link | b71_2026-10-18T1850_AIm3cFZUGNMzCcnow--e9uU_0.jpg | Partly | `expandNamedReferences` (`reader-bridge.js` 600–614; de722cf) covers Figure/Fig., Table/Tab., Equation/Eq., Algorithm and "Tab.4". **Not** Sec./Section, §, Appendix A, "Fig 3" (no dot), Alg., Lemma, Theorem, or a word in its own span (the build-71 "Sec.2.2" screenshot) | Extend the prefix list, accept letter-led targets ("A", "A.1"), add tests | n+b | Bug |
| 18:53 | 71 | Two choices: Default (model) or Choose model | b71_2026-10-18T1853_AKySCAEqMG8jFIUsZuMgJUk_0.jpg | Addressed (n), not (b) | `AIChoiceView.swift` 27–41 | The browser button opens the full dialog; add the same two-step chooser | b | Design |
| 18:53 | 71 | Space between DeepSeek and the box above too large | b71_2026-10-18T1853_AJ_z1-3h-S_4KMX3DQeREZ8_0.jpg | Addressed (equations) | 8 pt (`EquationView.swift` 288–291) | The figure explainer still uses 18 pt (`FigureExplainView.swift` 177, 180) | n | Design |
| 18:54 | 71 | Switched Equation 1 → 4, formula didn't switch | b71_2026-10-18T1854_AAIRTUkUM8VCNEXeNJ08xWY_0.jpg | Addressed | reload on markup change (`EquationView.swift` 571–583) | — | n+b | Bug |
| 19:37 | 71 | Existing AI explainer should just open | b71_2026-10-18T1937_AALT8OoJugZVuzIPaA4fCiQ_0.jpg | Addressed | saved-answer lookup before the chooser (`FigureExplainView.swift` 63–66; `ReaderModel.swift` 3942–3951) | — | n+b | Bug |
| 20:07 | 71 | Cards must cover all pixels; typed, consistently titled cards | b71_2026-10-18T2007_ALCJLruWVHFOYNzJoULIvSY_0.jpg | Partly | Card kinds and titles done (`FigureView.swift` 47–53). Coverage is only *reported* (`FigureExplainView.swift` 246–249); nothing expands or retries a box | See G1 | n+b+server | Design |
| 20:45 | 71 | Open all options when tapping a reference | b71_2026-10-18T2045_AIxTRD9PfGy-NN-c6jJjzvY_0.jpg | Addressed | vertical action sheet (`MacSupport.swift` 230–252); Mac menu; browser dialog (`Reader.tsx` 637–672) | — | n+b | Design |
| 20:47 | 71 | Contents full screen; double-tap opens it | b71_2026-10-18T2047_AG6Tt6EQHLYdjkDVr7wbfEE_0.jpg | Addressed | `.large` plus iPad `.page` sizing (562ba8b); bridge 1901–1927 | — | n+b | Design |
| 20:49 | 71 | Hint above the tabs until double-tap is tried | b71_2026-10-18T2049_ABXmwha89ij3YBl_O7vJmmk_0.jpg | Addressed | `reader.contents.doubleTapDiscovered` (`PaperContentsSheet.swift` 29, 42–47; `Reader.tsx` 121) | — | n+b | Design |
| 20:50 | 71 | Still heavy animation between sections | b71_2026-10-18T2050_AGKMdEtP7pqVb2aAzZqY6rg_0.jpg | Addressed | `__scienceReaderJumpToHeading` instant (1262117) | — | n+b | Design |
| 20:55 | 72 | Device and authors as separate columns | b72_2026-10-18T2055_ABakbeFhKrV6jstQ5kcx1Vo_0.jpg | Addressed | `LibraryTableView.swift` 33, 246–258; `library-columns.ts` (1262117) | — | n+b | Design |
| 20:56 | 72 | "Just remove Edit here" | b72_2026-10-18T2056_AJLDiNJ6Dzq4eb06F-CvAhc_0.jpg | Addressed | 1262117; tapping the block opens the editor | See G4 / G2: this conflicts with using a chip tap for search | n+b | Design |

### Builds 73–76 (all open in OWNER_FEEDBACK.md except AMZ1)

| Date | Build | Comment | Screenshot | Status | Evidence | Proposed change | Platforms | Kind |
|---|---|---|---|---|---|---|---|---|
| 10-18 22:37 | 73 | "Awful. Unclear product experience" (orange "Your change is saved on this device. Refresh to try sending it again. Review") | b73_2026-10-18T2237_AMZ1EYpp-g46Tu85tdnKziA_0.jpg | Partly | 028a7f6 fixed the cause (rejected `v5_set_source_details`) and the wording per cause (`LibraryCommandCoordinator.swift` 359–370); a retry runs every ~60 s. Still: the banner appears immediately for any queued change, turns orange on the first failure, "Refresh" survives (`RootView.swift` 320, 364), and Review shows internal wording plus a raw "arXiv 2412…" label | Silent until a change has waited about 30 s or failed 3 times. Automatic backoff in `drain()` (5 s / 15 s / 60 s / 5 min, and on reconnect). Copy: "1 change hasn't synced yet. Gradstep will keep trying. [Details]", orange only when the reader must act. Changes page: paper titles, "Will retry automatically", "Try now" (`LibraryChangesView.swift`). Matches DESIGN.md Status | n (the browser has no change queue) | Bug+Design |
| 10-18 22:38 | 73 | "Need an option right at the top to search ML papers based on this keyword" (Edit tags sheet) | b73_2026-10-18T2238_ACN1pum4v1-mJuwgU22J7Ys_0.jpg | Not addressed | The keywords block is one button posting `{type:'tags'}` with no name (`reader-bridge.js` 1142–1167, 1536–1541) | See G2 | n+b | Design |
| 10-18 22:41 | 73 | "Looks like the whole sub figure not included?" ("Detail of Figure 2: 2", Interaction Harness clipped on three sides) | b73_2026-10-18T2241_ACxnS6bB8Ga4qBTzECN3xrk_0.jpg | Not addressed | See G1 | See G1 | n+b+server | Bug |
| 10-18 22:53 | 73 | "Clicked back to chat and somehow got here" (Chat tab titled "New chat" showing a promoted Figure 2 explainer) | b73_2026-10-18T2253_AHYZJO6d0-mkFRFYd-j1H_4_0.jpg | Not addressed | "Open in Chat" promotes the explainer into the Chat tab (`promoteContextualChat`, `ReaderModel.swift` 5368–5379). The title ignores it, so it reads "New chat" (`:643–646`). A ¶ citation from it only sets `returnToChatAvailable` (`PaperPassages.swift` 159), and `returnToChat()` just switches tab (`ReaderModel.swift` 3027). Both Back buttons can show at once (`PaperView.swift` 671–683) | Store an `ExplanationSubject` in `PromotedChatContext` (browser `promotedContexts`). In the promoted transcript's `onCite`, set `explainerReturn`, so Back reads "Back to Figure 2 Explainer" and reuses `contextualComposers[key]`. Hide `chatBack` while `explainerBack` shows. Title promoted chats from `promotedChatContext.label`. Browser: `chat-session.ts` 262–272 | n+b | Bug |
| 10-19 01:27 | 73 | "If I double tap here it should zoom" (figure sheet) | b73_2026-10-19T0127_AL-V0yuPVLvTrmalbO5c9yQ_0.jpg | Not addressed | The figure sheet is a web page with `width=device-width`, and the bridge's double-tap is off on figure pages (`reader-bridge.js` 1903; `PaperView.swift` 1343–1358). **Unreported bug in the same screenshot:** the pgfplots tick and axis labels are drawn vertically mirrored. Likely cause: `svgTextLabels` keeps the label's own flip transform and adds `matrix(1 0 0 -1 0 h)` to the new `<text>` (`supabase/functions/_shared/reader/arxiv/pictures.ts` ~58–61, 32f23a5). Plausible, not reproduced; the test sample has no outer flip | For image figures, use `ZoomableFigureImage` plus a fullscreen button in the sheet; otherwise add a figure-mode double-tap that zooms the scroll view. Reproduce the label flip on the source paper, fix `svgTextLabels`, add an outer-flip test and bump the renderer revision (SVG is rasterized at preparation, so saved copies need Update) | n+b | Design + Bug |
| 10-19 16:31 | 75 | (none) — "Save your recovery code" screen | (local copy deleted: shows the recovery code) | Informational | — | See the security note in §1 | — | — |
| 10-19 17:16 | 75 | Rename caused an awkward flash ("maybe another button appeared") | b75_2026-10-19T1716_AExYL9iTA1wuPNXFbz2Qhfk_0.jpg | Not addressed | Save sets `catalogBusy = true`. That inserts a "Saving…" row (`LibraryCatalogsView.swift` 61) and disables every row and the X (51–67), then reverts a moment later because the write is a fast local one (ca5c3e1) | Drop the inline row (or delay it ~0.5 s in an overlay that doesn't move the layout); don't disable the list for local writes; open the alert after the menu closes | n | Bug (polish) |
| 10-19 17:17 | 75 | "Option to save the entire catalog as CSV" | b75_2026-10-19T1717_ACLs0GZ0-xM7sxNzAZDclVY_0.jpg | Not addressed | No CSV or exporter in `apps/apple` or `apps/web/src` | Pure `LibraryCSV` builder in ScienceReaderCore. Columns: Title, Authors (`;`), Year, arXiv ID with version, URL, Venue, Tags, Added (ISO), Last opened, Progress, Chats, Archived, Catalog. Quote cells, and prefix `= + - @` against formula injection. Catalog row ⋯ › "Export as CSV…" via `.fileExporter` (save panel on Mac); browser download in `Catalogs.tsx`. Stays on the device (E2EE-friendly) | n+b | Design |
| 10-19 17:19 | 75 | Catalog left of the search bar; + becomes a row inside the "…" menu | b75_2026-10-19T1719_AHI8ygwIHDKnWw4cNgtIzhU_0.jpg | Not addressed | Header is search, +, … (`RootView.swift` 406–418, 457–499); the catalog row sits below (427–445) | Catalog menu before the search field (≤ ~140 pt, hidden while searching, same visibility rule); remove the + button; "Add paper" becomes the first section of ⋯. **Conflicts with DESIGN.md** "Top bar … right = create (+), then …" (C1); needs an owner-approved exception. Browser: move the catalog `<select>` (`Library.tsx` 327) | n+b | Design |
| 10-19 17:20 | 75 | "The purple dot beside the checkmark is confusing" | b75_2026-10-19T1720_AK1UB0HuHvzOK_i6GEqrno8_0.jpg | Not addressed | It means added within 3 days and never opened *on this device* (`ReaderModel.swift` 3020–3025). It's drawn in the Device column (`LibraryTableView.swift` 256), the list (`RootView.swift` 701) and the browser (`Library.tsx` 66) | Remove the dot from Device. Show "New" in secondary footnote text in Opened where "—" is today, and in the list's metadata line; update the VoiceOver text and browser `col-opened`. Conflict C2 | n+b | Design |
| 10-19 17:22 | 75 | "Search ML papers for tag" at the top of the Tags menu; external or internal | b75_2026-10-19T1722_AHgUYbURvvfwbl82MH3RIxA_0.jpg | Not addressed | Tags menu is "All tags" plus filters (`LibraryTableView.swift` 590–609) | See G2 | n+b | Design |
| 10-19 17:23 | 75 | "Got here; was a search not escaped?" (search active, tag filter High-Concurrency) | b75_2026-10-19T1723_AOogtkixgH4jspuy-KkHsEk_0.jpg | Not addressed | No single path sets both, but Cancel (`RootView.swift` 412–414) and the routes into search (find similar `ReaderModel.swift` 2299, author `PaperView.swift` 483, link `PaperShareMenu.swift` 38) never clear `libraryTagFilter`, and the filter is invisible inside the search UI. Browser Cancel keeps it too (`App.tsx` 465) | Cancel and every route into search set `libraryTagFilter = nil`; choosing a tag ends search focus; or show the tag as a removable token in the field | n+b | Bug |
| (same screenshots) | 75 | Unreported: two "TreeCut: A Synthetic Unanswerable Math…" rows | b75_2026-10-19T1719_AHI8ygwIHDKnWw4cNgtIzhU_0.jpg | Not addressed | `importPaper` computes `alreadyPresent` but uses it only for catalog assignment, and still enqueues the import (`ReaderModel.swift` 2440–2451). Browser `addArxiv` doesn't check (`useLibrary.ts` 161–169). The server `v2_begin_import` has no account+source uniqueness. Rows are keyed per import (`ReaderModel.swift` 2783–2797) | Redirect to the existing paper ("Already in your library"); have the server return the existing visible import for the same version-less source; merge existing duplicates in both row builders, keeping the newest version and combining reading activity | n+b+server | Bug |
| 10-20 09:25 | 76 | "Confusing that only one is purple?" (Chat about Figure is glass, AI Explainer is filled) | b76_2026-10-20T0925_APZf4fWGLnNqqBTZYKLgVwE_0.jpg | Not addressed | `BarCapsule(... prominent: true)` only for AI Explainer (`SheetChrome.swift` 82–88, c72b3f6); browser `.prominent` (`style.css` 867–872). DESIGN.md "Explain actions" treats them as peers (C4) | Give both the same glass style (`prominent: false`; drop the browser class). Also: the label is hard-coded "Chat about Figure" on **table** sheets (`SheetChrome.swift` 82; `Reader.tsx` 699); pass the noun | n+b | Design (+ label bug) |

## 3. Duplicate groups

- **G1 — Figure crops clipped / incomplete:** APke (70), ALCJ (71), ACxn (73), and the build 62 "Extract the
  subfigure" follow-up.
  - Boxes come only from the model (no detector ships; FIGURE_VIEW.md 55).
  - The client adds a fixed 2 % margin (`ScienceReaderCore/FigureView.swift` 27–33). Chat-answer crops have no
    margin and no zoom (`FigurePartsView.swift` 27–33).
  - Fix:
    - Expand each box outward until it meets a run of background rows or columns (≤ ~15 % per side), in both
      `FigureView.swift` and the browser `figure-view.ts` (~109).
    - Server: check the union coverage and re-ask once below ~97 %.
    - Add a regression test with MLExpert Figure 2 "Interaction Harness".
  - The research worktree `science-reader-subfigure-detector-20261021` (at 82c8656) is the detector track. Keep this
    deterministic fix separate from it.
- **G2 — "Search ML papers for this keyword/tag":** ACN1 (73), AHgU (75); related to AOog (75).
  - Bridge: each chip posts `{type:'tag', name}`. The block's own edit path keeps `tags`.
  - Native (`PaperView.swift`): accept only the paper's own tags. Show a dialog like the author one:
    "Search ML papers for "X"" first, then "Show library papers tagged "X"", then "Edit keywords…".
  - Add `ReaderModel.searchPapers(forTag:inLibrary:)`. It clears the tag filter, sets `discoveryQuery`,
    `searchExternal` and the tab, and runs discovery.
  - Library Tags menu: a first section "Search ML papers for "X"", or a submenu when no tag is selected.
  - Browser: `frame.ts` message, `Reader.tsx` menu, and a `Library.tsx` button reusing `similar()` (`App.tsx` 268).
- **G3 — Generic keywords/tags:** AB5R (70); earlier build 15 `ABOS7OQ9…` and build 21 `AM6B5rjN…`.
  - Add a generic stoplist (LLM(s), Large language models, Reasoning, Evaluation, Benchmark, Deep learning,
    Transformers…).
  - Rank by rarity across the library: per-term document counts in `DevicePaperTextIndex`, with body text passed to
    `derive(text:)` (`PaperKeywords.swift`, browser `lib/paper.ts`).
  - The tag vocabulary (`supabase/functions/_shared/tag-vocabulary.ts` 53, 100, 111) contains the generic terms
    themselves.
- **G4 — Keyword block:** AH4X (69), AFNR (70), AGaN (71), AJLD (72). Essentially addressed.
  - Remaining: name the heading from the source ("Your keywords" vs "Gradstep Keywords").
  - Call the sheet "Edit keywords". The reader says Keywords, the sheet and Library say Tags.
- **G5 — Explainer ↔ chat:** AGzc (69), AKUp (70), ABsD (70), AHYZ (73), APZf (76). See conflict C3.
- **G6 — Model naming and choice:** AOGV, AF8s, AJ_g, ANzw, AF3v, AMZI (69), AKyS (71), ABOb (70). Earlier: build 15
  `AHWFG3n0…` and build 57 `AEyurbt5X…`. All addressed or superseded, except the AJ_g duplicate controls and browser
  AKyS.
- **G7 — Layout broken after Find:** ALOA, AGKm (70). This is the second occurrence; the first was build 21
  `ACxg6N_I…`. Fixed structurally; add the stronger regression test.
- **G8 — Animated jumps:** AOkA (70), AGKM (71). Addressed.
- **G9 — Contents sheet:** AG6T, ABXm (71) are addressed. AG-KC (68) still has no timeout.
- **G10 — Library table cells:** AEHf (68), AFAp and ABpF (69), ABak (72), AK1U (75).
- **G11 — Session after account deletion:** the six build-66 reports. Addressed.
- **G12 — Figure sheet zoom / fullscreen:** AHQ6 (70, explainer done), AL-V0 (73, sheet not done).

## 4. Conflicts

- **C1 — AHI8 vs DESIGN.md "Top bar".** Moving + into "…" contradicts "right = create (+, compose), then …" and the
  "…" ordering rule. Placing the catalog on the left fits "left = where to go". Ask the owner whether the Library is
  an exception or DESIGN.md changes app-wide. Proposal: catalog left of search; + kept on the right.
- **C2 — AK1U vs the owner's earlier request.** Build 42 chat #10 asked for an indicator of recently added unread
  papers, which is why the dot exists. It also breaks DESIGN.md "Accent color only for tappable things".
  Recommendation: keep the meaning, change the form to secondary "New" text. Also note "unread" is per device: a
  paper read elsewhere still shows as new.
- **C3 — AGzc ("no option to navigate out … the interface should morph") vs AKUp ("chat icon … transitions into the
  chat UX").** The code does both:
  - an in-sheet conversation;
  - an icon that promotes the explainer into the Chat tab.
  The promotion path is what produced AHYZ. Decide whether promotion stays. If it does, fix AHYZ and add the
  transition. If not, remove the icon and keep everything in the sheet.
- **C4 — APZf vs code.** DESIGN.md "Explain actions" describes Explain in Chat and AI Explainer as peers. The code
  makes AI Explainer prominent. Align the code to the doc unless the owner wants the cost-bearing action emphasised.
- **C5 — AJLD ("remove Edit") vs ACN1/AHgU (tap a keyword to search).** Today any tap opens the editor. G2's chip
  menu satisfies both.
- **Stale docs:**
  - DESIGN.md says the composer placeholder is "Chat". The code says "Ask anything about the paper" (owner, build 57
    `AHGQP…`, which superseded build 14 `AMG9…`).
  - DESIGN.md "Sheets" still says information sheets have Done. "Sheet top row" says X, no Done.
  - DESIGN.md "Tables" calls the All chats column "Last used"; the UI says "Last read" (build 57 `ALpxT…`).
  - SESSION_REVIEW.md says "Settings › Testing"; it's "Settings › Admin".
  - OWNER_FEEDBACK.md has no rows for the build 57/59 chat/Settings items, and none yet for the build 75/76 items.

## 5. Builds 57–62 (status was unclear) and older items

- **Builds 57–62:** all 44 screenshots were inspected. 43 are addressed or superseded in code: most of build 57/58 in
  9a3a6ee (native) and 642dbf1 (browser); build 59 in 5e4c1d2 and 9903f50; build 62 in c72b3f6, e2ad759, f73d0ff,
  9c5d206 and 38d6a1a.
- **Open:**
  - **AKjmUM (57) partly.** Privacy & data has "Papers and arXiv" with the arXiv API Terms link
    (`RootView.swift` 1511–1519; `PrivacyData.tsx` 19–23). There is **no Gradstep Terms of Service** anywhere.
    Add a row to About and to the browser. The wording needs the owner or counsel.
  - **ANDZcctw (62) mostly.** A second "Couldn't open this paper / reading bundle couldn't be loaded / Try again"
    screen remains (`PaperView.swift` 286–290); fold it into the single failure screen.
  - **ABb9F (59).** Downloaded papers exist on native only. The browser keeps copies in IndexedDB but can't list or
    delete them.
  - **ALLgF (59)** is superseded by "AI defaults by activity"; confirm the owner accepts the replacement.
  - **AHoJV (59).** The row-height change when an add finishes can't be confirmed statically; the compact
    Progress cell may exceed two lines.
- **Builds 13–46:** documented item by item in OWNER_FEEDBACK.md. Spot checks found them built:
  - formula copy, the A−/A+ control, chat titles, column choosers and horizontal scrolling, Discuss in chat,
    Open on arXiv, Back to chat, Suggested questions, Download new papers, Check for new episodes.
  - Several build-14 reader items (dot-leader contents, author-year links) belong to the retired Mathpix-era renderer
    and are **obsolete** under the HTML-first reader.
  - Still-live themes now tracked under 66+ items:
    - generic tags: build 15 `ABOS7OQ9…` and build 21 `AM6B5rjN…`, see G3;
    - leftover keyboard layout: build 21 `ACxg6N_I…`, see G7;
    - chat scrolling "when the text is done": build 32 `AHQMFEOu…`, superseded by the build 76 scrolling repair.
      Physical-phone feel is unverified.

## 6. Prioritized fix list

**P0 — feedback channel and wrong behavior in core flows**

1. **Feedback channel.**
   - Ask the owner for the device checks in §1. App and App Store Connect evidence shows nothing removed.
   - Ship the in-app screenshot shortcut and "Report this screen" in sheets (n).
   - Owner deletes the recovery-code feedback item in App Store Connect.
2. **AHYZ — Back from a promoted explainer chat lands on "New chat".** Fix the return target, the double Back and the
   title (n+b: `ReaderModel.swift`, `PaperPassages.swift`, `PaperView.swift`, `ChatTranscript.swift`; browser
   `chat-session.ts`, `Reader.tsx`). Decide C3 first or alongside.
3. **AOog — tag filter survives into search.** Clear it on Cancel and on every route into search (n+b).
4. **Duplicate imports (TreeCut).**
   - Client redirect, so the same paper is never imported twice (n+b).
   - Server idempotence (a new additive migration).
   - Merge existing duplicate rows.
5. **G1 — crop clipping (ACxn/APke/ALCJ).** Deterministic box expansion, a server coverage retry and a regression
   test (core, browser, server).
6. **AL-V0 label flip.** Reproduce, fix `svgTextLabels`, add the test, bump the renderer revision. Then double-tap
   zoom and fullscreen in the figure sheet (n+b).
7. **AG-KC.** Equations tab fallback or timeout (n).

**P1 — open owner design requests (73–76)**

8. G2 — "Search ML papers for X" from keyword chips and the Tags menu (n+b; also resolves C5).
9. APZf — equal styling for the two top-row actions, plus "Chat about Table" (n+b; C4).
10. AK1U — "New" text instead of the accent dot (n+b; C2).
11. AMZ1 — quiet sync banner, automatic backoff, plain Changes page (n).
12. AExY — catalog rename flash (n).
13. ACLs — catalog CSV export (n+b).
14. AHI8 — catalog left of search; get the owner's decision on moving + (C1) first (n+b).

**P2 — partly addressed items**

15. G3 — keyword distinctiveness and stoplist, and use the on-device index (n+b, vocabulary).
16. AIW2 — the abstract width fix misses `h6`; add a test (bridge).
17. ADtu — fold affiliations and e-mails into the header, bump the revision (compiler).
18. AIm3 — whole-label links for Sec./Section/§/Appendix/Alg./Fig/Lemma/Theorem (bridge).
19. AJ_g — one model/options control in the composer; browser credits line (n+b).
20. AKUp — real transition, or retire promotion per C3.
21. **Browser parity:**
    - AKyS two-step chooser;
    - AEhY Copy as Text and "Related papers";
    - ABsD "Table" return label;
    - composer microphone (APvKL);
    - Downloaded papers (ABb9F);
    - Chats column;
    - 10.5 px preparing percent.
22. **Small items:**
    - AHnf idle-state copy;
    - AJ_z figure-explainer spacing;
    - AJuj equation prompt;
    - AKjmUM Terms of Service row;
    - ANDZcctw second failure screen;
    - AEHf iPad selected-row accent check;
    - AA7q persisted status filter;
    - Gradstep link path and version handling;
    - AG-KC style dead code and stale comments (`chatDraftStatusText`, `ignoresKeyboardFrame`, "Scroll sideways",
      "smooth", the account-row "picture").

**P3 — documentation**

23. Update the stale DESIGN.md lines (placeholder, Sheets/Done, Last read), SESSION_REVIEW.md (Settings › Admin), and
    OWNER_FEEDBACK.md rows for builds 57/59 and 75/76. Record this triage's open items there with their eventual
    fixing builds.

Verification note: statuses come from reading code on main and git history, with four parallel read-only code
reviews whose key claims were spot-checked:
- `SheetChrome.swift` prominence;
- `returnToChat`;
- the `importPaper` duplicate path;
- `svgTextLabels`;
- the Equations `ProgressView`;
- the composer controls.

No tests, Simulator runs, hosted checks or paid calls were made. The label-flip cause and the iPad highlight
regression are code-reading hypotheses that need reproduction.

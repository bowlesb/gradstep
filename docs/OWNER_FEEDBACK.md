# Owner feedback log

## October 18 late screenshots / October 19 account deletion (in progress)

The repeated delete → Apple/Google return failure has a deployed lifecycle repair, not another one-time Auth-user
recreation. Durable beta admission survives deletion; unknown addresses remain denied. Two real hosted synthetic
delete/public-signup/verify/RPC cycles pass. Browser refusal copy first shipped in Pages **e8aa027f** and remains
in **3f363fda**. Native callback handling is tested in code and the Simulator. The repair shipped in iPhone/iPad
and Mac TestFlight 74 and remains in **75**, now VALID / IN_BETA_TESTING on both platforms with notes verified.
Interactive provider UI acceptance remains unverified. See NATIVE_AUTHENTICATION.md.

Five later screenshots are retained under `.artifacts/feedback/catalogs-20261019/`:

| Report | Finding / remaining work |
|---|---|
| `AMZ1EYpp-g46Tu85tdnKziA` | Real native transport omitted `v5_set_source_details`; a valid-edit regression reproduces `invalidMutation` before HTTP. The fix and full-list bound alignment pass 23 native queue/transport checks, including persisted-edit recovery. Included in iOS/iPadOS TestFlight 74; Mac 74 also VALID / IN_BETA_TESTING. |
| `ACN1pum4v1-mJuwgU22J7Ys` | Search ML papers at the top of the keyword menu; downloaded, not yet addressed. |
| `ACxnS6bB8Ga4qBTzECN3xrk` | Clipped subfigure; downloaded, investigation remains open. |
| `AHYZJO6d0-mkFRFYd-j1H_4` | Back to chat returns to the wrong place; downloaded, investigation remains open. |
| `AL-V0yuPVLvTrmalbO5c9yQ` | Double-tap figure zoom; downloaded, not yet addressed. |

The separately requested named-catalog management is available in iPhone/iPad/Mac TestFlight **75** and browser
Pages **3f363fda**. Library → top-right menu → Catalogs supports rename/create/switch/default and deletion with
existing/new destination or paper removal. Core/native data checks, iPhone/iPad screen journeys, six browser
journeys and the 15-case import gate pass. See LIBRARY_CATALOGS.md. The four screenshot items above remain open.

## Further screenshot feedback — 2026-10-18, 20:45–20:56 UTC (TestFlight 73 and browser deployed)

All six screenshots were downloaded and inspected in `.artifacts/feedback/build71-20261018/`.
Build **73** is **VALID / IN_BETA_TESTING** on iOS/iPadOS and Mac, both verified at **21:45:12 UTC**, with release
notes read back. Browser Pages **8d2514ec** is deployed. The current-source import gate passes 13/13 without skips;
seven affected iPhone journeys, three Mac journeys, two native bridge regressions and four targeted browser cases
pass. Screenshots were inspected. This establishes release/test evidence, not owner acceptance on the physical phone.

| Report | Requested behavior / diagnosed cause | Evidence |
|---|---|---|
| `AIxTRD9PfGy-NN-c6jJjzvY` | Reference actions all visible: the horizontal iOS edit menu paginates Copy/Open/Add/Discuss. Replaced by a vertical native action sheet; Mac retains its complete menu. | Native Copy/Back and Discuss journeys pass; screenshots inspected. |
| `AG6Tt6EQHLYdjkDVr7wbfEE` | Full-height Contents by default; double-tap article text opens it. | Actual Simulator double-tap and full-height assertion pass. |
| `ABXmwha89ij3YBl_O7vJmmk` | Small hint above the four tabs, persisted until the gesture has actually been used. | Simulator relaunch and browser reload preserve discovery; first-use hint disappears. |
| `AGKMdEtP7pqVb2aAzZqY6rg` | No section-jump animation: `__scienceReaderJumpToHeading` still explicitly used smooth scrolling. | Native and browser frame-by-frame tests pass with Reduce Motion off. |
| `ABakbeFhKrV6jstQ5kcx1Vo` | Device check/cloud and authors in separate columns, not beneath Title. | Simulator screenshot inspected; browser desktop/phone column persistence and scrolling journeys pass. |
| `AJLDiNJ6Dzq4eb06F-CvAhc` | Remove the visible keyword Edit text; keep keyword editing reachable. | Shared bridge updated; accessible editing name/action retained. |


## Build 71 feedback — 2026-10-18 (included in TestFlight 72 iOS and 73 iOS/Mac)

Seven new screenshots were inspected individually (`.artifacts/feedback/build71-20261018/`).

| Report | Diagnosis and change | Evidence |
|---|---|---|
| `AAIRTUkUM8VCNEXeNJ08xWY` | Equation heading changed while WKWebView retained its initial formula. Reload on markup changes, keyed by bundle identity; ignore obsolete navigation completions. | Actual web-view DOM regression passes after switching equations. |
| `AJ_z1-3h-S_4KMX3DQeREZ8` | Excess space between equation and model control. Reduced the shared spacing. | Affected native journey passes; included in build 73. |
| `AKySCAEqMG8jFIUsZuMgJUk` | Initial choice should be Default and Choose model. Consolidated the initial chooser; expanded controls retain actual model names and reasons. | Native chooser and cloud-failure journeys pass. |
| `AIm3cFZUGNMzCcnow--e9uU` | Only part of a Figure/Table/Equation reference was clickable. Expand the anchor to the complete named reference. | Real reader DOM link regression passes. |
| `AGaNyh3RbfCpwDS8YAPMU98` | Use Gradstep Keywords, without the redundant device qualifier. | Reader markup assertion passes. |
| `AA7qkZeMDULoabnV9nJltRg` | Launch restored a saved tag filter with no results. Tag selection now starts clear; user's tags remain intact. | Launch-state regression passes. |
| `AALT8OoJugZVuzIPaA4fCiQ` | Reopening a saved figure explainer needlessly requested a model. Read the exact saved answer before presenting the chooser; opening it makes no AI request. | Actual session test and close → figure → AI Explainer → saved parts journey pass. |

Native evidence: `feedback-chooser.xcresult` under the intake folder. iPhone/iPad local answering removal and
Mac model qualification are a separate owner-directed change in this batch. The PDF extraction model is retained.
No physical iPhone testing was performed. An initial import gate caught a test that inspected rows before its
background search completed; it now awaits the actual search, retaining all row/spinner assertions. The release's
source-matching gate passes 13/13. Older intermittent Rubric Judgments/DocPilot failures remain unproven.

TestFlight screenshot feedback is read from App Store Connect (`betaFeedbackScreenshotSubmissions`; screenshots are
saved under `.artifacts/feedback/`, which is not committed). Each item gets a plan and is closed with the build that
fixes it. “In build 19/20” below means the reviewed change is included in both internal iOS/Mac TestFlight builds,
confirmed VALID / IN_BETA_TESTING on 2026-10-08 UTC; it does not claim the owner has installed or accepted it.
Sources `b4b7ad7` / `bd2e0f2`; release evidence `.artifacts/takeover-20261008/build-{19,20}-processing.json`.
At that checkpoint, build **21** (`c10e54c`) superseded both and was VALID / IN_BETA_TESTING for iOS and Mac.
It retained those fixes and added clearer reader download-limit, interrupted-download and update-required messages;
35 focused native tests pass. Evidence: `.artifacts/takeover-20261008/build-21-processing.json`.

## Build 70 feedback — 2026-10-18 (TestFlight 71 on iOS/iPadOS and Mac; browser deployed)

Twenty new screenshot reports were downloaded and individually inspected. No new in-app support reports or crash
reports were found. Evidence: `.artifacts/feedback/build70-20261018/`. The screenshot timestamps follow build 70;
the per-report ASC build relationship was not accessible (403). Build **71** from `c4d15d9` is
**VALID / IN_BETA_TESTING** for iOS/iPadOS at **2026-10-18T17:04:13.483Z**, with release notes verified. Browser
Pages **13724098** is deployed. Mac **71** from `927cbe9` is also **VALID / IN_BETA_TESTING**, with release
notes on both platforms verified at **2026-10-18T18:02:37.560Z**. The visually detected fullscreen-sizing defect is
corrected; the complete Mac and iPhone journeys and screenshot review pass. The final
feedback readback contains 189 screenshots with no further page or new reports. Inclusion below does not claim
owner-device acceptance; physical iPhone access remains paused.

| Feedback | Request | Status |
|---|---|---|
| `AOxhjTUj5Opevk-Il8QEe7Q` | Looking at table  | Included in iOS/iPadOS and Mac 71 |
| `AHQ6KQmwNL2yCmG3G5J0sRw` | Zoom works but you need to be able to full screen it before hand  | Included in iOS/iPadOS and Mac 71 |
| `AJujgmmq5eRFrgxrjf4vUzg` | In these sections, we should say what the authors want to argue as part of the result, ie it should say because X is greater than Y, the authors believe Z , just as am exanamplw  | Included in iOS/iPadOS and Mac 71 |
| `ABsD30JFf1gsmDpSTepGRm8` | I clicked from a table AI explainer chat to the paper, and there was no “Back to  Table Explajner” and also, then I got directed up here  | Included in iOS/iPadOS and Mac 71 |
| `APkeR39IIELErvOzT54Freg` | The crop dimensions are not good  | Included in iOS/iPadOS and Mac 71 |
| `AOkAOUHyt7v6c8t9W3bRWwk` | When I click on references in the paper there are heavy transitions, but they ad no value - just have it take me directly to the correct place  | Included in iOS/iPadOS and Mac 71 |
| `AKUpnsmo22QanrGf9iVxe6o` | We need a chat icon to the left of X and when you press it does a very graceful transition of this UX into the chat UX, exactly same as if you were to have picked the actual Chat button with the Figure content just magically loaded into it | Included in iOS/iPadOS and Mac 71 |
| `AIW2SzNnfmiwSiRJIhzKH1c` | I notice the text here is not as wide as it could be, there is a gap on the edges the text needs to extend just a bit more  | Included in iOS/iPadOS and Mac 71 |
| `AFNROYs1C2shOq6_tVetGQk` | keywords can be a header similar to Abstrct Intro etc.  Also, say the source if we came up with them , say Gradstep Keywords , or from Archiv say “Archiv Keywords” etc . You can put. ( edit ) right after to indicate they are clickable to be edited  | Included in iOS/iPadOS and Mac 71 |
| `ADpoeQ6c6bAiCu8el1W1Ye8` | To the left of the arrows there should be a icon that allows you to list a list of occurrences in table format, each allows you to click back to the paper at that spot  | Included in iOS/iPadOS and Mac 71 |
| `ALOAfmV3YuPNtl-N7CpOIhk` | I ended up here after navigating away from the find in paper  | Included in iOS/iPadOS and Mac 71 |
| `AGKm2VZUi8E9wuaEpQ-zo1M` | Also this after navigating away from find in paper  | Included in iOS/iPadOS and Mac 71 |
| `AHqnfqgG6QhAxsiiXCycKw8` | I should have a find similar papers option here  | Included in iOS/iPadOS and Mac 71 |
| `AB5RbQvOOBVm5rcCw7dVdFI` | We need to put a hard no on artificial intelligence and machine learning as keywords. It should be based on keywords that uniquely identify the paper as compared to other papers. My suggestion is to maintain a very fast on device index which also will selectively delete contents for that paper when the reader contents are deleted  | Included in iOS/iPadOS and Mac 71 |
| `ABQMRH-P_HMeXzuVVvFJhvs` | I want a Share option - that if you click has two options , one just for Archiv or the publisher url. Another specific grad step url, it’s smart about what it does, if the app it on phone, it deep links to the phone and if the paper isn’t there, it takes to search if it is there then it just opens to the actual paper.   These links should be designs in such a way that links to figure and table AI explainers also work ( not necessarily to implement that latter part right now ) | Included in iOS/iPadOS and Mac 71 |
| `AHnfxB7MNfJSOayC2DDJQKE` | “find papers” text redundant  | Included in iOS/iPadOS and Mac 71 |
| `ACMcVM602Rz-vXruEFQ43Fo` | My suggestion is that we have a basic keyword search but if you want you can expand it and do a more detailed search that allows you to choose field types from drop downs and then specify the specific criteria | Included in iOS/iPadOS and Mac 71 |
| `ABsQQla8nqWJpFfXRh1hecE` | The checkmark and the percent number before it are too small and not centered vertically  | Included in iOS/iPadOS and Mac 71 |
| `AKzAZhje38OzGFDx5K8czRo` | We should cleverly add the html and mermaid options into list of related questions somehow … it’s not a question per se, but try to make it a good option with UX | Included in iOS/iPadOS and Mac 71 |
| `ABOb4eqeePw0LqdsgW6pBZM` | I notice on here that Deek Seek was chosen , why? My suggestion is that we have different scenarios and different chat option defaults in settings , need to build this UX in settings   | Included in iOS/iPadOS and Mac 71 |

Additional owner request: investigate a purpose-built local subfigure/plot detector, shared by Figure AI Explainer
and ordinary cloud/local chat. Evaluate complete panel boundaries, axes/legends, iPhone resource requirements,
model/weight licenses and artifact provenance. Investigation complete: [design](architecture/LOCAL_FIGURE_REGIONS.md) and [measured Mac/Core ML experiment](reviews/LOCAL_FIGURE_REGIONS_20261018.md). The tested detector is fast after loading but misses regions and clips labels; it is not bundled. Research/prototype acceptance does not imply phone readiness.

## Build 69 feedback — 2026-10-18 (TestFlight 70 on iOS and Mac)

All 169 screenshot submissions were retrieved; the 19 new build-69 reports and four unclosed earlier UI requests
were inspected individually, including the seven chat inspiration images. Evidence: `.artifacts/feedback/all-20261018/`.
Build **70** from `2e461b4` is VALID / IN_BETA_TESTING on iOS and Mac, verified `2026-10-18T07:20:34.040Z`; release notes were
written and read back on both. Browser Pages **6ddf4887** is deployed. The checklist records inclusion in that
release, with the device-inference and microphone limitations below.

| Feedback | Required result | Status |
|---|---|---|
| `AJ_ghNZCc2TPoLQcQI64ss4`, `AF8s3goTA3zCRKQgfDCo5Tk`, `AOGV8iwN8oALZBCIwiyBJOA` | Actual model name in a consolidated composer/explainer control; local names end in “(local)”. | Included in build 70 |
| `AF3va71uyfJl9SS2unSsRVQ`, `AMZILJ5QrDuQxRe1s68Qh-g` | Simple default/cloud/local choice; proactive downloads and honest device compatibility/performance in Settings. Establish why iPhone refuses larger models. | Included in build 70 |
| `AEMnPGx7JyLldpyKPDyoOXI` | Remove the account face icon. | Included in build 70 |
| `AFMWFCg4drJsFsphnc5r7q8` | Disable Sync now when already synced. | Included in build 70 |
| `ANzwcWN12jtwwn5VOe4xxr4` | Three Anthropic model choices and two other-provider choices on separate rows. | Included in build 70 |
| `AEhYxws8LHOkth-WZbiHQKg` | Equation menu starts with Chat about Equation; remove Why it matters and duplicate copy; Copy as Text copies full LaTeX. | Included in build 70 |
| `AJmP3AGjSBDc_lSKXki3Sbg` | Library placeholder is Search. | Included in build 70 |
| `AH4X0rcoCTrD7GMa8ZVhJoI` | Editable paper keywords before the introduction. | Included in build 70 |
| `ABpFobeCnmum1y5oQ6eXJaY` | Show 0 in the Chats column. | Included in build 70 |
| `AFApSc2oh3EHD6gjW7Dvlgo` | Find and repair the missing Added date. | Included in build 70 |
| `ADtu4d3nuppfXDfMCpltx2o` | Repair the affiliation/contact block of 2610.22353v1 (the screenshot is not a bibliography failure). | Included in build 70 |
| `ACo538NX-0smYuNu1fjpQoQ` | Author tap offers a search for that author’s papers. | Included in build 70 |
| `ABYO8P1SY4632Iona4eyyuk` | Equation zoom actually enlarges; pan follows overflow automatically; minus, plus, percentage. | Included in build 70 |
| `AGzcvn1gg3maCYx7j1nUA9o` | Equation and figure explanations plus conversational follow-ups in the same view. | Included in build 70 |
| `AELl5FEzHTGgvHM9ZVZOZzo` | Render the reported conditional-routing cases and quantum ket formulas. | Included in build 70 |
| `ALwRw3t1IcviLG-AEohCJXY` | Zoom figure explanation crops. | Included in build 70 |
| `AEHfQ2RMLuN3d5lH8wDtk0g` (68) | Vertically center the temporary arXiv title while Adding, preserving equal row heights. | Included in build 70 |
| `AHZ7kJjPRjyb0R38c9Ph43k` (67) | Remove the Draft saved label; retain draft persistence. | Included in build 70 |
| `AKs7SR4wVXNI88s6V0BwZ7s` (67) | Align New chat with its paper subtitle. | Included in build 70 |
| `APvKLlmyyygSM6UlVANkQ-Y` (67) | Composer microphone and readily accessible answer controls, informed by the supplied examples. | Included in build 70 |

Required import/session gate: **13 passed, zero failures/skips**, with matching source. The final 123-paper sweep
has zero failures and eight unchanged warnings. Four exact-source native paper replays pass, including the
large-image overflow repair. The affected iPhone/iPad Simulator, Mac and browser journeys pass. Existing saved
papers need **Reader version details → Update this paper** for the affiliation/compiler changes.

Physical iPhone access remains paused. Larger models can still be unavailable under the current app memory limit;
the optional increased-memory profile capability remains unchanged because developer-portal access was blocked.
Actual microphone capture/recognition remains unverified. Simulator, exact-source compiler replay and real Mac inference are distinct
acceptance evidence; none establishes iPhone inference speed or memory safety. No broad paid model comparison.

## OpenRouter activation override — 2026-10-17 19:54 UTC (deployed, live check passed)

Owner: **“I am over riding the check, please make open router work again.”** The account logging/data-use check
no longer blocks activation. Flash is enabled in persistent staging configuration and deployed; the actual
profile table recommends it. One real request selecting that published recommendation completes in 4.506 seconds,
costing $0.001296075; all fast checks pass. No new app build is needed. Restart build 68 to refresh profiles;
an existing Sonnet chat or saved default needs Flash selected explicitly. No owner-session impersonation or phone
test was performed. The privacy switches remain unverified; request safeguards and budgets remain unchanged.
The server activation gap is closed with this evidence; actual owner-device acceptance is not claimed.
Evidence: `.artifacts/flash-activation-20261017/`.

## Local AI build and cloud still broken — 2026-10-17 (TestFlight 68 available; 15:08 checkpoint)

- Owner requested a build of the local chat/equation/figure prototype. TestFlight 68 is VALID / IN_BETA_TESTING on
  iOS and Mac as of 15:08 UTC. Model downloads are explicit; no phone acceptance is claimed. The release import/
  session gate passes 13/13 with no skips; archive contents and prior real Mac MLX inference are verified.
- Screenshot `ALgpsts9zZmv6PsboQse3BY`, 08:49 UTC, shows OpenVLA reference-add failing with the generic AI-service
  message. The corresponding 08:48 request and another at 14:32 are Anthropic `provider_billing` rejections. The
  100,000 app credits do not fund the upstream account; Flash remained hidden despite OpenRouter funding.
- Fresh Flash diagnosis reproduces a second cause: HTTP 404 for the account's ZDR policy against AI Studio.
  The fixed, explicitly ZDR-restricted Google Vertex US route passes seven deployed live generations, including
  the same OpenVLA add path, figure/detail and equation actions. Activation still requires the account logging/
  data-use check; this item is **not closed as working for ordinary readers**. Build 68/browser now distinguish
  model-balance failures, preserve the question and avoid an ineffective same-model retry.
- Additional screenshots at 08:44–08:48 are recorded for follow-up: chat microphone/settings inspiration
  (`APvKLlmyyygSM6UlVANkQ-Y`), remove “draft saved” (`AHZ7kJjPRjyb0R38c9Ph43k`), and left-align New Chat
  (`AKs7SR4wVXNI88s6V0BwZ7s`). These are not implemented or claimed fixed in this release.

Evidence: `.artifacts/release-68/` and [current cloud diagnosis](architecture/GEMINI_FLASH_CHAT.md).

## Login still blocked, 2026-10-17 08:26 UTC — beta access repaired

Owner: “my oath provider? what? … I am not even able to login at all.” The application’s sign-in options are Apple,
Google and email code; asking the owner to diagnose a provider was unnecessary. Hosted logs show repeated HTTP 422
`signup_disabled` today. The original account's hosted deletion/refresh audit events establish the exact address.
A fresh confirmed beta login for that address was created and read back as open at **08:30:31 UTC**. No new build,
password, email, credits, restored data or public-signup change. Actual owner sign-in remains to be observed.

The extended unpaid hosted test reproduces deletion and old-session rejection, re-admits the same synthetic address
as a fresh UUID, and verifies the app's email-code exchange plus account RPC (both HTTP 200), then deletes the
fixture. Evidence: `.artifacts/feedback/login-access-20261017/` and
`.artifacts/auth-lifecycle/2026-10-17T08-31-42-852Z.json`. Flash activation is a separate pending account-settings check.

## TestFlight build 66, 2026-10-17 06:05–06:10 UTC — session failure and FDE-Gym (browser / TestFlight 67 released)

All seven screenshots are retained privately under `.artifacts/feedback/followup-20261017/`.

| Feedback | Finding and fix | Evidence |
|---|---|---|
| Figure explainer (`AJuyKkNNTiFeAV5MuZ2QlqI`), chat (`ACVQHdRz8bI5W8FDZlRTYSg`), Feed (`AEYSbX5tCmVlpQe5bpyIBZo`), local papers despite sign-in error (`ABg02E4ni_mpLk_1RHT_4Us`), deletion error (`AA65AIWSKfwR6apOpDiZXsc`), reference add (`ACqjeCBOh_0IA889ZdKG9Vk`) | The native client retained an invalid cached Auth session after remote deletion. Its refresh error became generic “Sign-in couldn’t be completed”; local papers remained visible while every cloud action failed. Definitive refresh/RPC/chat rejection now retires that backend/model session and returns to normal sign-in. Network outages preserve offline access; encrypted local files/keys are retained. The stale deletion sheet closes when its account session changes. Browser RPC/stream rejection now also retires its visible session. | Hosted two-session deletion reproduces 400 `refresh_token_not_found` and 403 / SQL `28000` / `authentication_required`. Native regression fails three assertions on old code, then passes. 44 focused native checks, including actual sign-in/restart UI, pass with `-O`; browser units and desktop/phone journeys pass. This reproduces the observed failure path; it does not inspect the physical phone or restore the owner's deleted login. |
| FDE-Gym (`AAd00453-BHJNB4hJmBIBRo`) | Official HTML `2610.22350v1` emits font setup options as plain text at the start of a custom title paragraph. Revision 18 removes only that recognized prefix; title/project links/contributions/affiliations remain. | Two authored regressions; full device compile keeps all seven images and 63 equation entries. Before/after reviewed. Exact source/asset responses and forbidden-text assertions join the native import gate. Existing working copies need Reader version details → Update this paper. |

No provider call corresponds to the six cloud-failure reports. The eight earlier Flash checks were synthetic,
succeeded through the deployed adapter and cost $0.108185933; they did not activate Flash for ordinary readers.
The selected Flash default is still hidden pending confirmation of the two OpenRouter account privacy switches.
A fresh beta invitation was still pending at this release checkpoint; it was completed at 08:30 UTC as recorded above. No new paid AI call was made.
The expanded release gate requires 13 checks, including the seven-paper replay and session retirement.
Its first run blocked release: all 12 unit/import methods passed, but the startup explanation could disappear.
The explanation now stays beside Sign in and in Settings; the screen journey explicitly requires it.
Final release-optimization gate: **13 passed, zero failed/skipped** at 06:43 UTC, including the seven real papers
and the persistent-message/sign-in/restart flow. Final screenshots reviewed. Evidence:
`.artifacts/import-acceptance/2026-10-17T06-38-58-152Z.xcresult`.
Source `1d5f7aa`; browser `103582dd` deployed and verified. TestFlight 67 iOS and Mac are VALID / IN_BETA_TESTING
(06:57:42 UTC). Both signed archives match the tested revision-18 compiler. No newer feedback was present at that check.

## TestFlight build 65, 2026-10-17: import reliability, chat and account deletion

Feedback images and hosted readbacks are retained privately in `.artifacts/feedback/import-reliability-20261017/`.
Browser changes are deployed as Pages **91c7d07f**, with entry assets verified. Native changes are included in
TestFlight **66**, source **a539550**: iOS and Mac are **VALID / IN_BETA_TESTING**, confirmed 05:45:52 UTC.
The AI activation and re-invitation dependencies below were open at this client-release checkpoint; the 08:30 UTC
operator repair above supplies fresh beta access.

| Report | Established cause / response | Verification or remaining dependency |
|---|---|---|
| DocPilot, 2610.21327v1 (`AEC_-Omz-Cm7Y4YRyPxPThQ`) | Algorithm 1 embeds four text badges as SVG inside MathML. The math sanitizer rejects them; after that is fixed, flow classification mistakes the algorithm's SVG badges for figure images. Revision 17 extracts only the narrowly recognized badge text and excludes math descendants from figure classification. Unknown vector math still fails visibly. | Before: `arxiv_math_element`, then `figure_structure`. After: full device compilation and native encrypted install/reopen pass. |
| More Methods, 2610.19789v1 (`AN2N3cvxIscr9bi_DcpZkrM`) | arXiv serves HTML 404; its PDF is available. | Exact responses replay through native Library → Open PDF → encrypted save → PDFKit render → offline reopen. Automatic PDF opening is proposed, awaiting owner direction. |
| Library row height/spinner (`AHkxGOXC-_W1r5wZt9HSQ7M`) | A short ready title reserves 64 pt; an adding row reserves 84 pt. The spinner is 14 pt near the row's top. All Library rows now reserve the same title/author space; both initial Adding and subsequent preparation states share the larger indicator. | Actual UIKit red/green geometry: both rows 84 pt, spinner 20 pt at the 42 pt center. Screenshot reviewed. |
| Answer options (`AHymjh1Amb38m-iP1-czaOQ`, `AGGyBXTh4pfGJ98J6z24kXU`) | Remove the native title/Done row; retain the drag handle and accessibility escape. Say “New chats currently start with …”. “Reset default settings” is visible but disabled until the current choices differ; its existing action saves the current choices for new chats. | Browser affected journeys pass (12); native Settings defaults and final two sheet journeys pass; Mac close journey passes. Light/dark screenshots reviewed. Mac retains an X to close its sheet. |
| Gradient behind chat (`ANxeYmqyzosdFHDcDwiM1no`) | Remove the accent glow behind empty-chat starters in the apps and browser. Keep their position and the ordinary flat chat background. | Included in the light/dark chat screenshot review. |
| AI chat broken again (`AN1GwE_5DdVwAA1UdFecQg8`) | At 04:43 UTC the selected Sonnet request and four auxiliary Haiku attempts were refused as `provider_billing`. OpenRouter has $10.205283699 remaining, but Flash is still hidden. | No new paid calls. Activation awaits confirmation that OpenRouter input/output logging and data-use opt-ins are off; the ordinary app default is still Sonnet. |
| OAuth says not invited after deletion (conversation) | Auth login deletion completed at 04:48:45 UTC. Private-beta signups are disabled and no independent invitation survives Auth deletion. | Fresh confirmed beta login created at 08:30 UTC using the original UUID's Auth audit address. Hosted re-admission/email-code test passes. No guessed address, old-account resurrection or public signup. |

The new explicit import acceptance gate covers all six reported papers, real local PDFs, failed/missing sources,
cancellation, explicit retry, no automatic retry loop, encrypted storage and reopen without network. It uses `-O`
and whole-module compilation; upload scripts reject absent, skipped, failed or stale evidence. This fixes the earlier
verification gap without making the routine fast tier call arXiv or providers. Physical-phone access remains paused.
Final import gate is **7 passed, zero failed/skipped** (`.artifacts/import-acceptance/2026-10-17T05-17-25-813Z.xcresult`).
Native UI evidence: `chat-controls-iphone.xcresult` (Settings pass; initial dismissal assertion failure),
`chat-controls-iphone-passed.xcresult` (two passes, including light/dark), and `chat-controls-mac.xcresult` (one pass)
in the feedback artifact directory. Fast tier: 650 backend / 469 browser passes. No paid AI calls.

## TestFlight build 64, 2026-10-17: `Code: invalid` — cause reproduced, fixed in build 65

New screenshot `AHX5KiKf7h8mFPm8-E953es` (04:01:46 UTC, build 64) shows VLA-Δ, 2610.21306v1, with
**Code: invalid**. The actual native Library flow reproduces that error with Swift optimization enabled (`-O`),
while the same paper passes with optimization disabled (`-Onone`). Local stage-specific diagnostic codes narrow it
to the final image-collection guard, `asset_input_missing`; no diagnostic build was sent to the owner.

**Cause:** inside the concurrent image task's `do/catch`, Swift 6.3 compiles
`return (index, try await acquire(...))` so every successful image returns index zero (`swiftlang-6.3.0.123.5`). Downloads overwrite the
first slot, leaving the others empty. The per-image catch introduced in `c603266` exposes this failure. A standalone
program without network or WebKit reproduces it: with 1/4/10/36 inputs, `-O` fills only 1/1/1/1 slots; `-Onone`
fills them all. Awaiting into a local variable before returning `(index, bytes)` fills all slots under `-O` too.

**Why it escaped:** the existing authored native fixtures each had one unique image, and real-paper Simulator
checks used debug optimization. Neither could detect this release-only collection failure. The earlier memory
hypothesis did not explain it. The new authored regression uses ten distinct image URLs with out-of-order
completion and one deliberately missing image: it fails on the old expression and passes with the fix. The
three original reported papers also pass native cached replay with `-O` after the fix. The explicit native tier
now uses `-O` and whole-module compilation.

**Final verification:** all four reported papers download, install in the encrypted store and reopen through the
native Library flow with `-O` and whole-module compilation: VLA-Δ in 8.71 s, MetaShare/ManiFusion/Rubric Judgments
started together in 21.74 s. The native reader suite passes five tests (one unrelated live-DPO opt-in skipped),
including the ten-image regression and cached replay of the three original papers. `npm test` passes. This is
Simulator verification with the release compiler settings, not a physical-phone acceptance claim. Build 65 is
uploaded from this verified fix (`940e574`): iOS 04:30:19 UTC, Mac 04:33:15 UTC. Both are **VALID / IN_BETA_TESTING**
as of **04:35:57 UTC** (iOS first confirmed 04:33:41 UTC).
Release status is recorded in IMPLEMENTATION_STATUS.md.

The host now names each validation stage instead of using the same `invalid` code for unrelated guards.
Renderer revision remains 16: acquisition changes, generated bundles do not. Evidence:
`.artifacts/feedback/20261017-invalid/` (`library-optimized-vla.log`, `library-optimized-located-vla.log`,
`cached-optimized-trace.log`, `collector-{before,after}.swift`, `multi-image-regression-{before,after}.log`,
`release-optimized-reader.log`, `release-optimized-library-three.log`, `fast.log`).
No physical phone access or paid AI calls. The history below records the earlier incomplete investigation.

## TestFlight builds 63–64, 2026-10-17 ~04:00 UTC: earlier investigation, unresolved at that checkpoint

The owner installed build 64 and reports the same failure. Shipping that build during this investigation created
the expectation that the reading feedback had been addressed; no root cause or reader fix had been established.
Do not present the Simulator passes or diagnostic logging as a fix, or ship another proposed reader fix without
evidence tying it to the failure. Build 64's additional background error logging is **only active during a locally
started test-session recording**; it does not automatically deliver the phone's failure code to the developer.

Owner: “All of theee can’t be read ?” Screenshot `AOdhYANzVPZB-0xNEpmOwaM` shows Library preparation failures
for MetaShare (2610.21887v1), ManiFusion (2610.21433v1) and Rubric Judgments (2610.21214v1). App Store Connect
confirms build 63; no new crash submissions. Evidence: `.artifacts/feedback/20261017-current/` (private local files).

All three exact official HTML revisions are available. Local full device-compiler replay succeeds with all 4,
36 and 11 source images respectively; bundles are 1.0, 15.1 and 1.1 MiB. The source sweep has no failures; Rubric
Judgments has a separate existing `\\boxed` text warning. This does **not** explain or resolve the phone failure.
Native iPhone 17 Pro Simulator replay also opens all three through WebKit and independent Swift admission in
1.2–4.2 seconds each (674/354/214 blocks; 343/597/498 equations for MetaShare/ManiFusion/Rubric Judgments).
Next: obtain the failure screen’s ⓘ code, requested from the owner. The screenshot alone does not identify
memory, timeout or validation as the cause. Background Library preparation now records its failure code in an
active local test-session recording, matching the foreground open path (previously discarded there); no paper
text or identifier is logged. This diagnostic change does not fix the reported failure. Physical-phone access
remains paused; no paid model call is needed for this investigation. Status: investigating, not fixed.

Follow-up, ~04:00 UTC: the new opt-in `LibraryModelTests.testReportedPapersDownloadInstallAndOpenThroughTheLibrary`
also succeeds for all three with real native URLSession downloads started together, encrypted installation, and
opening each saved copy (22.6 seconds; one test, zero failures). It uses a fixture account backend on the iPhone
17 Pro Simulator; it does not reproduce the phone's OS, network, memory or prior account state. The compiler bytes
in the uploaded build-64 archive match those in this Simulator build (SHA-256
`5b9d9c5f6b8042a4c14d94953bb107e5cbb0a76ebefb44634711bad18337a9af`). Evidence:
`.artifacts/feedback/20261017-current/library-live-investigation.log`. No newer screenshot submission or in-app
owner support report was available when checked. The failure screen's existing ⓘ code remains needed; requested
again without asking the owner to install another build. No product change or release in this investigation.

## TestFlight builds 57–58, 2026-10-16: two papers refused over one figure each, and the table gradient

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "Fail" (ActionOPD: Distilling Decisions, Not Tokens, 2610.19820v1) | Reader (all surfaces) | The device compiler refused the paper (`svg_id`): its teaser SVG names two Illustrator layers both `layer_1`. Revision 15: a repeated id nothing refers to is dropped from the later element and the figure is drawn; any figure the device still can't prepare becomes a note ("This figure couldn't be shown here; the PDF has it."), never a refusal. | Fixed in revision 15 (not yet in a build) |
| 2 | "Couldn't open this paper — This paper exceeds the device reader's preparation limits" (InfoVis, 2610.16784v1) | Reader (all surfaces) | One 1,802 × 1,275 pt diagram SVG was over the pixel limit at twice its size (`image_dimensions`). Revision 15 draws an over-large picture at the largest size the reader allows (it is a vector; the pixel budget keeps fewer pixels anyway). All 13 figures show. | Fixed in revision 15 (not yet in a build) |
| 3 | "I really dislike this gradient" (a wide table's left/right edge) | Reader (iPhone, iPad, Mac, browser) | The reader bridge's scroll shadows (`reader-bridge.js`: grey radial gradients plus page-coloured covers) on every table and display equation that scrolls sideways. Removed; the box is flat and an edge with more beyond it shows a 1 px hairline, light and dark. | Fixed in the bridge (not yet in a build) |

## TestFlight build 55, 2026-10-15: "Couldn't open this paper" (YouZhi, 2606.05868)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Screenshot: "Couldn't open this paper — The HTML reader couldn't preserve an equation in this paper." | Reader (all surfaces) | One `vertical-align:-2.1pt` on one formula refused the paper (`arxiv_math_style`). Unknown math styling/attributes are now left out, not refused (revision 13). The staging-library sweep, now running the app's validator, found two more refusals in the owner's library: VideoJev (picture title, `index_title`) and The Parallelism Tradeoff (empty headings, `index_heading`), both fixed; revision 14 adds notes on figures arXiv's HTML lost, real names over template placeholders, and a footnote-mark fix. | Fixed: build 56 (rev 13), build 57 + browser (rev 14) |

## Chat, 2026-10-15: figure display, and monitoring at 100 → 1,000 people

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "I think the Figure display needs work. It should display sub figures at the bottom the crops should be inline, right as the chat discusses each one." | Chat (all surfaces) | Read as: each crop inline where the answer discusses it, and the whole figure with its parts outlined at the bottom. The model marks each part's place (`[[part N]]`); the apps and the browser put the crop there. Proven live on DPO's Figure 1. | Built; chat function on staging; browser and build 53 |
| 2 | "imagine there are 100 users … could be 1000. Imagine the graphs I need to monitor, what are they, how do I access them, does it feel seamless ? Please build" | Admin | Health tab: people, use, reliability, cost, with an Attention list and 100/1,000 projections; one sign-in (password + authenticator), Home Screen app, link in Settings. Cannot see papers that fail on the device (the server never sees them). | Live on admin.gradstep.ai (staging data) |

## Chat, 2026-10-15: "Sending figures to model should be ok?"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "Sending figures to model should be ok?" (after "the agent has the ability to break figures into cropped sub sections as part of the response and explain each component") | Chat | Yes, on the same terms as the text: the figure is part of the paper whose full text already goes to Anthropic, under the same retention terms, prepared on the device from arXiv's HTML (no PDF, nothing new fetched); about half a cent per figure. The one condition: the consent must say so, so it is v3 ("When you ask about a figure or table, its image from the paper") and readers are asked once more. Built: a question naming a figure sends its image; the model can break it into parts, shown as crops under the answer with a note each (CHAT.md "Figures in chat"). Proven live on DPO's Figure 1. | Built; build 47 (apps); the browser follows |

## Chat report, 2026-10-15: figures in parts "Not able to do this", "Even when I referenced a figure it still didn't work"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | The answer said no figure was attached (CaLIF, 2610.19525) | Chat, paper | A question naming no figure number attached nothing; the model now asks for the figure it means and the device asks again with it. Naming one works in builds from 47 (checked on this paper in the Simulator: Figures 2, 3, 4); a phone still on build 46 or earlier sends none. A figure with panels was two figures and its "Figure 1" caption a paragraph, so "Figure 1" was not found: panels are one figure now and go as one image. While a figure goes with a question, the chat says "Looking at Figure N…". | Built; live proof on staging; build 52 and the browser |

## Chat request, 2026-10-15: "create a version of the on device model into the app knowing it won't always work"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Put the on-device model in the app, knowing it won't always work, so we can try it and give feedback; evaluate it and prepare a message for the model-building agent | Reader (experimental) | The desktop's port kit, ported: Swift text layer, Core ML models, TypeScript converter (`docs/architecture/DEVICE_PDF_ROUTE.md`). A paper whose PDF is on the device: options › "Read with the on-device model"; the reading opens under a banner with Report and "Show the HTML reading". Evaluated on the eight fixtures (3 pass every gate, all verify); message: `docs/proposals/DEVICE_MODEL_FEEDBACK.md`. | Built; Simulator journey; build 49 |

## TestFlight, 2026-10-15 05:50–06:07 UTC (build 46, iPhone, 6 items)

Screenshots: `.artifacts/feedback/` is not committed; the batch was read from App Store Connect.

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "Not the nicest presentation" (LensErase title page: a logo figure, the abstract, a table of authors and notes run together) | Header | The title-page fold now skips a logo figure, reads past the abstract, reads an author table cell by cell, splits notes at their marks and keeps project-page lines as addresses; adjacent marks merge. | Built; fragment test; build 48 and the browser |
| 2 | "If you bothered to create a diagram please show it. But I think the different questions don't need to be there… upon request… takes up to much space" | Chat | A Mermaid diagram is drawn in the answer (a picture rendered on the device; a tap opens it full size with zoom) and an HTML visual shows inline; the suggested questions sit behind one small "Suggested questions (N)" control. Browser: the diagram draws inline without zoom tools, "Full size" opens the dialog; the questions fold the same way. | Built; native and browser journeys; build 48 and the browser |
| 3 | "Fail seems like author lists are ridiculously difficult ???" (FiLM, 1707.03017) | Header | The author table LaTeXML placed after the abstract folds into the header now. | Built; device compile; build 48 and the browser |
| 4 | "Should say the exact time please" | Library table, Added and Opened | Today shows the time ("11:02 PM"), then "Yest. 9:14 PM", the weekday within a week, the date with the time this year, and the date with the year before that; the browser's table says the same. | Built; native unit test; build 48 and the browser |
| 5 | "Why is performance on a new line ?" (2610.10478) | Header | A line break inside a title or heading is a space now; a name run into the affiliations is split at the catalog's name, and corresponding-author lines move to the notes. | Built; device compile; build 48 and the browser |
| 6 | "Ended up here" (Habitat, 1904.01201v2: "Couldn't open this paper") | Device reader | One figure is 9,900 × 1,938 pixels, past the side limit, and the compiler refused the paper (`image_dimensions_exceeded`). Images are checked against the device's own bounds (16,384 px a side, 80 MP) and an image past them is left out of its figure, counted, instead of refusing the paper; both apps name the code. | Built; device compile 3.5 MiB; build 48 and the browser |

## TestFlight, 2026-10-15 04:32–04:40 UTC (build 44, iPhone, 6 items)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "I see many situations where I press Back and I get to the top of the Article???" | Reader, after a chat citation | The jump from the chat opened the paper and recorded the top as "where you were". A chat jump into a paper not yet read offers no Back now (Back to chat stays); in-page links keep theirs. | Built; build 46 |
| 2 | "I was reading a paper, I saw a Back to where you were, I tried to swipe it and somehow I got to this screen" ("Couldn't open this paper — The reading bundle couldn't be loaded completely") | Reader | That screen appears when the web content process dies (memory, or a gesture that unloaded the page). The view now reloads once by itself before saying so. | Built; build 46 |
| 3 | "The Back to where you were feature, it needs to say where that is, maybe a reference? Also there needs to be a little x button that makes it go away" | Reader | Back names the section it returns to ("Back to 3 Method", from the nearest heading above the place left), and an X beside it ends the offer without going back. | Built; build 46 |
| 4 | "Still seeing this message" (Rubrics: "preparing it again failed. This paper couldn't be prepared on this device.") | Reader, stored copies | Found: the device store keeps one copy per paper revision and refused the new one as a `revisionConflict` because the old copy was removed only after installing. The old copy leaves first now; the notice names the store's own reason if it ever recurs. | Built; build 46 |
| 5 | "'Preparing' at the initial step is really Adding to library, right? … you are not automatically downloading when you add to library but you could… a setting that allows you to decide if you want to automatically download new papers" | Library | The server's stage says "Adding…" now; the device's download and preparation say "Downloading…" and "Preparing…". A paper that was already in the library when its import row went (LensErase) was missed: both orders are handled now. Settings › Library: "Download new papers automatically", on by default. | Built; build 46 |
| 6 | "For some reason the first time I clicked nothing happened second time I got the actual popup. But let's use a native style popup like Copy similar to when you select a term and want to explain in chat" | Reader, references | A tapped bibliography entry opens the same native edit menu as a tapped equation, beside the entry, instead of the sheet: Copy first (as for selected text), then the link by its own name ("Open on arXiv"), Add to library, Discuss in chat. | Built; build 46 |

## TestFlight, 2026-10-15 04:04–04:11 UTC (build 43, iPhone, 9 items, all on 2610.18683 "ProAS" and two reopened papers)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "More gross ness" ("[1]for each #1 do" after the abstract; "(?)" and "(??)" through the introduction) | Reader | A macro definition LaTeXML left as a paragraph (TeX parameter tokens never read in prose): gone, counted as an unsupported command. Citations LaTeXML could not resolve print as a bold "?": left out with their parentheses and counted in the closing note ("3 unresolved citations"). | Built; fragment test; build 44 and the browser |
| 2 | "Spacing fail around abstract" (a gap under "Abstract"; names on a second line read as affiliations) | Header | The abstract heading kept the browser's default 2.3 em bottom margin: headings now have their own. A second line of names with marks ("Heyuan Deng⁴ Fei Mi⁴,‡") was read as affiliations: lines after the first are more authors when they carry marks. | Built; fragment test; build 44 and the browser |
| 3 | "The highlight kind of works but it excludes parts. And if I click outside it, the highlight should go away" (a chat citation's passage highlight skipping equations) | Reader | The passage highlight was a CSS custom highlight, which WebKit does not paint over MathML and which outlived the jump. It is now a box over the whole passage, equations included, fading like a citation flash; a tap or key takes it away at once. | Built; build 44 |
| 4 | "So many question marks ??" | Reader | Row 1: unresolved citations. | Built; build 44 and the browser |
| 5 | "Weird white boxes ?" (a boxed ± in the bold table rows) | Tables | LaTeXML's math background colour on the ± (a `\colorbox`): the reader owns its colours now, so math colours and backgrounds are left out like the HTML's. | Built; fragment test; build 44 and the browser |
| 6 | "There is a weird gradient ??" (a tall table tinted after a citation jump) | Reader | The same passage highlight (row 3) over a whole table, under the bottom controls' fade. It fades in under two seconds now and clears on a tap. | Built; build 44 |
| 7 | "White box looks like a render fail" (Tables 11 and 12: a small white square) | Reader | A table drawn as a TikZ picture inside the figure was shown as a 0.65 em inline symbol. A picture on its own inside a figure is the figure's image; one beside words stays a legend symbol. | Built; fragment test; build 44 and the browser |
| 8 | "Fail" (MiniDog: "Showing the copy an earlier version prepared; preparing it again failed. This paper couldn't be prepared on this device.") · "There was a check does that not mean it's downloaded? When I clicked it said downloading… and then it gave me awkward message at top" (ScenePlacer) | Reader | A copy on this device now opens at once whichever app compiled it (the check means what it says); one compiled by an older app is prepared again behind the page, and an "updated copy is ready — Reload" bar offers the new one. A failure names its reason, including a network error ("Couldn't reach arXiv: …") instead of the generic sentence. | Built; build 44 |

## TestFlight, 2026-10-15 03:02–03:17 UTC (build 42, iPhone, 9 items) and the chat messages that followed

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "Still ugly please make it prettier" (Benchmarking Self-Supervised 3D…: seven long affiliations in one run) | Header | Affiliations and notes sit on their own lines under the names in a smaller face (`reader-affiliations`, `reader-notes`; arXiv CSS only, so the Mathpix sample's identity keeps). | Built; build 43 and the browser |
| 2 | "I didn't see Downloading step? It's stuck at 15%?" (two arXiv imports "Preparing 15%" for a minute) | Library rows | The server's stage for an arXiv paper is metadata only and the 15 % was a fixed number, not progress. Rows say "Preparing…" with a spinner during that stage; as soon as the paper appears, this device downloads and prepares it with real "Downloading… 37%" / "Preparing… 94%" in the row, so opening it afterwards is immediate. | Built; build 43 |
| 3 | "Don't see why three icons are needed? Either it's there (check is ok…) or the cloud icon in which case I need a button to download to device?" | Library rows | Two symbols: a check for a copy that opens at once (prepared, or a PDF), a cloud for one still to download. Tapping the cloud, or the row menu's "Download to this device", downloads and prepares it with progress in the row. | Built; build 43 |
| 4 | "It should include a reference to exact point in the paper where the text was referenced so agent response can be improved" | Chat from a selection | The question carries the passage's paragraph marker ("… [¶24]"), the paper's own numbering the answers already cite: the model starts from the exact place, the marker in the question links back to it, titles leave it out. Both surfaces. | Built; build 43 and the browser |
| 5 | "Fail" (Apertus 1.5: "This paper exceeds the device reader's preparation limits") | Reader, first open | The device path refused `image_total_limit`: 24 figures, fifteen of them pictures drawn at 2×, over 64 million pixels together — which the sweep never exercised because it converts the HTML only. Each paper's images now share a pixel budget (every image scaled to it; a raster the reader's own admission accepts within it is kept as it came, the same bytes on every device). A new headless-browser tool, `scripts/reader-device-compile.mjs`, runs the whole device path on a cached paper and found the next two refusals (`svg_fragment`, `svg_id`: a TikZ picture used a pattern LaTeXML defined once elsewhere in the page; the definitions travel with the picture now). Apertus: 9.1 MiB, 31 images. | Built; build 43 and the browser |
| 6 | "Fail" (PhysCodeGym: the old header still on build 42) · "Needs space after author section" (2610.10238: names and affiliations run together) | Reader | Two causes. A stored bundle's re-preparation fails silently and the old copy shows (arXiv busy, or a refusal): the page now says so with the reason and offers Try again. And 2610.10238's author block is set as a table (cells are the names, the next row the affiliations): read as such; marks are plain text, names unbolded. | Built; fragment tests; build 43 |
| 7 | "If I click on one with a checkmark it should take me the library entry for that item" (Feed) | Feed | The checkmark opens the paper; while this device prepares a just-added paper, the control shows its percent. | Built; build 43 |
| 8 | "weird line spacing between the author lines … this whole entry area needs to be thought through, it's really important" (2610.14075: a custom title page, no author block) | Header | The header is built from the catalog (title, names) and the title page's own lines fold into it: names with their marks when they are the catalog's, affiliation lines, the "Corresponding authors" note (e-mail out); the date and report-type lines go; a subtitle stays as the first paragraph. | Built; fragment test; build 43 |
| 9 | Chat: "If I am in a chat, and I click on a link back to the paper, I should see a 'Back to chat' option" | Reader | "Back to chat" beside "Back to where you were" after a citation opened the paper (not when the chat is beside the page). | Built; build 43 |
| 10 | Chat: "The flow from getting a paper from feed to actually reading it… I press Add… Preparing up to 15%… I have to MANually find it… nothing to indicate it was recently added and unread… another Downloading screen?" | Feed → Library → Paper | Rows 2, 3 and 7 together: the device prepares the paper right after the add with its progress in the Feed control and the Library row; a dot marks papers added in the last three days and not yet opened; the checkmark opens it; opening is immediate. | Built; build 43 |
| 12 | "I see \scriptsize" (2610.14075, Figure 1's caption: "\scriptsize①") | Reader | A size command LaTeXML left as plain text. Size and style commands in running text (`\scriptsize`, `\small`, `\bf`, `\centering`, …) are no words of the paper and are left out; the sweep's `macro_leak` check already flagged this class as a warning. | Built; fragment test; build 43 and the browser |
| 11 | Chat: "The chat needs a html tool… flow charts or other htmls… mermaid diagrams… an option for the users to disable these chat features" · "the agent has the ability to break figures into cropped sub sections… and explain each component" | Chat | Built (CHAT.md "Visual answers"): an HTML answer tool beside the Mermaid one — the server sanitizes the fragment to a finite vocabulary (structure, tables, inline SVG, inline CSS; no scripts, images or external resources) and relays it; the apps show it in a scriptless frame ("View visual"), the browser inline; a "Visual answers" setting (Settings › Chat; Chat defaults in the browser) turns both tools off and tells the model to answer in prose. Live on staging: a pipeline question answered with a 2.3 KB visual, a flow question with a Mermaid diagram. Figure crops remain a proposal (`docs/proposals/CHAT_TOOLS.md`): they need a consent for sending figures to the model. | Built; build 45 and the browser; crops proposed |

## Chat, 2026-10-15 (builds 39–40): "Authors list is still broken", "Second attempt to engage with the app", and the architecture concern

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "Authors list is still broken" (PRISM again, after the fix shipped) | Reader header | Not the compiler: the paper had been prepared on the device by the older build and the stored bundle was reopened as is; nothing invalidated it. The build now ships its compiler identity (`arxiv-reader-build.json`, written by the compiler build script), and a stored bundle whose manifest names another compiler is prepared again when opened (the stored copy still reads offline). Reading positions of re-prepared papers start over once. | Built; unit test; build 41 |
| 2 | "Second attempt to engage with the app" (Apertus 1.5: "This paper exceeds the device reader's current preparation limits") | Reader | The HTML is 2.6 MB against a 2 MiB source cap chosen before real technical reports were measured. The cap is 8 MiB on the compiler and both apps (the paper compiles in 149 ms to 863 blocks, 791 KB of reader HTML). | Built; build 41 and the browser |
| 3 | "Can you set up a test suite so you detect more of these issues proactively?" | Reader quality | `scripts/reader-sweep.mjs`: the newest papers in the categories the owner reads plus the staging library, compiled with the shipped compiler, checked for the header and structure invariants (title first, author block clean, abstract after the header, no date or punctuation lines, Contents present, markup leaks) and refusals. First run: 58 papers, 16 refused to compile — the real first-open failure rate — which drives the next item. | Built; run before every reader build (TESTING.md "Slow, reader sweep") |
| 4 | "when the failures are this common, it means we've added too much complexity… it might be time for a rethink of what the architecture is, what the components are, how quality is assured for each" · "maybe you could ask for an audit by a subagent" | Reader pipeline | Agreed. `docs/proposals/READER_ARCHITECTURE_RETHINK.md` names the components, their real contracts and a quality gate each; its first step (refusals become degradations with a ledger, the header from catalog metadata, the sweep as the gate, measured limits, versioned store) is being applied. An independent audit of the converter was requested from a subagent with the code and the sweep evidence; its findings are recorded alongside the proposal (its "Independent audit" section). | Proposal written; audit done; step 1 applied (build 42 and the browser) |
| 5 | "maybe you could ask for an audit by a subagent" | Reader pipeline | A read-only subagent reproduced every refusal on the 56 cached sweep sources and traced nine of fifteen to one figure branch. Everything it found was applied in the converter (fifteen fragment tests, `ARXIV_RENDERER_REVISION` 4): a paper without an `h1` is headed by the catalog title, the library's names head a paper with no author block, front matter reads first, publication notes under the title are left out, a top-level picture is a figure, graphics in a tabular are the figure's panels, a math or icon mark reads right, over-long blocks are excerpted. The same 58 papers: 0 refusals (16 before). | Done; build 42 and the browser |
| 6 | "Just one small note on the paper prep step let's simplify it. We only need Downloading… and Preparing… with a total percentage value" | Library rows and the opening paper, every surface | Two words and one percentage: "Downloading…" while the HTML and its figures download (to 80 %), "Preparing…" through the compile; server imports say the same two words (a download the server will retry reads "Downloading…"); no step names, times or details. | Built; build 42 and the browser |
| 7 | Screenshot, build 41, 19:42 PDT: "A Sovereign, Indic-First, Reasoning Model" (2610.15371) — "Couldn't open this paper. This version's HTML couldn't be prepared completely." | Reader, first open | The paper's LaTeXML page has no `h1` (a custom title page: a rule, a company logo, the title as a bold paragraph, "Core Team:" lines), so build 41's compiler refused it (`arxiv_title`). With the catalog title and the library's names passed to both compiler calls it opens: title, authors, then the title page's own lines; the logo is left out and counted, the rule is no block. The message itself was the deeper problem: iOS collapsed every refusal to one sentence and logged nothing, so neither the owner nor the log could say why. The app now carries the compiler's reason code, says which part refused in the same words as the browser (equation, figure, references, formatting, limits, source) and logs the code; a backend test keeps the two category tables complete and equal. | Built (fragment test on the title-page shape; native and backend tests); build 42 and the browser |

## TestFlight screenshot, 2026-10-15 (build 39): Urbex's header (abstract before the title, "[ [", a date line)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | (screenshot) arXiv 2610.18356: the abstract rendered above the title, the authors ended in a stray "[ [" line, and "October 13, 2026" stood alone under the paper line | Reader header | The paper uses a custom report template whose macros LaTeXML does not know, so its whole title page — logo path, running title, date, author list, affiliations ("1]Wuhan University"), contribution notes ("[†]Project leader") and the abstract itself — arrived as one error-marked paragraph *before* the title, and the two affiliation contacts were literally "[". The compiler now keeps each LaTeXML error marker as an empty span that names its macro and, for such a paragraph before the title, reads it by macro: the abstract segment becomes the Abstract heading and paragraph after the authors (where the paper's own would be), affiliation lines and contribution notes fold into the author block with their marks, the plumbing is left out with the macros (still counted in the closing note). Punctuation-only affiliations are dropped, and the `ltx_dates` line is left out (the paper line already says the year and revision). | Built (`8d481e9`); compiler test; Pages `43aef05a`; TestFlight build 40 iOS VALID, Mac uploaded. Owner acceptance open |

## Chat screenshot, 2026-10-15 (build 39): "AI answers are paused right now"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "It's all fine with me just push ahead please and get me something I can use" (screenshot: the paper chat refused with "AI answers are paused right now. Your papers and saved chats still work.") | Chat | October's platform provider cap: $23.20 of $25 spent, so a Sonnet answer's hold no longer fit (`platform_budget_exhausted`). On the owner's word the limit was raised: $30 immediately (the schema ceiling), then migration 068 lifts the ceiling to $50 and October is set to $40 — inside the approved $100/month budget, recorded in SPENDING_CONTROLS.md. A live chat proof after the raise answered in full (27 credits). | Resolved; "Try again" works |

## Chat report, 2026-10-15 (build 38): imports stuck at "Finding", podcast lifecycle, Contents for older PDFs, "do I have this paper on this device?"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "The import of PDFs appears to be broken?" (screenshot: three arXiv imports at "Finding 15% · Under a minute", one "Waiting") | Library, imports added 2026-10-15 ~00:28 UTC | Every import failed at the metadata stage with `source_unavailable` and was retried on backoff (failures 1→5). Not the network and not the evening's worker deploy: the worker run locally failed the same way, and the new failure diagnostics named it: the OAI-PMH `GetRecord` request timed out (60 s) at `oaipmh.arxiv.org`, while the Atom API answered. The worker built the identifier with `URLSearchParams`, which percent-encodes the colons (`oai%3AarXiv.org%3A2610.15166`); arXiv's OAI server stopped answering that form today and answers the literal form in 0.25 s. The URL is now built with literal colons (`arxivURLs`); the metadata stage's failure log carries the endpoint and status or failure name from now on. The row copy already turns into "Waiting for arXiv · retrying" and "Taking longer than usual" after the first failures; "Under a minute" stays only for the first attempt. | Fixed; worker revision 00041 and `paper-worker` deployed 2026-10-15 ~00:56 UTC; all three imports completed on their next retry (00:57, 00:59 and 01:05 UTC) |
| 2 | "How does it work when you create a podcast? Is it handled asynchronously… Is the tracking managed even if you closed the app?" | Listen | Yes on both. Start reserves the credits and queues a job on the server; the pipeline worker writes, checks, voices and publishes it (one to three minutes) whether or not the app is open. The app polls while the Listen sheet is open; closing the app or the sheet changes nothing on the server. Reopening Listen on that paper finds the running job (the paper lookup returns it) and resumes progress; a finished episode is simply there. The browser also keeps the request identity so a Start whose reply was lost is reconciled. What is missing: a place that lists *your* episodes being made and ready across papers, and a notice when one finishes — proposed below. | Answered; "Your episodes" list and a completion notice proposed (not built) |
| 3 | "Table of contents still not rendering for me for older PDFs" | Paper read as a PDF kept on this device | The Contents sheet showed the HTML reader's headings, which a PDF never has, so it was empty (or stale). The PDF viewer now has its own Contents from the PDF's outline (bookmarks), tapping an entry goes to its page; a PDF without an outline says so and why. Papers with a converted server copy keep their Contents (every legacy bundle checked has 12–60 headings). | Built; TestFlight build 39 iOS and Mac VALID. Owner acceptance open |
| 5 | "Is the worker making calls to arXiv? I thought it was the device to avoid terms of service issues?" | Import pipeline | Both are true, for different things. The **device** fetches every paper's content (the official HTML revision, and PDFs) and is the only place that does; the server never requests a PDF or an HTML page (`fetchArxiv` refuses any URL that is not one of the two metadata endpoints). The **server** asks arXiv's two public metadata APIs — the Atom API and OAI-PMH — for the catalog record (title, authors, abstract, categories, version dates) and the license evidence that shared episodes and catalog approvals need; both APIs exist for programmatic metadata access (arXiv metadata is CC0), and the worker paces them (a global gate, two reserved slots per import, Retry-After honored). The terms concern that drove the cutover was bulk content retrieval and redistribution, which the design avoids. | Answered; the boundary is written in HTML_FIRST_READER.md "Acquisition and availability" and PIPELINE_RELIABILITY.md |
| 4 | "synced devices might have different PDFs stored right, should we make it more obvious whether you do or do not have a pdf on a device? … we allow you to do things that require a paper and we haven't even told the user that there is no paper" | Library rows; Chat, Study, Listen | Yes. One model, written down (HTML_FIRST_READER.md "Paper availability on a device"): on this device (prepared HTML; reads offline; chat, Study and Listen have its text), PDF on this device (reads as a PDF; no structured text yet), not on this device yet (opens from arXiv when online), no readable copy. Library rows now show it as a small symbol before the byline (VoiceOver and Mac tooltip say the words); the browser says "Opens from arXiv; prepared in this browser when opened" or "Reads from the server's converted copy". Listen's refusal for a paper not prepared here says "Open this paper first so its text is ready on this device", and for a PDF that it has no structured text. | Built; TestFlight build 39 and Pages `ff4f6b0c`. Owner acceptance open |

## TestFlight screenshots, 2026-10-14 (builds 33–36; submitted 15:43, 17:46–17:47 and 23:37–23:38 UTC)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "Poor layout table contents" (15:43 UTC, PhysCodeGym 2610.17288) · "Still a gross author presentation" (23:37 UTC, PRISM 2610.14704) | Reader header of HTML papers | LaTeXML author blocks come in several shapes the first author-block renderer (same night) did not cover: one "Affiliation:" contact per author (the label was printed and the affiliations ran together with the names), e-mail inside an affiliation, a project page link glued to an institution, several "thanks:" daggers per author. The compiler now drops contact labels and e-mail, numbers per-author affiliations in order ("Chenghao Yue¹, Peiyan Li¹, Hao Wang² … ¹Tsinghua University · ²Dalian University of Technology"), puts a project page on its own line and each dagger note on its own line; verified on all four reported papers plus DPO (`.artifacts/back-repro/authors-check.mjs`). | Built 2026-10-14 night (commit `c2ad885`); compiler tests 17/17, browser compiler journey; browser Pages `fa19e107`; TestFlight build 37 iOS and Mac VALID (and 38). Owner acceptance open |
| 2 | "What is this Tram business and where is the correct info" (LoongSage 2610.16352: the header read "Team") | Reader header | The author is a team logo image followed by " Team"; the graphic is left out of running text, so only "Team" remained. Both apps now pass the library's author names into the device compiler, which uses them when a name was a graphic or no name was found ("LoongSage Team"); the same names on every device of a library give the same bundle. | Built (`c2ad885`); compiler test; Pages `fa19e107`, TestFlight 37 and 38. Owner acceptance open |
| 3 | "What's going on here?" on "Listening needs this paper in your synced library." and "This is dysfunctional on many levels: we should have stopped storing PDFs at all on the server is that not the case? And the message is also very off putting…" on "Episodes are made from a server copy of the paper…" | Listen on a paper read on this device | The server keeps no PDFs; it still has the text it converted for older papers, which is all Listen could use. The wording implied stored PDFs and gave no way forward. Interim copy: "Episodes can't be made for this paper yet. Listening still works from the text the server converted for older papers; making episodes from the paper on this device is being built." / "…it isn't in your synced library. Add it to your library, then try again." The real fix — private episodes written from the paper's own text on this device — is designed in PAPER_PODCASTS.md ("Episodes from the paper on this device") and built next (migration 066). | Copy in build 37; device-text episodes built and deployed the same night (migrations 066–067, `podcast` function, worker 00040, Pages `e7764deb`, both clients; PAPER_PODCASTS.md "Episodes from the paper on this device"); live proof on staging ready in 85 s for 31 credits; TestFlight **build 38** iOS and Mac VALID. Owner acceptance open |
| 4 | "Refresh episodes what does that mean ??" | Listen filter's ⋯ menu | Pull-to-refresh already reloads the catalog; the menu row now reads "Check for new episodes". | In builds 37 and 38 |
| 5 | "The scrolling experience is poor both when new text is coming and when the text is done" (15:36 UTC, build 31) | Chat transcript | "When new text is coming": 453d6ed slowed the flush cadence for long answers and the night's end-only following stops the snap-back (row 3 of the chat reports below). "When the text is done": the finished answer is re-rendered once (Markdown and math) and the transcript keeps the reader's place through it (anchors) when they are not at the end; no further change identified without a screen recording — the owner's "Report this screen" with a recording would pin it. | Partly addressed (builds 32, 36); recording requested |
| 6 | "The figure is tiny" · "The back to where you were feature is gone" (15:34 UTC, build 31) | Reader | Handled in 453d6ed (build 32) and the night's Back hardening (build 36); see the build-31 section and the chat reports below. | Builds 32 and 36 |

## Chat reports, 2026-10-14 (night): the authors list, "Back to where you were", scrolling while an answer streams

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "make sure that the authors list is presented nicely on all surfaces" | Reader header of HTML papers; library rows and columns, feed rows and cards, podcast cards and player, pending imports (native and browser) | The arXiv HTML compiler emitted LaTeXML's author block as it came: every affiliation mark twice with a "footnotemark:" label and its tag, "thanks:" notes inline, e-mail addresses. It now renders each name once with its marks ("Rafael Rafailov<sup>2,†</sup>, Archit Sharma<sup>1,2</sup>"), then the affiliations ("<sup>2</sup>Stanford University · <sup>3</sup>CZ Biohub") and the notes ("<sup>†</sup> Equal contribution…") on their own lines; links to those notes still resolve (verified on the DPO paper, arXiv 2305.18290, device-compiled). Rows and columns on both surfaces use one rule (one author: the full name; up to three family names; then "+N"; native had shown two names, the browser three surnames split on the last word), cards and the player's "Paper by" line show full names up to six then "+N" (native had listed twelve), bylines read "Vaswani et al." on both (the browser had shown the full first name). The native paper list and pending-import rows no longer print the raw joined string. | Built 2026-10-14 night; compiler tests 15/15, browser units, native `LibraryMetadataTests`; Browser Pages `943836e8` live 2026-10-14 16:29 PDT; TestFlight **build 36**: iOS VALID (uploaded 16:31 PDT), Mac uploaded 16:34 PDT (processing when written). Owner acceptance open. |
| 2 | "the 'Back to where you were' … no longer is there (all surfaces)" | Reader, after a citation, figure or section link | Not reproduced: the shared bridge still offers Back for every in-page link. New evidence: an iPhone Simulator journey on the HTML fixture (`ReaderNavigationTests/testHTMLPaperInPageLinksOfferBack`: the "[1]" citation and the "Figure 1" link both offer Back, Back returns) passes; the browser journey passes with the chat pane open (Back in view in the toolbar); a headless-WebKit harness on the real DPO paper (device-compiled) jumps with Back for bibliography, figure and section links by mouse and by touch. Two weaknesses that could hide Back on a real device were removed: the jump's landing place was fixed after 1.5 s even mid-scroll, so a long smooth scroll on a slow device then counted as "two screens away" and ended Back at once; and programmatic scrolls (a restore, a refit) could end it. Now the landing waits for the page to stop (up to 6 s), and Back outlives only the reader's own wheel, touch or key scrolling. If build 36 still shows no Back, the report needed is the paper (arXiv id) and the link tapped. | Built 2026-10-14 night; native journey, browser journey and harness as described; Browser Pages `943836e8` live 2026-10-14 16:29 PDT; TestFlight **build 36**: iOS VALID (uploaded 16:31 PDT), Mac uploaded 16:34 PDT (processing when written). Owner acceptance open. |
| 3 | "when the text is coming out (streaming) in chat, and I try to scroll up … it won't let me stay where I am (all surfaces)" | Chat transcript, both surfaces | Both clients re-followed the latest text whenever the reader was within 80 px/pt of the end, so a small scroll up (a trackpad tick, a short swipe) was snapped back by the next flush. The reader's own scroll now follows only at the end itself (2 px/pt): any scroll away stays put until they return to the end or tap "Latest message" / "Latest", and the transcript's own scrolls (following, "Latest") are never read as the reader's. | Built 2026-10-14 night; browser unit `chat-follow`, browser chat journeys, native `WorkflowJourneyTests/testChatKeepsLatestVisibleAsComposerGrowsAndKeyboardDismisses`; Browser Pages `943836e8` live 2026-10-14 16:29 PDT; TestFlight **build 36** (iOS VALID 16:31 PDT, Mac uploaded 16:34 PDT). Owner acceptance open. |

## Chat report, 2026-10-14 (evening): the podcast starts with "So the motivation is computational, but…"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "thats not a sane start to a podcast" | The owner's first DeepSeek episode (job `4ce016b9`) | The checker had removed seven of 28 turns: four for Markdown and inline-math wrappers in the spoken text (the voices cannot read them) and three as unanswered questions, among them the opening turn, so the episode began on the reply. Three fixes in the worker: readable markup is stripped and the turn kept; the writer must open with a plain welcome that names the paper and never ends on a question, and close the same way; a check that passes but leaves the opener removed or a reply orphaned runs the repair pass, and refuses the episode where no repair call exists. The word band was then widened once more (80%–125% of the writer's range) after a 930-word draft failed a 920 ceiling by ten words. | Deployed (worker 00039); verified on seed `8dd7ac8f` (release `9e90fb77`, 5 min 55 s, 24 turns, none removed): opens "Welcome to Gradstep. Today we are looking at…" |

## Chat request, 2026-10-14 (evening): "expose an option when creating a podcast to use anthropic or sonnet"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | A writer choice at podcast creation: Anthropic (Sonnet) or DeepSeek | Listen sheet (native), podcast dialog (browser) | Migration 065: a length may be offered under more than one allowed profile version, one per writer; `podcast_lengths()` lists each length's writers (default first, each with its own maximum, estimate and consent version); the quote takes a `writer` and resolves the matching version, so the providers and consent named in the quote follow the choice. Native: a "Written by" segmented control above the lengths (DeepSeek V4 Pro · lower cost, scripts vary more / Claude Sonnet 5.5 · steadier scripts), the lengths' maxima follow it and the length is quoted again. Browser: the same choice as radio buttons before the estimate. The policy offers both writers for all four lengths (revision 9; DeepSeek stays the default). | Server and browser live 2026-10-14 ~19:40 UTC (migration 065, podcast function, Pages `c4737d77`); native in TestFlight build 35 |

## Chat request, 2026-10-14 (afternoon): "Lets setup deep seek, prove it works with podcasts"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Set up DeepSeek and prove it with podcasts; hopefully more cost-effective | Podcast script writing (draft, review, repair) | A DeepSeek adapter beside the Anthropic one, chosen by the profile spec; migration 063 (provider, consent v2, version-4 profiles on DeepSeek V4 Pro at peak list prices); the worker and functions deployed; the browser quote handling unpinned. Script-stage ceilings fall from about $0.75 to about $0.40 per 5-minute episode; the maxima shown to readers fall from 180/200/360/610 to 140/150/280/500 credits. | Deployed 2026-10-14 (worker 00037, policy revision 8 on profiles v5, Pages `9b227fa2`); proven on the fourth seed `fe9e26d4` (5 min 35 s episode, release `c7a9a3e4` pending seed review) at $0.111 of script cost against about $0.35 on Sonnet; three earlier seeds failed and each taught a fix (trim repair, word-range tolerance, larger output caps with compact JSON) |

## Chat report, 2026-10-14 (afternoon): "I was not able to create a podcast at all"

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Could not create a podcast | Listen, any paper added since the HTML-first cutover | Episodes are written from the server's converted (Mathpix) text, found through the legacy library item, its render artifact and its OCR run. Papers prepared on the device have none of those rows, so the app finds no podcast item and said "Listening needs this paper in your synced library", which was misleading. Staging confirms nothing reached the quote in 36 hours. Copy now says episodes are made from a server copy that device-read papers don't have yet. Making episodes from the device's numbered text is a design change (quote, pin and worker), written up before building. | Copy fixed in the working tree; the device-text design is open |
| 2 | Same, for papers that were in the library before the cutover | Generation | The last three jobs on staging (2026-10-09, two customer, one seed) all failed `script_evidence_rejected`: the reviewer accepted the script, the checker removed turns whose numbers were not in the evidence, and the rest fell under the length's word floor. Nothing was charged; about $0.35 of platform loss each. A bounded second draft (a `podcast_script_repair` route in profile v3) rewrites the removed turns from quoted evidence; migration 062 and the podcast functions are deployed and the policy points at the v3 profiles (maxima 180/200/360/610 credits). | Deployed 2026-10-14 18:11 UTC; a live replay waits for the owner (October's seed allowance has $0.58 of $3 left, which fits no ceiling) or for the owner to try a pre-cutover paper |

## Build 31, 2026-10-14 (iPhone, 3 items, TestFlight screenshots 15:34–15:36 UTC)

Screenshots: `.artifacts/feedback/build31/` (private, not committed). All three on the PhysCodeGym paper (2610.17288).

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "The figure is tiny" | Reader, Figure 1 | LaTeXML wraps a centred graphic as `figure > p > span > img`; the adapter treated any graphic inside a figure paragraph as a legend symbol (`reader-inline-image`, 0.65 em tall). A paragraph that only wraps the graphic is now the figure's full-size image; a caption-only figure after an unwrapped graphic reads as that figure's caption. Regression test in `tests/backend/arxiv-html.test.ts`. | Shipped: Pages `7bbf4a45` and TestFlight build 33 (VALID for iOS and Mac at 08:57 PDT) |
| 2 | "The back to where you were feature is gone" | Reader, after following "[55]" to the bibliography | The reader bridge offered Back only for citations it parsed itself (Mathpix-era text marks); the arXiv HTML reader's own `<a href="#…">` links (citations, "Fig. 1", "Cited by: §1") navigated natively with no Back. The bridge now jumps and offers Back for every in-page link on both surfaces (browser journey asserts it). | Same |
| 3 | "The scrolling experience is poor both when new text is coming and when the text is done" | Chat, streaming answer | Each flush re-renders the whole answer so far (Markdown and math) every 50 ms; long answers churn the row and the scroll pin. Flushes now stretch from 50 ms to 400 ms as the answer grows. Not verified on a device: the remaining jump when the sealed answer, footer and follow-up chips replace the streaming row needs your eye on build 33; a tail-only streaming renderer is the next step if it still feels poor. | Partly built, in build 33; the end-of-answer jump needs the owner's eye on a device |

## Chat report, 2026-10-14 (build 31): library papers and new papers not opening

Owner (chat, not TestFlight): "papers that were already in my library don't work. Probably we need a better framing
of papers that are in library that have pdf downloaded vs not. Also I still see quite a few failures even for new
papers 'couldn't open this paper'."

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | Papers already in the library don't work | Reader, legacy items (42 visible, all with a server bundle; the server said every one was available) | The device opened them only through the server bundle path, which could end silently on "Paper download needed" with no action. Legacy arXiv items now open through the on-device HTML reader like every other arXiv paper; the server bundle is the fallback; every refusal has a reason and an action. | Built 2026-10-14, native and browser; ships in build 32 and the next Pages deploy |
| 2 | Better framing of what is downloaded | Library rows and table | Rows say "Opens from arXiv" until a paper is prepared on this device, "Unavailable offline" for a blocked copy, "PDF on this device" for a PDF; "Reader unavailable" only for non-arXiv items without a server bundle | Same |
| 3 | "Couldn't open this paper" on new papers | Reader, nine papers added 2026-10-13/14 | Replayed offline: five of nine refused (conversion markers, inline graphics, TikZ pictures). The compiler now tolerates all three and notes what it left out; nine of nine compile ([HTML_FIRST_READER.md](architecture/HTML_FIRST_READER.md#compiler-tolerance-and-legacy-items--2026-10-14-owner-report-quite-a-few-couldnt-open-this-paper)) | Same; browser replay evidence in IMPLEMENTATION_STATUS.md |

## Purchase credits, 2026-10-07 (TestFlight build 13; observed Sandbox path repaired)

Report `APgSDbWf0gMbTamRckWVdHs`, submitted 08:09 PDT, says:
“We should never be in a situation where credits were added but they can’t use them”.
The screenshot shows **17 credits available** and the purchase alert:
“Your purchase went through, but we couldn’t add the credits yet. The app will try again automatically.”
The owner reported the same failed-credit experience again during the Codex takeover.

**Resolved on staging for the observed Sandbox credit-pack purchases; production remains unverified.** This is TestFlight feedback, not an in-app
support report. The screenshot was downloaded and inspected; its private local copy is
`.artifacts/feedback/credits-APgSDbWf0gMbTamRckWVdHs.png`. The generic alert does not identify
which verification/recording step failed. Eight `invalid` server outcomes surround that attempt;
staging had recorded no App Store transactions. A separately reviewed diagnostic-only deployment
(`store-sync` v36,17:50 PDT) proved the hosted runtime lacks certificate operations required by
Apple's library. [Evidence and repair boundary](reviews/PURCHASE_DIAGNOSTICS_HOTFIX_20261007.md).
The private Node verifier and migrations 033–038 were subsequently deployed with signature/revocation checks intact.
Read-only takeover verification on 2026-10-08 05:14 UTC found three Sandbox credit-pack transactions with actual
grants totaling 1,000 credits: 400 + 400 + 200. The last is a partial grant under the 1,000-credit monthly Sandbox
allowance, not a verification failure. Replayed reports returned `already_recorded`; six app verifier attempts
succeeded. Evidence: `.artifacts/takeover-20261008/{purchase_grants,purchase_observations,sandbox_decisions}.json`.
Build 19 adds actual-granted-credit and Sandbox allowance wording; a real tester review of that new copy remains.
Receipt recording and credits granted remain distinct states; this evidence does not verify production subscriptions, renewals or refunds.

The owner reproduced the same symptom after those three grants. Read-only staging ledger evidence on 2026-10-09 shows
the later Sandbox pack and Standard subscription receipts were recorded, but each received **0 credits because the
account's October Sandbox allowance was already exhausted**; no receipt was lost. Migration `056` and the deployed
`store-sync` now add the finite `sandbox_monthly_cap` reason to that final response, so the purchase sheet explains
the TestFlight limit and does not imply that a paid transaction disappeared. The allowance remains bounded;
production purchases have no Sandbox cap once the Production verification path is enabled. Build 26 is `VALID` for
iOS and Mac and also reports the reason when Restore Purchases returns an already-recorded receipt. A bounded owner-
only 400-credit tester top-up was recorded on staging under request
`cd4aac8a-3144-481f-abbe-b7844c0b7030` (490 available / 0 held after the grant); it does not change the Sandbox cap
or production purchase rules.

## Build 14, 2026-10-07 (iPhone, 11 items)

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "What happened here" | Reader: the paper's own table of contents renders as one run-on paragraph ("Contents 1 Introduction ..... 1 2 …") | Detect dot-leader contents blocks and show them as a list, one entry per line | In build 15 (2026-10-07). Done after build 14 (bridge, no re-render): one entry per line, indented by depth, pages right-aligned and muted; entries that match a heading or run-in head jump there with Back (DLV: 35 of 40). Only the 5 real lists in 48 conversions change; verified in the iPhone Simulator, light and dark ([details](architecture/READER_RENDERER.md#the-papers-own-contents)) |
| 2 | "The reference isn't working" | Reader: `[Gelfond and Lifschitz 1991]`, `[Lobo et al. 1992; Eiter et al. 1997b]` (bracketed, no comma before the year) | Check the new author–year linking against this paper; add the form if missing | In build 15 (2026-10-07). Done after build 14: build 14 predates the author–year links (3 of 209 in this paper linked); the current bridge links 210 of 210, no wrong link. Added small-capital spellings ("AND", "ET AL."); `[Cadoli et al. 1997]` fits two entries and stays plain. Verified in the iPhone Simulator |
| 3 | "Formulas should be selectable in chats the same way as papers … copy at least" | Chat answers: formulas are images | Long-press/right-click on a formula: Copy LaTeX, Copy as text, and the selection actions | In build 15 (2026-10-07) |
| 4 | "Ask a question is bad language, you can just have chat" | Chat composer placeholder | Placeholder "Chat" | Done (merged from floating chrome): placeholder "Chat" |
| 5 | "Space below chat box not well used … the paper vs general option needs to be in a menu … can't take away screen real estate for chatting" | Chat screen: the Paper chat / General chat segmented row; gap under the composer | Move the switch into the chat title menu; tighten the composer to the tab bar | Done (merged from floating chrome): the switch is the chat title's menu (subtitle shows the paper or "General chat"); message box 10 pt above the floating tab bar, the conversation under both |
| 6 | "The icon choice is bad it looks like a refresh icon, it probably needs to have lines in it" | Chat: the All chats button (clock-arrow) | A list icon with lines | Done (merged from floating chrome): a list icon (bullets and lines, the first bullet amber) for All chats in the top bar and menus |
| 7 | "A really good table view should be the default, sort by recently, added, length, paper or general, topics" | All chats | Table landed after build 14 (sort by last used / started / messages / paper, filter paper/general); topics come with tags. Also: chat titles show prompt prefixes and raw LaTeX ("Explain in plain terms…: \[\begin{equation*}") → shown as "Explain · Attention(Q, K, V)…", "Add paper · [3] T. D. Lee…" in All chats and the chat title (display only) | Titles in build 15; configurable Topics, Kind and Answer length columns plus horizontal scrolling in build 19 |
| 8 | "The account option tells me nothing, sync? Sign out and delete … should be hidden away? What does appearance mean to the user?" | Settings | Account row opens an Account page (email, sign-in methods, sync state in words, Sign out, Delete account); "Appearance" becomes "Theme: Light / Dark / Match device" | In build 15 (2026-10-07); Sync now moved to the Account page |
| 9 | "This doesn't look like it should be there, seems cool" | Settings → Acknowledgements | Move under an About page with version and privacy | In build 15 (2026-10-07); "About Gradstep", last row, with "readable versions of papers" wording |
| 10 | "Trying to select some chat text to reference it … it just says copy" | Chat answers: text selection offers only Copy | Selection in answers offers Ask about this (quotes it into the composer), Explain, Define, Copy | In build 15 (2026-10-07) |
| 11 | "Why is it Answer: … seems not needed" | Chat answers start with a bold "Answer:" label | Tell the model not to label the answer; strip a leading "Answer:" label on display | Display cleanup in build 15; the chat function/model instruction was subsequently deployed |

Also seen in the screenshots: `**$n = 0$:**` shows literal asterisks (bold around math isn't parsed) — chat
renderer fix, with #3/#10.

## Build 15, 2026-10-07 (handoff follow-up)

| Owner feedback | Plan | Status |
|---|---|---|
| Offline library save fails on every launch, and downloads stop until relaunch | Version the decoded cache fields; repair only display metadata while preserving availability history | Shipped in build 16: format 3 and retained quarantine/identity checks; 211 Core tests, 321 iOS unit tests (5 opt-in skips), both encrypted relaunch journeys, and 298 Catalyst unit tests (4 opt-in skips) pass. See [Native offline bundles](architecture/NATIVE_OFFLINE_BUNDLES.md#build-14--15-cache-upgrade-2026-10-07-local-review) |
| Topic tags feel generic | Review feed-chip priority and tag vocabulary/prompt; estimate any re-tagging cost before running it | Pending; no paid re-tagging in this fix |
| Chat top is too cluttered | Recheck main's chat title-menu change on the current build before proposing another layout change | Pending owner-current-build comparison |
| More All chats columns / horizontal scrolling | Coordinate with the chat-quality workstream and its existing table changes | In build 19: chooser, pinned title/Last used, horizontal scrolling and retained per-device choices |
| Model / effort selection | Prepare UX and cost proposal before changing provider routing or prices | [Economics/profile proposal](research/PRICING_RECOMMENDATION_20261008.md) merged; no live model, allowance or price change |

## Build 16, 2026-10-07 evening (iPhone, 10 items)

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "If I have credits now after adding new credits, ones should just start downloading if they were explicitly added before" | Library rows stuck on "Needs credits" | When credits arrive (purchase, restore, grant), resume the account's imports waiting on credits automatically, oldest first, within balance | On staging 2026-10-08 (migration 040 + worker): a sweep before each claim and a wakeup when a balance grows |
| 2 | "Recent articles should be shown first" | Library search › arXiv scope | Order arXiv results newest first (keep relevance as a tie-breaker or an option) | In build 19: Newest is the default; Relevance remains available |
| 3 | "So many criteria we could be adding as columns … choose which columns to show and also allow horizontal scrolling" | All chats table (and library table) | Column chooser + horizontal scrolling with the title column pinned | In build 19 across Library, Feed and All chats; chosen columns remain reachable, with per-device settings |
| 4 | "Make it more clear that we have the option to copy and reference in the chat box. When you click on equations in the paper itself we should see the same type of pop options" | Chat text/formula menu; paper equations | Same native menu for paper equations; clearer "Ask about this" | In build 19: paper equation/text edit menus and Quote in Chat wording; current selection is captured at action time |
| 5 | "The options are at the bottom, that's awkward; use the regular menu with Copy … with the extra options, make the options clear, 'Explain in Chat'" | Paper selection bar | Replace the bottom selection bar with the system edit menu: Copy + Explain in Chat / Why it matters / Related / Add paper | In build 19; equation menu dismissal clears only the matching selection |
| 6 | "Little options in the bottom right that make the text a little bigger and smaller" | Feed / reader | Small A− / A+ controls | In build 19 for Feed and reader; expanded-abstract-specific feedback below remains separate |
| 7 | "As a PDF is downloading, very briefly something appears for 5 ms right below Unread … the text flashes and all items move" | Library during a download | Remove the transient row/banner that shifts the list | In build 19: delayed overlay for background updates, preserving table geometry |
| 8 | "Is text streamed as it comes? It's too long before text starts coming" | Chat time-to-first-text (Related with web search) | Measure; show progress immediately; reduce latency before first token | Server part on staging 2026-10-08 (chat function): policy lookup overlaps the body read; action instructions after the paper's cache breakpoint; search results without citations so the prompt cache survives the search round |
| 9 | "Please remove Open and just put arXiv and it can link out" | Papers in this answer | Replace Open with the arXiv ID as a link; keep Add to library | In build 19; separate Library and website destinations follow in build 20 (see below) |
| 10 | "Ingestion failure" (arXiv 2207.00729 at "Finding 99% · Taking longer than usual") | Import metadata | Completed after 7 min: arXiv rate-limited the metadata lookup (`rate_limited`, backoff). Add a metadata fallback when arXiv throttles; don't show 99% while waiting | On staging 2026-10-08: arXivRaw (OAI-PMH) fallback when the Atom API throttles; a throttled source shows "waiting", not 99 % (migration 040 + worker) |

## Build 17, 2026-10-08 (iPhone, 3 items)

| # | Owner said | Where | Cause / plan | Status |
|---|---|---|---|---|
| 1 | "The Add is all greyed out?" | Feed Add buttons (also Retry, tags, archive) | Regression: when uploads went live (039, upload policy on) the app adopted the full-v5 library, and library writes were deliberately disabled in v5 until an epoch-checked write path existed. Fix: v5 command RPCs that check the dataset epoch in the same transaction (migration 042) and the app sending them; needs a new build. The disabled capsule is also too similar to the enabled one in dark mode | 042 applied and hosted zero-credit command journey passed; build 19 carries the native fix and darker enabled Add styling. iPhone/iPad Feed Add journeys pass; build 18 remains affected |
| 2 | "I still have these stray items that weren't properly ingested … self cleaning or fixing but never just sitting there" | Library: "arXiv 2610.07426 · Details unavailable · Retry", "Needs credits" rows, Failed 5 | Needs-credits rows now resume by themselves (040). Next: a server sweep that re-attempts transient failures with backoff and requeues stale claims; permanent failures show a plain reason and one action (migration 041). Retry itself was blocked by #1 | 040 and 041 on staging (see below) |
| 3 | "Table still sucks why are they're so few options" | Feed table (Title, Published, Add on phone) | Column chooser (topic, authors, updated, arXiv ID, abstract, in library, relevance), horizontal scroll with pinned title, more sorts and filters, as for the library and chats tables | In build 19: chooser, pinned title/Add, horizontal scrolling, additional supported fields, and Hide papers in my library. Expanded-title/abstract feedback below is not covered by this claim |

Also requested with this batch: a personalized feed ("relevant to a users interests … kept up to date and
changing but have cost under control"). Design and the reviewed zero-paid-API implementation are merged. Migration 043 is **applied with serving and refresh off**,
with For You as default and server-visible metadata use awaiting the owner's answer. No paid ranking is enabled.
[Feed plan](architecture/PERSONALIZED_FEED.md).

## Build 18, new screenshot feedback reviewed 2026-10-08 UTC

Root downloaded and inspected the five TestFlight screenshots. Metadata:
`.artifacts/takeover-20261008/latest-owner-feedback.json`; private local images:
`.artifacts/feedback/build18/<report-id>.png`. These reports arrived from build 18; distinguish a fix already
in 19 from the follow-up work started afterward.

| Report | Owner feedback / observed issue | Status and next action |
|---|---|---|
| `AGd2CKOBGtQ2_DixxpXTxxg` | “No if there’s room. Find a way to make horizontal scrolling a good UX pls” | Covered by build 19's chosen-column horizontal scrolling and pinned columns; owner acceptance remains. |
| `ALdL2H9qgXauIAihHJQz8J8` | Expanded Feed row should show the entire title and abstract, with abstract text-size control | In build 20: full expanded table title/abstract, A−/A+ retained, list expansion also available; long ending verified in light/dark and accessibility XL. |
| `AAWbg6g4dUfzp4mwU1x5u14` | “It looks like this is a bad UX please fix”; screenshot shows truncated expanded abstract | In build 20 + discover v78. The server's 700-character preview was the root cause; new clients opt into a bounded full abstract, preserve mathematical Unicode and label any actual excerpt. Hosted full source/Feed smoke passes. |
| `ABHWnLf34Hf5ty2J-F3Blv4` | Reference popover repeats the visible bibliography text; buttons/options are liked | In build 20: reference title and existing actions retained, duplicate body removed. Reference → actions → Copy → Back journey passes. |
| `AH_QWMX10xPbqz3-10h1WGk` | Ingested-paper links need explicit Library and arXiv website destinations; “Open” is vague | In build 20: visibly labeled Library button beside the external identifier link. Opens the current saved paper or pending import, including wide layout, and preserves the previous chat draft/history; model and UI regressions pass. |

## Build 21, 2026-10-08 (iPhone, 7 items) and today's goals

Screenshots: `.artifacts/feedback/2026-10-08T11-*.png`, `2026-10-08T13-19-34-487Z-0.png` (private, not committed).
Owner's goals for 2026-10-08, verbatim: "respond to new feedback, and build the notebook LM podcasts feature
please. One more thing, chats should have the abiltity to customize the length and effort nad model right there
in the chat in a cleer UX".

| # | Owner said | Where | Plan | Status |
|---|---|---|---|---|
| 1 | "Each chat should have a labeled [title] on the topic of the chat in the same way that chat GPT does … embedded everywhere in the app" | All chats (titles like "Explain · L_task(θ) = -…") | A short topic title generated with the first answer, stored in the encrypted history and shown everywhere; renamable | Merged to main; native and browser journeys cover generated/displayed titles and encrypted history. Included in the current Build 24 candidate; owner-device acceptance remains. |
| 2 | "Machine learning and artificial intelligence are too generic it need to be specific to the individual tastes and their nuances" | Feed chips | "For you" first, then specific topics drawn from the reader's library and tags; broad categories under "More topics". Taken as the owner's yes to the pending For you / server-visible metadata decision | Merged; server (046) live on staging with serving off; the app side ships in the next build, then serving goes to staff |
| 3 | "Why not topics? And can we put a popularity score?" | Feed Columns sheet | Topics column (several specific tags) and a Popularity column and sort from free signals cached in the shared pool; "—" when unknown | Merged; Hugging Face upvotes filling the pool (27 of 825 on the first run); ships in the next build |
| 4 | "Reference at the top of the message isn't needed" | Reference popup ("Reference 84" header) | Remove the header | Merged to main 2026-10-08 (details below); ships in the next build |
| 5 | "Needs to be a discuss in chat button … takes you to the chat with the ref text in there and you can continue typing" | Reference popup | "Discuss in chat": opens the paper's chat with the reference quoted in the composer, unsent | Merged to main 2026-10-08 (details below); ships in the next build |
| 6 | "Brafman ref missed" | Citation links ("Brafman and Ten-nenholtz 2002", hyphenated across a line) | Citation matcher handles hyphenation and diacritics; regression fixture; link rate measured before/after | Merged to main 2026-10-08 (details below); ships in the next build |
| 7 | "When figures are referenced you should be able to link directly to them … and … a 'return to reading location' option in a sensible location" | Reader ("Fig. 1") | "Fig./Table/Algorithm N" become links that show the figure with "Go to figure"; one Back-to-where-you-were control for every jump | Merged to main 2026-10-08 (details below); ships in the next build |
| — | Podcasts ("build the notebook LM podcasts feature") | Feed "Listen", paper "Listen", player | Per [PAPER_PODCASTS.md](architecture/PAPER_PODCASTS.md); owner approved the v2 profile rollout, review-gated catalog and private generation | Live on staging in revision `gradstep-pipeline-00031-l5v`: two reviewed shared episodes are published; Short / 5 / 10 / 20-minute profiles are enabled with revised server caps; the October catalog period is `$3` / 10 episodes and operator-seeded, review-gated. Two post-rollout candidates were stopped before speech by the evidence/quality gate. The dialogue-completeness and substantive-repair prompt hardening is live; post-activation scheduler samples at 15:41 and 16:02 UTC recorded 16/16 and 15/15 HTTP 200 calls with zero provider cost. Owner-device acceptance remains. |
| — | Chat model / effort / length "right there in the chat" | Chat composer | A control showing the current choice with a live credit estimate and maximum; server-enforced, versioned profiles | Merged to main; native and browser controls, profile persistence and credit estimates are covered by unit/UI journeys. Included in the current Build 24 candidate; owner-device acceptance remains. |

| 8 | "Somehow I ended up with this please fix it bug report" (16:54 UTC) | Reader: tab bar and A−/A+ float ~170 pt up, page cut off, black below (keyboard-sized inset left behind) | Reproduce, fix the leftover keyboard inset at the root, regression UI test | Fixed 2026-10-08, verified in the Simulator only; ships in the next build once merged. Cause: Search in the find bar hides the keyboard and leaves the bar docked; UIKit reports the keyboard hidden with its frame still on screen, SwiftUI keeps that frame as a keyboard inset, and the tab bar was padded for the home indicator on top of it. The owner's page was not dimmed for find, so on the device the frame stayed after the bar had gone. Now the tab bar sits just above a docked find bar, and a frame left with nothing there is ignored. Covered by `PaperToolsTests` |

### Build 21 reader items in detail

Screenshots `.artifacts/feedback/small-2026-10-08T11-47-20-18Z-0.png`, `…T11-50-01-745Z-0.png`, `…T11-51-56-283Z-0.png` and
`…T13-19-34-487Z-0.png` (local, not committed). Reader bridge and native iOS/iPad only; no re-render, no deployment.
Decisions: [References, figure links and Back](DECISIONS.md#references-figure-links-and-back-owner-feedback-on-build-21-2026-10-08-agent-decisions-reversible);
measurements: [Reader renderer](architecture/READER_RENDERER.md#figure-table-and-algorithm-references).

| # | Owner said | Change | Status |
|---|---|---|---|
| 1 | "Reference at the top of the message isn't needed" | The reference actions have no title row | Merged to main; native and browser reference journeys pass. Included in the current Build 24 candidate; owner-device acceptance remains. |
| 2 | "Needs to be a discuss in chat button … you can continue typing" | **Discuss in chat**: this paper's chat, the entry quoted in the message box (`About “…”: `), keyboard up, nothing sent; a new conversation unless the paper's chat is still empty | Merged to main; native and browser journeys cover the quoted, unsent composer state. Included in Build 24; owner-device acceptance remains. |
| 3 | "Brafman ref missed" ("Brafman and Ten-nenholtz 2002" in a semicolon group) | Hyphenated (line-break, soft, Unicode) and accented surnames match on both sides | Merged to main with the measured matcher regression (2,579/2,603 links on the staging/local sample, 0 wrong links). Included in Build 24; owner-device acceptance remains. |
| 4 | "When figures are referenced you should be able to link directly to them … a 'return to reading location' option" | "Fig. 1", "Figure 3(b)", "Figs. 2 and 3", "Table 2", "Algorithm 1" link to the element whose caption prints the label; a tap shows it with its caption in a half-height sheet with Go to figure; **Back to where you were** after every jump, left of A− / A+, until Back, two screens away or a return by scrolling | Merged to main; native and browser figure/reference journeys pass, including the KWIK fixture and Back-to-reading state. Included in Build 24; owner-device acceptance remains. |

The browser reader gets the figure links through the shared bridge; its sheet, Discuss in chat and Back wording are
listed for the web owner in the renderer doc.

## Screenshot feedback audit, 2026-10-08

All 44 TestFlight screenshot reports (builds 13–21) were checked against this file and the code. Every report
is fixed, in a build, in progress, or listed here as a follow-up for the owner:

- **Build 15, "We need to improve the tags they can't be this generic …"**:
  - Feed chips and per-paper Topics are now specific (046).
  - Library tags themselves still come from the existing vocabulary.
  - Options: tune the keyword rules with a one-time Haiku labeling pass over the shared pool (≈$0.95, $1 cap; owner approval needed), or wait for the first real For you pool and judge.
- **Build 15, "The top looks too cluttered"** (chat screen):
  - The Paper/General switch moved into the chat title's menu after that build.
  - The composer is gaining a model/effort/length control.
  - Owner check: is the chat top acceptable on the current build?
- **Build 15, "What other good customizations will help?"**: proposals for the owner after the chat controls ship. Candidates:
  - answer style (intuitive / technical / step-by-step math);
  - web search on/off per chat;
  - citations of paper passages on/off;
  - default chat settings per paper type.
- **Builds 16–20:** the items shipped in 19/20 still await the owner's acceptance on device.

## Podcast seed pilot budget, 2026-10-08

After three failed attempts ($1.00 of $2 spent, no episode published), the owner approved **"Raise to $5 total"**. This historical pilot section is superseded by the v2 rollout recorded above.
- **Where:** inside the existing $25 provider cap.
- **Unchanged:** at most $0.75 per attempt and at most two published episodes.
- **Needs:** migration 051, because 048's check constraint caps a seed period at $2.
- **Status:** superseded and deployed through migrations `051`–`055`; the current catalog allowance is `$3` / 10 episodes and is operator-seeded and review-gated. The historical fix details remain in [Seed pilot fix 3](architecture/PAPER_PODCASTS.md#seed-pilot-fix-3-review-reasons-checker-v4-and-the-5-cap-2026-10-08).

## Podcasts, after the first two episodes (2026-10-09)

The owner liked the episodes ("I like it … lets keep going with this") and approved three next steps:
1. **Re-enable Short, 10 and 20 min** with revised maxima: Short ~140 credits, 10 min ~300, 20 min ~520. Google's
   speech service takes no output cap, so each call reserves the serving limit. Typical costs are unchanged.
2. **Smoother, fuller episodes:** no unanswered questions after the checker removes a turn, and 5-minute episodes
   that actually run about 5 minutes.
3. **A weekly curated catalog** on a **$3/month** allowance (about 10 episodes), inside the $25 provider cap.
   Episodes wait for the owner's review by default.

## Build 62, 2026-10-16 14:43–15:07 UTC (iPhone, 15 items)

Delivery checkpoint, 2026-10-16 takeover: all client fixes below are merged; browser Pages `836089d4` is live;
TestFlight 63 iOS and Mac are VALID / IN_BETA_TESTING as of 20:05 UTC (evidence in IMPLEMENTATION_STATUS.md). Merged Simulator
journeys: 22 passed, 2 tablet-only skips. Item 15's provider credit and item 8's paid live verification remain open;
fixture UI evidence does not establish live provider availability. Owner acceptance remains open.

| # | Owner's words (short) | Where | Plan |
|---|---|---|---|
| 1 | "Equations in this way need an outline clean step… excess pixels around the edge… then margin" | on-device PDF model: formulas shown as images | trim stray edge pixels from a formula crop, then a margin |
| 2 | "Remove the try again. Have two options — the pdf view and the on device model" | Couldn't open this paper (MLExpert 2610.22344) | one failure screen: Open PDF, Read with the on-device model |
| 3 | "keeps trying to Download repeatedly and failing, doesn't stop retrying" | Library row | every library sync reopened the selected paper after a failed open; retry only on the reader's action |
| 4 | "This message… is too intrusive… 'Reader Version Details'… the option to update it" | banner after a failed re-preparation | no banner; ⋯ › Reader version details (this paper's, the app's, Update) |
| 5 | "different types of screens in different situations, there should be just one" | No web version vs Couldn't open | same screen as 2 |
| 6 | "top horizontal space is poorly used… X in top right… Explain in Chat and Explain with AI… liquid styling" | figure page | DESIGN.md "Sheet top row", "Explain actions" |
| 7 | "options on top… a little thing you can expand to get to… all your equation listings" | explainer pages | top row; title ⌄ lists the other figures/equations |
| 8 | "a new button for 'Extract the subfigure and more context'… loader below… puts it below" | a walkthrough part | new action per part: crop + more context, on request |
| 9 | "remove Done, use x button, use Liquid… tabs" | Contents sheet | glass tabs + X in one row |
| 10 | "remove the equation text… Equation 1, Equation 2… a tile view similar to figures?" | Contents › Equations | rows "Equation (n)"; View as tiles with the equations typeset |
| 11 | "The title Equations is duplicative" | Contents sheet | no title (the tab says it) |
| 12 | "Equation Explanations, and Figure Explanations in the list of your assets" | Settings › Your assets | two lists of the explanations kept on this device |
| 13 | "Zooming with two fingers should work… but it doesn't" | a diagram full size | pinch to zoom and pan |
| 14 | "Replace Explain with AI Explainer" | equation edit menu | "Equation" → "AI Explainer"; the pages' button is "AI Explainer" too |
| 15 | "Broken??" (Related papers) | chat | Anthropic credit balance ran out on staging (~15:00 UTC); every Claude request failed. Owner tops up; operators alerted on billing rejections |

Also seen: 2504.02792 and 2610.22083 failed their re-preparation (revision 16) on the phone while they prepare on the
Mac and in the Simulator; the reason was hidden behind the default wording. The failure reason is now shown in Reader
version details, a killed web compiler is retried once, and preparations run one at a time.


## Additional build 71 figure-card instruction — 2026-10-18 20:07 UTC (TestFlight 73; browser/backend deployed)

Report **ALCJLruWVHFOYNzJoULIvSY**, 3DCodeVerse-2M Figure 2: every pixel represented when divided into cards;
allow grouped panels; consistent titles/subtitles and distinct panel/concept/related-work cards. Screenshot
inspected under `.artifacts/feedback/build71-20261018/`. The app/browser retain the full overview, check the
pixel union of outward-rounded crops, and label an incomplete split explicitly. Additive card kinds preserve old
saved answers and prevent a concept/related-work card from becoming a crop. Related work identifies the supplied
paper as its source; no other paper is fetched automatically. Server prompt asks for complete grouped/panel
coverage, with at most the existing 12 sections. No detector is promoted by these presentation changes.
The initial seven reports shipped in iPhone/iPad TestFlight 72; this eighth report and the later six reports
are included in build 73 on iOS/iPadOS and Mac (VALID / IN_BETA_TESTING at 21:45:12 UTC).
